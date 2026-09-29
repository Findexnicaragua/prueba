-- 0237 — La bandeja de rechazos se vuelve ACCIONABLE: un toque y el cobro
-- rechazado vuelve a entrar, evaluado por el guard del server.
--
-- Cierra el circuito que 0236 dejó a medias: el rechazo ya sube con su payload
-- completo, pero recuperarlo exigía SQL a mano (así se repusieron COL-00025 y
-- COL-00028). Ahora lo hace el admin desde "Cobros a revisar".
--
-- POR QUÉ un RPC SECURITY DEFINER y no un re-intento del device: todas las
-- clases de rechazo vigentes en `pagos` (RLS 42501, FK 23503, tenant 23514,
-- formato 22xxx) fallan IDÉNTICO si el mismo usuario reintenta el mismo
-- insert. El que puede destrabarlo es el admin — autoridad distinta, intención
-- humana. La EVALUACIÓN del dinero sigue siendo automática: el guard de
-- sobrepago (0218) decide si el pago cuenta, va a cuarentena (en_revision →
-- pantalla "Cobros a revisar") o se auto-anula como duplicado exacto. Este RPC
-- NO opina sobre plata: inserta y deja que las reglas de siempre decidan.

begin;

-- ── Gate interno compartido ─────────────────────────────────────────────────
-- ¿El caller puede operar sobre este rechazo? super_admin siempre; si no,
-- admin/cobranza DEL MISMO tenant. Un rechazo sin tenant (payload huérfano)
-- queda solo para super_admin.
create or replace function public.sync_rechazo_autorizado(p_tenant uuid)
returns boolean language sql stable security definer
set search_path to 'public'
as $fn$
  select public.is_super_admin()
      or (p_tenant is not null
          and p_tenant = public.current_tenant_id()
          and public.is_admin_or_cobranza());
$fn$;

-- ── recibos_huecos: gate por tenant (corrige 0236) ──────────────────────────
-- La versión de 0236 devolvía TODOS los tenants a cualquier autenticado
-- (metadata: nombres de tenant, prefijos, tamaños de hueco). Ahora:
-- super_admin ve todo; admin/cobranza solo su tenant; el resto, nada.
create or replace function public.recibos_huecos()
returns table (
  tenant text, prefijo text, cobrador text,
  desde int, hasta int, faltan int,
  ok_antes timestamptz, ok_despues timestamptz
)
language sql stable security definer
set search_path to 'public'
as $fn$
  with r as (
    select t.id as tenant_id, t.nombre as tenant, r.prefijo, r.correlativo,
           r.created_at,
           (r.created_at::time <> '00:00:00') as real_now,
           lag(r.correlativo) over w as prev_corr,
           lag(r.created_at)  over w as prev_at,
           lag(r.cobrador_id) over w as prev_cob,
           lag(r.created_at::time <> '00:00:00') over w as prev_real
    from public.recibos r
    join public.tenants t on t.id = r.tenant_id
    window w as (partition by r.tenant_id, r.prefijo order by r.correlativo)
  )
  select r.tenant, r.prefijo, coalesce(co.nombre, '?'),
         r.prev_corr + 1, r.correlativo - 1, (r.correlativo - r.prev_corr - 1),
         r.prev_at, r.created_at
  from r left join public.cobradores co on co.id = r.prev_cob
  where r.correlativo - r.prev_corr > 1
    and r.real_now and r.prev_real
    and (public.is_super_admin()
         or (r.tenant_id = public.current_tenant_id()
             and public.is_admin_or_cobranza()))
  order by (r.correlativo - r.prev_corr - 1) desc, r.tenant, r.prefijo;
$fn$;

-- ── Lista enriquecida para la pantalla ──────────────────────────────────────
-- El payload trae cuota_id, no el nombre del cliente: el JOIN se hace acá
-- (definer) para que la UI no dependa del RLS de lectura de cada tabla.
-- DROP: agregar la columna pago_id cambia la firma de retorno y
-- CREATE OR REPLACE no puede (error 42P13). Solo la llama la app.
drop function if exists public.sync_rechazos_pendientes();
create function public.sync_rechazos_pendientes()
returns table (
  id uuid, tabla text, registro_id text, codigo text, mensaje text,
  ocurrido_en timestamptz, cobrador text,
  cliente_codigo text, cliente_nombre text,
  monto numeric, recibo_numero text,
  -- Para recibos: el id de su pago. La UI lo usa para ATAR el recibo a su
  -- cobro pendiente (sin boton propio; se resuelve junto con el).
  pago_id text
)
language sql stable security definer
set search_path to 'public'
as $fn$
  select sr.id, sr.tabla, sr.registro_id, sr.codigo, sr.mensaje,
         sr.ocurrido_en,
         co.nombre as cobrador,
         cl.codigo as cliente_codigo,
         cl.nombre as cliente_nombre,
         case when sr.tabla = 'pagos'
              then nullif(sr.payload->>'monto_cordobas','')::numeric
         end as monto,
         case
           when sr.tabla = 'recibos' then
             (sr.payload->>'prefijo') || '-' ||
             lpad(coalesce(sr.payload->>'correlativo','0'), 5, '0')
         end as recibo_numero,
         case when sr.tabla = 'recibos' then sr.payload->>'pago_id'
         end as pago_id
  from public.sync_rechazos sr
  left join public.cobradores co on co.id = sr.cobrador_id
  left join public.cuotas cu
         on sr.tabla = 'pagos'
        and cu.id = nullif(sr.payload->>'cuota_id','')::uuid
  left join public.clientes cl on cl.id = cu.cliente_id
  where sr.resuelto = false
    and public.sync_rechazo_autorizado(sr.tenant_id)
  order by sr.ocurrido_en desc;
$fn$;

-- ── Registrar: el cobro rechazado vuelve a entrar ───────────────────────────
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
          -- El número que consumió el contador quedó libre: devolverlo, solo
          -- si sigue siendo el tope (dentro de esta tx siempre lo es).
          update public.recibo_correlativos
             set ultimo = ultimo - 1
           where tenant_id = r.tenant_id and prefijo = v_orig_pref
             and ultimo = v_new_corr;
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

revoke all on function public.sync_rechazo_autorizado(uuid) from public;
revoke all on function public.sync_rechazos_pendientes() from public;
revoke all on function public.sync_rechazo_registrar(uuid) from public;
grant execute on function public.sync_rechazo_autorizado(uuid) to authenticated;
grant execute on function public.sync_rechazos_pendientes() to authenticated;
grant execute on function public.sync_rechazo_registrar(uuid) to authenticated;

commit;

-- Verificación (aparte):
--   select proname from pg_proc where proname like 'sync_rechazo%';
--   -- 3 funciones. E2E: sembrar un rechazo de prueba en Test Tenant,
--   -- registrar con el JWT de un admin TT, verificar guard + número de recibo.
