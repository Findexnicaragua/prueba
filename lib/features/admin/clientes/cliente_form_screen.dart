import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/utils/busqueda_cliente.dart' show foldBusqueda, foldSqlExpr;
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/mapa_picker_screen.dart';
import '../../shared/widgets/phone_text_field.dart';
import '../../shared/widgets/selector_buscable.dart';
import '../inventario/equipos_en_baja.dart';
import 'widgets/geo_picker.dart';
import 'widgets/red_picker.dart';

class ClienteFormScreen extends ConsumerStatefulWidget {
  const ClienteFormScreen({super.key, this.clienteId});
  final String? clienteId;

  @override
  ConsumerState<ClienteFormScreen> createState() => _ClienteFormScreenState();
}

class _ClienteFormScreenState extends ConsumerState<ClienteFormScreen> {
  final _formKey = GlobalKey<FormState>();
  // Tracking de "form sucio" — true cuando el user tocó algún campo
  // tras la última cargada/guardado. Usado por PopScope para mostrar
  // dialog de confirmación al intentar salir con cambios sin guardar.
  bool _dirty = false;
  final _codigo = TextEditingController();
  final _nombre = TextEditingController();
  final _cedula = TextEditingController();
  final _telefono = TextEditingController();
  final _email = TextEditingController();
  final _direccion = TextEditingController();
  final _referencia = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _notas = TextEditingController();
  // ¿El usuario tocó la nota en ESTA sesión del form? La nota tiene un segundo
  // editor (la ficha del cliente), así que reenviarla siempre pisaría lo que
  // haya escrito otro mientras este form estaba abierto.
  bool _notasTocadas = false;

  String? _comunidadId;
  String? _puertoId;
  String? _cobradorId;
  bool _activo = true;
  bool _activoOriginal = true; // para detectar la transición activo→inactivo

  /// ¿Puede cambiar el estado activo/inactivo del cliente, en AMBAS direcciones?
  ///
  /// `admin` y `admin_usuarios`. El de usuarios lo tuvo por etapas:
  ///   · antes: solo podía SOLICITAR la baja, y no tenía forma de reactivar
  ///     (la sección desaparecía con el cliente ya inactivo — bug de campo).
  ///   · 2026-07-29: reactivar pasó a directo.
  ///   · confirmado por Rubén el mismo día: **desactivar también es directo**,
  ///     sin autorización del admin. Se quitó el botón de solicitar la baja.
  ///
  /// Que sea directo NO saltea la regla de negocio: el guardado bloquea
  /// desactivar un cliente con contratos ACTIVOS (hay que suspender/cancelar
  /// primero, que es lo que frena las cuotas) — mismo guard que aplicaba la
  /// ruta de aprobación, y vive en el form, no en la cola.
  ///
  /// `TipoSolicitud.desactivarCliente` y su ejecución NO se borraron: había 10
  /// solicitudes PENDIENTES en producción al hacer este cambio, y sin la rama
  /// de ejecución quedarían imposibles de resolver.
  bool get _puedeCambiarEstado {
    final c = ref.watch(cobradorActualProvider).valueOrNull;
    return c?.rol == 'admin' || (c?.esAdminUsuarios ?? false);
  }

  // La nota interna la edita CUALQUIER rol que llegue a este formulario
  // (decisión de Rubén 2026-08-09; la primera versión la limitaba a `admin` y
  // se abrió el mismo día). No hace falta gate: `lectura` no llega acá — el
  // router lo rebota (`router_redirect_test`), y la guardia de solo-lectura de
  // la DB frena cualquier escritura suya igual.

  bool _cargando = true;
  bool _noEncontrado = false;
  bool _guardando = false;
  String? _error;
  // Foto legacy del cliente (campo viejo). Se preserva al guardar pero
  // ya no se setea desde el form — las fotos múltiples viven en
  // FotoGalleryWidget en la pantalla de detalle del cliente.
  String? _fotoPath;

  // Código de cliente: chequeo de duplicado en vivo + bloqueo de inmutabilidad.
  String? _codigoDupNombre; // nombre del cliente que ya usa ese código (o null)
  bool _codigoYaAsignado = false; // true = el cliente ya tiene código guardado
  Timer? _dupDebounce; // debounce del chequeo de duplicado en vivo

  // Cédula: aviso EN VIVO de "ya está en uso", NO bloqueante (decisión Rubén
  // 2026-08-08). No se bloquea porque en Nicaragua es normal registrar a varios
  // clientes con la cédula de un familiar: de los grupos duplicados que hay hoy
  // en producción, 49 son personas DISTINTAS legítimas. Pero 60 grupos SÍ son la
  // MISMA persona cargada dos veces (la oficina llegó a crear 131 clientes con
  // sufijo "#2"/"#3" como parche) → por eso el aviso ofrece ABRIR la ficha del
  // que ya existe: viéndola, le agregan el contrato ahí en vez de duplicar.
  String? _cedulaDupId; // id del cliente que ya usa esa cédula (para su ficha)
  String? _cedulaDupNombre;
  String? _cedulaDupCodigo;
  int _cedulaDupOtros = 0; // cuántos MÁS la usan, además del que se muestra
  Timer? _cedulaDebounce;
  // Notifier capturado en initState para resetear el form-dirty en dispose
  // SIN usar `ref` (ref NO es válido en dispose → "Cannot use ref after the
  // widget was disposed"). El StateController vive en el container, sobrevive
  // al widget, así que escribirlo en dispose es seguro.
  late final StateController<bool> _formDirtyCtrl;

  @override
  void initState() {
    super.initState();
    _formDirtyCtrl = ref.read(formDirtyProvider.notifier);
    _cargar();
  }

  Future<void> _cargar() async {
    if (widget.clienteId == null) {
      setState(() => _cargando = false);
      return;
    }
    final rows = await ps.db
        .getAll('SELECT * FROM clientes WHERE id = ?', [widget.clienteId]);
    // C7: el await pudo resolver con el form ya desmontado (back rápido) —
    // setState sobre un State muerto tira en debug.
    if (!mounted) return;
    if (rows.isEmpty) {
      // El cliente no está en el SQLite local (deep-link viejo, fila aún no
      // sincronizada o borrada): mostramos "no encontrado" en vez de un form
      // vacío editable que parece un alta (fix audit 2026-06-26).
      setState(() {
        _cargando = false;
        _noEncontrado = true;
      });
      return;
    }
    final r = rows.first;
    _nombre.text = r['nombre'] as String? ?? '';
    _cedula.text = r['cedula'] as String? ?? '';
    _telefono.text = r['telefono'] as String? ?? '';
    _email.text = r['email'] as String? ?? '';
    _direccion.text = r['direccion'] as String? ?? '';
    _referencia.text = r['direccion_referencia'] as String? ?? '';
    _lat.text = r['latitud']?.toString() ?? '';
    _lng.text = r['longitud']?.toString() ?? '';
    // Se hidrata SIEMPRE, aunque el rol no pueda editarla: el guardado reenvía
    // este valor y esconder la carga la borraría en silencio al guardar
    // cualquier otro campo. El gate vive en el widget, nunca acá.
    _notas.text = r['notas'] as String? ?? '';
    _comunidadId = r['comunidad_id'] as String?;
    _puertoId = r['puerto_id'] as String?;
    _cobradorId = r['cobrador_id'] as String?;
    _activo = (r['activo'] as int? ?? 1) == 1;
    _activoOriginal = _activo;
    _fotoPath = r['foto_path'] as String?;
    _codigo.text = r['codigo'] as String? ?? '';
    // Si ya tiene código asignado queda read-only para admin/cobrador; el
    // super_admin sí puede corregirlo (se evalúa en build con el rol actual).
    _codigoYaAsignado = _codigo.text.trim().isNotEmpty;
    setState(() => _cargando = false);
  }

  String? _clienteIdAsignado;

  @override
  void dispose() {
    // Reset defensivo del form_dirty_provider: el shell que watchea
    // este provider no debe ver dirty=true tras desmontar el form,
    // sino el próximo sidebar tap mostraría un dialog huérfano.
    // Usamos el notifier CAPTURADO en initState, NO `ref` (ref no es válido
    // en dispose: lanza "Cannot use ref after the widget was disposed").
    _formDirtyCtrl.state = false;
    _dupDebounce?.cancel();
    _cedulaDebounce?.cancel();
    _codigo.dispose();
    _nombre.dispose();
    _cedula.dispose();
    _telefono.dispose();
    _email.dispose();
    _direccion.dispose();
    _referencia.dispose();
    _lat.dispose();
    _lng.dispose();
    _notas.dispose();
    super.dispose();
  }

  /// Chequea (contra el SQLite local) si ya existe OTRO cliente del tenant con
  /// el mismo código (case-insensitive). Setea `_codigoDupNombre` con el nombre
  /// del cliente en conflicto, o null si está libre. El admin baja todos los
  /// clientes del tenant → el chequeo es confiable para él; el UNIQUE de
  /// Postgres es la garantía dura (el cobrador tiene vista parcial).
  Future<void> _verificarCodigoDuplicado() async {
    final codigo = _codigo.text.trim();
    if (codigo.isEmpty) {
      if (_codigoDupNombre != null) setState(() => _codigoDupNombre = null);
      return;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    try {
      // SQLite upper() es ASCII-only → no detecta un duplicado de código con ñ
      // (ni distingue 'PENA'/'PEÑA'). El fold canónico (ñ/acentos→ASCII) sí lo
      // detecta, y de paso evita códigos confundibles que difieren solo en acento.
      final rows = await ps.db.getAll(
        'SELECT nombre FROM clientes '
        'WHERE tenant_id = ? AND ${foldSqlExpr('codigo')} = ? AND id != ? LIMIT 1',
        [tenantId, foldBusqueda(codigo), widget.clienteId ?? ''],
      );
      if (!mounted) return;
      final nombre = rows.isEmpty ? null : rows.first['nombre'] as String?;
      if (nombre != _codigoDupNombre) setState(() => _codigoDupNombre = nombre);
    } catch (_) {
      // Best-effort: si la query local falla no bloqueamos el form (el UNIQUE
      // de Postgres es la garantía dura igual).
    }
  }

  /// Forma COMPARABLE de una cédula: plegada a ASCII (ñ/acentos/minúsculas —
  /// regla #1d: `lower()` de SQLite es ASCII-only) y sin separadores. Así
  /// '001-010190-0001A' y '0010101900001a' se reconocen como la MISMA cédula,
  /// que es como la oficina las tipea (a veces con guiones, a veces sin).
  /// Espeja a [_cedulaSqlComparable] para que Dart y SQL comparen lo mismo.
  static String _cedulaComparable(String s) =>
      foldBusqueda(s).replaceAll(RegExp(r'[\s./\-_]'), '');

  /// Versión SQL (SQLite) de [_cedulaComparable]: `foldSqlExpr` + `replace()`
  /// encadenado para los separadores. `col` es un literal controlado.
  static String _cedulaSqlComparable(String col) {
    var e = foldSqlExpr(col);
    for (final sep in const ['-', '.', ' ', '/', '_']) {
      e = "replace($e,'$sep','')";
    }
    return e;
  }

  /// Normaliza la cédula para GUARDAR: devuelve `null` (columna NULL, no cadena
  /// vacía — igual que el resto de los campos opcionales del form) cuando el
  /// valor es un COMODÍN en vez de un documento real.
  ///
  /// Por qué: cuando el cliente no traía cédula, la oficina fue escribiendo '0',
  /// 'N/A', '-'… y quedaron **861 clientes con cedula = '0'** en producción. Eso
  /// ensucia todo lo que cuelga del campo: la búsqueda por cédula (tipear "0"
  /// traía media cartera), este mismo aviso de "ya está en uso" (861 falsos
  /// positivos) y el recibo, que lo imprime como si fuera un documento válido.
  /// Guardar NULL es la forma honesta de decir "no tenemos la cédula".
  static String? _cedulaNormalizada(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final c = _cedulaComparable(t);
    if (c.isEmpty) return null; // solo separadores/espacios: '-', '- -', '   '
    if (RegExp(r'^0+$').hasMatch(c)) return null; // '0', '00', '000'
    // Placeholders escritos a mano. Se comparan ya compactados, así que 'N/A',
    // 'n.a.' y 'NA' caen todos acá.
    // 'notiene' cubre el "No Tiene" / "NO TIENE" que apareció medido en
    // producción: la migración 0223 lo limpia del pasado y este set evita que
    // la app lo vuelva a escribir (server y cliente tienen que definir "comodín"
    // igual, si no la limpieza se deshace con el próximo guardado).
    const comodines = {
      'na', 'nd', 'sn', 'sincedula', 'sinced', 'ninguna', 'ninguno', 'notiene',
    };
    if (comodines.contains(c)) return null;
    return t;
  }

  /// Busca en la réplica local OTRO cliente del tenant con la MISMA cédula y
  /// carga los datos del aviso (nombre, código, id para abrir su ficha, y cuántos
  /// más la comparten). NO bloquea nada: es informativo.
  ///
  /// Los comodines quedan fuera solos: [_cedulaNormalizada] los manda a null y
  /// ahí ni se consulta, así que los 861 clientes con cedula '0' no disparan el
  /// aviso. Alcance: lo que esté sincronizado localmente (el admin baja todo el
  /// tenant → para él es confiable).
  Future<void> _verificarCedulaDuplicada() async {
    final cedula = _cedulaNormalizada(_cedula.text);
    if (cedula == null) {
      if (_cedulaDupNombre != null) _limpiarAvisoCedula();
      return;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    try {
      final where = 'tenant_id = ? AND ${_cedulaSqlComparable('cedula')} = ? '
          "AND id != ? AND coalesce(cedula,'') != ''";
      final params = [
        tenantId,
        _cedulaComparable(cedula),
        widget.clienteId ?? '',
      ];
      // Uno para mostrar + el total, para poder decir "y N más" sin traer la
      // lista entera (una cédula familiar puede repetirse en varios hijos).
      final rows = await ps.db.getAll(
        'SELECT id, nombre, codigo FROM clientes WHERE $where '
        'ORDER BY nombre LIMIT 1',
        params,
      );
      if (!mounted) return;
      if (rows.isEmpty) {
        if (_cedulaDupNombre != null) _limpiarAvisoCedula();
        return;
      }
      final total = await ps.db
          .getAll('SELECT COUNT(*) AS n FROM clientes WHERE $where', params);
      if (!mounted) return;
      final n = (total.first['n'] as int?) ?? 1;
      final r = rows.first;
      setState(() {
        _cedulaDupId = r['id'] as String?;
        _cedulaDupNombre = r['nombre'] as String?;
        _cedulaDupCodigo = r['codigo'] as String?;
        _cedulaDupOtros = n - 1 < 0 ? 0 : n - 1;
      });
    } catch (_) {
      // Best-effort: es un aviso, no un guard. Si la query local falla, el form
      // sigue funcionando igual.
    }
  }

  void _limpiarAvisoCedula() {
    setState(() {
      _cedulaDupId = null;
      _cedulaDupNombre = null;
      _cedulaDupCodigo = null;
      _cedulaDupOtros = 0;
    });
  }

  /// Abre la ficha del cliente que ya usa esa cédula. Es lo más valioso del
  /// aviso: si es la MISMA persona, se le agrega el contrato ahí en vez de
  /// crear el duplicado con sufijo "#2".
  ///
  /// `push` (no `go`): el form queda VIVO abajo en la pila, así el usuario mira
  /// la ficha, vuelve y sigue con lo que ya tenía tipeado. Es ruta de detalle
  /// bajo `clientes/`, la excepción que la regla #12 de AGENTS permite pushear.
  void _abrirFichaDeLaCedula(BuildContext context) {
    final id = _cedulaDupId;
    if (id == null) return;
    final enAdminShell = GoRouterState.of(context).uri.path.startsWith('/admin');
    context.push(enAdminShell ? '/admin/clientes/$id' : '/clientes/$id');
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    // Capturamos los ancestros ANTES de los await. Tras el INSERT/UPDATE,
    // PowerSync notifica a los watchers y el árbol se reconstruye: el elemento
    // del form puede quedar desactivado (mounted sigue true pero el lookup de
    // ancestro ya NO es seguro) → buscar ScaffoldMessenger/GoRouter por context
    // ahí lanza "Looking up a deactivated widget's ancestor is unsafe".
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() => _error = 'No se pudo determinar el tenant');
      return;
    }
    // Doble-submit (fix audit #7): _guardando ANTES del primer await — con
    // el botón habilitado durante los guards async, un doble-click creaba
    // DOS clientes locales con el mismo código (el UNIQUE server rechazaba
    // el 2º recién al sync). Los early-returns de abajo lo revierten.
    setState(() {
      _guardando = true;
      _error = null;
    });

    // Guard de código duplicado (hard stop con mensaje claro; el UNIQUE de la
    // DB es la red final). El super_admin puede corregir un código asignado,
    // así que para él el campo es editable y también se chequea.
    final esSuper =
        ref.read(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;
    if (!codigoBloqueado) {
      await _verificarCodigoDuplicado();
      if (!mounted) return;
      if (_codigoDupNombre != null) {
        setState(() {
          _guardando = false;
          _error =
              'Ya existe un cliente con el código "${_codigo.text.trim()}": '
              '$_codigoDupNombre';
        });
        return;
      }
    }

    // Titular F1 (deuda fantasma): "desactivar cliente" es ORGANIZATIVO (ocultar),
    // NO frena la facturación — la generación de cuotas gatea por contrato.estado,
    // nunca por cliente.activo. Para no dejar deuda invisible acumulándose, se
    // BLOQUEA desactivar un cliente que aún tiene contratos activos: primero hay
    // que suspender/cancelar el contrato (eso sí detiene las cuotas y snapshotea
    // la deuda). Semántica C aprobada por Rubén 2026-07-09.
    if (widget.clienteId != null && _activoOriginal && !_activo) {
      final rows = await ps.db.getAll(
        'SELECT COUNT(*) AS n FROM contratos '
        "WHERE cliente_id = ? AND estado = 'activo'",
        [widget.clienteId],
      );
      final n = (rows.first['n'] as int?) ?? 0;
      if (n > 0) {
        if (!mounted) return;
        setState(() {
          _guardando = false;
          _error = 'No podés desactivar un cliente con $n contrato(s) activo(s). '
              'Suspendé o cancelá el contrato primero (eso frena las cuotas y '
              'registra la deuda). Desactivar solo lo oculta, no deja de facturar.';
        });
        return;
      }
    }

    // ESPEJO DEL GUARD DEL SERVER (0220), que chequea OTRA COSA que el de
    // arriba: el server bloquea por DEUDA, la app bloqueaba por CONTRATOS
    // ACTIVOS. Un cliente con el contrato ya suspendido o cancelado y cuotas
    // impagas caía justo en el hueco: la app lo dejaba pasar, el server
    // rechazaba el UPDATE entero y el usuario perdía TODO lo que había editado
    // en ese guardado —teléfono, dirección, ubicación— sin entender por qué.
    // Encima el historial registraba un cambio que el server nunca aceptó.
    // Medido al detectarlo: 5 clientes, C$4.925,24.
    //
    // El alcance de "deuda" es el del server, a propósito: NO filtra por estado
    // del contrato. La deuda de un contrato cancelado sigue siendo deuda.
    if (widget.clienteId != null && _activoOriginal && !_activo) {
      final rows = await ps.db.getAll(
        'SELECT COUNT(*) AS n, '
        '       SUM(monto + COALESCE(cargos_neto, 0) - COALESCE(monto_pagado, 0)) AS deuda '
        '  FROM cuotas '
        " WHERE cliente_id = ? AND estado IN ('pendiente', 'parcial') "
        '   AND (monto + COALESCE(cargos_neto, 0) - COALESCE(monto_pagado, 0)) > 0.01',
        [widget.clienteId],
      );
      final n = (rows.first['n'] as int?) ?? 0;
      if (n > 0) {
        final deuda = (rows.first['deuda'] as num?)?.toDouble() ?? 0;
        if (!mounted) return;
        setState(() {
          _guardando = false;
          _error = 'Este cliente debe ${Fmt.cordobas(deuda)} en $n cuota(s). '
              'Mientras tenga deuda no se puede desactivar: se le seguiría '
              'debiendo cobrar y quedaría escondido de las listas y del mapa. '
              'Cobrale o resolvé la deuda primero.';
        });
        return;
      }
    }

    // P3b (2026-06-17): se permite desasignar el cobrador aunque el cliente
    // tenga contratos activos. Sus cuotas quedan sin cobrador → solo
    // admin/admin_cobranza las ven y cobran hasta reasignar. Antes había un
    // guard acá (espejo del trigger 0058, ya removido en la migración 0121).

    // Aviso de puerto ocupado (soft, FORZABLE — decisión Rubén 2026-07-04): si
    // el puerto ya lo tiene OTRO cliente ACTIVO, avisamos con su nombre y
    // dejamos guardar igual si el admin confirma (mudanzas/splitters no
    // modelados). Sin constraint dura; un cliente inactivo libera la boca.
    if (_puertoId != null) {
      String? ocupadoPor;
      try {
        final rows = await ps.db.getAll(
          'SELECT nombre FROM clientes WHERE puerto_id = ? AND id != ? '
          'AND activo = 1 LIMIT 1',
          [_puertoId, widget.clienteId ?? ''],
        );
        ocupadoPor = rows.isEmpty ? null : rows.first['nombre'] as String?;
      } catch (_) {/* best-effort: si falla la query local no bloqueamos */}
      if (!mounted) return;
      if (ocupadoPor != null) {
        final forzar = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Puerto ya ocupado'),
            content: Text('Ese puerto ya está asignado a "$ocupadoPor". '
                '¿Asignarlo igual a este cliente?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Asignar igual')),
            ],
          ),
        );
        if (forzar != true) {
          if (mounted) setState(() => _guardando = false);
          return;
        }
      }
    }

    try {
      final now = DateTime.now().toIso8601String();
      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      final lat = double.tryParse(_lat.text);
      final lng = double.tryParse(_lng.text);
      // Cédula: los comodines ('0', 'N/A', '-'…) se guardan como NULL — ver el
      // porqué en [_cedulaNormalizada].
      final cedula = _cedulaNormalizada(_cedula.text);

      // op_log (rework change log): actor + id de intención para registrar el
      // alta/edición del cliente (1 entrada, diff antes→después curado).
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      if (widget.clienteId == null) {
        // Si ya subimos foto antes de guardar, reusamos el id para que
        // el path remoto y el id en BD coincidan.
        final id = _clienteIdAsignado ?? const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            '''
            INSERT INTO clientes (
              id, tenant_id, cobrador_id, comunidad_id, puerto_id, codigo, nombre,
              cedula, telefono, email, direccion, direccion_referencia, latitud, longitud,
              foto_path, notas, activo, created_at, updated_at, ocurrido_en
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              id, tenantId, _cobradorId, _comunidadId, _puertoId,
              _codigo.text.trim().isEmpty ? null : _codigo.text.trim().toUpperCase(),
              _nombre.text.trim(),
              cedula,
              PhoneTextField.sanitized(_telefono),
              _email.text.trim().isEmpty ? null : _email.text.trim(),
              _direccion.text.trim().isEmpty ? null : _direccion.text.trim(),
              _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
              lat, lng,
              _fotoPath,
              // En el ALTA no hace falta gatear: al no-admin ni le mostramos el
              // campo, así que el controller viene vacío → NULL.
              _notas.text.trim().isEmpty ? null : _notas.text.trim(),
              _activo ? 1 : 0, now, now, ocurridoEn,
            ],
          );
          final despues =
              (await tx.getAll('SELECT * FROM clientes WHERE id = ?', [id])).first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'clientes', entidadId: id,
              antes: const {}, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurridoEn));
        });
      } else {
        final id = widget.clienteId!;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows =
              await tx.getAll('SELECT * FROM clientes WHERE id = ?', [id]);
          final antes = antesRows.isNotEmpty
              ? antesRows.first
              : const <String, dynamic>{};
          await tx.execute(
            '''
            UPDATE clientes
               SET cobrador_id = ?, comunidad_id = ?, puerto_id = ?, codigo = ?,
                   nombre = ?, cedula = ?, telefono = ?, email = ?, direccion = ?,
                   direccion_referencia = ?, latitud = ?, longitud = ?,
                   foto_path = ?, notas = ?, activo = ?, updated_at = ?,
                   ocurrido_en = ?
             WHERE id = ?
            ''',
            [
              _cobradorId, _comunidadId, _puertoId,
              // Código inmutable (fix F1): si el campo está bloqueado, reenviar el
              // valor GUARDADO tal cual — NO re-mayusculizar el texto. Si no, un
              // código guardado en minúsculas se volvía "ABC" ≠ "abc" y el trigger
              // 0071 (NEW.codigo != OLD.codigo) rechazaba TODA edición del cliente.
              codigoBloqueado
                  ? antes['codigo']
                  : (_codigo.text.trim().isEmpty
                      ? null
                      : _codigo.text.trim().toUpperCase()),
              _nombre.text.trim(),
              cedula,
              PhoneTextField.sanitized(_telefono),
              _email.text.trim().isEmpty ? null : _email.text.trim(),
              _direccion.text.trim().isEmpty ? null : _direccion.text.trim(),
              _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
              lat, lng,
              _fotoPath,
              // Solo se escribe si el usuario TOCÓ el campo. Desde que la nota
              // también se edita desde la ficha del cliente hay dos escritores,
              // y este form es last-write-wins ciego: hidrata al abrir y
              // reenvía al guardar. Sin este guard, un admin con el form
              // abierto le borraba en silencio la nota que el cobrador acababa
              // de escribir en la puerta de la casa — justo el escenario que la
              // feature venía a habilitar.
              _notasTocadas
                  ? (_notas.text.trim().isEmpty ? null : _notas.text.trim())
                  : antes['notas'],
              _activo ? 1 : 0, now, ocurridoEn,
              id,
            ],
          );
          final despues =
              (await tx.getAll('SELECT * FROM clientes WHERE id = ?', [id])).first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'clientes', entidadId: id,
              antes: antes, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurridoEn));
        });
      }
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(widget.clienteId == null
              ? 'Cliente creado'
              : 'Cambios guardados')),
        );
        // Reseteamos _dirty PRE-pop para que el PopScope no intercepte
        // con el dialog "¿Descartar cambios?" — recién guardamos, no
        // hay cambios sin persistir. Sin esto, el guardado dispara la
        // confirmación que el user esperaría solo en cancelación.
        _dirty = false;
        // Si se DESACTIVÓ el cliente (transición activo→inactivo), ofrecer
        // gestionar sus equipos instalados antes de salir (audit de lifecycle).
        // El cliente YA se guardó: si el sheet falla (context desactivable tras
        // el rebuild de PowerSync — pasa context crudo, riesgo residual de
        // "ancestor unsafe"), NO bloqueamos la navegación; los equipos se
        // gestionan luego desde el detalle. Fix completo (context estable) en
        // backlog.
        if (widget.clienteId != null && _activoOriginal && !_activo) {
          try {
            await ofrecerGestionEquiposEnBaja(context, ref,
                clienteId: widget.clienteId!, entidad: 'cliente');
          } catch (_) {/* no bloquea el cierre del form */}
        }
        if (!mounted) return;
        // Navegamos con el router CAPTURADO (no por context, ya desactivable
        // tras el await). pop si vinimos vía push (caso normal); fallback go al
        // listado si fue deep-link directo a la edición.
        if (router.canPop()) {
          router.pop();
        } else {
          router.go('/admin/clientes');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = mensajeErrorHumano(e, contexto: 'guardar el cliente'));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _abrirMapaPicker() async {
    final inicial = (double.tryParse(_lat.text) != null &&
            double.tryParse(_lng.text) != null)
        ? LatLng(double.parse(_lat.text), double.parse(_lng.text))
        : const LatLng(12.13, -86.25); // Managua como centro default
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => MapaPickerScreen(inicial: inicial)),
    );
    if (picked != null && mounted) {
      setState(() {
        _lat.text = picked.latitude.toStringAsFixed(6);
        _lng.text = picked.longitude.toStringAsFixed(6);
        // controller.text = ... asignación programática NO dispara
        // Form.onChanged (solo onSubmitted/onChanged del field). Marcar
        // dirty a mano para que PopScope intercepte el discard.
        _dirty = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync el dirty state al provider global para que el sidebar del
    // shell pueda mostrar "¿Descartar cambios?" si el user toca un
    // item de menú con cambios sin guardar (PopScope solo cubre pops,
    // no `context.go` del go_router).
    //
    // Condicional para no schedular un postFrameCallback en cada
    // keystroke cuando _dirty ya está en true. Post-frame porque
    // setear el state notifica listeners; durante build no se permite.
    if (ref.read(formDirtyProvider) != _dirty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(formDirtyProvider.notifier).state = _dirty;
        }
      });
    }

    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_noEncontrado) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off_outlined,
                size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            const Text('Cliente no encontrado'),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.pop(),
              child: const Text('Volver'),
            ),
          ],
        ),
      );
    }

    // El código es inmutable una vez asignado para admin/cobrador; el
    // super_admin sí puede corregirlo (P1 del audit del feature).
    final esSuper =
        ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await confirmDiscardChanges(context);
        if (confirm != true || !context.mounted) return;
        // Mismo patrón fallback que `_guardar()`: si vinimos por push
        // (canPop=true), Navigator.pop. Si fue deep-link directo
        // (canPop=false), `Navigator.pop` no haría nada y el user
        // quedaría atrapado con _dirty=false. Hacemos go al listado.
        if (context.canPop()) {
          Navigator.pop(context);
        } else {
          context.go('/admin/clientes');
        }
      },
      child: Form(
        key: _formKey,
        onChanged: () {
          // Cualquier change en cualquier TextFormField del árbol del
          // Form dispara esto. Lo usamos para flagear dirty sin tener
          // que addListener manual a cada controller.
          if (!_dirty) setState(() => _dirty = true);
        },
        child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // ── Datos personales ──────────────────────────────────────────
          _Section(
            titulo: 'Datos personales',
            children: [
              TextFormField(
                controller: _codigo,
                enabled: !codigoBloqueado,
                decoration: InputDecoration(
                  labelText: 'Código de cliente *',
                  hintText: 'Ej. CL00027',
                  helperText: codigoBloqueado
                      ? 'Inmutable: no se puede cambiar una vez asignado.'
                      : 'Identificador visible del cliente. No se puede repetir.',
                  errorText: _codigoDupNombre != null
                      ? 'Ya existe un cliente con ese código: $_codigoDupNombre'
                      : null,
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  // Alfanumérico ESPAÑOL: incluye ñ y vocales con tilde (el
                  // filtro corre ANTES del toUpperCase, así que va en minúscula
                  // y mayúscula). Sin esto la ñ no se podía tipear en el código.
                  FilteringTextInputFormatter.allow(
                      RegExp(r'[A-Za-z0-9ñÑáéíóúüÁÉÍÓÚÜ\-_]')),
                  TextInputFormatter.withFunction((oldV, newV) =>
                      newV.copyWith(text: newV.text.toUpperCase())),
                  LengthLimitingTextInputFormatter(30),
                ],
                validator: (v) {
                  if (codigoBloqueado) return null;
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return 'El código es obligatorio';
                  if (_codigoDupNombre != null) {
                    return 'Ya existe un cliente con ese código: $_codigoDupNombre';
                  }
                  return null;
                },
                onChanged: (_) {
                  _dupDebounce?.cancel();
                  _dupDebounce = Timer(const Duration(milliseconds: 350),
                      _verificarCodigoDuplicado);
                },
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nombre,
                decoration: const InputDecoration(labelText: 'Nombre completo *'),
                validator: (v) =>
                    Validators.requiredField(v, label: 'Nombre') ??
                    Validators.minLength(v, 3),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _cedula,
                      // Cédula libre (alfanumérica, sin formato estricto): el
                      // negocio no requiere validarla con precisión. Opcional
                      // (sin validator) — por eso normalizar los comodines a
                      // NULL al guardar es seguro: dejar el campo vacío ya era
                      // un caso válido.
                      decoration: const InputDecoration(labelText: 'Cédula'),
                      // Aviso en vivo de "ya está en uso" (NO bloquea). Con
                      // debounce para no escanear la tabla en cada tecla.
                      onChanged: (_) {
                        _cedulaDebounce?.cancel();
                        _cedulaDebounce = Timer(
                            const Duration(milliseconds: 400),
                            _verificarCedulaDuplicada);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PhoneTextField(controller: _telefono),
                  ),
                ],
              ),
              if (_cedulaDupNombre != null) ...[
                const SizedBox(height: 8),
                _AvisoCedulaEnUso(
                  nombre: _cedulaDupNombre!,
                  codigo: _cedulaDupCodigo,
                  otros: _cedulaDupOtros,
                  onAbrirFicha: () => _abrirFichaDeLaCedula(context),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                // Correo OPCIONAL: si está vacío pasa; si tiene algo, valida
                // el formato (Validators.email no es coercitivo con vacío).
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  hintText: 'opcional',
                ),
                validator: Validators.email,
              ),
            ],
          ),

          // ── Ubicación ─────────────────────────────────────────────────
          _Section(
            titulo: 'Ubicación',
            children: [
              GeoPicker(
                tenantId: ref.read(tenantIdProvider) ?? '',
                comunidadId: _comunidadId,
                usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
                onChanged: (id) => setState(() {
                  _comunidadId = id;
                  _dirty = true;
                }),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _direccion,
                decoration: const InputDecoration(
                  labelText: 'Dirección',
                  hintText: 'Calle, número, sector',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _referencia,
                decoration: const InputDecoration(
                  labelText: 'Referencia',
                  hintText: 'Casa amarilla, frente al molino, etc.',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _lat,
                      decoration: const InputDecoration(labelText: 'Latitud'),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                      ],
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return null;
                        final n = double.tryParse(v!);
                        if (n == null) return 'Número inválido';
                        if (n < -90 || n > 90) return 'Fuera de rango (-90 a 90)';
                        if (n < 10 || n > 15) return 'Nicaragua: entre 10 y 15';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lng,
                      decoration: const InputDecoration(labelText: 'Longitud'),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                      ],
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return null;
                        final n = double.tryParse(v!);
                        if (n == null) return 'Número inválido';
                        if (n < -180 || n > 180) return 'Fuera de rango (-180 a 180)';
                        if (n < -88 || n > -82) return 'Nicaragua: entre -88 y -82';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.map),
                label: const Text('Seleccionar en mapa'),
                onPressed: _abrirMapaPicker,
              ),
            ],
          ),

          // ── Conexión de red ───────────────────────────────────────────
          _Section(
            titulo: 'Conexión de red (opcional)',
            children: [
              RedPicker(
                tenantId: ref.read(tenantIdProvider) ?? '',
                puertoId: _puertoId,
                clienteIdActual: widget.clienteId,
                onChanged: (id) => setState(() {
                  _puertoId = id;
                  _dirty = true;
                }),
              ),
            ],
          ),

          // ── Asignación + Estado ───────────────────────────────────────
          _Section(
            titulo: 'Asignación',
            children: [
              _SelectorCobrador(
                cobradorId: _cobradorId,
                onChanged: (id) => setState(() {
                  _cobradorId = id;
                  _dirty = true;
                }),
              ),
            ],
          ),

          // ── Nota interna ──────────────────────────────────────────────
          // Contexto sobre la PERSONA, no sobre su servicio (eso vive en
          // `contratos.notas`): sobrevive a sus contratos, por eso va acá.
          // La ven y la editan todos los roles: el punto de la nota es que la
          // lea (y la corrija) quien va a la casa del cliente.
          _Section(
            titulo: 'Nota interna',
            children: [
              TextFormField(
                controller: _notas,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Notas del cliente',
                  hintText:
                      'Ej. Atiende la hija después de las 3. El perro está suelto.',
                  helperText:
                      'Uso interno: no aparece en el recibo ni en ningún PDF.',
                  helperMaxLines: 2,
                  prefixIcon: Icon(Icons.sticky_note_2_outlined),
                ),
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => _notasTocadas = true,
              ),
            ],
          ),

          // ── Estado del cliente ────────────────────────────────────────
          // `admin` y `admin_usuarios`, en ambas direcciones y sin aprobación
          // de por medio. Ver `_puedeCambiarEstado` para el porqué y para la
          // regla de negocio que sigue vigente (no se puede desactivar con
          // contratos activos — lo bloquea el guardado).
          if (_puedeCambiarEstado)
            _Section(
              titulo: 'Estado',
              children: [
                SwitchListTile(
                  value: _activo,
                  onChanged: (v) => setState(() {
                    _activo = v;
                    _dirty = true;
                  }),
                  title: Text(_activo ? 'Cliente activo' : 'Cliente inactivo'),
                  subtitle: Text(_activo
                      ? 'El cliente aparece en la lista del cobrador y el mapa.'
                      : 'Se oculta de listas, mapa y cobros. NO frena la '
                          'facturación: para eso, suspendé o cancelá sus contratos.'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              ),
            ),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _guardando
                      ? null
                      : () => context.canPop()
                          ? context.pop()
                          : context.go('/admin/clientes'),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: _guardando
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(_guardando
                      ? 'Guardando...'
                      : (widget.clienteId == null
                          ? 'Crear cliente'
                          : 'Guardar cambios')),
                  onPressed: _guardando ? null : _guardar,
                ),
              ),
            ],
          ),
        ],
        ),
      ),
    );
  }
}

/// Aviso NO bloqueante: la cédula tipeada ya la tiene otro cliente del tenant.
///
/// Deliberadamente NO es un `errorText` del campo: compartir cédula es legítimo
/// (se registra con la del familiar). Lo que sí aporta es el atajo a la ficha del
/// que ya existe, para cortar los duplicados "Fulano #2".
class _AvisoCedulaEnUso extends StatelessWidget {
  const _AvisoCedulaEnUso({
    required this.nombre,
    required this.codigo,
    required this.otros,
    required this.onAbrirFicha,
  });

  final String nombre;
  final String? codigo; // código de cliente (CD0017); puede faltar
  final int otros; // cuántos MÁS comparten la cédula, además de [nombre]
  final VoidCallback onAbrirFicha;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quien =
        (codigo == null || codigo!.trim().isEmpty) ? nombre : '$nombre ($codigo)';
    final masTexto = otros <= 0
        ? '.'
        : (otros == 1 ? ' y 1 cliente más.' : ' y $otros clientes más.');

    return Container(
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Esa cédula ya la usa '),
                    TextSpan(
                      text: quien,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(text: masTexto),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Text(
              'No es un error: es normal registrar con la cédula de un familiar. '
              'Pero si es la MISMA persona, abrí su ficha y agregale ahí el '
              'contrato, en vez de crear otro cliente.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: TextButton.icon(
                onPressed: onAbrirFicha,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Abrir su ficha'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.titulo, required this.children});
  final String titulo;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(titulo,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectorCobrador extends StatefulWidget {
  const _SelectorCobrador({required this.cobradorId, required this.onChanged});
  final String? cobradorId;
  final ValueChanged<String?> onChanged;

  @override
  State<_SelectorCobrador> createState() => _SelectorCobradorState();
}

class _SelectorCobradorState extends State<_SelectorCobrador> {
  // Etiqueta de un cobrador: "nombre (prefijo)" o solo "nombre".
  static String _labelDe(Map<String, dynamic> r) => r['prefijo_recibo'] != null
      ? '${r['nombre']} (${r['prefijo_recibo']})'
      : r['nombre'] as String;

  // Campo-selector read-only (reemplaza al DropdownButton). Su texto muestra
  // el cobrador elegido; null = "— Sin asignar —".
  final _cobradorCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Valor inicial (edición): si el cliente ya tiene un cobrador asignado,
    // hidratamos el campo con su nombre. Sin esto el campo arrancaría vacío al
    // editar un cliente que sí tiene cobrador.
    if (widget.cobradorId != null) _hidratarNombre(widget.cobradorId!);
  }

  Future<void> _hidratarNombre(String id) async {
    final rows = await ps.db.getAll(
      'SELECT id, nombre, prefijo_recibo FROM cobradores WHERE id = ?',
      [id],
    );
    if (!mounted || rows.isEmpty) return;
    setState(() => _cobradorCtrl.text = _labelDe(rows.first));
  }

  @override
  void dispose() {
    _cobradorCtrl.dispose();
    super.dispose();
  }

  Future<void> _elegirCobrador() async {
    final rows = await ps.db.getAll(
      '''
      SELECT id, nombre, prefijo_recibo FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
    if (!mounted) return;
    // El cobrador es OPCIONAL → primera opción "— Sin asignar —" (valor con
    // id null) que limpia la selección.
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Cobrador asignado',
      hint: 'Buscar cobrador...',
      opciones: [
        const OpcionSelector(
          valor: <String, dynamic>{'id': null},
          nombre: '— Sin asignar —',
        ),
        for (final r in rows)
          OpcionSelector(valor: r, nombre: _labelDe(r)),
      ],
    );
    if (elegido == null || !mounted) return;
    final id = elegido['id'] as String?;
    setState(() => _cobradorCtrl.text = id == null ? '' : _labelDe(elegido));
    widget.onChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _cobradorCtrl,
      readOnly: true,
      decoration: const InputDecoration(
        labelText: 'Cobrador asignado',
        hintText: 'Toca para elegir',
        suffixIcon: Icon(Icons.arrow_drop_down),
      ),
      onTap: _elegirCobrador,
    );
  }
}


