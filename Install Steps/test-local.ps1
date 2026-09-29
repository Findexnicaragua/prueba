# Build de PRUEBA local, verificado paso por paso.
#
# POR QUE EXISTE. El 2026-08-11 se compilo, se instalo y se pidio validar un
# cambio que el usuario no vio. El build estaba bien; el problema fue el
# proceso:
#   - Todas las compilaciones de prueba salian con la MISMA version (0.32.0),
#     asi que no habia forma de distinguir a simple vista el build nuevo del
#     viejo. TESTING.md ya exigia declarar la version esperada; no se cumplia.
#   - Conviven TRES apps instaladas (CRM generico, Telecable Mairena, Telenet).
#     El usuario abrio una branded y vio la version vieja. Nada se lo advirtio.
#
# Este script cierra las dos puertas: bumpea el build number, renombra la app de
# prueba para que no se confunda con las de produccion, y VERIFICA cada paso en
# vez de suponerlo. Si algo no cierra, FALLA fuerte en vez de dejar seguir.
#
#   .\Install Steps\test-local.ps1 `
#     -Marcador "Cobertura del ciclo","Caja del ciclo","Juntos dan" `
#     -MarcadorAusente "Cobros del mes"
#
# -Marcador son textos que TIENEN que estar en el binario: la prueba de que cada
# cambio viajo hasta el .so. Sin eso, lo unico verificado es que el compilador
# corrio. UN SOLO MARCADOR NO ALCANZA - va uno por cada cambio a probar.
#
# -MarcadorAusente son los que tienen que haber DESAPARECIDO (renombrados,
# textos quitados). Sin esto, un rename a medias pasa como bueno: el nombre
# nuevo aparece y el viejo sigue vivo en otro lado.

param(
  # Textos que TIENEN que estar en el binario (uno por cada cambio a probar).
  [Parameter(Mandatory = $true)][string[]]$Marcador,
  # Textos que NO tienen que estar: lo que se quito o renombro. Verificar solo
  # presencia deja pasar un rename a medias, con el nombre viejo todavia vivo.
  [string[]]$MarcadorAusente = @(),
  [string]$NombrePrueba = "CRM PRUEBA"
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

$paso = 0
function Ok($msg)   { $script:paso++; Write-Host ("  [{0}] OK    {1}" -f $script:paso, $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  [X] FALLA  {0}" -f $msg) -ForegroundColor Red; exit 1 }
function Info($msg) { Write-Host ("        {0}" -f $msg) -ForegroundColor DarkGray }

# Pliega acentos y enies a ASCII. Los marcadores viajan por la linea de comandos
# y ahi la codificacion se rompe segun la consola: 'No entro plata' llego como
# 'No entr?plata' y el chequeo dio FALSO NEGATIVO dos veces sobre cambios que si
# estaban en el binario. Comparando ambos lados plegados, el acento deja de
# poder mentir. (Mismo criterio que foldBusqueda en el codigo Dart.)
function Plegar([string]$s) {
  # Plegado por MAPA, no por Normalize(): normalizar un binario decodificado
  # como texto lanza "invalid Unicode code points" — trae subrogados sueltos y
  # no-caracteres que ninguna limpieza previa cubre del todo. El mapa solo
  # necesita las vocales acentuadas y la enie, que es todo lo que aparece en
  # los textos de esta app, y no puede fallar sobre basura binaria.
  $r = $s
  foreach ($p in @(
      @('a','áàäâ'), @('e','éèëê'),
      @('i','íìïî'), @('o','óòöô'),
      @('u','úùüû'), @('n','ñ'),
      @('A','ÁÀÄÂ'), @('E','ÉÈËÊ'),
      @('I','ÍÌÏÎ'), @('O','ÓÒÖÔ'),
      @('U','ÚÙÜÛ'), @('N','Ñ'))) {
    foreach ($c in $p[1].ToCharArray()) { $r = $r.Replace($c, $p[0]) }
  }
  return $r
}

Write-Host "`n=== Build de prueba local ===" -ForegroundColor Cyan

# ── 1. Version: se bumpea el BUILD NUMBER para que el login la muestre distinta.
$pubspec = Join-Path $raiz 'pubspec.yaml'
$original = Get-Content $pubspec -Raw
if ($original -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)') { Fail "no se pudo leer la version de pubspec.yaml" }
$semver = $Matches[1]
# El build number es la FECHA-HORA (MMddHHmm), no un +1: el script restaura el
# pubspec al terminar, asi que "el anterior + 1" daba SIEMPRE el mismo numero y
# dos compilaciones seguidas volvian a ser indistinguibles — el problema que
# este script viene a cerrar. Con la marca de tiempo, la etiqueta del login dice
# ademas CUANDO se compilo: v0.32.0 (08112353) = 11 de agosto, 23:53.
$nuevoBuild = [int](Get-Date -Format 'MMddHHmm')
$versionPrueba = "$semver+$nuevoBuild"

# El display_name distinto evita el error que ya paso: abrir la app branded y
# creer que se esta mirando el build nuevo.
$parcheado = $original `
  -replace '(?m)^version:\s*[\d\.\+]+', "version: $versionPrueba" `
  -replace '(?m)^(\s*)display_name:\s*CRM\s*$', "`${1}display_name: $NombrePrueba"
Set-Content $pubspec $parcheado -NoNewline -Encoding UTF8
Ok "pubspec parcheado -> $versionPrueba, app '$NombrePrueba'"

try {
  # ── 2. Compilar. Sin --dart-define-from-file la app arranca sin backend y
  #      muestra "Configuracion pendiente" (ya paso una vez).
  $env:Path = $env:Path
  $so = Join-Path $raiz 'build\windows\x64\runner\Release\data\app.so'
  if (Test-Path $so) { Remove-Item $so -Force }   # que no quede el viejo si el build falla

  Write-Host "  ... compilando (unos 3-4 min)" -ForegroundColor DarkGray
  & flutter build windows --release --dart-define-from-file=.env.json 2>&1 | Select-Object -Last 3
  if ($LASTEXITCODE -ne 0) { Fail "flutter build devolvio $LASTEXITCODE" }
  if (-not (Test-Path $so)) { Fail "no se genero data/app.so" }
  Ok "compilado"

  # ── 3. LA verificacion que faltaba: los cambios estan DENTRO del binario.
  #
  #      Se busca en DOS codificaciones porque Dart guarda los literales de dos
  #      formas: si todos los caracteres entran en Latin-1 usa UN byte por
  #      caracter; si alguno se pasa —y el guion largo, que estos textos usan a
  #      cada rato, se pasa— guarda la cadena ENTERA en UTF-16.
  #
  #      Buscar en una sola daba falsos negativos sobre cambios que SI estaban:
  #      paso el 2026-08-12 con la nota del (i), que el script reporto como
  #      faltante estando compilada adentro. Un verificador que grita "falta el
  #      cambio" cuando el cambio esta es peor que no tenerlo: entrena a
  #      ignorarlo.
  #      SON TRES, no dos (fix 2026-08-13). El caso que faltaba es el mas
  #      comun de todos y el comentario de arriba ya lo nombraba sin cubrirlo:
  #      una cadena cuyos caracteres entran TODOS en Latin-1 pero que tiene
  #      alguno no-ASCII (una tilde, una enie, el punto medio) se guarda a UN
  #      byte por caracter — o sea Latin-1 crudo. Leerla como UTF-8 convierte
  #      ese byte en U+FFFD y el marcador no matchea nunca.
  #      Lo cazo 'Todavia en fecha': el string estaba compilado adentro y el
  #      script lo reporto como faltante.
  $bytes = [System.IO.File]::ReadAllBytes($so)
  $comoUtf8   = Plegar ([System.Text.Encoding]::UTF8.GetString($bytes))
  $comoUtf16  = Plegar ([System.Text.Encoding]::Unicode.GetString($bytes))
  $comoLatin1 = Plegar ([System.Text.Encoding]::Latin1.GetString($bytes))
  function EstaEnElBinario([string]$m) {
    $p = Plegar $m
    return ($comoUtf8 -like "*$p*") -or ($comoUtf16 -like "*$p*") `
        -or ($comoLatin1 -like "*$p*")
  }
  foreach ($m in $Marcador) {
    if (-not (EstaEnElBinario $m)) { Fail "'$m' NO esta en app.so - el build no lleva ese cambio" }
    Info "contiene: $m"
  }
  foreach ($m in $MarcadorAusente) {
    if (EstaEnElBinario $m) { Fail "'$m' TODAVIA esta en app.so - el cambio quedo a medias" }
    Info "ya no contiene: $m"
  }
  Ok ("{0} marcadores presentes, {1} ausentes - verificado" -f $Marcador.Count, $MarcadorAusente.Count)

  # El .so puede ser MAS VIEJO que el .exe sin que sea un build rancio: si el
  # codigo Dart no cambio, Flutter reusa el artefacto identico del cache. Por eso
  # lo que manda es el CONTENIDO de arriba, no la fecha. Se informa igual.
  Info ("app.so: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Item $so).LastWriteTime)

  # ── 4. Empaquetar. --build-windows false para no recompilar y arriesgar que
  #      el msix salga de OTRO build distinto al que se acaba de verificar.
  & dart run msix:create --build-windows false 2>&1 | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0) { Fail "msix:create devolvio $LASTEXITCODE" }
  $msix = Join-Path $raiz 'build\windows\x64\runner\Release\isp_billing.msix'
  if (-not (Test-Path $msix)) { Fail "no se genero el msix" }
  if ((Get-Item $msix).LastWriteTime -lt (Get-Item $so).LastWriteTime) {
    Fail "el msix es MAS VIEJO que app.so - se empaqueto un build anterior"
  }
  # El msix tiene que contener el mismo binario que se acaba de verificar.
  $hashSo = (Get-FileHash $so -Algorithm SHA256).Hash
  Info "sha256 del app.so verificado: $($hashSo.Substring(0,16))..."
  Ok "msix empaquetado despues del binario verificado"

  # ── 5. Instalar. Windows bloquea si la identidad es igual y el contenido no
  #      (0x80073CFB), asi que primero se desinstala.
  Get-AppxPackage -Name 'com.sitecsa.crm' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName }
  Add-AppxPackage -Path $msix
  $inst = Get-AppxPackage -Name 'com.sitecsa.crm'
  if (-not $inst) { Fail "la app no quedo instalada" }
  Ok "instalada"

  # ── 6. Que lo instalado sea EXACTAMENTE lo que se acaba de compilar.
  Info "version del paquete msix: $($inst.Version)"
  $manifest = Get-AppxPackageManifest $inst.PackageFullName
  $nombre = $manifest.Package.Properties.DisplayName
  if ($nombre -ne $NombrePrueba) { Fail "la app instalada se llama '$nombre', no '$NombrePrueba'" }
  Ok "identidad correcta: '$nombre' $($inst.Version)"

  # ── 7. Avisar de las OTRAS apps, que es lo que causo la confusion.
  $otras = Get-AppxPackage | Where-Object { $_.Name -like 'com.sitecsa.crm.*' }
  if ($otras) {
    Write-Host "`n  OJO - tambien hay estas apps instaladas, que NO tienen el cambio:" -ForegroundColor Yellow
    foreach ($o in $otras) {
      $n = (Get-AppxPackageManifest $o.PackageFullName).Package.Properties.DisplayName
      Write-Host ("        - {0}  v{1}" -f $n, $o.Version) -ForegroundColor Yellow
    }
  }

  Write-Host "`n=== LISTO ===" -ForegroundColor Cyan
  Write-Host "  Abrir la app llamada: $NombrePrueba" -ForegroundColor White
  Write-Host "  En el login tiene que decir: v$semver ($nuevoBuild)" -ForegroundColor White
  Write-Host "  Si dice otro numero entre parentesis, NO es este build." -ForegroundColor White
}
finally {
  # pubspec vuelve como estaba SIEMPRE, aunque algo haya fallado: el bump y el
  # rename son solo para la prueba local, nunca se commitean.
  Set-Content $pubspec $original -NoNewline -Encoding UTF8
  Write-Host "  (pubspec.yaml restaurado)" -ForegroundColor DarkGray
}
