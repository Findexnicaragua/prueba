# -*- coding: utf-8 -*-
"""Specs Etapa 2 (campo y operacion) — FIELES A LA APP (labels extraidos del
codigo real: cobradores_admin, cliente_detail (_RegistrarVisitaDialog),
mapa_screen, geografia_admin, planes_admin, centro_cobranza + cola_card,
avisos_screen, dashboard_admin, reportes_admin)."""

FLOWS = [
    # ═══════════════════════ COBRADORES / PERSONAL ═══════════════════════════
    {
        "id": "personal-invitar",
        "titulo": "Invitar a un miembro nuevo (cobrador, admin, técnico)",
        "rol": "solo admin",
        "pasos": [
            {"n": 1, "titulo": "Cobradores → «Invitar nuevo»",
             "mock": [
                 {"t": "appbar", "title": "Cobradores", "actions": ["Invitar nuevo"]},
                 {"t": "dialog", "title": "Invitar cobrador",
                  "body": "Se creará el usuario con una contraseña aleatoria (no se manda email — la vas a copiar y compartir vos).",
                  "items": [
                      {"t": "field", "label": "Email *", "value": "juan.lopez@ejemplo.com"},
                      {"t": "field", "label": "Nombre completo *", "value": "Juan López"},
                      {"t": "field", "label": "Teléfono", "value": "8877-1122"},
                      {"t": "field", "label": "Rol", "value": "Cobrador", "dropdown": True},
                      {"t": "field", "label": "Prefijo de recibo", "value": "JL",
                       "helper": "Si lo dejás vacío, se genera automáticamente del nombre"},
                      {"t": "label", "text": "Contraseña"},
                      {"t": "segmented", "opts": [("Generar", True), ("Escribir yo", False)]},
                  ],
                  "actions": [("Cancelar", "neutral"), ("Generar contraseña", "primary")]},
             ]},
            {"n": 2, "titulo": "Roles disponibles: Cobrador · Admin de cobranza · Administrador (+ Técnico y Admin de tickets si tu empresa tiene el módulo). El prefijo numera sus recibos (JL-000123)"},
            {"n": 3, "titulo": "La contraseña se muestra UNA SOLA VEZ — copiala y pasásela por canal seguro",
             "mock": [
                 {"t": "dialog", "title": "Credenciales de Juan López",
                  "body": "Usuario creado. Pasale email + contraseña por canal seguro — esta es la única vez que la contraseña queda visible.",
                  "items": [
                      {"t": "field", "label": "Email", "value": "juan.lopez@ejemplo.com"},
                      {"t": "field", "label": "Contraseña", "value": "Xk4-mR9-pT2"},
                  ],
                  "actions": [("Cerrar sin copiar", "neutral"), ("Copiar contraseña", "primary")]},
             ]},
        ],
        "nota": "En «Escribir yo» aparecen los campos Contraseña (mínimo 8) y Repetir contraseña "
                "y el botón pasa a decir «Crear usuario». Los roles Técnico y Admin de tickets solo "
                "se ofrecen si tu empresa tiene el módulo de tickets.",
    },
    {
        "id": "personal-editar",
        "titulo": "Editar un miembro, forzarle contraseña o desactivarlo",
        "rol": "solo admin (forzar contraseña: nunca sobre uno mismo)",
        "pasos": [
            {"n": 1, "titulo": "En la fila del miembro: lápiz «Editar»",
             "mock": [
                 {"t": "dialog", "title": "Editar cobrador",
                  "items": [
                      {"t": "field", "label": "Nombre", "value": "Juan López"},
                      {"t": "field", "label": "Teléfono", "value": "8877-1122"},
                      {"t": "field", "label": "Rol", "value": "Cobrador", "dropdown": True},
                      {"t": "field", "label": "Prefijo de recibo", "value": "JL",
                       "helper": "Para roles que cobran (cobrador / admin / cobranza). Único por empresa."},
                      {"t": "switchrow", "text": "Activo", "on": True},
                      {"t": "switchrow", "text": "Puede cambiar fecha de pago",
                       "sub": "Cobra los días puente y mueve la fecha de pago del cliente", "on": True},
                  ],
                  "actions": [("Forzar contraseña", "text"), ("Cancelar", "neutral"), ("Guardar", "primary")]},
             ]},
            {"n": 2, "titulo": "El ROL solo lo puede cambiar el dueño del sistema; el interruptor «Puede cambiar fecha de pago» aparece solo para cobrador / admin de cobranza y si tu empresa tiene esa función activa"},
            {"n": 3, "titulo": "«Forzar contraseña» genera una nueva (visible una sola vez); el usuario queda deslogueado y entra con esa",
             "mock": [
                 {"t": "dialog", "title": "Contraseña de Juan López",
                  "body": "Contraseña forzada. Pasale email + contraseña por canal seguro — el usuario quedó deslogueado y debe entrar con esta nueva.",
                  "actions": [("Cerrar sin copiar", "neutral"), ("Copiar contraseña", "primary")]},
             ]},
        ],
        "nota": "Desactivar NO borra su historial: deja de poder entrar, pero sus cobros, recibos y "
                "visitas quedan intactos. Cambios sensibles piden confirmación extra.",
    },
    {
        "id": "personal-stats",
        "titulo": "Leer la lista del personal",
        "rol": "solo admin",
        "pasos": [
            {"n": 1, "titulo": "Cada miembro que cobra muestra Prefijo, Clientes y «Cobrado este mes»",
             "mock": [
                 {"t": "tile", "avatar": "JL", "text": "Juan López", "pill": ("Cobrador", "neutral"),
                  "sub": "Prefijo JL · Clientes 120 · Cobrado este mes C$ 45,300",
                  "iconbtn": ("pencil", None), "iconbtn2": ("clock", None)},
                 {"t": "tile", "avatar": "AR", "text": "Ana Ruiz", "pill": ("Cobranza", "neutral"),
                  "sub": "Prefijo AR · Clientes 85 · Cobrado este mes C$ 31,150",
                  "iconbtn": ("pencil", None), "iconbtn2": ("clock", None)},
                 {"t": "tile", "avatar": "PM", "text": "Pedro Mora",
                  "sub": "Técnico", "pill": ("Inactivo", "neutral")},
             ]},
        ],
        "nota": "«Cobrado este mes» cuenta los pagos que ESA persona registró (no los de sus "
                "clientes asignados) — la misma cifra del reporte por cobrador. Un prefijo «— sin "
                "asignar —» sale en rojo: ese usuario no puede emitir recibos.",
    },

    # ═══════════════════════════════ VISITAS ═════════════════════════════════
    {
        "id": "visitas-registrar",
        "titulo": "Registrar una visita sin cobro",
        "rol": "cobrador y roles de cobranza (si tu empresa tiene Visitas habilitado)",
        "pasos": [
            {"n": 1, "titulo": "Cliente → pestaña «Visitas» → «Registrar visita»",
             "mock": [
                 {"t": "dialog", "title": "Registrar visita",
                  "field": "Resultado — Cobrado · No estaba · Sin pago · Promesa de pago · Otro",
                  "field2": "Notas (opcional) — Ej: promete pagar el viernes",
                  "actions": [("Cancelar", "neutral"), ("Guardar", "primary")]},
             ]},
            {"n": 2, "titulo": "Queda en el «Historial de visitas» del cliente con tu nombre y fecha",
             "mock": [
                 {"t": "label", "text": "Historial de visitas (2)"},
                 {"t": "row", "icon": "check", "text": "Promesa de pago · Juan López",
                  "sub": "07/07/2026 · hoy — promete pagar el viernes"},
                 {"t": "row", "icon": "clock", "text": "No estaba · Juan López", "sub": "01/07/2026 · hace 6 días"},
             ]},
        ],
        "nota": "Sirve para demostrar la gestión («fui 3 veces y no estaba»). Si no ves la pestaña "
                "Visitas, tu empresa no tiene la función activada. No disponible al impersonar.",
    },

    # ═══════════════════════════ MAPA Y RUTAS ════════════════════════════════
    {
        "id": "mapa-dia",
        "titulo": "Planificar el día con el mapa",
        "rol": "cobrador (su herramienta de ruta) · admin",
        "pasos": [
            {"n": 1, "titulo": "Filtrá los pins con los chips (cada estado tiene su color: mora rojo, gracia ámbar, hoy azul, próxima morado)",
             "mock": [
                 {"t": "chipbar", "chips": [("Pendientes", True), ("En mora", False), ("En gracia", False),
                                            ("Vencen hoy", False), ("Próximas", False)]},
                 {"t": "row", "icon": "search", "text": "Botón de lupa → «Nombre, cédula, teléfono o código» (enfoca el pin del cliente)"},
             ]},
            {"n": 2, "titulo": "Tocá un pin: la tarjeta del cliente con todo lo accionable",
             "mock": [
                 {"t": "tile", "avatar": "MP", "text": "María Peña Ruíz", "sub": "8836-0218 · Iglesia 1/2C Sur",
                  "btn": ("Llamar", "text")},
                 {"t": "btnrow", "buttons": [("Ruta", "neutral"), ("Ver cliente", "neutral")]},
                 {"t": "btnrow", "buttons": [("Pagar Junio · C$ 450", "primary")]},
             ]},
            {"n": 3, "titulo": "Botones flotantes: centrar en mi ubicación · buscar cliente · ver satélite/calles. El mapa guarda las zonas vistas para funcionar sin internet"},
        ],
        "nota": "Si el contrato tiene varias cuotas cobrables, el botón dice «Pagar cuota (N "
                "servicios)» y te deja elegir cuál. «Cambiar fecha de pago» aparece si tenés el "
                "permiso.",
    },
    {
        "id": "mapa-ruta",
        "titulo": "Trazar la ruta hasta un cliente",
        "rol": "cobrador · admin",
        "pasos": [
            {"n": 1, "titulo": "En la tarjeta del pin tocá «Ruta»: la app dibuja el camino — SIN internet",
             "mock": [
                 {"t": "row", "icon": "pin", "text": "Ruta a: María Peña Ruíz", "right": "3.2 km · 9 min",
                  "iconbtn": ("ban", None)},
                 {"t": "btnrow", "buttons": [("Abrir en Google Maps", "neutral")]},
             ]},
            {"n": 2, "titulo": "¿Preferís el navegador del teléfono? «Abrir en Google Maps» lanza la navegación externa a esas coordenadas"},
        ],
    },
    {
        "id": "mapa-admin",
        "titulo": "El mapa del admin (supervisión)",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Además de los chips, filtros por Cobrador, Zona y Nodo — y el chip «Ver todo»",
             "mock": [
                 {"t": "field", "label": "Cobrador", "value": "Juan López", "dropdown": True},
                 {"t": "field", "label": "Zona", "value": "La Barrera", "dropdown": True},
                 {"t": "field", "label": "Nodo", "value": "—", "dropdown": True},
                 {"t": "row", "text": "El chip «Ver todo» (en la fila de estados) muestra también a los que están al día."},
             ]},
        ],
        "nota": "El filtro de Cobrador incluye «Sin cobrador»: los clientes que nadie visita en "
                "ruta porque no tienen cobrador asignado.",
    },

    # ═══════════════════════════ GEOGRAFÍA ═══════════════════════════════════
    {
        "id": "geografia-crud",
        "titulo": "Armar el catálogo geográfico (departamento → municipio → comunidad)",
        "rol": "solo admin",
        "pasos": [
            {"n": 1, "titulo": "Administración → Geografía: árbol expandible — «Departamento» arriba, y dentro de cada nivel su botón de agregar",
             "mock": [
                 {"t": "row", "icon": "pin", "text": "Chinandega", "iconbtn": ("chevron", None)},
                 {"t": "row", "text": "   └ Somotillo", "iconbtn": ("chevron", None)},
                 {"t": "row", "text": "        └ La Barrera"},
                 {"t": "row", "icon": "plus", "text": "Agregar comunidad"},
             ]},
            {"n": 2, "titulo": "Cada alta es un diálogo simple con el nombre",
             "mock": [
                 {"t": "dialog", "title": "Nueva comunidad",
                  "field": "Nombre — El Espino",
                  "actions": [("Cancelar", "neutral"), ("Agregar", "primary")]},
             ]},
            {"n": 3, "titulo": "El menú de cada fila: Editar · Historial · Eliminar. Borrar solo se puede si NO está en uso",
             "mock": [
                 {"t": "row", "text": "«No se puede eliminar: está en uso (12).»", "pill": ("12 clientes", "danger")},
             ]},
        ],
        "nota": "«Crece con uso — sólo agregá lo que necesités.» Las comunidades aparecen al crear "
                "clientes y como filtro de Zona en el mapa, las listas y los reportes.",
    },

    # ═════════════════════════════ PLANES ════════════════════════════════════
    {
        "id": "planes-crud",
        "titulo": "Planes de servicio: crear, editar precio y desactivar",
        "rol": "solo admin",
        "pasos": [
            {"n": 1, "titulo": "Administración → Planes → «Nuevo plan»",
             "mock": [
                 {"t": "dialog", "title": "Nuevo plan",
                  "field": "Nombre * — Ej. Internet 10MB · Tipo — Internet · TV · Combo",
                  "field2": "Precio mensual (C$) * — 450",
                  "actions": [("Cancelar", "neutral"), ("Guardar", "primary")]},
             ]},
            {"n": 2, "titulo": "La lista muestra cuántos contratos activos usa cada plan",
             "mock": [
                 {"t": "tile", "avatar": "IN", "text": "Básico 10 Mbps",
                  "sub": "internet · 38 contrato(s) activo(s)", "right": "C$ 450",
                  "iconbtn": ("pencil", None), "iconbtn2": ("clock", None)},
                 {"t": "tile", "avatar": "IN", "text": "Premium 20 Mbps",
                  "sub": "internet · 12 contrato(s) activo(s)", "right": "C$ 700",
                  "iconbtn": ("pencil", None), "iconbtn2": ("clock", None)},
             ]},
            {"n": 3, "titulo": "Desactivar («No aparecerá al crear nuevos contratos»): los vigentes siguen igual. Subir el precio tampoco toca las cuotas ya generadas",
             "mock": [
                 {"t": "switchrow", "text": "Activo", "on": False},
             ]},
        ],
        "nota": "Sin al menos un plan activo no se pueden crear contratos. Para actualizar el "
                "precio a un cliente puntual usá «Cambiar plan» en su contrato. El precio queda en "
                "el historial del plan (es dato de dinero).",
    },

    # ═══════════════════════ CENTRO DE COBRANZA ══════════════════════════════
    {
        "id": "centro-dia",
        "titulo": "El Centro de cobranza: qué atiendo hoy",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Las 4 métricas del día",
             "mock": [
                 {"t": "row", "text": "Vencen hoy", "right": "C$ 12,450", "pill": ("8 clientes", "primary")},
                 {"t": "row", "text": "En mora", "right": "C$ 38,200", "pill": ("23 clientes", "danger")},
                 {"t": "row", "text": "A suspender", "right": "4", "pill": ("ya cortados", "warn")},
                 {"t": "row", "text": "A favor", "right": "C$ 1,850", "pill": ("3 clientes", "success")},
             ]},
            {"n": 2, "titulo": "Abajo, tres secciones de colas: Cobrar · Servicio · Créditos — cada card te lleva a donde se actúa",
             "mock": [
                 {"t": "row", "text": "En mora — avisar", "sub": "Clientes vencidos pasada la gracia.",
                  "btn": ("Ver en Avisos", "text")},
                 {"t": "row", "text": "Ya cortados — falta suspender el contrato",
                  "sub": "El técnico cortó pero el contrato sigue facturándose.",
                  "btn": ("Ver contrato", "text")},
                 {"t": "row", "text": "Créditos a favor sin aplicar",
                  "sub": "Pagaron de más — aplicá al saldo o devolvé.", "btn": ("Ver cliente", "text")},
             ]},
        ],
        "nota": "El Centro no toca dinero por sí solo: solo te dice QUÉ atender y te lleva ahí. "
                "«Ya cortados» se alimenta de las órdenes de corte de tickets — sin ese módulo la "
                "cola queda vacía y la suspensión se hace manual desde el contrato.",
    },
    # ═══════════════════════ AVISOS / WHATSAPP ═══════════════════════════════
    {
        "id": "avisos-notificar",
        "titulo": "Avisar por WhatsApp a los clientes en gracia o mora",
        "rol": "admin / admin de cobranza (si tu empresa tiene Avisos habilitado)",
        "pasos": [
            {"n": 1, "titulo": "Cobranza → Avisos: dos secciones — «Próximos a corte — en gracia» y «En mora — corte»",
             "mock": [
                 {"t": "twobox",
                  "a": {"label": "PRÓXIMOS A CORTE", "l1": "C$ 3,150", "l2": "7 clientes"},
                  "b": {"label": "EN MORA", "l1": "C$ 38,200", "l2": "23 clientes", "tint": "danger"}},
                 {"t": "row", "text": "En mora — corte", "btn": ("Notificar a todos (23)", "success")},
                 {"t": "cardrow", "texto": "CL0102 · María Peña Ruíz", "color": "danger",
                  "sub": "La Barrera · Somotillo · 8836-0218", "badge": ("en mora hace 12 día(s)", "danger"),
                  "saldo": "C$ 450", "btns": [("Orden de corte", "neutral"), ("WhatsApp", "success")]},
             ]},
            {"n": 2, "titulo": "«WhatsApp» abre el chat con el mensaje YA escrito (tu plantilla con nombre y monto) — solo tocás enviar. En mora además: «Orden de corte» (crea el ticket precargado)",
             "mock": [
                 {"t": "row", "text": "«Hola María, su cuota de junio (C$ 450) está vencida hace 12 días…»",
                  "pill": ("plantilla editable", "primary")},
                 {"t": "btnrow", "buttons": [("Orden de corte", "neutral")]},
             ]},
            {"n": 3, "titulo": "«Notificar a todos» te guía uno por uno",
             "mock": [
                 {"t": "row", "text": "Cliente 1 de 23", "btn": ("Enviar por WhatsApp y siguiente", "success")},
                 {"t": "btnrow", "buttons": [("Saltar este cliente", "text")]},
             ]},
        ],
        "nota": "El envío es manual y gratis. Las plantillas (gracia y mora) se editan en "
                "Configuración → Cobranza → «Mensajes de WhatsApp (Avisos)» con variables de "
                "nombre, monto, días y empresa.",
    },

    # ═══════════════════ REPORTES / ARQUEO / DASHBOARD ═══════════════════════
    {
        "id": "dashboard-kpis",
        "titulo": "El Resumen (dashboard): la foto del mes en vivo",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "KPIs de cobros en vivo",
             "mock": [
                 {"t": "row", "text": "Hoy", "right": "C$ 8,320", "pill": ("12 cobros", "neutral")},
                 {"t": "row", "text": "Esta semana", "right": "C$ 41,900", "pill": ("58 cobros", "neutral")},
                 {"t": "row", "text": "Este mes", "right": "C$ 152,400", "pill": ("214 cobros", "primary")},
             ]},
            {"n": 2, "titulo": "Y las tarjetas operativas: «Proyección de cobros por cobrador», «Recuperación por cobrador y comunidad», «Top cobradores (este mes)», «Distribución de cuotas» (Al día · En gracia · Vencidas · Pagadas)"},
        ],
        "nota": "Qué tarjetas ves depende de la configuración de tu empresa. «Cobrado» siempre "
                "cuenta por quién REGISTRÓ el pago.",
    },
    {
        "id": "reportes-generar",
        "titulo": "Generar y descargar un reporte",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Reportes → dos filtros arriba: el rango («Filtra por fecha de cobro») y los cobradores",
             "mock": [
                 {"t": "row", "text": "Rango de reportes descargables", "sub": "Este mes · 01/07/2026 – 31/07/2026",
                  "btn": ("Cambiar", "neutral")},
                 {"t": "row", "text": "Cobradores en los reportes", "sub": "Todos los cobradores · Filtra por quién cobró.",
                  "btn": ("Cambiar", "neutral")},
             ]},
            {"n": 2, "titulo": "«Generar reporte» → elegí tipo y formato",
             "mock": [
                 {"t": "dialog", "title": "Generar reporte",
                  "body": "Tipo: Reporte de cobranza · Cobros del período · Cobros por cobrador · Arqueo / cierre de caja · Fiscal / contable · Eficiencia por cobrador · Anulaciones · Mora · Estado de clientes · Clientes inactivos · Padrón de clientes",
                  "field": "Formato — Excel | PDF",
                  "actions": [("Cancelar", "neutral"), ("Generar", "primary")]},
             ]},
            {"n": 3, "titulo": "El «Reporte de cobranza» (Excel) lista cada pago: ID, cliente, cobrador, mes, FECHA DE COBRO, recibo y montos C$/US$ con totales"},
        ],
        "nota": "Presets del rango: Hoy · Ayer · Este mes · Mes pasado · Personalizado. Los tipos "
                "detallados aparecen si tu empresa los tiene activados; el de cobranza está siempre.",
    },
    {
        "id": "reportes-arqueo",
        "titulo": "Cuadrar la caja con el arqueo",
        "rol": "admin / admin de cobranza",
        "pasos": [
            {"n": 1, "titulo": "Generá «Arqueo / cierre de caja» del rango: el PDF desglosa POR COBRADOR lo que debe entregar",
             "mock": [
                 {"t": "label", "text": "ARQUEO — JUAN LÓPEZ · EFECTIVO (caja física)"},
                 {"t": "row", "text": "Córdobas recibidos", "right": "C$ 45,300"},
                 {"t": "row", "text": "(−) Vuelto entregado", "right": "C$ 1,150"},
                 {"t": "row", "text": "(−) Devoluciones de saldo a favor", "right": "C$ 300"},
                 {"t": "row", "text": "Neto a entregar", "right": "C$ 43,850", "pill": ("lo que entrega", "success")},
             ]},
            {"n": 2, "titulo": "Compará el total por cobrador contra lo que cada uno entrega físicamente"},
        ],
        "nota": "Los créditos a favor APLICADOS no aparecen en el arqueo: no son plata que entró "
                "ese día (entró cuando el cliente pagó de más). Ver módulo Saldo a favor.",
    },
]
