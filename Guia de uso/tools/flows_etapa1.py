# -*- coding: utf-8 -*-
"""Specs de los mockups de la Etapa 1 (nucleo de dinero) de GUIA-APP.md.

FIELES A LA APP: los labels, dialogos y botones se extrajeron del codigo real
(cliente_form_screen, contrato_detail_*, suspension_dialogs, cobro_screen,
pagos_admin_screen, cargo/descuento_dialog...). Al cambiar una pantalla,
actualizar el flujo aca y regenerar.

Datos de ejemplo continuos: cliente "Maria Peña Ruíz" (CL0102, La Barrera),
cobrador "Juan Lopez", plan "Basico 10 Mbps" C$ 450, instalado el 15.
"""

FLOWS = [
    # ════════════════════════════════ CLIENTES ═══════════════════════════════
    {
        "id": "clientes-crear",
        "titulo": "Crear un cliente nuevo",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Clientes → botón «Nuevo cliente»",
             "mock": [
                 {"t": "appbar", "title": "Clientes", "actions": [("icon", "search")]},
                 {"t": "row", "icon": "search", "text": "Buscar por nombre, código, cédula, teléfono o contrato",
                  "btn": ("Nuevo cliente", "primary")},
             ]},
            {"n": 2, "titulo": "Datos personales (los * son obligatorios)",
             "mock": [
                 {"t": "label", "text": "DATOS PERSONALES"},
                 {"t": "field", "label": "Código de cliente *", "value": "CL0102   (Ej. CL00027 — no se puede repetir)"},
                 {"t": "field", "label": "Nombre completo *", "value": "María Peña Ruíz"},
                 {"t": "field", "label": "Cédula", "value": "281-150692-0001A"},
                 {"t": "field", "label": "Teléfono", "value": "8836-0218"},
                 {"t": "field", "label": "Correo electrónico", "value": "", "helper": "opcional"},
             ]},
            {"n": 3, "titulo": "Ubicación, red y asignación (opcionales)",
             "mock": [
                 {"t": "label", "text": "UBICACIÓN"},
                 {"t": "field", "label": "Comunidad", "value": "Chinandega → Somotillo → La Barrera"},
                 {"t": "field", "label": "Dirección", "value": "Calle, número, sector"},
                 {"t": "field", "label": "Referencia", "value": "Casa amarilla, frente al molino, etc."},
                 {"t": "field", "label": "Latitud", "value": "13.04218"},
                 {"t": "field", "label": "Longitud", "value": "-86.90557"},
                 {"t": "btnrow", "buttons": [("Seleccionar en mapa", "neutral")]},
                 {"t": "label", "text": "CONEXIÓN DE RED (OPCIONAL) · ASIGNACIÓN"},
                 {"t": "field", "label": "Puerto de red", "value": "Nodo Centro → Hub 2 → Puerto 5"},
                 {"t": "field", "label": "Cobrador asignado", "value": "Toca para elegir…   (vacío = lo gestiona el admin)"},
             ]},
            {"n": 4, "titulo": "Si el puerto ya lo usa otro cliente activo, la app avisa (se puede forzar)",
             "mock": [
                 {"t": "dialog", "title": "Puerto ya ocupado",
                  "body": "Ese puerto ya está asignado a «Carlos Mairena». ¿Asignarlo igual a este cliente?",
                  "actions": [("Cancelar", "neutral"), ("Asignar igual", "primary")]},
             ]},
            {"n": 5, "titulo": "«Crear cliente» — queda en la lista, el mapa y la ruta del cobrador",
             "mock": [
                 {"t": "btnrow", "buttons": [("Cancelar", "neutral"), ("Crear cliente", "primary")]},
                 {"t": "row", "text": "CL0102 · María Peña Ruíz",
                  "sub": "La Barrera · Somotillo", "right": "Saldo C$ 0", "pill": ("Sin contrato", "warn")},
             ]},
        ],
        "nota": "El código es único por empresa (si ya existe, el form no deja guardar) y después "
                "queda inmutable. Un cliente sin cobrador asignado aparece con el chip «Sin cobrador» "
                "y solo lo gestionan los admins.",
    },
    {
        "id": "clientes-editar",
        "titulo": "Editar la ficha o desactivar un cliente",
        "rol": "admin / admin de cobranza (desactivar: solo admin)",
        "pasos": [
            {"n": 1, "titulo": "Abrí el cliente y tocá el lápiz del encabezado («Editar cliente»)",
             "mock": [
                 {"t": "appbar", "title": "María Peña Ruíz",
                  "actions": ["+ Cobro extra", ("icon", "doc"), ("icon", "pencil"), ("icon", "clock")]},
             ]},
            {"n": 2, "titulo": "Cambiá lo que necesites → «Guardar cambios»",
             "mock": [
                 {"t": "field", "label": "Teléfono", "value": "8899-4455  (actualizado)"},
                 {"t": "btnrow", "buttons": [("Cancelar", "neutral"), ("Guardar cambios", "primary")]},
             ]},
            {"n": 3, "titulo": "Para dar de baja: sección «Estado» → apagá el interruptor",
             "mock": [
                 {"t": "switchrow", "text": "Cliente activo", "on": False},
                 {"t": "row", "text": "El cliente se oculta del cobrador y NO se generan nuevas cuotas."},
             ]},
        ],
        "nota": "Desactivar NO borra nada: la deuda que tuviera sigue viva y se cobra con «Fuera de "
                "ruta» (ver Cuotas y cobros). Todo cambio queda en el historial (ícono del reloj).",
    },
    {
        "id": "clientes-cobrador",
        "titulo": "Asignar o cambiar el cobrador de un cliente",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "En el detalle del cliente: tarjeta «Cobrador» → lápiz «Cambiar cobrador»",
             "mock": [
                 {"t": "row", "icon": "pin", "text": "Cobrador", "right": "Sin asignar",
                  "iconbtn": ("pencil", None)},
             ]},
            {"n": 2, "titulo": "Elegí en la lista (con buscador); la primera opción es «— Sin asignar —»",
             "mock": [
                 {"t": "dialog", "title": "Asignar cobrador",
                  "items": [
                      {"t": "row", "text": "— Sin asignar —"},
                      {"t": "row", "text": "Juan López (JL)", "pill": ("elegido", "primary")},
                      {"t": "row", "text": "Ana Ruiz (AR)"},
                  ]},
             ]},
            {"n": 3, "titulo": "Para VARIOS a la vez: en Clientes, «Seleccionar todos del filtro» (o marcá casillas) → «Asignar cobrador»",
             "mock": [
                 {"t": "row", "text": "3 seleccionados", "btn": ("Asignar cobrador", "tonal")},
                 {"t": "dialog", "title": "Confirmar asignación masiva",
                  "body": "Vas a asignar a «Juan López» 3 cliente(s). Esta acción se registra en auditoría y no se puede deshacer en lote.",
                  "actions": [("Cancelar", "neutral"), ("Asignar", "primary")]},
             ]},
        ],
        "nota": "Cambiar el cobrador solo mueve al cliente de ruta/lista. NUNCA cambia el historial "
                "de quién cobró cada pago (el arqueo y los reportes no se alteran).",
    },
    {
        "id": "clientes-etiquetas",
        "titulo": "Etiquetas: crear el catálogo y etiquetar clientes",
        "rol": "catálogo: solo admin · asignar: admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "El catálogo vive en Administración → Etiquetas (nombre + color + ícono)",
             "mock": [
                 {"t": "dialog", "title": "Nueva etiqueta",
                  "body": "Nombre + selector de color (paleta) + ícono (cuadrícula), con vista previa del chip.",
                  "field": "Nombre — VIP",
                  "actions": [("Cancelar", "neutral"), ("Guardar", "primary")]},
             ]},
            {"n": 2, "titulo": "En el detalle del cliente: sección «Etiquetas» → «Asignar» (o «Editar» si ya tiene)",
             "mock": [
                 {"t": "label", "text": "ETIQUETAS DEL CLIENTE"},
                 {"t": "row", "text": "VIP", "pill": ("asignada", "primary")},
                 {"t": "row", "text": "Promesa de pago"},
             ]},
            {"n": 3, "titulo": "Se ven como chips en la lista de clientes, el mapa y el cobro",
             "mock": [
                 {"t": "tile", "avatar": "MP", "text": "CL0102 · María Peña Ruíz",
                  "sub": "La Barrera · Somotillo", "pill": ("VIP", "primary")},
             ]},
        ],
        "nota": "Si el nombre ya existe, avisa «Ya existe una etiqueta». Asignar o quitar queda "
                "registrado en el historial del cliente.",
    },
    {
        "id": "clientes-acciones",
        "titulo": "El detalle del cliente: acciones, fotos e historial",
        "rol": "todos los roles lo ven; las acciones según permiso",
        "pasos": [
            {"n": 1, "titulo": "El encabezado: código y nombre + botones «Llamar» y «Navegar» (abre el GPS)",
             "mock": [
                 {"t": "tile", "avatar": "MP", "text": "CL0102", "sub": "María Peña Ruíz"},
                 {"t": "btnrow", "buttons": [("Llamar", "tonal"), ("Navegar", "tonal")]},
                 {"t": "label", "text": "PESTAÑAS: DETALLE · CONTRATOS · EQUIPOS · VISITAS"},
             ]},
            {"n": 2, "titulo": "Fotos de la casa / instalación: tarjeta «Fotos» → «Agregar» (cámara o galería)",
             "mock": [
                 {"t": "row", "icon": "camera", "text": "Cuadrícula de miniaturas + casilla «Agregar»",
                  "sub": "Tocá una foto para verla en grande; el alta y la baja quedan en el historial"},
             ]},
            {"n": 3, "titulo": "Historial de cambios (ícono del reloj): quién cambió qué y cuándo — ediciones, etiquetas, fotos, visitas",
             "mock": [
                 {"t": "row", "icon": "clock", "text": "Teléfono: 8836-0218 → 8899-4455",
                  "sub": "12 jun 2026 · Admin"},
                 {"t": "row", "icon": "clock", "text": "Visita registrada: Promesa de pago",
                  "sub": "10 jun 2026 · Juan López"},
             ]},
            {"n": 4, "titulo": "PDF del historial de pagos: ícono PDF del encabezado → elegí el período",
             "mock": [
                 {"t": "dialog", "title": "Historial de pagos",
                  "body": "Últimos 12 meses · Este año (2026) · Año pasado (2025)"},
             ]},
        ],
    },

    # ═══════════════════════════════ CONTRATOS ═══════════════════════════════
    {
        "id": "contratos-crear",
        "titulo": "Crear un contrato (genera las cuotas solo)",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Cliente → pestaña «Contratos» → «Nuevo»",
             "mock": [
                 {"t": "row", "text": "Contratos (0 activos)", "btn": ("Nuevo", "text")},
             ]},
            {"n": 2, "titulo": "Cliente y plan",
             "mock": [
                 {"t": "label", "text": "CLIENTE Y PLAN"},
                 {"t": "field", "label": "Código de contrato *", "value": "CT0088   (Ej. CT00012 — no se repite)"},
                 {"t": "field", "label": "Cliente *", "value": "María Peña Ruíz"},
                 {"t": "field", "label": "Plan *", "value": "Básico 10 Mbps · C$ 450.00"},
             ]},
            {"n": 3, "titulo": "Términos: la fecha de instalación DEFINE el día de pago (no hay campo aparte)",
             "mock": [
                 {"t": "label", "text": "TÉRMINOS"},
                 {"t": "field", "label": "Fecha de instalación", "value": "15/06/2026"},
                 {"t": "row", "text": "La primera cuota vence el 15/07/2026 (mes siguiente). Después, cada día 15 del mes."},
                 {"t": "label", "text": "DURACIÓN"},
                 {"t": "segmented", "opts": [("1 año", True), ("2 años", False), ("Indefinido", False)]},
                 {"t": "field", "label": "Costo de instalación (opcional)", "value": "C$ 500   (informativo, no genera cobro)"},
                 {"t": "field", "label": "Notas del contrato (opcional)", "value": ""},
             ]},
            {"n": 4, "titulo": "«Crear contrato» → las cuotas se generan AUTOMÁTICAMENTE",
             "mock": [
                 {"t": "btnrow", "buttons": [("Cancelar", "neutral"), ("Crear contrato", "primary")]},
                 {"t": "row", "text": "Julio 2026 · vence 15/07", "right": "C$ 450", "pill": ("30d", "primary")},
                 {"t": "row", "text": "Agosto 2026 · vence 15/08", "right": "C$ 450", "pill": ("61d", "primary")},
                 {"t": "row", "text": "… hasta completar la duración"},
             ]},
        ],
        "nota": "También podés adjuntar el contrato firmado (PDF, Word o foto) — si no tenés "
                "conexión, se sube después desde el detalle. Cada cuota nace con el precio del plan "
                "de ese momento: si después cambiás el precio del plan, las ya generadas no cambian.",
    },
    {
        "id": "contratos-header",
        "titulo": "Leer el detalle del contrato",
        "rol": "todos los roles",
        "pasos": [
            {"n": 1, "titulo": "La tarjeta de arriba: plan + estado, datos y el panel de plata",
             "mock": [
                 {"t": "appbar", "title": "Detalle del contrato", "actions": [("icon", "clock")]},
                 {"t": "row", "text": "Básico 10 Mbps", "pill": ("Activo", "primary")},
                 {"t": "row", "text": "CT0088 · María Peña Ruíz · C$ 450 / mes · Duración: 1 año · Instalación: 15/06/2026"},
                 {"t": "field", "label": "Total contrato", "value": "C$ 5,400"},
                 {"t": "field", "label": "Recaudado", "value": "C$ 1,350"},
                 {"t": "field", "label": "Pendiente", "value": "C$ 4,050"},
             ]},
            {"n": 2, "titulo": "Las acciones del contrato",
             "mock": [
                 {"t": "btnrow", "buttons": [("Pagar", "primary"), ("Cambiar fecha", "neutral"),
                                             ("Suspender contrato", "neutral"), ("Cambiar plan", "neutral")]},
             ]},
            {"n": 3, "titulo": "Abajo: las cuotas (tocá una para cargos/descuentos), el historial de pagos y el documento adjunto"},
        ],
        "nota": "El «Total contrato» es la suma REAL de las cuotas vivas (si hubo suspensión o "
                "cambio de plan, se ajusta solo). En contratos indefinidos solo se muestra «Total "
                "recaudado» — no hay «pendiente» porque no hay fin.",
    },
    {
        "id": "contratos-cambiar-fecha",
        "titulo": "Cambiar el día de pago (cobra el «puente» en el momento)",
        "rol": "admin / admin de cobranza · cobrador solo si el dueño del sistema lo habilitó",
        "pasos": [
            {"n": 1, "titulo": "Detalle del contrato → «Cambiar fecha»",
             "mock": [
                 {"t": "dialog", "title": "Cambiar fecha de pago",
                  "body": "Cobrás el «puente» (los días entre la fecha vieja y la nueva) más lo que esté vencido; desde ahí la cuota vence el día que elijas. Abajo ves el total.",
                  "actions": [("Cancelar", "neutral")]},
             ]},
            {"n": 2, "titulo": "Elegí el nuevo día — la app te muestra el total a cobrar YA",
             "mock": [
                 {"t": "field", "label": "Nuevo día de pago", "value": "Día 1   (actual: día 15)"},
                 {"t": "row", "text": "Puente: 17 días", "right": "C$ 255"},
                 {"t": "row", "text": "Total a cobrar", "right": "C$ 255", "pill": ("se cobra ahora", "warn")},
                 {"t": "row", "text": "Desde ahí, las cuotas vencen el día 1 de cada mes."},
             ]},
            {"n": 3, "titulo": "Ingresá lo entregado y confirmá — es un cobro normal (con vuelto y recibo)",
             "mock": [
                 {"t": "field", "label": "Monto entregado (C$)", "value": "300"},
                 {"t": "btnrow", "buttons": [("Cancelar", "neutral"), ("Cobrar y cambiar fecha", "primary")]},
             ]},
        ],
        "nota": "Así el cliente nunca paga dos veces el mismo período ni queda con días gratis. Si "
                "tiene cuotas vencidas, la app pide cobrar los atrasados antes de cambiar la fecha.",
    },
    {
        "id": "contratos-cambiar-plan",
        "titulo": "Cambiar el plan de un contrato vigente",
        "rol": "admin / admin de cobranza (si el dueño del sistema habilitó «Cambio de plan»)",
        "pasos": [
            {"n": 1, "titulo": "Detalle del contrato → «Cambiar plan»: elegí el nuevo (ACTUAL → NUEVO)",
             "mock": [
                 {"t": "dialog", "title": "Cambiar de plan",
                  "body": "ACTUAL: Básico 10 Mbps · C$ 450/mes   →   NUEVO: Premium 20 Mbps · C$ 700/mes (↑ sube C$ 250)",
                  "actions": [("Cancelar", "neutral")]},
             ]},
            {"n": 2, "titulo": "«¿Cuándo aplica?» — dos opciones",
             "mock": [
                 {"t": "row", "text": "Próximo ciclo", "sub": "Arranca el próximo mes. No se cobra nada hoy.",
                  "pill": ("elegido", "primary")},
                 {"t": "row", "text": "Hoy con prorrateo", "sub": "Arranca ya. Se ajustan los días que faltan del ciclo actual."},
             ]},
            {"n": 3, "titulo": "El resumen «QUÉ CAMBIA, CUÁNDO Y POR QUÉ» te muestra todo antes de confirmar",
             "mock": [
                 {"t": "row", "text": "Ciclo en curso", "right": "sigue al plan actual"},
                 {"t": "row", "text": "10 cuotas futuras", "right": "desde Ago · pasan a C$ 700"},
                 {"t": "row", "text": "Se cobra hoy", "right": "nada"},
                 {"t": "btnrow", "buttons": [("Cancelar", "neutral"), ("Confirmar", "primary")]},
             ]},
        ],
        "nota": "No cambian: el día de pago, la vigencia del contrato ni el conteo de cuotas — solo "
                "el plan y el precio de las cuotas futuras. En un downgrade con prorrateo, la "
                "diferencia queda como crédito a favor del cliente.",
    },
    {
        "id": "contratos-suspender",
        "titulo": "Suspender un contrato (moroso o pausa a pedido)",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Detalle → «Suspender contrato»: el diálogo te explica qué va a pasar",
             "mock": [
                 {"t": "dialog", "title": "Suspender contrato",
                  "body": "¿Qué va a pasar? 1. Se cobra la deuda hasta hoy (la ves abajo). 2. Los meses futuros NO se facturan mientras esté suspendido. 3. Al reactivar, su fecha de pago mensual pasa a ser ese día (no estira el contrato).",
                  "field": "Motivo — Solicitud del cliente · Falta de pago · Suspensión por mantenimiento · Otro",
                  "field2": "Notas (opcional) — Detalle del porqué… · Fecha de suspensión — 20/07/2026",
                  "actions": [("Cancelar", "neutral"), ("Suspender", "primary")]},
             ]},
            {"n": 2, "titulo": "El recuadro «Deuda a la fecha» clasifica cada cuota por el servicio consumido",
             "mock": [
                 {"t": "label", "text": "DEUDA A LA FECHA — C$ 600"},
                 {"t": "row", "text": "Junio 2026", "sub": "vence 15/06 · abonó C$ 0", "right": "C$ 450"},
                 {"t": "row", "text": "Julio 2026", "sub": "vence 15/07 · prorrateado 10/30 días · abonó C$ 0", "right": "C$ 150"},
             ]},
            {"n": 3, "titulo": "Al confirmar, la app ofrece imprimir el PDF de deuda para el cliente",
             "mock": [
                 {"t": "dialog", "title": "Contrato suspendido",
                  "body": "¿Imprimir el detalle de la deuda para entregárselo al cliente?",
                  "actions": [("Ahora no", "neutral"), ("Imprimir", "primary")]},
             ]},
            {"n": 4, "titulo": "El contrato queda con la tarjeta «Suspensión vigente» (reimprimir deuda · revertir · cobrar pendiente / reactivar). Si pagó de más, decidís el excedente (ver Saldo a favor)"},
        ],
        "nota": "El suspendido SALE de «Por cobrar» y del conteo de mora; su deuda se cobra con el "
                "chip «Fuera de ruta». Si fue un error, «Revertir» el MISMO flujo lo deja como estaba.",
    },
    {
        "id": "contratos-reactivar",
        "titulo": "Reactivar un contrato suspendido",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "En la tarjeta «Suspensión vigente»: si debe, «Cobrar pendiente»; al día → «Reactivar»",
             "mock": [
                 {"t": "row", "text": "Suspensión vigente", "sub": "Desde el 20/07 · Motivo: Falta de pago · Deuda: C$ 600",
                  "btn": ("Reactivar", "primary")},
             ]},
            {"n": 2, "titulo": "Elegí la fecha — el diálogo explica el re-anclaje",
             "mock": [
                 {"t": "dialog", "title": "Reactivar contrato",
                  "body": "El día de pago pasa a 22. El servicio se reactiva desde esta fecha y se factura hasta el fin original del contrato (sin estirar). El tiempo en pausa no se cobra.",
                  "field": "Fecha de reactivación — 22/08/2026",
                  "actions": [("Cancelar", "neutral"), ("Reactivar", "primary")]},
             ]},
        ],
        "nota": "Cobrar la deuda NO reactiva solo: al saldar, la app avisa «Deuda saldada» con el "
                "botón «Reactivar ahora». Suspendiste por error → «Revertir» ese mismo día lo deja "
                "exacto como estaba.",
    },
    {
        "id": "contratos-cancelar",
        "titulo": "Cancelar un contrato (definitivo)",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Badge de estado del contrato → «Cancelado» (o desde el flujo de suspensión)",
             "mock": [
                 {"t": "dialog", "title": "¿Cancelar este contrato?",
                  "body": "Es PERMANENTE: el servicio termina y el contrato NO se puede reactivar. La deuda real (meses cumplidos + lo consumido del mes en curso) queda COBRABLE; los meses futuros se anulan. Se imprime un documento con la deuda.",
                  "field": "Motivo de la cancelación (obligatorio) — Ej. Mudanza, insatisfacción del servicio",
                  "actions": [("Volver", "neutral"), ("Cancelar contrato", "danger")]},
             ]},
            {"n": 2, "titulo": "El contrato queda con su tarjeta de cancelación (la deuda sigue cobrable «fuera de ruta»)",
             "mock": [
                 {"t": "row", "text": "Contrato cancelado · 20/07/2026",
                  "sub": "Motivo: Mudanza · Deuda al cancelar (cobrable): C$ 600",
                  "btn": ("Revertir cancelación", "neutral")},
             ]},
        ],
        "nota": "«Revertir cancelación» existe mientras no hayas cobrado nada de esa deuda (por si "
                "fue un error). Si el cliente vuelve, se le crea un contrato NUEVO.",
    },
    {
        "id": "contratos-solicitar-aprobacion",
        "titulo": "Pedir aprobación: suspender, cancelar o reactivar (admin de usuarios)",
        "rol": "pide: admin de usuarios · aprueba: admin",
        "pasos": [
            {"n": 1, "titulo": "En el detalle del contrato, el admin de usuarios ve «Solicitar…» donde los demás tienen el botón que ejecuta",
             "mock": [
                 {"t": "btnrow", "buttons": [("Solicitar suspensión", "neutral"),
                                             ("Solicitar cancelación", "danger")]},
             ]},
            {"n": 2, "titulo": "El diálogo pide MOTIVO (lista) y NOTAS — los dos obligatorios: sin notas el botón no envía",
             "mock": [
                 {"t": "dialog", "title": "Solicitar: Suspender contrato",
                  "body": "Esta acción requiere aprobación de un administrador. Cliente: María Peña Ruíz. El motivo y las notas son obligatorios.",
                  "field": "Motivo — Solicitud del cliente · Falta de pago · Mudanza / cambio de domicilio · Otro",
                  "field2": "Notas — Explicá el motivo…",
                  "actions": [("Cancelar", "neutral"), ("Enviar solicitud", "primary")]},
             ]},
            {"n": 3, "titulo": "La solicitud cae en Solicitudes: quien la pidió la sigue en «Mis solicitudes»; el admin la resuelve en «Pendientes», con el motivo a la vista",
             "mock": [
                 {"t": "row", "text": "Suspender contrato",
                  "sub": "Solicitó: Ana Gestora · Motivo: Falta de pago — 3 meses sin pagar, ya se le avisó",
                  "pill": ("Pendiente", "warn")},
                 {"t": "btnrow", "buttons": [("Rechazar", "neutral"), ("Aprobar", "primary")]},
             ]},
            {"n": 4, "titulo": "«Aprobar» ejecuta la suspensión de verdad CON ese motivo y esas notas (así queda en el historial del contrato). «Rechazar» pide su propio motivo y no toca nada"},
        ],
        "nota": "El admin de usuarios pide, no ejecuta: no suspende, no cancela y no cobra. "
                "Las solicitudes viejas (anteriores al motivo obligatorio) siguen visibles, sin ese recuadro.",
    },

    # ═══════════════════════════ CUOTAS / COBROS ═════════════════════════════
    {
        "id": "cuotas-lista",
        "titulo": "La pantalla «Por cobrar» (la lista de trabajo)",
        "rol": "cobrador (su vista principal) · admin / admin de cobranza (con filtros)",
        "pasos": [
            {"n": 1, "titulo": "Filtrá con los chips de estado; el admin además filtra por Cobrador y Zona",
             "mock": [
                 {"t": "chipbar", "chips": [("Pendientes", True), ("En mora", False), ("En gracia", False),
                                            ("Vencen hoy", False), ("Próximas", False), ("Ver todo", False)]},
                 {"t": "row", "icon": "search", "text": "Buscar por nombre, código, cédula, teléfono o contrato"},
             ]},
            {"n": 2, "titulo": "Cada card es UN contrato con su cuota más vieja pendiente (la barra de color indica el estado) — «Pagar» va directo al cobro",
             "mock": [
                 {"t": "cardrow", "texto": "CL0102 · María Peña Ruíz", "color": "danger",
                  "sub": "Básico 10 Mbps · Junio · 15/06/2026", "badge": ("Vencida 12d", "danger"),
                  "saldo": "C$ 450", "btns": [("Fecha", "neutral"), ("Pagar", "primary")]},
                 {"t": "cardrow", "texto": "CL0055 · Carlos Mairena", "color": "primary",
                  "sub": "Premium 20 Mbps · Julio · 07/07/2026", "badge": ("Hoy", "primary"),
                  "saldo": "C$ 700", "btns": [("Pagar", "primary")]},
                 {"t": "cardrow", "texto": "CL0071 · Sandra López", "color": "success",
                  "sub": "Básico 10 Mbps · Julio · 20/07/2026", "badge": ("13d", "success"),
                  "saldo": "C$ 450", "btns": [("Pagar", "primary")]},
             ]},
            {"n": 3, "titulo": "Tocar la fila abre el detalle del cliente. Si el contrato debe MÁS cuotas, un aviso lo indica («+2 cuotas · C$ 900 más»)"},
        ],
        "nota": "La app SIEMPRE cobra primero la cuota más vieja del contrato (no deja saltear una "
                "vencida). El buscador encuentra con o sin tildes/ñ.",
    },
    {
        "id": "cuotas-cobrar",
        "titulo": "Cobrar una cuota (el flujo del día a día)",
        "rol": "cobrador · admin / admin de cobranza — funciona SIN internet",
        "pasos": [
            {"n": 1, "titulo": "«Pagar» abre el cobro con la cuota cargada",
             "mock": [
                 {"t": "appbar", "title": "María Peña Ruíz"},
                 {"t": "row", "text": "Cobro de Junio 2026", "right": "C$ 450",
                  "sub": "Fecha de cobro: 07/07/2026 · Periodo: 15/06 → 15/07"},
             ]},
            {"n": 2, "titulo": "Método de pago y monto: ingresá lo que el cliente ENTREGA (no lo que debe)",
             "mock": [
                 {"t": "label", "text": "MÉTODO DE PAGO"},
                 {"t": "chipbar", "chips": [("Efectivo", True), ("Transferencia", False), ("Tarjeta", False)]},
                 {"t": "label", "text": "MONTO"},
                 {"t": "segmented", "opts": [("C$", True), ("US$", False)]},
                 {"t": "field", "label": "0.00", "value": "500"},
             ]},
            {"n": 3, "titulo": "El resumen calcula solo — incluido el vuelto",
             "mock": [
                 {"t": "row", "text": "Saldo total", "right": "C$ 450"},
                 {"t": "row", "text": "A cobrar ahora", "right": "C$ 450"},
                 {"t": "row", "text": "Vuelto al cliente", "right": "C$ 50", "pill": ("siempre en C$", "primary")},
                 {"t": "row", "text": "Cuota completa ✓", "pill": ("Pagada", "success")},
             ]},
            {"n": 4, "titulo": "«Confirmar cobro» → vas directo al recibo. Sin señal, queda guardado en el teléfono y sube solo al reconectar",
             "mock": [
                 {"t": "btnrow", "buttons": [("Cancelar", "neutral"), ("Confirmar cobro", "primary")]},
             ]},
        ],
    },
    {
        "id": "cuotas-parcial-adelantado",
        "titulo": "Pago parcial y pago adelantado",
        "rol": "según lo tenga habilitado tu empresa (lo activa el dueño del sistema)",
        "pasos": [
            {"n": 1, "titulo": "PARCIAL: el cliente entrega MENOS que el saldo → el resumen muestra el restante y la cuota queda «Parcial»",
             "mock": [
                 {"t": "row", "text": "A cobrar ahora", "right": "C$ 200"},
                 {"t": "row", "text": "Saldo restante", "right": "C$ 250"},
                 {"t": "row", "text": "En la lista queda:", "pill": ("Parcial · abonó C$ 200 de C$ 450", "warn")},
             ]},
            {"n": 2, "titulo": "ADELANTADO: con lo vencido saldado, la cuota «Próxima» del contrato también se puede cobrar",
             "mock": [
                 {"t": "cardrow", "texto": "CL0102 · María Peña Ruíz", "color": "success",
                  "sub": "Básico 10 Mbps · Agosto · 15/08/2026", "badge": ("39d", "success"),
                  "saldo": "C$ 450", "btns": [("Pagar", "primary")]},
             ]},
        ],
        "nota": "Si tu empresa no permite parcial, la app avisa: «No se permite pago parcial: cobrá "
                "el total de C$ 450». En cobro múltiple cada cuota se paga completa.",
    },
    {
        "id": "cuotas-fuera-de-ruta",
        "titulo": "Cobrar deuda de suspendidos o cancelados («Fuera de ruta»)",
        "rol": "cobrador · admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "En «Por cobrar», activá el chip «Fuera de ruta»",
             "mock": [
                 {"t": "chipbar", "chips": [("Pendientes", True), ("Fuera de ruta", True)]},
             ]},
            {"n": 2, "titulo": "Aparece la sección «Recuperación · fuera de ruta» con esa deuda congelada",
             "mock": [
                 {"t": "label", "text": "RECUPERACIÓN · FUERA DE RUTA — 2 · C$ 1,050"},
                 {"t": "cardrow", "texto": "CL0034 · Pedro Vega", "color": "warn",
                  "sub": "Julio · deuda al suspender", "badge": ("Suspendido", "warn"),
                  "saldo": "C$ 600", "btns": [("Pagar", "primary")]},
                 {"t": "cardrow", "texto": "CL0090 · Rosa Díaz", "color": "danger",
                  "sub": "Junio · deuda al cancelar", "badge": ("Cancelado", "danger"),
                  "saldo": "C$ 450", "btns": [("Pagar", "primary")]},
             ]},
            {"n": 3, "titulo": "Se cobra igual que siempre. Si un SUSPENDIDO salda todo, la app avisa",
             "mock": [
                 {"t": "dialog", "title": "Deuda saldada",
                  "body": "La deuda de Pedro Vega quedó en cero, pero su contrato sigue SUSPENDIDO. Pagar no reactiva el servicio.",
                  "actions": [("Entendido", "neutral"), ("Reactivar ahora", "primary")]},
             ]},
        ],
        "nota": "Un cancelado nunca se reactiva (su deuda solo se recupera). El chip queda apagado "
                "por defecto para no ensuciar la ruta del día.",
    },
    {
        "id": "cuotas-anular-recobrar",
        "titulo": "Anular una cuota cobrada por error y volver a cobrarla",
        "rol": "admin / admin de cobranza (no disponible al impersonar)",
        "pasos": [
            {"n": 1, "titulo": "Abrí el pago: contrato → «Historial de pagos» → tocá el pago. Abajo del detalle está «Anular pago»",
             "mock": [
                 {"t": "hero", "monto": "450,00 C$", "sub": "Cuota Junio 2026 · aplicado a la cuota"},
                 {"t": "twobox",
                  "a": {"label": "CÓMO PAGÓ", "l1": "Entregó 450,00 C$", "l2": "Vuelto 0,00 C$"},
                  "b": {"label": "LA CUOTA QUEDÓ", "l1": "PAGADA", "l2": "saldo 0,00 C$", "tint": "success"}},
                 {"t": "kv", "label": "DATOS DEL COBRO",
                  "rows": [("Método", "Efectivo"), ("Fecha del cobro", "03/06/2026 14:32"),
                           ("Cobrador", "Juan López"), ("Recibo", "REC-000123")]},
                 {"t": "btnfull", "label": "Reimprimir / Ver recibo", "tipo": "primary", "icon": "print"},
                 {"t": "btnfull", "label": "Anular pago", "tipo": "danger_outline"},
             ]},
            {"n": 2, "titulo": "Escribí el motivo (obligatorio) y confirmá",
             "mock": [
                 {"t": "dialog", "title": "Anular pago",
                  "body": "Esta acción queda registrada en auditoría. La cuota volverá a su estado anterior y el recibo emitido queda inválido. Para volver a cobrar, registrá el cobro de nuevo desde la cuota.",
                  "field": "Motivo de anulación * — Ej. Monto incorrecto, registrado por error...",
                  "actions": [("Cancelar", "neutral"), ("Anular", "danger")]},
             ]},
            {"n": 3, "titulo": "El pago queda ANULADO (no se borra) y la cuota vuelve a «Por cobrar»",
             "mock": [
                 {"t": "tile", "avatar": "MP", "text": "María Peña Ruíz  ·  C$ 450", "tachado": True,
                  "sub": "Anulado: Registrado por error", "pill": ("Anulado", "danger")},
                 {"t": "cardrow", "texto": "CL0102 · María Peña Ruíz", "color": "danger",
                  "sub": "Básico 10 Mbps · Junio · 15/06/2026", "badge": ("Vencida 12d", "danger"),
                  "saldo": "C$ 450", "btns": [("Pagar", "primary")]},
             ]},
            {"n": 4, "titulo": "Cobrala de nuevo como cualquier cuota — se emite un recibo NUEVO",
             "mock": [
                 {"t": "row", "text": "Cuota Junio 2026 cobrada", "right": "C$ 450",
                  "pill": ("Recibo REC-000124", "success")},
             ]},
        ],
        "nota": "El pago anulado se conserva con quién lo anuló y por qué (se ve con el chip «Ver "
                "anulados» y descuenta de la caja del día). La pantalla «Pagos» existe si tu empresa "
                "la tiene habilitada; el historial de pagos del contrato está siempre.",
    },

    # ═══════════════════════════ PAGOS / RECIBOS ═════════════════════════════
    {
        "id": "pagos-usd",
        "titulo": "Cobrar en dólares (USD)",
        "rol": "si tu empresa tiene el dólar habilitado",
        "pasos": [
            {"n": 1, "titulo": "En «Monto», cambiá el selector C$ | US$ — la app muestra el equivalente con la tasa del día",
             "mock": [
                 {"t": "segmented", "opts": [("C$", False), ("US$", True)]},
                 {"t": "field", "label": "0.00", "value": "15"},
                 {"t": "row", "text": "Equivalente: C$ 547.50 (tasa 36.50)"},
             ]},
            {"n": 2, "titulo": "El vuelto se calcula SIEMPRE en córdobas",
             "mock": [
                 {"t": "row", "text": "A cobrar ahora", "right": "C$ 450"},
                 {"t": "row", "text": "Vuelto al cliente", "right": "C$ 97.50", "pill": ("en córdobas", "primary")},
             ]},
        ],
        "nota": "El vuelto jamás se da en dólares. El recibo y los reportes registran lo entregado "
                "en US$ y su equivalente con la tasa exacta del momento del cobro.",
    },
    {
        "id": "pagos-metodos",
        "titulo": "Transferencia o tarjeta: referencia y foto del comprobante",
        "rol": "los métodos disponibles los define tu empresa",
        "pasos": [
            {"n": 1, "titulo": "Elegí el método — transferencia/tarjeta piden el comprobante",
             "mock": [
                 {"t": "chipbar", "chips": [("Efectivo", False), ("Transferencia", True), ("Tarjeta", False)]},
                 {"t": "field", "label": "Número de referencia / confirmación", "value": "BANPRO-778812"},
             ]},
            {"n": 2, "titulo": "O adjuntá la foto (vale como referencia)",
             "mock": [
                 {"t": "btnrow", "buttons": [("Adjuntar foto del comprobante", "neutral")]},
                 {"t": "row", "text": "Si no hay ni referencia ni foto, la app avisa: «Ingresá referencia o adjuntá foto»"},
             ]},
        ],
    },
    {
        "id": "pagos-editar",
        "titulo": "Editar un pago ya registrado",
        "rol": "admin / admin de cobranza (pantalla «Pagos», si está habilitada)",
        "pasos": [
            {"n": 1, "titulo": "En la fila del pago: lápiz «Editar pago»",
             "mock": [
                 {"t": "tile", "avatar": "MP", "text": "María Peña Ruíz", "right": "C$ 450",
                  "sub": "REC-000123 · Efectivo · 03/06/2026 · Juan López",
                  "iconbtn": ("pencil", None)},
             ]},
            {"n": 2, "titulo": "Podés corregir monto (C$), método y notas",
             "mock": [
                 {"t": "dialog", "title": "Editar pago",
                  "field": "Monto (C$) — 450",
                  "field2": "Método de pago — Efectivo · Notas (opcional)",
                  "actions": [("Cancelar", "neutral"), ("Guardar", "primary")]},
             ]},
            {"n": 3, "titulo": "Un pago con VUELTO o en DÓLARES no se edita: anulalo y cobralo de nuevo",
             "mock": [
                 {"t": "row", "text": "«No se puede editar: este pago tiene vuelto»", "pill": ("bloqueado", "danger")},
             ]},
        ],
        "nota": "Toda edición queda en el historial con el antes y el después.",
    },
    {
        "id": "recibos-imprimir",
        "titulo": "El recibo: imprimir, PDF y reimprimir",
        "rol": "quien cobra; el diseño del recibo lo configura el admin en Configuración → Recibos",
        "pasos": [
            {"n": 1, "titulo": "Al confirmar un cobro vas directo al recibo (tal cual va a salir impreso)",
             "mock": [
                 {"t": "appbar", "title": "Recibo"},
                 {"t": "row", "text": "TELECABLE MAIRENA S.A. · RECIBO JL-000124",
                  "sub": "María Peña Ruíz · Cuota Junio 2026 · C$ 450 · Cobró: Juan López"},
             ]},
            {"n": 2, "titulo": "Imprimí en la térmica Bluetooth (sin internet) o guardá el PDF",
             "mock": [
                 {"t": "btnrow", "buttons": [("Imprimir 80mm", "primary"), ("Guardar PDF 80mm", "tonal"),
                                             ("Configurar impresora", "neutral")]},
                 {"t": "row", "text": "El recibo queda guardado y sincronizado aunque la impresora falle. Podés reintentar imprimir cuando quieras."},
             ]},
            {"n": 3, "titulo": "Si el cliente tiene cuotas vencidas, el recibo agrega el bloque de MORA con el detalle por mes"},
            {"n": 4, "titulo": "REIMPRIMIR: abrí el pago (contrato → Historial de pagos) → «Reimprimir / Ver recibo»",
             "mock": [
                 {"t": "btnrow", "buttons": [("Reimprimir / Ver recibo", "primary")]},
             ]},
        ],
        "nota": "Qué muestra el recibo (cédula, adeudado, descuentos, título, pie, papel 57/80 mm) "
                "se configura en Configuración → Recibos. Un pago anulado no se reimprime.",
    },
    {
        "id": "recibos-impresora-pc",
        "titulo": "Configurar la impresora de la computadora (USB)",
        "rol": "cada persona en SU computadora — estos ajustes no viajan a los otros equipos",
        "pasos": [
            {"n": 1, "titulo": "Perfil → «Impresora térmica»: la lista muestra las impresoras que Windows tiene instaladas. Elegí la tuya («Usar como predeterminada») y probala",
             "mock": [
                 {"t": "appbar", "title": "Impresora"},
                 {"t": "tile", "icon": "print", "text": "3nStar RPT004",
                  "sub": "Predeterminada del sistema",
                  "btn": ("Imprimir prueba", "neutral")},
             ]},
            {"n": 2, "titulo": "«Modo de impresión»: con cuál sale el recibo",
             "mock": [
                 {"t": "row", "text": "Imagen (recomendado)",
                  "sub": "Sale igual que la vista previa: mismo diseño, tamaños y logo",
                  "pill": ("elegido", "primary")},
                 {"t": "row", "text": "Texto nativo",
                  "sub": "Letra pareja de la impresora, liviano y SIEMPRE completo (nunca pierde el pie)"},
                 {"t": "row", "text": "Por driver de Windows",
                  "sub": "El camino anterior. Solo si la impresora no entiende los otros dos"},
             ]},
            {"n": 3, "titulo": "«Imprimir regla de ancho» MIDE tu impresora (modo texto): imprime líneas numeradas en los dos extremos y el número más alto que salga COMPLETO va al «Ancho de línea»",
             "mock": [
                 {"t": "row", "text": "Ancho de línea", "right": "42 caracteres"},
                 {"t": "btnrow", "buttons": [("Imprimir regla de ancho", "neutral")]},
                 {"t": "row", "text": "REGLA DE ANCHO",
                  "sub": "Anote el número más alto que aparezca a la IZQUIERDA y a la DERECHA de la MISMA línea"},
             ]},
            {"n": 4, "titulo": "Los ajustes que arreglan lo que se ve mal en el papel",
             "mock": [
                 {"t": "switchrow", "text": "Impresión lenta   (modo imagen)",
                  "sub": "Si en recibos largos —con lista de mora— el final sale en blanco o cortado", "on": True},
                 {"t": "row", "text": "Avance antes del corte", "right": "6 líneas",
                  "sub": "Si el slogan del pie sale cortado o aparece arriba del recibo siguiente, subilo"},
                 {"t": "label", "text": "TILDES (ACENTOS) — solo en modo texto"},
                 {"t": "segmented", "opts": [("Sin tildes", True), ("Acentos", False),
                                             ("Estándar", False), ("Occidental", False)]},
             ]},
        ],
        "nota": "Son ajustes de ESA computadora: no afectan a los celulares ni a las otras PC. "
                "En el celular la impresora es Bluetooth y su pantalla tiene solo modo, tildes y envío lento.",
    },

    # ══════════════════════════ MORA Y SUSPENSIONES ══════════════════════════
    {
        "id": "mora-ciclo",
        "titulo": "Cómo funciona la mora (gracia → vencida)",
        "rol": "automático (el sistema la marca cada medianoche); la ven todos",
        "pasos": [
            {"n": 1, "titulo": "La cuota vence y arrancan los días de gracia de tu empresa (ej. 10): badge «Gracia»",
             "mock": [
                 {"t": "cardrow", "texto": "CL0102 · María Peña Ruíz", "color": "warn",
                  "sub": "Básico 10 Mbps · Junio · venció 15/06", "badge": ("Gracia", "warn"),
                  "saldo": "C$ 450", "btns": [("Pagar", "primary")]},
             ]},
            {"n": 2, "titulo": "Pasada la gracia, cada medianoche el sistema la marca vencida con los días acumulados",
             "mock": [
                 {"t": "cardrow", "texto": "CL0102 · María Peña Ruíz", "color": "danger",
                  "sub": "Básico 10 Mbps · Junio · venció 15/06", "badge": ("Vencida 12d", "danger"),
                  "saldo": "C$ 450", "btns": [("Pagar", "primary")]},
             ]},
            {"n": 3, "titulo": "Los morosos aparecen en el chip «En mora», el Centro de cobranza y la pantalla Avisos (para notificar). Si no paga, el paso siguiente es suspender (ver Contratos)"},
        ],
        "nota": "Los días de gracia los define el dueño del sistema para tu empresa. Suspendidos y "
                "cancelados NO generan mora nueva (su deuda quedó congelada).",
    },

    # ═══════════════════════ CARGOS EXTRA / DESCUENTOS ═══════════════════════
    {
        "id": "cargos-agregar",
        "titulo": "Agregar un cargo a una cuota (reconexión u otro)",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Contrato → tocá la cuota → «Cargo extra»: elegí tipo, monto y descripción",
             "mock": [
                 {"t": "dialog", "title": "Cargo extra",
                  "body": "Reconexión | Otro cargo",
                  "field": "Monto (C$) — 100",
                  "field2": "Descripción * — Ej. Cambio de equipo, instalación, etc.",
                  "actions": [("Cancelar", "neutral"), ("Aplicar cargo", "primary")]},
             ]},
            {"n": 2, "titulo": "El recuadro «Resultado» muestra el saldo nuevo antes de confirmar",
             "mock": [
                 {"t": "row", "text": "Cargo: +C$ 100", "right": "Saldo: C$ 450 → C$ 550"},
             ]},
        ],
        "nota": "Si tu empresa tiene la reconexión automática activada, el cargo se agrega solo al "
                "cobrar a un cliente que estuvo suspendido (el cobro lo muestra como tarjeta).",
    },
    {
        "id": "descuentos-aplicar",
        "titulo": "Aplicar un descuento a una cuota (y quitarlo)",
        "rol": "admin / admin de cobranza (si el dueño del sistema habilitó los ajustes) — el cobrador NO descuenta",
        "pasos": [
            {"n": 1, "titulo": "Contrato → tocá la cuota → «Descontar cuota»: 3 pasos guiados",
             "mock": [
                 {"t": "dialog", "title": "Descontar cuota",
                  "body": "Paso 1 · ¿Qué tipo de descuento? — Ajuste (corrección puntual: días sin servicio, error, acuerdo) | Promo (beneficio comercial). Paso 2 · ¿Cuánto? — Monto C$ | Porcentaje %. Paso 3 · ¿Por qué?",
                  "field": "Motivo * — Ej. Sin servicio 5 días",
                  "actions": [("Cancelar", "neutral"), ("Aplicar descuento", "primary")]},
             ]},
            {"n": 2, "titulo": "Con chips rápidos de motivo y el resultado a la vista",
             "mock": [
                 {"t": "chipbar", "chips": [("Sin servicio", True), ("Promesa de pago", False),
                                            ("Acuerdo con el cliente", False)]},
                 {"t": "row", "text": "Descuento: −C$ 50", "right": "Saldo: C$ 450 → C$ 400"},
             ]},
            {"n": 3, "titulo": "Para QUITAR un cargo/descuento: el ícono de basura junto a él en la cuota. El «Crédito aplicado» tiene candado y NO se quita (ver Saldo a favor)"},
        ],
        "nota": "Hay topes configurados por empresa (% o monto máximo) y el descuento no puede "
                "exceder el saldo. Todo queda en el historial de la cuota.",
    },

    # ═══════════════════ SALDO A FAVOR (CRÉDITO POR EXCEDENTE) ═══════════════
    {
        "id": "credito-disposicion",
        "titulo": "El cliente pagó de más: decidir qué hacer con el excedente",
        "rol": "admin / admin de cobranza (la app nunca decide sola)",
        "pasos": [
            {"n": 1, "titulo": "Al suspender/cancelar con meses ya pagados, aparece «A favor del cliente»",
             "mock": [
                 {"t": "row", "text": "A favor del cliente", "right": "C$ 300",
                  "sub": "Pagó por adelantado servicio que no se prestará. ¿Qué hacés?"},
             ]},
            {"n": 2, "titulo": "Elegí UNA de las tres opciones",
             "mock": [
                 {"t": "row", "text": "Acreditar", "sub": "Saldo a favor para sus próximas cuotas (no caduca).",
                  "pill": ("elegido", "primary")},
                 {"t": "row", "text": "Devolver en efectivo", "sub": "Sale de la caja. Genera comprobante de devolución."},
                 {"t": "row", "text": "Condonar", "sub": "El cliente cede el saldo. Queda en caja, registrado."},
                 {"t": "field", "label": "Motivo (opcional)", "value": ""},
             ]},
        ],
        "nota": "Si elegís devolver, la app avisa: «Vas a entregar C$ 300 en efectivo — sale de la "
                "caja de hoy» (queda en el arqueo). La decisión se registra en el historial y el "
                "mismo excedente no se ofrece dos veces.",
    },
    {
        "id": "credito-aplicar",
        "titulo": "Usar el crédito a favor en una cuota",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "En el detalle del CLIENTE aparece su saldo a favor con el botón «Aplicar»",
             "mock": [
                 {"t": "row", "icon": "check", "text": "Saldo a favor", "right": "C$ 300",
                  "btn": ("Aplicar", "primary")},
                 {"t": "dialog", "title": "Aplicar saldo a favor",
                  "body": "Se aplican C$ 300 a la cuota de Agosto 2026 (queda en C$ 150). No entra plata: es cobertura con el saldo a favor del cliente.",
                  "actions": [("Cancelar", "neutral"), ("Aplicar", "primary")]},
             ]},
            {"n": 2, "titulo": "La cuota baja su saldo; el movimiento queda en la sección «Saldo a favor» del contrato",
             "mock": [
                 {"t": "row", "text": "Cuota Agosto: C$ 450 − crédito C$ 300", "right": "C$ 150"},
                 {"t": "row", "text": "Aplicado a Agosto 2026", "right": "− C$ 300"},
                 {"t": "row", "text": "Acreditado · excedente de Julio 2026", "right": "+ C$ 300"},
             ]},
        ],
        "nota": "«El crédito a favor no es un cobro: no entra a la caja ni al recaudado» (la plata "
                "entró el día que pagó de más). Por eso en la cuota aparece con candado y no se borra.",
    },
]
