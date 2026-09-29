-- 0245 — Fixes del audit adversarial de 0243/0244 (Fase 4, 2026-08-20).
--
-- Findings corregidos (reporte del agente DB/dinero):
--   #1 ALTA  pago_historico: el correlativo del recibo lo asigna el TRIGGER
--      0215 (contador recibo_correlativos) pisando NEW.correlativo — el max+1
--      de 0244 era cálculo muerto y el número reportado/registrado en op_log
--      podía NO ser el real (drift contador vs max verificado en prod: series
--      CT y RA). Fix: el INSERT usa RETURNING para leer el número REAL
--      post-trigger; el preview estima con el contador (fallback max+1).
--   #2 MEDIA pago_historico: si el guard 0218 (BEFORE INSERT) anulaba o
--      encuarentenaba el pago por una carrera con un device, el RPC igual
--      reportaba éxito. Fix: RETURNING anulado/en_revision + RAISE (rollback
--      total, no queda ni pago ni recibo ni registro).
--   #3 MEDIA grants: los default privileges de Supabase les daban EXECUTE a
--      anon/authenticated/service_role incluso sobre las _impl ("revoke from
--      public" no los toca). Fix: revoke explícito por rol; las _impl quedan
--      sin ningún grant (los wrappers DEFINER las llaman como owner).
--   #4 MEDIA baja_deuda: al cancelar el contrato, el trigger 0234
--      (z_contratos_anular_cuotas_futuras) anulaba las cuotas FUTURAS con su
--      propio motivo y sin op_log — el loop posterior ya no las veía y esas
--      cuotas quedaban sin historial de la baja. Fix: capturar los ids ANTES
--      de cancelar y anotar/emitir op_log por cada uno con UPDATE idempotente
--      (misma transacción, misma intención).
--   #5 MEDIA/BAJA cuota_estado: anular una cuota de un contrato FIJO activo
--      deja INV11 señalada para siempre. Decisión de producto pendiente
--      (BITACORA); acá solo se AGREGA el aviso en el preview.
--   Nota: warn de cuarentena en el preview del pago histórico; mensaje en el
--   early-return de baja_deuda (la UI espera 'mensaje' al ejecutar).

begin;

-- ═════════════════════════════ 1. PAGO HISTÓRICO ════════════════════════════

create or replace function public.super_admin_pago_historico_impl(
  p_tenant uuid, p_cuota uuid, p_monto numeric, p_fecha date, p_metodo text,
  p_cobrador uuid, p_referencia text, p_ejecutar boolean, p_actor_label text)
returns jsonb
language plpgsql volatile security definer set search_path=public as $fn$
declare
  v_cu   public.cuotas%rowtype;
  v_ct   public.contratos%rowtype;
  v_cl   public.clientes%rowtype;
  v_co   public.cobradores%rowtype;
  v_hoy  date := (now() at time zone 'America/Managua')::date;
  v_saldo numeric;
  v_estado_desp text;
  v_saldo_desp numeric;
  v_vieja record;
  v_warn text := '';
  v_corr int;
  v_num text;
  v_pago uuid;
  v_pg_anulado boolean;
  v_pg_rev boolean;
  v_op uuid;
  v_label text;
  v_ref text := trim(coalesce(p_referencia, ''));
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  select * into v_cu from public.cuotas where id = p_cuota;
  if v_cu.id is null or v_cu.tenant_id <> p_tenant then
    raise exception 'La cuota no existe en esta empresa.';
  end if;
  if v_cu.estado = 'anulada' then
    raise exception 'La cuota está anulada. Revivila primero (operación "Revivir / anular cuota") y después registrá el pago.';
  end if;
  if v_cu.estado = 'pagada' then
    raise exception 'La cuota ya está pagada por completo — no hay saldo que cubrir.';
  end if;

  select * into v_cl from public.clientes where id = v_cu.cliente_id;

  if v_cu.contrato_id is not null then
    select * into v_ct from public.contratos where id = v_cu.contrato_id;
    if v_ct.estado = 'cancelado' then
      raise exception 'El contrato % está cancelado. Revertí la cancelación antes de registrar pagos.', coalesce(v_ct.codigo, '');
    end if;
    if v_ct.estado = 'suspendido' then
      v_warn := v_warn || e'\n⚠ El contrato está SUSPENDIDO: se puede cobrar deuda vieja, pero verificá que corresponda.';
    end if;
  end if;

  v_saldo := v_cu.monto + coalesce(v_cu.cargos_neto, 0) - v_cu.monto_pagado;
  if p_monto is null or p_monto < 0.01 then
    raise exception 'El monto tiene que ser mayor a cero.';
  end if;
  if p_monto > v_saldo + 0.01 then
    raise exception 'El monto (C$%) supera el saldo de la cuota (C$%). Esta vía no admite sobrepagos: registrá hasta el saldo exacto.',
      to_char(p_monto, 'FM999,999,990.00'), to_char(v_saldo, 'FM999,999,990.00');
  end if;

  if p_fecha is null or p_fecha > v_hoy then
    raise exception 'La fecha del pago no puede ser futura.';
  end if;
  if p_fecha < date '2020-01-01' then
    raise exception 'La fecha del pago no parece real (anterior a 2020).';
  end if;

  if p_metodo is null or p_metodo not in ('efectivo','transferencia','deposito','tarjeta') then
    raise exception 'Método inválido. Opciones: efectivo, transferencia, deposito, tarjeta.';
  end if;
  if length(v_ref) < 3 then
    raise exception 'La referencia del comprobante es obligatoria (n.° de recibo físico, referencia del sistema viejo, etc.).';
  end if;

  select * into v_co from public.cobradores where id = p_cobrador;
  if v_co.id is null or v_co.tenant_id <> p_tenant then
    raise exception 'El usuario a quien atribuir el pago no existe en esta empresa.';
  end if;
  if not v_co.activo then
    raise exception 'El usuario % está inactivo — elegí un usuario activo.', v_co.nombre;
  end if;
  if coalesce(v_co.prefijo_recibo, '') = '' then
    raise exception 'El usuario % no tiene prefijo de recibo asignado. Asignale uno en Cobradores o elegí otro usuario.', v_co.nombre;
  end if;

  -- Oldest-first (#11): sin dejar atrás una cuota más vieja pendiente del
  -- mismo contrato (los cargos manuales quedan exentos, como en la app).
  if v_cu.contrato_id is not null and v_cu.tipo_cargo_manual is null then
    select cu2.periodo, cu2.fecha_vencimiento into v_vieja
      from public.cuotas cu2
     where cu2.contrato_id = v_cu.contrato_id and cu2.id <> v_cu.id
       and cu2.tipo_cargo_manual is null
       and cu2.estado in ('pendiente','parcial')
       and cu2.fecha_vencimiento < v_cu.fecha_vencimiento
     order by cu2.fecha_vencimiento
     limit 1;
    if v_vieja.periodo is not null then
      raise exception 'Hay una cuota más vieja pendiente en el mismo contrato (vence %). Registrá primero esa (oldest-first).',
        to_char(v_vieja.fecha_vencimiento, 'DD/MM/YYYY');
    end if;
  end if;

  -- Avisos (no bloquean): duplicado del mismo monto / cobros en cuarentena.
  if exists (select 1 from public.pagos p
              where p.cuota_id = p_cuota and not p.anulado and not p.en_revision
                and round(p.monto_cordobas * 100) = round(p_monto * 100)) then
    v_warn := v_warn || e'\n⚠ Ya existe un pago vivo del MISMO monto en esta cuota. Verificá que no estés duplicando.';
  end if;
  if exists (select 1 from public.pagos p
              where p.cuota_id = p_cuota and p.en_revision and not p.anulado) then
    v_warn := v_warn || e'\n⚠ Hay cobro(s) EN CUARENTENA sobre esta cuota, pendientes de decisión en la bandeja. Si el admin los aprueba después, podrían exceder el total.';
  end if;

  -- Recibo estimado: el número REAL lo asigna el trigger 0215 con el contador
  -- recibo_correlativos (fix #1) — se estima con ese contador, no con max+1.
  select coalesce(
      (select rc.ultimo + 1 from public.recibo_correlativos rc
        where rc.tenant_id = p_tenant and rc.prefijo = v_co.prefijo_recibo),
      (select coalesce(max(r.correlativo), 0) + 1 from public.recibos r
        where r.tenant_id = p_tenant and r.prefijo = v_co.prefijo_recibo))
    into v_corr;
  v_num := v_co.prefijo_recibo || '-' || lpad(v_corr::text, 5, '0');

  v_estado_desp := case when p_monto >= v_saldo - 0.01 then 'pagada' else 'parcial' end;
  v_saldo_desp  := greatest(v_saldo - p_monto, 0);

  v_label :=
    'Cliente: ' || coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre || ' (' ||
      (select nombre from public.tenants where id = p_tenant) || ')' ||
    e'\nCuota: periodo ' || to_char(v_cu.periodo, 'DD/MM/YYYY') ||
      ' · vence ' || to_char(v_cu.fecha_vencimiento, 'DD/MM/YYYY') ||
      ' · saldo C$' || to_char(v_saldo, 'FM999,999,990.00') ||
    e'\nSe registra: C$' || to_char(p_monto, 'FM999,999,990.00') || ' (' || p_metodo ||
      ') con fecha ' || to_char(p_fecha, 'DD/MM/YYYY') ||
      ', atribuido a ' || v_co.nombre ||
    e'\nComprobante: ' || v_ref ||
    e'\nRecibo CRM: ' || v_num || case when p_ejecutar then '' else ' (estimado)' end ||
    e'\nResultado: la cuota queda ' || upper(v_estado_desp) ||
      case when v_saldo_desp > 0.009
           then ' (saldo restante C$' || to_char(v_saldo_desp, 'FM999,999,990.00') || ')'
           else '' end ||
    v_warn;

  if not p_ejecutar then
    return jsonb_build_object('afectados', 1, 'label', v_label);
  end if;

  -- ── Ejecutar ──────────────────────────────────────────────────────────────
  v_pago := gen_random_uuid();
  v_op := gen_random_uuid();

  -- fecha_pago/created_at del recibo: la FECHA REAL a medianoche (convención
  -- local-naive → el bucketing por date() cae en el día correcto, y la
  -- medianoche marca "no nació de un cobro en vivo" para recibos_huecos()).
  -- RETURNING (fix #2): si el guard 0218 (BEFORE INSERT) anuló o encuarentenó
  -- el pago por una carrera con un device, acá se detecta y se ABORTA todo.
  insert into public.pagos (
      id, tenant_id, cuota_id, cobrador_id, monto_cordobas, metodo, notas,
      fecha_pago, client_local_id, moneda, monto_original, tasa_conversion,
      referencia, anulado, vuelto_cordobas, ocurrido_en, en_revision)
  values (
      v_pago, p_tenant, p_cuota, p_cobrador, p_monto, p_metodo,
      'Pago histórico (Dev) — comprobante: ' || v_ref,
      p_fecha::timestamp, null, 'NIO', p_monto, 1,
      v_ref, false, 0, now(), false)
  returning anulado, en_revision into v_pg_anulado, v_pg_rev;

  if v_pg_anulado or v_pg_rev then
    raise exception 'Un cobro simultáneo cambió la cuota mientras confirmabas: el guard del servidor marcó este pago como duplicado/sobrepago. NO se registró nada — refrescá y verificá el estado actual de la cuota.';
  end if;

  -- El número REAL lo pone el trigger 0215 (contador) — RETURNING lo lee
  -- post-trigger (fix #1): op_log, data_ops_log y el mensaje usan ESTE.
  insert into public.recibos (
      id, tenant_id, pago_id, cobrador_id, prefijo, correlativo,
      numero_completo, reimpresiones, anulado, created_at, client_local_id,
      ocurrido_en)
  values (
      gen_random_uuid(), p_tenant, v_pago, p_cobrador, v_co.prefijo_recibo,
      v_corr, v_num, 0, false, p_fecha::timestamp, null, now())
  returning numero_completo, correlativo into v_num, v_corr;

  -- Estado real post-triggers (recalcular_cuota mantiene monto_pagado/estado).
  select estado, greatest(monto + coalesce(cargos_neto,0) - monto_pagado, 0)
    into v_estado_desp, v_saldo_desp
    from public.cuotas where id = p_cuota;

  -- op_log (1 fila por objeto, mismo op_id; formato espejo de pagos_repo).
  insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
      actor_id, actor_label, accion, diff, ocurrido_en)
  values
    (gen_random_uuid(), p_tenant, v_op, 'cobro_recuperado', 'cuotas', p_cuota,
     null, 'System Admin', 'update',
     jsonb_build_object(
       'campos', jsonb_build_array(
         jsonb_build_object('campo','estado','antes',v_cu.estado,'despues',v_estado_desp),
         jsonb_build_object('campo','saldo','antes',greatest(v_saldo,0),'despues',v_saldo_desp)),
       'resumen', jsonb_build_object(
         'monto', p_monto, 'entregado', p_monto, 'moneda', 'NIO', 'vuelto', 0,
         'metodo', p_metodo, 'fecha_pago', p_fecha, 'recibo', v_num,
         'motivo', 'Pago histórico — comprobante: ' || v_ref))::text,
     now()),
    (gen_random_uuid(), p_tenant, v_op, 'cobro_recuperado', 'pagos', v_pago,
     null, 'System Admin', 'create',
     jsonb_build_object(
       'campos', '[]'::jsonb,
       'resumen', jsonb_build_object(
         'monto', p_monto, 'metodo', p_metodo, 'fecha_pago', p_fecha,
         'recibo', v_num, 'motivo', 'Pago histórico — comprobante: ' || v_ref))::text,
     now());

  insert into public.data_ops_log (tenant_id, operacion, target_label,
      afectados, backup_id, actor_id, actor_label)
  values (p_tenant, 'pago_historico',
      coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre || ' · ' || v_num,
      jsonb_build_object('pagos', 1, 'recibos', 1, 'monto', p_monto,
                         'fecha', p_fecha, 'comprobante', v_ref),
      null, auth.uid(), p_actor_label);

  return jsonb_build_object(
    'afectados', 1,
    'mensaje', 'Pago histórico de C$' || to_char(p_monto, 'FM999,999,990.00') ||
               ' registrado a ' || v_cl.nombre || '. Recibo ' || v_num || '.',
    'recibo', v_num);
end $fn$;

-- ═══════════════════════════ 2. REVIVIR / ANULAR CUOTA ══════════════════════
-- Cambio único vs 0244: aviso INV11 en el preview al anular una cuota de un
-- contrato FIJO activo (finding #5 — la decisión de fondo queda en BITACORA).

create or replace function public.super_admin_cuota_estado_impl(
  p_tenant uuid, p_cuota uuid, p_accion text, p_motivo text,
  p_ejecutar boolean, p_actor_label text)
returns jsonb
language plpgsql volatile security definer set search_path=public as $fn$
declare
  v_cu public.cuotas%rowtype;
  v_ct public.contratos%rowtype;
  v_cl public.clientes%rowtype;
  v_saldo numeric;
  v_nuevo text;
  v_warn text := '';
  v_label text;
  v_op uuid := gen_random_uuid();
  v_backup uuid;
  v_motivo text := trim(coalesce(p_motivo, ''));
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_accion not in ('anular','revivir') then
    raise exception 'Acción inválida (anular | revivir).';
  end if;
  if length(v_motivo) < 5 then
    raise exception 'El motivo es obligatorio (mínimo 5 caracteres) — queda en el historial para siempre.';
  end if;

  select * into v_cu from public.cuotas where id = p_cuota;
  if v_cu.id is null or v_cu.tenant_id <> p_tenant then
    raise exception 'La cuota no existe en esta empresa.';
  end if;
  select * into v_cl from public.clientes where id = v_cu.cliente_id;
  if v_cu.contrato_id is not null then
    select * into v_ct from public.contratos where id = v_cu.contrato_id;
  end if;

  v_saldo := greatest(v_cu.monto + coalesce(v_cu.cargos_neto,0) - v_cu.monto_pagado, 0);

  if p_accion = 'anular' then
    if v_cu.estado = 'anulada' then
      raise exception 'La cuota ya está anulada.';
    end if;
    if v_cu.monto_pagado > 0.009 then
      raise exception 'La cuota tiene C$% ya cobrados. Anulá primero ese/esos pago(s) desde el detalle del pago — la plata cobrada nunca se esconde.',
        to_char(v_cu.monto_pagado, 'FM999,999,990.00');
    end if;
    if exists (select 1 from public.pagos p
                where p.cuota_id = p_cuota and p.en_revision and not p.anulado) then
      raise exception 'Hay un cobro EN CUARENTENA sobre esta cuota. Resolvelo en la bandeja antes de anularla.';
    end if;
    -- Aviso INV11 (finding #5): en un fijo activo el conteo de cuotas vivas
    -- deja de cuadrar con la duración y el verificador lo señala.
    if v_ct.id is not null and v_ct.estado = 'activo'
       and v_ct.duracion_meses is not null then
      v_warn := v_warn || e'\n⚠ Contrato FIJO activo: al anular, el verificador de invariantes (INV11) va a señalar este contrato porque sus cuotas ya no cuadran con la duración. Si el mes no se cobra por un corte de servicio, lo correcto es la SUSPENSIÓN, no anular a mano.';
    end if;
    v_nuevo := 'anulada';
    v_label :=
      'Cliente: ' || coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre ||
      e'\nSe ANULA la cuota: periodo ' || to_char(v_cu.periodo, 'DD/MM/YYYY') ||
        ' · vence ' || to_char(v_cu.fecha_vencimiento, 'DD/MM/YYYY') ||
        ' · C$' || to_char(v_saldo, 'FM999,999,990.00') ||
      e'\nLa deuda del cliente baja C$' || to_char(v_saldo, 'FM999,999,990.00') ||
      e'\nMotivo: ' || v_motivo ||
      e'\nReversible: se puede revivir después con esta misma pantalla.' ||
      v_warn;
  else
    if v_cu.estado <> 'anulada' then
      raise exception 'La cuota no está anulada — no hay nada que revivir.';
    end if;
    if v_ct.id is not null and v_ct.estado = 'cancelado' then
      raise exception 'El contrato % está cancelado. Revertí la cancelación primero.', coalesce(v_ct.codigo, '');
    end if;
    if not v_cl.activo then
      raise exception 'El cliente está DESACTIVADO — revivir la cuota le crearía deuda viva (INV19). Reactivá el cliente primero.';
    end if;
    if v_ct.id is not null and v_ct.estado = 'suspendido' then
      v_warn := e'\n⚠ El contrato está SUSPENDIDO: la cuota revive pero verificá que corresponda cobrarla.';
    end if;
    v_nuevo := case
      when v_cu.monto_pagado >= v_cu.monto + coalesce(v_cu.cargos_neto,0) - 0.01 then 'pagada'
      when v_cu.monto_pagado > 0.009 then 'parcial'
      else 'pendiente' end;
    v_label :=
      'Cliente: ' || coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre ||
      e'\nSe REVIVE la cuota: periodo ' || to_char(v_cu.periodo, 'DD/MM/YYYY') ||
        ' · vence ' || to_char(v_cu.fecha_vencimiento, 'DD/MM/YYYY') ||
        ' · C$' || to_char(v_saldo, 'FM999,999,990.00') ||
      e'\n(La habían anulado el ' || coalesce(to_char(v_cu.anulada_en, 'DD/MM/YYYY'), '?') ||
        ' con motivo: ' || coalesce(v_cu.motivo_anulacion, '—') || ')' ||
      e'\nQueda en estado ' || upper(v_nuevo) ||
      case when v_nuevo <> 'pagada'
           then ' — la deuda del cliente sube C$' || to_char(v_saldo, 'FM999,999,990.00')
           else '' end ||
      e'\nMotivo: ' || v_motivo || v_warn;
  end if;

  if not p_ejecutar then
    return jsonb_build_object('afectados', 1, 'label', v_label);
  end if;

  -- ── Ejecutar (backup de la fila previa + cambio + registros) ─────────────
  insert into public.data_op_backups (tenant_id, operacion, target_label, snapshot,
      actor_id, actor_label)
  values (p_tenant, 'cuota_' || p_accion,
      coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre || ' · cuota ' ||
        to_char(v_cu.periodo, 'DD/MM/YYYY'),
      jsonb_build_object('cuotas', jsonb_build_array(to_jsonb(v_cu))),
      auth.uid(), p_actor_label)
  returning id into v_backup;

  if p_accion = 'anular' then
    update public.cuotas
       set estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(),
           motivo_anulacion = 'Dev: ' || v_motivo
     where id = p_cuota;
  else
    update public.cuotas
       set estado = v_nuevo, anulada_en = null, anulada_por = null,
           motivo_anulacion = null
     where id = p_cuota;
  end if;

  insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
      actor_id, actor_label, accion, diff, ocurrido_en)
  values (gen_random_uuid(), p_tenant, v_op, 'anulacion_cuota', 'cuotas', p_cuota,
      null, 'System Admin', 'update',
      jsonb_build_object(
        'campos', jsonb_build_array(
          jsonb_build_object('campo','estado','antes',v_cu.estado,
                             'despues', case when p_accion='anular' then 'anulada' else v_nuevo end)),
        'resumen', jsonb_build_object(
          'motivo', case when p_accion='revivir' then 'REACTIVADA: ' else '' end || v_motivo))::text,
      now());

  insert into public.data_ops_log (tenant_id, operacion, target_label, afectados,
      backup_id, actor_id, actor_label)
  values (p_tenant, 'cuota_' || p_accion,
      coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre || ' · cuota ' ||
        to_char(v_cu.periodo, 'DD/MM/YYYY'),
      jsonb_build_object('cuotas', 1, 'saldo', v_saldo, 'motivo', v_motivo),
      v_backup, auth.uid(), p_actor_label);

  return jsonb_build_object(
    'afectados', 1,
    'mensaje', case when p_accion = 'anular'
      then 'Cuota anulada. La deuda de ' || v_cl.nombre || ' bajó C$' ||
           to_char(v_saldo, 'FM999,999,990.00') || '.'
      else 'Cuota revivida (queda ' || v_nuevo || '). El historial registró la reactivación.' end);
end $fn$;

-- ═══════════════════════ 3. BAJA DE DEUDA (cliente que se va) ═══════════════
-- Cambios vs 0244 (finding #4 + notas): los ids de las cuotas a anular se
-- capturan ANTES de cancelar contratos (el trigger 0234 anula las futuras al
-- cancelar, con motivo ajeno y sin op_log — ahora el paso 2 las re-anota con
-- el motivo de la baja y emite SU fila op_log, UPDATE idempotente); el
-- early-return trae 'mensaje'; el label ya no promete snapshot en contratos
-- previamente cancelados.

create or replace function public.super_admin_baja_deuda_impl(
  p_tenant uuid, p_cliente uuid, p_motivo text,
  p_ejecutar boolean, p_actor_label text)
returns jsonb
language plpgsql volatile security definer set search_path=public as $fn$
declare
  v_cl public.clientes%rowtype;
  v_motivo text := trim(coalesce(p_motivo, ''));
  v_parcial record;
  v_ids uuid[];
  v_n_cuotas int;
  v_total numeric;
  v_n_contratos int;
  v_afectados int;
  v_label text;
  v_op uuid := gen_random_uuid();
  v_backup uuid;
  v_ct record;
  v_cuota record;
  v_snap jsonb;
  v_msg text;
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if length(v_motivo) < 5 then
    raise exception 'El motivo es obligatorio (mínimo 5 caracteres) — queda en el historial para siempre.';
  end if;

  select * into v_cl from public.clientes where id = p_cliente;
  if v_cl.id is null or v_cl.tenant_id <> p_tenant then
    raise exception 'El cliente no existe en esta empresa.';
  end if;

  -- Bloqueo 1: cuarentenas abiertas (plata en el limbo — decidir primero).
  if exists (select 1 from public.pagos p
              join public.cuotas cu on cu.id = p.cuota_id
             where cu.cliente_id = p_cliente and p.en_revision and not p.anulado) then
    raise exception 'El cliente tiene cobros EN CUARENTENA. Resolvelos en la bandeja antes de darlo de baja.';
  end if;

  -- Bloqueo 2: cuotas con plata cobrada a medias (INV12 — jamás se anulan).
  select cu.periodo, cu.monto_pagado into v_parcial
    from public.cuotas cu
   where cu.cliente_id = p_cliente
     and cu.estado in ('pendiente','parcial')
     and cu.monto_pagado > 0.009
   order by cu.fecha_vencimiento
   limit 1;
  if v_parcial.periodo is not null then
    raise exception 'La cuota del periodo % tiene C$% ya cobrados. Antes de la baja: o completala con "Registrar pago histórico", o anulá su pago. La plata cobrada nunca se descarta.',
      to_char(v_parcial.periodo, 'DD/MM/YYYY'),
      to_char(v_parcial.monto_pagado, 'FM999,999,990.00');
  end if;

  -- El SET de la baja se captura ACÁ, antes de tocar nada (fix #4): al
  -- cancelar un contrato, el trigger 0234 anula sus cuotas futuras y el
  -- filtro estado='pendiente' dejaría de verlas.
  select array_agg(cu.id order by cu.fecha_vencimiento),
         count(*)::int,
         coalesce(sum(cu.monto + coalesce(cu.cargos_neto,0)), 0)
    into v_ids, v_n_cuotas, v_total
    from public.cuotas cu
   where cu.cliente_id = p_cliente and cu.estado = 'pendiente'
     and cu.monto_pagado <= 0.009;

  select count(*) into v_n_contratos
    from public.contratos ct
   where ct.cliente_id = p_cliente and ct.estado in ('activo','suspendido');

  v_afectados := v_n_cuotas + v_n_contratos + case when v_cl.activo then 1 else 0 end;

  if v_afectados = 0 then
    return jsonb_build_object('afectados', 0,
      'label', 'Nada que hacer: el cliente ya está desactivado, sin contratos vivos ni deuda pendiente.',
      'mensaje', 'Nada que hacer: el cliente ya está desactivado, sin contratos vivos ni deuda pendiente.');
  end if;

  v_label :=
    'Cliente: ' || coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre ||
      case when v_cl.activo then ' (activo)' else ' (ya desactivado)' end ||
    e'\nSe dan de baja ' || v_n_cuotas || ' cuota(s) pendiente(s) por C$' ||
      to_char(v_total, 'FM999,999,990.00') ||
      ' (quedan como ANULADAS; los contratos vivos guardan la foto de su deuda)' ||
    e'\nSe cancela(n) ' || v_n_contratos || ' contrato(s) vivo(s)' ||
    case when v_cl.activo then e'\nEl cliente queda DESACTIVADO' else '' end ||
    e'\nMotivo: ' || v_motivo ||
    e'\nLo ya cobrado no se toca. Todo queda en el historial y con respaldo restaurable.';

  if not p_ejecutar then
    return jsonb_build_object('afectados', v_afectados, 'label', v_label);
  end if;

  -- ── Ejecutar ──────────────────────────────────────────────────────────────
  -- 0) Respaldo completo de lo que se toca (por ids exactos).
  insert into public.data_op_backups (tenant_id, operacion, target_label, snapshot,
      actor_id, actor_label)
  values (p_tenant, 'baja_deuda',
      coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre,
      jsonb_build_object(
        'cliente', to_jsonb(v_cl),
        'contratos', coalesce((select jsonb_agg(to_jsonb(ct))
            from public.contratos ct
           where ct.cliente_id = p_cliente and ct.estado in ('activo','suspendido')), '[]'::jsonb),
        'cuotas', coalesce((select jsonb_agg(to_jsonb(cu))
            from public.cuotas cu
           where cu.id = any(coalesce(v_ids, '{}'::uuid[]))), '[]'::jsonb)),
      auth.uid(), p_actor_label)
  returning id into v_backup;

  -- 1) Foto de la deuda en cada contrato vivo (mismo formato que DeudaSnapshot)
  --    y cancelación. El snapshot se toma ANTES del update de ese contrato.
  for v_ct in
    select ct.*, pl.precio_mensual as plan_precio
      from public.contratos ct
      left join public.planes pl on pl.id = ct.plan_id
     where ct.cliente_id = p_cliente and ct.estado in ('activo','suspendido')
  loop
    select jsonb_build_object(
        'total', coalesce(sum(cu.monto + coalesce(cu.cargos_neto,0)), 0),
        'cuotas', coalesce(jsonb_agg(jsonb_build_object(
            'periodo', cu.periodo, 'saldo', cu.monto + coalesce(cu.cargos_neto,0),
            'monto_pagado', cu.monto_pagado,
            'fecha_vencimiento', cu.fecha_vencimiento)
          order by cu.fecha_vencimiento), '[]'::jsonb),
        'dia_pago', v_ct.dia_pago,
        'precio_mensual', coalesce(v_ct.plan_precio, 0),
        'fecha', now())
      into v_snap
      from public.cuotas cu
     where cu.contrato_id = v_ct.id and cu.id = any(coalesce(v_ids, '{}'::uuid[]));

    update public.contratos
       set estado = 'cancelado', cancelado_en = now(), cancelado_por = auth.uid(),
           motivo_cancelacion = 'Baja de deuda (Dev): ' || v_motivo,
           cancelacion_deuda_snapshot =
             case when (v_snap->>'total')::numeric > 0.009 then v_snap::text
                  else cancelacion_deuda_snapshot end
     where id = v_ct.id;

    insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
        actor_id, actor_label, accion, diff, ocurrido_en)
    values (gen_random_uuid(), p_tenant, v_op, 'cancelacion', 'contratos', v_ct.id,
        null, 'System Admin', 'update',
        jsonb_build_object(
          'campos', jsonb_build_array(
            jsonb_build_object('campo','estado','antes',v_ct.estado,'despues','cancelado')),
          'resumen', jsonb_build_object('motivo', 'Baja de deuda: ' || v_motivo))::text,
        now());
  end loop;

  -- 2) Anular el SET capturado (fix #4): UPDATE idempotente — si el trigger
  --    0234 ya la anuló al cancelar el contrato, acá se re-anota con el motivo
  --    de la BAJA (misma transacción, misma intención) y se emite su op_log.
  for v_cuota in
    select cu.id, cu.periodo,
           cu.monto + coalesce(cu.cargos_neto,0) as saldo
      from public.cuotas cu
     where cu.id = any(coalesce(v_ids, '{}'::uuid[]))
  loop
    update public.cuotas
       set estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(),
           motivo_anulacion = 'Baja de deuda (Dev): ' || v_motivo
     where id = v_cuota.id;

    insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
        actor_id, actor_label, accion, diff, ocurrido_en)
    values (gen_random_uuid(), p_tenant, v_op, 'anulacion_cuota', 'cuotas', v_cuota.id,
        null, 'System Admin', 'update',
        jsonb_build_object(
          'campos', jsonb_build_array(
            jsonb_build_object('campo','estado','antes','pendiente','despues','anulada')),
          'resumen', jsonb_build_object(
            'motivo', 'Baja de deuda: ' || v_motivo,
            'monto', v_cuota.saldo))::text,
        now());
  end loop;

  -- 3) Desactivar el cliente (el guard 0220 ya no ve deuda viva).
  if v_cl.activo then
    update public.clientes set activo = false where id = p_cliente;
  end if;

  insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
      actor_id, actor_label, accion, diff, ocurrido_en)
  values (gen_random_uuid(), p_tenant, v_op, 'limpieza_deuda', 'clientes', p_cliente,
      null, 'System Admin', 'update',
      jsonb_build_object(
        'campos', case when v_cl.activo
          then jsonb_build_array(jsonb_build_object('campo','activo','antes',true,'despues',false))
          else '[]'::jsonb end,
        'resumen', jsonb_build_object(
          'motivo', v_motivo, 'monto', v_total,
          'cuotas_anuladas', v_n_cuotas, 'contratos_cancelados', v_n_contratos))::text,
      now());

  insert into public.data_ops_log (tenant_id, operacion, target_label, afectados,
      backup_id, actor_id, actor_label)
  values (p_tenant, 'baja_deuda',
      coalesce(v_cl.codigo || ' — ', '') || v_cl.nombre,
      jsonb_build_object('cuotas', v_n_cuotas, 'contratos', v_n_contratos,
                         'total', v_total, 'motivo', v_motivo),
      v_backup, auth.uid(), p_actor_label);

  v_msg := 'Baja registrada: ' || v_n_cuotas || ' cuota(s) por C$' ||
           to_char(v_total, 'FM999,999,990.00') || ' anulada(s), ' ||
           v_n_contratos || ' contrato(s) cancelado(s)' ||
           case when v_cl.activo then ' y el cliente desactivado.' else '.' end;
  return jsonb_build_object('afectados', v_afectados, 'mensaje', v_msg);
end $fn$;

-- ═══════════════════ 4. GRANTS REALES (fix #3) ══════════════════════════════
-- Los default privileges de Supabase les dieron EXECUTE a anon/authenticated/
-- service_role al crear las funciones ("revoke from public" no los toca).
-- Las _impl quedan SIN ningún grant (los wrappers DEFINER las llaman como
-- owner); los wrappers y los diag quedan solo para authenticated (el gate
-- is_super_admin() interno sigue siendo la defensa principal).

revoke all on function public.super_admin_pago_historico_impl(uuid,uuid,numeric,date,text,uuid,text,boolean,text) from public, anon, authenticated, service_role;
revoke all on function public.super_admin_cuota_estado_impl(uuid,uuid,text,text,boolean,text) from public, anon, authenticated, service_role;
revoke all on function public.super_admin_baja_deuda_impl(uuid,uuid,text,boolean,text) from public, anon, authenticated, service_role;

revoke all on function public.super_admin_preview_pago_historico(uuid,uuid,numeric,date,text,uuid,text) from public, anon, service_role;
revoke all on function public.super_admin_ejecutar_pago_historico(uuid,uuid,numeric,date,text,uuid,text,text) from public, anon, service_role;
revoke all on function public.super_admin_preview_cuota_estado(uuid,uuid,text,text) from public, anon, service_role;
revoke all on function public.super_admin_ejecutar_cuota_estado(uuid,uuid,text,text,text) from public, anon, service_role;
revoke all on function public.super_admin_preview_baja_deuda(uuid,uuid,text) from public, anon, service_role;
revoke all on function public.super_admin_ejecutar_baja_deuda(uuid,uuid,text,text) from public, anon, service_role;

revoke all on function public.super_admin_diag_buscar(text) from public, anon, service_role;
revoke all on function public.super_admin_diag_cliente(uuid) from public, anon, service_role;
revoke all on function public.super_admin_diag_talonarios() from public, anon, service_role;
revoke all on function public.super_admin_diag_fantasmas() from public, anon, service_role;

grant execute on function public.super_admin_preview_pago_historico(uuid,uuid,numeric,date,text,uuid,text) to authenticated;
grant execute on function public.super_admin_ejecutar_pago_historico(uuid,uuid,numeric,date,text,uuid,text,text) to authenticated;
grant execute on function public.super_admin_preview_cuota_estado(uuid,uuid,text,text) to authenticated;
grant execute on function public.super_admin_ejecutar_cuota_estado(uuid,uuid,text,text,text) to authenticated;
grant execute on function public.super_admin_preview_baja_deuda(uuid,uuid,text) to authenticated;
grant execute on function public.super_admin_ejecutar_baja_deuda(uuid,uuid,text,text) to authenticated;
grant execute on function public.super_admin_diag_buscar(text) to authenticated;
grant execute on function public.super_admin_diag_cliente(uuid) to authenticated;
grant execute on function public.super_admin_diag_talonarios() to authenticated;
grant execute on function public.super_admin_diag_fantasmas() to authenticated;

commit;
