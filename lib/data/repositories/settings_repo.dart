import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/recibo_layout.dart';
import '../models/setting.dart';
import '../providers/cobrador_provider.dart';
import '../providers/db_epoch_provider.dart';
import '../utils/cuota_estado_visual.dart';
import '../utils/op_log.dart';

class SettingsRepo {
  const SettingsRepo();

  /// [tenantId]: filtra los settings al tenant efectivo. CRÍTICO durante
  /// impersonación — el SQLite del super_admin tiene settings de DOS tenants
  /// (System + impersonado) con las MISMAS claves; sin el filtro `map[clave]`
  /// se quedaba con una fila no determinista (M4 del audit). Para un admin
  /// normal el SQLite es mono-tenant, así que el filtro es inocuo. Null → sin filtro.
  Stream<Map<String, Setting>> watchAll({String? tenantId}) {
    final where = tenantId != null ? 'WHERE tenant_id = ?' : '';
    final params = tenantId != null ? <Object?>[tenantId] : <Object?>[];
    return ps.db
        .watch('SELECT * FROM settings $where ORDER BY categoria, clave',
            parameters: params)
        .map((rows) {
      final map = <String, Setting>{};
      for (final r in rows) {
        final s = Setting.fromRow(r);
        map[s.clave] = s;
      }
      return map;
    });
  }

  Future<dynamic> read(String clave, {dynamic fallback}) async {
    final rows = await ps.db
        .getAll('SELECT valor FROM settings WHERE clave = ?', [clave]);
    if (rows.isEmpty) return fallback;
    final raw = rows.first['valor'] as String?;
    try {
      return raw == null ? fallback : jsonDecode(raw);
    } catch (_) {
      return raw ?? fallback;
    }
  }

  /// Actualiza el valor de un setting. El valor se serializa con JSON,
  /// así un bool va como `true`, número como `42`, string como `"texto"`.
  Future<void> update(String tenantId, String clave, dynamic valor,
      {String? usuarioId}) async {
    final encoded = jsonEncode(valor);
    final now = DateTime.now();
    final opId = OpLog.nuevoOpId();
    // settings = config de tenant; el admin que la cambia es el actor. Si no se
    // pasa usuarioId (paneles super_admin), el actor es "System Admin".
    final actor = usuarioId != null
        ? await OpLog.actorDeUsuario(ps.db, usuarioId)
        : const OpLogActor.systemAdmin();
    await ps.dbW.writeTransaction((tx) async {
      final antes = await tx.getAll(
        'SELECT id, valor FROM settings WHERE tenant_id = ? AND clave = ?',
        [tenantId, clave],
      );
      await tx.execute(
        'UPDATE settings SET valor = ?, updated_at = ? WHERE tenant_id = ? AND clave = ?',
        [encoded, now.toUtc().toIso8601String(), tenantId, clave],
      );
      if (antes.isNotEmpty && antes.first['valor'] != encoded) {
        await OpLog.escribir(tx,
            tenantId: tenantId, opId: opId, tipoOp: 'edicion_entidad',
            entidad: 'settings', entidadId: antes.first['id'] as String,
            accion: 'update',
            diff: {
              'campos': [
                {'campo': clave, 'antes': antes.first['valor'], 'despues': encoded}
              ]
            },
            actor: actor, ocurridoEn: now.toUtc());
      }
    });
  }

  /// Upsert de un setting: actualiza si la fila existe, la inserta si no.
  ///
  /// No usamos `ON CONFLICT(tenant_id, clave)` porque la constraint UNIQUE
  /// vive en Postgres, pero la tabla local de PowerSync solo enforcea el PK
  /// `id`. Por eso hacemos SELECT → UPDATE | INSERT (ambos válidos en SQLite).
  ///
  /// `valor` se serializa con JSON. `tipo`/`categoria` se respetan al crear.
  Future<void> upsert(
    String tenantId,
    String clave,
    dynamic valor, {
    String tipo = 'json',
    String categoria = 'cobranza',
    // Quién puede editar la clave (enforced por la RLS settings_write_admin:
    // un admin NO puede escribir claves 'super_admin'). Default 'admin' =
    // comportamiento previo; el super pasa 'super_admin' para claves suyas.
    String editablePor = 'admin',
    String? usuarioId,
  }) async {
    final encoded = jsonEncode(valor);
    final now = DateTime.now();
    // updated_at en UTC (fix F0): Postgres lo lee como UTC; naive quedaba -6h.
    final nowStr = now.toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = usuarioId != null
        ? await OpLog.actorDeUsuario(ps.db, usuarioId)
        : const OpLogActor.systemAdmin();

    await ps.dbW.writeTransaction((tx) async {
      final existentes = await tx.getAll(
        'SELECT id, valor FROM settings WHERE tenant_id = ? AND clave = ? LIMIT 1',
        [tenantId, clave],
      );

      if (existentes.isNotEmpty) {
        final id = existentes.first['id'] as String;
        final valorViejo = existentes.first['valor'];
        await tx.execute(
          'UPDATE settings SET valor = ?, updated_at = ? WHERE tenant_id = ? AND clave = ?',
          [encoded, nowStr, tenantId, clave],
        );
        if (valorViejo != encoded) {
          await OpLog.escribir(tx,
              tenantId: tenantId, opId: opId, tipoOp: 'edicion_entidad',
              entidad: 'settings', entidadId: id, accion: 'update',
              diff: {
                'campos': [
                  {'campo': clave, 'antes': valorViejo, 'despues': encoded}
                ]
              },
              actor: actor, ocurridoEn: now.toUtc());
        }
        return;
      }

      // INSERT: incluir todas las columnas NOT NULL (tenant_id, clave, valor,
      // tipo, categoria) + id (PK local de PowerSync) + updated_at.
      final id = const Uuid().v4();
      await tx.execute(
        '''
        INSERT INTO settings (id, tenant_id, clave, valor, tipo, categoria, editable_por, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [id, tenantId, clave, encoded, tipo, categoria, editablePor, nowStr],
      );
      await OpLog.escribir(tx,
          tenantId: tenantId, opId: opId, tipoOp: 'alta_entidad',
          entidad: 'settings', entidadId: id, accion: 'create',
          diff: {
            'campos': [
              {'campo': clave, 'antes': null, 'despues': encoded}
            ]
          },
          actor: actor, ocurridoEn: now.toUtc());
    });
  }
}

final settingsRepoProvider = Provider((_) => const SettingsRepo());

/// Mapa clave→Setting. Único stream global de settings.
final settingsMapProvider = StreamProvider<Map<String, Setting>>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  // Filtra al tenant efectivo (propio o impersonado) para no mezclar settings
  // de dos tenants en el SQLite del super_admin durante impersonación (M4).
  final tenantId = ref.watch(tenantIdProvider);
  return ref.watch(settingsRepoProvider).watchAll(tenantId: tenantId);
});

/// Helper genérico tipado: lee un setting con default.
T settingValue<T>(Map<String, Setting>? map, String clave, T fallback) {
  if (map == null) return fallback;
  final s = map[clave];
  if (s == null) return fallback;
  final v = s.valor;
  if (v is T) return v;
  if (T == double && v is num) return v.toDouble() as T;
  if (T == int && v is num) return v.toInt() as T;
  // Boolean defense: JSONB puede llegar como string "true"/"false" via PowerSync.
  if (T == bool && v is String) {
    return (v.toLowerCase() == 'true') as T;
  }
  return fallback;
}

/// Plantillas por defecto de los avisos por WhatsApp (Feature 4). DEBEN espejar
/// los defaults de la migración 0135 (si cambian, cambiar en ambos lados). Las
/// usa el getter (fallback) y el editor visual ("Restaurar por defecto").
/// Placeholders: {nombre} {monto} {dias} {empresa}.
const kAvisoMsgGraciaDefault =
    'Hola {nombre}, le recordamos que tiene un saldo pendiente de {monto}. '
    'Para evitar la suspensión del servicio, realice su pago en los próximos '
    '{dias} días. Gracias — {empresa}';
const kAvisoMsgMoraDefault =
    'Hola {nombre}, su servicio fue suspendido por falta de pago (saldo '
    'vencido: {monto}, {dias} días de atraso). Para reactivarlo, acérquese a '
    'pagar o contáctenos. Gracias — {empresa}';

/// Acceso tipado a los settings más usados en la app.
class AppSettings {
  AppSettings(this._map);
  final Map<String, Setting>? _map;

  int get diasGracia => settingValue<num>(_map, 'cobranza.dias_gracia', 10).toInt();
  // (Los getters descuentosHabilitados/descuentoTipo/descuentoMax* se
  // retiraron con el rediseño 2026-06-12: el cobrador no descuenta — todo
  // descuento lo aplica el admin desde el contrato. Settings en _hidden.)

  bool get reconexionHabilitada =>
      settingValue<bool>(_map, 'cobranza.cargo_reconexion_habilitado', false);
  double get montoReconexion =>
      settingValue<num>(_map, 'cobranza.monto_reconexion', 0).toDouble();

  // Efectivo es el método de pago POR DEFECTO e INMUTABLE: siempre disponible.
  // No se puede desactivar (sino el cobrador podría quedar sin ningún método y
  // se rompería el cobro). El toggle en settings se muestra fijo en ON.
  bool get efectivoHabilitado => true;

  // Transferencia: chequeamos la clave original de 0010 y la de 0040 (OR).
  // Esto cubre tenants que tengan una, la otra, o ambas.
  bool get transferenciaHabilitada =>
      settingValue<bool>(_map, 'pagos.transferencia_habilitada', false) ||
      settingValue<bool>(_map, 'pagos.metodo_transferencia', false);
  // Tarjeta: chequeamos clave original de 0010 y la de 0040 (OR).
  bool get tarjetaHabilitada =>
      settingValue<bool>(_map, 'pagos.tarjeta_habilitada', false) ||
      settingValue<bool>(_map, 'pagos.metodo_tarjeta', false);
  bool get usdHabilitado =>
      settingValue<bool>(_map, 'pagos.usd_habilitado', true);
  double get tasaUsd =>
      settingValue<num>(_map, 'pagos.tasa_usd_cordoba', 36.5).toDouble();

  // (cuotasManuales se retiró con la pantalla /admin/cuotas — 2026-06-11.)

  // Ajustes de cuota (Sprint 2, 0115): habilitación + topes super-only.
  bool get ajustesHabilitados =>
      settingValue<bool>(_map, 'cobranza.ajustes_habilitados', false);
  double get ajusteMaxPorcentaje =>
      settingValue<num>(_map, 'cobranza.ajuste_max_porcentaje', 50).toDouble();
  double get ajusteMaxMonto =>
      settingValue<num>(_map, 'cobranza.ajuste_max_monto', 0).toDouble();

  // Permisos del cobrador (toggles en Settings → Cobranza).
  bool get cobradorEditaFecha =>
      settingValue<bool>(_map, 'cobranza.cobrador_edita_fecha', false);
  bool get cobradorAnulaCobros =>
      settingValue<bool>(_map, 'cobranza.cobrador_anula_cobros', false);
  bool get cobradorEditaCobros =>
      settingValue<bool>(_map, 'cobranza.cobrador_edita_cobros', false);
  bool get fotoObligatoria =>
      settingValue<bool>(_map, 'cobranza.foto_obligatoria', false);

  /// Switch maestro de la foto de comprobante. Default FALSE → el cobro NO sube
  /// fotos (cero consumo de Storage). Solo el super_admin lo habilita por tenant
  /// (el toggle vive gateado en settings). `fotoObligatoria` solo aplica si esto
  /// está en ON.
  bool get comprobanteHabilitado =>
      settingValue<bool>(_map, 'cobranza.comprobante_habilitado', false);

  /// Cambio de fecha de pago por días (feature C, 0119): switch maestro por
  /// tenant que SOLO habilita el super_admin (toggle super_admin-only). Default
  /// FALSE. Aun con esto en ON, cada cobrador/admin_cobranza necesita además el
  /// permiso por usuario (`cobradores.puede_cambiar_fecha`); el rol admin puede
  /// siempre. El gate duro lo aplica la RLS server-side (`puede_cambiar_fecha_pago()`).
  bool get cambioFechaHabilitado =>
      settingValue<bool>(_map, 'cobranza.cambio_fecha_habilitado', false);

  /// ¿El tenant tiene habilitado el "Cambiar plan" del contrato? Toggle
  /// super_admin-only (default FALSE = opt-in, migración 0151). Con esto en ON,
  /// admin/admin_cobranza ven el botón en el detalle de contrato (NO el cobrador
  /// — es operación de administración; el gate duro lo aplica la RLS server).
  bool get cambioPlanHabilitado =>
      settingValue<bool>(_map, 'cobranza.cambio_plan_habilitado', false);

  /// Pantalla admin opcional `/admin/pagos` (historial de pagos + anular),
  /// habilitada por el super_admin por tenant (toggle super_admin-only en
  /// settings). Default FALSE → el item del menú no aparece.
  bool get pantallaPagosHabilitada =>
      settingValue<bool>(_map, 'cobranza.pantalla_pagos', false);

  /// Registrar visitas: feature opcional, OFF por defecto, la habilita el
  /// super_admin por tenant (toggle super_admin-only en settings). Con OFF la
  /// pestaña "Visitas" del detalle del cliente no aparece.
  bool get registrarVisitasHabilitado =>
      settingValue<bool>(_map, 'cobranza.registrar_visitas', false);

  bool get pagoParcialPermitido =>
      settingValue<bool>(_map, 'cobranza.pago_parcial', true);
  bool get pagoAdelantadoPermitido =>
      settingValue<bool>(_map, 'cobranza.pago_adelantado', true);

  /// Crédito por excedente al suspender/cancelar (0127): ofrece acreditar/
  /// devolver/condonar el pago por adelantado de servicio no prestado. ON por
  /// defecto; el super_admin lo apaga por tenant (vuelve al comportamiento viejo).
  bool get creditoExcedenteHabilitado =>
      settingValue<bool>(_map, 'cobranza.credito_excedente', true);

  int get diasCuotasVisibles =>
      settingValue<num>(_map, 'cobranza.dias_cuotas_visibles', 5).toInt();

  // ── Secciones del dashboard admin (toggleables por el super_admin por tenant;
  // grupo super-only en Settings → Avanzado, migración 0133). Default TRUE: un
  // tenant sin la fila ve la sección (no rompe dashboards existentes). El
  // dashboard lee estos getters para mostrar/ocultar cada bloque.
  bool get dashCobrosVisible =>
      settingValue<bool>(_map, 'dashboard.cobros_visible', true);
  bool get dashSparklineVisible =>
      settingValue<bool>(_map, 'dashboard.sparkline_visible', true);
  bool get dashOperativoVisible =>
      settingValue<bool>(_map, 'dashboard.operativo_visible', true);
  bool get dashTopCobradoresVisible =>
      settingValue<bool>(_map, 'dashboard.top_cobradores_visible', true);
  bool get dashDistribucionVisible =>
      settingValue<bool>(_map, 'dashboard.distribucion_visible', true);
  bool get dashProyeccionVisible =>
      settingValue<bool>(_map, 'dashboard.proyeccion_visible', true);
  bool get dashRecuperacionVisible =>
      settingValue<bool>(_map, 'dashboard.recuperacion_visible', true);

  // ── Pantalla de Avisos (gracia/mora): toggle super_admin por tenant (0134).
  // Default FALSE = opt-in (el super_admin lo prende). Gatea el ítem de menú +
  // la ruta + lo ve solo admin/admin_cobranza.
  bool get avisosHabilitado =>
      settingValue<bool>(_map, 'cobranza.avisos_habilitado', false);

  // ── Notificación por WhatsApp desde Avisos (Feature 4, 0135). El toggle lo
  // habilita el super_admin; las plantillas las edita el admin. Los defaults
  // espejan los de la migración (placeholders {nombre} {monto} {dias} {empresa}).
  bool get notifWhatsappHabilitado =>
      settingValue<bool>(_map, 'cobranza.notif_whatsapp_habilitado', false);
  String get avisoMsgGracia =>
      settingValue<String>(_map, 'cobranza.aviso_msg_gracia', kAvisoMsgGraciaDefault);
  String get avisoMsgMora =>
      settingValue<String>(_map, 'cobranza.aviso_msg_mora', kAvisoMsgMoraDefault);

  // ── WhatsApp Cloud API (envío automático, modo pago, 0137). Config en
  // Avanzado (super_admin); el Access Token vive en el servidor, no acá.
  bool get notifApiHabilitado =>
      settingValue<bool>(_map, 'cobranza.notif_api_habilitado', false);
  bool get notifApiTokenConfigurado =>
      settingValue<bool>(_map, 'cobranza.notif_api_token_configurado', false);
  String get notifApiPhoneId =>
      settingValue<String>(_map, 'cobranza.notif_api_phone_id', '');
  String get notifApiTemplateGracia =>
      settingValue<String>(_map, 'cobranza.notif_api_template_gracia', '');
  String get notifApiTemplateMora =>
      settingValue<String>(_map, 'cobranza.notif_api_template_mora', '');
  String get notifApiTemplateLang =>
      settingValue<String>(_map, 'cobranza.notif_api_template_lang', 'es');
  int get notifApiHora =>
      settingValue<num>(_map, 'cobranza.notif_api_hora', 8).toInt();
  String get notifApiFrecuencia =>
      settingValue<String>(_map, 'cobranza.notif_api_frecuencia', 'semanal');
  int get notifApiTopeDiario =>
      settingValue<num>(_map, 'cobranza.notif_api_tope_diario', 200).toInt();
  // Cuerpo redactado de las plantillas API (borrador para copiar a Meta; NO es
  // lo que se envía). Mismo default que los avisos gratis (0139).
  String get notifApiBodyGracia => settingValue<String>(
      _map, 'cobranza.notif_api_body_gracia', kAvisoMsgGraciaDefault);
  String get notifApiBodyMora => settingValue<String>(
      _map, 'cobranza.notif_api_body_mora', kAvisoMsgMoraDefault);

  /// Toggle super_admin (Avanzado): muestra los reportes DETALLADOS (legacy) en
  /// el módulo de reportes. OFF (default) → solo el "Reporte de cobranza"
  /// (plantilla estándar). ON → además los reportes variados de siempre.
  bool get reportesDetallados =>
      settingValue<bool>(_map, 'cobranza.reportes_detallados', false);

  /// Toggle super_admin (Avanzado): habilita el "cobro extra" / cobro puntual
  /// (multa u otro cargo que decide el admin) desde el detalle del cliente Y el
  /// "Generar cobro" desde un ticket. OFF (default) → ambos ocultos. Es un
  /// módulo que el super_admin activa por tenant (0177).
  bool get cobroExtraHabilitado =>
      settingValue<bool>(_map, 'cobranza.cobro_extra', false);

  /// Campos de búsqueda de cliente habilitados (toggles super_admin, Avanzado).
  /// El NOMBRE siempre entra (no es toggle). Default true = comportamiento
  /// previo. El teléfono se puede apagar para evitar falsos positivos (buscar
  /// "003" traía todo cliente con 003 en el número). Lo consume el helper
  /// `busquedaClienteSql` (data/utils/busqueda_cliente.dart), compartido por las
  /// 5 búsquedas (clientes admin, lista del cobrador, Cobros, global, mapa).
  bool get busquedaPorCodigo =>
      settingValue<bool>(_map, 'busqueda.por_codigo', true);
  bool get busquedaPorCedula =>
      settingValue<bool>(_map, 'busqueda.por_cedula', true);
  bool get busquedaPorTelefono =>
      settingValue<bool>(_map, 'busqueda.por_telefono', true);
  bool get busquedaPorContrato =>
      settingValue<bool>(_map, 'busqueda.por_contrato', true);

  /// Colores configurables por estado de cuota (setting `cobranza.colores_estados`,
  /// map JSONB `{mora,gracia,hoy,proxima}` → "#RRGGBB"). Si falta o es inválido,
  /// cae a [ColoresEstados.defaults]. Fuente única de color para mapa, lista de
  /// cobros, cuotas admin, detalle de contrato y lista de clientes.
  ColoresEstados get coloresEstados {
    final s = _map?['cobranza.colores_estados'];
    if (s == null) return ColoresEstados.defaults;
    dynamic raw = s.valor;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return ColoresEstados.defaults;
      }
    }
    if (raw is! Map) return ColoresEstados.defaults;
    return ColoresEstados.fromJson(raw);
  }

  /// Valor del descuento pronto pago. 0 = deshabilitado.
  double get descuentoProntoPago =>
      settingValue<num>(_map, 'cuotas.descuento_pronto_pago', 0).toDouble();

  /// Tipo de descuento: 'porcentaje' o 'monto'.
  String get descuentoProntoPagoTipo =>
      settingValue<String>(_map, 'cuotas.descuento_pronto_pago_tipo', 'porcentaje');

  bool get auditVisibleAdminCobranza =>
      settingValue<bool>(_map, 'audit.visible_admin_cobranza', false);

  /// Override del super_admin de qué campos del change log (op_log) se muestran
  /// por operación (setting `op_log.campos_visibles`, map JSONB
  /// `{tipo_op: [campos]}`). Vacío = usar los defaults del catálogo. Lo consume
  /// el render (`HistorialOpLog`) y el panel (`OpLogCamposScreen`).
  Map<String, List<String>> get opLogCamposOverride {
    final s = _map?['op_log.campos_visibles'];
    if (s == null) return const {};
    dynamic raw = s.valor;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return const {};
      }
    }
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    raw.forEach((k, v) {
      if (k is String && v is List) out[k] = v.whereType<String>().toList();
    });
    return out;
  }

  int get formatoReciboMm =>
      settingValue<num>(_map, 'recibo.formato_default_mm', 80).toInt();
  String get pieRecibo => settingValue<String>(_map, 'recibo.pie_libre', '');

  String get empresaNombre => settingValue<String>(_map, 'empresa.nombre', '');
  String get empresaDireccion =>
      settingValue<String>(_map, 'empresa.direccion', '');
  String get empresaTelefono =>
      settingValue<String>(_map, 'empresa.telefono', '');
  String get empresaRuc => settingValue<String>(_map, 'empresa.ruc', '');

  /// Path del logo en Storage (bucket `logos-empresa`). Vacío si no hay logo.
  String get empresaLogoPath =>
      settingValue<String>(_map, 'empresa.logo_path', '');

  /// VERSIÓN del logo = `updated_at` de la fila `empresa.logo_path`.
  ///
  /// El path es siempre `{tenant}/logo.png` (ver `LogoEmpresaService`), así que
  /// NO cambia cuando el admin sube un logo nuevo — el archivo se pisa en la
  /// misma ruta. Lo que sí cambia es `updated_at`, porque `SettingsRepo.update`
  /// lo reescribe en cada llamada. Por eso el cache del logo se versiona con
  /// ESTE campo y no con el path: sin él, un logo nuevo nunca se bajaría.
  String get empresaLogoVersion => _map?['empresa.logo_path']?.updatedAt ?? '';

  /// Título del documento en el recibo (ej: "COBRO", "RECIBO").
  String get reciboTitulo =>
      settingValue<String>(_map, 'recibo.titulo', 'RECIBO');

  /// Mostrar tabla de meses adeudados en el recibo.
  bool get reciboMostrarAdeudado =>
      settingValue<bool>(_map, 'recibo.mostrar_adeudado', true);

  /// Mostrar WhatsApp de la empresa en el recibo.
  String get empresaWhatsapp =>
      settingValue<String>(_map, 'empresa.whatsapp', '');

  /// Mostrar la cédula del cliente en el recibo (#8b).
  bool get reciboMostrarCedula =>
      settingValue<bool>(_map, 'recibo.mostrar_cedula', true);

  /// Mostrar el CÓDIGO (ID simbólico) del cliente en el recibo. Default true
  /// (pedido de Rubén 2026-07-10). Sub-toggle del bloque `cliente`.
  bool get reciboMostrarCodigo =>
      settingValue<bool>(_map, 'recibo.mostrar_codigo', true);

  /// Mostrar la HORA del cobro en el recibo. Default FALSE (el template pedido
  /// no la muestra, y los cobros históricos cargados por el super_admin salen
  /// 00:00). Toggleable — sub-toggle de `meta`.
  bool get reciboMostrarHora =>
      settingValue<bool>(_map, 'recibo.mostrar_hora', false);

  /// Modos de impresión DISPONIBLES para el tenant (config del super_admin).
  /// `imagen` = raster de toda la hoja (fidelidad perfecta, pero pesado);
  /// `compatible` = texto nativo ESC/POS + codepage español (liviano, para
  /// impresoras baratas que dan basura/caracteres chinos). Imagen es el DEFAULT y
  /// no se puede quitar; Compatible arranca deshabilitado. Si ambos están
  /// habilitados, el cobrador elige por-dispositivo (config de impresora del
  /// celular); si solo uno, se usa ese.
  bool get modoImagenHabilitado =>
      settingValue<bool>(_map, 'recibo.modo_imagen_habilitado', true);
  bool get modoCompatibleHabilitado =>
      settingValue<bool>(_map, 'recibo.modo_compatible_habilitado', false);

  /// Desglose de descuentos/cargos de la cuota en el recibo (rediseño
  /// 2026-06-11): línea por cada cargo_extra vigente, dentro del bloque
  /// `cuota`. Sub-toggle del bloque en el diseñador de recibo.
  bool get reciboMostrarDescuentos =>
      settingValue<bool>(_map, 'recibo.mostrar_descuentos', true);

  /// Mostrar el MOTIVO en cada línea de descuento/cargo del recibo (apagado
  /// queda solo la etiqueta: Ajuste / Promo / Descuento / Cargo).
  bool get reciboMostrarMotivoDescuentos =>
      settingValue<bool>(_map, 'recibo.mostrar_motivo_descuentos', true);

  /// Layout configurable del recibo (rework "diseñador de recibo"): lista
  /// ORDENADA de bloques, cada uno con visibilidad + tamaño de letra. Default =
  /// orden del catálogo, todo visible, normal. Parseo robusto: ver
  /// `ReciboLayout.fromRaw` (sanea ids desconocidos, completa faltantes, fuerza
  /// visible en los totales).
  List<ReciboBloque> get reciboLayout =>
      ReciboLayout.fromRaw(_map?['recibo.layout']?.valor, semillasCampos: {
        // Semillas de migración: los sub-toggles viejos siembran la visibilidad
        // del campo equivalente SOLO en layouts legacy (sin `campos`). Una vez
        // que el admin edita el layout, `campos` persiste y esto queda inerte.
        'meta.hora': reciboMostrarHora,
        'cliente.id': reciboMostrarCodigo,
        'cliente.cedula': reciboMostrarCedula,
      });

  /// Tickets (Fase 3) — SLA de respuesta por PRIORIDAD, en horas (setting
  /// `tickets.sla_horas_por_prioridad`, map JSONB `{urgente, alta, media, baja}`).
  /// El SLA EFECTIVO de un ticket es el MENOR entre esto y el SLA del tipo (ver
  /// `slaHorasEfectivas`). Sólo se devuelven niveles con valor > 0 — un nivel en
  /// 0/ausente significa "sin SLA por prioridad" → cae al del tipo. Si el setting
  /// NO existe, default razonable out-of-the-box (urgente 1h … baja 12h).
  Map<String, int> get slaHorasPorPrioridad {
    const def = {'urgente': 1, 'alta': 2, 'media': 6, 'baja': 12};
    final s = _map?['tickets.sla_horas_por_prioridad'];
    if (s == null) return def;
    dynamic raw = s.valor;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return def;
      }
    }
    if (raw is! Map) return def;
    final result = <String, int>{};
    raw.forEach((k, v) {
      if (k is String && v is num && v > 0) result[k] = v.toInt();
    });
    return result;
  }

  /// Tickets — días para auto-cerrar un ticket 'resuelto' sin reapertura (setting
  /// `tickets.auto_cierre_dias`). 0 = desactivado (default). El cron diario (0109)
  /// lo lee server-side; este getter alimenta el editor en la pantalla de Tipos.
  int get autoCierreDias =>
      settingValue<num>(_map, 'tickets.auto_cierre_dias', 0).toInt();

  /// Tickets — intentos de contacto necesarios para habilitar el cierre SIN
  /// confirmación del cliente (setting `tickets.cierre_intentos_min`, 0208).
  ///
  /// El call center cierra la orden recién cuando el cliente confirma que
  /// quedó bien. Si no lo ubica, tras estos intentos puede cerrarla igual
  /// dejando el motivo por escrito. Default 3.
  int get cierreIntentosMin =>
      settingValue<num>(_map, 'tickets.cierre_intentos_min', 3).toInt();

  /// Tickets — días que deben pasar desde que se resolvió antes de poder
  /// cerrar sin confirmar (setting `tickets.cierre_dias_min`, 0208).
  ///
  /// Va junto con los intentos para que no se pueda cerrar a ciegas llamando
  /// tres veces en el mismo minuto. Default 2.
  int get cierreDiasMin =>
      settingValue<num>(_map, 'tickets.cierre_dias_min', 2).toInt();

}

final appSettingsProvider = Provider<AppSettings>((ref) {
  final map = ref.watch(settingsMapProvider).valueOrNull;
  return AppSettings(map);
});

/// ¿El usuario actual puede usar el cambio de fecha de pago por días? Espeja la
/// RLS server `puede_cambiar_fecha_pago()`: feature ON para el tenant + (rol
/// admin O permiso por usuario). Para mostrar/ocultar el botón "Cambiar fecha".
/// (El bloqueo por impersonación se evalúa aparte en la acción, como el cobro.)
final puedeCambiarFechaPagoProvider = Provider<bool>((ref) {
  if (!ref.watch(appSettingsProvider).cambioFechaHabilitado) return false;
  final c = ref.watch(cobradorActualProvider).valueOrNull;
  if (c == null) return false;
  // `lectura` (0198) nunca, aunque conserve el flag `puede_cambiar_fecha` de un
  // rol anterior: ni `set_cobrador_rol` ni el form lo limpian al migrar (solo
  // limpian el prefijo de recibo).
  if (c.esLectura) return false;
  return c.esAdmin || c.puedeCambiarFecha;
});

/// Habilitación para suspender / reactivar contratos: admin / admin_cobranza /
/// admin_usuarios (gestión del tenant). Sin feature-flag por tenant ni permiso
/// por usuario — es una operación de administración, no de campo. (El bloqueo
/// por impersonación se evalúa aparte en la acción.)
final puedeSuspenderProvider = Provider<bool>((ref) {
  final c = ref.watch(cobradorActualProvider).valueOrNull;
  if (c == null) return false;
  return c.esAdmin || c.esAdminCobranza || c.esAdminUsuarios;
});

/// ¿El usuario actual puede cambiar el plan de un contrato? Feature ON para el
/// tenant (toggle super_admin, 0151) + solo rol admin (NO admin_cobranza ni
/// cobrador — Fase 2 roles: admin_cobranza no gestiona planes/precios).
/// (El bloqueo por impersonación se evalúa aparte en la acción, como el cobro.)
final puedeCambiarPlanProvider = Provider<bool>((ref) {
  if (!ref.watch(appSettingsProvider).cambioPlanHabilitado) return false;
  final c = ref.watch(cobradorActualProvider).valueOrNull;
  if (c == null) return false;
  return c.esAdmin;
});

/// ¿El usuario gestiona el ESTADO de un contrato (suspender / reactivar /
/// cancelar), sea ejecutándolo o pidiéndolo?
///
/// Es el gate de VISIBILIDAD, separado de quién puede ejecutar sin permiso.
/// Hace falta porque al pasar la bifurcación de rol a acción, las ramas de
/// "Solicitar…" quedaron sin ningún gate de rol: como `requiereAprobacionPara`
/// devuelve true para todo el que no sea admin, el botón se le apareció al
/// cobrador, al técnico y hasta al rol `lectura` —que además generaría una
/// solicitud fantasma que el server rechaza (audit 2026-08-09).
final puedeGestionarEstadoContratoProvider = Provider<bool>((ref) {
  final c = ref.watch(cobradorActualProvider).valueOrNull;
  if (c == null || c.esLectura) return false;
  return c.esAdmin || c.esAdminCobranza || c.esAdminUsuarios || c.esSuperAdmin;
});

/// ¿El usuario VE la opción de cambiar de plan? (ejecutarla o pedirla).
///
/// Se separó de [puedeCambiarPlanProvider] —que sigue significando "lo ejecuta
/// sin permiso"— porque el rol dejó de decidir la VISIBILIDAD: el que no puede
/// ejecutarlo ahora lo PIDE. Antes el `admin_cobranza` ni siquiera lo veía, y
/// terminaba cancelando el contrato y creando otro: así se hacen hoy 3 de cada
/// 4 "cancelaciones" de la base (45 de 61 tienen un contrato hermano con plan
/// distinto), perdiendo el historial en cada una.
///
/// `lectura`, `cobrador` y `tecnico` quedan afuera: no gestionan el contrato.
final puedeVerCambiarPlanProvider = Provider<bool>((ref) {
  if (!ref.watch(appSettingsProvider).cambioPlanHabilitado) return false;
  final c = ref.watch(cobradorActualProvider).valueOrNull;
  if (c == null || c.esLectura) return false;
  return c.esAdmin || c.esAdminCobranza || c.esSuperAdmin;
});
