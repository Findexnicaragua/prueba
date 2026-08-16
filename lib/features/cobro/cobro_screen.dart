import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:image_picker/image_picker.dart';

import '../../data/models/cuota.dart';
import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/foto_comprobante_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/cuotas_repo.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/cobro_calculo.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/montos.dart';
import '../../powersync/db.dart' as ps;
import '../contratos/suspension_dialogs.dart' show ReactivarContratoDialog;
import '../recibo/recibo_cargos.dart' show cargoEtiquetaRecibo;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/selector_fecha_rapido.dart';
import '../shared/widgets/impersonation_banner.dart';

class CobroScreen extends ConsumerStatefulWidget {
  const CobroScreen({super.key, required this.cuotaIds});
  final List<String> cuotaIds;

  @override
  ConsumerState<CobroScreen> createState() => _CobroScreenState();
}

class _CobroScreenState extends ConsumerState<CobroScreen> {
  final _formKey = GlobalKey<FormState>();
  final _montoCtrl = TextEditingController();
  final _referenciaCtrl = TextEditingController();
  final _notasCtrl = TextEditingController();

  Moneda _moneda = Moneda.nio;
  MetodoPago _metodo = MetodoPago.efectivo;
  bool _enviando = false;
  String? _error;

  // Multi-cuota: lista de cuotas y sus totales a cobrar.
  final List<Cuota> _cuotas = [];
  // Total por cuota SEGÚN LA DB (cuota ± cargos ya persistidos). Los cargos
  // pendientes de esta pantalla (auto + manuales) se aplican encima en
  // _recalcularTotales() — nada se graba hasta confirmar el cobro.
  final List<double> _totalesBase = [];
  final List<double> _totalesACobrar = [];
  // Día de pago del contrato de cada cuota (paralela a _cuotas). Sirve para
  // derivar el "mes de servicio" en las tarjetas. null = cuota manual.
  final List<int?> _diasPago = [];
  Map<String, dynamic>? _clienteRow;
  double? _tasaSnapshot;
  String? _fotoPath;
  DateTime _fechaCobro = DateTime.now();

  // C3/C4: cargos automáticos detectados (reconexión / pronto pago). Se
  // insertan recién al confirmar el cobro (con pago_id) — abandonar la
  // pantalla no deja rastro.
  final List<_CargoAutoPreview> _cargosAuto = [];
  // Cargos/descuentos YA aplicados a la cuota (DB) — el cobro los muestra
  // como REFERENCIA (rediseño 2026-06-12: acá no se crea nada; descuentos
  // y cargos los gestiona el admin desde el detalle del contrato).
  final List<Map<String, dynamic>> _cargosExistentes = [];

  bool _cargaFallida = false;
  bool get _esMultiCuota => widget.cuotaIds.length > 1;

  @override
  void initState() {
    super.initState();
    // Si la carga inicial lanza (ClosedException por recreación de DB al cambiar
    // de usuario/impersonación, query transitoria offline…) NO dejamos la
    // pantalla de cobro girando para siempre (reglas #7/#9): mostramos el estado
    // de error con "Volver" (el mismo EmptyState que "Cuota no encontrada").
    _cargar().catchError((Object e) {
      if (mounted) setState(() => _cargaFallida = true);
    });
  }

  void _cambiarMoneda(Moneda nueva, AppSettings settings) {
    if (nueva == _moneda) return;
    setState(() {
      _moneda = nueva;
      _tasaSnapshot = settings.tasaUsd;
      // Reset del campo: si el cobrador escribió "500" en NIO y cambia a USD,
      // 500 USD ≠ 500 NIO (sería cobrar 36× más). Forzamos re-ingresar.
      _montoCtrl.clear();
    });
  }

  Future<void> _cargar() async {
    final repo = ref.read(cuotasRepoProvider);
    final settings = ref.read(appSettingsProvider);
    final cuotas = <Cuota>[];
    final totales = <double>[];
    // Día de pago del contrato de cada cuota — para el mes de servicio en las
    // tarjetas. null para cuotas manuales (sin contrato).
    final dias = <int?>[];

    for (final id in widget.cuotaIds) {
      final cuota = await repo.getById(id);
      if (cuota == null) continue;
      cuotas.add(cuota);
      totales.add(await repo.totalACobrar(id));
      int? diaPago;
      if (cuota.contratoId != null) {
        final ctRows = await ps.db.getAll(
          'SELECT dia_pago FROM contratos WHERE id = ?',
          [cuota.contratoId],
        );
        if (ctRows.isNotEmpty) {
          diaPago = (ctRows.first['dia_pago'] as num?)?.toInt();
        }
      }
      dias.add(diaPago);
    }
    if (cuotas.isEmpty) {
      if (mounted) setState(() => _cargaFallida = true);
      return;
    }

    final cliRows = await ps.db.getAll(
      '''
      SELECT c.nombre, c.cedula, c.telefono, co.nombre AS comunidad
        FROM clientes c
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE c.id = ?
      ''',
      [cuotas.first.clienteId],
    );

    // C3: detectar cuotas vencidas que necesitan cargo reconexión.
    final cargos = <_CargoAutoPreview>[];
    if (settings.reconexionHabilitada && settings.montoReconexion > 0) {
      final diasGracia = settings.diasGracia;
      // Día local de Nicaragua (UTC-6, sin DST): no sugerir cargos en el borde
      // del día según el reloj/zona del dispositivo (audit 2026-06-24, regla 1b).
      final ahoraNic = DateTime.now().toUtc().subtract(const Duration(hours: 6));
      final hoy = DateTime(ahoraNic.year, ahoraNic.month, ahoraNic.day);
      for (final cu in cuotas) {
        final vence = cu.fechaVencimiento;
        final diasPasados = hoy.difference(vence).inDays;
        if (diasPasados > diasGracia &&
            (cu.estado == CuotaEstado.pendiente || cu.estado == CuotaEstado.parcial)) {
          // Verificar que no haya ya un cargo reconexión para esta cuota.
          final existing = await ps.db.getAll(
            "SELECT id FROM cargos_extra WHERE cuota_id = ? AND tipo = 'reconexion'",
            [cu.id],
          );
          if (existing.isEmpty) {
            cargos.add(_CargoAutoPreview(
              cuotaId: cu.id,
              tipo: 'reconexion',
              monto: settings.montoReconexion,
              descripcion: 'Cargo por reconexión',
            ));
          }
        }
      }
    }

    // C4: detectar pago adelantado para descuento pronto pago.
    final descuento = settings.descuentoProntoPago;
    if (descuento > 0) {
      final esPorcentaje = settings.descuentoProntoPagoTipo == 'porcentaje';
      // Día local de Nicaragua (UTC-6) para el adelanto (regla 1b).
      final ahoraNic = DateTime.now().toUtc().subtract(const Duration(hours: 6));
      final hoy = DateTime(ahoraNic.year, ahoraNic.month, ahoraNic.day);
      for (var i = 0; i < cuotas.length; i++) {
        final cu = cuotas[i];
        if (hoy.isBefore(cu.fechaVencimiento)) {
          // Verificar que no haya ya un descuento (manual o automático).
          final existing = await ps.db.getAll(
            "SELECT id FROM cargos_extra WHERE cuota_id = ? AND tipo IN ('descuento_monto','descuento_porcentaje')",
            [cu.id],
          );
          if (existing.isEmpty) {
            final montoDescuento = esPorcentaje
                ? cuotas[i].monto * descuento / 100
                : descuento;
            cargos.add(_CargoAutoPreview(
              cuotaId: cu.id,
              tipo: esPorcentaje ? 'descuento_porcentaje' : 'descuento_monto',
              monto: montoDescuento,
              porcentaje: esPorcentaje ? descuento : null,
              descripcion: 'Descuento pronto pago',
            ));
          }
        }
      }
    }

    // Cargos YA aplicados (referencia, single-cuota): el cobrador los ve
    // con motivo en un sheet de solo-lectura.
    final existentes = widget.cuotaIds.length == 1
        ? await ref.read(cuotasRepoProvider).cargosDeCuota(widget.cuotaIds.first)
        : const <Map<String, dynamic>>[];

    if (!mounted) return;
    setState(() {
      _cuotas.addAll(cuotas);
      _totalesBase.addAll(totales);
      _totalesACobrar.addAll(List.filled(totales.length, 0.0));
      _diasPago.addAll(dias);
      _clienteRow = cliRows.isEmpty ? null : cliRows.first;
      _cargosAuto.addAll(cargos);
      _cargosExistentes.addAll(existentes);
      // Aplica los cargos automáticos sobre los totales base y deja el
      // monto default = saldo completo de todas las cuotas.
      _recalcularTotales();
    });
  }

  /// Re-deriva `_totalesACobrar` desde los totales base de DB + cargos
  /// automáticos pendientes, y resetea el monto sugerido al saldo completo
  /// EN LA MONEDA ACTIVA (audit F4: pisarlo siempre en C$ con USD elegido
  /// convertía el saldo en un monto US$ ~36× — vuelto fantasma gigante).
  void _recalcularTotales() {
    for (var i = 0; i < _cuotas.length; i++) {
      var t = _totalesBase[i];
      for (final c in _cargosAuto) {
        if (c.cuotaId != _cuotas[i].id) continue;
        if (c.tipo == 'reconexion' || c.tipo == 'otro') {
          t += c.monto;
        } else {
          t = (t - c.monto).clamp(0.0, double.infinity);
        }
      }
      _totalesACobrar[i] = t;
    }
    var saldo = 0.0;
    for (var i = 0; i < _cuotas.length; i++) {
      saldo +=
          (_totalesACobrar[i] - _cuotas[i].montoPagado).clamp(0.0, double.infinity);
    }
    final tasa = _moneda == Moneda.usd
        ? (_tasaSnapshot ?? ref.read(appSettingsProvider).tasaUsd)
        : 1.0;
    _montoCtrl.text = (saldo / (tasa <= 0 ? 1.0 : tasa)).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _referenciaCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  /// Sheet de REFERENCIA (solo lectura, rediseño 2026-06-12): muestra los
  /// descuentos/cargos que la cuota ya tiene aplicados (con su motivo) y
  /// los automáticos que se van a aplicar al confirmar este cobro. Acá no
  /// se crea nada — descuentos y cargos los gestiona el admin desde el
  /// detalle del contrato.
  void _verCargosCuota() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        Widget linea(String etiqueta, double monto, bool esDescuento,
            {String? nota}) {
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              esDescuento ? Icons.discount : Icons.add_circle_outline,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              '$etiqueta  ${esDescuento ? '−' : '+'}${Fmt.cordobas(monto)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: nota == null ? null : Text(nota),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Descuentos y cargos de la cuota',
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Referencia de lo aplicado al cliente. Los descuentos y '
                  'cargos los gestiona el admin desde el contrato.',
                  style: Theme.of(sheetCtx)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 8),
                if (_cargosExistentes.isEmpty && _cargosAuto.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('Sin descuentos ni cargos.',
                        style: TextStyle(color: scheme.outline)),
                  ),
                for (final c in _cargosExistentes)
                  linea(
                    cargoEtiquetaRecibo(c, conMotivo: true),
                    (c['monto'] as num? ?? 0).toDouble(),
                    (c['tipo'] as String? ?? '').startsWith('descuento'),
                  ),
                for (final c in _cargosAuto)
                  linea(
                    c.descripcion,
                    c.monto,
                    c.tipo.startsWith('descuento'),
                    nota: 'Se aplica al confirmar este cobro',
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Confirma el descarte si hay datos cargados. Devuelve true si se puede
  /// salir. Compartido por el botón Cancelar y el back del sistema (PopScope).
  Future<bool> _confirmarDescarte() async {
    final v = parseMonto(_montoCtrl.text);
    final hayDatos = v != null && v > 0;
    final tieneFoto = _fotoPath != null;
    final tieneRef = _referenciaCtrl.text.trim().isNotEmpty;
    if (!hayDatos && !tieneFoto && !tieneRef) return true;
    // El aviso enumera SOLO lo que de verdad se pierde (audit F4: el texto
    // fijo mencionaba pérdidas que no existían y desgastaba el aviso).
    final perdidas = [
      if (hayDatos) 'el monto',
      if (tieneFoto) 'la foto',
      if (tieneRef) 'la referencia',
    ];
    final lista = perdidas.length == 1
        ? perdidas.first
        : '${perdidas.sublist(0, perdidas.length - 1).join(', ')} y ${perdidas.last}';
    final descartar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Descartar cobro?'),
        content:
            Text('Vas a perder $lista. Esta cuota queda sin cobrar.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Seguir editando'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    return descartar == true;
  }

  Future<void> _cancelar(BuildContext context) async {
    if (await _confirmarDescarte() && context.mounted) context.pop();
  }

  Future<void> _confirmar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_cuotas.isEmpty) return;
    // Guard (#9): el super_admin impersonando NO puede registrar cobros — el
    // pago se atribuiría a su fila real (tenant System), no al impersonado,
    // generando pagos/recibos huérfanos. La UI ya deshabilita el botón; esto
    // es defensa en profundidad.
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se puede registrar cobros mientras gestionás un tenant como super_admin.');
      return;
    }
    final cobrador = ref.read(cobradorActualProvider).valueOrNull;
    if (cobrador == null || cobrador.prefijoRecibo == null) {
      setState(() => _error = 'No tenés prefijo de recibo asignado. Pedile al admin que te lo configure.');
      return;
    }
    final settings = ref.read(appSettingsProvider);
    final tasa = _moneda == Moneda.usd
        ? (_tasaSnapshot ?? settings.tasaUsd)
        : 1.0;

    // P3: si el tenant exige foto del comprobante, no dejar confirmar sin foto.
    // Solo aplica a métodos con comprobante — en efectivo el picker no se
    // muestra y _fotoPath siempre es null, así que no bloqueamos ahí.
    if (settings.comprobanteHabilitado &&
        settings.fotoObligatoria &&
        _metodo.requiereComprobante &&
        _fotoPath == null) {
      setState(() => _error =
          'La foto del comprobante es obligatoria para este método de pago.');
      return;
    }
    // P4: si el tenant no permite pago parcial, exigir cubrir el saldo
    // completo de la cuota.
    if (!settings.pagoParcialPermitido && !_esMultiCuota) {
      final saldoCuota = (_totalesACobrar.first - _cuotas.first.montoPagado)
          .clamp(0.0, double.infinity);
      final entregadoCordobas =
          CobroCalculo.aCordobas(parseMonto(_montoCtrl.text) ?? 0, tasa);
      if (entregadoCordobas < saldoCuota - 0.01) {
        setState(() => _error =
            'No se permite pago parcial: cobrá el total de ${Fmt.cordobas(saldoCuota)}.');
        return;
      }
    }
    // Multi-cuota: cada cuota se cobra completa (sin pago parcial repartido).
    // El monto entregado puede ser MAYOR al total (genera vuelto), pero nunca
    // menor: no tendría sentido un parcial distribuido entre varias cuotas.
    if (_esMultiCuota) {
      var totalSaldo = 0.0;
      for (var i = 0; i < _cuotas.length; i++) {
        totalSaldo += (_totalesACobrar[i] - _cuotas[i].montoPagado)
            .clamp(0.0, double.infinity);
      }
      final entregadoCordobas =
          CobroCalculo.aCordobas(parseMonto(_montoCtrl.text) ?? 0, tasa);
      if (entregadoCordobas < totalSaldo - 0.01) {
        setState(() => _error =
            'En cobro múltiple cada cuota se paga completa: el monto no puede '
            'ser menor al total de ${Fmt.cordobas(totalSaldo)}.');
        return;
      }
    }

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      final CobroResultado result;
      if (_esMultiCuota) {
        // Multi-cuota: cada cuota se cobra COMPLETA (su saldo entra a la caja
        // del ISP). Si el entregado supera el total, el excedente es vuelto —en
        // córdobas— imputado al ÚLTIMO pago del grupo. Funciona en NIO y en USD
        // (una sola tasa para toda la transacción). La distribución (montos
        // aplicados + montos en moneda original + vuelto) vive en CobroCalculo,
        // testeada — respeta los invariantes de dinero #1/#4 (el vuelto NUNCA
        // infla monto_cordobas).
        final saldos = <double>[
          for (var i = 0; i < _cuotas.length; i++)
            (_totalesACobrar[i] - _cuotas[i].montoPagado)
                .clamp(0.0, double.infinity)
        ];
        final dist = CobroCalculo.distribuirMulti(
          saldosCordobas: saldos,
          entregadoCordobas:
              // El validator del form ya garantizó que parsea (M8: con coma).
              CobroCalculo.aCordobas(parseMonto(_montoCtrl.text)!, tasa),
          tasa: tasa,
        );

        final cargosInfo = _cargosAuto
            .map((c) => CargoAutoInfo(
                  cuotaId: c.cuotaId,
                  tipo: c.tipo,
                  monto: c.monto,
                  porcentaje: c.porcentaje,
                  descripcion: c.descripcion,
                ))
            .toList();

        result = await ref.read(pagosRepoProvider).registrarCobroMultiple(
              tenantId: cobrador.tenantId,
              cobradorId: cobrador.id,
              prefijoRecibo: cobrador.prefijoRecibo!,
              cuotaIds: _cuotas.map((c) => c.id).toList(),
              montosCordobas: dist.montosCordobas,
              vueltoCordobas: dist.vueltoCordobas,
              moneda: _moneda,
              montosOriginal: dist.montosOriginal,
              tasaConversion: tasa,
              metodo: _metodo,
              referencia: _referenciaCtrl.text.trim().isEmpty
                  ? null
                  : _referenciaCtrl.text.trim(),
              fotoComprobantePath: _fotoPath,
              lat: null,
              lng: null,
              notas: _notasCtrl.text.trim().isEmpty
                  ? null
                  : _notasCtrl.text.trim(),
              fechaPago: _fechaCobro,
              cargosAuto: cargosInfo.isEmpty ? null : cargosInfo,
            );
      } else {
        // Single cuota: el field _montoCtrl tiene lo ENTREGADO por el cliente.
        // El aplicado a la cuota se trunca al saldo real (sin vuelto se
        // inflaba recaudado del ISP). El exceso se guarda como vuelto.
        // Regla de negocio: el vuelto SIEMPRE se da en córdobas, incluso
        // si el cliente pagó en USD. monto_original preserva lo entregado
        // en la moneda original (US$30 si pagó 30 dólares), no el aplicado.
        // La matemática vive en CobroCalculo (puro + testeado).
        final entregado = parseMonto(_montoCtrl.text)!;
        final saldoCuota = (_totalesACobrar.first - _cuotas.first.montoPagado)
            .clamp(0.0, double.infinity);
        final dist = CobroCalculo.calcular(
          entregadoCordobas: CobroCalculo.aCordobas(entregado, tasa),
          saldoCordobas: saldoCuota,
        );
        final aplicadoCordobas = dist.aplicadoCordobas;
        final vueltoCordobas = dist.vueltoCordobas;
        // monto_original = lo entregado en la moneda original (NO el aplicado).
        // Invariante: monto_original * tasa ≈ monto_cordobas + vuelto_cordobas.
        final montoOriginalEntregado = entregado;

        final cargosInfo = _cargosAuto
            .map((c) => CargoAutoInfo(
                  cuotaId: c.cuotaId,
                  tipo: c.tipo,
                  monto: c.monto,
                  porcentaje: c.porcentaje,
                  descripcion: c.descripcion,
                ))
            .toList();

        result = await ref.read(pagosRepoProvider).registrarCobro(
              tenantId: cobrador.tenantId,
              cobradorId: cobrador.id,
              prefijoRecibo: cobrador.prefijoRecibo!,
              cuotaId: _cuotas.first.id,
              montoCordobas: aplicadoCordobas,
              vueltoCordobas: vueltoCordobas,
              moneda: _moneda,
              montoOriginal: montoOriginalEntregado,
              tasaConversion: tasa,
              metodo: _metodo,
              referencia: _referenciaCtrl.text.trim().isEmpty
                  ? null
                  : _referenciaCtrl.text.trim(),
              fotoComprobantePath: _fotoPath,
              lat: null,
              lng: null,
              notas: _notasCtrl.text.trim().isEmpty
                  ? null
                  : _notasCtrl.text.trim(),
              fechaPago: _fechaCobro,
              cargosAuto: cargosInfo.isEmpty ? null : cargosInfo,
            );
      }

      if (!mounted) return;

      // Aviso post-cobro (recuperación / fuera de ruta, 2026-07-01): si el cobro
      // dejó en CERO la deuda de un contrato SUSPENDIDO, avisamos que sigue
      // pendiente de reactivar — pagar NO reactiva el servicio (es acción de
      // admin). Con botón directo a Reactivar si el usuario es admin. Best-effort:
      // nunca bloquea el paso al recibo.
      await _avisarSuspendidoSaldado(
          esAdmin: cobrador.tieneAccesoAdmin || cobrador.esAdminCobranza);

      if (!mounted) return;

      if (result.esMultiCuota) {
        // Multi-cuota: navegar al primer recibo (el screen agrupa por grupo_cobro).
        context.pushReplacement('/recibo/${result.reciboId}?grupo=${result.grupoCobro}');
      } else {
        context.pushReplacement('/recibo/${result.reciboId}');
      }
    } catch (e) {
      if (!mounted) return;
      // M14: e.toString() crudo confundía al cobrador; el detalle técnico
      // queda en debugPrint dentro del helper.
      setState(
          () => _error = mensajeErrorHumano(e, contexto: 'registrar el cobro'));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  /// Tras un cobro, si quedó en CERO la deuda de un contrato SUSPENDIDO de las
  /// cuotas cobradas, muestra un aviso: pagar NO reactiva el servicio (lo hace
  /// el admin). Si `esAdmin`, ofrece "Reactivar ahora" (abre el diálogo estándar
  /// de reactivación). El saldo se lee del mirror local (registrarCobro espeja
  /// monto_pagado/estado en la misma writeTransaction) → confiable offline. Es
  /// best-effort: cualquier error se traga para no bloquear el paso al recibo.
  Future<void> _avisarSuspendidoSaldado({required bool esAdmin}) async {
    // Best-effort de PUNTA A PUNTA: nada acá (ni el getAll ni los showDialog)
    // debe bloquear el paso al recibo — el cobro ya está guardado. Cualquier
    // throw se traga; el recibo se muestra igual.
    try {
      final ids = _cuotas.map((c) => c.id).toList();
      if (ids.isEmpty) return;
      final ph = List.filled(ids.length, '?').join(', ');
      final rows = await ps.db.getAll('''
        SELECT ct.id AS contrato_id, c.nombre AS cliente_nombre,
               COALESCE(p.precio_mensual, 0) AS precio_mensual,
               COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0)
                                       - COALESCE(cu.monto_pagado, 0), 0))
                           FROM cuotas cu
                          WHERE cu.contrato_id = ct.id
                            AND cu.estado IN ('pendiente', 'parcial')), 0) AS saldo
          FROM contratos ct
          JOIN clientes c ON c.id = ct.cliente_id
     LEFT JOIN planes p ON p.id = ct.plan_id
         WHERE ct.estado = 'suspendido'
           AND ct.id IN (
             SELECT DISTINCT contrato_id FROM cuotas
              WHERE id IN ($ph) AND contrato_id IS NOT NULL)
      ''', ids);

      final saldados = [
        for (final r in rows)
          if (((r['saldo'] as num?)?.toDouble() ?? 0) <= 0.005) r
      ];
      if (saldados.isEmpty || !mounted) return;

      final primero = saldados.first;
      final nombre = (primero['cliente_nombre'] as String?) ?? 'El cliente';
      final masDeUno = saldados.length > 1;
      final precio = (primero['precio_mensual'] as num?)?.toDouble() ?? 0;

      final irReactivar = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline),
          title: const Text('Deuda saldada'),
          content: Text(masDeUno
              ? 'Se saldó la deuda de ${saldados.length} contratos suspendidos. '
                  'Pagar NO reactiva el servicio: reactivalos desde Centro → Reactivar.'
              : 'La deuda de $nombre quedó en cero, pero su contrato sigue '
                  'SUSPENDIDO. Pagar no reactiva el servicio.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Entendido'),
            ),
            if (esAdmin && !masDeUno && precio > 0)
              FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('Reactivar ahora'),
              ),
          ],
        ),
      );

      if (irReactivar == true && mounted) {
        await showDialog<bool>(
          context: context,
          builder: (_) => ReactivarContratoDialog(
            contratoId: primero['contrato_id'] as String,
            precioMensual: precio,
          ),
        );
      }
    } catch (_) {
      // Best-effort: el aviso nunca bloquea el flujo de cobro.
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final impersonando = ref.watch(estaImpersonandoProvider);

    // Si el método seleccionado fue deshabilitado en settings, corregir
    // al primer método disponible para evitar un estado inválido.
    final metodosDisponibles = <MetodoPago>[
      if (settings.efectivoHabilitado) MetodoPago.efectivo,
      if (settings.transferenciaHabilitada) MetodoPago.transferencia,
      if (settings.tarjetaHabilitada) MetodoPago.tarjeta,
    ];
    if (metodosDisponibles.isNotEmpty && !metodosDisponibles.contains(_metodo)) {
      // Schedule después del build para evitar setState durante build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _metodo = metodosDisponibles.first);
      });
    }

    if (_cuotas.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cobrar')),
        body: _cargaFallida
            ? Center(
                child: EmptyState(
                  icon: Icons.error_outline,
                  titulo: 'Cuota no encontrada',
                  descripcion: 'La cuota pudo haber sido eliminada o anulada.',
                  accion: FilledButton(
                    onPressed: () => context.pop(),
                    child: const Text('Volver'),
                  ),
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final puedeConfirmar = !_enviando &&
        !impersonando &&
        cobrador != null &&
        (cobrador.prefijoRecibo ?? '').isNotEmpty;
    final mensajeDeshabilitado = impersonando
        ? 'Estás gestionando un tenant como super_admin. El cobro lo registra el cobrador del ISP — no se puede cobrar impersonando.'
        : cobrador == null
            ? 'Esperando datos del cobrador...'
            : (cobrador.prefijoRecibo ?? '').isEmpty
                ? 'Tu prefijo de recibo no está configurado. Pedile al admin que te lo asigne.'
                : null;

    final cuota = _cuotas.first;
    var saldo = 0.0;
    for (var i = 0; i < _cuotas.length; i++) {
      saldo += (_totalesACobrar[i] - _cuotas[i].montoPagado).clamp(0.0, double.infinity);
    }

    // Tasa EFECTIVA = la misma que usará _confirmar (#6b): el snapshot tomado
    // al elegir USD, no la tasa live de settings. Si la tasa cambia por sync
    // entre que el cobrador elige USD y confirma, el preview ("Equivalente")
    // y el monto persistido coinciden — sin divergencia.
    final tasaEfectiva =
        _moneda == Moneda.usd ? (_tasaSnapshot ?? settings.tasaUsd) : 1.0;
    final montoEnNio = (parseMonto(_montoCtrl.text) ?? 0) * tasaEfectiva;

    final esCompleto = montoEnNio >= saldo - 0.01;

    // PopScope (fix audit #6): el back del sistema (gesto Android / flecha)
    // pasaba de largo y descartaba monto/foto/referencia sin confirmar —
    // solo el botón Cancelar preguntaba. Misma confirmación para ambos.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _enviando) return;
        final salir = await _confirmarDescarte();
        // El guard esta en la misma linea (`&& mounted`): el context del closure
        // es el parametro de `build`, que en un State ES el mismo Element que
        // `State.context`, o sea justo el que `mounted` protege.
        // ignore: use_build_context_synchronously
        if (salir && mounted) context.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(
          _esMultiCuota
              ? 'Cobro múltiple (${_cuotas.length} cuotas)'
              : _clienteRow?['nombre'] ?? 'Cobrar',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          // Banner de impersonación (#9a): visible si el super_admin entró a
          // un tenant; self-gating (invisible si no impersona).
          const ImpersonationBanner(),
          if (_esMultiCuota)
            _MultiCuotaCard(
              cliente: _clienteRow,
              cuotas: _cuotas,
              totales: _totalesACobrar,
              diasPago: _diasPago,
            )
          else
            _ClienteCuotaCard(
                cliente: _clienteRow,
                cuota: cuota,
                totalACobrar: _totalesACobrar.first,
                diaPago: _diasPago.first),
          // Cargos automáticos que ESTE cobro va a insertar al confirmar
          // (reconexión / pronto pago).
          if (_cargosAuto.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final cargo in _cargosAuto)
              Card(
                color: cargo.tipo.startsWith('descuento')
                    ? Theme.of(context).colorScheme.tertiaryContainer
                    : Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        cargo.tipo.startsWith('descuento')
                            ? Icons.discount
                            : Icons.add_circle_outline,
                        size: 18,
                        color: cargo.tipo.startsWith('descuento')
                            ? Theme.of(context).colorScheme.onTertiaryContainer
                            : Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(cargo.descripcion)),
                      Text(
                        '${cargo.tipo.startsWith('descuento') ? '-' : '+'}${Fmt.cordobas(cargo.monto)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          // Rediseño 2026-06-12 (decisión Rubén): el cobro NO crea
          // descuentos ni cargos — solo referencia lo aplicado. La gestión
          // vive en el detalle del contrato (sheet de la cuota).
          if (!_esMultiCuota &&
              (_cargosExistentes.isNotEmpty || _cargosAuto.isNotEmpty)) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.discount),
              label: const Text('Ver descuentos y cargos'),
              onPressed: _verCargosCuota,
            ),
          ],

          const SizedBox(height: 24),
          Text('Método de pago', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _MetodosWrap(
            actual: _metodo,
            settings: settings,
            onSelected: (m) {
              setState(() {
                _metodo = m;
                // Si el método ya no requiere comprobante, descartar
                // la foto adjunta para no asociarla a un pago en efectivo.
                if (!m.requiereComprobante) _fotoPath = null;
                // USD solo es válido con efectivo (plata en mano). Al cambiar a
                // otro método, forzar córdobas + limpiar monto/snapshot (igual
                // que _cambiarMoneda) para que no quede un monto en USD colgado.
                if (m != MetodoPago.efectivo && _moneda != Moneda.nio) {
                  _moneda = Moneda.nio;
                  _tasaSnapshot = null;
                  _montoCtrl.clear();
                }
              });
            },
          ),

          const SizedBox(height: 24),
          Row(
            children: [
              Text('Monto', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              // Toggle de moneda (C$/US$), visible si el tenant habilitó USD.
              // Funciona igual en single y multi-cuota: una sola tasa para toda
              // la transacción; la distribución multi vive en
              // CobroCalculo.distribuirMulti (pura + testeada).
              // USD solo con efectivo: el dólar es plata en mano (no hay
              // transferencias en USD en este flujo). Con otro método, NIO fijo.
              if (settings.usdHabilitado && _metodo == MetodoPago.efectivo)
                _MonedaToggle(
                  actual: _moneda,
                  onChanged: (m) => _cambiarMoneda(m, settings),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _montoCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              montoInputFormatter, // dígitos + coma/punto (M8)
            ],
            decoration: InputDecoration(
              prefixText: '${_moneda.symbol} ',
              hintText: '0.00',
              helperText: _esMultiCuota
                  ? 'Total de las cuotas. Si el cliente entrega más, el exceso se devuelve como vuelto.'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Ingresá un monto';
              final n = parseMonto(v);
              if (n == null || n <= 0) return 'Monto inválido';
              return null;
            },
          ),
          if (_moneda == Moneda.usd)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Equivalente: ${Fmt.cordobas(montoEnNio)} (tasa ${tasaEfectiva.toStringAsFixed(2)})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),

          if (_metodo.requiereComprobante) ...[
            const SizedBox(height: 24),
            TextFormField(
              controller: _referenciaCtrl,
              decoration: const InputDecoration(
                labelText: 'Número de referencia / confirmación',
              ),
              validator: (v) {
                final hayFoto = _fotoPath != null;
                final hayRef = (v ?? '').trim().isNotEmpty;
                // Con foto-comprobante habilitada (super_admin): referencia O
                // foto. Sin ella (default): solo se exige la referencia.
                if (!hayRef && !(settings.comprobanteHabilitado && hayFoto)) {
                  return settings.comprobanteHabilitado
                      ? 'Ingresá referencia o adjuntá foto'
                      : 'Ingresá el número de referencia';
                }
                return null;
              },
            ),
            // Foto del comprobante: solo si el super_admin la habilitó para el
            // tenant (default OFF → la transferencia guarda solo la referencia,
            // cero consumo de disco).
            if (settings.comprobanteHabilitado) ...[
              const SizedBox(height: 12),
              _FotoComprobantePicker(
                path: _fotoPath,
                onPicked: (p) => setState(() => _fotoPath = p),
              ),
            ],
          ],

          const SizedBox(height: 24),
          TextFormField(
            controller: _notasCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
            ),
          ),

          // Fecha del cobro: editable si el admin lo habilitó.
          if (settings.cobradorEditaFecha) ...[
            const SizedBox(height: 16),
            InkWell(
              onTap: () async {
                final picked = await elegirFechaRapida(
                  context,
                  initialDate: _fechaCobro,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setState(() => _fechaCobro = picked);
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Fecha del cobro',
                  prefixIcon: Icon(Icons.calendar_today),
                ),
                child: Text(Fmt.fechaCorta(_fechaCobro)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _ResumenCard(
            saldoActual: saldo,
            aCobrar: montoEnNio,
            esCompleto: esCompleto,
            cantidadCuotas: _cuotas.length,
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ],

          const SizedBox(height: 24),
          if (mensajeDeshabilitado != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                mensajeDeshabilitado,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _enviando ? null : () => _cancelar(context),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: puedeConfirmar ? _confirmar : null,
                  icon: _enviando
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(_enviando
                      ? 'Procesando...'
                      : _esMultiCuota
                          ? 'Confirmar ${_cuotas.length} cuotas'
                          : 'Confirmar cobro'),
                ),
              ),
            ],
          ),
        ],
        ),
      ),
      ),
    );
  }
}

class _ClienteCuotaCard extends StatelessWidget {
  const _ClienteCuotaCard({
    required this.cliente,
    required this.cuota,
    required this.totalACobrar,
    required this.diaPago,
  });

  final Map<String, dynamic>? cliente;
  final Cuota cuota;
  final double totalACobrar;
  // Día de pago del contrato — para el mes de servicio. null = manual.
  final int? diaPago;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cliente?['nombre'] ?? '—',
                style: Theme.of(context).textTheme.titleMedium),
            if (cliente?['comunidad'] != null)
              Text(cliente!['comunidad'] as String,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const Divider(height: 24),
            Row(
              children: [
                // Cuota MANUAL (cobro puntual): ícono de caja + el concepto
                // (descripción) en vez de "Cobro de <mes>", que no aplica a un
                // cargo de una vez (audit 0173).
                Icon(cuota.esManual ? Icons.point_of_sale : Icons.calendar_today,
                    size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    cuota.esManual
                        ? (cuota.descripcion ?? 'Cobro puntual')
                        : 'Cobro de ${Fmt.mesServicioLabel(cuota.periodo, diaPago)}',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(Fmt.cordobas(cuota.monto),
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Text(
                'Fecha de cobro: ${Fmt.fechaCorta(cuota.fechaVencimiento)}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
              ),
            ),
            if (Fmt.periodoServicioRango(diaPago, cuota.fechaVencimiento) != null)
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Text(
                  'Periodo: '
                  '${Fmt.periodoServicioRango(diaPago, cuota.fechaVencimiento)}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
                ),
              ),
            if (totalACobrar != cuota.monto) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 36),
                  Expanded(
                    child: Text(
                      'Con descuentos/cargos: ${Fmt.cordobas(totalACobrar)}',
                      style:
                          TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ],
            if (cuota.montoPagado > 0) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 36),
                  Text(
                    'Ya pagado: ${Fmt.cordobas(cuota.montoPagado)}',
                    style: TextStyle(color: scheme.tertiary, fontSize: 15),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MultiCuotaCard extends StatelessWidget {
  const _MultiCuotaCard({
    required this.cliente,
    required this.cuotas,
    required this.totales,
    required this.diasPago,
  });
  final Map<String, dynamic>? cliente;
  final List<Cuota> cuotas;
  final List<double> totales;
  // Día de pago por cuota (paralela a cuotas). null = manual.
  final List<int?> diasPago;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var totalGeneral = 0.0;
    for (var i = 0; i < cuotas.length; i++) {
      totalGeneral += (totales[i] - cuotas[i].montoPagado).clamp(0.0, double.infinity);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cliente?['nombre'] ?? '—',
                style: Theme.of(context).textTheme.titleMedium),
            if (cliente?['comunidad'] != null)
              Text(cliente!['comunidad'] as String,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const Divider(height: 24),
            Text('${cuotas.length} cobros seleccionados',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                )),
            const SizedBox(height: 8),
            for (var i = 0; i < cuotas.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Cobro ${Fmt.mesServicioLabel(cuotas[i].periodo, diasPago[i])}',
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          Fmt.cordobas((totales[i] - cuotas[i].montoPagado).clamp(0.0, double.infinity)),
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 28),
                      child: Text(
                        'Fecha de cobro: ${Fmt.fechaCorta(cuotas[i].fechaVencimiento)}',
                        style:
                            TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                      ),
                    ),
                    if (Fmt.periodoServicioRango(diasPago[i], cuotas[i].fechaVencimiento) != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 28),
                        child: Text(
                          'Periodo: '
                          '${Fmt.periodoServicioRango(diasPago[i], cuotas[i].fechaVencimiento)}',
                          style:
                              TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 16),
            Row(
              children: [
                Text('Total a cobrar',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    )),
                const Spacer(),
                Text(Fmt.cordobas(totalGeneral),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      fontSize: 16,
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetodosWrap extends StatelessWidget {
  const _MetodosWrap({
    required this.actual,
    required this.settings,
    required this.onSelected,
  });

  final MetodoPago actual;
  final AppSettings settings;
  final ValueChanged<MetodoPago> onSelected;

  @override
  Widget build(BuildContext context) {
    final disponibles = <MetodoPago>[
      if (settings.efectivoHabilitado) MetodoPago.efectivo,
      if (settings.transferenciaHabilitada) MetodoPago.transferencia,
      if (settings.tarjetaHabilitada) MetodoPago.tarjeta,
    ];

    return Wrap(
      spacing: 8,
      children: [
        for (final m in disponibles)
          ChoiceChip(
            label: Text(m.label),
            avatar: Icon(_icon(m), size: 18),
            selected: actual == m,
            onSelected: (_) => onSelected(m),
          ),
      ],
    );
  }

  IconData _icon(MetodoPago m) => switch (m) {
        MetodoPago.efectivo => Icons.payments,
        MetodoPago.transferencia => Icons.swap_horiz,
        MetodoPago.deposito => Icons.account_balance,
        MetodoPago.tarjeta => Icons.credit_card,
      };
}

class _MonedaToggle extends StatelessWidget {
  const _MonedaToggle({required this.actual, required this.onChanged});
  final Moneda actual;
  final ValueChanged<Moneda> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Moneda>(
      segments: const [
        ButtonSegment(value: Moneda.nio, label: Text('C\$')),
        ButtonSegment(value: Moneda.usd, label: Text('US\$')),
      ],
      selected: {actual},
      onSelectionChanged: (s) => onChanged(s.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }
}

class _FotoComprobantePicker extends ConsumerStatefulWidget {
  const _FotoComprobantePicker({required this.path, required this.onPicked});
  final String? path;
  final ValueChanged<String?> onPicked;

  @override
  ConsumerState<_FotoComprobantePicker> createState() =>
      _FotoComprobantePickerState();
}

class _FotoComprobantePickerState
    extends ConsumerState<_FotoComprobantePicker> {
  Uint8List? _bytes;

  @override
  void didUpdateWidget(covariant _FotoComprobantePicker old) {
    super.didUpdateWidget(old);
    if (widget.path != old.path) _resolverBytes();
  }

  @override
  void initState() {
    super.initState();
    // Caso sincrónico: path null → bytes null. No usar setState (pre-build).
    if (widget.path == null) {
      _bytes = null;
    } else {
      _resolverBytes();
    }
  }

  Future<void> _resolverBytes() async {
    final b = widget.path == null
        ? null
        : await ref
            .read(fotoComprobanteServiceProvider)
            .bytesLocal(widget.path);
    if (mounted) setState(() => _bytes = b);
  }

  // Capturando/comprimiendo la foto (0.3-3 s tras cerrar la cámara): muestra
  // spinner y bloquea reabrir el sheet en pleno cobro.
  bool _procesando = false;

  Future<void> _elegir(ImageSource source) async {
    if (_procesando) return;
    setState(() => _procesando = true);
    try {
      final p = await ref
          .read(fotoComprobanteServiceProvider)
          .capturar(source: source);
      if (p != null) widget.onPicked(p);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(mensajeErrorHumano(e, contexto: 'capturar'))),
        );
      }
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              _bytes!,
              height: 180,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Cambiar'),
                  onPressed: _procesando ? null : () => _mostrarFuente(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Quitar'),
                  onPressed: () => widget.onPicked(null),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return OutlinedButton.icon(
      icon: _procesando
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.camera_alt),
      label: Text(
          _procesando ? 'Procesando...' : 'Adjuntar foto del comprobante'),
      onPressed: _procesando ? null : _mostrarFuente,
    );
  }

  void _mostrarFuente() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Tomar foto'),
              onTap: () {
                Navigator.pop(ctx);
                _elegir(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Elegir de galería'),
              onTap: () {
                Navigator.pop(ctx);
                _elegir(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumenCard extends StatelessWidget {
  const _ResumenCard({
    required this.saldoActual,
    required this.aCobrar,
    required this.esCompleto,
    this.cantidadCuotas = 1,
  });

  final double saldoActual;
  final double aCobrar;
  final bool esCompleto;
  final int cantidadCuotas;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saldoFinal = (saldoActual - aCobrar).clamp(0, double.infinity);
    final vuelto = aCobrar > saldoActual ? aCobrar - saldoActual : 0.0;
    return Card(
      color: esCompleto ? scheme.tertiaryContainer : scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _row('Saldo total${cantidadCuotas > 1 ? ' ($cantidadCuotas cuotas)' : ''}',
                Fmt.cordobas(saldoActual)),
            const SizedBox(height: 4),
            _row('A cobrar ahora', Fmt.cordobas(aCobrar), bold: true),
            if (vuelto > 0.01) ...[
              const SizedBox(height: 4),
              _row('Vuelto al cliente', Fmt.cordobas(vuelto),
                  color: scheme.primary, bold: true),
            ],
            const Divider(),
            _row(
              esCompleto
                  ? (cantidadCuotas > 1 ? 'Cuotas completas ✓' : 'Cuota completa ✓')
                  : 'Saldo restante',
              Fmt.cordobas(saldoFinal.toDouble()),
              color: esCompleto ? scheme.tertiary : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Text(label),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _CargoAutoPreview {
  const _CargoAutoPreview({
    required this.cuotaId,
    required this.tipo,
    required this.monto,
    this.porcentaje,
    required this.descripcion,
  });
  final String cuotaId;
  final String tipo;
  final double monto;
  final double? porcentaje;
  final String descripcion;
}
