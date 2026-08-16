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
