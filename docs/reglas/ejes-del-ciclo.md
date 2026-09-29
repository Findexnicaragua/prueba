# Regla: el Resumen mide el tiempo con DOS ejes, y cada tarjeta usa uno solo

**Enunciado, en una línea.** Una tarjeta cuenta por el **VENCIMIENTO** de la
cuota (qué se factura en el ciclo) o por la **FECHA DE PAGO** (qué plata entró
en la ventana), nunca por los dos — y tiene que decir cuál usa.

| | Eje **VENCIMIENTO** | Eje **FECHA DE PAGO** |
|---|---|---|
| Tarjetas | Cobertura del ciclo · Mora del ciclo · Proyección | Caja del ciclo · Quién cobró |
| Campo | `cuotas.fecha_vencimiento` | `pagos.fecha_pago` |
| Pregunta | de lo que se FACTURA en el ciclo, ¿cuánto entró? | ¿cuánta plata entró por la ventanilla? |
| Entra si… | **vence** dentro del rango | **se pagó** dentro del rango |

Las dos son correctas. Ninguna puede adoptar el eje de la otra sin dejar de
contestar su pregunta.

**Por qué confunde: las dos se rotulan igual.** El selector dice
*"Ciclo 15 ago – 14 sep"* en ambas, y eso invita a leerlas como el mismo
conjunto de cuotas. No lo son.

**El caso concreto (2026-09-01), para no tener que reconstruirlo.** Dos cuotas
del Test Tenant que vencen el 10 y el 14 de agosto —PB-16 y PB-06, C$500 cada
una— se cobraron el **16 de agosto**:

- **Cobertura de agosto** las cuenta → fila *"después del ciclo · 2 · C$1.000"*;
- **Caja de septiembre** cuenta su plata → adentro de sus C$5.300;
- **Cobertura de septiembre** NO las tiene, porque no vencen ahí.

El dueño buscó esos C$500 entre las cuotas del ciclo de septiembre, no los
encontró, y reportó que confundía. **Los tres números eran correctos.**

**No es un caso de borde — medirlo antes de descartarlo.** En Mairena, dentro de
la ventana de un ciclo entran **1.337 cuotas por C$1.159.734** que vencen en
otros ciclos, y hay cobros de otros ciclos en **15 de los 31 días**. Es la mitad
de los días y una de cada tres cuotas cobradas.

**Dónde se ve hoy que una cuota se cobró fuera de su ciclo:**

- la **tabla** de Cobertura, en la fila *"después del ciclo"* / *"antes del
  ciclo"* dentro de Recuperado;
- la **curva**, sumado al primer o al último punto (no en la fecha real del
  pago — el eje del gráfico es el del ciclo);
- el **globo**, que en un día sin cobros del ciclo dice *"Sin cobros de **este
  ciclo**"* y suma el renglón *"de otros ciclos"*;
- el **Excel**, con la columna `Ciclo del cobro`: *"Septiembre 2026 (15 ago – 14
  sep)"*.

**Ojo al leer el índice: "Proyección" está en la tabla de arriba pero YA NO
aparece en la lista de superficies** (2026-09-02). No es una inconsistencia del
índice y no hay nada que arreglar: la tarjeta sigue midiendo por VENCIMIENTO
—es literalmente lo que muestra, "cuotas que vencen hoy"—, pero el único lugar
donde NOMBRABA el ciclo era una columna de su Excel, y ese Excel se retiró
cuando el dueño pidió volver al estilo de producción, donde la tarjeta nunca lo
tuvo. Una tarjeta puede obedecer un eje sin escribir su nombre en ningún lado.

**La función que decide el ciclo de una fecha es `periodoDe`**
(`data/utils/periodo_dashboard.dart`), y **toda** superficie tiene que usar esa
—no recalcular el corte 15→14 por su cuenta— o el archivo diría un ciclo y la
pantalla otro para la misma fecha.

**Qué NO se hizo, y por qué.** Marcar en la gráfica los días con cobros de otros
ciclos: con 15 de 31 días marcados es ruido, no referencia. Y sumar esa plata a
la curva: no pertenece al ciclo, y hacerlo contaría en septiembre una cuota de
agosto.

**Al agregar una tarjeta o un export, decir en qué eje vive.** Si mezcla los
dos, va a mostrar una cuota en un ciclo y su plata en otro sin que nadie pueda
explicar la diferencia.

**Pendiente (propuesto y no aprobado, 2026-09-01):** *Caja del ciclo* muestra su
total sin distinguir cuánto viene de cuotas de meses anteriores — en el ejemplo,
C$2.300 de sus C$5.300.

```regla
simbolos:
  periodoDe
  periodoLabel
  inicioPeriodo
  finPeriodo
  # El puente entre los dos ejes: lo que entro en la ventana y vence afuera.
  cobrosDeOtrosCiclosDiaria
  # La columna del Excel que dice en que ciclo cayo el cobro.
  _cicloDelCobro
  cicloDe
prohibido:
docs:
  ARQUITECTURA.md -> Dashboard admin, LOS DOS EJES DEL TIEMPO
  AGENTS.md -> Checklist de audit
superficies:
  ARQUITECTURA.md
  BITACORA.md
  lib/data/repositories/pagos_repo.dart
  lib/data/utils/periodo_dashboard.dart
  lib/features/admin/dashboard/caja_ciclo_card.dart
  lib/features/admin/dashboard/dashboard_export.dart
  lib/features/admin/dashboard/dashboard_query.dart
  lib/features/admin/dashboard/mora_ciclos_card.dart
  lib/features/admin/dashboard/mora_zona_card.dart
  lib/features/admin/dashboard/quien_cobro_card.dart
  lib/features/admin/dashboard/recaudo_mora_card.dart
  lib/features/admin/dashboard/tendencia_cobros_card.dart
  lib/features/admin/reportes/pdf/reporte_deuda_suspension_pdf.dart
  lib/features/admin/reportes/pdf/reporte_historial_cliente_pdf.dart
  lib/features/admin/reportes/reportes_admin_screen.dart
  lib/features/contratos/contrato_detail_pagos.dart
  lib/features/recibo/recibo_pdf.dart
  lib/features/recibo/recibo_texto_escpos.dart
  lib/features/recibo/recibo_ticket.dart
  lib/features/shared/widgets/rango_fechas_dialog.dart
  test/features/admin/dashboard/caja_ciclo_ventanas_test.dart
  test/features/admin/dashboard/dashboard_export_test.dart
  test/features/admin/dashboard/dashboard_resumen_widget_test.dart
  test/features/admin/dashboard/mora_cobertura_test.dart
  test/features/admin/dashboard/recaudo_mora_test.dart
```
