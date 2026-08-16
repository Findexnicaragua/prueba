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
