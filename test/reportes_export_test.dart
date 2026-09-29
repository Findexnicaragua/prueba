import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:isp_billing/data/models/prestamos_models.dart';
import 'package:isp_billing/features/admin/reportes/estados_financieros_export.dart';

void main() {
  group('Estados Financieros Export Tests', () {
    const testCartera = ResumenCartera(
      clientesCount: 15,
      prestamosCount: 20,
      activosCount: 12,
      activosMonto: 150000.0,
      moraVigenteCount: 3,
      moraVigenteMonto: 25000.0,
      porVencerCount: 2,
      porVencerMonto: 15000.0,
      moraVencidaCount: 1,
      moraVencidaMonto: 5000.0,
      pagadosCount: 4,
      pagadosMonto: 40000.0,
      enMoraCount: 4,
      enMoraMonto: 30000.0,
    );

    const testCaja = EstadoCaja(
      cajaInicial: 20000.0,
      capitalAportado: 200000.0,
      ingresosNetos: 35000.0,
      egresos: 5000.0,
      cajaActual: 50000.0,
      cajaPrestamos: 25000.0,
      bancos: 80000.0,
      gastosDiarios: 2000.0,
      capitalRecuperado: 40000.0,
      interesesCobrados: 12000.0,
      proyeccionInteres: 3000.0,
      interesesAcumulados: 15000.0,
    );

    test('generates valid Excel bytes', () {
      final bytes = construirEstadosFinancierosExcelBytes(
        cartera: testCartera,
        caja: testCaja,
        empresaNombre: 'Findex Nicaragua',
      );

      expect(bytes, isNotEmpty);
      final excel = Excel.decodeBytes(bytes);
      expect(excel.tables.containsKey('Estados Financieros'), isTrue);
      final sheet = excel.tables['Estados Financieros']!;
      expect(sheet.maxRows, greaterThan(15));
    });

    test('generates valid Word docx OpenXML bytes', () {
      final bytes = construirEstadosFinancierosDocxBytes(
        cartera: testCartera,
        caja: testCaja,
        empresaNombre: 'Findex Nicaragua',
      );

      expect(bytes, isNotEmpty);
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.findFile('[Content_Types].xml'), isNotNull);
      expect(archive.findFile('word/document.xml'), isNotNull);
      expect(archive.findFile('word/styles.xml'), isNotNull);
      expect(archive.findFile('_rels/.rels'), isNotNull);

      final docXml = String.fromCharCodes(archive.findFile('word/document.xml')!.content as List<int>);
      expect(docXml, contains('ESTADOS FINANCIEROS'));
      expect(docXml, contains('FINDEX NICARAGUA'));
      expect(docXml, contains('Balance General'));
    });
  });
}
