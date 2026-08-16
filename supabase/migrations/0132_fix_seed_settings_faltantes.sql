-- 0132 — Fix: el seed de settings de tenants nuevos quedó desactualizado.
--
-- `tenants_seed_settings_trg()` (trigger AFTER INSERT en tenants) llama a
-- seed_settings_default/super_only/recibo_layout/ajustes. Varios settings se
-- agregaron DESPUÉS por migración (dias_cuotas_visibles 0113, cambio_fecha
-- 0119, colores_estados, audit.campos_visibles, recibo.mostrar_descuentos/
-- _motivo) con backfill a los tenants existentes, pero NUNCA se sumaron al
-- seed → los tenants NUEVOS nacen sin esas filas y, como el panel solo dibuja
-- las claves con fila, esas opciones no aparecen (ej. Telenet: 54 settings).
--
-- (1) Helper DRY con los 6 defaults canónicos (insert idempotente).
-- (2) Backfill a TODO tenant que las tenga faltantes.
-- (3) tenants_seed_settings_trg() ahora llama al helper → tenants futuros OK.

begin;

create or replace function public.seed_settings_faltantes_0132(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.dias_cuotas_visibles','5'::jsonb,'number','cobranza','Días de cuotas próximas (rango visible al cobrador)','admin'),
    ('cobranza.cambio_fecha_habilitado','false'::jsonb,'boolean','cobranza','Permite el cambio de fecha de pago por días (personal habilitado por el admin)','super_admin'),
    ('cobranza.colores_estados','{"mora":"#DC2626","gracia":"#CA8A04","hoy":"#2563EB","proxima":"#7C3AED"}'::jsonb,'json','cobranza',null,'admin'),
    ('audit.campos_visibles','{"clientes":["codigo","nombre","telefono","direccion","cedula","referencia","notas","activo","cobrador_id","comunidad_id"],"contratos":["codigo","estado","precio_mensual","dia_pago","fecha_inicio","fecha_fin","duracion_meses","documento_path","plan_id","cobrador_id"],"cuotas":["estado","monto","monto_pagado","periodo","fecha_vencimiento","tipo_cargo_manual","descripcion","cargos_neto"],"pagos":["fecha_pago","monto_cordobas","vuelto_cordobas","monto_original","moneda","tasa_conversion","metodo","referencia","notas","anulado"],"recibos":["numero_completo","anulado","reimpresiones"],"cargos_extra":["monto","tipo","descripcion"],"visitas":["estado","notas","resultado"],"fotos_cliente":["descripcion"],"planes":["nombre","tipo","precio_mensual","activo"]}'::jsonb,'json','cobranza',null,'admin'),
    ('recibo.mostrar_descuentos','true'::jsonb,'boolean','recibos',null,'admin'),
    ('recibo.mostrar_motivo_descuentos','true'::jsonb,'boolean','recibos',null,'admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- (2) Backfill a todos los tenants existentes (excepto el System)
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_faltantes_0132(t.id);
  end loop;
end $$;

-- (3) Seed para tenants FUTUROS: llamar al helper desde el trigger
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);   -- [0132] settings que el seed no insertaba
  -- [0113] dias_cuotas_visibles default 5 (red de seguridad por si otro seed lo metió como 30)
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  -- [0113] reglas/permisos sensibles → super_admin-only
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación (dentro de la transacción)
select 'telenet_total' as chk, count(*) as n from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578'
union all select 'telenet_dias_proxima', count(*) from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578' and clave='cobranza.dias_cuotas_visibles'
union all select 'telenet_cambio_fecha', count(*) from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578' and clave='cobranza.cambio_fecha_habilitado'
union all select 'tenants_sin_dias_proxima', count(*) from public.tenants t where t.id<>'00000000-0000-0000-0000-000000000000' and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.dias_cuotas_visibles')
union all select 'tenants_sin_cambio_fecha', count(*) from public.tenants t where t.id<>'00000000-0000-0000-0000-000000000000' and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.cambio_fecha_habilitado');

commit;
