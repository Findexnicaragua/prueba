// ignore_for_file: use_build_context_synchronously
//
// Los avisos de este archivo son FALSA ALARMA, verificados uno por uno: el
// `context` se pasa a `guardarPdfConAviso`, que chequea `context.mounted` ADENTRO antes
// de tocarlo. El analizador no puede ver a través de la función, así que
// flaggea el call-site igual.
//
// REGLA PARA ESTE ARCHIVO: si agregás un uso DIRECTO del context después de un
// await (sin pasar por `guardarPdfConAviso`), sacá este ignore y poné el guard donde va —
// si no, el aviso que sí importa queda tapado.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/router.dart';
import '../../../data/models/pago.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/logo_empresa_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/cobrador_helpers.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../features/shared/widgets/rango_fechas_dialog.dart';
import '../../../powersync/db.dart' as ps;
import 'arqueo_calculo.dart';
import 'descarga_archivo.dart';
import 'excel/reporte_excel.dart';
import 'pdf/reporte_anulaciones_pdf.dart';
import 'pdf/reporte_arqueo_pdf.dart';
import 'pdf/reporte_clientes_pdf.dart';
import 'pdf/reporte_cobros_pdf.dart';
import 'pdf/reporte_eficiencia_pdf.dart';
import 'pdf/reporte_fiscal_pdf.dart';
import 'pdf/reporte_inactivos_pdf.dart';
import 'pdf/reporte_mora_pdf.dart';
import 'pdf/reporte_por_cobrador_pdf.dart';

/// Bytes del logo del tenant para los headers de los PDF (cache
/// offline-first, el mismo del recibo). Nunca lanza: sin logo configurado o
/// sin cache+red devuelve null y el header sale solo texto.
Future<Uint8List?> _logoParaReportes(WidgetRef ref) async {
  try {
    final bytes = await ref.read(logoEmpresaBytesProvider.future);
    if (bytes == null &&
        ref.read(appSettingsProvider).empresaLogoPath.isNotEmpty) {
      // Hay logo configurado pero no se pudo resolver (ej. arranque offline
      // sin cache): invalidar para que el PRÓXIMO reporte reintente en vez
      // de quedarse con el null cacheado toda la sesión.
      ref.invalidate(logoEmpresaBytesProvider);
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Rango de fechas para los reportes DESCARGABLES (#3). Filtra por `fecha_pago`
/// (la "fecha de cobro"). NO afecta las tarjetas analíticas en pantalla —esas
/// siguen mostrando el mes actual—. Default: mes actual.
class RangoReporte {
  const RangoReporte({
    required this.desde,
    required this.hasta,
    required this.label,
  });
  final DateTime desde; // inclusive (date-only)
  final DateTime hasta; // inclusive (date-only)
  final String label;

  String get desdeSql => _d(desde);
  String get hastaSql => _d(hasta);
  String get periodoLabel => '${Fmt.fechaCorta(desde)} – ${Fmt.fechaCorta(hasta)}';
  static String _d(DateTime x) => x.toIso8601String().substring(0, 10);

  static RangoReporte mesActual() {
    // "now" en hora de Nicaragua (UTC-6) para que el rango por defecto (1ro del
    // mes → hoy) sea el día Nicaragua correcto, sin depender de la zona horaria
    // de la máquina. `fecha_pago` se guarda en hora local Nicaragua, así que las
    // queries filtran por `date(fecha_pago)` CRUDO (sin '-6 hours') y este rango
    // calza con ese bucketing.
    //
    // OJO — NO calza con el dashboard: desde el corte del 15 (`periodo_dashboard
    // .dart`) el Resumen mide del 15 al 14 y Reportes sigue midiendo el mes
    // calendario. Los dos están BIEN, miden ventanas distintas a propósito, pero
    // sus totales no coinciden y no deben "cuadrarse" entre sí.
    final now = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    return RangoReporte(
      desde: DateTime(now.year, now.month, 1),
      hasta: DateTime(now.year, now.month, now.day),
      label: 'Este mes',
    );
  }

  static RangoReporte mesPasado() {
    final now = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    final finMesPasado = DateTime(now.year, now.month, 1)
        .subtract(const Duration(days: 1));
    return RangoReporte(
      desde: DateTime(finMesPasado.year, finMesPasado.month, 1),
      hasta: finMesPasado,
      label: 'Mes pasado',
    );
  }

  /// Día de hoy (desde = hasta = hoy). Default del arqueo de caja.
  static RangoReporte hoy() {
    final now = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    final dia = DateTime(now.year, now.month, now.day);
    return RangoReporte(desde: dia, hasta: dia, label: 'Hoy');
  }

  /// Día de ayer (desde = hasta = ayer). Para cerrar la caja del día previo.
  static RangoReporte ayer() {
    final now = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    final dia =
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    return RangoReporte(desde: dia, hasta: dia, label: 'Ayer');
  }
}

/// Rango activo para reportes descargables. Default: mes actual.
final reporteRangoProvider =
    StateProvider<RangoReporte>((ref) => RangoReporte.mesActual());

/// Cobradores seleccionados para FILTRAR los reportes — COMPARTIDO por el
/// reporte de cobranza y todos los detallados (reforma del módulo). `null` =
/// TODOS (sin filtro); un set = solo esos `pagos.cobrador_id` (= quién cobró,
/// invariante de reportería). La reportería POR CLIENTE (mora, estado de
/// clientes, inactivos, padrón) lo IGNORA: ahí "quién cobró" no aplica.
final reporteCobradoresProvider = StateProvider<Set<String>?>((ref) => null);

/// Fragmento SQL + params para filtrar por los cobradores seleccionados.
/// `null`/vacío (= todos) → fragmento vacío (sin filtro). Por defecto filtra por
/// `pagos.cobrador_id` (quién cobró, invariante de reportería); los reportes que
/// agrupan por cobrador pasan `columna: 'cb.id'`. El caller intercala `.sql` en
/// su WHERE y concatena `.params`. Las ids van SIEMPRE como placeholders (`?`),
/// nunca interpoladas → sin riesgo de inyección.
({String sql, List<Object?> params}) filtroCobradorSql(Set<String>? cobradores,
    {String columna = 'p.cobrador_id'}) {
  if (cobradores == null || cobradores.isEmpty) {
    return (sql: '', params: const []);
  }
  final placeholders = List.filled(cobradores.length, '?').join(',');
  return (sql: ' AND $columna IN ($placeholders)', params: cobradores.toList());
}

class ReportesAdminScreen extends ConsumerWidget {
  const ReportesAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    final detallados = settings.reportesDetallados;
    final esAdminCobranza =
        ref.watch(cobradorActualProvider).valueOrNull?.esAdminCobranza ?? false;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const _RangoReportesCard(),
        const SizedBox(height: 16),
        const _CobradoresReporteCard(),
        const SizedBox(height: 16),
        _GenerarReporteCard(
            diasGracia: diasGracia, esAdminCobranza: esAdminCobranza),
        if (detallados) ...[
          if (!esAdminCobranza) ...[
            const SizedBox(height: 16),
            const _RecaudacionMensualCard(),
            const SizedBox(height: 16),
            const _CobradoresMesCard(),
          ],
          const SizedBox(height: 16),
          _MoraPorComunidadCard(diasGracia: diasGracia),
          const SizedBox(height: 16),
          const _PlanesPopularesCard(),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Selector de rango para los reportes descargables (#3). Muestra el rango
/// activo y permite cambiarlo con presets (Este mes / Mes pasado / custom).
/// Deja claro que NO afecta las tarjetas analíticas de abajo.
class _RangoReportesCard extends ConsumerWidget {
  const _RangoReportesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rango = ref.watch(reporteRangoProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.date_range, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Rango de reportes descargables',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    '${rango.label} · ${rango.periodoLabel}',
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                  Text(
                      'Filtra por fecha de cobro. No afecta las tarjetas de abajo.',
                      style: TextStyle(color: scheme.outline, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _elegirRango(context, ref),
              icon: const Icon(Icons.edit_calendar, size: 18),
              label: const Text('Cambiar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _elegirRango(BuildContext context, WidgetRef ref) async {
    final opcion = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.wb_sunny_outlined),
              title: const Text('Hoy'),
              onTap: () => Navigator.pop(ctx, 'hoy'),
            ),
            ListTile(
              leading: const Icon(Icons.wb_twilight),
              title: const Text('Ayer'),
              onTap: () => Navigator.pop(ctx, 'ayer'),
            ),
            ListTile(
              leading: const Icon(Icons.today),
              title: const Text('Este mes'),
              onTap: () => Navigator.pop(ctx, 'mes'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Mes pasado'),
              onTap: () => Navigator.pop(ctx, 'pasado'),
            ),
            ListTile(
              leading: const Icon(Icons.date_range),
              title: const Text('Personalizado…'),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (opcion == null || !context.mounted) return;
    final notifier = ref.read(reporteRangoProvider.notifier);
    if (opcion == 'hoy') {
      notifier.state = RangoReporte.hoy();
    } else if (opcion == 'ayer') {
      notifier.state = RangoReporte.ayer();
    } else if (opcion == 'mes') {
      notifier.state = RangoReporte.mesActual();
    } else if (opcion == 'pasado') {
      notifier.state = RangoReporte.mesPasado();
    } else if (opcion == 'custom') {
      final now = DateTime.now();
      final actual = ref.read(reporteRangoProvider);
      final picked = await mostrarRangoFechas(
        context,
        firstDate: DateTime(now.year - 5),
        lastDate: now, // sin futuro: "fecha de cobro" no tiene sentido a futuro
        inicial: DateTimeRange(start: actual.desde, end: actual.hasta),
      );
      if (picked == null) return;
      notifier.state = RangoReporte(
        desde:
            DateTime(picked.start.year, picked.start.month, picked.start.day),
        hasta: DateTime(picked.end.year, picked.end.month, picked.end.day),
        label: 'Personalizado',
      );
    }
  }
}

/// Filtro de COBRADORES compartido por todos los reportes (reforma del módulo).
/// Muestra la selección activa ("Todos" o "N seleccionado(s)") y abre el
/// multi-select. `null` en el provider = todos (sin filtro).
class _CobradoresReporteCard extends ConsumerWidget {
  const _CobradoresReporteCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = ref.watch(reporteCobradoresProvider);
    final scheme = Theme.of(context).colorScheme;
    final label = sel == null
        ? 'Todos los cobradores'
        : '${sel.length} cobrador(es) seleccionado(s)';
    return Card(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.groups, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cobradores en los reportes',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(label,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                  Text('Filtra por quién cobró. No aplica a mora/estado/inactivos.',
                      style: TextStyle(color: scheme.outline, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => editarFiltroCobradores(context, ref),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Cambiar'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Abre el multi-select de cobradores y guarda la selección en
/// [reporteCobradoresProvider]. Lista: cobradores/admins/admin_cobranza activos
/// + CUALQUIER usuario (aunque inactivo) que haya cobrado en el rango activo (no
/// se pierde histórico). Si quedan TODOS marcados guarda `null` (= sin filtro).
Future<void> editarFiltroCobradores(BuildContext context, WidgetRef ref) async {
  final rango = ref.read(reporteRangoProvider);
  final usuarios = await ps.db.getAll('''
    SELECT cb.id, cb.nombre, cb.rol, cb.activo
      FROM cobradores cb
     WHERE (cb.activo = 1 AND cb.rol IN ('cobrador','admin','admin_cobranza'))
        OR EXISTS (SELECT 1 FROM pagos p
                    WHERE p.cobrador_id = cb.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
                      AND date(p.fecha_pago) BETWEEN ? AND ?)
     ORDER BY cb.nombre
  ''', [rango.desdeSql, rango.hastaSql]);
  if (!context.mounted) return;
  if (usuarios.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No hay cobradores ni cobros en el período.')));
    return;
  }
  final actual = ref.read(reporteCobradoresProvider);
  final seleccionados = actual == null
      ? {for (final u in usuarios) u['id'] as String}
      : {...actual};
  final result = await showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final todos = seleccionados.length == usuarios.length;
        return AlertDialog(
          title: const Text('Cobradores en los reportes'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                CheckboxListTile(
                  value: todos,
                  title: const Text('Todos'),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) => setLocal(() {
                    seleccionados.clear();
                    if (v == true) {
                      seleccionados
                          .addAll(usuarios.map((u) => u['id'] as String));
                    }
                  }),
                ),
                const Divider(height: 1),
                ...usuarios.map((u) {
                  final id = u['id'] as String;
                  final inactivo = (u['activo'] as num?) != 1;
                  return CheckboxListTile(
                    value: seleccionados.contains(id),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(u['nombre'] as String),
                    subtitle: Text(rolLabel(u['rol'] as String) +
                        (inactivo ? ' · inactivo' : '')),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        seleccionados.add(id);
                      } else {
                        seleccionados.remove(id);
                      }
                    }),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: seleccionados.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, {...seleccionados}),
              child: const Text('Aplicar'),
            ),
          ],
        );
      },
    ),
  );
  if (result == null) return; // cancelado
  // Si quedaron TODOS marcados → null (sin filtro); si no, el subset elegido.
  final esTodos = result.length == usuarios.length;
  ref.read(reporteCobradoresProvider.notifier).state = esTodos ? null : result;
}

/// Query del arqueo / cierre por cobrador. Una fila por cobrador con los
/// efectivos separados por moneda (US$/C$, montos en `monto_original`), el
/// vuelto total, los electrónicos por método, y el recaudado contable
/// (`monto_cordobas`). Params: [desde, hasta] (date-only, inclusive).
/// SQLite-válida: usa SUM(CASE WHEN…), NO FILTER. Compartida por PDF y Excel.
/// [filtroCbWhere] = '' (todos) o 'WHERE cb.id IN (?,?,…)' del filtro de
/// cobradores; sus params van DESPUÉS de los 4 de fechas (orden posicional).
String _arqueoSql(String filtroCbWhere) => '''
  SELECT cb.nombre AS cobrador_nombre,
         COUNT(p.id) AS total_cobros,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN p.monto_original ELSE 0 END),0) AS efectivo_usd,
         SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN 1 ELSE 0 END) AS efectivo_usd_qty,
         -- Equivalente en córdobas del efectivo USD, a la tasa de CADA cobro
         -- (monto_cordobas + vuelto_cordobas = monto_original × tasa_conversion,
         -- invariante #3). NO usar la tasa de hoy: rompería la reconciliación.
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN COALESCE(p.monto_cordobas,0) + COALESCE(p.vuelto_cordobas,0) ELSE 0 END),0) AS efectivo_usd_equiv,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='NIO' THEN p.monto_original ELSE 0 END),0) AS efectivo_nio,
         SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='NIO' THEN 1 ELSE 0 END) AS efectivo_nio_qty,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' THEN p.vuelto_cordobas ELSE 0 END),0) AS efectivo_vuelto,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' THEN p.monto_cordobas ELSE 0 END),0) AS efectivo_ingreso,
         COALESCE(SUM(CASE WHEN p.metodo='transferencia' THEN p.monto_cordobas ELSE 0 END),0) AS transferencia,
         SUM(CASE WHEN p.metodo='transferencia' THEN 1 ELSE 0 END) AS transferencia_qty,
         COALESCE(SUM(CASE WHEN p.metodo='deposito' THEN p.monto_cordobas ELSE 0 END),0) AS deposito,
         SUM(CASE WHEN p.metodo='deposito' THEN 1 ELSE 0 END) AS deposito_qty,
         COALESCE(SUM(CASE WHEN p.metodo='tarjeta' THEN p.monto_cordobas ELSE 0 END),0) AS tarjeta,
         SUM(CASE WHEN p.metodo='tarjeta' THEN 1 ELSE 0 END) AS tarjeta_qty,
         COALESCE(SUM(p.monto_cordobas),0) AS ingreso_total,
         -- Devoluciones de saldo a favor pagadas en efectivo (0127): salen de la
         -- caja de ESTE cobrador en el rango (bucket por fecha_devolucion LOCAL).
         -- Tabla derivada con LEFT JOIN (no subquery correlacionada) → un cobrador
         -- que SOLO hizo devoluciones (sin pagos en el rango) igual aparece.
         COALESCE(d.dev, 0) AS devoluciones
    FROM cobradores cb
    LEFT JOIN pagos p ON p.cobrador_id = cb.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
                     AND date(p.fecha_pago) BETWEEN ? AND ?
    LEFT JOIN (SELECT cobrador_id, SUM(monto) AS dev
                 FROM saldos_favor
                WHERE tipo = 'devuelto'
                  AND date(fecha_devolucion) BETWEEN ? AND ?
                GROUP BY cobrador_id) d ON d.cobrador_id = cb.id
   $filtroCbWhere
   GROUP BY cb.id, cb.nombre, d.dev
  HAVING COUNT(p.id) > 0 OR COALESCE(d.dev, 0) > 0
   ORDER BY ingreso_total DESC
''';

/// Descriptor de un tipo de reporte para el generador unificado (reforma).
/// [soloDetallado] = aparece solo con el toggle de reportes detallados ON.
/// TODOS soportan Excel; [pdf] indica si además hay PDF. [filtraCobrador] =
/// respeta el filtro global de cobradores (los por-cliente no).
class _TipoReporte {
  const _TipoReporte(this.key, this.label,
      {this.pdf = true,
      this.soloDetallado = true,
      this.filtraCobrador = true,
      this.soloAdmin = false});
  final String key;
  final String label;
  final bool pdf;
  final bool soloDetallado;
  final bool filtraCobrador;
  final bool soloAdmin;
}

const _tiposReporte = <_TipoReporte>[
  _TipoReporte('cobranza', 'Reporte de cobranza',
      pdf: false, soloDetallado: false),
  _TipoReporte('cobros', 'Cobros del período', soloAdmin: true),
  _TipoReporte('por_cobrador', 'Cobros por cobrador', soloAdmin: true),
  _TipoReporte('arqueo', 'Arqueo / cierre de caja', soloAdmin: true),
  _TipoReporte('fiscal', 'Fiscal / contable', soloAdmin: true),
  _TipoReporte('eficiencia', 'Eficiencia por cobrador', soloAdmin: true),
  _TipoReporte('anulaciones', 'Anulaciones'),
  _TipoReporte('mora', 'Mora', filtraCobrador: false),
  _TipoReporte('clientes', 'Estado de clientes', filtraCobrador: false),
  _TipoReporte('inactivos', 'Clientes inactivos', filtraCobrador: false),
  _TipoReporte('padron', 'Padrón de clientes',
      pdf: false, filtraCobrador: false),
];

/// Generador unificado de reportes (reforma): UNA card con "Generar reporte"
/// → diálogo (tipo + formato). Los filtros de período y cobradores viven en sus
/// propias cards arriba y se comparten con TODOS los reportes.
class _GenerarReporteCard extends ConsumerWidget {
  const _GenerarReporteCard(
      {required this.diasGracia, this.esAdminCobranza = false});
  final int diasGracia;
  final bool esAdminCobranza;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final rango = ref.watch(reporteRangoProvider);
    final sel = ref.watch(reporteCobradoresProvider);
    final cobLabel =
        sel == null ? 'Todos los cobradores' : '${sel.length} cobrador(es)';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.summarize, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Generar reporte',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Elegí el tipo y el formato; usa los filtros de arriba.',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Filtros: ${rango.label} · $cobLabel',
                style: TextStyle(color: scheme.outline, fontSize: 11)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => _abrirDialogo(context, ref),
                icon: const Icon(Icons.file_download, size: 18),
                label: const Text('Generar reporte'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Diálogo unificado: elegí TIPO + FORMATO; los filtros (período + cobradores)
  /// vienen de las cards de arriba. La lista de tipos depende del toggle de
  /// reportes detallados (solo "cobranza" si está OFF).
  Future<void> _abrirDialogo(BuildContext context, WidgetRef ref) async {
    final detallados = ref.read(appSettingsProvider).reportesDetallados;
    final tipos = _tiposReporte
        .where((t) =>
            (!t.soloDetallado || detallados) &&
            (!t.soloAdmin || !esAdminCobranza))
        .toList();
    if (tipos.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay reportes disponibles')),
      );
      return;
    }
    var tipoKey = tipos.first.key;
    var esExcel = true;
    final elegido = await showDialog<({String tipo, bool excel})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final desc = tipos.firstWhere((t) => t.key == tipoKey);
          if (!esExcel && !desc.pdf) esExcel = true;
          return AlertDialog(
            title: const Text('Generar reporte'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Tipo de reporte',
                      style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          fontSize: 12)),
                ),
                DropdownButton<String>(
                  value: tipoKey,
                  isExpanded: true,
                  items: [
                    for (final t in tipos)
                      DropdownMenuItem(value: t.key, child: Text(t.label)),
                  ],
                  onChanged: (v) => setLocal(() => tipoKey = v!),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Formato',
                      style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          fontSize: 12)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('Excel'),
                        avatar: const Icon(Icons.table_view, size: 18),
                        selected: esExcel,
                        onSelected: (_) => setLocal(() => esExcel = true),
                      ),
                    ),
                    if (desc.pdf) const SizedBox(width: 8),
                    if (desc.pdf)
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('PDF'),
                          avatar: const Icon(Icons.picture_as_pdf, size: 18),
                          selected: !esExcel,
                          onSelected: (_) => setLocal(() => esExcel = false),
                        ),
                      ),
                  ],
                ),
                if (!desc.filtraCobrador) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Es un reporte por cliente: el filtro de cobradores no aplica.',
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.outline, fontSize: 11),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(ctx, (tipo: tipoKey, excel: esExcel)),
                child: const Text('Generar'),
              ),
            ],
          );
        },
      ),
    );
    if (elegido == null || !context.mounted) return;
    if (elegido.excel) {
      await _generarExcel(context, ref, elegido.tipo);
    } else {
      await _generar(context, ref, elegido.tipo);
    }
  }

  Future<void> _generar(
      BuildContext context, WidgetRef ref, String tipo) async {
    final empresaNombre =
        ref.read(empresaNombreProvider).valueOrNull ?? 'ISP';
    final rango = ref.read(reporteRangoProvider);
    // Filtro de cobradores compartido (reforma): se aplica a los reportes DE
    // COBRO; los por-cliente (mora/clientes/inactivos) lo ignoran.
    final cobradores = ref.read(reporteCobradoresProvider);
    final fc = filtroCobradorSql(cobradores);

    final logoBytes = await _logoParaReportes(ref);

    try {
      if (tipo == 'cobros') {
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago, c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto, p.metodo,
                 p.moneda, p.monto_original, p.tasa_conversion,
                 p.vuelto_cordobas,
                 cb.nombre AS cobrador_nombre,
                 r.numero_completo AS numero_recibo,
                 SUBSTR(p.grupo_cobro, 1, 8) AS ref_grupo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?${fc.sql}
           ORDER BY p.fecha_pago DESC
        ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);

        final now = DateTime.now();
        final periodo = rango.periodoLabel;
        final doc = await buildReporteCobros(
          titulo: 'Reporte de cobros',
          empresaNombre: empresaNombre,
          periodo: periodo,
          rows: rows,
          logoBytes: logoBytes,
        );

        await guardarPdfConAviso(
          context,
          fileName: 'cobros_${now.year}_${now.month}.pdf',
          bytes: await doc.save(),
        );
      } else if (tipo == 'mora') {
        final rows = await ps.db.getAll('''
          SELECT c.nombre AS cliente_nombre,
                 co.nombre AS comunidad,
                 COUNT(cu.id) AS cuotas_vencidas,
                 COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0)
                   - COALESCE(cu.monto_pagado, 0), 0)), 0) AS monto_adeudado,
                 CAST(julianday('now', '-6 hours') - julianday(MIN(cu.fecha_vencimiento)) - ?
                   AS INTEGER) AS dias_mora
            FROM cuotas cu
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE cu.estado IN ('pendiente','parcial')
             AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') != 'suspendido'
             AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                 < date('now', '-6 hours')
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY dias_mora DESC
        ''', [diasGracia, diasGracia]);

        final now = DateTime.now();
        final periodoMora = Fmt.mes(now);

        final doc = await buildReporteMora(
          titulo: 'Reporte de mora',
          empresaNombre: empresaNombre,
          periodo: periodoMora,
          rows: rows,
          logoBytes: logoBytes,
        );
        await guardarPdfConAviso(
          context,
          fileName: 'mora_${now.year}_${now.month}_${now.day}.pdf',
          bytes: await doc.save(),
        );
      } else if (tipo == 'por_cobrador') {
        // Usa el filtro de cobradores GLOBAL (reforma): null = todos.
        final rows = await _rowsPorCobrador(cobradores, rango);
        final subtitulo = await _subtituloCobradores(cobradores);
        if (!context.mounted) return;

        final now = DateTime.now();
        final doc = await buildReportePorCobrador(
          titulo: 'Reporte por cobrador',
          empresaNombre: empresaNombre,
          periodo: rango.periodoLabel,
          subtitulo: subtitulo,
          rows: rows,
          logoBytes: logoBytes,
        );
        await guardarPdfConAviso(
          context,
          fileName: 'cobrador_${now.year}_${now.month}.pdf',
          bytes: await doc.save(),
        );
      } else if (tipo == 'clientes') {
        final rows = await ps.db.getAll('''
          SELECT c.nombre, co.nombre AS comunidad,
                 (SELECT COUNT(*) FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')) AS pendientes,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')), 0) AS saldo,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')
                     AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') = 'suspendido'), 0) AS saldo_suspendido,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')
                     -- 'completado' entra acá: es terminal como 'cancelado' (así
                     -- lo trata el header del contrato) y el CHECK de la base
                     -- todavía lo admite, así que una app vieja puede seguir
                     -- escribiéndolo. Sin esto su deuda caería en "En ruta".
                     AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') IN ('cancelado', 'completado')), 0) AS saldo_cancelado,
                 (SELECT MAX(p.fecha_pago) FROM pagos p
                    JOIN cuotas cu2 ON cu2.id = p.cuota_id
                   WHERE cu2.cliente_id = c.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0) AS ultimo_pago
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE c.activo = 1
           ORDER BY saldo DESC
        ''');

        final now = DateTime.now();
        final doc = await buildReporteClientes(
          titulo: 'Estado de clientes',
          empresaNombre: empresaNombre,
          periodo: Fmt.mes(now),
          rows: rows,
          logoBytes: logoBytes,
        );
        await guardarPdfConAviso(
          context,
          fileName: 'clientes_${now.year}_${now.month}.pdf',
          bytes: await doc.save(),
        );
      } else if (tipo == 'fiscal') {
        await _generarFiscal(context, empresaNombre, rango, logoBytes, cobradores);
      } else if (tipo == 'eficiencia') {
        await _generarEficiencia(
            context, empresaNombre, rango, logoBytes, cobradores);
      } else if (tipo == 'inactivos') {
        await _generarInactivos(context, empresaNombre, logoBytes);
      } else if (tipo == 'anulaciones') {
        await _generarAnulaciones(
            context, empresaNombre, rango, logoBytes, cobradores);
      } else if (tipo == 'arqueo') {
        final whereCb = cobradores == null || cobradores.isEmpty
            ? ''
            : 'WHERE cb.id IN (${List.filled(cobradores.length, '?').join(',')})';
        final rows = await ps.db.getAll(_arqueoSql(whereCb), [
          rango.desdeSql, rango.hastaSql,
          rango.desdeSql, rango.hastaSql,
          ...?cobradores,
        ]);
        final now = DateTime.now();
        final doc = await buildReporteArqueo(
          titulo: 'Arqueo / cierre por cobrador',
          empresaNombre: empresaNombre,
          periodo: rango.periodoLabel,
          rows: rows,
          logoBytes: logoBytes,
        );
        await guardarPdfConAviso(
          context,
          fileName: 'arqueo_${now.year}_${now.month}_${now.day}.pdf',
          bytes: await doc.save(),
          mensaje: 'Arqueo guardado',
        );
      }
    } catch (e) {
      if (context.mounted) {
        final msg = e is UnsupportedError
            ? (e.message?.toString() ?? 'Exportación no soportada')
            : mensajeErrorHumano(e, contexto: 'generar el reporte');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Reporte por cobrador: selector multi + query compartida (PDF y Excel)
  // ---------------------------------------------------------------------------

  /// Subtítulo del reporte por cobrador según el filtro global. `null` = todos;
  /// hasta 3 nombres se listan, más de 3 se cuentan.
  Future<String> _subtituloCobradores(Set<String>? cobradores) async {
    if (cobradores == null || cobradores.isEmpty) return 'Todos los cobradores';
    if (cobradores.length > 3) return '${cobradores.length} cobradores';
    final placeholders = List.filled(cobradores.length, '?').join(',');
    final rows = await ps.db.getAll(
        'SELECT nombre FROM cobradores WHERE id IN ($placeholders) ORDER BY nombre',
        cobradores.toList());
    return rows.map((r) => r['nombre'] as String).join(', ');
  }

  /// Filas de pagos de los cobradores elegidos, ordenadas por cobrador y fecha.
  /// `IN (?,?,...)` con placeholders dinámicos (NUNCA ANY()/ARRAY[], que son
  /// Postgres-only). Total = SUM(monto_cordobas) no anulados (invariantes #4/#10).
  Future<List<Map<String, dynamic>>> _rowsPorCobrador(
      Set<String>? cobradores, RangoReporte rango) async {
    final fc = filtroCobradorSql(cobradores);
    return ps.db.getAll('''
      SELECT p.fecha_pago, c.nombre AS cliente_nombre,
             p.monto_cordobas AS monto, p.metodo,
             p.moneda, p.monto_original, p.tasa_conversion, p.vuelto_cordobas,
             p.cobrador_id AS cobrador_id,
             cb.nombre AS cobrador_nombre, cb.rol AS cobrador_rol,
             r.numero_completo AS numero_recibo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
   LEFT JOIN recibos r ON r.pago_id = p.id
       WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
         AND date(p.fecha_pago) BETWEEN ? AND ?${fc.sql}
       ORDER BY cb.nombre, p.fecha_pago DESC
    ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);
  }

  /// Datos Excel del reporte por cobrador: una hoja con columna Cobrador (las
  /// filas vienen ordenadas por cobrador). Montos como num (sumables en Excel).
  ({List<String> headers, List<List<Object?>> filas}) _datosExcelPorCobrador(
      List<Map<String, dynamic>> rows) {
    return (
      headers: ['Cobrador', 'Rol', 'Fecha de cobro', 'Cliente',
                'Monto cobrado (C\$)', 'Moneda', 'Entregado (orig.)', 'Tasa',
                'Vuelto (C\$)', 'Método de pago', 'Nro. de recibo'],
      filas: rows.map((r) {
        final esUsd = (r['moneda']?.toString() ?? 'NIO') == 'USD';
        final vuelto = ((r['vuelto_cordobas'] as num?) ?? 0).toDouble();
        return <Object?>[
          r['cobrador_nombre']?.toString() ?? '',
          rolLabel((r['cobrador_rol'] as String?) ?? ''),
          Fmt.fechaHoraNi(r['fecha_pago'] as String?),
          r['cliente_nombre']?.toString() ?? '',
          (r['monto'] as num?) ?? 0,
          esUsd ? 'US\$' : 'C\$',
          (r['monto_original'] as num?) ?? 0,
          esUsd ? (r['tasa_conversion'] as num?) ?? '' : '',
          vuelto > 0 ? vuelto : '',
          MetodoPago.fromString(r['metodo']?.toString() ?? '').label,
          r['numero_recibo']?.toString() ?? '',
        ];
      }).toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // E1: Reporte fiscal — ingresos por mes, plan y método de pago
  // ---------------------------------------------------------------------------

  Future<void> _generarFiscal(BuildContext context, String empresaNombre,
      RangoReporte rango, Uint8List? logoBytes, Set<String>? cobradores) async {
    final fc = filtroCobradorSql(cobradores);
    final rows = await ps.db.getAll('''
      SELECT strftime('%Y-%m', cu.fecha_vencimiento) AS mes,
             COALESCE(pl.nombre, 'Sin plan') AS plan_nombre,
             p.metodo, p.moneda,
             COALESCE(SUM(p.monto_cordobas), 0) AS total_monto,
             COALESCE(SUM(p.monto_original), 0) AS total_entregado,
             COUNT(p.id) AS cantidad
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
   LEFT JOIN planes pl ON pl.id = ct.plan_id
       WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
         AND date(p.fecha_pago) BETWEEN ? AND ?${fc.sql}
       GROUP BY mes, plan_nombre, p.metodo, p.moneda
       ORDER BY mes DESC, plan_nombre, p.metodo, p.moneda
    ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);

    final now = DateTime.now();
    final doc = await buildReporteFiscal(
      titulo: 'Reporte fiscal / contable',
      empresaNombre: empresaNombre,
      periodo: rango.periodoLabel,
      rows: rows,
      logoBytes: logoBytes,
    );
    await guardarPdfConAviso(
      context,
      fileName: 'fiscal_${now.year}_${now.month}.pdf',
      bytes: await doc.save(),
    );
  }

  // ---------------------------------------------------------------------------
  // E2: Reporte eficiencia por cobrador
  // ---------------------------------------------------------------------------

  Future<void> _generarEficiencia(BuildContext context, String empresaNombre,
      RangoReporte rango, Uint8List? logoBytes, Set<String>? cobradores) async {
    final fc = filtroCobradorSql(cobradores, columna: 'cb.id');
    final rows = await ps.db.getAll('''
      SELECT cb.nombre AS cobrador_nombre,
             -- Numerador y denominador en el MISMO universo: la CARTERA ASIGNADA
             -- al cobrador (cuotas mensuales con cq.cobrador_id = cb, vencidas en el
             -- período). El numerador cuenta cuántas de ESAS cuotas se cobraron, sin
             -- importar QUIÉN registró el pago (si un admin cobra su cartera, cuenta
             -- a su favor). Antes numerador=quién-cobró (p.cobrador_id) vs
             -- denominador=asignación (cq.cobrador_id) → % engañoso: un admin cobrando
             -- bajaba el % del cobrador (decisión de producto, audit 2026-06-30).
             -- DISTINCT por cuota → paid ≤ asignadas → % ≤ 100%. Manuales excluidas.
             COUNT(DISTINCT CASE WHEN p.id IS NOT NULL THEN cu.id END) AS total_cobros,
             COUNT(DISTINCT CASE WHEN p.id IS NOT NULL THEN cu.cliente_id END) AS clientes_visitados,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto_total,
             (SELECT COUNT(*)
                FROM cuotas cq
               WHERE cq.cobrador_id = cb.id
                 AND cq.tipo_cargo_manual IS NULL
                 AND cq.estado IN ('pendiente','parcial','pagada')
                 AND date(cq.fecha_vencimiento) BETWEEN ? AND ?
             ) AS cuotas_asignadas
        FROM cobradores cb
   LEFT JOIN cuotas cu ON cu.cobrador_id = cb.id
                      AND cu.tipo_cargo_manual IS NULL
                      AND cu.estado IN ('pendiente','parcial','pagada')
                      AND date(cu.fecha_vencimiento) BETWEEN ? AND ?
   LEFT JOIN pagos p ON p.cuota_id = cu.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
       WHERE cb.rol = 'cobrador' AND cb.activo = 1${fc.sql}
       GROUP BY cb.id, cb.nombre
       ORDER BY monto_total DESC
    ''', [rango.desdeSql, rango.hastaSql, rango.desdeSql, rango.hastaSql,
          ...fc.params]);

    final now = DateTime.now();
    final doc = await buildReporteEficiencia(
      titulo: 'Eficiencia por cobrador',
      empresaNombre: empresaNombre,
      periodo: rango.periodoLabel,
      rows: rows,
      logoBytes: logoBytes,
    );
    await guardarPdfConAviso(
      context,
      fileName: 'eficiencia_${now.year}_${now.month}.pdf',
      bytes: await doc.save(),
    );
  }

  // ---------------------------------------------------------------------------
  // E3: Reporte clientes inactivos
  // ---------------------------------------------------------------------------

  Future<void> _generarInactivos(BuildContext context, String empresaNombre,
      Uint8List? logoBytes) async {
    const mesesInactividad = 3;
    final rows = await ps.db.getAll('''
      SELECT c.nombre, co.nombre AS comunidad,
             c.telefono,
             MAX(p.fecha_pago) AS ultimo_pago,
             CAST(julianday('now', '-6 hours') - julianday(MAX(p.fecha_pago))
               AS INTEGER) AS dias_sin_pago
        FROM clientes c
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
   LEFT JOIN cuotas cu ON cu.cliente_id = c.id
   LEFT JOIN pagos p ON p.cuota_id = cu.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
       WHERE c.activo = 1
       GROUP BY c.id, c.nombre, co.nombre, c.telefono
      HAVING MAX(p.fecha_pago) IS NULL
          OR MAX(p.fecha_pago) < date('now', '-6 hours', '-$mesesInactividad months')
       ORDER BY ultimo_pago ASC
    ''');

    final now = DateTime.now();
    final doc = await buildReporteInactivos(
      titulo: 'Clientes inactivos',
      empresaNombre: empresaNombre,
      periodo: Fmt.mes(now),
      rows: rows,
      mesesInactividad: mesesInactividad,
      logoBytes: logoBytes,
    );
    await guardarPdfConAviso(
      context,
      fileName: 'inactivos_${now.year}_${now.month}.pdf',
      bytes: await doc.save(),
    );
  }

  // ---------------------------------------------------------------------------
  // E4: Reporte de anulaciones
  // ---------------------------------------------------------------------------

  Future<void> _generarAnulaciones(BuildContext context, String empresaNombre,
      RangoReporte rango, Uint8List? logoBytes, Set<String>? cobradores) async {
    final fc = filtroCobradorSql(cobradores);
    final rows = await ps.db.getAll('''
      SELECT p.fecha_pago,
             c.nombre AS cliente_nombre,
             p.monto_cordobas AS monto,
             p.motivo_anulacion,
             cb_anulador.nombre AS anulado_por_nombre,
             r.numero_completo AS numero_recibo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN cobradores cb_anulador ON cb_anulador.id = p.anulado_por
   LEFT JOIN recibos r ON r.pago_id = p.id
       WHERE p.anulado = 1
         -- Filtrar por CUÁNDO se anuló (no por la fecha del cobro original): el
         -- reporte audita las anulaciones DEL PERÍODO. anulado_en es UTC → -6h
         -- da el día Nicaragua (audit 2026-06-30, decisión de producto).
         AND date(p.anulado_en, '-6 hours') BETWEEN ? AND ?${fc.sql}
       ORDER BY p.anulado_en DESC, p.fecha_pago DESC
    ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);

    final now = DateTime.now();
    final doc = await buildReporteAnulaciones(
      titulo: 'Reporte de anulaciones',
      empresaNombre: empresaNombre,
      periodo: rango.periodoLabel,
      rows: rows,
      logoBytes: logoBytes,
    );
    await guardarPdfConAviso(
      context,
      fileName: 'anulaciones_${now.year}_${now.month}.pdf',
      bytes: await doc.save(),
    );
  }

  // ---------------------------------------------------------------------------
  // E5: Exportar a Excel — sub-menú de selección de reporte
  // ---------------------------------------------------------------------------

  /// Genera el .xlsx de [tipo] con los filtros GLOBALES (período + cobradores).
  /// Llamado por el diálogo unificado. "cobranza" = plantilla estándar;
  /// "por_cobrador" arma su hoja con columna Cobrador; el resto vía _extraerDatos.
  Future<void> _generarExcel(
      BuildContext context, WidgetRef ref, String tipo) async {
    try {
      final rango = ref.read(reporteRangoProvider);
      final cobradores = ref.read(reporteCobradoresProvider);
      final empresaNombre =
          ref.read(empresaNombreProvider).valueOrNull ?? 'ISP';
      final now = DateTime.now();
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');

      // Plantilla estándar de cobranza (pagos del período + totales C$/US$).
      if (tipo == 'cobranza') {
        final fc = filtroCobradorSql(cobradores);
        final rows = await ps.db.getAll('''
          SELECT c.codigo AS cliente_codigo, c.nombre AS cliente_nombre,
                 cb.nombre AS cobrador_nombre, cu.periodo AS cuota_periodo,
                 -- El mes que se MUESTRA es el de SERVICIO (ARQUITECTURA §3.5),
                 -- no `periodo` (mes de vencimiento = etiqueta interna). Se
                 -- ancla al `dia_pago` del contrato y NO al día del
                 -- vencimiento: ese trae el ajuste domingo→lunes, que es de
                 -- COBRO y no de servicio (rompía con dia_pago 14 cuando el 14
                 -- caía domingo).
                 ct.dia_pago AS dia_pago,
                 p.fecha_pago,
                 r.numero_completo AS numero_recibo,
                 p.moneda, p.monto_original, p.monto_cordobas, p.vuelto_cordobas
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?${fc.sql}
           ORDER BY p.fecha_pago, c.nombre
        ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);
        final bytes = construirReporteCobranzaBytes(
          empresaNombre: empresaNombre,
          fechaInicial: Fmt.fechaCorta(rango.desde),
          fechaFinal: Fmt.fechaCorta(rango.hasta),
          rows: rows,
        );
        final ruta = await guardarArchivo(
          fileName: 'cobranza_${now.year}_${mm}_$dd.xlsx',
          bytes: bytes,
          extension: 'xlsx',
        );
        if (ruta != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reporte de cobranza guardado')),
          );
        }
        return;
      }

      // "Por cobrador": hoja con columna Cobrador desde la MISMA query del PDF
      // (totales idénticos — invariante de consistencia).
      if (tipo == 'por_cobrador') {
        final rows = await _rowsPorCobrador(cobradores, rango);
        final datosPC = _datosExcelPorCobrador(rows);
        final ruta = await descargarExcel(
          fileName: 'por_cobrador_${now.year}_${mm}_$dd.xlsx',
          hojaNombre: 'Por cobrador',
          headers: datosPC.headers,
          filas: datosPC.filas,
          empresaNombre: empresaNombre,
          titulo: 'Reporte por cobrador',
          periodo: rango.periodoLabel,
        );
        if (context.mounted && ruta != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reporte Excel guardado')),
          );
        }
        return;
      }

      final datos = await _extraerDatos(tipo, rango, cobradores);
      final ruta = await descargarExcel(
        fileName: '${tipo}_${now.year}_${mm}_$dd.xlsx',
        hojaNombre: _hojaNombre(tipo),
        headers: datos.headers,
        filas: datos.filas,
        empresaNombre: empresaNombre,
        titulo: _tituloReporte(tipo),
        periodo: _periodoExcel(tipo, rango),
      );
      // ruta == null cuando el usuario cancela el diálogo de guardado.
      if (context.mounted && ruta != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reporte Excel guardado')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        final msg = e is UnsupportedError
            ? (e.message?.toString() ?? 'Exportación no soportada')
            : mensajeErrorHumano(e, contexto: 'generar el Excel');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    }
  }

  /// Nombre legible de la hoja del .xlsx según el tipo de reporte.
  String _hojaNombre(String tipo) => switch (tipo) {
        'cobros' => 'Cobros',
        'mora' => 'Mora',
        'clientes' => 'Clientes',
        'padron' => 'Padrón de clientes',
        'fiscal' => 'Fiscal',
        'eficiencia' => 'Eficiencia',
        'inactivos' => 'Inactivos',
        'anulaciones' => 'Anulaciones',
        'arqueo' => 'Arqueo',
        _ => 'Reporte',
      };

  /// Título del header corporativo del .xlsx — mismos nombres que los PDF.
  String _tituloReporte(String tipo) => switch (tipo) {
        'cobros' => 'Reporte de cobros',
        'mora' => 'Reporte de mora',
        'clientes' => 'Estado de clientes',
        'padron' => 'Listado de clientes',
        'fiscal' => 'Reporte fiscal / contable',
        'eficiencia' => 'Eficiencia por cobrador',
        'inactivos' => 'Clientes inactivos',
        'anulaciones' => 'Reporte de anulaciones',
        'arqueo' => 'Arqueo / cierre por cobrador',
        _ => 'Reporte',
      };

  /// Período a mostrar en el header del .xlsx. Los reportes SIN rango global
  /// (mora/clientes/padrón = foto del estado actual) muestran la fecha de
  /// corte; inactivos describe su ventana fija.
  String _periodoExcel(String tipo, RangoReporte rango) => switch (tipo) {
        'cobros' ||
        'fiscal' ||
        'eficiencia' ||
        'anulaciones' ||
        'arqueo' =>
          rango.periodoLabel,
        'inactivos' => 'Sin pagos en los últimos 3 meses',
        _ => 'Al ${Fmt.fechaCorta(DateTime.now())}',
      };

  /// Extrae los datos de un reporte como headers + filas tipadas. Los montos y
  /// cantidades se devuelven como `num` (para que en Excel sean números
  /// sumables); el texto como `String`. MISMA fuente de queries que el CSV
  /// anterior y los PDF — solo cambia el formato de salida. El arqueo valua el
  /// USD a la tasa histórica de cada cobro (`efectivo_usd_equiv`), no necesita
  /// la tasa actual.
  Future<({List<String> headers, List<List<Object?>> filas})> _extraerDatos(
      String tipo, RangoReporte rango, Set<String>? cobradores) async {
    // Filtro de cobradores (reforma): por `p.cobrador_id` salvo los reportes
    // que agrupan por cobrador (eficiencia/arqueo → `cb.id`, ver cada case).
    final fc = filtroCobradorSql(cobradores);
    switch (tipo) {
      case 'cobros':
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago, c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto, p.metodo,
                 p.moneda, p.monto_original, p.tasa_conversion,
                 p.vuelto_cordobas,
                 cb.nombre AS cobrador_nombre,
                 r.numero_completo AS numero_recibo,
                 SUBSTR(p.grupo_cobro, 1, 8) AS ref_grupo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?${fc.sql}
           ORDER BY p.fecha_pago DESC
        ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);
        return (
          headers: ['Fecha de cobro', 'Cliente', 'Monto cobrado (C\$)',
                    'Moneda', 'Entregado (orig.)', 'Tasa', 'Vuelto (C\$)',
                    'Método de pago', 'Cobrador', 'Nro. de recibo',
                    'Ref. cobro múltiple'],
          filas: rows.map((r) {
            final esUsd = (r['moneda']?.toString() ?? 'NIO') == 'USD';
            final vuelto = ((r['vuelto_cordobas'] as num?) ?? 0).toDouble();
            return <Object?>[
              Fmt.fechaHoraNi(r['fecha_pago'] as String?),
              r['cliente_nombre']?.toString() ?? '',
              (r['monto'] as num?) ?? 0,
              esUsd ? 'US\$' : 'C\$',
              (r['monto_original'] as num?) ?? 0,
              // Tasa solo cuando es USD (en C$ siempre es 1 → ruido).
              esUsd ? (r['tasa_conversion'] as num?) ?? '' : '',
              vuelto > 0 ? vuelto : '',
              MetodoPago.fromString(r['metodo']?.toString() ?? '').label,
              r['cobrador_nombre']?.toString() ?? '',
              r['numero_recibo']?.toString() ?? '',
              r['ref_grupo']?.toString() ?? '',
            ];
          }).toList(),
        );

      case 'mora':
        final rows = await ps.db.getAll('''
          SELECT c.nombre AS cliente_nombre,
                 co.nombre AS comunidad,
                 COUNT(cu.id) AS cuotas_vencidas,
                 COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0)
                   - COALESCE(cu.monto_pagado, 0), 0)), 0) AS monto_adeudado,
                 CAST(julianday('now', '-6 hours') - julianday(MIN(cu.fecha_vencimiento)) - ?
                   AS INTEGER) AS dias_mora
            FROM cuotas cu
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE cu.estado IN ('pendiente','parcial')
             AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') != 'suspendido'
             AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                 < date('now', '-6 hours')
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY dias_mora DESC
        ''', [diasGracia, diasGracia]);
        return (
          headers: ['Cliente', 'Comunidad', 'Cuotas vencidas',
                    'Monto adeudado (C\$)', 'Días de mora'],
          filas: rows.map((r) => <Object?>[
            r['cliente_nombre']?.toString() ?? '',
            r['comunidad']?.toString() ?? '',
            (r['cuotas_vencidas'] as num?) ?? 0,
            (r['monto_adeudado'] as num?) ?? 0,
            (r['dias_mora'] as num?) ?? 0,
          ]).toList(),
        );

      case 'padron':
        // Padrón / listado de clientes: TODOS (activos + inactivos) con sus
        // datos + plan(es)/día de pago/saldo. Subqueries correlacionadas para
        // plan/día/saldo → una fila por cliente sin multiplicar el saldo por la
        // cantidad de contratos/cuotas. El saldo usa el `monto_pagado`
        // denormalizado de la cuota (invariante #7), no un JOIN a pagos.
        final rows = await ps.db.getAll('''
          SELECT c.codigo, c.nombre, c.cedula, c.telefono, c.direccion,
                 c.direccion_referencia, c.activo, c.created_at,
                 co.nombre AS comunidad,
                 cb.nombre AS cobrador,
                 (SELECT GROUP_CONCAT(DISTINCT pl.nombre)
                    FROM contratos ct JOIN planes pl ON pl.id = ct.plan_id
                   WHERE ct.cliente_id = c.id) AS planes,
                 (SELECT GROUP_CONCAT(DISTINCT ct.dia_pago)
                    FROM contratos ct WHERE ct.cliente_id = c.id) AS dias_pago,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')), 0) AS saldo
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
       LEFT JOIN cobradores cb ON cb.id = c.cobrador_id
        ORDER BY c.activo DESC, c.nombre
        ''');
        return (
          headers: [
            'Código', 'Nombre', 'Cédula', 'Teléfono', 'Dirección', 'Referencia',
            'Comunidad', 'Cobrador', 'Plan(es)', 'Día de pago',
            'Saldo pendiente (C\$)', 'Estado', 'Fecha de alta',
          ],
          filas: rows.map((r) {
            final created = r['created_at'] as String?;
            return <Object?>[
              r['codigo']?.toString() ?? '',
              r['nombre']?.toString() ?? '',
              r['cedula']?.toString() ?? '',
              r['telefono']?.toString() ?? '',
              r['direccion']?.toString() ?? '',
              r['direccion_referencia']?.toString() ?? '',
              r['comunidad']?.toString() ?? '',
              r['cobrador']?.toString() ?? '',
              r['planes']?.toString() ?? '',
              r['dias_pago']?.toString() ?? '',
              (r['saldo'] as num?)?.toDouble() ?? 0.0,
              (r['activo'] as int? ?? 1) == 1 ? 'Activo' : 'Inactivo',
              created == null ? '' : Fmt.fechaNi(created),
            ];
          }).toList(),
        );

      case 'clientes':
        final rows = await ps.db.getAll('''
          SELECT c.nombre, co.nombre AS comunidad,
                 (SELECT COUNT(*) FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')) AS pendientes,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')), 0) AS saldo,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')
                     AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') = 'suspendido'), 0) AS saldo_suspendido,
                 COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                    FROM cuotas cu
                   WHERE cu.cliente_id = c.id
                     AND cu.estado IN ('pendiente','parcial')
                     -- 'completado' entra acá: es terminal como 'cancelado' (así
                     -- lo trata el header del contrato) y el CHECK de la base
                     -- todavía lo admite, así que una app vieja puede seguir
                     -- escribiéndolo. Sin esto su deuda caería en "En ruta".
                     AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') IN ('cancelado', 'completado')), 0) AS saldo_cancelado,
                 (SELECT MAX(p.fecha_pago) FROM pagos p
                    JOIN cuotas cu2 ON cu2.id = p.cuota_id
                   WHERE cu2.cliente_id = c.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0) AS ultimo_pago
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE c.activo = 1
           ORDER BY saldo DESC
        ''');
        final filasCli = rows.map((r) {
          final ultimoPago = r['ultimo_pago'] as String?;
          final nombre = r['nombre']?.toString() ?? '';
          return <Object?>[
            marcaFueraDeRuta(nombre, r),
            r['comunidad']?.toString() ?? '',
            (r['pendientes'] as num?) ?? 0,
            (r['saldo'] as num?) ?? 0,
            ultimoPago == null ? 'Sin pagos' : Fmt.fechaNi(ultimoPago),
          ];
        }).toList();
        // Subtotales al pie: el total incluye deuda FUERA DE RUTA (suspendida
        // y cancelada — sigue en cartera y se sigue cobrando). Antes el activo
        // salía por resta de SOLO los suspendidos, así que los cancelados se
        // imprimían como activos (audit 2026-08-08: C$168.987,21 en Mairena).
        final totalSaldoCli = rows.fold<double>(
            0, (s, r) => s + ((r['saldo'] as num?) ?? 0).toDouble());
        final totalSuspCli = rows.fold<double>(0,
            (s, r) => s + ((r['saldo_suspendido'] as num?) ?? 0).toDouble());
        final totalCancCli = rows.fold<double>(0,
            (s, r) => s + ((r['saldo_cancelado'] as num?) ?? 0).toDouble());
        if (totalSuspCli > 0.009 || totalCancCli > 0.009) {
          filasCli.add(<Object?>['', '', '', '', '']);
          filasCli.add(<Object?>[
            'En ruta — contratos activos (C\$)', '', '',
            totalSaldoCli - totalSuspCli - totalCancCli, ''
          ]);
          filasCli.add(
              <Object?>['Fuera de ruta — suspendidos (C\$)', '', '', totalSuspCli, '']);
          filasCli.add(
              <Object?>['Fuera de ruta — cancelados (C\$)', '', '', totalCancCli, '']);
          filasCli.add(<Object?>['Total (C\$)', '', '', totalSaldoCli, '']);
        }
        return (
          headers: ['Cliente', 'Comunidad', 'Cuotas pendientes',
                    'Saldo pendiente (C\$)', 'Último pago'],
          filas: filasCli,
        );

      case 'fiscal':
        final rows = await ps.db.getAll('''
          SELECT strftime('%Y-%m', cu.fecha_vencimiento) AS mes,
                 COALESCE(pl.nombre, 'Sin plan') AS plan_nombre,
                 p.metodo, p.moneda,
                 COALESCE(SUM(p.monto_cordobas), 0) AS total_monto,
                 COALESCE(SUM(p.monto_original), 0) AS total_entregado,
                 COUNT(p.id) AS cantidad
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
       LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       LEFT JOIN planes pl ON pl.id = ct.plan_id
           WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?${fc.sql}
           GROUP BY mes, plan_nombre, p.metodo, p.moneda
           ORDER BY mes DESC, plan_nombre, p.metodo, p.moneda
        ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);
        return (
          headers: ['Mes', 'Plan', 'Método de pago', 'Moneda',
                    'Total recaudado (C\$)', 'Total entregado (orig.)',
                    'Cantidad de cobros'],
          filas: rows.map((r) {
            final esUsd = (r['moneda']?.toString() ?? 'NIO') == 'USD';
            return <Object?>[
              r['mes']?.toString() ?? '',
              r['plan_nombre']?.toString() ?? '',
              MetodoPago.fromString(r['metodo']?.toString() ?? '').label,
              esUsd ? 'US\$' : 'C\$',
              (r['total_monto'] as num?) ?? 0,
              // "Entregado (orig.)" solo aporta en USD (dólares físicos que
              // entran). En C$ sería recaudado+vuelto → confunde; va vacío.
              esUsd ? (r['total_entregado'] as num?) ?? 0 : '',
              (r['cantidad'] as num?) ?? 0,
            ];
          }).toList(),
        );

      case 'eficiencia':
        // Agrupa por cobrador → filtra por cb.id (no p.cobrador_id).
        final fcCb = filtroCobradorSql(cobradores, columna: 'cb.id');
        final rows = await ps.db.getAll('''
          SELECT cb.nombre AS cobrador_nombre,
                 -- MISMO universo num/denom (cartera ASIGNADA al cobrador) que el
                 -- PDF de eficiencia: cuenta cuántas de sus cuotas del período se
                 -- cobraron, sin importar quién registró el pago (decisión de
                 -- producto, audit 2026-06-30). DISTINCT por cuota → % <= 100%.
                 COUNT(DISTINCT CASE WHEN p.id IS NOT NULL THEN cu.id END) AS total_cobros,
                 COUNT(DISTINCT CASE WHEN p.id IS NOT NULL THEN cu.cliente_id END) AS clientes_visitados,
                 COALESCE(SUM(p.monto_cordobas), 0) AS monto_total,
                 (SELECT COUNT(*)
                    FROM cuotas cq
                   WHERE cq.cobrador_id = cb.id
                     AND cq.tipo_cargo_manual IS NULL
                     AND cq.estado IN ('pendiente','parcial','pagada')
                     AND date(cq.fecha_vencimiento) BETWEEN ? AND ?
                 ) AS cuotas_asignadas
            FROM cobradores cb
       LEFT JOIN cuotas cu ON cu.cobrador_id = cb.id
                          AND cu.tipo_cargo_manual IS NULL
                          AND cu.estado IN ('pendiente','parcial','pagada')
                          AND date(cu.fecha_vencimiento) BETWEEN ? AND ?
       LEFT JOIN pagos p ON p.cuota_id = cu.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
           WHERE cb.rol = 'cobrador' AND cb.activo = 1${fcCb.sql}
           GROUP BY cb.id, cb.nombre
           ORDER BY monto_total DESC
        ''', [rango.desdeSql, rango.hastaSql, rango.desdeSql, rango.hastaSql,
              ...fcCb.params]);
        return (
          headers: ['Cobrador', 'Cobros realizados', 'Clientes cobrados',
                    'Total recaudado (C\$)', 'Cuotas asignadas', '% de éxito'],
          filas: rows.map((r) {
            final cobros = ((r['total_cobros'] as num?) ?? 0).toInt();
            final asignadas = ((r['cuotas_asignadas'] as num?) ?? 0).toInt();
            // Sin cartera asignada (0 cuotas) → '—' (no medible), consistente con
            // el PDF; antes Excel mostraba '0%' engañoso (audit 2026-06-30).
            final tasa = asignadas > 0
                ? '${((cobros / asignadas) * 100).clamp(0, 100).toStringAsFixed(1)}%'
                : '—';
            return <Object?>[
              r['cobrador_nombre']?.toString() ?? '',
              cobros,
              (r['clientes_visitados'] as num?) ?? 0,
              (r['monto_total'] as num?) ?? 0,
              asignadas,
              tasa,
            ];
          }).toList(),
        );

      case 'inactivos':
        const mesesInactividad = 3;
        final rows = await ps.db.getAll('''
          SELECT c.nombre, co.nombre AS comunidad,
                 c.telefono,
                 MAX(p.fecha_pago) AS ultimo_pago,
                 CAST(julianday('now', '-6 hours') - julianday(MAX(p.fecha_pago))
                   AS INTEGER) AS dias_sin_pago
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
       LEFT JOIN cuotas cu ON cu.cliente_id = c.id
       LEFT JOIN pagos p ON p.cuota_id = cu.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
           WHERE c.activo = 1
           GROUP BY c.id, c.nombre, co.nombre, c.telefono
          HAVING MAX(p.fecha_pago) IS NULL
              OR MAX(p.fecha_pago) < date('now', '-6 hours', '-$mesesInactividad months')
           ORDER BY ultimo_pago ASC
        ''');
        return (
          headers: ['Cliente', 'Comunidad', 'Teléfono', 'Último pago',
                    'Días sin pagar'],
          filas: rows.map((r) {
            final ultimoPago = r['ultimo_pago'] as String?;
            return <Object?>[
              r['nombre']?.toString() ?? '',
              r['comunidad']?.toString() ?? '',
              r['telefono']?.toString() ?? '',
              ultimoPago == null ? 'Sin pagos' : Fmt.fechaNi(ultimoPago),
              r['dias_sin_pago'] as num?,
            ];
          }).toList(),
        );

      case 'anulaciones':
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago,
                 c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto,
                 p.motivo_anulacion,
                 cb_anulador.nombre AS anulado_por_nombre,
                 r.numero_completo AS numero_recibo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN cobradores cb_anulador ON cb_anulador.id = p.anulado_por
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE p.anulado = 1
             -- Filtrar por CUÁNDO se anuló (anulado_en, UTC-6 → día Nicaragua),
             -- IDÉNTICO al PDF (_generarAnulaciones): el reporte audita las
             -- anulaciones DEL período, no la fecha del cobro original. (Antes el
             -- Excel filtraba por fecha_pago sin -6h → divergía del PDF y violaba #1b.)
             AND date(p.anulado_en, '-6 hours') BETWEEN ? AND ?${fc.sql}
           ORDER BY p.anulado_en DESC, p.fecha_pago DESC
        ''', [rango.desdeSql, rango.hastaSql, ...fc.params]);
        return (
          headers: ['Fecha de cobro', 'Cliente', 'Monto anulado (C\$)',
                    'Motivo de anulación', 'Anulado por', 'Nro. de recibo'],
          filas: rows.map((r) => <Object?>[
            Fmt.fechaHoraNi(r['fecha_pago'] as String?),
            r['cliente_nombre']?.toString() ?? '',
            (r['monto'] as num?) ?? 0,
            r['motivo_anulacion']?.toString() ?? 'Sin motivo',
            r['anulado_por_nombre']?.toString() ?? '',
            r['numero_recibo']?.toString() ?? '',
          ]).toList(),
        );

      case 'arqueo':
        final whereCb = cobradores == null || cobradores.isEmpty
            ? ''
            : 'WHERE cb.id IN (${List.filled(cobradores.length, '?').join(',')})';
        final rows = await ps.db.getAll(_arqueoSql(whereCb), [
          rango.desdeSql, rango.hastaSql, // LEFT JOIN pagos
          rango.desdeSql, rango.hastaSql, // tabla derivada devoluciones
          ...?cobradores,
        ]);
        return (
          headers: [
            'Cobrador', 'Total de cobros', 'Efectivo (US\$)', 'Efectivo (C\$)',
            'Vuelto (C\$)', 'Devoluciones (C\$)', 'Efectivo neto (C\$)',
            'Transferencia (C\$)', 'Depósito (C\$)', 'Tarjeta (C\$)',
            'Equivalente total (C\$)', 'Ingreso total (C\$)',
          ],
          filas: rows.map((r) {
            // Matemática del arqueo en ArqueoCalculo (compartida con el PDF):
            // el USD se valúa a la tasa de cada cobro, así Equivalente total
            // cuadra con Ingreso total sin importar la tasa de hoy.
            final a = ArqueoCalculo.fromRow(r);
            return <Object?>[
              r['cobrador_nombre']?.toString() ?? '',
              (r['total_cobros'] as num?) ?? 0,
              a.efectivoUsd,
              a.efectivoNio,
              a.efectivoVuelto,
              a.devoluciones,
              a.efectivoNetoC,
              a.transferencia,
              a.deposito,
              a.tarjeta,
              a.equivalenteTotalC,
              a.ingresoTotal,
            ];
          }).toList(),
        );

      default:
        throw ArgumentError('Tipo de reporte desconocido: $tipo');
    }
  }
}

class _RecaudacionMensualCard extends StatefulWidget {
  const _RecaudacionMensualCard();

  @override
  State<_RecaudacionMensualCard> createState() =>
      _RecaudacionMensualCardState();
}

class _RecaudacionMensualCardState extends State<_RecaudacionMensualCard> {
  late final Stream<List<Map<String, dynamic>>> _recaudacionStream;

  @override
  void initState() {
    super.initState();
    _recaudacionStream = ps.db.watch(
      '''
      SELECT strftime('%Y-%m', cu.fecha_vencimiento) AS mes,
             COALESCE(SUM(pagos.monto_cordobas), 0) AS total,
             COUNT(*) AS qty
        FROM pagos
        JOIN cuotas cu ON cu.id = pagos.cuota_id
        WHERE COALESCE(pagos.anulado, 0) = 0 AND COALESCE(pagos.en_revision, 0) = 0
         AND date(pagos.fecha_pago) >= date('now', '-6 hours', '-5 months', 'start of month')
       GROUP BY mes
       ORDER BY mes
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Recaudación últimos 6 meses',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _recaudacionStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text(mensajeErrorHumano(snap.error!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return Text('Sin pagos en los últimos 6 meses',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline));
                }
                final maxTotal = rows.map((r) => (r['total'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
                return Column(
                  children: rows.map((r) {
                    final total = (r['total'] as num).toDouble();
                    final pct = maxTotal > 0 ? total / maxTotal : 0.0;
                    final mes = _mesLabel(r['mes'] as String);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(mes)),
                              Text('${r['qty']} cobros',
                                  style: TextStyle(
                                      color: Theme.of(context).colorScheme.outline,
                                      fontSize: 12)),
                              const SizedBox(width: 12),
                              Text(Fmt.cordobas(total),
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 6,
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _mesLabel(String yyyyMm) {
    final parts = yyyyMm.split('-');
    final mes = int.parse(parts[1]);
    const nombres = [
      'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
    ];
    return '${nombres[mes - 1]} ${parts[0]}';
  }
}

class _CobradoresMesCard extends StatefulWidget {
  const _CobradoresMesCard();

  @override
  State<_CobradoresMesCard> createState() => _CobradoresMesCardState();
}

class _CobradoresMesCardState extends State<_CobradoresMesCard> {
  late final Stream<List<Map<String, dynamic>>> _cobradoresMesStream;

  @override
  void initState() {
    super.initState();
    _cobradoresMesStream = ps.db.watch(
      '''
      SELECT co.id, co.nombre, co.prefijo_recibo,
             COALESCE(SUM(p.monto_cordobas), 0) AS total,
             COUNT(p.id) AS qty,
             COUNT(DISTINCT p.cuota_id) AS cuotas
        FROM cobradores co
   LEFT JOIN pagos p ON p.cobrador_id = co.id
                    AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
                    AND date(p.fecha_pago) >= date('now', '-6 hours', 'start of month')
       -- SIN filtro de rol: agrupa por QUIÉN COBRÓ (`pagos.cobrador_id`,
       -- §3.5-4b), y en la práctica cobra sobre todo la oficina. Con
       -- rol='cobrador' esta tarjeta ocultaba ~80% de la recaudación y no
       -- cerraba con el arqueo. (La "Eficiencia por cobrador" SÍ filtra por
       -- rol, y está bien: mide cartera ASIGNADA, no lo recaudado.)
       WHERE co.activo = 1
       GROUP BY co.id, co.nombre, co.prefijo_recibo
       ORDER BY total DESC
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Cobradores este mes',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _cobradoresMesStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text(mensajeErrorHumano(snap.error!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: rows.map((r) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          child: Text(
                              ((r['prefijo_recibo'] as String?) ?? '??')
                                  .padRight(2, '?')
                                  .substring(0, 2)),
                        ),
                        title: Text(r['nombre'] as String),
                        subtitle: Text('${r['qty']} cobros · ${r['cuotas']} cuotas'),
                        trailing: Text(
                          Fmt.cordobas(r['total'] as num),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      )).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MoraPorComunidadCard extends StatefulWidget {
  const _MoraPorComunidadCard({required this.diasGracia});
  final int diasGracia;

  @override
  State<_MoraPorComunidadCard> createState() => _MoraPorComunidadCardState();
}

class _MoraPorComunidadCardState extends State<_MoraPorComunidadCard> {
  late Stream<List<Map<String, dynamic>>> _moraStream;

  @override
  void initState() {
    super.initState();
    _buildStream();
  }

  @override
  void didUpdateWidget(covariant _MoraPorComunidadCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diasGracia != widget.diasGracia) {
      setState(() => _buildStream());
    }
  }

  void _buildStream() {
    _moraStream = ps.db.watch(
      '''
      SELECT co.nombre AS comunidad, m.nombre AS municipio,
             COUNT(cu.id) AS vencidas,
             COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)), 0) AS adeudo
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
        JOIN comunidades co ON co.id = c.comunidad_id
        JOIN municipios m ON m.id = co.municipio_id
       WHERE cu.estado IN ('pendiente','parcial')
         AND COALESCE((SELECT ct.estado FROM contratos ct WHERE ct.id = cu.contrato_id), 'activo') != 'suspendido'
         AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
       GROUP BY co.id, co.nombre, m.nombre
       ORDER BY adeudo DESC
       LIMIT 10
      ''',
      parameters: [widget.diasGracia],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mora por comunidad',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _moraStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text(mensajeErrorHumano(snap.error!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return Text('Sin mora — todos al día',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline));
                }
                return Column(
                  children: rows.map((r) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.warning,
                            color: Theme.of(context).colorScheme.error),
                        title: Text(r['comunidad'] as String),
                        subtitle: Text(
                            '${r['municipio']} · ${r['vencidas']} cuotas vencidas'),
                        trailing: Text(
                          Fmt.cordobas(r['adeudo'] as num),
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.error),
                        ),
                      )).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanesPopularesCard extends StatefulWidget {
  const _PlanesPopularesCard();

  @override
  State<_PlanesPopularesCard> createState() => _PlanesPopularesCardState();
}

class _PlanesPopularesCardState extends State<_PlanesPopularesCard> {
  late final Stream<List<Map<String, dynamic>>> _planesStream;

  @override
  void initState() {
    super.initState();
    _planesStream = ps.db.watch(
      '''
      SELECT p.nombre, p.precio_mensual,
             COUNT(ct.id) AS contratos
        FROM planes p
   LEFT JOIN contratos ct ON ct.plan_id = p.id AND ct.estado = 'activo'
       GROUP BY p.id, p.nombre, p.precio_mensual
       ORDER BY contratos DESC
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Planes contratados',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _planesStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text(mensajeErrorHumano(snap.error!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: rows.map((r) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.wifi),
                        title: Text(r['nombre'] as String),
                        subtitle: Text(Fmt.cordobas(r['precio_mensual'] as num)),
                        trailing: Text(
                          '${r['contratos']} contratos',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      )).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
