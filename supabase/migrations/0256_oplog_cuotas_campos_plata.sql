-- 0256 — `cargos_neto` y `monto_pagado` de la cuota al historial de cambios
--
-- El corrector de invariantes (0251) escribe esos dos campos como
-- antes -> despues cuando arregla un descuadre de plata. El lado Dart ya se
-- amplio (`kOpLogCamposCatalogo['cuotas']` + `kOpLogCamposVisiblesDefault`).
-- Pero eso NO alcanza, por la MISMA razon que documenta 0228:
-- `opLogCamposVisibles` (op_log_campos.dart:97) le da prioridad al override
-- persistido del tenant sobre el default de Dart —
--     if (ov == null) return kOpLogCamposVisiblesDefault[entidad] ?? catalogo;
--     return [for (final k in catalogo) if (ov.contains(k)) k];
-- — asi que un tenant con la fila `op_log.campos_visibles` guardada sigue
-- filtrando contra SU lista vieja y los dos campos quedan invisibles. Pareceria
-- un bug de codigo y no lo seria.
--
-- ESTADO VERIFICADO antes de escribir esto (2026-08-23, contra vxxz):
--   Telenet            -> cuotas: SIN cargos_neto, SIN monto_pagado
--   Test Tenant        -> cuotas: SIN cargos_neto, SIN monto_pagado
--   Telecable Mairena  -> sin fila (cae al default de Dart, ya corregido)
--   System             -> sin fila
--
-- POR QUE IMPORTA: sin esto, de los dos ISPs vivos uno recibe el cambio y el
-- otro no, y encima al reves de lo intuitivo — Mairena (el grande, sin fila)
-- veria los numeros, y Telenet (el que si configuro sus campos) veria el motivo
-- de la correccion pero NO de cuanto a cuanto quedo la plata. Que es lo unico
-- que sirve para revisar un cambio automatico de dinero.
--
-- Se agrega tambien `motivo`, que ya esta en el catalogo y en el override de
-- los dos tenants pero NO en el default de Dart: asi las dos mitades -el por
-- que y los numeros- quedan visibles en TODOS los tenants. (El lado Dart de
-- `motivo` va en el mismo commit.)
--
-- IDEMPOTENTE: un UPDATE por clave, cada uno con su `NOT (... ? 'campo')`,
-- igual que 0228. Re-correrla no duplica nada.
-- NO TOCA DINERO: `settings` solo decide que columnas se MUESTRAN.

UPDATE public.settings
   SET valor = jsonb_set(
         valor::jsonb,
         '{cuotas}',
         (valor::jsonb -> 'cuotas') || '["cargos_neto"]'::jsonb
       )::text,
       updated_at = now()
 WHERE clave = 'op_log.campos_visibles'
   AND valor::jsonb ? 'cuotas'
   AND jsonb_typeof(valor::jsonb -> 'cuotas') = 'array'
   AND NOT ((valor::jsonb -> 'cuotas') ? 'cargos_neto');

UPDATE public.settings
   SET valor = jsonb_set(
         valor::jsonb,
         '{cuotas}',
         (valor::jsonb -> 'cuotas') || '["monto_pagado"]'::jsonb
       )::text,
       updated_at = now()
 WHERE clave = 'op_log.campos_visibles'
   AND valor::jsonb ? 'cuotas'
   AND jsonb_typeof(valor::jsonb -> 'cuotas') = 'array'
   AND NOT ((valor::jsonb -> 'cuotas') ? 'monto_pagado');
