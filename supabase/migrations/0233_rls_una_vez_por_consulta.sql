-- 0233 — Las reglas de permiso se evalúan UNA VEZ por consulta, no una por fila
--
-- ── EL SÍNTOMA ──────────────────────────────────────────────────────────────
-- "No se pudo verificar el número contra la base (el servidor respondió un
-- error)" al crear un contrato en Telecable Mairena. Intermitente: a veces sí,
-- a veces no.
--
-- ── LA CAUSA ────────────────────────────────────────────────────────────────
-- Postgres evalúa una función suelta dentro de una policy UNA VEZ POR FILA.
-- Buscar UN código entre los 4.548 contratos del tenant significaba 4.548 × 5
-- llamadas a `is_super_admin()`, `current_tenant_id()`, etc. Medido en
-- producción: **4.196 ms** para una búsqueda que debería ser instantánea.
--
-- El rol `authenticated` tiene `statement_timeout = 8s` (lo pone Supabase). Con
-- 4 segundos de piso, basta algo de carga o latencia para pasarse, y ahí
-- Postgres mata la consulta y PostgREST devuelve el error que veía el usuario.
-- Por eso fallaba de a ratos.
--
-- Peor: contar `cuotas` (56.392 filas) como usuario autenticado YA se pasa de
-- los 8 segundos hoy. Cualquier consulta directa a esa tabla está rota.
--
-- ── EL ARREGLO ──────────────────────────────────────────────────────────────
-- Envolver cada llamada en `(SELECT fn())`. Con eso Postgres la resuelve como
-- InitPlan —una sola vez por consulta— en vez de por fila. Es la optimización
-- que la propia documentación de Supabase recomienda para RLS.
--
-- Medido en producción, misma búsqueda de código:  4.196 ms → **9 ms**.
--
-- NO cambia a quién le da acceso: es la MISMA condición calculada de otra
-- forma. Verificado antes de aplicar: se contaron las filas visibles para un
-- representante de cada (tenant, rol) —14 usuarios × 7 tablas = 98
-- mediciones, sobre 592 filas muestreadas de los 3 tenants— con las policies
-- viejas y con las nuevas, dentro de una transacción revertida.
-- Resultado: **0 diferencias**.
--
-- ── ALCANCE ─────────────────────────────────────────────────────────────────
-- Las 45 policies de las 7 tablas con más de 1.000 filas: clientes, contratos,
-- cuotas, pagos, recibos, notificaciones_mora y op_log. Las tablas chicas
-- quedan como están a propósito: el costo por fila es irrelevante con 50 filas,
-- y reescribir 100 policies más sería sumar riesgo sin ganancia. Si alguna
-- crece, se aplica el mismo patrón.
--
-- ── REGLA PARA EL FUTURO ────────────────────────────────────────────────────
-- Toda policy nueva sobre una tabla que pueda crecer debe envolver sus
-- llamadas a función en `(SELECT ...)`. Una policy sin envolver no falla ni da
-- error: solo hace la tabla progresivamente más lenta hasta que un día se pasa
-- del límite y aparece un "error del servidor" que no dice nada.

DROP POLICY IF EXISTS "clientes_read" ON public.clientes;
CREATE POLICY "clientes_read" ON public.clientes
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "clientes_write_admin_usuarios" ON public.clientes;
CREATE POLICY "clientes_write_admin_usuarios" ON public.clientes
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_usuarios'::text)))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_usuarios'::text)));

DROP POLICY IF EXISTS "clientes_write_admins" ON public.clientes;
CREATE POLICY "clientes_write_admins" ON public.clientes
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "clientes_write_notas" ON public.clientes;
CREATE POLICY "clientes_write_notas" ON public.clientes
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))));

DROP POLICY IF EXISTS "lectura_select" ON public.clientes;
CREATE POLICY "lectura_select" ON public.clientes
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "super_admin_all" ON public.clientes;
CREATE POLICY "super_admin_all" ON public.clientes
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "contratos_cambiar_fecha" ON public.contratos;
CREATE POLICY "contratos_cambiar_fecha" ON public.contratos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())));

DROP POLICY IF EXISTS "contratos_read" ON public.contratos;
CREATE POLICY "contratos_read" ON public.contratos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "contratos_read_admin_usuarios" ON public.contratos;
CREATE POLICY "contratos_read_admin_usuarios" ON public.contratos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_usuarios'::text)));

DROP POLICY IF EXISTS "contratos_write_admins" ON public.contratos;
CREATE POLICY "contratos_write_admins" ON public.contratos
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "contratos_write_notas" ON public.contratos;
CREATE POLICY "contratos_write_notas" ON public.contratos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) IS DISTINCT FROM 'lectura'::text) AND (EXISTS ( SELECT 1
   FROM cobradores cb
  WHERE ((cb.id = (SELECT auth.uid())) AND cb.activo)))));

DROP POLICY IF EXISTS "lectura_select" ON public.contratos;
CREATE POLICY "lectura_select" ON public.contratos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "super_admin_all" ON public.contratos;
CREATE POLICY "super_admin_all" ON public.contratos
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "cuotas_cambiar_fecha_insert" ON public.cuotas;
CREATE POLICY "cuotas_cambiar_fecha_insert" ON public.cuotas
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago()) AND (EXISTS ( SELECT 1
   FROM contratos c
  WHERE ((c.id = cuotas.contrato_id) AND (c.cobrador_id = (SELECT auth.uid())) AND (c.tenant_id = (SELECT current_tenant_id())))))));

DROP POLICY IF EXISTS "cuotas_cambiar_fecha_update" ON public.cuotas;
CREATE POLICY "cuotas_cambiar_fecha_update" ON public.cuotas
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (cobrador_id = (SELECT auth.uid())) AND (SELECT puede_cambiar_fecha_pago())));

DROP POLICY IF EXISTS "cuotas_read" ON public.cuotas;
CREATE POLICY "cuotas_read" ON public.cuotas
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "cuotas_update_cobrador_propio" ON public.cuotas;
CREATE POLICY "cuotas_update_cobrador_propio" ON public.cuotas
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text)))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text)));

DROP POLICY IF EXISTS "cuotas_write_admins" ON public.cuotas;
CREATE POLICY "cuotas_write_admins" ON public.cuotas
  FOR ALL TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "lectura_select" ON public.cuotas;
CREATE POLICY "lectura_select" ON public.cuotas
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "super_admin_all" ON public.cuotas;
CREATE POLICY "super_admin_all" ON public.cuotas
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.notificaciones_mora;
CREATE POLICY "lectura_select" ON public.notificaciones_mora
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "notif_delete_admin" ON public.notificaciones_mora;
CREATE POLICY "notif_delete_admin" ON public.notificaciones_mora
  FOR DELETE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin())));

DROP POLICY IF EXISTS "notif_read" ON public.notificaciones_mora;
CREATE POLICY "notif_read" ON public.notificaciones_mora
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "notif_update_marca" ON public.notificaciones_mora;
CREATE POLICY "notif_update_marca" ON public.notificaciones_mora
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (cobrador_id = (SELECT auth.uid())))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (cobrador_id = (SELECT auth.uid())))));

DROP POLICY IF EXISTS "notif_write_admin" ON public.notificaciones_mora;
CREATE POLICY "notif_write_admin" ON public.notificaciones_mora
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "super_admin_all" ON public.notificaciones_mora;
CREATE POLICY "super_admin_all" ON public.notificaciones_mora
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.op_log;
CREATE POLICY "lectura_select" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "op_log_insert" ON public.op_log;
CREATE POLICY "op_log_insert" ON public.op_log
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((actor_id = (SELECT auth.uid())) OR (actor_id IS NULL)) AND (NOT (SELECT is_lectura()))));

DROP POLICY IF EXISTS "op_log_read" ON public.op_log;
CREATE POLICY "op_log_read" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "op_log_read_admin_tickets" ON public.op_log;
CREATE POLICY "op_log_read_admin_tickets" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'admin_tickets'::text) AND (entidad = ANY (ARRAY['tickets'::text, 'ticket_tipos'::text, 'incidentes'::text]))));

DROP POLICY IF EXISTS "op_log_read_cobrador" ON public.op_log;
CREATE POLICY "op_log_read_cobrador" ON public.op_log
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (actor_id = (SELECT auth.uid()))));

DROP POLICY IF EXISTS "op_log_update" ON public.op_log;
CREATE POLICY "op_log_update" ON public.op_log
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((actor_id = (SELECT auth.uid())) OR (actor_id IS NULL)) AND (NOT (SELECT is_lectura()))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((actor_id = (SELECT auth.uid())) OR (actor_id IS NULL)) AND (NOT (SELECT is_lectura()))));

DROP POLICY IF EXISTS "super_admin_all" ON public.op_log;
CREATE POLICY "super_admin_all" ON public.op_log
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.pagos;
CREATE POLICY "lectura_select" ON public.pagos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "pagos_delete_admin" ON public.pagos;
CREATE POLICY "pagos_delete_admin" ON public.pagos
  FOR DELETE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin())));

DROP POLICY IF EXISTS "pagos_insert_propio" ON public.pagos;
CREATE POLICY "pagos_insert_propio" ON public.pagos
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid())) AND (EXISTS ( SELECT 1
   FROM cuotas
  WHERE ((cuotas.id = pagos.cuota_id) AND (cuotas.tenant_id = (SELECT current_tenant_id())))))))));

DROP POLICY IF EXISTS "pagos_read" ON public.pagos;
CREATE POLICY "pagos_read" ON public.pagos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "pagos_update" ON public.pagos;
CREATE POLICY "pagos_update" ON public.pagos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))));

DROP POLICY IF EXISTS "super_admin_all" ON public.pagos;
CREATE POLICY "super_admin_all" ON public.pagos
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));

DROP POLICY IF EXISTS "lectura_select" ON public.recibos;
CREATE POLICY "lectura_select" ON public.recibos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_lectura())));

DROP POLICY IF EXISTS "recibos_insert_propio" ON public.recibos;
CREATE POLICY "recibos_insert_propio" ON public.recibos
  FOR INSERT TO public
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT is_admin_or_cobranza()) OR (((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))));

DROP POLICY IF EXISTS "recibos_read" ON public.recibos;
CREATE POLICY "recibos_read" ON public.recibos
  FOR SELECT TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_personal_cobranza())));

DROP POLICY IF EXISTS "recibos_update_admins" ON public.recibos;
CREATE POLICY "recibos_update_admins" ON public.recibos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND (SELECT is_admin_or_cobranza())));

DROP POLICY IF EXISTS "recibos_update_impresion_cobrador" ON public.recibos;
CREATE POLICY "recibos_update_impresion_cobrador" ON public.recibos
  FOR UPDATE TO public
  USING (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))))
  WITH CHECK (((tenant_id = (SELECT current_tenant_id())) AND ((SELECT current_user_rol()) = 'cobrador'::text) AND (cobrador_id = (SELECT auth.uid()))));

DROP POLICY IF EXISTS "super_admin_all" ON public.recibos;
CREATE POLICY "super_admin_all" ON public.recibos
  FOR ALL TO public
  USING ((SELECT is_super_admin()))
  WITH CHECK ((SELECT is_super_admin()));
