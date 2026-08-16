import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:isp_billing/features/admin/reportes/excel/reporte_excel.dart';

String? _texto(Sheet sheet, int col, int row) {
  final v = sheet
      .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
      .value;
  return v?.toString();
}

/// Valor numérico de una celda (Int o Double), o null si está vacía.
num? _num(Sheet sheet, int col, int row) {
  final v = sheet
      .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
      .value;
  if (v is IntCellValue) return v.value;
  if (v is DoubleCellValue) return v.value;
  return null;
}

void main() {
  setUpAll(() async {
    // Locale data de es_NI para Fmt.fechaCorta ("Generado: dd/MM/yyyy").
    await initializeDateFormatting('es_NI', null);
  });

  group('construirExcelBytes', () {
    test('sin branding: headers en fila 0 y datos desde fila 1 (layout '
        'histórico, lo consume quien no pasa empresaNombre)', () {
      final bytes = construirExcelBytes(
        hojaNombre: 'Cobros',
        headers: ['Cliente', 'Monto'],
        filas: [
          ['Juan', 100.5],
          ['Ana', 3],
        ],
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel['Cobros'];
      expect(_texto(sheet, 0, 0), 'Cliente');
      expect(_texto(sheet, 1, 0), 'Monto');
      expect(_texto(sheet, 0, 1), 'Juan');
      expect(_texto(sheet, 1, 1), '100.5');
      expect(_texto(sheet, 1, 2), '3');
    });

    test('con branding: empresa/título/período arriba, fila en blanco y '
        'tabla desde la fila 5', () {
      final bytes = construirExcelBytes(
        hojaNombre: 'Cobros',
        headers: ['Cliente', 'Monto'],
        filas: [
          ['Juan', 100.5],
        ],
        empresaNombre: 'Telecable Demo',
        titulo: 'Reporte de cobros',
        periodo: '01/06/2026 – 12/06/2026',
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel['Cobros'];
      expect(_texto(sheet, 0, 0), 'Telecable Demo');
      expect(_texto(sheet, 0, 1), 'Reporte de cobros');
      expect(_texto(sheet, 0, 2), contains('Período: 01/06/2026'));
      expect(_texto(sheet, 0, 2), contains('Generado:'));
      // Fila 3 en blanco.
      expect(_texto(sheet, 0, 3), isNull);
      // Tabla: headers en fila 4, datos en fila 5.
      expect(_texto(sheet, 0, 4), 'Cliente');
      expect(_texto(sheet, 1, 4), 'Monto');
      expect(_texto(sheet, 0, 5), 'Juan');
      expect(_texto(sheet, 1, 5), '100.5');
      // Sin merges: las celdas de branding desbordan naturalmente (un
      // título mergeado se recorta al ancho de la tabla en Excel).
      expect(sheet.spannedItems, isEmpty);
    });

    test('branding sin período usa solo la fecha de generación', () {
      final bytes = construirExcelBytes(
        hojaNombre: 'Clientes',
        headers: ['Nombre'],
        filas: [
          ['Ana'],
        ],
        empresaNombre: 'Telecable Demo',
        titulo: 'Listado de clientes',
      );

      final excel = Excel.decodeBytes(bytes);
      final sheet = excel['Clientes'];
      expect(_texto(sheet, 0, 2), startsWith('Generado:'));
      expect(sheet.spannedItems, isEmpty);
      expect(_texto(sheet, 0, 4), 'Nombre');
      expect(_texto(sheet, 0, 5), 'Ana');
    });
  });

  group('construirReporteCobranzaBytes (plantilla de cobranza)', () {
    test('layout + split de monedas (C\$/US\$) + 4 totales + fecha de cobro', () {
      final bytes = construirReporteCobranzaBytes(
        empresaNombre: 'Telecable Demo',
        fechaInicial: '01/06/2026',
        fechaFinal: '21/06/2026',
        rows: [
          {
            'cliente_codigo': 'M-01', 'cliente_nombre': 'María',
            'cobrador_nombre': 'Juan', 'cuota_periodo': '2026-06-01',
            'fecha_pago': '2026-06-03T14:32:00',
            'numero_recibo': 'A-1', 'moneda': 'NIO',
            'monto_original': 700, 'monto_cordobas': 700, 'vuelto_cordobas': 0,
          },
          {
            'cliente_codigo': 'M-02', 'cliente_nombre': 'Carlos',
            'cobrador_nombre': 'Ana', 'cuota_periodo': '2026-06',
            'fecha_pago': '2026-06-05', 'numero_recibo': 'B-9', 'moneda': 'USD',
            'monto_original': 10, 'monto_cordobas': 350, 'vuelto_cordobas': 18,
          },
        ],
      );
      final sheet = Excel.decodeBytes(bytes)['Cobranza'];

      // Banner + rango.
      expect(_texto(sheet, 0, 0), 'Telecable Demo');
      expect(_texto(sheet, 0, 1), 'Reporte de cobranza');
      expect(_texto(sheet, 0, 3), 'Fecha inicial:');
      expect(_texto(sheet, 1, 3), '01/06/2026');
      expect(_texto(sheet, 1, 4), '21/06/2026');

      // 4 totales (label col D=3, valor col I=8 — corrido por la columna nueva
      // "Fecha de cobro"): subtotal=700, divisa=350+18, total C$=1068, US$=10.
      expect(_texto(sheet, 3, 3), 'SUBTOTAL CÓRDOBAS');
      expect(_num(sheet, 8, 3), 700);
      expect(_texto(sheet, 3, 4), 'CAMBIO COMPRA DE DIVISAS');
      expect(_num(sheet, 8, 4), 368);
      expect(_texto(sheet, 3, 5), 'TOTAL CÓRDOBAS');
      expect(_num(sheet, 8, 5), 1068);
      expect(_texto(sheet, 3, 6), 'TOTAL DÓLARES');
      expect(_num(sheet, 8, 6), 10);

      // Headers de la tabla (fila 7): "Fecha de cobro" va entre "Mes" y "Recibo #".
      expect(_texto(sheet, 0, 7), 'ID');
      expect(_texto(sheet, 3, 7), 'Mes');
      expect(_texto(sheet, 4, 7), 'Fecha de cobro');
      expect(_texto(sheet, 5, 7), 'Recibo #');
      expect(_texto(sheet, 6, 7), 'Dólar');
      expect(_texto(sheet, 7, 7), 'Córdoba');
      expect(_texto(sheet, 8, 7), 'Compra de Divisas');

      // Fila NIO (8): solo "Córdoba"; mes 'Junio'; fecha de cobro 03/06/2026.
      expect(_texto(sheet, 0, 8), 'M-01');
      expect(_texto(sheet, 3, 8), 'Junio');
      expect(_texto(sheet, 4, 8), '03/06/2026');
      expect(_num(sheet, 7, 8), 700);
      expect(_num(sheet, 6, 8), isNull);
      expect(_num(sheet, 8, 8), isNull);

      // Fila USD (9): "Dólar" + "Compra de Divisas"; "Córdoba" vacío; mes 'Junio'
      // (periodo 'YYYY-MM' también parsea); fecha de cobro 05/06/2026 (sin hora).
      expect(_num(sheet, 6, 9), 10);
      expect(_num(sheet, 8, 9), 368);
      expect(_num(sheet, 7, 9), isNull);
      expect(_texto(sheet, 3, 9), 'Junio');
      expect(_texto(sheet, 4, 9), '05/06/2026');
    });

    test('rows vacío: genera el archivo con totales en 0', () {
      final bytes = construirReporteCobranzaBytes(
        empresaNombre: 'Demo',
        fechaInicial: '01/06/2026',
        fechaFinal: '21/06/2026',
        rows: const [],
      );
      final sheet = Excel.decodeBytes(bytes)['Cobranza'];
      expect(_num(sheet, 8, 3), 0);
      expect(_num(sheet, 8, 6), 0);
      expect(_texto(sheet, 0, 7), 'ID');
      expect(_texto(sheet, 4, 7), 'Fecha de cobro');
    });
  });
}
