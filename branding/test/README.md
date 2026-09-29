# Marca `test` — build de PRUEBA

No es un ISP: es la app para testear en dispositivos reales sin tocar nada de
producción. Nació el 2026-08-28 a pedido de Rubén.

## Por qué existe como una marca más

Reusar el mecanismo de branding sale gratis y da las dos barreras que importan,
sin código nuevo:

- **`applicationId` propio** (`com.sitecsa.crm.test`): Android la instala AL
  LADO de Telecable y Telenet, nunca encima. No puede pisarles los datos ni la
  sesión.
- **`releaseName` propio**: el instalador se llama `CRM-TEST-vX.Y.Z.apk` y su
  manifest es `version-test.json`. Ninguna app oficial pide ese archivo.

## Cómo se publica

Al repo PRIVADO, y como pre-release:

```
.\'Install Steps'\build-release.ps1 -Tenant test -Repo rubenmaltez/Template-TT -PreRelease
```

Las dos banderas importan:

- **`-Repo`** manda los assets a `Template-TT` en vez de a `sitecsa-updates`.
  Desde el 2026-08-28 el script también HORNEA ese repo en la app
  (`--dart-define=UPDATE_REPO`), así que la build de prueba se auto-actualiza
  desde su propio canal y no desde el de producción.
- **`-PreRelease`** hace que GitHub NO lo cuente como `latest`. Es la red por si
  alguna vez se publica en el repo equivocado: aunque caiga en
  `sitecsa-updates`, las apps oficiales seguirían viendo el último estable.

## El icono es provisional

`logo.png` es una copia del icono genérico (`assets/icon/app_icon.png`). Se
distingue por el NOMBRE ("CRM TEST"), no por la imagen. Si conviene diferenciarlo
más, se reemplaza este archivo y se rebuildea — no hay nada más que tocar.

## Lo que esta marca NO hace

**No aísla la base de datos.** Apunta al mismo Supabase que producción
(`vxxzesbmilfolwjhfxgr`). Un cobro registrado desde acá con un usuario de una
empresa real es un cobro real. Rubén lo evaluó el 2026-08-28 y decidió que
alcanza con usar siempre el Test Tenant; la barrera es de disciplina, no de
código. Si algún día se quiere una barrera real, las opciones están en la
BITACORA de esa fecha.
