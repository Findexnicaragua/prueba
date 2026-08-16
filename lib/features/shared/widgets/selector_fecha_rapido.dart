import 'package:flutter/material.dart';

/// Selector de fecha que APLICA AL TOCAR el día — sin botones OK/Cancelar.
///
/// El `showDatePicker` nativo de Material, en modo calendario, SIEMPRE dibuja
/// "Cancelar/OK": no es configurable. Los dueños pidieron que tocar el día lo
/// aplique de una (2026-07-31). Se reemplaza por un diálogo propio que envuelve
/// `CalendarDatePicker` y hace `Navigator.pop(fecha)` en su `onDateChanged`.
///
/// Contrato IGUAL a `showDatePicker` (mismos `initialDate`/`firstDate`/
/// `lastDate`, devuelve la fecha o `null` si se cierra sin elegir), así los
/// call-sites solo cambian el nombre de la función. `helpText` va arriba, como
/// en el nativo. Sin `cancelText`/`confirmText` porque ya no hay botones; para
/// cerrar sin elegir, el usuario toca fuera del diálogo (barrera).
Future<DateTime?> elegirFechaRapida(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
}) {
  // Clamp defensivo: CalendarDatePicker LANZA si initialDate cae fuera del
  // rango (mismo requisito que el nativo). Los call-sites ya suelen pasar algo
  // válido, pero el rango del selector de "Desde/Hasta" puede empujarlo afuera.
  DateTime ini = initialDate;
  if (ini.isBefore(firstDate)) ini = firstDate;
  if (ini.isAfter(lastDate)) ini = lastDate;

  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (helpText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Text(
                  helpText,
                  style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            CalendarDatePicker(
              initialDate: ini,
              firstDate: firstDate,
              lastDate: lastDate,
              // Arranca SIEMPRE en la grilla de días (no en año): así el primer
              // toque es un día y aplica. Navegar meses con las flechas usa
              // `onDisplayedMonthChanged`, no éste, así que no cierra.
              initialCalendarMode: DatePickerMode.day,
              // Cada toque de DÍA dispara esto → cerramos con la fecha elegida.
              // Quirk conocido y aceptado: si el usuario abre el desplegable de
              // AÑO y elige otro año, eso también dispara `onDateChanged` y
              // cierra con el mismo día en ese año. Es un toque deliberado extra
              // (el dropdown de año), raro en este negocio donde las fechas son
              // del período en curso; se reabre ya posicionado en el año nuevo.
              onDateChanged: (d) => Navigator.of(ctx).pop(d),
            ),
          ],
        ),
      ),
    ),
  );
}
