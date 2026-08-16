import 'dart:async';
import 'dart:io' show HandshakeException, HttpException, SocketException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../config/theme.dart';
import '../../../data/providers/aprobaciones_provider.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/conexion_real_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/services/imagen_compresion.dart';
import '../../../data/utils/busqueda_cliente.dart' show foldBusqueda, foldSqlExpr;
import '../../../data/models/solicitud_accion.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/solicitud_accion_helper.dart';
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/selector_buscable.dart';
import '../../shared/widgets/selector_fecha_rapido.dart';

enum _Duracion { unAno, dosAnos, indefinido }

/// Resultado de verificar el código de contrato contra la BASE REAL (Supabase),
/// no contra la réplica local. Se distingue "no hay red" de "el server contestó
/// un error": el remedio del usuario es distinto (conectarse vs avisar al
/// administrador) y decirle "sin conexión" ante un error de permisos lo manda a
/// buscar el problema donde no está.
enum _ResultadoChequeo {
  /// El código está libre: ni contrato existente ni solicitud pendiente.
  libre,

  /// El código ya está tomado (contrato o solicitud pendiente).
  ocupado,

  /// La consulta NUNCA llegó al server (DNS/socket/timeout) → no podemos
  /// afirmar que el código sea único. No se guarda.
  sinConexion,

  /// El server RESPONDIÓ, pero con error (RLS, 5xx del gateway, SQL). Tampoco
  /// podemos afirmar unicidad, pero NO es un problema de conexión.
  errorServidor,
}

class _ChequeoCodigo {
  const _ChequeoCodigo(this.resultado, [this.mensaje]);
  final _ResultadoChequeo resultado;
  final String? mensaje;

  bool get libre => resultado == _ResultadoChequeo.libre;
}

class ContratoFormScreen extends ConsumerStatefulWidget {
  // Solo ALTA de contrato. La edición se quitó (M5/M6 del audit): cambiar un
  // contrato existente se hace cancelándolo y creando uno nuevo (B2 terminal),
  // así nunca divergen el contrato y sus cuotas ya generadas.
  const ContratoFormScreen({super.key, this.clienteId});
  final String? clienteId;

  @override
  ConsumerState<ContratoFormScreen> createState() => _ContratoFormScreenState();
}

class _ContratoFormScreenState extends ConsumerState<ContratoFormScreen> {
  final _formKey = GlobalKey<FormState>();
  // Tracking de "form sucio" — flagea cambios para que PopScope muestre
  // confirmación al salir con data sin guardar.
  bool _dirty = false;
  String? _clienteId;
  String? _planId;
  DateTime _fechaInicio = DateTime.now();
  // Día de pago mensual = día de la fecha de instalación (un solo campo). La
  // primera cuota vence el MES SIGUIENTE (facturación vencida); el server
  // (generar_cuotas_contrato) lo deriva de fecha_inicio.
  final _costoCtrl = TextEditingController();
  final _notasCtrl = TextEditingController();
  final _codigoCtrl = TextEditingController();
  // Código de contrato (0077): identificador legible, único por
  // tenant, inmutable una vez asignado (server lo refuerza; solo super lo cambia).
  // Mensaje YA ARMADO del conflicto detectado en vivo (contrato existente o
  // solicitud pendiente), o null si el código está libre en la réplica local.
  String? _codigoDupMensaje;
  final bool _codigoYaAsignado = false;
  Timer? _dupDebounce; // chequeo de código duplicado en vivo (como cliente).

  // Guía del siguiente número (feedback del dueño 2026-08: el personal perdió
  // la secuencia y la inventa; "que el mismo lo guíe: 2401, 2402, 2403"). Se
  // calcula UNA vez al abrir el form desde la réplica local (que en todos los
  // roles que llegan acá trae los contratos del tenant completos).
  String? _ultimoCodigo; // el último número de la serie que ya está usado
  String? _ultimoCodigoCliente; // de quién es ese contrato (si se pudo resolver)
  String? _codigoSugerido; // el siguiente de la serie, o null si no hay patrón
  _Duracion _duracion = _Duracion.unAno;
  final bool _cargando = false;
  bool _guardando = false;
  String? _error;

  // Documento del contrato (opcional al crear). Se sube best-effort tras el
  // INSERT si hay conexión; offline o sin adjuntar, el contrato se crea igual
  // y el doc se puede subir luego desde el detalle. Solo en alta (no edición:
  // ahí el detalle ya tiene su propia sección de documento).
  static const _docBucket = 'contratos-documentos';
  static const _docMaxBytes = 10 * 1024 * 1024; // 10 MB
  // Por encima de esto se avisa "archivo pesado" (sin bloquear).
  static const _docAvisoBytes = 5 * 1024 * 1024;
  Uint8List? _docBytes;
  String? _docExt;
  String? _docNombre;
  // Procesando el documento elegido (compresión de fotos, 0.5-3 s): muestra
  // spinner en el botón y bloquea un segundo picker.
  bool _eligiendoDoc = false;
  // Notifier capturado en initState para resetear el form-dirty en dispose
  // SIN usar `ref` (no es válido en dispose: "Cannot use ref after disposed").
  late final StateController<bool> _formDirtyCtrl;

  @override
  void initState() {
    super.initState();
    _formDirtyCtrl = ref.read(formDirtyProvider.notifier);
    _clienteId = widget.clienteId;
    // Best-effort: la sugerencia es una AYUDA, si falla el form sigue igual.
    unawaited(_cargarSugerenciaCodigo());
  }

  @override
  void dispose() {
    _costoCtrl.dispose();
    _notasCtrl.dispose();
    _dupDebounce?.cancel();
    _codigoCtrl.dispose();
    // Reset defensivo del form_dirty_provider: el shell que watchea
    // este provider no debe ver dirty=true tras desmontar el form.
    // Notifier CAPTURADO en initState (ref no es válido en dispose).
    _formDirtyCtrl.state = false;
    super.dispose();
  }

  DateTime? _fechaFin() {
    switch (_duracion) {
      case _Duracion.unAno:
        return DateTime(_fechaInicio.year + 1, _fechaInicio.month, _fechaInicio.day);
      case _Duracion.dosAnos:
        return DateTime(_fechaInicio.year + 2, _fechaInicio.month, _fechaInicio.day);
      case _Duracion.indefinido:
        return null;
    }
  }

  /// Vencimiento estimado de la primera cuota = mes SIGUIENTE a la
  /// instalación, mismo día (clamp a fin de mes). Solo para mostrar en el
  /// form; el server (generar_cuotas_contrato) lo deriva igual de fecha_inicio.
  DateTime _primerCobroEstimado() {
    final base = DateTime(_fechaInicio.year, _fechaInicio.month + 1, 1);
    final ultimoDia = DateTime(base.year, base.month + 1, 0).day;
    final dia = _fechaInicio.day < ultimoDia ? _fechaInicio.day : ultimoDia;
    return DateTime(base.year, base.month, dia);
  }

  /// Abre el file picker para el documento del contrato (PDF/Word/foto).
  /// Solo guarda los bytes en memoria; la subida real ocurre en _guardar
  /// tras crear el contrato (necesita el contrato_id).
  Future<void> _elegirDocumento() async {
    if (_eligiendoDoc) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    var bytes = file.bytes;
    if (bytes == null) return;

    var ext = (file.extension ?? 'bin').toLowerCase();
    final esImagen = ext == 'jpg' || ext == 'jpeg' || ext == 'png';
    // PDF/Word: límite duro ANTES (no se pueden comprimir). Las fotos se
    // validan DESPUÉS de comprimir: una de 12 MB entra sobrada comprimida.
    if (!esImagen && bytes.length > _docMaxBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'El archivo supera el límite de ${_docMaxBytes ~/ (1024 * 1024)} MB')),
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() => _eligiendoDoc = true);
    try {
      // Foto elegida como documento → mismo pipeline de compresión que las
      // fotos de cliente. PDF/Word van tal cual (no hay recompresión
      // razonable client-side); el peso se muestra en el ListTile con aviso
      // si es pesado.
      if (esImagen) {
        final comp = await comprimirImagen(bytes,
            maxLado: 1920, calidad: 85, maxBytes: 9 * 1024 * 1024);
        if (!mounted) return;
        bytes = comp.bytes;
        ext = comp.ext;
        // Red de seguridad: imagen indecodificable que excede el bucket.
        if (bytes.length > _docMaxBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'El archivo supera el límite de ${_docMaxBytes ~/ (1024 * 1024)} MB')),
          );
          return;
        }
      }
      setState(() {
        _docBytes = bytes;
        _docExt = ext;
        _docNombre = file.name;
        _dirty = true;
      });
    } finally {
      if (mounted) setState(() => _eligiendoDoc = false);
    }
  }

  /// Sube el documento adjunto al bucket y actualiza documento_path.
  /// Best-effort: si falla (offline, etc.) no rompe la creación del contrato
  /// — solo avisa que se puede reintentar desde el detalle.
  Future<void> _subirDocumento(
      String contratoId, String tenantId, String ocurridoEn) async {
    try {
      final ext = _docExt ?? 'bin';
      final storagePath =
          '$tenantId/$contratoId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await Supabase.instance.client.storage.from(_docBucket).uploadBinary(
            storagePath,
            _docBytes!,
            fileOptions: FileOptions(contentType: _mimeDoc(ext)),
          );
      await ps.dbW.execute(
        'UPDATE contratos SET documento_path = ?, ocurrido_en = ? WHERE id = ?',
        [storagePath, ocurridoEn, contratoId],
      );
    } catch (_) {
      // No bloquea: el contrato ya existe. Avisamos para subir desde detalle.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'El contrato se creó, pero no se pudo subir el documento '
                  '(¿sin conexión?). Podés adjuntarlo desde el detalle.')),
        );
      }
    }
  }

  String _mimeDoc(String ext) => switch (ext) {
        'pdf' => 'application/pdf',
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'doc' => 'application/msword',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        _ => 'application/octet-stream',
      };

  /// Chequea (contra SQLite local) si el código ya está tomado en el tenant,
  /// mirando DOS lugares:
  ///   1. `contratos` — un contrato ya creado con ese código.
  ///   2. `solicitudes_accion` PENDIENTES de tipo crear_contrato — un número ya
  ///      pedido por otro gestor que todavía no se aprobó. Sin esto, dos
  ///      gestores piden el mismo número el mismo día, los dos "pasan" (el
  ///      contrato aún no existe) y el segundo revienta recién al aprobarse —
  ///      exactamente el rechazo tardío que reportó el dueño.
  ///
  /// Setea `_codigoDupMensaje` con el mensaje ya armado. Es el feedback EN VIVO
  /// mientras se tipea; el guard duro al guardar consulta el server
  /// (`_verificarCodigoEnServidor`). Devuelve true si hay conflicto.
  Future<bool> _verificarCodigoDuplicado() async {
    final codigo = _codigoCtrl.text.trim();
    if (codigo.isEmpty) {
      _codigoDupMensaje = null;
      return false;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return false;
    try {
      final rows = await ps.db.getAll(
        'SELECT c.nombre AS n FROM contratos ct '
        'LEFT JOIN clientes c ON c.id = ct.cliente_id '
        'WHERE ct.tenant_id = ? AND ${foldSqlExpr('ct.codigo')} = ? '
        'LIMIT 1',
        [tenantId, foldBusqueda(codigo)],
      );
      if (rows.isNotEmpty) {
        final nombre = rows.first['n'] as String?;
        _codigoDupMensaje = 'Ya existe un contrato con ese código'
            '${nombre != null ? ' (cliente $nombre)' : ''}';
        return true;
      }
      final pedidoPor = await _solicitudPendienteConCodigo(tenantId, codigo);
      if (pedidoPor != null) {
        _codigoDupMensaje = 'Ese número ya está pedido en una solicitud '
            'pendiente${pedidoPor.isEmpty ? '' : ' (de $pedidoPor)'}';
        return true;
      }
      _codigoDupMensaje = null;
      return false;
    } catch (_) {
      return false; // best-effort; el guard duro es el chequeo contra el server
    }
  }

  /// Busca en la réplica local una solicitud PENDIENTE de crear contrato que ya
  /// haya pedido ese código. Devuelve el nombre de quien la pidió ('' si no se
  /// sabe), o null si no hay ninguna.
  ///
  /// La réplica local sirve para esto en TODOS los roles que llegan a este form:
  /// las sync rules bajan `solicitudes_accion` del tenant completo (buckets
  /// `todo_tenant_admin_usuarios` y los de admin/cobranza), a diferencia de
  /// PostgREST, donde la RLS le muestra al gestor SOLO sus propias solicitudes.
  Future<String?> _solicitudPendienteConCodigo(
      String tenantId, String codigo) async {
    final rows = await ps.db.getAll(
      'SELECT * FROM solicitudes_accion '
      "WHERE tenant_id = ? AND tipo = 'crear_contrato' AND estado = 'pendiente'",
      [tenantId],
    );
    final buscado = foldBusqueda(codigo);
    for (final r in rows) {
      final s = SolicitudAccion.fromRow(r);
      final c = (s.datos['codigo'] as String?)?.trim();
      // foldBusqueda de los DOS lados: lower() de SQLite es ASCII-only y estos
      // códigos admiten ñ/tildes (regla #1d) — comparar pelado da falso libre.
      if (c != null && c.isNotEmpty && foldBusqueda(c) == buscado) {
        return s.solicitanteLabel ?? '';
      }
    }
    return null;
  }

  /// Escapa los comodines de LIKE/ILIKE. El código admite `_` y `-`: sin
  /// escapar, `OF_2401` matchearía `OF-2401` en el ILIKE del server (`_` = "un
  /// carácter cualquiera") y bloquearíamos un número que en realidad está libre.
  /// Igual NO confiamos solo en esto: el ILIKE se usa para ACOTAR y la igualdad
  /// final se confirma en Dart con `foldBusqueda` (un comodín solo puede traer
  /// filas de más, nunca de menos, así que el match verdadero siempre viene).
  static String _escaparLike(String s) => s
      .replaceAll('\\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// ¿El error es de RED (la consulta nunca llegó al server) o el server
  /// contestó? Se decide por TIPO de excepción, no por texto: PostgREST solo
  /// construye `PostgrestException` cuando ya tiene una respuesta HTTP en la
  /// mano — los fallos de red los deja pasar crudos (SocketException del
  /// dart:io, ClientException de package:http, TimeoutException nuestro).
  static bool _esErrorDeRed(Object e) {
    if (e is PostgrestException) return false; // el server RESPONDIÓ
    return e is SocketException ||
        e is HandshakeException ||
        e is HttpException ||
        e is TimeoutException ||
        e is http.ClientException;
  }

  /// Verifica el código contra la BASE REAL antes de guardar. La consulta ES la
  /// prueba de conexión: crear un contrato exige red justamente porque el número
  /// se valida contra la base (decisión del dueño 2026-08). El resto de la app
  /// sigue siendo offline-first; esto aplica SOLO al alta de contrato, que solo
  /// se hace desde el shell de admin (ningún cobrador crea contratos en la calle).
  ///
  /// ⚠️ LÍMITE CONOCIDO (RLS): `contratos_read` exige `is_personal_cobranza()`
  /// y `solicitudes_read` le muestra al gestor solo las suyas → para el rol
  /// `admin_usuarios` estas dos consultas devuelven vacío SIN error (la RLS
  /// filtra, no falla). Para ese rol la red dura la pone el chequeo local
  /// (`_verificarCodigoDuplicado`), que SÍ ve el tenant completo por las sync
  /// rules y queda fresco porque acabamos de exigir conexión. Para volver esto
  /// autoritativo también para el gestor hace falta una función SECURITY
  /// DEFINER en Postgres (no se puede desde el cliente).
  Future<_ChequeoCodigo> _verificarCodigoEnServidor(
      String tenantId, String codigo) async {
    // Corte propio: un socket colgado (wifi "conectado" que no llega a ningún
    // lado) no debe dejar el botón girando para siempre.
    const limite = Duration(seconds: 12);
    final sb = Supabase.instance.client;
    try {
      // 1. ¿Ya existe el contrato? `ilike` = comparación case-insensitive del
      //    lado de Postgres, la misma semántica del índice único
      //    `contratos_codigo_tenant_uq` = UNIQUE (tenant_id, upper(codigo)).
      final buscado = foldBusqueda(codigo);
      final contratos = await sb
          .from('contratos')
          .select('id, cliente_id, codigo')
          .eq('tenant_id', tenantId)
          .ilike('codigo', _escaparLike(codigo))
          .limit(5)
          .timeout(limite);
      for (final row in contratos) {
        final c = (row['codigo'] as String?)?.trim();
        // Confirmación exacta en Dart: el ILIKE pudo traer de más.
        if (c == null || foldBusqueda(c) != buscado) continue;
        final nombre = await _nombreClienteLocal(row['cliente_id'] as String?);
        return _ChequeoCodigo(
          _ResultadoChequeo.ocupado,
          'Ya existe un contrato con el código "$codigo"'
          '${nombre != null ? ' (cliente $nombre)' : ''}. Usá otro número.',
        );
      }

      // 2. ¿Alguien YA lo pidió y está esperando aprobación? Este es el caso que
      //    hoy se escapa: el contrato todavía no existe, así que el chequeo de
      //    arriba pasa y el choque aparece recién cuando el admin aprueba.
      final solicitudes = await sb
          .from('solicitudes_accion')
          .select()
          .eq('tenant_id', tenantId)
          .eq('tipo', 'crear_contrato')
          .eq('estado', 'pendiente')
          .limit(500)
          .timeout(limite);
      for (final row in solicitudes) {
        final s = SolicitudAccion.fromRow(row);
        final c = (s.datos['codigo'] as String?)?.trim();
        if (c == null || c.isEmpty || foldBusqueda(c) != buscado) continue;
        final quien = s.solicitanteLabel;
        return _ChequeoCodigo(
          _ResultadoChequeo.ocupado,
          'Ese número ya está pedido en una solicitud pendiente de aprobación'
          '${quien != null ? ' (de $quien)' : ''}. Usá otro número.',
        );
      }
      return const _ChequeoCodigo(_ResultadoChequeo.libre);
    } catch (e) {
      debugPrint('verificarCodigoEnServidor: $e');
      if (_esErrorDeRed(e)) {
        return const _ChequeoCodigo(
          _ResultadoChequeo.sinConexion,
          'Para crear un contrato necesitás conexión: el número se verifica '
          'contra la base para que no se duplique. Conectate y reintentá.',
        );
      }
      return const _ChequeoCodigo(
        _ResultadoChequeo.errorServidor,
        'No se pudo verificar el número contra la base (el servidor respondió '
        'un error). Reintentá; si sigue igual, avisale al administrador.',
      );
    }
  }

  /// Nombre del cliente desde la réplica local (el server solo nos dio el id).
  Future<String?> _nombreClienteLocal(String? clienteId) async {
    if (clienteId == null) return null;
    try {
      final row = await ps.db.getOptional(
        'SELECT nombre FROM clientes WHERE id = ?',
        [clienteId],
      );
      return row?['nombre'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Calcula "último número usado" + "siguiente sugerido" leyendo los códigos
  /// del tenant en la réplica local (más los ya pedidos en solicitudes
  /// pendientes: sugerir un número que otro ya pidió sería empujar al choque).
  ///
  /// Contempla prefijos alfanuméricos (`OF-2401` → `OF-2402`), el relleno con
  /// ceros (`00099` → `00100`) y que puede no haber ningún código todavía. Si
  /// ninguno termina en dígitos no hay patrón que continuar → se muestra el
  /// último usado SIN sugerencia.
  Future<void> _cargarSugerenciaCodigo() async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    try {
      final rows = await ps.db.getAll(
        'SELECT codigo FROM contratos '
        "WHERE tenant_id = ? AND codigo IS NOT NULL AND TRIM(codigo) <> '' "
        // Ordenado para que, si NINGÚN código termina en dígitos, el último de
        // la lista sea el del contrato más nuevo y no una fila al azar.
        'ORDER BY created_at',
        [tenantId],
      );
      final codigos = <String>[
        for (final r in rows) (r['codigo'] as String).trim(),
      ];
      final pendientes = await ps.db.getAll(
        'SELECT * FROM solicitudes_accion '
        "WHERE tenant_id = ? AND tipo = 'crear_contrato' AND estado = 'pendiente'",
        [tenantId],
      );
      for (final r in pendientes) {
        final c = (SolicitudAccion.fromRow(r).datos['codigo'] as String?)?.trim();
        if (c != null && c.isNotEmpty) codigos.add(c);
      }
      if (codigos.isEmpty) return;

      // Agrupamos por PREFIJO (lo que va antes de los dígitos finales) y nos
      // quedamos con la serie más usada: un tenant puede tener códigos sueltos
      // de otra época y no queremos que uno solo desvíe la sugerencia.
      final re = RegExp(r'^(.*?)(\d+)$');
      final maxPorPrefijo = <String, int>{};
      final anchoPorPrefijo = <String, int>{};
      final conteoPorPrefijo = <String, int>{};
      for (final c in codigos) {
        final m = re.firstMatch(c);
        if (m == null) continue;
        final prefijo = m.group(1)!;
        final digitos = m.group(2)!;
        // tryParse: 25 dígitos no entran en un int → esa serie se ignora.
        final valor = int.tryParse(digitos);
        if (valor == null) continue;
        conteoPorPrefijo[prefijo] = (conteoPorPrefijo[prefijo] ?? 0) + 1;
        final maxActual = maxPorPrefijo[prefijo];
        if (maxActual == null || valor > maxActual) {
          maxPorPrefijo[prefijo] = valor;
          anchoPorPrefijo[prefijo] = digitos.length;
        }
      }

      String? ultimo;
      String? sugerido;
      if (conteoPorPrefijo.isEmpty) {
        // Ningún código termina en número (p.ej. todos son "CONTRATO-ANEXO"):
        // mostramos uno como referencia pero no inventamos una secuencia.
        ultimo = codigos.last;
      } else {
        var mejor = conteoPorPrefijo.keys.first;
        for (final p in conteoPorPrefijo.keys) {
          final gana = conteoPorPrefijo[p]! > conteoPorPrefijo[mejor]! ||
              (conteoPorPrefijo[p]! == conteoPorPrefijo[mejor]! &&
                  maxPorPrefijo[p]! > maxPorPrefijo[mejor]!);
          if (gana) mejor = p;
        }
        final ancho = anchoPorPrefijo[mejor]!;
        final maximo = maxPorPrefijo[mejor]!;
        ultimo = '$mejor${maximo.toString().padLeft(ancho, '0')}';
        // El siguiente al MÁXIMO de la serie: por construcción está libre (y si
        // alguien lo pidió recién, el guard contra el server lo va a frenar).
        sugerido = '$mejor${(maximo + 1).toString().padLeft(ancho, '0')}'
            .toUpperCase();
      }

      final cliente = await _nombreClienteDeCodigo(tenantId, ultimo);
      if (!mounted) return;
      setState(() {
        _ultimoCodigo = ultimo;
        _ultimoCodigoCliente = cliente;
        _codigoSugerido = sugerido;
      });
    } catch (_) {
      // La guía es una ayuda, no un requisito: si falla, el form anda igual.
    }
  }

  /// De quién es el contrato que usa ese código (null si el código viene de una
  /// solicitud pendiente, es decir, todavía no hay contrato).
  Future<String?> _nombreClienteDeCodigo(String tenantId, String codigo) async {
    try {
      final rows = await ps.db.getAll(
        'SELECT c.nombre AS n FROM contratos ct '
        'LEFT JOIN clientes c ON c.id = ct.cliente_id '
        'WHERE ct.tenant_id = ? AND ${foldSqlExpr('ct.codigo')} = ? LIMIT 1',
        [tenantId, foldBusqueda(codigo)],
      );
      return rows.isEmpty ? null : rows.first['n'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Completa el campo con el número sugerido y revalida (entre que se calculó
  /// y se tocó el chip pudo entrar otro contrato por sync).
  Future<void> _usarCodigoSugerido() async {
    final sugerido = _codigoSugerido;
    if (sugerido == null) return;
    _dupDebounce?.cancel();
    _codigoCtrl.text = sugerido;
    _codigoCtrl.selection =
        TextSelection.collapsed(offset: _codigoCtrl.text.length);
    setState(() => _dirty = true);
    await _verificarCodigoDuplicado();
    if (mounted) setState(() {});
  }

  Future<void> _guardarComoSolicitud() async {
    final yo = ref.read(cobradorActualProvider).valueOrNull;
    if (yo == null || _clienteId == null || _planId == null) return;

    final planRow = await ps.db.getOptional(
      'SELECT nombre FROM planes WHERE id = ?',
      [_planId],
    );
    final clienteRow = await ps.db.getOptional(
      'SELECT nombre FROM clientes WHERE id = ?',
      [_clienteId],
    );
    if (!mounted) return;

    final duracionMeses = _duracion == _Duracion.unAno
        ? 12
        : (_duracion == _Duracion.dosAnos ? 24 : null);

    final datos = <String, dynamic>{
      'cliente_id': _clienteId,
      'cliente_nombre': clienteRow?['nombre'] as String? ?? '',
      'plan_id': _planId,
      'plan_nombre': planRow?['nombre'] as String? ?? '',
      'fecha_inicio': _fechaInicio.toIso8601String().substring(0, 10),
      'dia_pago': _fechaInicio.day,
      'duracion_meses': duracionMeses,
      'costo_instalacion': parseMonto(_costoCtrl.text),
      'codigo': _codigoCtrl.text.trim().isEmpty
          ? null
          : _codigoCtrl.text.trim().toUpperCase(),
      'notas':
          _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim(),
    };

    final ok = await solicitarAccion(
      context: context,
      ref: ref,
      tipo: TipoSolicitud.crearContrato,
      entidadId: _clienteId!,
      datos: datos,
      descripcionExtra:
          'Plan: ${planRow?['nombre'] ?? '?'}\n'
          'Cliente: ${clienteRow?['nombre'] ?? '?'}',
    );
    if (ok && mounted) {
      _dirty = false;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/admin/clientes');
      }
    }
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_clienteId == null) {
      setState(() => _error = 'Seleccioná un cliente');
      return;
    }
    if (_planId == null) {
      setState(() => _error = 'Seleccioná un plan');
      return;
    }

    final yo = ref.read(cobradorActualProvider).valueOrNull;
    // Antes: `esGestor = esAdminUsuarios`. O sea, el alta pasaba por aprobación
    // SOLO para ese rol y el admin_cobranza creaba directo — por descarte, el
    // mismo patrón que en el resto del ciclo.
    final esGestor =
        requiereAprobacionPara(yo, AccionSensible.crearContrato);

    // Doble-submit (fix audit #7): _guardando se setea ANTES del primer
    // await — con el botón habilitado durante los pre-chequeos async, un
    // doble-click en Windows creaba DOS contratos locales (el server
    // rechazaba el 2º recién al sync; offline persistían). Cada early-return
    // de acá en adelante debe revertirlo.
    // Ahora cubre TAMBIÉN el camino de solicitud (antes bifurcaba arriba y el
    // gestor podía doble-clickear "Solicitar creación").
    setState(() {
      _guardando = true;
      _error = null;
    });

    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() {
        _guardando = false;
        _error = 'No se pudo determinar el tenant';
      });
      return;
    }

    // ── Guard del CÓDIGO — corre para los DOS caminos ────────────────────
    // Bug reportado por el dueño (2026-08): el gestor bifurcaba a
    // _guardarComoSolicitud() ANTES de este chequeo, así que mandaba números
    // repetidos y el rechazo aparecía recién en la aprobación del admin.
    // Si el código está bloqueado (asignado + no super) no se puede cambiar → skip.
    final esSuper = yo?.esSuperAdmin ?? false;
    if (!(_codigoYaAsignado && !esSuper)) {
      // 1. Réplica local: instantáneo y ve el tenant completo en todos los roles.
      if (await _verificarCodigoDuplicado()) {
        if (!mounted) return;
        setState(() {
          _guardando = false;
          _error = '${_codigoDupMensaje ?? 'Ese código ya está en uso'}. '
              'Usá otro número.';
        });
        return;
      }
      // 2. Base REAL: además de ser la verdad, la consulta ES la prueba de
      //    conexión. Sin red no se crea el contrato (decisión del dueño).
      final chequeo =
          await _verificarCodigoEnServidor(tenantId, _codigoCtrl.text.trim());
      if (!mounted) return;
      if (!chequeo.libre) {
        setState(() {
          _guardando = false;
          _error = chequeo.mensaje;
        });
        return;
      }
    }

    if (esGestor) {
      try {
        await _guardarComoSolicitud();
      } finally {
        if (mounted) setState(() => _guardando = false);
      }
      return;
    }

    // P3b (2026-06-17): un cliente SIN cobrador SÍ puede tener contrato. Sus
    // cuotas quedan con cobrador_id NULL → solo admin/admin_cobranza las ven y
    // cobran hasta reasignar. Antes un guard acá (espejo del trigger E1,
    // removido en 0121) lo bloqueaba.
    // Guard: el índice único contratos_unique_activo_por_cliente_plan
    // (migración 0023/0054) prohíbe dos contratos ACTIVOS del mismo
    // cliente+plan. Sin este pre-chequeo, el INSERT local pasa pero PowerSync
    // lo rechaza al sincronizar con un error técnico en inglés. El contrato
    // nuevo siempre nace activo, así que el chequeo siempre corre.
    final dup = await ps.db.getAll(
      '''
      SELECT id FROM contratos
       WHERE cliente_id = ? AND plan_id = ? AND estado = 'activo'
       LIMIT 1
      ''',
      [_clienteId, _planId],
    );
    if (!mounted) return;
    if (dup.isNotEmpty) {
      setState(() {
        _guardando = false;
        _error = 'Este cliente ya tiene un contrato activo con ese plan. '
            'Cancelá el contrato anterior o elegí otro plan.';
      });
      return;
    }
    try {
      final fechaFin = _fechaFin();
      // Duración inmutable del contrato (invariante #5): se fija al crear y
      // NO se re-deriva de fechas. null = indefinido.
      final duracionMeses = _duracion == _Duracion.unAno
          ? 12
          : (_duracion == _Duracion.dosAnos ? 24 : null);
      // Día de pago = día de la instalación (un solo campo). La primera cuota
      // vence el mes siguiente; el server la deriva de fecha_inicio.
      final diaPago = _fechaInicio.day;
      final fechaPrimerCobroStr =
          _primerCobroEstimado().toIso8601String().substring(0, 10);
      final costoInstalacion = parseMonto(_costoCtrl.text);
      final notas =
          _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim();
      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      // Denormalizamos cobrador_id desde clientes en el INSERT local.
      // Postgres tiene trigger que lo llenaría server-side, pero ese
      // trigger no corre en SQLite local — sin esto, el contrato local
      // queda con cobrador_id NULL hasta sync, lo que lo hace invisible
      // al bucket por_cobrador.
      final clienteRow = await ps.db.getOptional(
        'SELECT cobrador_id FROM clientes WHERE id = ?',
        [_clienteId],
      );
      final cobradorId = clienteRow?['cobrador_id'] as String?;

      // P3b: un cliente SIN cobrador puede tener contrato → el contrato/cuotas
      // quedan con cobrador_id NULL (admin-managed hasta reasignar). Solo
      // bloqueamos si el cliente no está sincronizado localmente (sin sus datos
      // no podemos crear el contrato).
      if (clienteRow == null) {
        setState(() {
          _error =
              'No se pudo cargar el cliente. Verificá que esté sincronizado.';
          _guardando = false;
        });
        return;
      }

      final nuevoId = const Uuid().v4();
      // op_log (audit 2026-06-24): la creación del contrato debe dejar historial
      // (toda entidad creable lo emite — antes faltaba SOLO en este form). actor
      // = el usuario logueado (no el cobrador denormalizado del cliente).
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      // Las cuotas (incluido el colchón de indefinidos) las genera el trigger
      // server `trg_contratos_generar_cuotas_iniciales` al sincronizar el
      // contrato. NO se generan en el cliente acá: colisionarían con las del
      // trigger en el upload (mismo (contrato_id, periodo), distinto id →
      // unique violation 23505 → 3 avisos de rechazo de sync por alta). El
      // colchón OFFLINE se mantiene en el COBRO (pagos_repo →
      // asegurarColchonIndefinido), donde el contrato ya existe y no hay
      // AFTER INSERT que colisione.
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          '''
          INSERT INTO contratos (
            id, tenant_id, cliente_id, codigo, cobrador_id, plan_id, dia_pago,
            fecha_inicio, fecha_fin, duracion_meses, fecha_primer_cobro,
            costo_instalacion, notas, estado, created_at, ocurrido_en
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'activo', ?, ?)
          ''',
          [
            nuevoId,
            tenantId,
            _clienteId,
            _codigoCtrl.text.trim().isEmpty
                ? null
                : _codigoCtrl.text.trim().toUpperCase(),
            cobradorId,
            _planId,
            diaPago,
            _fechaInicio.toIso8601String().substring(0, 10),
            fechaFin?.toIso8601String().substring(0, 10),
            duracionMeses,
            fechaPrimerCobroStr,
            costoInstalacion,
            notas,
            DateTime.now().toIso8601String(),
            ocurridoEn,
          ],
        );
        final despues = (await tx
                .getAll('SELECT * FROM contratos WHERE id = ?', [nuevoId]))
            .first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId,
            opId: opId,
            entidad: 'contratos',
            entidadId: nuevoId,
            antes: const {},
            despues: despues,
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });

      // Documento opcional: subir best-effort si se adjuntó. Requiere
      // conexión (Storage); si falla o estamos offline, el contrato ya
      // quedó creado y el doc se puede subir luego desde el detalle.
      if (_docBytes != null) {
        await _subirDocumento(nuevoId, tenantId, ocurridoEn);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contrato creado.')),
        );
        // _dirty=false pre-pop para que PopScope no intercepte con
        // "¿Descartar?" tras guardado exitoso (no hay cambios sin
        // persistir — recién guardamos).
        _dirty = false;
        // pop si vinimos vía push (caso normal); fallback go al listado
        // si fue deep-link directo a la edición/creación.
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/contratos');
        }
      }
    } catch (e) {
      // M14: e.toString() crudo (SQLite/Postgres en inglés) no le sirve a un
      // admin; el detalle queda en debugPrint dentro del helper.
      if (mounted) {
        setState(
            () => _error = mensajeErrorHumano(e, contexto: 'guardar el contrato'));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync _dirty al form_dirty_provider para que el shell sidebar
    // pregunte "¿Descartar cambios?" antes de navegar — `context.go`
    // bypassa PopScope. Condicional para evitar postFrameCallbacks
    // en cada keystroke.
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
    final esSuper =
        ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;
    // Sondeo TCP real (el flag `connected` de PowerSync miente). Es un aviso
    // TEMPRANO — así no llenan todo el form para enterarse al final —, no la
    // decisión: tarda hasta ~15 s en declarar offline, así que quien decide si
    // se guarda es la consulta real de `_verificarCodigoEnServidor`. Por eso el
    // botón NO se deshabilita acá (un falso offline dejaría el form trabado).
    final sinConexion = ref.watch(conexionRealProvider).valueOrNull == false;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await confirmDiscardChanges(context);
        if (confirm != true || !context.mounted) return;
        // Fallback para deep-link: si canPop=false, Navigator.pop no
        // hace nada y el user queda atrapado. Go al listado.
        if (context.canPop()) {
          Navigator.pop(context);
        } else {
          context.go('/admin/contratos');
        }
      },
      child: Form(
        key: _formKey,
        onChanged: () {
          if (!_dirty) setState(() => _dirty = true);
        },
        child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (sinConexion) ...[
            Card(
              color: AppColors.warning.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off, color: AppColors.warning),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Sin conexión. Para crear un contrato hace falta '
                        'conexión: el número se verifica contra la base para '
                        'que no se duplique. Conectate antes de guardar.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Cliente y plan',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _codigoCtrl,
                    enabled: !codigoBloqueado,
                    decoration: InputDecoration(
                      labelText: 'Código de contrato *',
                      hintText: 'Ej. CT00012',
                      helperText: codigoBloqueado
                          ? 'Inmutable: no se puede cambiar una vez asignado.'
                          : 'Identificador del contrato. No se puede repetir.',
                      errorText: _codigoDupMensaje,
                      prefixIcon: const Icon(Icons.tag),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      // Alfanumérico ESPAÑOL: incluye ñ y vocales con tilde (el
                      // filtro corre ANTES del toUpperCase → minúscula y
                      // mayúscula). Sin esto la ñ no se podía tipear.
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Za-z0-9ñÑáéíóúüÁÉÍÓÚÜ\-_]')),
                      TextInputFormatter.withFunction((oldV, newV) =>
                          newV.copyWith(text: newV.text.toUpperCase())),
                      LengthLimitingTextInputFormatter(30),
                    ],
                    validator: (v) {
                      if (codigoBloqueado) return null;
                      if ((v ?? '').trim().isEmpty) {
                        return 'El código es obligatorio';
                      }
                      if (_codigoDupMensaje != null) return _codigoDupMensaje;
                      return null;
                    },
                    onChanged: (_) {
                      _dupDebounce?.cancel();
                      _dupDebounce = Timer(
                        const Duration(milliseconds: 350),
                        () async {
                          await _verificarCodigoDuplicado();
                          if (mounted) setState(() {});
                        },
                      );
                    },
                    textInputAction: TextInputAction.next,
                  ),
                  // Guía de la secuencia: "el digitador se levantó, volvió y no
                  // se acuerda del número" (feedback del dueño). Mostramos el
                  // último usado y, si la serie termina en dígitos, el siguiente
                  // a un toque. Wrap (no Row) para que no desborde en el celu.
                  if (!codigoBloqueado && _ultimoCodigo != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          Text(
                            'Último código usado: $_ultimoCodigo'
                            '${_ultimoCodigoCliente != null ? ' (cliente $_ultimoCodigoCliente)' : ''}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          if (_codigoSugerido != null &&
                              _codigoCtrl.text.trim() != _codigoSugerido)
                            ActionChip(
                              avatar: const Icon(Icons.arrow_forward, size: 16),
                              label: Text('Usar $_codigoSugerido'),
                              visualDensity: VisualDensity.compact,
                              onPressed:
                                  _guardando ? null : _usarCodigoSugerido,
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  _ClienteSelector(
                    clienteId: _clienteId,
                    enabled: true,
                    // Form.onChanged solo dispara para FormFields; los
                    // selectors custom acá deben marcar dirty a mano.
                    onChanged: (id) => setState(() {
                      _clienteId = id;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: 12),
                  _PlanSelector(
                    planId: _planId,
                    onChanged: (id) => setState(() {
                      _planId = id;
                      _dirty = true;
                    }),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Términos',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _SelectorFecha(
                    label: 'Fecha de instalación',
                    fecha: _fechaInicio,
                    onChanged: (d) => setState(() {
                      _fechaInicio = d;
                      _dirty = true;
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                    child: Text(
                      'La primera cuota vence el ${Fmt.fechaCorta(_primerCobroEstimado())} '
                      '(mes siguiente). Después, cada día ${_fechaInicio.day} del mes.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Duración',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<_Duracion>(
                    segments: const [
                      ButtonSegment(value: _Duracion.unAno, label: Text('1 año')),
                      ButtonSegment(value: _Duracion.dosAnos, label: Text('2 años')),
                      ButtonSegment(
                          value: _Duracion.indefinido, label: Text('Indefinido')),
                    ],
                    selected: {_duracion},
                    onSelectionChanged: (s) => setState(() {
                      _duracion = s.first;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _Duracion.indefinido == _duracion
                          ? 'Contrato indefinido: se generan las cuotas del período actual y el sistema mantiene un colchón de 3 meses adelante.'
                          : 'Se generan ${_duracion == _Duracion.unAno ? 12 : 24} cuotas (una por mes) desde el primer cobro.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _costoCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Costo de instalación (opcional)',
                      prefixText: 'C\$ ',
                      helperText:
                          'Dato informativo. No genera un cobro automático.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notasCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Notas del contrato (opcional)',
                      alignLabelWithHint: true,
                    ),
                  ),
                  // El estado del contrato (activo / suspendido / cancelado) se
                  // gestiona SOLO desde el dropdown del detalle del contrato —
                  // ahí la cancelación liquida las cuotas (anula pendientes +
                  // descuenta el saldo de las parciales) y es terminal. El form
                  // de edición no toca el estado para no saltearse esa lógica.
                ],
              ),
            ),
          ),
          // Documento del contrato (opcional al crear).
          ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Documento del contrato (opcional)',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Adjuntá el contrato firmado (PDF, Word o foto). Si no '
                      'tenés conexión ahora, podés subirlo después desde el '
                      'detalle del contrato.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_docBytes == null)
                      OutlinedButton.icon(
                        icon: _eligiendoDoc
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.upload_file),
                        label: Text(_eligiendoDoc
                            ? 'Procesando...'
                            : 'Adjuntar documento'),
                        onPressed: (_guardando || _eligiendoDoc)
                            ? null
                            : _elegirDocumento,
                      )
                    else
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file),
                        title: Text(_docNombre ?? 'Documento',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          _docBytes!.length > _docAvisoBytes
                              ? '${Fmt.pesoArchivo(_docBytes!.length)} — '
                                  'archivo pesado, puede tardar en subir'
                              : Fmt.pesoArchivo(_docBytes!.length),
                          style: _docBytes!.length > _docAvisoBytes
                              // Aviso informativo, no error: naranja warning.
                              ? const TextStyle(color: AppColors.warning)
                              : null,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Quitar',
                          onPressed: _guardando
                              ? null
                              : () => setState(() {
                                    _docBytes = null;
                                    _docExt = null;
                                    _docNombre = null;
                                  }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _guardando
                      ? null
                      : () => context.canPop()
                          ? context.pop()
                          : context.go('/admin/contratos'),
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
                      : (ref.watch(cobradorActualProvider).valueOrNull
                                  ?.esAdminUsuarios ??
                              false)
                          ? 'Solicitar creación'
                          : 'Crear contrato'),
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

class _ClienteSelector extends StatefulWidget {
  const _ClienteSelector({
    required this.clienteId,
    required this.onChanged,
    this.enabled = true,
  });
  final String? clienteId;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  State<_ClienteSelector> createState() => _ClienteSelectorState();
}

class _ClienteSelectorState extends State<_ClienteSelector> {
  // Campo read-only que abre un selector con buscador (acentos/ñ insensible)
  // en vez de un DropdownButton: con muchos clientes el dropdown es inusable.
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Valor inicial (deep-link con clienteId pre-seteado): hidratamos el nombre
    // del cliente ya elegido para no mostrar el campo vacío.
    _hidratarNombre();
  }

  @override
  void didUpdateWidget(_ClienteSelector old) {
    super.didUpdateWidget(old);
    if (old.clienteId != widget.clienteId) _hidratarNombre();
  }

  Future<void> _hidratarNombre() async {
    final id = widget.clienteId;
    if (id == null) {
      if (mounted) _ctrl.clear();
      return;
    }
    final row = await ps.db.getOptional(
      'SELECT nombre FROM clientes WHERE id = ?',
      [id],
    );
    if (!mounted) return;
    _ctrl.text = (row?['nombre'] as String?) ?? '';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _elegirCliente() async {
    final rows = await ps.db.getAll(
      'SELECT id, nombre FROM clientes WHERE activo = 1 ORDER BY nombre',
    );
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay clientes activos.')),
      );
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí un cliente',
      hint: 'Buscar cliente...',
      opciones: [
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() => _ctrl.text = elegido['nombre'] as String);
    widget.onChanged(elegido['id'] as String);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _ctrl,
      readOnly: true,
      enabled: widget.enabled,
      decoration: InputDecoration(
        labelText: 'Cliente *',
        hintText: 'Toca para elegir',
        suffixIcon: const Icon(Icons.arrow_drop_down),
        helperText:
            !widget.enabled ? 'No se puede cambiar al editar contrato' : null,
      ),
      onTap: widget.enabled ? _elegirCliente : null,
      // El valor real es el id del padre; el ctrl puede tener texto pero si el
      // padre no tiene cliente elegido, es inválido.
      validator: (_) => widget.clienteId == null ? 'Requerido' : null,
    );
  }
}

class _PlanSelector extends StatefulWidget {
  const _PlanSelector({required this.planId, required this.onChanged});
  final String? planId;
  final ValueChanged<String?> onChanged;

  @override
  State<_PlanSelector> createState() => _PlanSelectorState();
}

class _PlanSelectorState extends State<_PlanSelector> {
  // Campo read-only + selector con buscador (reemplaza al DropdownButton).
  final _ctrl = TextEditingController();
  // ¿Hay planes activos? Lo refresca cada apertura del selector; en build solo
  // decide si mostramos el aviso "No hay planes creados".
  bool _hayPlanes = true;

  @override
  void initState() {
    super.initState();
    // Valor inicial (form de edición / re-entrada): hidratamos "nombre · precio"
    // del plan ya elegido para no mostrar vacío.
    _hidratarNombre();
    _refrescarHayPlanes();
  }

  @override
  void didUpdateWidget(_PlanSelector old) {
    super.didUpdateWidget(old);
    if (old.planId != widget.planId) _hidratarNombre();
  }

  String _labelPlan(Map<String, dynamic> r) =>
      '${r['nombre']} · ${Fmt.cordobas(r['precio_mensual'] as num)}';

  Future<void> _hidratarNombre() async {
    final id = widget.planId;
    if (id == null) {
      if (mounted) _ctrl.clear();
      return;
    }
    final row = await ps.db.getOptional(
      'SELECT nombre, precio_mensual FROM planes WHERE id = ?',
      [id],
    );
    if (!mounted) return;
    _ctrl.text = row == null ? '' : _labelPlan(row);
  }

  Future<void> _refrescarHayPlanes() async {
    final rows = await ps.db.getAll(
      'SELECT 1 FROM planes WHERE activo = 1 LIMIT 1',
    );
    if (!mounted) return;
    final hay = rows.isNotEmpty;
    if (hay != _hayPlanes) setState(() => _hayPlanes = hay);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _elegirPlan() async {
    final rows = await ps.db.getAll(
      'SELECT id, nombre, precio_mensual FROM planes WHERE activo = 1 ORDER BY precio_mensual',
    );
    if (!mounted) return;
    if (rows.isEmpty) {
      setState(() => _hayPlanes = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay planes creados. Ir a Planes → Nuevo plan.')),
      );
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí un plan',
      hint: 'Buscar plan...',
      opciones: [
        for (final r in rows)
          OpcionSelector(valor: r, nombre: _labelPlan(r)),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() => _ctrl.text = _labelPlan(elegido));
    widget.onChanged(elegido['id'] as String);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _ctrl,
          readOnly: true,
          decoration: const InputDecoration(
            labelText: 'Plan *',
            hintText: 'Toca para elegir',
            suffixIcon: Icon(Icons.arrow_drop_down),
          ),
          onTap: _elegirPlan,
          validator: (_) => widget.planId == null ? 'Requerido' : null,
        ),
        if (!_hayPlanes) ...[
          const SizedBox(height: 8),
          Text(
            'No hay planes creados. Ir a Planes → Nuevo plan.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

class _SelectorFecha extends StatelessWidget {
  const _SelectorFecha({
    required this.label,
    required this.fecha,
    required this.onChanged,
  });

  final String label;
  final DateTime fecha;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final minDate = DateTime(2020);
        // initialDate debe estar dentro de [firstDate, lastDate].
        final initial = fecha.isBefore(minDate) ? minDate : fecha;
        final picked = await elegirFechaRapida(
          context,
          initialDate: initial,
          firstDate: minDate,
          lastDate: DateTime(2035),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today),
        ),
        child: Text(Fmt.fechaCorta(fecha)),
      ),
    );
  }
}
