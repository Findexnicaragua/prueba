import '../repositories/settings_repo.dart';
import 'validators.dart';

/// Pliega texto a una forma canónica para búsqueda: minúsculas + ñ y vocales
/// acentuadas a su base ASCII (ñ→n, á→a…). SQLite `lower()` es ASCII-only (NO
/// minusculiza Ñ ni acentos) y el form sube los códigos a MAYÚSCULA, así que sin
/// plegar, un código guardado 'JÑ0048' no matcheaba la query 'jñ0048' — los
/// clientes con ñ no aparecían en la búsqueda (bug 2026-06-22). Plegar ASCII
/// además hace la búsqueda tolerante a tipear con o sin ñ/tilde. Espeja a
/// [foldSqlExpr] para que SQL y Dart comparen la MISMA forma.
String foldBusqueda(String s) {
  var r = s.toLowerCase(); // Dart sí baja Ñ→ñ, Á→á (unicode).
  const map = {
    'ñ': 'n', 'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u',
  };
  map.forEach((k, v) => r = r.replaceAll(k, v));
  return r;
}

/// Expresión SQL (SQLite) que pliega una columna a la MISMA forma canónica que
/// [foldBusqueda]: `replace()` encadenado para ñ/acentos (ambos casos, porque
/// `replace` es case-sensitive y `lower()` no toca el no-ASCII) + `lower()` para
/// el resto. Uso: `${foldSqlExpr('c.codigo')} LIKE ?` con la query plegada por
/// [foldBusqueda]. `col` es siempre un literal controlado (sin input de usuario).
String foldSqlExpr(String col) {
  const map = {
    'Ñ': 'n', 'ñ': 'n', 'Á': 'a', 'á': 'a', 'É': 'e', 'é': 'e',
    'Í': 'i', 'í': 'i', 'Ó': 'o', 'ó': 'o', 'Ú': 'u', 'ú': 'u', 'Ü': 'u', 'ü': 'u',
  };
  var e = "coalesce($col,'')";
  map.forEach((k, v) => e = "replace($e,'$k','$v')");
  return 'lower($e)';
}

/// Parte la query en TOKENS plegados (uno por palabra). "María Peña" / "maria
/// pena" → `['maria','pena']`. Vacía si la query es solo espacios. Base de la
/// **búsqueda por tokens AND-en-cualquier-orden**: cada token debe matchear (así
/// "luisa ruiz" encuentra "María Luisa Peña Ruíz", y "maria ruiz" también).
List<String> tokensBusqueda(String queryRaw) {
  return queryRaw
      .trim()
      .split(RegExp(r'\s+'))
      .map(foldBusqueda)
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
}

/// Matcher client-side de UN texto contra la query por TOKENS: pliega ambos lados
/// (ñ/acentos → ASCII, regla #1d) y exige que TODOS los tokens estén presentes en
/// cualquier orden. Query vacía → true (no filtra). Es el reemplazo uniforme de
/// `foldBusqueda(x).contains(foldBusqueda(q))` en toda búsqueda/filtro de texto
/// libre (selectores, filtros, buscadores de pantalla).
bool coincideTokens(String target, String queryRaw) {
  final toks = tokensBusqueda(queryRaw);
  if (toks.isEmpty) return true;
  final t = foldBusqueda(target);
  return toks.every(t.contains);
}

/// Fragmento SQL (SQLite) de búsqueda por TOKENS sobre UNA columna de texto:
/// pliega la columna con [foldSqlExpr] y ANDea un `LIKE ?` por token (todos deben
/// matchear, cualquier orden). Devuelve `(sql, params)` para intercalar en un
/// WHERE; `sql: ''` si la query está vacía. Espeja [coincideTokens] en SQL.
({String sql, List<Object?> params}) foldSqlTokens(String col, String queryRaw) {
  final toks = tokensBusqueda(queryRaw);
  if (toks.isEmpty) return (sql: '', params: const []);
  final expr = foldSqlExpr(col);
  final clauses = <String>[];
  final params = <Object?>[];
  for (final t in toks) {
    clauses.add('$expr LIKE ?');
    params.add('%$t%');
  }
  return (sql: '(${clauses.join(' AND ')})', params: params);
}

/// Placeholder DINÁMICO para las barras de búsqueda de clientes: lista solo los
/// campos HABILITADOS por los toggles del settings panel (el nombre siempre
/// entra), para que el hint sea consistente con lo que REALMENTE se busca. Si el
/// tenant apaga "teléfono", no aparece "teléfono" en el placeholder. Usar en
/// toda barra gobernada por [busquedaClienteSql]/[busquedaClienteMatch].
String placeholderBusqueda(AppSettings settings) {
  final campos = <String>['nombre'];
  if (settings.busquedaPorCodigo) campos.add('código');
  if (settings.busquedaPorCedula) campos.add('cédula');
  if (settings.busquedaPorTelefono) campos.add('teléfono');
  if (settings.busquedaPorContrato) campos.add('contrato');
  final String lista;
  if (campos.length == 1) {
    lista = campos.first;
  } else {
    lista = '${campos.sublist(0, campos.length - 1).join(', ')} o ${campos.last}';
  }
  return 'Buscar por $lista';
}

/// Helper COMPARTIDO de búsqueda de cliente por texto. Arma el fragmento WHERE
/// (SQLite) respetando qué campos están habilitados en [settings] (toggles
/// super_admin, Avanzado). El NOMBRE siempre entra; código de cliente, cédula,
/// teléfono y código de CONTRATO son toggleables.
///
/// - **Teléfono**: usa el strip a dígitos (`sanitizePhoneForWhatsApp`) para
///   matchear números guardados sin guiones. Se apaga para evitar falsos
///   positivos (buscar "003" traía todo cliente con 003 en el número).
/// - **Código de contrato**: encuentra al cliente (padre) por el código de
///   CUALQUIERA de sus contratos (hijos) — herencia padre-hijo.
///
/// Devuelve `(sql: '(... OR ...)', params: [...])` para intercalar en un WHERE:
/// `where.add(b.sql); params.addAll(b.params);`. Si [queryRaw] está vacío
/// devuelve `sql: ''`, `params: []`. [alias] = alias de la tabla `clientes`.
/// SQLite-válido (solo `LIKE ?` con placeholders, sin Postgres-only).
({String sql, List<Object?> params}) busquedaClienteSql(
  String queryRaw,
  AppSettings settings, {
  String alias = 'c',
}) {
  final tokens = tokensBusqueda(queryRaw);
  if (tokens.isEmpty) return (sql: '', params: const []);

  // Búsqueda por TOKENS: cada token debe matchear en ALGUNO de los campos
  // habilitados (OR entre campos) y TODOS los tokens deben matchear (AND entre
  // tokens), en cualquier orden — así "maria ruiz" encuentra a "María Luisa Peña
  // Ruíz". El NOMBRE siempre entra (red de seguridad). SQLite-válido (solo LIKE ?).
  final clauses = <String>[];
  final params = <Object?>[];
  for (final tok in tokens) {
    final like = '%$tok%';
    final partes = <String>['${foldSqlExpr('$alias.nombre')} LIKE ?'];
    final p = <Object?>[like];

    if (settings.busquedaPorCodigo) {
      partes.add('${foldSqlExpr('$alias.codigo')} LIKE ?');
      p.add(like);
    }
    if (settings.busquedaPorCedula) {
      partes.add('${foldSqlExpr('$alias.cedula')} LIKE ?');
      p.add(like);
    }
    if (settings.busquedaPorTelefono) {
      // El token se reduce a dígitos para matchear el teléfono almacenado (al que
      // también le sacamos separadores: SQLite no tiene regex → replace()
      // encadenado). Si el token no tiene dígitos, cae al LIKE de texto (no
      // matchea un número, pero el token igual entra por nombre/otro campo).
      final digits = sanitizePhoneForWhatsApp(tok);
      partes.add('replace(replace(replace(replace(replace('
          "coalesce($alias.telefono,''),'-',''),' ',''),'(',''),')',''),'+','') LIKE ?");
      p.add(digits.isEmpty ? like : '%$digits%');
    }
    if (settings.busquedaPorContrato) {
      partes.add('$alias.id IN (SELECT cliente_id FROM contratos '
          'WHERE ${foldSqlExpr('codigo')} LIKE ?)');
      p.add(like);
    }

    clauses.add('(${partes.join(' OR ')})');
    params.addAll(p);
  }

  return (sql: '(${clauses.join(' AND ')})', params: params);
}

/// Variante CLIENT-SIDE del mismo criterio, para las búsquedas que filtran en
/// Dart sobre filas YA cargadas (Cobros, mapa) en vez de un WHERE SQL — ahí no
/// se puede recrear el stream por tecla. Respeta los MISMOS toggles que
/// [busquedaClienteSql] para que la búsqueda configurable sea coherente en las
/// 5 pantallas (el NOMBRE siempre entra).
///
/// [campos] son los valores de la fila por nombre lógico:
/// `nombre`/`codigo`/`cedula`/`telefono`/`contratoCodigos` (este último = los
/// códigos de contrato concatenados, p.ej. `GROUP_CONCAT`). Cualquiera puede ser
/// null. El teléfono compara por dígitos (igual que el SQL usa el strip).
bool busquedaClienteMatch(
  String queryRaw,
  AppSettings settings, {
  String? nombre,
  String? codigo,
  String? cedula,
  String? telefono,
  String? contratoCodigos,
}) {
  final toks = tokensBusqueda(queryRaw);
  if (toks.isEmpty) return true;

  // Plegamos cada campo UNA vez (ñ/acentos → ASCII, espeja foldSqlExpr).
  final nombreF = foldBusqueda(nombre ?? '');
  final codigoF = settings.busquedaPorCodigo ? foldBusqueda(codigo ?? '') : '';
  final cedulaF = settings.busquedaPorCedula ? foldBusqueda(cedula ?? '') : '';
  final contratoF =
      settings.busquedaPorContrato ? foldBusqueda(contratoCodigos ?? '') : '';
  final telF = settings.busquedaPorTelefono ? foldBusqueda(telefono ?? '') : '';
  final telDigits = settings.busquedaPorTelefono
      ? sanitizePhoneForWhatsApp(telefono ?? '')
      : '';

  // TODOS los tokens deben matchear en ALGÚN campo habilitado (AND entre tokens,
  // OR entre campos), en cualquier orden — espeja busquedaClienteSql. El nombre
  // siempre entra. El teléfono compara por dígitos (igual que el SQL).
  for (final tok in toks) {
    final tokDigits = sanitizePhoneForWhatsApp(tok);
    final ok = nombreF.contains(tok) ||
        (settings.busquedaPorCodigo && codigoF.contains(tok)) ||
        (settings.busquedaPorCedula && cedulaF.contains(tok)) ||
        (settings.busquedaPorContrato && contratoF.contains(tok)) ||
        (settings.busquedaPorTelefono &&
            (telF.contains(tok) ||
                (tokDigits.isNotEmpty && telDigits.contains(tokDigits))));
    if (!ok) return false;
  }
  return true;
}
