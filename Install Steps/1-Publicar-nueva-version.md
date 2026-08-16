# 1 — Publicar una versión nueva (dev)

Lo corrés vos, en tu PC, con el repo clonado. Requisitos: `flutter`, `gh`
(logueado con `gh auth login`), `pwsh` 7+, `.env.json` en la raíz, y la firma
release de Android: `android/key.properties` + `sitecsa-release.jks`
(gitignored — viven SOLO en el worktree principal; el script **ABORTA** si
faltan, así no sale un APK debug-signed que las apps instaladas rechazarían).

---

## Paso 1 — Bump de versión

En `pubspec.yaml`, subí la línea `version`:

```yaml
version: 0.6.4+064   # X.Y.Z+NNN
```

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
