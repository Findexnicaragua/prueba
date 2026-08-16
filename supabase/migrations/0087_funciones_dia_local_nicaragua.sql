-- 0087 — Día local Nicaragua también en las funciones server-side de límite
-- de día. Mismo objetivo que el fix del cliente (date('now','-6 hours')): el
-- negocio opera en hora de Nicaragua (UTC-6, sin DST).
--
-- MECANISMO: `SET timezone='America/Managua'` POR FUNCIÓN (GUC scopeado a la
-- ejecución de esa función). Dentro de cada una, `current_date` / `now()`
-- devuelven el día Nicaragua sin importar a qué hora se la llame — clave para
-- los triggers que corren AD-HOC (ej. crear/editar un contrato de noche, cuando
-- el UTC ya es el día siguiente).
--
-- POR QUÉ NO cambiar el timezone global de la DB: alteraría el wire-format de
-- TODOS los `timestamptz` (pasarían a mostrarse con offset -06), lo que
-- cambiaría cómo PowerSync/el cliente reciben y parsean esas fechas y podría
-- desalinear el fix del cliente (date() de SQLite sobre un ISO con offset).
-- Per-función es quirúrgico y no toca nada más.
--
-- NOTA crons: `generar_cuotas_mensual` (06:05 UTC = 00:05 Nicaragua) y el de
-- mora ya están agendados a la medianoche Nicaragua, así que su `current_date`
-- ya coincidía al ejecutarse. El SET por-función los hace robustos igual (si
-- cambia el horario del cron o si se llaman ad-hoc).
--
-- Sin columnas/tablas nuevas → sin bump de schema ni redeploy de sync rules.

-- Mora: día actual para marcar vencidas pasada la gracia + días de mora.
alter function public.actualizar_notificaciones_mora(uuid)
  set timezone = 'America/Managua';

-- Generación de cuotas del contrato: se dispara por trigger al crear/editar un
-- contrato (a cualquier hora). Usa current_date para el colchón de meses de los
-- contratos indefinidos.
alter function public.generar_cuotas_contrato(uuid, integer)
  set timezone = 'America/Managua';

-- Trigger de UPDATE de contrato: usa current_date para el "mes actual" al
-- recalcular las cuotas futuras.
alter function public.contratos_actualizar_cuotas_futuras_trg()
  set timezone = 'America/Managua';
