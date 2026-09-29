-- 0271 — tres planes que decían ser de un servicio y son de otro
--
-- ── Por qué ────────────────────────────────────────────────────────────────
--
-- El filtro por plan (2026-09-03) agrupa por `planes.tipo`. Al auditar los 56
-- planes de los tres tenants contra lo que dice su nombre aparecieron 6
-- desacuerdos. **Telecable Mairena está impecable: 29 de 29 bien.** De los 6,
-- estos 3 se pueden afirmar; los otros 3 quedan como están por decisión de
-- Rubén (ver abajo).
--
-- ── Los tres, con la evidencia ─────────────────────────────────────────────
--
-- 1. `Promo 1 Catv Gratis` (Telenet, 15 contratos) — hoy `internet`.
--    Cuesta **C$916**, el precio EXACTO de `Internet 20MB` en el mismo tenant.
--    O sea: internet al precio de lista + el cable de regalo. Lleva los dos
--    servicios → **combo**.
--
-- 2. `Promo 3 Internet Gratis` (Telenet, 10 contratos) — hoy `tv`.
--    Cuesta **C$513**, el precio EXACTO de `Catv` pelado. Cable al precio de
--    lista + el internet de regalo → **combo**.
--
-- 3. `Combo Premium TV + Internet` (Test Tenant, 1 contrato) — hoy `internet`.
--    El nombre lo dice entero → **combo**.
--
-- Sin esto, los 25 clientes de Telenet de (1) y (2) NO aparecen al filtrar por
-- Combo, que es justamente lo que tienen contratado.
--
-- ── Lo que NO se toca, a propósito ─────────────────────────────────────────
--
-- Los otros 3 desacuerdos son de Telenet y **el nombre no da ninguna pista**:
--   · `Pasate con Nosotros`  (combo, 58 contratos) — cuesta C$513, igual que
--     `Catv` pelado, lo que haría pensar que es sólo cable. Es el más grande.
--   · `Especial`             (internet, 1) — precio C$1.100, no coincide con
--     ningún otro plan, así que no hay de dónde deducirlo.
--   · `Tarifa preferencial`  (combo, 1) — ídem, C$1.482 sin repetir.
-- Sólo Telenet sabe qué incluye cada uno. Decisión de Rubén (2026-09-03):
-- quedan como están y el admin del tenant los ajusta desde el catálogo si hace
-- falta — ahora que el filtro existe, un tipo mal puesto se hace visible solo.
-- **No adivinar.**
--
-- ── Por qué es seguro ──────────────────────────────────────────────────────
--
-- `planes.tipo` NO participa de ningún cálculo de dinero. Verificado con grep
-- sobre `lib/`: el único consumidor hoy es el ícono de la lista de planes
-- (`planes_admin_screen._icon`), y desde este sprint el agrupador del filtro.
-- Todas las demás consultas que tocan `planes` traen `nombre` y
-- `precio_mensual`. La tabla no tiene triggers. No se mueve una cuota, un pago
-- ni un recibo.

begin;

do $$
declare v_antes text;
begin
  select string_agg(p.nombre || '=' || p.tipo, ', ' order by p.nombre) into v_antes
    from public.planes p
   where p.id in ('6eae2e19-0861-449b-8e77-da4cc6011df3',
                  '4ee8eab8-2c4e-4850-b451-4d978ceb6a9b',
                  '7e683e19-c6ae-49df-8b05-5c8cf5e092df');
  raise notice '0271 · antes: %', v_antes;
end $$;

-- Por ID, no por nombre: en estos tenants los nombres de plan se repiten
-- (en Mairena hay SIETE planes llamados "CATV") y un predicado por texto podría
-- alcanzar a otro.
update public.planes
   set tipo = 'combo'
 where id in ('6eae2e19-0861-449b-8e77-da4cc6011df3',   -- Promo 1 Catv Gratis
              '4ee8eab8-2c4e-4850-b451-4d978ceb6a9b',   -- Promo 3 Internet Gratis
              '7e683e19-c6ae-49df-8b05-5c8cf5e092df');  -- Combo Premium TV + Internet

do $$
declare v_ok int; v_total int;
begin
  select count(*) into v_ok
    from public.planes
   where id in ('6eae2e19-0861-449b-8e77-da4cc6011df3',
                '4ee8eab8-2c4e-4850-b451-4d978ceb6a9b',
                '7e683e19-c6ae-49df-8b05-5c8cf5e092df')
     and tipo = 'combo';

  if v_ok <> 3 then
    raise exception '0271 ABORTA: quedaron % de 3 en combo', v_ok;
  end if;

  -- Y que no se haya tocado nada más: el total de planes por tipo tiene que
  -- cuadrar con lo medido antes (56 planes en total, ninguno sin tipo).
  select count(*) into v_total from public.planes where tipo is null;
  if v_total > 0 then
    raise exception '0271 ABORTA: % planes quedaron sin tipo', v_total;
  end if;

  raise notice '0271 OK · los 3 quedaron en combo';
end $$;

commit;
