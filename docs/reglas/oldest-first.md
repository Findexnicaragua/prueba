# Regla: no se cobra una cuota dejando atrás otra más vieja

**Enunciado, en una línea.** Dentro de un mismo contrato no se puede cobrar una
cuota si quedó otra ANTERIOR pendiente. Se cobra de la más vieja a la más nueva.

**Dónde se enforça.** En el CLIENTE: `pagos_repo._validarOldestFirst`, que es la
red final de `registrarCobro` y `registrarCobroMultiple` —online y offline—
además de los guards de la UI que evitan que el botón aparezca. Tira
`CobroFueraDeOrdenException` y no muta nada.

**Por DECISIÓN de producto NO hay trigger en el server** (invariante #11 de
`AGENTS.md`): la data no se ingresa por SQL, así que el chokepoint del cliente
alcanza. **Límite aceptado y escrito:** dos dispositivos offline sin sincronizar
pueden violarla; lo detecta INV21 y no lo previene nadie. Si alguna vez se decide
cerrar eso, es una migración, no un cambio de Dart.

**Qué NO entra en la regla.** Los **cargos manuales** (cuota sin contrato) se
cobran en cualquier orden: no son una mensualidad, no tienen "anterior". Y el
**adelanto contiguo** está permitido: con todo lo vencido al día, se puede pagar
la cuota próxima.

**Por qué existe.** Sin esto, un cobrador cobra el mes corriente, el cliente cree
estar al día, y la deuda vieja queda escondida atrás — que es exactamente la
"deuda fantasma" que el sistema viene arrastrando desde el inicio.

**El escenario de prueba también la respeta, y ahí es fácil romperla
(2026-08-27).** Al armar la población del dashboard se diseñaron clientes que
"saltean un ciclo y siguen pagando", para darle variación a la curva. **INV21 lo
rechazó**: eso es exactamente lo que la regla prohíbe, y por la app no se puede
hacer. La variación se rehizo con clientes que dejan de pagar en ciclos
distintos — que sí la respeta, porque el que deja de pagar deja de pagar de ahí
en adelante. Vive en `supabase/escenarios/poblacion.py`, con la advertencia
escrita donde estaría la tentación de volver a agregarlo.

```regla
simbolos:
  _validarOldestFirst
  CobroFueraDeOrdenException
prohibido:
docs:
  AGENTS.md -> Invariantes de dinero, 11
  ARQUITECTURA.md -> Receta R11
superficies:
  AGENTS.md
  BITACORA.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  lib/data/repositories/pagos_repo.dart
  supabase/escenarios/poblacion.py
  supabase/migrations/0248_invariantes_21_31_en_rpc.sql
  supabase/migrations/0255_invariantes_falsos_positivos.sql
  supabase/tests/invariantes_dinero.sql
  test/data/repositories/pagos_repo_test.dart
```
