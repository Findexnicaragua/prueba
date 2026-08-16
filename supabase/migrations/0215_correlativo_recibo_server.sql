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
