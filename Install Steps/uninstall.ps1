# Compatible con PowerShell 5.1+
<#
  uninstall.ps1  --  Desinstala CRM del PC (full).

  Uso:  click derecho -> "Ejecutar con PowerShell"
        o:  pwsh -ExecutionPolicy Bypass -File .\uninstall.ps1

  NO requiere administrador (Remove-AppxPackage es por-usuario).
  Al desinstalar el MSIX, su data local (el SQLite de PowerSync que vive en el
  contenedor del paquete) se borra junto con la app -> queda 100% limpio.
#>
$ErrorActionPreference = "Stop"

# Cerrar la app si está corriendo: sino sus archivos (sesión + SQLite local)
# quedan LOCKEADOS y el borrado de la cache falla -> la sesión "sobrevive" al
# uninstall+reinstall. Esta era la causa de "reinstale y seguía logueado".
Get-Process -Name isp_billing -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

$pkgs = @(Get-AppxPackage | Where-Object { $_.Name -like "*sitecsa*" })
if ($pkgs.Count -eq 0) {
  Write-Host "CRM no esta instalada (nada que desinstalar)." -ForegroundColor Yellow
  return
}

foreach ($p in $pkgs) {
  Write-Host "Desinstalando $($p.Name)  v$($p.Version) ..." -ForegroundColor Cyan
  Remove-AppxPackage -Package $p.PackageFullName
}

# Limpiar AppData sobrante del paquete (sesion + SQLite local de PowerSync), por si
# Windows lo retuvo tras el Remove-AppxPackage (pasa con updates in-place).
$quedoAlgo = $false
Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "*sitecsa*" -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "Limpiando cache local: $($_.Name) ..." -ForegroundColor Cyan
  Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $_.FullName) { $quedoAlgo = $true }
}

if ($quedoAlgo) {
  Write-Host "`n[!] La app se desinstalo, pero NO se pudo borrar del todo la cache local" -ForegroundColor Yellow
  Write-Host "    (archivos en uso). La SESION podria sobrevivir al reinstalar." -ForegroundColor Yellow
  Write-Host "    Fix seguro: abri la app y toca 'Cerrar sesion' para el login limpio." -ForegroundColor Yellow
} else {
  Write-Host "`n[OK] CRM desinstalada + cache local borrada (sesion incluida)." -ForegroundColor Green
}
Write-Host "     Nota: la DATA (clientes/cuotas/pagos) vive en Supabase (la nube) y se" -ForegroundColor DarkGray
Write-Host "     re-baja al loguearte. El 'desde 0' de la DATA es el wipe del BACKEND." -ForegroundColor DarkGray
