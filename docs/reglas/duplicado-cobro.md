# Regla: todo cobro duplicado lo decide una persona

**Enunciado, en una línea.** Cuando un segundo cobro hace que una cuota se pase
de su total, ese cobro queda en CUARENTENA (`en_revision`) y no cuenta para nada
hasta que un admin elija cuál es el verdadero. **Sin excepciones — ni siquiera
el duplicado idéntico.**

**Dónde se enforça.** En el **server**, trigger `pagos_guard_sobrepago_trg`
(BEFORE INSERT) y su gemelo `pagos_guard_sobrepago_update_trg` (BEFORE UPDATE),
que cubre el caso de inflar un pago existente. El cliente no lo espeja: no hace
falta, porque un pago que entra en cuarentena vuelve marcado por sync y todas
las métricas ya lo excluyen.

**La rama que se SACÓ, y por qué no vuelve (migración `0264`, 2026-08-29).**
Hasta esa fecha, si el duplicado era una copia EXACTA —misma cuota, mismo monto,
mismo día— el guard lo **anulaba solo**. Se retiró porque dos cobros idénticos
**no son intercambiables**:

- cada uno tiene su **recibo**, con su **correlativo** y su **cobrador**;
- el cliente tiene **UNO de los dos papeles** en la mano, y ése es el que manda;
- el importe puede coincidir y el recibo no: cambia el **vuelto**, o uno pagó en
  **dólares** (mismo monto aplicado, entrega distinta).

Elegir por el cliente es elegir cuál comprobante queda sin respaldo. En
producción se habían resuelto así **14 cobros** sin que nadie los viera. Se
quedan como están (decisión del dueño: lo resuelto, resuelto), y conservan su
motivo `Duplicado automático:` — del que depende **INV18** y el CHECK
`pagos_anulacion_coherencia`.

**Cómo se verifica que la rama no volvió, y por qué no es un grep.** Las
migraciones son inmutables: `0214`, `0218` y `0240` conservan para siempre el
`new.anulado := true` que era correcto en su momento, así que un patrón
prohibido sobre ese texto daría hallazgos eternos — el chequeo que siempre falla
y termina ignorándose (`AGENTS.md` → checklist #14). El chequeo bueno corre
contra la **definición viva** en Postgres, y es el que `0264` deja escrito al
final de la migración:

```sql
select pg_get_functiondef(oid) not like '%new.anulado          := true%'
  from pg_proc where proname = 'pagos_guard_sobrepago_trg';   -- debe dar true
```

**El guard se excluye a sí mismo, y eso no es un detalle.** El `p.id <> new.id`
existe por el UPSERT de PowerSync: un re-put del mismo pago se contaría a sí
mismo y se mandaría a cuarentena solo. Cualquier reescritura del guard lo tiene
que conservar.

**Predicado canónico de "pago que cuenta": `anulado = false AND en_revision =
false`.** Las dos condiciones, siempre. Está en las 21 superficies de reportería
(caja, arqueo, dashboard, cobertura, mora, "quién cobró", los Excel) y es la
razón de que esta regla sea barata: un cobro en cuarentena desaparece de todas
las métricas sin tocar una sola query. `anulado = false` a secas es un bug
silencioso.

**Qué ve el que decide.** La tarjeta de cada cobro en "Cobros a revisar" muestra
**recibo, cobrador, moneda y vuelto** — los cuatro datos con los que se
distingue un papel del otro— más el `revision_motivo` que escribe el server, que
desde `0264` diferencia el duplicado idéntico ("preguntá al cliente qué recibo
tiene") del sobrepago común. Sin esos campos el admin no puede decidir con
criterio, solo adivinar.

**Resolución de la cuota y cierre de modal (UX):** Al marcar *"Este es el verdadero"*
(vía `elegirCobroVerdadero()`, que confirma el legítimo y anula los duplicados) o
al anular manualmente el último cobro en revisión de esa cuota, la hoja modal se
cierra automáticamente (`Navigator.pop()`), regresando de inmediato al admin al listado
en lugar de quedarse abierta mostrando acciones sobre registros ya procesados.

**La sección "Resueltos automáticamente" SE SACÓ (2026-08-29) y no vuelve.**
Mostraba los últimos 30 días de auto-anulados. Al retirarse la rama que los
producía quedó **estructuralmente vacía**: no puede volver a tener miembros. Es
el mismo caso que el filtro "Cancelado con deuda" — una sección permanentemente
vacía confunde más de lo que informa (`AGENTS.md` → checklist #14).

**Lo que la cuarentena NO cubre, y hay que saberlo.** El guard se dispara cuando
la cuota **se pasa** del total. Dos medios cobros que suman exacto (C$500 + C$500
sobre una cuota de C$1.000) NO lo disparan: los dos entran como buenos. Medido en
producción el 2026-08-30: **cero cuotas con dos pagos vivos**, así que la
operación real no lo produce. Si algún día aparece, el chequeo que lo cazaría es
por conteo de pagos vivos, no por monto.

```regla
simbolos:
  pagos_guard_sobrepago_trg
  pagos_guard_sobrepago_update_trg
  en_revision
  revision_motivo
  elegirCobroVerdadero
  cobrosARevisarCount
  duplicado_auto_anulado
prohibido:
  Resueltos autom | la seccion "Resueltos automaticamente" se saco el 2026-08-29 junto con la rama que la alimentaba: quedo estructuralmente vacia y una seccion que nunca puede tener miembros confunde mas de lo que informa
docs:
  AGENTS.md -> Invariantes de dinero, 7
  ARQUITECTURA.md -> Receta R17
superficies:
  AGENTS.md
  ARQUITECTURA.md
  BITACORA.md
  GUIA-TESTING-Tickets-Inventario.md
  MODULOS.md
  docs/AUDIT-INTEGRAL-2026-08-22.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  lib/data/providers/contrato_providers.dart
  lib/data/providers/dashboard_providers.dart
  lib/data/repositories/pagos_repo.dart
  lib/features/admin/cobradores/cobradores_admin_screen.dart
  lib/features/admin/dashboard/caja_ciclo_card.dart
  lib/features/admin/dashboard/dashboard_admin_screen.dart
  lib/features/admin/dashboard/dashboard_query.dart
  lib/features/admin/dashboard/quien_cobro_card.dart
  lib/features/admin/inventario/ficha_equipo_screen.dart
  lib/features/admin/inventario/inv_seriales_acciones.dart
  lib/features/admin/inventario/inventario_comun.dart
  lib/features/admin/pagos/cobros_a_revisar_screen.dart
  lib/features/admin/pagos/pagos_admin_screen.dart
  lib/features/admin/pagos/rechazos_sync_seccion.dart
  lib/features/admin/reportes/arqueo_query.dart
  lib/features/admin/reportes/reportes_admin_screen.dart
  lib/features/admin/shell/admin_shell.dart
  lib/features/admin/tickets/ticket_materiales_widget.dart
  lib/features/clientes/cliente_detail_screen.dart
  lib/features/historial/historial_screen.dart
  lib/features/historial/mis_cobros_screen.dart
  lib/features/shared/widgets/historial_op_log.dart
  lib/features/super_admin/diagnostico_screen.dart
  lib/powersync/schema.dart
  supabase/escenarios/dashboard_seed.sql
  supabase/escenarios/generar_seed_dart.py
  supabase/escenarios/generar_seed_sql.py
  supabase/migrations/0204_inventario_revision_redes_geo_ticket.sql
  supabase/migrations/0205_ticket_materiales_retiro.sql
  supabase/migrations/0214_guard_sobrepago_cuota.sql
  supabase/migrations/0216_cuotas_forzar_derivados.sql
  supabase/migrations/0218_cuarentena_en_revision.sql
  supabase/migrations/0220_guards_integridad.sql
  supabase/migrations/0224_recalcular_cuota_al_salir_de_revision.sql
  supabase/migrations/0237_rechazos_registrar.sql
  supabase/migrations/0240_bulletproof_recibos_duplicados.sql
  supabase/migrations/0243_diag_consola.sql
  supabase/migrations/0244_ops_dinero.sql
  supabase/migrations/0245_ops_dinero_hardening.sql
  supabase/migrations/0248_invariantes_21_31_en_rpc.sql
  supabase/migrations/0249_backfill_oplog_duplicados.sql
  supabase/migrations/0251_corregir_invariantes_rastro.sql
  supabase/migrations/0255_invariantes_falsos_positivos.sql
  supabase/migrations/0259_condonar_deuda_al_cancelar.sql
  supabase/migrations/0264_duplicado_identico_lo_decide_el_admin.sql
  supabase/migrations/0273_pagos_fecha_cobro.sql
  supabase/tests/invariantes_dinero.sql
  supabase/tests/probar_baja_cliente.sql
  test/features/admin/dashboard/dashboard_numeros_test.dart
  test/features/admin/dashboard/dashboard_resumen_widget_test.dart
  test/features/admin/dashboard/dashboard_tarjetas_nuevas_test.dart
  test/features/admin/dashboard/escenario_seed.dart
  test/features/admin/dashboard/mismas_cifras_tras_optimizar_test.dart
  test/features/admin/dashboard/mora_cobertura_test.dart
  test/features/admin/dashboard/rendimiento_escala_real_test.dart
  test/features/admin/pagos/cobros_a_revisar_widget_test.dart
```
