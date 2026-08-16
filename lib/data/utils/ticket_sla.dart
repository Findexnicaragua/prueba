import 'package:flutter/material.dart';

/// Helpers de tickets (Fase 3): SLA derivado en el cliente, código legible,
/// transiciones válidas y labels/colores. Sin model class: las pantallas usan
/// `Map<String, dynamic>` de `ps.db.watch` (mismo patrón que inventario).

/// Estado del SLA, DERIVADO en el cliente (no se persiste). El SLA EFECTIVO es el
/// MENOR entre el del TIPO (`ticket_tipos.sla_horas`) y el de la PRIORIDAD (setting
/// `tickets.sla_horas_por_prioridad`), resuelto con [slaHorasEfectivas] — el caller
/// pasa ese número ya combinado en `slaHoras`. Plazo = created_at + sla_horas +
/// segundos_pausado. Mientras el ticket está `en_espera` el SLA se considera
/// PAUSADO (no vence); resuelto/cerrado/cancelado lo cierran.
///
/// PAUSA EXACTA (migración 0105): el trigger server-side acumula en
/// `tickets.segundos_pausado` TODO el tiempo que el ticket estuvo en `en_espera`
/// (usando el device-time `ocurrido_en` de cada transición → offline-safe). Acá
/// lo sumamos al plazo. Offline mid-pausa: el cliente recién ve el `segundos_pausado`
/// actualizado al sincronizar (el trigger es server-side); hasta entonces el plazo
/// queda levemente conservador (más urgente, nunca oculta un vencimiento).
enum SlaEstado { sinSla, enPlazo, porVencer, vencido, pausado, cerrado }

const _estadosCerrados = {'resuelto', 'cerrado', 'cancelado'};

SlaEstado ticketSlaEstado({
  required String estado,
  required DateTime createdAt,
  int? slaHoras, // SLA EFECTIVO (ver [slaHorasEfectivas])
  String? prioridad, // ajusta el lead-time del "por vencer"
  int segundosPausado = 0, // tiempo acumulado en en_espera (no consume SLA)
  DateTime? ahora,
}) {
  if (_estadosCerrados.contains(estado)) return SlaEstado.cerrado;
  if (slaHoras == null || slaHoras <= 0) return SlaEstado.sinSla;
  if (estado == 'en_espera') return SlaEstado.pausado;
  final now = ahora ?? DateTime.now();
  // El plazo se corre por todo el tiempo que el ticket estuvo en espera.
  final deadline = createdAt
      .add(Duration(hours: slaHoras))
      .add(Duration(seconds: segundosPausado));
  if (now.isAfter(deadline)) return SlaEstado.vencido;
  // Por vencer: dentro del último 20% del plazo. El PISO del lead-time depende de
  // la prioridad — urgente/alta avisan con 15 min (no se puede dar 1h de aviso en
  // un SLA de 1h); media/baja con 1h. NUNCA más del 50% del plazo (techo) — sin
  // él un SLA corto (1-5h) nacería directo en "por vencer".
  final restante = deadline.difference(now);
  final minutosSla = slaHoras * 60;
  var umbralMin = (minutosSla * 0.2).round();
  final piso = (prioridad == 'urgente' || prioridad == 'alta') ? 15 : 60;
  if (umbralMin < piso) umbralMin = piso;
  final techo = (minutosSla * 0.5).round();
  if (umbralMin > techo) umbralMin = techo; // techo 50% del SLA
  if (restante <= Duration(minutes: umbralMin)) {
    return SlaEstado.porVencer;
  }
  return SlaEstado.enPlazo;
}

/// SLA EFECTIVO en horas = el MENOR entre el SLA del tipo y el de la prioridad,
/// ignorando nulos y no-positivos (modelo híbrido "la restricción más urgente
/// gana"). Devuelve null cuando ninguno aplica → el ticket no tiene SLA.
///   - ambos null/≤0 → null (sin SLA)
///   - sólo uno seteado → ese
///   - ambos seteados → min(a, b)
int? slaHorasEfectivas(int? tipoSla, int? prioridadSla) {
  final vals = [tipoSla, prioridadSla].whereType<int>().where((h) => h > 0);
  return vals.isEmpty ? null : vals.reduce((a, b) => a < b ? a : b);
}

/// Parsea el `created_at` de un ticket interpretando sus COMPONENTES como
/// wall-clock local del dispositivo (Nicaragua, UTC-6 sin DST), descartando
/// cualquier flag UTC del string.
///
/// POR QUÉ: el cliente escribe `created_at` device-local SIN offset (patrón
/// `fecha_pago`). Pre-sync el string local es naive ("14:00") y parsea local —
/// correcto. POST-sync, Postgres (sesión UTC) interpretó ese naive como UTC y
/// PowerSync lo baja como "14:00Z": el INSTANTE quedó corrido 6h, pero el
/// WALL-CLOCK ("14:00") se preserva en los componentes. Un `DateTime.parse`
/// crudo tomaría el instante corrido y el SLA vencería 6h antes; reconstruir
/// desde componentes como hora local da el instante real en AMBOS formatos.
DateTime parseTicketWallClock(String iso) {
  final dt = DateTime.parse(iso);
  return DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
      dt.millisecond, dt.microsecond);
}

/// Tiempo restante hasta el vencimiento del SLA. Positivo = falta; negativo =
/// vencido hace |x|. Devuelve null cuando NO hay cuenta regresiva viva (sin SLA /
/// en espera / cerrado). `slaHoras` debe ser el EFECTIVO ([slaHorasEfectivas]).
///
/// Es matemática pura sobre data local (`DateTime.now()` + la fila del ticket):
/// TICKEA OFFLINE sin tocar la red. El `segundosPausado` es server-computed; off-
/// line mid-pausa queda levemente conservador (más urgente, nunca oculta vencido).
/// `createdAt` DEBE venir de [parseTicketWallClock] (ver su doc): un
/// `DateTime.parse` crudo del valor post-sync corre el deadline ~6h.
Duration? ticketSlaRestante({
  required String estado,
  required DateTime createdAt,
  int? slaHoras,
  int segundosPausado = 0,
  DateTime? ahora,
}) {
  if (_estadosCerrados.contains(estado)) return null;
  if (slaHoras == null || slaHoras <= 0) return null;
  if (estado == 'en_espera') return null; // pausado → no hay cuenta regresiva
  final deadline = createdAt
      .add(Duration(hours: slaHoras))
      .add(Duration(seconds: segundosPausado));
  return deadline.difference(ahora ?? DateTime.now());
}

/// Formato legible del restante. `compact` (listas, donde el ancho importa) omite
/// "restantes"/"hace" — el color del chip ya comunica el estado:
///   compact=false: "2h 15m restantes" · "vencido hace 2d 3h"
///   compact=true:  "2h 15m"           · "vencido 2d 3h"
/// Rolea a días arriba de 24h (acota el ancho y se lee más rápido que "50h").
String formatSlaRestante(Duration d, {bool compact = false}) {
  final vencido = d.isNegative;
  final a = d.abs();
  final dias = a.inDays;
  final h = a.inHours.remainder(24);
  final m = a.inMinutes.remainder(60);
  final String cuerpo;
  if (dias > 0) {
    cuerpo = '${dias}d ${h}h';
  } else if (h > 0) {
    cuerpo = '${h}h ${m}m';
  } else {
    cuerpo = '${m}m';
  }
  if (compact) return vencido ? 'vencido $cuerpo' : cuerpo;
  return vencido ? 'vencido hace $cuerpo' : '$cuerpo restantes';
}

String slaLabel(SlaEstado s) => switch (s) {
      SlaEstado.sinSla => 'Sin SLA',
      SlaEstado.enPlazo => 'En plazo',
      SlaEstado.porVencer => 'Por vencer',
      SlaEstado.vencido => 'Vencido',
      SlaEstado.pausado => 'En espera',
      SlaEstado.cerrado => 'Cerrado',
    };

// Semáforo del SLA: verde (en plazo) → ámbar (por vencer) → rojo (vencido).
// `c.tertiary` ES AppColors.success (verde, theme.dart); `c.primary` es el AZUL
// de marca, NO sirve para "ok". El ámbar espeja la convención "En gracia → ámbar"
// (Colors.amber.shade700) del resto de la app. Pausado va NEUTRO (gris): el reloj
// está congelado, nunca debe leerse como "ok".
Color slaColor(SlaEstado s, ColorScheme c) => switch (s) {
      SlaEstado.vencido => c.error,
      SlaEstado.porVencer => Colors.amber.shade700,
      SlaEstado.enPlazo => c.tertiary,
      SlaEstado.pausado => c.outline,
      SlaEstado.cerrado => c.outline,
      SlaEstado.sinSla => c.outline,
    };

/// Código legible del ticket: T-00001 (correlativo cliente-computado).
String ticketCodigo(num? correlativo) {
  if (correlativo == null || correlativo <= 0) return 'T-(s/n)';
  return 'T-${correlativo.toInt().toString().padLeft(5, '0')}';
}

// ── Estados del ticket ─────────────────────────────────────────────────────
String estadoTicketLabel(String e) => switch (e) {
      'abierto' => 'Abierto',
      'asignado' => 'Asignado',
      'en_progreso' => 'En progreso',
      'en_espera' => 'En espera',
      'resuelto' => 'Resuelto',
      'cerrado' => 'Cerrado',
      'reabierto' => 'Reabierto',
      'cancelado' => 'Cancelado',
      _ => e,
    };

Color estadoTicketColor(String e, ColorScheme c) => switch (e) {
      'abierto' => c.primary,
      // c.secondary es primary al 10% (relleno) → ilegible como texto. Indigo
      // legible y distinto de 'abierto'(primary) y 'en_progreso'(blue).
      'asignado' => Colors.indigo,
      'en_progreso' => Colors.blue,
      'en_espera' => c.tertiary,
      'resuelto' => Colors.green,
      'cerrado' => c.outline,
      'reabierto' => Colors.orange,
      'cancelado' => c.error,
      _ => c.outline,
    };

/// Transiciones de estado válidas (espeja el trigger server-side de 0103). La UI
/// solo ofrece estas; el server las re-valida ("server gana").
const Map<String, List<String>> kTransicionesTicket = {
  'abierto': ['asignado', 'en_progreso', 'cancelado'],
  'asignado': ['en_progreso', 'en_espera', 'abierto', 'cancelado'],
  'en_progreso': ['en_espera', 'resuelto', 'asignado', 'cancelado'],
  'en_espera': ['en_progreso', 'resuelto', 'cancelado'],
  'resuelto': ['cerrado', 'reabierto'],
  'reabierto': ['asignado', 'en_progreso', 'en_espera', 'resuelto', 'cancelado'],
  // Estados terminales: solo se pueden REABRIR (ticket cancelado/cerrado por
  // error). Espeja exactamente el trigger server-side de 0103/0105.
  'cerrado': ['reabierto'],
  'cancelado': ['reabierto'],
};

List<String> transicionesDesde(String estado) =>
    kTransicionesTicket[estado] ?? const [];

/// Estados a los que un TÉCNICO puede mover un ticket desde el campo (subconjunto
/// de [kTransicionesTicket]). El admin hace el resto: cerrar, cancelar, reabrir y
/// reasignar. "Server gana": el trigger 0103 igual valida la transición base, y
/// la RLS (`is_ticket_staff`) permite el UPDATE — esto sólo acota lo que la UI del
/// técnico OFRECE, para que el flujo de campo sea simple (avanzar / pausar / resolver).
const kEstadosDestinoTecnico = {'en_progreso', 'en_espera', 'resuelto'};

/// Transiciones que la UI del técnico ofrece desde [estado]: las válidas filtradas
/// a [kEstadosDestinoTecnico].
List<String> transicionesTecnico(String estado) =>
    transicionesDesde(estado).where(kEstadosDestinoTecnico.contains).toList();

// ── Prioridad ──────────────────────────────────────────────────────────────
const kTicketPrioridades = ['baja', 'media', 'alta', 'urgente'];

String prioridadLabel(String? p) => switch (p) {
      'baja' => 'Baja',
      'media' => 'Media',
      'alta' => 'Alta',
      'urgente' => 'Urgente',
      _ => '—',
    };

Color prioridadColor(String? p, ColorScheme c) => switch (p) {
      'urgente' => c.error,
      'alta' => Colors.orange,
      'media' => c.primary,
      'baja' => c.outline,
      _ => c.outline,
    };

// ── Eventos de la bitácora ─────────────────────────────────────────────────
String tipoEventoLabel(String t) => switch (t) {
      'creado' => 'Ticket creado',
      'asignado' => 'Asignado',
      'cambio_estado' => 'Cambio de estado',
      'comentario' => 'Comentario',
      'material' => 'Material',
      'adjunto' => 'Adjunto',
      'reabierto' => 'Reabierto',
      'cerrado' => 'Cerrado',
      'cancelado' => 'Cancelado',
      // 0208: sin este caso la bitácora mostraba el valor crudo 'contacto'.
      'contacto' => 'Intento de contacto',
      _ => t,
    };

IconData tipoEventoIcon(String t) => switch (t) {
      'creado' => Icons.add_circle_outline,
      'asignado' => Icons.person_pin_circle_outlined,
      'cambio_estado' => Icons.swap_horiz,
      'comentario' => Icons.chat_bubble_outline,
      'material' => Icons.inventory_2_outlined,
      'adjunto' => Icons.attach_file,
      'reabierto' => Icons.refresh,
      'cerrado' => Icons.check_circle_outline,
      'cancelado' => Icons.cancel_outlined,
      'contacto' => Icons.phone_missed,
      _ => Icons.circle,
    };
