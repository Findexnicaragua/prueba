-- ============================================================================
-- Smoke test: valida que el backend está coherente tras correr migraciones.
-- Corré esto en Supabase Studio → SQL Editor después de las 22 migraciones.
--
-- NO requiere usuarios en auth.users — sólo verifica que el esquema,
-- funciones, triggers y policies estén correctamente definidos y que
-- la lógica de SQL funcione con datos sintéticos.
--
-- Si todo pasa, verás "✅ smoke test OK" al final.
-- Si algo falla, RAISE EXCEPTION corta el script en el primer error.
-- ============================================================================

do $$
declare
  v_count int;
  v_fecha date;
  v_dia_pago int;
begin
  raise notice '--- Test 1: extensiones requeridas ---';
  select count(*) into v_count from pg_extension where extname in ('pgcrypto','pg_cron');
  if v_count < 2 then
    raise exception 'Faltan extensiones pgcrypto y/o pg_cron';
  end if;
  raise notice 'OK';

  raise notice '--- Test 2: tablas críticas existen ---';
  for v_count in
    select count(*) from information_schema.tables
     where table_schema = 'public'
       and table_name in (
         'tenants','cobradores','planes','clientes','contratos','cuotas',
         'pagos','recibos','cargos_extra','settings','departamentos',
         'municipios','comunidades','notificaciones_mora','audit_log'
       )
  loop
    if v_count <> 15 then
      raise exception '%s/15 tablas críticas existen, faltan algunas', v_count;
    end if;
  end loop;
  raise notice 'OK (15/15)';

  raise notice '--- Test 3: funciones SQL principales ---';
  for v_count in
    select count(*) from information_schema.routines
     where routine_schema = 'public'
       and routine_name in (
         'current_tenant_id','current_user_rol','is_admin','is_admin_or_cobranza',
         'setting_number','calcular_fecha_pago','generar_cuotas_mes',
         'generar_cuotas_contrato','actualizar_notificaciones_mora',
         'cuota_total_a_cobrar','recalcular_cuota_desde_pagos',
         'seed_settings_default','audit_registrar'
       )
  loop
    if v_count < 13 then
      raise exception '%s/13 funciones existen, revisa migraciones', v_count;
    end if;
  end loop;
  raise notice 'OK';

  raise notice '--- Test 4: triggers críticos ---';
  -- Trigger de generación de cuotas al crear contrato
  select count(*) into v_count from information_schema.triggers
   where trigger_name = 'trg_contratos_generar_cuotas_iniciales';
  if v_count = 0 then
    raise exception 'Falta trigger trg_contratos_generar_cuotas_iniciales';
  end if;

  -- Trigger central de recálculo de cuota
  select count(*) into v_count from information_schema.triggers
   where trigger_name in (
     'trg_pagos_insert_recalcular',
     'trg_pagos_update_recalcular',
     'trg_pagos_delete_recalcular',
     'trg_cargos_extra_recalcular_cuota'
   );
  if v_count < 4 then
    raise exception 'Faltan triggers de recálculo (%/4)', v_count;
  end if;
  raise notice 'OK';

  raise notice '--- Test 5: calcular_fecha_pago — clamping y domingo→lunes ---';
  -- Día 31 en febrero (no bisiesto): debe clampar a 28.
  select calcular_fecha_pago('2025-02-01'::date, 31) into v_fecha;
  if v_fecha <> '2025-02-28'::date then
    raise exception 'calcular_fecha_pago(feb-2025, 31) = % (esperaba 2025-02-28)', v_fecha;
  end if;

  -- Día 29 en febrero bisiesto (2024): debe ser 29.
  select calcular_fecha_pago('2024-02-01'::date, 29) into v_fecha;
  if v_fecha <> '2024-02-29'::date then
    raise exception 'calcular_fecha_pago(feb-2024, 29) = % (esperaba 2024-02-29)', v_fecha;
  end if;

  -- Día que cae en domingo debe saltar a lunes.
  -- 2025-06-01 (domingo, día 1). Con dia_pago=1 → debería ser 2025-06-02 (lunes).
  select calcular_fecha_pago('2025-06-01'::date, 1) into v_fecha;
  if extract(dow from v_fecha) = 0 then
    raise exception 'calcular_fecha_pago no saltó domingo → %', v_fecha;
  end if;
  raise notice 'OK';

  raise notice '--- Test 6: cuota_total_a_cobrar sin cargos ---';
  -- Creamos un tenant ficticio temporal con datos sintéticos para testear
  -- la función cuota_total_a_cobrar.
  declare
    v_tenant uuid;
    v_plan uuid;
    v_cli uuid;
    v_con uuid;
    v_cuo uuid;
    v_total numeric;
  begin
    insert into public.tenants (nombre) values ('SMOKE_TEST') returning id into v_tenant;
    insert into public.planes (tenant_id, nombre, tipo, precio_mensual)
      values (v_tenant, 'Plan smoke', 'internet', 1000) returning id into v_plan;
    -- Cliente sin cobrador (no impacta para esta prueba).
    insert into public.clientes (tenant_id, nombre)
      values (v_tenant, 'Cliente Smoke') returning id into v_cli;
    -- Contrato directo en BD (bypassa trigger generar cuotas usando dia_pago_check
    -- válido y fecha_inicio en el pasado para que se generen cuotas).
    insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
      values (v_tenant, v_cli, v_plan, 15, current_date - interval '1 month')
      returning id into v_con;

    -- El trigger generó cuotas. Buscamos la más vieja.
    select id into v_cuo from public.cuotas
      where contrato_id = v_con order by periodo limit 1;
    if v_cuo is null then
      raise exception 'Trigger generar_cuotas_contrato no generó cuotas';
    end if;

    -- Total a cobrar sin cargos extra = monto cuota.
    select cuota_total_a_cobrar(v_cuo) into v_total;
    if v_total <> 1000 then
      raise exception 'cuota_total_a_cobrar sin cargos = % (esperaba 1000)', v_total;
    end if;

    -- Aplicar descuento de 200 → total = 800.
    insert into public.cargos_extra (tenant_id, cuota_id, cobrador_id, tipo, monto, aplicado_por)
      values (v_tenant, v_cuo, v_cli, 'descuento_monto', 200, v_cli);
    select cuota_total_a_cobrar(v_cuo) into v_total;
    if v_total <> 800 then
      raise exception 'cuota_total_a_cobrar con descuento 200 = % (esperaba 800)', v_total;
    end if;

    -- Aplicar reconexión de 150 → total = 800 + 150 = 950.
    insert into public.cargos_extra (tenant_id, cuota_id, cobrador_id, tipo, monto, aplicado_por)
      values (v_tenant, v_cuo, v_cli, 'reconexion', 150, v_cli);
    select cuota_total_a_cobrar(v_cuo) into v_total;
    if v_total <> 950 then
      raise exception 'cuota_total_a_cobrar con desc+reconex = % (esperaba 950)', v_total;
    end if;

    raise notice 'OK (cuota=1000 → con desc=800 → con desc+reconex=950)';

    -- Cleanup
    delete from public.cuotas where contrato_id = v_con;
    delete from public.contratos where id = v_con;
    delete from public.clientes where id = v_cli;
    delete from public.planes where id = v_plan;
    delete from public.settings where tenant_id = v_tenant;
    delete from public.tenants where id = v_tenant;
  end;

  raise notice '--- Test 7: settings se siembran por trigger AFTER INSERT en tenants ---';
  declare
    v_tenant uuid;
    v_settings_count int;
  begin
    insert into public.tenants (nombre) values ('SMOKE_TEST_SETTINGS')
      returning id into v_tenant;
    select count(*) into v_settings_count from public.settings where tenant_id = v_tenant;
    if v_settings_count < 15 then
      raise exception 'Settings no sembrados al crear tenant (%/15+)', v_settings_count;
    end if;
    raise notice 'OK (% settings sembrados)', v_settings_count;
    delete from public.settings where tenant_id = v_tenant;
    delete from public.tenants where id = v_tenant;
  end;

  raise notice '--- Test 8: cron jobs registrados ---';
  select count(*) into v_count from cron.job
   where jobname in ('generar_cuotas_mensual', 'actualizar_notificaciones_mora_diario');
  if v_count < 2 then
    raise exception 'Cron jobs faltantes (%/2)', v_count;
  end if;
  raise notice 'OK';

  raise notice '--- Test 9: políticas RLS críticas presentes ---';
  select count(*) into v_count from pg_policies
   where schemaname = 'public'
     and tablename in ('clientes','contratos','cuotas','pagos','recibos',
                       'cargos_extra','notificaciones_mora','settings',
                       'cobradores','planes','audit_log');
  if v_count < 20 then
    raise exception 'Pocas políticas RLS (%/20+). Revisa migraciones 0013/0017/0022', v_count;
  end if;
  raise notice 'OK (% políticas activas)', v_count;

  raise notice '--- Test 10: storage buckets configurados ---';
  select count(*) into v_count from storage.buckets
   where id in ('fotos-clientes', 'comprobantes-pago', 'logos-empresa');
  if v_count < 3 then
    raise exception 'Storage buckets faltantes (%/3)', v_count;
  end if;
  raise notice 'OK';

  raise notice '--- Test 11: trigger handle_new_user existe ---';
  select count(*) into v_count from information_schema.triggers
   where trigger_name = 'on_auth_user_created'
     and event_object_schema = 'auth';
  if v_count = 0 then
    raise exception 'Falta trigger on_auth_user_created (migración 0024)';
  end if;
  raise notice 'OK';

  raise notice '--- Test 12: trigger cargos_neto en cuotas ---';
  -- Verificar que la columna cargos_neto existe (migración 0023).
  select count(*) into v_count from information_schema.columns
   where table_schema = 'public' and table_name = 'cuotas'
     and column_name = 'cargos_neto';
  if v_count = 0 then
    raise exception 'Falta columna cuotas.cargos_neto (migración 0023)';
  end if;
  raise notice 'OK';

  raise notice '--- Test 13: trigger contratos_check_cliente_con_cobrador ---';
  -- Verifica que el trigger E1 está creado (migración 0025).
  select count(*) into v_count from information_schema.triggers
   where trigger_name = 'trg_contratos_check_cliente_con_cobrador';
  if v_count = 0 then
    raise exception 'Falta trigger E1 (migración 0025)';
  end if;
  raise notice 'OK';

  raise notice '';
  raise notice '✅ smoke test OK — backend coherente. Todo listo para usar.';
end $$;
