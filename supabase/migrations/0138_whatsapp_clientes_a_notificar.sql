-- 0138 — Función que devuelve los clientes a notificar por WhatsApp (modo API).
--
-- La usa la edge function `whatsapp-enviar` (modo lote) + el cron. Centraliza la
-- lógica en Postgres (testeable por SQL): clientes con deuda VENCIDA (gracia o
-- mora), con teléfono, que NO fueron notificados dentro de la ventana de la
-- frecuencia configurada, hasta el tope diario. Un cliente se clasifica por su
-- cuota MÁS VIEJA impaga (igual que la pantalla Avisos): mora si pasó la gracia,
-- gracia si todavía está dentro.
--
-- `dias`: para gracia = cuántos faltan para el corte; para mora = hace cuántos.
-- `monto`: total VENCIDO del cliente (Σ saldo canónico de cuotas pasadas de fecha).
-- settings.valor es TEXT-JSON → se extrae con `::jsonb #>> '{}'` (escalar sin comillas).

begin;

create or replace function public.whatsapp_clientes_a_notificar(p_tenant uuid)
returns table (
  cliente_id uuid,
  nombre text,
  telefono text,
  estado text,
  monto numeric,
  dias int
) language plpgsql stable as $fn$
declare
  v_hoy date := (now() at time zone 'America/Managua')::date;
  v_gracia int;
  v_freq text;
  v_tope int;
begin
  select coalesce((s.valor::jsonb #>> '{}')::int, 10) into v_gracia
    from public.settings s where s.tenant_id=p_tenant and s.clave='cobranza.dias_gracia';
  v_gracia := coalesce(v_gracia, 10);
  select coalesce(s.valor::jsonb #>> '{}', 'semanal') into v_freq
    from public.settings s where s.tenant_id=p_tenant and s.clave='cobranza.notif_api_frecuencia';
  v_freq := coalesce(v_freq, 'semanal');
  select coalesce((s.valor::jsonb #>> '{}')::int, 200) into v_tope
    from public.settings s where s.tenant_id=p_tenant and s.clave='cobranza.notif_api_tope_diario';
  v_tope := coalesce(v_tope, 200);

  return query
  with deudas as (
    select cu.cliente_id as cid,
           min(cu.fecha_vencimiento) as peor,
           sum(greatest(cu.monto + coalesce(cu.cargos_neto,0) - coalesce(cu.monto_pagado,0), 0)) as saldo
      from public.cuotas cu
      join public.clientes c on c.id = cu.cliente_id and c.activo
      left join public.contratos ct on ct.id = cu.contrato_id
     where cu.tenant_id = p_tenant
       and coalesce(ct.estado,'activo') = 'activo'
       and cu.estado in ('pendiente','parcial')
       and cu.fecha_vencimiento < v_hoy
     group by cu.cliente_id
  ),
  clasificado as (
    select d.cid, d.peor, d.saldo,
           case when (d.peor + v_gracia) < v_hoy then 'mora' else 'gracia' end as est,
           case when (d.peor + v_gracia) < v_hoy
                then (v_hoy - d.peor) - v_gracia          -- mora: hace N días
                else v_gracia - (v_hoy - d.peor) end as d_dias  -- gracia: faltan N
      from deudas d
  )
  select cl.cid, c.nombre, c.telefono, cl.est, cl.saldo::numeric, cl.d_dias
    from clasificado cl
    join public.clientes c on c.id = cl.cid
   where c.telefono is not null and btrim(c.telefono) <> ''
     and not exists (
       select 1 from public.whatsapp_envios e
        where e.tenant_id = p_tenant and e.cliente_id = cl.cid and e.ok
          and case v_freq
                when 'diario'         then e.enviado_en::date >= v_hoy
                when 'cada_3'         then e.enviado_en > now() - interval '3 days'
                when 'semanal'        then e.enviado_en > now() - interval '7 days'
                when 'cada_15'        then e.enviado_en > now() - interval '15 days'
                when 'una_vez_estado' then e.estado = cl.est and e.enviado_en::date >= cl.peor
                else e.enviado_en::date >= v_hoy
              end
     )
   order by cl.peor asc
   limit v_tope;
end;
$fn$;

commit;
