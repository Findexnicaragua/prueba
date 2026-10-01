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

import '../../../data/providers/aprobaciones_provider.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/conexion_real_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/services/imagen_compresion.dart';
import '../../../data/services/prestamos_calculo_service.dart';
import '../../../data/models/solicitud_accion.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/solicitud_accion_helper.dart';
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/selector_buscable.dart';

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
    _fechaPrimerCobro = PrestamosCalculoService.sugerirPrimerPago(_fechaInicio, _frecuencia);
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

  String get _simboloMoneda => _moneda == 'USD' ? 'US\$' : 'C\$';

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
        _codigoSugerido = '$mejor${(maxNum + 1).toString().padLeft(ancho, '0')}';
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

  void _mostrarDialogoCronograma() {
    final calculo = _calculoActual;
    final fMoneda = NumberFormat('#,##0.00');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Cronograma de Amortización',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${calculo.plazoCuotas} cuotas de $_simboloMoneda ${fMoneda.format(calculo.montoCuota)} (${calculo.frecuencia.etiqueta}) · Método: ${calculo.metodo.titulo}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 13,
                ),
              ),
              const Divider(height: 24),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  itemCount: calculo.cronograma.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, idx) {
                    final c = calculo.cronograma[idx];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${c.numero}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  DateFormat('dd/MM/yyyy').format(c.fechaVencimiento),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  'Capital: $_simboloMoneda ${fMoneda.format(c.capital)}  |  Interés: $_simboloMoneda ${fMoneda.format(c.interes)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '$_simboloMoneda ${fMoneda.format(c.cuota)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                'Saldo: $_simboloMoneda ${fMoneda.format(c.saldoRestante)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
          _error = '${_codigoDupMensaje ?? 'Ese código ya está en uso'}. Usá otro número.';
        });
        return;
      }
      final chequeo = await _verificarCodigoEnServidor(tenantId, _codigoCtrl.text.trim());
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
          'fecha_inicio': calculo.fechaInicio.toIso8601String().substring(0, 10),
          'fecha_primer_cobro': calculo.fechaPrimerPago.toIso8601String().substring(0, 10),
          'notas': _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim(),
        };

        final ok = await solicitarAccion(
          context: context,
          ref: ref,
          tipo: TipoSolicitud.crearContrato,
          entidadId: _clienteId!,
          datos: datos,
          descripcionExtra:
              'Préstamo: $_simboloMoneda ${calculo.montoPrestado.toStringAsFixed(2)} '
              '(${calculo.plazoCuotas} cuotas de $_simboloMoneda ${calculo.montoCuota.toStringAsFixed(2)})\n'
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
          final fechaStr = c.fechaVencimiento.toIso8601String().substring(0, 10);
          final descripcion = 'Cuota ${c.numero} de ${calculo.plazoCuotas} (${calculo.frecuencia.etiqueta})';

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
            backgroundColor: Colors.green.shade800,
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

    final esSuper = ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;
    final sinConexion = ref.watch(conexionRealProvider).valueOrNull == false;
    final calculo = _calculoActual;
    final fMoneda = NumberFormat('#,##0.00');

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
        appBar: AppBar(
          title: const Text('Nuevo Préstamo'),
          actions: [
            if (sinConexion)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Icon(Icons.wifi_off, size: 16, color: Theme.of(context).colorScheme.error),
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
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── 1. DATOS DEL CRÉDITO Y PRESTATARIO ──────────────────────────
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.badge_outlined, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('Datos del Préstamo', style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _codigoCtrl,
                        readOnly: codigoBloqueado,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: 'Código de Préstamo / Pagaré *',
                          hintText: 'Ej. PREST-001',
                          prefixIcon: const Icon(Icons.numbers),
                          errorText: _codigoDupMensaje,
                          helperText: codigoBloqueado
                              ? 'Asignado previamente'
                              : 'Identificador único del crédito.',
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'El código es obligatorio';
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
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                              if (_codigoSugerido != null &&
                                  _codigoCtrl.text.trim() != _codigoSugerido)
                                ActionChip(
                                  avatar: const Icon(Icons.auto_awesome, size: 14),
                                  label: Text('Usar $_codigoSugerido'),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _guardando ? null : _usarCodigoSugerido,
                                ),
                            ],
                          ),
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
                      Row(
                        children: [
                          Text('Moneda:', style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(width: 16),
                          ChoiceChip(
                            label: const Text('Córdobas (C\$)'),
                            selected: _moneda == 'NIO',
                            onSelected: (s) {
                              if (s) setState(() => _moneda = 'NIO');
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Dólares (US\$)'),
                            selected: _moneda == 'USD',
                            onSelected: (s) {
                              if (s) setState(() => _moneda = 'USD');
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── 2. CONDICIONES FINANCIERAS (CALCULADORA) ───────────────────
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.calculate_outlined, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('Condiciones del Préstamo', style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Monto y Tasa
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              controller: _montoCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: 'Monto a prestar (Capital) *',
                                prefixText: '$_simboloMoneda ',
                                prefixIcon: const Icon(Icons.attach_money),
                              ),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) return 'Requerido';
                                final n = double.tryParse(v.replaceAll(',', ''));
                                if (n == null || n <= 0) return 'Monto inválido';
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _interesCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(
                                labelText: 'Tasa de Interés *',
                                suffixText: '%',
                                prefixIcon: Icon(Icons.percent),
                              ),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) return 'Requerido';
                                final n = double.tryParse(v.replaceAll(',', ''));
                                if (n == null || n < 0) return 'Tasa inválida';
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Spacer(),
                          ChoiceChip(
                            label: const Text('Tasa Mensual'),
                            selected: _tasaEsMensual,
                            visualDensity: VisualDensity.compact,
                            onSelected: (s) => setState(() => _tasaEsMensual = true),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Tasa Total Crédito'),
                            selected: !_tasaEsMensual,
                            visualDensity: VisualDensity.compact,
                            onSelected: (s) => setState(() => _tasaEsMensual = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Frecuencia de cobro
                      Text('Frecuencia de Cobro', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final f in FrecuenciaPago.values) ...[
                              ChoiceChip(
                                label: Text(f.etiqueta),
                                selected: _frecuencia == f,
                                onSelected: (s) {
                                  if (s) {
                                    setState(() {
                                      _frecuencia = f;
                                      _fechaPrimerCobro =
                                          PrestamosCalculoService.sugerirPrimerPago(_fechaInicio, f);
                                    });
                                  }
                                },
                              ),
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Cuotas y Método
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _cuotasCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Número de Cuotas *',
                                prefixIcon: Icon(Icons.repeat),
                              ),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) return 'Requerido';
                                final n = int.tryParse(v);
                                if (n == null || n <= 0) return 'Mínimo 1 cuota';
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 3,
                            child: DropdownButtonFormField<MetodoCalculo>(
                              initialValue: _metodo,
                              decoration: const InputDecoration(
                                labelText: 'Método de Amortización',
                                prefixIcon: Icon(Icons.account_balance),
                              ),
                              items: MetodoCalculo.values.map((m) {
                                return DropdownMenuItem(
                                  value: m,
                                  child: Text(
                                    m == MetodoCalculo.interesFijo
                                        ? 'Interés Fijo (Microfinanzas)'
                                        : 'Cuota Nivelada (Francés)',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                );
                              }).toList(),
                              onChanged: (m) {
                                if (m != null) setState(() => _metodo = m);
                              },
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Fechas
                      Row(
                        children: [
                          Expanded(
                            child: _SelectorFecha(
                              label: 'Fecha de Desembolso',
                              fecha: _fechaInicio,
                              onChanged: (d) {
                                setState(() {
                                  _fechaInicio = d;
                                  _fechaPrimerCobro =
                                      PrestamosCalculoService.sugerirPrimerPago(d, _frecuencia);
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SelectorFecha(
                              label: 'Fecha Primer Cobro',
                              fecha: _fechaPrimerCobro,
                              onChanged: (d) => setState(() => _fechaPrimerCobro = d),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── 3. TARJETA DE RESUMEN EN TIEMPO REAL ────────────────────────
              Card(
                elevation: 1,
                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Resumen de la Cotización',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.table_chart, size: 16),
                            label: const Text('Ver Cronograma'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: calculo.cronograma.isNotEmpty
                                ? _mostrarDialogoCronograma
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _ResumenItem(
                              titulo: 'Cuota Periódica',
                              valor: '$_simboloMoneda ${fMoneda.format(calculo.montoCuota)}',
                              destacado: true,
                            ),
                          ),
                          Expanded(
                            child: _ResumenItem(
                              titulo: 'Interés Total',
                              valor: '$_simboloMoneda ${fMoneda.format(calculo.totalInteres)}',
                            ),
                          ),
                          Expanded(
                            child: _ResumenItem(
                              titulo: 'Total a Pagar',
                              valor: '$_simboloMoneda ${fMoneda.format(calculo.totalPagar)}',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Cronograma: ${calculo.plazoCuotas} cuotas ${calculo.frecuencia.etiqueta.toLowerCase()}s. '
                        'Vence del ${DateFormat('dd/MM/yyyy').format(calculo.fechaPrimerPago)} '
                        'al ${DateFormat('dd/MM/yyyy').format(calculo.fechaUltimaCuota)}.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── 4. NOTAS Y DOCUMENTOS ADJUNTOS ──────────────────────────────
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.description_outlined, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('Garantía y Documentos', style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _notasCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Notas del préstamo / Garantías (opcional)',
                          hintText: 'Detalles de prenda, aval fiduciario o destino del crédito...',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Pagaré o Contrato firmado (opcional)',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                Text(
                                  _docNombre != null
                                      ? 'Archivo adjunto: $_docNombre'
                                      : 'Podés adjuntar PDF, Word o foto del pagaré.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _docNombre != null
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_docBytes != null)
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              tooltip: 'Quitar archivo',
                              onPressed: () => setState(() {
                                _docBytes = null;
                                _docNombre = null;
                                _docMime = null;
                              }),
                            ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.attach_file),
                            label: Text(_docBytes == null ? 'Adjuntar' : 'Cambiar'),
                            onPressed: _guardando ? null : _adjuntarDoc,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // ── 5. BOTONES DE ACCIÓN ────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _guardando ? null : () => Navigator.of(context).maybePop(),
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
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: Text(
                        _guardando
                            ? 'Guardando...'
                            : (ref.watch(cobradorActualProvider).valueOrNull?.esAdminUsuarios ?? false)
                                ? 'Solicitar Aprobación'
                                : 'Crear Préstamo',
                      ),
                      onPressed: _guardando ? null : _guardar,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResumenItem extends StatelessWidget {
  const _ResumenItem({
    required this.titulo,
    required this.valor,
    this.destacado = false,
  });

  final String titulo;
  final String valor;
  final bool destacado;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titulo,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          valor,
          style: TextStyle(
            fontSize: destacado ? 16 : 14,
            fontWeight: FontWeight.bold,
            color: destacado
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurface,
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
    return TextFormField(
      controller: _ctrl,
      readOnly: true,
      enabled: widget.enabled,
      decoration: const InputDecoration(
        labelText: 'Prestatario / Cliente *',
        hintText: 'Toca para buscar cliente...',
        prefixIcon: Icon(Icons.person_outline),
        suffixIcon: Icon(Icons.arrow_drop_down),
      ),
      onTap: widget.enabled ? _elegirCliente : null,
      validator: (_) => widget.clienteId == null ? 'Seleccioná un cliente' : null,
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
        final d = await showDatePicker(
          context: context,
          initialDate: fecha,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (d != null) onChanged(d);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today, size: 20),
        ),
        child: Text(DateFormat('dd/MM/yyyy').format(fecha)),
      ),
    );
  }
}
