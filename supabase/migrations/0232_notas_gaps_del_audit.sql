-- 0232 — Dos huecos que dejó 0230, cazados por el audit adversarial
--
-- ── (A) EL EMPLEADO DADO DE BAJA SEGUÍA PUDIENDO ESCRIBIR ───────────────────
-- Las policies de 0230 pedían tenant + rol distinto de 'lectura', pero NO
-- miraban `cobradores.activo`. `current_user_rol()` devuelve el rol igual para
-- un usuario desactivado, así que alguien dado de baja en la app —mientras su
-- refresh token de Supabase siguiera vivo— podía reescribir por REST la nota de
-- cualquier cliente y de cualquier contrato del tenant. Antes de 0230 no tenía
-- NINGUNA policy de escritura, así que esto lo introdujo 0230.
--
-- ── (B) admin_usuarios VEÍA EL LÁPIZ Y LA NOTA NO SE GUARDABA ───────────────
-- 0230 le dio UPDATE sobre `contratos`, pero `contratos_read` es
-- `is_personal_cobranza()` (admin, admin_cobranza, cobrador) y NO lo cubre. El
-- connector sube el write como `.update(...).select('id')`, y ese RETURNING
-- necesita permiso de SELECT: sin él Postgres devuelve 0 filas y el UPDATE se
-- descarta.
--
-- El resultado era peor que "no funciona": el `op_log` viaja como una operación
-- APARTE contra otra tabla, cuya policy de INSERT sí lo deja pasar. O sea que
-- el historial del contrato mostraba «notas: (vacío) → "instalación con 40 m de
-- cable"», firmado y fechado, y el contrato no tenía esa nota. El historial
-- mintiendo es justo lo que este proyecto no se puede permitir.
--
-- Se resuelve con la lectura, no achicando el permiso: `admin_usuarios` YA
-- recibe `contratos` en su dispositivo por las sync rules (bucket
-- `todo_tenant_admin_usuarios`), así que la policy solo alinea el acceso REST
-- con lo que ese rol ya tiene local. No se agrega ningún dato nuevo a su vista.
--
-- NO se toca `tecnico` / `admin_tickets` / `coordinador`: 0230 les dio un UPDATE
-- que hoy es inefectivo (no tienen SELECT). Queda así a propósito — el router
-- los confina a sus propios shells y no llegan a la ficha del cliente ni a la
-- del contrato, así que abrirles la lectura sería ampliar acceso sin un caso de
-- uso. Si algún día se les da esa pantalla, hay que volver acá.

-- ── (A) ────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS clientes_write_notas ON public.clientes;
CREATE POLICY clientes_write_notas ON public.clientes
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura'
         AND EXISTS (SELECT 1 FROM public.cobradores cb
                      WHERE cb.id = auth.uid() AND cb.activo))
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura'
              AND EXISTS (SELECT 1 FROM public.cobradores cb
                           WHERE cb.id = auth.uid() AND cb.activo));

DROP POLICY IF EXISTS contratos_write_notas ON public.contratos;
CREATE POLICY contratos_write_notas ON public.contratos
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura'
         AND EXISTS (SELECT 1 FROM public.cobradores cb
                      WHERE cb.id = auth.uid() AND cb.activo))
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura'
              AND EXISTS (SELECT 1 FROM public.cobradores cb
                           WHERE cb.id = auth.uid() AND cb.activo));

-- ── (B) ────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS contratos_read_admin_usuarios ON public.contratos;
CREATE POLICY contratos_read_admin_usuarios ON public.contratos
  FOR SELECT
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() = 'admin_usuarios');

COMMENT ON POLICY contratos_read_admin_usuarios ON public.contratos IS
  'Alinea el acceso REST con lo que este rol ya recibe por sync rules (bucket '
  'todo_tenant_admin_usuarios). Sin esto, el RETURNING de su UPDATE de `notas` '
  'devolvía 0 filas y la nota se descartaba en silencio mientras el op_log sí '
  'registraba el cambio — historial mintiendo.';
