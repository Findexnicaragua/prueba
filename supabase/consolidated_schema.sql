-- ========================================================
-- FINDEX CONSOLIDATED DATABASE SCHEMA
-- Generated on 2026-08-15 17:58:34
-- ========================================================

-- >>> Migration: 0001_init.sql <<<
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


-- >>> Migration: 0002_denormalize_cobrador.sql <<<
-- Denormalizar `cobrador_id` y mantenerlo sincronizado.
--
-- PowerSync sync rules NO soportan subqueries ni JOINs. Para poder filtrar
-- contratos/cuotas por el cobrador asignado, necesitamos la columna en cada
-- tabla, replicada desde clientes.cobrador_id mediante triggers.

-- 1. Añadir columnas
alter table public.contratos add column cobrador_id uuid references public.cobradores(id);
alter table public.cuotas    add column cobrador_id uuid references public.cobradores(id);

create index on public.contratos (tenant_id, cobrador_id);
create index on public.cuotas    (tenant_id, cobrador_id);

-- 2. Backfill (las tablas están vacías ahora mismo, pero por si acaso)
update public.contratos c
set cobrador_id = cl.cobrador_id
from public.clientes cl
where c.cliente_id = cl.id;

update public.cuotas cu
set cobrador_id = cl.cobrador_id
from public.clientes cl
where cu.cliente_id = cl.id;

-- 3. Triggers: cuando se inserta un contrato/cuota, copia cobrador_id desde
--    el cliente correspondiente.
create or replace function public.set_cobrador_id_from_cliente()
returns trigger language plpgsql as $$
begin
  if new.cobrador_id is null then
    select cobrador_id into new.cobrador_id
    from public.clientes
    where id = new.cliente_id;
  end if;
  return new;
end;
$$;

create trigger trg_set_cobrador_id_contratos
before insert on public.contratos
for each row execute function public.set_cobrador_id_from_cliente();

create trigger trg_set_cobrador_id_cuotas
before insert on public.cuotas
for each row execute function public.set_cobrador_id_from_cliente();

-- 4. Trigger: cuando se REASIGNA un cliente a otro cobrador, propagar el cambio
--    a sus contratos y cuotas para que PowerSync mueva las filas al nuevo
--    cobrador en su próximo sync.
create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger language plpgsql as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;
  end if;
  return new;
end;
$$;

create trigger trg_propagate_cobrador_id_clientes
after update of cobrador_id on public.clientes
for each row execute function public.propagate_cobrador_id_from_cliente();


-- >>> Migration: 0003_geografia.sql <<<
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


-- >>> Migration: 0004_settings_y_rol_admin_cobranza.sql <<<
-- Settings: configuración global por tenant.
-- Clave/valor con tipo, agrupados por categoría para UI del panel admin.

create table public.settings (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  clave text not null,
  valor jsonb not null,
  tipo text not null check (tipo in ('boolean','number','string','json')),
  categoria text not null,
  descripcion text,
  editable_por text not null default 'admin' check (editable_por in ('admin','admin_cobranza')),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, clave)
);

create index on public.settings (tenant_id, categoria);

alter table public.settings enable row level security;

create policy "tenant_isolation" on public.settings
  for all using (tenant_id = public.current_tenant_id());

-- =========================================================================
-- Rol admin_cobranza
-- Existía sólo admin/cobrador en 0001. admin_cobranza administra clientes,
-- contratos, asignación de cobradores. NO toca settings ni borra cobradores.
-- =========================================================================

alter table public.cobradores drop constraint cobradores_rol_check;

alter table public.cobradores add constraint cobradores_rol_check
  check (rol in ('admin','admin_cobranza','cobrador'));

-- Helper para sync rules y políticas RLS.
create or replace function public.current_user_rol() returns text
language sql stable security definer as $$
  select rol from public.cobradores where id = auth.uid()
$$;

-- =========================================================================
-- RLS de settings: lectura permitida a cualquier usuario del tenant,
-- escritura sólo admin (o admin_cobranza si la setting lo permite).
-- =========================================================================

drop policy "tenant_isolation" on public.settings;

create policy "settings_read" on public.settings
  for select using (tenant_id = public.current_tenant_id());

create policy "settings_write_admin" on public.settings
  for all using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
  ) with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
  );

-- admin_cobranza puede actualizar settings cuyo editable_por sea 'admin_cobranza'.
create policy "settings_update_admin_cobranza" on public.settings
  for update using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin_cobranza'
    and editable_por = 'admin_cobranza'
  );


-- >>> Migration: 0005_pagos_parciales_multimoneda.sql <<<
-- Pagos parciales en cuotas + multi-moneda en pagos + foto/geo del cobro.

-- =========================================================================
-- Cuotas: soporte para pagos parciales
-- =========================================================================

alter table public.cuotas add column monto_pagado numeric(10,2) not null default 0
  check (monto_pagado >= 0);

-- Ampliar estados. 'parcial' = tiene pagos pero no llega al monto total.
-- 'vencida' se DERIVA en queries (fecha_vencimiento + gracia < now() y
-- estado in ('pendiente','parcial')), no se guarda — evita updates masivos.
alter table public.cuotas drop constraint cuotas_estado_check;

alter table public.cuotas add constraint cuotas_estado_check
  check (estado in ('pendiente','parcial','pagada','anulada'));

-- Sanity check: no se puede pagar más de lo que vale la cuota.
alter table public.cuotas add constraint cuotas_pagado_no_excede_monto
  check (monto_pagado <= monto);

-- =========================================================================
-- Pagos: multi-moneda, método extendido, foto y geo
-- =========================================================================

-- Renombrar `monto` → `monto_cordobas` (lo que se aplica al saldo de la cuota,
-- siempre en NIO porque las cuotas están en córdobas).
alter table public.pagos rename column monto to monto_cordobas;

-- Moneda en la que el cliente PAGÓ (lo que trajo en mano).
alter table public.pagos add column moneda text not null default 'NIO'
  check (moneda in ('NIO','USD'));

-- Monto en la moneda original (= monto_cordobas si moneda=NIO).
alter table public.pagos add column monto_original numeric(10,2) not null default 0
  check (monto_original >= 0);

-- Tasa snapshot en el momento del cobro (USD → NIO). Para auditoría futura.
-- 1.0 si moneda=NIO.
alter table public.pagos add column tasa_conversion numeric(10,4) not null default 1
  check (tasa_conversion > 0);

-- Método ampliado: efectivo, transferencia, depósito (bancario), tarjeta.
alter table public.pagos drop constraint pagos_metodo_check;
alter table public.pagos add constraint pagos_metodo_check
  check (metodo in ('efectivo','transferencia','deposito','tarjeta'));

-- Referencia para transferencias/depósitos/tarjeta (número de confirmación).
alter table public.pagos add column referencia text;

-- Foto del comprobante (transferencia/depósito). Path en Supabase Storage.
alter table public.pagos add column foto_comprobante_path text;

-- Geo del cobro (donde el cobrador estaba al momento de cobrar).
-- Útil para reportes y auditoría — confirma que el cobrador estaba en zona.
alter table public.pagos add column lat double precision;
alter table public.pagos add column lng double precision;

-- =========================================================================
-- Backfill: para registros existentes (en dev) los nuevos campos quedan
-- consistentes. Producción no tiene pagos aún.
-- =========================================================================

update public.pagos
  set monto_original = monto_cordobas,
      moneda = 'NIO',
      tasa_conversion = 1
  where monto_original = 0;

-- Quitamos los defaults transitorios para forzar que el cliente envíe valor real.
alter table public.pagos alter column monto_original drop default;

-- =========================================================================
-- Validación cruzada: si moneda=NIO, monto_cordobas == monto_original y tasa=1
-- =========================================================================

alter table public.pagos add constraint pagos_coherencia_moneda
  check (
    (moneda = 'NIO' and tasa_conversion = 1 and monto_cordobas = monto_original)
    or
    (moneda = 'USD' and tasa_conversion > 0)
  );

-- Transferencia/depósito DEBEN tener referencia o foto (al menos uno).
-- La app valida UX-first, esto es defensa en profundidad.
alter table public.pagos add constraint pagos_comprobante_si_no_efectivo
  check (
    metodo = 'efectivo'
    or referencia is not null
    or foto_comprobante_path is not null
  );


-- >>> Migration: 0006_recibos.sql <<<
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


-- >>> Migration: 0007_cargos_extra.sql <<<
-- Cargos extra sobre una cuota: descuentos, reconexión, otros.
-- Quedan separados de `cuotas.monto` para mantener histórico/auditoría
-- (quién aplicó, cuándo, qué tipo). El total a cobrar = cuota.monto
-- + SUM(cargos_extra.monto * signo según tipo).

create table public.cargos_extra (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  cuota_id uuid not null references public.cuotas(id) on delete cascade,

  -- Denormalizado para sync rules (mismo patrón que cuotas/pagos).
  cobrador_id uuid not null references public.cobradores(id),

  tipo text not null check (tipo in (
    'descuento_monto',       -- valor fijo en C$
    'descuento_porcentaje',  -- % aplicado sobre cuota.monto
    'reconexion',            -- cargo por reconexión de servicio
    'otro'                   -- ajustes manuales (con descripción obligatoria)
  )),

  -- VALOR FINAL EN CÓRDOBAS del cargo/descuento. Siempre positivo.
  -- El signo lo determina el tipo al calcular el total: descuentos restan,
  -- cargos suman.
  monto numeric(10,2) not null check (monto >= 0),

  -- Sólo cuando tipo='descuento_porcentaje', para histórico y reporte.
  -- La app calcula monto = cuota.monto * porcentaje / 100 al aplicarlo.
  porcentaje numeric(5,2) check (
    porcentaje is null or (porcentaje > 0 and porcentaje <= 100)
  ),

  descripcion text,
  aplicado_por uuid not null references public.cobradores(id),
  aplicado_en timestamptz not null default now(),

  -- Idempotencia offline.
  client_local_id text unique
);

create index on public.cargos_extra (tenant_id, cuota_id);
create index on public.cargos_extra (tenant_id, cobrador_id, aplicado_en desc);

-- Coherencia tipo ↔ campos.
alter table public.cargos_extra add constraint cargos_extra_coherencia_tipo
  check (
    (tipo = 'descuento_porcentaje' and porcentaje is not null)
    or (tipo <> 'descuento_porcentaje' and porcentaje is null)
  );

-- 'otro' obliga descripción para auditoría.
alter table public.cargos_extra add constraint cargos_extra_otro_con_descripcion
  check (tipo <> 'otro' or descripcion is not null);

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.cargos_extra enable row level security;

create policy "tenant_isolation" on public.cargos_extra
  for all using (tenant_id = public.current_tenant_id());


-- >>> Migration: 0008_notificaciones_mora.sql <<<
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


-- >>> Migration: 0009_jobs_mensuales.sql <<<
-- Jobs SQL: generación mensual de cuotas + actualización de notificaciones de mora.
-- Se programan con pg_cron (Supabase Cloud lo incluye).

create extension if not exists pg_cron;

-- =========================================================================
-- Helper: leer setting numérico de un tenant
-- =========================================================================

create or replace function public.setting_number(p_tenant_id uuid, p_clave text, p_default numeric)
returns numeric
language sql stable as $$
  select coalesce(
    (select (valor)::text::numeric
       from public.settings
      where tenant_id = p_tenant_id and clave = p_clave),
    p_default
  )
$$;

-- =========================================================================
-- Generar cuotas del mes para un tenant
-- =========================================================================
-- Idempotente: si la cuota ya existe (mismo contrato + periodo), no la duplica.
-- Devuelve cantidad de cuotas creadas.

create or replace function public.generar_cuotas_mes(p_tenant_id uuid, p_periodo date)
returns int
language plpgsql as $$
declare
  v_creadas int;
begin
  insert into public.cuotas (
    tenant_id, contrato_id, cliente_id, cobrador_id,
    periodo, fecha_vencimiento, monto, estado
  )
  select
    c.tenant_id,
    c.id,
    c.cliente_id,
    cli.cobrador_id,
    date_trunc('month', p_periodo)::date,
    -- Vencimiento = primer día del mes + (dia_corte - 1) días.
    -- dia_corte ∈ [1,28] (check en 0001), no hay rebose de mes.
    (date_trunc('month', p_periodo) + ((c.dia_corte - 1) || ' days')::interval)::date,
    p.precio_mensual,
    'pendiente'
  from public.contratos c
  join public.planes   p   on p.id = c.plan_id
  join public.clientes cli on cli.id = c.cliente_id
  where c.tenant_id = p_tenant_id
    and c.activo = true
    and c.fecha_inicio <= (date_trunc('month', p_periodo) + interval '1 month')::date
    and (c.fecha_fin is null or c.fecha_fin >= date_trunc('month', p_periodo)::date)
  on conflict (contrato_id, periodo) do nothing;

  get diagnostics v_creadas = row_count;
  return v_creadas;
end;
$$;

-- =========================================================================
-- Actualizar notificaciones de mora
-- =========================================================================
-- Para cada cuota cuyo (vencimiento + dias_gracia) ya pasó y aún tiene saldo:
--   - upsert una notificación
--   - recalcula dias_mora y monto_adeudado
-- No toca cuotas pagadas/anuladas (no entran al WHERE).

create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
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
        monto_adeudado = excluded.monto_adeudado,
        resuelta_en    = null,  -- reactivar si volvió a caer
        resuelta_por   = null;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

-- =========================================================================
-- Cron jobs
-- =========================================================================

-- 1) Generar cuotas el primer día del mes a las 00:05 (todos los tenants).
select cron.schedule(
  'generar_cuotas_mensual',
  '5 0 1 * *',
  $$
    select public.generar_cuotas_mes(t.id, current_date)
    from public.tenants t;
  $$
);

-- 2) Actualizar notificaciones de mora diariamente a las 06:00.
select cron.schedule(
  'actualizar_notificaciones_mora_diario',
  '0 6 * * *',
  $$
    select public.actualizar_notificaciones_mora(t.id)
    from public.tenants t;
  $$
);


-- >>> Migration: 0010_settings_defaults.sql <<<
-- Settings default por tenant: cuando se crea un tenant nuevo, sembrar
-- la configuración base. Después el admin la ajusta desde el panel.

create or replace function public.seed_settings_default(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por) values

  -- ── Empresa (datos del recibo) ──────────────────────────────────────
  (p_tenant_id, 'empresa.nombre',    '""'::jsonb, 'string', 'empresa', 'Nombre comercial del ISP',           'admin'),
  (p_tenant_id, 'empresa.direccion', '""'::jsonb, 'string', 'empresa', 'Dirección física para recibo',        'admin'),
  (p_tenant_id, 'empresa.telefono',  '""'::jsonb, 'string', 'empresa', 'Teléfono de contacto para recibo',    'admin'),
  (p_tenant_id, 'empresa.ruc',       '""'::jsonb, 'string', 'empresa', 'RUC para recibo',                     'admin'),
  (p_tenant_id, 'empresa.logo_path', 'null'::jsonb, 'string', 'empresa', 'Ruta del logo en Storage',          'admin'),

  -- ── Cobranza ────────────────────────────────────────────────────────
  (p_tenant_id, 'cobranza.dias_gracia',                   '10'::jsonb,  'number',  'cobranza', 'Días entre vencimiento y notificación de mora', 'admin'),
  (p_tenant_id, 'cobranza.modo_ruta',                     '"libre"'::jsonb, 'string', 'cobranza', 'Modo de visualización de ruta del cobrador (libre|planificada)', 'admin'),
  (p_tenant_id, 'cobranza.descuentos_habilitados',        'false'::jsonb, 'boolean', 'cobranza', 'Permitir aplicar descuentos en campo', 'admin'),
  (p_tenant_id, 'cobranza.descuento_tipo',                '"monto"'::jsonb, 'string', 'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_porcentaje',      '0'::jsonb, 'number', 'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_monto',           '0'::jsonb, 'number', 'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)', 'admin'),
  (p_tenant_id, 'cobranza.cargo_reconexion_habilitado',   'false'::jsonb, 'boolean', 'cobranza', 'Permitir cobrar reconexión', 'admin'),
  (p_tenant_id, 'cobranza.monto_reconexion',              '0'::jsonb, 'number', 'cobranza', 'Monto de reconexión en C$', 'admin'),

  -- ── Métodos de pago ─────────────────────────────────────────────────
  -- Efectivo siempre habilitado (no requiere setting).
  (p_tenant_id, 'pagos.transferencia_habilitada', 'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por transferencia', 'admin'),
  (p_tenant_id, 'pagos.deposito_habilitado',      'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por depósito bancario', 'admin'),
  (p_tenant_id, 'pagos.tarjeta_habilitada',       'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago con tarjeta (simbólico, sin pasarela)', 'admin'),
  (p_tenant_id, 'pagos.usd_habilitado',           'true'::jsonb,  'boolean', 'pagos', 'Aceptar pagos en USD', 'admin'),
  (p_tenant_id, 'pagos.tasa_usd_cordoba',         '36.50'::jsonb, 'number',  'pagos', 'Tasa de conversión USD → C$', 'admin_cobranza'),

  -- ── Recibos ─────────────────────────────────────────────────────────
  (p_tenant_id, 'recibo.formato_default_mm', '80'::jsonb, 'number', 'recibos', 'Ancho de papel por defecto (57|80)', 'admin'),
  (p_tenant_id, 'recibo.template_57mm',      '""'::jsonb, 'string', 'recibos', 'Plantilla de recibo 57mm con placeholders', 'admin'),
  (p_tenant_id, 'recibo.template_80mm',      '""'::jsonb, 'string', 'recibos', 'Plantilla de recibo 80mm con placeholders', 'admin'),
  (p_tenant_id, 'recibo.imprimir_logo',      'true'::jsonb, 'boolean', 'recibos', 'Incluir logo en el recibo', 'admin'),
  (p_tenant_id, 'recibo.pie_libre',          '""'::jsonb, 'string', 'recibos', 'Texto libre al pie del recibo (gracias, etc.)', 'admin')

  on conflict (tenant_id, clave) do nothing;
end;
$$;

-- =========================================================================
-- Trigger AFTER INSERT en tenants: siembra automáticamente settings default
-- =========================================================================

create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  return new;
end;
$$;

create trigger trg_tenants_seed_settings
  after insert on public.tenants
  for each row execute function public.tenants_seed_settings_trg();

-- =========================================================================
-- Backfill: sembrar settings para tenants que ya existían antes de esta migración
-- =========================================================================

select public.seed_settings_default(id) from public.tenants;


-- >>> Migration: 0011_fixes_settings_pk_misc.sql <<<
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


-- >>> Migration: 0012_pagos_triggers_y_soft_delete.sql <<<
-- Triggers para mantener cuotas.monto_pagado/estado coherentes con los pagos.
-- Soft delete de pagos (anulación con auditoría) sin pérdida de histórico.
-- Recibos: permitir reemisión cuando se anula un pago.

-- =========================================================================
-- Soft delete en pagos
-- =========================================================================

alter table public.pagos add column anulado boolean not null default false;
alter table public.pagos add column anulado_en timestamptz;
alter table public.pagos add column anulado_por uuid references public.cobradores(id) on delete set null;
alter table public.pagos add column motivo_anulacion text;

-- Si anulado, los campos de auditoría deben estar presentes.
alter table public.pagos add constraint pagos_anulacion_coherencia
  check (
    anulado = false
    or (anulado_en is not null and anulado_por is not null and motivo_anulacion is not null)
  );

create index on public.pagos (tenant_id, anulado) where anulado = true;

-- =========================================================================
-- Recibos: permitir reemisión cuando un pago se anula
-- =========================================================================

-- Antes (0006): pago_id UNIQUE → un solo recibo por pago. Ahora permitimos
-- emitir un nuevo recibo si el pago previo fue anulado, manteniendo histórico.
-- Restricción nueva: a lo sumo UN recibo NO anulado por pago.
alter table public.recibos drop constraint recibos_pago_id_key;

alter table public.recibos add column anulado boolean not null default false;
alter table public.recibos add column anulado_en timestamptz;
alter table public.recibos add column anulado_por uuid references public.cobradores(id) on delete set null;

alter table public.recibos add constraint recibos_anulacion_coherencia
  check (anulado = false or (anulado_en is not null and anulado_por is not null));

create unique index recibos_pago_no_anulado_unique
  on public.recibos (pago_id)
  where anulado = false;

-- =========================================================================
-- Recibos: unique correlativo POR (cobrador, prefijo) — antes era sólo
-- (cobrador, correlativo). Si admin cambia el prefijo del cobrador y la
-- nueva secuencia arranca en 1, no colisiona con el prefijo anterior.
-- =========================================================================

drop index recibos_correlativo_por_cobrador;

create unique index recibos_correlativo_por_cobrador_prefijo
  on public.recibos (cobrador_id, prefijo, correlativo);

-- =========================================================================
-- Trigger central: recalcular cuotas.monto_pagado y estado
-- =========================================================================
-- Suma sólo pagos NO anulados. Determina el nuevo estado en base al total.
-- Respeta estado='anulada' de la cuota (no lo sobrescribe).

create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_monto_cuota numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select monto, estado
    into v_monto_cuota, v_estado_actual
    from public.cuotas
   where id = v_cuota_id;

  -- Si la cuota está anulada, no la tocamos.
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_monto_cuota then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

-- INSERT: nuevo pago → suma al total.
create trigger trg_pagos_insert_recalcular
  after insert on public.pagos
  for each row execute function public.recalcular_cuota_desde_pagos();

-- UPDATE: si cambia monto, cuota_id o anulado, recalcular.
create trigger trg_pagos_update_recalcular
  after update of monto_cordobas, cuota_id, anulado on public.pagos
  for each row execute function public.recalcular_cuota_desde_pagos();

-- DELETE: pago borrado físicamente (raro, soft delete es lo normal).
create trigger trg_pagos_delete_recalcular
  after delete on public.pagos
  for each row execute function public.recalcular_cuota_desde_pagos();


-- >>> Migration: 0013_rls_por_rol.sql <<<
-- RLS por rol: el `tenant_isolation` actual es FOR ALL — un cobrador puede
-- UPDATE/DELETE clientes/cuotas/pagos de otros cobradores vía API directa
-- (Supabase REST o supabase-flutter), aunque el sync rule no le baje sus filas.
-- Esta migración endurece las políticas según el rol del usuario.

-- Helper: ¿es admin?
create or replace function public.is_admin() returns boolean
language sql stable security definer
set search_path = public, pg_temp as $$
  select public.current_user_rol() = 'admin'
$$;

-- Helper: ¿es admin o admin_cobranza?
create or replace function public.is_admin_or_cobranza() returns boolean
language sql stable security definer
set search_path = public, pg_temp as $$
  select public.current_user_rol() in ('admin','admin_cobranza')
$$;

-- =========================================================================
-- planes — sólo admin escribe
-- =========================================================================
drop policy "tenant_isolation" on public.planes;

create policy "planes_read" on public.planes
  for select using (tenant_id = public.current_tenant_id());

create policy "planes_write_admin" on public.planes
  for all using (tenant_id = public.current_tenant_id() and public.is_admin())
  with check (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- cobradores — sólo admin escribe; cobrador ve su propia fila + admins ven todo
-- =========================================================================
drop policy "tenant_isolation_cobradores" on public.cobradores;

create policy "cobradores_read_self_or_admin" on public.cobradores
  for select using (
    tenant_id = public.current_tenant_id()
    and (id = auth.uid() or public.is_admin_or_cobranza())
  );

create policy "cobradores_write_admin" on public.cobradores
  for all using (tenant_id = public.current_tenant_id() and public.is_admin())
  with check (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- clientes — admin/admin_cobranza escriben; cobrador sólo lee los suyos
-- =========================================================================
drop policy "tenant_isolation" on public.clientes;

create policy "clientes_read" on public.clientes
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "clientes_write_admins" on public.clientes
  for all using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- contratos — igual que clientes
-- =========================================================================
drop policy "tenant_isolation" on public.contratos;

create policy "contratos_read" on public.contratos
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "contratos_write_admins" on public.contratos
  for all using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- cuotas — admins gestionan (anular, regenerar); cobrador sólo lee las suyas
-- =========================================================================
drop policy "tenant_isolation" on public.cuotas;

create policy "cuotas_read" on public.cuotas
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "cuotas_write_admins" on public.cuotas
  for all using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- pagos — cobrador inserta los suyos; admins gestionan/anulan
-- =========================================================================
drop policy "tenant_isolation" on public.pagos;

create policy "pagos_read" on public.pagos
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "pagos_insert_propio" on public.pagos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      (public.is_admin_or_cobranza())
      or (public.current_user_rol() = 'cobrador' and cobrador_id = auth.uid())
    )
  );

create policy "pagos_update_admins" on public.pagos
  for update using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

create policy "pagos_delete_admin" on public.pagos
  for delete using (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- recibos — igual patrón que pagos
-- =========================================================================
drop policy "tenant_isolation" on public.recibos;

create policy "recibos_read" on public.recibos
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "recibos_insert_propio" on public.recibos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (public.current_user_rol() = 'cobrador' and cobrador_id = auth.uid())
    )
  );

create policy "recibos_update_admins" on public.recibos
  for update using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- cargos_extra — cobrador aplica para sus cuotas; admins también
-- =========================================================================
drop policy "tenant_isolation" on public.cargos_extra;

create policy "cargos_read" on public.cargos_extra
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "cargos_insert" on public.cargos_extra
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (public.current_user_rol() = 'cobrador' and cobrador_id = auth.uid())
    )
  );

create policy "cargos_write_admins" on public.cargos_extra
  for update using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

create policy "cargos_delete_admin" on public.cargos_extra
  for delete using (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- notificaciones_mora — el cobrador ve/marca las suyas; admins ven todas
-- =========================================================================
drop policy "tenant_isolation" on public.notificaciones_mora;

create policy "notif_read" on public.notificaciones_mora
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

-- Marcar vista: el cobrador asignado o admins.
create policy "notif_update_marca" on public.notificaciones_mora
  for update using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

-- Sólo admins insertan/borran (el cron las genera con superuser).
create policy "notif_write_admin" on public.notificaciones_mora
  for insert with check (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  );

create policy "notif_delete_admin" on public.notificaciones_mora
  for delete using (tenant_id = public.current_tenant_id() and public.is_admin());


-- >>> Migration: 0014_dia_pago_y_calculo_fecha.sql <<<
-- Refactor: dia_corte (1-28) → dia_pago (1-31), con clamping al último día
-- del mes y ajuste domingo → lunes. La fecha de instalación define el día
-- de pago (decisión de negocio: cliente instalado el 17 paga todos los 17).

-- =========================================================================
-- Rename y ampliación del rango
-- =========================================================================

alter table public.contratos rename column dia_corte to dia_pago;
alter table public.contratos drop constraint contratos_dia_corte_check;
alter table public.contratos add constraint contratos_dia_pago_check
  check (dia_pago between 1 and 31);

-- =========================================================================
-- Función central: fecha de pago para un mes dado
-- =========================================================================
-- Reglas:
--   1. Día clamped al último día real del mes (ej. 31 en feb → 28/29).
--   2. Si cae en domingo, mover al lunes (no se cobra los domingos).
--   3. Feriados nacionales: NO se manejan en esta fase.

create or replace function public.calcular_fecha_pago(p_mes date, p_dia_pago int)
returns date
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_ultimo_dia int;
  v_fecha date;
begin
  v_ultimo_dia := extract(day from (date_trunc('month', p_mes) + interval '1 month - 1 day'))::int;
  v_fecha := (date_trunc('month', p_mes) + ((least(p_dia_pago, v_ultimo_dia) - 1) || ' days')::interval)::date;

  -- extract(dow ...): 0=domingo, 1=lunes, ..., 6=sábado.
  if extract(dow from v_fecha) = 0 then
    v_fecha := v_fecha + 1;
  end if;

  return v_fecha;
end;
$$;

-- =========================================================================
-- Reescribir generar_cuotas_mes usando la función nueva
-- =========================================================================

create or replace function public.generar_cuotas_mes(p_tenant_id uuid, p_periodo date)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_creadas int;
begin
  insert into public.cuotas (
    tenant_id, contrato_id, cliente_id, cobrador_id,
    periodo, fecha_vencimiento, monto, estado
  )
  select
    c.tenant_id,
    c.id,
    c.cliente_id,
    cli.cobrador_id,
    date_trunc('month', p_periodo)::date,
    public.calcular_fecha_pago(p_periodo, c.dia_pago),
    p.precio_mensual,
    'pendiente'
  from public.contratos c
  join public.planes   p   on p.id = c.plan_id
  join public.clientes cli on cli.id = c.cliente_id
  where c.tenant_id = p_tenant_id
    and c.activo = true
    -- Contrato debe estar vigente DURANTE el mes objetivo.
    and c.fecha_inicio <= public.calcular_fecha_pago(p_periodo, c.dia_pago)
    and (c.fecha_fin is null or c.fecha_fin >= date_trunc('month', p_periodo)::date)
  on conflict (contrato_id, periodo) do nothing;

  get diagnostics v_creadas = row_count;
  return v_creadas;
end;
$$;


-- >>> Migration: 0015_generacion_cuotas_contrato.sql <<<
-- Generación de cuotas al crear contrato + colchón futuro para indefinidos.
-- Reglas:
--   - Contrato con fecha_fin: se generan TODAS las cuotas del rango al crearlo.
--   - Contrato indefinido (fecha_fin=null): se generan 3 cuotas iniciales.
--   - Cron mensual mantiene un colchón de 3 meses futuros (cubre indefinidos
--     y es no-op para fijos cuyo rango ya terminó).

-- =========================================================================
-- RPC: generar cuotas para un contrato
-- =========================================================================
-- Parámetro p_meses opcional sobreescribe la lógica automática.
-- Idempotente vía ON CONFLICT (contrato_id, periodo).
-- Devuelve cantidad de cuotas creadas.

create or replace function public.generar_cuotas_contrato(
  p_contrato_id uuid,
  p_meses int default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_max_meses     int;
  v_creadas       int := 0;
  v_periodo       date;
  v_vencimiento   date;
  v_inserto       boolean;
begin
  select * into v_contrato from public.contratos where id = p_contrato_id;
  if not found then
    raise exception 'Contrato % no existe', p_contrato_id;
  end if;

  select cobrador_id into v_cobrador_id from public.clientes where id = v_contrato.cliente_id;
  select precio_mensual into v_precio from public.planes where id = v_contrato.plan_id;

  -- Determinar cuántos meses iterar (límite del loop).
  if p_meses is not null then
    v_max_meses := p_meses;
  elsif v_contrato.fecha_fin is null then
    v_max_meses := 3;  -- indefinido: colchón inicial
  else
    -- diff en meses entre fecha_inicio y fecha_fin, +1 para incluir ambos extremos.
    v_max_meses := ((extract(year from v_contrato.fecha_fin) - extract(year from v_contrato.fecha_inicio)) * 12
                  + (extract(month from v_contrato.fecha_fin) - extract(month from v_contrato.fecha_inicio)))::int + 1;
  end if;

  for i in 0 .. v_max_meses - 1 loop
    v_periodo := (date_trunc('month', v_contrato.fecha_inicio) + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    -- Fuera de rango por fecha_fin → terminar el loop.
    exit when v_contrato.fecha_fin is not null and v_periodo > v_contrato.fecha_fin;

    -- Mes anterior a la instalación (vencimiento previo a fecha_inicio) → saltar.
    -- Caso típico: instalación el 25 con día de pago 15 → mes 0 no aplica.
    continue when v_vencimiento < v_contrato.fecha_inicio;

    insert into public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) values (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    on conflict (contrato_id, periodo) do nothing;

    get diagnostics v_inserto = row_count;
    if v_inserto then
      v_creadas := v_creadas + 1;
    end if;
  end loop;

  return v_creadas;
end;
$$;

-- =========================================================================
-- Trigger: al crear un contrato, generar cuotas iniciales automáticamente
-- =========================================================================

create or replace function public.contratos_generar_cuotas_iniciales_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.generar_cuotas_contrato(new.id);
  return new;
end;
$$;

create trigger trg_contratos_generar_cuotas_iniciales
  after insert on public.contratos
  for each row execute function public.contratos_generar_cuotas_iniciales_trg();

-- =========================================================================
-- Reescribir cron mensual: colchón de 3 meses
-- =========================================================================
-- Cada mes pregenera hoy + 1 + 2 meses adelante. ON CONFLICT do nothing
-- hace que la operación sea no-op para los meses que ya tienen cuotas
-- (contratos fijos cuyo rango ya cubre todo). Para indefinidos siempre
-- queda colchón de 3 meses adelante.

select cron.unschedule('generar_cuotas_mensual');
select cron.schedule(
  'generar_cuotas_mensual',
  '5 6 1 * *',
  $$
    select public.generar_cuotas_mes(
      t.id,
      (current_date + (n || ' months')::interval)::date
    )
    from public.tenants t
    cross join generate_series(0, 2) as n;
  $$
);


-- >>> Migration: 0016_fixes_finales.sql <<<
-- Fixes finales de la auditoría:
--   1. actualizar_notificaciones_mora ya no resetea resuelta_en al recalcular.
--   2. Propagación de cobrador_id a notificaciones_mora cuando se reasigna cliente
--      (pagos/recibos/cargos_extra quedan con el cobrador original como auditoría).
--   3. Catálogos geo: inserción restringida a admin/admin_cobranza para evitar
--      basura ad infinitum.

-- =========================================================================
-- 1. actualizar_notificaciones_mora: no resetear resuelta_en
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
    -- resuelta_en/resuelta_por NO se tocan: si el trigger en cuotas las marcó
    -- como resueltas al pagarse, queda como histórico. Si después el pago se
    -- anula, la lógica de anulación es responsable de reabrir la notif.

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

-- =========================================================================
-- 2. Propagación a notificaciones_mora cuando se reasigna cliente
-- =========================================================================
-- Solo notificaciones NO resueltas se mueven al nuevo cobrador. Las
-- resueltas quedan con el cobrador histórico que la resolvió (auditoría).

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;

    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;
    -- pagos / recibos / cargos_extra NO se propagan: snapshot histórico
    -- del cobrador que los ejecutó.
  end if;
  return new;
end;
$$;

-- =========================================================================
-- 3. Catálogos geo: inserción sólo admin/admin_cobranza
-- =========================================================================

drop policy "geo_insert_authenticated" on public.departamentos;
drop policy "geo_insert_authenticated" on public.municipios;
drop policy "geo_insert_authenticated" on public.comunidades;

create policy "geo_insert_admins" on public.departamentos
  for insert to authenticated
  with check (public.is_admin_or_cobranza());

create policy "geo_insert_admins" on public.municipios
  for insert to authenticated
  with check (public.is_admin_or_cobranza());

create policy "geo_insert_admins" on public.comunidades
  for insert to authenticated
  with check (public.is_admin_or_cobranza());


-- >>> Migration: 0017_fixes_2da_auditoria.sql <<<
-- Fixes de la segunda pasada de auditoría:
--   1. search_path en current_user_rol + funciones de 0001/0002/0016
--   2. actualizar_notificaciones_mora marcada SECURITY DEFINER
--   3. RLS de recibos: el cobrador puede marcar SUS recibos como impresos
--   4. notif_update_marca con WITH CHECK
--   5. Reapertura automática de notificación cuando un pago se anula y
--      la cuota baja de 'pagada' a 'parcial'/'pendiente'

-- =========================================================================
-- 1. search_path en funciones legacy
-- =========================================================================

create or replace function public.current_tenant_id() returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select tenant_id from public.cobradores where id = auth.uid()
$$;

create or replace function public.current_user_rol() returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select rol from public.cobradores where id = auth.uid()
$$;

-- Triggers de 0002 — agregar search_path y reescribir.
create or replace function public.set_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is null then
    select cobrador_id into new.cobrador_id
    from public.clientes
    where id = new.cliente_id;
  end if;
  return new;
end;
$$;

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;
  end if;
  return new;
end;
$$;

-- =========================================================================
-- 2. actualizar_notificaciones_mora marcada SECURITY DEFINER
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
-- 3. RLS recibos: el cobrador puede actualizar campos de impresión propios
-- =========================================================================

create policy "recibos_update_impresion_cobrador" on public.recibos
  for update
  using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
    and cobrador_id = auth.uid()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
    and cobrador_id = auth.uid()
  );

-- =========================================================================
-- 4. WITH CHECK en notif_update_marca para evitar reasignación arbitraria
-- =========================================================================

drop policy "notif_update_marca" on public.notificaciones_mora;

create policy "notif_update_marca" on public.notificaciones_mora
  for update
  using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  )
  with check (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

-- =========================================================================
-- 5. Trigger: reabrir notificación cuando cuota baja de 'pagada' a otro estado
-- =========================================================================
-- Caso típico: pago se anula → trigger central baja cuota.estado a parcial.
-- Necesitamos reabrir la notificación de mora si existe.

create or replace function public.reabrir_notificacion_al_anular_pago()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.estado = 'pagada' and new.estado in ('parcial','pendiente') then
    update public.notificaciones_mora
       set resuelta_en = null,
           resuelta_por = null
     where cuota_id = new.id
       and resuelta_en is not null;
  end if;
  return new;
end;
$$;

create trigger trg_reabrir_notificacion_al_anular_pago
  after update on public.cuotas
  for each row execute function public.reabrir_notificacion_al_anular_pago();


-- >>> Migration: 0018_cargos_y_contratos_coherentes.sql <<<
-- Cierre de gaps detectados en la 2da auditoría:
--   - Cargos extra (descuentos/reconexiones) afectan el estado de la cuota.
--   - Cambios de dia_pago / fecha_fin propagan a las cuotas futuras.

-- =========================================================================
-- 1. Helper: total real a cobrar de una cuota considerando cargos extra
-- =========================================================================
-- total = cuota.monto - SUM(descuentos) + SUM(cargos sumados)
-- Descuentos: tipos 'descuento_monto' y 'descuento_porcentaje' (monto ya
-- normalizado a C$ por la app al aplicar el descuento).
-- Cargos sumados: 'reconexion', 'otro'.

create or replace function public.cuota_total_a_cobrar(p_cuota_id uuid)
returns numeric
language sql stable
security definer
set search_path = public, pg_temp
as $$
  select
    cu.monto
    - coalesce((
        select sum(ce.monto)
          from public.cargos_extra ce
         where ce.cuota_id = cu.id
           and ce.tipo in ('descuento_monto','descuento_porcentaje')
      ), 0)
    + coalesce((
        select sum(ce.monto)
          from public.cargos_extra ce
         where ce.cuota_id = cu.id
           and ce.tipo in ('reconexion','otro')
      ), 0)
  from public.cuotas cu
  where cu.id = p_cuota_id
$$;

-- =========================================================================
-- 2. Reescribir recalcular_cuota_desde_pagos para considerar cargos extra
-- =========================================================================

create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

-- =========================================================================
-- 3. Trigger en cargos_extra: recalcular cuota cuando se aplica un cargo
-- =========================================================================
-- Reusa la misma función — vale tanto para pagos.cuota_id como para
-- cargos_extra.cuota_id porque ambos tienen esa columna.

create trigger trg_cargos_extra_recalcular_cuota
  after insert or update or delete on public.cargos_extra
  for each row execute function public.recalcular_cuota_desde_pagos();

-- =========================================================================
-- 4. Trigger UPDATE en contratos: mantener cuotas futuras coherentes
-- =========================================================================
-- - Cambia dia_pago: recalcula fecha_vencimiento de cuotas FUTURAS pendientes.
-- - Cambia fecha_fin: regenera el rango (idempotente vía ON CONFLICT).

create or replace function public.contratos_actualizar_cuotas_futuras_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_mes_actual date := date_trunc('month', current_date)::date;
begin
  if new.dia_pago is distinct from old.dia_pago then
    update public.cuotas
       set fecha_vencimiento = public.calcular_fecha_pago(periodo, new.dia_pago)
     where contrato_id = new.id
       and periodo >= v_mes_actual
       and estado = 'pendiente';
  end if;

  if new.fecha_fin is distinct from old.fecha_fin then
    perform public.generar_cuotas_contrato(new.id);
  end if;

  return new;
end;
$$;

create trigger trg_contratos_actualizar_cuotas_futuras
  after update of dia_pago, fecha_fin on public.contratos
  for each row execute function public.contratos_actualizar_cuotas_futuras_trg();


-- >>> Migration: 0019_storage_buckets.sql <<<
-- Storage buckets para fotos del sistema.
-- Convención de paths: {tenant_id}/{...}.{ext} para que la policy filtre por
-- tenant mirando el primer segmento.
--
-- Buckets:
--   fotos-clientes:      foto del cliente            ({tenant}/cli/{cliente_id}.jpg)
--   comprobantes-pago:   foto del comprobante         ({tenant}/comp/{pago_id}.jpg)
--   logos-empresa:       logo en recibo               ({tenant}/logo.png)

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('fotos-clientes',     'fotos-clientes',     false, 2 * 1024 * 1024, array['image/jpeg','image/png','image/webp']),
  ('comprobantes-pago',  'comprobantes-pago',  false, 2 * 1024 * 1024, array['image/jpeg','image/png','image/webp']),
  ('logos-empresa',      'logos-empresa',      false, 1 * 1024 * 1024, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- =========================================================================
-- Helpers reutilizables: primer segmento del path = tenant uuid
-- =========================================================================

create or replace function public.storage_path_tenant(p_name text) returns uuid
language sql immutable
set search_path = public, pg_temp
as $$
  select case
    when split_part(p_name, '/', 1) ~* '^[0-9a-f-]{36}$'
      then split_part(p_name, '/', 1)::uuid
    else null
  end
$$;

-- =========================================================================
-- Policies: lectura por tenant; escritura según rol y bucket
-- =========================================================================

-- LECTURA: todos los usuarios autenticados del tenant pueden ver fotos del tenant.
create policy "storage_read_por_tenant" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('fotos-clientes','comprobantes-pago','logos-empresa')
    and public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- ESCRITURA — fotos-clientes: admin/admin_cobranza (crean el cliente con foto).
create policy "storage_write_fotos_clientes" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'fotos-clientes'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin_or_cobranza()
  )
  with check (
    bucket_id = 'fotos-clientes'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin_or_cobranza()
  );

-- ESCRITURA — comprobantes-pago: cobrador sube los suyos; admins también.
create policy "storage_write_comprobantes" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
  )
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- ESCRITURA — logos-empresa: sólo admin.
create policy "storage_write_logos" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'logos-empresa'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin()
  )
  with check (
    bucket_id = 'logos-empresa'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin()
  );


-- >>> Migration: 0020_audit_log.sql <<<
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


-- >>> Migration: 0021_anulacion_cuotas.sql <<<
-- Anulación de cuotas con auditoría: motivo, autor y timestamp.
-- Antes la anulación solo cambiaba `estado='anulada'` sin razón.

alter table public.cuotas add column anulada_en timestamptz;
alter table public.cuotas add column anulada_por uuid
  references public.cobradores(id) on delete set null;
alter table public.cuotas add column motivo_anulacion text;

-- Coherencia: si estado='anulada', los campos de auditoría son obligatorios.
alter table public.cuotas add constraint cuotas_anulacion_coherencia
  check (
    estado <> 'anulada'
    or (anulada_en is not null and anulada_por is not null and motivo_anulacion is not null)
  );

-- =========================================================================
-- Extender el trigger de auditoría existente para capturar el motivo
-- =========================================================================

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
      to_jsonb(old.estado),
      jsonb_build_object(
        'estado', new.estado,
        'motivo', new.motivo_anulacion,
        'anulada_por', new.anulada_por
      )
    );
  end if;
  return new;
end;
$$;


-- >>> Migration: 0022_rls_hardening.sql <<<
-- Hardening de RLS detectado en la auditoría triple:
--
-- 1. El cobrador hace UPDATE local en cuotas (monto_pagado, estado) al
--    registrar un cobro. Sin policy, RLS rechaza y la queue PowerSync se
--    atasca reintentando indefinidamente.
--    → Nueva policy cuotas_update_via_pago_cobrador + trigger que
--      restringe columnas mutables.
--
-- 2. recibos_update_impresion_cobrador permite UPDATE de cobrador en sus
--    recibos pero no restringe columnas. Cobrador podía mutar prefijo,
--    correlativo, numero_completo, anulado — saltándose el flujo de
--    anulación admin y rompiendo la unicidad.
--    → Trigger BEFORE UPDATE que congela columnas críticas.
--
-- 3. pagos_insert_propio / cargos_insert no validan que cuota_id
--    pertenezca al cobrador. Via API directa, cobrador A podría insertar
--    pago/cargo contra cuota de B.
--    → EXISTS subquery en check.
--
-- 4. Storage 'comprobantes-pago' sin scoping por pago_id. Cualquier rol
--    del tenant puede sobreescribir foto de cualquier pago.
--    → Para cobrador, validar que pago_id en el path es suyo.

-- =========================================================================
-- 1. CUOTAS: cobrador puede UPDATE sus cuotas para reflejar cobros locales
-- =========================================================================

create policy "cuotas_update_cobrador_propio" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.current_user_rol() = 'cobrador'
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.current_user_rol() = 'cobrador'
  );

-- Trigger BEFORE UPDATE: el cobrador SOLO puede mutar monto_pagado y
-- estado. Cualquier intento de tocar monto, periodo, contrato_id, etc.
-- desde un rol cobrador es rechazado. Admins quedan sin restricción.
create or replace function public.cuotas_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if new.monto         is distinct from old.monto         or
       new.contrato_id   is distinct from old.contrato_id   or
       new.cliente_id    is distinct from old.cliente_id    or
       new.cobrador_id   is distinct from old.cobrador_id   or
       new.periodo       is distinct from old.periodo       or
       new.fecha_vencimiento is distinct from old.fecha_vencimiento or
       new.tenant_id     is distinct from old.tenant_id     or
       new.anulada_en    is distinct from old.anulada_en    or
       new.anulada_por   is distinct from old.anulada_por   or
       new.motivo_anulacion is distinct from old.motivo_anulacion or
       (new.estado <> old.estado and new.estado = 'anulada')
    then
      raise exception 'cobrador solo puede modificar monto_pagado y estado (no anulada) de sus cuotas';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_cuotas_check_cobrador_update
  before update on public.cuotas
  for each row execute function public.cuotas_check_cobrador_update();

-- =========================================================================
-- 2. RECIBOS: trigger que congela columnas críticas para cobrador
-- =========================================================================

create or replace function public.recibos_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if new.prefijo          is distinct from old.prefijo          or
       new.correlativo      is distinct from old.correlativo      or
       new.numero_completo  is distinct from old.numero_completo  or
       new.pago_id          is distinct from old.pago_id          or
       new.cobrador_id      is distinct from old.cobrador_id      or
       new.tenant_id        is distinct from old.tenant_id        or
       new.anulado          is distinct from old.anulado          or
       new.anulado_en       is distinct from old.anulado_en       or
       new.anulado_por      is distinct from old.anulado_por
    then
      raise exception 'cobrador solo puede modificar campos de impresion en recibos (impreso_en, reimpresiones, ultimo_formato_mm)';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_recibos_check_cobrador_update
  before update on public.recibos
  for each row execute function public.recibos_check_cobrador_update();

-- =========================================================================
-- 3. PAGOS / CARGOS_EXTRA: validar que cuota_id pertenezca al cobrador
-- =========================================================================
-- Nota: las policies actuales (pagos_insert_propio, cargos_insert) sólo
-- piden cobrador_id = auth.uid(). Endurecemos con EXISTS.

drop policy "pagos_insert_propio" on public.pagos;

create policy "pagos_insert_propio" on public.pagos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        and exists (
          select 1 from public.cuotas
           where id = pagos.cuota_id
             and cobrador_id = auth.uid()
        )
      )
    )
  );

drop policy "cargos_insert" on public.cargos_extra;

create policy "cargos_insert" on public.cargos_extra
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        and exists (
          select 1 from public.cuotas
           where id = cargos_extra.cuota_id
             and cobrador_id = auth.uid()
        )
      )
    )
  );

-- =========================================================================
-- 4. STORAGE: comprobantes-pago scoping por pago_id propio
-- =========================================================================
-- Path: {tenant}/comp/{pago_id}.jpg → extraer pago_id de split_part(name, '/', 3)
--   sin extensión.

drop policy "storage_write_comprobantes" on storage.objects;

create policy "storage_write_comprobantes_select_y_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = replace(split_part(name, '/', 3), '.jpg', '')
           and cobrador_id = auth.uid()
      )
    )
  );

create policy "storage_update_comprobantes" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = replace(split_part(name, '/', 3), '.jpg', '')
           and cobrador_id = auth.uid()
      )
    )
  );

-- Borrado: sólo admins. Si alguien necesita borrar comprobantes (caso
-- excepcional), debe pasar por admin.
create policy "storage_delete_comprobantes_admin" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin()
  );


-- >>> Migration: 0023_fixes_simulacion_e2e.sql <<<
-- Fixes detectados al simular el flujo end-to-end completo.
-- Bugs lógicos que sólo aparecen con datos reales corriendo.

-- =========================================================================
-- B1 — Drop constraint `cuotas_pagado_no_excede_monto`
-- =========================================================================
-- El constraint asume monto_pagado ≤ cuota.monto. Pero con cargos extra
-- (reconexión, otro), el total a cobrar es monto + suma_cargos - descuentos.
-- Caso: cuota 500 + reconexión 100 = total 600. Cliente paga 600 → trigger
-- UPDATE monto_pagado=600. Check falla, rollback de todo el cobro.

alter table public.cuotas drop constraint cuotas_pagado_no_excede_monto;

-- Nuevo constraint laxo: monto_pagado ≥ 0 (ya en la columna). El "no
-- excede" se gobierna por cuota_total_a_cobrar() en la lógica del trigger
-- de recálculo, no por un constraint estático.

-- =========================================================================
-- B3 — Off-by-one en generación de cuotas
-- =========================================================================
-- generar_cuotas_contrato sumaba `+ 1` al cálculo de meses. Resultado:
-- contrato de 1 año (fecha_inicio=may'26, fecha_fin=may'27) generaba 13
-- cuotas (incluía mayo'27 cuya cuota cubriría DESPUÉS del fin de contrato).
--
-- Comportamiento esperado: 12 cuotas (mayo'26 a abril'27 inclusive).

create or replace function public.generar_cuotas_contrato(
  p_contrato_id uuid,
  p_meses int default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_max_meses     int;
  v_creadas       int := 0;
  v_periodo       date;
  v_vencimiento   date;
  v_inserto       boolean;
begin
  select * into v_contrato from public.contratos where id = p_contrato_id;
  if not found then
    raise exception 'Contrato % no existe', p_contrato_id;
  end if;

  select cobrador_id into v_cobrador_id from public.clientes where id = v_contrato.cliente_id;
  select precio_mensual into v_precio from public.planes where id = v_contrato.plan_id;

  if p_meses is not null then
    v_max_meses := p_meses;
  elsif v_contrato.fecha_fin is null then
    v_max_meses := 3;  -- indefinido: colchón inicial
  else
    -- Cantidad de meses cubiertos = diff en meses, SIN +1.
    -- Caso 1 año: fecha_inicio=2026-05-17, fecha_fin=2027-05-17 → diff=12.
    -- Loop i=0..11 produce 12 cuotas (mayo'26 hasta abril'27).
    v_max_meses := ((extract(year from v_contrato.fecha_fin) - extract(year from v_contrato.fecha_inicio)) * 12
                  + (extract(month from v_contrato.fecha_fin) - extract(month from v_contrato.fecha_inicio)))::int;
  end if;

  for i in 0 .. v_max_meses - 1 loop
    v_periodo := (date_trunc('month', v_contrato.fecha_inicio) + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    exit when v_contrato.fecha_fin is not null and v_vencimiento >= v_contrato.fecha_fin;
    continue when v_vencimiento < v_contrato.fecha_inicio;

    insert into public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) values (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    on conflict (contrato_id, periodo) do nothing;

    get diagnostics v_inserto = row_count;
    if v_inserto then
      v_creadas := v_creadas + 1;
    end if;
  end loop;

  return v_creadas;
end;
$$;

-- =========================================================================
-- B5 — UNIQUE para evitar contratos duplicados activos por cliente+plan
-- =========================================================================

create unique index contratos_unique_activo_por_cliente_plan
  on public.contratos (cliente_id, plan_id)
  where activo = true;

-- =========================================================================
-- B7 — Columna saldo computado en cuotas, mantenida por trigger
-- =========================================================================
-- Las queries de lista usaban `monto - monto_pagado`, sin considerar cargos.
-- Esto producía un saldo distinto al que veía el cobrador en pantalla de
-- cobro. La solución más simple es persistir `cargos_neto` (suma menos
-- descuentos) en la cuota; las queries calculan saldo como
-- `monto + cargos_neto - monto_pagado`.

alter table public.cuotas add column cargos_neto numeric(10,2) not null default 0;

-- Helper: suma neta de cargos para una cuota.
create or replace function public.calcular_cargos_neto(p_cuota_id uuid)
returns numeric
language sql stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    sum(case
          when tipo in ('reconexion','otro') then monto
          when tipo in ('descuento_monto','descuento_porcentaje') then -monto
          else 0
        end
    ), 0)
    from public.cargos_extra
   where cuota_id = p_cuota_id
$$;

-- Trigger: cuando se inserta/actualiza/borra un cargo_extra, recalcular
-- cuotas.cargos_neto para la cuota afectada.
create or replace function public.cargos_extra_actualizar_neto_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);
  update public.cuotas
     set cargos_neto = public.calcular_cargos_neto(v_cuota_id)
   where id = v_cuota_id;
  return coalesce(new, old);
end;
$$;

create trigger trg_cargos_extra_actualizar_neto
  after insert or update or delete on public.cargos_extra
  for each row execute function public.cargos_extra_actualizar_neto_trg();

-- Backfill: poblar cargos_neto para cuotas existentes.
update public.cuotas
   set cargos_neto = public.calcular_cargos_neto(id);

-- =========================================================================
-- E2 — Anular cuota anula los pagos asociados automáticamente
-- =========================================================================

create or replace function public.cuotas_anular_pagos_asociados_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.estado = 'anulada' and old.estado <> 'anulada' then
    update public.pagos
       set anulado = true,
           anulado_en = coalesce(new.anulada_en, now()),
           anulado_por = new.anulada_por,
           motivo_anulacion = coalesce(
             new.motivo_anulacion || ' (cuota anulada)',
             'Cuota anulada')
     where cuota_id = new.id
       and anulado = false;
    -- Sus recibos también.
    update public.recibos
       set anulado = true,
           anulado_en = coalesce(new.anulada_en, now()),
           anulado_por = new.anulada_por
     where pago_id in (select id from public.pagos where cuota_id = new.id)
       and anulado = false;
  end if;
  return new;
end;
$$;

create trigger trg_cuotas_anular_pagos_asociados
  after update of estado on public.cuotas
  for each row execute function public.cuotas_anular_pagos_asociados_trg();

-- =========================================================================
-- E3 — Acortar fecha_fin elimina cuotas futuras pendientes excedentes
-- =========================================================================
-- Si admin acorta la duración del contrato, las cuotas pendientes cuyo
-- vencimiento sobrepasa la nueva fecha_fin deben eliminarse.
-- Sólo elimina pendientes (no pagadas ni parciales — esas son histórico).

create or replace function public.contratos_limpiar_cuotas_excedentes_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.fecha_fin is not null
     and (old.fecha_fin is null or new.fecha_fin < old.fecha_fin) then
    delete from public.cuotas
     where contrato_id = new.id
       and estado = 'pendiente'
       and fecha_vencimiento >= new.fecha_fin;
  end if;
  return new;
end;
$$;

create trigger trg_contratos_limpiar_cuotas_excedentes
  after update of fecha_fin on public.contratos
  for each row execute function public.contratos_limpiar_cuotas_excedentes_trg();

-- =========================================================================
-- E6 — cargos_extra.cobrador_id se propaga al reasignar cliente
-- =========================================================================
-- Migración 0016 propagaba a contratos/cuotas/notif pero olvidó cargos_extra.
-- Sólo propagamos cargos pendientes (cuya cuota NO está pagada/anulada).

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;

    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;

    -- cargos_extra de cuotas no pagadas también se reasignan.
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


-- >>> Migration: 0024_handle_new_user.sql <<<
-- Auto-creación de filas en `cobradores` cuando un usuario se registra
-- en auth.users. Resuelve dos casos:
--
--   A) Bootstrap del primer admin:
--      Sin metadata.tenant_id → crea un tenant nuevo y asigna rol=admin.
--      El nombre de la empresa puede venir en metadata.empresa_nombre
--      (sino default 'Mi ISP', se ajusta en onboarding wizard).
--
--   B) Invitación de un usuario por admin (Edge Function 'invitar-cobrador'):
--      metadata.tenant_id presente + rol + nombre + prefijo (opcional).
--      Crea la fila en cobradores ligada a ese tenant.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
begin
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  -- Validar rol.
  if v_rol not in ('admin', 'admin_cobranza', 'cobrador') then
    v_rol := 'admin';
  end if;

  -- Caso A: bootstrap del primer admin (sin tenant en metadata).
  if v_tenant_id is null then
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    -- El trigger trg_tenants_seed_settings se dispara aquí (settings default).
    v_rol := 'admin';  -- el primer usuario del tenant SIEMPRE es admin.
  end if;

  -- Caso B: usuario invitado por admin existente, con tenant ya determinado.
  -- Insertamos la fila en cobradores. ON CONFLICT por si esto se ejecuta
  -- doble (raro: trigger inviteUserByEmail + signup).
  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol = 'cobrador' then v_prefijo else null end,
    true
  )
  on conflict (id) do update
    set tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  return new;
end;
$$;

-- Trigger AFTER INSERT en auth.users (esquema controlado por Supabase).
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- >>> Migration: 0025_fix_b2_reasignacion_offline.sql <<<
-- Fix B2: cobro de cliente reasignado offline rechaza por RLS.
--
-- Escenario:
--   1. Cobrador A tiene cliente X asignado, baja sus cuotas via sync.
--   2. A va al campo offline y cobra cuota de X.
--   3. Mientras A está offline, admin reasigna cliente X → cobrador B.
--   4. propagate_cobrador_id_from_cliente cambia cuotas.cobrador_id → B.
--   5. A vuelve a tener internet, PowerSync sube su pago.
--   6. Policy pagos_insert_propio rechaza: cuota.cobrador_id ya no es A.
--      Queue atascada para siempre.
--
-- Solución: relajar el EXISTS para que el cobrador pueda insertar pago
-- contra cualquier cuota DE SU TENANT, mientras el pago tenga
-- cobrador_id = auth.uid(). La auditoría queda intacta (cobrador_id del
-- pago apunta a quien cobró). El cobrador no puede inventar cuotas
-- porque sólo ve las suyas via sync.

drop policy "pagos_insert_propio" on public.pagos;

create policy "pagos_insert_propio" on public.pagos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        -- La cuota debe existir en el tenant. Quitamos la restricción
        -- 'cuotas.cobrador_id = auth.uid()' para que un cobro hecho
        -- offline antes de una reasignación se acepte al subir.
        and exists (
          select 1 from public.cuotas
           where id = pagos.cuota_id
             and tenant_id = public.current_tenant_id()
        )
      )
    )
  );

-- Idem para cargos_extra.
drop policy "cargos_insert" on public.cargos_extra;

create policy "cargos_insert" on public.cargos_extra
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        and exists (
          select 1 from public.cuotas
           where id = cargos_extra.cuota_id
             and tenant_id = public.current_tenant_id()
        )
      )
    )
  );

-- Para UPDATE de cuotas: el cobrador necesita poder actualizar
-- monto_pagado/estado de su cobro offline aunque la cuota ya esté
-- reasignada. Cambiamos `cobrador_id = auth.uid()` a "cobrador del
-- tenant" — el trigger BEFORE UPDATE (cuotas_check_cobrador_update,
-- migración 0022) sigue restringiendo qué columnas puede tocar.

drop policy "cuotas_update_cobrador_propio" on public.cuotas;

create policy "cuotas_update_cobrador_propio" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
  )
  with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
  );

-- =========================================================================
-- E1 — Bloquear contratos con cobrador_id = NULL
-- =========================================================================
-- Cuando un cliente no tiene cobrador asignado, las cuotas se generan con
-- cobrador_id=NULL y son invisibles para todos los cobradores via sync
-- rules. Forzamos que el contrato falle si el cliente no tiene cobrador
-- asignado.

create or replace function public.contratos_check_cliente_con_cobrador()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cobrador_id uuid;
begin
  select cobrador_id into v_cobrador_id
    from public.clientes where id = new.cliente_id;
  if v_cobrador_id is null then
    raise exception 'Cliente sin cobrador asignado. Asignale uno antes de crear contrato.';
  end if;
  return new;
end;
$$;

create trigger trg_contratos_check_cliente_con_cobrador
  before insert on public.contratos
  for each row execute function public.contratos_check_cliente_con_cobrador();


-- >>> Migration: 0026_super_admin_y_modulos.sql <<<
-- Sprint A1 — Rol super_admin + sistema de módulos por tenant
--
-- Cambios:
--   1. Rol 'super_admin' agregado al CHECK constraint de cobradores.
--   2. Tenant 'System' (UUID 0000-...) para alojar a los super_admin.
--   3. Tabla `modulos` (catálogo de módulos del sistema).
--   4. Tabla `tenant_modulos` (qué módulos tiene habilitado cada tenant).
--   5. Funciones helper: is_super_admin(), tenant_tiene_modulo().
--      Se definen DESPUÉS de las tablas que referencian (orden importante).
--   6. Policies de modulos + tenant_modulos.
--   7. Backfill módulos base en tenants existentes.
--   8. Trigger: al crear un tenant, auto-habilita los módulos base.
--   9. RLS 'super_admin_all' en todas las tablas operativas + storage.
--   10. handle_new_user actualizado: super_admin → tenant System.

-- =========================================================================
-- 1. Rol super_admin
-- =========================================================================

alter table public.cobradores drop constraint if exists cobradores_rol_check;
alter table public.cobradores add constraint cobradores_rol_check
  check (rol in ('super_admin', 'admin', 'admin_cobranza', 'cobrador'));

-- =========================================================================
-- 2. Tenant 'System' (UUID fijo, conocido)
-- =========================================================================

insert into public.tenants (id, nombre)
  values ('00000000-0000-0000-0000-000000000000', 'System')
  on conflict (id) do nothing;

-- =========================================================================
-- 3. Tabla `modulos`
-- =========================================================================

create table if not exists public.modulos (
  codigo text primary key,
  nombre text not null,
  descripcion text,
  es_base boolean not null default false,
  orden int not null default 0,
  created_at timestamptz not null default now()
);

insert into public.modulos (codigo, nombre, descripcion, es_base, orden) values
  ('cobranza',   'Cobranza',
   'Gestión de clientes, contratos, cuotas, cobros e impresión de recibos.',
   true,  10),
  ('inventario', 'Inventario',
   'Gestión de equipos (routers, ONUs, etc.) asignados a clientes.',
   false, 20)
on conflict (codigo) do nothing;

alter table public.modulos enable row level security;

-- =========================================================================
-- 4. Tabla `tenant_modulos`
-- =========================================================================

create table if not exists public.tenant_modulos (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  modulo_codigo text not null references public.modulos(codigo) on delete restrict,
  habilitado boolean not null default true,
  habilitado_en timestamptz not null default now(),
  habilitado_por uuid references public.cobradores(id) on delete set null,
  primary key (tenant_id, modulo_codigo)
);

alter table public.tenant_modulos enable row level security;

-- =========================================================================
-- 5. Funciones helper (DESPUÉS de las tablas que usan)
-- =========================================================================

create or replace function public.is_super_admin() returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select rol = 'super_admin' from public.cobradores where id = auth.uid()),
    false
  )
$$;

create or replace function public.tenant_tiene_modulo(p_tenant_id uuid, p_modulo text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select habilitado from public.tenant_modulos
      where tenant_id = p_tenant_id and modulo_codigo = p_modulo),
    false
  )
$$;

-- =========================================================================
-- 6. Policies (ahora is_super_admin existe)
-- =========================================================================

drop policy if exists "modulos_read" on public.modulos;
create policy "modulos_read" on public.modulos
  for select to authenticated using (true);

drop policy if exists "modulos_super_admin_write" on public.modulos;
create policy "modulos_super_admin_write" on public.modulos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

drop policy if exists "tenant_modulos_read" on public.tenant_modulos;
create policy "tenant_modulos_read" on public.tenant_modulos
  for select using (
    tenant_id = public.current_tenant_id() or public.is_super_admin()
  );

drop policy if exists "tenant_modulos_super_admin_write" on public.tenant_modulos;
create policy "tenant_modulos_super_admin_write" on public.tenant_modulos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

-- =========================================================================
-- 7. Backfill módulos base en tenants existentes
-- =========================================================================

insert into public.tenant_modulos (tenant_id, modulo_codigo)
  select t.id, m.codigo
  from public.tenants t cross join public.modulos m
  where m.es_base = true
on conflict do nothing;

-- =========================================================================
-- 8. Trigger: nuevo tenant → auto-habilita módulos base
-- =========================================================================

create or replace function public.tenants_habilitar_modulos_base_trg()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.tenant_modulos (tenant_id, modulo_codigo)
    select new.id, codigo from public.modulos where es_base = true
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_tenants_habilitar_modulos_base on public.tenants;
create trigger trg_tenants_habilitar_modulos_base
  after insert on public.tenants
  for each row execute function public.tenants_habilitar_modulos_base_trg();

-- =========================================================================
-- 9. RLS: super_admin tiene acceso cross-tenant
-- =========================================================================

do $$
declare
  v_table text;
  v_tables text[] := array[
    'tenants','cobradores','planes','clientes','contratos','cuotas',
    'pagos','recibos','cargos_extra','notificaciones_mora','settings','audit_log'
  ];
begin
  foreach v_table in array v_tables loop
    execute format('drop policy if exists "super_admin_all" on public.%I', v_table);
    execute format(
      'create policy "super_admin_all" on public.%I for all using (public.is_super_admin()) with check (public.is_super_admin())',
      v_table
    );
  end loop;
end $$;

drop policy if exists "storage_super_admin" on storage.objects;
create policy "storage_super_admin" on storage.objects
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- =========================================================================
-- 10. handle_new_user actualizado para soportar super_admin
-- =========================================================================
-- - rol='super_admin' → tenant System (00000000-...).
-- - sin tenant_id y rol != super_admin → crea tenant nuevo (admin del ISP).
-- - con tenant_id → invitación (cobrador / admin_cobranza / admin).

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
begin
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  if v_rol not in ('super_admin', 'admin', 'admin_cobranza', 'cobrador') then
    v_rol := 'admin';
  end if;

  if v_rol = 'super_admin' then
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  elsif v_tenant_id is null then
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    v_rol := 'admin';
  end if;

  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol = 'cobrador' then v_prefijo else null end,
    true
  )
  on conflict (id) do update
    set tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  return new;
end;
$$;


-- >>> Migration: 0027_super_admin_rpcs.sql <<<
-- Sprint A2 — RPCs para el panel Super Admin
--
-- El panel /super/* no sincroniza modulos / tenant_modulos al SQLite local
-- (así esas tablas no se exponen a tenants regulares). En su lugar consume
-- estas RPCs. Todas chequean is_super_admin() y devuelven error 42501 si no.
--
-- Funciones:
--   1. list_modulos()         → catálogo global (cobranza, inventario, …)
--   2. list_tenants_admin()   → tenants + cobradores_count + módulos activos
--   3. set_tenant_modulo(...) → habilita/deshabilita módulo en un tenant

-- =========================================================================
-- 1. Catálogo de módulos del sistema
-- =========================================================================

create or replace function public.list_modulos()
returns table (
  codigo      text,
  nombre      text,
  descripcion text,
  es_base     boolean,
  orden       int
)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select codigo, nombre, descripcion, es_base, orden
  from public.modulos
  order by orden;
$$;

revoke all on function public.list_modulos() from public;
grant execute on function public.list_modulos() to authenticated;

-- =========================================================================
-- 2. Listar tenants con métricas
-- =========================================================================
-- Excluye el tenant 'System' (no es un ISP real).
-- cobradores_count cuenta sólo activos.
-- modulos_habilitados llega como array de códigos para que el cliente lo
-- consuma fácil (chips/badges).

create or replace function public.list_tenants_admin()
returns table (
  id                  uuid,
  nombre              text,
  created_at          timestamptz,
  cobradores_count    bigint,
  modulos_habilitados text[]
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      t.id,
      t.nombre,
      t.created_at,
      (select count(*) from public.cobradores c
         where c.tenant_id = t.id and c.activo) as cobradores_count,
      coalesce(
        (select array_agg(tm.modulo_codigo order by tm.modulo_codigo)
           from public.tenant_modulos tm
          where tm.tenant_id = t.id and tm.habilitado),
        array[]::text[]
      ) as modulos_habilitados
    from public.tenants t
    where t.id <> '00000000-0000-0000-0000-000000000000'
    order by t.created_at desc;
end;
$$;

revoke all on function public.list_tenants_admin() from public;
grant execute on function public.list_tenants_admin() to authenticated;

-- =========================================================================
-- 3. Toggle de módulo para un tenant
-- =========================================================================
-- Reglas:
--   - Sólo super_admin.
--   - No se puede modificar el tenant System.
--   - Módulos con es_base=true no se pueden deshabilitar (cobranza siempre on).
--   - Upsert: registra quién/cuándo cambió el flag.

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

  insert into public.tenant_modulos (
    tenant_id, modulo_codigo, habilitado, habilitado_en, habilitado_por
  ) values (
    p_tenant_id, p_modulo, p_habilitado, now(), auth.uid()
  )
  on conflict (tenant_id, modulo_codigo) do update
    set habilitado     = excluded.habilitado,
        habilitado_en  = excluded.habilitado_en,
        habilitado_por = excluded.habilitado_por;
end;
$$;

revoke all on function public.set_tenant_modulo(uuid, text, boolean) from public;
grant execute on function public.set_tenant_modulo(uuid, text, boolean) to authenticated;


-- >>> Migration: 0028_super_admin_listar_miembros.sql <<<
-- Batch 1 — Listar miembros de un tenant (panel Super Admin)
--
-- RPC `list_cobradores_tenant` que devuelve la lista de cobradores de un
-- tenant + metadata de auth.users (email, último login, invitación
-- pendiente). Sólo super_admin la puede llamar. No expone System.
--
-- El orden es: activos primero, luego por jerarquía de rol (admin >
-- admin_cobranza > cobrador), luego por nombre alfabético.

create or replace function public.list_cobradores_tenant(p_tenant_id uuid)
returns table (
  id                  uuid,
  email               text,
  nombre              text,
  telefono            text,
  rol                 text,
  activo              boolean,
  prefijo_recibo      text,
  created_at          timestamptz,
  last_sign_in_at     timestamptz,
  email_confirmed_at  timestamptz,
  invited_at          timestamptz
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede listar miembros del tenant System';
  end if;

  return query
    select
      c.id,
      u.email::text,
      c.nombre,
      c.telefono,
      c.rol,
      c.activo,
      c.prefijo_recibo,
      c.created_at,
      u.last_sign_in_at,
      u.email_confirmed_at,
      u.invited_at
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.tenant_id = p_tenant_id
      -- Defensa: filas super_admin no deberían tener un tenant_id distinto a
      -- System, pero por si quedaron históricas, no las exponemos al panel
      -- de otro tenant.
      and c.rol <> 'super_admin'
    order by
      c.activo desc,
      case c.rol
        when 'admin' then 1
        when 'admin_cobranza' then 2
        when 'cobrador' then 3
        else 4
      end,
      c.nombre;
end;
$$;

revoke all on function public.list_cobradores_tenant(uuid) from public;
grant execute on function public.list_cobradores_tenant(uuid) to authenticated;


-- >>> Migration: 0029_super_admin_toggle_activo.sql <<<
-- Batch 1 paso 2 — Activar / Desactivar miembro del tenant
--
-- RPC `set_cobrador_activo(p_cobrador_id, p_activo)`:
--   - Sólo super_admin (errcode 42501 si no).
--   - No permite modificarse a sí mismo (defensa contra auto-baneo).
--   - No permite modificar a otro super_admin (defensa contra escalation
--     entre super_admins en el futuro).
--   - Update directo en public.cobradores.activo, mantiene la fila — no
--     borra nada — así historial / pagos / auditoría siguen referenciando.

create or replace function public.set_cobrador_activo(
  p_cobrador_id uuid,
  p_activo      boolean
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target_tenant uuid;
  v_target_rol    text;
  v_target_activo boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  -- Defensa de auto-modificación. Funciona porque cobradores.id = auth.uid()
  -- por invariante del trigger handle_new_user (migración 0024) — si se
  -- desacopla en el futuro, este check necesita actualizarse.
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio estado';
  end if;

  select tenant_id, rol, activo
    into v_target_tenant, v_target_rol, v_target_activo
  from public.cobradores
  where id = p_cobrador_id;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar a otro super_admin';
  end if;

  -- Si ya está en el estado pedido, no hacemos nada (idempotencia + evita
  -- registrar audit duplicado).
  if v_target_activo = p_activo then
    return;
  end if;

  update public.cobradores
  set activo = p_activo
  where id = p_cobrador_id;

  -- Auditoría: desactivar/reactivar un usuario es security-sensitive.
  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'cobradores',
    p_cobrador_id,
    'activo',
    to_jsonb(v_target_activo),
    to_jsonb(p_activo),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.set_cobrador_activo(uuid, boolean) from public;
grant execute on function public.set_cobrador_activo(uuid, boolean) to authenticated;


-- >>> Migration: 0030_super_admin_cambiar_rol.sql <<<
-- Batch 2 — Cambiar rol de un miembro del tenant
--
-- RPC `set_cobrador_rol(p_cobrador_id, p_nuevo_rol)`:
--   - Sólo super_admin (errcode 42501 si no).
--   - No permite modificarse a sí mismo.
--   - No permite modificar a otro super_admin (defensa contra escalation
--     entre super_admins).
--   - El nuevo rol debe ser uno de: admin / admin_cobranza / cobrador.
--     No permite escalar a super_admin desde acá (el rol super_admin se
--     asigna sólo manualmente por el dueño del SaaS).
--   - Idempotencia: si ya tiene el rol pedido, no hace nada (no escribe
--     audit duplicado).
--   - Limpieza de prefijo_recibo: si el target deja de ser cobrador,
--     prefijo se setea a NULL (no aplica a otros roles).
--   - Audit log: registra el cambio de rol con valor anterior/nuevo.
--
-- Nota: si el cobrador afectado está logueado en otra sesión, sus reglas
-- de sync de PowerSync (que dependen del rol) sólo se actualizan al
-- próximo login. El super_admin debería avisar al usuario que cierre
-- sesión y vuelva a entrar para ver el panel correcto.

create or replace function public.set_cobrador_rol(
  p_cobrador_id uuid,
  p_nuevo_rol   text
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target_tenant uuid;
  v_target_rol    text;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio rol';
  end if;

  if p_nuevo_rol not in ('admin', 'admin_cobranza', 'cobrador') then
    raise exception
      'Rol inválido. Permitidos: admin, admin_cobranza, cobrador';
  end if;

  -- FOR UPDATE: lock de la fila para que dos super_admins concurrentes no
  -- pasen ambos el check de idempotencia y escriban audit rows con
  -- valores anterior/nuevo inconsistentes.
  select tenant_id, rol
    into v_target_tenant, v_target_rol
  from public.cobradores
  where id = p_cobrador_id
  for update;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar el rol de otro super_admin';
  end if;

  -- Idempotencia.
  if v_target_rol = p_nuevo_rol then
    return;
  end if;

  -- Si deja de ser cobrador, prefijo_recibo no aplica.
  update public.cobradores
  set rol = p_nuevo_rol,
      prefijo_recibo = case
        when p_nuevo_rol = 'cobrador' then prefijo_recibo
        else null
      end
  where id = p_cobrador_id;

  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'cobradores',
    p_cobrador_id,
    'rol',
    to_jsonb(v_target_rol),
    to_jsonb(p_nuevo_rol),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.set_cobrador_rol(uuid, text) from public;
grant execute on function public.set_cobrador_rol(uuid, text) to authenticated;


-- >>> Migration: 0031_listar_miembros_con_clientes_count.sql <<<
-- Hot-fix: extender `list_cobradores_tenant` para devolver el count de
-- clientes activos asignados a cada cobrador.
--
-- Por qué: cuando un cobrador se cambia de rol o se desactiva, los
-- clientes con `cobrador_id = <ese-id>` quedan huérfanos semánticamente
-- (la FK sigue válida pero el "cobrador" asignado ya no opera como tal).
-- El super_admin necesita saber cuántos clientes va a dejar sin cobrador
-- antes de confirmar el cambio.
--
-- Sólo se incluyen clientes con activo=true. El campo es bigint para
-- ser consistente con la salida de COUNT(*) de PostgreSQL.

drop function if exists public.list_cobradores_tenant(uuid);

create or replace function public.list_cobradores_tenant(p_tenant_id uuid)
returns table (
  id                  uuid,
  email               text,
  nombre              text,
  telefono            text,
  rol                 text,
  activo              boolean,
  prefijo_recibo      text,
  created_at          timestamptz,
  last_sign_in_at     timestamptz,
  email_confirmed_at  timestamptz,
  invited_at          timestamptz,
  clientes_asignados  bigint
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede listar miembros del tenant System';
  end if;

  return query
    select
      c.id,
      u.email::text,
      c.nombre,
      c.telefono,
      c.rol,
      c.activo,
      c.prefijo_recibo,
      c.created_at,
      u.last_sign_in_at,
      u.email_confirmed_at,
      u.invited_at,
      (select count(*) from public.clientes cl
         where cl.cobrador_id = c.id and cl.activo)::bigint
        as clientes_asignados
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.tenant_id = p_tenant_id
      and c.rol <> 'super_admin'
    order by
      c.activo desc,
      case c.rol
        when 'admin' then 1
        when 'admin_cobranza' then 2
        when 'cobrador' then 3
        else 4
      end,
      c.nombre;
end;
$$;

revoke all on function public.list_cobradores_tenant(uuid) from public;
grant execute on function public.list_cobradores_tenant(uuid) to authenticated;

-- Partial index para el count: el subselect filtra por cobrador_id +
-- activo en cada fila de la lista. Sin este índice y con tenants grandes
-- el planner puede caer en seq-scan de clientes.
create index if not exists clientes_cobrador_activo_idx
  on public.clientes (cobrador_id)
  where activo;


-- >>> Migration: 0032_super_admin_detalle_miembro.sql <<<
-- Batch 3 paso 1 — RPCs para pantalla de detalle del miembro
--
-- Dos RPCs, ambas gateadas por is_super_admin():
--   1. get_cobrador_stats: stats agregadas (last_sign_in, # clientes
--      asignados, # pagos del mes, $ cobrado del mes).
--   2. list_audit_cobrador: últimos N eventos del audit_log donde el
--      miembro fue afectado (registro_id = cobrador_id).
--
-- Excluye la lógica de pagos cuando el cobrador no es rol cobrador
-- (admins no cobran, devuelven 0). Las queries usan los índices que ya
-- existen para clientes (cobrador_activo_idx) y pagos (by_cobrador_fecha).

-- =========================================================================
-- 1. get_cobrador_stats: stats agregadas para un miembro
-- =========================================================================

create or replace function public.get_cobrador_stats(p_cobrador_id uuid)
returns table (
  id                  uuid,
  last_sign_in_at     timestamptz,
  clientes_asignados  bigint,
  pagos_mes_count     bigint,
  pagos_mes_total     numeric
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      c.id,
      u.last_sign_in_at,
      (select count(*) from public.clientes cl
         where cl.cobrador_id = c.id and cl.activo)::bigint
        as clientes_asignados,
      (select count(*) from public.pagos p
         where p.cobrador_id = c.id
           and p.anulado = false
           and p.fecha_pago >= date_trunc('month', now()))::bigint
        as pagos_mes_count,
      coalesce(
        (select sum(p.monto_cordobas) from public.pagos p
          where p.cobrador_id = c.id
            and p.anulado = false
            and p.fecha_pago >= date_trunc('month', now())),
        0
      ) as pagos_mes_total
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.id = p_cobrador_id
      and c.rol <> 'super_admin';
end;
$$;

revoke all on function public.get_cobrador_stats(uuid) from public;
grant execute on function public.get_cobrador_stats(uuid) to authenticated;

-- =========================================================================
-- 2. list_audit_cobrador: timeline de eventos sobre el miembro
-- =========================================================================
-- Devuelve los últimos N eventos del audit_log donde el miembro fue el
-- TARGET (registro_id), no donde fue el ACTOR. Útil para responder
-- "¿qué le pasó a este usuario en los últimos 50 cambios?".
--
-- Hace JOIN con auth.users + cobradores del autor del cambio para mostrar
-- nombre + email en la UI sin queries adicionales.

create or replace function public.list_audit_cobrador(
  p_cobrador_id uuid,
  p_limit int default 50
)
returns table (
  id              uuid,
  tabla           text,
  campo           text,
  valor_anterior  jsonb,
  valor_nuevo     jsonb,
  user_id         uuid,
  user_rol        text,
  user_email      text,
  user_nombre     text,
  created_at      timestamptz
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      a.id,
      a.tabla,
      a.campo,
      a.valor_anterior,
      a.valor_nuevo,
      a.user_id,
      a.user_rol,
      u.email::text as user_email,
      c.nombre as user_nombre,
      a.created_at
    from public.audit_log a
    left join auth.users u on u.id = a.user_id
    left join public.cobradores c on c.id = a.user_id
    where a.registro_id = p_cobrador_id
      -- Defense in depth: aunque la chance de colisión UUID entre tablas
      -- es astronómica, restringimos a las tablas donde nuestras acciones
      -- sobre cobradores escriben audit (cobradores, auth.users).
      and a.tabla in ('cobradores', 'auth.users')
    order by a.created_at desc
    limit greatest(p_limit, 1);
end;
$$;

revoke all on function public.list_audit_cobrador(uuid, int) from public;
grant execute on function public.list_audit_cobrador(uuid, int) to authenticated;


-- >>> Migration: 0033_super_admin_audit_reset_password.sql <<<
-- Auditoría del reset password vía email (cliente)
--
-- El flow de reset password se ejecuta del lado cliente con
-- auth.resetPasswordForEmail (API pública), sin pasar por Edge Function.
-- Eso significa que no quedaba registro del intento en audit_log a
-- diferencia del resto de las acciones del panel super_admin.
--
-- Esta RPC permite al cliente registrar el evento en audit_log con los
-- mismos guards de seguridad (sólo super_admin) y el mismo formato del
-- resto de los audit entries. El cliente la llama tras un reset exitoso.
--
-- Race conocida: si el reset email se envió pero la RPC de audit falla,
-- el audit queda incompleto. Acceptable porque el cobrador puede ver el
-- email de reset igual y completar el flow; el audit row es para
-- trazabilidad del super_admin, no para correctness funcional.

create or replace function public.audit_reset_password(p_cobrador_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target_tenant uuid;
  v_target_rol    text;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  select tenant_id, rol
    into v_target_tenant, v_target_rol
  from public.cobradores
  where id = p_cobrador_id;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede auditar reset de otro super_admin';
  end if;

  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'auth.users',
    p_cobrador_id,
    'reset_password_email',
    null,
    jsonb_build_object('action', 'reset_password_email_sent'),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.audit_reset_password(uuid) from public;
grant execute on function public.audit_reset_password(uuid) to authenticated;


-- >>> Migration: 0034_db_integrity_hardening.sql <<<
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


-- >>> Migration: 0035_error_logs.sql <<<
-- Sistema de logs de errores del cliente Flutter.
--
-- Cada crash/excepción capturada por el cliente (FlutterError.onError,
-- runZonedGuarded, PlatformDispatcher) se inserta acá para que super_admin
-- diagnostique sin pedirle al cliente que abra DevTools.
--
-- Modelo:
--   - INSERT only desde clientes authenticated. La policy exige
--     user_id = auth.uid() para evitar suplantación.
--   - tenant_id es opcional (puede ser null si el cliente no logró
--     leerlo de PowerSync, ej. arranque sin sync). Si se pasa, tiene que
--     coincidir con current_tenant_id() — un user no puede atribuir su
--     error a otro tenant.
--   - super_admin tiene policy ALL: lee todos los logs cross-tenant
--     desde /super/logs y eventualmente puede purgar viejos.
--   - client_log_id: UUID del cliente para idempotencia. Si el cliente
--     reintenta el upload (network blip), el segundo INSERT choca contra
--     el unique constraint y el cliente lo trata como éxito.

-- =========================================================================
-- Tabla
-- =========================================================================

create table if not exists public.error_logs (
  id              uuid        primary key default gen_random_uuid(),
  ts              timestamptz not null    default now(),
  user_id         uuid                    references auth.users(id) on delete set null,
  tenant_id       uuid                    references public.tenants(id) on delete set null,
  error_type      text        not null    check (error_type in ('flutter','zone','platform')),
  message         text        not null,
  stack           text,
  route           text,
  user_agent      text,
  app_version     text,
  client_log_id   uuid,
  reported_at     timestamptz not null    default now()
);


-- =========================================================================
-- Indices
-- =========================================================================
-- Listado global (más reciente primero) — el viewer /super/logs lo usa.
create index if not exists error_logs_ts_idx
  on public.error_logs (ts desc);

-- Filtro por tenant (cuando super_admin pivota en un ISP específico).
create index if not exists error_logs_tenant_ts_idx
  on public.error_logs (tenant_id, ts desc)
  where tenant_id is not null;

-- Filtro por user (cuando se diagnostica el problema de un usuario puntual).
create index if not exists error_logs_user_ts_idx
  on public.error_logs (user_id, ts desc)
  where user_id is not null;

-- Idempotencia: dedupe en reintentos del cliente.
create unique index if not exists error_logs_client_log_id_uidx
  on public.error_logs (client_log_id)
  where client_log_id is not null;


-- =========================================================================
-- RLS
-- =========================================================================

alter table public.error_logs enable row level security;

-- super_admin: ALL (read/insert/update/delete cross-tenant).
drop policy if exists "error_logs_super_admin_all" on public.error_logs;
create policy "error_logs_super_admin_all"
  on public.error_logs
  for all
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- authenticated: INSERT propio. Exige user_id = auth.uid() para evitar
-- suplantación. tenant_id puede ser null (cliente no leyó la tabla
-- cobradores aún) o tiene que coincidir con current_tenant_id() para
-- evitar atribuir el error a otro tenant.
drop policy if exists "error_logs_self_insert" on public.error_logs;
create policy "error_logs_self_insert"
  on public.error_logs
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and (
      tenant_id is null
      or tenant_id = public.current_tenant_id()
    )
  );


-- =========================================================================
-- RPC list_error_logs — el viewer /super/logs la consume.
-- =========================================================================
-- Hace JOIN con tenants y cobradores para mostrar nombres en vez de
-- UUIDs raw. SECURITY DEFINER porque el viewer es exclusivo de
-- super_admin — la guard explícita raisea 42501 si lo invoca otro rol.
--
-- Filtros opcionales: tenant, tipo de error, búsqueda en message (ilike).

create or replace function public.list_error_logs(
  p_tenant_id  uuid default null,
  p_error_type text default null,
  p_search     text default null,
  p_limit      int  default 100
)
returns table(
  id            uuid,
  ts            timestamptz,
  user_id       uuid,
  user_nombre   text,
  tenant_id     uuid,
  tenant_nombre text,
  error_type    text,
  message       text,
  stack         text,
  route         text,
  user_agent    text,
  app_version   text,
  reported_at   timestamptz
)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
  select
    el.id, el.ts, el.user_id, co.nombre as user_nombre,
    el.tenant_id, t.nombre as tenant_nombre,
    el.error_type, el.message, el.stack, el.route,
    el.user_agent, el.app_version, el.reported_at
  from public.error_logs el
  left join public.tenants t      on t.id  = el.tenant_id
  left join public.cobradores co  on co.id = el.user_id
  where (p_tenant_id  is null or el.tenant_id  = p_tenant_id)
    and (p_error_type is null or el.error_type = p_error_type)
    and (p_search     is null or el.message ilike '%' || p_search || '%')
  order by el.ts desc
  -- Cap a 500 para defender contra p_limit gigantes accidentales del cliente.
  limit least(greatest(p_limit, 1), 500);
end;
$$;

revoke all on function public.list_error_logs(uuid, text, text, int) from public;
grant execute on function public.list_error_logs(uuid, text, text, int) to authenticated;


-- >>> Migration: 0036_check_email_exists.sql <<<
-- Migración 0036: RPC para verificar si un email existe en auth.users.
--
-- Reemplaza el patrón `listUsers({ perPage: 1000 })` en la Edge Function
-- `cambiar-email-cobrador`. El listUsers tiene un tope de 1000 users —
-- con más de 1000, la verificación da falsos negativos y se crean emails
-- duplicados. Este RPC consulta auth.users directamente sin límite.
--
-- SECURITY DEFINER porque auth.users no es accesible via RLS normal.
-- SET search_path = '' para evitar inyección de schema en funciones
-- SECURITY DEFINER (best practice CWE-426).
--
-- Parámetros:
--   p_email: email a verificar (case-insensitive).
--   p_exclude_user_id: excluir un user específico (para el caso de
--     cambiar-email donde el target ya tiene un email distinto).
--
-- Retorna: true si el email está tomado por OTRO user, false si no.

CREATE OR REPLACE FUNCTION check_email_exists_in_auth(
  p_email text,
  p_exclude_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS(
    SELECT 1 FROM auth.users
    WHERE lower(email) = lower(p_email)
      AND (p_exclude_user_id IS NULL OR id != p_exclude_user_id)
  );
$$;


-- >>> Migration: 0037_error_logs_indices_retention.sql <<<
-- Migración 0037: índice por error_type + RPC de purga para retention.
--
-- Sprint 4 (BULK 3): índice en error_logs.error_type para que los
-- filtros por chip (flutter/zone/platform) en /super/logs no hagan
-- sequential scan cuando la tabla crezca.
--
-- Sprint 2 (BULK 3): RPC purge_error_logs para retention manual.
-- Guard: solo super_admin puede ejecutarla. Complementa el cron
-- diario (cuando se configure pg_cron).

-- Índice por tipo de error para filtros en el viewer.
CREATE INDEX IF NOT EXISTS idx_error_logs_error_type
  ON error_logs(error_type);

-- Índice por timestamp para el filtro de rango de fechas y la purga.
CREATE INDEX IF NOT EXISTS idx_error_logs_ts
  ON error_logs(ts);

-- RPC de purga: borra logs anteriores a la fecha dada.
-- Solo super_admin puede ejecutarla (guard via is_super_admin).
CREATE OR REPLACE FUNCTION purge_error_logs(p_before timestamptz)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede purgar error_logs';
  END IF;

  DELETE FROM public.error_logs WHERE ts < p_before;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;


-- >>> Migration: 0038_revoke_check_email.sql <<<
-- Migración 0038: restringir acceso a check_email_exists_in_auth.
--
-- Security audit finding: la RPC era callable por cualquier user
-- autenticado → user enumeration (probar si un email existe).
-- Las Edge Functions ya usan service_role para llamarla, así que
-- revocar acceso a public/anon/authenticated no rompe nada.

REVOKE EXECUTE ON FUNCTION check_email_exists_in_auth FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION check_email_exists_in_auth TO service_role;


-- >>> Migration: 0039_super_admin_impersonation.sql <<<
-- Migración 0039: Impersonación de tenants por super_admin.
--
-- Permite al super_admin "entrar" a cualquier tenant y operar como
-- admin. El mecanismo es una tabla mínima que indica qué tenant está
-- viendo el super_admin actualmente. La función current_tenant_id()
-- la checa primero: si hay una row, retorna ese tenant_id. Si no,
-- retorna el tenant real del cobrador (System para super_admin).
--
-- El super_admin NO aparece en la lista de miembros del tenant porque
-- su row en cobradores tiene tenant_id = System. Cuando current_tenant_id()
-- retorna el tenant impersonado, el WHERE tenant_id = current_tenant_id()
-- excluye la row del super_admin naturalmente.

-- 1. Tabla de impersonación: una row por super_admin activo.
CREATE TABLE IF NOT EXISTS public.super_admin_impersonation (
  user_id   uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  started_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.super_admin_impersonation ENABLE ROW LEVEL SECURITY;

-- Solo super_admin puede leer/escribir su propia row.
CREATE POLICY "super_admin_own" ON public.super_admin_impersonation
  FOR ALL USING (
    public.is_super_admin() AND user_id = auth.uid()
  )
  WITH CHECK (
    public.is_super_admin() AND user_id = auth.uid()
  );

-- 2. Modificar current_tenant_id() para soportar impersonación.
-- Si el caller es super_admin y tiene una row en la tabla, retorna
-- ese tenant. Sino, retorna el tenant del cobrador (comportamiento
-- original). Para users normales, no cambia nada.
CREATE OR REPLACE FUNCTION public.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN public.is_super_admin() THEN
      COALESCE(
        (SELECT tenant_id FROM public.super_admin_impersonation
         WHERE user_id = auth.uid()),
        (SELECT tenant_id FROM public.cobradores WHERE id = auth.uid())
      )
    ELSE
      (SELECT tenant_id FROM public.cobradores WHERE id = auth.uid())
  END
$$;


-- >>> Migration: 0040_bulk11_settings.sql <<<
-- Migración 0040: settings adicionales para BULK 11.
--
-- Agrega toggles y configuraciones del plan BULK11-PLAN.md:
-- - Cobranza: permisos del cobrador, métodos de pago, reconexión.
-- - Moneda: tasa de cambio, moneda principal.
-- - Cuotas: cuotas manuales, editar monto, descuento pronto pago.

-- Función helper para insertar setting solo si no existe (idempotente).
-- Usamos DO block para no fallar si se corre 2 veces.
DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP

    -- Cobranza: permisos cobrador
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'cobranza.cobrador_edita_fecha', '"false"', 'boolean', 'cobranza',
       'Permite al cobrador modificar la fecha del cobro', 'admin'),
      (v_tenant.id, 'cobranza.cobrador_anula_cobros', '"false"', 'boolean', 'cobranza',
       'Permite al cobrador anular sus propios cobros', 'admin'),
      (v_tenant.id, 'cobranza.cobrador_edita_cobros', '"false"', 'boolean', 'cobranza',
       'Permite al cobrador editar cobros ya registrados', 'admin'),
      (v_tenant.id, 'cobranza.foto_obligatoria', '"false"', 'boolean', 'cobranza',
       'Requiere foto del comprobante al cobrar', 'admin'),
      (v_tenant.id, 'cobranza.pago_parcial', '"true"', 'boolean', 'cobranza',
       'Permite pagos parciales de cuotas', 'admin'),
      (v_tenant.id, 'cobranza.pago_adelantado', '"true"', 'boolean', 'cobranza',
       'Permite pagar múltiples cuotas en un solo cobro', 'admin'),
      (v_tenant.id, 'cobranza.cargo_reconexion', '"0"', 'number', 'cobranza',
       'Cargo automático por reconexión (0 = deshabilitado)', 'admin'),

      -- Métodos de pago
      (v_tenant.id, 'pagos.metodo_efectivo', '"true"', 'boolean', 'pagos',
       'Habilitar pago en efectivo', 'admin'),
      (v_tenant.id, 'pagos.metodo_transferencia', '"false"', 'boolean', 'pagos',
       'Habilitar pago por transferencia', 'admin'),
      (v_tenant.id, 'pagos.metodo_tarjeta', '"false"', 'boolean', 'pagos',
       'Habilitar pago con tarjeta', 'admin'),

      -- Moneda
      (v_tenant.id, 'moneda.principal', '"NIO"', 'string', 'moneda',
       'Moneda principal del tenant (NIO o USD)', 'admin'),

      -- Cuotas
      (v_tenant.id, 'cuotas.manuales', '"false"', 'boolean', 'cuotas',
       'Permite al admin crear cuotas fuera de contrato', 'admin'),
      (v_tenant.id, 'cuotas.editar_monto', '"false"', 'boolean', 'cuotas',
       'Permite al admin modificar monto de cuota generada', 'admin'),
      (v_tenant.id, 'cuotas.descuento_pronto_pago', '"0"', 'number', 'cuotas',
       'Descuento por pronto pago (% si <100, monto fijo si >=100. 0 = deshabilitado)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;

  END LOOP;
END $$;


-- >>> Migration: 0041_recibo_template_settings.sql <<<
-- Migración 0041: settings del template de recibo.
DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'recibo.titulo', '"RECIBO"', 'string', 'recibos',
       'Titulo del documento en el recibo (ej: COBRO, RECIBO)', 'admin'),
      (v_tenant.id, 'recibo.monto_en_letras', '"true"', 'boolean', 'recibos',
       'Mostrar monto en letras en el recibo', 'admin'),
      (v_tenant.id, 'recibo.mostrar_adeudado', '"true"', 'boolean', 'recibos',
       'Mostrar tabla de meses adeudados en el recibo', 'admin'),
      (v_tenant.id, 'empresa.whatsapp', '""', 'string', 'empresa',
       'Numero de WhatsApp de la empresa (aparece en recibo)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;


-- >>> Migration: 0042_cuotas_manuales_editar_monto.sql <<<
-- Migración 0042: soporte para cuotas manuales y edición de monto.
--
-- 1. contrato_id pasa a nullable para cuotas manuales (no ligadas a contrato).
-- 2. Se agrega columna `descripcion` para dar contexto a cuotas manuales
--    (ej: "Cargo por reconexión", "Instalación", etc.).
-- 3. El unique index (contrato_id, periodo) se mantiene — las cuotas con
--    contrato_id NULL no colisionan entre sí porque NULL != NULL en Postgres.
--    Esto significa que pueden existir múltiples cuotas manuales para el
--    mismo periodo sin conflicto.

-- 1. Hacer contrato_id nullable.
ALTER TABLE public.cuotas ALTER COLUMN contrato_id DROP NOT NULL;

-- 2. Agregar columna descripcion (texto libre, nullable).
ALTER TABLE public.cuotas ADD COLUMN IF NOT EXISTS descripcion text;


-- >>> Migration: 0043_pagos_grupo_cobro.sql <<<
-- 0043: Agregar grupo_cobro a pagos para agrupar pagos multi-cuota.
-- Cuando un cobrador paga N cuotas del mismo contrato en un solo acto,
-- todos los pagos comparten el mismo grupo_cobro UUID.
-- NULL = pago individual (single cuota).

ALTER TABLE pagos ADD COLUMN grupo_cobro uuid;

CREATE INDEX idx_pagos_grupo_cobro ON pagos (grupo_cobro)
  WHERE grupo_cobro IS NOT NULL;


-- >>> Migration: 0044_descuento_pronto_pago_tipo.sql <<<
-- 0044: Agregar setting para tipo de descuento pronto pago.
-- Antes se usaba un heuristic (< 100 = porcentaje, >= 100 = fijo).
-- Ahora el admin elige explícitamente el tipo.

INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion)
SELECT
  t.id,
  'cuotas.descuento_pronto_pago_tipo',
  '"porcentaje"',
  'string',
  'cuotas',
  'Tipo de descuento pronto pago: porcentaje o monto'
FROM tenants t
WHERE NOT EXISTS (
  SELECT 1 FROM settings s
  WHERE s.tenant_id = t.id AND s.clave = 'cuotas.descuento_pronto_pago_tipo'
);


-- >>> Migration: 0045_seed_settings_bulk11.sql <<<
-- 0045: Actualizar seed_settings_default para incluir los settings de BULK 11.
-- Sin esto, tenants creados DESPUÉS de las migraciones 0040-0044 no tendrían
-- los 19 settings nuevos.

create or replace function public.seed_settings_default(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por) values

  -- ── Empresa ────────────────────────────────────────────────────────
  (p_tenant_id, 'empresa.nombre',    '""'::jsonb, 'string', 'empresa', 'Nombre comercial del ISP',           'admin'),
  (p_tenant_id, 'empresa.direccion', '""'::jsonb, 'string', 'empresa', 'Dirección física para recibo',        'admin'),
  (p_tenant_id, 'empresa.telefono',  '""'::jsonb, 'string', 'empresa', 'Teléfono de contacto para recibo',    'admin'),
  (p_tenant_id, 'empresa.ruc',       '""'::jsonb, 'string', 'empresa', 'RUC para recibo',                     'admin'),
  (p_tenant_id, 'empresa.logo_path', 'null'::jsonb, 'string', 'empresa', 'Ruta del logo en Storage',          'admin'),
  (p_tenant_id, 'empresa.whatsapp',  '""'::jsonb, 'string', 'empresa', 'WhatsApp de la empresa',              'admin'),

  -- ── Cobranza ────────────────────────────────────────────────────────
  (p_tenant_id, 'cobranza.dias_gracia',                   '10'::jsonb,    'number',  'cobranza', 'Días entre vencimiento y notificación de mora', 'admin'),
  (p_tenant_id, 'cobranza.modo_ruta',                     '"libre"'::jsonb, 'string', 'cobranza', 'Modo de visualización de ruta del cobrador', 'admin'),
  (p_tenant_id, 'cobranza.descuentos_habilitados',        'false'::jsonb, 'boolean', 'cobranza', 'Permitir aplicar descuentos en campo', 'admin'),
  (p_tenant_id, 'cobranza.descuento_tipo',                '"monto"'::jsonb, 'string', 'cobranza', 'Tipo de descuento permitido', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_porcentaje',      '0'::jsonb,     'number',  'cobranza', 'Tope de descuento porcentual', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_monto',           '0'::jsonb,     'number',  'cobranza', 'Tope de descuento monto', 'admin'),
  (p_tenant_id, 'cobranza.cargo_reconexion_habilitado',   'false'::jsonb, 'boolean', 'cobranza', 'Permitir cobrar reconexión', 'admin'),
  (p_tenant_id, 'cobranza.monto_reconexion',              '0'::jsonb,     'number',  'cobranza', 'Monto de reconexión en C$', 'admin'),
  -- BULK 11 settings
  (p_tenant_id, 'cobranza.cobrador_edita_fecha',          'false'::jsonb, 'boolean', 'cobranza', 'Cobrador puede editar fecha de cobro', 'admin'),
  (p_tenant_id, 'cobranza.cobrador_anula_cobros',         'false'::jsonb, 'boolean', 'cobranza', 'Cobrador puede anular cobros', 'admin'),
  (p_tenant_id, 'cobranza.cobrador_edita_cobros',         'false'::jsonb, 'boolean', 'cobranza', 'Cobrador puede editar cobros post-registro', 'admin'),
  (p_tenant_id, 'cobranza.foto_obligatoria',              'false'::jsonb, 'boolean', 'cobranza', 'Foto de comprobante obligatoria', 'admin'),
  (p_tenant_id, 'cobranza.pago_parcial',                  'true'::jsonb,  'boolean', 'cobranza', 'Permitir pago parcial', 'admin'),
  (p_tenant_id, 'cobranza.pago_adelantado',               'true'::jsonb,  'boolean', 'cobranza', 'Permitir pago adelantado (multi-cuota)', 'admin'),
  (p_tenant_id, 'cobranza.cargo_reconexion',              '0'::jsonb,     'number',  'cobranza', 'Cargo automático por reconexión, 0 = deshabilitado', 'admin'),
  (p_tenant_id, 'cobranza.recrear_pago_anulado',        'false'::jsonb, 'boolean', 'cobranza', 'Permitir recrear pagos anulados por error', 'admin'),
  (p_tenant_id, 'cobranza.dias_cuotas_visibles',        '30'::jsonb,    'number',  'cobranza', 'Días de cuotas futuras visibles para el cobrador', 'admin'),

  -- ── Pagos ────────────────────────────────────────────────────────
  (p_tenant_id, 'pagos.transferencia_habilitada', 'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por transferencia', 'admin'),
  (p_tenant_id, 'pagos.deposito_habilitado',      'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por depósito bancario', 'admin'),
  (p_tenant_id, 'pagos.tarjeta_habilitada',       'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago con tarjeta', 'admin'),
  (p_tenant_id, 'pagos.usd_habilitado',           'true'::jsonb,  'boolean', 'pagos', 'Aceptar pagos en USD', 'admin'),
  (p_tenant_id, 'pagos.tasa_usd_cordoba',         '36.50'::jsonb, 'number',  'pagos', 'Tasa de conversión USD → C$', 'admin_cobranza'),
  (p_tenant_id, 'pagos.metodo_efectivo',           'true'::jsonb,  'boolean', 'pagos', 'Aceptar efectivo', 'admin'),
  (p_tenant_id, 'pagos.metodo_transferencia',      'false'::jsonb, 'boolean', 'pagos', 'Aceptar transferencia', 'admin'),
  (p_tenant_id, 'pagos.metodo_tarjeta',            'false'::jsonb, 'boolean', 'pagos', 'Aceptar tarjeta', 'admin'),

  -- ── Moneda ─────────────────────────────────────────────────────────
  (p_tenant_id, 'moneda.principal',               '"NIO"'::jsonb, 'string', 'moneda', 'Moneda principal (NIO/USD)', 'admin'),

  -- ── Cuotas ─────────────────────────────────────────────────────────
  (p_tenant_id, 'cuotas.manuales',                'false'::jsonb, 'boolean', 'cuotas', 'Admin puede crear cuotas manuales', 'admin'),
  (p_tenant_id, 'cuotas.editar_monto',            'false'::jsonb, 'boolean', 'cuotas', 'Admin puede editar monto de cuota', 'admin'),
  (p_tenant_id, 'cuotas.descuento_pronto_pago',   '0'::jsonb,     'number',  'cuotas', 'Descuento por pronto pago, 0 = deshabilitado', 'admin'),
  (p_tenant_id, 'cuotas.descuento_pronto_pago_tipo', '"porcentaje"'::jsonb, 'string', 'cuotas', 'Tipo de descuento pronto pago: porcentaje o monto', 'admin'),

  -- ── Recibos ─────────────────────────────────────────────────────────
  (p_tenant_id, 'recibo.formato_default_mm', '80'::jsonb,    'number',  'recibos', 'Ancho de papel por defecto (57|80)', 'admin'),
  (p_tenant_id, 'recibo.template_57mm',      '""'::jsonb,    'string',  'recibos', 'Plantilla de recibo 57mm', 'admin'),
  (p_tenant_id, 'recibo.template_80mm',      '""'::jsonb,    'string',  'recibos', 'Plantilla de recibo 80mm', 'admin'),
  (p_tenant_id, 'recibo.imprimir_logo',      'true'::jsonb,  'boolean', 'recibos', 'Incluir logo en el recibo', 'admin'),
  (p_tenant_id, 'recibo.pie_libre',          '""'::jsonb,    'string',  'recibos', 'Texto libre al pie del recibo', 'admin'),
  (p_tenant_id, 'recibo.titulo',             '"RECIBO"'::jsonb, 'string', 'recibos', 'Título del documento en el recibo', 'admin'),
  (p_tenant_id, 'recibo.monto_en_letras',    'true'::jsonb,  'boolean', 'recibos', 'Mostrar monto en letras en el recibo', 'admin'),
  (p_tenant_id, 'recibo.mostrar_adeudado',   'true'::jsonb,  'boolean', 'recibos', 'Mostrar tabla de meses adeudados', 'admin'),

  -- ── Auditoría ──────────────────────────────────────────────────────
  (p_tenant_id, 'audit.visible_admin_cobranza', 'false'::jsonb, 'boolean', 'cobranza', 'Permitir a admin de cobranza ver historial de cambios', 'admin')

  on conflict (tenant_id, clave) do nothing;
end;
$$;

-- Backfill: asegurar que tenants existentes tengan todos los settings nuevos.
select public.seed_settings_default(id) from public.tenants;


-- >>> Migration: 0046_pagos_update_cobrador.sql <<<
-- 0046: Permitir al cobrador UPDATE/soft-delete en sus propios pagos.
-- Antes solo admin/admin_cobranza podían hacer UPDATE en pagos.
-- Los toggles cobranza.cobrador_edita_cobros y cobrador_anula_cobros
-- controlan la UI; la RLS permite el UPDATE server-side.

DROP POLICY "pagos_update_admins" ON public.pagos;

CREATE POLICY "pagos_update" ON public.pagos
  FOR UPDATE USING (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR (public.current_user_rol() = 'cobrador' AND cobrador_id = auth.uid())
    )
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR (public.current_user_rol() = 'cobrador' AND cobrador_id = auth.uid())
    )
  );


-- >>> Migration: 0047_audit_changelog_triggers.sql <<<
-- 0047: Change Log genérico — captura full-row en audit_log.
-- Principio: todo feature nuevo debe incluir change log como base.

-- 1. Agregar columna accion (backwards-compatible).
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS accion text NOT NULL DEFAULT 'update';

-- 2. Actualizar helper para aceptar accion.
CREATE OR REPLACE FUNCTION public.audit_registrar(
  p_tenant_id uuid,
  p_tabla text,
  p_registro_id uuid,
  p_campo text,
  p_valor_anterior jsonb,
  p_valor_nuevo jsonb,
  p_accion text DEFAULT 'update'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, accion,
    user_id, user_rol
  ) VALUES (
    p_tenant_id, p_tabla, p_registro_id, p_campo,
    p_valor_anterior, p_valor_nuevo, p_accion,
    auth.uid(), public.current_user_rol()
  );
END;
$$;

-- 3. Trigger genérico full-row (reutilizable para cualquier tabla).
CREATE OR REPLACE FUNCTION public.audit_changelog_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      to_jsonb(OLD), to_jsonb(NEW), 'update'
    );
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      NULL, to_jsonb(NEW), 'create'
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.audit_registrar(
      OLD.tenant_id, TG_TABLE_NAME, OLD.id, NULL,
      to_jsonb(OLD), NULL, 'delete'
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

-- 4. Reemplazar triggers específicos con el genérico.
-- Drop old specific triggers para evitar duplicados.
DROP TRIGGER IF EXISTS trg_audit_pagos_anulacion ON public.pagos;
DROP TRIGGER IF EXISTS trg_audit_cuotas_anulacion ON public.cuotas;
DROP TRIGGER IF EXISTS trg_audit_clientes_cobrador ON public.clientes;
DROP TRIGGER IF EXISTS trg_audit_recibos_anulacion ON public.recibos;

-- Crear triggers genéricos (AFTER UPDATE captura ediciones + anulaciones).
-- WHEN pg_trigger_depth() < 2: evita entradas fantasma por triggers en
-- cascada (ej: pago UPDATE → trigger recalcula cuota → fire changelog
-- de cuota con cambios no iniciados por el usuario).
CREATE TRIGGER trg_changelog_pagos
  AFTER UPDATE ON public.pagos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_cuotas
  AFTER UPDATE ON public.cuotas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_clientes
  AFTER UPDATE ON public.clientes
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_contratos
  AFTER UPDATE ON public.contratos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_recibos
  AFTER UPDATE ON public.recibos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- 5. RLS: permitir lectura a admin_cobranza (controlado por setting en UI).
-- Antes solo admin podía leer. Ahora admin + admin_cobranza.
DROP POLICY IF EXISTS "audit_read_admin" ON public.audit_log;

CREATE POLICY "audit_read" ON public.audit_log
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

-- 6. Setting: toggle visibilidad para admin_cobranza.
INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'audit.visible_admin_cobranza', 'false'::jsonb, 'boolean', 'cobranza',
       'Permitir a admin de cobranza ver historial de cambios', 'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;


-- >>> Migration: 0048_recibos_cobrador_anular.sql <<<
-- 0048: Permitir al cobrador anular sus propios recibos.
-- El trigger de 0022 bloqueaba cambios a anulado/anulado_en/anulado_por
-- en recibos para cobradores. Ahora permitimos esos campos además de
-- los de impresión. El setting cobrador_anula_cobros controla la UI.

CREATE OR REPLACE FUNCTION public.recibos_check_cobrador_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rol text;
BEGIN
  v_rol := public.current_user_rol();
  IF v_rol = 'cobrador' THEN
    IF new.prefijo          IS DISTINCT FROM old.prefijo          OR
       new.correlativo      IS DISTINCT FROM old.correlativo      OR
       new.numero_completo  IS DISTINCT FROM old.numero_completo  OR
       new.pago_id          IS DISTINCT FROM old.pago_id          OR
       new.cobrador_id      IS DISTINCT FROM old.cobrador_id      OR
       new.tenant_id        IS DISTINCT FROM old.tenant_id
    THEN
      RAISE EXCEPTION 'cobrador solo puede modificar campos de impresión y anulación en recibos';
    END IF;
  END IF;
  RETURN new;
END;
$$;


-- >>> Migration: 0049_setting_dias_cuotas_visibles.sql <<<
-- 0049: Setting para controlar cuántos días de cuotas futuras ve el cobrador.
-- Default 30: muestra cuotas vencidas + próximos 30 días.

INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'cobranza.dias_cuotas_visibles', '30'::jsonb, 'number', 'cobranza',
       'Días de cuotas futuras visibles para el cobrador (0 = solo vencidas)', 'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;


-- >>> Migration: 0050_drop_old_audit_registrar.sql <<<
-- 0050: Eliminar overload viejo de audit_registrar (6 params).
-- La migración 0047 creó una versión con 7 params (incluyendo p_accion).
-- La versión vieja de 0020 (6 params) seguía existiendo como overload,
-- causando error "function is not unique" cuando el trigger de settings
-- la llamaba con 6 args ambiguos.

DROP FUNCTION IF EXISTS public.audit_registrar(uuid, text, uuid, text, jsonb, jsonb);


-- >>> Migration: 0051_tipo_cargo_manual_recrear_pago.sql <<<
-- 0051: tipo_cargo_manual en cuotas + setting recrear_pago_anulado.

-- 1. Columna para clasificar cuotas manuales (filtrable en reportes).
ALTER TABLE public.cuotas ADD COLUMN IF NOT EXISTS tipo_cargo_manual text;

-- 2. Setting: toggle para permitir recrear pagos anulados.
INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'cobranza.recrear_pago_anulado', 'false'::jsonb, 'boolean', 'cobranza',
       'Permitir recrear pagos anulados por error', 'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;


-- >>> Migration: 0052_contrato_estado.sql <<<
-- 0052: Contrato estados: activo boolean → estado text.
-- Valores: 'activo', 'completado', 'cancelado'.

ALTER TABLE public.contratos ADD COLUMN IF NOT EXISTS estado text NOT NULL DEFAULT 'activo';

-- Migrar datos existentes.
UPDATE public.contratos SET estado = CASE
  WHEN activo = true THEN 'activo'
  ELSE 'cancelado'
END;

-- Eliminar columna vieja.
ALTER TABLE public.contratos DROP COLUMN IF EXISTS activo;


-- >>> Migration: 0053_fotos_cliente.sql <<<
-- 0053: Tabla para fotos múltiples del cliente (max 10).
-- Reemplaza el campo foto_path (single) en clientes.

CREATE TABLE IF NOT EXISTS public.fotos_cliente (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.cobradores(id)
);

CREATE INDEX ON public.fotos_cliente (tenant_id, cliente_id);

ALTER TABLE public.fotos_cliente ENABLE ROW LEVEL SECURITY;

CREATE POLICY "fotos_cliente_read" ON public.fotos_cliente
  FOR SELECT USING (tenant_id = public.current_tenant_id());

CREATE POLICY "fotos_cliente_insert" ON public.fotos_cliente
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

CREATE POLICY "fotos_cliente_delete" ON public.fotos_cliente
  FOR DELETE USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

CREATE POLICY "super_admin_all" ON public.fotos_cliente
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());


-- >>> Migration: 0054_fix_generar_cuotas_estado.sql <<<
-- 0054: Fix generar_cuotas_mes after contrato.activo → estado migration.
-- La función 0014 usaba c.activo = true, pero 0052 reemplazó la columna
-- con estado text. Ahora filtra por c.estado = 'activo'.

CREATE OR REPLACE FUNCTION public.generar_cuotas_mes(p_tenant_id uuid, p_periodo date)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_creadas int;
BEGIN
  INSERT INTO public.cuotas (
    tenant_id, contrato_id, cliente_id, cobrador_id,
    periodo, fecha_vencimiento, monto, estado
  )
  SELECT
    c.tenant_id,
    c.id,
    c.cliente_id,
    cli.cobrador_id,
    date_trunc('month', p_periodo)::date,
    public.calcular_fecha_pago(p_periodo, c.dia_pago),
    p.precio_mensual,
    'pendiente'
  FROM public.contratos c
  JOIN public.planes   p   ON p.id = c.plan_id
  JOIN public.clientes cli ON cli.id = c.cliente_id
  WHERE c.tenant_id = p_tenant_id
    AND c.estado = 'activo'
    AND c.fecha_inicio <= public.calcular_fecha_pago(p_periodo, c.dia_pago)
    AND (c.fecha_fin IS NULL OR c.fecha_fin >= date_trunc('month', p_periodo)::date)
  ON CONFLICT (contrato_id, periodo) DO NOTHING;

  GET DIAGNOSTICS v_creadas = ROW_COUNT;
  RETURN v_creadas;
END;
$$;

-- Recrear el índice único de "un contrato activo por cliente+plan".
-- El original (0023) usaba `WHERE activo = true` — fue eliminado
-- implícitamente al dropear la columna `activo` en migración 0052.
DROP INDEX IF EXISTS public.contratos_unique_activo_por_cliente_plan;

CREATE UNIQUE INDEX contratos_unique_activo_por_cliente_plan
  ON public.contratos (cliente_id, plan_id)
  WHERE estado = 'activo';


-- >>> Migration: 0055_fotos_cliente_cobrador_id.sql <<<
-- 0055: Denormalizar cobrador_id en fotos_cliente para sync rules.
-- PowerSync exige que cada query use TODOS los parámetros del bucket.
-- El bucket por_cobrador tiene cobrador_id + tenant_id, así que
-- fotos_cliente necesita cobrador_id para sincronizar al cobrador.

-- 1. Agregar columna
ALTER TABLE public.fotos_cliente
  ADD COLUMN IF NOT EXISTS cobrador_id uuid REFERENCES public.cobradores(id);

-- 2. Poblar rows existentes (si hay alguna)
UPDATE public.fotos_cliente fc
SET cobrador_id = c.cobrador_id
FROM public.clientes c
WHERE fc.cliente_id = c.id;

-- 3. Trigger: al insertar foto, copiar cobrador_id del cliente
CREATE OR REPLACE FUNCTION public.fotos_cliente_set_cobrador_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.cobrador_id := (
    SELECT cobrador_id FROM public.clientes WHERE id = NEW.cliente_id
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_fotos_cliente_set_cobrador
  BEFORE INSERT ON public.fotos_cliente
  FOR EACH ROW EXECUTE FUNCTION public.fotos_cliente_set_cobrador_trg();

-- 4. Trigger cascada: al reasignar cliente, actualizar cobrador_id de sus fotos
CREATE OR REPLACE FUNCTION public.clientes_cascade_cobrador_fotos_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.cobrador_id IS DISTINCT FROM OLD.cobrador_id THEN
    UPDATE public.fotos_cliente
    SET cobrador_id = NEW.cobrador_id
    WHERE cliente_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_clientes_cascade_cobrador_fotos
  AFTER UPDATE OF cobrador_id ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_cascade_cobrador_fotos_trg();


-- >>> Migration: 0056_visitas.sql <<<
-- 0056: Migrar visitas locales (SharedPreferences) a tabla Postgres.
-- Las visitas necesitan sincronizar al admin para que vea quién visitó
-- y cuándo, y también persistir cross-device del cobrador.

CREATE TABLE IF NOT EXISTS public.visitas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  cobrador_id uuid NOT NULL REFERENCES public.cobradores(id),
  resultado text NOT NULL CHECK (resultado IN ('cobrado','no_estaba','sin_pago','promesa_pago','otro')),
  notas text,
  fecha timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON public.visitas (tenant_id, cliente_id, fecha DESC);
CREATE INDEX ON public.visitas (tenant_id, cobrador_id, fecha DESC);

ALTER TABLE public.visitas ENABLE ROW LEVEL SECURITY;

-- Cobrador ve solo visitas de sus clientes asignados.
-- Admin/admin_cobranza ven todas las del tenant.
CREATE POLICY "visitas_read" ON public.visitas
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR cobrador_id = auth.uid()
    )
  );

-- Cualquier usuario del tenant puede registrar visitas (cobradores en
-- campo). El cobrador_id se setea con auth.uid() server-side via trigger.
CREATE POLICY "visitas_insert" ON public.visitas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
  );

-- Solo admin puede eliminar (audit trail — cobrador no debería borrar
-- visitas registradas por error; en su lugar registra una nueva).
CREATE POLICY "visitas_delete" ON public.visitas
  FOR DELETE USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

CREATE POLICY "super_admin_all" ON public.visitas
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());


-- >>> Migration: 0057_visitas_rls_cobrador_id.sql <<<
-- 0057: Reforzar RLS de visitas — el cobrador_id en INSERT debe
-- coincidir con auth.uid() para prevenir que un cobrador autenticado
-- registre visitas en nombre de otro vía REST directo.
-- El comentario original de 0056 mencionaba un trigger que setea
-- cobrador_id server-side, pero ese trigger no se creó. Esta política
-- es la defensa correcta.

DROP POLICY IF EXISTS "visitas_insert" ON public.visitas;

CREATE POLICY "visitas_insert" ON public.visitas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND cobrador_id = auth.uid()
  );


-- >>> Migration: 0058_clientes_block_cobrador_null_con_contratos.sql <<<
-- 0058: Trigger que bloquea remover cobrador_id de cliente con
-- contratos activos. Previene huérfanos operativos.
--
-- Reglas:
--   - Cliente PUEDE existir sin cobrador (captura de prospectos).
--   - Cliente con contratos activos NO PUEDE quedar sin cobrador.
--   - Cambiar cobrador (A → B) está permitido (cascada via trigger 0017).
--   - Sólo se bloquea cambiar a NULL si hay contratos activos.

CREATE OR REPLACE FUNCTION public.clientes_check_cobrador_no_null_con_contratos_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.cobrador_id IS NOT NULL
     AND NEW.cobrador_id IS NULL
     AND EXISTS (
       SELECT 1 FROM public.contratos
       WHERE cliente_id = NEW.id AND estado = 'activo'
     )
  THEN
    RAISE EXCEPTION 'No se puede desasignar el cobrador: el cliente tiene contratos activos. Reasigne primero a otro cobrador.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_check_cobrador_no_null
  ON public.clientes;

CREATE TRIGGER trg_clientes_check_cobrador_no_null
  BEFORE UPDATE OF cobrador_id ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_check_cobrador_no_null_con_contratos_trg();


-- >>> Migration: 0059_contratos_documento_path.sql <<<
-- 0059: Agregar documento_path al contrato.
-- Permite adjuntar PDF/Word/foto del contrato firmado.
-- Solo admin/admin_cobranza pueden subir/eliminar (UI gateado).
-- Storage bucket: contratos-documentos.

ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS documento_path text;

-- Comment para documentar el path scheme: tenant_id/contrato_id/<timestamp>.<ext>
COMMENT ON COLUMN public.contratos.documento_path IS
  'Path en Storage bucket contratos-documentos: {tenant_id}/{contrato_id}/{timestamp}.{ext}';


-- >>> Migration: 0060_storage_contratos_documentos.sql <<<
-- 0060: Bucket de Storage para documentos del contrato + RLS.
-- Path scheme: {tenant_id}/{contrato_id}/{timestamp}.{ext}
-- Permitidos: PDF, JPG, PNG, DOC, DOCX. Límite: 10MB por archivo.

-- 1. Crear bucket (idempotente)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'contratos-documentos',
  'contratos-documentos',
  false,
  10485760,  -- 10 MB
  ARRAY[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- 2. Read: cualquier usuario autenticado del tenant puede leer
DROP POLICY IF EXISTS "storage_read_contratos_documentos" ON storage.objects;
CREATE POLICY "storage_read_contratos_documentos" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'contratos-documentos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- 3. Write (INSERT/UPDATE/DELETE): solo admin/admin_cobranza del tenant
DROP POLICY IF EXISTS "storage_write_contratos_documentos" ON storage.objects;
CREATE POLICY "storage_write_contratos_documentos" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'contratos-documentos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  )
  WITH CHECK (
    bucket_id = 'contratos-documentos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

-- 4. Super admin bypass (consistente con otros buckets)
DROP POLICY IF EXISTS "storage_super_admin_contratos_documentos" ON storage.objects;
CREATE POLICY "storage_super_admin_contratos_documentos" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'contratos-documentos'
    AND public.is_super_admin()
  )
  WITH CHECK (
    bucket_id = 'contratos-documentos'
    AND public.is_super_admin()
  );


-- >>> Migration: 0061_pagos_vuelto_cordobas.sql <<<
-- 0061: Agregar columna pagos.vuelto_cordobas.
--
-- CRÍTICO contable: hasta ahora pagos.monto_cordobas guardaba lo que
-- el cliente ENTREGÓ (incluyendo vuelto). Esto inflaba el recaudado
-- del contrato cuando había vuelto.
--
-- Modelo nuevo:
--   - monto_cordobas: lo APLICADO a la cuota (lo que ingresó a la caja)
--   - vuelto_cordobas: lo devuelto al cliente
--   - entregado_cordobas (calculado en UI): monto_cordobas + vuelto_cordobas
--
-- Para data legacy: la columna nueva default 0. Los pagos viejos asumen
-- que no hubo vuelto (lo cual puede no ser cierto, pero es lo más seguro
-- para no alterar el monto_cordobas existente).

ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS vuelto_cordobas numeric(10,2) NOT NULL DEFAULT 0
    CHECK (vuelto_cordobas >= 0);

COMMENT ON COLUMN public.pagos.vuelto_cordobas IS
  'Vuelto entregado al cliente cuando el monto pagado > saldo de la cuota. '
  'monto_cordobas siempre es lo APLICADO a la cuota.';


-- >>> Migration: 0062_audit_triggers_insert_delete.sql <<<
-- 0062: Completar triggers de audit_changelog para INSERT y DELETE.
--
-- Bug crítico encontrado: la función audit_changelog_trg maneja
-- TG_OP = 'INSERT' / 'UPDATE' / 'DELETE', pero los CREATE TRIGGER
-- de 0047 solo registraron AFTER UPDATE. Resultado: las creaciones
-- y eliminaciones no se registran en audit_log.
--
-- Esta migración:
--   1. Re-crea los triggers existentes con INSERT OR UPDATE OR DELETE
--   2. Agrega triggers para visitas, fotos_cliente, cargos_extra
--      (tablas operativas que también necesitan trazabilidad)

-- pagos
DROP TRIGGER IF EXISTS trg_changelog_pagos ON public.pagos;
CREATE TRIGGER trg_changelog_pagos
  AFTER INSERT OR UPDATE OR DELETE ON public.pagos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- cuotas
DROP TRIGGER IF EXISTS trg_changelog_cuotas ON public.cuotas;
CREATE TRIGGER trg_changelog_cuotas
  AFTER INSERT OR UPDATE OR DELETE ON public.cuotas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- clientes
DROP TRIGGER IF EXISTS trg_changelog_clientes ON public.clientes;
CREATE TRIGGER trg_changelog_clientes
  AFTER INSERT OR UPDATE OR DELETE ON public.clientes
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- contratos
DROP TRIGGER IF EXISTS trg_changelog_contratos ON public.contratos;
CREATE TRIGGER trg_changelog_contratos
  AFTER INSERT OR UPDATE OR DELETE ON public.contratos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- recibos
DROP TRIGGER IF EXISTS trg_changelog_recibos ON public.recibos;
CREATE TRIGGER trg_changelog_recibos
  AFTER INSERT OR UPDATE OR DELETE ON public.recibos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- visitas (nuevo)
DROP TRIGGER IF EXISTS trg_changelog_visitas ON public.visitas;
CREATE TRIGGER trg_changelog_visitas
  AFTER INSERT OR UPDATE OR DELETE ON public.visitas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- fotos_cliente (nuevo)
DROP TRIGGER IF EXISTS trg_changelog_fotos_cliente ON public.fotos_cliente;
CREATE TRIGGER trg_changelog_fotos_cliente
  AFTER INSERT OR UPDATE OR DELETE ON public.fotos_cliente
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- cargos_extra (nuevo)
DROP TRIGGER IF EXISTS trg_changelog_cargos_extra ON public.cargos_extra;
CREATE TRIGGER trg_changelog_cargos_extra
  AFTER INSERT OR UPDATE OR DELETE ON public.cargos_extra
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();


-- >>> Migration: 0063_setting_caja_chica.sql <<<
-- 0063: Setting caja_chica.habilitada (toggle admin).
--
-- Feature futura: tracking de caja chica del cobrador para reconciliar
-- vueltos entregados vs efectivo cobrado vs efectivo entregado al admin
-- al final del día.
--
-- Esta migración solo agrega el toggle. La feature real (tabla
-- cajas_chicas + UI de asignación/reconciliación) queda para sprint
-- futuro cuando el toggle esté en ON en algún tenant que lo necesite.

INSERT INTO public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'caja_chica.habilitada', 'false'::jsonb, 'boolean', 'cobranza',
       'Habilitar gestión de caja chica del cobrador (asignación diaria y reconciliación de efectivo)',
       'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;


-- >>> Migration: 0064_backfill_vuelto_legacy.sql <<<
-- 0064: Backfill de pagos legacy con vuelto (anteriores a migración 0061).
--
-- Antes del fix del vuelto (0061), pagos.monto_cordobas guardaba lo que el
-- cliente ENTREGÓ. Si pagó de más, la cuota quedó con monto_pagado > total
-- (sobrepago, viola INV4) y el recaudado del contrato quedó inflado.
--
-- Este script repara la corrupción histórica: por cada cuota sobrepagada,
-- mueve el exceso del pago más reciente a vuelto_cordobas. El trigger
-- trg_pagos_update_recalcular recalcula cuota.monto_pagado automáticamente.
--
-- IDEMPOTENTE: solo toca pagos cuya cuota está sobrepagada. Correrlo de
-- nuevo no hace nada (ya no hay sobrepago tras la primera corrida).
--
-- Detectado por: supabase/tests/invariantes_dinero.sql → INV4.

WITH sobrepago AS (
  SELECT cu.id AS cuota_id,
         cu.monto_pagado - (cu.monto + COALESCE(cu.cargos_neto, 0)) AS exceso
  FROM public.cuotas cu
  WHERE cu.estado <> 'anulada'
    AND cu.monto_pagado > (cu.monto + COALESCE(cu.cargos_neto, 0)) + 0.01
),
pago_objetivo AS (
  -- El pago más reciente NO anulado de cada cuota sobrepagada.
  -- Es el que recibió el exceso (el cliente entregó de más en ese cobro).
  SELECT DISTINCT ON (p.cuota_id)
         p.id AS pago_id, s.exceso
  FROM public.pagos p
  JOIN sobrepago s ON s.cuota_id = p.cuota_id
  WHERE p.anulado = false
  ORDER BY p.cuota_id, p.fecha_pago DESC
)
UPDATE public.pagos p
SET monto_cordobas  = p.monto_cordobas - po.exceso,
    vuelto_cordobas = p.vuelto_cordobas + po.exceso
FROM pago_objetivo po
WHERE p.id = po.pago_id
  AND p.monto_cordobas >= po.exceso;  -- guard defensivo: no dejar negativo


-- >>> Migration: 0065_fix_coherencia_moneda_vuelto.sql <<<
-- 0065: Corregir constraint pagos_coherencia_moneda para el modelo de vuelto.
--
-- BUG CRÍTICO DE PRODUCCIÓN encontrado al correr el backfill 0064:
-- el constraint viejo (migración 0005) exigía para NIO:
--     monto_cordobas = monto_original
-- Eso era válido ANTES del vuelto, cuando monto_cordobas == lo entregado.
--
-- Con el modelo de vuelto (0061):
--   - monto_original  = lo ENTREGADO en moneda original
--   - monto_cordobas  = lo APLICADO a la cuota
--   - vuelto_cordobas = lo devuelto al cliente (siempre NIO)
--   - Invariante: entregado = aplicado + vuelto
--
-- Para NIO (tasa=1): monto_original = monto_cordobas + vuelto_cordobas.
-- Sin este fix, CUALQUIER cobro NIO con vuelto sería rechazado por el
-- constraint. (USD se deja laxo: tasa>0, por redondeo de conversión; INV1
-- en invariantes_dinero.sql verifica la coherencia USD con tolerancia.)
--
-- Legacy sin vuelto: monto_original = monto_cordobas + 0 → sigue cumpliendo.

ALTER TABLE public.pagos DROP CONSTRAINT IF EXISTS pagos_coherencia_moneda;

ALTER TABLE public.pagos ADD CONSTRAINT pagos_coherencia_moneda
  CHECK (
    (moneda = 'NIO'
       AND tasa_conversion = 1
       AND ABS(monto_original - (monto_cordobas + vuelto_cordobas)) < 0.01)
    OR
    (moneda = 'USD' AND tasa_conversion > 0)
  );


-- >>> Migration: 0066_cobradores_freeze_rol.sql <<<
-- 0066: Congelar la columna `rol` de cobradores (defensa M1-SEC).
--
-- BUG de escalación de privilegios encontrado en el audit de seguridad:
-- la policy cobradores_write_admin (0013) permite a un admin UPDATE sobre
-- cobradores de su tenant sin restringir QUÉ columnas. El constraint
-- cobradores_rol_check (0026) acepta 'super_admin'. No hay nada que impida:
--     UPDATE cobradores SET rol='super_admin' WHERE id = <propio uid>
-- → is_super_admin() pasa a true → acceso cross-tenant total.
--
-- La app NUNCA hace este UPDATE (usa la RPC set_cobrador_rol, que valida).
-- Pero RLS no fuerza a pasar por la RPC. Este trigger cierra el hueco:
-- nadie puede asignar/mantener rol='super_admin' ni mutar rol/tenant_id
-- salvo que el caller sea super_admin (o sea el propio trigger SECURITY
-- DEFINER de creación de usuario, que corre como postgres sin auth.uid()).

CREATE OR REPLACE FUNCTION public.cobradores_freeze_rol_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Si no hay sesión de usuario (auth.uid() NULL), es un proceso del
  -- sistema (handle_new_user, Edge Function con service_role, RPC
  -- SECURITY DEFINER). Esos ya validan internamente — no los bloqueamos.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- super_admin puede todo (gestión cross-tenant legítima).
  IF public.is_super_admin() THEN
    RETURN NEW;
  END IF;

  -- A partir de acá: caller autenticado que NO es super_admin.

  -- Nadie no-super_admin puede crear/asignar el rol super_admin.
  IF NEW.rol = 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado a asignar el rol super_admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- En UPDATE: no se puede mutar rol ni tenant_id por escritura directa.
  -- (El cambio legítimo de rol pasa por la RPC set_cobrador_rol, que corre
  --  como SECURITY DEFINER con auth.uid() pero valida reglas de negocio;
  --  esa RPC está exenta porque no escribe rol directamente desde un
  --  caller no-super_admin sin sus propios checks. Si en el futuro la RPC
  --  necesita escribir rol, se ejecuta con el guard de la propia RPC.)
  IF TG_OP = 'UPDATE' THEN
    IF NEW.rol IS DISTINCT FROM OLD.rol THEN
      RAISE EXCEPTION 'El rol solo puede cambiarse vía la función set_cobrador_rol'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
      RAISE EXCEPTION 'No autorizado a cambiar el tenant de un cobrador'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cobradores_freeze_rol ON public.cobradores;

CREATE TRIGGER trg_cobradores_freeze_rol
  BEFORE INSERT OR UPDATE ON public.cobradores
  FOR EACH ROW
  EXECUTE FUNCTION public.cobradores_freeze_rol_trg();


-- >>> Migration: 0067_geo_update_delete_policies.sql <<<
-- 0067: Policies UPDATE/DELETE para tablas geo (fix M2-DB).
--
-- departamentos/municipios/comunidades tenían SELECT (0003) e INSERT
-- (geo_insert_admins, 0016) pero NINGUNA policy UPDATE/DELETE. Con RLS
-- habilitado, eso = operación denegada silenciosamente. /admin/geografia
-- expone editar/borrar, así que esas acciones fallaban sin error claro.
--
-- Decisión del producto: el admin puede editar/borrar geo. Las tablas geo
-- son globales (sin tenant_id) — cualquier admin de cualquier tenant las
-- gestiona (catálogo compartido de Nicaragua). super_admin también.

-- Helper: admin de cualquier tenant o super_admin.
-- is_admin() ya cubre admin del tenant; is_super_admin() para Rubén.

-- ── departamentos ──────────────────────────────────────────────────────
DROP POLICY IF EXISTS "geo_update_admins" ON public.departamentos;
CREATE POLICY "geo_update_admins" ON public.departamentos
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_super_admin())
  WITH CHECK (public.is_admin() OR public.is_super_admin());

DROP POLICY IF EXISTS "geo_delete_admins" ON public.departamentos;
CREATE POLICY "geo_delete_admins" ON public.departamentos
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_super_admin());

-- ── municipios ─────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "geo_update_admins" ON public.municipios;
CREATE POLICY "geo_update_admins" ON public.municipios
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_super_admin())
  WITH CHECK (public.is_admin() OR public.is_super_admin());

DROP POLICY IF EXISTS "geo_delete_admins" ON public.municipios;
CREATE POLICY "geo_delete_admins" ON public.municipios
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_super_admin());

-- ── comunidades ────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "geo_update_admins" ON public.comunidades;
CREATE POLICY "geo_update_admins" ON public.comunidades
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_super_admin())
  WITH CHECK (public.is_admin() OR public.is_super_admin());

DROP POLICY IF EXISTS "geo_delete_admins" ON public.comunidades;
CREATE POLICY "geo_delete_admins" ON public.comunidades
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_super_admin());


-- >>> Migration: 0068_consolidar_cascade_cobrador.sql <<<
-- 0068: Consolidar la cascada de reasignación de cobrador (fix M6-DB).
--
-- Había dos triggers independientes sobre clientes AFTER UPDATE OF cobrador_id:
--   - trg_propagate_cobrador_id_clientes (0002/0034) → contratos, cuotas,
--     notificaciones_mora, cargos_extra
--   - trg_clientes_cascade_cobrador_fotos (0055) → fotos_cliente
-- Funcionaban, pero fragmentados: agregar una tabla dependiente nueva exige
-- recordar tocar el lugar correcto. Riesgo de desincronización a futuro.
--
-- Fix: una sola función propagate_cobrador_id_from_cliente que cubre TODAS
-- las tablas dependientes (incluida fotos_cliente). Un solo trigger.

CREATE OR REPLACE FUNCTION public.propagate_cobrador_id_from_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.cobrador_id IS DISTINCT FROM OLD.cobrador_id THEN
    UPDATE public.contratos
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- Solo cuotas operativas. Las pagadas/anuladas preservan el cobrador_id
    -- del momento del pago (historial inmutable).
    UPDATE public.cuotas
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND estado IN ('pendiente','parcial');

    UPDATE public.notificaciones_mora
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND resuelta_en IS NULL;

    UPDATE public.cargos_extra
       SET cobrador_id = NEW.cobrador_id
     WHERE cuota_id IN (
       SELECT id FROM public.cuotas
        WHERE cliente_id = NEW.id
          AND estado IN ('pendiente','parcial')
     );

    -- fotos_cliente: consolidado acá (antes trigger separado 0055).
    UPDATE public.fotos_cliente
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- pagos / recibos NO se propagan: snapshot histórico inmutable.
  END IF;
  RETURN NEW;
END;
$$;

-- Eliminar el trigger separado de fotos (su lógica ya vive en la función
-- consolidada). El trigger principal trg_propagate_cobrador_id_clientes
-- sigue apuntando a la misma función actualizada — no hace falta recrearlo.
DROP TRIGGER IF EXISTS trg_clientes_cascade_cobrador_fotos ON public.clientes;

-- La función clientes_cascade_cobrador_fotos_trg queda huérfana (sin trigger
-- que la use). La dejamos por compatibilidad de rollback; no se ejecuta.


-- >>> Migration: 0069_audit_ocurrido_en.sql <<<
-- 0069: Change Log Fase B — guardar la HORA REAL DEL DISPOSITIVO de cada acción.
--
-- Problema: hoy audit_log usa `created_at` (hora del server al sincronizar).
-- En offline-first, una acción hecha sin conexión se registra recién cuando
-- PowerSync sincroniza — la hora del historial NO refleja cuándo el cobrador
-- realmente hizo la acción.
--
-- Solución: columna uniforme `ocurrido_en timestamptz` en las tablas
-- auditadas. El cliente la setea con la hora de dispositivo en UTC
-- (DateTime.now().toUtc()). El trigger genérico la copia a
-- `audit_log.ocurrido_en`. El historial la muestra con `.toLocal()`.
--
-- Idempotente (IF NOT EXISTS / CREATE OR REPLACE). Solo corre en Postgres.
-- Envuelta en transacción: columnas + funciones + backfill todo-o-nada.

BEGIN;

-- 1. Columna en audit_log (sin default: la setea el trigger vía COALESCE).
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;

-- 2. Columna en las 8 tablas de entidad SIN DEFAULT.
--    Motivo: `DEFAULT now()` es VOLATILE → Postgres reescribe físicamente
--    toda la tabla con lock ACCESS EXCLUSIVE (lento/bloqueante en tablas
--    grandes). Sin default, el ADD COLUMN es metadata-only (instantáneo).
--    El cliente setea ocurrido_en en cada write; el trigger hace COALESCE a
--    now() como fallback. El backfill de filas viejas es opcional (el display
--    lee audit_log.ocurrido_en, no estas columnas) — no hace falta.
ALTER TABLE public.pagos         ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.cuotas        ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.clientes      ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.contratos     ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.recibos       ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.cargos_extra  ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.visitas       ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.fotos_cliente ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;

-- 3. audit_registrar: nuevo param p_ocurrido_en (con DEFAULT NULL → no rompe
--    callers existentes). Inserta ocurrido_en = COALESCE(p_ocurrido_en, now()).
CREATE OR REPLACE FUNCTION public.audit_registrar(
  p_tenant_id uuid,
  p_tabla text,
  p_registro_id uuid,
  p_campo text,
  p_valor_anterior jsonb,
  p_valor_nuevo jsonb,
  p_accion text DEFAULT 'update',
  p_ocurrido_en timestamptz DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, accion,
    user_id, user_rol, ocurrido_en
  ) VALUES (
    p_tenant_id, p_tabla, p_registro_id, p_campo,
    p_valor_anterior, p_valor_nuevo, p_accion,
    auth.uid(), public.current_user_rol(),
    COALESCE(p_ocurrido_en, now())
  );
END;
$$;

-- 4. audit_changelog_trg: computar el device time genéricamente desde
--    la columna ocurrido_en de la fila y pasarlo a audit_registrar.
--    NO se cambia la lógica de depth/guard ni los eventos.
CREATE OR REPLACE FUNCTION public.audit_changelog_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dev timestamptz;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_dev := (to_jsonb(NEW)->>'ocurrido_en')::timestamptz;
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      to_jsonb(OLD), to_jsonb(NEW), 'update', v_dev
    );
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    v_dev := (to_jsonb(NEW)->>'ocurrido_en')::timestamptz;
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      NULL, to_jsonb(NEW), 'create', v_dev
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    v_dev := (to_jsonb(OLD)->>'ocurrido_en')::timestamptz;
    PERFORM public.audit_registrar(
      OLD.tenant_id, TG_TABLE_NAME, OLD.id, NULL,
      to_jsonb(OLD), NULL, 'delete', v_dev
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

-- 5. Backfill: las filas viejas del audit_log muestran su hora server
--    (mejor que null). Acotado e idempotente.
UPDATE public.audit_log SET ocurrido_en = created_at WHERE ocurrido_en IS NULL;

COMMIT;


-- >>> Migration: 0070_fix_audit_registrar_overload.sql <<<
-- 0070_fix_audit_registrar_overload.sql
--
-- BUG: editar CUALQUIER setting (WhatsApp, tasa USD, nombre empresa, config de
-- cobranza, recibos, etc.) tiraba:
--   "function public.audit_registrar(uuid, unknown, uuid, text, jsonb, jsonb)
--    is not unique"
-- y la sincronización a Postgres se rechazaba, así que el valor NO persistía.
--
-- CAUSA RAÍZ: la migración 0069 agregó el overload de 8 args (con p_ocurrido_en)
-- pero NO dropeó el de 7 args que había dejado 0047. Ambos aceptan una llamada
-- de 6 args (rellenan sus DEFAULT), así que `audit_settings_trg` (0020) — el
-- único trigger viejo que sobrevivió al barrido de 0047 y todavía llama con
-- 6 args — no podía resolver a cuál de los dos invocar → ambigüedad.
--
-- Por qué solo settings fallaba: 0047 reemplazó los triggers específicos de
-- pagos/cuotas/clientes/recibos por el genérico `audit_changelog_trg` (que
-- llama con 8 args, sin ambigüedad), pero `trg_audit_settings` quedó afuera.
--
-- FIX (dos partes):
--   1. Eliminar el overload redundante de 7 args (causa raíz de la ambigüedad).
--   2. Modernizar `audit_settings_trg` para que invoque el de 8 args EXPLÍCITO:
--      ya no depende de la resolución por defaults (defensa en profundidad) y
--      conserva el audit por-clave limpio (mejor que el genérico, que logearía
--      el row completo de settings).
--
-- Solo función server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

-- 1. Eliminar el overload de 7 args que colisiona con el de 8 args (0069).
DROP FUNCTION IF EXISTS public.audit_registrar(
  uuid, text, uuid, text, jsonb, jsonb, text
);

-- 2. Reescribir el trigger de settings para invocar el de 8 args explícito.
--    (El trigger `trg_audit_settings` sigue enganchado; solo cambia el cuerpo.)
CREATE OR REPLACE FUNCTION public.audit_settings_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF new.valor IS DISTINCT FROM old.valor THEN
    PERFORM public.audit_registrar(
      new.tenant_id,           -- p_tenant_id
      'settings',              -- p_tabla
      new.id,                  -- p_registro_id
      new.clave,               -- p_campo
      to_jsonb(old.valor),     -- p_valor_anterior
      to_jsonb(new.valor),     -- p_valor_nuevo
      'update',                -- p_accion (explícito)
      NULL                     -- p_ocurrido_en (settings no tiene la columna)
    );
  END IF;
  RETURN new;
END;
$$;

COMMIT;


-- >>> Migration: 0071_codigo_cliente.sql <<<
-- 0071_codigo_cliente.sql
--
-- Feature: "código de cliente" — identificador simbólico legible que cada
-- ISP asigna a sus clientes (ej. CL00027). NO reemplaza el UUID (que sigue
-- siendo PK y FK interno de TODO); es la identidad VISUAL del cliente en
-- toda la app y en los módulos futuros (inventario, técnicos, etc.).
--
-- Reglas (decididas con el usuario):
--   - Manual, alfanumérico, obligatorio a nivel app al crear.
--   - Único por tenant, case-insensitive (CL27 == cl27 == Cl27).
--   - Inmutable una vez asignado; SOLO el super_admin puede corregir un typo
--     (queda registrado en audit_log vía el trigger genérico de changelog).
--
-- La columna es nullable a nivel DB para tolerar offline y clientes legacy;
-- la obligatoriedad se valida en el form. `clientes` usa SELECT * en las
-- sync rules → REDEPLOYAR sync rules para que la columna baje a los clientes.

BEGIN;

-- 1. Columna.
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS codigo text;

-- 2. Unicidad por tenant, case-insensitive, ignorando NULLs (clientes legacy
--    sin código aún + offline). El upper() hace que CL27 y cl27 colisionen.
CREATE UNIQUE INDEX IF NOT EXISTS clientes_codigo_tenant_uq
  ON public.clientes (tenant_id, upper(codigo))
  WHERE codigo IS NOT NULL;

-- 3. Inmutabilidad: una vez asignado (no-NULL), solo el super_admin puede
--    cambiarlo. admin/cobrador reciben excepción. La asignación inicial
--    (NULL → valor) siempre se permite. Mismo patrón que cobradores_freeze_rol.
CREATE OR REPLACE FUNCTION public.clientes_codigo_inmutable_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.codigo IS NOT NULL
     AND NEW.codigo IS DISTINCT FROM OLD.codigo
     AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION
      'El código del cliente es inmutable una vez asignado (actual: %).', OLD.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_codigo_inmutable ON public.clientes;
CREATE TRIGGER trg_clientes_codigo_inmutable
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_codigo_inmutable_trg();

COMMIT;


-- >>> Migration: 0072_contrato_duracion_meses.sql <<<
-- 0072_contrato_duracion_meses.sql
-- Materializa la duración del contrato como columna inmutable.
--
-- Invariante de dinero #5: el total de un contrato fijo = precio_mensual ×
-- meses DEFINIDOS AL CREAR, nunca re-derivado. Hasta ahora el total se
-- recalculaba en la UI desde (fecha_fin - fecha_inicio), lo que sería
-- incorrecto si en el futuro se permite editar fecha_fin (extensión /
-- renovación de contrato). Guardamos la duración una vez y la usamos como
-- fuente de verdad.
--
-- NULL = contrato indefinido (sin total fijo; solo se reporta el recaudado
-- acumulado, invariante #6).

ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS duracion_meses integer;

-- Backfill desde las fechas existentes, con EXACTAMENTE la misma fórmula que
-- usaba la UI (años*12 + diff de meses) para no cambiar ningún total ya
-- mostrado. fecha_fin NULL (indefinido) deja duracion_meses en NULL.
UPDATE public.contratos
   SET duracion_meses = (
           (EXTRACT(YEAR  FROM fecha_fin::date)::int
          - EXTRACT(YEAR  FROM fecha_inicio::date)::int) * 12
         + (EXTRACT(MONTH FROM fecha_fin::date)::int
          - EXTRACT(MONTH FROM fecha_inicio::date)::int)
       )
 WHERE fecha_fin IS NOT NULL
   AND duracion_meses IS NULL;


-- >>> Migration: 0073_contrato_fecha_primer_cobro.sql <<<
-- 0073_contrato_fecha_primer_cobro.sql
-- Fecha explícita del primer cobro del contrato.
--
-- Hasta ahora la primera cuota se derivaba de (mes de fecha_inicio + dia_pago),
-- saltando al mes siguiente si esa fecha caía antes de la instalación. Era
-- correcto pero opaco: el admin no veía ni controlaba cuándo vencía la
-- primera cuota. Ahora el form pide "fecha del primer cobro" y de ahí se
-- deriva el dia_pago mensual. La primera cuota vence EXACTAMENTE en esa
-- fecha; las siguientes son mensuales en el mismo día.
--
-- Esta migración:
--   1. Agrega contratos.fecha_primer_cobro (date, nullable = contratos viejos).
--   2. Backfill: calcula la fecha que el sistema YA usaba para el primer mes
--      con cuota → NO cambia ninguna cuota existente.
--   3. Reescribe generar_cuotas_contrato para anclar el período inicial al mes
--      de fecha_primer_cobro. Idempotente (ON CONFLICT do nothing): no toca
--      cuotas ya creadas, solo afecta contratos nuevos.

-- =========================================================================
-- 1. Columna
-- =========================================================================
ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS fecha_primer_cobro date;

-- =========================================================================
-- 2. Backfill con la MISMA fecha que el sistema ya calculaba
-- =========================================================================
-- Lógica original (migración 0015): se itera desde el mes de fecha_inicio y
-- la primera cuota real es la del primer mes cuyo vencimiento NO sea anterior
-- a fecha_inicio. Reproducimos eso: si el vencimiento del mes de instalación
-- cae antes de la instalación, el primer cobro es el mes siguiente.
UPDATE public.contratos c
   SET fecha_primer_cobro = CASE
         WHEN public.calcular_fecha_pago(c.fecha_inicio, c.dia_pago) >= c.fecha_inicio
           THEN public.calcular_fecha_pago(c.fecha_inicio, c.dia_pago)
         ELSE public.calcular_fecha_pago(
                (date_trunc('month', c.fecha_inicio) + interval '1 month')::date,
                c.dia_pago)
       END
 WHERE c.fecha_primer_cobro IS NULL;

-- =========================================================================
-- 3. Reescribir generar_cuotas_contrato anclando al primer cobro
-- =========================================================================
-- Cambios vs 0015:
--   - El loop arranca en el MES de fecha_primer_cobro (no el de fecha_inicio).
--   - El vencimiento del período inicial es fecha_primer_cobro EXACTA; los
--     siguientes usan calcular_fecha_pago (clamp último día + ajuste domingo).
--   - Fallback: si fecha_primer_cobro es NULL (no debería tras backfill), cae
--     a la lógica vieja basada en fecha_inicio + dia_pago.
CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(
  p_contrato_id uuid,
  p_meses int DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_max_meses     int;
  v_creadas       int := 0;
  v_ancla         date;   -- mes 0 del loop (mes del primer cobro)
  v_periodo       date;
  v_vencimiento   date;
  v_inserto       boolean;
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes ancla: el del primer cobro (o el de fecha_inicio si falta el dato).
  v_ancla := date_trunc('month',
               coalesce(v_contrato.fecha_primer_cobro, v_contrato.fecha_inicio))::date;

  -- Cuántos meses iterar.
  IF p_meses IS NOT NULL THEN
    v_max_meses := p_meses;
  ELSIF v_contrato.fecha_fin IS NULL THEN
    v_max_meses := 3;  -- indefinido: colchón inicial
  ELSE
    -- diff en meses entre el ancla y fecha_fin, +1 para incluir ambos extremos.
    v_max_meses := ((extract(year from v_contrato.fecha_fin) - extract(year from v_ancla)) * 12
                  + (extract(month from v_contrato.fecha_fin) - extract(month from v_ancla)))::int + 1;
  END IF;

  FOR i IN 0 .. v_max_meses - 1 LOOP
    v_periodo := (v_ancla + (i || ' months')::interval)::date;

    -- Período inicial: vencimiento = fecha_primer_cobro exacta (si existe).
    -- Resto de meses: calcular_fecha_pago normal.
    IF i = 0 AND v_contrato.fecha_primer_cobro IS NOT NULL THEN
      v_vencimiento := v_contrato.fecha_primer_cobro;
    ELSE
      v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);
    END IF;

    -- Fuera de rango por fecha_fin → terminar.
    EXIT WHEN v_contrato.fecha_fin IS NOT NULL AND v_periodo > v_contrato.fecha_fin;

    INSERT INTO public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) VALUES (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    ON CONFLICT (contrato_id, periodo) DO NOTHING;

    GET DIAGNOSTICS v_inserto = ROW_COUNT;
    IF v_inserto THEN
      v_creadas := v_creadas + 1;
    END IF;
  END LOOP;

  RETURN v_creadas;
END;
$$;


-- >>> Migration: 0074_contratos_facturacion_vencida.sql <<<
-- 0074_contratos_facturacion_vencida.sql
-- Modelo de facturación VENCIDA + retroactividad de indefinidos + extras.
--
-- Cambios de negocio (decisión de Rubén, ver REPORTE-SESION):
--   1. La primera cuota vence el MES SIGUIENTE a la instalación, mismo día.
--      Antes la primera cuota podía caer en el mes de instalación (modelo
--      "adelantado"). Ahora es VENCIDA: el cliente paga al final del período
--      de servicio. Instalado el 14/may → primera cuota vence 14/jun.
--   2. El día de pago sale de la fecha de instalación (un solo campo en el
--      form). fecha_primer_cobro deja de ser un input del admin; el server
--      la deriva (= mes siguiente). Se mantiene la columna poblada para la UI.
--   3. Contratos FIJOS: se generan exactamente `duracion_meses` cuotas
--      (invariante de dinero #5: total = precio × meses definidos al crear).
--   4. Contratos INDEFINIDOS: se generan retroactivamente desde el primer
--      cobro hasta hoy + colchón de 3 meses. El cron extiende el colchón
--      mes a mes. Antes solo se generaban 3 cuotas fijas desde el ancla.
--   5. El "mes simbólico" que sale en el recibo (mes con más días del período)
--      NO se almacena: se deriva en el cliente desde (periodo, dia_pago). Por
--      eso esta migración NO toca la columna `periodo` ni las cuotas viejas.
--   6. Columnas nuevas: contratos.costo_instalacion + contratos.notas
--      (informativas; no generan cobro automático en este sprint).
--
-- NOTA sobre `periodo`: sigue siendo el primer día del MES DE VENCIMIENTO de
-- la cuota (igual que 0073). El dedup (contrato_id, periodo) no cambia.

-- =========================================================================
-- 1. Columnas nuevas en contratos
-- =========================================================================
ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS costo_instalacion numeric(10,2),
  ADD COLUMN IF NOT EXISTS notas text;

-- =========================================================================
-- 2. generar_cuotas_contrato — modelo vencido + retroactividad
-- =========================================================================
-- Idempotente vía ON CONFLICT (contrato_id, periodo). Devuelve cuántas creó.
-- Se la llama desde el trigger AFTER INSERT (0015) y desde el cron (abajo).
CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(
  p_contrato_id uuid,
  p_meses int DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_num_cuotas    int;          -- cuántas cuotas generar
  v_creadas       int := 0;
  v_primer_mes    date;         -- mes de vencimiento de la 1ª cuota (mes sig. a instalación)
  v_periodo       date;         -- mes de vencimiento de la cuota i
  v_vencimiento   date;
  v_inserto       boolean;
  v_colchon       constant int := 3;  -- meses adelante a pregenerar (indefinidos)
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  -- Contrato no activo (cancelado): no generar nada nuevo.
  IF v_contrato.estado IS DISTINCT FROM 'activo' THEN
    RETURN 0;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes de vencimiento de la PRIMERA cuota = mes siguiente a la instalación.
  -- Facturación vencida: paga al final del período de servicio. Se deriva de
  -- fecha_inicio (autoridad del dinero); el form pobla fecha_primer_cobro
  -- aparte, solo para display.
  v_primer_mes := (date_trunc('month', v_contrato.fecha_inicio) + interval '1 month')::date;

  -- Cuántas cuotas generar.
  IF p_meses IS NOT NULL THEN
    v_num_cuotas := p_meses;
  ELSIF v_contrato.duracion_meses IS NOT NULL THEN
    -- Fijo: exactamente duracion_meses cuotas (invariante de dinero #5).
    v_num_cuotas := v_contrato.duracion_meses;
  ELSE
    -- Indefinido: desde el primer mes hasta hoy + colchón. Retroactivo:
    -- si el contrato arrancó hace meses, genera las que falten. El cron
    -- recalcula cada mes con current_date → mantiene el colchón futuro.
    v_num_cuotas := GREATEST(
      0,
      ((extract(year  from current_date)::int - extract(year  from v_primer_mes)::int) * 12
     +  (extract(month from current_date)::int - extract(month from v_primer_mes)::int))
      + 1 + v_colchon
    );
  END IF;

  FOR i IN 0 .. v_num_cuotas - 1 LOOP
    v_periodo := (v_primer_mes + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    INSERT INTO public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) VALUES (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    ON CONFLICT (contrato_id, periodo) DO NOTHING;

    GET DIAGNOSTICS v_inserto = ROW_COUNT;
    IF v_inserto THEN
      v_creadas := v_creadas + 1;
    END IF;
  END LOOP;

  RETURN v_creadas;
END;
$$;

-- =========================================================================
-- 3. generar_cuotas_mes — ahora delega en generar_cuotas_contrato (DRY)
-- =========================================================================
-- Mantiene la firma vieja por compatibilidad. p_periodo se ignora (la lógica
-- de fechas vive en generar_cuotas_contrato). Itera los contratos activos del
-- tenant y deja que cada uno genere/extienda sus cuotas. Idempotente.
CREATE OR REPLACE FUNCTION public.generar_cuotas_mes(
  p_tenant_id uuid,
  p_periodo date DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total int := 0;
  v_c     record;
BEGIN
  FOR v_c IN
    SELECT id FROM public.contratos
     WHERE tenant_id = p_tenant_id AND estado = 'activo'
  LOOP
    v_total := v_total + public.generar_cuotas_contrato(v_c.id);
  END LOOP;
  RETURN v_total;
END;
$$;

-- =========================================================================
-- 4. Cron: regenerar/extender cuotas el 1° de cada mes
-- =========================================================================
-- Llama generar_cuotas_contrato por cada contrato activo de todos los
-- tenants. Para fijos ya completos es no-op (ON CONFLICT). Para indefinidos
-- extiende el colchón de 3 meses hacia adelante.
SELECT cron.unschedule('generar_cuotas_mensual');
SELECT cron.schedule(
  'generar_cuotas_mensual',
  '5 6 1 * *',
  $$
    SELECT public.generar_cuotas_contrato(c.id)
    FROM public.contratos c
    WHERE c.estado = 'activo';
  $$
);


-- >>> Migration: 0075_recalcular_cuota_ocurrido_en.sql <<<
-- 0075: recalcular_cuota_desde_pagos propaga ocurrido_en (device time).
--
-- PROBLEMA (Change Log / historial de cobro):
-- Al registrar un cobro, el trigger server-side recalcular_cuota_desde_pagos
-- (0012/0018) recalcula cuotas.monto_pagado + estado, pero NO seteaba
-- ocurrido_en. Esa funcion es anterior a la 0069 (que introdujo el device
-- time). Como la columna cuotas.ocurrido_en venia en NULL (la generacion
-- mensual tampoco la setea), el audit_log de ESE cambio — el real:
-- pendiente->pagada — caia al COALESCE(p_ocurrido_en, now()) de
-- audit_registrar, quedando con la HORA DE SYNC del server en vez de la hora
-- real del cobro. El cliente ademas hace su propio UPDATE de la cuota con el
-- device time correcto, pero llega despues del trigger y queda no-op.
--
-- CONSECUENCIA observada (confirmada con audit_log real de un cobro
-- multi-cuota):
--   * La 2da cuota del cobro tenia su cambio real (pendiente->pagada) con
--     ocurrido_en = server time, a >3s del device time del pago. El
--     HistorialCuotaWidget agrupa pago<->cuota por una ventana de 3s sobre
--     ocurrido_en, asi que ese cambio NO se agrupaba con el pago y aparecia
--     "pendiente->pagada" colgando suelto, desconectado del cobro.
--   * En cobros offline sincronizados tarde, el historial mostraba la hora de
--     sync, no la del cobro — exactamente lo que la 0069 buscaba evitar.
--
-- FIX:
-- El UPDATE de la cuota propaga ocurrido_en desde la fila que disparo el
-- trigger (el pago en pagos, o el cargo en cargos_extra) via
-- coalesce(new.ocurrido_en, old.ocurrido_en, now()) — mismo patron que el
-- coalesce(new.cuota_id, old.cuota_id) que la funcion ya usaba. Asi el cambio
-- canonico de la cuota lleva el device time del cobro y se alinea con el pago.
--
-- NO cambia la logica de monto_pagado/estado: solo agrega ocurrido_en al SET.
-- Las invariantes de dinero quedan intactas (monto_pagado sigue siendo
-- SUM(pagos no anulados); estado se deriva igual). Idempotente
-- (CREATE OR REPLACE). Solo funcion server-side: NO toca schema.dart, db.dart
-- ni sync rules.
--
-- Se aplica el MISMO fix a cargos_extra_actualizar_neto_trg (0023), que
-- actualiza cuotas.cargos_neto cuando se inserta/edita/borra un cargo extra
-- (ej. reconexion durante el cobro) y tampoco propagaba ocurrido_en — mismo
-- sintoma de desalineacion en el historial del cobro-con-cargo.

BEGIN;

create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  -- ocurrido_en: propagar el device time del pago/cargo que disparo el
  -- trigger. coalesce con old (caso DELETE) y now() (fallback, ej. la fila
  -- disparadora no traia device time). Mismo patron que coalesce(new.cuota_id,
  -- old.cuota_id) de arriba.
  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

-- Mismo fix para el trigger de cargos_neto: propagar el device time del
-- cargo_extra que disparo el recalculo. Sin esto, el cobro con cargo de
-- reconexion deja el cambio de cargos_neto de la cuota con hora de sync.
create or replace function public.cargos_extra_actualizar_neto_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);
  update public.cuotas
     set cargos_neto = public.calcular_cargos_neto(v_cuota_id),
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;
  return coalesce(new, old);
end;
$$;

COMMIT;


-- >>> Migration: 0076_audit_planes.sql <<<
-- 0076_audit_planes.sql
-- Change log para `planes`: cierra el gap de cobertura del audit/historial.
--
-- Bajo la regla de change log universal (ver CLAUDE.md): toda entidad editable
-- por usuarios debe tener su historial. `planes` quedaba afuera de los 8
-- triggers de 0062. Acá se suma.
--
-- `planes` es per-tenant (tiene tenant_id), así que el trigger genérico
-- `audit_changelog_trg` (0047/0062/0069) aplica directo, sin variantes.
--
-- NO se agrega columna `ocurrido_en`: los planes los edita el admin ONLINE
-- desde el panel web, no el cobrador offline, así que el device-time no aporta.
-- El trigger lee `to_jsonb(NEW)->>'ocurrido_en'`; al faltar la key devuelve
-- NULL (no error) → `audit_log.ocurrido_en` queda NULL → la UI cae a
-- `created_at` vía COALESCE. Correcto para una entidad online-only.
--
-- Sin cambios de PowerSync schema/sync: `audit_log` ya sincroniza (SELECT *) y
-- `planes` no cambia de columnas. Las filas de audit de un plan heredan su
-- tenant_id → visibles solo para ese tenant (RLS de audit_log).

begin;

drop trigger if exists trg_changelog_planes on public.planes;
create trigger trg_changelog_planes
  after insert or update or delete on public.planes
  for each row when (pg_trigger_depth() < 2)
  execute function public.audit_changelog_trg();

commit;


-- >>> Migration: 0077_codigo_contrato.sql <<<
-- 0077_codigo_contrato.sql
--
-- Feature: "código de contrato" — identificador simbólico legible por contrato,
-- MISMA DINÁMICA que el código de cliente (0071): manual, único por tenant
-- (case-insensitive), inmutable una vez asignado (solo super_admin corrige un
-- typo, queda en audit_log vía el trigger de changelog).
--
-- A diferencia del de cliente, es OPCIONAL a nivel app (un ISP puede no querer
-- codificar contratos). Nullable a nivel DB para tolerar contratos legacy +
-- offline. `contratos` usa SELECT * en las sync rules → REDEPLOYAR sync rules
-- para que la columna baje a los clientes.

BEGIN;

-- 1. Columna.
ALTER TABLE public.contratos ADD COLUMN IF NOT EXISTS codigo text;

-- 2. Unicidad por tenant, case-insensitive, ignorando NULLs (contratos legacy
--    sin código + offline). El upper() hace que CT27 y ct27 colisionen.
CREATE UNIQUE INDEX IF NOT EXISTS contratos_codigo_tenant_uq
  ON public.contratos (tenant_id, upper(codigo))
  WHERE codigo IS NOT NULL;

-- 3. Inmutabilidad: una vez asignado (no-NULL), solo el super_admin puede
--    cambiarlo. La asignación inicial (NULL → valor) siempre se permite.
--    Mismo patrón que clientes_codigo_inmutable_trg (0071).
CREATE OR REPLACE FUNCTION public.contratos_codigo_inmutable_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.codigo IS NOT NULL
     AND NEW.codigo IS DISTINCT FROM OLD.codigo
     AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION
      'El código del contrato es inmutable una vez asignado (actual: %).', OLD.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contratos_codigo_inmutable ON public.contratos;
CREATE TRIGGER trg_contratos_codigo_inmutable
  BEFORE UPDATE ON public.contratos
  FOR EACH ROW
  EXECUTE FUNCTION public.contratos_codigo_inmutable_trg();

COMMIT;


-- >>> Migration: 0078_validar_tenant_coherente.sql <<<
-- 0078 — Defensa server-side de coherencia de tenant en el rastro de dinero.
--
-- Contexto (#9): se detectó que el super_admin impersonando podía registrar
-- un pago/cargo cuyo `tenant_id` quedaba en el tenant System (su fila real)
-- en vez del tenant impersonado, generando pagos/recibos huérfanos invisibles
-- para el ISP y rompiendo los invariantes de dinero #4/#10. El fix principal
-- es client-side (se bloquean esas acciones impersonando), pero acá agregamos
-- una defensa en profundidad a nivel DB: rechazar cualquier INSERT donde el
-- tenant del hijo no coincida con el de su padre.
--
--   pagos.tenant_id        debe == cuotas.tenant_id   (por cuota_id)
--   cargos_extra.tenant_id debe == cuotas.tenant_id   (por cuota_id)
--   recibos.tenant_id      debe == pagos.tenant_id    (por pago_id)
--   visitas.tenant_id      debe == clientes.tenant_id (por cliente_id)
--
-- Se valida en INSERT y en los UPDATE que MUEVEN la fila de tenant/padre
-- (cambian tenant_id o el link cuota_id/pago_id/cliente_id). Los UPDATE
-- benignos (anular, editar notas/monto) NO se validan → no bloquean filas
-- legacy que pudieran ser incoherentes. Esto cierra el vector UPDATE-move del
-- super_admin (que evade el scoping de RLS via super_admin_all). SECURITY
-- DEFINER para leer el tenant real del padre sin que RLS lo oculte y haga
-- pasar la validación por error.

create or replace function public.validar_tenant_coherente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_padre uuid;
begin
  -- En UPDATE solo validamos si la fila se "mueve" de tenant o de padre
  -- (cambia tenant_id o el link al padre). Un UPDATE benigno (anular, editar
  -- notas/monto) NO se valida → no bloquea filas legacy que pudieran ser
  -- incoherentes. Esto cierra el vector UPDATE-move del super_admin (que evade
  -- el scoping de RLS por la policy super_admin_all) sin romper anular/editar.
  if tg_op = 'UPDATE'
     and new.tenant_id is not distinct from old.tenant_id
     and (
       (tg_table_name in ('pagos', 'cargos_extra')
          and new.cuota_id is not distinct from old.cuota_id)
       or (tg_table_name = 'recibos'
          and new.pago_id is not distinct from old.pago_id)
       or (tg_table_name = 'visitas'
          and new.cliente_id is not distinct from old.cliente_id)
     ) then
    return new;
  end if;

  if tg_table_name = 'pagos' then
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del pago (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  elsif tg_table_name = 'cargos_extra' then
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del cargo (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  elsif tg_table_name = 'recibos' then
    select tenant_id into v_tenant_padre
      from public.pagos where id = new.pago_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del recibo (%) no coincide con el de su pago (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  elsif tg_table_name = 'visitas' then
    select tenant_id into v_tenant_padre
      from public.clientes where id = new.cliente_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id de la visita (%) no coincide con el de su cliente (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists validar_tenant_coherente_pagos on public.pagos;
create trigger validar_tenant_coherente_pagos
  before insert or update on public.pagos
  for each row execute function public.validar_tenant_coherente();

drop trigger if exists validar_tenant_coherente_cargos on public.cargos_extra;
create trigger validar_tenant_coherente_cargos
  before insert or update on public.cargos_extra
  for each row execute function public.validar_tenant_coherente();

drop trigger if exists validar_tenant_coherente_recibos on public.recibos;
create trigger validar_tenant_coherente_recibos
  before insert or update on public.recibos
  for each row execute function public.validar_tenant_coherente();

drop trigger if exists validar_tenant_coherente_visitas on public.visitas;
create trigger validar_tenant_coherente_visitas
  before insert or update on public.visitas
  for each row execute function public.validar_tenant_coherente();


-- >>> Migration: 0079_recibo_bloques.sql <<<
-- 0079 — Settings del "diseñador de recibo" (#8b): visibilidad de bloques
-- opcionales + orden de los bloques del pie.
--
-- El núcleo de dinero (recibo Nº, fecha, cliente, ítems, método, COBRADO/
-- VUELTO/PAGADO) queda SIEMPRE visible y en orden fijo. Lo configurable:
--   - mostrar_empresa: bloque de empresa (nombre/dir/tel/RUC) en el encabezado.
--   - mostrar_cedula:  cédula del cliente.
--   - (ya existían: imprimir_logo, monto_en_letras, mostrar_adeudado, y el
--      título / pie / whatsapp se ocultan dejándolos vacíos.)
--   - orden_pie: orden de los bloques de TEXTO LIBRE del pie. CSV de ids:
--     'pie' (pie libre) y 'whatsapp'. El render los emite en ese orden, cada
--     uno si tiene contenido. (El "saldo adeudado" se controla aparte con
--     mostrar_adeudado y mantiene su posición fija por renderer.)
--
-- Son filas nuevas en `settings` (key-value); no hay columnas nuevas, así que
-- no requiere bump de schema ni redeploy de sync rules (SELECT * ya cubre).

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'recibo.mostrar_empresa', '"true"', 'boolean', 'recibos',
       'Mostrar datos de la empresa (nombre, dirección, teléfono, RUC) en el recibo', 'admin'),
      (v_tenant.id, 'recibo.mostrar_cedula', '"true"', 'boolean', 'recibos',
       'Mostrar la cédula del cliente en el recibo', 'admin'),
      (v_tenant.id, 'recibo.orden_pie', '"pie,whatsapp"', 'string', 'recibos',
       'Orden de los bloques de texto del pie del recibo (pie libre y WhatsApp)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;


-- >>> Migration: 0080_recibo_layout.sql <<<
-- 0080 — Layout configurable del recibo ("diseñador de recibo", rework).
--
-- El recibo pasa a ser una LISTA ORDENADA de bloques; cada uno con
-- visibilidad + tamaño de letra. Este setting (`recibo.layout`) guarda esa
-- lista como un array JSON. El default = orden actual del catálogo, todo
-- visible, tamaño normal → los recibos existentes se ven igual (back-compat).
--
-- El bloque `totales` (dinero) se siembra visible y NO es ocultable (el
-- cliente Dart lo fuerza visible aunque alguien lo edite). Es fila nueva en
-- `settings` (key-value), sin columnas → sin bump de schema ni redeploy de
-- sync rules (SELECT * ya cubre).
--
-- Nota: los settings viejos de visibilidad (recibo.mostrar_empresa,
-- recibo.mostrar_cedula, recibo.orden_pie, recibo.monto_en_letras,
-- recibo.mostrar_adeudado, recibo.imprimir_logo) quedan vigentes hasta que el
-- render migre al layout (fase siguiente del rework). No se tocan acá.

DO $$
DECLARE
  v_tenant record;
  v_layout text := '[' ||
    '{"id":"logo","visible":true,"size":"normal"},' ||
    '{"id":"empresa","visible":true,"size":"normal"},' ||
    '{"id":"titulo","visible":true,"size":"normal"},' ||
    '{"id":"meta","visible":true,"size":"normal"},' ||
    '{"id":"cliente","visible":true,"size":"normal"},' ||
    '{"id":"servicio","visible":true,"size":"normal"},' ||
    '{"id":"cuota","visible":true,"size":"normal"},' ||
    '{"id":"metodo","visible":true,"size":"normal"},' ||
    '{"id":"letras","visible":true,"size":"normal"},' ||
    '{"id":"totales","visible":true,"size":"normal"},' ||
    '{"id":"pie","visible":true,"size":"normal"},' ||
    '{"id":"whatsapp","visible":true,"size":"normal"}' ||
  ']';
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'recibo.layout', v_layout, 'json', 'recibos',
       'Layout del recibo: orden, visibilidad y tamaño de cada bloque', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;


-- >>> Migration: 0081_comprobante_habilitado.sql <<<
-- 0081 — Switch maestro de la foto de comprobante (gateado por super_admin).
--
-- Hoy el cobro muestra el picker de foto para métodos con comprobante
-- (transferencia). Para no consumir Storage de cada tenant sin decisión del
-- dueño del SaaS, la foto pasa a estar APAGADA por defecto: el cobro guarda
-- solo el número de referencia. El super_admin (entrando al tenant) puede
-- habilitarla por tenant desde el panel de settings.
--
-- `fotoObligatoria` (cobranza.foto_obligatoria, 0010) queda como sub-opción:
-- solo aplica si este switch está en ON. Ambos toggles se muestran únicamente
-- al super_admin en la UI (gate `esSuperAdmin`, client-side).
--
-- Fila nueva en `settings` (key-value), sin columnas → sin bump de schema ni
-- redeploy de sync rules (SELECT * ya cubre).

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
       'cobranza',
       'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
       'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;


-- >>> Migration: 0082_fix_validar_tenant_coherente.sql <<<
-- 0082 — FIX CRÍTICO de validar_tenant_coherente() (0078).
--
-- BUG: la función es polimórfica (un solo trigger en pagos / cargos_extra /
-- recibos / visitas) y arrancaba con una condición COMPARTIDA que referenciaba
-- `new.pago_id` y `new.cliente_id` en un OR:
--
--   if tg_op = 'UPDATE' and ... (
--        (tg_table_name in ('pagos','cargos_extra') and new.cuota_id ...) or
--        (tg_table_name = 'recibos' and new.pago_id ...) or       -- ← falla
--        (tg_table_name = 'visitas' and new.cliente_id ...) )     -- ← falla
--
-- PL/pgSQL PLANIFICA la expresión booleana completa apenas la ejecución llega
-- al IF (en cada INSERT/UPDATE), y al resolver `new.pago_id` / `new.cliente_id`
-- contra una fila de `pagos` (que NO tiene esas columnas) tira:
--   "record \"new\" has no field \"pago_id\""
-- → rompe TODO INSERT/UPDATE de pagos y cargos_extra (el cobro entero).
--
-- FIX: ramificar por `tg_table_name` PRIMERO y referenciar solo los campos de
-- esa tabla DENTRO de su rama. PL/pgSQL planifica cada sentencia recién cuando
-- la ejecución la alcanza, así que la rama de `recibos` (con new.pago_id) nunca
-- se planifica cuando el trigger corre sobre `pagos`. Misma lógica de validación
-- y de skip de UPDATE benigno que 0078 — solo cambia la estructura. Los triggers
-- de 0078 siguen vigentes (llaman a la función por nombre); solo se reemplaza el
-- cuerpo con CREATE OR REPLACE.

create or replace function public.validar_tenant_coherente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_padre uuid;
begin
  -- pagos.tenant_id debe == cuotas.tenant_id (por cuota_id)
  if tg_table_name = 'pagos' then
    -- UPDATE benigno (no se mueve de tenant ni de cuota): no validar.
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.cuota_id is not distinct from old.cuota_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del pago (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  -- cargos_extra.tenant_id debe == cuotas.tenant_id (por cuota_id)
  elsif tg_table_name = 'cargos_extra' then
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.cuota_id is not distinct from old.cuota_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del cargo (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  -- recibos.tenant_id debe == pagos.tenant_id (por pago_id)
  elsif tg_table_name = 'recibos' then
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.pago_id is not distinct from old.pago_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.pagos where id = new.pago_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del recibo (%) no coincide con el de su pago (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  -- visitas.tenant_id debe == clientes.tenant_id (por cliente_id)
  elsif tg_table_name = 'visitas' then
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.cliente_id is not distinct from old.cliente_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.clientes where id = new.cliente_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id de la visita (%) no coincide con el de su cliente (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;


-- >>> Migration: 0083_blindar_recalcular_cuota.sql <<<
-- 0083 — Blindaje preventivo de recalcular_cuota_desde_pagos (lección de 0078).
--
-- La función es polimórfica: se engancha a `pagos` (0012) y a `cargos_extra`
-- (0018), y referencia `new.cuota_id` / `new.ocurrido_en` en sentencias
-- COMPARTIDAS (no ramificadas por tabla) — el MISMO antipatrón que rompió todo
-- INSERT de pagos en 0078 (PL/pgSQL planifica cada sentencia al alcanzarla y
-- resuelve los campos contra el rowtype de la tabla que dispara; si el campo no
-- existe → "record \"new\" has no field ...").
--
-- HOY no rompe porque ambas tablas tienen `cuota_id` + `ocurrido_en`. Pero es
-- frágil exactamente igual y toca el flujo de dinero: si esta función se
-- enganchara a una tabla SIN esas columnas, se caería TODO INSERT de esa tabla.
--
-- FIX (defensivo, sin cambiar comportamiento): un guard temprano por
-- `tg_table_name` ANTES de tocar cualquier `new.<campo>`. Como PL/pgSQL es lazy
-- (planifica la sentencia recién al alcanzarla), una tabla desconocida retorna
-- no-op sin llegar nunca al acceso a `new.cuota_id`. Las 2 tablas conocidas
-- operan idéntico que antes — monto_pagado/estado/ocurrido_en sin cambios, las
-- invariantes de dinero intactas. Idempotente (CREATE OR REPLACE). Solo función
-- server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  -- Guard polimórfico (lección de 0078): operar SOLO sobre las 2 tablas
  -- conocidas, que tienen cuota_id + ocurrido_en. Cualquier otra tabla es un
  -- no-op seguro — el acceso a new.cuota_id queda después de este guard y nunca
  -- se alcanza, así que PL/pgSQL no lo planifica ni falla.
  if tg_table_name not in ('pagos', 'cargos_extra') then
    return coalesce(new, old);
  end if;

  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

COMMIT;


-- >>> Migration: 0084_pantallas_admin_opcionales.sql <<<
-- 0084 — Pantallas admin opcionales gateadas por super_admin (por tenant).
--
-- /admin/pagos (historial de pagos del tenant + anular) y /admin/notificaciones
-- (gestión de mora) existían como rutas/pantallas pero SIN punto de entrada en
-- el menú (BULK 12 las dejó huérfanas). Decisión: que el super_admin las
-- habilite por tenant desde el panel de settings del admin (mismo patrón que la
-- foto de comprobante). Default OFF → el item del menú no aparece.
--
-- Los toggles se muestran SOLO al super_admin en la UI (gate `esSuperAdmin` +
-- `superAdminOnly` en settings_admin). Los getters
-- `pantallaPagosHabilitada`/`pantallaNotificacionesHabilitada` controlan la
-- visibilidad del item en `admin_shell` (`_menuVisible` + `settingKey`).
--
-- Filas nuevas en `settings` (key-value), sin columnas → sin bump de schema ni
-- redeploy de sync rules.

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
       'cobranza',
       'Muestra la pantalla de historial de pagos del tenant (admin)', 'admin'),
      (v_tenant.id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
       'cobranza',
       'Muestra la pantalla de gestión de notificaciones de mora (admin)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;


-- >>> Migration: 0085_settings_super_only_enforce.sql <<<
-- 0085 — Enforce server-side de los settings "super_admin-only".
--
-- PROBLEMA (audit): los toggles que el dueño del SaaS controla por tenant
-- (foto de comprobante → consume Storage; pantallas admin opcionales) se
-- gateaban SOLO en la UI (`esSuperAdmin` client-side). Server-side, la policy
-- `settings_write_admin` (0004) dejaba a CUALQUIER admin del tenant escribir
-- CUALQUIER fila de `settings`. Un admin podía re-activar la foto de
-- comprobante o las pantallas que el super_admin dejó en OFF, escribiendo el
-- setting por PowerSync/REST. No cruzaba tenants (RLS lo scopa), pero anulaba
-- el control de costo/política del SaaS.
--
-- FIX: marcar esas claves con `editable_por='super_admin'` y endurecer la
-- policy para que el admin NO pueda tocarlas. El super_admin las sigue
-- escribiendo vía la policy `super_admin_all` (0026), que ya cubre `settings`.
--
-- Filas/constraint/policy — sin columnas nuevas → sin bump de schema.dart ni
-- redeploy de sync rules (la app lee `editable_por` por SELECT *, ya cubierto).

-- =========================================================================
-- 1. Permitir 'super_admin' como valor de editable_por
--    (el CHECK inline de 0004 sólo aceptaba 'admin' | 'admin_cobranza').
-- =========================================================================
alter table public.settings drop constraint settings_editable_por_check;
alter table public.settings add constraint settings_editable_por_check
  check (editable_por in ('admin', 'admin_cobranza', 'super_admin'));

-- =========================================================================
-- 2. Helper: sembrar/marcar las 4 claves super-only de un tenant.
--    ON CONFLICT DO UPDATE editable_por (preserva `valor` existente): sirve
--    para tenants nuevos (INSERT) y para re-marcar foto_obligatoria, que ya
--    la siembra seed_settings_default con editable_por='admin'.
-- =========================================================================
create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- =========================================================================
-- 3. Aplicar a todos los tenants existentes.
-- =========================================================================
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;

-- =========================================================================
-- 4. Tenant nuevo: además del seed default, sembrar las super-only.
--    (seed_settings_default no las incluye — se agregaron en 0081/0084 sólo
--    para tenants existentes; sin esto, un tenant nuevo no las tendría.)
-- =========================================================================
create or replace function public.tenants_seed_settings_trg()
returns trigger
language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  return new;
end $$;

-- =========================================================================
-- 5. Endurecer settings_write_admin: el admin NO puede escribir las claves
--    super-only. El super_admin las escribe vía super_admin_all (0026).
--    admin_cobranza sigue con su policy propia (sólo claves admin_cobranza).
-- =========================================================================
drop policy "settings_write_admin" on public.settings;
create policy "settings_write_admin" on public.settings
  for all using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
    and editable_por <> 'super_admin'
  ) with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
    and editable_por <> 'super_admin'
  );


-- >>> Migration: 0086_descuentos_reconexion_super_only.sql <<<
-- 0086 — Descuentos y reconexión pasan a super_admin-only (por tenant).
--
-- Decisión del dueño: el admin del ISP NO debe ver/activar el módulo de
-- descuentos (manual en campo) ni el cargo por reconexión. El super_admin
-- (dueño del SaaS) los habilita por tenant desde la tab "Avanzado", mismo
-- patrón que foto-comprobante / pantallas opcionales (0085). Mientras el super
-- los deje en OFF (default), no aparecen ni en el cobro ni en el contrato.
--
-- Extiende seed_settings_super_only (0085) con las 6 claves. Solo cambia
-- editable_por (el `valor` lo preserva el ON CONFLICT). La RLS endurecida de
-- 0085 (settings_write_admin con `editable_por <> 'super_admin'`) ya impide
-- server-side que el admin las escriba.
--
-- Filas/función — sin columnas nuevas → sin bump de schema.dart ni redeploy de
-- sync rules.

create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    -- Foto de comprobante + pantallas opcionales (0085).
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    -- Descuentos (manual en campo) → super-only (0086).
    (p_tenant_id, 'cobranza.descuentos_habilitados', 'false'::jsonb, 'boolean',
     'cobranza', 'Permitir aplicar descuentos en campo', 'super_admin'),
    (p_tenant_id, 'cobranza.descuento_tipo', '"monto"'::jsonb, 'string',
     'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_porcentaje', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)',
     'super_admin'),
    -- Reconexión → super-only (0086).
    (p_tenant_id, 'cobranza.cargo_reconexion_habilitado', 'false'::jsonb,
     'boolean', 'cobranza', 'Permitir cobrar reconexión', 'super_admin'),
    (p_tenant_id, 'cobranza.monto_reconexion', '0'::jsonb, 'number',
     'cobranza', 'Monto de reconexión en C$', 'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- Aplicar a todos los tenants existentes (flip de editable_por de las 10 claves).
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;


-- >>> Migration: 0087_funciones_dia_local_nicaragua.sql <<<
-- 0087 — Día local Nicaragua también en las funciones server-side de límite
-- de día. Mismo objetivo que el fix del cliente (date('now','-6 hours')): el
-- negocio opera en hora de Nicaragua (UTC-6, sin DST).
--
-- MECANISMO: `SET timezone='America/Managua'` POR FUNCIÓN (GUC scopeado a la
-- ejecución de esa función). Dentro de cada una, `current_date` / `now()`
-- devuelven el día Nicaragua sin importar a qué hora se la llame — clave para
-- los triggers que corren AD-HOC (ej. crear/editar un contrato de noche, cuando
-- el UTC ya es el día siguiente).
--
-- POR QUÉ NO cambiar el timezone global de la DB: alteraría el wire-format de
-- TODOS los `timestamptz` (pasarían a mostrarse con offset -06), lo que
-- cambiaría cómo PowerSync/el cliente reciben y parsean esas fechas y podría
-- desalinear el fix del cliente (date() de SQLite sobre un ISO con offset).
-- Per-función es quirúrgico y no toca nada más.
--
-- NOTA crons: `generar_cuotas_mensual` (06:05 UTC = 00:05 Nicaragua) y el de
-- mora ya están agendados a la medianoche Nicaragua, así que su `current_date`
-- ya coincidía al ejecutarse. El SET por-función los hace robustos igual (si
-- cambia el horario del cron o si se llaman ad-hoc).
--
-- Sin columnas/tablas nuevas → sin bump de schema ni redeploy de sync rules.

-- Mora: día actual para marcar vencidas pasada la gracia + días de mora.
alter function public.actualizar_notificaciones_mora(uuid)
  set timezone = 'America/Managua';

-- Generación de cuotas del contrato: se dispara por trigger al crear/editar un
-- contrato (a cualquier hora). Usa current_date para el colchón de meses de los
-- contratos indefinidos.
alter function public.generar_cuotas_contrato(uuid, integer)
  set timezone = 'America/Managua';

-- Trigger de UPDATE de contrato: usa current_date para el "mes actual" al
-- recalcular las cuotas futuras.
alter function public.contratos_actualizar_cuotas_futuras_trg()
  set timezone = 'America/Managua';


-- >>> Migration: 0088_backlog_mora_cargos_neto_storage_ext.sql <<<
-- 0088 — Limpieza de backlog del audit total:
--   1. actualizar_notificaciones_mora: monto_adeudado con cargos_neto (L3).
--   2. Storage RLS de comprobantes: extraer pago_id sin acoplar a '.jpg' (DB F2).
--
-- Sin columnas/tablas nuevas → sin bump de schema ni redeploy de sync rules.

-- =========================================================================
-- 1. monto_adeudado de la mora = monto + cargos_neto − monto_pagado (igual que
--    el saldo en TODA la app). Antes omitía cargos_neto → el reporte de mora
--    y la bandeja quedaban levemente inexactos con reconexión/descuentos.
--
--    OJO: CREATE OR REPLACE reescribe la función → hay que RE-DECLARAR el
--    `SET timezone='America/Managua'` (0087) y `SET search_path`, o se pierden.
-- =========================================================================
create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
set timezone = 'America/Managua'
as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- row_security off: el cron corre sin auth.uid(); SECURITY DEFINER da rol
  -- postgres (BYPASSRLS), lo explicitamos por las dudas.
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
    cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado
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
-- 2. Storage RLS de comprobantes-pago: extraer pago_id del path
--    {tenant}/comp/{pago_id}.{ext} sin asumir '.jpg'. `regexp_replace` quita
--    CUALQUIER extensión final → si mañana se sube .png/.webp, el EXISTS de
--    pago sigue matcheando (antes el cobrador no podría subir no-jpg).
-- =========================================================================
drop policy "storage_write_comprobantes_select_y_insert" on storage.objects;
create policy "storage_write_comprobantes_select_y_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = regexp_replace(split_part(name, '/', 3), '\.[^.]+$', '')
           and cobrador_id = auth.uid()
      )
    )
  );

drop policy "storage_update_comprobantes" on storage.objects;
create policy "storage_update_comprobantes" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = regexp_replace(split_part(name, '/', 3), '\.[^.]+$', '')
           and cobrador_id = auth.uid()
      )
    )
  );


-- >>> Migration: 0089_audit_visible_admin_super_only.sql <<<
-- 0089 — Visibilidad de Auditoría para el admin → super_admin-only (por tenant).
--
-- Decisión del dueño: el panel de Auditoría (/admin/audit) ya NO es visible por
-- defecto para el admin del ISP. El super_admin (dueño del SaaS) lo habilita por
-- tenant desde la tab "Avanzado" de Settings, mismo patrón que pantallas
-- opcionales / descuentos / reconexión (0085/0086). El super_admin lo ve siempre
-- (es config del SaaS); el admin sólo si el toggle está en ON. admin_cobranza
-- nunca lo ve (sigue gateado por rol en el router).
--
-- Extiende seed_settings_super_only (0085/0086) con la clave nueva. La RLS
-- endurecida de 0085 (settings_write_admin con `editable_por <> 'super_admin'`)
-- ya impide server-side que el admin la escriba.
--
-- Default OFF: por pedido explícito, la opción arranca oculta para los admins.
--
-- Sin columnas nuevas → sin bump de schema.dart ni redeploy de sync rules
-- (la tabla settings ya sincroniza con SELECT *).

create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    -- Foto de comprobante + pantallas opcionales (0085).
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    -- Descuentos (manual en campo) → super-only (0086).
    (p_tenant_id, 'cobranza.descuentos_habilitados', 'false'::jsonb, 'boolean',
     'cobranza', 'Permitir aplicar descuentos en campo', 'super_admin'),
    (p_tenant_id, 'cobranza.descuento_tipo', '"monto"'::jsonb, 'string',
     'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_porcentaje', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)',
     'super_admin'),
    -- Reconexión → super-only (0086).
    (p_tenant_id, 'cobranza.cargo_reconexion_habilitado', 'false'::jsonb,
     'boolean', 'cobranza', 'Permitir cobrar reconexión', 'super_admin'),
    (p_tenant_id, 'cobranza.monto_reconexion', '0'::jsonb, 'number',
     'cobranza', 'Monto de reconexión en C$', 'super_admin'),
    -- Visibilidad del panel de Auditoría para el admin → super-only (0089).
    (p_tenant_id, 'cobranza.audit_visible_admin', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra el panel de Auditoría (historial de cambios) al admin del tenant',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- Aplicar a todos los tenants existentes: siembra la clave nueva (los demás ya
-- existen, el ON CONFLICT preserva su `valor` y sólo reafirma editable_por).
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;


-- >>> Migration: 0090_seed_recibo_layout_tenants_nuevos.sql <<<
-- 0090 — Sembrar settings de recibo faltantes en tenants nuevos.
--
-- Bug: dos claves que toca el editor del recibo nunca entraron a la función de
-- alta de tenant (seed_settings_default, 0010/0045) — se agregaron sólo como
-- backfill puntual: `recibo.layout` (0080) y `recibo.mostrar_cedula` (0079). Un
-- tenant creado DESPUÉS de esas migraciones no tiene esas filas. El editor de
-- recibos guardaba con un UPDATE puro → 0 filas afectadas → los toggles
-- "rebotaban" (no se podían desactivar). Las otras claves del editor
-- (recibo.titulo, recibo.mostrar_adeudado, recibo.formato_default_mm,
-- recibo.pie_libre) SÍ están en el seed 0045, así que esas ya funcionaban.
--
-- Fix de dos capas:
--   - Cliente (v0.6.4): el editor pasa a `upsert` (crea la fila si falta).
--   - Servidor (esta migración): el trigger de alta siembra `recibo.layout` +
--     `recibo.mostrar_cedula`, y se backfillea cualquier tenant que hoy no las tenga.
--
-- Default = mismo layout que 0080 (12 bloques, todo visible, tamaño normal). El
-- cliente agrega el bloque `mora` al final si falta (ReciboLayout.fromRaw), igual
-- que con los tenants existentes. Fila key-value, sin columnas → sin bump de
-- schema ni redeploy de sync rules (settings ya sincroniza con SELECT *).

create or replace function public.seed_settings_recibo_layout(p_tenant_id uuid)
returns void
language plpgsql as $$
declare
  v_layout text := '[' ||
    '{"id":"logo","visible":true,"size":"normal"},' ||
    '{"id":"empresa","visible":true,"size":"normal"},' ||
    '{"id":"titulo","visible":true,"size":"normal"},' ||
    '{"id":"meta","visible":true,"size":"normal"},' ||
    '{"id":"cliente","visible":true,"size":"normal"},' ||
    '{"id":"servicio","visible":true,"size":"normal"},' ||
    '{"id":"cuota","visible":true,"size":"normal"},' ||
    '{"id":"metodo","visible":true,"size":"normal"},' ||
    '{"id":"letras","visible":true,"size":"normal"},' ||
    '{"id":"totales","visible":true,"size":"normal"},' ||
    '{"id":"pie","visible":true,"size":"normal"},' ||
    '{"id":"whatsapp","visible":true,"size":"normal"}' ||
  ']';
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'recibo.layout', v_layout::jsonb, 'json', 'recibos',
     'Layout del recibo: orden, visibilidad y tamaño de cada bloque', 'admin'),
    (p_tenant_id, 'recibo.mostrar_cedula', 'true'::jsonb, 'boolean', 'recibos',
     'Mostrar la cédula del cliente en el recibo', 'admin')
  on conflict (tenant_id, clave) do nothing;
end $$;

-- Extender el trigger de alta para que TODO tenant nuevo reciba el layout.
-- Preserva las dos siembras existentes (default 0010/0045 + super_only 0085/0086).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  return new;
end;
$$;

-- Backfill: cualquier tenant que hoy no tenga `recibo.layout` / `recibo.mostrar_cedula`
-- (creado entre 0079/0080 y esta migración). ON CONFLICT DO NOTHING preserva lo
-- ya configurado.
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_recibo_layout(v_t.id);
  end loop;
end $$;


-- >>> Migration: 0091_list_cobrador_emails.sql <<<
-- Migración 0091: RPC para listar el email de los cobradores del tenant.
--
-- El email vive en `auth.users`, no en `cobradores`, y auth.users no es
-- accesible vía RLS normal. Esta RPC SECURITY DEFINER devuelve
-- (cobrador_id, email) para los miembros del tenant del caller, para que
-- la pantalla de Personal muestre el email junto a cada usuario.
--
-- Mismo patrón que check_email_exists_in_auth (0036) y list_error_logs:
-- SECURITY DEFINER + SET search_path = '' (CWE-426). El scope NO se delega
-- a RLS (auth.users no la tiene): se filtra explícitamente por el tenant
-- del caller vía current_tenant_id(), que ya respeta la impersonación del
-- super_admin (0039).
--
-- Guard de rol: sólo admin / admin_cobranza / super_admin pueden ver los
-- emails. Un cobrador raso NO (no gestiona usuarios). El super_admin ve los
-- del tenant que esté impersonando (current_tenant_id() lo resuelve); fuera
-- de impersonación ve los de su propio tenant System (vacío en la práctica).
--
-- Retorna: filas (cobrador_id uuid, email text). Vacío si el caller no
-- tiene permiso (no lanza excepción para que la UI degrade elegante).

CREATE OR REPLACE FUNCTION public.list_cobrador_emails()
RETURNS TABLE (cobrador_id uuid, email text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rol    text;
  v_tenant uuid;
BEGIN
  -- Rol del caller (de la tabla cobradores).
  SELECT c.rol INTO v_rol
  FROM public.cobradores c
  WHERE c.id = auth.uid();

  -- Sólo roles de gestión ven emails. Cobrador raso o caller desconocido
  -- → set vacío (sin error: la UI simplemente no muestra emails).
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'admin_cobranza', 'super_admin') THEN
    RETURN;
  END IF;

  -- Tenant scopeado (respeta impersonación del super_admin vía 0039).
  v_tenant := public.current_tenant_id();
  IF v_tenant IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT c.id, u.email::text
  FROM public.cobradores c
  JOIN auth.users u ON u.id = c.id
  WHERE c.tenant_id = v_tenant;
END;
$$;

REVOKE ALL ON FUNCTION public.list_cobrador_emails() FROM public;
GRANT EXECUTE ON FUNCTION public.list_cobrador_emails() TO authenticated;


-- >>> Migration: 0092_prefijo_recibo_unico_por_tenant.sql <<<
-- Migración 0092: prefijo de recibo único por tenant.
--
-- Ahora que los 3 roles que cobran (cobrador / admin / admin_cobranza)
-- pueden tener prefijo de recibo, dos usuarios del mismo tenant con el
-- mismo prefijo colisionarían sus correlativos de recibo (ej: COB-01-0001
-- emitido por dos personas distintas). Este índice único lo impide a nivel
-- de DB.
--
-- - Parcial (WHERE prefijo_recibo IS NOT NULL): los usuarios sin prefijo
--   (ej: super_admin, o uno todavía sin asignar) no chocan entre sí.
-- - upper(prefijo_recibo): comparación case-insensitive — la UI ya
--   normaliza a mayúsculas, pero esto blinda contra writes directos.
-- - Por tenant: prefijos pueden repetirse ENTRE tenants distintos (cada ISP
--   tiene su propio espacio de correlativos).
--
-- IF NOT EXISTS: idempotente. NOTA: si la data actual ya tiene duplicados,
-- la creación del índice fallará; en ese caso hay que deduplicar primero.

CREATE UNIQUE INDEX IF NOT EXISTS cobradores_prefijo_tenant_uq
  ON public.cobradores (tenant_id, upper(prefijo_recibo))
  WHERE prefijo_recibo IS NOT NULL;


-- >>> Migration: 0093_set_cobrador_rol_conserva_prefijo.sql <<<
-- Migración 0093: set_cobrador_rol conserva el prefijo de los roles que cobran.
--
-- La versión original (0030) limpiaba prefijo_recibo a NULL para cualquier
-- rol distinto de 'cobrador'. Ahora que los 3 roles que cobran (cobrador /
-- admin / admin_cobranza) llevan prefijo, ese borrado al cambiar de rol
-- entre ellos perdería el correlativo del usuario.
--
-- Cambio MÍNIMO: el CASE de prefijo_recibo ahora conserva el prefijo cuando
-- el rol nuevo es cobrador, admin o admin_cobranza; sólo lo limpia para
-- super_admin (rol que igual no se puede asignar desde esta RPC — el guard
-- de p_nuevo_rol lo rechaza — pero lo dejamos explícito por claridad). El
-- resto de la lógica (guards, idempotencia, audit) se preserva idéntico.

create or replace function public.set_cobrador_rol(
  p_cobrador_id uuid,
  p_nuevo_rol   text
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target_tenant uuid;
  v_target_rol    text;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio rol';
  end if;

  if p_nuevo_rol not in ('admin', 'admin_cobranza', 'cobrador') then
    raise exception
      'Rol inválido. Permitidos: admin, admin_cobranza, cobrador';
  end if;

  -- FOR UPDATE: lock de la fila para que dos super_admins concurrentes no
  -- pasen ambos el check de idempotencia y escriban audit rows con
  -- valores anterior/nuevo inconsistentes.
  select tenant_id, rol
    into v_target_tenant, v_target_rol
  from public.cobradores
  where id = p_cobrador_id
  for update;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar el rol de otro super_admin';
  end if;

  -- Idempotencia.
  if v_target_rol = p_nuevo_rol then
    return;
  end if;

  -- El prefijo se conserva para los 3 roles que cobran (cobrador, admin,
  -- admin_cobranza). Sólo se limpiaría para super_admin (inalcanzable acá
  -- por el guard de p_nuevo_rol, pero explícito por claridad).
  update public.cobradores
  set rol = p_nuevo_rol,
      prefijo_recibo = case
        when p_nuevo_rol in ('cobrador', 'admin', 'admin_cobranza')
          then prefijo_recibo
        else null
      end
  where id = p_cobrador_id;

  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'cobradores',
    p_cobrador_id,
    'rol',
    to_jsonb(v_target_rol),
    to_jsonb(p_nuevo_rol),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.set_cobrador_rol(uuid, text) from public;
grant execute on function public.set_cobrador_rol(uuid, text) to authenticated;


-- >>> Migration: 0094_recibo_formato_57_a_58.sql <<<
-- Migración 0094: estandarizar el ancho de recibo angosto a 58mm.
--
-- El formato angosto pasó de 57mm a 58mm (estándar real de las térmicas de
-- 58mm). El recibo ahora imprime rasterizando el PDF (no texto ESC/POS), así
-- que el ancho importa para el cálculo de dots/puntos. Migramos los tenants
-- que tengan el valor legacy 57 al nuevo 58.
--
-- El valor vive en settings(clave='recibo.formato_default_mm') como JSONB
-- numérico. Idempotente: solo toca filas con valor 57; correrla de nuevo no
-- hace nada.

update public.settings
   set valor = '58'::jsonb
 where clave = 'recibo.formato_default_mm'
   and valor::text = '57';


-- >>> Migration: 0095_recibos_formato_mm_acepta_58.sql <<<
-- 0095 — Permitir 58 en recibos.ultimo_formato_mm.
--
-- Bug: el CHECK original (0006) era `ultimo_formato_mm in (57, 80)`. Al
-- estandarizar el ancho angosto a 58mm (migr 0094 + UI), la impresión escribe
-- `ultimo_formato_mm = 58` y la fila de `recibos` VIOLA el constraint →
-- "new row for relation recibos violates check constraint
-- recibos_ultimo_formato_mm_check" → el sync del recibo falla (aunque el cobro
-- ya quedó guardado).
--
-- Fix: ampliar el CHECK para aceptar 57 (legacy), 58 y 80. Idempotente
-- (drop if exists + add). Sin columnas nuevas → sin bump de schema ni redeploy
-- de sync rules.

alter table public.recibos
  drop constraint if exists recibos_ultimo_formato_mm_check;

alter table public.recibos
  add constraint recibos_ultimo_formato_mm_check
  check (ultimo_formato_mm is null or ultimo_formato_mm in (57, 58, 80));


-- >>> Migration: 0096_get_cobrador_stats_mes_nicaragua.sql <<<
-- 0096 — get_cobrador_stats: "pagos del mes" en mes de Nicaragua
--
-- PROBLEMA (borde de mes): la función contaba los pagos del mes con
-- `p.fecha_pago >= date_trunc('month', now())`. `now()` es UTC y, más sutil,
-- `fecha_pago` se guarda como hora LOCAL de Nicaragua etiquetada como UTC (el
-- cliente escribe wall-clock sin offset y la sesión de Postgres es UTC). Por
-- eso ni el código actual ni un simple `set timezone='America/Managua'` dan el
-- mes correcto: con `set timezone` el corte de inicio de mes (00:00 Nica =
-- 06:00 UTC) deja afuera los pagos de la madrugada del día 1 (00:00–05:59 Nica),
-- que están guardados con su wall-clock < 06:00.
--
-- FIX: comparar en el MISMO espacio wall-clock que usa el dashboard del cliente
-- (`date(fecha_pago)` crudo). Se recupera el wall-clock de Nicaragua del pago
-- con `fecha_pago AT TIME ZONE 'UTC'` (timestamptz → timestamp sin tz = la hora
-- que se guardó) y se compara contra el inicio del mes ACTUAL de Nicaragua,
-- `date_trunc('month', now() AT TIME ZONE 'America/Managua')`. Ambos lados son
-- `timestamp` sin zona, en hora Nicaragua. Así el conteo del super_admin coincide
-- con los KPIs del dashboard en todos los casos, incluido el borde de mes.
--
-- Solo redefine la función (idempotente). NO toca schema.dart, db.dart ni sync
-- rules. Mantiene firma, gates y grants idénticos.

BEGIN;

create or replace function public.get_cobrador_stats(p_cobrador_id uuid)
returns table (
  id                  uuid,
  last_sign_in_at     timestamptz,
  clientes_asignados  bigint,
  pagos_mes_count     bigint,
  pagos_mes_total     numeric
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      c.id,
      u.last_sign_in_at,
      (select count(*) from public.clientes cl
         where cl.cobrador_id = c.id and cl.activo)::bigint
        as clientes_asignados,
      (select count(*) from public.pagos p
         where p.cobrador_id = c.id
           and p.anulado = false
           and (p.fecha_pago at time zone 'UTC')
               >= date_trunc('month', now() at time zone 'America/Managua'))::bigint
        as pagos_mes_count,
      coalesce(
        (select sum(p.monto_cordobas) from public.pagos p
          where p.cobrador_id = c.id
            and p.anulado = false
            and (p.fecha_pago at time zone 'UTC')
                >= date_trunc('month', now() at time zone 'America/Managua')),
        0
      ) as pagos_mes_total
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.id = p_cobrador_id
      and c.rol <> 'super_admin';
end;
$$;

revoke all on function public.get_cobrador_stats(uuid) from public;
grant execute on function public.get_cobrador_stats(uuid) to authenticated;

COMMIT;


-- >>> Migration: 0097_geografia_per_tenant.sql <<<
-- 0097: Geografía global → per-tenant.
--
-- Hasta ahora departamentos/municipios/comunidades eran GLOBALES (sin
-- tenant_id, RLS permisiva). Pasan a ser per-tenant: cada tenant maneja su
-- propia geografía, con RLS scopeada por current_tenant_id() y audit log.
--
-- DATA: es data de prueba (decisión de Rubén) → NO se hace backfill/replicación.
-- Se vacían las tablas globales y se deja clientes.comunidad_id = NULL; el
-- admin recarga la geografía por tenant. (Si en el futuro hubiera data real,
-- esta migración debería replicar + re-apuntar FKs en vez de vaciar.)

-- =========================================================================
-- 1. Limpiar data global (test) y soltar FK de clientes
-- =========================================================================
UPDATE public.clientes SET comunidad_id = NULL WHERE comunidad_id IS NOT NULL;

DELETE FROM public.comunidades;
DELETE FROM public.municipios;
DELETE FROM public.departamentos;

-- =========================================================================
-- 2. Agregar tenant_id (NOT NULL — las tablas quedaron vacías) + FK
-- =========================================================================
ALTER TABLE public.departamentos
  ADD COLUMN tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE public.municipios
  ADD COLUMN tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE public.comunidades
  ADD COLUMN tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE;

-- =========================================================================
-- 3. Unicidad: ahora POR TENANT (antes era global)
-- =========================================================================
ALTER TABLE public.departamentos DROP CONSTRAINT IF EXISTS departamentos_nombre_key;
ALTER TABLE public.departamentos DROP CONSTRAINT IF EXISTS departamentos_codigo_key;
ALTER TABLE public.municipios    DROP CONSTRAINT IF EXISTS municipios_departamento_id_nombre_key;
ALTER TABLE public.comunidades   DROP CONSTRAINT IF EXISTS comunidades_municipio_id_nombre_key;

ALTER TABLE public.departamentos ADD CONSTRAINT departamentos_tenant_nombre_key UNIQUE (tenant_id, nombre);
ALTER TABLE public.municipios    ADD CONSTRAINT municipios_tenant_depto_nombre_key UNIQUE (tenant_id, departamento_id, nombre);
ALTER TABLE public.comunidades   ADD CONSTRAINT comunidades_tenant_muni_nombre_key UNIQUE (tenant_id, municipio_id, nombre);

CREATE INDEX IF NOT EXISTS departamentos_by_tenant ON public.departamentos (tenant_id);
CREATE INDEX IF NOT EXISTS municipios_by_tenant    ON public.municipios (tenant_id, departamento_id);
CREATE INDEX IF NOT EXISTS comunidades_by_tenant   ON public.comunidades (tenant_id, municipio_id);

-- =========================================================================
-- 4. RLS: reemplazar las policies globales por scoping per-tenant
-- =========================================================================
-- Dropear TODAS las policies geo previas (globales). OJO: los nombres cambiaron
-- a lo largo del historial — read=geo_read_authenticated (0003); insert pasó de
-- geo_insert_authenticated (0003) a geo_insert_admins (0016); update/delete son
-- geo_update_admins/geo_delete_admins (0067). Si no dropeamos los nombres REALES,
-- esas policies viejas SIN scoping por tenant sobreviven y (combinadas con OR)
-- anulan el scoping nuevo → fuga cross-tenant en escritura de geografía.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departamentos','municipios','comunidades']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "geo_read_authenticated" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_insert_authenticated" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_insert_admins" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_update_admins" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_delete_admins" ON public.%I;', t);
  END LOOP;
END $$;

-- Lectura: cualquier miembro del tenant (cobrador necesita la geo del cliente).
-- Insert: cualquier miembro del tenant (preserva el "crear inline" del geo_picker).
-- Update/Delete: solo admin/admin_cobranza.
-- super_admin_all: agregada a mano (el do$$ de 0026 enumera tablas fijas).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departamentos','municipios','comunidades']
  LOOP
    EXECUTE format('CREATE POLICY "geo_read" ON public.%I FOR SELECT USING (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "geo_insert" ON public.%I FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "geo_update" ON public.%I FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "geo_delete" ON public.%I FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());', t);
  END LOOP;
END $$;

-- =========================================================================
-- 5. Audit log: ahora que tienen tenant_id, aplica el trigger genérico
-- =========================================================================
CREATE TRIGGER trg_changelog_departamentos
  AFTER INSERT OR UPDATE OR DELETE ON public.departamentos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_municipios
  AFTER INSERT OR UPDATE OR DELETE ON public.municipios
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_comunidades
  AFTER INSERT OR UPDATE OR DELETE ON public.comunidades
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();


-- >>> Migration: 0098_red_topologia.sql <<<
-- 0098: Topología de red per-tenant (Nodo → Hub → Puerto).
--
-- Catálogo jerárquico que cada tenant arma con su infraestructura. El cliente
-- se conecta a un Puerto (clientes.puerto_id); Hub y Nodo se derivan de la
-- cadena. Greenfield (sin data previa). Mismo patrón que geografía per-tenant.
-- Solo nombre/código por nivel (sin capacidad/ocupación por ahora).

-- =========================================================================
-- 1. Tablas
-- =========================================================================
CREATE TABLE public.red_nodos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  codigo text,
  -- Tipo de nodo (ISP nica suele ser mixto). Da contexto a los incidentes.
  tipo text CHECK (tipo IS NULL OR tipo IN ('fibra','wireless','hibrido')),
  -- Ubicación física del nodo (torre/OLT) para el futuro mapa de outages.
  lat double precision,
  lng double precision,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.red_hubs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nodo_id uuid NOT NULL REFERENCES public.red_nodos(id) ON DELETE RESTRICT,
  nombre text NOT NULL,
  codigo text,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nodo_id, nombre)
);

CREATE TABLE public.red_puertos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  hub_id uuid NOT NULL REFERENCES public.red_hubs(id) ON DELETE RESTRICT,
  nombre text NOT NULL,
  codigo text,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, hub_id, nombre)
);

CREATE INDEX red_hubs_by_nodo    ON public.red_hubs (tenant_id, nodo_id);
CREATE INDEX red_puertos_by_hub  ON public.red_puertos (tenant_id, hub_id);

-- Cliente → Puerto (opcional). Nodo/Hub se derivan de la cadena.
-- ON DELETE SET NULL: borrar/recablear un puerto NO debe bloquearse por tener
-- clientes; el cliente sigue existiendo, solo pierde su punto de conexión.
ALTER TABLE public.clientes
  ADD COLUMN puerto_id uuid REFERENCES public.red_puertos(id) ON DELETE SET NULL;
CREATE INDEX clientes_by_puerto ON public.clientes (puerto_id);

-- =========================================================================
-- 2. RLS — read: miembro del tenant; write: admin/admin_cobranza
-- =========================================================================
ALTER TABLE public.red_nodos   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.red_hubs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.red_puertos ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['red_nodos','red_hubs','red_puertos']
  LOOP
    EXECUTE format('CREATE POLICY "red_read" ON public.%I FOR SELECT USING (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "red_insert" ON public.%I FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "red_update" ON public.%I FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "red_delete" ON public.%I FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());', t);
  END LOOP;
END $$;

-- =========================================================================
-- 3. Audit log (trigger genérico)
-- =========================================================================
CREATE TRIGGER trg_changelog_red_nodos
  AFTER INSERT OR UPDATE OR DELETE ON public.red_nodos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_red_hubs
  AFTER INSERT OR UPDATE OR DELETE ON public.red_hubs
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_red_puertos
  AFTER INSERT OR UPDATE OR DELETE ON public.red_puertos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();


-- >>> Migration: 0099_inventario_catalogo.sql <<<
-- 0099: Inventario — Sub-fase 2A (catálogo). Módulo OPCIONAL, gateado por
-- tenant_modulos ('inventario', es_base=false → deshabilitado por defecto; el
-- super_admin lo habilita por tenant). Per-tenant, RLS, audit. Admin-facing.
--
-- Tablas de catálogo (master data): categorías, proveedores, productos.
-- (Ubicaciones, seriales, recepciones y movimientos llegan en 2B/2C.)
-- Stock NO se materializa: se deriva del ledger (inv_movimientos, 2C). Sin
-- inv_stock ni trigger de proyección en el MVP.

-- =========================================================================
-- 1. Tablas
-- =========================================================================
CREATE TABLE public.inv_categorias (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  orden int NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.inv_proveedores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  telefono text,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.inv_productos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  categoria_id uuid REFERENCES public.inv_categorias(id) ON DELETE SET NULL,
  codigo text,                       -- SKU interno opcional
  nombre text NOT NULL,
  -- Equipo serializado (ONU/router/STB) vs granel (cable/conectores).
  es_serializado boolean NOT NULL DEFAULT false,
  unidad text NOT NULL DEFAULT 'unidad',   -- unidad/metro/rollo/caja...
  -- granel que se mide con decimales (cable por metro) vs entero.
  maneja_decimal boolean NOT NULL DEFAULT false,
  costo_promedio numeric(12,2) NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE INDEX inv_productos_by_categoria
  ON public.inv_productos (tenant_id, categoria_id);

-- =========================================================================
-- 2. RLS — read: miembro del tenant (forward-compat con técnico de Fase 3);
--    write: admin/admin_cobranza; super_admin_all a mano.
-- =========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['inv_categorias','inv_proveedores','inv_productos']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('CREATE POLICY "inv_read" ON public.%I FOR SELECT USING (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "inv_insert" ON public.%I FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "inv_update" ON public.%I FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "inv_delete" ON public.%I FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());', t);
  END LOOP;
END $$;

-- =========================================================================
-- 3. Audit log (trigger genérico)
-- =========================================================================
CREATE TRIGGER trg_changelog_inv_categorias
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_categorias
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_inv_proveedores
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_proveedores
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_inv_productos
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_productos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- =========================================================================
-- 4. Gating: que la app sepa qué módulos tiene habilitado el tenant.
-- tenant_modulos tiene PK compuesta (tenant_id, modulo_codigo) y PowerSync
-- exige un `id` por fila para sincronizar. Agregamos un id único; la app lo
-- baja READ-ONLY (la escritura sigue siendo del super_admin vía RPC).
-- =========================================================================
ALTER TABLE public.tenant_modulos
  ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_modulos_id_key'
  ) THEN
    ALTER TABLE public.tenant_modulos
      ADD CONSTRAINT tenant_modulos_id_key UNIQUE (id);
  END IF;
END $$;


-- >>> Migration: 0100_inventario_ubicaciones.sql <<<
-- 0100: Inventario — Sub-fase 2B. Ubicaciones (bodegas/custodias).
-- Master data. central/bodega/vehiculo + 'tecnico' (custodia por técnico,
-- se cablea en Fase 3 con el rol técnico; cobrador_id queda preparado).
-- Per-tenant, RLS, audit. (inv_proveedores ya existe en 0099.)

CREATE TABLE public.inv_ubicaciones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  tipo text NOT NULL DEFAULT 'central'
    CHECK (tipo IN ('central','bodega','vehiculo','tecnico')),
  -- Para tipo='tecnico': a qué empleado pertenece la custodia (Fase 3).
  cobrador_id uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  activa boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE INDEX inv_ubicaciones_by_tenant ON public.inv_ubicaciones (tenant_id);

ALTER TABLE public.inv_ubicaciones ENABLE ROW LEVEL SECURITY;

CREATE POLICY "inv_read" ON public.inv_ubicaciones
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inv_insert" ON public.inv_ubicaciones
  FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_update" ON public.inv_ubicaciones
  FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_delete" ON public.inv_ubicaciones
  FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.inv_ubicaciones
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

CREATE TRIGGER trg_changelog_inv_ubicaciones
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_ubicaciones
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();


-- >>> Migration: 0101_inventario_movimientos.sql <<<
-- 0101: Inventario — Sub-fase 2C (núcleo). Ledger de movimientos + seriales.
--
-- Filosofía: el stock NO se edita directo ni se materializa. Es una PROYECCIÓN
-- derivada del ledger `inv_movimientos` (append-only). Stock de un producto en
-- una ubicación = SUM(cantidad con destino=U) − SUM(cantidad con origen=U).
-- Cada movimiento tiene origen y/o destino:
--   ingreso: solo destino (+) · egreso/baja/consumo: solo origen (−)
--   transferencia: origen (−) + destino (+) · asignacion: origen (−, serial→cliente)
--   devolucion: destino (+) · ajuste: destino (+) u origen (−) según signo
-- `inv_seriales` lleva 1 fila por unidad serializada (ONU/router) con su estado
-- y ubicación/cliente actuales (trazabilidad = su historial de movimientos).

-- =========================================================================
-- 1. Seriales (unidades físicas de productos serializados)
-- =========================================================================
CREATE TABLE public.inv_seriales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  producto_id uuid NOT NULL REFERENCES public.inv_productos(id) ON DELETE RESTRICT,
  serial text NOT NULL,
  mac text,
  estado text NOT NULL DEFAULT 'en_stock'
    CHECK (estado IN ('en_stock','instalado','danado','retirado','baja')),
  ubicacion_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  cliente_id uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  contrato_id uuid REFERENCES public.contratos(id) ON DELETE SET NULL,
  costo_ingreso numeric(12,2),
  notas text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, serial)
);

CREATE INDEX inv_seriales_by_producto ON public.inv_seriales (tenant_id, producto_id);
CREATE INDEX inv_seriales_by_cliente  ON public.inv_seriales (tenant_id, cliente_id);
CREATE INDEX inv_seriales_by_ubicacion ON public.inv_seriales (tenant_id, ubicacion_id);

-- =========================================================================
-- 2. Movimientos (ledger append-only) — fuente de verdad del stock
-- =========================================================================
CREATE TABLE public.inv_movimientos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  tipo text NOT NULL CHECK (tipo IN
    ('ingreso','egreso','ajuste','transferencia','asignacion','consumo','devolucion','baja')),
  producto_id uuid NOT NULL REFERENCES public.inv_productos(id) ON DELETE RESTRICT,
  serial_id uuid REFERENCES public.inv_seriales(id) ON DELETE SET NULL,
  cantidad numeric(12,2) NOT NULL DEFAULT 1,
  ubicacion_origen_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  ubicacion_destino_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  cliente_id uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  contrato_id uuid REFERENCES public.contratos(id) ON DELETE SET NULL,
  proveedor_id uuid REFERENCES public.inv_proveedores(id) ON DELETE SET NULL,
  numero_factura text,
  costo_unitario numeric(12,2),
  motivo text,
  notas text,
  ticket_id uuid,                 -- Fase 3 (consumo desde un ticket); sin FK aún
  hecho_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline)
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX inv_mov_by_producto ON public.inv_movimientos (tenant_id, producto_id);
CREATE INDEX inv_mov_by_serial   ON public.inv_movimientos (serial_id);
CREATE INDEX inv_mov_by_destino  ON public.inv_movimientos (tenant_id, ubicacion_destino_id);
CREATE INDEX inv_mov_by_origen   ON public.inv_movimientos (tenant_id, ubicacion_origen_id);

-- =========================================================================
-- 3. RLS
-- =========================================================================
ALTER TABLE public.inv_seriales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inv_movimientos ENABLE ROW LEVEL SECURITY;

-- Seriales: read miembro del tenant; write admin/admin_cobranza.
CREATE POLICY "inv_read" ON public.inv_seriales
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inv_insert" ON public.inv_seriales
  FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_update" ON public.inv_seriales
  FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_delete" ON public.inv_seriales
  FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.inv_seriales
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Movimientos: APPEND-ONLY. read + insert (admin); SIN update/delete (para
-- corregir se agrega un movimiento inverso, como el audit log).
CREATE POLICY "inv_read" ON public.inv_movimientos
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inv_insert" ON public.inv_movimientos
  FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.inv_movimientos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 4. Audit log
-- =========================================================================
CREATE TRIGGER trg_changelog_inv_seriales
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_seriales
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_inv_movimientos
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_movimientos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();


-- >>> Migration: 0102_guardas_borrado_ledger_appendonly.sql <<<
-- 0102: Guardas server-side de borrado + ledger estrictamente append-only.
--
-- Hallazgos del audit integral de Fase 2:
--  · (Agent 7, MEDIA) inv_ubicaciones / inv_proveedores tienen FK ON DELETE
--    SET NULL hacia seriales/movimientos → la guarda client-side de "en uso"
--    corre sobre SQLite local; multi-device offline podía borrar una ubicación/
--    proveedor en uso y dejar el movimiento/serial huérfano (ubicacion_id NULL)
--    en silencio. Agregamos un BEFORE DELETE server-side que rechaza el borrado.
--  · (R1) red_puertos tiene FK SET NULL hacia clientes.puerto_id; comunidades
--    es NO ACTION (restrict) hacia clientes.comunidad_id (corrige el comentario
--    original que decía SET NULL — audit 2026-06-24) → mismo riesgo de uso:
--    borrar un puerto/comunidad en uso rompería el vínculo. Mismo guard server.
--  · (Agent 4, F3) la policy super_admin_all de inv_movimientos era FOR ALL →
--    permitía al super_admin UPDATE/DELETE del ledger append-only. La acotamos
--    a SELECT + INSERT (corregir = movimiento inverso, como el audit_log).
--
-- Los guards son CASCADE-SAFE: si el tenant ya no existe (borrado del tenant en
-- progreso, ej. rollback de crear-tenant) NO bloquean, así no rompen el cascade.
-- `inv_productos` NO necesita guard: sus FK (seriales/movimientos.producto_id)
-- ya son ON DELETE RESTRICT (el server lo rechaza solo).
--
-- IDEMPOTENTE: cada CREATE TRIGGER/POLICY lleva su DROP ... IF EXISTS y todo va
-- en una transacción → se puede re-correr por Dashboard sin dejar estado a medias.

BEGIN;

-- =========================================================================
-- 1. Guard: inv_ubicaciones en uso (seriales o movimientos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.inv_ubicaciones_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Cascade del tenant: el tenant ya se borró → no bloquear.
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inv_seriales WHERE ubicacion_id = OLD.id)
     OR EXISTS (SELECT 1 FROM public.inv_movimientos
                 WHERE ubicacion_origen_id = OLD.id
                    OR ubicacion_destino_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar la ubicación: tiene equipos o movimientos asociados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_inv_ubicaciones_guard_borrado ON public.inv_ubicaciones;
CREATE TRIGGER trg_inv_ubicaciones_guard_borrado
  BEFORE DELETE ON public.inv_ubicaciones
  FOR EACH ROW EXECUTE FUNCTION public.inv_ubicaciones_guard_borrado();

-- =========================================================================
-- 2. Guard: inv_proveedores en uso (movimientos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.inv_proveedores_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inv_movimientos WHERE proveedor_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar el proveedor: tiene movimientos asociados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_inv_proveedores_guard_borrado ON public.inv_proveedores;
CREATE TRIGGER trg_inv_proveedores_guard_borrado
  BEFORE DELETE ON public.inv_proveedores
  FOR EACH ROW EXECUTE FUNCTION public.inv_proveedores_guard_borrado();

-- =========================================================================
-- 3. Guard: red_puertos en uso (clientes.puerto_id) — cierra R1
-- =========================================================================
CREATE OR REPLACE FUNCTION public.red_puertos_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.clientes WHERE puerto_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar el puerto: tiene clientes conectados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_red_puertos_guard_borrado ON public.red_puertos;
CREATE TRIGGER trg_red_puertos_guard_borrado
  BEFORE DELETE ON public.red_puertos
  FOR EACH ROW EXECUTE FUNCTION public.red_puertos_guard_borrado();

-- =========================================================================
-- 4. Guard: comunidades en uso (clientes.comunidad_id) — R1 geo
-- =========================================================================
CREATE OR REPLACE FUNCTION public.comunidades_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.clientes WHERE comunidad_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar la comunidad: tiene clientes asignados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_comunidades_guard_borrado ON public.comunidades;
CREATE TRIGGER trg_comunidades_guard_borrado
  BEFORE DELETE ON public.comunidades
  FOR EACH ROW EXECUTE FUNCTION public.comunidades_guard_borrado();

-- =========================================================================
-- 5. Ledger append-only estricto: super_admin solo SELECT + INSERT
-- =========================================================================
DROP POLICY IF EXISTS "super_admin_all" ON public.inv_movimientos;
DROP POLICY IF EXISTS "super_admin_select" ON public.inv_movimientos;
DROP POLICY IF EXISTS "super_admin_insert" ON public.inv_movimientos;

CREATE POLICY "super_admin_select" ON public.inv_movimientos
  FOR SELECT USING (public.is_super_admin());
CREATE POLICY "super_admin_insert" ON public.inv_movimientos
  FOR INSERT WITH CHECK (public.is_super_admin());

COMMIT;


-- >>> Migration: 0103_tickets_fundacion.sql <<<
-- 0103: Fase 3 — Fundación de Tickets (slice 3A).
--
-- Agrega: roles `tecnico` + `admin_tickets`; módulo opcional `tickets`; y las
-- tablas núcleo ticket_tipos / tickets / ticket_eventos / ticket_adjuntos con
-- RLS per-tenant, audit y un trigger que valida las transiciones de estado
-- server-side ("server gana", decisión D2). Materiales (engancha inventario) e
-- incidentes llegan en 3C/3D — por eso `tickets.incidente_id` queda sin FK aún.
--
-- Correlativo del ticket: cliente-computado (MAX+1 por tenant) con UNIQUE de
-- respaldo, mismo patrón que recibos (decisión D4). Módulo `tickets` es_base=false
-- → OFF por defecto; lo enciende el super_admin.
--
-- IDEMPOTENTE + transaccional (lección de 0102).

BEGIN;

-- =========================================================================
-- 1. Roles: agregar tecnico + admin_tickets al CHECK
-- =========================================================================
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets'));

-- set_cobrador_rol: permitir los dos roles nuevos. tecnico/admin_tickets NO
-- cobran → caen al `else null` del prefijo (no llevan correlativo de recibo).
CREATE OR REPLACE FUNCTION public.set_cobrador_rol(
  p_cobrador_id uuid,
  p_nuevo_rol   text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_tenant uuid;
  v_target_rol    text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_cobrador_id = auth.uid() THEN
    RAISE EXCEPTION 'No podés modificar tu propio rol';
  END IF;
  IF p_nuevo_rol NOT IN ('admin','admin_cobranza','cobrador','tecnico','admin_tickets') THEN
    RAISE EXCEPTION 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets';
  END IF;

  SELECT tenant_id, rol INTO v_target_tenant, v_target_rol
  FROM public.cobradores WHERE id = p_cobrador_id FOR UPDATE;

  IF v_target_rol IS NULL THEN
    RAISE EXCEPTION 'Cobrador no existe' USING errcode = 'P0002';
  END IF;
  IF v_target_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede modificar el rol de otro super_admin';
  END IF;
  IF v_target_rol = p_nuevo_rol THEN
    RETURN;
  END IF;

  UPDATE public.cobradores
  SET rol = p_nuevo_rol,
      prefijo_recibo = CASE
        WHEN p_nuevo_rol IN ('cobrador','admin','admin_cobranza')
          THEN prefijo_recibo
        ELSE NULL
      END
  WHERE id = p_cobrador_id;

  INSERT INTO public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) VALUES (
    v_target_tenant, 'cobradores', p_cobrador_id, 'rol',
    to_jsonb(v_target_rol), to_jsonb(p_nuevo_rol), auth.uid(), 'super_admin'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_cobrador_rol(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.set_cobrador_rol(uuid, text) TO authenticated;

-- =========================================================================
-- 2. Módulo opcional `tickets` (OFF por defecto)
-- =========================================================================
INSERT INTO public.modulos (codigo, nombre, descripcion, es_base, orden) VALUES
  ('tickets', 'Tickets',
   'Gestión de trabajo de campo: instalaciones, reparaciones, reclamos y cortes (outages), con rol técnico.',
   false, 30)
ON CONFLICT (codigo) DO NOTHING;

-- =========================================================================
-- 3. Helpers de rol para tickets
-- =========================================================================
CREATE OR REPLACE FUNCTION public.is_admin_or_tickets() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.current_user_rol() IN ('admin','admin_tickets');
$$;

-- Staff que opera tickets: admin, admin_tickets y el técnico (crea/resuelve).
CREATE OR REPLACE FUNCTION public.is_ticket_staff() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.current_user_rol() IN ('admin','admin_tickets','tecnico');
$$;

-- =========================================================================
-- 4. ticket_tipos (catálogo per-tenant con SLA por tipo)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ticket_tipos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  descripcion text,
  sla_horas integer CHECK (sla_horas IS NULL OR sla_horas > 0),
  color text,
  orden integer NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_tipos_by_tenant ON public.ticket_tipos (tenant_id);

-- =========================================================================
-- 5. tickets
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  correlativo integer NOT NULL CHECK (correlativo > 0),
  tipo_id uuid REFERENCES public.ticket_tipos(id) ON DELETE RESTRICT,
  cliente_id uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  puerto_id uuid REFERENCES public.red_puertos(id) ON DELETE SET NULL,
  incidente_id uuid,                       -- FK en 3D (incidentes aún no existe)
  titulo text NOT NULL,
  descripcion text,
  estado text NOT NULL DEFAULT 'abierto'
    CHECK (estado IN ('abierto','asignado','en_progreso','en_espera',
                      'resuelto','cerrado','reabierto','cancelado')),
  prioridad text CHECK (prioridad IS NULL OR
    prioridad IN ('baja','media','alta','urgente')),
  asignado_a uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  creado_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  resuelto_en timestamptz,
  cerrado_en timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline)
  UNIQUE (tenant_id, correlativo)
);
CREATE INDEX IF NOT EXISTS tickets_by_tenant   ON public.tickets (tenant_id, estado);
CREATE INDEX IF NOT EXISTS tickets_by_cliente  ON public.tickets (tenant_id, cliente_id);
CREATE INDEX IF NOT EXISTS tickets_by_asignado ON public.tickets (tenant_id, asignado_a);

-- Validación de transición de estado (D2: server gana). Rechaza saltos inválidos.
CREATE OR REPLACE FUNCTION public.tickets_validar_transicion() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado = OLD.estado THEN RETURN NEW; END IF;
  IF NOT (
    (OLD.estado = 'abierto'     AND NEW.estado IN ('asignado','en_progreso','cancelado')) OR
    (OLD.estado = 'asignado'    AND NEW.estado IN ('en_progreso','en_espera','abierto','cancelado')) OR
    (OLD.estado = 'en_progreso' AND NEW.estado IN ('en_espera','resuelto','asignado','cancelado')) OR
    (OLD.estado = 'en_espera'   AND NEW.estado IN ('en_progreso','resuelto','cancelado')) OR
    (OLD.estado = 'resuelto'    AND NEW.estado IN ('cerrado','reabierto')) OR
    (OLD.estado = 'reabierto'   AND NEW.estado IN ('asignado','en_progreso','en_espera','resuelto','cancelado')) OR
    (OLD.estado = 'cerrado'     AND NEW.estado IN ('reabierto')) OR
    (OLD.estado = 'cancelado'   AND NEW.estado IN ('reabierto'))
  ) THEN
    RAISE EXCEPTION 'Transición de estado inválida: % → %', OLD.estado, NEW.estado;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_tickets_validar_transicion ON public.tickets;
CREATE TRIGGER trg_tickets_validar_transicion
  BEFORE UPDATE OF estado ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_validar_transicion();

-- =========================================================================
-- 6. ticket_eventos (bitácora APPEND-ONLY)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ticket_eventos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  tipo_evento text NOT NULL CHECK (tipo_evento IN
    ('creado','asignado','cambio_estado','comentario','material','adjunto',
     'reabierto','cerrado','cancelado')),
  estado_anterior text,
  estado_nuevo text,
  comentario text,
  hecho_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  ocurrido_en timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_eventos_by_ticket ON public.ticket_eventos (ticket_id);

-- =========================================================================
-- 7. ticket_adjuntos (fotos del ticket)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ticket_adjuntos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  descripcion text,
  subido_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_adjuntos_by_ticket ON public.ticket_adjuntos (ticket_id);

-- =========================================================================
-- 8. RLS — read: miembro del tenant; write: staff de tickets (o config admin)
-- =========================================================================
ALTER TABLE public.ticket_tipos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickets         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_eventos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_adjuntos ENABLE ROW LEVEL SECURITY;

-- ticket_tipos: lo configura el admin/admin_tickets.
DROP POLICY IF EXISTS "tt_read"   ON public.ticket_tipos;
DROP POLICY IF EXISTS "tt_write"  ON public.ticket_tipos;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_tipos;
CREATE POLICY "tt_read"  ON public.ticket_tipos FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "tt_write" ON public.ticket_tipos FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets());
CREATE POLICY "super_admin_all" ON public.ticket_tipos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- tickets: crea/edita el staff (admin/admin_tickets/tecnico).
DROP POLICY IF EXISTS "tk_read"   ON public.tickets;
DROP POLICY IF EXISTS "tk_write"  ON public.tickets;
DROP POLICY IF EXISTS "super_admin_all" ON public.tickets;
CREATE POLICY "tk_read"  ON public.tickets FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "tk_write" ON public.tickets FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_ticket_staff())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.tickets
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- ticket_eventos: APPEND-ONLY (read + insert; sin update/delete).
DROP POLICY IF EXISTS "te_read"   ON public.ticket_eventos;
DROP POLICY IF EXISTS "te_insert" ON public.ticket_eventos;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_eventos;
CREATE POLICY "te_read"   ON public.ticket_eventos FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "te_insert" ON public.ticket_eventos FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.ticket_eventos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- ticket_adjuntos: read + write del staff (puede borrar una foto equivocada).
DROP POLICY IF EXISTS "ta_read"  ON public.ticket_adjuntos;
DROP POLICY IF EXISTS "ta_write" ON public.ticket_adjuntos;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_adjuntos;
CREATE POLICY "ta_read"  ON public.ticket_adjuntos FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "ta_write" ON public.ticket_adjuntos FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_ticket_staff())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.ticket_adjuntos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 9. Audit log (trigger genérico) en las 4 tablas
-- =========================================================================
DROP TRIGGER IF EXISTS trg_changelog_ticket_tipos ON public.ticket_tipos;
CREATE TRIGGER trg_changelog_ticket_tipos
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_tipos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

DROP TRIGGER IF EXISTS trg_changelog_tickets ON public.tickets;
CREATE TRIGGER trg_changelog_tickets
  AFTER INSERT OR UPDATE OR DELETE ON public.tickets
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

DROP TRIGGER IF EXISTS trg_changelog_ticket_eventos ON public.ticket_eventos;
CREATE TRIGGER trg_changelog_ticket_eventos
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_eventos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

DROP TRIGGER IF EXISTS trg_changelog_ticket_adjuntos ON public.ticket_adjuntos;
CREATE TRIGGER trg_changelog_ticket_adjuntos
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_adjuntos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

COMMIT;


-- >>> Migration: 0104_ticket_adjuntos_storage.sql <<<
-- 0104: Storage bucket para los adjuntos (fotos) de tickets — Fase 3 (3A).
--
-- Convención de path: {tenant_id}/{ticket_id}/{timestamp}.{ext} → la policy filtra
-- por tenant con el primer segmento (`storage_path_tenant`, 0019). Read = miembro
-- del tenant; write = staff de tickets (`is_ticket_staff`, 0103). Depende de 0103.
-- Idempotente + transaccional.

BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
  ('ticket-adjuntos', 'ticket-adjuntos', false, 5 * 1024 * 1024,
   array['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

-- LECTURA: cualquier miembro del tenant ve los adjuntos del tenant.
DROP POLICY IF EXISTS "storage_read_ticket_adjuntos" ON storage.objects;
CREATE POLICY "storage_read_ticket_adjuntos" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'ticket-adjuntos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- ESCRITURA: el staff de tickets (admin / admin_tickets / técnico).
DROP POLICY IF EXISTS "storage_write_ticket_adjuntos" ON storage.objects;
CREATE POLICY "storage_write_ticket_adjuntos" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'ticket-adjuntos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_ticket_staff()
  )
  WITH CHECK (
    bucket_id = 'ticket-adjuntos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_ticket_staff()
  );

COMMIT;


-- >>> Migration: 0105_ticket_sla_pausa.sql <<<
-- 0105: SLA con pausa EXACTA por `en_espera` (Fase 3, completa la pausa del PLAN).
--
-- 3A dejó la pausa aproximada (solo pausa si el ticket está en espera AHORA). Acá
-- la hacemos exacta: acumulamos el tiempo total que el ticket estuvo en `en_espera`
-- en `tickets.segundos_pausado`, y el SLA derivado en el cliente lo suma al plazo.
--
-- OFFLINE-AWARE: el trigger usa `NEW.ocurrido_en` (device-time de la transición),
-- NO `now()` server — así el cómputo es correcto aunque la transición se haya hecho
-- offline y sincronice más tarde. `en_espera_desde` guarda el device-time de entrada
-- a en_espera; al salir, suma (salida.ocurrido_en − en_espera_desde) a los segundos.
--
-- Idempotente + transaccional. NO deployado aún (3A pendiente) → schema v21→v22.

BEGIN;

ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS segundos_pausado integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS en_espera_desde timestamptz;

-- Re-crear el trigger de transición (0103) sumándole la contabilidad de la pausa.
-- Sigue siendo BEFORE UPDATE OF estado, así que puede mutar NEW.
CREATE OR REPLACE FUNCTION public.tickets_validar_transicion() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado = OLD.estado THEN RETURN NEW; END IF;

  -- 1. Validar la transición (matriz, igual que 0103). "server gana".
  IF NOT (
    (OLD.estado = 'abierto'     AND NEW.estado IN ('asignado','en_progreso','cancelado')) OR
    (OLD.estado = 'asignado'    AND NEW.estado IN ('en_progreso','en_espera','abierto','cancelado')) OR
    (OLD.estado = 'en_progreso' AND NEW.estado IN ('en_espera','resuelto','asignado','cancelado')) OR
    (OLD.estado = 'en_espera'   AND NEW.estado IN ('en_progreso','resuelto','cancelado')) OR
    (OLD.estado = 'resuelto'    AND NEW.estado IN ('cerrado','reabierto')) OR
    (OLD.estado = 'reabierto'   AND NEW.estado IN ('asignado','en_progreso','en_espera','resuelto','cancelado')) OR
    (OLD.estado = 'cerrado'     AND NEW.estado IN ('reabierto')) OR
    (OLD.estado = 'cancelado'   AND NEW.estado IN ('reabierto'))
  ) THEN
    RAISE EXCEPTION 'Transición de estado inválida: % → %', OLD.estado, NEW.estado;
  END IF;

  -- 2. Contabilidad de la pausa de SLA (device-time → offline-safe).
  IF NEW.estado = 'en_espera' AND OLD.estado <> 'en_espera' THEN
    NEW.en_espera_desde := NEW.ocurrido_en;
  ELSIF OLD.estado = 'en_espera' AND NEW.estado <> 'en_espera' THEN
    NEW.segundos_pausado := COALESCE(OLD.segundos_pausado, 0)
      + GREATEST(0, EXTRACT(EPOCH FROM
          (NEW.ocurrido_en - COALESCE(OLD.en_espera_desde, NEW.ocurrido_en)))::int);
    NEW.en_espera_desde := NULL;
  END IF;

  RETURN NEW;
END;
$$;
-- El trigger trg_tickets_validar_transicion (0103) ya apunta a esta función.

COMMIT;


-- >>> Migration: 0106_ticket_materiales.sql <<<
-- 0106: Tickets Fase 3C — materiales consumidos en un ticket (engancha INVENTARIO).
--
-- El técnico (o admin) registra el material que instaló/usó en un ticket. El
-- descuento de stock es 100% SERVER-SIDE (decisión D1 del FASE3-PLAN): el técnico
-- NO tiene permiso directo sobre inv_* (esas policies son is_admin_or_cobranza),
-- así que un trigger SECURITY DEFINER hace el inv_movimientos tipo 'consumo' y,
-- si es serializado, marca el serial 'instalado' en el cliente del ticket.
--
-- OFFLINE-FIRST + "server gana": el técnico crea la fila `ticket_materiales`
-- offline (un simple append); al sincronizar corre el trigger y proyecta el
-- inventario. NO bloquea por stock insuficiente (tolerancia negativa offline,
-- igual que el resto del inventario — el ledger es la verdad y se concilia).
--
-- TRAZABILIDAD: la fila `ticket_materiales` ES la acción auditada del usuario
-- (insert a depth 0 → audit a depth 1, dispara). El inv_movimientos de consumo y
-- el UPDATE del serial los crea el trigger a depth 1 → su audit caería a depth 2 →
-- el guard `pg_trigger_depth() < 2` los saltea a propósito (son PROYECCIÓN
-- derivada, no acción de usuario, como `cuota.monto_pagado`). El consumo se
-- surfacea en la bitácora del ticket y en el historial cuna-a-tumba del serial
-- (HistorialSerialWidget une `ticket_materiales`).
--
-- Idempotente + transaccional. NO deployado aún → schema v22→v23.

BEGIN;

-- 1. Materiales consumidos por ticket. APPEND-ONLY (read + insert; corregir un
--    error = flujo inverso futuro, NO update/delete — como el ledger de inventario).
CREATE TABLE IF NOT EXISTS public.ticket_materiales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  producto_id uuid NOT NULL REFERENCES public.inv_productos(id) ON DELETE RESTRICT,
  serial_id uuid REFERENCES public.inv_seriales(id) ON DELETE SET NULL,
  cantidad numeric(12,2) NOT NULL DEFAULT 1 CHECK (cantidad > 0),
  ubicacion_origen_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  costo_unit_snapshot numeric(12,2),
  hecho_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline)
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_materiales_by_ticket ON public.ticket_materiales (ticket_id);
CREATE INDEX IF NOT EXISTS ticket_materiales_by_serial ON public.ticket_materiales (serial_id);

-- 2. FK de inv_movimientos.ticket_id (existía sin FK desde 0101; ahora se usa).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inv_mov_ticket_fk') THEN
    ALTER TABLE public.inv_movimientos
      ADD CONSTRAINT inv_mov_ticket_fk FOREIGN KEY (ticket_id)
      REFERENCES public.tickets(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 3. RLS: read = miembro del tenant; insert = staff de tickets (incluye TÉCNICO,
--    a diferencia de inv_* que es is_admin_or_cobranza). Append-only.
ALTER TABLE public.ticket_materiales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tm_read"   ON public.ticket_materiales;
DROP POLICY IF EXISTS "tm_insert" ON public.ticket_materiales;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_materiales;
CREATE POLICY "tm_read"   ON public.ticket_materiales FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "tm_insert" ON public.ticket_materiales FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.ticket_materiales
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- 4. Audit del change-log (la fila ticket_materiales = la acción del usuario).
DROP TRIGGER IF EXISTS trg_changelog_ticket_materiales ON public.ticket_materiales;
CREATE TRIGGER trg_changelog_ticket_materiales
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_materiales
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- 5. Trigger de CONSUMO (D1, SECURITY DEFINER → puede escribir inv_* aunque el
--    técnico no tenga permiso directo). Descuenta del origen y, si es serial,
--    lo marca 'instalado' en el cliente del ticket.
CREATE OR REPLACE FUNCTION public.ticket_materiales_consumo() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cliente uuid;
  v_existe  boolean := false;
BEGIN
  -- Defensa cross-tenant (SECURITY DEFINER saltea RLS → validamos a mano que TODO
  -- FK pertenezca a NEW.tenant_id; la FK sola sólo garantiza existencia, no co-
  -- tenencia, y NEW.tenant_id está anclado por la RLS WITH CHECK al tenant real
  -- del que escribe). Sin esto, una fila podría referenciar recursos de otro tenant.
  SELECT cliente_id, true INTO v_cliente, v_existe
    FROM public.tickets
   WHERE id = NEW.ticket_id AND tenant_id = NEW.tenant_id;
  IF NOT COALESCE(v_existe, false) THEN
    RAISE EXCEPTION 'Ticket % no pertenece al tenant %', NEW.ticket_id, NEW.tenant_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inv_productos
                  WHERE id = NEW.producto_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Producto % no pertenece al tenant %', NEW.producto_id, NEW.tenant_id;
  END IF;
  IF NEW.ubicacion_origen_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inv_ubicaciones
         WHERE id = NEW.ubicacion_origen_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Ubicación % no pertenece al tenant %', NEW.ubicacion_origen_id, NEW.tenant_id;
  END IF;
  IF NEW.serial_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inv_seriales
         WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Serial % no pertenece al tenant %', NEW.serial_id, NEW.tenant_id;
  END IF;

  -- 1. Serializado: el serial pasa a 'instalado' en el cliente del ticket.
  --    Guards: estado='en_stock' (no pisa un serial ya instalado/dado de baja) +
  --    ubicacion_id == ubicacion_origen_id declarada. Este 2º guard cierra dos cosas:
  --    (a) custodia intra-tenant — sólo consumís un serial de DONDE realmente está
  --        (la UI siempre setea ubicacion_origen_id = la ubicación del serial), así un
  --        insert crafteado con un serial ajeno + otra ubicación no lo instala;
  --    (b) idempotencia del dup offline — el 2º consumo del mismo serial ya no está
  --        en_stock allí → no consume.
  --    Si no consumió nada → no-op SIN registrar movimiento (offline-safe, sin RAISE
  --    para no trabar la cola de upload de PowerSync). La fila ticket_materiales queda
  --    igual como registro del intento.
  IF NEW.serial_id IS NOT NULL THEN
    UPDATE public.inv_seriales
       SET estado = 'instalado', cliente_id = v_cliente, ubicacion_id = NULL
     WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id AND estado = 'en_stock'
       AND ubicacion_id IS NOT DISTINCT FROM NEW.ubicacion_origen_id;
    IF NOT FOUND THEN
      RETURN NEW; -- ya instalado / no está en el origen → no duplicamos el movimiento
    END IF;
  END IF;

  -- 2. Movimiento de consumo (descuenta del origen = custodia/ubicación). Serial:
  --    sólo si se consumió arriba. Granel (serial NULL): siempre — el stock granel
  --    tolera ir negativo si dos devices descuentan offline (por diseño; se reconcilia
  --    en el ledger append-only).
  INSERT INTO public.inv_movimientos
    (id, tenant_id, tipo, producto_id, serial_id, cantidad,
     ubicacion_origen_id, cliente_id, ticket_id, costo_unitario,
     motivo, hecho_por, ocurrido_en, created_at)
  VALUES
    (gen_random_uuid(), NEW.tenant_id, 'consumo', NEW.producto_id, NEW.serial_id,
     NEW.cantidad, NEW.ubicacion_origen_id, v_cliente, NEW.ticket_id,
     NEW.costo_unit_snapshot, 'Consumo en ticket', NEW.hecho_por,
     NEW.ocurrido_en, now());

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ticket_materiales_consumo ON public.ticket_materiales;
CREATE TRIGGER trg_ticket_materiales_consumo
  AFTER INSERT ON public.ticket_materiales
  FOR EACH ROW EXECUTE FUNCTION public.ticket_materiales_consumo();

COMMIT;


-- >>> Migration: 0107_incidentes.sql <<<
-- 0107: Tickets Fase 3D — incidentes (outages/cortes). Un incidente agrupa un
-- corte de servicio; los clientes afectados se DERIVAN de la topología de red
-- (clientes.puerto_id → red_puertos.hub_id → red_hubs.nodo_id), y los tickets se
-- agrupan por `incidente_id` (la columna ya existe en tickets desde 0103, sin FK).
--
-- Alcance del corte (jerárquico, EXCLUYENTE): a lo sumo UNO de nodo/hub/puerto
-- (corte de ese nivel hacia abajo) o TODOS NULL (corte general del tenant). El
-- CHECK lo fuerza. FK a red con ON DELETE SET NULL (recablear la red no borra el
-- histórico del incidente).
--
-- Admin-facing (write = is_admin_or_tickets; el técnico NO crea incidentes, sólo
-- ve sus tickets que el admin agrupó). Idempotente + transaccional. schema v23→v24.

BEGIN;

CREATE TABLE IF NOT EXISTS public.incidentes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  titulo text NOT NULL,
  descripcion text,
  -- Alcance: a lo sumo uno set (nivel del corte) o todos NULL (corte general).
  nodo_id   uuid REFERENCES public.red_nodos(id)   ON DELETE SET NULL,
  hub_id    uuid REFERENCES public.red_hubs(id)    ON DELETE SET NULL,
  puerto_id uuid REFERENCES public.red_puertos(id) ON DELETE SET NULL,
  estado text NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','resuelto')),
  inicio timestamptz NOT NULL DEFAULT now(),
  fin timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline/audit)
  CONSTRAINT incidentes_un_solo_nivel CHECK (
    ((nodo_id IS NOT NULL)::int + (hub_id IS NOT NULL)::int
     + (puerto_id IS NOT NULL)::int) <= 1
  )
);
CREATE INDEX IF NOT EXISTS incidentes_by_tenant ON public.incidentes (tenant_id, estado);

-- FK diferida de 0103: ahora que incidentes existe, atamos tickets.incidente_id.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tickets_incidente_fk') THEN
    ALTER TABLE public.tickets
      ADD CONSTRAINT tickets_incidente_fk FOREIGN KEY (incidente_id)
      REFERENCES public.incidentes(id) ON DELETE SET NULL;
  END IF;
END $$;

-- RLS: read = miembro del tenant; write = admin/admin_tickets (config-level).
ALTER TABLE public.incidentes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "inc_read"  ON public.incidentes;
DROP POLICY IF EXISTS "inc_write" ON public.incidentes;
DROP POLICY IF EXISTS "super_admin_all" ON public.incidentes;
CREATE POLICY "inc_read"  ON public.incidentes FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inc_write" ON public.incidentes FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets());
CREATE POLICY "super_admin_all" ON public.incidentes
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Audit del change-log.
DROP TRIGGER IF EXISTS trg_changelog_incidentes ON public.incidentes;
CREATE TRIGGER trg_changelog_incidentes
  AFTER INSERT OR UPDATE OR DELETE ON public.incidentes
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

COMMIT;


-- >>> Migration: 0108_incidente_alcance_label.sql <<<
-- 0108: incidentes — snapshot del alcance (fix del audit cross-módulo 3D).
--
-- Problema: el alcance (nodo/hub/puerto) es FK ON DELETE SET NULL. Si más tarde se
-- borra ese nodo/hub/puerto, el incidente histórico pierde su nivel (FK → NULL) y
-- la UI lo lee como "corte general (todos los clientes)" — engañoso en un post-mortem.
-- El delete-guard de red ya impide borrar un puerto/hub/nodo CON clientes, pero el
-- residual (borrar tras mover los clientes, con un incidente histórico apuntando) deja
-- una ambigüedad de etiqueta.
--
-- Fix: columna denormalizada `alcance_label` que captura el nombre legible del alcance
-- al crear (ej. "Puerto: Puerto 3" / "Corte general"). La UI prefiere el nombre VIVO del
-- FK (maneja renombres) y cae al snapshot cuando el FK quedó NULL (borrado). Es el mismo
-- patrón de denormalización que cobrador_id en cuotas/pagos. Idempotente.

BEGIN;

ALTER TABLE public.incidentes
  ADD COLUMN IF NOT EXISTS alcance_label text;

COMMIT;


-- >>> Migration: 0109_tickets_auto_cierre.sql <<<
-- 0109 — SLA accionable: auto-cierre de tickets resueltos (cron diario).
--
-- Cierra automáticamente los tickets en estado 'resuelto' que llevan más de N
-- días sin reapertura (N = setting per-tenant `tickets.auto_cierre_dias`; 0 =
-- desactivado, que es el DEFAULT). Deja el rastro en la bitácora (`ticket_eventos`)
-- con autor = NULL (= "Sistema" en la UI). Reversible: `cerrado→reabierto` sigue
-- siendo una transición válida.
--
-- Simplicidad a propósito (no repetir el lío de Nodos): NO crea tablas ni
-- columnas ni vínculos nuevos. Usa SOLO columnas que `tickets` ya tiene
-- (`estado`, `resuelto_en`, `cerrado_en`). NO toca el cálculo del SLA (se basa en
-- `resuelto_en`, no en el deadline) → cero lógica de SLA en el server. Sin bump de
-- schema, sin redeploy de sync rules (los cambios de estado/cerrado_en viajan por
-- el `SELECT *` existente).
--
-- Patrón espejado del cron de mora (0009/0011/0034): SECURITY DEFINER per-tenant +
-- `setting_number` + cron diario. La transición resuelto→cerrado ya está validada
-- por el CHECK + el trigger de 0103; los triggers de pausa/audit conviven sin tocar.

begin;

-- =========================================================================
-- 1. Función per-tenant. En el cron `auth.uid()` es NULL (no hay usuario) → la
--    RLS de tickets/ticket_eventos bloquearía el write; por eso SECURITY DEFINER
--    + `row_security = off` explícito (idéntico a actualizar_notificaciones_mora).
-- =========================================================================
create or replace function public.tickets_auto_cierre(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dias int := public.setting_number(p_tenant_id, 'tickets.auto_cierre_dias', 0)::int;
  v_filas int := 0;
begin
  -- 0 (o ausente) = desactivado. Default → el cron no cierra nada hasta que el
  -- admin lo prenda en el editor de Tipos.
  if v_dias <= 0 then
    return 0;
  end if;
  set local row_security = off;

  -- Cierra los 'resuelto' vencidos y registra el evento de bitácora de cada uno.
  -- CTE data-modifying: el UPDATE corre una vez; `eventos` lee su RETURNING e
  -- inserta un evento por ticket cerrado; el SELECT final cuenta desde `eventos`
  -- (así ambas CTE se ejecutan con seguridad). hecho_por = NULL = "Sistema".
  with cerrados as (
    update public.tickets t
       set estado = 'cerrado',
           cerrado_en = now(),
           ocurrido_en = now()
     where t.tenant_id = p_tenant_id
       and t.estado = 'resuelto'
       and t.resuelto_en is not null
       and t.resuelto_en < now() - (v_dias || ' days')::interval
    returning t.id, t.tenant_id
  ),
  eventos as (
    insert into public.ticket_eventos
      (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
       ocurrido_en, created_at)
    select gen_random_uuid(), c.tenant_id, c.id, 'cerrado',
           'Cerrado automáticamente tras ' || v_dias || ' días sin reapertura',
           null, now(), now()
      from cerrados c
    returning 1
  )
  select count(*)::int into v_filas from eventos;

  return v_filas;
end $$;

-- =========================================================================
-- 2. Cron diario (06:30 UTC = 00:30 Nicaragua; no colisiona con generar_cuotas
--    06:05 ni mora 12:00). Idempotente: desagenda por nombre si ya existe, luego
--    agenda. La hora exacta no afecta el resultado (es "N días desde resuelto_en",
--    no un corte de día calendario), así que no necesita SET timezone.
-- =========================================================================
select cron.unschedule(jobid)
  from cron.job where jobname = 'tickets_auto_cierre_diario';
select cron.schedule(
  'tickets_auto_cierre_diario',
  '30 6 * * *',
  $$ select public.tickets_auto_cierre(t.id) from public.tenants t; $$
);

commit;


-- >>> Migration: 0110_calidad_campo_stock_minimo.sql <<<
-- 0110 — Calidad de campo (checklists) + Inventario v2 (stock mínimo).
--
-- Approach SIMPLE (lección de Nodos): NO crea tablas ni jerarquías ni vínculos
-- nuevos. Solo 3 columnas en tablas que ya existen. La firma del cliente NO está
-- acá: reusa `ticket_adjuntos` (0104), cero schema.
--
-- 1. CHECKLISTS — el tipo define el template, el ticket guarda su SNAPSHOT.
--    `ticket_tipos.checklist_template` (JSONB): lista de pasos que edita el admin,
--      ej. ["Verificar señal","Configurar router"].
--    `tickets.checklist` (JSONB): snapshot al crear, [{"texto":..,"hecho":bool}].
--      El snapshot evita que editar el template rompa los tickets ya creados (cada
--      ticket es dueño de su copia — no queda linkeado frágil al template).
--    El técnico tilda → update del JSONB en el ticket que ya posee (offline-safe).
--
-- 2. STOCK MÍNIMO — `inv_productos.stock_minimo` (numeric, 0 = sin alerta). La
--    alerta es DERIVADA en el cliente (lista resalta bajo-mínimo + badge), sin cron
--    ni tabla de notificaciones — el stock se computa del ledger.
--
-- Sin RLS nueva (las columnas heredan la de su tabla) ni triggers nuevos (los
-- cambios los capturan los audit triggers existentes). Idempotente.
--
-- ⚠️ Cadena de integridad: schema.dart declara las 3 columnas, `_schemaVersion`
-- 25→26 (db.dart), y redeploy de sync rules (el SELECT * de tickets/ticket_tipos/
-- inv_productos ya las cubre).

begin;

alter table public.ticket_tipos
  add column if not exists checklist_template jsonb not null default '[]'::jsonb;

alter table public.tickets
  add column if not exists checklist jsonb not null default '[]'::jsonb;

alter table public.inv_productos
  add column if not exists stock_minimo numeric not null default 0;

commit;


-- >>> Migration: 0111_cuotas_cobrador_no_desanular.sql <<<
-- 0111 — RLS hardening: el cobrador no puede DES-anular una cuota.
--
-- El trigger `cuotas_check_cobrador_update` (0022) bloquea que un rol cobrador
-- ponga estado='anulada' (anular es acción de admin). Pero NO cubría el camino
-- inverso: cambiar el estado DESDE 'anulada' a otro valor. Vía su policy
-- `cuotas_update_cobrador_propio`, un cobrador podía "revivir" una cuota anulada
-- (anulada → pendiente/parcial/pagada) y volver a cobrarla, salteándose el
-- control de anulación del admin y la cascada de pagos/recibos (0023).
--
-- FIX (defensivo): el trigger también rechaza cualquier cambio de estado cuando
-- la cuota YA está 'anulada'. Para el cobrador una cuota anulada es TERMINAL;
-- sólo un admin (sin esta restricción) puede reactivarla si hiciera falta. No
-- hay flujo legítimo del cobrador que des-anule (la UI ya oculta/bloquea cobrar
-- cuotas anuladas), así que el bloqueo no rompe nada operativo.
--
-- Idempotente (CREATE OR REPLACE). El trigger `trg_cuotas_check_cobrador_update`
-- (0022) sigue apuntando a esta función por nombre — no hace falta recrearlo.
-- Sólo función server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

create or replace function public.cuotas_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if new.monto         is distinct from old.monto         or
       new.contrato_id   is distinct from old.contrato_id   or
       new.cliente_id    is distinct from old.cliente_id    or
       new.cobrador_id   is distinct from old.cobrador_id   or
       new.periodo       is distinct from old.periodo       or
       new.fecha_vencimiento is distinct from old.fecha_vencimiento or
       new.tenant_id     is distinct from old.tenant_id     or
       new.anulada_en    is distinct from old.anulada_en    or
       new.anulada_por   is distinct from old.anulada_por   or
       new.motivo_anulacion is distinct from old.motivo_anulacion or
       -- No puede anular...
       (new.estado <> old.estado and new.estado = 'anulada') or
       -- ...ni des-anular (reactivar) una cuota ya anulada.
       (new.estado <> old.estado and old.estado = 'anulada')
    then
      raise exception 'cobrador no puede anular ni reactivar cuotas; sólo monto_pagado y transiciones de cobro';
    end if;
  end if;
  return new;
end;
$$;

COMMIT;


-- >>> Migration: 0112_mora_resolver_al_anular.sql <<<
-- 0112 — Resolver la notificación de mora también al ANULAR la cuota.
--
-- `resolver_notificacion_al_pagar` (0008) cierra la notificación de mora cuando
-- la cuota pasa a 'pagada'. Pero al ANULAR una cuota (ej. al cancelar un
-- contrato, que anula sus cuotas pendientes — típicamente ya en mora, que es por
-- lo que se cancela) la notificación quedaba ABIERTA → mora fantasma en el panel
-- del admin y del cobrador para una cuota que ya no se cobra.
--
-- FIX: resolver la notificación cuando la cuota deja los estados "abiertos"
-- (pasa a 'pagada' O 'anulada'). El caso 'pagada' se comporta idéntico que antes
-- (no hay regresión). Idempotente (CREATE OR REPLACE); el trigger
-- `trg_resolver_notificacion_al_pagar` (0008) sigue apuntando a esta función por
-- nombre. Sólo server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

create or replace function public.resolver_notificacion_al_pagar()
returns trigger language plpgsql as $$
begin
  if new.estado in ('pagada', 'anulada')
     and old.estado not in ('pagada', 'anulada') then
    update public.notificaciones_mora
       set resuelta_en = now()
     where cuota_id = new.id
       and resuelta_en is null;
  end if;
  return new;
end;
$$;

COMMIT;


-- >>> Migration: 0113_dias_cuotas_proximas_default_5.sql <<<
-- 0113_dias_cuotas_proximas_default_5.sql
--
-- "Días de cuotas próximas" (setting `cobranza.dias_cuotas_visibles`) = rango,
-- en días a partir de hoy, dentro del cual una cuota futura se considera
-- "próxima a pagar" y se muestra al cobrador (mapa + lista "Por cobrar"). Las
-- que vencen más allá del rango quedan FUERA (el cobrador no las ve; en el
-- detalle del contrato salen en gris "no disponible").
--
-- El default histórico del seed era 30; pasa a 5 para TODOS los tenants
-- (existentes y nuevos) — decisión de Rubén ("por defecto siempre 5").
--
-- También marca como super_admin-only (`editable_por`) las 4 reglas/permisos de
-- cobro sensibles que la UI movió a la tab Avanzado (pago_parcial,
-- pago_adelantado, cobrador_anula_cobros, cobrador_edita_cobros) — para que la
-- RLS los proteja igual que el resto de los settings super-only (consistencia
-- DB ↔ UI; antes quedaban editables por el admin vía API directa).
--
-- Sin cambios de schema/columnas → NO requiere bump de _schemaVersion ni
-- redeploy de sync rules (la tabla `settings` ya sincroniza por SELECT *).
-- Idempotente: se puede correr más de una vez sin efectos colaterales.

-- (1) Tenants EXISTENTES → 5 en TODOS. `DO UPDATE` fuerza 5 incluso donde había
--     el viejo default 30 (Rubén: "todos a 5"). Inserta la fila donde falte.
insert into public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
select id, 'cobranza.dias_cuotas_visibles', '5'::jsonb, 'number', 'cobranza',
       'Días de cuotas próximas (rango visible al cobrador)', 'admin'
from public.tenants
on conflict (tenant_id, clave) do update set valor = '5'::jsonb;

-- (2) `dias_gracia` = 10 donde FALTE (defensivo, tenants muy viejos). `DO
--     NOTHING` no pisa la configuración de los que ya la tienen.
insert into public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
select id, 'cobranza.dias_gracia', '10'::jsonb, 'number', 'cobranza',
       'Días entre vencimiento y notificación de mora', 'admin'
from public.tenants
on conflict (tenant_id, clave) do nothing;

-- (2b) Reglas/permisos sensibles → super_admin-only en tenants EXISTENTES
--      (consistencia con la UI, que los muestra solo en la tab Avanzado). NO
--      cambia el `valor`; solo `editable_por`, para que la RLS settings_write_admin
--      (que bloquea editable_por='super_admin') los proteja.
update public.settings set editable_por = 'super_admin'
  where clave in ('cobranza.pago_parcial', 'cobranza.pago_adelantado',
                  'cobranza.cobrador_anula_cobros',
                  'cobranza.cobrador_edita_cobros');

-- (3) Tenants NUEVOS: el trigger de alta siembra 30 vía `seed_settings_default`.
--     En vez de recrear esa función entera (riesgo de perder alguna clave),
--     agregamos un paso final al trigger que normaliza el valor a 5. Se mantiene
--     idéntico al cuerpo vigente (0090) + el UPDATE.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  -- Default nuevo: 5 días de cuotas próximas (el seed aún inserta 30; se
  -- normaliza acá para no recrear la función completa).
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  -- Reglas/permisos sensibles → super_admin-only (el seed los crea como 'admin';
  -- la UI los muestra solo en Avanzado, así que la RLS debe acompañar).
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial', 'cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros',
                    'cobranza.cobrador_edita_cobros');
  return new;
end;
$$;


-- >>> Migration: 0114_gate_modulos_server_side.sql <<<
-- ============================================================================
-- 0114 — Gate server-side de módulos opcionales (M2 del AUDIT-INTEGRAL-2026-06-09)
--
-- PROBLEMA: las policies de inventario (0099-0101) y tickets/incidentes
-- (0103/0106/0107) chequean tenant + rol pero NO consultan tenant_tiene_modulo().
-- El gate de "módulo habilitado" vivía solo en el router/UI del cliente → un
-- admin de un tenant con el módulo OFF podía leer/escribir esas tablas vía
-- REST/PowerSync directo (mismo tenant, no cruza tenants — es un gap de
-- consistencia COMERCIAL, no de aislamiento). Mismo patrón ya cerrado
-- server-side para settings super-only (0085) y descuentos/reconexión (0086).
--
-- DECISIÓN (write-only gating):
--   · ESCRITURA (insert/update/delete) → exige tenant_tiene_modulo(). Es la
--     decisión comercial del dueño del SaaS: sin módulo contratado, no se opera.
--   · LECTURA (select) → NO se gatea. Apagar un módulo no debe "desaparecer"
--     la data histórica que el admin pueda necesitar consultar; y la
--     replicación de PowerSync no pasa por RLS de todos modos (sync rules).
--   · super_admin_all queda INTACTA (OR entre policies → el super siempre opera).
--
-- NOTAS DE COMPORTAMIENTO:
--   · El trigger SECURITY DEFINER ticket_materiales_consumo (0106) sigue
--     funcionando aunque 'inventario' esté OFF y 'tickets' ON: corre como el
--     owner (bypassa RLS sin FORCE). El consumo de materiales es del módulo
--     tickets; los inv_movimientos derivados son proyección del sistema.
--   · Si un tenant tiene writes offline ENCOLADOS y el super le apaga el módulo
--     antes del sync: los INSERT se rechazan (42501) y el connector los
--     descarta CON aviso; los UPDATE/DELETE bloqueados por USING son no-op
--     silenciosos (0 rows, 2xx) — el dato local diverge hasta que el próximo
--     checkpoint server-wins lo pisa (self-heals, sin aviso). Edge case
--     aceptado: apagar un módulo con campo activo es acción deliberada del super.
--
-- DEFENSIVA: cada bloque se saltea con NOTICE si la tabla no existe todavía
-- (migraciones 0099→0107 sin correr) → esta migración es segura de correr en
-- cualquier orden relativo al deploy del bloque inventario/tickets. Si se
-- corrió ANTES, RE-CORRERLA después de 0099→0107 para que aplique completa.
-- Idempotente (DROP POLICY IF EXISTS + CREATE).
-- ============================================================================

DO $$
DECLARE
  t text;
BEGIN
  -- ── Inventario: inv_insert / inv_update / inv_delete + módulo 'inventario' ──
  FOREACH t IN ARRAY ARRAY[
    'inv_categorias', 'inv_proveedores', 'inv_productos',
    'inv_ubicaciones', 'inv_seriales'
  ] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE '0114: tabla % no existe (0099-0101 sin correr) — skip', t;
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS "inv_insert" ON public.%I;', t);
    EXECUTE format($p$
      CREATE POLICY "inv_insert" ON public.%I FOR INSERT
        WITH CHECK (tenant_id = public.current_tenant_id()
                    AND public.is_admin_or_cobranza()
                    AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
    $p$, t);
    EXECUTE format('DROP POLICY IF EXISTS "inv_update" ON public.%I;', t);
    EXECUTE format($p$
      CREATE POLICY "inv_update" ON public.%I FOR UPDATE
        USING (tenant_id = public.current_tenant_id()
               AND public.is_admin_or_cobranza()
               AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
    $p$, t);
    EXECUTE format('DROP POLICY IF EXISTS "inv_delete" ON public.%I;', t);
    EXECUTE format($p$
      CREATE POLICY "inv_delete" ON public.%I FOR DELETE
        USING (tenant_id = public.current_tenant_id()
               AND public.is_admin_or_cobranza()
               AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
    $p$, t);
  END LOOP;

  -- inv_movimientos: ledger append-only (solo tenía inv_insert).
  IF to_regclass('public.inv_movimientos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "inv_insert" ON public.inv_movimientos;
    CREATE POLICY "inv_insert" ON public.inv_movimientos FOR INSERT
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_admin_or_cobranza()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
  ELSE
    RAISE NOTICE '0114: inv_movimientos no existe — skip';
  END IF;

  -- ── Tickets / incidentes: módulo 'tickets' ─────────────────────────────────
  -- ticket_tipos (tt_write FOR ALL, is_admin_or_tickets)
  IF to_regclass('public.ticket_tipos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "tt_write" ON public.ticket_tipos;
    CREATE POLICY "tt_write" ON public.ticket_tipos FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_admin_or_tickets()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_admin_or_tickets()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_tipos no existe (0103 sin correr) — skip';
  END IF;

  -- tickets (tk_write FOR ALL, is_ticket_staff)
  IF to_regclass('public.tickets') IS NOT NULL THEN
    DROP POLICY IF EXISTS "tk_write" ON public.tickets;
    CREATE POLICY "tk_write" ON public.tickets FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_ticket_staff()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: tickets no existe (0103 sin correr) — skip';
  END IF;

  -- ticket_eventos (te_insert, append-only, is_ticket_staff)
  IF to_regclass('public.ticket_eventos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "te_insert" ON public.ticket_eventos;
    CREATE POLICY "te_insert" ON public.ticket_eventos FOR INSERT
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_eventos no existe (0103 sin correr) — skip';
  END IF;

  -- ticket_adjuntos (ta_write FOR ALL, is_ticket_staff)
  IF to_regclass('public.ticket_adjuntos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "ta_write" ON public.ticket_adjuntos;
    CREATE POLICY "ta_write" ON public.ticket_adjuntos FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_ticket_staff()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_adjuntos no existe (0103 sin correr) — skip';
  END IF;

  -- ticket_materiales (tm_insert, append-only, is_ticket_staff)
  IF to_regclass('public.ticket_materiales') IS NOT NULL THEN
    DROP POLICY IF EXISTS "tm_insert" ON public.ticket_materiales;
    CREATE POLICY "tm_insert" ON public.ticket_materiales FOR INSERT
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_materiales no existe (0106 sin correr) — skip';
  END IF;

  -- incidentes (inc_write FOR ALL, is_admin_or_tickets)
  IF to_regclass('public.incidentes') IS NOT NULL THEN
    DROP POLICY IF EXISTS "inc_write" ON public.incidentes;
    CREATE POLICY "inc_write" ON public.incidentes FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_admin_or_tickets()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_admin_or_tickets()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: incidentes no existe (0107 sin correr) — skip';
  END IF;

  -- ── Storage del bucket ticket-adjuntos (0104): mismo gap, mismo gate ───────
  -- Sin esto, un tenant con tickets OFF no podía crear la fila ta_write
  -- (gateada arriba) pero SÍ subir binarios al bucket vía Storage API.
  -- La función helper storage_path_tenant + la policy existen solo si 0104
  -- corrió; el to_regprocedure lo detecta.
  IF to_regprocedure('public.storage_path_tenant(text)') IS NOT NULL THEN
    DROP POLICY IF EXISTS "storage_write_ticket_adjuntos" ON storage.objects;
    CREATE POLICY "storage_write_ticket_adjuntos" ON storage.objects
      FOR ALL TO authenticated
      USING (
        bucket_id = 'ticket-adjuntos'
        AND public.storage_path_tenant(name) = public.current_tenant_id()
        AND public.is_ticket_staff()
        AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets')
      )
      WITH CHECK (
        bucket_id = 'ticket-adjuntos'
        AND public.storage_path_tenant(name) = public.current_tenant_id()
        AND public.is_ticket_staff()
        AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets')
      );
  ELSE
    RAISE NOTICE '0114: storage_path_tenant no existe (0104 sin correr) — skip';
  END IF;
END$$;

-- Verificación rápida post-run (debe listar las policies recreadas con el gate):
--   SELECT schemaname, tablename, policyname, qual, with_check FROM pg_policies
--    WHERE (schemaname='public' AND policyname IN
--      ('inv_insert','inv_update','inv_delete','tt_write','tk_write',
--       'te_insert','ta_write','tm_insert','inc_write'))
--       OR (schemaname='storage' AND policyname='storage_write_ticket_adjuntos')
--    ORDER BY schemaname, tablename, policyname;
-- Cada qual/with_check debe contener "tenant_tiene_modulo".


-- >>> Migration: 0115_ajustes_cuota_y_reversion_descuentos.sql <<<
-- 0115 — Ajustes de cuota (Sprint 2 del audit 2026-06-11) + reversión de
-- descuentos al anular pago (fix M3).
--
-- FEATURE (aprobada por Rubén 2026-06-11): el admin/admin_cobranza puede
-- aplicar un AJUSTE (descuento con motivo) a una cuota — p.ej. el cliente
-- pasó sin servicio N días. Principio rector: todo ajuste/promo es una fila
-- en `cargos_extra` (NUNCA se muta `cuotas.monto`): el saldo, los mirrors,
-- el changelog y las invariantes ya digieren cargos_extra.
--
-- FIX M3 (audit): los descuentos automáticos (pronto pago) que un cobro
-- insertaba NO se revertían al anular el pago — la cuota quedaba con el
-- total rebajado para siempre. Ahora cada cargo nacido de un cobro lleva
-- `pago_id`, y anular el pago BORRA sus descuentos (trigger server +
-- mirror local en PagosRepo.anularPago).
--
-- Cadena de integridad (Receta R4): correr esta migración → schema.dart
-- (3 columnas nuevas) → bump _schemaVersion 26→27 → redeploy sync rules
-- ("Active"; los SELECT * las incluyen solos) → app desde cero.

BEGIN;

-- =========================================================================
-- 1. Columnas nuevas de cargos_extra.
--    `origen`: de qué flujo nació el cargo (gobierna guards y UI).
--    `grupo_promo`: agrupa los N cargos de una promoción (Sprint 3) para
--    mostrarlos/revertirlos juntos.
--    `pago_id`: el pago que insertó este cargo automático (M3). SIN FK a
--    propósito: PowerSync sube la CRUD queue en orden de escritura y los
--    cargos del cobro se insertan ANTES que su pago — una FK rebotaría el
--    cargo con 23503 y el connector lo descartaría. La coherencia la
--    garantizan el flujo de cobro (transacción local) y este archivo.
-- =========================================================================
alter table public.cargos_extra
  add column origen text not null default 'cobro'
    check (origen in ('cobro', 'ajuste', 'promo', 'liquidacion')),
  add column grupo_promo uuid,
  add column pago_id uuid;

create index cargos_extra_pago_idx
  on public.cargos_extra (pago_id)
  where pago_id is not null;

comment on column public.cargos_extra.origen is
  'Flujo que creó el cargo: cobro (campo/auto), ajuste (admin con motivo), '
  'promo (Sprint 3), liquidacion (cancelar contrato).';

-- =========================================================================
-- 2. Helper setting_bool (espejo de setting_number, 0011).
-- =========================================================================
create or replace function public.setting_bool(
  p_tenant_id uuid, p_clave text, p_default boolean)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select (valor)::boolean
       from public.settings
      where tenant_id = p_tenant_id and clave = p_clave),
    p_default
  )
$$;

-- =========================================================================
-- 3. Settings del feature (patrón 0085/0086: super-only, enforced por la
--    policy settings_write_admin que excluye editable_por='super_admin').
-- =========================================================================
create or replace function public.seed_settings_ajustes(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'cobranza.ajustes_habilitados', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite al admin aplicar ajustes (descuentos con motivo) a cuotas',
     'super_admin'),
    (p_tenant_id, 'cobranza.ajuste_max_porcentaje', '50'::jsonb, 'number',
     'cobranza', 'Tope porcentual de un ajuste de cuota (0=sin tope)',
     'super_admin'),
    (p_tenant_id, 'cobranza.ajuste_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope en C$ de un ajuste de cuota (0=sin tope)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_ajustes(v_t.id);
  end loop;
end $$;

-- Tenant nuevo: encadenar el seed. OJO (audit Fase 4): se parte del cuerpo
-- VIGENTE (0113 — incluye recibo_layout, el default 5 de dias_cuotas_visibles
-- y la promoción super-only de las 4 claves sensibles), NO del de 0085.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  -- Default nuevo: 5 días de cuotas próximas (el seed aún inserta 30; se
  -- normaliza acá para no recrear la función completa). [0113]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  -- Reglas/permisos sensibles → super_admin-only. [0113]
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial', 'cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros',
                    'cobranza.cobrador_edita_cobros');
  -- Ajustes de cuota (0115).
  perform public.seed_settings_ajustes(new.id);
  return new;
end;
$$;

-- =========================================================================
-- 4. Guard server-side de ajustes (el control REAL, no solo UI — lección
--    del finding 0046/M7: un setting que gatea dinero se enforcea acá).
--    Sin bypass para super_admin a propósito (previene errores; el súper
--    puede cambiar los topes si lo necesita).
-- =========================================================================
create or replace function public.cargos_ajuste_guard_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_max_pct numeric;
  v_max_monto numeric;
begin
  -- Cascadas y re-upserts NO se re-validan (audit Fase 4): un UPDATE que no
  -- toca los campos gobernados (p.ej. la reasignación de cobrador de 0068,
  -- o el re-upsert idéntico de un retry de batch de PowerSync) pasa de
  -- largo — sin esto, deshabilitar el feature o bajar topes REBOTABA
  -- cascadas sobre ajustes históricos legítimos.
  if tg_op = 'UPDATE'
     and new.tipo = old.tipo
     and new.monto = old.monto
     and coalesce(new.porcentaje, -1) = coalesce(old.porcentaje, -1)
     and coalesce(new.descripcion, '') = coalesce(old.descripcion, '')
     and new.origen = old.origen then
    return new;
  end if;
  if not public.setting_bool(
      new.tenant_id, 'cobranza.ajustes_habilitados', false) then
    raise exception
      'Los ajustes de cuota no están habilitados para esta empresa';
  end if;
  if public.current_user_rol() = 'cobrador' then
    raise exception 'Solo un admin puede aplicar ajustes de cuota';
  end if;
  if new.tipo not in ('descuento_monto', 'descuento_porcentaje') then
    raise exception
      'Un ajuste solo puede ser un descuento (monto o porcentaje)';
  end if;
  if new.descripcion is null or btrim(new.descripcion) = '' then
    raise exception 'El ajuste requiere un motivo';
  end if;

  v_max_pct := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_porcentaje', 0);
  v_max_monto := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_monto', 0);
  if v_max_pct > 0
     and new.tipo = 'descuento_porcentaje'
     and coalesce(new.porcentaje, 0) > v_max_pct then
    raise exception
      'El ajuste excede el tope configurado de % por ciento', v_max_pct;
  end if;
  if v_max_monto > 0 and new.monto > v_max_monto + 0.01 then
    raise exception 'El ajuste excede el tope de C$% configurado', v_max_monto;
  end if;
  -- Limitación documentada (audit Fase 4, BAJA): el guard NO valida
  -- monto ≤ saldo (carrera offline cobro+ajuste puede sobrepagar; el repo
  -- lo valida con su snapshot local e INV4 lo detecta a posteriori) —
  -- misma clase aceptada que el cobro concurrente multi-dispositivo.
  return new;
end $$;

create trigger trg_cargos_ajuste_guard
  before insert or update on public.cargos_extra
  for each row
  when (new.origen = 'ajuste')
  execute function public.cargos_ajuste_guard_trg();

-- =========================================================================
-- 5. M3: anular un pago borra LOS DESCUENTOS que ese cobro insertó (los
--    identifica pago_id). La reconexión se preserva a propósito (se sigue
--    debiendo). El DELETE dispara en cascada trg_cargos_extra_actualizar_neto
--    (0023, recalcula cargos_neto) y trg_cargos_extra_recalcular_cuota
--    (0018, recalcula estado) — depth 1 al encolar, así que el changelog
--    del cargo borrado SÍ se registra (guard depth<2).
--    Orden con trg_pagos_update_recalcular: alfabético → 'revertir' corre
--    ANTES que 'update_recalcular'; ambos recálculos son SUMs idempotentes.
-- =========================================================================
create or replace function public.pagos_revertir_descuentos_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.cargos_extra
   where pago_id = new.id
     and tipo in ('descuento_monto', 'descuento_porcentaje');
  return new;
end $$;

create trigger trg_pagos_revertir_descuentos
  after update of anulado on public.pagos
  for each row
  when (new.anulado = true and old.anulado = false)
  execute function public.pagos_revertir_descuentos_trg();

-- =========================================================================
-- 6. Quitar ajuste también para admin_cobranza (QA Fase 4, finding ALTO):
--    la policy de DELETE de 0013 exigía is_admin(), pero la UI de ajustes
--    es para admin Y admin_cobranza — su DELETE moría FILTRADO por RLS en
--    silencio (0 filas, sin error) y el cargo "resucitaba" al sync con la
--    cuota ya espejada en 0 → divergencia muda de dinero. UPDATE ya era
--    is_admin_or_cobranza (cargos_write_admins); el DELETE se alinea.
-- =========================================================================
drop policy "cargos_delete_admin" on public.cargos_extra;
create policy "cargos_delete_admin" on public.cargos_extra
  for delete using (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  );

COMMIT;

-- Verificación post-deploy (correr a mano):
--   select column_name from information_schema.columns
--    where table_name = 'cargos_extra'
--      and column_name in ('origen','grupo_promo','pago_id');   -- 3 filas
--   select tgname from pg_trigger
--    where tgrelid = 'public.cargos_extra'::regclass
--      and tgname = 'trg_cargos_ajuste_guard';                  -- 1 fila
--   select tgname from pg_trigger
--    where tgrelid = 'public.pagos'::regclass
--      and tgname = 'trg_pagos_revertir_descuentos';            -- 1 fila
--   select count(*) from public.settings
--    where clave like 'cobranza.ajuste%';        -- 3 × cantidad de tenants


-- >>> Migration: 0116_guards_server_sprint3.sql <<<
-- 0116 — Guards server-side del mega-sprint de correcciones (audit 2026-06-11,
-- Sprints 3/4: fixes #4, #9, #10, M18, M23 + filas audit fantasma).
--
-- Regla que cierra este archivo (lección 0046/0085): TODO control de dinero
-- o de integridad que un setting "apaga" tiene que vivir en el server — la
-- UI solo lo refleja. Un cobrador con su JWT puede hablarle a PostgREST
-- directo; las cascadas offline llegan en cualquier orden.

BEGIN;

-- =========================================================================
-- 1. (#4, HIGH del audit) Enforce server-side de cobrador_anula_cobros /
--    cobrador_edita_cobros. La policy 0046 dejaba al cobrador UPDATEar SUS
--    pagos vía REST aunque el admin tuviera los toggles en OFF (default):
--    vector de fraude real — cobrar en efectivo, anular por REST y quedarse
--    la plata (solo quedaba rastro en audit_log). Los toggles ahora son
--    control duro, como esperan los admins.
--    Columnas LIBRES a propósito: foto_comprobante_path (el worker de fotos
--    la setea post-upload), lat/lng, ocurrido_en, client_local_id.
--    Re-upserts idénticos de PowerSync (retry de batch) pasan: nada cambia.
-- =========================================================================
create or replace function public.pagos_guard_cobrador_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.current_user_rol() <> 'cobrador' then
    return new;
  end if;

  if new.anulado is distinct from old.anulado
     and not public.setting_bool(
           new.tenant_id, 'cobranza.cobrador_anula_cobros', false) then
    raise exception
      'Anular cobros está deshabilitado para cobradores en esta empresa';
  end if;

  if (new.monto_cordobas  is distinct from old.monto_cordobas
      or new.vuelto_cordobas is distinct from old.vuelto_cordobas
      or new.monto_original  is distinct from old.monto_original
      or new.tasa_conversion is distinct from old.tasa_conversion
      or new.metodo          is distinct from old.metodo
      or new.referencia      is distinct from old.referencia
      or new.notas           is distinct from old.notas
      or new.fecha_pago      is distinct from old.fecha_pago
      or new.cuota_id        is distinct from old.cuota_id)
     and not public.setting_bool(
           new.tenant_id, 'cobranza.cobrador_edita_cobros', false) then
    raise exception
      'Editar cobros está deshabilitado para cobradores en esta empresa';
  end if;
  return new;
end $$;

drop trigger if exists trg_pagos_guard_cobrador on public.pagos;
create trigger trg_pagos_guard_cobrador
  before update on public.pagos
  for each row execute function public.pagos_guard_cobrador_trg();

-- =========================================================================
-- 2. (#9, HIGH) Change log para `cobradores` — era la ÚNICA entidad editable
--    de las 27 sin trigger: cambiar el prefijo de recibo (numeración =
--    rastro de dinero) o desactivar a alguien no dejaba registro.
--    El cliente complementa con labels + historial en su pantalla.
-- =========================================================================
drop trigger if exists trg_changelog_cobradores on public.cobradores;
create trigger trg_changelog_cobradores
  after insert or update or delete on public.cobradores
  for each row when (pg_trigger_depth() < 2)
  execute function public.audit_changelog_trg();

-- =========================================================================
-- 3. (#10, HIGH) Transiciones de estado de inv_seriales — "server gana".
--    El write-path directo del admin (asignar/devolver/transferir) validaba
--    SOLO contra su SQLite local: dos devices offline podían asignar el
--    MISMO equipo a clientes distintos (last-writer-wins) o pisar el consumo
--    del técnico. Reglas mínimas que cierran ambos casos sin romper flujos:
--      a) pasar A 'instalado' exige venir de 'en_stock';
--      b) un 'instalado' no cambia de cliente sin pasar por stock.
--    El connector surfacea el rechazo (aviso persistente del Sprint 1).
-- =========================================================================
create or replace function public.inv_seriales_guard_transicion_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.estado = 'instalado'
     and old.estado is distinct from new.estado
     and old.estado <> 'en_stock' then
    raise exception
      'El equipo % no está en stock (estado actual: %)', old.serial, old.estado;
  end if;
  if new.estado = 'instalado' and old.estado = 'instalado'
     and new.cliente_id is distinct from old.cliente_id then
    raise exception
      'El equipo % ya está instalado en otro cliente; devolvelo a stock primero',
      old.serial;
  end if;
  return new;
end $$;

drop trigger if exists trg_inv_seriales_guard_transicion on public.inv_seriales;
create trigger trg_inv_seriales_guard_transicion
  before update on public.inv_seriales
  for each row execute function public.inv_seriales_guard_transicion_trg();

-- =========================================================================
-- 4. (M18) Correlativo de tickets: MAX+1 se calcula en el CLIENTE por
--    tenant — dos admins offline colisionaban (23505) y el ticket entero se
--    DESCARTABA de la cola. El server ahora re-asigna en conflicto: el
--    correlativo local es provisorio; el definitivo baja con el sync.
-- =========================================================================
create or replace function public.tickets_correlativo_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- `id <> new.id` (QA Fase 4): sin esto, el RE-UPSERT de un retry de
  -- PowerSync encontraba SU PROPIA fila como "conflicto" y renumeraba el
  -- ticket en cada reintento (EXCLUDED hereda el NEW post-trigger).
  if exists (select 1 from public.tickets
              where tenant_id = new.tenant_id
                and correlativo = new.correlativo
                and id <> new.id) then
    select coalesce(max(correlativo), 0) + 1
      into new.correlativo
      from public.tickets
     where tenant_id = new.tenant_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_tickets_correlativo on public.tickets;
create trigger trg_tickets_correlativo
  before insert on public.tickets
  for each row execute function public.tickets_correlativo_trg();

-- =========================================================================
-- 5. (M23) audit_log append-only TAMBIÉN para el super_admin: la
--    super_admin_all FOR ALL (0026) le permitía UPDATE/DELETE del log —
--    contradice la invariante #4. Mismo cierre que 0102 hizo para
--    inv_movimientos. El INSERT directo es legítimo (impersonación).
-- =========================================================================
drop policy if exists "super_admin_all" on public.audit_log;
drop policy if exists "super_admin_select" on public.audit_log;
drop policy if exists "super_admin_insert" on public.audit_log;
create policy "super_admin_select" on public.audit_log
  for select using (public.is_super_admin());
create policy "super_admin_insert" on public.audit_log
  for insert with check (public.is_super_admin());

-- =========================================================================
-- 6. (LOW del audit offline) Filas 'update' FANTASMA en el change log: el
--    retry de un batch parcial de PowerSync re-upserta filas idénticas y
--    cada una generaba una entrada update con old == new (ruido en los
--    historiales con conexión flaky). Guard no-op en la función genérica —
--    cubre las 28 tablas de una vez. (Cuerpo = versión 0069 + el guard.)
-- =========================================================================
create or replace function public.audit_changelog_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dev timestamptz;
begin
  if tg_op = 'UPDATE' then
    if to_jsonb(old) = to_jsonb(new) then
      return new; -- no-op (re-upsert de retry): sin entrada fantasma
    end if;
    v_dev := (to_jsonb(new)->>'ocurrido_en')::timestamptz;
    perform public.audit_registrar(
      new.tenant_id, tg_table_name, new.id, null,
      to_jsonb(old), to_jsonb(new), 'update', v_dev
    );
    return new;
  elsif tg_op = 'INSERT' then
    v_dev := (to_jsonb(new)->>'ocurrido_en')::timestamptz;
    perform public.audit_registrar(
      new.tenant_id, tg_table_name, new.id, null,
      null, to_jsonb(new), 'create', v_dev
    );
    return new;
  elsif tg_op = 'DELETE' then
    v_dev := (to_jsonb(old)->>'ocurrido_en')::timestamptz;
    perform public.audit_registrar(
      old.tenant_id, tg_table_name, old.id, null,
      to_jsonb(old), null, 'delete', v_dev
    );
    return old;
  end if;
  return null;
end;
$$;

COMMIT;

-- Verificación post-deploy (correr a mano):
--   select tgname from pg_trigger where tgrelid = 'public.pagos'::regclass
--     and tgname = 'trg_pagos_guard_cobrador';                    -- 1 fila
--   select tgname from pg_trigger where tgrelid = 'public.cobradores'::regclass
--     and tgname = 'trg_changelog_cobradores';                    -- 1 fila
--   select tgname from pg_trigger where tgrelid = 'public.inv_seriales'::regclass
--     and tgname = 'trg_inv_seriales_guard_transicion';           -- 1 fila
--   select tgname from pg_trigger where tgrelid = 'public.tickets'::regclass
--     and tgname = 'trg_tickets_correlativo';                     -- 1 fila
--   select policyname from pg_policies where tablename = 'audit_log'
--     and policyname like 'super_admin%';     -- super_admin_select + _insert


-- >>> Migration: 0117_promos_y_motivo_descuentos_cobro.sql <<<
-- 0117 — Rediseño de descuentos (decisión Rubén 2026-06-11, sesión de
-- rediseño post-feedback): las PROMOS van por el MISMO riel que los ajustes
-- (cargos_extra origen='promo', mismo diálogo con selector Ajuste/Promo) y
-- los descuentos del COBRO pasan a exigir motivo también en el server
-- (paridad real de reglas: "admin y cobrador, mismas reglas").
--
-- Server-side NO cambia el modelo: cero columnas nuevas (origen='promo' ya
-- existía en el CHECK de 0115 reservado para Sprint 3). Guards + una regla
-- de estado (§3, condonación). Cambios:
--   1. trg_cargos_ajuste_guard ahora también gobierna origen='promo'
--      (mismas validaciones: feature ON, rol admin, solo descuento, motivo,
--      topes ajuste_max_*).
--   2. trg_cargos_cobro_motivo_guard (nuevo): un descuento de origen='cobro'
--      exige motivo (descripcion). Los automáticos ya lo traían ("Descuento
--      pronto pago"); el manual del diálogo nuevo siempre manda motivo.
--      Los topes descuento_max_* del cobrador siguen UI-only (un tope server
--      rebotaría el pronto-pago automático, que no es negociación del
--      cobrador); INV4/INV13 detectan abusos a posteriori.
--
-- ⚠️ Transición: deployar JUNTO con la app de esta rama. Una cola offline
-- de una app VIEJA con descuento manual sin motivo sería rechazada por el
-- guard (P0001 → va a "Cambios sin sincronizar" del Perfil). Riesgo bajo:
-- el feature de descuentos del cobrador estaba recién en testing.
--
-- Sin cambios de schema → NO requiere bump de PowerSync ni redeploy de
-- sync rules.

BEGIN;

-- =========================================================================
-- 1. Guard de ajustes extendido a promos. El cuerpo ya era origen-agnóstico
--    (valida settings/rol/tipo/motivo/topes); se recrea solo para que los
--    mensajes cubran ambos casos y queda el trigger con WHEN ampliado.
--    Sin bypass para super_admin a propósito (igual que 0115).
-- =========================================================================
create or replace function public.cargos_ajuste_guard_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_max_pct numeric;
  v_max_monto numeric;
begin
  -- Cascadas y re-upserts NO se re-validan (audit Fase 4 de 0115): un
  -- UPDATE que no toca los campos gobernados (p.ej. la reasignación de
  -- cobrador de 0068, o el re-upsert idéntico de un retry de batch de
  -- PowerSync) pasa de largo — sin esto, deshabilitar el feature o bajar
  -- topes REBOTABA cascadas sobre descuentos históricos legítimos.
  if tg_op = 'UPDATE'
     and new.tipo = old.tipo
     and new.monto = old.monto
     and coalesce(new.porcentaje, -1) = coalesce(old.porcentaje, -1)
     and coalesce(new.descripcion, '') = coalesce(old.descripcion, '')
     and new.origen = old.origen then
    return new;
  end if;
  if not public.setting_bool(
      new.tenant_id, 'cobranza.ajustes_habilitados', false) then
    raise exception
      'Los ajustes de cuota no están habilitados para esta empresa';
  end if;
  if public.current_user_rol() = 'cobrador' then
    raise exception 'Solo un admin puede aplicar ajustes o promos';
  end if;
  if new.tipo not in ('descuento_monto', 'descuento_porcentaje') then
    raise exception
      'Un ajuste o promo solo puede ser un descuento (monto o porcentaje)';
  end if;
  if new.descripcion is null or btrim(new.descripcion) = '' then
    raise exception 'El descuento requiere un motivo';
  end if;

  v_max_pct := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_porcentaje', 0);
  v_max_monto := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_monto', 0);
  if v_max_pct > 0
     and new.tipo = 'descuento_porcentaje'
     and coalesce(new.porcentaje, 0) > v_max_pct then
    raise exception
      'El descuento excede el tope configurado de % por ciento', v_max_pct;
  end if;
  if v_max_monto > 0 and new.monto > v_max_monto + 0.01 then
    raise exception
      'El descuento excede el tope de C$% configurado', v_max_monto;
  end if;
  -- Limitación documentada (0115, BAJA): el guard NO valida monto ≤ saldo
  -- (carrera offline cobro+descuento puede sobrepagar; el repo lo valida
  -- con su snapshot local e INV4 lo detecta a posteriori).
  return new;
end $$;

drop trigger if exists trg_cargos_ajuste_guard on public.cargos_extra;
create trigger trg_cargos_ajuste_guard
  before insert or update on public.cargos_extra
  for each row
  when (new.origen in ('ajuste', 'promo'))
  execute function public.cargos_ajuste_guard_trg();

-- =========================================================================
-- 2. Motivo obligatorio para descuentos del cobro (manuales del cobrador y
--    automáticos). Scope estricto origen='cobro': NO toca 'liquidacion'
--    (cancelar contrato pone su propia descripcion) ni 'ajuste'/'promo'
--    (guard propio arriba).
-- =========================================================================
create or replace function public.cargos_cobro_motivo_guard_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Mismo passthrough de cascadas/re-upserts que el guard de ajustes: las
  -- filas históricas pre-0117 (descuentos sin motivo del diálogo viejo) no
  -- deben rebotar cuando una cascada las toque sin cambiar lo gobernado.
  if tg_op = 'UPDATE'
     and new.tipo = old.tipo
     and new.monto = old.monto
     and coalesce(new.porcentaje, -1) = coalesce(old.porcentaje, -1)
     and coalesce(new.descripcion, '') = coalesce(old.descripcion, '')
     and new.origen = old.origen then
    return new;
  end if;
  if new.tipo in ('descuento_monto', 'descuento_porcentaje')
     and (new.descripcion is null or btrim(new.descripcion) = '') then
    raise exception 'El descuento del cobro requiere un motivo';
  end if;
  return new;
end $$;

drop trigger if exists trg_cargos_cobro_motivo_guard on public.cargos_extra;
create trigger trg_cargos_cobro_motivo_guard
  before insert or update on public.cargos_extra
  for each row
  when (new.origen = 'cobro')
  execute function public.cargos_cobro_motivo_guard_trg();

-- =========================================================================
-- 3. CONDONACIÓN (audit Fase 4 del rediseño, finding ALTO): una promo o
--    ajuste del 100% dejaba la cuota 'pendiente' con saldo 0 — nunca
--    'pagada' (la regla v_total_pagado <= 0 → 'pendiente' corría primero)
--    y esa cuota BLOQUEABA el orden de cobro del contrato (es la más
--    antigua pendiente y un cobro de C$0 es inválido). Regla nueva, ANTES
--    del resto: total a cobrar <= 0 → 'pagada' (saldada sin plata).
--    Quitar el descuento revierte: el total vuelve a >0 y el recálculo la
--    devuelve a 'pendiente'. ESPEJO EXACTO del cliente
--    (lib/data/utils/cuota_estado.dart) — cambiar uno = cambiar el otro.
--    Cuerpo base: 0083 (guard polimórfico de tg_table_name intacto).
-- =========================================================================
create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  -- Guard polimórfico (lección de 0078, blindado en 0083): operar SOLO
  -- sobre las 2 tablas conocidas, que tienen cuota_id + ocurrido_en.
  if tg_table_name not in ('pagos', 'cargos_extra') then
    return coalesce(new, old);
  end if;

  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);

  if v_total_a_cobrar <= 0 then
    -- Condonada (0117): descuento del 100% → no queda nada que cobrar.
    v_nuevo_estado := 'pagada';
  elsif v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

COMMIT;

-- Verificación post-deploy (correr a mano):
--   select tgname from pg_trigger
--    where tgrelid = 'public.cargos_extra'::regclass
--      and tgname in ('trg_cargos_ajuste_guard',
--                     'trg_cargos_cobro_motivo_guard');          -- 2 filas
--   -- El WHEN del guard de ajustes debe incluir 'promo':
--   select pg_get_triggerdef(oid) from pg_trigger
--    where tgrelid = 'public.cargos_extra'::regclass
--      and tgname = 'trg_cargos_ajuste_guard';  -- ... IN ('ajuste','promo')
--   -- La condonación quedó en la función de recálculo:
--   select prosrc like '%Condonada (0117)%' from pg_proc
--    where proname = 'recalcular_cuota_desde_pagos';             -- true


-- >>> Migration: 0118_serial_baja_transferencias_tardias.sql <<<
-- 0118 — Restricción de transiciones de inv_seriales: baja es terminal, y se bloquean transferencias tardías sobre instalado.
-- M19 — Auto-generación de eventos de ticket en el servidor para evitar eventos huérfanos.

BEGIN;

-- 1. Actualizar la función trg_inv_seriales_guard_transicion para incluir:
--    a) si old.estado = 'baja' y new.estado <> 'baja', error (estado terminal).
--    b) si old.estado = 'instalado' y new.ubicacion_id is distinct from old.ubicacion_id y new.estado <> 'en_stock', error (transferencia tardía).
CREATE OR REPLACE FUNCTION public.inv_seriales_guard_transicion_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- 'baja' es un estado terminal: no se puede salir de 'baja'
  IF OLD.estado = 'baja' AND NEW.estado IS DISTINCT FROM OLD.estado THEN
    RAISE EXCEPTION
      'El equipo % está dado de baja (estado terminal) y no se puede modificar su estado', OLD.serial;
  END IF;

  -- pasar a 'instalado' exige venir de 'en_stock'
  IF NEW.estado = 'instalado'
     AND OLD.estado IS DISTINCT FROM NEW.estado
     AND OLD.estado <> 'en_stock' THEN
    RAISE EXCEPTION
      'El equipo % no está en stock (estado actual: %)', OLD.serial, OLD.estado;
  END IF;

  -- un 'instalado' no cambia de cliente sin pasar por stock
  IF NEW.estado = 'instalado' AND OLD.estado = 'instalado'
     AND NEW.cliente_id IS DISTINCT FROM OLD.cliente_id THEN
    RAISE EXCEPTION
      'El equipo % ya está instalado en otro cliente; devolvelo a stock primero',
      OLD.serial;
  END IF;

  -- si old.estado = 'instalado' y cambia ubicacion_id, exige pasar a 'en_stock' (bloquea transferencias tardías)
  IF OLD.estado = 'instalado'
     AND NEW.ubicacion_id IS DISTINCT FROM OLD.ubicacion_id
     AND NEW.estado <> 'en_stock' THEN
    RAISE EXCEPTION
      'No se puede transferir el equipo % si está instalado (estado actual: %)',
      OLD.serial, OLD.estado;
  END IF;

  RETURN NEW;
END $$;

-- 2. (M19) Auto-generación de ticket_eventos en el servidor.
CREATE OR REPLACE FUNCTION public.tickets_eventos_auto_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cobrador_nombre text;
  v_hecho_por uuid;
BEGIN
  v_hecho_por := COALESCE(auth.uid(), NEW.creado_por);

  IF TG_OP = 'INSERT' THEN
    -- Evento: creado
    INSERT INTO public.ticket_eventos (
      id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
      comentario, hecho_por, ocurrido_en, created_at
    ) VALUES (
      gen_random_uuid(), NEW.tenant_id, NEW.id, 'creado', NULL, NEW.estado,
      NULL, v_hecho_por, NEW.ocurrido_en, NEW.created_at
    );

    -- Evento: asignado (si se crea asignado)
    IF NEW.asignado_a IS NOT NULL THEN
      SELECT nombre INTO v_cobrador_nombre FROM public.cobradores WHERE id = NEW.asignado_a;
      INSERT INTO public.ticket_eventos (
        id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at
      ) VALUES (
        gen_random_uuid(), NEW.tenant_id, NEW.id, 'asignado', 'abierto', NEW.estado,
        'Asignado a ' || COALESCE(v_cobrador_nombre, 'desconocido'), v_hecho_por, NEW.ocurrido_en, NEW.created_at
      );
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Evento: cambio de estado
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
      INSERT INTO public.ticket_eventos (
        id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at
      ) VALUES (
        gen_random_uuid(), NEW.tenant_id, NEW.id,
        CASE NEW.estado
          WHEN 'cancelado' THEN 'cancelado'
          WHEN 'cerrado' THEN 'cerrado'
          WHEN 'reabierto' THEN 'reabierto'
          ELSE 'cambio_estado'
        END,
        OLD.estado, NEW.estado,
        NULL, v_hecho_por, NEW.ocurrido_en, now()
      );
    END IF;

    -- Evento: reasignado
    IF NEW.asignado_a IS DISTINCT FROM OLD.asignado_a THEN
      IF NEW.asignado_a IS NULL THEN
        v_cobrador_nombre := 'Sin asignar';
      ELSE
        SELECT nombre INTO v_cobrador_nombre FROM public.cobradores WHERE id = NEW.asignado_a;
        v_cobrador_nombre := 'Asignado a ' || COALESCE(v_cobrador_nombre, 'desconocido');
      END IF;

      INSERT INTO public.ticket_eventos (
        id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at
      ) VALUES (
        gen_random_uuid(), NEW.tenant_id, NEW.id, 'asignado', OLD.estado, NEW.estado,
        v_cobrador_nombre, v_hecho_por, NEW.ocurrido_en, now()
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tickets_eventos_auto ON public.tickets;
CREATE TRIGGER trg_tickets_eventos_auto
  AFTER INSERT OR UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_eventos_auto_trg();

COMMIT;


-- >>> Migration: 0119_cambio_fecha_pago_por_dias.sql <<<
-- 0119 — Feature C: Cambio de fecha de pago por días (offline-first).
--
-- VISIÓN (decisiones de Rubén, 2026-06-14):
--   El cliente quiere mover su día de pago (ej. del 15 al 30, o al 10). Si está
--   AL DÍA, paga los "días puente" entre su fecha vieja y la nueva (prorrateados
--   = precio_mensual / días reales del mes), con RECIBO en el momento. A partir
--   de ahí su calendario corre en el día nuevo. El personal habilitado lo hace
--   desde un botón al lado de "Pagar" (lista de cobros + mapa), en CAMPO, OFFLINE.
--
-- GATING de 2 niveles:
--   (1) Por TENANT: el super_admin activa la feature (setting super-only
--       'cobranza.cambio_fecha_habilitado'). Es excepcional.
--   (2) Por USUARIO: el admin habilita a cobradores/admin_cobranza específicos
--       (columna cobradores.puede_cambiar_fecha). El rol 'admin' siempre puede
--       (con la feature ON). Sin flujo de aprobación extra: el personal habilitado
--       = capacitado.
--
-- MODELO (Diseño A, decisión de Rubén 2026-06-14; re-anclaje orquestado por el
--   CLIENTE como cambios de filas que sincronizan; el server NO necesita un RPC):
--   - Cargo PUENTE = un cargos_extra (origen='puente', tipo='otro' → SUMA) sobre
--     la ÚLTIMA cuota pagada del contrato (host: cargos_extra.cuota_id es NOT NULL
--     y una cuota anulada no puede alojar el pago). Se cobra al instante → genera
--     pago + recibo con la línea "Puente de pago". Entra a RECAUDADO; NO infla el
--     total fijo (precio × meses) — es ingreso extra, como una reconexión
--     (invariantes #9/#10 intactos).
--   - La/s cuota/s pendiente/s que caen DENTRO de la ventana del puente quedan
--     ABSORBIDAS (anuladas, sin pago = sin deuda); el primer pago completo pasa al
--     día nuevo. Salto corto que no cruza de mes → 0 absorbidas (solo se corre el
--     vencimiento); salto que cruza de mes → se absorbe la cuota de ese mes.
--   - Las cuotas futuras pendientes se mueven al día nuevo: lo hace AUTOMÁTICO el
--     trigger contratos_actualizar_cuotas_futuras_trg (0018) al UPDATE de dia_pago
--     (fecha_vencimiento = calcular_fecha_pago(periodo, dia_pago_nuevo)). El cliente
--     lo espeja local (port Dart de calcular_fecha_pago) para verlo offline al instante.
--   - Contratos de plazo fijo: el cliente agrega 1 cuota de cierre al final (período
--     libre, día nuevo) por cada absorbida → conserva el conteo ACTIVO en
--     duracion_meses (total fijo intacto) → el servicio termina unos días después.
--     Indefinidos: solo se re-ancla el cushion. INV11 (invariantes_dinero.sql) cuenta
--     solo cuotas NO anuladas para no marcar la absorbida + cierre como sobre-generación.
--
-- OFFLINE: como el cobrador opera sin internet, NO se puede usar un RPC server.
--   Los writes ocurren LOCAL (PowerSync) y suben vía RLS. Por eso esta migración
--   EXTIENDE la RLS de contratos/cuotas para permitir esos writes SOLO al personal
--   habilitado y SOLO sobre SUS PROPIOS contratos/cuotas, y RELAJA el guard
--   cuotas_check_cobrador_update (0111/0022) para que el personal habilitado pueda
--   re-fechar (fecha_vencimiento) y absorber (anular) — ver bloques 5 y 6. ⚠ Cambio
--   de acceso sensible — revisar en el audit de seguridad (Fase 4).
--
-- cargos_extra.origen tenía CHECK cerrado (0115) → este archivo lo EXTIENDE con
--   'puente' (bloque 5). El label legible y la línea del recibo se mapean en el cliente.
--
-- POST-DEPLOY: bump schema.dart (cobradores.puede_cambiar_fecha) + _schemaVersion
--   27→28 + redeploy sync rules (la columna se agregó a los SELECT de cobradores).

-- =========================================================================
-- 1. Permiso por usuario (lo habilita el admin a cobradores/admin_cobranza)
-- =========================================================================
alter table public.cobradores
  add column if not exists puede_cambiar_fecha boolean not null default false;

-- =========================================================================
-- 2. Setting super-only por tenant: feature habilitada (patrón 0085/0086).
--    Se agrega la clave nueva a seed_settings_super_only y se re-siembra.
-- =========================================================================
create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.cambio_fecha_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite el cambio de fecha de pago por días (personal habilitado por el admin)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;

-- =========================================================================
-- 3. Helper: ¿el usuario actual puede cambiar fecha de pago?
--    feature ON (tenant) AND (rol admin OR permiso por usuario).
-- =========================================================================
create or replace function public.puede_cambiar_fecha_pago()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce((
      -- settings.valor es TEXT (0011 lo migró de jsonb a text serializado para
      -- el cliente SQLite); el cliente lo escribe con jsonEncode(bool) → 'true'
      -- /'false'. Comparar como texto (no como jsonb).
      select s.valor = 'true'
        from public.settings s
       where s.tenant_id = public.current_tenant_id()
         and s.clave = 'cobranza.cambio_fecha_habilitado'
    ), false)
    and coalesce((
      select (c.rol = 'admin' or c.puede_cambiar_fecha)
        from public.cobradores c
       where c.id = auth.uid()
    ), false);
$$;

-- =========================================================================
-- 4. RLS: permitir al personal habilitado los writes del cambio de fecha,
--    SOLO sobre SUS PROPIOS contratos/cuotas (cobrador_id = auth.uid()).
--    Los admins/admin_cobranza ya están cubiertos por *_write_admins (0013).
--    Estas policies SUMAN acceso (permissive OR), gateado por la feature+permiso.
-- =========================================================================

-- contratos: UPDATE (dia_pago / fecha_fin) del re-anclaje.
drop policy if exists "contratos_cambiar_fecha" on public.contratos;
create policy "contratos_cambiar_fecha" on public.contratos
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- cuotas: INSERT (cuota de cierre en fijos). Exige que el contrato sea del
-- propio cobrador (patrón endurecido de 0022: el cobrador setea cobrador_id en
-- su propia fila, así que sin el EXISTS podría insertar contra contratos ajenos).
drop policy if exists "cuotas_cambiar_fecha_insert" on public.cuotas;
create policy "cuotas_cambiar_fecha_insert" on public.cuotas
  for insert
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
    and exists (
      select 1 from public.contratos c
       where c.id = cuotas.contrato_id
         and c.cobrador_id = auth.uid()
         and c.tenant_id = public.current_tenant_id()
    )
  );

-- cuotas: UPDATE (anular la cuota absorbida; el día de las futuras lo mueve el
-- trigger 0018 como SECURITY DEFINER). NO se habilita DELETE.
drop policy if exists "cuotas_cambiar_fecha_update" on public.cuotas;
create policy "cuotas_cambiar_fecha_update" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- NOTA: pagos/recibos ya permiten al cobrador insertar los suyos (0013), así que
-- el cobro del puente + su recibo no requieren policy nueva.

-- =========================================================================
-- 5. Extender el CHECK de cargos_extra.origen para admitir 'puente' (Diseño A).
--    El cargo puente es un cargos_extra origen='puente' tipo='otro' (SUMA) sobre
--    la última cuota pagada. El CHECK de 0115 es inline (nombre autogenerado) →
--    lo ubicamos por pg_constraint y lo reemplazamos por uno con nombre estable.
-- =========================================================================
do $$
declare
  v_con text;
begin
  select c.conname into v_con
    from pg_constraint c
   where c.conrelid = 'public.cargos_extra'::regclass
     and c.contype = 'c'
     and pg_get_constraintdef(c.oid) ilike '%origen%'
     and pg_get_constraintdef(c.oid) ilike '%cobro%'
   limit 1;
  if v_con is not null then
    execute format('alter table public.cargos_extra drop constraint %I', v_con);
  end if;
end $$;

alter table public.cargos_extra
  add constraint cargos_extra_origen_check
  check (origen in ('cobro', 'ajuste', 'promo', 'liquidacion', 'puente'));

-- =========================================================================
-- 6. Relajar el guard cuotas_check_cobrador_update (0111/0022) para el personal
--    habilitado: necesita RE-FECHAR (fecha_vencimiento) las futuras y ABSORBER
--    (anular con metadata) la/s cuota/s del puente, OFFLINE, sobre SUS cuotas.
--    Sigue PROHIBIDO para el cobrador: des-anular (reactivar) y los cambios
--    estructurales (monto/contrato/cliente/cobrador/periodo/tenant).
--    ⚠ Cambio de acceso sensible (Fase 4 seguridad): un cobrador habilitado
--    puede anular/re-fechar SUS cuotas sin aprobación extra (modelo "habilitado
--    = capacitado"). El gating feature+permiso (puede_cambiar_fecha_pago()) y el
--    scope cobrador_id=auth.uid() de las policies 0119 lo acotan.
-- =========================================================================
create or replace function public.cuotas_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if public.puede_cambiar_fecha_pago() then
      -- Personal habilitado (feature C): puede re-fechar (fecha_vencimiento) y
      -- ABSORBER (anular) SOLO SUS PROPIAS cuotas, y la anulación SOLO con el
      -- marcador del flujo legítimo. Necesario porque la policy permissive
      -- cuotas_update_cobrador_propio (0025) NO scopea por dueño (confía en este
      -- guard) y las permissive se unen con OR → sin esto un cobrador habilitado
      -- podría anular por API cuotas pendientes de otros clientes del tenant.
      if new.cobrador_id is distinct from auth.uid()
         or old.cobrador_id is distinct from auth.uid()
      then
        raise exception 'cobrador solo puede cambiar la fecha de SUS propias cuotas';
      end if;
      -- Sigue bloqueado: cambios estructurales y des-anular.
      if new.monto         is distinct from old.monto         or
         new.contrato_id   is distinct from old.contrato_id   or
         new.cliente_id    is distinct from old.cliente_id    or
         new.cobrador_id   is distinct from old.cobrador_id   or
         new.periodo       is distinct from old.periodo       or
         new.tenant_id     is distinct from old.tenant_id     or
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede cambiar monto/contrato/periodo ni reactivar cuotas anuladas';
      end if;
      -- Anular SOLO por el flujo de cambio de fecha (marcador del motivo): una
      -- anulación arbitraria por el cobrador (borrar deuda) sigue prohibida.
      if new.estado <> old.estado and new.estado = 'anulada'
         and coalesce(new.motivo_anulacion, '') <> 'Absorbida por cambio de fecha de pago'
      then
        raise exception 'cobrador solo puede anular cuotas por cambio de fecha de pago';
      end if;
    else
      -- Guard original (sin la feature de cambio de fecha habilitada).
      if new.monto         is distinct from old.monto         or
         new.contrato_id   is distinct from old.contrato_id   or
         new.cliente_id    is distinct from old.cliente_id    or
         new.cobrador_id   is distinct from old.cobrador_id   or
         new.periodo       is distinct from old.periodo       or
         new.fecha_vencimiento is distinct from old.fecha_vencimiento or
         new.tenant_id     is distinct from old.tenant_id     or
         new.anulada_en    is distinct from old.anulada_en    or
         new.anulada_por   is distinct from old.anulada_por   or
         new.motivo_anulacion is distinct from old.motivo_anulacion or
         -- No puede anular...
         (new.estado <> old.estado and new.estado = 'anulada') or
         -- ...ni des-anular (reactivar) una cuota ya anulada.
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede anular ni reactivar cuotas; sólo monto_pagado y transiciones de cobro';
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- =========================================================================
-- 7. Guard BEFORE UPDATE en contratos: el rol cobrador (que ahora tiene UPDATE
--    vía contratos_cambiar_fecha, bloque 4) SOLO puede tocar dia_pago y fecha_fin
--    del re-anclaje; todo lo demás, congelado. Sin esto la policy daría UPDATE de
--    TODAS las columnas: un PATCH directo de fecha_fin hacia ATRÁS dispara
--    limpiar_cuotas_excedentes (0023, SECURITY DEFINER) que BORRA cuotas
--    pendientes (deuda); cambiar plan_id/duracion_meses rompería el total fijo
--    (#5); estado='cancelado' cancelaría el contrato. admins/admin_cobranza no
--    pasan por este if (su rol no es 'cobrador'). ⚠ Acceso sensible — Fase 4.
-- =========================================================================
create or replace function public.contratos_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.current_user_rol() = 'cobrador' then
    if new.cliente_id     is distinct from old.cliente_id     or
       new.cobrador_id    is distinct from old.cobrador_id    or
       new.tenant_id      is distinct from old.tenant_id      or
       new.plan_id        is distinct from old.plan_id        or
       new.duracion_meses is distinct from old.duracion_meses or
       new.fecha_inicio   is distinct from old.fecha_inicio   or
       new.estado         is distinct from old.estado         or
       new.codigo         is distinct from old.codigo         or
       new.fecha_primer_cobro is distinct from old.fecha_primer_cobro or
       new.costo_instalacion  is distinct from old.costo_instalacion
    then
      raise exception 'cobrador solo puede cambiar dia_pago/fecha_fin (cambio de fecha de pago)';
    end if;
    -- fecha_fin SOLO hacia adelante: acortarla dispara el DELETE de
    -- limpiar_cuotas_excedentes (0023) = borrado de deuda.
    if new.fecha_fin is distinct from old.fecha_fin
       and old.fecha_fin is not null
       and new.fecha_fin < old.fecha_fin
    then
      raise exception 'cobrador no puede acortar fecha_fin';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_contratos_check_cobrador_update on public.contratos;
create trigger trg_contratos_check_cobrador_update
  before update on public.contratos
  for each row execute function public.contratos_check_cobrador_update();


-- >>> Migration: 0120_suspension_temporal_contrato.sql <<<
-- 0120: Suspensión temporal de contrato (Feature A).
--
-- Permite a admin / admin_cobranza PAUSAR un contrato: estado='suspendido'.
-- El cron `generar_cuotas_mensual` y `generar_cuotas_contrato` (0074) ya gatean
-- por estado='activo' → al suspender, dejan de generar cuotas SOLOS (pausa
-- gratis). La transacción del cliente (offline-first) hace el resto:
--   - SUSPENDER: anula las cuotas futuras pendientes del período + prorratea la
--     del mes en curso (fijos) / solo pausa (indefinidos), e inserta una fila en
--     `contrato_suspensiones` (motivo + notas + snapshot de deuda).
--   - REACTIVAR: estado='activo', re-ancla `dia_pago` a la fecha de reactivación
--     y regenera cuotas hasta el mes ORIGINAL de `fecha_fin` (sin estirar); cierra
--     la fila (reactivado_en/por). NO cobra puente (lo suspendido no se factura).
-- El PDF de deuda se genera on-demand del `deuda_snapshot` (offline, reimprimible).
-- Decisiones cerradas (Rubén 2026-06-15): no se cobra el período suspendido,
-- el contrato termina en el mismo mes, solo se suspende a futuro (lo pagado no se
-- toca), solo admin/admin_cobranza. schema v28 → v29.

BEGIN;

-- 1) contratos.estado: agregar 'suspendido'. Hoy NO hay CHECK (0052 lo dejó
--    libre); lo creamos con nombre estable e idempotente.
ALTER TABLE public.contratos DROP CONSTRAINT IF EXISTS contratos_estado_check;
ALTER TABLE public.contratos
  ADD CONSTRAINT contratos_estado_check
  CHECK (estado IN ('activo', 'suspendido', 'completado', 'cancelado'));

-- 2) Tabla de historial de suspensiones (Receta R10). Append-only salvo el
--    UPDATE de cierre al reactivar (reactivado_en/por). `deuda_snapshot` = JSON
--    (texto) de las cuotas pendientes al momento de suspender, para reimprimir
--    el PDF sin re-calcular. Sin denormalizar cobrador_id (es hija de contratos).
CREATE TABLE IF NOT EXISTS public.contrato_suspensiones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  contrato_id uuid NOT NULL REFERENCES public.contratos(id) ON DELETE CASCADE,
  motivo text NOT NULL,
  notas text,                                      -- nota libre opcional del porqué
  deuda_snapshot text,                             -- JSON: cuotas pendientes + total al suspender
  suspendido_en timestamptz NOT NULL DEFAULT now(),
  suspendido_por uuid REFERENCES public.cobradores(id),
  reactivado_en timestamptz,                       -- NULL = suspensión vigente
  reactivado_por uuid REFERENCES public.cobradores(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL DEFAULT now()   -- device-time (offline/audit)
);
CREATE INDEX IF NOT EXISTS contrato_suspensiones_by_contrato
  ON public.contrato_suspensiones (tenant_id, contrato_id);

-- RLS: read = miembro del tenant; write = admin/admin_cobranza; super_admin A MANO.
ALTER TABLE public.contrato_suspensiones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "susp_read"  ON public.contrato_suspensiones;
DROP POLICY IF EXISTS "susp_write" ON public.contrato_suspensiones;
DROP POLICY IF EXISTS "super_admin_all" ON public.contrato_suspensiones;
CREATE POLICY "susp_read" ON public.contrato_suspensiones FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "susp_write" ON public.contrato_suspensiones FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.contrato_suspensiones
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Audit del change-log (genérico AFTER I/U/D, guard de profundidad).
DROP TRIGGER IF EXISTS trg_changelog_contrato_suspensiones ON public.contrato_suspensiones;
CREATE TRIGGER trg_changelog_contrato_suspensiones
  AFTER INSERT OR UPDATE OR DELETE ON public.contrato_suspensiones
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

COMMIT;


-- >>> Migration: 0121_p3b_permitir_sin_cobrador.sql <<<
-- 0121_p3b_permitir_sin_cobrador.sql
-- P3b (decisión Rubén 2026-06-17): un cliente —INCLUSO con contratos— puede
-- quedar SIN cobrador. Sus cuotas quedan con cobrador_id NULL → el bucket
-- por_cobrador NO las baja, así que SOLO admin/admin_cobranza las ven, filtran
-- y cobran (bajan el bucket del tenant completo). La deuda NO se pierde: queda
-- admin-managed hasta asignar un cobrador (pantalla Rutas o por cliente, que
-- propaga cobrador_id a las cuotas vía trigger 0068).
--
-- Relaja dos guards que asumían "cliente siempre con cobrador":
--   - 0058  trg_clientes_check_cobrador_no_null  (BEFORE UPDATE clientes):
--           bloqueaba poner cobrador_id = NULL si había contratos activos.
--   - 0025  trg_contratos_check_cliente_con_cobrador (BEFORE INSERT contratos):
--           bloqueaba crear un contrato si el cliente no tenía cobrador.
--
-- Se eliminan los TRIGGERS (las funciones quedan por si se quisieran reactivar).
-- No toca schema del cliente ni sync rules (sin bump de versión). No toca
-- dinero: las cuotas sin cobrador siguen contando para recaudado/saldo, solo
-- cambia QUIÉN las ve/cobra (admin, no el cobrador de campo).

DROP TRIGGER IF EXISTS trg_clientes_check_cobrador_no_null ON public.clientes;
DROP TRIGGER IF EXISTS trg_contratos_check_cliente_con_cobrador ON public.contratos;


-- >>> Migration: 0122_etiquetas_clientes.sql <<<
-- 0122: Módulo de Etiquetas personalizables para clientes (P5).
--
-- Feature CORE (NO gateada por tenant_modulos): todos los tenants la tienen.
-- Dos tablas (R10 ×2):
--   - etiquetas: catálogo por tenant (nombre + color hex + icono clave).
--     CRUD del admin/admin_cobranza desde Ajustes.
--   - cliente_etiquetas: relación M2M cliente↔etiqueta. ASIGNAR/QUITAR solo
--     admin/admin_cobranza (decisión P5); el cobrador la LEE (sus clientes).
--
-- Sync al cobrador: el bucket por_cobrador filtra por cobrador_id, así que
-- cliente_etiquetas DENORMALIZA cobrador_id (igual que cuotas/fotos_cliente,
-- 0055/0068). BEFORE INSERT lo copia del cliente; la cascada consolidada de
-- reasignación (propagate_cobrador_id_from_cliente, 0068) lo mantiene al
-- mover el cliente de cobrador. NULL = cliente admin-managed sin cobrador
-- (P3b) → no baja a ningún cobrador.

-- =========================================================================
-- 1. Tablas
-- =========================================================================
CREATE TABLE public.etiquetas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  color text NOT NULL,                 -- hex "#RRGGBB"
  icono text NOT NULL,                 -- clave del icono (mapeada en Dart)
  orden int NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz,             -- device-time UTC (audit offline)
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.cliente_etiquetas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  etiqueta_id uuid NOT NULL REFERENCES public.etiquetas(id) ON DELETE CASCADE,
  -- Denormalizado para el bucket por_cobrador. Lo setea el BEFORE INSERT y lo
  -- mantiene la cascada de reasignación. NULL = sin cobrador (admin-managed).
  cobrador_id uuid REFERENCES public.cobradores(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz,
  UNIQUE (tenant_id, cliente_id, etiqueta_id)
);

CREATE INDEX cliente_etiquetas_by_cliente
  ON public.cliente_etiquetas (tenant_id, cliente_id);
CREATE INDEX cliente_etiquetas_by_etiqueta
  ON public.cliente_etiquetas (tenant_id, etiqueta_id);
CREATE INDEX cliente_etiquetas_by_cobrador
  ON public.cliente_etiquetas (tenant_id, cobrador_id);

-- =========================================================================
-- 2. Denormalización de cobrador_id (para sync rules del cobrador)
-- =========================================================================
-- 2a. Al asignar una etiqueta, copiar el cobrador_id actual del cliente.
CREATE OR REPLACE FUNCTION public.cliente_etiquetas_set_cobrador_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.cobrador_id := (
    SELECT cobrador_id FROM public.clientes WHERE id = NEW.cliente_id
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cliente_etiquetas_set_cobrador
  BEFORE INSERT ON public.cliente_etiquetas
  FOR EACH ROW EXECUTE FUNCTION public.cliente_etiquetas_set_cobrador_trg();

-- 2b. Extender la cascada consolidada (0068): al reasignar el cliente,
-- actualizar el cobrador_id de sus etiquetas. CREATE OR REPLACE reemplaza la
-- función entera → se reproduce el cuerpo vigente (0068) + el bloque nuevo.
CREATE OR REPLACE FUNCTION public.propagate_cobrador_id_from_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.cobrador_id IS DISTINCT FROM OLD.cobrador_id THEN
    UPDATE public.contratos
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- Solo cuotas operativas. Las pagadas/anuladas preservan el cobrador_id
    -- del momento del pago (historial inmutable).
    UPDATE public.cuotas
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND estado IN ('pendiente','parcial');

    UPDATE public.notificaciones_mora
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND resuelta_en IS NULL;

    UPDATE public.cargos_extra
       SET cobrador_id = NEW.cobrador_id
     WHERE cuota_id IN (
       SELECT id FROM public.cuotas
        WHERE cliente_id = NEW.id
          AND estado IN ('pendiente','parcial')
     );

    UPDATE public.fotos_cliente
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- cliente_etiquetas (P5): organizativo, sigue al cliente.
    UPDATE public.cliente_etiquetas
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- pagos / recibos NO se propagan: snapshot histórico inmutable.
  END IF;
  RETURN NEW;
END;
$$;

-- =========================================================================
-- 3. RLS — read: miembro del tenant (el cobrador ve las de sus clientes vía
--    sync rules); write: admin/admin_cobranza; super_admin_all a mano.
-- =========================================================================
ALTER TABLE public.etiquetas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cliente_etiquetas ENABLE ROW LEVEL SECURITY;

-- etiquetas (catálogo: read/insert/update/delete del admin)
CREATE POLICY "etiquetas_read" ON public.etiquetas
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "etiquetas_insert" ON public.etiquetas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "etiquetas_update" ON public.etiquetas
  FOR UPDATE USING (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "etiquetas_delete" ON public.etiquetas
  FOR DELETE USING (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.etiquetas
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- cliente_etiquetas (M2M: read de todos; assign/unassign = insert/delete del
-- admin. No hay UPDATE de usuario — cobrador_id lo mueve la cascada DEFINER).
CREATE POLICY "cliente_etiquetas_read" ON public.cliente_etiquetas
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "cliente_etiquetas_insert" ON public.cliente_etiquetas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "cliente_etiquetas_delete" ON public.cliente_etiquetas
  FOR DELETE USING (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.cliente_etiquetas
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 4. Audit log (trigger genérico, guard de profundidad < 2: las updates de
--    cobrador_id por cascada NO se loguean, igual que en cuotas)
-- =========================================================================
CREATE TRIGGER trg_changelog_etiquetas
  AFTER INSERT OR UPDATE OR DELETE ON public.etiquetas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_cliente_etiquetas
  AFTER INSERT OR UPDATE OR DELETE ON public.cliente_etiquetas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();


-- >>> Migration: 0123_cancelacion_dinamica_suspension.sql <<<
-- 0123: Cancelar contrato con la MISMA dinámica de dinero que suspender, pero
-- PERMANENTE (sin reactivación). El cancelar viejo anulaba TODA la deuda y
-- liquidaba parciales a 0; ahora deja viva/cobrable la deuda real (meses
-- cumplidos + mora previa), prorratea el mes en curso por ventana de servicio
-- del día_pago y anula solo los meses futuros (igual que suspender). La lógica
-- vive en ContratosRepo.cancelarContrato (espeja suspenderContrato).
--
-- Esta migración solo agrega a `contratos` las columnas para registrar la
-- cancelación + el snapshot de deuda (para reimprimir el documento, como hace
-- contrato_suspensiones). NO nueva tabla: `contratos` ya tiene RLS y ya
-- sincroniza (los buckets usan SELECT * → las columnas bajan solas). El estado
-- 'cancelado' ya está permitido por el CHECK de contratos.

ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS cancelado_en timestamptz,
  ADD COLUMN IF NOT EXISTS cancelado_por uuid REFERENCES public.cobradores(id),
  ADD COLUMN IF NOT EXISTS motivo_cancelacion text,
  ADD COLUMN IF NOT EXISTS cancelacion_deuda_snapshot jsonb;


-- >>> Migration: 0124_mora_excluye_contratos_no_activos.sql <<<
-- 0124: el cron de mora NO debe generar notificaciones para cuotas de
-- contratos NO activos. Un contrato suspendido —o, con el nuevo cancelar
-- (0123), cancelado— deja cuotas vivas pendientes/parciales; el cron las
-- tomaba a diario y el badge de mora del cobrador las contaba, PERO la lista
-- de Cobros/mora y el mapa las excluyen (filtran estado='activo') → badge
-- fantasma que no baja desde su pantalla. Fix: filtrar por estado de contrato
-- = 'activo' en el INSERT, alineando suspendido y cancelado con Cobros/mapa
-- (la deuda de esos contratos se cobra desde el detalle del contrato).
-- Solo reescribe la función; sin cambio de schema. Detectado por el audit
-- adversarial del feature de cancelación.

create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
set timezone = 'America/Managua'
as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- row_security off: el cron corre sin auth.uid(); SECURITY DEFINER da rol
  -- postgres (BYPASSRLS), lo explicitamos por las dudas.
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
    cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
    -- Solo contratos ACTIVOS (0124): suspendido/cancelado salen del flujo de
    -- mora del cobrador aunque conserven cuotas vivas.
    and coalesce(
          (select ct.estado from public.contratos ct where ct.id = cu.contrato_id),
          'activo') = 'activo'
  on conflict (cuota_id) do update
    set dias_mora      = excluded.dias_mora,
        monto_adeudado = excluded.monto_adeudado;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;


-- >>> Migration: 0125_registrar_visitas_super_only.sql <<<
-- 0125 — Registrar visitas → super_admin-only (por tenant), default OFF.
--
-- P5: la pestaña "Visitas" del detalle del cliente (botón "Registrar visita" +
-- historial) ahora es OPCIONAL y arranca OCULTA. El super_admin la habilita por
-- tenant desde la tab "Avanzado" de Settings, mismo patrón que pantalla de pagos
-- / auditoría (0085/0086/0089). El cliente lee `cobranza.registrar_visitas`
-- (default false en settings_repo) → con OFF la pestaña no aparece.
--
-- Extiende seed_settings_super_only (0085/0086/0089) con la clave nueva. La RLS
-- de 0085 (settings_write_admin con editable_por <> 'super_admin') ya impide
-- server-side que el admin la escriba.
--
-- Sin columnas nuevas → sin bump de schema.dart ni redeploy de sync rules
-- (settings ya sincroniza con SELECT *).

create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    -- Foto de comprobante + pantallas opcionales (0085).
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    -- Descuentos (manual en campo) → super-only (0086).
    (p_tenant_id, 'cobranza.descuentos_habilitados', 'false'::jsonb, 'boolean',
     'cobranza', 'Permitir aplicar descuentos en campo', 'super_admin'),
    (p_tenant_id, 'cobranza.descuento_tipo', '"monto"'::jsonb, 'string',
     'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_porcentaje', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)',
     'super_admin'),
    -- Reconexión → super-only (0086).
    (p_tenant_id, 'cobranza.cargo_reconexion_habilitado', 'false'::jsonb,
     'boolean', 'cobranza', 'Permitir cobrar reconexión', 'super_admin'),
    (p_tenant_id, 'cobranza.monto_reconexion', '0'::jsonb, 'number',
     'cobranza', 'Monto de reconexión en C$', 'super_admin'),
    -- Visibilidad del panel de Auditoría para el admin → super-only (0089).
    (p_tenant_id, 'cobranza.audit_visible_admin', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra el panel de Auditoría (historial de cambios) al admin del tenant',
     'super_admin'),
    -- Registro de visitas → super-only (0125), default OFF.
    (p_tenant_id, 'cobranza.registrar_visitas', 'false'::jsonb, 'boolean',
     'cobranza',
     'Habilita la pestaña Visitas en el detalle del cliente (registrar visita + historial)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- Aplicar a todos los tenants existentes: siembra la clave nueva (los demás ya
-- existen; el ON CONFLICT preserva su `valor` y sólo reafirma editable_por).
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;


-- >>> Migration: 0126_cancelacion_snapshot_a_text.sql <<<
-- 0126 — cancelacion_deuda_snapshot: jsonb → text (consistencia con deuda_snapshot).
--
-- 0123 creó la columna como `jsonb`. El cliente (offline-first) guarda un STRING ya
-- codificado con jsonEncode; al sincronizar vía PowerSync/PostgREST ese string entra al
-- jsonb como STRING SCALAR y vuelve DOBLE-codificado ("{...}") → en el cliente
-- jsonDecode daba un String, no un Map, y el revert/PDF/tarjeta de cancelación fallaban
-- (type 'String' is not a subtype of type 'Map'). El `deuda_snapshot` de suspensión
-- (0120) es `text` y NO sufre esto.
--
-- Fix raíz: pasar la columna a `text` (igual que deuda_snapshot) y des-doble-codificar
-- las filas existentes (`#>> '{}'` extrae el string interno de un jsonb string-scalar).
-- Los writes futuros del cliente quedan single-encoded. El cliente además trae un decode
-- robusto (decodeSnapshotMap) que tolera ambos formatos → esta migración es de
-- CONSISTENCIA: la app YA funciona con el decode robusto, pero esto evita el footgun de
-- que cualquier lectura futura tenga que acordarse de des-doble-codificar.
--
-- Sin cambio de schema.dart (ya es Column.text) ni de sync rules (SELECT *).

ALTER TABLE public.contratos
  ALTER COLUMN cancelacion_deuda_snapshot TYPE text
  USING (
    CASE
      WHEN cancelacion_deuda_snapshot IS NULL THEN NULL
      WHEN jsonb_typeof(cancelacion_deuda_snapshot) = 'string'
        THEN cancelacion_deuda_snapshot #>> '{}'
      ELSE cancelacion_deuda_snapshot::text
    END
  );


-- >>> Migration: 0127_saldos_favor_credito_excedente.sql <<<
-- 0127 — Crédito por excedente al suspender / cancelar (saldos a favor).
--
-- QUÉ: cuando un cliente pagó por adelantado servicio que NO se va a prestar
-- (suspensión/cancelación con cuotas pagadas a futuro o el sobre-pago del mes
-- en curso), el admin/admin_cobranza decide qué hacer con ese EXCEDENTE:
--   · ACREDITAR  → queda como saldo a favor del CLIENTE (cualquier contrato suyo).
--   · DEVOLVER   → se le devuelve en efectivo (recibo de devolución; sale de caja).
--   · CONDONAR   → el cliente cede el saldo (queda en caja, pero AUDITADO).
-- El saldo a favor NO caduca. Lo decide admin/admin_cobranza; el cobrador no.
-- Gateado por setting super-only `cobranza.credito_excedente` (default ON);
-- en OFF la suspensión/cancelación se comportan como antes (excedente perdido).
--
-- DECISIÓN DE MODELO (validación adversarial, ver BITACORA 2026-06-18):
--   El crédito NO es un `pago`. Modelarlo como pago (metodo='credito') rompía
--   ~15 agregados de caja y 5+ invariantes. En su lugar:
--     - El crédito vive en la tabla nueva `saldos_favor` (libro append-only).
--     - APLICARLO a una cuota = un `cargos_extra` origen='credito'
--       tipo='credito_aplicado' (RESTA del saldo canónico, igual que un
--       descuento) → NO toca `pagos`, NO infla recaudado ni arqueo.
--   Invariante #4 se PARTE en dos (ver AGENTS.md):
--     recaudado_caja = SUM(pagos no anulados) − SUM(saldos_favor devuelto)
--     cobertura_cuota = monto + cargos_neto − monto_pagado (fórmula canónica).
--
-- R10: tabla nueva con tenant_id + RLS + super_admin_all A MANO + audit +
-- schema.dart + bump _schemaVersion + sync rules. Append-only (sin UPDATE/DELETE
-- para usuarios del tenant; "deshacer" = fila nueva tipo='revertido').

-- =========================================================================
-- 1. Tabla saldos_favor (libro append-only de movimientos de crédito)
-- =========================================================================
-- saldo_disponible(cliente) = SUM(+acreditado) − SUM(aplicado+devuelto+
--   condonado+revertido). TODA disposición arranca con una fila 'acreditado';
--   devolver/condonar agregan su fila que la neutraliza (net 0); acreditar la
--   deja parada hasta que se aplique (o se revierta/devuelva después).
CREATE TABLE public.saldos_favor (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  contrato_id uuid NOT NULL REFERENCES public.contratos(id) ON DELETE CASCADE,

  -- 'acreditado' (origen, +) / 'aplicado' (a una cuota, −) / 'devuelto' (efectivo
  -- a caja, −) / 'condonado' (cede, −) / 'revertido' (deshacer acreditación, −).
  tipo text NOT NULL CHECK (tipo IN
    ('acreditado','aplicado','devuelto','condonado','revertido')),
  -- Siempre POSITIVO; el signo lo da el tipo.
  monto numeric(12,2) NOT NULL CHECK (monto >= 0),

  -- Trazabilidad (A6/A8 de la validación: revert-aware + anti doble-acreditación).
  cuota_id uuid REFERENCES public.cuotas(id) ON DELETE SET NULL,        -- origen (acreditado) o destino (aplicado)
  origen_evento_id uuid,                                                -- FK lógica a contrato_suspensiones.id (suspensión); NULL en cancelación
  cargo_id uuid REFERENCES public.cargos_extra(id) ON DELETE SET NULL,  -- el cargos_extra creado al APLICAR
  recibo_id uuid REFERENCES public.recibos(id) ON DELETE SET NULL,      -- recibo de devolución (solo tipo='devuelto')

  -- Solo tipo='devuelto': a qué caja/cobrador se resta y EN QUÉ DÍA (local-naive
  -- Nicaragua, análogo a pagos.fecha_pago — el arqueo bucketea por acá, NUNCA
  -- por ocurrido_en UTC, ver regla 1b de AGENTS.md / hallazgo A3).
  cobrador_id uuid REFERENCES public.cobradores(id),
  fecha_devolucion date,

  motivo text,
  creado_por uuid NOT NULL REFERENCES public.cobradores(id),
  ocurrido_en timestamptz NOT NULL,                 -- device-time UTC (.toUtc()) — audit, NO para bucketing de caja
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX saldos_favor_by_cliente ON public.saldos_favor (tenant_id, cliente_id);
CREATE INDEX saldos_favor_by_evento  ON public.saldos_favor (origen_evento_id);
CREATE INDEX saldos_favor_by_cuota   ON public.saldos_favor (cuota_id);
CREATE INDEX saldos_favor_devueltos  ON public.saldos_favor (tenant_id, cobrador_id, fecha_devolucion)
  WHERE tipo = 'devuelto';

-- =========================================================================
-- 2. Helper: saldo a favor DISPONIBLE de un cliente (todos sus contratos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.saldo_favor_disponible(p_cliente_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(
    CASE WHEN tipo = 'acreditado' THEN monto ELSE -monto END
  ), 0)::numeric
  FROM public.saldos_favor
  WHERE cliente_id = p_cliente_id;
$$;

-- =========================================================================
-- 3. Trigger anti-sobregiro (A5: "server gana" ante carrera offline)
-- =========================================================================
-- Dos dispositivos podrían aplicar/devolver el mismo crédito antes de
-- sincronizar → saldo_disponible < 0 = el ISP regala plata. El server rechaza
-- la segunda. El cliente espeja optimista; el rechazo rebota por sync.
CREATE OR REPLACE FUNCTION public.saldos_favor_no_sobregiro_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Solo los movimientos que RESTAN pueden sobregirar. 'acreditado' suma.
  IF NEW.tipo IN ('aplicado','devuelto','condonado','revertido') THEN
    -- saldo_favor_disponible aún NO ve a NEW (BEFORE INSERT): es el disponible
    -- previo. Dentro de la misma transacción ya ve las filas insertadas antes
    -- (p.ej. el 'acreditado' que precede a un 'devuelto'/'condonado').
    IF public.saldo_favor_disponible(NEW.cliente_id) < NEW.monto - 0.005 THEN
      RAISE EXCEPTION
        'Saldo a favor insuficiente: disponible %, intentó % (cliente %)',
        public.saldo_favor_disponible(NEW.cliente_id), NEW.monto, NEW.cliente_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_saldos_favor_no_sobregiro
  BEFORE INSERT ON public.saldos_favor
  FOR EACH ROW EXECUTE FUNCTION public.saldos_favor_no_sobregiro_trg();

-- =========================================================================
-- 4. RLS — read: miembro del tenant; insert: admin/admin_cobranza;
--    super_admin_all A MANO. SIN policies UPDATE/DELETE = append-only para los
--    usuarios del tenant (deshacer = fila 'revertido').
-- =========================================================================
ALTER TABLE public.saldos_favor ENABLE ROW LEVEL SECURITY;

CREATE POLICY "saldos_favor_read" ON public.saldos_favor
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "saldos_favor_insert" ON public.saldos_favor
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.saldos_favor
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 5. Audit log (toda entidad editable tiene historial; guard depth < 2)
-- =========================================================================
CREATE TRIGGER trg_changelog_saldos_favor
  AFTER INSERT OR UPDATE OR DELETE ON public.saldos_favor
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- =========================================================================
-- 6. cargos_extra: el vehículo de la APLICACIÓN del crédito
-- =========================================================================
-- 6a. Nuevo origen 'credito' (esquiva el guard de ajustes, que solo dispara con
--     origen='ajuste', y el de promo/ajuste de 0117). Reemplaza el CHECK con
--     nombre estable (igual que 0119 hizo con 'puente').
ALTER TABLE public.cargos_extra DROP CONSTRAINT IF EXISTS cargos_extra_origen_check;
ALTER TABLE public.cargos_extra
  ADD CONSTRAINT cargos_extra_origen_check
  CHECK (origen IN ('cobro','ajuste','promo','liquidacion','puente','credito'));

-- 6b. Nuevo tipo 'credito_aplicado' (RESTA del saldo, como un descuento, pero
--     SEPARADO para no contaminar reportes de descuentos). El CHECK del tipo es
--     inline (nombre autogenerado) → lo ubicamos por pg_constraint.
DO $$
DECLARE
  v_con text;
BEGIN
  SELECT c.conname INTO v_con
    FROM pg_constraint c
   WHERE c.conrelid = 'public.cargos_extra'::regclass
     AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%tipo%'
     AND pg_get_constraintdef(c.oid) ILIKE '%descuento_monto%'
     AND pg_get_constraintdef(c.oid) ILIKE '%reconexion%'
   LIMIT 1;
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.cargos_extra DROP CONSTRAINT %I', v_con);
  END IF;
END $$;

ALTER TABLE public.cargos_extra
  ADD CONSTRAINT cargos_extra_tipo_check
  CHECK (tipo IN (
    'descuento_monto','descuento_porcentaje','reconexion','otro','credito_aplicado'));

-- 6c. calcular_cargos_neto: 'credito_aplicado' resta (como los descuentos).
--     Reproduce el cuerpo vigente (0023), incluido SECURITY DEFINER +
--     search_path, + el tipo nuevo. (Espeja `cuotas.cargos_neto`.)
CREATE OR REPLACE FUNCTION public.calcular_cargos_neto(p_cuota_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(
    CASE
      WHEN tipo IN ('reconexion','otro') THEN monto
      WHEN tipo IN ('descuento_monto','descuento_porcentaje','credito_aplicado') THEN -monto
      ELSE 0
    END
  ), 0)::numeric
  FROM public.cargos_extra
  WHERE cuota_id = p_cuota_id;
$$;

-- 6d. cuota_total_a_cobrar: el TOTAL real de la cuota que usa el trigger server
--     `recalcular_cuota_desde_pagos` (0012/0018) para derivar el ESTADO. DEBE
--     restar 'credito_aplicado' igual que calcular_cargos_neto; si no, al
--     sincronizar el cargo de crédito el server recalcula el estado SIN el
--     crédito → vuelve la cuota a 'pendiente'/'parcial' (server gana) y una
--     cuota saldo-0 pendiente traba el orden de cobro (bug que 0117 evita).
--     Reproduce el cuerpo vigente (0018) + el tipo nuevo en la RESTA.
CREATE OR REPLACE FUNCTION public.cuota_total_a_cobrar(p_cuota_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    cu.monto
    - COALESCE((
        SELECT SUM(ce.monto)
          FROM public.cargos_extra ce
         WHERE ce.cuota_id = cu.id
           AND ce.tipo IN ('descuento_monto','descuento_porcentaje','credito_aplicado')
      ), 0)
    + COALESCE((
        SELECT SUM(ce.monto)
          FROM public.cargos_extra ce
         WHERE ce.cuota_id = cu.id
           AND ce.tipo IN ('reconexion','otro')
      ), 0)
  FROM public.cuotas cu
  WHERE cu.id = p_cuota_id
$$;

-- =========================================================================
-- 7. Setting cobranza.credito_excedente (super-only, DEFAULT ON)
-- =========================================================================
-- Reproduce el cuerpo vigente de seed_settings_super_only (0125) + la clave
-- nueva. A diferencia del resto (default OFF), este arranca en 'true'.
CREATE OR REPLACE FUNCTION public.seed_settings_super_only(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  VALUES
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuentos_habilitados', 'false'::jsonb, 'boolean',
     'cobranza', 'Permitir aplicar descuentos en campo', 'super_admin'),
    (p_tenant_id, 'cobranza.descuento_tipo', '"monto"'::jsonb, 'string',
     'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_porcentaje', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.cargo_reconexion_habilitado', 'false'::jsonb,
     'boolean', 'cobranza', 'Permitir cobrar reconexión', 'super_admin'),
    (p_tenant_id, 'cobranza.monto_reconexion', '0'::jsonb, 'number',
     'cobranza', 'Monto de reconexión en C$', 'super_admin'),
    (p_tenant_id, 'cobranza.audit_visible_admin', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra el panel de Auditoría (historial de cambios) al admin del tenant',
     'super_admin'),
    (p_tenant_id, 'cobranza.registrar_visitas', 'false'::jsonb, 'boolean',
     'cobranza',
     'Habilita la pestaña Visitas en el detalle del cliente (registrar visita + historial)',
     'super_admin'),
    -- Crédito por excedente al suspender/cancelar → super-only, DEFAULT ON (0127).
    (p_tenant_id, 'cobranza.credito_excedente', 'true'::jsonb, 'boolean',
     'cobranza',
     'Al suspender/cancelar, ofrece acreditar/devolver/condonar el excedente pagado por adelantado (en OFF se pierde, como antes)',
     'super_admin')
  ON CONFLICT (tenant_id, clave) DO UPDATE SET editable_por = 'super_admin';
END $$;

-- Backfill a todos los tenants existentes (el ON CONFLICT preserva el `valor` de
-- las claves viejas; la nueva entra en 'true').
DO $$
DECLARE
  v_t record;
BEGIN
  FOR v_t IN SELECT id FROM public.tenants LOOP
    PERFORM public.seed_settings_super_only(v_t.id);
  END LOOP;
END $$;

-- =========================================================================
-- VERIFICACIÓN post-deploy (correr aparte; nunca asumir que la migración corrió)
-- =========================================================================
-- SELECT to_regclass('public.saldos_favor');                       -- no NULL
-- SELECT polname FROM pg_policies WHERE tablename='saldos_favor';  -- 3 policies
-- SELECT tgname FROM pg_trigger WHERE tgrelid='public.saldos_favor'::regclass; -- no_sobregiro + changelog
-- SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.cargos_extra'::regclass AND conname IN
--   ('cargos_extra_origen_check','cargos_extra_tipo_check');       -- incluyen credito/credito_aplicado
-- SELECT clave, valor, editable_por FROM public.settings
--   WHERE clave='cobranza.credito_excedente';                      -- true / super_admin (1 por tenant)


-- >>> Migration: 0128_op_log.sql <<<
-- op_log — Log de INTENCIÓN del usuario (rework de change log, branch changelog-rework).
--
-- A diferencia de audit_log (que el trigger genérico audit_changelog_trg llena
-- por-fila, fan-outeando una intención en N filas), op_log lo escribe el CLIENTE
-- dentro de su writeTransaction: UNA fila por cada OBJETO afectado por la
-- intención, scoped a los atributos de ESE objeto (la cuota no hereda del
-- contrato). Todas las filas de una misma intención comparten op_id, actor y
-- ocurrido_en.
--
-- Append-only. Lo LEEN admin/admin_cobranza (igual que audit_log). El cobrador
-- lo ESCRIBE (registra sus cobros offline) pero NO lo descarga. Offline-first:
-- PowerSync lo sincroniza como cualquier tabla.
--
-- audit_log y su trigger NO se tocan acá (quedan como forense/archivo; la UI
-- dejará de leerlos en una fase posterior). Diseño completo: CHANGELOG-REWORK.md.

create table public.op_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id),
  op_id       uuid not null,             -- agrupador de intención (generaliza grupo_cobro)
  tipo_op     text not null,             -- 'cobro'|'suspension'|'edicion_entidad'|... (enum app)
  entidad     text not null,             -- objeto-cabecera: 'cuotas'|'contratos'|'clientes'|...
  entidad_id  uuid not null,             -- PK del objeto (para WHERE entidad_id = ?)
  actor_id    uuid,                      -- usuario real de sesión; NULL = "System Admin" (super_admin)
  actor_label text not null,             -- 'Ruby Admin' | 'María' | 'System Admin'
  accion      text not null,             -- 'create' | 'update' | 'delete'
  diff        jsonb not null,            -- {campos:[{campo,antes,despues}], resumen:{...}}
  ocurrido_en timestamptz not null,      -- device-time UTC (orden cronológico real)
  created_at  timestamptz not null default now()  -- server-time al sincronizar (desempate)
);

create index on public.op_log (tenant_id, entidad, entidad_id, ocurrido_en desc);
create index on public.op_log (tenant_id, op_id);

alter table public.op_log enable row level security;

-- LECTURA: mismo modelo que audit_log (0047) — admin + admin_cobranza del tenant.
-- (La visibilidad efectiva para admin_cobranza la gatea el setting
-- audit.visible_admin_cobranza en la UI, igual que hoy.)
create policy "op_log_read" on public.op_log
  for select using (
    tenant_id = public.current_tenant_id()
    and public.is_admin_or_cobranza()
  );

-- INSERCIÓN: cualquier miembro del tenant registra SU propia acción (el cobrador
-- escribe sus cobros offline). actor_id debe ser el propio auth.uid() o NULL
-- (System Admin / super_admin impersonando) → evita spoofear el actor de otro.
-- Append-only: SIN policy UPDATE/DELETE → bloqueadas.
create policy "op_log_insert" on public.op_log
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (actor_id = auth.uid() or actor_id is null)
  );


-- >>> Migration: 0129_op_log_diff_text_y_upsert.sql <<<
-- Fix de op_log (branch changelog-rework) — descubierto en testing en vivo.
--
-- (1) diff: jsonb -> text.
--   El cliente PowerSync guarda diff como STRING de texto JSON (jsonEncode). Al
--   subirlo a una columna jsonb vía PostgREST, Postgres lo mete como jsonb-STRING
--   (jsonb_typeof='string'), no como objeto → doble-encodeado. Como text, el
--   round-trip es identidad (text->text, single) y el cliente lo decodifica con
--   un solo jsonDecode. El schema LOCAL (schema.dart) ya lo declara text.
--
-- (2) policy UPDATE.
--   El conector (powersync/connector.dart) sube cada cambio con supabase.upsert
--   = INSERT ... ON CONFLICT DO UPDATE. op_log no tenía policy UPDATE (diseño
--   append-only), así que en un REINTENTO/conflicto el path de UPDATE daba 42501
--   ("rechazado por el servidor"). El forense INMUTABLE es audit_log (trigger
--   server); op_log es el log de intención para UX → puede tener UPDATE scopeado
--   al dueño sin perder garantías. La app igual nunca actualiza op_log: el
--   upsert solo reescribe la MISMA fila idempotentemente.

alter table public.op_log alter column diff type text using diff::text;

drop policy if exists "op_log_update" on public.op_log;
create policy "op_log_update" on public.op_log
  for update using (
    tenant_id = public.current_tenant_id()
    and (actor_id = auth.uid() or actor_id is null)
  ) with check (
    tenant_id = public.current_tenant_id()
    and (actor_id = auth.uid() or actor_id is null)
  );


-- >>> Migration: 0130_clientes_email.sql <<<
-- 0130 — Email opcional del cliente
-- Campo de contacto adicional (opcional) en información personal del cliente.
-- Aditivo: las apps nuevas lo esperan; las viejas lo ignoran. Sync rules usan
-- SELECT * en los buckets de clientes → la columna se sincroniza sola (no hay
-- que tocar sync-rules.yaml). NO se bumpea _dbWipeVersion (columna aditiva,
-- PowerSync la aplica in-place — política R4).

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS email text;

COMMENT ON COLUMN public.clientes.email IS
  'Correo electrónico del cliente (opcional). Sin validación server; el cliente valida formato.';


-- >>> Migration: 0131_op_log_super_admin_policy.sql <<<
-- op_log: faltaba el bypass de super_admin (R10).
--
-- Las policies de 0128/0129 chequean `tenant_id = current_tenant_id()`, pero el
-- super_admin (impersonando un tenant) NO tiene un current_tenant_id() que
-- matchee al tenant impersonado → TODO INSERT/UPDATE de op_log hecho por el
-- super_admin se rechazaba con 42501 ("Sin permiso para esta operación"). Se vio
-- al cambiar un setting desde el Panel admin impersonando (2026-06-20).
-- El READ no se notaba porque el super_admin lee op_log vía las sync rules de
-- PowerSync (bucket impersonated_tenant), no por esta policy.
--
-- Solución: la policy super_admin_all estándar (idéntica a
-- clientes/cuotas/cliente_etiquetas/saldos_favor): permisiva, FOR ALL. Se OR-ea
-- con op_log_insert/op_log_update/op_log_read, así el resto de roles sigue igual.
drop policy if exists "super_admin_all" on public.op_log;
create policy "super_admin_all" on public.op_log
  for all
  using (public.is_super_admin())
  with check (public.is_super_admin());


-- >>> Migration: 0132_fix_seed_settings_faltantes.sql <<<
-- 0132 — Fix: el seed de settings de tenants nuevos quedó desactualizado.
--
-- `tenants_seed_settings_trg()` (trigger AFTER INSERT en tenants) llama a
-- seed_settings_default/super_only/recibo_layout/ajustes. Varios settings se
-- agregaron DESPUÉS por migración (dias_cuotas_visibles 0113, cambio_fecha
-- 0119, colores_estados, audit.campos_visibles, recibo.mostrar_descuentos/
-- _motivo) con backfill a los tenants existentes, pero NUNCA se sumaron al
-- seed → los tenants NUEVOS nacen sin esas filas y, como el panel solo dibuja
-- las claves con fila, esas opciones no aparecen (ej. Telenet: 54 settings).
--
-- (1) Helper DRY con los 6 defaults canónicos (insert idempotente).
-- (2) Backfill a TODO tenant que las tenga faltantes.
-- (3) tenants_seed_settings_trg() ahora llama al helper → tenants futuros OK.

begin;

create or replace function public.seed_settings_faltantes_0132(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.dias_cuotas_visibles','5'::jsonb,'number','cobranza','Días de cuotas próximas (rango visible al cobrador)','admin'),
    ('cobranza.cambio_fecha_habilitado','false'::jsonb,'boolean','cobranza','Permite el cambio de fecha de pago por días (personal habilitado por el admin)','super_admin'),
    ('cobranza.colores_estados','{"mora":"#DC2626","gracia":"#CA8A04","hoy":"#2563EB","proxima":"#7C3AED"}'::jsonb,'json','cobranza',null,'admin'),
    ('audit.campos_visibles','{"clientes":["codigo","nombre","telefono","direccion","cedula","referencia","notas","activo","cobrador_id","comunidad_id"],"contratos":["codigo","estado","precio_mensual","dia_pago","fecha_inicio","fecha_fin","duracion_meses","documento_path","plan_id","cobrador_id"],"cuotas":["estado","monto","monto_pagado","periodo","fecha_vencimiento","tipo_cargo_manual","descripcion","cargos_neto"],"pagos":["fecha_pago","monto_cordobas","vuelto_cordobas","monto_original","moneda","tasa_conversion","metodo","referencia","notas","anulado"],"recibos":["numero_completo","anulado","reimpresiones"],"cargos_extra":["monto","tipo","descripcion"],"visitas":["estado","notas","resultado"],"fotos_cliente":["descripcion"],"planes":["nombre","tipo","precio_mensual","activo"]}'::jsonb,'json','cobranza',null,'admin'),
    ('recibo.mostrar_descuentos','true'::jsonb,'boolean','recibos',null,'admin'),
    ('recibo.mostrar_motivo_descuentos','true'::jsonb,'boolean','recibos',null,'admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- (2) Backfill a todos los tenants existentes (excepto el System)
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_faltantes_0132(t.id);
  end loop;
end $$;

-- (3) Seed para tenants FUTUROS: llamar al helper desde el trigger
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);   -- [0132] settings que el seed no insertaba
  -- [0113] dias_cuotas_visibles default 5 (red de seguridad por si otro seed lo metió como 30)
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  -- [0113] reglas/permisos sensibles → super_admin-only
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación (dentro de la transacción)
select 'telenet_total' as chk, count(*) as n from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578'
union all select 'telenet_dias_proxima', count(*) from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578' and clave='cobranza.dias_cuotas_visibles'
union all select 'telenet_cambio_fecha', count(*) from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578' and clave='cobranza.cambio_fecha_habilitado'
union all select 'tenants_sin_dias_proxima', count(*) from public.tenants t where t.id<>'00000000-0000-0000-0000-000000000000' and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.dias_cuotas_visibles')
union all select 'tenants_sin_cambio_fecha', count(*) from public.tenants t where t.id<>'00000000-0000-0000-0000-000000000000' and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.cambio_fecha_habilitado');

commit;


-- >>> Migration: 0133_dashboard_secciones_toggle.sql <<<
-- 0133 — Secciones del dashboard admin toggleables (super_admin-only, por tenant).
--
-- 7 settings 'dashboard.*_visible' (boolean, default true): el super_admin
-- prende/apaga qué bloques del Resumen ve el admin de cada tenant (grupo
-- super-only en Settings → Avanzado). El panel SOLO dibuja claves con fila →
-- hay que sembrarlas (R6): helper idempotente + backfill a todos los tenants +
-- enganche al seed de tenants nuevos. Default TRUE = no rompe dashboards
-- existentes (coincide con el getter-default en AppSettings). categoria
-- 'cobranza' a propósito (la tab Avanzado lee settings de esa categoría y los
-- agrupa por settings_groups; reclamadas por kGruposAvanzado).

begin;

create or replace function public.seed_settings_dashboard_0133(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('dashboard.cobros_visible','true'::jsonb,'boolean','cobranza','Muestra los KPIs de cobros (Hoy/Semana/Mes) en el Resumen','super_admin'),
    ('dashboard.proyeccion_visible','true'::jsonb,'boolean','cobranza','Muestra la proyección de cobros por cobrador','super_admin'),
    ('dashboard.recuperacion_visible','true'::jsonb,'boolean','cobranza','Muestra la recuperación de mora por cobrador y comunidad','super_admin'),
    ('dashboard.sparkline_visible','true'::jsonb,'boolean','cobranza','Muestra el gráfico de cobros de 7 días','super_admin'),
    ('dashboard.operativo_visible','true'::jsonb,'boolean','cobranza','Muestra los KPIs operativos (clientes, por cobrar, mora)','super_admin'),
    ('dashboard.top_cobradores_visible','true'::jsonb,'boolean','cobranza','Muestra el top de cobradores del mes','super_admin'),
    ('dashboard.distribucion_visible','true'::jsonb,'boolean','cobranza','Muestra la distribución de cuotas','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_dashboard_0133(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0132).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);   -- [0133]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación dentro de la transacción.
select 'tenants_sin_dashboard' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='dashboard.cobros_visible')
union all
select 'telenet_dashboard_keys', count(*)
  from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578' and clave like 'dashboard.%';

commit;


-- >>> Migration: 0134_avisos_habilitado_toggle.sql <<<
-- 0134 — Toggle super_admin para la pantalla de Avisos (gracia/mora).
--
-- Setting 'cobranza.avisos_habilitado' (boolean, default FALSE = opt-in): el
-- super_admin lo prende por tenant para que admin/admin_cobranza vean la
-- pantalla "Avisos" (clientes próximos a corte / en mora). El panel SOLO dibuja
-- claves con fila → hay que sembrarla (R6): helper idempotente + backfill a
-- todos los tenants + enganche al seed de tenants nuevos. categoria 'cobranza'
-- a propósito (la tab Avanzado lee settings de esa categoría; reclamada por
-- kGruposAvanzado). Default FALSE: no aparece hasta que el super_admin lo prenda.

begin;

create or replace function public.seed_settings_avisos_0134(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.avisos_habilitado','false'::jsonb,'boolean','cobranza','Muestra la pantalla "Avisos" (clientes próximos a corte y en mora) a admin/admin_cobranza','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_avisos_0134(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0133).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);   -- [0134]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación dentro de la transacción.
select 'tenants_sin_avisos' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.avisos_habilitado')
union all
select 'avisos_editable_por_ok', count(*)
  from public.settings where clave='cobranza.avisos_habilitado' and editable_por='super_admin';

commit;


-- >>> Migration: 0135_notif_whatsapp.sql <<<
-- 0135 — Notificación por WhatsApp desde Avisos (Feature 4).
--
-- 3 settings nuevos:
--   1. cobranza.notif_whatsapp_habilitado (boolean, default FALSE, super_admin):
--      habilita los botones "WhatsApp" en la pantalla Avisos. Opt-in.
--   2. cobranza.aviso_msg_gracia (string, editable_por ADMIN): plantilla del
--      mensaje para clientes próximos a corte (en gracia).
--   3. cobranza.aviso_msg_mora (string, editable_por ADMIN): plantilla para
--      clientes en mora (corte).
-- Las plantillas usan placeholders {nombre} {monto} {dias} {empresa} que el
-- cliente rellena al armar el deep link wa.me. Editables por el admin (cada ISP
-- personaliza su texto) → editable_por='admin' (la RLS settings_write_admin lo
-- permite); el feature lo HABILITA el super_admin (toggle #1). categoria
-- 'cobranza': el toggle vive en Avanzado (super-only, kGruposAvanzado) y las
-- plantillas en la tab Cobranza (las edita el admin).

begin;

create or replace function public.seed_settings_notif_0135(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_whatsapp_habilitado','false'::jsonb,'boolean','cobranza',
     'Habilita el botón "WhatsApp" en la pantalla Avisos para notificar a los clientes','super_admin'),
    ('cobranza.aviso_msg_gracia',
     to_jsonb('Hola {nombre} 👋 Le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes próximos a corte (en gracia). Placeholders: {nombre} {monto} {dias} {empresa}','admin'),
    ('cobranza.aviso_msg_mora',
     to_jsonb('Hola {nombre} 👋 Su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes en mora (corte). Placeholders: {nombre} {monto} {dias} {empresa}','admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_notif_0135(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0134).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);   -- [0135]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación dentro de la transacción.
select 'tenants_sin_notif' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.notif_whatsapp_habilitado')
union all
select 'plantillas_admin_editables', count(*)
  from public.settings where clave in ('cobranza.aviso_msg_gracia','cobranza.aviso_msg_mora') and editable_por='admin'
union all
select 'toggle_super_only', count(*)
  from public.settings where clave='cobranza.notif_whatsapp_habilitado' and editable_por='super_admin';

commit;


-- >>> Migration: 0136_templates_whatsapp_sin_emoji.sql <<<
-- 0136 — Plantillas de WhatsApp sin emoji (solo texto).
--
-- Rubén pidió sacar el 👋 de las plantillas por defecto. Toca dos cosas:
--   1. UPDATE de las filas YA sembradas (0135) que siguen en el default viejo
--      (con emoji) → nuevo texto sin emoji. El WHERE compara contra el default
--      viejo EXACTO → si un admin ya editó su mensaje, NO se toca (preserva).
--   2. CREATE OR REPLACE del seeder seed_settings_notif_0135 con el texto sin
--      emoji, para los tenants futuros.
--
-- OJO: settings.valor es TEXT (guarda el JSON como texto, ej. `"Hola..."` con
-- comillas). Para comparar usamos `valor::jsonb = to_jsonb(<texto>)` (jsonb=jsonb).
-- El SET con to_jsonb(...) auto-castea jsonb→text al asignar (igual que 0135).

begin;

-- 1) Actualizar las filas un-customizadas (siguen en el default con emoji).
update public.settings
   set valor = to_jsonb('Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text)
 where clave = 'cobranza.aviso_msg_gracia'
   and valor::jsonb = to_jsonb('Hola {nombre} 👋 Le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text);

update public.settings
   set valor = to_jsonb('Hola {nombre}, su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text)
 where clave = 'cobranza.aviso_msg_mora'
   and valor::jsonb = to_jsonb('Hola {nombre} 👋 Su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text);

-- 2) Tenants futuros: el seeder con el texto sin emoji.
create or replace function public.seed_settings_notif_0135(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_whatsapp_habilitado','false'::jsonb,'boolean','cobranza',
     'Habilita el botón "WhatsApp" en la pantalla Avisos para notificar a los clientes','super_admin'),
    ('cobranza.aviso_msg_gracia',
     to_jsonb('Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes próximos a corte (en gracia). Placeholders: {nombre} {monto} {dias} {empresa}','admin'),
    ('cobranza.aviso_msg_mora',
     to_jsonb('Hola {nombre}, su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes en mora (corte). Placeholders: {nombre} {monto} {dias} {empresa}','admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Verificación dentro de la transacción.
select 'con_emoji_restantes' as chk, count(*) as n
  from public.settings
 where clave in ('cobranza.aviso_msg_gracia','cobranza.aviso_msg_mora')
   and valor like '%👋%';

commit;


-- >>> Migration: 0137_whatsapp_api.sql <<<
-- 0137 — WhatsApp Cloud API (envío automático por lote). Feature paga, opt-in.
--
-- Convive con el modo gratis (wa.me manual, configurado en Cobranza). Este modo
-- API se configura SOLO en Avanzado (super_admin) y habilita el envío por LOTE a
-- la hora configurada vía la Cloud API de Meta.
--
-- Contiene:
--   1. Settings de config (super_admin, categoria cobranza, render custom en la
--      tab Avanzado vía _WhatsappApiCard). El ACCESS TOKEN NO va acá (es secreto
--      y los settings sincronizan a los dispositivos) → va en una tabla aparte.
--   2. Tabla `whatsapp_credenciales` (server-only, NO en sync rules): el token.
--      La escribe SOLO la edge function `whatsapp-set-token` (service role).
--   3. Tabla `whatsapp_envios` (server-only): log de a quién/cuándo se notificó,
--      para respetar la frecuencia de re-notificación y el tope diario.
--
-- Las edge functions + el cron se deployan a mano en el Dashboard (ver
-- Install Steps / la guía). Esta migración solo prepara DB + settings.

begin;

-- ── 1) Settings de config del modo API ──────────────────────────────────────
create or replace function public.seed_settings_whatsapp_api_0137(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_api_habilitado','false'::jsonb,'boolean','cobranza','Activa el envío automático por lote vía la API paga de WhatsApp','super_admin'),
    ('cobranza.notif_api_phone_id', to_jsonb(''::text),'string','cobranza','Phone Number ID de la Cloud API de Meta','super_admin'),
    ('cobranza.notif_api_template_gracia', to_jsonb(''::text),'string','cobranza','Nombre de la plantilla aprobada por Meta para próximos a corte (gracia)','super_admin'),
    ('cobranza.notif_api_template_mora', to_jsonb(''::text),'string','cobranza','Nombre de la plantilla aprobada por Meta para mora (corte)','super_admin'),
    ('cobranza.notif_api_template_lang', to_jsonb('es'::text),'string','cobranza','Código de idioma de las plantillas (ej. es, es_NI)','super_admin'),
    ('cobranza.notif_api_hora','8'::jsonb,'number','cobranza','Hora (0-23, Nicaragua) del envío automático diario','super_admin'),
    ('cobranza.notif_api_frecuencia', to_jsonb('semanal'::text),'string','cobranza','Cada cuánto re-notificar al mismo cliente: una_vez_estado | cada_3 | semanal | cada_15 | diario','super_admin'),
    ('cobranza.notif_api_tope_diario','200'::jsonb,'number','cobranza','Tope de mensajes por día (resguardo anti-spam)','super_admin'),
    ('cobranza.notif_api_token_configurado','false'::jsonb,'boolean','cobranza','Refleja si el Access Token está cargado (lo setea la edge function; el token vive en el servidor)','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_whatsapp_api_0137(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0135).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);
  perform public.seed_settings_whatsapp_api_0137(new.id);   -- [0137]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- ── 2) Token (server-only, NO en sync rules) ─────────────────────────────────
create table if not exists public.whatsapp_credenciales (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  access_token text not null,
  actualizado_en timestamptz not null default now()
);
alter table public.whatsapp_credenciales enable row level security;
-- Sin policies: SOLO el service role (edge function) accede. El cliente nunca la
-- ve (tampoco está en sync rules). Defensa en profundidad contra REST directo.

-- ── 3) Log de envíos (server-only) — para frecuencia + tope ──────────────────
create table if not exists public.whatsapp_envios (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  cliente_id uuid not null,
  estado text not null,            -- 'gracia' | 'mora'
  canal text not null default 'api', -- 'api' | 'wa_me'
  enviado_en timestamptz not null default now(),
  ok boolean not null default true,
  error text
);
create index if not exists whatsapp_envios_lookup
  on public.whatsapp_envios (tenant_id, cliente_id, enviado_en desc);
alter table public.whatsapp_envios enable row level security;
-- El super_admin puede inspeccionar el log; el service role (edge/cron) escribe.
drop policy if exists whatsapp_envios_super_select on public.whatsapp_envios;
create policy whatsapp_envios_super_select on public.whatsapp_envios
  for select using (public.is_super_admin());

-- Verificación dentro de la transacción.
select 'tenants_sin_api_cfg' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.notif_api_habilitado')
union all
select 'tablas_creadas',
  (select count(*) from information_schema.tables
    where table_schema='public' and table_name in ('whatsapp_credenciales','whatsapp_envios'));

commit;


-- >>> Migration: 0138_whatsapp_clientes_a_notificar.sql <<<
-- 0138 — Función que devuelve los clientes a notificar por WhatsApp (modo API).
--
-- La usa la edge function `whatsapp-enviar` (modo lote) + el cron. Centraliza la
-- lógica en Postgres (testeable por SQL): clientes con deuda VENCIDA (gracia o
-- mora), con teléfono, que NO fueron notificados dentro de la ventana de la
-- frecuencia configurada, hasta el tope diario. Un cliente se clasifica por su
-- cuota MÁS VIEJA impaga (igual que la pantalla Avisos): mora si pasó la gracia,
-- gracia si todavía está dentro.
--
-- `dias`: para gracia = cuántos faltan para el corte; para mora = hace cuántos.
-- `monto`: total VENCIDO del cliente (Σ saldo canónico de cuotas pasadas de fecha).
-- settings.valor es TEXT-JSON → se extrae con `::jsonb #>> '{}'` (escalar sin comillas).

begin;

create or replace function public.whatsapp_clientes_a_notificar(p_tenant uuid)
returns table (
  cliente_id uuid,
  nombre text,
  telefono text,
  estado text,
  monto numeric,
  dias int
) language plpgsql stable as $fn$
declare
  v_hoy date := (now() at time zone 'America/Managua')::date;
  v_gracia int;
  v_freq text;
  v_tope int;
begin
  select coalesce((s.valor::jsonb #>> '{}')::int, 10) into v_gracia
    from public.settings s where s.tenant_id=p_tenant and s.clave='cobranza.dias_gracia';
  v_gracia := coalesce(v_gracia, 10);
  select coalesce(s.valor::jsonb #>> '{}', 'semanal') into v_freq
    from public.settings s where s.tenant_id=p_tenant and s.clave='cobranza.notif_api_frecuencia';
  v_freq := coalesce(v_freq, 'semanal');
  select coalesce((s.valor::jsonb #>> '{}')::int, 200) into v_tope
    from public.settings s where s.tenant_id=p_tenant and s.clave='cobranza.notif_api_tope_diario';
  v_tope := coalesce(v_tope, 200);

  return query
  with deudas as (
    select cu.cliente_id as cid,
           min(cu.fecha_vencimiento) as peor,
           sum(greatest(cu.monto + coalesce(cu.cargos_neto,0) - coalesce(cu.monto_pagado,0), 0)) as saldo
      from public.cuotas cu
      join public.clientes c on c.id = cu.cliente_id and c.activo
      left join public.contratos ct on ct.id = cu.contrato_id
     where cu.tenant_id = p_tenant
       and coalesce(ct.estado,'activo') = 'activo'
       and cu.estado in ('pendiente','parcial')
       and cu.fecha_vencimiento < v_hoy
     group by cu.cliente_id
  ),
  clasificado as (
    select d.cid, d.peor, d.saldo,
           case when (d.peor + v_gracia) < v_hoy then 'mora' else 'gracia' end as est,
           case when (d.peor + v_gracia) < v_hoy
                then (v_hoy - d.peor) - v_gracia          -- mora: hace N días
                else v_gracia - (v_hoy - d.peor) end as d_dias  -- gracia: faltan N
      from deudas d
  )
  select cl.cid, c.nombre, c.telefono, cl.est, cl.saldo::numeric, cl.d_dias
    from clasificado cl
    join public.clientes c on c.id = cl.cid
   where c.telefono is not null and btrim(c.telefono) <> ''
     and not exists (
       select 1 from public.whatsapp_envios e
        where e.tenant_id = p_tenant and e.cliente_id = cl.cid and e.ok
          and case v_freq
                when 'diario'         then e.enviado_en::date >= v_hoy
                when 'cada_3'         then e.enviado_en > now() - interval '3 days'
                when 'semanal'        then e.enviado_en > now() - interval '7 days'
                when 'cada_15'        then e.enviado_en > now() - interval '15 days'
                when 'una_vez_estado' then e.estado = cl.est and e.enviado_en::date >= cl.peor
                else e.enviado_en::date >= v_hoy
              end
     )
   order by cl.peor asc
   limit v_tope;
end;
$fn$;

commit;


-- >>> Migration: 0139_whatsapp_api_body.sql <<<
-- 0139 — Cuerpo (borrador) de las plantillas del modo API de WhatsApp.
--
-- El modo API NO envía texto libre: Meta exige una plantilla aprobada y la app
-- manda el NOMBRE de la plantilla + los valores de las variables. Estos dos
-- settings guardan el CUERPO redactado en el editor visual de la app (chips +
-- preview), que sirve para COPIAR/PEGAR al crear la plantilla en Meta y queda de
-- referencia. NO es lo que se envía (eso es la plantilla aprobada en Meta).
--
-- Placeholders del editor (igual que el modo gratis): {nombre} {monto} {dias}
-- {empresa}. El botón "Copiar para Meta" los convierte a variables CON NOMBRE de
-- Meta: {{nombre}} {{monto}} {{dias}} {{empresa}} (el edge function manda los
-- parámetros por nombre → sin problema de orden). Defaults = mismos textos que
-- los avisos gratis (kAvisoMsg* en settings_repo.dart).

begin;

create or replace function public.seed_settings_whatsapp_api_body_0139(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_api_body_gracia',
     to_jsonb('Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text),
     'string','cobranza','Cuerpo redactado de la plantilla de gracia (borrador para crear/pegar en Meta; no es lo que se envía)','super_admin'),
    ('cobranza.notif_api_body_mora',
     to_jsonb('Hola {nombre}, su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text),
     'string','cobranza','Cuerpo redactado de la plantilla de mora (borrador para crear/pegar en Meta; no es lo que se envía)','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_whatsapp_api_body_0139(t.id);
  end loop;
end $$;

-- Trigger de seed: preservar el cuerpo exacto + agregar la nueva llamada.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);
  perform public.seed_settings_whatsapp_api_0137(new.id);   -- [0137]
  perform public.seed_settings_whatsapp_api_body_0139(new.id);   -- [0139]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

select 'tenants_sin_body' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.notif_api_body_gracia');

commit;


-- >>> Migration: 0140_drop_audit_log.sql <<<
-- 0140 — Eliminar por completo el sistema `audit_log` (forense server-side).
--
-- Decisión de Rubén (2026-06-21): `op_log` (change-log escrito por el cliente)
-- cubre el historial que la app muestra; `audit_log` era forense/debug y casi no
-- se usaba (1 panel gateado + el RPC list_audit_cobrador + config de campos).
-- Se elimina TODO el sistema audit_log. `op_log` NO se toca.
--
-- ⚠️ MIGRACIÓN DESTRUCTIVA — ORDEN DE DEPLOY OBLIGATORIO (prod):
--   1) Deployar las edge functions SIN inserts a audit_log (forzar-password,
--      eliminar-cobrador, cambiar-email, reenviar-invitacion).
--   2) Releasear la app SIN el panel /admin/audit, sin el insert de impersonación,
--      sin la tabla en schema.dart, sin el RPC list_audit_cobrador.
--   3) Flipear las sync rules (sacar audit_log de los 3 buckets) en PowerSync.
--   4) RECIÉN AHÍ correr esta migración.
-- Si se corre antes, los escritores vivos (triggers→no; edge/impersonación→sí)
-- y lectores (panel/RPC) fallan. Los triggers se van acá (server-side, instantáneo
-- para todos). Lista de triggers/funciones VERIFICADA contra prod (vxxz).

begin;

-- ── 1) Triggers de change-log (todos llaman audit_changelog_trg) + settings ──
drop trigger if exists trg_audit_settings              on public.settings;
drop trigger if exists trg_changelog_cargos_extra      on public.cargos_extra;
drop trigger if exists trg_changelog_cliente_etiquetas on public.cliente_etiquetas;
drop trigger if exists trg_changelog_clientes          on public.clientes;
drop trigger if exists trg_changelog_cobradores        on public.cobradores;
drop trigger if exists trg_changelog_comunidades       on public.comunidades;
drop trigger if exists trg_changelog_contrato_suspensiones on public.contrato_suspensiones;
drop trigger if exists trg_changelog_contratos         on public.contratos;
drop trigger if exists trg_changelog_cuotas            on public.cuotas;
drop trigger if exists trg_changelog_departamentos     on public.departamentos;
drop trigger if exists trg_changelog_etiquetas         on public.etiquetas;
drop trigger if exists trg_changelog_fotos_cliente     on public.fotos_cliente;
drop trigger if exists trg_changelog_incidentes        on public.incidentes;
drop trigger if exists trg_changelog_inv_categorias    on public.inv_categorias;
drop trigger if exists trg_changelog_inv_movimientos   on public.inv_movimientos;
drop trigger if exists trg_changelog_inv_productos     on public.inv_productos;
drop trigger if exists trg_changelog_inv_proveedores   on public.inv_proveedores;
drop trigger if exists trg_changelog_inv_seriales      on public.inv_seriales;
drop trigger if exists trg_changelog_inv_ubicaciones   on public.inv_ubicaciones;
drop trigger if exists trg_changelog_municipios        on public.municipios;
drop trigger if exists trg_changelog_pagos             on public.pagos;
drop trigger if exists trg_changelog_planes            on public.planes;
drop trigger if exists trg_changelog_recibos           on public.recibos;
drop trigger if exists trg_changelog_red_hubs          on public.red_hubs;
drop trigger if exists trg_changelog_red_nodos         on public.red_nodos;
drop trigger if exists trg_changelog_red_puertos       on public.red_puertos;
drop trigger if exists trg_changelog_saldos_favor      on public.saldos_favor;
drop trigger if exists trg_changelog_ticket_adjuntos   on public.ticket_adjuntos;
drop trigger if exists trg_changelog_ticket_eventos    on public.ticket_eventos;
drop trigger if exists trg_changelog_ticket_materiales on public.ticket_materiales;
drop trigger if exists trg_changelog_ticket_tipos      on public.ticket_tipos;
drop trigger if exists trg_changelog_tickets           on public.tickets;
drop trigger if exists trg_changelog_visitas           on public.visitas;

-- ── 2) Funciones (changelog + deprecated huérfanas + reset + el RPC) ──────────
drop function if exists public.audit_changelog_trg();
drop function if exists public.audit_settings_trg();
drop function if exists public.audit_clientes_cobrador_trg();
drop function if exists public.audit_cuotas_anulacion_trg();
drop function if exists public.audit_pagos_anulacion_trg();
drop function if exists public.audit_recibos_anulacion_trg();
drop function if exists public.audit_registrar(uuid, text, uuid, text, jsonb, jsonb, text, timestamptz);
drop function if exists public.audit_reset_password(uuid);
drop function if exists public.list_audit_cobrador(uuid, integer);

-- ── 2b) RPCs vivos que insertaban en audit_log → redefinir SIN ese insert ─────
-- (set_cobrador_rol/activo + set_tenant_modulo los llama el panel super_admin;
-- si no se redefinen, revientan al dropear la tabla). Idempotentes.
create or replace function public.set_cobrador_rol(p_cobrador_id uuid, p_nuevo_rol text)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_target_rol text;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio rol';
  end if;
  if p_nuevo_rol not in ('admin','admin_cobranza','cobrador','tecnico','admin_tickets') then
    raise exception 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets';
  end if;
  select rol into v_target_rol from public.cobradores where id = p_cobrador_id for update;
  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;
  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar el rol de otro super_admin';
  end if;
  if v_target_rol = p_nuevo_rol then
    return;
  end if;
  update public.cobradores
     set rol = p_nuevo_rol,
         prefijo_recibo = case when p_nuevo_rol in ('cobrador','admin','admin_cobranza')
                               then prefijo_recibo else null end
   where id = p_cobrador_id;
end;
$fn$;

create or replace function public.set_cobrador_activo(p_cobrador_id uuid, p_activo boolean)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_target_rol    text;
  v_target_activo boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio estado';
  end if;
  select rol, activo into v_target_rol, v_target_activo
    from public.cobradores where id = p_cobrador_id;
  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;
  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar a otro super_admin';
  end if;
  if v_target_activo = p_activo then
    return;
  end if;
  update public.cobradores set activo = p_activo where id = p_cobrador_id;
end;
$fn$;

create or replace function public.set_tenant_modulo(p_tenant_id uuid, p_modulo text, p_habilitado boolean)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_es_base boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede modificar el tenant System';
  end if;
  select es_base into v_es_base from public.modulos where codigo = p_modulo;
  if v_es_base is null then
    raise exception 'Módulo % no existe', p_modulo;
  end if;
  if v_es_base and not p_habilitado then
    raise exception 'Módulo % es base y no se puede deshabilitar', p_modulo;
  end if;
  insert into public.tenant_modulos (tenant_id, modulo_codigo, habilitado, habilitado_en, habilitado_por)
  values (p_tenant_id, p_modulo, p_habilitado, now(), auth.uid())
  on conflict (tenant_id, modulo_codigo) do update
    set habilitado     = excluded.habilitado,
        habilitado_en  = excluded.habilitado_en,
        habilitado_por = excluded.habilitado_por;
end;
$fn$;

-- ── 3) Setting del PANEL muerto (cobranza.audit_visible_admin) ────────────────
-- OJO: NO tocar 'audit.visible_admin_cobranza' — pese al nombre "audit", gatea un
-- historial de op_log VIVO (pagos_admin_screen → HistorialOpLog para admin_cobranza).
-- Tampoco 'audit.campos_visibles' se borra acá (queda huérfano inofensivo; el
-- configurador viejo se retira del lado app).
delete from public.settings where clave = 'cobranza.audit_visible_admin';

-- ── 4) La tabla (PUNTO DE NO RETORNO — se va el histórico forense) ────────────
drop table if exists public.audit_log;

-- Verificación
select 'triggers_audit_restantes' as chk, count(*) as n
  from pg_trigger t join pg_proc p on p.oid=t.tgfoid
  where not t.tgisinternal and (p.proname ilike '%audit%' or p.proname ilike '%changelog%')
union all
select 'audit_log_existe', case when to_regclass('public.audit_log') is null then 0 else 1 end;

commit;


-- >>> Migration: 0141_reportes_detallados_toggle.sql <<<
-- 0141 — Toggle 'cobranza.reportes_detallados' (super_admin, Avanzado).
--
-- Rework del módulo de reportes: por defecto el módulo se basa en la PLANTILLA
-- estándar ("Reporte de cobranza", Excel) que pidieron Mairena/Telenet. Los
-- reportes variados de siempre (los 8 PDF + arqueo + menú Excel) NO se borran:
-- se ocultan tras este toggle, que solo el super_admin habilita por tenant.
-- Default OFF (= solo el reporte plantilla). Aditivo, sin cambios de schema.

begin;

create or replace function public.seed_settings_reportes_0141(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, 'cobranza.reportes_detallados', 'false'::jsonb, 'boolean', 'cobranza',
         'Muestra los reportes detallados (legacy) además del reporte de cobranza estándar', 'super_admin'
  where not exists (
    select 1 from public.settings s
     where s.tenant_id = p_tenant and s.clave = 'cobranza.reportes_detallados'
  );
end;
$fn$;

do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_reportes_0141(t.id);
  end loop;
end $$;

-- Trigger de seed: preservar el cuerpo exacto + agregar la nueva llamada.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);
  perform public.seed_settings_whatsapp_api_0137(new.id);   -- [0137]
  perform public.seed_settings_whatsapp_api_body_0139(new.id);   -- [0139]
  perform public.seed_settings_reportes_0141(new.id);   -- [0141]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

select 'tenants_sin_toggle' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.reportes_detallados');

commit;


-- >>> Migration: 0142_colchon_indefinidos_greatest3.sql <<<
-- 0142 — Colchón de cuotas de indefinidos: GREATEST(0,…) → GREATEST(3,…).
--
-- Un contrato INDEFINIDO genera `meses_desde_primer_mes + 1 + colchón(3)` cuotas,
-- con piso GREATEST(0,…). Con fecha de instalación FUTURA ese cálculo da < 3 (o 0
-- con +3 meses) → el cobrador no ve cuotas por cobrar hasta que el cron mensual
-- las completa. Decisión Rubén: el indefinido SIEMPRE arranca con el colchón de 3
-- desde la primera cuota de pago, sin importar la fecha. Fix de 1 línea
-- (GREATEST 0→3). Idempotente (CREATE OR REPLACE); no toca cuotas existentes.

CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(p_contrato_id uuid, p_meses integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_num_cuotas    int;          -- cuántas cuotas generar
  v_creadas       int := 0;
  v_primer_mes    date;         -- mes de vencimiento de la 1ª cuota (mes sig. a instalación)
  v_periodo       date;         -- mes de vencimiento de la cuota i
  v_vencimiento   date;
  v_inserto       boolean;
  v_colchon       constant int := 3;  -- meses adelante a pregenerar (indefinidos)
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  -- Contrato no activo (cancelado): no generar nada nuevo.
  IF v_contrato.estado IS DISTINCT FROM 'activo' THEN
    RETURN 0;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes de vencimiento de la PRIMERA cuota = mes siguiente a la instalación.
  -- Facturación vencida: paga al final del período de servicio. Se deriva de
  -- fecha_inicio (autoridad del dinero); el form pobla fecha_primer_cobro
  -- aparte, solo para display.
  v_primer_mes := (date_trunc('month', v_contrato.fecha_inicio) + interval '1 month')::date;

  -- Cuántas cuotas generar.
  IF p_meses IS NOT NULL THEN
    v_num_cuotas := p_meses;
  ELSIF v_contrato.duracion_meses IS NOT NULL THEN
    -- Fijo: exactamente duracion_meses cuotas (invariante de dinero #5).
    v_num_cuotas := v_contrato.duracion_meses;
  ELSE
    -- Indefinido: desde el primer mes hasta hoy + colchón. Retroactivo:
    -- si el contrato arrancó hace meses, genera las que falten. El cron
    -- recalcula cada mes con current_date → mantiene el colchón futuro.
    -- GREATEST(3,…) (fix 0142): piso de 3 cuotas SIEMPRE — una instalación con
    -- fecha futura ya no arranca con < 3 (o 0) cuotas por cobrar.
    v_num_cuotas := GREATEST(
      3,
      ((extract(year  from current_date)::int - extract(year  from v_primer_mes)::int) * 12
     +  (extract(month from current_date)::int - extract(month from v_primer_mes)::int))
      + 1 + v_colchon
    );
  END IF;

  FOR i IN 0 .. v_num_cuotas - 1 LOOP
    v_periodo := (v_primer_mes + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    INSERT INTO public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) VALUES (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    ON CONFLICT (contrato_id, periodo) DO NOTHING;

    GET DIAGNOSTICS v_inserto = ROW_COUNT;
    IF v_inserto THEN
      v_creadas := v_creadas + 1;
    END IF;
  END LOOP;

  RETURN v_creadas;
END;
$function$;


-- >>> Migration: 0143_drop_error_logs.sql <<<
-- 0143 — Eliminar error_logs por completo (decisión Rubén 2026-06-22).
--
-- Era el log de crashes del cliente Flutter (pantalla /super/logs). No se usó
-- para debug; se quita junto con su servicio/pantalla/ruta en la app. NO está
-- en las sync rules ni en schema.dart (se escribía por REST y se leía por RPC),
-- así que NO requiere deploy de sync rules. Drop de la tabla + sus 2 RPCs
-- (list_error_logs / purge_error_logs). Destructivo y autorizado.

begin;

-- Drop de las funciones por su firma real (robusto ante overloads/cambios).
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig
      from pg_proc
     where proname in ('list_error_logs', 'purge_error_logs')
       and pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

drop table if exists public.error_logs cascade;

commit;


-- >>> Migration: 0144_reinvite_locks.sql <<<
-- 0144 — Lock anti-race para `reenviar-invitacion` (#6).
--
-- Reenviar borra el usuario de auth y lo recrea. Dos super_admins reenviando el
-- MISMO cobrador pendiente a la vez se pisaban (uno borra, el otro 404→409, y si
-- la recreación del primero falla queda inconsistente). Esta tabla es un lock
-- por cobrador: la edge function inserta una fila (PK única) al entrar; si ya
-- existe (otro reenvío en curso) rebota con 409; la borra al terminar (finally).
-- Limpieza de locks huérfanos por TTL (>120s) en la propia función. Server-only:
-- solo el service_role la toca → bypassa RLS; NO se sincroniza.

create table if not exists public.reinvite_locks (
  cobrador_id uuid primary key,
  locked_at   timestamptz not null default now()
);

alter table public.reinvite_locks enable row level security;
-- Sin policies a propósito: ningún usuario normal la lee/escribe; solo la edge
-- function (service_role, que bypassa RLS).


-- >>> Migration: 0145_busqueda_campos_toggle.sql <<<
-- 0145 — Toggles de campos de búsqueda de cliente (super_admin, Avanzado).
--
-- La búsqueda de cliente (5 listas: clientes admin, lista del cobrador, Cobros,
-- global, mapa) matcheaba SIEMPRE nombre + código + cédula + teléfono +
-- código-de-contrato. El teléfono mete falsos positivos (buscar "003" trae todo
-- número con 003). Estos toggles dejan que el super_admin elija qué campos
-- entran, por tenant. El NOMBRE no es toggle (siempre entra). Default TRUE =
-- comportamiento previo (no cambia nada hasta que el super_admin apague alguno).
-- Aditivo, sin cambios de schema. Lo consume el helper busquedaClienteSql.

begin;

create or replace function public.seed_settings_busqueda_0145(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, x.clave, 'true'::jsonb, 'boolean', 'cobranza', x.descripcion, 'super_admin'
    from (values
      ('busqueda.por_codigo',   'Buscar clientes por su código'),
      ('busqueda.por_cedula',   'Buscar clientes por cédula'),
      ('busqueda.por_telefono', 'Buscar clientes por teléfono (apagalo si mete falsos positivos)'),
      ('busqueda.por_contrato', 'Buscar clientes por el código de sus contratos')
    ) as x(clave, descripcion)
   where not exists (
     select 1 from public.settings s
      where s.tenant_id = p_tenant and s.clave = x.clave
   );
end;
$fn$;

-- Backfill de los tenants existentes.
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_busqueda_0145(t.id);
  end loop;
end $$;

-- Trigger de seed: MISMO cuerpo actual + la llamada nueva (para tenants nuevos).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);
  perform public.seed_settings_whatsapp_api_0137(new.id);   -- [0137]
  perform public.seed_settings_whatsapp_api_body_0139(new.id);   -- [0139]
  perform public.seed_settings_reportes_0141(new.id);   -- [0141]
  perform public.seed_settings_busqueda_0145(new.id);   -- [0145]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

commit;

-- Verificación: ningún tenant real sin el toggle.
select 'tenants_sin_toggle' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='busqueda.por_telefono');


-- >>> Migration: 0146_data_ops.sql <<<
-- 0146 — Operaciones de datos del super_admin (corrección de errores de carga).
--
-- Backend del panel "Operaciones" (super_admin): la edge function
-- `super-admin-data-op` ejecuta borrados predefinidos (limpiar_cliente /
-- eliminar_cliente / eliminar_contrato) con PREVIEW + confirmación + BACKUP +
-- registro. Estas 2 tablas son el backup (restaurable) y el log (historial).
-- NO se sincronizan a clientes: el panel las lee por REST con el JWT del
-- super_admin (igual que tenants/tenant_modulos). Aditivas, sin cambios a otras
-- tablas. El INSERT lo hace el service_role (edge fn); el super_admin solo LEE.

begin;

-- Snapshot de las filas borradas por una operación (para poder restaurar).
create table if not exists public.data_op_backups (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  operacion    text not null,        -- limpiar_cliente | eliminar_cliente | eliminar_contrato
  target_label text not null,        -- ej. 'SE0020 — David Pineda Saenz'
  snapshot     jsonb not null,       -- las filas eliminadas, por tabla
  actor_id     uuid,
  actor_label  text,
  created_at   timestamptz not null default now()
);

-- Registro de cada operación ejecutada (el "Historial de operaciones").
create table if not exists public.data_ops_log (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  operacion    text not null,
  target_label text not null,
  afectados    jsonb not null,       -- {contratos:8, cuotas:64, pagos:47, ...}
  backup_id    uuid references public.data_op_backups(id) on delete set null,
  actor_id     uuid,
  actor_label  text,
  created_at   timestamptz not null default now()
);

create index if not exists data_ops_log_tenant_idx
  on public.data_ops_log (tenant_id, created_at desc);

alter table public.data_op_backups enable row level security;
alter table public.data_ops_log    enable row level security;

-- Solo el super_admin LEE (vía REST con su JWT). El INSERT lo hace el
-- service_role de la edge function (bypassa RLS). Sin policies de INSERT/
-- UPDATE/DELETE para usuarios normales → nadie más las toca.
drop policy if exists data_op_backups_super_read on public.data_op_backups;
create policy data_op_backups_super_read on public.data_op_backups
  for select using (public.is_super_admin());

drop policy if exists data_ops_log_super_read on public.data_ops_log;
create policy data_ops_log_super_read on public.data_ops_log
  for select using (public.is_super_admin());

commit;

-- Verificación.
select to_regclass('public.data_op_backups') AS backups,
       to_regclass('public.data_ops_log')    AS log;


-- >>> Migration: 0147_data_ops_funciones.sql <<<
-- 0147 — Funciones del panel "Operaciones de datos" (super_admin).
--
-- 6 funciones SECURITY DEFINER que respaldan el panel de corrección de errores
-- de carga: 3 de PREVIEW (cuentan, NO borran) + 3 de EJECUTAR (snapshot atómico
-- a data_op_backups → borrado en orden FK → limpieza de op_log → registro en
-- data_ops_log). Todas arrancan con el gate `is_super_admin()` (usa auth.uid()
-- → chequea al LLAMADOR, no al definer) + validan que el target pertenezca al
-- tenant en contexto (`p_tenant`, defensa en profundidad: el server reproduce
-- el scope que la UI ya filtra client-side).
--
-- ORDEN DE BORRADO (derivado de las FK reales — CRÍTICO):
--   · pagos.cuota_id es NO ACTION → SIEMPRE borrar `pagos` ANTES que cuotas/
--     contratos (si no, el delete de cuotas falla por la FK).
--   · recibos.pago_id CASCADE → los recibos se van solos al borrar pagos.
--   · cuotas.contrato_id, contrato_suspensiones.contrato_id, cargos_extra.cuota_id,
--     notificaciones_mora.cuota_id, saldos_favor.contrato_id/cliente_id → CASCADE.
--   · cliente_etiquetas/contratos/fotos_cliente/saldos_favor/visitas.cliente_id
--     CASCADE; inv_seriales/inv_movimientos/tickets.cliente_id SET NULL (se
--     desvinculan, NO se borran).
-- Por eso: borrar pagos del scope PRIMERO, después un solo delete del contenedor
-- (contrato o cliente) deja que el CASCADE arrastre el resto.
--
-- SNAPSHOT COMPLETO: el backup incluye TODAS las tablas que el borrado elimina
-- (incl. cargos_extra + notificaciones_mora que caen por cascade de cuotas, y
-- saldos_favor) → restauración fiel.
--
-- op_log: es CLIENT-written, append-only (0128) — NO lo escriben triggers server.
-- El `delete from op_log where entidad_id=any(v_ids)` limpia el historial de
-- intención PREEXISTENTE de las entidades borradas. v_ids se captura ANTES.
--
-- Idempotente: todas son CREATE OR REPLACE; re-correr la migración es seguro.

begin;

-- Drop de firmas viejas (idempotencia: por si se corrió una versión previa con
-- otra aridad — al agregar p_tenant cambia la firma y quedarían overloads que
-- harían ambigua la resolución de PostgREST).
drop function if exists public.super_admin_preview_limpiar_cliente(uuid);
drop function if exists public.super_admin_preview_eliminar_contrato(uuid);
drop function if exists public.super_admin_preview_eliminar_cliente(uuid);
drop function if exists public.super_admin_ejecutar_limpiar_cliente(uuid, text);
drop function if exists public.super_admin_ejecutar_eliminar_contrato(uuid, text);
drop function if exists public.super_admin_ejecutar_eliminar_cliente(uuid, text);

-- ════════════════════════════════════════════════════════════════════════════
-- PREVIEW — limpiar cliente (conserva el cliente, borra su cobranza)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_preview_limpiar_cliente(p_cliente uuid, p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_label text; v_tenant uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  return jsonb_build_object(
    'target_label', v_label,
    'conserva', 'El cliente (datos, ubicación, etiquetas, fotos) se conserva. Se borra solo su cobranza.',
    'afectados', jsonb_build_object(
      'contratos',(select count(*) from contratos where cliente_id=p_cliente),
      'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
      'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
      'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente)));
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- PREVIEW — eliminar contrato (un solo contrato del cliente)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_preview_eliminar_contrato(p_contrato uuid, p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_label text; v_tenant uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo, id::text) into v_tenant, v_label from contratos where id=p_contrato;
  if v_tenant is null then raise exception 'Contrato no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El contrato no pertenece al tenant en contexto'; end if;
  return jsonb_build_object(
    'target_label', v_label,
    'conserva', 'El cliente se conserva. Se borra solo este contrato y su cobranza.',
    'afectados', jsonb_build_object(
      'contratos', 1,
      'cuotas',(select count(*) from cuotas where contrato_id=p_contrato),
      'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
      'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
      'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.contrato_id=p_contrato),
      'suspensiones',(select count(*) from contrato_suspensiones where contrato_id=p_contrato)));
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- PREVIEW — eliminar cliente (borra TODO + el cliente)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_preview_eliminar_cliente(p_cliente uuid, p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_label text; v_tenant uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  return jsonb_build_object(
    'target_label', v_label,
    'conserva', 'NADA del cliente se conserva (inventario y tickets quedan desvinculados, no se borran).',
    'afectados', jsonb_build_object(
      'cliente', 1,
      'contratos',(select count(*) from contratos where cliente_id=p_cliente),
      'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
      'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
      'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
      'etiquetas',(select count(*) from cliente_etiquetas where cliente_id=p_cliente),
      'fotos',(select count(*) from fotos_cliente where cliente_id=p_cliente),
      'visitas',(select count(*) from visitas where cliente_id=p_cliente)));
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- EJECUTAR — limpiar cliente (CONSERVA el cliente, borra su cobranza)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_ejecutar_limpiar_cliente(p_cliente uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tenant uuid; v_label text; v_snapshot jsonb; v_afectados jsonb; v_backup_id uuid; v_ids uuid[];
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  select array_agg(id) into v_ids from (
    select id from contratos where cliente_id=p_cliente
    union select id from cuotas where cliente_id=p_cliente
    union select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select r.id from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select cs.id from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente) x;
  v_snapshot := jsonb_build_object(
    'contratos',(select coalesce(jsonb_agg(t),'[]') from contratos t where t.cliente_id=p_cliente),
    'cuotas',(select coalesce(jsonb_agg(t),'[]') from cuotas t where t.cliente_id=p_cliente),
    'pagos',(select coalesce(jsonb_agg(p),'[]') from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select coalesce(jsonb_agg(r),'[]') from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos_extra',(select coalesce(jsonb_agg(ce),'[]') from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'notificaciones_mora',(select coalesce(jsonb_agg(nm),'[]') from notificaciones_mora nm join cuotas c on c.id=nm.cuota_id where c.cliente_id=p_cliente),
    'contrato_suspensiones',(select coalesce(jsonb_agg(cs),'[]') from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'op_log',(select coalesce(jsonb_agg(o),'[]') from op_log o where o.entidad_id = any(v_ids)));
  v_afectados := jsonb_build_object(
    'contratos',(select count(*) from contratos where cliente_id=p_cliente),
    'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
    'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'historial',(select count(*) from op_log o where o.entidad_id = any(v_ids)));
  insert into data_op_backups(tenant_id,operacion,target_label,snapshot,actor_id,actor_label)
    values (v_tenant,'limpiar_cliente',v_label,v_snapshot,auth.uid(),p_actor_label) returning id into v_backup_id;
  delete from pagos where id in (select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente);
  delete from contratos where cliente_id=p_cliente;
  delete from op_log where entidad_id = any(v_ids);
  insert into data_ops_log(tenant_id,operacion,target_label,afectados,backup_id,actor_id,actor_label)
    values (v_tenant,'limpiar_cliente',v_label,v_afectados,v_backup_id,auth.uid(),p_actor_label);
  return jsonb_build_object('ok',true,'backup_id',v_backup_id,'afectados',v_afectados,'target_label',v_label);
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- EJECUTAR — eliminar contrato (un solo contrato; cliente intacto)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_ejecutar_eliminar_contrato(p_contrato uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tenant uuid; v_label text; v_cliente uuid; v_saldo_resto numeric;
        v_snapshot jsonb; v_afectados jsonb; v_backup_id uuid; v_ids uuid[];
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo, id::text), cliente_id into v_tenant, v_label, v_cliente
    from contratos where id=p_contrato;
  if v_tenant is null then raise exception 'Contrato no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El contrato no pertenece al tenant en contexto'; end if;
  -- GUARD de crédito (cross-contrato): el saldo a favor es a nivel CLIENTE y
  -- cruza contratos. Borrar las filas saldos_favor de ESTE contrato (cascade)
  -- sin las del otro contrato descuadraría el libro. Bloqueamos si, al sacar
  -- las filas de este contrato, el saldo restante del cliente quedaría NEGATIVO
  -- (= este contrato originó crédito que se consumió en otro contrato).
  select coalesce(sum(case
           when tipo='acreditado' then monto
           when tipo in ('aplicado','devuelto','condonado','revertido') then -monto
           else 0 end), 0)
    into v_saldo_resto
    from saldos_favor
   where cliente_id = v_cliente
     and (contrato_id is null or contrato_id <> p_contrato);
  if v_saldo_resto < -0.005 then
    raise exception 'No se puede eliminar solo este contrato: el cliente tiene crédito a favor que cruza contratos y quedaría inconsistente (saldo negativo). Usá "Eliminar cliente completo" o pedí ayuda.';
  end if;
  select array_agg(id) into v_ids from (
    select id from contratos where id=p_contrato
    union select id from cuotas where contrato_id=p_contrato
    union select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato
    union select r.id from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato
    union select id from contrato_suspensiones where contrato_id=p_contrato) x;
  v_snapshot := jsonb_build_object(
    'contratos',(select coalesce(jsonb_agg(t),'[]') from contratos t where t.id=p_contrato),
    'cuotas',(select coalesce(jsonb_agg(t),'[]') from cuotas t where t.contrato_id=p_contrato),
    'pagos',(select coalesce(jsonb_agg(p),'[]') from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'recibos',(select coalesce(jsonb_agg(r),'[]') from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'cargos_extra',(select coalesce(jsonb_agg(ce),'[]') from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.contrato_id=p_contrato),
    'notificaciones_mora',(select coalesce(jsonb_agg(nm),'[]') from notificaciones_mora nm join cuotas c on c.id=nm.cuota_id where c.contrato_id=p_contrato),
    'contrato_suspensiones',(select coalesce(jsonb_agg(t),'[]') from contrato_suspensiones t where t.contrato_id=p_contrato),
    'saldos_favor',(select coalesce(jsonb_agg(t),'[]') from saldos_favor t where t.contrato_id=p_contrato),
    'op_log',(select coalesce(jsonb_agg(o),'[]') from op_log o where o.entidad_id = any(v_ids)));
  v_afectados := jsonb_build_object(
    'contratos', 1,
    'cuotas',(select count(*) from cuotas where contrato_id=p_contrato),
    'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.contrato_id=p_contrato),
    'suspensiones',(select count(*) from contrato_suspensiones where contrato_id=p_contrato),
    'historial',(select count(*) from op_log o where o.entidad_id = any(v_ids)));
  insert into data_op_backups(tenant_id,operacion,target_label,snapshot,actor_id,actor_label)
    values (v_tenant,'eliminar_contrato',v_label,v_snapshot,auth.uid(),p_actor_label) returning id into v_backup_id;
  delete from pagos where id in (select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato);
  delete from contratos where id=p_contrato;
  delete from op_log where entidad_id = any(v_ids);
  insert into data_ops_log(tenant_id,operacion,target_label,afectados,backup_id,actor_id,actor_label)
    values (v_tenant,'eliminar_contrato',v_label,v_afectados,v_backup_id,auth.uid(),p_actor_label);
  return jsonb_build_object('ok',true,'backup_id',v_backup_id,'afectados',v_afectados,'target_label',v_label);
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- EJECUTAR — eliminar cliente (borra TODO + el cliente)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_ejecutar_eliminar_cliente(p_cliente uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tenant uuid; v_label text; v_snapshot jsonb; v_afectados jsonb; v_backup_id uuid; v_ids uuid[];
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  select array_agg(id) into v_ids from (
    select p_cliente as id
    union select id from contratos where cliente_id=p_cliente
    union select id from cuotas where cliente_id=p_cliente
    union select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select r.id from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select cs.id from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente) x;
  v_snapshot := jsonb_build_object(
    'cliente',(select coalesce(jsonb_agg(t),'[]') from clientes t where t.id=p_cliente),
    'contratos',(select coalesce(jsonb_agg(t),'[]') from contratos t where t.cliente_id=p_cliente),
    'cuotas',(select coalesce(jsonb_agg(t),'[]') from cuotas t where t.cliente_id=p_cliente),
    'pagos',(select coalesce(jsonb_agg(p),'[]') from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select coalesce(jsonb_agg(r),'[]') from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos_extra',(select coalesce(jsonb_agg(ce),'[]') from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'notificaciones_mora',(select coalesce(jsonb_agg(nm),'[]') from notificaciones_mora nm join cuotas c on c.id=nm.cuota_id where c.cliente_id=p_cliente),
    'contrato_suspensiones',(select coalesce(jsonb_agg(cs),'[]') from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'cliente_etiquetas',(select coalesce(jsonb_agg(t),'[]') from cliente_etiquetas t where t.cliente_id=p_cliente),
    'fotos_cliente',(select coalesce(jsonb_agg(t),'[]') from fotos_cliente t where t.cliente_id=p_cliente),
    'visitas',(select coalesce(jsonb_agg(t),'[]') from visitas t where t.cliente_id=p_cliente),
    'saldos_favor',(select coalesce(jsonb_agg(t),'[]') from saldos_favor t where t.cliente_id=p_cliente),
    'op_log',(select coalesce(jsonb_agg(o),'[]') from op_log o where o.entidad_id = any(v_ids)));
  v_afectados := jsonb_build_object(
    'cliente', 1,
    'contratos',(select count(*) from contratos where cliente_id=p_cliente),
    'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
    'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'etiquetas',(select count(*) from cliente_etiquetas where cliente_id=p_cliente),
    'fotos',(select count(*) from fotos_cliente where cliente_id=p_cliente),
    'visitas',(select count(*) from visitas where cliente_id=p_cliente),
    'historial',(select count(*) from op_log o where o.entidad_id = any(v_ids)));
  insert into data_op_backups(tenant_id,operacion,target_label,snapshot,actor_id,actor_label)
    values (v_tenant,'eliminar_cliente',v_label,v_snapshot,auth.uid(),p_actor_label) returning id into v_backup_id;
  delete from pagos where id in (select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente);
  delete from clientes where id=p_cliente;
  delete from op_log where entidad_id = any(v_ids);
  insert into data_ops_log(tenant_id,operacion,target_label,afectados,backup_id,actor_id,actor_label)
    values (v_tenant,'eliminar_cliente',v_label,v_afectados,v_backup_id,auth.uid(),p_actor_label);
  return jsonb_build_object('ok',true,'backup_id',v_backup_id,'afectados',v_afectados,'target_label',v_label);
end; $fn$;

commit;

-- Verificación: las 6 funciones existen con la firma nueva (p_tenant).
select proname, pronargs from pg_proc
 where proname like 'super_admin_%_cliente' or proname like 'super_admin_%_contrato'
 order by proname;


-- >>> Migration: 0148_colchon_ancla_ultima_pagada.sql <<<
-- 0148 — Colchón de indefinidos: anclar a max(última pagada, mes actual) + 3.
--
-- Hasta 0142 la cantidad de cuotas de un INDEFINIDO se calculaba sólo contra
-- `current_date` (mes actual + 3). Eso NO contemplaba el pago POR ADELANTADO:
-- si un cliente paga jun→sep (4 meses), el colchón debía correrse a oct·nov·dic
-- (3 después de la ÚLTIMA pagada), no quedarse en mes_actual+3. Esta migración:
--   (a) re-ancla la generación a `GREATEST(meses_hasta_hoy, meses_hasta_última
--       _pagada)` → siempre 3 cuotas después de la más nueva entre el mes
--       actual y la última cuota pagada;
--   (b) hace el BACKFILL de todos los indefinidos activos (idempotente, ON
--       CONFLICT DO NOTHING) para curar los que hoy están sin colchón.
--
-- Es el lado server (trigger al crear + cron mensual) del fix; el ESPEJO OFFLINE
-- vive en `lib/data/utils/colchon_indefinido.dart` (mismo ancla), que corre al
-- crear el contrato y al cobrar — los triggers Postgres no corren en SQLite.
-- Idempotente: CREATE OR REPLACE + el backfill sólo agrega lo que falta.

CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(p_contrato_id uuid, p_meses integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_num_cuotas    int;          -- cuántas cuotas generar
  v_creadas       int := 0;
  v_primer_mes    date;         -- mes de vencimiento de la 1ª cuota (mes sig. a instalación)
  v_periodo       date;         -- mes de vencimiento de la cuota i
  v_vencimiento   date;
  v_inserto       boolean;
  v_ult_pagada    date;         -- período de la última cuota PAGADA (NULL si no hay)
  v_meses_ancla   int;          -- meses desde primer_mes hasta el ancla (hoy o última pagada)
  v_colchon       constant int := 3;  -- meses adelante a pregenerar (indefinidos)
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  -- Contrato no activo (cancelado/suspendido): no generar nada nuevo.
  IF v_contrato.estado IS DISTINCT FROM 'activo' THEN
    RETURN 0;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes de vencimiento de la PRIMERA cuota = mes siguiente a la instalación
  -- (facturación vencida; se deriva de fecha_inicio, autoridad del dinero).
  v_primer_mes := (date_trunc('month', v_contrato.fecha_inicio) + interval '1 month')::date;

  -- Cuántas cuotas generar.
  IF p_meses IS NOT NULL THEN
    v_num_cuotas := p_meses;
  ELSIF v_contrato.duracion_meses IS NOT NULL THEN
    -- Fijo: exactamente duracion_meses cuotas (invariante de dinero #5).
    v_num_cuotas := v_contrato.duracion_meses;
  ELSE
    -- Indefinido: desde el primer mes hasta el ANCLA + colchón. El ancla es la
    -- más nueva entre el mes actual y la última cuota con ALGÚN pago (pagada o
    -- parcial) → un adelanto, aun parcial, corre el colchón (siempre 3 después
    -- de la última con pago). GREATEST(3,…): piso de 3 cuotas SIEMPRE, aun con
    -- instalación futura. (Espejo Dart: lib/data/utils/colchon_indefinido.dart.)
    SELECT MAX(periodo) INTO v_ult_pagada
      FROM public.cuotas
     WHERE contrato_id = p_contrato_id AND estado IN ('pagada', 'parcial');

    v_meses_ancla :=
      ((extract(year  from current_date)::int - extract(year  from v_primer_mes)::int) * 12
     +  (extract(month from current_date)::int - extract(month from v_primer_mes)::int));

    IF v_ult_pagada IS NOT NULL THEN
      v_meses_ancla := GREATEST(
        v_meses_ancla,
        ((extract(year  from v_ult_pagada)::int - extract(year  from v_primer_mes)::int) * 12
       +  (extract(month from v_ult_pagada)::int - extract(month from v_primer_mes)::int))
      );
    END IF;

    v_num_cuotas := GREATEST(3, v_meses_ancla + 1 + v_colchon);
  END IF;

  FOR i IN 0 .. v_num_cuotas - 1 LOOP
    v_periodo := (v_primer_mes + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    INSERT INTO public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) VALUES (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    ON CONFLICT (contrato_id, periodo) DO NOTHING;

    GET DIAGNOSTICS v_inserto = ROW_COUNT;
    IF v_inserto THEN
      v_creadas := v_creadas + 1;
    END IF;
  END LOOP;

  RETURN v_creadas;
END;
$function$;

-- Backfill: regenerar el colchón de TODOS los indefinidos activos con la fórmula
-- nueva. Cura los que hoy están sin las 3 cuotas. Idempotente (ON CONFLICT).
SELECT public.generar_cuotas_contrato(c.id)
  FROM public.contratos c
 WHERE c.estado = 'activo' AND c.duracion_meses IS NULL;


-- >>> Migration: 0149_cobrador_lectura_tenant.sql <<<
-- 0149 — Cobrador con lectura de TODO el tenant (#4).
--
-- Decisión de producto: los cobradores comparten las vistas de Cobros / Mapa /
-- Clientes con los admins y ven TODOS los clientes del tenant (no solo su ruta
-- asignada). Su ruta sigue siendo su foco operativo, pero pueden ver — y cobrar —
-- a cualquier cliente. Lo ÚNICO que NO pueden es EDITAR información (clientes/
-- contratos/cuotas siguen siendo write = admin/admin_cobranza), igual que hoy.
--
-- Esta migración SOLO relaja la LECTURA (SELECT) del cobrador a tenant-wide.
-- Es segura por sí sola: PowerSync replica respetando RLS, así que mientras el
-- bucket `por_cobrador` siga bajando solo su slice, el comportamiento no cambia.
-- La VISIBILIDAD real se activa cuando se deployan las sync rules tenant-wide
-- (powersync/sync-rules.yaml) — ese es el paso manual de Rubén en PowerSync.
--
-- Escritura: SIN cambios. pagos_insert_propio ya permite que el cobrador cobre
-- a CUALQUIER cuota auto-estampándose como cobrador_id = auth.uid() (invariante
-- #11, quién-cobró). Las cuotas las recalcula el trigger server desde pagos.

-- Helper: ¿es personal de cobranza (admin / admin_cobranza / cobrador)?
-- Son los roles que operan la cartera y ahora comparten la lectura completa.
-- El técnico y admin_tickets NO entran (no ven dinero; su acceso lo dan sus
-- propios buckets/políticas de tickets).
create or replace function public.is_personal_cobranza() returns boolean
language sql stable security definer
set search_path = public, pg_temp as $$
  select public.current_user_rol() in ('admin','admin_cobranza','cobrador')
$$;

-- clientes
drop policy "clientes_read" on public.clientes;
create policy "clientes_read" on public.clientes
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- contratos
drop policy "contratos_read" on public.contratos;
create policy "contratos_read" on public.contratos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- cuotas
drop policy "cuotas_read" on public.cuotas;
create policy "cuotas_read" on public.cuotas
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- pagos
drop policy "pagos_read" on public.pagos;
create policy "pagos_read" on public.pagos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- recibos
drop policy "recibos_read" on public.recibos;
create policy "recibos_read" on public.recibos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- cargos_extra
drop policy "cargos_read" on public.cargos_extra;
create policy "cargos_read" on public.cargos_extra
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- notificaciones_mora (lectura; la marca de "vista" sigue como estaba)
drop policy "notif_read" on public.notificaciones_mora;
create policy "notif_read" on public.notificaciones_mora
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );


-- >>> Migration: 0150_vencimiento_mas_viejo.sql <<<
-- 0150: precalcular `vencimiento_mas_viejo` por cliente (Opción 2 — mapa rápido)
--
-- QUÉ: la FECHA de vencimiento de la cuota pendiente/parcial MÁS VIEJA de cada
-- cliente, contando solo contratos activos (+ cuotas manuales sin contrato).
-- Es la MISMA condición que el LEFT JOIN cuotas del mapa.
--
-- POR QUÉ: el mapa calculaba el estado de cada pin cruzando TODAS las cuotas de
-- 4.442 clientes + GROUP BY (lento, ~16s en "Ver todo", peor en teléfonos). Con
-- esta columna el cliente lee 1 fecha por pin y deriva el estado al vuelo.
--
-- CLAVE: guardamos una FECHA (dato), NO un estado ni un color.
--  * El ESTADO (mora/gracia/hoy/próxima/fuera de rango/sin deuda) lo deriva el
--    CLIENTE de esta fecha + diasGracia/diasVisibles (mismo `_estadoDe`).
--  * El COLOR sigue saliendo del setting configurable `coloresEstados` al
--    renderizar — acá NO se hardcodea nada de color.
--  * Como es una fecha (date-independent), NO hace falta cron diario: el color
--    se computa contra "hoy" en cada apertura → siempre al día, aun offline.
--
-- El dominante = la cuota más vieja (precedencia mora>gracia>hoy>próxima por
-- antigüedad de vencimiento) → con MIN(vencimiento) alcanza para el color.

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS vencimiento_mas_viejo date;

-- Recalcula la columna para UN cliente. SECURITY DEFINER: el trigger debe poder
-- escribir `clientes` aunque el usuario que dispara el cambio (p.ej. un cobrador
-- registrando un pago) no tenga UPDATE directo sobre `clientes` por RLS. El
-- cliente_id viene siempre de la cuota/contrato del propio tenant → sin fuga
-- cross-tenant. search_path fijo por seguridad (SECURITY DEFINER).
CREATE OR REPLACE FUNCTION public.recalc_vencimiento_mas_viejo(p_cliente_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.clientes c
     SET vencimiento_mas_viejo = (
       SELECT MIN(cu.fecha_vencimiento)
         FROM public.cuotas cu
         LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
        WHERE cu.cliente_id = p_cliente_id
          AND cu.estado IN ('pendiente', 'parcial')
          AND COALESCE(ct.estado, 'activo') = 'activo'
     )
   WHERE c.id = p_cliente_id;
$$;

-- Trigger en cuotas: cualquier cambio que afecte el set pendiente/vencimiento
-- recalcula el cliente (y el viejo si el cliente_id cambió o en DELETE).
CREATE OR REPLACE FUNCTION public.trg_cuotas_vmv()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.recalc_vencimiento_mas_viejo(OLD.cliente_id);
    RETURN OLD;
  END IF;
  PERFORM public.recalc_vencimiento_mas_viejo(NEW.cliente_id);
  IF TG_OP = 'UPDATE' AND NEW.cliente_id IS DISTINCT FROM OLD.cliente_id THEN
    PERFORM public.recalc_vencimiento_mas_viejo(OLD.cliente_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cuotas_vmv ON public.cuotas;
CREATE TRIGGER cuotas_vmv
  AFTER INSERT OR DELETE OR
        UPDATE OF estado, fecha_vencimiento, contrato_id, cliente_id
  ON public.cuotas
  FOR EACH ROW EXECUTE FUNCTION public.trg_cuotas_vmv();

-- Trigger en contratos: suspender/reactivar/cancelar cambia qué cuotas cuentan
-- → recalcula el cliente.
CREATE OR REPLACE FUNCTION public.trg_contratos_vmv()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM public.recalc_vencimiento_mas_viejo(NEW.cliente_id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS contratos_vmv ON public.contratos;
CREATE TRIGGER contratos_vmv
  AFTER UPDATE OF estado ON public.contratos
  FOR EACH ROW
  WHEN (NEW.estado IS DISTINCT FROM OLD.estado)
  EXECUTE FUNCTION public.trg_contratos_vmv();

-- Backfill de todos los clientes existentes (UPDATE directo, no dispara el
-- trigger de cuotas).
UPDATE public.clientes c
   SET vencimiento_mas_viejo = (
     SELECT MIN(cu.fecha_vencimiento)
       FROM public.cuotas cu
       LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
      WHERE cu.cliente_id = c.id
        AND cu.estado IN ('pendiente', 'parcial')
        AND COALESCE(ct.estado, 'activo') = 'activo'
   );


-- >>> Migration: 0151_cambio_plan_setting.sql <<<
-- 0151 — Toggle super_admin para el "Cambio de plan" del contrato.
--
-- Setting 'cobranza.cambio_plan_habilitado' (boolean, default FALSE = opt-in): el
-- super_admin lo prende por tenant para que admin/admin_cobranza vean el botón
-- "Cambiar plan" en el Detalle de contrato. El panel SOLO dibuja claves con fila
-- → hay que sembrarla (R6): helper idempotente + backfill a todos los tenants +
-- enganche al seed de tenants nuevos. categoria 'cobranza' (la tab Avanzado lee
-- esa categoría). Default FALSE: no aparece hasta que el super_admin lo prenda.
-- Calca exacto el molde de 0134 (avisos_habilitado).

begin;

create or replace function public.seed_settings_cambio_plan_0151(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.cambio_plan_habilitado','false'::jsonb,'boolean','cobranza','Muestra el botón "Cambiar plan" en el detalle de contrato a admin/admin_cobranza','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_cambio_plan_0151(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0134).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_cambio_plan_0151(new.id);   -- [0151]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación dentro de la transacción.
select 'tenants_sin_cambio_plan' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.cambio_plan_habilitado')
union all
select 'cambio_plan_editable_por_ok', count(*)
  from public.settings where clave='cobranza.cambio_plan_habilitado' and editable_por='super_admin';

commit;


-- >>> Migration: 0152_fix_seed_trigger_completo.sql <<<
-- 0152 — Fix: tenants_seed_settings_trg() perdió 5 seed calls en 0151.
--
-- REGRESIÓN (hallada en el audit pre-merge de cambio-de-plan): 0151 hizo
-- CREATE OR REPLACE del trigger de seed partiendo del cuerpo VIEJO de 0134, y al
-- hacerlo DROPEÓ del provisioning de tenants nuevos las llamadas agregadas por
-- 0135/0137/0139/0141/0145: notif (WhatsApp manual), WhatsApp Cloud API +
-- bodies, reportes detallados y los 4 toggles de campos de búsqueda. Los 3
-- tenants vivos NO se afectan (sus settings ya estaban backfilleados por esas
-- migraciones), pero todo tenant CREADO de ahora en más nacería sin esas filas
-- → el panel "solo dibuja claves con fila" (R6) las ocultaría y quedarían
-- inconfigurables. Este fix repone el cuerpo COMPLETO (= 0145 + cambio_plan_0151).
--
-- Regla de proceso (para no repetirlo): al CREATE OR REPLACE de una función
-- ACUMULATIVA, partir SIEMPRE de la ÚLTIMA definición vigente (grep del último
-- CREATE OR REPLACE de esa función en migrations/), no de la que el comentario
-- recuerde. Las 13 funciones seed referenciadas existen en PROD (verificado).

begin;

create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);                -- [0135] repuesta
  perform public.seed_settings_whatsapp_api_0137(new.id);         -- [0137] repuesta
  perform public.seed_settings_whatsapp_api_body_0139(new.id);    -- [0139] repuesta
  perform public.seed_settings_reportes_0141(new.id);             -- [0141] repuesta
  perform public.seed_settings_busqueda_0145(new.id);             -- [0145] repuesta
  perform public.seed_settings_cambio_plan_0151(new.id);          -- [0151]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Backfill defensivo: por si algún tenant se creó en la ventana en que el trigger
-- estuvo regresado (0151 → ahora). Las 5 funciones son idempotentes (insert WHERE
-- NOT EXISTS) → no-op para los tenants que ya las tienen.
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_notif_0135(t.id);
    perform public.seed_settings_whatsapp_api_0137(t.id);
    perform public.seed_settings_whatsapp_api_body_0139(t.id);
    perform public.seed_settings_reportes_0141(t.id);
    perform public.seed_settings_busqueda_0145(t.id);
  end loop;
end $$;

-- Verificación dentro de la transacción: el cuerpo del trigger debe referenciar
-- de nuevo las 5 funciones repuestas + cambio_plan, y ningún tenant real debe
-- quedar sin las claves muestra (notif, busqueda, reportes, whatsapp).
select 'trg_refs_5_repuestas+cambio_plan' as chk,
  (pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_notif_0135%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_whatsapp_api_0137%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_whatsapp_api_body_0139%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_reportes_0141%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_busqueda_0145%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_cambio_plan_0151%') as ok
union all
select 'tenants_reales_sin_busqueda_por_telefono',
  (select count(*) = 0 from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
     and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='busqueda.por_telefono'))
union all
select 'tenants_reales_sin_reportes_detallados',
  (select count(*) = 0 from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
     and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.reportes_detallados'));

commit;


-- >>> Migration: 0153_verificar_invariantes_rpc.sql <<<
-- 0153 — RPC `super_admin_verificar_invariantes`: corre los 17 invariantes de
-- dinero SCOPEADOS a un tenant, desde la app (módulo Operaciones → "Verificar
-- invariantes de dinero"). Read-only, SECURITY DEFINER + gate is_super_admin()
-- (patrón 0147). Espeja supabase/tests/invariantes_dinero.sql, pero agrega
-- `AND <tabla>.tenant_id = p_tenant` en CADA check para verificar SOLO el tenant
-- en contexto (el impersonado) tras un fix, sin abrir el SQL Editor del Dashboard.
--
-- Devuelve 1 fila por invariante: (invariante, violaciones, ejemplo_ids). Si
-- TODAS dan violaciones=0, el tenant está contablemente sano. Si alguna > 0,
-- ejemplo_ids trae hasta 10 IDs ofensores. La fórmula de cada check es IDÉNTICA
-- al script de tests (no se relaja ninguna regla) — solo se scopea por tenant.

create or replace function public.super_admin_verificar_invariantes(p_tenant uuid)
returns table(invariante text, violaciones bigint, ejemplo_ids text)
language plpgsql security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  inv1 as (
    select 'INV1: entregado = aplicado + vuelto (pagos)'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(string_agg(id::text, ', ' order by id), '')::text as ejemplo_ids
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and abs((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50
           limit 10) t
  ),
  inv2 as (
    select 'INV2: cuota.monto_pagado = SUM(pagos aplicados)'::text,
           count(*)::bigint,
           coalesce(string_agg(cuota_id::text, ', ' order by cuota_id), '')::text
    from (select cu.id as cuota_id
            from public.cuotas cu
            left join (select cuota_id, sum(monto_cordobas) as pagado
                         from public.pagos where anulado = false group by cuota_id) p
              on p.cuota_id = cu.id
           where cu.tenant_id = p_tenant and cu.estado <> 'anulada'
             and abs(cu.monto_pagado - coalesce(p.pagado, 0)) > 0.01
           limit 10) t
  ),
  inv3 as (
    select 'INV3: estado de cuota coherente con monto_pagado'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and ((estado = 'pagada'    and monto_pagado < (monto + coalesce(cargos_neto,0)) - 0.01)
               or (estado = 'pendiente' and monto_pagado > 0.01)
               or (estado = 'parcial'   and (monto_pagado <= 0.01
                     or monto_pagado >= (monto + coalesce(cargos_neto,0)) - 0.01)))
           limit 10) t
  ),
  inv4 as (
    select 'INV4: ninguna cuota con sobrepago (monto_pagado > total)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and monto_pagado > (monto + coalesce(cargos_neto,0)) + 0.01
           limit 10) t
  ),
  inv5 as (
    select 'INV5: todo pago no anulado tiene recibo'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select p.id from public.pagos p
           where p.tenant_id = p_tenant and p.anulado = false
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)
           limit 10) p
  ),
  inv6 as (
    select 'INV6: vuelto_cordobas >= 0'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and vuelto_cordobas < 0 limit 10) t
  ),
  inv7 as (
    select 'INV7: correlativo de recibo único por cobrador+prefijo'::text,
           count(*)::bigint,
           coalesce(string_agg(numero_completo, ', ' order by numero_completo), '')::text
    from (select numero_completo from public.recibos
           where tenant_id = p_tenant
           group by cobrador_id, prefijo, correlativo, numero_completo
           having count(*) > 1
           limit 10) t
  ),
  inv8 as (
    select 'INV8: contrato.cobrador_id = cliente.cobrador_id'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
            join public.clientes c on c.id = ct.cliente_id
           where ct.tenant_id = p_tenant and ct.estado = 'activo'
             and ct.cobrador_id is distinct from c.cobrador_id
           limit 10) t
  ),
  inv9 as (
    -- Solo cuotas OPERATIVAS (pendiente/parcial): el trigger 0122 congela el
    -- cobrador de las pagadas/anuladas al reasignar (auditoría) → su mismatch es
    -- esperado, no un bug. "Quién cobró" = pagos/recibos.cobrador_id (INV5/INV7).
    select 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select cu.id from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
           where cu.tenant_id = p_tenant and cu.contrato_id is not null
             and cu.estado in ('pendiente','parcial')
             and cu.cobrador_id is distinct from ct.cobrador_id
           limit 10) cu
  ),
  inv10 as (
    select 'INV10: tenant_id de hija == tenant_id de su padre (0082)'::text,
           count(*)::bigint,
           coalesce(string_agg(ofensor, ', ' order by ofensor), '')::text
    from (
      select 'pago:' || p.id::text as ofensor
        from public.pagos p join public.cuotas cu on cu.id = p.cuota_id
       where p.tenant_id = p_tenant and p.cuota_id is not null and p.tenant_id <> cu.tenant_id
      union all
      select 'recibo:' || r.id::text
        from public.recibos r join public.pagos p on p.id = r.pago_id
       where r.tenant_id = p_tenant and r.pago_id is not null and r.tenant_id <> p.tenant_id
      union all
      select 'cargo:' || ce.id::text
        from public.cargos_extra ce join public.cuotas cu on cu.id = ce.cuota_id
       where ce.tenant_id = p_tenant and ce.cuota_id is not null and ce.tenant_id <> cu.tenant_id
      limit 10) t
  ),
  inv11 as (
    select 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is not null and ct.duracion_meses > 0
             and ((select count(*) from public.cuotas cu
                     where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                       and cu.estado <> 'anulada')
                  + (select count(*) from public.cuotas cu
                       where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                         and cu.estado = 'anulada' and cu.motivo_anulacion = 'Suspensión temporal'))
                 <> ct.duracion_meses
           limit 10) t
  ),
  inv12 as (
    select 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant
             and abs(coalesce((select sum(cu.monto_pagado) from public.cuotas cu
                                where cu.contrato_id = ct.id), 0)
                   - coalesce((select sum(pa.monto_cordobas) from public.pagos pa
                                join public.cuotas cu2 on cu2.id = pa.cuota_id
                               where cu2.contrato_id = ct.id and pa.anulado = false), 0)) > 0.01
           limit 10) t
  ),
  inv13 as (
    select 'INV13: cargos origen=ajuste son descuento_* con motivo no vacío'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ce.id from public.cargos_extra ce
           where ce.tenant_id = p_tenant and ce.origen = 'ajuste'
             and (ce.tipo not in ('descuento_monto', 'descuento_porcentaje')
                  or ce.descripcion is null or btrim(ce.descripcion) = '')
           limit 10) t
  ),
  inv14 as (
    select 'INV14: cuotas.cargos_neto == SUM real de cargos_extra'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select cu.id from public.cuotas cu
           where cu.tenant_id = p_tenant
             and abs(coalesce(cu.cargos_neto, 0)
                   - coalesce((select sum(case
                         when ce.tipo in ('reconexion','otro') then ce.monto
                         when ce.tipo in ('descuento_monto','descuento_porcentaje','credito_aplicado') then -ce.monto
                         else 0 end)
                        from public.cargos_extra ce where ce.cuota_id = cu.id), 0)) > 0.01
           limit 10) t
  ),
  inv15 as (
    select 'INV15: saldo a favor del cliente nunca negativo'::text,
           count(*)::bigint,
           coalesce(string_agg(cliente_id::text, ', ' order by cliente_id), '')::text
    from (select cliente_id from public.saldos_favor
           where tenant_id = p_tenant
           group by cliente_id
           having sum(case when tipo = 'acreditado' then monto else -monto end) < -0.005
           limit 10) t
  ),
  inv16 as (
    select 'INV16: ningún pago con método de crédito (crédito no es pago)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and metodo not in ('efectivo','transferencia','deposito','tarjeta')
           limit 10) t
  ),
  inv17 as (
    select 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchón)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is null
             and (select count(*) from public.cuotas cu
                   where cu.contrato_id = ct.id and cu.estado = 'pendiente'
                     and cu.tipo_cargo_manual is null
                     and cu.periodo > greatest(
                       date_trunc('month', (now() at time zone 'America/Managua'))::date,
                       coalesce((select max(cu2.periodo) from public.cuotas cu2
                                  where cu2.contrato_id = ct.id
                                    and cu2.estado in ('pagada', 'parcial')), '1900-01-01'::date))) < 3
           limit 10) t
  )
  select * from inv1
  union all select * from inv2
  union all select * from inv3
  union all select * from inv4
  union all select * from inv5
  union all select * from inv6
  union all select * from inv7
  union all select * from inv8
  union all select * from inv9
  union all select * from inv10
  union all select * from inv11
  union all select * from inv12
  union all select * from inv13
  union all select * from inv14
  union all select * from inv15
  union all select * from inv16
  union all select * from inv17
  order by invariante;
end;
$fn$;


-- >>> Migration: 0154_reasignar_cobrador_masivo.sql <<<
-- 0154 — Reasignar cobrador en masa (módulo Operaciones, super_admin). Mueve
-- TODOS los clientes de un cobrador (o de "sin cobrador") a otro, de un golpe.
-- El UPDATE de clientes.cobrador_id dispara el trigger 0002
-- (trg_propagate_cobrador_id_clientes) que propaga a contratos y cuotas → la
-- denormalización queda consistente (INV8/INV9) y PowerSync mueve las filas al
-- nuevo cobrador. NO toca dinero ni el historial de QUIÉN cobró
-- (pagos/recibos.cobrador_id intactos): cobrador_id de cliente es ORGANIZATIVO.
--
-- Patrón data-ops (0147): SECURITY DEFINER + gate is_super_admin() + p_tenant +
-- preview (cuenta) + ejecutar (log en data_ops_log, sin backup — es reversible
-- corriendo la operación inversa). NULL = "sin cobrador" (admin-managed).

-- ── PREVIEW: cuántos clientes se reasignarían ──────────────────────────────
create or replace function public.super_admin_preview_reasignar_cobrador(
  p_tenant uuid, p_origen uuid, p_destino uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is not distinct from p_destino then
    raise exception 'El cobrador de origen y el de destino son el mismo';
  end if;
  if p_destino is not null and not exists (
       select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El cobrador de destino no existe, no está activo, o no es de este tenant';
  end if;
  if p_origen is not null and not exists (
       select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El cobrador de origen no pertenece a este tenant';
  end if;
  select count(*) into v_afectados from clientes
    where tenant_id = p_tenant and cobrador_id is not distinct from p_origen;
  v_origen_label  := case when p_origen  is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_origen) end;
  v_destino_label := case when p_destino is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_destino) end;
  return jsonb_build_object(
    'afectados', v_afectados,
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;

-- ── EJECUTAR: reasigna + registra en data_ops_log ──────────────────────────
create or replace function public.super_admin_ejecutar_reasignar_cobrador(
  p_tenant uuid, p_origen uuid, p_destino uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is not distinct from p_destino then
    raise exception 'El cobrador de origen y el de destino son el mismo';
  end if;
  if p_destino is not null and not exists (
       select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El cobrador de destino no existe, no está activo, o no es de este tenant';
  end if;
  if p_origen is not null and not exists (
       select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El cobrador de origen no pertenece a este tenant';
  end if;
  v_origen_label  := case when p_origen  is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_origen) end;
  v_destino_label := case when p_destino is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_destino) end;
  -- El UPDATE dispara trg_propagate_cobrador_id_clientes (0002) por cada fila →
  -- propaga a contratos/cuotas. Filtro tenant_id: el super_admin impersonando
  -- tiene clientes de varios tenants en su SQLite, pero acá es server-side y el
  -- UPDATE solo toca los del tenant en contexto.
  with upd as (
    update clientes set cobrador_id = p_destino
     where tenant_id = p_tenant and cobrador_id is not distinct from p_origen
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay clientes asignados a "%" para reasignar', v_origen_label;
  end if;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reasignar_cobrador',
            v_origen_label || ' → ' || v_destino_label,
            jsonb_build_object('clientes', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object(
    'ok', true,
    'afectados', jsonb_build_object('clientes', v_afectados),
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;


-- >>> Migration: 0155_restaurar_backup.sql <<<
-- 0155 — Restaurar un backup de data-ops (módulo Operaciones, super_admin).
-- Deshace un borrado (limpiar_cliente / eliminar_contrato / eliminar_cliente)
-- re-insertando el snapshot jsonb de data_op_backups. El RPC ya guardaba el
-- snapshot (0146/0147) pero NO había forma de revertirlo desde la app — solo
-- SQL manual sobre el jsonb. Esto cierra ese ciclo.
--
-- CLAVE — triggers desactivados durante la re-inserción
-- (`session_replication_role = replica`): si los triggers corrieran, insertar el
-- contrato dispararía la GENERACIÓN de cuotas (→ duplicados) y el insert de pagos/
-- cargos recalcularía monto_pagado/cargos_neto. El snapshot YA es contablemente
-- consistente (se capturó del estado real antes de borrar) → lo restauramos TAL
-- CUAL. Tras restaurar conviene correr "Verificar invariantes" (0153).
--
-- ROBUSTO: `on conflict do nothing` (no pisa data actual ni falla si algo ya
-- existe → idempotente, re-restaurar es no-op) y `jsonb_populate_recordset` (drift
-- de schema OK: columna nueva → NULL/default; columna vieja en el jsonb → ignorada).
-- Orden de tablas = orden FK (padres antes que hijos). 'cliente' → tabla clientes.

create or replace function public.super_admin_restaurar_backup(
  p_backup_id uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  v_tenant uuid; v_operacion text; v_label text; v_snapshot jsonb;
  v_restaurados jsonb := '{}'::jsonb; v_total int := 0;
  v_orden text[] := array[
    'cliente','contratos','cuotas','pagos','recibos','cargos_extra',
    'contrato_suspensiones','notificaciones_mora','saldos_favor',
    'cliente_etiquetas','fotos_cliente','visitas','op_log'];
  v_key text; v_table text; v_rows jsonb; v_n int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  select tenant_id, operacion, target_label, snapshot
    into v_tenant, v_operacion, v_label, v_snapshot
    from data_op_backups where id = p_backup_id;
  if v_tenant is null then raise exception 'El respaldo no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El respaldo no pertenece al tenant en contexto'; end if;

  set local session_replication_role = replica;

  foreach v_key in array v_orden loop
    v_rows := v_snapshot -> v_key;
    if v_rows is null or jsonb_typeof(v_rows) <> 'array' or jsonb_array_length(v_rows) = 0 then
      continue;
    end if;
    v_table := case when v_key = 'cliente' then 'clientes' else v_key end;
    execute format(
      'insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1) '
      'on conflict do nothing', v_table, v_table) using v_rows;
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    v_restaurados := v_restaurados || jsonb_build_object(v_key, v_n);
  end loop;

  set local session_replication_role = origin;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'restaurar', 'Restauró: ' || v_label, v_restaurados, p_backup_id, auth.uid(), p_actor_label);

  return jsonb_build_object(
    'ok', true,
    'operacion_original', v_operacion,
    'target_label', v_label,
    'restaurados', v_restaurados,
    'total', v_total);
end; $fn$;


-- >>> Migration: 0156_verificar_invariantes_inventario.sql <<<
-- 0156 — RPC `super_admin_verificar_invariantes_inventario`: chequeos de
-- integridad ESTRUCTURAL del inventario (seriales + ledger de movimientos),
-- scopeados a un tenant, desde el módulo Operaciones. Read-only, SECURITY
-- DEFINER + gate is_super_admin() (mismo patrón que 0153 para dinero). Es el
-- hermano de la verificación de dinero: el inventario NO tenía red de seguridad.
--
-- Devuelve 1 fila por invariante: (invariante, violaciones, ejemplo_ids). Si
-- TODAS dan violaciones=0, el stock está estructuralmente sano. ejemplo_ids trae
-- hasta 10 IDs ofensores.
--
-- Recordatorio del modelo: el stock se DERIVA (serializado = COUNT en_stock;
-- granel = Σdestino − Σorigen del ledger append-only inv_movimientos). Estos
-- chequeos validan la COHERENCIA de seriales y movimientos, no recalculan stock.
-- Estados del serial: en_stock | instalado | danado | retirado | baja (terminal).

create or replace function public.super_admin_verificar_invariantes_inventario(p_tenant uuid)
returns table(invariante text, violaciones bigint, ejemplo_ids text)
language plpgsql security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  invi1 as (
    select 'INVI1: serial en_stock tiene ubicación'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(string_agg(id::text, ', ' order by id), '')::text as ejemplo_ids
    from (select id from public.inv_seriales
           where tenant_id = p_tenant and estado = 'en_stock' and ubicacion_id is null
           limit 10) t
  ),
  invi2 as (
    select 'INVI2: serial instalado tiene cliente'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_seriales
           where tenant_id = p_tenant and estado = 'instalado' and cliente_id is null
           limit 10) t
  ),
  invi3 as (
    -- 'baja' es terminal (equipo fuera de circulación) → no debe seguir "en" un
    -- cliente. La op "Dar de baja" (módulo Operaciones) limpia cliente_id.
    select 'INVI3: serial dado de baja no conserva cliente'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_seriales
           where tenant_id = p_tenant and estado = 'baja' and cliente_id is not null
           limit 10) t
  ),
  invi4 as (
    select 'INVI4: serial pertenece a un producto serializado'::text,
           count(*)::bigint,
           coalesce(string_agg(s.id::text, ', ' order by s.id), '')::text
    from (select s.id from public.inv_seriales s
            join public.inv_productos p on p.id = s.producto_id
           where s.tenant_id = p_tenant and p.es_serializado = false
           limit 10) s
  ),
  invi5 as (
    select 'INVI5: tenant_id de hija == tenant_id de su padre'::text,
           count(*)::bigint,
           coalesce(string_agg(ofensor, ', ' order by ofensor), '')::text
    from (
      select 'serial:' || s.id::text as ofensor
        from public.inv_seriales s join public.inv_productos p on p.id = s.producto_id
       where s.tenant_id = p_tenant and s.tenant_id <> p.tenant_id
      union all
      select 'mov:' || m.id::text
        from public.inv_movimientos m join public.inv_productos p on p.id = m.producto_id
       where m.tenant_id = p_tenant and m.tenant_id <> p.tenant_id
      union all
      select 'mov-serial:' || m.id::text
        from public.inv_movimientos m join public.inv_seriales s on s.id = m.serial_id
       where m.tenant_id = p_tenant and m.serial_id is not null and m.tenant_id <> s.tenant_id
      limit 10) t
  ),
  invi6 as (
    select 'INVI6: movimiento con serial coincide en producto'::text,
           count(*)::bigint,
           coalesce(string_agg(m.id::text, ', ' order by m.id), '')::text
    from (select m.id from public.inv_movimientos m
            join public.inv_seriales s on s.id = m.serial_id
           where m.tenant_id = p_tenant and m.serial_id is not null
             and m.producto_id <> s.producto_id
           limit 10) m
  ),
  invi7 as (
    select 'INVI7: todo movimiento tiene cantidad positiva'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_movimientos
           where tenant_id = p_tenant and cantidad <= 0
           limit 10) t
  ),
  invi8 as (
    -- Transferencia = mueve de un lado a otro: exige origen y destino, distintos.
    select 'INVI8: transferencia tiene origen y destino distintos'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_movimientos
           where tenant_id = p_tenant and tipo = 'transferencia'
             and (ubicacion_origen_id is null or ubicacion_destino_id is null
                  or ubicacion_origen_id = ubicacion_destino_id)
           limit 10) t
  )
  select * from invi1
  union all select * from invi2
  union all select * from invi3
  union all select * from invi4
  union all select * from invi5
  union all select * from invi6
  union all select * from invi7
  union all select * from invi8
  order by invariante;
end;
$fn$;


-- >>> Migration: 0157_verificar_invariantes_tickets.sql <<<
-- 0157 — RPC `super_admin_verificar_invariantes_tickets`: chequeos de integridad
-- de TICKETS + Incidentes (estado, SLA, fechas, vínculo a incidentes), scopeados
-- a un tenant, desde el módulo Operaciones. Read-only, SECURITY DEFINER + gate
-- is_super_admin() (patrón 0153). Tickets no tenía red de seguridad: un device
-- con reloj mal o un ticket colgado de un incidente resuelto pasaban inadvertidos.
--
-- Devuelve 1 fila por invariante: (invariante, violaciones, ejemplo_ids). Todas
-- en 0 = tickets sanos. OJO SLA wall-clock: created_at es device-time local-naive
-- (parseTicketWallClock) — el chequeo de "fecha futura" usa un margen amplio
-- (2 días) para no marcar falsos positivos por huso horario (Nicaragua UTC-6).
-- Estados ticket: abierto|asignado|en_progreso|en_espera|resuelto|cerrado|reabierto|cancelado.

create or replace function public.super_admin_verificar_invariantes_tickets(p_tenant uuid)
returns table(invariante text, violaciones bigint, ejemplo_ids text)
language plpgsql security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  invt1 as (
    -- Reloj de device adelantado → ticket nace con fecha futura → SLA monstruo.
    select 'INVT1: ningún ticket con fecha de creación futura'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(string_agg(id::text, ', ' order by id), '')::text as ejemplo_ids
    from (select id from public.tickets
           where tenant_id = p_tenant and created_at > now() + interval '2 days'
           limit 10) t
  ),
  invt2 as (
    select 'INVT2: pausa de SLA (segundos_pausado) no negativa'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant and coalesce(segundos_pausado, 0) < 0
           limit 10) t
  ),
  invt3 as (
    -- El outage se resolvió pero un ticket suyo sigue activo → foto incorrecta.
    select 'INVT3: ningún ticket activo en un incidente ya resuelto'::text,
           count(*)::bigint,
           coalesce(string_agg(t.id::text, ', ' order by t.id), '')::text
    from (select t.id from public.tickets t
            join public.incidentes i on i.id = t.incidente_id
           where t.tenant_id = p_tenant
             and t.estado not in ('resuelto', 'cerrado', 'cancelado')
             and i.estado = 'resuelto'
           limit 10) t
  ),
  invt4 as (
    select 'INVT4: ticket asignado tiene técnico'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant and estado = 'asignado' and asignado_a is null
           limit 10) t
  ),
  invt5 as (
    select 'INVT5: tenant_id de hija == tenant_id del ticket'::text,
           count(*)::bigint,
           coalesce(string_agg(ofensor, ', ' order by ofensor), '')::text
    from (
      select 'evento:' || e.id::text as ofensor
        from public.ticket_eventos e join public.tickets t on t.id = e.ticket_id
       where e.tenant_id = p_tenant and e.tenant_id <> t.tenant_id
      union all
      select 'material:' || m.id::text
        from public.ticket_materiales m join public.tickets t on t.id = m.ticket_id
       where m.tenant_id = p_tenant and m.tenant_id <> t.tenant_id
      union all
      select 'adjunto:' || a.id::text
        from public.ticket_adjuntos a join public.tickets t on t.id = a.ticket_id
       where a.tenant_id = p_tenant and a.tenant_id <> t.tenant_id
      limit 10) t
  ),
  invt6 as (
    select 'INVT6: fechas coherentes (resuelto antes de cerrado)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant
             and resuelto_en is not null and cerrado_en is not null
             and resuelto_en > cerrado_en
           limit 10) t
  ),
  invt7 as (
    -- Por la matriz de transiciones, todo cierre pasa por 'resuelto' → tiene fecha.
    select 'INVT7: ticket resuelto/cerrado tiene fecha de resolución'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant and estado in ('resuelto', 'cerrado')
             and resuelto_en is null
           limit 10) t
  )
  select * from invt1
  union all select * from invt2
  union all select * from invt3
  union all select * from invt4
  union all select * from invt5
  union all select * from invt6
  union all select * from invt7
  order by invariante;
end;
$fn$;


-- >>> Migration: 0158_reasignar_tecnico_masivo.sql <<<
-- 0158 — Reasignar técnico en masa (módulo Operaciones, super_admin). Mueve los
-- tickets ACTIVOS de un técnico a otro, de un golpe. Gemelo de 0154 (reasignar
-- cobrador), para el módulo de tickets. El UPDATE de tickets.asignado_a dispara
-- trg_tickets_eventos_auto (un evento 'asignado' por ticket → audit). NO cambia
-- el estado del ticket, así que NO pasa por la matriz de transiciones.
--
-- Solo tickets ACTIVOS (estado NOT IN resuelto/cerrado/cancelado): en los tickets
-- terminados, asignado_a es el registro histórico de quién lo trabajó y NO se
-- toca (igual que el trigger 0122 congela el cobrador de las cuotas pagadas).
--
-- Patrón data-ops (0147/0154): SECURITY DEFINER + gate is_super_admin() +
-- p_tenant + preview (cuenta) + ejecutar (log en data_ops_log, reversible
-- corriéndolo al revés). Origen y destino son cobradores (staff) del tenant.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reasignar_tecnico(
  p_tenant uuid, p_origen uuid, p_destino uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí el técnico de origen'; end if;
  if p_destino is null then raise exception 'Elegí el técnico de destino'; end if;
  if p_origen = p_destino then raise exception 'El técnico de origen y el de destino son el mismo'; end if;
  if not exists (select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El técnico de destino no existe, no está activo, o no es de este tenant';
  end if;
  if not exists (select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El técnico de origen no pertenece a este tenant';
  end if;
  select count(*) into v_afectados from tickets
    where tenant_id = p_tenant and asignado_a = p_origen
      and estado not in ('resuelto', 'cerrado', 'cancelado');
  select coalesce(nombre, id::text) into v_origen_label  from cobradores where id = p_origen;
  select coalesce(nombre, id::text) into v_destino_label from cobradores where id = p_destino;
  return jsonb_build_object(
    'afectados', v_afectados,
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reasignar_tecnico(
  p_tenant uuid, p_origen uuid, p_destino uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí el técnico de origen'; end if;
  if p_destino is null then raise exception 'Elegí el técnico de destino'; end if;
  if p_origen = p_destino then raise exception 'El técnico de origen y el de destino son el mismo'; end if;
  if not exists (select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El técnico de destino no existe, no está activo, o no es de este tenant';
  end if;
  if not exists (select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El técnico de origen no pertenece a este tenant';
  end if;
  select coalesce(nombre, id::text) into v_origen_label  from cobradores where id = p_origen;
  select coalesce(nombre, id::text) into v_destino_label from cobradores where id = p_destino;
  with upd as (
    update tickets set asignado_a = p_destino
     where tenant_id = p_tenant and asignado_a = p_origen
       and estado not in ('resuelto', 'cerrado', 'cancelado')
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay tickets activos asignados a "%" para reasignar', v_origen_label;
  end if;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reasignar_tecnico',
            v_origen_label || ' → ' || v_destino_label,
            jsonb_build_object('tickets', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object(
    'ok', true,
    'afectados', jsonb_build_object('tickets', v_afectados),
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;


-- >>> Migration: 0159_transferencia_masiva_seriales.sql <<<
-- 0159 — Transferencia masiva de equipos entre ubicaciones (módulo Operaciones,
-- super_admin). Mueve TODOS los seriales en_stock de una ubicación a otra, de un
-- golpe. Por cada serial: (1) inserta un movimiento 'transferencia' en el ledger
-- append-only (origen → destino), (2) actualiza inv_seriales.ubicacion_id. El
-- orden importa: primero los movimientos (capturan el origen real), después el
-- UPDATE. Respeta el guard de transiciones (en_stock cambia ubicación libremente;
-- un 'instalado' NO se transfiere — por eso solo en_stock).
--
-- Caso de uso: consolidar bodegas o redistribuir la custodia de un técnico que
-- se va. Patrón data-ops (0147/0154): SECURITY DEFINER + gate + p_tenant +
-- preview (cuenta) + ejecutar (log). Reversible corriéndolo al revés.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_transferir_serial(
  p_tenant uuid, p_origen uuid, p_destino uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí la ubicación de origen'; end if;
  if p_destino is null then raise exception 'Elegí la ubicación de destino'; end if;
  if p_origen = p_destino then raise exception 'La ubicación de origen y la de destino son la misma'; end if;
  if not exists (select 1 from inv_ubicaciones where id = p_destino and tenant_id = p_tenant and activa = true) then
    raise exception 'La ubicación de destino no existe, no está activa, o no es de este tenant';
  end if;
  if not exists (select 1 from inv_ubicaciones where id = p_origen and tenant_id = p_tenant) then
    raise exception 'La ubicación de origen no pertenece a este tenant';
  end if;
  select count(*) into v_afectados from inv_seriales
    where tenant_id = p_tenant and estado = 'en_stock' and ubicacion_id = p_origen;
  select nombre into v_origen_label  from inv_ubicaciones where id = p_origen;
  select nombre into v_destino_label from inv_ubicaciones where id = p_destino;
  return jsonb_build_object(
    'afectados', v_afectados,
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_transferir_serial(
  p_tenant uuid, p_origen uuid, p_destino uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí la ubicación de origen'; end if;
  if p_destino is null then raise exception 'Elegí la ubicación de destino'; end if;
  if p_origen = p_destino then raise exception 'La ubicación de origen y la de destino son la misma'; end if;
  if not exists (select 1 from inv_ubicaciones where id = p_destino and tenant_id = p_tenant and activa = true) then
    raise exception 'La ubicación de destino no existe, no está activa, o no es de este tenant';
  end if;
  if not exists (select 1 from inv_ubicaciones where id = p_origen and tenant_id = p_tenant) then
    raise exception 'La ubicación de origen no pertenece a este tenant';
  end if;
  select nombre into v_origen_label  from inv_ubicaciones where id = p_origen;
  select nombre into v_destino_label from inv_ubicaciones where id = p_destino;

  -- 1. Movimientos PRIMERO (mientras los seriales todavía están en el origen).
  insert into inv_movimientos(
    id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_origen_id, ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  select gen_random_uuid(), s.tenant_id, 'transferencia', s.producto_id, s.id, 1,
         p_origen, p_destino, 'Transferencia masiva (Operaciones)', auth.uid(), now(), now()
    from inv_seriales s
   where s.tenant_id = p_tenant and s.estado = 'en_stock' and s.ubicacion_id = p_origen;

  -- 2. UPDATE de la ubicación denormalizada del serial.
  with upd as (
    update inv_seriales set ubicacion_id = p_destino
     where tenant_id = p_tenant and estado = 'en_stock' and ubicacion_id = p_origen
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay equipos en stock en "%" para transferir', v_origen_label;
  end if;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'transferir_serial',
            v_origen_label || ' → ' || v_destino_label,
            jsonb_build_object('equipos', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object(
    'ok', true,
    'afectados', jsonb_build_object('equipos', v_afectados),
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;


-- >>> Migration: 0160_cerrar_tickets_viejos.sql <<<
-- 0160 — Cerrar (cancelar) tickets viejos sin actividad en masa (módulo
-- Operaciones, super_admin). Cancela los tickets en estados transitivos
-- (abierto/asignado/en_progreso/en_espera/reabierto — NUNCA 'resuelto', que cierra
-- por otro carril) que llevan > N días sin actividad: creados hace más de N días
-- Y sin ningún ticket_evento en los últimos N días. Limpia el histórico de
-- trabajos atascados o nunca iniciados.
--
-- El UPDATE a 'cancelado' pasa por la matriz de transiciones (todos los estados
-- de scope → cancelado son válidos) y dispara el auto-evento 'cancelado' por
-- ticket. Patrón data-ops: SECURITY DEFINER + gate + p_tenant + preview + log.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_cerrar_tickets_viejos(
  p_tenant uuid, p_dias int)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_cutoff timestamptz;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_dias is null or p_dias < 1 then raise exception 'Indicá un número de días válido (>= 1)'; end if;
  v_cutoff := now() - (p_dias || ' days')::interval;
  select count(*) into v_afectados from tickets t
   where t.tenant_id = p_tenant
     and t.estado in ('abierto','asignado','en_progreso','en_espera','reabierto')
     and t.created_at < v_cutoff
     and not exists (select 1 from ticket_eventos e
                      where e.ticket_id = t.id and e.ocurrido_en >= v_cutoff);
  return jsonb_build_object('afectados', v_afectados,
    'label', case when v_afectados = 0
      then 'No hay tickets sin actividad de más de ' || p_dias || ' días.'
      else 'Se cancelarán ' || v_afectados || ' ticket(s) sin actividad de más de ' || p_dias || ' días.' end);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_cerrar_tickets_viejos(
  p_tenant uuid, p_dias int, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_cutoff timestamptz;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_dias is null or p_dias < 1 then raise exception 'Indicá un número de días válido (>= 1)'; end if;
  v_cutoff := now() - (p_dias || ' days')::interval;
  with upd as (
    update tickets t set estado = 'cancelado'
     where t.tenant_id = p_tenant
       and t.estado in ('abierto','asignado','en_progreso','en_espera','reabierto')
       and t.created_at < v_cutoff
       and not exists (select 1 from ticket_eventos e
                        where e.ticket_id = t.id and e.ocurrido_en >= v_cutoff)
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay tickets sin actividad de más de % días para cancelar', p_dias;
  end if;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'cerrar_tickets_viejos',
            'Sin actividad > ' || p_dias || ' días',
            jsonb_build_object('tickets', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_afectados,
    'mensaje', v_afectados || ' ticket(s) cancelados.');
end; $fn$;


-- >>> Migration: 0161_reabrir_ticket.sql <<<
-- 0161 — Reabrir un ticket cerrado/cancelado por error (módulo Operaciones,
-- super_admin), identificado por su correlativo (#N visible en la app). El
-- UPDATE estado='reabierto' pasa por la matriz (cerrado→reabierto y
-- cancelado→reabierto son válidas) y dispara el auto-evento 'reabierto'. Solo
-- aplica a cerrados/cancelados (los activos no se reabren).
--
-- Patrón data-ops: SECURITY DEFINER + gate + p_tenant + preview + log. Contrato
-- del input card: preview→{afectados,label}, ejecutar→{afectados,mensaje}.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reabrir_ticket(
  p_tenant uuid, p_correlativo int)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_titulo text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado, titulo into v_id, v_estado, v_titulo
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el ticket #' || p_correlativo || ' en este tenant.');
  end if;
  if v_estado not in ('cerrado','cancelado') then
    return jsonb_build_object('afectados', 0,
      'label', 'El ticket #' || p_correlativo || ' está "' || v_estado || '": solo se reabren cerrados o cancelados.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se reabrirá el ticket #' || p_correlativo || ' — "' || coalesce(v_titulo,'') || '" (' || v_estado || ').');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reabrir_ticket(
  p_tenant uuid, p_correlativo int, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado into v_id, v_estado
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then raise exception 'No existe el ticket #% en este tenant', p_correlativo; end if;
  if v_estado not in ('cerrado','cancelado') then
    raise exception 'El ticket #% está "%": solo se reabren cerrados o cancelados', p_correlativo, v_estado;
  end if;
  update tickets set estado = 'reabierto' where id = v_id;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reabrir_ticket', 'Ticket #' || p_correlativo,
            jsonb_build_object('tickets', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Ticket #' || p_correlativo || ' reabierto.');
end; $fn$;


-- >>> Migration: 0162_resolver_incidente.sql <<<
-- 0162 — Resolver un incidente y cerrar sus tickets de un golpe (módulo
-- Operaciones, super_admin). Marca el incidente como resuelto (estado='resuelto',
-- fin=now) Y lleva cada uno de sus tickets ACTIVOS a 'resuelto'. Elimina el peor
-- dolor de los cortes masivos: cerrar 50+ tickets a mano.
--
-- Transición por la matriz: en_progreso/en_espera/reabierto → resuelto directo;
-- abierto/asignado pasan por 'en_progreso' (paso intermedio válido) antes de
-- 'resuelto'. Cada UPDATE valida la transición y dispara su auto-evento. Se setea
-- resuelto_en=now() (INVT7). Solo incidentes ABIERTOS.
--
-- afectados=1 cuando el incidente es resolvable (la acción principal SIEMPRE
-- ocurre, aunque tenga 0 tickets) → el botón ejecutar se muestra. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_resolver_incidente(
  p_tenant uuid, p_incidente uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_estado text; v_titulo text; v_activos int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_incidente is null then raise exception 'Elegí el incidente'; end if;
  select estado, titulo into v_estado, v_titulo
    from incidentes where id = p_incidente and tenant_id = p_tenant;
  if v_estado is null then
    return jsonb_build_object('afectados', 0, 'label', 'El incidente no existe en este tenant.');
  end if;
  if v_estado <> 'abierto' then
    return jsonb_build_object('afectados', 0,
      'label', 'El incidente "' || coalesce(v_titulo,'') || '" ya está resuelto.');
  end if;
  select count(*) into v_activos from tickets
    where incidente_id = p_incidente and tenant_id = p_tenant
      and estado in ('abierto','asignado','en_progreso','en_espera','reabierto');
  return jsonb_build_object('afectados', 1,
    'label', 'Se resolverá el incidente "' || coalesce(v_titulo,'') || '" y se cerrarán '
             || v_activos || ' ticket(s) activo(s).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_resolver_incidente(
  p_tenant uuid, p_incidente uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_estado text; v_titulo text; r record; v_cerrados int := 0;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_incidente is null then raise exception 'Elegí el incidente'; end if;
  select estado, titulo into v_estado, v_titulo
    from incidentes where id = p_incidente and tenant_id = p_tenant;
  if v_estado is null then raise exception 'El incidente no existe en este tenant'; end if;
  if v_estado <> 'abierto' then raise exception 'El incidente ya está resuelto'; end if;

  for r in select id, estado from tickets
            where incidente_id = p_incidente and tenant_id = p_tenant
              and estado in ('abierto','asignado','en_progreso','en_espera','reabierto') loop
    if r.estado in ('abierto','asignado') then
      update tickets set estado = 'en_progreso' where id = r.id; -- paso intermedio (matriz)
    end if;
    update tickets set estado = 'resuelto', resuelto_en = now() where id = r.id;
    v_cerrados := v_cerrados + 1;
  end loop;

  update incidentes set estado = 'resuelto', fin = now() where id = p_incidente;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'resolver_incidente',
            'Incidente: ' || coalesce(v_titulo, p_incidente::text),
            jsonb_build_object('tickets', v_cerrados), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_cerrados,
    'mensaje', 'Incidente resuelto. ' || v_cerrados || ' ticket(s) cerrados.');
end; $fn$;


-- >>> Migration: 0163_baja_recuperar_serial.sql <<<
-- 0163 — Dar de baja / recuperar un equipo serializado (módulo Operaciones,
-- super_admin), identificado por su número de serie. Cierra el ciclo de vida del
-- equipo, que estaba incompleto (existía la lista de bajas pero no la ENTRADA a
-- baja). Cada acción genera su movimiento en el ledger append-only + op via
-- data_ops_log. Identificado por serial (match exacto, trim).
--
-- DAR DE BAJA: estado → 'baja' (terminal), limpia cliente_id/contrato_id. NO toca
--   ubicacion_id (si OLD='instalado', cambiar ubicación dispararía el guard de
--   "transferencia tardía"; dejándola quieta, el guard pasa). Movimiento 'baja'.
-- RECUPERAR: 'danado' → 'en_stock' en una ubicación (la del serial, o la primera
--   activa). Movimiento 'ingreso'. (baja es terminal: NO se recupera.)
-- Contrato del input card: preview→{afectados,label}, ejecutar→{afectados,mensaje}.

-- ── DAR DE BAJA: PREVIEW ───────────────────────────────────────────────────
create or replace function public.super_admin_preview_baja_serial(
  p_tenant uuid, p_serial text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_cli text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select s.id, s.estado, c.nombre into v_id, v_estado, v_cli
    from inv_seriales s left join clientes c on c.id = s.cliente_id
   where s.tenant_id = p_tenant and s.serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_estado = 'baja' then
    return jsonb_build_object('afectados', 0, 'label', 'El equipo "' || btrim(p_serial) || '" ya está dado de baja.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se dará de baja el equipo "' || btrim(p_serial) || '" (estado actual: ' || v_estado
             || coalesce(', instalado en ' || v_cli, '') || '). Es terminal.');
end; $fn$;

-- ── DAR DE BAJA: EJECUTAR ──────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_baja_serial(
  p_tenant uuid, p_serial text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_prod uuid; v_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select id, estado, producto_id, ubicacion_id into v_id, v_estado, v_prod, v_ubic
    from inv_seriales where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_estado = 'baja' then raise exception 'El equipo "%" ya está dado de baja', btrim(p_serial); end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_origen_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'baja', v_prod, v_id, 1,
    v_ubic, 'Baja de equipo (Operaciones)', auth.uid(), now(), now());
  -- NO tocamos ubicacion_id (evita el guard de transferencia tardía si era instalado).
  update inv_seriales set estado = 'baja', cliente_id = null, contrato_id = null
   where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'baja_serial', 'Equipo ' || btrim(p_serial),
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Equipo "' || btrim(p_serial) || '" dado de baja.');
end; $fn$;

-- ── RECUPERAR: PREVIEW ─────────────────────────────────────────────────────
create or replace function public.super_admin_preview_recuperar_serial(
  p_tenant uuid, p_serial text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select id, estado into v_id, v_estado
    from inv_seriales where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_estado <> 'danado' then
    return jsonb_build_object('afectados', 0,
      'label', 'El equipo "' || btrim(p_serial) || '" está "' || v_estado || '": solo se recuperan los dañados.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se recuperará el equipo "' || btrim(p_serial) || '" (dañado → en stock).');
end; $fn$;

-- ── RECUPERAR: EJECUTAR ────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_recuperar_serial(
  p_tenant uuid, p_serial text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_prod uuid; v_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select id, estado, producto_id, ubicacion_id into v_id, v_estado, v_prod, v_ubic
    from inv_seriales where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_estado <> 'danado' then
    raise exception 'El equipo "%" está "%": solo se recuperan los dañados', btrim(p_serial), v_estado;
  end if;
  -- destino: la ubicación que tenía, o la primera activa (central primero).
  if v_ubic is null then
    select id into v_ubic from inv_ubicaciones
     where tenant_id = p_tenant and activa = true
     order by (tipo = 'central') desc, nombre limit 1;
  end if;
  if v_ubic is null then raise exception 'No hay ninguna ubicación activa para recuperar el equipo'; end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'ingreso', v_prod, v_id, 1,
    v_ubic, 'Recuperación de equipo dañado (Operaciones)', auth.uid(), now(), now());
  update inv_seriales set estado = 'en_stock', ubicacion_id = v_ubic where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'recuperar_serial', 'Equipo ' || btrim(p_serial),
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Equipo "' || btrim(p_serial) || '" recuperado a stock.');
end; $fn$;


-- >>> Migration: 0164_reconciliar_huerfanos.sql <<<
-- 0164 — Reconciliar seriales huérfanos (módulo Operaciones, super_admin). Los
-- equipos 'instalado' cuyo cliente ya no existe quedan con cliente_id NULL (la FK
-- es ON DELETE SET NULL: borrar/eliminar un cliente deja el serial colgado). Esos
-- huérfanos inflan el conteo y rompen la ficha del equipo. Esta operación los
-- devuelve a stock: estado='en_stock' en una ubicación + movimiento 'devolucion'.
-- (Es el fix de la violación INVI2 = 'instalado sin cliente'.)
--
-- Sin input: preview cuenta los huérfanos, ejecutar los reconcilia todos. La
-- transición instalado→en_stock pasa el guard (no es transferencia tardía: el
-- estado destino ES en_stock). Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reconciliar_huerfanos(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  select count(*) into v_afectados from inv_seriales
   where tenant_id = p_tenant and estado = 'instalado' and cliente_id is null;
  return jsonb_build_object('afectados', v_afectados,
    'label', case when v_afectados = 0
      then 'No hay equipos huérfanos (instalados sin cliente).'
      else 'Se devolverán a stock ' || v_afectados || ' equipo(s) instalado(s) sin cliente.' end);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reconciliar_huerfanos(
  p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_default_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  select id into v_default_ubic from inv_ubicaciones
   where tenant_id = p_tenant and activa = true
   order by (tipo = 'central') desc, nombre limit 1;
  if v_default_ubic is null then raise exception 'No hay ninguna ubicación activa para devolver los equipos'; end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  select gen_random_uuid(), s.tenant_id, 'devolucion', s.producto_id, s.id, 1,
    coalesce(s.ubicacion_id, v_default_ubic), 'Reconciliación de equipo huérfano (Operaciones)',
    auth.uid(), now(), now()
   from inv_seriales s
  where s.tenant_id = p_tenant and s.estado = 'instalado' and s.cliente_id is null;

  with upd as (
    update inv_seriales set estado = 'en_stock', ubicacion_id = coalesce(ubicacion_id, v_default_ubic)
     where tenant_id = p_tenant and estado = 'instalado' and cliente_id is null
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then raise exception 'No hay equipos huérfanos para reconciliar'; end if;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reconciliar_huerfanos', 'Equipos huérfanos → stock',
            jsonb_build_object('equipos', v_afectados), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_afectados,
    'mensaje', v_afectados || ' equipo(s) huérfano(s) devueltos a stock.');
end; $fn$;


-- >>> Migration: 0165_ajuste_conteo_fisico.sql <<<
-- 0165 — Ajuste por conteo físico (módulo Operaciones, super_admin). Para
-- productos GRANEL (es_serializado=false): el admin ingresa lo que contó
-- físicamente en una ubicación, y la operación inserta un movimiento 'ajuste'
-- por la DIFERENCIA contra el stock derivado del ledger. Convierte el "egreso
-- suelto con cuenta a mano" en un flujo claro y auditado.
--
-- Stock granel derivado = Σ(cantidad con destino=U) − Σ(cantidad con origen=U)
-- para ese producto. diff = contado − actual. Si diff>0 → ajuste con destino=U
-- (suma); si diff<0 → ajuste con origen=U (resta). cantidad SIEMPRE positiva
-- (INVI7). Append-only: es un movimiento nuevo, nunca edita. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_ajuste_conteo(
  p_tenant uuid, p_producto uuid, p_ubicacion uuid, p_contado numeric)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_actual numeric; v_diff numeric; v_pnom text; v_unom text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_producto is null then raise exception 'Elegí el producto'; end if;
  if p_ubicacion is null then raise exception 'Elegí la ubicación'; end if;
  if p_contado is null or p_contado < 0 then raise exception 'Indicá la cantidad contada (>= 0)'; end if;
  select nombre into v_pnom from inv_productos
   where id = p_producto and tenant_id = p_tenant and es_serializado = false;
  if v_pnom is null then raise exception 'El producto no existe, no es de este tenant, o es serializado (el conteo es para granel)'; end if;
  select nombre into v_unom from inv_ubicaciones where id = p_ubicacion and tenant_id = p_tenant;
  if v_unom is null then raise exception 'La ubicación no existe o no es de este tenant'; end if;

  select coalesce(sum(case when ubicacion_destino_id = p_ubicacion then cantidad else 0 end), 0)
       - coalesce(sum(case when ubicacion_origen_id  = p_ubicacion then cantidad else 0 end), 0)
    into v_actual
    from inv_movimientos where tenant_id = p_tenant and producto_id = p_producto;
  v_diff := p_contado - v_actual;
  return jsonb_build_object(
    'afectados', case when v_diff = 0 then 0 else 1 end,
    'label', case when v_diff = 0
      then v_pnom || ' en ' || v_unom || ': sistema y conteo coinciden (' || v_actual || '). Sin ajuste.'
      else v_pnom || ' en ' || v_unom || ' — sistema: ' || v_actual || ' · contado: ' || p_contado
           || ' · ajuste: ' || case when v_diff > 0 then '+' else '' end || v_diff end);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_ajuste_conteo(
  p_tenant uuid, p_producto uuid, p_ubicacion uuid, p_contado numeric, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_actual numeric; v_diff numeric; v_pnom text; v_unom text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_producto is null then raise exception 'Elegí el producto'; end if;
  if p_ubicacion is null then raise exception 'Elegí la ubicación'; end if;
  if p_contado is null or p_contado < 0 then raise exception 'Indicá la cantidad contada (>= 0)'; end if;
  select nombre into v_pnom from inv_productos
   where id = p_producto and tenant_id = p_tenant and es_serializado = false;
  if v_pnom is null then raise exception 'El producto no existe, no es de este tenant, o es serializado'; end if;
  select nombre into v_unom from inv_ubicaciones where id = p_ubicacion and tenant_id = p_tenant;
  if v_unom is null then raise exception 'La ubicación no existe o no es de este tenant'; end if;

  select coalesce(sum(case when ubicacion_destino_id = p_ubicacion then cantidad else 0 end), 0)
       - coalesce(sum(case when ubicacion_origen_id  = p_ubicacion then cantidad else 0 end), 0)
    into v_actual
    from inv_movimientos where tenant_id = p_tenant and producto_id = p_producto;
  v_diff := p_contado - v_actual;
  if v_diff = 0 then raise exception 'No hay diferencia entre el sistema (%) y el conteo', v_actual; end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
    ubicacion_origen_id, ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'ajuste', p_producto, abs(v_diff),
    case when v_diff < 0 then p_ubicacion end, case when v_diff > 0 then p_ubicacion end,
    'Conteo físico (Operaciones)', auth.uid(), now(), now());

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'ajuste_conteo', v_pnom || ' @ ' || v_unom,
            jsonb_build_object('ajuste', abs(v_diff)), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1,
    'mensaje', 'Ajuste de ' || case when v_diff > 0 then '+' else '' end || v_diff
               || ' aplicado a ' || v_pnom || ' en ' || v_unom || '.');
end; $fn$;


-- >>> Migration: 0166_corregir_vinculo_serial.sql <<<
-- 0166 — Corregir el cliente/contrato de un equipo instalado (módulo
-- Operaciones, super_admin). Si un serial quedó instalado en el cliente
-- equivocado (homónimo, duplicado en la carga), reasigna cliente_id/contrato_id
-- al correcto. Es una corrección de METADATO (el equipo está físicamente bien),
-- así que NO genera movimiento de inventario.
--
-- El guard de transiciones BLOQUEA cambiar el cliente de un 'instalado' (pide
-- pasar por stock). Como es una corrección deliberada del super_admin (el equipo
-- no se movió), se bypassa con `set local session_replication_role = replica`
-- (mismo patrón que el restore 0155), acotado a este UPDATE. Se valida a mano que
-- el contrato pertenezca al cliente. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_corregir_vinculo(
  p_tenant uuid, p_serial text, p_cliente uuid, p_contrato uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_cur text; v_new text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_cliente is null then raise exception 'Elegí el cliente correcto'; end if;
  select s.id, s.estado, c.nombre into v_id, v_estado, v_cur
    from inv_seriales s left join clientes c on c.id = s.cliente_id
   where s.tenant_id = p_tenant and s.serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_estado <> 'instalado' then
    return jsonb_build_object('afectados', 0,
      'label', 'El equipo "' || btrim(p_serial) || '" está "' || v_estado || '": solo se corrige el vínculo de los instalados.');
  end if;
  select nombre into v_new from clientes where id = p_cliente and tenant_id = p_tenant;
  if v_new is null then raise exception 'El cliente destino no existe o no es de este tenant'; end if;
  if p_contrato is not null and not exists (
       select 1 from contratos where id = p_contrato and cliente_id = p_cliente and tenant_id = p_tenant) then
    raise exception 'El contrato elegido no pertenece a ese cliente';
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Equipo "' || btrim(p_serial) || '" instalado en ' || coalesce(v_cur, '(sin cliente)')
             || ' → se reasigna a ' || v_new || '.');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_corregir_vinculo(
  p_tenant uuid, p_serial text, p_cliente uuid, p_contrato uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_new text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_cliente is null then raise exception 'Elegí el cliente correcto'; end if;
  select id, estado into v_id, v_estado from inv_seriales
   where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_estado <> 'instalado' then
    raise exception 'El equipo "%" está "%": solo se corrige el vínculo de los instalados', btrim(p_serial), v_estado;
  end if;
  select nombre into v_new from clientes where id = p_cliente and tenant_id = p_tenant;
  if v_new is null then raise exception 'El cliente destino no existe o no es de este tenant'; end if;
  if p_contrato is not null and not exists (
       select 1 from contratos where id = p_contrato and cliente_id = p_cliente and tenant_id = p_tenant) then
    raise exception 'El contrato elegido no pertenece a ese cliente';
  end if;

  -- Bypass del guard de transiciones: es corrección de metadato, no movimiento físico.
  set local session_replication_role = replica;
  update inv_seriales set cliente_id = p_cliente, contrato_id = p_contrato where id = v_id;
  set local session_replication_role = origin; -- reactivar guards para el resto (patrón 0155)

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'corregir_vinculo', 'Equipo ' || btrim(p_serial) || ' → ' || v_new,
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Equipo "' || btrim(p_serial) || '" reasignado a ' || v_new || '.');
end; $fn$;


-- >>> Migration: 0167_corregir_estado_serial.sql <<<
-- 0167 — Corregir el estado de un equipo serializado (módulo Operaciones,
-- super_admin). ALTO RIESGO: para datos mal importados (un serial que quedó en
-- un estado que no corresponde). Bypassa el guard de transiciones
-- (session_replication_role=replica) porque una corrección puede requerir una
-- transición que el guard normalmente bloquea (p.ej. revertir una baja errónea).
--
-- Para SERIALIZADOS el stock se deriva del ESTADO (COUNT en_stock), no del
-- ledger, así que cambiar el estado ES el cambio de stock (no hace falta
-- movimiento). Acotado a estados SIN cliente: en_stock | danado | retirado | baja
-- (para 'instalado' usar "Corregir cliente de un equipo", que exige cliente).
-- Al pasar a en_stock/baja se limpia el vínculo al cliente. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_corregir_estado_serial(
  p_tenant uuid, p_serial text, p_estado text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_cur text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_estado is null or p_estado not in ('en_stock','danado','retirado','baja') then
    raise exception 'Estado inválido. Para "instalado" usá Corregir cliente de un equipo';
  end if;
  select id, estado into v_id, v_cur from inv_seriales
   where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_cur = p_estado then
    return jsonb_build_object('afectados', 0, 'label', 'El equipo "' || btrim(p_serial) || '" ya está en estado "' || p_estado || '".');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Equipo "' || btrim(p_serial) || '": ' || v_cur || ' → ' || p_estado || '.');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_corregir_estado_serial(
  p_tenant uuid, p_serial text, p_estado text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_cur text; v_ubic uuid; v_def_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_estado is null or p_estado not in ('en_stock','danado','retirado','baja') then
    raise exception 'Estado inválido. Para "instalado" usá Corregir cliente de un equipo';
  end if;
  select id, estado, ubicacion_id into v_id, v_cur, v_ubic from inv_seriales
   where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_cur = p_estado then raise exception 'El equipo "%" ya está en estado "%"', btrim(p_serial), p_estado; end if;

  if p_estado = 'en_stock' and v_ubic is null then
    select id into v_def_ubic from inv_ubicaciones
     where tenant_id = p_tenant and activa = true order by (tipo = 'central') desc, nombre limit 1;
    if v_def_ubic is null then raise exception 'No hay ubicación activa para poner el equipo en stock'; end if;
  end if;

  set local session_replication_role = replica; -- bypass guard (corrección deliberada)
  update inv_seriales set
    estado = p_estado,
    cliente_id  = case when p_estado in ('en_stock','baja') then null else cliente_id end,
    contrato_id = case when p_estado in ('en_stock','baja') then null else contrato_id end,
    ubicacion_id = case when p_estado = 'en_stock' then coalesce(v_ubic, v_def_ubic) else ubicacion_id end
   where id = v_id;
  set local session_replication_role = origin; -- reactivar guards para el resto (patrón 0155)

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'corregir_estado_serial',
            'Equipo ' || btrim(p_serial) || ': ' || v_cur || ' → ' || p_estado,
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1,
    'mensaje', 'Equipo "' || btrim(p_serial) || '" corregido a "' || p_estado || '".');
end; $fn$;


-- >>> Migration: 0168_corregir_sla_ticket.sql <<<
-- 0168 — Corregir la fecha de creación (y por ende el SLA) de un ticket (módulo
-- Operaciones, super_admin). ALTO RIESGO: muta created_at, que es WALL-CLOCK
-- local-naive y ancla el SLA. Un device con el reloj adelantado hace nacer el
-- ticket con created_at en el futuro → SLA monstruo / ya-vencido. Esta operación
-- reancla la fecha a la correcta y resetea la pausa acumulada (segundos_pausado).
--
-- created_at se setea al MEDIODÍA de la fecha indicada, en UTC (SET LOCAL
-- timezone='UTC'). OJO convención (regla 1b): created_at es timestamptz pero la
-- app lo escribe NAIVE (DateTime.now().toIso8601String(), sin offset) → Postgres
-- lo guarda como-si-UTC y parseTicketWallClock re-lee los COMPONENTES ignorando la
-- Z → el wall-clock local round-trips. Por eso acá NO se convierte vía Managua
-- (guardaría +6h → SLA corrido); se escribe el instante en UTC: '2026-..-.. 12:00:00+00'
-- → la app lee 12:00. NO dispara triggers (created_at no es estado).
-- Bloqueado para cerrados/cancelados (su SLA es histórico). Verificá el SLA en la
-- app tras correrlo. Patrón data-ops. Input: correlativo (#) + fecha AAAA-MM-DD.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_corregir_sla(
  p_tenant uuid, p_correlativo int, p_fecha text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_actual date;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  if p_fecha is null or btrim(p_fecha) = '' then raise exception 'Indicá la fecha (AAAA-MM-DD)'; end if;
  begin perform p_fecha::date; exception when others then raise exception 'Fecha inválida. Usá el formato AAAA-MM-DD'; end;
  select id, estado, created_at::date into v_id, v_estado, v_actual
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el ticket #' || p_correlativo || ' en este tenant.');
  end if;
  if v_estado in ('cerrado','cancelado') then
    return jsonb_build_object('afectados', 0,
      'label', 'El ticket #' || p_correlativo || ' está "' || v_estado || '": su SLA es histórico, no se corrige.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Ticket #' || p_correlativo || ': fecha de creación ' || v_actual || ' → ' || p_fecha::date
             || ' (se reinicia la pausa del SLA).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_corregir_sla(
  p_tenant uuid, p_correlativo int, p_fecha text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  if p_fecha is null or btrim(p_fecha) = '' then raise exception 'Indicá la fecha (AAAA-MM-DD)'; end if;
  begin perform p_fecha::date; exception when others then raise exception 'Fecha inválida. Usá el formato AAAA-MM-DD'; end;
  select id, estado into v_id, v_estado from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then raise exception 'No existe el ticket #% en este tenant', p_correlativo; end if;
  if v_estado in ('cerrado','cancelado') then
    raise exception 'El ticket #% está "%": su SLA es histórico, no se corrige', p_correlativo, v_estado;
  end if;

  set local timezone = 'UTC';
  update tickets set
    created_at = (p_fecha || ' 12:00:00')::timestamptz,
    segundos_pausado = 0,
    en_espera_desde = null
   where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'corregir_sla', 'Ticket #' || p_correlativo || ' → ' || p_fecha::date,
            jsonb_build_object('tickets', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1,
    'mensaje', 'Ticket #' || p_correlativo || ': fecha corregida a ' || p_fecha::date || '. Verificá el SLA en la app.');
end; $fn$;


-- >>> Migration: 0169_anular_ticket_unwind.sql <<<
-- 0169 — Anular un ticket creado por error, devolviendo sus materiales al stock
-- (módulo Operaciones, super_admin). ALTO RIESGO: cascada. Un ticket duplicado
-- al que ya se le consumió material deja el stock incorrecto (el serial quedó
-- 'instalado', el granel descontado) y bloquea devoluciones. Esta operación lo
-- "desenrolla": por cada material consumido inserta un movimiento 'devolucion'
-- (reversa) y, si es serializado, devuelve el equipo a stock; luego cancela el
-- ticket.
--
-- APPEND-ONLY: NO borra las filas de ticket_materiales (quedan como registro del
-- intento); el stock se corrige con los movimientos de devolución. El serial se
-- revierte SOLO si sigue 'instalado' en el cliente del ticket (idempotente, no
-- pisa un equipo reusado). Bloqueado para resuelto/cerrado/cancelado. Patrón
-- data-ops. Input: correlativo (#).

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_anular_ticket(
  p_tenant uuid, p_correlativo int)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_mats int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado into v_id, v_estado from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el ticket #' || p_correlativo || ' en este tenant.');
  end if;
  if v_estado in ('resuelto','cerrado','cancelado') then
    return jsonb_build_object('afectados', 0,
      'label', 'El ticket #' || p_correlativo || ' está "' || v_estado || '": solo se anulan los activos.');
  end if;
  select count(*) into v_mats from ticket_materiales where ticket_id = v_id;
  return jsonb_build_object('afectados', 1,
    'label', 'Ticket #' || p_correlativo || ': se anulará (cancelará) y se devolverán '
             || v_mats || ' material(es) al stock.');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_anular_ticket(
  p_tenant uuid, p_correlativo int, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_cli uuid; v_def uuid; r record; v_devueltos int := 0;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado, cliente_id into v_id, v_estado, v_cli
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then raise exception 'No existe el ticket #% en este tenant', p_correlativo; end if;
  if v_estado in ('resuelto','cerrado','cancelado') then
    raise exception 'El ticket #% está "%": solo se anulan los activos', p_correlativo, v_estado;
  end if;
  select id into v_def from inv_ubicaciones
   where tenant_id = p_tenant and activa = true order by (tipo = 'central') desc, nombre limit 1;

  for r in select * from ticket_materiales where ticket_id = v_id loop
    if coalesce(r.ubicacion_origen_id, v_def) is null then
      raise exception 'No hay ubicación para devolver un material del ticket (sin origen ni ubicación activa)';
    end if;
    if r.serial_id is not null then
      -- Revertir el serial SOLO si sigue instalado en el cliente del ticket.
      update inv_seriales set estado = 'en_stock', cliente_id = null, contrato_id = null,
             ubicacion_id = coalesce(r.ubicacion_origen_id, v_def)
       where id = r.serial_id and tenant_id = p_tenant and estado = 'instalado'
         and cliente_id is not distinct from v_cli;
      if found then
        insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
          ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
        values (gen_random_uuid(), p_tenant, 'devolucion', r.producto_id, r.serial_id, 1,
          coalesce(r.ubicacion_origen_id, v_def), v_id, 'Anulación de ticket (Operaciones)',
          auth.uid(), now(), now());
        v_devueltos := v_devueltos + 1;
      end if;
    else
      -- Granel: devolución de la cantidad consumida.
      insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
        ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
      values (gen_random_uuid(), p_tenant, 'devolucion', r.producto_id, r.cantidad,
        coalesce(r.ubicacion_origen_id, v_def), v_id, 'Anulación de ticket (Operaciones)',
        auth.uid(), now(), now());
      v_devueltos := v_devueltos + 1;
    end if;
  end loop;

  update tickets set estado = 'cancelado' where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'anular_ticket', 'Ticket #' || p_correlativo,
            jsonb_build_object('materiales', v_devueltos), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_devueltos,
    'mensaje', 'Ticket #' || p_correlativo || ' anulado. ' || v_devueltos || ' material(es) devueltos al stock.');
end; $fn$;


-- >>> Migration: 0170_reversar_movimiento.sql <<<
-- 0170 — Reversar un movimiento de inventario mal cargado (módulo Operaciones,
-- super_admin). Para GRANEL: si se cargó mal un ingreso/egreso/ajuste/
-- transferencia, inserta el movimiento INVERSO (NUNCA edita ni borra el original
-- — el ledger es append-only). El stock derivado (Σdestino − Σorigen) se reajusta
-- solo: el inverso usa origen=destino_original y destino=origen_original, misma
-- cantidad, tipo 'ajuste'. Net 0 sobre el original.
--
-- Solo movimientos de GRANEL (serial_id NULL): los de equipos serializados se
-- corrigen con Baja/Recuperar/Corregir estado (su stock se deriva del estado, no
-- del ledger). Patrón data-ops. Input: selector de movimientos granel recientes.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reversar_movimiento(
  p_tenant uuid, p_movimiento uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_tipo text; v_cant numeric; v_serial uuid; v_prod text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_movimiento is null then raise exception 'Elegí el movimiento a reversar'; end if;
  select m.id, m.tipo, m.cantidad, m.serial_id, p.nombre
    into v_id, v_tipo, v_cant, v_serial, v_prod
    from inv_movimientos m join inv_productos p on p.id = m.producto_id
   where m.id = p_movimiento and m.tenant_id = p_tenant;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'El movimiento no existe en este tenant.');
  end if;
  if v_serial is not null then
    return jsonb_build_object('afectados', 0,
      'label', 'Ese movimiento es de un equipo serializado: corregilo con Baja / Recuperar / Corregir estado.');
  end if;
  -- Idempotencia: el motivo de la reversa embebe el id del original.
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%(' || p_movimiento::text || ')%') then
    return jsonb_build_object('afectados', 0, 'label', 'Ese movimiento ya fue reversado.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se reversará: ' || v_tipo || ' ' || v_cant || ' ' || v_prod || ' (se inserta el movimiento inverso).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reversar_movimiento(
  p_tenant uuid, p_movimiento uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_tipo text; v_cant numeric; v_prod uuid; v_serial uuid; v_org uuid; v_dst uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_movimiento is null then raise exception 'Elegí el movimiento a reversar'; end if;
  select id, tipo, cantidad, producto_id, serial_id, ubicacion_origen_id, ubicacion_destino_id
    into v_id, v_tipo, v_cant, v_prod, v_serial, v_org, v_dst
    from inv_movimientos where id = p_movimiento and tenant_id = p_tenant;
  if v_id is null then raise exception 'El movimiento no existe en este tenant'; end if;
  if v_serial is not null then
    raise exception 'Ese movimiento es de un equipo serializado: usá Baja / Recuperar / Corregir estado';
  end if;
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%(' || p_movimiento::text || ')%') then
    raise exception 'Ese movimiento ya fue reversado';
  end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
    ubicacion_origen_id, ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'ajuste', v_prod, v_cant,
    v_dst, v_org, -- inverso: origen=destino_orig, destino=origen_orig
    'Reversa de movimiento ' || v_tipo || ' (' || p_movimiento::text || ')',
    auth.uid(), now(), now());

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reversar_movimiento', 'Reversa: ' || v_tipo || ' ' || v_cant,
            jsonb_build_object('movimientos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Movimiento reversado (' || v_tipo || ' ' || v_cant || ').');
end; $fn$;


-- >>> Migration: 0171_reversar_consumo.sql <<<
-- 0171 — Reversar el consumo de UN material de un ticket (módulo Operaciones,
-- super_admin). Versión fina de "Anular ticket" (0169): si el técnico cargó mal
-- UN material (serial equivocado, pieza no usada), revierte solo ese consumo SIN
-- cancelar el ticket. Por cada consumo: inserta un movimiento 'devolucion'
-- (reversa) y, si es serializado, devuelve el equipo a stock.
--
-- APPEND-ONLY: NO borra la fila de ticket_materiales (queda como registro). El
-- serial se revierte SOLO si sigue 'instalado' en el cliente del ticket
-- (idempotente). Para granel, reversar dos veces duplicaría la devolución — el
-- super_admin lo hace deliberadamente una vez. Patrón data-ops. Input: selector
-- de consumos recientes.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reversar_consumo(
  p_tenant uuid, p_material uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_corr int; v_serial text; v_prod text; v_cant numeric;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_material is null then raise exception 'Elegí el consumo a reversar'; end if;
  select tm.id, t.correlativo, s.serial, p.nombre, tm.cantidad
    into v_id, v_corr, v_serial, v_prod, v_cant
    from ticket_materiales tm
    join tickets t on t.id = tm.ticket_id
    join inv_productos p on p.id = tm.producto_id
    left join inv_seriales s on s.id = tm.serial_id
   where tm.id = p_material and tm.tenant_id = p_tenant;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'El consumo no existe en este tenant.');
  end if;
  -- Idempotencia: la devolución embebe el id del material en el motivo.
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%[' || p_material::text || ']%') then
    return jsonb_build_object('afectados', 0, 'label', 'Ese consumo ya fue reversado.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se reversará el consumo del ticket #' || v_corr || ': '
             || coalesce(v_serial, v_prod || ' ' || v_cant) || ' (vuelve al stock).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reversar_consumo(
  p_tenant uuid, p_material uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tk uuid; v_corr int; v_cli uuid; v_prod uuid; v_serial uuid;
        v_cant numeric; v_org uuid; v_def uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_material is null then raise exception 'Elegí el consumo a reversar'; end if;
  select tm.ticket_id, tm.producto_id, tm.serial_id, tm.cantidad, tm.ubicacion_origen_id,
         t.cliente_id, t.correlativo
    into v_tk, v_prod, v_serial, v_cant, v_org, v_cli, v_corr
    from ticket_materiales tm join tickets t on t.id = tm.ticket_id
   where tm.id = p_material and tm.tenant_id = p_tenant;
  if v_tk is null then raise exception 'El consumo no existe en este tenant'; end if;
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%[' || p_material::text || ']%') then
    raise exception 'Ese consumo ya fue reversado';
  end if;
  select id into v_def from inv_ubicaciones
   where tenant_id = p_tenant and activa = true order by (tipo = 'central') desc, nombre limit 1;
  if coalesce(v_org, v_def) is null then
    raise exception 'No hay ninguna ubicación para devolver el material';
  end if;

  if v_serial is not null then
    update inv_seriales set estado = 'en_stock', cliente_id = null, contrato_id = null,
           ubicacion_id = coalesce(v_org, v_def)
     where id = v_serial and tenant_id = p_tenant and estado = 'instalado'
       and cliente_id is not distinct from v_cli;
    if not found then
      raise exception 'El equipo de ese consumo ya no está instalado en el cliente del ticket (ya se revirtió o se movió)';
    end if;
    insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
      ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
    values (gen_random_uuid(), p_tenant, 'devolucion', v_prod, v_serial, 1,
      coalesce(v_org, v_def), v_tk, 'Reversa de consumo (Operaciones) [' || p_material::text || ']', auth.uid(), now(), now());
  else
    insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
      ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
    values (gen_random_uuid(), p_tenant, 'devolucion', v_prod, v_cant,
      coalesce(v_org, v_def), v_tk, 'Reversa de consumo (Operaciones) [' || p_material::text || ']', auth.uid(), now(), now());
  end if;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reversar_consumo', 'Consumo del ticket #' || v_corr,
            jsonb_build_object('materiales', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Consumo del ticket #' || v_corr || ' reversado.');
end; $fn$;


-- >>> Migration: 0172_tickets_contrato_efecto.sql <<<
-- =========================================================================
-- 0172 — Integración órdenes de trabajo (tickets) ↔ cobranza/servicio (FASE 1)
-- =========================================================================
-- Solo METADATOS para trazabilidad y para derivar las colas. CERO trigger de
-- plata, cero acoplamiento con pagos/cuotas. El cobro y el estado de servicio
-- siguen donde están hoy (cobro→recibo; suspenderContrato/reactivarContrato).
-- El admin encadena las acciones de facturación a mano, asistido por las colas
-- que derivan de estos dos campos.
--   corte→suspensión y pago→reconexión→reactivación quedan MANUALES (con badge).
-- Diseño: factibilidad 2026-06-29 (recomendación "link liviano" + taxonomía de
-- dos puertas). El automatismo por trigger SECURITY DEFINER es Fase 2 (diferido).
--
-- ADITIVO PURO (columnas nullable / con default + índice) → NO se bumpea
-- _dbWipeVersion: PowerSync lo aplica in-place sin re-descargar (política R4).
-- =========================================================================

-- (1) Vínculo de la orden de trabajo a un CONTRATO específico. Hoy `tickets`
--     solo conoce el cliente (0103:130), pero un cliente puede tener varios
--     contratos → sin esto no se sabe QUÉ servicio cortar/reconectar. NULL =
--     instalación pre-contrato / outage / trabajo sin contrato. ON DELETE SET
--     NULL: borrar el contrato no borra la orden de trabajo.
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS contrato_id uuid
    REFERENCES public.contratos(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS tickets_by_contrato
  ON public.tickets (tenant_id, contrato_id);

-- (2) Semántica de SISTEMA sobre el catálogo free-form de tipos (0103:109): qué
--     EFECTO de servicio tiene una orden de ese tipo. Es lo único que permite
--     derivar las colas. 'ninguno' = reparación / reclamo / cualquier trabajo
--     sin efecto en facturación (DEFAULT seguro → los tipos existentes quedan
--     neutros y el admin re-clasifica los que correspondan).
ALTER TABLE public.ticket_tipos
  ADD COLUMN IF NOT EXISTS efecto text NOT NULL DEFAULT 'ninguno'
    CHECK (efecto IN ('ninguno','instalacion','corte','reconexion'));


-- >>> Migration: 0173_cobro_desde_ticket.sql <<<
-- 0173 — Cobro desde el ticket (instalación / reconexión / reinstalación / anexo).
--
-- Modelo (decisión Rubén 2026-06-30): el trabajo de campo nace en un TICKET, así
-- que su cobro+recibo se dispara DESDE el ticket (no desde el cliente). Las
-- multas/otros cargos del admin siguen por el botón del cliente ("Cobro puntual").
--
--   ticket_tipos.precio  → precio DEFAULT del cobro para tickets de ese tipo.
--                          0 = NO cobrable (sin botón). >0 = en el ticket RESUELTO
--                          aparece "Generar cobro" con este monto precargado
--                          (editable). Orthogonal a `efecto` (que sigue manejando
--                          el cambio de estado: corte→suspender, reconexion→reactivar).
--   cuotas.ticket_id     → liga la cuota manual (el cobro puntual) al ticket que la
--                          originó: para el recibo ("Ticket #N") y para no cobrar
--                          dos veces el mismo ticket (la UI chequea si ya hay cobro).
--
-- ADITIVOS (Receta R4): PowerSync los aplica IN-PLACE → NO se bumpea
-- `_dbWipeVersion`. Cadena de integridad: schema.dart + sync-rules (los nuevos
-- campos viajan en los buckets de ticket_tipos/cuotas) + Dart consistente.

ALTER TABLE public.ticket_tipos
  ADD COLUMN IF NOT EXISTS precio numeric NOT NULL DEFAULT 0
    CHECK (precio >= 0);

ALTER TABLE public.cuotas
  ADD COLUMN IF NOT EXISTS ticket_id uuid
    REFERENCES public.tickets(id) ON DELETE SET NULL;

-- El cobro se busca por ticket (¿este ticket ya tiene cobro?) → índice parcial.
CREATE INDEX IF NOT EXISTS cuotas_by_ticket
  ON public.cuotas (ticket_id) WHERE ticket_id IS NOT NULL;


-- >>> Migration: 0174_cargos_extra_cobrador_null.sql <<<
-- 0174 — cargos_extra.cobrador_id acepta NULL (fix rechazo 23502, 2026-07-03)
--
-- BUG: al quitarle el cobrador a un cliente (clientes.cobrador_id = NULL,
-- operación legítima — "admin-managed", §3.5-4b), el trigger de propagación
-- (propagate_cobrador_id_from_cliente, 0122) empuja ese NULL a las 6 tablas
-- denormalizadas. cargos_extra era la ÚNICA de las 6 con NOT NULL → el UPDATE
-- entero rebotaba con 23502 ("null value in column cobrador_id of relation
-- cargos_extra") y el cliente quedaba imposible de des-asignar si tenía
-- cargos/descuentos. Efecto colateral del mismo NOT NULL: tampoco se podía
-- aplicar un cargo/descuento a un cliente sin cobrador (el INSERT desde Dart
-- pasa el cobrador_id de la cuota, que es NULL en admin-managed).
--
-- El cobrador_id de cargos_extra es ORGANIZATIVO (propagado por 0122), igual
-- que sus 5 hermanas nullable (contratos, cuotas, notificaciones_mora,
-- cliente_etiquetas, fotos_cliente). Quién EJECUTÓ el cargo lo captura
-- aplicado_por (NOT NULL sigue intacto). Ningún consumidor agrupa por
-- cargos_extra.cobrador_id (la reportería usa pagos.cobrador_id — §3.5-4b).

ALTER TABLE public.cargos_extra ALTER COLUMN cobrador_id DROP NOT NULL;


-- >>> Migration: 0175_cobro_ticket_unico.sql <<<
-- 0175 — un ticket = un solo cobro vivo (red dura server-side, audit Fase 2)
--
-- BUG (audit 2026-07-05): el anti-doble-cobro del cobro-desde-ticket (0173)
-- era 100% reactivo en la UI (un stream que oculta "Generar cobro" si ya hay
-- una cuota ligada). Sin garantía dura, dos admins / dos devices / un doble-tap
-- podían generar DOS cuotas manuales no-anuladas del MISMO ticket antes de
-- sincronizar → doble cobro de la misma instalación (viola el modelo de dinero).
-- El índice `cuotas_by_ticket` de 0173 era PARCIAL SIMPLE (no UNIQUE).
--
-- Fix: índice UNIQUE parcial. El 2º INSERT (de otro device) es rechazado al
-- reconciliar (23505) y el connector lo descarta → la cuota fantasma se revierte
-- en el próximo sync. Complementa el re-check client-side dentro de la
-- writeTransaction de crearCuotaManual (para el mismo device offline).
--
-- Sólo cuenta las VIVAS: una cuota anulada libera el ticket para re-cobrar
-- (mismo criterio que el stream de la UI: estado <> 'anulada'). Verificado en
-- prod que no hay duplicados vivos antes de crearlo.

CREATE UNIQUE INDEX IF NOT EXISTS cuotas_unico_cobro_ticket
  ON public.cuotas (ticket_id)
  WHERE ticket_id IS NOT NULL AND estado <> 'anulada';


-- >>> Migration: 0176_handle_new_user_roles_tickets.sql <<<
-- 0176 — handle_new_user: soportar roles de tickets + prefijo para admins
--
-- BUG 1 (CRÍTICO, escalación de privilegios — audit Fase 3 2026-07-05):
-- invitar un 'tecnico' o 'admin_tickets' creaba un usuario con rol='admin'.
-- La UI (cobradores) ofrece esos roles y la edge function invitar-cobrador los
-- acepta, pero el trigger handle_new_user (0026) coacciona todo rol fuera de
-- (super_admin,admin,admin_cobranza,cobrador) a 'admin'. El CHECK (0103) y
-- set_cobrador_rol (0140) SÍ se actualizaron con los roles de tickets; el
-- trigger quedó desincronizado → el técnico invitado entraba con acceso total
-- del tenant (clientes, cobros, settings). Fix: agregar 'tecnico','admin_tickets'
-- a la whitelist de v_rol.
--
-- BUG 2 (MEDIO, dato perdido — mismo trigger): al invitar un admin/admin_cobranza
-- con prefijo de recibo, el prefijo se descartaba (solo se guardaba para
-- 'cobrador'). El cliente y la edge function ya lo mandan para los 3 roles que
-- cobran y set_cobrador_rol los trata por igual. Fix: guardar el prefijo para
-- ('cobrador','admin','admin_cobranza').
--
-- Partido del cuerpo VIGENTE (0026:186; 0029/0066 solo lo mencionan en
-- comentarios) — se preserva completo; solo cambian las líneas 208 y 225.
-- Idempotente (CREATE OR REPLACE); no re-descarga nada (no toca schema cliente).

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
begin
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  if v_rol not in ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets') then
    v_rol := 'admin';
  end if;

  if v_rol = 'super_admin' then
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  elsif v_tenant_id is null then
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    v_rol := 'admin';
  end if;

  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol in ('cobrador', 'admin', 'admin_cobranza')
         then v_prefijo else null end,
    true
  )
  on conflict (id) do update
    set tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  return new;
end;
$$;


-- >>> Migration: 0177_cobro_extra_toggle.sql <<<
-- 0177 — Toggle 'cobranza.cobro_extra' (super_admin, Avanzado).
--
-- El "cobro extra" (cobro puntual: multa / otro cargo que decide el admin) se
-- mostraba SIEMPRE: el botón "Cobro extra" en el detalle del cliente y el
-- "Generar cobro" en el detalle de un ticket. Debe ser un módulo que SOLO el
-- super_admin habilita por tenant. Default OFF (= oculto en ambos lados).
-- Mismo patrón que 'cobranza.reportes_detallados' (0141). Aditivo, sin schema.
--
-- El cuerpo del trigger de seed se parte del ÚLTIMO vigente (0152) y solo se
-- AGREGA la nueva llamada (lección 0151→0152: no perder performs).

begin;

create or replace function public.seed_settings_cobro_extra_0177(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, 'cobranza.cobro_extra', 'false'::jsonb, 'boolean', 'cobranza',
         'Habilita el cobro puntual (multa / otro cargo) desde el cliente y desde tickets', 'super_admin'
  where not exists (
    select 1 from public.settings s
     where s.tenant_id = p_tenant and s.clave = 'cobranza.cobro_extra'
  );
end;
$fn$;

do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_cobro_extra_0177(t.id);
  end loop;
end $$;

-- Trigger de seed: cuerpo VIGENTE (0152) + la nueva llamada [0177].
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);                -- [0135] repuesta
  perform public.seed_settings_whatsapp_api_0137(new.id);         -- [0137] repuesta
  perform public.seed_settings_whatsapp_api_body_0139(new.id);    -- [0139] repuesta
  perform public.seed_settings_reportes_0141(new.id);             -- [0141] repuesta
  perform public.seed_settings_busqueda_0145(new.id);             -- [0145] repuesta
  perform public.seed_settings_cambio_plan_0151(new.id);          -- [0151]
  perform public.seed_settings_cobro_extra_0177(new.id);          -- [0177]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

select 'tenants_sin_cobro_extra' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.cobro_extra');

commit;


-- >>> Migration: 0178_colchon_no_backfill_hueco_suspension.sql <<<
-- 0178 — Colchón de indefinidos: NO rellenar el hueco de una suspensión larga.
--
-- BUG (latente, 0 casos en prod): un indefinido suspendido MÁS de 3 meses y
-- luego reactivado queda con un HUECO — los meses de la pausa (entre el colchón
-- anulado al suspender y `mesReactivación`) nunca se crearon (el colchón sólo
-- materializa 3 meses adelante, una pausa larga nunca los alcanza). El generador
-- (esta función + su espejo Dart) arrancaba el loop en `v_primer_mes` y como esos
-- períodos NO existen, el `ON CONFLICT DO NOTHING` no los saltaba → los insertaba
-- como 'pendiente' con vencimiento PASADO = deuda FALSA por meses SIN servicio
-- (viola 0120: los meses suspendidos no se facturan).
--
-- FIX: para un contrato que YA tiene cuotas, no generar NUNCA períodos interiores
-- anteriores al mes SIGUIENTE a la cuota existente más nueva (de cualquier estado)
-- = `v_start`. El único hueco interior posible de un indefinido lo deja una
-- suspensión; `reactivarContrato` siempre crea el colchón desde `mesR+1`, así que
-- el máximo existente cae DESPUÉS del hueco → el piso lo salta. En generación
-- INICIAL (0 cuotas) `v_start = v_primer_mes` → comportamiento intacto. Sólo aplica
-- al ramo INDEFINIDO (los fijos ya nacen con todas sus cuotas contiguas → el hueco
-- de una suspensión existe como fila 'anulada' y el ON CONFLICT ya lo salta).
--
-- Espejo Dart: lib/data/utils/colchon_indefinido.dart (mismo piso). Idempotente:
-- CREATE OR REPLACE. SIN backfill (0 contratos afectados hoy; sólo cambia el
-- comportamiento futuro). Base: 0148 (última definición vigente).

CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(p_contrato_id uuid, p_meses integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_num_cuotas    int;          -- cuántas cuotas generar
  v_creadas       int := 0;
  v_primer_mes    date;         -- mes de vencimiento de la 1ª cuota (mes sig. a instalación)
  v_periodo       date;         -- mes de vencimiento de la cuota i
  v_vencimiento   date;
  v_inserto       boolean;
  v_ult_pagada    date;         -- período de la última cuota PAGADA (NULL si no hay)
  v_meses_ancla   int;          -- meses desde primer_mes hasta el ancla (hoy o última pagada)
  v_colchon       constant int := 3;  -- meses adelante a pregenerar (indefinidos)
  v_max_periodo   date;         -- período de la cuota existente MÁS NUEVA (cualquier estado)
  v_start         date;         -- PISO anti-backfill: no generar períodos < v_start
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  -- Contrato no activo (cancelado/suspendido): no generar nada nuevo.
  IF v_contrato.estado IS DISTINCT FROM 'activo' THEN
    RETURN 0;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes de vencimiento de la PRIMERA cuota = mes siguiente a la instalación
  -- (facturación vencida; se deriva de fecha_inicio, autoridad del dinero).
  v_primer_mes := (date_trunc('month', v_contrato.fecha_inicio) + interval '1 month')::date;

  -- PISO anti-backfill. Default = v_primer_mes (fijos + generación inicial → sin
  -- cambio: v_periodo nunca cae por debajo). Sólo se ELEVA para indefinidos que
  -- ya tienen cuotas (ver bloque ELSE abajo).
  v_start := v_primer_mes;

  -- Cuántas cuotas generar.
  IF p_meses IS NOT NULL THEN
    v_num_cuotas := p_meses;
  ELSIF v_contrato.duracion_meses IS NOT NULL THEN
    -- Fijo: exactamente duracion_meses cuotas (invariante de dinero #5).
    v_num_cuotas := v_contrato.duracion_meses;
  ELSE
    -- Indefinido: desde el primer mes hasta el ANCLA + colchón. El ancla es la
    -- más nueva entre el mes actual y la última cuota con ALGÚN pago (pagada o
    -- parcial) → un adelanto, aun parcial, corre el colchón (siempre 3 después
    -- de la última con pago). GREATEST(3,…): piso de 3 cuotas SIEMPRE, aun con
    -- instalación futura. (Espejo Dart: lib/data/utils/colchon_indefinido.dart.)
    SELECT MAX(periodo) INTO v_ult_pagada
      FROM public.cuotas
     WHERE contrato_id = p_contrato_id AND estado IN ('pagada', 'parcial');

    v_meses_ancla :=
      ((extract(year  from current_date)::int - extract(year  from v_primer_mes)::int) * 12
     +  (extract(month from current_date)::int - extract(month from v_primer_mes)::int));

    IF v_ult_pagada IS NOT NULL THEN
      v_meses_ancla := GREATEST(
        v_meses_ancla,
        ((extract(year  from v_ult_pagada)::int - extract(year  from v_primer_mes)::int) * 12
       +  (extract(month from v_ult_pagada)::int - extract(month from v_primer_mes)::int))
      );
    END IF;

    v_num_cuotas := GREATEST(3, v_meses_ancla + 1 + v_colchon);

    -- ANTI-BACKFILL (0178): si el indefinido YA tiene cuotas, el piso pasa al mes
    -- siguiente a la más nueva. Nunca se rellenan períodos interiores anteriores
    -- (el hueco de una suspensión larga = meses sin servicio → no se facturan).
    SELECT MAX(periodo) INTO v_max_periodo
      FROM public.cuotas WHERE contrato_id = p_contrato_id;
    IF v_max_periodo IS NOT NULL THEN
      v_start := GREATEST(
        v_primer_mes,
        (date_trunc('month', v_max_periodo) + interval '1 month')::date
      );
    END IF;
  END IF;

  FOR i IN 0 .. v_num_cuotas - 1 LOOP
    v_periodo := (v_primer_mes + (i || ' months')::interval)::date;
    -- Piso anti-backfill: no materializar el hueco de una suspensión larga.
    IF v_periodo < v_start THEN
      CONTINUE;
    END IF;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    INSERT INTO public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) VALUES (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    ON CONFLICT (contrato_id, periodo) DO NOTHING;

    GET DIAGNOSTICS v_inserto = ROW_COUNT;
    IF v_inserto THEN
      v_creadas := v_creadas + 1;
    END IF;
  END LOOP;

  RETURN v_creadas;
END;
$function$;


-- >>> Migration: 0179_op_log_append_only_guard.sql <<<
-- 0179 — op_log append-only ENFORCED por trigger (audit F0, 2026-07-09).
--
-- La policy `op_log_update` (0129) existe SOLO para que el upsert idempotente de
-- PowerSync (connector.dart: INSERT ... ON CONFLICT DO UPDATE) pueda reescribir
-- la MISMA fila en un reintento. Pero su USING/CHECK solo valida tenant+actor —
-- NO impide que un cliente, con su propio JWT, PATCHee una fila histórica con
-- contenido DISTINTO. Desde que 0140 eliminó el `audit_log` forense, `op_log` es
-- el ÚNICO registro de cambios y quedó alterable (un cobrador podría reescribir
-- "Cobró C$500" por "C$50" después de sincronizar).
--
-- Guard: rechazar todo UPDATE que MODIFIQUE una fila existente. El re-upsert
-- legítimo reenvía la fila IDÉNTICA (NEW = OLD) → pasa sin ruido. Cualquier
-- cambio real → excepción 23514 (no-retryable: el connector lo descarta y deja
-- RechazoSync, sin loop). NO se guarda DELETE a propósito: la RLS ya lo bloquea
-- para usuarios normales (no hay policy DELETE) y el super lo conserva vía
-- super_admin_all para el tooling de data-ops/restore.

CREATE OR REPLACE FUNCTION public.op_log_append_only_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW IS DISTINCT FROM OLD THEN
    RAISE EXCEPTION
      'op_log es append-only: no se puede modificar una fila existente (id=%)', OLD.id
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS op_log_append_only_upd ON public.op_log;
CREATE TRIGGER op_log_append_only_upd
  BEFORE UPDATE ON public.op_log
  FOR EACH ROW EXECUTE FUNCTION public.op_log_append_only_guard();


-- >>> Migration: 0180_tenants_nombre_unico.sql <<<
-- 0180 — tenants.nombre único case/trim-insensitive, excepto System (audit F0).
--
-- crear-tenant valida vacío/largo/'system'/control-chars pero NO colisión de
-- nombre, y no había UNIQUE → dos tenants podían llamarse igual o quedar con un
-- typo permanente (no hay UI de rename; sí es editable por el super vía la policy
-- super_admin_all de 0026). Este índice impide NUEVOS duplicados. El fold es
-- `lower(trim(...))` (Postgres lower() es unicode-aware — ñ/acentos OK); no se usa
-- unaccent para no depender de la extensión. Excluye el pseudo-tenant System
-- (UUID fijo). Verificado: 0 duplicados en prod al crear el índice.

CREATE UNIQUE INDEX IF NOT EXISTS tenants_nombre_unico
  ON public.tenants (lower(trim(nombre)))
  WHERE id <> '00000000-0000-0000-0000-000000000000';


-- >>> Migration: 0181_revocacion_acceso.sql <<<
-- 0181 — Revocación de acceso real (audit F0, titular CRÍTICO+ALTO).
--
-- HOY "Desactivar" un cobrador (cobradores.activo=false) es cosmético: no corta
-- login (auth intacto), ni sync (sync-rules no filtra activo), ni cobro. Y no
-- existe forma de suspender un tenant que deja de pagar. Esta migración da el
-- lado SERVER del fix v1:
--   (1) tenants.activo — para suspender/reactivar un ISP completo.
--   (2) verificar_acceso() — gate que la app llama al iniciar sesión: si el
--       cobrador o su tenant están inactivos, la app cierra sesión. El super_admin
--       queda SIEMPRE exento (no hay forma de que el dueño se deje afuera).
--   (3) set_tenant_activo() — suspender/reactivar un tenant (solo super_admin).
--   (4) list_tenants_admin() ahora devuelve `activo` (para el toggle del panel).
-- El corte de SYNC del cobrador se hace en sync-rules (AND activo=true en los 6
-- buckets por-cobrador); esta migración es lo de Postgres. El client agrega el
-- gate en el arranque de sesión (fail-open ante error de red).

-- (1) Columna: todos los tenants vivos nacen activos.
ALTER TABLE public.tenants
  ADD COLUMN IF NOT EXISTS activo boolean NOT NULL DEFAULT true;

-- (2) Gate de acceso del usuario actual. SECURITY DEFINER: lee SOLO su propia
-- fila (WHERE id = auth.uid()). El super_admin es SIEMPRE activo. Sin fila →
-- no devuelve nada → el client hace fail-open (no bloquea ante anomalía/red).
CREATE OR REPLACE FUNCTION public.verificar_acceso()
 RETURNS TABLE(cobrador_activo boolean, tenant_activo boolean)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    CASE WHEN c.rol = 'super_admin' THEN true ELSE COALESCE(c.activo, false) END,
    CASE WHEN c.rol = 'super_admin' THEN true ELSE COALESCE(t.activo, true) END
  FROM public.cobradores c
  LEFT JOIN public.tenants t ON t.id = c.tenant_id
  WHERE c.id = auth.uid();
$function$;

REVOKE ALL ON FUNCTION public.verificar_acceso() FROM public;
GRANT EXECUTE ON FUNCTION public.verificar_acceso() TO authenticated;

-- (3) Suspender / reactivar un tenant (solo super_admin; System protegido).
CREATE OR REPLACE FUNCTION public.set_tenant_activo(p_tenant_id uuid, p_activo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_tenant_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'No se puede suspender el tenant System';
  END IF;
  UPDATE public.tenants SET activo = p_activo WHERE id = p_tenant_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_tenant_activo(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_tenant_activo(uuid, boolean) TO authenticated;

-- (4) list_tenants_admin ahora expone `activo` (cambia el return type → DROP+CREATE).
DROP FUNCTION IF EXISTS public.list_tenants_admin();
CREATE FUNCTION public.list_tenants_admin()
returns table (
  id                  uuid,
  nombre              text,
  activo              boolean,
  created_at          timestamptz,
  cobradores_count    bigint,
  modulos_habilitados text[]
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      t.id,
      t.nombre,
      t.activo,
      t.created_at,
      (select count(*) from public.cobradores c
         where c.tenant_id = t.id and c.activo) as cobradores_count,
      coalesce(
        (select array_agg(tm.modulo_codigo order by tm.modulo_codigo)
           from public.tenant_modulos tm
          where tm.tenant_id = t.id and tm.habilitado),
        array[]::text[]
      ) as modulos_habilitados
    from public.tenants t
    where t.id <> '00000000-0000-0000-0000-000000000000'
    order by t.created_at desc;
end;
$$;

revoke all on function public.list_tenants_admin() from public;
grant execute on function public.list_tenants_admin() to authenticated;


-- >>> Migration: 0182_settings_superonly_y_oplog_admin_tickets.sql <<<
-- 0182 — Dos fixes de F0 (settings super-only + historial de admin_tickets).
--
-- (#4) op_log.campos_visibles es una clave SÓLO del super_admin (define qué
-- campos ve el historial de cada tenant), pero el upsert del cliente
-- (settings_repo.dart) hardcodea editable_por='admin' al crearla. La RLS
-- `settings_write_admin` permite escribir cualquier clave con
-- editable_por <> 'super_admin' → un admin del tenant podía sobreescribir esa
-- clave. Fix: marcarla 'super_admin' (el cliente además la crea así de ahora en
-- más — ver settings_repo.upsert(editablePor:)).
UPDATE public.settings
   SET editable_por = 'super_admin'
 WHERE clave = 'op_log.campos_visibles'
   AND editable_por IS DISTINCT FROM 'super_admin';

-- (#6) El rol admin_tickets NO está en op_log_read (is_admin_or_cobranza =
-- admin/admin_cobranza), así que su "Historial de cambios" del ticket abría
-- vacío. Se le da acceso SCOPEADO a op_log SOLO de las entidades que gestiona
-- (tickets/ticket_tipos/incidentes) — NUNCA el op_log de dinero (cobros/pagos),
-- que no debe ver. Esta policy cubre el acceso REST; el bucket por_admin_tickets
-- sincroniza el MISMO subconjunto (sync-rules).
DROP POLICY IF EXISTS op_log_read_admin_tickets ON public.op_log;
CREATE POLICY op_log_read_admin_tickets ON public.op_log
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND public.current_user_rol() = 'admin_tickets'
    AND entidad IN ('tickets', 'ticket_tipos', 'incidentes')
  );


-- >>> Migration: 0183_f1_etiqueta_unica_y_visitas_read.sql <<<
-- 0183 — F1: unicidad de etiqueta case/acento-insensitive + visitas_read alineada.
--
-- (etiquetas) 0122 dejó `UNIQUE(tenant_id, nombre)` case/acento-SENSITIVE, pero el
-- pre-check del cliente pliega con foldSqlExpr (ñ/acentos→ASCII + lower). Dos admins
-- offline (o uno en 2 devices) podían crear "Moroso"/"moroso"/"Morosó": todas pasan
-- el check local y el server las acepta → catálogo con duplicados visuales. Índice
-- canónico que IGUALA foldSqlExpr: lower(translate(...)) es IMMUTABLE. Verificado:
-- 0 colisiones en prod al crear el índice.
--
-- (visitas) `visitas_read` limitaba al cobrador a SUS visitas (cobrador_id=auth.uid()),
-- pero el bucket `por_cobrador` del sync-rules ya le baja TODAS las del tenant (modelo
-- vigente "el cobrador ve todo el tenant", ARQUITECTURA §4b) → la restricción era
-- dead-code offline (RLS y sync decían cosas distintas). Se alinea la RLS a tenant-wide.

CREATE UNIQUE INDEX IF NOT EXISTS etiquetas_nombre_fold_unico
  ON public.etiquetas (
    tenant_id,
    lower(translate(nombre, 'ÑñÁáÉéÍíÓóÚúÜü', 'nnaaeeiioouuuu'))
  );

DROP POLICY IF EXISTS "visitas_read" ON public.visitas;
CREATE POLICY "visitas_read" ON public.visitas
  FOR SELECT USING (tenant_id = public.current_tenant_id());


-- >>> Migration: 0184_mora_sin_churn_diario.sql <<<
-- 0184: mora — eliminar el CHURN DIARIO de sincronización de PowerSync
-- Diagnóstico 2026-07-10: "Data Synced" de PowerSync trepó a 24 GB con solo
-- ~11 dispositivos. Causa #1 medida (pg_stat): notificaciones_mora con 130.289
-- UPDATES en 63 días (5,7× la tabla entera).
--
-- POR QUÉ: el cron diario `actualizar_notificaciones_mora` hacía UPSERT con
-- `ON CONFLICT DO UPDATE SET dias_mora, monto_adeudado`. Como
-- `dias_mora = current_date - fecha_vencimiento - gracia` crece +1 CADA DÍA,
-- todos los días TODAS las filas de mora vencida (~23k) cambian de verdad →
-- PowerSync re-sincroniza la tabla ENTERA a CADA dispositivo, todos los días
-- (y escala con la cartera vencida).
--
-- CLAVE (auditado): los campos GUARDADOS `dias_mora`/`monto_adeudado` son
-- ESCRITURA-MUERTA — NADIE los lee. Los 4 consumidores del cliente (reporte de
-- mora `reporte_mora_pdf`/`reportes_admin_screen`, colas `colas_servicio_provider`,
-- `cola_card`) los calculan EN VIVO desde `cuotas` (`... AS dias_mora`). El
-- estado que SÍ importa (`vista_en`/`resuelta_en`, que alimenta el badge) lo
-- manejan los mirrors del cliente + triggers, NO este cron.
--
-- FIX: el cron solo INSERTA filas para cuotas recién vencidas; ya NO re-actualiza
-- las existentes (`ON CONFLICT DO NOTHING`). Cero lectores afectados, badge de
-- mora intacto, resolución intacta. Mata el churn diario para siempre.
-- Server-only: sin cambio de app ni de sync-rules (la tabla sigue sincronizada
-- por su estado vista_en/resuelta_en, que casi no cambia).
CREATE OR REPLACE FUNCTION public.actualizar_notificaciones_mora(p_tenant_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- row_security off: el cron corre sin auth.uid(); SECURITY DEFINER da rol
  -- postgres (BYPASSRLS), lo explicitamos por las dudas.
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
    cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
    -- Solo contratos ACTIVOS (0124): suspendido/cancelado salen del flujo de
    -- mora del cobrador aunque conserven cuotas vivas.
    and coalesce(
          (select ct.estado from public.contratos ct where ct.id = cu.contrato_id),
          'activo') = 'activo'
  -- ANTES: `do update set dias_mora = excluded.dias_mora, monto_adeudado = ...`
  -- → reescribía TODAS las filas vencidas cada día (dias_mora +1/día) → el #1
  -- driver del Data Synced. Esos campos son escritura-muerta (se calculan en
  -- vivo desde cuotas). AHORA `do nothing`: solo alta de cuotas recién vencidas;
  -- las existentes NO se tocan → sin churn diario.
  on conflict (cuota_id) do nothing;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$function$;


-- >>> Migration: 0185_vmv_guarda_no_op.sql <<<
-- 0185: clientes.vencimiento_mas_viejo — GUARDA anti escritura no-op
-- Diagnóstico 2026-07-10: churn de sincronización de PowerSync (Data Synced 24 GB).
-- Causa #2 medida (pg_stat): clientes con 62.201 UPDATES (10,7× la tabla entera).
--
-- POR QUÉ: `recalc_vencimiento_mas_viejo` (trigger `cuotas_vmv` en cada cambio de
-- cuota) hacía `UPDATE clientes SET vencimiento_mas_viejo = <nuevo>` SIEMPRE,
-- aunque el valor NO cambiara. Cada cuota FUTURA generada (generación mensual,
-- ~5,8k/mes + colchón) dispara el trigger pero NO mueve el "más viejo" (la nueva
-- vence en el futuro) → escritura no-op → una operación de PowerSync a CADA
-- dispositivo, para nada.
--
-- FIX: computar el valor nuevo y solo escribir si CAMBIÓ (`IS DISTINCT FROM`,
-- maneja NULL correctamente). El valor final y el color del mapa son IDÉNTICOS;
-- solo se evitan las escrituras inútiles. Se pasa de LANGUAGE sql a plpgsql para
-- poder computar el valor una sola vez y compararlo. Server-only.
CREATE OR REPLACE FUNCTION public.recalc_vencimiento_mas_viejo(p_cliente_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new date;
BEGIN
  SELECT MIN(cu.fecha_vencimiento)
    INTO v_new
    FROM public.cuotas cu
    LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
   WHERE cu.cliente_id = p_cliente_id
     AND cu.estado IN ('pendiente', 'parcial')
     AND COALESCE(ct.estado, 'activo') = 'activo';

  -- Guarda: solo escribe (y solo entonces genera operación de PowerSync) si el
  -- valor realmente cambió. Antes escribía siempre → miles de no-ops por la
  -- generación de cuotas futuras.
  UPDATE public.clientes c
     SET vencimiento_mas_viejo = v_new
   WHERE c.id = p_cliente_id
     AND c.vencimiento_mas_viejo IS DISTINCT FROM v_new;
END;
$$;


-- >>> Migration: 0186_generar_recibos_faltantes.sql <<<
-- 0186 — Generar recibos faltantes (módulo Operaciones, super_admin). Crea el
-- recibo de cada pago no-anulado que quedó SIN recibo (bajas de la colisión de
-- correlativo: el pago subió, el recibo chocó el UNIQUE 23505 y el connector lo
-- descartó → INV5 violado). Es la versión "botón" del backfill manual por SQL.
--
-- Correlativo = MAX+1 por (cobrador, prefijo), ordenado por fecha_pago (mismo
-- criterio que registrarCobro). NO toca la plata: el recibo no cambia
-- cuotas.monto_pagado ni recaudado, solo agrega el comprobante que faltaba.
-- Idempotente: re-correr solo llena huérfanos nuevos (el NOT EXISTS filtra los
-- que ya tienen recibo). Corré "Verificar invariantes" después (INV5 → 0).
--
-- Patrón data-ops (0147/0154): SECURITY DEFINER + gate is_super_admin() +
-- p_tenant + preview (cuenta) + ejecutar (log en data_ops_log, sin backup — no
-- es destructivo, solo agrega filas).

-- ── PREVIEW: cuántos pagos quedaron sin recibo ─────────────────────────────
create or replace function public.super_admin_preview_recibos_faltantes(
  p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_generables int; v_sin_prefijo int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  -- Huérfanos cuyo cobrador tiene prefijo → se les puede generar el recibo.
  select count(*) into v_generables
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
   where p.tenant_id = p_tenant and p.anulado = false
     and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
     and not exists (select 1 from recibos r where r.pago_id = p.id);

  -- Huérfanos SIN prefijo de cobrador → no se pueden auto-generar (raro).
  select count(*) into v_sin_prefijo
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
   where p.tenant_id = p_tenant and p.anulado = false
     and (co.prefijo_recibo is null or co.prefijo_recibo = '')
     and not exists (select 1 from recibos r where r.pago_id = p.id);

  return jsonb_build_object(
    'generables', v_generables,
    'sin_prefijo', v_sin_prefijo);
end; $fn$;

-- ── EJECUTAR: genera los recibos faltantes + registra en data_ops_log ──────
create or replace function public.super_admin_generar_recibos_faltantes(
  p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_generados int; v_numeros jsonb;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  with orphans as (
    select p.id as pago_id, p.tenant_id, p.cobrador_id, p.fecha_pago, p.ocurrido_en,
           co.prefijo_recibo as prefijo,
           -- Correlativo continuo por PREFIJO dentro del tenant. El prefijo es
           -- único por tenant (0092) y numero_completo es UNIQUE(tenant_id,
           -- numero_completo), así que arrancar del MAX por (tenant, prefijo)
           -- garantiza no chocar ese índice incluso si un prefijo se hubiera
           -- reasignado entre cobradores en el tiempo. created_at/ocurrido_en =
           -- fecha_pago del pago A PROPÓSITO (data del comprobante al momento
           -- del cobro, no del backfill).
           row_number() over (partition by co.prefijo_recibo
                              order by p.fecha_pago, p.id) as rn
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
    where p.tenant_id = p_tenant and p.anulado = false
      and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
      and not exists (select 1 from recibos r where r.pago_id = p.id)
  ),
  maxes as (
    select d.prefijo,
           coalesce(max(r.correlativo), 0) as maxc
    from (select distinct prefijo from orphans) d
    left join recibos r on r.tenant_id = p_tenant and r.prefijo = d.prefijo
    group by d.prefijo
  ),
  ins as (
    insert into recibos (
      id, tenant_id, pago_id, cobrador_id, prefijo, correlativo, numero_completo,
      reimpresiones, anulado, created_at, client_local_id, ocurrido_en)
    select gen_random_uuid(), o.tenant_id, o.pago_id, o.cobrador_id, o.prefijo,
           m.maxc + o.rn,
           o.prefijo || '-' || lpad((m.maxc + o.rn)::text, 5, '0'),
           0, false, o.fecha_pago, gen_random_uuid(),
           coalesce(o.ocurrido_en, o.fecha_pago)
    from orphans o
    join maxes m on m.prefijo = o.prefijo
    returning numero_completo)
  select count(*)::int,
         coalesce(jsonb_agg(numero_completo order by numero_completo), '[]'::jsonb)
    into v_generados, v_numeros
  from ins;

  if v_generados > 0 then
    insert into data_ops_log(
      tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'generar_recibos_faltantes',
            v_generados || ' recibo(s) faltante(s)',
            jsonb_build_object('recibos', v_generados),
            null, auth.uid(), p_actor_label);
  end if;

  return jsonb_build_object(
    'ok', true,
    'generados', v_generados,
    'numeros', v_numeros);
end; $fn$;


-- >>> Migration: 0187_recibo_layout_default_template.sql <<<
-- 0187 — Recibo por defecto = template pedido (2026-07-11).
--
-- El layout/orden por defecto del recibo ahora vive en el catálogo Dart
-- (ReciboLayout.porDefecto): encabezado → meta → cliente/servicio →
-- Monto/letras/método → mora → WhatsApp/pie, con 'cuota' oculto y el espaciado
-- por segmento. Etiquetas nuevas (Colector, Monto, Total en mora) salen en los
-- 3 renderers por código. Esta migración hace el ROLLOUT de datos:
--
--   1. SEED de tenants nuevos: dejar de sembrar 'recibo.layout' con el JSON
--      viejo. Sin fila, el cliente usa ReciboLayout.porDefecto = el template, y
--      además sigue AUTOMÁTICAMENTE cualquier cambio futuro del catálogo (no se
--      duplica el JSON en SQL). Se conserva la siembra de 'recibo.mostrar_cedula'.
--   2. Tenants EXISTENTES: borrar su 'recibo.layout' (orden viejo + cuota
--      visible + whatsapp mal ubicado) y su 'recibo.mostrar_hora' → el cliente
--      cae a porDefecto (template) y a la Hora apagada por defecto. Los settings
--      de CONTENIDO (logo, empresa, título, pie) NO se tocan.
--
-- No toca dinero (solo layout de comprobante). settings es key-value → sin bump
-- de schema ni sync rules. Idempotente.

-- ── 1. Seed de tenants nuevos: ya NO siembra recibo.layout ──────────────────
-- (Se parte del cuerpo VIGENTE de 0090 y se le quita solo el insert de
--  recibo.layout; el trigger tenants_seed_settings_trg NO se toca.)
create or replace function public.seed_settings_recibo_layout(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  -- Sin 'recibo.layout': el cliente usa ReciboLayout.porDefecto (template del
  -- catálogo Dart) y sigue sus cambios futuros. Se mantiene mostrar_cedula.
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'recibo.mostrar_cedula', 'true'::jsonb, 'boolean', 'recibos',
     'Mostrar la cédula del cliente en el recibo', 'admin')
  on conflict (tenant_id, clave) do nothing;
end $$;

-- ── 2. Tenants existentes → template + hora off ────────────────────────────
delete from public.settings where clave = 'recibo.layout';
delete from public.settings where clave = 'recibo.mostrar_hora';


-- >>> Migration: 0188_invariantes_timeout.sql <<<
-- 0188 — Aumentar statement_timeout de las RPCs de invariantes.
-- Supabase impone ~8s para API; las queries con JOINs/subqueries lo exceden
-- en tenants con data real (~4600 clientes). ALTER SET aplica SOLO durante
-- la ejecución de la función, no cambia el global.

alter function public.super_admin_verificar_invariantes(uuid)
  set statement_timeout = '120s';

alter function public.super_admin_verificar_invariantes_inventario(uuid)
  set statement_timeout = '120s';

alter function public.super_admin_verificar_invariantes_tickets(uuid)
  set statement_timeout = '120s';


-- >>> Migration: 0189_corregir_invariantes_auto.sql <<<
-- 0189: RPC para corrección automática de invariantes auto-fixeables.
-- Corrige INV2 (monto_pagado), INV3 (estado), INV14 (cargos_neto),
-- INV17 (colchón indefinidos). INV5 ya tiene su propio botón.
-- Solo super_admin, SECURITY DEFINER.

CREATE OR REPLACE FUNCTION public.super_admin_corregir_invariantes(p_tenant uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
SET "TimeZone" TO 'America/Managua'
AS $$
DECLARE
  v_fixed jsonb := '{}'::jsonb;
  v_count int;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede ejecutar esta operación.';
  END IF;

  -- ── INV14: re-sync cargos_neto ──
  -- Va ANTES de INV3 porque el estado depende de cargos_neto.
  UPDATE cuotas q
  SET cargos_neto = COALESCE((
    SELECT SUM(ce.monto) FROM cargos_extra ce WHERE ce.cuota_id = q.id
  ), 0)
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND COALESCE(q.cargos_neto, 0) <> COALESCE((
      SELECT SUM(ce.monto) FROM cargos_extra ce WHERE ce.cuota_id = q.id
    ), 0);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV14', v_count);

  -- ── INV2: re-sync monto_pagado ──
  -- Va ANTES de INV3 porque el estado depende de monto_pagado.
  UPDATE cuotas q
  SET monto_pagado = COALESCE((
    SELECT SUM(p.monto_cordobas) FROM pagos p
    WHERE p.cuota_id = q.id AND p.anulado = false
  ), 0)
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND q.monto_pagado <> COALESCE((
      SELECT SUM(p.monto_cordobas) FROM pagos p
      WHERE p.cuota_id = q.id AND p.anulado = false
    ), 0);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV2', v_count);

  -- ── INV3: re-sync estado basado en monto_pagado vs total ──
  UPDATE cuotas q
  SET estado = CASE
    WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) THEN 'pagada'
    WHEN q.monto_pagado > 0 THEN 'parcial'
    ELSE 'pendiente'
  END
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND q.tipo_cargo_manual IS NULL
    AND q.estado <> CASE
      WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) THEN 'pagada'
      WHEN q.monto_pagado > 0 THEN 'parcial'
      ELSE 'pendiente'
    END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV3', v_count);

  -- ── INV17: regenerar colchón para contratos indefinidos ──
  -- Primero contamos cuántos necesitan fix.
  SELECT COUNT(*) INTO v_count
  FROM contratos c
  WHERE c.tenant_id = p_tenant
    AND c.duracion_meses IS NULL
    AND c.estado = 'activo'
    AND (
      SELECT COUNT(*) FROM cuotas q2
      WHERE q2.contrato_id = c.id
        AND q2.estado IN ('pendiente','parcial')
        AND q2.tipo_cargo_manual IS NULL
        AND q2.periodo >= date_trunc('month', CURRENT_DATE)::date
    ) < 3;

  -- Regeneramos el colchón llamando la función existente.
  PERFORM public.generar_cuotas_contrato(c.id)
  FROM contratos c
  WHERE c.tenant_id = p_tenant
    AND c.duracion_meses IS NULL
    AND c.estado = 'activo'
    AND (
      SELECT COUNT(*) FROM cuotas q2
      WHERE q2.contrato_id = c.id
        AND q2.estado IN ('pendiente','parcial')
        AND q2.tipo_cargo_manual IS NULL
        AND q2.periodo >= date_trunc('month', CURRENT_DATE)::date
    ) < 3;

  v_fixed := v_fixed || jsonb_build_object('INV17', v_count);

  RETURN v_fixed;
END;
$$;


-- >>> Migration: 0190_op_log_cobrador_read_policy.sql <<<
-- 0190: Permitir que cobradores lean sus PROPIOS op_log entries.
--
-- Problema: el upload de PowerSync usa .upsert() que PostgREST traduce a
-- INSERT ON CONFLICT DO UPDATE ... RETURNING * — Postgres necesita que el
-- usuario pueda SELECT la fila para que la operación completa funcione.
-- La policy existente (op_log_read) solo permite SELECT a admin/admin_cobranza.
-- Los cobradores podían INSERTAR pero no ver la fila resultante → 42501.
--
-- Fix: policy SELECT mínima para cobradores sobre sus propias filas.
-- El cobrador NO necesita leer op_log ajeno (su historial lo recibe por
-- PowerSync sync rules); esto es solo para que el upsert cierre.

CREATE POLICY op_log_read_cobrador ON op_log
  FOR SELECT
  USING (
    tenant_id = current_tenant_id()
    AND actor_id = auth.uid()
  );


-- >>> Migration: 0191_fix_cuotas_ownership_check.sql <<<
-- 0191 — Fix: quitar ownership check de cuotas_check_cobrador_update
--
-- Bug: cuando Feature C (cambio de fecha de pago) está habilitado, el guard
-- exige cobrador_id=auth.uid() para TODO update — incluyendo el mirror de
-- monto_pagado al registrar un cobro. Si la cuota no está asignada al cobrador
-- (cobrador_id NULL = admin-managed, o asignada a otro), el pago se rechaza
-- con "cobrador solo puede cambiar la fecha de SUS propias cuotas".
--
-- Decisión de producto: cobrador_id es ORGANIZATIVO (rutas, reportes, mapa),
-- NO un gate de acceso. Cualquier cobrador puede cobrar, re-fechar o anular
-- cualquier cuota del tenant. Se elimina el ownership check por completo.

create or replace function public.cuotas_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if public.puede_cambiar_fecha_pago() then
      -- ① Structural: bloqueado siempre (monto/contrato/cliente/cobrador/
      --    periodo/tenant + des-anular).
      if new.monto         is distinct from old.monto         or
         new.contrato_id   is distinct from old.contrato_id   or
         new.cliente_id    is distinct from old.cliente_id    or
         new.cobrador_id   is distinct from old.cobrador_id   or
         new.periodo       is distinct from old.periodo       or
         new.tenant_id     is distinct from old.tenant_id     or
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede cambiar monto/contrato/periodo ni reactivar cuotas anuladas';
      end if;

      -- ② Anulación legítima: solo con el marcador del flujo de cambio de fecha.
      if new.estado <> old.estado and new.estado = 'anulada'
         and coalesce(new.motivo_anulacion, '') <> 'Absorbida por cambio de fecha de pago'
      then
        raise exception 'cobrador solo puede anular cuotas por cambio de fecha de pago';
      end if;
    else
      -- Guard original (Feature C OFF): el cobrador solo puede tocar
      -- monto_pagado y transiciones de estado por cobro.
      if new.monto         is distinct from old.monto         or
         new.contrato_id   is distinct from old.contrato_id   or
         new.cliente_id    is distinct from old.cliente_id    or
         new.cobrador_id   is distinct from old.cobrador_id   or
         new.periodo       is distinct from old.periodo       or
         new.fecha_vencimiento is distinct from old.fecha_vencimiento or
         new.tenant_id     is distinct from old.tenant_id     or
         new.anulada_en    is distinct from old.anulada_en    or
         new.anulada_por   is distinct from old.anulada_por   or
         new.motivo_anulacion is distinct from old.motivo_anulacion or
         (new.estado <> old.estado and new.estado = 'anulada') or
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede anular ni reactivar cuotas; sólo monto_pagado y transiciones de cobro';
      end if;
    end if;
  end if;
  return new;
end;
$$;


-- >>> Migration: 0192_rol_admin_usuarios.sql <<<
-- 0192 — Fase 3: rol admin_usuarios
--
-- Nuevo rol para personal administrativo que gestiona la cartera de clientes
-- (altas, contratos, suspensiones) SIN acceso a dinero ni cobros.
-- Sub-fase A: permisos directos (sin cola de aprobación).
--
-- Cambios:
--   1. CHECK constraint: agregar 'admin_usuarios'
--   2. handle_new_user: whitelist + prefijo (admin_usuarios NO cobra → sin prefijo)
--   3. set_cobrador_rol: permitir el nuevo rol
--
-- is_admin_or_cobranza() NO se modifica: admin_usuarios no es cobranza.
-- No hay tabla nueva ni columna nueva → sin bump de schema ni sync rules schema.
-- Idempotente (CREATE OR REPLACE + DROP IF EXISTS).

BEGIN;

-- 1. CHECK constraint
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets','admin_usuarios'));

-- 2. handle_new_user: agregar 'admin_usuarios' a la whitelist.
-- Partido del cuerpo VIGENTE de 0176. admin_usuarios NO cobra → sin prefijo
-- (cae al else null del CASE).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
BEGIN
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  IF v_rol NOT IN ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets', 'admin_usuarios') THEN
    v_rol := 'admin';
  END IF;

  IF v_rol = 'super_admin' THEN
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  ELSIF v_tenant_id IS NULL THEN
    INSERT INTO public.tenants (nombre)
      VALUES (coalesce(v_empresa_nombre, 'Mi ISP'))
      RETURNING id INTO v_tenant_id;
    v_rol := 'admin';
  END IF;

  INSERT INTO public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) VALUES (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    CASE WHEN v_rol IN ('cobrador', 'admin', 'admin_cobranza')
         THEN v_prefijo ELSE NULL END,
    true
  )
  ON CONFLICT (id) DO UPDATE
    SET tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  RETURN new;
END;
$$;

-- 3. set_cobrador_rol: agregar admin_usuarios.
-- Partido del cuerpo VIGENTE de 0140. admin_usuarios NO cobra → sin prefijo.
CREATE OR REPLACE FUNCTION public.set_cobrador_rol(p_cobrador_id uuid, p_nuevo_rol text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_target_rol text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_cobrador_id = auth.uid() THEN
    RAISE EXCEPTION 'No podés modificar tu propio rol';
  END IF;
  IF p_nuevo_rol NOT IN ('admin','admin_cobranza','cobrador','tecnico','admin_tickets','admin_usuarios') THEN
    RAISE EXCEPTION 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets, admin_usuarios';
  END IF;
  SELECT rol INTO v_target_rol FROM public.cobradores WHERE id = p_cobrador_id FOR UPDATE;
  IF v_target_rol IS NULL THEN
    RAISE EXCEPTION 'Cobrador no existe' USING errcode = 'P0002';
  END IF;
  IF v_target_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede modificar el rol de otro super_admin';
  END IF;
  IF v_target_rol = p_nuevo_rol THEN
    RETURN;
  END IF;
  UPDATE public.cobradores
     SET rol = p_nuevo_rol,
         prefijo_recibo = CASE WHEN p_nuevo_rol IN ('cobrador','admin','admin_cobranza')
                               THEN prefijo_recibo ELSE NULL END
   WHERE id = p_cobrador_id;
END;
$fn$;

COMMIT;


-- >>> Migration: 0193_solicitudes_accion.sql <<<
-- 0193 — Cola de aprobación para admin_usuarios (Fase 3B).
--
-- admin_usuarios puede SOLICITAR acciones estructurales (crear contrato,
-- suspender, reactivar, cancelar contrato, desactivar cliente). El admin o
-- admin_cobranza revisa y aprueba o rechaza (con motivo obligatorio).
-- Al aprobar, el admin ejecuta la acción desde su dispositivo usando los
-- datos JSONB guardados.
--
-- Offline-first: el admin_usuarios crea la solicitud localmente (INSERT),
-- se sincroniza al server via PowerSync, y el admin la ve al entrar.
--
-- R10: tabla nueva con tenant_id + RLS + super_admin_all A MANO.

-- =========================================================================
-- 1. Tabla solicitudes_accion
-- =========================================================================
CREATE TABLE public.solicitudes_accion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,

  -- Quién solicita (admin_usuarios).
  solicitante_id uuid NOT NULL REFERENCES public.cobradores(id),

  -- Tipo de acción solicitada.
  tipo text NOT NULL CHECK (tipo IN (
    'crear_contrato',
    'cancelar_contrato',
    'suspender_contrato',
    'reactivar_contrato',
    'desactivar_cliente'
  )),

  -- Entidad sobre la que aplica: cliente_id para crear_contrato y
  -- desactivar_cliente; contrato_id para el resto.
  entidad_id uuid NOT NULL,

  -- Datos de la solicitud (el form completo para crear_contrato; motivo
  -- para cancelar/suspender; vacío para reactivar/desactivar).
  datos jsonb NOT NULL DEFAULT '{}',

  -- Estado del flujo.
  estado text NOT NULL DEFAULT 'pendiente' CHECK (estado IN (
    'pendiente', 'aprobada', 'rechazada'
  )),

  -- Quién resolvió (admin/admin_cobranza que aprobó o rechazó).
  aprobador_id uuid REFERENCES public.cobradores(id),
  -- Motivo de rechazo (obligatorio en rechazada, NULL en aprobada/pendiente).
  motivo_rechazo text,

  -- Label del solicitante (snapshot del nombre, para la lista del admin
  -- sin hacer JOIN). Igual que actor_label en op_log.
  solicitante_label text,

  -- Timestamps.
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL,   -- device-time UTC (.toUtc())
  resolved_at timestamptz             -- cuándo se aprobó/rechazó
);

CREATE INDEX solicitudes_accion_by_tenant
  ON public.solicitudes_accion (tenant_id, estado);
CREATE INDEX solicitudes_accion_by_solicitante
  ON public.solicitudes_accion (tenant_id, solicitante_id);

-- =========================================================================
-- 2. RLS
-- =========================================================================
-- El admin_usuarios inserta y lee las suyas. Admin/admin_cobranza lee y
-- actualiza (aprueba/rechaza) todas del tenant. Super_admin: all.
ALTER TABLE public.solicitudes_accion ENABLE ROW LEVEL SECURITY;

-- SELECT: admin/admin_cobranza ven todas; admin_usuarios ve las suyas.
CREATE POLICY "solicitudes_read" ON public.solicitudes_accion
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR solicitante_id = auth.uid()
    )
  );

-- INSERT: solo admin_usuarios (solicitante_id = auth.uid()).
-- El current_user_rol() check es por seguridad; admin/admin_cobranza
-- no deberían crear solicitudes (ejecutan directo).
CREATE POLICY "solicitudes_insert" ON public.solicitudes_accion
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND solicitante_id = auth.uid()
  );

-- UPDATE: solo admin/admin_cobranza (aprobar/rechazar).
CREATE POLICY "solicitudes_update" ON public.solicitudes_accion
  FOR UPDATE USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

-- super_admin bypass.
CREATE POLICY "super_admin_all" ON public.solicitudes_accion
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


-- >>> Migration: 0194_fix_solicitud_datos_jsonb.sql <<<
-- Fix doble-encoding de la columna datos (jsonb) en solicitudes_accion.
-- PowerSync envía el valor como string JSON literal → Postgres lo guarda como
-- jsonb "string" en vez de jsonb "object". Este trigger desempaqueta
-- automáticamente antes de guardar.

CREATE OR REPLACE FUNCTION fix_solicitud_datos_jsonb()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(NEW.datos) = 'string' THEN
    NEW.datos := (NEW.datos #>> '{}')::jsonb;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fix_solicitud_datos ON solicitudes_accion;
CREATE TRIGGER trg_fix_solicitud_datos
  BEFORE INSERT OR UPDATE ON solicitudes_accion
  FOR EACH ROW EXECUTE FUNCTION fix_solicitud_datos_jsonb();


-- >>> Migration: 0195_rls_admin_usuarios_clientes.sql <<<
-- admin_usuarios necesita write en clientes, fotos y etiquetas para gestión
-- de usuarios. NO se amplía is_admin_or_cobranza() porque esa función gatea
-- ~30 tablas incluyendo pagos/cuotas/cargos/contratos — demasiado scope.

CREATE POLICY clientes_write_admin_usuarios ON clientes
  FOR ALL
  USING (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios')
  WITH CHECK (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios');

CREATE POLICY fotos_cliente_write_admin_usuarios ON fotos_cliente
  FOR ALL
  USING (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios')
  WITH CHECK (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios');

CREATE POLICY cliente_etiquetas_write_admin_usuarios ON cliente_etiquetas
  FOR ALL
  USING (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios')
  WITH CHECK (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios');


-- >>> Migration: 0196_password_texto.sql <<<
-- Columna para almacenar la contraseña en texto recuperable.
-- NO se incluye en sync rules — nunca llega al dispositivo.
-- Solo accesible via Edge Function (ver-password-cobrador) con
-- re-autenticación del admin.
ALTER TABLE cobradores ADD COLUMN IF NOT EXISTS password_texto text;


-- >>> Migration: 0197_dashboard_pin_per_user.sql <<<
-- 0197: PIN del dashboard per-user (antes era un setting de tenant).
-- Solo aplica a usuarios con rol 'admin'. Cada admin tiene su propio PIN.
-- El super_admin bypassa el gate; los demás roles no ven el gate.

ALTER TABLE cobradores ADD COLUMN IF NOT EXISTS dashboard_pin TEXT NOT NULL DEFAULT '';


-- >>> Migration: 0198_rol_lectura.sql <<<
-- 0198 — Rol `lectura` ("Solo lectura")
--
-- Rol para los dueños del ISP: ve TODO el tenant (incluida la plata) y no
-- puede modificar NADA. Pedido por los dueños de los tenants.
--
-- Modelo de permisos: se agregan policies de SELECT y NINGUNA de escritura.
-- El rol queda fuera de `is_admin_or_cobranza()` A PROPÓSITO — esa función
-- gatea también INSERT/UPDATE/DELETE, así que meterlo ahí le daría permiso de
-- escritura sobre medio esquema. Por eso las policies nuevas son propias y
-- exclusivamente `FOR SELECT`.
--
-- Excepción única de escritura: su propio PIN del dashboard, vía la RPC
-- `set_mi_dashboard_pin` (SECURITY DEFINER, acotada a auth.uid() y a esa sola
-- columna). No se abre policy de UPDATE sobre `cobradores`: una policy
-- `USING (id = auth.uid())` dejaría que el usuario se editara nombre, teléfono
-- y prefijo, y el rol solo lo frena el trigger cobradores_freeze_rol.
--
-- Idempotente (DROP IF EXISTS + CREATE OR REPLACE).

BEGIN;

-- 1. CHECK constraint: sumar 'lectura'
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets','admin_usuarios','lectura'));

-- 2. handle_new_user: whitelist + prefijo.
-- Partido del cuerpo VIGENTE en la DB (= 0192, verificado antes de escribir
-- esta migración). `lectura` NO cobra → cae al ELSE NULL del CASE del prefijo.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
BEGIN
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  IF v_rol NOT IN ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets', 'admin_usuarios', 'lectura') THEN
    v_rol := 'admin';
  END IF;

  IF v_rol = 'super_admin' THEN
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  ELSIF v_tenant_id IS NULL THEN
    INSERT INTO public.tenants (nombre)
      VALUES (coalesce(v_empresa_nombre, 'Mi ISP'))
      RETURNING id INTO v_tenant_id;
    v_rol := 'admin';
  END IF;

  INSERT INTO public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) VALUES (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    CASE WHEN v_rol IN ('cobrador', 'admin', 'admin_cobranza')
         THEN v_prefijo ELSE NULL END,
    true
  )
  ON CONFLICT (id) DO UPDATE
    SET tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  RETURN new;
END;
$$;

-- 3. set_cobrador_rol: permitir migrar a/desde 'lectura'.
-- Partido del cuerpo VIGENTE (= 0192, verificado). `lectura` NO cobra.
CREATE OR REPLACE FUNCTION public.set_cobrador_rol(p_cobrador_id uuid, p_nuevo_rol text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_target_rol text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_cobrador_id = auth.uid() THEN
    RAISE EXCEPTION 'No podés modificar tu propio rol';
  END IF;
  IF p_nuevo_rol NOT IN ('admin','admin_cobranza','cobrador','tecnico','admin_tickets','admin_usuarios','lectura') THEN
    RAISE EXCEPTION 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets, admin_usuarios, lectura';
  END IF;
  SELECT rol INTO v_target_rol FROM public.cobradores WHERE id = p_cobrador_id FOR UPDATE;
  IF v_target_rol IS NULL THEN
    RAISE EXCEPTION 'Cobrador no existe' USING errcode = 'P0002';
  END IF;
  IF v_target_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede modificar el rol de otro super_admin';
  END IF;
  IF v_target_rol = p_nuevo_rol THEN
    RETURN;
  END IF;
  UPDATE public.cobradores
     SET rol = p_nuevo_rol,
         prefijo_recibo = CASE WHEN p_nuevo_rol IN ('cobrador','admin','admin_cobranza')
                               THEN prefijo_recibo ELSE NULL END
   WHERE id = p_cobrador_id;
END;
$fn$;

-- 4. Helper de rol.
CREATE OR REPLACE FUNCTION public.is_lectura()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.current_user_rol() = 'lectura'
$$;

-- 5. Policies de SELECT (y SOLO de SELECT) sobre las tablas tenant-scoped.
-- La lista sale de: toda tabla con RLS + columna `tenant_id`, MENOS las que son
-- del panel super_admin (super_admin_impersonation, data_op_backups,
-- data_ops_log). `modulos`/`tenants` no se sincronizan al cliente.
DO $do$
DECLARE
  t text;
  tablas text[] := ARRAY[
    'cargos_extra','cliente_etiquetas','clientes','cobradores','comunidades',
    'contrato_suspensiones','contratos','cuotas','departamentos','etiquetas',
    'fotos_cliente','incidentes','inv_categorias','inv_movimientos',
    'inv_productos','inv_proveedores','inv_seriales','inv_ubicaciones',
    'municipios','notificaciones_mora','op_log','pagos','planes','recibos',
    'red_hubs','red_nodos','red_puertos','saldos_favor','settings',
    'solicitudes_accion','tenant_modulos','ticket_adjuntos','ticket_eventos',
    'ticket_materiales','ticket_tipos','tickets','visitas','whatsapp_envios'
  ];
BEGIN
  FOREACH t IN ARRAY tablas LOOP
    EXECUTE format('DROP POLICY IF EXISTS lectura_select ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY lectura_select ON public.%I FOR SELECT '
      'USING (tenant_id = public.current_tenant_id() AND public.is_lectura())', t);
  END LOOP;
END
$do$;

-- 6. Única escritura permitida al rol: su PROPIO PIN del dashboard.
--
-- Va por RPC y no por la tabla porque el cliente del rol `lectura` descarta su
-- cola de subida de PowerSync (barrera 2): un UPDATE local nunca llegaría al
-- server y el PIN se perdería al re-sincronizar. La RPC escribe server-side y
-- PowerSync lo baja de vuelta. Sirve igual para el resto de los roles.
CREATE OR REPLACE FUNCTION public.set_mi_dashboard_pin(p_pin text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING errcode = '42501';
  END IF;
  -- '' = quitar el PIN. Cualquier otro valor debe ser exactamente 4 dígitos.
  IF p_pin <> '' AND p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El PIN debe tener 4 dígitos';
  END IF;
  UPDATE public.cobradores SET dashboard_pin = p_pin WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public.set_mi_dashboard_pin(text) FROM public;
GRANT EXECUTE ON FUNCTION public.set_mi_dashboard_pin(text) TO authenticated;

COMMIT;


-- >>> Migration: 0199_lectura_hardening.sql <<<
-- 0199 — Hardening del rol `lectura` (findings del audit de 0198)
--
-- 1. `password_texto` deja de ser legible por `authenticated`/`anon`.
--
--    ESCALADA DE PRIVILEGIOS REAL, y NO nace con 0198 — 0198 solo la amplió.
--    `cobradores.password_texto` guarda contraseñas EN CLARO (5 filas hoy, 2 de
--    ellas de rol admin). RLS es row-level: cualquier policy que deje ver la
--    FILA de otro miembro deja ver también esa columna. Ya pasaba con
--    `is_admin_or_cobranza()` (un admin_cobranza podía leer la contraseña de un
--    admin y loguearse como él); con `lectura_select` se sumaba el rol nuevo.
--
--    El REVOKE por columna lo corta para TODOS los roles de app de una vez, sin
--    tocar ninguna policy. Se preservan a propósito:
--      · service_role  → lo usan las Edge Functions (invitar-cobrador,
--                        forzar-password-cobrador, ver-password-cobrador), que
--                        validan el rol del caller server-side.
--      · powersync_selfhost → replica; las sync rules NUNCA seleccionan esta
--                        columna (lista explícita), así que no llega al device.
--    Ningún archivo de `lib/` lee `password_texto`.
--
-- 2. Cinco policies de ESCRITURA que no miran el rol.
--
--    Filtran por tenant y por `auth.uid()`, pero no por quién es el usuario, así
--    que un rol de solo lectura las satisface. NO las contiene la barrera del
--    connector: son alcanzables por REST directo, sin pasar por PowerSync.
--    La de `op_log` es la más grave — permite falsificar el historial, que es el
--    único registro de cambios desde que se eliminó `audit_log` (0140), e
--    incluso escribir filas con `actor_id IS NULL` (las del super_admin).

BEGIN;

-- ── 1. Contraseñas en claro ───────────────────────────────────────────────
-- OJO: un `REVOKE SELECT (columna)` NO alcanza si el rol tiene el SELECT a
-- nivel de TABLA — ese grant cubre todas las columnas y gana. Hay que quitar el
-- de tabla y volver a otorgar columna por columna.
--
-- La lista es TODA la tabla menos `password_texto`. Si se agrega una columna
-- nueva a `cobradores`, hay que sumarla acá o los clientes dejan de verla
-- (el grant de columna no cubre lo que no se nombra).
REVOKE SELECT ON public.cobradores FROM authenticated;
REVOKE SELECT ON public.cobradores FROM anon;
GRANT SELECT (id, tenant_id, nombre, telefono, rol, activo, created_at,
              prefijo_recibo, puede_cambiar_fecha, dashboard_pin)
  ON public.cobradores TO authenticated;

-- Backlog (NO se toca acá a propósito): `authenticated` conserva INSERT/UPDATE
-- sobre `password_texto`. No expone credenciales — a lo sumo permite pisar el
-- campo espejo de alguien cuya fila RLS ya deje actualizar (el password real
-- vive en auth.users y no se toca). Revocar el UPDATE por columna obliga a
-- rehacer el GRANT de escritura de TODA la tabla, y equivocarse en una columna
-- rompe la edición de personal; no vale el riesgo por un vector de envenenado.

-- ── 2. Escrituras sin chequeo de rol ──────────────────────────────────────
-- Se reconstruyen con la MISMA condición vigente + `AND NOT is_lectura()`.

DROP POLICY IF EXISTS visitas_insert ON public.visitas;
CREATE POLICY visitas_insert ON public.visitas FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND cobrador_id = auth.uid()
              AND NOT public.is_lectura());

DROP POLICY IF EXISTS op_log_insert ON public.op_log;
CREATE POLICY op_log_insert ON public.op_log FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND (actor_id = auth.uid() OR actor_id IS NULL)
              AND NOT public.is_lectura());

DROP POLICY IF EXISTS op_log_update ON public.op_log;
CREATE POLICY op_log_update ON public.op_log FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND (actor_id = auth.uid() OR actor_id IS NULL)
         AND NOT public.is_lectura())
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND (actor_id = auth.uid() OR actor_id IS NULL)
              AND NOT public.is_lectura());

DROP POLICY IF EXISTS solicitudes_insert ON public.solicitudes_accion;
CREATE POLICY solicitudes_insert ON public.solicitudes_accion FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND solicitante_id = auth.uid()
              AND NOT public.is_lectura());

DO $do$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departamentos','municipios','comunidades'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS geo_insert ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY geo_insert ON public.%I FOR INSERT '
      'WITH CHECK (tenant_id = public.current_tenant_id() '
      'AND NOT public.is_lectura())', t);
  END LOOP;
END
$do$;

COMMIT;


-- >>> Migration: 0200_lectura_cambio_fecha.sql <<<
-- 0200 — `puede_cambiar_fecha_pago()` excluye al rol `lectura`
--
-- La función gatea las policies `contratos_cambiar_fecha` y
-- `cuotas_cambiar_fecha_*`. Su condición de rol es
-- `c.rol = 'admin' OR c.puede_cambiar_fecha`, así que un usuario migrado DESDE
-- `cobrador` a `lectura` la satisface: ni `set_cobrador_rol` ni el form limpian
-- ese flag al cambiar de rol (solo limpian `prefijo_recibo`).
--
-- Alcanzable por REST directo (no pasa por la cola de PowerSync, así que la
-- guardia del cliente no lo contiene). El espejo en Dart es el early-return de
-- `puedeCambiarFechaPagoProvider`.
--
-- Partido del cuerpo VIGENTE en la DB (verificado con pg_get_functiondef antes
-- de escribir esta migración).

CREATE OR REPLACE FUNCTION public.puede_cambiar_fecha_pago()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    coalesce((
      -- settings.valor es TEXT (0011 lo migró de jsonb a text serializado para
      -- el cliente SQLite); el cliente lo escribe con jsonEncode(bool) → 'true'
      -- /'false'. Comparar como texto (no como jsonb).
      select s.valor = 'true'
        from public.settings s
       where s.tenant_id = public.current_tenant_id()
         and s.clave = 'cobranza.cambio_fecha_habilitado'
    ), false)
    and coalesce((
      select (c.rol <> 'lectura' and (c.rol = 'admin' or c.puede_cambiar_fecha))
        from public.cobradores c
       where c.id = auth.uid()
    ), false);
$function$;


-- >>> Migration: 0201_dashboard_pin_aislado.sql <<<
-- 0201 — El PIN del dashboard deja de viajar al equipo de los demás
--
-- 0197 puso `dashboard_pin` en `cobradores` y las sync rules lo bajan
-- tenant-wide: cada admin tenía en su SQLite local el PIN EN CLARO de todos
-- sus pares. El "PIN por usuario" no aislaba a un admin de otro.
--
-- Cambio (decisión de Rubén 2026-07-26): nadie ve el PIN ajeno, ni para
-- ayudar. Si alguien lo olvida, otro admin FUERZA el cambio (se lo borra sin
-- verlo) y la persona configura uno nuevo al entrar al Resumen.
--
--   · `dashboard_pin_configurado` — columna GENERADA (booleana). Es lo que
--     viaja tenant-wide: alcanza para que Personal muestre "tiene PIN / sin
--     PIN" sin exponer el valor. Al ser generada no se puede desincronizar.
--   · `dashboard_pin` sale de los buckets tenant-wide (ver sync-rules.yaml);
--     solo llega por el bucket self-scoped de cada usuario.
--   · `forzar_reset_dashboard_pin(uuid)` — un admin borra el PIN de otro sin
--     leerlo. No devuelve el valor viejo.
--
-- Idempotente.

BEGIN;

-- 1. Columna generada: "¿tiene PIN?" sin decir cuál.
ALTER TABLE public.cobradores
  ADD COLUMN IF NOT EXISTS dashboard_pin_configurado boolean
  GENERATED ALWAYS AS (dashboard_pin IS NOT NULL AND dashboard_pin <> '') STORED;

-- 2. Reset forzado: borra el PIN de otro miembro SIN devolverlo.
--
-- Guard de rol: solo admin o super_admin, y dentro del propio tenant (el
-- super_admin bypassa el chequeo de tenant, igual que el resto de sus RPCs).
-- No se puede usar sobre un super_admin.
CREATE OR REPLACE FUNCTION public.forzar_reset_dashboard_pin(p_cobrador_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_mi_rol    text;
  v_mi_tenant uuid;
  v_su_rol    text;
  v_su_tenant uuid;
BEGIN
  SELECT rol, tenant_id INTO v_mi_rol, v_mi_tenant
    FROM public.cobradores WHERE id = auth.uid();
  IF v_mi_rol IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING errcode = '42501';
  END IF;
  IF v_mi_rol NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar el cambio de PIN'
      USING errcode = '42501';
  END IF;

  SELECT rol, tenant_id INTO v_su_rol, v_su_tenant
    FROM public.cobradores WHERE id = p_cobrador_id;
  IF v_su_rol IS NULL THEN
    RAISE EXCEPTION 'Ese usuario no existe' USING errcode = 'P0002';
  END IF;
  IF v_su_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede forzar el PIN de un super_admin';
  END IF;
  IF v_mi_rol <> 'super_admin' AND v_su_tenant <> v_mi_tenant THEN
    RAISE EXCEPTION 'Ese usuario es de otra empresa' USING errcode = '42501';
  END IF;

  UPDATE public.cobradores SET dashboard_pin = '' WHERE id = p_cobrador_id;
END;
$$;

REVOKE ALL ON FUNCTION public.forzar_reset_dashboard_pin(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.forzar_reset_dashboard_pin(uuid) TO authenticated;

-- 3. La columna nueva se lee tenant-wide; el PIN NO.
-- (El REVOKE de 0199 dejó a `authenticated` con grants por columna: hay que
-- sumar la nueva o los clientes no la ven.)
GRANT SELECT (dashboard_pin_configurado) ON public.cobradores TO authenticated;

COMMIT;


-- >>> Migration: 0202_dashboard_pins_tabla.sql <<<
-- 0202 — El PIN se muda a su propia tabla, visible SOLO para su dueño
--
-- Por qué una tabla y no dejarlo como columna de `cobradores`: para que un
-- admin no vea el PIN ajeno habría que sincronizar la MISMA fila con distintas
-- columnas según el bucket (tenant-wide sin el PIN, self con él). Cuando dos
-- buckets traen la misma fila, cuál gana no es determinista — y equivocarse
-- acá significa o filtrar el PIN o borrárselo al dueño. Con una tabla aparte
-- la regla es inequívoca: el bucket self trae SOLO tu fila, y nadie más la ve.
--
-- `cobradores.dashboard_pin_configurado` (0201, columna generada) sigue siendo
-- lo que viaja tenant-wide para que Personal muestre "tiene PIN / sin PIN".
-- `cobradores.dashboard_pin` queda como respaldo de la generada y deja de
-- sincronizarse a NINGÚN cliente (ver sync-rules.yaml).

BEGIN;

CREATE TABLE IF NOT EXISTS public.dashboard_pins (
  id          uuid PRIMARY KEY REFERENCES public.cobradores(id) ON DELETE CASCADE,
  tenant_id   uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  pin         text NOT NULL DEFAULT '',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- El PK es el propio cobrador_id: una fila por usuario, sin duplicados
-- posibles. `id` (y no `cobrador_id`) porque PowerSync exige que la PK se
-- llame así.
COMMENT ON TABLE public.dashboard_pins IS
  'PIN del Resumen, uno por usuario. Solo su dueño lo lee (RLS + bucket self).';

-- Backfill desde donde vivía hasta ahora.
INSERT INTO public.dashboard_pins (id, tenant_id, pin)
SELECT c.id, c.tenant_id, COALESCE(c.dashboard_pin, '')
  FROM public.cobradores c
 WHERE COALESCE(c.dashboard_pin, '') <> ''
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.dashboard_pins ENABLE ROW LEVEL SECURITY;

-- SOLO tu propia fila. No hay policy que deje ver la de otro: ni el admin del
-- tenant. Para ayudar a alguien que lo olvidó está `forzar_reset_dashboard_pin`
-- (0201), que lo BORRA sin leerlo.
DROP POLICY IF EXISTS dashboard_pins_self ON public.dashboard_pins;
CREATE POLICY dashboard_pins_self ON public.dashboard_pins
  FOR SELECT USING (id = auth.uid());

-- super_admin_all a mano, como toda tabla tenant-scoped (regla de AGENTS): sin
-- esto el super_admin impersonando no puede operar.
DROP POLICY IF EXISTS super_admin_all ON public.dashboard_pins;
CREATE POLICY super_admin_all ON public.dashboard_pins
  FOR ALL USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Escritura: nadie escribe directo. Va por las RPC de abajo, que son las que
-- garantizan que solo toques el tuyo.

-- Guardar el PROPIO PIN (reemplaza el UPDATE sobre cobradores de 0198).
CREATE OR REPLACE FUNCTION public.set_mi_dashboard_pin(p_pin text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_tenant uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING errcode = '42501';
  END IF;
  -- '' = quitar el PIN. Cualquier otro valor, exactamente 4 dígitos.
  IF p_pin <> '' AND p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El PIN debe tener 4 dígitos';
  END IF;

  SELECT tenant_id INTO v_tenant FROM public.cobradores WHERE id = auth.uid();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING errcode = '42501';
  END IF;

  INSERT INTO public.dashboard_pins (id, tenant_id, pin, updated_at)
       VALUES (auth.uid(), v_tenant, p_pin, now())
  ON CONFLICT (id) DO UPDATE SET pin = excluded.pin, updated_at = now();

  -- Espejo en `cobradores` para que `dashboard_pin_configurado` (generada, lo
  -- único que ven los demás) siga diciendo la verdad.
  UPDATE public.cobradores SET dashboard_pin = p_pin WHERE id = auth.uid();
END;
$$;

-- Reset forzado: además de `cobradores`, limpia la tabla nueva.
CREATE OR REPLACE FUNCTION public.forzar_reset_dashboard_pin(p_cobrador_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_mi_rol    text;
  v_mi_tenant uuid;
  v_su_rol    text;
  v_su_tenant uuid;
BEGIN
  SELECT rol, tenant_id INTO v_mi_rol, v_mi_tenant
    FROM public.cobradores WHERE id = auth.uid();
  IF v_mi_rol IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING errcode = '42501';
  END IF;
  IF v_mi_rol NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar el cambio de PIN'
      USING errcode = '42501';
  END IF;

  SELECT rol, tenant_id INTO v_su_rol, v_su_tenant
    FROM public.cobradores WHERE id = p_cobrador_id;
  IF v_su_rol IS NULL THEN
    RAISE EXCEPTION 'Ese usuario no existe' USING errcode = 'P0002';
  END IF;
  IF v_su_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede forzar el PIN de un super_admin';
  END IF;
  IF v_mi_rol <> 'super_admin' AND v_su_tenant <> v_mi_tenant THEN
    RAISE EXCEPTION 'Ese usuario es de otra empresa' USING errcode = '42501';
  END IF;

  UPDATE public.cobradores  SET dashboard_pin = '' WHERE id = p_cobrador_id;
  UPDATE public.dashboard_pins SET pin = '', updated_at = now()
   WHERE id = p_cobrador_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_mi_dashboard_pin(text) FROM public;
GRANT EXECUTE ON FUNCTION public.set_mi_dashboard_pin(text) TO authenticated;
REVOKE ALL ON FUNCTION public.forzar_reset_dashboard_pin(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.forzar_reset_dashboard_pin(uuid) TO authenticated;

-- El PIN de `cobradores` deja de ser legible por la app: ya nadie lo lee de
-- ahí (el propio llega por `dashboard_pins`, el ajeno no llega). PowerSync
-- replica con su propio rol, así que el backfill y el espejo siguen andando.
REVOKE SELECT (dashboard_pin) ON public.cobradores FROM authenticated;

COMMIT;


-- >>> Migration: 0203_generar_recibos_por_tandas.sql <<<
-- 0203 — El reparador de recibos deja de ser todo-o-nada
--
-- Síntoma reportado: "analizar y generar los recibos da timeout y no corrige
-- nada". El rol `authenticated` tiene `statement_timeout = 8s`, y 0186 inserta
-- TODOS los faltantes en una sola sentencia. Si se pasa del límite —cosa que
-- pasa por espera de locks cuando los devices están sincronizando cobros sobre
-- la misma tabla, no por lentitud: las consultas miden 575ms y 47ms— Postgres
-- aborta y REVIERTE la sentencia entera: no genera ni uno. Por eso corría,
-- tardaba, fallaba y todo quedaba igual.
--
-- Cambios:
--   1. `p_limite` (default 200): procesa de a tandas. Cada corrida COMMITEA lo
--      suyo, así que lo hecho queda hecho aunque la siguiente se corte.
--   2. Devuelve `restantes` para que la UI sepa si hay que volver a correr.
--   3. Índice sobre `recibos(pago_id)` — el que había es PARCIAL
--      (`WHERE anulado = false`) y el `NOT EXISTS` no lo puede usar, así que
--      recorría la tabla entera. Hoy son 17.400 filas y crece todos los días.
--
-- La causa RAÍZ (el correlativo se calcula en el device y colisiona) se ataca
-- del lado del cliente: un choque ahora reintenta con el próximo número en vez
-- de descartar el recibo. Esto es la red para lo ya acumulado.

BEGIN;

-- Índice usable por el NOT EXISTS (el existente es parcial y no aplica).
CREATE INDEX IF NOT EXISTS recibos_pago_id_idx ON public.recibos (pago_id);

-- OJO: agregar un parámetro NO reemplaza la función, crea una SOBRECARGA — y
-- PostgREST podría seguir resolviendo a la vieja (que es la todo-o-nada). Se
-- dropea explícitamente la firma de 2 argumentos.
DROP FUNCTION IF EXISTS public.super_admin_generar_recibos_faltantes(uuid, text);

CREATE OR REPLACE FUNCTION public.super_admin_generar_recibos_faltantes(
  p_tenant uuid, p_actor_label text default null, p_limite int default 200)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_generados int; v_numeros jsonb; v_restantes int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_limite is null or p_limite < 1 then p_limite := 200; end if;

  with orphans as (
    select p.id as pago_id, p.tenant_id, p.cobrador_id, p.fecha_pago, p.ocurrido_en,
           co.prefijo_recibo as prefijo,
           row_number() over (partition by co.prefijo_recibo
                              order by p.fecha_pago, p.id) as rn
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
    where p.tenant_id = p_tenant and p.anulado = false
      and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
      and not exists (select 1 from recibos r where r.pago_id = p.id)
    -- La TANDA: los más viejos primero, para que el correlativo siga el orden
    -- cronológico de los cobros.
    order by p.fecha_pago, p.id
    limit p_limite
  ),
  maxes as (
    select d.prefijo,
           coalesce(max(r.correlativo), 0) as maxc
    from (select distinct prefijo from orphans) d
    left join recibos r on r.tenant_id = p_tenant and r.prefijo = d.prefijo
    group by d.prefijo
  ),
  ins as (
    insert into recibos (
      id, tenant_id, pago_id, cobrador_id, prefijo, correlativo, numero_completo,
      reimpresiones, anulado, created_at, client_local_id, ocurrido_en)
    select gen_random_uuid(), o.tenant_id, o.pago_id, o.cobrador_id, o.prefijo,
           m.maxc + o.rn,
           o.prefijo || '-' || lpad((m.maxc + o.rn)::text, 5, '0'),
           0, false, o.fecha_pago, gen_random_uuid(),
           coalesce(o.ocurrido_en, o.fecha_pago)
    from orphans o
    join maxes m on m.prefijo = o.prefijo
    returning numero_completo)
  select count(*)::int,
         coalesce(jsonb_agg(numero_completo order by numero_completo), '[]'::jsonb)
    into v_generados, v_numeros
  from ins;

  -- Cuántos quedan DESPUÉS de esta tanda: la UI lo usa para ofrecer otra vuelta.
  select count(*)::int into v_restantes
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
   where p.tenant_id = p_tenant and p.anulado = false
     and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
     and not exists (select 1 from recibos r where r.pago_id = p.id);

  if v_generados > 0 then
    insert into data_ops_log(
      tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'generar_recibos_faltantes',
            v_generados || ' recibo(s) faltante(s)',
            jsonb_build_object('recibos', v_generados, 'restantes', v_restantes),
            null, auth.uid(), p_actor_label);
  end if;

  return jsonb_build_object(
    'ok', true,
    'generados', v_generados,
    'restantes', v_restantes,
    'numeros', v_numeros);
end; $fn$;

COMMIT;


-- >>> Migration: 0204_inventario_revision_redes_geo_ticket.sql <<<
-- =========================================================================
-- 0204 — Ciclo del material (revisión / redes / descarte) + geo en la orden
--
-- Pedido del nuevo dueño (audios 2026-07-26, ver BITACORA):
--   "del técnico pasa a revisión y de revisión pasa a la bodega si está bueno
--    y si está malo pasa a descarte […] y los materiales que están instalados
--    en las redes […] del técnico regresa lo malo a revisión"
--   "el técnico va a poner la geolocalizacion como parte de la orden"
--
-- Los tres cambios son ADITIVOS (amplían CHECKs / agregan columnas nullables):
--   1. inv_seriales.estado      += 'en_revision'
--   2. inv_ubicaciones.tipo     += 'redes'
--   3. tickets.lat / tickets.lng (nuevas, NULL = orden sin ubicación marcada)
--
-- NO se bumpea `_dbWipeVersion`: PowerSync aplica aditivos in-place (R4).
-- 'descarte' NO es un estado nuevo — es el label de 'baja' (solo Dart).
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. inv_seriales.estado: sumar 'en_revision'
--
-- Limbo entre que el equipo vuelve del cliente/red y que se decide su destino.
-- Desde acá el equipo sale a 'en_stock' (sirve) o a 'baja' (descarte).
-- El CHECK se reescribe COMPLETO a partir del vigente (0101) — no existe otra
-- migración que lo haya tocado (verificado con grep sobre migrations/).
-- -------------------------------------------------------------------------
ALTER TABLE public.inv_seriales DROP CONSTRAINT IF EXISTS inv_seriales_estado_check;
ALTER TABLE public.inv_seriales ADD CONSTRAINT inv_seriales_estado_check
  CHECK (estado IN ('en_stock','instalado','danado','retirado','baja','en_revision'));

-- -------------------------------------------------------------------------
-- 2. inv_ubicaciones.tipo: sumar 'redes'
--
-- Material que queda montado en la planta (troncales, splitters, herrajes):
-- no tiene cliente dueño, pero tampoco está en bodega. Sin él, el material de
-- construcción no tiene dónde vivir y quedaba mal contado como 'en_stock'.
-- -------------------------------------------------------------------------
ALTER TABLE public.inv_ubicaciones DROP CONSTRAINT IF EXISTS inv_ubicaciones_tipo_check;
ALTER TABLE public.inv_ubicaciones ADD CONSTRAINT inv_ubicaciones_tipo_check
  CHECK (tipo IN ('central','bodega','vehiculo','tecnico','redes'));

-- -------------------------------------------------------------------------
-- 3. tickets.lat / tickets.lng
--
-- Ubicación REAL donde el técnico ejecutó la orden. Es del TICKET, no del
-- cliente: la casa puede estar mal geolocalizada en la ficha, y lo que importa
-- para auditar el trabajo es dónde se paró el técnico. Nullable a propósito —
-- las órdenes viejas y las que no se ejecutan en sitio no tienen ubicación.
-- Convención `lat`/`lng` en `real`, igual que clientes (schema.dart).
-- -------------------------------------------------------------------------
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS lat double precision;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS lng double precision;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO (no por existencia — lección de la 0192: el
-- CHECK existía pero sin el valor nuevo y la verificación lo dio por bueno).
-- Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT
  'inv_seriales.estado admite en_revision' AS chequeo,
  pg_get_constraintdef(oid) LIKE '%en_revision%' AS ok
  FROM pg_constraint
 WHERE conrelid = 'public.inv_seriales'::regclass
   AND conname  = 'inv_seriales_estado_check'
UNION ALL
SELECT
  'inv_ubicaciones.tipo admite redes',
  pg_get_constraintdef(oid) LIKE '%redes%'
  FROM pg_constraint
 WHERE conrelid = 'public.inv_ubicaciones'::regclass
   AND conname  = 'inv_ubicaciones_tipo_check'
UNION ALL
SELECT
  'tickets.lat existe y es double precision',
  data_type = 'double precision'
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'tickets' AND column_name = 'lat'
UNION ALL
SELECT
  'tickets.lng existe y es double precision',
  data_type = 'double precision'
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'tickets' AND column_name = 'lng';


-- >>> Migration: 0205_ticket_materiales_retiro.sql <<<
-- =========================================================================
-- 0205 — Retiro de equipo desde la orden (Fase 2, el técnico)
--
-- Pedido del nuevo dueño (audio 7): "cuando retire un cliente […] lo va a
-- retirar del cliente y se le tiene que buscar en el inventario de los
-- clientes". Hoy el técnico puede CONSUMIR material desde la orden pero no
-- puede DEVOLVER lo que desinstala.
--
-- POR QUÉ POR ACÁ Y NO CON UNA ESCRITURA DEL CLIENTE: el rol `tecnico` NO
-- tiene RLS de UPDATE sobre `inv_seriales` (`inv_update` exige
-- `is_admin_or_cobranza()`). Un botón que escriba inventario desde su app se
-- vería OK offline y lo rechazaría el server al sincronizar. En cambio SÍ
-- puede insertar en `ticket_materiales` (`tm_insert` usa `is_ticket_staff()`),
-- y el trigger SECURITY DEFINER mueve el inventario por él. Es exactamente el
-- camino que ya usa el consumo desde 0106.
--
-- 1. `ticket_materiales.tipo` — 'consumo' (lo de siempre) | 'retiro' (nuevo).
-- 2. `ticket_materiales_consumo()` — se le antepone la rama del retiro.
--    El cuerpo del CONSUMO queda IDÉNTICO al vigente en la DB (partido de
--    `pg_get_functiondef`, no de la migración 0106 ni de memoria — lección
--    0151→0152: reescribir desde el cuerpo viejo pierde llamadas en silencio).
--
-- Aditivo: `tipo` nace con DEFAULT 'consumo', así TODA fila existente y toda
-- fila que escriba una app v0.28.0 (que no conoce la columna) sigue el camino
-- de siempre. No se bumpea `_dbWipeVersion`.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Discriminador de la fila
-- -------------------------------------------------------------------------
ALTER TABLE public.ticket_materiales
  ADD COLUMN IF NOT EXISTS tipo text NOT NULL DEFAULT 'consumo';

ALTER TABLE public.ticket_materiales
  DROP CONSTRAINT IF EXISTS ticket_materiales_tipo_check;
ALTER TABLE public.ticket_materiales
  ADD CONSTRAINT ticket_materiales_tipo_check
  CHECK (tipo IN ('consumo','retiro'));

-- -------------------------------------------------------------------------
-- 2. Trigger: rama de retiro + consumo intacto
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ticket_materiales_consumo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cliente uuid;
  v_existe  boolean := false;
BEGIN
  -- Defensa cross-tenant (SECURITY DEFINER saltea RLS → validamos a mano que TODO
  -- FK pertenezca a NEW.tenant_id; la FK sola sólo garantiza existencia, no co-
  -- tenencia, y NEW.tenant_id está anclado por la RLS WITH CHECK al tenant real
  -- del que escribe). Sin esto, una fila podría referenciar recursos de otro tenant.
  SELECT cliente_id, true INTO v_cliente, v_existe
    FROM public.tickets
   WHERE id = NEW.ticket_id AND tenant_id = NEW.tenant_id;
  IF NOT COALESCE(v_existe, false) THEN
    RAISE EXCEPTION 'Ticket % no pertenece al tenant %', NEW.ticket_id, NEW.tenant_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inv_productos
                  WHERE id = NEW.producto_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Producto % no pertenece al tenant %', NEW.producto_id, NEW.tenant_id;
  END IF;
  IF NEW.ubicacion_origen_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inv_ubicaciones
         WHERE id = NEW.ubicacion_origen_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Ubicación % no pertenece al tenant %', NEW.ubicacion_origen_id, NEW.tenant_id;
  END IF;
  IF NEW.serial_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inv_seriales
         WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Serial % no pertenece al tenant %', NEW.serial_id, NEW.tenant_id;
  END IF;

  -- =======================================================================
  -- RAMA NUEVA (0205): RETIRO — el equipo vuelve del cliente a revisión.
  -- Sale por RETURN antes de tocar el camino del consumo, que queda igual.
  -- =======================================================================
  IF NEW.tipo = 'retiro' THEN
    -- El retiro es de equipo serializado: el granel consumido no "vuelve".
    IF NEW.serial_id IS NULL THEN
      RETURN NEW;
    END IF;
    -- Guards espejo del consumo:
    --  (a) sólo se retira lo que está REALMENTE instalado en el cliente de ESTE
    --      ticket → un insert crafteado no puede arrancarle el equipo a otro;
    --  (b) idempotencia del duplicado offline — el 2º retiro del mismo serial
    --      ya no lo encuentra 'instalado' → no-op sin movimiento duplicado.
    -- Si el ticket no tiene cliente (outage), v_cliente es NULL y no matchea
    -- nada: un retiro sin cliente es un no-op, no un error.
    UPDATE public.inv_seriales
       SET estado = 'en_revision', cliente_id = NULL, contrato_id = NULL,
           ubicacion_id = NULL
     WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id
       AND estado = 'instalado' AND cliente_id IS NOT DISTINCT FROM v_cliente;
    IF NOT FOUND THEN
      RETURN NEW; -- ya retirado / no estaba instalado en este cliente
    END IF;
    -- Movimiento NEUTRO en el ledger: sin origen NI destino. Un 'instalado' ya
    -- fue debitado de su ubicación al instalarse (su `ubicacion_id` es NULL), y
    -- `en_revision` todavía no aterrizó en ninguna bodega. El +1 lo hace recién
    -- `devolverEquipo` cuando aprueba la revisión. Mandar un origen acá dejaría
    -- ese stock en negativo; mandar un destino lo inflaría (ver 0204).
    INSERT INTO public.inv_movimientos
      (id, tenant_id, tipo, producto_id, serial_id, cantidad,
       cliente_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
    VALUES
      (gen_random_uuid(), NEW.tenant_id, 'devolucion', NEW.producto_id,
       NEW.serial_id, NEW.cantidad, v_cliente, NEW.ticket_id,
       'Retirado en ticket → revisión', NEW.hecho_por, NEW.ocurrido_en, now());
    RETURN NEW;
  END IF;

  -- 1. Serializado: el serial pasa a 'instalado' en el cliente del ticket.
  --    Guards: estado='en_stock' (no pisa un serial ya instalado/dado de baja) +
  --    ubicacion_id == ubicacion_origen_id declarada. Este 2º guard cierra dos cosas:
  --    (a) custodia intra-tenant — sólo consumís un serial de DONDE realmente está
  --        (la UI siempre setea ubicacion_origen_id = la ubicación del serial), así un
  --        insert crafteado con un serial ajeno + otra ubicación no lo instala;
  --    (b) idempotencia del dup offline — el 2º consumo del mismo serial ya no está
  --        en_stock allí → no consume.
  --    Si no consumió nada → no-op SIN registrar movimiento (offline-safe, sin RAISE
  --    para no trabar la cola de upload de PowerSync). La fila ticket_materiales queda
  --    igual como registro del intento.
  IF NEW.serial_id IS NOT NULL THEN
    UPDATE public.inv_seriales
       SET estado = 'instalado', cliente_id = v_cliente, ubicacion_id = NULL
     WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id AND estado = 'en_stock'
       AND ubicacion_id IS NOT DISTINCT FROM NEW.ubicacion_origen_id;
    IF NOT FOUND THEN
      RETURN NEW; -- ya instalado / no está en el origen → no duplicamos el movimiento
    END IF;
  END IF;

  -- 2. Movimiento de consumo (descuenta del origen = custodia/ubicación). Serial:
  --    sólo si se consumió arriba. Granel (serial NULL): siempre — el stock granel
  --    tolera ir negativo si dos devices descuentan offline (por diseño; se reconcilia
  --    en el ledger append-only).
  INSERT INTO public.inv_movimientos
    (id, tenant_id, tipo, producto_id, serial_id, cantidad,
     ubicacion_origen_id, cliente_id, ticket_id, costo_unitario,
     motivo, hecho_por, ocurrido_en, created_at)
  VALUES
    (gen_random_uuid(), NEW.tenant_id, 'consumo', NEW.producto_id, NEW.serial_id,
     NEW.cantidad, NEW.ubicacion_origen_id, v_cliente, NEW.ticket_id,
     NEW.costo_unit_snapshot, 'Consumo en ticket', NEW.hecho_por,
     NEW.ocurrido_en, now());

  RETURN NEW;
END;
$function$;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'ticket_materiales.tipo existe con default consumo' AS chequeo,
       column_default LIKE '%consumo%' AND is_nullable = 'NO' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='ticket_materiales' AND column_name='tipo'
UNION ALL
SELECT 'el CHECK admite retiro',
       pg_get_constraintdef(oid) LIKE '%retiro%'
  FROM pg_constraint
 WHERE conrelid='public.ticket_materiales'::regclass
   AND conname='ticket_materiales_tipo_check'
UNION ALL
SELECT 'el trigger tiene la rama de retiro',
       pg_get_functiondef(oid) LIKE '%en_revision%'
  FROM pg_proc WHERE proname='ticket_materiales_consumo'
UNION ALL
SELECT 'el camino del consumo sigue intacto',
       pg_get_functiondef(oid) LIKE '%Consumo en ticket%'
   AND pg_get_functiondef(oid) LIKE '%ubicacion_id IS NOT DISTINCT FROM NEW.ubicacion_origen_id%'
  FROM pg_proc WHERE proname='ticket_materiales_consumo';


-- >>> Migration: 0206_tickets_orden_cola.sql <<<
-- =========================================================================
-- 0206 — Orden de la cola del técnico (Fase 2)
--
-- Pedido del nuevo dueño (audio 6): "quiero que el técnico pueda ver la
-- siguiente orden, pero no la pueda manipular hasta que haya terminado la
-- primera […] hay la opción que el coordinador, porque no encontraron a la
-- persona, pues pueda pasarlo para segundo lugar, tercer lugar o último".
--
-- El BLOQUEO en sí no necesita esta columna (alcanzaba con ordenar por fecha),
-- pero el REORDENAMIENTO del coordinador sí. Se agrega ahora para que la cola
-- se construya desde el principio sobre su orden definitivo: si el bloqueo se
-- montara sobre `created_at` y después se cambiara, la orden "activa" de un
-- técnico podría saltar de la noche a la mañana.
--
-- NULL = sin posición asignada → va después de las ordenadas, por antigüedad.
-- Así ningún ticket existente cambia de lugar al aplicar esta migración.
--
-- Aditivo (columna nullable) → sin bump de `_dbWipeVersion`.
-- =========================================================================

BEGIN;

ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS orden_cola integer;

COMMENT ON COLUMN public.tickets.orden_cola IS
  'Posición en la cola del técnico asignado. NULL = sin posición explícita '
  '(se ordena por created_at, después de las que sí la tienen). Lo setea el '
  'coordinador al reordenar; ver kEstadosOcupanTecnico en cola_tecnico.dart.';

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 2 filas deben dar ok = true.
-- =========================================================================
SELECT 'tickets.orden_cola existe y es integer nullable' AS chequeo,
       data_type = 'integer' AND is_nullable = 'YES' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets' AND column_name='orden_cola'
UNION ALL
SELECT 'ningun ticket existente quedo con posicion (todos NULL)',
       COUNT(*) FILTER (WHERE orden_cola IS NOT NULL) = 0
  FROM public.tickets;


-- >>> Migration: 0207_rol_coordinador.sql <<<
-- =========================================================================
-- 0207 — Rol `coordinador` (Fase 2)
--
-- Del diagrama del nuevo dueño: "EL COORDINADOR NO PODRÁ MODIFICAR LOS
-- TRABAJOS, SOLO ORDENAR" + audio 1: "del ticket se le manda al coordinador
-- para que organice qué técnico, qué cuadrilla lleva los trabajos".
--
-- Alcance aprobado por Rubén (2026-07-26):
--   · Escribe SOLO `asignado_a` y `orden_cola`. Nada más: ni título, ni
--     descripción, ni tipo, ni cliente, ni estado, ni prioridad.
--   · Ve TODAS las órdenes del tenant (para repartir carga entre técnicos).
--   · No toca dinero.
--
-- ⚠️ POR QUÉ HAY UN TRIGGER Y NO ALCANZA LA RLS: las policies de Postgres son
-- ROW-level, no column-level — dejan pasar o bloquean la fila entera. Un
-- `FOR UPDATE USING (is_coordinador())` le permitiría reescribir el título o
-- cerrar la orden. Restringir por columna con `GRANT UPDATE (col)` tampoco
-- sirve acá: Supabase autentica a todos con el MISMO rol de Postgres
-- (`authenticated`), así que el GRANT afectaría a admins y técnicos también.
-- La única barrera real es un trigger que compare OLD vs NEW. (Misma lección
-- que `cobradores.password_texto` en 0199.)
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. CHECK del rol — reescrito COMPLETO desde el vigente (0198) + coordinador
-- -------------------------------------------------------------------------
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets','admin_usuarios','lectura',
                 'coordinador'));

-- -------------------------------------------------------------------------
-- 2. Helper de rol, en la línea de is_ticket_staff / is_lectura
-- -------------------------------------------------------------------------
-- El COALESCE va ADENTRO, como `is_super_admin()` — no como `is_lectura()` /
-- `is_ticket_staff()`, que devuelven NULL si el usuario no tiene fila en
-- `cobradores`. En una policy RLS ese NULL es inocuo (la fila se filtra, falla
-- cerrado), pero en un `IF NOT ...` de plpgsql NO se cumple y saltea el guard.
-- Blindarlo acá evita que cada llamador nuevo tenga que acordarse.
CREATE OR REPLACE FUNCTION public.is_coordinador()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT rol = 'coordinador' FROM public.cobradores WHERE id = auth.uid()),
    false
  )
$function$;

-- -------------------------------------------------------------------------
-- 3. handle_new_user: sumar 'coordinador' a la whitelist.
--
--    El cuerpo se copió de la definición VIVA en la DB (pg_get_functiondef),
--    NO de la migración que la creó — lección 0151→0152: reescribirla desde un
--    cuerpo viejo pierde en silencio lo que se le agregó en el medio.
--    Único cambio respecto del vivo: 'coordinador' en el IF de la whitelist.
--    `coordinador` no cobra → cae en el ELSE NULL del prefijo, sin tocar nada.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
BEGIN
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  IF v_rol NOT IN ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets', 'admin_usuarios', 'lectura',
                   'coordinador') THEN
    v_rol := 'admin';
  END IF;

  IF v_rol = 'super_admin' THEN
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  ELSIF v_tenant_id IS NULL THEN
    INSERT INTO public.tenants (nombre)
      VALUES (coalesce(v_empresa_nombre, 'Mi ISP'))
      RETURNING id INTO v_tenant_id;
    v_rol := 'admin';
  END IF;

  INSERT INTO public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) VALUES (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    CASE WHEN v_rol IN ('cobrador', 'admin', 'admin_cobranza')
         THEN v_prefijo ELSE NULL END,
    true
  )
  ON CONFLICT (id) DO UPDATE
    SET tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  RETURN new;
END;
$function$;

-- -------------------------------------------------------------------------
-- 4. RLS: el coordinador puede UPDATE de tickets de su tenant.
--    Qué columnas, lo decide el trigger del punto 5.
--    (SELECT ya lo tiene por `tk_read`, que es tenant-wide.)
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS "tk_update_coordinador" ON public.tickets;
CREATE POLICY "tk_update_coordinador" ON public.tickets
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.is_coordinador()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
  WITH CHECK (tenant_id = public.current_tenant_id()
         AND public.is_coordinador()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));

-- -------------------------------------------------------------------------
-- 5. LA barrera real: el coordinador solo mueve asignación y posición.
--
--    `ocurrido_en` entra en la lista permitida porque el cliente lo re-sella
--    en CUALQUIER escritura (es el reloj de la intención, no contenido del
--    trabajo). Sin él, una reasignación legítima sería rechazada.
--
--    Se compara el row entero menos las columnas permitidas: así una columna
--    que se agregue en el futuro queda protegida sola, sin tener que acordarse
--    de venir a editar este trigger.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_coordinador_solo_orden()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- COALESCE OBLIGATORIO, no es defensivo de más: `current_user_rol()` devuelve
  -- NULL cuando no hay usuario resuelto (service_role, la CLI, un contexto sin
  -- auth.uid()), así que `is_coordinador()` da NULL — y en plpgsql `IF NOT NULL`
  -- NO se cumple, con lo cual el RETURN temprano se salteaba y el trigger
  -- bloqueaba escrituras legítimas de cualquiera. Encontrado en la prueba
  -- end-to-end: un UPDATE normal de título/estado murió con "el coordinador
  -- solo puede asignar y ordenar".
  IF NOT COALESCE(public.is_coordinador(), false) THEN
    RETURN NEW;  -- admin/técnico/etc. siguen con sus reglas de siempre
  END IF;
  IF (to_jsonb(NEW) - 'asignado_a' - 'orden_cola' - 'ocurrido_en')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'asignado_a' - 'orden_cola' - 'ocurrido_en') THEN
    RAISE EXCEPTION
      'El coordinador solo puede asignar y ordenar la orden %, no modificarla',
      OLD.correlativo
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

-- ⚠️ ESTA BARRERA DEPENDE DEL ORDEN DE LOS TRIGGERS (nota agregada 2026-08-10).
-- Postgres dispara los BEFORE UPDATE en orden ALFABÉTICO por nombre. En
-- `tickets` conviven 7, y los que corren DESPUÉS de éste
-- (`trg_tickets_correlativo`, `trg_tickets_eventos_auto`,
-- `trg_tickets_marcar_verificacion`, `trg_tickets_validar_transicion`) verían un
-- NEW ya corregido y podrían re-aplicar lo que esta barrera revirtió.
-- Un trigger nuevo con un nombre alfabéticamente anterior la desarma EN
-- SILENCIO: sin error, y ningún test lo caza (es comportamiento de runtime de
-- Postgres). Antes de agregar uno, ver la advertencia de ARQUITECTURA §R10 y
-- verificar el orden real con:
--   select tgname from pg_trigger
--    where tgrelid='public.tickets'::regclass and not tgisinternal
--    order by tgname;
DROP TRIGGER IF EXISTS trg_tickets_coordinador_solo_orden ON public.tickets;
CREATE TRIGGER trg_tickets_coordinador_solo_orden
  BEFORE UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_coordinador_solo_orden();

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 5 filas deben dar ok = true.
-- =========================================================================
SELECT 'el CHECK de rol admite coordinador' AS chequeo,
       pg_get_constraintdef(oid) LIKE '%coordinador%' AS ok
  FROM pg_constraint
 WHERE conrelid='public.cobradores'::regclass AND conname='cobradores_rol_check'
UNION ALL
SELECT 'is_coordinador existe', COUNT(*) = 1
  FROM pg_proc WHERE proname='is_coordinador'
UNION ALL
SELECT 'handle_new_user acepta coordinador',
       pg_get_functiondef(oid) LIKE '%coordinador%'
  FROM pg_proc WHERE proname='handle_new_user'
UNION ALL
SELECT 'handle_new_user NO perdio ningun rol viejo',
       pg_get_functiondef(oid) LIKE '%admin_usuarios%'
   AND pg_get_functiondef(oid) LIKE '%lectura%'
   AND pg_get_functiondef(oid) LIKE '%admin_tickets%'
  FROM pg_proc WHERE proname='handle_new_user'
UNION ALL
SELECT 'el trigger de columnas esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_tickets_coordinador_solo_orden';


-- >>> Migration: 0208_cierre_con_intentos.sql <<<
-- =========================================================================
-- 0208 — Cierre de la orden con intentos de contacto (Fase 3)
--
-- Audio 1 del nuevo dueño: "va a cerrar el ticket una vez que se comunique con
-- el cliente y le diga que todo está arreglado, si no, no lo va a poder
-- cerrar […] tiene que garantizar que el trabajo se haga".
--
-- Decisión de Rubén (opción A+B): el call center registra cada intento de
-- contacto; tras N intentos se habilita "cerrar sin confirmar" con motivo
-- obligatorio, y queda marcado como tal para los reportes.
--
-- La parte B (auto-cierre a los X días) NO se construye acá: YA EXISTE desde
-- 0109 — `tickets_auto_cierre(tenant)` + el cron diario
-- `tickets_auto_cierre_diario` (06:30 UTC). Solo hay que prender el setting
-- `tickets.auto_cierre_dias`, que hoy está en 0 (desactivado) en los 4 tenants.
--
-- 1. `ticket_eventos.tipo_evento` += 'contacto'
-- 2. `tickets.cerrado_sin_confirmar` + `tickets.motivo_cierre`
--
-- ⚠️ Las dos columnas nacen NULLABLES A PROPÓSITO, no por descuido. El SQLite
-- local de PowerSync no tiene DEFAULTs y el conector sube la fila entera: una
-- columna NOT NULL que el cliente no setee viaja como NULL, la rechaza Postgres
-- y TRABA LA COLA DE UPLOAD del dispositivo. Se leen siempre con COALESCE.
-- (Se aprendió en 0205, donde `tipo` sí es NOT NULL y hubo que setearlo
-- explícito en todos los INSERT de Dart para no romper el consumo.)
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Un intento de contacto es un evento más de la bitácora del ticket.
--
--    Se reusa `ticket_eventos` en vez de crear una tabla: ya sincroniza a
--    todos los shells, ya tiene RLS, ya se muestra en el timeline de la orden
--    y ya la lee el historial. Una tabla nueva sería 1 migración + 4 policies
--    + 5 buckets de sync para guardar "llamé y no contestó".
--
--    El CHECK se reescribe COMPLETO desde el vigente (0103).
-- -------------------------------------------------------------------------
ALTER TABLE public.ticket_eventos DROP CONSTRAINT IF EXISTS ticket_eventos_tipo_evento_check;
ALTER TABLE public.ticket_eventos ADD CONSTRAINT ticket_eventos_tipo_evento_check
  CHECK (tipo_evento IN
    ('creado','asignado','cambio_estado','comentario','material','adjunto',
     'reabierto','cerrado','cancelado','contacto'));

-- -------------------------------------------------------------------------
-- 2. Cómo se cerró la orden.
--
--    `cerrado_sin_confirmar` = se cerró SIN que el cliente confirmara que el
--    trabajo quedó bien. No es un error: es una salida legítima tras N
--    intentos fallidos. Se marca para que el ISP pueda MEDIR cuántas cierra a
--    ciegas — si ese número crece, algo anda mal en la operación.
--    `motivo_cierre` es obligatorio en la UI para ese caso.
-- -------------------------------------------------------------------------
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS cerrado_sin_confirmar boolean;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS motivo_cierre text;

COMMENT ON COLUMN public.tickets.cerrado_sin_confirmar IS
  'true = se cerró tras N intentos fallidos, sin confirmación del cliente. '
  'NULL/false = cierre normal. Nullable a propósito (ver cabecera de 0208).';

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'ticket_eventos admite tipo contacto' AS chequeo,
       pg_get_constraintdef(oid) LIKE '%contacto%' AS ok
  FROM pg_constraint
 WHERE conrelid='public.ticket_eventos'::regclass
   AND conname='ticket_eventos_tipo_evento_check'
UNION ALL
SELECT 'el CHECK no perdio ningun tipo viejo',
       pg_get_constraintdef(oid) LIKE '%material%'
   AND pg_get_constraintdef(oid) LIKE '%adjunto%'
   AND pg_get_constraintdef(oid) LIKE '%reabierto%'
   AND pg_get_constraintdef(oid) LIKE '%cancelado%'
  FROM pg_constraint
 WHERE conrelid='public.ticket_eventos'::regclass
   AND conname='ticket_eventos_tipo_evento_check'
UNION ALL
SELECT 'cerrado_sin_confirmar existe y es NULLABLE',
       data_type='boolean' AND is_nullable='YES'
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets'
   AND column_name='cerrado_sin_confirmar'
UNION ALL
SELECT 'motivo_cierre existe y es NULLABLE',
       data_type='text' AND is_nullable='YES'
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets' AND column_name='motivo_cierre';


-- >>> Migration: 0209_verificacion_instalacion.sql <<<
-- =========================================================================
-- 0209 — La orden cerrada pasa al gestor para verificar (Fase 4)
--
-- Audio 2 del nuevo dueño: "el ticket ya realizado se le manda al gestor del
-- cliente ya con todos los datos, ya solo para que verifique que lo que se
-- escribió en el contrato es lo mismo que está escrito en la orden […] y el
-- número de contrato […] y una vez pasa al super administrador para que lo
-- apruebe. El punto interesante es que del ticket pase al gestor de usuario
-- EN EL MISMO SISTEMA".
--
-- (El "super administrador" que aprueba es el rol `admin` del tenant, aclarado
-- por Rubén — no el `super_admin` del SaaS, que ahora se muestra como "Dev".)
--
-- QUÉ SE REUSA EN VEZ DE CONSTRUIR:
--   · `ticket_tipos.efecto = 'instalacion'` (0172) YA marca qué órdenes crean
--     servicio. No hace falta un flag nuevo: si el tipo instala, se verifica.
--   · La aprobación del admin YA existe: `solicitudes_accion` (0193), con sus
--     estados y su aprobador. Esta migración NO la toca.
--
-- POR QUÉ UN TRIGGER Y NO CÓDIGO EN LA APP: una orden se cierra por TRES
-- caminos distintos —el cierre normal, el "cerrar sin confirmar" (0208) y el
-- cron de auto-cierre (0109, que corre sin ninguna app abierta)—. Marcarlo
-- desde Dart dejaría afuera el tercero justamente en el caso más probable:
-- la instalación que nadie confirmó y se cerró sola de madrugada.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Estado de la verificación.
--    NULL = no aplica (la orden no instala nada). 'pendiente' = esperando al
--    gestor. 'verificada' = el gestor comparó la orden contra el contrato.
--    Nullable a propósito (ver la cabecera de 0208: una NOT NULL que el
--    cliente no setee traba la cola de upload del dispositivo).
-- -------------------------------------------------------------------------
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS verificacion_estado text;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS verificado_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS verificado_en timestamptz;

ALTER TABLE public.tickets DROP CONSTRAINT IF EXISTS tickets_verificacion_estado_check;
ALTER TABLE public.tickets ADD CONSTRAINT tickets_verificacion_estado_check
  CHECK (verificacion_estado IS NULL
         OR verificacion_estado IN ('pendiente','verificada'));

-- Índice para la bandeja del gestor: son pocas filas sobre muchas órdenes.
CREATE INDEX IF NOT EXISTS tickets_verificacion_pendiente_idx
  ON public.tickets (tenant_id)
  WHERE verificacion_estado = 'pendiente';

-- -------------------------------------------------------------------------
-- 2. Al cerrarse una orden de instalación, queda pendiente de verificar.
--
--    Solo en la TRANSICIÓN a 'cerrado' (no en cada UPDATE de una ya cerrada) y
--    solo si todavía no tiene estado de verificación — así un re-cierre tras
--    una reapertura no borra que el gestor ya la había verificado.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_marcar_verificacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.estado = 'cerrado'
     AND OLD.estado IS DISTINCT FROM 'cerrado'
     AND NEW.verificacion_estado IS NULL
     AND EXISTS (SELECT 1 FROM public.ticket_tipos tt
                  WHERE tt.id = NEW.tipo_id
                    AND tt.tenant_id = NEW.tenant_id
                    AND tt.efecto = 'instalacion')
  THEN
    NEW.verificacion_estado := 'pendiente';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_tickets_marcar_verificacion ON public.tickets;
CREATE TRIGGER trg_tickets_marcar_verificacion
  BEFORE UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_marcar_verificacion();

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 5 filas deben dar ok = true.
-- =========================================================================
SELECT 'verificacion_estado existe y es NULLABLE' AS chequeo,
       data_type='text' AND is_nullable='YES' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets'
   AND column_name='verificacion_estado'
UNION ALL
SELECT 'verificado_por y verificado_en existen', COUNT(*) = 2
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets'
   AND column_name IN ('verificado_por','verificado_en')
UNION ALL
SELECT 'el CHECK acepta NULL y los 2 estados',
       pg_get_constraintdef(oid) LIKE '%pendiente%'
   AND pg_get_constraintdef(oid) LIKE '%verificada%'
  FROM pg_constraint
 WHERE conrelid='public.tickets'::regclass
   AND conname='tickets_verificacion_estado_check'
UNION ALL
SELECT 'el trigger esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_tickets_marcar_verificacion'
UNION ALL
SELECT 'el indice de la bandeja existe', COUNT(*) = 1
  FROM pg_indexes
 WHERE schemaname='public' AND indexname='tickets_verificacion_pendiente_idx';


-- >>> Migration: 0210_gestor_verifica_rls.sql <<<
-- =========================================================================
-- 0210 — Permiso del gestor para marcar una orden como verificada (Fase 4)
--
-- La 0209 dejó las órdenes de instalación en 'pendiente' esperando al gestor,
-- pero el gestor NO PODÍA TOCARLAS: la policy `tk_write` de tickets es
-- `is_ticket_staff()` = admin / admin_tickets / tecnico, y `admin_usuarios` no
-- está. Su botón "Verificada" habría escrito local, se habría visto bien, y lo
-- habría rechazado el server al sincronizar. (Tercera vez que aparece este
-- patrón en el proyecto: 0205 con el técnico y el inventario, 0207 con el
-- coordinador. Regla: antes de dar un botón a un rol, chequear su RLS.)
--
-- Se le abre UPDATE sobre tickets, pero acotado a las 3 columnas de la
-- verificación por un trigger — igual que con el coordinador, y por la misma
-- razón: las policies son ROW-level y dejarían pasar la fila entera.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Helper de rol. COALESCE ADENTRO: `current_user_rol()` es NULL sin usuario
--    resuelto, y en un `IF NOT ...` de plpgsql ese NULL saltea el guard
--    (bug real encontrado en 0207).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin_usuarios()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT rol = 'admin_usuarios' FROM public.cobradores WHERE id = auth.uid()),
    false
  )
$function$;

-- -------------------------------------------------------------------------
-- 2. Policy de UPDATE para el gestor.
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS "tk_update_verificacion" ON public.tickets;
CREATE POLICY "tk_update_verificacion" ON public.tickets
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.is_admin_usuarios()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
  WITH CHECK (tenant_id = public.current_tenant_id()
         AND public.is_admin_usuarios()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));

-- -------------------------------------------------------------------------
-- 3. La barrera de columnas: el gestor SOLO firma la verificación.
--    No cierra, no reasigna, no edita el trabajo.
--
--    Trigger separado del coordinador a propósito: son dos reglas distintas
--    para dos roles distintos, y mezclarlas haría que tocar una arriesgue la
--    otra. `ocurrido_en` va permitido porque el cliente lo re-sella en toda
--    escritura.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_gestor_solo_verificacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT COALESCE(public.is_admin_usuarios(), false) THEN
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'verificacion_estado' - 'verificado_por'
      - 'verificado_en' - 'ocurrido_en')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'verificacion_estado' - 'verificado_por'
      - 'verificado_en' - 'ocurrido_en') THEN
    RAISE EXCEPTION
      'El gestor solo puede verificar la orden %, no modificarla',
      OLD.correlativo
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_tickets_gestor_solo_verificacion ON public.tickets;
CREATE TRIGGER trg_tickets_gestor_solo_verificacion
  BEFORE UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_gestor_solo_verificacion();

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'is_admin_usuarios existe y NO devuelve NULL' AS chequeo,
       public.is_admin_usuarios() IS NOT NULL AS ok
UNION ALL
SELECT 'la funcion trae COALESCE adentro',
       pg_get_functiondef(oid) LIKE '%COALESCE%'
  FROM pg_proc WHERE proname='is_admin_usuarios'
UNION ALL
SELECT 'la policy de verificacion existe', COUNT(*) = 1
  FROM pg_policies
 WHERE tablename='tickets' AND policyname='tk_update_verificacion'
UNION ALL
SELECT 'el trigger de columnas del gestor esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_tickets_gestor_solo_verificacion';


-- >>> Migration: 0211_reverificar_al_reabrir.sql <<<
-- =========================================================================
-- 0211 — Una orden reabierta vuelve a verificarse (audit profundo 2026-07-26)
--
-- La 0209 marcaba 'pendiente' solo si `verificacion_estado IS NULL`, con la
-- idea de "no pisar que el gestor ya la había verificado". Auditado en frío,
-- ese razonamiento es más débil que el riesgo que abre:
--
--   una instalación se verifica → se REABRE → el técnico vuelve, cambia el
--   equipo, corrige la dirección, la re-cierra → y el gestor NUNCA la ve otra
--   vez. Queda con el sello de una verificación que se hizo sobre datos que
--   ya no existen.
--
-- Verificar de más cuesta un minuto; dar por verificado un trabajo que cambió
-- es exactamente lo que este paso existe para evitar.
--
-- El trigger solo dispara en la TRANSICIÓN a 'cerrado' (`OLD.estado IS
-- DISTINCT FROM 'cerrado'`), así que un UPDATE cualquiera sobre una orden ya
-- cerrada NO la vuelve a marcar: solo un ciclo real de reapertura y cierre.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.tickets_marcar_verificacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.estado = 'cerrado'
     AND OLD.estado IS DISTINCT FROM 'cerrado'
     AND EXISTS (SELECT 1 FROM public.ticket_tipos tt
                  WHERE tt.id = NEW.tipo_id
                    AND tt.tenant_id = NEW.tenant_id
                    AND tt.efecto = 'instalacion')
  THEN
    -- Sin el `IS NULL` de 0209: cada cierre de una instalación vuelve a pedir
    -- verificación, incluso si ya la tuvo antes de una reapertura. Se limpian
    -- el quién y el cuándo para que no quede el sello viejo colgado.
    NEW.verificacion_estado := 'pendiente';
    NEW.verificado_por := NULL;
    NEW.verificado_en := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 2 filas deben dar ok = true.
-- =========================================================================
SELECT 'el trigger ya NO exige que la verificacion este vacia' AS chequeo,
       pg_get_functiondef(oid) NOT LIKE '%NEW.verificacion_estado IS NULL%' AS ok
  FROM pg_proc WHERE proname='tickets_marcar_verificacion'
UNION ALL
SELECT 'limpia el sello viejo al re-pedir verificacion',
       pg_get_functiondef(oid) LIKE '%NEW.verificado_por := NULL%'
  FROM pg_proc WHERE proname='tickets_marcar_verificacion';


-- >>> Migration: 0212_pin_configurado_replicable.sql <<<
-- =========================================================================
-- 0212 — HOTFIX: el PIN del Resumen se pedía configurar en LOOP
--
-- SÍNTOMA (reportado en producción, 2026-07-27): un admin configura su PIN,
-- la app dice "PIN configurado", y a la siguiente visita al Resumen le vuelve
-- a pedir configurarlo. Para siempre. El PIN nunca "se guarda".
--
-- CAUSA REAL — y no es el guardado: el PIN SÍ se persiste correctamente, en
-- `dashboard_pins` y en `cobradores.dashboard_pin` (verificado con datos
-- reales). Lo que falla es que la app decide si pedir configuración leyendo
-- `cobradores.dashboard_pin_configurado`, que era una columna **GENERATED
-- ALWAYS** — y **Postgres NO replica columnas generadas** por replicación
-- lógica (la opción `publish_generated_columns` recién existe en PG18; acá
-- corre PG17). Comprobado contra `pg_publication_tables`: la publicación
-- `powersync` envía `dashboard_pin` pero NO envía `dashboard_pin_configurado`.
--
-- Resultado: el flag llegaba NULL a TODOS los dispositivos, siempre. El
-- cliente lo lee como `(row[...] as int? ?? 0) == 1` → false → "Configurá tu
-- PIN" en cada visita, sin importar cuántas veces se configure.
--
-- FIX: dejar de usar una columna generada. `DROP EXPRESSION` la convierte en
-- una columna normal CONSERVANDO los valores actuales, y un trigger la
-- mantiene sincronizada con `dashboard_pin`. Al no ser generada, la
-- publicación empieza a enviarla y los dispositivos la reciben.
--
-- POR QUÉ ESTO ARREGLA A TODOS SIN RELEASE: el cliente no cambia ni una línea
-- —sigue leyendo la misma columna—. El arreglo es 100% server-side, así que
-- alcanza a las apps ya instaladas (v0.27, v0.28 y v0.29) apenas sincronicen.
--
-- Es la ÚNICA columna generada del esquema (verificado en
-- information_schema), así que el problema no se repite en ningún otro lado.
-- =========================================================================

BEGIN;

-- 1. De columna generada a columna normal. Conserva los valores calculados.
ALTER TABLE public.cobradores
  ALTER COLUMN dashboard_pin_configurado DROP EXPRESSION IF EXISTS;

-- 2. El trigger toma el lugar de la expresión: mismo cálculo, pero en una
--    columna real que la replicación sí manda.
CREATE OR REPLACE FUNCTION public.cobradores_sync_pin_configurado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  NEW.dashboard_pin_configurado :=
    (NEW.dashboard_pin IS NOT NULL AND NEW.dashboard_pin <> '');
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cobradores_sync_pin_configurado ON public.cobradores;
CREATE TRIGGER trg_cobradores_sync_pin_configurado
  BEFORE INSERT OR UPDATE ON public.cobradores
  FOR EACH ROW EXECUTE FUNCTION public.cobradores_sync_pin_configurado();

-- 3. Re-alinear por las dudas (DROP EXPRESSION ya conservó los valores, pero
--    esto deja la columna coherente aunque alguien la hubiera tocado a mano).
UPDATE public.cobradores
   SET dashboard_pin_configurado =
       (dashboard_pin IS NOT NULL AND dashboard_pin <> '')
 WHERE dashboard_pin_configurado IS DISTINCT FROM
       (dashboard_pin IS NOT NULL AND dashboard_pin <> '');

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'la columna ya NO es generada' AS chequeo,
       is_generated = 'NEVER' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='cobradores'
   AND column_name='dashboard_pin_configurado'
UNION ALL
SELECT 'la publicacion AHORA la envia',
       bool_or(a = 'dashboard_pin_configurado')
  FROM (SELECT unnest(attnames) AS a FROM pg_publication_tables
         WHERE pubname='powersync' AND tablename='cobradores') s
UNION ALL
SELECT 'el trigger que la mantiene esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_cobradores_sync_pin_configurado'
UNION ALL
SELECT 'ningun usuario quedo con el flag desalineado', COUNT(*) = 0
  FROM public.cobradores
 WHERE dashboard_pin_configurado IS DISTINCT FROM
       (dashboard_pin IS NOT NULL AND dashboard_pin <> '');


-- >>> Migration: 0213_invariantes_timeout_y_conteo.sql <<<
-- =========================================================================
-- 0213 — La verificación de invariantes moría por timeout (y mentía el conteo)
--
-- REPORTADO: "canceling statement due to statement timeout" al verificar los
-- invariantes de dinero de Telecable Mairena (4.372 contratos, 41.804 cuotas,
-- 19.415 pagos).
--
-- CAUSA 1 — FALTABA UN ÍNDICE. El plan real de INV12 mostraba:
--     Seq Scan on pagos  (rows=19415 loops=4372)
-- o sea: la tabla ENTERA de pagos escaneada UNA VEZ POR CONTRATO — 85 millones
-- de filas leídas. 27.417 ms para un solo chequeo, contra un statement_timeout
-- de 8 s. `pagos` tenia indice (tenant_id, cuota_id), pero las subconsultas
-- buscan por cuota_id SOLO, y en un índice compuesto sin la primera columna
-- no hay búsqueda dirigida. Con el índice: **27.417 ms → 173 ms** (158x).
--
-- CAUSA 2 -- EL CONTEO MENTIA. Cada chequeo hacia count(*) sobre un subselect
-- con LIMIT 10, asi que el número TOPABA en 10. Medido en Mairena: INV2 tiene
-- **33 violaciones reales y la pantalla mostraba 10**. Y como el propio consejo
-- de la UI es "corregí INV2 primero", el operador arreglaba 10, re-verificaba,
-- volvia a leer 10 y concluia que la correccion no servia. Ahora violaciones
-- es el conteo REAL y ejemplo_ids sigue trayendo 10 (que es su propósito:
-- ejemplos, no inventario).
--
-- Contar sin el LIMIT ya no cuesta nada gracias al índice: medido, 174 ms el
-- chequeo más pesado y 8 ms el segundo.
--
-- El cuerpo sale de la definicion VIVA (pg_get_functiondef), no de la
-- migración que la creó — regla del proyecto. Los ÚNICOS cambios son sacar los
-- 17 LIMIT 10 y recortar los 17 agregadores a 10 ejemplos.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. El índice que faltaba. Sirve a TODA búsqueda de pagos por cuota, no solo
--    a esta verificación (es un patrón central del dominio).
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS pagos_cuota_id_idx ON public.pagos (cuota_id);

-- -------------------------------------------------------------------------
-- 2. Conteo real + 10 ejemplos.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.super_admin_verificar_invariantes(p_tenant uuid)
 RETURNS TABLE(invariante text, violaciones bigint, ejemplo_ids text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  inv1 as (
    select 'INV1: entregado = aplicado + vuelto (pagos)'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text as ejemplo_ids
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and abs((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50) t
  ),
  inv2 as (
    select 'INV2: cuota.monto_pagado = SUM(pagos aplicados)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cuota_id::text order by cuota_id))[1:10], ', '), '')::text
    from (select cu.id as cuota_id
            from public.cuotas cu
            left join (select cuota_id, sum(monto_cordobas) as pagado
                         from public.pagos where anulado = false group by cuota_id) p
              on p.cuota_id = cu.id
           where cu.tenant_id = p_tenant and cu.estado <> 'anulada'
             and abs(cu.monto_pagado - coalesce(p.pagado, 0)) > 0.01) t
  ),
  inv3 as (
    select 'INV3: estado de cuota coherente con monto_pagado'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and ((estado = 'pagada'    and monto_pagado < (monto + coalesce(cargos_neto,0)) - 0.01)
               or (estado = 'pendiente' and monto_pagado > 0.01)
               or (estado = 'parcial'   and (monto_pagado <= 0.01
                     or monto_pagado >= (monto + coalesce(cargos_neto,0)) - 0.01)))) t
  ),
  inv4 as (
    select 'INV4: ninguna cuota con sobrepago (monto_pagado > total)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and monto_pagado > (monto + coalesce(cargos_neto,0)) + 0.01) t
  ),
  inv5 as (
    select 'INV5: todo pago no anulado tiene recibo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id from public.pagos p
           where p.tenant_id = p_tenant and p.anulado = false
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)) p
  ),
  inv6 as (
    select 'INV6: vuelto_cordobas >= 0'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and vuelto_cordobas < 0) t
  ),
  inv7 as (
    select 'INV7: correlativo de recibo Ãºnico por cobrador+prefijo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(numero_completo order by numero_completo))[1:10], ', '), '')::text
    from (select numero_completo from public.recibos
           where tenant_id = p_tenant
           group by cobrador_id, prefijo, correlativo, numero_completo
           having count(*) > 1) t
  ),
  inv8 as (
    select 'INV8: contrato.cobrador_id = cliente.cobrador_id'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
            join public.clientes c on c.id = ct.cliente_id
           where ct.tenant_id = p_tenant and ct.estado = 'activo'
             and ct.cobrador_id is distinct from c.cobrador_id) t
  ),
  inv9 as (
    -- Solo cuotas OPERATIVAS (pendiente/parcial): el trigger 0122 congela el
    -- cobrador de las pagadas/anuladas al reasignar (auditorÃ­a) â†’ su mismatch es
    -- esperado, no un bug. "QuiÃ©n cobrÃ³" = pagos/recibos.cobrador_id (INV5/INV7).
    select 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
           where cu.tenant_id = p_tenant and cu.contrato_id is not null
             and cu.estado in ('pendiente','parcial')
             and cu.cobrador_id is distinct from ct.cobrador_id) cu
  ),
  inv10 as (
    select 'INV10: tenant_id de hija == tenant_id de su padre (0082)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(ofensor order by ofensor))[1:10], ', '), '')::text
    from (
      select 'pago:' || p.id::text as ofensor
        from public.pagos p join public.cuotas cu on cu.id = p.cuota_id
       where p.tenant_id = p_tenant and p.cuota_id is not null and p.tenant_id <> cu.tenant_id
      union all
      select 'recibo:' || r.id::text
        from public.recibos r join public.pagos p on p.id = r.pago_id
       where r.tenant_id = p_tenant and r.pago_id is not null and r.tenant_id <> p.tenant_id
      union all
      select 'cargo:' || ce.id::text
        from public.cargos_extra ce join public.cuotas cu on cu.id = ce.cuota_id
       where ce.tenant_id = p_tenant and ce.cuota_id is not null and ce.tenant_id <> cu.tenant_id) t
  ),
  inv11 as (
    select 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is not null and ct.duracion_meses > 0
             and ((select count(*) from public.cuotas cu
                     where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                       and cu.estado <> 'anulada')
                  + (select count(*) from public.cuotas cu
                       where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                         and cu.estado = 'anulada' and cu.motivo_anulacion = 'SuspensiÃ³n temporal'))
                 <> ct.duracion_meses) t
  ),
  inv12 as (
    select 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant
             and abs(coalesce((select sum(cu.monto_pagado) from public.cuotas cu
                                where cu.contrato_id = ct.id), 0)
                   - coalesce((select sum(pa.monto_cordobas) from public.pagos pa
                                join public.cuotas cu2 on cu2.id = pa.cuota_id
                               where cu2.contrato_id = ct.id and pa.anulado = false), 0)) > 0.01) t
  ),
  inv13 as (
    select 'INV13: cargos origen=ajuste son descuento_* con motivo no vacÃ­o'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ce.id from public.cargos_extra ce
           where ce.tenant_id = p_tenant and ce.origen = 'ajuste'
             and (ce.tipo not in ('descuento_monto', 'descuento_porcentaje')
                  or ce.descripcion is null or btrim(ce.descripcion) = '')) t
  ),
  inv14 as (
    select 'INV14: cuotas.cargos_neto == SUM real de cargos_extra'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
           where cu.tenant_id = p_tenant
             and abs(coalesce(cu.cargos_neto, 0)
                   - coalesce((select sum(case
                         when ce.tipo in ('reconexion','otro') then ce.monto
                         when ce.tipo in ('descuento_monto','descuento_porcentaje','credito_aplicado') then -ce.monto
                         else 0 end)
                        from public.cargos_extra ce where ce.cuota_id = cu.id), 0)) > 0.01) t
  ),
  inv15 as (
    select 'INV15: saldo a favor del cliente nunca negativo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cliente_id::text order by cliente_id))[1:10], ', '), '')::text
    from (select cliente_id from public.saldos_favor
           where tenant_id = p_tenant
           group by cliente_id
           having sum(case when tipo = 'acreditado' then monto else -monto end) < -0.005) t
  ),
  inv16 as (
    select 'INV16: ningÃºn pago con mÃ©todo de crÃ©dito (crÃ©dito no es pago)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and metodo not in ('efectivo','transferencia','deposito','tarjeta')) t
  ),
  inv17 as (
    select 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchÃ³n)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is null
             and (select count(*) from public.cuotas cu
                   where cu.contrato_id = ct.id and cu.estado = 'pendiente'
                     and cu.tipo_cargo_manual is null
                     and cu.periodo > greatest(
                       date_trunc('month', (now() at time zone 'America/Managua'))::date,
                       coalesce((select max(cu2.periodo) from public.cuotas cu2
                                  where cu2.contrato_id = ct.id
                                    and cu2.estado in ('pagada', 'parcial')), '1900-01-01'::date))) < 3) t
  )
  select * from inv1
  union all select * from inv2
  union all select * from inv3
  union all select * from inv4
  union all select * from inv5
  union all select * from inv6
  union all select * from inv7
  union all select * from inv8
  union all select * from inv9
  union all select * from inv10
  union all select * from inv11
  union all select * from inv12
  union all select * from inv13
  union all select * from inv14
  union all select * from inv15
  union all select * from inv16
  union all select * from inv17
  order by invariante;
end;
$function$
;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'el indice de pagos por cuota existe' AS chequeo, COUNT(*) = 1 AS ok
  FROM pg_indexes
 WHERE schemaname='public' AND indexname='pagos_cuota_id_idx'
UNION ALL
SELECT 'la funcion ya NO topa el conteo en 10',
       pg_get_functiondef(oid) NOT ILIKE '%limit 10%'
  FROM pg_proc WHERE proname='super_admin_verificar_invariantes'
UNION ALL
SELECT 'sigue devolviendo 10 ejemplos',
       pg_get_functiondef(oid) LIKE '%[1:10]%'
  FROM pg_proc WHERE proname='super_admin_verificar_invariantes'
UNION ALL
SELECT 'no se perdio ningun invariante (los 17)',
       (length(pg_get_functiondef(oid)) - length(replace(pg_get_functiondef(oid), 'INV', ''))) / 3 >= 17
  FROM pg_proc WHERE proname='super_admin_verificar_invariantes';


-- >>> Migration: 0214_guard_sobrepago_cuota.sql <<<
-- 0214 — Guard de sobrepago: el servidor deja de aceptar en silencio un cobro
-- que deja la cuota por encima de su total (INV4).
--
-- POR QUÉ
-- El 26/07/2026 entraron 72 pagos que dejaron 36 cuotas sobrepagadas
-- (C$30.003, 9 clientes): dos usuarios cargando el mismo histórico. 33 de esos
-- casos son copia EXACTA (misma cuota, mismo monto, mismo día) y 3 son un pago
-- real imputado al mes equivocado. Nadie se enteró hasta que se corrió el
-- chequeo a mano — eso es lo que este guard viene a cerrar.
--
-- POR QUÉ ANULA Y NO RECHAZA
-- `raise exception` funcionaría: `connector.dart` clasifica P0001 como error
-- permanente, lo saltea y NO traba la cola. Pero el pago quedaría solo en el
-- device (divergente del server) con un recibo ya impreso que no respalda
-- nada. Anulándolo, la fila existe de los dos lados, el cobrador ve en su
-- propia app que quedó anulada, y `recalcular_cuota_desde_pagos` no la suma
-- (ya filtra por anulado = false) → la cuota cuadra sola.
--
-- QUÉ **NO** HACE
-- Si el pago excede pero NO es copia exacta (otro monto u otra fecha), entra
-- igual. Puede ser plata real imputada al mes equivocado y la app no tiene
-- forma de saber cuál de los dos es el bueno: lo decide una persona. Esos
-- casos se listan solos con la consulta del pie (pantalla "Cobros a revisar").

BEGIN;

-- `pagos_anulacion_coherencia` exigía `anulado_por IS NOT NULL` para toda
-- anulación. Acá no hay persona que haya anulado: lo hizo el server. Poner al
-- cobrador del pago sería MENTIR en el rastro — un reporte de anulaciones lo
-- mostraría como si él lo hubiera anulado.
--
-- Se abre el carve-out EXACTO para el caso del sistema (actor nulo + motivo
-- automático) y se deja la exigencia intacta para las anulaciones humanas: una
-- anulación hecha por un usuario sigue necesitando sí o sí quién, cuándo y por
-- qué. El prefijo del motivo lo escribe el trigger de abajo, nadie más.
alter table public.pagos drop constraint if exists pagos_anulacion_coherencia;
alter table public.pagos add constraint pagos_anulacion_coherencia
  check (
    anulado = false
    or (anulado_en is not null
        and motivo_anulacion is not null
        and (anulado_por is not null
             or motivo_anulacion like 'Duplicado automático:%'))
  );

create or replace function public.pagos_guard_sobrepago_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
-- `fecha_pago` guarda el WALL-CLOCK local como si fuera UTC (convención de
-- AGENTS §1b: su `date()` sostiene el bucketing). Con la sesión en UTC,
-- `::date` devuelve el día que el usuario eligió; convertir a
-- 'America/Managua' correría un día para atrás todo pago retroactivo
-- (verificado: 2026-01-12 00:00+00 → 2026-01-11). Se fija acá para no
-- depender del TimeZone de la sesión que dispare el trigger.
set timezone = 'UTC'
as $$
declare
  v_total_a_cobrar numeric(10,2);
  v_ya_pagado      numeric(10,2);
  v_gemelo         uuid;
begin
  -- Un pago que ya llega anulado no suma a la cuota: no hay nada que evaluar.
  if new.anulado then
    return new;
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(new.cuota_id);
  if v_total_a_cobrar is null then
    return new;  -- cuota inexistente: que lo rechace la FK, no este guard
  end if;

  -- OJO — `p.id <> new.id` NO es decorativo: el upload de PowerSync es un
  -- UPSERT (`connector.dart`, UpdateType.put → `table.upsert`), así que un
  -- reintento del MISMO pago vuelve a disparar este BEFORE INSERT con la fila
  -- ya commiteada. Sin excluirse a sí mismo, el reintento se leería como
  -- duplicado de sí mismo y se auto-anularía.
  select coalesce(sum(p.monto_cordobas), 0)
    into v_ya_pagado
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false
     and p.id <> new.id;

  -- No excede → el 99,9% de los cobros. El guard no toca nada.
  -- Tolerancia de 1 centavo, igual que INV4 en invariantes_dinero.sql.
  if v_ya_pagado + new.monto_cordobas <= v_total_a_cobrar + 0.01 then
    return new;
  end if;

  -- Excede. ¿Ya hay un pago IDÉNTICO en esta cuota? Se compara en centavos
  -- enteros para no arrastrar el redondeo de numeric.
  --
  -- Que el monto sea igual NO alcanza por sí solo: dos parciales de 500 sobre
  -- una cuota de 1000 son legítimos y no llegan acá justamente porque no
  -- exceden. Llegar acá con monto y día iguales solo pasa si el cobro se
  -- cargó dos veces.
  select p.id
    into v_gemelo
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false
     and p.id <> new.id
     and round(p.monto_cordobas * 100) = round(new.monto_cordobas * 100)
     and p.fecha_pago::date = new.fecha_pago::date
   order by p.fecha_pago
   limit 1;

  if v_gemelo is null then
    return new;  -- excede pero no es copia: lo resuelve una persona
  end if;

  new.anulado          := true;
  new.anulado_en       := now();
  new.anulado_por      := null;  -- lo anuló el servidor, no un usuario
  new.motivo_anulacion := coalesce(
    new.motivo_anulacion,
    'Duplicado automático: ya existe un pago idéntico en esta cuota ('
      || v_gemelo || ')');
  return new;
end $$;

drop trigger if exists trg_pagos_guard_sobrepago on public.pagos;
create trigger trg_pagos_guard_sobrepago
  before insert on public.pagos
  for each row execute function public.pagos_guard_sobrepago_trg();

-- Descuentos huérfanos de un pago auto-anulado.
--
-- `trg_pagos_revertir_descuentos` limpia los `cargos_extra` de descuento
-- cuando un pago pasa de vivo a anulado, pero es AFTER UPDATE OF anulado: no
-- dispara si el pago nace anulado. Y los cargos del cobro suben DESPUÉS del
-- pago en el mismo batch, así que tampoco están todavía cuando corre el guard.
-- Sin esto, un cobro duplicado CON descuento quedaría anulado pero con su
-- descuento aplicado, bajando `cuota_total_a_cobrar` sin pago que lo sostenga.
create or replace function public.cargos_descuento_de_pago_anulado_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.pago_id is null
     or new.tipo not in ('descuento_monto', 'descuento_porcentaje') then
    return new;
  end if;
  -- Mismo alcance que pagos_revertir_descuentos_trg: descuentos atados a un
  -- pago que ya no cuenta. Descartar la fila (return null) deja al server sin
  -- ella y PowerSync converge borrándola del device.
  if exists (select 1 from public.pagos p
              where p.id = new.pago_id and p.anulado = true) then
    return null;
  end if;
  return new;
end $$;

drop trigger if exists trg_cargos_descuento_pago_anulado on public.cargos_extra;
create trigger trg_cargos_descuento_pago_anulado
  before insert on public.cargos_extra
  for each row execute function public.cargos_descuento_de_pago_anulado_trg();

COMMIT;

-- Verificación post-deploy (correr a mano):
--
--   -- 1) Los dos triggers existen:
--   select tgname from pg_trigger
--    where tgname in ('trg_pagos_guard_sobrepago',
--                     'trg_cargos_descuento_pago_anulado');        -- 2 filas
--
--   -- 2) El guard fija la sesión en UTC (si no, los pagos retroactivos
--   --    se comparan contra el día equivocado):
--   select proconfig from pg_proc
--    where proname = 'pagos_guard_sobrepago_trg';   -- incluye TimeZone=UTC
--
--   -- 3) Cobros a revisar — excede el total y NADIE lo anuló solo (o sea,
--   --    no era copia exacta). Es la consulta que alimenta la pantalla.
--   select cl.nombre, cu.periodo::date, cu.monto_pagado,
--          public.cuota_total_a_cobrar(cu.id) as total
--     from public.cuotas cu
--     join public.contratos ct on ct.id = cu.contrato_id
--     join public.clientes  cl on cl.id = ct.cliente_id
--    where cu.estado <> 'anulada'
--      and cu.monto_pagado > public.cuota_total_a_cobrar(cu.id) + 0.01
--    order by cl.nombre, cu.periodo;
--
--   -- 4) Lo que el guard anuló solo (auditoría de falsos positivos):
--   select count(*) from public.pagos
--    where anulado = true and anulado_por is null
--      and motivo_anulacion like 'Duplicado autom%';


-- >>> Migration: 0215_correlativo_recibo_server.sql <<<
-- 0215 — El correlativo del recibo lo asigna el SERVER (fin de colisiones).
--
-- PROBLEMA: el device calcula el correlativo como MAX(local)+1 por
-- (cobrador, prefijo) (`pagos_repo.registrarCobro`). Dos devices de la MISMA
-- cuenta (típico: "Oficina" en 2 PCs) ambos sin sincronizar calculan el mismo
-- número. Como NO existe un unique en `numero_completo` (el comentario del
-- código que dice "choca 23505" está DESACTUALIZADO), hoy la colisión deja
-- pasar DUPLICADOS silenciosos (dos recibos con el mismo número). En la época
-- en que sí existía el unique, en cambio, se DESCARTABA el 2º recibo → cobro
-- sin comprobante (INV5, los OF-12292..12311 backfilleados a mano).
--
-- FIX (server-only, sin build de app): un contador atómico por (tenant, prefijo)
-- + trigger BEFORE INSERT que asigna el correlativo y reescribe numero_completo,
-- IGNORANDO el que mandó el device. Restaura "server gana" (invariante #3) para
-- el numerado.
--   - El contador se incrementa con INSERT..ON CONFLICT DO UPDATE..RETURNING:
--     atómico (row-lock) → dos inserts concurrentes sacan números distintos, y
--     el INSERT multi-fila del reparador 0203 también numera bien (cada fila
--     re-lee+incrementa el contador; MAX+1 NO serviría: no ve las filas de la
--     misma sentencia).
--   - Scope (tenant, prefijo): igual que numero_completo (= prefijo-correlativo)
--     y que 0203. El device numera por (cobrador, prefijo); coincide porque el
--     prefijo es de-cobrador (`cobradores.prefijo_recibo`).
--   - UNIQUE (tenant, prefijo, correlativo) como red final: duplicado imposible.
--   - El device sigue imprimiendo su número (casi siempre = el del server, que
--     consulta antes de cobrar). Solo en la carrera real el 2º se guarda con el
--     próximo número → existe y es único (mejor que duplicado o descartado).
--
-- Verificado antes: 0 correlativos duplicados, 0 numero_completo duplicados,
-- 0 pagos sin recibo (27.079 recibos). Se puede agregar el UNIQUE sin limpiar.

BEGIN;

-- ── 1) Contador por (tenant, prefijo). Server-only (fuera de sync rules). ─────
CREATE TABLE IF NOT EXISTS public.recibo_correlativos (
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  prefijo   text NOT NULL,
  ultimo    int  NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, prefijo)
);
ALTER TABLE public.recibo_correlativos ENABLE ROW LEVEL SECURITY;
-- Sin policies: solo el trigger (SECURITY DEFINER) y el service role lo tocan.

-- ── 2) Backfill: arrancar el contador en el MAX actual (incluye anulados, que
--        NO reutilizan número — igual que el device). ─────────────────────────
INSERT INTO public.recibo_correlativos (tenant_id, prefijo, ultimo)
SELECT tenant_id, prefijo, MAX(correlativo)
  FROM public.recibos
 GROUP BY tenant_id, prefijo
ON CONFLICT (tenant_id, prefijo)
  DO UPDATE SET ultimo = GREATEST(public.recibo_correlativos.ultimo, EXCLUDED.ultimo);

-- ── 3) Trigger BEFORE INSERT: asigna correlativo + numero_completo. ──────────
-- SECURITY DEFINER: el cobrador que inserta el recibo no tiene acceso RLS al
-- contador; el trigger corre como owner (bypassa RLS) para incrementarlo.
CREATE OR REPLACE FUNCTION public.recibos_asignar_correlativo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_next int;
BEGIN
  INSERT INTO public.recibo_correlativos (tenant_id, prefijo, ultimo)
  VALUES (NEW.tenant_id, NEW.prefijo, 1)
  ON CONFLICT (tenant_id, prefijo)
    DO UPDATE SET ultimo = public.recibo_correlativos.ultimo + 1
  RETURNING ultimo INTO v_next;

  NEW.correlativo := v_next;
  NEW.numero_completo := NEW.prefijo || '-' || lpad(v_next::text, 5, '0');
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS recibos_asignar_correlativo_trg ON public.recibos;
CREATE TRIGGER recibos_asignar_correlativo_trg
  BEFORE INSERT ON public.recibos
  FOR EACH ROW EXECUTE FUNCTION public.recibos_asignar_correlativo();

-- ── 4) Red final: unique. Con el trigger NUNCA se viola (asigna antes), pero
--        garantiza a nivel de esquema que no puede haber dos iguales. ─────────
ALTER TABLE public.recibos
  ADD CONSTRAINT recibos_tenant_prefijo_correlativo_uq
  UNIQUE (tenant_id, prefijo, correlativo);

-- ── Verificación dentro de la transacción. ───────────────────────────────────
SELECT 'contadores_creados' AS chk, count(*)::text AS n FROM public.recibo_correlativos
UNION ALL
SELECT 'trigger_ok',
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid='public.recibos'::regclass AND tgname='recibos_asignar_correlativo_trg')
UNION ALL
SELECT 'unique_ok',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid='public.recibos'::regclass AND conname='recibos_tenant_prefijo_correlativo_uq');

COMMIT;


-- >>> Migration: 0216_cuotas_forzar_derivados.sql <<<
-- 0216 — El SERVER es el único autor de las columnas DERIVADAS de la cuota.
--
-- PROBLEMA (BUG #1 + finding F2 de la auditoría 2026-08-02): `cuota.monto_pagado`,
-- `cuota.cargos_neto` y `cuota.estado` son columnas que un TRIGGER server mantiene
-- (`recalcular_cuota_desde_pagos` 0083; `cargos_extra_actualizar_neto` 0023), pero
-- el CLIENTE también las escribe (espejo offline) desde 3 repos (pagos_repo,
-- contratos_repo, cuotas_repo) y PowerSync sube ese UPDATE. Como NINGÚN trigger
-- en `cuotas` las protege, el UPDATE del device PISA el valor correcto del server
-- (verificado en prod: los únicos triggers de cuotas miran cobrador/notif, no
-- estas columnas). Si el device tenía un valor viejo (otro device cobró/ajustó
-- la misma cuota sin sincronizar), desinfla/infla en silencio → re-cobro, o
-- crédito/descuento que "desaparece". Caso real: Marcos (cuota 1832 con 2 pagos
-- de 916 → decía 916). Contradice "server gana" (invariante #3) e INV2/3/12/14.
--
-- FIX: trigger BEFORE UPDATE en `cuotas` que RECALCULA las 3 columnas desde la
-- verdad del server, IGNORANDO lo que mandó el device. Es la versión permanente
-- y preventiva de lo que hoy hace a mano `super_admin_corregir_invariantes` (0189)
-- — convierte INV2/3/12/14 de "mantenidos" a ENFORZADOS.
--
-- GUARDAS (findings F6 y punto 4 de la auditoría):
--   - NO recomputa `estado` si es 'anulada': suspensión / absorción por cambio de
--     fecha / cambio de plan setean estado='anulada' desde el cliente; revertirlo
--     rompería esos flujos y no dispararía `trg_cuotas_anular_pagos_asociados`.
--   - NO recomputa `estado` de cuotas de cargo manual (`tipo_cargo_manual`), igual
--     que la excepción del corrector 0189.
--   - `monto_pagado` y `cargos_neto` SIEMPRE se fuerzan (también en anuladas: son
--     inocuas ahí y así nunca quedan pisadas).
--
-- Idempotente y sin recursión: modifica NEW (no emite UPDATE). Convive con el
-- AFTER `recalcular_cuota_desde_pagos` (su UPDATE dispara este BEFORE, que
-- recomputa el MISMO valor). Overhead: 2 subqueries por UPDATE de cuota
-- (aceptable; reasignación masiva / re-fechado). Server-only, sin build de app.
--
-- NOTA co-diseño cuarentena (Fase 2): cuando exista `pagos.en_revision`, el SUM
-- de acá debe pasar a `anulado=false AND en_revision=false` (predicado canónico).

BEGIN;

CREATE OR REPLACE FUNCTION public.cuotas_forzar_derivados()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_pagado numeric(10,2);
  v_cargos numeric(10,2);
  v_total  numeric(10,2);
BEGIN
  -- monto_pagado: SIEMPRE = SUM(pagos vivos). El cliente NUNCA es autor.
  SELECT COALESCE(SUM(monto_cordobas), 0) INTO v_pagado
    FROM public.pagos WHERE cuota_id = NEW.id AND anulado = false;
  NEW.monto_pagado := v_pagado;

  -- cargos_neto: SIEMPRE = calcular_cargos_neto (reconexión/otro suman;
  -- descuento/crédito restan). Cierra F2 (clobber de cargos_neto) y usa el signo
  -- correcto que a 0189 le faltaba (F5).
  v_cargos := public.calcular_cargos_neto(NEW.id);
  NEW.cargos_neto := v_cargos;

  -- estado: derivar (= recalcular_cuota_desde_pagos), salvo anulada / cargo manual.
  -- v_total = cuota_total_a_cobrar, calculado con los valores NEW (correcto
  -- durante un cambio de plan que altere NEW.monto).
  IF NEW.estado <> 'anulada' AND NEW.tipo_cargo_manual IS NULL THEN
    v_total := NEW.monto + COALESCE(v_cargos, 0);
    IF v_total <= 0 THEN
      NEW.estado := 'pagada';        -- condonada (descuento 100%)
    ELSIF v_pagado <= 0 THEN
      NEW.estado := 'pendiente';
    ELSIF v_pagado < v_total THEN
      NEW.estado := 'parcial';
    ELSE
      NEW.estado := 'pagada';
    END IF;
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS cuotas_forzar_derivados_trg ON public.cuotas;
CREATE TRIGGER cuotas_forzar_derivados_trg
  BEFORE UPDATE ON public.cuotas
  FOR EACH ROW EXECUTE FUNCTION public.cuotas_forzar_derivados();

-- Verificación.
SELECT 'trigger_ok' AS chk,
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid='public.cuotas'::regclass AND tgname='cuotas_forzar_derivados_trg');

COMMIT;


-- >>> Migration: 0217_fix_corrector_cargos_neto.sql <<<
-- 0217 — Fix F5 (auditoría 2026-08-02): el corrector de invariantes recalculaba
-- cargos_neto SIN signo.
--
-- `super_admin_corregir_invariantes` (0189) hacía en su bloque INV14:
--   SET cargos_neto = SUM(ce.monto)
-- que suma TODOS los cargos_extra como positivos. Pero `cargos_neto` es NETO:
-- reconexión/otro SUMAN, descuento_monto/descuento_porcentaje/credito_aplicado
-- RESTAN (ver `calcular_cargos_neto`, 0023). En un tenant con descuentos o
-- crédito aplicado, correr el corrector INFLABA cargos_neto → corrompía el total
-- a cobrar y el saldo (INV14). Hoy sin daño (INV14=0) pero es un footgun.
--
-- FIX: usar `calcular_cargos_neto(q.id)` (el mismo helper con signo que usa el
-- trigger 0216). CREATE OR REPLACE idempotente; se parte de la definición VIGENTE
-- en prod y se cambia SOLO el bloque INV14 (regla del proyecto). Los bloques
-- INV2/INV3/INV17 quedan verbatim.

BEGIN;

CREATE OR REPLACE FUNCTION public.super_admin_corregir_invariantes(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_fixed jsonb := '{}'::jsonb;
  v_count int;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede ejecutar esta operación.';
  END IF;

  -- ── INV14: re-sync cargos_neto ──
  -- Va ANTES de INV3 porque el estado depende de cargos_neto.
  -- FIX F5 (2026-08-02): `calcular_cargos_neto` respeta el SIGNO (reconexión/otro
  -- suman; descuento_*/credito_aplicado restan). Antes SUM(ce.monto) sin signo.
  UPDATE cuotas q
  SET cargos_neto = public.calcular_cargos_neto(q.id)
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND COALESCE(q.cargos_neto, 0) <> public.calcular_cargos_neto(q.id);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV14', v_count);

  -- ── INV2: re-sync monto_pagado ──
  -- Va ANTES de INV3 porque el estado depende de monto_pagado.
  UPDATE cuotas q
  SET monto_pagado = COALESCE((
    SELECT SUM(p.monto_cordobas) FROM pagos p
    WHERE p.cuota_id = q.id AND p.anulado = false
  ), 0)
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND q.monto_pagado <> COALESCE((
      SELECT SUM(p.monto_cordobas) FROM pagos p
      WHERE p.cuota_id = q.id AND p.anulado = false
    ), 0);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV2', v_count);

  -- ── INV3: re-sync estado basado en monto_pagado vs total ──
  UPDATE cuotas q
  SET estado = CASE
    WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) THEN 'pagada'
    WHEN q.monto_pagado > 0 THEN 'parcial'
    ELSE 'pendiente'
  END
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND q.tipo_cargo_manual IS NULL
    AND q.estado <> CASE
      WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) THEN 'pagada'
      WHEN q.monto_pagado > 0 THEN 'parcial'
      ELSE 'pendiente'
    END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV3', v_count);

  -- ── INV17: regenerar colchón para contratos indefinidos ──
  SELECT COUNT(*) INTO v_count
  FROM contratos c
  WHERE c.tenant_id = p_tenant
    AND c.duracion_meses IS NULL
    AND c.estado = 'activo'
    AND (
      SELECT COUNT(*) FROM cuotas q2
      WHERE q2.contrato_id = c.id
        AND q2.estado IN ('pendiente','parcial')
        AND q2.tipo_cargo_manual IS NULL
        AND q2.periodo >= date_trunc('month', CURRENT_DATE)::date
    ) < 3;

  PERFORM public.generar_cuotas_contrato(c.id)
  FROM contratos c
  WHERE c.tenant_id = p_tenant
    AND c.duracion_meses IS NULL
    AND c.estado = 'activo'
    AND (
      SELECT COUNT(*) FROM cuotas q2
      WHERE q2.contrato_id = c.id
        AND q2.estado IN ('pendiente','parcial')
        AND q2.tipo_cargo_manual IS NULL
        AND q2.periodo >= date_trunc('month', CURRENT_DATE)::date
    ) < 3;

  v_fixed := v_fixed || jsonb_build_object('INV17', v_count);

  RETURN v_fixed;
END;
$function$;

COMMIT;


-- >>> Migration: 0218_cuarentena_en_revision.sql <<<
-- 0218 — CUARENTENA de cobros duplicados ("en revisión"). FUNDACIÓN SERVER.
--
-- Objetivo (pedido de Rubén, diseño aprobado): un sobrepago NO-exacto sobre una
-- cuota (típico: 2 devices de la cuenta "Oficina" cobran la misma cuota sin
-- sincronizar) NO debe inflar la caja hasta que una persona decida cuál pago es
-- el verdadero. Hoy los dos cuentan → efectivo inexistente en la ventana de
-- revisión. El guard 0214 ya auto-anula los duplicados EXACTOS; esto cubre los
-- NO exactos, poniéndolos "en revisión" (excluidos de TODA métrica) en vez de
-- dejarlos contar.
--
-- PREDICADO CANÓNICO: "pago que cuenta" = anulado=false AND en_revision=false.
-- Se aplica acá en el server (guard + recalcular + trigger 0216 + VIEW). La otra
-- mitad (queries de caja del CLIENTE + rediseño de "Cobros a revisar" por flag)
-- va en el mismo release de la app. ⚠️ NO aplicar esta migración sola: dejaría
-- el pago en revisión INVISIBLE (fuera de monto_pagado, no dispara el "Cobros a
-- revisar" derivado) pero TODAVÍA contando en los dashboards del cliente.
--
-- Co-diseñado con el fix #1 (0216): el mismo predicado en las 3 funciones que
-- suman pagos server-side.

BEGIN;

-- ── 1) Columnas (aditivas). ──────────────────────────────────────────────────
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS en_revision boolean NOT NULL DEFAULT false;
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS revision_motivo text;

-- Índice para la pantalla de revisión (busca los en_revision del tenant).
CREATE INDEX IF NOT EXISTS pagos_en_revision_idx
  ON public.pagos (tenant_id) WHERE en_revision = true;

-- ── 2) VIEW canónica (para queries server-side; el cliente filtra en Dart). ──
CREATE OR REPLACE VIEW public.pagos_contables
  WITH (security_invoker = true) AS
  SELECT * FROM public.pagos WHERE anulado = false AND en_revision = false;

-- ── 3) Guard 0214: sobrepago NO exacto → EN REVISIÓN (antes: lo dejaba contar).
-- También excluye en_revision del SUM de "ya pagado" (un pago en cuarentena no
-- cuenta para el chequeo de sobrepago del siguiente).
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
    return new;
  end if;

  -- Excede pero NO es copia exacta → CUARENTENA (antes: return new = contaba).
  new.en_revision    := true;
  new.revision_motivo := coalesce(new.revision_motivo,
    'Sobrepago: excede el total de la cuota. Requiere decidir cuál cobro es el verdadero.');
  return new;
end $function$;

-- ── 4) recalcular_cuota_desde_pagos: el SUM excluye en_revision. ─────────────
CREATE OR REPLACE FUNCTION public.recalcular_cuota_desde_pagos()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  if tg_table_name not in ('pagos','cargos_extra') then
    return coalesce(new, old);
  end if;
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0) into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false and en_revision = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then return coalesce(new, old); end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);
  if v_total_a_cobrar <= 0 then v_nuevo_estado := 'pagada';
  elsif v_total_pagado <= 0 then v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then v_nuevo_estado := 'parcial';
  else v_nuevo_estado := 'pagada'; end if;

  update public.cuotas
     set monto_pagado = v_total_pagado, estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;
  return coalesce(new, old);
end $function$;

-- ── 5) Trigger 0216 (cuotas_forzar_derivados): el SUM excluye en_revision. ───
CREATE OR REPLACE FUNCTION public.cuotas_forzar_derivados()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_pagado numeric(10,2); v_cargos numeric(10,2); v_total numeric(10,2);
BEGIN
  SELECT COALESCE(SUM(monto_cordobas),0) INTO v_pagado
    FROM public.pagos WHERE cuota_id=NEW.id AND anulado=false AND en_revision=false;
  NEW.monto_pagado := v_pagado;
  v_cargos := public.calcular_cargos_neto(NEW.id); NEW.cargos_neto := v_cargos;
  IF NEW.estado <> 'anulada' AND NEW.tipo_cargo_manual IS NULL THEN
    v_total := NEW.monto + COALESCE(v_cargos,0);
    IF v_total <= 0 THEN NEW.estado := 'pagada';
    ELSIF v_pagado <= 0 THEN NEW.estado := 'pendiente';
    ELSIF v_pagado < v_total THEN NEW.estado := 'parcial';
    ELSE NEW.estado := 'pagada'; END IF;
  END IF;
  RETURN NEW;
END; $fn$;

-- ── 6) RPCs server que suman pagos → excluir en_revision (predicado canónico).
-- Se hace por string-replace de la def VIGENTE (evita transcribir a mano; los
-- substrings son exactos y únicos). Guardado para no duplicar si se re-corre.
DO $$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.get_cobrador_stats'::regproc);
  IF position('p.en_revision' in v) = 0 THEN
    v := replace(v, 'and p.anulado = false',
                    'and p.anulado = false and p.en_revision = false');
    EXECUTE v;
  END IF;
END $$;

DO $$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc);
  IF position('en_revision = false group by cuota_id' in v) = 0 THEN
    -- INV2: monto_pagado = SUM(pagos que cuentan)
    v := replace(v, 'where anulado = false group by cuota_id',
                    'where anulado = false and en_revision = false group by cuota_id');
    -- INV12: recaudado por contrato = SUM(pagos que cuentan)
    v := replace(v, 'where cu2.contrato_id = ct.id and pa.anulado = false',
                    'where cu2.contrato_id = ct.id and pa.anulado = false and pa.en_revision = false');
    EXECUTE v;
  END IF;
END $$;

SELECT 'cols_ok' AS chk,
  (SELECT count(*)::text FROM information_schema.columns
    WHERE table_name='pagos' AND column_name IN ('en_revision','revision_motivo'))
UNION ALL
SELECT 'get_cobrador_stats_en_revision',
  CASE WHEN position('p.en_revision' in pg_get_functiondef('public.get_cobrador_stats'::regproc)) > 0
       THEN 'ok' ELSE 'FALTA' END
UNION ALL
SELECT 'verificar_invariantes_en_revision',
  CASE WHEN position('en_revision = false group by cuota_id' in pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN 'ok' ELSE 'FALTA' END;

COMMIT;


-- >>> Migration: 0219_fix_mojibake_verificar_invariantes.sql <<<
-- 0219 — Fix mojibake en super_admin_verificar_invariantes (INV11).
--
-- SÍNTOMA: el panel "Verificar invariantes de dinero" marcaba INV11 ("contrato
-- fijo con cuotas de más o de menos") como violación en contratos fijos que
-- tuvieron una SUSPENSIÓN (ej. Martha Lorena Ramos Cueva, Mairena, contrato 3965:
-- 11 cuotas vivas + 1 anulada por suspensión, esperadas 12). La DATA está
-- CORRECTA: la suspensión anuló bien el mes (no se factura y fecha_fin no se
-- estira), por lo que 11 cobrables en un contrato de 12 meses es lo esperado.
--
-- CAUSA: el INV11 del RPC REINTEGRA al conteo las cuotas anuladas con
-- motivo_anulacion='Suspensión temporal' (activas + gap-suspendido = duracion),
-- pero ese literal quedó con la "ó" CORRUPTA — 'SuspensiÃ³n temporal' (bytes UTF-8
-- de "ó" leídos como Latin-1). Como la data tiene la "ó" correcta, la comparación
-- NUNCA matcheaba → la reintegración no sumaba → falso positivo permanente en
-- todo contrato fijo suspendido-y-reactivado. Se coló al re-crear la función por
-- string-replace (0218) bajo una sesión con encoding equivocado. El
-- invariantes_dinero.sql canónico NO tiene el bug (tiene la 'ó' correcta).
--
-- FIX: revertir el mojibake de TODA la definición con un round-trip LATIN1<->UTF8.
-- La función es ASCII + caracteres Latin-1 (los acentos mal codificados están en
-- el rango U+0080..U+00FF); sin chars > 0xFF, el round-trip solo re-decodifica los
-- acentos y deja el ASCII intacto. Es un chequeo de LECTURA: no toca dinero.

DO $$
DECLARE v text; hi int;
BEGIN
  v := pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc);
  -- ¿algún char fuera de Latin-1? Si no, el round-trip es seguro.
  SELECT count(*) INTO hi
    FROM regexp_split_to_table(v, '') s
   WHERE ascii(s) > 255;
  IF hi = 0 THEN
    v := convert_from(convert_to(v, 'LATIN1'), 'UTF8');
  ELSE
    -- Fallback conservador: arreglar solo la "ó" (Ã³ -> ó), que es la crítica.
    v := replace(v, chr(195) || chr(179), chr(243));
  END IF;
  EXECUTE v;
END $$;

-- Verificación: la comparación de INV11 ahora usa la "ó" correcta y NO queda
-- mojibake ('Ã', chr(195)) en la definición.
SELECT 'inv11_suspension_ok' AS chk,
  CASE WHEN position('Suspensi' || chr(243) || 'n temporal'
         in pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN 'ok' ELSE 'FALTA' END AS estado
UNION ALL
SELECT 'sin_mojibake',
  CASE WHEN position(chr(195)
         in pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) = 0
       THEN 'ok' ELSE 'QUEDA' END;


-- >>> Migration: 0220_guards_integridad.sql <<<
-- 0220 — Guards, triggers y constraints de integridad.
--
-- Cinco bloques independientes (ninguno toca DATA existente; esto es
-- PREVENCIÓN, la reparación de lo que ya está mal va en 0221):
--   (a) No desactivar un cliente que tiene deuda (regla del dueño:
--       "desactivado = sin servicio Y saldado").
--   (b) Desempaquetado del jsonb doble-encodeado de los checklists de tickets
--       (mismo patrón que 0194 para solicitudes_accion.datos).
--   (c) Guard `id <> new.id` en el correlativo de recibos: un re-upsert de
--       reintento de PowerSync renumeraba un recibo YA IMPRESO.
--   (d) Constraints baratos que hoy dan 0 violaciones (verificado con SELECT,
--       ver los conteos al pie de cada bloque).
--   (e) INV18/INV19/INV20 en `super_admin_verificar_invariantes`.
--
-- OJO: ENCODING (lección 0218 → 0219): 0218 re-creó el RPC de invariantes bajo una
-- sesión con encoding equivocado y dejó 'SuspensiÃ³n temporal' como literal de
-- COMPARACIÓN contra data → falso positivo permanente en INV11. 0219 intentó el
-- round-trip LATIN1<->UTF8 pero cayó al fallback conservador (la definición tenía
-- un '→' cuyo mojibake incluye '†' = U+2020 > 255) y solo reparó la "ó": HOY
-- siguen mojibakeados INV7 ('Ãºnico'), INV13 ('vacÃ­o') e INV16 ('ningÃºn ...
-- mÃ©todo ... crÃ©dito'), verificado con
--   SELECT count(*) FROM regexp_matches(
--     pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc),
--     chr(195), 'g');                                          -- devolvió 8
-- Por eso esta migración: (1) fuerza `client_encoding = 'UTF8'`, (2) escribe los
-- literales acentuados correctos, (3) arma el único literal que se COMPARA con
-- data ('Suspensión temporal') con chr(243) — a prueba de encoding —, y (4) no
-- vuelve a meter '→' (usa '->' ASCII) para que un round-trip futuro no falle.
SET client_encoding = 'UTF8';

BEGIN;

-- ===========================================================================
-- (a) GUARD: no desactivar un cliente con deuda.
--
-- REGLA (dueño): desactivar un cliente = ya NO tiene servicio Y está SALDADO.
-- Mientras tenga deuda debe seguir ACTIVO: así se le sigue cobrando y aparece
-- en la reportería, aunque su contrato esté cancelado.
--
-- POR QUÉ EN EL SERVER: hoy el bloqueo vive SOLO en la app
-- (`cliente_form_screen.dart` — "para no dejar deuda invisible acumulándose" —
-- y `solicitudes_repo.dart`), y además chequea otra cosa (contratos activos,
-- no deuda). Un segundo device, la aprobación de una solicitud, o cualquier
-- camino que no pase por ese form, lo saltea. El server es el chokepoint real.
--
-- OJO: POR QUÉ SOLO LA TRANSICIÓN true -> false (crítico):
-- PowerSync clasifica P0001 (RAISE EXCEPTION) como error PERMANENTE
-- (`esCodigoNoRetryable` en `connector.dart`): avisa al usuario, registra el
-- rechazo y DESCARTA la op para no trabar la cola — o sea, el device queda
-- divergente del server hasta que la fila vuelva a bajar por sync.
-- Si el guard disparara en CUALQUIER update de un cliente inactivo con deuda,
-- los ~75 clientes que HOY ya están en ese estado inválido (35 con contrato
-- activo, todos en Telecable Mairena) quedarían con TODAS sus escrituras
-- rechazadas para siempre: cambiarles el teléfono, la geo o el cobrador
-- fallaría en silencio. Con el guard atado a la transición, esos clientes
-- siguen editándose normal (old.activo = false → no hay transición) y el
-- camino de salida — REACTIVARLOS (false -> true) — nunca se bloquea.
-- La reparación de esas filas es 0221; este guard solo frena casos NUEVOS.
--
-- Alcance de "deuda": cuotas pendiente/parcial con saldo canónico > 0.01
-- (`monto + cargos_neto − monto_pagado`, invariante #10). NO se filtra por
-- estado del contrato a propósito: la deuda de un contrato cancelado sigue
-- siendo deuda y se cobra igual.
--
-- COSTO: el trigger corre en TODO update de `clientes`, y hay dos que pegan
-- fuerte — `recalc_vencimiento_mas_viejo` (0185, dispara con cada cambio de
-- cuota) y `reasignar_cobrador_masivo` (0154, bulk). Por eso el chequeo caro
-- (el count sobre cuotas) queda DESPUÉS del early-return: en esos casos el
-- trigger son dos comparaciones de booleano y se va.
--
-- ORDEN vs 0221: da igual cuál corra primero. 0221 solo hace `activo = false ->
-- true` (reactivar), que este guard nunca bloquea.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.clientes_guard_desactivar_con_deuda_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_cuotas int;
  v_saldo  numeric;
BEGIN
  -- Solo la transición ACTIVO -> INACTIVO (ver el bloque de arriba).
  IF NOT (old.activo = true AND new.activo = false) THEN
    RETURN new;
  END IF;

  SELECT count(*),
         coalesce(sum(cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado), 0)
    INTO v_cuotas, v_saldo
    FROM public.cuotas cu
   WHERE cu.cliente_id = new.id
     AND cu.estado IN ('pendiente', 'parcial')
     AND (cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado) > 0.01;

  IF v_cuotas > 0 THEN
    RAISE EXCEPTION
      'No se puede desactivar a %: tiene % cuota(s) con saldo pendiente por C$%. Un cliente desactivado no debe tener deuda: cobrale o anulá esas cuotas primero.',
      coalesce(new.nombre, '(sin nombre)'),
      v_cuotas,
      to_char(v_saldo, 'FM999999990.00');
  END IF;

  RETURN new;
END $fn$;

DROP TRIGGER IF EXISTS trg_clientes_guard_desactivar ON public.clientes;
CREATE TRIGGER trg_clientes_guard_desactivar
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_guard_desactivar_con_deuda_trg();

-- ===========================================================================
-- (b) Desempaquetado del jsonb doble-encodeado de los checklists.
--
-- MISMO BUG QUE 0194 (`solicitudes_accion.datos`): PowerSync sube el valor de
-- una columna jsonb como STRING JSON literal, y Postgres lo guarda como un
-- ESCALAR jsonb ("[]") en vez de un array. Verificado hoy: 3 de 6 `tickets` y
-- 1 de 3 `ticket_tipos` están así. El daño real es CERO porque todos los
-- corruptos están vacíos, pero es un bug LATENTE: el día que alguien guarde un
-- checklist con ítems, toda query que haga jsonb_array_elements / ->> sobre esa
-- columna revienta o devuelve nada.
--
-- SIN CHECK `jsonb_typeof(...) = 'array'` A PROPÓSITO: si el trigger se cayera
-- (un DROP accidental, un restore parcial), un CHECK haría que PowerSync
-- descartara CADA escritura de ticket en silencio — el remedio sería peor que
-- la enfermedad. El trigger repara; el CHECK castigaría.
--
-- Repara solo lo que se ESCRIBE de acá en más. Las 3+1 filas ya corruptas las
-- normaliza 0221 (reparación de datos).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fix_ticket_checklist_jsonb()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF jsonb_typeof(new.checklist) = 'string' THEN
    new.checklist := (new.checklist #>> '{}')::jsonb;
  END IF;
  RETURN new;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_fix_ticket_checklist ON public.tickets;
CREATE TRIGGER trg_fix_ticket_checklist
  BEFORE INSERT OR UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.fix_ticket_checklist_jsonb();

CREATE OR REPLACE FUNCTION public.fix_ticket_tipo_checklist_jsonb()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF jsonb_typeof(new.checklist_template) = 'string' THEN
    new.checklist_template := (new.checklist_template #>> '{}')::jsonb;
  END IF;
  RETURN new;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_fix_ticket_tipo_checklist ON public.ticket_tipos;
CREATE TRIGGER trg_fix_ticket_tipo_checklist
  BEFORE INSERT OR UPDATE ON public.ticket_tipos
  FOR EACH ROW EXECUTE FUNCTION public.fix_ticket_tipo_checklist_jsonb();

-- ===========================================================================
-- (c) `recibos_asignar_correlativo`: guard de re-upsert.
--
-- PROBLEMA: el trigger es BEFORE INSERT, y el reintento de un batch de
-- PowerSync re-manda la fila como upsert (`INSERT ... ON CONFLICT DO UPDATE`).
-- En Postgres los triggers BEFORE INSERT corren ANTES de detectar el
-- conflicto → el trigger incrementa el contador y REESCRIBE `correlativo` +
-- `numero_completo`, y el DO UPDATE guarda ese número nuevo (EXCLUDED hereda
-- el NEW post-trigger). Resultado: un recibo YA IMPRESO cambia de número en
-- cada reintento, y encima se quema un correlativo por vuelta.
--
-- FIX: si la fila ya existe (mismo id), esto NO es un recibo nuevo → conservar
-- el correlativo y el numero_completo que ya tiene y no tocar el contador. Es
-- el análogo del `id <> new.id` que `tickets_correlativo_trg` (0116) tuvo que
-- agregar por exactamente el mismo motivo ("sin esto, el RE-UPSERT de un retry
-- de PowerSync encontraba SU PROPIA fila como conflicto y renumeraba").
--
-- El cuerpo parte de la ÚLTIMA definición VIGENTE (verificada con
-- `pg_get_functiondef('public.recibos_asignar_correlativo'::regproc)`, idéntica
-- a la de 0215) — regla de AGENTS: un CREATE OR REPLACE acumulativo escrito
-- desde un cuerpo viejo PIERDE cambios en silencio (lección 0151/0152).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.recibos_asignar_correlativo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_next int;
  v_correlativo int;
  v_numero text;
BEGIN
  -- Re-upsert de reintento: la fila ya está guardada con SU número. Devolverlo
  -- tal cual (idempotente) en vez de asignar uno nuevo.
  SELECT r.correlativo, r.numero_completo
    INTO v_correlativo, v_numero
    FROM public.recibos r
   WHERE r.id = new.id;

  IF FOUND THEN
    new.correlativo := v_correlativo;
    new.numero_completo := v_numero;
    RETURN new;
  END IF;

  INSERT INTO public.recibo_correlativos (tenant_id, prefijo, ultimo)
  VALUES (new.tenant_id, new.prefijo, 1)
  ON CONFLICT (tenant_id, prefijo)
    DO UPDATE SET ultimo = public.recibo_correlativos.ultimo + 1
  RETURNING ultimo INTO v_next;

  new.correlativo := v_next;
  new.numero_completo := new.prefijo || '-' || lpad(v_next::text, 5, '0');
  RETURN new;
END;
$fn$;

-- ===========================================================================
-- (d) Constraints seguros — los 4 dan 0 violaciones HOY (verificado con):
--
--   SELECT (SELECT count(*) FROM public.pagos WHERE monto_cordobas < 0)   AS pagos_neg,          -- 0
--          (SELECT count(*) FROM public.inv_movimientos WHERE cantidad <= 0) AS mov_no_pos,      -- 0
--          (SELECT count(*) FROM public.tickets WHERE tipo_id IS NULL)    AS tickets_sin_tipo,   -- 0
--          (SELECT count(*) FROM (SELECT tenant_id, nombre FROM public.ticket_tipos
--                                  GROUP BY 1,2 HAVING count(*) > 1) d)   AS tipos_dup;          -- 0
--
-- Tamaños (el ACCESS EXCLUSIVE de cada ALTER es de milisegundos): pagos 29.036,
-- cuotas 57.005, clientes 6.096, tickets 6, ticket_tipos 3, inv_movimientos 8.
--
-- NO se agregan (a propósito):
--   · FK RESTRICT en `recibos.pago_id` / `cargos_extra.pago_id` → rompería
--     "Operaciones de datos": `0147_data_ops_funciones.sql` BORRA pagos y
--     DEPENDE de la cascada (hasta cuenta los recibos en su backup).
--   · UNIQUEs parciales en `contrato_suspensiones` / `solicitudes_accion`.
-- ===========================================================================

-- d.1 — `pagos.monto_cordobas >= 0`: es lo APLICADO a la cuota (invariante #1),
-- nunca puede ser negativo. `monto_original` y `vuelto_cordobas` ya tienen su
-- CHECK >= 0 desde el origen; el que entra a caja no lo tenía.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pagos'::regclass
                    AND conname = 'pagos_monto_cordobas_check') THEN
    ALTER TABLE public.pagos
      ADD CONSTRAINT pagos_monto_cordobas_check CHECK (monto_cordobas >= 0);
  END IF;
END $$;

-- d.2 — `ticket_tipos (tenant_id, nombre)` único. Dos tipos con el mismo nombre
-- son indistinguibles en el selector y parten el SLA/reportería en dos. Seguro
-- porque el borrado de un tipo es DELETE real (`ticket_tipos_screen.dart`, con
-- guard de "en uso"), no un soft-delete que dejaría el nombre ocupado.
-- Efecto en offline: si dos admin crean el mismo nombre sin sincronizar, el 2º
-- write se rechaza (23505 = permanente) con aviso al usuario. Es lo buscado.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.ticket_tipos'::regclass
                    AND conname = 'ticket_tipos_tenant_nombre_uq') THEN
    ALTER TABLE public.ticket_tipos
      ADD CONSTRAINT ticket_tipos_tenant_nombre_uq UNIQUE (tenant_id, nombre);
  END IF;
END $$;

-- d.3 — `inv_movimientos.cantidad > 0`. En este ledger la cantidad es una
-- MAGNITUD y la dirección la da origen/destino (stock =
-- SUM(destino) − SUM(origen)); incluso el 'ajuste' de resta se guarda positivo
-- con `ubicacion_origen_id` seteado (`inv_stock_flows.dart`). Una cantidad <= 0
-- solo puede venir de un bug y desbalancea el stock sin dejar rastro.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.inv_movimientos'::regclass
                    AND conname = 'inv_movimientos_cantidad_check') THEN
    ALTER TABLE public.inv_movimientos
      ADD CONSTRAINT inv_movimientos_cantidad_check CHECK (cantidad > 0);
  END IF;
END $$;

-- d.4 — `tickets.tipo_id NOT NULL`. El tipo define SLA, efecto (instalación/
-- corte/reconexión) y precio: un ticket sin tipo no se puede priorizar ni
-- facturar. El único INSERT del código ya lo exige
-- (`ticket_form_screen.dart:472` → "Elegí un tipo de ticket."), así que el
-- NOT NULL solo cierra el hueco de un write por REST/SQL. Re-correrlo es no-op.
ALTER TABLE public.tickets ALTER COLUMN tipo_id SET NOT NULL;

-- ===========================================================================
-- (e) `super_admin_verificar_invariantes`: se reponen INV18 y se agregan
--     INV19 + INV20.
--
-- El cuerpo parte de la ÚLTIMA DEFINICIÓN VIGENTE leída de la base
-- (`pg_get_functiondef`), NO de una migración vieja — regla de AGENTS
-- (lección 0151/0152: reescribir desde un cuerpo viejo dropea llamadas sin
-- avisar). INV1..INV17 quedan textualmente iguales salvo los acentos, que se
-- escriben BIEN (ver la nota de encoding del encabezado).
--
--   · INV18 — ya existía en `supabase/tests/invariantes_dinero.sql` pero NUNCA
--     se había agregado al RPC (divergencia entre las dos herramientas: el
--     panel del super_admin no lo chequeaba). Se repone TAL CUAL del archivo
--     canónico; verificado que hoy da 0 violaciones en toda la base. Si no se
--     lo quiere en el panel, se borra el CTE `inv18` y su línea del UNION.
--   · INV19 — NUEVO: cliente activo = false con cuotas pendientes/parciales con
--     saldo > 0. Es el estado que el guard (a) prohíbe hacia adelante; este
--     invariante lo hace VISIBLE. Hoy: 75 (69 Mairena + 6 Telenet).
--     OJO: 0221 reactiva SOLO los 35 que además tienen el contrato ACTIVO (su
--     alcance aprobado), así que después de 0221 este invariante va a seguir
--     mostrando ~40 — los que tienen el contrato suspendido/cancelado pero
--     igual deben plata. NO es que la reparación falló: es la decisión de
--     producto que quedó pendiente (ver el comentario de alcance en 0221).
--   · INV20 — NUEVO: `clientes.vencimiento_mas_viejo` divergente del valor real.
--     El predicado es EXACTAMENTE el de `recalc_vencimiento_mas_viejo` (leída
--     viva; definición vigente = 0185): MIN(fecha_vencimiento) de las cuotas
--     pendiente/parcial cuyo contrato está activo (o no tiene contrato), y la
--     comparación con IS DISTINCT FROM para que NULL = NULL no cuente como
--     violación. Hoy: 9 clientes divergentes, los 9 en Telenet.
--
-- Verificado antes de escribir esto: la query completa (los 20 CTE) se corrió
-- READ-ONLY contra Mairena y contra Telenet reemplazando `p_tenant` por el uuid.
-- Resultado: INV1..INV18 = 0 en ambos (o sea, ninguna regresión al re-crear la
-- función, y el INV11 con chr(243) ya NO da el falso positivo de 0218),
-- INV19 = 69/6 e INV20 = 0/9.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.super_admin_verificar_invariantes(p_tenant uuid)
RETURNS TABLE(invariante text, violaciones bigint, ejemplo_ids text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '120s'
AS $function$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  inv1 as (
    select 'INV1: entregado = aplicado + vuelto (pagos)'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text as ejemplo_ids
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and abs((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50) t
  ),
  inv2 as (
    select 'INV2: cuota.monto_pagado = SUM(pagos aplicados)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cuota_id::text order by cuota_id))[1:10], ', '), '')::text
    from (select cu.id as cuota_id
            from public.cuotas cu
            left join (select cuota_id, sum(monto_cordobas) as pagado
                         from public.pagos where anulado = false and en_revision = false group by cuota_id) p
              on p.cuota_id = cu.id
           where cu.tenant_id = p_tenant and cu.estado <> 'anulada'
             and abs(cu.monto_pagado - coalesce(p.pagado, 0)) > 0.01) t
  ),
  inv3 as (
    select 'INV3: estado de cuota coherente con monto_pagado'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and ((estado = 'pagada'    and monto_pagado < (monto + coalesce(cargos_neto,0)) - 0.01)
               or (estado = 'pendiente' and monto_pagado > 0.01)
               or (estado = 'parcial'   and (monto_pagado <= 0.01
                     or monto_pagado >= (monto + coalesce(cargos_neto,0)) - 0.01)))) t
  ),
  inv4 as (
    select 'INV4: ninguna cuota con sobrepago (monto_pagado > total)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and monto_pagado > (monto + coalesce(cargos_neto,0)) + 0.01) t
  ),
  inv5 as (
    select 'INV5: todo pago no anulado tiene recibo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id from public.pagos p
           where p.tenant_id = p_tenant and p.anulado = false
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)) p
  ),
  inv6 as (
    select 'INV6: vuelto_cordobas >= 0'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and vuelto_cordobas < 0) t
  ),
  inv7 as (
    select 'INV7: correlativo de recibo único por cobrador+prefijo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(numero_completo order by numero_completo))[1:10], ', '), '')::text
    from (select numero_completo from public.recibos
           where tenant_id = p_tenant
           group by cobrador_id, prefijo, correlativo, numero_completo
           having count(*) > 1) t
  ),
  inv8 as (
    select 'INV8: contrato.cobrador_id = cliente.cobrador_id'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
            join public.clientes c on c.id = ct.cliente_id
           where ct.tenant_id = p_tenant and ct.estado = 'activo'
             and ct.cobrador_id is distinct from c.cobrador_id) t
  ),
  inv9 as (
    -- Solo cuotas OPERATIVAS (pendiente/parcial): el trigger 0122 congela el
    -- cobrador de las pagadas/anuladas al reasignar (auditoría) -> su mismatch es
    -- esperado, no un bug. "Quién cobró" = pagos/recibos.cobrador_id (INV5/INV7).
    select 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
           where cu.tenant_id = p_tenant and cu.contrato_id is not null
             and cu.estado in ('pendiente','parcial')
             and cu.cobrador_id is distinct from ct.cobrador_id) cu
  ),
  inv10 as (
    select 'INV10: tenant_id de hija == tenant_id de su padre (0082)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(ofensor order by ofensor))[1:10], ', '), '')::text
    from (
      select 'pago:' || p.id::text as ofensor
        from public.pagos p join public.cuotas cu on cu.id = p.cuota_id
       where p.tenant_id = p_tenant and p.cuota_id is not null and p.tenant_id <> cu.tenant_id
      union all
      select 'recibo:' || r.id::text
        from public.recibos r join public.pagos p on p.id = r.pago_id
       where r.tenant_id = p_tenant and r.pago_id is not null and r.tenant_id <> p.tenant_id
      union all
      select 'cargo:' || ce.id::text
        from public.cargos_extra ce join public.cuotas cu on cu.id = ce.cuota_id
       where ce.tenant_id = p_tenant and ce.cuota_id is not null and ce.tenant_id <> cu.tenant_id) t
  ),
  inv11 as (
    -- OJO: 'Suspensión temporal' se COMPARA contra data. Se arma con chr(243)
    -- ("ó") para que sea inmune al encoding de la sesión que corra esta
    -- migración - el mojibake de 0218 en ESTE literal produjo un falso positivo
    -- permanente en todo contrato fijo suspendido-y-reactivado (ver 0219).
    select 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is not null and ct.duracion_meses > 0
             and ((select count(*) from public.cuotas cu
                     where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                       and cu.estado <> 'anulada')
                  + (select count(*) from public.cuotas cu
                       where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                         and cu.estado = 'anulada'
                         and cu.motivo_anulacion = 'Suspensi' || chr(243) || 'n temporal'))
                 <> ct.duracion_meses) t
  ),
  inv12 as (
    select 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant
             and abs(coalesce((select sum(cu.monto_pagado) from public.cuotas cu
                                where cu.contrato_id = ct.id), 0)
                   - coalesce((select sum(pa.monto_cordobas) from public.pagos pa
                                join public.cuotas cu2 on cu2.id = pa.cuota_id
                               where cu2.contrato_id = ct.id and pa.anulado = false and pa.en_revision = false), 0)) > 0.01) t
  ),
  inv13 as (
    select 'INV13: cargos origen=ajuste son descuento_* con motivo no vacío'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ce.id from public.cargos_extra ce
           where ce.tenant_id = p_tenant and ce.origen = 'ajuste'
             and (ce.tipo not in ('descuento_monto', 'descuento_porcentaje')
                  or ce.descripcion is null or btrim(ce.descripcion) = '')) t
  ),
  inv14 as (
    select 'INV14: cuotas.cargos_neto == SUM real de cargos_extra'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
           where cu.tenant_id = p_tenant
             and abs(coalesce(cu.cargos_neto, 0)
                   - coalesce((select sum(case
                         when ce.tipo in ('reconexion','otro') then ce.monto
                         when ce.tipo in ('descuento_monto','descuento_porcentaje','credito_aplicado') then -ce.monto
                         else 0 end)
                        from public.cargos_extra ce where ce.cuota_id = cu.id), 0)) > 0.01) t
  ),
  inv15 as (
    select 'INV15: saldo a favor del cliente nunca negativo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cliente_id::text order by cliente_id))[1:10], ', '), '')::text
    from (select cliente_id from public.saldos_favor
           where tenant_id = p_tenant
           group by cliente_id
           having sum(case when tipo = 'acreditado' then monto else -monto end) < -0.005) t
  ),
  inv16 as (
    select 'INV16: ningún pago con método de crédito (crédito no es pago)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and metodo not in ('efectivo','transferencia','deposito','tarjeta')) t
  ),
  inv17 as (
    select 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchón)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is null
             and (select count(*) from public.cuotas cu
                   where cu.contrato_id = ct.id and cu.estado = 'pendiente'
                     and cu.tipo_cargo_manual is null
                     and cu.periodo > greatest(
                       date_trunc('month', (now() at time zone 'America/Managua'))::date,
                       coalesce((select max(cu2.periodo) from public.cuotas cu2
                                  where cu2.contrato_id = ct.id
                                    and cu2.estado in ('pagada', 'parcial')), '1900-01-01'::date))) < 3) t
  ),
  inv18 as (
    -- Repuesto del invariantes_dinero.sql canónico (nunca estuvo en el RPC).
    -- El guard de sobrepago (0214) es el ÚNICO que puede anular sin usuario, y
    -- solo con su motivo automático. 'automático' con chr(225) por la misma
    -- razón que INV11: se COMPARA contra data (el CHECK
    -- `pagos_anulacion_coherencia` usa ese prefijo exacto).
    select 'INV18: anulación sin actor solo si la hizo el guard (0214)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = true and anulado_por is null
             and coalesce(motivo_anulacion, '')
                 not like 'Duplicado autom' || chr(225) || 'tico:%') t
  ),
  inv19 as (
    -- NUEVO: desactivar un cliente = sin servicio Y SALDADO (regla del dueño).
    -- Un cliente inactivo con deuda es deuda INVISIBLE: no sale en las listas
    -- de cobro pero se le siguen generando/venciendo cuotas. El guard
    -- `trg_clientes_guard_desactivar` (0220-a) lo impide hacia adelante; esto
    -- expone las filas que ya quedaron así. Saldo canónico (invariante #10);
    -- NO se filtra por estado del contrato: la deuda de un contrato cancelado
    -- sigue siendo deuda.
    select 'INV19: cliente desactivado no tiene deuda pendiente'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select c.id from public.clientes c
           where c.tenant_id = p_tenant and c.activo = false
             and exists (select 1 from public.cuotas cu
                          where cu.cliente_id = c.id
                            and cu.estado in ('pendiente','parcial')
                            and (cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado) > 0.01)) t
  ),
  inv20 as (
    -- NUEVO: `clientes.vencimiento_mas_viejo` es un DENORMALIZADO que mantiene
    -- `recalc_vencimiento_mas_viejo` (definición vigente: 0185) y del que
    -- depende el color del mapa / la priorización de la ruta. Si quedó
    -- desincronizado (p.ej. una escritura que no disparó el trigger), el
    -- cobrador ve una fecha de vencimiento que no existe. El predicado es
    -- EXACTAMENTE el de esa función - MIN(fecha_vencimiento) de las cuotas
    -- pendiente/parcial cuyo contrato está activo (LEFT JOIN + COALESCE: la
    -- cuota sin contrato cuenta) - y compara con IS DISTINCT FROM para que
    -- NULL vs NULL no sea violación.
    select 'INV20: clientes.vencimiento_mas_viejo == el real (recalc)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select c.id from public.clientes c
           where c.tenant_id = p_tenant
             and c.vencimiento_mas_viejo is distinct from (
                   select min(cu.fecha_vencimiento)
                     from public.cuotas cu
                     left join public.contratos ct on ct.id = cu.contrato_id
                    where cu.cliente_id = c.id
                      and cu.estado in ('pendiente', 'parcial')
                      and coalesce(ct.estado, 'activo') = 'activo')) t
  )
  select * from inv1
  union all select * from inv2
  union all select * from inv3
  union all select * from inv4
  union all select * from inv5
  union all select * from inv6
  union all select * from inv7
  union all select * from inv8
  union all select * from inv9
  union all select * from inv10
  union all select * from inv11
  union all select * from inv12
  union all select * from inv13
  union all select * from inv14
  union all select * from inv15
  union all select * from inv16
  union all select * from inv17
  union all select * from inv18
  union all select * from inv19
  union all select * from inv20
  order by invariante;
end;
$function$;

-- ===========================================================================
-- Verificación (corre DENTRO de la transacción: si algo falta, se ve acá y se
-- puede abortar antes del COMMIT).
-- ===========================================================================
SELECT 'a_trigger_clientes' AS chk,
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid = 'public.clientes'::regclass
      AND tgname = 'trg_clientes_guard_desactivar') AS n_esperado_1
UNION ALL
SELECT 'b_trigger_tickets_checklist',
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid = 'public.tickets'::regclass
      AND tgname = 'trg_fix_ticket_checklist')
UNION ALL
SELECT 'b_trigger_ticket_tipos_checklist',
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid = 'public.ticket_tipos'::regclass
      AND tgname = 'trg_fix_ticket_tipo_checklist')
UNION ALL
SELECT 'c_guard_reupsert_recibos',
  CASE WHEN position('r.id = new.id' in
         pg_get_functiondef('public.recibos_asignar_correlativo'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
SELECT 'd1_pagos_monto_cordobas_check',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid = 'public.pagos'::regclass AND conname = 'pagos_monto_cordobas_check')
UNION ALL
SELECT 'd2_ticket_tipos_tenant_nombre_uq',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid = 'public.ticket_tipos'::regclass AND conname = 'ticket_tipos_tenant_nombre_uq')
UNION ALL
SELECT 'd3_inv_movimientos_cantidad_check',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid = 'public.inv_movimientos'::regclass AND conname = 'inv_movimientos_cantidad_check')
UNION ALL
SELECT 'd4_tickets_tipo_id_not_null',
  (SELECT CASE WHEN attnotnull THEN '1' ELSE 'FALTA' END FROM pg_attribute
    WHERE attrelid = 'public.tickets'::regclass AND attname = 'tipo_id')
UNION ALL
SELECT 'e_inv19_en_rpc',
  CASE WHEN position('INV19' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
SELECT 'e_inv20_en_rpc',
  CASE WHEN position('INV20' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
-- Los 2 literales que se COMPARAN contra data ('Suspensión temporal' en INV11,
-- 'Duplicado automático:' en INV18) tienen que haber quedado armados con chr()
-- — así son inmunes al encoding de la sesión. Se chequea que la CONSTRUCCIÓN
-- sobrevivió en el fuente (pg_get_functiondef devuelve el fuente, no el valor
-- evaluado, por eso se busca el texto 'chr(243)' y no la "ó").
SELECT 'e_inv11_literal_con_chr243',
  CASE WHEN position('chr(243)' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
SELECT 'e_inv18_literal_con_chr225',
  CASE WHEN position('chr(225)' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
-- Las ETIQUETAS visibles (INV7 'único', INV13 'vacío', INV16 'ningún/método/
-- crédito') sí van en UTF-8 directo. Si la sesión las mangleó, aparece un
-- chr(195) ('Ã') en la definición: eso es el mojibake de 0218 volviendo.
-- Si dice QUEDA-MOJIBAKE: NO commitear (ROLLBACK) y re-correr con una sesión
-- en UTF-8.
--
-- Se chequea TAMBIÉN chr(226) ('â'): todo lo acentuado del cuerpo es U+00C0..FF
-- y mangleado empieza con chr(195), pero un carácter > U+00FF (guión largo,
-- flecha, viñeta) manglea a 'â€…' — que arranca con chr(226) y el chequeo de
-- chr(195) NO lo vería. Por eso el cuerpo se escribe con '-' y '->' ASCII: un
-- char > 255 adentro es lo que hizo caer a 0219 en su fallback conservador
-- (ver la nota del encabezado). Si esto salta, hay un char alto de vuelta.
SELECT 'e_sin_mojibake',
  CASE WHEN position(chr(195) in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) = 0
        AND position(chr(226) in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) = 0
       THEN '1' ELSE 'QUEDA-MOJIBAKE' END;

COMMIT;

-- ===========================================================================
-- Verificación POST-DEPLOY (correr a mano; los conteos son de HOY y bajan a
-- medida que 0221 repara los datos):
--
--   -- INV19: clientes inactivos con deuda (hoy 75 en toda la base)
--   SELECT count(*) FROM public.clientes c
--    WHERE c.activo = false
--      AND EXISTS (SELECT 1 FROM public.cuotas cu
--                   WHERE cu.cliente_id = c.id
--                     AND cu.estado IN ('pendiente','parcial')
--                     AND (cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) > 0.01);
--
--   -- INV20: vencimiento_mas_viejo divergente (hoy 9)
--   SELECT count(*) FROM public.clientes c
--    WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
--            SELECT MIN(cu.fecha_vencimiento) FROM public.cuotas cu
--              LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
--             WHERE cu.cliente_id = c.id AND cu.estado IN ('pendiente','parcial')
--               AND COALESCE(ct.estado,'activo') = 'activo');
--
--   -- El guard (a) debe RECHAZAR esto (probar con un cliente CON deuda):
--   --   UPDATE public.clientes SET activo = false WHERE id = '<uuid-con-deuda>';
--   --   → ERROR: No se puede desactivar a ...: tiene N cuota(s) ...
--   -- y debe DEJAR PASAR el update de un cliente que YA está inactivo:
--   --   UPDATE public.clientes SET telefono = telefono WHERE activo = false ...;
-- ===========================================================================

-- ===========================================================================
-- PENDIENTE — NO lo apliqué porque `supabase/tests/invariantes_dinero.sql` NO
-- es un archivo de mi propiedad en esta tanda (varios agentes en paralelo).
-- Para dejar el .sql canónico a la par del RPC hay que agregarle estos dos CTE
-- (después de `inv18`) y sus dos líneas al UNION final. Es el MISMO predicado
-- que el RPC, sin el filtro `tenant_id = p_tenant` (el archivo corre global):
--
-- ,inv19 AS (
--   SELECT 'INV19: cliente desactivado no tiene deuda pendiente' AS invariante,
--          COUNT(*) AS violaciones,
--          COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
--   FROM (
--     SELECT c.id
--     FROM public.clientes c
--     WHERE c.activo = false
--       AND EXISTS (SELECT 1 FROM public.cuotas cu
--                    WHERE cu.cliente_id = c.id
--                      AND cu.estado IN ('pendiente','parcial')
--                      AND (cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) > 0.01)
--   ) t
-- )
-- ,inv20 AS (
--   SELECT 'INV20: clientes.vencimiento_mas_viejo == el real (recalc)' AS invariante,
--          COUNT(*) AS violaciones,
--          COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
--   FROM (
--     SELECT c.id
--     FROM public.clientes c
--     WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
--             SELECT MIN(cu.fecha_vencimiento)
--               FROM public.cuotas cu
--               LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
--              WHERE cu.cliente_id = c.id
--                AND cu.estado IN ('pendiente','parcial')
--                AND COALESCE(ct.estado,'activo') = 'activo')
--   ) t
-- )
--
-- ... y en el SELECT final:
--   UNION ALL SELECT * FROM inv19
--   UNION ALL SELECT * FROM inv20
-- ===========================================================================


-- >>> Migration: 0221_reparacion_datos.sql <<<
-- ============================================================================
-- 0221: REPARACIÓN DE DATOS (producción, vxxzesbmilfolwjhfxgr)
-- ============================================================================
--
-- Cuatro reparaciones que salen de la regla de negocio que fijó el dueño:
--
--   (a) "Desactivar un cliente = ya no tiene servicio Y está saldado."
--       → un cliente CON deuda NO puede estar desactivado. Se reactiva.
--   (b) El estado de contrato 'completado' SE ELIMINA: era un alias de
--       'cancelado'. Si un contrato cancelado quedó saldado o no es un dato
--       DERIVADO (se calcula de las cuotas), no un estado guardado.
--   (c) `clientes.vencimiento_mas_viejo` (denormalización que pinta el color
--       del pin del mapa) quedó desincronizado en 9 clientes.
--   (d) Checklists de tickets guardados como STRING jsonb en vez de array
--       (doble-encoding de PowerSync). 0220 pone el trigger que arregla las
--       escrituras FUTURAS; las 4 filas ya podridas se normalizan acá.
--
-- NINGUNO de los cuatro toca plata: no se crean/anulan/modifican cuotas, pagos,
-- recibos ni cargos. Solo se cambian cuatro columnas de ETIQUETA/METADATO
-- (`clientes.activo`, `contratos.estado`, `clientes.vencimiento_mas_viejo`,
-- `tickets.checklist`). Para que eso sea verificable y no una promesa, la
-- migración toma un SNAPSHOT global de la deuda viva al abrir la transacción y
-- ASSERTEA al cerrar que quedó idéntica: si algún trigger movió un centavo, la
-- transacción entera se revierte (RAISE EXCEPTION → ROLLBACK).
--
-- ES RE-EJECUTABLE: los cuatro bloques están acotados por el predicado del daño
-- (no por listas de IDs hardcodeadas), así que una segunda corrida toca 0
-- filas. Las temp tables son ON COMMIT DROP.
--
-- ----------------------------------------------------------------------------
-- ORDEN DE DEPLOY — LEER ANTES DE CORRER EL BLOQUE (b2)
-- ----------------------------------------------------------------------------
-- El bloque (b2) endurece el CHECK de `contratos.estado` sacando 'completado'.
-- La app INSTALADA HOY (v0.31.23) TODAVÍA ESCRIBE ese valor: el menú de
-- `contrato_detail_header.dart` ofrece la opción "Completado" (verificado en
-- HEAD, no solo en el working tree). Si el CHECK se endurece ANTES de que los
-- dispositivos actualicen, el usuario con la app vieja que marque "Completado"
-- recibe un `check_violation` (SQLSTATE 23514) al subir.
--
-- QUÉ TAN GRAVE: NO traba la cola. `esCodigoNoRetryable` (`connector.dart`,
-- ya shippeado) clasifica toda la clase 23 como PERMANENTE → avisa al usuario
-- y DESCARTA la op para no bloquear el resto. O sea: no se pierden cobros ni
-- se traba el device. El daño se limita a que ese contrato queda mostrando
-- 'Completado' en LA PANTALLA de ese equipo hasta que PowerSync le vuelva a
-- bajar la fila del server (que sigue diciendo 'cancelado' — el valor bueno),
-- más un error feo en pantalla.
--
-- Molesto pero no crítico. Aun así conviene correr (b2) junto con (o después
-- de) el release que saca la opción del menú; (a), (b1) y (c) se pueden correr
-- cuando sea, no dependen de ninguna versión de la app.
--
-- CÓMO CORRER SIN (b2): comentar las 3 líneas del `ALTER TABLE` del bloque
-- (b2) (están marcadas) y correr el archivo igual. Todo lo demás es
-- independiente. Después, cuando salga el release, descomentarlas y volver a
-- correr el archivo entero: es re-ejecutable, los otros bloques tocan 0 filas.
-- ----------------------------------------------------------------------------
--
-- MEDICIONES REALES (SELECTs corridos contra vxxz el 2026-08-08, antes de
-- aplicar nada): están citadas bloque por bloque más abajo.
-- ============================================================================

-- Lección 0218 → 0219 (mismo cuidado que 0220): forzar el encoding de la
-- sesión y NO meter acentos ni flechas en literales SQL que se van a devolver
-- o guardar. Los acentos quedan SOLO en comentarios, que no viajan a ningún
-- lado.
SET client_encoding = 'UTF8';

BEGIN;

-- ── Snapshot global de la deuda viva (la red de seguridad de plata) ─────────
-- Fórmula canónica del saldo (AGENTS, invariante #10):
--   saldo = monto + COALESCE(cargos_neto,0) - monto_pagado
-- Medido antes de aplicar (2026-08-08): 28.374 cuotas vivas por
-- C$26.190.362,58 · 28.222 pagos no anulados por C$25.151.117,05.
-- (El número exacto no importa acá — lo que importa es que sea IDÉNTICO al
-- final. Por eso se compara contra sí mismo, no contra una constante.)
CREATE TEMP TABLE _0221_deuda_global ON COMMIT DROP AS
SELECT count(*)                                                            AS cuotas,
       COALESCE(sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado), 0) AS saldo,
       (SELECT count(*) FROM public.pagos WHERE anulado = false)           AS pagos_vivos,
       (SELECT COALESCE(sum(monto_cordobas),0) FROM public.pagos WHERE anulado = false) AS recaudado
  FROM public.cuotas cu
 WHERE cu.estado IN ('pendiente','parcial');


-- ============================================================================
-- (a) REACTIVAR CLIENTES DESACTIVADOS QUE TIENEN DEUDA
-- ============================================================================
-- POR QUÉ: la regla del dueño dice que desactivar = "sin servicio Y saldado".
-- Un cliente desactivado con deuda es una contradicción: su plata se sigue
-- cobrando pero queda escondido de las listas de la app (los filtros de UI
-- esconden a los inactivos), así que nadie va a cobrarle. 14 de estos 35
-- registraron un pago en los últimos 60 días → son clientes VIVOS mal
-- etiquetados, no bajas.
--
-- SELECT "antes" (corrido el 2026-08-08 → 35 clientes / 242 cuotas /
-- C$227.817,00 en deuda, TODOS del tenant Telecable Mairena):
--   SELECT count(DISTINCT c.id) AS clientes, count(*) AS cuotas,
--          sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) AS saldo
--     FROM clientes c
--     JOIN cuotas cu    ON cu.cliente_id = c.id
--     JOIN contratos ct ON ct.id = cu.contrato_id
--    WHERE c.activo = false
--      AND cu.estado IN ('pendiente','parcial')
--      AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0
--      AND ct.estado = 'activo';
--
-- ⚠️ ALCANCE ACOTADO A PROPÓSITO — Y NO COINCIDE CON EL GUARD DE 0220. LEER:
-- El predicado de acá exige `ct.estado = 'activo'`, que es el hallazgo medido
-- y aprobado (35 clientes). Si se afloja a "cualquier cuota viva con saldo,
-- sin mirar el estado del contrato", el universo sube a 75 clientes /
-- 378 cuotas / C$309.486,41 — 40 clientes más, casi todos con el contrato
-- suspendido o cancelado.
--
-- El guard nuevo de 0220 (`clientes_guard_desactivar_con_deuda_trg`) usa la
-- versión AMPLIA: no filtra por estado de contrato, "la deuda de un contrato
-- cancelado sigue siendo deuda". Con lo cual, corriendo 0220 + 0221 como están,
-- quedan 40 clientes en un estado que el guard ya no dejaría crear: inactivos
-- con deuda. No rompe nada (el guard solo mira la transición true→false, así
-- que esos 40 se siguen editando normal) pero es una inconsistencia declarada.
--
-- Se dejó acotado porque ampliarlo es una decisión de PRODUCTO que no estaba
-- aprobada — reactivar 40 clientes los devuelve a las listas y rutas de cobro.
-- Si el dueño la aprueba, alcanza con borrar la línea `AND ct.estado = 'activo'`
-- del EXISTS de abajo (y el JOIN a contratos queda de más).
--
-- NO se tocan contratos ni cuotas: solo el flag `activo`.
UPDATE public.clientes c
   SET activo = true
 WHERE c.activo = false
   AND EXISTS (
     SELECT 1
       FROM public.cuotas cu
       JOIN public.contratos ct ON ct.id = cu.contrato_id
      WHERE cu.cliente_id = c.id
        AND cu.estado IN ('pendiente','parcial')
        AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0
        AND ct.estado = 'activo'
   );


-- ============================================================================
-- (b1) MIGRAR contratos.estado 'completado' → 'cancelado'
-- ============================================================================
-- POR QUÉ: 'completado' y 'cancelado' significaban lo mismo (contrato
-- terminal, sin servicio). Peor: 31 de los 34 contratos marcados 'completado'
-- son INDEFINIDOS — un contrato sin duración no puede "completarse", así que
-- la etiqueta era directamente incorrecta.
--
-- ⚠️ ESTO ES UN CAMBIO DE ETIQUETA, NADA MÁS. No se ejecuta la lógica de
-- cancelación del contrato: NO se anulan cuotas, NO se toca fecha_fin, NO se
-- borra deuda. Esos 34 contratos arrastran 211 cuotas vivas por C$193.676,00
-- (84 de ellas ya vencidas, C$83.337,00) y esa plata es COBRABLE: tiene que
-- sobrevivir intacta. El assert del final lo verifica.
--
-- SELECT "antes" (corrido el 2026-08-08):
--   SELECT estado, count(*) FROM contratos GROUP BY estado;
--     activo 5478 · cancelado 59 · completado 34 · suspendido 55
--   (los 34 'completado' = 27 Telecable Mairena + 7 Telenet)
--
-- EFECTO COLATERAL ESPERADO (benigno): el trigger `contratos_vmv` dispara en
-- los 34 UPDATEs y recalcula `vencimiento_mas_viejo` del cliente. El valor NO
-- cambia, porque `recalc_vencimiento_mas_viejo` solo cuenta cuotas de
-- contratos con estado = 'activo' y tanto 'completado' como 'cancelado' quedan
-- fuera de ese filtro por igual. En el peor caso corrige un valor ya podrido,
-- que es justo lo que hace el bloque (c).
UPDATE public.contratos
   SET estado = 'cancelado'
 WHERE estado = 'completado';


-- ============================================================================
-- (b2) SACAR 'completado' DEL CHECK DE contratos.estado
-- ============================================================================
-- PREFERIBLEMENTE NO CORRER ESTE BLOQUE ANTES DEL RELEASE — ver la advertencia
-- de ORDEN DE DEPLOY en la cabecera (la app v0.31.23 todavía escribe
-- 'completado' → check_violation 23514 → op descartada + error en pantalla de
-- ESE equipo; la cola NO se traba, pero es una fricción evitable).
--
-- Constraint vigente medida en producción (2026-08-08):
--   contratos_estado_check
--     CHECK (estado = ANY (ARRAY['activo','suspendido','completado','cancelado']))
--
-- Se verificó además que 'completado' NO aparece en NINGÚN otro objeto del
-- server: 0 funciones (`SELECT proname FROM pg_proc WHERE prosrc ILIKE
-- '%completado%'` → vacío), 0 vistas, 0 policies RLS y 0 reglas de sync de
-- PowerSync. La única referencia server-side era esta CHECK.
--
-- Va DESPUÉS de (b1) a propósito: primero se normalizan las filas, después se
-- angosta el dominio. Al revés fallaría la validación de la constraint.
--
-- ↓↓↓ ESTAS 3 LÍNEAS SON LAS QUE SE COMENTAN SI EL RELEASE TODAVÍA NO SALIÓ ↓↓↓
ALTER TABLE public.contratos DROP CONSTRAINT IF EXISTS contratos_estado_check;
ALTER TABLE public.contratos
  ADD CONSTRAINT contratos_estado_check
  CHECK (estado = ANY (ARRAY['activo'::text, 'suspendido'::text, 'cancelado'::text]));
-- ↑↑↑ FIN DEL BLOQUE (b2) OPCIONAL ↑↑↑


-- ============================================================================
-- (c) RESINCRONIZAR clientes.vencimiento_mas_viejo
-- ============================================================================
-- QUÉ ES: denormalización que alimenta el color del pin en el mapa y el filtro
-- "solo cobrables" (`mapa_screen.dart`). NO es plata — ningún invariante de
-- `invariantes_dinero.sql` la usa (0 menciones en ese archivo).
--
-- SELECT "antes" (corrido el 2026-08-08 → 9 clientes divergentes, todos del
-- tenant Telenet, todos con `activo = true` y contratos activos):
--   WITH esperado AS (
--     SELECT c.id, c.vencimiento_mas_viejo AS guardado,
--            (SELECT MIN(cu.fecha_vencimiento) FROM cuotas cu
--               LEFT JOIN contratos ct ON ct.id = cu.contrato_id
--              WHERE cu.cliente_id = c.id
--                AND cu.estado IN ('pendiente','parcial')
--                AND COALESCE(ct.estado,'activo') = 'activo') AS real
--       FROM clientes c)
--   SELECT count(*) FROM esperado WHERE guardado IS DISTINCT FROM real;   -- 9
--
-- En los 9 el valor guardado está 29-31 días DESPUÉS del real (exactamente un
-- mes tarde): el pin del mapa los muestra menos vencidos de lo que están, o
-- sea que se caen del filtro de cobrables y el cobrador no los visita.
--
-- CAUSA PROBABLE (para el que venga después, NO se arregla acá): el cliente
-- Dart espeja esta columna offline con `recalcVmvDeContrato`
-- (`lib/data/utils/colchon_indefinido.dart`), que usa el MISMO predicado pero
-- contra la base LOCAL. Si el dispositivo no tenía sincronizada la cuota más
-- vieja, su MIN local da un mes más tarde y PowerSync lo sube pisando el valor
-- correcto del server — sin que cambie ninguna cuota, así que el trigger
-- `cuotas_vmv` nunca se entera. Esta migración limpia el daño acumulado; la
-- reincidencia hay que atacarla del lado del mirror, no acá.
--
-- CÓMO SE REPARA: NO se duplica la fórmula en el UPDATE. Se detectan los
-- divergentes y después se invoca la función viva del server,
-- `recalc_vencimiento_mas_viejo(uuid)` (definición de 0185, verificada en
-- producción), que ya trae su propia guarda anti-escritura-no-op: si el valor
-- coincide no escribe, así que no genera churn de PowerSync.
--
-- POR QUÉ NO UN BARRIDO DE TODOS LOS CLIENTES: son 6.096 clientes y `cuotas`
-- no tiene índice por `cliente_id` solo (el que hay es
-- `(tenant_id, cliente_id, estado)`), así que 6.096 llamadas sueltas a la
-- función escanean el índice entero cada vez (57.005 cuotas) y la migración
-- tardaría minutos. Detectando primero, el loop hace 9 llamadas.
--
-- Va ÚLTIMO para absorber cualquier recálculo que hayan disparado (a) y (b1).
CREATE TEMP TABLE _0221_vmv_divergentes ON COMMIT DROP AS
SELECT c.id
  FROM public.clientes c
 WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
         SELECT MIN(cu.fecha_vencimiento)
           FROM public.cuotas cu
           LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
          WHERE cu.cliente_id = c.id
            AND cu.estado IN ('pendiente','parcial')
            AND COALESCE(ct.estado,'activo') = 'activo'
       );

DO $$
DECLARE
  v_id      uuid;
  v_total   int := 0;
BEGIN
  FOR v_id IN SELECT id FROM _0221_vmv_divergentes LOOP
    PERFORM public.recalc_vencimiento_mas_viejo(v_id);
    v_total := v_total + 1;
  END LOOP;
  -- Mensajes de RAISE en ASCII puro a proposito: la salida de psql/CLI ya
  -- rompio acentos antes en este repo (ver 0219_fix_mojibake_*).
  RAISE NOTICE '0221 (c): recalculados % clientes (esperado 9 en la 1ra corrida, 0 despues)', v_total;
END;
$$;


-- ============================================================================
-- (d) NORMALIZAR LOS CHECKLISTS jsonb DOBLE-ENCODEADOS
-- ============================================================================
-- QUÉ PASÓ: PowerSync sube el valor de una columna jsonb como STRING JSON
-- literal, así que Postgres guarda el ESCALAR "[]" en vez del array []. Es el
-- mismo bug que 0194 arregló para `solicitudes_accion.datos`.
--
-- 0220 (b) instala los triggers de desempaquetado, pero un BEFORE trigger solo
-- toca lo que se ESCRIBE: las filas ya guardadas mal siguen mal hasta que
-- alguien las vuelva a escribir. La reparación del dato en reposo es acá — el
-- encabezado de 0220 la promete explícitamente ("las 3+1 filas ya corruptas las
-- normaliza 0221") y sin este bloque esa promesa quedaba sin cumplir.
--
-- SELECT "antes" (corrido el 2026-08-08): 3 de 6 `tickets` y 1 de 3
-- `ticket_tipos`, los 4 con el valor "[]" (o sea, checklist VACÍO). El daño de
-- HOY es cero; lo que se cierra es el bug LATENTE: si alguno se llenara con
-- ítems, todo `jsonb_array_elements` / `->>` sobre esa columna revienta o
-- devuelve nada.
--
-- ORDEN vs 0220: indistinto. Si 0220 ya corrió, sus triggers ven el valor ya
-- normalizado y no hacen nada (idempotente). Si todavía no corrió, este UPDATE
-- arregla igual — solo que sin el trigger la corrupción puede volver.
--
-- POR QUÉ ES SEGURO (los 6 triggers de `tickets` verificados uno por uno):
--   · trg_tickets_validar_transicion  — BEFORE UPDATE OF estado: no dispara.
--   · trg_tickets_marcar_verificacion — pide `NEW.estado='cerrado'` y que el
--     estado CAMBIE: no dispara (acá el estado no se toca).
--   · trg_tickets_eventos_auto        — solo inserta evento si cambió `estado`
--     o `asignado_a`: no dispara, no se inventa historial.
--   · trg_tickets_coordinador_solo_orden / trg_tickets_gestor_solo_verificacion
--     — hacen early-return si el rol no es coordinador/gestor. Verificado en
--     producción que con el rol que corre migraciones `is_coordinador()` e
--     `is_admin_usuarios()` devuelven false sin lanzar excepción.
--   · trg_tickets_correlativo         — BEFORE INSERT: no dispara.
UPDATE public.tickets
   SET checklist = (checklist #>> '{}')::jsonb
 WHERE jsonb_typeof(checklist) = 'string';

UPDATE public.ticket_tipos
   SET checklist_template = (checklist_template #>> '{}')::jsonb
 WHERE jsonb_typeof(checklist_template) = 'string';


-- ============================================================================
-- ASSERT DE PLATA — si algo movió un centavo, esto revierte TODO
-- ============================================================================
-- Ninguno de los tres bloques debería tocar cuotas ni pagos. Lo verificamos en
-- vez de asumirlo: la app tiene triggers que recalculan solos (cancelación de
-- contrato, limpieza de cuotas excedentes, mora) y un cambio de etiqueta mal
-- pensado podría despertarlos. Si el conteo o el saldo cambió, cortamos con
-- excepción y la transacción entera hace ROLLBACK.
DO $$
DECLARE
  a record;
  d record;
BEGIN
  SELECT * INTO a FROM _0221_deuda_global;

  SELECT count(*) AS cuotas,
         COALESCE(sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado), 0) AS saldo,
         (SELECT count(*) FROM public.pagos WHERE anulado = false) AS pagos_vivos,
         (SELECT COALESCE(sum(monto_cordobas),0) FROM public.pagos WHERE anulado = false) AS recaudado
    INTO d
    FROM public.cuotas cu
   WHERE cu.estado IN ('pendiente','parcial');

  IF d.cuotas <> a.cuotas OR ABS(d.saldo - a.saldo) > 0.01
     OR d.pagos_vivos <> a.pagos_vivos OR ABS(d.recaudado - a.recaudado) > 0.01 THEN
    RAISE EXCEPTION
      '0221 ABORTADA: la migracion movio plata. cuotas % -> %, saldo % -> %, pagos % -> %, recaudado % -> %',
      a.cuotas, d.cuotas, a.saldo, d.saldo, a.pagos_vivos, d.pagos_vivos, a.recaudado, d.recaudado;
  END IF;

  RAISE NOTICE '0221 assert OK: % cuotas vivas / saldo % / % pagos vivos / recaudado % - sin cambios',
    d.cuotas, d.saldo, d.pagos_vivos, d.recaudado;
END;
$$;

COMMIT;


-- ============================================================================
-- VERIFICACIÓN "DESPUÉS" — correr esto y leer la columna `resultado`
-- ============================================================================
-- Las filas cuyo `esperado` es 0 son ASERCIONES DURAS: si no dan 0, algo falló.
-- Las que citan totales son de REFERENCIA: los conteos medidos el 2026-08-08
-- se mueven solos con la operación normal (altas, cobros, generación mensual).
-- Lo que ahí importa es la MAGNITUD — que la deuda de los cancelados haya
-- SUBIDO ~211 cuotas / ~C$193.676, no que baje.
SELECT 'a) clientes inactivos con deuda (contrato activo)' AS chequeo,
       (SELECT count(DISTINCT c.id)
          FROM public.clientes c
          JOIN public.cuotas cu    ON cu.cliente_id = c.id
          JOIN public.contratos ct ON ct.id = cu.contrato_id
         WHERE c.activo = false
           AND cu.estado IN ('pendiente','parcial')
           AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0
           AND ct.estado = 'activo')::text AS resultado,
       '0' AS esperado

UNION ALL
SELECT 'b1) contratos con estado = completado',
       (SELECT count(*) FROM public.contratos WHERE estado = 'completado')::text,
       '0'

UNION ALL
SELECT 'b1) contratos por estado (activo/suspendido/cancelado)',
       (SELECT string_agg(estado || '=' || n::text, ' | ' ORDER BY estado)
          FROM (SELECT estado, count(*) AS n FROM public.contratos GROUP BY estado) t),
       'sin completado (ref. 2026-08-08: activo=5478 | cancelado=93 | suspendido=55)'

UNION ALL
SELECT 'b2) el CHECK ya no admite completado',
       (SELECT pg_get_constraintdef(oid) ILIKE '%completado%'
          FROM pg_constraint
         WHERE conrelid = 'public.contratos'::regclass
           AND conname = 'contratos_estado_check')::text,
       'false (si da true es que comentaste el bloque b2 a proposito)'

UNION ALL
-- La deuda de los ex-'completado' tiene que seguir viva. Se cuenta sobre TODOS
-- los cancelados porque después del UPDATE ya no hay forma de distinguirlos.
-- Aritmética verificada el 2026-08-08 (esto es la prueba de que no se borró
-- deuda, es el chequeo más importante del archivo):
--   59 contratos cancelados de antes -> 137 cuotas vivas / C$93.668,46
--   34 contratos ex-'completado'     -> 211 cuotas vivas / C$193.676,00
--   ----------------------------------------------------------------
--   93 cancelados despues            -> 348 cuotas vivas / C$287.344,46
SELECT 'b) deuda viva de contratos cancelados (incluye la de los 34 ex-completado)',
       (SELECT count(*)::text || ' cuotas / C$' ||
               to_char(COALESCE(sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado),0),
                       'FM999999999.00')
          FROM public.cuotas cu
          JOIN public.contratos ct ON ct.id = cu.contrato_id
         WHERE ct.estado = 'cancelado'
           AND cu.estado IN ('pendiente','parcial')
           AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0),
       '~348 cuotas / ~C$287344.46 (antes eran 137 / C$93668.46: tiene que SUBIR)'

UNION ALL
SELECT 'c) clientes con vencimiento_mas_viejo divergente',
       (SELECT count(*)
          FROM public.clientes c
         WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
                 SELECT MIN(cu.fecha_vencimiento)
                   FROM public.cuotas cu
                   LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
                  WHERE cu.cliente_id = c.id
                    AND cu.estado IN ('pendiente','parcial')
                    AND COALESCE(ct.estado,'activo') = 'activo'))::text,
       '0'

UNION ALL
-- Los 4 checklists tienen que haber quedado como ARRAY. Si sigue habiendo
-- 'string', el `#>> '{}'` no desempaquetó (valor no parseable como jsonb).
SELECT 'd) checklists jsonb todavia guardados como string',
       ((SELECT count(*) FROM public.tickets      WHERE jsonb_typeof(checklist) = 'string')
      + (SELECT count(*) FROM public.ticket_tipos WHERE jsonb_typeof(checklist_template) = 'string'))::text,
       '0 (antes 2026-08-08: 3 tickets + 1 ticket_tipo)';


-- >>> Migration: 0222_solicitudes_motivo_columnas.sql <<<
-- 0222 — motivo/notas de la solicitud: de `datos` (jsonb) a COLUMNAS.
--
-- POR QUÉ: el motivo y las notas son datos OPERATIVOS de la solicitud (se leen
-- en la tarjeta de la cola, se copian al evento del contrato al aprobar y se
-- reportan). Vivían dentro del jsonb `datos`, que es un cajón de sastre: ahí
-- también va el BORRADOR del contrato a crear. Eso ya produjo un bug real —
-- en v0.31.20 las claves eran `motivo`/`notas` sueltas y las `notas` de la
-- solicitud PISABAN las notas del CONTRATO al aprobar `crear_contrato`
-- (se parchó en v0.31.23 renombrándolas a `solicitud_motivo`/`solicitud_notas`,
-- que es un parche, no una solución). Con columnas propias el choque de
-- namespace desaparece y el dato queda consultable por SQL.
--
-- `datos` NO se migra ni se limpia: sigue siendo el borrador de contrato
-- (cliente_id, plan_id, fecha_inicio, dia_pago, notas DEL CONTRATO, …). Las
-- claves `solicitud_*` que ya estén guardadas se dejan como están a propósito:
-- los dispositivos que todavía no actualizaron siguen escribiendo ahí, y el
-- cliente lee la COLUMNA primero y cae al JSON solo si está vacía.
--
-- Receta R4 (columna nueva). Aditivo → NO se bumpea `_dbWipeVersion`.
-- Sync rules: el bucket de `solicitudes_accion` usa `SELECT *` en las 5 vistas
-- (admin, lectura, admin_cobranza, admin_usuarios, impersonated_tenant) → no
-- hay YAML que editar; alcanza con reiniciar PowerSync para que las emita.

-- =========================================================================
-- 1. Columnas
-- =========================================================================
ALTER TABLE public.solicitudes_accion
  ADD COLUMN IF NOT EXISTS motivo text,
  ADD COLUMN IF NOT EXISTS notas  text;

COMMENT ON COLUMN public.solicitudes_accion.motivo IS
  'Motivo de la solicitud (opción del dropdown). Antes vivía en datos->>solicitud_motivo.';
COMMENT ON COLUMN public.solicitudes_accion.notas IS
  'Detalle escrito por el solicitante. Antes vivía en datos->>solicitud_notas. '
  'NO confundir con datos->>notas, que son las notas del CONTRATO a crear.';

-- =========================================================================
-- 2. Backfill desde `datos` — contempla los DOS formatos históricos
-- =========================================================================
--   · v0.31.23 → `solicitud_motivo` / `solicitud_notas` (claves propias).
--   · v0.31.20 → `motivo` / `notas` sueltas. OJO: `notas` solo se toma como
--     nota de la SOLICITUD si la fila trae también el `motivo` legacy que la
--     acompaña; sin ese marcador, `notas` son las del CONTRATO y copiarlas
--     sería repetir el bug que este cambio viene a cerrar.
--
-- El CASE de `obj` desempaqueta el doble-encoding de PowerSync (jsonb "string"
-- en vez de "object"): lo corrige el trigger de 0194 en cada escritura, pero
-- una fila anterior a esa migración puede seguir guardada así en reposo.
--
-- El filtro por `motivo IS NULL AND notas IS NULL` hace el UPDATE idempotente:
-- re-correr la migración no pisa lo que ya escribió la app.
WITH d AS (
  SELECT id,
         CASE WHEN jsonb_typeof(datos) = 'string'
              THEN (datos #>> '{}')::jsonb
              ELSE datos
         END AS obj
    FROM public.solicitudes_accion
)
UPDATE public.solicitudes_accion s
   SET motivo = NULLIF(btrim(COALESCE(d.obj ->> 'solicitud_motivo',
                                      d.obj ->> 'motivo',
                                      '')), ''),
       notas  = NULLIF(btrim(COALESCE(d.obj ->> 'solicitud_notas',
                                      CASE WHEN d.obj ->> 'motivo' IS NOT NULL
                                           THEN d.obj ->> 'notas' END,
                                      '')), '')
  FROM d
 WHERE d.id = s.id
   AND jsonb_typeof(d.obj) = 'object'
   AND s.motivo IS NULL
   AND s.notas IS NULL;

-- =========================================================================
-- 3. Verificación (correr a mano después de aplicar)
-- =========================================================================
-- SELECT column_name, data_type
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'solicitudes_accion'
--    AND column_name IN ('motivo','notas');
--
-- -- Cuántas solicitudes tenían motivo en el JSON y cuántas quedaron con
-- -- columna cargada (los dos números deben coincidir):
-- SELECT count(*) FILTER (
--          WHERE COALESCE(datos ->> 'solicitud_motivo', datos ->> 'motivo') IS NOT NULL
--        ) AS con_motivo_en_json,
--        count(*) FILTER (WHERE motivo IS NOT NULL) AS con_motivo_en_columna
--   FROM public.solicitudes_accion;


-- >>> Migration: 0223_normalizar_cedulas.sql <<<
-- ============================================================================
-- 0223: NORMALIZAR LAS CEDULAS COMODIN A NULL (producción, vxxzesbmilfolwjhfxgr)
-- ============================================================================
--
-- QUÉ PASÓ: `clientes.cedula` es opcional, pero cuando el cliente no traía
-- documento la oficina igual escribía ALGO en el campo — casi siempre un '0'.
-- Quedaron 864 clientes con un comodín guardado como si fuera un documento
-- real. Eso ensucia todo lo que cuelga de la columna:
--
--   · EL RECIBO lo imprime: "Cédula: 0" en la cara del cliente.
--   · LA BÚSQUEDA por cédula: tipear "0" traía media cartera (el `LIKE %0%` de
--     `busquedaClienteSql` matchea a los 861).
--   · EL AVISO de "esta cédula ya está en uso" (feature nueva de esta tanda):
--     sin esto, cada alta con cédula vacía daría 861 falsos positivos.
--
-- Guardar NULL es la forma honesta de decir "no tenemos la cédula".
--
-- ----------------------------------------------------------------------------
-- CONSECUENCIA VISIBLE EN EL RECIBO (verificada en el código, no supuesta)
-- ----------------------------------------------------------------------------
-- Hoy el recibo imprime la línea "Cédula: 0" para 787 clientes que YA tienen
-- recibos emitidos (803 de los afectados tienen contrato). Al pasar a NULL esa
-- línea simplemente NO SE IMPRIME: los tres renderers omiten el campo cuando
-- viene null, cada uno con su propio guard —
--
--   · lib/features/recibo/recibo_ticket.dart:286        (ticket en pantalla)
--   · lib/features/recibo/recibo_texto_escpos.dart:622  (ESC/POS, recibo simple)
--   · lib/features/recibo/recibo_texto_escpos.dart:758  (ESC/POS, recibo multi)
--   · lib/features/recibo/recibo_pdf.dart:241 y :501    (PDF simple y multi)
--
-- los cinco con la forma `r['cliente_cedula'] != null ? _fila(...) : null`, y el
-- `_emitirCampos*` descarta las entradas null. El dato lo trae
-- `recibo_screen.dart:90` como `c.cedula AS cliente_cedula`, sin coalesce.
--
-- ⚠️ POR ESO SE ESCRIBE NULL Y **NO** CADENA VACÍA: el guard es `!= null`, así
-- que un '' pasaría el filtro e imprimiría "Cédula:" con el valor en blanco —
-- peor que hoy. NULL es el único valor que hace desaparecer la línea.
-- (El resto del layout no se toca: la línea sigue gobernada por el setting
-- `recibo.mostrar_cedula` / `cliente.cedula`, ver settings_repo.dart:487.)
--
-- ----------------------------------------------------------------------------
-- LO QUE ESTA MIGRACIÓN **NO** HACE — Y POR QUÉ
-- ----------------------------------------------------------------------------
-- NO agrega un UNIQUE ni un CHECK sobre `cedula`. Decisión del dueño: la cédula
-- se AVISA, no se bloquea. Medido en producción: de los grupos de clientes que
-- comparten cédula, 49 son PERSONAS DISTINTAS registradas con el documento de
-- un familiar — práctica normal en Nicaragua. Un UNIQUE rompería 49 altas
-- legítimas. (El aviso informativo lo hace la app, en el form del cliente.)
--
-- Tampoco endurece nada con un CHECK "prohibido guardar '0'": la app INSTALADA
-- hoy todavía puede escribirlo, y un `check_violation` (23514) le tira un error
-- feo en pantalla al usuario con la versión vieja. Misma lección que 0221 (b2).
-- El bloqueo de entrada va del lado del cliente (`_cedulaNormalizada` en
-- `cliente_form_screen.dart`), que ya manda estos valores a null al guardar.
--
-- NO toca las 3 cédulas MAL CARGADAS que hay en producción (un nombre o una
-- dirección tipeados en el campo cédula):
--     [Frente al centro de Salud] · [Juan Ramon Aguilar Gunera] ·
--     [Leonsa del Socorro Salinas Quintero]
-- No son comodines: son datos reales puestos en la columna equivocada, y
-- decidir qué hacer con ellos (mover a `direccion`, corregir a mano, borrar) es
-- una decisión de la oficina, no de una migración. Se dejan a propósito.
--
-- NO escribe `op_log`: `op_log` es el log de intención del CLIENTE (lo escribe
-- Dart dentro de su writeTransaction). Una reparación server-side no genera
-- historial visible en la ficha — igual que 0221. Esta migración es el rastro.
--
-- NO toca plata: no hay una sola cuota, pago, recibo ni cargo en el archivo.
-- Solo se pisa `clientes.cedula`. El assert de más abajo lo demuestra en vez de
-- prometerlo (huella md5 de las otras columnas antes/después).
--
-- ----------------------------------------------------------------------------
-- PREDICADO: ESPEJA A `_cedulaNormalizada()` DEL FORM
-- ----------------------------------------------------------------------------
-- El bloque (a) usa EXACTAMENTE la misma definición de "comodín" que
-- `cliente_form_screen.dart` (`_cedulaNormalizada`, que se apoya en
-- `_cedulaComparable`), para que server y cliente coincidan: lo que la app deja
-- de guardar de ahora en más es lo mismo que acá se limpia del pasado.
--
--   Dart:  foldBusqueda(s).replaceAll(RegExp(r'[\s./\-_]'), '')
--          → null si: queda vacío  |  ^0+$  |  está en {na, nd, sn, sincedula,
--                                                       sinced, ninguna, ninguno}
--   SQL:   regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g')
--
-- (Acá alcanza con `lower()` a secas: `lower()` de POSTGRES sí es unicode —
-- la trampa de la regla #1d es el `lower()` de SQLITE, que es ASCII-only. Y
-- ninguno de los comodines de la lista lleva ñ ni acentos.)
--
-- ----------------------------------------------------------------------------
-- MEDICIONES REALES (SELECTs corridos contra vxxz el 2026-08-08, ANTES de
-- aplicar nada). Cada bloque cita las suyas.
-- ----------------------------------------------------------------------------
--   SELECT '[' || cedula || ']', count(*) FROM clientes
--    WHERE cedula IS NOT NULL
--      AND regexp_replace(lower(btrim(cedula)),'[[:space:]./_-]','','g')
--          IN ('','na','nd','sn','sincedula','sinced','ninguna','ninguno','notiene')
--       OR regexp_replace(lower(btrim(cedula)),'[[:space:]./_-]','','g') ~ '^0+$'
--    GROUP BY 1;
--
--     [0]         861      -> bloque (a), 'todos ceros'
--     [00]          1      -> bloque (a), 'todos ceros'
--     [No Tiene]    1      -> bloque (b), EXTRA (ver la advertencia del bloque)
--     [NO TIENE]    1      -> bloque (b), EXTRA
--     ------------------
--     TOTAL       864
--
--   Ningún otro comodín de la lista existe en la base: '000', 'N/A', 'NA', '-',
--   '' (cadena vacía), 'S/N', 'X', 'NINGUNA'... todos dan 0 filas. No se listan
--   en el predicado por adivinanza: el predicado los cubre igual si aparecen
--   mañana, pero lo que HOY se toca son esas 864 filas y nada más.
--
--   Universo y reparto:
--     clientes en la base ................ 6096
--     afectados .......................... 864   (862 Telecable Mairena + 2 Telenet)
--     de ellos, con contrato ............. 803
--     de ellos, con recibo emitido ....... 787   <- los que hoy ven "Cédula: 0"
--     ya tenían cedula NULL ................. 3
--     cédulas con al menos un dígito ..... 6088  -> quedan 5226 (bajan los 862
--                                                  comodines numéricos, ni una más)
--     -> después de correr esto: 867 clientes con cedula NULL (14,2% de 6096)
--
-- ----------------------------------------------------------------------------
-- ES RE-EJECUTABLE: los UPDATE están acotados por el predicado del daño (no por
-- listas de IDs), así que una segunda corrida toca 0 filas. Las temp tables son
-- ON COMMIT DROP.
--
-- EFECTO EN POWERSYNC (esperado, benigno): son 864 UPDATEs, o sea 864 filas de
-- `clientes` que se replican de nuevo a todos los dispositivos del tenant. Es
-- una corrida única y `clientes` es una tabla angosta — pero conviene correrlo
-- en horario de baja actividad y no repetirlo por gusto (el self-host de
-- Hetzner paga el ancho de banda del re-sync).
--
-- TRIGGERS DE `clientes` (los 2 vivos, verificados en producción — ninguno
-- dispara con este UPDATE):
--   · trg_clientes_codigo_inmutable      BEFORE UPDATE, pero solo lanza si
--     `NEW.codigo IS DISTINCT FROM OLD.codigo`. Acá `codigo` no se toca.
--   · trg_propagate_cobrador_id_clientes AFTER UPDATE **OF cobrador_id**. Acá
--     `cobrador_id` no se toca -> no se ejecuta.
-- Y `cedula` no aparece en ningún índice ni en ninguna CHECK constraint de la
-- tabla (verificado con pg_indexes y pg_constraint: 0 filas en ambos).
-- ============================================================================

-- Lección 0218 -> 0219 (y 0221): forzar el encoding de la sesión y NO meter
-- acentos ni flechas en literales SQL que se devuelven o se guardan. Los
-- acentos quedan SOLO en comentarios, que no viajan a ningún lado.
SET client_encoding = 'UTF8';

BEGIN;

-- ── Snapshot: la red de seguridad ───────────────────────────────────────────
-- `huella` es un md5 de TODAS las columnas de `clientes` que NO son la cédula.
-- Si al cerrar la transacción la huella cambió, es que se tocó algo que no se
-- debía y el assert revierte todo. Es la prueba de que la migración solo pisa
-- una columna.
CREATE TEMP TABLE _0223_snapshot ON COMMIT DROP AS
SELECT count(*)                                              AS clientes,
       count(*) FILTER (WHERE c.cedula IS NULL)              AS cedula_null,
       md5(string_agg(
             c.id::text                         || '|' ||
             coalesce(c.nombre, '')             || '|' ||
             coalesce(c.codigo, '')             || '|' ||
             coalesce(c.telefono, '')           || '|' ||
             coalesce(c.direccion, '')          || '|' ||
             coalesce(c.email, '')              || '|' ||
             coalesce(c.cobrador_id::text, '')  || '|' ||
             coalesce(c.tenant_id::text, '')    || '|' ||
             coalesce(c.activo::text, '')       || '|' ||
             coalesce(c.vencimiento_mas_viejo::text, ''),
             E'\n' ORDER BY c.id))                           AS huella,
       (SELECT count(*) FROM public.pagos WHERE anulado = false) AS pagos_vivos
  FROM public.clientes c;


-- ============================================================================
-- (a) COMODINES: ceros, vacíos y placeholders de texto  ->  NULL
-- ============================================================================
-- Medido el 2026-08-08: 862 filas (861 con '0' + 1 con '00'). Los demás valores
-- de la lista no existen hoy en la base; van igual porque el predicado tiene que
-- describir la REGLA (la misma que aplica la app al guardar), no la foto de hoy.
--
-- Cubre, sobre la forma comparable (minúsculas, sin espacios ni . / _ -):
--   · cadena que queda vacía  ->  '', '   ', '-', '- -', '...'
--   · solo ceros              ->  '0', '00', '000', '0-0'
--   · placeholders de texto   ->  'na', 'n/a', 'N.A.', 'nd', 'sn', 's/n',
--                                 'sin cedula', 'sinced', 'ninguna', 'ninguno'
UPDATE public.clientes
   SET cedula = NULL
 WHERE cedula IS NOT NULL
   AND (
     regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = ''
     OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') ~ '^0+$'
     OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g')
        IN ('na', 'nd', 'sn', 'sincedula', 'sinced', 'ninguna', 'ninguno')
   );


-- ============================================================================
-- (b) EXTRA: "No Tiene" / "NO TIENE"  ->  NULL     [2 filas, se puede comentar]
-- ============================================================================
-- ⚠️ ESTE BLOQUE VA MÁS ALLÁ DE LA LISTA APROBADA — leer antes de correr.
--
-- Al medir la base aparecieron 2 clientes con la cédula literal "No Tiene" /
-- "NO TIENE". Es el mismo comodín de siempre escrito con palabras, y hoy se
-- imprime en el recibo como "Cédula: No Tiene", que es exactamente el problema
-- que esta migración viene a resolver. Por eso se limpia.
--
-- PERO ES UNA DIVERGENCIA DECLARADA CON EL CLIENTE: `_cedulaNormalizada` del
-- form compacta "No Tiene" a 'notiene', que NO está en su set de comodines, así
-- que la app de HOY dejaría volver a guardarlo. Son 2 filas y no se puede
-- reincidir en masa, pero para cerrarlo del todo hay que agregar 'notiene' al
-- `const comodines` de `cliente_form_screen.dart:249`.
--
-- SI NO SE QUIERE ESTA LIMPIEZA: comentar el UPDATE de abajo. El resto del
-- archivo es independiente y corre igual (la verificación final lo reporta por
-- separado, no lo assertea).
UPDATE public.clientes
   SET cedula = NULL
 WHERE cedula IS NOT NULL
   AND regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = 'notiene';


-- ============================================================================
-- ASSERT — si se tocó cualquier cosa que no sea `cedula`, esto revierte TODO
-- ============================================================================
-- No debería poder pasar (ningún trigger de `clientes` dispara con este UPDATE,
-- ver la cabecera), pero lo verificamos en vez de asumirlo: la app tiene
-- triggers que recalculan solos y un UPDATE mal escrito podría despertarlos.
DO $$
DECLARE
  a record;
  d record;
BEGIN
  SELECT * INTO a FROM _0223_snapshot;

  SELECT count(*)                                              AS clientes,
         count(*) FILTER (WHERE c.cedula IS NULL)              AS cedula_null,
         md5(string_agg(
               c.id::text                         || '|' ||
               coalesce(c.nombre, '')             || '|' ||
               coalesce(c.codigo, '')             || '|' ||
               coalesce(c.telefono, '')           || '|' ||
               coalesce(c.direccion, '')          || '|' ||
               coalesce(c.email, '')              || '|' ||
               coalesce(c.cobrador_id::text, '')  || '|' ||
               coalesce(c.tenant_id::text, '')    || '|' ||
               coalesce(c.activo::text, '')       || '|' ||
               coalesce(c.vencimiento_mas_viejo::text, ''),
               E'\n' ORDER BY c.id))                           AS huella,
         (SELECT count(*) FROM public.pagos WHERE anulado = false) AS pagos_vivos
    INTO d
    FROM public.clientes c;

  -- Mensajes de RAISE en ASCII puro a proposito: la salida de psql/CLI ya
  -- rompio acentos antes en este repo (ver 0219_fix_mojibake_*).
  IF d.clientes <> a.clientes THEN
    RAISE EXCEPTION
      '0223 ABORTADA: cambio la cantidad de clientes (% -> %). Un UPDATE no borra filas: revisar.',
      a.clientes, d.clientes;
  END IF;

  IF d.huella <> a.huella THEN
    RAISE EXCEPTION
      '0223 ABORTADA: cambio alguna columna de clientes que NO es cedula (huella md5 distinta).';
  END IF;

  IF d.pagos_vivos <> a.pagos_vivos THEN
    RAISE EXCEPTION
      '0223 ABORTADA: cambio la cantidad de pagos vivos (% -> %). Esta migracion no toca plata.',
      a.pagos_vivos, d.pagos_vivos;
  END IF;

  RAISE NOTICE '0223 OK: % cedulas comodin pasadas a NULL (cedula_null % -> %). Resto de clientes intacto (huella md5 igual), % pagos vivos sin tocar.',
    d.cedula_null - a.cedula_null, a.cedula_null, d.cedula_null, d.pagos_vivos;
END;
$$;

COMMIT;


-- ============================================================================
-- VERIFICACIÓN "DESPUÉS" — correr esto y leer la columna `resultado`
-- ============================================================================
-- Las filas cuyo `esperado` es 0 son ASERCIONES DURAS: si no dan 0, algo falló.
-- Las demás son de REFERENCIA (los totales se mueven solos con las altas
-- normales de clientes).
SELECT 'a) cedulas comodin que quedan (ceros/vacios/placeholders)' AS chequeo,
       (SELECT count(*) FROM public.clientes
         WHERE cedula IS NOT NULL
           AND (regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = ''
             OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') ~ '^0+$'
             OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g')
                IN ('na','nd','sn','sincedula','sinced','ninguna','ninguno')))::text AS resultado,
       '0 (antes 2026-08-08: 862 = 861 con [0] + 1 con [00])' AS esperado

UNION ALL
SELECT 'b) cedulas literales "no tiene" que quedan',
       (SELECT count(*) FROM public.clientes
         WHERE cedula IS NOT NULL
           AND regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = 'notiene')::text,
       '0 si corriste el bloque (b) / 2 si lo comentaste a proposito'

UNION ALL
SELECT 'total de clientes con cedula NULL',
       (SELECT count(*) FROM public.clientes WHERE cedula IS NULL)::text,
       '867 (antes eran 3: tiene que SUBIR en 864)'

UNION ALL
SELECT 'total de clientes (no se borro ninguno)',
       (SELECT count(*) FROM public.clientes)::text,
       '6096 (ref. 2026-08-08; sube solo con altas nuevas)'

UNION ALL
-- Prueba de que NO se convirtio nada en cadena vacia: un '' pasaria el guard
-- `!= null` de los renderers e imprimiria "Cedula:" en blanco en el recibo.
SELECT 'cedulas guardadas como cadena vacia o solo espacios',
       (SELECT count(*) FROM public.clientes WHERE cedula IS NOT NULL AND btrim(cedula) = '')::text,
       '0'

UNION ALL
-- Control de que la limpieza no se llevo puesta ninguna cedula real. Los unicos
-- comodines CON digitos son los 862 del bloque (a) ([0] y [00]), asi que la
-- cuenta tiene que bajar EXACTAMENTE en 862: 6088 medidos antes - 862 = 5226.
-- Si baja mas, el predicado se comio documentos validos.
SELECT 'clientes con cedula real (con al menos un digito)',
       (SELECT count(*) FROM public.clientes WHERE cedula ~ '[0-9]')::text,
       '5226 (antes 2026-08-08: 6088; tiene que bajar exactamente 862)'

UNION ALL
-- Las 3 mal cargadas (nombre/direccion en el campo cedula) NO se tocan: quedan
-- para que la oficina las corrija a mano. Antes de correr esto daban 5, porque
-- los 2 "No Tiene" tampoco tienen digitos; el bloque (b) los saca.
SELECT 'cedulas mal cargadas sin ningun digito (se dejan a proposito)',
       (SELECT count(*) FROM public.clientes
         WHERE cedula IS NOT NULL AND cedula !~ '[0-9]')::text,
       '3 con el bloque (b) / 5 si lo comentaste. Antes: 5. Los 3 que quedan son '
       || 'Frente al centro de Salud, Juan Ramon Aguilar Gunera, Leonsa del Socorro Salinas Quintero';


-- >>> Migration: 0224_recalcular_cuota_al_salir_de_revision.sql <<<
-- 0224 — el recálculo de la cuota también dispara al salir de CUARENTENA.
--
-- BUG (audit 2026-08-08). `trg_pagos_update_recalcular` escuchaba
--   AFTER UPDATE OF monto_cordobas, cuota_id, anulado
-- pero NO `en_revision`. Y `recalcular_cuota_desde_pagos()` suma
--   WHERE anulado = false AND en_revision = false
-- o sea que `en_revision` SÍ cambia el resultado del recálculo, pero no lo
-- disparaba. La combinación es venenosa por el ORDEN en que resuelve la app:
--
--   `pagos_repo.elegirCobroVerdadero()` (pagos_repo.dart:834)
--     1. anula los OTROS pagos vivos de la cuota  → dispara el trigger, y como
--        el pago ELEGIDO todavía tiene en_revision = true, no lo suma:
--        la cuota queda en monto_pagado = 0, estado 'pendiente'.
--     2. recién entonces hace UPDATE pagos SET en_revision = 0 sobre el elegido
--        → ESTE update no dispara nada.
--
-- Resultado: cuota PENDIENTE con la plata ya cobrada. Traba oldest-first en ese
-- contrato, infla la mora del cliente, impide desactivarlo (guard 0220) y
-- empuja al cobrador a cobrarle en la calle un mes ya pagado.
--
-- El comentario de pagos_repo.dart:828 ("El server recalcula monto_pagado/estado
-- (triggers 0083/0216)") era FALSO para este camino; se corrige aparte.
--
-- ESTADO AL APLICAR: 0 cuotas dañadas en producción (nadie resolvió todavía una
-- cuarentena eligiendo el pago retenido). Es prevención, no reparación — por eso
-- la migración no repara nada: no hay nada que reparar.
--
-- Nota: `cuotas_forzar_derivados_trg` (0216, BEFORE UPDATE en cuotas) ya reparaba
-- el caso de rebote — cualquier escritura posterior sobre esa fila de cuotas
-- recalcula desde `pagos`. Por eso el daño no era permanente, pero sí quedaba
-- vivo hasta que algo volviera a tocar la cuota.

DROP TRIGGER IF EXISTS trg_pagos_update_recalcular ON public.pagos;

CREATE TRIGGER trg_pagos_update_recalcular
  AFTER UPDATE OF monto_cordobas, cuota_id, anulado, en_revision
  ON public.pagos
  FOR EACH ROW
  EXECUTE FUNCTION recalcular_cuota_desde_pagos();

COMMENT ON TRIGGER trg_pagos_update_recalcular ON public.pagos IS
  'Recalcula monto_pagado/estado de la cuota. Escucha en_revision desde 0224: '
  'sacar un pago de cuarentena CAMBIA el resultado de recalcular_cuota_desde_pagos '
  '(su WHERE filtra en_revision), asi que tiene que disparar. Si se agrega otra '
  'columna al predicado de pagos vivos, agregarla tambien a esta lista.';


-- >>> Migration: 0225_app_dispositivos.sql <<<
-- 0225 — saber QUÉ VERSIÓN de la app corre cada dispositivo.
--
-- POR QUÉ. Hasta ahora no había forma de saberlo: no existe ninguna columna de
-- versión en la base. Eso hizo que dos auditorías sacaran conclusiones falsas al
-- leer datos de producción como si los hubiera producido el código de `main`
-- (audit 2026-08-09: se dio por "agujero vivo" algo que ya estaba arreglado, y
-- se explicó por "versiones viejas" un campo que nunca existió). También es lo
-- que impide responder "¿el digitador ya tiene el guard?" sin preguntarle.
--
-- DISEÑO. Es TELEMETRÍA, no dato de negocio:
--   · NO entra al schema de PowerSync. La app la escribe DIRECTO por Supabase al
--     abrir sesión, best-effort — si falla, no pasa nada. Así no ocupa lugar en
--     la cola de sync ni compite con los writes que sí importan.
--   · Una fila por DISPOSITIVO (no por sesión): se upsertea. No crece sin techo.
--   · Sin FK a `cobradores`: si se borra el usuario, la telemetría no debe
--     bloquear el borrado ni desaparecer.
create table if not exists public.app_dispositivos (
  id           uuid primary key,          -- id estable del install (lo genera el device)
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  usuario_id   uuid not null,             -- auth.uid() — sin FK, ver arriba
  usuario_nombre text,                    -- desnormalizado: sobrevive al borrado
  rol          text,
  version      text not null,             -- "0.31.26+249"
  plataforma   text,                      -- windows | android | otro
  modelo       text,                      -- para correlacionar bugs de impresora
  primera_vez  timestamptz not null default now(),
  visto_en     timestamptz not null default now()
);

create index if not exists app_dispositivos_tenant_visto_idx
  on public.app_dispositivos (tenant_id, visto_en desc);
create index if not exists app_dispositivos_version_idx
  on public.app_dispositivos (version);

alter table public.app_dispositivos enable row level security;

-- El dispositivo se reporta a SÍ MISMO. No puede escribir la fila de otro.
drop policy if exists app_disp_self_insert on public.app_dispositivos;
create policy app_disp_self_insert on public.app_dispositivos
  for insert to authenticated
  with check (tenant_id = current_tenant_id() and usuario_id = auth.uid());

drop policy if exists app_disp_self_update on public.app_dispositivos;
create policy app_disp_self_update on public.app_dispositivos
  for update to authenticated
  using (tenant_id = current_tenant_id() and usuario_id = auth.uid())
  with check (tenant_id = current_tenant_id() and usuario_id = auth.uid());

-- Leer: el admin del tenant (para saber a quién le falta actualizar).
drop policy if exists app_disp_read on public.app_dispositivos;
create policy app_disp_read on public.app_dispositivos
  for select to authenticated
  using (tenant_id = current_tenant_id() and is_admin_or_cobranza());

-- Toda tabla tenant-scoped nace con esta policy A MANO (regla de AGENTS R10):
-- sin ella el super_admin impersonando no puede escribir, porque su
-- current_tenant_id() no matchea el tenant impersonado.
drop policy if exists super_admin_all on public.app_dispositivos;
create policy super_admin_all on public.app_dispositivos
  for all to authenticated
  using (is_super_admin()) with check (is_super_admin());

comment on table public.app_dispositivos is
  'Telemetria: que version de la app corre cada dispositivo. La escribe el propio '
  'device al abrir sesion, DIRECTO por Supabase (no por PowerSync). Una fila por '
  'install, se upsertea. Sirve para saber si un fix ya llego a la gente antes de '
  'sacar conclusiones sobre datos de produccion.';


-- >>> Migration: 0226_solicitud_cambiar_plan.sql <<<
-- 0226 — nuevo tipo de solicitud: `cambiar_plan`.
--
-- POR QUÉ. Ruben pidió que el admin_cobranza pueda PEDIR el cambio de plan con
-- aprobación del admin. Hoy ni siquiera lo ve (`puedeCambiarPlanProvider` exige
-- rol admin), y no existía el tipo de solicitud para pedirlo.
--
-- Y hay una razón más fuerte, medida: **3 de cada 4 "cancelaciones" de la base
-- son cambios de plan disfrazados**. De 61 contratos cancelados, 53 tienen otro
-- contrato del mismo cliente creado alrededor de la misma fecha, y 45 de esos
-- con plan DISTINTO (upgrades y downgrades reales: CATV→Internet 20MB,
-- Combo 40→Combo 20…). El contrato nuevo se crea ANTES de cancelar el viejo
-- (44 h antes en Mairena, 6 h en Telenet). Cada uno de esos casos pierde el
-- historial: contrato nuevo, cuotas nuevas, numeración nueva. Lo hacen así
-- porque la feature de cambio de plan está apagada y no tienen otra salida.
--
-- SIN RIESGO DE ROLLOUT. Una app VIEJA que reciba una solicitud de este tipo la
-- parsea con el fallback `_parseTipo` → la mostraría como "Crear contrato" y su
-- ejecutor intentaría un INSERT con datos que no le corresponden. Por eso el
-- botón para crear estas solicitudes queda detrás del setting
-- `cobranza.cambio_plan_habilitado`, que está en **false en los 4 tenants**: no
-- puede nacer una sola fila de este tipo hasta que se prenda a propósito, y para
-- entonces `app_dispositivos` (0225) permite verificar que todos actualizaron.
alter table public.solicitudes_accion
  drop constraint if exists solicitudes_accion_tipo_check;

alter table public.solicitudes_accion
  add constraint solicitudes_accion_tipo_check
  check (tipo = any (array[
    'crear_contrato',
    'cancelar_contrato',
    'suspender_contrato',
    'reactivar_contrato',
    'desactivar_cliente',
    'cambiar_plan'
  ]));

comment on constraint solicitudes_accion_tipo_check on public.solicitudes_accion is
  'Tipos de solicitud validos. Al agregar uno: (1) ampliar este CHECK, (2) el enum '
  'TipoSolicitud + tipoDb + _parseTipo + tipoLabel en solicitud_accion.dart, '
  '(3) el ejecutor en solicitudes_repo.ejecutarAccionAprobada, (4) la tarjeta en '
  'solicitudes_screen. OJO con el rollout: las apps viejas caen al fallback de '
  '_parseTipo y muestran el tipo desconocido como crear_contrato, asi que el tipo '
  'nuevo tiene que nacer detras de un gate apagado.';


-- >>> Migration: 0227_clientes_notas.sql <<<
-- 0227 — Nota interna del cliente
-- El CONTRATO ya tenía `notas` (contexto del servicio: "instalación con cable
-- extra"); el CLIENTE no tenía dónde anotar contexto de la PERSONA ("atiende la
-- hija después de las 3", "el perro está suelto"). Esa nota sobrevive a los
-- contratos del cliente, por eso va acá y no en `contratos`.
--
-- Interna: no sale en recibo, PDF ni export (decisión de Rubén 2026-08-09).
-- La ven y la editan TODOS los roles operativos — la escribe justamente quien
-- llega a la casa. `lectura` queda afuera por su guardia de solo-lectura, no
-- por una regla propia de esta columna.
--
-- Aditivo: las apps nuevas la esperan; las viejas la ignoran. Los 9 buckets de
-- `clientes` en sync-rules.yaml usan `SELECT *` → la columna se sincroniza sola
-- (no hay que editar el YAML, pero sí reiniciar el servicio en el VPS para que
-- re-lea el schema de la fuente). NO se bumpea `_dbWipeVersion` (columna
-- aditiva, PowerSync la aplica in-place — política R4).
--
-- Sin GRANT extra: los únicos GRANT/REVOKE por columna del repo (0199, 0201,
-- 0202) son sobre `cobradores`; `public.clientes` conserva el grant a nivel de
-- TABLA, así que la columna nueva nace legible y escribible.

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS notas text;

COMMENT ON COLUMN public.clientes.notas IS
  'Nota interna sobre el cliente (opcional). La ven y la editan todos los '
  'roles operativos. Nunca se imprime en recibo ni PDF.';


-- >>> Migration: 0228_oplog_contratos_notas.sql <<<
-- 0228 — `notas` del contrato al historial de cambios
--
-- `contratos.notas` existía desde siempre pero NUNCA estuvo en la allowlist del
-- change log: se escribía al crear el contrato y ningún cambio quedaba
-- registrado. Con 0227 la nota pasa a ser editable, así que tiene que auditarse
-- como cualquier otro campo del formulario.
--
-- El lado Dart ya se arregló (`kAuditCamposVisiblesDefault['contratos']` +
-- `kAuditCamposCatalogo['contratos']` en audit_changelog.dart). Pero eso NO
-- alcanza: `opLogCamposVisibles` le da prioridad al override persistido del
-- tenant sobre el default de Dart —
--     if (override == null) return default;
--     return [for (k in catalogo) if (override.contains(k)) k];
-- — así que un tenant con la fila `op_log.campos_visibles` guardada seguiría
-- filtrando 'notas' y el campo quedaría invisible en el historial. Parecería un
-- bug de código y no lo sería.
--
-- Estado verificado antes de escribir esto (2026-08-09, contra vxxz):
--   Telenet      → contratos: SIN 'notas' · clientes: CON 'notas'
--   Test Tenant  → contratos: SIN 'notas' · clientes: CON 'notas'
--   Telecable Mairena → sin fila (cae al default de Dart, ya corregido)
-- Por eso `clientes.notas` (0227) no necesita nada acá y `contratos.notas` sí.
--
-- Idempotente: el WHERE excluye las filas que ya lo tengan, así que re-correrla
-- no duplica la clave en el array.

UPDATE public.settings
   SET valor = jsonb_set(
         valor::jsonb,
         '{contratos}',
         (valor::jsonb -> 'contratos') || '["notas"]'::jsonb
       )::text,
       updated_at = now()
 WHERE clave = 'op_log.campos_visibles'
   AND valor::jsonb ? 'contratos'
   AND jsonb_typeof(valor::jsonb -> 'contratos') = 'array'
   AND NOT ((valor::jsonb -> 'contratos') ? 'notas');


-- >>> Migration: 0229_solicitudes_deuda_snapshot.sql <<<
-- 0229 — Foto de la deuda al PEDIR suspender/cancelar un contrato
--
-- Desde v0.31.28 todo rol que no sea admin tiene que SOLICITAR la suspensión o
-- la cancelación. Efecto colateral: el rol que antes lo ejecutaba directo veía
-- el bloque "Deuda a la fecha" (lo que queda cobrable después del corte) y al
-- pasar a pedir permiso dejó de verlo — y la solicitud que le llega al admin
-- tampoco lo llevaba. O sea: se pedía cortar el servicio a ciegas y se aprobaba
-- a ciegas.
--
-- Esta columna guarda el cálculo del MOMENTO DEL PEDIDO. La tarjeta de
-- aprobación NO lo muestra como el número bueno: recalcula en vivo (que es lo
-- que el sistema va a aplicar al aprobar) y usa el snapshot para explicar la
-- diferencia — si bajó, el cliente pagó; si subió, corrieron días de servicio
-- del ciclo en curso mientras la solicitud esperaba.
--
-- TEXT, no jsonb, a propósito. `contratos.cancelacion_deuda_snapshot` nació
-- jsonb en 0123 y hubo que migrarla a text en 0126: el cliente manda el JSON ya
-- serializado, entraba como string-escalar y volvía doble-codificado, reventando
-- con "type 'String' is not a subtype of type 'Map'". Con text el valor viaja
-- tal cual y se decodifica una sola vez, en Dart.
--
-- Aditiva y nullable: las solicitudes ya creadas quedan sin snapshot y la
-- tarjeta las muestra igual (solo sin la línea comparativa). Los buckets de
-- `solicitudes_accion` usan SELECT * → no hay que editar sync-rules.yaml. NO se
-- bumpea `_dbWipeVersion` (política R4).

ALTER TABLE public.solicitudes_accion
  ADD COLUMN IF NOT EXISTS deuda_snapshot text;

COMMENT ON COLUMN public.solicitudes_accion.deuda_snapshot IS
  'JSON (texto) con la deuda cobrable calculada al crear la solicitud: '
  '{total, cuotas[], dia_pago, precio_mensual, fecha}. Solo aplica a '
  'suspender/cancelar contrato. Es referencia histórica: el aprobador ve el '
  'recálculo en vivo, no este valor.';


-- >>> Migration: 0230_notas_editables_todos_los_roles.sql <<<
-- 0230 — La nota del cliente y la del contrato las edita CUALQUIER rol menos `lectura`
--
-- Decisión de Rubén (2026-08-10). La nota es contexto operativo — "atiende la
-- hija después de las 3", "el poste está del otro lado, 40 m de cable extra" —
-- y quien lo descubre es el que va a la casa, no la oficina. Si el que lo sabe
-- no la puede escribir, la nota se degrada.
--
-- ── EL PROBLEMA ─────────────────────────────────────────────────────────────
-- La RLS de este proyecto es ROW-level: una policy de UPDATE habilita la FILA
-- ENTERA, no una columna. Y un GRANT por columna no sirve para distinguir roles:
-- los roles de la app (`cobradores.rol`) son un DATO de tabla, no roles de
-- Postgres — TODOS los usuarios son el mismo grantee `authenticated`.
-- Dicho de otro modo: dejar que el cobrador escriba `notas` con una policy
-- suelta lo dejaría escribir `precio_mensual`, `plan_id` y `estado`.
--
-- ── LA SOLUCIÓN ─────────────────────────────────────────────────────────────
-- Policy permisiva + trigger BEFORE UPDATE que hace de barrera por columna.
-- El trigger NO enumera qué revertir: hace `new := old` (descarta TODO) y vuelve
-- a poner SOLO lo permitido. Así una columna que se agregue mañana nace
-- protegida, en vez de nacer con un agujero — que es exactamente cómo se
-- escapan estas cosas.
--
-- REVIERTE EN SILENCIO, NUNCA `raise exception`. Verificado en el connector
-- (`lib/powersync/connector.dart`): un P0001 marca la operación como no
-- retryable y DESCARTA EL CrudEntry COMPLETO. El form de clientes manda sus 16
-- columnas en una sola sentencia, así que abortarla por `notas` le haría perder
-- también el nombre, el teléfono y la dirección recién editados. Con la
-- reversión silenciosa el resto se persiste y el valor bueno vuelve por
-- checkpoint.
--
-- ── LOS TRES ESCAPES DEL TRIGGER (y por qué) ────────────────────────────────
-- 1. `auth.uid() is null` → pasa sin tocar nada. Son los crons y las Edge
--    Functions (service_role): sin esto el trigger revertiría la generación
--    mensual de cuotas, la suspensión automática y todo lo que corre del lado
--    del server. Es el escape más importante de los tres.
-- 2. Los roles que YA tenían escritura completa por sus policies pasan igual
--    (admin/admin_cobranza en las dos tablas; admin_usuarios además en
--    clientes; super_admin siempre). El trigger no les cambia nada.
-- 3. El cobrador conserva `dia_pago` y `fecha_fin` en contratos: es lo que ya le
--    permitía `contratos_cambiar_fecha`, y revertirlo rompería el cambio de
--    fecha de pago. `contratos_check_cobrador_update` (0016) sigue vigente y
--    corre DESPUÉS — los nombres de los triggers nuevos empiezan con `_a_` a
--    propósito, porque Postgres los dispara en orden alfabético y la barrera
--    tiene que reponer los valores viejos ANTES de que el otro se fije si algo
--    cambió (si no, el cobrador comería un "solo puede cambiar dia_pago").
--
-- `lectura` queda afuera por la policy, no por el trigger: no llega a escribir.

-- ── CLIENTES ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.clientes_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_updated  timestamptz := new.updated_at;
BEGIN
  -- Escape 1: server-side (crons, Edge Functions, service_role).
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 2: los que ya tenían escritura completa sobre `clientes`.
  IF public.is_super_admin()
     OR public.is_admin_or_cobranza()
     OR public.current_user_rol() = 'admin_usuarios' THEN
    RETURN new;
  END IF;
  -- El resto: SOLO la nota (más las marcas de tiempo, para que el cambio se
  -- propague y quede fechado).
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  new.updated_at  := v_updated;
  RETURN new;
END;
$function$;

COMMENT ON FUNCTION public.clientes_solo_notas_trg() IS
  'Barrera por columna: los roles sin escritura completa sobre clientes solo '
  'pueden mover `notas`. Revierte en silencio (nunca raise: un P0001 haría que '
  'el connector descarte el UPDATE entero y se pierdan los demás campos).';

DROP TRIGGER IF EXISTS trg_clientes_a_solo_notas ON public.clientes;
CREATE TRIGGER trg_clientes_a_solo_notas
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_solo_notas_trg();

DROP POLICY IF EXISTS clientes_write_notas ON public.clientes;
CREATE POLICY clientes_write_notas ON public.clientes
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura')
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura');

-- ── CONTRATOS ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.contratos_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_dia_pago integer     := new.dia_pago;
  v_fecha_fin date       := new.fecha_fin;
BEGIN
  -- Escape 1: server-side (crons de facturación, Edge Functions).
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 2: los que ya tenían escritura completa sobre `contratos`.
  IF public.is_super_admin() OR public.is_admin_or_cobranza() THEN
    RETURN new;
  END IF;
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  -- Escape 3: el cambio de fecha de pago del cobrador (policy
  -- `contratos_cambiar_fecha`, gated por el setting). Se repone tal cual; los
  -- límites de ESE camino los sigue aplicando `contratos_check_cobrador_update`,
  -- que corre después.
  IF public.current_user_rol() = 'cobrador'
     AND old.cobrador_id = auth.uid()
     AND public.puede_cambiar_fecha_pago() THEN
    new.dia_pago  := v_dia_pago;
    new.fecha_fin := v_fecha_fin;
  END IF;
  RETURN new;
END;
$function$;

COMMENT ON FUNCTION public.contratos_solo_notas_trg() IS
  'Barrera por columna: los roles sin escritura completa sobre contratos solo '
  'pueden mover `notas` (y el cobrador con permiso, dia_pago/fecha_fin del '
  'cambio de fecha). Revierte en silencio, nunca raise.';

DROP TRIGGER IF EXISTS trg_contratos_a_solo_notas ON public.contratos;
CREATE TRIGGER trg_contratos_a_solo_notas
  BEFORE UPDATE ON public.contratos
  FOR EACH ROW EXECUTE FUNCTION public.contratos_solo_notas_trg();

DROP POLICY IF EXISTS contratos_write_notas ON public.contratos;
CREATE POLICY contratos_write_notas ON public.contratos
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura')
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura');


-- >>> Migration: 0231_barrera_notas_no_pisa_al_server.sql <<<
-- 0231 — HOTFIX de 0230: la barrera de notas estaba revirtiendo al PROPIO SERVER
--
-- ── EL BUG ──────────────────────────────────────────────────────────────────
-- `SECURITY DEFINER` cambia el usuario de POSTGRES, no el JWT de la sesión.
-- `auth.uid()` lee `request.jwt.claims`, que es un GUC de SESIÓN: sigue siendo
-- el del usuario logueado aunque estemos adentro de una función del server.
--
-- Consecuencia: cuando un COBRADOR registra un pago, el trigger `cuotas_vmv`
-- dispara `recalc_vencimiento_mas_viejo()` (SECURITY DEFINER, owner postgres),
-- que hace `UPDATE clientes SET vencimiento_mas_viejo = ...`. Para la barrera de
-- 0230 ese UPDATE era indistinguible de uno del cobrador: `auth.uid()` no era
-- NULL y `current_user_rol()` decía 'cobrador' → no entraba por ningún escape →
-- `new := old` lo descartaba en silencio.
--
-- El cliente pagaba y quedaba marcado como vencido: pin rojo en el mapa (que
-- deriva el color de esa columna sin cruzar cuotas), y seguía en la cola de
-- corte — con riesgo de cortarle el servicio a alguien al día. Además rompía
-- INV20 de `invariantes_dinero.sql`.
--
-- El mismo mecanismo rompía la cascada de `propagate_cobrador_id_from_cliente()`:
-- un `admin_usuarios` reasignaba el cobrador de un cliente, la propagación a
-- `clientes` y `cuotas` entraba y la de `contratos` se revertía → el contrato
-- quedaba con el cobrador VIEJO. Escritura parcial, sin un solo error.
--
-- ── EL FIX ──────────────────────────────────────────────────────────────────
-- Un escape que distingue "lo escribió el server" de "lo escribió el usuario",
-- sin enumerar funciones ni columnas:
--
--     current_user IS DISTINCT FROM 'authenticated'
--
-- Un UPDATE que viene derecho de la app corre como el rol `authenticated`.
-- Adentro de una función `SECURITY DEFINER` de owner postgres, `current_user`
-- pasa a ser postgres; los crons y el `service_role` tampoco son
-- `authenticated`. O sea: la barrera se aplica SOLO cuando escribe la app, y
-- cualquier función del server que se agregue mañana queda cubierta sola — que
-- es justo lo que fallaba: 0230 razonaba sobre QUIÉN es el usuario, cuando la
-- pregunta correcta era QUIÉN está escribiendo.
--
-- OJO — NO sirve `current_user <> session_user`, que fue el primer intento y
-- desactivaba la barrera ENTERA: bajo Supabase la conexión entra como
-- `authenticator` y hace `SET ROLE authenticated`, así que los dos difieren en
-- TODA petición normal. Lo cazó la prueba de regresión de acá abajo, no el
-- razonamiento.
--
-- Para que eso funcione las dos funciones pasan a `SECURITY INVOKER`: siendo
-- DEFINER, `current_user` era SIEMPRE el owner y la comparación no distinguía
-- nada. No pierden capacidad: solo leen OLD/NEW y llaman helpers que siguen
-- siendo DEFINER.
--
-- Se conservan los tres escapes de 0230 (server sin JWT, roles con escritura
-- completa, y el cambio de fecha del cobrador).

-- ── CLIENTES ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.clientes_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_updated  timestamptz := new.updated_at;
BEGIN
  -- Escape 1: server sin sesión de usuario (crons, service_role).
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 1b (0231): lo está escribiendo una función SECURITY DEFINER del
  -- server DENTRO de la sesión del usuario — p.ej. recalc_vencimiento_mas_viejo
  -- al cobrar, o propagate_cobrador_id_from_cliente al reasignar. Sin esto la
  -- barrera le revertía al server sus propias columnas derivadas.
  IF current_user IS DISTINCT FROM 'authenticated' THEN
    RETURN new;
  END IF;
  -- Escape 2: los roles que ya tenían escritura completa sobre `clientes`.
  IF public.is_super_admin()
     OR public.is_admin_or_cobranza()
     OR public.current_user_rol() = 'admin_usuarios' THEN
    RETURN new;
  END IF;
  -- El resto: SOLO la nota (más las marcas de tiempo).
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  new.updated_at  := v_updated;
  RETURN new;
END;
$function$;

-- ── CONTRATOS ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.contratos_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_dia_pago integer     := new.dia_pago;
  v_fecha_fin date       := new.fecha_fin;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 1b (0231) — ver el comentario en clientes_solo_notas_trg.
  IF current_user IS DISTINCT FROM 'authenticated' THEN
    RETURN new;
  END IF;
  IF public.is_super_admin() OR public.is_admin_or_cobranza() THEN
    RETURN new;
  END IF;
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  -- Escape 3: cambio de fecha de pago del cobrador (policy
  -- `contratos_cambiar_fecha`). Sus límites los sigue aplicando
  -- `contratos_check_cobrador_update`, que corre después.
  IF public.current_user_rol() = 'cobrador'
     AND old.cobrador_id = auth.uid()
     AND public.puede_cambiar_fecha_pago() THEN
    new.dia_pago  := v_dia_pago;
    new.fecha_fin := v_fecha_fin;
  END IF;
  RETURN new;
END;
$function$;


-- >>> Migration: 0232_notas_gaps_del_audit.sql <<<
-- 0232 — Dos huecos que dejó 0230, cazados por el audit adversarial
--
-- ── (A) EL EMPLEADO DADO DE BAJA SEGUÍA PUDIENDO ESCRIBIR ───────────────────
-- Las policies de 0230 pedían tenant + rol distinto de 'lectura', pero NO
-- miraban `cobradores.activo`. `current_user_rol()` devuelve el rol igual para
-- un usuario desactivado, así que alguien dado de baja en la app —mientras su
-- refresh token de Supabase siguiera vivo— podía reescribir por REST la nota de
-- cualquier cliente y de cualquier contrato del tenant. Antes de 0230 no tenía
-- NINGUNA policy de escritura, así que esto lo introdujo 0230.
--
-- ── (B) admin_usuarios VEÍA EL LÁPIZ Y LA NOTA NO SE GUARDABA ───────────────
-- 0230 le dio UPDATE sobre `contratos`, pero `contratos_read` es
-- `is_personal_cobranza()` (admin, admin_cobranza, cobrador) y NO lo cubre. El
-- connector sube el write como `.update(...).select('id')`, y ese RETURNING
-- necesita permiso de SELECT: sin él Postgres devuelve 0 filas y el UPDATE se
-- descarta.
--
-- El resultado era peor que "no funciona": el `op_log` viaja como una operación
-- APARTE contra otra tabla, cuya policy de INSERT sí lo deja pasar. O sea que
-- el historial del contrato mostraba «notas: (vacío) → "instalación con 40 m de
-- cable"», firmado y fechado, y el contrato no tenía esa nota. El historial
-- mintiendo es justo lo que este proyecto no se puede permitir.
--
-- Se resuelve con la lectura, no achicando el permiso: `admin_usuarios` YA
-- recibe `contratos` en su dispositivo por las sync rules (bucket
-- `todo_tenant_admin_usuarios`), así que la policy solo alinea el acceso REST
-- con lo que ese rol ya tiene local. No se agrega ningún dato nuevo a su vista.
--
-- NO se toca `tecnico` / `admin_tickets` / `coordinador`: 0230 les dio un UPDATE
-- que hoy es inefectivo (no tienen SELECT). Queda así a propósito — el router
-- los confina a sus propios shells y no llegan a la ficha del cliente ni a la
-- del contrato, así que abrirles la lectura sería ampliar acceso sin un caso de
-- uso. Si algún día se les da esa pantalla, hay que volver acá.

-- ── (A) ────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS clientes_write_notas ON public.clientes;
CREATE POLICY clientes_write_notas ON public.clientes
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura'
         AND EXISTS (SELECT 1 FROM public.cobradores cb
                      WHERE cb.id = auth.uid() AND cb.activo))
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura'
              AND EXISTS (SELECT 1 FROM public.cobradores cb
                           WHERE cb.id = auth.uid() AND cb.activo));

DROP POLICY IF EXISTS contratos_write_notas ON public.contratos;
CREATE POLICY contratos_write_notas ON public.contratos
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura'
         AND EXISTS (SELECT 1 FROM public.cobradores cb
                      WHERE cb.id = auth.uid() AND cb.activo))
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura'
              AND EXISTS (SELECT 1 FROM public.cobradores cb
                           WHERE cb.id = auth.uid() AND cb.activo));

-- ── (B) ────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS contratos_read_admin_usuarios ON public.contratos;
CREATE POLICY contratos_read_admin_usuarios ON public.contratos
  FOR SELECT
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() = 'admin_usuarios');

COMMENT ON POLICY contratos_read_admin_usuarios ON public.contratos IS
  'Alinea el acceso REST con lo que este rol ya recibe por sync rules (bucket '
  'todo_tenant_admin_usuarios). Sin esto, el RETURNING de su UPDATE de `notas` '
  'devolvía 0 filas y la nota se descartaba en silencio mientras el op_log sí '
  'registraba el cambio — historial mintiendo.';


-- >>> Migration: 0233_rls_una_vez_por_consulta.sql <<<
-- 0233 — Las reglas de permiso se evalúan UNA VEZ por consulta, no una por fila
--
-- ── EL SÍNTOMA ──────────────────────────────────────────────────────────────
-- "No se pudo verificar el número contra la base (el servidor respondió un
-- error)" al crear un contrato en Telecable Mairena. Intermitente: a veces sí,
-- a veces no.
--
-- ── LA CAUSA ────────────────────────────────────────────────────────────────
-- Postgres evalúa una función suelta dentro de una policy UNA VEZ POR FILA.
-- Buscar UN código entre los 4.548 contratos del tenant significaba 4.548 × 5
-- llamadas a `is_super_admin()`, `current_tenant_id()`, etc. Medido en
-- producción: **4.196 ms** para una búsqueda que debería ser instantánea.
--
-- El rol `authenticated` tiene `statement_timeout = 8s` (lo pone Supabase). Con
-- 4 segundos de piso, basta algo de carga o latencia para pasarse, y ahí
-- Postgres mata la consulta y PostgREST devuelve el error que veía el usuario.
-- Por eso fallaba de a ratos.
--
-- Peor: contar `cuotas` (56.392 filas) como usuario autenticado YA se pasa de
-- los 8 segundos hoy. Cualquier consulta directa a esa tabla está rota.
--
-- ── EL ARREGLO ──────────────────────────────────────────────────────────────
-- Envolver cada llamada en `(SELECT fn())`. Con eso Postgres la resuelve como
-- InitPlan —una sola vez por consulta— en vez de por fila. Es la optimización
-- que la propia documentación de Supabase recomienda para RLS.
--
-- Medido en producción, misma búsqueda de código:  4.196 ms → **9 ms**.
--
-- NO cambia a quién le da acceso: es la MISMA condición calculada de otra
-- forma. Verificado antes de aplicar: se contaron las filas visibles para un
-- representante de cada (tenant, rol) —14 usuarios × 7 tablas = 98
-- mediciones, sobre 592 filas muestreadas de los 3 tenants— con las policies
-- viejas y con las nuevas, dentro de una transacción revertida.
-- Resultado: **0 diferencias**.
--
-- ── ALCANCE ─────────────────────────────────────────────────────────────────
-- Las 45 policies de las 7 tablas con más de 1.000 filas: clientes, contratos,
-- cuotas, pagos, recibos, notificaciones_mora y op_log. Las tablas chicas
-- quedan como están a propósito: el costo por fila es irrelevante con 50 filas,
-- y reescribir 100 policies más sería sumar riesgo sin ganancia. Si alguna
-- crece, se aplica el mismo patrón.
--
-- ── REGLA PARA EL FUTURO ────────────────────────────────────────────────────
-- Toda policy nueva sobre una tabla que pueda crecer debe envolver sus
-- llamadas a función en `(SELECT ...)`. Una policy sin envolver no falla ni da
-- error: solo hace la tabla progresivamente más lenta hasta que un día se pasa
-- del límite y aparece un "error del servidor" que no dice nada.

DROP POLICY IF EXISTS "clientes_read" ON public.clientes;
CREATE POLICY "clientes_read" ON public.clientes
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "clientes_write_admin_usuarios" ON public.clientes;
CREATE POLICY "clientes_write_admin_usuarios" ON public.clientes
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_usuarios'::text)))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_usuarios'::text)));

DROP POLICY IF EXISTS "clientes_write_admins" ON public.clientes;
CREATE POLICY "clientes_write_admins" ON public.clientes
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "clientes_write_notas" ON public.clientes;
CREATE POLICY "clientes_write_notas" ON public.clientes
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))));

DROP POLICY IF EXISTS "lectura_select" ON public.clientes;
CREATE POLICY "lectura_select" ON public.clientes
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "super_admin_all" ON public.clientes;
CREATE POLICY "super_admin_all" ON public.clientes
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "contratos_cambiar_fecha" ON public.contratos;
CREATE POLICY "contratos_cambiar_fecha" ON public.contratos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())));

DROP POLICY IF EXISTS "contratos_read" ON public.contratos;
CREATE POLICY "contratos_read" ON public.contratos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "contratos_read_admin_usuarios" ON public.contratos;
CREATE POLICY "contratos_read_admin_usuarios" ON public.contratos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_usuarios'::text)));

DROP POLICY IF EXISTS "contratos_write_admins" ON public.contratos;
CREATE POLICY "contratos_write_admins" ON public.contratos
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "contratos_write_notas" ON public.contratos;
CREATE POLICY "contratos_write_notas" ON public.contratos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))));

DROP POLICY IF EXISTS "lectura_select" ON public.contratos;
CREATE POLICY "lectura_select" ON public.contratos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "super_admin_all" ON public.contratos;
CREATE POLICY "super_admin_all" ON public.contratos
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "cuotas_cambiar_fecha_insert" ON public.cuotas;
CREATE POLICY "cuotas_cambiar_fecha_insert" ON public.cuotas
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago()) AND (EXISTS ( SELECT 1
   FROM contratos c
  WHERE ((c.id = cuotas.contrato_id) AND (c.cobrador_id = (SELECT auth.uid())) AND (c.tenant_id = (SELECT current_tenant_id())))))));

DROP POLICY IF EXISTS "cuotas_cambiar_fecha_update" ON public.cuotas;
CREATE POLICY "cuotas_cambiar_fecha_update" ON public.cuotas
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())));

DROP POLICY IF EXISTS "cuotas_read" ON public.cuotas;
CREATE POLICY "cuotas_read" ON public.cuotas
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "cuotas_update_cobrador_propio" ON public.cuotas;
CREATE POLICY "cuotas_update_cobrador_propio" ON public.cuotas
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text)))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text)));

DROP POLICY IF EXISTS "cuotas_write_admins" ON public.cuotas;
CREATE POLICY "cuotas_write_admins" ON public.cuotas
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "lectura_select" ON public.cuotas;
CREATE POLICY "lectura_select" ON public.cuotas
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "super_admin_all" ON public.cuotas;
CREATE POLICY "super_admin_all" ON public.cuotas
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.notificaciones_mora;
CREATE POLICY "lectura_select" ON public.notificaciones_mora
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "notif_delete_admin" ON public.notificaciones_mora;
CREATE POLICY "notif_delete_admin" ON public.notificaciones_mora
  FOR DELETE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin())));

DROP POLICY IF EXISTS "notif_read" ON public.notificaciones_mora;
CREATE POLICY "notif_read" ON public.notificaciones_mora
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "notif_update_marca" ON public.notificaciones_mora;
CREATE POLICY "notif_update_marca" ON public.notificaciones_mora
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (cobrador_id = (SELECT auth.uid())))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (cobrador_id = (SELECT auth.uid())))));

DROP POLICY IF EXISTS "notif_write_admin" ON public.notificaciones_mora;
CREATE POLICY "notif_write_admin" ON public.notificaciones_mora
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "super_admin_all" ON public.notificaciones_mora;
CREATE POLICY "super_admin_all" ON public.notificaciones_mora
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.op_log;
CREATE POLICY "lectura_select" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "op_log_insert" ON public.op_log;
CREATE POLICY "op_log_insert" ON public.op_log
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((actor_id = (SELECT auth.uid())) OR (actor_id IS NULL)) AND (NOT (SELECT is_lectura()))));

DROP POLICY IF EXISTS "op_log_read" ON public.op_log;
CREATE POLICY "op_log_read" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "op_log_read_admin_tickets" ON public.op_log;
CREATE POLICY "op_log_read_admin_tickets" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_tickets'::text) AND (entidad = ANY (ARRAY['tickets'::text, 'ticket_tipos'::text, 'incidentes'::text]))));

DROP POLICY IF EXISTS "op_log_read_cobrador" ON public.op_log;
CREATE POLICY "op_log_read_cobrador" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (actor_id = (SELECT auth.uid()))));

DROP POLICY IF EXISTS "op_log_update" ON public.op_log;
CREATE POLICY "op_log_update" ON public.op_log
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((actor_id = (SELECT auth.uid())) OR (actor_id IS NULL)) AND (NOT (SELECT is_lectura()))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((actor_id = (SELECT auth.uid())) OR (actor_id IS NULL)) AND (NOT (SELECT is_lectura()))));

DROP POLICY IF EXISTS "super_admin_all" ON public.op_log;
CREATE POLICY "super_admin_all" ON public.op_log
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.pagos;
CREATE POLICY "lectura_select" ON public.pagos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "pagos_delete_admin" ON public.pagos;
CREATE POLICY "pagos_delete_admin" ON public.pagos
  FOR DELETE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin())));

DROP POLICY IF EXISTS "pagos_insert_propio" ON public.pagos;
CREATE POLICY "pagos_insert_propio" ON public.pagos
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid())) AND (EXISTS ( SELECT 1
   FROM cuotas
  WHERE ((cuotas.id = pagos.cuota_id) AND (cuotas.tenant_id = (SELECT current_tenant_id())))))))));

DROP POLICY IF EXISTS "pagos_read" ON public.pagos;
CREATE POLICY "pagos_read" ON public.pagos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "pagos_update" ON public.pagos;
CREATE POLICY "pagos_update" ON public.pagos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))));

DROP POLICY IF EXISTS "super_admin_all" ON public.pagos;
CREATE POLICY "super_admin_all" ON public.pagos
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.recibos;
CREATE POLICY "lectura_select" ON public.recibos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "recibos_insert_propio" ON public.recibos;
CREATE POLICY "recibos_insert_propio" ON public.recibos
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))));

DROP POLICY IF EXISTS "recibos_read" ON public.recibos;
CREATE POLICY "recibos_read" ON public.recibos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "recibos_update_admins" ON public.recibos;
CREATE POLICY "recibos_update_admins" ON public.recibos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "recibos_update_impresion_cobrador" ON public.recibos;
CREATE POLICY "recibos_update_impresion_cobrador" ON public.recibos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))));

DROP POLICY IF EXISTS "super_admin_all" ON public.recibos;
CREATE POLICY "super_admin_all" ON public.recibos
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));


