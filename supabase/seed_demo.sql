-- ============================================================================
-- Seed DEMO rico para mostrar la app funcionando.
--
-- Precondición: tener 3 usuarios creados en Authentication (uuid de cada uno).
-- Pegá los uuids abajo y corré el script en SQL Editor.
--
-- Crea:
--   • 1 tenant
--   • 3 cobradores (1 admin, 1 admin_cobranza, 1 cobrador)
--   • 2 departamentos, 5 municipios, 10 comunidades
--   • 3 planes
--   • 12 clientes con geolocalización
--   • 8 contratos (4 indefinidos + 2 de 1 año + 2 de 2 años)
--   • Cuotas generadas automáticamente por trigger
--   • Pagos variados (completos, parciales, anulado)
--   • Cuotas con fechas pasadas para que el cron de mora dispare notificaciones
--
-- Idempotente: reutiliza tenant si los cobradores ya existen.
-- ============================================================================

do $$
declare
  -- ── PEGAR UUIDS AQUÍ ──────────────────────────────────────────────────
  v_admin_id          uuid := 'PEGA_UUID_ADMIN';
  v_admin_cobranza_id uuid := 'PEGA_UUID_ADMIN_COBRANZA';
  v_cobrador_id       uuid := 'PEGA_UUID_COBRADOR';
  -- ──────────────────────────────────────────────────────────────────────

  v_tenant_id     uuid;

  -- Geografía
  v_managua       uuid;
  v_carazo        uuid;
  v_mun_managua   uuid;
  v_mun_mateare   uuid;
  v_mun_sandino   uuid;
  v_mun_jinotepe  uuid;
  v_mun_diriamba  uuid;
  v_com_tamarindo uuid;
  v_com_xiloa     uuid;
  v_com_motastepe uuid;
  v_com_diria     uuid;
  v_com_san_jose  uuid;

  -- Planes
  v_plan_5mb      uuid;
  v_plan_10mb     uuid;
  v_plan_20mb     uuid;

  -- Clientes (los más relevantes guardamos)
  v_cli_ids       uuid[] := array[]::uuid[];
  v_cli_id        uuid;
  v_con_id        uuid;
  v_cuota_id      uuid;
  v_pago_id       uuid;
begin
  -- =========================================================================
  -- Tenant + cobradores
  -- =========================================================================
  select tenant_id into v_tenant_id
    from public.cobradores where id = v_admin_id;

  if v_tenant_id is null then
    insert into public.tenants (nombre) values ('ISP Demo Managua')
      returning id into v_tenant_id;

    insert into public.cobradores (id, tenant_id, nombre, telefono, rol, prefijo_recibo) values
      (v_admin_id,          v_tenant_id, 'María Administradora',    '+50588000001', 'admin',          null),
      (v_admin_cobranza_id, v_tenant_id, 'Carlos Cobranza',          '+50588000002', 'admin_cobranza', null),
      (v_cobrador_id,       v_tenant_id, 'Pedro Pérez',              '+50588000003', 'cobrador',       'PEDRO');
  end if;

  -- =========================================================================
  -- Empresa: rellenar settings (defaults se sembraron por trigger)
  -- =========================================================================
  update public.settings set valor = '"ISP Demo Managua"'
    where tenant_id = v_tenant_id and clave = 'empresa.nombre';
  update public.settings set valor = '"De la rotonda Universitaria 2c al sur, Managua"'
    where tenant_id = v_tenant_id and clave = 'empresa.direccion';
  update public.settings set valor = '"+505 2222-3333"'
    where tenant_id = v_tenant_id and clave = 'empresa.telefono';
  update public.settings set valor = '"J0810000123456"'
    where tenant_id = v_tenant_id and clave = 'empresa.ruc';
  update public.settings set valor = 'true'
    where tenant_id = v_tenant_id and clave = 'pagos.transferencia_habilitada';
  update public.settings set valor = '"¡Gracias por su preferencia!"'
    where tenant_id = v_tenant_id and clave = 'recibo.pie_libre';

  -- =========================================================================
  -- Geografía
  -- =========================================================================
  insert into public.departamentos (nombre, codigo) values ('Managua', 'MN')
    on conflict (nombre) do update set nombre = excluded.nombre
    returning id into v_managua;
  insert into public.departamentos (nombre, codigo) values ('Carazo', 'CA')
    on conflict (nombre) do update set nombre = excluded.nombre
    returning id into v_carazo;

  insert into public.municipios (departamento_id, nombre) values
    (v_managua, 'Managua'),         (v_managua, 'Mateare'), (v_managua, 'Ciudad Sandino'),
    (v_carazo, 'Jinotepe'),         (v_carazo, 'Diriamba')
  on conflict (departamento_id, nombre) do nothing;

  select id into v_mun_managua  from public.municipios where departamento_id = v_managua and nombre = 'Managua';
  select id into v_mun_mateare  from public.municipios where departamento_id = v_managua and nombre = 'Mateare';
  select id into v_mun_sandino  from public.municipios where departamento_id = v_managua and nombre = 'Ciudad Sandino';
  select id into v_mun_jinotepe from public.municipios where departamento_id = v_carazo  and nombre = 'Jinotepe';
  select id into v_mun_diriamba from public.municipios where departamento_id = v_carazo  and nombre = 'Diriamba';

  insert into public.comunidades (municipio_id, nombre) values
    (v_mun_mateare,  'El Tamarindo'),  (v_mun_mateare,  'Los Brasiles'),
    (v_mun_sandino,  'Xiloá'),         (v_mun_sandino,  'Motastepe'),
    (v_mun_managua,  'Bello Horizonte'), (v_mun_managua, 'Las Brisas'),
    (v_mun_jinotepe, 'San José'),       (v_mun_jinotepe, 'El Diamante'),
    (v_mun_diriamba, 'Diriá'),          (v_mun_diriamba, 'La Trinidad')
  on conflict (municipio_id, nombre) do nothing;

  select id into v_com_tamarindo from public.comunidades where municipio_id = v_mun_mateare  and nombre = 'El Tamarindo';
  select id into v_com_xiloa     from public.comunidades where municipio_id = v_mun_sandino  and nombre = 'Xiloá';
  select id into v_com_motastepe from public.comunidades where municipio_id = v_mun_sandino  and nombre = 'Motastepe';
  select id into v_com_diria     from public.comunidades where municipio_id = v_mun_diriamba and nombre = 'Diriá';
  select id into v_com_san_jose  from public.comunidades where municipio_id = v_mun_jinotepe and nombre = 'San José';

  -- =========================================================================
  -- Planes
  -- =========================================================================
  insert into public.planes (tenant_id, nombre, tipo, precio_mensual) values
    (v_tenant_id, 'Internet 5MB',  'internet',  500.00),
    (v_tenant_id, 'Internet 10MB', 'internet',  750.00),
    (v_tenant_id, 'Internet 20MB', 'internet', 1100.00)
  returning id into v_plan_5mb;

  select id into v_plan_5mb  from public.planes where tenant_id = v_tenant_id and nombre = 'Internet 5MB';
  select id into v_plan_10mb from public.planes where tenant_id = v_tenant_id and nombre = 'Internet 10MB';
  select id into v_plan_20mb from public.planes where tenant_id = v_tenant_id and nombre = 'Internet 20MB';

  -- =========================================================================
  -- Clientes — 12 distribuidos entre comunidades, asignados a Pedro (cobrador)
  -- =========================================================================
  -- Lat/lng aproximadas de Nicaragua: 12.0-12.5° N, -86.3 a -86.5° W.

  insert into public.clientes (tenant_id, cobrador_id, comunidad_id, nombre, cedula, telefono, direccion, direccion_referencia, latitud, longitud)
  values
    (v_tenant_id, v_cobrador_id, v_com_tamarindo, 'Juan Ramírez',     '001-010180-0001A', '+50587001001', 'Casa #12',                'Frente al molino',          12.226, -86.428),
    (v_tenant_id, v_cobrador_id, v_com_tamarindo, 'María López',      '001-020285-0002B', '+50587001002', 'Calle del comercio',      'Casa amarilla',             12.227, -86.430),
    (v_tenant_id, v_cobrador_id, v_com_tamarindo, 'Carlos Mendoza',   '001-150388-0003C', '+50587001003', 'Esquina opuesta iglesia', 'Portón verde',              12.225, -86.426),
    (v_tenant_id, v_cobrador_id, v_com_xiloa,     'Ana Rodríguez',    '001-030475-0004D', '+50587001004', 'Camino a la laguna',      '50m al norte del puente',   12.220, -86.317),
    (v_tenant_id, v_cobrador_id, v_com_xiloa,     'José García',      '001-040570-0005E', '+50587001005', 'Sector 2',                'Casa con barda blanca',     12.222, -86.319),
    (v_tenant_id, v_cobrador_id, v_com_motastepe, 'Lucía Torres',     '001-051195-0006F', '+50587001006', 'Barrio Motastepe',        'Pulpería La Estrella',      12.135, -86.330),
    (v_tenant_id, v_cobrador_id, v_com_diria,     'Roberto Sánchez',  '001-200182-0007G', '+50587001007', 'Calle principal',         'Frente al parque',          11.880, -86.241),
    (v_tenant_id, v_cobrador_id, v_com_diria,     'Patricia Núñez',   '001-250590-0008H', '+50587001008', 'Camino real',             'Casa de dos pisos',         11.882, -86.243),
    (v_tenant_id, v_cobrador_id, v_com_san_jose,  'Diego Vargas',     '001-080278-0009I', '+50587001009', 'Sector San José',         'A 100m de la pulpería',     11.857, -86.198),
    (v_tenant_id, v_cobrador_id, v_com_san_jose,  'Sofía Castillo',   '001-091092-0010J', '+50587001010', 'San José oeste',          'Casa azul, portón negro',   11.855, -86.200),
    (v_tenant_id, v_cobrador_id, v_com_tamarindo, 'Mario Herrera',    '001-110280-0011K', '+50587001011', 'Calle 5',                 'Frente al taller',          12.228, -86.432),
    (v_tenant_id, v_cobrador_id, v_com_motastepe, 'Elena Pérez',      '001-220377-0012L', '+50587001012', 'Motastepe alto',          'Sobre la loma',             12.137, -86.332);

  -- =========================================================================
  -- Contratos — el trigger AFTER INSERT genera las cuotas automáticamente
  -- =========================================================================
  -- 4 indefinidos (3 cuotas iniciales) + 2 fijos 1 año (12) + 2 fijos 2 años (24).
  -- Hace 6 meses → algunas cuotas ya vencidas para probar mora.

  -- Indefinido, instalado hace 6 meses (varias cuotas pasadas)
  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    select v_tenant_id, id, v_plan_10mb, 5, current_date - interval '6 months'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'Juan Ramírez';

  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    select v_tenant_id, id, v_plan_5mb, 15, current_date - interval '4 months'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'María López';

  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    select v_tenant_id, id, v_plan_20mb, 25, current_date - interval '2 months'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'Carlos Mendoza';

  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    select v_tenant_id, id, v_plan_10mb, 10, current_date - interval '1 month'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'Ana Rodríguez';

  -- Fijo 1 año
  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin)
    select v_tenant_id, id, v_plan_10mb, 20, current_date - interval '3 months',
           current_date - interval '3 months' + interval '1 year'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'José García';

  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin)
    select v_tenant_id, id, v_plan_5mb, 1, current_date - interval '5 months',
           current_date - interval '5 months' + interval '1 year'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'Lucía Torres';

  -- Fijo 2 años
  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin)
    select v_tenant_id, id, v_plan_20mb, 28, current_date - interval '2 months',
           current_date - interval '2 months' + interval '2 years'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'Roberto Sánchez';

  insert into public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin)
    select v_tenant_id, id, v_plan_10mb, 17, current_date - interval '1 month',
           current_date - interval '1 month' + interval '2 years'
      from public.clientes where tenant_id = v_tenant_id and nombre = 'Diego Vargas';

  -- =========================================================================
  -- Pagos variados para demostrar estados
  -- =========================================================================

  -- Juan Ramírez: pagó 5 de las 6 cuotas pasadas (al día menos la última)
  for v_cuota_id in
    select id from public.cuotas
     where cliente_id = (select id from public.clientes where tenant_id = v_tenant_id and nombre = 'Juan Ramírez')
     order by periodo asc
     limit 5
  loop
    insert into public.pagos (
      tenant_id, cuota_id, cobrador_id, monto_cordobas, moneda, monto_original,
      tasa_conversion, metodo, fecha_pago
    ) values (
      v_tenant_id, v_cuota_id, v_cobrador_id, 750.00, 'NIO', 750.00,
      1, 'efectivo', now() - interval '1 day'
    );
  end loop;

  -- María López: pago PARCIAL en la cuota más vieja (sólo 300 de 500)
  select id into v_cuota_id from public.cuotas
    where cliente_id = (select id from public.clientes where tenant_id = v_tenant_id and nombre = 'María López')
    order by periodo asc limit 1;
  insert into public.pagos (
    tenant_id, cuota_id, cobrador_id, monto_cordobas, moneda, monto_original,
    tasa_conversion, metodo, fecha_pago
  ) values (
    v_tenant_id, v_cuota_id, v_cobrador_id, 300.00, 'NIO', 300.00,
    1, 'efectivo', now() - interval '15 days'
  );

  -- Lucía Torres: pago en USD con tasa
  select id into v_cuota_id from public.cuotas
    where cliente_id = (select id from public.clientes where tenant_id = v_tenant_id and nombre = 'Lucía Torres')
    order by periodo asc limit 1;
  insert into public.pagos (
    tenant_id, cuota_id, cobrador_id, monto_cordobas, moneda, monto_original,
    tasa_conversion, metodo, referencia, fecha_pago
  ) values (
    v_tenant_id, v_cuota_id, v_cobrador_id, 547.50, 'USD', 15.00,
    36.50, 'efectivo', null, now() - interval '7 days'
  );

  -- José García: pago anulado (soft delete) para probar trigger
  select id into v_cuota_id from public.cuotas
    where cliente_id = (select id from public.clientes where tenant_id = v_tenant_id and nombre = 'José García')
    order by periodo asc limit 1;
  insert into public.pagos (
    tenant_id, cuota_id, cobrador_id, monto_cordobas, moneda, monto_original,
    tasa_conversion, metodo, fecha_pago
  ) values (
    v_tenant_id, v_cuota_id, v_cobrador_id, 750.00, 'NIO', 750.00,
    1, 'efectivo', now() - interval '3 days'
  ) returning id into v_pago_id;

  update public.pagos
     set anulado = true,
         anulado_en = now(),
         anulado_por = v_admin_id,
         motivo_anulacion = 'Demo: registrar mal el monto, reemitir'
   where id = v_pago_id;

  -- =========================================================================
  -- Notificaciones de mora — generar ahora para que aparezcan en demo
  -- =========================================================================
  perform public.actualizar_notificaciones_mora(v_tenant_id);

  raise notice '✅ Seed DEMO listo';
  raise notice '   tenant=%', v_tenant_id;
  raise notice '   admin=% admin_cobranza=% cobrador=%', v_admin_id, v_admin_cobranza_id, v_cobrador_id;
  raise notice '   12 clientes, 8 contratos, cuotas generadas por trigger';
end $$;
