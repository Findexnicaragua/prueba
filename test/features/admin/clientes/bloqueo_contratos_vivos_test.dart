@TestOn('vm')
library;

/// El bloqueo "Todavía no se puede" de la baja de cliente, RENDERIZADO.
///
/// Por qué existe: la migración `0265` cambió el diálogo de baja de "esto va a
/// condonar C$X" a una LISTA de lo que falta cerrar, con una fila por contrato
/// que mete código, deuda y estado en el mismo renglón. En un teléfono de
/// 360 px eso tiene poco lugar, y un overflow de Flutter no lo caza `analyze`
/// ni un test de números — en release ni siquiera pinta la franja amarilla: el
/// texto queda cortado y nadie se entera.
///
/// Los casos de abajo no son bonitos a propósito: códigos largos, montos de
/// cinco cifras y varios contratos. Si aguanta esto, aguanta la operación real.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/formatters.dart';
import 'package:isp_billing/features/admin/clientes/cliente_form_screen.dart';

Future<void> _montar(
    WidgetTester tester, double ancho, List<Map<String, dynamic>> vivos) async {
  tester.view.physicalSize = Size(ancho, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    locale: const Locale('es', 'NI'),
    supportedLocales: const [Locale('es', 'NI'), Locale('es'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    // Dentro de un AlertDialog, que es donde vive de verdad: el ancho útil no
    // es el de la pantalla sino el que el diálogo deja, y ahí es donde aprieta.
    home: Scaffold(
      body: AlertDialog(
        title: const Text('Todavía no se puede'),
        content: SingleChildScrollView(child: ContratosVivosBloqueo(vivos: vivos)),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  const dosNormales = [
    {'id': 'c1', 'codigo': '4102', 'estado': 'activo', 'deuda': 3400.0},
    {'id': 'c2', 'codigo': '3877', 'estado': 'suspendido', 'deuda': 1420.0},
  ];

  group('Bloqueo de baja — entra en el teléfono y dice lo necesario', () {
    for (final ancho in [320.0, 360.0, 412.0, 800.0, 1400.0]) {
      testWidgets('${ancho.toInt()} px: se ve entero', (tester) async {
        await _montar(tester, ancho, dosNormales);
        expect(find.textContaining('2 contratos sin cerrar'), findsOneWidget);
        expect(find.textContaining('4102'), findsOneWidget);
        expect(find.textContaining('ACTIVO'), findsOneWidget);
        expect(find.textContaining('SUSPENDIDO'), findsOneWidget);
        // La deuda con el MISMO formateador de la pantalla, no un string a mano.
        expect(find.textContaining(Fmt.cordobas(3400)), findsOneWidget);
      });
    }

    testWidgets('el caso feo: código largo y monto de 6 cifras a 320 px',
        (tester) async {
      await _montar(tester, 320, const [
        {
          'id': 'c1',
          'codigo': 'CONTRATO-2026-000000129-B',
          'estado': 'suspendido',
          'deuda': 128450.75,
        },
      ]);
      // El texto se recorta con puntos suspensivos en vez de desbordar: por eso
      // las dos líneas de la fila llevan `maxLines: 1` + ellipsis.
      expect(find.textContaining('1 contrato sin cerrar'), findsOneWidget);
      expect(find.textContaining('SUSPENDIDO'), findsOneWidget);
    });

    testWidgets('un contrato SIN deuda igual bloquea, y lo dice',
        (tester) async {
      // El bloqueo es por contrato VIVO, no por deuda: un activo al día también
      // impide la baja. Si dijera "debe C$0.00" el usuario no entendería por
      // qué lo frena.
      await _montar(tester, 360, const [
        {'id': 'c1', 'codigo': '5001', 'estado': 'activo', 'deuda': 0.0},
      ]);
      expect(find.text('sin deuda'), findsOneWidget);
      expect(find.textContaining('1 contrato sin cerrar'), findsOneWidget);
    });

    testWidgets('cinco contratos a 360 px: la lista scrollea, no desborda',
        (tester) async {
      await _montar(tester, 360, [
        for (var i = 0; i < 5; i++)
          {
            'id': 'c$i',
            'codigo': '40$i',
            'estado': i.isEven ? 'activo' : 'suspendido',
            'deuda': 1000.0 * (i + 1),
          },
      ]);
      expect(find.textContaining('5 contratos sin cerrar'), findsOneWidget);
      expect(find.textContaining('403'), findsOneWidget);
    });
  });
}
