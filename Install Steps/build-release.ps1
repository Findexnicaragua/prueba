# Compatible con PowerShell 5.1+
<#
  build-release.ps1  --  Build + release de CRM en UN comando.

  GENÉRICO (como siempre):
    .\'Install Steps'\build-release.ps1                # CRM (version.json)

  WHITE-LABEL por tenant (Opción B — ver branding/README.md):
    .\'Install Steps'\build-release.ps1 -Tenant mairena   # solo Telecable Mairena
    .\'Install Steps'\build-release.ps1 -AllTenants        # TODOS los de branding/

  Cada tenant sale con su ícono + nombre, y los instaladores con su nombre
  BRANDED + versionado (config.releaseName, ej. `Telecable-Mairena-CRM-vX.Y.Z.msix`
  / `Telenet-CRM-vX.Y.Z.apk`). Su canal de update es el manifest `version-<slug>.json`
  (nombre FIJO — el app lo pide así) que apunta al instalador branded. Todo en el
  MISMO GitHub Release. Cada app se actualiza desde SU manifest (baked
  `--dart-define=TENANT=<slug>` → ver update_service.dart).

  El branding se aplica al working tree antes de cada build y se RESTAURA con
  `git checkout` después (el repo queda limpio). Requiere que la rama esté
  commiteada (el restore vuelve al estado de HEAD).

  Requisitos: flutter, gh (logueado), .env.json + android/key.properties.
#>
param([string]$Tenant = "", [switch]$AllTenants, [switch]$NoRelease, [string]$Tag = "", [string]$Notes = "", [string]$Repo = "")
$ErrorActionPreference = "Stop"

# Rutas relativas a la RAÍZ del repo (el script vive en Install Steps/).
Set-Location (Split-Path $PSScriptRoot -Parent)

# Repo de RELEASES (publico, sin codigo). Prioridad: -Repo > UPDATE_REPO del
# .env.json > default historico. UN SOLO valor (UPDATE_REPO en .env.json) maneja
# a la vez el canal de publicacion Y el que la app consulta para auto-actualizar
# (update_service.dart lo lee del MISMO .env via --dart-define-from-file). Asi,
# para apuntar a otro dueño (traspaso/staging), se cambia UPDATE_REPO y listo.
# Override con -Repo solo para casos puntuales (p.ej. el puente legacy).
if ([string]::IsNullOrWhiteSpace($Repo)) {
  if (Test-Path ".env.json") {
    try { $u = (Get-Content ".env.json" -Raw | ConvertFrom-Json).UPDATE_REPO } catch { $u = $null }
    if (-not [string]::IsNullOrWhiteSpace($u)) { $Repo = $u }
  }
  if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = "rubenmaltez/sitecsa-updates" }
}
$repo   = $Repo
$ghBase = "https://github.com/$repo/releases/latest/download"
Write-Host "Repo de releases: $repo" -ForegroundColor DarkGray

function Check($msg) { if ($LASTEXITCODE -ne 0) { throw "FALLO: $msg (exit $LASTEXITCODE)" } }

# Ejecuta un comando nativo (flutter, dart, git, gh) sin que su stderr
# dispare $ErrorActionPreference=Stop (en PS 5.1 stderr = ErrorRecord).
function Invoke-Native {
  param([string]$Label, [Parameter(ValueFromRemainingArguments)][string[]]$Cmd)
  $prev = $ErrorActionPreference
  $global:ErrorActionPreference = "Continue"
  try {
    $exe  = $Cmd[0]
    $argv = @(); if ($Cmd.Count -gt 1) { $argv = $Cmd[1..($Cmd.Count-1)] }
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "FALLO: $Label (exit $LASTEXITCODE)" }
  } finally { $global:ErrorActionPreference = $prev }
}

# Reemplaza la PRIMERA coincidencia de $pattern por el literal $literal (sin
# que '$' del literal se interprete como grupo). Falla si no aplicó.
function Patch-File($path, $pattern, $literal) {
  $content   = Get-Content $path -Raw
  $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $literal }
  $new = [regex]::Replace($content, $pattern, $evaluator,
          [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($new -eq $content) { throw "Patch no aplico en $path (patron: $pattern)" }
  Set-Content $path $new -Encoding utf8 -NoNewline
}

# 0) Pre-checks
if (-not (Test-Path ".env.json")) { throw ".env.json no existe en la raiz (config Supabase/PowerSync)." }
if (-not (Test-Path "android/key.properties")) { throw "android/key.properties no existe -> el APK se firmaria con la DEBUG key y NO actualizaria las apps instaladas." }
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw "flutter no esta en el PATH." }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh (GitHub CLI) no esta en el PATH." }

$ver = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches.Groups[1].Value).Split('+')[0]
if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = "v$ver" }
Write-Host "`n=== CRM  $ver  ->  release $Tag ===`n" -ForegroundColor Cyan

# Deps + flag de msix (una sola vez)
Invoke-Native "flutter pub get" flutter pub get
# Detectar el flag correcto de msix (--no-build-windows vs --build-windows false).
# cmd /c aisla completamente el stderr de dart del manejo de PS 5.1.
$msixHelp = cmd /c "dart run msix:create --help 2>&1"
$noBuild  = if ($msixHelp -match 'no-build-windows') { @('--no-build-windows') } else { @('--build-windows','false') }

# Carpetas de salida
$relDir = Join-Path "Releases" $Tag
New-Item -ItemType Directory -Force -Path $relDir | Out-Null
$desk     = [Environment]::GetFolderPath("Desktop")
$uploads  = [System.Collections.Generic.List[string]]::new()

# Buildea UN target. $Slug vacío = genérico (CRM).
function Build-One {
  param([string]$Slug = "")
  $isTenant = $Slug -ne ""

  # CLEAN: Evitar filtraciones de recursos/iconos cacheados de otros tenants en Gradle/CMake
  Invoke-Native "clean" flutter clean
  Invoke-Native "pub get" flutter pub get

  if ($isTenant) {
    if (-not (Test-Path "branding/$Slug/config.json")) { throw "No existe branding/$Slug/config.json" }
    if (-not (Test-Path "branding/$Slug/logo.png"))    { throw "Falta branding/$Slug/logo.png" }
    $cfg  = Get-Content "branding/$Slug/config.json" -Raw | ConvertFrom-Json
    $name = $cfg.displayName
    Write-Host "`n--- Tenant '$Slug'  ->  $name ---" -ForegroundColor Cyan

    # 1) Branding: ícono cuadrado (forma A) + logo del login, y regenerar
    #    mipmaps de Android + .ico de Windows desde ese ícono.
    Invoke-Native "branding $Slug" dart run tool/aplicar_branding.dart $Slug
    Invoke-Native "launcher icons $Slug" dart run flutter_launcher_icons

    # 2) Nombre e identidad por plataforma
    Patch-File "android/app/src/main/AndroidManifest.xml" 'android:label="[^"]*"' "android:label=`"$name`""
    Patch-File "windows/runner/main.cpp"                  'window\.Create\(L"[^"]*"' "window.Create(L`"$name`""
    Patch-File "pubspec.yaml"                             '^\s*display_name:.*$'   "  display_name: $name"
    Patch-File "pubspec.yaml"                             '^\s*identity_name:.*$'  "  identity_name: $($cfg.msixIdentity)"
    Patch-File "android/app/build.gradle.kts"            'applicationId = "[^"]*"' "applicationId = `"$($cfg.applicationId)`""

    # Nombre branded del instalador (config.releaseName, ej. "Telecable-Mairena-CRM").
    # Fallback al esquema viejo si el config no lo trae. El MANIFEST sigue siendo
    # version-<slug>.json (el app lo pide por nombre fijo — NO se renombra).
    $base   = if ($cfg.releaseName) { $cfg.releaseName } else { "CRM-$Slug" }

    # Runner.rc: ProductName distinto por marca → path_provider resuelve a
    # carpetas separadas en %APPDATA% → sesión/DB/prefs aisladas por app.
    Patch-File "windows/runner/Runner.rc"                 '"ProductName", "[^"]*"'  "`"ProductName`", `"$base`""
    $vjName = "version-$Slug.json"
    $define = @("--dart-define=TENANT=$Slug")
  } else {
    Write-Host "`n--- Generico  ->  CRM ---" -ForegroundColor Cyan
    $base   = "CRM"
    $vjName = "version.json"
    $define = @()
  }

  # 3) Build Windows (con env) + MSIX (sin re-buildear) + APK (con env)
  Invoke-Native "build windows ($Slug)" flutter build windows --release --dart-define-from-file=.env.json @define
  Invoke-Native "msix:create ($Slug)" dart run msix:create @noBuild
  Invoke-Native "build apk ($Slug)" flutter build apk --release --dart-define-from-file=.env.json @define

  $msixPath = (Get-ChildItem -Recurse -Filter *.msix build\windows | Select-Object -First 1).FullName
  if (-not $msixPath) { throw "No se encontro el .msix generado ($Slug)." }
  $apkPath = "build\app\outputs\flutter-apk\app-release.apk"

  # 4) Asset BRANDED + VERSIONADO: es el MISMO archivo que se sube al release y al
  #    que apunta el manifest. `latest/download/<name>` resuelve al asset del
  #    release vigente → mientras $Tag es Latest, el auto-update lo baja. Ej:
  #    Telecable-Mairena-CRM-v0.18.3.msix. (El manifest version-<slug>.json
  #    mantiene su nombre fijo — es lo que el app pide por nombre.)
  $msixName = "$base-$Tag.msix"
  $apkName  = "$base-$Tag.apk"
  $msixOut  = Join-Path (Get-Location) $msixName
  $apkOut   = Join-Path (Get-Location) $apkName
  Copy-Item $msixPath $msixOut -Force
  Copy-Item $apkPath  $apkOut  -Force
  # Copias al historico (.\Releases\vX\) + escritorio (mismo nombre branded).
  Copy-Item $msixOut (Join-Path $relDir $msixName) -Force
  Copy-Item $apkOut  (Join-Path $relDir $apkName)  -Force
  Copy-Item $msixOut (Join-Path $desk $msixName) -Force
  Copy-Item $apkOut  (Join-Path $desk $apkName)  -Force

  # 5) version json del canal — apunta al asset branded versionado de ESTE release.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  if ($isTenant) {
    $notes = if ($Notes -ne "") { $Notes } else { "Actualizacion de $name." }
    $vj = [ordered]@{
      version              = $ver
      release_notes        = $notes
      download_url_windows = "$ghBase/$msixName"
      download_url_android = "$ghBase/$apkName"
      download_url         = "$ghBase/$msixName"
    }
    $vjJson = $vj | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) $vjName), $vjJson, $utf8NoBom)
  } else {
    $vj = Get-Content version.json -Raw | ConvertFrom-Json
    $vj.version = $ver
    # Reescribir SIEMPRE las download_url desde $ghBase (no confiar en lo
    # commiteado): asi el canal generico apunta al repo de releases vigente.
    $vj.download_url_windows = "$ghBase/$msixName"
    $vj.download_url_android = "$ghBase/$apkName"
    $vj.download_url         = "$ghBase/$msixName"
    if ($Notes -ne "") { $vj.release_notes = $Notes }
    else { Write-Host "AVISO: sin -Notes, release_notes del generico queda como estaba." -ForegroundColor Yellow }
    $vjJson = $vj | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) "version.json"), $vjJson, $utf8NoBom)
  }

  # FIX (2026-07-13): subir desde $relDir (.\Releases\vX\), NO desde la raiz.
  # Los assets branded en la raiz del 1er tenant desaparecian antes del
  # `gh release create` (quedaba solo el ultimo tenant -> "no matches found for
  # <1er-tenant>.msix"). $relDir tiene TODOS los tenants y persiste -> confiable.
  Copy-Item $vjName (Join-Path $relDir $vjName) -Force
  $uploads.Add((Join-Path $relDir $msixName))
  $uploads.Add((Join-Path $relDir $apkName))
  $uploads.Add((Join-Path $relDir $vjName))

  # Instalador PS del tenant como asset publico (nombre fijo install-<slug>.ps1)
  # para el one-liner de instalacion en PC nueva:
  #   irm https://github.com/rubenmaltez/sitecsa-updates/releases/latest/download/install-<slug>.ps1 | iex
  # (Se sube tal cual del repo; el generico no tiene install-.ps1 -> Test-Path lo saltea.)
  if ($isTenant) {
    $instPs = Join-Path (Get-Location) "Install Steps\install-$Slug.ps1"
    if (Test-Path $instPs) { $uploads.Add($instPs) }
    else { Write-Host "AVISO: no existe $instPs -> el one-liner de $Slug no tendra asset." -ForegroundColor Yellow }
  }

  # 6) Restaurar el working tree (solo tenant: deshacer branding + patches)
  if ($isTenant) {
    Invoke-Native "git checkout (restaurar branding $Slug)" git checkout -- pubspec.yaml android/app/build.gradle.kts `
      android/app/src/main/AndroidManifest.xml windows/runner/main.cpp `
      windows/runner/Runner.rc `
      assets/icon/app_icon.png assets/branding/login_logo.png `
      android/app/src/main/res windows/runner/resources/app_icon.ico
  }

  Write-Host "==> Listo $base ($Tag)" -ForegroundColor Green
}

# ¿Qué buildear?
if ($AllTenants) {
  $slugs = Get-ChildItem branding -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "config.json") } |
    ForEach-Object { $_.Name }
  if (-not $slugs) { throw "No hay tenants con config.json en branding/." }
  Write-Host "Tenants a buildear: $($slugs -join ', ')" -ForegroundColor Cyan
  foreach ($s in $slugs) { Build-One -Slug $s }
} elseif ($Tenant -ne "") {
  Build-One -Slug $Tenant
} else {
  Build-One
}

# 7) Publicar / actualizar el release con TODOS los assets juntos
#    (-NoRelease: solo buildea para probar local, sin tocar GitHub)
if ($NoRelease) {
  Write-Host "`n=== LISTO (build local, sin publicar) ===" -ForegroundColor Green
  Write-Host "Instaladores en: $relDir  +  Escritorio" -ForegroundColor Green
  Get-ChildItem $relDir | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Green }
  return
}

$assetArgs = $uploads.ToArray()
$releaseCheck = & gh release view $Tag --repo $repo 2>&1
if ($LASTEXITCODE -eq 0) {
  Write-Host "`n==> Release $Tag ya existe -> reemplazando assets..." -ForegroundColor Cyan
  Invoke-Native "gh release upload" gh release upload $Tag @assetArgs --repo $repo --clobber
} else {
  Write-Host "`n==> Creando release $Tag..." -ForegroundColor Cyan
  Invoke-Native "gh release create" gh release create $Tag @assetArgs --repo $repo --title $Tag --notes "Release $Tag de CRM."
}

Write-Host "`n=== LISTO ===" -ForegroundColor Green
Write-Host "Release: https://github.com/$repo/releases/tag/$Tag" -ForegroundColor Green
foreach ($a in $uploads) { Write-Host "  asset: $(Split-Path $a -Leaf)" -ForegroundColor Green }
