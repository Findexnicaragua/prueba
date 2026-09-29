-- 0248_invariantes_21_31_en_rpc.sql
-- Portar INV21-31 del archivo canonico (supabase/tests/invariantes_dinero.sql)
-- a la RPC que corre el panel del Dev. Hoy el panel reporta 20 y el archivo 31:
-- divergir es exactamente el problema que 0220 vino a cerrar.
--
-- Ademas: el ORDEN pasa a ser NUMERICO. Antes ordenaba por TEXTO y listaba
-- INV1, INV10, INV11, INV12, ... INV2 - ilegible con 20, peor con 31.
--
-- PARTIDA: pg_get_functiondef() de la definicion VIVA (0213 -> 0218 -> 0219 ->
-- 0220), NUNCA del cuerpo de una migracion vieja. Es la leccion 0151->0152:
-- reescribir desde un cuerpo viejo dropea silenciosamente lo que se agrego en
-- el medio y CREATE OR REPLACE no avisa.
--
-- SOLO LECTURA: la funcion no escribe nada. Los 11 nuevos arrancan en CERO en
-- los 3 tenants (verificado antes de esta migracion contra el archivo).

CREATE OR REPLACE FUNCTION public.super_admin_verificar_invariantes(p_tenant uuid)
 RETURNS TABLE(invariante text, violaciones bigint, ejemplo_ids text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  inv1 as (
    select 'INV1: entregado = aplicado + vuelto (pagos)'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text as ejemplo_ids
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and abs((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50) t
  ),
  inv2 as (
    select 'INV2: cuota.monto_pagado = SUM(pagos aplicados)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cuota_id::text order by cuota_id))[1:10], ', '), '')::text
    from (select cu.id as cuota_id
            from public.cuotas cu
            left join (select cuota_id, sum(monto_cordobas) as pagado
                         from public.pagos where anulado = false and en_revision = false group by cuota_id) p
              on p.cuota_id = cu.id
           where cu.tenant_id = p_tenant and cu.estado <> 'anulada'
             and abs(cu.monto_pagado - coalesce(p.pagado, 0)) > 0.01) t
  ),
  inv3 as (
    select 'INV3: estado de cuota coherente con monto_pagado'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and ((estado = 'pagada'    and monto_pagado < (monto + coalesce(cargos_neto,0)) - 0.01)
               or (estado = 'pendiente' and monto_pagado > 0.01)
               or (estado = 'parcial'   and (monto_pagado <= 0.01
                     or monto_pagado >= (monto + coalesce(cargos_neto,0)) - 0.01)))) t
  ),
  inv4 as (
    select 'INV4: ninguna cuota con sobrepago (monto_pagado > total)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and monto_pagado > (monto + coalesce(cargos_neto,0)) + 0.01) t
  ),
  inv5 as (
    select 'INV5: todo pago no anulado tiene recibo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id from public.pagos p
           where p.tenant_id = p_tenant and p.anulado = false
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)) p
  ),
  inv6 as (
    select 'INV6: vuelto_cordobas >= 0'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and vuelto_cordobas < 0) t
  ),
  inv7 as (
    select 'INV7: correlativo de recibo único por cobrador+prefijo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(numero_completo order by numero_completo))[1:10], ', '), '')::text
    from (select numero_completo from public.recibos
           where tenant_id = p_tenant
           group by cobrador_id, prefijo, correlativo, numero_completo
           having count(*) > 1) t
  ),
  inv8 as (
    select 'INV8: contrato.cobrador_id = cliente.cobrador_id'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
            join public.clientes c on c.id = ct.cliente_id
           where ct.tenant_id = p_tenant and ct.estado = 'activo'
             and ct.cobrador_id is distinct from c.cobrador_id) t
  ),
  inv9 as (
    -- Solo cuotas OPERATIVAS (pendiente/parcial): el trigger 0122 congela el
    -- cobrador de las pagadas/anuladas al reasignar (auditoría) -> su mismatch es
    -- esperado, no un bug. "Quién cobró" = pagos/recibos.cobrador_id (INV5/INV7).
    select 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
           where cu.tenant_id = p_tenant and cu.contrato_id is not null
             and cu.estado in ('pendiente','parcial')
             and cu.cobrador_id is distinct from ct.cobrador_id) cu
  ),
  inv10 as (
    select 'INV10: tenant_id de hija == tenant_id de su padre (0082)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(ofensor order by ofensor))[1:10], ', '), '')::text
    from (
      select 'pago:' || p.id::text as ofensor
        from public.pagos p join public.cuotas cu on cu.id = p.cuota_id
       where p.tenant_id = p_tenant and p.cuota_id is not null and p.tenant_id <> cu.tenant_id
      union all
      select 'recibo:' || r.id::text
        from public.recibos r join public.pagos p on p.id = r.pago_id
       where r.tenant_id = p_tenant and r.pago_id is not null and r.tenant_id <> p.tenant_id
      union all
      select 'cargo:' || ce.id::text
        from public.cargos_extra ce join public.cuotas cu on cu.id = ce.cuota_id
       where ce.tenant_id = p_tenant and ce.cuota_id is not null and ce.tenant_id <> cu.tenant_id) t
  ),
  inv11 as (
    -- OJO: 'Suspensión temporal' se COMPARA contra data. Se arma con chr(243)
    -- ("ó") para que sea inmune al encoding de la sesión que corra esta
    -- migración - el mojibake de 0218 en ESTE literal produjo un falso positivo
    -- permanente en todo contrato fijo suspendido-y-reactivado (ver 0219).
    select 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is not null and ct.duracion_meses > 0
             and ((select count(*) from public.cuotas cu
                     where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                       and cu.estado <> 'anulada')
                  + (select count(*) from public.cuotas cu
                       where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                         and cu.estado = 'anulada'
                         and cu.motivo_anulacion = 'Suspensi' || chr(243) || 'n temporal'))
                 <> ct.duracion_meses) t
  ),
  inv12 as (
    select 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant
             and abs(coalesce((select sum(cu.monto_pagado) from public.cuotas cu
                                where cu.contrato_id = ct.id), 0)
                   - coalesce((select sum(pa.monto_cordobas) from public.pagos pa
                                join public.cuotas cu2 on cu2.id = pa.cuota_id
                               where cu2.contrato_id = ct.id and pa.anulado = false and pa.en_revision = false), 0)) > 0.01) t
  ),
  inv13 as (
    select 'INV13: cargos origen=ajuste son descuento_* con motivo no vacío'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ce.id from public.cargos_extra ce
           where ce.tenant_id = p_tenant and ce.origen = 'ajuste'
             and (ce.tipo not in ('descuento_monto', 'descuento_porcentaje')
                  or ce.descripcion is null or btrim(ce.descripcion) = '')) t
  ),
  inv14 as (
    select 'INV14: cuotas.cargos_neto == SUM real de cargos_extra'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
           where cu.tenant_id = p_tenant
             and abs(coalesce(cu.cargos_neto, 0)
                   - coalesce((select sum(case
                         when ce.tipo in ('reconexion','otro') then ce.monto
                         when ce.tipo in ('descuento_monto','descuento_porcentaje','credito_aplicado') then -ce.monto
                         else 0 end)
                        from public.cargos_extra ce where ce.cuota_id = cu.id), 0)) > 0.01) t
  ),
  inv15 as (
    select 'INV15: saldo a favor del cliente nunca negativo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cliente_id::text order by cliente_id))[1:10], ', '), '')::text
    from (select cliente_id from public.saldos_favor
           where tenant_id = p_tenant
           group by cliente_id
           having sum(case when tipo = 'acreditado' then monto else -monto end) < -0.005) t
  ),
  inv16 as (
    select 'INV16: ningún pago con método de crédito (crédito no es pago)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and metodo not in ('efectivo','transferencia','deposito','tarjeta')) t
  ),
  inv17 as (
    select 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchón)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is null
             and (select count(*) from public.cuotas cu
                   where cu.contrato_id = ct.id and cu.estado = 'pendiente'
                     and cu.tipo_cargo_manual is null
                     and cu.periodo > greatest(
                       date_trunc('month', (now() at time zone 'America/Managua'))::date,
                       coalesce((select max(cu2.periodo) from public.cuotas cu2
                                  where cu2.contrato_id = ct.id
                                    and cu2.estado in ('pagada', 'parcial')), '1900-01-01'::date))) < 3) t
  ),
  inv18 as (
    -- Repuesto del invariantes_dinero.sql canónico (nunca estuvo en el RPC).
    -- El guard de sobrepago (0214) es el ÚNICO que puede anular sin usuario, y
    -- solo con su motivo automático. 'automático' con chr(225) por la misma
    -- razón que INV11: se COMPARA contra data (el CHECK
    -- `pagos_anulacion_coherencia` usa ese prefijo exacto).
    select 'INV18: anulación sin actor solo si la hizo el guard (0214)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = true and anulado_por is null
             and coalesce(motivo_anulacion, '')
                 not like 'Duplicado autom' || chr(225) || 'tico:%') t
  ),
  inv19 as (
    -- NUEVO: desactivar un cliente = sin servicio Y SALDADO (regla del dueño).
    -- Un cliente inactivo con deuda es deuda INVISIBLE: no sale en las listas
    -- de cobro pero se le siguen generando/venciendo cuotas. El guard
    -- `trg_clientes_guard_desactivar` (0220-a) lo impide hacia adelante; esto
    -- expone las filas que ya quedaron así. Saldo canónico (invariante #10);
    -- NO se filtra por estado del contrato: la deuda de un contrato cancelado
    -- sigue siendo deuda.
    select 'INV19: cliente desactivado no tiene deuda pendiente'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select c.id from public.clientes c
           where c.tenant_id = p_tenant and c.activo = false
             and exists (select 1 from public.cuotas cu
                          where cu.cliente_id = c.id
                            and cu.estado in ('pendiente','parcial')
                            and (cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado) > 0.01)) t
  ),
  inv20 as (
    -- NUEVO: `clientes.vencimiento_mas_viejo` es un DENORMALIZADO que mantiene
    -- `recalc_vencimiento_mas_viejo` (definición vigente: 0185) y del que
    -- depende el color del mapa / la priorización de la ruta. Si quedó
    -- desincronizado (p.ej. una escritura que no disparó el trigger), el
    -- cobrador ve una fecha de vencimiento que no existe. El predicado es
    -- EXACTAMENTE el de esa función - MIN(fecha_vencimiento) de las cuotas
    -- pendiente/parcial cuyo contrato está activo (LEFT JOIN + COALESCE: la
    -- cuota sin contrato cuenta) - y compara con IS DISTINCT FROM para que
    -- NULL vs NULL no sea violación.
    select 'INV20: clientes.vencimiento_mas_viejo == el real (recalc)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select c.id from public.clientes c
           where c.tenant_id = p_tenant
             and c.vencimiento_mas_viejo is distinct from (
                   select min(cu.fecha_vencimiento)
                     from public.cuotas cu
                     left join public.contratos ct on ct.id = cu.contrato_id
                    where cu.cliente_id = c.id
                      and cu.estado in ('pendiente', 'parcial')
                      and coalesce(ct.estado, 'activo') = 'activo')) t
  ),
  -- ==========================================================================
  -- INV21-31: portados desde `supabase/tests/invariantes_dinero.sql` (el
  -- archivo canónico) para que el PANEL y el ARCHIVO digan lo mismo. Divergir
  -- es exactamente el problema que 0220 vino a cerrar.
  -- Diferencia obligada respecto del archivo: acá TODO va scopeado por
  -- `p_tenant` (el archivo corre global). Cada agregado se corta a 10 ejemplos
  -- con el mismo `array_to_string((array_agg(...))[1:10], ', ')` del resto.
  -- ==========================================================================

  -- INV21: oldest-first (invariante #11 de AGENTS) — la ÚNICA regla de dinero
  -- sin red: por DECISIÓN de producto NO hay trigger server, solo el guard del
  -- cliente (`pagos_repo._validarOldestFirst`), ciego al multi-device offline.
  -- `k` = (fecha_vencimiento, período) = el MISMO criterio de orden que `keyDe`
  -- en el guard. Una violación por CUOTA SALTADA. SOLO cuenta la que NUNCA vio
  -- plata (pendiente + monto_pagado <= 0.01): incluir 'parcial' da un falso
  -- positivo (una cuota pagada completa que después recibe un cargo vuelve a
  -- 'parcial' sin que nadie viole el orden).
  of_regs as (
    select cu.id, cu.contrato_id, cu.estado, cu.monto_pagado, cu.monto, cu.cargos_neto,
           to_char(cu.fecha_vencimiento,'YYYYMMDD') || to_char(cu.periodo,'YYYYMMDD') as k
      from public.cuotas cu
     where cu.tenant_id = p_tenant
       and cu.contrato_id is not null
       and cu.tipo_cargo_manual is null
       and cu.estado <> 'anulada'
  ),
  of_tope as (
    select contrato_id, max(k) as k_max
      from of_regs where monto_pagado > 0.01 group by contrato_id
  ),
  inv21 as (
    select 'INV21: ninguna cuota vieja saltada por un cobro posterior (#11 oldest-first)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select r.id
            from of_regs r
            join of_tope t on t.contrato_id = r.contrato_id
           where r.estado = 'pendiente'
             and r.monto_pagado <= 0.01
             and (r.monto + coalesce(r.cargos_neto,0)) > 0.01
             and r.k < t.k_max) t
  ),

  -- INV22: INV5 es unidireccional (pago vivo -> recibo). Este es el reverso.
  -- Un recibo vivo sin pago vivo detrás es un comprobante con número fiscal
  -- circulando sin plata en caja.
  inv22 as (
    select 'INV22: todo recibo vivo cuelga de un pago vivo (reverso de INV5)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select r.id
            from public.recibos r
            left join public.pagos p on p.id = r.pago_id
           where r.tenant_id = p_tenant
             and coalesce(r.anulado, false) = false
             and (r.pago_id is null or p.id is null or p.anulado = true)) t
  ),

  -- INV23: INV5 se satisface con un recibo ANULADO (solo pregunta NOT EXISTS).
  -- Este exige EXACTAMENTE UNO vivo: caza el cobro sin comprobante válido Y el
  -- duplicado que quema un correlativo. SUBSUME a INV5; se dejan los dos porque
  -- si divergen (INV5=0, INV23=N) el par dice que el problema son recibos
  -- anulados y no recibos faltantes.
  inv23 as (
    select 'INV23: todo pago vivo tiene EXACTAMENTE un recibo vivo (refuerza INV5)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id
            from public.pagos p
           where p.tenant_id = p_tenant
             and p.anulado = false
             and (select count(*) from public.recibos r
                   where r.pago_id = p.id and coalesce(r.anulado,false) = false) <> 1) t
  ),

  -- INV24: el hueco entre INV2 (excluye anuladas) e INV12 (recorre contratos).
  -- Un pago VIVO sobre una cuota anulada o inexistente no lo mira NADIE, y esa
  -- plata SÍ entra al arqueo y al dashboard (que suman monto_cordobas bruto).
  -- Las cuotas manuales pueden tener contrato_id NULL, así que INV12 tampoco
  -- llega por ese lado.
  inv24 as (
    select 'INV24: ningún pago vivo cuelga de una cuota anulada o inexistente'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id
            from public.pagos p
            left join public.cuotas cu on cu.id = p.cuota_id
           where p.tenant_id = p_tenant
             and p.anulado = false
             and (p.cuota_id is null or cu.id is null or cu.estado = 'anulada')) t
  ),

  -- INV25: verifica que la red de 0234 (anular cuotas futuras al dar de baja)
  -- haya funcionado. 0234 nació de 8 cuotas por C$6.411 que se siguieron
  -- facturando después de la baja.
  -- ¡OJO! El predicado del WHERE es COPIA EXACTA del CTE `futuras` de
  -- `contratos_anular_cuotas_futuras_trg`, A PROPÓSITO: si el trigger cambia,
  -- este invariante tiene que cambiar con él.
  -- Anclado a la VENTANA DE SERVICIO, nunca al mes calendario (regla 1c de
  -- AGENTS): anclado al mes da falsos positivos que son prorrateos de baja
  -- correctos (facturación vencida con dia_pago <> 1).
  inv25 as (
    select 'INV25: contrato dado de baja sin cuotas FUTURAS vivas (red 0234)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id
            from public.contratos ct
            join lateral (
              select case when ct.estado = 'cancelado' then ct.cancelado_en::date
                          else (select s.suspendido_en::date from public.contrato_suspensiones s
                                 where s.contrato_id = ct.id and s.reactivado_en is null
                                 order by s.suspendido_en desc limit 1) end as fecha
            ) b on true
            join public.cuotas cu on cu.contrato_id = ct.id
           where ct.tenant_id = p_tenant
             and ct.estado in ('cancelado','suspendido')
             and b.fecha is not null
             and cu.estado = 'pendiente'
             and cu.tipo_cargo_manual is null
             and coalesce(cu.monto_pagado, 0) <= 0.009
             and coalesce(
                   (select max(cu2.fecha_vencimiento) from public.cuotas cu2
                     where cu2.contrato_id = cu.contrato_id
                       and cu2.fecha_vencimiento < cu.fecha_vencimiento
                       and cu2.estado <> 'anulada'),
                   (cu.fecha_vencimiento - interval '1 month')::date
                 ) > b.fecha) t
  ),

  -- INV26: cancelar contrato es el único evento de plata sin CHECK de
  -- atribución (`pagos` y `cuotas` sí tienen el suyo). CORTE 2026-08-20: los
  -- históricos sin atribuir son legacy + una limpieza SQL manual del 19/08.
  -- Ningún camino de la APP deja el actor vacío. La segunda rama cubre el caso
  -- sin fecha, que si no se escaparía por el propio filtro de fecha.
  inv26 as (
    select 'INV26: cancelación de contrato atribuida (desde 2026-08-20)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id
            from public.contratos ct
           where ct.tenant_id = p_tenant
             and ct.estado = 'cancelado'
             and (ct.cancelado_en >= date '2026-08-20'
                  or (ct.cancelado_en is null and ct.created_at >= date '2026-08-20'))
             and (ct.cancelado_por is null
                  or ct.cancelado_en is null
                  or coalesce(btrim(ct.motivo_cancelacion), '') = '')) t
  ),

  -- INV27: `op_log` es el ÚNICO registro de cambios (audit_log se eliminó en
  -- 0140) y lo escribe el CLIENTE -> la fila puede perderse sin que el cobro se
  -- pierda. Ningún INV1-20 lo miraba.
  -- CORTE 2026-08-20 + GRACIA DE 48 h. El corte deja afuera los 177 cobros
  -- históricos (causa conocida y cerrada: `op_log` no tenía policy de SELECT
  -- para cobrador, el upsert moría con 42501 en el RETURNING y el connector lo
  -- descartaba -> 0190, 2026-07-17). La gracia de 48 h evita el FALSO POSITIVO
  -- del cobrador offline: `uploadData` sube las ops de a una y el insert de
  -- op_log es la ÚLTIMA del writeTransaction del cobro; si se corta la señal en
  -- el medio, el server queda con el pago y sin rastro hasta la próxima sync.
  -- QUÉ NO VE: el 2º pago o posterior sobre la MISMA cuota (es EXISTS, no
  -- conteo), y los 177 históricos, a propósito.
  inv27 as (
    select 'INV27: todo cobro deja rastro en op_log (desde 2026-08-20, gracia 48h)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id
            from public.pagos p
           where p.tenant_id = p_tenant
             and coalesce(p.ocurrido_en, p.fecha_pago) >= timestamptz '2026-08-20 00:00-06'
             and coalesce(p.ocurrido_en, p.fecha_pago) < now() - interval '48 hours'
             and not exists (
                   select 1 from public.op_log o
                    where o.tenant_id = p.tenant_id
                      and o.entidad = 'cuotas' and o.entidad_id = p.cuota_id
                      and o.tipo_op in ('cobro', 'cobro_recuperado'))) t
  ),

  -- INV28: el invariante #4 tiene DOS sumandos
  -- (`recaudado_caja = SUM(pagos) - SUM(saldos_favor devuelto)`) y los 20
  -- chequeos vigentes miran solo el primero. Bucketea por `fecha_devolucion` y
  -- `fecha_pago::date` — local-naive A PROPÓSITO, igual que el arqueo (regla
  -- 1b: el wall-clock de fecha_pago sostiene el bucketing). Solo
  -- `metodo='efectivo'`: una devolución en efectivo no sale de una
  -- transferencia. El `ejemplo_ids` devuelve `cobrador_id@fecha`, no un uuid:
  -- la violación es del PAR, no de una fila.
  inv28 as (
    select 'INV28: devoluciones del día <= efectivo cobrado ese día (#4 caja neta)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(clave order by clave))[1:10], ', '), '')::text
    from (select d.cobrador_id::text || '@' || d.fecha_devolucion::text as clave
            from public.saldos_favor d
           where d.tenant_id = p_tenant
             and d.tipo = 'devuelto'
             and d.cobrador_id is not null and d.fecha_devolucion is not null
           group by d.tenant_id, d.cobrador_id, d.fecha_devolucion
          having sum(d.monto) > coalesce((
                   select sum(p.monto_cordobas) from public.pagos p
                    where p.tenant_id = d.tenant_id and p.cobrador_id = d.cobrador_id
                      and p.anulado = false and p.metodo = 'efectivo'
                      and p.fecha_pago::date = d.fecha_devolucion), 0) + 0.005) t
  ),

  -- INV29: sin cobrador+fecha la devolución no cae en NINGÚN bucket del arqueo
  -- (el ISP sigue mostrando en caja plata que ya devolvió); sin recibo no hay
  -- papel de la salida de efectivo. Las tres columnas son NULLABLE y no hay
  -- CHECK que las exija. Va de la mano de INV28: sin INV29, INV28 es EVADIBLE
  -- (una devolución sin cobrador ni fecha se saltea su GROUP BY).
  inv29 as (
    select 'INV29: devolución de saldo con cobrador, fecha y recibo (#2/#4)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select sf.id
            from public.saldos_favor sf
           where sf.tenant_id = p_tenant
             and sf.tipo = 'devuelto'
             and (sf.cobrador_id is null or sf.fecha_devolucion is null
                  or sf.recibo_id is null)) t
  ),

  -- INV30: la moneda es el único ángulo del modelo contable cuyo SÍ es por
  -- código y no por datos. INV1 verifica la CONSISTENCIA de la ecuación, no la
  -- SANIDAD de sus factores: con tasa=0 pasa a exigir monto_cordobas+vuelto=0,
  -- y un pago marcado NIO con tasa 36 cumple igual si monto_original se guardó
  -- 36 veces más chico.
  inv30 as (
    select 'INV30: moneda y tasa coherentes en pagos vivos (#3)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id
            from public.pagos p
           where p.tenant_id = p_tenant
             and p.anulado = false
             and (p.tasa_conversion is null or p.tasa_conversion <= 0
                  or p.monto_original is null or p.monto_original <= 0
                  or (p.moneda = 'NIO' and abs(p.tasa_conversion - 1) > 0.0001))) t
  ),

  -- INV31: el crédito por excedente (0127) se escribe en DOS tablas desde el
  -- CLIENTE, en la misma writeTransaction, y nadie verifica el puente.
  -- Si entra SOLO el cargo: la cuota se descuenta sin consumir saldo -> el
  -- cliente usa el mismo crédito infinitas veces. Si entra SOLO el saldo: se
  -- consume el crédito sin descontar la cuota. Ninguno rompe INV14 (mira la
  -- suma de los cargos que SÍ llegaron) ni INV15 (mira el neto de
  -- saldos_favor). Prefijo saldo:/cargo: igual que INV10, para saber a qué
  -- tabla ir.
  inv31 as (
    select 'INV31: crédito aplicado <-> cargo credito_aplicado, mismo monto (#4)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(ofensor order by ofensor))[1:10], ', '), '')::text
    from (
      select 'saldo:' || sf.id::text as ofensor
        from public.saldos_favor sf
        left join public.cargos_extra ce on ce.id = sf.cargo_id
       where sf.tenant_id = p_tenant
         and sf.tipo = 'aplicado'
         and (ce.id is null or ce.tipo <> 'credito_aplicado'
              or abs(sf.monto - ce.monto) > 0.01)
      union all
      select 'cargo:' || ce.id::text
        from public.cargos_extra ce
       where ce.tenant_id = p_tenant
         and ce.tipo = 'credito_aplicado'
         and not exists (select 1 from public.saldos_favor sf
                          where sf.cargo_id = ce.id and sf.tipo = 'aplicado')) t
  )
  -- Orden NUMÉRICO por el número de invariante. Antes ordenaba por TEXTO, que
  -- listaba INV1, INV10, INV11, INV12... INV2 — ilegible con 20, peor con 31.
  select u.invariante, u.violaciones, u.ejemplo_ids
  from (
    select * from inv1
    union all select * from inv2
    union all select * from inv3
    union all select * from inv4
    union all select * from inv5
    union all select * from inv6
    union all select * from inv7
    union all select * from inv8
    union all select * from inv9
    union all select * from inv10
    union all select * from inv11
    union all select * from inv12
    union all select * from inv13
    union all select * from inv14
    union all select * from inv15
    union all select * from inv16
    union all select * from inv17
    union all select * from inv18
    union all select * from inv19
    union all select * from inv20
    union all select * from inv21
    union all select * from inv22
    union all select * from inv23
    union all select * from inv24
    union all select * from inv25
    union all select * from inv26
    union all select * from inv27
    union all select * from inv28
    union all select * from inv29
    union all select * from inv30
    union all select * from inv31
  ) u
  order by coalesce(substring(u.invariante from 'INV([0-9]+)')::int, 0), u.invariante;
end;
$function$

