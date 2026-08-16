# AGENTS.md

Reglas y proceso de trabajo del proyecto **Cobranza ISP (CRM)** para
CUALQUIER agente de AI (Claude Code, OpenCode, Codex, Cursor, Antigravity,
etc.). Si estás abriendo este repo, leé esto primero. (Claude Code lo carga
vía el shim `CLAUDE.md`, que es solo `@AGENTS.md`; las demás herramientas
leen este archivo directo por el estándar AGENTS.md.)

---

## 📚 EL SISTEMA DE DOCUMENTOS (leer en este orden al abrir una sesión)

| # | Documento | Qué responde | Cuándo actualizarlo |
|---|---|---|---|
| 1 | **`BITACORA.md`** | ¿Dónde quedamos? Estado vivo + historial de cambios con su porqué | **SIEMPRE al cerrar la sesión** (Fase 6) |
| 2 | **`AGENTS.md`** (este) | Reglas, invariantes, proceso | Solo si cambia una regla/proceso |
| 3 | **`PRODUCTO.md`** | Qué es la app, misión, roles, día a día, stack y porqués | Si cambia misión/roles/módulos de producto/stack |
| 4 | **`MODULOS.md`** | Catálogo de módulos: propósito, features y ciclo de uso (con diagrama) de cada uno | Si se agrega un módulo o cambia su propósito/features/gating |
| 5 | **`ARQUITECTURA.md`** | Cómo está construida: módulos, conexiones, settings y **RECETAS de cambios** | Si cambia un módulo/tabla/setting/ruta/conexión |
| 6 | `TESTING.md` §0 | Loop de testing manual con Rubén | Si un feature nuevo trae flujo de testing |
| 7 | `Install Steps/` | Build, release, versionado e instalación | Si cambia el flujo de build |
| 8 | `Troubleshooting SQL/` | Corregir DATA de un tenant en producción vía SQL (guía para AI: acoplamiento de tablas, triggers que recalculan solos, recetario de fixes seguros) | Si cambia un trigger/cascada/invariante de dinero |
| 8b | `Guia de uso/GUIA-APP.md` | Guía de USUARIO por módulo (paso a paso con mockups SVG) para el personal del tenant — sin super_admin | Si cambia la UI/flujo de un módulo: editar el spec `Guia de uso/tools/flows_*.py` y regenerar (`python tools/mockups_guia.py`) |
| 9 | **`AUDIT-PROFUNDO.md`** | El audit de 4 especialistas senior (ciclo de vida · lógica · datos/uniones · UI/UX). Se ejecuta ENTERO cuando Rubén pide un **"audit profundo"** | Cada vez que un bug se nos escapa: se agrega la regla que lo habría cazado |
| 10 | `CLAUDE.md` | Shim de 1 línea (`@AGENTS.md`) para que Claude Code cargue este archivo automáticamente | NUNCA — las reglas se editan ACÁ |

**Para hacer un CAMBIO en el código**: buscá tu caso en `ARQUITECTURA.md` §0
(índice de cambios → recetas R1-R18). Eso evita escanear el repo.
**Históricos**: `docs/archive/` (HANDOFF, REPORTE-SESION, ESTADO-APP, STACK,
ROADMAP, planes y audits viejos — solo para arqueología, NO mantener).

---

## Producto (resumen mínimo — detalle en `PRODUCTO.md`)

SaaS **multi-tenant** de cobranza para ISPs de Centroamérica (Nicaragua).
Roles: `super_admin` (Rubén, dueño del SaaS) · `admin` / `admin_cobranza`
(ISP) · `admin_usuarios` (gestión sin dinero, cola de aprobación) ·
`cobrador` (campo, offline-first) · `tecnico` (módulo tickets) ·
`admin_tickets` (tickets sin dinero).
Onboarding **SIN email** (password server-side por WhatsApp); no hay signup
público → findings de seguridad "si signup estuviera habilitado…" = fuera de
scope. Foco: bugs reales, no hardening hipotético.

Stack: Flutter (Android + Windows) · Supabase (Postgres+Auth+Edge+Storage) ·
PowerSync **SELF-HOSTED** (desde 2026-07-13: corre en un VPS Hetzner propio, NO en
el cloud de paga que se retiró por costo — ver ARQUITECTURA §3.8; offline-first, DB
**wipe v1** — `_dbWipeVersion` en `db.dart`; el schema se aplica IN-PLACE, el bump
NO re-descarga por cambio aditivo, solo por destructivo/cache-corrupto — fix #1,
política en ARQUITECTURA R4) · Riverpod ·
go_router.

---

## Principios arquitecturales a respetar SIEMPRE

1. **Multi-tenant con RLS** — toda tabla operativa tiene `tenant_id` NOT NULL
   y policies por `current_tenant_id()`; super_admin bypassa con
   `is_super_admin()`. Tabla nueva → checklist completo en ARQUITECTURA
   **Receta R10** (incluye `super_admin_all` A MANO + gate de módulo 0114).
   **Toda tabla tenant-scoped DEBE nacer con la policy `super_admin_all`
   (`FOR ALL USING/WITH CHECK is_super_admin()`) a mano** — sin ella el
   super_admin impersonando NO puede escribir (su `current_tenant_id()` no
   matchea el tenant impersonado). Ejemplo del bug si falta: `op_log` nació en
   0128 sin `super_admin_all` → "Sin permiso" al cambiar un setting
   impersonando; se arregló recién en 0131.
2. **Offline-first** — el cobrador/técnico opera sin internet. Features que
   requieran conexión sincrónica deben declararse explícitamente.
3. **Server gana** — Postgres es la fuente de verdad. El cliente espeja
   triggers (mirrors) SOLO para UX instantánea offline.
4. **Change log (`op_log`) append-only** — el historial es `op_log` (log de
   intención del cliente); nunca borrar rows, para "deshacer" se agregan rows
   nuevas. (El `audit_log` forense del server se ELIMINÓ — 0140.)
5. **Workflow sin email** — toda feature que asuma "envía email" necesita
   fallback no-email.

## Invariantes de dinero (NUNCA violar — la base del negocio)

Cualquier cambio que toque `pagos`, `cuotas`, `recibos`, `contratos`,
`cargos_extra` o flujos de cobro DEBE respetarlas y el audit DEBE verificarlas:

1. **`pagos.monto_cordobas` = lo APLICADO a la cuota** (lo que entra a caja).
   NUNCA lo entregado por el cliente.
2. **`pagos.vuelto_cordobas` = lo devuelto, SIEMPRE en córdobas.** El cliente
   puede pagar en USD; el vuelto jamás se da en USD.
3. **`pagos.monto_original` = lo ENTREGADO en la moneda original.**
   Invariante: `monto_original × tasa ≈ monto_cordobas + vuelto_cordobas`.
4. **Dos métricas separadas (desde 0127 — crédito por excedente, R17):**
   - **`recaudado_caja` = `SUM(pagos.monto_cordobas)` VIVOS (ver #7: no anulados
     Y no en revisión) − `SUM(saldos_favor
     devuelto)`.** La plata real que entró y sigue en caja (= el gran total NETO del
     arqueo, `equivalenteTotalC`). Nunca sumar lo entregado ni el vuelto.
     **Matiz (audit 2026-06-27):** el **dashboard** y el **ingreso bruto del arqueo**
     muestran `SUM(monto_cordobas)` **BRUTO** (sin restar devoluciones) a propósito —
     son "cobros del período" (entrada de pagos en una ventana), métrica distinta de
     la caja neta; coinciden entre sí y solo divergen del neto si hubo una **devolución
     de saldo a favor en efectivo** (rara). El que resta devoluciones es el TOTAL NETO
     del arqueo. No es bug: bruto ≡ bruto, neto = bruto − devoluciones.
   - **`cobertura_cuota` = `monto + cargos_neto − monto_pagado`.** Cuánto de la cuota
     está cubierto (incluye el descuento por crédito aplicado), NO cuánta plata entró.
   - El **crédito a favor NO es un pago**: se acredita en `saldos_favor` y se aplica
     como `cargos_extra credito_aplicado`. Por diseño NO toca `pagos` → no aparece en
     ninguna métrica de caja. (Antes de 0127 ambas coincidían.)
5. **Total de contrato fijo MOSTRADO = `Σ cuotas vivas`** (monto + cargos de las
   no-anuladas = `recaudado + pendiente`), **NO `precio_mensual × meses`**
   (REDEFINIDO 2026-06-27 para el cambio de plan — R22). Por qué: el nominal usa
   el precio LIVE del plan y descuadraría tras un cambio de plan; las cuotas son
   **snapshots del precio de su momento** (las pasadas/en-curso al plan viejo, las
   futuras re-valuadas al nuevo) → su Σ es el Total real facturable. `precio×meses`
   queda SOLO para detectar fijo vs indefinido (header) y como nominal conceptual.
   `pendiente = Σ saldos canónicos de cuotas vivas` (= la fórmula de los reportes;
   consistencia #10) — robusto a suspensión (meses anulados no se cobran) Y a
   cambio de plan. El hint **"ajustado"** del header señala por **CONTEO**
   (`vivas < duración_meses`), nunca por monto (un cambio de plan altera el monto
   pero no el conteo → no debe disparar el hint).
6. **Contratos indefinidos**: solo "total recaudado"; no hay "pendiente".
7. **`cuota.monto_pagado` = SUM(pagos aplicados VIVOS)** — lo mantiene un
   trigger server. El cliente NUNCA lo calcula a mano (solo espeja).
   **PAGO VIVO = `anulado = false AND en_revision = false`.** Las DOS
   condiciones, siempre. Un pago en cuarentena (`en_revision`) NO está anulado
   pero TAMPOCO cuenta: es un cobro duplicado esperando que alguien decida cuál
   vale. Verificado contra el server (`recalcular_cuota_desde_pagos`, 0083 +
   0224): `where cuota_id = ? and anulado = false and en_revision = false`.
   Esta definición estuvo escrita a medias acá —solo "no anulados"— y por eso
   se propagó incompleta a los invariantes de abajo y a más de un audit.
8. **Anular un pago restaura** la cuota (trigger) y el pago se PRESERVA.
9. **Cargos manuales** se asocian al contrato; cuentan para recaudado, NO
   para el total fijo.
10. **Consistencia cross-pantalla**: el saldo/recaudado debe dar IDÉNTICO en
    todas las pantallas (fórmula canónica:
    `monto + COALESCE(cargos_neto,0) − monto_pagado`). Si dos difieren, una
    está mal — investigar antes de seguir.
11. **Oldest-first (chokepoint cliente, #4 2026-06-19):** no se cobra una cuota
    dejando atrás otra más vieja pendiente del mismo contrato. Lo enforça
    `pagos_repo._validarOldestFirst` (red final en `registrarCobro`/
    `registrarCobroMultiple`, online y offline) además de los 6 guards de UI.
    Excluye cargos manuales; permite el adelanto contiguo. Por DECISIÓN de
    producto NO hay trigger server (la data no se ingresa por SQL); límite
    aceptado: multi-device offline sin sincronizar.

**Verificación**: `supabase/tests/invariantes_dinero.sql` después de cada
deploy que toque dinero. Toda fila debe dar `violaciones = 0`.

**Modelo del que salen estos invariantes** (facturación VENCIDA · ancla al
`dia_pago` · ventana de servicio · reportería) → **`ARQUITECTURA.md` §3.5**
(la regla de oro). **Anclaje (clave, bug 2026-06-16):** toda lógica de
prorrateo o de ciclo (suspensión, cambio de fecha, "qué servicio cubre esta
cuota") usa la **ventana de servicio del `dia_pago`** (`ventanaServicio`/
`estadoServicio` en `prorrateo.dart`), NUNCA el mes calendario. Solo coinciden
si `dia_pago = 1`; para cualquier otro día, anclar al mes calendario sub/sobre-cobra.
**Cobrador (clave, P3b 2026-06-17):** `clientes.cobrador_id` (denormalizado en
`contratos`/`cuotas`) es ORGANIZATIVO (en qué lista/mapa aparece; puede ser NULL
= "admin-managed", solo lo ven/cobran admin/admin_cobranza). QUIÉN cobró lo
captura `pagos.cobrador_id`/`recibos.cobrador_id` (NOT NULL = el usuario que
registró el pago) y TODA la reportería (arqueo, "por cobrador") agrupa por ESE
campo, NUNCA por el cobrador asignado del cliente. Reasignar un cliente no toca
el historial de quién cobró. Detalle: §3.5 (4b).

## Modelo del change log (obligatorio para TODA entidad editable)

**Toda entidad que un usuario pueda crear/editar/borrar tiene historial
accesible desde su pantalla.** Modelo VIGENTE = **`op_log`** (rework 0128/0129/
0131): el **CLIENTE** escribe la intención DENTRO de su `writeTransaction` —
**una fila por cada OBJETO afectado** por la intención, scoped a los atributos de
ESE objeto (la cuota NO hereda del contrato). Las filas de una misma intención
comparten `op_id`, `actor` y `ocurrido_en` (device-time, `.toUtc()`).
Append-only. El historial visible lo da `op_log`; lo lee `HistorialOpLog`
(`lib/features/shared/widgets/historial_op_log.dart`), enchufado en TODAS las
pantallas de historial.

- **`audit_log` ELIMINADO (0140, 2026-06-21):** la tabla, sus 33 triggers
  (`audit_changelog_trg`) + funciones, el panel `/admin/audit` y la "auditoría por
  cobrador" del super_admin se borraron. `op_log` es el ÚNICO registro de cambios.
  (Trade-off aceptado: sin rastro forense tamper-proof de resets/impersonación/
  anulaciones — `op_log` es client-written.)
- **Helpers**: `OpLog` en `lib/data/utils/op_log.dart`
  (`OpLog.actorDeUsuario` → super_admin = `OpLogActor.systemAdmin` con
  `actor_id` NULL); allowlists de campos visibles por entidad en
  `lib/data/utils/op_log_campos.dart` (`kOpLogCamposVisiblesDefault` /
  `kOpLogCamposCatalogo` / `opLogCamposVisibles`); la visibilidad se gestiona
  en `op_log_campos_screen.dart` (settings).
- **Quién lo emite**: `pagos_repo` (cobros, edición de pago, cambio de fecha),
  `contratos_repo`, `cuotas_repo` (cargos/descuentos del admin — aplicar/quitar,
  scoped a la cuota, desde el audit 2026-06-28), `settings_repo`, etiquetas,
  `visitas_service`, `foto_gallery_widget` (alta/baja de fotos, scoped al
  cliente) y los forms de cada entidad.
- **RLS de `op_log`**: `op_log_read` (`tenant_id=current_tenant_id() AND
  is_admin_or_cobranza()`), `op_log_insert`/`update`
  (`tenant_id=current_tenant_id() AND (actor_id=auth.uid() OR NULL)`) **+
  `super_admin_all` (`FOR ALL USING/WITH CHECK is_super_admin()`)** agregada en
  0131. El super_admin LEE por las sync rules de PowerSync (bucket
  `impersonated_tenant`), no por la policy de SELECT.
- **Sin LIMIT** en los historiales per-entidad (vida completa).
- **Contrato al agregar entidad nueva**: **EMITIR `op_log`** desde el
  repo/form (1 fila por objeto afectado, en el `writeTransaction`) + registrar
  labels/allowlist en `data/utils/op_log_campos.dart` + `HistorialOpLog` en su
  pantalla. Detalle operativo: ARQUITECTURA **Receta R10**; diseño completo:
  `CHANGELOG-REWORK.md`.

---

## Proceso mandatorio de fixes y features (lifecycle)

**Fase 1 — Entender:** leer el pedido → `BITACORA.md` (dónde quedamos) →
este AGENTS.md → `ARQUITECTURA.md` §0 (¿hay receta para este cambio?).

**Fase 2 — Pre-evaluación:** investigar archivos (la receta dice cuáles),
evaluar riesgos/dependencias, **presentar propuesta con opciones y ESPERAR
aprobación (OBLIGATORIO)**. Si el cambio toca UI/UX → la propuesta incluye un
**mockup visual** (ver "Reglas de comunicación con Rubén").

**Fase 3 — Implementación:** cambio por cambio, committeando. Si toca
tablas/columnas: cadena de integridad completa (Receta R4/R10).

**Fase 4 — Audit post-implementación (OBLIGATORIO):** lanzar agentes (Code +
DB integrity mínimo; 3 en paralelo para cambios significativos: Code Audit +
QA + el tercero según el cambio: UX / Deployment Safety / Security).
> Si Rubén pide un **"audit profundo"**, no es este audit: se ejecuta
> **`AUDIT-PROFUNDO.md`** completo — 4 especialistas senior, verificación contra
> la base real y reporte con lo que se intentó romper y aguantó.
**Presentar findings con el formato de reporte** (abajo) y esperar aprobación
de los fixes. Aplicar fixes convergentes.

**Fase 5 — Testing:** paso a paso para Rubén (formato `TESTING.md` §0: qué
hacer → qué debería ver → si falla). Indicar restart completo vs hot reload,
comandos exactos de migraciones, y si hay redeploy de sync rules. **Además, el
handoff DEBE abrir con dos líneas obligatorias** (sin ellas está incompleto):
1. **Build esperado:** la versión semver de `pubspec.yaml` (`X.Y.Z`) que Rubén
   tiene que ver en login/sidebar/perfil ANTES de testear + correr el GATE de
   build fresco (`TESTING.md` §0.0): cerrar instancias viejas, recompilar, NO
   confiar en el timestamp del `.exe` (mirar `data/app.so`). Sin esto se testea
   la app instalada vieja y un bug-fantasma de código-viejo se diagnostica como
   bug de sync/código (pasó el 2026-06-17: se testeó v0.11.9 instalada).
2. **Rol/identidad de prueba:** con qué rol se prueba cada feature gateado y si
   aplica o no IMPERSONANDO. Las features atribuidas al usuario que las ejecuta
   (visitas, pagos, recibos, cambios auditados) están bloqueadas/ocultas al
   impersonar por diseño y se prueban con la identidad REAL del rol — NUNCA
   impersonando (detalle en `TESTING.md` §0.3.0). Probar bajo el rol equivocado
   hace pasar por bug lo que es un gate intencional (pasó con "Registrar visita").

**Fase 6 — Cierre (OBLIGATORIO, no saltear):**
1. **Actualizar `BITACORA.md`**: bloque ESTADO ACTUAL + entrada nueva arriba
   (qué se pidió/por qué/qué se hizo/commits/pendientes).
2. Si cambió un módulo/tabla/setting/conexión → **actualizar
   `ARQUITECTURA.md`** (sección del módulo y/o recetas).
3. Si cambió misión/roles/stack → `PRODUCTO.md`.
4. Si hay flujo de testing nuevo → `TESTING.md` §0.3.
> Sin este cierre, la próxima sesión arranca a ciegas. Documentar toma
> minutos; no hacerlo cuesta horas.

**NUNCA saltar fases.**

## Checklist de audit obligatorio (post-implementación)

**1. SQL SQLite vs Postgres (CRÍTICO, scope: TODO el codebase):**
   - `grep -rn 'FILTER' lib/ --include="*.dart"` → 0 `FILTER (WHERE ...)`.
   - `::text/::int/::uuid/::jsonb`, `RETURNING`, `ILIKE`, `ANY(`, `ARRAY[`
     → 0 en `lib/` (son Postgres-only; SQLite usa `CAST`, `SUM(CASE WHEN…)`).

**1b. Zona horaria / día local (CRÍTICO — norma general):**
   - Lógica de LÍMITE DE DÍA (vencidas/mora/gracia/"hoy"/rangos/conteos) usa
     SIEMPRE `date('now','-6 hours')` y `julianday('now','-6 hours')` — NUNCA
     `date('now')` pelado (SQLite es UTC; el negocio es Nicaragua UTC-6 sin
     DST). Aplica a TODO módulo actual y futuro.
   - Server-side: NO cambiar el timezone global de la DB. Funciones con
     lógica de día → `SET timezone = 'America/Managua'` (patrón 0087).
     Crons a medianoche Nicaragua = 06:05 UTC.
   - Convención de timestamps: `ocurrido_en`/`aplicado_en`/`anulada_en` en
     **UTC** (`.toUtc()`); `fecha_pago` y `tickets.created_at` **local-naive
     A PROPÓSITO** (su wall-clock sostiene el bucketing por `date()` — NO
     normalizarlos sin migrar los cortes). El SLA parsea `created_at` con
     `parseTicketWallClock`.

**1c. Anclaje del período / prorrateo (CRÍTICO — regla nueva, bug 2026-06-16):**
   auditar SIEMPRE el SUPUESTO del modelo de período, no solo que la aritmética
   cierre. Toda lógica que prorratee o clasifique servicio (suspensión, cambio
   de fecha, "qué cubre esta cuota a la fecha X") debe anclar a la **ventana de
   servicio del `dia_pago`** (`ventanaServicio`/`estadoServicio`, ver
   `ARQUITECTURA.md` §3.5), NUNCA al **mes calendario** (`DateTime(y,m,1)`,
   `date(periodo)=date(mesX)`). Probar con `dia_pago ≠ 1` (el caso normal) —
   con `dia_pago = 1` el bug es invisible. Los audits previos verificaron
   fórmulas/SQL pero tomaron el ancla como dada → así se escapó el sub-cobro.

**1d. Case-folding no-ASCII en SQLite (CRÍTICO — regla nueva, bug 2026-06-22):**
   `lower()`/`upper()` de SQLite son **ASCII-only** — NO minusculizan `Ñ` ni
   vocales acentuadas (á,é,í,ó,ú,ü), a diferencia de Postgres y de Dart
   `String.toLowerCase()` (que sí son unicode). Toda comparación, búsqueda o
   matcheo **case-insensitive** contra un campo que pueda contener ñ/acentos
   (códigos, nombres, cédulas, cualquier texto en español) DEBE plegar AMBOS
   lados a forma canónica ASCII con **`foldBusqueda`** (Dart) + **`foldSqlExpr`**
   (SQL), de `data/utils/busqueda_cliente.dart` — NUNCA `lower()`/`upper()`/
   `toLowerCase()` pelado. Es un **falso negativo silencioso** (no tira error,
   solo no encuentra). Grep de regresión: `lower(`/`upper(` en SQL y
   `toLowerCase(`/`toUpperCase(` en código de búsqueda/match/unicidad → cada hit
   sobre texto español, plegado o justificado.
   **Regla de rango ampliado:** cuando un cambio AMPLÍA el set de caracteres
   válidos de una columna (p.ej. habilitar ñ en un `inputFormatters`/validador),
   auditar TODOS los consumidores que leen/comparan/normalizan/buscan esa
   columna (`grep -rn 'columna' lib/`) — habilitar la ENTRADA sin arreglar la
   BÚSQUEDA deja al registro **invisible**. **Probar con dato NO-ASCII** (un
   código con ñ): con ASCII puro el bug no aparece (igual que 1c con
   `dia_pago = 1`). Así se escapó v0.13.3: habilitó tipear la ñ pero no auditó
   la búsqueda downstream.

**2. Stream lifecycle Riverpod:** `ConsumerStatefulWidget` + `ref.watch` en
   build + stream creado en `initState` → el stream vive en `late final` /
   `_buildStream()` / provider (o `.asBroadcastStream()`). Sin `ps.db.watch`
   inline en build de Consumers (excepción documentada: `geo_picker`).

**3. Regresión full-codebase:** el audit NO se limita a lo modificado.
   Grep de patrones rotos conocidos (SQL incompatible, imports rotos,
   columnas droppeadas, providers huérfanos).

**4. Cadena de integridad ampliada:** toda query del codebase que toque las
   tablas modificadas (`grep -rn 'tabla' lib/`).

**5. Rutas GoRouter completas:** cada `context.push/go` debe existir en
   `router.dart` (ambas variantes de los paths condicionales
   `enAdminShell ? '/admin/x' : '/x'`).

**6. Denormalización en INSERTs:** columnas denormalizadas (`cobrador_id`)
   SIEMPRE en el INSERT desde Dart (los triggers no corren en SQLite).

**7. Prohibido `showDialog` como indicador de carga (CRÍTICO):**
   - NUNCA usar `showDialog` para mostrar un loading/spinner efímero. Si la
     operación async falla y `Navigator.pop(context)` no se ejecuta (o el
     `context` apunta al navigator equivocado con GoRouter), la barrera del
     diálogo queda permanente → **pantalla negra sin salida** para el usuario.
   - **Patrón correcto**: flag de estado interno (`_isLoading`) + overlay
     condicional en el `Stack` del widget (`if (_isLoading) Positioned.fill(…)`).
     Se limpia con `setState` en el `finally`/`catch`, sin depender de
     navigators. Ejemplo canónico: `mapa_screen.dart` → `_isCalculatingRoute`.
   - Excepciones válidas: diálogos de CONFIRMACIÓN del usuario (aceptar/cancelar)
     donde `showDialog` es el patrón correcto (el usuario los cierra).

**8. `Navigator.pop(context)` + GoRouter (CRÍTICO):**
   - `Navigator.pop(context)` busca el navigator más cercano al `context`
     pasado. Con GoRouter (navigators anidados), el `context` del State puede
     NO corresponder al navigator que contiene el diálogo/sheet — el pop
     cierra la pantalla equivocada o falla silenciosamente.
   - Toda llamada a `Navigator.pop(context)` que cierre algo abierto con
     `showDialog`/`showModalBottomSheet` debe usar el `context` del `builder`
     del diálogo, NO el del State externo. O mejor: evitar el patrón por
     completo (ver punto 7).

**9. Manejo de errores en flujos async (UI stuck):**
   - Todo nuevo flujo async que modifique la UI (loading, overlay, diálogo)
     debe verificar: **¿qué pasa si lanza excepción?** ¿Queda un loading
     infinito? ¿Queda un diálogo abierto? ¿Queda la pantalla inutilizable?
   - Usar `try/catch/finally` con cleanup garantizado en `finally` (o en el
     `catch` + después del `if` de éxito).
   - Verificar `mounted` antes de cada `setState`/`Navigator.pop` post-await.

**10. Selección única / dropdowns (CRÍTICO — bug 2026-06-26):**
   - Un `DropdownButton`/`DropdownButtonFormField` alimentado por una lista de la
     DB (items de `ps.db.watch`/`getAll`) **DENTRO de un diálogo** (`showDialog`/
     sheet/`AlertDialog`) **NO commitea su `onChanged`**: el menú-overlay
     `_DropdownRoute` anida mal sobre el overlay del diálogo → el valor mostrado
     cambia pero el estado del padre queda null y la validación falla. Confirmado
     en vivo: los de **pantalla full-screen** y los de **enum estático** SÍ
     commitean (incluso en diálogo); solo rompe **lista-DB + diálogo**.
   - **Regla uniforme de selección:**
     - **Selección única de lista DB** (producto, cliente, plan, cobrador,
       ubicación, nodo, técnico, categoría…) → **`SelectorBuscable`**
       (`elegirConBuscador` de `lib/features/shared/widgets/selector_buscable.dart`):
       campo `TextField` read-only + `onTap` que hace `getAll` y abre un diálogo
       con **buscador en vivo** (`foldBusqueda`, acentos/ñ, regla #1d). Escala a
       miles. **NUNCA** un `DropdownButton(FormField)` con items de stream/getAll.
     - **Enum fijo** (≤8 opciones const: tipo, prioridad, rol, método de pago,
       día…) → `DropdownButton(FormField)` está OK (commitea; no necesita
       búsqueda). El `SelectorBuscable` **muestra SIEMPRE el buscador** (cambio
       2026-06-27 — las listas DB crecen y el typing tokenizado debe estar siempre;
       antes se auto-ocultaba en ≤8). Autofocus solo en listas largas (>8): en
       cortas el box está visible pero sin robar foco (tocás un ítem sin que salte
       el teclado en Android).
     - **Filtro multi-selección** (estado, categoría, zona en listas) →
       `FiltroMultiDropdown` (no se toca).
   - **Toda** búsqueda/filtro de texto pliega ambos lados con `foldBusqueda`/
     `foldSqlExpr` (encontrar con o sin tildes/ñ — regla #1d, universal).
   - **Búsqueda por TOKENS (2026-06-27):** toda búsqueda de texto libre matchea
     **palabra por palabra, en cualquier orden** (cada token debe aparecer; todos
     deben estar) — "maria ruiz" encuentra "María Luisa Peña Ruíz". Helpers en
     `data/utils/busqueda_cliente.dart`: **`coincideTokens(target, query)`**
     (client-side), **`foldSqlTokens(col, query)`** (SQL 1 columna), y
     `busquedaClienteSql`/`busquedaClienteMatch` (multi-campo). NUNCA un
     `.contains(foldBusqueda(q))` pelado (eso exige substring contiguo: "maria
     ruiz" no matchearía). `tokensBusqueda(q)` parte+pliega; query vacía = no filtra.
   - Patrón + ejemplos: `inv_stock_flows.dart` (`_IngresoDialogState`) y los ~15
     selectores migrados (catálogo, tickets, incidentes, contratos, clientes,
     red/geo pickers). El selector de "ninguno/opcional" usa una `OpcionSelector`
     centinela (no `valor: null`, que se confunde con cancelar).

**11. `Row` con `crossAxisAlignment.stretch` dentro de scroll (CRÍTICO — bug
   2026-06-27):** un `Row` con `crossAxisAlignment: CrossAxisAlignment.stretch`
   adentro de un `SingleChildScrollView` (o cualquier contexto de altura ilimitada)
   reclama **altura INFINITA** (el eje cruzado es vertical y el scroll no le pone
   cota) → empuja TODO lo que va DESPUÉS al vacío: se renderiza pero a `y=∞`,
   invisible e inalcanzable por scroll. **Fix: envolver el `Row` en
   `IntrinsicHeight`** (altura = la del hijo más alto; el stretch entonces iguala
   alturas bien). NO lo cazan `flutter analyze` ni los tests (es layout en runtime)
   — solo el render en vivo. Grep de regresión: `CrossAxisAlignment.stretch` en un
   `Row` que viva dentro de un scroll → debe tener `IntrinsicHeight` arriba. Pasó
   con el diálogo de cambio de plan y el detalle de pago (las cajas "de→a" y "cómo
   pagó/estado" tapaban toda la sección de abajo).

**12. `push` a una ruta del ShellRoute admin (CRÍTICO — bug 2026-06-30, mordió
   2 veces):** abrir una pantalla que vive DENTRO del `AdminShell` (chrome
   heredado, sin Scaffold propio) con `context.push` rompe el botón de volver del
   shell. Razón: `push` NO reconstruye el shell → su `GoRouterState.matchedLocation`
   sigue apuntando a la ruta PADRE, así que `_tituloFor`/`_backTargetFor`
   (`admin_shell.dart`) se calculan contra el padre. Si la pantalla se pushea
   **desde `/admin` (el home)**, `_backTargetFor('/admin')=null` → **NO hay botón de
   volver** → el usuario queda trabado (pasó con el Centro vía "Abrir centro"). Si se
   pushea desde otro padre, no se traba pero muestra el título/destino del PADRE
   (quirk: el Catálogo pusheado desde `/admin/inventario` titula "Inventario").
   **Regla: las rutas del shell admin se NAVEGAN con `context.go`, NUNCA `push`**
   (los cards de la galería ya usan `go`). `push` queda SOLO para detalle/form con
   guard de `_hasFormGuard` (clientes/contratos → su back hace `Navigator.maybePop`,
   que sí popea). Grep de regresión: `context.push('/admin/...` sobre una ruta del
   ShellRoute que NO sea `clientes/`/`contratos/` → debe ser `go`. NO lo cazan
   analyze ni tests (es comportamiento de runtime de go_router) — solo el uso en vivo.

### Formato obligatorio del reporte de audit
```
## REPORTE DE AUDIT — [nombre]
### Metodología (agentes, scope, archivos)
### Findings que requieren fix
| # | Severidad | Archivo:línea | Problema | Impacto en usuario |
(por finding: quién lo encontró · código antes · escenario real · código después)
### Clean — sin problemas (tabla por categoría)
### Backlog (no bloquea)
```
El reporte se presenta ANTES del pull/testing. Sin reporte, el sprint no está
auditado.

## Modelo de testing de 4 capas

| Capa | Qué | Cuándo |
|---|---|---|
| 1. Audit estático | agentes leen código (sintaxis/SQL/RLS/imports) | post-implementación |
| 2. Invariantes SQL | `invariantes_dinero.sql` contra data real | tras cada deploy que toque dinero |
| 3. Tests de repo | `flutter test` (suite `pagos_repo` + unit) | cada cambio + CI |
| 4. Manual (Rubén) | escenarios reales en la app | antes de cerrar sprint |

**Regla:** cambios de dinero pasan por 1+2+3 antes del manual.

## Principio de diseño: evaluar ANTES de implementar

Antes de elegir herramienta/servicio para algo nuevo: ¿se resuelve con el
stack existente? ¿agrega pasos manuales al workflow? ¿tiene límites
conocidos? ¿cómo se ve end-to-end para el usuario? Elegir lo más simple y
documentar el trade-off en el commit.

---

## Acceso del AI a la máquina y servicios (vale para TODA sesión)

> **Confirmado por Rubén (2026-06-18). Tener en cuenta en CADA ventana de sesión:**
> el AI **opera la PC local directamente** — corre comandos **PowerShell**
> (build, git, tests, etc.) sin pedir permiso paso a paso. Acceso ya configurado:
> - **GitHub:** `gh` autenticado (rubenmaltez, scopes repo/workflow) → branches,
>   push, PRs, releases los hace el AI. **No** hace falta que Rubén copie/pegue.
> - **Supabase (`vxxzesbmilfolwjhfxgr`, "Template TT"):** `supabase db query --linked`
>   → el AI **corre migraciones y SQL** y los **verifica** él mismo (sin copy-paste al
>   Dashboard). ⚠️ **OJO — este proyecto ES PRODUCCIÓN** (confirmado por Rubén
>   2026-06-20): es a donde apunta el `.env.json` del release y se conectan los usuarios
>   reales. El AGENTS lo llamaba "DEV" por ERROR. Sirve dev/testing Y producción a la
>   vez → tratá CADA cambio (migración, UPDATE, borrar data) como producción: cuidá,
>   verificá antes, y corré `invariantes_dinero.sql` tras tocar plata. (Existe un 2º
>   proyecto `scqxraueqtbsgzkjzoyk` "TT's Project" — propósito sin confirmar; NO es a
>   donde apunta el release.)
> - **PowerSync SELF-HOST (desde 2026-07-13 — el cloud de paga se retiró):** el sync
>   corre en un **VPS Hetzner** (`https://65-109-1-217.sslip.io`; SSH
>   `ssh -i ~/.ssh/hetzner_powersync root@65.109.1.217`). El AI lo opera por SSH
>   (Docker). Detalle completo en **ARQUITECTURA §3.8** + memoria
>   `powersync-selfhost-hetzner`.
> - **Sync Rules — ahora las despliega el AI por SSH (ya NO por "Dashboard de
>   PowerSync"):** editar `/opt/powersync/config/sync-config.yaml` en el VPS (fuente
>   DRY en `powersync/sync-rules.yaml`) + `docker compose restart powersync`. Sin
>   clipboard, sin "Active", sin Rubén.
> - **Deploy ordenado (release):** como `vxxz` ES la base live, el "deploy a PROD" =
>   migraciones contra `vxxz` (+ sync rules al VPS si cambiaron), SIEMPRE **antes** del
>   `build-release.ps1` (que dispara el auto-update). No hay una 2ª base PROD aparte.

## Cómo deployar

### Migración SQL — base linkeada (vxxz = PRODUCCIÓN; el AI la corre y verifica)
- Correr: `supabase db query --linked -f supabase\migrations\NNNN_*.sql` (vxxz
  linkeado — ES producción, tratar como tal). **OJO con flags:** `-o`/`--output` choca con el flag global; usar el
  default o `--output-format`. Las funciones (`CREATE OR REPLACE`) son idempotentes
  → re-correr una función suelta para patchear es seguro; **no** re-correr una
  migración con `CREATE TABLE` (falla "already exists") — para eso, nueva migración.
- **`CREATE OR REPLACE` de una función ACUMULATIVA** (la que se va extendiendo —
  ej. `tenants_seed_settings_trg()`): partí SIEMPRE de la **ÚLTIMA definición
  vigente** (`grep` del último `CREATE OR REPLACE` de esa función en
  `migrations/`), NUNCA de la que el comentario recuerde. Lección 0151→0152: 0151
  reescribió el trigger de seed desde el cuerpo VIEJO de 0134 y **perdió 5
  `perform`** de seed (0135-0145) → los tenants NUEVOS nacían sin esos settings
  (los 3 vivos no se afectaron). Lo cazó el audit de regresión, no los tests; 0152
  repuso el cuerpo completo. Es REGRESIÓN silenciosa: `CREATE OR REPLACE` no avisa
  que dropeaste llamadas.
- **NUNCA asumir que corrió — verificar con query** (`information_schema.columns` /
  `pg_tables` / `pg_trigger`; para regclass comparar por OID `'tabla'::regclass`).
- **PROD / opción manual:** `Get-Content ...sql -Raw | Set-Clipboard` → Dashboard →
  SQL Editor → Run → `Success`. (Solo PROD, o si Rubén lo pide.)

### Edge Function
1. `Get-Content supabase\functions\NOMBRE\index.ts -Raw | Set-Clipboard`
2. Dashboard → Edge Functions → función → tab Code → reemplazar → Deploy
   updates → verificar "a few seconds ago".
3. **`_shared/*.ts`**: el editor del Dashboard tiene árbol FILES con los
   `_shared` bundleados — editables ahí. OJO: cada función es un bundle
   independiente → cambiar un `_shared` exige repetir edit+deploy EN CADA
   función que lo importa (`passwords.ts` → crear-tenant, invitar-cobrador,
   reenviar-invitacion). El repo es la fuente de verdad DRY.

### Checklist al agregar columna/tabla
Ver ARQUITECTURA **Receta R4** (columna) y **R10** (tabla). Resumen:
migración corrida y VERIFICADA → schema.dart → sync rules al VPS (editar
`sync-config.yaml` + `docker compose restart powersync`) → Dart consistente → app
desde cero. **NO se bumpea `_dbWipeVersion`** para
aditivos (columna/tabla/índice): PowerSync los aplica in-place sin re-descargar;
el bump se reserva para cambios destructivos (política en R4, fix #1).

### Build / release de la app
**`Install Steps/1-Publicar-nueva-version.md`** (bump de versión en
`pubspec.yaml` → migraciones → `Install Steps\build-release.ps1 -AllTenants`).
Tras cualquier cambio mergeado que Rubén quiera distribuir, guiarlo ahí.
**Nombres de assets (desde v0.18.3):** los instaladores salen **branded +
versionados** por ISP (`config.releaseName`: `Telecable-Mairena-CRM-vX.Y.Z.{msix,apk}`,
`Telenet-CRM-vX.Y.Z.{msix,apk}`). El nombre FIJO es el **manifest**
`version-<slug>.json` (lo que el app pide); apunta al instalador branded vía
`download_url`. Quien descargue por URL estable (auto-update, `install-*.ps1`)
debe leer el manifest, NUNCA hardcodear el nombre del instalador. **Dos canales:**
`sitecsa-updates` (público, el que usan las apps) + `Template-TT` (puente privado,
por continuidad; 404 anónimo por privado). Política: al publicar, borrar el
release/tag anterior (`gh release delete vX --cleanup-tag`) — solo el vigente.

---

## Git / branching (modelo desde 2026-06-09)

- **`main` es la ÚNICA rama permanente** y la default del repo. Siempre
  refleja el último estado estable/auditado.
- Cada sesión de trabajo desarrolla en una **rama efímera creada desde
  `main`** (la que asigne el entorno, p.ej. `claude/*`). Al cerrar el
  trabajo aprobado: **merge a `main` y BORRAR la rama** — no acumular ramas.
- **Hitos/checkpoints = TAGS, nunca ramas** (`git tag <nombre>` + push del
  tag). Política de limpieza (decisión Rubén 2026-06-12): en GitHub se
  conserva SOLO el tag/release de la versión vigente — al publicar una
  versión nueva se borran el release y el tag anteriores
  (`gh release delete vX --cleanup-tag`). Los checkpoints `pre-mvp-v1/v2`
  fueron eliminados (el historial de `main` los contiene igual).
- No reescribir historia de `main` (sin force-push).

## Reglas de comunicación con Rubén

- Pasos detallados, **un comando por vez** cuando el output importa, con
  output esperado al lado y verificación explícita antes de avanzar.
- NO asumir confirmación; pedirla después de cada sub-paso.
- Mismo error 2 veces → FRENAR y diagnosticar, no repetir instrucciones.
- Decisiones técnicas → tabla de pros/cons, recomendar honestamente, dejarlo
  elegir.
- **Trabajo VISUAL-FIRST (confirmado por Rubén 2026-06-15 — acelera el
  desarrollo y evita retrabajo):**
  - **Cambios de UI/UX → mockup visual al proponer, no solo texto.** Para
    rediseños de pantalla, nuevos componentes, cambios de layout o de recibo,
    renderizar un **mockup** (herramienta de visualización) que muestre cómo va
    a quedar, ANTES de implementar. Rubén decide mejor viendo el diseño.
  - **Explicar flujos/lógica con ramificaciones** (escenarios, decisiones,
    árboles) → usar un **diagrama** visual, no solo prosa.
  - **Siempre consultar antes de implementar** (Fase 2) y, si ayuda al contexto
    del pedido, **dar ejemplos visuales/diagramas**. Es la forma de trabajo
    preferida — no la saltees aunque parezca obvio.
- Idioma: español rioplatense (vos). Strings de UI 100% español. Commits en
  español, primera línea ≤72 chars, sin co-authored-by ni firmas.

---

## Backlog y estado

El backlog vivo y el estado actual viven en **`BITACORA.md`** (§ESTADO ACTUAL
y §Backlog vivo). No re-flagear en audits lo que figure ahí como resuelto o
aceptado. Los ítems parqueados por decisión de Rubén: flags
`modo_ruta`/`caja_chica` (ocultos) · geo del cobro · Resend/dominio.
