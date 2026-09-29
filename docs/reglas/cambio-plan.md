# Regla: cambiar de plan NO crea un contrato nuevo — re-valúa el que hay

**Enunciado, en una línea.** Un contrato que cambia de plan conserva su código,
su vigencia, su día de pago y su **cantidad de cuotas**; lo único que se mueve
son los montos de las cuotas cuyo servicio **todavía no empezó**.

**Por qué existe.** El precio no vive en el contrato: vive en
`planes.precio_mensual`. Cambiar de plan es entonces un `UPDATE contratos.plan_id`
más una re-valuación de cuotas — no una cancelación seguida de un alta. Antes de
que existiera esta función, `admin_usuarios` resolvía un cambio de plan
**cancelando el contrato y creando otro**: 61 cancelaciones y 207 contratos
nuevos contra cero cambios de plan.

---

## Qué se re-valúa y qué no

Para que una cuota pase al precio nuevo tienen que darse **tres** cosas
(`contratos_repo.cambiarPlan`, paso 1):

1. `estado = 'pendiente'` — ni pagada, ni parcial, ni anulada;
2. `estadoServicio(...) == 'futuro'` — su servicio no empezó;
3. el monto nuevo difiere del viejo en ≥ 0,005.

**El corte NO mira la fecha de vencimiento: mira la ventana de servicio del
`dia_pago`** (ver [[mes-servicio]]). Con día de pago 15, la cuota de julio cubre
del 15/06 al 15/07: el 20/06 esa cuota está *en curso*, no es futura.

Consecuencias que confunden si no se saben:

- **Una cuota vencida e impaga NO se re-valúa.** Su servicio ya se prestó con el
  plan viejo. La deuda queda intacta, al precio con el que se generó. Es lo
  correcto: no se le re-cobra a nadie un mes ya servido al precio nuevo.
- **Una cuota futura con un adelanto tampoco.** Queda `parcial` o `pagada`, así
  que no pasa el filtro y **se queda al precio viejo para siempre**: ninguna
  operación posterior la vuelve a mirar. El helper `montoCuotaRevaluada` tiene un
  clamp `>= montoPagado` puesto explícitamente "por si se re-valúa una con abono
  parcial" — una red que **hoy no puede dispararse nunca**, porque el filtro del
  repo nunca le manda una. (Y su comentario cita un `CHECK monto_pagado <= monto`
  que **no existe en producción**.)
- **La mora NO bloquea el cambio**, por decisión de diseño. El diálogo avisa la
  deuda pero no frena.

---

## Los dos modos, y cuál se usa

| Modo | Qué hace con la plata | Uso real en Mairena |
|---|---|---|
| **Próximo ciclo** (default) | Nada. Solo re-valúa las futuras | **32 de 37** |
| **Hoy con prorrateo** | Ajusta los días no servidos del ciclo en curso | 5 de 37 |

En modo Hoy, la cuota **en curso** recibe el ajuste:

- **sube de plan** → un `cargos_extra` (`origen='cambio_plan'`, `tipo='otro'`)
  que SUMA a la cuota. El admin lo cobra por el flujo normal.
  🔴 **Salvo que esa cuota ya esté SALDADA** (decisión del dueño, 2026-09-03):
  ahí el cargo se asienta en la **cuota siguiente**, no sobre ella. Meterlo
  encima la reabría, y el cliente tiene un recibo en la mano que dice que ese mes
  está pagado — la regla 18 del AGENTS (el recibo es un documento emitido, no una
  vista). El prorrateo NO cambia: se sigue cobrando por los días del ciclo en
  curso; lo único que cambia es **dónde se asienta**.
  Pasó de verdad: contrato **0986** de Mairena, cuota de agosto, C$513,00
  cobrados el 25/08 con el recibo **RE-01069**, y el cambio del 28/08 la dejó
  debiendo C$49,61. Tres de los ocho cambios hechos cayeron sobre una cuota que
  ya tenía plata paga (verificado por fechas de pago vs. fecha del cargo).
  Si **no hay cuota siguiente** —contrato terminándose— la diferencia **no se
  cobra**, y queda asentado en el `op_log` del contrato con ese motivo: antes que
  falsear un recibo entregado por unos días de un contrato que cierra.
  El `detalle` congelado lleva `diferido: true` para poder explicar, dentro de
  dos años, por qué un recibo de septiembre cobra días de agosto.
  Lo avisan **las dos superficies que muestran el número antes de firmar**: el
  diálogo (`cambio_plan_dialog`) y la tarjeta del aprobador
  (`_ProrrateoSolicitud`), las dos con el MISMO criterio y el mismo epsilon que
  la mutación.
- **baja de plan** → un `saldos_favor` de tipo `acreditado`. **La cuota NO baja**:
  sigue facturando el plan anterior entero, y la diferencia queda como crédito
  que alguien tiene que aplicar a mano ([[credito-excedente]]). Se acredita
  **aunque la cuota esté impaga**: el cliente sale con un crédito por plata que
  todavía no entregó. Es el comportamiento buscado y hay un test que lo fija.

---

## 🔴 La asimetría del cálculo — lo más importante de esta ficha

**El cambio de plan es el único de los tres flujos que prorratean que MEZCLA dos
unidades de facturación.** Los otros dos son puros:

| Flujo | Qué hace con la cuota | Por qué no se pisa con el mes nominal |
|---|---|---|
| **Suspender** (R14) | **REEMPLAZA** el monto por los días consumidos | Como reemplaza, no hay doble conteo |
| **Cambiar fecha** (R13) | **AGREGA** un cargo por los días del hueco | Esos días no los cubre ninguna cuota |
| **Cambiar de plan** (R22) | **AGREGA** la diferencia de los días que faltan | Esos días **ya están adentro** de la cuota nominal |

La convención de precio-por-día (`precio ÷ días reales de SU mes`) la decidió
Rubén el **2026-06-14**, y se decidió **para el puente** — un tramo de servicio
que no tiene ninguna cuota detrás. **Nunca se decidió cómo valuar un ciclo que ya
tiene una cuota nominal encima.**

Resultado, con plan 500 → 800, día de pago 15, cambio el 20/06:

- **lo que hace la app:** cuota nominal 500 + diferencia día-a-día 245,16 = **745,16**
- **"mitad al plan viejo, mitad al nuevo":** 83,33 + 653,76 = **737,09**

Difieren en **8,07**, y el hueco **oscila entre −25,92 y +25,92** según los meses
que cruce el ciclo (un ciclo a caballo de dos meses de distinta longitud no suma
el nominal: 15 días de junio a 500/30 + 15 de julio a 500/31 = 491,94, no 500).

**Ninguno de los dos está mal; son modelos distintos.** Pero de ahí sale que:

1. **La única forma honesta de rotular el número es como la app lo calcula:**
   *"el mes completo al plan anterior, más la diferencia por los días que
   faltan"*. Decir "N días al plan viejo y M al nuevo" sería mostrar un número
   que no se cobra.
2. **Al hacer el cambio el día exacto del vencimiento**, la cuota que arranca
   recibe el prorrateo del ciclo **entero** — y eso NO da la diferencia mensual
   exacta. En un ciclo enero→febrero la cuota queda en **815,55** en vez de 800.
   Pasa un día por mes y por eso nunca se notó.

---

## Quién puede hacerlo

Llave por empresa **`cobranza.cambio_plan_habilitado`** (migración `0151`), solo
del super_admin, protegida server-side (`0085`). Nace apagada; hoy está
**encendida en los tres tenants**.

| Rol | Ve el botón | Qué hace |
|---|---|---|
| admin | sí | **ejecuta** |
| admin_cobranza · admin_usuarios | sí | **solicitan** (migración `0226`) |
| cobrador · técnico · lectura | no | — |
| super_admin | se oculta al impersonar | — |

La regla de ejecutar-vs-pedir **no mira la acción, mira el rol**
(`requiereAprobacionPara`): solo `admin` ejecuta, todos los demás piden —
incluido un rol que se agregue mañana.

**Al aprobar se usa el precio del plan de ESE momento**, no el del pedido. Por
eso la tarjeta del aprobador calcula el monto **en vivo** con el mismo helper que
la mutación: un número congelado al pedir mentiría si alguien editó el precio
mientras la solicitud esperaba.

---

## Qué queda escrito, y qué no

- El contrato con el plan nuevo, las cuotas futuras re-valuadas, el cargo o el
  crédito, y una fila de `op_log` **por cada objeto tocado**.
- **`cargos_extra.detalle` / `saldos_favor.detalle`** (migración `0267`) guardan
  la transición completa —plan viejo y nuevo con sus precios, rango de días y
  tramos por mes— porque **ese dato no se puede reconstruir después**: el
  contrato ya apunta al plan nuevo y el único rastro del viejo es un UUID en
  `op_log`, que **no se le sincroniza al cobrador**.
- **NO hay historial de planes.** El `plan_id` se pisa.
- **Los 41 cambios anteriores al 2026-09-02 no tienen `detalle`** y no se puede
  rellenar. Sus recibos se reimprimen como siempre.
- 🔴 **`origen` es lo que protege al cargo, y los viejos no lo tenían**
  (migración `0269`, 2026-09-03). El guard que impide borrar un cargo de cambio
  de plan con la papelera mira `kOrigenesNoQuitables`, o sea `origen`. Pero
  `origen='cambio_plan'` **solo lo escribe el código nuevo**, y `0267` se limitó
  a agregar el valor al CHECK: no reclasificó ninguna fila. Los cargos anteriores
  nacieron con `origen='cobro'` —el cajón de los manuales— así que seguían
  borrables. Eran **8 filas**, 4 de ellas cartera real de Mairena por
  **C$1.175,27**, todas con `pago_id` nulo. `0269` las movió a `cambio_plan`;
  solo cambia `origen`, los montos y `cargos_neto` quedan idénticos (INV14 = 0
  verificado después de correrla). **No rellena `detalle`**: reconstruirlo hoy
  sería inventar un dato con cara de congelado.
  **Lección para la próxima:** una migración que agrega un valor a un CHECK no
  reclasifica lo existente. Si algún guard del cliente discrimina por esa
  columna, el universo viejo queda afuera del guard — y medirlo filtrando por la
  columna nueva devuelve un cero tranquilizador (así conté "1 cargo" cuando
  había 8).

---

## El recibo

El cliente ve un bloque **CAMBIO DE PLAN** (`recibo_cambio_plan.dart`, los tres
renderers) con de qué plan a cuál, el mes al plan anterior, la diferencia con sus
días y su rango, el total, y la cuota desde el próximo mes.

- **SIN el desglose día por día** (decisión de Rubén, 2026-09-02): quien tiene
  que poder rehacer la multiplicación es el que **autoriza**, y para eso está la
  pantalla. Los tramos igual **se guardan**: sacarlos del papel es una decisión
  de impresión, no de datos.
- El bloque nace **visible** (a diferencia de `cuota`, apagado en los tres ISPs):
  explica un cargo que el cliente no puede deducir del total.
- ✅ **Corregido el 2026-09-03 (migración `0270`).** Nació apareciendo al **final
  de su zona** —después del total y de la mora— en los tres tenants: los bloques
  que un layout guardado no nombra se completan al final, por decisión con test
  ([`recibo_layout_test`](../../test/data/models/recibo_layout_test.dart)). El
  cliente leía el monto, después la mora, y al pie un segundo total en negrita.
  Se arregló el **dato** (los tres layouts guardados, que tenían 13 bloques de
  14), NO la regla de `fromRaw` ni el código de generación del recibo — cambiar
  esa regla movería de lugar cualquier bloque futuro en todos los tenants.
  Orden verificado hoy en los tres: `servicio → cambio_plan → cuota → totales →
  mora`. Un admin que lo reubique desde el editor gana sobre esto.
- ⚠️ **La BAJADA de plan no se dibuja en el ticket del cobrador**: su bucket de
  sync no baja `saldos_favor` (deliberado — los créditos son cosa del admin). En
  la PC del admin sí.

El recibo también **congela el nombre del plan** al emitirse
(`recibos.plan_label`, migración `0268`) — ver [[mes-servicio]].

---

## Qué NO se hizo, y por qué

- **Alinear el cálculo con el modelo "días viejos + días nuevos"** (opción C de
  la propuesta del 2026-09-02). Cerraría el hueco de ±25 córdobas, pero cambia el
  criterio con el que ya se hicieron 37 cambios en Mairena para corregir una
  diferencia que nadie reclamó. Si se hace, va en su propio sprint con mapa de
  impacto y audit.
- **Bajar `saldos_favor` al cobrador** para que el ticket muestre la bajada de
  plan. Es exponer datos nuevos en los dispositivos de campo: decisión del dueño.
- **Reconstruir el `detalle` de los 41 cambios viejos.** El plan anterior solo
  vive como UUID en `op_log`, que no llega al device que imprime.

```regla
simbolos:
  cambiarPlan
  cambio_plan_habilitado
  prorrateoCambioPlanHoy
  montoCuotaRevaluada
  TramoProrrateo
  tramosPuente
  CambioPlanDialog
  lineasCambioPlan
  fetchCambioPlan
  _ProrrateoSolicitud
prohibido:
docs:
  ARQUITECTURA.md -> Receta R22
  AGENTS.md -> Invariantes de dinero, 5
superficies:
  AGENTS.md
  ARQUITECTURA.md
  BITACORA.md
  MODULOS.md
  docs/AUDIT-INTEGRAL-2026-08-22.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  lib/data/models/solicitud_accion.dart
  lib/data/providers/aprobaciones_provider.dart
  lib/data/repositories/contratos_repo.dart
  lib/data/repositories/settings_repo.dart
  lib/data/repositories/solicitudes_repo.dart
  lib/data/utils/prorrateo.dart
  lib/features/admin/settings/settings_admin_screen.dart
  lib/features/admin/settings/settings_groups.dart
  lib/features/admin/solicitudes/solicitudes_screen.dart
  lib/features/contratos/cambio_plan_dialog.dart
  lib/features/contratos/contrato_detail_screen.dart
  lib/features/recibo/recibo_cambio_plan.dart
  lib/features/recibo/recibo_pdf.dart
  lib/features/recibo/recibo_screen.dart
  lib/features/recibo/recibo_texto_escpos.dart
  lib/features/recibo/recibo_ticket.dart
  supabase/migrations/0151_cambio_plan_setting.sql
  supabase/migrations/0226_solicitud_cambiar_plan.sql
  test/data/repositories/pagos_repo_test.dart
  test/data/repositories/permiso_cambiar_plan_test.dart
  test/data/utils/errores_test.dart
  test/data/utils/prorrateo_test.dart
```
