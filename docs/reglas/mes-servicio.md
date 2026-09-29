# Regla: el mes de una cuota se ancla al DÍA DE PAGO, no al calendario

**Enunciado, en una línea.** Toda lógica que prorratee o clasifique servicio
—suspensión, cambio de fecha, "qué cubre esta cuota al día X", la etiqueta del mes
en pantalla— usa la **ventana de servicio del `dia_pago`**, NUNCA el mes calendario.

**Las funciones que la implementan** viven en `data/utils/prorrateo.dart`:
`ventanaServicio` (inicio y fin del ciclo de una cuota), `estadoServicio`
(cumplido / en curso / futuro respecto de una fecha), `montoPuente` y `diasPuente`
(el prorrateo por días consumidos). La etiqueta que ve el usuario la arma
`Fmt.mesServicioLabel`.

**Por qué es tan fácil de romper: con `dia_pago = 1` el bug es INVISIBLE.** Ahí la
ventana de servicio y el mes calendario coinciden, así que un cálculo anclado al
calendario da bien. Con cualquier otro día —que es el caso normal— sub-cobra o
sobre-cobra. Así se escapó el bug de 2026-06-16, y los audits anteriores no lo
vieron porque verificaron que la aritmética cerrara sin cuestionar el ancla.
**Al probar cualquier cosa que toque períodos, usar `dia_pago ≠ 1`.**

**El corte del dashboard es OTRA cosa y no hay que confundirlos.** El Resumen usa
una ventana administrativa 15→14 (`data/utils/periodo_dashboard.dart`), que es un
corte del tenant, no el ancla del `dia_pago`. Con `dia_pago = 25`, la cuota de
junio vence el 25/06 y cae en el ciclo "julio" del dashboard. Atribuirla al mes
calendario le muestra al dueño el número en el mes equivocado.

**El RECIBO congela su mes al emitirse (migración `0262`, 2026-08-26).** Hasta
esa fecha `recibos` no guardaba el rótulo: cada impresión lo recalculaba, así que
**una reimpresión posterior a un cambio de regla contradecía el papel del
cliente**. Caso que lo destapó: el recibo **HL-00230** de Telecable Mairena
(cliente R20014) está en manos del cliente diciendo *"Julio 2026"* y la app
muestra *"Junio 2026"* para ESE MISMO recibo — mismo cobro, misma plata, el
correlativo se usó una sola vez. Y no era raro que pasara: **esta regla cambió
3+ veces en 2026** (`927d762` umbral 14/15 · `72173a5` mes del período ·
`b8aba57` vuelta al mes de servicio, las dos últimas con 19 horas de diferencia).

Cómo funciona ahora: `pagos_repo._labelsCongelados` calcula el rótulo dentro
del `writeTransaction` del cobro y lo escribe en `recibos.periodo_label`; los tres
renderers (`recibo_ticket`, `recibo_pdf`, `recibo_texto_escpos`) lo prefieren
sobre el cálculo. **`NULL` siempre es seguro**: significa "recibo anterior al
congelamiento, o sin período impreso (cuota manual / puente)" y hace que el
renderer calcule, exactamente como antes.

**Y el PLAN se congela igual, por lo mismo (migración `0268`, 2026-09-02).** El
recibo resolvía el nombre del plan por JOIN al plan **vivo** del contrato, así que
el día que un contrato cambiaba de plan, **todos sus recibos anteriores pasaban a
decir el plan nuevo** — la reimpresión del papel que el cliente guardó incluida.
Un cliente que pagó junio en Básico 5 Megas veía su recibo de junio diciendo Fibra
10 Megas. No es teórico: 37 cambios de plan en Telecable Mairena entre el 22/08 y
el 01/09, cada uno reescribiendo en silencio los recibos viejos de su contrato.
Se cierra con `recibos.plan_label`, escrito por el mismo helper —que por eso pasó
de `_periodoLabelCongelado` a `_labelsCongelados`, y devuelve los dos rótulos de
la misma consulta— y leído por los tres renderers como `plan_label ?? plan_nombre`.
**Los tres caminos que emiten recibos lo congelan**: cobro simple, cobro múltiple
(cada recibo congela SU plan, así que un múltiple que cruza un cambio de plan
puede legítimamente imprimir planes distintos) y el recibo del **puente**, que
omite la fila Período pero sí imprime Servicio.

**Y el CATÁLOGO DE PLANES es superficie de esta regla desde el 2026-09-03.** El
congelado protege a los recibos NUEVOS, pero los viejos siguen resolviendo el
nombre por JOIN vivo — al 2026-09-03 son **33.949 de 33.951** en producción,
porque `0268` recién entró. O sea que **renombrar un plan reescribe lo que dicen
esos papeles**. Por eso el formulario de planes
(`planes_admin_screen._contarRecibosExpuestos`) cuenta los recibos de ese plan
con `plan_label IS NULL` y lo avisa con el número exacto **antes** de guardar.
No se bloquea: hay tipeos reales que corregir —`INTERNT+CATV (Hotel)` existe en
Mairena—, pero nadie lo hace sin saber a cuántos papeles alcanza. El número baja
solo con el tiempo: los recibos nuevos ya nacen congelados.
(Lo contrario vale para el PRECIO: no se imprime en el recibo y no toca las
cuotas ya generadas, así que ahí el aviso dice justo eso para no frenar un
aumento de tarifa.)

**Regla que se desprende:** todo dato del recibo que salga de un JOIN a una tabla
que alguien puede editar después es un candidato a este mismo bug. El mes y el
plan ya están congelados; el nombre de la empresa, la dirección y el nombre del
cobrador **no**, y hoy se resuelven vivos.

**Dos cosas de ese helper que NO se pueden tocar:**
1. **No puede lanzar.** Corre dentro de la transacción del cobro: una excepción
   ahí le impide COBRAR al cobrador. Va envuelto en `try/catch` y usa
   `DateTime.tryParse`. El rótulo es cosmético; la plata no. Hay un test que lo
   fija (*"un período impagable NO rompe el cobro"*).
2. **Espeja el criterio `esManual` de los renderers** (`plan_nombre == null`): una
   cuota sin plan no imprime período, así que congelarle uno sería inventarlo.

**Los NULL viejos NO se rellenan, y es deliberado.** Para los ~49 recibos impresos
dentro de la ventana del 31/07–01/08 el rótulo de hoy NO es el que dice su papel,
y el original no quedó guardado en ningún lado. Backfillear con la regla vigente
sería escribir una mentira con cara de dato.

**La bandeja de aprobación también ancla acá (2026-09-02).** La tarjeta de una
solicitud de cambio de plan calcula **en vivo** el monto del prorrateo que el
admin está por autorizar, y para encontrar la cuota del ciclo en curso usa
`estadoServicio` + `servicioFin` igual que el repo
(`solicitudes_screen.dart`, `_ProrrateoSolicitud`). Se calcula en vivo y **no**
se lee de la solicitud a propósito: al aprobar, el repo relee el precio del plan
de ESE momento, así que un número congelado al pedir mentiría si alguien editó
el precio mientras la solicitud esperaba. Consecuencia para esta regla: **si el
ancla cambia, esa tarjeta cambia con ella** — y si divergiera del repo, el admin
estaría firmando un número distinto del que se aplica, que es exactamente lo que
la regla de la casa prohíbe.

**Señal de alarma en una revisión:** `DateTime(y, m, 1)`, `date(periodo) = date(mesX)`
o cualquier `date_trunc('month', ...)` sobre una fecha de cuota. Ninguno de los
tres respeta la ventana.

```regla
simbolos:
  ventanaServicio
  estadoServicio
  montoPuente
  diasPuente
  mesServicioLabel
  # El rotulo congelado del recibo (0262): sin estos simbolos el indice no
  # llevaba ni a los tres renderers ni al repo que lo escribe.
  periodo_label
  periodoRecibo
  # 0268 congelo tambien el PLAN, por el mismo motivo y con el mismo patron: el
  # JOIN resolvia el plan VIVO, asi que un cambio de plan reescribia el plan que
  # decian todos los recibos anteriores del contrato. Los dos rotulos salen del
  # mismo helper, que por eso dejo de llamarse _periodoLabelCongelado.
  plan_label
  _labelsCongelados
prohibido:
docs:
  ARQUITECTURA.md -> §3.5 (2) El ancla del día_pago
  AGENTS.md -> Checklist de audit, 1c
superficies:
  AGENTS.md
  ARQUITECTURA.md
  BITACORA.md
  MODULOS.md
  TESTING.md
  docs/AUDIT-INTEGRAL-2026-08-22.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  docs/traspaso/TRASPASO.md
  lib/data/repositories/contratos_repo.dart
  lib/data/repositories/pagos_repo.dart
  lib/data/utils/formatters.dart
  lib/data/utils/prorrateo.dart
  lib/features/admin/clientes/clientes_admin_screen.dart
  lib/features/admin/pagos/cobros_a_revisar_screen.dart
  lib/features/admin/planes/planes_admin_screen.dart
  lib/features/admin/reportes/pdf/reporte_deuda_suspension_pdf.dart
  lib/features/admin/solicitudes/solicitudes_screen.dart
  lib/features/clientes/cliente_detail_screen.dart
  lib/features/cobro/cambio_fecha_dialog.dart
  lib/features/cobro/cobro_screen.dart
  lib/features/contratos/cambio_plan_dialog.dart
  lib/features/contratos/contrato_detail_cuotas.dart
  lib/features/contratos/contrato_detail_pagos.dart
  lib/features/cuotas/cuotas_list_screen.dart
  lib/features/mapa/mapa_screen.dart
  lib/features/recibo/recibo_pdf.dart
  lib/features/recibo/recibo_screen.dart
  lib/features/recibo/recibo_texto_escpos.dart
  lib/features/recibo/recibo_ticket.dart
  lib/features/shared/widgets/deuda_contrato_bloque.dart
  lib/powersync/schema.dart
  supabase/escenarios/dashboard_seed.sql
  supabase/escenarios/generar_seed_sql.py
  supabase/migrations/0262_recibo_congela_el_periodo.sql
  supabase/migrations/0268_recibo_congela_el_plan.sql
  test/data/repositories/pagos_repo_test.dart
  test/data/utils/formatters_test.dart
  test/data/utils/prorrateo_test.dart
```
