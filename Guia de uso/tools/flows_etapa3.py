# -*- coding: utf-8 -*-
"""Specs Etapa 3 (opcionales + configuracion) — FIELES A LA APP (labels del
codigo real: red_admin, settings_admin + recibo_layout_editor).

Inventario, Tickets e Incidentes se quitaron de la guia de USUARIO: existen en
el codigo pero no se ofrecen como modulos. La arquitectura si los documenta."""

FLOWS = [
    # ═══════════════════════════ RED / TOPOLOGÍA ═════════════════════════════
    {
        "id": "red-topologia",
        "titulo": "Armar la topología de red y conectar a los clientes",
        "rol": "armar: admin / admin de cobranza · el cobrador la ve en la ficha del cliente",
        "pasos": [
            {"n": 1, "titulo": "Administración → Red: «Topología de red (Nodo → Hub → Puerto)» — árbol expandible con «Agregar hub» / «Agregar puerto» en cada nivel",
             "mock": [
                 {"t": "row", "icon": "pin", "text": "Nodo Centro", "iconbtn": ("chevron", None)},
                 {"t": "row", "text": "   └ Hub 2", "iconbtn": ("chevron", None)},
                 {"t": "row", "text": "        └ Puerto 5"},
                 {"t": "row", "icon": "plus", "text": "Agregar puerto"},
             ]},
            {"n": 2, "titulo": "El nodo lleva tipo (Fibra · Wireless · Híbrido), notas y su ubicación («Elegir en el mapa»)",
             "mock": [
                 {"t": "dialog", "title": "Nuevo nodo",
                  "items": [
                      {"t": "field", "label": "Nombre", "value": "Nodo Centro"},
                      {"t": "field", "label": "Tipo (opcional)", "value": "Fibra", "dropdown": True},
                      {"t": "field", "label": "Notas (opcional)", "value": "Ej. torre detrás de la iglesia"},
                      {"t": "field", "label": "Latitud", "value": "13.04218"},
                      {"t": "field", "label": "Longitud", "value": "-86.90557"},
                      {"t": "btnrow", "buttons": [("Elegir en el mapa", "neutral")]},
                  ],
                  "actions": [("Cancelar", "neutral"), ("Guardar", "primary")]},
             ]},
            {"n": 3, "titulo": "El puerto se asigna al cliente desde SU ficha (sección «Conexión de red»). ¿Para qué? Incidentes deriva los afectados, y el técnico/cobrador ve dónde está conectado"},
        ],
        "nota": "Borrar está bloqueado si el nivel está en uso: «No se puede eliminar: está en uso "
                "(N).» (nodo con hubs, hub con puertos, puerto con clientes).",
    },

    # ═══════════════════════════ CONFIGURACIÓN ═══════════════════════════════
    {
        "id": "settings-empresa",
        "titulo": "Configuración → Empresa (identidad del ISP)",
        "rol": "solo admin",
        "pasos": [
            {"n": 1, "titulo": "Logo + «Datos de la empresa»",
             "mock": [
                 {"t": "field", "label": "Nombre comercial", "value": "Telecable Mairena S.A."},
                 {"t": "field", "label": "Dirección", "value": "Somotillo, Chinandega"},
                 {"t": "field", "label": "Teléfono", "value": "8877-0000"},
                 {"t": "field", "label": "RUC", "value": "J031000000xxxx"},
                 {"t": "field", "label": "WhatsApp", "value": "8877-0000"},
             ]},
            {"n": 2, "titulo": "¿A qué afecta? Al encabezado del RECIBO (térmica y PDF) y a los REPORTES exportados (salen con el logo y estos datos)"},
        ],
    },
    {
        "id": "settings-cobranza",
        "titulo": "Configuración → Cobranza (reglas, permisos, colores y mensajes)",
        "rol": "solo admin",
        "pasos": [
            {"n": 1, "titulo": "«Reglas de cobro»",
             "mock": [
                 {"t": "row", "text": "Días de gracia", "right": "10", "pill": ("afecta: mora, Avisos, badges", "primary")},
                 {"t": "row", "text": "Días de cuotas próximas", "right": "5", "pill": ("afecta: Por cobrar, mapa", "primary")},
             ]},
            {"n": 2, "titulo": "«Permisos»",
             "mock": [
                 {"t": "switchrow", "text": "Cobrador puede editar fecha", "on": False},
                 {"t": "switchrow", "text": "Admin cobranza ve historial de cambios", "on": True},
             ]},
            {"n": 3, "titulo": "«Colores de estados de cuota» — «Se aplican en el mapa y en los badges de cuotas» (En mora · En gracia · Vence hoy · Próxima)"},
            {"n": 4, "titulo": "«Mensajes de WhatsApp (Avisos)»: editor con variables y vista previa",
             "mock": [
                 {"t": "dialog", "title": "Editar mensaje",
                  "body": "Variables: Nombre {nombre} · Monto {monto} · Días {dias} · Empresa {empresa} — con vista previa del WhatsApp y «Restaurar mensaje por defecto».",
                  "field": "Mensaje — Hola {nombre}, su cuota ({monto}) está vencida hace {dias} días…",
                  "actions": [("Guardar", "primary")]},
             ]},
        ],
    },
    {
        "id": "settings-pagos",
        "titulo": "Configuración → Pagos (métodos y dólar)",
        "rol": "solo admin (la tasa también la puede editar el admin de cobranza)",
        "pasos": [
            {"n": 1, "titulo": "«Métodos de pago» — el efectivo es fijo; transferencia y tarjeta se prenden acá",
             "mock": [
                 {"t": "switchrow", "text": "Aceptar efectivo   (método por defecto, siempre activo)", "on": True},
                 {"t": "switchrow", "text": "Aceptar transferencia", "on": True},
                 {"t": "switchrow", "text": "Aceptar tarjeta", "on": False},
             ]},
            {"n": 2, "titulo": "«Dólares»: el toggle revela la tasa",
             "mock": [
                 {"t": "switchrow", "text": "Aceptar pagos en USD", "on": True},
                 {"t": "field", "label": "Tasa USD → C$", "value": "36.50"},
                 {"t": "row", "text": "Cada cobro en USD guarda la tasa vigente en ese momento",
                  "pill": ("afecta: cobro, recibo, reportes", "primary")},
             ]},
        ],
        "nota": "Actualizá la tasa con regularidad: la tasa del momento queda para siempre en el "
                "recibo y los reportes de ese pago.",
    },
    {
        "id": "settings-recibos",
        "titulo": "Configuración → Recibos (el diseñador del comprobante)",
        "rol": "solo admin — con vista previa en vivo",
        "pasos": [
            {"n": 1, "titulo": "«Ajustes generales»: papel, título y pie",
             "mock": [
                 {"t": "field", "label": "Ancho de papel", "value": "80 mm (estándar) · 58 mm"},
                 {"t": "field", "label": "Título del recibo", "value": "RECIBO, COBRO…"},
                 {"t": "field", "label": "Pie del recibo", "value": "¡Gracias por su pago!"},
             ]},
            {"n": 2, "titulo": "Los bloques se arrastran entre ENCABEZADO · CUERPO · PIE, con tamaño y visibilidad por bloque",
             "mock": [
                 {"t": "switchrow", "text": "Logo · Datos de la empresa · Cliente · Montos de la cuota…", "on": True},
                 {"t": "row", "text": "«Totales (cobrado / vuelto / pagado)»", "pill": ("no se puede ocultar", "neutral")},
             ]},
            {"n": 3, "titulo": "Sub-opciones del contenido",
             "mock": [
                 {"t": "switchrow", "text": "Mostrar cédula", "on": True},
                 {"t": "switchrow", "text": "Mostrar saldo pendiente", "on": True},
                 {"t": "switchrow", "text": "Mostrar descuentos y cargos", "on": True},
                 {"t": "switchrow", "text": "Mostrar motivos", "on": False},
             ]},
        ],
        "nota": "Afecta a TODOS los recibos desde ese momento (los ya emitidos no cambian). "
                "«Restaurar layout por defecto» vuelve al diseño original.",
    },
]
