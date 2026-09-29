import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/formatters.dart' show Fmt;
import '../admin/settings/invariantes_detalle.dart' show kInvInfo;

/// Consola de diagnóstico del Dev (`/super/diagnostico`) — SOLO super_admin,
/// solo lectura, online-only (RPCs 0243). Cuatro fichas:
///   · Radiografía — buscador global de clientes + veredicto del caso.
///   · Invariantes — los chequeos de dinero por tenant (RPC 0153 → 0248/0255;
///     hoy 31, y el conteo NO se hardcodea: sale de las filas que devuelve).
///   · Talonarios  — series de recibos, huecos vigentes e ignorados.
///   · Fantasmas   — cuotas post-cancelación, rechazos 14d, cuarentenas.
///
/// El VEREDICTO en prosa se arma acá (client-side) a partir de `senales` del
/// server: mantenerlo en Dart lo hace ajustable sin migración.
class DiagnosticoScreen extends ConsumerWidget {
  const DiagnosticoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Radiografía'),
                Tab(text: 'Invariantes'),
                Tab(text: 'Talonarios'),
                Tab(text: 'Fantasmas'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                _TabRadiografia(),
                _TabInvariantes(),
                _TabTalonarios(),
                _TabFantasmas(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── helpers comunes ─────────────────────────

String _dg(dynamic v) => v?.toString() ?? '—';

String _dgFecha(dynamic raw) {
  if (raw == null) return '—';
  final d = DateTime.tryParse(raw.toString());
  if (d == null) return raw.toString();
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(d.day)}/${dos(d.month)}/${d.year}';
}

double _dgNum(dynamic v) => v is num ? v.toDouble() : 0;

Color _dgEstadoColor(BuildContext ctx, String estado) {
  switch (estado) {
    case 'pagada':
      return const Color(0xFF1D9E75);
    case 'parcial':
      return const Color(0xFF378ADD);
    case 'anulada':
      return Theme.of(ctx).colorScheme.outline;
    case 'cancelado':
    case 'suspendido':
      return const Color(0xFFD85A30);
    default:
      return const Color(0xFFD85A30); // pendiente
  }
}

class _DgError extends StatelessWidget {
  const _DgError({required this.texto, required this.onReintentar});
  final String texto;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: scheme.error, size: 32),
            const SizedBox(height: 8),
            Text(texto, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            FilledButton.tonal(
                onPressed: onReintentar, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

class _DgSeccion extends StatelessWidget {
  const _DgSeccion({required this.titulo, required this.child});
  final String titulo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 1. Radiografía ─────────────────────────

class _TabRadiografia extends StatefulWidget {
  const _TabRadiografia();

  @override
  State<_TabRadiografia> createState() => _TabRadiografiaState();
}

class _TabRadiografiaState extends State<_TabRadiografia>
    with AutomaticKeepAliveClientMixin {
  final _qCtrl = TextEditingController();
  bool _buscando = false;
  bool _cargando = false;
  String? _error;
  List<Map<String, dynamic>>? _matches;
  Map<String, dynamic>? _data; // radiografía del cliente elegido

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  Future<void> _buscar() async {
    final q = _qCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _buscando = true;
      _error = null;
      _matches = null;
      _data = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_diag_buscar', params: {'p_q': q});
      if (!mounted) return;
      setState(() => _matches = [
            for (final e in (res as List))
              Map<String, dynamic>.from(e as Map),
          ]);
      // Un único match → abrir directo la radiografía.
      if (_matches!.length == 1) {
        await _abrir(_matches!.first['id'] as String);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is PostgrestException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }

  Future<void> _abrir(String clienteId) async {
    setState(() {
      _cargando = true;
      _error = null;
      _data = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_diag_cliente', params: {'p_cliente': clienteId});
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is PostgrestException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// El veredicto en prosa: heurísticas sobre `senales`.
  List<(IconData, Color, String)> _veredicto(Map<String, dynamic> senales) {
    final out = <(IconData, Color, String)>[];
    final cuarentenas = _dgNum(senales['cuarentenas']).toInt();
    final rechazos = _dgNum(senales['rechazos_pendientes']).toInt();
    final vencidas = _dgNum(senales['vencidas_sin_pago']).toInt();
    final anuladas30 = _dgNum(senales['anuladas_30d']).toInt();
    final deuda = _dgNum(senales['deuda_viva']);
    final ultimoPago = senales['ultimo_pago'];

    if (cuarentenas > 0) {
      out.add((Icons.warning_amber, const Color(0xFFD85A30),
          '$cuarentenas cobro(s) EN CUARENTENA: hay plata esperando la decisión '
          'del admin en la bandeja "Cobros a revisar".'));
    }
    if (rechazos > 0) {
      out.add((Icons.sync_problem, const Color(0xFFD85A30),
          '$rechazos rechazo(s) de sync sin resolver tocan registros de este '
          'cliente — revisá la bandeja.'));
    }
    if (vencidas > 0) {
      out.add((Icons.receipt_long, const Color(0xFF378ADD),
          'Debe $vencidas cuota(s) vencida(s) sin NINGÚN pago registrado'
          '${ultimoPago != null ? ' (último pago: ${_dgFecha(ultimoPago)})' : ''}. '
          'Si el cliente dice que pagó, pedí el comprobante físico y usá '
          '"Registrar pago histórico" en Operaciones.'));
    }
    if (anuladas30 > 0) {
      out.add((Icons.block, const Color(0xFF7F77DD),
          '$anuladas30 cuota(s) anulada(s) en los últimos 30 días — el motivo '
          'está en el historial de abajo. Si el ISP dice que sí se debe, '
          'usá "Revivir cuota" en Operaciones.'));
    }
    if (out.isEmpty) {
      out.add((Icons.check_circle, const Color(0xFF1D9E75),
          deuda > 0.009
              ? 'Sin señales raras: deuda viva normal de '
                  '${Fmt.cordobas(deuda)} y nada pendiente de decisión.'
              : 'Sin señales raras: el cliente está al día.'));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _qCtrl,
              decoration: InputDecoration(
                labelText: 'Buscar cliente en TODAS las empresas',
                hintText: 'código o nombre (con o sin tildes/ñ)',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: _buscando
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _buscando ? null : _buscar,
                ),
              ),
              onSubmitted: (_) {
                if (!_buscando) _buscar();
              },
            ),
            const SizedBox(height: 12),
            if (_error != null)
              _DgError(texto: _error!, onReintentar: _buscar),
            if (_matches != null && _matches!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Sin resultados. Probá con menos palabras.'),
              ),
            if (_matches != null && _matches!.length > 1 && _data == null)
              _DgSeccion(
                titulo: 'Resultados (${_matches!.length})',
                child: Column(children: [
                  for (final m in _matches!)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                          (m['activo'] == true)
                              ? Icons.person
                              : Icons.person_off,
                          size: 20,
                          color: (m['activo'] == true)
                              ? scheme.primary
                              : scheme.outline),
                      title: Text(
                          '${m['codigo'] ?? ''} ${m['nombre']}'.trim(),
                          style: const TextStyle(fontSize: 13.5)),
                      subtitle: Text('${m['tenant']}',
                          style: const TextStyle(fontSize: 12)),
                      onTap: _cargando ? null : () => _abrir(m['id'] as String),
                    ),
                ]),
              ),
            if (_cargando)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_data != null) ..._radiografia(context, _data!),
          ],
        ),
      ),
    );
  }

  List<Widget> _radiografia(BuildContext context, Map<String, dynamic> d) {
    final scheme = Theme.of(context).colorScheme;
    final cl = Map<String, dynamic>.from(d['cliente'] as Map? ?? {});
    final senales = Map<String, dynamic>.from(d['senales'] as Map? ?? {});
    final contratos = (d['contratos'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final cuotas = (d['cuotas'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final pagos = (d['pagos'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final historial = (d['historial'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final cuotasTotal = _dgNum(d['cuotas_total']).toInt();

    return [
      // Ficha + veredicto.
      _DgSeccion(
        titulo:
            '${cl['codigo'] ?? ''} ${cl['nombre'] ?? ''} · ${cl['tenant'] ?? ''}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${(cl['activo'] == true) ? 'ACTIVO' : 'DESACTIVADO'}'
              ' · tel: ${_dg(cl['telefono'])}'
              ' · cobrador: ${_dg(cl['cobrador_asignado'])}'
              ' · cliente desde ${_dgFecha(cl['creado'])}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            for (final v in _veredicto(senales))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(v.$1, size: 17, color: v.$2),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(v.$3,
                            style: const TextStyle(
                                fontSize: 12.5, height: 1.35))),
                  ],
                ),
              ),
          ],
        ),
      ),
      // Contratos.
      _DgSeccion(
        titulo: 'Contratos (${contratos.length})',
        child: contratos.isEmpty
            ? const Text('Sin contratos.', style: TextStyle(fontSize: 12.5))
            : Column(children: [
                for (final ct in contratos)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.description_outlined,
                            size: 16,
                            color: _dgEstadoColor(
                                context, '${ct['estado']}')),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${ct['codigo'] ?? 'contrato'} · '
                            '${'${ct['estado']}'.toUpperCase()} · '
                            '${_dg(ct['plan'])} '
                            '(${Fmt.cordobas(_dgNum(ct['precio_mensual']))}/mes) · '
                            'día de pago ${_dg(ct['dia_pago'])}'
                            '${ct['cancelado_en'] != null ? ' · cancelado ${_dgFecha(ct['cancelado_en'])}${ct['tiene_snapshot'] == true ? ' (con foto de deuda)' : ''}' : ''}'
                            '${ct['motivo_cancelacion'] != null ? '\nMotivo: ${ct['motivo_cancelacion']}' : ''}',
                            style: const TextStyle(fontSize: 12.5, height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ),
              ]),
      ),
      // Cuotas.
      _DgSeccion(
        titulo: 'Cuotas (últimas ${cuotas.length} de $cuotasTotal)',
        child: Column(children: [
          for (final cu in cuotas)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _dgEstadoColor(context, '${cu['estado']}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Vence ${_dgFecha(cu['fecha_vencimiento'])} · '
                      '${Fmt.cordobas(_dgNum(cu['monto']) + _dgNum(cu['cargos_neto']))} · '
                      '${'${cu['estado']}'.toUpperCase()}'
                      '${_dgNum(cu['monto_pagado']) > 0.009 ? ' (pagado ${Fmt.cordobas(_dgNum(cu['monto_pagado']))})' : ''}'
                      '${cu['es_cargo_manual'] == true ? ' · cargo manual' : ''}'
                      '${cu['motivo_anulacion'] != null ? '\nAnulada ${_dgFecha(cu['anulada_en'])}: ${cu['motivo_anulacion']}' : ''}',
                      style: const TextStyle(fontSize: 12, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
        ]),
      ),
      // Pagos.
      _DgSeccion(
        titulo: 'Pagos (últimos ${pagos.length})',
        child: pagos.isEmpty
            ? const Text('Sin pagos registrados.',
                style: TextStyle(fontSize: 12.5))
            : Column(children: [
                for (final p in pagos)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '${_dgFecha(p['fecha_pago'])} · '
                      '${Fmt.cordobas(_dgNum(p['monto']))} (${p['metodo']}) · '
                      '${_dg(p['cobrador'])}'
                      '${p['recibo'] != null ? ' · recibo ${p['recibo']}' : ' · SIN recibo'}'
                      '${p['en_revision'] == true ? ' · EN CUARENTENA' : ''}'
                      '${p['anulado'] == true ? ' · ANULADO (${_dg(p['motivo_anulacion'])})' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: (p['anulado'] == true)
                            ? scheme.outline
                            : scheme.onSurface,
                      ),
                    ),
                  ),
              ]),
      ),
      // Historial op_log.
      _DgSeccion(
        titulo: 'Historial (últimos ${historial.length} eventos)',
        child: historial.isEmpty
            ? const Text('Sin eventos.', style: TextStyle(fontSize: 12.5))
            : Column(children: [
                for (final h in historial)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '${_dgFecha(h['ocurrido_en'])} · ${h['tipo_op']} '
                      '(${h['entidad']}) · ${_dg(h['actor'])}'
                      '${(h['resumen'] as Map?)?['motivo'] != null ? '\n${(h['resumen'] as Map)['motivo']}' : ''}',
                      style: const TextStyle(fontSize: 12, height: 1.35),
                    ),
                  ),
              ]),
      ),
    ];
  }
}

// ───────────────────────── 2. Invariantes ─────────────────────────

class _TabInvariantes extends ConsumerStatefulWidget {
  const _TabInvariantes();

  @override
  ConsumerState<_TabInvariantes> createState() => _TabInvariantesState();
}

class _TabInvariantesState extends ConsumerState<_TabInvariantes>
    with AutomaticKeepAliveClientMixin {
  String? _tenantId;
  String? _tenantNombre;
  bool _corriendo = false;
  String? _error;
  List<Map<String, dynamic>>? _rows;

  @override
  bool get wantKeepAlive => true;

  Future<void> _correr() async {
    if (_tenantId == null) return;
    setState(() {
      _corriendo = true;
      _error = null;
      _rows = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
          'super_admin_verificar_invariantes',
          params: {'p_tenant': _tenantId});
      if (!mounted) return;
      setState(() => _rows = [
            for (final e in (res as List))
              Map<String, dynamic>.from(e as Map),
          ]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is PostgrestException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _corriendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final tenantsAsync = ref.watch(tenantsAdminProvider);
    final violadas = _rows
        ?.where((r) => _dgNum(r['violaciones']) > 0)
        .toList(growable: false);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
                'Corre los chequeos de integridad de dinero contra la data '
                'REAL de una empresa. Solo lectura. Todos en 0 = contablemente '
                'sana.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            tenantsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => _DgError(
                  texto: 'No pude cargar las empresas: $e',
                  onReintentar: () => ref.invalidate(tenantsAdminProvider)),
              data: (tenants) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in tenants)
                    ChoiceChip(
                      label: Text(t.nombre,
                          style: const TextStyle(fontSize: 12.5)),
                      selected: _tenantId == t.id,
                      onSelected: _corriendo
                          ? null
                          : (_) => setState(() {
                                _tenantId = t.id;
                                _tenantNombre = t.nombre;
                                _rows = null;
                                _error = null;
                              }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _tenantId == null || _corriendo ? null : _correr,
                icon: _corriendo
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.rule, size: 18),
                label: Text(_tenantNombre == null
                    ? 'Verificar invariantes'
                    : 'Verificar $_tenantNombre'),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null) _DgError(texto: _error!, onReintentar: _correr),
            if (_rows != null && violadas != null) ...[
              if (violadas.isEmpty)
                Card(
                  color: const Color(0xFF1B7A3D).withValues(alpha: 0.12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      const Icon(Icons.check_circle, color: Color(0xFF1D9E75)),
                      const SizedBox(width: 10),
                      // El conteo sale del resultado, NO hardcodeado: el número
                      // creció 17 -> 20 -> 31 y el texto quedaba viejo cada vez.
                      Expanded(
                          child: Text(
                              'Los ${_rows!.length} invariantes dan 0 violaciones — la '
                              'contabilidad está estructuralmente sana.',
                              style: const TextStyle(fontSize: 13))),
                    ]),
                  ),
                )
              else ...[
                for (final r in violadas)
                  Card(
                    color: scheme.errorContainer.withValues(alpha: 0.35),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${'${r['invariante']}'.split(':').first} — '
                              '${_dgNum(r['violaciones']).toInt()} violación(es)',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(
                              kInvInfo['${r['invariante']}'.split(':').first]
                                      ?.explicacion ??
                                  '${r['invariante']}',
                              style: const TextStyle(
                                  fontSize: 12, height: 1.35)),
                          if ('${r['ejemplo_ids'] ?? ''}'.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            SelectableText('IDs: ${r['ejemplo_ids']}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ],
                      ),
                    ),
                  ),
                Text(
                    '${_rows!.length - violadas.length} chequeo(s) '
                    'restante(s) en 0.',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 3. Talonarios ─────────────────────────

class _TabTalonarios extends StatefulWidget {
  const _TabTalonarios();

  @override
  State<_TabTalonarios> createState() => _TabTalonariosState();
}

class _TabTalonariosState extends State<_TabTalonarios>
    with AutomaticKeepAliveClientMixin {
  bool _cargando = true;
  String? _error;
  Map<String, dynamic>? _data;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final res =
          await Supabase.instance.client.rpc('super_admin_diag_talonarios');
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is PostgrestException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _DgError(texto: _error!, onReintentar: _cargar);
    }
    final series = (_data!['series'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final huecos = (_data!['huecos'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final ignorados = (_data!['ignorados'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: RefreshIndicator(
          onRefresh: _cargar,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Botón explícito: en Windows (mouse) no existe pull-to-refresh.
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FilledButton.tonalIcon(
                    onPressed: _cargar,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Actualizar'),
                  ),
                ),
              ),
              _DgSeccion(
                titulo: 'Series de recibos (${series.length})',
                child: Column(children: [
                  for (final s in series)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        '${s['tenant']} · serie ${s['prefijo']} · '
                        'último n.° ${s['max_correlativo']} · '
                        '${s['total']} recibo(s)'
                        '${_dgNum(s['anulados']) > 0 ? ' (${_dgNum(s['anulados']).toInt()} anulados)' : ''} · '
                        'último: ${_dgFecha(s['ultimo'])} · '
                        'usa: ${_dg(s['duenos'])}',
                        style: const TextStyle(fontSize: 12, height: 1.35),
                      ),
                    ),
                ]),
              ),
              _DgSeccion(
                titulo: 'Huecos vigentes (${huecos.length})',
                child: huecos.isEmpty
                    ? const Text('Sin huecos pendientes — numeración continua.',
                        style: TextStyle(fontSize: 12.5))
                    : Column(children: [
                        for (final h in huecos)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              '${h['tenant']} · ${h['prefijo']} '
                              '${h['desde']}–${h['hasta']} '
                              '(faltan ${h['faltan']}) · ${_dg(h['cobrador'])}',
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: scheme.error),
                            ),
                          ),
                        const SizedBox(height: 4),
                        const Text(
                            'Se gestionan desde la bandeja del tenant '
                            '(impersonando): Ignorar con registro.',
                            style: TextStyle(fontSize: 11.5)),
                      ]),
              ),
              _DgSeccion(
                titulo: 'Huecos ignorados con registro (${ignorados.length})',
                child: ignorados.isEmpty
                    ? const Text('Ninguno todavía.',
                        style: TextStyle(fontSize: 12.5))
                    : Column(children: [
                        for (final i in ignorados)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              '${i['tenant']} · ${i['prefijo']} '
                              '${i['desde']}–${i['hasta']} · '
                              'por ${_dg(i['por'])} el ${_dgFecha(i['cuando'])}'
                              '${i['motivo'] != null ? ' · ${i['motivo']}' : ''}',
                              style:
                                  const TextStyle(fontSize: 12, height: 1.35),
                            ),
                          ),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 4. Fantasmas ─────────────────────────

class _TabFantasmas extends StatefulWidget {
  const _TabFantasmas();

  @override
  State<_TabFantasmas> createState() => _TabFantasmasState();
}

class _TabFantasmasState extends State<_TabFantasmas>
    with AutomaticKeepAliveClientMixin {
  bool _cargando = true;
  String? _error;
  Map<String, dynamic>? _data;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final res =
          await Supabase.instance.client.rpc('super_admin_diag_fantasmas');
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is PostgrestException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _DgError(texto: _error!, onReintentar: _cargar);
    }
    final fantasmas = (_data!['cuotas_fantasma'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rechazos = (_data!['rechazos_14d'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final cuarentenas = (_data!['cuarentenas'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final sinRecibo = (_data!['pagos_sin_recibo'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: RefreshIndicator(
          onRefresh: _cargar,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Botón explícito: en Windows (mouse) no existe pull-to-refresh.
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FilledButton.tonalIcon(
                    onPressed: _cargar,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Actualizar'),
                  ),
                ),
              ),
              _DgSeccion(
                titulo:
                    'Cuotas vivas nacidas DESPUÉS de cancelar el contrato (${fantasmas.length})',
                child: fantasmas.isEmpty
                    ? const Text('Ninguna — los cancelados no generan cuotas.',
                        style: TextStyle(fontSize: 12.5))
                    : Column(children: [
                        for (final f in fantasmas)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              '${f['tenant']} · ${f['cliente']} · '
                              'contrato ${_dg(f['contrato'])} '
                              '(cancelado ${_dgFecha(f['contrato_cancelado_en'])}) · '
                              'cuota creada ${_dgFecha(f['creada'])} '
                              'por ${f['firma']} · ${'${f['estado']}'.toUpperCase()}',
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: scheme.error),
                            ),
                          ),
                      ]),
              ),
              _DgSeccion(
                titulo: 'Rechazos de sync — últimos 14 días',
                child: rechazos.isEmpty
                    ? const Text('Sin rechazos en 14 días.',
                        style: TextStyle(fontSize: 12.5))
                    : Column(children: [
                        for (final r in rechazos)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '${_dgFecha(r['dia'])} · ${r['tenant']}: '
                              '${r['total']} rechazo(s)'
                              '${_dgNum(r['sin_resolver']) > 0 ? ' (${_dgNum(r['sin_resolver']).toInt()} sin resolver)' : ' (todos resueltos)'}',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                color: _dgNum(r['sin_resolver']) > 0
                                    ? scheme.error
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                      ]),
              ),
              _DgSeccion(
                titulo: 'Cuarentenas abiertas por empresa',
                child: cuarentenas.isEmpty
                    ? const Text('Ninguna — nada esperando decisión.',
                        style: TextStyle(fontSize: 12.5))
                    : Column(children: [
                        for (final c in cuarentenas)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                                '${c['tenant']}: ${_dgNum(c['abiertas']).toInt()} cobro(s) en cuarentena',
                                style: const TextStyle(
                                    fontSize: 12, height: 1.3)),
                          ),
                      ]),
              ),
              _DgSeccion(
                titulo: 'Pagos sin recibo por empresa',
                child: sinRecibo.isEmpty
                    ? const Text('Ninguno — todo pago vivo tiene su recibo.',
                        style: TextStyle(fontSize: 12.5))
                    : Column(children: [
                        for (final p in sinRecibo)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                                '${p['tenant']}: ${_dgNum(p['pagos']).toInt()} pago(s) sin recibo '
                                '(reparable en Operaciones → "Generar recibos faltantes")',
                                style: const TextStyle(
                                    fontSize: 12, height: 1.3)),
                          ),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
