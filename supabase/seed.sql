-- ============================================================================
-- Seed para test de diagnóstico de PowerSync.
--
-- Cómo usar:
--  1. Crea un usuario en Supabase Dashboard → Authentication → Users
--  2. Copia su UUID
--  3. Pégalo abajo donde dice 'PEGA_EL_UUID_DEL_USUARIO_AQUI'
--  4. Corre todo este script en Supabase Dashboard → SQL Editor
--
-- Crea: 1 tenant (con settings auto-sembrados por trigger) + 1 cobrador
--       con prefijo COB-01 + 1 depto/municipio/comunidad de prueba + 1 plan
--       + 1 cliente con comunidad + 1 contrato + 1 cuota pendiente.
--
-- Idempotente: reutiliza tenant del cobrador si ya existe.
-- ============================================================================

do $$
declare
  v_user_id      uuid := 'PEGA_EL_UUID_DEL_USUARIO_AQUI';
  v_tenant_id    uuid;
  v_plan_id      uuid;
  v_cliente_id   uuid;
  v_contrato_id  uuid;
  v_depto_id     uuid;
  v_municipio_id uuid;
  v_comunidad_id uuid;
begin
  -- Reutilizar tenant existente si el cobrador ya está creado.
  select tenant_id into v_tenant_id
    from public.cobradores where id = v_user_id;

  if v_tenant_id is null then
    insert into public.tenants (nombre) values ('ISP de Prueba')
    returning id into v_tenant_id;
    -- Trigger sembra settings default automáticamente.

    insert into public.cobradores (id, tenant_id, nombre, telefono, rol, prefijo_recibo)
    values (v_user_id, v_tenant_id, 'Cobrador de Prueba', '+50500000000',
            'cobrador', 'COB-01');
  end if;

  -- Geografía: catálogo compartido, crear si no existe.
  insert into public.departamentos (nombre, codigo) values ('Managua', 'MN')
  on conflict (nombre) do update set codigo = excluded.codigo
  returning id into v_depto_id;

  insert into public.municipios (departamento_id, nombre) values (v_depto_id, 'Mateare')
  on conflict (departamento_id, nombre) do update set nombre = excluded.nombre
  returning id into v_municipio_id;

  insert into public.comunidades (municipio_id, nombre) values (v_municipio_id, 'El Tamarindo')
  on conflict (municipio_id, nombre) do update set nombre = excluded.nombre
  returning id into v_comunidad_id;

  insert into public.planes (tenant_id, nombre, tipo, precio_mensual)
  values (v_tenant_id, 'Internet 10MB', 'internet', 500.00)
  returning id into v_plan_id;

  insert into public.clientes (
    tenant_id, cobrador_id, comunidad_id,
    nombre, telefono, direccion, direccion_referencia
  )
  values (
    v_tenant_id, v_user_id, v_comunidad_id,
    'Cliente de Prueba', '+50511111111',
    'Casa de la esquina', 'Frente al molino, portón verde'
  )
  returning id into v_cliente_id;

  -- El trigger en contratos AFTER INSERT genera las cuotas iniciales
  -- automáticamente (3 si indefinido, todas si tiene fecha_fin).
  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
  values (v_tenant_id, v_cliente_id, v_plan_id, 17, current_date)
  returning id into v_contrato_id;

  raise notice '✅ Seed listo. tenant=% cobrador=%', v_tenant_id, v_user_id;
end $$;
