-- 0139 — Cuerpo (borrador) de las plantillas del modo API de WhatsApp.
--
-- El modo API NO envía texto libre: Meta exige una plantilla aprobada y la app
-- manda el NOMBRE de la plantilla + los valores de las variables. Estos dos
-- settings guardan el CUERPO redactado en el editor visual de la app (chips +
-- preview), que sirve para COPIAR/PEGAR al crear la plantilla en Meta y queda de
-- referencia. NO es lo que se envía (eso es la plantilla aprobada en Meta).
--
-- Placeholders del editor (igual que el modo gratis): {nombre} {monto} {dias}
-- {empresa}. El botón "Copiar para Meta" los convierte a variables CON NOMBRE de
-- Meta: {{nombre}} {{monto}} {{dias}} {{empresa}} (el edge function manda los
-- parámetros por nombre → sin problema de orden). Defaults = mismos textos que
-- los avisos gratis (kAvisoMsg* en settings_repo.dart).

begin;

create or replace function public.seed_settings_whatsapp_api_body_0139(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_api_body_gracia',
     to_jsonb('Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text),
     'string','cobranza','Cuerpo redactado de la plantilla de gracia (borrador para crear/pegar en Meta; no es lo que se envía)','super_admin'),
    ('cobranza.notif_api_body_mora',
     to_jsonb('Hola {nombre}, su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text),
     'string','cobranza','Cuerpo redactado de la plantilla de mora (borrador para crear/pegar en Meta; no es lo que se envía)','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_whatsapp_api_body_0139(t.id);
  end loop;
end $$;

-- Trigger de seed: preservar el cuerpo exacto + agregar la nueva llamada.
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
  perform public.seed_settings_notif_0135(new.id);
  perform public.seed_settings_whatsapp_api_0137(new.id);   -- [0137]
  perform public.seed_settings_whatsapp_api_body_0139(new.id);   -- [0139]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

select 'tenants_sin_body' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.notif_api_body_gracia');

commit;
