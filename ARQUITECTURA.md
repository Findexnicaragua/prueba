# ARQUITECTURA.md — Esquema de la app, módulos, conexiones y recetas de cambio

> **Quién lee esto:** humanos que quieren entender cómo conecta todo, y AIs que
> van a MODIFICAR código. **La meta: poder hacer un cambio sin escanear todo el
> repo** — buscá tu caso en §0 (índice de cambios) y andá directo.
> **Cuándo se actualiza (OBLIGATORIO):** al agregar/quitar un módulo, tabla,
> setting, ruta o conexión entre módulos → actualizar la sección del módulo +
> §0 si aparece un tipo de cambio nuevo. Cambios que no alteran el esquema
> (fixes internos) NO se anotan acá (van en `BITACORA.md`).
> **Documentos hermanos:** `PRODUCTO.md` (qué es la app y por qué) ·
> `BITACORA.md` (estado vivo + historial) · `AGENTS.md` (reglas/proceso) ·
> `Install Steps/` (build/release) · `TESTING.md` (testing manual).

---

## §0. ÍNDICE DE CAMBIOS — "quiero modificar X" → dónde ir

| Quiero... | Andá a |
|---|---|
| Cambiar colores de estados de cuota (mapa/listas) | **Receta R1** |
| Tocar el dashboard del admin (KPIs) | **Receta R2** |
| Cambiar el layout/textos del recibo (térmica + PDF) | **Receta R3** |
| Arreglar cómo IMPRIME una impresora (corte a la derecha, pie perdido, logo empastado, tildes raras) | **§3 Recibo + Impresora** — es ajuste POR-PC, nunca tocar el raster/transporte compartido |
| Agregar una columna a una tabla existente | **Receta R4** (cadena de integridad) |
| Agregar una pantalla al admin | **Receta R5** |
| Elegir 1 ítem de una lista de la base (producto/cliente/plan/nodo…) en un form o diálogo | **`SelectorBuscable`** — NO `DropdownButton` (§3 Shared + AGENTS audit #10) |
| Agregar un setting nuevo | **Receta R6** |
| Cambiar lógica de mora/gracia/vencimiento | **Receta R7** |
| Agregar un reporte (PDF + Excel) | **Receta R8** |
| Cambiar textos/branding del recibo | **Receta R9** |
| Entender el modelo de dinero (facturación vencida / ancla día_pago / reportería) | **§3.5** (regla de oro) |
| Tocar el flow de cobro (¡DINERO!) | **Receta R11** + invariantes de `AGENTS.md` |
| Cobrar instalación/reconexión/etc con recibo (trabajo de campo) | **Cobro DESDE el ticket** (§Cuotas/§Tickets; `ticket_tipos.precio` → cuota manual ligada por `ticket_id` → R11) |
| Cobrar una multa / otro cargo que decide el admin, con recibo | **Cobro puntual** del cliente (§Cuotas; cuota manual standalone → R11) |
| Cambiar fecha de pago de un cliente (puente) | **Receta R13** |
| Cambiar el plan de un contrato (mid-contrato, re-valúa futuras + prorrateo) | **Receta R22** |
| Suspender / reactivar un contrato | **Receta R14** |
| Cancelar un contrato (permanente, deja deuda cobrable) | **Receta R16** |
| Ver/cobrar deuda de cancelados/suspendidos en Cobros (toggle "fuera de ruta") | **§3 Cuotas/Cobros** (`cobrosFueraDeRutaQuery` + sección Recuperación) |
| Crédito por excedente (acreditar/devolver/condonar lo pagado por adelantado) | **Receta R17** |
| Reasignar cobrador (masivo / pantalla Rutas) o cliente sin cobrador | **Receta R15** |
| Crear/editar/asignar etiquetas de clientes (color + icono) | **§3 Etiquetas** (módulo P5; R10) |
| Agregar una tabla/entidad/módulo nuevo | **Receta R10** (checklist completo) |
| Emitir historial (op_log) en una entidad/operación | **Receta R18** (+ §3 Audit/Change log) |
| Cambiar el menú/galería de inicio del admin | **Receta R12** |
| Tocar tickets/técnico/inventario/incidentes | §3 módulos opcionales |
| Rediseñar / tocar el módulo Inventario (vistas, alta de items, filtros, lifecycle) | **Receta R21** (mapa de impacto + cadena de integridad) |
| Tocar auth/login/sync gate/impersonación | §2 núcleo + §3 auth/super_admin |
| Corregir/borrar data de un cliente (super_admin: limpiar/eliminar cliente o contrato) | **Receta R19** (+ §3 Operaciones de datos) |
| White-label: app branded por tenant (ícono, nombre, logo de login, canal de update) | **Receta R20** |
| Tocar la búsqueda de cliente (campos, folding ñ/acentos, placeholder) | **§3 Clientes** (helper `busqueda_cliente.dart`) |
| Tocar el rol `lectura` (solo lectura) o agregar una acción que deba ocultarle | **§3.9** (las 3 barreras) |
| Escribir en la base desde el cliente | **`ps.dbW`, NUNCA `ps.db`** (§3.9 — guardia de solo-lectura) |
| Tocar el PIN del Resumen | **§3.10** (vive en `dashboard_pins`, una fila por usuario) |
| Cambiar la ventana de fechas del Resumen (KPIs, ranking, tendencia) | **`data/utils/periodo_dashboard.dart`** — corte del 15, NO mes calendario |
| Buildear y publicar una versión | `Install Steps/1-Publicar-nueva-version.md` |
| Entender cómo se entrelazan las tablas (FKs, cascades, denormalización + triggers) | **§3.6** |
| Entender/tocar los algoritmos de optimización (mapa vmv, Clientes paginada, índices) | **§3.7** |

**Reglas de oro antes de CUALQUIER cambio** (detalle en §6):
Toda ESCRITURA del cliente va por `ps.dbW` (guardia del rol `lectura`), nunca
por `ps.db` — y ojo con inyectar `db:` en un repo, que la esquiva ·
SQLite ≠ Postgres (sin `FILTER`/`::casts`/`ILIKE` en `lib/`) · TZ Nicaragua
(`date('now','-6 hours')`, nunca pelado) · server gana (el cliente espeja
triggers, no decide) · toda tabla tenant-scoped nueva nace con
`tenant_id`+RLS (incl. `super_admin_all` A MANO) + emite `op_log` si es
editable · provider global que toca `ps.db` lleva `ref.watch(dbEpochProvider)`.

---

## §1. Visión de capas

```
┌─────────────────────────────────────────────────────────────────────────┐
│ UI  ·  lib/features/<modulo>/*.dart                                       │
│   4 shells por rol: AppShell (cobrador `/`) · AdminShell (`/admin` =      │
│   galería de inicio) · SuperShell (`/super`) · TecnicoShell (`/tecnico`)  │
│   go_router (config/router.dart) decide el shell según el rol             │
└───────────────▲───────────────────────────────────┬──────────────────────┘
                │ ref.watch / ref.read               │ context.go/push
┌───────────────┴───────────────────────────────────▼──────────────────────┐
│ STATE  ·  Riverpod  ·  lib/data/providers/* + *RepoProvider               │
│   StreamProvider (watch SQLite) · FutureProvider.family · StateProvider   │
│   Los globales hacen ref.watch(dbEpochProvider) → se recrean al cambiar DB│
└───────────────▲───────────────────────────────────┬──────────────────────┘
┌───────────────┴─────────────────┐  ┌───────────────▼──────────────────────┐
│ DATA repos · lib/data/repos/*    │  │ DATA services · lib/data/services/*   │
│   PagosRepo, ClientesRepo,       │  │   FotoComprobante, Impresora, Logo,   │
│   CuotasRepo, SettingsRepo →     │  │   Impersonation, ErrorLog, MapTile,   │
│   SQLite local                   │  │   Update, Visitas (Storage/BT/OS/RPC) │
│   SuperAdminRepo → RPC/Edge      │  │                                       │
└───────────────▲──────────────────┘  └───────────────────────────────────────┘
                │ ps.db.watch / .execute / .writeTransaction
┌───────────────┴──────────────────────────────────────────────────────────┐
│ PowerSync (SQLite local) · lib/powersync/{db,schema,connector}.dart        │
│   ps.db = PowerSyncDatabase per-user (sitecsa_{uid}_w1.db)                 │
│   schema.dart declara tablas · connector.dart sube la CRUD queue           │
└───────────────▲───────────────────────────────────┬──────────────────────┘
        download │ (sync rules: buckets por rol)      │ upload (CRUD queue)
┌───────────────┴───────────────────────────────────▼──────────────────────┐
│ SUPABASE · Postgres + RLS + Triggers + Edge Functions (Deno) + Storage     │
│   powersync/sync-rules.yaml = QUÉ filas baja cada rol                      │
│   Triggers = fuente de verdad de dinero y audit ("server gana")            │
└───────────────────────────────────────────────────────────────────────────┘
```

**Regla general de quién habla con quién:** la UI nunca llama a Supabase
directo para data operativa (pasa por providers → repos → `ps.db`).
Excepciones legítimas: `SuperAdminRepo` (RPC/Edge, cross-tenant),
`ImpersonationService`, el piso del correlativo de recibo (MAX server con
timeout 5s + high-water mark local `CorrelativoStore` que nunca decrece), y
Storage (fotos/logos/documentos).

---

## §2. El núcleo del wiring (leer antes de tocar auth/sync/rutas)

### `lib/main.dart` — bootstrap y ciclo de sesión
`runZonedGuarded` + `ErrorLogService.init()` capturan todo error → `error_logs`.
`auth.onAuthStateChange`: `signedIn` → `ps.openDatabaseForUser(uid)` +
`ps.connectPowerSync()`; `signedOut` → `disconnectPowerSync()` (la data local
NO se borra). **Las 3 operaciones se serializan con el lock `_pendingOp`**
(fix 2026-06-09 — sin esto, el sync gate quedaba colgado post-forzar-password).
Al cambiar de DB, `onDatabaseSwitched` bumpea `dbEpochProvider` → recrea todos
los providers globales. Workers de fondo con conexión: fotos pendientes,
error_logs, caché del logo. Telemetría `[SYNC-DIAG]` en consola.

### `lib/powersync/` — la capa de datos local
- **`db.dart`**: `ps.db` global per-user; **`_dbWipeVersion = 1`** vive en el
  nombre del archivo SQLite (`sitecsa_<uid>_w1.db`) → bumpearlo fuerza DB fresca
  para todos. **NO se bumpea por cambios aditivos** (columna/tabla/índice =
  in-place); solo destructivos/cache-corrupto (política en R4, fix #1 2026-06-19).
  El aislamiento entre usuarios lo da el `<uid>` del nombre, no la versión.
- **`schema.dart`**: TODA columna de Postgres que la app usa DEBE estar acá.
- **`connector.dart`** (`SupabaseConnector`): drena la CRUD queue con
  upsert/update/delete genéricos vía PostgREST. `esCodigoNoRetryable`
  (pública, testeada — audit 2026-06-11 #1): **ALLOWLIST** de permanentes —
  descarta con aviso SOLO `23xxx`/`42xxx`/`22xxx` (SQLSTATE de 5 chars) y
  `P0001`; TODO lo demás (PGRST*, códigos HTTP, clase 40, desconocidos) se
  **REINTENTA** (un permanente raro bloquea la cola a propósito: preserva el
  dato hasta que se corrija server-side). Cada descarte deja TRIPLE rastro:
  `uploadErrorsController` → SnackBar humanizado en los 4 shells ·
  `RechazosSyncService` → card "Cambios sin sincronizar" del Perfil ·
  `error_logs` con el `opData` completo (forense).
  **LÍMITE CONOCIDO Y ACEPTADO (0230, 2026-08-10) — el rechazo MUDO ya no se
  detecta en `clientes` ni `contratos`.** El mecanismo era: `.update(...)
  .select('id')` y si volvían 0 filas, la RLS lo había filtrado ⇒ rechazo. Con
  la barrera por columna de 0230 la fila SÍ pasa la RLS y el trigger revierte lo
  no permitido, así que el UPDATE devuelve 1 fila y se ve exitoso.
  **No se reconstruyó a propósito.** La alternativa obvia —que el connector
  compare lo que mandó contra lo que volvió— ya se intentó en este proyecto y
  falló: `anulado`/`en_revision` son `Column.integer` (0/1) en SQLite y `boolean`
  en Postgres, así que `'1' != 'true'` habría disparado una alarma roja en CADA
  anulación de pago. Cambiar un silencio raro por un falso positivo constante es
  peor. Hoy ningún camino de la app produce el caso (el gate de UI está alineado
  con lo que la barrera permite); si mañana aparece uno, el usuario NO va a
  recibir aviso, y hay que resolverlo en el origen —alineando el gate— no acá.
- **Buckets de sync** (`powersync/sync-rules.yaml` — QUÉ baja cada rol; los 11
  reales, línea del yaml entre paréntesis):

  | Bucket | Quién lo baja | Qué trae (resumen) |
  |---|---|---|
  | `catalogo_tenant` (L21) | todo miembro | planes, settings, etiquetas, geografía, red, `tenant_modulos` |
  | `por_cobrador` (L58) | rol cobrador | el tenant operativo: clientes/contratos/cuotas + pagos/recibos NO anulados, cargos, mora, fotos, visitas |
  | `por_tecnico` + `_tickets` + `_inventario` + `_clientes` (L113-169) | rol técnico | SUS tickets + catálogo + su custodia de inventario + clientes ligados a sus tickets |
  | `por_admin_tickets` (L183) | rol admin_tickets | todos los tickets del tenant + clientes + catálogo inventario |
  | `todo_tenant_admin` (L211) | rol admin | TODO el tenant (incl. anulados, op_log, inventario, tickets) |
  | `todo_tenant_admin_cobranza` (L256) | rol admin_cobranza | como admin SIN inventario-stock; **incluye `tickets`+`ticket_tipos`** (colas del Centro — fix Fable 5, v17) |
  | `todo_tenant_admin_usuarios` (L325) | rol admin_usuarios | clientes, contratos, planes, catálogo, solicitudes, op_log, etiquetas, geografía, red. **SIN** pagos, recibos, cuotas, cargos_extra, saldos_favor, inventario, tickets |
  | `super_admin_self` (L311) | super_admin | su propia fila (reconocer el rol) |
  | `impersonated_tenant` (L339) | super_admin impersonando | el tenant impersonado completo (incl. op_log) |

  Regla: una pantalla que consulta una tabla que el bucket del rol NO trae →
  query vacía SIN error (así se escapó la cola "ya cortados" vacía). Al
  agregar tabla nueva: R10 exige revisar TODOS los buckets que la necesitan.

### `lib/config/router.dart` — navegación por rol + gates (EN ORDEN)
1. Sin sesión → `/login` · flow recovery/invite → `/set-password`.
2. **Sync gate** (`/sync-gate`): retiene mientras `!syncReady || rol == null`,
   con grace de 8s y escape hatches (SyncGateScreen).
3. Landing por rol: super → `/super/tenants` (o `/admin` si impersona) ·
   admin/admin_cobranza/admin_usuarios → `/admin` (galería de inicio; el
   dashboard vive en `/admin/resumen`, sub-galería en `/admin/administracion`)
   · admin_tickets → `/admin-tickets` · tecnico → `/tecnico` · cobrador → `/`.
4. Guards: `tecnico` contenido en `/tecnico/*`; `cobrador` rebotado de
   `/admin`; `admin_cobranza` bloqueado de la lista `soloAdmin`;
   **`admin_usuarios`** allowlist estricta (`/admin/clientes`,
   `/admin/contratos`, `/admin/mapa`, `/admin/solicitudes` — todo lo demás
   redirige a `/admin`; también bloqueado de `/cobro` y `/recibo`);
   `/admin/pagos` gateado por setting;
   `/admin/inventario|tickets|incidentes` gateados por módulo; `/super/*`
   solo super_admin sin impersonar.
- Providers del router: `_rolUsuarioProvider` (rol desde `cobradores`) y
  `empresaNombreProvider` (setting `empresa.nombre`).

### Providers transversales (el pegamento — viven en `lib/data/providers/`)
| Provider | Expone | Lo usan |
|---|---|---|
| `dbEpochProvider` | contador de recreación de DB | TODO provider global que toque `ps.db` (primera línea) |
| `cobradorActualProvider` | el usuario logueado (`Cobrador`) | casi todas las pantallas |
| `tenantIdProvider` | tenant EFECTIVO (respeta impersonación) | todo INSERT/UPDATE |
| `appSettingsProvider` | settings tipados del tenant | cobro, cuotas, recibo, mapa, shells, router |
| `syncStatusProvider` / `syncReadyProvider` | estado PowerSync / gate listo | shells, router |
| `conexionRealProvider` | conectividad REAL del device (sondeo TCP a Supabase vía `dart:io`, sin paquete nuevo; respeta `dbEpochProvider` → no queda latcheado en offline tras recrear la DB, fix cold-start 2026-06-19) | `OfflineBanner` (banner rojo "Sin conexión") |
| `modulosHabilitadosProvider` | set de módulos ON | menú admin, router, inventario/tickets |
| `impersonatedTenantIdProvider` / `estaImpersonandoProvider` | impersonación | banner, guards de acciones de campo |
| `crudUploadErrorProvider` | errores de upload | SnackBars en shells (humanizados; VER → Perfil en cobrador/técnico) |
| `rechazosSyncProvider` | rechazos de sync persistidos (`RechazosSyncService`, SharedPreferences) | card "Cambios sin sincronizar" del Perfil |
| `moraCountProvider` (`mora_count_provider.dart`) | mora sin ver DEL PROPIO cobrador (`cobrador_id = uid` — única marcable por RLS `notif_update_marca`; audit 2026-07-03) | badge "Cobros" del bottom-nav cobrador (`app_shell`), invalidado por router en auth-change |
| `centroCobranzaProviders` (`centro_cobranza_providers.dart`) | métricas + colas del Centro de cobranza (read-only) | `/admin/centro-cobranza` |

---

## §3. Módulos — qué es cada uno, con qué conecta y por qué

> Formato por módulo: **[H]** = explicación humana · **[AI]** = datos técnicos
> para modificar sin escanear. Las tablas locales = Postgres vía PowerSync.

### Cobro (el corazón) — `lib/features/cobro/`
**[H]** La pantalla donde el cobrador registra un pago en campo (single o
multi-cuota): monto, moneda NIO/USD, método, descuentos/cargos, foto. Conecta
con **recibo** (navega al terminar), **cuotas** (de ahí llega), **settings**
(reglas de cobro) e **inventario de dinero** de toda la app (dashboard,
reportes y contratos leen lo que esto escribe).
**[AI]** `cobro_screen.dart` (UI+validaciones) · cálculo puro en
`data/utils/cobro_calculo.dart` (`aplicado=min(entregado,saldo)`,
`vuelto=entregado−aplicado` SIEMPRE NIO; multi-cuota: vuelto al último pago) ·
persistencia en `data/repositories/pagos_repo.dart`
(`registrarCobro`/`registrarCobroMultiple`: una `writeTransaction` con
`cargos_extra`→`pagos`→`recibos`→mirror de `cuotas` vía `calcularEstadoCuota`).
Correlativo: MAX del server como piso (timeout 5s) + hwm `CorrelativoStore`
+ recálculo en tx. Rutas: `/cobro/:ids` (ids = `id1,id2,...`). Settings:
`cobranza.pago_parcial/pago_adelantado/
descuentos_*/cargo_reconexion_*/comprobante_*/foto_obligatoria`,
`pagos.usd_habilitado/tasa_usd_cordoba/metodo_*`. Tablas: escribe `pagos`,
`recibos`, `cargos_extra`, `cuotas` (mirror). Guard: bloqueado impersonando.
Desde el mega-sprint 2026-06-11: montos con `parseMonto` (coma decimal, M8) ·
PopScope con confirmación de descarte (#6, incluye cargos pendientes) ·
`trg_pagos_guard_cobrador` (0116) enforcea server-side
`cobrador_anula_cobros`/`cobrador_edita_cobros` (#4) · anular un pago
revierte SUS descuentos (`pago_id`, 0115/M3 — cubre TAMBIÉN los manuales).
**Rediseño descuentos 2026-06-12:** el cobro NO crea descuentos ni cargos
— solo los REFERENCIA (botón "Ver descuentos y cargos" → sheet solo-lectura
con `_cargosExistentes` de DB + `_cargosAuto` pendientes). La gestión vive
en el detalle del contrato (admin). Los automáticos (reconexión / pronto
pago) siguen diferidos: se insertan al confirmar vía `cargosAuto` (con
`pago_id`) — abandonar el cobro no deja rastro y anular el pago revierte
sus descuentos. Totales derivados de `_totalesBase` + autos
(`_recalcularTotales`, monto default en la MONEDA activa).
**⚠️ Ver Receta R11 + invariantes de dinero en `AGENTS.md` antes de tocar.**

### Cuotas — `lib/features/cuotas/` (cobrador+admin)
**[H]** La lista de qué hay que cobrar. El cobrador ve SUS cuotas (mora
primero, gate de rango para las futuras). Alimenta a **cobro** (multi-select
→ batch). La pantalla admin `/admin/cuotas` se RETIRÓ (2026-06-11, decisión
Rubén): "anular cuota" salió del producto (terminal-peligroso; la única
anulación masiva es Cancelar contrato). **Cobro puntual (2026-06-29):** las
cuotas MANUALES (`tipo_cargo_manual` NOT NULL, `contrato_id` NULL) — que estaban
DORMIDAS desde que se retiró `/admin/cuotas` — volvieron como cargo de UNA VEZ
con recibo (instalación/reinstalación/anexo/multa/reconexión):
`CuotasRepo.crearCuotaManual` crea la cuota **standalone** (op_log de alta scoped,
`cobrador_id` denormalizado) y enruta al MISMO `/cobro/:id` → pago→recibo→
correlativo (CERO cambios en la mecánica de dinero; el recibo imprime el concepto
vía `cuota_descripcion`). **DOS orígenes (0173, decisión Rubén 2026-06-30):**
**(1) DESDE EL TICKET** — el trabajo de campo (instalación/reconexión/etc) nace en
un ticket; el tipo lleva `ticket_tipos.precio` (>0 = cobrable) y el ticket RESUELTO
ofrece "Generar cobro" (`ticket_detail_screen._botonCobro/_generarCobro`, gateado
admin/cobranza no-impersonando) con el precio precargado (editable); la cuota guarda
`cuotas.ticket_id` (link → recibo "Ticket #N"). **Anti-doble-cobro en 3 capas
(0175, audit 2026-07-05):** (a) el stream `_cobroTicket` oculta "Generar cobro"
si ya hay cuota viva; (b) re-check dentro de la `writeTransaction` de
`crearCuotaManual` (mismo device offline); (c) índice UNIQUE parcial server
`cuotas_unico_cobro_ticket` (`ticket_id WHERE estado<>'anulada'`) → el 2º INSERT
de otro device es rechazado (23505) y el connector lo revierte. Anular la cuota
libera el ticket para re-cobrar. **(2) DEL CLIENTE** — multa / otro cargo
que decide el admin: acción en el AppBar del detalle del cliente (concepto en
`kCobroPuntualAdminTipos` = multa/otro). El diálogo `cobro_puntual_dialog.dart` tiene
los 2 modos. Money-safe: la cuota con `contrato_id` NULL queda FUERA del total fijo y
de los invariantes (INV11 y oldest-first la ignoran por `tipo_cargo_manual`); su pago
SÍ entra a caja; `ticket_id` es metadato puro (no toca dinero — audit 17/17 en 0).
Conceptos en `data/utils/cobro_puntual.dart`. → **R11.**
**[AI]** `cuotas_list_screen.dart` (vista ÚNICA "Por cobrar"; **Feature 1
2026-06-21: UNA fila PLANA por CONTRATO** — antes era tarjeta-por-cliente con
desplegable). El stream principal trae **una fila por CONTRATO agregada en SQL**
(`cobros_query.dart` `cobrosFlatQuery`: CTE `lineas` con `ROW_NUMBER` por
contrato → `rn=1` = cuota más vieja; CTE `grupos` con `COUNT`/`SUM` por grupo
para el aviso de cuotas extra). Cada fila (`_CobroFilaCard`) muestra
código·nombre · **plan · mes · fecha · estado** + **saldo** (= la cuota más
vieja, oldest-first) + **Pagar** (→ esa cuota) + **Cambiar fecha**, SIEMPRE
visibles **sin desplegable**, barra de color de estado, y **tocar la fila abre la
ficha del cliente** (`InkWell` → `/[admin/]clientes/:id`; los botones capturan su
propio tap → no abren la ficha). Cargos manuales (sin contrato) = su propia fila.
**Por qué 1 fila/contrato:** un cliente con 2 contratos = 2 filas (lo normal es
1=1); escala igual que el modelo anterior (mismo scan SQL, ListView lazy). El
saldo usa la fórmula canónica del CTE (idéntica a `cobrosResumenQuery`) → la **Σ
de las filas de un cliente = el `total_cobrable` del resumen** (consistencia #10,
cubierta por `test/features/cuotas/cobros_resumen_test.dart`). Buscador
client-side con **debounce 250ms** (nombre/cédula/teléfono/código, no recrea el
stream) + chips de estado + filtros multi-selección `FiltroMultiDropdown`
Cobrador/Zona en adminMode (SQL `IN`; "todos→null"=sin filtrar). "Pagar" →
`/cobro/:id` **para admin Y cobrador**. Los streams respetan `dbEpochProvider`
(cold-start #7). **`cobrosResumenQuery`/`cobrosDetalleQuery` se conservan** en
`cobros_query.dart` para los tests y la **futura pantalla de Avisos** (ya no los
usa la lista de Cobros). Índice
`cuotas.by_contrato_vencimiento(contrato_id, fecha_vencimiento)`: lo usan el
**mapa** y el **detalle de contrato**; las queries de Cobros NO lo usan (su
`PARTITION` es sobre `COALESCE(contrato_id, 'm:'||id)`) — no lo "optimices"
creyendo que aplica.
**OJO "cobrable ahora":** el saldo grande de la fila + "Pagar" son la cuota más
vieja del contrato (oldest-first), NO la deuda total. Si el contrato arrastra MÁS
de una cuota que matchea el filtro, la fila muestra un **chip rojo "+N cuotas ·
C$X más"** (la deuda ADICIONAL del contrato, DENTRO del filtro vigente —
`grupos.grupo_count`/`grupo_saldo`); la cuota parcial muestra **"Parcial · abonó
C$X de C$Y"**. Estados PERSISTIDOS:
`pendiente/parcial/pagada/anulada` (CHECK en DB); `en_gracia/vencida/hoy/
proxima` son DERIVADOS en Dart (`data/utils/cuota_estado_visual.dart`
`estadoVisualCuota()`: >gracia→mora · 1..gracia→gracia · 0→hoy ·
futuro≤rango→proxima · futuro>rango→fueraDeRango GRIS "no disponible").
NUNCA escribir `estado='vencida'` (choca el CHECK). Settings:
`cobranza.dias_gracia` (10) / `dias_cuotas_visibles` (5) / `colores_estados`.
Saldo canónico: `monto + COALESCE(cargos_neto,0) − monto_pagado` (igual en
TODAS las pantallas — invariante #10).
**[AI] Recuperación / toggle "Ver fuera de ruta" (2026-07-01)** — la lista de
Cobros filtra `COALESCE(ct.estado,'activo')='activo'` (solo contratos vivos). Un
**toggle "Fuera de ruta"** (off por defecto, cobrador Y admin) ANEXA al final una
sección **"Recuperación · fuera de ruta"** con la deuda viva de contratos
**cancelados y suspendidos** — antes solo visible como el badge "debe C$X fuera de
ruta" en Clientes; ahora cobrable desde el campo. Query dedicada
`cobrosFueraDeRutaQuery` (`cobros_query.dart`): mismo shape que `cobrosFlatQuery`
+ columna `estado_contrato` (es a la vez el badge Cancelado/Suspendido y el
discriminador de sección — **NULL en la lista activa**), `ct.estado IN
('cancelado','suspendido')` + `cu.estado IN ('pendiente','parcial')`, oldest por
contrato, **ignora los chips de fecha** (muestra TODA la deuda viva), respeta el
filtro cobrador/zona, excluye cargos manuales (sin contrato) e inactivos. **Las 3
queries activas quedan INTACTAS** → consistencia #10 preservada; activo vs
fuera-de-ruta son disjuntos por estado de contrato → sin doble conteo. En
recuperación se **oculta "Cambiar fecha"** (esas cuotas están congeladas). **Cobrar
NO reactiva** (pagar solo baja la deuda): si un SUSPENDIDO queda en deuda 0,
`cobro_screen._avisarSuspendidoSaldado` avisa "pendiente de reactivar" (+ botón
Reactivar solo si es admin y `precio_mensual>0`, abre `ReactivarContratoDialog`);
un CANCELADO nunca reactiva (R16/0123). El `_fueraStream` sólo vive con el toggle
prendido (lifecycle #2). Tests: `cobros_resumen_test.dart` (grupo fuera de ruta).
**[AI] Avisos (Feature 3, 2026-06-21)** — `lib/features/admin/avisos/avisos_screen.dart`:
pantalla admin/admin_cobranza que lista clientes EN GRACIA (próximos a corte) y EN MORA, reusando
`cobrosResumenQuery` con filtro `gracia`/`mora` (providers `avisosGracia/avisosMoraProvider`; mismo SQL
canónico → consistente con los chips de Cobros). Fila: cliente · comunidad · teléfono · días
(gracia "corta en N días" = `diasGracia − diasFromVence`; mora "en mora hace N días" =
`diasFromVence − diasGracia`) · total_cobrable, tap→ficha. **Gateada por el toggle super_admin
`cobranza.avisos_habilitado`** (default FALSE/opt-in, migración 0134): gating en 3 capas — ítem de menú
(`settingKey` + `_pantallasOn` en `admin_shell.dart`), ruta (guard en `router.dart` para admin Y
admin_cobranza), y edición del setting super-only (RLS `settings_write_admin`).
**Notificar por WhatsApp (Feature 4, 0135):** cada fila con teléfono trae un botón "WhatsApp" + hay un flujo
guiado "Notificar a todos" (`_NotificarTodosSheet`, uno-por-uno). Abre `https://wa.me/<n>?text=<msg>` vía
`ExternalActions.whatsapp(...,texto:)` — `?text=` URL-encoded + teléfono normalizado a internacional
(`phoneWhatsappIntl`: Nicaragua 505) + `https://wa.me` (NO `whatsapp://` + `canLaunchUrl` → ese combo fallaba en
Android 11+). El mensaje sale de plantillas **editables por el admin** (`cobranza.aviso_msg_gracia`/`_mora`, tab
Cobranza, placeholders `{nombre}{monto}{dias}{empresa}`); los botones los habilita el toggle super_admin
`cobranza.notif_whatsapp_habilitado` (default OFF). Es envío MANUAL (deep link, el usuario toca enviar). Sin
infra de email (no hay columna ni proveedor).
**[AI] WhatsApp por API (modo PAGO, opt-in, 0137/0138, 2026-06-21 — DORMIDO hasta setup de Meta):** segundo modo
que CONVIVE con el manual. Envío AUTOMÁTICO por lote vía Cloud API de Meta, configurable SOLO en Avanzado
(super_admin) con `_WhatsappApiCard` (`settings_admin_screen.dart`): 9 settings `cobranza.notif_api_*` (toggle,
phone_id, template_gracia/mora/lang, hora, frecuencia, tope_diario, token_configurado). El **Access Token** NO es
un setting — vive en **`whatsapp_credenciales`** (tabla server-only, RLS sin policies, NO en sync rules; la escribe
solo la edge function `whatsapp-set-token` con service role; la UI solo ve el booleano reflejo `token_configurado`).
Los envíos se loguean en **`whatsapp_envios`** (dedup por frecuencia + tope). La función Postgres
**`whatsapp_clientes_a_notificar(tenant)`** (0138) centraliza la elegibilidad (gracia/mora por cuota más vieja, con
teléfono, respeta frecuencia: una_vez_estado/cada_3/semanal/cada_15/diario, + tope). La edge function
**`whatsapp-enviar`** tiene modo `uno` (botón "Probar", super_admin) y `lote` (cron service-role: itera tenants con
API on + token + hora Nicaragua == hora config → Meta v21 template message con vars {{1}}nombre {{2}}monto
{{3}}días {{4}}empresa). El **cron** (pg_cron hourly) y el **deploy de las edge functions** son manuales en el
Dashboard. Guía completa de activación: **`Install Steps/WhatsApp-API-setup.md`**.
**[AI] Centro de cobranza (2026-06-29, `b73684f`)** —
`avisos/centro_cobranza_screen.dart`, ruta `/admin/centro-cobranza` (card del
grupo Cobranza; se navega con `go`, regla #12). Panel **read-only** que dice
"qué atender hoy": fila de métricas (Vencen hoy · En mora · A suspender "ya
cortados" · A favor) + colas de acción — Cobrar (gracia/mora → Avisos),
**Servicio** ("Ya cortados — falta suspender" y "Deuda saldada — reactivar",
derivadas de `tickets` efecto=corte JOIN `ticket_tipos`; vacías con módulo
tickets OFF → suspensión manual desde el contrato) y Créditos sin aplicar.
SOLO navega (a Avisos o a `/admin/contratos/:id`) — no toca dinero ni estado;
suspender/reactivar se disparan con la UI existente del contrato (gateadas,
bloqueadas al impersonar). Providers: `centro_cobranza_providers.dart`.
**Gating Fase 2 roles:** `admin_cobranza` ve TODO el Centro de cobranza
(métricas, colas, suspender/reactivar en lote) — los montos acá son PENDIENTES
por cobrar (mora, deuda, créditos a favor), no recaudado. Suspender/reactivar
es "recuperación de cartera" según el req del tenant.
**Sync (fix Fable 5):** el bucket `todo_tenant_admin_cobranza` DEBE traer
`tickets`+`ticket_tipos` o las colas de Servicio le llegan vacías a
admin_cobranza (sync rules v17).
**DESCUENTOS y CARGOS del admin (0115 + rediseño 0117/2026-06-12 — ÚNICO
punto de creación, el cobrador no descuenta):** la variación legítima de
una cuota es un cargo en `cargos_extra` — `cuotas.monto` NO se muta
("Editar monto" se RETIRÓ). UI: icono % por cuota en el detalle del
contrato → sheet "Descuentos y cargos de la cuota" (lista TODOS los
orígenes; los nacidos de un pago van solo-lectura con candado) con DOS
botones: "Aplicar descuento" (`DescuentoDialog`: selector Ajuste/Promo +
chips de motivo + preview → `aplicarAjuste(origen:)`, origen
'ajuste'|'promo') y "Cargo extra" (`CargoDialog`: Reconexión/Otro →
`aplicarCargo`, origen 'cobro' SIN pago_id). `cargosDeCuota` lista,
`quitarCargo` revierte (protege `pago_id` y 'liquidacion');
`cargos_count` pinta el ícono. Guard REAL server-side
`trg_cargos_ajuste_guard` (0117: `origen IN ('ajuste','promo')`): setting
super-only `cobranza.ajustes_habilitados` + topes
`ajuste_max_porcentaje/_monto` + motivo + solo descuento_*. CONDONACIÓN
(0117): descuento del 100% → total 0 → cuota `pagada` (espejo en
`cuota_estado.dart`). Una promo multi-mes se aplica cuota por cuota (sin
multi-select; `grupo_promo` reservado). Al anular un pago, sus descuentos
(`cargos_extra.pago_id`) se borran — `trg_pagos_revertir_descuentos` +
mirror en `anularPago` (M3); los cargos del admin (sin pago_id) NO se
tocan. El descuento de origen 'cobro' exige motivo server-side
(`trg_cargos_cobro_motivo_guard`, 0117).

### Clientes — `lib/features/clientes/` · `lib/features/admin/clientes/`
**[H]** El catálogo de clientes del ISP. Detalle COMPARTIDO admin+cobrador en
**pestañas con forma de botones** (rediseño 2026-06-17): **Detalle** (etiquetas +
fotos en 2 columnas + **Historial de pagos READ-ONLY** abajo, Feature 2) · **Contratos** (preview de cada contrato con
"Pagadas X/Y"; activos y suspendidos prominentes, terminales colapsados) · **Equipos**
(solo con módulo de inventario) · **Visitas** (OPCIONAL, gateada por el setting
super-admin `cobranza.registrar_visitas`, default OFF — ver §3 Settings).
**`clientes.notas` (0227, 2026-08-10):** nota INTERNA sobre la PERSONA ("atiende
la hija después de las 3", "el perro está suelto"), distinta de `contratos.notas`,
que describe el SERVICIO y muere con él. Se muestra en la ficha a TODOS los roles
que llegan a ella —incluido el cobrador, que es quien toca el timbre— y se edita
en el form (`admin/clientes/cliente_form_screen.dart`), o sea admin,
admin_cobranza y admin_usuarios: el cobrador NO tiene camino de edición y la RLS
de `clientes` tampoco se lo permitiría. **Nunca sale en recibo, PDF ni export.**
El historial salió gratis: `notas` ya estaba en `kAuditCamposVisiblesDefault`
['clientes'] y en el override vivo de los tenants. La identidad
(avatar/código/nombre/Llamar/Navegar) queda fija debajo de las pestañas. Conecta con
**contratos**, **geografía** (picker), **red** (puerto del cliente), **mapa**.
**[AI]** Lista cobrador `clientes_list_screen.dart` (paginada, "Cargar más") ·
admin `clientes_admin_screen.dart` (**PAGINADA por subconsulta interna desde
v0.16.0** — `_ListaState` agrega SOLO la página visible vía `WHERE c.id IN (SELECT id
FROM clientes c WHERE <filtros> ORDER BY c.nombre LIMIT ?)` [trae `_limite+1` para
saber "hay más" exacto], scroll infinito de a 60, **spinner** en la 1ª carga,
suscripción MANEJADA [no `StreamBuilder`] → build puro; antes agregaba sobre los
4.606 de golpe = segundos de "Sin clientes". El **contador del header es el TOTAL
real** [`Fmt.entero` → "4.281 clientes"] vía una query `COUNT(*)` aparte con el MISMO
`construirFiltroClientes` que "Seleccionar todos del filtro" → siempre coinciden; el
filtro **Estado de servicio** es el caso pesado [calcula para filtrar]. Export y
select-all usan su propia query NO paginada [cubren todo el set]. Botón de
exportación Excel; filtros multi-selección `FiltroMultiDropdown` — ver §3 Shared) ·
detalle
compartido `cliente_detail_screen.dart` (role detection) · form
**Búsqueda CONFIGURABLE** (v0.13.1, migración `0145`): qué campos entran al buscar
un cliente lo decide el super_admin con toggles `busqueda.por_*`
(código/cédula/teléfono/código-de-contrato; el **nombre siempre** entra) en
Avanzado → "Búsqueda de clientes". Las **5 búsquedas** (lista admin, lista
cobrador, Cobros, global, mapa) usan el helper compartido
`data/utils/busqueda_cliente.dart`: `busquedaClienteSql` (WHERE, para las 3 SQL) +
`busquedaClienteMatch` (client-side, para Cobros/mapa que filtran en Dart por
diseño anti-flicker). El teléfono strippea a dígitos ambos lados (matchea
importados con guiones). El **código de contrato** encuentra al cliente padre por
sus contratos hijos. Default todos ON (= búsqueda previa). Apagar Teléfono evita
falsos positivos.
**Folding ñ/acentos (CRÍTICO, fix 2026-06-22 — regla 1d):** `foldBusqueda(String)`
(Dart) y `foldSqlExpr(String col)` (SQL, `replace()` encadenado + `lower()`) pliegan
AMBOS lados de la comparación a una forma canónica ASCII-minúscula (ñ→n, á→a…). Sin
esto, SQLite `lower()`/`upper()` (ASCII-only, NO bajan Ñ ni vocales acentuadas)
dejaban INVISIBLE en la búsqueda a todo cliente con ñ en el código (se guarda en
MAYÚSCULA, ej. `JÑ0048`; la query `jñ0048` no matcheaba `lower('JÑ0048')='jÑ0048'`).
Plegar a ASCII además hace la búsqueda tolerante a tipear con o sin ñ/tilde. **Mismo
patrón fuera de búsqueda** (mismas funciones): unicidad de código (cliente/contrato
forms), unicidad de categorías de inventario, búsqueda de pagos por nombre, pickers
de cliente (inventario/tickets), y `_resolverId` de data-ops. Test:
`test/busqueda_cliente_test.dart`.
**Placeholder dinámico:** `placeholderBusqueda(settings)` arma el hint de la barra
listando SOLO los campos habilitados por los toggles (apagás teléfono → no aparece
"teléfono" en el hint) — consistente con lo que realmente se busca. En clientes_list,
clientes_admin y cuotas (Cobros).
**Chip de código de contrato:** se REMOVIÓ de la tarjeta de cliente (lista admin +
lista cobrador, 2026-06-22): se quería BUSCAR por código de contrato, no MOSTRARLO
(ya no hay `GROUP_CONCAT` de códigos en esas filas). La búsqueda por contrato sigue
intacta (la hace `busquedaClienteSql` por subquery a `contratos`). · form
`cliente_form_screen.dart` (PopScope guard + `formDirtyProvider`) ·
`widgets/geo_picker.dart` + `red_picker.dart`. Campo **`clientes.email`** (text
opcional, migración `0130`, aditiva → no bumpea `_dbWipeVersion`): "Email" en la
sección de información personal del form (validator `Validators.email`, opcional) y
se muestra en el detalle (`_row`). **Historial de pagos (Feature 2, 2026-06-21):** al final del tab Detalle,
sección READ-ONLY `_HistorialPagosSection`/`_PagoFilaReadOnly` (en `cliente_detail_screen.dart`) que agrupa por
contrato los pagos del cliente vía **`clientePagosProvider`** (`contrato_providers.dart`; join
`pagos→cuotas→contratos→planes` por `cu.cliente_id`, SIN LIMIT — historial completo). Solo display: mes de
servicio · fecha · método · monto (tachado si anulado); **NO abre detalle ni anula** (eso sigue en el detalle de
contrato — no se duplicó lógica de plata). Reusa el modelo `Pago` + `Fmt`. Tablas: `clientes`, `fotos_cliente` (max 10), `visitas`;
lee geo + `red_puertos`. Historial: `HistorialOpLog(entidad:'clientes')` (modelo
op_log per-objeto — ver §3 Audit/Change log; reemplazó al agregador
`HistorialClienteWidget`). La pestaña Visitas muestra
"Registrar visita" solo si NO se está impersonando (la visita se atribuye al usuario;
`visitas_service` también lo bloquea server-side). La galería de fotos cachea las URLs
firmadas → no recarga al cambiar de pestaña.

### Contratos — `lib/features/contratos/` · `lib/features/admin/contratos/`
**[H]** El vínculo cliente↔plan que GENERA las cuotas (las crea un trigger
server, nunca el cliente). El detalle es el centro de control: cuotas,
pagos, estado, documento. **Cancelar un contrato = dinámica de suspensión pero
PERMANENTE** (rediseño 2026-06-17, migración 0123): NO liquida a 0 — deja viva y
cobrable la deuda real (meses cumplidos + mora previa), prorratea el mes en curso por la
ventana de servicio del `dia_pago` y anula solo los meses futuros pendientes; imprime un
documento de deuda, resuelve las notificaciones de mora del contrato y NO se reactiva.
Exige un motivo (changelog). La deuda se sigue cobrando desde el detalle del contrato
(los cancelados salen de lista/Cobros/mapa — ver **Receta R16**).
**[AI]** `contrato_detail_screen.dart` + `_header/_cuotas/_pagos/_documento`
· form create-only `contrato_form_screen.dart` (la edición se eliminó) ·
providers en `data/providers/contrato_providers.dart`. Total fijo =
`precio_mensual × duracion_meses` (NUNCA suma de cuotas); indefinidos: solo
recaudado.
**Gating por rol (Fase 2 roles, 2026-07-19):** en el header del contrato
(`contrato_detail_header.dart`), `admin_cobranza` NO ve "Recaudado" (C$ ya
cobrado); SÍ ve "Total contrato" y "Pendiente" (lo que falta por cobrar).
"Cambiar plan" se oculta al admin_cobranza (es gestión administrativa, no
cobranza). Suspender/reactivar se MANTIENE (es recuperación de cartera,
alineado con el req "todo lo englobalizado a recuperación de cartera").
Los pagos del contrato (historial + PDF) se mantienen visibles: el
admin_cobranza necesita saber si un cliente pagó para decidir qué cobrar
(es contexto operativo por cliente, no reporte agregado de recaudación). **Colchón de indefinidos (#1, 2026-06-23):** un indefinido activo
mantiene SIEMPRE cuotas `pendiente` contiguas desde el mes-sig-al-inicio hasta
`max(última cuota con pago, mes actual) + 3` (3 de colchón; un adelanto aun
PARCIAL lo corre; piso 3 aun con instalación futura). Lo generan el SERVER
(`generar_cuotas_contrato` 0148: trigger al crear + cron mensual) Y el ESPEJO
OFFLINE `asegurarColchonIndefinido` (`data/utils/colchon_indefinido.dart`,
llamado al COBRAR en `pagos_repo` — NO al crear: ahí lo hace el server, el
cliente colisionaría). Guard por período (≡ `ON CONFLICT`). Verificado por
**INV17**. **Piso anti-backfill (0178, 2026-07-07):** si el contrato YA tiene
cuotas, NINGUNO de los dos paths genera períodos interiores anteriores al
mes-siguiente-a-la-cuota-más-nueva → suspender un indefinido >3 meses y
reactivarlo NO re-factura los meses de la pausa (quedan sin fila, no se cobran);
la generación INICIAL (0 cuotas) queda intacta. `ContratosRepo.cancelarContrato` (espeja `suspenderContrato`; columnas
`cancelado_en/cancelado_por/motivo_cancelacion/cancelacion_deuda_snapshot`, 0123).
Rutas: `/contratos/:id` y
`/admin/contratos/:id` (ambas existen — detalle compartido).
**Detalle (rediseño 2026-06-16):** "Total contrato" muestra EN GRANDE el total
**real** (`recaudado + pendiente`) con hint "ajustado por suspensión" si bajó del
nominal (la suspensión/cambio-de-fecha reducen el real). En pantallas anchas
(≥820px) cuotas y pagos van en **doble panel** lado a lado (`LayoutBuilder`); el
documento del contrato queda al fondo. Las cuotas se ordenan por antigüedad
(default: más antigua primero) y los pagos por mes (default: más nuevo primero),
toggle con flechas ↑/↓. Chips de fecha (`_ContratoFechasChips`): "Primera/Última
cuota" salen del min/max `fecha_vencimiento` de cuotas vivas (no del `fecha_fin`
viejo) + "Día de pago"; indefinido → "Indefinido". Fila "Instalación: {fechaInicio}".
Reimprimir desde PC (recibo / deuda de suspensión) usa "Guardar como"
(`guardarPdfConAviso`), no la impresora térmica.

### Rutas — `lib/features/admin/rutas/rutas_screen.dart` (admin, 2026-06-17)
**[H]** Reasignación de cobradores por ZONA: una comunidad = una ruta. El admin
ve cada comunidad con su cobrador actual y reasigna la ruta entera de una (para
rotar quién la trabaja). El `cobrador_id` del cliente es organizativo (en qué
lista/mapa aparece), no "quién cobra" — eso lo captura el pago (ver §3.5 4b).
**[AI]** `rutas_screen.dart` (ruta `/admin/rutas`, menú admin no-adminOnly).
Deriva el cobrador de la comunidad de sus clientes activos ("Mixto"/"Sin asignar"
en rojo/"(inactivo)"). Reasignar = `UPDATE clientes SET cobrador_id WHERE
comunidad_id AND activo=1` (resetea todos; el server propaga a cuotas vía 0068 →
online). Comparte `SeleccionarCobradorDialog` con la lista de clientes. Filtros
(2026-07-03): chips `Municipio` + `Cobrador` (multi, con "Sin asignar"; matchea
comunidades donde el elegido tiene ≥1 cliente activo — `GROUP_CONCAT DISTINCT`
en la misma query, filtro client-side/offline) + buscador por tokens. **Gotcha
de la des-asignación (fix 0174):** quitar el cobrador (`cobrador_id = NULL`) es
válido — cargos_extra.cobrador_id era la única de las 6 tablas propagadas con
NOT NULL y rebotaba el UPDATE entero con 23502 si el cliente tenía cargos;
0174 la alineó con sus hermanas (nullable). → **R15.**

### Etiquetas de clientes — `lib/features/admin/etiquetas/` (P5, 2026-06-17)
**[H]** Etiquetas personalizables (nombre + color + icono) para marcar clientes
(VIP, moroso histórico, zona difícil…). Un cliente puede tener varias. El admin
define el catálogo; admin/admin_cobranza las asignan desde el detalle del
cliente; el cobrador SOLO las ve (lista/cobros/mapa). Es ORGANIZATIVO/visual, NO
toca dinero.
**[AI]** Tablas `etiquetas` (catálogo) + `cliente_etiquetas` (M2M), migración
`0122` (R10 ×2; `cobrador_id` denormalizado en la M2M + extensión de la cascada
`propagate_cobrador_id_from_cliente` 0068 → baja al bucket del cobrador; NULL =
admin-managed). Catálogo: `etiquetas_admin_screen.dart` (ruta `/admin/etiquetas`,
menú adminOnly) con color picker (`kPaletaColoresEstados`) + icon picker
(`data/utils/icono_helpers.dart`, clave→IconData).
Escritura `data/repositories/etiquetas_repo.dart` (asignar idempotente,
denormaliza `cobrador_id` en el INSERT — el trigger no corre en SQLite offline).
Render: `EtiquetaChip` (`shared/widgets/etiqueta_chip.dart`); las listas (clientes
cobrador/admin, cobros, mapa) traen las etiquetas con una **subquery escalar
GROUP_CONCAT** (separadores `char(31)`/`char(30)`, parse `etiquetaChipsDesdeConcat`)
para NO hacer fan-out con el JOIN de cuotas. Mapa: punto sobre el pin (color de la
1ª etiqueta) + lista en el popup. Asignación en `cliente_detail_screen.dart`
(`_EtiquetasSection` + `_AsignarEtiquetasSheet`). Historial: `etiquetas_repo`
emite `op_log` (catálogo + `cliente_etiquetas` scopeada al cliente, en
`resumen.motivo`). Sync rules v11. → **R10.**

### Recibo + Impresora — `lib/features/recibo/` · `lib/features/impresora/`
**[H]** El comprobante que el cobrador imprime, 100% offline (el logo se cachea
en disco). En Android sale por la térmica **Bluetooth**; en Windows por las
impresoras **del sistema** (USB/red). El admin lo ve/reimprime y puede sacarlo en
PDF. El layout es configurable por bloques con zonas (encabezado/cuerpo/pie) desde
Configuración → Recibos (por tenant), y **cada PC tiene sus propios ajustes finos**
de impresión (**Perfil → Impresora**, ruta `/perfil/impresora`; también se llega
desde el recibo): cada modelo de térmica recorta, centra y corta distinto.
**[AI]** `recibo_screen.dart` (preview + acciones; ORQUESTA qué bytes se mandan
por cada camino) · `recibo_ticket.dart` (el widget que se captura en modo imagen) ·
`recibo_texto_escpos.dart` (modo texto nativo) · `recibo_pdf.dart` ·
`recibo_mora.dart`. Bytes ESC/POS compartidos por TODOS los transportes:
`data/services/impresora/recibo_escpos.dart` (**`GS v 0` armado a mano** — NO
`gen.imageRaster`, que codificaba mal en algunas térmicas: el bug histórico de la
GOOJPRT PT-210). Transportes: `impresora_service{_io,_web}.dart` (Bluetooth,
`kIsWeb` no-op) · `windows_raw_printer.dart` (cola RAW de Windows por FFI/winspool,
sin driver gráfico) · `sistema_impresora_service.dart` (paquete `printing`, PDF al
driver). Logo: `data/utils/logo_termica.dart` (pre-proceso en isolate + cache).
Ajustes: `data/providers/impresora_provider.dart` + pantalla
`features/impresora/impresora_sistema_setup.dart` (favorita propia en SharedPrefs,
claves `impresora_sistema_*`, paralela a la BT del móvil; gate `impresionPorSistema`
= desktop nativo, el plugin BT es un stub muerto en Windows).
Layout: modelo `data/models/recibo_layout.dart` (`kReciboBloquesCatalogo`,
`zonaEfectiva()`, bloque `totales` NO ocultable) ↔ setting `recibo.layout` ↔
editor `admin/settings/recibo_layout_editor.dart` + `recibo_preview.dart`.
Settings: `recibo.titulo/pie_libre/formato_default_mm/mostrar_*`, `empresa.*`.
→ **Receta R3/R9.**

**INVARIANTE del módulo — Android/Bluetooth BYTE-IDÉNTICO.** Todo lo de Windows
entra por parámetros cuyo default es exactamente lo que Android emite hoy
(`umbral 0.5` · `margenIzqDots 0` · `feedFinalLineas 2` · `logoNativo null` ·
`aplicarTamanos`/`logoRasterManual`/`filasPlanas`/`compatible`/`suavizado` = false),
y cada ajuste vive **por dispositivo** (SharedPrefs), nunca por tenant. Es la
lección **v0.22.10-13**: arreglar un modelo tocando el transporte/raster COMPARTIDO
rompió a la flota entera. Lo cubren `test/data/services/recibo_escpos_test.dart` +
`test/features/recibo/{recibo_texto_escpos,tildes_cp850}_test.dart`.

**Windows — 3 modos** (`AjustesImpresionWin`, por-PC, claves `impresora_win_*`):

| Modo | Cómo imprime | Para qué |
|---|---|---|
| **`imagen`** (default) | captura del `ReciboTicket` → raster `GS v 0` por la cola RAW | fiel a la vista previa: conserva diseño, tamaños y logo |
| **`texto`** | ESC/POS de texto nativo (`construirReciboTextoEscPos`) por la misma cola RAW | liviano y SIEMPRE completo (no pierde el pie ni con lista de mora); letra uniforme de la impresora |
| **`driver`** | PDF de rollo al driver vía `printing` (`directPrintPdf`, sin diálogo) | respaldo: solo si la impresora no entiende ESC/POS |

El `driver` imprime EN EL HILO DE LA VENTANA → con drivers lentos la app queda "no
responde" ~10s; por eso existen los otros dos, y por eso el default migró a
`imagen`. Su toggle **"Ajustar al driver"** (`impresoraAjustarADriverProvider`,
default OFF) manda el `PdfPageFormat` exacto del rollo; ON = `usePrinterSettings`
(escape hatch para el driver que sí necesita decidir). Cada impresora se valida con
el botón de prueba (`comandosPruebaEscPos`, ASCII puro: prueba el CANAL, no el
diseño).

**El LOGO, uno por modo** (mismo pre-proceso, distinta emisión):
- Pre-proceso común `procesarLogoTermica` (isolate vía `compute` + cache por
  tenant/tamaño — decodificar un logo de 8000×4500 en el hilo de UI dispara ANR):
  resize a la altura EXACTA de display + híbrido umbral/dither Bayer (sólidos
  limpios, tonos medios —el naranja de Telenet— como gris). El flag `suavizado`
  (interpolación `average` + gate del dither en bordes acromáticos) está **gateado
  a desktop** → Android sigue con el pipeline de siempre.
- **`imagen`**: el logo se emite **APARTE**, ANTES del cuerpo (`rasterLogoCentrado`
  + `logoNativo` en `comandosReciboEscPos`/`…Segmentado`, y la captura va con
  `_capturarReciboPng(sinLogo: true)`). Por qué: dentro de la captura lo
  re-binarizaba el `umbral` GRUESO del texto (0.62, subido a propósito para que la
  letra salga negra) y eso le CERRABA los huecos a los arcos finos (el ícono de
  wifi salía como un manchón). Emitido aparte va a resolución nativa y umbral 0.5
  — que es como el modo TEXTO ya lo hacía bien, y ese contraste papel-a-papel fue
  la prueba. El logo y el cuerpo se centran con los MISMOS getters
  (`_margenImpresion` / `_offsetDerechaImpresion`) + tope al ancho útil del cuerpo,
  para que no diverjan.
- **`texto`**: `logoRasterManual: true` → el MISMO `rasterGsv0` manual, centrado con
  padding blanco horneado. `gen.image` (= `ESC *`) NO lo dibujaba en la 3nStar.
- **Android/BT**: el logo va DENTRO de la captura (modo imagen) o por `gen.image`
  (modo compatible), sin tocar.

**Ajustes por-PC** (Perfil → Impresora; se guardan por dispositivo):

| Ajuste | Modos | Qué hace |
|---|---|---|
| **Ancho de línea** (`charsPorLinea`, 28 al máximo del rollo: 48 en 80mm / 32 en 58mm) + botón **"Imprimir regla de ancho"** | texto | el ancho imprimible REAL de esa impresora. La **regla** (`comandosReglaAnchoEscPos`) imprime líneas de largo EXACTO rotuladas en AMBOS extremos (rotular los dos lados distingue **truncar** de **envolver**: con un solo rótulo, el firmware que envuelve haría anotar un ancho MAYOR al real). El número que salga completo se carga en el slider y **manda siempre** (default 42 = 504 dots, ~6mm de aire) |
| **Tildes** (`impresoraTildesModoProvider`) | texto | `ascii` "Sin tildes" (**default en Windows**, translitera á→a: 0 bytes altos, infalible y alinea perfecto) · `gbk` "Acentos" (acentos REALES en el alfabeto NATIVO chino + ñ/Ñ como glifos de usuario `ESC &`) · `cp850` "Estándar" (**default Android**) · `latin1` "Occidental". ⚠️ Mismo provider, **rótulos distintos por pantalla**: la de Bluetooth (`impresora_setup_screen.dart`) los llama Estándar/Occidental/**Alternativo**(gbk)/**Simplificado**(ascii) |
| **Compatibilidad de imagen** (`imagenCompatible`) | imagen | emite el bitmap con `ESC *` (comando viejo) en vez de `GS v 0`, para las térmicas que reciben el raster moderno y escupen sus bytes como caracteres sueltos |
| **Grosor del texto** (`umbral`, 0.45–0.85, default **0.62**) | imagen | cuántos píxeles pasan a tinta. Ya no afecta al logo (se emite aparte) |
| **Impresión lenta** (`impresoraEnvioLentoProvider`, default OFF) | imagen | `comandosReciboEscPosSegmentado` + `WindowsRawPrinter.enviarSegmentos`: **un solo job**, un `WritePrinter` por banda `GS v 0` + pausa de 35ms. Acota la tasa de entrada al ritmo del cabezal para no desbordar el buffer (128 KB en la RPT004) en recibos largos con mora. El corte cae SIEMPRE en frontera de comando |
| **Avance antes del corte** (`impresoraAvanceCorteProvider`, `ESC d n`, default **6** en Windows / 2 en Android) | imagen+texto | la cuchilla está ~1–1.5 cm ARRIBA del cabezal: sin avanzar esa distancia el ÚLTIMO bloque (pie/slogan) queda atrapado en el hueco, la cuchilla lo corta por arriba y reaparece en el tope del recibo siguiente |
| **Forzar densidad del cabezal** (`tiempoCalor`, `ESC 7`, default off) | ambos | opt-in: no toda térmica soporta `ESC 7` y una que no lo entienda escupe basura |
| **Margen izquierdo** (`margenMm`) | imagen+texto | ⚠️ hoy solo lo aplica la **impresión de prueba** (`GS L`). El recibo real manda `margenIzqDots: 0` y **hornea** el margen —padding del widget en `imagen`, espacios (`_indentPlano`) en `texto`— porque estas térmicas ignoran el `GS L` |

**Por qué las decisiones raras (no re-litigarlas — todas salieron de la 3nStar
RPT004 de campo: 80mm, 576 dots imprimibles sobre ~636 de papel, buffer 128 KB, y
firmware que IGNORA `GS L`, `ESC $` y `FS .`):**
- **Márgenes simétricos en `imagen`**: `ReciboTicket.offsetDerechaDots = 30`
  (gateado a 80mm + desktop) corre el CUERPO para compensar la zona muerta física
  de 60 dots, que cae toda a la derecha; el ancho del contenido no cambia, solo se
  re-reparte el padding. Con default 0 el `EdgeInsets` es idéntico al de Android.
- **Filas PLANAS en `texto`** (`filasPlanas: true` → `_filaPlano`): `gen.row` ancla
  el valor por posición ABSOLUTA (`ESC $`) + `ESC a 2`, y esta térmica ignora el
  `ESC $` y justifica al BORDE FÍSICO → se come 2-3 caracteres. **Ninguna palanca
  de posición lo arregla** (bajar columnas, `spaceBetweenRows`, `GS L`: todas se
  probaron y ninguna movió el corte). La fila etiqueta:valor se arma como TEXTO
  PLANO rellenado con espacios → el valor se ubica por CONTEO de chars desde x=0,
  inmune a lo que el firmware no honre. Ídem `_centroPlano`, que parte las líneas
  centradas por PALABRAS (el `ESC a 1` centra sobre el ancho nominal y no parte: el
  monto en letras se salía del papel). Solo aplica con tildes ≠ `gbk` (sus pares
  fullwidth ocupan 2 celdas). Android sigue con `gen.row`.
- **La sangría sale de ADENTRO del ancho**, nunca se le suma: si se sumara, cargar
  el número medido por la regla produciría líneas más largas y volvería el corte —
  justo el bug que la regla viene a cerrar.
- **`aplicarTamanos: false`** en Windows/texto: fuente A 1×1, jerarquía por negrita
  (como Android). Duplicar el ancho parte a la mitad los caracteres por línea.
- **Logo a resolución NATIVA**: el supersample 2× que se probó fue una REGRESIÓN
  (promedia el dither a gris → moiré en los arcos finos). La CAPTURA sí va a
  `pixelRatio 2` — pero eso es para el TEXTO, y el downscale con `average` lo
  aprovecha.
- **Envío lento de Bluetooth** (`impresoraEnvioLentoProvider`, el MISMO toggle):
  hoy es **un write ÚNICO + settle de 2s antes del disconnect** (el `writeBytes`
  retorna con datos encolados en el stack BT y el disconnect inmediato cortaba la
  cola, siempre el pie). La v1 partía en chunks de 512B con pausas de 20ms y eso
  **rompió** el raster en la 3nStar (las pausas caían EN MEDIO del bloque binario
  del `GS v 0` → el firmware se desincronizaba e imprimía el bitmap como texto);
  el chunking se eliminó. En Windows el equivalente es por bandas, y ahí sí se
  puede porque cada banda es un comando ESC/POS COMPLETO.

### Mapa — `lib/features/mapa/mapa_screen.dart` (compartido 3 shells)
**[H]** Clientes geolocalizados coloreados por estado de cuota (6 estados).
El cobrador queda limitado al rango; el admin tiene "Ver todo". Tiles con
caché en disco → funciona offline. Geolocalización en vivo del usuario en
tiempo real (online/offline) con marcador pulsante y botón de centrado rápido.
**[AI]** `MapTileCache` (`data/services/map_tile_cache.dart`, OSM + 
flutter_map_cache, web cae a red). Capa calle = OSM, satélite = Esri World
Imagery (toggle `_satelite`). **Zoom (2026-06-16)**: el `TileLayer` satelital
usa `maxNativeZoom: 17` (OSM 19) → más allá flutter_map **agranda** el último
tile en vez de pedir el gris "Map data not yet available" de Esri (que en zona
rural se queda sin foto ~z17); `MapOptions.maxZoom: 20` da un acercamiento extra
(borroso pero útil). Mismo arreglo en el picker. Niveles ajustables según
cobertura rural real. Colores: `cobranza.colores_estados` vía
`estadoVisualCuota()`. Rutas: `/mapa`, `/admin/mapa`, `/tecnico/mapa`.
**PERFORMANCE — estado precalculado (Opción 2, v0.16.0):** el mapa NO cruza más las
cuotas. El color de cada pin sale de `clientes.vencimiento_mas_viejo` (FECHA de la
cuota pendiente/parcial más vieja de contratos activos + manuales, **precalculada**):
`_buildStream` deriva los 5 flags de estado con un `CASE` sobre esa columna (sin `LEFT
JOIN cuotas` ni `GROUP BY`) → "Ver todo" de ~16-19s a ~3s con 4.442 pines, rápido hasta
en teléfonos (es cómputo LOCAL del CPU). `_estadoDe` y el setting `coloresEstados`
quedan INTACTOS (se guarda una FECHA, no un color — no se hardcodea nada). El
**default** (no "Ver todo", no Soporte) trae SOLO cobrables vía
`date(vencimiento_mas_viejo) <= hoy + diasVisibles` (~154 vs 4.442) + **spinner** (no
más "Sin ubicaciones" falso). La columna la mantiene el **trigger server 0150**
(`cuotas_vmv`/`contratos_vmv` → `recalc_vencimiento_mas_viejo`, SECURITY DEFINER) + el
**mirror offline** `recalcVmvDeContrato` (`data/utils/colchon_indefinido.dart`, llamado
al cobrar en `pagos_repo`). Es date-independent → SIN cron diario; el color se computa
al vuelo. Verificado prod: estado precalc == vivo, 0 mismatches. **Límite v1:** el
mirror offline cubre el COBRO; suspender/cambio-fecha/anular offline → color stale hasta
sync (el trigger online lo corrige).
Búsqueda multi-campo + filtros multi-selección `FiltroMultiDropdown`
(cobrador/zona/comunidad/nodo, `Set<String>?`, filtro client-side `.contains`).
Ubicación actual vía `geolocator` con marcador
custom (`UbicacionActualMarker`, en `shared/widgets/mapa_widgets_compartidos.dart`
— público, compartido con el picker de ubicación) y centrado en cámara. La geo
del cobro NO existe (lat/lng null by-design). El **selector de ubicación**
(`shared/widgets/mapa_picker_screen.dart`, lo usan el form de cliente y el de
nodo de red) replica la misma UX: rotación + brújula, pin de ubicación actual,
toggle calle/satélite y atribución (2026-06-14).

### Dashboard admin — `lib/features/admin/dashboard/`
**[H]** El "cómo viene el negocio" del admin: cobros hoy/semana/mes, mora,
top cobradores, distribución de cuotas, sparkline. Lee lo mismo que reportes
— si difieren, hay bug (invariante #10).
**[AI]** `dashboard_admin_screen.dart` (ruta `/admin/resumen` desde 2026-06-20 —
ya no es la landing; se abre como una card más de la galería) +
`data/providers/dashboard_providers.dart` (KPIs como StreamProviders con
`dbEpochProvider`). Cortes de día en hora Nicaragua (UTC-6). KPIs derivan de
`pagos` no anulados (`monto_cordobas`).
**Gating por rol (Fase 2 roles, 2026-07-19):** `admin_cobranza` NO ve las
secciones de dinero recaudado: CobrosKPIs, ConsultarPeriodoCard,
ProyeccionCobrosCard, Sparkline7d, TopCobradoresCard (5 ocultas). SÍ ve las
operativas: RecuperacionCard (%), OperativoKPIs (clientes/mora/pendiente),
DistribucionCuotasCard (pie de estados). Gate client-side vía
`cobradorActualProvider.esAdminCobranza`.
**Principio de gating:** lo que se oculta es el **dinero RECAUDADO** (lo que
entró a caja / se cobró); lo **PENDIENTE por cobrar** (mora, saldos, deuda)
se mantiene visible porque es la herramienta de trabajo del admin_cobranza.
→ **Receta R2.**

### Reportes — `lib/features/admin/reportes/`
**[H]** Generador UNIFICADO (reforma 2026-06-22): **filtros compartidos arriba**
(período + cobradores) que valen para TODOS los reportes, y **un solo "Generar
reporte" → diálogo (tipo + formato Excel/PDF)**. 11 tipos (cobranza, cobros, por
cobrador, arqueo, fiscal, eficiencia, anulaciones, mora, estado de clientes,
inactivos, padrón); descriptores en `_tiposReporte` (`_TipoReporte`: qué formatos,
`soloDetallado`, `filtraCobrador`, `soloAdmin`). El toggle `reportesDetallados`
controla qué tipos ofrece el diálogo (solo "cobranza" si OFF) + muestra las
tarjetas analíticas.
**Gating por rol (Fase 2 roles, 2026-07-19):** `admin_cobranza` NO ve los 5
reportes de dinero (`soloAdmin: true`): cobranza, cobros, por_cobrador, arqueo,
fiscal. SÍ ve: eficiencia, anulaciones, mora, clientes, inactivos, padrón.
Tarjetas analíticas: oculta RecaudacionMensualCard y CobradoresMesCard; mantiene
MoraPorComunidadCard y PlanesPopularesCard. Gate client-side vía
`cobradorActualProvider.esAdminCobranza`. Mismo principio: oculta recaudado,
mantiene operativo.
**Filtro de cobradores** (`reporteCobradoresProvider`, null=todos; helper
`filtroCobradorSql` → fragmento `AND col IN (?,?)`): aplica a los reportes DE COBRO
—por `p.cobrador_id`; los que AGRUPAN por cobrador (arqueo, eficiencia) por
`cb.id`—; los POR-CLIENTE (mora/estado/inactivos/padrón) lo **IGNORAN**. El arqueo
usa el **rango global** (presets Hoy/Ayer; ya no tiene rango propio). PDF y Excel
del mismo tipo salen de la MISMA query → totales idénticos (invariante #10).
**[AI]** `reportes_admin_screen.dart` (queries + generador unificado) ·
`pdf/reporte_*_pdf.dart` · `excel/reporte_excel.dart` ·
`descarga_archivo.dart` (`file_picker.saveFile`, Windows/Android; web avisa)
· `arqueo_calculo.dart`. Headers Excel↔PDF alineados. Cortes por
`date(fecha_pago)` vs boundary Nicaragua (¡`fecha_pago` es local-naive a
propósito — NO normalizarla a UTC!). **Branding** (2026-06-12): los 9 PDF
llevan el LOGO del tenant en `buildHeaderEstandar` (`pdf/pdf_utils.dart`,
bytes de `logoEmpresaBytesProvider` — cache offline del recibo, helper
`_logoParaReportes`); el Excel lleva header tipográfico (empresa/título/
período via `construirExcelBytes`) porque la lib `excel` no embebe imágenes.
→ **Receta R8.**

### Historial / Home / Perfil (cobrador) — `lib/features/historial/`, `settings/perfil_screen.dart`
**[AI]** `historial_screen.dart` (sus cobros; anular si
`cobranza.cobrador_anula_cobros`) · perfil con config de impresora, cambio de
password y card "Cambios sin sincronizar" (`_RechazosSyncCard`: rechazos de
sync persistidos por `RechazosSyncService`; también en el perfil del técnico).
La landing del cobrador es la lista de Cobros (no hay home aparte).

### Settings — `lib/features/admin/settings/` + `data/repositories/settings_repo.dart`
**[H]** El panel de configuración del tenant (tabs Empresa/Cobranza/Pagos/
Recibos/Avanzado). El tab Avanzado es solo del super (reglas sensibles con
`editable_por='super_admin'` enforced server-side).
**[AI]** **`settings_repo.dart` es LA fuente de verdad** de claves/defaults/
getters (`AppSettings`). UI: `settings_admin_screen.dart` renderiza lo
declarado en `settings_groups.dart`. Editor de layout del recibo acá.
Catálogo completo de claves en **§5**. → **Receta R6.**
**El tab Avanzado se agrupa en 5 CATEGORÍAS de dominio** (`kCategoriasAvanzado`
en `settings_groups.dart`, reorg 2026-06-27): Reglas de cobro y dinero ·
Permisos y operación del cobrador · Avisos y notificaciones · Visibilidad y
reportes · Búsqueda e historial. `SettingCategoria` envuelve los `SettingGroup`
(+ `cardsEspeciales` para las 2 que no son SettingGroup: `whatsapp_api`,
`historial`); `kGruposAvanzado` se DERIVA aplanando las categorías. El screen
hace early-return `_buildAvanzadoCategorizado` (encabezado `_CategoriaHeader` +
mini-grilla por categoría). Agregar una sección al Avanzado = meter el
`SettingGroup` en la categoría que corresponda (no al final suelto).

### Auth + Sync gate — `lib/features/auth/`
**[AI]** `login_screen` (sin signup público) · `set_password_screen`
(invite/recovery) · `auth_flow_provider.dart` · `sync_gate_screen.dart`
(escape hatches a 120s/180s) · `syncReadyProvider`/`syncGateGraceProvider`
(8s) · `authIdentityProvider` (detección de user-switch). El ciclo
connect/disconnect vive en `main.dart` (§2).

### Super admin — `lib/features/super_admin/` + `data/repositories/super_admin_repo.dart`
**[H]** El panel SaaS de Rubén: tenants, módulos por tenant, miembros
(password/email/rol/eliminar vía Edge Functions), logs de errores, e
**impersonación** (entra a un tenant como su admin, con banner, auditoría
start/end y acciones de campo bloqueadas).
**[AI]** `SuperAdminRepo` va por RPC/Edge (NO SQLite). Impersonación:
`data/services/impersonation_service.dart` (único write-path; escribe
`super_admin_impersonation`) → `impersonatedTenantIdProvider`
→ `tenantIdProvider` resuelve el tenant efectivo → router lo lleva a
`/admin/*`. Edge Functions (6): `crear-tenant`, `invitar-cobrador`,
`reenviar-invitacion`, `forzar-password-cobrador`, `cambiar-email-cobrador`,
`eliminar-cobrador` + `_shared/` (passwords/auth_errors/response). Patrón:
`callerClient` (RLS) para DB; `service_role` SOLO `auth.admin.*`/rollback.
Tabla auxiliar: **`reinvite_locks`** (0144) — lock anti doble-reenvío usado
solo por la Edge `reenviar-invitacion`. SERVER-ONLY: RLS habilitada SIN
policies (solo la escribe la Edge con service_role); NO va a `schema.dart` ni
a sync rules — mismo patrón que `whatsapp_credenciales`.
**Gating de módulos (modelo de datos):** catálogo global **`modulos`**
(`codigo`, `es_base`) + M2M **`tenant_modulos`** (lo leen
`modulosHabilitadosProvider` y `tenant_tiene_modulo()` de las RLS 0114). Al
crear un tenant, `trg_tenants_habilitar_modulos_base` (0026) habilita solo los
`es_base=true`; `trg_tenants_seed_settings` siembra los settings (R6). Se
togglean vía RPC `set_tenant_modulo` desde el panel super_admin.

### Operaciones de datos — `lib/features/admin/settings/data_ops_screen.dart`
**[H]** El panel para que **el super_admin corrija errores de carga** (cliente/
contrato mal importado) borrando data DESDE LA APP, sin pedir un SQL a mano por
chat — con red de seguridad: **preview** (cuánto se borra) → **confirmación por
tipeo del código** → **backup restaurable** → **registro**. 3 operaciones:
**limpiar cliente** (borra su cobranza, conserva el cliente), **eliminar contrato**
(uno solo) y **eliminar cliente** (todo + el cliente). Vive como tab "Operaciones"
de Config (`settings_admin_screen.dart`, categoría `'operaciones'`), gateado por
`esSuperAdmin` en el menú Y en el propio widget (defensa en profundidad).
**[AI]** UI por RPC (NO SQLite): `_OperacionCard` llama `super_admin_preview_*` y
`super_admin_ejecutar_*` (migración **0147**, 6 funciones SECURITY DEFINER) vía
`Supabase.instance.client.rpc`. Anti-pantalla-negra (regla #7 del audit): **nada de
`showDialog` como loading** — flag `_isLoading` + overlay en el `Stack`, guards
`mounted` tras cada await. `_resolverId(codigo)` traduce el código tipeado a UUID
buscando con **`foldSqlExpr`** (no `upper()`: matchea ñ/acentos) y **aborta si el
código es ambiguo** (>1 fila por fold accent-insensitive). La confirmación valida
contra el código RESUELTO en el preview, NO el texto vivo del campo (invariante
independiente del reset).
- **Tablas** (migración **0146**, aditivas): `data_op_backups` (snapshot `jsonb` de
  las filas borradas, por tabla → restaurable) + `data_ops_log` (historial:
  operación/target/`afectados`/`backup_id`/actor). **RLS: SOLO el super_admin LEE**
  (`for select using is_super_admin()`); SIN policies de INSERT/UPDATE/DELETE para
  usuarios → el INSERT lo hacen las funciones SECURITY DEFINER (service_role bypassa
  RLS). **NO se sincronizan a clientes**: el panel las lee por REST con el JWT del
  super_admin (igual que `tenants`/`tenant_modulos`) → **no van a `schema.dart` ni a
  sync rules**.
- **Patrón de borrado SEGURO** (las 6 funciones, gate `is_super_admin()` que usa
  `auth.uid()` → chequea al LLAMADOR, no al definer; + validación `p_tenant` =
  defensa en profundidad del scope que la UI ya filtra): **snapshot COMPLETO**
  (incl. `cargos_extra`/`notificaciones_mora`/`saldos_favor` que caen por cascade, y
  el `op_log` de las entidades) → **borrado en orden FK** (`pagos` PRIMERO porque
  `pagos.cuota_id` es NO ACTION; después un solo delete del contenedor —contrato o
  cliente— deja que el CASCADE arrastre cuotas/recibos/cargos/suspensiones) →
  **limpieza de `op_log`** por `entidad_id` (el change log es client-written
  append-only, no lo borra ningún cascade) → registro en `data_ops_log`.
  `inv_seriales`/`inv_movimientos`/`tickets` con `cliente_id` quedan **SET NULL** (se
  desvinculan, NO se borran).
- **Guard de crédito cross-contrato** (en `eliminar_contrato`): el saldo a favor es a
  nivel CLIENTE y cruza contratos. Si borrar las filas `saldos_favor` de ESTE contrato
  dejara el saldo restante del cliente **negativo** (= este contrato originó crédito
  consumido en otro), la función **bloquea** y sugiere "Eliminar cliente completo".
- **Expansión "starter pack" (2026-06-28, aún sin liberar):** además de los 3 borrados,
  el panel suma operaciones que REUSAN el mismo patrón RPC seguro (SECURITY DEFINER +
  `is_super_admin()` + `p_tenant`): **Verificar invariantes de dinero** (`0153`,
  `_VerificarInvariantesCard` — corre los 17 invariantes de `invariantes_dinero.sql`
  scopeados al tenant, read-only; el cierre de todo fix de dinero sin abrir el SQL
  Editor). ⚠️ **El RPC es una COPIA del `.sql` canónico y puede derivar de él:**
  `0219` arregló un **mojibake** en `super_admin_verificar_invariantes` — el literal
  `'Suspensión temporal'` del INV11 había quedado con la `ó` corrupta al re-crear la
  función por string-replace (`0218`) bajo una sesión con encoding equivocado. Como
  la data tiene la `ó` correcta, la comparación NUNCA matcheaba → INV11 no reintegraba
  las cuotas anuladas por suspensión y daba **falso positivo en TODO contrato fijo
  suspendido**. El `invariantes_dinero.sql` del repo nunca tuvo el bug. Regla: al
  reescribir este RPC, verificar los literales acentuados por CONTENIDO, no solo que
  la función exista. **Reasignar cobrador en masa** (`0154`, `_ReasignarCobradorCard` con
  `SelectorBuscable` — UPDATE de `clientes.cobrador_id` dispara el trigger 0002 que
  propaga a contratos/cuotas; ORGANIZATIVO, no toca dinero ni quién cobró) y
  **Restaurar backup** (`0155`, botón "Restaurar" en el historial — re-inserta el
  snapshot `jsonb` con `session_replication_role=replica` para NO disparar la
  generación de cuotas ni recálculos; `on conflict do nothing` = idempotente +
  no pisa data actual). El historial (`_HistorialFila`) muestra "Restaurar" solo en
  los borrados con `backup_id`. Tras restaurar, conviene correr "Verificar invariantes".
- **Operaciones de Tickets e Inventario (2026-06-28, sin liberar — RPCs `0156`-`0171`):**
  19 operaciones nuevas, mismo patrón seguro (SECURITY DEFINER + `is_super_admin()` +
  `p_tenant` + preview/ejecutar + `data_ops_log`). **Diagnóstico read-only:** verificar
  invariantes de **inventario** (`0156`, 8 chequeos estructurales del stock) y de **tickets**
  (`0157`, 7) — el `_VerificarInvariantesCard` quedó PARAMETRIZADO (rpc/título/mensaje) y se
  instancia 3× (dinero/inv/tickets). **Masivas:** reasignar técnico (`0158`), transferir
  equipos entre ubicaciones (`0159`), cerrar tickets viejos sin actividad (`0160`), reabrir
  ticket (`0161`), resolver incidente + cerrar sus tickets (`0162`). **Correcciones:** baja/
  recuperar serial (`0163`), reconciliar huérfanos (`0164`, fix de INVI2), ajuste por conteo
  físico granel (`0165`), corregir vínculo (`0166`) / estado (`0167`) de serial, corregir
  fecha/SLA (`0168`), anular ticket con unwind de materiales (`0169`), reversar movimiento
  granel (`0170`) / consumo (`0171`). **Export read-only a Excel** (tickets + inventario,
  `_ExportarCard` reusa `descargarExcel` de reportes). **Cards genéricas nuevas:**
  `_ReasignarMasivoCard` (2 selectores → preview-conteo → ejecutar; reusada técnico +
  transferencia), `_OpInputCard` (1 input número/texto/selector/`ninguno` + 2º campo opcional
  → contrato preview `{afectados,label}` / ejecutar `{afectados,mensaje}`), `_AjusteConteoCard`,
  `_CorregirVinculoCard`, `_CorregirEstadoSerialCard`; helper top-level `_cargarFuente(_FuenteSel)`
  para los selectores DB. **Reglas respetadas:** `inv_movimientos` APPEND-ONLY (corregir =
  movimiento inverso, nunca UPDATE/DELETE); stock serializado = COUNT(en_stock), granel =
  Σdestino−Σorigen; guard de transiciones de serial (las correcciones de metadato `0166`/`0167`
  lo bypassan con `session_replication_role=replica` DELIBERADO, acotado al UPDATE + reset
  como `0155`); matriz de transiciones de tickets (`0162` usa paso intermedio en_progreso para
  abierto/asignado→resuelto); **SLA wall-clock**: `created_at` es naive-as-if-UTC → `0168` setea
  con `timezone='UTC'`, NO Managua (era un bug, lo cazó el audit). Idempotencia de reversas
  granel (`0170`/`0171`) por `motivo` que embebe el id + selectores que excluyen reversas/
  consumos ya hechos. **Auditadas** (workflow adversarial 4-dim: 2 bloqueantes fixeados —
  SLA tz + reversa duplicable). **Gating por módulo:** las cards de Tickets y de
  Inventario solo se muestran si el módulo (`'tickets'`/`'inventario'`) está habilitado
  para el tenant impersonado (`modulosHabilitadosProvider`, mismo mecanismo que el menú
  admin); el panel se ordena en secciones (Diagnóstico · Cobranza · Tickets · Inventario ·
  borrados · historial). **NO incluido:** importar stock por Excel (feature grande aparte).
- **Deploy:** las tablas y funciones se corren en Postgres (0146/0147 + 0153/0154/0155 +
  **0156-0171**, ya en prod `vxxz`; aditivas, sin efecto hasta que un build llame las cards);
  el panel es solo UI. Receta de cambios: **R19**.

### Geografía — `lib/features/admin/geografia/`
**[AI]** CRUD jerárquico `departamentos→municipios→comunidades`
(**per-tenant desde 0097**, con RLS + audit). Consumido por `geo_picker.dart`
en clientes. Baja a todos los roles (catálogo).

### Red — `lib/features/admin/red/`
**[AI]** Topología `red_nodos→red_hubs→red_puertos` + asignación
cliente↔puerto (`red_picker.dart`). Baja a todos (el cobrador necesita el
puerto del cliente). Consumidor principal: **incidentes** (derivación de
afectados) y tickets (`puerto_id`).

### Inventario (módulo opcional) — `lib/features/admin/inventario/`
> 0118 (Opción A): `trg_inv_seriales_guard_transicion` — 'baja' es terminal (no se puede
> cambiar de estado una vez dado de baja), instalar exige venir de `en_stock`, un
> instalado no cambia de cliente sin pasar por stock, y se bloquean transferencias tardías
> (no se puede cambiar `ubicacion_id` de un `'instalado'` sin pasarlo antes a `'en_stock'`).
> `inv_movimientos.ocurrido_en` en UTC.
> **0204 — `en_revision` + `redes` + 'descarte':** `en_revision` es el LIMBO del
> retorno (cliente/red → técnico → revisión → bodega si sirve, descarte si no).
> Las 4 transiciones nuevas PASAN el guard de 0118 sin tocarlo: `instalado →
> en_revision` no dispara la regla de transferencia tardía porque un instalado
> siempre tiene `ubicacion_id` NULL (lo deja así `asignarEquipo`), y `revisión →
> instalado` queda BLOQUEADO por el server — que es justo el ciclo pedido: el
> equipo tiene que aprobar y volver a bodega antes de reinstalarse.
> **Revisión NO toca el ledger de ubicación** (su movimiento va sin origen ni
> destino): toda salida de `en_stock` ya debitó su ubicación, y `darDeBajaEquipo`
> solo descuenta si el equipo estaba `en_stock` → depositarlo al entrar a revisión
> lo habría inflado para siempre. El `+1` lo hace recién `devolverEquipo`.
> `redes` = tipo de ubicación para material montado en planta (sin cliente dueño).
> **'descarte' es el LABEL de 'baja'** — el valor en DB no cambió (data viva + 61
> usos del literal); el vocabulario del nuevo dueño habla de descarte.
> ⚠️ El rol `tecnico` **NO tiene RLS de escritura** sobre `inv_seriales`
> (`inv_update` exige `is_admin_or_cobranza()`): todo lo que el técnico mueva de
> inventario debe pasar por `ticket_materiales` + trigger server-side (patrón 0106).
**[H]** Stock del ISP: catálogo, ubicaciones (bodega/custodia del técnico),
seriales cuna-a-tumba y ledger de movimientos. El stock NO es un contador:
se DERIVA (serializado = COUNT de seriales `en_stock`; granel = Σdestino−Σorigen).
**[AI]** Vista operativa `inventario_v2_screen.dart` (tabs Equipos/Existencias,
sobre `ListaPaginadaScroll`+`FiltrosBar`) · ficha `ficha_equipo_screen.dart`
(`/equipo/:id`) · catálogo `inventario_catalogo_screen.dart` (`/catalogo`) ·
acciones de equipo `inv_seriales_acciones.dart` · ingreso/movimiento de stock
`inv_stock_flows.dart` · op_log `inventario_oplog.dart`
· estado común `inventario_comun.dart` · `equipos_en_baja.dart` (baja
cross-módulo) · `data/providers/inventario_alerta_provider.dart` (stock mínimo).
Tablas:
`inv_categorias`, `inv_proveedores`, `inv_productos`, `inv_ubicaciones`,
`inv_seriales`, `inv_movimientos` (nombres completos, grep-ables).
Sync: admin-only (NO baja al cobrador; el técnico baja SOLO su custodia).
Gate: módulo `inventario` (menú+router+**RLS 0114**). Historial:
`HistorialOpLog(entidad:'inv_seriales')` (seriales + movimientos como alta vía
`op_log`; reemplazó a `HistorialSerialWidget`).
**Conecta con (mapa de impacto — revisar al tocar inventario; detalle en R21):**
`Clientes` (`inv_seriales.cliente_id`/`contrato_id` → la ficha del cliente lista
equipos, `cliente_detail_screen.dart _EquiposInstaladosSection`) · `Tickets`
(`ticket_materiales` → trigger 0106 → `inv_movimientos 'consumo'` + serial
`instalado`) · `Red` (al asignar avisa si el cliente no tiene `puerto_id`) ·
`op_log` (emite historial en sus flujos) · menú/badge de stock bajo
(`inventario_alerta_provider`). **NO** entra a las métricas de dinero.
**Rediseño en curso** (rama `Inventario-Tickets`, 2026-06-25, ver
`docs/PROPUESTA-INVENTARIO.md`): partir CONFIG (catálogo → admin panel) de OPERACIÓN
(existencias/equipos → vista exclusiva) + estandarizar lista paginada
(`ListaPaginadaScroll`) y filtros (`FiltrosBar`) del gold-standard de Clientes +
ficha de equipo. Orden y cadena de integridad: **Receta R21**.

### Tickets + Técnico + Incidentes (módulo opcional) — `lib/features/admin/tickets/`, `lib/features/tecnico/`, `lib/features/admin/incidentes/`
> 0118 (M19): la generación de eventos del ticket se realiza automáticamente en el
> servidor (`trg_tickets_eventos_auto`), eliminando inserciones client-side de
> creación, asignación y cambios de estado.
> 0116 (M18): el correlativo local del ticket es PROVISORIO — en conflicto el
> server lo re-asigna (`trg_tickets_correlativo`). Transiciones terminales por rol confirman.
> **0208/0209/0210 — cierre del call center y verificación del gestor (Fases 3-4):**
> · Un intento de contacto es un `ticket_eventos` con `tipo_evento='contacto'` (no hay
> tabla nueva). Tras N intentos + D días (settings `tickets.cierre_intentos_min` /
> `cierre_dias_min`) se habilita cerrar sin confirmar, con motivo, marcado en
> `tickets.cerrado_sin_confirmar` para poder MEDIRLO.
> · **El auto-cierre por vencimiento YA EXISTÍA desde 0109** (`tickets_auto_cierre` + cron
> `tickets_auto_cierre_diario` 06:30 UTC, setting `tickets.auto_cierre_dias`). Está en 0
> (apagado) en los 4 tenants — prenderlo es configuración, no código.
> · Al cerrarse una orden de tipo `efecto='instalacion'`, el trigger
> `tickets_marcar_verificacion` la deja `pendiente` para el gestor. Es TRIGGER porque una
> orden se cierra por 3 caminos y uno es el cron (sin app abierta).
> · ⚠️ `admin_usuarios` NO estaba en `tk_write` ni bajaba tickets: 0210 le abre UPDATE
> acotado a las 3 columnas de verificación (trigger `tickets_gestor_solo_verificacion`) y su
> bucket baja SOLO las pendientes. **Regla que se repitió 3 veces (0205/0207/0210): antes de
> darle un botón a un rol, chequear su RLS Y su bucket — offline se ve OK y falla al
> sincronizar.**
>
> **0205/0206/0207 — el técnico y el coordinador (Fase 2):**
> · **Retiro:** `ticket_materiales.tipo` = 'consumo' | 'retiro'. El técnico NO tiene
> RLS de UPDATE sobre `inv_seriales`, así que TODO movimiento de inventario suyo va
> por `ticket_materiales` (policy `tm_insert` = `is_ticket_staff()`) + el trigger
> `ticket_materiales_consumo`, que es SECURITY DEFINER. La rama de retiro deja el
> equipo en `en_revision` con un movimiento NEUTRO (sin origen ni destino, ver 0204)
> y es idempotente ante el duplicado offline.
> · **Cola (`tickets.orden_cola`):** una orden a la vez. Se libera con `resuelto`, NO
> con `cerrado` — cerrar es del call center y depende de ubicar al cliente; atarlo al
> cierre paralizaría al técnico por algo que no controla. `en_espera` NO participa de
> la cola (es el estado de "esperando repuesto"; si bloqueara, dejaría al técnico sin
> poder trabajar). Lógica pura y testeada en `data/utils/cola_tecnico.dart`.
> · **Rol `coordinador`:** escribe SOLO `asignado_a` y `orden_cola`. ⚠️ Lo enforza el
> trigger `tickets_coordinador_solo_orden`, **NO la RLS** — las policies son ROW-level
> y dejarían pasar la fila entera; y `GRANT UPDATE (col)` tampoco sirve porque Supabase
> autentica a todos con el mismo rol de Postgres. Compara el row menos las columnas
> permitidas, así una columna futura queda protegida sola. **Sus helpers `is_*` deben
> COALESCE adentro**: `current_user_rol()` es NULL sin usuario resuelto, y en plpgsql
> `IF NOT NULL` no se cumple → el guard se saltea (bug real, cazado en la prueba).
> Vive en el shell `/admin-tickets`; bucket `por_coordinador` en las sync rules.
>
> **0204 — `tickets.lat` / `tickets.lng`:** ubicación REAL donde se ejecutó la
> orden. Es del TICKET, no del cliente: la ficha puede estar mal geolocalizada y
> lo que audita el trabajo es dónde se paró el técnico. NULL = sin marcar; no se
> re-marca una orden `cerrado`/`cancelado`. La captura de GPS vive en
> `data/utils/ubicacion_actual.dart` (`UbicacionActual.obtener()`), extraída
> porque la danza de permisos estaba duplicada en `mapa_screen` y `mapa_picker`.
> Devuelve un resultado en vez de mostrar SnackBars → usable sin árbol de widgets.
**[H]** El ciclo de trabajo de campo: admin crea/asigna → técnico resuelve
offline (avanzar/pausar/resolver, checklist, fotos, comentarios) y consume
materiales de su custodia (descuenta inventario e instala el equipo en el
cliente) → admin cierra. Cortes masivos = incidentes con afectados derivados
de la red. SLA con semáforo que tickea offline y se pausa en espera.
**[AI]** Estados (8) con matriz `kTransicionesTicket` en
`data/utils/ticket_sla.dart` — espejo del trigger server (0103/0105). SLA:
`slaHorasEfectivas` (min tipo/prioridad) + `ticketSlaEstado/Restante`;
`created_at` SIEMPRE se parsea con **`parseTicketWallClock`** (wall-clock por
componentes — un `DateTime.parse` crudo corre el deadline 6h post-sync).
Pausa exacta server-side en `segundos_pausado` (0105). Consumo de materiales:
fila en `ticket_materiales` (auditada) → trigger SECURITY DEFINER (0106) →
`inv_movimientos 'consumo'` + serial `instalado` (derivados a depth 2, no
auditados). Incidentes: alcance nodo|hub|puerto|general (CHECK un_solo_nivel),
afectados por JOIN de la red, `alcance_label` snapshot. Settings:
`tickets.sla_horas_por_prioridad`, `tickets.auto_cierre_dias` (cron 0109).
Sync del técnico: SOLO sus tickets/clientes/custodia — cero dinero.
Historial: `HistorialOpLog(entidad:'tickets')` (ticket + sub-entidades
—adjuntos/materiales/checklist/reasignación— scopeadas al ticket vía `op_log`,
texto en `resumen.motivo`; reemplazó a `HistorialTicketWidget`). Rol
`admin_tickets` (VIVO desde 2026-06-22, `0e72fec`): admin acotado a
tickets/inventario-catálogo, con shell móvil propio `admin_tickets_shell.dart`
en `/admin-tickets/*` (home tickets + mapa + perfil; detalle/form/tipos
pusheados fuera del shell), guards de exclusión en router y bucket
`por_admin_tickets` — se ofrece en el alta de personal si el tenant tiene el
módulo (0 usuarios asignados en prod a hoy). Gate: módulo `tickets`
(menú+router+RLS 0114). **OJO trigger (fix 0176, audit F3 2026-07-05):** invitar
`tecnico`/`admin_tickets` los coaccionaba a `admin` (escalación de privilegios) —
`handle_new_user` nunca se sincronizó con el CHECK/`set_cobrador_rol` de 0103.
Al agregar un rol NUEVO, actualizar SIEMPRE la whitelist de `handle_new_user`
(hoy en 0176) además del CHECK de `cobradores.rol` y `set_cobrador_rol`.
**Tablas del módulo:** `tickets`, `ticket_tipos` (tipo_id RESTRICT),
`ticket_adjuntos` (fotos/archivos; ticket_id CASCADE), `ticket_eventos`
(timeline — lo inserta SOLO el server vía `trg_tickets_eventos_auto`, el
cliente no escribe acá; ticket_id CASCADE), `ticket_materiales` (ticket_id
CASCADE), `incidentes`. Borrar un ticket arrastra adjuntos/eventos/materiales.
**Integración con cobranza (Fase 1, 0172 — "link liviano"):** `tickets.contrato_id`
(FK SET NULL) vincula la orden a un servicio; `ticket_tipos.efecto`
(`ninguno|instalacion|corte|reconexion`) la clasifica. De esos 2 metadatos se
DERIVAN 2 colas (`data/providers/colas_servicio_provider.dart` →
`ColasServicioPanel`, arriba de la lista de tickets, solo shell admin): "cortes
resueltos sobre contrato activo → falta suspender" y "contrato suspendido con saldo
de cuotas vivas = 0 → falta reactivar". Son QUERIES read-only — **cero trigger de
plata, cero cambio en `pagos_repo`/`contratos_repo`**: el panel solo navega a
`/admin/contratos/:id` y el admin dispara suspender/reactivar con la UI existente
(manual, gateado, bloqueado al impersonar). La orden de corte se genera desde
Avisos/mora (botón → form con `?cliente=`). El form avisa si una orden de corte/
reconexión no tiene contrato (no alimentaría las colas). Taxonomía de DOS PUERTAS:
trabajo físico (instalación/corte/reconexión) por ticket; mora/anexos/descuentos por
cobranza pura. Automatismo por trigger SECURITY DEFINER = FASE 2 diferida (exigiría
portar suspender/reactivar a PL/pgSQL — el grueso del riesgo).
**Sync (audit Fable 5, 2026-07-02):** las colas son un `tickets` JOIN `ticket_tipos`,
así que AMBAS tablas deben estar en el bucket de sync de quien alcanza el Centro.
El bucket `todo_tenant_admin_cobranza` NO las traía → la cola "ya cortados" le
llegaba **vacía a `admin_cobranza`** (sí al admin full, que tiene su propio bucket).
Fix: agregar `tickets` + `ticket_tipos` (scoped por `tenant_id`) a
`todo_tenant_admin_cobranza` en `powersync/sync-rules.yaml` (paridad con
`todo_tenant_admin`/`impersonated_tenant`). Requiere redeploy de sync rules.

### Audit / Change log — SOLO `op_log` (`audit_log` ELIMINADO 0140) — `lib/data/utils/op_log*.dart` + `shared/widgets/historial_op_log.dart`
> REWORK 2026-06-20 (`0128`/`0129`/`0131`): el historial que ve el usuario lo
> escribe el **CLIENTE** como **log de intención** en `op_log`, NO un trigger.
> **El viejo `audit_changelog_trg`→`audit_log` (forense) se ELIMINÓ POR COMPLETO
> (0140, 2026-06-21):** 33 triggers + funciones + tabla + panel `/admin/audit` +
> RPC `list_audit_cobrador`. Ya NO hay rastro forense server-side; `op_log`
> (client-written) es el único registro de cambios. Diseño op_log: `CHANGELOG-REWORK.md`.
**[H]** Toda entidad editable tiene su historial (quién/cuándo/qué) accesible
desde su pantalla, con UN renglón por intención del usuario (no las ~5 filas por
fila-de-DB del modelo viejo). Lo escribe el cliente dentro de la misma
transacción que muta el dato (offline-first: la app es el único lugar donde
"esto es UN cobro" existe como unidad atómica).
**[AI] Modelo `op_log`** (tabla nueva PowerSync-synced, append-only): el cliente
escribe, dentro de su `writeTransaction`, **UNA fila por cada OBJETO afectado**
por la intención, scoped a los atributos de ESE objeto (la cuota NO hereda del
contrato). Las filas de una misma intención comparten `op_id`, `actor` y
`ocurrido_en`. Columnas clave: `op_id` · `tipo_op` (enum: `cobro`/`cobro_multiple`/
`anulacion_pago`/`edicion_pago`/`cambio_fecha`/`suspension`/`cancelacion`/
`reactivacion`/`revertir_*`/`aplicar_credito`/`disposicion_excedente`/`alta_entidad`/
`edicion_entidad`/`baja_entidad`) · `entidad` + `entidad_id` (scope del `WHERE`) ·
`actor_id`/`actor_label` (super_admin → `OpLogActor.systemAdmin`, `actor_id` NULL,
label "System Admin") · `diff` **text** (no jsonb — ver gotcha abajo) con
`{campos:[{campo,antes,despues}], resumen:{...}}` · `ocurrido_en` device-time UTC.
- **Código:** helper `OpLog` en `data/utils/op_log.dart`
  (`escribir`/`escribirCambioEntidad`/`escribirBaja`;
  `OpLog.actorDeUsuario` resuelve el actor) · allowlists curadas AL ESCRIBIR en
  `data/utils/op_log_campos.dart` (`kOpLogCamposVisiblesDefault`/`kOpLogCamposCatalogo`/
  `opLogCamposVisibles` — el diff nace ya filtrado, sin fallback permisivo) ·
  widget único `shared/widgets/historial_op_log.dart` (`HistorialOpLog(entidad,
  entidadId)`: `WHERE entidad=? AND entidad_id=? ORDER BY ocurrido_en DESC`,
  1 entrada por intención, fecha/hora AM/PM + actor + desplegable antes→después;
  oculta lo vacío). Enchufado en TODAS las pantallas de historial (reemplazó a los
  ~11 `Historial*Widget` y a los agregadores; ya NO hay regla de profundidad,
  `kAuditCamposSuperficie` ni la ventana-3s). Panel super-only de visibilidad por
  ENTIDAD: `op_log_campos_screen.dart` (`OpLogCamposScreen`, Config→Avanzado→
  "Campos del historial") → setting `op_log.campos_visibles`.
- **Lo emiten** (per-objeto, dentro de su `writeTransaction`): `pagos_repo`
  (cobros/`edicion_pago`/`cambio_fecha`/anulación), `contratos_repo` (las 7
  mutantes: suspender/cancelar/reactivar/revertir×2/aplicar_credito/
  disposicion_excedente, + `cambiarEstadoSimple`), `settings_repo`,
  `etiquetas_repo`, `visitas_service`, y los ~50 forms CRUD de entidades
  (clientes/planes/cobradores/red/geografía/inventario/tickets+sub/incidentes).
- **RLS de `op_log`** (0128 + 0131): `op_log_read` (`tenant_id=current_tenant_id()
  AND is_admin_or_cobranza()`) · `op_log_insert`/`op_log_update`
  (`tenant_id=current_tenant_id() AND (actor_id=auth.uid() OR actor_id IS NULL)`)
  · **`super_admin_all`** (`FOR ALL USING/WITH CHECK is_super_admin()`, agregada en
  `0131` — faltaba). El super_admin **LEE** `op_log` por las **sync rules** (bucket
  `impersonated_tenant`), NO por la policy de SELECT. Necesita policy **UPDATE**
  aunque sea append-only porque el conector sube con `upsert` = `INSERT ... ON
  CONFLICT DO UPDATE` (gotcha 0129, ver abajo).
- **⚠️ LECCIÓN (bug 2026-06-20):** `op_log` nació en 0128 SIN `super_admin_all` →
  el super_admin impersonando NO podía INSERT/UPDATE (su `current_tenant_id()` no
  matchea el tenant impersonado) → "Sin permiso" al cambiar un setting. **Toda
  tabla tenant-scoped nueva DEBE nacer con `super_admin_all` a mano** (R10). Otro
  gotcha de 0129: `diff` debe ser **text**, no jsonb — PostgREST sube el string
  JSON del cliente y jsonb lo guarda doble-encodeado.
- **`audit_log` ELIMINADO (0140, 2026-06-21):** se dropearon los 33 triggers
  (`trg_changelog_*` + `trg_audit_settings`), las funciones (`audit_changelog_trg`,
  `audit_registrar`, `audit_reset_password`, `list_audit_cobrador` + deprecadas) y
  la tabla. Los 3 RPCs que escribían audit_log (`set_cobrador_rol`/`_activo`,
  `set_tenant_modulo`) se redefinieron **sin** ese insert. Del lado app se borró
  el panel `/admin/audit`, `audit_campos_screen`, el modelo `AuditEntry` y la
  "auditoría por cobrador" del super_admin. `data/utils/audit_changelog.dart` se
  MANTIENE (op_log usa sus constantes de campos). **Trade-off aceptado por Rubén:**
  sin rastro forense tamper-proof de resets/impersonación/anulaciones (`op_log` es
  client-written). Settings huérfanos (`audit.campos_visibles`,
  `cobranza.audit_visible_admin`) quedan en `_hidden` para no colarse en "Otros".

### Shared / Shells
**[AI]** `shared/widgets/`: `offline_banner` (banner rojo "Sin conexión"; desde
2026-06-16 escucha `conexionRealProvider` —sondeo TCP real al backend— NO el
`SyncStatus` de PowerSync, que no detecta caídas silenciosas y daba falsos
positivos; rojo solo tras ~15s sin alcanzar el backend; sin aviso "red
inestable"), `sync_gate_screen`, `impersonation_banner`, `update_banner`
(auto-update IN-APP: descarga con progreso vía `update_service` + instalador
del sistema con open_filex; GitHub Releases `latest` es el endpoint; la firma
del APK usa el keystore local `sitecsa-release.jks` — ver 0-Setup §3b),
`descuento_dialog` (EL diálogo de descuento: el admin graba ajuste/promo
desde el sheet de la cuota) · `cargo_dialog` (reconexión/otro del admin,
graba vía `aplicarCargo`),
`historial_op_log` (EL widget de historial — ver §3 Audit/Change log;
`historial_cambios_widget` se borró en Fase 3c), `filtro_multi_dropdown`,
`empty_state`, `skeleton`, etc.
Shells: `features/shell/app_shell.dart` (cobrador, bottom-nav) ·
`features/admin/shell/admin_shell.dart` (**galería de inicio** reescrita
2026-06-20 — `MenuGaleriaScreen` grid de cards + `AdminSubGaleriaScreen`
"Administración"; gates por rol/módulo/setting + badges; AppBar con back-al-menú
+ avatar + indicador de sync — Receta R12) · `super_shell.dart` ·
`tecnico/tecnico_shell.dart`. `global_search_delegate.dart` (búsqueda global
del admin). `shared/widgets/filtro_multi_dropdown.dart` (`FiltroMultiDropdown`:
búsqueda + multi-selección + jerarquía municipio→comunidad + "todos→null"=sin
filtrar; usado en Cobros/Clientes/Mapa — reemplazó el `DropdownFiltro`
single-select).
`shared/widgets/selector_buscable.dart` (`SelectorBuscable` / `elegirConBuscador<T>` +
`OpcionSelector<T>`: EL selector **single-select de listas de la base** — la contraparte
de `FiltroMultiDropdown`. Campo `TextField` readOnly + `onTap` → abre un diálogo con
**buscador en vivo** (`foldBusqueda`: insensible a ñ/acentos y SIMÉTRICO; auto-oculta el
buscador en listas ≤8; muestra "N de M") y devuelve el valor por `Navigator.pop`.
**Por qué existe (bug 2026-06-26):** un `DropdownButton`/`DropdownButtonFormField`
alimentado por una lista de la DB (`ps.db.watch`/`getAll`) DENTRO de un diálogo NO
commitea su `onChanged` — su menú es una ruta-overlay (`_DropdownRoute`) que anida mal
sobre el overlay del diálogo: el valor mostrado cambia pero el campo del State queda
null → "elegí X" fantasma. Reemplazó ~15 dropdowns de lista-DB app-wide (inventario:
ingreso/movimiento/categoría · contratos: cliente/plan · tickets: tipo/técnico/incidente/
materiales · incidentes: nodo/hub/puerto · clientes: cobrador · `red_picker` · `geo_picker`).
**Regla uniforme (AGENTS audit #10):** lista de la base + elegir-uno → `SelectorBuscable`;
**enum fijo** (rol, prioridad, **método de pago**, duración) → `DropdownButton` OK (commitea
aunque esté en diálogo, no se tocó); **multi-selección** → `FiltroMultiDropdown`. Toda
búsqueda/filtro pliega con `foldBusqueda` (audit #1d). Gotcha: para un valor nullable
("— Sin asignar —"/"— Ninguno —") usar una **fila centinela** + `identical()` para
distinguir "cancelé" de "elegí nada".)

---

## §3.5. Modelo de dinero y facturación (LA REGLA DE ORO)

> Esta sección es la fuente única de cómo "piensa" la app la plata. Todo cambio
> que toque cuotas/pagos/contratos/suspensión/cambio-de-fecha/reportería DEBE
> respetarla. Los 10 invariantes de dinero viven en `AGENTS.md`; acá está el
> **modelo del que salen** (el porqué). Si una pantalla no cuadra con esto, la
> pantalla está mal, no el modelo.

### (1) Facturación VENCIDA — qué representa una cuota

La app factura **vencido**: una cuota se cobra al FINAL del período de servicio
que cubre, no al principio. Para una cuota:

- **`cuota.periodo`** = primer día del **mes de VENCIMIENTO** (no del mes de
  servicio). Es una etiqueta interna (`AAAA-MM-01`), NO se le muestra cruda al
  usuario.
- **`cuota.fecha_vencimiento`** = `calcular_fecha_pago(periodo, dia_pago)` =
  el `dia_pago` clampeado al mes del período + ajuste domingo→lunes (no se cobra
  domingo). Es la fecha que el cliente debe pagar.
- **Ventana de servicio que cubre** = `(venc_anterior, venc_propio]` — desde el
  vencimiento de la cuota ANTERIOR (exclusivo, ya cubierto) hasta el suyo
  (inclusivo). Ej. `dia_pago 15`, periodo junio → cubre **(15-may, 15-jun]**.
- **Mes que se MUESTRA al usuario = el MES DE SERVICIO, anclado al DÍA DE PAGO
  FIJO** (`dia_pago` del contrato + `cuotas.periodo`), vía
  `Fmt.mesServicioLabel(periodo, dia_pago)` / `Fmt.mesServicio`. Facturación
  vencida → la cuota que vence el `dia_pago` del mes P cubre el servicio del mes
  anterior; el día 15 parte aguas:
  - `dia_pago 1-14`  → mes mostrado = **periodo − 1** (el servicio se consumió
    sobre todo el mes anterior al vencimiento).
  - `dia_pago 15-31` → mes mostrado = **periodo**.
  Ej.: instaló 05/ene, día 5, 1ª cuota vence 05/feb (periodo febrero) → "Enero".
  **Anclado al `dia_pago` FIJO, NUNCA al día del vencimiento:** `calcular_fecha_pago`
  corre el domingo→lunes, así que un día 14 en domingo vence el 15 — usar ESE día
  lo clasificaría mal como ≥15 y saltaría el mes (bug PN0190). Con el día fijo el
  mes es CONSTANTE y único por cuota.
  **Historia:** v0.22.5 lo introdujo (mes de servicio) → v0.31.3 lo revirtió al
  "mes de período" (ignoraba `dia_pago`) por el corrimiento → **2026-08-01
  (v0.31.9) se RESTAURÓ el mes de servicio**, ahora robusto porque toma SOLO el día
  de pago fijo (SE0047 día 5 salía "Febrero" y debía ser "Enero"; PN0190 día 14
  pasa de Junio/Julio a Mayo/Junio). Se eliminaron `mesServicio*DeVencimiento`/
  `*Seguro` (derivaban el día del vencimiento corrido — código muerto).
  **OJO — es SOLO la etiqueta de display.** La ventana de servicio y el prorrateo
  (abajo, `prorrateo.dart`) SIGUEN anclados al `dia_pago` y NO cambiaron: el
  cambio no toca un centavo, solo cómo se nombra el mes.

**Corolario crítico (de dónde salió el bug de anclaje 2026-06-16):** el período
de servicio se ancla al `dia_pago`, **NUNCA al mes calendario**. Solo cuando
`dia_pago = 1` coinciden; para cualquier otro día (el caso normal) usar el mes
calendario como ancla corre el período medio mes y sub/sobre-cobra. Cualquier
lógica de "qué servicio cubre esta cuota a una fecha X" usa el helper de abajo.

### (2) El ancla del día_pago — `data/utils/prorrateo.dart`

Un único helper define la ventana de servicio; toda feature de prorrateo lo reusa:

- **`servicioFin(periodo, diaPago)`** → el venc NOMINAL (día_pago clampeado al
  mes, SIN ajuste domingo→lunes: es SERVICIO, no cobro). Es el MISMO ancla que
  `pagadoHasta` del cambio de fecha.
- **`ventanaServicio(periodo, diaPago)`** → `(inicio EXCLUSIVO, fin INCLUSIVO)`
  de la cuota: `(servicioFin(periodo−1mes), servicioFin(periodo)]`.
- **`estadoServicio(periodo, diaPago, x)`** → clasifica el servicio a la fecha
  `x`: **`'cumplido'`** (`fin ≤ x`, servicio entregado completo → cobrar ENTERA),
  **`'en_curso'`** (`inicio ≤ x < fin` → prorratear los días consumidos),
  **`'futuro'`** (`inicio > x`, no empezó → anular).
- **`montoPuente(pagadoHasta, anclaServicio, precioMensual)`** → suma día a día,
  cada día valuado a `precio_mensual / días reales de SU mes` (junio=/30,
  julio=/31). El servicio corre todos los días (domingos incluidos); el ajuste
  domingo→lunes es solo de la fecha de COBRO.

Estos helpers los comparten **cambio de fecha** (R13) y **suspensión** (R14): la
misma matemática de "días de servicio a precio diario" en los dos lados.

### (3) Los números que importan (invariantes, resumen operativo)

- **Saldo canónico de una cuota** = `max(monto + COALESCE(cargos_neto,0) −
  monto_pagado, 0)`. IDÉNTICO en TODA pantalla (inv. #10). En SQL:
  `(cu.monto + COALESCE(cu.cargos_neto,0) − cu.monto_pagado)`.
- **`pagos.monto_cordobas`** = lo APLICADO a la cuota (lo que entra a caja),
  NUNCA lo entregado. **`vuelto_cordobas`** = devuelto, SIEMPRE en córdobas.
  **`monto_original`** = entregado en su moneda. `original × tasa ≈ aplicado +
  vuelto`.
- **`recaudado`** = `SUM(pagos.monto_cordobas)` no anulados. Nunca lo entregado,
  nunca el vuelto.
- **Total de contrato FIJO** = `precio_mensual × duracion_meses` (NUNCA la suma
  de cuotas). `pendiente = Σ saldos canónicos cobrables` (NO `total − recaudado`
  nominal cuando hay suspensión/cambio-de-fecha: ver matiz inv. #5). Indefinidos:
  solo "total recaudado", no hay pendiente.
- **`cuota.monto_pagado`** lo mantiene un trigger server (`recalcular_cuota_
  desde_pagos`); el cliente solo lo ESPEJA offline, jamás lo calcula a mano.
- **Anular un pago** restaura la cuota (trigger) y PRESERVA el pago.

### (4) Reportería — dashboard ≡ reportes (inv. #10)

Toda cifra de dinero sale del **saldo canónico**; si dos pantallas difieren, una
está mal. Reglas vigentes (2026-06-16):

- **Dashboard = reportes**: leen lo mismo. El "por cobrar"/"vencido" del titular
  y todas las queries de mora **EXCLUYEN suspendidos** (`COALESCE(ct.estado,
  'activo') != 'suspendido'`) → la deuda suspendida no se esconde, va al KPI
  "Suspendido (por reactivar)" aparte (titular + suspendido = total).
- **Días de mora** del reporte = `días desde el venc − dias_gracia` →
  coincide con el badge "Vencida Nd" de la UI (`diasFromVence − diasGracia`).
- **Cortes de día** en hora Nicaragua: `date('now','-6 hours')` /
  `julianday('now','-6 hours')`, NUNCA pelado (SQLite es UTC).
- **Recibos y reportes**: rotulan cada cuota con `Fmt.mesServicioLabel` /
  `Fmt.periodoRecibo` = **el mes de SERVICIO anclado al `dia_pago` fijo**
  (2026-08-01, ver §3.5-1). App, reportes de cobranza/historial y recibo dicen
  todos el MISMO mes — si dos difieren, uno está mal (pasó en v0.31.0-0.31.2 con
  el reporte de cobranza). El `dia_pago` que se pasa DEBE ser el del contrato
  (`ct.dia_pago`), nunca el día del vencimiento (trae el corrimiento).

### (4b) Cobrador: ORGANIZATIVO vs QUIÉN COBRÓ (regla de oro, 2026-06-17)

Dos `cobrador_id` distintos que NO hay que confundir:
- **`clientes.cobrador_id` (+ denormalizado en `contratos`/`cuotas`) = ORGANIZATIVO**:
  define el **foco de ruta** del cobrador (en qué lista/mapa aparece como "suyo",
  el filtro "Cobrador"/"Ver todo", el agrupador de Rutas, y si puede "Cambiar
  fecha"). Puede ser **NULL** (P3b, "sin cobrador"). Reasignarlo (Rutas / lista /
  form) propaga a las cuotas operativas vía trigger `0068` — NO toca el historial.
  > **#4 (2026-06-23):** este campo YA NO controla la VISIBILIDAD. El cobrador
  > ahora **ve y cobra TODOS los clientes del tenant** (RLS `0149` con
  > `is_personal_cobranza()` + bucket `por_cobrador` ahora tenant-wide,
  > parametrizado por `tenant_id`). `cobrador_id` quedó como dato puramente
  > organizativo (foco de ruta + reportería + filtros). El cobrador NO edita
  > (write admin-only) ni "Cambia fecha" a clientes ajenos (botón gateado +
  > trigger `0119` owner-scoped). ⚠️ El bucket tenant-wide baja todo el tenant a
  > cada dispositivo → ver nota de VOLUMEN en sync rules.
- **`pagos.cobrador_id` / `recibos.cobrador_id` = QUIÉN COBRÓ** (el usuario
  logueado que registró el pago: cobrador, admin o admin_cobranza). NOT NULL,
  inmutable. El **recibo** lo captura de acá, y **toda la reportería** (arqueo,
  "por cobrador") agrupa por ESTE campo — NUNCA por el cobrador asignado del
  cliente. Por eso un cliente sin cobrador igual se cobra (lo registra el admin
  con su prefijo) y aparece en el arqueo bajo quien cobró.

**Invariante** (`invariantes_dinero.sql` INV8): `contrato.cobrador_id` debe
coincidir con `cliente.cobrador_id` (`IS DISTINCT FROM`; ambos NULL = OK).

### (5) Eventos de ciclo de contrato (los que tocan el ancla)

| Evento | Qué hace con la plata | Receta |
|---|---|---|
| Crear contrato | trigger server genera las cuotas del período | §3 Contratos |
| Cobro | aplica a la cuota más vieja; trigger recalcula la verdad | R11 |
| Cambio de fecha de pago | cobra el "puente" (días entre pagado y día nuevo), re-fecha futuras, absorbe las del puente | **R13** |
| Suspensión | clasifica cada cuota por `estadoServicio` (cumplido=entera, en_curso=prorrateo días, futuro=anular); congela snapshot de deuda | **R14** |
| Reactivación | **cualquier día posterior** a la suspensión (mismo día → Revertir); re-ancla `dia_pago` al día de reactivación, revive el gap anulado sin estirar `fecha_fin`; si el corte colisiona con el 1er ciclo reanudado (suspendido tras el día de pago, mismo ciclo) se RE-COMPLETA | **R14** |
| Cancelar contrato (PERMANENTE) | como suspender pero sin reactivar: cumplido=entera, en_curso=prorrateo por ventana de servicio, futuro=anular; **deja la deuda real cobrable (NO liquida a 0)**; congela snapshot, resuelve mora; exige motivo | **R16** |

**Verificación obligatoria** tras cualquier deploy que toque dinero:
`supabase/tests/invariantes_dinero.sql` (toda fila `violaciones = 0`) + suite
`flutter test` (grupos `registrarCobro`/`registrarCambioFecha`/`suspenderContrato`/
`reactivarContrato`).

---

## §3.6. Modelo de datos — el grafo de tablas y cómo se mantiene entrelazado

**Raíz de todo: `tenants`.** TODA tabla operativa tiene `tenant_id` (RLS por
`current_tenant_id()`, invariante #1). Los usuarios son `cobradores` (rol
super_admin/admin/admin_cobranza/cobrador/tecnico).

**La cadena operativa (FK + `ON DELETE`, verificado en prod):**
```
tenants
 └─ cobradores            (usuarios; quién cobró sale de acá)
 └─ clientes              cobrador_id→cobradores · comunidad_id→comunidades(→municipios→departamentos) · puerto_id→red_puertos(→red_hubs→red_nodos, SET NULL)
     ├─ visitas           cliente_id→clientes (CASCADE)
     ├─ fotos_cliente     cliente_id→clientes (CASCADE — ojo: los archivos en Storage NO caen con la fila)
     └─ contratos         cliente_id→clientes (CASCADE) · plan_id→planes · cobrador_id
         └─ cuotas        contrato_id→contratos (CASCADE) · cliente_id · cobrador_id · ticket_id→tickets (SET NULL — la cuota sobrevive al ticket; cobro-desde-ticket 0173)
             ├─ pagos          cuota_id→cuotas (NO ACTION)   ← ¡NO cascadea!
             │   └─ recibos    pago_id→pagos (CASCADE)
             ├─ cargos_extra   cuota_id→cuotas (CASCADE) · pago_id (columna SIN FK — link blando deliberado, 0115; los descuentos del pago los borra el trigger de anulación, no un cascade)
             └─ notificaciones_mora  cuota_id→cuotas (CASCADE) · cliente_id (NO ACTION — bloquea igual que pagos en borrados parciales)
         └─ contrato_suspensiones  contrato_id→contratos (CASCADE)
 └─ saldos_favor          cliente_id/contrato_id→… (CASCADE) · cuota_id/cargo_id/recibo_id (SET NULL)
 └─ cliente_etiquetas     M2M cliente↔etiqueta (ambos CASCADE)
```
**Consecuencia clave del borrado (sostiene la Receta R19):** borrar un contrato
CASCADEA cuotas → y de ahí cargos_extra / notificaciones_mora. PERO
`pagos.cuota_id` es **NO ACTION** → la FK BLOQUEA el borrado de cuotas si hay
pagos. Por eso R19 borra **pagos PRIMERO** (sus recibos caen por el CASCADE de
`pago_id`), y recién después el contenedor. `saldos_favor` es a nivel CLIENTE y
cruza contratos → un borrado parcial debe cuidar no dejar el saldo negativo.

**RESTRICTs (bloquean borrar catálogos en uso — el DELETE falla, no cascadea):**
`inv_productos` ← `inv_seriales`/`inv_movimientos`/`ticket_materiales` (×3: un
producto con historial NO se borra) · `ticket_tipos` ← `tickets.tipo_id` · red:
`red_nodos` ← `red_hubs` ← `red_puertos` · geografía: `departamentos` ←
`municipios` ← `comunidades` (+ `clientes.comunidad_id` NO ACTION). Además los
guards 0102 (`trg_*_guard_borrado` en comunidades/inv_proveedores/
inv_ubicaciones/red_puertos) rechazan con RAISE si el registro está en uso.

### Denormalización: "server gana, el cliente espeja" (el corazón del entrelazado)
Postgres es la fuente de verdad: **triggers server** mantienen los campos
denormalizados. El cliente los **espeja DENTRO de su `writeTransaction`** SOLO
para UX instantánea offline (sin esperar el sync). Mapa de los 4 espejos:

| Campo denormalizado | Vive en | Trigger server (la VERDAD) | Espejo offline (cliente) |
|---|---|---|---|
| `monto_pagado` + `estado` | `cuotas` | `recalcular_cuota_desde_pagos` (en `pagos` y `cargos_extra`) | `pagos_repo` (cobro/anular/editar) |
| `cargos_neto` | `cuotas` | `cargos_extra_actualizar_neto_trg` | repos al tocar cargos |
| `vencimiento_mas_viejo` (color del mapa) | `clientes` | `trg_cuotas_vmv` + `trg_contratos_vmv` (0150) | `recalcVmvDeContrato` — en **todos los flujos que mutan `cuotas.estado`** (`pagos_repo`, `contratos_repo`, `cuotas_repo`). Regla: todo UPDATE de `cuotas.estado` lo llama, igual que el trigger server dispara por `OF estado` |
| `cobrador_id` (organizativo) | `contratos`, `cuotas`, `notificaciones_mora`, `cargos_extra`, `cliente_etiquetas`, `fotos_cliente` (las 6 que propaga el trigger 0122) | `propagate_cobrador_id_from_cliente` (en `clientes`) + `set_cobrador_id_from_cliente` (en contratos/cuotas) | se setea en el INSERT desde Dart (R10 #6). OJO: `pagos`/`recibos`/`visitas`/`saldos_favor` NO van acá — su `cobrador_id` es "quién ejecutó" (§3.5-4b), no se re-propaga |

> **⚠️ "server gana" AHORA ENFORZADO para las columnas derivadas de la cuota
> (0216, 2026-08-02).** Hasta 0216 el espejo era solo una CONVENCIÓN: el cliente
> escribía `monto_pagado`/`estado`/`cargos_neto`, PowerSync los subía y —como
> ningún trigger en `cuotas` los protegía— un device con valor viejo PISABA la
> verdad del server (BUG #1 + finding F2 de la auditoría: desinfla/infla en
> silencio; caso Marcos). Ahora el trigger `BEFORE UPDATE cuotas_forzar_derivados`
> recalcula esas 3 columnas desde la verdad del server en CADA update, ignorando
> lo que mande el device. Guardas: no recomputa `estado` si es `'anulada'`
> (suspensión/absorción/plan) ni en cuotas de `tipo_cargo_manual`. El espejo del
> cliente sigue existiendo (UX offline) pero ya es INOCUO — el server lo corrige
> al subir. Convierte INV2/3/12/14 de "mantenidos" a enforzados.

Otros triggers estructurales: `contratos_generar_cuotas_iniciales_trg` (genera
las cuotas al crear contrato), `contratos_actualizar_cuotas_futuras_trg`
(re-fecha pendientes al cambiar día/fecha), `cuotas_anular_pagos_asociados_trg`,
`resolver/reabrir_notificacion_*` (mora), `saldos_favor_no_sobregiro_trg`,
guards de `tenant` coherente e inmutabilidad de códigos. Y estos, fáciles de
pasar por alto:
- **`contratos_limpiar_cuotas_excedentes_trg` (0023) ⚠️:** al ACORTAR
  `contratos.fecha_fin`, hace **DELETE FÍSICO** de las cuotas `pendiente` con
  vencimiento >= la nueva fecha_fin — la ÚNICA excepción al principio "cuotas
  se anulan, no se borran". Irrecuperable (no queda rastro en op_log).
- **`cobradores_freeze_rol_trg`:** el `rol` de un cobrador NO se cambia por
  UPDATE directo — rechaza el write; solo vía RPC `set_cobrador_rol`
  (super_admin).
- **`*_check_cobrador_update` (0119, en contratos/cuotas/recibos):** si
  `current_user_rol()='cobrador'`, solo permite columnas whitelisted de filas
  PROPIAS (sostiene el "Cambiar fecha" owner-scoped y bloquea plan_id/montos);
  admin/admin_cobranza y el SQL Editor no pasan por el if.

**Regla de oro del `cobrador_id`** (no confundir, §3.5-4b): el `cobrador_id`
denormalizado es **ORGANIZATIVO** (en qué lista/mapa aparece el cliente; puede
ser NULL = admin-managed). QUIÉN cobró lo captura `pagos.cobrador_id` /
`recibos.cobrador_id` (NOT NULL) y TODA la reportería agrupa por ESE campo.

---

### §3.6.1. Mapa EXHAUSTIVO por tabla (generado del schema REAL de prod — 2026-07-03)

**Para agentes AI: antes de tocar una tabla, buscala acá.** La columna
"Referenciada por (← hijas)" es la lista de tablas que se ven AFECTADAS si
modificás/borrás filas de esta; "FKs salientes" son sus padres (lo que esta
tabla necesita que exista). `(CASCADE)` = borra en cadena; `(SET NULL)` = la
hija sobrevive huérfana; `(RESTRICT)` = el borrado del padre se BLOQUEA; sin
sufijo = NO ACTION (bloquea igual, pero al momento del commit). Todas las
tablas operativas tienen además `tenant_id→tenants` (RLS multi-tenant,
invariante #1 — omitido por brevedad). "RLS" = cantidad de policies (0 =
server-only, p.ej. `whatsapp_credenciales`, `reinvite_locks`).

| Tabla | FKs salientes (→ padre) | Referenciada por (← hijas) | Triggers | RLS |
|---|---|---|---|---|
| `cargos_extra` | aplicado_por→cobradores; cobrador_id→cobradores; cuota_id→cuotas (CASCADE) | saldos_favor.cargo_id (SET NULL) | trg_cargos_ajuste_guard→cargos_ajuste_guard_trg(INSERT UPDATE); trg_cargos_cobro_motivo_guard→cargos_cobro_motivo_guard_trg(INSERT UPDATE); trg_cargos_extra_actualizar_neto→cargos_extra_actualizar_neto_trg(INSERT DELETE UPDATE); trg_cargos_extra_recalcular_cuota→recalcular_cuota_desde_pagos(INSERT DELETE UPDATE); validar_tenant_coherente_cargos→validar_tenant_coherente(INSERT UPDATE) | 5 |
| `cliente_etiquetas` | cliente_id→clientes (CASCADE); cobrador_id→cobradores; etiqueta_id→etiquetas (CASCADE) | — | trg_cliente_etiquetas_set_cobrador→cliente_etiquetas_set_cobrador_trg(INSERT) | 4 |
| `clientes` | cobrador_id→cobradores; comunidad_id→comunidades; puerto_id→red_puertos (SET NULL) | cliente_etiquetas.cliente_id (CASCADE); contratos.cliente_id (CASCADE); cuotas.cliente_id; fotos_cliente.cliente_id (CASCADE); inv_movimientos.cliente_id (SET NULL); inv_seriales.cliente_id (SET NULL); notificaciones_mora.cliente_id; saldos_favor.cliente_id (CASCADE); tickets.cliente_id (SET NULL); visitas.cliente_id (CASCADE) | trg_clientes_codigo_inmutable→clientes_codigo_inmutable_trg(UPDATE); trg_propagate_cobrador_id_clientes→propagate_cobrador_id_from_cliente(UPDATE) | 3 |
| `cobradores` | — | cargos_extra.aplicado_por; cargos_extra.cobrador_id; cliente_etiquetas.cobrador_id; clientes.cobrador_id; contrato_suspensiones.reactivado_por; contrato_suspensiones.suspendido_por; contratos.cancelado_por; contratos.cobrador_id; cuotas.anulada_por (SET NULL); cuotas.cobrador_id; fotos_cliente.cobrador_id; fotos_cliente.created_by; inv_movimientos.hecho_por (SET NULL); inv_ubicaciones.cobrador_id (SET NULL); notificaciones_mora.cobrador_id (SET NULL); notificaciones_mora.resuelta_por (SET NULL); notificaciones_mora.vista_por (SET NULL); pagos.anulado_por (SET NULL); pagos.cobrador_id; recibos.anulado_por (SET NULL); recibos.cobrador_id; saldos_favor.cobrador_id; saldos_favor.creado_por; tenant_modulos.habilitado_por (SET NULL); ticket_adjuntos.subido_por (SET NULL); ticket_eventos.hecho_por (SET NULL); ticket_materiales.hecho_por (SET NULL); tickets.asignado_a (SET NULL); tickets.creado_por (SET NULL); visitas.cobrador_id | trg_cobradores_freeze_rol→cobradores_freeze_rol_trg(INSERT UPDATE) | 3 |
| `comunidades` | municipio_id→municipios (RESTRICT) | clientes.comunidad_id | trg_comunidades_guard_borrado→comunidades_guard_borrado(DELETE) | 5 |
| `contrato_suspensiones` | contrato_id→contratos (CASCADE); reactivado_por→cobradores; suspendido_por→cobradores | — | — | 3 |
| `contratos` | cancelado_por→cobradores; cliente_id→clientes (CASCADE); cobrador_id→cobradores; plan_id→planes | contrato_suspensiones.contrato_id (CASCADE); cuotas.contrato_id (CASCADE); inv_movimientos.contrato_id (SET NULL); inv_seriales.contrato_id (SET NULL); saldos_favor.contrato_id (CASCADE); tickets.contrato_id (SET NULL) | contratos_vmv→trg_contratos_vmv(UPDATE); trg_contratos_actualizar_cuotas_futuras→contratos_actualizar_cuotas_futuras_trg(UPDATE); trg_contratos_check_cobrador_update→contratos_check_cobrador_update(UPDATE); trg_contratos_codigo_inmutable→contratos_codigo_inmutable_trg(UPDATE); trg_contratos_generar_cuotas_iniciales→contratos_generar_cuotas_iniciales_trg(INSERT); trg_contratos_limpiar_cuotas_excedentes→contratos_limpiar_cuotas_excedentes_trg(UPDATE); trg_set_cobrador_id_contratos→set_cobrador_id_from_cliente(INSERT) | 4 |
| `cuotas` | anulada_por→cobradores (SET NULL); cliente_id→clientes; cobrador_id→cobradores; contrato_id→contratos (CASCADE); ticket_id→tickets (SET NULL) | cargos_extra.cuota_id (CASCADE); notificaciones_mora.cuota_id (CASCADE); pagos.cuota_id; saldos_favor.cuota_id (SET NULL) | cuotas_vmv→trg_cuotas_vmv(INSERT DELETE UPDATE); trg_cuotas_anular_pagos_asociados→cuotas_anular_pagos_asociados_trg(UPDATE); trg_cuotas_check_cobrador_update→cuotas_check_cobrador_update(UPDATE); trg_reabrir_notificacion_al_anular_pago→reabrir_notificacion_al_anular_pago(UPDATE); trg_resolver_notificacion_al_pagar→resolver_notificacion_al_pagar(UPDATE); trg_set_cobrador_id_cuotas→set_cobrador_id_from_cliente(INSERT) | 6 |
| `data_op_backups` | — | data_ops_log.backup_id (SET NULL) | — | 1 |
| `data_ops_log` | backup_id→data_op_backups (SET NULL) | — | — | 1 |
| `departamentos` | — | municipios.departamento_id (RESTRICT) | — | 5 |
| `etiquetas` | — | cliente_etiquetas.etiqueta_id (CASCADE) | — | 5 |
| `fotos_cliente` | cliente_id→clientes (CASCADE); cobrador_id→cobradores; created_by→cobradores | — | trg_fotos_cliente_set_cobrador→fotos_cliente_set_cobrador_trg(INSERT) | 4 |
| `incidentes` | hub_id→red_hubs (SET NULL); nodo_id→red_nodos (SET NULL); puerto_id→red_puertos (SET NULL) | tickets.incidente_id (SET NULL) | — | 3 |
| `inv_categorias` | — | inv_productos.categoria_id (SET NULL) | — | 5 |
| `inv_movimientos` | cliente_id→clientes (SET NULL); contrato_id→contratos (SET NULL); hecho_por→cobradores (SET NULL); producto_id→inv_productos (RESTRICT); proveedor_id→inv_proveedores (SET NULL); serial_id→inv_seriales (SET NULL); ticket_id→tickets (SET NULL); ubicacion_destino_id→inv_ubicaciones (SET NULL); ubicacion_origen_id→inv_ubicaciones (SET NULL) | — | — | 4 |
| `inv_productos` | categoria_id→inv_categorias (SET NULL) | inv_movimientos.producto_id (RESTRICT); inv_seriales.producto_id (RESTRICT); ticket_materiales.producto_id (RESTRICT) | — | 5 |
| `inv_proveedores` | — | inv_movimientos.proveedor_id (SET NULL) | trg_inv_proveedores_guard_borrado→inv_proveedores_guard_borrado(DELETE) | 5 |
| `inv_seriales` | cliente_id→clientes (SET NULL); contrato_id→contratos (SET NULL); producto_id→inv_productos (RESTRICT); ubicacion_id→inv_ubicaciones (SET NULL) | inv_movimientos.serial_id (SET NULL); ticket_materiales.serial_id (SET NULL) | trg_inv_seriales_guard_transicion→inv_seriales_guard_transicion_trg(UPDATE) | 5 |
| `inv_ubicaciones` | cobrador_id→cobradores (SET NULL) | inv_movimientos.ubicacion_destino_id (SET NULL); inv_movimientos.ubicacion_origen_id (SET NULL); inv_seriales.ubicacion_id (SET NULL); ticket_materiales.ubicacion_origen_id (SET NULL) | trg_inv_ubicaciones_guard_borrado→inv_ubicaciones_guard_borrado(DELETE) | 5 |
| `modulos` | — | tenant_modulos.modulo_codigo (RESTRICT) | — | 2 |
| `municipios` | departamento_id→departamentos (RESTRICT) | comunidades.municipio_id (RESTRICT) | — | 5 |
| `notificaciones_mora` | cliente_id→clientes; cobrador_id→cobradores (SET NULL); cuota_id→cuotas (CASCADE); resuelta_por→cobradores (SET NULL); vista_por→cobradores (SET NULL) | — | — | 5 |
| `op_log` | — | — | — | 4 |
| `pagos` | anulado_por→cobradores (SET NULL); cobrador_id→cobradores; cuota_id→cuotas | recibos.pago_id (CASCADE) | trg_pagos_delete_recalcular→recalcular_cuota_desde_pagos(DELETE); trg_pagos_guard_cobrador→pagos_guard_cobrador_trg(UPDATE); trg_pagos_insert_recalcular→recalcular_cuota_desde_pagos(INSERT); trg_pagos_revertir_descuentos→pagos_revertir_descuentos_trg(UPDATE); trg_pagos_update_recalcular→recalcular_cuota_desde_pagos(UPDATE); validar_tenant_coherente_pagos→validar_tenant_coherente(INSERT UPDATE) | 5 |
| `planes` | — | contratos.plan_id | — | 3 |
| `recibos` | anulado_por→cobradores (SET NULL); cobrador_id→cobradores; pago_id→pagos (CASCADE) | saldos_favor.recibo_id (SET NULL) | trg_recibos_check_cobrador_update→recibos_check_cobrador_update(UPDATE); validar_tenant_coherente_recibos→validar_tenant_coherente(INSERT UPDATE) | 5 |
| `red_hubs` | nodo_id→red_nodos (RESTRICT) | incidentes.hub_id (SET NULL); red_puertos.hub_id (RESTRICT) | — | 5 |
| `red_nodos` | — | incidentes.nodo_id (SET NULL); red_hubs.nodo_id (RESTRICT) | — | 5 |
| `red_puertos` | hub_id→red_hubs (RESTRICT) | clientes.puerto_id (SET NULL); incidentes.puerto_id (SET NULL); tickets.puerto_id (SET NULL) | trg_red_puertos_guard_borrado→red_puertos_guard_borrado(DELETE) | 5 |
| `reinvite_locks` | — | — | — | 0 |
| `saldos_favor` | cargo_id→cargos_extra (SET NULL); cliente_id→clientes (CASCADE); cobrador_id→cobradores; contrato_id→contratos (CASCADE); creado_por→cobradores; cuota_id→cuotas (SET NULL); recibo_id→recibos (SET NULL) | — | trg_saldos_favor_no_sobregiro→saldos_favor_no_sobregiro_trg(INSERT) | 3 |
| `solicitudes_accion` | solicitante_id→cobradores; aprobador_id→cobradores; tenant_id→tenants (CASCADE) | — | — | 4 (solicitudes_read, solicitudes_insert, solicitudes_update, super_admin_all) |
| `settings` | — | — | — | 4 |
| `super_admin_impersonation` | — | — | — | 1 |
| `tenant_modulos` | habilitado_por→cobradores (SET NULL); modulo_codigo→modulos (RESTRICT) | — | — | 2 |
| `tenants` | — | — | trg_tenants_habilitar_modulos_base→tenants_habilitar_modulos_base_trg(INSERT); trg_tenants_seed_settings→tenants_seed_settings_trg(INSERT) | 1 |
| `ticket_adjuntos` | subido_por→cobradores (SET NULL); ticket_id→tickets (CASCADE) | — | — | 3 |
| `ticket_eventos` | hecho_por→cobradores (SET NULL); ticket_id→tickets (CASCADE) | — | — | 3 |
| `ticket_materiales` | hecho_por→cobradores (SET NULL); producto_id→inv_productos (RESTRICT); serial_id→inv_seriales (SET NULL); ticket_id→tickets (CASCADE); ubicacion_origen_id→inv_ubicaciones (SET NULL) | — | trg_ticket_materiales_consumo→ticket_materiales_consumo(INSERT) | 3 |
| `ticket_tipos` | — | tickets.tipo_id (RESTRICT) | — | 3 |
| `tickets` | asignado_a→cobradores (SET NULL); cliente_id→clientes (SET NULL); contrato_id→contratos (SET NULL); creado_por→cobradores (SET NULL); incidente_id→incidentes (SET NULL); puerto_id→red_puertos (SET NULL); tipo_id→ticket_tipos (RESTRICT) | cuotas.ticket_id (SET NULL); inv_movimientos.ticket_id (SET NULL); ticket_adjuntos.ticket_id (CASCADE); ticket_eventos.ticket_id (CASCADE); ticket_materiales.ticket_id (CASCADE) | trg_tickets_correlativo→tickets_correlativo_trg(INSERT); trg_tickets_eventos_auto→tickets_eventos_auto_trg(INSERT UPDATE); trg_tickets_validar_transicion→tickets_validar_transicion(UPDATE) | 3 |
| `visitas` | cliente_id→clientes (CASCADE); cobrador_id→cobradores | — | validar_tenant_coherente_visitas→validar_tenant_coherente(INSERT UPDATE) | 4 |
| `whatsapp_credenciales` | — | — | — | 0 |
| `whatsapp_envios` | — | — | — | 1 |

**Cómo regenerar este mapa** (correr desde el worktree principal, linkeado):
```sql
-- FKs:      SELECT tc.table_name, kcu.column_name, ccu.table_name AS apunta_a, rc.delete_rule
--           FROM information_schema.table_constraints tc
--           JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name
--           JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
--           JOIN information_schema.referential_constraints rc ON rc.constraint_name = tc.constraint_name
--           WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema='public';
-- Triggers: SELECT c.relname, t.tgname, p.proname FROM pg_trigger t
--           JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_proc p ON p.oid=t.tgfoid
--           JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal;
-- RLS:      SELECT tablename, count(policyname) FROM pg_tables t
--           LEFT JOIN pg_policies p USING (tablename) WHERE t.schemaname='public' GROUP BY 1;
```
(vía `supabase db query --linked "..."`). Regenerar al agregar tabla/FK/trigger
(Recetas R4/R10) — si este mapa y prod divergen, MANDA PROD.

### §3.6.2. Fichas de FUNDACIÓN (auditoría por tabla — F0, 2026-07-09)

Auditoría exhaustiva por tabla del núcleo multi-tenant (v0.22.8). Cada ficha da el
"por qué" del wiring + los fixes F0 aplicados; complementa el grafo de §3.6.1.

**`tenants` (raíz del multi-tenant)**
- *Vínculos:* `tenants.id` ← todo por `tenant_id`. **No se sincroniza al cliente**
  (no está en schema.dart/sync-rules); el vínculo cliente↔tenant es indirecto vía
  cobradores/settings. `current_tenant_id()` (0039) = impersonación → si no,
  cobradores.tenant_id.
- *Escribe:* SOLO edge `crear-tenant` (INSERT con JWT super; rollback = DELETE). El
  cliente JAMÁS la toca. RLS = única policy `super_admin_all` (deny-all para el resto).
- *Lee:* RPC `list_tenants_admin` (super) + edges service-role. El nombre visible al
  cliente sale de `settings` empresa.nombre (no de esta tabla).
- *F0:* **`tenants.activo`** (0181) + `set_tenant_activo` + gate de login → suspender
  un ISP corta el acceso de todos sus usuarios · **UNIQUE `lower(trim(nombre))`** (0180).

**`cobradores` (usuarios: cobrador/admin/admin_cobranza/admin_usuarios/tecnico/admin_tickets)**
- *Vínculos:* `cobradores.id == auth.users.id` (1:1, lo crea `handle_new_user` 0176).
  `cobrador_id` denormalizado en clientes→contratos→cuotas es ORGANIZATIVO (P3b; NULL
  = admin-managed). QUIÉN cobró lo captura `pagos/recibos.cobrador_id`, NUNCA éste.
- *Escribe:* edges invitar/reenviar/crear-tenant (alta) + RPCs set_cobrador_activo/rol
  + UPDATE local (nombre/tel/prefijo). `rol` congelado (trigger 0066) → solo por RPC.
- *Invariante:* `prefijo_recibo` único por (tenant, prefijo) — sostiene el correlativo
  fiscal (INV7).
- *F0:* **`activo` ahora ENFORZADO** — corta login (gate `verificar_acceso`) + sync
  (`AND activo=true` en 6 buckets) · reenviar-invitacion conserva prefijo de admin/
  admin_cobranza · unicidad de prefijo validada en cliente · op_log de alta (cliente)
  y baja (edge eliminar-cobrador).

**`settings` (key-value por tenant; gatea features)**
- *Vínculos:* `tenant_id` (CASCADE). Sembrada por `trg_tenants_seed_settings` (cuerpo
  vigente 0177) + backfills por migración para tenants viejos.
- *Escribe:* `settings_repo` (update/upsert). RLS: `settings_write_admin` (admin, SOLO
  si `editable_por <> 'super_admin'`) · `settings_update_admin_cobranza` · `super_admin_all`.
  **`editable_por` SÍ se enforza en la RLS** (no es un mero hint de UI — ése era el
  supuesto peligroso del audit).
- *Lee:* todos los miembros (por tenant) · `appSettingsProvider`. `editable_por` decide
  la tab de la UI.
- *F0:* `op_log.campos_visibles` (super-only) ahora nace `editable_por='super_admin'`
  (0182 + `upsert(editablePor:)`) → el admin no la pisa · `updated_at` en UTC · visor
  de historial (Avanzado → "Ver historial de cambios").

**`op_log` (ÚNICO change log; append-only; client-written)**
- *Vínculos:* `tenant_id`; filas de una intención comparten `op_id`; `entidad_id` = PK
  del objeto (SIN FK — genérico). `audit_log` ELIMINADO (0140) → op_log es el único.
- *Escribe:* el CLIENTE dentro de su writeTransaction (1 fila por objeto). Excepción F0:
  la BAJA de cobrador la emite el edge (service role — la baja es server-side). RLS:
  read = `is_admin_or_cobranza` + **`op_log_read_admin_tickets` scopeado** (0182) ·
  insert/update por tenant+actor · super_admin_all.
- *Lee:* `HistorialOpLog(entidad, entidadId)` — con `entidadId=null` da el log GLOBAL de
  una entidad (F0, usado por el visor de settings).
- *F0:* **trigger append-only** (0179) → no se pueden PISAR filas (el re-upsert idéntico
  pasa) · admin_tickets ve historial de tickets/incidentes (RLS + bucket scopeados, sin
  leak de dinero) · op_log de alta/baja cobrador + adjuntar/quitar documento de contrato.
- *Backlog ACEPTADO (no-fix):* `super_admin_all` ausente en 5 tablas append-only/
  service-role (`inv_movimientos`, `whatsapp_*`, `data_ops_*`) — ponerle `FOR ALL` a un
  ledger contradice el append-only; sus escrituras van por RPC definer/service-role, así
  que el super nunca choca. Documentado como desviación intencional.

### §3.6.3. Fichas de CLIENTES y su órbita (auditoría por tabla — F1, 2026-07-09)

Auditoría por tabla de clientes/etiquetas/fotos_cliente/visitas (v0.22.9). Sin
críticos; búsqueda ñ/acentos y vencimiento_mas_viejo verificados SANOS en prod.

**`clientes` (entidad central)**
- *Vínculos:* hija de tenants; ref opcional a cobradores (cobrador_id ORGANIZATIVO,
  NULL=admin-managed), comunidades, red_puertos. PADRE (CASCADE) de contratos/cuotas/
  pagos/recibos/fotos_cliente/visitas/cliente_etiquetas/tickets — todos denormalizan
  cobrador_id para el bucket por_cobrador. Denorm propia: `vencimiento_mas_viejo` (color
  del mapa). NO hay borrado físico desde la app (lifecycle = alta/edición + `activo=0`).
- *Escribe:* cliente_form_screen (alta/edición, con op_log) · clientes_admin_screen
  _bulkAssign (reasignación masiva). Server: propagate_cobrador_id (0122),
  recalc_vencimiento_mas_viejo (0150), codigo inmutable (0071).
- *BÚSQUEDA (lo crítico de esta tabla):* TODA búsqueda/filtro/unicidad contra nombre/
  codigo/cedula usa foldBusqueda/foldSqlExpr + tokens (busquedaClienteSql/coincideTokens)
  — regla #1d. Verificado: 0 consumidores con lower()/`.contains()` pelado. Prod: 160
  códigos + 1076 nombres con ñ/acentos (prefijo "CÑ"), todos encontrables.
- *F1:* (a) **deuda fantasma** — desactivar un cliente es ORGANIZATIVO (ocultar), NO frena
  la generación de cuotas (gatea por contrato.estado, no cliente.activo). Fix semántica C:
  se BLOQUEA desactivar con contratos activos (suspendé/cancelá el contrato primero) +
  texto del switch corregido. (b) el form ya no re-mayusculiza el código bloqueado → un
  cliente con código en minúsculas vuelve a ser editable (antes el trigger 0071 lo trababa).

**`etiquetas` (catálogo 0122) + `cliente_etiquetas` (M2M)**
- *Vínculos:* etiquetas per-tenant; cliente_etiquetas FK a clientes+etiquetas (CASCADE).
  Consumidores usan INNER JOIN etiquetas → orphans locales (pre-cascade) no leakean.
- *Escribe:* etiquetas_repo. op_log de asignar/quitar scoped al CLIENTE (resumen "Etiqueta
  asignada/quitada"). RLS: read=miembro, write=is_admin_or_cobranza + super_admin_all (ambas).
- *F1:* (a) borrar una etiqueta ahora emite "Etiqueta quitada" por cada cliente afectado
  (antes el CASCADE los desasignaba sin rastro). (b) UNIQUE server folded (0183, igual a
  foldSqlExpr) → no más "Moroso"/"moroso"/"Morosó" por multi-device.
- *Backlog:* cliente_etiquetas.cobrador_id + su trigger son VESTIGIALES (el bucket
  por_cobrador baja tenant-wide, no filtra por cobrador). Sin impacto.

**`fotos_cliente`**
- *Escribe/lee:* foto_gallery_widget (subir/borrar, op_log alta Y baja scoped al cliente).
  Storage con path scopeado por tenant (RLS storage_super_admin da bypass al super). RLS
  tabla: is_admin_or_cobranza + super_admin_all. El técnico NO renderiza galería → que
  falte en su bucket es correcto, no gap.
- *F1:* borrar foto offline ya no muestra error falso — el éxito se confirma al commitear
  la DB; storage.remove es best-effort silencioso (huérfano inofensivo).

**`visitas`**
- *Escribe:* visitas_service (alta, op_log bajo `entidad='clientes'` — la visita aparece en
  el historial del CLIENTE). Append-only de facto (sin edición desde la app). RLS:
  insert=miembro, delete=admin, super_admin_all.
- *ATRIBUCIÓN:* registrar visita está atribuida al usuario → BLOQUEADA al impersonar (0125):
  doble guard (UI oculta el botón + visitas_service lanza StateError). Verificado.
- *TIMEZONE:* fecha/ocurrido_en en UTC device-time, display `.toLocal()`, sin bucketing por
  día → regla #1b OK. Técnico/admin_tickets NO sincronizan visitas (sin leak).
- *F1:* `visitas_read` alineada a tenant-wide (0183) — antes limitaba al cobrador a SUS
  visitas pero el bucket ya bajaba todas (dead-code). Entrada op_log 'visitas' muerta
  removida (logueaba bajo 'clientes'; listaba una columna 'estado' inexistente).

---

## §3.7. Algoritmos de optimización de performance (lote v0.16.0 + v0.17.0)

Nacieron del tenant Mairena (~4.600 clientes) que hacía lento Clientes y Mapa.
Principio transversal: **precalcular en el server + espejar offline**, y
**agregar/paginar en SQL** en vez de cruzar en Dart.

1. **Mapa "Opción 2" (color del pin sin cruzar cuotas).** Antes el color cruzaba
   `clientes × cuotas` (~16-19s para "Ver todo" con 4.442 pines). Ahora el estado
   sale de `clientes.vencimiento_mas_viejo` (la FECHA de la cuota pendiente más
   vieja, precalc por `trg_cuotas_vmv`/`trg_contratos_vmv` + espejo
   `recalcVmvDeContrato`). Un `CASE` sobre esa fecha deriva los 5 estados/colores
   → **"Ver todo" ~3s**. Default = solo **cobrables** (`vmv ≤ hoy+ventana`, ~154
   pines); "Ver todo" (admin) quita el filtro. Empty state ofrece **"Ver todos
   los clientes"** si no hay cobrables (tenant sin contratos no queda sin mapa).
   `mapa_screen.dart`.
2. **Lista de Clientes paginada.** Agrega SOLO la página visible (~60) con una
   subconsulta `WHERE c.id IN (SELECT id … ORDER BY … LIMIT lim+1)` + scroll
   infinito; el contador del header = `COUNT(*)` aparte (`Fmt.entero`, el total
   REAL del filtro, no "60+"). Antes agregaba los 4.606 → segundos de "Sin
   clientes". `clientes_admin_screen.dart`.
3. **Cobros en 1 fila por contrato.** `cobros_query.dart` arma el resumen
   agregado en SQL (CTE `lineas`, cuota más vieja por contrato); reusa el CTE
   para blindar la consistencia #10 con test. Escala a miles.
4. **Clustering del mapa.** `flutter_map_marker_cluster` agrupa los ~4.000 pines
   en burbujas y renderiza solo lo visible (`markerChildBehavior`).
5. **Índices que sostienen lo anterior** (`schema.dart`): `by_contrato_vencimiento`
   (cuota más vieja por contrato — mapa + detalle, sin full scan),
   `by_vencimiento`, `by_cobrador_estado`, `by_cuota` (pagos), `by_correlativo`.
6. **Cold-start sin "ClosedException".** Los streams se recrean con
   `dbEpochProvider` y `conexionRealProvider` arranca optimista; el sync gate
   tiene grace de 8s (`sync_ready_provider`) para no colgar el primer arranque.

**Verificado date-independent:** el estado precalc == el vivo, 0 mismatches /
4.442; sin cron (la fecha en `vmv` no caduca, el `CASE` la compara contra "hoy").

---

## §3.8. Sync SELF-HOSTED — PowerSync en VPS propio (desde 2026-07-13)

**Por qué:** el PowerSync **cloud** (de paga) superó el free tier de "Data Synced"
(~$66/mes de overage, inflado por dev-churn + el bucket `por_cobrador` que baja todo
el tenant a cada device). Se migró a un **PowerSync self-hosted** en un VPS propio
(~$6/mes). **Supabase NO cambia** — sigue siendo la fuente de verdad (Postgres+Auth+
Storage+Edge); lo único que se reemplazó es el servicio de sync.

**Topología (quién habla con quién):**
```
                 login/JWT · subida de cobros · fotos · Edge Functions
   ┌────────────┐ ─────────────────────────────────────────────► ┌──────────┐
   │ Dispositivo│                                                  │ Supabase │  (fuente
   │  (app)     │ ◄──── bajada (sync stream) ──── ┌───────────┐    │ Postgres │   de verdad)
   │ SQLite     │                                  │  TU VPS   │◄───┤ +Auth    │
   │ offline    │                                  │ PowerSync │ replicación
   └────────────┘                                  └───────────┘  (directa IPv6)
```
- **El VPS SOLO hace la BAJADA** (el sync stream de descarga). Auth, **subida** de
  writes (CRUD queue → `uploadData` en `connector.dart`), Storage y Edge Functions van
  **directo a Supabase** — NO pasan por el VPS. Por eso si el VPS cae: los cobradores
  siguen operando offline y sus cobros igual suben a Supabase; solo se pausa la
  propagación entre devices hasta que vuelva.

**Infra del VPS:** Hetzner Helsinki, CX23 (2 vCPU/4GB), IP `65.109.1.217`, URL
`https://65-109-1-217.sslip.io` (sslip.io + Caddy/Let's Encrypt). SSH:
`ssh -i ~/.ssh/hetzner_powersync root@65.109.1.217`. Stack Docker en `/opt/powersync/`:
`journeyapps/powersync-service:1.23.3` (unified) + Postgres 18 (bucket-storage) + Caddy.
Docker con **IPv6 habilitado** (`daemon.json`) — necesario porque la conexión directa
de Supabase es IPv6-only.

**Conexión a Supabase (replicación):** directa IPv6 a `db.<ref>.supabase.co:5432`, rol
dedicado **`powersync_selfhost`** con **`BYPASSRLS`** (CRÍTICO: el snapshot inicial hace
`SELECT`, sujeto a RLS; sin bypass el rol ve 0 filas por las policies de tenant y no
baja nada). `sslmode: verify-full` con la CA de Supabase inlineada. Reusa la publicación
`powersync` que ya existía. Auth de clientes: **JWKS** (`client_auth.jwks_uri` al
endpoint público de Supabase; claves asimétricas ES256; `audience: [authenticated]`).

**Deploy de sync rules (cambió):** editar `/opt/powersync/config/sync-config.yaml` en el
VPS (fuente DRY: `powersync/sync-rules.yaml`) + `docker compose restart powersync`. YA NO
se pega en el "Dashboard de PowerSync" (el cloud se retiró). Un cambio de reglas puede
disparar re-sync, igual que antes.

**Panel de estado:** `https://65-109-1-217.sslip.io/panel-<slug>/` (path secreto; salud/
RAM/disco/buckets, auto-refresh 60s; generado por `status-gen.sh` vía cron).

**Rollback:** el cloud queda de respaldo unos días (slot activo); rollback = re-release
con `.env.json.cloudbak`. Al confirmar estabilidad → decomisionar el cloud (borrar el
proyecto) y el overage desaparece del todo.

> **Runbook completo + gotchas** (Docker IPv6, ban de fuerza-bruta de Supabase por
> auth fallidos → unban en Dashboard→Database→Network bans, primer checkpoint que
> necesita que el WAL avance, msix `--build-windows false`): memoria del proyecto
> **`powersync-selfhost-hetzner`**.

---

## §4. Flujos críticos end-to-end (cómo viaja la data)

### (a) Cobro de campo: offline → sync → trigger → reportes
1. `/cobro/:ids` → `PagosRepo.registrarCobro` escribe TODO local en una
   transacción (pagos+recibos+cargos+mirror de cuota) → UI instantánea.
2. → `/recibo/:id` → térmica, offline (Bluetooth en Android, cola RAW del sistema
   en Windows — §3 Recibo + Impresora).
3. Con red: `connector.uploadData` sube la cola → triggers server
   (`recalcular_cuota_desde_pagos`, `cargos_extra_actualizar_neto`)
   recalculan la VERDAD → baja corregida por sync.
4. Dashboard/reportes del admin leen `pagos`/`cuotas` ya consolidados.

### (b) Generación de cuotas: crear contrato → trigger server genera las
cuotas del período → bajan al cobrador asignado (bucket `por_cobrador`) y al
admin. Cron diario (06:05 UTC = medianoche Nicaragua) genera
`notificaciones_mora` SOLO de cuotas de contratos `estado='activo'` (0124:
suspendidos y cancelados no generan mora — fix del badge fantasma).

### (c) Anular pago: `PagosRepo.anularPago` marca `anulado=1` (pago+recibo) +
mirror local de la resta → trigger server restaura la cuota autoritativo.
El pago anulado SE PRESERVA. Las sync rules del cobrador filtran anulados.

### (d) Change log (op_log, vigente): el repo escribe el `op_log` (1 fila por
objeto afectado, mismo `op_id`) DENTRO de la misma `writeTransaction` que muta el
dato → el `HistorialOpLog` lo ve YA, offline, sin esperar al server. Al sincronizar
sube por la CRUD queue (el cobrador NO descarga `op_log` pero SÍ la escribe y
encola). `op_log` es el ÚNICO change-log (el trigger forense a `audit_log` se
eliminó en 0140). `ocurrido_en` = device-time UTC (orden cronológico real);
`created_at` server desempata.

### (e) Onboarding de tenant: `/super/tenants` → Edge `crear-tenant`
(tenant + módulos + admin con password server-side, rollback completo) →
el admin entra por `/login` → landing `/admin`.

### (f) Ticket con materiales: admin crea (correlativo T-00001) → técnico
resuelve offline → consume serial de su custodia → sync → trigger 0106
descuenta inventario e instala en el cliente → admin cierra.

---

## §5. Catálogo de settings (fuente de verdad: `settings_repo.dart`)

> Editar un setting NO requiere migración salvo que necesite seed/default
> server-side. La tabla `settings` sincroniza por `SELECT *` → una clave
> nueva llega sola. Súper-only se enforcea server-side (`editable_por`).

| Clave | Default | Controla | Consumido por |
|---|---|---|---|
| `empresa.nombre/direccion/telefono/ruc/whatsapp/logo_path` | "" | branding | recibo, reportes, AppBar |
| `cobranza.dias_gracia` | 10 | vencido→mora | estados de cuota, mora, dashboard |
| `cobranza.dias_cuotas_visibles` | 5 | rango de futuras del cobrador | listas, mapa, cobro |
| `cobranza.colores_estados` | 🔴🟠🔵🟣 | colores mora/gracia/hoy/próxima | mapa, listas, badges (R1) |
| `cobranza.pago_parcial` / `pago_adelantado` | true | reglas de cobro (súper-only) | cobro |
| `cobranza.cobrador_anula_cobros` / `cobrador_edita_cobros` | false | permisos campo (súper-only) | historial, pagos |
| `cobranza.cobrador_edita_fecha` | false | fecha editable en cobro | cobro |
| `cobranza.ajustes_habilitados` + `ajuste_max_porcentaje/_monto` | false / 50 / 0 | descuentos del admin: ajustes y promos (súper-only; grupo "Ajustes de cuota (admin)"; guard 0115/0117) | DescuentoDialog |
| `cobranza.cargo_reconexion_habilitado` + `monto_reconexion` | false | cargo auto reconexión (súper-only) | cobro |
| `cobranza.comprobante_habilitado` + `foto_obligatoria` | false | foto del comprobante (súper-only) | cobro |
| `cobranza.pantalla_pagos` | false | habilita `/admin/pagos` (súper-only; el súper TAMBIÉN la respeta) | menú+router |
| `cobranza.registrar_visitas` | false | habilita la pestaña Visitas del detalle de cliente (súper-only; 0125) | detalle de cliente |
| `pagos.metodo_transferencia/metodo_tarjeta` | false | métodos extra | cobro |
| `pagos.usd_habilitado` + `tasa_usd_cordoba` | true / 36.50 | USD y tasa | cobro, arqueo |
| `recibo.layout` | catálogo | bloques/zonas/tamaños del recibo | recibo (pantalla/PDF/térmica) (R3) |
| `recibo.titulo/pie_libre/formato_default_mm/mostrar_adeudado/mostrar_cedula` | varios | textos/formato del recibo | recibo |
| `recibo.mostrar_descuentos` + `mostrar_motivo_descuentos` | true | desglose de descuentos/cargos en el bloque `cuota` (sub-toggles del diseñador) | recibo (pantalla/PDF/térmica) |
| `cuotas.descuento_pronto_pago(+_tipo)` | 0 | descuento automático por pago antes del vencimiento (grupo "Pronto pago" en Avanzado) | cobro |
| `tickets.sla_horas_por_prioridad` | {urgente:1,alta:2,media:6,baja:12} | SLA por prioridad | tickets (SLA efectivo = min con el del tipo) |
| `tickets.auto_cierre_dias` | 0 (off) | auto-cierre de resueltos | cron 0109 |
| `op_log.campos_visibles` | {} | override por ENTIDAD de los campos visibles del historial op_log (panel super-only `OpLogCamposScreen`, Config→Avanzado) | `HistorialOpLog` (`appSettings.opLogCamposOverride`) |

Ocultos/aspiracionales (NO implementados): `cobranza.modo_ruta`,
`caja_chica`, `pantalla_notificaciones` (parqueados por decisión).
Retirados (seed preservado, en `_hidden`): `cuotas.editar_monto` (Sprint 2)
· `cuotas.manuales` (2026-06-11, junto con `/admin/cuotas`) ·
`cobranza.descuentos_habilitados/descuento_tipo/descuento_max_*`
(2026-06-12: el cobrador no descuenta — todo va por ajustes del admin) ·
`cobranza.audit_visible_admin` · `audit.campos_visibles` (0140, 2026-06-21:
el sistema audit_log fue eliminado — ver "Audit / Change log").

---

## §R. RECETAS de cambios comunes (paso a paso, sin escanear)

### R1 — Cambiar colores de estados de cuota
**Archivos:** `lib/data/utils/cuota_estado_visual.dart` (enum + 
`ColoresEstados.defaults`/`fromJson` + `estadoVisualCuota()`) · getter en
`settings_repo.dart` (`coloresEstados`) · picker en
`features/admin/settings/` (sección "Colores de estados de cuota").
**Afecta:** mapa, lista de cobros, cuotas admin, detalle de contrato, lista
de clientes — TODOS leen el mismo helper; cambiar el helper cambia todo.
**Cuidado:** el parseo es defensivo (color inválido → default); los 6 estados
visuales incluyen `fueraDeRango` (gris "no disponible") y `sinDeuda` — no
agregar estados sin actualizar el switch exhaustivo de Dart en los consumers.

### R2 — Modificar el dashboard del admin
**Archivos:** `features/admin/dashboard/dashboard_admin_screen.dart` (UI) ·
`data/providers/dashboard_providers.dart` (KPIs).
**Cuidado:** cortes de día/mes SIEMPRE con boundary Nicaragua (patrón
`DateTime.now().toUtc().subtract(Duration(hours: 6))` o
`date('now','-6 hours')` en SQL); los KPIs deben seguir dando idéntico a
reportes (invariante #10); providers nuevos → `ref.watch(dbEpochProvider)`.

### R3 — Layout/bloques del recibo
**Archivos:** `data/models/recibo_layout.dart` (catálogo + zonas) · editor
`features/admin/settings/recibo_layout_editor.dart` + `recibo_preview.dart` ·
**4 renderers** que iteran el MISMO layout: `features/recibo/recibo_screen.dart`
(pantalla) · `recibo_ticket.dart` (térmica modo imagen — se CAPTURA a PNG) ·
`recibo_texto_escpos.dart` (térmica modo texto nativo) · `recibo_pdf.dart` (PDF).
**Cuidado:** bloque `totales` no es ocultable; bloques nuevos se agregan al
final automáticamente (fromRaw completa faltantes); bloques desconocidos se
descartan (backward-compatible). Térmica: `GS v 0` manual, **no tocar el método
de raster ni el transporte** (lección v0.22.10-13). Ojo con el 4º renderer:
**`recibo_texto_escpos.dart` NO es una captura del widget**, así que un bloque
nuevo hay que emitirlo también ahí o el modo texto no lo imprime.
**Un problema de UNA impresora NO se arregla acá** — va como ajuste por-PC en
§3 Recibo + Impresora.
**Recibo de pago ANULADO (B6, 2026-06-30):** si el pago está anulado
(`pagos.anulado=1`), `recibo_screen.dart` estampa el sello **"ANULADO"** y OCULTA
reimprimir. En un cobro multi-cuota con anulación parcial, `contrato_detail_pagos.dart`
**fuerza el path SINGLE** para el pago anulado (grupo=null); si no, se reimprimía el
ticket VÁLIDO de los pagos hermanos vivos del grupo.

### R4 — Agregar una columna a una tabla existente (CADENA DE INTEGRIDAD)
**Pasos EN ORDEN (saltarse uno = horas de debugging):**
1. Migración SQL `supabase/migrations/NNNN_*.sql` (`ALTER TABLE ... ADD COLUMN`)
   → correrla en Dashboard → verificar en Table Editor.
2. `lib/powersync/schema.dart`: declarar la `Column.text/real/integer`.
3. **NO se bumpea `_dbWipeVersion`** — un ADD COLUMN es ADITIVO: PowerSync
   reconstruye la view in-place al reabrir, SIN re-descargar (verificado en
   `test/powersync/schema_inplace_test.dart`). Los datos locales se conservan.
4. **Redeployar sync rules** en PowerSync Dashboard → "Active" (con `SELECT *` la
   columna entra sola, pero el redeploy hace que el server la emita).
5. Dart: modelo (`fromRow`), INSERTs (¡incluir columnas denormalizadas — los
   triggers NO corren en SQLite!), queries.
6. App reiniciada desde cero (`q` + `flutter run`) — sin wipe ni re-sync.

> **Política de `_dbWipeVersion`** (la versión en el NOMBRE del archivo `.db`;
> fix #1 del 2026-06-19). NO se bumpea por cambios ADITIVOS (columna/tabla/índice
> nuevos) → PowerSync los aplica in-place. Bumpear SOLO cuando el cambio NO puede
> aplicarse in-place: **destructivo** (rename/drop/cambio de TIPO de una columna
> poblada) o **sospecha de cache local corrupto**. Un cambio de **sync rules** se
> re-materializa en el server (no necesita bump salvo que cambie la FORMA de una
> tabla). Bumpear = re-sync COMPLETO del slice de cada usuario (caro) → se
> reserva. Antes se bumpeaba en cada cambio de schema (~97% aditivo = re-sync
> gratis evitable).

### R5 — Agregar una pantalla al admin
1. Pantalla en `lib/features/admin/<modulo>/`.
2. Ruta en `config/router.dart` (dentro del ShellRoute admin; rutas
   específicas ANTES que las dinámicas `:id`).
3. Item en `_adminMenu` de `features/admin/shell/admin_shell.dart` (con
   `adminOnly`/`settingKey`/`moduloKey` según corresponda — R12).
4. Si es admin-only: agregarla a la lista `soloAdmin` del router (guard de
   `admin_cobranza`). Si depende de módulo/setting: gate en router también.
5. Si tiene form editable: PopScope + `formDirtyProvider`.

### R6 — Agregar un setting nuevo
1. Getter tipado en `AppSettings` (`settings_repo.dart`) con
   `settingValue<T>(_map, 'categoria.clave', default)`.
2. Entrada en `settings_groups.dart` (la pantalla la renderiza sola). Si es
   sensible → tab Avanzado (súper-only): meter el `SettingGroup` DENTRO de la
   `SettingCategoria` que corresponda en `kCategoriasAvanzado` (Reglas de cobro
   y dinero / Permisos del cobrador / Avisos / Visibilidad y reportes / Búsqueda
   e historial), no como grupo suelto. Catálogo y placement: §Settings.
3. **OBLIGATORIO — sembrar la FILA** (el panel SOLO dibuja claves que tienen
   fila en `settings`; sin fila la opción NO aparece, aunque el getter tenga
   default): **(a) Backfill** a tenants existentes (migración `INSERT ... WHERE
   NOT EXISTS` con `tipo`/`categoria`/`editable_por`; `super_admin` si es
   súper-only — el server lo enforcea). **(b) Seed de tenants NUEVOS**: sumar la
   clave al helper de seed (`seed_settings_faltantes_0132`) que llama
   `tenants_seed_settings_trg`. ⚠️ Si SOLO backfilleás, los tenants futuros
   nacen sin la fila → bug 0132 (Telenet sin "Días de cuota próxima" / "Cambiar
   fecha de pago").
4. Consumir con `ref.watch(appSettingsProvider).miGetter`. Sin migración de
   schema ni redeploy de sync (settings ya sincroniza `SELECT *`).

### R7 — Lógica de mora/gracia/vencimiento
**Archivos:** `cuota_estado_visual.dart` (`estadoVisualCuota()` — la
derivación visual) · `cuota_estado.dart` (`calcularEstadoCuota` — espejo del
trigger de dinero, NO confundir) · server: funciones de mora con
`SET timezone='America/Managua'` (patrón 0087).
**Cuidado:** la lógica tiene COPIA server-side (triggers/cron de mora) — si
cambiás el criterio en Dart, migración para el server también. TZ: siempre
`-6 hours`. NUNCA persistir estados derivados.

### R8 — Agregar un reporte
0. Registrar el tipo en `_tiposReporte` (`_TipoReporte`: `key`, label, `pdf`,
   `soloDetallado`, `filtraCobrador`). El diálogo unificado lo ofrece según el
   toggle/los formatos; NO hay tarjeta propia (reforma 2026-06-22).
1. Query: PDF → un `case` en `_generar`; Excel → un `case` en `_extraerDatos`
   (o rama propia si es especial, como cobranza/por_cobrador). Filtrar
   `anulado=0`, cortes con boundary Nicaragua. Si es DE COBRO, intercalar
   `${fc.sql}` (de `filtroCobradorSql(cobradores)`; `cb.id` si agrupa por
   cobrador) tras el `BETWEEN ? AND ?` y concatenar `...fc.params` AL FINAL.
2. PDF en `reportes/pdf/reporte_<nombre>_pdf.dart` (patrón de los existentes:
   aceptar `Uint8List? logoBytes`, crear `pw.MemoryImage` UNA vez y pasarlo a
   `buildHeaderEstandar(logo:)`; el caller le pasa `_logoParaReportes(ref)`).
3. Excel en `reportes/excel/reporte_excel.dart` (headers IDÉNTICOS al PDF) +
   registrar el tipo en `_tituloReporte`/`_periodoExcel`/`_hojaNombre`.
4. Descarga vía `descarga_archivo.dart`. Recaudado = `SUM(monto_cordobas)` no
   anulados — jamás sumar entregado/vuelto.

### R9 — Textos/branding del recibo
Settings `recibo.titulo/pie_libre` + `empresa.*` (sin código). Cambios de
formato → R3. ESC/POS: ojo con los caracteres fuera de code-page — en el modo
TEXTO los resuelve el ajuste **Tildes** por-dispositivo (`ascii`/`gbk`/`cp850`/
`latin1`, §3 Recibo + Impresora) y todo lo no representable cae a `?`; en el
modo IMAGEN los rasteriza Skia, así que no dependen de la impresora.

### R10 — Agregar una tabla/entidad/módulo nuevo (checklist COMPLETO)

> ⚠️ **ANTES DE AGREGAR UN TRIGGER `BEFORE UPDATE`, LEE ESTO.** Postgres los
> dispara en **orden ALFABÉTICO por nombre**, y hay barreras de permisos que
> dependen de ese orden para funcionar. Un trigger nuevo mal nombrado las
> desarma **en silencio** — sin error, sin test que lo cace.
>
> Las tres barreras que hoy dependen del orden:
> - `trg_tickets_coordinador_solo_orden` (0207) — el coordinador solo puede
>   ordenar trabajos, no reescribir el ticket. Convive con 6 triggers más en
>   `tickets`; los que corren DESPUÉS (`trg_tickets_correlativo`,
>   `trg_tickets_eventos_auto`, `trg_tickets_marcar_verificacion`,
>   `trg_tickets_validar_transicion`) podrían re-aplicar lo que ella revirtió.
> - `trg_clientes_a_solo_notas` y `trg_contratos_a_solo_notas` (0230) — los roles
>   sin escritura completa solo pueden mover `notas`. El prefijo `_a_` es
>   DELIBERADO: tienen que correr ANTES de `trg_*_codigo_inmutable` y de
>   `trg_contratos_check_cobrador_update`, que si no verían un cambio que la
>   barrera ya iba a revertir y cortarían con una excepción — y un P0001 hace que
>   el connector descarte el guardado ENTERO.
>
> **Regla:** si tu trigger nuevo toca `tickets`, `clientes` o `contratos`,
> nombralo para que corra DESPUÉS de esas barreras (nada que empiece con `trg_a`
> o antes alfabéticamente), y verificá el orden real con
> `select tgname from pg_trigger where tgrelid='public.TABLA'::regclass and not tgisinternal order by tgname`.

1. **Migración**: tabla con `id` UUID PK + `tenant_id` NOT NULL FK + (si se
   edita offline) `ocurrido_en`; índice por tenant.
2. **RLS**: `ENABLE ROW LEVEL SECURITY` + policies por
   `current_tenant_id()` (+ helper de rol) + **`super_admin_all` A MANO**
   (`FOR ALL USING/WITH CHECK is_super_admin()`; las tablas nuevas NO la heredan
   del do$$ de 0026 — sin esto el super_admin impersonando NO puede escribir,
   bug 2026-06-20 de op_log) + si la tabla la **escribe el cliente** vía
   PowerSync, policy **UPDATE** además de INSERT (el conector sube con `upsert`,
   gotcha 0129) + si es de módulo opcional: `tenant_tiene_modulo()` en las write
   policies (patrón 0114).
3. **Cadena local**: `schema.dart` (tabla nueva = ADITIVO, **sin bump de
   `_dbWipeVersion`**; baja sola por las sync rules) + sync-rules.yaml (¿qué
   buckets/roles la bajan?) + redeploy de sync rules. Política de
   `_dbWipeVersion`: ver R4.
4. **Dart**: modelo/repo/pantalla (R5) + **historial visible = emitir `op_log`**:
   registrar la entidad en `data/utils/op_log_campos.dart`
   (allowlists visibles/catálogo) + emitir `op_log` en cada mutación dentro de su
   `writeTransaction` (**R18**) + `HistorialOpLog(entidad, entidadId)` en su
   pantalla.
5. **Verificación**: queries de `information_schema`/`pg_trigger` post-deploy
   (nunca asumir que la migración corrió).

### R11 — Flow de cobro (DINERO — máxima precaución)
**Archivos:** `cobro_screen.dart` (UI) · `cobro_calculo.dart` (matemática
pura — los invariantes viven acá) · `pagos_repo.dart` (transacción+mirror).
**Antes de mergear:** correr `flutter test` (suite de `pagos_repo`, 14 tests)
y tras el deploy `supabase/tests/invariantes_dinero.sql` (0 violaciones).
**Cuidado:** vuelto SIEMPRE NIO · tasa snapshot al momento del cobro ·
multi-cuota: vuelto al último pago · NUNCA tocar `monto_pagado` a mano (lo
mantiene el trigger; el cliente solo espeja con `calcularEstadoCuota`) ·
cargos automáticos nuevos requieren actualizar también el trigger server.

### R12 — Galería de inicio / menú del admin
**Archivo:** `features/admin/shell/admin_shell.dart` → lista `_adminMenu`
(reescrito 2026-06-20: el rail/drawer pasó a una **galería de cards**
`MenuGaleriaScreen` en `/admin`; "Administración" abre la sub-galería
`AdminSubGaleriaScreen` en `/admin/administracion`; el dashboard es una card más
en `/admin/resumen`; el avatar de la AppBar despliega nombre/rol + Cambiar
contraseña + Cerrar sesión + versión). `_MenuItem(icon, label, path, {adminOnly,
superAdminOnly, settingKey, superRespetaSetting, moduloKey, children})`. Gates:
`adminOnly` excluye a `admin_cobranza`; `settingKey` muestra solo con el setting
ON (por default el súper lo ve igual, salvo `superRespetaSetting: true`);
`moduloKey` exige el módulo del tenant (el súper también lo respeta). Badges de
alerta (tickets en riesgo, stock bajo) sobre las cards.
**Cuidado:** la galería y el ROUTER deben quedar consistentes (mismo gate en
ambos — la card se oculta, el router rebota). Las rutas nuevas (`/admin`,
`/admin/resumen`, `/admin/administracion`) ya existen en `router.dart`.
**Grupo "Cobranza" (2026-06-30):** las 4 cards sueltas de cobranza (Centro/Cobros/
Avisos/Pagos) se consolidaron en UN botón **"Cobranza"** que abre su sub-galería
(igual que "Administración"). `AdminSubGaleriaScreen` pasó a `SubGaleriaScreen(grupoPath)`
genérica (**+ `esAdminCobranza`**, sin él los hijos `cobranza:true` no se veían para
ese rol); el `destino` del home = `m.path` (cada grupo abre SU sub-galería, ya no
hardcodeado a Administración); ruta+título `/admin/cobranza`. `_backTargetFor` mapea
el volver de cada sección a su galería padre (Centro/Cobros/Avisos/Pagos→`/admin/cobranza`;
Cobradores/Planes/Geografía/Red/Etiquetas→`/admin/administracion`; sub-parents→su
listado). **`go`, no `push` (regla #12).**
**Form-discard del back del shell (B1, 2026-06-30):** el back-arrow del `AdminShell`
descartaba los cambios de CUALQUIER form pusheado sin preguntar. Causa: el shell NO se
reconstruye al pushear una ruta hija → `matchedLocation` queda en el padre y
`_hasFormGuard(location)` nunca daba true; y `context.pop()` de go_router es declarativo
→ tampoco disparaba el `PopScope`. Fix: el back lee `formDirtyProvider` (que los forms ya
sincronizan) y muestra `confirmDiscardChanges` él mismo antes de `context.pop()` (mismo
patrón que `closeModalsAndGoGuarded` de las cards); el back de una ruta pusheada vuelve al
PADRE (pop), no al home.

### R13 — Cambio de fecha de pago (puente)
**Archivos:** `cobro/cambio_fecha_dialog.dart` (UI + elegibilidad) ·
`data/utils/prorrateo.dart` (`calcularPuenteCambioFecha`/`calcularFechaPago`) ·
`pagos_repo.dart` → `registrarCambioFecha` (transacción+mirror) · botón en
`cuotas_list_screen.dart` · `mapa_screen.dart` · `contrato_detail_screen.dart` ·
gate `cobradores.puede_cambiar_fecha` (se prende en Settings, multi-select) ·
migración `0119`. El recibo trae el puente (`origen='puente'`) filtrado por
`pago_id` → solo el de ESE recibo (varios cambios no se apilan).
**Qué hace:** mueve `contratos.dia_pago` y cobra el "puente" = días prorrateados
entre lo pagado y el día nuevo (cargo `origen='puente'` + pago + recibo en UNA
transacción).
**3 escenarios** (por cuotas vencidas; `venc < hoy` ESTRICTO, hora Nicaragua —
gracia cuenta, "vence hoy" no):
- **0 (al día):** host = última cuota PAGADA (es el ancla "pagado hasta"); cobra
  SOLO el puente. Sin cuota pagada → throw *"no hay nada para puentear"* (sin
  pagado-hasta no hay gap que cobrar).
- **1 (mora):** host = la vencida; cobra su saldo + el puente en 1 recibo.
- **2+:** BLOQUEADO (sería cobro multi-cuota + puente).
**Efectos sobre el contrato:** re-fecha las futuras al día nuevo (trigger
`contratos_actualizar_cuotas_futuras_trg` 0018: `UPDATE cuotas SET fecha_vencimiento`
WHERE `periodo >= mes_actual AND estado='pendiente'`) · absorbe (anula, motivo
`'Absorbida por cambio de fecha de pago'`) las que caen dentro del puente · en FIJOS
agrega 1 cuota de cierre por absorbida y corre `fecha_fin` · UPDATE `dia_pago`.
Indefinidos: absorben pero NO agregan cierre.
**Gates que frenan:** habilitado · contrato (no manual) · sin parcial en curso ·
día nuevo ≠ actual · puente > 0 · monto entregado ≥ cuota+puente. *Corolario (por qué
NO hay desfase de período en cobro): tras un cambio, toda cuota pendiente quedó
re-fechada al día nuevo (la única vencida permitida se cobró en la transacción), así
que la lista de cobro nunca mezcla venc viejo con día nuevo.*
**Nota recibo (fix #1, v0.12.3):** el rótulo del mes de servicio se ancla al
`fecha_vencimiento` HISTÓRICO de la cuota (`Fmt.mesServicioLabelDeVencimiento` /
`periodoReciboDeVencimiento` en `formatters.dart`), NO al `dia_pago` VIVO del
contrato → ESTABLE: reimprimir un recibo viejo ya no corre el mes al cambiar el día
de pago (las cuotas pagadas no se re-fechean). Caso borde cosmético (~0.5%): si el
día de cobro cae en domingo, `fecha_vencimiento` trae el +1 (domingo→lunes) y el mes
puede diferir en el límite. Las cuotas manuales (sin plan) usan el mes del `periodo`.
**Antes de mergear:** `flutter test` (grupos `registrarCambioFecha` +
`fetchCargosCuotas — scope del puente`) + invariantes de dinero. Es DINERO → R11.

### R14 — Suspensión temporal de contrato (Feature A)
**Archivos:** `data/repositories/contratos_repo.dart` (`suspenderContrato` /
`reactivarContrato` / `previewDeudaSuspension` — transacción offline) ·
`data/utils/prorrateo.dart` (`ventanaServicio`/`estadoServicio`/`montoPuente` —
ancla al día_pago, el MISMO prorrateo del puente; ver **§3.5**) ·
`features/contratos/suspension_dialogs.dart` (diálogos Suspender/Reactivar) ·
`contrato_detail_screen.dart` (botón Suspender en `_AccionesContrato` +
`_SuspensionCard`) · `contrato_detail_header.dart` (badge ámbar) ·
`reportes/pdf/reporte_deuda_suspension_pdf.dart` (PDF) · gate
`puedeSuspenderProvider` (admin/admin_cobranza) · tabla `contrato_suspensiones`
(migración `0120`, R10) · historial vía `HistorialOpLog(entidad:'contratos')`
(`contratos_repo` emite `op_log` per-objeto: contrato + cada cuota afectada —
`HistorialContratoWidget` quedó muerto en Fase 3c) ·
**ciclo de vida (2026-06-16):** `cuotas_list_screen.dart` + `mapa_screen.dart` (salen
de rutas) · `clientes_admin_screen.dart` (filtro "Suspendidos") · `dashboard_providers.dart`
+ `dashboard_admin_screen.dart` (KPI suspendido) · `reportes_admin_screen.dart` +
`reportes/pdf/reporte_clientes_pdf.dart` (clasificación en el reporte de clientes).
**Qué hace:** pausa un contrato (`estado='suspendido'`). El cron y
`generar_cuotas_contrato` (0074) gatean por `estado='activo'` → al suspender
dejan de generar SOLOS (pausa gratis).
**Suspender (anclado al día_pago — fix 2026-06-16, ver §3.5):** clasifica CADA
cuota `pendiente`/`parcial` por `estadoServicio(periodo, dia_pago, fechaSusp)`:
**`'cumplido'`** (servicio entregado completo → se cobra ENTERA, no se toca),
**`'en_curso'`** (`montoPuente(ventana.inicio, fechaSusp, precio)` = días
consumidos, con CLAMP al pago: `monto=max(prorrateo,abonado)`; si el abono cubre
→ `'pagada'` sin reembolso), **`'futuro'`** (servicio no empezó → anular,
motivo `'Suspensión temporal'`). Las `parcial` futuras igual sobreviven (tienen
pago) y entran al snapshot. **NUNCA** se ancla por mes calendario (ese era el
bug). `_calcularDeudaSuspension` espeja EXACTO la mutación (preview == snapshot
== saldo de la lista) e incluye `en_curso`/`dias_consumidos`/`dias_ciclo` para el
desglose del diálogo y el PDF. Inserta `contrato_suspensiones` (motivo + notas +
snapshot de deuda).
**Reactivar (reinicio limpio desde la fecha — decisión Rubén):** estado→`'activo'`,
re-ancla `dia_pago` al día de reactivación. La facturación es VENCIDA, así que la
cuota cuyo mes de vencimiento = mes de reactivación cubre el período suspendido previo
→ se revive desde **`mesR + 1`** (`mesRNext`), no desde `mesR`. Revive las cuotas
anuladas de periodo ≥ `mesRNext` hasta el `fecha_fin` ORIGINAL (sin estirar; reúsa
filas por `UNIQUE(contrato_id,periodo)`); el gap suspendido queda anulado.
**Reactivar en CUALQUIER día posterior a la suspensión (2026-06-18):** el guard
pasó de "mes posterior" a "**día estrictamente posterior** a `suspendido_en`" (el
MISMO día → Revertir). **Sub-caso 4** (se suspendió DESPUÉS del día de pago y se
reactiva el MISMO ciclo): la cuota de corte (en_curso prorrateada) tiene
`periodo == mesRNext` → colisiona con el primer ciclo reanudado (UNIQUE) y NO se
revive (no está anulada); para no SUB-COBRAR ese ciclo se **RE-COMPLETA** (su monto
suma el mes reanudado completo + se re-fecha al día nuevo; el recibo desglosa
prorrateo del corte + mes reanudado). Si se suspendió ANTES del día de pago, no hay
colisión (el corte queda en un periodo < `mesRNext`). Probar SIEMPRE con `dia_pago ≠ 1`.
**PDF de deuda:** se arma del `deuda_snapshot` (offline, reimprimible).
**Decisiones cerradas (Rubén):** no se cobra el período suspendido · termina en
el mismo mes · solo a futuro (lo pagado no se toca) · indefinidos solo pausan,
fijos anulan/regeneran · solo admin/admin_cobranza · oculto al impersonar.
**Vía `admin_usuarios` (cola de aprobación):** ese rol no ejecuta la acción, manda
una **solicitud** (`solicitudes_accion`, tabla en §3.6.1; helper
`shared/widgets/solicitud_accion_helper.dart`) con **Motivo (dropdown) + Notas,
AMBOS obligatorios** — se guardan en `solicitudes_accion.datos` (`motivo`/`notas`)
y la tarjeta de la cola (`admin/solicitudes/solicitudes_screen.dart`) los muestra
al que aprueba. Al APROBAR, `solicitudes_repo.ejecutarAccionAprobada` los pasa al
evento REAL (`_motivoNotasSolicitud` → `motivo`/`notas` de `suspenderContrato`;
en `cancelarContrato`, que no toma `notas`, se anexan al motivo), así el historial
dice POR QUÉ y no el genérico "Aprobada solicitud de…" — que queda de fallback
para las solicitudes viejas sin motivo. `reactivarContrato` no tiene campo motivo,
así que ahí el par solo vive en la solicitud.
**Deuda a la vista al pedir y al aprobar (0229, 2026-08-10):** el bloque
"Deuda a la fecha" vive en `shared/widgets/deuda_contrato_bloque.dart` y lo
comparten los CUATRO caminos (suspensión directa, cancelación directa, diálogo de
solicitud y tarjeta de aprobación) — antes era un método privado del State del
diálogo de suspensión, o sea que el que pedía permiso y el que aprobaba no veían
un solo número. `_solicitarCorte` (`contrato_detail_screen`) calcula la deuda y la
congela en `solicitudes_accion.deuda_snapshot` (**TEXT** con JSON, no jsonb —
mismo footgun de doble-encoding que forzó 0123→0126). La tarjeta **NO muestra el
snapshot**: recalcula EN VIVO con `_deudaVivaProvider`, colgado de
`contratoCuotasProvider` para re-emitir cuando entra un pago (era one-shot y se
congelaba con la pantalla abierta). El snapshot solo sirve para explicar la
diferencia, y **solo afirma lo que puede probar** (cambio de precio o de día de
pago): un descuento, un crédito aplicado (invariante #4: NO es un pago) o una
cuota anulada bajan el total sin que entre un peso. Las tres fechas del cálculo
salen de `SolicitudesRepo.fechaEjecucion()` — NO de `Fmt.hoyNicaragua()`, que
trunca a medianoche y movería el prorrateo. Al aprobar, `_disponerExcedente`
acredita el excedente pagado por adelantado (faltaba: los caminos directos sí lo
hacían y la cola no).
**Pendiente/reportería:** el "Pendiente" del header (`contrato_detail_header.dart`)
= deuda **cobrable** = Σ saldos canónicos de cuotas vivas (provider
`contratoRecaudadoProvider`, columna `cobrable`), igual que TODOS los reportes
(invariante #10) — NO el nominal `precio×meses`. "X/N pagadas" (`cliente_detail` +
`contratos_admin`) excluye anuladas; la distribución del dashboard usa eje
vigencia disjunto + overlay "Con pago parcial". **INV11** reintegra al conteo las
anuladas con `motivo='Suspensión temporal'` (activas + gap = `duracion_meses`) —
ese literal acentuado es load-bearing: cuando se corrompió en el RPC del panel
super_admin, INV11 marcó falso positivo en todo contrato fijo suspendido (fix
`0219`, ver §3 Operaciones de datos).
**Ciclo de vida / visibilidad (2026-06-16):** un suspendido SALE de la lista de cobros
(`cuotas_list_screen` filtra `COALESCE(ct.estado,'activo')='activo'`) y del mapa
(`mapa_screen`, join de cuotas restringido a contratos activos) — ya no está en rutas. Se
encuentra por el filtro **"Suspendidos"** de Clientes (`clientes_admin_screen`,
`c.id IN (SELECT cliente_id FROM contratos WHERE estado='suspendido')`; lista + export).
**Reactivar exige 0 pendiente:** `_SuspensionCard` gatea Reactivar a `cobrable < 0.01`; si
hay deuda muestra **"Cobrar pendiente"** → cobra la cuota MÁS VIEJA (`/cobro/:id`,
oldest-first, un recibo por cuota; reusa el cobro normal). El guard a nivel server quedó en
backlog (rompía los tests de reactivar; va con los demás guards de dinero server-side). Al
confirmar la suspensión, prompt para imprimir la deuda (helper `imprimirDeudaSuspension`,
compartido con "Reimprimir deuda").
**Clasificación en reportes:** la deuda suspendida sigue contando, pero aparte. El dashboard
saca los suspendidos del titular "por cobrar"/"vencido" (predicado `!= 'suspendido'`, así
titular + suspendido = total y no se esconde deuda) y agrega el KPI "Suspendido (por
reactivar)"; el reporte de clientes (PDF+Excel) suma `saldo_suspendido` por cliente →
subtotales Activo/Suspendido/Total + sufijo "(susp.)" por fila. Las 3 fórmulas (gate /
KPI / reporte) usan el saldo canónico (invariante #10).
**Revertir (deshacer por error):** `revertirSuspension` vuelve al estado EXACTO previo
(≠ Reactivar, que es reinicio limpio) — detalle en **R16**.
**Antes de mergear:** `flutter test` (grupos `suspenderContrato`/`reactivarContrato`)
+ invariantes de dinero. Es DINERO → R11.

### R15 — Reasignar cobrador (masivo / Rutas) y clientes sin cobrador (P3/P3b)
**Modelo:** ver §3.5 (4b) — `clientes.cobrador_id` es ORGANIZATIVO (lista/mapa/
ruta; filtro del bucket `por_cobrador`; puede ser NULL); quién cobró lo captura
`pagos.cobrador_id`. Reasignar = `UPDATE clientes SET cobrador_id` → el server
propaga a cuotas operativas vía trigger `0068` (REQUIERE online).
**Archivos:** `features/admin/rutas/rutas_screen.dart` (pantalla Rutas, ruta
`/admin/rutas`, menú admin no-adminOnly) · `features/admin/clientes/
clientes_admin_screen.dart` (`_seleccionarTodosDelFiltro` + `_filtroWhere`
compartido con el export) · `features/admin/clientes/seleccionar_cobrador_dialog.dart`
(diálogo compartido: buscador + `distribucionActual` + `permitirDesasignar`) ·
`features/cuotas/cuotas_list_screen.dart` (filtro "Sin cobrador",
`_kSinCobradorFiltro` → `cobrador_id IS NULL`).
**Reasignación masiva (P3):** Rutas reasigna una comunidad entera
(`WHERE comunidad_id AND activo=1`, resetea TODOS — los especiales se re-ajustan
después por cliente); la lista de clientes tiene "Seleccionar todos del filtro"
(no solo la página). El cobrador de ruta se DERIVA (único / "Mixto" / "Sin
asignar" en rojo / "(inactivo)").
**Sin cobrador (P3b, migración `0121`):** se dropearon los triggers `0058`
(bloqueaba desasignar con contratos activos) y `0025 E1` (bloqueaba crear contrato
sin cobrador), y los 3 guards cliente-side espejo (cliente form, contrato form,
botón "Nuevo" del detalle). Un cliente sin cobrador → cuotas `cobrador_id NULL` →
SOLO admin/admin_cobranza las ven/filtran/cobran (bucket de tenant; el cobro lo
registra el admin con su prefijo). `0121` NO cambia schema ni sync rules.
**Antes de mergear:** `flutter test` + invariantes (INV8 valida
`contrato.cobrador_id = cliente.cobrador_id`). No toca dinero (solo visibilidad).

### R16 — Cancelar un contrato (dinámica de suspensión PERMANENTE)
**Archivos:** `data/repositories/contratos_repo.dart` (`cancelarContrato` /
`previewDeudaCancelacion` — **espeja `suspenderContrato`**) · `data/utils/prorrateo.dart`
(mismo `estadoServicio`/`montoPuente` de R14) · `contrato_detail_screen.dart`
(`_cambiarEstado` + `imprimirDeudaCancelacion` + `_CancelacionCard`) ·
`contrato_detail_header.dart` (badge rojo "Cancelado") · `reportes/pdf/
reporte_deuda_suspension_pdf.dart` (PDF parametrizado: título "Documento de deuda" al
cancelar) · columnas `cancelado_en/cancelado_por/motivo_cancelacion/
cancelacion_deuda_snapshot` (migración `0123`, **bump schema v30→v31**) · cron de mora
`0124` (excluye contratos no-activos).
**Qué hace:** igual que suspender (cumplido=entera, en_curso=prorrateo por ventana de
servicio con CLAMP al pago, futuro=anular) pero **PERMANENTE**: `estado='cancelado'`,
**NO se reactiva**. Deja viva y cobrable la deuda real (meses cumplidos + mora previa);
**NO liquida a 0** (ese era el cancelar VIEJO `_cancelarYLiquidarCuotas`, eliminado).
Congela `cancelacion_deuda_snapshot` (para reimprimir el documento), resuelve las
`notificaciones_mora` del contrato (`resuelta_en`), exige motivo. La deuda se cobra desde
el **detalle del contrato** (`_CancelacionCard`): los cancelados SALEN de lista de
clientes / Cobros / mapa (cron 0124 + los joins de cuotas filtran `estado='activo'`).
**Backlog (decisión Rubén 2026-06-17):** reporte/filtro de "deuda de bajas" para no
perder de vista esa deuda (ver BITACORA §Backlog).
**Diferencia con R14:** misma maquinaria de dinero; cancelar no revive nada (sin
reactivar) y su deuda no vuelve a los flujos diarios.
**Revertir (deshacer por error) — 2026-06-18:** `revertirSuspension` /
`revertirCancelacion` restauran el estado EXACTO previo desde `cuotas_previas` (que
suspender/cancelar guardan en el snapshot JSON, **sin migración**): des-anulan las
cuotas, restauran monto/vencimiento, dejan el contrato `activo` (suspensión SIN
re-anclar dia_pago; cancelación limpia `cancelado_*` y re-abre la mora resuelta).
Distinto de **Reactivar** (reinicio limpio tras pausa real). **GUARDA:** solo si no se
cobró NI se aplicó cargo/descuento después (compara `monto_pagado` + `cargos_neto` vs el
snapshot; si cambió → aborta, va a Reactivar/cobro normal). Botones "Revertir" en
`_SuspensionCard`/`_CancelacionCard` (admin/admin_cobranza, no impersonando). Append-only
(el change-log audita; la fila de suspensión se cierra con `reactivado_en`). Caveat
aceptado: revertir una cuota que la suspensión clampeó a 'pagada' puede re-abrir su mora
vía el trigger server `trg_reabrir_notificacion_al_anular_pago` (correcto: vuelve a deber).
**Antes de mergear:** `flutter test` (grupos `suspenderContrato`/`pagos_repo`, misma
maquinaria) + invariantes de dinero. Es DINERO → R11.

### R17 — Crédito por excedente al suspender / cancelar (saldos a favor)
**Qué hace:** cuando un cliente pagó por adelantado servicio que NO se va a prestar
(al suspender/cancelar), admin/admin_cobranza decide qué hacer con el EXCEDENTE
(nunca automático): **acreditar** (saldo a favor del CLIENTE, no caduca, aplica a
cualquier contrato suyo), **devolver** (efectivo, sale de caja, comprobante) o
**condonar** (queda en caja, auditado). Gateado por setting super-only
`cobranza.credito_excedente` (default ON; OFF = comportamiento viejo, el excedente
se pierde). Migración `0127` (R10).
**Decisión de modelo (validada adversarialmente):** el crédito **NO es un pago**
(meterlo en `pagos` rompía ~15 agregados de caja). Vive en tabla nueva
`saldos_favor` (libro append-only: `acreditado`(+)/`aplicado`/`devuelto`/
`condonado`/`revertido`; `disponible = Σ(+acreditado) − Σ(resto)`). **Aplicarlo** =
un `cargos_extra` `origen='credito'` `tipo='credito_aplicado'` que RESTA del saldo
canónico de la cuota (igual que un descuento) → NO toca `pagos` ni el arqueo. Por eso
**invariante #4 se parte** (ver AGENTS): `recaudado_caja = Σ(pagos no anulados) −
Σ(devuelto)` ≠ `cobertura_cuota = monto + cargos_neto − monto_pagado`.
**Archivos:** `data/utils/prorrateo.dart` (`excedenteCuota`, anclado al día_pago —
espejo de `montoPuente`) · `data/repositories/contratos_repo.dart`
(`previewExcedente`/`_calcularExcedente`; `registrarDisposicionExcedente`;
`aplicarCredito`; `saldoFavorDisponible`; `_prepararRevertCredito` en
revertir*; `suspenderContrato` devuelve el id de la suspensión) ·
`pagos_repo.dart` (`_deltaCargosExtra` resta credito_aplicado) ·
`features/contratos/suspension_dialogs.dart` (`DisposicionExcedenteSelector`,
compartido) · `contrato_detail_screen.dart` (cancelación con disposición) ·
`features/clientes/cliente_detail_screen.dart` (`_SaldoFavorSection`: chip +
Aplicar, nivel cliente, oldest-first global) · `features/admin/settings/
settings_admin_screen.dart` (aviso al desactivar, `_avisoDesactivar` extensible) ·
`features/admin/reportes/{arqueo_calculo,reportes_admin_screen,pdf/
reporte_arqueo_pdf}.dart` (el arqueo RESTA devoluciones — LEFT JOIN) · `0127` +
`schema.dart` (tabla `saldos_favor`, schema v32) + `sync-rules.yaml` (3 buckets admin).
**Server (0127, espejado offline en SQLite):** `calcular_cargos_neto` Y
`cuota_total_a_cobrar` DEBEN restar `credito_aplicado` (si `cuota_total_a_cobrar` no lo
resta, el trigger `recalcular_cuota_desde_pagos` recalcula el estado SIN el crédito al
sincronizar → revierte la cuota a pendiente, server gana, y una cuota saldo-0 pendiente
traba el orden de cobro — bug que atajó el audit Fase 4). Trigger `BEFORE INSERT`
anti-sobregiro: rechaza `aplicado/devuelto/condonado/revertido` que dejen el disponible
del cliente < 0 (server gana ante carrera offline).
**Reglas:** acción de admin/admin_cobranza, **bloqueada al impersonar** (deja rastro de
quién); crédito a nivel CLIENTE; **revert consciente** (A6): revertir una suspensión/
cancelación que generó crédito lo neutraliza con **una fila `revertido` POR CUOTA
(con `cuota_id`, espejo del `acreditado` de esa cuota — fix audit Fable 5,
`0b4d804`)** SOLO si nada se consumió; si ya se aplicó/devolvió/condonó → BLOQUEA.
El per-cuota es OBLIGATORIO: el neteo A8 filtra `WHERE cuota_id = ?` — un lump sin
cuota_id no cancela y deja el excedente indisponible en una re-suspensión.
Anti doble-acreditación (A8): `_calcularExcedente` resta lo ya acreditado por
`cuota_id`.
**Antes de mergear:** `flutter test` + `invariantes_dinero.sql` (INV14 con
credito_aplicado + INV15 saldo ≥ 0 + INV16 ningún pago de crédito). Es DINERO → R11.

### R18 — Emitir historial (op_log) en una entidad/operación
**Modelo:** el historial visible lo escribe el CLIENTE, no el trigger (ver §3
Audit/Change log + `CHANGELOG-REWORK.md`). Una intención del usuario = **1 fila
`op_log` por cada OBJETO afectado**, scoped a SUS atributos, todas con el mismo
`op_id`/`actor`/`ocurrido_en`, DENTRO de la misma `writeTransaction` que muta el
dato.
**Archivos:** `data/utils/op_log.dart` (helper `OpLog`) ·
`data/utils/op_log_campos.dart` (allowlists) · `shared/widgets/historial_op_log.dart`
(widget) · el repo que muta (`pagos_repo`/`contratos_repo`/`settings_repo`/forms).
**Pasos:**
1. **Edición simple** (un form CRUD): leer la fila ANTES con `SELECT *` → mutar →
   leer DESPUÉS → `OpLog.escribirCambioEntidad` (diff curado por allowlist) /
   `OpLog.escribirBaja` para borrados. Actor: `OpLog.actorDeUsuario` (super_admin
   → "System Admin", `actor_id` NULL).
2. **Operación compuesta** (toca varios objetos: cobro, suspensión, cambio de
   fecha): un `op_id` único + un `escribir` por objeto afectado
   (contrato + cada cuota…), con su diff scoped y su `resumen` derivado de los
   MISMOS valores que se escriben (nunca recalcular — para que no "mienta").
3. **Allowlist**: registrar la entidad + sus campos visibles en
   `op_log_campos.dart` (`kOpLogCamposVisiblesDefault`/`kOpLogCamposCatalogo`). El
   diff nace ya filtrado; entidad no registrada ⇒ no-log, NO volcar columnas crudas.
4. **Pantalla**: `HistorialOpLog(entidad:'<tabla>', entidadId: id)` (filtra por
   `entidad_id`, no `IN(SELECT)` → la borrada física sigue apareciendo).
**Cuidado:** texto de eventos scopeados (checklist/comentario/material…) que no
tienen columna real va en `resumen.motivo` (lo renderiza el subtítulo), NO en
`diff.campos` con keys fuera de la allowlist (quedan invisibles — fix Fase 3b). El
panel super-only `op_log_campos_screen.dart` guarda un snapshot del catálogo en
`op_log.campos_visibles` → un override viejo OCULTA campos agregados después
(backlog conocido; se mitiga re-guardando el panel).

### R19 — Operaciones de datos (super_admin: borrar/limpiar data por error de carga)
**Cuándo:** agregar una NUEVA operación de corrección al panel, o tocar el borrado
seguro de una existente. **NO** es el flujo de un usuario normal — es del super_admin
para arreglar imports/cargas erróneas, con preview+backup+log.
**Archivos:** `features/admin/settings/data_ops_screen.dart` (UI por RPC) ·
`settings_admin_screen.dart` (tab "Operaciones", gate `esSuperAdmin`) · migraciones
`0146` (tablas `data_op_backups`/`data_ops_log`) + `0147` (6 funciones SECURITY
DEFINER). Modelo del módulo: §3 "Operaciones de datos".
**Para una operación NUEVA:**
1. **2 funciones SECURITY DEFINER** en una migración (`super_admin_preview_<x>` +
   `super_admin_ejecutar_<x>`), AMBAS arrancando con
   `if not public.is_super_admin() then raise exception …` (usa `auth.uid()` →
   chequea al LLAMADOR, no al definer) + validación de que el target pertenece a
   `p_tenant`. Idempotentes (`CREATE OR REPLACE`); si cambia la aridad, `drop`
   previo (evita overloads que ambiguan PostgREST).
2. **Borrado en orden FK** (mirar las FK REALES con `information_schema`): `pagos`
   PRIMERO (su `cuota_id` es NO ACTION); después un solo delete del contenedor deja
   que el CASCADE arrastre el resto. **Snapshot ANTES** del borrado, COMPLETO (toda
   tabla que el cascade toca, incl. `cargos_extra`/`notificaciones_mora`/
   `saldos_favor`/`visitas`/`fotos_cliente`/`cliente_etiquetas` + el `op_log` por
   `entidad_id`; el árbol completo de cascades: §3.6.1) → `data_op_backups`. **Limpiar
   `op_log`** por `entidad_id` (es client-written append-only, ningún cascade lo
   borra). Registrar en `data_ops_log` (con `afectados` jsonb + `backup_id`).
3. **¿Toca dinero/crédito?** chequear invariantes: el `saldos_favor` es a nivel
   CLIENTE y cruza contratos → cualquier borrado parcial (ej. un solo contrato) debe
   GUARDAR que no deje el saldo del cliente negativo (ver el guard de
   `eliminar_contrato`). Borrar pagos/cuotas sin pensar el crédito descuadra el libro.
4. **UI**: un `_OperacionCard` (preview → confirmación por tipeo del código resuelto
   → ejecutar) reusando `_resolverId` (folding ñ con `foldSqlExpr`, aborta si
   ambiguo). Anti-pantalla-negra: flag + overlay, NO `showDialog` de loading
   (regla #7). El gate `esSuperAdmin` va en el menú Y en el widget.
**Cuidado:** las tablas son **server-only** (RLS solo-READ super_admin, INSERT por las
funciones) — **NO agregarlas a `schema.dart` ni a sync rules** (se leen por REST con
el JWT del super). Verificar SIEMPRE con query que la migración corrió (`pg_proc`/
`to_regclass`), nunca asumir.

---

### R20 — White-label: app branded por tenant (Opción B)
**Cuándo:** brandear un tenant nuevo (su ícono + nombre + logo de login) o tocar el
mecanismo. **Es la MISMA app**; el branding es 100% cosmético (RLS aísla los datos; NO
hay tenant-lock — un user de otro tenant podría loguearse pero solo ve SU data).
**Archivos:** `branding/<slug>/{config.json,logo.png}` (lo que se agrega por tenant) ·
`tool/aplicar_branding.dart` (genera el ícono + el logo del login) · `Install Steps/
build-release.ps1` (orquesta) · `lib/data/services/update_service.dart` (canal por slug) ·
`lib/features/shared/widgets/brand_login_logo.dart` · `assets/branding/login_logo.png`
(default = copia de `app_icon.png`). Tenants actuales: **Telecable Mairena S.A.**
(`com.sitecsa.crm.mairena`), **Telenet** (`com.sitecsa.crm.telenet`).
**Tenant nuevo (3 pasos):**
1. `branding/<slug>/config.json`: `slug`, `displayName`, `releaseName` (nombre de
   archivo del instalador, ej. `Telecable-Mairena-CRM` / `Telenet-CRM` — guion, sin
   espacios), `applicationId` (`com.sitecsa.crm.<slug>`), `msixIdentity` (igual al
   applicationId), `logo: "logo.png"`.
2. Dejar `branding/<slug>/logo.png` (logo de la empresa = el del recibo; PNG fondo
   blanco/transparente, ≥1000px de ancho). Preview del ícono:
   `dart run tool/aplicar_branding.dart <slug> --preview`.
3. Buildear: `build-release.ps1 -AllTenants` (todos) o `-Tenant <slug>` (uno); `-NoRelease`
   = build local sin publicar (probar antes de distribuir).
**Qué hace el build por tenant (y RESTAURA con `git checkout` al terminar — exige la rama
commiteada):**
- `aplicar_branding.dart`: ícono **forma A** (logo centrado en blanco 1024², recorta el margen
  transparente) → `assets/icon/app_icon.png`; copia el logo ancho → `assets/branding/login_logo.png`.
- `flutter_launcher_icons` regenera mipmaps Android + `.ico` Windows desde ese ícono.
- Patcha: `android:label` (manifest), título de ventana (`windows/runner/main.cpp`),
  `display_name`+`identity_name` (msix_config de `pubspec.yaml`), `applicationId` (build.gradle.kts).
- Buildea con `--dart-define=TENANT=<slug>`; `update_service` lee ese slug y baja
  el manifest `version-<slug>.json` (nombre FIJO), que apunta al instalador **branded
  versionado** `<releaseName>-vX.Y.Z.{apk,msix}` (ej. `Telecable-Mairena-CRM-v0.18.3.msix`;
  todo en el MISMO GitHub Release). El auto-update sigue el `download_url` del manifest.
**Invariantes / cuidados:**
- Branding cosmético: NO toca data, permisos, sync ni schema. **NO requiere migración SQL ni
  redeploy de sync rules** (es build-side + un PNG por tenant).
- **applicationId por tenant (Opción B):** un equipo que ya tiene la app vieja (genérica
  `com.example.isp_billing`) la ve como app DISTINTA → instala AL LADO. **Migración 1 vez:**
  sincronizar la vieja → instalar la branded → verificar → desinstalar la vieja; de ahí en más
  auto-update in-place sin reinstalar.
- El `version-<slug>.json` y los instaladores branded `<releaseName>-v*.{apk,msix}` son
  **gitignored** (artefactos de build).
- **AISLAMIENTO CROSS-APP en disco (actualizado v0.24.10):** dos apps branded (Mairena
  y Telenet) instaladas en la MISMA PC/tel PUEDEN convivir **SIN namespace manual en el
  código**. MSIX con `identity_name` distinto (`com.sitecsa.crm.mairena` vs
  `com.sitecsa.crm.telenet`) virtualiza `AppSupport` (donde vive la DB de PowerSync) y
  `SharedPreferences` (registry) automáticamente. Android con `applicationId` distinto
  sandboxea TODO (`/data/data/<applicationId>/`). `getApplicationDocumentsDirectory()` en
  Windows/MSIX devuelve `%USERPROFILE%\Documents` (compartido), pero el logo se guarda en
  `logo_empresa/logo_<tenantId>.png` (UUID distinto por tenant → no colisiona).
  **v0.24.7 intentó un namespace por slug (`<AppSupport>/<slug>/`, `logo_empresa_<slug>/`)
  pero era innecesario y causó bugs:** DB orfanada (vista vacía "Nada por cobrar" tras
  update), migración que borraba `logo_empresa/` (fuga de logo). **Revertido en v0.24.10.**
  El aislamiento real lo da el OS/instalador, no el código.

### R21 — Tocar / rediseñar el módulo Inventario
**Cuándo:** cambiar las vistas de inventario, el alta de productos/categorías, los
filtros, el lifecycle del serial, o cualquier flujo de stock.
**Mapa de impacto (qué revisar SIEMPRE — quién se entrelaza con inventario):**
- **Clientes:** `inv_seriales.cliente_id`/`contrato_id` → la ficha del cliente lista los
  equipos instalados (`cliente_detail_screen.dart` `_EquiposInstaladosSection`,
  gateada por módulo). Si tocás asignar/devolver/baja o el estado del serial →
  revisar esa sección.
- **Tickets:** `ticket_materiales` → trigger SECURITY DEFINER `0106` →
  `inv_movimientos 'consumo'` + serial `instalado`. Si cambia el modelo de
  seriales/movimientos o el consumo → revisar el trigger `0106` y el flujo de
  materiales del ticket (`lib/features/admin/tickets/`).
- **op_log:** todo flujo que muta seriales/movimientos emite `op_log` (R18).
  Entidad/flujo nuevo → registrar labels/allowlist en `op_log_campos.dart`.
- **Red:** asignar consulta `clientes.puerto_id` (aviso suave, no bloquea).
- **Gate / rutas:** módulo `inventario` (menú + router + **RLS 0114**); rutas
  condicionales `enAdminShell ? '/admin/x' : '/x'` en **ambas** variantes (audit #5).
**Invariantes (no romper):**
- **Stock DERIVADO**, nunca materializado (serializado = `COUNT` `en_stock`; granel =
  Σdestino−Σorigen) — `inventario_v2_screen.dart` (tab Existencias, const `_granelStock`)
  + `inventario_alerta_provider.dart` (badge de stock bajo).
- **Guardas de transición del serial** (trigger `0118`): `baja` terminal · instalar
  exige venir de `en_stock` · un instalado no cambia de cliente sin pasar por stock ·
  sin transferencias tardías sobre un `instalado`.
- Ledger `inv_movimientos` **append-only** (corregir = movimiento inverso, nunca
  UPDATE/DELETE). `ocurrido_en` en UTC.
- Inventario **NO** entra a `recaudado_caja`/`cobertura` (métricas de dinero).
- Búsqueda/unicidad case-insensitive con `foldBusqueda`/`foldSqlExpr` (audit #1d — ñ/acentos).
**Rediseño 2026 (rama `Inventario-Tickets`, ver `docs/PROPUESTA-INVENTARIO.md`) — ORDEN:**
1. ✅ Estándares `ListaPaginadaScroll` + `FiltrosBar` + `opcionesDesdeRows`
   (`lib/features/shared/widgets/`, reusan el gold-standard de Clientes
   `clientes_admin_screen.dart _ListaState`; reusables para TODA la app) — con tests.
2. ✅ Vista exclusiva (`inventario_v2_screen.dart`, ruta/menú **TEMP-BETA**
   `/admin/inventario-v2`): tabs **Equipos** (seriales paginados + filtros
   estado/producto/ubicación + búsqueda `foldBusqueda` + tap→historial) y
   **Existencias** (granel, stock derivado del ledger + filtro Categoría + "bajo
   mínimo" = def. del badge + tap→stock por ubicación). Ambos `ConsumerStatefulWidget`
   (las opciones de los chips se re-suscriben en `dbEpoch`, igual que la lista).
   Convive con la pantalla vieja; al terminar el rediseño reemplaza `/admin/inventario`
   y se **BORRA el cableado beta** (grep `TEMP-BETA`: router import/route/soloAdmin/gate
   + `_MenuItem` del shell).
3. Ficha de equipo (`ficha_equipo_screen.dart`, `/admin/inventario-v2/equipo/:id`):
   hub serial ↔ cliente ↔ tickets ↔ historial.
   - **3a ✅ detalle solo-lectura**: datos del serial + cliente linkeable + tickets
     (vía `ticket_materiales`, NO `inv_movimientos`) + `HistorialOpLog`. Estado
     compartido en `inventario_comun.dart` (`kEstadoSerial`/`estadoSerialColor`/
     `kEstadoSerialOpciones`, usados por la lista y la ficha).
   - **3b ✅ acciones**: write-paths extraídos a `inv_seriales_acciones.dart`
     (`asignarEquipo`/`devolverEquipo`/`transferirEquipo`/`darDeBajaEquipo` + sus pickers)
     + infra op_log a `inventario_oplog.dart` (`InvError`/`actorOpLog`/`opLogMovimiento`,
     compartidas con el inventario viejo, que quedó rewireado a esas funciones —
     comportamiento idéntico). La ficha tiene botones gateados por estado.
4. ✅ Catálogo en pantalla dedicada (`inventario_catalogo_screen.dart`,
   `/admin/inventario/catalogo`): los 4 tabs (Productos/Categorías/Ubicaciones/
   Proveedores) copiados del viejo (aditivo, la vieja queda intacta hasta el cierre),
   reusan `inventario_oplog.dart`; acceso con botón "Catálogo" en la vista v2.
5. ✅ **Cierre**: `/admin/inventario` sirve `InventarioV2Screen`; ficha en
   `/admin/inventario/equipo/:id`; **borrados** `inventario_screen.dart` (monolito
   viejo, 2568 líneas) + el cableado beta. **Rediseño completo y en producción.**
Cada paso: tests + audit + actualizar este recipe + `MODULOS.md` + `BITACORA.md`.

### R22 — Cambiar el plan de un contrato (mid-contrato, sin contrato nuevo)
**Archivos:** `contratos/cambio_plan_dialog.dart` (UI: de→a con delta + barra de fechas [día de pago · ciclo actual · vence] + resumen "QUÉ CAMBIA, CUÁNDO Y POR QUÉ" + nota de vigencia) · `data/utils/prorrateo.dart` (`montoCuotaRevaluada`, `prorrateoCambioPlanHoy`, `ProrrateoCambioPlan` — reusan `montoPuente`/`servicioFin`/`estadoServicio`, NO los modifican) · `contratos_repo.dart` → `cambiarPlan` (transacción única + op_log 1-fila-por-objeto + `recalcVmvDeContrato`) · botón gateado en `contrato_detail_screen.dart` (`_AccionesContrato`) · gate `cobranza.cambio_plan_habilitado` (super-only, OFF default; getter + `puedeCambiarPlanProvider` en `settings_repo.dart`) · migración `0151` (setting) + `0152` (fix del seed trigger). El detalle de pago (`contrato_detail_pagos.dart`) desglosa el cargo del prorrateo (cuota base + ajuste = total).
**Qué hace:** mantiene el contrato y su vigencia; solo cambia `contratos.plan_id` + re-valúa el `monto` de las cuotas FUTURAS (`estadoServicio='futuro'`, anclado al día_pago) al precio nuevo (clamp ≥ monto_pagado, CHECK monto_pagado≤monto). El conteo de cuotas NO cambia (invariante #11 intacto). **El precio vive en `planes.precio_mensual`, NO en contratos.**
**Dos modos (SegmentedButton):**
- **Próximo ciclo** (default): solo re-valúa las futuras. CERO plata hoy. El ciclo en curso sigue al plan viejo (downgrade NO da crédito — telco-standard).
- **Hoy con prorrateo**: además ajusta los días NO servidos del ciclo en curso = la diferencia prorrateada `montoPuente(hoy, finVentana, |Δprecio|)`: UPGRADE → `cargos_extra` (origen='cobro', tipo='otro', descripcion='Diferencia por cambio de plan') sobre la cuota en curso, cobrable con el flujo normal · DOWNGRADE → `saldos_favor` tipo='acreditado' (R17), NO toca `pagos` → no infla recaudado_caja.
**Server gana, SIN trigger nuevo (auditado fase 2):** el cliente re-valúa + sincroniza = la verdad (last-write-wins; límite multi-device aceptado). El cobrador queda bloqueado de `plan_id`/`monto` por los guards `*_check_cobrador_update` pre-existentes; el admin escribe por `contratos_write_admins` (RLS genérica). NO se agregó RLS ni trigger propio.
**Gates que frenan:** feature ON (super_admin) · rol admin (NO admin_cobranza
— es gestión administrativa, Fase 2 roles 2026-07-19; antes incluía
admin_cobranza) · NO impersonando · contrato activo · plan ≠ actual · el
cliente no tiene otro contrato activo en el plan destino (pre-chequeo del
índice único `(cliente_id,plan_id) WHERE estado='activo'`).
**Total del contrato (REDEFINIDO, decisión Rubén):** el "Total" del header pasó de `precio×meses` a **Σ cuotas vivas** (`contrato_detail_header.dart` + `vivas` COUNT en `contratoRecaudadoProvider`) — robusto al cambio de plan. El hint "ajustado" usa el CONTEO (vivas < duración), no el monto. Ver invariante #5 de `AGENTS.md`.
**Antes de mergear:** `flutter test` (grupo `ContratosRepo.cambiarPlan` en `pagos_repo_test.dart` + `prorrateo_test.dart`) + `invariantes_dinero.sql` (= 0). Es DINERO → R11. Migraciones `0151`+`0152` corridas/verificadas en vxxz.

---

## §6. Reglas de wiring que NO se deben romper

| Regla | Dónde se enforcea | Romperla = |
|---|---|---|
| RLS por tenant | policies `current_tenant_id()` + sync rules | fuga cross-tenant |
| Server gana | triggers Postgres = verdad de dinero/estado | saldos divergentes |
| Historial = `op_log` (cliente, append-only; ÚNICO change-log desde 0140) | repos emiten `op_log` en su `writeTransaction` (R18); sin DELETE jamás | pérdida de trazabilidad / historial fantasma |
| Tabla tenant-scoped nueva nace con `super_admin_all` (y UPDATE si la escribe el cliente) | policies a mano (R10) | super_admin impersonando sin permiso de escritura |
| Invariantes de dinero (10) | `cobro_calculo`/`pagos_repo`/triggers/`invariantes_dinero.sql` | plata descuadrada |
| Cadena DB↔schema↔sync↔version | R4 | columnas que no sincronizan |
| `dbEpochProvider` en globales | cada StreamProvider global | streams de la DB vieja tras user-switch |
| Denormalizar `cobrador_id` en INSERTs | repos | el cobrador no baja sus propias filas |
| SQLite ≠ Postgres | grep `FILTER/::/ILIKE/RETURNING` en lib/ = 0 | crash en runtime local |
| TZ `-6 hours` en límites de día | todo `date('now')`/`julianday('now')` | mora corrida 1 día de noche |
| Estados derivados nunca persistidos | CHECK en `cuotas.estado` | constraint violation |
| Timestamps: `ocurrido_en` en UTC; `fecha_pago`/`tickets.created_at` local-naive A PROPÓSITO | convención (ver AGENTS.md backlog L1) | bucketing de reportes roto |
| Módulos opcionales: gate en menú+router+RLS (0114) | `_MenuItem`+redirect+policies | inconsistencia comercial |

---

## §7. Mapa rápido archivo → responsabilidad (los que más se tocan)

| Archivo | Responsabilidad |
|---|---|
| `lib/main.dart` | bootstrap, auth listener, connect/disconnect PowerSync, workers |
| `lib/config/router.dart` | rutas + redirect con TODOS los gates |
| `lib/powersync/db.dart` | `ps.db` per-user, `_dbWipeVersion`, locks |
| `lib/powersync/schema.dart` | tablas/columnas del SQLite local |
| `lib/powersync/connector.dart` | upload de la CRUD queue + clasificación de errores |
| `powersync/sync-rules.yaml` | buckets por rol (qué baja a quién) |
| `lib/data/repositories/pagos_repo.dart` | TODO el dinero (cobrar/anular/editar + mirrors) |
| `lib/data/repositories/settings_repo.dart` | claves/defaults/getters de settings |
| `lib/data/utils/cobro_calculo.dart` | matemática del cobro (invariantes) |
| `lib/data/utils/cuota_estado.dart` | espejo Dart del trigger de dinero |
| `lib/data/utils/cuota_estado_visual.dart` | estados visuales + colores |
| `lib/data/utils/ticket_sla.dart` | SLA, transiciones, `parseTicketWallClock` |
| `lib/data/utils/op_log.dart` + `op_log_campos.dart` | escribir el historial de intención (helper `OpLog` + allowlists) |
| `lib/data/utils/audit_changelog.dart` | util de constantes de campos (labels/allowlists) que consume `op_log`; ya NO tiene relación con el `audit_log` eliminado en 0140 |
| `lib/data/services/imagen_compresion.dart` | compresión client-side ANTES de todo upload a Storage (isolate; Windows ignora `imageQuality` del picker) |
| `lib/features/admin/shell/admin_shell.dart` | galería de inicio admin + gates |
| `lib/features/shared/widgets/historial_op_log.dart` | `HistorialOpLog` — el único widget de historial (toda pantalla) |
| `supabase/functions/_shared/*.ts` | helpers de las 6 Edge Functions |
| `supabase/tests/invariantes_dinero.sql` | TODAS las verificaciones de dinero (hoy 17, INV1-INV17) — correr y exigir `violaciones = 0` en cada fila, sin hardcodear el conteo |

_Verificado contra: DB wipe v1 (schema in-place) · migraciones 0001→0131 (0128/0129/0131
op_log + 0130 clientes.email) · 6 Edge Functions · rework de change log (op_log) + galería
de inicio admin 2026-06-20._

---

## §3.9. Rol `lectura` y la guardia de escritura (0198-0200)

**Qué es:** el dueño del ISP mirando su operación. Ve TODO el tenant, incluida la
plata, y no puede modificar nada. Entra al panel admin completo.

**Por qué tres barreras y no una:** hay ~86 escrituras repartidas en ~32 archivos.
Ocultar botón por botón deja huecos, y un hueco no da error: da un **cambio
fantasma** — el usuario ve aplicarse la operación, el connector la descarta
después y revierte sin avisarle.

1. **La pantalla** — `soloLecturaProvider` (`data/providers/cobrador_provider.dart`)
   es la fuente ÚNICA; no compares el rol a mano. Preferí OCULTAR el control
   antes que dejar que falle.
2. **La app** — `ps.dbW` (`powersync/db.dart`) es la misma base con una guardia
   síncrona que lanza `SoloLecturaException` antes de tocar el SQLite. El rol se
   espeja en `ps.rolActualCache` desde `cobradorActualProvider`. Las LECTURAS
   siguen por `ps.db`. **Cuidado:** inyectar `Repo(db: ps.db)` esquiva la
   guardia (pasó en `cambio_plan_dialog`).
3. **Postgres** — 38 policies `lectura_select`, ninguna de escritura. Más el
   connector, que descarta la cola de subida del rol para que un write escapado
   no le llene la pantalla de errores ni trabe la cola.

**Al agregar una acción nueva:** gatearla con `soloLecturaProvider` y escribir el
permiso como ALLOWLIST (“solo estos roles pueden”). Los flags escritos como
denylist (`!esAdminUsuarios`) le dan permiso por omisión al próximo rol — así se
escaparon 4 casos.

## §3.10. PIN del Resumen (0197, 0201-0202)

Uno por usuario, para `admin` y `lectura`. Se pide **en cada visita** al Resumen
y al volver de segundo plano (el desbloqueo vive en el State, no en un `static`).

**Dónde vive:** tabla `dashboard_pins` (PK = el propio `cobradores.id`), con RLS
`id = auth.uid()` y un bucket que trae UNA fila. Se eligió tabla aparte y no una
columna con dos buckets porque cuando la misma fila llega por varios buckets con
distintas columnas, **cuál gana no es determinista** — y equivocarse ahí es
filtrar el PIN o borrárselo al dueño.

Lo que viaja tenant-wide es `cobradores.dashboard_pin_configurado` (columna
GENERADA, booleana): alcanza para que Personal muestre "tiene PIN" sin el valor.

**Nadie ve el PIN de otro**, ni para ayudarlo: si alguien lo olvida, un admin usa
**Forzar cambio** (`forzar_reset_dashboard_pin`), que lo borra sin leerlo.
Escritura del propio: `set_mi_dashboard_pin` (RPC; no va por la cola de sync).

⚠️ `cobradores.dashboard_pin` sigue en los buckets SOLO por compatibilidad con
v0.27.0, que lo lee. Quitarla del yaml recién cuando no queden v0.27.0 en campo.
