-- 0218 — CUARENTENA de cobros duplicados ("en revisión"). FUNDACIÓN SERVER.
--
-- Objetivo (pedido de Rubén, diseño aprobado): un sobrepago NO-exacto sobre una
-- cuota (típico: 2 devices de la cuenta "Oficina" cobran la misma cuota sin
-- sincronizar) NO debe inflar la caja hasta que una persona decida cuál pago es
-- el verdadero. Hoy los dos cuentan → efectivo inexistente en la ventana de
-- revisión. El guard 0214 ya auto-anula los duplicados EXACTOS; esto cubre los
-- NO exactos, poniéndolos "en revisión" (excluidos de TODA métrica) en vez de
-- dejarlos contar.
--
-- PREDICADO CANÓNICO: "pago que cuenta" = anulado=false AND en_revision=false.
-- Se aplica acá en el server (guard + recalcular + trigger 0216 + VIEW). La otra
-- mitad (queries de caja del CLIENTE + rediseño de "Cobros a revisar" por flag)
-- va en el mismo release de la app. ⚠️ NO aplicar esta migración sola: dejaría
-- el pago en revisión INVISIBLE (fuera de monto_pagado, no dispara el "Cobros a
-- revisar" derivado) pero TODAVÍA contando en los dashboards del cliente.
--
-- Co-diseñado con el fix #1 (0216): el mismo predicado en las 3 funciones que
-- suman pagos server-side.

BEGIN;

-- ── 1) Columnas (aditivas). ──────────────────────────────────────────────────
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS en_revision boolean NOT NULL DEFAULT false;
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS revision_motivo text;

-- Índice para la pantalla de revisión (busca los en_revision del tenant).
CREATE INDEX IF NOT EXISTS pagos_en_revision_idx
  ON public.pagos (tenant_id) WHERE en_revision = true;

-- ── 2) VIEW canónica (para queries server-side; el cliente filtra en Dart). ──
CREATE OR REPLACE VIEW public.pagos_contables
  WITH (security_invoker = true) AS
  SELECT * FROM public.pagos WHERE anulado = false AND en_revision = false;

-- ── 3) Guard 0214: sobrepago NO exacto → EN REVISIÓN (antes: lo dejaba contar).
-- También excluye en_revision del SUM de "ya pagado" (un pago en cuarentena no
-- cuenta para el chequeo de sobrepago del siguiente).
CREATE OR REPLACE FUNCTION public.pagos_guard_sobrepago_trg()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp' SET "TimeZone" TO 'UTC'
AS $function$
declare
  v_total_a_cobrar numeric(10,2);
  v_ya_pagado      numeric(10,2);
  v_gemelo         uuid;
begin
  if new.anulado then return new; end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(new.cuota_id);
  if v_total_a_cobrar is null then return new; end if;

  -- Excluye anulados Y en_revision (predicado canónico). El `p.id <> new.id`
  -- es por el UPSERT de PowerSync (reintento del mismo pago).
  select coalesce(sum(p.monto_cordobas), 0)
    into v_ya_pagado
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id;

  if v_ya_pagado + new.monto_cordobas <= v_total_a_cobrar + 0.01 then
    return new;  -- no excede: el 99,9%.
  end if;

  -- Excede. ¿Copia EXACTA (mismo monto + día)? → auto-anula (como 0214).
  select p.id into v_gemelo
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id
     and round(p.monto_cordobas * 100) = round(new.monto_cordobas * 100)
     and p.fecha_pago::date = new.fecha_pago::date
   order by p.fecha_pago limit 1;

  if v_gemelo is not null then
    new.anulado          := true;
    new.anulado_en       := now();
    new.anulado_por      := null;
    new.motivo_anulacion := coalesce(new.motivo_anulacion,
      'Duplicado automático: ya existe un pago idéntico en esta cuota ('||v_gemelo||')');
    return new;
  end if;

  -- Excede pero NO es copia exacta → CUARENTENA (antes: return new = contaba).
  new.en_revision    := true;
  new.revision_motivo := coalesce(new.revision_motivo,
    'Sobrepago: excede el total de la cuota. Requiere decidir cuál cobro es el verdadero.');
  return new;
end $function$;

-- ── 4) recalcular_cuota_desde_pagos: el SUM excluye en_revision. ─────────────
CREATE OR REPLACE FUNCTION public.recalcular_cuota_desde_pagos()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  if tg_table_name not in ('pagos','cargos_extra') then
    return coalesce(new, old);
  end if;
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0) into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false and en_revision = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then return coalesce(new, old); end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);
  if v_total_a_cobrar <= 0 then v_nuevo_estado := 'pagada';
  elsif v_total_pagado <= 0 then v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then v_nuevo_estado := 'parcial';
  else v_nuevo_estado := 'pagada'; end if;

  update public.cuotas
     set monto_pagado = v_total_pagado, estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;
  return coalesce(new, old);
end $function$;

-- ── 5) Trigger 0216 (cuotas_forzar_derivados): el SUM excluye en_revision. ───
CREATE OR REPLACE FUNCTION public.cuotas_forzar_derivados()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_pagado numeric(10,2); v_cargos numeric(10,2); v_total numeric(10,2);
BEGIN
  SELECT COALESCE(SUM(monto_cordobas),0) INTO v_pagado
    FROM public.pagos WHERE cuota_id=NEW.id AND anulado=false AND en_revision=false;
  NEW.monto_pagado := v_pagado;
  v_cargos := public.calcular_cargos_neto(NEW.id); NEW.cargos_neto := v_cargos;
  IF NEW.estado <> 'anulada' AND NEW.tipo_cargo_manual IS NULL THEN
    v_total := NEW.monto + COALESCE(v_cargos,0);
    IF v_total <= 0 THEN NEW.estado := 'pagada';
    ELSIF v_pagado <= 0 THEN NEW.estado := 'pendiente';
    ELSIF v_pagado < v_total THEN NEW.estado := 'parcial';
    ELSE NEW.estado := 'pagada'; END IF;
  END IF;
  RETURN NEW;
END; $fn$;

-- ── 6) RPCs server que suman pagos → excluir en_revision (predicado canónico).
-- Se hace por string-replace de la def VIGENTE (evita transcribir a mano; los
-- substrings son exactos y únicos). Guardado para no duplicar si se re-corre.
DO $$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.get_cobrador_stats'::regproc);
  IF position('p.en_revision' in v) = 0 THEN
    v := replace(v, 'and p.anulado = false',
                    'and p.anulado = false and p.en_revision = false');
    EXECUTE v;
  END IF;
END $$;

DO $$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc);
  IF position('en_revision = false group by cuota_id' in v) = 0 THEN
    -- INV2: monto_pagado = SUM(pagos que cuentan)
    v := replace(v, 'where anulado = false group by cuota_id',
                    'where anulado = false and en_revision = false group by cuota_id');
    -- INV12: recaudado por contrato = SUM(pagos que cuentan)
    v := replace(v, 'where cu2.contrato_id = ct.id and pa.anulado = false',
                    'where cu2.contrato_id = ct.id and pa.anulado = false and pa.en_revision = false');
    EXECUTE v;
  END IF;
END $$;

SELECT 'cols_ok' AS chk,
  (SELECT count(*)::text FROM information_schema.columns
    WHERE table_name='pagos' AND column_name IN ('en_revision','revision_motivo'))
UNION ALL
SELECT 'get_cobrador_stats_en_revision',
  CASE WHEN position('p.en_revision' in pg_get_functiondef('public.get_cobrador_stats'::regproc)) > 0
       THEN 'ok' ELSE 'FALTA' END
UNION ALL
SELECT 'verificar_invariantes_en_revision',
  CASE WHEN position('en_revision = false group by cuota_id' in pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc)) > 0
       THEN 'ok' ELSE 'FALTA' END;

COMMIT;
