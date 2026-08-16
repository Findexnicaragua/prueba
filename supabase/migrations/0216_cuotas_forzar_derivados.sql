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
