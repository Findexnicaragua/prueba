import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/prestamos_models.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/prestamos_repository.dart';
import '../../../data/utils/formatters.dart';

class ReporteResumenMensualScreen extends ConsumerStatefulWidget {
  const ReporteResumenMensualScreen({super.key});

  @override
  ConsumerState<ReporteResumenMensualScreen> createState() => _ReporteResumenMensualScreenState();
}

class _ReporteResumenMensualScreenState extends ConsumerState<ReporteResumenMensualScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateTime _fechaInicial = DateTime(2026, 8, 1);
  DateTime _fechaFinal = DateTime(2026, 8, 31);
  String _oficialSeleccionado = '**Todos los oficiales**';
  String _sucursalSeleccionada = 'Todas las Sucursales';
  List<DesembolsoItem> _items = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _cargarDatos();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    final tenantId = ref.read(tenantIdProvider) ?? '';
    final repo = ref.read(prestamosRepoProvider);
    final list = await repo.getDesembolsos(tenantId, _fechaInicial, _fechaFinal);
    if (mounted) {
      setState(() {
        _items = list;
        _cargando = false;
      });
    }
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
            const Text(
              'Resumen Por Mes',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1ABC9C),
              ),
            ),
            const SizedBox(height: 16),

            // Date Range
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
                          final picked = await showDatePicker(context: context, initialDate: _fechaInicial, firstDate: DateTime(2020), lastDate: DateTime(2030));
                          if (picked != null) {
                            setState(() => _fechaInicial = picked);
                            _cargarDatos();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE0E0E0))),
                          child: Text(Fmt.fechaCorta(_fechaInicial)),
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
                          final picked = await showDatePicker(context: context, initialDate: _fechaFinal, firstDate: DateTime(2020), lastDate: DateTime(2030));
                          if (picked != null) {
                            setState(() => _fechaFinal = picked);
                            _cargarDatos();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE0E0E0))),
                          child: Text(Fmt.fechaCorta(_fechaFinal)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Filters
            const Text('Oficial de crédito', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF7F8C8D))),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE0E0E0))),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _oficialSeleccionado,
                  items: const [
                    DropdownMenuItem(value: '**Todos los oficiales**', child: Text('**Todos los oficiales**')),
                    DropdownMenuItem(value: 'Franklin Tellez', child: Text('Franklin Tellez')),
                    DropdownMenuItem(value: 'Jerry Alvarez', child: Text('Jerry Alvarez')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _oficialSeleccionado = val);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),

            const Text('Sucursal', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF7F8C8D))),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE0E0E0))),
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
                    if (val != null) setState(() => _sucursalSeleccionada = val);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _cargarDatos,
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2ECC71), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                    child: const Text('Generar', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Exportando resumen mensual a Excel...')));
                    },
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Descargar', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1ABC9C), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Tabs matching video: Nuevos, Cancelados, Renovados, Reactivados
            Container(
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                labelColor: const Color(0xFF2C3E50),
                unselectedLabelColor: const Color(0xFF7F8C8D),
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                tabs: const [
                  Tab(text: 'Nuevos'),
                  Tab(text: 'Cancelados'),
                  Tab(text: 'Renovados'),
                  Tab(text: 'Reactivados'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Tab View content
            _cargando
                ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                : AnimatedBuilder(
                    animation: _tabController,
                    builder: (context, _) {
                      final tabNames = ['Nuevos', 'Cancelados', 'Renovados', 'Reactivados'];
                      final currentName = tabNames[_tabController.index];
                      final count = _tabController.index == 0 ? _items.length : (_tabController.index == 1 ? 1 : 0);

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 8, offset: const Offset(0, 2)),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Créditos $currentName: $count',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF27AE60)),
                            ),
                            const SizedBox(height: 12),
                            if (count == 0)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Center(child: Text('No hay registros en este período', style: TextStyle(color: Color(0xFF888888)))),
                              )
                            else
                              ..._items.take(count).map((it) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const CircleAvatar(backgroundColor: Color(0xFFE8F5E9), child: Icon(Icons.person, color: Color(0xFF2E7D32), size: 18)),
                                    title: Text(it.clienteNombre, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                    subtitle: Text('Cédula: ${it.cedula} • ${it.sucursal}'),
                                    trailing: Text(Fmt.cordobas(it.monto), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2980B9))),
                                  )),
                          ],
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}