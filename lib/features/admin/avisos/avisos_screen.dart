import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/services/external_actions.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../cuotas/cobros_query.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Avisos (Feature 3+4): lista de clientes EN GRACIA (próximos a corte) y EN
// MORA. Reusa `cobrosResumenQuery` (el MISMO SQL canónico que la pantalla
// Cobros) con los filtros `gracia`/`mora`. Botón "WhatsApp" por cliente (Feature
// 4, deep link wa.me con mensaje prellenado desde plantilla editable) + flujo
// guiado "Notificar a todos". Gateada por `cobranza.avisos_habilitado`; el botón
// WhatsApp por `cobranza.notif_whatsapp_habilitado` (ambos super_admin). Visible
// solo para admin/admin_cobranza (ver router + admin_shell).
// ─────────────────────────────────────────────────────────────────────────────

/// Clientes EN GRACIA (vencidos pero dentro del período de gracia = próximos a
/// corte). Recrea el stream al cambiar la DB (dbEpoch) o los días de settings.
final avisosGraciaProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watch(dbEpochProvider);
  final diasGracia = ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  final diasVisibles =
      ref.watch(appSettingsProvider.select((s) => s.diasCuotasVisibles));
  final (sql, params) = cobrosResumenQuery(
      filtro: CobrosFiltro.gracia,
      diasGracia: diasGracia,
      diasVisibles: diasVisibles);
  return ps.db.watch(sql, parameters: params);
});

/// Clientes EN MORA (vencidos pasada la gracia).
final avisosMoraProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watch(dbEpochProvider);
  final diasGracia = ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  final diasVisibles =
      ref.watch(appSettingsProvider.select((s) => s.diasCuotasVisibles));
  final (sql, params) = cobrosResumenQuery(
      filtro: CobrosFiltro.mora,
      diasGracia: diasGracia,
      diasVisibles: diasVisibles);
  return ps.db.watch(sql, parameters: params);
});

enum _TipoAviso { gracia, mora }

const _kGracia = Color(0xFF854F0B); // ámbar oscuro
const _kMora = Color(0xFFA32D2D); // rojo
const _kWhatsapp = Color(0xFF128C3F); // verde WhatsApp

/// Días hasta el corte (gracia) / de atraso (mora) de una fila.
int _diasDe(Map<String, dynamic> row, _TipoAviso tipo, int diasGracia) {
  final peor = DateTime.parse(row['peor_vence'] as String);
  final diasFromVence = Fmt.hoyNicaragua()
      .difference(DateTime(peor.year, peor.month, peor.day))
      .inDays;
  return tipo == _TipoAviso.gracia
      ? (diasGracia - diasFromVence).clamp(0, 99999)
      : (diasFromVence - diasGracia);
}

bool _tieneTelefono(Map<String, dynamic> row) =>
    ((row['cliente_telefono'] as String?)?.trim().isNotEmpty) ?? false;

/// Arma el mensaje reemplazando los placeholders de la plantilla.
String _mensajeAviso({
  required String template,
  required Map<String, dynamic> row,
  required _TipoAviso tipo,
  required int diasGracia,
  required String empresa,
}) {
  final nombre = (row['cliente_nombre'] as String?) ?? '';
  final total = (row['total_cobrable'] as num?)?.toDouble() ?? 0;
  final dias = _diasDe(row, tipo, diasGracia);
  return template
      .replaceAll('{nombre}', nombre)
      .replaceAll('{monto}', Fmt.cordobas(total))
      .replaceAll('{dias}', '$dias')
      .replaceAll('{empresa}', empresa);
}

class AvisosScreen extends ConsumerWidget {
  const AvisosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    final notifOn = settings.notifWhatsappHabilitado;
    final empresa = settings.empresaNombre;
    // "Generar orden de corte" desde mora: solo si el módulo tickets está ON
    // Y el usuario puede entrar a /admin/tickets/nuevo (soloAdmin en el router).
    // Sin el gate de rol, admin_cobranza veía el botón y el router lo rebotaba a
    // /admin en silencio (callejón sin salida — audit sweep 2026-07-01).
    final esAdminFull =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final ticketsOn = esAdminFull &&
        (ref.watch(modulosHabilitadosProvider).valueOrNull?.contains('tickets') ??
            false);
    final gracia = ref.watch(avisosGraciaProvider);
    final mora = ref.watch(avisosMoraProvider);

    final graciaRows = gracia.valueOrNull ?? const [];
    final moraRows = mora.valueOrNull ?? const [];
    final graciaTotal = graciaRows.fold<double>(
        0, (a, r) => a + ((r['total_cobrable'] as num?)?.toDouble() ?? 0));
    final moraTotal = moraRows.fold<double>(
        0, (a, r) => a + ((r['total_cobrable'] as num?)?.toDouble() ?? 0));

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
      children: [
        Row(
          children: [
            Expanded(
              child: _ResumenCard(
                titulo: 'Próximos a corte',
                n: graciaRows.length,
                total: graciaTotal,
                color: _kGracia,
                cargando: gracia.isLoading,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ResumenCard(
                titulo: 'En mora',
                n: moraRows.length,
                total: moraTotal,
                color: _kMora,
                cargando: mora.isLoading,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _Seccion(
          titulo: 'Próximos a corte — en gracia',
          color: _kGracia,
          estado: gracia,
          tipo: _TipoAviso.gracia,
          diasGracia: diasGracia,
          notifOn: notifOn,
          template: settings.avisoMsgGracia,
          empresa: empresa,
          ticketsOn: ticketsOn,
        ),
        const SizedBox(height: 20),
        _Seccion(
          titulo: 'En mora — corte',
          color: _kMora,
          estado: mora,
          tipo: _TipoAviso.mora,
          diasGracia: diasGracia,
          notifOn: notifOn,
          template: settings.avisoMsgMora,
          empresa: empresa,
          ticketsOn: ticketsOn,
        ),
      ],
    );
  }
}

class _ResumenCard extends StatelessWidget {
  const _ResumenCard({
    required this.titulo,
    required this.n,
    required this.total,
    required this.color,
    required this.cargando,
  });
  final String titulo;
  final int n;
  final double total;
  final Color color;
  final bool cargando;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          cargando
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: '$n',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                            color: color)),
                    TextSpan(
                        text: '  ·  ${Fmt.cordobas(total)}',
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant)),
                  ]),
                ),
        ],
      ),
    );
  }
}

class _Seccion extends ConsumerWidget {
  const _Seccion({
    required this.titulo,
    required this.color,
    required this.estado,
    required this.tipo,
    required this.diasGracia,
    required this.notifOn,
    required this.template,
    required this.empresa,
    required this.ticketsOn,
  });
  final String titulo;
  final Color color;
  final AsyncValue<List<Map<String, dynamic>>> estado;
  final _TipoAviso tipo;
  final int diasGracia;
  final bool notifOn;
  final String template;
  final String empresa;
  final bool ticketsOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = estado.valueOrNull ?? const [];
    final conTelefono = rows.where(_tieneTelefono).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(titulo,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            // "Notificar a todos" (flujo guiado uno-por-uno). Solo si el feature
            // está habilitado y hay clientes con teléfono.
            if (notifOn && conTelefono.isNotEmpty)
              // El mensaje de WhatsApp SALE de verdad y no revierte: es la única
              // acción del rol `lectura` que ninguna barrera puede deshacer.
              if (!ref.watch(soloLecturaProvider))
                TextButton.icon(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => _NotificarTodosSheet(
                      clientes: conTelefono,
                      tipo: tipo,
                      template: template,
                      empresa: empresa,
                      diasGracia: diasGracia,
                    ),
                  ),
                  icon: const Icon(Icons.chat, size: 16, color: _kWhatsapp),
                  label: Text('Notificar a todos (${conTelefono.length})',
                      style: const TextStyle(fontSize: 12, color: _kWhatsapp)),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
          ],
        ),
        const SizedBox(height: 8),
        estado.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text(mensajeErrorHumano(e)),
          data: (rows) {
            if (rows.isEmpty) {
              return _VacioMini(
                  texto: tipo == _TipoAviso.gracia
                      ? 'Nadie en gracia ahora.'
                      : 'Nadie en mora ahora.');
            }
            return Column(
              children: [
                for (final r in rows)
                  _AvisoFila(
                    row: r,
                    tipo: tipo,
                    color: color,
                    diasGracia: diasGracia,
                    notifOn: notifOn,
                    template: template,
                    empresa: empresa,
                    mostrarOrdenCorte: ticketsOn && tipo == _TipoAviso.mora,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _VacioMini extends StatelessWidget {
  const _VacioMini({required this.texto});
  final String texto;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: scheme.outline),
          const SizedBox(width: 8),
          Text(texto, style: TextStyle(color: scheme.outline)),
        ],
      ),
    );
  }
}

class _AvisoFila extends ConsumerWidget {
  const _AvisoFila({
    required this.row,
    required this.tipo,
    required this.color,
    required this.diasGracia,
    required this.notifOn,
    required this.template,
    required this.empresa,
    required this.mostrarOrdenCorte,
  });
  final Map<String, dynamic> row;
  final _TipoAviso tipo;
  final Color color;
  final int diasGracia;
  final bool notifOn;
  final String template;
  final String empresa;
  final bool mostrarOrdenCorte;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final clienteId = row['cliente_id'] as String;
    final codigo = row['cliente_codigo'] as String?;
    final nombre = row['cliente_nombre'] as String;
    final telefono = row['cliente_telefono'] as String?;
    final comunidad = row['comunidad'] as String?;
    final municipio = row['municipio'] as String?;
    final total = (row['total_cobrable'] as num?)?.toDouble() ?? 0;
    final ubic = [comunidad, municipio]
        .where((s) => s != null && s.isNotEmpty)
        .join(' · ');
    final tieneTel = _tieneTelefono(row);

    final dias = _diasDe(row, tipo, diasGracia);
    final diasLabel = tipo == _TipoAviso.gracia
        ? (dias <= 0 ? 'corta hoy' : 'corta en $dias ${dias == 1 ? "día" : "días"}')
        : 'en mora hace $dias ${dias == 1 ? "día" : "días"}';

    final subtitlePartes = <String>[
      if (ubic.isNotEmpty) ubic,
      if (tieneTel) telefono!.trim() else 'sin teléfono',
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 7),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/admin/clientes/$clienteId'),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (codigo != null && codigo.isNotEmpty)
                                  ? '$codigo · $nombre'
                                  : nombre,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w500, fontSize: 13),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitlePartes.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: scheme.onSurfaceVariant),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(diasLabel,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: color)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(Fmt.cordobas(total),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                          if (notifOn && !ref.watch(soloLecturaProvider)) ...[
                            const SizedBox(height: 6),
                            tieneTel
                                ? FilledButton.icon(
                                    onPressed: () => ExternalActions.whatsapp(
                                        context, telefono!,
                                        texto: _mensajeAviso(
                                            template: template,
                                            row: row,
                                            tipo: tipo,
                                            diasGracia: diasGracia,
                                            empresa: empresa)),
                                    icon: const Icon(Icons.chat, size: 15),
                                    label: const Text('WhatsApp',
                                        style: TextStyle(fontSize: 12)),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _kWhatsapp,
                                      foregroundColor: Colors.white,
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12),
                                      minimumSize: const Size(0, 30),
                                    ),
                                  )
                                : Text('sin tel.',
                                    style: TextStyle(
                                        fontSize: 10, color: scheme.outline)),
                          ],
                          if (mostrarOrdenCorte) ...[
                            const SizedBox(height: 6),
                            OutlinedButton.icon(
                              onPressed: () => context.push(
                                  '/admin/tickets/nuevo?cliente=$clienteId'),
                              icon: const Icon(Icons.power_off_outlined,
                                  size: 14),
                              label: const Text('Orden de corte',
                                  style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                minimumSize: const Size(0, 30),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
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

// Flujo guiado "Notificar a todos": muestra un cliente a la vez; "Enviar por
// WhatsApp" abre el chat con el mensaje y avanza al siguiente; "Saltar" avanza
// sin abrir. Con deep links wa.me NO hay envío masivo automático — el usuario
// toca enviar en cada chat (límite documentado del approach Fase 1).
class _NotificarTodosSheet extends StatefulWidget {
  const _NotificarTodosSheet({
    required this.clientes,
    required this.tipo,
    required this.template,
    required this.empresa,
    required this.diasGracia,
  });
  final List<Map<String, dynamic>> clientes;
  final _TipoAviso tipo;
  final String template;
  final String empresa;
  final int diasGracia;

  @override
  State<_NotificarTodosSheet> createState() => _NotificarTodosSheetState();
}

class _NotificarTodosSheetState extends State<_NotificarTodosSheet> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = widget.clientes.length;

    if (_i >= total) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: _kWhatsapp, size: 40),
              const SizedBox(height: 12),
              Text('Recorriste los $total clientes',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cerrar'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final row = widget.clientes[_i];
    final nombre = row['cliente_nombre'] as String;
    final telefono = (row['cliente_telefono'] as String?) ?? '';
    final total2 = (row['total_cobrable'] as num?)?.toDouble() ?? 0;
    final mensaje = _mensajeAviso(
        template: widget.template,
        row: row,
        tipo: widget.tipo,
        diasGracia: widget.diasGracia,
        empresa: widget.empresa);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 4,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Cliente ${_i + 1} de $total',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
            const SizedBox(height: 6),
            Text(nombre,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text('$telefono · ${Fmt.cordobas(total2)}',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(mensaje, style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                ExternalActions.whatsapp(context, telefono, texto: mensaje);
                setState(() => _i++);
              },
              icon: const Icon(Icons.chat, size: 18),
              label: const Text('Enviar por WhatsApp y siguiente'),
              style: FilledButton.styleFrom(
                backgroundColor: _kWhatsapp,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 46),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _i++),
              child: const Text('Saltar este cliente'),
            ),
          ],
        ),
      ),
    );
  }
}
