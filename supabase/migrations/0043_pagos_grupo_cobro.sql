-- 0043: Agregar grupo_cobro a pagos para agrupar pagos multi-cuota.
-- Cuando un cobrador paga N cuotas del mismo contrato en un solo acto,
-- todos los pagos comparten el mismo grupo_cobro UUID.
-- NULL = pago individual (single cuota).

ALTER TABLE pagos ADD COLUMN grupo_cobro uuid;

CREATE INDEX idx_pagos_grupo_cobro ON pagos (grupo_cobro)
  WHERE grupo_cobro IS NOT NULL;
