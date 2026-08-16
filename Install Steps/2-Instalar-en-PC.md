# 2 — Instalar / actualizar en una PC (Windows)

El MSIX está firmado con un **certificado self-signed** (no comprado), así que
hay que confiarlo una vez por máquina. Update **in-place**: no hace falta
desinstalar la versión vieja, los datos viven en el backend.

---

## Opción A (recomendada) — un solo comando

En una PC nueva, Windows **bloquea correr archivos `.ps1` descargados** (el
"execution policy"). Este método lo esquiva: no descargás ningún archivo, corrés
el instalador **en una línea**. Baja la última versión, confía el certificado
e instala solo.

1. Menú Inicio → escribí **PowerShell** → **click derecho → "Ejecutar como
   administrador"**. (Admin hace falta para confiar el certificado; el `.ps1`
   NO — el comando corre desde memoria, por eso Windows no lo bloquea.)
2. Pegá el comando de TU ISP y Enter:

   **Telecable Mairena:**
   ```powershell
   irm https://github.com/rubenmaltez/sitecsa-updates/releases/latest/download/install-mairena.ps1 | iex
   ```

   **Telenet:**
   ```powershell
   irm https://github.com/rubenmaltez/sitecsa-updates/releases/latest/download/install-telenet.ps1 | iex
   ```

Al final muestra: `[OK] ... instalada: vX.Y.Z`. Buscala en el menú Inicio.

> Funciona con Windows PowerShell 5.1+ (el que viene con Windows). No necesita
> instalar nada extra. La primera vez confía el certificado self-signed en la
> máquina; como el cert no cambia entre versiones, se hace **una sola vez** —
> después las actualizaciones (auto-update de la app) entran solas.

### Fallback — si preferís bajar el script

Si no querés el one-liner: bajá el `install-mairena.ps1` / `install-telenet.ps1`
(de esta carpeta o de la [página del último release](https://github.com/rubenmaltez/sitecsa-updates/releases/latest)),
abrí **PowerShell como administrador** y corré (ajustá la ruta):

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\install-mairena.ps1"
```

El `-ExecutionPolicy Bypass` le dice a Windows "ignorá el bloqueo por esta vez".

## Opción B — manual (un instalador puntual)

1. Conseguí el instalador branded versionado (`Telecable-Mairena-CRM-vX.Y.Z.msix`
   para Mairena, `Telenet-CRM-vX.Y.Z.msix` para Telenet): de `Releases\vX.Y.Z\`
   (en la PC de build) o del Escritorio, o bajalo de la página del último release
   `https://github.com/rubenmaltez/sitecsa-updates/releases/latest` (elegí el
   `.msix` del ISP). El nombre incluye la versión.
2. Doble click en el `.msix`.
3. Si Windows dice que el editor no es de confianza:
   - Click derecho sobre el `.msix` → **Propiedades** → pestaña **Firmas
     digitales** → seleccioná la firma → **Detalles** → **Ver certificado** →
     **Instalar certificado** → **Equipo local** → "Colocar en el siguiente
     almacén" → **Personas de confianza** → Aceptar.
   - Volvé a abrir el `.msix` → **Instalar**.

---

## Verificar

Abrí la app → en el **login** (al pie) y en el **sidebar del admin** (abajo)
debe decir `CRM vX.Y.Z` con la versión que instalaste.

## Desinstalar

Corré `uninstall.ps1` (click derecho → Ejecutar con PowerShell). No requiere
admin. Limpia también la cache local de AppData; la data real está en el backend.
