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
   **`is_super_admin()` relaja el ROL, NUNCA el TENANT (regla nueva, bug
   2026-08-20).** En toda función/policy/query de LECTURA que alimente una
   pantalla del ISP (rutas `/admin/*` y las del cobrador), la forma canónica es:
   ```sql
   and <tabla>.tenant_id = public.current_tenant_id()
   and (public.is_super_admin() or public.is_admin_or_cobranza())
   ```
   **NUNCA** `is_super_admin() or (tenant_id = current_tenant_id() and …)`: el
   `OR` cortocircuita y para el super_admin el filtro de tenant no se evalúa
   nunca. La rama del rol es necesaria (`is_admin_or_cobranza()` es FALSE para
   el super_admin: sin ella perdería la pantalla hasta en el tenant que
   impersona), pero va sobre el ROL, no sobre el tenant. Impersonando, el
   super_admin ve EXACTAMENTE lo que vería el admin de esa empresa, ni una fila
   más. Lo cross-tenant vive en `/super/*` (hoy: `/super/diagnostico`, que
   etiqueta cada fila con el nombre de la empresa) y en funciones gemelas
   `*_todos()` gateadas solo a `is_super_admin()`. Así nació el bug: la bandeja
   de un tenant listaba huecos de talonario de otros dos ISPs (0237/0238/0242 →
   corregido en 0246). **Al auditar**: `grep -n "is_super_admin() *$" -A2` sobre
   las migraciones, buscando el patrón `is_super_admin()\n or (`. Y ojo con el
   espejo en el cliente: el SQLite del super_admin NO es mono-tenant (baja su
   propia fila del tenant System y conserva la empresa anterior hasta que cierra
   el sync), así que toda query local de listas debe filtrar `tenant_id`
   explícitamente — el supuesto "el sync ya lo scopeó" solo vale para usuarios
   del ISP.
2. **Offline-first** — el cobrador/técnico opera sin internet. Features que
   requieran conexión sincrónica deben declararse explícitamente.
3. **Server gana** — Postgres es la fuente de verdad. El cliente espeja
   triggers (mirrors) SOLO para UX instantánea offline.
4. **Change log (`op_log`) append-only** — el historial es `op_log` (log de
   intención del cliente); nunca borrar rows, para "deshacer" se agregan rows
   nuevas. (El `audit_log` forense del server se ELIMINÓ — 0140.)
5. **Workflow sin email** — toda feature que asuma "envía email" necesita
   fallback no-email.
6. **🔴 Toda acción con repercusión monetaria pide AUTORIZACIÓN del admin**
   (línea general de Rubén, 2026-08-26). Si una acción crea, borra o mueve
   plata cobrable, el rol que la ejecuta pasa por `requiereAprobacionPara`
   (`data/providers/aprobaciones_provider.dart`): el `admin` la ejecuta —es
   quien aprueba— y **todos los demás la SOLICITAN**. La regla es *"requiere
   aprobación salvo que seas quien aprueba"*, nunca una lista de roles por
   descarte: un rol nuevo nace pidiendo permiso.
   **Y quien autoriza tiene que VER el número antes de firmar**: monto real de
   lo que se va a crear o borrar, calculado con el MISMO criterio que la
   mutación, más motivo obligatorio. Un preview que usa otra fórmula que la
   mutación es una firma en falso — pasó con la cancelación (el preview traía
   el cálculo de suspensión y mostraba menos de lo que se condonaba, fix
   2026-08-26).
   **Cómo se rompe esto sin querer:** una acción que *antes* no movía plata y
   *ahora* sí. Desactivar un cliente era organizativo y lo ejecutaba
   `admin_usuarios` directo; cuando pasó a condonar la deuda (regla del
   2026-08-26, migración `0260`), ese permiso quedó autorizando una baja de
   cartera. **Al cambiar lo que una acción HACE, revisar quién puede hacerla.**
   **Y el viaje de vuelta NO es simétrico (2026-08-29, migración `0265`):** esa
   misma baja dejó de mover plata —ahora exige que no queden contratos vivos, y
   la condonación se autoriza contrato por contrato— y **igual se le conservó la
   aprobación**, por decisión del dueño: terminar la relación con un cliente es
   una decisión de negocio. O sea: que una acción empiece a mover plata OBLIGA a
   revisar el permiso; que deje de moverla **habilita** revisarlo, no lo relaja
   solo. Quitar un permiso es del dueño, nunca una consecuencia automática.
   **Dónde más mirar cuando una acción cambia de efecto:** el preview que la
   muestra, el texto de la solicitud que ve el aprobador y el `deuda` que viaja
   con ella. Los tres decían "se va a condonar" y quedaron mintiendo el día que
   dejó de condonarse.

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
6b. **CANCELAR no deja deuda; SUSPENDER sí** (regla del dueño, 2026-08-24).
   Cancelar un contrato pone en CERO todas sus cuotas vivas — incluidos los
   meses de atraso — y el contrato sale de las listas de cobro. Suspender corta
   el servicio pero CONSERVA la deuda y es reversible: es la herramienta para el
   que se va debiendo y se le va a seguir cobrando. Antes los dos hacían casi lo
   mismo (cancelar dejaba cobrable lo cumplido + el prorrateo del mes en curso),
   y el dueño reportó contratos cancelados que seguían con deuda.
   **CÓMO se pone en cero — y esto NO es negociable:** cuota sin pago → anular;
   cuota CON pago → `monto = monto_pagado`, `cargos_neto = 0`, estado `'pagada'`.
   **Anular una cuota con plata está PROHIBIDO**: el trigger
   `cuotas_anular_pagos_asociados_trg` anula EN CASCADA sus pagos y sus recibos,
   o sea que borra plata que entró a caja y un comprobante que el cliente tiene
   en la mano. `cargos_neto` va a 0 en el mismo UPDATE: entra en el saldo
   canónico (#10) y un cargo vivo resucita la cuota en las listas de cobro
   aunque el monto quede en cero. Implementado en `contratos_repo.cancelarContrato`
   + migración `0258` para la deuda histórica.
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

## 🔴 LA REGLA DE ORO — un cambio no está hecho hasta que TODO lo conectado dice la verdad

> **Pedido textual de Rubén (2026-08-26), después de frenar el trabajo por este
> motivo.** Las reglas de abajo nacieron de UN caso: al cambiar la regla de
> cancelación (cancelar CONDONA la deuda, 2026-08-24) se arregló el repo que la
> ejecuta y quedaron mintiendo las superficies que la MUESTRAN. El filtro
> "Cancelado con deuda" siguió ofreciendo una categoría abolida
> (`clientes_admin_screen.dart:33`), el chip decía "Sin contrato" a un suspendido,
> y la documentación afirmaba lo CONTRARIO en seis lugares. **Una regla de negocio
> no vive solo en el repo que la ejecuta: vive en los filtros, chips, conteos,
> exports, textos y documentación.**

**1. Barrer las superficies conectadas — NO es opcional.** Antes de dar un cambio
por hecho: `grep -rn '<tabla|símbolo>' lib/` y recorrer CADA filtro, chip, conteo,
export, PDF, texto de ayuda y documento preguntándose *¿esta pantalla sigue
diciendo la verdad?*. **Una superficie que no se revisó no es una superficie que
está bien: es una que no se miró.**

Las tres herramientas que lo vuelven mecánico. **Dos de ellas las corre el CI**
(`regla.py --verificar` y `estructura.py --verificar`), así que una omisión
FALLA en vez de pasar desapercibida; **`impacto.py` NO** — no tiene modo
`--verificar`, toma una tabla como argumento, y por eso depende de que uno se
acuerde de correrla:

| Herramienta | Contesta | Cuándo |
|---|---|---|
| `python tools/impacto.py <tabla>` | dónde vive una TABLA (las 8 capas) | si el cambio toca una tabla o columna (Fase 2) |
| `python tools/regla.py <regla>` | dónde se VE una regla de negocio | si el cambio toca una de las reglas con ficha (`docs/reglas/`) |
| `python tools/estructura.py` | si las tablas que `ARQUITECTURA` declara COMPLETAS lo están | al crear una tabla o un bucket de sync |

**2. Ejecutar COMPLETA la opción elegida.** Cuando Rubén elige una de las opciones
propuestas se hace entera —incluidas las superficies del punto 1 y la
documentación—, no la mitad más fácil. Entregar la mitad sin decirlo es peor que
no empezar: deja la app en un estado que nadie sabe describir.

**3. Cerrar con las TRES LISTAS.** Todo pedido se entrega con:
   - **superficies tocadas** (`archivo:línea`),
   - **superficies revisadas y sin cambios** (con el porqué de cada una),
   - **superficies que quedan afuera** (con el porqué y qué las dispararía).

   Sin las tres el cambio no está entregado: está abandonado a mitad de camino.

**4. El criterio solo puede SUMAR trabajo, nunca sacarlo.** Se puede decidir
convocar especialistas de más, profundizar un audit o pedir una verificación extra.
NO se puede decidir que el barrido del punto 1 "esta vez no hace falta", ni que la
documentación se actualiza después. *"Esto es sencillo"* es exactamente lo que uno
piensa antes de romper algo.

**5. Entrega VISUAL del antes y el después.** Todo cambio que altere lo que el
usuario ve o hace se entrega con mockups del **ciclo de vida de uso** —el recorrido
del negocio, no la pantalla suelta—: el ANTES real y el DESPUÉS propuesto en la
propuesta (Fase 2), y el resultado real al cerrar (Fase 6), **sobre el MISMO
diagrama** para que la comparación sea inmediata. Formato y reglas:
`AUDIT-PROFUNDO.md` §6. En español llano: si hay que saber SQL para entenderlo,
está mal hecho.

**Por qué esto vive ACÁ y no en `BITACORA.md`:** este aprendizaje pasó dos días
SOLO en el bloque de estado de la bitácora, que se reescribe cada sesión — o sea
que estaba programado para desaparecer y que el próximo agente repitiera el error
idéntico. Lo único que se carga solo en CADA sesión es este archivo.

---

## Proceso mandatorio de fixes y features (lifecycle)

**Fase 1 — Entender:** leer el pedido → `BITACORA.md` (dónde quedamos) →
este AGENTS.md → `ARQUITECTURA.md` §0 (¿hay receta para este cambio?).

**Fase 2 — Pre-evaluación:** investigar archivos (la receta dice cuáles),
evaluar riesgos/dependencias, **presentar propuesta con opciones y ESPERAR
aprobación (OBLIGATORIO)**. Si el cambio toca UI/UX → la propuesta incluye un
**mockup visual** (ver "Reglas de comunicación con Rubén").

> **🔴 MAPA DE IMPACTO — obligatorio si el cambio toca UNA TABLA O COLUMNA.**
> Antes de proponer, correr y **pegar la salida en la propuesta**:
>
> ```bash
> python tools/impacto.py cuotas.cargos_neto
> ```
>
> Lista las 8 capas donde esa tabla vive en el repo (migraciones, `schema.dart`,
> sync rules del VPS, queries Dart, tests, los DOS seeds, invariantes, docs) y
> avisa de lo que rompe callado: triggers que recalculan solos, policies RLS,
> CHECKs, FKs a otras tablas, DEFAULTs que el INSERT de Dart no hereda.
>
> **Por qué es obligatorio y no "buena práctica":** el modo de falla más caro
> del proyecto es exactamente éste — *"se piden cambios que por jerarquía van
> encadenados con otras tablas, esas tablas se quedan fuera y esos cambios dañan
> la interacción"* (Rubén, 2026-08-14). La regla de grepear ya existía en el
> checklist §4 y en R4/R10; lo que fallaba es que dependía de acordarse. Pegado
> en la propuesta, Rubén ve la lista COMPLETA antes de aprobar, y lo que falte
> lo caza ahí y no en producción tres días después.
>
> **Una capa sin hits es una PREGUNTA, no un OK.** Si la columna no aparece en
> `schema.dart`, la app no la ve. Si no aparece en los dos seeds, el escenario
> de test diverge de producción (ya pasó 3 veces). Si no aparece en ningún test,
> el cambio no tiene red.

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
5. **Entregar con las TRES LISTAS** (regla de oro §3) y, si cambió lo que el
   usuario ve o hace, los **mockups del antes y el después** (regla de oro §5).
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

**12b. Gate booleano que falla ABIERTO por un NULL (CRÍTICO — regla nueva, bug
   2026-08-21):** SQL tiene lógica de TRES valores y **`if not <expr>` NO entra
   cuando `<expr>` es NULL** → el guard se saltea EN SILENCIO y la función sigue
   como si estuviera autorizada. Toda función/expresión que se consuma como
   permiso (`if not gate(...) then return 'sin permiso'`) tiene que ser **TOTAL**:
   `coalesce(<expr>, false)`, o consumirse con `is not true`. Dónde aparece el
   NULL: `current_tenant_id()` es NULL para un JWT sin fila en `cobradores`
   (incluido `anon`) → `p_tenant = current_tenant_id()` da NULL, no false; y
   `is_admin_or_cobranza()` también puede dar NULL. Los dos casos reales:
   `sync_rechazo_autorizado()` devolvía NULL para anon y
   `sync_rechazo_registrar()` la usaba con `if not` → **insertaba pagos, recibos
   y op_log** con el guard salteado (0237→0247); y `sync_rechazo_descartar`
   contra una fila huérfana (`tenant_id` NULL) daba NULL para un admin → caía al
   UPDATE (regresión de 0246, cerrada en 0247). **En un WHERE no se nota** (ahí
   NULL se comporta como false), así que el mismo gate puede estar bien en la
   lista y mal en el `if` — probar los DOS consumos. Grep de regresión:
   `if not public.` en `supabase/migrations/` → cada hit tiene que ser total.
   Al probar, incluir SIEMPRE una identidad **sin fila en `cobradores`**: con
   usuarios normales el bug es invisible (igual que `dia_pago = 1` en 1c).

**13. Plata nueva que el Resumen no ve (CRÍTICO — regla nueva 2026-08-13):**
   toda feature que pueda **CREAR, INFLAR o ENCOGER** plata cobrable tiene que
   quedar reflejada en el dashboard **en el mismo sprint**, y hay que
   **AVISARLE A RUBÉN** en el handoff: qué concepto nuevo aparece, en qué balde
   (Mensualidad / Otros / Descuentos / ninguno), con qué número esperado y qué
   gate lo enciende (setting, precio, módulo). **Pedido textual del dueño: el
   dashboard se actualiza con CUALQUIER cambio de plata y se le avisa.** Un
   cambio de plata que no movió el Resumen y no se avisó NO está cerrado.
   La tabla de los 13 caminos vigentes, el puente ticket→cobro y el **grep de
   regresión con baselines** están en **ARQUITECTURA §3.5 (6)** — ahí se agrega
   la fila, no acá. **NO lo cazan `flutter analyze` ni los tests**: un balde
   faltante no rompe nada, la plata entra igual y solo miente el concepto.
   Exclusión deliberada (costo interno, egreso de caja) también se escribe, con
   el porqué, para que el próximo agente no la "arregle".

## Cómo se DELEGA el trabajo (las 8 capas y quién toca cada una)

Un pedido casi nunca vive en una sola capa. El desorden que costó días fue
tratar cada pedido como "un cambio" en vez de como **N cambios encadenados**.
`python tools/impacto.py <tabla>` dice CUÁLES capas se tocan; esta tabla dice
QUIÉN las toca y en qué orden.

| # | Capa | Qué vive ahí | Se delega a |
|---|---|---|---|
| 1 | **Postgres** | migraciones, triggers, RLS, CHECKs | el hilo principal, NUNCA un subagente (es producción) |
| 2 | **SQLite** | `powersync/schema.dart` | va junto con (1), mismo commit |
| 3 | **Sync** | `powersync/sync-rules.yaml` + restart del VPS | el hilo principal (SSH a Hetzner) |
| 4 | **Dart** | queries, repos, providers | subagentes en paralelo, uno por archivo/módulo |
| 5 | **UI** | pantallas, widgets | subagente + la skill `design` / `ui-ux-pro-max` |
| 6 | **Tests** | unit, widget, escenarios | subagente, DESPUÉS de que (4) esté escrito |
| 7 | **Seeds** | `supabase/escenarios/` — los DOS generadores | el hilo principal (ya divergieron 3 veces) |
| 8 | **Docs** | ARQUITECTURA / MODULOS / BITACORA | el hilo principal, en la Fase 6 |

**Reglas de delegación que no se negocian:**

1. **Nada que escriba en producción se delega.** Migraciones, `supabase db query`
   con UPDATE/INSERT, sync rules, releases. Un subagente no tiene el contexto
   para juzgar el daño y no puede pedirle permiso a Rubén.
2. **Lo que se delega bien es lo que se puede VERIFICAR solo**: leer y reportar
   (auditorías), buscar en muchos archivos, escribir tests, proponer diseños en
   paralelo. Si el resultado necesita que alguien lo crea sin poder chequearlo,
   no se delega.
3. **Todo hallazgo de un subagente pasa por un escéptico** antes de llegar a
   Rubén. En esta sesión, de ~30 hallazgos reportados sobrevivieron 4 — el resto
   eran plausibles y falsos. Relatar un hallazgo sin refutarlo es hacerle perder
   el tiempo.
4. **Verificar los números uno mismo antes de relatarlos.** Un subagente dijo
   "C$4.898 sin facturar" y era cierto; otro dijo que el efecto `reconexion` no
   cobraba y era media verdad. Si el número va a llegar a Rubén, se corre la
   consulta acá.
5. **El orden es 1→8, no al revés.** Escribir Dart antes de tener la columna en
   `schema.dart` produce código que compila y no ve datos.

**Las skills, dónde entran:** `ui-ux-pro-max`/`design` cuando el pedido es de
interfaz (evita las 8 iteraciones de la misma tarjeta que costó el Resumen);
`systematic-debugging` cuando algo falla y no se sabe por qué;
`writing-plans`/`brainstorming` para descomponer un pedido grande;
`dispatching-parallel-agents` para el fan-out. **Ninguna reemplaza las 6 fases
ni el mapa de impacto.**

**13. Guard de ESTADO vs guard de TRANSICIÓN (CRÍTICO — regla nueva, 0254):**
   Cuando la regla es *"quien hace X tiene que registrar quién y por qué"*, el
   requisito es sobre la **TRANSICIÓN**, no sobre el estado de la fila. Un
   `CHECK` no distingue: evalúa la fila entera en **cada** INSERT/UPDATE, y
   `NOT VALID` **solo salta el escaneo inicial** — sigue disparando para siempre
   en cualquier UPDATE futuro de una fila vieja que no lo cumple. Si algo del
   día a día toca esas filas (en 0254: `propagate_cobrador_id_from_cliente`
   updatea TODOS los contratos del cliente sin filtrar por estado), el guard
   rompe una operación diaria para proteger un dato histórico — al revés.
   **Regla: usar un trigger BEFORE que valide solo la transición** (`NEW.x = v
   AND OLD.x IS DISTINCT FROM v`). Antes de agregar CUALQUIER `CHECK` a una
   tabla con filas históricas que lo violan, contar **cuántas filas vivas
   quedarían atrapadas** (`SELECT count(*) ... WHERE <la condición falla>`) y
   preguntarse **quién las updatea en la operación normal**.

**13b. `TG_OP` miente con el UPSERT (CRÍTICO — mismo origen):** PowerSync sube
   los `UpdateType.put` con `table.upsert(...)` (`connector.dart`), que PostgREST
   traduce a `INSERT ... ON CONFLICT DO UPDATE`. El trigger **BEFORE INSERT
   dispara ANTES de que se detecte el conflicto**: `TG_OP` dice `'INSERT'` y
   `OLD` no existe, **aunque la fila ya esté en la tabla**. Todo guard de
   transición sobre una tabla sincronizada necesita, además de la rama
   `TG_OP='UPDATE' AND OLD...`, la rama `TG_OP='INSERT' AND EXISTS (SELECT 1
   FROM <tabla> WHERE id = NEW.id AND <ya estaba en ese estado>)`. Sin ella el
   guard rebota re-puts legítimos de filas históricas. No lo cazan analyze ni
   tests: solo aparece cuando un device re-sube una fila vieja.

**13c. El corrector y el verificador comparten predicado (regla nueva, 0251):**
   toda función que ARREGLA lo que un chequeo MARCA tiene que usar el predicado
   **idéntico**. Si divergen, el botón "corrige" filas que el chequeo no marca
   (o no corrige las que sí) y **nunca converge**: se aprieta, dice "N
   corregidos", se vuelve a verificar y sigue igual. Peor si el corrector emite
   `op_log`: estampa filas de "corrección" con `antes = después` en el historial
   de dinero, en cada apretón. Al tocar cualquiera de los dos lados, grepear el
   otro y comparar los WHERE **cláusula por cláusula**. Ojo con `en_revision`
   (cuarentena del guard 0218): el predicado canónico de "pagos que cuentan" es
   `anulado = false AND en_revision = false`, y `anulado = false` a secas es un
   bug silencioso.

**14. Un chequeo que NUNCA puede dar >0, o que SIEMPRE va a dar >0, es peor
   que no tener chequeo (regla nueva, audit 0255):** el primero da falsa
   tranquilidad, el segundo se ignora y tapa el día que haya algo real. Al
   escribir o tocar un invariante, hacer SIEMPRE las dos preguntas y
   contestarlas con una consulta, no con el ojo:
   - **¿Puede dar >0?** Describí la fila que DEBERÍA dispararlo y verificá que
     el predicado la atrapa. Ojo con el **fail-open por NULL**: `x > NULL` da
     NULL y la fila se excluye en silencio — un `IS NOT NULL` río arriba puede
     estar tapando justo la población donde vive el bug (así INV25 no vio 6
     cuotas de deuda fantasma: le faltaba el `COALESCE` que su trigger sí hace).
   - **¿Puede satisfacerse?** Si exige un campo, grepear **quién lo escribe**.
     Si no lo escribe nadie (`count(campo) = 0` en producción, sin UPDATE en
     `lib/`, sin trigger), el chequeo es una alarma permanente disfrazada de
     invariante — y encima se tapa a sí mismo: si TODO viola, deja de
     discriminar (INV29 pedía un `recibo_id` que ningún camino setea).
   Y una tercera, para los que ya existen: **¿el que lo ARREGLA y el que lo
   MIDE usan el mismo canon que el que MANDA?** Cuando hay un trigger BEFORE de
   por medio, el trigger es la autoridad — gana siempre. Verificador y corrector
   se alinean A ÉL, no entre ellos (ver #13c). Si el corrector pide algo que el
   trigger no deja entrar, `RETURNING` devuelve el valor POST-trigger: la fila
   cuenta como "corregida" sin haber cambiado. Blindaje barato y general:
   `... RETURNING prev.x AS antes, q.x AS despues` + filtrar
   `WHERE antes IS DISTINCT FROM despues` antes de contar y de loguear.

**15. `Flexible` + `Expanded` en el MISMO `Row` deja un HUECO (regla nueva,
   2026-09-01):** los dos son flex y se reparten el espacio libre en partes
   iguales, pero `Flexible` es *loose*: usa sólo lo que su hijo necesita y **el
   resto de su parte queda como hueco muerto**, que el `Expanded` nunca ve. La
   cifra alineada a la derecha del `Expanded` termina donde termina su fracción
   — **un lugar distinto en cada fila**, según cuán largo sea el texto del
   `Flexible`. En "Estado actual" las cifras terminaban en **siete bordes
   derechos distintos** a 1900px, y la única fila que llegaba al borde era la
   única SIN hint, o sea sin `Flexible`.
   **La forma correcta: UN SOLO `Expanded`, y que sea el de la IZQUIERDA.**
   Absorbe todo el sobrante; el valor va sin flex, con su ancho natural, y por
   eso pegado al borde. Cuando hay que alinear COLUMNAS entre filas (una tabla),
   `Table` con `IntrinsicColumnWidth` lo resuelve **por construcción** — con
   `Flexible` la alineación depende del CONTENIDO: si los textos saturan su
   cuota queda derecha por casualidad, y con textos cortos se corre.
   **No lo caza `flutter analyze` ni ningún test de datos**: no hay excepción,
   el widget se dibuja. Sólo se nota mirando, y a un ancho concreto. Grep de
   regresión: un `Flexible` y un `Expanded` hermanos en el mismo `Row`.

**15b. Un test de layout que no distingue el ANTES del DESPUÉS es decoración
   (mismo día, tres intentos):** al probar la alineación del globo, la primera
   versión medía **un solo día** y daba VERDE con el layout roto (los montos del
   escenario eran largos y saturaban); la segunda comparaba posiciones
   **absolutas entre días** y daba 31 valores distintos porque el globo se mueve
   con su punto en la curva; la tercera medía a **1400px**, donde el globo de
   250 entra en cualquier posición y el bug de límites no se ejercita.
   **Antes de dar por bueno un test de UI, correrlo contra el código VIEJO.** Si
   pasa igual, no es una red.

**16. Un escenario que no siembra lo que producción tiene no prueba lo que
   creés (regla nueva, 2026-09-01):** el Excel sumó una columna `Recibo` y el
   test la encontró VACÍA — el escenario tenía **245 pagos y CERO recibos**,
   contra el **100%** de producción (32.609 de 32.609). El código estaba bien;
   el escenario mentía.
   Al agregar una columna que sale de una tabla que el escenario no puebla,
   **sembrarla en los DOS generadores** (`generar_seed_dart.py` y
   `generar_seed_sql.py`) — ya divergieron tres veces. Y contra producción,
   preguntar **qué porcentaje** de las filas tiene el dato: si allá es 100% y
   en el escenario 0%, el test no está probando la columna.

**17. Una fila de cierre de Excel armada A MANO se corre en silencio (regla
   nueva, 2026-09-01):** los exports con secciones escriben su subtotal como
   `['Subtotal x', '', '', '', '', c.cuotas, c.monto]` — un `''` por columna
   hasta la que lleva el número. **Agregar una columna y olvidar el `''` no
   rompe nada**: el archivo se genera, se abre en Excel, y el total aparece una
   casilla más a la izquierda. No lo caza `analyze` (las filas son
   `List<Object?>` y aceptan cualquier largo) ni ningún test de datos.
   Lo verifica **`LibroExcel.desparejas()`**, que salta como `assert` al
   construir el libro — y encontró el error en el acto: al sumar `Recibo` y
   `Ciclo del cobro`, el TOTAL de Cobertura quedó con **13 celdas para 15
   columnas**. En release el assert no está: un subtotal corrido no es motivo
   para dejar a nadie sin su Excel.

**14b. Un comentario que dice "copia exacta de X" es una promesa que hay que
   verificar, no creer (mismo audit):** INV25 declaraba ser copia exacta del CTE
   `futuras` del trigger 0234 y difería en dos cosas (el `COALESCE` de la fecha y
   un filtro de más). Al auditar cualquier bloque que se declare espejo de otro,
   **traer los dos cuerpos VIVOS y diffearlos**, cláusula por cláusula. El
   comentario envejece; el código del otro lado se mueve.

**14c. El texto que la UI muestra sobre un problema es parte del fix:** si el
   invariante dice "es plata que salió de una caja que no la tenía" y la
   operación real es legítima, mandás a auditar un arqueo sano; si la corrección
   sugerida es "completá el recibo" y no hay campo de recibo en ningún flujo, la
   instrucción es imposible de seguir. Al cambiar el PREDICADO de un chequeo,
   revisar SIEMPRE su `explicacion`/`correccion` en `invariantes_detalle.dart`.
   Y no hardcodear conteos en pantalla ("corre los 20 chequeos"): derivarlos del
   resultado — ese número fue 17, 20 y 31, y quedó viejo las tres veces.

**18. Un dato del COMPROBANTE que sale de un JOIN a una tabla editable
   CONTRADICE el papel que el cliente tiene en la mano (regla nueva,
   2026-09-02):** el recibo no es una vista, es un **documento EMITIDO**. Todo
   campo que se imprime y se **recalcula en cada impresión** hay que
   congelarlo en la fila del recibo al emitirlo — columna nullable y **sin
   backfill**: `NULL` = recibo viejo, el renderer calcula como siempre;
   rellenar los viejos con la regla de hoy sería escribir una mentira con
   cara de dato.
   **Ya mordió DOS veces con la misma forma.** El **mes** (`0262`): el recibo
   HL-00230 de Mairena dice *"Julio 2026"* en mano del cliente y *"Junio
   2026"* en la app, mismo cobro y mismo correlativo. Y el **plan** (`0268`):
   el recibo resolvía el plan por JOIN al plan VIVO del contrato, así que los
   37 cambios de plan de Mairena entre el 22/08 y el 01/09 reescribieron **en
   silencio** el plan que decían todos los recibos anteriores de esos
   contratos.
   **Siguen vivos y SIN congelar:** el nombre y la dirección de la empresa
   (`settings.empresaNombre`/`empresaDireccion`, leídos vivos en los tres
   renderers) y el nombre del cobrador (`co.nombre` por `JOIN cobradores`,
   `recibo_screen.dart`). Cualquiera de los tres se edita y reescribe
   retroactivamente lo que dicen todos los recibos viejos.
   **NO lo cazan `analyze` ni los tests:** el recibo se imprime perfecto y la
   mentira aparece recién en la REIMPRESIÓN, meses después, cuando el cliente
   pone su papel al lado de la pantalla. Al sumar un campo al recibo,
   preguntarse siempre: **¿de qué tabla sale, y quién la puede editar
   mañana?** Caso completo: `docs/reglas/mes-servicio.md`.

**19. Un parámetro que una función RECIBE, DOCUMENTA y nunca USA (regla
   nueva, mismo día):** `cambiarPlan` declaraba `String? motivo` con el
   docstring *"queda en el op_log del contrato"* y el cuerpo escribía siempre
   el literal `'Cambio de plan'`. Producción lo confirma: **168 filas de
   historial, cero variación**. Es la hermana de la 14b —un comentario que
   promete— pero peor, porque el parámetro existe y **el llamador lo llena en
   serio**: el camino de aprobación armaba un motivo que incluía el aviso de
   que el precio del plan se movió entre el pedido y la firma, con los dos
   números, y se descartaba entero.
   **Cómo se caza, y es barato:** para todo parámetro opcional que un
   docstring diga que se persiste, grepear su nombre **dentro del cuerpo** de
   la función. Si solo aparece en la firma, no se usa. Y contra producción:
   `SELECT DISTINCT <campo>` — si un campo que debería variar tiene UN solo
   valor en miles de filas, nadie lo está escribiendo.

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
