import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/prestamos_models.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/prestamos_repository.dart';
import '../../../data/utils/formatters.dart';

class ReporteIndicadoresScreen extends ConsumerStatefulWidget {
  const ReporteIndicadoresScreen({super.key});

  @override
  ConsumerState<ReporteIndicadoresScreen> createState() => _ReporteIndicadoresScreenState();
}

class _ReporteIndicadoresScreenState extends ConsumerState<ReporteIndicadoresScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateTime _fecha = DateTime(2026, 8, 6);
  String _sucursalSeleccionada = 'Todas las Sucursales';
  List<IndicadorOficial> _oficiales = [];
  List<IndicadorSucursal> _sucursales = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
    final oficialesList = await repo.getIndicadoresOficiales(tenantId, _fecha);
    final sucursalesList = await repo.getIndicadoresSucursales(tenantId, _fecha);
    if (mounted) {
      setState(() {
        _oficiales = oficialesList;
        _sucursales = sucursalesList;
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
            // Title
            const Text(
              'Reporte de Indicadores',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1ABC9C),
              ),
            ),
            const SizedBox(height: 16),

            // Filters Container
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonHideUnderline(
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
                  const Divider(height: 16),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _fecha,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2030),
                      );
                      if (picked != null) {
                        setState(() => _fecha = picked);
                        _cargarDatos();
                      }
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Fecha: ${Fmt.fechaCorta(_fecha)}',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const Icon(Icons.calendar_today, size: 16, color: Color(0xFF7F8C8D)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Tab Bar
            Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                labelColor: const Color(0xFF2C3E50),
                unselectedLabelColor: const Color(0xFF7F8C8D),
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                tabs: const [
                  Tab(text: 'Oficiales'),
                  Tab(text: 'Sucursales'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Content
            if (_cargando)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else
              AnimatedBuilder(
                animation: _tabController,
                builder: (context, _) {
                  if (_tabController.index == 0) {
                    return Column(
                      children: _oficiales.map((of) => _OficialCard(oficial: of)).toList(),
                    );
                  } else {
                    return Column(
                      children: _sucursales.map((suc) => _SucursalCard(sucursal: suc)).toList(),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _OficialCard extends StatelessWidget {
  final IndicadorOficial oficial;

  const _OficialCard({required this.oficial});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF6C7A89),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      oficial.nombre,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      oficial.sucursal,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFE0E0E0),
                      ),
                    ),
                  ],
                ),
                Text(
                  Fmt.fechaCorta(oficial.fecha),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                _IndicatorRow(
                  icon: Icons.account_balance_wallet,
                  iconColor: const Color(0xFF2ECC71),
                  label: 'Saldo de cartera:',
                  value: Fmt.cordobas(oficial.saldoCartera),
                  valueColor: const Color(0xFF2980B9),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.assignment,
                  iconColor: const Color(0xFF3498DB),
                  label: 'Préstamos Totales:',
                  value: '${oficial.prestamosTotales}',
                  valueColor: const Color(0xFF2C3E50),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.pie_chart,
                  iconColor: const Color(0xFF1ABC9C),
                  label: 'Porcentaje de Mora Total:',
                  value: '${oficial.porcentajeMoraTotal.toStringAsFixed(2)}%',
                  valueColor: oficial.porcentajeMoraTotal > 10 ? const Color(0xFFC0392B) : const Color(0xFF27AE60),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.warning_amber_rounded,
                  iconColor: const Color(0xFFE67E22),
                  label: 'Monto en Mora Total:',
                  value: Fmt.cordobas(oficial.montoMoraTotal),
                  valueColor: const Color(0xFFC0392B),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.savings,
                  iconColor: const Color(0xFFF1C40F),
                  label: 'Recuperac. del Mes:',
                  value: Fmt.cordobas(oficial.recuperacionMes),
                  valueColor: const Color(0xFF27AE60),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SucursalCard extends StatelessWidget {
  final IndicadorSucursal sucursal;

  const _SucursalCard({required this.sucursal});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF2C3E50),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Sucursal: ${sucursal.sucursal}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Icon(Icons.location_city, color: Colors.white70, size: 20),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                _IndicatorRow(
                  icon: Icons.account_balance_wallet,
                  iconColor: const Color(0xFF2ECC71),
                  label: 'Saldo de cartera:',
                  value: Fmt.cordobas(sucursal.saldoCartera),
                  valueColor: const Color(0xFF2980B9),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.people,
                  iconColor: const Color(0xFF3498DB),
                  label: 'Clientes Totales:',
                  value: '${sucursal.clientesTotales}',
                  valueColor: const Color(0xFF2C3E50),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.pie_chart,
                  iconColor: const Color(0xFF1ABC9C),
                  label: '% Mora General:',
                  value: '${sucursal.porcentajeMoraTotal.toStringAsFixed(2)}%',
                  valueColor: sucursal.porcentajeMoraTotal > 10 ? const Color(0xFFC0392B) : const Color(0xFF27AE60),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.warning_amber_rounded,
                  iconColor: const Color(0xFFE67E22),
                  label: 'Monto en Mora:',
                  value: Fmt.cordobas(sucursal.montoMoraTotal),
                  valueColor: const Color(0xFFC0392B),
                ),
                const Divider(height: 16),
                _IndicatorRow(
                  icon: Icons.savings,
                  iconColor: const Color(0xFFF1C40F),
                  label: 'Recuperación Mes:',
                  value: Fmt.cordobas(sucursal.recuperacionMes),
                  valueColor: const Color(0xFF27AE60),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IndicatorRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final Color valueColor;

  const _IndicatorRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF555555), fontWeight: FontWeight.w500),
          ),
        ),
        Text(
          value,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: valueColor),
        ),
      ],
    );
  }
}