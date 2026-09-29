# Regla: el crédito a favor NO es un pago

**Enunciado, en una línea.** Cuando un cliente pagó por adelantado un servicio que
no se le va a prestar, ese excedente se le acredita como **saldo a favor** — y eso
**no toca `pagos`**, así que no aparece en ninguna métrica de caja.

**Cómo se mueve.** Vive en la tabla `saldos_favor`, un libro **append-only**:
`acreditado` (+) contra `aplicado` / `devuelto` / `condonado` / `revertido`, y el
`disponible` es la resta. **Aplicarlo** a una cuota no crea un pago: crea un
`cargos_extra` de tipo `credito_aplicado` que RESTA del saldo canónico, igual que
un descuento.

**Por qué NO es un pago, y por qué esto importa.** Meterlo en `pagos` rompía unos
15 agregados de caja: el arqueo, el dashboard y los reportes cuentan
`SUM(pagos.monto_cordobas)` de pagos vivos, y el crédito es plata que YA entró en
un período anterior. Contarla otra vez sería contar dos veces el mismo peso.
**Consecuencia directa (invariante #4 de `AGENTS.md`):** desde que existe el
crédito, `recaudado_caja` y `cobertura_cuota` **dejaron de coincidir** — la
cobertura incluye el descuento por crédito, la caja no. Antes de eso daban igual,
y por eso todavía hay quien las trata como sinónimos.

**Las tres salidas del excedente, y ninguna es automática.** Al suspender o
cancelar, admin/admin_cobranza deciden: **acreditar** (queda a favor del CLIENTE,
no caduca, sirve para cualquier contrato suyo), **devolver** (efectivo, sale de
caja y por eso SÍ se resta del neto del arqueo) o **condonar** (queda en caja).
Gateado por el setting super-only `cobranza.credito_excedente`.

**Lo que hay que cuidar al condonar una deuda** (ver [[cancelacion]]): si una cuota
tiene un `credito_aplicado` y esa cuota se anula, el crédito queda **consumido
contra algo que ya no existe** — el cliente pierde plata suya y **ningún invariante
lo levanta**. El tratamiento correcto es una fila `revertido` en `saldos_favor`,
que hoy solo hace el revert desde Dart.

**A QUÉ cuotas se puede aplicar (2026-08-26).** A las de contratos **activos y
SUSPENDIDOS**, la más vieja primero, cruzando contratos del cliente. El suspendido
entró junto con el resto de la app: se le cortó el servicio pero se le sigue
cobrando (ver [[suspension]]), así que era absurdo cobrarle una deuda y a la vez
tenerle plata suya guardada que no se podía usar contra ella. `cancelado` no entra:
condona, no queda deuda.

**🔴 Los cargos manuales SUELTOS quedan afuera, y NO es un olvido.** El picker usa
un **INNER JOIN** a `contratos`. Es tentador pasarlo a LEFT —`cuotas.contrato_id` es
nullable y el `COALESCE(ct.estado,'activo')` de la query parece pedirlo— pero
**`saldos_favor.contrato_id` es NOT NULL**: el INSERT de `aplicarCredito` reventaría
con un 23502 **en el server**, después de que SQLite ya lo escribió local. Como esto
es offline-first, el usuario vería el crédito aplicado y la cuota bajar de saldo, y
el sync lo rechazaría. Habilitarlo necesita una **migración** que haga nullable esa
columna, no un cambio de JOIN. El repo `aplicarCredito` no tiene guard de estado de
contrato: **el único portero es esta query**.

**Consecuencias asumidas al ampliar a suspendidos.** (a) Aplicar crédito escribe un
`cargos_extra`, y `revertirSuspension` aborta si los cargos cambiaron desde el
snapshot → **después de aplicar crédito, la salida es Reactivar, no Revertir**. Es
el comportamiento que la regla de suspensión ya declara, no uno nuevo. (b) El
`deuda_snapshot` congelado al suspender **no** se actualiza: el PDF de constancia
seguirá mostrando la deuda del momento de suspender. Ya era así con un cobro normal.

**El rol `lectura` ve el saldo pero no lo aplica (2026-08-26).** `verDinero` lo
incluye a propósito, y hasta esta fecha eso le dejaba apretar "Aplicar" y escribir
un cargo, una fila de `saldos_favor` y `op_log` a su nombre. Ahora el botón no se le
dibuja y `_aplicar` chequea `soloLecturaProvider`.

**Sin red de tests.** Ni la suite de Dart ni las dos seeds ejercitan `aplicarCredito`.
En producción `saldos_favor` no tiene **ni una fila `aplicado`**: el botón nunca se
usó con éxito. Lo que hay son 7 clientes con ~C$1.525 acreditados (5 Mairena, 2
Telenet, medido 2026-08-26). Cualquier cambio acá se prueba a mano.

```regla
simbolos:
  saldos_favor
  credito_aplicado
  previewExcedente
  credito_excedente
  aplicarCredito
  _SaldoFavorSection
prohibido:
docs:
  ARQUITECTURA.md -> Receta R17
  AGENTS.md -> Invariantes de dinero, 4
superficies:
  AGENTS.md
  ARQUITECTURA.md
  BITACORA.md
  CHANGELOG-REWORK.md
  MODULOS.md
  PRODUCTO.md
  TESTING.md
  docs/AUDIT-INTEGRAL-2026-08-22.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  docs/traspaso/GUIA-SUPABASE-POWERSYNC.md
  lib/data/providers/centro_cobranza_providers.dart
  lib/data/providers/contrato_providers.dart
  lib/data/repositories/contratos_repo.dart
  lib/data/repositories/cuotas_repo.dart
  lib/data/repositories/pagos_repo.dart
  lib/data/repositories/settings_repo.dart
  lib/data/repositories/solicitudes_repo.dart
  lib/data/utils/audit_changelog.dart
  lib/data/utils/prorrateo.dart
  lib/features/admin/dashboard/dashboard_query.dart
  lib/features/admin/reportes/arqueo_query.dart
  lib/features/admin/settings/settings_admin_screen.dart
  lib/features/admin/settings/settings_groups.dart
  lib/features/clientes/cliente_detail_screen.dart
  lib/features/contratos/contrato_detail_pagos.dart
  lib/features/contratos/contrato_detail_screen.dart
  lib/features/contratos/suspension_dialogs.dart
  lib/features/recibo/recibo_cambio_plan.dart
  lib/powersync/schema.dart
  powersync/sync-rules.yaml
  supabase/escenarios/dashboard_seed.sql
  supabase/escenarios/generar_seed_sql.py
  supabase/migrations/0127_saldos_favor_credito_excedente.sql
  supabase/migrations/0131_op_log_super_admin_policy.sql
  supabase/migrations/0140_drop_audit_log.sql
  supabase/migrations/0147_data_ops_funciones.sql
  supabase/migrations/0153_verificar_invariantes_rpc.sql
  supabase/migrations/0155_restaurar_backup.sql
  supabase/migrations/0198_rol_lectura.sql
  supabase/migrations/0213_invariantes_timeout_y_conteo.sql
  supabase/migrations/0217_fix_corrector_cargos_neto.sql
  supabase/migrations/0220_guards_integridad.sql
  supabase/migrations/0248_invariantes_21_31_en_rpc.sql
  supabase/migrations/0251_corregir_invariantes_rastro.sql
  supabase/migrations/0255_invariantes_falsos_positivos.sql
  supabase/migrations/0267_cargo_cambio_plan_con_detalle.sql
  supabase/tests/invariantes_dinero.sql
  supabase/tests/seed_credito_excedente.sql
  test/data/repositories/cuotas_repo_ajustes_test.dart
  test/data/repositories/pagos_repo_test.dart
```
