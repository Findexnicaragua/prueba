import 'formatters.dart';

/// Ventana de reporte del dashboard: **del día 15 de un mes al 14 del
/// siguiente** (el fin es EXCLUSIVO = 15 del mes de cierre).
///
/// Es el ciclo con el que el negocio lee sus cobros y NO es el mes calendario:
/// el período "julio" va del 15 jun al 14 jul. Vivía privado dentro de
/// `tendencia_cobros_card.dart`, así que las gráficas cortaban por el 15 y los
/// KPIs por el día 1 — dos ventanas distintas en la misma pantalla, con
/// números que no cerraban entre sí. Desde 2026-07-26 lo comparten TODAS las
/// secciones de Resumen que tienen ventana mensual.
///
/// OJO — esto es reportería de COBROS, no clasificación de servicio. La regla
/// #1c de AGENTS (anclar al `dia_pago` del contrato, nunca al mes calendario)
/// aplica al prorrateo y al ciclo de un contrato; esta ventana es un corte
/// administrativo único para todo el tenant y no toca esa lógica.
const kMesesCortosPeriodo = [
  'ene', 'feb', 'mar', 'abr', 'may', 'jun',
  'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
];

String mesCortoPeriodo(int mes) => kMesesCortosPeriodo[(mes - 1) % 12];

/// Primer día (inclusivo) del período [mes]/[anio]: el 15 del mes anterior.
DateTime inicioPeriodo(int anio, int mes) => DateTime(anio, mes - 1, 15);

/// Fin EXCLUSIVO del período [mes]/[anio]: el 15 del propio mes (el último día
/// cubierto es el 14).
DateTime finPeriodo(int anio, int mes) => DateTime(anio, mes, 15);

/// Mes de período que contiene [dia]: del 15 en adelante ya se cuenta contra el
/// período del mes siguiente.
DateTime periodoDe(DateTime dia) => dia.day >= 15
    ? DateTime(dia.year, dia.month + 1, 1)
    : DateTime(dia.year, dia.month, 1);

/// Etiqueta legible del rango, ej. "15 jun – 14 jul".
String periodoLabel(int anio, int mes) {
  final ini = inicioPeriodo(anio, mes);
  final fin = DateTime(anio, mes, 14);
  return '${ini.day} ${mesCortoPeriodo(ini.month)} – '
      '${fin.day} ${mesCortoPeriodo(fin.month)}';
}

/// Ventana del período en curso, anclada al día de Nicaragua (UTC-6).
({DateTime inicio, DateTime fin}) ventanaPeriodoActual() {
  final p = periodoDe(Fmt.hoyNicaragua());
  return (inicio: inicioPeriodo(p.year, p.month), fin: finPeriodo(p.year, p.month));
}

/// Etiqueta del período en curso, ej. "15 jun – 14 jul".
String periodoLabelActual() {
  final p = periodoDe(Fmt.hoyNicaragua());
  return periodoLabel(p.year, p.month);
}

/// `yyyy-MM-dd` para comparar contra `date(...)` en SQLite.
String isoDia(DateTime d) => d.toIso8601String().substring(0, 10);
