-- Schema inicial: ISP Billing
-- Multi-tenant desde el inicio (cada ISP cliente = un tenant).
-- Pensado para sync con PowerSync: PKs uuid, columnas de auditoría, `client_local_id`
-- en tablas de escritura intensiva para idempotencia offline.

create extension if not exists "pgcrypto";

-- =========================================================================
-- Tenants e identidad
-- =========================================================================

create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  created_at timestamptz not null default now()
);

-- Cobradores = empleados que cobran en campo. Linkean a auth.users de Supabase.
create table public.cobradores (
  id uuid primary key references auth.users(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id),
  nombre text not null,
  telefono text,
  rol text not null default 'cobrador' check (rol in ('admin','cobrador')),
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create index on public.cobradores (tenant_id);

-- =========================================================================
-- Catálogo: planes de servicio (5MB, 10MB, TV básico, combo, etc.)
-- =========================================================================

create table public.planes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  nombre text not null,
  tipo text not null check (tipo in ('internet','tv','combo')),
  precio_mensual numeric(10,2) not null,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

-- =========================================================================
-- Clientes finales del ISP
-- =========================================================================

create table public.clientes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  cobrador_id uuid references public.cobradores(id),
  nombre text not null,
  cedula text,
  telefono text,
  direccion text,
  zona text,
  latitud double precision,
  longitud double precision,
  foto_path text,                  -- ruta en Supabase Storage
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.clientes (tenant_id, cobrador_id);
create index on public.clientes (tenant_id, activo);

-- =========================================================================
-- Contratos: un cliente puede tener N contratos (uno por servicio activo)
-- =========================================================================

create table public.contratos (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  plan_id uuid not null references public.planes(id),
  dia_corte int not null check (dia_corte between 1 and 28),
  fecha_inicio date not null,
  fecha_fin date,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create index on public.contratos (tenant_id, cliente_id);

-- =========================================================================
-- Cuotas: cobros mensuales generados por contrato
-- =========================================================================

create table public.cuotas (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  cliente_id uuid not null references public.clientes(id),
  periodo date not null,                        -- primer día del mes que cubre
  fecha_vencimiento date not null,              -- ajustada si cae en domingo
  monto numeric(10,2) not null,
  estado text not null default 'pendiente'
    check (estado in ('pendiente','pagada','vencida','anulada')),
  created_at timestamptz not null default now()
);

create unique index on public.cuotas (contrato_id, periodo);
create index on public.cuotas (tenant_id, cliente_id, estado);
create index on public.cuotas (tenant_id, fecha_vencimiento);

-- =========================================================================
-- Pagos: cada vez que un cobrador cobra una cuota
-- =========================================================================

create table public.pagos (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  cuota_id uuid not null references public.cuotas(id),
  cobrador_id uuid not null references public.cobradores(id),
  monto numeric(10,2) not null,
  metodo text not null default 'efectivo'
    check (metodo in ('efectivo','transferencia','tarjeta')),
  recibo_numero text,
  notas text,
  fecha_pago timestamptz not null default now(),
  -- Idempotencia para sync offline: la app genera este id antes de subir
  client_local_id text unique
);

create index on public.pagos (tenant_id, cobrador_id, fecha_pago);
create index on public.pagos (tenant_id, cuota_id);

-- =========================================================================
-- RLS — aislamiento por tenant
-- =========================================================================

alter table public.tenants    enable row level security;
alter table public.cobradores enable row level security;
alter table public.planes     enable row level security;
alter table public.clientes   enable row level security;
alter table public.contratos  enable row level security;
alter table public.cuotas     enable row level security;
alter table public.pagos      enable row level security;

create or replace function public.current_tenant_id() returns uuid
language sql stable security definer as $$
  select tenant_id from public.cobradores where id = auth.uid()
$$;

create policy "tenant_isolation" on public.clientes
  for all using (tenant_id = public.current_tenant_id());

create policy "tenant_isolation" on public.contratos
  for all using (tenant_id = public.current_tenant_id());

create policy "tenant_isolation" on public.cuotas
  for all using (tenant_id = public.current_tenant_id());

create policy "tenant_isolation" on public.pagos
  for all using (tenant_id = public.current_tenant_id());

create policy "tenant_isolation" on public.planes
  for all using (tenant_id = public.current_tenant_id());

create policy "tenant_isolation_cobradores" on public.cobradores
  for select using (tenant_id = public.current_tenant_id());
