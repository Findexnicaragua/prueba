-- Fixes detectados al simular el flujo end-to-end completo.
-- Bugs lógicos que sólo aparecen con datos reales corriendo.

-- =========================================================================
-- B1 — Drop constraint `cuotas_pagado_no_excede_monto`
-- =========================================================================
-- El constraint asume monto_pagado ≤ cuota.monto. Pero con cargos extra
-- (reconexión, otro), el total a cobrar es monto + suma_cargos - descuentos.
-- Caso: cuota 500 + reconexión 100 = total 600. Cliente paga 600 → trigger
-- UPDATE monto_pagado=600. Check falla, rollback de todo el cobro.

alter table public.cuotas drop constraint cuotas_pagado_no_excede_monto;

-- Nuevo constraint laxo: monto_pagado ≥ 0 (ya en la columna). El "no
-- excede" se gobierna por cuota_total_a_cobrar() en la lógica del trigger
-- de recálculo, no por un constraint estático.

-- =========================================================================
-- B3 — Off-by-one en generación de cuotas
-- =========================================================================
-- generar_cuotas_contrato sumaba `+ 1` al cálculo de meses. Resultado:
-- contrato de 1 año (fecha_inicio=may'26, fecha_fin=may'27) generaba 13
-- cuotas (incluía mayo'27 cuya cuota cubriría DESPUÉS del fin de contrato).
--
-- Comportamiento esperado: 12 cuotas (mayo'26 a abril'27 inclusive).

create or replace function public.generar_cuotas_contrato(
  p_contrato_id uuid,
  p_meses int default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_max_meses     int;
  v_creadas       int := 0;
  v_periodo       date;
  v_vencimiento   date;
  v_inserto       boolean;
begin
  select * into v_contrato from public.contratos where id = p_contrato_id;
  if not found then
    raise exception 'Contrato % no existe', p_contrato_id;
  end if;

  select cobrador_id into v_cobrador_id from public.clientes where id = v_contrato.cliente_id;
  select precio_mensual into v_precio from public.planes where id = v_contrato.plan_id;

  if p_meses is not null then
    v_max_meses := p_meses;
  elsif v_contrato.fecha_fin is null then
    v_max_meses := 3;  -- indefinido: colchón inicial
  else
    -- Cantidad de meses cubiertos = diff en meses, SIN +1.
    -- Caso 1 año: fecha_inicio=2026-05-17, fecha_fin=2027-05-17 → diff=12.
    -- Loop i=0..11 produce 12 cuotas (mayo'26 hasta abril'27).
    v_max_meses := ((extract(year from v_contrato.fecha_fin) - extract(year from v_contrato.fecha_inicio)) * 12
                  + (extract(month from v_contrato.fecha_fin) - extract(month from v_contrato.fecha_inicio)))::int;
  end if;

  for i in 0 .. v_max_meses - 1 loop
    v_periodo := (date_trunc('month', v_contrato.fecha_inicio) + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    exit when v_contrato.fecha_fin is not null and v_vencimiento >= v_contrato.fecha_fin;
    continue when v_vencimiento < v_contrato.fecha_inicio;

    insert into public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) values (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    on conflict (contrato_id, periodo) do nothing;

    get diagnostics v_inserto = row_count;
    if v_inserto then
      v_creadas := v_creadas + 1;
    end if;
  end loop;

  return v_creadas;
end;
$$;

-- =========================================================================
-- B5 — UNIQUE para evitar contratos duplicados activos por cliente+plan
-- =========================================================================

create unique index contratos_unique_activo_por_cliente_plan
  on public.contratos (cliente_id, plan_id)
  where activo = true;

-- =========================================================================
-- B7 — Columna saldo computado en cuotas, mantenida por trigger
-- =========================================================================
-- Las queries de lista usaban `monto - monto_pagado`, sin considerar cargos.
-- Esto producía un saldo distinto al que veía el cobrador en pantalla de
-- cobro. La solución más simple es persistir `cargos_neto` (suma menos
-- descuentos) en la cuota; las queries calculan saldo como
-- `monto + cargos_neto - monto_pagado`.

alter table public.cuotas add column cargos_neto numeric(10,2) not null default 0;

-- Helper: suma neta de cargos para una cuota.
create or replace function public.calcular_cargos_neto(p_cuota_id uuid)
returns numeric
language sql stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    sum(case
          when tipo in ('reconexion','otro') then monto
          when tipo in ('descuento_monto','descuento_porcentaje') then -monto
          else 0
        end
    ), 0)
    from public.cargos_extra
   where cuota_id = p_cuota_id
$$;

-- Trigger: cuando se inserta/actualiza/borra un cargo_extra, recalcular
-- cuotas.cargos_neto para la cuota afectada.
create or replace function public.cargos_extra_actualizar_neto_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);
  update public.cuotas
     set cargos_neto = public.calcular_cargos_neto(v_cuota_id)
   where id = v_cuota_id;
  return coalesce(new, old);
end;
$$;

create trigger trg_cargos_extra_actualizar_neto
  after insert or update or delete on public.cargos_extra
  for each row execute function public.cargos_extra_actualizar_neto_trg();

-- Backfill: poblar cargos_neto para cuotas existentes.
update public.cuotas
   set cargos_neto = public.calcular_cargos_neto(id);

-- =========================================================================
-- E2 — Anular cuota anula los pagos asociados automáticamente
-- =========================================================================

create or replace function public.cuotas_anular_pagos_asociados_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.estado = 'anulada' and old.estado <> 'anulada' then
    update public.pagos
       set anulado = true,
           anulado_en = coalesce(new.anulada_en, now()),
           anulado_por = new.anulada_por,
           motivo_anulacion = coalesce(
             new.motivo_anulacion || ' (cuota anulada)',
             'Cuota anulada')
     where cuota_id = new.id
       and anulado = false;
    -- Sus recibos también.
    update public.recibos
       set anulado = true,
           anulado_en = coalesce(new.anulada_en, now()),
           anulado_por = new.anulada_por
     where pago_id in (select id from public.pagos where cuota_id = new.id)
       and anulado = false;
  end if;
  return new;
end;
$$;

create trigger trg_cuotas_anular_pagos_asociados
  after update of estado on public.cuotas
  for each row execute function public.cuotas_anular_pagos_asociados_trg();

-- =========================================================================
-- E3 — Acortar fecha_fin elimina cuotas futuras pendientes excedentes
-- =========================================================================
-- Si admin acorta la duración del contrato, las cuotas pendientes cuyo
-- vencimiento sobrepasa la nueva fecha_fin deben eliminarse.
-- Sólo elimina pendientes (no pagadas ni parciales — esas son histórico).

create or replace function public.contratos_limpiar_cuotas_excedentes_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.fecha_fin is not null
     and (old.fecha_fin is null or new.fecha_fin < old.fecha_fin) then
    delete from public.cuotas
     where contrato_id = new.id
       and estado = 'pendiente'
       and fecha_vencimiento >= new.fecha_fin;
  end if;
  return new;
end;
$$;

create trigger trg_contratos_limpiar_cuotas_excedentes
  after update of fecha_fin on public.contratos
  for each row execute function public.contratos_limpiar_cuotas_excedentes_trg();

-- =========================================================================
-- E6 — cargos_extra.cobrador_id se propaga al reasignar cliente
-- =========================================================================
-- Migración 0016 propagaba a contratos/cuotas/notif pero olvidó cargos_extra.
-- Sólo propagamos cargos pendientes (cuya cuota NO está pagada/anulada).

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;

    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;

    -- cargos_extra de cuotas no pagadas también se reasignan.
    update public.cargos_extra
       set cobrador_id = new.cobrador_id
     where cuota_id in (
       select id from public.cuotas
        where cliente_id = new.id
          and estado in ('pendiente','parcial')
     );

    -- pagos / recibos NO se propagan: snapshot histórico inmutable.
  end if;
  return new;
end;
$$;
