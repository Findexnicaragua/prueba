import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/prestamos_models.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/prestamos_repository.dart';
import '../../../data/utils/formatters.dart';

class ReporteDesembolsosScreen extends ConsumerStatefulWidget {
  const ReporteDesembolsosScreen({super.key});

  @override
  ConsumerState<ReporteDesembolsosScreen> createState() => _ReporteDesembolsosScreenState();
}

class _ReporteDesembolsosScreenState extends ConsumerState<ReporteDesembolsosScreen> {
  DateTime _fechaInicial = DateTime(2026, 8, 1);
  DateTime _fechaFinal = DateTime(2026, 8, 6);
  String _sucursalSeleccionada = 'Todas las Sucursales';
  List<DesembolsoItem> _items = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    final tenantId = ref.read(tenantIdProvider) ?? '';
    final repo = ref.read(prestamosRepoProvider);
    final list = await repo.getDesembolsos(
      tenantId,
      _fechaInicial,
      _fechaFinal,
      sucursal: _sucursalSeleccionada == 'Todas las Sucursales' ? null : _sucursalSeleccionada,
    );
    if (mounted) {
      setState(() {
        _items = list;
        _cargando = false;
      });
    }
  }

  void _mostrarActaComite() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.assignment, color: Color(0xFF2C3E50)),
            SizedBox(width: 8),
            Text('Acta de Comité de Crédito', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Período: ${Fmt.fechaCorta(_fechaInicial)} al ${Fmt.fechaCorta(_fechaFinal)}',
                style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF555555)),
              ),
              const SizedBox(height: 8),
              Text('Total de Créditos Aprobados: ${_items.length}'),
              Text('Monto Total Desembolsado: ${Fmt.cordobas(_items.fold(0.0, (acc, it) => acc + it.monto))}'),
              const Divider(height: 24),
              const Text('Miembros del Comité:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('1. Gerencia de Crédito: ____________________'),
              const SizedBox(height: 6),
              const Text('2. Oficial de Cumplimiento: _______________'),
              const SizedBox(height: 6),
              const Text('3. Supervisor de Cartera: __________________'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Acta de Comité descargada / lista para imprimir')),
              );
            },
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Descargar PDF'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2ECC71),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FA),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            const Text(
              'Reporte de Desembolsos',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1ABC9C),
              ),
            ),
            const SizedBox(height: 16),

            // Date Filters Row
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Fecha inicial', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF7F8C8D))),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _fechaInicial,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setState(() => _fechaInicial = picked);
                            _cargarDatos();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE0E0E0)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(Fmt.fechaCorta(_fechaInicial)),
                              const Icon(Icons.calendar_today, size: 16, color: Color(0xFF7F8C8D)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Fecha final', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF7F8C8D))),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _fechaFinal,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setState(() => _fechaFinal = picked);
                            _cargarDatos();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE0E0E0)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(Fmt.fechaCorta(_fechaFinal)),
                              const Icon(Icons.calendar_today, size: 16, color: Color(0xFF7F8C8D)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Branch Dropdown
            const Text('Filtrar por Sucursal', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF7F8C8D))),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE0E0E0)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _sucursalSeleccionada,
                  items: const [
                    DropdownMenuItem(value: 'Todas las Sucursales', child: Text('Todas las Sucursales')),
                    DropdownMenuItem(value: 'Chinandega', child: Text('Chinandega')),
                    DropdownMenuItem(value: 'Somotillo', child: Text('Somotillo')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _sucursalSeleccionada = val);
                      _cargarDatos();
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Action Buttons
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _cargarDatos,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2ECC71),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Actualizar', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Generando reporte Excel de desembolsos...')),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1ABC9C),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Descargar', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _mostrarActaComite,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7F8C8D),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Acta Comité', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 20),

            // Table of Disbursed Loans
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _cargando
                  ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                  : Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
                          ),
                          child: const Row(
                            children: [
                              SizedBox(width: 30, child: Text('#', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7F8C8D)))),
                              SizedBox(width: 80, child: Text('Código', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7F8C8D)))),
                              Expanded(child: Text('Cliente', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7F8C8D)))),
                              SizedBox(width: 90, child: Text('Monto', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7F8C8D)))),
                            ],
                          ),
                        ),
                        ..._items.asMap().entries.map((entry) {
                          final idx = entry.key + 1;
                          final it = entry.value;
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
                            ),
                            child: Row(
                              children: [
                                SizedBox(width: 30, child: Text('$idx', style: const TextStyle(color: Color(0xFF555555)))),
                                SizedBox(width: 80, child: Text(it.codigo, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2C3E50)))),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(it.clienteNombre, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                                      Text('${it.sucursal} • ${it.oficialNombre}', style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    Fmt.cordobas(it.monto),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF27AE60), fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}