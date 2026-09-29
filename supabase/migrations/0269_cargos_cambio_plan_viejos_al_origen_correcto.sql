-- 0269 — los cargos de cambio de plan ANTERIORES a 0267 pasan a su origen real
--
-- ── El agujero ──────────────────────────────────────────────────────────────
--
-- El commit b88103c1 cerró el paso por el que la papelera borraba el cargo de un
-- cambio de plan (deshacía el cambio A MEDIAS: la cuota volvía al monto viejo y el
-- contrato se quedaba en el plan nuevo). El guard vive en `kOrigenesNoQuitables`
-- (`lib/data/repositories/cuotas_repo.dart:34`) y lo enforça el `NOT IN` de
-- `quitarCargo`, más `HojaCargosCuota.quitable`.
--
-- Pero el criterio es `origen`, y `origen = 'cambio_plan'` **sólo lo escribe el
-- código nuevo** (`contratos_repo.dart:507-521`). La migración 0267 agregó el valor
-- al CHECK y las columnas `detalle`, y NO reclasificó ninguna fila: los cargos
-- creados antes nacieron con `origen = 'cobro'` — el cajón de los manuales — así que
-- `quitable()` devuelve true y la papelera los borra igual que antes.
--
-- Audit del 2026-09-03. Medido en producción ANTES de escribir esto:
--
--   Telecable Mairena  4 filas  origen='cobro'  C$1.175,27   ← cartera REAL
--   Test Tenant        3 filas  origen='cobro'  C$1.080,00
--   Test Tenant        1 fila   origen='cambio_plan'         ← la única protegida
--
-- Las 8 tienen `pago_id IS NULL`, o sea que ninguna estaba protegida por esa vía.
--
-- ── Por qué el predicado es seguro ──────────────────────────────────────────
--
-- `descripcion` NO es texto libre acá: es el literal que escribe
-- `contratos_repo.dart:518`, y las 8 filas de la base lo tienen IDÉNTICO
-- ('Diferencia por cambio de plan'). Se piden además `origen='cobro'` y
-- `tipo='otro'` para no tocar nada más. Un cargo manual que un admin haya tipeado
-- con esa frase exacta Y ese tipo no existe hoy (verificado fila por fila).
--
-- ── Por qué NO mueve plata ──────────────────────────────────────────────────
--
-- Sólo cambia `origen`. NO toca `monto`, así que los dos triggers que recalculan
-- (`trg_cargos_extra_actualizar_neto` y `trg_cargos_extra_recalcular_cuota`)
-- recomputan EL MISMO `cuotas.cargos_neto` y el mismo saldo. INV14 (cargos_neto =
-- suma real de cargos_extra) queda satisfecho igual.
--
-- Y no lo rebota ningún guard: los dos triggers con `WHEN` sobre el origen miran
-- `NEW.origen` —`trg_cargos_ajuste_guard` con `new.origen in ('ajuste','promo')` y
-- `trg_cargos_cobro_motivo_guard` con `new.origen = 'cobro'`— y después del UPDATE
-- `NEW.origen` es 'cambio_plan', así que ninguno dispara. (Aunque disparara, el de
-- cobro sólo exige motivo para `tipo` descuento_*, y estas filas son 'otro'.)
--
-- ── Lo que NO hace, a propósito ─────────────────────────────────────────────
--
-- NO rellena `detalle` en las filas viejas. Ese JSON congela de qué plan a qué plan
-- y con qué días se prorrateó; reconstruirlo hoy sería inventar un dato con cara de
-- congelado, y la regla 18 del AGENTS lo prohíbe explícitamente ("rellenar los
-- viejos con la regla de hoy sería escribir una mentira con cara de dato").
-- `detalle IS NULL` ya está contemplado: `cargoLineaDetalle` cae al texto genérico.

begin;

-- Foto ANTES, para poder comparar en el mismo output.
do $$
declare v_antes int;
begin
  select count(*) into v_antes
    from public.cargos_extra
   where origen = 'cobro' and tipo = 'otro'
     and descripcion = 'Diferencia por cambio de plan';
  raise notice '0269 · filas a reclasificar: %', v_antes;
end $$;

update public.cargos_extra
   set origen = 'cambio_plan'
 where origen = 'cobro'
   and tipo = 'otro'
   and descripcion = 'Diferencia por cambio de plan';

-- Verificación DENTRO de la transacción: si algo quedó sin reclasificar, abortar.
do $$
declare v_quedan int; v_total int;
begin
  select count(*) into v_quedan
    from public.cargos_extra
   where origen = 'cobro' and tipo = 'otro'
     and descripcion = 'Diferencia por cambio de plan';

  select count(*) into v_total
    from public.cargos_extra where origen = 'cambio_plan';

  if v_quedan > 0 then
    raise exception '0269 ABORTA: quedaron % cargos de cambio de plan con origen=cobro', v_quedan;
  end if;

  raise notice '0269 OK · cargos con origen=cambio_plan ahora: %', v_total;
end $$;

commit;
