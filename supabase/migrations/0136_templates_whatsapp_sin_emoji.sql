-- 0136 — Plantillas de WhatsApp sin emoji (solo texto).
--
-- Rubén pidió sacar el 👋 de las plantillas por defecto. Toca dos cosas:
--   1. UPDATE de las filas YA sembradas (0135) que siguen en el default viejo
--      (con emoji) → nuevo texto sin emoji. El WHERE compara contra el default
--      viejo EXACTO → si un admin ya editó su mensaje, NO se toca (preserva).
--   2. CREATE OR REPLACE del seeder seed_settings_notif_0135 con el texto sin
--      emoji, para los tenants futuros.
--
-- OJO: settings.valor es TEXT (guarda el JSON como texto, ej. `"Hola..."` con
-- comillas). Para comparar usamos `valor::jsonb = to_jsonb(<texto>)` (jsonb=jsonb).
-- El SET con to_jsonb(...) auto-castea jsonb→text al asignar (igual que 0135).

begin;

-- 1) Actualizar las filas un-customizadas (siguen en el default con emoji).
update public.settings
   set valor = to_jsonb('Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text)
 where clave = 'cobranza.aviso_msg_gracia'
   and valor::jsonb = to_jsonb('Hola {nombre} 👋 Le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text);

update public.settings
   set valor = to_jsonb('Hola {nombre}, su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text)
 where clave = 'cobranza.aviso_msg_mora'
   and valor::jsonb = to_jsonb('Hola {nombre} 👋 Su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text);

-- 2) Tenants futuros: el seeder con el texto sin emoji.
create or replace function public.seed_settings_notif_0135(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_whatsapp_habilitado','false'::jsonb,'boolean','cobranza',
     'Habilita el botón "WhatsApp" en la pantalla Avisos para notificar a los clientes','super_admin'),
    ('cobranza.aviso_msg_gracia',
     to_jsonb('Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. Para evitar la suspensión del servicio, realice su pago en los próximos {dias} días. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes próximos a corte (en gracia). Placeholders: {nombre} {monto} {dias} {empresa}','admin'),
    ('cobranza.aviso_msg_mora',
     to_jsonb('Hola {nombre}, su servicio fue suspendido por falta de pago (saldo vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a pagar o contáctenos. Gracias — {empresa}'::text),
     'string','cobranza',
     'Mensaje de WhatsApp para clientes en mora (corte). Placeholders: {nombre} {monto} {dias} {empresa}','admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Verificación dentro de la transacción.
select 'con_emoji_restantes' as chk, count(*) as n
  from public.settings
 where clave in ('cobranza.aviso_msg_gracia','cobranza.aviso_msg_mora')
   and valor like '%👋%';

commit;
