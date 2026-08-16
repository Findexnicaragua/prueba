# CHANGELOG-REWORK — Diseño y plan

> Branch `changelog-rework` (desde `main` @ `be7bac2`). Dirección y decisiones
> aprobadas por Rubén (2026-06-19). Documento vivo: se actualiza por fase.
> Investigación + diseño + verificación adversarial: workflow `changelog-rework-diseno`.

## Progreso de implementación

> Sesión 2026-06-20: TODO verificado **en vivo** (build MSIX v0.11.10 local, contra
> DEV; **PROD intacto**, sin release). Test tenant "Test Mairena" con 1 cliente demo.

- ✅ **Fase 0 — Infra:** tabla `op_log` (mig 0128 + **0129** `diff`→`text` + policy
  UPDATE), helper `OpLog`/`diffVisible`/`OpLogActor`, `schema.dart`, sync rules
  (Active). Test offline. Test tenant limpiado a 0.
- ✅ **Fase 1 (cobros):** `registrarCobro`/`registrarCobroMultiple`/`anularPago`
  emiten `op_log` por objeto. Resumen del cobro COMPLETO: monto, entregado, vuelto,
  método, fecha del cobro, **notas**, recibo. Suite `pagos_repo` 57 verde.
- ✅ **Fase 2 — UI + panel (A+B):**
  - `HistorialOpLog`: 1 entrada por intención, fecha/hora AM/PM + actor, desplegable
    antes→después; oculta lo vacío (vuelto 0, entregado=aplicado, notas vacía).
  - Cableado en la cuota (`contrato_detail_cuotas/_pagos`). Verificado en vivo: cobro,
    anulación (timeline append-only), cobro con vuelto, cobro con **notas**.
  - **Panel `OpLogCamposScreen`** (super_admin → Config → Avanzado → "Campos del
    historial"): **por ENTIDAD** (reusa `kAuditCamposCatalogo`: clientes, contratos,
    cuotas, pagos, red, inventario/equipos, tickets…) con **chips-toggle** del mockup;
    guarda el setting `op_log.campos_visibles`. El render aplica el override en vivo
    (`appSettings.opLogCamposOverride`). Verificado: apagar "Vuelto" → desaparece.
  - **Crédito excedente** movido de Cobranza→Otros a la tab **Avanzado** (super_admin).
- ✅ **Fase 1b (compuestas de `pagos_repo`):** `editarPago` y `registrarCambioFecha`
  emiten `op_log`. **editarPago** (param nuevo `editadoPorId`): 1 entrada `edicion_pago`
  en la cuota (monto/método/notas antes→después + estado/saldo si cambió el monto;
  recibo en el resumen; no loguea si nada cambió). **registrarCambioFecha** (per-objeto,
  mismo `op_id`): contrato (día_pago/fecha_fin) + cuota host (cobro del puente) + cada
  absorbida (→anulada) + cada re-fechada (nueva venc, skip si no cambió) + cada cuota de
  cierre (alta). La entrada del CONTRATO se **captura ya**; su historial se cablea en
  Fase 3. Render: verbo `edicion_pago`, `_fmtValor` para método/fechas, `monto` +
  `fecha_vencimiento` sumados a la allowlist de `cuotas`.
  **Audit Fase 4 adversarial (22 agentes, 18 crudos → 5 reales):** atomicidad OK
  (op_log additivo, no toca dinero). FIXES aplicados: (a) `monto` en el resumen salía
  crudo ("500.0") y duplicaba el título de cobro/anulación → case en `_fmtResumen` +
  `_montoOcultoEnResumen` (no duplica en cobro/cobro_multiple/anulacion; `edicion_pago`
  lo muestra como CAMPO y `cambio_fecha` el puente); (b) host "al día" emitía campos
  no-op (pagada→pagada, 0→0) → campos condicionales (la entrada igual va por su resumen);
  (c) `editarPago` desde `/historial` sin guard de impersonación + `_opLogActor` filtraba
  el nombre REAL del super_admin → guard agregado + `_opLogActor` registra al super_admin
  como **"System Admin"** (lee `rol`→`systemAdmin`, diseño 0128). Suite `pagos_repo`
  **61 verde** · analyze limpio.
- ✅ **Fase 3a (`contratos_repo`):** las 7 funciones mutantes (`suspender`/`cancelar`/
  `reactivar`/`revertirSuspension`/`revertirCancelacion`/`aplicarCredito`/
  `registrarDisposicionExcedente`) emiten `op_log` per-objeto (contrato + cada cuota,
  mismo `op_id`). Actor centralizado en `OpLog.actorDeUsuario` (super_admin = "System
  Admin"); `pagos_repo._opLogActor` delega ahí. Render: verbos `revertir_suspension`/
  `revertir_cancelacion`/`aplicar_credito`/`disposicion_excedente`. **Historial del
  CONTRATO cableado** a `HistorialOpLog(entidad:'contratos')` (reemplaza
  `HistorialContratoWidget`/audit_log). **Audit Fase 4 (22 agentes, 18 crudos → 8, 7
  bajas + 1 media):** fix de la media — el dropdown del header (`activo`/`completado`)
  hacía un `UPDATE` directo sin log → tras recablear el historial quedaba invisible →
  nuevo `ContratosRepo.cambiarEstadoSimple` (UPDATE + op_log `edicion_entidad`). Suite
  `pagos_repo` **64 verde** · analyze limpio. **Decisiones (Rubén):** historia vieja =
  op_log limpio desde el corte (audit_log queda forense); settings = migran a op_log.
  Backlog menor: `disposicion_excedente` no expande detalle (monto/motivo en título/
  subtítulo); `HistorialContratoWidget` queda muerto hasta 3c.
- ✅ **Fase 3b — edición simple de entidades (decisión Rubén: "todo de una"):** ~50 sitios
  CRUD emiten `op_log` dentro de su `writeTransaction` (patrón: leer fila ANTES con
  `SELECT *`, mutar, leer DESPUÉS, `OpLog.escribirCambioEntidad`/`escribirBaja`; diff curado
  por allowlist; actor `OpLog.actorDeUsuario`). Cubre: clientes, planes, cobradores (update
  local; rol queda en RPC forense), red (nodos/hubs/puertos), geografía
  (deptos/municipios/comunidades), inventario (productos/ubicaciones/proveedores/categorías/
  **seriales + movimientos** como alta), tickets + sub-entidades (eventos/adjuntos/
  materiales/checklist/reasignación **scopeadas al ticket**), ticket_tipos, incidentes,
  etiquetas (catálogo) + **cliente_etiquetas scopeada al cliente**, visitas, y **settings**
  (`entidad='settings'`, diff por clave; actor "System Admin" si no se pasa `usuarioId`).
  Helper nuevo `OpLog.escribirBaja`; fix allowlist clientes (`direccion_referencia`,
  `puerto_id`). Implementado con clientes como patrón de referencia + 4 agentes en paralelo
  (archivos disjuntos). analyze limpio · **suite 357 verde**. Commits `917f76e` (clientes +
  helpers) + `766c0fb` (resto). **Audit Fase 4 (3 confirmados, misma raíz):** los eventos
  scopeados al ticket (checklist/incidente/comentario/reasignación/material/adjunto)
  ponían el texto en `diff.campos` con keys fuera de la allowlist de `tickets` → el render
  los dejaba invisibles. **Fix (`5001467`):** movidos a `resumen.motivo` (que sí se ve en
  el subtítulo, como `cliente_etiquetas`). El resto (escribirCambioEntidad con columnas
  reales) renderiza bien. Atomicidad/orden/entidad_id OK.
- ✅ **Fase 3c — cortar `audit_log` de la UI:** los ~11 `Historial*Widget` (simples +
  agregadores cliente/serial/ticket) reemplazados por `HistorialOpLog(entidad, entidadId)`
  en 9 pantallas; `pagos_admin` apunta a la **cuota** del pago (op_log no tiene
  `entidad='pagos'`). Borrado `historial_cambios_widget.dart` (muerto). `audit_log` queda
  **forense** (trigger server intacto + `AuditAdminScreen` sin tocar). analyze limpio ·
  suite **357 verde**. Commit `56eeed4`.

- ✅ **Testeo en vivo (2026-06-20, build MSIX local v0.11.10 vs DEV, admin real "Ruby
  Admin"):** verificado — (a) `HistorialOpLog` renderiza (estado vacío "Sin movimientos" +
  entradas expandibles); (b) **3b** edición de cliente → entrada `edicion_entidad` con
  `Teléfono 88888886 → 88887777` y `Direccion referencia — → Casa azul…`, actor real,
  fecha-hora AM/PM; (c) **3a** cambio de estado del contrato Activo→Completado→Activo
  (`cambiarEstadoSimple`) → `Estado: Activo → Completado` en el historial del contrato;
  (d) cuota pagada pre-corte → "Sin movimientos" (correcto, limpio desde el corte).
  **2 fixes del testeo:** `kAuditCamposCatalogo['clientes']` también debía usar
  `direccion_referencia` + `puerto_id` (commit `14590b6`); y se limpió un **override stale**
  de DEV (`op_log.campos_visibles`).
- ⚠️ **Backlog (no bloquea) — override del panel congela el catálogo:** el panel super_admin
  guarda `op_log.campos_visibles` como **snapshot completo** del catálogo. Si después se
  agregan campos (lo que hizo este rework: `monto`/`fecha_vencimiento` en cuotas,
  `direccion_referencia`/`puerto_id` en clientes), un override pre-existente los **oculta**
  hasta re-guardar el panel. Sin override (caso normal de un tenant) se ven por default.
  Mejora futura: que el override guarde el set OCULTO (no el visible), o que campos nuevos
  no listados se traten como visibles. Hoy se mitiga re-guardando el panel.

> **Rework COMPLETO de punta a punta** (Fases 0/1/1b/2/3a/3b/3c) + testeo en vivo OK. Todo
> en op_log; `audit_log` es forense. Pendiente: merge a `main` + build/release.

### Feature paralela de esta rama: rediseño de FILTROS (no es op_log)

Componente único `FiltroMultiDropdown` (búsqueda + multi-selección + jerarquía
municipio→comunidad + detección "todos→`null`"=sin filtrar + aplica al instante).
Reemplaza `DropdownFiltro` (single-select). Cableado y **verificado en vivo** en las
**3 pantallas**: Cobros (SQL `= ?`→`IN`, `cobros_query.dart`, 9/9 test), Mapa
(client-side `.where` con `.contains`), Clientes-admin (3 chips propios reescritos).
350 tests verde. `DropdownFiltro` queda muerto (cleanup futuro).

### Otras features de esta rama (pedidos de Rubén 2026-06-20, no es op_log)

- ✅ **Email opcional del cliente (`0130`, commit `08e4228`):** campo de contacto opcional
  en información personal. Migración `0130` (`ALTER TABLE clientes ADD email`; sync rules
  `SELECT *` → automático, sin tocar). schema.dart + modelo `Cliente` + form (con
  `Validators.email`, opcional) + detalle (`_row`) + allowlist op_log (Visibles + Catálogo;
  label ya existía). Patrón espejado de cédula. **Verificado en vivo:** alta del email → se
  ve en el detalle y en el historial ("Email: — → demo@cliente.com").
- ✅ **Panel lateral → galería de inicio (estilo A, commit `0e0cf7d`):** el rail/drawer se
  reemplazó por una galería de cards con ícono de color por sección (`MenuGaleriaScreen` en
  `/admin`). El dashboard pasó a `/admin/resumen` (card más); "Administración" abre una
  sub-galería (`/admin/administracion`); el avatar de la barra superior despliega nombre/rol
  + Cambiar contraseña + Cerrar sesión + versión; cada sección abre con "← Menú". Reusa el
  filtrado por rol/módulo/setting + badges Tickets/Inventario. Removidos `_AdminRail`/
  `_AdminDrawer`/`_TopBar`/`_ExpandableMenuItem`/`_UserHeader`. **Verificado en vivo** (build
  MSIX v0.11.10): galería, sub-galería, back-a-menú, navegación, avatar.

> **Deploy a PROD (orden):** ahora la cadena de migraciones incluye `0128`/`0129` (op_log) +
> `0130` (email). El build/release sigue gateado al deploy en orden.

### ⚠️ Dos gotchas encontrados en testing en vivo (migración 0129)

**(1) `diff` jsonb → doble-encode.** El cliente PowerSync guarda `diff` como STRING
de texto JSON (`jsonEncode`). Al subirlo a una columna **`jsonb`** vía PostgREST,
Postgres lo mete como **jsonb-string** (`jsonb_typeof='string'`), no como objeto →
queda doble-encodeado en TODOS lados. **Fix raíz: `diff` debe ser `text`** (el schema
local ya lo es); así el round-trip es identidad y un `jsonDecode` alcanza. Defensa
extra en el render: `_decodeDiff` decodifica en bucle hasta obtener un Map (sirve para
data vieja doble-encodeada). Commits `d4bff90` (render) + `0129` (columna).

**(2) `upsert` sin policy UPDATE → 42501.** El conector (`powersync/connector.dart`)
sube cada cambio con `supabase.upsert` = `INSERT ... ON CONFLICT DO UPDATE`. Una tabla
append-only SOLO con policy INSERT da **"rechazado por el servidor" (42501)** en el
primer reintento/conflicto (el path de UPDATE no tiene policy). **Fix: toda tabla que
el cliente escriba necesita policy UPDATE** (scopeada al dueño), aunque sea
"append-only" — el upsert reescribe la misma fila idempotentemente. El forense
inmutable real es `audit_log` (trigger server), no `op_log`. Regla nueva para R10.

---

## 0. Resumen en una frase

Reemplazar el change log actual (que loguea **por fila de base de datos** → una
intención del usuario se parte en N filas confusas) por un **log de INTENCIÓN
escrito por el cliente**: una entrada por **cada objeto afectado**, scoped a los
atributos de ESE objeto, dentro de la misma `writeTransaction` offline-first.
El trigger por-fila actual se conserva como **registro forense** (solo super_admin).

---

## 1. El problema (diagnóstico verificado)

El `audit_changelog_trg` (genérico, AFTER I/U/D por fila, migraciones 0047/0062/
0069/0116) escribe **una fila de `audit_log` por cada fila física que cambia**.
Como PowerSync sincroniza cada escritura de la `writeTransaction` del cliente como
una operación top-level (todas a `pg_trigger_depth()=1`, pasan el guard `<2`) y el
cliente **espeja** el recálculo del server, una sola intención explota:

- **Registrar un cobro** (`pagos_repo.registrarCobro`): INSERT pago + INSERT recibo
  + 2 UPDATE cuota (cargos_neto, monto_pagado/estado) + N cargos_extra ⇒ **~4-6
  filas** de log para UNA acción. Multi-cuota: **8-15 filas**.
- **Cambio de fecha / suspensión / cancelación**: **10-20 filas**.

El `pg_trigger_depth()<2` solo corta cascadas server de profundidad ≥2; NO unifica
writes top-level del cliente. **La intención solo se conoce en el CLIENTE**, en la
`writeTransaction` (offline-first: la app hace y espeja las escrituras; al
sincronizar, los triggers server quedan suprimidos por el depth-guard y la
auditoría ve todo plano). Esa semántica se pierde al cruzar el sync.

Hoy solo `HistorialCuotaWidget` agrupa, con una **ventana de 3 segundos** frágil
(matchea por `user_id` + proximidad temporal). Los otros 5 widgets muestran cada
fila suelta. Esa fragilidad heurística es justo lo que este rework elimina.

---

## 2. Requisitos (la visión de Rubén)

1. **Cada objeto tiene su propio historial**, con SUS atributos. Una acción a
   nivel contrato que afecta cuotas ⇒ una entrada en el contrato (atributos del
   contrato) **y** una entrada en **cada cuota** afectada (atributos de la cuota).
   La cuota **NO hereda** datos del contrato.
2. **Dentro de un objeto, una acción del usuario = UNA entrada** (no las 5 filas
   de hoy).
3. Captura **quién · cuándo (fecha + hora AM/PM) · qué cambió**.
4. **Creación**: solo los atributos visibles del formulario (no flags internos).
5. **Modificación**: solo lo que cambió, **antes → después**.
6. **super_admin** (impersonando o no): el actor se registra como **"System Admin"**.
7. Visible **solo para super_admin y admin** (se mantiene).
8. **Offline y online** por igual.
9. **Escalable y simple**: cualquier entidad creable/editable/eliminable —
   presente o futura — se engancha igual.
10. **Visualmente consistente** en toda la app, muy entendible.

---

## 3. Arquitectura

**Híbrido con sesgo a "log de intención en el cliente" + forense server.**

| Pieza | Qué es | Para qué |
|---|---|---|
| **`op_log`** (tabla nueva, PowerSync-synced, append-only) | El cliente escribe, dentro de la misma `writeTransaction` que muta los datos, **UNA fila por cada objeto afectado** por la intención. Todas comparten un `op_id` (generaliza el `grupo_cobro` existente), el mismo `actor` y `ocurrido_en`. Cada fila está **scoped** a su objeto (`entidad` + `entidad_id`) y lleva el diff de los atributos de ESE objeto. | El historial que ven admin/super_admin. Una entrada por objeto por acción. |
| **`tech_log`** (forense) | El `audit_changelog_trg` actual se **conserva** pero su salida va a un registro que **NO se sincroniza al cliente** y solo ve super_admin. (v1: dejar el trigger escribiendo a `audit_log` y simplemente **dejar de leerlo en la UI** — `audit_log` pasa a ser el forense de facto. Cero cambio de trigger.) | Rastro inviolable por-columna + fixes por SQL directo en prod, que la app nunca vería. |
| **`HistorialOpLog`** (un solo widget) | Mismo componente en TODA la app: `WHERE entidad=? AND entidad_id=? ORDER BY ocurrido_en DESC`. | Consistencia total. Desaparecen los 6 widgets, los agregadores, `kAuditCamposSuperficie`, las reglas de profundidad y la ventana-3s. |

**Por qué el cliente y no el trigger:** offline-first invierte el flujo. La app es
el único lugar donde "esto es UN cobro" existe como unidad atómica (la
`writeTransaction`). Escribir el log ahí es semánticamente correcto, no un parche
de re-agrupación. El `op_id` ata las entradas-por-objeto de una misma acción
(útil para forense y para "qué hizo esta acción en total").

---

## 4. Modelo de datos

```sql
CREATE TABLE op_log (
  id          uuid PRIMARY KEY,
  tenant_id   uuid NOT NULL,
  op_id       uuid NOT NULL,            -- agrupador de intención (generaliza grupo_cobro)
  tipo_op     text NOT NULL,            -- enum de acción (ver abajo)
  entidad     text NOT NULL,            -- objeto: 'cuotas'|'contratos'|'clientes'|'pagos'...
  entidad_id  uuid NOT NULL,            -- PK del objeto (para WHERE entidad_id=?)
  actor_id    uuid,                     -- usuario real de sesión (NULL si System Admin)
  actor_label text NOT NULL,            -- 'Ruby Admin' | 'María (cobradora)' | 'System Admin'
  accion      text NOT NULL,            -- 'create'|'update'|'delete' (para el verbo base)
  diff        jsonb NOT NULL,           -- {campos:[{campo,antes,despues}], resumen:{...}}
  ocurrido_en timestamptz NOT NULL,     -- device-time UTC (orden cronológico real)
  created_at  timestamptz DEFAULT now() -- server-time al sincronizar (desempate)
);
CREATE INDEX op_log_hist ON op_log (tenant_id, entidad, entidad_id, ocurrido_en DESC);
CREATE INDEX op_log_op   ON op_log (tenant_id, op_id);

-- RLS (mismo modelo append-only que audit_log 0020):
--   INSERT: WITH CHECK (current_tenant_id() = tenant_id)
--   SELECT: USING (current_tenant_id()=tenant_id AND is_admin_or_cobranza()) OR is_super_admin()
--   SIN UPDATE/DELETE.
```

**`tipo_op` (enum):** `cobro · cobro_multiple · anulacion_pago · edicion_pago ·
cambio_fecha · suspension · cancelacion · reactivacion · revertir_suspension ·
revertir_cancelacion · aplicar_credito · disposicion_excedente · alta_entidad ·
edicion_entidad · baja_entidad`.

**Formato del `diff`:**
```json
// Edición simple (teléfono):
{ "campos": [{"campo":"telefono","antes":"8888-1111","despues":"8888-2222"}] }
// Cobro (entrada de la cuota):
{ "campos":[{"campo":"estado","antes":"pendiente","despues":"pagada"},
            {"campo":"saldo","antes":500,"despues":0}],
  "resumen":{"monto":500,"recibo":"A-00042"} }
// Suspensión (entrada de UNA cuota afectada):
{ "campos":[{"campo":"monto","antes":500,"despues":280},
            {"campo":"estado","antes":"pendiente","despues":"anulada"}] }
```

**Schema/sync/wipe:**
- `op_log` se agrega a `lib/powersync/schema.dart` (como `audit_log`).
- Sync rules: `op_log` al bucket admin (mismo que `audit_log`: `todo_tenant_admin`,
  `todo_tenant_admin_cobranza`, `impersonated_tenant`). El cobrador **no la
  descarga** pero **sí la escribe** (verificado, §7). Redeploy lo hace Rubén.
- **NO se bumpea `_dbWipeVersion`** (tabla aditiva, in-place — política R4, fix #1).
- `audit_log` existente **se preserva** (append-only) como forense / archivo.

---

## 5. Reglas de negocio del log

- **Una entrada por objeto afectado.** El repo, dentro de su `writeTransaction`,
  emite un `op_log` por cada objeto que el usuario cambió, scoped a ese objeto.
  Comparten `op_id`, `actor`, `ocurrido_en`.
- **Diff scoped y curado en el cliente AL ESCRIBIR** (no al renderizar): se reusa
  la allowlist `kAuditCamposVisiblesDefault` + `kAuditSkipKeys` + value-labels
  (refactorizadas a un helper puro sin UI). El diff nace ya filtrado → se cierra
  el agujero del "fallback permisivo" (entidad no registrada ⇒ assert/no-log, no
  volcar columnas crudas).
- **El resumen se deriva de los MISMOS valores que se escriben** a las tablas
  (reusar `nuevoEstado`, el `snapshot` de suspensión que el repo ya arma), nunca
  recalcular — para que el log no "mienta".
- **Actor:**
  - cobrador/admin: `actor_id` = su uid, `actor_label` = su nombre.
  - **super_admin (impersonando o no): `actor_label` = "System Admin"**, `actor_id`
    = NULL (no es un usuario del tenant).
- **Anulaciones / revertir**: cada una es su PROPIA intención → su propio `op_log`
  con el efecto (cuota restaurada, recibo anulado). No N updates sueltos.
- **Borrado físico**: el `op_log` de la baja guarda el `entidad_id` + snapshot
  final en `diff` → el objeto borrado sigue apareciendo en su historial (filtra por
  `entidad_id`, no `IN(SELECT)`).

---

## 6. Modelo de UI

Un **único componente `HistorialOpLog(entidad, entidadId)`** que cualquier pantalla
instancia. Mockups aprobados (2026-06-19):

- **Lista ordenada por fecha y hora (AM/PM) con el usuario al frente.** Cada fila:
  - Línea 1 (verbo + resumen, visible sin expandir): "Cobró C$500", "Cliente
    actualizado", "Contrato suspendido", "Pago anulado". Color/ícono por `tipo_op`.
  - Línea 2: `fecha · hora AM/PM · actor [· Recibo N]`.
  - **Desplegable**: lista `diff.campos` como `[label] [antes → después]` (reusa el
    `_CambioTile` y `_fmtField` actuales: C$, enums ES, fechas).
- **Mismo objeto, una acción = una fila.** Una suspensión que tocó 6 cuotas: 1 fila
  en el contrato (atributos del contrato) + 6 filas, una por cuota (cada una con su
  `monto`/`estado`). La cuota nunca muestra datos del contrato.
- **Query simple:** `WHERE entidad=? AND entidad_id=?`. (Si una entidad debe ver
  también la entrada de su padre, un OR opcional — pero por la regla de scoping de
  Rubén, cada objeto muestra LO SUYO; no se agrega ruido del padre.)

---

## 7. Garantías verificadas

- **Offline write + upload-queue (bloqueante crítico, RESUELTO):**
  `test/powersync/oplog_offline_test.dart` confirma contra el PowerSync real que un
  cliente que NO descarga `op_log` igual la **escribe offline** sin fallar y queda
  **encolada para subir** (`getCrudBatch` la trae como PUT). El upload es
  independiente de los buckets de descarga. → escribir el log en la misma
  `writeTransaction` es seguro: la escritura no falla, así que no puede tumbar el
  cobro, y se mantiene la atomicidad (no hay "dato sin log").
- **Dinero intacto:** `op_log`/`tech_log` NO entran a ninguna métrica de caja
  (`recaudado_caja`/`cobertura_cuota`) ni tocan `pagos`/`cuotas`/`recibos`. En toda
  fase, `invariantes_dinero.sql` debe dar 0.

---

## 8. Plan de implementación por fases (cada una reversible)

**FASE 0 — Infra (aditiva, sin cambiar comportamiento):**
- Migración: `CREATE TABLE op_log` + RLS + índices (DEV vía `supabase db query
  --linked`, verificar con `information_schema`).
- `schema.dart`: agregar `op_log`. **Sin** bump de `_dbWipeVersion`.
- `sync-rules.yaml`: `op_log` al bucket admin → Rubén lo deja **Active**.
- Helper Dart `OpLog` (`escribirOperacion` / `escribirEdicion`) + refactor de
  `auditExtraerCambios`/`_campoVisible` a un helper PURO reusable.

**FASE 1 — Empezar por `pagos_repo` (el 80% del ruido):**
- Emitir `op_log` por objeto en `registrarCobro` / `registrarCobroMultiple` /
  `anularPago` / `editarPago` / `registrarCambioFecha` (el trigger viejo SIGUE
  corriendo a `audit_log` — doble escritura SOLO en esta fase de validación).
- Tests de repo: una intención → exactamente una fila `op_log` por objeto, con el
  diff correcto. `invariantes_dinero.sql` = 0.

**FASE 2 — Lectura a `op_log`:**
- Los `Historial*Widget` → un único `HistorialOpLog`. Se elimina agregador,
  `kAuditCamposSuperficie` y la ventana-3s.

**FASE 3 — Resto de operaciones + cortar la doble fuente (OBLIGATORIA):**
- `contratos_repo` (suspender/cancelar/reactivar/revertir/crédito) + edits simples
  (clientes, planes, etiquetas, geo, red, inventario, tickets, visitas, settings).
- **Dejar de leer `audit_log` en la UI** (pasa a forense super_admin-only). NO se
  deja la doble fuente "por las dudas" — ese fue el error de la ventana-3s.

**Reversibilidad:** cada fase se revierte (el trigger se re-apunta con CREATE OR
REPLACE; los widgets vuelven a `audit_log`). Dinero intacto siempre.

---

## 9. Decisiones

**Resueltas (Rubén, 2026-06-19):**
- ✅ **Per-objeto, scoped:** cada objeto su historial con sus atributos; la cuota
  no hereda del contrato. (Resuelve el Hueco 5 del verificador: el detalle por-cuota
  SÍ se muestra, scoped.)
- ✅ **Actor super_admin = "System Admin".**
- ✅ **Offline** (bloqueante crítico): verificado, el cobrador escribe op_log y sube.
- ✅ **Arrancar por `pagos_repo`** (el mayor ruido), validar, seguir.

**Cerradas por diseño:**
- Multi-recibo: cada cuota emite su entrada con SU recibo en `diff.resumen` → no se
  pierde ningún correlativo (cada cuota muestra el suyo).
- Doble fuente: Fase 3 (cortar la lectura de `audit_log`) es obligatoria.

**Abiertas (no bloquean Fase 0/1):**
- Historia vieja pre-migración: ¿UNION de `audit_log` (cards sueltos viejos) +
  `op_log` por fecha de corte, o `audit_log` solo de archivo super_admin? — Decidir
  antes de Fase 2.
- ¿`settings` migra a op_log o se queda con su trigger (ya es 1-fila=1-intención)? —
  Baja prioridad, Fase final.

---

## 10. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| El dev olvida emitir `op_log` en una operación nueva → 0 logs | El cierre de cada `writeTransaction` de repo pasa por el helper `OpLog` (forma única); enumerar las 15 operaciones con su fuente-de-resumen ANTES de codear; tech_log conserva el rastro forense. |
| El resumen "miente" (no coincide con el dato) | Derivar el resumen de los MISMOS valores escritos; tests de repo que comparan op_log vs estado real de las tablas. |
| Fuente de verdad pasa del trigger (inviolable) al cliente | tech_log (trigger por-fila) se conserva como respaldo forense super_admin; RLS solo-INSERT en op_log. |
| Fix por SQL directo en prod no genera op_log | Lo captura tech_log; documentado: un fix SQL es invisible al historial de usuario, visible en el forense. |
| Multi-device offline desordena por `ocurrido_en` | Límite ya aceptado (invariante #11); `created_at` server da desempate. La agrupación NO se rompe (cada intención es 1 fila por objeto, no depende de proximidad temporal). |
