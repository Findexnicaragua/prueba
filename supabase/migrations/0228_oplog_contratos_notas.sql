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
