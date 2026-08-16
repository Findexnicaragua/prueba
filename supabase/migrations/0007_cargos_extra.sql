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
