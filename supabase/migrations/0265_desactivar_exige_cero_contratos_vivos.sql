-- 0265 — Desactivar un cliente exige que NO le quede ningún contrato vivo
--
-- QUE: se retira la CASCADA de 0260 (desactivar cancelaba todos los contratos
-- vivos y condonaba en bloque) y entra un GUARD que rechaza la baja mientras
-- quede un contrato en 'activo' o 'suspendido'.
--
-- REGLA (dueño, 2026-08-29): "si quieren desactivar a un cliente y todavía
-- tiene contratos activos, que se avise que no se puede hasta que no tenga.
-- Se tienen que cancelar los contratos primero, o si tiene uno en suspensión
-- que cancele totalmente la deuda o lo pase a cancelado y condone, para que
-- todo quede saldado. Todo con el procedimiento de pedir autorización."
--
-- POR QUE ES MEJOR QUE LA CASCADA: la plata se sigue condonando, pero UNA
-- FIRMA POR CONTRATO en vez de una sola firma que cubre todos juntos. Con la
-- cascada, autorizar una baja podía condonar la deuda de varios contratos que
-- el que firmaba nunca vio por separado. Es la línea general de AGENTS: quien
-- autoriza tiene que VER el número antes de firmar.
--
-- LA BAJA SIGUE PIDIENDO AUTORIZACIÓN (decisión C del dueño, 2026-08-29),
-- aunque después de este cambio ya no mueva un córdoba: dar por terminada la
-- relación con un cliente es una decisión de negocio. El peso económico de la
-- firma se mudó a cada cancelación.
--
-- ES UN GUARD DE TRANSICIÓN, NO UN CHECK — regla #13 de AGENTS, que nos costó
-- una vez (0254). Un CHECK evalúa la fila entera en CADA update y trabaría a
-- cualquier cliente histórico que lo violara; esto solo mira el paso de activo
-- a inactivo. Y contempla el UPSERT de PowerSync (regla #13b): TG_OP dice
-- 'INSERT' aunque la fila ya exista, así que un re-put de un cliente que YA
-- estaba inactivo no puede leerse como una baja nueva.
--
-- ALCANCE medido en producción ANTES de escribir esto (2026-08-30):
--   578 clientes inactivos, de los cuales 0 tienen contratos vivos → ninguno
--   queda atrapado por el guard. 259 contratos cancelados, 0 con deuda viva.
--   1.074 pagos vivos preservados en cancelados (el histórico no se toca).

begin;

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 1 — Se retira la cascada
-- ═══════════════════════════════════════════════════════════════════════════
-- Solo el TRIGGER. La función `cancelar_contratos_por_baja_cliente` se
-- conserva (queda sin llamadores) para poder revertir este cambio sin
-- reescribirla, y porque su aritmética ya está auditada. Si alguna vez se la
-- vuelve a enganchar, que sea una decisión explícita y no un descuido.
drop trigger if exists zz_clientes_baja_cancela_contratos on public.clientes;

comment on function public.cancelar_contratos_por_baja_cliente(uuid, uuid, text)
  is 'SIN USO desde 0265: la baja ya no cancela en cascada, exige que no queden '
     'contratos vivos. Se conserva para poder revertir 0265. No re-enganchar '
     'sin decisión del dueño.';

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 2 — El guard
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.clientes_guard_desactivar_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_era_activo boolean;
  v_vivos      int;
  v_activos    int;
  v_susp       int;
begin
  -- Solo interesa la transición HACIA inactivo. `is not false` cubre el NULL
  -- sin dejar el gate abierto (regla #12b: `if not <expr>` no entra con NULL).
  if new.activo is not false then return new; end if;

  if tg_op = 'UPDATE' then
    v_era_activo := old.activo;
  else
    -- INSERT: PowerSync sube los `put` como upsert, y el BEFORE INSERT dispara
    -- ANTES de detectar el conflicto → TG_OP dice 'INSERT' aunque la fila esté
    -- en la tabla (regla #13b). Se mira la fila real.
    select c.activo into v_era_activo
      from public.clientes c where c.id = new.id;
    -- No existe: es un alta real que nace inactiva. No puede tener contratos.
    if not found then return new; end if;
  end if;

  -- Ya estaba inactivo ⇒ esto no es una baja, es un re-put. Pasa.
  if v_era_activo is not true then return new; end if;

  select count(*) filter (where ct.estado = 'activo'),
         count(*) filter (where ct.estado = 'suspendido')
    into v_activos, v_susp
    from public.contratos ct
   where ct.cliente_id = new.id
     and ct.estado in ('activo', 'suspendido');

  v_vivos := coalesce(v_activos, 0) + coalesce(v_susp, 0);
  if v_vivos = 0 then return new; end if;

  -- El mensaje viaja hasta la pantalla del usuario (P0001 está en la lista de
  -- rechazos permanentes del cliente), así que dice QUÉ hacer, no solo que no.
  raise exception 'No se puede desactivar a este cliente: le quedan % contrato(s) sin cerrar (% activo(s), % suspendido(s)). Cancelalos o cobrá su deuda primero; al desactivar no puede quedar nada pendiente.',
    v_vivos, coalesce(v_activos, 0), coalesce(v_susp, 0);
end;
$fn$;

-- `zz_` a propósito: corre DESPUÉS de `trg_clientes_a_solo_notas`, que revierte
-- por columna lo que un rol sin permiso intentó cambiar. Así el guard evalúa el
-- valor FINAL de `activo` y no el que llegó crudo del device.
drop trigger if exists zz_clientes_guard_desactivar on public.clientes;
create trigger zz_clientes_guard_desactivar
  before insert or update on public.clientes
  for each row execute function public.clientes_guard_desactivar_trg();

commit;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICACIÓN POR CONTENIDO — lección 0192
-- ═══════════════════════════════════════════════════════════════════════════
-- Esperado: cascada_retirada=true, guard_puesto=true, mira_transicion=true,
-- contempla_upsert=true, atrapados=0.
select
  (not exists (select 1 from pg_trigger
                where tgrelid = 'public.clientes'::regclass
                  and tgname = 'zz_clientes_baja_cancela_contratos'))
    as cascada_retirada,
  (exists (select 1 from pg_trigger
            where tgrelid = 'public.clientes'::regclass
              and tgname = 'zz_clientes_guard_desactivar'))
    as guard_puesto,
  (select pg_get_functiondef(oid) like '%v_era_activo is not true%'
     from pg_proc where proname = 'clientes_guard_desactivar_trg')
    as mira_transicion,
  (select pg_get_functiondef(oid) like '%tg_op = ''UPDATE''%'
     from pg_proc where proname = 'clientes_guard_desactivar_trg')
    as contempla_upsert,
  (select count(*) from public.clientes cl
    where cl.activo = false
      and exists (select 1 from public.contratos ct
                   where ct.cliente_id = cl.id
                     and ct.estado in ('activo','suspendido')))
    as atrapados;
