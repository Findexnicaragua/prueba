-- Denormalizar `cobrador_id` y mantenerlo sincronizado.
--
-- PowerSync sync rules NO soportan subqueries ni JOINs. Para poder filtrar
-- contratos/cuotas por el cobrador asignado, necesitamos la columna en cada
-- tabla, replicada desde clientes.cobrador_id mediante triggers.

-- 1. Añadir columnas
alter table public.contratos add column cobrador_id uuid references public.cobradores(id);
alter table public.cuotas    add column cobrador_id uuid references public.cobradores(id);

create index on public.contratos (tenant_id, cobrador_id);
create index on public.cuotas    (tenant_id, cobrador_id);

-- 2. Backfill (las tablas están vacías ahora mismo, pero por si acaso)
update public.contratos c
set cobrador_id = cl.cobrador_id
from public.clientes cl
where c.cliente_id = cl.id;

update public.cuotas cu
set cobrador_id = cl.cobrador_id
from public.clientes cl
where cu.cliente_id = cl.id;

-- 3. Triggers: cuando se inserta un contrato/cuota, copia cobrador_id desde
--    el cliente correspondiente.
create or replace function public.set_cobrador_id_from_cliente()
returns trigger language plpgsql as $$
begin
  if new.cobrador_id is null then
    select cobrador_id into new.cobrador_id
    from public.clientes
    where id = new.cliente_id;
  end if;
  return new;
end;
$$;

create trigger trg_set_cobrador_id_contratos
before insert on public.contratos
for each row execute function public.set_cobrador_id_from_cliente();

create trigger trg_set_cobrador_id_cuotas
before insert on public.cuotas
for each row execute function public.set_cobrador_id_from_cliente();

-- 4. Trigger: cuando se REASIGNA un cliente a otro cobrador, propagar el cambio
--    a sus contratos y cuotas para que PowerSync mueva las filas al nuevo
--    cobrador en su próximo sync.
create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger language plpgsql as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;
  end if;
  return new;
end;
$$;

create trigger trg_propagate_cobrador_id_clientes
after update of cobrador_id on public.clientes
for each row execute function public.propagate_cobrador_id_from_cliente();
