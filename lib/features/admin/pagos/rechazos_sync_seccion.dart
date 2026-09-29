import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/services/rechazos_sync_service.dart'
    show etiquetaTablaSync;
import '../../../data/utils/formatters.dart';

/// Secciones ONLINE de "Cobros a revisar" (0236/0237): la bandeja de cobros
/// que el server RECHAZÓ al sincronizar, y los huecos del talonario.
///
/// Nacen del incidente Derling (28-29/07/2026): 10 cobros rechazados quedaron
/// solo en el teléfono del cobrador y se supo 19 días después, por el reclamo
/// de una clienta. Ahora el rechazo sube al server con el cobro completo
/// (`sync_rechazos`) y el admin lo REGISTRA con un toque: el RPC
/// `sync_rechazo_registrar` re-inserta el pago con autoridad de admin y el
/// guard de sobrepago (0218) decide solo — cuenta, cuarentena o duplicado.
/// El número de recibo IMPRESO se preserva si sigue libre.
///
/// SON ONLINE A PROPÓSITO (declarado, principio offline-first de AGENTS):
/// recuperar un rechazo exige red por definición — el dato vive SOLO en el
/// server (no está en las sync rules; el device que lo sufrió tiene su copia
/// local en el Perfil). Sin conexión las secciones se ocultan en silencio y
/// la pantalla queda como siempre (la cuarentena local sigue siendo offline).
final rechazosPendientesProvider = FutureProvider.autoDispose<
    List<Map<String, dynamic>>>((ref) async {
  final res =
      await Supabase.instance.client.rpc('sync_rechazos_pendientes');
  return (res as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
});

final huecosTalonarioProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await Supabase.instance.client.rpc('recibos_huecos');
  return (res as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
});

/// Para el badge del shell y la CAMPANA: SOLO rechazos de PLATA (pagos y
/// recibos). Los avisos internos del sistema (cuotas u otras tablas de
/// fontanería) se ven en la pantalla como informativos grises, pero no
/// hacen sonar la campana — rojo es plata, gris es sistema (paquete bandeja
/// humana 2026-08-20). Offline/error → 0 (el badge no puede depender de la
/// red; lo local ya lo cubre cobrosARevisarCount).
final rechazosPendientesCountProvider = Provider.autoDispose<int>((ref) =>
    ref.watch(rechazosPendientesProvider).maybeWhen<int>(
        data: (l) => l
            .where((r) => r['tabla'] == 'pagos' || r['tabla'] == 'recibos')
            .length,
        orElse: () => 0));

class RechazosSyncSeccion extends ConsumerStatefulWidget {
  const RechazosSyncSeccion({super.key});

  @override
  ConsumerState<RechazosSyncSeccion> createState() =>
      _RechazosSyncSeccionState();
}

class _RechazosSyncSeccionState extends ConsumerState<RechazosSyncSeccion> {
  /// Ids con un Registrar/Descartar en vuelo (deshabilita SOLO ese tile).
  final _enVuelo = <String>{};

  static const _maxVisibles = 6;

  /// Auto-refresh: la pantalla puede quedar abierta horas en la PC de la
  /// oficina y mostraba datos viejos (los "6 rechazados" fantasma del
  /// 20/08/2026 ya estaban resueltos en el server). El fetch es on-mount;
  /// este timer lo repite cada 60 s mientras la pantalla esté visible.
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _autoRefresh = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      ref.invalidate(rechazosPendientesProvider);
      ref.invalidate(huecosTalonarioProvider);
    });
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _registrar(Map<String, dynamic> r) async {
    final id = r['id'] as String;
    final cliente = (r['cliente_nombre'] as String?) ?? 'este cobro';
    final monto = r['monto'];
    // Confirmación (patrón correcto de showDialog — la cierra el usuario, y el
    // pop usa el context del builder, regla AGENTS #8).
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('¿Registrar este cobro?'),
        content: Text(
            'Se vuelve a ingresar el cobro de $cliente'
            '${monto != null ? ' por ${Fmt.cordobas((monto as num))}' : ''} '
            'que el servidor rechazó. Las reglas de siempre deciden: si la '
            'cuota está impaga cuenta de una; si la sobrepagaría queda en '
            'cuarentena acá mismo; si es copia exacta de otro pago se anula '
            'solo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('Registrar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _enVuelo.add(id));
    try {
      final res = await Supabase.instance.client
          .rpc('sync_rechazo_registrar', params: {'p_id': id});
      final m = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final exito = m['ok'] == true;
      final recibo = m['recibo'] as String?;
      final msg = !exito
          ? 'No se pudo registrar: ${m['error']}'
          : switch (m['estado'] as String?) {
              'cuenta' =>
                'Registrado: el cobro cuenta'
                    '${recibo != null ? ' (recibo $recibo)' : ''}.',
              'cuarentena' =>
                'Registrado EN CUARENTENA: sobrepasaría la cuota. Decidí acá '
                    'mismo cuál pago es el verdadero.',
              'anulado_duplicado' =>
                'Era copia exacta de un pago que ya está: quedó anulado, sin '
                    'doble cobro.',
              'recibo_suelto' =>
                'Recibo registrado${recibo != null ? ' ($recibo)' : ''}.',
              _ => 'Registrado.',
            };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 6),
        backgroundColor:
            exito ? null : Theme.of(context).colorScheme.error,
      ));
      if (exito) {
        ref.invalidate(rechazosPendientesProvider);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No se pudo registrar (¿sin conexión?): $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _enVuelo.remove(id));
    }
  }

  Future<void> _descartar(Map<String, dynamic> r) async {
    final id = r['id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('¿Descartar este aviso?'),
        content: const Text(
            'El aviso se marca resuelto SIN registrar nada. Usalo solo si ya '
            'verificaste que este cambio no era plata (o ya se cargó por otro '
            'lado).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('Descartar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _enVuelo.add(id));
    try {
      // RPC anclada al tenant en contexto (0246), no un UPDATE REST directo:
      // el UPDATE suelto podia apagar el aviso de un cobro perdido de OTRA
      // empresa cuando el super_admin impersonaba, sin dejar rastro ni forma
      // de deshacerlo desde la app. La RPC valida y explica el rechazo.
      final res = await Supabase.instance.client
          .rpc('sync_rechazo_descartar', params: {'p_id': id});
      final map = Map<String, dynamic>.from(res as Map);
      if (map['ok'] != true) {
        throw Exception(map['error']?.toString() ?? 'No se pudo descartar.');
      }
      ref.invalidate(rechazosPendientesProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No se pudo descartar: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _enVuelo.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rechazos = ref.watch(rechazosPendientesProvider);
    final huecos = ref.watch(huecosTalonarioProvider);

    final listaR = rechazos.valueOrNull ?? const <Map<String, dynamic>>[];
    // Los cobros pendientes, para ATAR cada recibo huerfano al suyo: un recibo
    // cuyo cobro esta en esta misma lista no se toca — se resuelve solo al
    // registrar el cobro (el RPC arrastra al hermano).
    final pagosPendientes = <String>{
      for (final r in listaR)
        if (r['tabla'] == 'pagos') r['registro_id'] as String,
    };
    final listaH = huecos.valueOrNull ?? const <Map<String, dynamic>>[];
    // Semáforo del paquete "bandeja humana": ROJO solo para plata (pagos y
    // recibos); todo lo demás (cuotas u otra fontanería interna) es un aviso
    // GRIS informativo — no asusta, no bloquea, no suena la campana.
    final listaPlata = [
      for (final r in listaR)
        if (r['tabla'] == 'pagos' || r['tabla'] == 'recibos') r,
    ];
    final listaSistema = [
      for (final r in listaR)
        if (r['tabla'] != 'pagos' && r['tabla'] != 'recibos') r,
    ];
    // Offline, cargando o vacío → nada. La pantalla queda como siempre.
    if (listaR.isEmpty && listaH.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (listaPlata.isNotEmpty) ...[
          _header(scheme, Icons.cloud_off_outlined,
              'Cobros rechazados al sincronizar · ${listaPlata.length}'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                for (final r in listaPlata.take(_maxVisibles))
                  _tile(scheme, r, pagosPendientes),
                if (listaPlata.length > _maxVisibles)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                        'y ${listaPlata.length - _maxVisibles} más — al resolver '
                        'estos aparecen los siguientes',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
              ]),
            ),
          ),
        ],
        if (listaSistema.isNotEmpty) ...[
          _headerGris(scheme, Icons.info_outline,
              'Avisos del sistema'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                for (final r in listaSistema.take(_maxVisibles))
                  _tileSistema(scheme, r),
                if (listaSistema.length > _maxVisibles)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                        'y ${listaSistema.length - _maxVisibles} más — al '
                        'descartar estos aparecen los siguientes',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
              ]),
            ),
          ),
        ],
        if (listaH.isNotEmpty) ...[
          _header(scheme, Icons.receipt_long_outlined,
              'Talonario — recibos que nunca llegaron'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                for (final h in listaH.take(4)) _tileHueco(scheme, h),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Text(
                      'Un salto en la numeración = cobros hechos en el '
                      'teléfono que no llegaron al servidor. Pedile al '
                      'cobrador esos recibos del talonario.',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: scheme.onSurfaceVariant)),
                ),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _header(ColorScheme scheme, IconData icon, String txt) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(children: [
          Icon(icon, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(txt,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.error)),
          ),
          InkWell(
            onTap: () {
              ref.invalidate(rechazosPendientesProvider);
              ref.invalidate(huecosTalonarioProvider);
            },
            child: Icon(Icons.refresh, size: 16, color: scheme.onSurfaceVariant),
          ),
        ]),
      );

  Widget _headerGris(ColorScheme scheme, IconData icon, String txt) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(txt,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
        ]),
      );

  /// Aviso interno (tabla que NO es plata, p.ej. la fontanería de cuotas):
  /// tono gris, lenguaje llano, la jerga queda como "detalle técnico".
  Widget _tileSistema(ColorScheme scheme, Map<String, dynamic> r) {
    final id = r['id'] as String;
    final busy = _enVuelo.contains(id);
    final tabla = r['tabla'] as String? ?? '?';
    final cobrador = r['cobrador'] as String?;
    final fecha = Fmt.fechaHoraNi(r['ocurrido_en'] as String?);
    final codigo = r['codigo'] as String?;
    final mensaje = (r['mensaje'] as String?) ?? '';
    return ListTile(
      dense: true,
      leading:
          Icon(Icons.settings_suggest, size: 18, color: scheme.onSurfaceVariant),
      title: Text(
          'Aviso interno${cobrador != null ? ' · equipo de $cobrador' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'El servidor no aceptó un cambio interno '
            '(${etiquetaTablaSync(tabla)}). En general se corrige solo al '
            'sincronizar; verificá el registro antes de descartar.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        Text('$fecha · detalle técnico: ${codigo ?? '?'} $mensaje',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: scheme.outline)),
      ]),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(
              onPressed: () => _descartar(r),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.onSurfaceVariant),
              child: const Text('Descartar'),
            ),
    );
  }

  /// Descarta PARA SIEMPRE un salto histórico de numeración (queda registro
  /// de quién y cuándo en el server — RPC 0242).
  Future<void> _ignorarHueco(Map<String, dynamic> h) async {
    final desde = h['desde'] as int, hasta = h['hasta'] as int;
    final prefijo = h['prefijo'] as String;
    final rango = desde == hasta ? '$desde' : '$desde–$hasta';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('¿Ignorar el salto $prefijo $rango?'),
        // Acción permanente: el diálogo repite TODO el contexto del tile
        // (audit UX #4 — al confirmar, el tile ya no se ve).
        content: Text(
            'Faltan ${h['faltan']} recibo(s) de ${h['cobrador']}, entre '
            '${Fmt.fechaHoraNi(h['ok_antes'] as String?)} y '
            '${Fmt.fechaHoraNi(h['ok_despues'] as String?)}.\n\n'
            'Usalo SOLO si ya verificaste que estos números no son cobros '
            'reales (p.ej. pruebas previas al arranque). El salto deja de '
            'aparecer acá y queda registrado quién lo descartó y cuándo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('Ignorar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final llave = 'hueco:$prefijo:$desde';
    setState(() => _enVuelo.add(llave));
    try {
      final res = await Supabase.instance.client
          .rpc('recibos_hueco_ignorar', params: {
        'p_prefijo': prefijo,
        'p_desde': desde,
        'p_hasta': hasta,
        'p_motivo': 'Descartado desde la bandeja',
      });
      final m = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      if (m['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('Salto $prefijo $rango descartado (quedó registrado).'),
        ));
        ref.invalidate(huecosTalonarioProvider);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No se pudo ignorar: ${m['error']}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No se pudo ignorar (¿sin conexión?): $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _enVuelo.remove(llave));
    }
  }

  /// El motivo, contado en TERCERA PERSONA y en pasado: esta bandeja la lee
  /// el ADMIN, no quien sufrio el rechazo. "Sin permiso para esta operacion"
  /// (la voz del Perfil del cobrador) aca sonaba a que el admin no tenia
  /// permisos — feedback de Ruben 2026-08-17. El codigo queda entre parentesis
  /// para diagnostico.
  String _motivoHistorico(Map<String, dynamic> r, {required bool atado}) {
    if (atado) {
      return 'Va atado al cobro de arriba: al registrarlo, este recibo entra solo.';
    }
    final codigo = r['codigo'] as String?;
    final mensaje = (r['mensaje'] as String?) ?? '';
    final causa = switch (codigo) {
      '42501' => 'el servidor le negó el permiso al equipo del cobrador en ese momento',
      '23503' => 'apuntaba a datos que aún no estaban en el servidor',
      '23505' => 'chocaba con un registro que ya existía',
      '23514' => 'no pasó una validación del negocio',
      'P0001' => mensaje.isEmpty ? 'una regla del negocio lo frenó' : mensaje,
      _ when (codigo ?? '').startsWith('22') =>
        'los datos tenían un formato inválido',
      _ => mensaje.isEmpty ? 'el servidor lo rechazó' : mensaje,
    };
    return 'El cobro no pudo entrar al sistema: $causa'
        '${codigo != null ? ' (cód. $codigo)' : ''}.';
  }

  Widget _tile(
      ColorScheme scheme, Map<String, dynamic> r, Set<String> pagosPendientes) {
    final id = r['id'] as String;
    final tabla = r['tabla'] as String? ?? '?';
    final busy = _enVuelo.contains(id);
    final cliente = r['cliente_nombre'] as String?;
    final codigo = r['cliente_codigo'] as String?;
    final monto = r['monto'] as num?;
    final recibo = r['recibo_numero'] as String?;
    final cobrador = r['cobrador'] as String?;
    final fecha = Fmt.fechaHoraNi(r['ocurrido_en'] as String?);

    // Recibo cuyo cobro esta pendiente en esta misma lista: subordinado, sin
    // botones. Registrar el cobro lo arrastra; descartarlo aparte dejaria un
    // cobro sin comprobante (INV5).
    final pagoVinculado = r['pago_id'] as String?;
    final atado = tabla == 'recibos' &&
        pagoVinculado != null &&
        pagosPendientes.contains(pagoVinculado);
    final esCobro = tabla == 'pagos' || (tabla == 'recibos' && !atado);

    final titulo = cliente != null
        ? '${codigo != null ? '$codigo · ' : ''}$cliente'
        : tabla == 'recibos'
            ? 'Recibo ${recibo ?? ''}'.trim()
            : etiquetaTablaSync(tabla);
    final detalle = [
      if (monto != null) Fmt.cordobas(monto),
      if (recibo != null) recibo,
      if (cobrador != null) cobrador,
      fecha,
    ].join(' · ');

    return ListTile(
      dense: true,
      title: Text(titulo,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(detalle, style: const TextStyle(fontSize: 12)),
        Text(_motivoHistorico(r, atado: atado),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11.5,
                color: atado ? scheme.onSurfaceVariant : scheme.error)),
      ]),
      trailing: atado
          ? Icon(Icons.subdirectory_arrow_left,
              size: 18, color: scheme.onSurfaceVariant)
          : busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              if (esCobro)
                FilledButton(
                  onPressed: () => _registrar(r),
                  style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12)),
                  child: const Text('Registrar'),
                ),
              PopupMenuButton<String>(
                tooltip: 'Más',
                onSelected: (v) {
                  if (v == 'descartar') _descartar(r);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'descartar', child: Text('Descartar')),
                ],
              ),
            ]),
    );
  }

  Widget _tileHueco(ColorScheme scheme, Map<String, dynamic> h) {
    final desde = h['desde'], hasta = h['hasta'];
    final rango = desde == hasta ? '$desde' : '$desde–$hasta';
    return ListTile(
      dense: true,
      leading: Icon(Icons.warning_amber_rounded,
          size: 18, color: scheme.error),
      title: Text(
          '${h['prefijo']} $rango · faltan ${h['faltan']} · ${h['cobrador']}',
          style: const TextStyle(fontSize: 13)),
      subtitle: Text(
          'entre ${Fmt.fechaHoraNi(h['ok_antes'] as String?)} y '
          '${Fmt.fechaHoraNi(h['ok_despues'] as String?)}',
          style: const TextStyle(fontSize: 11.5)),
      // Descarte manual CON registro (0242) para saltos históricos que ya se
      // verificaron como no-cobros (p.ej. la era de pruebas pre-arranque).
      trailing: _enVuelo.contains('hueco:${h['prefijo']}:${h['desde']}')
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(
              onPressed: () => _ignorarHueco(h),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.onSurfaceVariant),
              child: const Text('Ignorar'),
            ),
    );
  }
}
