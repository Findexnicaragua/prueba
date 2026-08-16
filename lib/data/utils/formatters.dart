import 'package:intl/intl.dart';

class Fmt {
  static final _nio = NumberFormat.currency(
    locale: 'es_NI',
    symbol: 'C\$',
    decimalDigits: 2,
  );

  static final _usd = NumberFormat.currency(
    locale: 'es_NI',
    symbol: 'US\$',
    decimalDigits: 2,
  );

  static final _entero = NumberFormat.decimalPattern('es_NI');

  static final _fechaCorta = DateFormat('dd/MM/yyyy', 'es_NI');
  static final _fechaLarga = DateFormat("d 'de' MMMM 'de' y", 'es_NI');
  static final _mes = DateFormat('MMMM y', 'es_NI');
  static final _diaSemana = DateFormat('EEEE', 'es_NI');
  static final _hora = DateFormat('HH:mm', 'es_NI');
  static final _fechaHora = DateFormat('dd/MM/yyyy HH:mm', 'es_NI');

  /// "Hoy" en hora de Nicaragua (UTC-6), truncado a día. Para los badges de
  /// mora/gracia que deben coincidir con los cortes SQL `date('now','-6 hours')`
  /// aunque el dispositivo no esté en la TZ de Nicaragua (B11).
  static DateTime hoyNicaragua() {
    final n = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    return DateTime(n.year, n.month, n.day);
  }

  /// Entero con separador de miles (es_NI): 4281 → "4.281".
  static String entero(int v) => _entero.format(v);

  static String cordobas(num v) => _nio.format(v);
  static String dolares(num v) => _usd.format(v);
  static String monto(num v, String moneda) =>
      moneda == 'USD' ? dolares(v) : cordobas(v);

  static String fechaCorta(DateTime d) => _fechaCorta.format(d);
  static String fechaLarga(DateTime d) => _fechaLarga.format(d);
  static String mes(DateTime d) => _mes.format(d);
  static String diaSemana(DateTime d) =>
      _diaSemana.format(d)[0].toUpperCase() + _diaSemana.format(d).substring(1);
  static String hora(DateTime d) => _hora.format(d);

  /// Peso de archivo legible: "850 KB" / "7.3 MB".
  static String pesoArchivo(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Formatea un timestamp `fecha_pago` (string crudo de SQLite) a
  /// dd/MM/yyyy HH:mm. `fecha_pago` se guarda como hora LOCAL de Nicaragua
  /// (wall-clock, sin `Z`), así que se formatea DIRECTO: `DateTime.parse` toma
  /// los campos tal cual del string en cualquier dispositivo, sin shift de TZ.
  /// Coincide con cómo el recibo muestra la misma fecha y con cómo los reportes
  /// la agrupan (`date(fecha_pago)` crudo). Si no parsea, devuelve el raw.
  static String fechaHoraNi(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return _fechaHora.format(dt);
  }

  /// Igual que [fechaHoraNi] pero solo la fecha (dd/MM/yyyy).
  static String fechaNi(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return _fechaCorta.format(dt);
  }

  static String fechaRelativa(DateTime d, [DateTime? hoy]) {
    final ref = hoy ?? DateTime.now();
    final base = DateTime(ref.year, ref.month, ref.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = target.difference(base).inDays;
    if (diff == 0) return 'Hoy';
    if (diff == 1) return 'Mañana';
    if (diff == -1) return 'Ayer';
    if (diff > 0 && diff < 7) return 'En $diff días';
    if (diff < 0 && diff > -7) return 'Hace ${-diff} días';
    return fechaCorta(d);
  }

  /// Mes que representa una cuota para el usuario — el que sale en pantalla,
  /// en los reportes y en el recibo.
  ///
  /// **Regla VIGENTE (decisión de Rubén 2026-08-01): el MES DE SERVICIO,
  /// anclado al DÍA DE PAGO FIJO del contrato.** Facturación vencida: la cuota
  /// que vence el `dia_pago` del mes P cubre el servicio del mes anterior. El
  /// día 15 (mitad de mes) parte aguas:
  ///   • `diaPago` 1–14  → mes = período − 1  (el servicio se consumió sobre
  ///     todo el mes anterior al vencimiento).
  ///   • `diaPago` 15–31 → mes = período      (el servicio cae sobre todo en el
  ///     mes del vencimiento).
  /// Ej.: instalación 05/01, día 5, 1ª cuota vence 05/02 (período febrero) →
  /// "Enero". Cliente día 14, cuota de período junio → "Mayo".
  ///
  /// Se ancla al `diaPago` FIJO y al `periodo` (ambos estables), NUNCA al día
  /// del vencimiento: `calcular_fecha_pago` corre el domingo→lunes, así que un
  /// día 14 que cae domingo vence el 15 — usar ESE día lo mal-clasificaría como
  /// ≥15 y saltaría el mes (bug de PN0190). Con el día fijo el mes es CONSTANTE.
  ///
  /// REVIERTE el "mes de período" (v0.31.3), que ignoraba `diaPago` y dejaba
  /// todo un mes adelantado para los clientes de día ≤14 (SE0047 salía febrero
  /// cuando debía ser enero). Restaura el mes de servicio de v0.22.5, ahora
  /// robusto porque toma SOLO el día de pago, no el vencimiento corrido.
  ///
  /// Es SOLO etiqueta de display. La matemática de servicio/prorrateo vive en
  /// `prorrateo.dart` (`ventanaServicio`/`estadoServicio`) y NO pasa por acá,
  /// así que este cambio no toca un centavo — solo cómo se nombra el mes.
  static DateTime mesServicio(int diaPago, DateTime periodo) =>
      DateTime(periodo.year, periodo.month - (diaPago <= 14 ? 1 : 0), 1);

  /// Período que se muestra en el recibo (sin capitalizar). Deriva el mes
  /// de servicio de `mesServicio`. Ver esa función para la regla.
  static String periodoRecibo(int diaPago, DateTime periodo) =>
      mes(mesServicio(diaPago, periodo));

  /// Label capitalizado del mes de servicio de una cuota, para listas y
  /// detalles. Si [diaPago] es null (cuota manual sin contrato) usa el mes
  /// del `periodo` tal cual — las cuotas manuales no tienen período de
  /// servicio derivado.
  static String mesServicioLabel(DateTime periodo, int? diaPago) {
    final m = diaPago == null
        ? DateTime(periodo.year, periodo.month, 1)
        : mesServicio(diaPago, periodo);
    final s = mes(m);
    return s[0].toUpperCase() + s.substring(1);
  }

  // (Se eliminaron `mesServicioDeVencimiento`/`periodoReciboDeVencimiento`/
  // `mesServicioLabelDeVencimiento` y sus variantes `*Seguro` — 2026-08-01.
  // Derivaban el día del `fecha_vencimiento`, que trae el corrimiento
  // domingo→lunes y mal-clasificaba el mes en el límite. El labeling se ancla
  // ahora SIEMPRE al `dia_pago` fijo + `periodo` vía `mesServicio` /
  // `mesServicioLabel` / `periodoRecibo`. Estaban sin usar.)

  /// Rango de fechas del período de servicio que cubre una cuota (modelo de
  /// facturación VENCIDA): del día de pago del mes anterior al día de
  /// vencimiento. Ambos extremos clampeados al último día real de su mes
  /// (ej. día 31 en un mes de 30 → 30). Devuelve "DD/MM/AAAA a DD/MM/AAAA".
  ///
  /// [fechaVencimiento] = fin del período (la fecha de cobro de la cuota, ya
  /// clampeada por el server). [diaPago] = día de cobro del contrato; null en
  /// cuotas manuales (sin contrato) → devuelve null porque no hay período de
  /// servicio derivado.
  static String? periodoServicioRango(int? diaPago, DateTime fechaVencimiento) {
    if (diaPago == null) return null;
    final fin = fechaVencimiento;
    // Primer día del mes anterior al vencimiento (month-1 en enero → dic del
    // año previo, lo normaliza DateTime).
    final mesAnt = DateTime(fin.year, fin.month - 1, 1);
    // Último día real del mes anterior (DateTime(y, m+1, 0) = último de m).
    final ultDiaAnt = DateTime(mesAnt.year, mesAnt.month + 1, 0).day;
    final diaInicio = diaPago < ultDiaAnt ? diaPago : ultDiaAnt;
    final inicio = DateTime(mesAnt.year, mesAnt.month, diaInicio);
    return '${fechaCorta(inicio)} a ${fechaCorta(fin)}';
  }
}
