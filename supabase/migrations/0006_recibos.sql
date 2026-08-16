-- Recibos: numeración offline por cobrador.
-- Cada cobrador tiene un prefijo único en su tenant ("COB-07", "PEDRO", etc.)
-- y un correlativo propio que incrementa offline. Resultado: "COB-07-00042".

-- =========================================================================
-- Cobrador: prefijo de recibos
-- =========================================================================

-- Nullable hasta que el admin lo asigne. La app móvil no permite imprimir
-- recibos hasta que el cobrador tenga prefijo asignado.
alter table public.cobradores add column prefijo_recibo text;

-- Único dentro del tenant (dos cobradores no comparten prefijo).
create unique index cobradores_prefijo_recibo_unique
  on public.cobradores (tenant_id, prefijo_recibo)
  where prefijo_recibo is not null;

-- Formato: solo letras mayúsculas, números y guiones. Sin espacios ni acentos.
alter table public.cobradores add constraint cobradores_prefijo_formato
  check (prefijo_recibo is null or prefijo_recibo ~ '^[A-Z0-9-]{2,16}$');

-- =========================================================================
-- Tabla recibos
-- =========================================================================

create table public.recibos (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  pago_id uuid not null unique references public.pagos(id) on delete cascade,
  cobrador_id uuid not null references public.cobradores(id),

  -- Snapshot del prefijo en el momento de emisión. Si el admin cambia el
  -- prefijo del cobrador después, los recibos antiguos no se renumeran.
  prefijo text not null,
  correlativo int not null check (correlativo > 0),
  numero_completo text not null,

  -- Tracking de impresión. Una sola fila puede imprimirse en ambos formatos
  -- y/o reimprimirse — el cobrador puede haber dañado el papel.
  impreso_en timestamptz,
  reimpresiones int not null default 0,
  ultimo_formato_mm int check (ultimo_formato_mm in (57, 80)),

  created_at timestamptz not null default now(),

  -- Idempotencia offline: el cliente genera este id antes de subir.
  client_local_id text unique
);

-- Cada cobrador tiene su propia secuencia: (cobrador, correlativo) único.
create unique index recibos_correlativo_por_cobrador
  on public.recibos (cobrador_id, correlativo);

-- Lookup por número completo (para búsqueda en panel admin).
create unique index recibos_numero_completo_por_tenant
  on public.recibos (tenant_id, numero_completo);

create index on public.recibos (tenant_id, cobrador_id, created_at desc);

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.recibos enable row level security;

create policy "tenant_isolation" on public.recibos
  for all using (tenant_id = public.current_tenant_id());

-- =========================================================================
-- PowerSync: denormalización para sync rules sin subqueries
-- =========================================================================

-- recibos.cobrador_id ya está en la tabla (no necesita denormalización extra).
-- El sync rule "por_cobrador" bajará: recibos WHERE cobrador_id = bucket.cobrador_id.
