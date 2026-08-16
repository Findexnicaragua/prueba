/// Prorrateo "por días" para el cambio de fecha de pago (feature C) y la
/// suspensión temporal (feature A).
///
/// **Convención de negocio (decisión de Rubén, 2026-06-14):** el precio de un
/// día de servicio = `precio_mensual / días reales del mes` de esa fecha. Si un
/// rango cruza dos meses, cada día se valúa con los días de SU propio mes
/// (un día de junio = precio/30, uno de julio = precio/31).
///
/// **Servicio vs cobro:** el servicio corre TODOS los días (incluidos domingos),
/// así que el prorrateo usa días calendario crudos. El ajuste domingo→lunes del
/// server (`calcular_fecha_pago`) es SOLO para la fecha de COBRO de las cuotas,
/// no para el conteo de días de servicio.
library;

/// Días reales del mes de [year]/[month] (1-12). 28/29/30/31.
int diasDelMes(int year, int month) => DateTime(year, month + 1, 0).day;

/// Precio de un día de servicio en el mes de [fecha].
double precioPorDia(DateTime fecha, double precioMensual) =>
    precioMensual / diasDelMes(fecha.year, fecha.month);

/// Trunca a fecha-sólo (sin hora) para que las diferencias de días sean exactas.
DateTime _soloFecha(DateTime d) => DateTime(d.year, d.month, d.day);

/// Cantidad de días del puente entre [pagadoHasta] (último día ya cubierto,
/// EXCLUSIVO) y [anclaServicio] (INCLUSIVO). Es simplemente la diferencia de
/// fechas en días. Ej: 15-jun → 10-jul = 25.
int diasPuente(DateTime pagadoHasta, DateTime anclaServicio) =>
    _soloFecha(anclaServicio).difference(_soloFecha(pagadoHasta)).inDays;

/// Monto del puente: cada día desde `pagadoHasta + 1` hasta `anclaServicio`
/// (inclusive) valuado con el precio diario de su mes. Redondeado a centavos.
/// Devuelve 0 si el ancla no es posterior a lo pagado.
double montoPuente(
    DateTime pagadoHasta, DateTime anclaServicio, double precioMensual) {
  var monto = 0.0;
  var d = _soloFecha(pagadoHasta).add(const Duration(days: 1));
  final fin = _soloFecha(anclaServicio);
  while (!d.isAfter(fin)) {
    monto += precioPorDia(d, precioMensual);
    d = d.add(const Duration(days: 1));
  }
  return (monto * 100).round() / 100;
}

/// Día [diaNuevo] (1-31) clampeado al último día real del mes [year]/[month].
/// Espeja el clamp de `calcular_fecha_pago` (ej. 31 en febrero → 28/29).
int diaClampMes(int year, int month, int diaNuevo) {
  final ult = diasDelMes(year, month);
  return diaNuevo < ult ? diaNuevo : ult;
}

/// **Fin de la ventana de servicio de una cuota** = su vencimiento NOMINAL
/// (`diaPago` clampeado al mes del [periodo]), SIN ajuste domingo→lunes (es
/// SERVICIO, no cobro). Es el MISMO ancla que `pagadoHasta` del cambio de fecha
/// (`pagos_repo`): una cuota cubre servicio HASTA esta fecha. Ej día_pago 15,
/// periodo junio → 15-jun.
DateTime servicioFin(DateTime periodo, int diaPago) => DateTime(
    periodo.year, periodo.month, diaClampMes(periodo.year, periodo.month, diaPago));

/// **Ventana de servicio** (`inicio` EXCLUSIVO — ya cubierto por la cuota
/// anterior — `fin` INCLUSIVO) de la cuota de [periodo] con [diaPago]: desde el
/// venc del período anterior hasta su propio venc. Ej día_pago 15, periodo
/// junio → (15-may, 15-jun]. NUNCA usar el mes CALENDARIO como ancla.
({DateTime inicio, DateTime fin}) ventanaServicio(DateTime periodo, int diaPago) {
  final prev = DateTime(periodo.year, periodo.month - 1, 1);
  return (inicio: servicioFin(prev, diaPago), fin: servicioFin(periodo, diaPago));
}

/// Clasifica el SERVICIO de la cuota de [periodo] a la fecha [x] (la de la
/// suspensión): `'cumplido'` (servicio entregado completo, `fin <= x` → cobrar
/// ENTERA), `'en_curso'` (`inicio <= x < fin` → prorratear los días consumidos),
/// `'futuro'` (`inicio > x`, servicio no empezó → anular). Ancla al día_pago,
/// no al mes calendario.
String estadoServicio(DateTime periodo, int diaPago, DateTime x) {
  final v = ventanaServicio(periodo, diaPago);
  final xd = _soloFecha(x);
  if (!v.fin.isAfter(xd)) return 'cumplido';
  if (!v.inicio.isAfter(xd)) return 'en_curso';
  return 'futuro';
}

/// **Excedente** de una cuota a la fecha [x] (suspensión/cancelación): la parte
/// PAGADA por servicio que NO se va a prestar. Es el espejo de [montoPuente] —
/// lo servido se cobra; lo pagado de más es el excedente acreditable/devolvible/
/// condonable. Anclado al día_pago (ver `ARQUITECTURA.md` §3.5), NUNCA al mes
/// calendario.
///   - **cumplido** (servicio entero entregado) → 0 (lo pagado cubrió servicio real).
///   - **en_curso** → `max(0, montoPagado − días consumidos prorrateados)`.
///   - **futuro** (servicio no empezó) → todo lo pagado (0 servicio prestado).
/// Clamp ≥ 0 (nunca negativo). [montoPagado] = lo aplicado a la cuota (no anulado).
double excedenteCuota({
  required DateTime periodo,
  required int diaPago,
  required double montoPagado,
  required DateTime x,
  required double precioMensual,
}) {
  if (montoPagado <= 0) return 0;
  final est = estadoServicio(periodo, diaPago, x);
  if (est == 'cumplido') return 0;
  final servido = est == 'futuro'
      ? 0.0
      : montoPuente(ventanaServicio(periodo, diaPago).inicio, x, precioMensual);
  final exc = montoPagado - servido;
  return exc <= 0 ? 0 : (exc * 100).round() / 100;
}

/// **Ancla de servicio del nuevo día de pago**: la primera fecha cuyo día sea
/// [diaNuevo] (clampeado a fin de mes) ESTRICTAMENTE posterior a [pagadoHasta].
/// Sin ajuste domingo→lunes (eso es de la fecha de cobro, no del servicio).
///
/// Ejemplos (pagadoHasta = 15-jun): día 30 → 30-jun · día 14 → 14-jul ·
/// día 10 → 10-jul · día 16 → 16-jun.
DateTime anclaServicio(DateTime pagadoHasta, int diaNuevo) {
  final base = _soloFecha(pagadoHasta);
  var y = base.year;
  var m = base.month;
  var cand = DateTime(y, m, diaClampMes(y, m, diaNuevo));
  if (!cand.isAfter(base)) {
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
    cand = DateTime(y, m, diaClampMes(y, m, diaNuevo));
  }
  return cand;
}

/// **Fecha de COBRO de una cuota** para el mes [periodo] con el día [diaPago]:
/// espeja EXACTAMENTE el server `calcular_fecha_pago` (migración 0014) — clamp del
/// día al último del mes + ajuste domingo→lunes (no se cobra domingo). Es DISTINTA
/// de [anclaServicio] (servicio puro, sin ajuste domingo→lunes): esta es la fecha
/// con la que el cliente espeja OFFLINE el re-fechado de las cuotas futuras que el
/// trigger `contratos_actualizar_cuotas_futuras_trg` (0018) hace en el server al
/// cambiar `dia_pago`.
DateTime calcularFechaPago(DateTime periodo, int diaPago) {
  final y = periodo.year;
  final m = periodo.month;
  var f = DateTime(y, m, diaClampMes(y, m, diaPago));
  // DateTime.weekday: lunes=1 … domingo=7. (dow Postgres: domingo=0.)
  if (f.weekday == DateTime.sunday) f = f.add(const Duration(days: 1));
  return f;
}

/// Resultado de simular un cambio de fecha de pago.
class PuenteCambioFecha {
  const PuenteCambioFecha({
    required this.anclaServicio,
    required this.diasPuente,
    required this.montoPuente,
  });

  /// Primera fecha de servicio con el día nuevo, posterior a lo pagado.
  final DateTime anclaServicio;

  /// Días de servicio del puente a cobrar.
  final int diasPuente;

  /// Monto a cobrar por el puente (córdobas, 2 decimales).
  final double montoPuente;
}

/// Calcula el puente completo de un cambio de fecha de pago al [diaNuevo],
/// dado lo que el cliente ya pagó ([pagadoHasta]) y el [precioMensual].
PuenteCambioFecha calcularPuenteCambioFecha({
  required DateTime pagadoHasta,
  required int diaNuevo,
  required double precioMensual,
}) {
  final ancla = anclaServicio(pagadoHasta, diaNuevo);
  return PuenteCambioFecha(
    anclaServicio: ancla,
    diasPuente: diasPuente(pagadoHasta, ancla),
    montoPuente: montoPuente(pagadoHasta, ancla, precioMensual),
  );
}

// ───────────────────────── Cambio de plan (feature contract-new-feature) ─────
//
// El precio vive en `planes.precio_mensual`; cambiar de plan = re-valuar el
// `monto` de las cuotas FUTURAS pendientes al precio nuevo (el conteo de cuotas
// NO cambia → el invariante #11 queda intacto) y, en modo "Hoy con prorrateo",
// ajustar SOLO los días aún no servidos del ciclo en curso a la DIFERENCIA de
// precio. Misma matemática día-a-día anclada al día_pago que el cambio de fecha
// (R13) y la suspensión (R14) — NO se reinventa nada.

/// Monto nuevo de una cuota FUTURA pendiente tras el cambio de plan = el
/// [precioNuevo], clampeado a `>= montoPagado` para respetar el CHECK
/// `monto_pagado <= monto` (0005). Las futuras pendientes tienen montoPagado 0;
/// el clamp es una red por si se re-valúa una con abono parcial. NO se re-valúan
/// las cumplidas/vencidas/anuladas/parciales: eso lo filtra el repo por estado y
/// por `estadoServicio == 'futuro'`.
double montoCuotaRevaluada(double precioNuevo, double montoPagado) =>
    precioNuevo < montoPagado ? montoPagado : precioNuevo;

/// Resultado del prorrateo "Hoy con prorrateo" de un cambio de plan: el ajuste
/// por los días AÚN NO SERVIDOS del ciclo en curso, valuados a la DIFERENCIA de
/// precio (no al precio entero — los días ya consumidos quedan al plan viejo,
/// facturación vencida correcta).
class ProrrateoCambioPlan {
  const ProrrateoCambioPlan({
    required this.dias,
    required this.monto,
    required this.esUpgrade,
  });

  /// Días no servidos del ciclo en curso (de `hoy` EXCL a `finVentana` INCL).
  final int dias;

  /// La diferencia prorrateada, SIEMPRE `>= 0` (córdobas, 2 decimales).
  final double monto;

  /// `true` = el precio SUBIÓ → se COBRA la diferencia (pago+recibo inmutable).
  /// `false` = bajó → se ACREDITA en saldos_favor (nunca devuelve efectivo).
  final bool esUpgrade;

  /// No hay nada que cobrar/acreditar (precio igual, o no quedan días).
  bool get sinAjuste => monto == 0;
}

/// Prorratea el modo "Hoy" de un cambio de plan: re-valúa SOLO los días que
/// faltan del ciclo en curso a la diferencia `|precioNuevo − precioViejo|`,
/// anclado al día_pago. [hoy] = fecha del cambio (EXCL, ya servido hasta hoy);
/// [finVentanaActual] = `servicioFin(periodoEnCurso, diaPago)` (último día del
/// ciclo, INCL). Reusa [montoPuente] (idéntico día-a-día que cambio-fecha y
/// suspensión: cada día a `precio/díasDelMes` de SU mes).
ProrrateoCambioPlan prorrateoCambioPlanHoy({
  required DateTime hoy,
  required DateTime finVentanaActual,
  required double precioViejo,
  required double precioNuevo,
}) {
  final diff = precioNuevo - precioViejo;
  final dias = diasPuente(hoy, finVentanaActual);
  return ProrrateoCambioPlan(
    dias: dias < 0 ? 0 : dias,
    monto: montoPuente(hoy, finVentanaActual, diff.abs()),
    esUpgrade: diff >= 0,
  );
}
