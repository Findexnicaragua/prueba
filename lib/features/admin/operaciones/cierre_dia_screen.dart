import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/prestamos_repository.dart';
import '../../../data/utils/formatters.dart';

class CierreDiaScreen extends ConsumerStatefulWidget {
  const CierreDiaScreen({super.key});

  @override
  ConsumerState<CierreDiaScreen> createState() => _CierreDiaScreenState();
}

class _CierreDiaScreenState extends ConsumerState<CierreDiaScreen> {
  final DateTime _fechaActual = DateTime(2026, 8, 6);
  final int _dia = 6;
  String _mes = 'Agosto';
  bool _procesandoCierre = false;
  bool _procesandoGestiones = false;
  String? _mensajeExito;
  int _gestionesGeneradas = 135;

  final List<String> _meses = const [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'
  ];

  Future<void> _ejecutarCierre() async {
    setState(() {
      _procesandoCierre = true;
      _mensajeExito = null;
    });

    final tenantId = ref.read(tenantIdProvider) ?? '';
    final repo = ref.read(prestamosRepoProvider);
    await Future.delayed(const Duration(milliseconds: 600));
    final res = await repo.ejecutarCierreDia(tenantId, _fechaActual);

    if (mounted) {
      setState(() {
        _procesandoCierre = false;
        _mensajeExito = res['mensaje'] as String? ?? 'Cartera actualizada correctamente!';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mensajeExito!),
          backgroundColor: const Color(0xFF27AE60),
        ),
      );
    }
  }

  Future<void> _crearGestiones() async {
    setState(() => _procesandoGestiones = true);
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      setState(() {
        _procesandoGestiones = false;
        _gestionesGeneradas = 135;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$_gestionesGeneradas gestiones de cobro generadas para los oficiales.'),
          backgroundColor: const Color(0xFF1ABC9C),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FA),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Cierre de Día - Hoy es ${Fmt.fechaCorta(_fechaActual)}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1ABC9C),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Día:', style: TextStyle(color: Color(0xFF7F8C8D), fontWeight: FontWeight.w600)),
                        Text('$_dia', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _mes,
                        items: _meses.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                        onChanged: (val) {
                          if (val != null) setState(() => _mes = val);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _procesandoCierre ? null : _ejecutarCierre,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2ECC71),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                      child: _procesandoCierre
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text(
                              'Cerrar el día',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _procesandoGestiones ? null : _crearGestiones,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1ABC9C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                      child: _procesandoGestiones
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text(
                              'Crear gestiones',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (_mensajeExito != null) ...[
                    Text(
                      _mensajeExito!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFDCFCE7)),
                    ),
                    child: Text(
                      'Para el día de hoy están generadas $_gestionesGeneradas gestiones de cobro',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF15803D),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}