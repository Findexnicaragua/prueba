-- 0135 — Notificación por WhatsApp desde Avisos (Feature 4).
--
-- 3 settings nuevos:
--   1. cobranza.notif_whatsapp_habilitado (boolean, default FALSE, super_admin):
--      habilita los botones "WhatsApp" en la pantalla Avisos. Opt-in.
--   2. cobranza.aviso_msg_gracia (string, editable_por ADMIN): plantilla del
--      mensaje para clientes próximos a corte (en gracia).
--   3. cobranza.aviso_msg_mora (string, editable_por ADMIN): plantilla para
--      clientes en mora (corte).
-- Las plantillas usan placeholders {nombre} {monto} {dias} {empresa} que el
-- cliente rellena al armar el deep link wa.me. Editables por el admin (cada ISP
-- personaliza su texto) → editable_por='admin' (la RLS settings_write_admin lo
-- permite); el feature lo HABILITA el super_admin (toggle #1). categoria
-- 'cobranza': el toggle vive en Avanzado (super-only, kGruposAvanzado) y las
-- plantillas en la tab Cobranza (las edita el admin).

begin;

create or replace function public.seed_settings_notif_0135(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_whatsapp_habilitado','false'::jsonb,'boolean','cobranza',
     'Habilita el botón "WhatsApp" en la pantalla Avisos para notificar a los clientes','super_admin'),
    ('cobranza.aviso_msg_gracia',
     to_jsonb('Hola {nombre} 👋 Le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes próximos a corte (en gracia). Placeholders: {nombre} {monto} {dias} {empresa}','admin'),
    ('cobranza.aviso_msg_mora',
     to_jsonb('Hola {nombre} 👋 Su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes en mora (corte). Placeholders: {nombre} {monto} {dias} {empresa}','admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_notif_0135(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0134).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);   -- [0135]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación dentro de la transacción.
select 'tenants_sin_notif' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.notif_whatsapp_habilitado')
union all
select 'plantillas_admin_editables', count(*)
  from public.settings where clave in ('cobranza.aviso_msg_gracia','cobranza.aviso_msg_mora') and editable_por='admin'
union all
select 'toggle_super_only', count(*)
  from public.settings where clave='cobranza.notif_whatsapp_habilitado' and editable_por='super_admin';

commit;
