-- Generación de cuotas al crear contrato + colchón futuro para indefinidos.
-- Reglas:
--   - Contrato con fecha_fin: se generan TODAS las cuotas del rango al crearlo.
--   - Contrato indefinido (fecha_fin=null): se generan 3 cuotas iniciales.
--   - Cron mensual mantiene un colchón de 3 meses futuros (cubre indefinidos
--     y es no-op para fijos cuyo rango ya terminó).

-- =========================================================================
-- RPC: generar cuotas para un contrato
-- =========================================================================
-- Parámetro p_meses opcional sobreescribe la lógica automática.
-- Idempotente vía ON CONFLICT (contrato_id, periodo).
-- Devuelve cantidad de cuotas creadas.

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

  -- Determinar cuántos meses iterar (límite del loop).
  if p_meses is not null then
    v_max_meses := p_meses;
  elsif v_contrato.fecha_fin is null then
    v_max_meses := 3;  -- indefinido: colchón inicial
  else
    -- diff en meses entre fecha_inicio y fecha_fin, +1 para incluir ambos extremos.
    v_max_meses := ((extract(year from v_contrato.fecha_fin) - extract(year from v_contrato.fecha_inicio)) * 12
                  + (extract(month from v_contrato.fecha_fin) - extract(month from v_contrato.fecha_inicio)))::int + 1;
  end if;

  for i in 0 .. v_max_meses - 1 loop
    v_periodo := (date_trunc('month', v_contrato.fecha_inicio) + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

    -- Fuera de rango por fecha_fin → terminar el loop.
    exit when v_contrato.fecha_fin is not null and v_periodo > v_contrato.fecha_fin;

    -- Mes anterior a la instalación (vencimiento previo a fecha_inicio) → saltar.
    -- Caso típico: instalación el 25 con día de pago 15 → mes 0 no aplica.
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
-- Trigger: al crear un contrato, generar cuotas iniciales automáticamente
-- =========================================================================

create or replace function public.contratos_generar_cuotas_iniciales_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.generar_cuotas_contrato(new.id);
  return new;
end;
$$;

create trigger trg_contratos_generar_cuotas_iniciales
  after insert on public.contratos
  for each row execute function public.contratos_generar_cuotas_iniciales_trg();

-- =========================================================================
-- Reescribir cron mensual: colchón de 3 meses
-- =========================================================================
-- Cada mes pregenera hoy + 1 + 2 meses adelante. ON CONFLICT do nothing
-- hace que la operación sea no-op para los meses que ya tienen cuotas
-- (contratos fijos cuyo rango ya cubre todo). Para indefinidos siempre
-- queda colchón de 3 meses adelante.

select cron.unschedule('generar_cuotas_mensual');
select cron.schedule(
  'generar_cuotas_mensual',
  '5 6 1 * *',
  $$
    select public.generar_cuotas_mes(
      t.id,
      (current_date + (n || ' months')::interval)::date
    )
    from public.tenants t
    cross join generate_series(0, 2) as n;
  $$
);
