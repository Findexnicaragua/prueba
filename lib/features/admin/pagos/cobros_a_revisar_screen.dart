import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/pagos_repo.dart';
import '../../../data/utils/busqueda_cliente.dart'
    show foldSqlExpr, tokensBusqueda;
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

/// Cuotas cobradas POR ENCIMA de su total, para que un humano las resuelva.
///
/// Nace del incidente del 26/07/2026: 72 pagos cargados por dos usuarios sobre
/// el mismo histórico dejaron 36 cuotas sobrepagadas (C$30.003) y nadie se
/// enteró hasta correr `invariantes_dinero.sql` a mano.
///
/// El guard del server (0214) ya anula solo la copia EXACTA (misma cuota, mismo
/// monto, mismo día). Acá cae lo que el server NO puede decidir: montos o
/// fechas distintas, donde el segundo pago puede ser plata real imputada al mes
/// equivocado. Esa diferencia la tiene que ver una persona.
///
/// **La lista se DERIVA del flag, no se marca "revisado".** Una cuota aparece
/// porque tiene un pago EN REVISIÓN (cuarentena 0218: un sobrepago no-exacto
/// queda `en_revision=1`, excluido de toda métrica) y desaparece cuando se
/// resuelve (se elige el verdadero → el otro se anula; o se descarta el
/// duplicado). Sin botón de "ya lo miré" que esconda plata en cuarentena.
/// El conteo alimenta el badge; comparte la MISMA condición que la lista.
final cobrosARevisarCountProvider = StreamProvider<int>((ref) {
  return ps.db
      .watch('SELECT COUNT(DISTINCT cu.id) AS cnt FROM cuotas cu '
          'JOIN pagos p ON p.cuota_id = cu.id '
          "WHERE cu.estado <> 'anulada' AND p.anulado = 0 AND p.en_revision = 1")
      .map((rows) => (rows.first['cnt'] as num?)?.toInt() ?? 0);
});

class CobrosARevisarScreen extends ConsumerStatefulWidget {
  const CobrosARevisarScreen({super.key});

  @override
  ConsumerState<CobrosARevisarScreen> createState() =>
      _CobrosARevisarScreenState();
}

class _CobrosARevisarScreenState extends ConsumerState<CobrosARevisarScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _debounce;
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Una cuota entra si tiene un pago EN REVISIÓN (cuarentena 0218): un 2º cobro
  /// que sobrepasa el total y no es duplicado exacto queda `en_revision=1` →
  /// NO cuenta en ninguna métrica hasta que una persona decide cuál es el
  /// verdadero. (Antes se derivaba de `monto_pagado > total`; con la cuarentena
  /// el en_revision ya no infla monto_pagado, así que el disparador es el flag.)
  Stream<List<Map<String, dynamic>>> _buildStream() {
    final where = <String>[
      "cu.estado <> 'anulada'",
      'EXISTS (SELECT 1 FROM pagos pr WHERE pr.cuota_id = cu.id '
          'AND pr.anulado = 0 AND pr.en_revision = 1)',
    ];
    final params = <Object?>[];
    if (_query.isNotEmpty) {
      // Tokens + plegado de ñ/acentos (AGENTS #1d y #10): "maria ruiz"
      // encuentra "María Luisa Peña Ruíz".
      final expr = foldSqlExpr('c.nombre');
      for (final tok in tokensBusqueda(_query)) {
        where.add('$expr LIKE ?');
        params.add('%$tok%');
      }
    }
    return ps.db.watch(
      'SELECT cu.id AS cuota_id, cu.periodo, cu.monto, '
      'COALESCE(cu.cargos_neto, 0) AS cargos, cu.monto_pagado, '
      'c.id AS cliente_id, c.nombre AS cliente, ct.dia_pago AS dia_pago '
      'FROM cuotas cu '
      // Por `cliente_id` (NOT NULL), NO por `contrato_id` (que SÍ es nullable):
      // con ese el JOIN perdería filas y la lista quedaría más corta que el
      // badge, que no joinea. Verificado contra el esquema.
      'JOIN clientes c ON c.id = cu.cliente_id '
      // LEFT para el `dia_pago` que necesita el mes de servicio (mesServicioLabel):
      // LEFT porque `contrato_id` es nullable (cuotas manuales) → no dropea filas;
      // dia_pago NULL cae al mes del período (sin corrimiento), como debe ser.
      'LEFT JOIN contratos ct ON ct.id = cu.contrato_id '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY c.nombre, cu.periodo',
      parameters: params,
    );
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _query = v.trim();
        _stream = _buildStream();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // Cold-start: recrear el stream si la DB se recrea (cambio de usuario o
    // schema), para no quedar leyendo una conexión cerrada.
    ref.listen(dbEpochProvider, (_, __) {
      if (mounted) setState(() => _stream = _buildStream());
    });
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final rows = snap.data ?? const <Map<String, dynamic>>[];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  hintText: 'Buscar por cliente',
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            _onSearch('');
                          },
                        ),
                ),
              ),
            ),
            if (rows.isNotEmpty)
              Container(
                width: double.infinity,
                color: scheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  'Estas cuotas quedaron cobradas por encima de su total. '
                  'Cada una tiene más de un pago: uno sobra, o uno va a otro mes.',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onErrorContainer, height: 1.4),
                ),
              ),
            Expanded(
              child: rows.isEmpty
                  ? EmptyState(
                      icon: Icons.verified_outlined,
                      titulo: _query.isEmpty
                          ? 'Nada que revisar'
                          : 'Sin resultados',
                      descripcion: _query.isEmpty
                          ? 'Ninguna cuota está cobrada por encima de su total.'
                          : 'Ningún cliente con ese nombre tiene cuotas para revisar.',
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      children: _porCliente(rows)
                          .map((g) => _ClienteCard(grupo: g))
                          .toList(),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Agrupa por cliente preservando el orden del SQL (ya viene por nombre).
  List<_Grupo> _porCliente(List<Map<String, dynamic>> rows) {
    final out = <_Grupo>[];
    for (final r in rows) {
      final id = r['cliente_id'] as String;
      if (out.isNotEmpty && out.last.clienteId == id) {
        out.last.cuotas.add(r);
      } else {
        out.add(_Grupo(
          clienteId: id,
          cliente: (r['cliente'] as String?) ?? 'Sin nombre',
          cuotas: [r],
        ));
      }
    }
    return out;
  }
}

class _Grupo {
  _Grupo({required this.clienteId, required this.cliente, required this.cuotas});
  final String clienteId;
  final String cliente;
  final List<Map<String, dynamic>> cuotas;

  double get totalSobrante => cuotas.fold(
      0.0,
      (a, r) =>
          a +
          ((r['monto_pagado'] as num).toDouble() -
              (r['monto'] as num).toDouble() -
              (r['cargos'] as num).toDouble()));
}

class _ClienteCard extends StatelessWidget {
  const _ClienteCard({required this.grupo});
  final _Grupo grupo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(grupo.cliente,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Text(
                  grupo.cuotas.length == 1
                      ? '1 cuota'
                      : '${grupo.cuotas.length} cuotas',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text('Sobra ${Fmt.cordobas(grupo.totalSobrante)} en total',
                style: TextStyle(fontSize: 12, color: scheme.error)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: grupo.cuotas.map((r) {
                final sobra = (r['monto_pagado'] as num).toDouble() -
                    (r['monto'] as num).toDouble() -
                    (r['cargos'] as num).toDouble();
                final periodo = DateTime.tryParse(r['periodo'] as String? ?? '');
                return ActionChip(
                  label: Text(
                    '${periodo == null ? '?' : Fmt.mesServicioLabel(periodo, (r['dia_pago'] as num?)?.toInt())} · '
                    '${Fmt.cordobas(sobra)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: () => _abrirDetalle(context, r),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _abrirDetalle(BuildContext context, Map<String, dynamic> cuota) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DetalleCuotaSheet(cuota: cuota, cliente: grupo.cliente),
    );
  }
}

/// Los pagos vivos de la cuota, enfrentados. Es una hoja y no una ruta a
/// propósito: las rutas del ShellRoute admin se navegan con `go` y no con
/// `push` (AGENTS #12), y para comparar dos pagos no hace falta una pantalla.
class _DetalleCuotaSheet extends ConsumerStatefulWidget {
  const _DetalleCuotaSheet({required this.cuota, required this.cliente});
  final Map<String, dynamic> cuota;
  final String cliente;

  @override
  ConsumerState<_DetalleCuotaSheet> createState() => _DetalleCuotaSheetState();
}

class _DetalleCuotaSheetState extends ConsumerState<_DetalleCuotaSheet> {
  late final Stream<List<Map<String, dynamic>>> _pagos;
  // Overlay por bandera, NUNCA un showDialog de carga (AGENTS #7): si el await
  // falla, la barrera del diálogo dejaría la pantalla negra sin salida.
  bool _anulando = false;

  @override
  void initState() {
    super.initState();
    _pagos = ps.db.watch(
      'SELECT p.id, p.monto_cordobas, p.fecha_pago, p.metodo, p.notas, '
      'p.en_revision, '
      'co.nombre AS quien, r.numero_completo AS recibo '
      'FROM pagos p '
      'LEFT JOIN cobradores co ON co.id = p.cobrador_id '
      'LEFT JOIN recibos r ON r.pago_id = p.id AND r.anulado = 0 '
      'WHERE p.cuota_id = ? AND p.anulado = 0 '
      // en_revision DESC: el/los cobro(s) en revisión (los sospechosos) arriba.
      'ORDER BY p.en_revision DESC, p.fecha_pago, p.id',
      parameters: [widget.cuota['cuota_id']],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = (widget.cuota['monto'] as num).toDouble() +
        (widget.cuota['cargos'] as num).toDouble();
    final pagado = (widget.cuota['monto_pagado'] as num).toDouble();
    final periodo =
        DateTime.tryParse(widget.cuota['periodo'] as String? ?? '');
    final me = ref.watch(cobradorActualProvider).valueOrNull;
    // `lectura` mira pero no toca; los demás roles que llegan acá (admin,
    // admin_cobranza, super_admin) sí resuelven.
    final puedeAnular = me != null && !me.esLectura;

    return Stack(
      children: [
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.cliente} · '
                  '${periodo == null ? '' : Fmt.mesServicioLabel(periodo, (widget.cuota['dia_pago'] as num?)?.toInt())}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _Cifra(label: 'Total de la cuota', valor: total),
                    _Cifra(label: 'Cobrado (cuenta)', valor: pagado),
                  ],
                ),
                const Divider(height: 24),
                Flexible(
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: _pagos,
                    builder: (context, snap) {
                      final pagos = snap.data ?? const <Map<String, dynamic>>[];
                      if (pagos.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('Sin pagos vivos en esta cuota.'),
                        );
                      }
                      return ListView.separated(
                        shrinkWrap: true,
                        itemCount: pagos.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _PagoCard(
                          pago: pagos[i],
                          puedeAnular: puedeAnular,
                          onAnular: () => _anular(pagos[i]),
                          onEsVerdadero: () => _esVerdadero(pagos[i]),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'El cobro EN REVISIÓN no está contando en la caja. Elegí "Este '
                  'es el verdadero" en el cobro que corresponde: los demás se '
                  'anulan y queda uno solo. O anulá directamente el duplicado.',
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      height: 1.45),
                ),
              ],
            ),
          ),
        ),
        if (_anulando)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.3),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Future<void> _anular(Map<String, dynamic> pago) async {
    // No anular pagos del tenant mientras el super_admin impersona.
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => _MotivoAnulacionDialog(
        monto: (pago['monto_cordobas'] as num).toDouble(),
        recibo: pago['recibo'] as String?,
      ),
    );
    if (motivo == null || motivo.trim().isEmpty || !mounted) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    setState(() => _anulando = true);
    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: pago['id'] as String,
            anuladoPorId: me.id,
            motivo: motivo.trim(),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pago anulado')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mensajeErrorHumano(e))),
      );
    } finally {
      // Cleanup garantizado: sin esto una excepción deja el overlay puesto y
      // la hoja inutilizable (AGENTS #9).
      if (mounted) setState(() => _anulando = false);
    }
  }

  /// "Este es el verdadero": conserva [pago] y anula los demás cobros de la
  /// cuota (cuarentena 0218). Queda uno solo → la cuota sale de "Cobros a revisar".
  Future<void> _esVerdadero(Map<String, dynamic> pago) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('¿Este es el cobro verdadero?'),
        content: Text(
          'Se conserva este cobro '
          '(${Fmt.cordobas((pago['monto_cordobas'] as num).toDouble())}'
          '${pago['quien'] != null ? ' · ${pago['quien']}' : ''}) y se ANULAN '
          'los demás cobros de esta cuota. Queda uno solo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
    setState(() => _anulando = true);
    try {
      await ref.read(pagosRepoProvider).elegirCobroVerdadero(
            cuotaId: widget.cuota['cuota_id'] as String,
            pagoVerdaderoId: pago['id'] as String,
            actorId: me.id,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cobro confirmado. Los demás se anularon.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mensajeErrorHumano(e))),
      );
    } finally {
      if (mounted) setState(() => _anulando = false);
    }
  }
}

class _Cifra extends StatelessWidget {
  const _Cifra({required this.label, required this.valor});
  final String label;
  final double valor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          Text(Fmt.cordobas(valor),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Fecha del pago, con la hora SOLO si dice algo. Los pagos cargados como
/// histórico (fecha elegida a mano, sin hora) quedan en 00:00: mostrarlo sería
/// dar por dato una hora que nadie registró, y justo esos son los que más se
/// van a mirar acá. Un cobro hecho con la app sí trae su hora real y se muestra.
String _fechaLegible(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return dt.hour == 0 && dt.minute == 0
      ? Fmt.fechaNi(iso)
      : Fmt.fechaHoraNi(iso);
}

class _PagoCard extends StatelessWidget {
  const _PagoCard({
    required this.pago,
    required this.puedeAnular,
    required this.onAnular,
    required this.onEsVerdadero,
  });
  final Map<String, dynamic> pago;
  final bool puedeAnular;
  final VoidCallback onAnular;
  final VoidCallback onEsVerdadero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quien = (pago['quien'] as String?) ?? 'Sin usuario';
    final recibo = pago['recibo'] as String?;
    final notas = pago['notas'] as String?;
    final enRevision = ((pago['en_revision'] as num?)?.toInt() ?? 0) == 1;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
            color: enRevision ? scheme.error : scheme.outlineVariant,
            width: enRevision ? 1.5 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  Fmt.cordobas((pago['monto_cordobas'] as num).toDouble()),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Text(_fechaLegible(pago['fecha_pago'] as String?),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          if (enRevision) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('EN REVISIÓN · no cuenta en la caja',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: scheme.onErrorContainer)),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Registró: $quien'
            '${recibo == null ? '' : '\nRecibo $recibo'}'
            ' · ${pago['metodo'] ?? ''}'
            '${notas == null || notas.isEmpty ? '' : '\n$notas'}',
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant, height: 1.5),
          ),
          if (puedeAnular) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Este es el verdadero'),
                  onPressed: onEsVerdadero,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.block, size: 18),
                  label: const Text('Anular este'),
                  onPressed: onAnular,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Confirmación con motivo. `showDialog` acá es el patrón correcto (el usuario
/// lo cierra), a diferencia de usarlo como indicador de carga.
class _MotivoAnulacionDialog extends StatefulWidget {
  const _MotivoAnulacionDialog({required this.monto, this.recibo});
  final double monto;
  final String? recibo;

  @override
  State<_MotivoAnulacionDialog> createState() => _MotivoAnulacionDialogState();
}

class _MotivoAnulacionDialogState extends State<_MotivoAnulacionDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Se anula el pago de ${Fmt.cordobas(widget.monto)}'
            '${widget.recibo == null ? '' : ' (recibo ${widget.recibo})'}. '
            'La cuota vuelve a su saldo anterior y el recibo emitido queda '
            'inválido. Queda registrado quién lo anuló y por qué.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Motivo',
              hintText: 'Cobro cargado dos veces',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          // El context del builder del diálogo, NO el del State externo
          // (AGENTS #8): con GoRouter el de afuera puede cerrar otra pantalla.
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _ctrl.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _ctrl.text),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}
