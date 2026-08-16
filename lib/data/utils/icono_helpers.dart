import 'package:flutter/material.dart';

/// Catálogo de iconos seleccionables para las etiquetas de clientes (P5).
///
/// `IconData` NO es serializable, así que se persiste la CLAVE (string) en
/// `etiquetas.icono` y se resuelve a `IconData` con [iconoEtiqueta]. El orden
/// del map = orden de presentación en el picker.
const Map<String, IconData> kIconosEtiqueta = {
  'estrella': Icons.star,
  'bandera': Icons.flag,
  'corazon': Icons.favorite,
  'rayo': Icons.bolt,
  'reloj': Icons.schedule,
  'apreton': Icons.handshake,
  'pulgar_arriba': Icons.thumb_up,
  'pulgar_abajo': Icons.thumb_down,
  'dinero': Icons.attach_money,
  'moneda': Icons.payments,
  'alerta': Icons.warning_amber,
  'verificado': Icons.verified,
  'bloqueado': Icons.block,
  'persona': Icons.person,
  'grupo': Icons.groups,
  'casa': Icons.home,
  'telefono': Icons.phone,
  'ubicacion': Icons.location_on,
  'montana': Icons.terrain,
  'wifi': Icons.wifi,
  'herramienta': Icons.build,
  'llave': Icons.key,
  'candado': Icons.lock,
  'escudo': Icons.shield,
  'campana': Icons.notifications,
  'fuego': Icons.local_fire_department,
  'subida': Icons.trending_up,
  'bajada': Icons.trending_down,
};

/// Icono por defecto cuando la clave es desconocida/null (etiqueta genérica).
const IconData kIconoEtiquetaDefault = Icons.label;

/// Lista ordenada de claves para el grid del picker.
const List<String> kIconosEtiquetaKeys = [
  'estrella', 'bandera', 'corazon', 'rayo', 'reloj', 'apreton',
  'pulgar_arriba', 'pulgar_abajo', 'dinero', 'moneda', 'alerta', 'verificado',
  'bloqueado', 'persona', 'grupo', 'casa', 'telefono', 'ubicacion',
  'montana', 'wifi', 'herramienta', 'llave', 'candado', 'escudo',
  'campana', 'fuego', 'subida', 'bajada',
];

/// Resuelve la clave persistida a su `IconData`. Fallback al genérico.
IconData iconoEtiqueta(String? key) =>
    key == null ? kIconoEtiquetaDefault : (kIconosEtiqueta[key] ?? kIconoEtiquetaDefault);
