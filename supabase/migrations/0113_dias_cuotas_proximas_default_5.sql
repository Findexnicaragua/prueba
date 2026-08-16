-- 0113_dias_cuotas_proximas_default_5.sql
--
-- "Días de cuotas próximas" (setting `cobranza.dias_cuotas_visibles`) = rango,
-- en días a partir de hoy, dentro del cual una cuota futura se considera
-- "próxima a pagar" y se muestra al cobrador (mapa + lista "Por cobrar"). Las
-- que vencen más allá del rango quedan FUERA (el cobrador no las ve; en el
-- detalle del contrato salen en gris "no disponible").
--
-- El default histórico del seed era 30; pasa a 5 para TODOS los tenants
-- (existentes y nuevos) — decisión de Rubén ("por defecto siempre 5").
--
-- También marca como super_admin-only (`editable_por`) las 4 reglas/permisos de
-- cobro sensibles que la UI movió a la tab Avanzado (pago_parcial,
-- pago_adelantado, cobrador_anula_cobros, cobrador_edita_cobros) — para que la
-- RLS los proteja igual que el resto de los settings super-only (consistencia
-- DB ↔ UI; antes quedaban editables por el admin vía API directa).
--
-- Sin cambios de schema/columnas → NO requiere bump de _schemaVersion ni
-- redeploy de sync rules (la tabla `settings` ya sincroniza por SELECT *).
-- Idempotente: se puede correr más de una vez sin efectos colaterales.

-- (1) Tenants EXISTENTES → 5 en TODOS. `DO UPDATE` fuerza 5 incluso donde había
--     el viejo default 30 (Rubén: "todos a 5"). Inserta la fila donde falte.
insert into public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
select id, 'cobranza.dias_cuotas_visibles', '5'::jsonb, 'number', 'cobranza',
       'Días de cuotas próximas (rango visible al cobrador)', 'admin'
from public.tenants
on conflict (tenant_id, clave) do update set valor = '5'::jsonb;

-- (2) `dias_gracia` = 10 donde FALTE (defensivo, tenants muy viejos). `DO
--     NOTHING` no pisa la configuración de los que ya la tienen.
insert into public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
select id, 'cobranza.dias_gracia', '10'::jsonb, 'number', 'cobranza',
       'Días entre vencimiento y notificación de mora', 'admin'
from public.tenants
on conflict (tenant_id, clave) do nothing;

-- (2b) Reglas/permisos sensibles → super_admin-only en tenants EXISTENTES
--      (consistencia con la UI, que los muestra solo en la tab Avanzado). NO
--      cambia el `valor`; solo `editable_por`, para que la RLS settings_write_admin
--      (que bloquea editable_por='super_admin') los proteja.
update public.settings set editable_por = 'super_admin'
  where clave in ('cobranza.pago_parcial', 'cobranza.pago_adelantado',
                  'cobranza.cobrador_anula_cobros',
                  'cobranza.cobrador_edita_cobros');

-- (3) Tenants NUEVOS: el trigger de alta siembra 30 vía `seed_settings_default`.
--     En vez de recrear esa función entera (riesgo de perder alguna clave),
--     agregamos un paso final al trigger que normaliza el valor a 5. Se mantiene
--     idéntico al cuerpo vigente (0090) + el UPDATE.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  -- Default nuevo: 5 días de cuotas próximas (el seed aún inserta 30; se
  -- normaliza acá para no recrear la función completa).
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  -- Reglas/permisos sensibles → super_admin-only (el seed los crea como 'admin';
  -- la UI los muestra solo en Avanzado, así que la RLS debe acompañar).
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial', 'cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros',
                    'cobranza.cobrador_edita_cobros');
  return new;
end;
$$;
