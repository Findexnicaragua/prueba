# REDISEÑO DEL MÓDULO INVENTARIO — PROPUESTA FINAL

> Estado: **PROPUESTA** (mockups + lifecycle). No hay implementación. Fase 2 del lifecycle del proyecto — espera aprobación antes de codear.
> Toda referencia a archivos/líneas es evidencia del código actual.

---

## 1. Resumen del rediseño

Hoy el inventario es **una mega-pantalla de 6 tabs en un archivo de 3159 líneas** (`inventario_screen.dart:20-51`) que mezcla configuración del catálogo con la operación diaria, sin paginación, sin filtros, sin contador real, y con todo el CRUD en `AlertDialog` inline. El rediseño hace tres movimientos: (1) **parte físicamente CONFIG de OPERACIÓN** — el catálogo (productos, categorías, proveedores, ubicaciones, unidades) baja al **Admin Panel/Settings**, y la operación (existencias + equipos) sube a una **vista exclusiva en el menú principal**; (2) consolida el **patrón de lista paginada** del gold-standard de clientes (`clientes_admin_screen.dart` `_ListaState`) en un widget compartido `ListaPaginadaScroll<T>` con scroll-windowing + contador `COUNT(*)` real; (3) consolida la **barra de filtros estándar** (`FiltroMultiDropdown` con chips multi-select y convención "todos=sin filtrar") como `FiltrosBar` reusable. El subproducto es que ambos widgets quedan disponibles para migrar después Clientes y Cobros, cumpliendo el pedido de que sean **estándar de toda la app**. Se conserva intacto el ledger `inv_movimientos` append-only, el lifecycle cuna-a-tumba de seriales, `_InvRowMenu`, `HistorialOpLog` y las guardas `_borrarSiLibre` (TOCTOU).

---

## 2. Info-arquitectura nueva

**Regla de partición:** lo que se toca **una vez al mes** (datos maestros) → Admin Panel. Lo que se toca **todos los días** (existencias y equipos) → vista exclusiva del menú principal.

```
ANTES                                  DESPUÉS
/admin/inventario                      ┌─ MENÚ PRINCIPAL · OPERACIÓN (alta frecuencia)
└─ 6 tabs · 1 archivo (3159 líneas)    │  /inventario
   ├ Existencias  ← OPERACIÓN          │  ├─ tab Existencias  (granel + stock · paginada + filtros)
   ├ Equipos      ← OPERACIÓN          │  └─ tab Equipos      (seriales · paginada + filtros)
   ├ Productos    ← CONFIG             │     └─ /inventario/equipo/:id   (DETALLE — hub cuna-a-tumba)
   ├ Categorías   ← CONFIG             │
   ├ Ubicaciones  ← CONFIG             └─ ADMIN PANEL · SETTINGS · CONFIG (baja frecuencia)
   └ Proveedores  ← CONFIG                /admin/settings/inventario
                                          ├─ Catálogo de productos   (/catalogo)
                                          ├─ Categorías              (/categorias)
                                          ├─ Ubicaciones             (/ubicaciones)
                                          ├─ Proveedores             (/proveedores)
                                          └─ Unidades de medida      (/unidades)
```

| Va al **Admin Panel** (config) | Va a la **Vista exclusiva** (operación) |
|---|---|
| Catálogo de productos (alta/edición de SKU, tipo, unidad, mínimo) | **Existencias**: stock granel, valor, bajo-mínimo, Ingreso, Movimiento |
| Categorías (CRUD + guarda en-uso) | **Equipos**: seriales cuna-a-tumba, asignar/devolver/transferir/baja |
| Ubicaciones, Proveedores | **Detalle de equipo**: hub cliente ↔ tickets ↔ historial |
| Unidades de medida (hoy hardcodeadas, `:2501`) | Escaneo en campo, búsqueda por serial/MAC/cliente |

**A respetar al rutear:** el gate de módulo `'inventario'` (`router.dart:293-295`) aplica a **todas** las rutas nuevas (operativas y de settings); las rutas condicionales `enAdminShell ? '/admin/x' : '/x'` deben existir en **ambas** variantes (checklist audit #5).

---

## 3. Estándares a consolidar para TODA la app

### (a) Patrón de LISTA PAGINADA → `ListaPaginadaScroll<T>`

Componente nuevo en `lib/features/shared/widgets/`, clonado del gold-standard `clientes_admin_screen.dart` `_ListaState` (L961-1262) — la única lista de la app que ya combina las 5 piezas. Encapsula:

1. **Virtualización + ventana SQL:** `ListView.separated` (itemBuilder lazy) sobre una query con `LIMIT` en **subconsulta interna sobre la PK** (L1169-1174) — el SELECT externo agrega solo sobre la página → costo **O(página), no O(tenant)**.
2. **Scroll-windowing:** `_tamPagina=60`, `int _limite`, `ScrollController._onScroll` que crece `+60` al llegar a `maxScrollExtent-600` (L972-1065); pide `LIMIT _limite+1` para detectar `_hayMas` **exacto sin COUNT extra** (L1034-1036).
3. **Contador real:** segunda suscripción `COUNT(*)` con el **mismo WHERE**, sin LIMIT, reactiva, re-suscrita solo al cambiar filtro (L991-1021).
4. **Stream cacheado anti-flicker (regla audit #2):** creado en `initState`, recreado solo en `didUpdateWidget`; **nunca `ps.db.watch` inline en build**. Suscripción a mano → `build` puro.
5. **Spinner vs vacío (M11):** primera carga = spinner; `_filas=null` al refiltrar; `EmptyState` solo si total real = 0.
6. **Cold-start (audit #7):** `ref.listen(dbEpochProvider)` para re-suscribir si la DB se recrea (evita `ClosedException`) — hoy solo lo tiene `cuotas_list`; el widget base lo trae para todos.

Helper de filtro centralizado `construirFiltroInventario` (espejo de `construirFiltroClientes:99-161`) que devuelve `{where, params}` y lo comparten **lista + COUNT(*) + export** → los tres números nunca divergen (consistencia #10).

### (b) BARRA DE FILTROS estándar → `FiltrosBar` (envuelve `FiltroMultiDropdown`)

`FiltroMultiDropdown` (`filtro_multi_dropdown.dart:30-156`) ya es el componente correcto: chip-pill que abre un **`OverlayEntry` anclado con `LayerLink`** (no `showDialog` → respeta checklist #7/#8), multi-select con checkboxes, jerarquía opcional por `grupo`, botones Todos/Ninguno, contador `sel/total`, pill "activa" solo si `n<total`. `FiltrosBar` canoniza lo que hoy vive **inline en cuotas**:

- helper `opcionesDesdeRows(rows, {grupoKey})` = el `_opciones()` de `cuotas_list_screen.dart:120-132` promovido a util.
- regla **`s.isEmpty || s.length >= total ? null : s`** (`cuotas:162-163`) encapsulada en el `onChanged` → ningún call-site la reimplementa, nunca se filtra a lista vacía por accidente.
- sentinela **`FiltroOpcion(id: kSinX, label: 'Sin X')`** para NULLs de FK (`cuotas:149-150`).
- botón **"Limpiar (N)"** + contador `filtrosActivos` (`cuotas:186-204`).
- búsqueda interna del dropdown migrada a **`foldBusqueda`** (hoy `toLowerCase().contains`, ASCII-frágil, `:214`) para matchear "CAÑO" tipeando "cano".

**Migración app-wide:** reemplazar el `showModalBottomSheet` single-select + `FilterChip` booleano de Clientes (`clientes_list_screen.dart:170-175`) por `FiltrosBar`, de modo que Clientes, Cobros e Inventario filtren con **exactamente el mismo componente y comportamiento**.

---

## 4. Mejora de AGREGAR item + categoría

**Problema actual.** Agregar producto (`_ProductoDialog:2479-2709`) es un `AlertDialog` denso que, para crear una categoría sobre la marcha, abre **otro `AlertDialog` anidado** (`_crearCategoriaInline:2528`) — dialog-dentro-de-dialog, con código de op_log y pre-check de duplicado **duplicados** respecto del camino "oficial" de la tab Categorías (`_crear:655`). Además: unidades de medida **hardcodeadas** (5 fijas, `:2501`), el bloqueo de tipo serializado/granel cuando ya hay movimientos (`:179-193`) solo se descubre **al fallar el guardado**, y no hay previsualización.

**Flujo nuevo (por qué es mejor):**

1. **Categoría inline de UN solo camino.** El "+ Nueva" junto al dropdown **expande un campo en la misma tarjeta** (no abre otro diálogo). Llama a **un único helper de creación de categoría** compartido con la pantalla de Categorías → se elimina el código duplicado y la divergencia de op_log/pre-check.
2. **Aviso de tipo inmutable ANTES de fallar.** Texto `ⓘ No se puede cambiar si ya hay movimientos` junto al selector Granel/Serializado, en vez de un error post-submit.
3. **Unidades de medida editables.** El dropdown se alimenta de una fuente de config ("gestionar unidades") en lugar de la lista fija — decisión de Fase 2: tabla `inv_unidades` (Receta R10 completa) vs lista en settings (más simple).
4. **Búsqueda y unicidad con `foldBusqueda`/`foldSqlExpr`** (audit #1d): habilitar ñ/acentos en nombre/SKU sin arreglar la búsqueda downstream deja el registro invisible.
5. Se **conserva** `_InvRowMenu` (Editar/Historial/Eliminar) y la guarda `_borrarSiLibre:2767` (re-chequeo TOCTOU dentro de la tx).

---

## MOCKUPS A RENDERIZAR

### [1] Vista exclusiva — EXISTENCIAS — stock de granel/productos, alta frecuencia

**Layout.** `Scaffold` con `TabBar` de 2 tabs (Existencias | Equipos) arriba. Cuerpo vertical: buscador → `FiltrosBar` (chips) → header-contador → lista paginada. FABs: `Ingreso` (extended) + `Movimiento` (small) — equivalentes a `:814-833` pero con icono/etiqueta claros.

**Componentes/campos.**
- Buscador `TextField` con debounce 250ms (`clientes_list_screen.dart:76-86`); busca `nombre` y `codigo`/SKU con `foldBusqueda`/`foldSqlExpr` (#1d), nunca `lower()` pelado.
- Header-contador real: `"148 productos · 12 bajo mínimo · valor C$ 284,500"` — segunda suscripción `COUNT(*)`/agregación con el mismo WHERE (`Fmt.cordobas`).
- FAB Ingreso → mockup [6]; FAB Movimiento → egreso/ajuste/transferencia de granel.

**Filtros (chips).** Categoría (`inv_categorias` → `inv_productos.categoria_id`, sentinela "Sin categoría") · Ubicación (`inv_ubicaciones` → stock por ubicación) · Tipo (estático: Serializado / Granel → `es_serializado`) · `▢ Solo stock bajo` (toggle: `stock < stock_minimo OR stock<=0`).

**Columnas/estados de lista.** Por fila: icono por tipo (📦 granel / 📡 serializado) · nombre · categoría · costo promedio + valor · **stock con unidad a la derecha, en ROJO si bajo** (lógica `:858`) + "mín N" · badge `serializado`. En serializados, el subtítulo enlaza **"X instalados →"** que abre la tab Equipos **pre-filtrada por ese producto**. Tap en fila → bottom sheet stock-por-ubicación (`_verStockPorUbicacion`, existente).

**Variantes/estados.** Spinner en primera carga (M11) · `EmptyState "Sin existencias"` solo si total=0 · al refiltrar `_filas=null`→spinner · fila bajo-mínimo resaltada.

---

### [2] Vista exclusiva — EQUIPOS — seriales cuna-a-tumba, la pantalla que hoy más sufre

**Layout.** Misma `TabBar`. Cuerpo: buscador (+ botón Escanear en Android) → `FiltrosBar` → header-contador → lista paginada (scroll-windowing).

**Componentes/campos.**
- Buscador por `serial`, `mac`, `cliente.nombre` (fold). Botón **Escanear** (cámara) que pre-llena el buscador con el código leído → encuentra el equipo al instante en campo.
- Header-contador: `"1 240 equipos · 312 instalados · 28 en stock · 9 dañados"`.

**Filtros (chips).** Estado (estático: en_stock / instalado / dañado / retirado / baja → `inv_seriales.estado`; **default = excluye `baja`** para mostrar lo vivo) · Producto (`inv_productos` serializados → `producto_id`) · Ubicación (`inv_ubicaciones` → `ubicacion_id`) · Cliente (`clientes` con equipo → `cliente_id` + sentinela "Sin cliente").

**Columnas/estados de lista.** Query = el JOIN actual pero **con `LIMIT _limite+1` en subconsulta sobre `inv_seriales.id`** (agrega producto/cliente solo sobre la página). Por fila: icono 📡 · serial mono · **pill de estado color-coded** (`● en stock` verde · `instalado` azul · `dañado` ámbar · `retirado` gris · `baja` tachado, reusa `_estadoSerial:1847`) · subtítulo `producto · ubicación` o `producto · en {cliente} (#contrato)` · **acción primaria SIEMPRE visible** en el trailing (no PopupMenu escondido): `en_stock → [Asignar ▸]`, `instalado → [Ver ficha ▸]`, resto → `[⋯]` (devolver/baja/historial). Tap en fila → **Detalle de equipo** [3].

**Variantes/estados.** Spinner M11 · `EmptyState "Sin equipos"` solo si total=0 · pill por estado.

---

### [3] DETALLE DE EQUIPO — el hub cuna-a-tumba — `/inventario/equipo/:id`

> Lo que hoy **no existe**: el único lugar rico es un bottom-sheet de historial (`_showHistorialSerial:3132`). Esta ficha materializa el vínculo equipo ↔ cliente ↔ tickets ↔ historial (punto 5 de Rubén).

**Layout.** Pantalla scrolleable de bloques apilados: Header → Cliente → Ubicación → Tickets → Acciones → Historial. AppBar con `‹ Equipos`, serial, `[⋯]`.

**Componentes/campos por bloque.**
- **Header:** pill de estado grande + `serial · MAC · producto · categoría`.
- **CLIENTE** (solo si `cliente_id != null`): `👤 nombre · Contrato #N (Plan)` + dirección, botón **[Ver ▸]** → ficha del cliente (`/clientes/:id` o variante admin). Cierra el gap "la UI no deja navegar al cliente".
- **UBICACIÓN ACTUAL:** `inv_seriales.ubicacion_id` o "en domicilio del cliente".
- **TICKETS QUE LO USARON** (contador): tickets cuyo `ticket_materiales` consumió este serial (trigger existente); cada uno linkea a su detalle. **Hace visible el vínculo que hoy solo vive en datos.**
- **ACCIONES contextuales por estado** como botones visibles (no PopupMenu): `[Devolver a stock] [Transferir] [Dar de baja]` / `[Asignar]` — reusan `_asignar:1899`, `_devolver`, `_transferir`, `_darDeBaja`.
- **HISTORIAL:** `HistorialOpLog` por entidad serial embebido al pie, **sin LIMIT** (vida completa).

**Variantes/estados.** Sin cliente → se oculta el bloque CLIENTE y la acción primaria es `[Asignar]` · estado `baja` → acciones deshabilitadas, header tachado · sin tickets → "Aún no usado en tickets".

---

### [4] AGREGAR / EDITAR producto — form de alta rápida (categoría inline 1-camino)

**Layout.** `showModalBottomSheet`/pantalla de form (no AlertDialog anidado). Campos verticales; sección que cambia según Tipo.

**Componentes/campos.** Nombre* · Código/SKU · **Categoría*** (dropdown + **"+ Nueva" que expande un campo EN LA MISMA tarjeta**, no abre otro diálogo) · **Tipo** (radio Granel/Serializado, con `ⓘ No se puede cambiar si ya hay movimientos`) · si **Granel**: Unidad (dropdown editable + "⚙ gestionar unidades") + Stock mínimo + `▢ admite fracciones` · si **Serializado**: Stock mínimo (alerta cuando bajen las unidades). Footer `[Cancelar] [Guardar producto]`.

**Filtros (chips).** N/A (es form).

**Variantes/estados.** Crear vs Editar (en Editar, Tipo bloqueado si ya hay movimientos, con el aviso ya visible) · validación de duplicado de Nombre/SKU con `foldSqlExpr` antes de persistir · creación de categoría inline → un único helper compartido (sin op_log duplicado).

---

### [5] CONFIG en Admin Panel — Catálogo + Categorías (y barra de FILTROS desplegada)

**5a. Catálogo de productos** — `/admin/settings/inventario/catalogo`
- **Layout:** AppBar `‹ Settings · Inventario › Catálogo` + `[+ Producto]`; buscador + `FiltrosBar` (Categoría, Tipo) + contador; lista paginada.
- **Columnas:** icono · nombre · `serializado | granel (unidad)` · categoría · `mín N` · `[✎]`. Tap/✎ → form [4].

**5b. Categorías** — `/admin/settings/inventario/categorias` (Ubicaciones/Proveedores = mismo patrón)
- **Layout:** AppBar + `[+ Nueva]`; buscador + contador `"12 categorías"`; lista simple (pocas filas → paginación opcional).
- **Componentes:** fila = nombre · `N productos · M unidades` (contexto para borrar) · `_InvRowMenu` (Editar / Historial / Eliminar). Borrar usa guarda `_borrarSiLibre:2767` (re-chequeo TOCTOU). "+ Nueva" = el **mismo helper** que el inline del form de producto.
- **Variantes:** color/ícono/orden = backlog (no bloquea).

**5c. Barra de FILTROS desplegada (`FiltroMultiDropdown` abierto)** — spec del overlay
- **Layout:** chips horizontales en `SingleChildScrollView(Axis.horizontal)`. Al tocar un chip se abre un **`OverlayEntry` anclado con `LayerLink`** debajo del chip (no `showDialog`).
- **Contenido del overlay:** TextField de búsqueda interna (con `foldBusqueda`) → fila `[Todos] [Ninguno]` → lista de checkboxes (con jerarquía por `grupo` y cabecera tri-estado cuando aplica) → footer `"N/total"`. Aplica **al instante** (cada toque dispara `onChanged`).
- **Estado del chip:** "activo" (color primario + badge `$n`) solo cuando `n < total`; "todos seleccionados" se pinta neutro = sin filtrar. Botón **"Limpiar (N)"** a la derecha de la barra resetea todos a null.

---

## GRÁFICO LIFECYCLE

**Propósito.** Mostrar el ciclo de vida de un EQUIPO (estados de `inv_seriales.estado`), los eventos que disparan cada transición, y cómo se entrelaza con CLIENTE y TICKETS. Para que un diseñador lo dibuje como diagrama de estados con dos "carriles de vínculo" laterales.

**Nodos (estados — color-coded como en la lista [2]).**
- `EN_STOCK` (verde) — en bodega/ubicación, contado como stock físico.
- `INSTALADO` (azul) — `cliente_id` + `contrato_id` set; en domicilio del cliente.
- `DAÑADO` (ámbar) / `RETIRADO` (gris) — fuera de servicio, recuperable.
- `BAJA` (tachado) — **terminal**, no vuelve (motivo + op_log).
- Nodo de origen CONFIG: `Producto serializado en Catálogo` (define `es_serializado`).

**Aristas (eventos · qué columna toca).**
- Catálogo → `EN_STOCK`: **INGRESO** (factura, proveedor, seriales+MAC, costo promedio ponderado).
- `EN_STOCK → INSTALADO`: **ASIGNAR** a cliente (set `cliente_id`/`contrato_id`).
- `INSTALADO → EN_STOCK`: **DEVOLVER** (vuelve de cliente).
- `EN_STOCK → EN_STOCK`: **TRANSFERIR** entre ubicaciones (cambia `ubicacion_id`, sigue en stock).
- `INSTALADO/EN_STOCK → DAÑADO/RETIRADO`: **falla / retiro**.
- `DAÑADO/RETIRADO → EN_STOCK`: **DEVOLVER reparado**.
- `DAÑADO/RETIRADO → BAJA`: **irreparable** (terminal).
- Lazo transversal: **cada transición emite una fila `op_log`** (1 por objeto, en la tx) → alimenta el HISTORIAL.

**Carril de vínculo CLIENTE** (sale de `INSTALADO`).
`INSTALADO` → `clientes.cliente_id`/`contrato_id` → **Ficha del cliente** muestra el equipo y su contrato. La ficha del equipo [3] linkea de vuelta a la ficha del cliente.

**Carril de vínculo TICKETS** (sale de `INSTALADO` y del consumo de stock).
`ticket_materiales` consume el serial vía **trigger server** → la ficha del equipo [3] lista los tickets que lo usaron (🎫 #318 Instalación, 🎫 #402 Sin señal) → cada uno linkea a su detalle.

**Dónde se ve cada estado/evento (leyenda del diagrama).**
- Lista **Equipos** [2] → pill de estado + filtros Estado/Producto/Ubicación/Cliente.
- **Existencias** [1] → `COUNT(estado='en_stock')` por producto = verdad física del stock.
- **Ficha cliente** → equipos instalados de ese cliente.
- **Detalle ticket** → materiales consumidos.
- **Historial** (op_log) → toda transición, cuna a tumba, sin LIMIT.

**Invariante del lifecycle (ya en el código, lo respeta el rediseño).** El stock serializado se deriva de `COUNT(estado='en_stock')` (`inventario_screen.dart:794-798`), **no** del ledger → un movimiento con ubicación NULL o una doble asignación no inflan el stock; `baja` es terminal; cada transición emite `op_log`.

---

### Archivos citados como evidencia
- `lib/features/admin/inventario/inventario_screen.dart` — actual: tabs `:20-51`; Existencias `:772/:791-809/:858`; Equipos sin LIMIT `:1800/:1812-1819/:1847/:1855`; `_asignar` wizard `:1899`; `_MovimientoDialog` 3-en-1 `:1203`; `_IngresoDialog` `:1531/:1565`; `_ProductoDialog` `:2479-2709` + categoría inline duplicada `:2528` + unidades hardcode `:2501`; categoría tab `_crear:655`; bloqueo de tipo `:179-193`; stock serializado por COUNT `:794-798`; guarda borrar `:2767`; `_ClientePicker:2228`; historial `:3101/:3132`.
- `lib/features/admin/clientes/clientes_admin_screen.dart` — gold-standard de lista `_ListaState:961-1262` (windowing `:972-1065`, COUNT `:991-1021`, LIMIT+1 `:1034-1036/:1134`, subconsulta PK `:1169-1174`, helper filtro `:99-161`, spinner M11 `:1192`).
- `lib/features/cuotas/cuotas_list_screen.dart` — filtros: opciones `:120-132`, regla todos=null `:162-163`, sentinela `:149-150`, Limpiar `:186-204`, dbEpoch `:260-262`.
- `lib/features/clientes/clientes_list_screen.dart` — debounce `:76-86`, stream cacheado `:289-312`, anti-patrón bottomsheet `:170-175`.
- `lib/features/shared/widgets/filtro_multi_dropdown.dart` — base `:30-156`, overlay anclado `:28-29`, búsqueda ASCII a migrar `:214`.
- `lib/features/shared/widgets/cargar_mas_button.dart` — sentinel alternativo.
- `lib/config/router.dart` — gate módulo `:293-295`, ruta actual `:465-466`.

Es una **PROPUESTA** — no se implementó nada. Espera aprobación (Fase 2) antes de codear.