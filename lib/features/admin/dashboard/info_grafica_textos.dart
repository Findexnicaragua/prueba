import 'info_grafica.dart';

/// Textos del (i) de cada gráfica del dashboard. Fuente única — se importan
/// desde `tendencia_cobros_card.dart` (Cobros, Mora) y `dashboard_admin_screen.dart`
/// (el resto). Redacción aprobada por Rubén (2026-08-01). El ORDEN de secciones
/// refleja el modelo de dinero: caja (por fecha_pago) vs cobertura (por
/// vencimiento) vs mora vs foto-de-ahora (ver AGENTS §invariantes #4).

// ── 🟢 CAJA (plata que entró, por fecha de pago) ──

const kInfoCobrosKpis = InfoGrafica(
  titulo: 'Cobros del período (caja)',
  eje: 'Eje: caja. La plata que ENTRÓ, por fecha de pago. Todo cobro cuenta, '
      'sea de la cuota del mes, de una atrasada o de una adelantada.',
  opciones: [
    InfoOpcion('Hoy', 'Cobros con fecha de pago de hoy.'),
    InfoOpcion('Esta semana',
        'Desde el domingo hasta hoy. La semana va de domingo a sábado: el '
            'sábado a medianoche vuelve a cero y arranca la nueva.'),
    InfoOpcion('Este período',
        'Desde el 15 (corte del ciclo) hasta hoy — el período en curso.'),
  ],
  incluye: [
    'Todos los pagos no anulados de la ventana',
    'De cualquier cuota y cualquier contrato, incluso suspendido',
  ],
  noIncluye: [
    'Pagos anulados',
  ],
  nota: '"Hoy" puede ser mayor que el "Del día" de la gráfica de tendencia: esa '
      'solo cuenta lo que cubre ESTE período; un cobro de hoy sobre una cuota de '
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
  titulo: 'Top cobradores',
  eje: 'Eje: caja por QUIÉN cobró — el usuario que registró el pago, no el '
      'cobrador asignado del cliente. Muestra el top 5.',
  opciones: [
    InfoOpcion('Top cobradores (hoy)', 'Cobros registrados hoy.'),
    InfoOpcion('Top cobradores (período)', 'Cobros registrados desde el 15.'),
  ],
  incluye: [
    'Pagos no anulados, agrupados por quien los registró — toda la oficina',
  ],
  noIncluye: [
    'Pagos anulados',
  ],
  nota: 'Reasignar un cliente a otro cobrador NO cambia este histórico: cuenta '
      'quien cobró, no quien tiene asignado al cliente.',
);

// ── 🔵 COBERTURA (cuánto de lo facturado se recuperó, por vencimiento) ──

const kInfoCobrosDelMes = InfoGrafica(
  titulo: 'Cobros del mes',
  eje: 'Eje: cobertura. Cuánto de lo facturado de este período ya se recuperó. '
      'Agrupa por la fecha en que VENCE la cuota, no por cuándo se pagó.',
  opciones: [
    InfoOpcion('◀ ▶ Cambiar de período',
        'Movés entre ciclos 15→14. El período EN CURSO dibuja la curva solo '
            'hasta hoy (se va llenando); los CERRADOS muestran el ciclo completo '
            'y la curva llega al total.'),
  ],
  incluye: [
    'Cuotas que vencen del 15 al 14 (el período mostrado)',
    'Pagos aplicados a esas cuotas, en la fecha que se hayan pagado',
  ],
  noIncluye: [
    'Contratos suspendidos',
    'Cuotas o pagos anulados',
    'Pagos de este período sobre cuotas de otro mes (cuentan en su propio mes)',
  ],
  nota: 'La columna Usuarios NO suma vertical: un mismo cliente puede estar en '
      'las dos filas (pagó una cuota y debe otra). Es correcto — si sumás para '
      'abajo no te va a dar.\n\n'
      'La línea punteada roja del gráfico es lo que se recuperó TARDE (pasada '
      'la gracia). Va siempre por debajo de la verde porque es una parte de '
      'ella, no plata aparte: no se suman.',
);

const kInfoMora = InfoGrafica(
  titulo: 'Mora',
  eje: 'Eje: mora del período. De lo que venció y pasó la gracia, cuánto se '
      'recuperó tarde y cuánto sigue impago.',
  opciones: [
    InfoOpcion('◀ ▶ Cambiar de período',
        'Igual que Cobros. En el período EN CURSO la mora casi no aparece los '
            'primeros ~15 días + gracia (las cuotas nuevas todavía no entraron en '
            'mora); recién después crece.'),
  ],
  incluye: [
    'Cuotas vencidas del período que ya cruzaron los días de gracia',
    'Tanto las impagas como las que se pagaron tarde (recuperadas)',
  ],
  noIncluye: [
    'Cuotas pagadas a tiempo (nunca estuvieron en mora)',
    'Contratos suspendidos',
    'Cuotas o pagos anulados',
  ],
  nota: 'El "Recuperado" de esta tarjeta YA está contado dentro del '
      '"Recuperado" de Cobros del mes: es la misma plata vista de otra '
      'forma, no se suma aparte. Sumarlas fue exactamente lo que hizo que '
      'los números no cerraran la primera vez.',
);

const kInfoMoraHistorica = InfoGrafica(
  titulo: 'Mora — últimos 6 ciclos',
  eje: 'Eje: mora por ciclo. La misma medida de la tarjeta "Mora del ciclo", '
      'repetida en los últimos 6 — para ver si la cartera viene mejorando o '
      'empeorando, no cuánta mora hay hoy.',
  opciones: [
    InfoOpcion('Altura de la barra',
        'La mora TOTAL de ese ciclo: lo que se recuperó tarde más lo que sigue '
            'impago.'),
    InfoOpcion('La última barra',
        'Es el ciclo EN CURSO y todavía va a moverse. Compararla contra las '
            'cerradas es comparar un mes a medias contra meses completos.'),
  ],
  incluye: [
    'Cuotas que vencieron dentro del ciclo y pasaron los días de gracia',
    'Tanto las impagas como las que se pagaron tarde (recuperadas)',
  ],
  noIncluye: [
    'Cuotas pagadas a tiempo (nunca estuvieron en mora)',
    'Contratos suspendidos',
    'Cuotas o pagos anulados',
  ],
  nota: 'Lo recuperado de acá YA está contado dentro del "Recuperado" de '
      'Cobros del mes: es la misma plata vista de otra forma, no se suma '
      'aparte. La barra del último ciclo tiene que dar IGUAL que la tarjeta '
      '"Mora del ciclo" — si difieren, una de las dos está mal.',
);

// ── 🔴 Lo que FALTA / proyección ──

const kInfoProyeccion = InfoGrafica(
  titulo: 'Proyección de cobros por cobrador',
  eje: 'Eje: lo que se DEBE cobrar (a futuro), por cobrador asignado. Es la '
      'proyección de quién debe salir a cobrar, no el histórico de lo cobrado.',
  opciones: [
    InfoOpcion('Switch "Incluir cuotas próximas" apagado',
        'Solo lo que vence HOY.'),
    InfoOpcion('Switch "Incluir cuotas próximas" encendido',
        'Vence hoy + lo que vence en los próximos días configurados.'),
  ],
  incluye: [
    'Cuotas vivas (pendientes/parciales) según la opción elegida',
    'Solo contratos activos y clientes activos',
  ],
  noIncluye: [
    'Contratos suspendidos o cancelados',
    'Cuotas ya pagadas (no es histórico cobrado)',
  ],
);

const kInfoRecuperacion = InfoGrafica(
  titulo: 'Recuperación por cobrador y comunidad',
  eje: 'Eje: mora pendiente A RECUPERAR, por cobrador asignado × comunidad. '
      'Muestra lo que FALTA cobrar, no lo ya recuperado.',
  opciones: [
    InfoOpcion('Toda la mora',
        'Todo lo vencido pasada la gracia, sin límite de fecha. Es lo que el '
            'equipo sale a cobrar.'),
    InfoOpcion('Vencidas del período',
        'Solo las que vencen en el ciclo actual. Sirve para "cuánta mora generó '
            'este período". Ojo: da casi 0 los primeros ~15 días + gracia.'),
    InfoOpcion('Tocá una comunidad',
        'Despliega el desglose por monto (cuántas cuotas de cada saldo); la '
            'suma cierra contra el total de la fila.'),
  ],
  incluye: [
    'Cuotas vivas vencidas pasada la gracia',
    'Solo contratos activos y clientes activos',
  ],
  noIncluye: [
    'Contratos suspendidos o cancelados',
    'Lo ya recuperado (muestra el saldo pendiente)',
  ],
);

// ── ⚪ Foto de ahora (estado actual, sin ventana de tiempo) ──

const kInfoOperativo = InfoGrafica(
  titulo: 'Estado actual',
  eje: 'Eje: foto de ahora (no una ventana de tiempo). El estado de clientes y '
      'cuotas en este momento.',
  opciones: [
    InfoOpcion('Clientes activos', 'Clientes con estado activo.'),
    InfoOpcion('Cuotas por cobrar',
        'Pendientes/parciales de contratos NO suspendidos (su saldo pendiente).'),
    InfoOpcion('En mora',
        'De las por cobrar, las vencidas pasada la gracia.'),
    InfoOpcion('Suspendido (por reactivar)',
        'Deuda de contratos suspendidos, aparte. Cuenta en contabilidad pero no '
            'está en rutas de cobro.'),
  ],
  noIncluye: [
    'En "por cobrar" y "en mora": contratos suspendidos (van en su propia línea)',
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
  nota: 'A diferencia de "En mora" del bloque de arriba, esta SÍ incluye cuotas '
      'de contratos suspendidos.',
);
