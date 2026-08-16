import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/setting.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/logo_empresa_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/services/logo_cache_service.dart';
import '../../../data/services/logo_local_storage.dart';
import '../../../data/utils/cuota_estado_visual.dart';
import '../../../data/utils/montos.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import 'data_ops_screen.dart';
import 'recibo_layout_editor.dart';
import 'settings_groups.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/edge_functions.dart';

/// Panel de configuración. Agrupa settings por categoría en pestañas; dentro
/// de cada pestaña, en tarjetas-sección (`SettingGroup`). Algunas secciones
/// tienen un toggle padre que REVELA campos hijos (reveal animado).
///
/// Sólo admin puede editar la mayoría; admin_cobranza puede tocar las settings
/// marcadas con editable_por='admin_cobranza' (ej. tasa USD). La tab "Avanzado"
/// sólo la ve el super_admin (settings que consumen recursos del SaaS +
/// pantallas opcionales del tenant + link a "Campos del historial").
class SettingsAdminScreen extends ConsumerWidget {
  const SettingsAdminScreen({super.key});

  // Tabs base (todos los roles con acceso admin). "Avanzado" se agrega aparte
  // sólo para super_admin (ver build).
  static const _categoriasBase = [
    ('empresa', 'Empresa', Icons.business),
    ('cobranza', 'Cobranza', Icons.receipt_long),
    ('pagos', 'Pagos', Icons.payments),
    // Tab "Moneda" removido: la moneda principal SIEMPRE es córdoba (NIO). El
    // dólar es método de pago ALTERNO (con tasa de cambio, vuelto en córdobas),
    // no una moneda principal — el setting confundía. moneda.principal queda
    // huérfano en la DB (nadie lo lee; la app ya asume NIO).
    // Tab "Cuotas" removido a pedido (cuotas manuales / editar monto fuera de
    // scope por ahora). El feature sigue en el código; solo se oculta de
    // settings. Los settings cuotas.* quedan huérfanos en la DB (sin tab).
    ('recibos', 'Recibos', Icons.print),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsMapProvider);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    // super_admin hereda permisos de admin.
    final esAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;

    // La tab "Avanzado" (settings super_admin-only + link historial) sólo se
    // agrega para el super_admin. Orden: Empresa · Cobranza · Pagos · Recibos
    // · [Avanzado].
    final categorias = [
      ..._categoriasBase,
      if (esSuperAdmin) ('avanzado', 'Avanzado', Icons.tune),
      // Operaciones de datos (corrección de errores de carga). Solo super_admin.
      if (esSuperAdmin) ('operaciones', 'Operaciones', Icons.build_circle_outlined),
    ];

    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(mensajeErrorHumano(e))),
      data: (settings) {
        if (settings.isEmpty) {
          return const EmptyState(
            icon: Icons.settings,
            titulo: 'Sin configuración',
            descripcion: 'Esperando primera sincronización.',
          );
        }
        return DefaultTabController(
          length: categorias.length,
          child: Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: TabBar(
                  isScrollable: true,
                  indicatorColor: Theme.of(context).colorScheme.primary,
                  labelColor: Theme.of(context).colorScheme.primary,
                  unselectedLabelColor: Theme.of(context).colorScheme.outline,
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerColor: Theme.of(context).colorScheme.outlineVariant,
                  tabs: categorias
                      .map((c) => Tab(icon: Icon(c.$3, size: 20), text: c.$2))
                      .toList(),
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: categorias.map((c) {
                    return _CategoriaTab(
                      categoria: c.$1,
                      settings: settings,
                      // tenantIdProvider respeta impersonación: si el
                      // super_admin está dentro de un tenant, retorna
                      // el tenant impersonado, no el System.
                      tenantId: ref.watch(tenantIdProvider) ?? '',
                      esAdmin: esAdmin,
                      esSuperAdmin: esSuperAdmin,
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Settings que se renderizan con widgets especiales o que están
// obsoletos/orphaned y no deben mostrarse al admin. Vive a nivel de archivo
// para que el catch-all de "Otros" lo respete (no re-mostrar orphans).
const _hidden = {
  'empresa.logo_path',
  // "Editar monto" RETIRADO (Sprint 2, audit 2026-06-11 M1): mutaba
  // cuotas.monto sin recalcular estado ni motivo. Reemplazado por los
  // AJUSTES (cargos_extra origen='ajuste'). El seed histórico se preserva.
  'cuotas.editar_monto',
  // "Cuotas manuales" RETIRADO junto con la pantalla /admin/cuotas
  // (decisión Rubén 2026-06-11): no se usan; un cobro extra puntual se
  // resuelve con "Cargo extra" sobre una cuota existente. Seed preservado.
  'cuotas.manuales',
  // Descuentos del COBRADOR retirados (rediseño 2026-06-12): el cobrador
  // no descuenta — todo descuento/cargo lo aplica el admin desde el
  // contrato (ajustes/promos, topes ajuste_max_*). Seeds preservados.
  'cobranza.descuentos_habilitados',
  'cobranza.descuento_tipo',
  'cobranza.descuento_max_monto',
  'cobranza.descuento_max_porcentaje',
  // Legacy duplicados — la app ya usa los metodo_* de 0040.
  'pagos.transferencia_habilitada',
  'pagos.tarjeta_habilitada',
  // Depósito = transferencia (mismo método). Se quitó como opción separada; se
  // oculta el setting (la data histórica con metodo='deposito' se preserva).
  'pagos.deposito_habilitado',
  // Orphaned — nunca leído por AppSettings.
  'cobranza.cargo_reconexion',
  // Modo de ruta: setting huérfano (0 usos en el código, sin getter). El
  // mapa del cobrador no lo lee. Se oculta hasta implementar ruta
  // planificada vs libre.
  'cobranza.modo_ruta',
  // Feature 'recrear pago' eliminada (#5): anular es void puro. El seed
  // en DB (0045/0051) queda orphaned y se oculta acá (no se migra).
  'cobranza.recrear_pago_anulado',
  // Templates sin implementar — confunden al admin.
  'recibo.template_57mm',
  'recibo.template_80mm',
  // Orden del pie: se edita con el widget ReorderableListView dedicado
  // (#8b), no como campo de texto CSV.
  'recibo.orden_pie',
  // Superseded por el diseñador de bloques (recibo.layout): la visibilidad
  // del logo/empresa/monto-en-letras ahora se controla desde el editor de
  // bloques, no con toggles sueltos. Se ocultan para no confundir.
  'recibo.imprimir_logo',
  'recibo.mostrar_empresa',
  'recibo.monto_en_letras',
  // El layout se edita con el diseñador visual, nunca como texto crudo.
  'recibo.layout',
  // La clave nueva del rework op_log ({tabla:[campos]} del historial). La
  // sembró 0132 → se colaba en "Otros" como JSON crudo. Se edita desde la misma
  // pantalla "Campos del historial", nunca a mano.
  'op_log.campos_visibles',
  // Sistema audit_log eliminado (0140), pero estas filas de settings pueden
  // seguir existiendo (sembradas por 0132/0089). Se ocultan para que no se
  // cuelen como campos crudos en "Otros".
  'audit.campos_visibles',
  'cobranza.audit_visible_admin',
  // Feature sin implementar (caja chica del cobrador: tabla + UI
  // pendientes). Se oculta hasta que exista la feature real.
  'caja_chica.habilitada',
  // Pantalla de notificaciones de mora: el módulo se eliminó (menú + ruta); el
  // setting quedó huérfano. Se oculta para que no aparezca en "Otros".
  'cobranza.pantalla_notificaciones',
  // Colores de estados de cuota: tiene su propia card (picker de paleta) en la
  // tab Cobranza. La fila JSONB no debe renderizarse como campo genérico.
  'cobranza.colores_estados',
  // Plantillas de WhatsApp: se editan con el editor visual
  // (_PlantillasWhatsappCard → _PlantillaEditorDialog) que inserta las variables
  // sin typos. Como campo de texto crudo el admin podía romper los placeholders.
  // Se rinden como card propia en la tab Cobranza (si notif WhatsApp está ON).
  'cobranza.aviso_msg_gracia',
  'cobranza.aviso_msg_mora',
  // Config del modo API de WhatsApp (0137): se edita con _WhatsappApiCard en la
  // tab Avanzado, no como campos genéricos. El token NO es un setting (server).
  'cobranza.notif_api_habilitado',
  'cobranza.notif_api_token_configurado',
  'cobranza.notif_api_phone_id',
  'cobranza.notif_api_template_gracia',
  'cobranza.notif_api_template_mora',
  'cobranza.notif_api_template_lang',
  'cobranza.notif_api_hora',
  'cobranza.notif_api_frecuencia',
  'cobranza.notif_api_tope_diario',
  'cobranza.notif_api_body_gracia',
  'cobranza.notif_api_body_mora',
  // PIN del dashboard migrado a cobradores.dashboard_pin (per-user, 0197).
  // El setting de tenant queda huérfano — se oculta.
  'dashboard.pin',
};

// Settings que SOLO ve el super_admin. Hoy todos viven en la tab "Avanzado"
// (que de por sí sólo la ve el super_admin), pero mantenemos el guard por
// defensa en profundidad si un admin llegara a la sección.
const _superAdminOnly = {
  'cobranza.comprobante_habilitado',
  'cobranza.foto_obligatoria',
  // Reglas y permisos de cobro sensibles: los gestiona el dueño del SaaS, no el
  // admin del ISP. Viven en la tab Avanzado.
  'cobranza.pago_parcial',
  'cobranza.pago_adelantado',
  'cobranza.cobrador_anula_cobros',
  'cobranza.cobrador_edita_cobros',
  // Pantallas admin opcionales: el super_admin las habilita por tenant.
  'cobranza.pantalla_pagos',
  // Registro de visitas (0125): default OFF, lo habilita el super_admin.
  'cobranza.registrar_visitas',
  // Secciones del dashboard (toggleables por tenant, super-only — migración 0133).
  'dashboard.cobros_visible',
  'dashboard.proyeccion_visible',
  'dashboard.recuperacion_visible',
  'dashboard.sparkline_visible',
  'dashboard.operativo_visible',
  'dashboard.top_cobradores_visible',
  'dashboard.distribucion_visible',
  // Pantalla de Avisos (gracia/mora) — toggle super_admin (migración 0134).
  'cobranza.avisos_habilitado',
  // Notificar por WhatsApp desde Avisos — toggle super_admin (migración 0135).
  // (Las plantillas aviso_msg_* son editable_por='admin' → NO van acá.)
  'cobranza.notif_whatsapp_habilitado',
  // Reportes detallados (legacy) — toggle super_admin (migración 0141). OFF =
  // solo el reporte de cobranza (plantilla).
  'cobranza.reportes_detallados',
  // Cobro extra (cobro puntual: multa/otro) — toggle super_admin (0177). OFF =
  // oculto el "Cobro extra" del cliente y el "Generar cobro" del ticket.
  'cobranza.cobro_extra',
  // Campos de búsqueda de cliente — toggles super_admin (migración 0145). El
  // nombre siempre entra; estos 4 son toggleables (apagar teléfono evita falsos
  // positivos). Los consume busquedaClienteSql.
  'busqueda.por_codigo',
  'busqueda.por_cedula',
  'busqueda.por_telefono',
  'busqueda.por_contrato',
  // Descuentos (manual en campo): módulo que el super_admin habilita por
  // tenant (0086). El admin no lo ve ni lo puede activar.
  'cobranza.descuentos_habilitados',
  'cobranza.descuento_tipo',
  'cobranza.descuento_max_monto',
  'cobranza.descuento_max_porcentaje',
  // Reconexión: ídem, super_admin-only por tenant (0086).
  'cobranza.cargo_reconexion_habilitado',
  // Ajustes de cuota (Sprint 2, 0115): habilitación + topes, super-only
  // (enforced server-side por trg_cargos_ajuste_guard).
  'cobranza.ajustes_habilitados',
  'cobranza.ajuste_max_porcentaje',
  'cobranza.ajuste_max_monto',
  'cobranza.monto_reconexion',
  // Cambio de fecha de pago por días (feature C, 0119): switch maestro por
  // tenant. El gate duro lo aplica la RLS server (puede_cambiar_fecha_pago()).
  'cobranza.cambio_fecha_habilitado',
  // Cambio de plan del contrato (0151): switch maestro por tenant, super-only.
  'cobranza.cambio_plan_habilitado',
  // Crédito por excedente (R17, 0127): movido a la tab Avanzado, super_admin-only.
  'cobranza.credito_excedente',
};

class _CategoriaTab extends ConsumerWidget {
  const _CategoriaTab({
    required this.categoria,
    required this.settings,
    required this.tenantId,
    required this.esAdmin,
    required this.esSuperAdmin,
  });

  final String categoria;
  final Map<String, Setting> settings;
  final String tenantId;
  final bool esAdmin;
  final bool esSuperAdmin;

  /// Guarda un setting y muestra el snackbar de confirmación.
  Future<void> _guardar(
    BuildContext context,
    WidgetRef ref,
    String clave,
    dynamic nuevo,
  ) async {
    await ref.read(settingsRepoProvider).update(tenantId, clave, nuevo,
        // Atribuir el cambio al admin real; sin usuarioId el op_log lo registra
        // como "System Admin" (audit 2026-06-30). Para super_admin resuelve solo
        // a systemAdmin. op_log es el ÚNICO change log desde 0140.
        usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_labelCorto(clave)} actualizado'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // La tab Recibos ES el diseñador completo (2 columnas: editor + preview en
    // vivo). Ocupa toda la altura; no usa los tiles genéricos ni grupos.
    if (categoria == 'recibos') {
      return ReciboLayoutEditor(tenantId: tenantId);
    }

    // Operaciones de datos: pantalla dedicada (super_admin), no usa tiles ni
    // grupos. El gate esSuperAdmin lo aplica también el propio widget.
    if (categoria == 'operaciones') {
      return const DataOpsScreen();
    }

    // ¿Puede ver/editar un setting? Respeta el guard super_admin-only.
    bool visible(String clave) =>
        !_hidden.contains(clave) &&
        (esSuperAdmin || !_superAdminOnly.contains(clave)) &&
        settings.containsKey(clave);

    // Avanzado: render AGRUPADO por categoría de dominio (5 bandas con su propio
    // encabezado y mini-grilla), no la grilla global que mezclaba secciones de
    // distinto dominio. Las 2 cards especiales (historial, WhatsApp API) caen
    // dentro de su categoría. Reorganización 2026-06-27.
    if (categoria == 'avanzado' && esSuperAdmin) {
      return _buildAvanzadoCategorizado(context, ref, visible);
    }

    // Construye las tarjetas-sección de la categoría, salteando grupos vacíos
    // (sin un solo setting presente/visible en el mapa sincronizado).
    final grupos = gruposDe(categoria);
    final cards = <Widget>[];

    for (final g in grupos) {
      final tarjeta = _construirGrupo(context, ref, g, visible);
      if (tarjeta != null) cards.add(tarjeta);
    }

    // Colores de los estados de cuota: card propia (picker de paleta, no es un
    // setting tipo número/toggle). Solo en la tab Cobranza.
    if (categoria == 'cobranza') {
      cards.add(_ColoresEstadosCard(tenantId: tenantId));
      // Plantillas de WhatsApp: editor visual con chips de variables + vista
      // previa (Feature 4). Solo si el super_admin habilitó notificar por WhatsApp.
      if (ref.watch(appSettingsProvider).notifWhatsappHabilitado) {
        cards.add(_PlantillasWhatsappCard(tenantId: tenantId));
      }
      // Habilitación multi-usuario del cambio de fecha (admin), solo cuando la
      // feature está prendida por el super_admin. El rol admin siempre puede;
      // este selector es para cobradores/admin_cobranza.
      if (esAdmin && ref.watch(appSettingsProvider).cambioFechaHabilitado) {
        cards.add(const _CambioFechaUsuariosCard());
      }
    }

    // (Los "Modos de impresión disponibles" del super_admin viven DENTRO del
    // diseñador de recibo — `ReciboLayoutEditor` —, no acá: la tab Recibos hace
    // early-return al editor y nunca llega a esta grilla de cards.)

    // Catch-all "Otros": cualquier setting de ESTA categoría que exista, no
    // esté hidden, sea visible para el rol, y NO lo reclame NINGÚN grupo (de
    // ninguna tab). El "ninguna tab" importa: los settings super_admin-only
    // tienen categoría DB 'cobranza' pero viven en grupos de la tab 'avanzado';
    // usar el set global evita que el "Otros" de Cobranza los duplique. Con la
    // data actual queda vacío; es una red de seguridad para no perder settings
    // nuevos que se agreguen sin asignarles grupo.
    final claimadas = clavesReclamadasGlobal();
    final huerfanas = settings.values
        .where((s) =>
            s.categoria == categoria &&
            visible(s.clave) &&
            !claimadas.contains(s.clave))
        .map((s) => s.clave)
        .toList()
      ..sort();
    if (huerfanas.isNotEmpty) {
      final otros = _GrupoCard(
        titulo: 'Otros',
        icono: Icons.more_horiz,
        children: [
          for (var i = 0; i < huerfanas.length; i++) ...[
            if (i > 0) const _SettingDivider(),
            _settingTile(context, ref, huerfanas[i]),
          ],
        ],
      );
      cards.add(otros);
    }

    if (cards.isEmpty) {
      return const Center(child: Text('Sin opciones en esta categoría'));
    }

    // Layout: 1 columna (angosto) o 2 columnas (ancho, ≥900px). Centrado y
    // limitado a 1200px para que no se estire en ultrawide.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dosColumnas = constraints.maxWidth >= 900;

        // En Empresa, el widget de logo va arriba de TODO (ancho completo,
        // sólo admin). No entra en la grilla de 2 columnas.
        final logo = (categoria == 'empresa' && esAdmin)
            ? _LogoUploadWidget(tenantId: tenantId)
            : null;

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (logo != null) ...[
                    logo,
                    const SizedBox(height: 12),
                  ],
                  if (dosColumnas)
                    _grillaDosColumnas(cards)
                  else
                    ..._intercalar(cards),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Apila las tarjetas en 1 columna con separación vertical.
  List<Widget> _intercalar(List<Widget> cards) {
    final out = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 12));
      out.add(cards[i]);
    }
    return out;
  }

  /// Distribuye las tarjetas en 2 columnas alternando por índice par/impar.
  /// Cada columna es un Column independiente; arrancan alineadas arriba para
  /// que tarjetas de distinta altura no se estiren.
  Widget _grillaDosColumnas(List<Widget> cards) {
    final izquierda = <Widget>[];
    final derecha = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      final destino = i.isEven ? izquierda : derecha;
      if (destino.isNotEmpty) destino.add(const SizedBox(height: 12));
      destino.add(cards[i]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: izquierda,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: derecha,
          ),
        ),
      ],
    );
  }

  /// Construye una tarjeta-sección. Devuelve null si el grupo no tiene ningún
  /// setting visible/presente (no se renderiza un grupo vacío).
  Widget? _construirGrupo(
    BuildContext context,
    WidgetRef ref,
    SettingGroup g,
    bool Function(String) visible,
  ) {
    final filas = <Widget>[];

    for (final e in g.entradas) {
      if (e.tieneHijos) {
        // Entrada con dependencia padre→hijos. Si el padre no es visible, se
        // saltea el bloque completo (incl. hijos). Si lo es, se delega a un
        // widget stateful que trackea el toggle local para el reveal instantáneo.
        if (!visible(e.clave)) continue;
        final hijasVisibles =
            e.hijos.where(visible).toList(growable: false);
        if (filas.isNotEmpty) filas.add(const _SettingDivider());
        filas.add(_DependenciaRevelable(
          padre: settings[e.clave]!,
          hijos: [for (final h in hijasVisibles) settings[h]!],
          esAdmin: esAdmin,
          onGuardar: (clave, valor) => _guardar(context, ref, clave, valor),
        ));
      } else {
        // Setting plano.
        if (!visible(e.clave)) continue;
        if (filas.isNotEmpty) filas.add(const _SettingDivider());
        filas.add(_settingTile(context, ref, e.clave));
      }
    }

    if (filas.isEmpty) return null;
    return _GrupoCard(
      titulo: g.titulo,
      icono: g.icono,
      subtitulo: g.subtitulo,
      children: filas,
    );
  }

  /// Tile editor de un setting (toggle/number/text/dropdown) ya envuelto con
  /// guardado + snackbar. `puedeEditar` respeta admin vs admin_cobranza.
  Widget _settingTile(BuildContext context, WidgetRef ref, String clave) {
    final s = settings[clave]!;
    // `lectura` (0198) no edita ningún setting, ni siquiera los abiertos a
    // admin_cobranza — entre ellos está la tasa del dólar, que ensucia todos
    // los montos en córdobas mientras esté mal.
    final puedeEditar = !ref.watch(soloLecturaProvider) &&
        (esAdmin || s.editablePor == 'admin_cobranza');
    return _SettingTile(
      setting: s,
      puedeEditar: puedeEditar,
      onSave: (nuevo) => _guardar(context, ref, clave, nuevo),
    );
  }

  /// Render del tab Avanzado AGRUPADO por categoría de dominio (5 bandas). Cada
  /// categoría = encabezado + su propia mini-grilla (2 columnas en pantallas
  /// anchas, 1 en angostas). Las 2 cards especiales (historial, WhatsApp API)
  /// caen dentro de su categoría. Reemplaza la grilla global que mezclaba
  /// secciones de distinto dominio. Una categoría sin nada visible se saltea.
  Widget _buildAvanzadoCategorizado(
    BuildContext context,
    WidgetRef ref,
    bool Function(String) visible,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dosColumnas = constraints.maxWidth >= 900;
        final bloques = <Widget>[];

        for (final cat in kCategoriasAvanzado) {
          final cards = <Widget>[];
          for (final g in cat.grupos) {
            final t = _construirGrupo(context, ref, g, visible);
            if (t != null) cards.add(t);
          }
          for (final id in cat.cardsEspeciales) {
            final w = _cardEspecialAvanzado(id);
            if (w != null) cards.add(w);
          }
          if (cards.isEmpty) continue; // categoría sin nada visible

          if (bloques.isNotEmpty) bloques.add(const SizedBox(height: 24));
          bloques.add(_CategoriaHeader(
            titulo: cat.titulo,
            icono: cat.icono,
            subtitulo: cat.subtitulo,
            conteo: cards.length,
          ));
          bloques.add(const SizedBox(height: 10));
          bloques.add(dosColumnas
              ? _grillaDosColumnas(cards)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _intercalar(cards),
                ));
        }

        // Catch-all "Otros": settings de categoría DB 'avanzado' que ningún grupo
        // reclame. Con la data actual queda vacío (red de seguridad).
        final claimadas = clavesReclamadasGlobal();
        final huerfanas = settings.values
            .where((s) =>
                s.categoria == 'avanzado' &&
                visible(s.clave) &&
                !claimadas.contains(s.clave))
            .map((s) => s.clave)
            .toList()
          ..sort();
        if (huerfanas.isNotEmpty) {
          if (bloques.isNotEmpty) bloques.add(const SizedBox(height: 24));
          bloques.add(_GrupoCard(
            titulo: 'Otros',
            icono: Icons.more_horiz,
            children: [
              for (var i = 0; i < huerfanas.length; i++) ...[
                if (i > 0) const _SettingDivider(),
                _settingTile(context, ref, huerfanas[i]),
              ],
            ],
          ));
        }

        if (bloques.isEmpty) {
          return const Center(child: Text('Sin opciones en esta categoría'));
        }

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: bloques,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Resuelve una card especial del tab Avanzado por su ID (no son SettingGroup,
  /// se renderizan con widgets propios). Devuelve null si el ID no se reconoce.
  Widget? _cardEspecialAvanzado(String id) {
    switch (id) {
      case 'historial':
        return const _HistorialCamposCard();
      case 'whatsapp_api':
        return _WhatsappApiCard(tenantId: tenantId);
      default:
        return null;
    }
  }
}

String _labelCorto(String clave) =>
    clave.split('.').last.replaceAll('_', ' ');

/// Encabezado de una CATEGORÍA del tab Avanzado: la banda de dominio que agrupa
/// varias tarjetas-sección. Ícono en chip + título + subtítulo + conteo de
/// secciones. No es una Card (va por encima de la mini-grilla de la categoría).
class _CategoriaHeader extends StatelessWidget {
  const _CategoriaHeader({
    required this.titulo,
    required this.icono,
    required this.subtitulo,
    required this.conteo,
  });

  final String titulo;
  final IconData icono;
  final String subtitulo;
  final int conteo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icono, size: 19, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  subtitulo,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$conteo ${conteo == 1 ? 'sección' : 'secciones'}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta-sección: header (ícono + título + subtítulo opcional) y los settings
/// del grupo apilados, con separadores sutiles ya intercalados por el caller.
class _GrupoCard extends StatelessWidget {
  const _GrupoCard({
    required this.titulo,
    required this.icono,
    required this.children,
    this.subtitulo,
  });

  final String titulo;
  final IconData icono;
  final String? subtitulo;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header.
            Row(
              children: [
                Icon(icono, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titulo,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (subtitulo != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitulo!,
                            style: TextStyle(
                              color: scheme.outline,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Card de la tab Cobranza para configurar el color de cada estado de cuota.
/// No es un setting tipo número/toggle, así que va en su propia card con un
/// picker de paleta. Escribe el setting JSONB `cobranza.colores_estados`.
class _ColoresEstadosCard extends ConsumerWidget {
  const _ColoresEstadosCard({required this.tenantId});

  final String tenantId;

  Future<void> _editar(BuildContext context, WidgetRef ref,
      ColoresEstados actual, String estado, String label) async {
    final elegido = await showDialog<Color>(
      context: context,
      builder: (_) => _PaletaColorDialog(titulo: label),
    );
    if (elegido == null) return;
    final nuevo = switch (estado) {
      'mora' => actual.copyWith(mora: elegido),
      'gracia' => actual.copyWith(gracia: elegido),
      'hoy' => actual.copyWith(hoy: elegido),
      _ => actual.copyWith(proxima: elegido),
    };
    await ref.read(settingsRepoProvider).upsert(
          tenantId,
          'cobranza.colores_estados',
          nuevo.toJson(),
          tipo: 'json',
          categoria: 'cobranza',
          usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Color de "$label" actualizado'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final colores = ref.watch(appSettingsProvider).coloresEstados;
    final filas = <(String, String, Color)>[
      ('mora', 'En mora', colores.mora),
      ('gracia', 'En gracia', colores.gracia),
      ('hoy', 'Vence hoy', colores.hoy),
      ('proxima', 'Próxima', colores.proxima),
    ];
    return _GrupoCard(
      titulo: 'Colores de estados de cuota',
      icono: Icons.palette_outlined,
      subtitulo: 'Se aplican en el mapa y en los badges de cuotas.',
      children: [
        for (var i = 0; i < filas.length; i++) ...[
          if (i > 0) const _SettingDivider(),
          InkWell(
            onTap: () =>
                _editar(context, ref, colores, filas[i].$1, filas[i].$2),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(child: Text(filas[i].$2)),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: filas[i].$3,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.edit, size: 16, color: scheme.outline),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Card (tab Cobranza) con las 2 plantillas de WhatsApp de Avisos. Cada una
/// abre el editor visual (chips de variables sin typos + vista previa). Solo se
/// muestra cuando el super_admin habilitó notificar por WhatsApp.
class _PlantillasWhatsappCard extends ConsumerWidget {
  const _PlantillasWhatsappCard({required this.tenantId});
  final String tenantId;

  Future<void> _editar(
    BuildContext context,
    WidgetRef ref, {
    required String clave,
    required String titulo,
    required String actual,
    required String porDefecto,
  }) async {
    final nuevo = await showDialog<String>(
      context: context,
      builder: (_) => _PlantillaEditorDialog(
        titulo: titulo,
        inicial: actual,
        porDefecto: porDefecto,
        empresa: ref.read(appSettingsProvider).empresaNombre,
      ),
    );
    if (nuevo == null) return; // canceló
    await ref.read(settingsRepoProvider).upsert(
          tenantId,
          clave,
          nuevo,
          tipo: 'string',
          categoria: 'cobranza',
          usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Mensaje actualizado'),
            duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final s = ref.watch(appSettingsProvider);

    Widget fila(String clave, String titulo, Color punto, String actual,
        String def) {
      return InkWell(
        onTap: () => _editar(context, ref,
            clave: clave, titulo: titulo, actual: actual, porDefecto: def),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(top: 4),
                  decoration:
                      BoxDecoration(color: punto, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo,
                        style: const TextStyle(
                            fontWeight: FontWeight.w500, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(actual,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit, size: 18, color: scheme.primary),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.chat, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Mensajes de WhatsApp (Avisos)',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text('Tocá un mensaje para editarlo con el editor visual.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            fila('cobranza.aviso_msg_gracia', 'Próximo a corte (en gracia)',
                const Color(0xFF854F0B), s.avisoMsgGracia, kAvisoMsgGraciaDefault),
            const Divider(height: 1),
            fila('cobranza.aviso_msg_mora', 'Corte (en mora)',
                const Color(0xFFA32D2D), s.avisoMsgMora, kAvisoMsgMoraDefault),
          ],
        ),
      ),
    );
  }
}

/// Editor visual a pantalla completa de una plantilla de WhatsApp: chips de
/// variables que se insertan en el cursor (sin typos), área de texto, vista
/// previa en vivo con datos de ejemplo, y "restaurar por defecto". Devuelve el
/// texto al Guardar (o null si cancela).
class _PlantillaEditorDialog extends StatefulWidget {
  const _PlantillaEditorDialog({
    required this.titulo,
    required this.inicial,
    required this.porDefecto,
    required this.empresa,
    this.paraMeta = false,
  });
  final String titulo;
  final String inicial;
  final String porDefecto;
  final String empresa;
  // Cuando true (modo API), agrega el bloque "Copiar para Meta" que convierte el
  // texto a variables con nombre de Meta ({{nombre}}…) para pegar al crear la
  // plantilla. El cuerpo redactado se guarda igual (de referencia), no se envía.
  final bool paraMeta;

  @override
  State<_PlantillaEditorDialog> createState() => _PlantillaEditorDialogState();
}

class _PlantillaEditorDialogState extends State<_PlantillaEditorDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.inicial);
  final _focus = FocusNode();

  static const _vars = <(String, String, IconData)>[
    ('Nombre', '{nombre}', Icons.person_outline),
    ('Monto', '{monto}', Icons.attach_money),
    ('Días', '{dias}', Icons.calendar_today),
    ('Empresa', '{empresa}', Icons.storefront_outlined),
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Inserta el token en la posición del cursor (o al final si no hay selección).
  void _insertar(String token) {
    final text = _ctrl.text;
    final sel = _ctrl.selection;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final nuevo = text.replaceRange(start, end, token);
    _ctrl.value = TextEditingValue(
      text: nuevo,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    _focus.requestFocus();
    setState(() {});
  }

  String _preview(String t) {
    final emp = widget.empresa.trim().isEmpty ? 'Tu empresa' : widget.empresa;
    return t
        .replaceAll('{nombre}', 'María Gutiérrez')
        .replaceAll('{monto}', '1.000,00 C\$')
        .replaceAll('{dias}', '3')
        .replaceAll('{empresa}', emp);
  }

  // Convierte el texto del editor a variables CON NOMBRE de Meta: {nombre} →
  // {{nombre}}. Es lo que se pega al crear la plantilla en Meta (modo API).
  String _aMeta(String t) => t
      .replaceAll('{nombre}', '{{nombre}}')
      .replaceAll('{monto}', '{{monto}}')
      .replaceAll('{dias}', '{{dias}}')
      .replaceAll('{empresa}', '{{empresa}}');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancelar',
              onPressed: () => Navigator.pop(context)),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Editar mensaje', style: TextStyle(fontSize: 16)),
              Text(widget.titulo,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
              child: const Text('Guardar'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Tocá una variable para insertarla donde está el cursor:',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in _vars)
                  ActionChip(
                    avatar: Icon(v.$3, size: 16),
                    label: Text(v.$1),
                    onPressed: () => _insertar(v.$2),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              focusNode: _focus,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Mensaje',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            Text(
                'Las variables van entre llaves ({nombre}, {monto}, {dias}, '
                '{empresa}). Insertalas con los chips para no equivocarte.',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
            const SizedBox(height: 20),
            Text('Vista previa (cliente de ejemplo):',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFDCF8C6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_preview(_ctrl.text),
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF0B2E13), height: 1.45)),
            ),
            if (widget.paraMeta) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F1FB),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [
                      Icon(Icons.content_copy,
                          size: 15, color: Color(0xFF0C447C)),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                            'Para crear la plantilla en Meta — copiá este cuerpo:',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF0C447C))),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(_aMeta(_ctrl.text),
                          style: const TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              fontFamily: 'monospace')),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                              'Variables con nombre: {{nombre}} {{monto}} '
                              '{{dias}} {{empresa}}',
                              style: TextStyle(
                                  fontSize: 11, color: Color(0xFF0C447C))),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: _aMeta(_ctrl.text)));
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Copiado para Meta'),
                                    duration: Duration(seconds: 2)));
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copiar'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  _ctrl.text = widget.porDefecto;
                  setState(() {});
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Restaurar mensaje por defecto'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card (tab Cobranza) para que el ADMIN habilite, con multi-selección, qué
/// cobradores / admins de cobranza pueden cambiar la fecha de pago. El rol
/// admin siempre puede; este selector es para el resto. Solo se muestra cuando
/// el super_admin tiene la feature prendida (cobranza.cambio_fecha_habilitado).
class _CambioFechaUsuariosCard extends ConsumerWidget {
  const _CambioFechaUsuariosCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _GrupoCard(
      titulo: 'Cambio de fecha — usuarios habilitados',
      icono: Icons.event_available,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Elegí qué cobradores y admins de cobranza pueden cambiar la '
                'fecha de pago de un cliente. El rol admin siempre puede.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.group, size: 18),
                  label: const Text('Habilitar usuarios'),
                  onPressed: () => _abrir(context, ref),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _abrir(BuildContext context, WidgetRef ref) async {
    // Filtro tenant_id (audit 2026-06-24): un super_admin impersonando tiene
    // cobradores de varios tenants en su SQLite local; sin el filtro el UPDATE
    // podría togglear los de otro tenant. tenantIdProvider respeta la impersonación.
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final usuarios = await ps.db.getAll('''
      SELECT id, nombre, rol, puede_cambiar_fecha FROM cobradores
       WHERE activo = 1 AND tenant_id = ? AND rol IN ('cobrador','admin_cobranza')
       ORDER BY nombre
    ''', [tenantId]);
    if (!context.mounted) return;
    if (usuarios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No hay cobradores ni admins de cobranza para habilitar.')));
      return;
    }
    final seleccionados = <String>{
      for (final u in usuarios)
        if ((u['puede_cambiar_fecha'] as int? ?? 0) == 1) u['id'] as String,
    };
    final guardar = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final todos = seleccionados.length == usuarios.length;
          return AlertDialog(
            title: const Text('Habilitar cambio de fecha'),
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
                    final rol = u['rol'] as String;
                    return CheckboxListTile(
                      value: seleccionados.contains(id),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(u['nombre'] as String),
                      subtitle: Text(
                          rol == 'admin_cobranza' ? 'Admin cobranza' : 'Cobrador'),
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
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      ),
    );
    if (guardar != true || !context.mounted) return;
    // El selector define el estado COMPLETO: cada usuario listado queda con
    // puede_cambiar_fecha = está seleccionado. op_log (audit 2026-06-24): 1 fila
    // por cobrador cuyo valor CAMBIÓ, en writeTransaction (antes era execute
    // suelto sin historial). El UPDATE filtra tenant_id (defensa impersonación).
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await ps.dbW.writeTransaction((tx) async {
      for (final u in usuarios) {
        final id = u['id'] as String;
        final antes = (u['puede_cambiar_fecha'] as int? ?? 0) == 1;
        final ahora = seleccionados.contains(id);
        if (antes == ahora) continue; // sin cambio: no toca ni loguea
        await tx.execute(
          'UPDATE cobradores SET puede_cambiar_fecha = ? WHERE id = ? AND tenant_id = ?',
          [ahora ? 1 : 0, id, tenantId],
        );
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId,
            opId: opId,
            entidad: 'cobradores',
            entidadId: id,
            antes: {'puede_cambiar_fecha': antes ? 1 : 0},
            despues: {'puede_cambiar_fecha': ahora ? 1 : 0},
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      }
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${seleccionados.length} usuario(s) habilitados para cambiar fecha.')));
    }
  }
}

/// Diálogo con la paleta de swatches predefinidos. Devuelve el color elegido
/// (o null si se cancela). Sin dependencias externas — paleta fija curada.
class _PaletaColorDialog extends StatelessWidget {
  const _PaletaColorDialog({required this.titulo});

  final String titulo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Color: $titulo'),
      content: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final c in kPaletaColoresEstados)
            InkWell(
              onTap: () => Navigator.pop(context, c),
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

/// Separador sutil entre settings dentro de un grupo.
class _SettingDivider extends StatelessWidget {
  const _SettingDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 18,
      thickness: 0.5,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
    );
  }
}

/// Card (tab Avanzado, super_admin): config del modo API de WhatsApp (envío
/// automático por lote, 0137). El Access Token se guarda en el SERVIDOR vía la
/// edge function `whatsapp-set-token` (no es un setting sincronizado). "Probar"
/// llama a `whatsapp-enviar` (modo uno). El resto son settings normales.
class _WhatsappApiCard extends ConsumerStatefulWidget {
  const _WhatsappApiCard({required this.tenantId});
  final String tenantId;
  @override
  ConsumerState<_WhatsappApiCard> createState() => _WhatsappApiCardState();
}

class _WhatsappApiCardState extends ConsumerState<_WhatsappApiCard> {
  late final TextEditingController _phone;
  late final TextEditingController _tplG;
  late final TextEditingController _tplM;
  late final TextEditingController _hora;
  late final TextEditingController _tope;
  final _token = TextEditingController();
  bool _guardandoToken = false;
  bool _guardandoConfig = false;
  bool _probando = false;
  bool _apiOn = false; // estado local del reveal (toggle padre, instantáneo)

  static const _frecuencias = <(String, String)>[
    ('una_vez_estado', 'Una sola vez por estado'),
    ('cada_3', 'Cada 3 días'),
    ('semanal', 'Una vez por semana'),
    ('cada_15', 'Cada 15 días'),
    ('diario', 'Todos los días'),
  ];

  // Códigos de idioma de Meta para plantillas (solo español; el código debe
  // coincidir EXACTO con el de la plantilla aprobada en Meta).
  static const _idiomas = <(String, String)>[
    ('es', 'Español'),
    ('es_MX', 'Español (México)'),
    ('es_AR', 'Español (Argentina)'),
    ('es_ES', 'Español (España)'),
  ];

  @override
  void initState() {
    super.initState();
    final s = ref.read(appSettingsProvider);
    _phone = TextEditingController(text: s.notifApiPhoneId);
    _tplG = TextEditingController(text: s.notifApiTemplateGracia);
    _tplM = TextEditingController(text: s.notifApiTemplateMora);
    _hora = TextEditingController(text: '${s.notifApiHora}');
    _tope = TextEditingController(text: '${s.notifApiTopeDiario}');
    _apiOn = s.notifApiHabilitado;
  }

  @override
  void dispose() {
    for (final c in [_phone, _tplG, _tplM, _hora, _tope, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _save(String clave, Object valor, String tipo) =>
      ref.read(settingsRepoProvider).upsert(widget.tenantId, clave, valor,
          tipo: tipo,
          categoria: 'cobranza',
          usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id);

  Future<void> _guardarToken() async {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    setState(() => _guardandoToken = true);
    try {
      final r = await invokeEdgeFunction(
          Supabase.instance.client, 'whatsapp-set-token',
          body: {'tenant_id': widget.tenantId, 'access_token': t});
      _token.clear();
      final ten = r['tenant'];
      _snack(ten != null ? 'Token guardado para $ten' : 'Token guardado');
    } catch (e) {
      _snack(humanizarEdgeError(e));
    } finally {
      if (mounted) setState(() => _guardandoToken = false);
    }
  }

  // Guarda de una vez todos los campos de texto (los TextField guardan en
  // onSubmitted/Enter; este botón es la red para quien edita y no presiona Enter).
  Future<void> _guardarConfig() async {
    setState(() => _guardandoConfig = true);
    try {
      await _save('cobranza.notif_api_phone_id', _phone.text.trim(), 'string');
      await _save(
          'cobranza.notif_api_template_gracia', _tplG.text.trim(), 'string');
      await _save(
          'cobranza.notif_api_template_mora', _tplM.text.trim(), 'string');
      final h = int.tryParse(_hora.text.trim());
      if (h != null && h >= 0 && h <= 23) {
        await _save('cobranza.notif_api_hora', h, 'number');
      }
      final n = int.tryParse(_tope.text.trim());
      if (n != null && n > 0) {
        await _save('cobranza.notif_api_tope_diario', n, 'number');
      }
      _snack('Configuración guardada');
    } catch (e) {
      _snack(humanizarEdgeError(e));
    } finally {
      if (mounted) setState(() => _guardandoConfig = false);
    }
  }

  Future<void> _probar() async {
    setState(() => _probando = true);
    try {
      final r = await invokeEdgeFunction(
          Supabase.instance.client, 'whatsapp-enviar',
          body: {'modo': 'uno', 'tenant_id': widget.tenantId});
      _snack('Enviado a ${r['enviado_a'] ?? 'un cliente'} ✓');
    } catch (e) {
      _snack(humanizarEdgeError(e));
    } finally {
      if (mounted) setState(() => _probando = false);
    }
  }

  static const _verde = Color(0xFF128C3F);
  static const _verdeOscuro = Color(0xFF0F6E56);

  InputDecoration _deco(String label, [String? hint]) => InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder());

  Widget _seccionHeader(IconData icon, String txt, ColorScheme scheme) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(txt,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant)),
        ]),
      );

  // Abre el editor visual del CUERPO de la plantilla (chips + preview + "Copiar
  // para Meta"). Guarda el borrador (no es lo que se envía; eso es la plantilla
  // aprobada en Meta).
  Future<void> _editarBody(
      String clave, String titulo, String actual, String def) async {
    final nuevo = await showDialog<String>(
      context: context,
      builder: (_) => _PlantillaEditorDialog(
        titulo: titulo,
        inicial: actual,
        porDefecto: def,
        empresa: ref.read(appSettingsProvider).empresaNombre,
        paraMeta: true,
      ),
    );
    if (nuevo == null || !mounted) return;
    await _save(clave, nuevo, 'string');
    _snack('Mensaje guardado');
  }

  Widget _plantillaRow({
    required ColorScheme scheme,
    required String titulo,
    required Color punto,
    required TextEditingController nameCtrl,
    required String nameClave,
    required String body,
    required String bodyClave,
    required String def,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: punto, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(titulo,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: nameCtrl,
          decoration: _deco('Nombre de la plantilla en Meta'),
          onSubmitted: (v) => _save(nameClave, v.trim(), 'string'),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _editarBody(bodyClave, titulo, body, def),
            icon: const Icon(Icons.edit_note, size: 18),
            label: const Text('Editar mensaje'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = ref.watch(appSettingsProvider);
    // Re-sincronizar el reveal si el valor del server cambia (carga async u otra
    // sesión); nuestro propio toggle deja _apiOn == server → no-op.
    ref.listen(appSettingsProvider, (prev, next) {
      if (mounted && next.notifApiHabilitado != _apiOn) {
        setState(() => _apiOn = next.notifApiHabilitado);
      }
    });

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con acento verde de WhatsApp.
          Container(
            width: double.infinity,
            color: _verde.withValues(alpha: 0.08),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.smart_toy_outlined, size: 20, color: _verde),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('WhatsApp API',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE1F5EE),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('PAGO · SUPER ADMIN',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _verdeOscuro)),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                    'Envío automático por lote vía la Cloud API de Meta. Distinto '
                    'del WhatsApp gratis (1×1 manual) de Avisos. Requiere negocio '
                    'verificado + plantillas aprobadas en Meta.',
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          // Toggle padre — revela la config al activarse.
          SwitchListTile.adaptive(
            activeThumbColor: _verde,
            title: const Text('Activar WhatsApp API'),
            subtitle: Text(
                _apiOn
                    ? 'Activo — configurá los datos abajo'
                    : 'Activalo para configurarlo',
                style: TextStyle(
                    fontSize: 11,
                    color: _apiOn ? _verdeOscuro : scheme.onSurfaceVariant)),
            value: _apiOn,
            onChanged: (v) async {
              setState(() => _apiOn = v); // reveal instantáneo
              try {
                await _save('cobranza.notif_api_habilitado', v, 'boolean');
              } catch (e) {
                // Si el guardado falla, revertimos el reveal y avisamos (sino
                // el estado mostrado mentiría respecto del server).
                if (mounted) {
                  setState(() => _apiOn = !v);
                  _snack(humanizarEdgeError(e));
                }
              }
            },
          ),
          // Config revelable (oculta cuando el toggle está OFF).
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: _apiOn
                  ? Padding(
                      key: const ValueKey('api-on'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: _config(context, s, scheme),
                    )
                  : const SizedBox(
                      key: ValueKey('api-off'), width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }

  Widget _config(BuildContext context, AppSettings s, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 8),
        const SizedBox(height: 10),
        // Credenciales
        _seccionHeader(Icons.key_outlined, 'Credenciales de Meta', scheme),
        TextField(
            controller: _phone,
            decoration: _deco('Phone Number ID'),
            onSubmitted: (v) =>
                _save('cobranza.notif_api_phone_id', v.trim(), 'string')),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
                controller: _token,
                obscureText: true,
                decoration: _deco(
                    'Access Token',
                    s.notifApiTokenConfigurado
                        ? 'Ya configurado — pegá uno nuevo para reemplazar'
                        : 'Pegá el token de Meta')),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _guardandoToken ? null : _guardarToken,
            child: _guardandoToken
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Guardar'),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
                s.notifApiTokenConfigurado
                    ? Icons.check_circle
                    : Icons.lock_outline,
                size: 14,
                color:
                    s.notifApiTokenConfigurado ? Colors.green : scheme.outline),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                  s.notifApiTokenConfigurado
                      ? 'Token configurado — vive en el servidor, no se sincroniza.'
                      : 'El token se guarda en el servidor, no se sincroniza a los dispositivos.',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        // Plantillas
        _seccionHeader(Icons.dashboard_customize_outlined,
            'Plantillas aprobadas por Meta', scheme),
        _plantillaRow(
          scheme: scheme,
          titulo: 'Próximo a corte (gracia)',
          punto: const Color(0xFF854F0B),
          nameCtrl: _tplG,
          nameClave: 'cobranza.notif_api_template_gracia',
          body: s.notifApiBodyGracia,
          bodyClave: 'cobranza.notif_api_body_gracia',
          def: kAvisoMsgGraciaDefault,
        ),
        const SizedBox(height: 14),
        _plantillaRow(
          scheme: scheme,
          titulo: 'Corte (mora)',
          punto: const Color(0xFFA32D2D),
          nameCtrl: _tplM,
          nameClave: 'cobranza.notif_api_template_mora',
          body: s.notifApiBodyMora,
          bodyClave: 'cobranza.notif_api_body_mora',
          def: kAvisoMsgMoraDefault,
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: _deco('Idioma de las plantillas'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: _idiomas.any((l) => l.$1 == s.notifApiTemplateLang)
                  ? s.notifApiTemplateLang
                  : 'es',
              items: [
                for (final l in _idiomas)
                  DropdownMenuItem(
                      value: l.$1,
                      child: Text('${l.$2}  ·  ${l.$1}',
                          style: const TextStyle(fontSize: 13))),
              ],
              onChanged: (v) {
                if (v != null) {
                  _save('cobranza.notif_api_template_lang', v, 'string');
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  'Redactá el mensaje con "Editar mensaje" (chips + vista previa) '
                  'y usá "Copiar para Meta": te da el cuerpo con variables '
                  '{{nombre}} {{monto}} {{dias}} {{empresa}} para pegar al crear '
                  'la plantilla en Meta. El nombre de acá debe coincidir con el de Meta.',
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: scheme.onSurfaceVariant)),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        // Envío automático
        _seccionHeader(Icons.schedule, 'Envío automático', scheme),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 110,
            child: TextField(
                controller: _hora,
                keyboardType: TextInputType.number,
                decoration: _deco('Hora (0-23)'),
                onSubmitted: (v) {
                  final h = int.tryParse(v.trim());
                  if (h != null && h >= 0 && h <= 23) {
                    _save('cobranza.notif_api_hora', h, 'number');
                  }
                }),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InputDecorator(
              decoration: _deco('Re-notificar al mismo cliente'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _frecuencias.any((f) => f.$1 == s.notifApiFrecuencia)
                      ? s.notifApiFrecuencia
                      : 'semanal',
                  items: [
                    for (final f in _frecuencias)
                      DropdownMenuItem(
                          value: f.$1,
                          child: Text(f.$2,
                              style: const TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      _save('cobranza.notif_api_frecuencia', v, 'string');
                    }
                  },
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          width: 170,
          child: TextField(
              controller: _tope,
              keyboardType: TextInputType.number,
              decoration: _deco('Tope diario'),
              onSubmitted: (v) {
                final n = int.tryParse(v.trim());
                if (n != null && n > 0) {
                  _save('cobranza.notif_api_tope_diario', n, 'number');
                }
              }),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: _guardandoConfig ? null : _guardarConfig,
              icon: _guardandoConfig
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('Guardar configuración'),
            ),
            OutlinedButton.icon(
              onPressed: _probando ? null : _probar,
              icon: _probando
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send, size: 18),
              label: const Text('Probar con un cliente'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
            'Guardá los cambios; después mandá una prueba antes de confiar en '
            'el automático.',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
      ],
    );
  }
}

/// Tarjeta-link "Campos del historial" (tab Avanzado, super_admin). No es un
/// setting: navega a la pantalla de configuración del change log. La pantalla
/// destino igual defiende con su propio gate.
class _HistorialCamposCard extends StatelessWidget {
  const _HistorialCamposCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Avanzado',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune),
              title: const Text('Campos del historial'),
              subtitle: const Text(
                'Elegí qué campos se ven en el historial de cambios',
              ),
              trailing: const Icon(Icons.chevron_right),
              // Regla #12: ruta del shell admin → go, no push (si no, el
              // AppBar del shell queda con el título del padre 'Configuración').
              onTap: () => context.go('/admin/settings/historial-campos'),
            ),
            // Visor del historial de cambios de configuración (fix F0: los
            // cambios de settings se logueaban en op_log pero ninguna pantalla
            // los mostraba). Sheet con el log global de la entidad 'settings'.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history_toggle_off),
              title: const Text('Ver historial de cambios'),
              subtitle: const Text(
                'Quién cambió cada ajuste y cuándo (antes → después)',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => DraggableScrollableSheet(
                  expand: false,
                  initialChildSize: 0.7,
                  maxChildSize: 0.95,
                  builder: (_, scrollCtrl) => SingleChildScrollView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Historial de configuración',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: 12),
                        // entidadId null → log global de todas las claves.
                        HistorialOpLog(entidad: 'settings', entidadId: null),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bloque "padre con hijos revelables": un toggle padre que muestra/oculta
/// (animado) los settings hijos según su estado. El estado del toggle se
/// trackea LOCAL para que el reveal sea instantáneo (no espera el round-trip a
/// la DB). El `didUpdateWidget` re-sincroniza si el valor del server cambia.
class _DependenciaRevelable extends StatefulWidget {
  const _DependenciaRevelable({
    required this.padre,
    required this.hijos,
    required this.esAdmin,
    required this.onGuardar,
  });

  final Setting padre;
  final List<Setting> hijos;
  final bool esAdmin;
  final Future<void> Function(String clave, dynamic valor) onGuardar;

  @override
  State<_DependenciaRevelable> createState() => _DependenciaRevelableState();
}

class _DependenciaRevelableState extends State<_DependenciaRevelable> {
  late bool _padreOn;

  @override
  void initState() {
    super.initState();
    _padreOn = widget.padre.asBool;
  }

  @override
  void didUpdateWidget(covariant _DependenciaRevelable old) {
    super.didUpdateWidget(old);
    // Si el valor del server cambió (ej. otra sesión), re-sincronizamos el
    // estado local del reveal.
    _padreOn = widget.padre.asBool;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final puedeEditarPadre =
        widget.esAdmin || widget.padre.editablePor == 'admin_cobranza';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Toggle padre. Al cambiar, actualizamos el estado local (reveal
        // instantáneo) y disparamos el guardado.
        _SettingTile(
          setting: widget.padre,
          puedeEditar: puedeEditarPadre,
          onSave: (nuevo) async {
            if (nuevo is bool && mounted) {
              setState(() => _padreOn = nuevo);
            }
            await widget.onGuardar(widget.padre.clave, nuevo);
          },
          // El tile notifica el cambio del switch ANTES del round-trip para
          // que el reveal no espere a la DB.
          onBoolChangedLocal: (v) {
            if (mounted) setState(() => _padreOn = v);
          },
        ),
        // Hijos revelables: ocultos cuando el padre está OFF (no sólo
        // disabled). AnimatedSize anima alto; el AnimatedOpacity suaviza.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: (_padreOn && widget.hijos.isNotEmpty)
                ? Padding(
                    key: const ValueKey('hijos-on'),
                    // Indentación + borde izquierdo sutil para marcar jerarquía.
                    padding: const EdgeInsets.only(top: 8, left: 12),
                    child: Container(
                      padding: const EdgeInsets.only(left: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: scheme.outlineVariant,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < widget.hijos.length; i++) ...[
                            if (i > 0) const _SettingDivider(),
                            _SettingTile(
                              setting: widget.hijos[i],
                              puedeEditar: widget.esAdmin ||
                                  widget.hijos[i].editablePor ==
                                      'admin_cobranza',
                              onSave: (nuevo) => widget.onGuardar(
                                  widget.hijos[i].clave, nuevo),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : const SizedBox(
                    key: ValueKey('hijos-off'),
                    width: double.infinity,
                  ),
          ),
        ),
      ],
    );
  }
}

class _SettingTile extends StatefulWidget {
  const _SettingTile({
    required this.setting,
    required this.puedeEditar,
    required this.onSave,
    this.onBoolChangedLocal,
  });

  final Setting setting;
  final bool puedeEditar;
  final Future<void> Function(dynamic) onSave;

  /// Callback opcional: se invoca con el nuevo valor del switch ANTES de
  /// guardar, para que el padre revele/oculte hijos sin esperar el round-trip.
  final void Function(bool)? onBoolChangedLocal;

  @override
  State<_SettingTile> createState() => _SettingTileState();
}

class _SettingTileState extends State<_SettingTile> {
  late TextEditingController _ctrl;
  late bool _boolValor;
  Timer? _debounce;

  // M9: error de parse del campo numérico ('Número inválido') — antes el
  // tryParse fallido descartaba lo tipeado EN SILENCIO y el user creía
  // haber guardado.
  String? _numError;

  // M9: último valor agendado por el debounce, para FLUSHEARLO en dispose
  // (antes salir de la pantalla dentro de los 600ms cancelaba y perdía la
  // edición).
  dynamic _pendiente;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.setting.valor?.toString() ?? '',
    );
    _boolValor = widget.setting.asBool;
  }

  @override
  void didUpdateWidget(covariant _SettingTile old) {
    super.didUpdateWidget(old);
    // Si llega nuevo valor del server y el campo no está enfocado, actualizamos.
    final nuevoTexto = widget.setting.valor?.toString() ?? '';
    if (nuevoTexto != _ctrl.text && !FocusScope.of(context).hasFocus) {
      _ctrl.text = nuevoTexto;
    }
    _boolValor = widget.setting.asBool;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    // M9: si quedó un guardado pendiente, ejecutarlo (flush) en vez de
    // cancelarlo. Best-effort: si el padre ya soltó sus providers (cierre
    // de pantalla completa) el catch evita romper el teardown.
    if ((_debounce?.isActive ?? false) && _pendiente != null) {
      try {
        unawaited(widget.onSave(_pendiente));
      } catch (_) {}
    }
    _debounce?.cancel();
    super.dispose();
  }

  void _debouncedSave(dynamic valor) {
    _pendiente = valor;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      _pendiente = null;
      widget.onSave(valor);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;

    // Los booleanos se renderizan como un SwitchListTile compacto (título +
    // subtítulo + switch). El resto (number/text/dropdown) usa label arriba +
    // field denso abajo.
    if (s.tipo == 'boolean' && _dropdownFor(s.clave) == null) {
      return _boolTile();
    }
    return _fieldTile();
  }

  // ---- Render de un toggle (boolean) ----
  Widget _boolTile() {
    final s = widget.setting;
    final scheme = Theme.of(context).colorScheme;
    final label = _label(s.clave);
    final desc = _descripcionOverride(s.clave) ?? s.descripcion;

    // Efectivo es el método por defecto e inmutable: el toggle queda fijo en
    // ON y deshabilitado (no se puede dejar al cobrador sin métodos de pago).
    final esEfectivoFijo = s.clave == 'pagos.metodo_efectivo';
    final enabled = widget.puedeEditar && !esEfectivoFijo;
    final valor = esEfectivoFijo ? true : _boolValor;

    return SwitchListTile.adaptive(
      value: valor,
      onChanged: enabled
          ? (v) async {
              // Aviso al DESACTIVAR un setting cuyo apagado cambia comportamiento
              // (no solo cosmético): se confirma antes de aplicar.
              if (!v) {
                final aviso = _avisoDesactivar(s.clave);
                if (aviso != null) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('¿Desactivar esta opción?'),
                      content: Text(aviso),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('No, dejar activa')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Desactivar')),
                      ],
                    ),
                  );
                  if (ok != true || !mounted) return; // sin flip ni guardado
                }
              }
              setState(() => _boolValor = v);
              widget.onBoolChangedLocal?.call(v);
              widget.onSave(v);
            }
          : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 14.5),
            ),
          ),
          if (!widget.puedeEditar) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Sólo admin puede modificar',
              child: Icon(Icons.lock_outline, color: scheme.outline, size: 16),
            ),
          ],
        ],
      ),
      subtitle: (desc != null && desc.isNotEmpty)
          ? Text(desc, style: TextStyle(color: scheme.outline, fontSize: 12))
          : (esEfectivoFijo
              ? Text('Método por defecto, siempre activo',
                  style: TextStyle(color: scheme.outline, fontSize: 12))
              : null),
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
    );
  }

  /// Aviso al DESACTIVAR settings cuyo apagado cambia comportamiento de plata o
  /// flujo (no solo cosmético). Devuelve el texto a confirmar, o null si no
  /// requiere confirmación. Extensible: agregar casos para otros settings.
  String? _avisoDesactivar(String clave) {
    switch (clave) {
      case 'cobranza.credito_excedente':
        return 'Al desactivar, el excedente pagado por adelantado al suspender o '
            'cancelar volverá a quedarse en la caja SIN acreditar ni devolver '
            '(como antes). Los saldos a favor YA generados se conservan y se '
            'pueden seguir aplicando.';
      default:
        return null;
    }
  }

  // ---- Render de un campo (number / string / json / dropdown) ----
  Widget _fieldTile() {
    final s = widget.setting;
    final scheme = Theme.of(context).colorScheme;
    final label = _label(s.clave);
    final desc = _descripcionOverride(s.clave) ?? s.descripcion;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14.5),
                ),
              ),
              if (!widget.puedeEditar)
                Tooltip(
                  message: 'Sólo admin puede modificar',
                  child: Icon(Icons.lock_outline,
                      color: scheme.outline, size: 16),
                ),
            ],
          ),
          if (desc != null && desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                desc,
                style: TextStyle(color: scheme.outline, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          _editor(),
        ],
      ),
    );
  }

  Widget _editor() {
    final s = widget.setting;
    final enabled = widget.puedeEditar;

    // Dropdown especial para formato de recibo (number type).
    if (s.clave == 'recibo.formato_default_mm') {
      final current = (s.valor as num?)?.toInt() ?? 80;
      return DropdownButtonFormField<int>(
        initialValue: current == 80 ? 80 : 58,
        decoration: const InputDecoration(isDense: true),
        items: const [
          DropdownMenuItem(value: 58, child: Text('58 mm (angosto)')),
          DropdownMenuItem(value: 80, child: Text('80 mm (estándar)')),
        ],
        onChanged: enabled ? (v) { if (v != null) widget.onSave(v); } : null,
      );
    }

    // Dropdowns para settings con opciones fijas.
    final dropdownOptions = _dropdownFor(s.clave);
    if (dropdownOptions != null) {
      final current = (s.valor as String?) ?? dropdownOptions.first.$1;
      final validValue = dropdownOptions.any((o) => o.$1 == current)
          ? current
          : dropdownOptions.first.$1;
      return DropdownButtonFormField<String>(
        initialValue: validValue,
        decoration: const InputDecoration(isDense: true),
        items: dropdownOptions
            .map((o) => DropdownMenuItem(value: o.$1, child: Text(o.$2)))
            .toList(),
        onChanged: enabled
            ? (v) {
                if (v != null) widget.onSave(v);
              }
            : null,
      );
    }

    if (s.tipo == 'number') {
      return TextFormField(
        controller: _ctrl,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        // M9: acepta coma decimal (teclado Android es-NI) — siempre en
        // pareja con parseMonto, que la normaliza.
        inputFormatters: [montoInputFormatter],
        decoration: InputDecoration(isDense: true, errorText: _numError),
        onChanged: (v) {
          // Las TASAS/factores (ej. pagos.tasa_usd_cordoba) llevan 3-4 decimales
          // (el BCN publica la tasa a 4) → NO aplica el anti-miles de 2 decimales
          // del dinero; el resto de los number (topes, enteros) sí (audit 2026-06-30).
          final n =
              parseMonto(v, maxDecimales: s.clave.contains('tasa') ? 6 : 2);
          if (n == null) {
            // M9: parse fallido AVISA y no guarda (antes era silencioso).
            // Campo vacío no es error: simplemente no hay nada que guardar.
            setState(
                () => _numError = v.trim().isEmpty ? null : 'Número inválido');
            return;
          }
          if (_numError != null) setState(() => _numError = null);
          // Enteros como int (JSON `10`, no `10.0`) — mismo shape que
          // generaba el num.tryParse anterior.
          _debouncedSave(n % 1 == 0 ? n.toInt() : n);
        },
      );
    }

    // string o json: text plano (json se trata como texto avanzado).
    return TextFormField(
      controller: _ctrl,
      enabled: enabled,
      maxLines: s.tipo == 'json' ? 5 : 1,
      decoration: const InputDecoration(isDense: true),
      onChanged: (v) => _debouncedSave(v),
    );
  }

  // Overrides de descripción cuando el copy de la DB no alcanza
  // (ej. feature flags pendientes de implementación).
  String? _descripcionOverride(String clave) {
    return switch (clave) {
      'caja_chica.habilitada' =>
        'Permite asignar caja chica diaria al cobrador y reconciliar '
            'efectivo al final del día. (Feature en desarrollo)',
      'cobranza.audit_visible_admin' =>
        'Si está activo, el admin del tenant ve el panel de Auditoría '
            '(historial de cambios) en su menú. Apagado, sólo vos (super_admin) '
            'lo ves.',
      _ => null,
    };
  }

  // Etiquetas legibles para las claves más comunes.
  String _label(String clave) {
    const labels = <String, String>{
      'empresa.nombre': 'Nombre comercial',
      'empresa.direccion': 'Dirección',
      'empresa.telefono': 'Teléfono',
      'empresa.ruc': 'RUC',
      'empresa.logo_path': 'Path del logo',
      'empresa.whatsapp': 'WhatsApp',
      'cobranza.dias_gracia': 'Días de gracia',
      'cobranza.modo_ruta': 'Modo de ruta',
      'cobranza.cargo_reconexion_habilitado': 'Cobrar reconexión',
      'cobranza.cargo_reconexion': 'Monto reconexión automática',
      'cobranza.monto_reconexion': 'Monto de reconexión',
      'caja_chica.habilitada': 'Caja chica del cobrador',
      'audit.visible_admin_cobranza': 'Admin cobranza ve historial de cambios',
      'cobranza.cobrador_edita_fecha': 'Cobrador puede editar fecha',
      'cobranza.cobrador_anula_cobros': 'Cobrador puede anular cobros',
      'cobranza.cobrador_edita_cobros': 'Cobrador puede editar cobros',
      'cobranza.comprobante_habilitado': 'Habilitar foto de comprobante',
      'cobranza.foto_obligatoria': 'Foto comprobante obligatoria',
      'cobranza.pantalla_pagos': 'Pantalla de pagos del tenant (admin)',
      'cobranza.audit_visible_admin': 'Panel de Auditoría visible al admin',
      'cobranza.registrar_visitas': 'Registrar visitas a clientes',
      'cobranza.pago_parcial': 'Permitir pago parcial',
      'cobranza.pago_adelantado': 'Permitir pago adelantado (multi-cuota)',
      'cobranza.dias_cuotas_visibles': 'Días de cuotas próximas',
      'cobranza.avisos_habilitado': 'Mostrar pantalla de Avisos (próximos a corte / mora)',
      'cobranza.notif_whatsapp_habilitado': 'Permitir notificar por WhatsApp desde Avisos',
      'cobranza.cambio_plan_habilitado': 'Mostrar botón "Cambiar plan" en el detalle de contrato',
      'cobranza.reportes_detallados': 'Mostrar reportes detallados (además del de cobranza)',
      'cobranza.cobro_extra': 'Habilitar "Cobro extra" (multa / otro cargo puntual)',
      'busqueda.por_codigo': 'Buscar por código de cliente',
      'busqueda.por_cedula': 'Buscar por cédula',
      'busqueda.por_telefono': 'Buscar por teléfono',
      'busqueda.por_contrato': 'Buscar por código de contrato',
      'cobranza.aviso_msg_gracia': 'Mensaje WhatsApp — próximo a corte (gracia)',
      'cobranza.aviso_msg_mora': 'Mensaje WhatsApp — corte (mora)',
      'dashboard.cobros_visible': 'Mostrar cobros (Hoy / Semana / Mes)',
      'dashboard.proyeccion_visible': 'Mostrar proyección de cobros por cobrador',
      'dashboard.recuperacion_visible': 'Mostrar recuperación por comunidad',
      'dashboard.sparkline_visible': 'Mostrar gráfico de 7 días',
      'dashboard.operativo_visible': 'Mostrar KPIs operativos',
      'dashboard.top_cobradores_visible': 'Mostrar top cobradores',
      'dashboard.distribucion_visible': 'Mostrar distribución de cuotas',
      'pagos.transferencia_habilitada': 'Aceptar transferencias',
      'pagos.deposito_habilitado': 'Aceptar depósitos',
      'pagos.tarjeta_habilitada': 'Aceptar tarjeta',
      'pagos.metodo_efectivo': 'Aceptar efectivo',
      'pagos.metodo_transferencia': 'Aceptar transferencia',
      'pagos.metodo_tarjeta': 'Aceptar tarjeta',
      'pagos.usd_habilitado': 'Aceptar pagos en USD',
      'pagos.tasa_usd_cordoba': 'Tasa USD → C\$',
      'moneda.principal': 'Moneda principal',
      'recibo.formato_default_mm': 'Ancho de papel (mm)',
      'recibo.template_57mm': 'Template 57mm',
      'recibo.template_80mm': 'Template 80mm',
      'recibo.imprimir_logo': 'Imprimir logo en recibo',
      'recibo.pie_libre': 'Pie del recibo',
      'recibo.titulo': 'Título del recibo',
      'recibo.monto_en_letras': 'Monto en letras',
      'recibo.mostrar_adeudado': 'Mostrar saldo de la cuota',
      'recibo.mostrar_empresa': 'Mostrar datos de empresa',
      'recibo.mostrar_cedula': 'Mostrar cédula del cliente',
      'recibo.mostrar_codigo': 'Mostrar código del cliente',
      'recibo.mostrar_hora': 'Mostrar hora del cobro',
      'cobranza.ajustes_habilitados': 'Permitir ajustes de cuota',
      'cobranza.ajuste_max_porcentaje': 'Tope % por ajuste (0 = sin tope)',
      'cobranza.ajuste_max_monto': 'Tope C\$ por ajuste (0 = sin tope)',
      'cuotas.descuento_pronto_pago': 'Descuento pronto pago (0 = apagado)',
      'cuotas.descuento_pronto_pago_tipo': 'Tipo de descuento pronto pago',
    };
    return labels[clave] ?? _humanize(clave.split('.').last);
  }

  static String _humanize(String raw) {
    return raw
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
  }

  static List<(String, String)>? _dropdownFor(String clave) {
    return switch (clave) {
      'cuotas.descuento_pronto_pago_tipo' => [
        ('porcentaje', 'Porcentaje (%)'),
        ('monto', 'Monto fijo (C\$)'),
      ],
      'cobranza.modo_ruta' => [
        ('libre', 'Libre'),
        ('planificada', 'Planificada'),
      ],
      'moneda.principal' => [
        ('NIO', 'Córdobas (NIO)'),
        ('USD', 'Dólares (USD)'),
      ],
      _ => null,
    };
  }
}

/// Widget de upload del logo de la empresa. Se muestra al inicio de la
/// tab "Empresa" cuando el usuario tiene permiso de admin.
///
/// Flujo:
/// 1. Muestra preview del logo actual (URL firmada vía `logoEmpresaUrlProvider`)
///    o un placeholder si no hay logo.
/// 2. Botón "Subir logo" abre el image picker.
/// 3. Al seleccionar imagen, sube a Storage y guarda el path en
///    `empresa.logo_path` vía `settingsRepo.update`.
/// 4. El provider se invalida y la URL firmada se refresca.
class _LogoUploadWidget extends ConsumerStatefulWidget {
  const _LogoUploadWidget({required this.tenantId});
  final String tenantId;

  @override
  ConsumerState<_LogoUploadWidget> createState() => _LogoUploadWidgetState();
}

class _LogoUploadWidgetState extends ConsumerState<_LogoUploadWidget> {
  bool _subiendo = false;
  String? _error;

  Future<void> _subirLogo() async {
    setState(() {
      _subiendo = true;
      _error = null;
    });
    try {
      final service = ref.read(logoEmpresaServiceProvider);
      final path = await service.pickYSubir(tenantId: widget.tenantId);
      // C7: el picker/upload pudo resolver con la pantalla ya desmontada —
      // setState/ref sobre un State muerto tiran en debug.
      if (!mounted) return;
      if (path == null) {
        // Usuario canceló el picker.
        setState(() => _subiendo = false);
        return;
      }
      // ORDEN (fix 2026-07-15, race del preview): PRIMERO refrescar el disco
      // (así el cache-first del provider re-fired lee bytes NUEVOS), DESPUÉS
      // limpiar la caché de imágenes (el `Image.network` del preview y las
      // vistas de recibo/reportes reusan la NetworkImage por URL — sin evict,
      // el `invalidate` re-firea el provider pero la miniatura se pinta con
      // los bytes CACHEADOS de la URL firmada anterior por 1-2 frames, dando
      // el "alterna a veces bien / a veces mal"). Recién ahí `invalidate`.
      await ref.read(settingsRepoProvider).update(
            widget.tenantId,
            'empresa.logo_path',
            path,
            usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
          );
      // El admin acaba de pisar el archivo en la MISMA ruta, así que el path
      // no distingue el logo nuevo del viejo. `update` de arriba ya movió el
      // `updated_at` (que es la versión del cache), pero tirar el cache acá lo
      // hace determinista: la próxima lectura va sí o sí a la red, sin depender
      // de que el stream de settings haya emitido todavía.
      await LogoCacheService.invalidar(widget.tenantId);
      // C7: ídem tras los awaits (ref.invalidate exige State vivo).
      if (!mounted) return;
      // Evict TODO el imageCache — Flutter keyea por URL exacta y con signed
      // URLs distintas no bastaría evict de una sola; barremos entero (es
      // chico, se reconstruye al vuelo). Cubre preview, recibo, reportes.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // Invalidar AMBOS providers: URL firmada (preview) y bytes (recibo +
      // headers de reportes).
      ref.invalidate(logoEmpresaUrlProvider);
      ref.invalidate(logoEmpresaBytesProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logo actualizado')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = mensajeErrorHumano(e, contexto: 'subir'));
      }
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  Future<void> _eliminarLogo() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar logo'),
        content: const Text('¿Seguro que querés eliminar el logo de la empresa?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmar != true) return;

    setState(() {
      _subiendo = true;
      _error = null;
    });
    try {
      final settings = ref.read(appSettingsProvider);
      final currentPath = settings.empresaLogoPath;
      if (currentPath.isNotEmpty) {
        final service = ref.read(logoEmpresaServiceProvider);
        await service.eliminar(currentPath);
      }
      // Limpiar el path en settings (null serializado como JSON).
      await ref.read(settingsRepoProvider).update(
            widget.tenantId,
            'empresa.logo_path',
            null,
            usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
          );
      // Borrar también el cache de disco (higiene: que un futuro logo no
      // conviva con bytes viejos) e invalidar ambos providers.
      await LogoLocalStorage.delete(widget.tenantId);
      if (!mounted) return;
      // Evict imageCache antes del invalidate (mismo motivo que en subir):
      // sin esto, la miniatura de "sin logo" tarda 1-2 frames en aparecer.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      ref.invalidate(logoEmpresaUrlProvider);
      ref.invalidate(logoEmpresaBytesProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logo eliminado')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = mensajeErrorHumano(e, contexto: 'eliminar'));
      }
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logoUrlAsync = ref.watch(logoEmpresaUrlProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.image, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Logo de la empresa',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Se muestra en el recibo de cobro.',
                          style:
                              TextStyle(color: scheme.outline, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 12),
            const SizedBox(height: 4),

            // Preview del logo o placeholder.
            Center(
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                  color: scheme.surfaceContainerHighest,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: logoUrlAsync.when(
                    data: (url) {
                      if (url == null) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.image_outlined,
                                  size: 48, color: scheme.outline),
                              const SizedBox(height: 8),
                              Text('Sin logo',
                                  style: TextStyle(
                                      color: scheme.outline, fontSize: 13)),
                            ],
                          ),
                        );
                      }
                      return Image.network(
                        url,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return const Center(
                              child: CircularProgressIndicator(strokeWidth: 2));
                        },
                        errorBuilder: (_, __, ___) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.broken_image,
                                  size: 48, color: scheme.error),
                              const SizedBox(height: 8),
                              Text('Error al cargar',
                                  style: TextStyle(
                                      color: scheme.error, fontSize: 13)),
                            ],
                          ),
                        ),
                      );
                    },
                    loading: () => const Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    error: (_, __) => Center(
                      child: Icon(Icons.error_outline,
                          size: 48, color: scheme.error),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),

            // Botones de acción.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _subiendo ? null : _subirLogo,
                  icon: _subiendo
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload),
                  label: Text(_subiendo ? 'Subiendo...' : 'Subir logo'),
                ),
                // Botón eliminar solo si hay logo.
                if (ref.read(appSettingsProvider).empresaLogoPath.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _subiendo ? null : _eliminarLogo,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Eliminar'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
