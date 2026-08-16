-- ============================================================================
-- 0114 — Gate server-side de módulos opcionales (M2 del AUDIT-INTEGRAL-2026-06-09)
--
-- PROBLEMA: las policies de inventario (0099-0101) y tickets/incidentes
-- (0103/0106/0107) chequean tenant + rol pero NO consultan tenant_tiene_modulo().
-- El gate de "módulo habilitado" vivía solo en el router/UI del cliente → un
-- admin de un tenant con el módulo OFF podía leer/escribir esas tablas vía
-- REST/PowerSync directo (mismo tenant, no cruza tenants — es un gap de
-- consistencia COMERCIAL, no de aislamiento). Mismo patrón ya cerrado
-- server-side para settings super-only (0085) y descuentos/reconexión (0086).
--
-- DECISIÓN (write-only gating):
--   · ESCRITURA (insert/update/delete) → exige tenant_tiene_modulo(). Es la
--     decisión comercial del dueño del SaaS: sin módulo contratado, no se opera.
--   · LECTURA (select) → NO se gatea. Apagar un módulo no debe "desaparecer"
--     la data histórica que el admin pueda necesitar consultar; y la
--     replicación de PowerSync no pasa por RLS de todos modos (sync rules).
--   · super_admin_all queda INTACTA (OR entre policies → el super siempre opera).
--
-- NOTAS DE COMPORTAMIENTO:
--   · El trigger SECURITY DEFINER ticket_materiales_consumo (0106) sigue
--     funcionando aunque 'inventario' esté OFF y 'tickets' ON: corre como el
--     owner (bypassa RLS sin FORCE). El consumo de materiales es del módulo
--     tickets; los inv_movimientos derivados son proyección del sistema.
--   · Si un tenant tiene writes offline ENCOLADOS y el super le apaga el módulo
--     antes del sync: los INSERT se rechazan (42501) y el connector los
--     descarta CON aviso; los UPDATE/DELETE bloqueados por USING son no-op
--     silenciosos (0 rows, 2xx) — el dato local diverge hasta que el próximo
--     checkpoint server-wins lo pisa (self-heals, sin aviso). Edge case
--     aceptado: apagar un módulo con campo activo es acción deliberada del super.
--
-- DEFENSIVA: cada bloque se saltea con NOTICE si la tabla no existe todavía
-- (migraciones 0099→0107 sin correr) → esta migración es segura de correr en
-- cualquier orden relativo al deploy del bloque inventario/tickets. Si se
-- corrió ANTES, RE-CORRERLA después de 0099→0107 para que aplique completa.
-- Idempotente (DROP POLICY IF EXISTS + CREATE).
-- ============================================================================

DO $$
DECLARE
  t text;
BEGIN
  -- ── Inventario: inv_insert / inv_update / inv_delete + módulo 'inventario' ──
  FOREACH t IN ARRAY ARRAY[
    'inv_categorias', 'inv_proveedores', 'inv_productos',
    'inv_ubicaciones', 'inv_seriales'
  ] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE '0114: tabla % no existe (0099-0101 sin correr) — skip', t;
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS "inv_insert" ON public.%I;', t);
    EXECUTE format($p$
      CREATE POLICY "inv_insert" ON public.%I FOR INSERT
        WITH CHECK (tenant_id = public.current_tenant_id()
                    AND public.is_admin_or_cobranza()
                    AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
    $p$, t);
    EXECUTE format('DROP POLICY IF EXISTS "inv_update" ON public.%I;', t);
    EXECUTE format($p$
      CREATE POLICY "inv_update" ON public.%I FOR UPDATE
        USING (tenant_id = public.current_tenant_id()
               AND public.is_admin_or_cobranza()
               AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
    $p$, t);
    EXECUTE format('DROP POLICY IF EXISTS "inv_delete" ON public.%I;', t);
    EXECUTE format($p$
      CREATE POLICY "inv_delete" ON public.%I FOR DELETE
        USING (tenant_id = public.current_tenant_id()
               AND public.is_admin_or_cobranza()
               AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
    $p$, t);
  END LOOP;

  -- inv_movimientos: ledger append-only (solo tenía inv_insert).
  IF to_regclass('public.inv_movimientos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "inv_insert" ON public.inv_movimientos;
    CREATE POLICY "inv_insert" ON public.inv_movimientos FOR INSERT
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_admin_or_cobranza()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'inventario'));
  ELSE
    RAISE NOTICE '0114: inv_movimientos no existe — skip';
  END IF;

  -- ── Tickets / incidentes: módulo 'tickets' ─────────────────────────────────
  -- ticket_tipos (tt_write FOR ALL, is_admin_or_tickets)
  IF to_regclass('public.ticket_tipos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "tt_write" ON public.ticket_tipos;
    CREATE POLICY "tt_write" ON public.ticket_tipos FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_admin_or_tickets()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_admin_or_tickets()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_tipos no existe (0103 sin correr) — skip';
  END IF;

  -- tickets (tk_write FOR ALL, is_ticket_staff)
  IF to_regclass('public.tickets') IS NOT NULL THEN
    DROP POLICY IF EXISTS "tk_write" ON public.tickets;
    CREATE POLICY "tk_write" ON public.tickets FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_ticket_staff()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: tickets no existe (0103 sin correr) — skip';
  END IF;

  -- ticket_eventos (te_insert, append-only, is_ticket_staff)
  IF to_regclass('public.ticket_eventos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "te_insert" ON public.ticket_eventos;
    CREATE POLICY "te_insert" ON public.ticket_eventos FOR INSERT
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_eventos no existe (0103 sin correr) — skip';
  END IF;

  -- ticket_adjuntos (ta_write FOR ALL, is_ticket_staff)
  IF to_regclass('public.ticket_adjuntos') IS NOT NULL THEN
    DROP POLICY IF EXISTS "ta_write" ON public.ticket_adjuntos;
    CREATE POLICY "ta_write" ON public.ticket_adjuntos FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_ticket_staff()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_adjuntos no existe (0103 sin correr) — skip';
  END IF;

  -- ticket_materiales (tm_insert, append-only, is_ticket_staff)
  IF to_regclass('public.ticket_materiales') IS NOT NULL THEN
    DROP POLICY IF EXISTS "tm_insert" ON public.ticket_materiales;
    CREATE POLICY "tm_insert" ON public.ticket_materiales FOR INSERT
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_ticket_staff()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: ticket_materiales no existe (0106 sin correr) — skip';
  END IF;

  -- incidentes (inc_write FOR ALL, is_admin_or_tickets)
  IF to_regclass('public.incidentes') IS NOT NULL THEN
    DROP POLICY IF EXISTS "inc_write" ON public.incidentes;
    CREATE POLICY "inc_write" ON public.incidentes FOR ALL
      USING (tenant_id = public.current_tenant_id()
             AND public.is_admin_or_tickets()
             AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
      WITH CHECK (tenant_id = public.current_tenant_id()
                  AND public.is_admin_or_tickets()
                  AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));
  ELSE
    RAISE NOTICE '0114: incidentes no existe (0107 sin correr) — skip';
  END IF;

  -- ── Storage del bucket ticket-adjuntos (0104): mismo gap, mismo gate ───────
  -- Sin esto, un tenant con tickets OFF no podía crear la fila ta_write
  -- (gateada arriba) pero SÍ subir binarios al bucket vía Storage API.
  -- La función helper storage_path_tenant + la policy existen solo si 0104
  -- corrió; el to_regprocedure lo detecta.
  IF to_regprocedure('public.storage_path_tenant(text)') IS NOT NULL THEN
    DROP POLICY IF EXISTS "storage_write_ticket_adjuntos" ON storage.objects;
    CREATE POLICY "storage_write_ticket_adjuntos" ON storage.objects
      FOR ALL TO authenticated
      USING (
        bucket_id = 'ticket-adjuntos'
        AND public.storage_path_tenant(name) = public.current_tenant_id()
        AND public.is_ticket_staff()
        AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets')
      )
      WITH CHECK (
        bucket_id = 'ticket-adjuntos'
        AND public.storage_path_tenant(name) = public.current_tenant_id()
        AND public.is_ticket_staff()
        AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets')
      );
  ELSE
    RAISE NOTICE '0114: storage_path_tenant no existe (0104 sin correr) — skip';
  END IF;
END$$;

-- Verificación rápida post-run (debe listar las policies recreadas con el gate):
--   SELECT schemaname, tablename, policyname, qual, with_check FROM pg_policies
--    WHERE (schemaname='public' AND policyname IN
--      ('inv_insert','inv_update','inv_delete','tt_write','tk_write',
--       'te_insert','ta_write','tm_insert','inc_write'))
--       OR (schemaname='storage' AND policyname='storage_write_ticket_adjuntos')
--    ORDER BY schemaname, tablename, policyname;
-- Cada qual/with_check debe contener "tenant_tiene_modulo".
