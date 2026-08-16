# TRASPASO.md — Handoff de control total de CRM

> **Quién lee esto:** la persona que recibe el control total del producto **CRM** (Cobranza ISP). Es el documento que el dueño actual (Rubén) te entrega para que entiendas cómo está desarrollada la app, qué cuentas y secretos necesitás, cómo se compila/publica y qué NO podés romper.
>
> **Cómo usar este documento:** leelo entero una vez antes de tocar nada. Después seguí la **§10 Checklist de traspaso** paso a paso. Lo que diga `<entregar por canal seguro>` se pasa por pendrive/gestor de secretos, **nunca por chat ni email plano**.
>
> **Fuente de verdad viva del proyecto:** el repo privado del código (`Template-TT`) y, dentro de él, `BITACORA.md` → `AGENTS.md` → `ARQUITECTURA.md`. Este TRASPASO.md es el mapa de alto nivel; el detalle fino vive en esos docs (ver §9).

---

## 1. Resumen ejecutivo

**Qué es.** CRM (internamente "Cobranza ISP") es un **SaaS multi-tenant de cobranza para ISPs de Centroamérica** (Nicaragua). Permite a una empresa de internet gestionar clientes, contratos, cuotas, pagos, recibos, mora, suspensiones, tickets de soporte técnico y la operación de cobradores de campo.

**A quién sirve.** Es **white-label** y hoy tiene **2 tenants reales en producción con dinero real**:

| Tenant | Empresa | Clientes aprox. | Paquete (identity) |
|---|---|---|---|
| `mairena` | Telecable Mairena S.A. | ~4.606 | `com.sitecsa.crm.mairena` |
| `telenet` | Telenet | ~1.187 | `com.sitecsa.crm.telenet` |

**Roles del producto:**
- `super_admin` — el dueño del SaaS (vos, después del traspaso). Crea tenants, impersona, configura todo.
- `admin` / `admin_cobranza` — staff del ISP (gestión de cobranza).
- `cobrador` — personal de campo, **offline-first** (cobra sin internet).
- `tecnico` — módulo de tickets/soporte.

**Plataformas.** App **Flutter** para **Android** (cobradores en el celular) y **Windows** (administración en la oficina). No hay iOS ni web.

**Estado actual (al momento del traspaso).** Producto **en producción y estable**, versión **v0.17.2**. El onboarding es **SIN email** (la contraseña se entrega server-side por WhatsApp; no hay signup público). El canal de auto-update ya migró a un repo público separado para poder mantener el código privado. Hay un backup cifrado de los 3 secretos críticos.

---

## 2. Stack tecnológico y arquitectura

**Stack:**
- **Frontend:** Flutter (Android + Windows) · Riverpod (estado) · go_router (navegación).
- **Backend:** Supabase — Postgres + Auth + Edge Functions (Deno) + Storage + RLS. Proyecto único `vxxzesbmilfolwjhfxgr` ("Template TT") = **PRODUCCIÓN**.
- **Sync offline-first:** PowerSync (servicio SEPARADO, su propio dashboard) — replica el Postgres de Supabase y baja a cada dispositivo solo su "slice" según buckets por rol; cada cobrador tiene su SQLite local.
- **Distribución:** GitHub (2 repos) + APK firmado (Android) + MSIX self-signed (Windows) + auto-update casero.
- **Mapas:** OpenStreetMap + ArcGIS World Imagery vía `flutter_map`, **sin API key** (gratis).

**Diagrama de servicios y cómo se conectan:**

```
                    ┌────────────────────────────────────────────┐
                    │              DISPOSITIVO (app Flutter)        │
                    │   Android (cobrador) · Windows (admin)        │
                    │                                               │
                    │   ┌──────────────┐      ┌─────────────────┐   │
                    │   │ SQLite local │◄────►│  Riverpod / UI  │   │
                    │   │ (PowerSync)  │      └─────────────────┘   │
                    │   └──────┬───────┘                            │
                    └──────────┼───────────────────┬───────────────┘
                               │ sync (offline)     │ auth (login)
                               │                     │
                  access token │   ┌─────────────────▼─────────────┐
                  de Supabase  │   │   SUPABASE  vxxzesbmilfolwjhfxgr │
                  (JWT)        │   │   = PRODUCCIÓN                  │
                               │   │   ┌──────────┐  ┌────────────┐ │
                  ┌────────────▼─┐ │   │ Postgres │  │  Auth      │ │
                  │  POWERSYNC   │ │   │ (RLS x   │  │ (login SIN │ │
                  │  (instancia  │ │   │  tenant) │  │  email)    │ │
                  │   cloud)     │◄┼───┤          │  └────────────┘ │
                  │              │ │   │  réplica │  ┌────────────┐ │
                  │ valida el    │ │   │  lógica  │  │ 8 Edge Fns │ │
                  │ JWT contra   │ │   │  (WAL) ──┼──┤ (Deno)     │ │
                  │ JWKS de      │ │   └──────────┘  └────────────┘ │
                  │ Supabase     │ │   ┌──────────────────────────┐ │
                  └──────────────┘ │   │ 4 Buckets Storage priv.  │ │
                  sync-rules.yaml  │   │ (fotos/comprobantes/...)  │ │
                  (pegado A MANO   │   └──────────────────────────┘ │
                   en su dashboard)└────────────────────────────────┘

   AUTO-UPDATE (canal separado):
   app instalada ──HTTP──► github.com/<owner>/sitecsa-updates (PÚBLICO)
                           releases/latest/download/version-<slug>.json
                           + CRM-<slug>.{msix,apk}
   (la URL del owner está HARDCODEADA en lib/data/services/update_service.dart)

   CÓDIGO FUENTE: github.com/<owner>/Template-TT (PRIVADO, rama única main)
```

**Acoplamiento clave que NO se ve en el código:** la auth de PowerSync va por el **JWT de Supabase** (el connector manda el access token de la sesión directo), NO por el `POWERSYNC_TOKEN_ENDPOINT` que sugiere el `.env`. PowerSync valida ese JWT contra la JWKS de Supabase configurada **en su propio dashboard**. Si ese vínculo se rompe, la app loguea pero **no sincroniza** y el síntoma (todo offline) no apunta obvio a la causa.

---

## 3. Cuentas, servicios y accesos a transferir

> **Recomendación general:** donde se pueda, **TRANSFERIR ownership** en vez de crear cuentas nuevas. Transferir conserva keys, datos, historial y conexiones → muchísimo menos riesgo. Crear de cero rota TODAS las credenciales y obliga a rebuildear y reconfigurar todo.

| Servicio | Qué contiene | Cómo se transfiere | Criticidad |
|---|---|---|---|
| **Supabase — proyecto `vxxz`** (`vxxzesbmilfolwjhfxgr`) | TODO el backend: Postgres (150 migraciones, RLS), Auth (login sin email), 8 Edge Functions, 4 buckets Storage, crons, y **los datos reales de Mairena + Telenet** | Crear tu Organización en Supabase → Rubén mueve el proyecto a tu org (Project Settings → General → Transfer project). **Conserva** ref/URL, anon key, service_role, JWT secret, DB password, datos y Storage | 🔴 Crítico |
| **Supabase — Billing/Org** | Plan, límites (DB size, bandwidth, Edge invocations), método de pago | Va con la org destino; si está en plan pago, pasa a tu tarjeta | 🔴 Crítico |
| **PowerSync — instancia** | Sync offline-first: connection a Postgres, sync rules activas, config de auth (JWKS) | Confirmar si PowerSync permite transferir billing/owner; si no, **crear cuenta nueva** y reconstruir connection + sync rules + auth a mano (no hay CLI) | 🔴 Crítico |
| **GitHub — `sitecsa-updates`** (PÚBLICO) | Solo instaladores/releases; **canal de auto-update** de TODAS las apps | Transferir ownership (Settings → Transfer). **DEBE quedar PÚBLICO** | 🔴 Crítico |
| **GitHub — `Template-TT`** (PRIVADO) | Todo el código, docs, migraciones, scripts. Rama única `main` | Transferir ownership. Conserva historial, CI, releases. Mantener **PRIVADO** | 🔴 Crítico |
| **GitHub — cuenta + `gh` CLI** | Autenticación para publicar releases y correr scripts | Re-autenticar con tu cuenta: `gh auth login` (scopes `repo`+`workflow`). El token de Rubén NO se traspasa | 🟡 Importante |
| **Supabase Access Token (CLI)** | Permite correr migraciones/SQL desde la terminal sin pegar en el Dashboard | Es personal: lo generás vos en Account → Access Tokens y re-linkeás (`supabase link`) | 🟢 Opcional |
| **Meta Business / WhatsApp API** | Solo si activás el envío automático (hoy DORMIDO) | Crear cuenta nueva en Meta. No hay nada que transferir hoy | 🟢 Opcional |
| **Mapas (OSM/ArcGIS)** | Tiles de mapa | **Sin credencial.** No hay nada que transferir | 🟢 Opcional |
| **Email / Resend / SMTP** | — | **No existe.** Producto sin-email a propósito | 🟢 Opcional |

---

## 4. Secretos y credenciales

Esta app **NO guarda secretos en git**. Viven solo en disco y entran al build con `--dart-define-from-file=.env.json`. Son **3 archivos** + 1 token server-side.

### Los 3 archivos (gitignored — viven solo en disco de Rubén)

| Archivo | Qué es | Dónde va | Reemplazable |
|---|---|---|---|
| **`.env.json`** (raíz) | JSON con 4 claves: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `POWERSYNC_URL`, `POWERSYNC_TOKEN_ENDPOINT`. Lo lee `lib/config/env.dart`. Sin él la app abre en "Configuración pendiente" y `build-release.ps1` aborta | raíz del repo | ✅ Sí (se re-deriva de los dashboards de Supabase/PowerSync) |
| **`android/key.properties`** | Passwords del keystore: `storePassword`, `keyPassword`, `keyAlias=sitecsa`, `storeFile=sitecsa-release.jks`. Lo lee `android/app/build.gradle.kts` | `android/` | ✅ Sí (si generás keystore nuevo) |
| **`android/app/sitecsa-release.jks`** | **Keystore RSA-2048 (validez ~30 años, alias `sitecsa`)** que firma TODOS los APK de release | `android/app/` | ❌ **IRREEMPLAZABLE** |

> 🔴 **EL KEYSTORE ES IRREEMPLAZABLE.** Android exige que cada update esté firmado con la **misma** llave. Si se pierde el `sitecsa-release.jks` o firmás con otro, **ningún Android ya instalado vuelve a actualizarse jamás** — habría que desinstalar/reinstalar perdiendo la base offline de cada cobrador. Apenas lo recibas, **backupealo fuera de la PC** (pendrive/vault).

### Backup cifrado existente

Hay un **`.7z` AES-256** con los 3 secretos juntos en `C:\Users\ruben\sitecsa-key-backup\` (fuera de OneDrive). Es la red de seguridad del `.jks`. **Recibilo o recreá el tuyo** y guardalo offline. La **passphrase del `.7z`** se entrega por un canal SEPARADO del archivo.

### Secretos server-side (NO en archivos)

- **`SUPABASE_SERVICE_ROLE_KEY`** — bypassa RLS. Lo **inyecta Supabase** en las Edge Functions; NO va en `.env.json`. ⚠️ Aparece **hardcodeado como literal** dentro del cron `whatsapp-lote-hourly` (ver `Install Steps/WhatsApp-API-setup.md`): si algún día rotás esa key, hay que re-editar ese cron. Si se transfiere el proyecto, no cambia.
- **`whatsapp_credenciales`** — Access Token de Meta por tenant. Vive en una tabla server-only (sin policies, no sincronizada). Hoy **vacío/dormido**.

### Valores para entregar

```
.env.json:
  SUPABASE_URL           = https://vxxzesbmilfolwjhfxgr.supabase.co
  SUPABASE_ANON_KEY      = <entregar por canal seguro>  (anon/public, va baked en el binario)
  POWERSYNC_URL          = <entregar por canal seguro>  (Instance URL de PowerSync)
  POWERSYNC_TOKEN_ENDPOINT = <entregar por canal seguro>  (vestigial — ver nota §7)

android/key.properties:
  storePassword = <entregar por canal seguro>
  keyPassword   = <entregar por canal seguro>
  keyAlias      = sitecsa
  storeFile     = sitecsa-release.jks

android/app/sitecsa-release.jks  = <archivo físico por canal seguro — IRREEMPLAZABLE>

Passphrase del backup .7z        = <entregar por canal SEPARADO del archivo>
```

---

## 5. Cómo compilar y publicar una versión

> **Doc de referencia obligatoria:** `Install Steps/0-Setup-PC-desarrollo.md` (setup de la PC) y `Install Steps/1-Publicar-nueva-version.md` (flujo de release). Esto es el resumen.

**Requisitos de la PC de build:** Flutter stable (alineado al CI: **3.41.9** — ver `.github/workflows/ci.yml`; NO instalar el último a ciegas, el choque `intl 0.20.2` vs `0.19.0` rompe `flutter pub get`), Visual Studio 2022 con "Desktop development with C++", Android Studio (SDK + JDK 17), PowerShell 7+ (`pwsh`), `gh` CLI autenticado, y los **3 secretos** colocados.

**Flujo de release (orden importa — PROD primero):**

1. **Bump de versión** en `pubspec.yaml` (`X.Y.Z`).
2. **Migraciones SQL** (si las hay) contra `vxxz` ANTES del build: `supabase db query --linked -f supabase\migrations\NNNN_*.sql`, y **verificar** con una query (nunca asumir que corrió).
3. **Sync rules** (si tocaste tablas/columnas): copiar `powersync/sync-rules.yaml` al dashboard de PowerSync y dejarlo **"Active"**. ⚠️ Es el **único paso manual** del release que no se automatiza.
4. **Build + release en un comando:**
   ```
   pwsh "Install Steps\build-release.ps1" -AllTenants
   ```
   El script: buildea Windows (MSIX) + Android (APK) por tenant, aplica el branding (`branding/<slug>/`), bakea `.env.json` y `--dart-define=TENANT=<slug>`, reescribe los `version-<slug>.json` con las URLs del repo público y publica el GitHub Release con assets de **nombre FIJO**. Pre-chequea `.env.json` y `key.properties` y **aborta** si faltan.
   - Default `-Repo 'rubenmaltez/sitecsa-updates'` → **cambialo a tu owner** (ver §10).
   - Usá **siempre** `-Tenant <slug>` o `-AllTenants` (el canal genérico está deprecado).
5. **Verificar invariantes de dinero** si el cambio tocó plata: `supabase/tests/invariantes_dinero.sql` → toda fila `violaciones = 0`.
6. **Instalar en cliente:** el cliente corre **como ADMIN** `install-<tenant>.ps1` (descarga el MSIX, confía el cert self-signed, instala). El doble-clic al `.msix` NO alcanza (paquete desconocido).

> **GATE de build fresco (TESTING.md §0.0):** el `.exe` NO cambia de fecha al recompilar (es el shell C++). Para confirmar que buildeaste lo nuevo, mirá `data/app.so`, no el timestamp del `.exe`. Saltarse esto = testear la app vieja y diagnosticar un bug-fantasma.

---

## 6. Arquitectura de datos e INVARIANTES críticos

> ⚠️ **Leé esta sección y la `ARQUITECTURA.md §3.5` ANTES de tocar cualquier lógica de dinero.** Hay 2 ISPs reales en producción; un cambio mal hecho les descuadra la caja real.

### Multi-tenant con RLS
Toda tabla operativa tiene `tenant_id NOT NULL` + policies por `current_tenant_id()`. Un tenant **jamás** ve data de otro (aislamiento físico en Postgres). El `super_admin` bypassa con `is_super_admin()`. **Toda tabla tenant-scoped DEBE nacer con la policy `super_admin_all` a mano** — sin ella el super_admin impersonando no puede escribir. El branding white-label es 100% cosmético; la RLS sigue aislando.

### Offline-first + `op_log`
El cobrador opera SIN internet (SQLite local, la cola sube sola al volver la señal). **"Server gana":** Postgres es la fuente de verdad; el cliente solo **espeja** triggers para UX instantánea. El historial de cambios es **`op_log`** (append-only, escrito por el cliente, 1 fila por objeto afectado). Nunca se borran rows; para deshacer se agregan nuevas. El `audit_log` forense server-side **fue eliminado (0140)** → `op_log` es el ÚNICO registro (trade-off aceptado: no es tamper-proof). Toda entidad editable nueva DEBE emitir `op_log`.

### Invariantes de dinero (NUNCA violar — son la base del negocio)
1. `pagos.monto_cordobas` = lo **APLICADO** a la cuota (lo que entra a caja). **Nunca** lo entregado por el cliente ni el vuelto.
2. `pagos.vuelto_cordobas` = lo devuelto, **siempre en córdobas** (aunque paguen en USD).
3. `monto_original × tasa ≈ monto_cordobas + vuelto_cordobas`.
4. Dos métricas separadas: **`recaudado_caja`** (plata real que entró) vs **`cobertura_cuota`** (cuánto de la cuota está cubierto). El **crédito por excedente NO es un pago** → por diseño no toca `pagos` ni aparece en métricas de caja.
5. **Total de contrato fijo = `precio_mensual × meses`** (nunca la suma de cuotas).
6. Contratos indefinidos: solo "total recaudado", no hay "pendiente".
7. `cuota.monto_pagado` lo mantiene un **trigger server**; el cliente nunca lo calcula a mano.
8. Anular un pago **restaura** la cuota (trigger) y **preserva** el pago.
9. Cargos manuales cuentan para recaudado, NO para el total fijo.
10. **Consistencia cross-pantalla:** el saldo/recaudado debe dar IDÉNTICO en todas las pantallas (fórmula canónica `monto + COALESCE(cargos_neto,0) − monto_pagado`).
11. **Oldest-first:** no se cobra una cuota dejando atrás una más vieja pendiente del mismo contrato.

### El modelo de negocio: facturación VENCIDA + anclaje al `dia_pago`
La app factura **vencido** (la cuota se cobra al final del período de servicio). **Regla de oro:** todo prorrateo/ciclo (suspensión, cambio de fecha, "qué cubre esta cuota") se ancla a la **ventana de servicio del `dia_pago`** (`ventanaServicio`/`estadoServicio` en `lib/data/utils/prorrateo.dart`), **NUNCA al mes calendario**. Solo coinciden si `dia_pago = 1`; con cualquier otro día, anclar al calendario sub/sobre-cobra. **Probá siempre con `dia_pago ≠ 1`** — con `= 1` el bug es invisible (bug real ocurrió el 2026-06-16).

### Reglas SQLite ≠ Postgres
El cliente corre **SQLite** (sin `FILTER`/`::casts`/`ILIKE`/`RETURNING`/`ANY`/`ARRAY`, que son Postgres-only). Lógica de límite de día (vencidas/mora/gracia/"hoy") usa **`date('now','-6 hours')`** nunca pelado (SQLite es UTC, Nicaragua es UTC-6 sin DST). `lower()`/`upper()` de SQLite son **ASCII-only**: para texto español (ñ/acentos) usar `foldBusqueda`/`foldSqlExpr` (`lib/data/utils/busqueda_cliente.dart`) o el registro queda **invisible** (bug real v0.13.3). Son falsos negativos/sobre-cobros **silenciosos** que no tiran error.

---

## 7. Integraciones externas

| Integración | Estado | Detalle |
|---|---|---|
| **Mapas (OSM + ArcGIS)** | 🟢 **Activa** | `flutter_map` con tiles públicos gratuitos, **sin API key**. Caché en disco. No hay Google Maps/Mapbox. A gran escala los servidores públicos podrían throttlear |
| **WhatsApp modo gratis (`wa.me`)** | 🟢 **Activa** | El canal REAL de notificación hoy: abre `wa.me/<n>?text=...` con mensaje prellenado. Sin cuenta de Meta, sin credencial (`lib/data/services/external_actions.dart`) |
| **WhatsApp Cloud API (Meta)** | 🟡 **DORMIDA** | Construida pero sin cuenta de Meta, sin functions deployadas, sin cron creado. Activarla requiere: verificación de negocio en Meta, número WhatsApp Business, **Access Token permanente** (System User), 2 plantillas aprobadas, deployar 2 functions y crear el cron. Guía: `Install Steps/WhatsApp-API-setup.md` |
| **Email / Resend / SMTP** | ⚫ **No existe** | Producto sin-email a propósito. Onboarding y passwords por WhatsApp. Resend está parqueado |
| **PowerSync auth endpoint** | ⚫ **Vestigial** | `POWERSYNC_TOKEN_ENDPOINT` apunta a una Edge Function `powersync-auth` que **NO existe** y **NO se usa**. Solo sirve para que `Env.isConfigured` no falle. La auth real va por el JWT de Supabase (ver §2). **No pierdas tiempo "arreglando" ese endpoint** |

---

## 8. Operación y mantenimiento (runbook)

### Los tenants reales
- **Mairena** (~4.606) fue **importado por SQL desde un Excel** de su sistema viejo → sus clientes no tienen contratos/cuotas/`op_log` iniciales. **Eso NO es un bug, no lo "arregles".**
- `vxxz` **ES PRODUCCIÓN**: no hay una 2ª base PROD aparte. Cada migración/UPDATE/borrado pega en usuarios reales al instante.

### Dónde mirar logs / diagnosticar
- **Errores de backend / Edge Functions:** Dashboard de Supabase → Logs y la pestaña de cada Edge Function.
- **Sync caído (app loguea pero no baja datos):** revisar en el dashboard de PowerSync que (a) la connection a Postgres esté viva, (b) las sync rules estén **"Active"** e iguales a `powersync/sync-rules.yaml`, (c) la **auth/JWKS** apunte al proyecto Supabase correcto.
- **Historial de cambios de una entidad:** `op_log` (visible en la app, pantalla de historial de cada entidad).

### Corregir DATA en producción (vía SQL)
Seguí **`Troubleshooting SQL/GUIA-TROUBLESHOOTING-SQL.md`** al pie. Reglas no negociables:
- Fix en **1 transacción**, con **`tenant_id` en TODO `WHERE`** (es el único cinturón contra tocar data de otro ISP — la RLS NO frena al rol privilegiado).
- **Nunca** tocar columnas derivadas a mano (los triggers recalculan solos).
- **Soft-delete**, no `DELETE`.
- Tras tocar plata: correr **`supabase/tests/invariantes_dinero.sql`** y verificar `violaciones = 0`. (Ojo: hay violaciones pre-existentes conocidas en el Test Tenant que NO deben confundirse con un bug nuevo en los tenants reales.)

### Crons activos en la DB
`generar_cuotas_mensual`, `actualizar_notificaciones_mora_diario` (en migraciones) y `whatsapp-lote-hourly` (manual, dormido). Los crons a medianoche Nicaragua corren a **06:05 UTC**.

### Reportería: cuidado con `cobrador_id`
`clientes.cobrador_id` es **organizativo** (en qué lista/mapa aparece). QUIÉN cobró lo captura `pagos.cobrador_id` y TODA la reportería agrupa por ese campo. **Reasignar un cliente NO altera el historial de quién cobró.**

---

## 9. Mapa de documentación del repo

> Todo vive en el repo PRIVADO `Template-TT`. Si el traspaso del repo falla, se pierde TODA la base de conocimiento (no hay copia externa). Leé en este orden:

| # | Documento | Qué responde |
|---|---|---|
| 1 | **`BITACORA.md`** | ¿Dónde quedamos? Estado vivo + historial de cambios. **Leer PRIMERO** |
| 2 | **`AGENTS.md`** | Reglas, invariantes, proceso de trabajo de 6 fases, checklist de audit |
| 3 | **`PRODUCTO.md`** | Qué es la app, misión, roles, día a día, stack y porqués |
| 4 | **`ARQUITECTURA.md`** | Cómo está construida + **§3.5 el modelo de dinero** + recetas de cambios R1-R20 (§0 índice) |
| 5 | **`TESTING.md` §0** | Loop de testing manual + GATE de build fresco |
| 6 | **`Install Steps/`** | Setup de PC, build, release, instalación |
| 7 | **`Troubleshooting SQL/`** | Corregir data de un tenant en prod vía SQL |
| 8 | `CLAUDE.md` | Shim de 1 línea (`@AGENTS.md`) — no editar |

`docs/archive/` = históricos solo para arqueología, no mantener.

---

## 10. Checklist de traspaso

**Cuentas y ownership**
- [ ] Crear tu Organización en **Supabase** y recibir la transferencia del proyecto `vxxz` (Project Settings → Transfer project).
- [ ] Hacerte cargo del **billing** de la org de Supabase (verificar uso real de DB/bandwidth antes — ya hubo presión de límites).
- [ ] Recibir transferencia (o crear+reconfigurar) la **instancia de PowerSync**: connection a Postgres, sync rules "Active", auth/JWKS al proyecto Supabase.
- [ ] Recibir transferencia del repo **`sitecsa-updates`** (PÚBLICO) y del repo **`Template-TT`** (PRIVADO).
- [ ] `gh auth login` con tu cuenta (scopes `repo`+`workflow`).
- [ ] `git remote set-url origin https://github.com/<tu-owner>/Template-TT` en el clon local.

**Secretos**
- [ ] Recibir por canal seguro: `.env.json`, `android/key.properties`, `android/app/sitecsa-release.jks`, y la **passphrase del `.7z`** (canal separado).
- [ ] **Backupear el `.jks` fuera de la PC** (pendrive/vault) apenas lo recibas.
- [ ] Generar tu **Supabase Access Token** de CLI y `supabase link`.

**Continuidad de identidad (NO romper)**
- [ ] **No cambiar** `applicationId` / `msixIdentity` / `publisher` de los tenants distribuidos (`com.sitecsa.crm.mairena`, `com.sitecsa.crm.telenet`, `CN=Msix Testing...`). Son INVARIANTES de auto-update.
- [ ] **No bumpear** el paquete `msix` (pin `3.16.13`) sin verificar que el test-cert/publisher no cambió.
- [ ] **No re-firmar** Android con otro keystore ni Windows con otro cert sin un plan de migración (rompe el auto-update de los usuarios reales).

**Re-apuntar el canal de auto-update (si cambiás de owner)**
- [ ] **Plan de corte (orden importa):** primero publicar UNA versión apuntando al repo viejo/transferido para que TODAS las apps actualicen; **recién después** cambiar el owner. Si lo hacés al revés, las apps que no actualizaron quedan huérfanas.
- [ ] Editar el owner hardcodeado en **`lib/data/services/update_service.dart:64`** (`<owner>/sitecsa-updates`).
- [ ] Ajustar el owner en los scripts: `build-release.ps1` (default `-Repo`), `install-mairena.ps1`, `install-telenet.ps1` (un `grep` de `rubenmaltez` lista los ~13 archivos).
- [ ] **Borrar `release.ps1`** (legacy, apunta al repo privado con nombres de asset viejos — si lo corrés por error publicás al canal equivocado).

**Validación**
- [ ] Setup de PC (`Install Steps/0-Setup-PC-desarrollo.md`), `flutter pub get`, `flutter run -d windows`, `flutter test` en verde.
- [ ] Hacer un release de prueba con `build-release.ps1 -AllTenants` y confirmar que el `msix:create` no falla por el `publisher`.
- [ ] Correr `supabase/tests/invariantes_dinero.sql` → `violaciones = 0` en los tenants reales.

**Conocimiento**
- [ ] Leer los 8 docs en el orden de §9. Interiorizar §6 (invariantes + anclaje al `dia_pago`) ANTES de tocar dinero.

---

## 11. Riesgos conocidos y limitaciones

1. 🔴 **Keystore Android irreemplazable.** `sitecsa-release.jks` + `key.properties` están gitignored y hoy viven SOLO en el disco de Rubén (+ el `.7z`). Si el traspaso no los incluye, ningún Android vuelve a actualizarse.
2. 🔴 **Owner del auto-update hardcodeado en el binario.** `update_service.dart:64` tiene `rubenmaltez/sitecsa-updates` compilado en cada app instalada. Cambiar de owner sin un release-puente que migre primero las apps las deja sin updates para siempre.
3. 🔴 **`sitecsa-updates` debe quedar PÚBLICO.** Si en la transferencia queda privado, la app no puede bajar los assets sin login → auto-update muere **en silencio** (el error se atrapa y retorna null).
4. 🔴 **`vxxz` ES PRODUCCIÓN, no DEV.** No hay 2ª base PROD. Cualquier error de migración/UPDATE/borrado impacta a usuarios reales al instante.
5. 🟡 **Acoplamiento Supabase↔PowerSync invisible.** PowerSync valida el JWT contra la JWKS de Supabase desde SU dashboard. Olvidar reconfigurarlo (si se crea proyecto nuevo) deja la app logueando pero **sin sincronizar**, y el síntoma no apunta a la causa.
6. 🟡 **Deploy de Edge Functions 100% manual.** No hay `config.toml` ni pipeline: cada función se deploya pegando su `index.ts` en el Dashboard. El `_shared/` está **bundleado por función** → un fix en `passwords.ts` obliga a re-deployar TODAS las que lo importan.
7. 🟡 **Sync rules sin CLI.** `powersync/sync-rules.yaml` está versionado pero su activación es copy-paste manual al dashboard ("Active"). El dashboard puede quedar desincronizado del repo sin que nadie lo note hasta que falten datos.
8. 🟡 **Volumen / free-tier PowerSync.** El bucket `por_cobrador` baja TODO el tenant a CADA dispositivo → el volumen escala con clientes × cobradores. Ya se rozó el free (2GB) una vez. Tener plan/alerta antes de onboardear tenants grandes.
9. 🟢 **`msix` pineado `3.16.13` sin `^`.** Un upgrade descuidado puede cambiar el test-cert y por ende el publisher → el build falla por mismatch (protección intencional) o, si se fuerza, rompe los updates de Windows.
10. 🟢 **Tiles de mapa son servidores públicos gratuitos** (OSM/ArcGIS) sin contrato ni API key. A gran escala podrían rate-limitear o cambiar política. No rompe hoy, pero es una dependencia no contractual.
11. 🟢 **Passwords solo portables Supabase↔Supabase.** Los hashes bcrypt viven en `auth.users`; una transferencia (o proyecto nuevo Supabase) los conserva, pero una salida a self-host/VPS los pierde — y los usuarios no tienen email para recuperarlas (onboarding sin email).
12. 🟢 **`TESTING.md §1` desactualizado** (menciona "25 migraciones"; el repo va por 0150+). La fuente real del orden es la carpeta `supabase/migrations/` completa.

---

> **Última nota.** Lo más fácil de subestimar en este traspaso no son las cuentas, son **los invariantes de dinero y el anclaje al `dia_pago`** (§6). Hay caja real de 2 ISPs detrás de cada cambio. Cuando dudes, leé `ARQUITECTURA.md §3.5`, probá con `dia_pago ≠ 1` y corré `invariantes_dinero.sql` antes de publicar.