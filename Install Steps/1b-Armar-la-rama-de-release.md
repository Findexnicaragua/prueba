# Cómo se arma una rama `release/*` (y por qué no se buildea `main`)

> Escrito el 2026-08-26 armando la **v0.36.6**, después de perder una hora
> creyendo que el dashboard estaba enredado con los reportes. No lo está. Esto
> es la receta, para que la próxima salga en diez minutos.

## 🔻 VIGENCIA: esta receta NO se usa hoy (2026-08-30)

El rediseño del dashboard se terminó y **salió publicado en la v0.37.0**, así
que desde esa versión **se buildea `main` directo** y no hay rama `release/*`.

**Esta receta se conserva a propósito, y no es documentación muerta:** es la
forma probada de sacar una versión cuando `main` tiene trabajo grande a medio
terminar. El día que vuelva a pasar, se sigue tal cual — cambiando la tabla de
archivos por los que correspondan a ese trabajo.

## Por qué existió esta rama

Entre la v0.36.2 y la v0.36.6, `main` tenía el **rediseño del dashboard sin
terminar** y buildearlo se lo habría publicado a los usuarios. La práctica era:
rama de release = `main` **menos el rediseño**, con el dashboard que ya estaba
probado en la calle.

## La receta

Desde este worktree (`C:/sc-release` — **está fuera de OneDrive**, ver el gotcha
de abajo), con `origin/main` ya actualizado:

```bash
git switch -c release/vX.Y.Z release/<la anterior>
git checkout origin/main -- .                 # todo lo nuevo
```

Después se devuelve el dashboard publicado y se saca el rediseño:

| Volver a la versión PUBLICADA | Borrar (solo viven en `main`) |
|---|---|
| `lib/data/providers/dashboard_providers.dart` | `lib/features/admin/dashboard/dashboard_query.dart` |
| `lib/features/admin/dashboard/dashboard_admin_screen.dart` | `lib/features/admin/dashboard/dashboard_export.dart` |
| `lib/features/admin/dashboard/tendencia_cobros_card.dart` | `lib/features/admin/dashboard/recaudo_mora_card.dart` |
| `lib/features/admin/dashboard/info_grafica_textos.dart` | `test/features/admin/dashboard/*` (los del rediseño) |
| `lib/features/admin/dashboard/mora_historica_card.dart` | |
| `lib/features/admin/reportes/excel/reporte_excel.dart` | |

**Lo que NO se toca (se queda el de `main`):**
`lib/features/admin/reportes/reportes_admin_screen.dart` y
`lib/features/admin/reportes/arqueo_query.dart`. **`arqueo_query.dart` no importa
nada** — la mención a `dashboard_query.dart` en su cabecera es un COMENTARIO, no
un import. Si alguien la lee como dependencia (me pasó) concluye que los reportes
dependen del dashboard, y es falso. **Verificá siempre con
`grep -rn "^import.*archivo.dart"`, no con un grep del nombre.**

Después: `flutter analyze lib/ test/` tiene que dar **cero errores**. Es el juez —
si algo quedó colgado, aparece ahí.

## Lo que hay que REAPLICAR a mano

Los archivos que volvieron a la versión publicada **pierden lo que se les hizo en
`main` esa semana**. Al armar la v0.36.6 hubo que reponer, sobre el dashboard
publicado, la deuda suspendida (regla del 2026-08-26):

- `dashboard_providers.dart`: sacar el predicado `noSusp` del titular (4 usos) y
  ampliar los **dos** de Recuperación a `IN ('activo','suspendido')`.
  ⚠️ **`proyeccionCobrosProvider` NO se toca**: pronostica a quién visitar, y a un
  contrato sin servicio no se lo visita por su cuota nueva.
- `dashboard_admin_screen.dart`: el KPI pasa de `'Suspendido (por reactivar)'` a
  `'De eso, suspendido'` — es desglose del titular, no un balde aparte.
- `info_grafica_textos.dart`: los textos del panel `(i)` que declaran el universo
  de cada tarjeta.

**Regla general:** después de restaurar un archivo publicado, mirá qué le hizo
`main` desde el fork (`git diff release/<anterior> origin/main -- <archivo>`) y
decidí explícitamente qué se repone. Lo que no se repone, se pierde en silencio.

## Gotcha de OneDrive

El repo vive en OneDrive y **`git merge` falla ahí** con
`fatal: update_ref failed for ref 'ORIG_HEAD': couldn't set 'ORIG_HEAD'`. No es
permisos: OneDrive intercepta el renombrado del archivo de lock. Por eso la
receta usa `git checkout <ref> -- <paths>` en vez de `git merge`, y por eso este
worktree vive en `C:/sc-release`, fuera de OneDrive. Un `git switch` dentro del
worktree de OneDrive puede además **fallar a medio camino** dejando el árbol roto
(se recupera con `git restore --source=HEAD --worktree --staged .`).

## Firma de Android

`android/key.properties` + el `.jks` son gitignored y **tienen que existir en el
worktree donde se buildea**, o sale un APK debug-signed que las apps instaladas
rechazan. En `C:/sc-release` están.
