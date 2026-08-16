import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../../powersync/db.dart' as ps;
import '../../../../data/utils/busqueda_cliente.dart';
import '../../../../data/utils/errores.dart';
import '../../../../data/utils/op_log.dart';
import '../../../shared/widgets/selector_buscable.dart';

/// Selector geo en cascada (departamento → municipio → comunidad) con
/// opción de crear inline cualquier nivel si no existe.
/// Recibe `comunidadId` (puede ser null) y notifica cambios.
class GeoPicker extends StatefulWidget {
  const GeoPicker({
    super.key,
    required this.tenantId,
    required this.comunidadId,
    required this.onChanged,
    this.usuarioId,
  });

  /// Tenant actual — la geografía es per-tenant (migración 0097), así que las
  /// filas que se crean inline deben llevar `tenant_id` (la RLS lo exige).
  final String tenantId;
  final String? comunidadId;
  final ValueChanged<String?> onChanged;

  /// Usuario actual — para atribuir el op_log de una geo creada inline (mismo
  /// registro que la crea desde geografia_admin_screen). null → System.
  final String? usuarioId;

  @override
  State<GeoPicker> createState() => _GeoPickerState();
}

class _GeoPickerState extends State<GeoPicker> {
  String? _deptoId;
  String? _munId;
  String? _comId;
  bool _cargando = true;

  /// Streams cacheados (no inline en build): el form de cliente reconstruye en
  /// cada tecla, así que crear el stream en build re-suscribiría el StreamBuilder.
  /// Mismo patrón que RedPicker. Los de muni/comunidad se recrean en onChanged /
  /// al hidratar.
  late final Stream<List<Map<String, dynamic>>> _deptosStream;
  Stream<List<Map<String, dynamic>>> _munsStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _comsStream = const Stream.empty();

  Stream<List<Map<String, dynamic>>> _watchMunicipios(String deptoId) =>
      ps.db.watch(
        'SELECT id, nombre FROM municipios WHERE departamento_id = ? ORDER BY nombre',
        parameters: [deptoId],
      );
  Stream<List<Map<String, dynamic>>> _watchComunidades(String munId) =>
      ps.db.watch(
        'SELECT id, nombre FROM comunidades WHERE municipio_id = ? ORDER BY nombre',
        parameters: [munId],
      );

  @override
  void initState() {
    super.initState();
    // Filtro por tenant (F1): la SQLite del super_admin impersonando tiene la geo
    // de System (vía catalogo_tenant) + la del tenant impersonado → sin el WHERE
    // el dropdown raíz daría la unión. Los hijos (muni/comunidad) ya filtran por FK.
    _deptosStream = ps.db.watch(
      'SELECT id, nombre FROM departamentos WHERE tenant_id = ? ORDER BY nombre',
      parameters: [widget.tenantId],
    );
    _comId = widget.comunidadId;
    _resolverCascada();
  }

  @override
  void didUpdateWidget(covariant GeoPicker old) {
    super.didUpdateWidget(old);
    if (widget.comunidadId != _comId) {
      _comId = widget.comunidadId;
      _resolverCascada();
    }
  }

  /// Si llega un comunidadId pre-existente, hidratamos depto+municipio.
  Future<void> _resolverCascada() async {
    if (_comId == null) {
      setState(() => _cargando = false);
      return;
    }
    // try/finally: si la hidratación lanza, NO dejamos el spinner colgado.
    try {
      final rows = await ps.db.getAll(
        '''
        SELECT m.departamento_id AS depto, co.municipio_id AS mun
          FROM comunidades co
          JOIN municipios m ON m.id = co.municipio_id
         WHERE co.id = ?
        ''',
        [_comId],
      );
      if (!mounted) return;
      if (rows.isNotEmpty) {
        _deptoId = rows.first['depto'] as String?;
        _munId = rows.first['mun'] as String?;
      }
      if (_deptoId != null) _munsStream = _watchMunicipios(_deptoId!);
      if (_munId != null) _comsStream = _watchComunidades(_munId!);
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
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Selector(
          label: 'Departamento',
          valueId: _deptoId,
          stream: _deptosStream,
          onChanged: (id) {
            setState(() {
              _deptoId = id;
              _munId = null;
              _comId = null;
              _munsStream =
                  id == null ? const Stream.empty() : _watchMunicipios(id);
              _comsStream = const Stream.empty();
            });
            widget.onChanged(null);
          },
          onCreate: (nombre) =>
              _crearGeo('departamentos', {'tenant_id': widget.tenantId}, nombre),
        ),
        const SizedBox(height: 12),
        _Selector(
          label: 'Municipio',
          valueId: _munId,
          enabled: _deptoId != null,
          stream: _munsStream,
          onChanged: (id) {
            setState(() {
              _munId = id;
              _comId = null;
              _comsStream =
                  id == null ? const Stream.empty() : _watchComunidades(id);
            });
            widget.onChanged(null);
          },
          onCreate: _deptoId == null
              ? null
              : (nombre) => _crearGeo('municipios',
                  {'tenant_id': widget.tenantId, 'departamento_id': _deptoId},
                  nombre),
        ),
        const SizedBox(height: 12),
        _Selector(
          label: 'Comunidad',
          valueId: _comId,
          enabled: _munId != null,
          stream: _comsStream,
          onChanged: (id) {
            setState(() => _comId = id);
            widget.onChanged(id);
          },
          onCreate: _munId == null
              ? null
              : (nombre) => _crearGeo('comunidades',
                  {'tenant_id': widget.tenantId, 'municipio_id': _munId}, nombre),
        ),
      ],
    );
  }

  /// Crea una geo (depto/muni/comunidad) reusando la existente si ya hay una
  /// con el mismo nombre (plegando ñ/acentos) en el mismo padre — evita el
  /// duplicado que el server rechazaría por UNIQUE al sync, que dejaría al
  /// cliente con un id huérfano (audit 2026-06-24). Guarda contra tenant sin
  /// resolver (no INSERTAR con tenant_id='').
  Future<String> _crearGeo(
      String tabla, Map<String, String?> cols, String nombre) async {
    if (widget.tenantId.isEmpty) {
      throw Exception('Esperá a que cargue tu cuenta para crear ubicaciones.');
    }
    final whereScope = cols.keys.map((c) => '$c = ?').join(' AND ');
    final dup = await ps.db.getOptional(
      'SELECT id FROM $tabla WHERE $whereScope AND ${foldSqlExpr('nombre')} = ?',
      [...cols.values, foldBusqueda(nombre)],
    );
    if (dup != null) return dup['id'] as String;
    final id = const Uuid().v4();
    final colNames = ['id', ...cols.keys, 'nombre', 'created_at'].join(', ');
    final ph = List.filled(cols.length + 3, '?').join(', ');
    // Write local-first + op_log DENTRO de la tx (alta de la entidad geo), igual
    // que geografia_admin_screen — sin esto la geo creada inline no aparecía en
    // su historial (audit 2026-07-04).
    final ocurridoEn = DateTime.now().toUtc();
    final actor = widget.usuarioId != null
        ? await OpLog.actorDeUsuario(ps.db, widget.usuarioId!)
        : const OpLogActor.systemAdmin();
    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO $tabla ($colNames) VALUES ($ph)',
        [id, ...cols.values, nombre, DateTime.now().toIso8601String()],
      );
      final despues =
          (await tx.getAll('SELECT * FROM $tabla WHERE id = ?', [id])).first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: widget.tenantId, opId: OpLog.nuevoOpId(), entidad: tabla,
          entidadId: id, antes: const {}, despues: despues, actor: actor,
          ocurridoEn: ocurridoEn);
    });
    return id;
  }
}

class _Selector extends StatefulWidget {
  const _Selector({
    required this.label,
    required this.valueId,
    required this.stream,
    required this.onChanged,
    this.onCreate,
    this.enabled = true,
  });

  final String label;
  final String? valueId;
  final Stream<List<Map<String, dynamic>>> stream;
  final ValueChanged<String?> onChanged;
  final Future<String> Function(String nombre)? onCreate;
  final bool enabled;

  @override
  State<_Selector> createState() => _SelectorState();
}

class _SelectorState extends State<_Selector> {
  final _ctrl = TextEditingController();

  /// Espejo de las filas que emite el stream (depto/muni/comunidad del padre).
  /// Lo mantenemos para: resolver el NOMBRE del `valueId` (mostrarlo en el
  /// TextField) y verificar que el `valueId` sigue existiendo (si no, reset).
  List<Map<String, dynamic>> _rows = const [];
  Object? _error;
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  @override
  void initState() {
    super.initState();
    _suscribir();
  }

  @override
  void didUpdateWidget(covariant _Selector old) {
    super.didUpdateWidget(old);
    // El padre recrea el stream al cambiar la cascada → re-suscribir.
    if (!identical(old.stream, widget.stream)) {
      _suscribir();
    } else if (old.valueId != widget.valueId) {
      _sincronizarTexto();
    }
  }

  void _suscribir() {
    _sub?.cancel();
    _rows = const [];
    _error = null;
    _sub = widget.stream.listen(
      (rows) {
        if (!mounted) return;
        setState(() {
          _rows = rows;
          _error = null;
        });
        _sincronizarTexto();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = e);
      },
    );
    _sincronizarTexto();
  }

  /// Mantiene el TextField mostrando el nombre del `valueId` actual. Si el id
  /// ya no existe en las filas (p.ej. cambió el padre), limpia el texto.
  void _sincronizarTexto() {
    final id = widget.valueId;
    if (id == null) {
      if (_ctrl.text.isNotEmpty) _ctrl.text = '';
      return;
    }
    final match = _rows.where((r) => r['id'] == id).toList();
    final nombre = match.isEmpty ? '' : (match.first['nombre'] as String);
    if (_ctrl.text != nombre) _ctrl.text = nombre;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// Sentinel para la opción "— Ninguno": el `valor` del [OpcionSelector] NO
  /// puede ser null, porque [elegirConBuscador] devuelve null AL CANCELAR. Si
  /// "Ninguno" fuese null no podríamos distinguir "limpié el campo" de "cerré
  /// el diálogo sin elegir". Con el sentinel sí: null = cancelar (no commitea),
  /// `_kNinguno` = limpiar el campo (commitea null al padre → resetea cascada).
  static const String _kNinguno = ' __ninguno__';

  Future<void> _elegir() async {
    if (!widget.enabled) return;
    if (_rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('No hay ${widget.label.toLowerCase()}s todavía.')),
      );
      return;
    }
    final elegido = await elegirConBuscador<String>(
      context,
      titulo: widget.label,
      hint: 'Buscar...',
      opciones: [
        const OpcionSelector<String>(valor: _kNinguno, nombre: '— Ninguno'),
        for (final r in _rows)
          OpcionSelector<String>(
            valor: r['id'] as String,
            nombre: r['nombre'] as String,
          ),
      ],
    );
    if (!mounted) return;
    if (elegido == null) return; // diálogo cancelado → sin cambios
    if (elegido == _kNinguno) {
      _commit(null, '');
    } else {
      final r = _rows.firstWhere((r) => r['id'] == elegido);
      _commit(elegido, r['nombre'] as String);
    }
  }

  /// Aplica la selección: actualiza el texto visible y notifica al padre.
  /// `nombre` se pasa explícito porque al CREAR inline el id todavía no está en
  /// `_rows` (el stream aún no emitió la fila nueva) → no se puede resolver.
  void _commit(String? id, String nombre) {
    setState(() => _ctrl.text = nombre);
    widget.onChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(mensajeErrorHumano(_error!)));
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            readOnly: true,
            enabled: widget.enabled,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: 'Toca para elegir',
              suffixIcon: const Icon(Icons.arrow_drop_down),
            ),
            onTap: widget.enabled ? _elegir : null,
          ),
        ),
        if (widget.onCreate != null && widget.enabled) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Agregar ${widget.label}',
            onPressed: _crear,
          ),
        ],
      ],
    );
  }

  Future<void> _crear() async {
    final nombre = await showDialog<String?>(
      context: context,
      builder: (_) => _CrearDialog(label: widget.label),
    );
    if (nombre == null || nombre.trim().isEmpty) return;
    if (!mounted) return;
    final limpio = nombre.trim();
    try {
      final id = await widget.onCreate!(limpio);
      if (!mounted) return;
      // El id recién creado aún no está en `_rows` (el stream no emitió):
      // pasamos el nombre tipeado para mostrarlo de inmediato.
      _commit(id, limpio);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    }
  }
}

class _CrearDialog extends StatefulWidget {
  const _CrearDialog({required this.label});
  final String label;

  @override
  State<_CrearDialog> createState() => _CrearDialogState();
}

class _CrearDialogState extends State<_CrearDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Nueva ${widget.label.toLowerCase()}'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Agregar'),
        ),
      ],
    );
  }
}
