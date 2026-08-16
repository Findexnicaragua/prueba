-- Fixes técnicos identificados en auditoría:
--   1. settings sin PK 'id' (PowerSync exige id text)
--   2. settings.valor jsonb → text serializado (compatibilidad cliente SQLite)
--   3. pagos.recibo_numero legacy (la info vive en tabla recibos ahora)
--   4. setting_number sin SECURITY DEFINER (RLS bloquea lectura)
--   5. pg_cron en UTC sin ajuste (Nicaragua = UTC-6)
--   6. ON DELETE en notificaciones_mora.cobrador_id

-- =========================================================================
-- 1 + 2. settings: PK id + valor como text
-- =========================================================================

-- Soltamos la PK compuesta. Reconfiguramos como (id PK, (tenant_id, clave) UNIQUE).
alter table public.settings drop constraint settings_pkey;
alter table public.settings add column id uuid not null default gen_random_uuid();
alter table public.settings add primary key (id);
alter table public.settings add constraint settings_tenant_clave_unique unique (tenant_id, clave);

-- valor jsonb → text. SQLite local de PowerSync no maneja jsonb nativo;
-- guardamos JSON serializado y el cliente parsea según `tipo`.
alter table public.settings alter column valor type text using valor::text;

-- =========================================================================
-- 3. Eliminar pagos.recibo_numero (legacy de 0001, ahora vive en tabla recibos)
-- =========================================================================

alter table public.pagos drop column recibo_numero;

-- =========================================================================
-- 4. setting_number con SECURITY DEFINER + search_path explícito
-- =========================================================================

create or replace function public.setting_number(p_tenant_id uuid, p_clave text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select (valor)::numeric
       from public.settings
      where tenant_id = p_tenant_id and clave = p_clave),
    p_default
  )
$$;

-- =========================================================================
-- 5. Cron en TZ correcta (Nicaragua = America/Managua = UTC-6, sin DST)
-- =========================================================================

-- Reschedule: día 1 00:05 hora Nicaragua = día 1 06:05 UTC.
select cron.unschedule('generar_cuotas_mensual');
select cron.schedule(
  'generar_cuotas_mensual',
  '5 6 1 * *',
  $$
    select public.generar_cuotas_mes(t.id, current_date)
    from public.tenants t;
  $$
);

-- Diario 06:00 Nicaragua = 12:00 UTC.
select cron.unschedule('actualizar_notificaciones_mora_diario');
select cron.schedule(
  'actualizar_notificaciones_mora_diario',
  '0 12 * * *',
  $$
    select public.actualizar_notificaciones_mora(t.id)
    from public.tenants t;
  $$
);

-- =========================================================================
-- 6. ON DELETE SET NULL en notificaciones_mora.cobrador_id + vista_por + resuelta_por
-- =========================================================================

alter table public.notificaciones_mora
  drop constraint notificaciones_mora_cobrador_id_fkey,
  add constraint notificaciones_mora_cobrador_id_fkey
    foreign key (cobrador_id) references public.cobradores(id) on delete set null;

alter table public.notificaciones_mora
  drop constraint notificaciones_mora_vista_por_fkey,
  add constraint notificaciones_mora_vista_por_fkey
    foreign key (vista_por) references public.cobradores(id) on delete set null;

alter table public.notificaciones_mora
  drop constraint notificaciones_mora_resuelta_por_fkey,
  add constraint notificaciones_mora_resuelta_por_fkey
    foreign key (resuelta_por) references public.cobradores(id) on delete set null;
