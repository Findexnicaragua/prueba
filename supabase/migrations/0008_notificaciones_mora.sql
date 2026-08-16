-- Notificaciones de mora: una fila por cuota que pasó el periodo de gracia
-- sin completarse. Generadas por un cron diario (ver 0009).
-- Visibles a admin, admin_cobranza y al cobrador asignado al cliente.

create table public.notificaciones_mora (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),

  -- Una notificación por cuota. Si se paga y vuelve a caer en mora
  -- (caso raro), se reactiva en lugar de duplicar.
  cuota_id uuid not null unique references public.cuotas(id) on delete cascade,

  cliente_id uuid not null references public.clientes(id),
  -- Denormalizado para sync del cobrador.
  cobrador_id uuid references public.cobradores(id),

  dias_mora int not null check (dias_mora >= 0),
  monto_adeudado numeric(10,2) not null check (monto_adeudado >= 0),

  generada_en timestamptz not null default now(),

  -- Tracking global (no por usuario): cuando alguien la marca como vista,
  -- queda marcada para todos. Suficiente para Fase 4.
  vista_en timestamptz,
  vista_por uuid references public.cobradores(id),

  -- Se cierra automáticamente cuando la cuota llega a estado='pagada'
  -- (ver trigger más abajo).
  resuelta_en timestamptz,
  resuelta_por uuid references public.cobradores(id)
);

create index on public.notificaciones_mora (tenant_id, cobrador_id, resuelta_en);
create index on public.notificaciones_mora (tenant_id, generada_en desc);

-- =========================================================================
-- Trigger: cuando una cuota pasa a estado='pagada', resolver su notificación
-- =========================================================================

create or replace function public.resolver_notificacion_al_pagar()
returns trigger language plpgsql as $$
begin
  if new.estado = 'pagada' and old.estado <> 'pagada' then
    update public.notificaciones_mora
       set resuelta_en = now()
     where cuota_id = new.id
       and resuelta_en is null;
  end if;
  return new;
end;
$$;

create trigger trg_resolver_notificacion_al_pagar
  after update on public.cuotas
  for each row execute function public.resolver_notificacion_al_pagar();

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.notificaciones_mora enable row level security;

create policy "tenant_isolation" on public.notificaciones_mora
  for all using (tenant_id = public.current_tenant_id());
