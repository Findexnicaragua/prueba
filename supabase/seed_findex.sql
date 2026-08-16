-- ============================================================================
-- SEED DE DATOS INICIALES PARA FINDEX (admin@findex.com)
-- ============================================================================

DO $$
DECLARE
  v_user_id       UUID := 'feb14981-611f-4c42-8e17-91ad71dfad9a';
  v_tenant_id     UUID := 'f7227a73-f6e8-4578-b5a6-f476f9ebeffe';

  -- Geografía
  v_depto_mga     UUID;
  v_depto_car     UUID;
  v_mun_managua   UUID;
  v_mun_mateare   UUID;
  v_mun_sandino   UUID;
  v_mun_jinotepe  UUID;
  v_com_tamarindo UUID;
  v_com_xiloa     UUID;
  v_com_motastepe UUID;
  v_com_san_jose  UUID;
  v_com_centro    UUID;

  -- Planes
  v_plan_10mb     UUID;
  v_plan_20mb     UUID;
  v_plan_50mb     UUID;
  v_plan_combo    UUID;

  -- Clientes y Contratos
  v_cli_id        UUID;
  v_con_id        UUID;
  v_cuota_id      UUID;
  v_pago_id       UUID;

  -- Inventario
  v_cat_equipos   UUID;
  v_cat_material  UUID;
  v_prod_router   UUID;
  v_prod_fibra    UUID;
  v_ub_bodega     UUID;
BEGIN
  -- 1. Asegurar Tenant y Super Admin
  UPDATE public.tenants SET nombre = 'Findex' WHERE id = v_tenant_id;

  UPDATE public.cobradores 
  SET nombre = 'Admin Findex', rol = 'super_admin', activo = true, prefijo_recibo = 'ADM-01'
  WHERE id = v_user_id;

  -- 2. Departamentos
  INSERT INTO public.departamentos (tenant_id, nombre, codigo)
  VALUES 
    (v_tenant_id, 'Managua', 'MGA'),
    (v_tenant_id, 'Carazo', 'CRZ')
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_depto_mga FROM public.departamentos WHERE tenant_id = v_tenant_id AND nombre = 'Managua' LIMIT 1;
  SELECT id INTO v_depto_car FROM public.departamentos WHERE tenant_id = v_tenant_id AND nombre = 'Carazo' LIMIT 1;

  -- 3. Municipios
  INSERT INTO public.municipios (tenant_id, departamento_id, nombre)
  VALUES 
    (v_tenant_id, v_depto_mga, 'Managua'),
    (v_tenant_id, v_depto_mga, 'Mateare'),
    (v_tenant_id, v_depto_mga, 'Ciudad Sandino'),
    (v_tenant_id, v_depto_car, 'Jinotepe')
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_mun_managua FROM public.municipios WHERE tenant_id = v_tenant_id AND nombre = 'Managua' LIMIT 1;
  SELECT id INTO v_mun_mateare FROM public.municipios WHERE tenant_id = v_tenant_id AND nombre = 'Mateare' LIMIT 1;
  SELECT id INTO v_mun_sandino FROM public.municipios WHERE tenant_id = v_tenant_id AND nombre = 'Ciudad Sandino' LIMIT 1;
  SELECT id INTO v_mun_jinotepe FROM public.municipios WHERE tenant_id = v_tenant_id AND nombre = 'Jinotepe' LIMIT 1;

  -- 4. Comunidades
  INSERT INTO public.comunidades (tenant_id, municipio_id, nombre)
  VALUES 
    (v_tenant_id, v_mun_managua, 'Centro Histórico'),
    (v_tenant_id, v_mun_mateare, 'El Tamarindo'),
    (v_tenant_id, v_mun_mateare, 'Laguna de Xiloá'),
    (v_tenant_id, v_mun_sandino, 'Motastepe'),
    (v_tenant_id, v_mun_jinotepe, 'San José')
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_com_centro FROM public.comunidades WHERE tenant_id = v_tenant_id AND nombre = 'Centro Histórico' LIMIT 1;
  SELECT id INTO v_com_tamarindo FROM public.comunidades WHERE tenant_id = v_tenant_id AND nombre = 'El Tamarindo' LIMIT 1;
  SELECT id INTO v_com_xiloa FROM public.comunidades WHERE tenant_id = v_tenant_id AND nombre = 'Laguna de Xiloá' LIMIT 1;
  SELECT id INTO v_com_motastepe FROM public.comunidades WHERE tenant_id = v_tenant_id AND nombre = 'Motastepe' LIMIT 1;
  SELECT id INTO v_com_san_jose FROM public.comunidades WHERE tenant_id = v_tenant_id AND nombre = 'San José' LIMIT 1;

  -- 5. Planes de servicio Findex
  INSERT INTO public.planes (tenant_id, nombre, tipo, precio_mensual, descripcion, activo)
  VALUES 
    (v_tenant_id, 'Findex Residencial 10MB', 'internet', 450.00, 'Fibra óptica 10 Mbps simétrico', true),
    (v_tenant_id, 'Findex Avanzado 20MB', 'internet', 700.00, 'Fibra óptica 20 Mbps simétrico', true),
    (v_tenant_id, 'Findex Ultra 50MB', 'internet', 1100.00, 'Fibra óptica 50 Mbps simétrico', true),
    (v_tenant_id, 'Findex Dúo Internet + TV', 'combo', 1350.00, '50 Mbps + 80 Canales HD', true)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_plan_10mb FROM public.planes WHERE tenant_id = v_tenant_id AND nombre LIKE '%10MB%' LIMIT 1;
  SELECT id INTO v_plan_20mb FROM public.planes WHERE tenant_id = v_tenant_id AND nombre LIKE '%20MB%' LIMIT 1;
  SELECT id INTO v_plan_50mb FROM public.planes WHERE tenant_id = v_tenant_id AND nombre LIKE '%50MB%' LIMIT 1;
  SELECT id INTO v_plan_combo FROM public.planes WHERE tenant_id = v_tenant_id AND nombre LIKE '%Dúo%' LIMIT 1;

  -- 6. Clientes de demostración
  INSERT INTO public.clientes (
    tenant_id, cobrador_id, comunidad_id, nombre, cedula, telefono, direccion, direccion_referencia, latitud, longitud
  ) VALUES
    (v_tenant_id, v_user_id, v_com_centro,    'Carlos Gómez Mendoza', '001-150388-0003C', '+50587001001', 'Costado este Catedral', 'Portón negro dos pisos', 12.155, -86.273),
    (v_tenant_id, v_user_id, v_com_centro,    'Ana Patricia Morales', '001-200592-0004M', '+50587001002', 'Barrio San Sebastián', 'Frente al parque', 12.158, -86.275),
    (v_tenant_id, v_user_id, v_com_tamarindo, 'Juan Ramón Rivas',     '001-100485-0001A', '+50587001003', 'Calle Principal #4', 'Pulpería El Sol 20m al sur', 12.225, -86.426),
    (v_tenant_id, v_user_id, v_com_tamarindo, 'María Elena Ortiz',    '001-220790-0002B', '+50587001004', 'Sector La Virgen', 'Casa esquinera muro blanco', 12.227, -86.428),
    (v_tenant_id, v_user_id, v_com_xiloa,     'Roberto José Castillo', '001-051180-0005R', '+50587001005', 'Camino a la Laguna', '50m al norte del puente', 12.220, -86.317),
    (v_tenant_id, v_user_id, v_com_motastepe, 'Lucía Fernanda Torres', '001-030995-0006L', '+50587001006', 'Altos de Motastepe', 'Frente a antena Claro', 12.135, -86.330)
  ON CONFLICT DO NOTHING;

  -- 7. Contratos y facturación generada por triggers
  -- Contrato 1: Carlos Gómez (Al día)
  SELECT id INTO v_cli_id FROM public.clientes WHERE tenant_id = v_tenant_id AND nombre = 'Carlos Gómez Mendoza';
  IF v_cli_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contratos WHERE cliente_id = v_cli_id) THEN
    INSERT INTO public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    VALUES (v_tenant_id, v_cli_id, v_plan_50mb, 5, CURRENT_DATE - INTERVAL '3 months')
    RETURNING id INTO v_con_id;
  END IF;

  -- Contrato 2: Ana Patricia (En gracia / venciendo)
  SELECT id INTO v_cli_id FROM public.clientes WHERE tenant_id = v_tenant_id AND nombre = 'Ana Patricia Morales';
  IF v_cli_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contratos WHERE cliente_id = v_cli_id) THEN
    INSERT INTO public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    VALUES (v_tenant_id, v_cli_id, v_plan_20mb, 15, CURRENT_DATE - INTERVAL '2 months')
    RETURNING id INTO v_con_id;
  END IF;

  -- Contrato 3: Juan Ramón (Mora)
  SELECT id INTO v_cli_id FROM public.clientes WHERE tenant_id = v_tenant_id AND nombre = 'Juan Ramón Rivas';
  IF v_cli_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contratos WHERE cliente_id = v_cli_id) THEN
    INSERT INTO public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    VALUES (v_tenant_id, v_cli_id, v_plan_10mb, 1, CURRENT_DATE - INTERVAL '4 months')
    RETURNING id INTO v_con_id;
  END IF;

  -- Contrato 4: María Elena (Combo Dúo)
  SELECT id INTO v_cli_id FROM public.clientes WHERE tenant_id = v_tenant_id AND nombre = 'María Elena Ortiz';
  IF v_cli_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contratos WHERE cliente_id = v_cli_id) THEN
    INSERT INTO public.contratos (tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio)
    VALUES (v_tenant_id, v_cli_id, v_plan_combo, 20, CURRENT_DATE - INTERVAL '1 month')
    RETURNING id INTO v_con_id;
  END IF;

  -- 8. Pagos de demostración
  -- Pagar cuotas viejas de Carlos Gómez
  FOR v_cuota_id IN
    SELECT c.id FROM public.cuotas c
    JOIN public.clientes cl ON cl.id = c.cliente_id
    WHERE cl.tenant_id = v_tenant_id AND cl.nombre = 'Carlos Gómez Mendoza'
    ORDER BY c.periodo ASC
    LIMIT 2
  LOOP
    INSERT INTO public.pagos (
      tenant_id, cuota_id, cobrador_id, monto_cordobas, moneda, monto_original,
      tasa_conversion, metodo, fecha_pago
    ) VALUES (
      v_tenant_id, v_cuota_id, v_user_id, 1100.00, 'NIO', 1100.00,
      1.0, 'efectivo', NOW() - INTERVAL '10 days'
    );
  END LOOP;

  -- Pago en USD para María Elena
  SELECT c.id INTO v_cuota_id FROM public.cuotas c
  JOIN public.clientes cl ON cl.id = c.cliente_id
  WHERE cl.tenant_id = v_tenant_id AND cl.nombre = 'María Elena Ortiz'
  ORDER BY c.periodo ASC LIMIT 1;

  IF v_cuota_id IS NOT NULL THEN
    INSERT INTO public.pagos (
      tenant_id, cuota_id, cobrador_id, monto_cordobas, moneda, monto_original,
      tasa_conversion, metodo, referencia, fecha_pago
    ) VALUES (
      v_tenant_id, v_cuota_id, v_user_id, 1350.00, 'USD', 36.80,
      36.68, 'transferencia', 'REF-FINDEX-001', NOW() - INTERVAL '2 days'
    );
  END IF;

  -- 9. Inventario Inicial
  INSERT INTO public.inv_categorias (tenant_id, nombre, descripcion)
  VALUES 
    (v_tenant_id, 'Equipos ONT / Routers', 'Equipos terminales de fibra para cliente'),
    (v_tenant_id, 'Cables y Conectores', 'Fibra drop y conectores mecánicos SC/APC')
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_cat_equipos FROM public.inv_categorias WHERE tenant_id = v_tenant_id AND nombre LIKE '%ONT%' LIMIT 1;
  SELECT id INTO v_cat_material FROM public.inv_categorias WHERE tenant_id = v_tenant_id AND nombre LIKE '%Cables%' LIMIT 1;

  INSERT INTO public.inv_ubicaciones (tenant_id, nombre, tipo, direccion)
  VALUES (v_tenant_id, 'Bodega Central Findex', 'bodega', 'Oficinas Findex Managua')
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_ub_bodega FROM public.inv_ubicaciones WHERE tenant_id = v_tenant_id AND nombre LIKE '%Central%' LIMIT 1;

  INSERT INTO public.inv_productos (tenant_id, categoria_id, nombre, tipo, unidad_medida, stock_minimo)
  VALUES 
    (v_tenant_id, v_cat_equipos, 'Router ONT Huawei Dual Band', 'serializado', 'unidad', 5),
    (v_tenant_id, v_cat_material, 'Bobina Fibra Drop 1 Hilo (1000m)', 'granel', 'metro', 200)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_prod_router FROM public.inv_productos WHERE tenant_id = v_tenant_id AND nombre LIKE '%Router ONT%' LIMIT 1;

  -- Seriales demo
  IF v_prod_router IS NOT NULL AND v_ub_bodega IS NOT NULL THEN
    INSERT INTO public.inv_seriales (tenant_id, producto_id, ubicacion_id, serial, mac, estado)
    VALUES 
      (v_tenant_id, v_prod_router, v_ub_bodega, 'HWTC-FINDEX-001', '48:57:02:11:22:33', 'disponible'),
      (v_tenant_id, v_prod_router, v_ub_bodega, 'HWTC-FINDEX-002', '48:57:02:11:22:34', 'disponible'),
      (v_tenant_id, v_prod_router, v_ub_bodega, 'HWTC-FINDEX-003', '48:57:02:11:22:35', 'disponible')
    ON CONFLICT DO NOTHING;
  END IF;

  -- 10. Actualizar estados y moras
  PERFORM public.actualizar_notificaciones_mora(v_tenant_id);

  RAISE NOTICE '¡Seed Findex cargado exitosamente para admin@findex.com!';
END $$;