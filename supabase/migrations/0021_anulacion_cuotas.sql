-- Anulación de cuotas con auditoría: motivo, autor y timestamp.
-- Antes la anulación solo cambiaba `estado='anulada'` sin razón.

alter table public.cuotas add column anulada_en timestamptz;
alter table public.cuotas add column anulada_por uuid
  references public.cobradores(id) on delete set null;
alter table public.cuotas add column motivo_anulacion text;

-- Coherencia: si estado='anulada', los campos de auditoría son obligatorios.
alter table public.cuotas add constraint cuotas_anulacion_coherencia
  check (
    estado <> 'anulada'
    or (anulada_en is not null and anulada_por is not null and motivo_anulacion is not null)
  );

-- =========================================================================
-- Extender el trigger de auditoría existente para capturar el motivo
-- =========================================================================

create or replace function public.audit_cuotas_anulacion_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.estado = 'anulada' and old.estado <> 'anulada' then
    perform public.audit_registrar(
      new.tenant_id, 'cuotas', new.id, 'estado',
      to_jsonb(old.estado),
      jsonb_build_object(
        'estado', new.estado,
        'motivo', new.motivo_anulacion,
        'anulada_por', new.anulada_por
      )
    );
  end if;
  return new;
end;
$$;
