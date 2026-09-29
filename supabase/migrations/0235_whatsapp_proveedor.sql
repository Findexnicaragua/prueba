-- 0235 — Proveedor del envío automático por WhatsApp: Meta directo | WhatChimp.
--
-- Por qué: el envío automático (modo API, 0137) siempre asumió la Cloud API de
-- Meta. Se suma WhatChimp como segundo camino — misma Cloud API por abajo, pero
-- con panel, bandeja y un asistente de alta que hace el trámite más llevadero.
-- La elección es POR TENANT: cada ISP puede ir por donde le convenga.
--
-- Qué cambia y qué NO:
--   · Cambia SOLO cómo se arma el pedido de salida (URL, auth y variables) en la
--     edge function `whatsapp-enviar`.
--   · NO cambia a quién se le avisa (`whatsapp_clientes_a_notificar`), ni la
--     frecuencia, ni el tope, ni el log (`whatsapp_envios`). Todo eso es
--     agnóstico del proveedor y se comparte.
--
-- Diferencia que obliga a bifurcar (verificada en la doc de WhatChimp, feb 2026):
--   · Meta      → POST graph.facebook.com/<v>/<phoneId>/messages, Bearer en el
--                 header, variables CON NOMBRE ({{nombre}}, {{monto}}…).
--   · WhatChimp → POST app.whatchimp.com/api/v1/whatsapp/send, apiToken como
--                 parámetro, variables POSICIONALES ({{1}}, {{2}}…) y el éxito
--                 se lee de `status: "1"` en el body, no del código HTTP.
-- Por eso la plantilla NO es intercambiable entre proveedores: hay que cargarla
-- del lado del proveedor elegido y escribirla con SU forma de variable.
--
-- El token sigue viviendo en `whatsapp_credenciales` (server-only, RLS sin
-- policies, fuera de las sync rules) — para WhatChimp esa misma columna guarda
-- el apiToken. Un tenant usa un proveedor a la vez, así que no hace falta
-- columna nueva.

begin;

-- ── Setting nuevo: por dónde sale el aviso ──────────────────────────────────
create or replace function public.seed_settings_whatsapp_proveedor_0235(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_api_proveedor', to_jsonb('meta'::text), 'string', 'cobranza',
     'Por dónde salen los avisos automáticos: meta (Cloud API directa) | whatchimp',
     'super_admin')
  ) as v(clave, valor, tipo, categoria, descripcion, editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id = p_tenant and s.clave = v.clave
  );
end;
$fn$;

-- Backfill a los tenants que ya existen (el System no lleva settings de tenant).
do $$
declare t record;
begin
  for t in select id from public.tenants
           where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_whatsapp_proveedor_0235(t.id);
  end loop;
end $$;

-- ── Tenants futuros ─────────────────────────────────────────────────────────
-- OJO: este cuerpo parte de la ÚLTIMA definición vigente (0177), NO de 0137.
-- Reescribirlo desde una versión vieja borra los `perform` intermedios y los
-- tenants nuevos nacen sin esos settings — pasó en 0151 y lo repuso 0152.
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
  perform public.seed_settings_notif_0135(new.id);                -- [0135]
  perform public.seed_settings_whatsapp_api_0137(new.id);         -- [0137]
  perform public.seed_settings_whatsapp_api_body_0139(new.id);    -- [0139]
  perform public.seed_settings_reportes_0141(new.id);             -- [0141]
  perform public.seed_settings_busqueda_0145(new.id);             -- [0145]
  perform public.seed_settings_cambio_plan_0151(new.id);          -- [0151]
  perform public.seed_settings_cobro_extra_0177(new.id);          -- [0177]
  perform public.seed_settings_whatsapp_proveedor_0235(new.id);   -- [0235]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

commit;

-- Verificación (correr aparte, después del commit):
--   select tenant_id, valor from public.settings
--    where clave = 'cobranza.notif_api_proveedor';
--   -- debe devolver una fila por tenant (menos System), todas con "meta".
