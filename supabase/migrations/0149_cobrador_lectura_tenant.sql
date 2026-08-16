-- 0149 — Cobrador con lectura de TODO el tenant (#4).
--
-- Decisión de producto: los cobradores comparten las vistas de Cobros / Mapa /
-- Clientes con los admins y ven TODOS los clientes del tenant (no solo su ruta
-- asignada). Su ruta sigue siendo su foco operativo, pero pueden ver — y cobrar —
-- a cualquier cliente. Lo ÚNICO que NO pueden es EDITAR información (clientes/
-- contratos/cuotas siguen siendo write = admin/admin_cobranza), igual que hoy.
--
-- Esta migración SOLO relaja la LECTURA (SELECT) del cobrador a tenant-wide.
-- Es segura por sí sola: PowerSync replica respetando RLS, así que mientras el
-- bucket `por_cobrador` siga bajando solo su slice, el comportamiento no cambia.
-- La VISIBILIDAD real se activa cuando se deployan las sync rules tenant-wide
-- (powersync/sync-rules.yaml) — ese es el paso manual de Rubén en PowerSync.
--
-- Escritura: SIN cambios. pagos_insert_propio ya permite que el cobrador cobre
-- a CUALQUIER cuota auto-estampándose como cobrador_id = auth.uid() (invariante
-- #11, quién-cobró). Las cuotas las recalcula el trigger server desde pagos.

-- Helper: ¿es personal de cobranza (admin / admin_cobranza / cobrador)?
-- Son los roles que operan la cartera y ahora comparten la lectura completa.
-- El técnico y admin_tickets NO entran (no ven dinero; su acceso lo dan sus
-- propios buckets/políticas de tickets).
create or replace function public.is_personal_cobranza() returns boolean
language sql stable security definer
set search_path = public, pg_temp as $$
  select public.current_user_rol() in ('admin','admin_cobranza','cobrador')
$$;

-- clientes
drop policy "clientes_read" on public.clientes;
create policy "clientes_read" on public.clientes
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- contratos
drop policy "contratos_read" on public.contratos;
create policy "contratos_read" on public.contratos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- cuotas
drop policy "cuotas_read" on public.cuotas;
create policy "cuotas_read" on public.cuotas
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- pagos
drop policy "pagos_read" on public.pagos;
create policy "pagos_read" on public.pagos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- recibos
drop policy "recibos_read" on public.recibos;
create policy "recibos_read" on public.recibos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- cargos_extra
drop policy "cargos_read" on public.cargos_extra;
create policy "cargos_read" on public.cargos_extra
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );

-- notificaciones_mora (lectura; la marca de "vista" sigue como estaba)
drop policy "notif_read" on public.notificaciones_mora;
create policy "notif_read" on public.notificaciones_mora
  for select using (
    tenant_id = public.current_tenant_id() and public.is_personal_cobranza()
  );
