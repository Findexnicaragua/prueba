import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/prestamos_models.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/prestamos_repository.dart';
import '../../../data/utils/formatters.dart';

class DashboardCarteraScreen extends ConsumerWidget {
  const DashboardCarteraScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenantId = ref.watch(tenantIdProvider) ?? '';
    final carteraAsync = ref.watch(resumenCarteraProvider(tenantId));
    final cajaAsync = ref.watch(estadoCajaProvider(tenantId));

    final cartera = carteraAsync.value ?? const ResumenCartera();
    final caja = cajaAsync.value ?? const EstadoCaja();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FA),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(resumenCarteraProvider(tenantId));
          ref.invalidate(estadoCajaProvider(tenantId));
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Bienvenido, admin',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2C3E50),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, color: Color(0xFF2ECC71), size: 8),
                        SizedBox(width: 6),
                        Text(
                          'Online',
                          style: TextStyle(
                            color: Color(0xFF2E7D32),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Cartera Header Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.business_center, color: Color(0xFF34495E), size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Cartera',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2C3E50),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          Fmt.cordobas(cartera.activosMonto),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2980B9),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.circle, color: Color(0xFF2ECC71), size: 10),
                        const SizedBox(width: 4),
                        Text(
                          'Activos ${cartera.activosCount}',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF555555)),
                        ),
                        const SizedBox(width: 16),
                        const Icon(Icons.circle, color: Color(0xFFE74C3C), size: 10),
                        const SizedBox(width: 4),
                        Text(
                          'Mora ${cartera.enMoraCount}',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF555555)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Metrics Grid (Exact visual match from video)
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'clientes',
                      value: '${cartera.clientesCount}',
                      indicatorColor: const Color(0xFF1B3B6F),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      label: 'prestamos',
                      value: '${cartera.prestamosCount}',
                      indicatorColor: const Color(0xFF1B3B6F),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'Activos',
                      value: '${cartera.activosCount} — ${Fmt.cordobas(cartera.activosMonto)}',
                      indicatorColor: const Color(0xFF2980B9),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      label: '⚠ Mora Vigente',
                      value: '${cartera.moraVigenteCount} — ${Fmt.cordobas(cartera.moraVigenteMonto)}',
                      indicatorColor: const Color(0xFFE67E22),
                      valueColor: const Color(0xFFD35400),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'Por vencer',
                      value: '${cartera.porVencerCount} — ${Fmt.cordobas(cartera.porVencerMonto)}',
                      indicatorColor: const Color(0xFF27AE60),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      label: '🔴 Mora Vencida',
                      value: '${cartera.moraVencidaCount} — ${Fmt.cordobas(cartera.moraVencidaMonto)}',
                      indicatorColor: const Color(0xFFC0392B),
                      valueColor: const Color(0xFFC0392B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'Pagados',
                      value: '${cartera.pagadosCount} — ${Fmt.cordobas(cartera.pagadosMonto)}',
                      indicatorColor: const Color(0xFF2ECC71),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      label: 'En Mora',
                      value: '${cartera.enMoraCount} — ${Fmt.cordobas(cartera.enMoraMonto)}',
                      indicatorColor: const Color(0xFFE74C3C),
                      valueColor: const Color(0xFFC0392B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Operational Section
              _StatusItemCard(
                icon: Icons.assignment_late_outlined,
                title: 'Casos Pendientes',
                count: '${cartera.casosPendientesCount}',
                color: const Color(0xFF7F8C8D),
              ),
              const SizedBox(height: 8),
              _StatusItemCard(
                icon: Icons.check_circle_outline,
                title: 'Créditos Aprobados',
                count: '${cartera.creditosAprobadosCount}',
                color: const Color(0xFF27AE60),
              ),
              const SizedBox(height: 8),
              _StatusItemCard(
                icon: Icons.payments_outlined,
                title: 'Desembolsos Hoy',
                count: '${cartera.desembolsosHoyCount} — ${Fmt.cordobas(cartera.desembolsosHoyMonto)}',
                color: const Color(0xFF2980B9),
              ),
              const SizedBox(height: 24),

              // Liquidez & Caja Header
              const Text(
                'Control de Caja y Liquidez',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2C3E50),
                ),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _CajaCard(
                      title: 'CAPITAL RECUPERADO',
                      items: [
                        _CajaRow('Capital recuperado', Fmt.cordobas(caja.capitalRecuperado), const Color(0xFF27AE60)),
                        _CajaRow('Intereses Cobrados', Fmt.cordobas(caja.interesesCobrados), const Color(0xFF27AE60)),
                        _CajaRow('Total Recaudado', Fmt.cordobas(caja.totalRecaudado), const Color(0xFF2E7D32), isBold: true),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _CajaCard(
                      title: 'CAJA',
                      items: [
                        _CajaRow('Caja inicial', Fmt.cordobas(caja.cajaInicial), const Color(0xFF8E44AD), isBold: true),
                        _CajaRow('Capital aportado', Fmt.cordobas(caja.capitalAportado), const Color(0xFF2980B9)),
                        _CajaRow('+ Ingresos netos', Fmt.cordobas(caja.ingresosNetos), const Color(0xFF27AE60)),
                        _CajaRow('- Egresos', Fmt.cordobas(caja.egresos), const Color(0xFFC0392B)),
                        _CajaRow('= Caja actual', Fmt.cordobas(caja.cajaActual), const Color(0xFF8E44AD), isBold: true),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _SimpleStatCard(
                      icon: Icons.money_off,
                      title: 'GASTOS DIARIOS',
                      amount: Fmt.cordobas(caja.gastosDiarios),
                      subtitle: 'De ingresos: C\$ 0.00\nDinero que no regresa',
                      amountColor: const Color(0xFFE67E22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SimpleStatCard(
                      icon: Icons.handshake,
                      title: 'CAJA DE PRÉSTAMOS',
                      amount: Fmt.cordobas(caja.cajaPrestamos),
                      subtitle: 'Disponible para prestar',
                      amountColor: const Color(0xFF2980B9),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              _SimpleStatCard(
                icon: Icons.account_balance,
                title: 'BANCOS',
                amount: Fmt.cordobas(caja.bancos),
                subtitle: 'Fondos en cuentas bancarias',
                amountColor: const Color(0xFF16A085),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final Color indicatorColor;
  final Color? valueColor;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.indicatorColor,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(color: indicatorColor, width: 4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF555555),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: valueColor ?? const Color(0xFF2C3E50),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusItemCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String count;
  final Color color;

  const _StatusItemCard({
    required this.icon,
    required this.title,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2C3E50),
                ),
              ),
            ],
          ),
          Text(
            count,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _CajaCard extends StatelessWidget {
  final String title;
  final List<_CajaRow> items;

  const _CajaCard({
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF7F8C8D),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          ...items.map((it) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        it.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: it.isBold ? FontWeight.bold : FontWeight.normal,
                          color: const Color(0xFF555555),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      it.value,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: it.isBold ? FontWeight.bold : FontWeight.w600,
                        color: it.color,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

class _CajaRow {
  final String label;
  final String value;
  final Color color;
  final bool isBold;

  _CajaRow(this.label, this.value, this.color, {this.isBold = false});
}

class _SimpleStatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String amount;
  final String subtitle;
  final Color amountColor;

  const _SimpleStatCard({
    required this.icon,
    required this.title,
    required this.amount,
    required this.subtitle,
    required this.amountColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: const Color(0xFF7F8C8D)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF7F8C8D),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            amount,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: amountColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 10,
              color: Color(0xFF888888),
            ),
          ),
        ],
      ),
    );
  }
}