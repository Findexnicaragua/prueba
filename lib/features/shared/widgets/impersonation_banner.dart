import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/theme.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/services/impersonation_service.dart';
import '../../../data/utils/errores.dart';
import '../../../powersync/db.dart' as ps;

/// Banner que avisa al super_admin que está VIENDO/gestionando un tenant
/// impersonado, con un botón "Salir" para terminar la impersonación.
///
/// **Self-gating** (#9a): si no hay impersonación activa, renderiza
/// `SizedBox.shrink()`. Así puede ponerse al tope del body de CUALQUIER
/// pantalla (incluidas las push fuera del AdminShell: detalle de cliente/
/// contrato, cobro, recibo) sin lógica condicional en cada caller — el
/// contexto donde más importa que el super_admin sepa en qué tenant está.
class ImpersonationBanner extends ConsumerStatefulWidget {
  const ImpersonationBanner({super.key});

  @override
  ConsumerState<ImpersonationBanner> createState() =>
      _ImpersonationBannerState();
}

class _ImpersonationBannerState extends ConsumerState<ImpersonationBanner> {
  bool _saliendo = false;

  Future<void> _salir() async {
    setState(() => _saliendo = true);
    // Estado optimista: el efectivo pasa a "no impersonando" YA, así el router
    // no rebota /super/tenants→/admin por la fila local stale (audit 2026-07-04).
    ref.read(pendingImpersonacionProvider.notifier).state =
        const PendingImpersonacion.saliendo();
    try {
      await ImpersonationService(Supabase.instance.client).exit();
      if (!mounted) return;
      context.go('/super/tenants');
    } catch (e) {
      // Si el exit falla (red), revertir el optimista para no quedar en un
      // estado falso de "no impersonando" mientras la fila sigue viva.
      ref.read(pendingImpersonacionProvider.notifier).state = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(mensajeErrorHumano(e, contexto: 'salir del tenant'))),
      );
      setState(() => _saliendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tenantId = ref.watch(impersonatedTenantIdProvider).valueOrNull;
    // Self-gating: sin impersonación, no se muestra nada.
    if (tenantId == null) return const SizedBox.shrink();

    final empresaAsync =
        ref.watch(impersonatedEmpresaNombreProvider(tenantId));
    final nombre = empresaAsync.when(
      data: (n) => n ?? 'Tenant sin nombre',
      loading: () => 'Cargando…',
      error: (_, __) => 'Tenant',
    );
    // Color de ALERTA (#CC7700), no primaryContainer: este theme no deriva de
    // un seed, así que primaryContainer es un celeste al 8% casi invisible que
    // se fundía con el header del cliente. El banner debe gritar "estás en OTRO
    // tenant" (#9a / finding de audit UX).
    return Material(
      color: AppColors.warning,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.shield, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Dev · Viendo: $nombre',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _saliendo
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : TextButton.icon(
                    icon: const Icon(Icons.exit_to_app, size: 18),
                    label: const Text('Salir'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _salir,
                  ),
          ],
        ),
      ),
    );
  }
}

/// Nombre del tenant impersonado, scoped por tenant_id. Lee de la tabla
/// `settings` local filtrando por el tenant_id específico (evita ambigüedad
/// cuando hay settings de múltiples tenants en SQLite).
///
/// autoDispose + family: se destruye al salir de impersonación.
final impersonatedEmpresaNombreProvider =
    StreamProvider.autoDispose.family<String?, String?>((ref, tenantId) async* {
  if (tenantId == null) {
    yield null;
    return;
  }
  yield* ps.db
      .watch(
        "SELECT valor FROM settings WHERE tenant_id = ? AND clave = 'empresa.nombre'",
        parameters: [tenantId],
      )
      .map((rows) {
    if (rows.isEmpty) return null;
    final v = rows.first['valor'] as String?;
    if (v == null) return null;
    final s = v.trim();
    if (s == 'null' || s == '""' || s.isEmpty) return null;
    // Remove JSON wrapping quotes: "\"ISP Las Lomas\"" → "ISP Las Lomas"
    if (s.startsWith('"') && s.endsWith('"') && s.length > 1) {
      return s.substring(1, s.length - 1);
    }
    return s;
  });
});
