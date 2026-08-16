import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/busqueda_cliente.dart';
import '../../data/services/map_tile_cache.dart';
import '../../data/utils/cuota_estado_visual.dart';
import '../../data/utils/icono_helpers.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../cobro/cambio_fecha_dialog.dart';
import '../shared/widgets/filtro_multi_dropdown.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/etiqueta_chip.dart';
import '../shared/widgets/mapa_widgets_compartidos.dart';
import '../../data/utils/errores.dart';
import 'servicios/offline_routing_service.dart';

/// Centinela del dropdown de Cobrador para "Sin cobrador" (cobrador_id IS NULL),
/// como una opción más del multi-select (igual que en Cobros/Clientes).
const _kSinCobrador = '__sin_cobrador__';

/// Mapa de clientes con flutter_map + OpenStreetMap (sin API key).
/// Marcador coloreado según estado de cobranza.
class MapaScreen extends ConsumerStatefulWidget {
  const MapaScreen({super.key});

  @override
  ConsumerState<MapaScreen> createState() => _MapaScreenState();
}

/// Opción seleccionada en la fila de chips de filtro sobre el mapa.
/// `pendientes` = superconjunto cobrable en rango (mora+gracia+hoy+próxima);
/// `verTodo` (solo admin) suma fuera-de-rango y sin-deuda; el resto matchea
/// contra un único [CuotaEstadoVisual].
enum _FiltroEstado { pendientes, mora, gracia, hoy, proxima, verTodo }

/// Deriva el estado VISUAL de un cliente a partir de los counts de cuotas de su
/// row, con la precedencia mora > gracia > hoy > próxima > fuera de rango > sin
/// deuda. La usan el color/ícono del marcador y el filtro de chips, para que
/// nunca diverjan.
CuotaEstadoVisual _estadoDe(Map<String, dynamic> r) {
  final vencidas = (r['vencidas'] as int? ?? 0);
  final enGracia = (r['en_gracia'] as int? ?? 0);
  final venceHoy = (r['vence_hoy'] as int? ?? 0);
  final proximas = (r['proximas'] as int? ?? 0);
  final fueraRango = (r['fuera_rango'] as int? ?? 0);
  if (vencidas > 0) return CuotaEstadoVisual.mora;
  if (enGracia > 0) return CuotaEstadoVisual.gracia;
  if (venceHoy > 0) return CuotaEstadoVisual.hoy;
  if (proximas > 0) return CuotaEstadoVisual.proxima;
  if (fueraRango > 0) return CuotaEstadoVisual.fueraDeRango;
  return CuotaEstadoVisual.sinDeuda;
}

class _MapaScreenState extends ConsumerState<MapaScreen> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // Se recrea cuando diasGracia cambia.
  late Stream<List<Map<String, dynamic>>> _clientesStream;
  int? _lastDiasGracia;
  int? _lastDiasVisibles;
  bool? _lastSoloCobrables;

  // Estado del filtro de chips (default: lo cobrable dentro del rango).
  _FiltroEstado _filtro = _FiltroEstado.pendientes;
  // Filtros SOLO para admin, multi-selección. null = sin filtrar (todos); un
  // Set = solo esos. El cobrador ve solo sus propios clientes.
  Set<String>? _cobradorIds;
  Set<String>? _comunidadIds;
  Set<String>? _nodoIds;
  // Toggle de capa: false = calle (OSM), true = satélite (Esri).
  bool _satelite = false;
  // Cliente enfocado por la búsqueda: cuando != null, el mapa muestra SOLO su
  // pin (ignora los demás filtros) y centra/zoom en él. La X lo limpia.
  String? _clienteSeleccionadoId;
  final _mapController = MapController();
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;

  // Rotación del mapa y ruta activa offline
  double _rotationAngle = 0.0;
  List<LatLng>? _rutaActivaPoints;
  double? _rutaActivaDistancia;
  String? _rutaDestinoNombre;
  Map<String, dynamic>? _rutaDestinoCliente;
  bool _isCalculatingRoute = false;

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _mapController.dispose();
    OfflineRoutingService.instance.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (position) {
          if (mounted) {
            setState(() => _currentPosition = position);
          }
        },
        onError: (e) {
          if (kDebugMode) debugPrint('Error en stream de ubicación: $e');
        },
      );

      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null && mounted && _currentPosition == null) {
        setState(() => _currentPosition = lastPos);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error _initLocation: $e');
    }
  }

  Future<void> _centrarEnUbicacion() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('El servicio de GPS está desactivado.')),
          );
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Permiso de ubicación denegado.')),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permiso de ubicación denegado permanentemente.')),
          );
        }
        return;
      }

      if (_positionSubscription == null) {
        _initLocation();
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (mounted) {
        setState(() => _currentPosition = pos);
        _mapController.move(LatLng(pos.latitude, pos.longitude), 16.0);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo obtener la ubicación: ${mensajeErrorHumano(e)}')),
        );
      }
    }
  }

  Future<void> _trazarRuta(Map<String, dynamic> cliente) async {
    final latCliente = (cliente['latitud'] as num).toDouble();
    final lngCliente = (cliente['longitud'] as num).toDouble();

    if (_currentPosition == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se puede calcular la ruta sin tu ubicación GPS actual.'),
          ),
        );
      }
      return;
    }

    final start = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    final end = LatLng(latCliente, lngCliente);

    // Indicador de carga seguro via estado interno (no showDialog, para evitar
    // pantalla negra si el Navigator.pop falla con GoRouter).
    setState(() => _isCalculatingRoute = true);

    try {
      final routeData = await OfflineRoutingService.instance.findRoute(start, end);
      if (!mounted) return;

      if (routeData != null) {
        setState(() {
          _isCalculatingRoute = false;
          _rutaActivaPoints = routeData.path;
          _rutaActivaDistancia = routeData.distanceMetres;
          _rutaDestinoNombre = cliente['nombre'] as String;
          _rutaDestinoCliente = cliente;
        });

        // Mover la cámara del mapa para encuadrar la ruta completa
        _encuadrarRuta(routeData.path);
      } else {
        setState(() => _isCalculatingRoute = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo encontrar una ruta offline.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCalculatingRoute = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al calcular la ruta: ${mensajeErrorHumano(e)}')),
        );
      }
    }
  }

  void _encuadrarRuta(List<LatLng> points) {
    if (points.isEmpty) return;
    
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.symmetric(horizontal: 40.0, vertical: 60.0),
      ),
    );
  }

  String _formatearDistanciaRuta(double? metros) {
    if (metros == null) return '';
    if (metros < 1000) {
      return '${metros.toStringAsFixed(0)} m';
    }
    return '${(metros / 1000).toStringAsFixed(1)} km';
  }

  String _estimarTiempoRuta(double? metros) {
    if (metros == null) return '';
    // Estimar velocidad promedio de 40 km/h en calles/carreteras
    final min = (metros / 1000.0) / 40.0 * 60.0;
    if (min < 1.0) return '1 min';
    return '${min.toStringAsFixed(0)} min';
  }

  Future<void> _abrirGoogleMapsExterno() async {
    if (_rutaDestinoCliente == null) return;
    final lat = (_rutaDestinoCliente!['latitud'] as num).toDouble();
    final lng = (_rutaDestinoCliente!['longitud'] as num).toDouble();
    final uri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _seleccionarCliente(Map<String, dynamic> r) {
    setState(() => _clienteSeleccionadoId = r['id'] as String);
    final lat = (r['latitud'] as num).toDouble();
    final lng = (r['longitud'] as num).toDouble();
    // Mover tras el frame para asegurar que el MapController esté montado.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.move(LatLng(lat, lng), 16.0);
    });
  }

  void _limpiarSeleccion() => setState(() => _clienteSeleccionadoId = null);

  Future<void> _abrirBuscador(List<Map<String, dynamic>> rows) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _BuscadorClientes(
        rows: rows,
        settings: ref.read(appSettingsProvider),
      ),
    );
    if (r != null) _seleccionarCliente(r);
  }

  Stream<List<Map<String, dynamic>>> _buildStream(
      int diasGracia, int diasVisibles, bool soloCobrables) {
    // A: por defecto solo los cobrables (vencimiento_mas_viejo <= hoy +
    // diasVisibles, e.g. ~154 vs 4.442). Con la columna precalculada es una
    // comparación de FECHA — sin cruzar cuotas. NULL (sin deuda) y los fuera de
    // rango quedan afuera (date(NULL)/fecha futura no cumplen). "Ver todo"
    // (soloCobrables=false) trae todos.
    final cobrableFilter = soloCobrables
        ? "\n           AND date(c.vencimiento_mas_viejo) <= date('now','-6 hours','+' || ? || ' days')"
        : '';
    // B (acelerar "Ver todo"): las subconsultas por-cliente (contrato_codigos,
    // etiquetas) van completas en el default cobrable (~154, instantáneo) y
    // apagadas en "Ver todo" (4.442) — ahí el badge de etiqueta del pin y el
    // match por código de contrato del buscador quedan off (pines clusterizados;
    // buscador sigue por nombre/código/cédula/teléfono).
    final subContratoCodigos = soloCobrables
        ? '(SELECT GROUP_CONCAT(ct.codigo, char(30)) '
            'FROM contratos ct WHERE ct.cliente_id = c.id)'
        : 'NULL';
    final subEtiquetas = soloCobrables
        ? '(SELECT GROUP_CONCAT(e.nombre || char(31) || e.color || char(31) || e.icono, char(30)) '
            'FROM cliente_etiquetas ce JOIN etiquetas e ON e.id = ce.etiqueta_id '
            'WHERE ce.cliente_id = c.id)'
        : 'NULL';
    // Opción 2: el estado de cobro sale de `vencimiento_mas_viejo` (la cuota
    // pendiente más vieja, precalculada por el server + mirror offline) — NO se
    // cruzan ni agrupan las cuotas (eso era el cuello, ~16s en "Ver todo"). Los
    // 5 flags son 0/1: la fecha cae en UN solo bucket por su precedencia, así que
    // `_estadoDe` los lee idéntico a antes y el COLOR sigue saliendo del setting
    // coloresEstados (acá no se hardcodea ningún color). Día Nicaragua (UTC-6).
    return ps.db.watch(
      '''
        SELECT c.id, c.nombre, c.latitud, c.longitud,
               c.cobrador_id, c.comunidad_id, c.puerto_id,
               c.cedula, c.telefono, c.codigo,
               c.direccion, c.direccion_referencia,
               $subContratoCodigos AS contrato_codigos,
               co.nombre AS comunidad, mu.nombre AS municipio,
               n.id AS nodo_id, n.nombre AS nodo,
               cob.nombre AS cobrador_nombre,
               CASE WHEN c.vencimiento_mas_viejo IS NOT NULL
                   AND date(c.vencimiento_mas_viejo, '+' || ? || ' days') < date('now', '-6 hours')
                 THEN 1 ELSE 0 END AS vencidas,
               CASE WHEN c.vencimiento_mas_viejo IS NOT NULL
                   AND date(c.vencimiento_mas_viejo) < date('now', '-6 hours')
                   AND date(c.vencimiento_mas_viejo, '+' || ? || ' days') >= date('now', '-6 hours')
                 THEN 1 ELSE 0 END AS en_gracia,
               CASE WHEN c.vencimiento_mas_viejo IS NOT NULL
                   AND date(c.vencimiento_mas_viejo) = date('now', '-6 hours')
                 THEN 1 ELSE 0 END AS vence_hoy,
               CASE WHEN c.vencimiento_mas_viejo IS NOT NULL
                   AND date(c.vencimiento_mas_viejo) > date('now', '-6 hours')
                   AND date(c.vencimiento_mas_viejo) <= date('now', '-6 hours', '+' || ? || ' days')
                 THEN 1 ELSE 0 END AS proximas,
               CASE WHEN c.vencimiento_mas_viejo IS NOT NULL
                   AND date(c.vencimiento_mas_viejo) > date('now', '-6 hours', '+' || ? || ' days')
                 THEN 1 ELSE 0 END AS fuera_rango,
               $subEtiquetas AS etiquetas_concat
          FROM clientes c
     LEFT JOIN comunidades co ON co.id = c.comunidad_id
     LEFT JOIN municipios mu ON mu.id = co.municipio_id
     LEFT JOIN red_puertos p ON p.id = c.puerto_id
     LEFT JOIN red_hubs h ON h.id = p.hub_id
     LEFT JOIN red_nodos n ON n.id = h.nodo_id
     LEFT JOIN cobradores cob ON cob.id = c.cobrador_id
         WHERE c.activo = 1
           AND c.latitud IS NOT NULL
           AND c.longitud IS NOT NULL$cobrableFilter
        ''',
      // Orden de los ?: diasGracia (vencidas), diasGracia (en_gracia),
      // diasVisibles (proximas), diasVisibles (fuera_rango) + diasVisibles del
      // filtro cobrable (solo cuando soloCobrables).
      parameters: soloCobrables
          ? [diasGracia, diasGracia, diasVisibles, diasVisibles, diasVisibles]
          : [diasGracia, diasGracia, diasVisibles, diasVisibles],
    );
  }

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    final diasVisibles = settings.diasCuotasVisibles;
    final colores = settings.coloresEstados;

    // Vista admin: los roles de campo (cobrador, técnico) ven solo SUS clientes
    // → no necesitan los filtros por cobrador/zona. Los mostramos solo para los
    // roles con vista de todo el tenant (admin/admin_cobranza/super_admin).
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    // admin_tickets Y técnico son roles de SOPORTE/campo: ven el mapa como
    // directorio de ubicaciones pero NO cobranza (su bucket no baja cuotas → el
    // filtro "solo cobrables" ocultaría a los clientes al día de sus tickets). Se
    // tratan como rol de campo: sin dropdowns admin, sin chips de cobranza, y
    // muestran TODOS los clientes (no filtran por estado de cobro). El técnico
    // estaba omitido acá → sus clientes al día no aparecían (audit Fable 5).
    final esSoporte =
        (cobrador?.esAdminTickets ?? false) || (cobrador?.esTecnico ?? false);
    // #4: el cobrador comparte la vista admin del mapa (dropdowns Cobrador/
    // Zona/Nodo + "Ver todo" + todos los clientes). Técnico y soporte siguen
    // excluidos (no ven cobranza).
    final esAdminView = cobrador != null &&
        !cobrador.esTecnico &&
        !esSoporte;

    // "Ver todo" (fuera de rango + sin deuda) es exclusivo del admin. Si un rol
    // de campo quedara con ese filtro (no debería: el chip no se le muestra), lo
    // devolvemos al default cobrable.
    if (!esAdminView && _filtro == _FiltroEstado.verTodo) {
      _filtro = _FiltroEstado.pendientes;
    }

    // A: por defecto cargamos SOLO los cobrables (≈154 en vez de 4.442). "Ver
    // todo" (solo admin) y el rol Soporte (directorio) traen todos. Cambiar
    // entre filtros cobrables (mora/gracia/hoy/próxima) NO recarga —mismo set—;
    // solo togglear "Ver todo" recrea el stream.
    final soloCobrables = !esSoporte && _filtro != _FiltroEstado.verTodo;

    // Recrea el stream si diasGracia/diasVisibles/soloCobrables cambiaron (o
    // primer build). Asignación directa (no setState): ya estamos en build y
    // StreamBuilder recibe la nueva referencia en este mismo frame (audit HIGH
    // fix). Es el patrón correcto para providers de Riverpod entre builds.
    if (_lastDiasGracia != diasGracia ||
        _lastDiasVisibles != diasVisibles ||
        _lastSoloCobrables != soloCobrables) {
      _lastDiasGracia = diasGracia;
      _lastDiasVisibles = diasVisibles;
      _lastSoloCobrables = soloCobrables;
      _clientesStream = _buildStream(diasGracia, diasVisibles, soloCobrables);
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _clientesStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
        }
        // C: mientras la query corre (primera carga / "Ver todo"), SPINNER —
        // nunca el "Sin ubicaciones" falso (ese era el bug que parecía que el
        // mapa estaba vacío/roto cuando en realidad estaba calculando).
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data ?? const <Map<String, dynamic>>[];
        if (rows.isEmpty) {
          // Admin en un filtro de cobrables vacío (p.ej. un tenant que aún no
          // tiene contratos): NO hay cobrables, pero puede haber clientes con
          // ubicación. Sin este atajo, el empty state reemplaza la barra de
          // filtros y el admin queda encerrado, sin forma de tocar "Ver todo".
          if (esAdminView && _filtro != _FiltroEstado.verTodo) {
            return EmptyState(
              icon: Icons.location_searching,
              titulo: 'Sin clientes con pago pendiente',
              descripcion:
                  'No hay clientes cobrables para mostrar en el mapa. '
                  'Mirá todos los clientes con ubicación.',
              accion: FilledButton.tonalIcon(
                icon: const Icon(Icons.public, size: 18),
                label: const Text('Ver todos los clientes'),
                onPressed: () =>
                    setState(() => _filtro = _FiltroEstado.verTodo),
              ),
            );
          }
          return const EmptyState(
            icon: Icons.location_off_outlined,
            titulo: 'Sin ubicaciones',
            descripcion:
                'Ningún cliente tiene coordenadas GPS guardadas todavía.',
          );
        }

        // Centro: promedio de TODOS los puntos (no del subconjunto filtrado),
        // para que el encuadre inicial sea estable al cambiar de filtro.
        final center = _calcularCentro(rows);

        // Opciones de los dropdowns (solo admin): cobradores y zonas
        // distintas presentes en las filas cargadas, sin queries extra.
        // null = "Todos"/"Todas".
        final cobradorOpciones = esAdminView
            ? [
                const FiltroOpcion(id: _kSinCobrador, label: 'Sin cobrador'),
                ..._opcionesDistinct(
                  rows,
                  idKey: 'cobrador_id',
                  labelKey: 'cobrador_nombre',
                ),
              ]
            : const <FiltroOpcion>[];
        final comunidadOpciones = esAdminView ? _opcionesDistinct(
          rows,
          idKey: 'comunidad_id',
          labelKey: 'comunidad',
          grupoKey: 'municipio',
        ) : const <FiltroOpcion>[];
        final nodoOpciones = esAdminView ? _opcionesDistinct(
          rows,
          idKey: 'nodo_id',
          labelKey: 'nodo',
        ) : const <FiltroOpcion>[];

        // El cobrador puro no ve los dropdowns; sus filtros quedan null para
        // que nunca recorten su set de clientes.
        final cobradorIds = esAdminView ? _cobradorIds : null;
        final comunidadIds = esAdminView ? _comunidadIds : null;
        final nodoIds = esAdminView ? _nodoIds : null;

        // Si hay un cliente buscado, el mapa muestra SOLO su pin (ignora los
        // chips y dropdowns: el usuario lo eligió explícitamente). Si ese id
        // ya no está en el set (se filtró/sincronizó fuera), cae a "todos".
        final seleccionado = _clienteSeleccionadoId == null
            ? null
            : rows.cast<Map<String, dynamic>?>().firstWhere(
                  (r) => r!['id'] == _clienteSeleccionadoId,
                  orElse: () => null,
                );

        // Filtra qué clientes se muestran combinando las 3 condiciones:
        // estado (chips, _estadoDe) + cobrador + zona (dropdowns admin).
        // _estadoDe se reusa para que filtro y color del marcador no diverjan.
        final visibles = seleccionado != null
            ? [seleccionado]
            : rows.where((r) {
                // Soporte (admin_tickets): muestra TODOS los clientes como
                // directorio de ubicaciones, sin filtrar por estado de cobro.
                if (esSoporte) return true;
                final estado = _estadoDe(r);
                final pasaEstado = switch (_filtro) {
                  // Default: todo lo cobrable dentro del rango. Excluye fuera de
                  // rango y sin deuda (el cobrador nunca los ve).
                  _FiltroEstado.pendientes =>
                    estado == CuotaEstadoVisual.mora ||
                        estado == CuotaEstadoVisual.gracia ||
                        estado == CuotaEstadoVisual.hoy ||
                        estado == CuotaEstadoVisual.proxima,
                  _FiltroEstado.mora => estado == CuotaEstadoVisual.mora,
                  _FiltroEstado.gracia => estado == CuotaEstadoVisual.gracia,
                  _FiltroEstado.hoy => estado == CuotaEstadoVisual.hoy,
                  _FiltroEstado.proxima => estado == CuotaEstadoVisual.proxima,
                  // Solo admin: incluye fuera de rango y sin deuda.
                  _FiltroEstado.verTodo => true,
                };
                final pasaCobrador = cobradorIds == null ||
                    cobradorIds.contains(r['cobrador_id']) ||
                    (r['cobrador_id'] == null &&
                        cobradorIds.contains(_kSinCobrador));
                final pasaComunidad = comunidadIds == null ||
                    comunidadIds.contains(r['comunidad_id']);
                final pasaNodo =
                    nodoIds == null || nodoIds.contains(r['nodo_id']);
                return pasaEstado && pasaCobrador && pasaComunidad && pasaNodo;
              }).toList();

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 12.0,
                // Tope de cámara: el satélite hace upscale desde z17 (maxNativeZoom
                // del TileLayer). z20 da un acercamiento extra (más borroso, pero
                // útil para ubicar la casa). Ajustable.
                maxZoom: 20,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
                onMapEvent: (event) {
                  if (event.camera.rotation != _rotationAngle) {
                    setState(() {
                      _rotationAngle = event.camera.rotation;
                    });
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: _satelite
                      ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.ispbilling.app',
                  // Esri World Imagery se queda sin foto en zona rural ~z17; OSM
                  // llega a z19. maxNativeZoom topea el FETCH: más allá flutter_map
                  // agranda el último tile disponible (borroso pero continuo) en
                  // vez de pedir el placeholder gris de Esri ("Map data not yet
                  // available"). Ajustable según la cobertura rural real.
                  maxNativeZoom: _satelite ? 17 : 19,
                  tileProvider: MapTileCache.instance.tileProvider(),
                ),
                if (_rutaActivaPoints != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _rutaActivaPoints!,
                        color: Colors.blueAccent.withValues(alpha: 0.85),
                        strokeWidth: 6.0,
                        borderColor: Colors.blue.shade900,
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                  ),
                // Clustering: agrupa pines cercanos en burbujas con el total y
                // los abre al acercar el zoom. El layer renderiza SOLO lo
                // visible (culling de viewport interno) → con ~4000 clientes ya
                // no se pintan todos los pines de golpe.
                MarkerClusterLayerWidget(
                  options: MarkerClusterLayerOptions(
                    maxClusterRadius: 48,
                    size: const Size(44, 44),
                    padding: const EdgeInsets.all(50),
                    // El child de cada pin (_markerFor) ya maneja su propio
                    // onTap (_mostrarBottomSheet) → markerChildBehavior:true para
                    // que ese gesture sea el único y el tap del pin sea
                    // determinista (lo recomienda el paquete).
                    markerChildBehavior: true,
                    markers: visibles
                        .map((r) => _markerFor(context, r, colores))
                        .toList(),
                    builder: (context, markers) =>
                        _clusterBubble(context, markers.length),
                  ),
                ),
                // La ubicación actual NO se clusteriza (siempre visible).
                if (_currentPosition != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(_currentPosition!.latitude,
                            _currentPosition!.longitude),
                        width: 40,
                        height: 40,
                        child: const UbicacionActualMarker(),
                      ),
                    ],
                  ),
                MapAttributionBanner(satelite: _satelite),
              ],
            ),
            // Fila de chips de filtro por estado (overlay arriba) +, solo
            // para admin, una segunda fila con dropdowns de cobrador y zona.
            Positioned(
              top: 8,
              left: 8,
              right: 56, // deja lugar para el botón de capa
              child: SafeArea(
                bottom: false,
                // Cliente buscado → banner con su nombre + X para volver a
                // todos. Si no, los filtros normales (chips + dropdowns admin).
                child: seleccionado != null
                    ? _BannerSeleccion(
                        nombre: seleccionado['nombre'] as String,
                        onClear: _limpiarSeleccion,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Soporte no ve los chips de cobranza (no aplica).
                          if (!esSoporte)
                            _FiltroChips(
                              seleccionado: _filtro,
                              colores: colores,
                              esAdmin: esAdminView,
                              onChanged: (f) => setState(() => _filtro = f),
                            ),
                          if (esAdminView) ...[
                            const SizedBox(height: 6),
                            _FiltrosAdmin(
                              cobradorSel: _cobradorIds ??
                                  cobradorOpciones.map((o) => o.id).toSet(),
                              comunidadSel: _comunidadIds ??
                                  comunidadOpciones.map((o) => o.id).toSet(),
                              nodoSel: _nodoIds ??
                                  nodoOpciones.map((o) => o.id).toSet(),
                              cobradorOpciones: cobradorOpciones,
                              comunidadOpciones: comunidadOpciones,
                              nodoOpciones: nodoOpciones,
                              // Todos o NADA marcado → null (sin filtrar): un
                              // cobrador/zona/nodo nuevo aparece solo, y
                              // deseleccionar todo nunca deja el mapa vacío.
                              onCobradorChanged: (s) => setState(() =>
                                  _cobradorIds = s.isEmpty ||
                                          s.length >= cobradorOpciones.length
                                      ? null
                                      : s),
                              onComunidadChanged: (s) => setState(() =>
                                  _comunidadIds = s.isEmpty ||
                                          s.length >= comunidadOpciones.length
                                      ? null
                                      : s),
                              onNodoChanged: (s) => setState(() => _nodoIds =
                                  s.isEmpty || s.length >= nodoOpciones.length
                                      ? null
                                      : s),
                            ),
                          ],
                          if (esAdminView && _filtrosActivos > 0) ...[
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Material(
                                color: Theme.of(context).colorScheme.surface,
                                elevation: 2,
                                borderRadius: BorderRadius.circular(20),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: _limpiarFiltros,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 7),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.filter_alt_off,
                                            size: 16),
                                        const SizedBox(width: 6),
                                        Text('Limpiar ($_filtrosActivos)',
                                            style:
                                                const TextStyle(fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
            // Botón de búsqueda de cliente (centra/zoom en su pin). Oculto
            // mientras hay uno enfocado — el X del banner vuelve a todos.
            Positioned(
              bottom: 16,
              right: 16,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'mapa_mi_ubicacion',
                      tooltip: 'Centrar en mi ubicación',
                      onPressed: _centrarEnUbicacion,
                      child: const Icon(Icons.my_location),
                    ),
                    if (seleccionado == null) ...[
                      const SizedBox(height: 12),
                      FloatingActionButton(
                        heroTag: 'mapa_buscar',
                        tooltip: 'Buscar cliente',
                        onPressed: () => _abrirBuscador(rows),
                        child: const Icon(Icons.search),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Botón flotante para alternar calle ↔ satélite.
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                bottom: false,
                child: FloatingActionButton.small(
                  heroTag: 'mapa_capa_toggle',
                  tooltip: _satelite ? 'Ver calles' : 'Ver satélite',
                  onPressed: () => setState(() => _satelite = !_satelite),
                  child: Icon(_satelite ? Icons.map : Icons.layers),
                ),
              ),
            ),
            // Botón de brújula (solo si está rotado)
            if (_rotationAngle != 0.0)
              Positioned(
                top: 56,
                right: 8,
                child: SafeArea(
                  bottom: false,
                  child: FloatingActionButton.small(
                    heroTag: 'mapa_compass',
                    tooltip: 'Restablecer orientación al norte',
                    onPressed: () {
                      _mapController.rotate(0.0);
                      setState(() => _rotationAngle = 0.0);
                    },
                    child: Transform.rotate(
                      angle: -_rotationAngle * (pi / 180.0),
                      child: const Icon(Icons.explore),
                    ),
                  ),
                ),
              ),
            // Panel de ruta activa offline
            if (_rutaActivaPoints != null)
              Positioned(
                left: 16,
                right: 80, // deja espacio para el botón de ubicación
                bottom: 16,
                child: SafeArea(
                  child: Card(
                    elevation: 6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  'Ruta a: ${_rutaDestinoNombre ?? "Cliente"}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                constraints: const BoxConstraints(),
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: () {
                                  setState(() {
                                    _rutaActivaPoints = null;
                                    _rutaActivaDistancia = null;
                                    _rutaDestinoNombre = null;
                                    _rutaDestinoCliente = null;
                                  });
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.directions_car, size: 16, color: Colors.blueAccent),
                              const SizedBox(width: 6),
                              Text(
                                _formatearDistanciaRuta(_rutaActivaDistancia),
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(width: 12),
                              const Icon(Icons.access_time, size: 16, color: Colors.grey),
                              const SizedBox(width: 6),
                              Text(
                                _estimarTiempoRuta(_rutaActivaDistancia),
                                style: const TextStyle(fontSize: 13, color: Colors.grey),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 32,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              icon: const Icon(Icons.open_in_new, size: 14),
                              label: const Text('Abrir en Google Maps', style: TextStyle(fontSize: 12)),
                              onPressed: _abrirGoogleMapsExterno,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // Overlay de carga al calcular ruta (dentro del Stack, no showDialog,
            // para evitar la pantalla negra por context mismatch con GoRouter).
            if (_isCalculatingRoute)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x44000000),
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Calculando ruta...'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  LatLng _calcularCentro(List<Map<String, dynamic>> rows) {
    double sumLat = 0, sumLng = 0;
    for (final r in rows) {
      sumLat += (r['latitud'] as num).toDouble();
      sumLng += (r['longitud'] as num).toDouble();
    }
    return LatLng(sumLat / rows.length, sumLng / rows.length);
  }

  /// Deriva las opciones de un dropdown desde las filas ya cargadas: pares
  /// (id, label) distintos, ignorando filas con id null, ordenados por label.
  /// Sin queries extra — todo sale del stream del mapa.
  List<FiltroOpcion> _opcionesDistinct(
    List<Map<String, dynamic>> rows, {
    required String idKey,
    required String labelKey,
    String? grupoKey,
  }) {
    final byId = <String, FiltroOpcion>{};
    for (final r in rows) {
      final id = r[idKey] as String?;
      if (id == null) continue;
      byId[id] = FiltroOpcion(
        id: id,
        label: (r[labelKey] as String?) ?? id,
        grupo: grupoKey == null ? null : r[grupoKey] as String?,
      );
    }
    final opciones = byId.values.toList()
      ..sort((a, b) {
        final g = (a.grupo ?? '')
            .toLowerCase()
            .compareTo((b.grupo ?? '').toLowerCase());
        return g != 0 ? g : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return opciones;
  }

  /// Cantidad de filtros activos (cobrador/zona/nodo + chip distinto del default).
  int get _filtrosActivos {
    var n = 0;
    if (_cobradorIds != null && _cobradorIds!.isNotEmpty) n++;
    if (_comunidadIds != null && _comunidadIds!.isNotEmpty) n++;
    if (_nodoIds != null && _nodoIds!.isNotEmpty) n++;
    if (_filtro != _FiltroEstado.pendientes) n++;
    return n;
  }

  void _limpiarFiltros() => setState(() {
        _cobradorIds = null;
        _comunidadIds = null;
        _nodoIds = null;
        _filtro = _FiltroEstado.pendientes;
      });

  /// Burbuja de cluster: círculo con la cantidad de pines agrupados. Reemplaza
  /// pintar 4000 marcadores a la vez (clustering + culling de viewport los hace
  /// el propio MarkerClusterLayer: solo renderiza lo visible).
  Widget _clusterBubble(BuildContext context, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: count > 999 ? 12 : 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Marker _markerFor(
      BuildContext context, Map<String, dynamic> r, ColoresEstados colores) {
    // Reusa la derivación de estado compartida con el filtro de chips, así
    // color/ícono y filtro nunca divergen. El color sale de la paleta
    // configurable del tenant (settings → cobranza.colores_estados).
    final estado = _estadoDe(r);
    final color = colores.color(estado);
    final icono = _iconoDe(estado);
    // Punto extra: el color de la primera etiqueta del cliente (si tiene). El
    // pin sigue coloreado por ESTADO de cobro; la etiqueta no lo pisa. La lista
    // completa se ve en el popup del pin.
    final etqChips = etiquetaChipsDesdeConcat(r['etiquetas_concat']);
    final etqColor =
        etqChips.isEmpty ? null : colorFromHex(etqChips.first.colorHex);
    final etqIcono =
        etqChips.isEmpty ? null : iconoEtiqueta(etqChips.first.iconoKey);

    return Marker(
      point: LatLng(
        (r['latitud'] as num).toDouble(),
        (r['longitud'] as num).toDouble(),
      ),
      width: 40,
      height: 40,
      child: GestureDetector(
        onTap: () => _mostrarBottomSheet(context, r),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2)),
                ],
              ),
              child: Icon(icono, color: Colors.white, size: 20),
            ),
            if (etqColor != null)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: etqColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Icon(etqIcono, size: 9, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _iconoDe(CuotaEstadoVisual estado) => switch (estado) {
        CuotaEstadoVisual.mora => Icons.warning,
        CuotaEstadoVisual.gracia => Icons.hourglass_bottom,
        CuotaEstadoVisual.hoy => Icons.payments,
        CuotaEstadoVisual.proxima => Icons.schedule,
        CuotaEstadoVisual.fueraDeRango => Icons.more_time,
        CuotaEstadoVisual.sinDeuda => Icons.check,
      };

  void _mostrarBottomSheet(BuildContext context, Map<String, dynamic> r) {
    // El técnico no ve cobranza ni "Pagar"/"Ver cliente" (su SQLite no tiene
    // cuotas y /clientes/:id lo rebota) — sí ve contacto + ruta. B8 del audit.
    // Soporte (admin_tickets) y técnico ocultan "Pagar"/"Ver cliente" (sin
    // cuotas sincronizadas y /clientes/:id los rebota) — ven contacto + ruta.
    final cob = ref.read(cobradorActualProvider).valueOrNull;
    final esTecnico =
        (cob?.esTecnico ?? false) || (cob?.esAdminTickets ?? false);
    // `lectura` entra acá igual que admin_usuarios: ve la ficha, sin el
    // botón de cobrar (denylist — un rol nuevo hereda permiso si no se suma).
    final sinDinero = (cob?.esAdminUsuarios ?? false) || (cob?.esLectura ?? false);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ClientePinSheet(
        row: r,
        esTecnico: esTecnico,
        sinDinero: sinDinero,
        onTrazarRuta: () => _trazarRuta(r),
      ),
    );
  }
}

/// Cuota pendiente más vieja de un contrato (para el botón "Pagar" del mapa).
typedef _ContratoCuota = ({
  String contratoId,
  String? planNombre,
  int? diaPago,
  double? precioMensual,
  String cuotaId,
  String periodo,
  double saldo,
});

/// Popup del pin de cliente en el mapa: foto de la casa + contacto + acciones
/// (llamar, ruta, ver cliente, pagar la cuota más vieja). Acceso rápido de campo.
class _ClientePinSheet extends ConsumerStatefulWidget {
  const _ClientePinSheet({
    required this.row,
    required this.esTecnico,
    this.sinDinero = false,
    required this.onTrazarRuta,
  });
  final Map<String, dynamic> row;
  final bool esTecnico;
  final bool sinDinero;
  final VoidCallback onTrazarRuta;

  @override
  ConsumerState<_ClientePinSheet> createState() => _ClientePinSheetState();
}

class _ClientePinSheetState extends ConsumerState<_ClientePinSheet> {
  late final Future<String?> _fotoUrl;
  late final Future<List<_ContratoCuota>> _contratos;

  String get _clienteId => widget.row['id'] as String;

  @override
  void initState() {
    super.initState();
    _fotoUrl = _cargarFoto();
    _contratos = (widget.esTecnico || widget.sinDinero)
        ? Future.value(const <_ContratoCuota>[])
        : _cargarContratosConCuota();
  }

  /// URL firmada de la PRIMERA foto del cliente (la galería que ya existe).
  Future<String?> _cargarFoto() async {
    try {
      final rows = await ps.db.getAll(
        'SELECT storage_path FROM fotos_cliente WHERE cliente_id = ? '
        'ORDER BY created_at ASC LIMIT 1',
        [_clienteId],
      );
      if (rows.isEmpty) return null;
      final path = rows.first['storage_path'] as String;
      return await Supabase.instance.client.storage
          .from('fotos-clientes')
          .createSignedUrl(path, 86400);
    } catch (_) {
      return null; // sin foto / sin red: la UI cae a un placeholder
    }
  }

  /// Un row por contrato activo que tenga cuota pendiente, con su cuota MÁS
  /// VIEJA (la que se cobraría). Ordenados por antigüedad del contrato.
  Future<List<_ContratoCuota>> _cargarContratosConCuota() async {
    final rows = await ps.db.getAll(
      '''
      SELECT ct.id AS contrato_id, p.nombre AS plan_nombre, p.precio_mensual,
             ct.dia_pago, cu.id AS cuota_id, cu.periodo,
             max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0) AS saldo
        FROM contratos ct
        LEFT JOIN planes p ON p.id = ct.plan_id
        JOIN cuotas cu ON cu.id = (
             SELECT cu2.id FROM cuotas cu2
              WHERE cu2.contrato_id = ct.id
                AND cu2.estado IN ('pendiente','parcial')
              ORDER BY cu2.fecha_vencimiento ASC, cu2.periodo ASC
              LIMIT 1)
       WHERE ct.cliente_id = ?
         AND COALESCE(ct.estado, 'activo') = 'activo'
       ORDER BY ct.fecha_inicio ASC
      ''',
      [_clienteId],
    );
    return rows
        .map((r) => (
              contratoId: r['contrato_id'] as String,
              planNombre: r['plan_nombre'] as String?,
              diaPago: (r['dia_pago'] as num?)?.toInt(),
              precioMensual: (r['precio_mensual'] as num?)?.toDouble(),
              cuotaId: r['cuota_id'] as String,
              periodo: r['periodo'] as String,
              saldo: ((r['saldo'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  Future<void> _llamar(String tel) async {
    final uri = Uri(scheme: 'tel', path: tel.replaceAll(RegExp(r'[^0-9+]'), ''));
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _ruta() {
    Navigator.pop(context); // cierra el sheet
    widget.onTrazarRuta();  // traza la ruta interna en el mapa
  }

  void _irACobro(String cuotaId) {
    Navigator.pop(context); // cierra el sheet
    context.push('/cobro/$cuotaId');
  }

  /// Botón "Pagar": 1 contrato → directo a la cuota; 2+ → selector de servicio.
  Future<void> _pagar(List<_ContratoCuota> contratos) async {
    if (contratos.length == 1) {
      _irACobro(contratos.first.cuotaId);
      return;
    }
    final elegido = await showModalBottomSheet<_ContratoCuota>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('¿Qué servicio cobrás?',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            for (final c in contratos)
              ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(c.planNombre ?? 'Servicio'),
                subtitle: Text(
                    '${Fmt.mesServicioLabel(DateTime.parse(c.periodo), c.diaPago)} · ${Fmt.cordobas(c.saldo)}'),
                onTap: () => Navigator.pop(context, c),
              ),
          ],
        ),
      ),
    );
    if (elegido != null && mounted) _irACobro(elegido.cuotaId);
  }

  /// Botón "Cambiar fecha de pago" (feature C): 1 contrato elegible → diálogo
  /// directo; 2+ → selector. Al cobrar el puente, cierra el sheet y va al recibo.
  Future<void> _cambiarFecha(List<_ContratoCuota> contratos) async {
    final elegibles = contratos
        .where((c) => c.diaPago != null && c.precioMensual != null)
        .toList();
    if (elegibles.isEmpty) return;
    _ContratoCuota? elegido = elegibles.length == 1 ? elegibles.first : null;
    elegido ??= await showModalBottomSheet<_ContratoCuota>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('¿A qué servicio le cambiás la fecha?',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              for (final c in elegibles)
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: Text(c.planNombre ?? 'Servicio'),
                  subtitle: Text('Día de pago actual: ${c.diaPago}'),
                  onTap: () => Navigator.pop(context, c),
                ),
            ],
          ),
        ),
      );
    if (elegido == null || !mounted) return;
    final sel = elegido;
    final reciboId = await showDialog<String>(
      context: context,
      builder: (_) => CambioFechaDialog(
        contratoId: sel.contratoId,
        diaPagoActual: sel.diaPago!,
        precioMensual: sel.precioMensual!,
        clienteNombre: widget.row['nombre'] as String?,
      ),
    );
    if (reciboId != null && mounted) {
      Navigator.pop(context); // cierra el sheet del pin
      context.push('/recibo/$reciboId');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = widget.row;
    final nombre = r['nombre'] as String;
    final tel = (r['telefono'] as String?)?.trim();
    final direccion = (r['direccion'] as String?)?.trim();
    final referencia = (r['direccion_referencia'] as String?)?.trim();
    // #4: "Cambiar fecha" sigue OWNER-SCOPED en el server (trigger 0119). Para
    // un cobrador sólo se muestra sobre SUS clientes: si no, el cambio se
    // aplicaría local y el server lo rechazaría → cobro fantasma. Admin/
    // admin_cobranza pueden sobre cualquiera.
    final yoMapa = ref.watch(cobradorActualProvider).valueOrNull;
    final puedeCambiarFecha = ref.watch(puedeCambiarFechaPagoProvider) &&
        (!(yoMapa?.esCobrador ?? false) ||
            (r['cobrador_id'] as String?) == yoMapa?.id);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Foto de la casa (primera de la galería).
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: FutureBuilder<String?>(
                  future: _fotoUrl,
                  builder: (_, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return Container(
                        color: scheme.surfaceContainerHighest,
                        child: const Center(
                            child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))),
                      );
                    }
                    final url = snap.data;
                    if (url == null) {
                      return Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.home_outlined,
                            size: 48, color: scheme.outline),
                      );
                    }
                    return Image.network(url, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) {
                      return Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.broken_image_outlined,
                            size: 40, color: scheme.outline),
                      );
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(nombre, style: Theme.of(context).textTheme.titleMedium),
            // Etiquetas del cliente (P5).
            Builder(builder: (_) {
              final chips =
                  etiquetaChipsDesdeConcat(r['etiquetas_concat'], dense: false);
              if (chips.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: chips),
              );
            }),
            // Teléfono con botón de llamar.
            if (tel != null && tel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.phone, size: 16, color: scheme.outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(tel)),
                    TextButton.icon(
                      icon: const Icon(Icons.call, size: 18),
                      label: const Text('Llamar'),
                      onPressed: () => _llamar(tel),
                    ),
                  ],
                ),
              ),
            if (direccion != null && direccion.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 16, color: scheme.outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(direccion)),
                  ],
                ),
              ),
            if (referencia != null && referencia.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.signpost_outlined,
                        size: 16, color: scheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(referencia,
                            style: TextStyle(color: scheme.outline))),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            // Acciones secundarias: Ruta + Ver cliente.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Ruta'),
                    onPressed: _ruta,
                  ),
                ),
                if (!widget.esTecnico) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.person_outline, size: 18),
                      label: const Text('Ver cliente'),
                      onPressed: () {
                        Navigator.pop(context);
                        context.push('/clientes/$_clienteId');
                      },
                    ),
                  ),
                ],
              ],
            ),
            // Botón principal: Pagar la cuota más vieja.
            if (!widget.esTecnico && !widget.sinDinero)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FutureBuilder<List<_ContratoCuota>>(
                  future: _contratos,
                  builder: (_, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const FilledButton(
                          onPressed: null, child: Text('Cargando cuotas…'));
                    }
                    final cuotas = snap.data ?? const [];
                    if (cuotas.isEmpty) {
                      return const FilledButton(
                          onPressed: null,
                          child: Text('Sin cuotas pendientes'));
                    }
                    final unica = cuotas.length == 1;
                    final label = unica
                        ? 'Pagar ${Fmt.mesServicioLabel(DateTime.parse(cuotas.first.periodo), cuotas.first.diaPago)} · ${Fmt.cordobas(cuotas.first.saldo)}'
                        : 'Pagar cuota (${cuotas.length} servicios)';
                    final puedeCambiar = puedeCambiarFecha &&
                        cuotas.any((c) =>
                            c.diaPago != null && c.precioMensual != null);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.payments),
                          label: Text(label),
                          onPressed: () => _pagar(cuotas),
                        ),
                        if (puedeCambiar) ...[
                          const SizedBox(height: 6),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.edit_calendar_outlined,
                                size: 18),
                            label: const Text('Cambiar fecha de pago'),
                            onPressed: () => _cambiarFecha(cuotas),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Fila de chips de filtro por estado de cobranza, sobre el mapa. Cada chip de
/// estado lleva un punto con el color configurado (leyenda viva). "Ver todo"
/// (que revela fuera-de-rango y sin-deuda) solo aparece para la vista admin.
class _FiltroChips extends StatelessWidget {
  const _FiltroChips({
    required this.seleccionado,
    required this.onChanged,
    required this.colores,
    required this.esAdmin,
  });

  final _FiltroEstado seleccionado;
  final ValueChanged<_FiltroEstado> onChanged;
  final ColoresEstados colores;
  final bool esAdmin;

  // (filtro, label, color del punto). null = sin punto (Pendientes / Ver todo).
  List<(_FiltroEstado, String, Color?)> _opciones() => [
        (_FiltroEstado.pendientes, 'Pendientes', null),
        (_FiltroEstado.mora, 'En mora', colores.mora),
        (_FiltroEstado.gracia, 'En gracia', colores.gracia),
        (_FiltroEstado.hoy, 'Vencen hoy', colores.hoy),
        (_FiltroEstado.proxima, 'Próximas', colores.proxima),
        if (esAdmin) (_FiltroEstado.verTodo, 'Ver todo', null),
      ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final (estado, label, punto) in _opciones())
          ChoiceChip(
            label: Text(label),
            avatar: punto == null
                ? null
                : CircleAvatar(backgroundColor: punto, radius: 6),
            selected: seleccionado == estado,
            visualDensity: VisualDensity.compact,
            // Fondo opaco para que se lea sobre el tile del mapa.
            backgroundColor: Theme.of(context).colorScheme.surface,
            onSelected: (_) => onChanged(estado),
          ),
      ],
    );
  }
}

/// Segunda fila de filtros del overlay, SOLO para la vista admin: dropdowns
/// de cobrador y zona (comunidad). Las opciones se derivan de las filas del
/// mapa; null = "Todos"/"Todas". El cobrador puro no ve esta fila.
class _FiltrosAdmin extends StatelessWidget {
  const _FiltrosAdmin({
    required this.cobradorSel,
    required this.comunidadSel,
    required this.nodoSel,
    required this.cobradorOpciones,
    required this.comunidadOpciones,
    required this.nodoOpciones,
    required this.onCobradorChanged,
    required this.onComunidadChanged,
    required this.onNodoChanged,
  });

  final Set<String> cobradorSel;
  final Set<String> comunidadSel;
  final Set<String> nodoSel;
  final List<FiltroOpcion> cobradorOpciones;
  final List<FiltroOpcion> comunidadOpciones;
  final List<FiltroOpcion> nodoOpciones;
  final ValueChanged<Set<String>> onCobradorChanged;
  final ValueChanged<Set<String>> onComunidadChanged;
  final ValueChanged<Set<String>> onNodoChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        FiltroMultiDropdown(
          icon: Icons.person_outline,
          hint: 'Cobrador',
          buscarHint: 'Buscar cobrador…',
          opciones: cobradorOpciones,
          seleccionados: cobradorSel,
          onChanged: onCobradorChanged,
        ),
        FiltroMultiDropdown(
          icon: Icons.place_outlined,
          hint: 'Zona',
          buscarHint: 'Buscar municipio o comunidad…',
          opciones: comunidadOpciones,
          seleccionados: comunidadSel,
          onChanged: onComunidadChanged,
        ),
        FiltroMultiDropdown(
          icon: Icons.hub_outlined,
          hint: 'Nodo',
          buscarHint: 'Buscar nodo…',
          opciones: nodoOpciones,
          seleccionados: nodoSel,
          onChanged: onNodoChanged,
        ),
      ],
    );
  }
}

/// Banner que reemplaza los filtros cuando hay un cliente enfocado por la
/// búsqueda: muestra su nombre y una X para volver a ver todos los pines.
class _BannerSeleccion extends StatelessWidget {
  const _BannerSeleccion({required this.nombre, required this.onClear});

  final String nombre;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                nombre,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              visualDensity: VisualDensity.compact,
              tooltip: 'Ver todos',
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet para buscar un cliente por nombre entre los que tienen
/// ubicación. Devuelve la fila elegida (o null si se cierra sin elegir).
class _BuscadorClientes extends StatefulWidget {
  const _BuscadorClientes({required this.rows, required this.settings});

  final List<Map<String, dynamic>> rows;
  final AppSettings settings;

  @override
  State<_BuscadorClientes> createState() => _BuscadorClientesState();
}

class _BuscadorClientesState extends State<_BuscadorClientes> {
  String _q = '';

  /// Matchea por nombre/código/cédula/teléfono/código de contrato, respetando
  /// los toggles de búsqueda configurable (super_admin) vía el helper compartido
  /// `busquedaClienteMatch`. Variante client-side (filtra en Dart las filas ya
  /// cargadas del mapa).
  bool _matches(Map<String, dynamic> r, String q) {
    return busquedaClienteMatch(
      q,
      widget.settings,
      nombre: r['nombre'] as String?,
      codigo: r['codigo'] as String?,
      cedula: r['cedula'] as String?,
      telefono: r['telefono'] as String?,
      contratoCodigos: r['contrato_codigos'] as String?,
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtradas = widget.rows.where((r) => _matches(r, _q)).toList()
      ..sort((a, b) => (a['nombre'] as String)
          .toLowerCase()
          .compareTo((b['nombre'] as String).toLowerCase()));

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Nombre, cédula, teléfono o código',
            ),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          if (filtradas.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Sin clientes con ubicación que coincidan'),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtradas.length,
                itemBuilder: (_, i) {
                  final r = filtradas[i];
                  // Subtítulo: código de cliente + comunidad, para desambiguar
                  // homónimos al buscar por nombre.
                  final sub = [r['codigo'], r['comunidad']]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · ');
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(r['nombre'] as String),
                    subtitle: sub.isEmpty ? null : Text(sub),
                    onTap: () => Navigator.pop(context, r),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}


