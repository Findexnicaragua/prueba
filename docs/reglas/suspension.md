# Regla: suspender CONSERVA la deuda y es reversible

**Enunciado, en una línea.** Suspender corta el servicio pero **conserva la deuda
cobrable** y se puede deshacer. Es lo OPUESTO de cancelar, que la condona.
*Si el cliente se va debiendo y le vas a seguir cobrando, la acción es SUSPENDER.*

**Cómo reparte la plata.** A diferencia de cancelar —que pone en cero el saldo
entero de toda cuota viva— suspender **clasifica cada cuota por su ventana de
servicio** anclada al `dia_pago` (ver [[mes-servicio]]): la cumplida queda entera,
la del mes **en curso se prorratea a los días consumidos** (con clamp al pago ya
hecho, para que el monto de una cuota nunca SUBA) y las futuras se anulan. Esa
deuda sobreviviente se congela en `deuda_snapshot` y se cobra desde la sección
**"Recuperación · fuera de ruta"** del cobrador.

**Por qué el preview y la mutación tienen que dar lo mismo.** `previewDeudaSuspension`
y `_calcularDeudaSuspension` son la misma función a propósito: el número que se
muestra ANTES de confirmar es el que se va a escribir. Cancelar tuvo ese bug
—usaba este cálculo, que descarta futuras y prorratea— y por eso quien autorizaba
la baja veía menos de lo que se condonaba (fix 2026-08-26, ver [[cancelacion]]).
**Si alguien vuelve a compartir el cálculo entre las dos, rompe una de las dos.**

**Reversible, con guarda.** `revertirSuspension` restaura el estado EXACTO previo
desde `cuotas_previas`. Aborta si después hubo cobros o cambios de cargo —compara
`monto_pagado` y `cargos_neto` contra el snapshot—: en ese caso la salida es
Reactivar, no revertir. **Reactivar** es otra cosa: reinicio limpio tras una pausa
real, re-ancla el `dia_pago` y revive el gap anulado.

**Dónde SE VE esa deuda (2026-08-26).** Como se le sigue cobrando, cuenta
**adentro** del total, no aparte: entra al titular *"Cuotas por cobrar"* y *"En
mora"* del dashboard, a las tres queries del reporte de **Mora** (PDF, Excel y la
tarjeta "Mora por comunidad") y a **"Recuperación por cobrador y comunidad"** con
su drill-down. El KPI que antes decía "Suspendido (por reactivar)" ahora se llama
**"De eso, suspendido"**: es el DESGLOSE del titular —cuánto de lo que nos deben
no sale en la ruta del día—, **no un balde que se suma**. Al aplicarlo, Telenet
pasó de C$508.678 a C$598.158 de mora: 17,6% que la empresa no estaba viendo.

**Lo que a propósito NO la cuenta, y por qué.** Todo lo que arma una VISITA:
"Vencimientos próximos" (`proyeccionCobrosProvider`, `= 'activo'`), la lista de
Cobros, el mapa y el cron de `notificaciones_mora` (0124). A un contrato sin
servicio no se lo visita por su cuota nueva; su deuda se persigue desde
"Recuperación · fuera de ruta". La línea divisoria es **contabilidad (cuenta) vs
ruta (no cuenta)**, y está escrita en el `noIncluye` de cada panel de info. Si
alguien "alinea" el cron o Proyección con el reporte, le llena la ruta del
cobrador de clientes sin servicio.

**El crédito a favor SÍ se le puede aplicar (2026-08-26).** El botón "Aplicar" de
la ficha del cliente antes solo ofrecía cuotas de contratos activos, así que un
cliente con crédito y un contrato suspendido con deuda no podía usar su propia plata
contra la deuda que se le estaba cobrando. Ahora entra — con dos consecuencias
asumidas: el cargo que genera hace que **Revertir** aborte (la salida pasa a ser
Reactivar, que es lo que esta misma ficha ya declara) y el `deuda_snapshot` no se
actualiza. Detalle en [[credito-excedente]].

**Permiso.** El `admin` la ejecuta; `admin_cobranza` y `admin_usuarios` la
SOLICITAN (principio 6 de `AGENTS.md`: toda acción con repercusión monetaria pide
autorización). Quien pide y quien aprueba ven el monto que **queda cobrable** —ese
rótulo es correcto acá y sería falso al cancelar.

```regla
simbolos:
  suspenderContrato
  revertirSuspension
  previewDeudaSuspension
  contrato_suspensiones
  suspendido_en
  # Los de ARRIBA indexan como se EJECUTA la suspension; los de abajo, donde se
  # VE su deuda. Se agregaron el 2026-08-26 porque el snapshot no traia ni el
  # dashboard ni los reportes: se cambio la visibilidad de la deuda suspendida y
  # el indice no llevaba a ninguna de las superficies que habia que tocar.
  saldoSuspendido
  cuotasSuspendidas
  saldo_suspendido
  proyeccionCobrosProvider
  recuperacionPorComunidadProvider
  # Los paneles "?" declaran el universo de cada tarjeta EN TEXTO. Son la
  # superficie que miente sin romper nada, asi que tienen que estar en el indice.
  kInfoOperativo
  kInfoRecuperacion
  kInfoProyeccion
prohibido:
docs:
  ARQUITECTURA.md -> Receta R14
  AGENTS.md -> Invariantes de dinero, 6b
  PRODUCTO.md -> Matriz de permisos
superficies:
  ARQUITECTURA.md
  BITACORA.md
  CHANGELOG-REWORK.md
  MODULOS.md
  docs/AUDIT-INTEGRAL-2026-08-22.md
  docs/PLAN-CONSISTENCIA-2026-08-23.md
  docs/traspaso/GUIA-SUPABASE-POWERSYNC.md
  lib/data/models/deuda_snapshot.dart
  lib/data/models/solicitud_accion.dart
  lib/data/providers/aprobaciones_provider.dart
  lib/data/providers/colas_servicio_provider.dart
  lib/data/providers/dashboard_providers.dart
  lib/data/repositories/contratos_repo.dart
  lib/data/repositories/solicitudes_repo.dart
  lib/data/utils/audit_changelog.dart
  lib/features/admin/dashboard/estado_actual_card.dart
  lib/features/admin/dashboard/info_grafica_textos.dart
  lib/features/admin/dashboard/mora_zona_card.dart
  lib/features/admin/dashboard/proyeccion_cobros_card.dart
  lib/features/admin/reportes/pdf/reporte_clientes_pdf.dart
  lib/features/admin/reportes/pdf/reporte_deuda_suspension_pdf.dart
  lib/features/admin/reportes/reportes_admin_screen.dart
  lib/features/admin/solicitudes/solicitudes_screen.dart
  lib/features/contratos/contrato_detail_screen.dart
  lib/features/contratos/suspension_dialogs.dart
  lib/features/shared/widgets/deuda_contrato_bloque.dart
  lib/powersync/schema.dart
  powersync/sync-rules.yaml
  supabase/escenarios/dashboard_seed.sql
  supabase/escenarios/generar_seed_sql.py
  supabase/migrations/0120_suspension_temporal_contrato.sql
  supabase/migrations/0123_cancelacion_dinamica_suspension.sql
  supabase/migrations/0127_saldos_favor_credito_excedente.sql
  supabase/migrations/0140_drop_audit_log.sql
  supabase/migrations/0147_data_ops_funciones.sql
  supabase/migrations/0155_restaurar_backup.sql
  supabase/migrations/0172_tickets_contrato_efecto.sql
  supabase/migrations/0198_rol_lectura.sql
  supabase/migrations/0220_guards_integridad.sql
  supabase/migrations/0234_anular_cuotas_futuras_al_dar_de_baja.sql
  supabase/migrations/0248_invariantes_21_31_en_rpc.sql
  supabase/migrations/0255_invariantes_falsos_positivos.sql
  supabase/tests/invariantes_dinero.sql
  supabase/tests/seed_escenarios_suspension.sql
  test/data/repositories/pagos_repo_test.dart
```
