@TestOn('vm')
library;

/// Los textos del Resumen, RENDERIZADOS de verdad.
///
/// Por qué existe: el 2026-08-11 se cambiaron los títulos y los bloques del
/// Resumen, se compiló, se instaló y el dueño reportó "no hubo ningún cambio
/// visual". La causa fue otra (abrió una app branded distinta), pero dejó la
/// pregunta abierta: un cambio que compila y no se pinta es indistinguible de
/// un cambio que no se hizo, y `flutter analyze` + los tests de números NO lo
/// cazan (los números salen de la consulta; el título sale del widget).
///
/// Este test monta `DashboardPinGate` —el MISMO widget que construye la ruta
/// '/admin/resumen' (`router.dart`)— sobre un SQLite REAL de PowerSync con
/// datos sembrados a medida, y afirma sobre lo que quedó en el árbol de
/// widgets. Si un cambio se queda en una rama muerta, detrás de un gate o en
/// un provider que nadie observa, acá se cae.
///
/// Lo único que se simula es la IDENTIDAD (`cobradorActualProvider`, que en
/// producción sale de Supabase Auth) y los SETTINGS (mapa vacío = los defaults
/// de `settings_repo.dart`, que es lo que tienen los 3 tenants vivos). Todo lo
/// demás —consultas, providers, gates de rol y de setting, layout— es el de
/// producción.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/models/setting.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
import 'package:isp_billing/data/repositories/settings_repo.dart';
import 'package:isp_billing/data/utils/formatters.dart';
import 'package:isp_billing/data/utils/periodo_dashboard.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_admin_screen.dart';
import 'package:isp_billing/features/admin/dashboard/mora_ciclos_card.dart';
import 'package:isp_billing/features/admin/dashboard/tendencia_cobros_card.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

const _tenant = 't-widget';
const _cobradorId = '11111111-1111-1111-1111-111111111111';

/// Un pago del escenario, con lo que el test necesita para calcular a mano lo
/// que la pantalla TIENE que mostrar.
class _Pago {
  const _Pago(this.id, this.cuotaId, this.monto, this.fecha);
  final String id;
  final String cuotaId;
  final num monto;
  final DateTime fecha;
}

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('dashboard_resumen_widget (saltado: falta powersync-sqlite-core)',
        () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  late PowerSyncDatabase db;
  late Directory tmpDir;

  // El ciclo en curso, calculado con los MISMOS helpers que usa la pantalla
  // (si el corte del 15 cambiara, el escenario se mueve con él y el test no
  // se pudre al pasar de mes).
  final hoy = Fmt.hoyNicaragua();
  final periodo = periodoDe(hoy);
  final iniCiclo = inicioPeriodo(periodo.year, periodo.month);
  final vence = iniCiclo.add(const Duration(days: 5));

  Future<void> abrirDb() async {
    tmpDir = await Directory.systemTemp.createTemp('dash_widget_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, 'test.db'));
    await db.initialize();
    await db.execute(
        'INSERT INTO cobradores (id, tenant_id, nombre, rol, activo) '
        'VALUES (?, ?, ?, ?, 1)',
        [_cobradorId, _tenant, 'Admin Test', 'admin']);
    // La pantalla lee `ps.db` (variable global de la app). Apuntarla a la base
    // del test es lo que permite montar los widgets REALES sin tocarlos.
    ps.db = db;
  }

  Future<void> cerrarDb() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }

  Future<void> insertarCliente(String id, String codigo) => db.execute(
      'INSERT INTO clientes (id, tenant_id, codigo, nombre, activo) '
      'VALUES (?, ?, ?, ?, 1)',
      [id, _tenant, codigo, 'Cliente $codigo']);

  Future<void> insertarContrato(String id, String clienteId) => db.execute(
      'INSERT INTO contratos (id, tenant_id, cliente_id, estado, dia_pago) '
      'VALUES (?, ?, ?, ?, ?)',
      [id, _tenant, clienteId, 'activo', 20]);

  Future<void> insertarCuota(String id, String clienteId, String contratoId,
          {required num monto,
          required num pagado,
          required DateTime vencimiento}) =>
      db.execute(
          'INSERT INTO cuotas (id, tenant_id, cliente_id, contrato_id, '
          'fecha_vencimiento, monto, cargos_neto, monto_pagado, estado) '
          'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)',
          [
            id,
            _tenant,
            clienteId,
            contratoId,
            isoDia(vencimiento),
            monto,
            pagado,
            pagado >= monto ? 'pagada' : (pagado > 0 ? 'parcial' : 'pendiente'),
          ]);

  Future<void> insertarPago(_Pago pago) => db.execute(
      'INSERT INTO pagos (id, tenant_id, cuota_id, cobrador_id, '
      // `fecha_cobro` (0273): el dashboard filtra el ciclo por esta columna.
      // Sin sembrarla, todo da cero (regla 16).
      'monto_cordobas, monto_original, moneda, metodo, fecha_pago, '
      'fecha_cobro, anulado, en_revision) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)',
      [
        pago.id,
        _tenant,
        pago.cuotaId,
        _cobradorId,
        pago.monto,
        pago.monto,
        'NIO',
        'efectivo',
        isoDia(pago.fecha),
        isoDia(pago.fecha),
      ]);

  /// Monta la pantalla REAL de la ruta '/admin/resumen'.
  ///
  /// Lo único overrideado es la identidad (Supabase Auth no existe en un test)
  /// y el mapa de settings VACÍO — o sea, los defaults de `settings_repo.dart`,
  /// que son los que tienen hoy los 3 tenants vivos (`dashboard.*_visible` en
  /// true, `cobranza.dias_gracia` 10).
  /// [rol] `super_admin` por defecto: es el único que entra al Resumen sin
  /// pasar por el teclado del PIN (`dashboard_admin_screen.dart:114`), así que
  /// es con el que se puede testear la PANTALLA. Con `admin` la ruta muestra el
  /// PIN, que es otro widget y otro test.
  /// [todo] prende TODO lo que hoy nace apagado: `dashboard.extras_visible`
  /// (las seis descartadas) y `dashboard.pendientes_visible` (las tarjetas 2 a
  /// 5, que se estan rehaciendo de a una). Ninguna de las dos claves esta
  /// sembrada, asi que `settingValue` cae a su default `false`; este harness
  /// inyecta un mapa VACIO, o sea el mismo default que ve un admin real. Un
  /// test que mire cualquier tarjeta que no sea Cobertura del ciclo tiene que
  /// pedir `todo: true` o no va a encontrar nada.
  Future<void> montarResumen(WidgetTester tester,
      {String rol = 'super_admin', bool todo = false, double ancho = 1600}) async {
    // Ventana grande: el Resumen es una lista y los widgets que no entran en
    // el viewport ni se construyen (un `find` sobre ellos daría 0 sin que nada
    // esté roto). 1600×4200 entra todo lo que este test mira.
    //
    // `ancho` se baja a 360 para probar el layout de TELÉFONO: las tarjetas
    // consultan `MediaQuery` para decidir si van compactas.
    tester.view.physicalSize = Size(ancho, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Desmontar ANTES de que el tearDown cierre la base: si los `db.watch` de
    // las tarjetas siguen suscritos, `db.close()` no vuelve nunca y el test
    // muere recién a los 10 minutos por timeout.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    final cobrador = Cobrador(
      id: _cobradorId,
      tenantId: _tenant,
      nombre: 'Admin Test',
      rol: rol,
      activo: true,
    );

    final app = ProviderScope(
      overrides: [
        cobradorActualProvider.overrideWith((ref) => Stream.value(cobrador)),
        settingsMapProvider.overrideWith((ref) => Stream.value(todo
            ? <String, Setting>{
                for (final clave in const [
                  'dashboard.extras_visible',
                  'dashboard.pendientes_visible',
                ])
                  clave: Setting(
                    id: 'set-$clave',
                    tenantId: _tenant,
                    clave: clave,
                    valor: true,
                    tipo: 'boolean',
                    categoria: 'cobranza',
                    editablePor: 'super_admin',
                  ),
              }
            : const <String, Setting>{})),
      ],
      // Locale y delegates IGUALES a los de `app.dart`: `Fmt` formatea con
      // 'es_NI' y sin los delegates de intl el primer build tira
      // LocaleDataException (y la pantalla entera queda en blanco).
      child: const MaterialApp(
        locale: Locale('es', 'NI'),
        supportedLocales: [Locale('es', 'NI'), Locale('es'), Locale('en')],
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: DashboardPinGate()),
      ),
    );

    // El montaje ENTERO va dentro de `runAsync` (zona real, no la del reloj
    // falso del test): así los `db.watch` de las tarjetas programan timers
    // REALES y las consultas terminan. Montando en la zona del test, los
    // timers de `sqlite_async` quedan congelados, las tarjetas no salen nunca
    // del spinner y hasta `db.close()` se cuelga esperándolos (10 min de
    // timeout por test, verificado).
    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      await asentar(tester);
    });
    await tester.pump();
  }

  tearDown(cerrarDb);

  // ── Escenario A: títulos, conteo por cuota, botones y puente ────────────
  //
  // 4 pagos repartidos a propósito:
  //   · dos pagos de HOY sobre la MISMA cuota  → distingue "cuotas" de "cobros"
  //   · un pago del arranque del ciclo         → distingue "Hoy" de "Período"
  //   · un pago ANTERIOR al ciclo, de una cuota del ciclo → alimenta el PUENTE
  group('Resumen — textos y bloques del ciclo', () {
    // C1: dos abonos hoy a la misma cuota.
    final pagoHoyA = _Pago('pg-1a', 'cuo-1', 700, hoy);
    final pagoHoyB = _Pago('pg-1b', 'cuo-1', 310, hoy);
    // C4: cobrado el primer día del ciclo (entra al período, no a "Hoy" salvo
    // que hoy SEA el día 15 — el test calcula, no supone).
    final pagoDelCiclo = _Pago('pg-4', 'cuo-4', 300, iniCiclo);
    // C3: cobrado ANTES de que el ciclo abriera, sobre una cuota del ciclo.
    final pagoAnterior =
        _Pago('pg-3', 'cuo-3', 500, iniCiclo.subtract(const Duration(days: 3)));

    final todos = [pagoHoyA, pagoHoyB, pagoDelCiclo, pagoAnterior];

    num sumaDesde(DateTime desde) => todos
        .where((x) => !x.fecha.isBefore(desde))
        .fold<num>(0, (a, x) => a + x.monto);

    final esperadoPeriodo = sumaDesde(iniCiclo);
    final pagosDeHoy = todos.where((x) => x.fecha == hoy).toList();
    final esperadoHoy = pagosDeHoy.fold<num>(0, (a, x) => a + x.monto);
    final cuotasDeHoy = pagosDeHoy.map((x) => x.cuotaId).toSet().length;
    // Lo recuperado del ciclo por la tarjeta de cobertura = TODO lo pagado a
    // cuotas que vencen en el ciclo, sin importar cuándo entró.
    final recuperadoCiclo = todos.fold<num>(0, (a, x) => a + x.monto);

    setUp(() async {
      await abrirDb();
      await insertarCliente('cli-1', 'W-01');
      await insertarContrato('ctr-1', 'cli-1');
      await insertarCuota('cuo-1', 'cli-1', 'ctr-1',
          monto: 1010, pagado: 1010, vencimiento: vence);
      await insertarCliente('cli-3', 'W-03');
      await insertarContrato('ctr-3', 'cli-3');
      await insertarCuota('cuo-3', 'cli-3', 'ctr-3',
          monto: 500, pagado: 500, vencimiento: vence);
      await insertarCliente('cli-4', 'W-04');
      await insertarContrato('ctr-4', 'cli-4');
      await insertarCuota('cuo-4', 'cli-4', 'ctr-4',
          monto: 300, pagado: 300, vencimiento: vence);
      // Una cuota del ciclo SIN cobrar: separa el "Cobros" (facturado) del
      // "Recuperado" para que el monto del puente se pueda ubicar sin
      // ambigüedad en la tabla de la otra tarjeta.
      await insertarCliente('cli-5', 'W-05');
      await insertarContrato('ctr-5', 'cli-5');
      await insertarCuota('cuo-5', 'cli-5', 'ctr-5',
          monto: 200, pagado: 0, vencimiento: vence);
      for (final pago in todos) {
        await insertarPago(pago);
      }
    });

    // La red del rework (2026-08-27): el dueno pidio enfocarse en UNA tarjeta
    // por vez, empezando por Cobertura del ciclo. Las otras cuatro estan
    // apagadas tras `dashboard.pendientes_visible` y las seis descartadas tras
    // `dashboard.extras_visible`; ninguna de las dos claves esta sembrada.
    // Cuando se apruebe la 2, se la saca del gate Y se la mueve aca arriba.
    testWidgets('por defecto se ve SOLO Cobertura del ciclo', (tester) async {
      await montarResumen(tester);

      expect(find.text('Cobertura del ciclo'), findsWidgets);
      // `Caja del ciclo` se ENCENDIO el 2026-08-28 (pedido del dueno) y ya no
      // depende de ningun gate: va primera, arriba de Cobertura.
      expect(find.text('Caja del ciclo'), findsOneWidget);
      // `Estado actual` VOLVIO el 2026-09-01 y `Distribucion de cuotas` el
      // 2026-09-02, las dos por el mismo pedido: que todo lo que mostraba el
      // Resumen viejo apareciera en el nuevo. Ya no queda ninguna del Resumen
      // viejo apagada por defecto.
      expect(find.text('Estado actual'), findsOneWidget);
      expect(find.text('Distribución de cuotas'), findsOneWidget);

      // 🔴 Estas TRES estaban en la lista de "apagadas" hasta el 2026-09-02 y
      // ahora se esperan PRESENTES. No es que el test se haya relajado: la
      // lista vieja las nombraba como "titulos VIEJOS de tarjetas que se
      // reemplazaron", y el dueno pidio deshacer justamente ese reemplazo. Hoy
      // son los titulos VIGENTES.
      for (final titulo in const [
        'Proyección de cobros por cobrador',
        'Recuperación por cobrador y comunidad',
        'Distribución de cuotas',
      ]) {
        expect(find.text(titulo), findsOneWidget,
            reason: 'volvio el 2026-09-02 y tiene que verse: $titulo');
      }

      for (final titulo in const [
        // titulos VIEJOS de tarjetas que si se reemplazaron de verdad
        'Mora — últimos 6 meses',
        'Top cobradores (hoy)',
        // las tres que siguen apagadas por defecto
        'Recaudo y mora',
        'Cobros últimos 7 días',
        'Consultar período',
      ]) {
        expect(find.text(titulo), findsNothing,
            reason: 'tiene que estar apagada y se esta viendo: $titulo');
      }
    });

    testWidgets('los tres títulos nuevos se pintan y los viejos no existen',
        (tester) async {
      await montarResumen(tester, todo: true);

      // Cambio 1 — tendencia de cobros.
      expect(find.text('Cobertura del ciclo'), findsOneWidget);
      expect(find.text('Cobros del mes'), findsNothing);

      // Cambio 2 — KPIs de caja.
      expect(find.text('Caja del ciclo'), findsOneWidget);
      expect(find.text('Cobros del período'), findsNothing);

      // Cambio 3 — la mora es la tabla de UN ciclo con los 6 ultimos de
      // contexto (2026-08-28). Los dos titulos anteriores —la curva de 6
      // meses y la tarjeta de barras suelta— ya no existen.
      expect(find.text('Mora del ciclo'), findsOneWidget);
      expect(find.text('Mora — últimos 6 meses'), findsNothing);
      expect(find.text('Mora — últimos 6 ciclos'), findsNothing);
      expect(find.byType(MoraCiclosCard), findsOneWidget);
    });

    testWidgets('cambio 4: los KPIs de caja cuentan CUOTAS, no filas de pagos',
        (tester) async {
      await montarResumen(tester, todo: true);

      // Hoy entraron 2 pagos sobre 1 sola cuota: el bloque tiene que decir 1.
      expect(pagosDeHoy.length, greaterThan(cuotasDeHoy),
          reason: 'el escenario debe tener dos abonos a la misma cuota, '
              'si no la aserción no distingue cuotas de cobros');
      // La tarjeta nueva rotula "N cobros"; el criterio no cambio: son CUOTAS
      // distintas, no filas de `pagos`.
      //
      // Se mira SOLO el bloque del dia: "2 cobros" es un error ahi y puede ser
      // perfectamente legitimo en el de semana o el de periodo.
      final bloqueDia = find.byKey(const ValueKey('caja-bloque-dia'));
      expect(
          find.descendant(
              of: bloqueDia,
              matching: find.textContaining('$cuotasDeHoy cobro')),
          findsOneWidget);
      expect(
          find.descendant(
              of: bloqueDia,
              matching: find.textContaining('${pagosDeHoy.length} cobros')),
          findsNothing,
          reason: 'contar filas de pagos (el comportamiento viejo) diria 2');
      // Y la palabra es "cuotas", no "cobros".
      expect(find.text('$cuotasDeHoy cobros'), findsNothing);
    });

    testWidgets('cambio 5: tocar un bloque cambia la ventana ACTIVA',
        (tester) async {
      await montarResumen(tester, todo: true);

      // Este test probaba el desglose "¿De qué cuotas era esta plata?", que se
      // eliminó el 2026-08-29 ("eso es totalmente innecesario") y VOLVIÓ el
      // 2026-08-31, cuando el dueño revisó que el Resumen nuevo no perdiera
      // nada de lo que muestra el anterior. Vuelve CERRADO, detrás de un
      // chevron: la objeción no era el dato sino el lugar que ocupaba.
      //
      // El observable de la selección sigue siendo el PUENTE y no el desglose,
      // porque el puente sólo se pinta cuando el bloque activo es un ciclo
      // completo — o sea que cambia al tocar, que es lo que este test mide.
      // El desglose está siempre (cerrado), así que no serviría para esto.
      final puente = find.textContaining('que es lo cobrado en "Cobertura');

      expect(puente, findsOneWidget,
          reason: 'arranca en "Este período", que es un ciclo completo');

      await tocar(tester, montoDelBloque(esperadoHoy));
      expect(puente, findsNothing,
          reason: 'con un día suelto elegido, el puente no aplica');

      await tocar(tester, montoDelBloque(esperadoPeriodo));
      expect(puente, findsOneWidget);
    });

    testWidgets('cambio 6: el puente explica cómo llegar al "Recuperado"',
        (tester) async {
      await montarResumen(tester, todo: true);

      final puente = 'De este ciclo entraron ${Fmt.cordobas(esperadoPeriodo)} '
          'ahora, y otros ${Fmt.cordobas(pagoAnterior.monto)} ya se habían '
          'cobrado antes. Juntos dan '
          '${Fmt.cordobas(esperadoPeriodo + pagoAnterior.monto)}, que es lo '
          'cobrado en "Cobertura del ciclo".';
      expect(find.text(puente), findsOneWidget);

      // Y la cuenta que promete tiene que cerrar contra el número que la OTRA
      // tarjeta pinta: si no, el puente miente con números en la cara.
      expect(esperadoPeriodo + pagoAnterior.monto, recuperadoCiclo);
      // La tabla volvio a las tres filas: el monto que el puente promete es el
      // de la fila RECUPERADO (el de "Cobros" es lo facturado del ciclo).
      expect(
        find.descendant(
            of: filaDeCobertura('Recuperado'),
            matching: find.text(Fmt.cordobas(recuperadoCiclo))),
        findsOneWidget,
      );

      // El puente solo tiene sentido con el ciclo entero elegido.
      await tocar(tester, montoDelBloque(esperadoHoy));
      expect(find.text(puente), findsNothing);
    });

    testWidgets('cambio 7: la nota de "pagado por adelantado" ya no se pinta',
        (tester) async {
      await montarResumen(tester);

      // El escenario tiene un pago adelantado (entró antes de que el ciclo
      // abriera), que es justo el que hacía aparecer la nota vieja.
      expect(find.textContaining('ya venía pagado por adelantado'),
          findsNothing);
    });

    testWidgets('en TELÉFONO los bloques de caja van apilados y parejos',
        (tester) async {
      // El bug reportado con capturas (2026-08-29): apilados, cada bloque
      // tomaba el ancho de SU texto y los tres quedaban escalonados. No lo caza
      // el analyzer ni un test de datos — sólo aparece a un ancho concreto.
      await montarResumen(tester, ancho: 360);

      final claves = ['caja-bloque-dia', 'caja-bloque-semana',
        'caja-bloque-periodo'];
      final anchos = <double>[];
      final xs = <double>[];
      for (final k in claves) {
        final f = find.byKey(ValueKey(k));
        expect(f, findsOneWidget, reason: 'falta el bloque $k');
        anchos.add(tester.getSize(f).width);
        xs.add(tester.getTopLeft(f).dx);
      }
      // ignore: avoid_print
      print('\n== Bloques a 360px ==\nanchos: $anchos\nx: $xs');

      expect(anchos.toSet().length, 1,
          reason: 'apilados tienen que medir todos lo mismo, no escalonarse');
      expect(xs.toSet().length, 1,
          reason: 'en teléfono van uno debajo del otro, no en fila');
    });

    testWidgets('en PC los bloques de caja van en FILA', (tester) async {
      await montarResumen(tester);
      final xs = [
        for (final k in const ['caja-bloque-dia', 'caja-bloque-semana',
          'caja-bloque-periodo'])
          tester.getTopLeft(find.byKey(ValueKey(k))).dx
      ];
      expect(xs.toSet().length, 3,
          reason: 'en pantalla ancha los tres van lado a lado');
    });

    // El desglose volvió el 2026-08-31, y vuelve CERRADO. Las dos mitades de
    // eso importan y por eso van juntas en un test: si estuviera abierto,
    // vuelve el problema que lo hizo sacar; si no estuviera, se perdió lo que
    // el dueño pidió recuperar.
    testWidgets('el desglose de caja está, y arranca cerrado', (tester) async {
      await montarResumen(tester, todo: true);

      // El encabezado se ve...
      expect(find.text('¿De qué cuotas era esta plata?'), findsOneWidget);
      // ...pero su contenido NO, hasta que alguien lo abra. Se mira "Total que
      // entró" porque es la ÚNICA fila incondicional del cuerpo: las otras
      // cuatro sólo se pintan si su monto es > 0, o sea que dependen del
      // escenario — y este test es sobre el desplegable, no sobre los datos.
      expect(find.textContaining('Total que entró'), findsNothing);

      // El tap y la espera van dentro de `runAsync`: al abrirse, el cuerpo
      // recién ahí dispara su consulta, y en la zona del reloj falso del test
      // esa consulta no termina nunca (mismo motivo que el montaje).
      await tester.runAsync(() async {
        await tester.tap(find.text('¿De qué cuotas era esta plata?'));
        await asentar(tester);
      });

      // Abierto, aparece el cuerpo.
      expect(find.textContaining('Total que entró'), findsWidgets);
    });

    testWidgets('el gate de rol: admin_cobranza no ve la caja', (tester) async {
      await montarResumen(tester, rol: 'admin_cobranza', todo: true);

      // Documenta el gate INTENCIONAL de dashboard_admin_screen.dart:468: si
      // mañana la caja se le escapa a este rol, este test se cae.
      expect(find.text('Caja del ciclo'), findsNothing);
      expect(find.text('¿De qué cuotas era esta plata?'), findsNothing);
      // Pero SÍ sigue viendo mora y cobertura (su trabajo).
      expect(find.text('Cobertura del ciclo'), findsOneWidget);
      expect(find.text('Mora del ciclo'), findsOneWidget);
    });
  });

  // ── Escenario B: la aritmética de la tabla, tal como se imprime ─────────
  //
  //   cuo-A: monto 1.010, cobrado 1.100 (sobre-cubierta, excedente 90)
  //   cuo-B: monto   990, cobrado     0
  //   ⇒ facturado 2.000 · recuperado aplicado 1.010 (50,5%) · falta 990 (49,5%)
  //
  // Los dos porcentajes caen JUSTO en el ,5: redondeando cada uno por su
  // cuenta la columna imprime 51% y 50% (=101%). Y `meta − rec` daría 900,
  // no los 990 que suman las cuotas.
  // SIN RED DE WIDGET TEST: el group de abonos parciales se retiro el
  // 2026-08-28. Montar la tabla con el InkWell de los desgloses deja algo vivo
  // que cuelga la suite 10 minutos Y arrastra a los tests que corren despues
  // (mismo sintoma que el test borrado el 27/08). Hay que resolver el harness
  // antes de volver a intentarlo.
  //
  // Lo que SI esta verificado: la consulta `desgloseRecuperado` se corrio
  // contra la base real y sus `saldadas` suman 29 (= la fila Recuperado) y sus
  // `monto` suman 21.100 (= su monto), con el credito cayendo en su momento.

  group('Resumen — porcentajes y "Por recuperar"', () {
    setUp(() async {
      await abrirDb();
      await insertarCliente('cli-a', 'W-A');
      await insertarContrato('ctr-a', 'cli-a');
      await insertarCuota('cuo-a', 'cli-a', 'ctr-a',
          monto: 1010, pagado: 1100, vencimiento: vence);
      await insertarPago(_Pago('pg-a', 'cuo-a', 1100, hoy));
      await insertarCliente('cli-b', 'W-B');
      await insertarContrato('ctr-b', 'cli-b');
      await insertarCuota('cuo-b', 'cli-b', 'ctr-b',
          monto: 990, pagado: 0, vencimiento: vence);
    });

    testWidgets('cambio 8: los porcentajes suman 100, nunca 101',
        (tester) async {
      await montarResumen(tester);

      // La pastilla de cada fila. La tabla volvio a las TRES filas del
      // concepto original (Cobros / Recuperado / Por recuperar) y el % es de
      // MONTO: recuperado 1.100 de 2.000.
      expect(pctDeFila('Cobros', '100%'), findsOneWidget);
      expect(pctDeFila('Recuperado', '50%'), findsOneWidget,
          reason: '1 de 2 cuotas saldadas = 50%');
      expect(pctDeFila('Por recuperar', '50%'), findsOneWidget,
          reason: 'el ultimo se DERIVA de los otros, no se redondea aparte');
    });

    testWidgets('cambio 9: "Por recuperar" sale de la consulta, no de la resta',
        (tester) async {
      await montarResumen(tester);

      // El monto de "Por recuperar" es la Σ de saldos clampeados cuota por
      // cuota = 0 + 990, NO `facturado − recuperado` = 2.000 − 1.100 = 900.
      // Con la resta, la cuota sobre-cubierta le comia deuda a la otra.
      final porRec = filaDeCobertura('Por recuperar');
      expect(
          find.descendant(of: porRec, matching: find.text(Fmt.cordobas(990))),
          findsOneWidget);
      expect(
          find.descendant(of: porRec, matching: find.text(Fmt.cordobas(900))),
          findsNothing,
          reason: 'si volviera la resta, la fila mostraria ESTE monto');

      // La tabla cuenta CUOTAS: "Recuperado" muestra lo facturado de las cuotas
      // saldadas (1.010), no el pago crudo (1.100). El excedente de C$90 de la
      // cuota sobre-cubierta no aparece — es el clamp que sostiene el 100%.
      final rec = filaDeCobertura('Recuperado');
      expect(find.descendant(of: rec, matching: find.text(Fmt.cordobas(1010))),
          findsWidgets);

      // Y los conteos cierran: 2 cuotas en el ciclo, 1 saldada y 1 debiendo.
      expect(
          find.descendant(
              of: filaDeCobertura('Cobros'), matching: find.text('2')),
          findsWidgets);
      expect(
          find.descendant(of: porRec, matching: find.text('1')), findsWidgets);
    });
  });

  // El Resumen es una PILA de tarjetas grandes. Con el borde del tema (0,5px
  // #E5E5EA) sobre el fondo de pagina (#FAFAFC) y blanco puro adentro, las
  // siete se leian como una sola masa continua — reporte del dueno el
  // 2026-09-01: *"me gustaria una separacion clara entre cada grafico"*.
  //
  // Esto NO lo caza `flutter analyze` ni ningun test de datos: un borde que se
  // afina o un aire que vuelve a 16 no rompen nada, solo deshacen el arreglo en
  // silencio. Y como el override vive en un `Theme` que envuelve la pantalla,
  // basta con que alguien mueva ese `Theme` de lugar para perderlo entero.
  // LA LETRA MAS GRANDE NO PUEDE ROMPER NINGUNA TARJETA (2026-09-01).
  //
  // El dueno pidio subir los tamanos "en general" y se unificaron en
  // `TxtResumen`: nueve valores sueltos —algunos de 9px— pasaron a seis roles.
  // Subir tipografia es exactamente el cambio que hace desbordar layouts
  // ajustados, y un overflow en release NO avisa: pinta la franja rayada en
  // debug y en release corta el texto y listo.
  //
  // Se monta el Resumen ENTERO con todas las tarjetas encendidas, a los tres
  // anchos que importan, y se exige cero excepciones.
  group('Resumen — la tipografia nueva no desborda', () {
    setUp(abrirDb);

    for (final ancho in [360.0, 800.0, 1900.0]) {
      testWidgets('a ${ancho.toInt()}px no desborda ninguna tarjeta',
          (tester) async {
        await montarResumen(tester, todo: true, ancho: ancho);
        expect(tester.takeException(), isNull,
            reason: 'alguna tarjeta del Resumen desborda a ${ancho.toInt()}px '
                'con la escala de `TxtResumen`');
      });
    }
  });

  group('Resumen — separacion entre tarjetas', () {
    // Base VACIA a proposito, y no solo por comodidad: es el tenant recien
    // creado y el device antes del primer sync. Montar el Resumen asi destapo
    // un NaN en el painter de Cobertura (sin meta ni cobros, `yMax` daba 0 y
    // `yOf` dividia por cero). Si algun dia alguien siembra datos aca para
    // "arreglar" un test, ese caso deja de probarse.
    setUp(abrirDb);

    testWidgets('cada tarjeta lleva el borde marcado del Resumen',
        (tester) async {
      await montarResumen(tester, todo: true);

      final cards = find.byType(Card);
      expect(tester.widgetList(cards), isNotEmpty,
          reason: 'no se monto ninguna tarjeta');

      // El `shape` del widget `Card` es NULL: la forma la resuelve el tema al
      // construir. Lo que de verdad se pinta es el `Material` que la Card arma
      // adentro, y ahi si esta el borde efectivo. Mirar el widget daria null
      // aunque el override este puesto Y aunque no lo este.
      for (var i = 0; i < tester.widgetList(cards).length; i++) {
        final mat = tester.widget<Material>(find
            .descendant(of: cards.at(i), matching: find.byType(Material))
            .first);
        expect(mat.shape, isA<RoundedRectangleBorder>(),
            reason: 'una tarjeta del Resumen perdio su forma');
        final side = (mat.shape! as RoundedRectangleBorder).side;
        expect(side.width, 1.0,
            reason: 'el borde volvio al filete de 0,5px del tema global');
        expect(side.color, const Color(0xFFD1D1D6),
            reason: 'el borde volvio al gris del tema global (#E5E5EA), que '
                'sobre el fondo de pagina casi no se ve');
      }
    });

    testWidgets('entre dos tarjetas hay 28px, no 16', (tester) async {
      await montarResumen(tester, todo: true);

      final cards = find.byType(Card);
      expect(tester.widgetList(cards).length, greaterThan(1),
          reason: 'con una sola tarjeta no hay separacion que medir');

      // Se mide el HUECO REAL entre los rectangulos pintados, no el
      // `SizedBox`: si alguien mete un widget entre medio, el SizedBox sigue
      // diciendo 28 y la separacion visible es otra.
      final a = tester.getRect(cards.at(0));
      final b = tester.getRect(cards.at(1));
      expect(b.top - a.bottom, closeTo(28.0, 0.5),
          reason: 'el aire entre tarjetas cambio; era 16 y subio a 28');
    });
  });
}

/// La FILA de la tabla de "Cobertura del ciclo" cuyo rótulo es [label]
/// ("Cobros" / "Recuperado" / "Por recuperar").
Finder filaDeCobertura(String label) => find
    .ancestor(
      of: find.descendant(
          of: find.byType(TendenciaCobrosCard), matching: find.text(label)),
      matching: find.byType(Row),
    )
    .first;

/// La pastilla de porcentaje de esa fila. Scopear importa: un `find.text('49%')`
/// suelto podría estar matcheando la pastilla de OTRA fila (o de la tarjeta de
/// Mora) y el test pasaría sin probar nada.
Finder pctDeFila(String label, String pct) =>
    find.descendant(of: filaDeCobertura(label), matching: find.text(pct));

/// El monto GRANDE de un bloque de la tarjeta de caja — el que se toca para
/// elegir cual manda sobre el desglose. Se distingue del monto del desglose
/// por su tamano: 22 contra 12.
Finder montoDelBloque(num monto) => find
    .byWidgetPredicate((w) =>
        w is Text &&
        w.data == Fmt.cordobas(monto) &&
        (w.style?.fontSize ?? 0) >= 20)
    .first;

// `totalDelDesglose` se retiro el 2026-08-29 con el bloque que medía: la
// tarjeta de caja ya no lista "Total que entró / Cuotas del ciclo / Atrasos".

/// Toca un bloque y espera a que la consulta de la ventana nueva vuelva.
/// También va en zona real: el `setState` crea una suscripción nueva.
Future<void> tocar(WidgetTester tester, Finder objetivo) async {
  await tester.runAsync(() async {
    await tester.tap(objetivo);
    await tester.pump();
    await asentar(tester);
  });
  await tester.pump();
}

/// Deja que los streams REALES de PowerSync entreguen sus filas y repinta.
/// Se llama SIEMPRE dentro de un `runAsync`.
Future<void> asentar(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
  }
}

String? _resolveCorePath() {
  for (final name in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    final f = File(name);
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}
