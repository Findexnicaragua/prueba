# branding/ — white-label por tenant

Cada tenant tiene su carpeta con:

- `logo.png` — **lo que dejás vos.** El logo de la empresa (el mismo del
  recibo). Se usa para el **ícono de la app** (forma A: el logo completo,
  centrado en un cuadrado) y para la **pantalla de login** (banda horizontal).
- `config.json` — nombre visible, slug, y el identificador de paquete
  (Opción B: cada tenant es su propia app). Lo mantiene el AI.

## Dónde dejar cada logo

| Tenant | Archivo a dejar |
|---|---|
| Telecable Mairena S.A. | `branding/mairena/logo.png` |
| Telenet | `branding/telenet/logo.png` |

**Formato del PNG:** fondo blanco o transparente, lo más grande posible
(idealmente ≥ 1000 px de ancho). Es el mismo logo del recibo.

## Cómo se buildea (un solo comando, las dos apps)

```
.\'Install Steps'\build-release.ps1 -AllTenants
```

Recorre cada carpeta de `branding/`, arma el instalador branded de cada
tenant (APK + MSIX con su ícono y nombre) y deja cada uno en su "caja" del
mismo GitHub Release. Cada app instalada se actualiza sola desde su caja.
