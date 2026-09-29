# 1 — Publicar una versión nueva (dev)

Lo corrés vos, en tu PC, con el repo clonado. Requisitos: `flutter`, `gh`
(logueado con `gh auth login`), `pwsh` 7+, `.env.json` en la raíz, y la firma
release de Android: `android/key.properties` + `sitecsa-release.jks`
(gitignored — viven SOLO en el worktree principal; el script **ABORTA** si
faltan, así no sale un APK debug-signed que las apps instaladas rechazarían).

---

> ## ✅ DESDE v0.37.0 SE BUILDEA `main`
>
> **Decisión de Rubén, 2026-08-30.** El rediseño del dashboard se terminó, se
> aprobó tarjeta por tarjeta y se publicó con la v0.37.0: ya no hay nada en
> `main` que haya que dejar afuera, así que la rama `release/*` dejó de tener
> motivo. Se buildea `main` directo.
>
> *Entre la v0.36.2 y la v0.36.6 fue al revés:* `main` tenía el rediseño a medio
> hacer y cada versión salía de una rama `release/*` = `main` **menos el
> rediseño**. La receta de cómo se armaba esa rama sigue en
> [`1b-Armar-la-rama-de-release.md`](1b-Armar-la-rama-de-release.md) —**no la
> borres**: el día que haya otra vez trabajo grande a medio terminar en `main`,
> es la forma probada de sacar una versión sin él.
>
> **Lo que NO cambió: el build se corre desde `C:/sc-release`**, que está fuera
> de OneDrive. Adentro de OneDrive el build falla ("unable to write new index
> file") y `git merge` también.

## Paso 1 — Bump de versión

En `pubspec.yaml`, subí la línea `version`:

```yaml
version: 0.6.4+064   # X.Y.Z+NNN
```

> **⚠️ COMMITEÁ EL BUMP ANTES DE BUILDEAR.** No es cosmético. El script lee la
> versión UNA sola vez y, al terminar cada tenant, restaura el working tree con
> `git checkout -- pubspec.yaml …` para deshacer el branding — lo que **revierte
> también la línea `version`**. Con `-AllTenants` y el bump sin commitear, el
> primer tenant sale bien y el **segundo se buildea con la versión VIEJA adentro
> pero con el nombre de archivo y el manifest de la nueva**: el instalador dice
> vX.Y.Z, la app muestra la anterior, y el auto-update queda ofreciendo para
> siempre una versión que "ya está instalada". Desde 2026-08-23 el script lo
> valida y aborta, pero conviene saber por qué.
>
> El `+NNN` (build number) tiene que **subir siempre**: Android y MSIX rechazan
> una actualización cuyo build number no sea mayor. Si baja o repite, la
> actualización simplemente no entra y no hay mensaje de error.

- `X.Y.Z` = semver. Es lo que compara el auto-update y lo que se muestra en la
  app (login, sidebar admin, perfil cobrador).
- `+NNN` (build) **siempre sube** — es el `versionCode` de Android; sin subirlo,
  Android rechaza la actualización.

> No hace falta tocar `version.json` a mano: `build-release.ps1` le pone el
> número del `pubspec.yaml` solo.

## Paso 2 — Migraciones de Supabase (si la versión trae)

Si el release incluye archivos nuevos en `supabase/migrations/`, corrélos en
orden **antes** de que la gente instale, vía Dashboard → SQL Editor:

```powershell
Get-Content supabase\migrations\NNNN_*.sql -Raw | Set-Clipboard
```
Pegá en SQL Editor → Run → esperá `Success`. Repetí por cada migración nueva,
en orden numérico.

> Si la migración solo inserta filas en tablas ya sincronizadas (ej. `settings`),
> **no** hace falta bumpear schema ni tocar sync rules. Si agrega columnas o
> tablas, seguí el checklist de integridad de `AGENTS.md`. **Sync rules (desde
> 2026-07-13):** viven en el VPS self-host — se actualizan editando
> `/opt/powersync/config/sync-config.yaml` + `docker compose restart powersync`
> (ya NO se pegan en un dashboard de PowerSync cloud; ver ARQUITECTURA §3.8).

## Paso 3 — Build + publicar (un comando)

```powershell
.\'Install Steps'\build-release.ps1 -AllTenants
```

> El script vive en `Install Steps\` y hace auto-cd a la raíz del repo —
> funciona invocado desde cualquier carpeta. `-AllTenants` buildea TODOS los
> tenants de `branding/` (cada uno con su ícono + nombre); `-Tenant mairena`
> hace uno solo; sin flag, el genérico.

Hace todo, en orden (por cada tenant):
1. Build Windows (MSIX) + Android (APK) con el `.env.json` baked + el branding
   del tenant.
2. Nombra los instaladores **branded + versionados** (`config.releaseName`):
   `Telecable-Mairena-CRM-vX.Y.Z.msix` / `.apk`, `Telenet-CRM-vX.Y.Z.msix` /
   `.apk`. Los archiva en `.\Releases\vX.Y.Z\` + copia al Escritorio.
3. Sube al **GitHub Release** esos instaladores branded + el **manifest**
   `version-<slug>.json` (nombre FIJO — el app lo pide así; apunta al instalador
   branded) + el **`install-<slug>.ps1`** (nombre FIJO, asset público — es lo
   que resuelve el one-liner de la guía 2). Total por release: **8 assets**
   (2 MSIX + 2 APK + 2 `version-<slug>.json` + 2 `install-<slug>.ps1`).
   Tag `vX.Y.Z`. El auto-update sigue el `download_url` del manifest.

Para forzar un tag distinto: `... -Tag v0.6.5`. Para el **canal puente** (repo
viejo `Template-TT`, mientras apps migran): repetir con `-Repo rubenmaltez/Template-TT`
(o reusar los mismos binarios y regenerar los `version-<slug>.json` con la URL
del puente — los binarios son idénticos entre canales).

Salida esperada al final, en verde: `==> Listo <ReleaseName> (vX.Y.Z)` por
tenant + el link del release.

## Paso 4 — Avisar / instalar

- Las apps ya instaladas muestran solo el banner **"Actualización disponible
  vX.Y.Z"** al abrir. Para aplicarla hay que instalar (ver guías 2 y 3).
- Para instalar en cada dispositivo: `2-Instalar-en-PC.md` y
  `3-Instalar-en-Android.md`.

---

## Probar en tu PC sin instalar

El build deja un `.exe` que ya viene con el `.env`:
```powershell
.\build\windows\x64\runner\Release\isp_billing.exe
```
