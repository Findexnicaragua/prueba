-- 0255_invariantes_falsos_positivos.sql
--
-- Audit Fase 4 de la tanda 0248-0254 (7 lentes + refutacion adversarial de los
-- hallazgos). Ningun invariante calculaba plata mal: lo que fallaba era el
-- SISTEMA DE MEDICION. Cuatro chequeos que dicen "cero" cuando no deberian, o
-- que van a decir "rojo" cuando todo esta bien. En un panel que es el cierre
-- no-negociable de todo fix de plata, un cero falso vale igual que un bug.
--
-- Se corrigen los CUATRO en la RPC (y en el archivo canonico, en el mismo
-- commit - no pueden volver a divergir):
--
--   INV3  -> adopta el canon del trigger `cuotas_forzar_derivados`, que es la
--            autoridad real. Cierra un bucle latente: la banda de +-0.01 propia
--            marcaba como violacion un estado que el propio server produce.
--   INV25 -> aplica el COALESCE a hoy-Nicaragua que el trigger 0234 SI hace y
--            este chequeo NO hacia, pese a jurar en su comentario que era copia
--            exacta. Es el unico de los cuatro con victimas HOY.
--   INV28 -> compara contra la caja del TENANT y no la del usuario. Devolver es
--            operacion de oficina; el predicado viejo pedia caja de calle.
--   INV29 -> saca `recibo_id`, una condicion que ningun camino del sistema
--            puede satisfacer.
--
-- EFECTO EN LOS NUMEROS (medido antes de aplicar, contra los 3 tenants):
--   INV3  0 -> 0     (arregla un latente, no cambia el presente)
--   INV28 0 -> 0     (idem)
--   INV29 0 -> 0     (idem)
--   INV25 0 -> **6** <- VERDADEROS POSITIVOS. 6 cuotas por C$6.154,00 en 3
--            contratos de Telecable Mairena, con ventana de servicio que
--            arranca en septiembre/octubre 2026 sobre contratos YA CANCELADOS.
--            Es deuda fantasma que hoy se lista como cobrable. NO se toca la
--            data en esta migracion: anular cuotas es operacion de dinero y va
--            con decision de Ruben, por el camino que ya existe
--            (`super_admin_cuota_estado_impl`, con preview, motivo y backup).
--            Hasta entonces el baseline aceptado suma INV25 = 6.
--
-- PARTIDA: pg_get_functiondef() de la definicion VIVA (0248). Los cuatro
-- bloques se reemplazan por string exacto y unico; el resto del cuerpo queda
-- byte-identico.

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
    -- CANON DEL TRIGGER (0255). Antes usaba una banda de +-0.01 propia, que
    -- NO es la de `cuotas_forzar_derivados` - el BEFORE UPDATE que decide de
    -- verdad el estado y gana siempre. La plata es numeric(10,2): el hueco mas
    -- chico posible es exactamente 0.01, y ahi los dos canon se contradecian.
    -- Una cuota a un centavo del total ES parcial para el server Y para el
    -- cliente (`cuota_estado.dart`); el falso positivo era del chequeo. Con la
    -- banda, esa fila quedaba marcada para siempre y el corrector no podia
    -- arreglarla (el trigger revertia su UPDATE). Medido: 0 filas hoy con
    -- cualquiera de los dos predicados - esto cierra un bucle latente.
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and estado is distinct from (case
                   when (monto + coalesce(cargos_neto,0)) <= 0 then 'pagada'
                   when monto_pagado <= 0 then 'pendiente'
                   when monto_pagado < (monto + coalesce(cargos_neto,0)) then 'parcial'
                   else 'pagada' end)) t
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
            -- COALESCE a HOY-Nicaragua (0255): el trigger 0234 hace
            -- exactamente esto (`COALESCE(new.cancelado_en::date, (now() -
            -- interval '6 hours')::date)`) y el chequeo no lo copiaba, aunque
            -- su comentario jurara ser copia exacta. Sin el COALESCE, los
            -- contratos cancelados SIN fecha de baja quedaban fuera del
            -- chequeo - y ahi era justo donde vivia la deuda fantasma: 37
            -- contratos sin fecha, y 6 cuotas por C$6.154 que el panel
            -- reportaba como "0 violaciones".
            -- OJO: `and b.fecha is not null` NO era el problema y borrarlo solo
            -- no arregla nada: `x > NULL` ya da NULL y la fila se excluye igual.
            -- El filtro de `tipo_cargo_manual` tambien se saca: el CTE `futuras`
            -- del trigger NO lo tiene, y esto dice ser su espejo.
            join lateral (
              select coalesce(
                       case when ct.estado = 'cancelado' then ct.cancelado_en::date
                            else (select s.suspendido_en::date from public.contrato_suspensiones s
                                   where s.contrato_id = ct.id and s.reactivado_en is null
                                   order by s.suspendido_en desc limit 1) end,
                       (now() - interval '6 hours')::date) as fecha
            ) b on true
            join public.cuotas cu on cu.contrato_id = ct.id
           where ct.tenant_id = p_tenant
             and ct.estado in ('cancelado','suspendido')
             and cu.estado = 'pendiente'
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
    -- CONTRA LA CAJA DEL TENANT, no la del usuario (0255). Antes exigia que
    -- la devolucion saliera del efectivo que ESE MISMO usuario cobro ESE MISMO
    -- dia. Eso no esta en el modelo: quien devuelve es admin/admin_cobranza
    -- (gente de oficina, por gating), y la plata sale de la caja de la oficina,
    -- no de la calle. Simulado sobre las 10 disposiciones de excedente reales:
    -- 2 habrian marcado en rojo por una operacion correcta, una de ellas de
    -- C$30.516 - y no hay corrector para INV28 ni forma de bajar la bandera.
    -- Lo que se conserva es el sentido: no puede salir mas efectivo del que
    -- entro ese dia en la empresa.
    select 'INV28: devoluciones del día <= efectivo cobrado ese día (#4 caja neta)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(clave order by clave))[1:10], ', '), '')::text
    from (select d.fecha_devolucion::text as clave
            from public.saldos_favor d
           where d.tenant_id = p_tenant
             and d.tipo = 'devuelto'
             and d.fecha_devolucion is not null
           group by d.tenant_id, d.fecha_devolucion
          having sum(d.monto) > coalesce((
                   select sum(p.monto_cordobas) from public.pagos p
                    where p.tenant_id = d.tenant_id
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
    -- SIN `recibo_id` (0255). Ese campo NO LO ESCRIBE NINGUN CAMINO del
    -- sistema: `registrarDisposicionExcedente` es el unico productor de filas
    -- 'devuelto' y no lo setea; no hay UPDATE de saldos_favor en todo lib/; el
    -- unico trigger de la tabla (no_sobregiro) no lo toca; y las 30 filas vivas
    -- tienen count(recibo_id) = 0. O sea: era una condicion IMPOSIBLE de
    -- satisfacer. La primera devolucion real dejaba INV29 en rojo permanente,
    -- con un texto en pantalla que mandaba a completar un dato que no tiene
    -- campo - y peor, tapaba su propia funcion: si TODA devolucion viola, deja
    -- de distinguir a la que de verdad es inimputable, y sin ese filo INV28
    -- vuelve a ser evadible (que es literalmente lo que INV29 previene).
    -- Queda exigiendo cobrador y fecha, que SI se escriben siempre y SI son
    -- los dos datos que sostienen el bucketing del arqueo.
    -- Emitir un recibo de devolucion es una FEATURE, no un fix de audit; si se
    -- hace, esta condicion vuelve.
    from (select sf.id
            from public.saldos_favor sf
           where sf.tenant_id = p_tenant
             and sf.tipo = 'devuelto'
             and (sf.cobrador_id is null or sf.fecha_devolucion is null)) t
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
;


-- ===========================================================================
-- EL CORRECTOR: mismo canon que el trigger + no contar lo que no cambio
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.super_admin_corregir_invariantes(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_fixed jsonb := '{}'::jsonb;
  v_count int;
  v_op_id uuid := gen_random_uuid();
  v_total int := 0;
  v_ids   uuid[];
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede ejecutar esta operación.';
  END IF;

  -- ── INV14: re-sync cargos_neto ──
  -- Va ANTES de INV3 porque el estado depende de cargos_neto.
  -- FIX F5 (2026-08-02): `calcular_cargos_neto` respeta el SIGNO (reconexión/otro
  -- suman; descuento_*/credito_aplicado restan). Antes SUM(ce.monto) sin signo.
  -- El self-join con `prev` lee el snapshot PRE-update: asi el rastro guarda el
  -- valor de ANTES, que es la mitad que sirve para revisar.
  WITH tocadas AS (
    UPDATE cuotas q
       SET cargos_neto = public.calcular_cargos_neto(q.id)
      FROM cuotas prev
     WHERE prev.id = q.id
       AND q.tenant_id = p_tenant
       AND q.estado <> 'anulada'
       AND COALESCE(q.cargos_neto, 0) <> public.calcular_cargos_neto(q.id)
    RETURNING q.id, prev.cargos_neto AS antes, q.cargos_neto AS despues
  ), cambiadas AS (
    -- BLINDAJE (0255): `RETURNING q.x` trae el valor DESPUÉS de los BEFORE
    -- triggers. Si `cuotas_forzar_derivados` revirtió lo que el corrector
    -- quiso escribir, la fila cuenta como "actualizada" pero no cambió nada.
    -- Sin este filtro se reporta un fix que no ocurrió y se estampa una fila de
    -- op_log con antes = despues en el historial de dinero de esa cuota.
    -- Cubre cualquier divergencia futura corrector/trigger, no solo la de INV3.
    SELECT * FROM tocadas WHERE antes IS DISTINCT FROM despues
  )
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
         'cuotas', t.id, NULL, 'System Admin', 'update',
         jsonb_build_object(
           'campos', jsonb_build_array(jsonb_build_object(
             'campo','cargos_neto','antes',t.antes,'despues',t.despues)),
           'resumen', jsonb_build_object('motivo',
             'Corrección automática INV14: los cargos de la cuota no sumaban '
             'lo que decía el total guardado.'))::text,
         now()
    FROM cambiadas t;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV14', v_count);
  v_total := v_total + v_count;

  -- ── INV2: re-sync monto_pagado ──
  -- Va ANTES de INV3 porque el estado depende de monto_pagado.
  -- `en_revision = false` es OBLIGATORIO: es el predicado canónico, el mismo
  -- que fuerza `cuotas_forzar_derivados` en cada escritura. Sin él, el WHERE
  -- pregunta por un valor que el trigger nunca va a dejar entrar -> la fila se
  -- "corrige" en cada pasada, sin cambiar nunca. No es plata mal escrita (el
  -- trigger la ataja): es un botón que no converge.
  WITH tocadas AS (
    UPDATE cuotas q
       SET monto_pagado = COALESCE((
             SELECT SUM(p.monto_cordobas) FROM pagos p
              WHERE p.cuota_id = q.id AND p.anulado = false
                AND p.en_revision = false), 0)
      FROM cuotas prev
     WHERE prev.id = q.id
       AND q.tenant_id = p_tenant
       AND q.estado <> 'anulada'
       AND q.monto_pagado <> COALESCE((
             SELECT SUM(p.monto_cordobas) FROM pagos p
              WHERE p.cuota_id = q.id AND p.anulado = false
                AND p.en_revision = false), 0)
    RETURNING q.id, prev.monto_pagado AS antes, q.monto_pagado AS despues
  ), cambiadas AS (
    -- BLINDAJE (0255): `RETURNING q.x` trae el valor DESPUÉS de los BEFORE
    -- triggers. Si `cuotas_forzar_derivados` revirtió lo que el corrector
    -- quiso escribir, la fila cuenta como "actualizada" pero no cambió nada.
    -- Sin este filtro se reporta un fix que no ocurrió y se estampa una fila de
    -- op_log con antes = despues en el historial de dinero de esa cuota.
    -- Cubre cualquier divergencia futura corrector/trigger, no solo la de INV3.
    SELECT * FROM tocadas WHERE antes IS DISTINCT FROM despues
  )
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
         'cuotas', t.id, NULL, 'System Admin', 'update',
         jsonb_build_object(
           'campos', jsonb_build_array(jsonb_build_object(
             'campo','monto_pagado','antes',t.antes,'despues',t.despues)),
           'resumen', jsonb_build_object('motivo',
             'Corrección automática INV2: lo pagado guardado en la cuota no '
             'coincidía con la suma de sus cobros vigentes.'))::text,
         now()
    FROM cambiadas t;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV2', v_count);
  v_total := v_total + v_count;

  -- ── INV3: re-sync estado basado en monto_pagado vs total ──
  -- CANON DEL TRIGGER (0255), no el del verificador. 0251 le dio a este bloque
  -- la banda de ±0.01 del chequeo, pero la autoridad real es
  -- `cuotas_forzar_derivados` (BEFORE UPDATE, sin WHEN), que decide sin
  -- tolerancia y gana siempre. Con la banda, una cuota a UN CENTAVO del total
  -- entraba al UPDATE, el trigger la revertía antes de tocar disco, y el botón
  -- informaba "1 corregido" sobre una fila que no cambió - el mismo bucle que
  -- 0251 vino a cerrar para INV2, reintroducido acá. El chequeo también se
  -- alinea al trigger en esta migración: los tres dicen lo mismo.
  WITH tocadas AS (
    UPDATE cuotas q
       SET estado = CASE
             WHEN q.monto + COALESCE(q.cargos_neto, 0) <= 0 THEN 'pagada'
             WHEN q.monto_pagado <= 0 THEN 'pendiente'
             WHEN q.monto_pagado < q.monto + COALESCE(q.cargos_neto, 0) THEN 'parcial'
             ELSE 'pagada'
           END
      FROM cuotas prev
     WHERE prev.id = q.id
       AND q.tenant_id = p_tenant
       AND q.estado <> 'anulada'
       AND q.tipo_cargo_manual IS NULL
       AND q.estado <> CASE
             WHEN q.monto + COALESCE(q.cargos_neto, 0) <= 0 THEN 'pagada'
             WHEN q.monto_pagado <= 0 THEN 'pendiente'
             WHEN q.monto_pagado < q.monto + COALESCE(q.cargos_neto, 0) THEN 'parcial'
             ELSE 'pagada'
           END
    RETURNING q.id, prev.estado AS antes, q.estado AS despues
  ), cambiadas AS (
    -- BLINDAJE (0255): `RETURNING q.x` trae el valor DESPUÉS de los BEFORE
    -- triggers. Si `cuotas_forzar_derivados` revirtió lo que el corrector
    -- quiso escribir, la fila cuenta como "actualizada" pero no cambió nada.
    -- Sin este filtro se reporta un fix que no ocurrió y se estampa una fila de
    -- op_log con antes = despues en el historial de dinero de esa cuota.
    -- Cubre cualquier divergencia futura corrector/trigger, no solo la de INV3.
    SELECT * FROM tocadas WHERE antes IS DISTINCT FROM despues
  )
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
         'cuotas', t.id, NULL, 'System Admin', 'update',
         jsonb_build_object(
           'campos', jsonb_build_array(jsonb_build_object(
             'campo','estado','antes',t.antes,'despues',t.despues)),
           'resumen', jsonb_build_object('motivo',
             'Corrección automática INV3: el estado de la cuota no coincidía '
             'con lo pagado.'))::text,
         now()
    FROM cambiadas t;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV3', v_count);
  v_total := v_total + v_count;

  -- ── INV17: regenerar colchón para contratos indefinidos ──
  -- Predicado IDÉNTICO al del verificador (INV17), incluido el ancla a
  -- `max(periodo pagado)`: un contrato pago por adelantado hasta diciembre
  -- necesita 3 cuotas DESPUÉS de diciembre, no después de este mes.
  -- Los ids se juntan ANTES de generar, porque después de generar el predicado
  -- ya no los selecciona y no habría a qué colgarle el rastro.
  SELECT array_agg(c.id) INTO v_ids
    FROM contratos c
   WHERE c.tenant_id = p_tenant
     AND c.duracion_meses IS NULL
     AND c.estado = 'activo'
     AND (SELECT COUNT(*) FROM cuotas q2
           WHERE q2.contrato_id = c.id
             AND q2.estado = 'pendiente'
             AND q2.tipo_cargo_manual IS NULL
             AND q2.periodo > GREATEST(
                   date_trunc('month', CURRENT_DATE)::date,
                   COALESCE((SELECT MAX(q3.periodo) FROM cuotas q3
                              WHERE q3.contrato_id = c.id
                                AND q3.estado IN ('pagada','parcial')),
                            '1900-01-01'::date))) < 3;

  v_count := COALESCE(array_length(v_ids, 1), 0);

  IF v_count > 0 THEN
    PERFORM public.generar_cuotas_contrato(t.cid) FROM unnest(v_ids) AS t(cid);

    INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                               actor_id, actor_label, accion, diff, ocurrido_en)
    SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
           'contratos', t.cid, NULL, 'System Admin', 'update',
           jsonb_build_object(
             'campos', '[]'::jsonb,
             'resumen', jsonb_build_object('motivo',
               'Corrección automática INV17: se regeneraron las cuotas futuras '
               'del contrato indefinido (colchón de 3 meses).'))::text,
           now()
      FROM unnest(v_ids) AS t(cid);
  END IF;

  v_fixed := v_fixed || jsonb_build_object('INV17', v_count);
  v_total := v_total + v_count;

  -- Resumen para el log de operaciones del Dev. Solo si tocó algo: apretar el
  -- botón sobre un tenant sano no es un evento.
  IF v_total > 0 THEN
    INSERT INTO public.data_ops_log (tenant_id, operacion, target_label,
        afectados, backup_id, actor_id, actor_label)
    VALUES (p_tenant, 'corregir_invariantes', 'INV14/INV2/INV3/INV17',
        v_fixed || jsonb_build_object('total', v_total, 'op_id', v_op_id),
        NULL, auth.uid(), 'System Admin');
  END IF;

  RETURN v_fixed;
END;
$function$;

-- ===========================================================================
-- sync_rechazos: no filtrar la identidad del super_admin al ISP
--
-- Las dos funciones resuelven el nombre con un LEFT JOIN a `cobradores` sin
-- condicion de tenant, y son SECURITY DEFINER -> el join bypassea RLS y alcanza
-- la fila del super_admin (tenant System). `sync_rechazo_descartar` escribe
-- `resuelto_por = auth.uid()` tambien cuando el que descarta es el super_admin
-- impersonando, asi que la fila queda apuntando a el.
-- `sync_rechazos_pendientes` YA ESTA VIVA en la app; `sync_rechazos_historial`
-- todavia no tiene consumidor - conviene arreglarla justamente ahora.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.sync_rechazos_historial()
 RETURNS TABLE(id uuid, tabla text, registro_id text, codigo text, mensaje text, ocurrido_en timestamp with time zone, cobrador text, cliente_codigo text, cliente_nombre text, monto numeric, recibo_numero text, pago_id text, resuelto boolean, resuelto_en timestamp with time zone, resuelto_por_nombre text, motivo text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select sr.id, sr.tabla, sr.registro_id, sr.codigo, sr.mensaje,
         sr.ocurrido_en,
         -- Mismo enmascarado que `resuelto_por_nombre`, por simetría: hoy los
         -- cobrador_id son todos del tenant de su fila (verificado), pero el
         -- join tiene la misma forma y la misma exposición.
         case when co.id is null then null
              when co.rol = 'super_admin'
                or co.tenant_id is distinct from sr.tenant_id then 'System Admin'
              else co.nombre end as cobrador,
         cl.codigo as cliente_codigo,
         cl.nombre as cliente_nombre,
         case when sr.tabla = 'pagos'
              then nullif(sr.payload->>'monto_cordobas','')::numeric
         end as monto,
         case
           when sr.tabla = 'recibos' then
             (sr.payload->>'prefijo') || '-' ||
             lpad(coalesce(sr.payload->>'correlativo','0'), 5, '0')
         end as recibo_numero,
         case when sr.tabla = 'recibos' then sr.payload->>'pago_id'
         end as pago_id,
         sr.resuelto,
         sr.resuelto_en,
         -- ENMASCARADO (0255): la función es SECURITY DEFINER, o sea que el
         -- join resuelve SIN RLS y alcanza la fila del super_admin, que vive en
         -- el tenant System. Sin esto, el admin de un ISP leería el nombre
         -- propio del dueño del SaaS atribuido a una acción sobre su plata,
         -- donde TODO el resto del sistema dice "System Admin" (la convención
         -- de op_log: actor_id NULL + actor_label 'System Admin', 848 filas).
         -- Se arregla del lado de la LECTURA: tocar el write reescribiría
         -- historia. Medido: 2 filas hoy, ambas del Test Tenant.
         case when rp.id is null then null
              when rp.rol = 'super_admin'
                or rp.tenant_id is distinct from sr.tenant_id then 'System Admin'
              else rp.nombre end as resuelto_por_nombre,
         sr.motivo
  from public.sync_rechazos sr
  left join public.cobradores co on co.id = sr.cobrador_id
  left join public.cobradores rp on rp.id = sr.resuelto_por
  left join public.cuotas cu
         on sr.tabla = 'pagos'
        and cu.id = nullif(sr.payload->>'cuota_id','')::uuid
  left join public.clientes cl on cl.id = cu.cliente_id
  where public.sync_rechazo_autorizado(sr.tenant_id)
  order by sr.ocurrido_en desc
  limit 200;
$function$;

CREATE OR REPLACE FUNCTION public.sync_rechazos_pendientes()
 RETURNS TABLE(id uuid, tabla text, registro_id text, codigo text, mensaje text, ocurrido_en timestamp with time zone, cobrador text, cliente_codigo text, cliente_nombre text, monto numeric, recibo_numero text, pago_id text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select sr.id, sr.tabla, sr.registro_id, sr.codigo, sr.mensaje,
         sr.ocurrido_en,
         -- Mismo enmascarado que `resuelto_por_nombre`, por simetría: hoy los
         -- cobrador_id son todos del tenant de su fila (verificado), pero el
         -- join tiene la misma forma y la misma exposición.
         case when co.id is null then null
              when co.rol = 'super_admin'
                or co.tenant_id is distinct from sr.tenant_id then 'System Admin'
              else co.nombre end as cobrador,
         cl.codigo as cliente_codigo,
         cl.nombre as cliente_nombre,
         case when sr.tabla = 'pagos'
              then nullif(sr.payload->>'monto_cordobas','')::numeric
         end as monto,
         case
           when sr.tabla = 'recibos' then
             (sr.payload->>'prefijo') || '-' ||
             lpad(coalesce(sr.payload->>'correlativo','0'), 5, '0')
         end as recibo_numero,
         case when sr.tabla = 'recibos' then sr.payload->>'pago_id'
         end as pago_id
  from public.sync_rechazos sr
  left join public.cobradores co on co.id = sr.cobrador_id
  left join public.cuotas cu
         on sr.tabla = 'pagos'
        and cu.id = nullif(sr.payload->>'cuota_id','')::uuid
  left join public.clientes cl on cl.id = cu.cliente_id
  where sr.resuelto = false
    and public.sync_rechazo_autorizado(sr.tenant_id)
  order by sr.ocurrido_en desc;
$function$;

NOTIFY pgrst, 'reload schema';
