-- 0181 — Revocación de acceso real (audit F0, titular CRÍTICO+ALTO).
--
-- HOY "Desactivar" un cobrador (cobradores.activo=false) es cosmético: no corta
-- login (auth intacto), ni sync (sync-rules no filtra activo), ni cobro. Y no
-- existe forma de suspender un tenant que deja de pagar. Esta migración da el
-- lado SERVER del fix v1:
--   (1) tenants.activo — para suspender/reactivar un ISP completo.
--   (2) verificar_acceso() — gate que la app llama al iniciar sesión: si el
--       cobrador o su tenant están inactivos, la app cierra sesión. El super_admin
--       queda SIEMPRE exento (no hay forma de que el dueño se deje afuera).
--   (3) set_tenant_activo() — suspender/reactivar un tenant (solo super_admin).
--   (4) list_tenants_admin() ahora devuelve `activo` (para el toggle del panel).
-- El corte de SYNC del cobrador se hace en sync-rules (AND activo=true en los 6
-- buckets por-cobrador); esta migración es lo de Postgres. El client agrega el
-- gate en el arranque de sesión (fail-open ante error de red).

-- (1) Columna: todos los tenants vivos nacen activos.
ALTER TABLE public.tenants
  ADD COLUMN IF NOT EXISTS activo boolean NOT NULL DEFAULT true;

-- (2) Gate de acceso del usuario actual. SECURITY DEFINER: lee SOLO su propia
-- fila (WHERE id = auth.uid()). El super_admin es SIEMPRE activo. Sin fila →
-- no devuelve nada → el client hace fail-open (no bloquea ante anomalía/red).
CREATE OR REPLACE FUNCTION public.verificar_acceso()
 RETURNS TABLE(cobrador_activo boolean, tenant_activo boolean)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    CASE WHEN c.rol = 'super_admin' THEN true ELSE COALESCE(c.activo, false) END,
    CASE WHEN c.rol = 'super_admin' THEN true ELSE COALESCE(t.activo, true) END
  FROM public.cobradores c
  LEFT JOIN public.tenants t ON t.id = c.tenant_id
  WHERE c.id = auth.uid();
$function$;

REVOKE ALL ON FUNCTION public.verificar_acceso() FROM public;
GRANT EXECUTE ON FUNCTION public.verificar_acceso() TO authenticated;

-- (3) Suspender / reactivar un tenant (solo super_admin; System protegido).
CREATE OR REPLACE FUNCTION public.set_tenant_activo(p_tenant_id uuid, p_activo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_tenant_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'No se puede suspender el tenant System';
  END IF;
  UPDATE public.tenants SET activo = p_activo WHERE id = p_tenant_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_tenant_activo(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_tenant_activo(uuid, boolean) TO authenticated;

-- (4) list_tenants_admin ahora expone `activo` (cambia el return type → DROP+CREATE).
DROP FUNCTION IF EXISTS public.list_tenants_admin();
CREATE FUNCTION public.list_tenants_admin()
returns table (
  id                  uuid,
  nombre              text,
  activo              boolean,
  created_at          timestamptz,
  cobradores_count    bigint,
  modulos_habilitados text[]
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      t.id,
      t.nombre,
      t.activo,
      t.created_at,
      (select count(*) from public.cobradores c
         where c.tenant_id = t.id and c.activo) as cobradores_count,
      coalesce(
        (select array_agg(tm.modulo_codigo order by tm.modulo_codigo)
           from public.tenant_modulos tm
          where tm.tenant_id = t.id and tm.habilitado),
        array[]::text[]
      ) as modulos_habilitados
    from public.tenants t
    where t.id <> '00000000-0000-0000-0000-000000000000'
    order by t.created_at desc;
end;
$$;

revoke all on function public.list_tenants_admin() from public;
grant execute on function public.list_tenants_admin() to authenticated;
