-- 0242 — "Ignorar" huecos históricos del talonario (paquete bandeja humana).
--
-- Los saltos de numeración de la era de pruebas (SA 2-4, SA 17-43, HL 3 en
-- Mairena) no son plata y no tienen arreglo posible: van a aparecer en la
-- bandeja PARA SIEMPRE salvo que exista un descarte manual CON REGISTRO.
-- La tabla guarda quién ignoró qué rango y cuándo; recibos_huecos() excluye
-- los rangos ignorados. NO sincroniza a devices (se lee vía RPC definer):
-- no entra a la publicación powersync ni a las sync rules.

begin;

create table if not exists public.recibos_huecos_ignorados (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id),
  prefijo      text not null,
  desde        int  not null,
  hasta        int  not null,
  motivo       text,
  ignorado_por uuid references public.cobradores(id),
  ignorado_en  timestamptz not null default now(),
  constraint huecos_ign_rango check (hasta >= desde)
);

alter table public.recibos_huecos_ignorados enable row level security;

drop policy if exists super_admin_all on public.recibos_huecos_ignorados;
create policy super_admin_all on public.recibos_huecos_ignorados
  for all using (public.is_super_admin()) with check (public.is_super_admin());

drop policy if exists huecos_ign_admin_read on public.recibos_huecos_ignorados;
create policy huecos_ign_admin_read on public.recibos_huecos_ignorados
  for select using (tenant_id = public.current_tenant_id()
                    and public.is_admin_or_cobranza());

-- ── RPC: ignorar un hueco (queda el registro de quién y cuándo) ─────────────
create or replace function public.recibos_hueco_ignorar(
  p_prefijo text, p_desde int, p_hasta int, p_motivo text default null)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $fn$
declare
  v_tenant uuid;
begin
  -- super_admin impersonando también resuelve su tenant por current_tenant_id
  v_tenant := public.current_tenant_id();
  if v_tenant is null or not (public.is_super_admin() or public.is_admin_or_cobranza()) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso para descartar huecos');
  end if;
  if p_hasta < p_desde then
    return jsonb_build_object('ok', false, 'error', 'Rango inválido');
  end if;
  -- El rango debe ser un SALTO REAL del talonario del tenant ANCLADO: los
  -- vecinos desde-1 y hasta+1 existen y adentro no hay nada. Cierra dos
  -- agujeros (audit 2026-08-20): el super_admin impersonando NO puede
  -- registrar el ignore del hueco de OTRO tenant (ese rango no existe en el
  -- tenant anclado), y nadie puede suprimir la detección futura con un rango
  -- arbitrario tipo 1-999999.
  if exists (select 1 from public.recibos r
              where r.tenant_id = v_tenant and r.prefijo = p_prefijo
                and r.correlativo between p_desde and p_hasta)
     or not exists (select 1 from public.recibos r
              where r.tenant_id = v_tenant and r.prefijo = p_prefijo
                and r.correlativo = p_desde - 1)
     or not exists (select 1 from public.recibos r
              where r.tenant_id = v_tenant and r.prefijo = p_prefijo
                and r.correlativo = p_hasta + 1) then
    return jsonb_build_object('ok', false, 'error',
      'Ese rango no corresponde a un salto real del talonario de tu empresa.');
  end if;
  insert into public.recibos_huecos_ignorados
    (tenant_id, prefijo, desde, hasta, motivo, ignorado_por)
  values (v_tenant, p_prefijo, p_desde, p_hasta, p_motivo, auth.uid());
  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function public.recibos_hueco_ignorar(text,int,int,text) from public;
grant execute on function public.recibos_hueco_ignorar(text,int,int,text) to authenticated;

-- ── recibos_huecos(): cuerpo vigente de 0237 + exclusión de ignorados ───────
create or replace function public.recibos_huecos()
returns table (
  tenant text, prefijo text, cobrador text,
  desde int, hasta int, faltan int,
  ok_antes timestamptz, ok_despues timestamptz
)
language sql stable security definer
set search_path to 'public'
as $fn$
  with r as (
    select t.id as tenant_id, t.nombre as tenant, r.prefijo, r.correlativo,
           r.created_at,
           (r.created_at::time <> '00:00:00') as real_now,
           lag(r.correlativo) over w as prev_corr,
           lag(r.created_at)  over w as prev_at,
           lag(r.cobrador_id) over w as prev_cob,
           lag(r.created_at::time <> '00:00:00') over w as prev_real
    from public.recibos r
    join public.tenants t on t.id = r.tenant_id
    window w as (partition by r.tenant_id, r.prefijo order by r.correlativo)
  )
  select r.tenant, r.prefijo, coalesce(co.nombre, '?'),
         r.prev_corr + 1, r.correlativo - 1, (r.correlativo - r.prev_corr - 1),
         r.prev_at, r.created_at
  from r left join public.cobradores co on co.id = r.prev_cob
  where r.correlativo - r.prev_corr > 1
    and r.real_now and r.prev_real
    -- Rango ignorado (descartado a mano, con registro): no se lista más.
    and not exists (
      select 1 from public.recibos_huecos_ignorados i
       where i.tenant_id = r.tenant_id and i.prefijo = r.prefijo
         and (r.prev_corr + 1) >= i.desde and (r.correlativo - 1) <= i.hasta
    )
    and (public.is_super_admin()
         or (r.tenant_id = public.current_tenant_id()
             and public.is_admin_or_cobranza()))
  order by (r.correlativo - r.prev_corr - 1) desc, r.tenant, r.prefijo;
$fn$;

commit;
