# 4 — Build de PRUEBA para Android

Para testear en el celular sin tocar nada de producción. Nació el 2026-08-28 a
pedido de Rubén.

---

## Qué la hace segura

Tres barreras, y sólo las dos primeras son estructurales:

| Barrera | Qué impide |
|---|---|
| **`applicationId` propio** (`com.sitecsa.crm.test`) | Android la instala **al lado** de Telecable y Telenet, nunca encima. No puede pisarles datos ni sesión. |
| **Canal privado** (`Template-TT`) + **pre-release** | El `latest` de `sitecsa-updates` —el que consultan las apps oficiales— no se mueve. Y aunque un release de prueba cayera ahí por error, `--prerelease` lo excluye del `latest`. |
| **Cinta "PRUEBA"** en pantalla | Que no confundas cuál abriste. Es visual, no una barrera. |

---

## 🔴 Lo que NO aísla

**La base de datos es la MISMA que producción** (`vxxzesbmilfolwjhfxgr`). Un
cobro registrado desde la app de prueba, con un usuario de una empresa real, es
un cobro real.

Rubén lo evaluó el 2026-08-28 y decidió que alcanza con **usar siempre el Test
Tenant**. La barrera es de disciplina, no de código. Si algún día se quiere una
real, las dos opciones están en `BITACORA.md` de esa fecha (candado por tenant,
o base aparte).

---

## Publicar una versión de prueba

Un solo comando, desde la raíz del repo, con la rama **limpia** (el script
restaura el branding con `git checkout` y aborta si hay cambios sin commitear):

```powershell
.\'Install Steps'\build-release.ps1 -Tenant test -Repo rubenmaltez/Template-TT -PreRelease
```

Las tres banderas importan y ninguna es opcional:

- **`-Tenant test`** → toma `branding/test/config.json`: `applicationId`,
  nombre "CRM TEST" y el manifest `version-test.json`.
- **`-Repo rubenmaltez/Template-TT`** → publica al repo PRIVADO. Desde el
  2026-08-28 el script **también hornea ese repo en la app**
  (`--dart-define=UPDATE_REPO`), así que la build de prueba se auto-actualiza
  desde su propio canal. Antes salía del `.env.json` y una build con `-Repo` se
  publicaba en un lado y se actualizaba desde otro.
- **`-PreRelease`** → GitHub no lo cuenta como `latest`.

> **No corras esto sin `-Repo`.** Sin él publica en `sitecsa-updates`, que es el
> canal de producción, y el release de prueba pasaría a ser el `latest` que
> consultan Mairena y Telenet.

### 🔴 El paso de publicar falla, y no se sabe por qué

**Pasó las TRES veces** (v0.36.31, v0.36.32 y v0.36.33): el build sale bien, y
`gh release create` aborta con `exit 1` y el mensaje `no matches found for -`.
Reintentando **el mismo comando a mano**, con los mismos assets y desde el mismo
directorio, funciona y devuelve `exit 0`.

Lo que se descartó:
- **No son los argumentos.** Se instrumentó `Invoke-Native` con una función
  espejo: los 14 argumentos llegan exactos, sin ningún `-` suelto.
- **No es `--prerelease`.** La primera vez falló igual, antes de que existiera
  esa bandera.
- **No son los assets.** Los tres archivos existen y el comando a mano los sube.
- **No es `Invoke-Native`.** Se replicó la función ENTERA —mismos parámetros,
  mismo `Tee-Object`, mismos argumentos, un tag nuevo— y funciona.

Lo que queda como sospecha, sin confirmar: algo del ESTADO acumulado del script
(variables, `$ErrorActionPreference`, el `gh release view … *> $null` que corre
justo antes y deja `$LASTEXITCODE` en 1). No se aisló.

**Mientras no se resuelva, el flujo es:** correr el script, y cuando aborte en
"Creando release", publicar a mano con los assets que dejó en `Releases\<tag>\`:

```powershell
$a = Get-ChildItem "Releases\v0.36.32" | ForEach-Object { $_.FullName }
gh release create v0.36.32 @a --repo rubenmaltez/Template-TT --title v0.36.32 --notes "Release de prueba" --prerelease
```

El build y la restauración del working tree SÍ funcionan; lo único que falla es
el `gh` de adentro del script.

---

## Bajarlo al celular

El repo es **privado**, así que el link de descarga **da 404 sin sesión**. Dos
caminos:

1. **Desde el celular:** entrar a github.com logueado con la cuenta de Rubén,
   ir a `Template-TT` → Releases → el pre-release → bajar
   `CRM-TEST-vX.Y.Z.apk`.
2. **Desde la PC:** bajarlo acá y pasarlo por cable, WhatsApp o Drive.

Android va a pedir permiso para instalar de orígenes desconocidos: es normal, el
APK no viene de Play Store.

---

## La firma

En los worktrees de trabajo no están `key.properties` ni el `.jks` (viven sólo
en el checkout principal), así que el APK de prueba sale **firmado en modo
debug**. Para esta app está bien —incluso es mejor: no toca la llave de
producción—, pero tiene una consecuencia:

**Hay que buildear siempre desde la misma máquina.** El debug keystore es local
(`~/.android/debug.keystore`); si una versión se firma en otra PC, Android va a
pedir desinstalar la anterior antes de actualizar.

---

## Convivencia con las apps reales

Podés tener las tres instaladas a la vez. Se distinguen por nombre:

| App | Se llama | `applicationId` |
|---|---|---|
| Prueba | **CRM TEST** | `com.sitecsa.crm.test` |
| Telecable | Telecable Mairena S.A. | `com.sitecsa.crm.mairena` |
| Telenet | Telenet | `com.sitecsa.crm.telenet` |

El icono de la de prueba es hoy el genérico (`assets/icon/app_icon.png`): se
distingue por el **nombre**, no por la imagen. Si conviene diferenciarlo, se
reemplaza `branding/test/logo.png` y se rebuildea.
