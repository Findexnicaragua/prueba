-- 0247 — Los gates de `sync_rechazos` dejan de fallar ABIERTO con NULL.
--
-- Audit del fix 0246 (2026-08-21). SQL tiene lógica de TRES valores y
-- `if not <expr>` NO entra cuando <expr> es NULL: el guard se saltea en
-- silencio y la ejecución sigue como si estuviera autorizada. Dos casos
-- reales, los dos verificados en producción evaluando las expresiones:
--
-- #1 (regresión introducida por 0246 §B1) `sync_rechazo_descartar` contra una
--    fila HUÉRFANA (`tenant_id` NULL) llamada por un admin/admin_cobranza:
--      NULL = v_tenant                      → NULL
--      (NULL is null and is_super_admin())  → (true and false) → false
--      NULL or false                        → NULL
--      not NULL                             → NULL  → NO corta → cae al UPDATE
--    O sea: un admin de cualquier ISP podía apagar el aviso de un cobro
--    huérfano, que es justo la clase de fila que 0246 §A6 reservó al
--    super_admin. La RPC es SECURITY DEFINER, así que la policy no lo frena.
--
-- #2 (preexistente de 0237, que 0246 reescribió sin cerrar)
--    `sync_rechazo_autorizado()` devuelve NULL —no false— para cualquier JWT
--    sin fila en `cobradores` (incluido `anon`): `current_tenant_id()` es NULL
--    → `p_tenant = NULL` → NULL. En `sync_rechazos_pendientes()` no hace daño
--    (está en un WHERE, donde NULL se comporta como false), pero
--    `sync_rechazo_registrar()` (cuerpo vigente 0240) la usa como
--    `if not public.sync_rechazo_autorizado(...)` → NULL → guard salteado →
--    sigue e INSERTA en `pagos`, `recibos` y `op_log`.
--    Hoy no hay exposición viva (0 filas con tenant NULL, 0 rechazos sin
--    resolver, y anon no puede enumerar ids: todas las lecturas le devuelven
--    0 filas), pero un gate que falla abierto no se deja pasar.
--
-- Regla para el futuro: **todo gate booleano que se consuma con `if not …`
-- tiene que ser TOTAL** — `coalesce(<expr>, false)` — o compararse con
-- `is not true`. Nunca dejar que un NULL decida un permiso.

begin;

-- ── #2 — el gate compartido se vuelve TOTAL ────────────────────────────────
-- Mismo criterio que 0246 (tenant anclado + rol relajado + huérfano para el
-- super_admin); lo único que cambia es que ahora NUNCA devuelve NULL.
-- Cierra de una sola vez a sus 3 consumidores: sync_rechazos_pendientes()
-- (la lista), sync_rechazo_registrar() (0240) y el UPDATE del recibo hermano.
create or replace function public.sync_rechazo_autorizado(p_tenant uuid)
returns boolean language sql stable security definer
set search_path to 'public'
as $fn$
  select coalesce(
    -- La fila es de la empresa en contexto y el rol alcanza.
    (p_tenant is not null
     and p_tenant = public.current_tenant_id()
     and (coalesce(public.is_super_admin(), false)
          or coalesce(public.is_admin_or_cobranza(), false)))
    -- Huérfano: cuando el write se rechaza POR contexto de tenant, el
    -- connector escribe la fila con tenant_id NULL a propósito. Sin dueño
    -- posible → queda para el super_admin, el único que puede reconstruirla.
    or (p_tenant is null and coalesce(public.is_super_admin(), false)),
    false);
$fn$;

-- ── #1 — descartar delega el anclaje en el gate total (DRY) ────────────────
-- El bloque a mano de 0246 se reemplaza por la función de arriba: fila propia
-- → true · ajena → false · huérfana+super → true · huérfana+admin → **false**
-- (antes NULL). A esta altura el gate de permiso ya garantizó que
-- current_tenant_id() no es NULL y que el rol es válido.
create or replace function public.sync_rechazo_descartar(p_id uuid)
returns jsonb
language plpgsql volatile security definer
set search_path to 'public'
as $fn$
declare
  v_tenant uuid := public.current_tenant_id();
  v_fila public.sync_rechazos%rowtype;
begin
  if v_tenant is null
     or not coalesce(public.is_super_admin()
                     or public.is_admin_or_cobranza(), false) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso para descartar avisos');
  end if;

  select * into v_fila from public.sync_rechazos where id = p_id;
  if v_fila.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese aviso ya no existe.');
  end if;
  -- Anclaje ANTES del atajo de idempotencia (lo cazó la verificación en vivo
  -- de 0246): con el orden invertido, un aviso AJENO ya resuelto contestaba
  -- "listo, ya estaba" en vez de "es de otra empresa".
  if not public.sync_rechazo_autorizado(v_fila.tenant_id) then
    return jsonb_build_object('ok', false,
      'error', 'Ese aviso es de otra empresa. Entrá a esa empresa para resolverlo.');
  end if;
  if v_fila.resuelto then
    return jsonb_build_object('ok', true, 'ya_estaba', true);
  end if;

  update public.sync_rechazos
     set resuelto = true, resuelto_en = now(), resuelto_por = auth.uid()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $fn$;

-- ── Higiene de grants (convención 0245) ────────────────────────────────────
-- Los default privileges de Supabase otorgan EXECUTE a anon/authenticated/
-- service_role al CREAR cualquier función, y `revoke ... from public` NO los
-- toca. Todas estas fallan cerradas por su gate interno, pero no hay motivo
-- para que anon las pueda invocar.
revoke all on function public.sync_rechazo_registrar(uuid) from anon, service_role;
revoke all on function public.sync_rechazos_pendientes() from anon, service_role;
revoke all on function public.sync_rechazo_autorizado(uuid) from anon, service_role;
revoke all on function public.recibos_huecos() from anon, service_role;
revoke all on function public.recibos_hueco_ignorar(text,int,int,text) from anon, service_role;
revoke all on function public.log_cobertura(int) from anon, service_role;

grant execute on function public.sync_rechazo_registrar(uuid) to authenticated;
grant execute on function public.sync_rechazos_pendientes() to authenticated;
grant execute on function public.sync_rechazo_autorizado(uuid) to authenticated;
grant execute on function public.recibos_huecos() to authenticated;
grant execute on function public.recibos_hueco_ignorar(text,int,int,text) to authenticated;
grant execute on function public.log_cobertura(int) to authenticated;

commit;
