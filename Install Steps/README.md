# Install Steps — orden absoluto para publicar e instalar CRM

Esta carpeta es la **fuente única** de cómo se saca una versión nueva y cómo se
instala en los dispositivos. Si dudás del orden, mirá acá — no la memoria.

> **Para AIs/modelos futuros:** después de mergear un cambio que Rubén quiera
> distribuir, guialo por `1-Publicar-nueva-version.md` — incluye el **bump de
> versión obligatorio** en `pubspec.yaml` (semver `X.Y.Z` + build `+NNN` que
> SIEMPRE sube, sino Android rechaza la actualización) y el script
> **`build-release.ps1` que vive EN ESTA CARPETA** (hace auto-cd a la raíz del
> repo; correrlo como `.\'Install Steps'\build-release.ps1`).

## Orden de uso

0. **`0-Setup-PC-desarrollo.md`** — UNA VEZ por PC de dev nueva: herramientas,
   clone, `.env.json` (único archivo que no viene por git), primera corrida.
1. **`1-Publicar-nueva-version.md`** — cada release: bump de versión,
   migraciones en Supabase, y `build-release.ps1` (genera instaladores
   + publica el GitHub Release).
2. **`2-Instalar-en-PC.md`** — instalar/actualizar la APP en una PC Windows.
3. **`3-Instalar-en-Android.md`** — instalar/actualizar en un teléfono.

## Cómo queda organizado todo (orden absoluto)

| Cosa | Dónde vive | Nombre |
|---|---|---|
| Versión única de verdad | `pubspec.yaml` (`version: X.Y.Z+NNN`) | — |
| Instaladores **branded versionados** (se apilan) | `Releases\vX.Y.Z\` (raíz del proyecto) | `Telecable-Mairena-CRM-vX.Y.Z.msix` / `.apk`, `Telenet-CRM-vX.Y.Z.msix` / `.apk` |
| Copia cómoda para mandar | Escritorio | idem (branded versionado) |
| Assets del GitHub Release (auto-update) | GitHub Releases | **8 assets por release**: los MISMOS instaladores branded (2 MSIX + 2 APK) + los **manifests** `version-<slug>.json` (×2, nombre **fijo**) + los **`install-<slug>.ps1`** (×2, nombre fijo, asset público desde v0.22.0 — resuelven el one-liner de la guía 2) |
| Scripts | esta carpeta | `build-release.ps1` (dev), `install-mairena.ps1` / `install-telenet.ps1`, `uninstall.ps1` |

### Qué es fijo y qué cambia por versión

- **Instalador branded versionado** (`<ReleaseName>-vX.Y.Z.msix`): lleva el nombre
  del ISP + la versión. Es el MISMO archivo en `Releases\`, el Escritorio y el
  GitHub Release. Lo archivás, lo mandás a mano, y es lo que baja el auto-update.
- **El manifest `version-<slug>.json`** (nombre **FIJO**): es lo que el app pide
  por nombre a `releases/latest/download/`. Adentro trae el `download_url` al
  instalador branded de ESE release. El nombre del manifest **no cambia** por
  versión (si no, se rompe el link de `latest`); el del instalador SÍ. Los
  scripts `install-*.ps1` resuelven la URL leyendo ese manifest.

`build-release.ps1` hace todo automáticamente: archiva los versionados en
`Releases\vX.Y.Z\` y sube instalador + manifest a GitHub. No renombrás nada.

> La carpeta `Releases\` está en `.gitignore` (son artefactos de build, no van
> al repo). Se crea sola la primera vez que corrés `build-release.ps1`.

## Scripts (PowerShell 7+)

| Script | Qué hace | Cómo correr |
|---|---|---|
| `install-mairena.ps1` / `install-telenet.ps1` | Instala/actualiza la app del ISP (Mairena o Telenet) desde GitHub (confía el cert self-signed) | **Vía principal: one-liner** en PowerShell **como administrador** (ver abajo) |
| `uninstall.ps1` | Desinstala CRM de la PC (y limpia cache local) | Click derecho → Ejecutar con PowerShell |

**Vía principal (one-liner):** desde v0.22.0 los `install-<slug>.ps1` se suben
como **asset público del release**, así que en una PC nueva no se baja ningún
archivo. PowerShell **como administrador** y:

```powershell
irm https://github.com/rubenmaltez/sitecsa-updates/releases/latest/download/install-<slug>.ps1 | iex
# <slug> = mairena | telenet
```

El comando corre desde memoria → **bypassa el execution policy** de Windows (que
bloquea los `.ps1` descargados). **Fallback** si preferís el archivo local (de
esta carpeta o bajado del release):

```powershell
powershell -ExecutionPolicy Bypass -File .\install-<slug>.ps1
```

Detalle paso a paso: `2-Instalar-en-PC.md`.
