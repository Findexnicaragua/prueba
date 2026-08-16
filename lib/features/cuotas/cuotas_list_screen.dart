import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/cuotas_filtro_provider.dart';
import '../../data/providers/db_epoch_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/busqueda_cliente.dart';
import '../../data/utils/cuota_estado_visual.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../cobro/cambio_fecha_dialog.dart';
import '../shared/widgets/filtro_multi_dropdown.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/etiqueta_chip.dart';
import 'cobros_query.dart';
import '../contratos/cuota_detalle_lectura.dart';

/// Pantalla de Cobros ("Por cobrar"). La usa el cobrador (móvil-first, su vista
/// de trabajo) y el admin/admin_cobranza (`adminMode: true`).
///
/// Muestra UNA fila por contrato = su cuota MÁS ANTIGUA pendiente (igual que el
/// pin del mapa), con botón "Pagar" que va directo al cobro de esa cuota. Tocar
/// la fila abre el detalle del cliente. Tiene buscador de clientes + (en
/// adminMode) filtros chip-dropdown Cobrador/Zona + los chips de estado.
class CuotasListScreen extends ConsumerStatefulWidget {
  const CuotasListScreen({super.key, this.adminMode = false});

  /// Cuando true, habilita la vista admin: filtros por cobrador/zona y sin
  /// el redirect automático de admins a /admin.
  final bool adminMode;

  @override
  ConsumerState<CuotasListScreen> createState() => _CuotasListScreenState();
}

class _CuotasListScreenState extends ConsumerState<CuotasListScreen> {
  CobrosFiltro _filtro = CobrosFiltro.todas;

  // Toggle "Ver fuera de ruta" (recuperación): off por defecto. Cuando se
  // prende, se ANEXA una sección con la deuda de contratos cancelados/
  // suspendidos (no reemplaza la ruta activa). Cobrador y admin. Se ve tanto en
  // la vista del cobrador como en adminMode.
  bool _verFueraDeRuta = false;

  // Filtros admin multi-selección. null = sin filtrar (todos); un Set = solo
  // esos. Sólo se usan/muestran en adminMode.
  Set<String>? _cobradorIds;
  Set<String>? _comunidadIds;

  // Búsqueda de cliente (client-side sobre lo ya cargado, sin recrear el
  // stream en cada tecla). Plegada a forma canónica ASCII (foldBusqueda).
  final _busquedaCtrl = TextEditingController();
  String _busqueda = '';
  // Debounce del buscador (la lista filtra client-side; con miles de clientes
  // re-filtrar en cada tecla tironea).
  Timer? _busquedaDebounce;

  // Streams de opciones de los dropdowns (sólo adminMode). Cacheados en
  // initState para no recrear suscripciones en cada build (anti-patrón
  // ps.db.watch inline). Cobradores activos del tenant + comunidades con
  // clientes activos.
  // No-final: se reasignan al recrear la DB (dbEpochProvider, #7) para no quedar
  // colgados de la conexión cerrada → ClosedException en el cold-start.
  late Stream<List<Map<String, dynamic>>> _cobradorOpcionesStream;
  late Stream<List<Map<String, dynamic>>> _comunidadOpcionesStream;

  @override
  void initState() {
    super.initState();
    if (widget.adminMode) _buildAdminStreams();
  }

  /// (Re)crea los streams de los dropdowns admin. Se llama en initState y cada
  /// vez que la DB se recrea (dbEpochProvider) para no leer de una DB cerrada.
  void _buildAdminStreams() {
    // Cobradores activos del tenant (rol cobrador). RLS scopa por tenant.
    _cobradorOpcionesStream = ps.db.watch('''
      SELECT id, nombre
        FROM cobradores
       WHERE rol = 'cobrador' AND activo = 1
       ORDER BY nombre
    ''');
    // Comunidades que tienen al menos un cliente activo asignado.
    _comunidadOpcionesStream = ps.db.watch('''
      SELECT co.id AS id, co.nombre AS nombre, mu.nombre AS municipio
        FROM comunidades co
        JOIN clientes c ON c.comunidad_id = co.id AND c.activo = 1
   LEFT JOIN municipios mu ON mu.id = co.municipio_id
       GROUP BY co.id, co.nombre, mu.nombre
       ORDER BY mu.nombre, co.nombre
    ''');
  }

  @override
  void dispose() {
    _busquedaDebounce?.cancel();
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<void> _marcarMoraComoVista() async {
    // vista_por es uuid FK a cobradores(id): hay que escribir el id del
    // cobrador, NUNCA el literal 'cobrador' — rompía el sync con "invalid
    // input syntax for type uuid". Este UPDATE marca las no-vistas Y repara
    // las que el bug previo dejó con el literal (solo las PROPIAS: las legacy
    // con cobrador_id NULL/ajeno quedan fuera A PROPÓSITO — no alimentan el
    // badge, el server nunca aceptó el literal y PowerSync las revierte solo).
    final cobradorId = ref.read(cobradorActualProvider).valueOrNull?.id;
    if (cobradorId == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    // Scoped a cobrador_id = él (audit 2026-07-03): la RLS notif_update_marca
    // solo le permite marcar la mora PROPIA — marcar de más era optimismo
    // local que el server revertía (y ensuciaba la cola de sync). Alineado
    // con el badge (mora_count_provider), que también cuenta solo la propia.
    await ps.dbW.execute('''
      UPDATE notificaciones_mora
      SET vista_en = COALESCE(vista_en, ?), vista_por = ?
      WHERE resuelta_en IS NULL
        AND cobrador_id = ?
        AND (vista_en IS NULL OR vista_por = 'cobrador')
    ''', [now, cobradorId, cobradorId]);
  }

  /// Convierte las filas de un stream de opciones (id/nombre, opcional
  /// `municipio`) a `FiltroOpcion`. El `municipio` (si viene) habilita la
  /// jerarquía del dropdown (agrupa comunidades por municipio). Filas con id
  /// null se ignoran.
  List<FiltroOpcion> _opciones(List<Map<String, dynamic>> rows) {
    final out = <FiltroOpcion>[];
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null) continue;
      out.add(FiltroOpcion(
        id: id,
        label: (r['nombre'] as String?) ?? id,
        grupo: r['municipio'] as String?,
      ));
    }
    return out;
  }

  /// Fila de dos chip-dropdowns ("Cobrador" / "Zona") para la vista admin.
  /// Cada uno se alimenta de su stream cacheado en initState. null = todos /
  /// todas. Mismo widget compartido (`FiltroMultiDropdown`) que usa el mapa.
  Widget _buildFiltrosAdmin() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _cobradorOpcionesStream,
            initialData: const [],
            builder: (context, snap) {
              final opts = <FiltroOpcion>[
                const FiltroOpcion(
                    id: kSinCobradorFiltro, label: 'Sin cobrador'),
                ..._opciones(snap.data ?? const []),
              ];
              final allIds = opts.map((o) => o.id).toSet();
              return FiltroMultiDropdown(
                icon: Icons.person_outline,
                hint: 'Cobrador',
                buscarHint: 'Buscar cobrador…',
                opciones: opts,
                seleccionados: _cobradorIds ?? allIds,
                // Todos o NADA marcado = sin filtrar (null) → un cobrador nuevo
                // aparece solo, y deseleccionar todo nunca da lista vacía.
                onChanged: (s) => setState(() => _cobradorIds =
                    s.isEmpty || s.length >= allIds.length ? null : s),
              );
            },
          ),
          const SizedBox(width: 8),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _comunidadOpcionesStream,
            initialData: const [],
            builder: (context, snap) {
              final opts = _opciones(snap.data ?? const []);
              final allIds = opts.map((o) => o.id).toSet();
              return FiltroMultiDropdown(
                icon: Icons.place_outlined,
                hint: 'Zona',
                buscarHint: 'Buscar municipio o comunidad…',
                opciones: opts,
                seleccionados: _comunidadIds ?? allIds,
                onChanged: (s) => setState(() => _comunidadIds =
                    s.isEmpty || s.length >= allIds.length ? null : s),
              );
            },
          ),
          const Spacer(),
          if (_filtrosActivos > 0)
            TextButton.icon(
              icon: const Icon(Icons.filter_alt_off, size: 18),
              label: Text('Limpiar ($_filtrosActivos)'),
              onPressed: _limpiarFiltros,
            ),
        ],
      ),
    );
  }

  /// Cantidad de filtros activos (cobrador/zona + chip distinto del default +
  /// toggle fuera de ruta) — para el botón "Limpiar (N)".
  int get _filtrosActivos {
    var n = 0;
    if (_cobradorIds != null && _cobradorIds!.isNotEmpty) n++;
    if (_comunidadIds != null && _comunidadIds!.isNotEmpty) n++;
    if (_filtro != CobrosFiltro.todas) n++;
    if (_verFueraDeRuta) n++;
    return n;
  }

  void _limpiarFiltros() {
    _busquedaDebounce?.cancel();
    _busquedaCtrl.clear();
    setState(() {
      _cobradorIds = null;
      _comunidadIds = null;
      _filtro = CobrosFiltro.todas;
      _verFueraDeRuta = false;
      _busqueda = '';
    });
  }

  /// Buscador de cliente. Filtra client-side la lista ya cargada (no recrea el
  /// stream). Mismos criterios que el buscador del mapa: nombre/cédula/teléfono/
  /// código.
  Widget _buildBuscador() {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _busquedaCtrl,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: placeholderBusqueda(settings),
          suffixIcon: _busqueda.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Limpiar',
                  onPressed: () {
                    _busquedaDebounce?.cancel();
                    _busquedaCtrl.clear();
                    setState(() => _busqueda = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) {
          // Debounce: con miles de clientes, re-filtrar en cada tecla tironea.
          _busquedaDebounce?.cancel();
          _busquedaDebounce = Timer(const Duration(milliseconds: 250), () {
            // Plegar a forma canónica ASCII (ñ/acentos → base) igual que el
            // resto de la app (regla #1d). `busquedaClienteMatch` también pliega
            // ambos lados; `foldBusqueda` es idempotente, así que no dobla.
            if (mounted) setState(() => _busqueda = foldBusqueda(v.trim()));
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Cold-start: al recrear la DB (cambio de schema) los streams admin quedan
    // colgados de la conexión cerrada → recrearlos. (#7 / regla audit #2)
    ref.listen(dbEpochProvider, (_, __) {
      if (mounted && widget.adminMode) setState(_buildAdminStreams);
    });

    final settings = ref.watch(appSettingsProvider);

    // Safety-net del cold-start: '/' (= Cobros) es la landing del cobrador.
    // Si el router aún no resolvió el rol y un admin/admin_cobranza/super_admin
    // cayó acá, lo reencaminamos a /admin cuando llega su rol. Redundante con el
    // redirect del router, pero evita el flash de la pantalla del cobrador.
    //
    // En adminMode NO aplica: el admin entra a propósito a /admin/cobros y
    // debe quedarse acá (esta MISMA pantalla es su vista de monitoreo/cobro).
    if (!widget.adminMode) {
      final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
      if ((cobrador != null && cobrador.tieneAccesoAdmin) ||
          cobrador?.esAdminCobranza == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.go('/admin');
        });
      }
    }

    final diasGracia = settings.diasGracia;
    final diasVisibles = settings.diasCuotasVisibles;

    // El filtro "Parciales" se muestra si el tenant permite pago parcial O si ya
    // hay cuotas parciales (históricas). Si el filtro activo dejó de estar
    // disponible, usamos 'todas' como EFECTIVO sin mutar el estado en build
    // (anti-patrón); el chip elegido por el usuario se conserva en _filtro.
    final mostrarParcial = settings.pagoParcialPermitido ||
        (ref.watch(hayCuotasParcialesProvider).valueOrNull ?? false);
    var filtroEfectivo = _filtro;
    if (!mostrarParcial && filtroEfectivo == CobrosFiltro.parciales) {
      filtroEfectivo = CobrosFiltro.todas;
    }
    if (!widget.adminMode && filtroEfectivo == CobrosFiltro.verTodo) {
      filtroEfectivo = CobrosFiltro.todas;
    }

    return Column(
      children: [
        // Filtros admin (cobrador / zona) — sólo en adminMode.
        if (widget.adminMode) _buildFiltrosAdmin(),
        _buildBuscador(),
        // Chips de estado.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              for (final f in CobrosFiltro.values)
                if ((mostrarParcial || f != CobrosFiltro.parciales) &&
                    (widget.adminMode || f != CobrosFiltro.verTodo)) ...[
                  FilterChip(
                    label: Text(_label(f)),
                    selected: filtroEfectivo == f,
                    onSelected: (_) {
                      setState(() => _filtro = f);
                      // Marcar la mora como vista SOLO cuando quien mira es el
                      // COBRADOR (su propia lista) — no un admin monitoreando (que
                      // borraría el badge del cobrador). Antes se gateaba por
                      // !adminMode, pero desde que la landing del cobrador pasó a
                      // adminMode:true eso quedó muerto (audit Fable 5) → se gatea
                      // por rol.
                      final esCobradorPuro = ref
                              .read(cobradorActualProvider)
                              .valueOrNull
                              ?.esCobrador ??
                          false;
                      if (f == CobrosFiltro.mora && esCobradorPuro) {
                        _marcarMoraComoVista();
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              // Separador + toggle "Ver fuera de ruta": no es un chip de estado
              // (no narra la ruta activa, la AUMENTA con la deuda de recuperación
              // de cancelados/suspendidos). Se distingue por color de aviso.
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(right: 8),
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              FilterChip(
                avatar: Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: _verFueraDeRuta
                      ? Theme.of(context).colorScheme.onErrorContainer
                      : Theme.of(context).colorScheme.error,
                ),
                label: const Text('Fuera de ruta'),
                selected: _verFueraDeRuta,
                selectedColor: Theme.of(context).colorScheme.errorContainer,
                onSelected: (v) => setState(() => _verFueraDeRuta = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: _CobrosList(
            adminMode: widget.adminMode,
            filtro: filtroEfectivo,
            diasGracia: diasGracia,
            diasVisibles: diasVisibles,
            cobradorIds: widget.adminMode ? _cobradorIds : null,
            comunidadIds: widget.adminMode ? _comunidadIds : null,
            verFueraDeRuta: _verFueraDeRuta,
            busqueda: _busqueda,
          ),
        ),
      ],
    );
  }

  String _label(CobrosFiltro f) => switch (f) {
        CobrosFiltro.todas => 'Pendientes',
        CobrosFiltro.mora => 'En mora',
        CobrosFiltro.gracia => 'En gracia',
        CobrosFiltro.parciales => 'Parciales',
        CobrosFiltro.hoy => 'Vencen hoy',
        CobrosFiltro.proxima => 'Próximas',
        CobrosFiltro.verTodo => 'Ver todo',
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Lista: una fila por contrato (cuota más antigua) + búsqueda client-side
// ─────────────────────────────────────────────────────────────────────────────

class _CobrosList extends ConsumerStatefulWidget {
  const _CobrosList({
    required this.adminMode,
    required this.filtro,
    required this.diasGracia,
    required this.diasVisibles,
    required this.verFueraDeRuta,
    required this.busqueda,
    this.cobradorIds,
    this.comunidadIds,
  });
  final bool adminMode;
  final CobrosFiltro filtro;
  final int diasGracia;
  final int diasVisibles;
  // Toggle "Ver fuera de ruta": anexa la sección de recuperación (cancelados/
  // suspendidos). Off por defecto.
  final bool verFueraDeRuta;
  final String busqueda;
  // Filtros admin multi-selección (null = sin filtrar). Vista cobrador: null.
  final Set<String>? cobradorIds;
  final Set<String>? comunidadIds;

  @override
  ConsumerState<_CobrosList> createState() => _CobrosListState();
}

class _CobrosListState extends ConsumerState<_CobrosList> {
  // Feature 1 (2026-06-20): el stream trae UNA fila por CONTRATO (su cuota más
  // antigua que matchea el filtro), agregada en SQL (cobrosFlatQuery). Sin
  // desplegable: cada fila ya muestra plan/mes/fecha + Pagar + Cambiar fecha, y
  // el tap abre la ficha del cliente. La suma de las filas de un cliente da
  // IDÉNTICA al total del resumen viejo (consistencia de dinero #10).
  late Stream<List<Map<String, dynamic>>> _flatStream;
  // Stream de la sección "fuera de ruta" (recuperación): sólo existe mientras el
  // toggle está prendido. Depende SOLO del filtro admin (cobrador/zona) — ignora
  // los chips de fecha y el rango visible a propósito (ver cobrosFueraDeRutaQuery).
  Stream<List<Map<String, dynamic>>>? _fueraStream;

  @override
  void initState() {
    super.initState();
    _flatStream = _buildFlatStream();
    if (widget.verFueraDeRuta) _fueraStream = _buildFueraStream();
  }

  @override
  void didUpdateWidget(_CobrosList old) {
    super.didUpdateWidget(old);
    // La búsqueda NO recrea el stream (se filtra client-side); sólo los filtros
    // que cambian la query SQL.
    if (old.filtro != widget.filtro ||
        old.diasGracia != widget.diasGracia ||
        old.diasVisibles != widget.diasVisibles ||
        !setEquals(old.cobradorIds, widget.cobradorIds) ||
        !setEquals(old.comunidadIds, widget.comunidadIds)) {
      setState(() => _flatStream = _buildFlatStream());
    }
    // Fuera de ruta: recrear al prenderse o al cambiar el filtro admin; soltar
    // el stream al apagarse (no consumir una suscripción que no se muestra).
    if (widget.verFueraDeRuta) {
      if (!old.verFueraDeRuta ||
          !setEquals(old.cobradorIds, widget.cobradorIds) ||
          !setEquals(old.comunidadIds, widget.comunidadIds)) {
        setState(() => _fueraStream = _buildFueraStream());
      }
    } else if (old.verFueraDeRuta) {
      setState(() => _fueraStream = null);
    }
  }

  /// Lista plana (Feature 1): una fila por contrato. El SQL vive en
  /// `cobros_query.dart`, compartido con los tests para que la suma por cliente
  /// dé idéntica al resumen (consistencia de dinero #10).
  Stream<List<Map<String, dynamic>>> _buildFlatStream() {
    final (sql, params) = cobrosFlatQuery(
      filtro: widget.filtro,
      diasGracia: widget.diasGracia,
      diasVisibles: widget.diasVisibles,
      cobradorIds: widget.cobradorIds,
      comunidadIds: widget.comunidadIds,
    );
    return ps.db.watch(sql, parameters: params);
  }

  /// Stream de la deuda fuera de ruta (cancelados/suspendidos). Mismo shape que
  /// la lista plana + `estado_contrato`; respeta el filtro admin.
  Stream<List<Map<String, dynamic>>> _buildFueraStream() {
    final (sql, params) = cobrosFueraDeRutaQuery(
      cobradorIds: widget.cobradorIds,
      comunidadIds: widget.comunidadIds,
    );
    return ps.db.watch(sql, parameters: params);
  }

  /// Matchea por nombre/código/cédula/teléfono/código de contrato, respetando
  /// los toggles de búsqueda configurable (super_admin) vía el helper compartido
  /// `busquedaClienteMatch`. Variante client-side (la lista filtra en Dart lo ya
  /// cargado, sin recrear el stream por tecla).
  bool _matchBusqueda(Map<String, dynamic> r, String q, AppSettings settings) {
    return busquedaClienteMatch(
      q,
      settings,
      nombre: r['cliente_nombre'] as String?,
      codigo: r['cliente_codigo'] as String?,
      cedula: r['cliente_cedula'] as String?,
      telefono: r['cliente_telefono'] as String?,
      contratoCodigos: r['contrato_codigos'] as String?,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Cold-start: recrear los streams al recrear la DB (cambio de schema); si
    // no, quedan leyendo de la conexión cerrada → ClosedException. (#7 / audit #2)
    ref.listen(dbEpochProvider, (_, __) {
      if (mounted) {
        setState(() {
          _flatStream = _buildFlatStream();
          if (widget.verFueraDeRuta) _fueraStream = _buildFueraStream();
        });
      }
    });
    // Settings de búsqueda configurable (toggles super_admin): el matcher
    // client-side respeta qué campos están habilitados.
    final settings = ref.watch(appSettingsProvider);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _flatStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
        }
        // M11: sin initialData, el primer frame muestra carga en vez de
        // flashear el estado vacío antes de que llegue la data real.
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        // Una fila por contrato (ya ordenada en SQL). El buscador filtra
        // client-side (no recrea el stream).
        final activas = [
          for (final r in (snap.data ?? const <Map<String, dynamic>>[]))
            if (_matchBusqueda(r, widget.busqueda, settings)) r
        ];

        // Toggle apagado: comportamiento clásico (sólo la ruta activa).
        if (!widget.verFueraDeRuta) {
          if (activas.isEmpty) return _emptyState(context);
          return _buildSecciones(context, activas, const []);
        }

        // Toggle prendido: anidamos la sección de recuperación. Su stream puede
        // seguir en waiting mientras la lista activa ya llegó → no bloqueamos
        // (se muestran las activas y la recuperación entra cuando llega).
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _fueraStream,
          builder: (context, snapF) {
            final fuera = [
              for (final r in (snapF.data ?? const <Map<String, dynamic>>[]))
                if (_matchBusqueda(r, widget.busqueda, settings)) r
            ];
            // Sin actividad y la recuperación aún cargando: mostrar carga, no el
            // empty-state (si no, parpadea "Nada por cobrar" antes de que llegue
            // la deuda fuera de ruta — justo el caso del cobrador de recuperación).
            if (activas.isEmpty &&
                snapF.connectionState == ConnectionState.waiting &&
                !snapF.hasData) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (activas.isEmpty && fuera.isEmpty) return _emptyState(context);
            return _buildSecciones(context, activas, fuera);
          },
        );
      },
    );
  }

  Widget _emptyState(BuildContext context) {
    final hayFiltros = widget.cobradorIds != null ||
        widget.comunidadIds != null ||
        widget.filtro != CobrosFiltro.todas ||
        widget.verFueraDeRuta;
    final String titulo;
    final String desc;
    if (widget.busqueda.isNotEmpty) {
      titulo = 'Sin resultados';
      desc = 'Ningún cliente coincide con la búsqueda.';
    } else if (hayFiltros) {
      titulo = 'Nada por cobrar';
      desc = widget.adminMode
          ? 'Ningún cobro coincide con los filtros. Tocá "Limpiar" arriba para ver todo.'
          : 'No hay cuotas en este filtro. Probá con otro.';
    } else {
      titulo = 'Nada por cobrar';
      desc = 'No hay cuotas pendientes con el filtro actual.';
    }
    return EmptyState(
      icon: Icons.check_circle_outline,
      titulo: titulo,
      descripcion: desc,
    );
  }

  /// Scroll combinado: sección activa (si hay) + sección recuperación (si el
  /// toggle está prendido y hay filas). Encabezados y tarjetas viven en un ÚNICO
  /// `ListView.builder` (scrollean juntos, lazy — soporta cientos de filas).
  Widget _buildSecciones(
    BuildContext context,
    List<Map<String, dynamic>> activas,
    List<Map<String, dynamic>> fuera,
  ) {
    final items = <Object>[];
    if (activas.isNotEmpty) {
      items.add(_SeccionHeader('${activas.length} por cobrar'));
      items.addAll(activas);
    }
    if (fuera.isNotEmpty) {
      final total = fuera.fold<double>(0, (s, r) => s + _saldoCanonico(r));
      items.add(_SeccionHeader(
        'Recuperación · fuera de ruta',
        fueraDeRuta: true,
        subtitulo: '${fuera.length} · ${Fmt.cordobas(total)}',
      ));
      items.addAll(fuera);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        if (it is _SeccionHeader) return _seccionHeaderWidget(context, it);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _CobroFilaCard(
            row: it as Map<String, dynamic>,
            diasGracia: widget.diasGracia,
            diasVisibles: widget.diasVisibles,
            adminMode: widget.adminMode,
          ),
        );
      },
    );
  }

  Widget _seccionHeaderWidget(BuildContext context, _SeccionHeader h) {
    final scheme = Theme.of(context).colorScheme;
    if (!h.fueraDeRuta) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(h.texto,
            style: TextStyle(fontSize: 12, color: scheme.outline)),
      );
    }
    // Banner de recuperación: distinto de las filas activas para que se lea como
    // "otra cosa" (deuda fuera del ciclo). Color de aviso, N · total a la derecha.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 16, color: scheme.onErrorContainer),
            const SizedBox(width: 6),
            Expanded(
              child: Text(h.texto,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onErrorContainer)),
            ),
            if (h.subtitulo != null)
              Text(h.subtitulo!,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onErrorContainer)),
          ],
        ),
      ),
    );
  }
}

/// Encabezado de sección en la lista combinada de Cobros (activa / recuperación).
class _SeccionHeader {
  const _SeccionHeader(this.texto, {this.fueraDeRuta = false, this.subtitulo});
  final String texto;
  final bool fueraDeRuta;
  final String? subtitulo;
}

/// Saldo canónico de una cuota (regla #10): monto + cargos_neto - pagado,
/// clampeado a >= 0. Idéntico a cobro/recibo/mapa.
double _saldoCanonico(Map<String, dynamic> r) {
  final s = (r['monto'] as num? ?? 0).toDouble() +
      (r['cargos_neto'] as num? ?? 0).toDouble() -
      (r['monto_pagado'] as num? ?? 0).toDouble();
  return s < 0 ? 0.0 : s;
}

// ─────────────────────────────────────────────────────────────────────────────
// Fila de cobro (Feature 1): UNA fila por contrato = su cuota más antigua que
// matchea el filtro. Muestra cliente + plan · mes · fecha · estado + saldo, con
// Pagar y Cambiar fecha SIEMPRE visibles (sin desplegable). Tocar la fila abre
// la ficha del cliente; los botones actúan sin abrirla (capturan su propio tap).
// ─────────────────────────────────────────────────────────────────────────────

class _CobroFilaCard extends ConsumerWidget {
  const _CobroFilaCard({
    required this.row,
    required this.diasGracia,
    required this.diasVisibles,
    required this.adminMode,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final int diasVisibles;
  final bool adminMode;

  static String _tipoLabel(String tipo) => switch (tipo) {
        'reconexion' => 'Reconexión',
        'instalacion' => 'Instalación',
        'mora' => 'Mora',
        'reparacion' => 'Reparación',
        'otro' => 'Otro',
        _ => tipo,
      };

  /// Abre el diálogo de cambio de fecha y, si se cobró el puente, va al recibo.
  Future<void> _abrirCambioFecha(BuildContext context, String contratoId,
      int diaPago, double precioMensual, String clienteNombre) async {
    final reciboId = await showDialog<String>(
      context: context,
      builder: (_) => CambioFechaDialog(
        contratoId: contratoId,
        diaPagoActual: diaPago,
        precioMensual: precioMensual,
        clienteNombre: clienteNombre,
      ),
    );
    if (reciboId != null && context.mounted) {
      context.push('/recibo/$reciboId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final colores = ref.watch(appSettingsProvider).coloresEstados;

    final clienteId = row['cliente_id'] as String;
    final codigo = row['cliente_codigo'] as String?;
    final nombre = row['cliente_nombre'] as String;
    final comunidad = row['comunidad'] as String?;
    final municipio = row['municipio'] as String?;
    final ubicacion = [comunidad, municipio]
        .where((s) => s != null && s.isNotEmpty)
        .join(' · ');
    // El prefijo de ruta se deriva de la LOCATION real, NO de adminMode: el
    // cobrador tambien monta esta pantalla con adminMode:true (su landing es '/'),
    // pero su ficha de cliente vive en /clientes/:id (root), no en /admin/... —
    // el guard de rol rebota cualquier /admin del cobrador a '/'. Conflar adminMode
    // (filtros) con "prefijo admin" dejaba al cobrador sin poder abrir la ficha
    // desde Cobros (audit 2026-06-30).
    final enAdmin =
        GoRouterState.of(context).matchedLocation.startsWith('/admin');
    final clientePath =
        enAdmin ? '/admin/clientes/$clienteId' : '/clientes/$clienteId';
    final etiquetaChips = etiquetaChipsDesdeConcat(row['etiquetas_concat']);

    final vence = DateTime.parse(row['fecha_vencimiento'] as String);
    final periodo = DateTime.parse(row['periodo'] as String);
    // Saldo canónico (regla #10) de la cuota que se cobra (la más vieja).
    final saldo = _saldoCanonico(row);
    final montoCuota = (row['monto'] as num? ?? 0).toDouble();
    final montoPagado = (row['monto_pagado'] as num? ?? 0).toDouble();
    final esParcial = (row['estado'] as String?) == 'parcial' && montoPagado > 0;
    final diasFromVence = Fmt.hoyNicaragua()
        .difference(DateTime(vence.year, vence.month, vence.day))
        .inDays;
    final esManual = row['contrato_id'] == null;
    final cuotaId = row['id'] as String;
    // Fuera de ruta: la fila viene de `cobrosFueraDeRutaQuery` (trae
    // `estado_contrato`). Es el discriminador de la sección de recuperación y su
    // badge; en la lista activa esta columna es NULL.
    final estadoContrato = row['estado_contrato'] as String?;
    final esFueraDeRuta = estadoContrato != null;

    // Aviso de cuotas EXTRA: el contrato arrastra más de una cuota que matchea
    // el filtro vigente. El número grande (saldo) y "Pagar" son la cuota MÁS
    // VIEJA (oldest-first); el chip avisa cuántas cuotas MÁS y cuánto más debe
    // ESE contrato (dentro del filtro), para que el cobrador no subestime la
    // deuda. "Más" = grupo − la cuota mostrada (sin solaparse con el saldo).
    final grupoCount = (row['grupo_count'] as num?)?.toInt() ?? 1;
    final grupoSaldo = (row['grupo_saldo'] as num?)?.toDouble() ?? saldo;
    final hayMas = grupoCount > 1;

    // "Cambiar fecha": sólo personal habilitado, sobre cuotas de un contrato
    // (no manuales) con día de pago y precio conocidos.
    final contratoId = row['contrato_id'] as String?;
    final diaPago = (row['dia_pago'] as num?)?.toInt();
    final precioMensual = (row['precio_mensual'] as num?)?.toDouble();
    // #4: el cobrador ve/cobra TODO el tenant, pero "Cambiar fecha" (re-fecha la
    // cuota + dia_pago del contrato) sigue siendo OWNER-SCOPED en el server
    // (trigger 0119). Para un cobrador sólo se muestra sobre SUS clientes: si no,
    // el cambio se aplicaría local y el server lo rechazaría → cobro fantasma.
    // Admin/admin_cobranza pueden sobre cualquiera.
    final yo = ref.watch(cobradorActualProvider).valueOrNull;
    final esCobradorPuro = yo?.esCobrador ?? false;
    final cuotaEsMia = (row['cobrador_id'] as String?) == yo?.id;
    final soloLectura = ref.watch(soloLecturaProvider);
    final mostrarCambioFecha = ref.watch(puedeCambiarFechaPagoProvider) &&
        !esManual &&
        // Fuera de ruta (cancelado/suspendido): NO se re-fecha una cuota de un
        // contrato que ya salió del ciclo activo (el server la congela).
        !esFueraDeRuta &&
        contratoId != null &&
        diaPago != null &&
        precioMensual != null &&
        (!esCobradorPuro || cuotaEsMia);

    final ev = estadoVisualCuota(
      diasFromVence: diasFromVence,
      diasGracia: diasGracia,
      diasVisibles: diasVisibles,
    );
    final color = colores.color(ev);
    final estadoLabel = switch (ev) {
      CuotaEstadoVisual.mora => 'Vencida ${diasFromVence - diasGracia}d',
      CuotaEstadoVisual.gracia => 'Gracia',
      CuotaEstadoVisual.hoy => 'Hoy',
      _ => '${-diasFromVence}d',
    };

    final mesLabel = Fmt.mesServicioLabel(
      periodo,
      (esManual || row['tipo_cargo_manual'] != null) ? null : diaPago,
    );

    final tipoManual = row['tipo_cargo_manual'] as String?;
    final planNombre = row['plan_nombre'] as String?;
    final plan = esManual
        ? (tipoManual != null ? _tipoLabel(tipoManual) : 'Cargo manual')
        : (planNombre ?? 'Contrato');

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(clientePath),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Barra de color del estado de esta cuota (triaje).
              Container(width: 5, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Línea 1: cliente.
                            Text(
                              (codigo != null && codigo.isNotEmpty)
                                  ? '$codigo · $nombre'
                                  : nombre,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            // Línea 2: plan · mes + fecha + chip de estado.
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 2,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('$plan · $mesLabel',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: scheme.onSurfaceVariant)),
                                  Text(Fmt.fechaCorta(vence),
                                      style: TextStyle(
                                          fontSize: 11, color: scheme.outline)),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(estadoLabel,
                                        style: TextStyle(
                                            color: color,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600)),
                                  ),
                                  if (esFueraDeRuta)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: estadoContrato == 'cancelado'
                                            ? scheme.errorContainer
                                            : scheme.tertiaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        estadoContrato == 'cancelado'
                                            ? 'Cancelado'
                                            : 'Suspendido',
                                        style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                            color: estadoContrato == 'cancelado'
                                                ? scheme.onErrorContainer
                                                : scheme.onTertiaryContainer),
                                      ),
                                    ),
                                  if (esManual)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: scheme.tertiaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text('Manual',
                                          style: TextStyle(
                                              fontSize: 9,
                                              color:
                                                  scheme.onTertiaryContainer)),
                                    ),
                                ],
                              ),
                            ),
                            if (ubicacion.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(ubicacion,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11, color: scheme.outline)),
                              ),
                            if (esParcial)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: scheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                      'Parcial · abonó ${Fmt.cordobas(montoPagado)} de ${Fmt.cordobas(montoCuota)}',
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: scheme.onSecondaryContainer)),
                                ),
                              ),
                            if (hayMas)
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: scheme.errorContainer,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.warning_amber_rounded,
                                          size: 13,
                                          color: scheme.onErrorContainer),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          '+${grupoCount - 1} ${grupoCount - 1 == 1 ? "cuota" : "cuotas"} · ${Fmt.cordobas(grupoSaldo - saldo)} más',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                              color: scheme.onErrorContainer),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (etiquetaChips.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: etiquetaChips),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Saldo + acciones. Los botones capturan su propio tap, así
                      // que NO abren la ficha (sólo el resto de la fila lo hace).
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(Fmt.cordobas(saldo),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 16)),
                          const SizedBox(height: 6),
                          // `lectura` (0198) no cobra: en vez de mandarlo al
                          // form (que el router le rebota al panel, sacándolo
                          // de la lista), abre el detalle de solo lectura.
                          FilledButton(
                            onPressed: () => soloLectura
                                ? mostrarCuotaSoloLectura(context, cuotaId)
                                : context.push('/cobro/$cuotaId'),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              minimumSize: const Size(0, 32),
                            ),
                            child: Text(soloLectura ? 'Ver' : 'Pagar'),
                          ),
                          if (mostrarCambioFecha)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: OutlinedButton.icon(
                                onPressed: () => _abrirCambioFecha(context,
                                    contratoId, diaPago, precioMensual, nombre),
                                icon: const Icon(Icons.event, size: 15),
                                label: const Text('Fecha',
                                    style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  minimumSize: const Size(0, 32),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
