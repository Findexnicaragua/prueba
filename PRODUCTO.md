# PRODUCTO.md — Misión, visión, día a día y stack de Cobranza ISP (CRM)

> **Quién lee esto:** humanos que necesitan entender QUÉ es la app y POR QUÉ
> existe, y AIs que necesitan el contexto de negocio antes de tocar código.
> **Cuándo se actualiza:** cuando cambia la misión, se agrega/quita un módulo
> de producto, cambia un rol, o se reemplaza una pieza del stack. Cambios de
> código del día a día NO se anotan acá (van en `BITACORA.md`).
> **Documentos hermanos:** `ARQUITECTURA.md` (cómo está construida y conectada)
> · `BITACORA.md` (qué se hizo y por qué, sesión por sesión) · `AGENTS.md`
> (reglas y proceso de trabajo para la AI) · `Install Steps/` (build y release).

---

## 1. Misión

Resolver el **ciclo completo de cobranza de internet residencial** para ISPs y
WISPs chicos/medianos de Centroamérica (mercado primario: **Nicaragua**), para
que un ISP real pueda **reemplazar su Excel + WhatsApp** de cobranza con una
sola app que funciona **sin internet** en el campo.

El producto es un SaaS **multi-tenant** modelo B2B:
- El dueño del SaaS (**Rubén**, rol `super_admin`) provee la plataforma.
- Cada ISP cliente es un **tenant** con sus propios admins, cobradores y
  técnicos. Un tenant JAMÁS ve data de otro (aislamiento por RLS en Postgres).

### Visión
Que el dueño de un ISP de 200–2000 clientes abra el dashboard y sepa en 10
segundos cuánto entró hoy, quién debe, y dónde está cada cobrador — y que el
cobrador en una zona rural sin señal cobre, imprima el recibo térmico, y siga
con el próximo cliente sin pensar en "la app". Sin features experimentales,
sin abstracciones prematuras: **cada sprint acerca al MVP del día a día real**.

---

## 2. Roles (quién usa la app y qué ve)

| Rol | Quién es | Dónde vive | Qué hace |
|---|---|---|---|
| `super_admin` (se muestra como **«Dev»**) | Dueño del SaaS | `/super/*` (web/desktop) | Crea/configura tenants, gestiona miembros cross-tenant, toggle de módulos por tenant, ve logs de errores. Puede **impersonar** un tenant (entra como su admin, con banner y auditoría; acciones de campo bloqueadas) y, dentro de un tenant, corregir **errores de carga** desde **Operaciones de datos** (limpiar/eliminar un cliente o contrato mal importado, con vista previa, copia de respaldo y registro). |
| `admin` | Dueño/gerente del ISP | `/admin/*` (Windows/web) | Catálogo (planes, clientes, contratos), cobradores, cuotas, pagos, reportes, mapa, settings, geografía, red, avisos. Módulos opcionales: inventario, tickets, incidentes. |
| `admin_cobranza` | Mano derecha del admin | `/admin/*` acotado | Globaliza cobranza, mora, metas, rutas. Ve: Clientes, Rutas, Cobranza (Centro/Cobros/Avisos), Reportes, Mapa y **Resumen**. **NO ve montos recolectados**: en el Resumen ve Cobros del mes y Mora del ciclo SIN la fila de lo cobrado ni la curva de cobrado acumulado (queda lo facturado y lo que falta), y la Proyección completa; quedan fuera Cobros del período, el rango manual y Top cobradores.
**Alcance REAL del recorte (decidido por Rubén 2026-08-10):** el recorte es del
**Resumen**, no del rol. Sí saca reportes, incluido **"Reporte de cobranza"**, que trae
`monto_cordobas` de cada pago — o sea que el rol SÍ puede ver montos cobrados si los
busca; lo habilitó `d100c19` a propósito porque los necesita. Los otros cinco reportes de
plata (Cobros del período, Cobros por cobrador, Arqueo, Fiscal, Eficiencia) siguen con
candado de admin. Su bucket le baja `pagos`, `recibos` y `saldos_favor` enteros (a
`admin_usuarios` se los niegan). **Lo que el recorte busca es que el Resumen no lo
distraiga de la mora y la cartera, no impedirle el acceso al dato.** No re-flagear como
fuga de seguridad. Ojo: viendo facturado y pendiente, lo cobrado es derivable por resta — se aceptó a cambio de no dejar la tarjeta sin contexto (2026-08-10). **Toda acción de contrato (crear, suspender, reactivar, cancelar, revertir, cambiar plan) la PIDE**: va a la cola que aprueba el `admin`, con motivo + notas obligatorios. SIN config sensible: no planes, cobradores, settings, geografía, red, inventario, tickets. |
| `admin_usuarios` | Personal administrativo sin acceso a dinero | `/admin/*` acotado (allowlist: clientes, contratos, mapa, solicitudes) | Ve y edita clientes/contratos pero NO cobra, NO ve pagos/cuotas/reportes/settings. Lo que toca el CONTRATO (crear, suspender, cancelar, reactivar, cambiar plan) se envía como **solicitud de aprobación** que el `admin` revisa, con **motivo + notas obligatorios** (viajan a la cola y al evento real del contrato); lo que es del CLIENTE lo maneja directo. Sin acceso a dinero ni configuración. |
| `lectura` | Dueño del ISP que supervisa (0198, 2026-07-26) | `/admin/*` completo, sin acciones | Ve TODO el tenant **incluida la plata** y no puede modificar nada. Pedido por los dueños de los tenants. Tres barreras: la pantalla no dibuja las acciones, la app frena la escritura antes de tocar los datos (`ps.dbW`) y sus policies de Postgres son exclusivamente de SELECT. Única escritura permitida: su propio PIN del Resumen. Lleva PIN igual que el `admin`. |
| `cobrador` | Usuario de campo | `/*` (Android, móvil-first) | Ve SUS clientes/cuotas asignadas, cobra offline-first (foto del comprobante + recibo térmico Bluetooth), registra visitas (si el tenant lo habilita — setting super-admin `cobranza.registrar_visitas`, default OFF). |
| `tecnico` | Técnico de campo (módulo tickets) | `/tecnico/*` (Android) | Ve SUS tickets asignados, los resuelve offline, consume materiales de su custodia (descuenta inventario). No ve dinero. Trabaja de a una orden por vez (cola). |
| `coordinador` | Quien reparte el trabajo de campo (módulo tickets) | `/admin-tickets/*` | Asigna técnico y ordena la cola de trabajo — y NADA más: solo puede escribir `asignado_a` y `orden_cola`, y lo enforza un TRIGGER (la RLS es row-level y no protege columnas). No ve dinero. |
| `admin_tickets` | Encargado de tickets del ISP (módulo tickets) | `/admin-tickets/*` | Admin acotado a tickets: crea/asigna/cierra tickets y administra tipos, sin ver dinero. VIVO desde 0e72fec (2026-06-22): se ofrece al invitar/editar personal si el tenant tiene el módulo tickets; shell propio y bucket de sync `por_admin_tickets` (0 usuarios asignados en prod a hoy, pero disponible). |

### Decisión de workflow CRÍTICA (onboarding sin email)
El super_admin NO depende de email para dar de alta tenants/usuarios:
1. Crea el ISP desde `/super/tenants` con el switch "Enviar email" en **OFF**.
2. El server genera una password aleatoria y se la devuelve para copiar.
3. La comparte por WhatsApp/llamada. El cliente entra por `/login` directo.

No hay signup público ni dominio verificado en Resend. **Cualquier finding de
seguridad del tipo "si signup estuviera habilitado..." está fuera de scope.**

---

## 3. El día a día (lifecycle de uso real)

### La jornada del cobrador (el corazón del producto)
1. **Mañana, con señal:** abre la app → PowerSync ya sincronizó su slice
   (sus clientes, cuotas, pagos). En **"Cobros"** ve **una fila por contrato**
   (la cuota más vieja de cada uno) ordenada por urgencia, con **plan · mes ·
   fecha · estado** y el **saldo cobrable**, y botones **Pagar** y **Cambiar
   fecha** inline. Toca la fila para abrir la **ficha del cliente**; busca a
   alguien puntual por nombre/cédula/teléfono/código. El saldo de la fila es
   lo cobrable en una pasada (la cuota más vieja), distinto a propósito del
   pendiente histórico del dashboard. Si el contrato arrastra varios meses, un
   chip avisa **"+N cuotas · C$X más"** (para que no crea que debe poco) y un
   abono parcial se marca **"Parcial · abonó C$X de C$Y"**.
2. **Campo, sin señal:** visita al cliente → cobra una cuota (o varias con
   multi-select): monto, método (efectivo NIO/USD, transferencia), descuento
   pronto-pago o cargo de reconexión automáticos según settings, foto del
   comprobante → **todo se guarda en SQLite local al instante**.
3. Imprime el recibo en su térmica Bluetooth (GOOJPRT PT-210; 100% offline,
   logo cacheado en disco). En la oficina el mismo recibo sale por la térmica
   **USB** de la PC (ESC/POS crudo a la cola de Windows, en modo imagen o
   texto). El vuelto SIEMPRE en córdobas, aunque le paguen en dólares.
4. Si el cliente no está: registra una **visita** (resultado + nota).
5. **Vuelve la señal:** la cola CRUD sube sola → los triggers de Postgres
   recalculan la verdad (estado de cuota, recaudado) → el admin ve todo.
6. Su recibo lleva **correlativo propio** (prefijo por cobrador) y la mora
   se calcula en hora Nicaragua (UTC-6).

### La jornada del admin
0. Entra a una **galería de inicio**: una grilla de tarjetas con los módulos
   (clientes, mapa, reportes, dashboard…) en vez de un panel lateral. La card
   **"Cobranza"** abre una sub-galería (Centro de cobranza, Cobros, Avisos) y
   la card **"Administración"** la suya (personal, planes, geografía, red,
   etiquetas). La barra superior tiene volver-al-menú, avatar e indicador de
   sync.
1. Abre el **dashboard**: cobros hoy/semana/mes, mora, top cobradores,
   **proyección de cobros por cobrador** y recuperación por comunidad (cada
   sección la prende/apaga el super_admin por tenant).
2. Gestiona el catálogo: alta de cliente (nombre, cédula, teléfono, dirección
   y un **email opcional**) → contrato (plan + día de pago) → las **cuotas se
   generan solas** (trigger server, mes a mes).
3. Revisa **pagos** (puede anular con motivo — el pago queda preservado y la
   cuota se restaura), aplica cargos/descuentos, gestiona la mora. Para cobranza
   preventiva tiene la pantalla **Avisos** (clientes próximos a corte y en mora)
   y los **notifica por WhatsApp** — hoy gratis (deep link `wa.me` 1×1, manual,
   con plantillas editables); el envío automático por lote vía la **API paga de
   Meta** está construido pero **apagado** hasta el setup en Meta.
4. Da **flexibilidad al contrato** sin descuadrar la plata: **cambiar el día
   de pago** (cobra el "puente" de días prorrateados hasta el día nuevo) o
   **suspender temporalmente** un contrato (no se cobra el período pausado;
   sale de cobros/mapa; al reactivar reinicia limpio desde la fecha). Todo
   prorrateado por días reales y anclado al día de pago — nunca al mes
   calendario (detalle del modelo: `ARQUITECTURA.md` §3.5).
5. Organiza las **rutas/cobradores**: asigna el cobrador de una comunidad
   entera de una (pantalla **Rutas**) o reasigna en masa desde Clientes
   (seleccionar todos del filtro). El cobrador asignado solo define en qué
   lista/mapa aparece el cliente; **quién cobró** lo captura cada pago/recibo.
   Un cliente puede quedar **sin cobrador** ("admin-managed"): solo la oficina
   (admin/admin_cobranza) lo ve y le cobra, hasta asignarle uno.
6. Baja **reportes** en PDF y Excel (8 reportes + arqueo de caja con detalle
   USD), con cortes por día en hora Nicaragua.
7. Todo cambio sensible queda en el **change log** (quién, cuándo, qué) —
   accesible desde el **historial de cada entidad** (lista la intención del
   usuario, no el log crudo de la base). El super_admin elige qué campos se
   muestran por tipo de entidad desde Config.

### La jornada del técnico (módulo opcional tickets)
1. El admin crea un ticket (instalación/reparación/corte) y se lo asigna.
2. El técnico lo ve en su shell, va al campo, lo avanza
   (en progreso → en espera → resuelto) **offline**, con checklist, fotos y
   comentarios. El SLA corre con semáforo (y se pausa en "en espera").
3. Consume materiales de su **custodia** (ej. un router): el inventario se
   descuenta solo y el equipo queda instalado en el cliente.
4. Cortes masivos se agrupan en **incidentes**: el admin marca el nodo/hub/
   puerto caído y los clientes afectados se derivan de la topología de red.

### El mes del dinero (reglas inquebrantables)
El control de dinero es la razón de ser del producto. Las 10 invariantes
exactas viven en `AGENTS.md` § "Invariantes de dinero" (la #1: lo APLICADO a
la cuota es lo que cuenta como recaudado — nunca lo entregado ni el vuelto).
`supabase/tests/invariantes_dinero.sql` las verifica contra data real después
de cada deploy que toque dinero.

---

## 4. Mapa de módulos del producto (qué hay hoy)

**Base (todos los tenants):** clientes · contratos (con **cambio de día de
pago** y **suspensión temporal**, ambos prorrateados por días) · planes ·
cuotas · cobro en campo · **cobro extra puntual** (multa / otro cargo de una
vez, con recibo aparte) · pagos · recibos (térmica + PDF) · visitas · fotos ·
mora · **avisos (próximos a corte / mora) + notificación por WhatsApp** ·
**centro de cobranza** (métricas del día + colas de suspender/reactivar) ·
historial de pagos por cliente · reportes PDF+Excel · arqueo · mapa offline ·
dashboard (con proyección por cobrador) · geografía (depto→municipio→comunidad) ·
red (nodos→hubs→puertos) · **change log universal (`op_log`)** ·
settings per-tenant.

**Opcionales (toggle por tenant, vendibles por separado):**
- **Inventario**: catálogo (categorías/proveedores/productos), ubicaciones
  (bodega/técnico), seriales cuna-a-tumba, ledger de movimientos, stock mínimo.
- **Tickets + Técnicos + Incidentes**: ciclo de trabajo de campo completo con
  SLA, materiales y outages. Incluye el **reparto** (un coordinador asigna y
  ordena la cola; el técnico ve una orden por vez), el **retiro** de equipo
  desinstalado (va a revisión, no directo a bodega) y el **cierre del call
  center** (intentos de contacto registrados y, si el cliente no responde,
  cerrar sin confirmar con motivo — queda marcado para poder medirlo).

**Panel SaaS (`/super/*` + Config del tenant impersonado):** tenants, módulos,
miembros, impersonación, error logs de todos los clientes Flutter, y
**Operaciones de datos** (corregir errores de carga: limpiar/eliminar un cliente o
contrato, con vista previa del daño, copia de respaldo restaurable y registro).

**No implementado a propósito** (decisiones, no olvidos): geo del cobro
(lat/lng null), modo ruta planificada (mapa siempre libre), caja chica,
emails transaccionales (Resend en sandbox).

> El detalle técnico de cada módulo (archivos, providers, tablas, conexiones)
> vive en `ARQUITECTURA.md` §3 — con recetas de cambios comunes en §5.

---

## 5. Stack tecnológico y POR QUÉ cada pieza

**Plataformas objetivo: Android (cobrador/técnico) + Windows (admin)**,
distribución por APK + MSIX con auto-update vía GitHub Releases. Web existe
pero NO es target: el código degrada con `kIsWeb` sin romper.

| Capa | Tecnología | Por qué esta y no otra |
|---|---|---|
| UI | **Flutter** (Dart) | Un codebase para Android + Windows (+ web de cortesía). AOT nativo en móvil. Ecosistema maduro para Bluetooth térmico, mapas, cámara. |
| Estado | **Riverpod 2.x** | Providers tipados y testeables; `StreamProvider` se acopla natural a los streams de PowerSync; `autoDispose` controla memoria con muchos streams abiertos. |
| Navegación | **go_router** | URL como fuente de verdad; `redirect` centralizado = un solo lugar con la lógica "quién puede ir a dónde" (3 shells por rol + gates de sync/módulo/setting). |
| Backend | **Supabase** (Postgres 15 + Auth + Storage + Edge Functions Deno) | Postgres REAL: RLS nativo = multi-tenant físicamente imposible de violar desde el cliente; triggers = fuente de verdad del dinero; JSONB para settings flexibles. Hosted sin DevOps; open-source sin lock-in. |
| Sync | **PowerSync SELF-HOSTED** (VPS Hetzner propio desde 2026-07-13; el cloud de paga se retiró por costo — ARQUITECTURA §3.8) | Offline-first real: réplica SQLite local por usuario con queries arbitrarias (JOINs/GROUP BY offline); sync rules declarativas = control fino de qué baja a cada rol; conflictos: server gana, sin CRDTs. El VPS (~$6/mes) solo hace la bajada; auth/subida/fotos van directo a Supabase. |
| Impresión | `print_bluetooth_thermal` (Android/BT) + **`win32` escribiendo ESC/POS crudo en la cola de Windows** (USB) + ESC/POS **GS v 0 armado a mano** | Las térmicas chinas fallan con `imageRaster` de la lib; el raster manual con polaridad/ancho explícitos fue lo que imprimió bien (PT-210, v0.8.0). En Windows el driver reescalaba y suponía el papel, así que se manda el MISMO raster por datatype RAW (v0.29.6) y los dos transportes comparten el armado. Regla aprendida en campo (3nStar RPT004): estas impresoras **ignoran los comandos de posición** (`GS L`, `ESC $`, `ESC a`, `FS .`) → el contenido se ubica por conteo de chars/dots y el ancho imprimible se **mide** con la regla de Ajustes, no se estima. |
| Mapas | **flutter_map + OSM** + `flutter_map_cache` (tiles en disco) | Gratis, sin API key, offline en Android/Windows. FMTC descartado por conflicto de versiones. |
| Reportes | `pdf`/`printing` + **`excel`** + `file_picker.saveFile` | PDF y .xlsx generados en Dart puro, guardado con diálogo nativo. |
| Email | Resend (**sandbox, fuera del flujo operativo**) | El onboarding es sin email por decisión de producto. |

**Por qué la combinación funciona:** PowerSync + Riverpod + SQLite hacen el
offline-first sin esfuerzo por pantalla; RLS + JWT hacen el multi-tenant sin
esfuerzo por query; los triggers de Postgres hacen el dinero confiable sin
confiar en el cliente. El cliente **espeja** los triggers localmente
(`calcularEstadoCuota`) solo para que la UI sea instantánea offline — al
sincronizar, **el server siempre gana**.

### Números actuales (actualizar en releases mayores)
- Último release **v0.31.22** (único vigente en `sitecsa-updates`; se borra el
  anterior al publicar) · migraciones **0001→0219** (ya en prod) · sync rules
  desplegadas por SSH al VPS (15 buckets, uno por rol/shell) · instalación en PC
  nueva vía one-liner (ver `Install Steps/2`).
- **9 Edge Functions** + `_shared/` (5 de gestión de usuarios —invitar, cambiar
  email, forzar/ver password, eliminar— + crear-tenant + reenviar-invitacion +
  `whatsapp-set-token` + `whatsapp-enviar`).
- **`audit_log` ELIMINADO (0140):** el `op_log` (change log escrito por el
  cliente) es el único registro de cambios; ya no hay rastro forense server-side
  ni panel `/admin/audit`.
- Tests: ~600 en total, incluida la suite de dinero (`pagos_repo` contra
  PowerSync real) + los invariantes SQL contra data real.
- Los audits integrales son parte del proceso de cada sprint (Fase 4 de
  `AGENTS.md`); el protocolo adversarial de 4 especialistas vive en
  `AUDIT-PROFUNDO.md`, invocable pidiendo "audit profundo".

### Cuándo revisitar el stack
- 100+ tenants concurrentes → revisar plan de Supabase / caché.
- Primer sync lento con tenants enormes → afinar buckets/paginación de sync.
- Hoy ninguna alarma suena: el stack aguanta el MVP y los próximos 6-12 meses.

---

## 6. Principios de producto (los "no negociables")

1. **Offline-first**: el cobrador/técnico opera sin señal. Toda feature nueva
   que exija conexión sincrónica debe declararse explícitamente.
2. **Server gana**: Postgres es la fuente de verdad; el cliente espeja para
   UX instantánea, nunca para decidir.
3. **Multi-tenant con RLS**: toda tabla operativa nace con `tenant_id` + RLS.
4. **Trazabilidad universal**: toda entidad editable tiene change log
   (append-only) accesible desde su pantalla. El cliente registra la
   **intención** del usuario (una entrada por objeto afectado, con quién, cuándo
   y el antes→después de lo que tocó) en el momento de la acción — así el
   historial es fiel y funciona offline.
5. **Sin email en el onboarding**: password server-side por canal externo.
6. **Simple antes que elegante**: la opción más simple del stack existente
   que resuelva el problema; sin dependencias ni pasos manuales nuevos.
