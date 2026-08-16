# MODULOS.md — Catálogo de módulos de CRM

> **Qué es este doc:** el mapa de los módulos de la app — para cada uno, su
> **propósito**, sus **features** (lo que sabe hacer hoy), un **ciclo de uso**
> de punta a punta y un **diagrama** simple de ese flujo. Es el índice mental
> de "qué hace cada parte de la app y cómo se usa".
>
> **Quién lo lee:** cualquier agente de AI o persona que abre el repo y necesita
> ubicarse rápido en qué módulos existen, qué es opcional y quién puede usarlo —
> antes de tocar código (la receta del cambio está en `ARQUITECTURA.md §0`).
>
> **Cuándo actualizarlo:** cuando se agrega un módulo nuevo, cambia el propósito
> o las features de uno existente, o cambia su gating (rol / opcional por tenant).
> No es la fuente de la arquitectura interna (eso es `ARQUITECTURA.md`) ni del
> estado vivo (eso es `BITACORA.md`) — acá va el "qué hace y cómo se usa".

---

## Índice de módulos

**Estado:** `siempre` = módulo núcleo, siempre activo · `opcional` = gate por
tenant (lo prende el super_admin) · `por rol` = visible/usable solo para ciertos
roles.

### Núcleo de dinero

| Módulo | Para qué sirve (1 línea) | Estado |
|---|---|---|
| [Clientes (ficha + etiquetas)](#clientes-ficha--etiquetas) | Padrón de abonados: alta/edición de la ficha y su detalle; raíz de la cadena de dinero | siempre · alta/edición por rol |
| [Contratos](#contratos) | El acuerdo de servicio (plan, precio, día_pago, duración); al crearse genera las cuotas | siempre · por rol |
| [Cuotas / Cobros ("Por cobrar")](#cuotas--cobros-por-cobrar) | La lista de trabajo: una fila por contrato con su cuota más vieja pendiente | siempre |
| [Pagos (cobro, vuelto, multi-moneda)](#pagos-cobro-vuelto-multi-moneda) | El acto de cobrar: registra el pago, calcula vuelto, offline-first | siempre |
| [Recibos](#recibos) | El comprobante del cobro: térmica Bluetooth (celular), USB/sistema (PC) o PDF | siempre |
| [Mora y Suspensiones](#mora-y-suspensiones) | Cuotas vencidas y el ciclo suspender/reactivar/cancelar | siempre · por rol |
| [Cargos extra (ajustes / descuentos)](#cargos-extra-ajustes--descuentos) | Sumar cargos o restar descuentos al saldo de una cuota | siempre · descuentos gateados |
| [Saldo a favor (crédito por excedente)](#saldo-a-favor-crédito-por-excedente) | La plata pagada de más: se acredita y se aplica como descuento, sin tocar caja | siempre · por rol |

### Campo y operación

| Módulo | Para qué sirve (1 línea) | Estado |
|---|---|---|
| [Cobradores / Personal](#cobradores--personal) | Invitar y gestionar el personal (cobradores, admins, técnicos) | por rol (admin/super) |
| [Solicitudes de aprobación](#solicitudes-de-aprobación-cola-admin_usuarios) | Cola de aprobación para acciones estructurales de admin_usuarios | por rol (admin/admin_cobranza/admin_usuarios) |
| [Visitas](#visitas-registro-del-cobrador-en-campo) | El cobrador registra el resultado de una visita sin cobro | opcional (por tenant) |
| [Mapa de clientes](#mapa-de-clientes) | Clientes geolocalizados con pin por estado de cobranza; ruta del día | siempre · por rol |
| [Geografía](#geografía-departamentos--municipios--comunidades) | Catálogo geográfico jerárquico (depto → municipio → comunidad) | por rol (admin/super) |
| [Planes](#planes) | Catálogo de planes de servicio (nombre, tipo, precio); base de la facturación | por rol (admin/super) |

### Módulos opcionales (gate por tenant)

> **Independencia del núcleo (verificado 2026-07-01):** el gate de estos módulos es
> SOLO cliente-side (router + menú + secciones UI que los renderizan); NO hay gate
> server-side sobre cobranza. Con **tickets e inventario OFF**, TODO el lifecycle de
> contratos sigue 100%: suspender / cancelar / reactivar / cambiar fecha / cambiar plan
> / cobrar (gateados por rol + settings super_admin, nunca por módulo). Lo único que
> cambia: la cola **"A suspender"** del Centro queda vacía (se alimenta de órdenes de
> corte de tickets) → **la suspensión pasa a ser MANUAL** desde el detalle del contrato;
> el botón "Orden de corte" en Avisos y las secciones de Equipos/Materiales se ocultan.
> Sin crashes ni queries rotas (las colas devuelven vacío). Fuera de ruta, avisos,
> reportes, arqueo y generación de cuotas son independientes de estos módulos.

| Módulo | Para qué sirve (1 línea) | Estado |
|---|---|---|
| [Inventario](#inventario) | Stock del ISP de cuna a tumba (catálogo, seriales, ledger); stock derivado | opcional (por tenant) |
| [Tickets (con rol Técnico)](#tickets-con-rol-técnico) | Ciclo de trabajo de campo: crear/asignar/resolver/cerrar con SLA | opcional (por tenant) |
| [Incidentes (cortes masivos)](#incidentes-cortes-masivos--outages) | Agrupar bajo un outage los clientes/tickets afectados de un corte | opcional (junto con Tickets) |
| [Red / Topología](#red--topología-nodo--hub--puerto) | Topología física (Nodo → Hub → Puerto) para ubicar al cliente en la red | siempre · por rol |

### Plataforma y transversal

| Módulo | Para qué sirve (1 línea) | Estado |
|---|---|---|
| [Multi-tenant + Super-admin](#multi-tenant--super-admin) | Panel del dueño del SaaS: crear tenants, togglear módulos, impersonar | por rol (super_admin) |
| [Auth / Onboarding (sin email)](#auth--onboarding-sin-email) | Login y alta de usuarios sin signup público (password por WhatsApp) | siempre · alta por rol |
| [Settings / Configuración](#settings--configuración) | Configura empresa, cobranza, métodos de pago y recibo | por rol (admin/super) |
| [Historial / Change-log (op_log)](#historial--change-log-op_log-unificado) | El único registro append-only de cambios por entidad | siempre · lectura por rol |
| [Centro de cobranza](#centro-de-cobranza) | Hub operativo del admin: métricas del día + colas de suspender/reactivar | por rol (admin/admin_cobranza) |
| [Notificaciones / WhatsApp](#notificaciones--whatsapp) | Avisar a clientes en gracia/mora (wa.me manual; API Meta dormida) | opcional (por tenant) |
| [Reportes / Arqueo / Dashboard](#reportes--arqueo--dashboard) | KPIs del mes y reportes exportables (arqueo, cobros, fiscal...) | por rol (admin) |
| [Etiquetas de cliente](#etiquetas-de-cliente) | Catálogo de etiquetas (nombre+color+icono) para clasificar clientes | por rol (admin) |

---

## Núcleo de dinero

### Clientes (ficha + etiquetas)

**Para qué sirve:** Padrón de los abonados del ISP — alta/edición de la ficha
(datos, ubicación, cobrador asignado, etiquetas) y su detalle con pestañas
Detalle/Contratos/Equipos/Visitas. Es la raíz de la cadena de dinero: sin
cliente no hay contrato ni cobro.

**Features:**
- Lista paginada (scroll infinito ~60/página + contador COUNT real del filtro) con buscador case-insensitive plegado a ASCII (`foldBusqueda`) y filtros por cobrador y zona.
- Alta y edición de la ficha: datos personales, código, cédula, comunidad/ubicación, puerto de red, `cobrador_id` ORGANIZATIVO (puede ser NULL = admin-managed).
- Detalle con pestañas: Detalle, Contratos (abre el detalle del contrato), Equipos instalados, Visitas (pestaña opcional gateada por `cobranza.registrar_visitas`).
- Etiquetas: catálogo per-tenant que admin/admin_cobranza asignan al cliente desde su detalle; chips visibles en lista, mapa y cobro.
- Historial op_log del cliente (bottom sheet) y PDF de historial; acciones externas (llamar / WhatsApp / mapa).
- El cobrador VE y cobra todos los clientes del tenant (RLS tenant-wide); `cobrador_id` solo define el foco de ruta/listado, no la visibilidad.

**Ciclo de uso:** El admin da de alta al cliente (datos + comunidad + cobrador
organizativo) y, opcionalmente, le pega una o varias etiquetas del catálogo.
Desde el detalle abre la pestaña Contratos para crear su primer contrato. El
cliente queda visible en la lista, en el mapa (pin por vencimiento) y para el
cobrador en su ruta. Reasignar el cobrador propaga a contratos/cuotas vía
trigger sin tocar el historial de quién cobró.

**Lifecycle (diagrama):**
```
Catálogo de etiquetas (admin)
        |
        v
Alta cliente  ->  Asignar etiquetas  ->  Crear contrato (pestaña Contratos)
     |                                          |
     +--(reasignar cobrador)-> cambia foco de ruta (no toca historial)
                                                v
                                   Cliente cobrable (lista / mapa / ruta)
```

**Gating:** Siempre activo (núcleo). Alta/edición = admin/admin_cobranza (write
admin-only); el cobrador la ve en solo-lectura. Etiquetas: el CATÁLOGO
(`/admin/etiquetas`) es SOLO admin (lista `soloAdmin` del router — admin_cobranza
rebota); la ASIGNACIÓN desde el detalle del cliente es admin/admin_cobranza.
Pestaña Visitas = gate por tenant (`cobranza.registrar_visitas`, super-only).

*Archivos: `lib/features/clientes/clientes_list_screen.dart`,
`lib/features/clientes/cliente_detail_screen.dart`,
`lib/features/admin/clientes/`,
`lib/features/admin/etiquetas/etiquetas_admin_screen.dart`,
`lib/data/repositories/clientes_repo.dart`,
`lib/data/repositories/etiquetas_repo.dart`.*

---

### Contratos

**Para qué sirve:** El acuerdo de servicio entre el ISP y el cliente: define el
plan/precio mensual, el `dia_pago` y la duración (fijo de N meses o indefinido).
Al crearse, un trigger server genera automáticamente las cuotas del período. Es
el contenedor del que cuelga toda la plata.

**Features:**
- Alta de contrato: plan, precio mensual, `dia_pago`, fijo (N meses) o indefinido; al insertar, el trigger `contratos_generar_cuotas_iniciales` genera las cuotas.
- Detalle con tarjeta de header (estado, plan, total/recaudado/pendiente) + pestañas de cuotas, pagos y documento.
- Total contrato MOSTRADO = `Σ cuotas vivas` (monto + cargos de las no-anuladas = `recaudado + pendiente`), **NO** `precio_mensual × meses` (invariante #5 redefinido por R22 — robusto al cambio de plan; las cuotas son snapshots del precio de su momento). El nominal `precio×meses` queda solo para detectar fijo vs indefinido y como hint "ajustado" por CONTEO de cuotas. `pendiente` = suma de saldos canónicos cobrables. Indefinidos: solo total recaudado, sin pendiente.
- Acciones de ciclo desde el detalle: Cambiar fecha de pago (cobra el "puente" de días y re-fecha futuras), Suspender, Reactivar, Cancelar (permanente).
- Gestión de cargos/descuentos del contrato (`CargoDialog`/`DescuentoDialog`) y aplicación de crédito a favor.
- Historial op_log del contrato; PDF de deuda en suspensión.

**Ciclo de uso:** Desde el detalle del cliente, el admin crea el contrato
eligiendo plan, precio, `dia_pago` y duración. El trigger server genera las
cuotas del período, que bajan al cobrador asignado y al admin. A lo largo de la
vida del contrato el admin puede cambiar la fecha de pago, suspender/reactivar o
cancelarlo; cada evento re-ancla la facturación a la ventana de servicio del
`dia_pago`. El total y el recaudado se muestran siempre desde el saldo canónico.

**Lifecycle (diagrama):**
```
Detalle cliente -> Crear contrato (plan + dia_pago + meses)
                        |
                        v (trigger server)
                 Se generan las cuotas del período
                        |
          +-------------+-------------+-------------+
          v             v             v             v
      Cambiar       Suspender     Reactivar     Cancelar
      fecha         (anula gap)   (re-ancla)    (permanente)
```

**Gating:** Siempre activo (núcleo).
Crear/editar/suspender/reactivar/cancelar/cambiar-fecha = admin/admin_cobranza.
**Cambiar plan = solo admin** (no admin_cobranza — es gestión administrativa,
Fase 2 roles 2026-07-19). Header del contrato: admin_cobranza NO ve "Recaudado"
(solo Total + Pendiente). El cobrador con foco en el cliente puede "Cambiar
fecha" de los suyos (gateado + trigger owner-scoped).

*Archivos: `lib/features/contratos/contrato_detail_screen.dart`,
`lib/features/contratos/contrato_detail_header.dart`,
`lib/features/contratos/contrato_detail_cuotas.dart`,
`lib/features/admin/contratos/`,
`lib/data/repositories/contratos_repo.dart`,
`ARQUITECTURA.md §3.5 (1)(2)(5)`.*

---

### Cuotas / Cobros ("Por cobrar")

**Para qué sirve:** La lista de trabajo del cobrador (y vista admin): UNA fila
por contrato mostrando su cuota más antigua pendiente, con botón "Pagar" que va
directo al cobro. Es la pantalla que dice "qué hay que cobrar hoy".

**Features:**
- Pantalla "Por cobrar": una fila por contrato = cuota más vieja pendiente (igual que el pin del mapa), agregada en SQL (`cobros_query.dart`, escala a miles).
- Chips de estado (todas/vencidas/gracia/hoy/próxima) y, en adminMode, filtros dropdown por cobrador y por zona.
- Buscador client-side con debounce, plegado a ASCII (`foldBusqueda`) para matchear nombres con ñ/acentos.
- Botón "Pagar" abre `/cobro` de esa cuota; tocar la fila abre el detalle del cliente.
- Saldo canónico de cada cuota = `monto + cargos_neto − monto_pagado`; idéntico en toda pantalla (invariante #10).
- Cortes de día en hora Nicaragua (`date('now','-6 hours')`); la ruta activa excluye suspendidos y cancelados.
- Toggle **"Ver fuera de ruta"** (off por defecto, cobrador y admin): anexa una sección **"Recuperación · fuera de ruta"** con la deuda viva de contratos **cancelados y suspendidos** (antes solo visible como el badge "debe C$X fuera de ruta" en Clientes; ahora cobrable desde el campo). `cobrosFueraDeRutaQuery` (oldest por contrato, ignora los chips de fecha; las queries activas quedan intactas). **Cobrar NO reactiva:** si un suspendido queda en deuda 0, aviso "pendiente de reactivar" + botón Reactivar (solo admin); un cancelado nunca reactiva.

**Ciclo de uso:** El cobrador abre "Por cobrar" y ve sus contratos con saldo
pendiente (la cuota más vieja de cada uno), ordenados/filtrados por estado. Toca
"Pagar" en una fila para ir al cobro de esa cuota, o toca la fila para abrir el
cliente. El admin usa la misma pantalla en modo admin con filtros por
cobrador/zona para supervisar.

**Lifecycle (diagrama):**
```
Lista 'Por cobrar' (1 fila por contrato = cuota más vieja)
        |
   +----+--------------------------------+
   |                                     |
 (botón Pagar)                      (tocar fila)
   v                                     v
 Cobro de esa cuota               Detalle del cliente
   |
   +--(filtros admin: cobrador / zona / estado)
```

**Gating:** Siempre activo (núcleo). Es la vista principal del cobrador
(móvil-first) y del admin/admin_cobranza (adminMode con filtros). Oldest-first
enforzado: no se cobra dejando atrás una cuota más vieja del mismo contrato.

*Archivos: `lib/features/cuotas/cuotas_list_screen.dart`,
`lib/features/cuotas/cobros_query.dart`,
`lib/data/repositories/cuotas_repo.dart`,
`ARQUITECTURA.md §3.5 (3)(4), §3.7 punto 3`.*

---

### Pagos (cobro, vuelto, multi-moneda)

**Para qué sirve:** El acto de cobrar: registra el pago aplicado a la cuota más
vieja del contrato, calcula vuelto, soporta multi-moneda (USD a tasa snapshot) y
múltiples métodos. Es offline-first: escribe todo local en una transacción y la
verdad la recalcula un trigger server al sincronizar.

**Features:**
- Pantalla de cobro: monto entregado, moneda (NIO/USD a tasa snapshot), método (efectivo/transferencia/tarjeta según settings), referencia, notas, foto de comprobante opcional.
- Cálculo de vuelto SIEMPRE en córdobas (el vuelto jamás se da en USD); `monto_cordobas` = lo aplicado a caja, `vuelto_cordobas` = devuelto, `monto_original` = lo entregado en su moneda.
- Cobro multi-cuota (varias cuotas en una transacción); pago parcial y adelantado según settings (super-only).
- Cargos automáticos detectados (reconexión, pronto pago) insertados recién al confirmar; descuentos/cargos del admin mostrados como referencia.
- Panel `/admin/pagos` (opcional, gate por tenant): listado con anular y editar (editar bloqueado si tiene vuelto o es USD).
- Anular preserva el pago (`anulado=1`) y restaura la cuota vía trigger; QUIÉN cobró = `pagos.cobrador_id` (NOT NULL, alimenta arqueo y "por cobrador").
- Escribe op_log dentro del `writeTransaction`; al confirmar va directo al recibo.

**Ciclo de uso:** Desde "Por cobrar" (botón Pagar) el cobrador abre el cobro de
la cuota más vieja. Ingresa lo que el cliente entrega y la moneda; si paga de
más, la app calcula el vuelto en córdobas. Confirma (opcionalmente con foto de
comprobante) → se graba todo local al instante y se va al recibo. Con red, sube
la cola y el trigger server recalcula `monto_pagado`/estado de la cuota. Un pago
mal hecho se anula desde `/admin/pagos` (si está habilitado), preservando el
registro.

**Lifecycle (diagrama):**
```
Por cobrar (Pagar) -> Cobro: monto + moneda (NIO/USD) + método
                          |
                  +-------+--------+
                  |                |
            paga exacto       paga de más
                  |                |
                  |          Vuelto (siempre C$)
                  +-------+--------+
                          v
                 Confirmar -> Recibo (offline)
                          |
            sync -> trigger recalcula la cuota
                          |
               +--(error)--> Anular (preserva pago, restaura cuota)
```

**Gating:** Cobro = siempre activo (cobrador, admin, admin_cobranza). USD/tasa,
pago_parcial/adelantado, métodos extra, foto comprobante, cargo reconexión =
settings super-only. Pantalla `/admin/pagos` = gate por tenant
(`cobranza.pantalla_pagos`). Anular/editar pago por el cobrador = settings
super-only; bloqueado al impersonar.

*Archivos: `lib/features/cobro/cobro_screen.dart`,
`lib/features/admin/pagos/pagos_admin_screen.dart`,
`lib/data/repositories/pagos_repo.dart`,
`lib/data/utils/cobro_calculo.dart`,
`ARQUITECTURA.md §3.5 (3), §4 (a)(c)`.*

---

### Recibos

**Para qué sirve:** El comprobante del cobro: se genera al confirmar el pago y
se imprime en térmica —Bluetooth desde el celular, USB/red desde la PC— o se
exporta como PDF. Layout configurable por el diseñador de recibo. Es la prueba
que el cobrador entrega en campo.

**Features:**
- Pantalla de recibo tras confirmar el cobro; impresión térmica offline (`recibo_ticket.dart`) y export PDF (`recibo_pdf.dart`).
- **Celular (Bluetooth, offline):** impresora pareada como predeterminada; modo Imagen o Compatible, selector de tildes y "Envío lento" para las térmicas que pierden el final del recibo.
- **PC (Windows, USB/red):** la impresora se elige entre las del sistema y hay **3 modos por-PC** — **Imagen** (default: fiel a la vista previa, conserva diseño, tamaños y logo), **Texto nativo** (letra interna de la impresora: liviano y SIEMPRE completo, con logo pero sin los tamaños del diseñador) y **Por driver de Windows** (el camino anterior, de respaldo). Si el envío directo falla, cae solo al PDF por driver y el recibo no se pierde.
- Ajustes finos de impresión **por PC** (no afectan a los celulares ni a las otras PCs): margen izquierdo, **"Avance antes del corte"** (empuja el pie/slogan más allá de la cuchilla antes de cortar — sin él el último bloque se pierde o reaparece arriba del recibo siguiente), grosor del texto, compatibilidad de imagen y densidad del cabezal.
- **"Impresión lenta"** (modo imagen, opt-in): manda el recibo en partes con pausas para las térmicas de buffer chico que dejan en blanco el final de los recibos largos (los que llevan lista de mora).
- **"Regla de ancho"** (modo texto): imprime líneas numeradas y rotuladas; el número más alto que sale COMPLETO es el ancho real de ESA impresora y se carga en el slider "Ancho de línea" → se acaba el recorte del borde derecho. Mide el hardware en vez de estimarlo.
- **Tildes (acentos)** por dispositivo: Sin tildes (transliterado — default en PC, infalible y alinea perfecto), Acentos (alfabeto nativo de las térmicas chinas, ej. 3nStar), Estándar y Occidental, para las impresoras que devuelven garabatos con las tablas occidentales.
- Layout configurable: bloques/zonas/tamaños vía `recibo.layout`; título, pie libre, formato mm, mostrar cédula/adeudado, mostrar descuentos y motivo.
- Bloque "EN MORA" que lista cuotas vencidas rotuladas con el mes simbólico de servicio (`recibo_mora.dart`).
- Desglose de cargos/descuentos del bloque cuota (`recibo_cargos.dart`) con sub-toggles del diseñador.
- Branding de la empresa (nombre/dirección/teléfono/RUC/logo) desde settings.
- El recibo captura quién cobró de `recibos.cobrador_id` (NOT NULL).

**Ciclo de uso:** Al confirmar un cobro la app navega al recibo, que arma con
los datos del pago + el layout configurado + el branding del ISP. El cobrador lo
imprime en su térmica Bluetooth (funciona sin internet) o el admin lo imprime
desde la PC en la térmica USB; también puede exportarlo a PDF. Si hay cuotas
vencidas, el recibo incluye un bloque "EN MORA" con el desglose. La impresora se
configura UNA vez por equipo en **Perfil → Impresora** (o desde el mismo recibo,
"Configurar impresora"): ahí se elige la predeterminada, se hace "Imprimir
prueba" y —en PC— se calibra el modo y los ajustes finos; con una impresora que
recorta a la derecha, primero se mide con la "Regla de ancho".

**Lifecycle (diagrama):**
```
Confirmar cobro -> Generar recibo (layout + branding + bloque mora)
                         |
        +----------------+-----------------+
        v                v                 v
  Térmica Bluetooth   Térmica USB      Exportar PDF
  (celular, offline)  (PC: imagen /
        |             texto / driver)
        |                v
        |         (falla el directo) -> PDF por driver (no se pierde)
        +----------------+
                 v
        Comprobante al cliente

Perfil > Impresora (por equipo): elegir predeterminada -> Imprimir prueba
        -> (PC) modo + avance antes del corte + impresión lenta
        -> ¿corta a la derecha? -> Regla de ancho -> cargar 'Ancho de línea'
        -> ¿garabatos en los acentos? -> cambiar Tildes
```

**Gating:** Siempre activo (núcleo). El layout/textos del recibo se configuran
vía settings (diseñador de recibo, por tenant). Los ajustes de impresión son
**por dispositivo** (no por tenant ni por rol): cada celular/PC guarda los
suyos. Lo dispara cualquier cobro (cobrador/admin/admin_cobranza).

*Archivos: `lib/features/recibo/recibo_screen.dart`,
`lib/features/recibo/recibo_ticket.dart`,
`lib/features/recibo/recibo_texto_escpos.dart`,
`lib/features/recibo/recibo_pdf.dart`,
`lib/features/recibo/recibo_mora.dart`,
`lib/features/recibo/recibo_cargos.dart`,
`lib/features/impresora/impresora_setup_screen.dart` (Bluetooth),
`lib/features/impresora/impresora_sistema_setup.dart` (PC: modos, ajustes,
regla de ancho, tildes),
`lib/data/providers/impresora_provider.dart`,
`lib/data/services/impresora/recibo_escpos.dart`,
`lib/data/services/impresora/windows_raw_printer.dart`,
`ARQUITECTURA.md §5 settings recibo.*, §3.5 (4)`.*

---

### Mora y Suspensiones

**Para qué sirve:** Gestiona las cuotas vencidas (mora tras los días de gracia)
y el ciclo de suspender/reactivar/cancelar contratos morosos. La mora se marca
con un cron diario; la suspensión congela la deuda re-anclada a la ventana de
servicio.

**Features:**
- Mora: cron diario (06:05 UTC = medianoche Nicaragua) genera `notificaciones_mora` SOLO de cuotas de contratos activos (suspendidos/cancelados no generan mora); contador de mora (`moraCountProvider`).
- Badge "Vencida Nd" = días desde el venc − `dias_gracia` (setting `cobranza.dias_gracia`, default 10); coincide con el reporte.
- Suspender: motivo predefinido + notas; clasifica cada cuota por `estadoServicio` (cumplido = entera, en_curso = prorrateo por días, futuro = anular), congela snapshot de deuda, ofrece disponer del excedente a favor.
- Reactivar: cualquier día posterior a la suspensión; re-ancla el `dia_pago` al día de reactivación y revive el gap anulado sin estirar `fecha_fin` (mismo día → Revertir).
- Cancelar (permanente): como suspender pero sin reactivar, deja la deuda real cobrable (no liquida a 0), exige motivo.
- PDF de deuda en suspensión (reimprimible desde la tarjeta de suspensión).
- El "por cobrar" EXCLUYE suspendidos → van al KPI "Suspendido (por reactivar)" aparte.

**Ciclo de uso:** Una cuota vence; pasados los días de gracia el cron la marca
en mora y aparece el badge "Vencida Nd". Si el cliente sigue sin pagar, el admin
suspende el contrato: la app clasifica cada cuota por su ventana de servicio
(cobra lo consumido, anula lo futuro) y congela un snapshot de deuda; si había
excedente, decide qué hacer con él. Cuando el cliente vuelve, el admin reactiva
re-anclando el ciclo al día de reactivación. Si nunca vuelve, cancela
permanentemente dejando la deuda real cobrable.

**Lifecycle (diagrama):**
```
Cuota vence -> (pasan dias_gracia) -> Cron marca MORA -> badge 'Vencida Nd'
                                                  |
                                        (cliente no paga)
                                                  v
                                            Suspender contrato
                                       (cobra consumido, anula futuro,
                                        congela deuda + dispone excedente)
                                                  |
                              +-------------------+-------------------+
                              v                                       v
                    Reactivar (re-ancla ciclo)             Cancelar (permanente,
                                                            deja deuda cobrable)
```

**Gating:** Siempre activo (núcleo). Suspender/reactivar/cancelar =
admin/admin_cobranza. Mora la genera el cron server (no manual). `dias_gracia`
es setting (super-only). El cobrador no suspende.

*Archivos: `lib/features/contratos/suspension_dialogs.dart`,
`lib/data/providers/mora_count_provider.dart`,
`lib/data/repositories/contratos_repo.dart` (suspender/reactivar),
`lib/features/admin/reportes/pdf/reporte_deuda_suspension_pdf.dart`,
`ARQUITECTURA.md §3.5 (5), §4 (b)`.*

---

### Cargos extra (ajustes / descuentos)

**Para qué sirve:** Permite al admin ajustar el monto a cobrar de una cuota:
sumar cargos (reconexión, otro) o restar descuentos (ajuste/corrección o
promo/beneficio comercial). Se asocian a la cuota y modifican su saldo canónico
(`cargos_neto`), sin tocar el total fijo del contrato.

**Features:**
- `CargoDialog`: agrega un `cargos_extra` positivo (tipo "reconexión" u "otro"), se suma al saldo de la cuota.
- `DescuentoDialog`: agrega un descuento negativo vía `cargos_extra` con origen "ajuste" (corrección) o "promo" (beneficio comercial); chip que cambia la semántica y los motivos sugeridos; tope por % o monto (`ajuste_max_porcentaje`/`_monto`).
- Motivo SIEMPRE obligatorio; el trigger `cargos_extra_actualizar_neto` recalcula `cuotas.cargos_neto` (la verdad la mantiene el server, el cliente espeja).
- Cargos manuales cuentan para el recaudado pero NO para el total fijo del contrato.
- Reconexión puede ser automática en el cobro (`cargo_reconexion_habilitado`) o manual vía `CargoDialog`; el cobro los muestra como referencia.
- Saldo canónico = `monto + cargos_neto − monto_pagado`; descuentos y `credito_aplicado` restan, reconexión/otro suman.

**Ciclo de uso:** Desde el detalle del contrato/cuota, el admin agrega un cargo
(ej. reconexión) o un descuento (ajuste por días sin servicio, o una promo),
siempre con motivo. El trigger server recalcula el `cargos_neto` de la cuota,
cambiando su saldo a cobrar. La próxima vez que se cobre esa cuota, el monto a
pagar ya refleja el ajuste; el cobro lo muestra como referencia.

**Lifecycle (diagrama):**
```
Detalle contrato/cuota (admin)
        |
   +----+----------------+
   v                     v
 CargoDialog (+)     DescuentoDialog (-)
 (reconexión/otro)   (ajuste / promo) + motivo
   |                     |
   +----------+----------+
              v (trigger recalcula cargos_neto)
     Nuevo saldo canónico de la cuota
              v
        Se cobra con el ajuste aplicado
```

**Gating:** El modelo siempre activo, pero los descuentos/ajustes del admin
están gateados por `cobranza.ajustes_habilitados` (super-only) con topes
`ajuste_max_porcentaje`/`_monto`. Reconexión automática =
`cargo_reconexion_habilitado`. Solo admin/admin_cobranza aplican cargos/descuentos
(el cobrador no descuenta).

*Archivos: `lib/features/shared/widgets/cargo_dialog.dart`,
`lib/features/shared/widgets/descuento_dialog.dart`,
`lib/data/repositories/cuotas_repo.dart`,
`lib/data/repositories/contratos_repo.dart` (`cargosNeto`),
`ARQUITECTURA.md §3.5 (3), §5 settings cobranza.ajustes_*/cargo_reconexion_*`.*

---

### Saldo a favor (crédito por excedente)

**Para qué sirve:** Maneja la plata que un cliente pagó de más (excedente,
típicamente al suspender/cancelar con cuotas adelantadas). El crédito NO es un
pago: se acredita en `saldos_favor` y se aplica como descuento
(`credito_aplicado`) en futuras cuotas, por diseño sin tocar caja ni el arqueo.

**Features:**
- Libro append-only `saldos_favor` por cliente (cruza contratos): tipos "acreditado" (+), "aplicado"/"credito_aplicado", "condonado", "devuelto".
- Al suspender/cancelar con excedente, el admin DECIDE la disposición (nunca automática): acreditar (queda disponible), condonar (la plata queda en caja, auditada) o devolver (sale de caja con `cobrador_id` + fecha para el arqueo).
- `saldoFavorDisponible(cliente)`: suma firmada del libro; trigger server anti-sobregiro valida que no se exceda.
- Aplicar crédito a una cuota: inserta `cargos_extra` tipo "credito_aplicado" (RESTA del saldo) + fila `saldos_favor` "aplicado", clampeado al `min(saldo cuota, disponible)`.
- Por diseño NO toca `pagos` → el crédito a favor NO aparece en ninguna métrica de caja (`recaudado_caja`); `cobertura_cuota` sí lo incluye.
- `recaudado_caja` resta los saldos a favor devueltos; trazabilidad por `cuota_id` (una 2ª suspensión no re-ofrece el mismo excedente, anti doble-acreditación).
- Emite op_log de la disposición en el contrato (monto/motivo en el resumen).

**Ciclo de uso:** Un cliente paga adelantado y luego se suspende/cancela su
contrato: queda un excedente. El admin elige qué hacer: acreditarlo (lo deja
como crédito disponible del cliente), condonarlo (se queda en caja) o devolverlo
(sale de caja, queda en el arqueo). Si lo acreditó, más adelante puede aplicar
ese crédito a una cuota nueva: se descuenta del saldo sin que entre plata a caja
(es un descuento, no un cobro).

**Lifecycle (diagrama):**
```
Cliente paga de más + suspensión/cancelación -> Excedente a favor
                         |
          +--------------+--------------+
          v              v              v
      Acreditar      Condonar       Devolver
   (queda crédito)  (queda caja)  (sale de caja, arqueo)
          |
          v (más adelante)
  Aplicar crédito a una cuota (credito_aplicado)
   = descuento del saldo, NO toca caja
```

**Gating:** Siempre activo (núcleo). La disposición del excedente
(acreditar/condonar/devolver) y la aplicación de crédito = admin/admin_cobranza
(nunca automática). El cobrador no dispone de créditos.

*Archivos: `lib/data/repositories/contratos_repo.dart`
(`registrarDisposicionExcedente`, `saldoFavorDisponible`, aplicar crédito),
`lib/features/contratos/suspension_dialogs.dart`,
`lib/features/contratos/contrato_detail_pagos.dart`,
`lib/features/admin/reportes/arqueo_calculo.dart`,
`ARQUITECTURA.md §3.5 (3)(4), invariante #4 recaudado_caja vs cobertura_cuota`.*

---

## Campo y operación

### Cobradores / Personal

**Para qué sirve:** Gestión del personal de la empresa (cobradores, admins,
técnicos): invitar usuarios, asignarles prefijo de recibo, rol, teléfono,
activarlos/desactivarlos y forzar contraseña. Es la única pantalla donde se dan
de alta los usuarios que operan la app.

**Features:**
- Lista de miembros del tenant con avatar por rol, chip de rol y badge "Inactivo", ordenada por activo/rol/nombre.
- Stats por miembro que cobra: prefijo de recibo, # de clientes asignados y total cobrado en el mes (SUM pagos no anulados del mes, corte −6h Nicaragua).
- Email traído de `auth.users` por RPC `list_cobrador_emails` (online-only, degrada elegante si no hay conexión).
- Invitar nuevo miembro vía Edge `invitar-cobrador`: email, nombre, teléfono, rol y prefijo (auto-genera prefijo de 2 letras si se deja vacío).
- Onboarding SIN email por default: el server genera/usa una contraseña que se muestra UNA vez en `CredencialesDialog` para compartir por canal seguro.
- Roles ofrecidos: cobrador, admin_cobranza, admin_usuarios, admin; y tecnico/admin_tickets solo si el tenant tiene el módulo "tickets".
- Editar miembro: nombre, teléfono, prefijo, activo y `puede_cambiar_fecha` (gateado por `cambioFechaHabilitado`, solo cobrador/admin_cobranza).
- Cambio de rol restringido al super_admin (el trigger `cobradores_freeze_rol` rechaza el write directo; el rol va por RPC `set_cobrador_rol`).
- Forzar contraseña (solo admin/super_admin, nunca sobre uno mismo) vía `superAdminRepo.forzarPasswordCobrador`.
- Historial de cambios por miembro (op_log) — el prefijo de recibo es numeración de dinero, por eso se audita.

**Ciclo de uso:** El admin entra a Cobradores → "Invitar nuevo", completa
email/nombre/rol/prefijo → la app crea el usuario y muestra la contraseña una
sola vez → el admin se la pasa al empleado por WhatsApp. El empleado entra con
esas credenciales y aparece en la lista con sus stats. Más tarde el admin puede
editarlo (cambiar prefijo, desactivarlo) o forzarle una contraseña nueva si la
pierde. Reasignar clientes a este cobrador se hace desde Clientes, no acá.

**Lifecycle (diagrama):**
```
Admin abre Cobradores -> Invitar (email/nombre/rol/prefijo) -> Server crea usuario
        -> Contraseña visible 1 vez -> Se comparte por WhatsApp -> Empleado loguea
              |
              +--(olvidó pass)-> Editar -> Forzar contraseña -> nueva pass 1 vez
              +--(deja la empresa)-> Editar -> Desactivar (no loguea; historial intacto)
```

**Gating:** Solo rol admin y super_admin. admin_cobranza NO accede (ruta
`/admin/cobradores` en la lista soloAdmin). Forzar contraseña: solo
admin/super_admin. Cambio de rol: solo super_admin.

*Archivos: `lib/features/admin/cobradores/cobradores_admin_screen.dart`,
`lib/config/router.dart`, `lib/data/repositories/super_admin_repo.dart`,
`lib/data/utils/edge_functions.dart`,
`lib/features/shared/widgets/password_mode_selector.dart`,
`lib/features/shared/widgets/credenciales_dialog.dart`.*

---

### Solicitudes de aprobación (cola de acciones estructurales)

**Para qué sirve:** Ningún rol salvo el `admin` ejecuta acciones estructurales
de contrato directamente. `admin_usuarios` y `admin_cobranza` envían una
**solicitud de aprobación** que el `admin` revisa desde la pantalla Solicitudes.
Al aprobar, el sistema ejecuta la acción y recién entonces la marca aprobada
(si la ejecución falla, la solicitud queda pendiente y no cambió nada); al
rechazar, registra el motivo y no hay nada que revertir.

**La regla (v0.31.27):** la decisión es por **ACCIÓN**, no por rol —
`requiereAprobacionPara(rol, acción)` en `aprobaciones_provider.dart`. Antes
cada botón preguntaba `esAdminUsuarios ? solicitar : ejecutarDirecto`, o sea
decidía por descarte: todo rol que no fuera `admin_usuarios` caía en la rama
directa. Así el `admin_cobranza` suspendía y cancelaba sin permiso — y en
producción resultó ser quien decidía el 55% de las bajas de contrato. Con la
regla nueva, **un rol nuevo nace pidiendo permiso, no salteándoselo**.

> ⚠️ **La barrera es CLIENTE.** La RLS deja escribir `contratos` a
> `is_admin_or_cobranza()`, así que un dispositivo con una app vieja sigue
> ejecutando directo. Cerrar esa policy es el paso que lo vuelve obligatorio de
> verdad, y va DESPUÉS de confirmar con `app_dispositivos` (0225) que todos
> actualizaron.

**Qué NO entra a la cola:** el **cambio de fecha de pago**, porque es un COBRO
(el cliente paga el puente prorrateado y se emite recibo, con él en el
mostrador). Meterlo en una cola implicaría cobrar y después arriesgar un
rechazo. Sin decidir; nunca se usó (0 eventos, 0 cargos puente).

**Features:**
- 6 tipos: `crear_contrato`, `cancelar_contrato`, `suspender_contrato`, `reactivar_contrato`, `desactivar_cliente`, `cambiar_plan` (0226). Un tipo que la app no conozca degrada a `TipoSolicitud.desconocido`: se ve pero NO se puede aprobar (antes caía a `crear_contrato` y su ejecutor intentaba crear un contrato con datos ajenos).
- **La tarjeta muestra el PEDIDO, no solo la entidad:** para `cambiar_plan`, a qué plan, el precio nuevo con el viejo al lado y desde cuándo (hoy con prorrateo vs próximo ciclo).
- **Se revalida AL APROBAR, no solo al pedir** (v0.31.27): el código de contrato se chequea contra la réplica y contra el server en el momento de escribir. Sin esto se perdieron 10 contratos: dos gestores pedían el mismo número con 18 h de diferencia, el admin aprobaba los dos, y el segundo lo rechazaba el server dejando la solicitud "aprobada" y al cliente sin contrato.
- **Motivo + Notas OBLIGATORIOS al solicitar (v0.31.20):** el diálogo pide un motivo del dropdown (`kMotivosSolicitud`: solicitud del cliente / falta de pago / mudanza / otro) y notas escritas — sin notas el botón "Enviar solicitud" no deja pasar. Se guardan en `solicitudes_accion.datos` (`motivo`/`notas`).
- La tarjeta de la cola (Pendientes e Historial) MUESTRA ese motivo ("Motivo: X — notas"), así el que aprueba decide con el porqué a la vista, sin preguntar por WhatsApp.
- **El motivo viaja al evento REAL:** al aprobar, `suspenderContrato` recibe `motivo` + `notas` y `cancelarContrato` recibe `motivo — notas` → queda en la suspensión/cancelación y en su op_log. Antes se grababa el genérico "Aprobada solicitud de …" (que sigue como fallback para solicitudes viejas sin motivo). Reactivar no lleva motivo en el evento: el suyo queda en la solicitud.
- Anti-spam: no se puede enviar una solicitud duplicada (mismo tipo + entidad pendiente).
- Execute-first-approve-after: la acción se ejecuta ANTES de marcar como aprobada; si falla, la solicitud queda pendiente.
- Vista admin: tabs Pendientes + Historial con badge en la galería de inicio; rechazar exige motivo de rechazo (se muestra en la tarjeta).
- Vista admin_usuarios: solo "Mis solicitudes" (las propias).
- Op_log en crear/aprobar/rechazar.

**Ciclo de uso:** El `admin_usuarios` abre el contrato y toca "Solicitar
suspensión / cancelación / reactivación" (o guarda un contrato nuevo): el
diálogo le exige elegir el motivo y escribir las notas antes de enviar. La
solicitud cae en la cola Pendientes del **admin** con el motivo a la
vista. El que aprueba ejecuta la acción real con ESE motivo (queda en la
suspensión/cancelación y en su historial); si la rechaza, escribe por qué y el
solicitante lo ve en "Mis solicitudes".

**Lifecycle (diagrama):**
```
admin_usuarios -> 'Solicitar …' -> Motivo (dropdown) + Notas  [AMBOS obligatorios]
        |
        v
Cola Pendientes (solo admin) -> la tarjeta muestra el motivo
        |
   +----+---------------------------+
   v                                v
 Aprobar                        Rechazar (motivo de rechazo)
   | (ejecuta primero, marca después)      |
   v                                       v
 Suspender/Cancelar CON ese motivo    'Mis solicitudes': rechazada + porqué
 (queda en el evento y en op_log)
```

**Gating:** solo **admin** aprueba/rechaza. `admin_usuarios` ve "Mis
solicitudes"; `admin_cobranza` **crea** solicitudes pero NO entra a la cola —
`/admin/solicitudes` está en la lista `soloAdmin` del router y su ítem del menú
es `adminOnly`. Que quien pide no pueda aprobar es el punto: si no, se
auto-aprueba.

**Tabla:** `solicitudes_accion` (migración 0193). RLS: lectura admin/cobranza +
propias; inserción por auth.uid(); update solo admin/cobranza; super_admin_all.

*Archivos clave: `lib/data/repositories/solicitudes_repo.dart`,
`lib/data/models/solicitud_accion.dart`,
`lib/features/admin/solicitudes/solicitudes_screen.dart`,
`lib/features/shared/widgets/solicitud_accion_helper.dart`.*

---

### Visitas (registro del cobrador en campo)

**Para qué sirve:** Deja que el cobrador registre el resultado de una visita a
un cliente cuando NO se concretó un cobro (no estaba, prometió pagar, etc.),
para tener trazabilidad de la gestión de campo más allá de los pagos efectivos.

**Features:**
- Registrar visita desde la pestaña Visitas del detalle de cliente con un resultado: Cobrado, No estaba, Sin pago, Promesa de pago, Otro — más notas opcionales.
- Cada visita guarda `cliente_id`, `cobrador_id` (= quién la registró, NOT NULL), resultado, notas y fecha (device-time UTC).
- Atribución por el usuario REAL que la ejecuta: bloqueada al impersonar (un super_admin se atribuiría al tenant System).
- Historial de visitas por cliente (últimas 50, más recientes primero) con el nombre del cobrador resuelto por JOIN a `cobradores`.
- Emite op_log en el `writeTransaction` (1 fila por el alta de la visita).

**Ciclo de uso:** El cobrador llega a la casa del cliente y, si no logra cobrar,
abre el detalle del cliente → pestaña Visitas → "Registrar visita" → elige el
resultado (ej. "Promesa de pago") y deja una nota → queda guardada con su nombre
y fecha. La próxima vez que él o el admin abran ese cliente, ven el historial de
visitas para entender la gestión previa.

**Lifecycle (diagrama):**
```
Cobrador en campo -> No concreta cobro -> Abre cliente > pestaña Visitas
        -> Registrar visita (resultado + nota) -> Queda en historial del cliente
              |
              +--(impersonando)-> bloqueado (se prueba con identidad real del rol)
```

**Gating:** Gate por tenant: aparece solo si el setting
`registrarVisitasHabilitado` está activo. Bloqueado al impersonar (atribución
por usuario real). Lo usan los roles de campo/cobranza desde el detalle de
cliente.

*Archivos: `lib/data/services/visitas_service.dart`,
`lib/features/clientes/cliente_detail_screen.dart`,
`lib/data/repositories/settings_repo.dart`.*

---

### Mapa de clientes

**Para qué sirve:** Muestra los clientes geolocalizados sobre un mapa
(OpenStreetMap, sin API key) con marcadores coloreados según su estado de
cobranza, para que el cobrador planifique la ruta del día y cobre/contacte en el
campo.

**Features:**
- Mapa `flutter_map` con clustering; color/ícono del pin según estado de cobranza (mora > gracia > vence hoy > próxima > fuera de rango > sin deuda).
- Capa calle (OSM) o satélite (Esri) con toggle; cache de tiles offline (`map_tile_cache`).
- Filtro de chips por estado (pendientes / mora / gracia / hoy / próxima); el admin además tiene "Ver todo".
- Filtros multi-select solo para admin: por Cobrador (incluye "Sin cobrador"), Comunidad/Zona y Nodo de red; el cobrador ve TODOS los clientes pero opera bajo RLS.
- Búsqueda de cliente: al seleccionarlo el mapa enfoca y muestra solo su pin.
- Ubicación del dispositivo en vivo (geolocator).
- Trazado de ruta interna al cliente con OSRM offline (`offline_routing_service`): dibuja el camino, encuadra, y muestra distancia y tiempo estimado.
- Abrir navegación externa en Google Maps hacia las coordenadas del cliente.
- Acciones desde el marcador: Llamar, Ruta, Ver cliente, y cambio de fecha de pago según permisos.
- El técnico / admin_tickets NO ven cobranza ni "Pagar"/"Ver cliente" (su SQLite no tiene esas tablas).

**Ciclo de uso:** El cobrador abre Mapa al empezar el día → filtra por "mora"
para ver primero a los morosos → toca un pin para ver al cliente, lo llama o
traza la ruta hasta él → al llegar usa "Ver cliente" para cobrar. El admin entra
al mismo mapa pero puede filtrar por cobrador/zona/nodo y usar "Ver todo" para
auditar la cobertura geográfica.

**Lifecycle (diagrama):**
```
Abre Mapa -> Filtra por estado (ej. mora) -> Toca un pin (cliente)
        -> Llamar / Trazar ruta / Ver cliente
              |
              +--(admin)-> filtros por cobrador/zona/nodo + 'Ver todo'
              +--(ruta)-> OSRM offline dibuja camino + distancia/tiempo
                          ó abre Google Maps externo
```

**Gating:** Siempre activo para los roles con shell de mapa: cobrador (`/mapa`),
tecnico (`/tecnico/mapa`), admin_tickets (`/admin-tickets/mapa`) y admin
(`/admin/mapa`). La cobranza en el mapa se oculta para técnico/admin_tickets.
Filtros multi-select solo para admin.

*Archivos: `lib/features/mapa/mapa_screen.dart`,
`lib/features/mapa/servicios/offline_routing_service.dart`,
`lib/data/services/map_tile_cache.dart`,
`lib/features/shared/widgets/mapa_widgets_compartidos.dart`,
`lib/data/utils/cuota_estado_visual.dart`, `lib/config/router.dart`.*

---

### Geografía (departamentos / municipios / comunidades)

**Para qué sirve:** CRUD del catálogo geográfico jerárquico del tenant
(departamento → municipio → comunidad) que se usa para ubicar a los clientes y
filtrar por zona en el mapa y los reportes.

**Features:**
- Árbol anidado con `ExpansionTile`: tocar un departamento revela sus municipios; tocar un municipio revela sus comunidades.
- Alta, edición y borrado de departamentos, municipios y comunidades (cada nivel hereda el `tenant_id` del padre).
- Borrado seguro: solo permite eliminar si no está en uso (chequea hijos/clientes por FK) — si no, muestra "está en uso (N)".
- Catálogo per-tenant: el SELECT filtra explícito por `tenant_id` (evita la unión con la geo de System al impersonar).
- Historial (op_log) por cada fila de geografía.
- Crece con el uso: arranca vacío, el admin solo agrega lo que necesita.

**Ciclo de uso:** Al configurar el tenant el admin entra a Geografía →
"Departamento" (ej. Managua) → dentro agrega un municipio → dentro agrega una
comunidad/barrio. Después, al dar de alta clientes, esas comunidades aparecen
para asignar la ubicación, y el mapa/reportes permiten filtrar por ellas. Si una
comunidad ya no se usa la puede borrar (solo si no tiene clientes).

**Lifecycle (diagrama):**
```
Crear Departamento -> Agregar Municipio -> Agregar Comunidad
        -> Disponible para asignar a clientes -> Filtro por zona en Mapa/Reportes
              |
              +--(borrar)-> solo si no tiene hijos/clientes; si está en uso -> bloqueado
```

**Gating:** Solo rol admin y super_admin. admin_cobranza NO accede (ruta
`/admin/geografia` en soloAdmin). Disponible en todos los tenants (no es módulo
opcional).

*Archivos: `lib/features/admin/geografia/geografia_admin_screen.dart`,
`lib/config/router.dart`.*

---

### Planes

**Para qué sirve:** CRUD de los planes de servicio del tenant (nombre, tipo
internet/tv/combo, precio mensual). Son la base de la facturación: sin al menos
un plan no se pueden crear contratos.

**Features:**
- Lista de planes con precio formateado en córdobas y conteo de contratos activos por plan; ordenada por activo/precio.
- Alta y edición: nombre, tipo (Internet / TV / Combo) y precio mensual.
- Activar/desactivar plan: un plan inactivo no aparece al crear nuevos contratos (los existentes siguen).
- Historial de cambios por plan (op_log) — el precio es dato de dinero, por eso se audita.
- Mensaje de estado vacío que obliga a crear al menos un plan antes de asignar contratos.

**Ciclo de uso:** Al montar el tenant el admin entra a Planes → "Nuevo plan"
(ej. "Internet 10MB", tipo Internet, C$500) → queda disponible. Cuando crea un
contrato para un cliente elige uno de estos planes y su `precio_mensual` define
la cuota. Si sube de precio edita el plan; si deja de ofrecerlo lo desactiva
para que no salga en contratos nuevos.

**Lifecycle (diagrama):**
```
Crear Plan (nombre/tipo/precio) -> Disponible al crear contrato
        -> Define la cuota mensual del cliente
              |
              +--(sube precio)-> Editar plan
              +--(deja de ofrecerlo)-> Desactivar (no sale en contratos nuevos;
                                        los vigentes siguen)
```

**Gating:** Solo rol admin y super_admin. admin_cobranza NO accede (ruta
`/admin/planes` en soloAdmin). Disponible en todos los tenants (no es módulo
opcional).

*Archivos: `lib/features/admin/planes/planes_admin_screen.dart`,
`lib/config/router.dart`.*

---

## Módulos opcionales (gate por tenant)

### Inventario

**Para qué sirve:** Lleva el stock del ISP de cuna a tumba: catálogo de
productos, ubicaciones (bodega y custodia de cada técnico), seriales
individuales y un ledger de movimientos. El stock no es un contador editable: se
DERIVA (serializado = COUNT de seriales en_stock; granel = Σ destino − Σ origen).

**Features:**
- Pantalla con pestañas: Existencias (stock derivado por producto/ubicación), Equipos (seriales individuales cuna-a-tumba), Productos, Categorías, Ubicaciones (bodega/custodia), Proveedores.
- Productos serializados (seriales únicos con ciclo de estado) vs a granel (cantidad).
- Ciclo de estado del serial con guard server (`trg_inv_seriales_guard_transicion`): en_stock → instalado, "baja" es terminal, no se transfiere un instalado sin pasar por stock.
- Ledger append-only de movimientos (`inv_movimientos`) con `ocurrido_en` en UTC; el stock resultante se recalcula y avisa si queda negativo.
- Pantalla aparte "equipos en baja" (`equipos_en_baja.dart`).
- Alerta de stock mínimo (`inventario_alerta_provider.dart`).
- Borrado bloqueado si el producto/ubicación tiene seriales o movimientos asociados.
- Historial por serial vía op_log (`HistorialOpLog` entidad `inv_seriales`).
- Consumido por Tickets: el técnico descuenta materiales de su custodia y los instala en el cliente.

**Ciclo de uso:** El admin crea categorías, proveedores, ubicaciones y
productos. Da de alta seriales (en_stock) o registra entradas a granel. Cuando
un técnico resuelve un ticket consume materiales de SU custodia: eso descuenta
inventario y deja el equipo "instalado" en el cliente. Las existencias se ven
siempre derivadas de los seriales/movimientos, nunca como un número editado a
mano. Equipos dañados se dan de baja (estado terminal).

**Lifecycle (diagrama):**
```
Crear catálogo (categorías/proveedores/productos/ubicaciones)
      |
      v
Alta de seriales (en_stock)  ->  Existencias se derivan solas
      |
      v
Mover a custodia del técnico  ->  Técnico consume en un ticket
      |
      v
Equipo queda 'instalado' en el cliente
      |
      +--(dañado)-> Baja (estado terminal, va a 'equipos en baja')
```

**Gating:** Módulo opcional — gate por tenant ("inventario": menú admin + router
+ RLS). Sync admin-only: NO baja al cobrador; el técnico baja SOLO su custodia.
No accesible para cobrador.

*Archivos: `lib/features/admin/inventario/inventario_v2_screen.dart` (vista operativa:
tabs Equipos/Existencias), `ficha_equipo_screen.dart` (detalle+acciones del serial),
`inventario_catalogo_screen.dart` (catálogo/config), `inv_seriales_acciones.dart`
(write-paths de equipo), `inventario_oplog.dart` (op_log), `inventario_comun.dart`
(estado), `equipos_en_baja.dart` (baja cross-módulo),
`lib/data/providers/inventario_alerta_provider.dart`,
`lib/config/router.dart` (`/admin/inventario` + `/equipo/:id` + `/catalogo`, gate por módulo),
`ARQUITECTURA.md §3 Inventario` (Receta R21).*

---

### Tickets (con rol Técnico)

**Para qué sirve:** El ciclo de trabajo de campo del ISP: el admin crea y asigna
un ticket, el técnico lo resuelve offline (avanza/pausa/resuelve, checklist,
fotos, comentarios, consume materiales de su custodia) y el admin lo cierra.
Incluye un SLA con semáforo que tickea offline y se pausa en espera.

**Features:**
- Admin: crear ticket, lista filtrable, detalle completo, administrar tipos de ticket y su SLA.
- Técnico: shell móvil-first (Mis tickets · Mapa · Perfil); "Mis tickets" ya viene acotado al técnico por el bucket de sync, filtro Activos/Cerrados.
- 8 estados con matriz de transiciones `kTransicionesTicket` (abierto, asignado, en_progreso, en_espera, resuelto, reabierto, cerrado, cancelado) — espejo del trigger server.
- SLA: `slaHorasEfectivas` (mín entre tipo y prioridad) + countdown que tickea offline; se pausa exacto en "en_espera" (`segundos_pausado`, server-side); `created_at` parseado con `parseTicketWallClock`.
- Adjuntos/fotos, consumo de materiales del inventario (→ `inv_movimientos` "consumo" + serial "instalado"), checklist y comentarios.
- Correlativo de ticket provisorio offline, re-asignado por el server en conflicto.
- Eventos del ticket generados automáticamente en el server.
- Sync del técnico SOLO sus tickets/clientes/custodia — cero dinero.
- Historial vía op_log (entidad `tickets`, con sub-entidades adjuntos/materiales/checklist/reasignación).
- **Integración con cobranza (Fase 1, 0172):** el tipo de ticket lleva un `efecto` (ninguno/instalacion/corte/reconexion) y el ticket se vincula a un `contrato_id`. Eso deriva 2 COLAS para el admin (`colas_servicio_provider` → `ColasServicioPanel`, arriba de la lista de tickets): "cortes ejecutados → falta suspender" y "deuda saldada → falta reactivar". El panel solo RECUERDA y navega al contrato; el cobro sigue en cobranza y suspender/reactivar siguen MANUALES (CERO trigger de plata). La orden de corte se genera desde la lista de mora ("Orden de corte" → form pre-cargado con el cliente). Taxonomía de DOS PUERTAS: órdenes de trabajo físicas (instalación/corte/reconexión) por ticket; mora/anexos/descuentos por cobranza pura. El automatismo por trigger (cerrar ticket suspende/reactiva solo) es FASE 2 (diferida).
- **Cobro desde el ticket (0173):** el tipo de ticket lleva `precio` (>0 = cobrable); en el detalle de un ticket resuelto/cerrado, admin/admin_cobranza (no impersonando) usa **Generar cobro** → diálogo de cobro puntual precargado (monto = precio del tipo, concepto = nombre del tipo) → crea una cuota manual ligada por `cuotas.ticket_id` → recibo 'Ticket #N' sin línea de Período; anti-doble-cobro (un ticket con cuota ligada no re-ofrece el botón) y chip 'Cobrado' en el detalle.
- **Rol `admin_tickets` VIVO (0e72fec, 2026-06-22):** se ofrece en el alta/edición de personal cuando el tenant tiene el módulo tickets; shell propio (`admin_tickets_shell.dart`, rutas `/admin-tickets/*`) y bucket de sync `por_admin_tickets` (0 usuarios asignados en prod a hoy, pero disponible).

**Ciclo de uso:** El admin crea un ticket eligiendo tipo, prioridad y cliente, y
se lo asigna a un técnico. El técnico lo ve en "Mis tickets", lo avanza a
en_progreso, puede pausarlo (en_espera, congela el SLA), sube fotos, marca el
checklist, consume materiales de su custodia (descuenta inventario e instala el
equipo en el cliente) y lo deja resuelto. El admin revisa y lo cierra; si algo
quedó mal, lo reabre.

**Lifecycle (diagrama):**
```
Admin crea ticket  ->  Asigna a técnico  ->  Técnico: en_progreso
                                              |
                                              v
                              Checklist + fotos + materiales (descuenta stock)
                                              |
                                              v
                              Resuelto  ->  Admin cierra
   +--(pausa)-> en_espera (SLA congelado)        +--(reabre)-> reabierto
   +--(no aplica / se anula)-> cancelado
```

**Gating:** Módulo opcional — gate por tenant ("tickets": menú + router + RLS).
El rol "tecnico" vive en su propio shell (`/tecnico/*`). Las transiciones del
técnico se prueban con la identidad REAL del técnico, NO impersonando.

*Archivos: `lib/features/admin/tickets/tickets_list_screen.dart`,
`lib/features/admin/tickets/ticket_form_screen.dart`,
`lib/features/admin/tickets/ticket_detail_screen.dart`,
`lib/features/admin/tickets/ticket_tipos_screen.dart`,
`lib/features/admin/tickets/ticket_adjuntos_widget.dart`,
`lib/features/admin/tickets/ticket_materiales_widget.dart`,
`lib/features/admin/tickets/admin_tickets_shell.dart`,
`lib/features/admin/tickets/colas_servicio_panel.dart`,
`lib/data/providers/colas_servicio_provider.dart`,
`lib/features/tecnico/tecnico_shell.dart`,
`lib/features/tecnico/mis_tickets_screen.dart`,
`lib/data/utils/ticket_sla.dart`, `lib/config/router.dart`.*

---

### Incidentes (cortes masivos / outages)

**Para qué sirve:** Registrar un corte masivo (outage) acotado a un alcance de
la red (un nodo, hub, puerto o general) y agrupar bajo él los clientes y tickets
afectados, en vez de abrir un ticket por cliente. Los afectados se DERIVAN de la
topología de red.

**Features:**
- Lista de incidentes con filtro Abiertos/Resueltos y badge de estado + alcance.
- Crear incidente con título y alcance: nodo | hub | puerto | general (CHECK `un_solo_nivel` server).
- Detalle: header con estado/alcance/fechas, clientes afectados DERIVADOS por JOIN de la red (`red_nodos`/`hubs`/`puertos`), tickets agrupados (`tickets.incidente_id`) e historial.
- Snapshot del alcance en `alcance_label` (texto fijo aunque cambie la red después).
- Resolver el incidente (marca fin = device-time UTC, alimenta el change-log).
- Historial vía op_log.

**Ciclo de uso:** Cuando se cae un nodo/hub/puerto y deja sin servicio a muchos
clientes a la vez, el admin crea un incidente eligiendo el alcance en la
topología de red. La app deriva automáticamente qué clientes quedan afectados
(por su puerto/hub/nodo) y agrupa los tickets relacionados. Cuando el servicio
vuelve, el admin resuelve el incidente y queda registrado con su fecha de fin.

**Lifecycle (diagrama):**
```
Se cae un nodo/hub/puerto
      |
      v
Admin crea incidente  ->  elige alcance (nodo|hub|puerto|general)
      |
      v
Afectados se DERIVAN de la red  ->  tickets se agrupan bajo el incidente
      |
      v
Servicio restablecido  ->  Admin resuelve (marca fin)
```

**Gating:** Módulo opcional — comparte el mismo gate de tenant que Tickets
("tickets": menú + router + RLS). Depende del módulo Red para derivar afectados.

*Archivos: `lib/features/admin/incidentes/incidentes_screen.dart`,
`lib/features/admin/incidentes/incidente_detail_screen.dart`,
`lib/config/router.dart` (`/admin/incidentes`, gateado junto con `/admin/tickets`),
`ARQUITECTURA.md §3 Tickets + Técnico + Incidentes`.*

---

### Red / Topología (Nodo → Hub → Puerto)

**Para qué sirve:** CRUD de la topología física de la red del ISP en tres
niveles anidados (Nodo → Hub → Puerto) para ubicar a cada cliente en la red
asignándole un puerto. Es la base sobre la que Incidentes deriva los clientes
afectados de un corte.

**Features:**
- Árbol de `ExpansionTile` anidado: tocar un nodo revela sus hubs, tocar un hub revela sus puertos; cada nivel se crea inline.
- Nodo: nombre + tipo (fibra/wireless/híbrido) + notas + lat/lng (con picker de mapa).
- Hub y Puerto: nombre + notas.
- Asignación cliente ↔ puerto desde el form de cliente (`red_picker.dart`).
- Editar/Eliminar por fila; borrado bloqueado si está en uso (nodo con hubs, hub con puertos, puerto con clientes asignados).
- FK `clientes.puerto_id` es ON DELETE SET NULL: el borrado del puerto verifica a mano que no haya clientes.
- Historial por fila vía op_log (entidad `red_nodos`/`red_hubs`/`red_puertos`).
- Filtro explícito por tenant en el SELECT (la SQLite del super_admin puede mezclar System + tenant impersonado).
- Baja a todos los roles (el cobrador necesita ver el puerto del cliente).

**Ciclo de uso:** El admin arma la topología creando nodos (con su ubicación en
el mapa), dentro de cada nodo sus hubs y dentro de cada hub sus puertos.
Después, al dar de alta o editar un cliente, le asigna un puerto. Esa asignación
permite que Incidentes sepa, ante un corte de un nodo/hub/puerto, qué clientes
quedan afectados; y le da al cobrador la ubicación del cliente en la red.

**Lifecycle (diagrama):**
```
Crear Nodo (tipo + lat/lng)
      |
      v
Agregar Hub dentro del nodo
      |
      v
Agregar Puerto dentro del hub
      |
      v
Asignar puerto a un cliente (red_picker)
      |
      +--> alimenta Incidentes (afectados) y la ficha del cliente
```

**Gating:** Según el código, Red es parte del módulo de cobranza BASE, NO un
módulo opcional con gate por tenant — siempre activo (per-tenant), accesible por
admin/admin_cobranza. Se documenta acá por ser el cimiento de Incidentes. El
cobrador solo consume el puerto del cliente.

*Archivos: `lib/features/admin/red/red_admin_screen.dart`,
`lib/features/admin/clientes/widgets/red_picker.dart`,
`lib/config/router.dart` (`/admin/red`), `ARQUITECTURA.md §3 Red`.*

---

## Plataforma y transversal

### Multi-tenant + Super-admin

**Para qué sirve:** Panel del dueño del SaaS (Rubén) para administrar todos los
ISPs (tenants): crearlos de un click, prender/apagar módulos opcionales por
tenant, gestionar sus miembros e IMPERSONAR a un tenant para operar su panel
admin como si fuera de adentro.

**Features:**
- Lista de tenants con su estado y miembros.
- Crear tenant completo de un click (Edge `crear-tenant`): inserta el row, habilita módulos base por trigger + extras vía `set_tenant_modulo`, y crea el admin del ISP — con email (invite) o sin email (password generada server-side para copiar).
- Detalle del tenant: toggles de módulos opcionales (inventario, tickets, avisos, pagos, dashboard) vía RPC `set_tenant_modulo`.
- Gestión de miembros: invitar admin/cobrador, ver detalle, forzar contraseña, cambiar email, reenviar invitación, eliminar/desactivar.
- Impersonación: "Entrar" a un tenant escribe `super_admin_impersonation` + reconecta PowerSync (re-evalúa sync rules → baja la data de ESE tenant); "Salir" borra el row y vuelve a System. Banner visible mientras dura.
- Bypassa RLS con `is_super_admin()`; las acciones atribuibles al usuario (cobros, visitas) están bloqueadas al impersonar por diseño.

**Ciclo de uso:** El super_admin entra a `/super/tenants`, crea un ISP nuevo
(nombre + admin, con o sin email) y comparte las credenciales. Luego puede
prender módulos opcionales, invitarle cobradores, o "Entrar" (impersonar) para
configurarlo desde adentro como admin. Cuando termina, "Sale" de la
impersonación y vuelve a su panel SaaS. Toda escritura impersonando funciona
porque la policy `super_admin_all` lo permite.

**Lifecycle (diagrama):**
```
Login super_admin -> /super/tenants -> Crear tenant (admin + módulos)
        -> comparte credenciales
              |
              +--> Entrar (impersonar) -> opera /admin del ISP
                        -> Salir -> vuelve a /super/tenants
```

**Gating:** Solo rol super_admin (todo `/super/*` gateado en `router.dart`). El
tenant System no se puede impersonar.

*Archivos: `lib/features/super_admin/tenants_list_screen.dart`,
`lib/features/super_admin/tenant_modulos_screen.dart`,
`lib/features/super_admin/miembro_detalle_screen.dart`,
`lib/features/super_admin/super_shell.dart`,
`lib/data/services/impersonation_service.dart`,
`lib/data/repositories/super_admin_repo.dart`,
`lib/features/shared/widgets/impersonation_banner.dart`,
`supabase/functions/crear-tenant/index.ts`, `lib/config/router.dart`.*

---

### Auth / Onboarding (sin email)

**Para qué sirve:** Manejar el login y el alta de usuarios en un modelo SaaS B2B
SIN signup público: cada usuario lo crea el super_admin (tenants/admins) o el
admin (cobradores), y la contraseña se entrega por canal seguro (WhatsApp / en
persona) cuando no hay email.

**Features:**
- `LoginScreen`: iniciar sesión + recuperar contraseña (sin signup público).
- Onboarding por email (invite/recovery): el link logea automático y desvía a `SetPasswordScreen` para fijar la nueva contraseña.
- Onboarding SIN email: Edge Functions (`crear-tenant`, `invitar-cobrador`, `reenviar-invitacion`, `forzar-password-cobrador`) generan una password server-side que se copia y se pasa por WhatsApp; el usuario logea directo.
- `SetPasswordScreen`: fija contraseña nueva vía `auth.updateUser` (la sesión activa autoriza, sin password viejo).
- Resolución de rol post-login desde la tabla `cobradores` local + sync gate que espera a que PowerSync baje la data antes de mostrar la pantalla por rol.
- Cambiar contraseña propia desde Perfil; cambiar email de un miembro (super_admin, Edge `cambiar-email-cobrador`).

**Ciclo de uso:** El admin/super crea al usuario eligiendo "con email" (manda
link de invite) o "sin email" (genera password para copiar). El usuario logea:
si entró por link va a `SetPasswordScreen` a fijar su clave; si le pasaron la
password generada entra directo. El router resuelve el rol y, tras el sync gate,
lo lleva a su panel (cobrador / admin / técnico / super). El olvido de clave se
resuelve con "Recuperar contraseña" o forzar-password.

**Lifecycle (diagrama):**
```
Admin crea usuario -> ¿con email?
   |
   +--(sí)-> link de invite -> login auto -> SetPassword -> panel por rol
   +--(no)-> password generada -> la pasa por WhatsApp -> Login -> panel por rol
```

**Gating:** Login público; el alta de usuarios está gateada por rol (super_admin
crea tenants/admins; admin invita cobradores de su tenant). Sin signup público.

*Archivos: `lib/features/auth/login_screen.dart`,
`lib/features/auth/set_password_screen.dart`,
`lib/features/auth/auth_flow_provider.dart`,
`lib/features/auth/cambiar_password_dialog.dart`,
`lib/features/shared/widgets/sync_gate_screen.dart`,
`supabase/functions/invitar-cobrador/index.ts`,
`supabase/functions/forzar-password-cobrador/index.ts`,
`supabase/functions/reenviar-invitacion/index.ts`,
`supabase/functions/cambiar-email-cobrador/index.ts`.*

---

### Settings / Configuración

**Para qué sirve:** Panel donde el admin del ISP configura su empresa, reglas de
cobranza, métodos de pago y formato de recibo; el super_admin tiene una pestaña
"Avanzado" extra para togglear pantallas opcionales y settings que consumen
recursos del SaaS.

**Features:**
- Settings agrupados en pestañas: Empresa, Cobranza, Pagos, Recibos (base) + Avanzado y Operaciones (solo super_admin).
- Toggles padre que revelan campos hijos (reveal animado); algunas settings son editables por admin_cobranza (ej. tasa USD).
- Datos de empresa (nombre, logo, WhatsApp), días de gracia/visibles, tasa de cambio, plantillas de mensajes, layout del recibo (editor).
- Pestaña Avanzado (super_admin): visibilidad de secciones del dashboard, pantallas opcionales del tenant, link a "Campos del historial" (op_log).
- Pestaña Operaciones (super_admin): corrección de errores de carga de datos.
- Persistencia en tabla `settings` (sincronizada por PowerSync); cada cambio emite op_log.

**Ciclo de uso:** El admin entra a `/admin/settings`, elige una pestaña (ej.
Empresa), edita un valor (nombre, logo, tasa de cambio) y guarda; el cambio se
persiste en `settings`, se sincroniza a todos los dispositivos del tenant y
queda registrado en op_log. El super_admin, además, usa Avanzado para
prender/apagar pantallas opcionales o ajustar la visibilidad del dashboard.

**Lifecycle (diagrama):**
```
Admin -> /admin/settings -> elige pestaña -> edita valor -> Guarda
        -> settings + op_log -> sync a dispositivos
              |
              +--(super_admin)-> pestaña Avanzado: toggles de pantallas/dashboard
```

**Gating:** Por rol: admin ve todo lo de su tenant; admin_cobranza solo settings
marcadas `editable_por='admin_cobranza'`; pestañas Avanzado y Operaciones solo
super_admin. La pantalla en sí es admin-only (no cobrador).

*Archivos: `lib/features/admin/settings/settings_admin_screen.dart`,
`lib/features/admin/settings/settings_groups.dart`,
`lib/features/admin/settings/recibo_layout_editor.dart`,
`lib/features/admin/settings/data_ops_screen.dart`,
`lib/data/repositories/settings_repo.dart`.*

---

### Historial / Change-log (op_log unificado)

**Para qué sirve:** Registro append-only de cada cambio que hace un usuario
sobre una entidad (cliente, contrato, cuota, pago, setting, etc.). Es el ÚNICO
historial de la app (el `audit_log` forense se eliminó en 0140) y se ve desde la
pantalla de cada objeto con el MISMO componente.

**Features:**
- `HistorialOpLog`: widget reutilizable que se instancia con `(entidad, entidadId)` y muestra la vida completa del objeto (sin LIMIT), ordenada por device-time desc.
- Una fila de op_log por cada objeto afectado por una intención; las filas de la misma intención comparten `op_id`/`actor`/`ocurrido_en`.
- Lo emiten los repos/forms dentro de su `writeTransaction` (pagos_repo, contratos_repo, settings_repo, etiquetas, visitas, etc.).
- Allowlist de campos visibles por entidad (`op_log_campos.dart`), gestionable por el super_admin en "Campos del historial".
- Solo admin/admin_cobranza/super sincronizan op_log (cobrador/técnico ven "Sin movimientos"); super_admin lee por sync rules del bucket `impersonated_tenant`.

**Ciclo de uso:** Un usuario edita una entidad (ej. cambia el monto de un
contrato o registra un cobro). El repo, dentro de su `writeTransaction`, inserta
una fila de op_log por cada objeto tocado, con la acción y el diff. Más tarde,
cualquier admin abre el detalle de ese objeto y el `HistorialOpLog` muestra toda
la traza de cambios. El super_admin decide qué campos son visibles desde "Campos
del historial".

**Lifecycle (diagrama):**
```
Usuario edita entidad -> repo escribe op_log (1 fila por objeto) -> sync
              |
              +--> Admin abre detalle -> HistorialOpLog muestra la traza
```

**Gating:** Lectura por rol: solo admin/admin_cobranza/super_admin (RLS
`op_log_read` + sync rules). La pantalla "Campos del historial" es
super_admin-only.

*Archivos: `lib/features/shared/widgets/historial_op_log.dart`,
`lib/features/historial/historial_screen.dart`, `lib/data/utils/op_log.dart`,
`lib/data/utils/op_log_campos.dart`,
`lib/features/admin/settings/op_log_campos_screen.dart`.*

---

### Centro de cobranza

**Para qué sirve:** El hub operativo del admin: un tablero read-only que junta
en UNA pantalla lo accionable de HOY — métricas del día arriba y las colas de
Cobrar / Servicio / Créditos abajo — para responder "qué atiendo hoy" sin
recorrer módulo por módulo. NO toca dinero ni estado: cada card solo NAVEGA a
la pantalla que ya sabe hacerlo (Avisos o el detalle del contrato).

**Features:**
- Métricas del día: **Vencen hoy** (total cobrable), **En mora**, **A suspender** ("ya cortados", conteo) y **A favor** (créditos disponibles). Calculadas SIN LIMIT (las listas muestran los 50 mayores; la métrica suma TODO).
- Cola **Cobrar** (vencen hoy · gracia · mora): gracia/mora reusan los providers de Avisos y su card lleva a "Ver en Avisos" (solo si el tenant tiene Avisos habilitado; sin el toggle esas filas no se muestran).
- Cola **Servicio**, derivada de tickets con `efecto = corte` (JOIN `ticket_tipos`): **"Ya cortados — falta suspender"** (orden de corte ejecutada, contrato aún activo) y **"Deuda saldada — reactivar"** (suspendido que ya no debe); "Ver contrato" por fila.
- Con el módulo tickets OFF las colas de Servicio quedan VACÍAS (se alimentan de órdenes de corte) → la suspensión pasa a ser MANUAL desde el detalle del contrato (sin crashes: las queries devuelven vacío).
- **Créditos sin aplicar**: clientes con saldo a favor disponible, para recordar aplicarlo o devolverlo.
- **Sin acción en lote** (eliminada 2026-08-09, decisión de Rubén): existió un "Suspender todos" / "Reactivar todos" que cortaba decenas de contratos con una confirmación. Se fue por dos razones: cada corte es individual sin importar cuántos sean y el admin los tiene que ver de a uno; y bypasseaba el circuito de aprobación de v0.31.28 — el mismo rol no podía suspender UN contrato pero sí treinta, con motivo fijo y sin ver la deuda que quedaba cobrable. Cada fila de la cola lleva al contrato.

**Ciclo de uso:** El admin abre el Centro al empezar el día y ve el pantallazo:
cuánto vence hoy, cuánta mora hay, cuántos cortes ejecutados faltan suspender y
qué créditos siguen sin aplicar. Baja a la cola que toque: de "Cobrar" salta a
Avisos para notificar/cobrar; de "Servicio" toca "Ver contrato" y dispara
suspender/reactivar con la UI existente del contrato, de a uno. El Centro solo
le dice QUÉ atender y lo lleva ahí — la acción vive en el módulo de siempre.

**Lifecycle (diagrama):**
```
Admin -> /admin/centro-cobranza -> métricas (vencen hoy / mora / a suspender / a favor)
      |
      +--> Cobrar (vencen hoy · gracia · mora) -> 'Ver en Avisos' -> notificar/cobrar
      +--> Servicio: 'Ya cortados — falta suspender' / 'Deuda saldada — reactivar'
      |         -> 'Ver contrato' -> suspender/reactivar (UI del contrato, de a UNO)
      +--> Créditos sin aplicar -> 'Ver contrato' -> aplicar crédito
```

**Gating:** Por rol admin/admin_cobranza (ruta `/admin/centro-cobranza`, en la
sub-galería "Cobranza"). Para admin_cobranza requiere sync rules **v17**
(tickets en su bucket — sin eso las colas de Servicio no bajan). Las filas de
gracia/mora dependen de Avisos habilitado. **Fase 2 roles:** admin_cobranza ve
TODO (métricas + colas) — los montos son PENDIENTES, no recaudado;
suspender/reactivar es recuperación de cartera, y desde v0.31.28 pasa por el
circuito de aprobación (el Centro solo navega al contrato).

*Archivos: `lib/features/admin/avisos/centro_cobranza_screen.dart`,
`lib/features/shared/widgets/cola_card.dart`,
`lib/data/providers/centro_cobranza_providers.dart`,
`lib/data/providers/colas_servicio_provider.dart`,
`lib/config/router.dart` (`/admin/centro-cobranza`).*

---

### Notificaciones / WhatsApp

**Para qué sirve:** Avisar a los clientes en gracia (próximos a corte) o en
mora. Hoy funciona vía deep link `wa.me` manual (gratis, lo dispara el admin);
la WhatsApp Cloud API de Meta (envío automático por cron) está construida pero
DORMIDA hasta el setup de Meta.

**Features:**
- Pantalla Avisos: lista de clientes en gracia y en mora (reusa el SQL canónico de Cobros con filtros gracia/mora).
- Botón "WhatsApp" por cliente: abre `https://wa.me/<numero>?text=...` con mensaje prellenado desde plantilla editable (`ExternalActions.whatsapp`).
- Flujo guiado "Notificar a todos" (uno por uno por `wa.me`).
- WhatsApp Cloud API (Edge `whatsapp-enviar`): modo "uno" (probar con un cliente, super_admin) y modo "lote" (cron por tenant según hora configurada); registra envíos en `whatsapp_envios` — DORMIDA, no probada contra Meta.
- Token de la API server-only (`whatsapp-set-token` → tabla `whatsapp_credenciales`, super_admin); la UI solo ve "configurado".

**Ciclo de uso:** El admin abre `/admin/avisos`, ve los clientes en gracia o
mora y toca "WhatsApp" en uno (o usa "Notificar a todos"); se abre WhatsApp con
el mensaje prellenado desde la plantilla y el admin lo envía manualmente. (Cuando
se active la API de Meta: el super_admin carga el token, prueba con un cliente y
el cron manda los avisos solo, según la hora y frecuencia configuradas por
tenant.)

**Lifecycle (diagrama):**
```
Admin -> /admin/avisos -> clientes en gracia/mora -> toca 'WhatsApp'
        -> wa.me con texto prellenado -> envía a mano
              |
              +--(API Meta dormida)-> cron -> whatsapp-enviar lote -> whatsapp_envios
```

**Gating:** Pantalla Avisos gateada por tenant (`cobranza.avisos_habilitado`,
super_admin) y por rol (admin/admin_cobranza). Botón WhatsApp por
`cobranza.notif_whatsapp_habilitado`. Modo API: token y modo lo configura solo
el super_admin.

*Archivos: `lib/features/admin/avisos/avisos_screen.dart`,
`lib/data/services/external_actions.dart`,
`supabase/functions/whatsapp-enviar/index.ts`,
`supabase/functions/whatsapp-set-token/index.ts`,
`lib/features/admin/settings/settings_groups.dart`.*

---

### Reportes / Arqueo / Dashboard

**Para qué sirve:** Darle al admin la foto del negocio: un Dashboard (Resumen)
con KPIs en vivo del mes, y un módulo de Reportes que exporta PDF/Excel (arqueo
de caja, cobros, por cobrador, mora, fiscal, clientes, etc.) para cuadrar la
caja y rendir cuentas.

**Features:**
- Dashboard: KPIs de cobros, proyección, recuperación, sparkline 7 días, operativo, top cobradores y distribución de cuotas — cada sección toggleable por tenant (`dashboard.*_visible`, super_admin).
- Reportes descargables con rango de fechas (default mes actual, filtra por `fecha_pago`): arqueo, cobros, por cobrador, mora, fiscal, anulaciones, eficiencia, clientes, inactivos.
- Exporta a PDF (con logo del tenant) y a Excel.
- Arqueo de caja: `recaudado_caja` = SUM(`pagos.monto_cordobas` no anulados) − devoluciones; consistencia cross-pantalla (misma fórmula canónica en dashboard/arqueo/fiscal/por-cobrador).
- Agrupa la reportería por `pagos.cobrador_id` (quién cobró), nunca por el cobrador asignado del cliente.

**Ciclo de uso:** El admin abre `/admin/resumen` y ve los KPIs del mes en vivo
(cobros, mora, proyección). Para cerrar caja o rendir, va a `/admin/reportes`,
elige un rango de fechas y descarga el arqueo (o cobros/por-cobrador/fiscal) en
PDF o Excel; el documento sale con el logo del ISP y los totales calculados con
la fórmula canónica.

**Lifecycle (diagrama):**
```
Admin -> /admin/resumen -> KPIs del mes en vivo
      -> /admin/reportes -> elige rango -> descarga PDF/Excel
                            (arqueo, cobros, por cobrador, fiscal...)
```

**Gating:** Por rol admin/admin_cobranza (no cobrador). Secciones del dashboard
toggleables por tenant (super_admin). **Fase 2 roles (2026-07-19):**
`admin_cobranza` no ve secciones/reportes de dinero RECAUDADO (CobrosKPIs,
ConsultarPeriodo, Proyeccion, Sparkline, TopCobradores, 5 reportes de dinero,
RecaudacionMensual, CobradoresMes); sí ve lo operativo (Recuperacion%,
Operativo, Distribucion, eficiencia, mora, clientes, padrón, MoraComunidad,
PlanesPopulares). Reportes accesibles a admin del tenant.

*Archivos: `lib/features/admin/dashboard/dashboard_admin_screen.dart`,
`lib/data/providers/dashboard_providers.dart`,
`lib/features/admin/reportes/reportes_admin_screen.dart`,
`lib/features/admin/reportes/arqueo_calculo.dart`,
`lib/features/admin/reportes/pdf/reporte_arqueo_pdf.dart`,
`lib/features/admin/reportes/excel/reporte_excel.dart`.*

---

### Etiquetas de cliente

**Para qué sirve:** Catálogo per-tenant de etiquetas (nombre + color + icono)
para clasificar clientes (ej. "VIP", "Conflictivo", "Moroso"). Acá solo se
DEFINE el catálogo; las etiquetas se asignan a clientes desde el detalle del
cliente.

**Features:**
- CRUD del catálogo de etiquetas (crear/editar/borrar/ordenar), con color de paleta e icono.
- Muestra el conteo de usos por etiqueta (cuántos clientes la tienen).
- `EtiquetaChip` reutilizable para renderizarlas en listas y detalle.
- Asignación de etiquetas a clientes desde el detalle del cliente (no desde esta pantalla).
- Cambios registrados en op_log (`HistorialOpLog` embebido).

**Ciclo de uso:** El admin abre `/admin/etiquetas` y define el catálogo: crea
una etiqueta (nombre, color, icono) y la ordena. Luego, desde el detalle de cada
cliente, asigna una o más etiquetas de ese catálogo; los chips aparecen en las
listas y el detalle. El conteo de usos le dice cuántos clientes usan cada una
antes de borrarla.

**Lifecycle (diagrama):**
```
Admin -> /admin/etiquetas -> define etiqueta (nombre+color+icono) -> ordena
              |
              +--> detalle del cliente -> asigna etiqueta -> chip en listas
```

**Gating:** Por rol admin/admin_cobranza del tenant (no cobrador). Catálogo
per-tenant (RLS por `tenant_id`). Siempre activo (no es módulo opcional con gate
por tenant).

*Archivos: `lib/features/admin/etiquetas/etiquetas_admin_screen.dart`,
`lib/data/repositories/etiquetas_repo.dart`,
`lib/features/shared/widgets/etiqueta_chip.dart`.*

---

## Diagrama general — cómo se entrelazan los módulos

El flujo central de dinero y cómo cuelgan de él los módulos opcionales:

```
                        Planes        Geografía / Red (puerto)
                          |                   |
                          v                   v
   Alta CLIENTE  ->  Crear CONTRATO  ->  Se generan CUOTAS  ->  'Por cobrar'
        |             (plan+dia_pago)     (trigger server)          |
        |                                                           v
        | (etiquetas,                                        COBRO (pago)
        |  visitas,                                          monto + vuelto
        |  mapa)                                                    |
        |                                                           v
        |                                                        RECIBO
        |                                          (térmica BT / USB · PDF)
        |
        +--(no paga)-> MORA (cron) -> SUSPENSIÓN -> Reactivar / Cancelar
        |                                  |
        |                                  +--> excedente -> SALDO A FAVOR
        |                                       (acreditar/condonar/devolver)
        |
        +--(opcional, gate por tenant)
              |
              +--> TICKET (técnico) -> consume INVENTARIO -> equipo instalado
              |          |
              |          +--> agrupado bajo INCIDENTE (corte masivo)
              |
              +--> AVISOS / WhatsApp (gracia / mora)

   Transversal (cruzan todo):  Auth/Onboarding · Settings · op_log (historial)
                               Reportes/Arqueo/Dashboard · Super-admin (multi-tenant)
```

Lectura rápida: **Cliente → Contrato → Cuotas → Cobro → Recibo** es la columna
vertebral; **Mora/Suspensión** y **Saldo a favor** son las ramas cuando no se
paga; **Inventario/Tickets/Incidentes/Avisos** cuelgan del cliente solo si el
tenant los tiene prendidos; y **Auth, Settings, op_log, Reportes y Super-admin**
son transversales a todo.