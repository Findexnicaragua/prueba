-- Triggers para mantener cuotas.monto_pagado/estado coherentes con los pagos.
-- Soft delete de pagos (anulación con auditoría) sin pérdida de histórico.
-- Recibos: permitir reemisión cuando se anula un pago.

-- =========================================================================
-- Soft delete en pagos
-- =========================================================================

alter table public.pagos add column anulado boolean not null default false;
alter table public.pagos add column anulado_en timestamptz;
alter table public.pagos add column anulado_por uuid references public.cobradores(id) on delete set null;
alter table public.pagos add column motivo_anulacion text;

-- Si anulado, los campos de auditoría deben estar presentes.
alter table public.pagos add constraint pagos_anulacion_coherencia
  check (
    anulado = false
    or (anulado_en is not null and anulado_por is not null and motivo_anulacion is not null)
  );

create index on public.pagos (tenant_id, anulado) where anulado = true;

-- =========================================================================
-- Recibos: permitir reemisión cuando un pago se anula
-- =========================================================================

-- Antes (0006): pago_id UNIQUE → un solo recibo por pago. Ahora permitimos
-- emitir un nuevo recibo si el pago previo fue anulado, manteniendo histórico.
-- Restricción nueva: a lo sumo UN recibo NO anulado por pago.
alter table public.recibos drop constraint recibos_pago_id_key;

alter table public.recibos add column anulado boolean not null default false;
alter table public.recibos add column anulado_en timestamptz;
alter table public.recibos add column anulado_por uuid references public.cobradores(id) on delete set null;

alter table public.recibos add constraint recibos_anulacion_coherencia
  check (anulado = false or (anulado_en is not null and anulado_por is not null));

create unique index recibos_pago_no_anulado_unique
  on public.recibos (pago_id)
  where anulado = false;

-- =========================================================================
-- Recibos: unique correlativo POR (cobrador, prefijo) — antes era sólo
-- (cobrador, correlativo). Si admin cambia el prefijo del cobrador y la
-- nueva secuencia arranca en 1, no colisiona con el prefijo anterior.
-- =========================================================================

drop index recibos_correlativo_por_cobrador;

create unique index recibos_correlativo_por_cobrador_prefijo
  on public.recibos (cobrador_id, prefijo, correlativo);

-- =========================================================================
-- Trigger central: recalcular cuotas.monto_pagado y estado
-- =========================================================================
-- Suma sólo pagos NO anulados. Determina el nuevo estado en base al total.
-- Respeta estado='anulada' de la cuota (no lo sobrescribe).

create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_monto_cuota numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select monto, estado
    into v_monto_cuota, v_estado_actual
    from public.cuotas
   where id = v_cuota_id;

  -- Si la cuota está anulada, no la tocamos.
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_monto_cuota then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

-- INSERT: nuevo pago → suma al total.
create trigger trg_pagos_insert_recalcular
  after insert on public.pagos
  for each row execute function public.recalcular_cuota_desde_pagos();

-- UPDATE: si cambia monto, cuota_id o anulado, recalcular.
create trigger trg_pagos_update_recalcular
  after update of monto_cordobas, cuota_id, anulado on public.pagos
  for each row execute function public.recalcular_cuota_desde_pagos();

-- DELETE: pago borrado físicamente (raro, soft delete es lo normal).
create trigger trg_pagos_delete_recalcular
  after delete on public.pagos
  for each row execute function public.recalcular_cuota_desde_pagos();
