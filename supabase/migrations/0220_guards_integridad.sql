-- 0220 — Guards, triggers y constraints de integridad.
--
-- Cinco bloques independientes (ninguno toca DATA existente; esto es
-- PREVENCIÓN, la reparación de lo que ya está mal va en 0221):
--   (a) No desactivar un cliente que tiene deuda (regla del dueño:
--       "desactivado = sin servicio Y saldado").
--   (b) Desempaquetado del jsonb doble-encodeado de los checklists de tickets
--       (mismo patrón que 0194 para solicitudes_accion.datos).
--   (c) Guard `id <> new.id` en el correlativo de recibos: un re-upsert de
--       reintento de PowerSync renumeraba un recibo YA IMPRESO.
--   (d) Constraints baratos que hoy dan 0 violaciones (verificado con SELECT,
--       ver los conteos al pie de cada bloque).
--   (e) INV18/INV19/INV20 en `super_admin_verificar_invariantes`.
--
-- OJO: ENCODING (lección 0218 → 0219): 0218 re-creó el RPC de invariantes bajo una
-- sesión con encoding equivocado y dejó 'SuspensiÃ³n temporal' como literal de
-- COMPARACIÓN contra data → falso positivo permanente en INV11. 0219 intentó el
-- round-trip LATIN1<->UTF8 pero cayó al fallback conservador (la definición tenía
-- un '→' cuyo mojibake incluye '†' = U+2020 > 255) y solo reparó la "ó": HOY
-- siguen mojibakeados INV7 ('Ãºnico'), INV13 ('vacÃ­o') e INV16 ('ningÃºn ...
-- mÃ©todo ... crÃ©dito'), verificado con
--   SELECT count(*) FROM regexp_matches(
--     pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc),
--     chr(195), 'g');                                          -- devolvió 8
-- Por eso esta migración: (1) fuerza `client_encoding = 'UTF8'`, (2) escribe los
-- literales acentuados correctos, (3) arma el único literal que se COMPARA con
-- data ('Suspensión temporal') con chr(243) — a prueba de encoding —, y (4) no
-- vuelve a meter '→' (usa '->' ASCII) para que un round-trip futuro no falle.
SET client_encoding = 'UTF8';

BEGIN;

-- ===========================================================================
-- (a) GUARD: no desactivar un cliente con deuda.
--
-- REGLA (dueño): desactivar un cliente = ya NO tiene servicio Y está SALDADO.
-- Mientras tenga deuda debe seguir ACTIVO: así se le sigue cobrando y aparece
-- en la reportería, aunque su contrato esté cancelado.
--
-- POR QUÉ EN EL SERVER: hoy el bloqueo vive SOLO en la app
-- (`cliente_form_screen.dart` — "para no dejar deuda invisible acumulándose" —
-- y `solicitudes_repo.dart`), y además chequea otra cosa (contratos activos,
-- no deuda). Un segundo device, la aprobación de una solicitud, o cualquier
-- camino que no pase por ese form, lo saltea. El server es el chokepoint real.
--
-- OJO: POR QUÉ SOLO LA TRANSICIÓN true -> false (crítico):
-- PowerSync clasifica P0001 (RAISE EXCEPTION) como error PERMANENTE
-- (`esCodigoNoRetryable` en `connector.dart`): avisa al usuario, registra el
-- rechazo y DESCARTA la op para no trabar la cola — o sea, el device queda
-- divergente del server hasta que la fila vuelva a bajar por sync.
-- Si el guard disparara en CUALQUIER update de un cliente inactivo con deuda,
-- los ~75 clientes que HOY ya están en ese estado inválido (35 con contrato
-- activo, todos en Telecable Mairena) quedarían con TODAS sus escrituras
-- rechazadas para siempre: cambiarles el teléfono, la geo o el cobrador
-- fallaría en silencio. Con el guard atado a la transición, esos clientes
-- siguen editándose normal (old.activo = false → no hay transición) y el
-- camino de salida — REACTIVARLOS (false -> true) — nunca se bloquea.
-- La reparación de esas filas es 0221; este guard solo frena casos NUEVOS.
--
-- Alcance de "deuda": cuotas pendiente/parcial con saldo canónico > 0.01
-- (`monto + cargos_neto − monto_pagado`, invariante #10). NO se filtra por
-- estado del contrato a propósito: la deuda de un contrato cancelado sigue
-- siendo deuda y se cobra igual.
--
-- COSTO: el trigger corre en TODO update de `clientes`, y hay dos que pegan
-- fuerte — `recalc_vencimiento_mas_viejo` (0185, dispara con cada cambio de
-- cuota) y `reasignar_cobrador_masivo` (0154, bulk). Por eso el chequeo caro
-- (el count sobre cuotas) queda DESPUÉS del early-return: en esos casos el
-- trigger son dos comparaciones de booleano y se va.
--
-- ORDEN vs 0221: da igual cuál corra primero. 0221 solo hace `activo = false ->
-- true` (reactivar), que este guard nunca bloquea.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.clientes_guard_desactivar_con_deuda_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_cuotas int;
  v_saldo  numeric;
BEGIN
  -- Solo la transición ACTIVO -> INACTIVO (ver el bloque de arriba).
  IF NOT (old.activo = true AND new.activo = false) THEN
    RETURN new;
  END IF;

  SELECT count(*),
         coalesce(sum(cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado), 0)
    INTO v_cuotas, v_saldo
    FROM public.cuotas cu
   WHERE cu.cliente_id = new.id
     AND cu.estado IN ('pendiente', 'parcial')
     AND (cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado) > 0.01;

  IF v_cuotas > 0 THEN
    RAISE EXCEPTION
      'No se puede desactivar a %: tiene % cuota(s) con saldo pendiente por C$%. Un cliente desactivado no debe tener deuda: cobrale o anulá esas cuotas primero.',
      coalesce(new.nombre, '(sin nombre)'),
      v_cuotas,
      to_char(v_saldo, 'FM999999990.00');
  END IF;

  RETURN new;
END $fn$;

DROP TRIGGER IF EXISTS trg_clientes_guard_desactivar ON public.clientes;
CREATE TRIGGER trg_clientes_guard_desactivar
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_guard_desactivar_con_deuda_trg();

-- ===========================================================================
-- (b) Desempaquetado del jsonb doble-encodeado de los checklists.
--
-- MISMO BUG QUE 0194 (`solicitudes_accion.datos`): PowerSync sube el valor de
-- una columna jsonb como STRING JSON literal, y Postgres lo guarda como un
-- ESCALAR jsonb ("[]") en vez de un array. Verificado hoy: 3 de 6 `tickets` y
-- 1 de 3 `ticket_tipos` están así. El daño real es CERO porque todos los
-- corruptos están vacíos, pero es un bug LATENTE: el día que alguien guarde un
-- checklist con ítems, toda query que haga jsonb_array_elements / ->> sobre esa
-- columna revienta o devuelve nada.
--
-- SIN CHECK `jsonb_typeof(...) = 'array'` A PROPÓSITO: si el trigger se cayera
-- (un DROP accidental, un restore parcial), un CHECK haría que PowerSync
-- descartara CADA escritura de ticket en silencio — el remedio sería peor que
-- la enfermedad. El trigger repara; el CHECK castigaría.
--
-- Repara solo lo que se ESCRIBE de acá en más. Las 3+1 filas ya corruptas las
-- normaliza 0221 (reparación de datos).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fix_ticket_checklist_jsonb()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF jsonb_typeof(new.checklist) = 'string' THEN
    new.checklist := (new.checklist #>> '{}')::jsonb;
  END IF;
  RETURN new;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_fix_ticket_checklist ON public.tickets;
CREATE TRIGGER trg_fix_ticket_checklist
  BEFORE INSERT OR UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.fix_ticket_checklist_jsonb();

CREATE OR REPLACE FUNCTION public.fix_ticket_tipo_checklist_jsonb()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF jsonb_typeof(new.checklist_template) = 'string' THEN
    new.checklist_template := (new.checklist_template #>> '{}')::jsonb;
  END IF;
  RETURN new;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_fix_ticket_tipo_checklist ON public.ticket_tipos;
CREATE TRIGGER trg_fix_ticket_tipo_checklist
  BEFORE INSERT OR UPDATE ON public.ticket_tipos
  FOR EACH ROW EXECUTE FUNCTION public.fix_ticket_tipo_checklist_jsonb();

-- ===========================================================================
-- (c) `recibos_asignar_correlativo`: guard de re-upsert.
--
-- PROBLEMA: el trigger es BEFORE INSERT, y el reintento de un batch de
-- PowerSync re-manda la fila como upsert (`INSERT ... ON CONFLICT DO UPDATE`).
-- En Postgres los triggers BEFORE INSERT corren ANTES de detectar el
-- conflicto → el trigger incrementa el contador y REESCRIBE `correlativo` +
-- `numero_completo`, y el DO UPDATE guarda ese número nuevo (EXCLUDED hereda
-- el NEW post-trigger). Resultado: un recibo YA IMPRESO cambia de número en
-- cada reintento, y encima se quema un correlativo por vuelta.
--
-- FIX: si la fila ya existe (mismo id), esto NO es un recibo nuevo → conservar
-- el correlativo y el numero_completo que ya tiene y no tocar el contador. Es
-- el análogo del `id <> new.id` que `tickets_correlativo_trg` (0116) tuvo que
-- agregar por exactamente el mismo motivo ("sin esto, el RE-UPSERT de un retry
-- de PowerSync encontraba SU PROPIA fila como conflicto y renumeraba").
--
-- El cuerpo parte de la ÚLTIMA definición VIGENTE (verificada con
-- `pg_get_functiondef('public.recibos_asignar_correlativo'::regproc)`, idéntica
-- a la de 0215) — regla de AGENTS: un CREATE OR REPLACE acumulativo escrito
-- desde un cuerpo viejo PIERDE cambios en silencio (lección 0151/0152).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.recibos_asignar_correlativo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_next int;
  v_correlativo int;
  v_numero text;
BEGIN
  -- Re-upsert de reintento: la fila ya está guardada con SU número. Devolverlo
  -- tal cual (idempotente) en vez de asignar uno nuevo.
  SELECT r.correlativo, r.numero_completo
    INTO v_correlativo, v_numero
    FROM public.recibos r
   WHERE r.id = new.id;

  IF FOUND THEN
    new.correlativo := v_correlativo;
    new.numero_completo := v_numero;
    RETURN new;
  END IF;

  INSERT INTO public.recibo_correlativos (tenant_id, prefijo, ultimo)
  VALUES (new.tenant_id, new.prefijo, 1)
  ON CONFLICT (tenant_id, prefijo)
    DO UPDATE SET ultimo = public.recibo_correlativos.ultimo + 1
  RETURNING ultimo INTO v_next;

  new.correlativo := v_next;
  new.numero_completo := new.prefijo || '-' || lpad(v_next::text, 5, '0');
  RETURN new;
END;
$fn$;

-- ===========================================================================
-- (d) Constraints seguros — los 4 dan 0 violaciones HOY (verificado con):
--
--   SELECT (SELECT count(*) FROM public.pagos WHERE monto_cordobas < 0)   AS pagos_neg,          -- 0
--          (SELECT count(*) FROM public.inv_movimientos WHERE cantidad <= 0) AS mov_no_pos,      -- 0
--          (SELECT count(*) FROM public.tickets WHERE tipo_id IS NULL)    AS tickets_sin_tipo,   -- 0
--          (SELECT count(*) FROM (SELECT tenant_id, nombre FROM public.ticket_tipos
--                                  GROUP BY 1,2 HAVING count(*) > 1) d)   AS tipos_dup;          -- 0
--
-- Tamaños (el ACCESS EXCLUSIVE de cada ALTER es de milisegundos): pagos 29.036,
-- cuotas 57.005, clientes 6.096, tickets 6, ticket_tipos 3, inv_movimientos 8.
--
-- NO se agregan (a propósito):
--   · FK RESTRICT en `recibos.pago_id` / `cargos_extra.pago_id` → rompería
--     "Operaciones de datos": `0147_data_ops_funciones.sql` BORRA pagos y
--     DEPENDE de la cascada (hasta cuenta los recibos en su backup).
--   · UNIQUEs parciales en `contrato_suspensiones` / `solicitudes_accion`.
-- ===========================================================================

-- d.1 — `pagos.monto_cordobas >= 0`: es lo APLICADO a la cuota (invariante #1),
-- nunca puede ser negativo. `monto_original` y `vuelto_cordobas` ya tienen su
-- CHECK >= 0 desde el origen; el que entra a caja no lo tenía.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pagos'::regclass
                    AND conname = 'pagos_monto_cordobas_check') THEN
    ALTER TABLE public.pagos
      ADD CONSTRAINT pagos_monto_cordobas_check CHECK (monto_cordobas >= 0);
  END IF;
END $$;

-- d.2 — `ticket_tipos (tenant_id, nombre)` único. Dos tipos con el mismo nombre
-- son indistinguibles en el selector y parten el SLA/reportería en dos. Seguro
-- porque el borrado de un tipo es DELETE real (`ticket_tipos_screen.dart`, con
-- guard de "en uso"), no un soft-delete que dejaría el nombre ocupado.
-- Efecto en offline: si dos admin crean el mismo nombre sin sincronizar, el 2º
-- write se rechaza (23505 = permanente) con aviso al usuario. Es lo buscado.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.ticket_tipos'::regclass
                    AND conname = 'ticket_tipos_tenant_nombre_uq') THEN
    ALTER TABLE public.ticket_tipos
      ADD CONSTRAINT ticket_tipos_tenant_nombre_uq UNIQUE (tenant_id, nombre);
  END IF;
END $$;

-- d.3 — `inv_movimientos.cantidad > 0`. En este ledger la cantidad es una
-- MAGNITUD y la dirección la da origen/destino (stock =
-- SUM(destino) − SUM(origen)); incluso el 'ajuste' de resta se guarda positivo
-- con `ubicacion_origen_id` seteado (`inv_stock_flows.dart`). Una cantidad <= 0
-- solo puede venir de un bug y desbalancea el stock sin dejar rastro.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.inv_movimientos'::regclass
                    AND conname = 'inv_movimientos_cantidad_check') THEN
    ALTER TABLE public.inv_movimientos
      ADD CONSTRAINT inv_movimientos_cantidad_check CHECK (cantidad > 0);
  END IF;
END $$;

-- d.4 — `tickets.tipo_id NOT NULL`. El tipo define SLA, efecto (instalación/
-- corte/reconexión) y precio: un ticket sin tipo no se puede priorizar ni
-- facturar. El único INSERT del código ya lo exige
-- (`ticket_form_screen.dart:472` → "Elegí un tipo de ticket."), así que el
-- NOT NULL solo cierra el hueco de un write por REST/SQL. Re-correrlo es no-op.
ALTER TABLE public.tickets ALTER COLUMN tipo_id SET NOT NULL;

-- ===========================================================================
-- (e) `super_admin_verificar_invariantes`: se reponen INV18 y se agregan
--     INV19 + INV20.
--
-- El cuerpo parte de la ÚLTIMA DEFINICIÓN VIGENTE leída de la base
-- (`pg_get_functiondef`), NO de una migración vieja — regla de AGENTS
-- (lección 0151/0152: reescribir desde un cuerpo viejo dropea llamadas sin
-- avisar). INV1..INV17 quedan textualmente iguales salvo los acentos, que se
-- escriben BIEN (ver la nota de encoding del encabezado).
--
--   · INV18 — ya existía en `supabase/tests/invariantes_dinero.sql` pero NUNCA
--     se había agregado al RPC (divergencia entre las dos herramientas: el
--     panel del super_admin no lo chequeaba). Se repone TAL CUAL del archivo
--     canónico; verificado que hoy da 0 violaciones en toda la base. Si no se
--     lo quiere en el panel, se borra el CTE `inv18` y su línea del UNION.
--   · INV19 — NUEVO: cliente activo = false con cuotas pendientes/parciales con
--     saldo > 0. Es el estado que el guard (a) prohíbe hacia adelante; este
--     invariante lo hace VISIBLE. Hoy: 75 (69 Mairena + 6 Telenet).
--     OJO: 0221 reactiva SOLO los 35 que además tienen el contrato ACTIVO (su
--     alcance aprobado), así que después de 0221 este invariante va a seguir
--     mostrando ~40 — los que tienen el contrato suspendido/cancelado pero
--     igual deben plata. NO es que la reparación falló: es la decisión de
--     producto que quedó pendiente (ver el comentario de alcance en 0221).
--   · INV20 — NUEVO: `clientes.vencimiento_mas_viejo` divergente del valor real.
--     El predicado es EXACTAMENTE el de `recalc_vencimiento_mas_viejo` (leída
--     viva; definición vigente = 0185): MIN(fecha_vencimiento) de las cuotas
--     pendiente/parcial cuyo contrato está activo (o no tiene contrato), y la
--     comparación con IS DISTINCT FROM para que NULL = NULL no cuente como
--     violación. Hoy: 9 clientes divergentes, los 9 en Telenet.
--
-- Verificado antes de escribir esto: la query completa (los 20 CTE) se corrió
-- READ-ONLY contra Mairena y contra Telenet reemplazando `p_tenant` por el uuid.
-- Resultado: INV1..INV18 = 0 en ambos (o sea, ninguna regresión al re-crear la
-- función, y el INV11 con chr(243) ya NO da el falso positivo de 0218),
-- INV19 = 69/6 e INV20 = 0/9.
-- ===========================================================================
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
  )
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
  order by invariante;
end;
$function$;

-- ===========================================================================
-- Verificación (corre DENTRO de la transacción: si algo falta, se ve acá y se
-- puede abortar antes del COMMIT).
-- ===========================================================================
SELECT 'a_trigger_clientes' AS chk,
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid = 'public.clientes'::regclass
      AND tgname = 'trg_clientes_guard_desactivar') AS n_esperado_1
UNION ALL
SELECT 'b_trigger_tickets_checklist',
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid = 'public.tickets'::regclass
      AND tgname = 'trg_fix_ticket_checklist')
UNION ALL
SELECT 'b_trigger_ticket_tipos_checklist',
  (SELECT count(*)::text FROM pg_trigger
    WHERE tgrelid = 'public.ticket_tipos'::regclass
      AND tgname = 'trg_fix_ticket_tipo_checklist')
UNION ALL
SELECT 'c_guard_reupsert_recibos',
  CASE WHEN position('r.id = new.id' in
         pg_get_functiondef('public.recibos_asignar_correlativo'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
SELECT 'd1_pagos_monto_cordobas_check',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid = 'public.pagos'::regclass AND conname = 'pagos_monto_cordobas_check')
UNION ALL
SELECT 'd2_ticket_tipos_tenant_nombre_uq',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid = 'public.ticket_tipos'::regclass AND conname = 'ticket_tipos_tenant_nombre_uq')
UNION ALL
SELECT 'd3_inv_movimientos_cantidad_check',
  (SELECT count(*)::text FROM pg_constraint
    WHERE conrelid = 'public.inv_movimientos'::regclass AND conname = 'inv_movimientos_cantidad_check')
UNION ALL
SELECT 'd4_tickets_tipo_id_not_null',
  (SELECT CASE WHEN attnotnull THEN '1' ELSE 'FALTA' END FROM pg_attribute
    WHERE attrelid = 'public.tickets'::regclass AND attname = 'tipo_id')
UNION ALL
SELECT 'e_inv19_en_rpc',
  CASE WHEN position('INV19' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
SELECT 'e_inv20_en_rpc',
  CASE WHEN position('INV20' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
-- Los 2 literales que se COMPARAN contra data ('Suspensión temporal' en INV11,
-- 'Duplicado automático:' en INV18) tienen que haber quedado armados con chr()
-- — así son inmunes al encoding de la sesión. Se chequea que la CONSTRUCCIÓN
-- sobrevivió en el fuente (pg_get_functiondef devuelve el fuente, no el valor
-- evaluado, por eso se busca el texto 'chr(243)' y no la "ó").
SELECT 'e_inv11_literal_con_chr243',
  CASE WHEN position('chr(243)' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
SELECT 'e_inv18_literal_con_chr225',
  CASE WHEN position('chr(225)' in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN '1' ELSE 'FALTA' END
UNION ALL
-- Las ETIQUETAS visibles (INV7 'único', INV13 'vacío', INV16 'ningún/método/
-- crédito') sí van en UTF-8 directo. Si la sesión las mangleó, aparece un
-- chr(195) ('Ã') en la definición: eso es el mojibake de 0218 volviendo.
-- Si dice QUEDA-MOJIBAKE: NO commitear (ROLLBACK) y re-correr con una sesión
-- en UTF-8.
--
-- Se chequea TAMBIÉN chr(226) ('â'): todo lo acentuado del cuerpo es U+00C0..FF
-- y mangleado empieza con chr(195), pero un carácter > U+00FF (guión largo,
-- flecha, viñeta) manglea a 'â€…' — que arranca con chr(226) y el chequeo de
-- chr(195) NO lo vería. Por eso el cuerpo se escribe con '-' y '->' ASCII: un
-- char > 255 adentro es lo que hizo caer a 0219 en su fallback conservador
-- (ver la nota del encabezado). Si esto salta, hay un char alto de vuelta.
SELECT 'e_sin_mojibake',
  CASE WHEN position(chr(195) in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) = 0
        AND position(chr(226) in
         pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) = 0
       THEN '1' ELSE 'QUEDA-MOJIBAKE' END;

COMMIT;

-- ===========================================================================
-- Verificación POST-DEPLOY (correr a mano; los conteos son de HOY y bajan a
-- medida que 0221 repara los datos):
--
--   -- INV19: clientes inactivos con deuda (hoy 75 en toda la base)
--   SELECT count(*) FROM public.clientes c
--    WHERE c.activo = false
--      AND EXISTS (SELECT 1 FROM public.cuotas cu
--                   WHERE cu.cliente_id = c.id
--                     AND cu.estado IN ('pendiente','parcial')
--                     AND (cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) > 0.01);
--
--   -- INV20: vencimiento_mas_viejo divergente (hoy 9)
--   SELECT count(*) FROM public.clientes c
--    WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
--            SELECT MIN(cu.fecha_vencimiento) FROM public.cuotas cu
--              LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
--             WHERE cu.cliente_id = c.id AND cu.estado IN ('pendiente','parcial')
--               AND COALESCE(ct.estado,'activo') = 'activo');
--
--   -- El guard (a) debe RECHAZAR esto (probar con un cliente CON deuda):
--   --   UPDATE public.clientes SET activo = false WHERE id = '<uuid-con-deuda>';
--   --   → ERROR: No se puede desactivar a ...: tiene N cuota(s) ...
--   -- y debe DEJAR PASAR el update de un cliente que YA está inactivo:
--   --   UPDATE public.clientes SET telefono = telefono WHERE activo = false ...;
-- ===========================================================================

-- ===========================================================================
-- PENDIENTE — NO lo apliqué porque `supabase/tests/invariantes_dinero.sql` NO
-- es un archivo de mi propiedad en esta tanda (varios agentes en paralelo).
-- Para dejar el .sql canónico a la par del RPC hay que agregarle estos dos CTE
-- (después de `inv18`) y sus dos líneas al UNION final. Es el MISMO predicado
-- que el RPC, sin el filtro `tenant_id = p_tenant` (el archivo corre global):
--
-- ,inv19 AS (
--   SELECT 'INV19: cliente desactivado no tiene deuda pendiente' AS invariante,
--          COUNT(*) AS violaciones,
--          COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
--   FROM (
--     SELECT c.id
--     FROM public.clientes c
--     WHERE c.activo = false
--       AND EXISTS (SELECT 1 FROM public.cuotas cu
--                    WHERE cu.cliente_id = c.id
--                      AND cu.estado IN ('pendiente','parcial')
--                      AND (cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) > 0.01)
--   ) t
-- )
-- ,inv20 AS (
--   SELECT 'INV20: clientes.vencimiento_mas_viejo == el real (recalc)' AS invariante,
--          COUNT(*) AS violaciones,
--          COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
--   FROM (
--     SELECT c.id
--     FROM public.clientes c
--     WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
--             SELECT MIN(cu.fecha_vencimiento)
--               FROM public.cuotas cu
--               LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
--              WHERE cu.cliente_id = c.id
--                AND cu.estado IN ('pendiente','parcial')
--                AND COALESCE(ct.estado,'activo') = 'activo')
--   ) t
-- )
--
-- ... y en el SELECT final:
--   UNION ALL SELECT * FROM inv19
--   UNION ALL SELECT * FROM inv20
-- ===========================================================================
