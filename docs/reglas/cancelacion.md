# Regla: cancelar un contrato CONDONA la deuda

**Enunciado, en una línea.** Cancelar pone en CERO toda la deuda viva del
contrato y lo saca de las listas de cobro. Suspender hace lo OPUESTO: corta el
servicio, conserva la deuda y es reversible. *Si el cliente se va debiendo y se
le va a seguir cobrando, es SUSPENDER; si ya no se le cobra más, CANCELAR.*

**Dónde se enforça.** En el **server** (migración `0259`: el gate
`condonacion_cancelacion_aplica`, la función `condonar_deuda_contrato` y dos
triggers) y espejada en el cliente (`contratos_repo.cancelarContrato`). El
server manda, y por una razón concreta: al aprobar una solicitud el trabajo lo
ejecuta el dispositivo del aprobador, así que mientras la regla vivió solo en
Dart un equipo con build viejo aplicó la lógica anterior — 44 contratos de
Mairena quedaron con C$102.834,54 de deuda viva.

**Cómo se pone en cero (no es negociable).** Cuota sin un peso encima → anular.
Cuota **con plata aplicada** → `monto = monto_pagado`, `cargos_neto = 0`, estado
`pagada`; **anularla está prohibido**, porque el trigger de cascada mataría sus
pagos y sus recibos, o sea plata que entró a caja y un comprobante que el cliente
tiene en la mano. Cuota cuyo único pago está en cuarentena → **no se toca**.
Detalle completo: `ARQUITECTURA.md` receta R16 e invariante 6b de `AGENTS.md`.

**El número que se muestra tiene que ser el que se borra (fix 2026-08-26).**
`previewDeudaCancelacion` espeja la mutación: mismas cuotas (`pendiente`/`parcial`),
mismo saldo canónico, mismo umbral `< 0.01`, **sin clasificar por ventana de servicio y
sin prorratear**. Antes delegaba en el cálculo de *suspensión* —la regla previa al
24/08— y por eso quien autorizaba la baja veía un monto menor que el que el sistema
ponía en cero, monto que además viajaba al snapshot, al documento del cliente y a la
tarjeta del contrato. Si alguien vuelve a hacer que la cancelación reuse el cálculo de
suspensión, el test *"el snapshot cuenta TODAS las cuotas vivas… sin prorratear"* falla.
Y los rótulos se eligen **por tipo**: suspender y cancelar son opuestos, así que
"Deuda que quedaría cobrable" y "Se va a condonar" no son intercambiables.

**Un cliente DESACTIVADO no puede tener nada pendiente — y la baja es el ÚLTIMO
paso, no el primero (regla del 2026-08-29, migración `0265`).** Desactivar
**exige** que no quede ningún contrato vivo: mientras haya uno en `activo` o
`suspendido`, el server rechaza la transición
(`zz_clientes_guard_desactivar`). Primero se cierra cada contrato —cancelarlo
condona su deuda, o se le cobra lo que debe— y recién después se desactiva.

*Esto dio vuelta la regla del 2026-08-26*, que duró tres días: entre el 26 y el
29 la baja CANCELABA en cascada (`zz_clientes_baja_cancela_contratos`, `0260`) y
condonaba todo junto. Se retiró porque **una sola firma terminaba borrando la
deuda de varios contratos que el que autorizaba nunca había visto por separado**,
justo lo contrario de la línea general (*quien autoriza tiene que VER el número*).
Ahora la condonación vive donde siempre debió: en `cancelarContrato`, una firma
por contrato. La función `cancelar_contratos_por_baja_cliente` se conserva **sin
llamadores** para poder revertir `0265`; no re-engancharla sin decisión del dueño.

**El guard es de TRANSICIÓN, no un CHECK** (regla #13 de AGENTS): mira el paso de
activo a inactivo, no el estado de la fila, y contempla el UPSERT de PowerSync
(#13b) para que un re-put de un cliente que YA estaba inactivo no se lea como una
baja nueva. Verificado al aplicarlo: 578 clientes inactivos, **0** atrapados.

**La baja sigue pidiendo autorización aunque ya no mueva plata** (decisión de
Rubén, 2026-08-29): terminar la relación con un cliente es una decisión de
negocio. El peso económico de la firma se mudó a cada cancelación.
**El camino inverso NO existe a propósito:** un cliente activo sin contratos
vivos no se desactiva solo.
**Prueba end-to-end del trigger** (vive en el server, ningún test de Dart lo
alcanza): `supabase/tests/probar_baja_cliente.sql` — desactiva un cliente real,
mide y revierte todo sin escribir.

**Sin corte por fecha (migración `0261`, 2026-08-26).** La norma es universal: si
un contrato está en estado `cancelado`, no queda nada pendiente — sin importar
cuándo se canceló. El corte `cancelado_en >= 2026-08-24` que traía `0259` no
representaba ninguna regla: existía solo para proteger los **5 contratos de
Telenet** (C$19.147,81) que `0258` había preservado porque el ISP los estaba
cobrando. Rubén levantó esa protección, así que el corte se fue y esos 5 se
condonaron (23 filas de `op_log`, monto exacto). **Si alguien lo vuelve a poner,
está reviviendo una excepción que ya se decidió cerrar.** Lo que sí queda es el
flag `cobranza.cancelar_condona` como válvula explícita, y la exigencia de
`cancelado_en IS NOT NULL` (la función la usa como fecha del rastro).

**El filtro "Cancelado con deuda" SE SACÓ (2026-08-26) y no vuelve.** Era el caso
que abrió todo este hilo: ofrecía una categoría que esta regla había abolido. Se
mantuvo viva a propósito mientras existieron los 5 contratos de Telenet —era la
única forma de encontrarlos—; al condonarlos (`0261`) quedó **estructuralmente
vacía**: devolvía 0 clientes y no puede volver a tener ninguno. Recién entonces
entró como **patrón prohibido**, porque antes habría sido una alarma que suena
siempre, y esas se terminan ignorando (`AGENTS.md` → checklist #14).

**Lo que NO se sacó, y por qué.** El chip "debe C$X fuera de ruta", los dos
exports con la fila "Fuera de ruta — cancelados" y la ruta de Recuperación del
cobrador siguen incluyendo `'cancelado'` en su consulta. Hoy aportan CERO — pero
si la condonación alguna vez falla, esa deuda aparece ahí en vez de desaparecer
en silencio. Es una red, no código muerto: **no las limpies.**

**El seed del escenario tiene que nacer condonado (2026-08-27).** Un contrato
que NACE cancelado en `generar_seed_sql.py` lleva la terna `cancelado_en /
cancelado_por / motivo_cancelacion` —la exige el guard de `0254`, que también
corre en el INSERT— y sus cuotas siguen las tres ramas de arriba: sin pago →
anulada, con pago → `monto = monto_pagado` y estado `pagada`. Si no, el
escenario nace violando **INV32**.
Y el caso curado **TT-10** decía ser "CANCELADO CON DEUDA": cubría el hallazgo
*"cancelados sí suman y suspendidos no"*, que esta regla **abolió**. Describía el
mundo viejo, igual que el filtro que se sacó el 26/08 — se actualizó para cubrir
lo contrario: que su plata histórica NO desaparece.

```regla
simbolos:
  canceladoDeuda
  cancelarContrato
  revertirCancelacion
  condonar_deuda_contrato
  condonacion_cancelacion_aplica
  cancelar_condona
  cancelacion_deuda_snapshot
  motivo_cancelacion
  cancelado_en
prohibido:
  [Pp]rorrateo por cancelaci | el codigo VIEJO prorrateaba el mes en curso al cancelar y la regla del 2026-08-24 lo abolio; si ese literal vuelve a aparecer, volvio la logica vieja
  canceladoDeuda | la categoria "Cancelado con deuda" de la lista de clientes se saco el 2026-08-26: cancelar condona, asi que no puede tener miembros. Si el identificador vuelve, alguien esta reponiendo una categoria abolida
docs:
  ARQUITECTURA.md -> Receta R16
  AGENTS.md -> Invariantes de dinero, 6b
  MODULOS.md -> Contratos
superficies:
  AGENTS.md
  ARQUITECTURA.md
  BITACORA.md
  CHANGELOG-REWORK.md
  MODULOS.md
  docs/AUDIT-INTEGRAL-2026-08-22.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  docs/cuadernos/telenet-analisis-2026-08-21.md
  lib/data/models/deuda_snapshot.dart
  lib/data/models/solicitud_accion.dart
  lib/data/providers/aprobaciones_provider.dart
  lib/data/providers/contrato_providers.dart
  lib/data/repositories/contratos_repo.dart
  lib/data/repositories/solicitudes_repo.dart
  lib/features/admin/clientes/cliente_form_screen.dart
  lib/features/admin/solicitudes/solicitudes_screen.dart
  lib/features/contratos/contrato_detail_screen.dart
  lib/features/shared/widgets/solicitud_accion_helper.dart
  lib/features/super_admin/diagnostico_screen.dart
  lib/powersync/schema.dart
  supabase/escenarios/dashboard_seed.sql
  supabase/escenarios/generar_seed_sql.py
  supabase/migrations/0123_cancelacion_dinamica_suspension.sql
  supabase/migrations/0126_cancelacion_snapshot_a_text.sql
  supabase/migrations/0229_solicitudes_deuda_snapshot.sql
  supabase/migrations/0234_anular_cuotas_futuras_al_dar_de_baja.sql
  supabase/migrations/0243_diag_consola.sql
  supabase/migrations/0244_ops_dinero.sql
  supabase/migrations/0245_ops_dinero_hardening.sql
  supabase/migrations/0248_invariantes_21_31_en_rpc.sql
  supabase/migrations/0254_guard_cancelacion_atribuida.sql
  supabase/migrations/0255_invariantes_falsos_positivos.sql
  supabase/migrations/0257_backfill_cancelado_en.sql
  supabase/migrations/0258_cancelados_sin_deuda.sql
  supabase/migrations/0259_condonar_deuda_al_cancelar.sql
  supabase/migrations/0260_desactivar_cliente_cancela_y_condona.sql
  supabase/migrations/0261_condonacion_sin_corte_por_fecha.sql
  supabase/tests/invariantes_dinero.sql
  supabase/tests/probar_baja_cliente.sql
  test/data/models/deuda_snapshot_test.dart
  test/data/repositories/pagos_repo_test.dart
```
