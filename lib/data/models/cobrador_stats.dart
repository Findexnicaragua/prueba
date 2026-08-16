/// Stats agregadas de un cobrador para la pantalla de detalle del
/// panel super_admin. Llega desde la RPC `get_cobrador_stats`.
class CobradorStats {
  const CobradorStats({
    required this.id,
    this.lastSignInAt,
    required this.clientesAsignados,
    required this.pagosMesCount,
    required this.pagosMesTotal,
  });

  final String id;
  final DateTime? lastSignInAt;
  final int clientesAsignados;
  final int pagosMesCount;
  final double pagosMesTotal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CobradorStats &&
          other.id == id &&
          other.lastSignInAt == lastSignInAt &&
          other.clientesAsignados == clientesAsignados &&
          other.pagosMesCount == pagosMesCount &&
          other.pagosMesTotal == pagosMesTotal;

  @override
  int get hashCode => Object.hash(
        id,
        lastSignInAt,
        clientesAsignados,
        pagosMesCount,
        pagosMesTotal,
      );

  factory CobradorStats.fromMap(Map<String, dynamic> m) => CobradorStats(
        id: m['id'] as String,
        lastSignInAt: m['last_sign_in_at'] != null
            ? DateTime.parse(m['last_sign_in_at'] as String)
            : null,
        clientesAsignados:
            (m['clientes_asignados'] as num?)?.toInt() ?? 0,
        pagosMesCount: (m['pagos_mes_count'] as num?)?.toInt() ?? 0,
        pagosMesTotal:
            (m['pagos_mes_total'] as num?)?.toDouble() ?? 0.0,
      );
}
