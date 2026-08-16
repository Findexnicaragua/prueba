import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'selector_fecha_rapido.dart';

/// Diálogo COMPACTO para elegir un rango de fechas (reemplaza el
/// `showDateRangePicker` full-screen). Pensado para reportes: práctico,
/// casual, sin la pantalla grande de calendario.
///
/// Devuelve un [DateTimeRange] date-only (hora 00:00 local) o `null` si se
/// canceló — mismo contrato que `showDateRangePicker`, así los call-sites
/// solo cambian la línea del picker y conservan su lógica posterior
/// (normalización a date-only + label "Personalizado").
///
/// [inicial] pre-puebla los campos Desde/Hasta. [firstDate]/[lastDate]
/// acotan tanto los presets como el `showDatePicker` nativo de cada campo;
/// por default [lastDate] es hoy (no tiene sentido elegir "fecha de cobro"
/// a futuro) y [firstDate] 5 años atrás.
///
/// Todos los presets se calculan en hora LOCAL (`DateTime.now()`), nunca UTC.
/// [usarPeriodos] cambia los dos presets mensuales por presets de PERÍODO
/// (el ciclo del 15 al 14 de `periodo_dashboard.dart`): "Este mes"→"Este
/// período" y "Mes pasado"→"Período pasado". Lo activa SOLO el dashboard, que
/// ya lee sus KPIs y tendencias por ese ciclo; los reportes y "mis cobros"
/// siguen con mes calendario (default false).
Future<DateTimeRange?> mostrarRangoFechas(
  BuildContext context, {
  DateTimeRange? inicial,
  DateTime? firstDate,
  DateTime? lastDate,
  bool usarPeriodos = false,
}) {
  final now = DateTime.now();
  final hoy = DateTime(now.year, now.month, now.day);
  final last = lastDate ?? hoy;
  final first = firstDate ?? DateTime(now.year - 5);
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => _RangoFechasDialog(
      inicial: inicial,
      firstDate: first,
      lastDate: last,
      usarPeriodos: usarPeriodos,
    ),
  );
}

/// Un preset rápido: etiqueta + función que calcula el rango en LOCAL.
class _Preset {
  const _Preset(this.label, this.calcular);
  final String label;
  final DateTimeRange Function() calcular;
}

class _RangoFechasDialog extends StatefulWidget {
  const _RangoFechasDialog({
    required this.inicial,
    required this.firstDate,
    required this.lastDate,
    required this.usarPeriodos,
  });

  final DateTimeRange? inicial;
  final DateTime firstDate;
  final DateTime lastDate;
  final bool usarPeriodos;

  @override
  State<_RangoFechasDialog> createState() => _RangoFechasDialogState();
}

class _RangoFechasDialogState extends State<_RangoFechasDialog> {
  late DateTime? _desde;
  late DateTime? _hasta;
  late final TextEditingController _desdeCtrl;
  late final TextEditingController _hastaCtrl;

  @override
  void initState() {
    super.initState();
    _desde = _soloFecha(widget.inicial?.start);
    _hasta = _soloFecha(widget.inicial?.end);
    _desdeCtrl = TextEditingController(text: _fmt(_desde));
    _hastaCtrl = TextEditingController(text: _fmt(_hasta));
  }

  @override
  void dispose() {
    _desdeCtrl.dispose();
    _hastaCtrl.dispose();
    super.dispose();
  }

  // --- Presets (todos en hora LOCAL) ----------------------------------------

  List<_Preset> get _presets {
    DateTime hoy() {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }

    DateTimeRange dia(DateTime d) => DateTimeRange(start: d, end: d);

    // Los dos presets del medio: mes CALENDARIO por default, o PERÍODO (ciclo
    // 15→14) si el dashboard lo pidió. El resto es idéntico en los dos modos.
    final List<_Preset> mensuales = widget.usarPeriodos
        ? [
            _Preset('Este período', () {
              // Del 15 (inicio del período en curso) → hoy: lo más útil para
              // "cuánto llevo cobrado este ciclo". Mismo criterio que "Este
              // mes" (arranca el borde, termina hoy).
              final v = ventanaPeriodoActual();
              return DateTimeRange(start: v.inicio, end: hoy());
            }),
            _Preset('Período pasado', () {
              // El período ANTERIOR completo: su inicio (15) hasta su último
              // día cubierto (el 14, = fin exclusivo − 1 día).
              final actual = periodoDe(hoy());
              final prev = DateTime(actual.year, actual.month - 1, 1);
              final ini = inicioPeriodo(prev.year, prev.month);
              final fin =
                  finPeriodo(prev.year, prev.month).subtract(const Duration(days: 1));
              return DateTimeRange(start: ini, end: fin);
            }),
          ]
        : [
            _Preset('Este mes', () {
              final h = hoy();
              // Primer día del mes → hoy (lo más útil para reportes en curso).
              return DateTimeRange(start: DateTime(h.year, h.month, 1), end: h);
            }),
            _Preset('Mes pasado', () {
              final h = hoy();
              final finMesPasado =
                  DateTime(h.year, h.month, 1).subtract(const Duration(days: 1));
              return DateTimeRange(
                start: DateTime(finMesPasado.year, finMesPasado.month, 1),
                end: finMesPasado,
              );
            }),
          ];

    return [
      _Preset('Hoy', () => dia(hoy())),
      _Preset('Ayer', () {
        final a = hoy().subtract(const Duration(days: 1));
        return dia(a);
      }),
      ...mensuales,
      _Preset('Últimos 7 días', () {
        final h = hoy();
        return DateTimeRange(start: h.subtract(const Duration(days: 6)), end: h);
      }),
      _Preset('Últimos 30 días', () {
        final h = hoy();
        return DateTimeRange(
            start: h.subtract(const Duration(days: 29)), end: h);
      }),
    ];
  }

  bool _coincide(_Preset p) {
    if (_desde == null || _hasta == null) return false;
    final r = p.calcular();
    return _mismosDias(r.start, _desde!) && _mismosDias(r.end, _hasta!);
  }

  void _aplicarPreset(_Preset p) {
    final r = p.calcular();
    setState(() {
      _desde = _soloFecha(r.start);
      _hasta = _soloFecha(r.end);
      _desdeCtrl.text = _fmt(_desde);
      _hastaCtrl.text = _fmt(_hasta);
    });
  }

  // --- Campos tipeables + calendario nativo ---------------------------------

  /// Parsea lo escrito con tolerancia (dd/MM/yyyy, también d/M/yy, separadores
  /// `/` `-` `.`). Devuelve null si no se puede interpretar.
  DateTime? _parse(String raw) {
    final txt = raw.trim();
    if (txt.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})$').firstMatch(txt);
    if (m == null) return null;
    final d = int.parse(m.group(1)!);
    final mes = int.parse(m.group(2)!);
    var anio = int.parse(m.group(3)!);
    if (anio < 100) anio += 2000; // yy → 20yy
    if (mes < 1 || mes > 12 || d < 1 || d > 31) return null;
    final fecha = DateTime(anio, mes, d);
    // Rechaza fechas que "rebalsan" (ej. 31/02 → DateTime normaliza a marzo).
    if (fecha.year != anio || fecha.month != mes || fecha.day != d) return null;
    return fecha;
  }

  void _onDesdeChanged(String raw) {
    final f = _parse(raw);
    setState(() => _desde = f);
  }

  void _onHastaChanged(String raw) {
    final f = _parse(raw);
    setState(() => _hasta = f);
  }

  Future<void> _pickNativo({required bool esDesde}) async {
    final actual = esDesde ? _desde : _hasta;
    final initial = _clamp(actual ?? widget.lastDate);
    final picked = await elegirFechaRapida(
      context,
      initialDate: initial,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      helpText: esDesde ? 'Elegí la fecha "Desde"' : 'Elegí la fecha "Hasta"',
    );
    if (picked == null) return;
    final f = _soloFecha(picked);
    setState(() {
      if (esDesde) {
        _desde = f;
        _desdeCtrl.text = _fmt(f);
      } else {
        _hasta = f;
        _hastaCtrl.text = _fmt(f);
      }
    });
  }

  // --- Validación -----------------------------------------------------------

  bool get _valido =>
      _desde != null && _hasta != null && !_desde!.isAfter(_hasta!);

  String? get _mensajeError {
    if (_desdeCtrl.text.trim().isNotEmpty && _desde == null) {
      return 'Fecha "Desde" inválida (usá dd/mm/aaaa)';
    }
    if (_hastaCtrl.text.trim().isNotEmpty && _hasta == null) {
      return 'Fecha "Hasta" inválida (usá dd/mm/aaaa)';
    }
    if (_desde != null && _hasta != null && _desde!.isAfter(_hasta!)) {
      return 'La fecha "Desde" no puede ser posterior a "Hasta"';
    }
    return null;
  }

  void _aceptar() {
    if (!_valido) return;
    Navigator.pop(
      context,
      DateTimeRange(start: _soloFecha(_desde)!, end: _soloFecha(_hasta)!),
    );
  }

  // --- Helpers --------------------------------------------------------------

  static DateTime? _soloFecha(DateTime? d) =>
      d == null ? null : DateTime(d.year, d.month, d.day);

  static bool _mismosDias(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _fmt(DateTime? d) => d == null ? '' : Fmt.fechaCorta(d);

  /// Mantiene la fecha dentro de [firstDate, lastDate] para el initialDate
  /// del picker nativo (que lanza si initial cae fuera del rango).
  DateTime _clamp(DateTime d) {
    if (d.isBefore(widget.firstDate)) return widget.firstDate;
    if (d.isAfter(widget.lastDate)) return widget.lastDate;
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = _mensajeError;
    // Ancho responsive: 380 en desktop/tablet, 90% del viewport en mobile
    // chico (un 380 fijo desborda el AlertDialog en pantallas ~360px).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 380.0;
    return AlertDialog(
      title: const Text('Elegir rango de fechas'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Presets rápidos.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets
                  .map((p) => ChoiceChip(
                        label: Text(p.label),
                        selected: _coincide(p),
                        onSelected: (_) => _aplicarPreset(p),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // Campos tipeables Desde / Hasta.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _CampoFecha(
                    label: 'Desde',
                    controller: _desdeCtrl,
                    onChanged: _onDesdeChanged,
                    onCalendario: () => _pickNativo(esDesde: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _CampoFecha(
                    label: 'Hasta',
                    controller: _hastaCtrl,
                    onChanged: _onHastaChanged,
                    onCalendario: () => _pickNativo(esDesde: false),
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _valido ? _aceptar : null,
          child: const Text('Aceptar'),
        ),
      ],
    );
  }
}

/// Campo de fecha tipeable con un botón de calendario que abre el
/// `showDatePicker` nativo (compacto, con flechas de mes + año tocable).
class _CampoFecha extends StatelessWidget {
  const _CampoFecha({
    required this.label,
    required this.controller,
    required this.onChanged,
    required this.onCalendario,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onCalendario;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: TextInputType.datetime,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9/\-.]')),
        LengthLimitingTextInputFormatter(10),
      ],
      decoration: InputDecoration(
        labelText: label,
        hintText: 'dd/mm/aaaa',
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: const Icon(Icons.calendar_today, size: 20),
          tooltip: 'Abrir calendario',
          onPressed: onCalendario,
        ),
      ),
    );
  }
}
