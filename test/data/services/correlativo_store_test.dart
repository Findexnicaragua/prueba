/// Tests de `CorrelativoStore` — el high-water mark local del correlativo de
/// recibos (audit 2026-06-11, finding #2). La propiedad que blindan:
/// MONOTONICIDAD — el valor guardado nunca decrece, para que un recibo
/// anulado removido del SQLite por el sync no haga reusar su número.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/services/correlativo_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('sin nada guardado → 0', () async {
    expect(await CorrelativoStore.leer('co1', 'A'), 0);
  });

  test('subirA es monotónico: nunca decrece', () async {
    await CorrelativoStore.subirA('co1', 'A', 5);
    expect(await CorrelativoStore.leer('co1', 'A'), 5);

    await CorrelativoStore.subirA('co1', 'A', 3); // menor → no baja
    expect(await CorrelativoStore.leer('co1', 'A'), 5);

    await CorrelativoStore.subirA('co1', 'A', 7);
    expect(await CorrelativoStore.leer('co1', 'A'), 7);
  });

  test('claves independientes por cobrador y por prefijo', () async {
    await CorrelativoStore.subirA('co1', 'A', 9);
    expect(await CorrelativoStore.leer('co1', 'A'), 9);
    expect(await CorrelativoStore.leer('co1', 'B'), 0);
    expect(await CorrelativoStore.leer('co2', 'A'), 0);
  });
}
