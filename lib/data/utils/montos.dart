import 'package:flutter/services.dart';

/// Parseo TOLERANTE de montos tipeados (fix M8 del audit 2026-06-11): en
/// teclados Android con locale español la tecla decimal emite ','; el
/// formatter viejo `[0-9.]` la DESCARTABA en silencio y "500,50" se volvía
/// "50050" (monto_original inflado, vuelto gigante). Acepta coma o punto
/// como separador decimal (uno solo) y rechaza todo lo demás.
/// [maxDecimales] = dígitos permitidos tras el separador. Default 2 (DINERO):
/// rechaza "1.500" porque es AMBIGUO con separador de miles (daba 1.5, un monto
/// 1000× menor, sin error — en campos sin piso creaba un cargo de C$1.50 en vez
/// de C$1500, audit 2026-06-30). Para TASAS/factores (que NO se tipean con miles
/// y el BCN publica a 4 decimales) el caller pasa un límite mayor.
double? parseMonto(String? s, {int maxDecimales = 2}) {
  if (s == null) return null;
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty || '.'.allMatches(t).length > 1) return null;
  final punto = t.indexOf('.');
  if (punto != -1 && t.length - punto - 1 > maxDecimales) return null;
  return double.tryParse(t);
}

/// Formatter estándar para campos de monto: dígitos y separador (. o ,).
/// SIEMPRE en pareja con [parseMonto] (que normaliza y valida).
final montoInputFormatter =
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));
