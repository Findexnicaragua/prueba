import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../data/utils/formatters.dart';

enum FrecuenciaPago {
  diario('Diario', 1, 'día'),
  semanal('Semanal', 7, 'semana'),
  quincenal('Quincenal', 15, 'quincena'),
  mensual('Mensual', 30, 'mes'),
  bimensual('Bimensual', 60, '2 meses');

  const FrecuenciaPago(this.etiqueta, this.diasAprox, this.periodo);
  final String etiqueta;
  final int diasAprox;
  final String periodo;
}

enum MetodoCalculo {
  interesFijo(
    'Interés Fijo (Microfinanzas)',
    'El interés se calcula de forma fija por período sobre el capital prestado. Común en créditos grupales y microfinanzas.',
  ),
  cuotaNivelada(
    'Cuota Nivelada (Francés)',
    'Amortización bancaria tradicional. Las cuotas son iguales pero el interés disminuye con el saldo restante.',
  );

  const MetodoCalculo(this.titulo, this.descripcion);
  final String titulo;
  final String descripcion;
}

class CuotaAmortizacion {
  const CuotaAmortizacion({
    required this.numero,
    required this.fecha,
    required this.cuota,
    required this.capital,
    required this.interes,
    required this.saldoRestante,
  });

  final int numero;
  final DateTime fecha;
  final double cuota;
  final double capital;
  final double interes;
  final double saldoRestante;
}

class CalculadoraPrestamosScreen extends StatefulWidget {
  const CalculadoraPrestamosScreen({super.key});

  @override
  State<CalculadoraPrestamosScreen> createState() =>
      _CalculadoraPrestamosScreenState();
}

class _CalculadoraPrestamosScreenState
    extends State<CalculadoraPrestamosScreen> {
  final _formKey = GlobalKey<FormState>();

  final _montoController = TextEditingController(text: '10000');
  final _interesController = TextEditingController(text: '10');
  final _cuotasController = TextEditingController(text: '12');

  String _moneda = 'NIO';
  FrecuenciaPago _frecuencia = FrecuenciaPago.mensual;
  MetodoCalculo _metodo = MetodoCalculo.interesFijo;
  bool _tasaEsMensual = true;
  DateTime _fechaPrimerPago = DateTime.now().add(const Duration(days: 30));
  bool _mostrarCronograma = false;

  @override
  void dispose() {
    _montoController.dispose();
    _interesController.dispose();
    _cuotasController.dispose();
    super.dispose();
  }

  double get _monto =>
      double.tryParse(_montoController.text.replaceAll(',', '')) ?? 0.0;
  double get _tasaInteres =>
      double.tryParse(_interesController.text.replaceAll(',', '')) ?? 0.0;
  int get _cuotas => int.tryParse(_cuotasController.text) ?? 1;

  double get _totalInteres {
    if (_monto <= 0 || _tasaInteres <= 0 || _cuotas <= 0) return 0.0;

    if (_metodo == MetodoCalculo.interesFijo) {
      if (_tasaEsMensual) {
        return _monto * (_tasaInteres / 100) * _cuotas;
      } else {
        return _monto * (_tasaInteres / 100);
      }
    } else {
      final r = (_tasaInteres / 100);
      if (r == 0) return 0.0;
      final cuota =
          _monto * (r * _pow(1 + r, _cuotas)) / (_pow(1 + r, _cuotas) - 1);
      final total = cuota * _cuotas;
      return (total - _monto).clamp(0.0, double.infinity);
    }
  }

  double get _totalPagar => _monto + _totalInteres;

  double get _montoCuota {
    if (_cuotas <= 0) return 0.0;
    if (_metodo == MetodoCalculo.interesFijo) {
      return _totalPagar / _cuotas;
    } else {
      final r = (_tasaInteres / 100);
      if (r <= 0) return _monto / _cuotas;
      return _monto * (r * _pow(1 + r, _cuotas)) / (_pow(1 + r, _cuotas) - 1);
    }
  }

  double _pow(double x, int n) {
    double res = 1.0;
    for (int i = 0; i < n; i++) {
      res *= x;
    }
    return res;
  }

  List<CuotaAmortizacion> _generarCronograma() {
    if (_monto <= 0 || _cuotas <= 0) return [];
    final List<CuotaAmortizacion> lista = [];

    DateTime fechaCursor = _fechaPrimerPago;
    double saldo = _monto;

    if (_metodo == MetodoCalculo.interesFijo) {
      final interesPorCuota = _totalInteres / _cuotas;
      final capitalPorCuota = _monto / _cuotas;
      final cuotaFija = capitalPorCuota + interesPorCuota;

      for (int i = 1; i <= _cuotas; i++) {
        saldo -= capitalPorCuota;
        if (saldo < 0 || i == _cuotas) saldo = 0.0;

        lista.add(
          CuotaAmortizacion(
            numero: i,
            fecha: fechaCursor,
            cuota: cuotaFija,
            capital: capitalPorCuota,
            interes: interesPorCuota,
            saldoRestante: saldo,
          ),
        );
        fechaCursor = _siguienteFecha(fechaCursor, _frecuencia);
      }
    } else {
      final r = (_tasaInteres / 100);
      final cuotaFija = _montoCuota;

      for (int i = 1; i <= _cuotas; i++) {
        final interesCuota = saldo * r;
        final capitalCuota = (cuotaFija - interesCuota).clamp(0.0, saldo);
        saldo -= capitalCuota;
        if (saldo < 0 || i == _cuotas) saldo = 0.0;

        lista.add(
          CuotaAmortizacion(
            numero: i,
            fecha: fechaCursor,
            cuota: cuotaFija,
            capital: capitalCuota,
            interes: interesCuota,
            saldoRestante: saldo,
          ),
        );
        fechaCursor = _siguienteFecha(fechaCursor, _frecuencia);
      }
    }

    return lista;
  }

  DateTime _siguienteFecha(DateTime actual, FrecuenciaPago freq) {
    switch (freq) {
      case FrecuenciaPago.diario:
        return actual.add(const Duration(days: 1));
      case FrecuenciaPago.semanal:
        return actual.add(const Duration(days: 7));
      case FrecuenciaPago.quincenal:
        return actual.add(const Duration(days: 15));
      case FrecuenciaPago.mensual:
        return DateTime(actual.year, actual.month + 1, actual.day);
      case FrecuenciaPago.bimensual:
        return DateTime(actual.year, actual.month + 2, actual.day);
    }
  }

  String _formatearMonto(num valor) {
    return Fmt.monto(valor, _moneda);
  }

  void _copiarResumen() {
    final buffer = StringBuffer();
    buffer.writeln('=================================');
    buffer.writeln('COTIZACIÓN DE PRÉSTAMO - FINDEX');
    buffer.writeln('=================================');
    buffer.writeln('Monto Prestado: ${_formatearMonto(_monto)}');
    buffer.writeln('Tasa de Interés: $_tasaInteres% ${_tasaEsMensual ? "por período" : "total"}');
    buffer.writeln('Frecuencia: ${_frecuencia.etiqueta}');
    buffer.writeln('Cantidad de Cuotas: $_cuotas');
    buffer.writeln('Método: ${_metodo.titulo}');
    buffer.writeln('---------------------------------');
    buffer.writeln('VALOR DE LA CUOTA: ${_formatearMonto(_montoCuota)}');
    buffer.writeln('TOTAL INTERESES: ${_formatearMonto(_totalInteres)}');
    buffer.writeln('TOTAL A PAGAR: ${_formatearMonto(_totalPagar)}');
    buffer.writeln('Primer Vencimiento: ${DateFormat("dd/MM/yyyy").format(_fechaPrimerPago)}');
    buffer.writeln('=================================');

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Cotización copiada al portapapeles.'),
        backgroundColor: Color(0xFF0F766E),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _reiniciarValores() {
    setState(() {
      _montoController.text = '10000';
      _interesController.text = '10';
      _cuotasController.text = '12';
      _frecuencia = FrecuenciaPago.mensual;
      _metodo = MetodoCalculo.interesFijo;
      _tasaEsMensual = true;
      _fechaPrimerPago = DateTime.now().add(const Duration(days: 30));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final esPantallaAncha = size.width >= 920;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context),
                const SizedBox(height: 20),
                if (esPantallaAncha)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: _buildParametrosCard(theme),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 6,
                        child: Column(
                          children: [
                            _buildResultadosCard(theme),
                            const SizedBox(height: 16),
                            _buildCronogramaSection(theme),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  Column(
                    children: [
                      _buildParametrosCard(theme),
                      const SizedBox(height: 16),
                      _buildResultadosCard(theme),
                      const SizedBox(height: 16),
                      _buildCronogramaSection(theme),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFE6FFFA),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.calculate_outlined,
              color: Color(0xFF0F766E),
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Calculadora de Préstamos',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Simulación de cuotas, intereses y cronograma de amortización.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          IconButton.outlined(
            tooltip: 'Restablecer valores',
            onPressed: _reiniciarValores,
            icon: const Icon(Icons.refresh, size: 20),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.grey.shade700,
              side: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _copiarResumen,
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copiar Cotización'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParametrosCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune, color: Color(0xFF0F766E), size: 20),
                SizedBox(width: 8),
                Text(
                  'Datos del Préstamo',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            const Text(
              'Moneda',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'NIO',
                  label: Text('Córdobas (C\$)'),
                  icon: Icon(Icons.monetization_on_outlined, size: 16),
                ),
                ButtonSegment(
                  value: 'USD',
                  label: Text('Dólares (US\$)'),
                  icon: Icon(Icons.attach_money, size: 16),
                ),
              ],
              selected: {_moneda},
              onSelectionChanged: (val) {
                setState(() => _moneda = val.first);
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),

            Text(
              'Cantidad a Prestar (${_moneda == "NIO" ? "C\$" : "US\$"})',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _montoController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.payments_outlined, size: 20),
                hintText: 'Ej. 10000',
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [2000, 5000, 10000, 20000, 50000].map((val) {
                return ActionChip(
                  label: Text(
                    _moneda == 'NIO' ? 'C\$ $val' : '\$ $val',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () {
                    setState(() {
                      _montoController.text = val.toString();
                    });
                  },
                  backgroundColor: const Color(0xFFF1F5F9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Tasa de Interés (%)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF475569),
                  ),
                ),
                Row(
                  children: [
                    InkWell(
                      onTap: () => setState(() => _tasaEsMensual = true),
                      child: Text(
                        'Por período',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: _tasaEsMensual ? FontWeight.bold : FontWeight.normal,
                          color: _tasaEsMensual ? const Color(0xFF0F766E) : Colors.grey,
                        ),
                      ),
                    ),
                    const Text(' | ', style: TextStyle(color: Colors.grey)),
                    InkWell(
                      onTap: () => setState(() => _tasaEsMensual = false),
                      child: Text(
                        'Total del crédito',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: !_tasaEsMensual ? FontWeight.bold : FontWeight.normal,
                          color: !_tasaEsMensual ? const Color(0xFF0F766E) : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _interesController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.percent, size: 18),
                hintText: 'Ej. 10',
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [5, 8, 10, 12, 15, 20].map((t) {
                return ActionChip(
                  label: Text('$t%', style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    setState(() {
                      _interesController.text = t.toString();
                    });
                  },
                  backgroundColor: const Color(0xFFF1F5F9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            const Text(
              'Frecuencia de Pago',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<FrecuenciaPago>(
              initialValue: _frecuencia,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              items: FrecuenciaPago.values.map((f) {
                return DropdownMenuItem(
                  value: f,
                  child: Text(
                    '${f.etiqueta} (cada ${f.periodo})',
                    style: const TextStyle(fontSize: 14),
                  ),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) setState(() => _frecuencia = val);
              },
            ),
            const SizedBox(height: 18),

            const Text(
              'Cantidad de Cuotas',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _cuotasController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.format_list_numbered, size: 20),
                      hintText: 'Ej. 12',
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: () {
                    final c = (_cuotas - 1).clamp(1, 360);
                    setState(() => _cuotasController.text = c.toString());
                  },
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () {
                    final c = _cuotas + 1;
                    setState(() => _cuotasController.text = c.toString());
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [4, 6, 8, 12, 16, 24, 30].map((n) {
                return ActionChip(
                  label: Text('$n cuotas', style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    setState(() => _cuotasController.text = n.toString());
                  },
                  backgroundColor: const Color(0xFFF1F5F9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            const Text(
              'Método de Amortización',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 6),
            ...MetodoCalculo.values.map((metodo) {
              final seleccionado = _metodo == metodo;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => setState(() => _metodo = metodo),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: seleccionado ? const Color(0xFFF0FDFA) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: seleccionado ? const Color(0xFF0F766E) : const Color(0xFFE2E8F0),
                        width: seleccionado ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          seleccionado ? Icons.radio_button_checked : Icons.radio_button_off,
                          size: 18,
                          color: seleccionado ? const Color(0xFF0F766E) : Colors.grey,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                metodo.titulo,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: seleccionado ? const Color(0xFF0F766E) : const Color(0xFF334155),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                metodo.descripcion,
                                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 14),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Fecha Primer Pago:',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF475569),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final pick = await showDatePicker(
                      context: context,
                      initialDate: _fechaPrimerPago,
                      firstDate: DateTime.now().subtract(const Duration(days: 30)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (pick != null) setState(() => _fechaPrimerPago = pick);
                  },
                  icon: const Icon(Icons.event, size: 16),
                  label: Text(DateFormat('dd/MM/yyyy').format(_fechaPrimerPago)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultadosCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F766E), Color(0xFF115E59)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F0F766E),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'VALOR DE LA CUOTA',
                style: TextStyle(
                  color: Color(0xFFCCFBF1),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(46),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_cuotas pagos ${_frecuencia.etiqueta.toLowerCase()}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _formatearMonto(_montoCuota),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Cada ${_frecuencia.periodo} hasta cancelar',
            style: const TextStyle(color: Color(0xFF99F6E4), fontSize: 13),
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0x33FFFFFF), height: 1),
          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Total a Pagar',
                  subtitulo: 'Capital + Intereses',
                  valor: _formatearMonto(_totalPagar),
                  icono: Icons.account_balance_wallet_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Solo Intereses',
                  subtitulo: 'Ganancia por crédito',
                  valor: _formatearMonto(_totalInteres),
                  icono: Icons.trending_up,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Capital Prestado',
                  subtitulo: 'Monto base',
                  valor: _formatearMonto(_monto),
                  icono: Icons.attach_money,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Tasa Efectiva',
                  subtitulo: _tasaEsMensual ? 'Por período' : 'Total del crédito',
                  valor: '$_tasaInteres %',
                  icono: Icons.percent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String titulo,
    required String subtitulo,
    required String valor,
    required IconData icono,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: const Color(0xFFCCFBF1), size: 14),
              const SizedBox(width: 6),
              Text(
                titulo,
                style: const TextStyle(
                  color: Color(0xFFCCFBF1),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            valor,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            subtitulo,
            style: const TextStyle(
              color: Color(0xAAFFFFFF),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCronogramaSection(ThemeData theme) {
    final cronograma = _generarCronograma();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.calendar_month_outlined, color: Color(0xFF0F766E), size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Cronograma de Pagos',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _mostrarCronograma = !_mostrarCronograma);
                  },
                  icon: Icon(
                    _mostrarCronograma ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 16,
                  ),
                  label: Text(_mostrarCronograma ? 'Ocultar' : 'Ver detalle ($_cuotas cuotas)'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF0F766E),
                  ),
                ),
              ],
            ),
          ),
          if (_mostrarCronograma) ...[
            const Divider(height: 1, color: Color(0xFFE2E8F0)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFFF8FAFC)),
                headingTextStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF475569),
                ),
                dataTextStyle: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF1E293B),
                ),
                columnSpacing: 22,
                columns: const [
                  DataColumn(label: Text('#')),
                  DataColumn(label: Text('Fecha')),
                  DataColumn(label: Text('Cuota')),
                  DataColumn(label: Text('Capital')),
                  DataColumn(label: Text('Interés')),
                  DataColumn(label: Text('Saldo Restante')),
                ],
                rows: cronograma.map((c) {
                  return DataRow(
                    cells: [
                      DataCell(Text(
                        '${c.numero}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      )),
                      DataCell(Text(DateFormat('dd/MM/yyyy').format(c.fecha))),
                      DataCell(Text(
                        _formatearMonto(c.cuota),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F766E),
                        ),
                      )),
                      DataCell(Text(_formatearMonto(c.capital))),
                      DataCell(Text(
                        _formatearMonto(c.interes),
                        style: const TextStyle(color: Color(0xFFD97706)),
                      )),
                      DataCell(Text(_formatearMonto(c.saldoRestante))),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
