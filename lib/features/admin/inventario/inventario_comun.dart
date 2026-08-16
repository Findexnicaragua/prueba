import 'package:flutter/material.dart';

import '../../shared/widgets/filtro_multi_dropdown.dart';

/// Helpers compartidos del estado del serial de inventario (`inv_seriales`),
/// reusados por la lista (`inventario_v2_screen.dart`) y la ficha
/// (`ficha_equipo_screen.dart`) — fuente única de labels/colores/opciones del
/// estado, para no duplicarlos por tercera vez.

/// Labels humanos del estado del serial.
///
/// `baja` se MUESTRA como "Descarte" (0204): el valor en DB no cambió — hay
/// data viva con 'baja' y renombrarlo obligaría a migrar filas y a tocar los
/// 61 usos del literal. El ciclo del material que pidió el nuevo dueño habla
/// de "descarte", así que el cambio es de vocabulario, no de estado.
const kEstadoSerial = {
  'en_stock': 'En stock',
  'instalado': 'Instalado',
  'en_revision': 'En revisión',
  'danado': 'Dañado',
  'retirado': 'Retirado',
  'baja': 'Descarte',
};

/// Opciones del filtro de estado, en el orden del ciclo de vida.
const kEstadoSerialOpciones = [
  FiltroOpcion(id: 'en_stock', label: 'En stock'),
  FiltroOpcion(id: 'instalado', label: 'Instalado'),
  FiltroOpcion(id: 'en_revision', label: 'En revisión'),
  FiltroOpcion(id: 'danado', label: 'Dañado'),
  FiltroOpcion(id: 'retirado', label: 'Retirado'),
  FiltroOpcion(id: 'baja', label: 'Descarte'),
];

/// Color semántico del estado del serial (verde/azul/violeta/ámbar/gris/rojo).
Color estadoSerialColor(String estado, ColorScheme s) {
  switch (estado) {
    case 'en_stock':
      return const Color(0xFF1D9E75); // verde
    case 'instalado':
      return const Color(0xFF2563EB); // azul
    case 'en_revision':
      return const Color(0xFF7C3AED); // violeta — esperando decisión
    case 'danado':
      return const Color(0xFFD97706); // ámbar
    case 'baja':
      return s.error; // rojo
    case 'retirado':
    default:
      return s.outline; // gris
  }
}
