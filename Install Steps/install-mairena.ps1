<#
  install-mairena.ps1  --  Instala/actualiza la app de Telecable Mairena S.A. (Windows).

  CORRER COMO ADMINISTRADOR (click derecho -> "Ejecutar como administrador"):
  el MSIX esta firmado con un certificado self-signed y hay que confiarlo en la
  maquina antes de instalar. Por eso el DOBLE-CLIC da "paquete desconocido" y este
  script si funciona (confia el certificado primero).

  Compatible con PowerShell 5.1+ (Windows PowerShell que viene con Windows).

  Que hace, solo:
    1. Resuelve y descarga el instalador branded del release "latest" (leyendo el
       manifest version-mairena.json, igual que el auto-update de la app).
    2. Extrae el certificado del MSIX y lo confia (LocalMachine\TrustedPeople).
    3. Instala (o actualiza) la app branded de Telecable Mairena.

  Es una app NUEVA (paquete propio, distinta de la vieja generica). Si tenias la
  app vieja instalada, podes desinstalarla DESPUES de confirmar que esta anda.
#>
param([string]$Repo = "rubenmaltez/sitecsa-updates")
$ErrorActionPreference = "Stop"

# --- TLS 1.2 (obligatorio para GitHub; PS 5.1 usa TLS 1.0 por defecto) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo    = $Repo
$slug    = "mairena"
$nombre  = "Telecable Mairena S.A."

# --- Admin check ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  throw "Corre este script COMO ADMINISTRADOR (click derecho -> Ejecutar como administrador). Hace falta para confiar el certificado."
}

# --- 1. Resolver la URL del MSIX desde el manifest ---
Write-Host "==> Resolviendo la ultima version de $nombre..." -ForegroundColor Cyan
$manifestUrl = "https://github.com/$repo/releases/latest/download/version-$slug.json"
try {
  # -UseBasicParsing: NO depende de IE, funciona en PS 5.1 y 7+.
  # En PS 5.1, .Content devuelve Byte[] con -UseBasicParsing -> decodificar a UTF-8.
  $response    = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing
  $manifestRaw = if ($response.Content -is [byte[]]) {
    [System.Text.Encoding]::UTF8.GetString($response.Content)
  } else { $response.Content }
  $manifest = $manifestRaw | ConvertFrom-Json
} catch {
  Write-Host "ERROR al descargar el manifest ($manifestUrl):" -ForegroundColor Red
  Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ""
  Write-Host "Posibles causas:" -ForegroundColor Yellow
  Write-Host "  - Sin conexion a internet" -ForegroundColor Yellow
  Write-Host "  - GitHub esta caido" -ForegroundColor Yellow
  Write-Host "  - No hay release publicado en $repo" -ForegroundColor Yellow
  throw "No se pudo obtener la informacion del release."
}

$msixUrl = $manifest.download_url_windows
$version = $manifest.version
if ([string]::IsNullOrWhiteSpace($msixUrl)) {
  throw "El manifest no contiene download_url_windows. Contenido: $manifestRaw"
}

Write-Host "    Version: $version" -ForegroundColor DarkGray
Write-Host "    URL:     $msixUrl" -ForegroundColor DarkGray

# --- 2. Descargar el MSIX ---
$tmpMsix = Join-Path $env:TEMP "CRM-$slug.msix"
$tmpCer  = Join-Path $env:TEMP "CRM-$slug.cer"

Write-Host "==> Descargando $nombre v$version desde GitHub..." -ForegroundColor Cyan
try {
  Invoke-WebRequest -Uri $msixUrl -OutFile $tmpMsix -UseBasicParsing
} catch {
  Write-Host "ERROR al descargar el instalador:" -ForegroundColor Red
  Write-Host "  URL: $msixUrl" -ForegroundColor Red
  Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
  throw "No se pudo descargar el instalador."
}
$sizeMB = [math]::Round((Get-Item $tmpMsix).Length / 1MB, 1)
if ($sizeMB -lt 1) {
  Write-Host "ADVERTENCIA: El archivo descargado es muy pequeno ($sizeMB MB). Puede estar corrupto." -ForegroundColor Yellow
}
Write-Host "    Descargado: $sizeMB MB" -ForegroundColor DarkGray

# --- 3. Confiar el certificado ---
Write-Host "==> Confiando el certificado del instalador..." -ForegroundColor Cyan
$sig = Get-AuthenticodeSignature $tmpMsix
if (-not $sig.SignerCertificate) { throw "El MSIX descargado no tiene firma. Abortando." }
Export-Certificate -Cert $sig.SignerCertificate -FilePath $tmpCer | Out-Null
Import-Certificate -FilePath $tmpCer -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
Write-Host "    Certificado confiado." -ForegroundColor DarkGray

# --- 4. Instalar ---
Write-Host "==> Instalando / actualizando $nombre..." -ForegroundColor Cyan
Add-AppxPackage -Path $tmpMsix -ForceApplicationShutdown -ForceUpdateFromAnyVersion

$inst = @(Get-AppxPackage | Where-Object { $_.Name -eq "com.sitecsa.crm.$slug" })[0]
if ($inst) {
  Write-Host "`n[OK] $nombre instalada: v$($inst.Version). Buscala en el menu Inicio." -ForegroundColor Green
} else {
  Write-Host "`n[OK] Instalacion lanzada. Busca '$nombre' en el menu Inicio." -ForegroundColor Green
}
