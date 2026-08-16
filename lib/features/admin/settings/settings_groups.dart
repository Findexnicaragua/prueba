import 'package:flutter/material.dart';

/// Definiciones declarativas de los grupos (tarjetas-sección) del panel de
/// settings. Cada tab del panel se arma a partir de la lista de grupos de su
/// categoría: el screen recorre estos grupos, busca cada `clave` en el mapa
/// de settings sincronizado y renderiza sólo las que existen.
///
/// La separación tab → grupos → settings vive acá para que el screen quede
/// declarativo: agregar/mover un setting de grupo es editar estos datos, no
/// la lógica de render.

/// Un setting dentro de un grupo. Puede declarar `hijos`: las claves de los
/// settings que SOLO se revelan (animado) cuando este setting (un toggle
/// padre) está en ON.
class SettingEntry {
  const SettingEntry(this.clave, {this.hijos = const []});

  final String clave;

  /// Claves de settings hijos que dependen de que este (toggle padre) esté ON.
  /// Si está vacío, el setting es un campo plano sin dependientes.
  final List<String> hijos;

  bool get tieneHijos => hijos.isNotEmpty;
}

/// Una tarjeta-sección: header (ícono + título) + lista de settings.
class SettingGroup {
  const SettingGroup({
    required this.titulo,
    required this.icono,
    required this.entradas,
    this.subtitulo,
  });

  final String titulo;
  final IconData icono;
  final String? subtitulo;
  final List<SettingEntry> entradas;

  /// Todas las claves que el grupo puede llegar a mostrar (padres + hijos).
  /// Se usa para decidir si el grupo tiene al menos un setting presente en el
  /// mapa sincronizado (si ninguna existe, el grupo no se renderiza).
  Iterable<String> get todasLasClaves sync* {
    for (final e in entradas) {
      yield e.clave;
      yield* e.hijos;
    }
  }
}

/// Grupos de la tab Empresa. (El `_LogoUploadWidget` se inserta aparte arriba
/// del primer grupo desde el screen, sólo si es admin.)
const kGruposEmpresa = <SettingGroup>[
  SettingGroup(
    titulo: 'Datos de la empresa',
    icono: Icons.business,
    entradas: [
      SettingEntry('empresa.nombre'),
      SettingEntry('empresa.direccion'),
      SettingEntry('empresa.telefono'),
      SettingEntry('empresa.ruc'),
      SettingEntry('empresa.whatsapp'),
    ],
  ),
];

/// Grupos de la tab Cobranza. Los settings super_admin-only (comprobante,
/// foto, pantallas opcionales) ya NO viven acá: se movieron a la tab Avanzado.
const kGruposCobranza = <SettingGroup>[
  SettingGroup(
    titulo: 'Reglas de cobro',
    icono: Icons.rule,
    entradas: [
      SettingEntry('cobranza.dias_gracia'),
      SettingEntry('cobranza.dias_cuotas_visibles'),
    ],
  ),
  SettingGroup(
    titulo: 'Permisos',
    icono: Icons.lock_open,
    entradas: [
      SettingEntry('cobranza.cobrador_edita_fecha'),
      SettingEntry('audit.visible_admin_cobranza'),
    ],
  ),
  // Las plantillas de WhatsApp (aviso_msg_gracia/mora) NO van acá: se editan con
  // el editor visual (_PlantillasWhatsappCard → _PlantillaEditorDialog, en
  // settings_admin_screen) que inserta las variables sin typos. Están en _hidden
  // y se rinden como card propia en la tab Cobranza.
];

/// Grupos de la tab Pagos.
const kGruposPagos = <SettingGroup>[
  SettingGroup(
    titulo: 'Métodos de pago',
    icono: Icons.payments,
    entradas: [
      // metodo_efectivo queda fijo en ON (lo fuerza el editor del tile).
      SettingEntry('pagos.metodo_efectivo'),
      SettingEntry('pagos.metodo_transferencia'),
      SettingEntry('pagos.metodo_tarjeta'),
    ],
  ),
  SettingGroup(
    titulo: 'Dólares',
    icono: Icons.attach_money,
    entradas: [
      SettingEntry(
        'pagos.usd_habilitado',
        hijos: ['pagos.tasa_usd_cordoba'],
      ),
    ],
  ),
];

/// Una CATEGORÍA del tab Avanzado: agrupa varias tarjetas-sección (SettingGroup)
/// bajo un encabezado de DOMINIO, para que el cajón super_admin no sea un
/// grab-bag. `cardsEspeciales` lista IDs de tarjetas que NO son SettingGroup y se
/// renderizan con widgets propios en el screen ('historial', 'whatsapp_api').
class SettingCategoria {
  const SettingCategoria({
    required this.titulo,
    required this.icono,
    required this.subtitulo,
    required this.grupos,
    this.cardsEspeciales = const [],
  });

  final String titulo;
  final IconData icono;
  final String subtitulo;
  final List<SettingGroup> grupos;
  final List<String> cardsEspeciales;
}

/// Categorías del tab Avanzado (solo super_admin). Agrupan las tarjetas-sección
/// por DOMINIO para dar jerarquía: en vez de una grilla plana que mezclaba
/// dashboard, reglas de cobro, búsqueda y permisos, cada banda reúne lo que se
/// prende/apaga junto. Reorganización 2026-06-27 (no cambia settings ni DB; solo
/// el orden/agrupación visual). El orden de esta lista = orden de render.
const kCategoriasAvanzado = <SettingCategoria>[
  // 1) Reglas de NEGOCIO sensibles que tocan cuánto entra/sale de caja. Las
  //    gestiona el dueño del SaaS por tenant.
  SettingCategoria(
    titulo: 'Reglas de cobro y dinero',
    icono: Icons.payments_outlined,
    subtitulo: 'Qué plata se puede cobrar o descontar y bajo qué reglas.',
    grupos: [
      SettingGroup(
        titulo: 'Reglas de cobro avanzadas',
        icono: Icons.tune,
        entradas: [
          SettingEntry('cobranza.pago_parcial'),
          SettingEntry('cobranza.pago_adelantado'),
        ],
      ),
      // Descuentos del admin desde el contrato (rediseño 2026-06-12: el cobrador
      // no descuenta). Topes como hijos del toggle padre.
      SettingGroup(
        titulo: 'Ajustes de cuota (admin)',
        icono: Icons.percent,
        subtitulo: 'Descuentos con motivo que el admin aplica a una cuota desde '
            'el detalle del contrato (correcciones y promos).',
        entradas: [
          SettingEntry(
            'cobranza.ajustes_habilitados',
            hijos: [
              'cobranza.ajuste_max_porcentaje',
              'cobranza.ajuste_max_monto',
            ],
          ),
        ],
      ),
      // Pronto pago (antes huérfano: categoría 'cuotas' sin tab → invisible).
      SettingGroup(
        titulo: 'Pronto pago',
        icono: Icons.event_available,
        subtitulo: 'Descuento automático cuando el cliente paga antes del '
            'vencimiento (0 = apagado).',
        entradas: [
          SettingEntry('cuotas.descuento_pronto_pago'),
          SettingEntry('cuotas.descuento_pronto_pago_tipo'),
        ],
      ),
      SettingGroup(
        titulo: 'Reconexión',
        icono: Icons.power,
        entradas: [
          SettingEntry(
            'cobranza.cargo_reconexion_habilitado',
            hijos: ['cobranza.monto_reconexion'],
          ),
        ],
      ),
      // Cambio de plan del contrato (0151): regla de pricing del contrato,
      // super-only. En ON, admin/admin_cobranza ven "Cambiar plan" en el detalle.
      SettingGroup(
        titulo: 'Cambio de plan',
        icono: Icons.swap_horiz,
        subtitulo: 'Permite a admin / admin de cobranza cambiar el plan de un '
            'contrato manteniendo su vigencia, con efecto al próximo ciclo o '
            'prorrateado desde hoy.',
        entradas: [
          SettingEntry('cobranza.cambio_plan_habilitado'),
        ],
      ),
      // Cobro extra / cobro puntual (0177): multa u otro cargo que el admin
      // cobra fuera del ciclo del contrato, desde el cliente y desde tickets.
      // Super-only; en OFF se ocultan ambas entradas.
      SettingGroup(
        titulo: 'Cobro extra (multa / otro)',
        icono: Icons.add_card_outlined,
        subtitulo: 'Permite crear un cobro puntual (multa u otro cargo) desde el '
            'detalle del cliente y desde un ticket. Apagado = oculto.',
        entradas: [
          SettingEntry('cobranza.cobro_extra'),
        ],
      ),
      // Crédito por excedente (R17, 0127): regla de negocio del dueño del SaaS.
      SettingGroup(
        titulo: 'Crédito por excedente',
        icono: Icons.savings,
        subtitulo: 'Al suspender/cancelar, ofrece acreditar/devolver/condonar el '
            'excedente pagado por adelantado (OFF = se pierde, como antes).',
        entradas: [
          SettingEntry('cobranza.credito_excedente'),
        ],
      ),
    ],
  ),
  // 2) Qué PUEDE HACER el personal de campo y qué pantallas/herramientas se le
  //    habilitan en el momento del cobro.
  SettingCategoria(
    titulo: 'Permisos y operación del cobrador',
    icono: Icons.badge_outlined,
    subtitulo: 'Qué puede hacer el personal de campo y qué pantallas se le '
        'habilitan.',
    grupos: [
      SettingGroup(
        titulo: 'Permisos del cobrador',
        icono: Icons.lock_person,
        entradas: [
          SettingEntry('cobranza.cobrador_anula_cobros'),
          SettingEntry('cobranza.cobrador_edita_cobros'),
        ],
      ),
      // Cambio de fecha de pago por días (feature C, 0119): switch maestro; cada
      // usuario necesita el permiso por persona (se habilita en Personal).
      SettingGroup(
        titulo: 'Cambio de fecha de pago',
        icono: Icons.event_repeat,
        subtitulo: 'Permite a personal habilitado cambiar la fecha de pago de un '
            'cliente AL DÍA, cobrando los días puente. Habilitá quién puede usarlo '
            'en cada cobrador / admin de cobranza desde Personal.',
        entradas: [
          SettingEntry('cobranza.cambio_fecha_habilitado'),
        ],
      ),
      SettingGroup(
        titulo: 'Foto de comprobante',
        icono: Icons.photo_camera,
        entradas: [
          SettingEntry(
            'cobranza.comprobante_habilitado',
            hijos: ['cobranza.foto_obligatoria'],
          ),
        ],
      ),
      SettingGroup(
        titulo: 'Pantallas opcionales del admin',
        icono: Icons.dashboard_customize,
        entradas: [
          SettingEntry('cobranza.pantalla_pagos'),
          SettingEntry('cobranza.registrar_visitas'),
        ],
      ),
    ],
  ),
  // 3) Cómo se le avisa al cliente (manual wa.me + envío automático por API).
  SettingCategoria(
    titulo: 'Avisos y notificaciones',
    icono: Icons.notifications_active_outlined,
    subtitulo: 'Cómo se le avisa al cliente próximo a corte o en mora.',
    grupos: [
      // Pantalla de Avisos + notificar WhatsApp (0134/0135). Las PLANTILLAS del
      // mensaje las edita el admin → van en kGruposCobranza, no acá.
      SettingGroup(
        titulo: 'Avisos de cobranza',
        icono: Icons.notifications_active_outlined,
        subtitulo: 'Habilita la pantalla "Avisos" (clientes próximos a corte y en '
            'mora) y el botón de notificar por WhatsApp, para este tenant.',
        entradas: [
          SettingEntry('cobranza.avisos_habilitado'),
          SettingEntry('cobranza.notif_whatsapp_habilitado'),
        ],
      ),
    ],
    // El modo API (envío automático por lote, 0137) se renderiza con
    // _WhatsappApiCard — vive bajo esta categoría (antes colgaba al final).
    cardsEspeciales: ['whatsapp_api'],
  ),
  // 4) Qué VE el admin del tenant en sus pantallas de análisis.
  SettingCategoria(
    titulo: 'Visibilidad y reportes',
    icono: Icons.insights_outlined,
    subtitulo: 'Qué tableros y reportes ve el admin del ISP.',
    grupos: [
      // Secciones del dashboard admin toggleables por tenant (0133). Cada clave
      // 'dashboard.*_visible' muestra/oculta un bloque del Resumen.
      SettingGroup(
        titulo: 'Secciones del dashboard',
        icono: Icons.dashboard,
        subtitulo: 'Qué bloques ve el admin en el Resumen. Apagá los que no '
            'quieras mostrarle a este tenant.',
        entradas: [
          SettingEntry('dashboard.cobros_visible'),
          SettingEntry('dashboard.proyeccion_visible'),
          SettingEntry('dashboard.recuperacion_visible'),
          SettingEntry('dashboard.sparkline_visible'),
          SettingEntry('dashboard.operativo_visible'),
          SettingEntry('dashboard.top_cobradores_visible'),
          SettingEntry('dashboard.distribucion_visible'),
        ],
      ),
      // Reportes detallados (legacy) vs plantilla estándar (rework 0141).
      SettingGroup(
        titulo: 'Reportes',
        icono: Icons.assessment_outlined,
        subtitulo: 'Por defecto el módulo usa la plantilla estándar de cobranza. '
            'Activá esto para mostrar además los reportes detallados (arqueo, '
            'analíticas y el menú PDF/Excel variado).',
        entradas: [
          SettingEntry('cobranza.reportes_detallados'),
        ],
      ),
    ],
  ),
  // 5) Cómo se ENCUENTRA y se AUDITA la información (metaconfig transversal).
  SettingCategoria(
    titulo: 'Búsqueda e historial',
    icono: Icons.manage_search,
    subtitulo: 'Cómo se encuentra y se audita la información.',
    grupos: [
      // Campos de búsqueda de cliente (0145): el super_admin elige qué campos
      // entran al buscar. El nombre SIEMPRE entra. Apagar Teléfono evita falsos
      // positivos. Los consume busquedaClienteSql.
      SettingGroup(
        titulo: 'Búsqueda de clientes',
        icono: Icons.search,
        subtitulo: 'Qué campos se usan al buscar un cliente (en todas las listas). '
            'El nombre siempre busca. Apagá Teléfono si te trae falsos positivos.',
        entradas: [
          SettingEntry('busqueda.por_codigo'),
          SettingEntry('busqueda.por_cedula'),
          SettingEntry('busqueda.por_telefono'),
          SettingEntry('busqueda.por_contrato'),
        ],
      ),
    ],
    // "Campos del historial" (qué campos del op_log se muestran por entidad) se
    // renderiza con _HistorialCamposCard (link a otra pantalla, no un setting).
    cardsEspeciales: ['historial'],
  ),
];

/// Todos los grupos del tab Avanzado, aplanados desde las categorías. Lo usan
/// `gruposDe('avanzado')` y el catch-all `clavesReclamadasGlobal()`.
final List<SettingGroup> kGruposAvanzado =
    kCategoriasAvanzado.expand((c) => c.grupos).toList(growable: false);

/// Devuelve los grupos definidos para una categoría/tab.
List<SettingGroup> gruposDe(String categoria) {
  return switch (categoria) {
    'empresa' => kGruposEmpresa,
    'cobranza' => kGruposCobranza,
    'pagos' => kGruposPagos,
    'avanzado' => kGruposAvanzado,
    _ => const [],
  };
}

/// TODAS las claves reclamadas por algún grupo, en CUALQUIER tab. El catch-all
/// "Otros" la usa para no re-mostrar un setting que ya tiene grupo en otra tab.
/// Caso real: los settings super_admin-only tienen categoría DB 'cobranza' pero
/// se muestran en grupos de la tab 'avanzado'; sin esto, el "Otros" de Cobranza
/// los duplicaría para el super_admin.
Set<String> clavesReclamadasGlobal() {
  final out = <String>{};
  for (final lista in [
    kGruposEmpresa,
    kGruposCobranza,
    kGruposPagos,
    kGruposAvanzado,
  ]) {
    for (final g in lista) {
      out.addAll(g.todasLasClaves);
    }
  }
  return out;
}
