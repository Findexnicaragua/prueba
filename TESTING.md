# Guía de testing del sistema

Pasos para validar que el sistema funciona end-to-end.
- La **sección 0** es el loop de TODOS los días (lo que hace Rubén para probar un
  cambio nuevo en Windows). Es lo que más se pierde entre sesiones → mantenerla viva.
- Las **secciones 1-5** son el setup/smoke completo (correr una vez tras desplegar
  Supabase o ante un cambio grande).

---

## 0. Loop de testing manual (uso diario en Windows)

> **Claude: cuando entregues un cambio, dale a Rubén los pasos en ESTE formato**
> (qué hacer → qué debería ver → qué hacer si falla). Si el cambio toca un feature,
> agregá/actualizá su checklist en §0.3.

### 0.0 GATE de build fresco (hacer ANTES de cualquier checklist de §0.3)

> **Antes de testear un cambio, confirmá que el dispositivo corre el código recién
> compilado.** Sin este gate terminás testeando la app INSTALADA vieja y diagnosticando
> como "bug de sync/código" lo que en realidad es código que nunca se compiló. (Pasó
> exacto: sesión 2026-06-17, se testeó la v0.11.9 instalada creyendo que era v0.11.10.)
>
> **No es un trámite: se perdieron rondas enteras por saltearlo.** En la sesión de
> impresión (2026-08-07) varios "sigue cortando igual" eran el build ANTERIOR — cada
> ajuste de recibo/ESC-POS es código Dart y **exige recompilar**, y en Windows conviven
> la app instalada por MSIX y el dev-build.
>
> **REGLA: leé la versión EN PANTALLA y confirmala ANTES del primer paso de cualquier
> checklist.** Si no coincide con la esperada, no hay nada que testear todavía —
> cualquier resultado que anotes es del código viejo.

**Claude: en TODO handoff de testing escribí al inicio la VERSIÓN SEMVER ESPERADA**
(la de `pubspec.yaml`, línea `version: X.Y.Z+NNN` → el `X.Y.Z`). Rubén la confirma
visualmente antes de tocar nada.

1. **Cerrá TODAS las instancias viejas primero.** Puede haber varios `isp_billing.exe`
   abiertos a la vez (la app instalada por MSIX + el dev-build) y es fácil mirar el
   equivocado. En PowerShell:
   `Get-Process isp_billing -ErrorAction SilentlyContinue | Stop-Process`.
   También cerrá la versión instalada desde el menú Inicio si la abriste.
2. **Recompilá y corré el build de testeo** (NO la instalada):
   ```powershell
   flutter run -d windows --dart-define-from-file=.env.json
   # o solo el .exe con el .env baked, sin la consola de flutter run:
   flutter build windows --dart-define-from-file=.env.json
   .\build\windows\x64\runner\Release\isp_billing.exe
   ```
   > Este build LOCAL de testeo **no** publica a GitHub. Publicar es otra cosa
   > (`Install Steps\build-release.ps1`, solo para distribuir a dispositivos).
3. **Verificá la versión SEMVER en pantalla** = la esperada. Se muestra en **login**,
   **sidebar admin** y **perfil del cobrador**. Si NO coincide → estás mirando la app
   instalada vieja: volvé al paso 1.
4. **NO confíes en el timestamp del `.exe`.** `isp_billing.exe` es el shell C++ y **no
   cambia de fecha al recompilar**. Lo que cambia con el código Dart es
   `build\windows\x64\runner\Release\data\app.so` — ese SÍ debe tener fecha reciente:
   `(Get-Item .\build\windows\x64\runner\Release\data\app.so).LastWriteTime`.
5. **Cuándo recompilar:** cualquier cambio de código Dart entregado en la sesión. Hot
   reload (`r`) solo sirve dentro de un `flutter run` ya corriendo SOBRE el código nuevo;
   si la app abierta es la instalada o un build viejo, no hay hot reload — recompilar.
6. **Los ajustes por-dispositivo NO se pierden al recompilar** (impresora, modo de
   impresión, ancho de línea…: viven en las preferencias de ESA PC, no en el build). Dos
   tells útiles: si tras recompilar el papel sale igual de mal, el sospechoso es el
   AJUSTE, no el build; si un control que la sesión dice que existe **no aparece** en la
   pantalla, el sospechoso es el BUILD.

*Si falla:* la versión en pantalla no es la esperada o `app.so` tiene fecha vieja → no
sigas con los checklists; primero arreglá que corra el build fresco.

### 0.1 Traer el cambio y correr

```powershell
# 1) Parado en la branch de trabajo (ver BITACORA.md § ESTADO ACTUAL cuál es)
git checkout <branch-de-trabajo>
git pull origin <branch-de-trabajo>
git log --oneline -1            # confirmar el commit esperado

# 2) Correr en Windows
flutter run -d windows --dart-define-from-file=.env.json
```

**Reglas de oro del loop:**
- **Cambios en `router.dart`, `main.dart`, providers globales o el schema** → NO
  alcanza hot reload (`r`). Hay que **restart completo**: `q` y volver a `flutter run`
  (o Shift+R). El `GoRouter` se construye una vez en `routerProvider`.
- **Cambios de UI normal** (un widget, un texto) → hot reload (`r`) suele alcanzar.
- **Cambios de columna/tabla/sync** → seguir el checklist de integridad de AGENTS.md
  (migración en Supabase + `schema.dart` + redeploy sync rules + restart desde cero).
  Aditivos NO bumpean `_dbWipeVersion` (in-place, sin re-descargar; política R4).
  Sin migración nueva ⇒ NO tocar Supabase.

### 0.2 Si hay dinero involucrado (pagos/cuotas/recibos/reportes)

Antes del testing manual, las capas automáticas (ver §4 del modelo de 4 capas en
AGENTS.md):
1. Audit estático (agentes) — ya corre en la sesión.
2. `supabase/tests/invariantes_dinero.sql` — toda fila debe dar `violaciones = 0`.
3. `flutter test` (pagos_repo y lógica crítica).

En la app, el equivalente es Configuración → **Operaciones** → **"Verificar invariantes
de dinero"** (solo super_admin). *Nota:* hasta la migración `0219`, **INV11**
("contrato fijo con cuotas de más o de menos") marcaba **falso positivo** en TODO
contrato fijo suspendido (el literal del motivo de anulación estaba corrupto y la
reintegración de las cuotas anuladas por suspensión nunca matcheaba). Ya está corregido
en producción: si volvés a ver INV11 sobre un suspendido-y-reactivado, ahora SÍ es data.

### 0.3 Checklists por feature (manual)

> Plantilla: **qué hacer → qué deberías ver → si falla**. Rubén: corregí/ampliá
> estos pasos con tu flujo real cuando algo no coincida.

**0.3.0-bis — Paquete tickets/inventario del nuevo dueño (Fases 1-4, 2026-07-26).**

> **Build esperado: v0.29.8** (o superior). CORREGIDO 2026-07-29: la rama
> `feature/tickets-inventario-nuevo-dueno` YA NO EXISTE — este paquete quedó en
> `main` y viene incluido en los releases desde la v0.29.4, así que **no hace falta
> buildear nada**: alcanza con actualizar a la última publicada. Igual corré el GATE
> de §0.0 para confirmar que la app que abrís es la nueva y no la instalada vieja.
>
> **Rol/identidad:** todo con identidad REAL, **nunca impersonando** — las acciones
> quedan atribuidas a quien las ejecuta. Hacen falta 4 usuarios: `tecnico`,
> `coordinador` (NUEVO), `admin_tickets` (hace de call center) y `admin_usuarios`
> (hace de gestor). El `admin` sirve para el inventario.

> **PREPARACIÓN de Test Tenant (verificado 2026-07-27 — sin esto, medio checklist no
> se puede correr):**
>
> | # | Qué | Por qué |
> |---|---|---|
> | 1 | ~~Habilitar `tickets` e `inventario`~~ **✅ HECHO 2026-07-29** (por SQL, verificado) | Estaban en `false`: sin esto NO se ve nada |
> | 2 | Crear 3 usuarios: `tecnico`, `coordinador`, `admin_tickets` | Solo existen admin, admin_cobranza, admin_usuarios y 2 cobradores. **Los roles de tickets solo aparecen en el selector si el módulo YA está habilitado** → hacer esto DESPUÉS del punto 1 |
> | 3 | Crear una ubicación tipo **"Custodia de técnico"** asignada al técnico | Solo existe "Bodega Central". Sin custodia propia el técnico no puede cargar material: la app le dice "No tenés una custodia asignada" |
> | 4 | ~~Al tipo **"Instalación"** efecto = **instalación**~~ **✅ HECHO 2026-07-29** | Tenía `ninguno` → la orden cerrada NUNCA caía en "Por verificar" y la Fase 4 parecía rota |
> | 5 | ~~Crear ubicación **"Redes / planta"**~~ **✅ HECHO 2026-07-29** | Para probar el destino nuevo |
>
> Los 4 seriales de prueba (`RT-TEST-*`) están todos en stock sin cliente: el primero
> se instala como parte del checklist y recién ahí se puede probar el retiro.

> ✅ **Módulos habilitados en Test Tenant (2026-07-29).** Mairena y Telenet siguen SIN
> las filas a propósito: el paquete está en producción pero DORMIDO (nadie tiene los
> roles nuevos tampoco). No prenderlos ahí hasta que este checklist pase.
>
> ⏳ **LO QUE FALTA para arrancar: los 3 usuarios** (`tecnico`, `coordinador`,
> `admin_tickets`) y la **custodia del técnico**, que depende de que el técnico exista.
> Los usuarios se crean desde la app —así se ejercita el onboarding real— y sus roles
> ya aparecen en el selector porque los módulos están prendidos.

| # | Qué hacer | Qué deberías ver | Si falla |
|---|---|---|---|
| 1 | Como admin, en un equipo `instalado` en un cliente: "Mandar a revisión" | Queda "En revisión", sale del cliente y NO aparece como stock en ninguna bodega | Si suma stock en algún lado, el ledger quedó mal (ver 0204) |
| 2 | Desde "En revisión": "Aprobar y devolver" a una bodega | Vuelve a "En stock" en esa bodega, sumando 1 | — |
| 3 | Otro equipo en revisión → "Mandar a descarte" | Queda en "Descarte" (antes decía "Baja") y no suma a ninguna bodega | — |
| 4 | Crear una ubicación tipo "Redes / planta" | Aparece en el selector de ubicaciones | — |
| 5 | Como técnico, abrir una orden asignada → "Marcar ubicación" | Botón pasa a "Ubicación marcada" y en la ficha aparece "Trabajó acá" con coordenadas | Si el GPS falla debe salir un mensaje, no un spinner infinito |
| 6 | Tocar "Trabajó acá" | Abre el mapa del teléfono en ese punto | — |
| 7 | Como técnico con 2+ órdenes asignadas | Solo la primera se abre; las demás con candado y "Se habilita al resolver la orden de arriba" | Si se abren todas, la cola no está aplicando |
| 8 | Resolver la primera | La segunda se habilita SOLA, sin que nadie cierre nada | Si sigue bloqueada, la cola está esperando el cierre (mal) |
| 9 | Como técnico, en una orden de un cliente con equipo instalado: "Retirar" | El equipo desaparece de la lista; al sincronizar queda "En revisión" | Si el server lo rechaza, revisar `ticket_materiales.tipo` |
| 10 | Como **coordinador**: abrir una orden | Ve SOLO "Asignar técnico" y "Mover en la cola". Sin comentar, sin adjuntar, sin materiales, sin botón de crear orden | Si ve alguno de esos, faltó el gate de `_noEditaTrabajo` |
| 11 | Como coordinador: "Mover en la cola" → "Primera" | La orden pasa al frente de la cola de ese técnico | — |
| 12 | Como call center, sobre una orden `resuelto`: "Registrar intento" ×3 | En la bitácora salen como **"Intento de contacto"** (no "contacto" crudo) y aparece "Cerrar sin confirmar" | Si el botón no aparece: faltan intentos o días (el texto dice cuál) |
| 13 | "Cerrar sin confirmar" sin escribir motivo | No deja cerrar | — |
| 14 | Con motivo → cerrar | Cierra; en el filtro "Resueltos" la tarjeta de salud del cierre muestra el % | — |
| 15 | Cerrar una orden cuyo tipo tenga `efecto = instalacion` | Como **gestor**, en /admin/solicitudes → "Por verificar" aparece esa orden | Si no aparece: el tipo no tiene `efecto=instalacion`, o falta el módulo |
| 16 | Como gestor: "Verificada" | Desaparece de la bandeja | Si el server la rechaza, revisar la policy de 0210 |

**0.3.0 Convención: ROL/IDENTIDAD de prueba (obligatorio en cada checklist).**

> **Cada checklist declara con qué ROL e IDENTIDAD se prueba.** Un feature gateado por
> rol probado bajo el rol equivocado parece un bug que no existe. (Pasó exacto: sesión
> 2026-06-17, se probó "Registrar visita" IMPERSONANDO y pareció roto — está oculto y
> bloqueado a propósito al impersonar.)

**Claude: al entregar un feature, agregá al inicio de su checklist una línea
`*Rol/identidad:*`** con qué rol lo prueba (`super_admin` sesión propia / `admin` /
`admin_cobranza` / `cobrador` build de cobrador / `tecnico`) y si aplica o no impersonando.

**Caveat de impersonación (CRÍTICO).** Cuando el super_admin **impersona** un tenant,
opera con su PROPIA fila real (tenant System), no con un usuario del tenant. Por eso las
features que **se ATRIBUYEN al usuario que las ejecuta** están **ocultas y/o bloqueadas al
impersonar, por diseño** — y NO se pueden probar impersonando; hay que loguearse como un
usuario REAL de ese rol. Ejemplos confirmados:
- **Registrar visita** (`cobrador`/`tecnico`): oculta impersonando (`cliente_detail_screen.dart`,
  guard `if (!impersonando)`) y bloqueada en el servicio (`visitas_service.dart` lanza
  `StateError`) → se atribuiría al super_admin en el tenant System.
- **Cobrar / registrar pago / emitir recibo:** capturan `pagos.cobrador_id` /
  `recibos.cobrador_id` = quién cobró (NOT NULL). Probar impersonando ensuciaría el
  historial → probar como cobrador/admin real.
- **Suspender / Reactivar / Cancelar contrato:** el cobrador NO los ve; impersonando
  TAMPOCO. Se prueban como admin del ISP real.

**Regla general:** si la acción deja rastro de "quién la hizo" (visita, pago, recibo,
cambio auditado atribuido al usuario), NO la pruebes impersonando — usá la identidad real
del rol. Si solo LEE o configura (settings, reportes, listados), impersonar está bien.

**0.3.1 — Impresión de recibos en PC (Windows/USB): calibrar una impresora nueva
(v0.31.14 → v0.31.22).**

> **Build esperado: v0.31.22** (o superior). Corré ANTES el GATE de §0.0 — cada ajuste
> de impresión es código Dart: sin recompilar estás mirando el recibo viejo.
>
> **Rol/identidad:** cualquiera que emita recibos (admin / admin_cobranza / cobrador),
> con identidad REAL si vas a cobrar. Para calibrar NO hace falta cobrar: **reimprimí un
> recibo YA existente** (Historial de pagos → abrir el recibo → Imprimir) y no ensuciás
> la caja.
>
> **Dónde:** en la pantalla del recibo, botón **"Configurar impresora"** / **"Cambiar
> impresora (…)"** — es el camino que sirve a TODOS los roles. El cobrador/técnico
> también llega por Perfil → **Impresora térmica**. **Todos estos ajustes son de ESA
> COMPUTADORA** — no viajan al celular ni a otra PC: cada equipo se calibra una vez.
> **Android/Bluetooth no cambió**: imprime byte-idéntico a antes, no hay que re-testearlo.

*A — Elegir la impresora.*

| # | Qué hacer | Qué deberías ver | Si falla |
|---|---|---|---|
| 1 | En "Impresoras del sistema", ⋮ de la tuya → "Usar como predeterminada" | Sube a la tarjeta **"Impresora predeterminada"** con su nombre | No está en la lista → encendela/instalala en Windows y tocá ↻ (Buscar impresoras) |
| 2 | Tocá **Prueba** | Sale la tira de prueba; el snackbar dice "Prueba enviada **(modo directo)**" | "esta impresora no acepta el modo directo" → pasá Modo de impresión a **"Por driver de Windows"** (camino viejo, siempre disponible) y saltá el resto |

*B — REGLA DE ANCHO: MEDIR el cabezal en vez de adivinarlo.* El ancho nominal (48
caracteres en 80mm) NO es el que imprime cada térmica — varias imprimen menos y recortan
la derecha. Esto lo mide en un solo tiro.

| # | Qué hacer | Qué deberías ver | Si falla |
|---|---|---|---|
| 3 | Modo de impresión → **Texto nativo** (el botón de la regla y el slider de ancho SOLO aparecen en ese modo) → **"Imprimir regla de ancho"** | Tira con el título "REGLA DE ANCHO" + líneas numeradas **en los DOS extremos** (`42----…----42`), de 2 en 2 | "Elegí primero una impresora predeterminada" → volvé al paso 1 |
| 4 | Buscá la línea más larga que tenga su número **a la IZQUIERDA y a la DERECHA de la MISMA línea**. Anotá ese número | En la 3nStar RPT004 de 80mm da ~42-44, **no 48** | Falta el número derecho → esa línea se TRUNCA. Reaparece solo al principio de la línea siguiente → ENVUELVE. En ambos casos esa medida NO vale: quedate con la anterior |
| 5 | Cargá ese número en el slider **"Ancho de línea"** | El slider muestra "N caracteres" y el recibo de texto deja de cortarse a la derecha | — |

> **Migración v0.31.22:** si venías con el ancho en 46-48, la app lo **descarta una sola
> vez** (antes ese valor no se aplicaba, así que no fue una elección informada, y hoy te
> cortaría el recibo) y el slider vuelve a mostrar **42** = "sin configurar". Es a
> propósito: volvé a medir con la regla.

*C — Modo IMAGEN (el default, fiel a la vista previa).*

| # | Qué hacer | Qué deberías ver | Si falla |
|---|---|---|---|
| 6 | Modo → **Imagen (recomendado)** → imprimí un recibo | Igual a la vista previa, con **márgenes parejos a los dos lados** (no corrido a la izquierda) | Corrido/asimétrico = build viejo (§0.0): la compensación de la zona muerta del cabezal entró en v0.31.22 |
| 7 | Mirá el **logo** | **Nítido**: los arcos finos abiertos, no una mancha negra | Empastado = build viejo (desde v0.31.22 el logo se emite APARTE del cuerpo, con su propio umbral fino) |
| 8 | Imprimí un recibo **LARGO** (con lista de mora, o un multi-cobro) | Llega completo hasta el slogan del pie | Final en blanco/cortado → prendé **"Impresión lenta"** y repetí (dosifica el envío para el buffer chico de la térmica) |
| 9 | Letra apagada o trazos pegados | Ajustá **"Grosor del texto"** (subir = más negro; de más, se pegan) | — |

*D — Modo TEXTO nativo (liviano y nunca pierde el pie).*

| # | Qué hacer | Qué deberías ver | Si falla |
|---|---|---|---|
| 10 | Modo → **Texto nativo** → imprimí el MISMO recibo que en imagen | **Todos** los datos, sin faltantes: encabezado, cliente, cuota(s), lista de mora, descuentos/cargos, totales y pie | Falta un bloque entero → es bug: anotá cuál |
| 11 | Mirá el borde **DERECHO** | Cada fila "etiqueta: valor" alineada, el valor pegado a la derecha y COMPLETO (los montos no pierden dígitos) | Corta a la derecha → bajá "Ancho de línea" de a 2, o re-medí con la regla (paso 3) |
| 12 | Con el bloque **"Monto en letras"** prendido (Configuración → Recibos), imprimí un monto largo (ej. C$1.250,00) | El texto **parte en 2 líneas centradas** y ninguna se sale del papel | Se sale o se corta a la derecha = build viejo |
| 13 | Mirá el margen **IZQUIERDO** | El bloque entero arranca ~2 caracteres adentro del borde, no pegado al filo | Pegado al borde → "Ancho de línea" quedó muy bajo (la sangría sale de ADENTRO del ancho) |
| 14 | Tildes | Default en Windows = **"Sin tildes"** (Periodo, Nunez) — a propósito: alinea perfecto y es infalible. Para acentos REALES probá **"Acentos"** | Con "Estándar"/"Occidental" muchas térmicas USB devuelven garabatos que se comen la letra siguiente → volvé a "Sin tildes" |

*E — El corte.*

| # | Qué hacer | Qué deberías ver | Si falla |
|---|---|---|---|
| 15 | Mirá el pie/slogan del último recibo cortado | Sale **completo** antes del corte | Cortado por arriba, o el pie aparece en el TOPE del recibo SIGUIENTE → subí **"Avance antes del corte"** (default 6 en Windows) de a 1-2 líneas. La cuchilla está ~1cm arriba del cabezal: sin avance, el último bloque queda atrapado |

*Troubleshooting rápido — síntoma en el papel → qué ajuste tocar:*

| Síntoma | Qué tocar |
|---|---|
| Se corta la **derecha** (montos, columna de valores) | **Texto:** "Ancho de línea" (medilo con la regla, paso 3). **Imagen:** confirmá el ancho de papel en Configuración → Recibos (80/58mm) |
| El **final** (pie/slogan) sale en blanco o cortado | **Imagen:** prendé "Impresión lenta". **Los dos:** subí "Avance antes del corte" |
| El pie aparece **arriba del recibo siguiente** | "Avance antes del corte" (subilo) |
| Márgenes desparejos / todo corrido a la izquierda | **Imagen:** ya viene compensado en v0.31.22 → si sigue, es build viejo. **Texto:** la sangría depende de "Ancho de línea" |
| Letra gris / apagada | **Imagen:** subí "Grosor del texto". **Los dos:** "Forzar densidad del cabezal" (apagalo si aparecen garabatos: esa impresora no lo soporta) |
| Trazos pegados / logo hecho una mancha | **Imagen:** bajá "Grosor del texto" |
| Sale una tira de caracteres sueltos en vez del recibo | **Imagen:** prendé "Compatibilidad de imagen" (usa el comando de imagen viejo) |
| Acentos como símbolos raros que se comen la letra siguiente | **Texto:** Tildes → "Sin tildes" (o "Acentos") |
| No imprime nada / snackbar "Modo directo falló; probando por el driver…" | Esa impresora no habla ESC/POS directo: dejala en Modo → "Por driver de Windows" |
| Toqué **"Margen izquierdo"** y el recibo no cambió | **Esperado:** ese slider afecta solo a la **Prueba**. En el recibo el margen ya viene horneado (imagen: en el diseño; texto: 2 caracteres de sangría) |

*Si falla algo que no está en la tabla:* anotá **modo** (imagen/texto), **ancho de línea**,
**avance de corte** y sacale foto al papel — sin esos 3 números el diagnóstico es a ciegas.

- **Mapa satelital en zona rural (P1, 2026-06-17 — ✅ testeado OK):**
  - Mapa → botón capa (satélite) → zona **rural** → zoom in a fondo. *Ver:* la imagen se **agranda
    (borrosa) pero continua** — ya NO la grilla gris "Map data not yet available". Ahora deja **un nivel
    más** de acercamiento (z20). *Si volvés a ver gris en rural:* bajar `maxNativeZoom` de 17 a 16 en
    `mapa_screen.dart`/`mapa_picker_screen.dart` (anotá a qué zoom apareció).
  - Zona **urbana** a fondo: nítida (un pelín menos en el máximo, esperado). Vista **calle**: igual que antes.

- **Banner "Sin conexión" (P2, 2026-06-17 — ✅ testeado OK):**
  - Cortá el wifi de verdad → esperá **~15s** → aparece el rojo "Sin conexión". *Si no aparece:* bajar
    `fallosOffline`/`intervalo` en `conexion_real_provider.dart`.
  - Reconectá → el rojo desaparece en pocos segundos (el sondeo TCP a Supabase vuelve a alcanzar).
  - Uso normal con buena señal: el rojo **NUNCA** aparece solo (antes salía por hipos de PowerSync). *Si
    aparece con señal buena:* revisar el sondeo (¿el host de Supabase está bloqueado en esa red?).
  - Ya NO existe el aviso ámbar "red inestable". El banner usa `conexionRealProvider` (sondeo real), no
    `SyncStatus` de PowerSync.

- **Reasignación masiva de cobrador — P3 (2026-06-17 — ✅ testeado OK):** *Requiere admin/admin_cobranza ONLINE.*
  - **Rutas** (menú admin): cada comunidad muestra su cobrador (o "Mixto" / "Sin asignar" en ROJO) + #clientes.
    Tocá una → selector con **buscador** + recuadro "Asignación actual" (desglose por cobrador). Elegí uno →
    confirma "los N → X" → reasigna TODOS los activos de la comunidad. *Ver:* la fila muestra el cobrador nuevo.
  - **Clientes → filtro Comunidad → "Seleccionar todos del filtro"** → "Asignar cobrador" → reasigna el set
    completo (no solo los ~50 visibles). Lista de clientes y de cobros muestran "N cargados".
  - *Si falla:* el cobrador nuevo no ve los clientes → confirmá que estabas online (el server propaga vía 0068).

- **Clientes/contratos SIN cobrador — P3b (2026-06-17 — ✅ testeado OK):** *Requiere migración 0121 en DEV.*
  - **Desasignar** un cliente con contrato activo (Clientes → Editar → quitar cobrador, o Rutas → "Desasignar")
    → ahora NO bloquea. *Antes* lo frenaba el guard 0058.
  - **Crear contrato** para un cliente sin cobrador (detalle del cliente → "Nuevo") → ahora deja crearlo.
  - **Filtro "Sin cobrador"** en Clientes y en Cobros → aparecen los sin-cobrador. **Cobralos como admin** →
    el recibo lleva TU prefijo y dice quién cobró (necesitás prefijo de recibo configurado).
  - Un **cobrador de campo NO los ve** (lista/mapa/cobros). **Reasignales** un cobrador → reaparecen para él
    tras sincronizar. *Si falla al cobrar:* confirmá que el admin tiene `prefijo_recibo`.
  - **Regla:** `clientes.cobrador_id` = organizativo (quién va a cobrar); `pagos.cobrador_id` = quién cobró
    (recibo + reportería). Un cliente sin cobrador es "admin-managed": la deuda cuenta igual, la ve la oficina.

- **Tag de contratos siempre visible — P4 (2026-06-17 — code+suite OK, falta build):** *Puro UI, basta hot reload.*
  - **Clientes (cobrador) y Clientes (admin):** un cliente con **1 contrato** ahora muestra chip **"1 contrato"**
    (antes no salía nada). Con **2+** → "N contratos" (plural). Mismo comportamiento en las dos listas.
  - Cliente **nuevo sin contrato** o con su **único contrato suspendido** → chip gris **"Sin contrato"**.
  - *Si falla:* dice "contrato" en plural / no aparece el chip con 1 contrato / no sale "Sin contrato" en 0.

- **Etiquetas personalizables de clientes — P5 (2026-06-17 — code OK, falta build):** *Requiere 0122 en DEV +
  sync rules v11 Active + build con schema v31.* Las asigna admin/admin_cobranza; el cobrador solo las VE.
  - **Catálogo (Administración → Etiquetas, solo admin):** "Nueva etiqueta" → nombre + elegir color (swatch) +
    icono (grid) → preview en vivo → Guardar. Aparece en la lista con su color/icono y "N clientes". Editar /
    Historial / Eliminar (eliminar avisa de cuántos clientes la quita).
  - **Asignar (detalle del cliente → sección "Etiquetas" → Asignar/Editar):** sheet con checks; tildar asigna,
    destildar quita. Los chips aparecen al toque en el detalle.
  - **Mostrar:** los chips se ven en la **lista de clientes** (cobrador y admin), en **Cobros** (cabecera del
    cliente) y en el **detalle**. En el **mapa**: el pin mantiene su color de estado y suma un **puntito** con el
    color de la primera etiqueta; al tocar el pin, el popup lista todas.
  - **Cobrador:** con un build de cobrador, un cliente suyo etiquetado por la oficina muestra los chips (tras
    sincronizar). El cobrador NO ve botón de asignar. *Si falla:* confirmá sync rules v11 Active + que el cliente
    es del cobrador (la asignación baja por `cobrador_id` denormalizado).
  - **Reasignar:** mové un cliente etiquetado a otro cobrador → sus etiquetas lo siguen (cascada). *Si falla:*
    confirmá online (el server propaga `cobrador_id`).

- **Detalle de cliente en pestañas + toggle de Visitas (2026-06-17 — code OK, falta build):**
  *Rol/identidad:* super_admin para el toggle; **admin/cobrador real (NO impersonando)** para registrar visita.
  Requiere `0125` en DEV + build schema **v31**.
  - **Tabs:** abrí un cliente → arriba botones **Detalle / Contratos / Equipos / Visitas**, identidad
    (avatar/código/nombre/Llamar/Navegar) fija debajo. **Equipos** solo con módulo de inventario; **Visitas** solo
    si el setting está ON (ver abajo).
  - **Detalle (Opción A):** etiquetas + fotos (2 columnas en pantalla ancha). Cambiá de tab y volvé → las **fotos
    NO recargan** (no parpadean).
  - **Contratos:** cada contrato como tarjeta-preview con **"Pagadas X/Y"**. Un contrato **suspendido** sale
    **prominente con badge naranja "Suspendido"** (NO tachado bajo "cancelados"); los **cancelados/terminados** van
    colapsados abajo.
  - **Toggle de Visitas (super_admin → Configuración → Avanzado → "Pantallas opcionales del admin"):** prendé
    **"Registrar visitas a clientes"** → la pestaña **Visitas** aparece en el detalle; apagalo → desaparece (default
    OFF). *Si no aparece el toggle:* confirmá build v31 (§0.0) y que estás como super_admin.
  - **Registrar visita:** con la pestaña ON, **logueado como cobrador/admin real (NO impersonando)**, botón
    "Registrar visita" → resultado + notas → aparece en el historial. *Impersonando el botón NO sale (por diseño,
    ver §0.3.0).*
  - *Si falla:* la foto recarga al cambiar de tab / un suspendido sale tachado bajo "cancelados" / el toggle no
    aparece (build viejo, ver §0.0).

- **Suspensión temporal de contrato (Feature A, 2026-06-15 — build v29):**
  *Requisito:* rol admin/admin_cobranza; correr 0119+0120 en DEV + sync rules v10 Active
  (ya están). Abrí un contrato **activo** (Contratos → tocar uno, o desde el cliente).
  *Data de prueba (DEV):* `supabase/tests/seed_escenarios_suspension.sql` crea/resetea 6
  clientes TEST-S1..S6 con escenarios de mora/parcial/al-día (pegar TODO el bloque en el
  SQL Editor de DEV; es seguro re-correrlo — los hijos cascadean). NUNCA en producción.
  1. *Suspender:* botón "Suspender contrato" → diálogo (motivo + notas opcionales +
     fecha) que muestra la **deuda a la fecha** → confirmar.
     *Ver:* badge ámbar **"Suspendido"** + tarjeta "Suspensión vigente" (motivo/notas/
     deuda) con **Reimprimir deuda** + **Reactivar**. Las cuotas futuras quedan
     anuladas; la del mes en curso, prorrateada a los días consumidos.
  2. *Reimprimir deuda:* botón → abre el PDF (empresa + cliente + cuotas + total).
  3. *Reactivar:* botón → diálogo (fecha; el picker solo deja un **mes posterior** al
     de la suspensión) → confirmar. *Ver:* contrato vuelve a **activo**, día de pago
     re-anclado a la fecha, cuotas desde ese mes revividas hasta el fin **original**;
     los meses suspendidos quedan sin cobrar.
  - *Gating:* el **cobrador NO** ve Suspender/Reactivar; al **impersonar** (super_admin)
    tampoco. *Mismo-mes:* reactivar en el mes de la suspensión debe RECHAZARSE.
  - *Si falla:* avisá qué muestra (snackbar/estado) — es DINERO, frenar y diagnosticar.
  - *Casos PARCIAL (2026-06-15 b):* una cuota del mes en curso con abono parcial → al suspender
    se PRORRATEA a los días (no cobra el mes completo); si el abono ya supera el prorrateo → la
    cuota queda **'pagada'** (saldo 0, sin reembolso). Una cuota FUTURA con abono parcial NO se
    anula y aparece en el PDF de deuda. *Ver:* snapshot/PDF y el saldo de la lista dan el MISMO número.
  - *Header "Pendiente" cobrable:* en un fijo suspendido, el "Pendiente" del header = lo cobrable
    real (suma de cuotas vivas), **IDÉNTICO** a la lista de cobros y a los reportes (no el nominal
    precio×meses). *Si difiere → bug.*
  - *Dashboard "Distribución de cuotas":* las 4 filas de vigencia (Al día/En gracia/Vencidas/Pagadas)
    suman el total de cuotas; **"Con pago parcial"** aparece como overlay debajo (solo si pago parcial
    está ON o ya hay parciales) y NO duplica conteos (una parcial vencida no se cuenta 2 veces).
  - *"X/N pagadas":* un contrato suspendido-reactivado llega a **N/N** (no cuenta los meses anulados)
    y el ratio coincide con el badge "Completado ✓".
  - **⭐ Anclaje al día_pago (CRÍTICO — fix 2026-06-16, la regla de oro):** el prorrateo del mes en curso
    se ancla a la **ventana de servicio del día_pago**, NUNCA al mes calendario. Validar con el seed:
    suspender un contrato día_pago **15** un 16/jun debe cobrar la cuota cuyo servicio ya se CUMPLIÓ entera
    + prorratear SOLO el ciclo en curso (1 día de jun a precio/30), no anular un período completo. Con
    día_pago **6** y suspensión 16/jun, el ciclo en curso (6→16) prorratea 10 días (precio/30). *Si los
    números no anclan al día de pago → frenar, es el bug que destapó S3.* La **reactivación** reinicia
    limpio: revive desde el mes SIGUIENTE al de reactivación (facturación vencida), sin doble-cobrar el corte.
  - **Reportería/recibo (fix `42edbbc`, 2026-06-16) — verificar de paso:** (a) **reporte de mora** (PDF/Excel
    y la tarjeta "Mora por comunidad" del dashboard) NO debe incluir contratos suspendidos (su deuda va al KPI
    "Suspendido", no a la mora); (b) los **"días de mora"** del reporte = los del badge "Vencida Nd" de la UI
    (restan la gracia); (c) un **recibo con bloque EN MORA** rotula cada cuota con el **mes de servicio**
    (= el resto de la app), no el mes calendario del vencimiento.
  - **Ciclo de vida nuevo (2026-06-16) — probar en orden con un cliente TEST (ej. S1):**
    1. *Desglose al suspender:* el diálogo Suspender lista **cuota por cuota** (mes de servicio · vence ·
       prorrateado N/díasMes · abonó · saldo) + total. *Ver:* los saldos por cuota suman el total; con
       pago parcial ON muestra el abono.
    2. *Prompt de impresión:* al confirmar aparece **"¿Imprimir el detalle de la deuda…?"** [Ahora no]/
       [Imprimir]. "Imprimir" abre el PDF; "Ahora no" cierra. *Si falla:* NO debe quedar diálogo abierto
       ni pantalla negra trabada.
    3. *Sale de rutas:* el suspendido **desaparece** de la lista de Cobros y del mapa. Un cliente con OTRO
       contrato activo sigue mostrando ESE contrato en Cobros (no se oculta el cliente entero).
    4. *Filtro "Suspendidos":* Clientes → chip **"Suspendidos"** → aparece el cliente (también lo respeta
       el export a Excel).
    5. *Dashboard:* "Cuotas por cobrar"/"En mora" **bajan** por el monto del suspendido; aparece la tarjeta
       **"Suspendido (por reactivar)"** con conteo + monto. (titular + suspendido = total de antes.)
    6. *Reporte de clientes (PDF + Excel):* el cliente sale con sufijo **"(susp.)"**; al pie, subtotales
       **Activo / Suspendido / Total**.
    7. *Reactivar exige cobrar primero:* en la tarjeta, mientras haya deuda NO está Reactivar — está
       **"Cobrar pendiente"** + aviso con el monto. Tocalo → cobro de la cuota **más vieja** (un recibo).
       Cobrá una por una (oldest-first). Al saldar TODO (cobrable 0) aparece **Reactivar**. *Si falla:*
       Reactivar visible con deuda, o "Cobrar pendiente" no toma la más vieja → frenar (es dinero).
    8. *Suspendido SIN deuda:* si suspendés un contrato sin nada pendiente, la tarjeta muestra **Reactivar
       directo** (no "Cobrar pendiente") y el dashboard NO suma KPI suspendido.
- **Re-confirmar:** recibo del cambio-de-fecha = **una sola** línea "Puente de pago" = COBRADO.
- **Lista de Cobros rediseñada — compacta + escala + cold-start (2026-06-19, build 0.11.10):**
  *Rol/identidad:* cobrador (vista en `/`) y admin/admin_cobranza (`/admin/cobros`), con identidad REAL si vas a
  cobrar. Schema **v33** (solo índice local `by_contrato_vencimiento`, sin migración SQL ni redeploy de sync rules).
  Corré ANTES el GATE de build fresco (§0.0): build esperado **0.11.10** en login/sidebar.
  1. *Tarjeta-resumen por cliente:* en Cobros, *ver:* **una tarjeta por cliente** (código · nombre ·
     `comunidad · municipio · N a cobrar · estado`), con el **total "COBRABLE AHORA"** (Σ cuota más vieja por
     contrato, oldest-first) y un botón **"Pagar"**. Tocá "Pagar" colapsado → va directo al cobro de la **cuota
     más vieja** del cliente. *Si falla:* si ves un renglón por cuota sin tocar la tarjeta = lista vieja (recompilá, §0.0).
  2. *Expandir:* tocá la tarjeta → se **expande** y carga el detalle (**un renglón por contrato** con Pagar /
     Cambiar fecha + "Ver ficha del cliente"). Colapsala → se contrae. Cliente con 2+ contratos → varios renglones.
  3. *Consistencia de dinero (#10):* el **total** de la tarjeta colapsada da **IDÉNTICO** a la suma de los saldos
     al expandir. *Si difiere → frenar, es dinero* (lo cubre `cobros_resumen_test.dart`, 8 casos vs SQLite real).
  4. *Buscador:* tipeá nombre/cédula/teléfono/código → filtra al instante (debounce 250ms). Limpiá con la X.
  5. *"Ver todo" a escala (solo admin):* chip **"Ver todo"** → TODO lo pendiente sin el límite de rango. Probalo con
     el tenant más cargado: abre fluido con **cientos/miles** de clientes (antes agrupaba en Dart y tironeaba). El
     cobrador NO debe ver "Ver todo". *Si falla:* tironeo notorio = regresión de escala.
  6. *Chip rojo de deuda escondida:* cliente con **más cuotas vencidas que líneas cobrables-ahora** (ej. 3 meses
     atrasado en 1 contrato → "1 a cobrar" pero debe 3). *Ver:* chip rojo **"N cuotas vencidas · debe C$X"**. Un
     cliente al día o con 1 sola vencida NO lo muestra.
  7. *Marca de pago parcial:* expandí un cliente con una cuota **parcial**. *Ver:* **"Parcial · abonó C$X de C$Y"**.
  8. *Cold-start (regresión):* abrí un build con schema **nuevo** sobre una DB de schema viejo → la app recrea la
     base local. *Ver:* Cobros carga normal (NO "ClosedException") y el banner **NO** muestra falso "Sin conexión".
     *Si falla:* stream cerrado o "Sin conexión" con red OK justo tras el primer arranque.
- **Chokepoint oldest-first (#4, 2026-06-19):** *Rol:* cobrador/admin, identidad REAL.
  1. *Bloqueo:* tomá un cliente con 2+ cuotas vencidas. Andá a cobrar y, por cualquier camino, intentá pagar una que
     NO sea la más vieja. *Ver:* no te deja; sale en español "Cobrá primero la cuota más antigua pendiente…".
  2. *Permitido:* cobrá la más vieja → OK. Después la siguiente ya es la más vieja → OK. Multi-cobro **contiguo desde
     la más vieja** (ej. mayo+junio) → OK. *Si falla:* si te deja saltear, o si bloquea un cargo manual de reconexión
     suelto (esos se cobran en cualquier orden), frenar — es dinero.
- **#1 — Schema in-place / sin re-descarga (2026-06-19, build con DB `_w1`):**
  1. *Wipe de transición (1 sola vez):* el PRIMER build con el nombre nuevo (`sitecsa_<uid>_w1.db`) re-sincroniza
     todo el slice una vez. Esperado. *Ver:* tras ese arranque, la app funciona normal con todos los datos.
  2. *Aditivo sin re-descarga (la prueba clave):* en un build POSTERIOR, agregá una columna a una tabla en
     `schema.dart` (y su migración) SIN tocar `_dbWipeVersion`. *Ver:* la app abre **sin** pantalla larga de
     "Sincronizando", **conserva** los datos locales y la columna nueva aparece. *Si falla:* si re-descarga todo o
     tira error de "columna no encontrada en el schema cache", reportarlo (no debería pasar — cubierto por
     `test/powersync/schema_inplace_test.dart`).
- **Rechazos de sync visibles (Sprint 1, audit 2026-06-11):** desde el admin,
  editá un cliente y asignale un código que YA usa otro cliente del tenant.
  *Ver:* al sincronizar, SnackBar en español ("Código de cliente duplicado…")
  — ya no el error crudo de Postgres en inglés. En cobrador/técnico, cualquier
  cambio rechazado por el server muestra además la card ámbar **"Cambios sin
  sincronizar"** en Perfil (mensaje en español + hora local); la X descarta el
  aviso y la card desaparece sola al quedar vacía.
  *Si falla:* el detalle técnico con el contenido del cambio (opData) queda en
  `/super/logs` (error_logs).
- **Descuentos rediseñados (2026-06-12, 0115+0117 — el admin gestiona
  desde el contrato, el cobro solo referencia):**
  1. *Settings:* como súper, Configuración → Avanzado. *Ver:* DOS grupos
     con subtítulo: "Ajustes de cuota (admin)" y "Pronto pago" — nada en
     "Otros" (los settings del descuento del cobrador quedaron retirados).
     Activá "Permitir ajustes de cuota".
  2. *Descuento desde el contrato (admin):* icono **%** en una cuota
     pendiente → sheet "Descuentos y cargos de la cuota" → "Aplicar
     descuento". *Ver:* selector **Ajuste/Promo**, chips de motivo (con
     Promo cambian), preview "Saldo: X → Y". Aplicá una PROMO con % → en
     el sheet aparece "Promo"; quitar restaura el saldo y deja rastro en
     el historial. Tope excedido → mensaje claro. Setting OFF → sin %.
     **Condonación:** promo del 100% → la cuota pasa a **Pagada** al
     instante; quitala → vuelve a Pendiente.
  3. *Cargo extra desde el contrato (admin):* mismo sheet → "Cargo extra"
     → selector **Reconexión/Otro** (reconexión prellenada con su monto;
     "otro" exige descripción), preview "+C$". *Ver:* el saldo de la cuota
     SUBE en todas las pantallas; en el sheet aparece con su etiqueta y se
     puede quitar. Los nacidos de un cobro (pronto pago, reconexión
     automática) se ven con candado: solo se revierten anulando el pago.
  4. *Cobro (referencia):* abrí a cobrar una cuota con descuentos/cargos.
     *Ver:* NO hay botones de crear — solo **"Ver descuentos y cargos"**
     (sheet solo-lectura con etiqueta y motivo de cada uno; los
     automáticos dicen "Se aplica al confirmar este cobro"). El total ya
     viene neto. Cobrá → recibo; anulá el pago desde Historial de pagos →
     el pronto-pago del cobro se revierte; los cargos del admin quedan.
  5. *Recibo:* muestra dentro de los montos de la cuota una línea por
     descuento/cargo con su motivo (pantalla, PDF y térmica iguales). En
     Configuración → Recibos, bloque "Montos de la cuota": sub-toggles
     "Mostrar descuentos y cargos" y "Mostrar motivos" — visibles SOLO si
     algún feature de descuentos/cargos está prendido en Avanzado
     (ajustes, reconexión o pronto pago); apagalos y la preview en vivo
     los oculta al instante. Con los features OFF, la data ya aplicada se
     sigue mostrando en el recibo (historial visible).
  6. *Pronto pago:* con valor > 0 y una cuota NO vencida, al cobrar
     aparece el descuento automático como card y en "Ver descuentos y
     cargos".
  *Si falla:* correr `invariantes_dinero.sql` (INV13/INV14) y verificar
  0117 (queries al pie de la migración).
- **Mega-sprint 2026-06-11 (smokes rápidos):** (1) en COBRO: tipeá "500,50"
  → el monto vale 500.50; back de Android con datos cargados → pide
  confirmación; aplicá un descuento manual con un cargo de reconexión
  pendiente → el total conserva la reconexión y no la duplica al confirmar.
  (2) Cancelar contrato → pide confirmación explícita. (3) Doble-click en
  "Crear cliente/contrato" → una sola entidad. (4) Como admin, filtrá "En
  mora" en /admin/cobros → el badge del cobrador NO se borra; tocá un
  cliente → abre la vista /admin con el menú lateral. (5) Menú →
  Administración: "Cuotas" YA NO está (pantalla retirada 2026-06-11; las
  cuotas viven en el detalle del contrato). (6) Personal → ícono 🕐
  → historial del miembro. (7) Provocá un error cualquiera → mensaje en
  español, no "Exception:". (8) Historial de cobros → "Cargar más" al fondo.
- **Cobro de campo (cobrador):** abrir una cuota pendiente → cargar monto, método,
  moneda (probar **USD con vuelto** y **C$**), foto → imprimir/guardar recibo.
  *Ver:* recibo correcto, recaudado = aplicado (no lo entregado), vuelto siempre en C$.
- **Reportes (`/admin/reportes`):** con un cobro USD y uno C$, generar Cobros, Por
  cobrador y Fiscal en **PDF y Excel**. *Ver:* "Monto/Total recaudado (C$)" = aplicado;
  columnas Moneda/Entregado/Tasa/Vuelto correctas; PDFs en landscape; Fiscal partido por moneda.
- **Recibo / impresión (smoke):** Android → impresora Bluetooth; Windows → imprime
  DIRECTO a la impresora del sistema (USB/red) y, si ese camino falla, cae solo al
  driver ("Modo directo falló; probando por el driver…"); además está "Descargar PDF".
  *El flujo completo de Windows —calibración, modos imagen/texto, corte— está en
  **§0.3.1**.*
- **Mapa (Rotación y Navegación Offline — 2026-06-12):**
  1. *Rotación táctil y brújula:* Rotá el mapa con dos dedos sobre la pantalla (en Windows podés mantener presionada la tecla Shift y arrastrar con el botón izquierdo del mouse para simular el gesto de dos dedos).
     *Ver:* El mapa rota libremente y aparece el botón flotante de la brújula en la esquina superior derecha (debajo de las capas). La brújula apunta siempre al norte geográfico independientemente de la orientación de la pantalla. Presioná el botón de la brújula: el mapa debe reorientarse suavemente de vuelta al norte (rotación 0.0) y la brújula debe desaparecer.
  2. *Trazado de Ruta Offline:* Tocá el pin de un cliente para abrir su bottom sheet y presioná el botón **"Ruta"**.
     *Ver:* El bottom sheet se cierra al instante y se dibuja una línea azul con curvas sobre las carreteras reales de Nicaragua que conecta tu ubicación GPS actual (o la posición simulada en caso de no tener GPS) con el pin del cliente.
  3. *Panel de Información de Ruta:* Al trazarse la ruta, aparece un panel de información en la parte inferior izquierda del mapa.
     *Ver:* Muestra el nombre del cliente destino, la distancia real en kilómetros/metros siguiendo las calles y el tiempo de viaje estimado (a 40 km/h promedio). El botón "Cerrar" (X) del panel borra la ruta del mapa.
  4. *Fallback Externo:* Presioná el botón **"Abrir en Google Maps"** en el panel inferior.
     *Ver:* Lanza de forma externa la aplicación de Google Maps con la ruta pre-configurada hacia el cliente (útil si se requiere navegación por voz).
  5. *Prueba 100% Offline:* Activá el modo avión en tu dispositivo móvil o desconectá la red en la PC. Tocá un cliente y presioná "Ruta".
     *Ver:* La ruta azul debe trazarse al instante en el mapa localmente gracias al motor A* ejecutado sobre la base de datos de carreteras local (`rutas_nicaragua.db`), sin dar ningún error por falta de internet.
- **Búsqueda en Mapa:** buscar por nombre, cédula, teléfono (con/sin guiones), código de cliente y de contrato → centra el pin correcto. Probar offline (tiles cacheados).
- **Transición:** navegar entre items del sidebar/nav → fade secuencial (sale una,
  entra la otra), nunca las dos encimadas.
- **Tickets — admin (`/admin/tickets`, Fase 3A):** requiere el módulo `tickets`
  encendido (super_admin en `/super/tenants/:id`). Crear un **tipo** con SLA → crear
  un **ticket** (tipo + cliente opcional + asignar a un técnico) → en el detalle,
  cambiar estado (avanzar/pausar/resolver/cerrar), reasignar, comentar, adjuntar foto.
  *Ver:* código `T-00001`, badge de estado/SLA, bitácora cronológica (creado/asignado/
  cambio de estado/comentario/adjunto), transiciones inválidas no ofrecidas. *Si falla:*
  módulo OFF → `/admin/tickets` rebota a `/admin`; admin_cobranza no lo ve.
- **Técnico (`/tecnico`, móvil-first, Fase 3B):** el super_admin asigna rol **Técnico**
  a un miembro (módulo `tickets` encendido). El admin crea un ticket y se lo asigna.
  Loguear como el técnico → entra al shell **Mis tickets · Mapa · Perfil**.
  *Ver:* en Mis tickets aparece SÓLO el ticket asignado (no otros del tenant); el detalle
  ofrece **avanzar/pausar/resolver** (no reasignar/cerrar); comentar + adjuntar foto andan;
  el Mapa muestra sólo el cliente del ticket; el Perfil NO tiene prefijo/historial/fotos.
  Probar **offline** (modo avión): mover el ticket en_progreso→en_espera→resuelto, comentar
  → al volver la red, sincroniza y el admin ve `resuelto` y puede **cerrar**. *Si falla:*
  el técnico NO debe poder entrar a `/admin`, `/super`, ni ver dinero (intentá por URL →
  rebota a `/tecnico`).
- **Materiales del ticket (3C, requiere módulos tickets + inventario):** primero, como admin,
  creá una ubicación de Inventario `tipo='técnico'` con el `cobrador_id` del técnico y
  transferíle stock (un serial + algo de granel). Como técnico (o admin), en el detalle del
  ticket → **Materiales › Agregar** → elegí serial o granel + cantidad → Registrar.
  *Ver:* aparece en la lista de Materiales + un evento "material" en la bitácora; al
  sincronizar, en Inventario el **stock baja** y el serial queda **'instalado'** en el
  cliente del ticket (visible en "Equipos instalados" del cliente y en el historial del
  serial). Probá **offline**: registrar un material sin red → al volver, el stock se
  descuenta. *Si falla:* el botón Registrar de granel debe exigir cantidad >0; un técnico
  sin custodia ve el aviso "no tenés una custodia asignada".
- **Incidentes / outages (3D, admin, módulo tickets):** con topología de red cargada
  (nodos/hubs/puertos) y clientes asignados a puertos, entrá a **Incidentes › +** → elegí
  alcance (general / nodo / hub / puerto) → Registrar. En el detalle: *ver* los **clientes
  afectados** correctos (los que cuelgan de ese nodo/hub/puerto), agregá tickets vía el
  picker al crear un ticket o con **"Vincular a incidente"** en un ticket existente, y
  **resolvé**. *Ver:* el alcance sigue mostrándose aunque borres el puerto/hub/nodo
  (snapshot); un técnico NO puede entrar a `/admin/incidentes` (rebota) ni ve el incidente
  en su ticket. *Si falla:* el corte general lista TODOS los clientes activos; un corte por
  puerto, sólo los de ese puerto.
- **Cancelar contrato = suspensión PERMANENTE (admin, detalle de contrato):**
  *Rol/identidad:* admin/admin_cobranza del tenant; **NO impersonando** (bloqueado por
  diseño). Requiere migraciones `0123` (columnas de cancelación) + `0124` (mora) en DEV.
  En `/admin/contratos/:id` (o `/contratos/:id`), tocá el badge de estado → **Cancelado**
  → pedí motivo y confirmá. *Ver:* se ofrece el **documento de deuda** y el contrato pasa
  a `cancelado` (badge rojo), SIN reactivación.
  - *La deuda real queda VIVA y cobrable (NO se liquida a 0):* a diferencia del cancelar
    viejo, las cuotas de meses YA SERVIDOS (cumplidos) + la mora previa **siguen cobrables**.
    El mes en curso se **prorratea** por días consumidos (ventana de servicio del día_pago,
    igual que suspender); solo los meses FUTUROS pendientes se **anulan**. En el detalle del
    contrato aparece la **tarjeta "Deuda al cancelar (cobrable)"** con el snapshot, y la
    deuda se cobra desde la lista de cuotas de abajo.
  - *Sale de los flujos diarios:* el cliente/contrato cancelado **desaparece** de la lista
    de clientes (mora/saldo), de **Cobros** y del **mapa** (igual que un suspendido). La
    deuda solo se ve/cobra entrando al **detalle del contrato**. (Backlog acordado: reporte
    de "deuda de bajas" para no perderla de vista — ver BITACORA §Backlog.)
  - *Mora:* tras cancelar → la **mora se limpia** (panel `/admin/notificaciones` + badge del
    cobrador); el cron `0124` ya no genera mora de contratos no-activos.
  - *Cuota con abono parcial:* el pago **sigue contado** en Recaudado; si el prorrateo del
    mes en curso es ≤ lo abonado, la cuota queda **pagada sin reembolso** (clamp al pago,
    igual que suspender).
  - *Terminal:* en un contrato ya **cancelado**, el badge de estado **no** abre dropdown (no
    se reactiva). En el **form de edición** del contrato **no** hay switch de estado.
  - *Impersonación:* como super_admin impersonando, el dropdown **no** ofrece "Cancelado"
    (la acción se atribuiría al super_admin) → probar como admin real del tenant.
  - *Si falla:* correr `supabase/tests/invariantes_dinero.sql` → toda fila `violaciones = 0`.
    El saldo cobrable de la tarjeta debe coincidir con la suma de la lista de cuotas vivas;
    un recaudado que cambió al cancelar es bug.

- **Revertir suspensión/cancelación = deshacer por error (2026-06-18):**
  *Rol/identidad:* admin/admin_cobranza del tenant; **NO impersonando**. Requiere `0123` en DEV + build con la
  feature. (≠ Reactivar: Revertir vuelve al estado EXACTO previo; Reactivar es reinicio limpio tras una pausa real.)
  - **Caso normal:** suspendé (o cancelá) un contrato por error → en su tarjeta (Suspensión / Cancelación) tocá
    **"Revertir"** → confirmá. *Ver:* el contrato vuelve a **activo** con las cuotas EXACTAS de antes — las anuladas
    re-aparecen pendientes con su monto original y la del mes en curso recupera su monto COMPLETO (no el prorrateo);
    NO se re-ancla el día de pago; la mora vuelve si correspondía.
  - **Guarda (no debe dejar revertir):** si DESPUÉS de suspender/cancelar cobraste algo de la deuda o aplicaste un
    cargo/descuento a una cuota → al tocar Revertir sale un aviso ("hubo cobros o cargos… usá Reactivar/cobro
    normal") y NO revierte (a propósito: ya no se puede volver al estado exacto).
  - *Si falla:* las cuotas no vuelven a su monto/estado original, o revierte aunque ya habías cobrado/cargado.
- **Crédito por excedente al suspender/cancelar (0127, 2026-06-18):**
  *Rol/identidad:* admin/admin_cobranza REAL, **NO impersonando**. Requiere `0127` en DEV + **sync rules con
  `saldos_favor` (Active)** + build **schema v32** + setting `cobranza.credito_excedente` ON (default).
  *Data:* `supabase/tests/seed_credito_excedente.sql` (TEST-CE1..CE3, pagaron abr-sep; al suspender/cancelar el
  **18-jun-2026**: deuda 0, **A favor = C$2.610** = jul 810 + ago 900 + sep 900).
  - **Acreditar + aplicar (TEST-CE1):** Suspendé (fecha 18-jun) → aparece el bloque verde **"A favor del cliente
    C$2.610"** + 3 opciones → elegí **Acreditar** + motivo → confirmá. Reactivá (directo, deuda 0). En el
    **detalle del CLIENTE** → chip **"Saldo a favor C$2.610"** + **Aplicar** → confirmación (cubre la cuota más
    vieja, queda en C$0) → aplicá. *Ver:* la cuota queda **saldada SIN que suba el recaudado**; el chip baja; el
    saldo cruza contratos (si el cliente tiene otro). *Si falla:* la cuota vuelve a "pendiente" tras sincronizar
    (sería el bug de `cuota_total_a_cobrar`), o el recaudado sube (el crédito NO debe contar como plata).
  - **Devolver (TEST-CE2):** Suspendé → "A favor C$2.610" → **Devolver** → confirmá. *Ver:* en el **reporte de
    arqueo** del día, la caja de ese cobrador muestra **"(−) Devoluciones de saldo a favor C$2.610"** y el total
    en caja baja por esa cifra. El saldo a favor queda en 0.
  - **Condonar (TEST-CE3):** **Cancelá** el contrato → "A favor C$2.610" → **Condonar** → confirmá. *Ver:* el
    contrato queda cancelado, la plata se QUEDA en caja (recaudado NO baja), el saldo a favor queda en 0, y el
    movimiento queda en el **historial** del cliente.
  - **Aviso al desactivar:** como **super_admin** → Configuración → Avanzado → apagá "Crédito por excedente" →
    *Ver:* sale un aviso explicando que el excedente volverá a quedarse en caja (los saldos ya generados se
    conservan). Con OFF, suspender/cancelar ya NO ofrece las 3 opciones.
  - **Aislar el Reactivar "puro" (D/A/B/E):** para probar **Reactivar** sin que el crédito se meta, dejá el setting
    en **OFF** (default ON). Con OFF, suspender/cancelar un contrato con sobrepago NO ofrece acreditar/devolver/
    condonar → el flujo queda en Reactivar limpio (revive cuotas desde el mes siguiente, re-ancla el día de pago).
    Probá D/A/B/E (validados en vivo 2026-06-19, los 4 pasaron, sin cambio de código) y **volvé a prenderlo** al
    terminar. *Si al suspender ves el bloque verde "A favor del cliente" cuando NO querías probar crédito:* el
    setting quedó ON.
  - **Impersonando:** el botón "Aplicar" y las 3 opciones NO deben ejecutarse impersonando (acción atribuida).
  - **Verificación SQL** (opcional): `SELECT tipo, monto FROM saldos_favor sf JOIN clientes c ON c.id=sf.cliente_id
    WHERE c.codigo='TEST-CE1' ORDER BY sf.created_at;` + `invariantes_dinero.sql` (INV14/15/16 = 0).
- **Colores configurables de estados de cuota (admin, Configuración → Cobranza):** abrir
  **Configuración → Cobranza → "Colores de estados de cuota"** → tocar una fila (ej. "En mora") →
  elegir un color de la paleta. *Ver:* el color cambia **en vivo** en el **mapa** (pin), en la
  **lista de cobros** (badge), en **cuotas admin**, en el **detalle de contrato** y en la
  **lista de clientes**; reabrir Configuración → el swatch quedó con el color elegido. *Si falla:* si
  no se refleja, fijate que salió el snackbar "Color de X actualizado" (es reactivo, no requiere
  reiniciar). No hay migración: en un tenant sin la clave aplican los defaults 🔴 mora /
  🟠 gracia / 🔵 vence-hoy / 🟣 próxima.
- **Mapa — 6 estados + gate por rango (cobrador vs admin):** abrir el mapa. *Ver (cualquiera):*
  pines coloreados por la cuota MÁS urgente del cliente — 🔴 mora, 🟠 gracia, 🔵 vence hoy,
  🟣 próxima (vence dentro de `cobranza.dias_cuotas_visibles`); chips **Pendientes / En mora /
  En gracia / Vencen hoy / Próximas** con su puntito de color. *Ver (cobrador):* NO aparecen los
  clientes sin deuda ni los de cuota fuera de rango. *Ver (admin):* aparece además el chip
  **"Ver todo"** → trae los de fuera de rango (morado atenuado) y sin deuda. *Si falla:* si ves
  pines verdes o TODOS los clientes por defecto, no recompiló (q + flutter run desde cero).
- **Lista de cobros — "Próximas" + "Ver todo" (admin):** en la lista de cobros (vista única "Por cobrar"), *ver:* chip
  **"Próximas"** (vencen después de hoy, dentro del rango) y badges "por vencer" en **morado**.
  Como admin en **`/admin/cobros`** aparece además **"Ver todo"** → TODO lo pendiente sin el
  límite de rango (las cuotas lejanas que el cobrador no ve). *Si falla:* el cobrador NO debe ver
  el chip "Ver todo".
- **Banner "sin conexión" sin parpadeo:** usar la app con red estable, navegar entre pantallas,
  cambiar de tenant (super_admin). *Ver:* el banner rojo "Sin conexión" **no parpadea**. Para el
  real: **modo avión** ~5s → aparece a los ~3s; **sacar modo avión** → desaparece sin flickear.
  *Si falla:* si parpadea al navegar o al cambiar de DB/tenant, el guard del estado de carga no
  está activo.
- **Settings sensibles solo super (Configuración, requiere 0113):** como **admin del ISP** (no super), en
  Configuración → Cobranza NO deben aparecer "Permitir pago parcial", "Permitir pago adelantado", "Cobrador
  anula/edita cobros" (se movieron a Avanzado), ni sueltos en "Otros". Como **super_admin**, Configuración →
  **Avanzado** muestra "Reglas de cobro avanzadas" + "Permisos del cobrador". *Si falla:* correr 0113
  (marca `editable_por='super_admin'` → la RLS también los bloquea, no solo la UI).
- **Días de cuotas próximas configurable (requiere 0113):** Configuración → Cobranza muestra **"Días de cuotas
  próximas" = 5**. Subilo a, ej., 15 → en el detalle de contrato/mapa, las cuotas que vencen dentro de 15
  días pasan a "en rango" (color); las de más allá quedan **grises**. *Si falla:* si no aparece el campo,
  la fila no se sembró (correr 0113).
- **Cuotas fuera de rango = gris (detalle de contrato):** abrí un contrato con cuotas futuras lejanas.
  *Ver:* las dentro de "días de cuotas próximas" → morado/azul/etc.; las **lejanas → GRIS "no disponible"**
  (antes salían todas en morado). *Si falla:* una cuota a meses en morado = el rango no se aplica.
- **Depósito quitado:** Configuración → Pagos ya NO tiene "Aceptar depósitos"; en un cobro los métodos son
  efectivo / transferencia / tarjeta. *Ver:* los pagos viejos con método "Depósito" siguen en
  historial/reportes/arqueo (data histórica preservada).
- **Recibo — zonas + reset (Configuración → Recibos):** *Ver:* **WhatsApp** en el **Encabezado**; cada bloque
  tiene un menú **⋮ "Mover a zona"** (Encabezado/Cuerpo/Pie) → moverlo se refleja en la vista previa y en
  el recibo impreso; el botón **"Restaurar layout por defecto"** vuelve al orden base (con confirmación).
  *Si falla:* si WhatsApp sigue en el pie, usá "Restaurar layout por defecto" o el menú ⋮.
- **Ubicación GPS en el mapa (2026-06-12, rama mapa-lista-clientes):**
  1. Abrí el mapa como cobrador, técnico o admin.
  2. *Ver:* Si tenés los permisos de ubicación otorgados y el GPS encendido, aparecerá un pin circular azul pulsante en tu ubicación actual (diseño de burbuja concéntrica interactiva).
  3. Tocá el botón de la mira (`Icons.my_location`) ubicado arriba de la lupa de búsqueda en la parte inferior derecha.
  4. *Ver:* El mapa se centra suavemente en tu ubicación con un nivel de zoom 16.0.
  5. Desactivá los permisos de ubicación o el servicio GPS y tocá el botón de la mira.
  6. *Ver:* SnackBar descriptivo en español indicando el estado del permiso o servicio. Funciona correctamente offline.
- **Exportación de clientes a Excel (2026-06-12, rama mapa-lista-clientes):**
  1. Ingresá a la vista de Clientes como `admin` o `admin_cobranza`.
  2. *Ver:* Al lado del botón "Nuevo cliente", aparece un botón de descarga (`Icons.download`).
  3. Aplicá filtros en la lista de clientes (por ejemplo, buscar por nombre, filtrar por comunidad o nodo, o activar "Solo en mora").
  4. Tocá el botón de descarga y elegí la opción **"Vista filtrada actual"**.
  5. *Ver:* Se genera y guarda un archivo Excel con el nombre `clientes_filtrados_AAAA_MM_DD.xlsx` en el dispositivo. Las columnas incluyen código, nombre, cédula, teléfono, dirección, comunidad, cobrador, planes, días de pago, saldo pendiente, estado y fecha de alta.
  6. Tocá el botón de descarga y elegí la opción **"Todos los clientes"**.
  7. *Ver:* Se genera y guarda el Excel de todos los clientes sin importar el filtro activo (`todos_los_clientes_AAAA_MM_DD.xlsx`).
  *Si falla:* Verificar que la base de datos local contenga información válida y que el formato de fecha se renderice con `Fmt.fechaNi` (sin warnings de parsed Null).
- **Opción A & Opción B / Sprint 4 (2026-06-12, 0118):**
  1. *Motivo de Cancelación Obligatorio (Contratos):* Andá al detalle de un contrato y cambiale el estado a **Cancelado**.
     *Ver:* Se abre el diálogo `_CancelarContratoDialog` solicitando un motivo de anulación. El botón "Confirmar" está deshabilitado hasta que escribas algo. Ingresá un motivo (ej: "Se muda de zona") y confirmá. En la lista de cuotas, tocá una cuota pendiente anulada y ve su historial. *Ver:* Muestra el motivo ingresado. Ejecutá la query de cargos extra. *Ver:* El cargo de liquidación generado tiene como descripción "Se muda de zona".
  2. *Baja de Equipo Terminal (Inventario):* Como admin, intentá cambiar el estado de un equipo que ya esté en estado **'baja'**.
     *Ver:* La base de datos (Postgres/Supabase) lanza un error a través del trigger guard impidiendo cualquier cambio (es un estado terminal).
  3. *Bloqueo de Transferencias Tardías (Inventario):* Como admin, intentá cambiar el `ubicacion_id` (transferir) de un equipo que esté en estado **'instalado'** sin pasar su estado a **'en_stock'**.
     *Ver:* La base de datos lanza un error a través del trigger guard impidiendo la transferencia directa, exigiendo desinstalarlo primero a stock.
  4. *Clampero de Saldos a >= 0 (Matemática):* Forzá una cuota para que su saldo deudor teórico sea negativo (ej: `monto_pagado > monto + cargos_neto`).
     *Ver:* En el dashboard (saldo general, saldo vencido), en la lista de clientes (admin/cobrador), en la exportación de clientes a Excel y en los 6 reportes de PDF y Excel, el saldo de dicho cliente/cuota se computa y muestra como `0.0`, nunca negativo.
  5. *Auto-eventos de Ticket (Tickets):* Creá un ticket, asignalo a un técnico, cambiale el estado y comentá.
     *Ver:* En la bitácora/historial del ticket se ven reflejados todos los eventos correspondientes (creado, asignado, cambios de estado) generados automáticamente en el servidor por el trigger `trg_tickets_eventos_auto` (y no por el cliente).
- **Toggle "Ver fuera de ruta" — deuda de cancelados/suspendidos (Cobros, 2026-07-01):**
  *Rol/identidad:* **cobrador REAL** y **admin/admin_cobranza REAL** (probar ambos; NO
  impersonando — cobrar se atribuye a quien registra el pago, ver §0.3.0).
  1. *Toggle:* en Cobros, prendé el chip **"Fuera de ruta"**. *Ver:* aparece la sección
     **"Recuperación · fuera de ruta"** con la deuda de contratos **cancelados/suspendidos**
     (badge de deuda; **SIN** botón "Cambiar fecha" — no se re-fecha una cuota de un contrato
     que no está activo). Apagá el toggle → la sección desaparece (default OFF).
  2. *Cobrar recuperación:* cobrá un suspendido hasta dejar la deuda en **0**. *Ver:* aviso
     de **deuda saldada — pendiente de reactivar** + botón **Reactivar SOLO si sos admin**
     (el cobrador no lo ve). **Cobrar NUNCA reactiva el servicio**: reactivar es acción
     explícita del admin (Centro / detalle del contrato).
  *Si falla:* el toggle no lista cancelados/suspendidos con deuda, aparece "Cambiar fecha"
  en la sección de recuperación, o un cobro dejó el contrato activo sin pasar por Reactivar
  → frenar (es dinero).
- **Cobro desde ticket (0173, 2026-07-01):**
  *Rol/identidad:* **admin o admin_cobranza REAL, NO impersonando** (impersonando el botón
  se bloquea por diseño — el cobro se atribuye a quien lo registra, ver §0.3.0).
  1. *Precondición:* un tipo de ticket con **precio > 0** (Tickets → Tipos) y un ticket de
     ese tipo en estado **resuelto o cerrado**.
  2. *Generar:* en el detalle del ticket, botón **"Generar cobro"** → diálogo **precargado**
     con el monto del tipo (editable) → cobrá. *Ver:* recibo con concepto **"Ticket #N"**.
  3. *Anti-doble-cobro:* volvé al detalle del ticket e intentá de nuevo. *Ver:* chip
     **"Cobrado"** (o "Continuar cobro" si quedó a medias) — NO deja generar un segundo
     cobro del mismo ticket.
  *Si falla:* deja cobrar dos veces el mismo ticket, o el diálogo no viene precargado →
  frenar (es dinero).
- **Badge de mora del cobrador (fix 2026-07-03):**
  *Rol/identidad:* **cobrador REAL** con clientes PROPIOS en mora sin ver (NO impersonando).
  1. Entrá como el cobrador. *Ver:* badge **N** en la pestaña **Cobros**.
  2. Tocá el chip **"En mora"**. *Ver:* el badge baja a **0** y queda en 0 tras cerrar y
     re-abrir la app (el visto persiste).
  - **NOTA:** la mora de clientes **SIN cobrador** ya NO cuenta en el badge (esa deuda es
    del admin); un admin o el super_admin impersonando ven el badge en **0** — esperado,
    NO es bug.
  *Si falla:* el badge no baja al ver "En mora", o reaparece tras re-abrir sin mora nueva.
- **Des-asignar cliente con cargos (fix 0174, 2026-07-03):**
  *Rol/identidad:* **admin REAL, con conexión** (la reasignación necesita internet y se
  registra en auditoría).
  1. *Precondición:* un cliente que tenga **≥1 cargo o descuento** en alguna cuota (ícono %
     en el detalle del contrato). En el Test Tenant sirven Sandra (SEED10) o Carlos (SEED04).
  2. *Quitar el cobrador:* desde **Rutas** (reasignar la ruta a "Sin cobrador") o desde la
     ficha del cliente. *Ver:* el cambio **se guarda** (el cliente queda "sin cobrador /
     admin-managed"); **NO** aparece el aviso rojo *"Faltó un dato obligatorio"*.
  3. *Cargo a un sin-cobrador:* aplicá un descuento/cargo a una cuota de ese cliente ya
     desasignado. *Ver:* se aplica sin rechazo.
  *Si falla:* vuelve el snackbar rojo "Faltó un dato obligatorio" / "Un cambio en Clientes
  fue rechazado" → la migración 0174 no está en esa base.
- **Filtro por cobrador en Rutas (2026-07-03):**
  *Rol/identidad:* **admin / admin_cobranza** (pantalla `/admin/rutas`).
  1. En Rutas, abrí el chip **"Cobrador"** (al lado de "Municipio"). *Ver:* lista todos los
     cobradores + **"Sin asignar"**, con buscador; multi-selección.
  2. *Elegí un cobrador.* *Ver:* quedan solo las comunidades donde ese cobrador tiene ≥1
     cliente activo (las **"Mixto"** aparecen si participa). Elegí **"Sin asignar"** → solo
     las comunidades con clientes sin cobrador. Combiná con "Municipio" y el buscador.
  3. *Limpiar (N):* vuelve a mostrar todas.
  *Si falla:* el chip no aparece, filtra a vacío sin salida, o no compone con Municipio.
- **Solicitudes de aprobación con motivo obligatorio (v0.31.20):**
  *Rol/identidad:* se PIDE como **`admin_usuarios` REAL** y se APRUEBA como **`admin` REAL**
  — **NO impersonando** (suspender/cancelar se atribuyen a quien los ejecuta, ver §0.3.0).
  Hacen falta las dos identidades. Ojo: `admin_cobranza` **NO** entra a Solicitudes (la ruta
  está en la lista `soloAdmin` del router y el ítem del menú es `adminOnly`) — no sirve para
  aprobar.
  1. *Pedir:* como `admin_usuarios`, abrí un contrato **activo** → **"Solicitar
     suspensión"** (ese rol no ve "Suspender contrato"). *Ver:* diálogo con **Motivo**
     (desplegable: Solicitud del cliente / Falta de pago / Mudanza · cambio de domicilio /
     Otro) **+ Notas**.
  2. *Obligatoriedad:* dejá las Notas vacías y tocá "Enviar solicitud". *Ver:* **NO
     envía** — el campo se marca con "Escribí el motivo (obligatorio)". Escribí el detalle
     → envía, con snackbar verde.
  3. *La cola lo muestra:* como **admin**, Administración → **Solicitudes**. *Ver:* la
     tarjeta trae quién solicitó **y el recuadro `Motivo: <el motivo> — <las notas>`**.
  4. *Aprobar:* tocá Aprobar. *Ver (lo clave):* el contrato queda **suspendido** y la
     tarjeta **"Suspensión vigente"** muestra **ESE** motivo con sus notas debajo; el
     **Historial de cambios** del contrato registra el cambio de estado con el mismo
     motivo. Ya NO aparece el genérico *"Aprobada solicitud de …"*.
  5. *Cancelar:* mismo flujo con **"Solicitar cancelación"**. *Ver:* al aprobar, el motivo
     del contrato cancelado queda como `<el motivo> — <las notas>` (cancelar no tiene
     campo de notas propio, se anexan al motivo).
  6. *Reactivar:* la solicitud también pide motivo+notas y la cola los muestra, pero la
     reactivación en sí no lleva campo de motivo — quedan en la solicitud. Esperado.
  - *Solicitudes viejas (previas a v0.31.20):* no tienen motivo → la tarjeta no muestra el
    recuadro y al aprobar cae al texto genérico. Es el fallback, no un bug.
  *Si falla:* deja enviar sin notas, la cola no muestra el motivo, o el contrato aprobado
  vuelve a decir "Aprobada solicitud de …".
- ⟨agregar acá los features nuevos a medida que se entregan⟩

---

## 1. Setup del backend en Supabase

### 1.1 Crear el proyecto Supabase

1. Crear proyecto en supabase.com.
2. En **Settings → Auth**: habilitar Email/Password.
3. En **Settings → API**: copiar `URL` y `anon key` a `.env.json`.

### 1.2 Correr las migraciones

En **SQL Editor**, corré en orden los archivos de `supabase/migrations/`:

```
0001_init.sql                          → 0010_settings_defaults.sql
0011_fixes_settings_pk_misc.sql        → 0020_audit_log.sql
0021_anulacion_cuotas.sql              → 0025_fix_b2_reasignacion_offline.sql
```

25 archivos en total. Cada uno debe terminar sin errores.

### 1.3 Correr el smoke test

```sql
-- pegar y ejecutar supabase/smoke_test.sql
```

Debe terminar con `✅ smoke test OK`. Si falla, el error indica qué migración revisar.

### 1.4 Configurar PowerSync

1. En el dashboard de PowerSync: crear instancia conectada a tu Supabase.
2. En **Sync Rules**: pegar el contenido de `powersync/sync-rules.yaml`.
3. Marcar "Use Supabase Auth" en la sección de credenciales.
4. Copiar el `powersync URL` a `.env.json`.

---

## 2. Setup de la app Flutter

### 2.1 Generar plataformas nativas

```bash
flutter create . --platforms=android,ios,web
flutter pub get
```

### 2.2 Configurar permisos nativos

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>

<!-- Bluetooth para impresora térmica -->
<uses-permission android:name="android.permission.BLUETOOTH"
    android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
    android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"/>
```

**iOS** — agregar también en `Info.plist`:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Conectar con impresora térmica para recibos.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Conectar con impresora térmica para recibos.</string>
```

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Capturamos tu ubicación al registrar un cobro para auditoría.</string>
<key>NSCameraUsageDescription</key>
<string>Para tomar foto del comprobante de pago y del cliente.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Para adjuntar foto desde galería.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Conectar con impresora térmica para recibos.</string>
```

### 2.3 Levantar en cada plataforma

```bash
# Mobile (cobrador)
flutter run --dart-define-from-file=.env.json

# Web (admin)
flutter run -d chrome --dart-define-from-file=.env.json
```

---

## 3. Smoke test manual del flujo

### 3.1 Crear usuarios

Desde la **app web** (recomendado):

1. Abrí la app web (admin), tocá "Crear cuenta nueva".
2. Email, contraseña, tu nombre, nombre de tu empresa.
3. Confirmá email si Supabase lo exige.
4. Logueate → llegás al wizard de onboarding.

El trigger `handle_new_user` (migración 0024) crea el tenant + tu fila
como admin automáticamente.

Para sumar más usuarios (admin_cobranza / cobrador), una vez logueado:
- `/admin/cobradores` → botón "Invitar nuevo".
- Ingresá email, nombre, rol y prefijo (si cobrador).
- La Edge Function `invitar-cobrador` los envía por email.

### 3.2 Correr el seed demo (opcional, sólo si querés data de prueba)

Si querés probar con clientes pre-cargados, abrí `supabase/seed_demo.sql`,
pegá los 3 UUIDs de auth.users en las variables de la cabecera
y ejecutalo. Crea:

- 1 tenant
- 3 cobradores con sus roles
- 5 municipios y 10 comunidades
- 3 planes
- 12 clientes con geo
- 8 contratos (mix de duraciones)
- Pagos variados (completos, parcial, USD, anulado)

### 3.3 Test del panel admin (web)

Loguear como `admin@test.com` en la app web.

**Checklist**:
- [ ] Redirect a `/admin` automático
- [ ] Dashboard muestra KPIs (cobrado mes, clientes activos, en mora)
- [ ] `/admin/clientes`: lista **completa** del filtro (sin "Cargar más"), contador "N cliente(s)", scroll fluido a cientos
- [ ] Filtro por comunidad funciona
- [ ] Bulk-assign: seleccionar 3, pedir confirmación, asignar a Pedro
- [ ] `/admin/clientes/nuevo`: crear cliente con foto + GPS picker en mapa
- [ ] `/admin/contratos`: lista de 8 contratos con progreso de cuotas
- [ ] `/admin/contratos/:id`: en el detalle, "Cambiar fecha" (día de pago) → cuotas futuras se actualizan (la ruta `/editar` ya no existe)
- [ ] `/admin/planes`: ver los 3 planes, crear uno nuevo
- [ ] `/admin/cobradores`: ver los 3 cobradores, editar prefijo
- [ ] `/admin/pagos`: anular un pago, ver que la cuota baja a `parcial`
- [ ] `/admin/avisos` (Avisos): ver mora pendiente, marcar como vista
- [ ] `/admin/settings`: cambiar tasa USD, ver que se guarda
- [ ] Historial (op_log): abrir el detalle de un cliente/contrato → Historial → se listan los cambios recién hechos con quién/cuándo (el panel `/admin/audit` ya no existe — 0140)
- [ ] `/admin/geografia`: explorar el árbol depto → municipio → comunidad
- [ ] `/admin/reportes`: ver recaudación, ranking cobradores, mora

### 3.4 Test offline cobrador (mobile)

Loguear como `cobrador@test.com` en la app móvil.

**Checklist conectado**:
- [ ] Home muestra dashboard con métricas del cobrador (no de todos)
- [ ] `/clientes`: ve solo SUS clientes asignados (Pedro tiene los 12 del seed)
- [ ] `/cuotas`: lista de cuotas pendientes con filtros
- [ ] Detalle cliente: ver llamar / WhatsApp / navegar
- [ ] `/cobro/:id`: cobrar parcial 200 de 500 → estado pasa a `parcial`
- [ ] Recibo se muestra con período correcto (regla del 15 sobre día de pago)
- [ ] Aplicar descuento de 10% antes de cobrar → total se ajusta

**Checklist offline** (apagar internet en el teléfono):
- [ ] Banner rojo "Sin conexión" aparece arriba
- [ ] Sigue navegando, viendo clientes y cuotas
- [ ] Hace 2-3 cobros offline (uno con foto del comprobante)
- [ ] Cada recibo se genera con correlativo + número completo
- [ ] Encender internet → banner desaparece
- [ ] Sync indicator del AppBar muestra "uploading" → "synced"
- [ ] Las fotos pendientes en `/perfil` se suben (badge desaparece)
- [ ] En la web del admin, los cobros aparecen

### 3.4.1 Test de impresión Bluetooth (mobile)

**Pareo previo desde el sistema**:
1. Encender la impresora térmica (típico botón POWER con LED).
2. En Ajustes → Bluetooth del teléfono, parear la impresora (ej. POS-58, MTP-3, etc.).

**En la app**:
- [ ] `/perfil` muestra card "Impresora térmica" con "Sin configurar"
- [ ] Tocar → `/perfil/impresora`
- [ ] Si BT off: card rojo "Bluetooth desactivado, encendelo y refrescá"
- [ ] BT on: lista de pareadas aparece
- [ ] Menú "..." → "Imprimir prueba" → sale ticket "PRUEBA DE IMPRESIÓN" con fecha/hora
- [ ] Menú "..." → "Usar como predeterminada" → snackbar de confirmación
- [ ] Card superior cambia a "Impresora predeterminada: <nombre>"
- [ ] `/perfil` card ahora muestra el nombre (no "Sin configurar")
- [ ] En el flujo de cobro: tras confirmar, en `/recibo/:id` botón "Imprimir 80mm" funcional
- [ ] Imprime con header (empresa), info recibo, cliente, servicio, total destacado, pie libre, corte
- [ ] Reimpresión: tocar imprimir otra vez → ticket sale con "*** REIMPRESIÓN ***" al final
- [ ] BD: `recibos.impreso_en` y `reimpresiones` se incrementan

### 3.5 Test de RLS (seguridad)

Desde Supabase SQL Editor, **logueate como uno de los cobradores** (en
`Authentication → Users → user → Generate JWT` y usá ese JWT).

Intenta:

```sql
-- ¿El cobrador puede UPDATE cliente de otro cobrador?
update clientes set nombre = 'HACKEADO' where cobrador_id != auth.uid() limit 1;
-- Esperado: 0 filas afectadas o error.

-- ¿Puede UPDATE su propio rol a admin?
update cobradores set rol = 'admin' where id = auth.uid();
-- Esperado: error (sólo admin puede).

-- ¿Puede UPDATE monto de una cuota?
update cuotas set monto = 1 where cobrador_id = auth.uid() limit 1;
-- Esperado: error del trigger cuotas_check_cobrador_update.

-- ¿Puede mutar correlativo de su recibo?
update recibos set correlativo = 999 where cobrador_id = auth.uid() limit 1;
-- Esperado: error del trigger recibos_check_cobrador_update.
```

Las 4 queries deben fallar o devolver 0 filas. Si alguna se ejecuta, hay
una grieta en RLS.

### 3.6 Test del cron mensual

```sql
-- Forzar la generación de cuotas para el mes próximo (en lugar de esperar al 1 del mes):
select generar_cuotas_mes(t.id, (current_date + interval '1 month')::date)
  from tenants t where nombre = 'ISP Demo Managua';
-- Devuelve cantidad de cuotas creadas.

-- Forzar el cálculo de notificaciones de mora:
select actualizar_notificaciones_mora(t.id) from tenants t where nombre = 'ISP Demo Managua';
-- Devuelve cantidad de notificaciones afectadas.
```

---

## 4. Troubleshooting frecuente

| Síntoma | Causa probable | Fix |
|---|---|---|
| App móvil queda en spinner tras login | Sync rules mal copiadas o cobrador sin fila en `cobradores` | Verificar que el UUID del seed coincide con auth.users |
| `flutter run` falla en web por `dart:io` | Conditional import roto | Confirmar que `foto_local_storage.dart` exporta con `if (dart.library.html)` |
| Cron no genera cuotas | pg_cron deshabilitado en tu plan Supabase | Activarlo o llamar manualmente la función |
| Botón "Cobrar" disabled siempre | Cobrador sin `prefijo_recibo` asignado | Admin va a `/admin/cobradores` y le asigna uno |
| Foto del comprobante no se sube | Sin internet O policy Storage incorrecta | Ver indicador en perfil; verificar 0019 y 0022 |
| Recibo dice mes incorrecto | Bug pre-fix S1; reverificar | Confirmar que migración 0014 está aplicada |

---

## 5. Notas conocidas

- **Auto-creación de cobradores**: hoy el admin invita desde Supabase Dashboard
  y luego asigna prefijo desde `/admin/cobradores`. Una Edge Function para
  automatizar esto está pendiente.
- **Impresión Bluetooth**: el preview del recibo funciona; el botón "Imprimir"
  está disabled hasta integrar `print_bluetooth_thermal`. El recibo igual
  se sincroniza al server.
- **Audit log offline**: las funciones SECURITY DEFINER del cron corren como
  postgres (sin auth.uid), así que las notificaciones generadas por cron
  tienen `user_id = NULL`. El viewer las muestra como "Sistema".
