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
