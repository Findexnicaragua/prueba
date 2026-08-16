# 0 — Setup de una PC de DESARROLLO nueva

Cómo dejar una computadora nueva lista para trabajar en CRM
(desarrollar, correr la app, correr tests y publicar releases). Tiempo
estimado: ~30-45 min (la mayoría es instalar Flutter/Visual Studio).

> Esta guía es para la PC del DEV (Rubén). Para instalar la APP en una PC de
> un cliente/admin, eso es `2-Instalar-en-PC.md`.

---

## Paso 1 — Instalar las herramientas

| Herramienta | Para qué | De dónde |
|---|---|---|
| **Git** | clonar el repo | git-scm.com |
| **Flutter SDK** (canal stable) | la app | docs.flutter.dev/get-started → agregar `flutter\bin` al PATH |
| **Visual Studio 2022** (Community) con el workload **"Desktop development with C++"** | build de Windows | visualstudio.microsoft.com |
| **Android Studio** (o solo el Android SDK + cmdline-tools) | build del APK | developer.android.com |
| **PowerShell 7+** (`pwsh`) | los scripts del repo | microsoft.com/powershell |
| **GitHub CLI** (`gh`) | publicar releases | cli.github.com → después `gh auth login` |

Verificación: `flutter doctor` — debe dar check verde en Windows, Android
y (opcional) Chrome. Los issues de iOS/macOS se ignoran.

## Paso 2 — Clonar el repo

```powershell
cd C:\Users\<tu-usuario>\Projects
git clone https://github.com/rubenmaltez/Template-TT.git
cd Template-TT
git checkout main
```

## Paso 3 — Copiar `.env.json` (EL ÚNICO ARCHIVO QUE NO VIENE POR GIT)

`.env.json` tiene las keys de Supabase y PowerSync → **NUNCA va al repo**.
Copialo desde tu PC anterior (USB, o pasátelo por un canal privado) a la
**raíz** del proyecto. Sin este archivo la app abre con "Configuración
pendiente" y el build falla a propósito.

> Si lo perdiste: las de Supabase están en el Dashboard de Supabase (Settings →
> API); `POWERSYNC_URL` es la URL del **VPS self-host** (`https://65-109-1-217.sslip.io`)
> — ya NO un "Instance URL" del PowerSync cloud (se retiró; ver ARQUITECTURA §3.8).
> La estructura del JSON se ve en `lib/config/env.dart`.

## Paso 3b — Copiar el keystore de firma del APK (junto con .env.json)

El APK de release se firma con el keystore de SITECSA (estable entre PCs —
sin él, un APK buildeado acá NO podría actualizar las apps ya instaladas).
Son 2 archivos que van por el MISMO canal seguro que `.env.json` (nunca git):

- `android/key.properties` (passwords del keystore)
- `android/app/sitecsa-release.jks` (el keystore)

> **Si es la PRIMERA VEZ (el keystore no existe todavía):** se genera UNA
> única vez, en una sola PC, y se copia a las demás:
> ```powershell
> keytool -genkey -v -keystore android\app\sitecsa-release.jks -keyalg RSA -keysize 2048 -validity 10950 -alias sitecsa
> ```
> (`keytool` viene con el JDK de Android Studio.) Después creá
> `android/key.properties` con:
> ```
> storePassword=LA_PASSWORD_QUE_ELEGISTE
> keyPassword=LA_PASSWORD_QUE_ELEGISTE
> keyAlias=sitecsa
> storeFile=sitecsa-release.jks
> ```
> ⚠️ **GUARDÁ el .jks + passwords como oro** (backup fuera de la PC): si se
> pierden, NINGUNA app instalada podrá actualizarse nunca más (habría que
> desinstalar y reinstalar todo, perdiendo la data offline local).
> Sin estos archivos el build cae a la firma debug (solo para desarrollo —
> NUNCA distribuir un APK firmado con debug).

## Paso 4 — Dependencias y primera corrida

```powershell
flutter pub get
flutter run -d windows
```

**Qué deberías ver:** la app compila y abre en el login. (La primera
compilación de Windows tarda varios minutos — descarga pdfium y compila
los plugins nativos.)

## Paso 5 — Verificar los tests (opcional pero recomendado)

```powershell
flutter test
```

**Qué deberías ver:** todos verdes (incluye la suite de dinero de
`pagos_repo`). Las DLLs nativas de PowerSync que estos tests necesitan
(`powersync_x64.dll`) **ya viene en el repo** (raíz),
igual que el certificado público `CRM.cer` — no hay pasos manuales.

## Paso 6 — Para publicar releases desde esta PC

```powershell
gh auth login    # una sola vez (cuenta rubenmaltez)
```

Y de ahí en más, el flujo normal de release: `1-Publicar-nueva-version.md`
(bump de versión + migraciones + `.\'Install Steps'\build-release.ps1`).
La firma del MSIX usa el certificado de prueba del paquete `msix` (sin
`certificate_path` custom), así que los releases generados desde esta PC
son compatibles con los instalados — no hay que mover certificados privados.

---

## Resumen: qué viene de dónde

| Cosa | Cómo llega a la PC nueva |
|---|---|
| Código + docs + scripts | `git clone` (rama `main`) |
| `powersync_x64.dll` / `CRM.cer` | vienen en el repo |
| `.env.json` | **a mano, por canal seguro** (nunca git) |
| `android/key.properties` + `android/app/sitecsa-release.jks` (firma APK) | **a mano, por canal seguro** (nunca git) |
| Dependencias Dart | `flutter pub get` |
| `build/`, `.dart_tool/`, etc. | se generan solos al compilar |
| `Releases\` (instaladores versionados) | se crea sola al correr `build-release.ps1` (el histórico viejo queda en la PC anterior / GitHub Releases) |
