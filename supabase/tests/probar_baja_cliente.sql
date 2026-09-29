-- ===========================================================================
-- probar_baja_cliente.sql — Prueba END-TO-END de la regla "cliente desactivado
-- no deja nada pendiente" (migracion 0260), contra DATOS REALES y SIN ESCRIBIR.
--
--   supabase db query --linked -f supabase/tests/probar_baja_cliente.sql
--
-- POR QUE ASI Y NO UN SEED: el trigger `zz_clientes_baja_cancela_contratos`
-- vive en el SERVER, asi que un test de Dart no puede ejercitarlo. Y un seed
-- con datos inventados prueba el trigger contra un caso de laboratorio; esto lo
-- prueba contra la forma real que tienen los contratos de produccion.
--
-- COMO NO ESCRIBE NADA: el bloque termina en `RAISE EXCEPTION`, que aborta la
-- transaccion entera. El resultado vuelve en el texto del error. Es la misma
-- tecnica con la que se probaron 0260 y 0261 antes de aplicarlas.
--
-- QUE TIENE QUE DAR (verificado el 2026-08-26 contra vxxz):
--   contrato: suspendido -> cancelado
--   deuda:    C$248,23   -> C$0,00
--   pagos vivos: 31.462  -> 31.462   <-- IDENTICOS: la baja no toca plata cobrada
--
-- SI FALLA:
--   · "no hay ningun cliente ACTIVO con contrato suspendido y deuda" → no es un
--     error: significa que hoy no existe el caso para probar. Sembralo o esperá.
--   · el contrato sigue 'suspendido' → el trigger no disparo. Revisar que
--     `zz_clientes_baja_cancela_contratos` exista y que la transicion sea
--     true→false (un cliente YA inactivo no lo dispara, por diseño).
--   · la deuda no llego a 0 → disparo el trigger pero no la condonacion: revisar
--     `condonacion_cancelacion_aplica` (el flag `cobranza.cancelar_condona`) y
--     los `RAISE LOG` del server.
--   · los pagos vivos CAMBIARON → ABORTAR Y AVISAR. Significa que se anulo una
--     cuota con plata y la cascada mato pagos y recibos. Es el unico desenlace
--     que destruye algo.
-- ===========================================================================
DO $prueba$
DECLARE
  v_cli     uuid;
  v_ct      uuid;
  v_tenant  uuid;
  v_actor   uuid;
  v_antes   numeric;
  v_desp    numeric;
  v_estado  text;
  v_pagos_a int;
  v_pagos_d int;
BEGIN
  SELECT c.id, c.tenant_id, ct.id
    INTO v_cli, v_tenant, v_ct
    FROM public.clientes c
    JOIN public.contratos ct ON ct.cliente_id = c.id AND ct.estado = 'suspendido'
    JOIN public.cuotas cu ON cu.contrato_id = ct.id AND cu.estado IN ('pendiente','parcial')
   WHERE c.activo = true
     AND (cu.monto + coalesce(cu.cargos_neto, 0) - coalesce(cu.monto_pagado, 0)) > 0.009
   LIMIT 1;

  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'PRUEBA REVERTIDA | no hay ningun cliente ACTIVO con contrato suspendido y deuda para probar el trigger';
  END IF;

  SELECT count(*) INTO v_pagos_a
    FROM public.pagos WHERE anulado = false AND en_revision = false;
  SELECT coalesce(sum(cu.monto + coalesce(cu.cargos_neto, 0) - coalesce(cu.monto_pagado, 0)), 0)
    INTO v_antes
    FROM public.cuotas cu
   WHERE cu.contrato_id = v_ct AND cu.estado IN ('pendiente', 'parcial');

  -- El trigger firma la baja con `auth.uid()`; sin identidad devuelve
  -- 'sin_actor' y no cancela nada. `is_local = true` acota el set_config a esta
  -- transaccion, que en una conexion pooleada de produccion no es opcional.
  SELECT id INTO v_actor
    FROM public.cobradores
   WHERE tenant_id = v_tenant AND rol = 'admin' AND activo
   LIMIT 1;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, true);

  -- LA PRUEBA: desactivar el cliente, y nada mas. Todo lo demas lo tiene que
  -- hacer el server solo.
  UPDATE public.clientes SET activo = false WHERE id = v_cli;

  SELECT estado INTO v_estado FROM public.contratos WHERE id = v_ct;
  SELECT coalesce(sum(cu.monto + coalesce(cu.cargos_neto, 0) - coalesce(cu.monto_pagado, 0)), 0)
    INTO v_desp
    FROM public.cuotas cu
   WHERE cu.contrato_id = v_ct AND cu.estado IN ('pendiente', 'parcial');
  SELECT count(*) INTO v_pagos_d
    FROM public.pagos WHERE anulado = false AND en_revision = false;

  RAISE EXCEPTION 'PRUEBA REVERTIDA | contrato: suspendido -> % | deuda: % -> % | pagos vivos: % -> %',
    v_estado, round(v_antes, 2), round(v_desp, 2), v_pagos_a, v_pagos_d;
END $prueba$;
