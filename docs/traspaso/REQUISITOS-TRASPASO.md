# Análisis de Requisitos de Traspaso — CRM
## Qué necesita el nuevo dueño para que la app siga funcionando

> Este documento responde, por apartado, qué requisitos debe cumplir el nuevo dueño. Está basado en el inventario de los 8 especialistas. La decisión transversal #1 es: **TRANSFERIR ownership de las cuentas existentes en vez de re-crearlas** — recrear rota todas las keys y obliga a rebuild+redistribución de las apps en campo (Mairena ~4.606 clientes, Telenet ~1.187).

---

## 1. Tabla maestra — por apartado: transferir / re-crear / entregar credencial

| # | Apartado | Componente | Acción recomendada | Severidad |
|---|---|---|---|---|
| 1 | **GitHub** | Repo público `sitecsa-updates` (canal auto-update) | **Transferir ownership** (mantener PÚBLICO) | 🔴 Crítico |
| 2 | **GitHub** | Repo privado `Template-TT` (código + 8 docs) | **Transferir ownership** (mantener PRIVADO) | 🔴 Crítico |
| 3 | **GitHub** | Owner hardcodeado `rubenmaltez/sitecsa-updates` en `update_service.dart:64` | **Re-deploy** (editar línea + rebuild de los 3 builds: genérico/mairena/telenet) | 🔴 Crítico |
| 4 | **GitHub** | `gh` CLI (token de Rubén, keyring) | **Re-crear** (`gh auth login` con cuenta nueva) | 🟡 Importante |
| 5 | **GitHub** | Remoto local `origin` + scripts (`build-release.ps1 -Repo`, `install-*.ps1`) | **Re-deploy** (`git remote set-url`; grep `rubenmaltez` → 13 archivos) | 🟡 Importante |
| 6 | **GitHub** | `release.ps1` legacy (apunta al repo privado, deprecado) | **Borrar** en el traspaso | 🟢 Opcional |
| 7 | **Supabase** | Proyecto `vxxz` (Postgres + Auth + Edge + Storage + datos reales) | **Transferir ownership** (org → org; conserva keys/JWT/datos/Storage) | 🔴 Crítico |
| 8 | **Supabase** | Billing / plan de la org | **Transferir ownership** (tarjeta nueva) | 🔴 Crítico |
| 9 | **Supabase** | Keys (anon, service_role, JWT secret, DB password) | **Entregar credencial** (no cambian si se transfiere; se leen del Dashboard) | 🔴 Crítico |
| 10 | **Supabase** | Access Token del CLI (personal) | **Re-crear** (cada uno genera el suyo) | 🟡 Importante |
| 11 | **Supabase** | 8 Edge Functions (deploy manual por Dashboard) | **Transferir** las trae deployadas; **re-deploy** solo si se recrea proyecto | 🟡 Importante |
| 12 | **Supabase** | Datos de los 2 tenants + 4 buckets de Storage | **Transferir ownership** (viajan adentro del proyecto) | 🔴 Crítico |
| 13 | **Supabase** | Crons (`pg_cron`/`pg_net`) + token Meta en `whatsapp_credenciales` | **Transferir** (quedan tal cual); **re-crear** solo si proyecto nuevo | 🟡 Importante |
| 14 | **PowerSync** | Cuenta + instancia (servicio separado, sin CLI) | **Transferir** si lo permite el billing; si no, **re-crear** instancia | 🔴 Crítico |
| 15 | **PowerSync** | Conexión por replicación lógica a Supabase | **Re-deploy** si se recrea (publication + replication slot) | 🔴 Crítico |
| 16 | **PowerSync** | Sync rules (`powersync/sync-rules.yaml`) | **Re-deploy MANUAL** (copy-paste → "Active"; único paso no automatizable) | 🔴 Crítico |
| 17 | **PowerSync** | Auth = JWT de Supabase (JWKS), NO el token-endpoint del `.env` | **Re-deploy** (apuntar JWKS/issuer a la Supabase nueva, solo si JWT rota) | 🔴 Crítico |
| 18 | **PowerSync** | `POWERSYNC_URL` (bakeado en el binario) | **Entregar credencial** + rebuild si cambia la instancia | 🔴 Crítico |
| 19 | **Firma Android** | `sitecsa-release.jks` (keystore único, RSA-2048) | **Entregar archivo físico** (IRREEMPLAZABLE, gitignored) | 🔴 Crítico |
| 20 | **Firma Android** | `android/key.properties` (passwords del keystore) | **Entregar archivo físico** (canal seguro, junto al `.jks`) | 🔴 Crítico |
| 21 | **Firma Windows** | Publisher MSIX `CN=Msix Testing…` + `msix` pineado 3.16.13 | **No tocar** (invariante; no hacer `pub upgrade msix`) | 🔴 Crítico |
| 22 | **Firma/distribución** | `applicationId`/`identity_name` de los 3 tenants | **No tocar** (INVARIANTES de continuidad) | 🔴 Crítico |
| 23 | **Secrets** | `.env.json` (SUPABASE_URL/ANON, POWERSYNC_URL/TOKEN_ENDPOINT) | **Entregar archivo físico** (gitignored, canal seguro) | 🔴 Crítico |
| 24 | **Secrets** | Backup cifrado `.7z` AES-256 (los 3 secretos) | **Entregar credencial** (+ passphrase por canal separado) | 🟡 Importante |
| 25 | **Servicios ext.** | WhatsApp Cloud API (Meta) — DORMIDO | **Re-crear** solo si se activa (trabajo nuevo de Meta) | 🟢 Opcional |
| 26 | **Servicios ext.** | Mapas (OSM + ArcGIS, sin API key) | **Nada** (sin credencial; tiles públicos) | 🟢 Opcional |
| 27 | **Servicios ext.** | Email / Resend / SMTP | **Nada** (no existe; producto sin-email a propósito) | 🟢 Opcional |
| 28 | **Entorno dev** | Toolchain (Flutter **3.41.9**, VS2022 C++, Android SDK + JDK 17, PS7, gh) | **Re-crear** (instalar en PC nueva; NO hay pin de versión en el repo) | 🔴 Crítico |
| 29 | **Conocimiento** | 8 docs del repo (AGENTS/PRODUCTO/ARQUITECTURA §3.5/BITACORA/TESTING/Troubleshooting SQL) | **Entregar credencial** (viven SOLO en `Template-TT` privado) | 🔴 Crítico |
| 30 | **Conocimiento** | 11 invariantes de dinero + anclaje al `dia_pago` + `invariantes_dinero.sql` | **Entregar credencial** (leer ANTES de tocar plata) | 🔴 Crítico |

---

## 2. Lo IRREEMPLAZABLE ⚠️

Esto **no se regenera**: si se pierde, hay daño permanente, no un "rehacer".

| Activo | Dónde vive hoy | Qué pasa si se pierde |
|---|---|---|
| **`android/app/sitecsa-release.jks`** (keystore Android, alias `sitecsa`, válido ~30 años) | Disco del worktree principal de Rubén + backup `.7z`. **Gitignored, NO en GitHub.** | **NINGÚN Android instalado (Mairena/Telenet) se vuelve a actualizar JAMÁS.** Firma distinta = Android rechaza el update como app distinta → hay que desinstalar/reinstalar **perdiendo la DB offline de cada cobrador**. `keytool` solo genera uno NUEVO, no recupera este. |
| **`android/key.properties`** (passwords del keystore) | Junto al `.jks`, gitignored. | Sin él el `.jks` es inútil (no se puede firmar); el build cae a firma DEBUG. |
| **Passwords de login** (hashes bcrypt en `auth.users`) | Solo dentro de Supabase. | Viajan bien Supabase→Supabase, pero se **pierden al salir a self-host/VPS**. Como el onboarding es **sin email**, no hay recuperación → habría que re-setear la contraseña de TODOS los usuarios a mano. |
| **Datos + Storage de los 2 tenants** | Solo en el Postgres/Storage de `vxxz`. | Las 150 migraciones recrean el ESQUEMA, **no los datos** (Mairena importado por SQL desde Excel) ni los archivos (fotos/comprobantes/logos/PDFs). Solo viajan si se **transfiere** el proyecto. |
| **El propio repo `Template-TT`** (8 docs + historial) | GitHub privado de Rubén. | Es la **única** copia de toda la base de conocimiento (invariantes, recetas, BITACORA). Sin copia externa. |

**Acción inmediata recomendada:** sacar el backup `.7z` de `C:\Users\ruben\sitecsa-key-backup\` a un **pendrive/vault offline** ANTES del traspaso (hoy está solo en la PC; un formateo lo destruye), y entregar la passphrase por canal separado del archivo.

---

## 3. Orden de traspaso recomendado (secuencia para que nada se rompa)

La lógica: **migrar las cuentas conservando identidad → recién al final tocar el código del canal de update**, para que ninguna app en campo quede huérfana en el medio.

**Fase A — Preparación (antes de tocar nada)**
1. Backup del `.7z` (jks + key.properties + .env.json) a vault/pendrive offline.
2. El nuevo dueño crea su **cuenta GitHub**, su **org Supabase** y su **cuenta PowerSync**.
3. Decidir el **handle de GitHub definitivo** del nuevo dueño AHORA (queda horneado en `update_service.dart`).

**Fase B — Transferir ownership (conserva keys, evita rebuilds)**
4. **Supabase**: transferir el proyecto `vxxz` org→org (`Project Settings → Transfer`). Conserva ref/URL, anon, service_role, JWT secret, DB password, datos y Storage. → No hay que tocar `.env.json` ni reconfigurar PowerSync.
5. **Billing Supabase**: pasar el método de pago a la org nueva.
6. **PowerSync**: transferir billing/owner si lo permite; verificar que la Connection siga apuntando a `vxxz` y la auth (JWKS) al mismo proyecto. Confirmar sync rules en "Active".
7. **GitHub**: transferir `Template-TT` (privado) y `sitecsa-updates` (público). El público DEBE seguir público.

**Fase C — Entregar secretos físicos (canal seguro)**
8. Entregar `.env.json`, `android/key.properties`, `android/app/sitecsa-release.jks` (USB/vault, nunca git/chat/email). Passphrase del `.7z` por canal separado.

**Fase D — Setup de la PC de build**
9. Clonar `Template-TT` (ya transferido), colocar los 3 secretos en sus rutas, `git remote set-url origin <nuevo>/Template-TT`.
10. Instalar toolchain alineado al CI: **Flutter 3.41.9**, VS2022 + C++, Android SDK + JDK 17, PowerShell 7, `gh auth login` con la cuenta nueva.
11. `flutter pub get` → `flutter test` → `flutter run -d windows` para validar.

**Fase E — Corte del canal de auto-update (lo último)**
12. **Si el owner del repo cambia**: primero publicar un release apuntando al repo viejo/transferido para que TODAS las apps migren; **recién después** editar `update_service.dart:64` + `build-release.ps1 -Repo` + `install-*.ps1` al owner nuevo y rebuildear.
13. `Install Steps/build-release.ps1 -AllTenants` (genera mairena + telenet con sus `version-<slug>.json`).
14. **Verificar auto-update**: instalar una app branded, confirmar que el banner de update ve el release nuevo desde el repo público.

**Fase F — Conocimiento (en paralelo, antes de tocar plata)**
15. Leer en orden: `BITACORA.md` → `AGENTS.md` → `PRODUCTO.md` → `ARQUITECTURA.md §3.5` → `TESTING.md §0` → `Troubleshooting SQL/`. Memorizar los 11 invariantes y el anclaje al `dia_pago`.

---

## 4. Trampas / gotchas más probables (específicas de esta app)

1. **El owner del auto-update está COMPILADO en cada app** (`update_service.dart:64` = `rubenmaltez/sitecsa-updates`). Cambiar de owner sin un **release-puente que migre primero** deja las apps en campo huérfanas para siempre → reinstalación manual de cada dispositivo. Plan de corte: migrar apps primero, cambiar owner después.

2. **El repo `sitecsa-updates` DEBE quedar PÚBLICO.** Si en la transferencia queda privado, la app no puede bajar los assets de `releases/latest/download/` sin login → `checkForUpdate` atrapa el error y retorna `null` → **el update falla en silencio**, sin aviso al usuario.

3. **El redirect de GitHub es frágil.** Transferir crea un redirect del owner viejo, pero se **rompe** si alguien re-crea un repo con el mismo nombre en la cuenta vieja. No depender de él a largo plazo: migrar la URL en el código.

4. **La auth de PowerSync NO usa el `POWERSYNC_TOKEN_ENDPOINT` del `.env`.** Esa Edge Function `powersync-auth` **no existe en el repo**: el connector firma con el `session.accessToken` de Supabase directo (JWKS). Si el nuevo dueño "sigue el `.env`" pierde tiempo buscando/creando un endpoint inútil. Lo que importa: apuntar la integración de auth del **dashboard de PowerSync** a la JWKS de la Supabase correcta. Si el JWT secret rota (proyecto nuevo), **la app loguea pero NADIE sincroniza** y el síntoma (todo offline) no apunta obvio a un JWT viejo.

5. **`service_role` HARDCODEADO en el cron `whatsapp-lote-hourly`** (`Install Steps/WhatsApp-API-setup.md`). Si se recrea el proyecto y se olvida actualizar ese literal, el cron autentica con una key muerta. Rotar el service_role obliga a re-editar ese cron a mano.

6. **`_shared/*.ts` está bundleado por Edge Function.** Un fix en `passwords.ts`/`auth_errors.ts` exige re-deployar **CADA** función que lo importa (crear-tenant, invitar-cobrador, reenviar-invitacion…) o quedan versiones divergentes. No hay `config.toml` ni deploy por CLI: todo a mano por Dashboard.

7. **Sync rules = único paso manual del release.** `powersync/sync-rules.yaml` está en el repo pero NO se deploya por CLI ni por `build-release.ps1`: copy-paste al dashboard + dejar **"Active"**. El dashboard puede quedar desincronizado del repo sin que nadie lo note hasta que falten datos en la app.

8. **`POWERSYNC_URL` se BAKEA en build-time** (`--dart-define-from-file=.env.json`). Cambiar solo el dashboard no alcanza: hay que editar `.env.json` (gitignored, fuera de git) y **rebuildear + publicar** o las apps siguen pegando a la instancia vieja.

9. **No bumpear `msix` (pineado 3.16.13 sin `^`).** El publisher del MSIX se deriva del test-cert de ESE paquete; un upgrade puede cambiarlo → el build falla por mismatch (protección) o, si se fuerza, **rompe los updates de Windows** de los tenants reales.

10. **`applicationId`/`identity_name` son INVARIANTES** (`com.sitecsa.crm.mairena`, `.telenet`, genérico `com.sitecsa.crm`). Cambiarlos = el SO ve una app NUEVA → doble instalación y los usuarios reales dejan de actualizar.

11. **Build genérico ≠ canal vivo.** El release `v0.17.2` solo tiene assets por-tenant (mairena/telenet) + sus `version-<slug>.json`; el canal genérico (`version.json`/`CRM.msix`) está deprecado y ninguna app branded lo consume. Usar SIEMPRE `-Tenant`/`-AllTenants`.

12. **`release.ps1` legacy publica al repo PRIVADO equivocado** (`Template-TT`, nombres `cobranza-isp-*`). Si se corre por error, el release queda donde el auto-update no lo ve. Borrarlo en el traspaso. Igual, `install-latest.ps1` todavía apunta al repo viejo (puente legacy) — entender qué canal usa cada app antes de retirar `Template-TT`.

13. **Flutter NO está pineado en el repo** (no hay `.fvm`/`.flutter-version`/`.tool-versions`). La versión real (3.41.9) vive solo en `ci.yml`. Instalar el último stable a ciegas rompe `flutter pub get` por el choque **intl 0.20.2 vs 0.19.0** (documentado en la nota del CI).

14. **`vxxz` ES PRODUCCIÓN, no DEV** (el AGENTS lo llamaba DEV por error). Cada migración/UPDATE/borrado pega en usuarios reales al instante. Tras tocar plata: correr `supabase/tests/invariantes_dinero.sql` (toda fila = `violaciones=0`). Ojo: hay violaciones pre-existentes conocidas del Test Tenant — no confundir con bug nuevo en tenants reales.

15. **Folding ñ/acentos + hora Nicaragua = bugs SILENCIOSOS.** `lower()`/`upper()` de SQLite son ASCII-only; `date('now')` pelado cuenta mal la mora (negocio UTC-6). Compilan sin error: solo se ven probando con dato no-ASCII y `dia_pago ≠ 1`.

16. **Distribución self-signed:** los `install-*.ps1` deben correr **COMO ADMIN** para confiar el cert; el doble-clic en el `.msix` da "paquete desconocido". Paso humano que hay que seguir documentando para los clientes.

---

**Resumen ejecutivo en una línea:** transferí ownership de los 3 servicios (GitHub ×2, Supabase, PowerSync) para conservar keys/datos/firma, entregá los 3 secretos físicos por canal seguro (el `.jks` es irreemplazable), y dejá el cambio de owner en `update_service.dart` para el FINAL con un release-puente — todo lo demás se rompe silenciosamente si se hace fuera de orden.