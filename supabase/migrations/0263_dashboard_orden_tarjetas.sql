-- 0263 — El ORDEN y el encendido de las tarjetas del Resumen, por tenant
--
-- Pedido de Rubén (2026-08-29): poder habilitar, deshabilitar y mover las
-- tarjetas del dashboard desde los ajustes avanzados (super_admin), por
-- empresa.
--
-- UN SOLO setting con la lista completa, en vez de una clave por tarjeta.
-- Por qué:
--
--   · El ORDEN no se puede expresar con toggles sueltos. Hoy vive escrito a
--     mano en `dashboard_admin_screen.dart` y cambiarlo es tocar código.
--   · Una tarjeta nueva no necesita ni clave nueva ni migración: si no está en
--     la lista, el cliente la agrega al final ENCENDIDA. Ese fallback es lo que
--     evita el modo de falla clásico —una tarjeta que desaparece porque el
--     ajuste guardado es viejo y no la nombra.
--   · Los toggles viejos (`dashboard.cobros_visible`, `proyeccion_visible`,
--     `recuperacion_visible`, `sparkline_visible`, `operativo_visible`,
--     `top_cobradores_visible`, `distribucion_visible`) quedan OBSOLETOS. Tres
--     de ellos ya no hacían nada: sus getters se retiraron el 2026-08-28 al
--     encender las tarjetas, y la pantalla de Ajustes los seguía ofreciendo.
--     Un interruptor que no mueve nada es peor que no tenerlo.
--
-- NO toca `schema.dart` ni las sync rules: `settings` ya sincroniza con
-- `SELECT *`, así que una clave nueva viaja sola (verificado con
-- `tools/impacto.py settings`).
--
-- El valor es un ARRAY JSON, en orden de arriba hacia abajo:
--   [{"id":"caja","on":true}, {"id":"cobertura","on":true}, ...]
-- Los `id` son los de `TarjetaResumen` en `dashboard_tarjetas.dart`. Un `id`
-- que el cliente no conoce se ignora (una tarjeta que se retiró del código no
-- rompe la pantalla de nadie).

begin;

-- ── El orden por defecto: el que Rubén eligió al trabajarlas una por una ────
create or replace function public.seed_settings_dashboard_orden_0263(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('dashboard.tarjetas',
     '[{"id":"caja","on":true},
       {"id":"cobertura","on":true},
       {"id":"mora_ciclo","on":true},
       {"id":"proyeccion","on":true},
       {"id":"mora_zona","on":true},
       {"id":"quien_cobro","on":true},
       {"id":"recaudo_mora","on":false},
       {"id":"consultar_periodo","on":false},
       {"id":"sparkline","on":false},
       {"id":"operativo","on":false},
       {"id":"distribucion","on":false}]'::jsonb,
     'json', 'dashboard',
     'Orden y encendido de las tarjetas del Resumen. Se edita en Ajustes → Avanzado → Tarjetas del Resumen.',
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
    perform public.seed_settings_dashboard_orden_0263(t.id);
  end loop;
end $$;

-- ── Tenants futuros ─────────────────────────────────────────────────────────
-- OJO (lección de 0151→0152): este cuerpo se reescribe COMPLETO en cada
-- migración que lo toca, así que hay que partir de la ÚLTIMA definición vigente
-- —la de 0235— y agregarle la línea nueva. Reescribirlo desde una versión vieja
-- BORRA los `perform` intermedios y los tenants nuevos nacen sin esos settings,
-- sin que nada avise.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql security definer set search_path = public as $fn$
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
  perform public.seed_settings_dashboard_orden_0263(new.id);      -- [0263]
  return new;
end;
$fn$;

commit;
