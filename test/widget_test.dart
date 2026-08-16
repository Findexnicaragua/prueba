// Smoke test mínimo del harness de tests.
//
// El boilerplate original del scaffolding referenciaba `MyApp` (nombre del
// template default de Flutter) que no existe en este proyecto — el widget raíz
// real es `CobranzaApp`. Ese widget no es pumpeable en aislamiento porque
// main() inicializa Supabase + PowerSync + ProviderContainer antes de runApp,
// así que acá dejamos un smoke test trivial que confirma que el harness corre.
//
// La cobertura real vive en los tests de lógica:
//   - test/data/utils/edge_functions_test.dart
//   - tests de pagos_repo (lógica de cobro / vuelto / anular).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('smoke: el harness de widgets renderiza', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Cobranza ISP'))),
    );
    expect(find.text('Cobranza ISP'), findsOneWidget);
  });
}
