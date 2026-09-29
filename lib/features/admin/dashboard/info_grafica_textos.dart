import 'info_grafica.dart';

/// Textos del (i) de cada gráfica del dashboard. Fuente única — se importan
/// desde `tendencia_cobros_card.dart` (Cobros, Mora) y `dashboard_admin_screen.dart`
/// (el resto). Redacción aprobada por Rubén (2026-08-01). El ORDEN de secciones
/// refleja el modelo de dinero: caja (por fecha_pago) vs cobertura (por
/// vencimiento) vs mora vs foto-de-ahora (ver AGENTS §invariantes #4).

// ── 🟢 CAJA (plata que entró, por fecha de pago) ──

const kInfoCobrosKpis = InfoGrafica(
  titulo: 'Caja del ciclo',
  eje: 'Eje: caja. La plata que ENTRÓ, por fecha de pago. Todo cobro cuenta, '
      'sea de la cuota del mes, de una atrasada o de una adelantada. Es la '
      'plata real que se recibió, no lo facturado.',
  opciones: [
    InfoOpcion('El rótulo ▾ de cada bloque',
        'Cambia SÓLO la ventana de ese bloque. Los tres son independientes: '
            'se puede mirar el martes pasado, la semana antepasada y el ciclo '
            'de hace tres meses al mismo tiempo. Cada opción del menú muestra '
            'su monto al costado, así se elige sabiendo qué se va a ver.'),
    InfoOpcion('Día',
        'Los últimos 7 días, uno por uno. Los días sin cobros aparecen igual, '
            'con un guion: esconderlos haría creer que falta información.'),
    InfoOpcion('Semana',
        'Las últimas 6 semanas. La semana va de DOMINGO a sábado: el sábado a '
            'medianoche vuelve a cero y arranca la nueva.'),
    InfoOpcion('Período',
        'Los últimos 6 ciclos. El ciclo va del 15 al 14 del mes siguiente.'),
    InfoOpcion('Tocar el cuerpo de un bloque',
        'Elige cuál de los tres alimenta el desglose de abajo. El bloque '
            'elegido queda pintado.'),
  ],
  incluye: [
    'Todos los pagos no anulados y no en revisión con fecha de pago dentro de '
        'la ventana',
    'De cualquier cuota y cualquier contrato, incluso suspendido o cancelado: '
        'si la plata entró, entró',
    'Los cobros puntuales, que no cuelgan de ninguna cuota',
  ],
  noIncluye: [
    'Pagos anulados y pagos en revisión (cobros duplicados en cuarentena)',
    'Lo facturado que todavía no se cobró: eso es "Cobertura del ciclo"',
  ],
  nota: 'El conteo son CUOTAS distintas, no filas de pagos: dos abonos a la '
      'misma cuota son un cobro para el negocio.\n\n'
      'El desglose de abajo clasifica la plata según a qué ciclo pertenecía la '
      'CUOTA que se pagó, y lo hace contra el ciclo de la ventana elegida — no '
      'contra el ciclo actual. Mirando "15 jun – 14 jul", sus propias cuotas '
      'salen como "del ciclo"; si se comparara contra el ciclo en curso, '
      'aparecerían todas como atrasos.\n\n'
      '"Hoy" puede ser mayor que el "Del día" de la gráfica de Cobertura: esa '
      'sólo cuenta lo que cubre ESE ciclo; un cobro de hoy sobre una cuota de '
      'otro mes suma acá pero no allá.',
);

const kInfoConsultarPeriodo = InfoGrafica(
  titulo: 'Consultar período',
  eje: 'Eje: caja. La plata que ENTRÓ en el rango que elijas, por fecha de '
      'pago. Cuenta todo cobro (del mes, atrasado o adelantado).',
  opciones: [
    InfoOpcion('Este período', 'Del 15 a hoy. Lo que llevás cobrado en el ciclo en curso.'),
    InfoOpcion('Período pasado',
        'El ciclo 15→14 anterior, completo. Para comparar contra el mes cerrado.'),
    InfoOpcion('Rango libre',
        'Las fechas exactas que toques en el calendario. Se aplica al instante.'),
  ],
  incluye: [
    'Todos los pagos no anulados con fecha de pago dentro del rango',
    'De cualquier cuota y cualquier contrato, incluso suspendido',
  ],
  noIncluye: [
    'Pagos anulados',
    'No mira vencimientos: no es lo mismo que "Recuperado" de las gráficas de '
        'tendencia (esas miden cobertura de lo que vence en el período)',
  ],
);

const kInfoSparkline7d = InfoGrafica(
  titulo: 'Cobros últimos 7 días',
  eje: 'Eje: caja. Total cobrado por día (por fecha de pago) en los últimos 7 '
      'días. Ventana fija, sin opciones.',
  incluye: [
    'Pagos no anulados de los últimos 7 días',
  ],
  noIncluye: [
    'Pagos anulados',
    'No mira vencimientos ni suspendidos (es caja pura)',
  ],
);

const kInfoTopCobradores = InfoGrafica(
  titulo: 'Quién cobró',
  eje: 'Eje: caja por QUIÉN cobró — el usuario que registró el pago, no el '
      'cobrador asignado del cliente. Lista a todos los que cobraron algo en '
      'la ventana elegida.',
  opciones: [
    InfoOpcion('Solo hoy', 'Cobros registrados hoy, desde la medianoche de '
        'Nicaragua.'),
    InfoOpcion('Ciclo', 'Cobros registrados desde el 15 del mes pasado. Es la '
        'misma ventana que usan el resto de las tarjetas.'),
  ],
  incluye: [
    'Pagos no anulados y no en revisión, agrupados por quien los registró — '
        'toda la oficina, no solo el rol cobrador',
  ],
  noIncluye: [
    'Pagos anulados y pagos en revisión (cobros duplicados en cuarentena)',
    'Quien no cobró nada en la ventana: no se lista en cero',
  ],
  nota: 'Reasignar un cliente a otro cobrador NO cambia este histórico: cuenta '
      'quien cobró, no quien tiene asignado al cliente.\n\n'
      'En un día sin cobros la lista sale vacía y lo dice con todas las '
      'letras. Es lo normal, no un error de la app.',
);

// ── 🔵 COBERTURA (cuánto de lo facturado se recuperó, por vencimiento) ──

const kInfoCobrosDelMes = InfoGrafica(
  titulo: 'Cobertura del ciclo',
  eje: 'Eje: cobertura. Cuánto de lo facturado de este período ya se recuperó. '
      'Agrupa por la fecha en que VENCE la cuota, no por cuándo se pagó.',
  opciones: [
    InfoOpcion('◀ ▶ Cambiar de período',
        'Movés entre ciclos 15→14. El período EN CURSO dibuja la curva solo '
            'hasta hoy (se va llenando); los CERRADOS muestran el ciclo completo '
            'y la curva llega al total.'),
    InfoOpcion('Descargar el detalle',
        'Baja a Excel una fila por cada cuota de este ciclo, agrupada por '
            'CUÁNDO entró su plata — los mismos tres grupos de la tabla, y el '
            'subtotal de cada uno es esa sub-fila. Trae además dos columnas '
            'que en pantalla no están: "Días" (si pagó adelantado, en gracia o '
            'tarde) y "Cuándo entró". El total del archivo TIENE que dar igual '
            'que el de la tarjeta: si no da, reportalo.'),
  ],
  incluye: [
    'Cuotas que vencen del 15 al 14 (el período mostrado)',
    'Pagos aplicados a esas cuotas, en la fecha que se hayan pagado',
    'Contratos suspendidos y cancelados: lo que ya pagaron sigue siendo plata '
        'que entró, y su deuda vieja sigue siendo cobrable. Un ciclo cerrado '
        'no cambia porque hoy suspendas a alguien',
  ],
  noIncluye: [
    'Cuotas o pagos anulados',
    'Pagos de este período sobre cuotas de otro mes (cuentan en su propio mes)',
  ],
  nota: 'QUÉ CUOTA ENTRA. La que VENCE entre el 15 y el 14, sin importar '
      'cuándo se pagó. Una cobrada por adelantado cuenta igual.'
      '\n\n'
      'POR QUÉ HAY MÁS CUOTAS QUE CLIENTES. Un cliente puede tener dos '
      'contratos (dos servicios en la misma casa) o un cobro puntual '
      '(instalación, reconexión, multa): cada uno factura por su cuenta.'
      '\n\n'
      'LAS TRES FILAS. "Cobros" es todo lo del ciclo; "Recuperado" y "Por '
      'recuperar" lo parten en dos, así que conteos y montos suman.'
      '\n\n'
      'EL MONTO DE "RECUPERADO" NO ES EL DE SUS CUOTAS. Las cuotas '
      'contadas son las SALDADAS; el monto incluye además lo abonado a '
      'cuotas que siguen en "Por recuperar". Por eso los montos cierran y '
      'los conteos no se pisan.'
      '\n\n'
      'LAS SUB-FILAS DE "RECUPERADO" dicen CUÁNDO entró esa plata, y son '
      'las tres partes de la curva de abajo: "antes del ciclo" es la '
      'altura en que arranca, "en el ciclo" lo que sube, "después" el '
      'salto del último punto. Suman el Recuperado exacto. Van sin '
      'conteo de cuotas porque una cuota puede cobrarse a medias o '
      'saldarse con un crédito, y entonces el conteo y la plata '
      'dejarían de ser la misma gente.'
      '\n\n'
      'LAS SUB-FILAS DE "POR RECUPERAR". "ya vencidas" es la parte que '
      'ya quemó la gracia: eso es lo accionable. "con abono parcial" '
      'son las que YA RECIBIERON algo y siguen debiendo — esa plata '
      'está contada arriba en Recuperado, y la cuota acá. Es la única '
      'que aparece en los dos lados, y por eso se dice.'
      '\n\n'
      'LA MORA CRECE MIENTRAS EL CICLO AVANZA. Cada cliente vence en su '
      'día: una cuota del 15 lleva casi un mes vencida cuando la del 14 '
      'ni venció.'
      '\n\n'
      'LAS ANULADAS NO CUENTAN en ninguna fila. El botón de descarga las '
      'lista aparte, en la hoja "Excluidas", con su motivo.'
      '\n\n'
      'UN CICLO CERRADO PUEDE SEGUIR SUBIENDO: si alguien paga hoy una '
      'cuota de junio, suma al ciclo de junio. Por eso este número no '
      'cuadra contra la caja del día ni contra el arqueo: mide otra cosa.',
);

const kInfoMora = InfoGrafica(
  titulo: 'Mora del ciclo',
  eje: 'Eje: la mora de UN ciclo, con los últimos 6 arriba como contexto. '
      'De todo lo que venció y pasó los días de gracia en ese ciclo, cuánto se '
      'recuperó tarde y cuánto sigue impago. La barra entera es la mora del '
      'ciclo y el verde es lo que ya se recuperó de ella.',
  opciones: [
    InfoOpcion('◀ ▶ Cambiar de ciclo',
        'Cambia la TABLA de abajo. La gráfica no se mueve: muestra siempre los '
            'últimos 6 ciclos, y el recuadro marca cuál estás mirando. Si '
            'retrocedés más allá de los 6, la tabla sigue yendo hacia atrás y '
            'la gráfica se queda sin recuadro — estás fuera de la ventana.'),
    InfoOpcion('Clic en una barra',
        'Salta a ese ciclo. Es lo mismo que llegar con las flechas.'),
    InfoOpcion('Pasar el mouse por una barra',
        'Muestra las mismas cifras que la fila de la tabla de ese ciclo. El '
            'globo no calcula nada aparte: lee la misma consulta, así que no '
            'pueden discrepar ni por redondeo.'),
    InfoOpcion('La flecha ▸ de una fila',
        'Abre el desglose. Aparece SOLO cuando hay dos o más categorías que '
            'mostrar: si toda la plata recuperada entró dentro del ciclo, no '
            'hay nada que abrir y la flecha no está.'),
    InfoOpcion('La barra rayada',
        'Es el ciclo EN CURSO. Su porcentaje bajo no es un mal resultado: le '
            'faltan semanas de cobro. Comparar un ciclo a medias contra ciclos '
            'cerrados es comparar cosas distintas.'),
  ],
  incluye: [
    'Cuotas vencidas del ciclo que ya cruzaron los días de gracia',
    'Tanto las impagas como las que se pagaron tarde (recuperadas)',
    'Contratos suspendidos: su deuda vieja sigue siendo cobrable',
  ],
  noIncluye: [
    'Cuotas pagadas a tiempo o dentro de la gracia (nunca estuvieron en mora)',
    'Cuotas o pagos anulados, y los pagos en revisión',
    'Contratos cancelados: cancelar condona la deuda, así que sus cuotas '
        'quedan en cero y salen de la mora',
  ],
  nota: 'Cómo leer la tabla: las dos filas de abajo SUMAN la de arriba. '
      'Recuperado + Por recuperar = Total en mora, tanto en cuotas como en '
      'monto, y los dos porcentajes suman 100. Si abrís un desglose, sus '
      'líneas suman la fila de la que cuelgan.\n\n'
      'Una excepción posible: una cuota con un abono parcial cobrado TARDE '
      'está en las dos filas a la vez (recuperó algo y todavía debe). Ahí los '
      'conteos suman uno de más — la plata sigue cerrando. Hoy no pasa en '
      'ninguna empresa.\n\n'
      'El "Recuperado" de esta tarjeta YA está contado dentro del '
      '"Recuperado" de Cobertura del ciclo: es la misma plata vista de otra '
      'forma, no se suma aparte. Sumarlas fue exactamente lo que hizo que los '
      'números no cerraran la primera vez.\n\n'
      'El Excel baja los 6 ciclos con una columna "Ciclo", otra "Fila de la '
      'tarjeta" y otra "Detalle": filtrando por ellas salen exactamente los '
      'mismos conteos que ves acá.',
);

// ── 🔴 Lo que FALTA / proyección ──

const kInfoProyeccion = InfoGrafica(
  // El título del globo tiene que decir lo mismo que el de la tarjeta.
  titulo: 'Proyección de cobros por cobrador',
  eje: 'Eje: lo que se DEBE cobrar de hoy en adelante, por cobrador asignado. '
      'Contesta "a quién mando a cobrar esta semana", no "cuánto me deben".',
  opciones: [
    // 🔴 Acá decía "La flecha ▸ de un cobrador", que era el desplegable de la
    // versión de tabla. Esa versión se retiró el 2026-09-02 al volver al estilo
    // de producción, y con ella la flecha: el globo quedó explicando un control
    // que ya no está en la pantalla. El control real es el interruptor.
    InfoOpcion('Incluir cuotas próximas',
        'Apagado, la tarjeta muestra sólo lo que vence HOY. Prendido, le suma '
            'lo que vence dentro de los próximos días configurados '
            '(Ajustes → días de cuotas visibles).'),
    InfoOpcion('El largo de cada barra',
        'Es proporcional al cobrador que MÁS tiene, no al total: sirve para '
            'comparar entre cobradores, no para leer un porcentaje.'),
  ],
  incluye: [
    'Cuotas pendientes y parciales que vencen HOY o dentro de los próximos '
        'días configurados (Ajustes → días de cuotas visibles)',
    'Sólo clientes y contratos ACTIVOS',
    'Los clientes SIN cobrador asignado, como fila propia: son cartera que '
        'sólo ven admin y admin_cobranza',
  ],
  noIncluye: [
    'Lo YA VENCIDO. Esta tarjeta mira hacia adelante a propósito: lo atrasado '
        'vive en "Mora del ciclo" y en "Recuperación por cobrador y comunidad"',
    'Contratos suspendidos: acá se pronostica a quién visitar, y a un contrato '
        'sin servicio no se lo visita por su cuota nueva',
    'Contratos cancelados (cancelar condona: no dejan nada pendiente)',
  ],
  nota: 'El total de esta tarjeta NO es la deuda de la empresa: es sólo lo que '
      'está por vencer. Si querés el total adeudado, mirá "Recuperación por '
      'cobrador y comunidad".',
);

const kInfoRecuperacion = InfoGrafica(
  // El título del globo TIENE que decir lo mismo que el título de la tarjeta:
  // si no, el usuario toca la (i) y lee el nombre de otra cosa. Volvió a
  // "Recuperación" el 2026-09-02 con la tarjeta.
  titulo: 'Recuperación por cobrador y comunidad',
  eje: 'Eje: la MORA — lo que venció, pasó los días de gracia y sigue impago —, '
      'repartida por cobrador asignado y por comunidad. Sirve para ver dónde '
      'está concentrada y a quién mandar a qué zona.',
  opciones: [
    InfoOpcion('Toda la mora',
        'Todo lo vencido pasada la gracia, sin límite de fecha. Es lo que el '
            'equipo sale a cobrar.'),
    InfoOpcion('La flecha ▸ de una comunidad',
        'Abre DE CUÁNTO son las cuotas: "C\$900 × 3 cuotas". Sirve para saber '
            'si la deuda de una zona son pocas cuotas caras o muchas baratas, '
            'que se cobran distinto. Debajo, una línea confirma que el '
            'desglose suma la comunidad.'),
    InfoOpcion('Vencidas del ciclo',
        'Sólo la mora de cuotas que vencieron dentro del ciclo en curso. '
            'Sirve para ver cómo viene el mes, sin el arrastre de los '
            'anteriores.'),
    InfoOpcion('La flecha ▸ de un cobrador',
        'Abre sus comunidades, de mayor a menor deuda. Aparece sólo si tiene '
            'más de una: con una sola, abrirla repetiría la fila de arriba.'),
  ],
  incluye: [
    'Cuotas pendientes y parciales de clientes activos que YA pasaron los días '
        'de gracia. Lo que todavía no venció, o está dentro de la gracia, NO '
        'es mora y no entra',
    'Contratos SUSPENDIDOS: suspender corta el servicio pero conserva la '
        'deuda, y esa deuda se sigue cobrando',
    'Los clientes SIN cobrador asignado, como fila propia al final: es cartera '
        'real que no tiene a nadie trabajándola',
  ],
  noIncluye: [
    'Contratos CANCELADOS: cancelar condona la deuda, así que sus cuotas '
        'quedan en cero y no hay nada que cobrar',
    'Clientes desactivados',
  ],
  nota: 'Esta tarjeta se llamaba "Recuperación por cobrador y comunidad" y el '
      'rótulo mentía: el número siempre fue lo que FALTA cobrar, no lo '
      'recuperado. Leído al lado de la tarjeta de Mora del ciclo —donde '
      '"Recuperado" sí es plata que entró— hacía leer la mora como cobranza.\n\n'
      'Agrupa por el cobrador ASIGNADO al cliente (en qué lista aparece), no '
      'por quién cobró. Para eso está "Quién cobró".',
);

// ── ⚪ Foto de ahora (estado actual, sin ventana de tiempo) ──

// 🔴 RESTAURADO al texto de producción el 2026-09-02, junto con la tarjeta.
// El texto que estaba acá describía la versión FUSIONADA (barra con "la parte
// verde", opciones "Al día" y "En gracia") que el dueño pidió deshacer: al
// volver la grilla de KPIs esas cosas dejan de existir en la pantalla y el
// globo habría explicado controles que no están.
// "Al día" y "En gracia" vuelven a explicarse en `kInfoDistribucion`, que es
// donde vuelven a verse.
const kInfoOperativo = InfoGrafica(
  titulo: 'Estado actual',
  eje: 'Eje: foto de ahora (no una ventana de tiempo). El estado de clientes y '
      'cuotas en este momento.',
  opciones: [
    InfoOpcion('Clientes activos', 'Clientes con estado activo.'),
    InfoOpcion('Cuotas por cobrar',
        'Toda cuota viva: pendientes y parciales, de contratos activos y también '
            'suspendidos. OJO — incluye los meses futuros que la app ya generó '
            'por adelantado (3 por contrato, para que el cobrador pueda cobrar '
            'adelantado sin internet), así que es MÁS de lo que se debe hoy: al '
            '26/08/2026, 4 de cada 5 córdobas de este número todavía no '
            'vencieron. Lo que ya venció está en "En mora" y en el reporte de '
            'mora.'),
    InfoOpcion('En mora',
        'De las por cobrar, las vencidas pasada la gracia.'),
    InfoOpcion('De eso, suspendido',
        'NO es plata aparte: es cuánta de la deuda de arriba viene de contratos '
            'sin servicio. No sale en la ruta del día (se cobra desde '
            'Recuperación), pero se le sigue cobrando igual. Si lo sumás al '
            '"por cobrar" lo estás contando dos veces.'),
  ],
  noIncluye: [
    'Contratos cancelados y clientes desactivados (cancelar condona: no dejan '
        'nada pendiente)',
    'Cuotas anuladas',
  ],
);

const kInfoDistribucion = InfoGrafica(
  titulo: 'Distribución de cuotas',
  eje: 'Eje: foto de ahora. Todas las cuotas clasificadas por su estado de '
      'vigencia en este momento.',
  opciones: [
    InfoOpcion('Al día', 'Pendientes/parciales cuyo vencimiento todavía no llegó.'),
    InfoOpcion('En gracia', 'Vencidas pero dentro de los días de gracia.'),
    InfoOpcion('Vencidas', 'Vencidas y pasada la gracia.'),
    InfoOpcion('Pagadas', 'Cuotas ya saldadas.'),
  ],
  incluye: [
    'TODAS las cuotas no anuladas',
    '"Con pago parcial" cruza los buckets de arriba (no suma aparte)',
  ],
  noIncluye: [
    'Cuotas anuladas',
  ],
  nota: 'Tarjeta VIEJA, apagada por defecto desde el 2026-09-01: "Estado '
      'actual" dice lo mismo y además la plata de cada grupo. Se conserva para '
      'quien quiera sólo los conteos.',
);
