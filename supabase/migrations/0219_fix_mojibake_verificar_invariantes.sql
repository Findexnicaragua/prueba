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
