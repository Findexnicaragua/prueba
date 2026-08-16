-- Audit log para cambios sensibles (settings, reasignaciones, anulaciones).
-- Append-only: nadie hace UPDATE/DELETE; los triggers son la única fuente.

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  tabla text not null,
  registro_id uuid not null,
  campo text,                   -- columna que cambió (null si es alta/baja completa)
  valor_anterior jsonb,
  valor_nuevo jsonb,
  user_id uuid,                 -- auth.uid() del momento; null si fue el cron
  user_rol text,                -- snapshot del rol al momento
  created_at timestamptz not null default now()
);

create index on public.audit_log (tenant_id, tabla, created_at desc);
create index on public.audit_log (tenant_id, registro_id, created_at desc);
create index on public.audit_log (tenant_id, user_id, created_at desc);

-- =========================================================================
-- RLS: lectura sólo admin; inserción sólo vía trigger (SECURITY DEFINER)
-- =========================================================================

alter table public.audit_log enable row level security;

create policy "audit_read_admin" on public.audit_log
  for select using (tenant_id = public.current_tenant_id() and public.is_admin());

-- No hay policy para INSERT/UPDATE/DELETE → bloqueados para usuarios. Sólo
-- las funciones SECURITY DEFINER del sistema escriben.

-- =========================================================================
-- Helper de registro
-- =========================================================================

create or replace function public.audit_registrar(
  p_tenant_id uuid,
  p_tabla text,
  p_registro_id uuid,
  p_campo text,
  p_valor_anterior jsonb,
  p_valor_nuevo jsonb
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo,
    user_id, user_rol
  ) values (
    p_tenant_id, p_tabla, p_registro_id, p_campo,
    p_valor_anterior, p_valor_nuevo,
    auth.uid(), public.current_user_rol()
  );
end;
$$;

-- =========================================================================
-- Triggers
-- =========================================================================

-- 1. settings: cualquier cambio en `valor`.
create or replace function public.audit_settings_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.valor is distinct from old.valor then
    perform public.audit_registrar(
      new.tenant_id, 'settings', new.id, new.clave,
      to_jsonb(old.valor), to_jsonb(new.valor)
    );
  end if;
  return new;
end;
$$;

create trigger trg_audit_settings
  after update on public.settings
  for each row execute function public.audit_settings_trg();

-- 2. clientes: reasignación de cobrador.
create or replace function public.audit_clientes_cobrador_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    perform public.audit_registrar(
      new.tenant_id, 'clientes', new.id, 'cobrador_id',
      to_jsonb(old.cobrador_id), to_jsonb(new.cobrador_id)
    );
  end if;
  return new;
end;
$$;

create trigger trg_audit_clientes_cobrador
  after update of cobrador_id on public.clientes
  for each row execute function public.audit_clientes_cobrador_trg();

-- 3. pagos: anulación.
create or replace function public.audit_pagos_anulacion_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.anulado = true and old.anulado = false then
    perform public.audit_registrar(
      new.tenant_id, 'pagos', new.id, 'anulado',
      jsonb_build_object('monto', old.monto_cordobas, 'metodo', old.metodo),
      jsonb_build_object('anulado_por', new.anulado_por, 'motivo', new.motivo_anulacion)
    );
  end if;
  return new;
end;
$$;

create trigger trg_audit_pagos_anulacion
  after update of anulado on public.pagos
  for each row execute function public.audit_pagos_anulacion_trg();

-- 4. recibos: anulación.
create or replace function public.audit_recibos_anulacion_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.anulado = true and old.anulado = false then
    perform public.audit_registrar(
      new.tenant_id, 'recibos', new.id, 'anulado',
      jsonb_build_object('numero', old.numero_completo),
      jsonb_build_object('anulado_por', new.anulado_por)
    );
  end if;
  return new;
end;
$$;

create trigger trg_audit_recibos_anulacion
  after update of anulado on public.recibos
  for each row execute function public.audit_recibos_anulacion_trg();

-- 5. cuotas: anulación.
create or replace function public.audit_cuotas_anulacion_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.estado = 'anulada' and old.estado <> 'anulada' then
    perform public.audit_registrar(
      new.tenant_id, 'cuotas', new.id, 'estado',
      to_jsonb(old.estado), to_jsonb(new.estado)
    );
  end if;
  return new;
end;
$$;

create trigger trg_audit_cuotas_anulacion
  after update of estado on public.cuotas
  for each row execute function public.audit_cuotas_anulacion_trg();
