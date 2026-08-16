/// Convierte un monto numérico a texto en español (convenciones nicaragüenses)
/// para uso en recibos de cobranza.
///
/// Ejemplos:
/// ```dart
/// montoALetras(1282.50)          // "UN MIL DOSCIENTOS OCHENTA Y DOS CÓRDOBAS CON 50/100"
/// montoALetras(100, moneda: 'USD') // "CIEN DÓLARES CON 00/100"
/// ```
///
/// Rango soportado: 0 – 999,999.99.
/// Cualquier valor fuera de rango lanza [ArgumentError].
String montoALetras(double monto, {String moneda = 'NIO'}) {
  if (monto < 0 || monto >= 1000000) {
    throw ArgumentError.value(
      monto,
      'monto',
      'Debe estar entre 0 y 999,999.99',
    );
  }

  // Separar parte entera y centavos. Redondeo a 2 decimales para evitar
  // artifacts de punto flotante (ej. 500.50 → 500 + 50, no 500 + 49).
  final centavos = (monto * 100).round() % 100;
  final entero = (monto * 100).round() ~/ 100;

  final textoEntero = _enteroALetras(entero);
  final textoCentavos = centavos.toString().padLeft(2, '0');

  final (singular, plural) = _nombreMoneda(moneda);
  final nombreMoneda = entero == 1 ? singular : plural;

  return '$textoEntero $nombreMoneda CON $textoCentavos/100';
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

(String singular, String plural) _nombreMoneda(String moneda) {
  switch (moneda.toUpperCase()) {
    case 'USD':
      return ('DÓLAR', 'DÓLARES');
    case 'NIO':
    default:
      return ('CÓRDOBA', 'CÓRDOBAS');
  }
}

const _unidades = [
  '', 'UN', 'DOS', 'TRES', 'CUATRO',
  'CINCO', 'SEIS', 'SIETE', 'OCHO', 'NUEVE',
  'DIEZ', 'ONCE', 'DOCE', 'TRECE', 'CATORCE',
  'QUINCE', 'DIECISÉIS', 'DIECISIETE', 'DIECIOCHO', 'DIECINUEVE',
  'VEINTE',
];

const _decenas = [
  '', '', 'VEINTI', 'TREINTA', 'CUARENTA',
  'CINCUENTA', 'SESENTA', 'SETENTA', 'OCHENTA', 'NOVENTA',
];

const _centenas = [
  '', 'CIENTO', 'DOSCIENTOS', 'TRESCIENTOS', 'CUATROCIENTOS',
  'QUINIENTOS', 'SEISCIENTOS', 'SETECIENTOS', 'OCHOCIENTOS', 'NOVECIENTOS',
];

/// Convierte un entero 0–999,999 a texto en español (uppercase).
String _enteroALetras(int n) {
  if (n == 0) return 'CERO';
  if (n < 0 || n > 999999) {
    throw ArgumentError.value(n, 'n', 'Fuera de rango 0–999,999');
  }

  final miles = n ~/ 1000;
  final resto = n % 1000;

  final partes = <String>[];

  if (miles > 0) {
    if (miles == 1) {
      // Convención nicaragüense: "UN MIL", no solo "MIL".
      partes.add('UN MIL');
    } else {
      partes.add('${_centenasALetras(miles)} MIL');
    }
  }

  if (resto > 0) {
    partes.add(_centenasALetras(resto));
  }

  return partes.join(' ');
}

/// Convierte un entero 1–999 a texto.
String _centenasALetras(int n) {
  assert(n >= 1 && n <= 999, 'Rango esperado: 1–999, recibió $n');

  if (n == 100) return 'CIEN';

  final c = n ~/ 100;
  final resto = n % 100;

  final partes = <String>[];

  if (c > 0) {
    partes.add(_centenas[c]);
  }

  if (resto > 0) {
    partes.add(_decenasALetras(resto));
  }

  return partes.join(' ');
}

/// Convierte un entero 1–99 a texto.
String _decenasALetras(int n) {
  assert(n >= 1 && n <= 99, 'Rango esperado: 1–99, recibió $n');

  // 1–20: lookup directo.
  if (n <= 20) return _unidades[n];

  final d = n ~/ 10;
  final u = n % 10;

  // 21–29: forma contracta "VEINTI..." (ej. VEINTIÚN, VEINTITRÉS).
  if (d == 2) {
    if (u == 0) return 'VEINTE'; // ya cubierto por _unidades[20] arriba
    if (u == 1) return 'VEINTIÚN';
    return '${_decenas[2]}${_unidades[u]}';
  }

  // 30–99: "TREINTA", "TREINTA Y UN", "TREINTA Y DOS", etc.
  if (u == 0) return _decenas[d];
  return '${_decenas[d]} Y ${_unidades[u]}';
}
