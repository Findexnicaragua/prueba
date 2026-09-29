-- 0240 — Bulletproofing de recibos y duplicados (audit adversarial 2026-08-19).
--
-- Cuatro fixes de una misma familia: dinero que entra offline/online debe
-- terminar SIEMPRE contado una sola vez, con comprobante coherente y con
-- alerta humana cuando algo huele mal.
--
-- §1 sync_rechazo_registrar: el contador NUNCA queda debajo de un número
--    restaurado (brickeaba la serie si se recuperaba en orden nuevo→viejo).
--    Cuerpo COMPLETO re-creado desde la definición vigente de 0237.
-- §2 Guard de sobrepago también en UPDATE: editar un pago o sacarlo de
--    cuarentena re-verifica; si el resultado excede el total, VUELVE a
--    cuarentena (mismo principio de 0218: nunca rechazar, siempre marcar).
-- §3 El recibo de un pago que NACE anulado (gemelo auto-anulado) nace
--    anulado también + fix retroactivo de los existentes.
-- §4 El gemelo auto-anulado deja rastro en op_log de la cuota (era silencio
--    total). Guard re-creado desde la definición vigente de 0218.

begin;

-- ══ §1: RPC de recuperación con contador a prueba de orden ══════════════════
create or replace function public.sync_rechazo_registrar(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $fn$
declare
  r           public.sync_rechazos%rowtype;
  v_payload   jsonb;
  v_pago_id   uuid;
  v_estado    text;
  v_num       text;
  v_orig_pref text;
  v_orig_corr int;
  v_new_corr  int;
  v_cuota     uuid;
  v_monto     numeric;
  v_est_antes text;
  v_est_desp  text;
  v_actor     uuid;
  v_label     text;
  v_rol       text;
begin
  select * into r from public.sync_rechazos where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Rechazo no encontrado');
  end if;
  if r.resuelto then
    return jsonb_build_object('ok', false, 'error', 'Ya estaba resuelto');
  end if;
  if not public.sync_rechazo_autorizado(r.tenant_id) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso sobre este rechazo');
  end if;
  if r.tabla not in ('pagos','recibos') or r.op <> 'put' then
    return jsonb_build_object('ok', false,
      'error', 'Solo se registran cobros y recibos (esto es '||r.tabla||'/'||r.op||')');
  end if;
  v_payload := r.payload;
  if v_payload is null then
    return jsonb_build_object('ok', false, 'error', 'El rechazo no trae el contenido del cobro');
  end if;

  -- Identificadores BLINDADOS: registro_id y los ids del payload son TEXT
  -- (asi los guarda el connector). Un aviso corrupto no debe explotar con un
  -- error SQL crudo hacia la UI: se responde en español, sin resolver nada.
  -- (Lo cazo el demo del 17/08: un id sembrado con un caracter no-hex tiro
  -- "invalid input syntax for type uuid" pelado al snackbar.)
  begin
    if r.tabla = 'pagos' then
      v_pago_id := r.registro_id::uuid;
    else
      v_pago_id := nullif(v_payload->>'pago_id','')::uuid;
    end if;
  exception when others then
    return jsonb_build_object('ok', false,
      'error', 'El aviso está dañado: su identificador no es válido. '
               'Descartalo; si el cobro es real, cargalo a mano.');
  end;

  -- ── El PAGO ───────────────────────────────────────────────────────────────
  if r.tabla = 'pagos' then
    v_cuota := nullif(v_payload->>'cuota_id','')::uuid;
    v_monto := nullif(v_payload->>'monto_cordobas','')::numeric;
    select estado into v_est_antes from public.cuotas where id = v_cuota;
    if not exists (select 1 from public.pagos where id = v_pago_id) then
      -- Columnas explícitas, nada de populate_record: el payload viene del
      -- SQLite del device, donde los boolean son 0/1. Los NOT NULL sin valor
      -- caen a defaults seguros; el dinero (monto/vuelto/tasa) va tal cual.
      -- Los triggers de siempre corren TODOS: tenant coherente valida, el
      -- guard de sobrepago evalúa, recalcular_cuota aplica.
      insert into public.pagos (
        id, tenant_id, cuota_id, cobrador_id,
        monto_cordobas, metodo, notas, fecha_pago, client_local_id,
        moneda, monto_original, tasa_conversion, referencia,
        foto_comprobante_path, lat, lng,
        anulado, grupo_cobro, vuelto_cordobas, ocurrido_en,
        en_revision, revision_motivo
      ) values (
        v_pago_id,
        r.tenant_id,
        nullif(v_payload->>'cuota_id','')::uuid,
        coalesce(nullif(v_payload->>'cobrador_id','')::uuid, r.cobrador_id),
        nullif(v_payload->>'monto_cordobas','')::numeric,
        coalesce(nullif(v_payload->>'metodo',''), 'efectivo'),
        nullif(v_payload->>'notas',''),
        coalesce(nullif(v_payload->>'fecha_pago','')::timestamptz, r.ocurrido_en),
        nullif(v_payload->>'client_local_id',''),
        coalesce(nullif(v_payload->>'moneda',''), 'NIO'),
        coalesce(nullif(v_payload->>'monto_original','')::numeric,
                 nullif(v_payload->>'monto_cordobas','')::numeric),
        coalesce(nullif(v_payload->>'tasa_conversion','')::numeric, 1),
        nullif(v_payload->>'referencia',''),
        nullif(v_payload->>'foto_comprobante_path',''),
        nullif(v_payload->>'lat','')::double precision,
        nullif(v_payload->>'lng','')::double precision,
        coalesce(v_payload->>'anulado','0') in ('1','true'),
        nullif(v_payload->>'grupo_cobro','')::uuid,
        coalesce(nullif(v_payload->>'vuelto_cordobas','')::numeric, 0),
        coalesce(nullif(v_payload->>'ocurrido_en','')::timestamptz, r.ocurrido_en),
        false, null
      );
    end if;

    -- Qué decidió el guard (0218) sobre el pago que acaba de entrar.
    select case
             when p.anulado then 'anulado_duplicado'
             when p.en_revision then 'cuarentena'
             else 'cuenta'
           end into v_estado
      from public.pagos p where p.id = v_pago_id;

    -- Su recibo, si también fue rechazado (misma transacción del device).
    update public.sync_rechazos sr
       set resuelto = true, resuelto_en = now(), resuelto_por = auth.uid()
     where sr.tabla = 'recibos' and sr.resuelto = false
       and nullif(sr.payload->>'pago_id','')::uuid = v_pago_id
       and public.sync_rechazo_autorizado(sr.tenant_id)
    returning sr.payload into v_payload;
    -- (si había, v_payload ahora es el del recibo; si no, queda null por el
    --  INTO de un UPDATE sin filas)
  else
    -- tabla = 'recibos' suelto: su pago subió bien y el comprobante no
    -- (INV5: todo pago vivo tiene recibo — esto lo repara).
    if v_pago_id is null
       or not exists (select 1 from public.pagos where id = v_pago_id) then
      return jsonb_build_object('ok', false,
        'error', 'El pago de este recibo no está en el servidor');
    end if;
    v_estado := 'recibo_suelto';
    select cuota_id into v_cuota from public.pagos where id = v_pago_id;
  end if;

  -- ── El RECIBO, preservando el número IMPRESO ──────────────────────────────
  if v_payload is not null and (v_payload ? 'prefijo') then
    v_orig_pref := v_payload->>'prefijo';
    v_orig_corr := nullif(v_payload->>'correlativo','')::int;

    if not exists (select 1 from public.recibos
                    where id = nullif(v_payload->>'id','')::uuid) then
      -- El trigger 0215 va a IGNORAR el correlativo del insert y asignar el
      -- siguiente del contador — correcto para cobros nuevos, pero acá el
      -- papel YA está impreso con su número. Se inserta, y después se intenta
      -- restaurar el original; si está libre, se devuelve el contador.
      insert into public.recibos (
        id, tenant_id, pago_id, cobrador_id, prefijo, correlativo,
        numero_completo, created_at, anulado, ocurrido_en
      ) values (
        nullif(v_payload->>'id','')::uuid,
        r.tenant_id,
        v_pago_id,
        coalesce(nullif(v_payload->>'cobrador_id','')::uuid, r.cobrador_id),
        v_orig_pref,
        coalesce(v_orig_corr, 0),
        v_orig_pref||'-'||lpad(coalesce(v_orig_corr,0)::text,5,'0'),
        coalesce(nullif(v_payload->>'created_at','')::timestamptz, r.ocurrido_en),
        false,
        coalesce(nullif(v_payload->>'ocurrido_en','')::timestamptz, r.ocurrido_en)
      );

      select correlativo into v_new_corr
        from public.recibos where id = nullif(v_payload->>'id','')::uuid;

      if v_orig_corr is not null and v_orig_corr <> v_new_corr then
        begin
          update public.recibos
             set correlativo = v_orig_corr,
                 numero_completo = v_orig_pref||'-'||lpad(v_orig_corr::text,5,'0')
           where id = nullif(v_payload->>'id','')::uuid;
          -- Contador tras restaurar (audit 2026-08-19, hallazgo ALTA):
          -- · restauró un número VIEJO (debajo del contador): el que se quemó
          --   recién queda libre → devolverlo (solo si sigue siendo el tope,
          --   dentro de esta tx siempre lo es).
          -- · restauró un número POR ENCIMA del contador (recuperación en
          --   orden nuevo→viejo, el orden en que la bandeja lista): el
          --   contador DEBE saltar hasta cubrirlo. Sin esto quedaba debajo de
          --   números tomados y el próximo INSERT del prefijo chocaba 23505
          --   PARA SIEMPRE (la serie entera se brickeaba; todo cobro futuro
          --   subía sin recibo).
          if v_orig_corr < v_new_corr then
            update public.recibo_correlativos
               set ultimo = ultimo - 1
             where tenant_id = r.tenant_id and prefijo = v_orig_pref
               and ultimo = v_new_corr;
          else
            update public.recibo_correlativos
               set ultimo = greatest(ultimo, v_orig_corr)
             where tenant_id = r.tenant_id and prefijo = v_orig_pref;
          end if;
        exception when unique_violation then
          -- El número impreso ya lo tiene otro recibo: se queda con el nuevo.
          null;
        end;
      end if;
    end if;

    select numero_completo into v_num
      from public.recibos where id = nullif(v_payload->>'id','')::uuid;
  end if;

  -- ── Rastro en el historial de la CUOTA (audit de logs 2026-08-18) ─────────
  -- Antes de esto, un cobro recuperado no dejaba NADA en op_log: el admin
  -- registraba y el historial de la cuota quedaba mudo — el disparador del
  -- audit completo. Misma forma de diff que un cobro normal ({campos,resumen});
  -- diff es TEXT, no jsonb. Actor: quien tocó Registrar (super_admin → la
  -- convención del cliente: actor_id NULL + 'System Admin').
  if v_cuota is not null then
    select estado into v_est_desp from public.cuotas where id = v_cuota;
    select c.rol, c.nombre into v_rol, v_label
      from public.cobradores c where c.id = auth.uid();
    if v_rol = 'super_admin' then
      v_actor := null; v_label := 'System Admin';
    else
      v_actor := auth.uid(); v_label := coalesce(v_label, 'Admin');
    end if;
    insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad,
                               entidad_id, actor_id, actor_label, accion,
                               diff, ocurrido_en)
    values (gen_random_uuid(), r.tenant_id, gen_random_uuid(),
            'cobro_recuperado', 'cuotas', v_cuota, v_actor, v_label, 'update',
            jsonb_build_object(
              'campos', case when v_est_antes is distinct from v_est_desp
                then jsonb_build_array(jsonb_build_object(
                       'campo','estado','antes',v_est_antes,'despues',v_est_desp))
                else '[]'::jsonb end,
              'resumen', jsonb_strip_nulls(jsonb_build_object(
                'monto', v_monto,
                'recibo', v_num,
                'resultado', v_estado,
                'motivo', 'Recuperado de un rechazo de sincronización (bandeja)')))::text,
            now());
  end if;

  update public.sync_rechazos
     set resuelto = true, resuelto_en = now(), resuelto_por = auth.uid()
   where id = p_id;

  return jsonb_build_object(
    'ok', true, 'estado', v_estado, 'recibo', v_num);
exception
  -- El insert volvió a fallar: el rechazo queda SIN resolver y el motivo
  -- vuelve a la UI EN ESPAÑOL (el snackbar muestra este texto tal cual —
  -- nunca jerga SQL cruda).
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'codigo', sqlstate,
      'error', 'El aviso trae datos con formato inválido (posible corrupción). '
               'Descartalo y cargá el cobro a mano.');
  when foreign_key_violation then
    return jsonb_build_object('ok', false, 'codigo', sqlstate,
      'error', 'El cobro apunta a una cuota o un cliente que ya no existe en el servidor.');
  when check_violation then
    return jsonb_build_object('ok', false, 'codigo', sqlstate,
      'error', 'El cobro no pasa una validación del negocio (montos o empresa incoherentes).');
  when unique_violation then
    return jsonb_build_object('ok', false, 'codigo', sqlstate,
      'error', 'Ya existe un registro con ese identificador.');
  when others then
    return jsonb_build_object('ok', false, 'codigo', sqlstate,
      'error', 'Error del servidor ('||sqlstate||'): '||sqlerrm);
end $fn$;

-- ══ §4 (mismo CREATE que §2 abajo usa de base): guard de INSERT con rastro ══
CREATE OR REPLACE FUNCTION public.pagos_guard_sobrepago_trg()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp' SET "TimeZone" TO 'UTC'
AS $function$
declare
  v_total_a_cobrar numeric(10,2);
  v_ya_pagado      numeric(10,2);
  v_gemelo         uuid;
begin
  if new.anulado then return new; end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(new.cuota_id);
  if v_total_a_cobrar is null then return new; end if;

  -- Excluye anulados Y en_revision (predicado canónico). El `p.id <> new.id`
  -- es por el UPSERT de PowerSync (reintento del mismo pago).
  select coalesce(sum(p.monto_cordobas), 0)
    into v_ya_pagado
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id;

  if v_ya_pagado + new.monto_cordobas <= v_total_a_cobrar + 0.01 then
    return new;  -- no excede: el 99,9%.
  end if;

  -- Excede. ¿Copia EXACTA (mismo monto + día)? → auto-anula (como 0214).
  select p.id into v_gemelo
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id
     and round(p.monto_cordobas * 100) = round(new.monto_cordobas * 100)
     and p.fecha_pago::date = new.fecha_pago::date
   order by p.fecha_pago limit 1;

  if v_gemelo is not null then
    new.anulado          := true;
    new.anulado_en       := now();
    new.anulado_por      := null;
    new.motivo_anulacion := coalesce(new.motivo_anulacion,
      'Duplicado automático: ya existe un pago idéntico en esta cuota ('||v_gemelo||')');
    -- Audit 2026-08-19: el auto-anulado era SILENCIO TOTAL (ni op_log ni
    -- pantalla; el cobrador ni lo ve porque su bucket filtra anulados).
    -- Rastro en el historial de la CUOTA, como todo cambio de dinero.
    insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad,
                               entidad_id, actor_id, actor_label, accion,
                               diff, ocurrido_en)
    values (gen_random_uuid(), new.tenant_id, gen_random_uuid(),
            'duplicado_auto_anulado', 'cuotas', new.cuota_id, null, 'Sistema',
            'update',
            jsonb_build_object(
              'campos', '[]'::jsonb,
              'resumen', jsonb_build_object(
                'monto', new.monto_cordobas,
                'pago_duplicado', new.id,
                'pago_original', v_gemelo,
                'motivo', 'Cobro idéntico duplicado (mismo monto y día), '
                          'anulado automáticamente al sincronizar'))::text,
            now());
    return new;
  end if;

  -- Excede pero NO es copia exacta → CUARENTENA (antes: return new = contaba).
  new.en_revision    := true;
  new.revision_motivo := coalesce(new.revision_motivo,
    'Sobrepago: excede el total de la cuota. Requiere decidir cuál cobro es el verdadero.');
  return new;
end $function$;

-- ══ §2: guard de sobrepago en UPDATE ════════════════════════════════════════
-- Editar monto, mover de cuota o sacar de cuarentena re-evalúa el estado
-- RESULTANTE. Si excede el total de la cuota: en_revision = true (vuelve a la
-- bandeja con motivo). Nunca rechaza. `elegirCobroVerdadero` anula los
-- perdedores ANTES de des-encuarentenar al ganador (verificado en
-- pagos_repo.dart) y la cola de PowerSync sube en orden → la resolución
-- normal pasa limpia; solo re-marca si el ganador POR SÍ SOLO excede (el
-- caso F1 del audit, que antes quedaba invisible).
create or replace function public.pagos_guard_sobrepago_update_trg()
 returns trigger language plpgsql security definer
 set search_path to 'public','pg_temp' set "TimeZone" to 'UTC'
as $function$
declare
  v_total_a_cobrar numeric(10,2);
  v_ya_pagado      numeric(10,2);
begin
  if new.anulado then return new; end if;        -- anular siempre pasa
  if new.en_revision then return new; end if;    -- sigue marcado: ok

  v_total_a_cobrar := public.cuota_total_a_cobrar(new.cuota_id);
  if v_total_a_cobrar is null then return new; end if;

  select coalesce(sum(p.monto_cordobas), 0)
    into v_ya_pagado
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id;

  if v_ya_pagado + new.monto_cordobas <= v_total_a_cobrar + 0.01 then
    return new;
  end if;

  new.en_revision     := true;
  new.revision_motivo := 'Sobrepago al actualizar: con este cambio la cuota '
    || 'queda cobrada por encima de su total. Requiere decidir cuál cobro '
    || 'es el verdadero o corregir el monto.';
  return new;
end $function$;

drop trigger if exists trg_pagos_guard_sobrepago_update on public.pagos;
create trigger trg_pagos_guard_sobrepago_update
  before update of monto_cordobas, cuota_id, en_revision, anulado
  on public.pagos
  for each row execute function public.pagos_guard_sobrepago_update_trg();

-- ══ §3: el recibo de un pago nacido anulado nace anulado ════════════════════
create or replace function public.recibos_guard_pago_anulado_trg()
 returns trigger language plpgsql security definer
 set search_path to 'public','pg_temp'
as $function$
begin
  if new.anulado then return new; end if;
  if exists (select 1 from public.pagos p
              where p.id = new.pago_id and p.anulado = true) then
    new.anulado    := true;
    new.anulado_en := coalesce(new.anulado_en, now());
    -- recibos_anulacion_coherencia exige anulado_por (sin válvula automática
    -- como la de pagos): se atribuye al anulador del pago o, si fue anulación
    -- automática (anulado_por NULL), al cobrador emisor del recibo.
    new.anulado_por := coalesce(new.anulado_por,
      (select p.anulado_por from public.pagos p where p.id = new.pago_id),
      new.cobrador_id);
  end if;
  return new;
end $function$;

drop trigger if exists trg_recibos_guard_pago_anulado on public.recibos;
create trigger trg_recibos_guard_pago_anulado
  before insert on public.recibos
  for each row execute function public.recibos_guard_pago_anulado_trg();

-- Retroactivo: anular recibos vivos que respaldan pagos anulados (el camino
-- automático de 0214/0218 los dejaba vigentes y reimprimibles).
update public.recibos r
   set anulado = true, anulado_en = now(),
       anulado_por = coalesce(p.anulado_por, r.cobrador_id)
  from public.pagos p
 where p.id = r.pago_id and p.anulado = true
   and r.anulado = false;

commit;
