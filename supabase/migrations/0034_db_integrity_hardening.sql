-- DB Integrity Hardening — Sprint Día 1
--
-- Cierra 6 bugs detectados en el audit de pre-producción:
--   R2  — storage_write_comprobantes solo strippa '.jpg' del path para
--          extraer el pago_id, pero el bucket acepta jpeg/png/webp.
--          Uploads de PNG/WEBP nunca pasan el EXISTS y son rechazados.
--          Fix: regex que cubre las 3 extensiones.
--   R16 — propagate_cobrador_id_from_cliente sobreescribe el cobrador_id
--          de cuotas históricas (pagadas/anuladas) cuando reasignás un
--          cliente. Rompe reportes "cobros por cobrador" del pasado.
--          Fix: filtrar por estado in ('pendiente','parcial').
--   R17 — actualizar_notificaciones_mora corre vía cron como postgres.
--          Hoy funciona porque postgres tiene BYPASSRLS, pero la dependencia
--          es implícita. Fix: SET LOCAL row_security = off explícito.
--   R18 — cron de mora escanea cuotas filtrando por estado+fecha_venc, pero
--          no hay índice que lo cubra. A 50k cuotas/tenant escanea full
--          table todas las noches. Fix: índice parcial.
--   R19 — pagos.client_local_id es UNIQUE GLOBAL. Dos tenants pueden
--          generar el mismo UUID v4 (astronómicamente raro pero
--          deterministic possible si se manipula). Fix: UNIQUE
--          (tenant_id, client_local_id). Idem recibos y cargos_extra.
--   R20 — set_tenant_modulo no escribe a audit_log. Toggle de módulos
--          es operación sensible cross-tenant que debería tener trail
--          como las demás RPCs de super_admin (set_cobrador_activo,
--          set_cobrador_rol, audit_reset_password).
--          Fix: INSERT a audit_log en la función.
--
-- NOTA: R1 (pagos_insert_propio cross-cobrador in-tenant) NO se incluye
-- a propósito. La policy actual es un trade-off documentado en la
-- migración 0025 para soportar el caso "cobro offline pre-reasignación".
-- Restringirla rompe ese use case real.


-- =========================================================================
-- R2: storage policy — soportar JPG, PNG, WEBP
-- =========================================================================
-- regexp_replace strippa cualquier extensión (.jpg/.jpeg/.png/.webp,
-- case-insensitive). El path tiene shape {tenant}/comp/{pago_id}.ext

drop policy if exists "storage_write_comprobantes_select_y_insert"
  on storage.objects;
create policy "storage_write_comprobantes_select_y_insert"
  on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = regexp_replace(
                 split_part(name, '/', 3),
                 '\.(jpe?g|png|webp)$',
                 '',
                 'i'
               )
           and cobrador_id = auth.uid()
      )
    )
  );

drop policy if exists "storage_update_comprobantes" on storage.objects;
create policy "storage_update_comprobantes" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = regexp_replace(
                 split_part(name, '/', 3),
                 '\.(jpe?g|png|webp)$',
                 '',
                 'i'
               )
           and cobrador_id = auth.uid()
      )
    )
  );


-- =========================================================================
-- R16: propagate_cobrador_id_from_cliente — solo cuotas en
-- pendiente/parcial. Las pagadas/anuladas mantienen el cobrador_id
-- histórico (quién las cobró), igual que pagos y recibos.
-- =========================================================================

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id;

    -- ANTES: update TODAS las cuotas (corrompía historial).
    -- AHORA: solo las cuotas operativas. Las pagadas/anuladas
    --        preservan el cobrador_id del momento del pago.
    update public.cuotas
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and estado in ('pendiente','parcial');

    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;

    update public.cargos_extra
       set cobrador_id = new.cobrador_id
     where cuota_id in (
       select id from public.cuotas
        where cliente_id = new.id
          and estado in ('pendiente','parcial')
     );

    -- pagos / recibos NO se propagan: snapshot histórico inmutable.
  end if;
  return new;
end;
$$;


-- =========================================================================
-- R17: actualizar_notificaciones_mora — set local row_security off
-- explícito. NO usa BYPASSRLS implícito de postgres: queremos que la
-- dependencia sea explícita en código.
--
-- Importante: `row_security = off` NO bypassa silenciosamente — si el
-- owner del function pierde BYPASSRLS, la query con `row_security off`
-- raisea error explícito en vez de devolver 0 rows silenciosamente.
-- Eso es mejor que el comportamiento anterior (auth.uid() NULL pasaba
-- por policy y devolvía 0 rows sin error, masking del bug en cron).
-- =========================================================================

create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- Necesitamos insertar en notificaciones_mora con cobrador_id=NULL
  -- como sistema. La policy notif_write_admin no nos deja porque
  -- auth.uid() es null en cron. SECURITY DEFINER nos da el rol de
  -- postgres (que tiene BYPASSRLS por default), pero explicitamos
  -- row_security=off para que no haya sorpresas si la función se
  -- re-ejecuta con un owner sin BYPASSRLS.
  set local row_security = off;

  insert into public.notificaciones_mora (
    tenant_id, cuota_id, cliente_id, cobrador_id,
    dias_mora, monto_adeudado
  )
  select
    cu.tenant_id,
    cu.id,
    cu.cliente_id,
    cu.cobrador_id,
    greatest((current_date - cu.fecha_vencimiento) - v_dias_gracia, 0),
    cu.monto - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
  on conflict (cuota_id) do update
    set dias_mora      = excluded.dias_mora,
        monto_adeudado = excluded.monto_adeudado;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;


-- =========================================================================
-- R18: índice parcial para el cron de mora.
-- Cuota query: WHERE tenant_id=? AND estado IN ('pendiente','parcial')
--              AND (fecha_venc + gracia) < current_date
-- El índice cubre tenant_id + estado + fecha_vencimiento; el WHERE
-- predicado parcial limita el tamaño del índice a las cuotas operativas
-- (no incluye pagadas/anuladas que son la mayoría a escala).
-- =========================================================================

create index if not exists cuotas_cron_mora_idx
  on public.cuotas (tenant_id, fecha_vencimiento)
  where estado in ('pendiente','parcial');


-- =========================================================================
-- R19: client_local_id UNIQUE global → UNIQUE per-tenant.
-- Si dos tenants generan el mismo UUID v4 (raro pero deterministic
-- possible bajo manipulación), el segundo tenant queda bloqueado del
-- sync. Cambiamos a UNIQUE compuesto.
--
-- Pre-flight: verificamos que no haya duplicados existentes en
-- (tenant_id, client_local_id) antes de tocar las constraints. Sin
-- esto, el ADD CONSTRAINT falla con error críptico de Postgres y la
-- transacción entera rollbackea sin pista clara de qué row es el
-- problema. Astronómicamente improbable con UUID v4, pero el guard
-- lo hace explícito.
--
-- Idempotency: los ADD CONSTRAINT van dentro de DO blocks que checkean
-- pg_constraint. Sin esto, un segundo run de la migración fallaría
-- porque ADD CONSTRAINT no tiene IF NOT EXISTS en Postgres.
-- =========================================================================

-- Pre-flight: detectar duplicados antes de cambiar constraints.
do $$
declare
  v_dup_pagos int;
  v_dup_recibos int;
  v_dup_cargos int;
begin
  select count(*) into v_dup_pagos
    from (select tenant_id, client_local_id
            from public.pagos
           where client_local_id is not null
           group by tenant_id, client_local_id
          having count(*) > 1) d;

  select count(*) into v_dup_recibos
    from (select tenant_id, client_local_id
            from public.recibos
           where client_local_id is not null
           group by tenant_id, client_local_id
          having count(*) > 1) d;

  select count(*) into v_dup_cargos
    from (select tenant_id, client_local_id
            from public.cargos_extra
           where client_local_id is not null
           group by tenant_id, client_local_id
          having count(*) > 1) d;

  if v_dup_pagos > 0 or v_dup_recibos > 0 or v_dup_cargos > 0 then
    raise exception 'R19: hay duplicados de (tenant_id, client_local_id) — pagos=%, recibos=%, cargos_extra=%. Resolvelos antes de aplicar esta migración.',
      v_dup_pagos, v_dup_recibos, v_dup_cargos;
  end if;
end$$;

-- pagos
alter table public.pagos
  drop constraint if exists pagos_client_local_id_key;
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'pagos_tenant_client_local_id_key'
       and conrelid = 'public.pagos'::regclass
  ) then
    alter table public.pagos
      add constraint pagos_tenant_client_local_id_key
      unique (tenant_id, client_local_id);
  end if;
end$$;

-- recibos
alter table public.recibos
  drop constraint if exists recibos_client_local_id_key;
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'recibos_tenant_client_local_id_key'
       and conrelid = 'public.recibos'::regclass
  ) then
    alter table public.recibos
      add constraint recibos_tenant_client_local_id_key
      unique (tenant_id, client_local_id);
  end if;
end$$;

-- cargos_extra
alter table public.cargos_extra
  drop constraint if exists cargos_extra_client_local_id_key;
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'cargos_extra_tenant_client_local_id_key'
       and conrelid = 'public.cargos_extra'::regclass
  ) then
    alter table public.cargos_extra
      add constraint cargos_extra_tenant_client_local_id_key
      unique (tenant_id, client_local_id);
  end if;
end$$;


-- =========================================================================
-- R20: set_tenant_modulo escribe a audit_log.
-- Trail completo de qué módulo se prendió/apagó, en qué tenant, por
-- qué super_admin, cuándo. Consistente con set_cobrador_activo y
-- set_cobrador_rol que ya auditan.
-- =========================================================================

create or replace function public.set_tenant_modulo(
  p_tenant_id  uuid,
  p_modulo     text,
  p_habilitado boolean
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_es_base boolean;
  v_anterior boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede modificar el tenant System';
  end if;

  select es_base into v_es_base
  from public.modulos
  where codigo = p_modulo;

  if v_es_base is null then
    raise exception 'Módulo % no existe', p_modulo;
  end if;

  if v_es_base and not p_habilitado then
    raise exception 'Módulo % es base y no se puede deshabilitar', p_modulo;
  end if;

  -- Capturamos el valor anterior para el audit (puede ser null si es
  -- la primera vez que se setea — el módulo no estaba en la tabla).
  select habilitado into v_anterior
  from public.tenant_modulos
  where tenant_id = p_tenant_id and modulo_codigo = p_modulo;

  insert into public.tenant_modulos (
    tenant_id, modulo_codigo, habilitado, habilitado_en, habilitado_por
  ) values (
    p_tenant_id, p_modulo, p_habilitado, now(), auth.uid()
  )
  on conflict (tenant_id, modulo_codigo) do update
    set habilitado     = excluded.habilitado,
        habilitado_en  = excluded.habilitado_en,
        habilitado_por = excluded.habilitado_por;

  -- Audit trail. tenant_id apunta al tenant afectado (no al System
  -- del super_admin) para que el row aparezca en el detalle del
  -- tenant en el panel.
  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    p_tenant_id,
    'tenant_modulos',
    p_tenant_id,
    p_modulo,
    jsonb_build_object('habilitado', v_anterior),
    jsonb_build_object('habilitado', p_habilitado),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.set_tenant_modulo(uuid, text, boolean) from public;
grant execute on function public.set_tenant_modulo(uuid, text, boolean) to authenticated;
