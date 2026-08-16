import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../powersync/db.dart' as ps;
import '../../../../data/utils/errores.dart';
import '../../../shared/widgets/selector_buscable.dart';

/// Selector en cascada de la topología de red (Nodo → Hub → Puerto) para
/// asignar `clientes.puerto_id`. **Solo selección** (la topología la administra
/// el admin en `/admin/red`; acá no se crea inline). El Hub y el Nodo se
/// derivan del Puerto elegido. Asignación opcional en el cliente.
class RedPicker extends StatefulWidget {
  const RedPicker({
    super.key,
    required this.tenantId,
    required this.puertoId,
    required this.onChanged,
    this.clienteIdActual,
  });
  final String tenantId;
  final String? puertoId;
  final ValueChanged<String?> onChanged;

  /// Cliente que se está editando — para excluirlo del "ocupado por" (sino su
  /// propio puerto se mostraría como ocupado por sí mismo). null en el alta.
  final String? clienteIdActual;

  @override
  State<RedPicker> createState() => _RedPickerState();
}

class _RedPickerState extends State<RedPicker> {
  String? _nodoId;
  String? _hubId;
  String? _puertoId;
  bool _cargando = true;

  /// Streams cacheados (no inline en build): el form de cliente reconstruye en
  /// cada tecla, así que crear el stream en build re-suscribiría el StreamBuilder
  /// (anti-patrón "Stream already listened"). Los de hub/puerto se recrean en los
  /// onChanged / al hidratar.
  late final Stream<List<Map<String, dynamic>>> _nodosStream;
  Stream<List<Map<String, dynamic>>> _hubsStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _puertosStream = const Stream.empty();

  Stream<List<Map<String, dynamic>>> _watchHubs(String nodoId) => ps.db.watch(
        'SELECT id, nombre FROM red_hubs WHERE nodo_id = ? ORDER BY nombre',
        parameters: [nodoId],
      );
  Stream<List<Map<String, dynamic>>> _watchPuertos(String hubId) => ps.db.watch(
        // ocupado_por: nombre del cliente ACTIVO ya asignado a esa boca (≠ el
        // que se edita) — para señalar los ocupados en el picker (audit
        // 2026-07-04). El aviso duro-forzable vive en el guardar del form.
        'SELECT p.id, p.nombre, '
        '(SELECT c.nombre FROM clientes c '
        '   WHERE c.puerto_id = p.id AND c.activo = 1 AND c.id != ? LIMIT 1) '
        'AS ocupado_por '
        'FROM red_puertos p WHERE p.hub_id = ? ORDER BY p.nombre',
        parameters: [widget.clienteIdActual ?? '', hubId],
      );

  @override
  void initState() {
    super.initState();
    // Filtro por tenant (F1): igual que geo_picker — la red está en
    // catalogo_tenant, así que la SQLite del super_admin impersonando tiene los
    // nodos de System + del impersonado; sin el WHERE el dropdown daría la unión.
    // Hub/Puerto ya filtran por FK del padre.
    _nodosStream = ps.db.watch(
      'SELECT id, nombre FROM red_nodos WHERE tenant_id = ? ORDER BY nombre',
      parameters: [widget.tenantId],
    );
    _puertoId = widget.puertoId;
    _resolverCascada();
  }

  @override
  void didUpdateWidget(covariant RedPicker old) {
    super.didUpdateWidget(old);
    if (widget.puertoId != _puertoId) {
      _puertoId = widget.puertoId;
      _resolverCascada();
    }
  }

  /// Si llega un puertoId pre-existente, hidratamos nodo + hub.
  Future<void> _resolverCascada() async {
    if (_puertoId == null) {
      setState(() => _cargando = false);
      return;
    }
    // try/finally: si la hidratación lanza (SQLite ocupado, mismatch durante un
    // bump), NO dejamos el spinner colgado para siempre → mostramos los
    // selectores y el usuario re-elige la red.
    try {
      final rows = await ps.db.getAll(
        '''
        SELECT h.nodo_id AS nodo, p.hub_id AS hub
          FROM red_puertos p
          JOIN red_hubs h ON h.id = p.hub_id
         WHERE p.id = ?
        ''',
        [_puertoId!],
      );
      if (!mounted) return;
      if (rows.isNotEmpty) {
        _nodoId = rows.first['nodo'] as String?;
        _hubId = rows.first['hub'] as String?;
      }
      if (_nodoId != null) _hubsStream = _watchHubs(_nodoId!);
      if (_hubId != null) _puertosStream = _watchPuertos(_hubId!);
    } catch (_) {
      // Silencioso: el usuario puede re-elegir manualmente la cascada.
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RedSelector(
          label: 'Nodo',
          valueId: _nodoId,
          stream: _nodosStream,
          emptyHint: 'Aún no cargaste tu red. '
              'Configurala en Administración → Red.',
          onChanged: (id) {
            setState(() {
              _nodoId = id;
              _hubId = null;
              _puertoId = null;
              _hubsStream = id == null ? const Stream.empty() : _watchHubs(id);
              _puertosStream = const Stream.empty();
            });
            widget.onChanged(null);
          },
        ),
        const SizedBox(height: 12),
        _RedSelector(
          // Key por nodo: al cambiar de nodo recreamos el dropdown para que el
          // FormField tome el valueId fresco (evita estado viejo con initialValue).
          key: ValueKey('hub-$_nodoId'),
          label: 'Hub',
          valueId: _hubId,
          enabled: _nodoId != null,
          stream: _hubsStream,
          emptyHint: 'Este nodo aún no tiene hubs. '
              'Agregalos en Administración → Red.',
          onChanged: (id) {
            setState(() {
              _hubId = id;
              _puertoId = null;
              _puertosStream =
                  id == null ? const Stream.empty() : _watchPuertos(id);
            });
            widget.onChanged(null);
          },
        ),
        const SizedBox(height: 12),
        _RedSelector(
          key: ValueKey('puerto-$_hubId'),
          label: 'Puerto',
          valueId: _puertoId,
          enabled: _hubId != null,
          stream: _puertosStream,
          emptyHint: 'Este hub aún no tiene puertos. '
              'Agregalos en Administración → Red.',
          onChanged: (id) {
            setState(() => _puertoId = id);
            widget.onChanged(id);
          },
        ),
      ],
    );
  }
}

/// Selector de un eslabón de la cascada (Nodo / Hub / Puerto). Read-only +
/// buscador (reemplaza al `DropdownButtonFormField`; patrón canónico de
/// `selector_buscable.dart`, regla #1d). Sigue alimentándose del `stream`
/// (reactivo a la cascada: al cambiar el padre llegan filas nuevas) para
/// mostrar el nombre del valor actual y poblar las opciones del buscador.
class _RedSelector extends StatefulWidget {
  const _RedSelector({
    super.key,
    required this.label,
    required this.valueId,
    required this.stream,
    required this.onChanged,
    this.enabled = true,
    this.emptyHint,
  });

  final String label;
  final String? valueId;
  final Stream<List<Map<String, dynamic>>> stream;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  /// Si el catálogo está vacío y este hint no es null, se muestra debajo del
  /// selector (ej. en Nodo: "cargá tu red en Administración → Red").
  final String? emptyHint;

  @override
  State<_RedSelector> createState() => _RedSelectorState();
}

class _RedSelectorState extends State<_RedSelector> {
  final _ctrl = TextEditingController();
  // Filas vivas del stream (catálogo de este eslabón). Mantenidas para poblar
  // el buscador y resolver el nombre del valor actual, sin re-consultar la DB.
  List<Map<String, dynamic>> _rows = const [];
  Object? _error;
  // ¿Ya emitió el stream al menos una vez? Para no mostrar el emptyHint
  // mientras todavía está cargando (igual que el connectionState != waiting
  // del StreamBuilder original).
  bool _emitio = false;
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  @override
  void initState() {
    super.initState();
    _suscribir();
    _sincronizarTexto();
  }

  @override
  void didUpdateWidget(covariant _RedSelector old) {
    super.didUpdateWidget(old);
    // El padre recrea el stream al cambiar la cascada → re-suscribir.
    if (!identical(old.stream, widget.stream)) {
      _emitio = false;
      _suscribir();
    }
    // El valueId puede cambiar desde afuera (reset de cascada / hidratación).
    if (old.valueId != widget.valueId) _sincronizarTexto();
  }

  void _suscribir() {
    _sub?.cancel();
    _sub = widget.stream.listen((rows) {
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
        _emitio = true;
      });
      _sincronizarTexto();
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _emitio = true;
      });
    });
  }

  // Refleja en el TextField el nombre del valor actual (o vacío si null / ya no
  // existe en el catálogo, ej. el padre cambió y la selección quedó huérfana).
  void _sincronizarTexto() {
    final id = widget.valueId;
    if (id == null) {
      _ctrl.text = '';
      return;
    }
    final fila = _rows.where((r) => r['id'] == id).toList();
    _ctrl.text = fila.isEmpty ? '' : (fila.first['nombre'] as String);
  }

  Future<void> _elegir() async {
    if (!widget.enabled) return;
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí ${widget.label}',
      hint: 'Buscar...',
      opciones: [
        // "Ninguno" como mapa CENTINELA no-null (id: null): con el genérico
        // nullable, tocar '—' devolvía null IGUAL que cancelar → no-op y no se
        // podía DESASIGNAR Nodo/Hub/Puerto. Ahora '—' devuelve un mapa no-null →
        // dispara onChanged(null); cancelar sigue devolviendo null (audit
        // 2026-06-30, mismo patrón que _SelectorCobrador).
        const OpcionSelector(valor: <String, dynamic>{'id': null}, nombre: '—'),
        for (final r in _rows)
          OpcionSelector(
            valor: r,
            // Solo los puertos traen 'ocupado_por' (nodo/hub → null): señalá
            // la boca ya ocupada por otro cliente activo.
            nombre: r['ocupado_por'] != null
                ? '${r['nombre']} · ocupado: ${r['ocupado_por']}'
                : r['nombre'] as String,
          ),
      ],
    );
    // null = se cerró/canceló el diálogo → no tocar la selección.
    if (elegido == null || !mounted) return;
    final id = elegido['id'] as String?;
    setState(() => _ctrl.text =
        id == null ? '' : (elegido['nombre'] as String));
    widget.onChanged(id);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(mensajeErrorHumano(_error!)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          readOnly: true,
          enabled: widget.enabled,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: 'Toca para elegir',
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          onTap: _elegir,
        ),
        // Solo tras la primera emisión del stream (no durante la carga), para
        // no parpadear "no tiene hubs" cuando el nodo SÍ tiene.
        if (widget.enabled &&
            _emitio &&
            _rows.isEmpty &&
            widget.emptyHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              widget.emptyHint!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline),
            ),
          ),
      ],
    );
  }
}
