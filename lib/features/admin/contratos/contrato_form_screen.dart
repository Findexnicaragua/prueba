import 'dart:async';
import 'dart:io' show HandshakeException, HttpException, SocketException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http show ClientException;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../data/models/solicitud_accion.dart';
import '../../../data/providers/aprobaciones_provider.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/conexion_real_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/services/imagen_compresion.dart';
import '../../../data/services/prestamos_calculo_service.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/selector_buscable.dart';
import '../../shared/widgets/solicitud_accion_helper.dart';

/// Resultado de verificar el código de contrato/préstamo contra Supabase.
enum _ResultadoChequeo {
  libre,
  ocupado,
  errorServidor,
  sinConexion,
}

extension _ResultadoChequeoX on _ResultadoChequeo {
  bool get libre => this == _ResultadoChequeo.libre;

  String get mensaje {
    switch (this) {
      case _ResultadoChequeo.libre:
        return '';
      case _ResultadoChequeo.ocupado:
        return 'Ese código ya está tomado en el servidor. Usá otro número.';
      case _ResultadoChequeo.errorServidor:
        return 'El servidor rechazó la verificación. Revisá tu conexión o intentá de nuevo.';
      case _ResultadoChequeo.sinConexion:
        return 'Sin conexión con el servidor. Para crear préstamos se requiere conexión para verificar el código único.';
    }
  }
}

class ContratoFormScreen extends ConsumerStatefulWidget {
  const ContratoFormScreen({super.key, this.clienteId});
  final String? clienteId;

  @override
  ConsumerState<ContratoFormScreen> createState() => _ContratoFormScreenState();
}

class _ContratoFormScreenState extends ConsumerState<ContratoFormScreen> {
  final _formKey = GlobalKey<FormState>();

  static const _docBucket = 'contratos-documentos';
  static const _tealColor = Color(0xFF0F766E);
  static const _tealDark = Color(0xFF115E59);

  // Controladores principales
  final _codigoCtrl = TextEditingController();
  final _montoCtrl = TextEditingController(text: '10000');
  final _interesCtrl = TextEditingController(text: '10');
  final _cuotasCtrl = TextEditingController(text: '12');
  final _notasCtrl = TextEditingController();

  String? _clienteId;
  String _moneda = 'NIO';
  FrecuenciaPago _frecuencia = FrecuenciaPago.mensual;
  MetodoCalculo _metodo = MetodoCalculo.interesFijo;
  bool _tasaEsMensual = true;
  DateTime _fechaInicio = DateTime.now();
  late DateTime _fechaPrimerCobro;
  bool _mostrarCronograma = false;

  // Sugerencia de código
  String? _ultimoCodigo;
  String? _codigoSugerido;
  final bool _codigoYaAsignado = false;
  String? _codigoDupMensaje;

  // Documento adjunto
  Uint8List? _docBytes;
  String? _docNombre;
  String? _docMime;

  bool _cargando = true;
  bool _guardando = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _clienteId = widget.clienteId;
    _fechaPrimerCobro =
        PrestamosCalculoService.sugerirPrimerPago(_fechaInicio, _frecuencia);
    _codigoCtrl.addListener(_onCodigoCambiado);
    _montoCtrl.addListener(_marcarDirty);
    _interesCtrl.addListener(_marcarDirty);
    _cuotasCtrl.addListener(_marcarDirty);
    _notasCtrl.addListener(_marcarDirty);
    _init();
  }

  void _marcarDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _onCodigoCambiado() {
    _marcarDirty();
    final texto = _codigoCtrl.text.trim();
    if (texto.isEmpty) {
      if (_codigoDupMensaje != null) {
        setState(() => _codigoDupMensaje = null);
      }
      return;
    }
    _debouncedVerificarCodigoDuplicado(texto);
  }

  Timer? _debounceTimer;
  void _debouncedVerificarCodigoDuplicado(String codigo) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      final dup = await _verificarCodigoDuplicadoTexto(codigo);
      if (!mounted) return;
      setState(() => _codigoDupMensaje = dup);
    });
  }

  Future<void> _init() async {
    await _cargarSugerenciaCodigo();
    if (mounted) setState(() => _cargando = false);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _codigoCtrl.removeListener(_onCodigoCambiado);
    _codigoCtrl.dispose();
    _montoCtrl.dispose();
    _interesCtrl.dispose();
    _cuotasCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  ResultadoCalculoPrestamo get _calculoActual {
    final monto = double.tryParse(_montoCtrl.text.replaceAll(',', '')) ?? 0.0;
    final tasa = double.tryParse(_interesCtrl.text.replaceAll(',', '')) ?? 0.0;
    final cuotas = int.tryParse(_cuotasCtrl.text) ?? 1;

    return PrestamosCalculoService.calcular(
      monto: monto,
      tasaInteres: tasa,
      plazoCuotas: cuotas,
      frecuencia: _frecuencia,
      metodo: _metodo,
      fechaInicio: _fechaInicio,
      fechaPrimerPago: _fechaPrimerCobro,
      moneda: _moneda,
      tasaEsMensual: _tasaEsMensual,
    );
  }

  String _formatearMonto(num valor) {
    return Fmt.monto(valor, _moneda);
  }

  Future<String?> _verificarCodigoDuplicadoTexto(String codigo) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return null;
    final rows = await ps.db.getAll(
      'SELECT c.nombre AS n FROM contratos ct '
      'JOIN clientes c ON c.id = ct.cliente_id '
      'WHERE ct.tenant_id = ? AND UPPER(ct.codigo) = UPPER(?) '
      'LIMIT 1',
      [tenantId, codigo],
    );
    if (rows.isNotEmpty) {
      final cli = rows.first['n'] as String? ?? 'otro cliente';
      return 'Código ya usado por $cli';
    }
    return null;
  }

  Future<bool> _verificarCodigoDuplicado() async {
    final texto = _codigoCtrl.text.trim();
    if (texto.isEmpty) return false;
    final msg = await _verificarCodigoDuplicadoTexto(texto);
    if (msg != null) {
      _codigoDupMensaje = msg;
      return true;
    }
    return false;
  }

  Future<_ResultadoChequeo> _verificarCodigoEnServidor(
      String tenantId, String codigo) async {
    if (codigo.isEmpty) return _ResultadoChequeo.libre;
    try {
      final sb = Supabase.instance.client;
      final contratos = await sb
          .from('contratos')
          .select('id, codigo, clientes(nombre)')
          .eq('tenant_id', tenantId)
          .ilike('codigo', codigo);

      if ((contratos as List).isNotEmpty) {
        return _ResultadoChequeo.ocupado;
      }

      final solicitudes = await sb
          .from('solicitudes_accion')
          .select('id, datos')
          .eq('tenant_id', tenantId)
          .eq('tipo', 'crear_contrato')
          .eq('estado', 'pendiente');

      for (final row in (solicitudes as List)) {
        final d = row['datos'] as Map<String, dynamic>?;
        final c = d?['codigo'] as String?;
        if (c != null && c.trim().toUpperCase() == codigo.toUpperCase()) {
          return _ResultadoChequeo.ocupado;
        }
      }
      return _ResultadoChequeo.libre;
    } on SocketException {
      return _ResultadoChequeo.sinConexion;
    } on HttpException {
      return _ResultadoChequeo.sinConexion;
    } on http.ClientException {
      return _ResultadoChequeo.sinConexion;
    } on HandshakeException {
      return _ResultadoChequeo.sinConexion;
    } catch (_) {
      return _ResultadoChequeo.errorServidor;
    }
  }

  Future<void> _cargarSugerenciaCodigo() async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    try {
      final rows = await ps.db.getAll(
        'SELECT codigo FROM contratos '
        "WHERE tenant_id = ? AND codigo IS NOT NULL AND TRIM(codigo) <> '' "
        'ORDER BY created_at',
        [tenantId],
      );
      final codigos = <String>[
        for (final r in rows) (r['codigo'] as String).trim(),
      ];
      if (codigos.isEmpty) {
        _codigoSugerido = 'PREST-001';
        return;
      }

      final re = RegExp(r'^(.*?)(\d+)$');
      final maxPorPrefijo = <String, int>{};
      final anchoPorPrefijo = <String, int>{};
      final conteoPorPrefijo = <String, int>{};

      for (final c in codigos) {
        final m = re.firstMatch(c);
        if (m == null) continue;
        final prefijo = m.group(1)!;
        final digitos = m.group(2)!;
        final valor = int.tryParse(digitos);
        if (valor == null) continue;
        conteoPorPrefijo[prefijo] = (conteoPorPrefijo[prefijo] ?? 0) + 1;
        final maxActual = maxPorPrefijo[prefijo];
        if (maxActual == null || valor > maxActual) {
          maxPorPrefijo[prefijo] = valor;
          anchoPorPrefijo[prefijo] = digitos.length;
        }
      }

      if (conteoPorPrefijo.isEmpty) {
        _ultimoCodigo = codigos.last;
        _codigoSugerido = 'PREST-001';
      } else {
        var mejor = conteoPorPrefijo.keys.first;
        for (final p in conteoPorPrefijo.keys) {
          if ((conteoPorPrefijo[p] ?? 0) > (conteoPorPrefijo[mejor] ?? 0)) {
            mejor = p;
          }
        }
        final maxNum = maxPorPrefijo[mejor]!;
        final ancho = anchoPorPrefijo[mejor]!;
        _ultimoCodigo = '$mejor${maxNum.toString().padLeft(ancho, '0')}';
        _codigoSugerido =
            '$mejor${(maxNum + 1).toString().padLeft(ancho, '0')}';
      }
    } catch (_) {}
  }

  void _usarCodigoSugerido() {
    if (_codigoSugerido == null) return;
    _codigoCtrl.text = _codigoSugerido!;
    setState(() => _dirty = true);
  }

  Future<void> _adjuntarDoc() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final file = res.files.first;
    if (file.bytes == null) return;

    var bytes = file.bytes!;
    final ext = (file.extension ?? '').toLowerCase();
    String mime = 'application/octet-stream';
    if (ext == 'pdf') mime = 'application/pdf';
    if (['jpg', 'jpeg', 'png'].contains(ext)) {
      mime = ext == 'png' ? 'image/png' : 'image/jpeg';
      final comp = await comprimirImagen(bytes);
      bytes = comp.bytes;
    }

    setState(() {
      _docBytes = bytes;
      _docNombre = file.name;
      _docMime = mime;
      _dirty = true;
    });
  }

  Future<void> _subirDocumento(
      String contratoId, String tenantId, String ocurridoEn) async {
    if (_docBytes == null) return;
    try {
      final ext = _docNombre?.split('.').last ?? 'bin';
      final storagePath =
          '$tenantId/$contratoId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      final sb = Supabase.instance.client;
      await sb.storage.from(_docBucket).uploadBinary(
            storagePath,
            _docBytes!,
            fileOptions: FileOptions(contentType: _docMime, upsert: true),
          );
      await ps.db.execute(
        'UPDATE contratos SET documento_path = ?, ocurrido_en = ? WHERE id = ?',
        [storagePath, ocurridoEn, contratoId],
      );
    } catch (_) {}
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_clienteId == null) {
      setState(() => _error = 'Seleccioná un cliente para el préstamo');
      return;
    }

    final calculo = _calculoActual;
    if (calculo.montoPrestado <= 0) {
      setState(() => _error = 'El monto del préstamo debe ser mayor a 0');
      return;
    }
    if (calculo.plazoCuotas <= 0) {
      setState(() => _error = 'El número de cuotas debe ser mayor a 0');
      return;
    }

    final yo = ref.read(cobradorActualProvider).valueOrNull;
    final esGestor = requiereAprobacionPara(yo, AccionSensible.crearContrato);

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

    // 1. Verificación de duplicado de código
    final esSuper = yo?.esSuperAdmin ?? false;
    if (!(_codigoYaAsignado && !esSuper)) {
      if (await _verificarCodigoDuplicado()) {
        if (!mounted) return;
        setState(() {
          _guardando = false;
          _error =
              '${_codigoDupMensaje ?? 'Ese código ya está en uso'}. Usá otro número.';
        });
        return;
      }
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

    // Si es gestor, pasa por flujo de solicitud de aprobación
    if (esGestor) {
      try {
        final clienteRow = await ps.db.getOptional(
          'SELECT nombre FROM clientes WHERE id = ?',
          [_clienteId],
        );
        if (!mounted) return;
        final datos = <String, dynamic>{
          'cliente_id': _clienteId,
          'cliente_nombre': clienteRow?['nombre'] as String? ?? '',
          'codigo': _codigoCtrl.text.trim().toUpperCase(),
          'monto_prestado': calculo.montoPrestado,
          'tasa_interes': calculo.tasaInteres,
          'tasa_es_mensual': calculo.tasaEsMensual,
          'frecuencia': calculo.frecuencia.name,
          'plazo_cuotas': calculo.plazoCuotas,
          'metodo_calculo': calculo.metodo.name,
          'moneda': calculo.moneda,
          'monto_cuota': calculo.montoCuota,
          'total_interes': calculo.totalInteres,
          'total_pagar': calculo.totalPagar,
          'fecha_inicio':
              calculo.fechaInicio.toIso8601String().substring(0, 10),
          'fecha_primer_cobro':
              calculo.fechaPrimerPago.toIso8601String().substring(0, 10),
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
              'Préstamo: ${_formatearMonto(calculo.montoPrestado)} '
              '(${calculo.plazoCuotas} cuotas de ${_formatearMonto(calculo.montoCuota)})\n'
              'Cliente: ${clienteRow?['nombre'] ?? '?'}',
        );
        if (ok && mounted) {
          _dirty = false;
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/admin/contratos');
          }
        }
      } finally {
        if (mounted) setState(() => _guardando = false);
      }
      return;
    }

    try {
      final nuevoId = const Uuid().v4();
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();

      // Denormalizar cobrador_id desde clientes
      final clienteRow = await ps.db.getOptional(
        'SELECT cobrador_id, nombre FROM clientes WHERE id = ?',
        [_clienteId],
      );
      final cobradorId = clienteRow?['cobrador_id'] as String?;

      final opId = OpLog.nuevoOpId();
      final actor = yo != null
          ? await OpLog.actorDeUsuario(ps.db, yo.id)
          : const OpLogActor.systemAdmin();

      // ── Transacción atómica: Préstamo + Cronograma de Cuotas ─────────────
      await ps.dbW.writeTransaction((tx) async {
        // 1. Guardar préstamo en contratos
        await tx.execute(
          '''
          INSERT INTO contratos (
            id, tenant_id, cliente_id, codigo, cobrador_id, dia_pago,
            fecha_inicio, fecha_fin, duracion_meses, fecha_primer_cobro,
            costo_instalacion, notas, estado, created_at, ocurrido_en,
            monto_prestado, tasa_interes, frecuencia, plazo_cuotas, metodo_calculo,
            monto_cuota, total_interes, total_pagar, moneda
          ) VALUES (
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            0.0, ?, 'activo', ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?
          )
          ''',
          [
            nuevoId,
            tenantId,
            _clienteId,
            _codigoCtrl.text.trim().toUpperCase(),
            cobradorId,
            calculo.fechaPrimerPago.day,
            calculo.fechaInicio.toIso8601String().substring(0, 10),
            calculo.fechaUltimaCuota.toIso8601String().substring(0, 10),
            (calculo.plazoCuotas * calculo.frecuencia.diasAprox / 30).ceil(),
            calculo.fechaPrimerPago.toIso8601String().substring(0, 10),
            _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim(),
            DateTime.now().toIso8601String(),
            ocurridoEn,
            calculo.montoPrestado,
            calculo.tasaInteres,
            calculo.frecuencia.name,
            calculo.plazoCuotas,
            calculo.metodo.name,
            calculo.montoCuota,
            calculo.totalInteres,
            calculo.totalPagar,
            calculo.moneda,
          ],
        );

        final despuesContrato = (await tx.getAll(
          'SELECT * FROM contratos WHERE id = ?',
          [nuevoId],
        )).first;

        await OpLog.escribirCambioEntidad(
          tx,
          tenantId: tenantId,
          opId: opId,
          entidad: 'contratos',
          entidadId: nuevoId,
          antes: const {},
          despues: despuesContrato,
          actor: actor,
          ocurridoEn: DateTime.parse(ocurridoEn),
        );

        // 2. Generar cronograma completo de cuotas
        for (final c in calculo.cronograma) {
          final cuotaId = const Uuid().v4();
          final fechaStr =
              c.fechaVencimiento.toIso8601String().substring(0, 10);
          final descripcion =
              'Cuota ${c.numero} de ${calculo.plazoCuotas} (${calculo.frecuencia.etiqueta})';

          await tx.execute(
            '''
            INSERT INTO cuotas (
              id, tenant_id, contrato_id, cliente_id, cobrador_id,
              periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto,
              estado, descripcion, created_at, ocurrido_en,
              capital, interes, saldo_restante
            ) VALUES (
              ?, ?, ?, ?, ?,
              ?, ?, ?, 0.0, 0.0,
              'pendiente', ?, ?, ?,
              ?, ?, ?
            )
            ''',
            [
              cuotaId,
              tenantId,
              nuevoId,
              _clienteId,
              cobradorId,
              fechaStr,
              fechaStr,
              c.cuota,
              descripcion,
              DateTime.now().toIso8601String(),
              ocurridoEn,
              c.capital,
              c.interes,
              c.saldoRestante,
            ],
          );

          final cuotaDespues = (await tx.getAll(
            'SELECT * FROM cuotas WHERE id = ?',
            [cuotaId],
          )).first;

          await OpLog.escribirCambioEntidad(
            tx,
            tenantId: tenantId,
            opId: opId,
            entidad: 'cuotas',
            entidadId: cuotaId,
            antes: const {},
            despues: cuotaDespues,
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn),
          );
        }
      });

      // Subir documento si se adjuntó
      if (_docBytes != null) {
        await _subirDocumento(nuevoId, tenantId, ocurridoEn);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Préstamo ${_codigoCtrl.text.trim().toUpperCase()} creado con éxito '
              '(${calculo.plazoCuotas} cuotas generadas).',
            ),
            backgroundColor: _tealColor,
          ),
        );
        _dirty = false;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/contratos');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Error guardando préstamo: ${mensajeErrorHumano(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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

    final sinConexion = ref.watch(conexionRealProvider).valueOrNull == false;
    final size = MediaQuery.of(context).size;
    final esPantallaAncha = size.width >= 920;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await confirmDiscardChanges(context);
        if (confirm != true || !context.mounted) return;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/contratos');
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          title: const Text('Nuevo Préstamo'),
          actions: [
            if (sinConexion)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Icon(Icons.wifi_off,
                        size: 16, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 4),
                    Text(
                      'Sin red',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1140),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    if (esPantallaAncha)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Columna Izquierda: Identificación, Variables exactas y Garantía
                          Expanded(
                            flex: 5,
                            child: Column(
                              children: [
                                _buildPrestatarioCodigoCard(),
                                const SizedBox(height: 16),
                                _buildDatosPrestamoCard(),
                                const SizedBox(height: 16),
                                _buildGarantiaDocumentosCard(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          // Columna Derecha: Tarjeta Teal, Cronograma y Botones
                          Expanded(
                            flex: 6,
                            child: Column(
                              children: [
                                _buildResultadosCard(),
                                const SizedBox(height: 16),
                                _buildCronogramaSection(),
                                const SizedBox(height: 20),
                                _buildBotonesAccion(),
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        children: [
                          _buildPrestatarioCodigoCard(),
                          const SizedBox(height: 16),
                          _buildDatosPrestamoCard(),
                          const SizedBox(height: 16),
                          _buildResultadosCard(),
                          const SizedBox(height: 16),
                          _buildCronogramaSection(),
                          const SizedBox(height: 16),
                          _buildGarantiaDocumentosCard(),
                          const SizedBox(height: 24),
                          _buildBotonesAccion(),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 1. PRESTATARIO Y CÓDIGO (OBLIGATORIO) ───────────────────────────────────
  Widget _buildPrestatarioCodigoCard() {
    final esSuper =
        ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.badge_outlined, color: _tealColor, size: 20),
              SizedBox(width: 8),
              Text(
                'Identificación del Préstamo',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _ClienteSelector(
            clienteId: _clienteId,
            enabled: true,
            onChanged: (id) => setState(() {
              _clienteId = id;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 16),
          const Text(
            'Código de Préstamo / Pagaré *',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _codigoCtrl,
            readOnly: codigoBloqueado,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.numbers, size: 20),
              hintText: 'Ej. PREST-001',
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              errorText: _codigoDupMensaje,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'El código de préstamo es obligatorio';
              }
              if (_codigoDupMensaje != null) return _codigoDupMensaje;
              return null;
            },
          ),
          if (_ultimoCodigo != null && !codigoBloqueado)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Último usado: $_ultimoCodigo',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  if (_codigoSugerido != null &&
                      _codigoCtrl.text.trim() != _codigoSugerido)
                    ActionChip(
                      avatar: const Icon(Icons.auto_awesome,
                          size: 14, color: _tealColor),
                      label: Text('Usar $_codigoSugerido'),
                      labelStyle: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _tealColor),
                      backgroundColor: const Color(0xFFE6FFFA),
                      side: const BorderSide(color: Color(0xFF99F6E4)),
                      visualDensity: VisualDensity.compact,
                      onPressed: _guardando ? null : _usarCodigoSugerido,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── 2. DATOS DEL PRÉSTAMO (UI EXACTA DE LA CALCULADORA) ────────────────────
  Widget _buildDatosPrestamoCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune, color: _tealColor, size: 20),
              SizedBox(width: 8),
              Text(
                'Variables del Préstamo',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Moneda
          const Text(
            'Moneda',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'NIO',
                label: Text('Córdobas (C\$)'),
                icon: Icon(Icons.monetization_on_outlined, size: 16),
              ),
              ButtonSegment(
                value: 'USD',
                label: Text('Dólares (US\$)'),
                icon: Icon(Icons.attach_money, size: 16),
              ),
            ],
            selected: {_moneda},
            onSelectionChanged: (val) {
              setState(() {
                _moneda = val.first;
                _marcarDirty();
              });
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Cantidad a Prestar
          Text(
            'Cantidad a Prestar (${_moneda == "NIO" ? "C\$" : "US\$"})',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _montoCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.payments_outlined, size: 20),
              hintText: 'Ej. 10000',
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Monto requerido';
              final n = double.tryParse(v.replaceAll(',', ''));
              if (n == null || n <= 0) return 'Monto inválido';
              return null;
            },
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [2000, 5000, 10000, 20000, 50000].map((val) {
              return ActionChip(
                label: Text(
                  _moneda == 'NIO' ? 'C\$ $val' : '\$ $val',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () {
                  setState(() {
                    _montoCtrl.text = val.toString();
                    _marcarDirty();
                  });
                },
                backgroundColor: const Color(0xFFF1F5F9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),

          // Tasa de Interés (%)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Tasa de Interés (%)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                ),
              ),
              Row(
                children: [
                  InkWell(
                    onTap: () => setState(() {
                      _tasaEsMensual = true;
                      _marcarDirty();
                    }),
                    child: Text(
                      'Por período',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            _tasaEsMensual ? FontWeight.bold : FontWeight.normal,
                        color: _tasaEsMensual ? _tealColor : Colors.grey,
                      ),
                    ),
                  ),
                  const Text(' | ', style: TextStyle(color: Colors.grey)),
                  InkWell(
                    onTap: () => setState(() {
                      _tasaEsMensual = false;
                      _marcarDirty();
                    }),
                    child: Text(
                      'Total del crédito',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            !_tasaEsMensual ? FontWeight.bold : FontWeight.normal,
                        color: !_tasaEsMensual ? _tealColor : Colors.grey,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _interesCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.percent, size: 18),
              hintText: 'Ej. 10',
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Tasa requerida';
              final n = double.tryParse(v.replaceAll(',', ''));
              if (n == null || n < 0) return 'Tasa inválida';
              return null;
            },
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [5, 8, 10, 12, 15, 20].map((t) {
              return ActionChip(
                label: Text('$t%', style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  setState(() {
                    _interesCtrl.text = t.toString();
                    _marcarDirty();
                  });
                },
                backgroundColor: const Color(0xFFF1F5F9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),

          // Frecuencia de Pago
          const Text(
            'Frecuencia de Pago',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<FrecuenciaPago>(
            initialValue: _frecuencia,
            decoration: InputDecoration(
              prefixIcon:
                  const Icon(Icons.calendar_today_outlined, size: 18),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            items: FrecuenciaPago.values.map((f) {
              return DropdownMenuItem(
                value: f,
                child: Text(
                  '${f.etiqueta} (cada ${f.periodo})',
                  style: const TextStyle(fontSize: 14),
                ),
              );
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _frecuencia = val;
                  _fechaPrimerCobro =
                      PrestamosCalculoService.sugerirPrimerPago(
                          _fechaInicio, val);
                  _marcarDirty();
                });
              }
            },
          ),
          const SizedBox(height: 18),

          // Cantidad de Cuotas
          const Text(
            'Cantidad de Cuotas',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _cuotasCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    prefixIcon:
                        const Icon(Icons.format_list_numbered, size: 20),
                    hintText: 'Ej. 12',
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Cuotas requeridas';
                    }
                    final n = int.tryParse(v);
                    if (n == null || n <= 0) return 'Mínimo 1 cuota';
                    return null;
                  },
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: () {
                  final cur = int.tryParse(_cuotasCtrl.text) ?? 1;
                  final c = (cur - 1).clamp(1, 360);
                  setState(() {
                    _cuotasCtrl.text = c.toString();
                    _marcarDirty();
                  });
                },
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.add, size: 18),
                onPressed: () {
                  final cur = int.tryParse(_cuotasCtrl.text) ?? 1;
                  final c = cur + 1;
                  setState(() {
                    _cuotasCtrl.text = c.toString();
                    _marcarDirty();
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [4, 6, 8, 12, 16, 24, 30].map((n) {
              return ActionChip(
                label: Text('$n cuotas', style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  setState(() {
                    _cuotasCtrl.text = n.toString();
                    _marcarDirty();
                  });
                },
                backgroundColor: const Color(0xFFF1F5F9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),

          // Método de Amortización
          const Text(
            'Método de Amortización',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          ...MetodoCalculo.values.map((metodo) {
            final seleccionado = _metodo == metodo;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => setState(() {
                  _metodo = metodo;
                  _marcarDirty();
                }),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: seleccionado
                        ? const Color(0xFFF0FDFA)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: seleccionado
                          ? _tealColor
                          : const Color(0xFFE2E8F0),
                      width: seleccionado ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        seleccionado
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: seleccionado ? _tealColor : Colors.grey,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              metodo.titulo,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: seleccionado
                                    ? _tealColor
                                    : const Color(0xFF334155),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              metodo.descripcion,
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 14),

          // Fechas
          Row(
            children: [
              Expanded(
                child: _SelectorFechaBoton(
                  label: 'Fecha Desembolso',
                  fecha: _fechaInicio,
                  onChanged: (d) {
                    setState(() {
                      _fechaInicio = d;
                      _fechaPrimerCobro =
                          PrestamosCalculoService.sugerirPrimerPago(
                              d, _frecuencia);
                      _marcarDirty();
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SelectorFechaBoton(
                  label: 'Fecha Primer Cobro',
                  fecha: _fechaPrimerCobro,
                  onChanged: (d) => setState(() {
                    _fechaPrimerCobro = d;
                    _marcarDirty();
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 3. TARJETA TEAL DE RESULTADOS (DISEÑO EXACTO CALCULADORA) ──────────────
  Widget _buildResultadosCard() {
    final calculo = _calculoActual;
    final cuotasNum = calculo.plazoCuotas;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_tealColor, _tealDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F0F766E),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'VALOR DE LA CUOTA',
                style: TextStyle(
                  color: Color(0xFFCCFBF1),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(40),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$cuotasNum pagos ${_frecuencia.etiqueta.toLowerCase()}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _formatearMonto(calculo.montoCuota),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Cada ${_frecuencia.periodo} hasta cancelar',
            style: const TextStyle(color: Color(0xFF99F6E4), fontSize: 13),
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0x33FFFFFF), height: 1),
          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Total a Pagar',
                  subtitulo: 'Capital + Intereses',
                  valor: _formatearMonto(calculo.totalPagar),
                  icono: Icons.account_balance_wallet_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Solo Intereses',
                  subtitulo: 'Ganancia por crédito',
                  valor: _formatearMonto(calculo.totalInteres),
                  icono: Icons.trending_up,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Capital Prestado',
                  subtitulo: 'Monto base',
                  valor: _formatearMonto(calculo.montoPrestado),
                  icono: Icons.attach_money,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricTile(
                  titulo: 'Tasa Efectiva',
                  subtitulo:
                      _tasaEsMensual ? 'Por período' : 'Total del crédito',
                  valor: '${calculo.tasaInteres} %',
                  icono: Icons.percent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String titulo,
    required String subtitulo,
    required String valor,
    required IconData icono,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: const Color(0xFFCCFBF1), size: 14),
              const SizedBox(width: 6),
              Text(
                titulo,
                style: const TextStyle(
                  color: Color(0xFFCCFBF1),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            valor,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            subtitulo,
            style: const TextStyle(
              color: Color(0xAAFFFFFF),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  // ── 4. CRONOGRAMA DE PAGOS (DESPLEGABLE / EXPANDIBLE) ──────────────────────
  Widget _buildCronogramaSection() {
    final calculo = _calculoActual;
    final cronograma = calculo.cronograma;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.calendar_month_outlined,
                        color: _tealColor, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Cronograma de Pagos',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _mostrarCronograma = !_mostrarCronograma);
                  },
                  icon: Icon(
                    _mostrarCronograma
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 16,
                  ),
                  label: Text(_mostrarCronograma
                      ? 'Ocultar'
                      : 'Ver detalle (${calculo.plazoCuotas} cuotas)'),
                  style: TextButton.styleFrom(
                    foregroundColor: _tealColor,
                  ),
                ),
              ],
            ),
          ),
          if (_mostrarCronograma) ...[
            const Divider(height: 1, color: Color(0xFFE2E8F0)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor:
                    WidgetStateProperty.all(const Color(0xFFF8FAFC)),
                headingTextStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF475569),
                ),
                dataTextStyle: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF1E293B),
                ),
                columnSpacing: 22,
                columns: const [
                  DataColumn(label: Text('#')),
                  DataColumn(label: Text('Fecha')),
                  DataColumn(label: Text('Cuota')),
                  DataColumn(label: Text('Capital')),
                  DataColumn(label: Text('Interés')),
                  DataColumn(label: Text('Saldo Restante')),
                ],
                rows: cronograma.map((c) {
                  return DataRow(
                    cells: [
                      DataCell(Text(
                        '${c.numero}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      )),
                      DataCell(Text(
                          DateFormat('dd/MM/yyyy').format(c.fechaVencimiento))),
                      DataCell(Text(
                        _formatearMonto(c.cuota),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _tealColor,
                        ),
                      )),
                      DataCell(Text(_formatearMonto(c.capital))),
                      DataCell(Text(
                        _formatearMonto(c.interes),
                        style: const TextStyle(color: Color(0xFFD97706)),
                      )),
                      DataCell(Text(_formatearMonto(c.saldoRestante))),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── 5. GARANTÍA, DOCUMENTOS Y NOTAS (RESPETADO) ───────────────────────────
  Widget _buildGarantiaDocumentosCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, color: _tealColor, size: 20),
              SizedBox(width: 8),
              Text(
                'Garantía, Documentos y Notas',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Garantía / Aval / Observaciones (opcional)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _notasCtrl,
            maxLines: 2,
            decoration: InputDecoration(
              hintText:
                  'Detalles de la garantía prendaria, aval solidario o acuerdos...',
              prefixIcon: const Icon(Icons.note_alt_outlined, size: 20),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 16),

          // Adjuntar documento
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                Icon(
                  _docNombre != null
                      ? Icons.description
                      : Icons.file_present_outlined,
                  color: _docNombre != null ? _tealColor : Colors.grey,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pagaré o Contrato firmado (opcional)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF334155),
                        ),
                      ),
                      Text(
                        _docNombre != null
                            ? 'Archivo: $_docNombre'
                            : 'Podés adjuntar PDF, imagen o foto del pagaré.',
                        style: TextStyle(
                          fontSize: 11,
                          color: _docNombre != null
                              ? _tealColor
                              : const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_docBytes != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.red, size: 20),
                    tooltip: 'Quitar archivo',
                    onPressed: () => setState(() {
                      _docBytes = null;
                      _docNombre = null;
                      _docMime = null;
                      _marcarDirty();
                    }),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: Text(_docBytes == null ? 'Adjuntar' : 'Cambiar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _tealColor,
                    side: const BorderSide(color: _tealColor),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _guardando ? null : _adjuntarDoc,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 6. BOTONES DE ACCIÓN ───────────────────────────────────────────────────
  Widget _buildBotonesAccion() {
    final yo = ref.watch(cobradorActualProvider).valueOrNull;
    final esGestor = requiereAprobacionPara(yo, AccionSensible.crearContrato);

    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _guardando
                ? null
                : () => Navigator.of(context).maybePop(),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Cancelar'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            icon: _guardando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check_circle_outline),
            label: Text(
              _guardando
                  ? 'Guardando...'
                  : esGestor
                      ? 'Solicitar Aprobación'
                      : 'Crear Préstamo',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _tealColor,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: _guardando ? null : _guardar,
          ),
        ),
      ],
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
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
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
      'SELECT id, nombre, cedula FROM clientes WHERE activo = 1 ORDER BY nombre',
    );
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay clientes activos creados.')),
      );
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí un Prestatario',
      hint: 'Buscar por nombre o cédula...',
      opciones: [
        for (final r in rows)
          OpcionSelector(
            valor: r,
            nombre: '${r['nombre']}'
                '${(r['cedula'] != null && (r['cedula'] as String).isNotEmpty) ? '  (${r['cedula']})' : ''}',
          ),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() => _ctrl.text = elegido['nombre'] as String);
    widget.onChanged(elegido['id'] as String);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Prestatario / Cliente *',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _ctrl,
          readOnly: true,
          enabled: widget.enabled,
          decoration: InputDecoration(
            hintText: 'Toca para buscar cliente...',
            prefixIcon: const Icon(Icons.person_outline, size: 20),
            suffixIcon: const Icon(Icons.arrow_drop_down),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          onTap: widget.enabled ? _elegirCliente : null,
          validator: (_) =>
              widget.clienteId == null ? 'Seleccioná un cliente' : null,
        ),
      ],
    );
  }
}

class _SelectorFechaBoton extends StatelessWidget {
  const _SelectorFechaBoton({
    required this.label,
    required this.fecha,
    required this.onChanged,
  });

  final String label;
  final DateTime fecha;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: fecha,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (d != null) onChanged(d);
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_outlined,
                    size: 16, color: Color(0xFF0F766E)),
                const SizedBox(width: 8),
                Text(
                  DateFormat('dd/MM/yyyy').format(fecha),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
