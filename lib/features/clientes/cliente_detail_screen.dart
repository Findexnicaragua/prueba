import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/router.dart' show empresaNombreProvider;
import '../../config/theme.dart';
import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/utils/op_log.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/providers/contrato_providers.dart';
import '../../data/providers/logo_empresa_provider.dart';
import '../../data/providers/modulos_provider.dart';
import '../../data/repositories/clientes_repo.dart';
import '../../data/repositories/contratos_repo.dart';
import '../../data/repositories/etiquetas_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/external_actions.dart';
import '../../data/services/visitas_service.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/etiqueta_chip.dart';
import '../cobro/cobro_puntual_dialog.dart';
import '../contratos/contrato_detail_header.dart' show ContratoHeaderCard;
import '../shared/widgets/foto_gallery_widget.dart';
import '../shared/widgets/impersonation_banner.dart';
import '../shared/widgets/historial_op_log.dart';
import '../admin/reportes/descarga_archivo.dart';
import '../admin/reportes/pdf/reporte_historial_cliente_pdf.dart';

class ClienteDetailScreen extends ConsumerStatefulWidget {
  const ClienteDetailScreen({super.key, required this.clienteId});
  final String clienteId;

  @override
  ConsumerState<ClienteDetailScreen> createState() =>
      _ClienteDetailScreenState();
}

class _ClienteDetailScreenState extends ConsumerState<ClienteDetailScreen> {
  final _visitasKey = GlobalKey<_VisitasSectionState>();
  // Pestaña activa del detalle (Detalle / Contratos / Equipos / Visitas).
  int _tab = 0;

  void _showHistorial(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial de cambios',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: HistorialOpLog(
                    entidad: 'clientes', entidadId: widget.clienteId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Historial de pagos imprimible (PDF). Pide el período (opciones fijas,
  /// tope 1 año) y genera el estado de cuenta del cliente.
  Future<void> _imprimirHistorial(BuildContext context) async {
    final sel =
        await showDialog<({DateTime desde, DateTime hasta, String label})>(
      context: context,
      builder: (ctx) {
        // "Hoy" en hora Nicaragua (UTC-6, sin DST) para los cortes de día.
        final nowNi = DateTime.now().toUtc().subtract(const Duration(hours: 6));
        final hoy = DateTime(nowNi.year, nowNi.month, nowNi.day);
        return SimpleDialog(
          title: const Text('Historial de pagos'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (
                desde: DateTime(hoy.year - 1, hoy.month, hoy.day),
                hasta: hoy,
                label: 'Últimos 12 meses',
              )),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.calendar_month_outlined),
                title: Text('Últimos 12 meses'),
                subtitle: Text('Un año hacia atrás contado desde hoy'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (
                desde: DateTime(hoy.year, 1, 1),
                hasta: hoy,
                label: 'Año ${hoy.year}',
              )),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text('Este año (${hoy.year})'),
                subtitle: const Text('Desde el 1 de enero hasta hoy'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (
                desde: DateTime(hoy.year - 1, 1, 1),
                hasta: DateTime(hoy.year - 1, 12, 31),
                label: 'Año ${hoy.year - 1}',
              )),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: Text('Año pasado (${hoy.year - 1})'),
                subtitle: const Text('El año calendario completo, enero a diciembre'),
              ),
            ),
          ],
        );
      },
    );
    if (sel == null || !context.mounted) return;
    await _generarHistorialPdf(context, sel.desde, sel.hasta);
  }

  Future<void> _generarHistorialPdf(
      BuildContext context, DateTime desde, DateTime hasta) async {
    String dos(int n) => n.toString().padLeft(2, '0');
    String sql(DateTime d) => '${d.year}-${dos(d.month)}-${dos(d.day)}';
    try {
      final cRows = await ps.db.getAll('''
        SELECT c.codigo, c.nombre, c.cedula, c.telefono, c.direccion,
               c.direccion_referencia, co.nombre AS comunidad,
               cb.nombre AS cobrador_asignado
          FROM clientes c
          LEFT JOIN comunidades co ON co.id = c.comunidad_id
          LEFT JOIN cobradores cb ON cb.id = c.cobrador_id
         WHERE c.id = ? LIMIT 1
      ''', [widget.clienteId]);
      final cliente = cRows.isEmpty ? <String, dynamic>{} : cRows.first;

      // Pagos vigentes (no anulados) del cliente, de TODOS sus contratos, en
      // el rango. fecha_pago es local-naive Nicaragua → date() corta el día
      // local sin necesitar el offset.
      final rows = await ps.db.getAll('''
        SELECT pa.fecha_pago, cu.periodo AS periodo,
               ct2.dia_pago AS dia_pago, r.numero_completo AS recibo,
               cb.nombre AS cobrador, pa.metodo, pa.referencia,
               pa.moneda, pa.monto_cordobas, pa.monto_original
          FROM pagos pa
          JOIN cuotas cu ON cu.id = pa.cuota_id
          -- dia_pago: ancla del mes de SERVICIO que se imprime (§3.5). LEFT
          -- porque una cuota manual puede no tener contrato.
          LEFT JOIN contratos ct2 ON ct2.id = cu.contrato_id
          LEFT JOIN cobradores cb ON cb.id = pa.cobrador_id
          LEFT JOIN recibos r ON r.pago_id = pa.id
         WHERE cu.cliente_id = ?
           AND COALESCE(pa.anulado, 0) = 0 AND COALESCE(pa.en_revision, 0) = 0
           AND date(pa.fecha_pago) BETWEEN ? AND ?
         ORDER BY pa.fecha_pago DESC
      ''', [widget.clienteId, sql(desde), sql(hasta)]);

      final empresaNombre =
          ref.read(empresaNombreProvider).valueOrNull ?? 'ISP';
      Uint8List? logoBytes;
      try {
        logoBytes = await ref.read(logoEmpresaBytesProvider.future);
      } catch (_) {/* sin logo → header solo texto */}

      final doc = await buildHistorialClientePdf(
        empresaNombre: empresaNombre,
        periodo: '${Fmt.fechaCorta(desde)} – ${Fmt.fechaCorta(hasta)}',
        cliente: cliente,
        rows: rows,
        logoBytes: logoBytes,
      );
      final codigo = (cliente['codigo']?.toString() ?? 'cliente')
          .replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final bytes = await doc.save();
      if (!context.mounted) return;
      await guardarPdfConAviso(
        context,
        fileName: 'historial_pagos_$codigo.pdf',
        bytes: bytes,
        mensaje: 'Historial de pagos guardado',
      );
    } catch (e) {
      if (context.mounted) {
        final msg = e is UnsupportedError
            ? (e.message?.toString() ??
                'Exportación no soportada en esta plataforma')
            : mensajeErrorHumano(e, contexto: 'generar el historial de pagos');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final clienteAsync = ref.watch(clienteByIdProvider(widget.clienteId));
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final impersonando = ref.watch(estaImpersonandoProvider);
    // admin/admin_cobranza/admin_usuarios gestionan clientes/contratos.
    // admin_usuarios NO toca dinero (cobros/pagos/reportes) → `puedeCobrar`.
    final puedeGestionar = (cobrador?.tieneAccesoAdmin ?? false) ||
        (cobrador?.esAdminCobranza ?? false) ||
        (cobrador?.esAdminUsuarios ?? false);
    final esAdminUsuarios = cobrador?.esAdminUsuarios ?? false;
    final puedeCobrar = puedeGestionar && !esAdminUsuarios;
    // VER dinero ≠ COBRAR. `puedeCobrar` gobernaba las dos cosas, así que el rol
    // `lectura` (0198) —cuyo requisito es "ve todo, incluida la plata"— se
    // quedaba sin saldo a favor, historial de pagos, el PDF y la pestaña de
    // equipos. Las ACCIONES siguen con `puedeCobrar`; lo que solo muestra usa
    // este flag.
    final verDinero = puedeCobrar || (cobrador?.esLectura ?? false);
    // El change-log / auditoría se oculta al cobrador puro (least-privilege:
    // si el rol aún no cargó → null → oculto). admin/admin_cobranza/super sí.
    final verHistorial = cobrador != null && !cobrador.esCobrador;
    final loc = GoRouterState.of(context).uri.path;
    final enAdminShell = loc.startsWith('/admin');
    // Sección "Equipos instalados" solo si el módulo Inventario está activo
    // para el tenant (tenant_modulos). Si el rol/módulos aún no cargó → oculto.
    final inventarioOn =
        ref.watch(modulosHabilitadosProvider).valueOrNull?.contains('inventario') ??
            false;
    // "Cobro extra" (cobro puntual: multa/otro) solo si el super_admin habilitó
    // el toggle para el tenant (0177). Default OFF → oculto.
    final cobroExtraOn = ref.watch(appSettingsProvider).cobroExtraHabilitado;

    return Scaffold(
      appBar: AppBar(
        title: clienteAsync.when(
          data: (c) => Text(c?.nombre ?? 'Cliente',
              overflow: TextOverflow.ellipsis),
          loading: () => const Text('Cliente'),
          error: (_, __) => const Text('Cliente'),
        ),
        actions: [
          // Cobro de una multa / cargo que DECIDE el admin (no del ciclo del
          // contrato). Con TEXTO, no solo ícono, para que sea descubrible (audit
          // UX 2026-06-30). Bloqueado al impersonar (atribución al usuario real).
          // Gateado por el toggle super_admin 'cobranza.cobro_extra' (0177).
          if (puedeCobrar && !impersonando && cobroExtraOn)
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Cobro extra'),
              onPressed: () async {
                final cuotaId = await mostrarCobroPuntual(context,
                    clienteId: widget.clienteId);
                if (cuotaId == null || !context.mounted) return;
                context.push('/cobro/$cuotaId');
              },
            ),
          if (verDinero)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Historial de pagos (PDF)',
              onPressed: () => _imprimirHistorial(context),
            ),
          if (puedeGestionar)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Editar cliente',
              onPressed: () {
                final editPath = enAdminShell
                    ? '/admin/clientes/${widget.clienteId}/editar'
                    : '/clientes/${widget.clienteId}/editar';
                context.push(editPath);
              },
            ),
          if (verHistorial)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de cambios',
              onPressed: () => _showHistorial(context),
            ),
        ],
      ),
      // "Registrar visita" se movió a la pestaña Visitas (gateada por el setting
      // super-admin `cobranza.registrar_visitas`). Sin FAB global.
      body: clienteAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(mensajeErrorHumano(e))),
        data: (cliente) {
          if (cliente == null) {
            return const EmptyState(
              icon: Icons.person_off,
              titulo: 'Cliente no encontrado',
            );
          }
          // Aprovechar espacio en pantallas grandes: maxWidth 1100,
          // centrado. Mobile usa todo el ancho disponible.
          final registrarVisitasOn =
              ref.watch(appSettingsProvider).registrarVisitasHabilitado;
          final equiposOn = inventarioOn && verDinero;

          // Contenido de cada pestaña (cada uno scrollea solo).
          final detalleTab = ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              if (verDinero)
                _SaldoFavorSection(clienteId: widget.clienteId),
              _EtiquetasSection(
                clienteId: widget.clienteId,
                tenantId: cliente.tenantId,
                puedeGestionar: puedeGestionar,
              ),
              const SizedBox(height: 8),
              // 2 columnas en ancho (info | fotos); apilado en angosto.
              LayoutBuilder(
                builder: (ctx, c) {
                  final info = _ClienteInfo(
                      cliente: cliente, puedeGestionar: puedeGestionar);
                  final fotos = Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FotoGalleryWidget(
                      clienteId: widget.clienteId,
                      tenantId: cliente.tenantId,
                      canEdit: puedeGestionar,
                    ),
                  );
                  if (c.maxWidth >= 760) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: info),
                        Expanded(flex: 2, child: fotos),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [info, const SizedBox(height: 8), fotos],
                  );
                },
              ),
              if (verDinero)
                _HistorialPagosSection(clienteId: widget.clienteId),
            ],
          );
          final contratosTab = ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              _ContratosSection(
                clienteId: widget.clienteId,
                esAdmin: puedeGestionar,
                enAdminShell: enAdminShell,
              ),
            ],
          );
          final equiposTab = ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              _EquiposInstaladosSection(
                clienteId: widget.clienteId,
                // Solo quien REALMENTE entra a /admin/inventario/* (admin ∪
                // super_admin) puede saltar a la ficha. admin_cobranza VE el
                // tab pero NO navega: el router bloquea /admin/inventario para
                // su rol (soloAdmin) → un go lo expulsaría al home /admin
                // perdiendo la ficha Y el detalle del cliente (audit Fase 2).
                navegable:
                    (cobrador?.tieneAccesoAdmin ?? false) && enAdminShell,
              ),
            ],
          );
          final visitasTab = ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              // La visita se atribuye al usuario; impersonando se oculta (#9).
              // `lectura` (0198) tampoco: registrar una visita es escribir.
              if (!impersonando && !ref.watch(soloLecturaProvider))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => _mostrarDialogVisita(context),
                      icon: const Icon(Icons.add_task),
                      label: const Text('Registrar visita'),
                    ),
                  ),
                ),
              _VisitasSection(key: _visitasKey, clienteId: widget.clienteId),
            ],
          );

          final tabs = <({String label, IconData icon, Widget content})>[
            (label: 'Detalle', icon: Icons.person_outline, content: detalleTab),
            (
              label: 'Contratos',
              icon: Icons.description_outlined,
              content: contratosTab
            ),
            if (equiposOn)
              (label: 'Equipos', icon: Icons.router, content: equiposTab),
            if (registrarVisitasOn)
              (label: 'Visitas', icon: Icons.add_task, content: visitasTab),
          ];
          final tabIndex = _tab.clamp(0, tabs.length - 1);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                children: [
                  if (!enAdminShell) const ImpersonationBanner(),
                  // Pestañas en forma de botones.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Row(
                      children: [
                        for (int i = 0; i < tabs.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          Expanded(
                            child: _TabButton(
                              label: tabs[i].label,
                              icon: tabs[i].icon,
                              selected: i == tabIndex,
                              onTap: () => setState(() => _tab = i),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Identidad del cliente fija en todas las pestañas.
                  _ClienteHeader(
                    codigo: cliente.codigo,
                    nombre: cliente.nombre,
                    telefono: cliente.telefono,
                    tieneUbicacion: cliente.tieneUbicacion,
                    latitud: cliente.latitud,
                    longitud: cliente.longitud,
                  ),
                  // Contenido de la pestaña activa (solo se monta esa).
                  Expanded(child: tabs[tabIndex].content),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _mostrarDialogVisita(BuildContext context) async {
    final resultado =
        await showDialog<({VisitaResultado resultado, String? notas})>(
      context: context,
      builder: (_) => const _RegistrarVisitaDialog(),
    );
    if (resultado == null || !context.mounted) return;

    final service = ref.read(visitasServiceProvider);
    try {
      await service.registrar(
        clienteId: widget.clienteId,
        resultado: resultado.resultado,
        notas: resultado.notas,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Visita registrada')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(mensajeErrorHumano(e,
                  contexto: 'registrar la visita'))),
        );
      }
    }
  }
}

String _inicialesDe(String nombre) {
  final parts = nombre.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

class _ClienteHeader extends StatelessWidget {
  const _ClienteHeader({
    required this.codigo,
    required this.nombre,
    required this.telefono,
    required this.tieneUbicacion,
    required this.latitud,
    required this.longitud,
  });
  final String? codigo;
  final String nombre;
  final String? telefono;
  final bool tieneUbicacion;
  final double? latitud;
  final double? longitud;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: Text(
                  _inicialesDe(nombre),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 18),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (codigo != null)
                      Text(codigo!,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                                letterSpacing: 0.5,
                              )),
                    Text(nombre,
                        style: Theme.of(context).textTheme.headlineSmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (telefono != null && telefono!.isNotEmpty)
                _IconButton(
                  icon: Icons.phone,
                  label: 'Llamar',
                  onTap: () => ExternalActions.llamar(context, telefono!),
                ),
              if (tieneUbicacion)
                _IconButton(
                  icon: Icons.directions,
                  label: 'Navegar',
                  onTap: () => ExternalActions.navegarA(
                    context,
                    lat: latitud!,
                    lng: longitud!,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

/// Saldo a favor del CLIENTE (crédito por excedente, 0127). Solo admin/
/// admin_cobranza. Muestra el disponible + "Aplicar" a la cuota pendiente más
/// vieja entre TODOS sus contratos activos (oldest-first global — el crédito es a
/// nivel cliente, cruza contratos). Oculto si no hay saldo o el setting está OFF.
class _SaldoFavorSection extends ConsumerStatefulWidget {
  const _SaldoFavorSection({required this.clienteId});
  final String clienteId;
  @override
  ConsumerState<_SaldoFavorSection> createState() => _SaldoFavorSectionState();
}

class _SaldoFavorSectionState extends ConsumerState<_SaldoFavorSection> {
  late final Stream<List<Map<String, dynamic>>> _stream;
  bool _aplicando = false;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      "SELECT COALESCE(SUM(CASE WHEN tipo='acreditado' THEN monto "
      'ELSE -monto END), 0) AS d FROM saldos_favor WHERE cliente_id = ?',
      parameters: [widget.clienteId],
    );
  }

  Future<void> _aplicar(double disponible) async {
    // Aplicar crédito es acción de dinero atribuida (cargo + saldos_favor con
    // creado_por = el usuario): bloqueada al impersonar, igual que cobrar/
    // suspender/cancelar.
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
    // Cuota pendiente/parcial MÁS VIEJA entre los contratos ACTIVOS del cliente.
    final rows = await ps.db.getAll(
      '''
      SELECT cu.id, cu.periodo, ct.dia_pago AS dia_pago,
             (cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0)) AS saldo
        FROM cuotas cu JOIN contratos ct ON ct.id = cu.contrato_id
       WHERE cu.cliente_id = ? AND cu.estado IN ('pendiente','parcial')
         AND COALESCE(ct.estado, 'activo') = 'activo'
         AND (cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0)) > 0.005
       ORDER BY date(cu.fecha_vencimiento) ASC LIMIT 1
      ''',
      [widget.clienteId],
    );
    if (rows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No hay cuotas pendientes para aplicar el saldo.')));
      }
      return;
    }
    final r = rows.first;
    final cuotaId = r['id'] as String;
    final periodo = DateTime.parse(r['periodo'] as String);
    final diaPago = (r['dia_pago'] as num?)?.toInt();
    final saldoCuota = (r['saldo'] as num).toDouble();
    final aplicar = disponible < saldoCuota ? disponible : saldoCuota;
    final mesLabel = Fmt.mesServicioLabel(periodo, diaPago);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aplicar saldo a favor'),
        content: Text(
            'Se aplican ${Fmt.cordobas(aplicar)} a la cuota de $mesLabel '
            '(queda en ${Fmt.cordobas(saldoCuota - aplicar)}). No entra plata: '
            'es cobertura con el saldo a favor del cliente.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Aplicar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _aplicando = true);
    try {
      final aplicado =
          await ContratosRepo().aplicarCredito(cuotaId: cuotaId, cobradorId: me.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Aplicado ${Fmt.cordobas(aplicado)} a $mesLabel.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                mensajeErrorHumano(e, contexto: 'aplicar el saldo a favor'))));
      }
    } finally {
      if (mounted) setState(() => _aplicando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(appSettingsProvider).creditoExcedenteHabilitado) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      initialData: const [],
      builder: (context, snap) {
        final raw =
            (snap.data?.isNotEmpty ?? false) ? snap.data!.first['d'] : null;
        final disp = (raw as num?)?.toDouble() ?? 0.0;
        if (disp <= 0.005) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.savings_outlined, color: Colors.green.shade800),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Saldo a favor',
                          style: TextStyle(
                              fontSize: 12, color: Colors.green.shade900)),
                      Text(Fmt.cordobas(disp),
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade900)),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: _aplicando ? null : () => _aplicar(disp),
                  child: _aplicando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Aplicar'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Sección de etiquetas del cliente (P5). Muestra los chips asignados; si el
/// usuario puede gestionar (admin/admin_cobranza), un botón abre el sheet de
/// asignación. El cobrador solo las ve.
class _EtiquetasSection extends ConsumerStatefulWidget {
  const _EtiquetasSection({
    required this.clienteId,
    required this.tenantId,
    required this.puedeGestionar,
  });
  final String clienteId;
  final String tenantId;
  final bool puedeGestionar;
  @override
  ConsumerState<_EtiquetasSection> createState() => _EtiquetasSectionState();
}

class _EtiquetasSectionState extends ConsumerState<_EtiquetasSection> {
  late final Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      'SELECT e.id, e.nombre, e.color, e.icono '
      'FROM cliente_etiquetas ce JOIN etiquetas e ON e.id = ce.etiqueta_id '
      'WHERE ce.cliente_id = ? ORDER BY e.orden, e.nombre',
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      initialData: const [],
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        // Cobrador sin etiquetas → no ocupamos espacio.
        if (rows.isEmpty && !widget.puedeGestionar) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Etiquetas',
                      style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  if (widget.puedeGestionar)
                    TextButton.icon(
                      icon: const Icon(Icons.edit, size: 18),
                      label: Text(rows.isEmpty ? 'Asignar' : 'Editar'),
                      onPressed: () => _abrirAsignar(context),
                    ),
                ],
              ),
              if (rows.isEmpty)
                Text('Sin etiquetas',
                    style: TextStyle(color: scheme.outline, fontSize: 13))
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in rows)
                      EtiquetaChip(
                        nombre: r['nombre'] as String? ?? '',
                        colorHex: r['color'] as String? ?? '',
                        iconoKey: r['icono'] as String? ?? '',
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  void _abrirAsignar(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AsignarEtiquetasSheet(
        clienteId: widget.clienteId,
        tenantId: widget.tenantId,
      ),
    );
  }
}

/// Sheet de asignación: lista el catálogo activo con un check por etiqueta.
/// Tildar asigna; destildar quita (reactivo vía PowerSync).
class _AsignarEtiquetasSheet extends ConsumerStatefulWidget {
  const _AsignarEtiquetasSheet(
      {required this.clienteId, required this.tenantId});
  final String clienteId;
  final String tenantId;
  @override
  ConsumerState<_AsignarEtiquetasSheet> createState() =>
      _AsignarEtiquetasSheetState();
}

class _AsignarEtiquetasSheetState
    extends ConsumerState<_AsignarEtiquetasSheet> {
  late final Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      'SELECT e.id, e.nombre, e.color, e.icono, '
      '(SELECT COUNT(*) FROM cliente_etiquetas ce '
      '  WHERE ce.etiqueta_id = e.id AND ce.cliente_id = ?) AS asignada '
      'FROM etiquetas e WHERE e.activo = 1 ORDER BY e.orden, e.nombre',
      parameters: [widget.clienteId],
    );
  }

  Future<void> _toggle(Map<String, dynamic> e, bool asignar) async {
    final repo = ref.read(etiquetasRepoProvider);
    final me = ref.read(cobradorActualProvider).valueOrNull;
    try {
      if (asignar) {
        await repo.asignar(
          tenantId: widget.tenantId,
          clienteId: widget.clienteId,
          etiquetaId: e['id'] as String,
          usuarioId: me?.id ?? '',
        );
      } else {
        await repo.quitar(
          clienteId: widget.clienteId,
          etiquetaId: e['id'] as String,
          usuarioId: me?.id ?? '',
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(err))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, sc) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        initialData: const [],
        builder: (context, snap) {
          final rows = snap.data ?? const [];
          return ListView(
            controller: sc,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text('Etiquetas del cliente',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No hay etiquetas en el catálogo. Creálas en '
                    'Administración → Etiquetas.',
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (final e in rows)
                  CheckboxListTile(
                    value: ((e['asignada'] as int?) ?? 0) > 0,
                    onChanged: (v) => _toggle(e, v ?? false),
                    title: Align(
                      alignment: Alignment.centerLeft,
                      child: EtiquetaChip(
                        nombre: e['nombre'] as String? ?? '',
                        colorHex: e['color'] as String? ?? '',
                        iconoKey: e['icono'] as String? ?? '',
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// Resuelve los labels de ubicación del cliente para mostrarlos read-only en el
/// detalle: comunidad (Depto → Muni → Comunidad) y red (Nodo → Hub → Puerto).
/// Una sola query a SQLite local; cada parte es null si no está asignada.
final clienteUbicacionLabelsProvider = FutureProvider.autoDispose
    .family<({String? comunidad, String? red}), String>((ref, clienteId) async {
  final rows = await ps.db.getAll(
    '''
    SELECT co.nombre AS comunidad, m.nombre AS muni, d.nombre AS depto,
           n.nombre AS nodo, h.nombre AS hub, p.nombre AS puerto
      FROM clientes c
 LEFT JOIN comunidades co  ON co.id = c.comunidad_id
 LEFT JOIN municipios m    ON m.id = co.municipio_id
 LEFT JOIN departamentos d ON d.id = m.departamento_id
 LEFT JOIN red_puertos p   ON p.id = c.puerto_id
 LEFT JOIN red_hubs h      ON h.id = p.hub_id
 LEFT JOIN red_nodos n     ON n.id = h.nodo_id
     WHERE c.id = ?
    ''',
    [clienteId],
  );
  if (rows.isEmpty) return (comunidad: null, red: null);
  final r = rows.first;
  String? cadena(List<String?> partes) {
    final ps = partes.whereType<String>().where((s) => s.isNotEmpty).toList();
    return ps.isEmpty ? null : ps.join(' → ');
  }
  return (
    comunidad: cadena(
        [r['depto'] as String?, r['muni'] as String?, r['comunidad'] as String?]),
    red: cadena(
        [r['nodo'] as String?, r['hub'] as String?, r['puerto'] as String?]),
  );
});

class _ClienteInfo extends ConsumerWidget {
  const _ClienteInfo({required this.cliente, required this.puedeGestionar});
  final dynamic cliente;
  // admin/admin_cobranza: pueden reasignar el cobrador inline desde el detalle.
  final bool puedeGestionar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobradorNombre =
        ref.watch(clienteCobradorNombreProvider(cliente.id as String)).valueOrNull;
    final ubic =
        ref.watch(clienteUbicacionLabelsProvider(cliente.id as String)).valueOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(context, Icons.badge, 'Cédula', cliente.cedula),
              _row(context, Icons.phone, 'Teléfono', cliente.telefono),
              _row(context, Icons.email, 'Email', cliente.email),
              _row(context, Icons.home, 'Dirección', cliente.direccion),
              _row(context, Icons.location_on, 'Referencia',
                  cliente.direccionReferencia),
              _row(context, Icons.location_city, 'Comunidad', ubic?.comunidad),
              _row(context, Icons.hub, 'Red', ubic?.red),
              if (cliente.tieneUbicacion)
                _row(context, Icons.gps_fixed, 'GPS',
                    '${cliente.latitud!.toStringAsFixed(5)}, ${cliente.longitud!.toStringAsFixed(5)}'),
              _cobradorRow(
                context,
                ref,
                nombre: cobradorNombre,
                cobradorIdActual: cliente.cobradorId as String?,
              ),
              _NotaClienteCard(
                clienteId: cliente.id as String,
                tenantId: cliente.tenantId as String,
                nota: cliente.notas as String?,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          SizedBox(width: 90, child: Text(label, style: TextStyle(color: scheme.outline))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  /// Fila "Cobrador: [nombre o 'Sin asignar']". Siempre visible (a diferencia
  /// de `_row`, que se oculta si el valor es vacío). Si `puedeGestionar`, suma
  /// un ícono de editar que abre el selector de cobradores del tenant.
  Widget _cobradorRow(
    BuildContext context,
    WidgetRef ref, {
    required String? nombre,
    required String? cobradorIdActual,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.person_pin_circle,
              size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          SizedBox(
              width: 90,
              child: Text('Cobrador',
                  style: TextStyle(color: scheme.onTertiaryContainer))),
          Expanded(
            child: Text(
              (nombre != null && nombre.isNotEmpty) ? nombre : 'Sin asignar',
              style: (nombre != null && nombre.isNotEmpty)
                  ? null
                  : TextStyle(
                      color: scheme.outline, fontStyle: FontStyle.italic),
            ),
          ),
          if (puedeGestionar)
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Cambiar cobrador',
              visualDensity: VisualDensity.compact,
              onPressed: () => _editarCobrador(
                context,
                ref,
                cobradorIdActual: cobradorIdActual,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _editarCobrador(
    BuildContext context,
    WidgetRef ref, {
    required String? cobradorIdActual,
  }) async {
    // El sentinel ('' = "sin cambio") distingue "cancelar" de "elegí — Sin
    // asignar —" (null). Solo persistimos si el valor cambió de verdad.
    final resultado = await showModalBottomSheet<({String? cobradorId})>(
      context: context,
      showDragHandle: true,
      builder: (_) =>
          _SelectorCobradorSheet(cobradorIdActual: cobradorIdActual),
    );
    if (resultado == null || !context.mounted) return;
    if (resultado.cobradorId == cobradorIdActual) return; // sin cambios

    try {
      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      // Write local-first + op_log DENTRO de la tx (1 fila para la entidad
      // 'clientes', diff antes→después), igual que cliente_form._guardar — sin
      // esto la reasignación por este atajo NO quedaba en el historial
      // (audit 2026-07-04; audit_log se eliminó en 0140, op_log es el único log).
      final ahora = DateTime.now().toIso8601String();
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final tenantId = ref.read(tenantIdProvider);
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      await ps.dbW.writeTransaction((tx) async {
        final antes = (await tx.getAll(
                'SELECT * FROM clientes WHERE id = ?', [cliente.id]))
            .first;
        await tx.execute(
          'UPDATE clientes SET cobrador_id = ?, updated_at = ?, ocurrido_en = ? '
          'WHERE id = ?',
          [resultado.cobradorId, ahora, ocurridoEn, cliente.id],
        );
        final despues = (await tx.getAll(
                'SELECT * FROM clientes WHERE id = ?', [cliente.id]))
            .first;
        if (tenantId != null) {
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'clientes',
              entidadId: cliente.id, antes: antes, despues: despues,
              actor: actor, ocurridoEn: DateTime.parse(ocurridoEn));
        }
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(resultado.cobradorId == null
                ? 'Cobrador desasignado'
                : 'Cobrador asignado'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al asignar cobrador: $e')),
        );
      }
    }
  }
}

/// Nota interna sobre la PERSONA (`clientes.notas`), con su editor al lado.
///
/// La ven y la editan todos los roles que llegan a la ficha menos `lectura`
/// (decisión de Rubén 2026-08-10). El editor vive ACÁ y no solo en el formulario
/// de cliente por una razón concreta: el formulario es una pantalla de admin y
/// el **cobrador no tiene ningún camino hacia él** (no le aparece el lápiz de
/// editar). O sea que el único que lee la nota en la puerta de la casa —"atiende
/// la hija después de las 3", "el perro está suelto"— era justo el que no podía
/// corregirla cuando dejaba de ser cierta.
///
/// La barrera real es de la base: 0230 abrió el UPDATE de `clientes` a cualquier
/// miembro del tenant y puso un trigger que revierte TODA columna que no sea
/// `notas`. Sin ese trigger, abrir la fila para la nota habría abierto también
/// el nombre, la cédula y el cobrador asignado.
class _NotaClienteCard extends ConsumerStatefulWidget {
  const _NotaClienteCard({
    required this.clienteId,
    required this.tenantId,
    required this.nota,
  });

  final String clienteId;
  final String tenantId;
  final String? nota;

  @override
  ConsumerState<_NotaClienteCard> createState() => _NotaClienteCardState();
}

class _NotaClienteCardState extends ConsumerState<_NotaClienteCard> {
  bool _guardando = false;

  Future<void> _editar() async {
    if (_guardando) return;
    final ctrl = TextEditingController(text: widget.nota ?? '');
    // Diálogo de CONFIRMACIÓN (lo cierra el usuario) — uso válido de showDialog.
    // El guardado corre DESPUÉS, con un flag de estado, para no dejar una
    // barrera colgada si falla (regla #7 del checklist).
    final texto = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Nota del cliente'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Ej. Atiende la hija después de las 3. El perro está suelto.',
            helperText: 'Uso interno: no sale en el recibo ni en ningún PDF.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            // El context del builder, NO el del State: con GoRouter el del
            // State puede apuntar a otro navigator (regla #8).
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (texto == null) return; // canceló
    final nuevo = texto.isEmpty ? null : texto;
    if (nuevo == (widget.nota?.trim().isEmpty ?? true ? null : widget.nota)) {
      return; // sin cambios: no ensuciamos el historial
    }
    if (!mounted) return;

    setState(() => _guardando = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final ahora = DateTime.now().toUtc();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      await ps.dbW.writeTransaction((tx) async {
        // Sin el guard, un `.first` sobre una fila que ya no está tira
        // StateError('No element') — y ese texto le llega CRUDO al usuario,
        // porque `mensajeErrorHumano` no lo reconoce como técnico. Pasa si el
        // cliente desapareció de la réplica local entre que se abrió el diálogo
        // y se guardó (se borró desde otro dispositivo, o el rol dejó de
        // sincronizarlo).
        final antesRows = await tx
            .getAll('SELECT * FROM clientes WHERE id = ?', [widget.clienteId]);
        if (antesRows.isEmpty) {
          throw StateError('El cliente ya no está disponible en este dispositivo.');
        }
        final antes = antesRows.first;
        await tx.execute(
          'UPDATE clientes SET notas = ?, ocurrido_en = ?, updated_at = ? '
          'WHERE id = ?',
          [
            nuevo,
            ahora.toIso8601String(),
            // `updated_at` a mano: es el único escritor de `clientes` que no lo
            // tocaba, y la barrera server (0230) lo repone tal como llega.
            ahora.toIso8601String(),
            widget.clienteId,
          ],
        );
        final despues = (await tx.getAll(
                'SELECT * FROM clientes WHERE id = ?', [widget.clienteId]))
            .first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: widget.tenantId,
            opId: OpLog.nuevoOpId(),
            entidad: 'clientes',
            entidadId: widget.clienteId,
            antes: antes,
            despues: despues,
            actor: actor,
            ocurridoEn: ahora);
      });
      if (mounted) {
        messenger.showSnackBar(SnackBar(
            content: Text(nuevo == null ? 'Nota borrada' : 'Nota guardada')));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Todos menos `lectura`. NO se bloquea al impersonar, a diferencia de las
    // acciones que se atribuyen al usuario (visitas, pagos, cortes): una nota
    // no es plata ni cambia el estado de nada, y si el super_admin no pudiera
    // corregirla no habría forma de arreglar una nota mal escrita de un tenant.
    // Queda firmada como "System Admin" en el historial, igual que el resto de
    // lo que él escribe.
    final puedeEditar = !ref.watch(soloLecturaProvider);
    final t = widget.nota?.trim() ?? '';

    // Sin nota y sin poder escribirla: no ocupamos espacio con una caja vacía.
    if (t.isEmpty && !puedeEditar) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.sticky_note_2_outlined,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Nota interna',
                  style:
                      TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              const Spacer(),
              // `TextButton.icon` y no un ícono pelado: el destinatario de esto
              // es el cobrador con el celular en la mano en la puerta de una
              // casa. Un ícono de 16px con 4 de padding daba un blanco de ~24,
              // la mitad del mínimo táctil, y sin texto no se lee como "acá
              // escribís la nota".
              if (puedeEditar)
                _guardando
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton.icon(
                        onPressed: _editar,
                        icon: Icon(t.isEmpty ? Icons.add : Icons.edit, size: 16),
                        label: Text(t.isEmpty ? 'Agregar' : 'Editar'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
            ]),
            if (t.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(t, style: const TextStyle(fontSize: 13)),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Sin nota.',
                    style: TextStyle(fontSize: 13, color: scheme.outline)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet que lista los cobradores `rol='cobrador'` activos del tenant
/// para reasignar el cliente. Devuelve `(cobradorId: <id|null>)` al elegir, o
/// null si se cierra sin elegir. Reutiliza la misma query del `_SelectorCobrador`
/// del form de cliente.
class _SelectorCobradorSheet extends StatefulWidget {
  const _SelectorCobradorSheet({required this.cobradorIdActual});
  final String? cobradorIdActual;

  @override
  State<_SelectorCobradorSheet> createState() => _SelectorCobradorSheetState();
}

class _SelectorCobradorSheetState extends State<_SelectorCobradorSheet> {
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    _cobradoresStream = ps.db.watch(
      '''
      SELECT id, nombre, prefijo_recibo FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _cobradoresStream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(mensajeErrorHumano(snap.error!)),
            );
          }
          final rows = snap.data!;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Asignar cobrador',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // Opción "Sin asignar".
                    ListTile(
                      leading: const Icon(Icons.person_off),
                      title: const Text('— Sin asignar —'),
                      selected: widget.cobradorIdActual == null,
                      selectedTileColor: scheme.primaryContainer,
                      onTap: () =>
                          Navigator.pop(context, (cobradorId: null)),
                    ),
                    ...rows.map((r) {
                      final id = r['id'] as String;
                      final nombre = r['nombre'] as String;
                      final prefijo = r['prefijo_recibo'] as String?;
                      return ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(prefijo != null
                            ? '$nombre ($prefijo)'
                            : nombre),
                        selected: widget.cobradorIdActual == id,
                        selectedTileColor: scheme.primaryContainer,
                        onTap: () =>
                            Navigator.pop(context, (cobradorId: id)),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Historial de pagos (Feature 2) — lista READ-ONLY, agrupada por contrato.
// Solo display: NO abre detalle, NO anula (eso vive en el detalle de contrato).
// Reusa el modelo `Pago` y los formatters para verse igual que el resto.
// ─────────────────────────────────────────────────────────────────────────────

class _HistorialPagosSection extends ConsumerWidget {
  const _HistorialPagosSection({required this.clienteId});
  final String clienteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final header = Row(
      children: [
        Icon(Icons.payments, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text('Historial de pagos',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: ref.watch(clientePagosProvider(clienteId)).when(
            loading: () => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            ),
            error: (e, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [header, const SizedBox(height: 8), Text(mensajeErrorHumano(e))],
            ),
            data: (rows) {
              if (rows.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text('Sin pagos registrados',
                          style: TextStyle(color: scheme.outline)),
                    ),
                  ],
                );
              }
              // Agrupar por contrato preservando el orden del SQL (contrato más
              // nuevo primero; los cargos manuales sueltos van juntos al final).
              final grupos = <String, List<Map<String, dynamic>>>{};
              for (final r in rows) {
                final key = (r['contrato_id'] as String?) ?? '__manual__';
                (grupos[key] ??= []).add(r);
              }
              // Dentro de cada contrato, ordenar por MES DE SERVICIO (período)
              // desc — igual que el historial del detalle de contrato, donde la
              // fecha de pago desordenaba (un pago tardío de un mes viejo subía).
              // Desempate por fecha de pago desc.
              for (final list in grupos.values) {
                list.sort((a, b) {
                  final cmp = ((b['periodo'] as String?) ?? '')
                      .compareTo((a['periodo'] as String?) ?? '');
                  if (cmp != 0) return cmp;
                  return ((b['fecha_pago'] as String?) ?? '')
                      .compareTo((a['fecha_pago'] as String?) ?? '');
                });
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  for (final entry in grupos.entries) ...[
                    const SizedBox(height: 12),
                    _grupoHeader(context, entry.key, entry.value),
                    const SizedBox(height: 6),
                    Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < entry.value.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _PagoFilaReadOnly(row: entry.value[i]),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
    );
  }

  Widget _grupoHeader(
      BuildContext context, String key, List<Map<String, dynamic>> pagos) {
    final scheme = Theme.of(context).colorScheme;
    final first = pagos.first;
    final esManual = key == '__manual__';
    final titulo = esManual
        ? 'Cargos manuales'
        : (first['plan_nombre'] as String? ?? 'Contrato');
    final codigo = first['contrato_codigo'] as String?;
    final n = pagos.length;
    return Row(
      children: [
        Icon(esManual ? Icons.receipt_long : Icons.wifi,
            size: 15, color: scheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            (codigo != null && codigo.isNotEmpty) ? '$titulo · $codigo' : titulo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          ),
        ),
        Text('$n ${n == 1 ? "pago" : "pagos"}',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
      ],
    );
  }
}

// Una fila de pago, SOLO display (sin tap/acciones).
class _PagoFilaReadOnly extends StatelessWidget {
  const _PagoFilaReadOnly({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pago = Pago.fromRow(row);
    final periodo = row['periodo'] != null
        ? DateTime.parse(row['periodo'] as String)
        : null;
    final mes = periodo != null
        ? Fmt.mesServicioLabel(
            periodo,
            row['tipo_cargo_manual'] != null
                ? null
                : (row['dia_pago'] as num?)?.toInt())
        : '—';
    final montoLabel = pago.moneda == Moneda.nio
        ? Fmt.cordobas(pago.montoCordobas)
        : '${Fmt.dolares(pago.montoOriginal)} (${Fmt.cordobas(pago.montoCordobas)})';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(pago.anulado ? Icons.block : Icons.check_circle,
              size: 18, color: pago.anulado ? scheme.error : Colors.green),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mes,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      decoration:
                          pago.anulado ? TextDecoration.lineThrough : null,
                    )),
                Text('${Fmt.fechaCorta(pago.fechaPago)} · ${pago.metodo.label}',
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
              ],
            ),
          ),
          Text(montoLabel,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: pago.anulado ? scheme.error : null,
                decoration: pago.anulado ? TextDecoration.lineThrough : null,
              )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sección de contratos del cliente
// ─────────────────────────────────────────────────────────────────────────────

class _ContratosSection extends StatefulWidget {
  const _ContratosSection({
    required this.clienteId,
    required this.esAdmin,
    required this.enAdminShell,
  });
  final String clienteId;
  final bool esAdmin;
  final bool enAdminShell;

  @override
  State<_ContratosSection> createState() => _ContratosSectionState();
}

class _ContratosSectionState extends State<_ContratosSection> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      '''
      SELECT ct.*, p.nombre AS plan_nombre, p.precio_mensual,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado <> 'anulada') AS total_cuotas,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado IN ('pendiente','parcial')) AS cuotas_pendientes,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado = 'pagada') AS cuotas_pagadas,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado IN ('pendiente','parcial')
              AND fecha_vencimiento < date('now', '-6 hours')) AS cuotas_vencidas
        FROM contratos ct
   LEFT JOIN planes p ON p.id = ct.plan_id
       WHERE ct.cliente_id = ?
       ORDER BY ct.estado ASC, ct.created_at DESC
      ''',
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mensajeErrorHumano(snap.error!)),
            ));
          }
          final rows = snap.data!;
          final activos = rows
              .where((r) => (r['estado'] as String? ?? 'activo') == 'activo')
              .toList();
          // Un contrato SUSPENDIDO es temporal/reactivable y tiene deuda viva:
          // se muestra prominente (como activo) con su badge "Suspendido", NO
          // tachado bajo "cancelados". Solo los terminales (cancelado, más el
          // viejo 'completado' que se eliminó) van al grupo colapsado.
          final suspendidos = rows
              .where((r) => (r['estado'] as String? ?? 'activo') == 'suspendido')
              .toList();
          final cancelados = rows.where((r) {
            final e = r['estado'] as String? ?? 'activo';
            return e != 'activo' && e != 'suspendido';
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Text('Contratos',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Text(
                      '(${activos.length} activo${activos.length != 1 ? 's' : ''}'
                      '${suspendidos.isNotEmpty ? ' · ${suspendidos.length} suspendido${suspendidos.length != 1 ? 's' : ''}' : ''})',
                      style: TextStyle(color: scheme.outline, fontSize: 13)),
                  const Spacer(),
                  if (widget.esAdmin)
                    // P3b (2026-06-17): se permite crear contrato aunque el
                    // cliente no tenga cobrador (queda admin-managed; el form de
                    // contrato y el server ya lo manejan). Antes el botón se
                    // deshabilitaba sin cobrador.
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Nuevo'),
                      onPressed: () {
                        final path = widget.enAdminShell
                            ? '/admin/contratos/nuevo?cliente_id=${widget.clienteId}'
                            : '/contratos/nuevo?cliente_id=${widget.clienteId}';
                        context.push(path);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Contratos activos
              if (activos.isEmpty && suspendidos.isEmpty && cancelados.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('Sin contratos',
                          style: TextStyle(color: scheme.outline)),
                    ),
                  ),
                ),

              // Preview = la MISMA tarjeta del detalle de contrato (sin cuotas).
              // Tocar → entra al contrato completo. Badge de estado read-only
              // en el preview (onEstadoChanged: null); se cambia en el detalle.
              ...activos.map((ct) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ContratoPreviewCard(
                      contratoId: ct['id'] as String,
                      esAdmin: widget.esAdmin,
                      enAdminShell: widget.enAdminShell,
                      pagadas: (ct['cuotas_pagadas'] as int?) ?? 0,
                      total: (ct['total_cuotas'] as int?) ?? 0,
                    ),
                  )),

              // Suspendidos: prominentes (deuda viva, reactivables). El preview
              // muestra el badge "Suspendido" naranja del ContratoHeaderCard.
              ...suspendidos.map((ct) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ContratoPreviewCard(
                      contratoId: ct['id'] as String,
                      esAdmin: widget.esAdmin,
                      enAdminShell: widget.enAdminShell,
                      pagadas: (ct['cuotas_pagadas'] as int?) ?? 0,
                      total: (ct['total_cuotas'] as int?) ?? 0,
                    ),
                  )),

              // Contratos cancelados (colapsable)
              if (cancelados.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  title: Text('Contratos cancelados (${cancelados.length})',
                      style: TextStyle(color: scheme.outline, fontSize: 14)),
                  initiallyExpanded: false,
                  children: cancelados
                      .map((ct) => _ContratoCard(
                            contrato: ct,
                            esAdmin: widget.esAdmin,
                            cancelado: true,
                            onTap: () {
                              final id = ct['id'] as String;
                              final prefix = widget.enAdminShell ? '/admin' : '';
                              context.push('$prefix/contratos/$id');
                            },
                          ))
                      .toList(),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Botón-pestaña del detalle del cliente (Detalle / Contratos / Equipos /
/// Visitas). Seleccionado = relleno primaryContainer + borde primary.
class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vista previa de un contrato en el detalle del cliente: reutiliza la tarjeta
/// del detalle de contrato (`ContratoHeaderCard`, sin la lista de cuotas). Toca
/// → abre el contrato completo. Lee el MISMO `contratoDetalleProvider` que el
/// detalle → números de plata idénticos. Badge de estado read-only en el
/// preview (`onEstadoChanged: null`); el cambio de estado se hace en el detalle.
class _ContratoPreviewCard extends ConsumerWidget {
  const _ContratoPreviewCard({
    required this.contratoId,
    required this.esAdmin,
    required this.enAdminShell,
    required this.pagadas,
    required this.total,
  });
  final String contratoId;
  final bool esAdmin;
  final bool enAdminShell;
  final int pagadas;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ref.watch(contratoDetalleProvider(contratoId)).maybeWhen(
          data: (rows) {
            if (rows.isEmpty) return const SizedBox.shrink();
            return GestureDetector(
              onTap: () {
                final prefix = enAdminShell ? '/admin' : '';
                context.push('$prefix/contratos/$contratoId');
              },
              child: ContratoHeaderCard(
                contrato: rows.first,
                esAdmin: esAdmin,
                esAdminCobranza: ref.watch(cobradorActualProvider).valueOrNull?.esAdminCobranza ?? false,
                contratoId: contratoId,
                enImpersonacion: false,
                onEstadoChanged: null,
                // "Pagadas X/Y" + barra de progreso (cuotas no anuladas).
                footer: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'Pagadas $pagadas/$total',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: total > 0 ? pagadas / total : 0,
                          minHeight: 6,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        );
  }
}

class _ContratoCard extends StatelessWidget {
  const _ContratoCard({
    required this.contrato,
    required this.esAdmin,
    this.cancelado = false,
    required this.onTap,
  });
  final Map<String, dynamic> contrato;
  final bool esAdmin;
  final bool cancelado;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = contrato['plan_nombre'] as String? ?? 'Sin plan';
    final codigo = contrato['codigo'] as String?;
    final precio = (contrato['precio_mensual'] as num?)?.toDouble() ?? 0;
    final totalCuotas = (contrato['total_cuotas'] as num?)?.toInt() ?? 0;
    final pagadas = (contrato['cuotas_pagadas'] as num?)?.toInt() ?? 0;
    final vencidas = (contrato['cuotas_vencidas'] as num?)?.toInt() ?? 0;
    final pendientes = (contrato['cuotas_pendientes'] as num?)?.toInt() ?? 0;

    return Card(
      color: cancelado ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : null,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (codigo != null && codigo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(codigo,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                          letterSpacing: 0.5)),
                ),
              Row(
                children: [
                  Icon(Icons.description,
                      color: cancelado ? scheme.outline : scheme.primary,
                      size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(plan,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: cancelado ? TextDecoration.lineThrough : null,
                        )),
                  ),
                  Text('${Fmt.cordobas(precio)}/mes',
                      style: TextStyle(
                        color: scheme.outline,
                        fontSize: 12,
                      )),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text('$pagadas/$totalCuotas pagadas',
                      style: TextStyle(color: scheme.outline, fontSize: 12)),
                  if (vencidas > 0)
                    Text('$vencidas vencida${vencidas != 1 ? 's' : ''}',
                        style: TextStyle(
                          color: scheme.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        )),
                  if (vencidas == 0 && pendientes > 0)
                    Text('Al día',
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 12,
                        )),
                  if (pendientes == 0 && totalCuotas > 0)
                    Text('Completado ✓',
                        style: TextStyle(
                          color: scheme.tertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sección de equipos de inventario instalados en el cliente (2D)
// ─────────────────────────────────────────────────────────────────────────────

class _EquiposInstaladosSection extends StatefulWidget {
  const _EquiposInstaladosSection(
      {required this.clienteId, this.navegable = false});
  final String clienteId;
  // Solo admin ∪ super_admin (los que el router deja entrar a
  // `/admin/inventario/*`) saltan a la ficha del equipo. El cobrador y el
  // admin_cobranza ven la lista pero SIN salto (el cobrador porque su ruta
  // `/clientes/:id` no está en el shell; el admin_cobranza porque el guard
  // `soloAdmin` del router le prohíbe /admin/inventario). Lo decide el caller.
  final bool navegable;

  @override
  State<_EquiposInstaladosSection> createState() =>
      _EquiposInstaladosSectionState();
}

class _EquiposInstaladosSectionState extends State<_EquiposInstaladosSection> {
  late final Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      '''
      SELECT s.id, s.serial, s.mac, p.nombre AS producto
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
       WHERE s.cliente_id = ? AND s.estado = 'instalado'
       ORDER BY p.nombre, s.serial
      ''',
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _stream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(mensajeErrorHumano(snap.error!)),
              );
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.router, size: 18, color: scheme.outline),
                    const SizedBox(width: 8),
                    Text('Sin equipos instalados',
                        style: TextStyle(color: scheme.outline)),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Icon(Icons.router, size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text('Equipos instalados',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Text('(${rows.length})',
                          style:
                              TextStyle(color: scheme.outline, fontSize: 13)),
                    ],
                  ),
                ),
                ...rows.map((r) {
                  final mac = r['mac'] as String?;
                  return ListTile(
                    dense: true,
                    leading:
                        Icon(Icons.qr_code_2, color: scheme.outline, size: 22),
                    title: Text(r['serial'] as String),
                    subtitle: Text([
                      r['producto'] as String? ?? '',
                      if (mac != null && mac.isNotEmpty) 'MAC $mac',
                    ].join(' · ')),
                    trailing: widget.navegable
                        ? Icon(Icons.chevron_right, color: scheme.outline)
                        : null,
                    // Regla #12: rutas del shell admin se navegan con go, no push.
                    onTap: widget.navegable
                        ? () => context
                            .go('/admin/inventario/equipo/${r['id'] as String}')
                        : null,
                  );
                }),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Sprint D1: Registrar visita dialog + historial de visitas ──────────

class _RegistrarVisitaDialog extends StatefulWidget {
  const _RegistrarVisitaDialog();

  @override
  State<_RegistrarVisitaDialog> createState() => _RegistrarVisitaDialogState();
}

class _RegistrarVisitaDialogState extends State<_RegistrarVisitaDialog> {
  VisitaResultado _resultado = VisitaResultado.noEstaba;
  final _notasCtrl = TextEditingController();

  @override
  void dispose() {
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar visita'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<VisitaResultado>(
            initialValue: _resultado,
            decoration: const InputDecoration(
              labelText: 'Resultado',
              border: OutlineInputBorder(),
            ),
            items: VisitaResultado.values
                .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _resultado = v);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notasCtrl,
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
              hintText: 'Ej: promete pagar el viernes',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (
              resultado: _resultado,
              notas: _notasCtrl.text.trim().isEmpty
                  ? null
                  : _notasCtrl.text.trim(),
            ),
          ),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _VisitasSection extends ConsumerStatefulWidget {
  const _VisitasSection({super.key, required this.clienteId});
  final String clienteId;

  @override
  ConsumerState<_VisitasSection> createState() => _VisitasSectionState();
}

class _VisitasSectionState extends ConsumerState<_VisitasSection> {
  late Stream<List<Visita>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ref.read(visitasServiceProvider).watch(widget.clienteId);
  }

  @override
  void didUpdateWidget(covariant _VisitasSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() {
        _stream = ref.read(visitasServiceProvider).watch(widget.clienteId);
      });
    }
  }

  /// API compat con el código viejo — el stream ya emite cambios automáticamente,
  /// pero algunos callers llaman recargar() después de registrar visita.
  void recargar() {}

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder<List<Visita>>(
          stream: _stream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(mensajeErrorHumano(snap.error!)),
              );
            }
            final visitas = snap.data!;
            if (visitas.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.history,
                        size: 18,
                        color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 8),
                    Text('Sin visitas registradas',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline)),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Icon(Icons.history,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('Historial de visitas',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Text('(${visitas.length})',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 13)),
                    ],
                  ),
                ),
                ...visitas.take(10).map((v) => _VisitaTile(visita: v)),
                if (visitas.length > 10)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${visitas.length - 10} visita(s) más antiguas',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _VisitaTile extends StatelessWidget {
  const _VisitaTile({required this.visita});
  final Visita visita;

  IconData get _icon => switch (visita.resultado) {
        VisitaResultado.cobrado => Icons.check_circle,
        VisitaResultado.noEstaba => Icons.person_off,
        VisitaResultado.sinPago => Icons.money_off,
        VisitaResultado.promesaPago => Icons.handshake,
        VisitaResultado.otro => Icons.notes,
      };

  Color _color(ColorScheme scheme) => switch (visita.resultado) {
        VisitaResultado.cobrado => scheme.tertiary,
        VisitaResultado.noEstaba => scheme.outline,
        VisitaResultado.sinPago => scheme.error,
        // scheme.secondary es el primary al 10% (relleno) → ilegible como texto.
        // Ámbar de la paleta (4.5:1), semánticamente "pendiente/promesa".
        VisitaResultado.promesaPago => AppColors.warning,
        VisitaResultado.otro => scheme.outline,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(scheme);
    final hasNotas = visita.notas != null && visita.notas!.isNotEmpty;
    final cobrador = visita.cobradorNombre ?? '—';
    return ListTile(
      dense: true,
      leading: Icon(_icon, color: color, size: 22),
      title: Row(
        children: [
          Text(visita.resultado.label,
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
          const SizedBox(width: 8),
          Flexible(
            child: Text('· $cobrador',
                style: TextStyle(color: scheme.outline, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${Fmt.fechaCorta(visita.fecha.toLocal())} · ${Fmt.fechaRelativa(visita.fecha.toLocal())}',
            style: TextStyle(color: scheme.outline, fontSize: 11),
          ),
          if (hasNotas) ...[
            const SizedBox(height: 4),
            Text(visita.notas!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

// ── Fin Sprint D1 ──────────────────────────────────────────────────────
