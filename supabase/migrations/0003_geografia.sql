-- Geografía: catálogos que crecen con uso (estilo W del diseño).
-- Tres niveles jerárquicos: departamento → municipio → comunidad.
-- Vacíos al inicio. El admin agrega los que va usando.
-- Compartidos entre tenants (Nicaragua es Nicaragua para todos), por lo que
-- NO llevan tenant_id. RLS de lectura es permisiva; escritura sólo admin.

create table public.departamentos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  codigo text unique,
  created_at timestamptz not null default now()
);

create table public.municipios (
  id uuid primary key default gen_random_uuid(),
  departamento_id uuid not null references public.departamentos(id) on delete restrict,
  nombre text not null,
  created_at timestamptz not null default now(),
  unique (departamento_id, nombre)
);

create index on public.municipios (departamento_id);

create table public.comunidades (
  id uuid primary key default gen_random_uuid(),
  municipio_id uuid not null references public.municipios(id) on delete restrict,
  nombre text not null,
  created_at timestamptz not null default now(),
  unique (municipio_id, nombre)
);

create index on public.comunidades (municipio_id);

-- =========================================================================
-- Cliente: reemplazar `zona` (texto libre) con FK a comunidad + ref. textual
-- =========================================================================

-- Eliminamos `zona` (decisión: arrancar limpio, sin data legacy).
alter table public.clientes drop column zona;

-- FK opcional al catálogo: un cliente puede no tener comunidad asignada todavía.
alter table public.clientes add column comunidad_id uuid references public.comunidades(id);

-- Texto adicional para detalle local (ej. "Casa esquina del molino").
-- `direccion` ya existe — éste es complementario.
alter table public.clientes add column direccion_referencia text;

create index on public.clientes (tenant_id, comunidad_id);

-- =========================================================================
-- RLS — geo es lectura libre para usuarios autenticados, escritura sólo admin
-- =========================================================================

alter table public.departamentos enable row level security;
alter table public.municipios    enable row level security;
alter table public.comunidades   enable row level security;

create policy "geo_read_authenticated" on public.departamentos
  for select to authenticated using (true);

create policy "geo_read_authenticated" on public.municipios
  for select to authenticated using (true);

create policy "geo_read_authenticated" on public.comunidades
  for select to authenticated using (true);

-- Escritura: cualquier usuario autenticado puede AGREGAR (autocompletar+crear inline).
-- Borrado/edición se restringe a admins en una capa superior si hace falta.
create policy "geo_insert_authenticated" on public.departamentos
  for insert to authenticated with check (true);

create policy "geo_insert_authenticated" on public.municipios
  for insert to authenticated with check (true);

create policy "geo_insert_authenticated" on public.comunidades
  for insert to authenticated with check (true);
