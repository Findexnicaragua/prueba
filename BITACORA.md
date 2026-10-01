# BITACORA.md — Control de cambios y estado vivo del proyecto

> **Quién lee esto:** la PRIMERA lectura de toda sesión nueva (humano o AI).
> Responde "¿dónde quedamos, qué fue lo último que se trabajó y por qué?".
> **Cómo se actualiza (OBLIGATORIO al cerrar cada sesión de trabajo):**
> 1. Refrescar el bloque **ESTADO ACTUAL** (versión, rama, lo último, pendientes).
>    Es un **panorama de ~1 pantalla, no una pila**: lo que deja de ser "estado"
>    baja a *Historial del bloque de estado*, y varias versiones de la misma saga
>    se cuentan como UNA entrada.
> 2. Dejar la historia de la sesión en un bullet fechado —`- **(AAAA-MM-DD) — título**`—
>    con qué se pidió/por qué + qué se hizo (commits y archivos clave) + qué quedó
>    pendiente + deploy necesario. Al cerrar la sesión siguiente, ese bullet baja a
>    *Historial del bloque de estado*. (Las entradas largas `## AAAA-MM-DD — título`
>    de más abajo son el formato viejo; se conservan, no se agregan nuevas.)
> 3. Si el cambio tocó módulos/conexiones → actualizar también
>    `ARQUITECTURA.md`. Si tocó misión/roles/stack → `PRODUCTO.md`.
> Mantener cada entrada en ≤15 líneas. El detalle fino vive en los commits.
> **Documentos hermanos:** `PRODUCTO.md` (qué es la app) · `ARQUITECTURA.md`
> (cómo está conectada) · `AGENTS.md` (reglas/proceso) · `Install Steps/`
> (build y release) · `TESTING.md` (testing manual).

---

## ⭐ ESTADO ACTUAL (refrescar al cerrar cada sesión)

- **👉 (2026-09-30) — Findex v0.45.3: Fase 3 Rework Microfinanzas / Préstamos — Cobro en Terreno, Recibos Térmicos, WhatsApp Directo y Cartera en Ruta.**
  · **Cobro en Terreno (`cobro_screen.dart`):** Tarjetas de cuota individual (`_ClienteCuotaCard`) y cobro múltiple (`_MultiCuotaCard`) adaptadas para microfinanzas mostrando el código de préstamo, desglose explícito de amortización (Abono a Capital vs Interés Ordinario) y el saldo restante proyectado al abonar.
  · **Modelo de Dominio (`cuota.dart`):** Incorporación de campos `capital`, `interes`, `saldoRestante` y getter `esPrestamo` para soporte transparente en cobro y auditoría.
  · **Comprobantes y Recibos Térmicos (`recibo_screen.dart`, `recibo_ticket.dart`, `recibo_pdf.dart`, `recibo_texto_escpos.dart`):** Inclusión de datos del crédito en los 3 motores de emisión (impresión térmica raster/Bluetooth, PDF descargable y ESC/POS texto). Emite 'Préstamo [código] · [cuota]' con líneas de Abono capital, Interés ordinario y Saldo restante deudor.
  · **Compartir por WhatsApp (`recibo_screen.dart`):** Botón de acción directa que formatea el comprobante digital estructurado con emojis y datos del préstamo, limpiando el teléfono del prestatario y abriendo la app de WhatsApp de inmediato.
  · **Cartera en Ruta (`cobros_query.dart`, `cuotas_list_screen.dart`):** Consultas `cobrosFlatQuery`, `cobrosFueraDeRutaQuery` y `cobrosDetalleQuery` extendidas con columnas de amortización y crédito. Las tarjetas de ruta muestran 'Préstamo [código]', descripción de cuota, saldo restante y amortización, deshabilitando el cambio recurrente de fecha mensual de ISP.
  · **Ficha de Cliente (`cliente_detail_screen.dart`, `contrato_providers.dart`):** Historial de pagos por contrato (`clientePagosProvider`) incluye abono a capital y saldo restante. Tarjetas de contratos cancelados muestran monto prestado y cuota en lugar de planes de internet.

- **👉 (2026-09-30) — Findex v0.45.2: Fase 2 Rework Microfinanzas / Préstamos — Consultas, Ficha de Préstamo y Desglose de Amortización.**
  · **Lista de Préstamos (`contratos_admin_screen.dart`):** Búsqueda en vivo por cliente y código (`codigo`), filtro de solo activos, tarjetas con diseño de microfinanzas mostrando monto prestado, cuota periódica con frecuencia, progreso de cuotas pagadas/totales, barra gráfica interactiva y saldo pendiente, manteniendo fallback retrocompatible a contratos ISP.
  · **Providers de Detalle (`contrato_providers.dart`):** Desacoplamiento de planes mediante `LEFT JOIN planes` tanto en `contratoDetalleProvider` como en `contratoCuotasProvider`, seleccionando campos de crédito (`monto_prestado`, `tasa_interes`, `frecuencia`, `plazo_cuotas`, `metodo_calculo`, `monto_cuota`, `total_interes`, `total_pagar`, `moneda`) y descomposición de amortización (`capital`, `interes`, `saldo_restante`).
  · **Cabecera de Préstamo (`contrato_detail_header.dart`):** Tarjeta principal adaptada para microfinanzas con grid de parámetros (desembolso, tasa, método flat/francés, cuota, plazo, total a pagar), avance porcentual amortizado con `LinearProgressIndicator` y chip de frecuencias.
  · **Cronograma de Cuotas (`contrato_detail_cuotas.dart`):** Visualización de cada cuota con desglose explícito de amortización (Capital vs Interés), saldo restante deudor tras la cuota, y soporte multi-moneda (`Fmt.monto`), preservando el flujo de cobro secuencial, multi-selección y auditoría.
  · **Detalle y Acciones (`contrato_detail_screen.dart`):** Transición segura de estados en préstamos y ocultamiento automático de "Cambiar plan" para créditos.

- **👉 (2026-09-30) — Findex v0.45.1: Fase 1 Rework Microfinanzas / Préstamos — Calculadora Integrada, Desacoplamiento de Planes y Amortización Atómica.**
  · **Rework de Contrato a Préstamo (`contrato_form_screen.dart`):** Sustituye la UI de internet/ISP por la calculadora financiera completa con selección de moneda (C$ / US$), Capital, Tasa % (mensual vs total), Frecuencia (Diario, Semanal, Quincenal, Mensual, Bimensual), Plazo en cuotas, Método de cálculo (Interés Fijo Flat vs Cuota Nivelada Francés), Fechas de desembolso y primer vencimiento, Resumen dinámico en vivo y previsualización de cronograma.
  · **Desacoplamiento de Planes:** `plan_id` pasa a ser opcional en `contratos` (migración `0274_prestamos_microfinanzas.sql`). La creación de préstamos ya no requiere crear previamente planes de internet.
  · **Generación Atómica de Cronograma:** En una sola transacción (`ps.dbW.writeTransaction`), se inserta el crédito en `contratos` y se generan e insertan las N cuotas exactas proyectadas en `cuotas`, con su desglose de capital, interés y saldo restante, auditadas en `op_log`.
  · **Servicio Financiero Puro (`prestamos_calculo_service.dart`):** Centraliza la matemática de amortización y cálculo de fechas con suite de tests completa (`test/data/services/prestamos_calculo_service_test.dart`) pasando al 100%.
  · **Lista Admin (`contratos_admin_screen.dart`):** Query ajustada a `LEFT JOIN planes` y tarjetas con información financiera (monto prestado, cuota, frecuencia y moneda).

- **👉 (2026-09-27) — Release oficial v0.45.0 a producción (`main`): Motor de Ruteo Híbrido Callejero en Mapa (OSRM online + Offline A* con Snapping).**
  · **Ruteo Callejero Preciso:** Sustituye el trazo euclidiano (línea recta) entre paradas de cobro por geometría real de calles vía OSRM con fallback offline instantáneo basado en grafo A* local (`assets/osm_graph.json`) y snapping geométrico al segmento vial más cercano.
  · **Topología de Red aislada:** Los avances de topología de red (semáforos de ocupación en NAPs, hubs y mapa de planta externa) quedan preservados en la rama `feature/red-topologia-mapa` para continuar iteración controlada sin impactar el release de cobros.
  · **Verificación:** 4/4 tests de ruteo pasando, integridad de tablas y buckets (50/15) y reglas de negocio (10/10) verificadas en verde.

- **(2026-09-05) — Release oficial v0.44.1 a producción (`main`): título de notificación de sincronización en segundo plano agnóstico de marca ("Sincronizando cartera").**
  · **Ajuste UX Android:** En `SyncForegroundService`, se reemplazó el título que exponía `'SITECSA CRM'` por `'Sincronizando cartera...'` / `'Sincronizando cartera (X%)'`, evitando redundancia con el encabezado de marca propio de cada tenant en Android.
  · **Versión previa v0.44.0:** Publicada y disponible con la optimización de 26 ms en Dashboard, ciclo 3-en-1, background sync ininterrumpido y auto-cierre de modal en cobros duplicados.
  · **Deploy:** Compilado con `build-release.ps1 -AllTenants` y publicado en `rubenmaltez/sitecsa-updates` (tag `v0.44.1`).

- **(2026-09-04, ANTERIOR) — INCIDENTE RESUELTO: el Resumen dejaba a TODA la
  app sin datos.** v0.42.0. Reportado por el dueño: al scrollear en el Resumen
  y volver, los gráficos quedaban clavados y **la lista de clientes salía en
  blanco** — la app entera, no sólo el dashboard.
  · **Tres causas, las tres MEDIDAS** contra una base local con los 51.598
    cuotas y 27.717 pagos reales de Mairena (banco de pruebas nuevo,
    `rendimiento_escala_real_test.dart`):
    1. **Los índices no se usaban.** Las consultas filtraban con
       `date(p.fecha_pago)` y `date(cu.fecha_vencimiento)`: envuelta en una
       función, la columna deja de ser indexable. **23 recorridas completas de
       tabla por pasada.**
    2. **Los providers no se apagaban.** 7 de 8 sin `autoDispose`: abrir el
       Resumen UNA vez dejaba sus consultas corriendo hasta cerrar la app.
    3. **Sin freno.** El `watch` se relanzaba cada **30 ms**; con 16 consultas
       vivas, las **5 lecturas concurrentes** de PowerSync quedaban ocupadas
       siempre y todo lo demás devolvía vacío.
  · **Resultado: 9.546 ms → 2.234 ms por pasada (−77%), 23 recorridas → 1.**
  · **`pagos.fecha_cobro` (migración 0273):** el DÍA del cobro como `date`.
    Existe porque sacar el `date()` de `fecha_pago` a lo bruto **perdía 192
    pagos por C\$152.143 en Mairena** — los del último día del ciclo, que
    comparados como texto quedan afuera. Idea del dueño, y es mejor que la
    gimnasia de rangos que yo proponía. **`fecha_vencimiento` no necesitó
    nada**: 0 de 63.207 filas tienen hora.
  · **La trampa de zona horaria, para el próximo que lea esto:** `fecha_pago`
    guarda el wall-clock local etiquetado como UTC. Derivar el día con
    `AT TIME ZONE 'America/Managua'` movería **26.178 de 34.010 pagos (77%) al
    día anterior**. Va con `'UTC'`. Ya estaba documentado en 0096 y 0214.
  · **Lo que dije mal en el camino**, porque importa para no repetirlo: dije que
    el problema era arquitectural —"análisis contra un almacén de documentos"—
    y propuse mover cuentas al servidor y apagar tarjetas. **Falso.** Medir el
    PISO lo desmintió: sumar las 51.598 cuotas cuesta **85 ms**. El JSON de
    PowerSync no era el problema; eran nuestras consultas. Lo cazó el dueño
    dudando del diagnóstico, no yo.
  · **Las cifras NO se movieron:** `mismas_cifras_tras_optimizar_test` compara
    las 9 consultas vieja-contra-nueva, columna por columna, a escala real.
  · **Un bug real que el test cazó antes de publicarse:** al updatear
    `fecha_pago` sin mover `fecha_cobro`, 7 cuotas pagadas EN FECHA contaban
    como mora. La app no tiene ese camino (nunca updatea `fecha_pago`), pero
    ahora si alguien lo agrega, salta. **INV33** lo cuida del lado del server.
  · **Tests: 885.** Commits: `0f473a6e` · `b8e0a1c2` · `2010bf13` · `c2656386`.
  · **Pendiente, con su porqué:** reportes, arqueo, `mis_cobros` y
    `cliente_detail` **siguen con `date(fecha_pago)`** — son pantallas bajo
    demanda, con su propio rango de fechas, y no son parte del incidente.
    Cambiarlas sumaba riesgo sobre consultas de dinero sin arreglar lo
    reportado. Se disparan si alguna se vuelve lenta en un tenant grande.

- **👉 (2026-09-03, ÚLTIMO) — El Resumen en el teléfono: las tablas pasan a
  "el total arriba y sus partes abajo".** **SIN PUBLICAR** (sería la v0.41.2).
  · **El pedido, en palabras del dueño:** *"que en la pantalla de un telefono se
    miren los numeros y letras de tamaño consistente con el resto de la app"*,
    con **toda la información** y **las mismas dos tablas**.
  · **La causa de fondo, MEDIDA (no estimada):** a 360px la tabla dispone de
    **312px** y las cinco columnas necesitan **287** sólo de números y
    separadores. Quedan **25px** para un rótulo que necesita 84 → el `FittedBox`
    dibujaba el monto al 34%, **4,8px**. **Ninguna variante de la GRILLA lo
    arregla**: hay que cambiar de forma. Medido con la Roboto real cargada por
    `FontLoader` — ojo, la fuente por defecto de `flutter_test` es Ahem y da
    todos los glifos del mismo ancho: medir con ella es medir cualquier cosa.
  · **Cuatro criterios se probaron y se descartaron antes**, y ése era el
    problema de fondo: nunca se eligió entre ellos y quedaron **dos vivos, uno
    en cada tabla** (ocultar el % · el monto en segunda línea · una tarjeta por
    fila · abreviar los encabezados).
  · **Lo que quedó:** el total de titular con su **barra de composición**, y
    cada parte con su monto, su % y sus conteos rotulados con la palabra al
    lado. Un solo archivo — `bloque_parte_y_todo.dart` — para las **TRES**
    tablas (Cobertura, mora y "Quién cobró", que el barrido encontró con el
    criterio viejo). Sin `FittedBox` y **sin inventar tamaños**: sólo roles de
    `TxtResumen` que ya existían. **En PC no cambia nada.**
  · **La barra se dibujaba con altura CERO y lo encontró el RENDER, no un
    test.** Un `ColoredBox` sin hijo toma `constraints.smallest` y un `Row` da
    la altura floja: la barra existía, con sus flex correctos, invisible. Los
    tests contaban widgets y medían flex — todos estaban. **Regla nueva: para
    juzgar layout hay que MIRARLO**; se capturó el widget a PNG con la Roboto y
    los íconos cargados.
  · **Tests: 874** (eran 853). Dos archivos que miden a 360px, y el del bloque
    usa los montos de **siete dígitos** de Mairena porque el escenario tiene de
    cinco (regla 16). Los 🔴 verificados contra el código roto.
  · Commits: `a3edf688` · `98fd5a3e` · `af438e10` · `6e565150` · `9002ef79`.
  · **De paso, dos bugs que nadie había reportado:** la barra de mora no abría
    el globo al TOCAR (sólo `onHover`, que en Android no existe), y adentro del
    globo el número se **pintaba fuera de la caja** con montos de siete dígitos
    — eso pasaba **también en PC**, porque el globo medía 208px fijos.

- **👉 (2026-09-03, ÚLTIMO) — El panel de los filtros entra en la pantalla.**
  Reportado desde Android por usuarios de un tenant. **SIN PUBLICAR.**
  · **El panel se anclaba SIEMPRE por la izquierda del chip**, con hasta 340px
    y sin mirar dónde estaba el chip. Con **"Plan"** —el ÚLTIMO de la barra de
    Cobros, o sea el más a la derecha— se cortaba: los usuarios veían
    "COMBO INTER…" y "2.014,00 C\$ · 1 clie…".
  · **NO era del chip nuevo: era del componente compartido.** Cobrador y Zona
    nunca lo mostraron porque están a la izquierda y ahí sobra lugar. El
    arreglo va en `FiltroMultiDropdown`, así que cubre los **cuatro** chips en
    las **cinco** pantallas que lo usan (Clientes, Cobros, Mapa, Rutas y la
    barra compartida).
  · **Es la MISMA lección del globo de la curva, el mismo día: anclar sin
    acotar.** Un widget anclado a otro no se queda dentro de la pantalla solo.
    Van dos en una jornada; vale como patrón a revisar en cualquier overlay.
  · Ahora se mide el espacio real a cada lado del chip: si por la derecha no
    entra y por la izquierda hay más, el panel **se ancla por la derecha** y
    crece hacia adentro. En los dos casos el ancho se clampea a lo disponible.
  · **Test verificado en los dos sentidos**: contra el código viejo falla
    diciendo *"termina en 589.0 y la pantalla mide 360"*. Con contraprueba a
    1200px para que el arreglo no encoja el panel donde hay lugar. **853 tests.**

- **🔴 (2026-09-03) — ABIERTO, es lo más urgente: usuarios reportan el Resumen
  lento o EN BLANCO.** Sin resolver, sin causa confirmada.
  · **Contexto que enmarca el riesgo:** v0.37.1 tenía **5 archivos** de
    dashboard; v0.41.0 tiene **16**. El Resumen se reconstruyó entero y **le
    llegó por primera vez a Mairena y Telenet hoy**. Encima la `0266` encendió
    `operativo` y `distribucion` para las dos, tarjetas que **nunca habían
    corrido contra sus datos**.
  · **Descartado con evidencia:** (a) NO es la `0266` en versiones viejas —
    v0.37.1 ni siquiera tiene `dashboard_tarjetas.dart`, no lee ese setting;
    (b) NO es la `0269` — metió el valor `cambio_plan` en `origen`, que las
    versiones viejas nunca vieron, pero sus dos `switch` tienen `_ =>`.
  · **Palanca inmediata, sin release:** apagar de nuevo `operativo` y
    `distribucion` para Mairena y Telenet. Es un cambio de settings, llega por
    sync en segundos, y parte el problema al medio. **Propuesta al dueño,
    esperando su OK.**
  · **Falta el caso concreto:** qué empresa, qué usuario, qué versión, y si es
    celular o PC. "Blanco total" puede ser la pantalla entera o el Resumen
    dentro del shell, y son diagnósticos distintos.
  · **También reportado, secundario:** las tablas del Resumen no siguen el
    esquema responsive en celular (encabezados cortados "U…"/"C…", montos que
    bajan de línea) y las barras de la mora de 6 ciclos no abren el globo al
    tocarlas — el `onTapUp` se retiró el 2026-09-02 y el (i) todavía dice que
    hacer clic salta al ciclo.

- **(2026-09-03) — Entrar a una empresa espera el sync completo.**
  Commit `bea774db`. **SIN PUBLICAR** (la v0.41.0 instalada no lo tiene).
  · **Las dos quejas del dueño eran el MISMO número.** Reportó (a) que al
    impersonar *"me hace una transición que me permite entrar al app sin nada
    cargado y yo como dev necesito ver data"* y (b) que el Resumen seguía lento
    *"cuando se supone que el sync ya descargó todo"*. La causa única:
    **`syncGateGraceProvider` abría el gate a los 8 SEGUNDOS**, terminara o no.
    Impersonar baja la empresa entera (~190.000 filas en Mairena) y en 8s entra
    una fracción → app vacía; y el resto seguía bajando, con cada lote
    re-disparando las consultas `watch` del Resumen, que nunca resolvían.
  · **Lo irónico: el plazo existía POR ese caso.** Su comentario decía que era
    para evitar "esperar minutos con DB vacía / sync inicial lento del
    super_admin". Se había cambiado una espera larga por una app vacía.
  · **Fix:** `AuthIdentityState.entrandoATenant` (sólo lo pone
    `onImpersonationChanged`) desactiva el plazo. Un LOGIN normal sigue
    liberando a los 8s — el plazo protege al cobrador y eso no se toca; hay
    contraprueba en el test. Seguro porque `SyncGateScreen` ya muestra progreso
    REAL y ofrece salidas a los 2 y 3 minutos. **Se paga una vez por empresa:**
    al reingresar sólo bajan los deltas, medido y aceptado por el dueño.
  · **851 tests.** El nuevo verificado en los dos sentidos.
  · **🔴 LO QUE NO SE HIZO, y por qué — leer antes de retomarlo.** Estaba
    aprobado filtrar por `tenant_id` las 16 consultas de `dashboard_query.dart`
    (opción A). **Se frenó al medir que el tenant System tiene CERO clientes,
    contratos, cuotas, pagos y recibos**: cuando el sync termina de verdad, el
    SQLite del super_admin queda con UNA sola empresa, así que la mezcla sólo
    existía durante la ventana de transición — que es la que este mismo fix
    cierra. Hacer A a mano sobre 16 consultas con parámetros POSICIONALES y
    subconsultas correlacionadas es donde se cuelan los errores silenciosos.
    **Sigue siendo deseable como refuerzo**, pero con un test que siembre DOS
    empresas y verifique que los números no se mueven — ese test no existe y es
    lo único que la vuelve segura.
  · **Pendiente relacionado (opción C, no urgente):** el bucket
    `impersonated_tenant` baja 38 tablas, incluidas **36.786 filas de `op_log`**
    en Mairena que ninguna pantalla del Resumen usa. Sacarlo acortaría la espera
    ~20%. Requiere deploy de sync rules al VPS.

- **(2026-09-03) — El globo del gráfico se dibuja ENCIMA de la
  leyenda, y deja de cortar su rótulo.** Reporte del dueño con captura.
  Commit `fead6a96`. **SIN PUBLICAR: la v0.41.0 instalada NO lo tiene.**
  · **Lo reportó como "el fondo del tooltip es transparente" y no era eso.** El
    globo mide ~196px contra los 180 del gráfico, se desborda hacia abajo, y la
    leyenda era **hermana POSTERIOR** en la misma Column: en Flutter el hermano
    de después se pinta encima. Se leía igual que una transparencia.
  · **Es el mismo bug que ya se arregló una vez en el eje HORIZONTAL** —el
    globo se salía por los costados y se clampeó, con su comentario y todo— y
    que quedó abierto en el vertical. Y los renglones que lo hicieron crecer
    (acumulado del ciclo + de otros ciclos) se agregaron ESE MISMO DÍA.
  · **Decisión del dueño: NO achicar el globo**, porque perdería información.
    *"El tooltip sólo se pone encima de la interfaz y que lo que queda en el
    background se tape mientras se haga el hover"*. La leyenda pasó a vivir
    DENTRO del mismo `Stack` y el globo quedó último.
  · **El rótulo a dos líneas**: "Acumulado del ciclo" salía como "Acumulado del
    cic…" — el renglón más importante era el único ilegible. No deja el monto
    huérfano porque en el globo cada dato tiene su columna en la `Table`. Se
    descartó ensanchar el globo: lo acercaría otra vez a los bordes.
  · **Test de regresión verificado en los dos sentidos.** Ojo con el finder:
    `find.text('Recuperado')` matchea TAMBIÉN una fila de la tabla, y con eso
    el test daba rojo con el bug ya arreglado. Se busca por 'Meta del ciclo',
    que sólo existe en la leyenda. Es la trampa que ese mismo archivo advierte.
  · **847 tests**, 10/10 reglas.
  · **🔴 PAUSADO, y es lo más grave abierto:** el dueño reportó que el Resumen
    tarda y se queda girando al impersonar Mairena. Diagnosticado, sin tocar
    nada: (a) las **48 consultas de `dashboard_query.dart` NO filtran
    `tenant_id`** —verificado también en producción v0.37.1, o sea que es de
    antes— y el SQLite del super_admin NO es mono-tenant, así que **los números
    pueden estar mezclando empresas** (regla §1 del AGENTS); (b) el bucket
    `impersonated_tenant` baja las 38 tablas —~190.000 filas para Mairena, de
    las cuales 36.786 son `op_log` que el dashboard nunca usa— y mientras eso
    escribe, cada lote **re-dispara todas las consultas `watch`** del Resumen,
    así que ninguna llega a terminar. Propuesto: (A) filtrar por empresa las 48
    consultas, (B) sacar `op_log` del bucket. Espera decisión.

- **(2026-09-03) — Filtro por plan en Clientes, Cobros y Mapa + el
  tipo de plan se elige a propósito.** Pedido de Rubén, antes del release.
  Commits `46b39799` → `0e4f1708`. **846 tests, 10/10 reglas, 15/15 buckets.**
  · **Lo que casi arruina el diseño, y era un error MÍO:** propuse agregar una
    columna `tipo` al catálogo de planes con toda una argumentación sobre lo
    frágil que es adivinar el tipo del nombre. **La columna ya existía** —NOT
    NULL, con CHECK de tres valores, y el formulario ya la escribía—. Consulté
    las columnas de la tabla, la salida se cortó, no la leí, y armé el
    razonamiento sobre una premisa falsa. Rubén lo cazó con una captura.
  · **El formulario** ya no preselecciona "Internet": arranca vacío y valida.
    Como la columna es NOT NULL el form nunca fallaba, así que un combo creado
    sin tocar el desplegable se guardaba como internet EN SILENCIO.
  · **Migración `0271`**: tres planes mal marcados. `Promo 1 Catv Gratis`
    (C$916 = el precio EXACTO de `Internet 20MB`, o sea internet + cable de
    regalo) y `Promo 3 Internet Gratis` (C$513 = el de `Catv`) pasan a combo.
    Sin eso, esos 25 clientes de Telenet no aparecían al filtrar por Combo.
    Los otros 3 desacuerdos quedan como están **por decisión del dueño**: el
    nombre no da ninguna pista y sólo Telenet sabe qué incluyen.
  · **Avisos al editar un plan**, uno para cada caso opuesto: renombrar
    reescribe lo que dicen **33.949 recibos ya entregados** (los que resuelven
    el nombre por JOIN vivo; el congelado de `0268` recién entró) y se dice con
    el número exacto; cambiar el precio NO toca las cuotas ya generadas y se
    aclara, porque el 95% de los contratos son indefinidos y subir ese precio
    ES el mecanismo del aumento de tarifa. Ninguno de los dos bloquea.
  · **Las tres pantallas NO comparten barra de filtros** — cada una la tiene
    hecha a mano y la única que usa `FiltrosBar` es Inventario. Lo compartible
    es el SQL de opciones y su armado (`shared/widgets/filtro_planes.dart`).
  · **Reglas cerradas:** un plan aparece si algún contrato lo usa (el `activo`
    no participa) · el filtro mira el plan de HOY · opción centinela "Sin plan"
    (96 clientes sin contrato activo en producción) · el chip va último.
  · **Regla 16, otra vez:** el generador Dart no sembraba `planes` ni ponía
    `plan_id`. Ahora siembra 4 planes con los tres tipos y dos que comparten
    nombre. El primer test del grupo verifica que el escenario TENGA planes
    antes de medir nada — y ya pagó: contra el seed viejo falló ahí en vez de
    dar cuatro verdes vacíos.
  · **Pendiente conocido:** el rol `coordinador` (0 usuarios hoy) ve el chip
    pero su bucket de sync NO baja `contratos`, así que le queda sin opciones.
    Para que le funcione hay que agregar `contratos` a `por_coordinador` — un
    deploy de sync rules, decidido para cuando exista el primer coordinador.

- **(2026-09-03) — AUDIT de la v0.40.0 y los 4 fixes que salieron
  de él.** Pedido de Rubén: *"un audito de la app, un audito de codigo,
  conexiones robustas entre tablas, UI y UX"*. **Nada publicado todavía.**
  Commit `40c48e4a` (+ el de cierre de docs).
  · **Lo que el audit encontró y NINGÚN invariante podía cazar:** los dos
    hallazgos graves no violan una regla de dinero, sólo **dicen algo falso**.
    Los 31 chequeos × 4 tenants dieron **1 sola violación** (INV11 en Mairena =
    3, la limpieza manual del cuaderno de agosto) y las uniones entre tablas
    **10 de 11 en cero**, incluidas las dos de fuga multi-tenant.
  · **Fix 1 — la gráfica no seguía a su selector.** `mora_ciclos_card` armaba
    las barras con `_mesHoy` (ancla fija) mientras el stream, el rótulo y el
    Excel usaban `_mesFin`. Se arregló el Excel el 02/09 y quedó mintiendo la
    gráfica de al lado. **Test de regresión nuevo** que compara encabezado vs
    etiquetas del eje X — verificado que FALLA contra el código viejo (regla 15b).
  · **Fix 2 — un cambio de plan reabría una cuota ya pagada.** Contrato `0986`
    de Mairena: C$513 cobrados el 25/08 con recibo **RE-01069**, y el cambio del
    28/08 la dejó debiendo C$49,61. **Decisión del dueño:** si la cuota del ciclo
    está saldada, el cargo va a la SIGUIENTE; si no hay siguiente, no se cobra y
    queda dicho en el `op_log`. Avisan el diálogo y la tarjeta del aprobador.
    **La fila rota se resolvió sola** mientras se auditaba (alguien bajó el
    `monto` a 463,39): las 3 cuotas con cargo de cambio de plan y pago quedaron
    en saldo 0. **No se corrió migración correctiva** — habría roto datos sanos.
  · **Migración `0269`** (corrida y verificada): los 8 cargos de cambio de plan
    anteriores a `0267` tenían `origen='cobro'`, y el guard que impide borrarlos
    mira `origen` → **C$1.175,27 de cartera de Mairena seguían borrables con la
    papelera**. Sólo cambia `origen`; montos y `cargos_neto` idénticos (INV14=0).
  · **Migración `0270`** (corrida y verificada): el bloque "Cambio de plan" del
    recibo se imprimía **después del total** en los tres tenants (`fromRaw`
    completa al final de la zona los bloques que un layout guardado no nombra).
    Se arregló **el dato**, no la generación del recibo. Orden hoy en los tres:
    `servicio → cambio_plan → cuota → totales → mora`.
  · **Hallazgo propio, sin resolver:** `app_dispositivos` tiene 38 filas y
    **ninguna es de un cobrador** (0 de 8). Son **5.582 recibos** desde equipos
    que el registro nunca vio. RLS descartada empíricamente. La causa es que la
    telemetría va directa por Supabase (no por la cola que reintenta), dispara
    una vez por proceso con el flag puesto ANTES del await y se traga el error:
    el cobrador arranca en la calle sin señal y se pierde. **Queda pendiente.**
  · **Dos números míos que corregí en el camino:** (a) reporté "1 cargo de
    cambio de plan" filtrando por `origen`, la columna que **sólo llena el
    código nuevo** — eran 8; (b) reporté "0 warnings" sobre un archivo que tenía
    sólo las últimas 25 líneas del `analyze`. El real: 32 infos + 1 warning
    (`unreachable_switch_case`, **preexistente**, ver Backlog).
  · Estado: **837 tests OK**, 10/10 reglas, 15/15 buckets, `analyze` con 1
    warning preexistente. Reporte visual completo en el artifact del audit.

- **(2026-09-03) — CHECKPOINT: todo consolidado en `main`, listo
  para release.** Pedido de Rubén. **Nada publicado todavía.**
  · **`main` = `9d2086a6` = v0.40.0**, local y en GitHub. Eran 83 commits por
    delante; el merge fue **fast-forward** (main era ancestro).
  · **🔴 Lo que el checkpoint destapó y era el riesgo real:** el commit de
    producción (`7c49277f`, v0.37.1) **NO era ancestro de `main` ni de la rama
    de trabajo** — el release se hizo en su propia rama y nunca volvió. Si se
    publicaba desde la rama sin mirar esto, cualquier fix hecho en la línea de
    release se perdía en silencio.
    **Verificado por CONTENIDO, no por el grafo:** los tres fixes de esa línea
    están en main — el permiso de `admin_usuarios` para Cambiar plan
    (`puedeVerCambiarPlan`), la regla de cancelación (`cancelarContrato`) y el
    buscador de planes (`selector_buscable.dart`, idéntico). El único archivo
    ausente es `mora_historica_card.dart`, que el rework reemplazó por
    `mora_ciclos_card.dart` y que en producción sólo usaba la pantalla vieja.
  · **Producción NO tenía tag.** Sólo existía como rama. Se creó el tag
    **`v0.37.1`** sobre `7c49277f` y se empujó, para poder volver a la versión
    viva sin depender de una rama (política de AGENTS: hitos = tags).
  · **Ramas borradas** (contenido 100% en main): `claude/app-status-79c6d7`,
    `claude/sync-local-github-a0fdd0`, `feature/dashboard-mora`,
    `release/v0.36.5`, `release/v0.36.6`, `release/v0.37.1`. Las dos remotas
    que existían (`feature/dashboard-mora`, `release/v0.36.6`) también.
  · **`feature/whatsapp-mora-meta` NO se borró:** tiene **5 commits que main no
    tiene** (2026-08-25, refactor a Meta-only). **Y trae una migración `0260`
    que COLISIONA** con la `0260_desactivar_cliente_cancela_y_condona.sql` de
    main. Al retomarla hay que renumerarla a `0269+` antes de mergear.
  · **Migraciones:** `0267` y `0268` corridas y verificadas. **La `0266` sigue
    SIN correr** y va CON el release — enciende `operativo` y `distribucion`
    para Mairena y Telenet, y correrla antes les mostraría una grilla que su
    app instalada dibuja distinto.
  · Estado: 834 tests, 10/10 reglas, `analyze` limpio (5 infos preexistentes).
    Plata del Test Tenant intacta: 248 pagos, C$176.896,67.

- **(2026-09-02 e) — el globo con el acumulado de mora, y el aviso
  de deuda del cambio de plan dice de qué meses es.** Sin publicar. Build de
  prueba **v0.39.6**.
  · **El globo del gráfico** suma un renglón "de eso, de mora" con su conteo,
    sangrado bajo "Acumulado". **No cuesta una consulta**: es la misma serie
    que dibuja la línea roja. Va sangrado porque **es un subconjunto**,
    verificado contra la base con el predicado de la tarjeta — C$4.990 de
    C$21.100, 7 de 30 pagos. Al mismo nivel se leería como algo que se suma.
    **Se descartó mostrar los dos porcentajes**: no comparten denominador (meta
    del ciclo vs total en mora) y compararlos no significa nada.
  · **El aviso de deuda del cambio de plan** lista los meses con su saldo, del
    más viejo al más nuevo. El dato ya estaba en la consulta y se descartaba.
    El rótulo sale de `Fmt.mesServicioLabel` (anclado al `dia_pago`), no del
    mes calendario: con `dia_pago = 28` los dos difieren y el aviso nombraría
    un mes distinto al del bloque de abajo.
  · **Consulta de Rubén, contestada con números:** por qué el prorrateo va
    sobre la DIFERENCIA de los dos planes. Porque no re-abre lo ya facturado.
    Re-derivar la cuota por tramos da **877,85 contra 846,67 — 31,18 de más**,
    y esa diferencia no es servicio: el ciclo 28/08→28/09 pisa dos meses de
    distinto largo, así que la suma diaria del plan viejo sobre el ciclo da
    **531,18 y no 500**. Con el método de la diferencia, la convención
    "precio ÷ días de su mes" sólo toca el delta, nunca la base.
  · **🔴 PENDIENTE que dejo escrito en vez de fingir:** el diálogo de cambio de
    plan **no tiene NINGÚN test de widget**, y el harness que intenté armar se
    cuelga al montarlo (queda en *"did not complete"*, ~4 min por test).
    Sospecha: `runAsync` + los providers de sesión que el diálogo lee en
    `_cargar`. No dejé el test colgado en la suite. **Lo dispara**: cualquier
    cambio siguiente en ese diálogo — es la pantalla que mueve plata con menos
    red de todo el repo.
  · Commits: `860b0384` · `a64c723d`.

- **(2026-09-02 d) — las 4 tarjetas del Resumen vuelven al estilo de
  producción, y encendidas.** Pedido de Rubén, **sin publicar**.
  · **El pedido, textual:** *"Proyección de cobros, Recuperación por cobrador y
    comunidad, Estado actual y Distribución de cuotas tienen que regresar al
    estilo anterior y habilitadas"*, más *"el excel solo era para distribución
    de cuotas y para mora de 6 meses; el resto se mantiene solo la gráfica y el
    (i)"*.
  · **🔴 Lo primero fue entender qué mostraban las capturas.** Eran de
    **Mairena EN PRODUCCIÓN (v0.37.1)** — confirmado con el dato, no de ojo:
    4.474 clientes activos coincide EXACTO con Mairena y con ningún otro
    tenant. O sea que Rubén no reportaba un bug: mostraba el estilo que quería
    de vuelta. Sin ese chequeo, el pedido se lee como "arreglá esto".
  · **Qué vuelve:** barras por cobrador + switch en Proyección · el rótulo
    "Recuperación" · la grilla de KPI cards en Estado actual · Distribución
    como tarjeta propia y encendida. **El layout es el viejo; la tipografía es
    la nueva** (`TxtResumen`) — Rubén eligió esa combinación entre las dos
    opciones, para que el Resumen no quede con dos lenguajes visuales.
  · **El Excel** queda SOLO en Cobertura del ciclo y Mora de 6 ciclos. Su frase
    describe producción al pie: verificado, `dashboard_admin_screen.dart` en la
    v0.37.1 tiene **cero** botones de descarga. Se le sacó también a "Quién
    cobró" — no estaba en su lista, pero la tarjeta que reemplazó tampoco lo
    tenía y él confirmó aplicar la regla al tablero entero.
  · **Dos cosas volvieron A SABIENDAS y quedaron escritas** en el código, en la
    migración y en ARQUITECTURA, para que nadie las "arregle":
    **(a)** Estado actual y Distribución muestran los MISMOS números
    (20.065 + 746 + 2.563 = 23.374 = "Cuotas por cobrar"; "En mora" 2.563 =
    "Vencidas"). Se le planteó con sus propios números y eligió las dos igual.
    **(b)** "Recuperación" se había renombrado porque el rótulo mentía; se le
    ofreció "Por recuperar…" y eligió el nombre viejo.
  · **🔴 Una regresión que cazó la suite, no el ojo:** la primera versión de
    `mora_zona` restauraba la clase de producción ENTERA y perdía el modo
    compacto de teléfono — **desbordaba 235px a 360**. Se revirtió a la versión
    que ya funcionaba y se aplicaron solo los dos cambios pedidos. Lección: al
    "restaurar" un archivo, restaurar lo que se PIDIÓ, no el archivo entero;
    lo que se agregó en el medio puede ser lo único que lo hace usable.
  · **Un error mío que conviene no repetir:** tomé `3adcfcc6` como "producción"
    y no lo es — la v0.37.1 es `7c49277f` ("vuelve el Resumen anterior"), y ni
    siquiera desciende del otro. Lo detecté y comparé clase por clase: tres de
    las cuatro son IDÉNTICAS entre los dos commits, y la cuarta difiere en un
    comentario y en un `onTap` que Estado actual nunca usó. O sea que no cambió
    el resultado — pero fue suerte. **Al buscar "cómo era en producción", partir
    del commit del RELEASE, no del anterior al rework.**
  · **Un hallazgo del panel que se cayó al verificarlo:** una agente reportó,
    con evidencia de la base, que Proyección no puede verse en producción
    porque su gate depende de `dashboard.pendientes_visible`, que **no existe
    en ningún tenant** (cierto: 0 filas). Pero eso vale para `3adcfcc6`; en
    `7c49277f` ese gate fue eliminado. Correcto sobre el código que miró, falso
    sobre el que importa.
  · **Migración `0266` AMPLIADA, no apilada:** nunca corrió en ningún tenant
    (el Test Tenant se prendió a mano), así que extenderla para encender
    también `distribucion` deja UNA verdad en vez de dos migraciones que se
    leen como si pelearan. Renombrada a
    `0266_dashboard_tarjetas_del_resumen_viejo.sql`. **Sigue SIN correr**: va
    con el release, junto con el código.
  · **Tests:** 818 en verde. Se reescribieron los 9 que custodiaban el diseño
    fusionado; el de alineación de "Estado actual" se reemplazó por uno que
    mide lo que SÍ manda en una grilla — cuántas columnas arma a cada ancho
    (1 / 2 / 3) — y se verificó que falla si se rompen los cortes.
  · **SEGUNDA PASADA (misma fecha):** Rubén miró el build y avisó que
    Recuperación *"también tiene que regresar a como está actualmente en
    producción"* — y que faltaba **habilitar** Distribución.
    **(a) Tenía razón y yo había entregado la mitad:** le cambié sólo el rótulo
    y el Excel, y dejé el cuerpo del rework. Mi motivo fue que el primer
    intento desbordaba 235px en teléfono; eso explica la decisión pero no la
    justifica — entregar la mitad porque la otra es difícil es justo lo que la
    regla de oro §3 prohíbe. Ahora vuelve entera: encabezado colapsable con el
    total, los dos ChoiceChips ("Vencidas del **período**", decía "del ciclo")
    y la lista de tres niveles con su línea "Coincide".
    **(b) Distribución no se veía y el motivo NO era el código:** el Test
    Tenant tiene el ajuste `dashboard.tarjetas` GUARDADO con
    `distribucion: false`, y el ajuste guardado le gana al default del código.
    Se prendió a mano en el Test Tenant (verificado por contenido: 8 on / 3
    off). Mairena y Telenet los enciende la `0266` con el release.
    **(c) Un desborde REAL que estaba en producción:** la fila de los dos chips
    mide ~328px y en un teléfono de 360 quedan 320 útiles. Nadie lo vio porque
    el Resumen se mira en PC. Resuelto con `Wrap`.
    **(d) La fuente de test volvió a mentir:** reporté 70px de desborde que no
    existían. Con NotoSans cargada, cero a 360/800/1900. Es la SEGUNDA vez hoy
    que este artefacto me hace diagnosticar mal — ya está escrito en dos tests.
  · **TERCERA PASADA:** Rubén vio que *"hay algunas opciones que no tienen
    dropdown y no sé de cuánto es la cantidad de las que consiste"*. Bug mío:
    al reescribir el cuerpo traje del rework la condición `tramos.length > 1`,
    que oculta la flecha cuando la comunidad tiene un solo monto. Producción no
    tiene condición. **El argumento de esa condición era falso** —"abrirlo
    repetiría la fila"— porque la fila dice el total y la cantidad, nunca el
    monto UNITARIO.
  · **🔴 Y ahí apareció lo más importante del día: los DOS GENERADORES DE
    ESCENARIO habían divergido.** `generar_seed_sql.py` sembraba comunidades y
    `generar_seed_dart.py` **cero**, así que en el escenario de los tests la
    consulta agrupaba todo en un solo "Sin comunidad" y **cualquier test sobre
    los tres niveles de esa tarjeta pasaba sin medir nada**. Lección 16 de
    AGENTS al pie: escribí el test, pasó contra el código CON el bug, y sólo al
    instrumentarlo apareció que había UNA comunidad en vez de siete. Cerrado —
    el generador Dart ahora siembra `comunidades` y `clientes.comunidad_id`.
    Además se movió `PB-43` a una comunidad propia ("El Naranjo") para que
    exista el caso de UN SOLO TRAMO: sin él el test tampoco discriminaba. No
    altera ningún total, y las 828 pruebas lo confirman.
  · Commits: `c44d64a2` · `570e247d` · `871a4b11`. 828 tests, 10/10 reglas.

- **(2026-09-02 c) — la columna USUARIOS vuelve a contar PERSONAS,
  y las cuatro columnas entran sin cortarse.** Pedido de Rubén, **sin publicar**.
  Build de prueba **v0.39.1** instalado en la PC.
  · **Qué pidió:** una columna de usuarios en las dos tablas de Cobertura del
    ciclo, *"sin texto explicativo — en tenants grandes eso puede ser demasiado
    contexto visual"*, con **data real por ciclo que haga match con el Excel**.
    Después: que las columnas no se entrecorten, que el % diga solo `%` y que
    `Usuarios` se vea completa.
  · **🔴 La decisión de fondo, que ya se dio vuelta DOS veces** — ficha nueva
    `docs/reglas/conteo-usuarios.md`, creada justo para que no haya una tercera.
    En agosto contaba personas, el dueño vio *"más cuotas que usuarios"* y se
    cambió a CONTRATOS para que cuadrara. Ahora explicó **para qué** la usa:
    *"si veo más cuotas que usuarios, reviso si por accidente alguien tiene dos
    contratos"*. Contando contratos eso es **imposible de ver**: da 1:1 siempre,
    por construcción. **La diferencia no es un descuadre, es EL DATO.**
    Medido antes de tocar: Mairena 4.409 personas contra 4.414 cuotas = cinco
    clientes con CATV + COMBO, todos legítimos; Telenet 1; Test Tenant 4.
  · **Lo que el barrido de superficies encontró, y es el motivo de que exista:**
    el **Excel seguía contando SERVICIOS** cuando la tarjeta ya contaba
    personas. Su fila de cierre habría dicho **4.414 contra 4.409 en pantalla**
    — dos números creíbles que se contradicen, sin que nada falle. Es la misma
    contradicción que el comentario del export advertía, **dada vuelta**.
    Corregido, con test que compara contra el número que el archivo REALMENTE
    escribe (falla contra el export anterior: pedía 55 y el archivo decía 57).
  · **Las columnas cortadas:** con las dos tablas lado a lado cada una mide la
    mitad, y el `maxLines: 1` que alineó las cabeceras el día anterior corta en
    vez de envolver — Rubén fotografió `Usuar…`, `% de las 56 cu…`. El `%` pasa
    a decir solo `%` y baja de flex 2 a flex 1: lo más ancho que aloja es
    `100%`, no una frase, y ese ancho es justo el que le faltaba a `Usuarios`.
    El denominador no se pierde: es la fila `Cobros` de la misma tabla.
  · **🔴 Lección que cuesta y conviene no repetir: un test de recorte sin
    fuente cargada MIENTE.** En un widget test sin fuentes, Flutter usa una
    fuente donde cada glifo mide `fontSize` × `fontSize`: `Cuotas` da 75px a
    12,5 contra ~42 reales. El test marcaba como cortado hasta lo que entra de
    sobra. Se resolvió cargando **NotoSans** —la que la app ya embebe para los
    PDFs— con `FontLoader` en el tema del test. Es un PROXY (en Windows la
    pantalla usa Segoe UI), sirve para holgura, no para el pixel. **El test
    ahora falla contra el código viejo**, que es lo único que lo separa de la
    decoración.
  · **Migraciones `0267` y `0268` CORRIDAS y verificadas** contra `vxxz`
    (producción) para poder testear. Las cuatro comprobadas por CONTENIDO;
    la plata intacta (26.590 pagos, C$23.494.710,30). **La `0266` sigue sin
    correr a propósito**: le mostraría la grilla de KPIs vieja a Mairena y
    Telenet, que no la pidieron. Va con el release.
  · **Falta:** que Rubén lo mire. **No pude verificarlo yo**: el Resumen pide
    PIN y no ingreso PINs ni contraseñas.
  · Commits: `b33b7e23` (columnas) · `89cd657d` (fuente real en el test) ·
    `e2c018c1` (el Excel cuenta personas) · `470f8b38` (ARQUITECTURA) ·
    `dce565df` (v0.39.1). 817 tests en verde, 9/9 reglas.

- **(2026-09-02 b) — el Resumen: la tabla de mora sube a Cobertura
  y la curva de mora marca sus días.** Pedido de Rubén, sin publicar.
  · **Por qué:** había DOS selectores de ciclo en la misma pantalla —el de
    Cobertura y el de Mora— y podían quedar en meses distintos mirando lo mismo.
    Ahora uno solo manda sobre la curva y las dos tablas.
  · **El cálculo NO cambió**, y se verificó antes de tocar: las dos tarjetas
    resolvían su rango con las MISMAS funciones y sus guards de navegación dan
    el mismo resultado con el corte 15→14.
  · **Lo que el test destapó y el ojo no:** las dos tablas comparten los rótulos
    `Recuperado` y `Por recuperar` —el vocabulario único que Rubén pidió el
    2026-08-27— así que lado a lado esas palabras aparecían dos veces con
    significados distintos. Se resolvió con encabezados: **"COBERTURA DEL CICLO"
    y "COBERTURA DE MORA"** son lo único que las separa.
  · **Efecto lateral que conviene saber:** el Excel de mora pasa a exportar la
    misma ventana que dibujan las barras. Antes tomaba el ciclo del selector, o
    sea que podía exportar 6 ciclos terminando en julio mientras las barras
    mostraban los últimos 6 — contra su propio principio de "el archivo trae lo
    que la pantalla muestra".
  · **8 tests nuevos, verificados contra el código viejo: 6 de 8 fallan ahí.**
    Es lo único que los vuelve una red y no decoración (lección 15b).
  · Commits `a302a1e2` (los puntos rojos) y `2398d993` (la mudanza).

- **👉 CHECKPOINT (2026-09-02, ÚLTIMO) — el cambio de plan: el prorrateo que se
  entiende, el recibo que lo explica y el aprobador que ve el número. NADA
  publicado: producción sigue en v0.37.1.**
  · **De dónde salió:** Rubén preguntó cómo funciona hoy el cambio de plan.
    Mapeando la feature aparecieron tres cosas que mentían, y de ahí el sprint.
  · **LO QUE ARRANCÓ TODO — "el cálculo es muy confuso".** La pantalla decía
    *"+C$245,16 por los 25 días que faltan"* y no contestaba **bajo qué plan** se
    prorratea ni **a qué período** se suma. Investigándolo apareció la razón de
    fondo, que no estaba escrita en ningún lado: **el cambio de plan es el único
    de los tres flujos que prorratean que MEZCLA** mes nominal con suma
    día-a-día (suspender REEMPLAZA el monto; el puente cobra días que ninguna
    cuota cubre). La convención del precio-por-día se decidió el 2026-06-14
    **para el puente**, que no tiene cuota detrás; nunca se decidió cómo valuar
    un ciclo que ya tiene una cuota nominal encima. De ahí sale un hueco que
    **oscila entre −25,92 y +25,92** contra el modelo "mitad y mitad".
    **Decisión de Rubén: NO se toca el cálculo** (opción B, no C) — se explica
    el número que efectivamente se cobra.
  · **QUÉ ENTRÓ, en una línea cada uno:**
    · **el prorrateo se desglosa por mes** — no existe un precio por día único
      (junio vale 10,0000 y julio 9,6774), así que la pantalla muestra un
      renglón por mes y la cuenta cierra a mano. Pedido explícito de Rubén;
    · **el cargo tiene identidad propia** — `origen='cambio_plan'` + `detalle`
      con la transición completa, porque ese dato **no se puede reconstruir
      después**: el contrato ya apunta al plan nuevo;
    · **el recibo explica la transición** — bloque nuevo en los tres renderers,
      visible por defecto, y en la BAJADA le avisa al cliente el crédito, que
      hasta hoy no aparecía en ningún comprobante. **Sin** desglose diario: eso
      es para quien autoriza, no para el cliente (decisión de Rubén);
    · **el recibo congela el plan** (`0268`) — espejo de `0262`. Cada uno de los
      37 cambios de Mairena venía reescribiendo **en silencio** el plan que
      decían todos los recibos anteriores de ese contrato;
    · **el aprobador ve el monto** — firmaba un cargo sin haberlo visto nunca; el
      cálculo ni se invocaba en esa pantalla. Se computa EN VIVO con el mismo
      helper que la mutación;
    · **el motivo se escribe de verdad** — la función lo recibía, lo documentaba
      y escribía un literal: **168 filas en producción con el mismo texto**. El
      camino de aprobación armaba un motivo que incluía el aviso de que el precio
      del plan cambió entre el pedido y la firma, y se descartaba entero;
    · **el conteo dejó de prometer de más** y la nota verde dejó de contradecir a
      la tabla que tiene encima.
  · **NINGÚN número se movió.** Todo es presentación, contexto y columnas nuevas.
  · **🔴 DOS COSAS QUE HABRÍAN LLEGADO A PRODUCCIÓN** y las cazó la auditoría de
    documentación (Rubén la pidió; tenía razón): la bitácora decía que faltaba
    correr UNA migración y son TRES —sin `0267`/`0268` el build **traba la cola
    de subida** en el primer cobro—, y el `pubspec` seguía en 0.38.8 con once
    commits encima, o sea que un build de prueba se habría llamado igual que el
    instalado. Ahora **v0.39.0+304**.
  · **DOC AL DÍA:** ficha nueva **`docs/reglas/cambio-plan.md`** (la que el
    protocolo pedía ANTES de tocar código y no se creó) · `ARQUITECTURA` R22
    corregida en cinco lugares —decía "solo rol admin", falso desde agosto, y
    citaba un CHECK que `0023` dropeó hace 245 migraciones— · `MODULOS`, que se
    contradecía a sí mismo · `AGENTS` lecciones **18** (el comprobante que sale
    de un JOIN editable) y **19** (el parámetro que se recibe, se documenta y no
    se usa) · `TESTING` §0.3.-3, que no tenía **ni un paso** para esta feature.
  · **PENDIENTE del sprint:** tests del diálogo y del bloque del recibo, y
    sembrar un cambio de plan en los dos generadores de escenario (hoy el
    escenario no ejercita esta feature ni una vez).

- **CHECKPOINT (2026-09-01) — el rework del Resumen, cerrado y
  documentado. NADA publicado: producción sigue en v0.37.1.**
  · **Rama `feature/dashboard-mora`, 34 commits.** Build de prueba instalado:
    **CRM TEST 0.38.8** (`com.sitecsa.crm.test`, paquete APARTE del de Mairena).
    **784 tests en verde** — la suite COMPLETA del repo, no sólo dashboard.
  · **QUÉ ENTRÓ, en una línea cada uno:**
    · **la mora, en rojo y adentro de la jerarquía** — cuatro referencias en la
      gráfica (verde/meta + roja/techo), y la mora repartida DENTRO de cada
      momento de la tabla en vez de colgando al lado;
    · **"Estado actual" volvió y se comió a "Distribución de cuotas"** — eran la
      misma partición contada dos veces; ahora cada parte trae su plata y su %;
    · **separación clara entre tarjetas** (borde 1px + 28px de aire);
    · **tipografía unificada en `escala_resumen.dart`** — nueve tamaños sueltos,
      algunos de 9px, pasaron a seis roles con piso en 11;
    · **el globo es una grilla** que parte el día en `a tiempo` + `venían de
      mora` = `cobradas`, y ya no se sale del gráfico;
    · **los cinco Excel con contexto** — `Recibo`, `Fecha de cobro`,
      `Ciclo del cobro` / `Ciclo de la cuota`, `Estado`, y `Cobrador` partido en
      `Cobró` vs `Cobrador asignado`.
  · **NINGÚN número del dashboard se movió.** Todo el rework es presentación,
    contexto y columnas nuevas. Si una cifra difiere de la de antes, es un bug.
  · **🔴 LO QUE FALTA ANTES DE PUBLICAR — son TRES migraciones, no una:**
    1. ~~correr `0267` y `0268`~~ — **CORRIDAS Y VERIFICADAS el 2026-09-02**
       (Rubén las autorizó para poder testear). Las cuatro comprobadas por
       CONTENIDO: `cargos_extra.detalle`, `saldos_favor.detalle`,
       `recibos.plan_label` y el CHECK aceptando `'cambio_plan'`. La plata,
       intacta: 26.590 pagos vivos y C$23.494.710,30 en Mairena, sin cambio —
       eran aditivas y no tocaron una fila. **La `0266` sigue SIN correr**, y
       eso es a propósito: haría aparecer la grilla de KPIs vieja a Mairena y
       Telenet, que no la pidieron, porque la app instalada dibuja otra cosa
       con ese id. Va con el release. Texto original, por si hace falta:
       aditivas, en la misma ventana que la 0266. `0267`: suma `'cambio_plan'` al CHECK de
       `cargos_extra.origen` + las columnas `cargos_extra.detalle` y
       `saldos_favor.detalle`. `0268`: `recibos.plan_label`.
       **🔴 Sin ellas el build nuevo TRABA LA COLA DE SUBIDA.** No es un detalle
       cosmético: `schema.dart` ya declara las tres columnas, el connector sube
       con `table.upsert({'id': op.id, ...?op.opData})` (`connector.dart:90`) —
       o sea TODAS las columnas de la fila local— y PostgREST rebota contra una
       columna que no existe. `plan_label` se escribe en **todo recibo nuevo**
       (los tres caminos de `pagos_repo`), así que rebotaría **en el primer
       cobro**. Las otras dos solo en el modo "Hoy con prorrateo".
    2. **correr la migración `0266`** (enciende `operativo` en los tenants con
       ajuste guardado) — **con** el release, nunca antes: la app instalada
       tiene el Resumen viejo, donde ese id dibuja la grilla de KPIs sueltos;
    3. el **testing manual** de Rubén (`TESTING.md` §0.3.-2 y §0.3.-3);
    4. decidir los pendientes de abajo.
  · **PENDIENTES propuestos y NO aprobados:** el desglose de *Caja del ciclo*
    ("de esto, C$2.300 vienen de meses anteriores") · rehacer **Consultar
    período** con el estilo nuevo · el Excel de **Mora** sin `Recibo` ni
    `Ciclo del cobro` · la tabla de Cobertura **centrada** a 720px · medir con
    el test de bordes las **otras cinco tarjetas**.
  · **DOC AL DÍA (2026-09-01):** `ARQUITECTURA` (sección del Dashboard reescrita
    + **LOS DOS EJES DEL TIEMPO** + receta R2) · `MODULOS` (las 7 tarjetas y el
    gate solo-admin, que **contradecía** a ARQUITECTURA) · `AGENTS` (cuatro
    lecciones nuevas: 15, 15b, 16, 17) · `TESTING` §0.3.-2 · ficha nueva
    **`docs/reglas/ejes-del-ciclo.md`**. Herramientas en verde: 50/50 tablas,
    15/15 buckets, **8/8 reglas**.

- **👉 NUEVO (2026-08-31 d, ÚLTIMO) — la mora en Cobertura: los datos, listos y
  cruzados; falta pintarlos.**
  · **🔴 NO HACÍA FALTA UNA CONSULTA NUEVA, y casi escribo una.** Se agregó
    `moraDeCobertura` y **se borró antes de que llegara a ningún lado**:
    `cortesDelCiclo` ya devolvía las cuatro categorías (`at_*` a tiempo, `cm_*`
    cobrado en mora, `sm_*` sigue en mora, `ef_*` en fecha) **y su stream ya
    estaba armado** en la tarjeta (`_cortesStream`). Los números de las dos
    consultas dieron idénticos, o sea que eran equivalentes.
    **La lección, que vale más que el código: dos consultas de plata que
    responden la misma pregunta terminan divergiendo, y ahí nacen las pantallas
    que se contradicen.** Antes de escribir una consulta, grepear qué hay.
  · **VERIFICADO EL CRUCE QUE PEDÍA RUBÉN** (*"que haga match con la gráfica de
    mora, los números"*): sobre el escenario, **Cobertura dice 28 cuotas /
    C$19.285 y Mora dice 28 cuotas / C$19.285**. Son dos consultas distintas
    (`cortesDelCiclo` y `desgloseMora`), escritas por separado, cruzadas en el
    test — no dos copias de la misma idea.
  · **Y las cuatro categorías PARTEN las filas madre:** 7 + 22 = 29 saldadas;
    28 + 0 = 28 con saldo; y las cuatro juntas = todas las cuotas del ciclo. Ese
    tercer expect no es redundante: sin él, una cuota podría quedar fuera de las
    cuatro y los otros dos seguirían cerrando cada uno por su lado.
  · **Test nuevo** `mora_cobertura_test.dart` (3 casos), incluido el que separa
    las **dos definiciones de "en mora"** —se pagó tarde vs la cuota ya venció—,
    que en el ciclo en curso del Test Tenant dan **0 contra 5**.
  · **FALTA, y es lo próximo:** pintar las cuatro líneas en la tabla (nivel 2,
    con su chevron), las dos líneas de la gráfica (tope de mora punteado + curva
    de mora recuperada) y el renglón del tooltip. Los datos ya están en el
    stream que la tarjeta tiene abierto: es trabajo de UI, no de consulta.

- **👉 NUEVO (2026-08-31 c, ÚLTIMO) — los 7 tests rojos, resueltos: la suite
  queda en CERO por primera vez en semanas (742 verdes).**
  · **POR QUÉ SE EMPEZÓ POR ACÁ** (Rubén: *"a como vos consideres"*): esos 7
    vivían en `dashboard_numeros_test.dart`, el archivo que verifica **los
    números** del Resumen, y todo lo que viene toca números. Mientras estuvieran
    rojos **tapaban cualquier rotura nueva** ahí. El mismo día habían cazado un
    overflow de 145 px que ninguna lectura habría visto.
  · **LA CAUSA, y no era "recalcular":** el escenario creció de **15 a 60
    clientes** el 2026-08-27 (`ad0a1e94`) —a propósito, porque con 15, todos del
    mismo cobrador y sin comunidad, tres tarjetas nuevas no se podían probar—.
    Los valores esperados quedaron describiendo el escenario viejo, **en el test
    Y en `esperados_ciclo_actual` del JSON**.
  · **EL CRITERIO CON QUE SE ARREGLÓ, que es lo importante:** los montos y
    conteos absolutos **se retiran, no se actualizan**. Con 343 cuotas generadas
    por perfiles de pago nadie puede recalcularlos a mano, y un número copiado de
    la salida del propio código no prueba nada — solo se vuelve a pudrir. Queda
    **un solo test que conoce el tamaño** del escenario (59/60/343/245) y los
    demás prueban **invariantes**, que valen con cualquier escenario.
  · **Dos mejoras que salieron de aplicarlo:** *"una cuota sobrepagada no le come
    deuda a los demás"* ahora **mide ANTES y compara DESPUÉS** en vez de contra un
    número fijo —prueba exactamente lo que dice—; y el del export cruza el total
    contra una consulta **independiente** de las dos que suma.
  · **🔴 UNA TRAMPA QUE CASI SE COLÓ:** el primer arreglo de "los 6 ciclos"
    comparaba `rec + imp` contra `rec + imp`. Es `x == x`: **no puede fallar
    nunca**, o sea peor que no tener chequeo (checklist #14). Se descartó y quedó
    lo que sí se puede afirmar sin inventar (seis ciclos, en orden, sin negativos,
    con movimiento en los cerrados) más el cruce fuerte contra OTRA consulta, que
    ya vive en el test de al lado.
  · **PENDIENTE:** `esperados_ciclo_actual` y `esperados_historico` del JSON
    `supabase/escenarios/dashboard.json` **siguen describiendo el escenario de 15
    clientes**. No rompen nada (ningún test los lee hoy) pero son la
    especificación escrita del escenario: quien los lea va a creer que el Resumen
    debe mostrar C$11.200 cuando muestra C$40.385.

- **👉 NUEVO (2026-08-31 b, ÚLTIMO) — el rework del Resumen sigue en su rama, y
  vuelve el desglose de caja.**
  · **DÓNDE VIVE QUÉ, ahora que se separó:** producción quedó en **v0.37.1**
    (rama `release/v0.37.1`) con el Resumen ANTERIOR y los dos cambios de regla
    del 30/08; todo el rework del Resumen vive en **`feature/dashboard-mora`**,
    que es donde se trabaja **sin publicar al canal oficial**.
  · **PEDIDO:** *"todo lo que sale actualmente en el dashboard actual tiene que
    ser optimizado y aparecer en el que vamos a seguir desarrollando"*.
  · **INVENTARIO de las 11 tarjetas del Resumen de producción contra el nuevo**
    (abriendo cada una, no de memoria): **7 ya están** —y la *Mora histórica* no
    se perdió: se **FUSIONÓ** dentro de "Mora del ciclo", que muestra la tabla de
    un ciclo y abajo la gráfica de los últimos seis—. **3 están apagadas con su
    estilo VIEJO** (Estado actual · Distribución de cuotas · Consultar período):
    encenderlas tal cual mezclaría dos épocas, así que hay que rehacerlas con el
    formato de las seis nuevas. *Cobros últimos 7 días* está apagada **también en
    producción**, en los dos ISP.
  · **🔴 MI INVENTARIO SE EQUIVOCÓ EN UN PUNTO, y queda anotado:** listé como
    faltante el corte de **HOY** de "Top cobradores". **Ya existe** desde el
    2026-08-28 en "Quién cobró", como un `SegmentedButton` *Solo hoy / Este
    ciclo* — y su docstring explica por qué se hizo así (las dos tarjetas viejas
    ocupaban el doble y la de "hoy" salía vacía la mitad del tiempo). No se tocó
    nada. **Lección: buscar por el WIDGET, no por el rótulo** — el grep de
    "Top cobradores" no encuentra "Solo hoy".
  · **VUELVE EL DESGLOSE DE CAJA, cerrado** (decisión de Rubén, 2026-08-31). Es
    el bloque que él mismo mandó sacar el 29/08 (*"totalmente innecesario"*), así
    que **no vuelve igual**: detrás de un chevron, y **el cuerpo no se construye
    mientras esté cerrado** —su consulta tampoco corre—. La objeción era el lugar
    que ocupaba, no el dato. El provider nunca se había ido (lo usa el puente);
    se recuperó el widget de `a9ba41b0`.
  · **DOS COSAS LAS CAZARON LOS TESTS, no la lectura:** el encabezado nuevo
    **desbordaba 145 px a 360 px** (el rótulo no entra al lado del chevron → va
    en `Expanded` con ellipsis), y un comentario de test afirmaba que el bloque
    *"se ELIMINÓ"*. El `findsNothing` del test de `admin_cobranza` **sigue siendo
    correcto** —ese rol no ve la tarjeta entera— y ahora prueba más que antes.
  · **Test nuevo que fija las DOS mitades de la decisión:** que el desglose esté
    **y** que arranque cerrado. Si alguien lo deja abierto vuelve el problema que
    lo hizo sacar; si lo saca, se pierde lo que se pidió recuperar. Mira "Total
    que entró" porque es la **única fila incondicional** del cuerpo.
  · **69 verdes** en el dashboard; siguen los **7 rojos PREEXISTENTES**.
  · **PENDIENTE, en este orden:** (1) la **mora en Cobertura** —propuesta,
    verificada contra la base, **sin el sí formal**—; (2) rehacer **Estado
    actual** y **Distribución de cuotas**; (3) rehacer **Consultar período**;
    (4) los dos ajustes chicos (formato de Proyección, ancho de las barras en PC);
    (5) los **7 tests rojos**, que mientras sigan así **tapan cualquier rotura
    nueva** en ese archivo. Y sigue **sin verificar en pantalla** la config de
    Tarjetas del Resumen (sólo la ve el super_admin).

- **👉 NUEVO (2026-08-31, ÚLTIMO) — v0.37.0 PUBLICADA en el canal oficial, con
  el rediseño del dashboard adentro.**
  · **PEDIDO:** *"mandemos el update oficial al release oficial"*, con la
    condición *"si no hay nada de backlog que corregir"* y, después,
    *"asumiendo que sea responsivo… y para todos los escenarios online y
    offline"*.
  · **DECISIÓN DE RUBÉN: se buildea `main`.** El rediseño del dashboard estaba
    en `main` desde la v0.36.2 y **nunca se había publicado** — cada release
    salía de una rama `release/*` = `main` menos el rediseño. Se terminó, se
    aprobó tarjeta por tarjeta y sale ahora. Los dos documentos de
    `Install Steps/` que decían "NO se buildea main" quedaron actualizados; la
    receta de la rama **no se borró**: es la forma probada para cuando `main`
    tenga otra vez trabajo a medio terminar.
  · **LA VERIFICACIÓN QUE FALTABA, y no era retórica:** ninguna de las dos
    pantallas nuevas había pasado por un ancho de teléfono. Se escribieron tests
    que las RENDERIZAN —Cobros a revisar sobre un SQLite real, y el bloqueo de
    la baja, que hubo que **extraer a `ContratosVivosBloqueo`** para poder
    montarlo— a **320/360/412/800/1400 px**. **734 verdes** (+12).
  · **Dos errores propios que el test destapó:** tapeaba el nombre del cliente
    en vez del chip que abre el detalle, y el escenario tenía los DOS pagos en
    cuarentena — un estado que el trigger del server no puede producir.
  · **ONLINE/OFFLINE:** los dos guards viven en el server (valen sin señal); las
    dos pantallas leen de SQLite local; y si un equipo con copia vieja deja
    pasar una baja que el server rechaza, ese `P0001` está en la lista de
    permanentes, deja rastro local, sube a la bandeja y **el mensaje llega tal
    cual al usuario** (`humanizarRechazoSync` no traduce los P0001).
  · **🔴 EL HALLAZGO DEL DÍA — el tenant de prueba iba al canal oficial.** Al
    crear `branding/test/` para la build de Android, `-AllTenants` empezó a
    incluirlo: el release se armó con `CRM-TEST-v0.37.0.msix/apk` y
    `version-test.json` entre sus assets. **No llegó a publicarse** (lo frenó el
    fallo de `gh`), pero iba al canal que leen los 12 equipos. Se marca con
    `soloPrueba: true` en el config —no por nombre, que hardcodearía un slug— y
    `-AllTenants` lo saltea avisando.
  · **`gh release create` falló por CUARTA vez** (`no matches found for ''`).
    Se descartó con evidencia: no es `Invoke-Native` (replicada, anda), no son
    los argumentos (espiados: 18, ninguno vacío), no es el splat vacío
    (probado), no es `gh` (create con assets anda suelto). **Publicado a mano
    con los 6 assets buenos.** Se dejó en el script el volcado de `CWD` + cada
    asset con marca de VACÍO/NO EXISTE, para que la próxima falla se explique
    sola.
  · **PUBLICADO Y VERIFICADO END-TO-END:** `v0.37.0` es **Latest** en
    `sitecsa-updates`, con 6 assets, y las dos URLs que la app consulta
    (`releases/latest/download/version-<slug>.json`) responden `0.37.0`.
  · **NO se borraron los releases anteriores** (la política dice conservar solo
    el vigente): v0.36.6 queda como red hasta que Rubén confirme la 0.37.0 en un
    equipo real. **Pendiente de su OK para limpiar.**

- **👉 (2026-08-30 b) — los 41 huecos, explicados y cerrados; y el
  barrido de documentación para el release oficial.**
  · **PEDIDO:** *"cerralos no hay problema, y mandemos el update oficial…
    actualicemos todos los documentos .md y de arquitectura… si no hay nada de
    backlog que corregir podemos mandar a producción"*.
  · **EL DIAGNÓSTICO REAL, y corrige lo que yo mismo había dicho:** los huecos
    **no eran cobros perdidos**. El correlativo lo asigna el SERVER desde
    `0215` (2026-08-01); antes lo **adivinaba el device** leyendo su copia
    local desactualizada, dos equipos sin señal tomaban el mismo número y el
    server rechazaba el segundo RECIBO — el PAGO entraba igual. Verificado:
    Derling registró **31 cobros y hay 31 recibos**, ninguno anulado; **0 pagos
    vivos sin recibo** en toda la base; los 25 sin recibo están **todos
    anulados** y son de abril-julio. PowerSync nunca falló.
  · **Los 41 son TODOS anteriores al 01/08.** Agosto cerró con **5.137 recibos,
    13 equipos y CERO huecos**; el contador de Telenet (249) coincide exacto con
    su recibo más alto. **Cerrados los 8 rangos** con el motivo que explica la
    causa raíz y la verificación; la bandeja quedó en **0 pendientes**.
  · **BACKLOG, verificado contra la base y no contra el documento** (que estaba
    mintiendo: declaraba "CERRADA 8/8" arriba y dejaba los bullets sin tachar
    abajo). Los **5 hallazgos CRÍTICA/ALTA** del audit integral del 22/08 están
    cerrados: #1 y #2 por `07ef4125`, #3 y #4 ya estaban, y **#5 se cerró hoy**
    —la contradicción del Total de contrato seguía viva en `ARQUITECTURA:687`
    ("NUNCA suma de cuotas"), justo al revés del invariante #5—. Los otros 42
    son MEDIA/BAJA. Los 21 clientes activos sin contrato son remanentes de la
    importación por Excel del 21/06, no el bug del backlog (**0 de los 8
    códigos** que listaba siguen así).
  · **Superficies que el cambio de ayer dejó mintiendo y se cazaron hoy:** la
    **guía de troubleshooting SQL** (§4) decía que el guard "AUTO-ANULA el
    gemelo exacto" —es la guía OPERATIVA que se usa para corregir data, así que
    mentía sobre lo que va a pasar— y `ARQUITECTURA:1512` lo narraba en
    presente. Los audits fechados (`AUDIT-INTEGRAL`, `PLAN-CONSISTENCIA`) **no
    se tocan**: narran lo que era cierto ese día.
  · **v0.37.0+294.** Minor porque cambian dos reglas de negocio.

- **👉 (2026-08-30 a) — todo duplicado lo decide el admin, y dar de
  baja pasa a ser el último paso.**
  · **PEDIDO:** que ni el duplicado idéntico se resuelva solo *"porque el recibo
    puede variar por el vuelto… o si se pagó en dólar, y lo más importante es el
    correlativo del cobrador"*; y que desactivar un cliente **avise que no se
    puede** mientras tenga contratos vivos.
  · **0264 — se saca la rama que anulaba sola el gemelo exacto.** Dos cobros con
    el mismo monto y el mismo día NO son intercambiables: cada uno tiene su
    recibo, con su correlativo y su cobrador, y el cliente tiene **uno** en la
    mano. Ahora los dos casos van a cuarentena. Los **14 ya resueltos se quedan
    como están** (decisión de Rubén) y conservan su motivo, del que dependen
    INV18 y el CHECK `pagos_anulacion_coherencia`.
  · **Barato porque `en_revision` ya estaba propagado** en las 21 superficies de
    reportería con el predicado canónico: **cero queries que tocar**.
  · **La tarjeta de decisión** suma recibo destacado + cobrador, moneda/monto
    entregado y vuelto —los cuatro datos que distinguen un papel del otro— y el
    `revision_motivo` del server, que ahora diferencia el idéntico del sobrepago.
    **Fuera la sección "Resueltos automáticamente"** (decisión B): al sacarse la
    rama que la alimentaba quedó estructuralmente vacía.
  · **0265 — desactivar EXIGE cero contratos vivos.** Se retira la cascada de
    `0260`, que condonaba la deuda de varios contratos con **una sola firma**.
    Ahora se cierra cada contrato por separado, con su autorización, y la baja es
    el último paso. **Sigue pidiendo permiso aunque ya no mueva plata**
    (decisión C): terminar la relación es una decisión de negocio.
  · Guard de **TRANSICIÓN, no CHECK** (regla #13) y contemplando el UPSERT de
    PowerSync (#13b). El bloqueo en la UI va **antes** de bifurcar por permiso:
    si viviera sólo en el diálogo del admin, el rol que SOLICITA lo saltearía y
    el aprobador firmaría algo que el server rechaza.
  · **Verificado en producción:** las dos migraciones por CONTENIDO; el guard
    probado en vivo (rechaza con contratos, pasa sin ellos) y revertido sin
    escribir; 578 clientes inactivos con **0 atrapados**; 259 cancelados sin
    deuda; 1.074 pagos preservados. **Invariantes idénticos antes y después**
    (93 chequeos, los mismos 2 hallazgos preexistentes de Mairena).
  · **Ficha nueva** `docs/reglas/duplicado-cobro.md` + `cancelacion.md`
    actualizada. Su patrón prohibido se dejó SIN el grep de `new.anulado := true`:
    las migraciones son inmutables y daría hallazgos eternos (checklist #14) — el
    chequeo bueno corre contra la definición viva y lo lleva `0264`.
  · **Tests: 722 verdes** (+2 nuevos de `previewBajaCliente`); siguen los **7
    rojos PREEXISTENTES**, confirmado corriéndolos en el commit anterior.
  · **PENDIENTE:** los **41 recibos faltantes** (8 rangos, 33 de Mairena y 8 de
    Telenet) son **históricos** —el más nuevo es del 30/07 y agosto cerró con
    5.098 recibos y CERO huecos—. Falta decidir dos cosas propuestas y no
    aprobadas: que los huecos suenen la campana, y el reintento del aviso de
    rechazo (hoy es de una sola oportunidad).

- **👉 (2026-08-29 b) — el orden y el encendido de las tarjetas
  del Resumen, configurables por empresa.**
  · **PEDIDO:** *"que la configuración de la posición entre cada gráfico sea
    configurable en el Dev panel… habilitar, deshabilitar y mover el orden de
    las métricas"*, en los ajustes avanzados (super_admin) y **por tenant**.
  · **UN SOLO ajuste** (`dashboard.tarjetas`, migración **0263**) con orden y
    encendido juntos. Los toggles sueltos no podían expresar el ORDEN, que
    vivía escrito a mano en `dashboard_admin_screen.dart`.
  · **LA REGLA QUE EVITA QUE UNA TARJETA DESAPAREZCA:** el ajuste NO es la
    autoridad sobre QUÉ tarjetas existen —eso lo dice `kTarjetasResumen`, en
    código—. Un id que el código ya no conoce se ignora; una tarjeta que el
    ajuste no nombra se agrega **al final, encendida**. Sin esa segunda regla,
    agregar una tarjeta la dejaría invisible en todo tenant con ajuste viejo.
    Un ajuste corrupto cae al default entero.
  · **ARREGLA ALGO QUE ROMPÍ EL 28:** al retirar los gates sin uso quedaron
    **tres interruptores en Ajustes que no hacían nada** (`proyeccion_visible`,
    `recuperacion_visible`, `top_cobradores_visible`). Los siete
    `dashboard.*_visible` salieron de la lista de claves.
  · El **gate de rol manda sobre el ajuste**: encender "Caja del ciclo" no se la
    muestra a `admin_cobranza`. La pantalla lo dice en cada fila que aplica.
  · **Migración verificada POR CONTENIDO** (lección 0192): sembrada en los 3
    tenants, tipo `json`, `editable_por=super_admin`, y el trigger de seed
    conserva sus **16 `perform`** (lección 0151).
  · **Tests (11):** los fallbacks —ajuste roto, id desconocido, id repetido,
    `on` como string, tarjeta nueva—, la ida y vuelta, los ids como candado, y
    uno que **lee la migración** y compara su default contra el de Dart: si se
    separan, un tenant nuevo abriría el Resumen distinto de uno viejo.
    **68 verdes**; siguen los 7 rojos PREEXISTENTES.
  · **PUBLICADO:** `Template-TT` → **v0.36.33**, prerelease, con el APK.
    Producción sigue en v0.36.6.
  · **El script falló por TERCERA vez** en `gh release create` (`no matches
    found for -`). Se descartó también que sea `Invoke-Native`: se replicó la
    función entera con los mismos argumentos y funciona. Queda como sospecha
    —sin confirmar— algo del estado acumulado del script. Publicado a mano.
  · **🔴 NO VERIFICADO EN PANTALLA:** la tab "Avanzado" sólo la ve el
    super_admin y el build local está logueado como admin del Test Tenant. La
    pantalla nueva compila y sus tests pasan, pero **nadie la vio funcionar
    todavía** — hay que abrirla como super_admin.

- **👉 NUEVO (2026-08-29 a) — responsive real en teléfono, y fuera el
  desglose de Caja.**
  · **PEDIDO:** *"aseguremonos que esto es responsive para telefonos como para
    PC, y el bloque de que cuota era esta plata, eso es totalmente
    innecesario"*, con capturas del teléfono.
  · **FUERA el desglose de Caja** ("¿De qué cuotas era esta plata?"): esa
    clasificación ya se lee en Cobertura y en Mora. **SE QUEDÓ EL PUENTE**, que
    no está en ninguna otra parte y ya se había perdido una vez.
  · **UN CRITERIO, aplicado en las cinco:** umbral 600px de pantalla = compacto.
    Rótulo de fijo a proporcional (46%, piso 120) · la columna de % y su
    encabezado se ocultan · el monto pierde el "C$" repetido · los bloques
    apilados van a ancho completo · el selector de Quién cobró acorta y baja el
    rango · las barras achican nombre y monto.
  · **CUATRO OVERFLOWS que las capturas NO mostraban**, cazados por el test
    nuevo a 360px: el navegador de ciclo de Mora (192px) y el de **Cobertura**
    (68px), y las leyendas de Mora (190px) y **Cobertura** (185px).
    Los dos de Cobertura son el ÚNICO cambio a esa tarjeta desde que Rubén la
    dio por cerrada, y son overflows —la franja amarilla y negra encima del
    contenido—, no rediseño: nada de lo que muestra cambia.
  · **Tests:** `responsive_tarjetas_test.dart` (3) + dos que MONTAN el Resumen
    a 360px y verifican que los bloques queden apilados y parejos, y en fila a
    1600. **Ese test es el que encontró los cuatro overflows.** 57 verdes;
    siguen los 7 rojos PREEXISTENTES de `dashboard_numeros_test`.
  · **PUBLICADO:** `Template-TT` → **v0.36.32**, prerelease, con el APK.
    Producción sigue en v0.36.6.
  · **🔴 PENDIENTE SIN RESOLVER:** el script aborta en `gh release create` con
    `no matches found for -`, las DOS veces que se usó. El mismo comando a mano
    funciona. Se descartó que sean los argumentos (se instrumentó y llegan
    exactos), `--prerelease` (la primera vez no existía) y los assets. El flujo
    manual está escrito en `Install Steps/4-Build-de-prueba-Android.md`.

- **👉 NUEVO (2026-08-28 d) — app **CRM TEST** para Android, en canal
  privado y sin tocar producción.**
  · **PEDIDO:** *"quiero que para android hagas la app CRM exclusiva para
    testing y para yo poderla descargar desde github en un release de test que
    no afecte los releases oficiales"*.
  · **CÓMO FUNCIONA EL AUTO-UPDATE (lo verifiqué antes de proponer):** cada app
    pide `releases/latest/download/version-<slug>.json`. Ese **`latest` lo
    decide GitHub**: publicar un release de prueba en `sitecsa-updates` lo
    volvería el `latest` que consultan Mairena y Telenet.
  · **SOLUCIÓN — marca `test`** (`branding/test/`), que reusa el mecanismo de
    branding y no necesita código nuevo:
    - `applicationId` **`com.sitecsa.crm.test`** → Android la instala AL LADO de
      las oficiales, nunca encima. Barrera estructural.
    - Canal **`Template-TT`** (privado, **no tenía ningún release**: canal
      limpio) + **`--prerelease`**, que GitHub excluye del `latest`.
    - Cinta **"PRUEBA"** en pantalla (`kEsBuildDePrueba`, resuelto en tiempo de
      compilación desde `TENANT=test`).
  · **UN BUG LATENTE QUE SE ACTIVABA JUSTO ACÁ:** el script publicaba en
    `-Repo` pero horneaba el `UPDATE_REPO` desde el `.env.json`. Un build con
    `-Repo` se publicaba en un canal y **se auto-actualizaba desde otro**. Ahora
    hornea `--dart-define=UPDATE_REPO=$repo`: para producción es el mismo valor
    (idempotente), para cualquier otro canal lo vuelve coherente.
  · **LO QUE NO AÍSLA — decisión de Rubén:** la base es la MISMA de producción
    (`vxxz`). Un cobro desde la app de prueba con un usuario de una empresa real
    es un cobro real. Le propuse un candado por tenant y una base aparte;
    **eligió la disciplina** (*"yo sé que para eso está el test tenant"*).
    Queda escrito acá y en `branding/test/README.md` por si algún día se
    revisa.
  · **Docs:** `Install Steps/4-Build-de-prueba-Android.md` (cómo publicar, cómo
    bajarlo del repo privado —da 404 sin sesión—, y el detalle de la firma
    debug: hay que buildear siempre desde la misma máquina).
  · **PUBLICADO:** `Template-TT` → `v0.36.31`, **prerelease**, con
    `CRM-TEST-v0.36.31.apk` (102 MB), el MSIX y `version-test.json`.
    Verificado que `sitecsa-updates` sigue en **v0.36.6 como Latest**: el canal
    de producción no se movió.
  · **EL SCRIPT FALLÓ UNA VEZ Y NO SE SUPO POR QUÉ.** El build salió bien y
    `gh release create` abortó con `exit 1` sin imprimir una línea. El reintento
    a mano, con el MISMO comando y los mismos assets, funcionó — así que la
    causa no quedó identificada (probablemente algo transitorio de red o del
    contexto sin TTY del proceso en background). Lo que SÍ se arregló es el
    diagnóstico: `Invoke-Native` ahora usa `Tee-Object` y el error incluye las
    últimas 8 líneas del comando. La próxima vez que falle, se va a saber.
  · **PENDIENTE:** que Rubén lo baje y pruebe.

- **👉 NUEVO (2026-08-28 c) — "Caja del ciclo" ENCENDIDA, con
  retroceso propio en cada bloque.**
  · **PEDIDO:** *"poder ver la data del día, semana y período con la opción en
    cada uno de poder seleccionar días anteriores como opciones
    predeterminadas"*. Sin Excel (pedido explícito), con (i).
  · `caja_ciclo_card.dart`, autocontenida como el resto. Sale del gate
    `extras_visible` y va PRIMERA: es la lectura más inmediata. Los tres
    bloques son independientes — se puede mirar el martes pasado, la semana
    antepasada y el ciclo de hace tres meses a la vez. 7 días · 6 semanas ·
    6 períodos, **cada opción con su monto en el menú**.
  · **Las fechas se calculan en DART** y viajan como parámetros; antes los
    cortes estaban escritos en el SQL, que sirve para "hoy" pero no deja
    retroceder.
  · **El desglose se clasifica contra el ciclo de la VENTANA ELEGIDA**, no el
    actual: mirando "15 jun – 14 jul" sus cuotas salen como "del ciclo" y no
    como atrasos.
  · **DOS COSAS QUE SE ROMPIERON Y SE REPUSIERON:**
    (1) `IntrinsicHeight` — **regla #11 del checklist**: el `Row` con
    `crossAxisAlignment.stretch` dentro del scroll reclamaba altura INFINITA y
    tiraba el layout de la pantalla ENTERA (no se veía ni Cobertura). Lo cazó
    el test de widget, no el analyzer.
    (2) **EL PUENTE con Cobertura** —*"De este ciclo entraron X ahora, y otros
    Y ya se habían cobrado antes…"*— se había perdido al reescribir. Vuelve, y
    sólo cuando la ventana es un ciclo COMPLETO: lo cobrado un martes no se
    compara con el "Recuperado" de un ciclo entero.
  · **Tests:** 12 nuevos de BORDES de fecha (el 14 contra el 15, el domingo que
    abre la semana, el cruce de año, que las ventanas no se pisen ni dejen
    huecos) + los 4 de widget actualizados. Cada bloque lleva `Key` para mirar
    UNO: "2 cobros" es un error en el de día y legítimo en el de semana.
    **52 verdes**; siguen los 7 rojos PREEXISTENTES de `dashboard_numeros_test`.
  · **PENDIENTE:** testing manual (v0.36.31 local). Y decidir si la Proyección
    va en formato compacto (una línea con switch, como la oficial) o queda con
    el diseño actual.

- **👉 NUEVO (2026-08-28 b) — las 3 tarjetas restantes del Resumen.
  Las cinco quedan encendidas y cada una en SU archivo.**
  · **PEDIDO:** *"podemos habilitar las 3… cada una es individual, así cada
    cambio en cada una es independiente de los demás y no deberían
    afectarlos"*.
  · **TRES ARCHIVOS NUEVOS**, sin un símbolo en común entre ellos ni con las
    dos anteriores — cada uno con su consulta, su grilla, su botón de Excel y
    su paleta: `proyeccion_cobros_card.dart`, `deuda_zona_card.dart`,
    `quien_cobro_card.dart`.
  · **DOS RÓTULOS QUE MENTÍAN:**
    (1) *"Recuperación por cobrador y comunidad"* mostraba lo que FALTA cobrar,
    no lo recuperado. Al lado de Mora —donde "Recuperado" sí es plata que
    entró— hacía leer C$170.185 como cobranza. Ahora es **"Deuda por cobrador
    y comunidad"**; el número no se tocó. Mismo arreglo que Usuarios→Servicios.
    (2) *"Top cobradores (hoy)"* salía **vacía** cualquier día sin cobros
    (medido: el 28 nadie había cobrado). Se unificó con la de período en
    **"Quién cobró"** con selector, y el vacío se EXPLICA en vez de mostrar una
    tarjeta en blanco.
  · **Los sin cobrador asignado** (30 cuotas / C$20.800) aparecen como fila
    propia en las dos primeras, en itálica y con la barra rayada: es cartera
    real que nadie trabaja, y pintarla igual que a un cobrador la volvía
    invisible como problema.
  · **LIMPIEZA:** se retiraron del screen las 3 tarjetas viejas, sus 2 widgets
    huérfanos de desglose, los 4 providers sin consumidor y **los 4 gates de
    settings** (`pendientes_visible`, `proyeccion_visible`,
    `recuperacion_visible`, `top_cobradores_visible`) que servían para
    encenderlas de a una. Un gate que nadie consulta es una palanca que el
    próximo agente cree que hace algo. El screen bajó de 1.407 a 1.264 líneas y
    `dashboard_providers.dart` de ~800 a 593.
  · **Tests:** 35 verdes. Un choque de rótulos apareció al montarlas juntas —
    el test de Cobertura busca `find.text('Hoy')` y el selector nuevo agregaba
    otro; el segmento pasó a **"Solo hoy"**, que además hace juego con el otro
    ("Ciclo 15 ago – 14 sep") y deja claro que son excluyentes.
  · **UN BUG DE PLATA QUE ENCONTRÓ UNA CAPTURA DE RUBÉN (misma sesión):** al
    reescribir la tarjeta de comunidad se perdió el filtro
    `vencimiento + gracia < hoy`. Dejó de mostrar la **MORA** y pasó a mostrar
    **toda la deuda viva**, incluidas cuotas que ni habían vencido:
    **C$170.185 contra C$33.485 reales**. Con el filtro de vuelta, 5 de las 6
    comunidades dan EXACTO lo que muestra la versión oficial (la 6ª creció
    porque pasó el tiempo). Pasó a llamarse **"Mora por cobrador y comunidad"**
    — "Deuda" describía bien lo que estaba midiendo mal.
  · **VOLVIÓ EL TERCER NIVEL** (pedido de Rubén): abriendo una comunidad se ve
    de cuánto son las cuotas —"C$900 × 3 cuotas"— y una línea confirma que el
    desglose suma la comunidad. Los tres niveles salen de UNA sola consulta:
    traerlos de consultas separadas es exactamente como estas tablas se
    descuadran.
  · **EXCEL PRECISO** (*"que no se invente nada"*): el de mora sale del MISMO
    provider que la pantalla; y el de "Quién cobró" hacía `JOIN cobradores` sin
    `activo = 1` mientras la pantalla sí lo filtraba — un cobrador dado de baja
    con pagos salía en el archivo y no en la tarjeta. Alineado.
  · **Test nuevo** `dashboard_tarjetas_nuevas_test.dart` (4, verdes): los tres
    niveles suman igual · el filtro de gracia está PUESTO (sin él el universo
    tiene que ser estrictamente mayor: 40.385 vs 62.485) · pantalla y Excel
    miran el mismo universo en las tres tarjetas.
  · **EL EXCEL DE ESA TARJETA BAJA UNA FILA POR CUOTA** (pedido: *"que la data
    sea trackeable al 100%… en X comunidad con Y cobrador hay 2 cuotas de 500, y
    en el excel aparece esa información con los detalles de esas 2 cuotas"*).
    **La app y la tabla NO se tocaron**: el cambio es sólo del archivo.
    Columnas: Cobrador · Comunidad · Cliente · Nombre · Contrato · Vence · Días
    de atraso · Saldo. Los tres niveles de la pantalla se reconstruyen
    agrupando (por `Saldo` el tercero, por `Comunidad` el segundo, por
    `Cobrador` el primero). Los **subtotales salen del provider de la
    pantalla**, no de sumar el detalle: si las dos consultas divergieran, el
    archivo mostraría la diferencia en vez de taparla. El detalle NO va en un
    `watch` (2.471 filas en Mairena); se consulta al hacer clic.
    Test nuevo: filtrar por (cobrador, comunidad, saldo) da el MISMO conteo que
    la tabla, en los dos sentidos — 58 cuotas en 11 grupos, todos exactos.

  · **OJO — los ajustes del Test Tenant cambiaron:** días de gracia pasó de 7 a
    10 y `dias_cuotas_visibles` es 10. Las tarjetas leen el setting en vivo, así
    que se ajustan solas; los números de referencia de esta bitácora anteriores
    a este bloque quedaron viejos.

  · **PENDIENTE:** testing manual (v0.36.30 local). Siguen los 7 rojos
    PREEXISTENTES de `dashboard_numeros_test.dart`.

- **👉 NUEVO (2026-08-28 a) — tarjeta 2 (Mora del ciclo): barras de 6
  ciclos + tabla del ciclo elegido. ENCENDIDA.**
  · **PEDIDO:** *"la siguiente metrica de mora de los ultimos 6 ciclos… en
    formato tabla y el grafico de barra de cumplimiento"*, y después *"la tabla
    quiero que sea estilo como la de cobertura del ciclo, pero ciclo por ciclo
    y con la capacidad de ir a ciclos anteriores, y la grafica de barras que
    siempre tenga los ultimos 6 ciclos"*.
  · **POR QUÉ:** la tarjeta vieja agregaba los 6 meses en UN número —"64% de
    cumplimiento global"— y eso no dice si la cartera viene mejorando: marzo
    (100%) y agosto (24%) quedaban promediados en la misma cifra. Medido en el
    Test Tenant: abr 100% · may 92% · jun 76% · jul 58% · ago 24% · sep 0%.
  · **QUÉ SE HIZO** (commits `16fdf9ed`, `541b7b93`):
    - `serieMoraPorCiclo` (una fila por ciclo) + `desgloseMora` (el 2º nivel).
      Por construcción `rec + pend = mora` en cuotas y monto → la barra apilada
      no puede mentir y el hover no puede discrepar de la tabla.
    - `TablaCiclo` (`tabla_ciclo.dart`): la grilla se EXTRAJO de `_TablaSummary`.
      Cobertura y Mora dibujan la misma tabla en vez de dos copias que se
      desalinean sola la primera vez que alguien toca una.
    - `MoraCiclosCard` (`mora_ciclos_card.dart`) reemplaza a `TendenciaMoraCard`,
      que se borró junto con 3 params del shell que solo usaba ella.
    - Excel: bloques por ciclo → **plano con columna `Ciclo` + `Fila de la
      tarjeta` + `Detalle`**. Es el formato que Rubén ya había elegido en
      Cobertura; filtrando salen los mismos conteos que la pantalla.
    - `kInfoMora` reescrito para la tarjeta nueva (el (i) explica cómo leerla).
    - Tests: `dashboard_mora_ciclos_test.dart` (3, verdes) verifica la identidad
      contra SQLite real; se actualizaron los 2 que asumían el formato viejo.
  · **DECISIONES:** el chevron aparece SOLO donde hay ≥2 categorías (por eso
    cambia de fila según el ciclo); el ciclo en curso va rayado e itálica; la
    gráfica NO se mueve al navegar (si retrocedés más de 6 ciclos, queda sin
    recuadro); altura por MONTO, no normalizada (si no se perdería que agosto
    tuvo mucha más mora que el resto).
  · **DOS BUGS QUE APARECIERON AL VERLA EN VIVO** (no los cazan analyze ni los
    tests — son de runtime): (1) con un `MouseRegion` POR BARRA, el `setState`
    del primer `onEnter` reconstruye el árbol y los eventos en vuelo se pierden:
    el cursor sobre junio y el globo diciendo marzo. Se reemplazó por UNA región
    que resuelve la columna por posición. (2) las barras salían de 180px (6
    `Expanded` repartiendo la tarjeta) y el ciclo en curso se leía como una caja
    vacía: tope de ancho 54px, selección por fondo tenue en vez de borde, y el
    rayado dibujado con un `CustomPainter` real.
  · **SEGUNDA VUELTA (mismo día) — INDEPENDENCIA TOTAL + formato de Cobertura.**
    Pedido: *"cada grafica va a tener su propia codificacion y customizacion…
    con eso quiero asegurarme que un cambio que se haga en una grafica no
    modifique otras sin querer"* + *"la grafica de Mora… que siga el mismo
    formato de la cobertura"*. Rubén eligió la **opción B** (copia literal)
    sobre la de motor común, y cerró Cobertura: no se toca más.
    - `tabla_ciclo.dart` **eliminado**; Mora tiene su `_GrillaMora`. Su botón
      de Excel es propio y `BotonExportar` volvió a ser privado en Cobertura.
      El Excel de Mora tiene `_headersMora`/`_filaMora`/`_cierreMora` propios.
      **Verificado: cero símbolos en común entre los dos archivos.**
    - Orden nuevo: encabezado → navegación centrada → tabla → barras (estaba
      al revés); descarga y DESPUÉS el (i) (estaban invertidos); la pastilla
      del ciclo avisa cuando está en curso.
    - **Hover:** el globo cuelga de su columna con una flecha que la apunta y
      las demás bajan de intensidad. Dos arreglos de runtime más: `setState`
      solo cuando la columna CAMBIA (`onHover` dispara por pixel y repintaba
      60 veces por segundo), y `onEnter` además de `onHover` — entrando de un
      salto no llegaba ningún evento y el globo no aparecía.
    - **TERCERA VUELTA:** el botón de descarga usaba `download_outlined` y el
      de Cobertura `file_download_outlined` — uno arriba del otro se veían
      distintos. Independientes por dentro no significa dos íconos para la
      misma acción. Y el Excel de Mora **volvió a agruparse por ciclo con el
      subtotal de cada uno**; los bloques ahora conviven con las columnas
      `Fila de la tarjeta` y `Detalle`, que son las que dejan reconstruir
      cualquier número de la pantalla fila por fila — sin ellas, los bloques
      obligaban a sumar subtotales a mano, que fue el reclamo original.
    - Trade-off ESCRITO en el encabezado del archivo: un ajuste que sirva a las
      dos hay que hacerlo dos veces.
  · **PENDIENTE:** testing manual de Rubén (v0.36.27 instalada local, identidad
    genérica `com.sitecsa.crm`; Telecable 0.35.2 y Telenet 0.27.0 NO se
    tocaron). Las tarjetas
    3 a 5 siguen ocultas tras `dashboard.pendientes_visible`. Siguen rojos los
    7 tests de `dashboard_numeros_test.dart` (esperados a mano del escenario
    viejo, PREEXISTENTE — incluye "el escenario se sembró completo", que no
    toca nada de esta sesión).
  · **HALLAZGO SUELTO:** los números del ciclo 15 jul–14 ago cambiaron solos
    (57→56 cuotas, C$40.385→39.685). Causa: la cuota **PB-43** (C$700, vencía
    16 jul) se anuló el 28 ago con motivo *"Cancelación de contrato"* — no es
    una de las anulaciones del escenario ("Anulada por el escenario de prueba").
    Es la regla de cancelación funcionando (cancelar condona), no un bug.

- **👉 NUEVO (2026-08-27 f) — tarjeta 1 (Cobertura del ciclo): 12
  arreglos de claridad. El Resumen queda con ESA SOLA.**
  · **PEDIDO:** *"la tabla se mira que requiere mejoras de UI porque no está muy
    clara, y también en la gráfica; al hacer hover quiero ver claro en qué día
    se hizo el pago y cuántas cuotas se pagaron"*. Y: *"de momento solo
    habilitemos lo de la cobertura del ciclo"*.
  · **PANEL:** 3 especialistas (2 UI/UX + contabilidad) + escéptico por hallazgo.
    32 hallazgos, 16 sobrevivieron, 12 aprobados por Rubén.
  · **TRES BUGS QUE NADIE HABÍA VISTO:**
    (1) las tres pastillas de % salían **siempre en rojo de alarma**, incluido
    el 100% de Cobros — `pctPill(0, entero: pct)` pasaba un `0` LITERAL donde va
    el valor que elige el color; en la fila Recuperado convivían el punto verde
    y la pastilla roja diciendo cosas opuestas del mismo número. **Era la causa
    de "no se ve clara"**: el único color de la tabla gritaba error.
    (2) `onHorizontalDragEnd` limpiaba la selección al soltar → **en Android el
    tooltip se borraba justo al levantar el dedo para leerlo**.
    (3) `_onHover`/`_onTap` clampeaban en vez de descartar → arrastrar sobre el
    eje Y mostraba el día 0 y pasar por un día futuro mostraba el último.
  · **LO PEDIDO:** tooltip reescrito — abre con *Cuotas cobradas* rotulado y en
    17px, con día de la semana. Antes ese dato era un `(5)` pelado entre
    paréntesis. Y `qty` pasa a `COUNT(DISTINCT p.cuota_id)`: contaba filas de
    pago. Medido: 685 días con cobro en los 3 tenants, cero diferencias — o sea
    que coincidía **por casualidad, no por diseño**.
  · **VOCABULARIO Y UNIDADES:** el % de la tabla es de CUOTAS y el de la curva
    es de MONTO, y nada lo decía. Ahora los dos dicen su base. La curva tenía
    tres nombres → uno: *Recuperado*. El pie decía "recuperado" con otro
    significado que la fila → *cobrado tarde*. El Excel usa el vocabulario de
    la pantalla.
  · **UNA PROPUESTA SE DESCARTÓ Y ESTUVO BIEN:** el contable proponía una línea
    con la caja del ciclo como chequeo. Rubén frenó: *"me confunde que digan que
    los totales no son correctos"*. Tenía razón — la caja (C$5.300) y el
    Recuperado (C$3.745) miden cosas distintas y ponerlos juntos agregaba ruido
    a una tarjeta cuyo problema es la claridad. **El desglose real ya vive en el
    Excel**, que suma exacto (verificado: 57 filas = C$40.385 / 21.100 / 19.285).
  · Commits `9cb4800e` + el del test. Versión **0.36.9** instalada en la PC.
  · **EL EXCEL, REESTRUCTURADO (opción B, elegida por Rubén):** el archivo pasa
    de dos bloques por ORIGEN (contrato vs cobro puntual — que casi nunca es lo
    que se quiere mirar, y que la columna "Tipo" ya dice fila por fila) a
    **tres por CÓMO SE COBRÓ**: cobradas a tiempo · cobradas tarde · por
    recuperar, cada uno con subtotal. Son el desglose exacto de la tarjeta: los
    dos primeros suman su fila "Recuperado", el tercero ES "Por recuperar".
    Columnas de plata de **7 a 3**: el cruce por mora se retiró porque el bloque
    dice lo mismo. Medido antes de sacarlo: **cero cuotas** cobradas en parte
    dentro de la gracia y en parte después, en los tres tenants.
  · **COLUMNA `Días`:** nació del caso que trajo Rubén — una cuota que vencía el
    18 y se pagó el 11 aparecía en el ciclo sin forma de ver que era un pago
    adelantado. Ahora dice `+7 adelantado` / `−2 en gracia` / `−16 tarde`, con
    los mismos días de gracia que usa la tarjeta.
  · **LA GRÁFICA NO SE TOCÓ** para esto, por decisión: el pago adelantado se
    explica en el archivo y en el tooltip del primer día ("Antes del ciclo").
    Sí se agregó **un punto por día con cobro** sobre la curva (pedido directo);
    sale de `montoPorDia`, no de "dónde subió la curva", porque el día 0 arranca
    elevado cuando hubo pagos ANTES del ciclo y ahí no hubo cobro ese día.
  · **Un error propio que cazó el test nuevo:** el commit que "sacaba" las 4
    columnas del cruce por mora solo agregó el comentario que lo decía — las
    tuplas seguían ahí. El test de reconciliación lo marcó al instante.
  · **UN SOLO CORTE (2026-08-27, el pedido más fino del día).** Rubén auditó
    ciclo por ciclo y encontró que *"las cantidades de cuotas no hacen match y
    todo depende de si una cuota fue pagada en el periodo anterior por
    adelantado o en el siguiente como pago muy atrasado"*. Tenía razón, y al
    medirlo aparecieron **TRES causas** distintas, todas reales:
    (1) plata que entró FUERA de la ventana que la gráfica dibuja — en el ciclo
    15 jul–14 ago: 1 cuota cobrada antes (C$1.025) y 2 después (C$1.000);
    (2) dos cuotas con abono parcial (TT-06 y TT-13): su plata entró pero
    siguen debiendo; (3) **TT-07**, cuota de C$1.075 con un cargo de −1.075:
    quedó saldada **sin que entrara un peso** y sin ningún pago que dibujar.
    → **La columna Cuotas y la columna Monto no pueden cerrar fila por fila.**
  · **QUÉ SE HIZO:** se retiró el pie de mora (*"es bastante confuso, no hace
    match visual"*) — sus dos números eran un TERCER corte que no salía de
    ninguna fila ni de ningún punto: el 36 era 8 de una fila + 28 de otra. Se
    retiraron también las sub-filas de mora. En su lugar, bajo `Recuperado`,
    tres sub-filas de **plata sola** por CUÁNDO entró: antes del ciclo · en el
    ciclo · después. Suman el Recuperado EXACTO y son, una a una, las tres
    partes de la curva (la altura en que arranca, lo que sube, el salto final).
    **Sin conteos a propósito** — ahí estaba la trampa.
  · **EL EXCEL SE AGRUPA IGUAL:** cuatro bloques por cuándo entró la plata, más
    una columna `Cuándo entró` por fila. El subtotal de cada bloque da, uno a
    uno, las sub-filas de la tarjeta. Test nuevo que lo fija.
  · Versión **0.36.12** instalada. La mora del ciclo vive ahora solo en la
    tarjeta 2, que es para lo que existe.
  · **LOS ABONOS PARCIALES DEJAN DE SER INVISIBLES (0.36.13).** Rubén, auditando
    la tarjeta contra el Excel: *"esos pagos parciales prácticamente califican
    en 2 grupos"*. Exacto: una cuota con abono recibió plata (está dentro del
    Recuperado) Y sigue debiendo (está contada en Por recuperar), y solo se veía
    una de las dos cosas. Ahora hay una sub-fila `con abono parcial · N · ya
    entraron C$X` bajo Por recuperar.
  · **ME EQUIVOQUÉ Y LO ENCONTRÓ EL PANEL:** le dije que los conteos costaban
    una consulta nueva. Para ESTE caso era falso — `med_c` y `med_e` ya venían
    en `resumenCobros` (:93-95) y ya se parseaban en `ParticionCobro`, y **no se
    dibujaban en ningún lado**. Data muerta desde que existe.
  · **REGLA NUEVA DEL DUEÑO:** *"yo no quiero que se inventen cuotas o
    cantidades, todo tiene que ser números reales"*. Rechazó una propuesta mía
    que fabricaba un residuo (19.075 − 1.100 = 17.975). Por eso quedó **afuera**
    poner conteos en las tres sub-filas de "cuándo entró": suman 30 y no 29,
    porque cuentan cuotas que recibieron plata y dos de ellas siguen debiendo.
    Es real, pero no cierra contra la fila madre.
  · **EL EXCEL SE CONTRADECÍA A SÍ MISMO:** el bloque decía "COBRADO DESPUÉS DEL
    CICLO · pago muy atrasado" y la columna `Días` de esas mismas filas decía
    "en gracia". Medido: las 2 cuotas de ese bloque pagaron a 2 y a 6 días, con
    gracia de 7. Pasa siempre que el `dia_pago` cae cerca del 14 — toda la
    gracia queda fuera del ciclo sin que el cliente se atrase. Los subtítulos
    pasan a decir solo CUÁNDO ("desde un ciclo siguiente"); el juicio de atraso
    lo da la columna Días, que es la que mira la gracia.
  · **DEUDA PROPIA SALDADA:** el (i) seguía describiendo la sub-fila "venían de
    mora" retirada el día anterior y prometiendo las 4 columnas de mora del
    Excel ya borradas. Al cambiar la tabla no se barrió el texto que la explica.
  · **TT-07 no es un error del seed:** `dashboard.json` lo describe como CRÉDITO
    A FAVOR APLICADO — cuota saldada con un cargo de −1.075 y cero filas en
    `pagos`. Pero el generador lo construyó a medias: el cargo quedó tipado
    `descuento_monto` en vez de `credito_aplicado` y no creó la fila en
    `saldos_favor` (`generar_seed_sql.py:373-386`). El efecto es correcto, el
    mecanismo no — o sea que ese escenario **hoy no prueba lo que dice cubrir**.
  · **DOS ENTREGAS MIAS QUE ESTABAN MAL (0.36.14).** Rubén: *"pedí líneas guías
    y el análisis de UI/UX que hiciste no funcionó porque se mira desalineado"*,
    y *"en el hover solo sale el monto pero no cuántas cuotas"*.
    (1) **La desalineación tenía causa medible:** la fila madre armaba su rótulo
    en 122px (8+6+108) y la sub-fila en 138 (22+12+6+98) → las columnas de
    números de las sub-filas quedaban **16px corridas**. Ahora los dos caminos
    miden 14 antes del rótulo y el rótulo mide 108: alineados por construcción,
    y coincide con el encabezado (14+108). Más la GUÍA que había pedido dos
    veces: una barra vertical del color de su fila madre.
    (2) **El tooltip:** `construirSerieTendencia` tiraba el `qty` de los días
    fuera de la ventana. Ahora lo acumula en `baselineQty`/`tailQty` y el
    tooltip dice "1 cuota · C$1.025,00".
  · **TRAMPA DEL WIDGET TEST, para la próxima:** `filaDeCobertura` localiza una
    fila con `find.ancestor(... byType(Row)).first`. Mi primer intento metió un
    `Row` ANIDADO para el rótulo y ese se llevó el match: la "fila encontrada"
    dejó de contener las celdas de números y 4 tests se cayeron. **La fila tiene
    que quedar PLANA.** Está comentado en el código.
  · **PENDIENTE:** los 7 tests de `dashboard_numeros_test.dart`, el arreglo del
    generador para TT-07, y las tarjetas 2 a 5 (apagadas tras
    `dashboard.pendientes_visible`).

- **(2026-08-27 e) — el Resumen queda en 5 tarjetas y es solo
  del admin. Paso 0 del rework.**
  · **RUBÉN FRENÓ EL TRABAJO:** *"la UI y UX está muy mal... se mira muy
    desordenado todo, habíamos aceptado que de todas solo 5 métricas se iban a
    quedar y dejaste todo visible, además que íbamos a ir de a 1 en 1"*. Tenía
    razón: se venían puliendo los rótulos de la tarjeta 1 sobre una pantalla que
    seguía mostrando los 11 bloques. Así "de a una" es invisible. **El flag no
    era el paso siguiente, era el paso CERO.**
  · **LO QUE QUEDA, en el orden de su lista:** 1 Cobertura del ciclo · 2 Mora 6
    ciclos · 3 Proyección · 4 Recuperación por cobrador y comunidad · 5 Top
    cobradores. Recuperación estaba DESPUÉS de Top cobradores, al revés.
  · **CÓMO SE APAGA EL RESTO SIN TOCAR PRODUCCIÓN** (pedido explícito: se itera
    local, sin migraciones ni UPDATE): clave nueva `dashboard.extras_visible`,
    default `false` y **deliberadamente NO sembrada**. `settingValue` cae al
    default cuando la fila no existe (`settings_repo.dart:186`), así que las
    seis nacen apagadas en TODOS los tenants sin escribir un registro. Cambiar
    el default de las otras seis `dashboard.*_visible` **no habría servido**:
    ya tienen fila (0133) y gana la fila — verificado contra la base, los tres
    tenants en `true` salvo sparkline.
  · **SOLO ADMIN:** se cierra en los DOS lugares porque uno solo no alcanza —
    `adminOnly: true` esconde la card y `/admin/resumen` en `soloAdmin` del
    router bloquea la URL directa. Resultado real: lo ven **admin, super_admin y
    `lectura`** (este último pasa los gates de rol por diseño documentado);
    quedan afuera `admin_cobranza` y `admin_usuarios`.
  · **RED NUEVA:** test que fija que por defecto se ven las 5 y ninguna de las
    otras 6. Y el harness ganó `extras: true` — 4 tests se rompieron al ocultar
    la caja y **uno pasaba por accidente** (*"admin_cobranza no ve la caja"*,
    que ahora nadie ve). Los 9 del widget test en verde.
  · **VERSIÓN 0.36.7** para que el MSIX local actualice sin desinstalar (con la
    misma versión Windows lo rechaza y el uninstall te hace re-loguear).
  · Commits `f655b981`, `2a054d2e`, `87a0fff0`. Instalado en la PC de Rubén como
    `com.sitecsa.crm` — Telecable (0.35.2) y Telenet (0.27.0) sin tocar.
  · **PENDIENTE:** los 7 tests de `dashboard_numeros_test.dart` (valores del
    escenario de 15 clientes), y seguir de a una con las tarjetas 2 a 5.

- **(2026-08-27 d) — la tarjeta de Cobertura hablaba dos
  idiomas. Ahora uno solo, el del dueño.**
  · **EL PEDIDO:** *"los rótulos tienen que ser cobros, recuperado y por
    recuperar"*, con un mockup hecho por él en Excel, y *"los textos están muy
    extensos, tienen que ser más compactos y directos"*.
  · **DOS DIAGNÓSTICOS MÍOS SALIERON MAL, LOS DOS POR NO MIRAR LA RAMA QUE
    RENDERIZA.** Primero inventé una sub-fila ("abonos a cuotas que siguen
    debiendo") que la app no tiene, para que cerrara mi mockup. Después dije que
    la tarjeta mostraba las mismas cifras en DOS tablas. Falso: `_TablaSummary`
    elige UNA por si la consulta trae `comp_c`, y `resumenCobros` lo trae. La
    otra tabla —la que tiene los tres rótulos que él pedía y la columna
    Servicios— es la que dibuja la tarjeta de **Mora**. Lo cazó el panel.
  · **O SEA QUE LO QUE HABÍA QUE RENOMBRAR ERA OTRA COSA:** no las sub-filas
    `:527`/`:1373` (que no se dibujan nunca en un ciclo con datos) sino los
    `fila3` de la tabla de partición. Ahora: Cobros / Recuperado / ↳ venían de
    mora / Por recuperar / ↳ ya vencidas.
  · **TRES BUGS DEL REDISEÑO, NINGUNO EN LA CALLE, LOS TRES SE PUBLICABAN:**
    (1) la leyenda de la gráfica de Mora imprimía el token crudo
    `$metaLabel (100%)` —un `\$` escapado mató la interpolación; es REGRESIÓN,
    la publicada lo tiene bien—; (2) `admin_cobranza` leía "Tu rol no muestra
    montos cobrados" con el monto cobrado arriba: `ocultarRecaudado` estaba solo
    en la tabla genérica; (3) el título decía "(monto C$)" sobre un eje en
    porcentaje.
  · **`estaban en mora` vs `están en mora`** convivían a seis líneas, mismo
    naranja, dos letras de diferencia, significados opuestos.
  · **NO se usó "cobrado en mora"** aunque él lo aprobó: ese número es el
    FACTURADO de esas cuotas, no lo que entró tarde. Queda "venían de mora".
  · **El (i)** describía columnas `Entró`/`Falta` y "dos cortes del mismo 100%"
    que la tabla no dibuja: reescrito, de 3.337 a 1.688 caracteres.
  · Commit `f556dc0`. `analyze` limpio; tests 29 ✅ / 7 ❌ — los mismos 7 de
    antes, todos en `dashboard_numeros_test.dart` (valores del escenario viejo).
  · **PENDIENTE:** los 7 tests, traer la tarjeta de Mora de 6 ciclos desde la
    rama publicada, el flag de Dev para las otras 7 tarjetas, y compilar el MSIX
    local para que Rubén lo vea.

- **(2026-08-27 c) — la columna del Resumen decía "Usuarios" y
  contaba servicios. Ahora dice lo que cuenta.**
  · **EL RECLAMO ERA VIEJO:** *"los números de clientes y cuotas no hacen match,
    siempre había más cuotas que clientes"*. Al ir a arreglarlo apareció que la
    CUENTA ya estaba corregida desde el 2026-08-24 —cuenta contratos a propósito,
    para que la columna cierre contra "Cuotas"— y el propio comentario de
    `dashboard_query.dart` lo documenta citando ese reclamo. **Lo único que
    quedó sin arreglar fue el RÓTULO**, que siguió diciendo "Usuarios".
  · **Casi lo rompo:** iba a cambiar la cuenta a personas, que es exactamente lo
    que el fix del 24/08 había descartado con la medición al lado (con contratos
    las tres filas dan 1:1 en 21 de 26 ciclos vivos). Lo frenó leer el comentario
    antes de editar.
  · **QUÉ SE TOCÓ:** el encabezado de la tarjeta (`tendencia_cobros_card`), la
    nota del panel (i), el pie del Excel —que decía "N usuarios" y ahora dice
    "N servicios"— y el comentario de `dashboard_query` que afirmaba
    "la etiqueta sigue diciendo Usuarios por decisión de producto", ya falso.
    **Ningún número cambió**: solo el nombre de la columna.
  · **DECISIÓN ESTRUCTURAL TOMADA:** el rework se hace sobre `main`. La versión
    publicada tiene 28 bloques de SQL pegados con `date('now')` fijo —imposible
    de testear—; la de `main` es la MISMA tarjeta con las consultas extraídas y
    `hoy` como parámetro, que es lo que sostiene las 641 líneas de pruebas.
    **No son dos dashboards: es el mismo, refactorizado.** La excepción es la
    tarjeta de Mora de 6 ciclos, que solo existe en la publicada y hay que
    traerla (main tiene "Recaudo y mora" en su lugar, que va al flag de Dev).
  · **PENDIENTE:** los 7 tests con valores esperados del escenario de 15
    clientes. Y decidir qué pasa con "Cuotas por cobrar" del Resumen, que sigue
    incluyendo el colchón futuro.

- **(2026-08-27 b) — el escenario del dashboard pasa de 15 a 60
  clientes, con cobradores y comunidades, y con la forma real de una cartera.**
  · **QUÉ SE PIDIÓ:** rework del dashboard. Rubén eligió quedarse con 5 tarjetas
    (Cobros del ciclo · Mora 6 ciclos · Proyección por cobrador · Recuperación
    por cobrador y comunidad · Top cobradores) y pidió sembrar el Test Tenant
    con data realista, *"100% correcta según la arquitectura contable"*.
  · **QUÉ SE HIZO:** `supabase/escenarios/poblacion.py` (nuevo) genera 45
    clientes de población por PERFIL DE PAGO; los 15 curados no se tocan. Los
    dos generadores aprendieron `cobrador`, `comunidad` y `cliente_activo`. Se
    crearon 6 comunidades con nombres reales (las que había eran "QA-SCROLL
    Barrio"). Reparto: 18/16/16 entre los tres cobradores + 9 sin asignar.
  · **LA CURVA QUE PRODUCE**, medida contra la base: recuperación **98 → 94,4 →
    86,8 → 78,8 → 52,2 → 10,7%** en los 6 ciclos, con el facturado CRECIENDO
    (35.680 → 40.385). Es casi calcada de la real de Mairena (98 → 43).
  · **VERIFICACIÓN:** los 32 invariantes de dinero corren y el Test Tenant queda
    en **CERO violaciones** (las 2 que quedan son el baseline viejo de Mairena).
    El cruce caja-vs-arqueo cierra: **C$28.195 = C$28.195**.
  · **🔴 CINCO INVARIANTES QUE EL ESCENARIO ROMPIÓ AL PRINCIPIO, y qué enseñan:**
    (a) **INV21 oldest-first** — había diseñado clientes que "saltean un ciclo y
    siguen pagando" para dar variación. Eso la app NO lo permite
    (`_validarOldestFirst`). La variación se rehizo con gente que deja de pagar
    en ciclos distintos. (b) **INV32** — el caso curado TT-10 era
    "CANCELADO CON DEUDA", que la regla del 24/08 **abolió**: describía el mundo
    viejo, igual que el filtro que sacamos. Se actualizó. (c) **INV8** — el hash
    del cobrador usaba el código del contrato y TT-05a/TT-05b son dos contratos
    del MISMO cliente. (d) **INV17** — el colchón arrancaba en fecha fija.
    (e) **INV27** — el seed no emitía `op_log`; ahora sí, como hace la app.
  · **🔴 LA DIVERGENCIA DE LOS DOS SEEDS, EN VIVO:** los dos filtraban
    `startswith('TT-')`, así que los 45 de población entraban al de Postgres y
    **no al de SQLite** — 59 clientes contra 14, sin fallar. Es exactamente
    contra lo que advierte el mapa de impacto. Los dos arreglados; hoy los dos
    dan 59/343/245, idéntico a la fuente.
  · **🔴 Y UN TEST QUE PASABA POR CASUALIDAD:** "la caja del dashboard da IGUAL
    que el arqueo" comparaba el arqueo `BETWEEN 15/08 y 14/08` contra una caja
    `>= 15/08` **sin tope**. Pasaba solo porque el escenario viejo no tenía
    pagos después del 14. Con data nueva falló por C$5.300 — que no era una
    diferencia de plata, sino de ventana. Acotado igual, cierra.
  · **PENDIENTE (Fase 4 del plan):** 7 tests siguen rojos porque sus valores
    esperados están calculados a mano para el escenario de 15 clientes. Hay que
    reescribirlos ANTES de tocar las tarjetas — si se anota lo que salió, el
    escenario deja de verificar nada.

- **(2026-08-27) — PUBLICADO: v0.36.6 está en manos de los
  usuarios. Todo lo de esta semana llegó a los dos ISPs.**
  · **Release:** https://github.com/rubenmaltez/sitecsa-updates/releases/tag/v0.36.6
    (Latest, 8 assets branded, manifests apuntando a 0.36.6). Rama
    `release/v0.36.6` (`a8b7b4a`) pusheada. `main` en `54f20c5`.
  · **Lo que llegó:** el recibo congela su mes (`0262`) · la deuda suspendida
    entra al Resumen y al reporte de Mora (Telenet +17,6% de mora visible) · el
    saldo a favor alcanza al contrato suspendido · el rol `lectura` ya no mueve
    plata desde ese botón · desactivar condona (`0260`/`0261`) · fuera el filtro
    "Cancelado con deuda". Migraciones ya estaban aplicadas antes de publicar.
  · **🔴 EL APRENDIZAJE DE LA SESIÓN, y no es técnico:** afirmé que el rediseño
    del dashboard estaba enredado con los reportes porque
    `reportes_admin_screen → arqueo_query → dashboard_query`. **Era falso.**
    `arqueo_query.dart` no importa nada: la mención a `dashboard_query.dart`
    está en un COMENTARIO de su cabecera. Leí un hit de grep como si fuera un
    import, y sobre ese diagnóstico Rubén aprobó una opción que no hacía falta.
    Lo cazó abrir el archivo. **Regla: `grep -rn "^import.*x.dart"`, nunca
    `grep -rn "x.dart"`.** Quedó escrito en `1b-Armar-la-rama-de-release.md`.
  · **Lo segundo que se destapó:** el dashboard publicado NO compila contra los
    providers de `main`, así que armar el release exige volver también
    `dashboard_providers.dart` y **reaplicar a mano** lo que main le hizo esa
    semana. Ahí `flutter analyze` cazó que mi reemplazo se había comido el
    predicado de "Vencimientos próximos". Sin analyze, salía roto.
  · **Receta escrita:** `Install Steps/1b-Armar-la-rama-de-release.md` +
    referencia desde el paso 1. Incluye el gotcha de OneDrive (`git merge` falla
    con `couldn't set 'ORIG_HEAD'` — es el rename del lock, no permisos).
  · **v0.36.5 NO se borró**, contra la política de "solo el release vigente":
    es el rollback si algo sale mal en la calle. Borrarlo cuando 0.36.6 esté
    confirmado funcionando.
  · **PENDIENTE:** el `main` LOCAL sigue en `3c34308` — hay que hacerle
    `git pull` en el worktree principal. Y sigue abierto por qué el papel de
    Gloria dice "Julio" (se cierra preguntándole a Harinton la versión).

- **(2026-08-26 m) — el recibo ya no puede contradecirse a sí
  mismo: congela el mes que imprime (`0262`).**
  · **EL CASO:** Byron reportó que el recibo **HL-00230** de Telecable Mairena
    (cliente R20014, Gloria María Larios) dice **"Julio 2026"** en manos del
    cliente y **"Junio 2026"** en la app. Mismo cobro, misma plata, correlativo
    usado UNA sola vez — verificado: cero correlativos duplicados en el tenant.
  · **LA CAUSA, simple:** `recibos` **no guardaba el mes**. Lo recalculaba en
    CADA impresión desde `cuota.periodo` + `contrato.dia_pago`. Esa regla cambió
    3+ veces en 2026 (una de ellas duró 19 horas), así que un papel viejo y una
    reimpresión de hoy pueden decir meses distintos.
  · **QUÉ SE HIZO:** columna `recibos.periodo_label`, escrita al emitir el recibo
    (los 3 sitios de `pagos_repo`), leída por los 3 renderers. `NULL` = recibo
    viejo o sin período impreso → se calcula, igual que antes. **Ningún número de
    plata cambia**; es solo el rótulo.
  · **NO se hace backfill A PROPÓSITO:** para los ~49 recibos impresos en la
    ventana 31/07–01/08 el rótulo de hoy NO es el de su papel, y el original no
    quedó guardado. Rellenarlo sería escribir una mentira con cara de dato.
  · **Dos trampas que el mapa de impacto destapó y se cerraron:** (a) el helper
    corre DENTRO del `writeTransaction` del cobro → si lanzaba, el cobrador no
    podía cobrar; va con `try/catch` + `tryParse` y tiene test propio; (b) el
    seed usaba `to_char(...,'TMMonth')` y la base está en `lc_time=en_US`, así
    que generaba **"June 2026"** — se cambió por nombres en español a mano.
  · **VERIFICADO:** 102 tests de `pagos_repo` en verde (4 nuevos) · 53 de
    `formatters` · migración aplicada y chequeada por CONTENIDO · los 5 buckets
    de sync usan `SELECT *`, así que la columna viaja sola (**no hubo que tocar
    las sync rules ni reiniciar el VPS**) · los DOS seeds regenerados y alineados.
  · **DE PASO, el estado del mes de servicio quedó auditado:** las 15 superficies
    que rotulan una cuota usan la MISMA función; los 6 usos de `Fmt.mes()` crudo
    son fechas de calendario (nombre de export, eje de gráfica, encabezado de
    reporte) y están bien; y aplicando la regla a **54.685 cuotas reales de 5.466
    contratos hay CERO meses repetidos** dentro de un contrato.
  · **PENDIENTE:** merge a `main` + release. Sigue abierto por qué el papel de
    Gloria dice "Julio" si figura impreso 7 h antes de que existiera esa regla —
    se cierra preguntándole a Harinton la versión de su app. Y `app_dispositivos`
    solo registra 2 de los 6 usuarios de Mairena: los cobradores de campo, que
    son quienes imprimen, no aparecen.

- **(2026-08-26 l) — el saldo a favor ya alcanza al suspendido, y
  se destapó que el titular del dashboard cuenta 20.038 cuotas que no vencieron.**
  · **SALDO A FAVOR (hecho, commiteado).** El botón "Aplicar" solo ofrecía cuotas de
    contratos ACTIVOS: un cliente con crédito y un contrato suspendido con deuda no
    podía usar su propia plata contra la deuda que se le está cobrando. Ahora entra
    `suspendido`. **NO se pasó a LEFT JOIN** —era la otra mitad de mi propuesta y el
    panel la tumbó—: `saldos_favor.contrato_id` es NOT NULL, así que alcanzar los
    cargos sueltos reventaría con 23502 EN EL SERVER después de que SQLite ya escribió
    local; offline-first ⇒ el usuario ve el crédito aplicado y el sync lo rechaza.
    Queda escrito en el código y en R17 para que nadie lo "arregle".
  · **De yapa, dos cosas que salieron del mismo barrido:** el rol **`lectura` podía
    apretar "Aplicar"** y escribir cargo + `saldos_favor` + `op_log` a su nombre
    (`verDinero` lo incluye a propósito, pero `_aplicar` nunca chequeaba
    `soloLecturaProvider`) → cerrado con doble red; y si la consulta del saldo fallaba
    **la tarjeta desaparecía entera**, indistinguible de "no tiene crédito" → ahora lo
    dice. Más el callejón "No hay cuotas pendientes", que no explicaba qué pasa con la
    plata.
  · **ALCANCE REAL:** 7 clientes tienen crédito (5 Mairena, 2 Telenet, ~C$1.525) y
    **ninguno estaba bloqueado hoy** — el fix es preventivo, no recupera plata. En
    producción `saldos_favor` no tiene **ni una fila `aplicado`**: el botón nunca se
    usó con éxito, y no hay tests ni seeds que lo cubran.
  · **⏸️ PARQUEADO POR RUBÉN — EL TITULAR DEL DASHBOARD.** Se le presentaron 3
    opciones y decidió: *"si esto toca el dashboard de momento vamos a omitir"*, en
    línea con que el rediseño del dashboard y WhatsApp esperan a que el flujo de
    dinero esté consistente. **Lo único que se tocó fue el texto del (i)**, que decía
    "TODO lo que nos deben" sobre un número donde 4 de cada 5 córdobas no vencieron —
    era una afirmación escrita ese mismo día y falsa. Cero números, cero consultas.
    El diagnóstico completo quedó en ARQUITECTURA §3.5-4 para quien retome el
    rediseño. **EL HALLAZGO, para no perderlo:** Rubén reportó que había
    más cuotas que clientes, contra la lógica del período. Medido: de las 24.242
    cuotas del titular, **20.038 (C$19.022.568,61) todavía no vencieron** — son el
    COLCHÓN (3 meses pre-generados por contrato indefinido para que el cobrador pueda
    adelantar offline; los fijos generan todo el plazo, hay cuotas hasta 2028).
    Lo que realmente se debe hoy son **4.202 cuotas / C$3.515.614,50**. Sacando el
    colchón la cartera se lee bien: 1,85 cuotas por deudor en Mairena, 1,59 en Telenet.
    **NO se tocó:** cambiar qué mide ese titular arrastra la columna "Saldo" de la
    tarjeta de cliente, el reporte "Estado de clientes" (PDF+Excel), el Padrón, los
    tres campos de plata del export de clientes y el desglose "De eso, suspendido"
    (que dejaría de ser subconjunto). Mover uno solo rompe el invariante #10.
  · **Panel:** 4 especialistas + escéptico, 50 hallazgos → **21 confirmados, 27
    corregidos, 2 falsos**. El escéptico mató el susto de que el titular no filtrara
    `tenant_id` (es la convención de todo el archivo, y el caso del super_admin se
    resuelve en otro lado).
  · **También quedó verificado el modelo de Rubén:** CERO clientes con 2 contratos
    activos en los dos ISPs (Mairena 4.409 con exactamente 1, Telenet 1.011).

- **(2026-08-26 k) — la deuda SUSPENDIDA entró al número que el
  dueño mira primero: Telenet tenía 17,6% más de mora del que veía.**
  · **QUÉ SE PIDIÓ:** verificar que los estados de contrato se traten igual en
    dashboard, arqueo y listas. Rubén cerró el modelo: *"lo que ya no se debe
    filtrar es los clientes desactivados o contratos cancelados; los suspendidos
    todavía mantienen deuda cobrable, entonces eso sí debería aparecer"*.
  · **POR QUÉ ESTABA MAL:** el titular "Cuotas por cobrar"/"En mora" y las 3 queries
    del reporte de Mora carvaban `!= 'suspendido'`. Eso era coherente **antes** del
    2026-08-24, cuando suspender y cancelar hacían casi lo mismo. Desde que
    suspender significa *"se fue debiendo y le vamos a seguir cobrando"*, era la
    deuda MÁS cobrable que hay y la única que no entraba al número principal.
  · **QUÉ SE HIZO:** se sacó el filtro del titular, de las 3 queries de Mora (PDF,
    Excel, tarjeta) y de **Recuperación por cobrador y comunidad** + su drill-down
    (esta última NO estaba en el pedido: se movió porque es el desglose de la mora
    y si no, la misma pantalla mostraba "En mora C$X" arriba y C$X−92.374 abajo →
    invariante #10). El KPI dejó de ser un cuarto balde: ahora se llama **"De eso,
    suspendido"** = desglose de cuánto no sale en la ruta del día.
  · **NÚMEROS (medidos contra vxxz):** Mairena mora C$1.893.987 → **C$1.896.881**;
    Telenet mora C$508.678 → **C$598.158 (+17,6%)**. Cancelados y desactivados
    aportan **0 cuotas** — por eso se pudo sacar el filtro sin esconder nada.
  · **QUEDA AFUERA A PROPÓSITO:** "Vencimientos próximos", la lista de Cobros, el
    mapa y el cron de `notificaciones_mora`. Son RUTA (a quién visitar) y a un
    contrato sin servicio no se lo visita por su cuota nueva. Escrito en el
    `noIncluye` de cada panel y en ARQUITECTURA §3.5-4.
  · **LO QUE ESTO DESTAPÓ (más importante que el fix):** el índice de la regla
    `suspension` **no traía ninguna de las superficies que había que tocar** — sus
    símbolos indexan cómo se EJECUTA la suspensión, no dónde se VE su deuda. Se le
    agregaron 8 símbolos (`saldoSuspendido`, `saldo_suspendido`, los `kInfo*`…) y
    pasó de 38 a 43 superficies. **El índice tenía un agujero del tamaño del pedido.**
  · **INV32 nuevo:** "contrato cancelado sin deuda viva", la premisa de la que ahora
    depende el titular. Sin filtro, un cancelado con deuda ya no queda escondido: se
    SUMA. Da 0 hoy; puede dar >0 (ya pasó: 44 contratos de Mairena con build viejo).
  · **PENDIENTE:** nada de esto está en manos de los usuarios — falta merge a `main`
    y release. Promover INV32 al panel del super_admin necesita migración (no se hizo
    sin aprobación). CI en rojo por 2 jobs previos. Colisión `0260` con la rama de
    WhatsApp.

- **(2026-08-26 j) — SE CERRÓ EL HILO: el filtro que abrió todo
  esto ya no existe, y no puede volver.**
  · **QUÉ:** fuera el filtro **"Cancelado con deuda"** de la lista de clientes — el
    caso exacto que Rubén reportó el primer día. Se mantuvo vivo a propósito mientras
    existieron los 5 contratos de Telenet (era la única forma de encontrarlos); al
    condonarlos (`0261`) quedó **estructuralmente vacío**: devolvía **0 clientes** y no
    puede volver a tener ninguno. Su vecino "Suspendido con deuda" se queda: devuelve
    **30 clientes reales** y es correcto — son opuestos, no variantes.
  · **RECIÉN AHORA entró como PATRÓN PROHIBIDO.** Antes habría sido una alarma que
    suena siempre (checklist #14). Probado: con el identificador de vuelta el
    verificador sale 1; en limpio, 0. **El CI falla si alguien repone la categoría.**
  · **LO QUE NO SE SACÓ, Y ES DELIBERADO:** el chip "debe C$X fuera de ruta", los dos
    exports con la fila "Fuera de ruta — cancelados" y la ruta de Recuperación del
    cobrador **siguen incluyendo `cancelado`** en su consulta. Hoy aportan cero, pero
    si la condonación alguna vez falla esa deuda aparece ahí en vez de desaparecer en
    silencio. **Es una red, no código muerto — escrito en la ficha para que nadie la
    "limpie".**
  · **⚠️ CHOQUE QUE VA A APARECER SOLO:** la rama `feature/whatsapp-mora-meta` tiene
    `0260_whatsapp_mora_meta.sql` y esta rama tiene `0260_desactivar_cliente_...`.
    **Dos migraciones con el mismo número**: hay que renumerar una ANTES de mergear
    esa rama.
  · **DECISIÓN DE RUBÉN (2026-08-26): el rediseño del DASHBOARD y el WHATSAPP quedan
    para después.** No son pendientes sueltos: se retoman **cuando el flujo de dinero
    esté optimizado y consistente**. Ese es el disparador.

- **👉 NUEVO (2026-08-26 i) — EL "HUECO DE LOS SEEDS" ERA MI MALA LECTURA;
  el hueco REAL era otro y ya está cerrado.**
  · **CORRECCIÓN, importante para el próximo que lea la bitácora.** Reporté que tres
    reglas "no aparecen en ninguno de los dos seeds". **Era falso.** `regla.py`
    marcaba esas capas vacías porque los símbolos de esas reglas son funciones de
    **Dart** (`ventanaServicio`, `_validarOldestFirst`, `arqueoSql`), que jamás
    podrían aparecer en un seed SQL. Leí la ausencia como falta de cobertura, dos
    veces seguidas.
  · **LA REALIDAD, medida:** el escenario tiene **16 clientes y 31 casos borde
    declarados**, con días de pago 1, 2, 5, 8, 10, 12, 14, 15, 18, 20, 22, 25 y 28
    — o sea que el bug del `dia_pago = 1` YA está cubierto. **oldest-first** tiene un
    grupo entero de tests (`chokepoint oldest-first (#4)`) más 3 en cobros, y
    **mes-servicio** tiene su propio `prorrateo_test.dart`.
  · **ARREGLADO EL FALSO NEGATIVO en `regla.py`:** si TODOS los símbolos de una regla
    son identificadores de Dart, las capas de SQL/YAML vacías se reportan como
    **ESPERADAS**, con la explicación de que eso no dice nada sobre la cobertura.
    Las reglas con símbolos snake_case (como `cancelacion`) siguen preguntando.
  · **EL HUECO DE VERDAD:** el trigger de `0260` **nunca había disparado** — el
    backfill llamó a la función directo, no al trigger. **Probado end-to-end contra
    produccion, sin escribir:** `suspendido -> cancelado`, deuda `C$248,23 -> 0,00`,
    **pagos vivos 31.462 -> 31.462**. Guardado como artefacto reusable en
    `supabase/tests/probar_baja_cliente.sql`, con qué tiene que dar y qué significa
    cada forma de fallar.

- **👉 NUEVO (2026-08-26 h) — `tools/estructura.py`: lo que se declara
  COMPLETO ahora se verifica solo.**
  · **EL PROBLEMA DE FONDO, no el caso.** Las dos tablas de ARQUITECTURA que se
    declaran completas —el mapa por tabla (§3.6.1) y los buckets (§3.8)— se
    mantienen a mano y **las dos se atrasaron**. Arreglarlas a mano deja el mismo
    problema para dentro de un mes.
  · **LA CLAVE DEL DISEÑO: corre sin tocar la base.** Deriva las tablas de las
    migraciones (`CREATE TABLE` menos `DROP TABLE`) y los buckets del yaml, así que
    **el CI puede correrlo sin credenciales**. La derivación se validó contra
    producción: **50 derivadas del repo, 50 reales, cero diferencias en ambas
    direcciones**. Sin eso el chequeo habría quedado como script local, o sea
    dependiendo otra vez de que alguien se acuerde.
  · **PROBADO EN LOS DOS SENTIDOS** (checklist #14): con una tabla sin documentar
    exit 1, con un bucket sin documentar exit 1, en limpio exit 0. Puede dar >0 y
    puede satisfacerse.
  · **Enchufado al CI** como paso del job `reglas-de-negocio`, y `AGENTS.md` → regla
    de oro §1 ahora lista **las tres herramientas** (impacto / regla / estructura)
    con qué contesta cada una y cuándo se corre.
  · **LÍMITE ESCRITO:** verifica que la tabla ESTÉ listada, no que su fila diga la
    verdad. Las FKs, triggers y policies de §3.6.1 siguen siendo a mano.

- **👉 NUEVO (2026-08-26 g) — BARRIDO DE DOCUMENTACIÓN: dos tablas que se
  declaraban completas y no lo eran.**
  · **§3.6.1, el "mapa EXHAUSTIVO por tabla":** decía estar generado del schema real
    (03/07) y **le faltaban 5 tablas** creadas después — `app_dispositivos`,
    `dashboard_pins`, `recibo_correlativos`, `recibos_huecos_ignorados` y
    `sync_rechazos`. Agregadas con sus FKs y policies REALES (consultadas a
    producción, no inferidas), más un aviso de que se mantiene a mano, la consulta
    para chequearlo y la nota de que lo sano sería generarlo con un script.
  · **§3.8, los buckets de sync:** no existía tabla; estaban sueltos en prosa y
    **cinco no se nombraban en ningún lado**, incluido `todo_tenant_lectura` — el del
    rol que §3.9 describe entero. Ahora están los **15**, con el rol al que responde
    cada uno, verificados contra el yaml.
  · **Lo que NO se tocó, y por qué:** los "33 triggers" de `audit_log` son un hecho
    histórico correcto, y el "20 chequeos" de AGENTS es la REGLA citando el mal
    ejemplo, no un conteo. Re-"arreglarlos" habría sido romperlos. Lo de
    "Ajustes > Impresora" ya estaba corregido; solo sobrevive en la bitácora como
    relato.
  · **Pendiente de fondo:** las dos tablas se mantienen A MANO y las dos se
    atrasaron. Generarlas con un script desde `pg_tables`/`pg_trigger`/`pg_policies`
    y el yaml es la salida real; queda anotado en §3.6.1.

- **👉 NUEVO (2026-08-26 f) — LAS 6 REGLAS DE NEGOCIO YA TIENEN FICHA
  (antes había UNA) + dos decisiones de rol registradas.**
  · **POR QUÉ:** hasta hoy solo la cancelación tenía ficha, así que el verificador
    frenaba los cambios de ESA regla y de ninguna otra — no porque las demás
    estuvieran bien, sino porque nadie las miraba. Es exactamente el origen de las
    contradicciones que aparecieron en el análisis de hoy.
  · **FICHAS NUEVAS:** `suspension` (38 superficies) · `oldest-first` (8) ·
    `mes-servicio` (29) · `credito-excedente` (46) · `cobrador-organizativo` (18).
    Verificador en verde con las 6; el CI las cubre a todas.
  · **HALLAZGO QUE EL ÍNDICE DESTAPÓ SOLO:** **tres reglas no aparecen en ninguno de
    los dos seeds** — oldest-first, mes de servicio y cobrador organizativo. El
    escenario de prueba no las ejercita, y los seeds ya divergieron de producción
    tres veces. Pendiente.
  · **DECISIÓN — `coordinador`:** sí debe poder asignarse, **pero todavía no**: el
    módulo donde trabaja no está habilitado. Pasa de "incoherencia" a **pendiente con
    disparador**, con los dos lugares exactos anotados en `PRODUCTO.md` (el Edge
    `invitar-cobrador` y `set_cobrador_rol`).
  · **DECISIÓN — la cola de aprobaciones:** aprobar **sigue siendo solo del `admin`**.
    Riesgo aceptado y medido: **un solo admin activo por empresa** para ~15
    solicitudes diarias (313 Mairena + 143 Telenet en 30 días). Hoy va al día —cero
    pendientes— pero es cuello único. Si alguna vez se abre, hay que impedir la
    auto-aprobación o el permiso no sirve de nada.

- **👉 NUEVO (2026-08-26 e) — LA CONDONACIÓN SIN CORTE POR FECHA + LA
  MATRIZ DE ROLES.**
  · **`0261` APLICADA.** El corte `cancelado_en >= 2026-08-24` de 0259 no representaba
    ninguna regla: existía solo para proteger los 5 de Telenet, y Rubén levantó esa
    protección. **La norma es universal: si está cancelado, no queda nada pendiente.**
    Backfill con la MISMA función del trigger. Verificado: **0 contratos cancelados con
    deuda**, 23 filas de `op_log` por **C$19.147,81** exactos, **INV19 en CERO**, el gate
    devuelve `true` para bajas de julio (ejecutado, no grepeado) y la plata idéntica
    (31.442 pagos vivos, 31.444 recibos, C$28.112.883,66 antes y después).
    **Cambio de criterio respecto de `0258`**, que los había preservado a propósito
    porque el ISP los cobraba; Rubén lo confirmó dos veces sabiendo eso.
  · **MATRIZ DE PERMISOS → `PRODUCTO.md`**, referencia canónica, con índice desde
    ARQUITECTURA §0. Decisión de Rubén registrada: **`admin_cobranza` NO solicita bajas
    de cliente; eso es de `admin_usuarios`** — y hoy ya se cumple.
  · **DOS INCOHERENCIAS ENCONTRADAS, NO RESUELTAS** (anotadas en `PRODUCTO.md` para que
    no se redescubran como bugs nuevos): **el rol `coordinador` no se le puede asignar a
    nadie** — existe entero (CHECK, RLS, trigger, bucket, shell, dropdown) pero ni el
    Edge de invitación ni `set_cobrador_rol` lo tienen en su allowlist, **verificado
    contra producción**—; y **`admin_cobranza` no llega a la cola de aprobaciones**
    aunque la RLS y su bucket se lo permiten, lo que con el permiso nuevo puede
    acumular la cola si el admin no está.
  · **Roles vivos hoy** (medido): 3 `admin`, 3 `admin_cobranza`, 3 `admin_usuarios`,
    8 `cobrador`, 1 `super_admin`. `lectura`, `tecnico`, `admin_tickets` y
    `coordinador` están construidos y sin un solo usuario.

- **👉 NUEVO (2026-08-26 d) — CLIENTE DESACTIVADO = TODO CONDONADO.
  COMPLETO: SERVER, APP, TESTS Y DOC.**
  **REGLA NUEVA (Rubén, 2026-08-26):** un cliente desactivado no puede tener nada
  pendiente: sus contratos vivos —incluso los SUSPENDIDOS— pasan a cancelado y la
  deuda se condona. Solo el histórico cuenta.
  · **APLICADA A PRODUCCIÓN: migración `0260`.** Saca el guard de `0220` (bloqueaba
    desactivar con deuda: la regla vieja, al revés de esta), instala
    `cancelar_contratos_por_baja_cliente` + el trigger `zz_clientes_baja_cancela_contratos`
    y backfillea. **Verificado por contenido:** guard eliminado, trigger y función
    instalados, **9 contratos cancelados**, **0 clientes desactivados con contrato vivo**,
    y la plata IDÉNTICA antes y después (31.430 pagos vivos, 31.432 recibos,
    C$28.098.268,66). Probada antes en una transacción auto-revertida.
  · **QUEDAN C$10.277,88** en clientes desactivados: son **2 de los 5 contratos
    históricos de Telenet** (MV0167 y QH0073, cancelados en julio), protegidos por el
    corte de fecha de 0259 y pendientes de la decisión de la notificación.
  · **LA MITAD DART, YA ENTREGADA.** (1) **Desactivar pide APROBACIÓN** — el `admin`
    ejecuta, el resto solicita (`TipoSolicitud.desactivarCliente`, que volvió a estar
    en uso). **Reactivar sigue siendo directo**: no mueve plata. (2) Diálogo de
    confirmación con el monto real y **motivo obligatorio**, que se guarda como fila
    propia de `op_log` (`tipo_op: baja_cliente`). (3) La tarjeta del aprobador ahora
    SÍ dibuja la deuda de una baja de cliente — antes devolvía vacío y se aprobaba a
    ciegas. (4) Salieron los DOS guards de la app (contratos activos y deuda): eran de
    la regla vieja y bloqueaban el efecto buscado. (5) El subtítulo del switch decía
    *"NO frena la facturación"* y ahora es lo que más la frena.
  · **`previewBajaCliente`** espeja al server: suma los contratos vivos y **deja
    afuera los ya cancelados**, porque el gate por fecha de 0259 no los toca y
    prometerlos condonados sería mentir. Test nuevo que lo fija.
  · **LA LÍNEA GENERAL, escrita donde se carga sola:** `AGENTS.md` principio 6 —
    *toda acción con repercusión monetaria pide autorización del admin*, quien autoriza
    ve el número calculado con el MISMO criterio que la mutación, y **al cambiar lo que
    una acción HACE hay que revisar quién puede hacerla** — que es exactamente cómo
    `admin_usuarios` terminó pudiendo condonar una cartera con un toggle.
  · **Doc:** ARQUITECTURA (§0 + §Clientes), MODULOS, la guía de usuario con su mockup
    regenerado y la ficha de la regla (37 superficies). analyze sin errores ni
    warnings; 8 tests verdes en el grupo de cancelación.
  · **Hallazgo del escéptico que sostiene el (1):** cuando en julio se decidió que
    desactivar fuera directo, la justificación escrita fue *"no saltea la regla porque
    el guardado bloquea"* — o sea que el permiso se apoyaba en el guard que 0260 acaba
    de sacar. Tumbó 3 de 6 hallazgos del panel (la trampa de fecha, "la cascada no puede
    firmarse" y lo del super_admin).

- **👉 NUEVO (2026-08-26 c) — EL QUE AUTORIZA UNA CANCELACIÓN VEÍA UN
  NÚMERO QUE NO ERA EL QUE SE BORRABA.** Primer pedido atacado con el protocolo
  `/pedido` completo: índice → panel de 4 especialistas → escéptico → propuesta con
  mockup → aprobación → implementación.
  **DÓNDE RETOMAR:** falta decidir/ejecutar lo de los **5 contratos de Telenet**
  (abajo) · falta publicar (el cambio está en la rama, sin release).
  · **EL HALLAZGO.** `previewDeudaCancelacion` delegaba **literalmente** en
    `_calcularDeudaSuspension`, o sea calculaba con la regla ANTERIOR al 24/08:
    descartaba las cuotas futuras pendientes y prorrateaba la del mes en curso.
    La mutación no clasifica por ventana: pone en cero el saldo ENTERO de toda cuota
    viva. Resultado: **quien autorizaba la baja aprobaba un monto MENOR que el que el
    sistema borraba**, y ese mismo monto viajaba al snapshot, al **documento que se le
    entrega al cliente** y a la tarjeta del contrato. Cuatro superficies.
  · **Y el rótulo decía lo contrario.** En el camino por SOLICITUD —el del rol que
    decide la mayoría de las bajas— quien pide y quien aprueba leían *"Deuda que
    quedaría cobrable"* también al cancelar, y no veían **ninguno** de los textos
    nuevos ("es PERMANENTE", "se CONDONA", "usá SUSPENDER").
  · **QUÉ SE HIZO.** `_calcularDeudaCancelacion` nueva, que espeja la mutación
    cláusula por cláusula · rótulos **por tipo** en las 3 pantallas · el PDF pasa a
    "Constancia de condonación" / "Condonado" / "Total condonado" · `cancelarContrato`
    pierde `fechaCancelacion`/`precioMensual` (sin prorrateo no dependen de nada) ·
    guía de usuario y sus 2 mockups regenerados · R16 y la ficha al día.
  · **LA RED QUE FALTABA:** el test se llamaba *"el snapshot guarda lo condonado"* y
    **nunca miraba `snap['total']`**. Ahora sí, más un test nuevo con vencida + en curso
    + futura que fija que se cuentan las tres enteras.
  · **EL PANEL PAGÓ: el escéptico tumbó 2 de 6 hallazgos.** Cayeron "el corte por fecha
    de 0259 es un defecto" (es la protección declarada) y "admin_cobranza puede cancelar
    directo por RLS" (aceptado y parqueado con su condición de disparo).
  · **🔻 LOS 5 DE TELENET (C$19.147,81) — DECISIÓN TOMADA, EJECUCIÓN PENDIENTE.**
    Rubén aprobó condonarlos, con este diseño: **que a Telenet le llegue una
    notificación para que EVALÚE caso por caso** si se condona o se conserva. Medido:
    **4 de los 5 tienen un solo contrato** (el cancelado); **MV0167 tiene dos — uno
    SUSPENDIDO**, que es justo la herramienta de "se fue debiendo y le seguimos
    cobrando". Los 5 conservan su estado previo, así que Telenet puede resolverlo
    desde su propia app (revertir + volver a cancelar). **`0258` los había dejado
    afuera A PROPÓSITO** porque el ISP los está usando para cobrar — releer eso antes
    de ejecutar. **Descartada `super_admin_ejecutar_baja_deuda`**: opera por CLIENTE,
    cancelaría contratos vivos y desactivaría al cliente.
  · **QUEDA AFUERA, con su disparador:** los textos de ayuda del dashboard, los
    reportes que suman la deuda cancelada a la cartera y la ruta de "Recuperación" del
    cobrador **siguen siendo ciertos mientras los 5 existan**; se corrigen cuando se
    resuelvan. Y el CI sigue rojo por dos jobs preexistentes.

- **👉 NUEVO (2026-08-26 b) — EL SISTEMA PARA QUE UN CAMBIO NO DEJE
  SUPERFICIES MINTIENDO. Rubén paro el trabajo hasta resolver esto; CERO cambios en la app.**
  **DÓNDE RETOMAR:** hay que **reiniciar la sesión** para que `/pedido` y los hooks
  tomen efecto (antes no existía `.claude/settings.json`, la herramienta no lo lee en
  caliente) · falta decidir si la rama se mergea a `main` · faltan las otras 5 fichas
  de regla · sigue pendiente la decisión sobre el filtro "Cancelado con deuda".
  · **EL DIAGNÓSTICO, con evidencia.** El filtro sigue vivo en
    `clientes_admin_screen.dart:33`. `ARQUITECTURA.md` **sí** se actualizó (R16 quedó
    bien reescrita), pero R16 lista los archivos que **ejecutan** la cancelación y el
    filtro vive en uno que R16 no nombra: leyendo la doc entera y al día no había forma
    de llegar. Los docs indexan por módulo y por tabla; lo que se rompe es una **regla**.
    Y nada verifica que la doc diga la verdad: si envejece no falla nada.
  · **LO QUE SE CONSTRUYÓ (4 commits, sin tocar `lib/`):** `AGENTS.md` → **LA REGLA DE
    ORO** (barrer superficies conectadas · ejecutar completa · las TRES LISTAS · el
    criterio solo SUMA · mockups antes/después) — vivía solo en el bloque de estado de
    esta bitácora, o sea programada para desaparecer. **`tools/regla.py`**: la ficha
    declara a mano ~10 renglones (símbolos + prohibidos) y el script encuentra las
    superficies contra el código de hoy; `--verificar` falla si aparece una que la ficha
    no contempla. **Job de CI** que lo corre. **`.claude/`**: `/pedido`, 6 especialistas
    senior + el escéptico (sin Bash/Edit/Write a propósito) y 3 hooks, el de cierre con
    dientes: niega el cierre si hay código sin `.md`.
  · **LA PRUEBA:** `python tools/regla.py cancelacion` escupe el filtro sin buscarlo, y
    de paso apareció una **cuarta superficie** que nadie había listado
    (`diagnostico_screen.dart`) y un hueco real: **los dos seeds no ejercitan ningún
    contrato cancelado**, o sea que el escenario de prueba no cubre la regla del mes.
  · **`.claude/` estaba GITIGNOREADO** — la config compartida no habría viajado en el
    repo. `.claude/` pasó a `.claude/*` con negaciones para `agents`, `skills` y
    `settings.json`; los worktrees siguen ignorados.
  · **Los hooks se probaron pasandoles el JSON a mano** (5 casos de ruta + 5 del cierre).
    El de `al_editar` quedaba **MUDO** con rutas absolutas: `relpath` tira `ValueError`
    entre `/c/Users` y `C:/Users`. Lo cazó el pipe-test, no la lectura.

- **👉 CHECKPOINT (2026-08-26) — DÓNDE RETOMAR CON CONTEXTO NUEVO.**
  **Todo commiteado y en GitHub.** `main` = `origin/main` = `b234011`. La rama
  `feature/whatsapp-mora-meta` está subida con 4 commits.
  · **PUBLICADO Y ANDANDO:** v0.36.5+265 en las dos empresas (manifiestos, MSIX
    `0.36.5.0`, APK `versionCode 265`, firma `28fe9404…`). Único release en el canal.
  · **EN PRODUCCIÓN:** la migración `0259` está aplicada — cancelar condona la deuda
    y ahora lo enforça el SERVER, así que vale aunque el dispositivo tenga una app
    vieja. Quedan solo los 5 contratos de Telenet preservados a propósito
    (C$19.147,81, los cortados por falta de pago, todos anteriores al 24/08).
  · **🔻 LO QUE ESTÁ A MEDIAS — WhatsApp para Telenet (rama `feature/whatsapp-mora-meta`):**
    - `84456c9` + `d2fd932` + `ad573c7`: **WhatChimp eliminado** del código (edge
      function 416→300 líneas, más el selector y 7 ramas de la UI). Analyze limpio,
      684 tests.
    - `758292a`: **migración `0260` ESCRITA PERO NO APLICADA.** Arregla que el
      mensaje decía el DOBLE que la app (120 de 200 clientes en Telenet), valida
      teléfonos en SQL (hay 1 número de Costa Rica que se entregaría a un
      desconocido), agrega `error_code`/`meta_message_id`, corrige las plantillas
      que Meta rechazaría y separa las horas.
    - **FALTA:** reescribir el modo `lote` de la edge function — hoy manda de a uno
      esperando cada respuesta (200 clientes no entran en los 150 s del techo) y un
      solo error de Meta quema los 200 envíos. Y la observabilidad: nadie se entera
      si el lote falla.
    - **NADA DE ESTO AFECTA A NADIE HOY:** el envío está apagado en los 3 tenants.
    - **Del lado de Telenet:** todo el trámite con Meta (guía completa en
      `Install Steps/WhatsApp-Meta-alta-y-setup.md`, 618 líneas). Con ~64 envíos/día
      entran bajo el techo de 250 de cuenta sin verificar → pueden empezar mientras
      la verificación está en trámite.
  · **⚠️ CÓMO TRABAJAR DE ACÁ EN ADELANTE (feedback de Rubén, 2026-08-26).** Pidió
    parar por desvíos y por entregas incompletas. El caso: al cambiar la regla de
    cancelación no se barrieron las superficies CONECTADAS — el filtro seguía
    ofreciendo "Cancelado con deuda", el chip decía "Sin contrato" a un suspendido, y
    los docs afirmaban lo contrario en SEIS lugares. **Una regla de negocio no vive
    solo en el repo que la ejecuta: vive en los filtros, chips, conteos, exports,
    textos y documentación.** Antes de dar un cambio por hecho: `grep -rn '<tabla>'
    lib/` y revisar cada filtro/chip/conteo/export/doc preguntándose *¿esta pantalla
    sigue diciendo la verdad?*. Y: responder DIRECTO, siempre con **mockups del
    ANTES y el DESPUÉS**, y cuando elige una opción ejecutarla COMPLETA.
  · **PENDIENTES SUELTOS:** los 2 posibles cobros dobles (LC0046 de Mairena, QH0066
    de Telenet con los códigos `00561`/`0561`) · las 10 cuotas de baja sin prorratear
    · el dashboard sin publicar con sus 2 decisiones de producto · el flujo de release
    sigue bumpeando la versión SOLO en las ramas `release/*`, así que `main` va a
    quedar atrás de nuevo en el próximo release.

- **👉 NUEVO (2026-08-25 b, ÚLTIMO) — v0.36.5 PUBLICADA: el chip y los planes.**
  **DÓNDE RETOMAR:** falta avisarle a Telenet lo de suspender vs cancelar · quedan
  3 releases en el canal (la política es dejar solo el vigente) · INV20=1 sin tocar.
  · **QUÉ LLEVA:** el chip **"Sin contrato"** ahora dice el estado real ("1
    suspendido" / "1 cancelado") — mentía en 70 clientes — y los **planes** se
    ordenan por precio dentro del mismo nombre, muestran cuántos contratos usa cada
    uno, y se encuentran tipeando el monto **con o sin** separador de miles.
  · **El reporte "faltan planes" era un falso positivo, pero el problema era real.**
    No faltaba ninguno (sync sin filtro + el diálogo excluye el plan actual = 24 de
    25). Lo que pasaba es que **18 de los 25 planes de Mairena comparten nombre** —7
    se llaman "CATV"— y solo los separa el precio, que era justo lo único que NO se
    podía buscar: tipear `1282` no encontraba "1.282,00 C$" porque el punto parte el
    substring. **Test nuevo** que fija esa regla (5 casos), porque es de las que
    vuelven a romperse en silencio. El arreglo vive en el SELECTOR, no en
    `foldBusqueda`, que la usa media app.
  · **VERIFICADA por contenido:** manifiestos `0.36.5` en las dos empresas · MSIX
    `0.36.5.0` con los package names correctos · APK `versionCode=265` /
    `versionName=0.36.5` · firma `28fe9404…` (la keystore de release, no debug).
    Tests **648 en la rama de release, 684 en main**, cero fallas.
  · **El build falló la primera vez y lo diagnostiqué mal la vez anterior.**
    `fatal: unable to write new index file` al restaurar el branding entre un tenant
    y el otro. NO es disco (184 GB libres) ni Gradle: **`C:/sc-release` está fuera de
    OneDrive pero es un WORKTREE**, así que su `.git` apunta adentro y OneDrive le
    bloquea el índice. Ya había pasado en v0.36.3. Salida: `git checkout --
    pubspec.yaml`, borrar los artefactos parciales y relanzar (el script es
    idempotente). **Arreglo de fondo: que `C:/sc-release` sea un CLON, no un
    worktree.** Anotado en memoria.

- **👉 NUEVO (2026-08-25, ÚLTIMO) — LA REGLA DE CANCELACIÓN AHORA VIVE EN EL SERVER.**
  **DÓNDE RETOMAR:** falta que Rubén AVISE a Telenet · falta que reinicien la PC de
  Mairena · el chip nuevo y el fix de "Usuarios" están en `main` sin publicar.
  · **EL DESCUBRIMIENTO:** el dueño reportó que el filtro "Cancelado con deuda" seguía
    mostrando gente. **El filtro no mentía: la data estaba sucia.** La regla del
    2026-08-24 vivía **solo en el Dart**, y al APROBAR una solicitud el trabajo lo
    ejecuta **el device de quien aprueba**. En Mairena ese equipo corre **0.36.2**
    (con la app abierta desde el día anterior, así que `app_dispositivos.visto_en`
    ni siquiera lo delataba) → **44 contratos cancelados con C$102.834,54 de deuda
    viva**, y creciendo: de 37 a 44 en las horas que duró el análisis.
    **Corrección a mi primer diagnóstico:** dije "la regla nueva no corrió ni una
    vez". Falso — **corre bien en Telenet**, cuyos admins están en 0.36.4. La firma
    está en el `op_log`: Mairena escribe una fila `monto 1.282 → 41,35` con motivo
    *"Prorrateo por cancelación"* (el código viejo prorratea el mes en curso);
    Telenet no la tiene.
  · **0259 APLICADA Y VERIFICADA.** Gate + función de condonación + trigger en
    `contratos` + trigger en `pagos` (para la plata que aterriza DESPUÉS de la baja)
    + backfill. Resultado medido: **49 → 5 contratos** con deuda (los 5 de Telenet,
    que **el corte por fecha** protege — NO el flag), **C$121.982,35 → C$19.147,81**,
    y **la plata intacta**: 31.397 pagos y 31.397 recibos vivos, C$28.067.532,66,
    idénticos antes y después. Rastro: 146 filas de `op_log` + 44 de `data_ops_log`.
  · **TRES ramas, no dos.** La del medio es la que faltaba y la tenían mal los 3
    diseños: una cuota cuyo único pago está **en cuarentena** NO se toca. Anularla
    mata un cobro real en cascada; condonarla la deja en una **trampa permanente**
    (al aprobar la cuarentena, el guard de sobrepago la devuelve una y otra vez).
  · **Por qué se reescribe `monto` y no se inserta un descuento:** `_previasValidadas`
    aborta el revert si cambia `cargos_neto`, así que un descuento inyectado por el
    server dejaría **toda baja sin vuelta atrás**, incluidas las de los builds viejos.
    `monto` es el único campo que ni `cuotas_forzar_derivados` ni la guarda del
    revert miran.
  · **La revisión adversarial pagó: entraron 6 parches.** Los dos serios:
    **(A)** la decisión de anular se tomaba con un `EXISTS` calculado **abajo del
    LockRows** (verificado con EXPLAIN contra la base viva) → un cobro concurrente
    podía caer en la rama de anular y la cascada le mataba el pago **y** el recibo;
    el `NOT EXISTS` pasó a ir DENTRO del UPDATE.
    **(B)** el gate usaba `setting_bool`, que hace `(valor)::boolean` y **revienta
    con 22P02** si el valor quedó JSON-quoteado — **ya hay 2 filas así en producción**.
    Como el gate corre en el camino de TODO cobro y 22P02 es no-retryable, un valor
    mal escrito habría **volteado cada cobro del tenant**. Ahora lee tolerante.
  · **DECISIÓN DE RUBÉN: encendida en las DOS empresas**, contra la recomendación de
    apagarla en Telenet. Lo que protege sus 5 deudas viejas es el corte por fecha (el
    más nuevo queda 12 días antes), no el flag. **De acá en adelante Telenet tiene que
    usar SUSPENDER para "se fue debiendo" — hay que avisarles.**
  · **También salió:** el chip **"Sin contrato"** mentía en **70 clientes** que sí
    tienen contrato (30 suspendidos + 40 con solo cancelados) y chocaba con el filtro
    homónimo, que exige CERO contratos (94 contra 24). Arreglado el CHIP, no el
    predicado — así los dos convergen sin solaparse con las categorías que ya existen.
  · **Planes "que no aparecen" (reporte del ISP): NO falta ninguno.** Sync sin filtro
    + el diálogo excluye el plan actual = 24 de 25. El problema real es que **18 de
    los 25 planes de Mairena comparten nombre** (7 se llaman "CATV", 5 "COMBO
    INTERNET+CATV 20MB"), el orden dentro del mismo nombre es azaroso, y buscar
    `1282` no encuentra `1.282,00` (la búsqueda no ignora el separador). Telenet no
    tiene nombres repetidos. **Pendiente de aprobar el fix.**
  · **INV20=1 NO es de esta migración** (verificado: 0 filas suyas para ese cliente;
    el único divergente no fue tocado). Es residuo de un cancelar+recrear de la app.

- **👉 NUEVO (2026-08-24 e, ÚLTIMO) — LOS NÚMEROS DEL RESUMEN CUADRAN · v0.36.4 PUBLICADA.**
  **DÓNDE RETOMAR:** falta que Rubén actualice y confirme en pantalla · queda sin
  decidir si se borra el release v0.36.3 · sigue pendiente el dashboard.
  · **EL FIX, y era de tres palabras:** la columna "Usuarios" hacía
    `COUNT(DISTINCT cliente_id)` — contaba PERSONAS mientras la de al lado contaba
    CUOTAS. Una persona con dos servicios (CATV + COMBO) genera dos cuotas, así que
    las dos columnas **no podían cerrar nunca**. Pasa a
    **`COUNT(DISTINCT COALESCE(contrato_id, id))`** en las **6** ocurrencias: las 3
    de "Cobros del mes" y las 3 de "Mora del ciclo", que tienen que usar el mismo
    criterio o muestran universos distintos. Medido contra producción, el ciclo en
    curso da **1:1 en las tres filas de las dos empresas** (Mairena 4.429 = 4.429,
    Telenet **971 = 971** — el número exacto de la captura del dueño).
  · **El `COALESCE` NO es adorno, y tapó un bug latente:** un **cargo manual** es una
    cuota con `contrato_id` NULL y `COUNT(DISTINCT)` ignora los NULL → sin él, cada
    cargo sumaría en "Cuotas" pero no en "Usuarios" y el descuadre volvía por otra
    puerta. Estaba invisible porque **los dos ISPs tienen CERO cargos manuales**; el
    Test Tenant tiene uno y con el COALESCE sus 8 ciclos cuadran, contra 7 sin él.
    (Mismo patrón que las reglas 1c y 1d del AGENTS: el caso normal esconde el bug.)
  · **Lo que NO cuadra y está BIEN:** 5 de 26 ciclos difieren porque un contrato tuvo
    **dos vencimientos en la misma ventana 15→14** (el 14/6/2026 cayó domingo y
    `calcular_fecha_pago` corrió el vencimiento al lunes 15) — son dos cobros reales.
  · **RUBÉN TENÍA RAZÓN en el fondo:** los 5 clientes que descuadraban el ciclo en
    curso NO tienen dos servicios de verdad. Los 5 son **un contrato cancelado + uno
    activo = un cambio de plan hecho como cancelar+recrear**: CF0190, CNC011, PI0059,
    R20072 (Mairena) y AS0026 (Telenet). Y **las 5 cuotas de cierre están PAGADAS**
    (C$2.572,32 cobrados) → no hay deuda colgando. Por eso el conteo las cuenta como
    servicios en vez de esconderlas: **esconderlas borraría C$2.572,32 de cobros
    reales** del Resumen. El origen lo corta el permiso que va en el mismo release.
  · **v0.36.4+264 PUBLICADA Y VERIFICADA** (canal `sitecsa-updates`, 8 assets).
    Verificado por CONTENIDO, no por timestamp: manifiestos `0.36.4` en los dos
    tenants · MSIX `Version=0.36.4.0` con los package names correctos · APK
    `versionCode=264` / `versionName=0.36.4` · firma **`28fe9404…`** (la keystore de
    release de siempre, no debug). Tests **643 en la rama de release, 679 en main**.
  · **Se cerró una MINA en `main`:** su `pubspec` decía `0.34.2+256` mientras la calle
    corría `0.36.3+263`, porque los bumps se venían commiteando SOLO en las ramas
    `release/*`, que nunca se mergean de vuelta. Publicar desde main habría
    **CONGELADO el canal** de los 11 equipos productivos (`_isNewer` compara
    major.minor.patch con `>` estricto → las apps creerían estar al día para
    siempre). Corregido con una línea (`dd3502b`). **NO se mergea `release/*` a
    main**: borraría el dashboard en curso.
  · **PENDIENTE que encontró la auditoría:** el strip del dashboard de v0.36.2
    revirtió `dashboard_providers.dart` por debajo del merge-base y **borró el fix
    multi-tenant del "Top cobradores"** — hoy ese ranking no filtra por empresa en lo
    publicado. Solo muerde en el equipo del super_admin (el único que sincroniza más
    de un tenant). Son 4 líneas, verificadas, sin aplicar.

- **👉 NUEVO (2026-08-24 d, ÚLTIMO) — "usuarios ≠ cuotas": la causa era un PERMISO, y los
  pagos retroactivos NO son doble cobro.**
  **DÓNDE RETOMAR:** falta build para que salga el permiso · quedan 2 casos puntuales de
  posible doble cobro (abajo) · quedan sin hacer las otras dos patas del fix de fondo.
  · **LA RESPUESTA A "que los números concuerden": YA CONCUERDAN.** Octubre cierra **1:1
    exacto** en las dos empresas (Mairena 4.424 = 4.424, Telenet 963 = 963). El desfase de
    septiembre es facturación LEGÍTIMA: la cuota de cierre del plan viejo, prorrateada a los
    días servidos, al centavo. Borrarla sería sub-facturar.
  · **LA CAUSA RAÍZ, y es de una línea (`9a9c8b3`):** `admin_usuarios` veía "Solicitar
    cancelación" pero **NO "Cambiar plan"**, así que para un cambio de servicio su única
    salida era cancelar+crear — y eso parte al cliente en dos contratos con dos cuotas.
    Medido: ese rol metió **61 cancelaciones y 207 contratos nuevos, y CERO cambios de
    plan**. Es el MISMO bug que el comentario del provider ya describía para
    `admin_cobranza`: se arregló para ese rol y quedó abierto para el que hace ~90% de la
    gestión. **Sin migración**: el rol PIDE el cambio y el server ya lo acepta.
    **Test nuevo que fija la REGLA DE PRODUCTO**, no la implementación: *todo rol que pueda
    pedir una cancelación tiene que poder pedir un cambio de plan*. Recorre los 7 roles.
  · **LO QUE FALTA del fix de fondo** (decisión: por ahora solo el permiso): una acción
    **"Corregir el plan desde el inicio"** que re-valúe TODAS las cuotas vivas —hoy
    `cambiarPlan` solo toca las futuras, y el motivo más frecuente es "se cargó mal desde el
    día uno", por eso hasta quien SÍ ve el botón sigue cancelando (Telenet canceló+recreó 4
    contratos el 24/08)— y el **permiso de cambio de fecha de pago**, que no tiene ninguno de
    los 12 usuarios de los dos tenants (3 de los 4 casos también cambiaron el día).
  · **🔻 EL HILO DE LOS PAGOS RETROACTIVOS — CERRADO, Y MI ALARMA ERA EXAGERADA.** Un lente
    lo reportó como *"plata que puede no haber entrado nunca a caja"* (C$160.985) y yo lo
    repetí acotado a C$74.946. **Las dos cifras eran falsas alarmas.** Lo que hay:
    223 pagos en cuotas superpuestas, **134 cargados +30 días después** de su fecha (hasta
    204 días), pero **103 de esos 134 se concentran en 10 días de carga** → es carga en lote
    de historia, consistente con la migración desde Excel. Y el discriminante decisivo: de
    **121 pares (cliente, mes) con dos cuotas, 119 tienen montos distintos y 108 planes
    distintos** → son **dos servicios reales** (CATV + COMBO), no duplicados. Los 223 pagos
    tienen recibo vivo, 0 sin respaldo.
    **Solo 2 pares quedan en duda** (mismo plan, mismo monto): **LC0046** de Mairena (dos
    COMBO, enero, los dos pagados C$1.282 → probable doble cobro) y **QH0066** de Telenet
    (contratos `00561` y `0561` — los que difieren solo por ceros a la izquierda; uno pagado
    y el otro se le está volviendo a cobrar). Esos dos sí conviene consultarlos.
  · **Tests 679/0.** El pico de julio del Resumen (145 de más) **no es un problema**: el 14
    de junio cayó domingo, `calcular_fecha_pago` corrió el vencimiento al lunes 15 y entró en
    la ventana junto al de julio. Es calendario. **Vuelve a pasar en abril y diciembre 2027.**

- **(2026-08-24 c) — CANCELAR UN CONTRATO YA NO DEJA DEUDA · PUBLICADO
  EN v0.36.3.**
  **DÓNDE RETOMAR:** testing manual de Rubén sobre **v0.36.3** (build **263**) · decidir si a
  los **5 morosos** que quedaron afuera se les hace algo · el dashboard sigue sin liberar.
  · **PUBLICADO:** canal con SOLO `v0.36.3` (v0.36.2 borrado, release y tag). Tag de código
    `v0.36.3` = `5825e77` (rama `release/v0.36.3`, cherry-pick de los 2 commits de código
    sobre `v0.36.2`). **Diff contra v0.36.2: exactamente 4 archivos, ninguno de dashboard.**
    Verificado antes de publicar: firma `28fe9404…` en las dos empresas · build 263 > 262 ·
    versión 0.36.3 **adentro** del APK y del MSIX de AMBAS · branding correcto (Telecable
    Mairena S.A. / Telenet) · los dos manifiestos sirviendo 0.36.3 desde `/latest/`.
    Suite de la rama: **629/0**.
  · **GOTCHA DEL BUILD (anotar):** el script falló con `exit 128` en
    `git checkout (restaurar branding telenet)` — el ÚLTIMO paso, después de generar los
    binarios. Es un **lock transitorio** (Gradle soltando archivos); correr el mismo checkout
    a mano da exit 0 y el árbol queda limpio. **Los artefactos ya estaban bien**: se
    verificaron los 4 antes de publicar. Si vuelve a pasar, no rebuildear: verificar y seguir.
  · **EL REPORTE:** un contrato CANCELADO seguía apareciendo con deuda. Era el diseño viejo
    —cancelar dejaba cobrable lo cumplido y prorrateaba el mes en curso—, o sea que hacía
    casi lo mismo que suspender. **Regla nueva del dueño:** cancelar condona todo; suspender
    conserva la deuda y es reversible. Ahora los dos botones significan cosas distintas.
  · **LA MEDICIÓN QUE DEFINIÓ EL ALCANCE:** 51 contratos cancelados arrastraban
    **C$120.234,28**, y el **79% era ATRASO** (meses viejos), no el mes de la baja. Al
    clasificar por motivo apareció el matiz: **36 de los 51 siguen siendo clientes** con
    otro contrato activo (recontrataron, migraron, o el contrato estaba mal cargado) — su
    deuda es residuo administrativo. Pero **5 se cortaron por falta de pago**, ninguno
    recontrató, y el ISP había escrito a mano *"quedó pendiente con mes junio"*: están
    usando el sistema para seguir esa deuda. **Se limpiaron 46 (C$101.086,47) y esos 5
    quedaron intactos** (C$19.147,81), por decisión explícita.
  · **LA REGLA INVIOLABLE QUE CONDICIONÓ EL DISEÑO:** anular una cuota con plata dispara
    `cuotas_anular_pagos_asociados_trg`, que anula EN CASCADA sus pagos y sus recibos —
    borraría plata cobrada y un comprobante que el cliente tiene. Por eso: sin pago → anular;
    **con pago → `monto = monto_pagado` + `cargos_neto = 0` + `'pagada'`** (saldo 0 sin tocar
    la plata). Verificado tras aplicar: **0 pagos y 0 recibos anulados**.
  · **Textos:** el diálogo prometía *"la deuda real queda COBRABLE"* y ahora avisa que se
    condona todo, con una línea en rojo: *"¿El cliente se va debiendo y le vas a seguir
    cobrando? Entonces usá SUSPENDER"*. La tarjeta decía *"Deuda al cancelar (cobrable)"* —
    mandaba a buscar una deuda inexistente— y pasa a *"Deuda condonada"*.
  · **Un test viejo se cayó, y estuvo bien:** afirmaba que cancelar un suspendido no tocaba
    las cuotas. Se **reescribió** en vez de borrarlo, porque protegía algo real (re-prorratear
    le SUBÍA el monto al cliente): la garantía sigue fijada con un `lessThanOrEqualTo`.
  · **Tests 664+, invariantes 31 filas con el baseline de siempre** (INV11=3, INV19=7).
  · **AGENTS: invariante 6b** con la regla y la prohibición de anular cuotas con pago.

- **(2026-08-24 b) — DASHBOARD: tarjeta "Recaudo y mora" (formato de la
  referencia del dueño), en prueba local sobre el Test Tenant.**
  **DÓNDE RETOMAR:** Rubén la está probando con el MSIX local (identidad genérica
  `com.sitecsa.crm`, NO pisa la app de Mairena instalada; canal de release intacto). Tras su
  OK quedan las DOS DECISIONES que las líneas punteadas esperan: ¿quién configura la **meta
  de recaudo** (hoy 100% de lo facturado) y el **límite de mora** (hoy 10%, supuesto del
  mockup)? Constantes `kMetaRecaudoPct`/`kLimiteMoraPct` en `recaudo_mora_card.dart`,
  marcadas PROVISORIAS.
  · **Qué es** (`c7d2613`): la tarjeta calca las capturas que trajo el dueño — 4 líneas
    (recaudado real/meta, mora real/límite), vistas **Mensual/Acumulado**, 4 KPIs, tabla de
    indicadores con % del total, 6 ciclos navegables — pero con la SEMÁNTICA CORREGIDA que
    se validó contra producción: `facturado = recaudado + por recaudar + mora` por ciclo,
    con "por recaudar" = saldo aún en plazo o gracia y "mora" = saldo que cruzó la gracia
    (disjuntos; la tabla suma 100% sin plata doble). En Acumulado la mora de cada ciclo es
    la viva HOY de las cuotas de ESE ciclo — acumular no duplica. La trampa que se evitó:
    en la referencia, con nuestra fila "Pendientes" el 100% habría sumado 33,9% de más
    (medido en Mairena).
  · `serieRecaudoMora` en `dashboard_query.dart` (clave de ciclo calcada de `periodoDe`,
    período 15→14). `admin_cobranza` no monta la tarjeta (es 100% montos). El gráfico marca
    el primer ciclo cuya mora rebasa el límite.
  · **Tests: 660/0** (los 5 nuevos: identidad por ciclo y acumulada, mapeo de períodos,
    relleno de huecos, y el cross-check con `resumenCobros` — dos tarjetas del mismo
    dashboard no pueden dar números distintos del mismo ciclo).
  · **Data simulada: NO hizo falta sembrar** — el Test Tenant ya tiene el escenario de
    `supabase/escenarios/dashboard_seed.sql` (14 clientes TT-*, 132 cuotas feb–nov 2026).
    NO se re-corrió el seed: su DELETE arrasa el tenant y se llevaría el caso de cuarentena.
  · El dashboard SIGUE sin liberar: esto vive en `main` y sale cuando el dueño diga.

- **(2026-08-24 a) — v0.36.2 EN LA CALLE + la doble facturación cerrada.**
  **DÓNDE RETOMAR:** testing manual tuyo sobre v0.36.2 · el dashboard sigue en desarrollo y
  sale cuando vos digas (bump ≥0.37.0) · el resto del bloque B del plan de consistencia.
  · **PUBLICADO:** canal `sitecsa-updates` con SOLO `v0.36.2` (v0.36.1 borrado, release y
    tag). Tag de código `v0.36.2` = `74559c9` (rama `release/v0.36.2` en `C:\sc-release`).
    **Build esperado en login/sidebar/perfil: `0.36.2`** (build 262).
  · **QUÉ LLEVA** (8 archivos, sin dashboard — el diff contra v0.36.1 se verificó):
    **B1**, el único que le cambia el día a día al cobrador: el rastro del cobro rechazado
    se guarda ANTES de que la cola se destruya. Es el que protege el caso Derling. Más el
    conteo del historial de Operaciones, el antes→después de los cambios de plata, y los
    textos del panel.
  · **VERIFICADO ANTES DE PUBLICAR** (la lista que conviene repetir siempre): firma Android
    `28fe9404…` idéntica en las dos empresas (si no coincide, Android rechaza la
    actualización) · build **262** > 261 · versión **0.36.2 adentro** del APK **y del
    MSIX**, en las DOS empresas — incluida Telenet, que es la segunda del loop y donde
    pegaría el bug que el guard nuevo previene · manifiestos apuntando al instalador
    correcto · el `version-mairena.json` servido desde `/releases/latest/` ya devuelve
    `0.36.2` · suite de la rama **624/0**.
  · **DEUDA FANTASMA CERRADA:** 11 cuotas por C$10.257 anuladas (`577cb27`) + `0257`
    repuso `cancelado_en` en 36 contratos desde el `op_log`. INV25 volvió a 0.
  · **NO TOCAR:** `pubspec` de main sigue en `0.34.2+256` A PROPÓSITO (el bump va en la
    rama de release). Y OJO: OneDrive bloquea la escritura de refs — no se puede crear un
    tag local en esa carpeta; el tag se empuja directo con
    `git push origin <sha>:refs/tags/vX.Y.Z`.

- **(2026-08-23) — RED DE CONSISTENCIA: 31 invariantes, y las 4
  operaciones de dinero que pasaban sin dejar rastro ya no pasan.** Migraciones
  `0248`-`0254`, TODAS aplicadas y verificadas contra `vxxz` (producción).
  **DÓNDE RETOMAR:** nada de esto necesita build para funcionar — el registro y los
  guards son server-side y ya están vivos. Lo que SÍ espera build es el bloque B del
  plan (`docs/PLAN-CONSISTENCIA-2026-08-23.md`), empezando por **B1: el rastro del
  rechazo se guarda sin esperar confirmación y justo después se destruye la evidencia**
  (`transaction.complete()`); si el teléfono muere en ese instante queda el recibo en
  papel y cero rastro.
  · **HALLAZGO DE ARRANQUE: el backlog del 08-08 estaba 8/8 CERRADO.** Se fue aplicando
    sin tacharse y mintió dos semanas. Incluso la que yo iba a proponer como estrella —el
    rechazo mudo— **ya estaba y ya se pagó sola**: al volverse ruidosa destapó el colchón
    de indefinidos que se rechazaba en silencio desde el día uno (→ 0241). Se tachó con
    la evidencia de cada cierre. **Lección de proceso: el backlog se tacha en el mismo
    commit que lo cierra.**
  · **Y una CORRECCIÓN de lectura, no de número:** el bullet de "clientes sin salida por
    condonación" (40 / C$108.512) estaba bien contado y mal leído — **28 de esos 40
    (C$89.153, el 82,9%) están SUSPENDIDOS, o sea mora normal y COBRABLE**. La propuesta
    que salía de ahí habría condonado C$89.000 cobrables. La población real son 11
    clientes por C$18.429, y la salida ya existe desde 0244/0245.
  · **31 INVARIANTES (`90e882f` + `0248`).** 11 nuevos, los 11 arrancando en CERO. El que
    más importa vigila **no cobrar salteándose la cuota más vieja** (#11 de AGENTS), el
    único invariante del negocio que no tenía NINGUNA red — por decisión de producto no
    hay trigger server y el guard del teléfono es ciego al multi-device offline. `0248`
    los porta a la RPC del panel (decía 20, el archivo 31 — divergir es justo lo que 0220
    vino a cerrar), pasa el orden a NUMÉRICO (antes: INV1, INV10, INV11… INV2) y hace que
    el cartel verde derive el conteo del resultado: el número fue 17, 20 y 31, y el texto
    quedaba viejo cada vez. Las 11 entradas humanizadas van en `kInvInfo`.
  · **BARRIDO DE ATRIBUCIÓN (`0249`-`0251`, `0254`).** (1) 14 duplicados auto-anulados sin
    historial, repuestos con el `pago_original` que el borrador perdía — sin él la fila
    dice "se anuló un duplicado" sin decir duplicado DE QUÉ. (2) Las **5 RPC del panel del
    Dev** no escribían nada: ahora sí, y las 3 de `cobradores` **se ven solas, sin build**;
    de paso queda registrada la pérdida silenciosa de `prefijo_recibo` al degradar un rol.
    (3) El **corrector de invariantes NO CONVERGÍA** — reproducido en vivo: "corrige" 2
    filas, no cambian, y la pasada siguiente vuelve a "corregirlas". No escribía plata
    fantasma (el trigger BEFORE la atajaba), pero sumarle el registro nuevo habría
    estampado filas de corrección con antes = después en el historial de esas cuotas en
    cada apretón. (4) **Dar de baja un contrato ahora exige quién y por qué.**
  · **LA LECCIÓN QUE MÁS SE VA A REUSAR (AGENTS #13/13b/13c):** el plan pedía un `CHECK
    NOT VALID` para (4). Al medirlo, habría dejado **93 clientes imposibles de reasignar**
    — un CHECK evalúa el ESTADO, no la TRANSICIÓN, y `NOT VALID` solo salta el escaneo
    inicial. Va como trigger de transición, con la rama del **UPSERT** (PowerSync sube los
    `put` con upsert y el BEFORE INSERT corre ANTES del conflicto: `TG_OP` dice `'INSERT'`
    aunque la fila exista).
  · **ADEMÁS:** `0252` historial de avisos de sync + motivo al descartar (declarar perdido
    un cobro real ahora deja constancia); `0253` índice único parcial que impide el mismo
    aviso N veces sin bloquear la reincidencia legítima.
  · **PENDIENTE ANOTADO:** el worktree `.claude/worktrees/app-status-check-850cf6` está
    PODRIDO (v0.28.0, migración 0203, dos meses atrás). Tres de las cuatro lentes del
    análisis lo leyeron y "probaron" bugs que en producción ya no existen, con evidencia
    que parecía real. **Borrarlo** (`git worktree remove ... --force`) antes de la próxima
    sesión de análisis.
  · **AUDIT FASE 4 DE LA PROPIA TANDA (`0255` + `f4a5cc8`).** 7 lentes + refutación
    adversarial de cada hallazgo (17 agentes). **Veredicto: ningún invariante calculaba
    plata mal** — lo que fallaba era el SISTEMA DE MEDICIÓN. En un panel que es el cierre
    no-negociable de todo fix de plata, un cero falso vale igual que un bug. Cuatro
    chequeos corregidos, y los tres primeros arrancan y terminan en cero (arreglan
    latentes, no cambian el presente):
    **INV3** adopta el canon del trigger `cuotas_forzar_derivados`, que es la autoridad —
    su banda propia de ±0.01 marcaba como violación un estado que el propio server
    produce, y el corrector no podía apagarla porque el trigger revertía su UPDATE.
    **INV28** compara contra la caja de la EMPRESA y no la del usuario: devolver es acción
    de oficina, y el predicado pedía caja de calle (2 de las 10 disposiciones reales
    habrían marcado rojo, una de C$30.516, sin forma de bajar la bandera).
    **INV29** pierde `recibo_id`, una condición que NINGÚN camino del sistema puede
    satisfacer — la primera devolución real dejaba rojo permanente con un texto que
    mandaba a completar un campo inexistente.
    **Y el corrector** suma un filtro `despues IS DISTINCT FROM antes`: `RETURNING` trae
    el valor POST-trigger, así que si el trigger revertía, la fila contaba como corregida
    sin cambiar y estampaba `op_log` con antes = después.
  · **🔻 INV25 = 6 — LO ÚNICO CON VÍCTIMAS, Y ESPERA TU DECISIÓN.** El comentario de INV25
    juraba ser copia exacta del trigger 0234 y no lo era: el trigger hace COALESCE de la
    fecha de baja a hoy-Nicaragua, el chequeo no. **Justo ahí vivía la deuda fantasma.**
    37 contratos cancelados SIN fecha quedaban fuera del chequeo, y con ellos **6 cuotas
    por C$6.154,00** en 3 contratos de Telecable Mairena (R10072, IV0161, SE0092) con
    ventana de servicio que arranca en **sep/oct 2026** sobre contratos YA CANCELADOS —
    servicio que no se va a prestar, hoy listado como cobrable. El panel decía "0
    violaciones"; ahora dice 6. **La data NO se tocó**: anular cuotas es operación de
    dinero. Se cierra desde Operaciones → estado de cuota (preview + motivo + respaldo).
    Hasta entonces el baseline suma INV25 = 6, marcado como PENDIENTE, no como aceptado.
  · **Y un dato que no era código:** las dos funciones de `sync_rechazos` filtraban la
    identidad del super_admin al ISP — sus `LEFT JOIN` a `cobradores` no tienen condición
    de tenant y son `SECURITY DEFINER`, así que resolvían contra la fila del dueño del
    SaaS. Enmascarado del lado de la LECTURA (tocar el write reescribiría historia).
  · **Invariantes tras cada migración: 31 filas · baseline INV11=3, INV19=7 · INV25=6
    pendiente. RPC y archivo canónico dan IDÉNTICO en los 4 tenants.**
  · **✅ B1 CERRADO (`a9b26fe`) — el rastro del cobro rechazado ya no corre una carrera
    contra el borrado.** Cuando el server rechaza un write, el connector disparaba el
    aviso local con `unawaited` y seguía; poco después corre `transaction.complete()`,
    que **borra las ops de la cola para siempre** (verificado en `powersync_core` 1.8.0).
    Si la app moría en esa ventana quedaba el recibo en papel y CERO rastro — y el
    `opData` de esa op es el ÚNICO registro del contenido con el que se reconstruye el
    cobro a mano. Eran **tres** los call sites, no dos (el plan se comía el `delete`).
    Ahora `_registrarRechazo` devuelve el Future del rastro LOCAL, `uploadData` los junta
    y los vacía **una vez** antes de `complete()`, con timeout de 5 s — no un `await` por
    rechazo: adentro del loop, un cambio de policy que rechace cientos de ops retendría
    el batch entero. Va solo ahí y **no en un `finally`**: si el loop sale por excepción,
    `complete()` no corre, las ops siguen en la cola y no hay evidencia que perder.
    **Test nuevo** que fija la garantía de la que depende todo: esperar esos Future deja
    los avisos EN DISCO (se leen de prefs, no de memoria) con su `data` completa.
  · **✅ DEUDA FANTASMA CERRADA (`577cb27`) — 11 cuotas, C$10.257, anuladas.** Con
    `super_admin_cuota_estado_impl` (preview + motivo + respaldo + triple registro), una
    por una, con un guard que abortaba todo si el conteo no daba 11. Verificado: 11 cuotas,
    C$10.257,00, 11 operaciones registradas, 11 respaldos, 11 filas de historial. **Es
    reversible** ("revivir" desde la misma pantalla). Y **`0257` repuso `cancelado_en` en
    36 contratos** desde la fecha real del `op_log` — sin inventar nada; el único sin
    rastro (1 de 37) se queda con NULL honesto, y `cancelado_por`/`motivo` NO se rellenan
    porque una atribución falsa es peor que el vacío. **INV25 volvió a 0**; el baseline
    queda en INV11=3 e INV19=7, los dos de siempre.
  · **🔻 EL DETALLE — el número cambió, y lo empeoró.** Al mirar caso por
    caso apareció el porqué: esos contratos se terminaron con el estado viejo
    **`'completado'`** (que después se eliminó como alias de `'cancelado'`), por un camino
    que NO escribía la atribución; una migración posterior los mapeó a `'cancelado'` sin
    reponer la fecha. **El `op_log` SÍ tiene la fecha real** (36 de 37). Con las fechas
    verdaderas no son 6 cuotas / C$6.154 sino **11 cuotas / C$10.257**, en **5 clientes de
    DOS empresas** (Mairena 8 / C$7.949 · Telenet 3 / C$2.308) — mi INV25 usa "hoy" como
    respaldo y por eso contaba de menos.
    **Lo decisivo: los 5 recontrataron y se les cobra el mismo mes DOS VECES.** Tomasa
    Ríos (IV0161) debería deber C$513/mes por su contrato nuevo y se le piden **C$1.795**,
    porque el contrato terminado sigue facturando C$1.282. Si el cobrador va y ella paga,
    esa plata entra a una cuota que no correspondía. Ojo SP0024: tiene **dos** contratos
    viejos (00255 y 0523, los que difieren solo por ceros a la izquierda).
    **Espera decisión de Rubén** (toca plata). Salida: anular las 11 desde Operaciones →
    estado de cuota (preview + motivo + respaldo). Complemento recomendable: **backfillear
    `cancelado_en` desde `op_log`** — no inventa nada, reconstruye un timestamp del
    historial registrado, y deja de depender del respaldo "hoy".
  · **Nota de método:** `flutter test` **se cuelga** en la carpeta de OneDrive (se clava en
    el primer archivo, `dart` al 0% de CPU). La misma suite corre en **1:13** desde un
    worktree en `C:\sc-release`. **647 pasando · 4 salteados · 0 fallas.**

- **(2026-08-22) — AUDIT INTEGRAL (47 hallazgos) + paquetes A y B
  aplicados: el prorrateo ya no puede subirle la deuda a quien se da de baja.**
  **DÓNDE RETOMAR:** **v0.36.1 publicada** con el fix crítico (ver abajo) → el riesgo del
  prorrateo está cerrado en cuanto los equipos actualicen. Sigue: paquete C (6 casos con
  víctima contada) y paquete D (la columna `precio_base`, el fix de fondo, que además
  cierra el lado de sub-cobro).
  · **EL AUDIT** (`docs/AUDIT-INTEGRAL-2026-08-22.md`, 7 lentes + refutación de los 12 más
    severos): **1 CRÍTICA · 4 ALTA · 18 MEDIA · 24 BAJA**. Los dos veredictos que importan:
    **la plata CIERRA al centavo** (18/20 invariantes en cero, los 2 restantes son los ya
    declarados; 57.003 cuotas sin un derivado desalineado; la deuda del tenant cierra por
    tres cortes; las 6 fórmulas de saldo dan idéntico) y **el ciclo offline es PRECISO**
    (41 triggers comparados con su espejo Dart, los 4 escenarios de conflicto cubiertos,
    0 pagos vivos sobre cuota anulada en 879 anulaciones).
  · **PAQUETE A (código, commit 07ef412).** (1) El **clamp del prorrateo**: al suspender/
    cancelar se prorrateaba con el precio LIVE del plan contra una cuota que es SNAPSHOT
    de su momento, y solo se clampeaba por abajo → **darse de baja podía salir más caro
    que el mes entero** (SE0338: C$513 → C$1.075 por 26 días; ya consumado en SE0294 el
    11/08: 479,90 → 496,45; 16 cuotas vivas expuestas). Ahora se acota por arriba al monto
    de la cuota **en los tres puntos, incluido el preview** — sin ese tercero el diálogo
    mostraba un número y la app escribía otro. 4 tests nuevos fijan la REGLA.
    (2) **reactivarContrato** revivía filtrando por el string `'Suspensión temporal'`, pero
    por suspensión se anula con TRES motivos (app, trigger 0234, backfill 0234): las otras
    dos quedaban anuladas para siempre (el unique contrato+periodo impide regenerarlas).
    Hoy hay 3 cuotas por C$2.748 así. Se filtran los 3; los de cancelación quedan fuera.
    Suite: **647/647**. **Publicado en v0.36.1** (`release/v0.36.1` = tag `v0.36.0` +
    cherry-pick del fix: el diff contra el release anterior son exactamente 2 archivos,
    `contratos_repo.dart` y `prorrateo_test.dart` — el dashboard sigue afuera y byte-idéntico
    a v0.35.2). Suite de la rama: 616/616 (612 + los 4 tests nuevos).
  · **PAQUETE B (docs, commit 396c363).** La guía de Troubleshooting SQL estaba 15% ciega:
    le faltaban 13 triggers, entre ellos el que **anula cuotas en masa** al cambiar el
    estado de un contrato (0234) — quien la seguía borraba deuda sin enterarse. Además el
    control post-fix decía "INV1-INV17 en 0" cuando el script emite **20**, y los 3 que
    quedaban fuera incluían INV19 (7 vivas). Se agregó la **línea base** (INV11=3, INV19=7
    aceptados: la regla es "tu fix no puede AUMENTAR ningún contador") y la query para
    regenerar la tabla de triggers (42 hoy). ARQUITECTURA §3.5: la "regla de oro" definía
    el total de contrato fijo como `precio × meses`, contradiciendo al invariante #5 y a su
    propia R22 — corregido a `Σ cuotas vivas` con el porqué.
  · **LO QUE QUEDA:** paquete C (estados de cuenta de Telenet con deuda ya perdonada · el
    mes del recibo se re-etiqueta al cambiar la fecha de pago, 27 recibos entregados · el
    período de servicio que se muestra al cobrar, 165 cuotas · el cierre de caja sin filtro
    de empresa · el aviso de rechazo sin `await`) y paquete D (`cuotas.precio_base`, que
    cierra también el lado de **sub**-cobro).

- **👉 NUEVO (2026-08-21 tarde, ÚLTIMO) — CUADERNO DE TELENET ejecutado (la parte probada)
  + guía de WhatsApp con Meta.**
  **DÓNDE RETOMAR:** mandarle a Telenet los 2 entregables de `docs/cuadernos/`
  (`Telenet-consultas-2026-08-21.md` con las 9 preguntas y
  `Telenet-contratos-por-decidir-2026-08-21.xlsx` con 49 contratos / C$154.174). Sin sus
  respuestas no se toca una cuota más. Pendiente aparte: los pagos duplicados (C$23.185).
  · **EJECUTADO (verificado):** 70 cuotas anuladas por **C$59.595,51** en 27 contratos, en UNA
    transacción. Lotes: A=29 cuotas (contrato re-tipeado: mismo servicio cargado dos veces con
    la misma fecha de alta y los meses ya pagados en el hermano), B=19 (cola FUTURA de
    contratos dados de baja — uno facturaba hasta enero 2027), C=5 (mes ya pagado en el
    contrato vigente), D=17 (mes facturado en los dos; se conserva el del vigente).
    Triple registro completo: 27 backups con los uuid adentro (el de Mairena no los tenía y el
    undo fue arqueología) · op_log 70 cuotas + 27 contratos DENTRO de la transacción (en
    Mairena se backfilleó 4h después) · data_ops_log poblado (en Mairena quedó vacío) ·
    snapshot de deuda en los 6 del lote B ANTES de anular. **0 cuotas con plata cobrada
    tocadas** (no había ninguna en los 47 contratos: verificado). Invariantes: los mismos 2
    preexistentes (INV11=3, INV19=7), sin aumentar. SQL en
    `docs/cuadernos/telenet-ejecucion-2026-08-21.sql`.
  · **CONGELADO C$102.860 (63% del cuaderno)** porque no se puede probar desde la base: en 6
    contratos de "mala fecha" el contrato bueno arranca MESES después y esos meses no los
    factura nadie (¿hubo servicio o no?); los 10 "cliente cortado" son deuda REAL declarada por
    el ISP. **Regla que se aplicó: si no está probado, se pregunta — no se borra.**
  · **Lo que el cuaderno NO contemplaba y salió del cruce:** (1) el problema SE SIGUE
    GENERANDO — 29 contratos nuevos por C$90.437 cayeron en el mismo estado entre el 12 y el
    18/08 por una campaña de cortes; vale investigar por qué cortar deja el contrato así.
    (2) C$23.185 de **pagos duplicados** en 7 clientes (uno ni figura en el cuaderno) inflando
    la caja 0,44%: se arregla revirtiendo el PAGO, no anulando cuotas, y primero el pago.
    (3) Marcela QH0066 tiene TRES contratos; el tercero está activo, debe C$5.128 y nunca pagó.
  · **Trampa del dato:** los códigos de contrato de Telenet se distinguen SOLO por ceros a la
    izquierda (561 / 0561 / 00561 son TRES contratos del mismo cliente). Todo se resolvió por
    UUID explícito y se verificó código por código antes de ejecutar (dry-run: 70 cuotas /
    C$59.595,51 exacto). El SQL del análisis traía 2 errores que lo habrían hecho fallar
    (`op_log.actor` no existe; `diff` es TEXT y necesita `::text`).
  · **WhatsApp/Meta:** guía completa en `Install Steps/WhatsApp-Meta-alta-y-setup.md` + PDF de
    25 páginas (sin marca SITECSA). Parte A la hace el ISP, Parte B nosotros, y cierra con los
    4 datos que nos tienen que pasar. Precio verificado: US$0,0113 por mensaje Utility.

- **👉 NUEVO (2026-08-21, ÚLTIMO) — v0.36.0 EN LA CALLE: se cerró la FUGA CROSS-TENANT
  del super_admin impersonando (la bandeja de un ISP mostraba datos de OTROS).**
  **DÓNDE RETOMAR:** testing manual de Rubén sobre v0.36.0 (guía abajo). Después: el
  dashboard sigue en desarrollo y sale cuando él diga (bump ≥0.37.0) · Excel de cruce a
  Franklin · talonario de Derling (8) y LT 110 de Lester · WhatsApp (falta la tarjeta en
  Meta) · los 3 "Ignorar" de huecos históricos de Mairena (SA 2-4, SA 17-43, HL 3).
  · **PUBLICADO:** canal `sitecsa-updates` con SOLO v0.36.0 (v0.35.2 borrado, release y
    tag); tag de código `v0.36.0` = `e5a141c` (rama efímera de release en `C:\sc-release`).
    Maniobra: release creado como DRAFT con los 8 assets → verificado que subieran los 8
    completos → `--draft=false --latest` (flip atómico, para que ningún device pida el
    manifest a medio subir). Manifests verificados por URL (0.36.0 en mairena y telenet) y
    descargas en HTTP 200. APK firmado con la llave real (SHA-256 idéntico al de v0.35.2 →
    actualiza sobre lo instalado). Dashboard y reportes byte-idénticos al tag v0.35.2
    (`git diff` vacío), EXCEPTO los 3 fixes de seguridad de `reportes_admin_screen`, que se
    re-aplicaron a mano sobre la versión revertida. Suite de la rama: 612/612.
  · **GUÍA DE PRUEBA (build esperado 0.36.0, identidad Dev/super_admin):** (1) Dev →
    Test Tenant → Cobros a revisar: la sección Talonario NO debe aparecer (TT no tiene
    huecos); (2) Dev → Mairena: SÍ debe verse, 5 huecos (SA/HL); Telenet: 3 (COL) — si
    alguna queda vacía, se fue de más; (3) sin impersonar, panel Dev → ícono de
    diagnóstico → Talonarios: los 8 huecos CON el nombre de la empresa + 14 series;
    (4) consola → Radiografía `SS0036` y Configuración → Operaciones (impersonando).
  · **EL BUG (reportado por Rubén con captura).** Impersonando Test Tenant, «Cobros a
    revisar» listaba 4 huecos de talonario: 2 de Telecable Mairena y 2 de Telenet, sin
    decir de qué empresa, y su botón Ignorar fallaba siempre (la ESCRITURA sí estaba
    anclada desde 0242 — se cerró la escritura y quedó abierta la lectura, en el mismo
    archivo). Ojo con el dato que confunde: **«System Admin» es el nombre de un COBRADOR**
    (hay uno en Mairena y otro en Telenet), no el tenant System.
  · **CAUSA RAÍZ, un patrón en 3 funciones:** el gate se escribió
    `is_super_admin() OR (tenant = current_tenant_id() AND is_admin_or_cobranza())` y el OR
    cortocircuita → para el super_admin el filtro de tenant NUNCA se evalúa. Relajaba el
    TENANT cuando debía relajar el ROL. **Regla nueva escrita en AGENTS §1.**
  · **NO HUBO FUGA ENTRE ISPs** (lo más importante): para todo rol que no sea super_admin
    el filtro ya era estricto. Verificado simulando 4 identidades reales: admin Telenet ve 3
    huecos (solo Telenet), admin_cobranza Mairena 5 (solo Mairena), cobrador 0, admin TT 0.
    Hay UNA sola cuenta super_admin. El barrido cubrió RPCs, SQLite local, sync rules,
    RLS/Storage y UI (16 agentes, 10 hallazgos, ninguno ISP→ISP).
  · **0246 (aplicada y verificada en prod, sin build):** `recibos_huecos()` anclada +
    `recibos_huecos_todos()` para la consola + `super_admin_diag_talonarios()` apuntada a la
    global (los 3 JUNTOS: anclar la primera sola dejaba /super/diagnostico diciendo «sin
    huecos» con 27 recibos faltantes en Mairena — falso todo-en-orden sobre plata) ·
    `sync_rechazo_autorizado()` anclada conservando la rama del rechazo huérfano ·
    `log_cobertura()` anclada · policy `sync_rechazos_super_all` anclada (el botón Descartar
    ya no puede apagar el aviso de un cobro perdido de otro ISP; forense: nunca pasó) ·
    `sync_rechazo_descartar()` nueva. **El INSERT permisivo de `sync_rechazos` NO se tocó**
    a propósito (endurecerlo perdería avisos — razón en la migración).
    Números antes→después: super impersonando 8 huecos ajenos→0 · admin Telenet 3→3 ·
    Mairena 5→5 · consola 8 huecos/14 series SIN cambios · log_cobertura 31.391→88 ·
    rechazos visibles para el super 11→4. Invariantes 18/20 en cero (INV11/INV19 son
    preexistentes de la limpieza del cuaderno).
  · **App (viaja en v0.36.0):** Descartar por RPC anclada · filtro de empresa en las listas
    de personal (Personal, Rutas, los 3 selectores de cobrador, ranking del dashboard) ·
    unicidad de prefijo por empresa · `SettingsRepo.read()` exige tenantId (53 claves
    colisionan entre empresas) · dbEpoch en 4 providers globales · guard de empresa al
    guardar cliente y al reasignar en masa. **El sync gate NO se tocó** (endurecerlo puede
    trabar el arranque de todos); queda documentado que al saltar entre empresas grandes se
    ve la anterior unos minutos, con las acciones de plata ya bloqueadas.
  · **Trampa que costó una vuelta:** con `ref.read` en `initState` el filtro de empresa
    quedaba congelado en null y la lista salía VACÍA para siempre → patrón `_rehacerStream()`.
  · **AUDIT DE FASE 4 (3 agentes; el primero murió por límite de sesión y se relanzó) —
    9 hallazgos, TODOS aplicados.** Del código (7): **quedaba un 4º selector de cobrador sin
    filtrar y es el que ESCRIBE** (ficha del cliente → Asignar cobrador; sin guard de
    impersonación, dejaba al cliente con un cobrador de otro ISP = fuera de su lista y su
    mapa) · mi guard del form había **reabierto la ventana de doble-submit** que el fix #7
    cerró (un `await` por encima del `setState` que deshabilita el botón) · la reasignación
    masiva **mentía**: decía "50 actualizados" aunque los salteara a todos (ahora cuenta los
    aplicados y explica los omitidos) · el **Excel de Eficiencia no filtraba y su PDF sí**
    (dos vistas del mismo reporte, dos listas — consistencia #10) · filtro de cobrador de la
    lista de cobros · selector de técnico de tickets (ticket asignado a alguien de otro ISP
    que nunca lo ve, con el SLA corriendo). Descartado: "el fix de reportes está sin
    commitear" (el agente leyó el árbol un minuto antes del commit).
  · **0247 — los gates dejan de FALLAR ABIERTO (los 2 hallazgos del SQL, ambos reales).**
    SQL tiene lógica de TRES valores: `if not <expr>` NO entra si `<expr>` es NULL y el
    guard se saltea EN SILENCIO. (a) regresión que introduje en 0246: `sync_rechazo_descartar`
    contra una fila HUÉRFANA llamada por un admin daba NULL y caía al UPDATE → un admin de
    cualquier ISP podía apagar el aviso de un cobro huérfano; (b) preexistente de 0237:
    `sync_rechazo_autorizado` devolvía NULL para todo JWT sin fila en `cobradores` (incluido
    anon) y `sync_rechazo_registrar` la consume con `if not` → **insertaba pagos, recibos y
    op_log** con el guard salteado. Sin exposición viva (0 huérfanos, 0 rechazos sin resolver,
    anon no puede enumerar ids), pero cerrado igual + revoke de anon/service_role en las 6
    funciones del circuito. **Regla nueva en AGENTS §12b** (gate total con `coalesce(...,
    false)`; probar SIEMPRE con una identidad sin fila en `cobradores`, porque con usuarios
    normales el bug es invisible).
  · **Veredicto de regresión: NO se rompió nada para los ISP reales**, verificado con la
    comparativa antes/después por identidad sobre data de producción: Telenet 3→3 huecos,
    Mairena 5→5, Test Tenant 0→0, rechazos autorizados 1→1 / 6→6 / 4→4, log_cobertura
    idéntico. El único que ve números distintos es el super_admin — que es el bug arreglado.
    Suite 643/643 (dos corridas). Ojo: `dashboard_resumen_widget_test` es **inestable dentro
    de la suite completa** (aislado pasa siempre, también en commits anteriores); es del
    dashboard en desarrollo y no entra en este build.

- **(2026-08-20 trasnoche) — SELF-SERVICE DEL DEV: consola de
  diagnóstico (/super/diagnostico) + 3 operaciones de dinero en el panel Operaciones.**
  **DÓNDE RETOMAR:** el SERVER ya está vivo (0243/0244/0245 en prod, E2E ×2 en TT,
  invariantes en 0); la UI viaja en el **build v0.36.0 junto con el dashboard** (cuando
  Rubén lo libere) — hasta entonces no hay nada visible en la app. Decisión parqueada:
  INV11 vs anulaciones Dev en fijos activos (por ahora el preview avisa; ver commit).
  · **QUÉ ES (pedido de Rubén: self-service para los casos puntuales del cliente).**
    Diagnóstico (solo lectura, cross-tenant, online): radiografía de cliente con
    veredicto (cuarentenas/rechazos/vencidas sin pago/anuladas 30d), invariantes por
    tenant, talonarios (series+huecos+ignorados), fantasmas de sync. Operaciones (en el
    panel de siempre, impersonando): **Registrar pago histórico** (caso Jimmy: fecha real
    + atribución + comprobante obligatorio + recibo CRM), **Revivir/anular cuota** (caso
    SS0036, motivo obligatorio, REACTIVADA en verde) y **Baja de deuda del que se va**
    (flujo cuaderno: snapshot→cancelar→anular→desactivar; bloquea parciales y
    cuarentenas). Preview y ejecutar corren la MISMA validación (una _impl por op);
    triple registro server-side: op_log «System Admin» + data_ops_log + backup.
  · **PROCESO:** Fase 4 con 2 agentes → 8 hallazgos, todos aplicados (0245). El estrella:
    el trigger 0215 PISA el correlativo del recibo con el contador → el número reportado
    podía no ser el real (drift CT/RA verificado en prod); fix con RETURNING + estimador
    por contador, probado contra el drift. También: grants reales de Supabase (default
    privileges daban EXECUTE a anon incluso en las _impl), op_log de cuotas futuras en la
    baja (trigger 0234), parseMonto M8 en el monto. Suite 642 ✓ (solo falla el test del
    dashboard WIP, preexistente). Commits d91ff02 + 0b87085, pusheados a main.

- **(2026-08-20 noche) — v0.35.2 EN LA CALLE: el paquete «bandeja
  humana» (campana animada + lenguaje llano + semáforo). El dashboard sigue en prueba.**
  **DÓNDE RETOMAR:** testing manual de Rubén (build esperado 0.35.2; campana y bandeja se
  prueban como ADMIN real — el Test Tenant tiene 2 cuarentenas + 2 rechazos demo que la
  hacen sonar). Después: Excel de cruce a Franklin · talonario de Derling (8) y LT 110
  de Lester · liberar dashboard cuando Rubén diga (bump ≥0.36.0).
  · **QUÉ SALIÓ (pedido de Rubén: interacción entendible, sin bloquear cobradores).**
    Campana en el AppBar del admin: visible en TODAS las pantallas, se sacude cada 8 s
    SOLO con plata pendiente (anti-fatiga: 6 sacudidas por conteo, silencio parado en la
    bandeja, revive con conteo nuevo), refresh propio de 60 s, tap → Cobros a revisar
    (go, regla #12). Badge de cards de plata con latido. Bandeja: ROJO solo pagos/recibos
    con lenguaje llano («El cobro no pudo entrar: …»); avisos internos (cuotas/fontanería)
    en GRIS («se corrige solo al sincronizar; verificá antes de descartar») con jerga como
    detalle técnico; sección «Resueltos automáticamente» (gemelos auto-anulados, 30 días);
    auto-refresh 60 s (mata los fantasmas del 20/08); scroll unificado (el día malo dejaba
    las cuotas inalcanzables en teléfono). Talonario: botón **Ignorar** con registro
    (0242: tabla + RPC con guard de salto REAL del tenant anclado — cierra cross-tenant
    impersonando y supresión arbitraria). Historial: labels de limpieza_deuda /
    duplicado_auto_anulado / anulacion_cuota (anulada vs reactivada). Pagos: chip
    EN REVISIÓN. anularPago: espejo no resta pagos en cuarentena (F6).
  · **PROCESO:** Fase 4 con 2 agentes (código + UX/regresión) → 13 hallazgos, TODOS
    aplicados (el estrella, de ambos: la campana congelaba su conteo — avisaba resueltos
    y callaba nuevos). Suite 612/612 ×2. Release desde rama efímera con dashboard
    byte-idéntico a v0.35.1 (verificado contra el tag; el rezagado dashboard_providers
    en data/ lo cazó la suite). Canal: solo v0.35.2 (v0.35.1 borrado, tags movidos).
  · Migraciones nuevas EN PROD: 0241 (policy colchón) y 0242 (huecos ignorados + guard).

- **(2026-08-19) — LIMPIEZA MASIVA de deuda de Mairena (cuaderno INV19
  ejecutado) + WhatsApp automático a UNA tarjeta de distancia + guía de clonado.**
  **DÓNDE RETOMAR:** (1) mandar a Mairena `Reporte-limpieza-Mairena-2026-08-19.xlsx` (hoja
  Repaso: 13 casos que deben confirmar) y a Telenet su cuaderno nuevo (65 contratos, solo
  deuda VENCIDA). (2) WhatsApp: falta SOLO la tarjeta en Meta (error 131042) — al cargarla,
  limpiar `whatsapp_envios` del TT y re-disparar el lote.
  · **CUADERNO MAIRENA (lo grande).** Mairena devolvió el Excel de deuda-por-estado con 123
    decisiones + 2 columnas propias (CORTADO = fecha real del corte; observación mes a mes) —
    ORO: permitió anular con bisturí. Ejecutado en 1 transacción: **383 cuotas anuladas
    (C$322.888)** por reglas A (al día = fantasma total), B (solo posteriores al corte real),
    C (cancelar contrato viejo); **+65 cuotas de deuda real dada de baja documentada
    (C$41.127)** — el guard de 0220 (desactivado ⇒ sin deuda viva) obligó a elegir: se anuló
    CON registro triple (snapshot en contrato + data_op_backups `limpieza_cuaderno_2026_08` +
    reporte). **54 clientes desactivados**, contratos → cancelado con
    `cancelacion_deuda_snapshot`, op_log `limpieza_deuda` por contrato. Guard 0220 y CHECK
    0021 pararon 2 intentos imperfectos (rollback atómico ambos) — el sistema se defendió.
  · **INVARIANTES: INV19 bajó de 40 → 7** (6 son de Telenet pendiente + SM2095 en repaso).
    INV20 quedó en 0 (recalc canónico; 3 divergencias eran previas, no del run). **INV11=3
    ACEPTADA**: los fijos reactivados (CT0035/FR0029/PG0169) tienen meses anulados → el
    conteo exacto no cierra por diseño; su total = Σ vivas (regla #5). Backlog: refinar INV11.
  · **Lote R (13 casos, NO tocados):** 3 "generar contrato nuevo", 2 titularidad de otra
    persona, 2 "buscar registro en red", supervisiones y ambiguos — en la hoja Repaso.
  · **WHATSAPP (día 18-19):** primera prueba REAL contra WhatChimp encontró que su doc mentía:
    `/send` es solo texto de sesión; plantillas van a **`/send/template` con template_id
    interno** (fix + resolución por nombre vía `/template/list`, commit 22100dc). El lote
    además acepta **CRON_SECRET** (la igualdad con SUPABASE_SERVICE_ROLE_KEY dejó de matchear
    tras la migración de claves de Supabase). **Cron horario INSTALADO y probado** (0239,
    pg_net + Vault). Resultado: 2/2 aceptados por Meta, entrega bloqueada por **131042 (falta
    método de pago)** — Rubén ya configuró moneda, falta la tarjeta. Investigación con
    fuentes: WhatChimp NO cubre las tarifas de Meta (su propia doc), Basic/Pro = 1 número
    (2 tenants = 2 licencias), promo "Nicaragua 50%" = countdown perpetuo, vendor joven con
    quejas de cancelación. **Recomendado: Meta directo** (~US$22,6/mes total, 1 pago; el
    selector ya existe en la app). Plantillas `aviso_gracia`/`aviso_mora` APROBADAS por Meta.
  · **Guía de clonado:** `docs/traspaso/GUIA-SUPABASE-POWERSYNC.md` (34774e0) — Supabase
    desde cero + réplica (rol BYPASSRLS, publicación 49 tablas, JWKS) + VPS + gotchas.
  · **BULLETPROOFING DE RECIBOS Y DUPLICADOS (0240, mismo día — audit adversarial de 2
    agentes + verificación empírica).** Producción venía LIMPIA (0 recibos duplicados
    vivos, 0 gemelos sin marcar, 0 huérfanos, 11/11 contadores alineados), pero el audit
    encontró y 0240 cerró: (1) **ALTA:** recuperar recibos desde la bandeja en orden
    nuevo→viejo brickeaba la serie (contador debajo de números tomados → 23505 eterno,
    todo cobro futuro sin recibo) — era EXACTAMENTE el flujo de los 8 recibos de Derling;
    fix `greatest`. (2) **ALTA:** el guard de sobrepago era solo INSERT: resolver la
    cuarentena o editar un pago podía re-crear el sobrepago invisible; ahora guard en
    UPDATE → vuelve a cuarentena con motivo. (3) El recibo del gemelo auto-anulado
    quedaba VIVO y reimprimible → nace anulado (+ retro: 0 filas). (4) El gemelo
    auto-anulado era silencio total → op_log `duplicado_auto_anulado` en la cuota.
    E2E 8/8 en TT (brick simulado con serie DEMO, resolución equivocada re-marcada,
    legítima limpia, gemelo con rastro); residuo limpio; invariantes estables
    (INV11=3 aceptada, INV19=7 conocidos, INV17 transitorio del colchón). Detalle en
    ARQUITECTURA (sección bandeja). Los 2 rechazos reales de Mairena capturados hoy
    (device de Snay insertando cuota de colchón/cambio-fecha, RLS 42501) quedan como
    caso a explicar — el server repone el colchón vía cron; revisar el gate de UI.
  **PENDIENTE:** verbos `limpieza_deuda`, `duplicado_auto_anulado` y `anulacion_cuota` sin label en
  `historial_op_log.dart` (se ven como "Actualizado" con su motivo; el backfill de 448 filas op_log por cuota anulada —caso SS0036— ya los hace visibles en el relojito de cada cuota) · tanda 3 del audit para próximo build
  (espejo local de anular-en-cuarentena, rastro de renumeración, marca de cuarentena
  en lista Pagos) · backlog: heurística duplicado sub-total, banner de cola <30min,
  push para cuarentenas ·
  tarjeta Meta → re-test WhatsApp → decidir Meta directo vs WhatChimp antes del 21/08 ·
  cuaderno Telenet a Telenet · repaso Mairena (13).

- **(2026-08-18) — v0.35.1 EN LA CALLE para los DOS tenants: bandeja de
  rechazos + fixes de logs. El dashboard nuevo NO salió (sigue en modo prueba).**
  **DÓNDE RETOMAR:** los pendientes del incidente (entrada de abajo) ya se prueban con la app
  publicada. Para liberar el dashboard: release nuevo desde `main`, bump a **≥0.36.0**.
  · **QUÉ SALIÓ.** Todo 0236/0237/0238 (bandeja "Cobros a revisar" con Registrar, rechazos al
    servidor, talonario, banner de cola atascada), los 5 fixes del audit de logs con sus verbos
    nuevos, selector WhatsApp por tenant (dormido), cancelar contratos suspendidos y el fix de
    quitarCargo. SIN el dashboard: rama efímera `release/logs-cuotas` desde main con los archivos
    del dashboard devueltos al estado publicado (la fecha del canal probó que v0.32.0 se compiló
    EXACTO de `origin/main` → ningún tenant pierde nada). Suite 612/612 en `C:/sc-release`
    (los builds y tests NUNCA en OneDrive — lockea archivos y cuelga `flutter test`).
  · **EL RELEASE QUE NO LLEGÓ (v0.35.0) Y SU CAUSA RAÍZ.** El script compiló los 4 instaladores
    y murió ANTES de publicar: el check `gh release view` ("¿ya existe el tag?") quedaba FUERA
    del guard anti-PS5.1 que el propio script ya tenía — su "release not found" ESPERADO se
    volvía fatal con `ErrorActionPreference=Stop`. v0.35.0 se publicó a mano (draft → publish,
    atómico, sin ventana de manifests apuntando a assets inexistentes) y v0.35.1 salió con el
    guard puesto y el script corriendo de punta a punta. Canal: SOLO v0.35.1 (política).
  · **POR QUÉ "NO LLEGABA EL UPDATE".** En la PC de Rubén conviven 3 apps: `CRM PRUEBA` (build
    genérico de testing — NO conectado al canal POR DISEÑO: pide `version.json`, que no se
    publica), Mairena (0.32.0) y Telenet (0.27.0). Solo las brandeadas se actualizan, y el
    chequeo es one-shot AL ARRANCAR (banner en login; en Android cerrar la app del todo).
  · **LAYOUT GIT FINAL:** `main` (local = GitHub) tiene TODO, dashboard incluido sin liberar;
    el tag **`v0.35.1`** marca el código exacto publicado; ramas efímeras borradas. `pubspec`
    de main queda en `0.34.2+256` A PROPÓSITO: el bump se hace al momento del release
    (Install Steps §1) — nunca buildear/publicar desde main sin bumpear ANTES.
  **PENDIENTE:** `GUIA-APP.md` aún no cuenta la bandeja de rechazos (editar `flows_*.py` y
  regenerar mockups cuando toque).

- **(2026-08-20) — Se cerró EL RECHAZO SILENCIOSO MÁS VIEJO de la app (0241) + caso Jimmy.**
  · **El "cartel rojo" de Telenet/Mairena** (cambio en Cuotas rechazado): NO era bug nuevo —
    era el colchón de indefinidos que el DEVICE genera al cobrar adelantado (diseño de v0.2x,
    `colchon_indefinido.dart`) chocando contra un RLS que NUNCA tuvo policy para permitirlo.
    Rechazo 42501 silencioso desde el día uno; los INV17 "preexistentes" eran esto. v0.35.1
    solo lo hizo VISIBLE (7 capturas/2 días: Snay, Lester, Derling — todos la cuota de dic).
  · **0241:** policy `cuotas_colchon_insert_cobrador` QUIRÚRGICA (tenant + contrato activo
    coherente + pendiente + sin pago + período >= mes actual + sin cargo manual; SIN exigir
    asignación — carrera de reasignación con la cola offline, caso real LB0139 sin asignar).
    Reposición server-side de los colchones rotos → **INV17 = 0 por primera vez**. Bandeja
    limpia (rechazos de cuotas resueltos; los 4 demo del TT intactos). E2E con identidad
    REAL de Snay vía `set role authenticated` + claims: su subida exacta ENTRA; una cuota
    con período pasado REBOTA 42501. Backlog: fórmula del cron 0178 (un mes corta en
    pago-adelantado) como segunda red.
  · **Caso Jimmy (LB0226):** pagó "junio" (servicio; período JULIO — ojo regla mes-servicio)
    el 26/07 con recibo N. 5367 del sistema ANTERIOR; nunca entró al CRM. Registrado
    retroactivo: pago C$1.282 fecha real 26/07 atribuido a Oficina Telenet, recibo CRM
    COL-00166, op_log `cobro_recuperado` citando el papel viejo. **Puede no ser el único:**
    generado Excel `Telenet-cruce-talonario-viejo` (359 cuotas ≤ julio de 231 clientes
    activos, C$344.517) para que Franklin cruce contra su talonario viejo — los "SI pagó"
    se registran en lote.
  **PENDIENTE:** Excel de cruce a Franklin · su devolución → registro en lote.

- **(2026-08-17) — INCIDENTE: 10 cobros de Telenet perdidos y nunca detectados.
  2 recuperados. Migración 0236 + `sync_rechazos` YA EN PRODUCCIÓN.**
  **DÓNDE RETOMAR:** faltan **8 recibos** (`COL-00020..24, 26, 27, 29`) — hay que pedirle el
  talonario a Derling. Y falta la **prueba decisiva**: que abra su app y vea si a Rosa Emilia le
  figura julio pagado.
  · **QUÉ PASÓ.** El 28-29/07 Derling Merlo cobró, imprimió los recibos `COL-00020..29` y se los
    dio a los clientes. Las filas nunca llegaron al servidor. Se supo el 17/08 porque una clienta
    reclamó por WhatsApp que le seguían cobrando julio. **19 días ciegos.** No hay pérdida de
    plata para el ISP (el efectivo lo recibió el cobrador) — es un problema de REGISTRO, pero los
    clientes figuraban morosos habiendo pagado.
  · **CÓMO SE DETECTÓ EL ALCANCE.** El correlativo del talonario saltaba. Primer conteo: 80
    faltantes en Mairena — **falso**: 21.538 de sus 25.095 recibos son IMPORTADOS del sistema
    viejo (`created_at` a medianoche UTC, sin hora) y sus huecos son del talonario anterior. Se
    delatan porque el recibo "siguiente" tiene fecha ANTERIOR al previo. Filtrando eso: **6 huecos
    reales**, y de esos solo 2 con perfil de cobro en calle (Telenet `COL` 20-29 y Mairena `LT`
    110). El resto son tandas de testing (clientes `PRUEBA` y `Juan Diaz Perez`).
  · **POR QUÉ SE PERDIERON (lo probado y lo que falta).** DESCARTADO: borrado de la app (el
    contador siguió en 30, no reinició en 20), rol `lectura` (siempre fue `cobrador`) y cambio de
    permisos (el único cambio del 29 fue renombrarlo). QUEDA EN PIE: el server los rechazó y
    `connector.dart` los descartó — el único camino por el que un write encolado desaparece.
    **PowerSync NO falló**: hizo lo que le pedimos. La decisión de descartar es NUESTRA y está
    bien fundada (si no, la cola se traba y ese cobrador no sincroniza nunca más). Lo que estaba
    mal es que el aviso se quedara en el device. **El motivo exacto del rechazo solo existe en el
    teléfono de Derling** (`RechazosSyncService`, tope 50 avisos, los nuevos pisan a los viejos).
  · **RECUPERADOS 2 de 10** (C$2.930): Rosa Emilia `VQ0018` C$916 (`COL-00028`) y Gerald Mairena
    `AL0043` C$2.014 (`COL-00025`), con su número ORIGINAL para que coincida con el papel.
    OJO al hacerlo: el trigger `recibos_asignar_correlativo` (0215) **pisa** el correlativo del
    INSERT — hubo que corregirlo por UPDATE después y devolver el contador. Invariantes de dinero
    corridos: **0 violaciones** en todo lo que toca el cambio.
  · **LO CONSTRUIDO (0236).** `sync_rechazos`: los rechazos suben al SERVIDOR con el payload
    completo. Su INSERT es **permisivo a propósito** (`authenticated`, `with check (true)`) — con
    las condiciones de `pagos`, el aviso podría ser rechazado por el mismo motivo que el cobro.
    `_subirRechazo` NO pasa por la cola de PowerSync (es lo que acaba de descartar el write).
    Y `recibos_huecos()`: detecta huecos reales excluyendo importados y testing.
  · **HALLAZGO DE CONTEXTO.** Desde **0215 (01/08)** el correlativo lo asigna el SERVER, tres días
    después del incidente. Valida el diagnóstico (el 29/07 numeraba el device) y ya cerró la
    familia de bugs de colisión. Su propia doc registra que **esto ya había pasado**: los
    `OF-12292..12311` se backfillearon a mano.
  · **PREEXISTENTES que aparecieron al correr invariantes** (NO son de este cambio, todos Mairena):
    INV17 = 4 contratos indefinidos sin colchón de cuotas futuras · INV19 = 40 clientes
    desactivados con deuda.
  · **CERRADO EL CIRCUITO (0237, mismo día):** la bandeja es accionable — "Cobros a revisar"
    gana las secciones ONLINE "Rechazados al sincronizar" (botón **Registrar**: RPC definer
    re-inserta el pago, el guard 0218 decide cuenta/cuarentena/duplicado, el recibo conserva
    el número IMPRESO) y "Talonario" (`recibos_huecos()`, ahora gateada por tenant). Badge =
    cuarentena local + rechazos online. `ColaAtascadaBanner` en shells admin+cobrador: cambios
    sin subir >30 min CON conexión (la falla que el server no puede ver). E2E en TT: pago 615
    entra y cuenta, cuota pagada por trigger, recibo TESTREG-00007 preservado, contador
    devuelto, doble-toque rechazado; residuo limpiado, invariantes 0 (INV17=5 e INV19=40
    preexistentes; el 5º de INV17 es NA0023 Telenet, operación viva de hoy). El cron nocturno
    se REEMPLAZÓ a propósito por badge-al-abrir: un cron sin canal de aviso no avisa a nadie.
  · **AUDIT DE LOGS (2026-08-18, pedido de Rubén):** el núcleo de op_log FUNCIONA (39.485
    filas); los huecos eran 5 y puntuales. F1: registrar desde la bandeja no emitía op_log — el
    historial de la cuota quedaba MUDO (disparador probable del reclamo); ahora emite
    'cobro_recuperado' (E2E: «Cobró C$615 (recuperado) · Ruby Admin · pendiente→pagada»).
    F2: resolver cuarentena emitía solo entidad 'pagos' que NINGUNA pantalla consulta → fila
    'revision_resuelta' en la cuota. F3: reimpresión de recibo (solo si ya había impresión).
    F4: foto de comprobante que se pierde. F5: log_cobertura(días) (0238) — actividad vs rastro
    por concepto, para detectar el próximo silencio con datos. CLEAN: tickets/inv/red emiten
    pero tienen ~0 uso; visitas/etiquetas/fotos/cargos loguean bajo el padre por diseño.
    Build v0.34.2 (256) instalada.
  **PENDIENTE:** los 8 recibos de Derling · la prueba de 2 min en su teléfono (¿julio figura
  pagado?) · si aparece el código exacto del rechazo, decidir si su clase merece trato especial.

- **(2026-08-16) — WhatsApp: se elige el proveedor POR TENANT (Meta directo o
  WhatChimp). Migración 0235 y las 2 edge functions YA EN PRODUCCIÓN; el envío sigue apagado.**
  **DÓNDE RETOMAR:** build de prueba **v0.33.0 (`6f2adc6`)**. Falta que Rubén cargue la clave de
  su cuenta WhatChimp y cree las 2 plantillas con `{{1}}..{{4}}`. Destino de prueba listo:
  **TT-12 Iveth, tel `82218473`** (Test Tenant).
  · **EL PEDIDO.** *"queremos que se mande de manera automática en vez de abrir la app de WhatsApp
    y darle enviar"*. Se verificó a fondo (20 agentes, doc oficial) que **NO existe camino gratis
    y automático**: `wa.me` solo abre y prellena —no tiene parámetro de auto-envío— y automatizar
    el click cae en "auto-messaging" de los ToS (baneo del número, detección por ML). Las listas
    de difusión mandan a 256 pero **solo llegan a quien te tiene agendado**, en silencio si no.
    La Cloud API tampoco tiene free tier: las 1.000 conversaciones gratis murieron el 1-jul-2025.
  · **LO QUE SE CONSTRUYÓ.** `cobranza.notif_api_proveedor` (0235, default `meta` = lo de antes).
    `whatsapp-enviar` bifurca SOLO el pedido de salida; elegibilidad, frecuencia, tope y log son
    compartidos. Tres diferencias reales de WhatChimp: token como parámetro `apiToken` (se manda
    por POST, no por GET como su doc, para que no quede en logs), variables **POSICIONALES**
    `{{1}}..{{4}}`, y éxito por `status == "1"` **en el body** (devuelve 200 aunque falle).
  · **LA TRAMPA DE LAS POSICIONALES.** El envío manda SIEMPRE las 4; si la plantilla usa menos,
    los datos salen corridos. `ORDEN_VARIABLES` (edge function) y `_orden` (editor) son el MISMO
    contrato y el editor AVISA si falta alguna. Las plantillas NO son intercambiables.
  · **NÚMEROS REALES de producción** (para dimensionar): a notificar hoy **Mairena 1.529 · Telenet
    466**; utility a Nicaragua = **USD 0,0113** (CSV oficial, "Rest of Latin America") → ~USD 90/mes
    entre los dos. Meta NO cobra renta ni por número. Los escalones son 250 → **2.000** → 10.000
    (no 1.000, como decía la doc de terceros) y cuentan **clientes únicos**, no mensajes.
  · **HALLAZGO NO PEDIDO:** **632 clientes de Mairena tienen el teléfono en `0`** (placeholder del
    import de Excel) = 19% de los morosos, inalcanzables por cualquier canal. Otros ~24 tienen dos
    celulares pegados en 16 dígitos, recuperables partiéndolos.
  · **ARQUITECTURA §Avisos corregida:** decía que Meta usa variables posicionales; usa **con
    nombre** (`parameter_name`). Estaba mal desde 0137.
  **PENDIENTE PARA QUE ANDE:** el cron `whatsapp-lote-hourly` **NO está instalado** → hoy solo
  funciona el botón "Probar". Subir el tope diario (200 no alcanza para 1.529). Y nada de esto se
  probó nunca contra la API real de WhatChimp — se escribió contra su doc de feb-2026.

- **(2026-08-14) — Cobertura del ciclo vuelve a 3 filas · mapa de impacto ·
  26 skills instaladas. SIN PUBLICAR (nada fue a producción; 12 commits en `main` sin pushear).**
  **DÓNDE RETOMAR:** build de prueba **v0.32.0 (8140055)** instalado como `CRM PRUEBA` —
  Rubén todavía no lo probó. Reiniciar Claude Code para que carguen las skills nuevas.
  · **LA TARJETA.** Terminó en las 3 filas de su Excel original: `Cobros / Recuperado /
    Por recuperar` × `Usuarios | Cuotas | Monto | Cumplimiento`. Las tres columnas de conteo
    SUMAN porque cada una usa una definición disjunta (un cliente debe o no debe; una cuota
    está saldada o tiene saldo; un córdoba entró o falta): 5+8=13 · 7+8=15 · 5.800+5.400=11.200.
    El gráfico pasó a eje **%** (0-100) para hablar la misma unidad que la columna Cumplimiento.
  · **QUÉ SE APRENDIÓ (el porqué de 8 iteraciones).** La causa raíz del "siento que los números
    no cuadran" era que **la columna % medía PLATA mientras el ojo cuenta CUOTAS**: "7 cuotas ·
    42%" invita a calcular 7/15=47%, y fallaba por 5 puntos en toda la columna — lo suficiente
    para parecer error de cuenta. Segunda causa: dos particiones apiladas con conteos distintos
    (7/2/6 y 5/2/7/1) que reconciliaban sin decirlo. **Regla que queda: una tarjeta, una unidad.**
  · **LA MORA SALIÓ de Cobertura**, por pedido explícito ("quitemos de momento la data de la mora
    para luego re-evaluarla"). NO se borró: `cortesDelCiclo` y `serieMoraDiaria` siguen en
    `dashboard_query.dart` **con sus tests pasando**; lo que se quitó es el cableado a la UI.
    Re-enchufarla no exige rehacer matemática.
  · **EL EXCEL NO SE TOCÓ** (decisión de Rubén): sigue con el detalle fino — fila por cuota,
    columna Tipo (mensualidad/cobro puntual), servicios en su bloque con subtotal, y las 4
    columnas de mora. Es donde vive el desglose que la tarjeta ya no muestra.
  · **`tools/impacto.py` (lo más importante de la sesión).** Dado `cuotas.cargos_neto` recorre
    las 8 capas donde una tabla vive y avisa de lo que rompe callado. Nace del reclamo: *"se
    piden cambios que por jerarquía van encadenados con otras tablas, esas tablas se quedan
    fuera y esos cambios dañan la interacción"*. **Obligatorio en Fase 2.** AGENTS gana además
    la sección "Cómo se DELEGA" con las 8 capas y qué se puede delegar.
  · **26 SKILLS** en `.claude/skills/` (gitignored): ui-ux-pro-max (7), superpowers (14, **solo
    las skills, NO sus hooks**, para que no compitan con AGENTS.md), obsidian-skills (5).
    gsd-core se instaló **global** en `~/.claude/` con **17 hooks, 7 de ellos PreToolUse** —
    corren en TODOS los proyectos; rollback en `~/.claude/gsd-file-manifest.json`.
    claude-mem quedó instalado con el worker APAGADO y **sin sync a la nube**.
  **PENDIENTES:** seed nuevo (solo mensualidades, reemplaza al actual → hay que recalcular a
  mano los esperados de 18 tests) · botones de selección rápida en los KPIs de caja · el guard
  de `quitarCargo` (plata real: quitar un cargo ya cobrado deja la cuota sobrepagada sin
  acreditar nada) · los 5 contratos con C$4.898 de `costo_instalacion` que nunca se facturaron ·
  `tickets` no está en el bucket `por_cobrador` de las sync rules (el recibo sale distinto según
  quién lo abra; invisible hoy porque hay 0 tickets).

- **(2026-08-12) — El Resumen: matemática verificada, export a Excel, y la
  reconciliación Excel ↔ gráfica. SIN PUBLICAR (falta bump + build).**
  **EL RECLAMO:** *"este módulo de dashboard está confuso, esta data no está siendo real"*.
  · **Math del ciclo.** El eje de la curva daba "2k · 2k · 1k · 578" (ticks no redondos);
    `porrec_m` se calculaba por RESTA, así que una cuota sobrepagada le comía deuda a los demás
    → ahora se CONSULTA con el saldo canónico clampeado, y el test lo verifica en vez de que
    cierre por construcción. Los porcentajes imprimían 101% (dos redondeos independientes) → se
    redondea uno y el otro se deriva. El filtro de suspendidos escondía C$99.972 de ciclos
    cerrados en Mairena: eliminado.
  · **Mora = últimos 6 ciclos** (antes el ciclo suelto + una barra aparte). Las tres filas de
    cobertura pasan a **Pago Completado / Parcial / Pendiente**, particionando las cuotas en
    grupos disjuntos que suman el total en las 4 columnas.
  · **Export a Excel de las dos tarjetas** (pedido del dueño): el detalle exacto que hay detrás
    del número, con el **código de contrato** por fila para distinguir a quien tiene varios; el
    de mora sale segmentado por ciclo con subtotal. Las cuotas anuladas van en su propia hoja
    ("Excluidas") con motivo — hoy no aparecen en ningún lado.
  · **El Excel no cuadraba con la gráfica** (22.150/18.265 vs 21.950/18.065). **Ninguno estaba
    mal: medían cosas distintas.** Cobertura mide lo FACTURADO del ciclo; mora mide lo que CAYÓ
    EN ATRASO. Un abono hecho DENTRO de la gracia cuenta en la primera y no en la segunda — la
    brecha de C$200 era un solo pago así (TT-06, abonó el 05-ago sobre una cuota con gracia
    hasta el 09). Yo había reusado las columnas de cobertura en la tabla de mora. Ahora el
    detalle de mora trae **En mora / Recuperado tarde / Sigue impago** con las mismas
    expresiones SQL que su tarjeta (+ Facturado / Pagado a tiempo como contexto, que son los
    que explican la diferencia). **Regla nueva en ARQUITECTURA §Dashboard.**
  · **Dos bugs que el audit encontró y yo no vi.** (1) El corte de "hoy" se evaluaba en DOS
    momentos: la tarjeta es un `watch` que PowerSync solo re-ejecuta al cambiar `cuotas`/`pagos`,
    el Excel un `getAll` al hacer clic → cruzar la medianoche con el dashboard abierto los
    desincronizaba (medido: Mairena +58 cuotas y **+C$42.680**, Telenet +26 y +C$25.840). Pasa a
    ser un PARÁMETRO que la tarjeta calcula y le pasa al Excel, + re-arme a medianoche vía
    `diaNicaraguaProvider`. El comentario que decía "resolver `now()` en SQL evita que quede
    congelado" era **falso** y estuvo vivo meses. (2) En `meta_m` el término de pagos tardíos no
    llevaba el guard de "hoy" que sí tiene `rec_m`: no cambia un centavo hoy, pero la identidad
    `meta_m = rec_m + porrec_m` dependía de que ningún pago tuviera fecha futura.
  · **Contratos cancelados "generando" cuotas** (reporte del dueño): los gates del cron estaban
    bien; era una carrera cliente/servidor (huecos de 1 y 6 minutos). **0234** = trigger
    `z_contratos_anular_cuotas_futuras` + reparación de 9 cuotas (C$7.364). **Corrida en PROD.**
  · **Infraestructura de verificación.** El SQL salió del widget a `dashboard_query.dart` (los
    tests corren la consulta de PRODUCCIÓN, no una copia); escenario de 15 clientes en 6 ciclos
    con esperados calculados A MANO; el test del export abre el `.xlsx` generado y lee las
    celdas. **639 tests.** Los de mora ahora fijan el día de corte → dejan de depender de cuándo
    se corran. `Install Steps/test-local.ps1`: build de prueba que VERIFICA que el binario lleva
    el cambio (busca los marcadores en `app.so` en UTF-8 y UTF-16) — nació de un "no hubo ningún
    cambio visual" que era una app branded vieja abierta por error.
  **AUDITS:** 15 agentes (6 casos borde + refutación) sobre la reconciliación → 4 findings;
  7 agentes sobre la implementación → 1, y era mío: tomaba el día del valor CACHEADO del
  provider, que puede ser de ayer hasta 60s pasada la medianoche, y hacía RETROCEDER el corte.
  **Commits:** `4af8be7` (.xlsx + código de contrato) · `7401411` (el año salía dos veces en el
  nombre del archivo) · `d5738dc` (reconciliación) · `4a56b5a` (el corte sale del reloj + doc).
  **PENDIENTE:** botones de selección rápida en los KPIs de caja (con dos trampas conocidas:
  `VentanaCaja` no tiene cota superior y `desgloseCajaProvider` clasifica siempre contra el ciclo
  actual) · **el guard de `quitarCargo`** (`cuotas_repo.dart:387`): quitar un cargo de una cuota
  ya cobrada puede dejarla sobrepagada sin acreditarle nada al cliente — es plata real, se
  difirió a propósito por tocar escritura de dinero · bump + build · los 40 de INV19.
  **Nota de proceso:** NO correr `dart format` en este repo (usa el estilo pre-Dart 3.7);
  reformateó 5 archivos ajenos, incluido el seed GENERADO. Revertido y verificado.

- **(2026-08-10) — Notas internas, se elimina la suspensión por lote, y la deuda
  a la vista al pedir/aprobar un corte. SIN PUBLICAR (falta bump + build).**
  Tres pedidos del dueño del tenant, atacados en orden.
  · **Nota del CLIENTE (0227, nueva)** — contexto de la PERSONA ("atiende la hija después de las 3",
    "el perro está suelto"), que sobrevive a sus contratos. Se ve en la ficha (todos los roles, así
    la lee el cobrador en la puerta) y se edita desde el form. Cadena R4 completa. El historial de
    la nota funcionó solo: `notas` ya estaba anticipado en la allowlist y en el override vivo de
    los tenants.
  · **Nota del CONTRATO** — existía y el header la mostraba, pero **no había forma de editarla**:
    una nota mal escrita al crear el contrato quedaba petrificada (48 contratos en producción la
    tienen). Ahora tiene tarjeta propia con editor acotado de una columna (NO se reabre el form de
    contrato: eso hacía divergir contrato y cuotas). Se sacó del header para no pintarla dos veces.
    Su historial tampoco existía → `notas` a los dos mapas de `audit_changelog` + **0228** al
    setting `op_log.campos_visibles` de Telenet y Test Tenant, que lo habrían filtrado igual.
    **Gate = espejo EXACTO de la RLS** (admin | admin_cobranza | super_admin). Rubén pidió "todos
    los roles", pero `contratos` no tiene policy de UPDATE para admin_usuarios ni para el cobrador:
    un gate más ancho que la RLS no habilita nada, solo promete un guardado que el server descarta
    y que desaparece solo al siguiente checkpoint.
  · **Suspensión/reactivación EN LOTE: ELIMINADA** (decisión de Rubén, revierte lo que decía la
    entrada de abajo). Cada corte es individual sin importar cuántos sean y el admin los tiene que
    ver de a uno. Además era la puerta trasera del circuito de v0.31.28: el mismo rol no podía
    suspender UN contrato pero sí treinta de un click, con motivo fijo y sin ver la deuda.
    Se borró `lote_servicio_dialog.dart` entero + los params de `ColaCard`.
  · **La deuda a la vista (0229)** — efecto colateral de v0.31.28: el rol que antes suspendía
    directo veía "Deuda a la fecha" y al pasar a pedir permiso dejó de verlo; al admin le llegaba
    una tarjeta sin un solo número. El bloque salió del State privado del diálogo a
    `deuda_contrato_bloque.dart` → lo comparten los cuatro caminos. **Para cancelar es feature
    nueva, no restauración:** `previewDeudaCancelacion` existía sin un solo consumidor y el
    diálogo directo describía la deuda en prosa. La tarjeta **recalcula en vivo** (colgada de
    `contratoCuotasProvider`, no one-shot) porque entre pedir y aprobar el cliente puede pagar;
    el snapshot solo explica la diferencia. Las tres fechas salen de `SolicitudesRepo.fechaEjecucion()`.
  · **Bug de plata cazado por el audit:** el corte por APROBACIÓN no registraba la disposición del
    excedente y los dos caminos directos sí. Un cliente que pagó 3 meses por adelantado y era
    suspendido por la cola —el único camino del admin_cobranza desde v0.31.28— perdía el rastro de
    su plata. Se agregó `_disponerExcedente` ('acreditar', el default seguro).
  **AUDIT**: 5 lentes + 2 escépticos por finding (67 agentes). 31 crudos → 22 confirmados.
  **Dos autocorrecciones que importan:** (1) afirmé que la nota del contrato "no la mostraba
  ninguna pantalla" — **era falso**, el header la mostraba, y mi tarjeta la duplicaba; (2)
  `_porQueCambioLaDeuda` afirmaba "el cliente pagó" por descarte, pero un descuento, un crédito
  aplicado o una cuota anulada bajan el total sin que entre un peso (invariante #4) — reescrito
  para afirmar solo lo que el snapshot prueba (precio y día de pago) y reportar el resto como
  diferencia, sin inventar causa.
  · **La nota la edita CUALQUIER rol menos `lectura`** (Rubén revirtió el "solo admin" el mismo
    día). Como la RLS es row-level, abrirla suelta habría abierto también `precio_mensual` y
    `estado` → **0230**: policy permisiva + trigger que hace `new := old` y repone SOLO lo
    permitido (no enumera qué revertir, así una columna nueva nace protegida). Revierte en
    silencio, nunca `raise`: un P0001 haría que el connector descarte el save entero.
    **0231 — HOTFIX del mismo día, bug MÍO ya vivo:** `SECURITY DEFINER` cambia el usuario de
    Postgres, NO el JWT, así que dentro de `recalc_vencimiento_mas_viejo()` `auth.uid()` seguía
    diciendo 'cobrador' → la barrera le revertía al SERVER sus columnas derivadas. Efecto: el
    cliente pagaba y seguía con el pin rojo y en la cola de corte. El discriminador correcto no
    es QUIÉN es el usuario sino QUIÉN escribe: `current_user IS DISTINCT FROM 'authenticated'`.
    **Mi primer intento (`current_user <> session_user`) desactivaba la barrera ENTERA** — bajo
    Supabase la conexión entra como `authenticator` y hace `SET ROLE`, así que difieren en toda
    petición. Lo cazó la prueba de regresión, no el razonamiento.
    **0232:** el empleado dado de baja seguía pudiendo escribir (las policies no miraban
    `cobradores.activo`), y `admin_usuarios` veía el lápiz sin efecto — tenía UPDATE pero no
    SELECT sobre `contratos`, y el RETURNING del connector lo necesita; peor, el `op_log` sí
    entraba, así que el historial mostraba una nota que el contrato no tenía.
  **AUDIT de la barrera**: 4 lentes + 2 escépticos (58 agentes). 27 crudos → 21 confirmados.
  **DATOS DE PRODUCCIÓN corregidos (decisión de Rubén, 2026-08-10):**
  · **14 contratos perdidos, creados.** Eran 10 y crecieron a 14 — clientes con servicio y sin
    facturación (C$14.469/mes). Los 14 códigos pedidos estaban ocupados POR OTRA PERSONA
    (verificado uno por uno: ninguno era duplicado), así que se les asignó el siguiente de la
    serie del tenant. Se respetó la `fecha_inicio` que había guardado cada solicitud → 55 cuotas,
    de las cuales solo **4 ya vencidas (C$3.590)**; el resto es facturación normal a futuro.
    Corrida en seco con ROLLBACK antes de commitear.
  · **34 clientes reactivados.** Estaban desactivados con el contrato ACTIVO: la app los escondía
    de las 3 rutas de cobro mientras el contrato seguía generando cuotas → **C$222.689 de deuda
    creciendo invisible**. INV19 bajó de 74 a 40; los 40 que quedan tienen el contrato
    suspendido/cancelado (C$81.669) y son otra decisión: cobrar o dar de baja la deuda.
  **PENDIENTE:** bump de versión + build · reiniciar PowerSync en el VPS (columnas nuevas) ·
  los 40 de INV19 · **la detección de rechazos silenciosos quedó ciega para `clientes` y
  `contratos`** (se apoyaba en que la RLS filtrara la fila; ahora pasa y el trigger revierte por
  columna) — hoy ningún camino de la app lo produce, pero si aparece uno no habría aviso.
  `analyze` en los 4 info preexistentes, **609 tests**, 19/20 invariantes limpios.

- **(2026-08-09/10) — v0.31.27 y v0.31.28: el circuito de aprobación, de verdad.**
  **EL RECLAMO DE RUBÉN:** *"un admin de cobranza puede suspender directo en vez de mandar la
  notificación al admin, y las notas siguen siendo opcionales"*. Correcto, y con una causa raíz
  peor que el síntoma: **el circuito no existía como concepto**. Cada botón preguntaba
  `esAdminUsuarios ? solicitar : ejecutarDirecto`, o sea decidía por ROL y POR DESCARTE —
  todo el que no fuera el gestor caía en la rama directa, incluido cualquier rol futuro. Y las
  notas obligatorias vivían DENTRO de `solicitarAccion`, o sea solo en la rama que él no tomaba.
  Medido: **el admin_cobranza decidía el 55% de las bajas de contrato**, con una tasa de
  reversión 2,6× la del admin.
  **LO QUE SE HIZO** (`aprobaciones_provider.dart`): la pregunta pasa a ser
  `requiereAprobacionPara(rol, acción)` — **requiere aprobación salvo que seas quien aprueba**.
  Alcanza crear, suspender, reactivar, cancelar, revertir y cambiar de plan. Por decisión de
  Rubén el camino EN LOTE del centro de cobranza queda FUERA (las solicitudes se revisan de a una).
  · **0225 `app_dispositivos`** — telemetría de versión por dispositivo. No había forma de saber
    qué corría cada equipo, y eso ya hizo que DOS auditorías sacaran conclusiones falsas. Va
    directo por Supabase (no por PowerSync), best-effort.
  · **0226 `cambiar_plan`** — tipo de solicitud nuevo. El admin_cobranza ni lo veía: por eso
    **3 de cada 4 "cancelaciones" son cambios de plan a mano** (45 de 61 tienen contrato hermano
    con plan distinto, creado ANTES de cancelar el viejo). Detrás del setting, apagado en los dos
    tenants reales.
  · **Revalidación AL APROBAR** — `_ejecutarCrearContrato` no chequeaba el código. Así se
    perdieron **10 contratos**: dos gestores pedían el mismo número con 18 h de diferencia, el
    admin aprobaba los dos, y el server rechazaba el segundo dejando la solicitud "aprobada" y al
    cliente sin contrato. Hoy: 10 clientes activos, con servicio, **sin contrato ni cuotas**.
  · **La tarjeta muestra el PEDIDO**, no solo el estado actual de la entidad.
  · **Resumen del admin_cobranza** — el requerimiento decía "que lo vea sin montos recolectados";
    lo implementado ocultaba las tarjetas ENTERAS, así que entraba y no veía nada, ni la mora.
    Ahora el recorte va adentro: vuelven Cobros del mes, Mora y Proyección sin la fila de cobrado
    ni la curva. **Alcance decidido por Rubén: el recorte es del RESUMEN, no del rol** — sigue
    sacando "Reporte de cobranza", que trae `monto_cordobas` de cada pago. No re-flagear como fuga.
  **CUATRO AUTOCORRECCIONES**, las cuatro compilaban y pasaban los 603 tests:
  (1) el guard del connector comparaba tipos entre SQLite y Postgres (`'1' != 'true'`) → habría
  gritado en CADA anulación de pago; (2) los espejos locales → **1.897 avisos rojos por mes**, uno
  por cobro; (3) la revalidación traía filas con tope y daba falso "libre" con 4.524 contratos;
  (4) el gate nuevo dejaba abierto el dropdown del header —el mismo camino que el commit citaba
  como el problema— y de paso le mostraba "Solicitar cancelación" a cobrador, técnico y lectura.
  **AUDITS**: 51 + 26 agentes con refutador por finding. El de permisos abrió con *"no se puede
  mergear como está"* y tenía razón. Cazó además dos notas que imprimían montos cobrados al rol
  que no debe verlos (C$171.821,92 en Mairena), invisibles antes porque la tarjeta estaba oculta.
  **DOCS**: `PRODUCTO.md` y `MODULOS.md` decían tres cosas falsas (la cola era "de admin_usuarios",
  cobranza "no cambia plan", y nada sobre qué hacía cobranza con los contratos — el vacío que
  originó todo). Corregidos.
  **PENDIENTE Y DICHO:** la barrera es CLIENTE. `contratos_write_admins` = `is_admin_or_cobranza()`,
  así que una app vieja sigue ejecutando directo. Cerrar esa policy va DESPUÉS de que
  `app_dispositivos` confirme que todos actualizaron. Y **los 10 contratos perdidos siguen
  perdidos**: esto previene nuevos, no repara los viejos (falta decidir con qué fecha nacen).
  `analyze` en los 4 info preexistentes, **603 tests**. **v0.31.28+251, PUBLICADA.**

- **(2026-08-09) — v0.31.26: el "bloque seguro" de la auditoría de roles + Test Tenant limpio.**
  Cuatro fixes aislados, hechos **de a uno** (pedido de Rubén: paso a paso, verificando que cada uno
  encaje antes del siguiente), ninguno toca plata.
  · **0224 — resolver una cuarentena ya no deja la cuota fantasma.** `trg_pagos_update_recalcular`
    escuchaba `monto_cordobas, cuota_id, anulado` pero NO `en_revision`, y
    `recalcular_cuota_desde_pagos()` filtra por esa columna. Como `elegirCobroVerdadero` anula PRIMERO
    y saca de revisión DESPUÉS, la cuota quedaba PENDIENTE con la plata cobrada. Probado en transacción
    revertida (viejo: queda en 500,00 / nuevo: pasa a 1.000,00), **aplicado a prod**, invariantes
    ANTES == DESPUÉS. Daño previo: 0 cuotas.
  · **Connector — los writes rechazados en silencio ahora avisan.** `patch`/`delete` iban sin
    `.select()`: si la policy filtraba por USING, PostgREST devolvía 204 con cero filas y sin error, el
    connector lo daba por exitoso y al llegar el checkpoint PowerSync revertía el valor local. 57
    policies en 32 tablas podían hacerlo. Código propio `RLS0`.
  · **`admin_usuarios` ya no ve un Total inventado** (contrato 1797: veía 8.240,00 donde van 19.776,00,
    −58%). Ahora ve conteo de cuotas (7/12), que sale de `cuotas` y es exacto. El rol se lee DENTRO de
    `_ContratoResumen`, así quedan cubiertos los 2 call sites.
  · **Solicitudes bloquea aprobar/rechazar/verificar al impersonar** (la carpeta era la única de
    `lib/features` sin el guard). Daño ya hecho: 0 de 202 resueltas.
  **DOS AUTOCORRECCIONES del connector, que es lo que salvó el release:**
  (1) El primer guard comparaba los valores escritos contra los del server COMO TEXTO. Cruza dos
  sistemas de tipos: `anulado`/`en_revision` son `Column.integer` (0/1) local y `boolean` en Postgres
  → `'1' != 'true'`, y las fechas nunca coinciden (Dart manda `...Z`, Postgres devuelve `+00:00`).
  Habría gritado "rechazado" en CADA anulación de pago. Reemplazado por la pregunta que no toca tipos:
  **¿la fila sigue visible?** (si se ve y el update volvió vacío, es rechazo; si no se ve, no se acusa).
  (2) El audit cazó que `registrarCobro`/`registrarCobroMultiple` llaman `recalcVmvDeContrato`
  (`pagos_repo.dart:439` y `:683`) para repintar el pin del mapa, escribiendo
  `clientes.vencimiento_mas_viejo` — columna del trigger server `cuotas_vmv`, en una tabla donde el rol
  `cobrador` NO tiene policy de escritura. Ese rechazo es lo ESPERADO. Sin filtrarlo, **1.897 avisos
  rojos en 30 días**, uno por cobro. Se agregó la lista `_espejosLocales`. Y se saltean los PATCH
  vacíos (`ignoreEmptyUpdates` viene en `false` y el schema no lo activa).
  **AUDIT** (5 ejes + un refutador por finding, 34 agentes): el eje del connector abrió con "no se
  puede mergear como está" y tenía razón. Confirmó limpio: las 38 tablas que sube el connector tienen
  columna `id` (la única sin ella, `super_admin_impersonation`, se escribe directo por Supabase, no por
  la cola); el `DROP TRIGGER` de 0224 no se llevó ninguno de los otros 6 de `pagos`; el refactor a
  `_registrarRechazo` no perdió información. Riesgo anotado, NO introducido por este diff: el aviso
  persistente vive en Mi perfil y **11 de 21 usuarios no tienen ruta a esa pantalla**.
  **TEST TENANT LIMPIO** (`8583a8f0-…`) para las pruebas: 0 clientes, 0 contratos, 0 cuotas, 0 pagos,
  0 recibos, 0 tickets, 0 mora, 0 op_log, y `recibo_correlativos` reseteado. **Se conservaron** los 5
  usuarios, 8 planes, 8 comunidades y 89 settings. Hecho con simulacro previo (ROLLBACK), orden
  hijo-a-padre por las 3 FK `NO ACTION` (`cuotas→clientes`, `pagos→cuotas`,
  `notificaciones_mora→clientes`), `WHERE tenant_id` en cada sentencia y verificación de que los otros
  tenants quedaron idénticos (6.077 clientes / 29.109 pagos, mismo conteo). Efecto lateral: **INV17
  pasó de 2 a 0** — esas 2 violaciones eran del tenant de prueba. Queda solo INV19=74.
  Se perdió el caso semilla de cuarentena (Ana Lucía SEED03), único pago `en_revision` de la base; se
  puede re-sembrar si se quiere probar el flujo en la app.
  `analyze` en los 4 info preexistentes, **603 tests**. **v0.31.26+249, PUBLICADA** (release único
  vigente en `sitecsa-updates`, los dos tenants).

- **(2026-08-08/09) — v0.31.25: "la matemática del Resumen no cuadra" + auditoría de roles.**
  **EL RECLAMO.** El dueño de Telecable Mairena sumó `Cobros › Recuperado` (1.821.490,92) + `Mora ›
  Recuperado` (207.343,00) = 2.028.833,92 y lo comparó contra el KPI del período (2.965.968,81):
  hueco de **937.134,89**. Auditoría de 7 ejes + sintetizador + crítico adversarial, todo medido contra
  `vxxz`. **VEREDICTO: la matemática estaba BIEN, no faltaba un peso.** Dos errores que la pantalla
  INVITABA a cometer: (1) los 207.343 ya estaban DENTRO de los 1.821.490,92 — mismos 232 cobros, la
  query de Mora es la de Cobros con un `AND` de más, o sea subconjunto estricto; (2) `Recuperado` mide
  por **vencimiento de cuota** y el KPI por **fecha de pago** — dos ejes perpendiculares. La ecuación
  cierra al centavo: `Cobrado − adelantado + suspendidos + atrasos + adelantos = caja`. Y **"Antes del
  ciclo" = 171.821,92** en 211 pre-pagos (el más viejo del 12/01/2026).
  **LO QUE SE HIZO (5 commits, sin migraciones ni schema ni sync rules — solo Dart):**
  · **La mora ya no se puede sumar dos veces**: sub-filas indentadas bajo "Cobrado" (`a tiempo o en
  gracia` / `tarde`), Mora pasa a "Mora del ciclo" (`Cayó en mora`/`Recuperado tarde`/`Sigue impago`)
  con nota FIJA al pie, cada tarjeta lleva su EJE en el subtítulo, el chip dice **"Ciclo 15 jul – 14
  ago"** (pedido de Rubén: el nombre del mes solo no alcanza — "Agosto 2026" cubre servicio de JULIO en
  el 99,95% de las cuotas), lo cobrado por adelantado se muestra SIEMPRE, y la línea punteada deja de
  decir "Meta" (no existe ningún setting de meta).
  · **Tarjeta nueva "¿De qué cuotas era esta plata?"** — descompone la caja en `de este ciclo` /
  `atrasos` / `adelantos`. Los renglones CON % suman el total exacto. Expone los **989.235,93 de mora
  VIEJA recuperada** que no figuraban en ninguna pantalla.
  · **PDF "Estado de clientes": C$168.987,21 de contratos CANCELADOS se imprimían como activos**
  (`Activo = Total − Suspendido`). Ahora imprime En ruta / Fuera de ruta suspendidos / Fuera de ruta
  cancelados / Total, y la marca de fila dice `(susp.)`, `(canc.)` o las dos. `saldo_cancelado` incluye
  `'completado'` porque el CHECK todavía lo admite y la app instalada aún lo escribe.
  · **Conteos consultados, no restados**: "Falta cobrar · Usuarios" mostraba 2.406 cuando eran 2.422
  (el cliente que pagó una cuota y debe otra se restaba entero). El MONTO sigue por resta — verificado
  idéntico al saldo canónico, desvío C$0,00.
  · **Cortes de fecha al SQL** (`date('now','-6 hours')`): se calculaban en Dart UNA vez en el factory
  del StreamProvider → con el dashboard abierto al cruzar medianoche "Hoy" sumaba el día anterior, y al
  cruzar el 15 el KPI seguía en el ciclo viejo. Alcanza a los 4 providers de caja (Top cobradores
  incluido, que si no divergía del KPI ya arreglado). `_dashboardDates()` borrada.
  **AUDIT POST-IMPLEMENTACIÓN** (5 ejes + un refutador POR finding: **22 de 32 se cayeron**). Cazó una
  regresión mía: el pie nuevo del PDF metía los tres desgloses en UN `pw.Text` dentro de un `Row`, y en
  el paquete pdf un hijo no flexible recibe `maxWidth` INFINITO → no envolvía, 499pt dentro de 444pt
  útiles, se salía del recuadro. Y que el subtítulo prometía "los cuatro renglones suman" cuando la
  sub-línea de mora vieja está DENTRO de Atrasos (+33,6% si se sumaban). Descartó el riesgo grande: la
  **CTE dentro de `ps.db.watch` NO esconde las tablas** (reprodujeron `getSourceTables` de sqlite_async
  sobre el esquema real de PowerSync). Las tres expresiones de fecha se probaron en SQLite real: cruce
  de año, febrero, bisiesto, borde 05:59/06:00 UTC y "hoy es domingo".
  **ENTREGABLE AL DUEÑO:** Excel de 4 hojas (`Como leer` con el puente en fórmulas vivas, `1 Cobertura`
  4.422 contratos, `2 Caja` 3.374 pagos con su balde, `3 Adelantado` 211 pre-pagos). Los 3 controles de
  cuadre pasan. Armándolo apareció un 5º término que **ninguna pantalla muestra**: C$916,00 de un pago
  sobre contrato SUSPENDIDO — la tarjeta de Cobros los excluye, la caja no. Candidato de backlog.
  **AUDITORÍA DE ROLES Y FLUJOS (misma sesión, findings SIN aplicar)** — ver §Backlog vivo. Lo más
  grave: el trigger de `pagos` no escucha `en_revision`, así que resolver una cuarentena deja la cuota
  fantasma (0 casos hoy, fix de 1 línea); y **10 contratos se perdieron al aprobar códigos duplicados —
  8 clientes de Mairena están activos, con servicio, SIN contrato ni cuotas**.
  `analyze` limpio (4 info preexistentes), **603 tests**. **v0.31.25+248**.

- **(2026-08-08) — v0.31.24: feedback del dueño + 4 migraciones aplicadas + 3 mejoras de método.**
  **MIGRACIONES APLICADAS A PRODUCCIÓN** (una por una, verificando; invariantes ANTES == DESPUÉS, la plata no se
  movió): **0220** guards (no desactivar cliente con deuda — probado en tx revertida: bloquea con deuda, deja
  editar a los 75 actuales, permite desactivar saldados · desempaquetado jsonb de checklists · guard de re-upsert
  en `recibos_asignar_correlativo` · 4 constraints · INV19/INV20 al RPC). **0222** columnas `motivo`/`notas` en
  `solicitudes_accion` + backfill (72 en JSON = 72 en columna) + **restart de PowerSync**. **0223** cédulas
  comodín → NULL (862 filas; 0 comodines restantes). **0221 PARCIAL**: `completado`→`cancelado` (34), checklists
  normalizados, `vencimiento_mas_viejo` resincronizado (9). **PENDIENTES a propósito:** 0221(a) reactivar los 75
  clientes desactivados con deuda (espera la revisión del Excel — INV19 los marca) y 0221(b2) el CHECK sin
  `completado` (va DESPUÉS de que el release saque la opción de la UI).
  **FEEDBACK DEL DUEÑO (5 features)**: cliente+ID+contrato+plan en las solicitudes de cancelar/suspender/reactivar
  (resuelto por JOIN local → sirve también para las ya pendientes) · **código de contrato duplicado bloqueado
  ANTES de enviar** (el gestor se salteaba la validación: `_guardar` bifurcaba a solicitud antes del chequeo) y
  ahora mira contratos **Y solicitudes pendientes** · **crear contrato exige conexión** (la consulta a Supabase ES
  la prueba; timeout 12s; no se pierde lo escrito; solo ese flujo — el resto sigue offline-first) · aviso NO
  bloqueante de cédula repetida con link a la ficha (49 grupos son personas distintas que comparten cédula: por
  eso se avisa y no se bloquea) · sugerencia del siguiente número de contrato.
  **MÉTODO**: golden test del stream de Android (el guard viejo solo miraba los primeros bytes) · versión impresa
  en la prueba y la regla (mata la ambigüedad "¿es build viejo?") · reglas de AGENTS como greps del CI.
  `analyze` limpio, **603 tests**. **v0.31.24+247**.

- **(2026-08-08) — v0.31.23: cierre del checkpoint — 4 fixes que destapó la verificación de docs.**
  (1) **Las notas de la SOLICITUD pisaban las del CONTRATO** (bug de v0.31.20): `solicitarAccion` escribía
  `datos['notas']`, la MISMA clave que usa `contrato_form_screen` para las notas del contrato → al aprobar una
  creación, la justificación quedaba como notas del contrato. Ahora usa claves propias (`solicitud_motivo`/
  `solicitud_notas`) con fallback al formato de v0.31.20 para las ya creadas. (2) La **regla de ancho IMPRESA**
  mandaba a "Ajustes > Impresora", que no existe → dice **Perfil > Impresora**. (3) **Rótulos de tildes
  unificados** entre la pantalla de Bluetooth y la de Windows (mismo provider, se llamaban distinto:
  Simplificado/Acentos → **Sin tildes/Alternativo**). (4) `pubspec.yaml` genérico tenía el **branding de Telenet**
  de un build viejo → vuelve a `CRM`/`com.sitecsa.crm` (los instaladores por tenant nunca se vieron afectados: el
  script re-parchea por tenant). Docs: TESTING usa **Configuración** (el nombre real del menú) en vez de
  "Ajustes". `analyze` limpio, 597 tests. **v0.31.23+246**.

**Dónde estamos (2026-08-07):** versión **v0.31.22+245**, **PUBLICADA** (release `v0.31.22`, el único
vigente en `sitecsa-updates`, para los dos tenants) · rama **`main`, limpia** (`2cfe17f`) · producción
(`vxxz`) con migraciones aplicadas y verificadas **hasta la 0219** · sync rules del VPS Hetzner sin nada
pendiente de desplegar · `flutter analyze` limpio y **597 tests** verdes.

**Lo último que se trabajó (2026-08-04 → 08-07):**

1. **Impresión en Windows/USB — la saga de la 3nStar RPT004, cerrada en código (v0.31.14 → v0.31.22).**
   El recibo en PC salía sin margen, con la letra opaca, cortado a la derecha, sin el pie y con el logo
   empastado. **La causa de fondo apareció recién en la ronda 4, al identificar la impresora:** la
   **3nStar RPT004** (80mm, **576 dots imprimibles** sobre ~636 de papel, buffer **128 KB**) **IGNORA los
   comandos de posición** — `GS L` (margen izquierdo), `ESC $` (posición absoluta) y `FS .` (tabla de
   caracteres); y el `ESC a 2` (justificar a la derecha) lo resuelve contra el **BORDE FÍSICO** del papel,
   no contra el ancho que uno le declara. **Aprendizaje caro: tres rondas (v0.31.17-19)
   se perdieron moviendo palancas que el firmware descarta** (columnas, `spaceBetweenRows`, `GS L`,
   márgenes por comando). Lo único que funciona en esta impresora es **acomodar el contenido por CONTEO
   de caracteres/dots desde x=0**, y **MEDIR** el ancho real en vez de estimarlo. Estado final:
   - **Modo IMAGEN (default en Windows):** el margen es **padding del propio widget `ReciboTicket`** (el
     recibo se renderiza a tamaño completo — encogerlo era lo que lo dejaba chico y opaco) y
     `ReciboTicket.offsetDerechaDots` corre el cuerpo para compensar la **zona muerta física del cabezal**,
     que caía toda de un lado. El **LOGO se emite APARTE** (`rasterLogoCentrado` + `logoNativo` en los dos
     builders + `_capturarReciboPng(sinLogo:)`): viajando DENTRO de la captura lo re-binarizaba el umbral
     grueso del texto (0.62, subido a propósito para engrosar la LETRA) y le cerraba los huecos a los arcos
     finos del wifi. **Lo probó el contraste papel-a-papel del cliente:** el MISMO logo salía bien en modo
     texto —que ya lo emitía suelto con `rasterGsv0` a 0.5— y mal en imagen. Logo y cuerpo salen de los
     MISMOS getters (`_margenImpresion`/`_offsetDerechaImpresion`) para que no se separen nunca.
   - **Modo TEXTO (la garantía real de completitud):** **`filasPlanas`** — las filas "etiqueta: valor" se
     arman como texto plano rellenado con espacios, así el valor queda ubicado por conteo desde x=0 y es
     inmune a que el firmware no honre `ESC $`/`ESC a`/`GS L`; `_centroPlano` parte por palabras las líneas
     centradas (el monto en letras, 51 chars, el firmware no lo partía); la sangría sale de **ADENTRO** del
     ancho (si sumara, anularía la medición); `aplicarTamanos:false`; tildes **ascii** por default en
     Windows (con la RPT004 ignorando `FS .`, cp850 salía garabato) y `gbk` disponible como "Acentos"; el
     logo por `rasterGsv0` (con `gen.image`/`ESC *` no lo dibujaba).
   - **Avance antes del corte** (`impresoraAvanceCorteProvider`, `ESC d n`, default **6** líneas en Windows
     / 2 en Android): la cuchilla está ~1cm sobre el cabezal, así que sin ese empujón el último bloque
     queda atrapado en el hueco y el pie/slogan se pierde. **No era el buffer** — por eso el modo lento no
     lo movía.
   - **REGLA DE ANCHO** (`comandosReglaAnchoEscPos` + botón en Perfil → Impresora): imprime líneas de
     largo EXACTO rotuladas en AMBOS extremos (distingue "trunca" de "envuelve") para **medir** el ancho
     imprimible real de cualquier impresora; el número se carga en el slider "Ancho de línea", que ahora
     manda siempre (+ migración que descarta un 46-48 heredado que nunca tuvo efecto).
   - **"Impresión lenta"** (opt-in, default OFF): `comandosReciboEscPosSegmentado` +
     `WindowsRawPrinter.enviarSegmentos` dosifican el raster por bandas para el buffer de 128 KB. Es
     best-effort (el spooler de Windows puede absorber las pausas): la garantía de completitud es el modo
     texto.
   - **INVARIANTE sostenido en toda la saga: Android/Bluetooth byte-idéntico.** Todo lo nuevo entra por
     gates default-false o por el path de Windows (incluido el `suavizado` del logo en `procesarLogoTermica`,
     gateado a desktop), y lo fija el guard de byte-identidad de `recibo_escpos_test`.

2. **Solicitudes de aprobación con motivo obligatorio (v0.31.20).** Pedido del tenant: toda solicitud de
   `admin_usuarios` (suspender / cancelar / reactivar contrato) tiene que llevar un motivo escrito. Antes el
   diálogo era "¿confirmás? → Enviar" con `datos` vacío y la cola no mostraba ningún motivo (solo el de
   RECHAZO, que sí se pedía). Ahora pide **Motivo (dropdown) + Notas**, **ambos obligatorios**, los guarda
   en `solicitudes_accion.datos`, los MUESTRA en la tarjeta de la cola (Pendientes / Mis solicitudes /
   Historial) y, al **aprobar**, los pasa al evento REAL de suspensión/cancelación —en vez del genérico
   "Aprobada solicitud de…"— para que queden en el historial del contrato. Fallback para las solicitudes
   viejas sin motivo. Client-only: la columna `datos` jsonb ya existía, no toca base/sync/Android.

3. **INV11 dejaba un falso positivo permanente (0219, server-side, aplicada a prod).** El RPC
   `super_admin_verificar_invariantes` reintegra al conteo las cuotas anuladas con
   `motivo_anulacion = 'Suspensión temporal'`, pero ese literal había quedado con la **ó corrupta**
   (mojibake, de re-crear la función por string-replace en 0218 bajo una sesión con el encoding
   equivocado) → nunca matcheaba → **todo contrato fijo suspendido-y-reactivado figuraba como violación**
   (caso Martha Lorena Ramos Cueva, Mairena: 11 cuotas vivas + 1 anulada, de 12). La DATA siempre estuvo
   bien; mentía el chequeo. **Lección de migraciones:** re-crear una función por string-replace puede
   corromper los acentos — verificar el literal **por contenido**, no que la función exista.

4. **Guía de testing de tickets/inventario:** `GUIA-TESTING-Tickets-Inventario.md` (+ `.pdf`) para correr
   el paquete de v0.29.0 cuando se habiliten los módulos en Test Tenant.

**⏳ EN VERIFICACIÓN — esperando las fotos del cliente (es lo único que frena el cierre de la saga):**
tres pruebas sobre la RPT004 real, con la v0.31.22 instalada:
- (a) **logo en modo imagen** — que los arcos del wifi salgan abiertos, como ya salen en modo texto;
- (b) **texto completo** — que no corte a la derecha ni se coma el pie/slogan;
- (c) **calibrar el ancho** — imprimir la **regla** desde Perfil → Impresora (modo Texto nativo), ver hasta qué número llega
  sin truncar y cargar ese valor en el slider "Ancho de línea".
Hasta que lleguen las fotos, **no tocar el módulo de impresión**: mover palancas sin dato de la impresora
real es exactamente lo que costó las 3 rondas perdidas.

**🔧 Pendiente / abierto (por orden; el backlog completo está al final del archivo):**
- **Separar la cuenta compartida "Oficina"** en un usuario por persona (operativo, sin código). Es la causa
  raíz de los cobros duplicados y los recibos colisionados; 0215/0216/0218 contienen el daño, no la causa.
- **Sacar `cobradores.dashboard_pin` de los buckets** de sync recién cuando no queden v0.27.0 en campo (esa
  versión lo lee y sin él su Resumen pide "Configurá tu PIN" en loop).
- **Tickets/inventario sin estrenar en producción:** Mairena y Telenet no tienen los módulos habilitados.
  Falta que Rubén los prenda en Test Tenant, cree los usuarios de prueba (los roles de tickets solo
  aparecen en el selector con el módulo YA habilitado) y corra la guía; recién después se decide si se
  prende `tickets.auto_cierre_dias` (hoy 0 = apagado en los 4 tenants).
- **Traspaso al nuevo dueño:** `UPDATE_REPO` ya sale de `.env.json` (canal de auto-update configurable),
  pero nunca se probó contra un canal real (memoria `traspaso-handoff-app`).
- **`analysis_options.yaml` no existe** (verificado): los lints del proyecto nunca corrieron.

---

## 📜 Historial del bloque de estado (sesiones anteriores)

### El rework del Resumen — el detalle de las 7 sesiones del 2026-09-01

> Consolidadas arriba en un solo checkpoint. Se conservan enteras porque
> cada una guarda el POR QUÉ de una decisión y el bug que la trajo.

- **👉 NUEVO (2026-09-01 g, ÚLTIMO) — los dos ejes del tiempo, y los Excel
  con contexto para un principiante.**
  · **EL CASO QUE LO TRAJO:** el dueño abrió el ciclo de septiembre, pasó el
    mouse por el **16 de agosto** y el globo dijo *"Sin cobros este día"*. Ese
    día habían entrado **C$1.000**: dos cuotas que vencían el 10 y el 14 de
    agosto (PB-16 y PB-06), cobradas dentro de la ventana de septiembre.
  · **NO ERA UN ERROR DE CUENTA.** El Resumen mide el tiempo de **DOS maneras**
    y ninguna pantalla lo decía: **Cobertura y Mora** cuentan por el
    **VENCIMIENTO** de la cuota (qué se facturó en el ciclo); **Caja y Quién
    cobró** por la **FECHA DE PAGO** (qué plata entró por la ventanilla). Por
    eso el mismo dinero está en Cobertura de agosto y en Caja de septiembre, y
    no aparece en Cobertura de septiembre. **Los tres números eran correctos.**
  · **Medido, y no es un caso raro:** en Mairena, **15 de los 31 días** del
    ciclo tienen cobros de otros ciclos — **1.337 cuotas, C$1.159.734**. Por eso
    se DESCARTÓ marcar día por día en la gráfica: media curva marcada es ruido,
    no referencia.
  · **Lo que se hizo (opción A, elegida por el dueño):** el globo pasa a decir
    *"Sin cobros de ESTE CICLO"* y suma un renglón *"de otros ciclos"* los días
    que hubo. **La curva NO se toca** — esa plata no pertenece al ciclo, y el
    renglón existe para que el globo deje de afirmar algo falso, no para
    cambiar un total. Test que fija el límite: lo de otros ciclos y lo del
    ciclo **parten** toda la plata de la ventana, así que no puede contarse dos
    veces.
  · **LOS EXCEL, con el criterio que pidió el dueño** (*"contexto suficiente
    para entender todo en 1 solo vistazo… manteniendo los detalles de todas las
    cuotas para que sea 100% trackeable"*): para entender una fila sin saber
    nada del sistema hacen falta **de quién, qué cuota (de qué mes), cuándo,
    cuánto** y un **identificador**.
    · **Cobertura** → `Recibo`, `Fecha de cobro` (era "Último pago") y
      `Ciclo del cobro` con nombre y rango: *"Septiembre 2026 (15 ago – 14
      sep)"*.
    · **Quién cobró** (el peor) → `Recibo`, `Vence`, `Ciclo de la cuota`.
    · **Mora por zona** y **Proyección** → `Ciclo de la cuota`, `Estado`.
  · **"Último pago" → "Fecha de cobro".** El dueño preguntó qué significaba. El
    nombre venía de que una cuota PUEDE recibir varios abonos; medido: de
    **32.609 cuotas cobradas** en los tres tenants, **ninguna** tiene más de
    uno. Siempre fue la fecha de cobro.
  · **🔴 LA COLUMNA "COBRADOR" SIGNIFICABA DOS COSAS.** En Mora por zona y
    Proyección es el **ASIGNADO** (`cuotas.cobrador_id`, organizativo); en Quién
    cobró es **QUIEN REGISTRÓ** el pago (`pagos.cobrador_id`). Es un invariante
    del proyecto —reasignar un cliente no cambia quién cobró en el pasado— y el
    Excel lo perdía bajo un mismo encabezado, invitando a sumarlas. Ahora son
    **"Cobrador asignado"** y **"Cobró"**.
  · **🔴 VALIDACIÓN NUEVA `LibroExcel.desparejas()` — y encontró un bug MÍO
    en el acto:** las filas de cierre se arman a mano con un `''` por columna, y
    al agregar `Recibo` y `Ciclo del cobro` el TOTAL de Cobertura quedó con
    **13 celdas para 15 columnas** — el total corrido dos casillas, en silencio.
    **No lo caza `analyze`** (las filas son `List<Object?>` y aceptan cualquier
    largo) **ni ningún test de datos**: el archivo se genera igual y se abre
    igual. Salta como `assert` en debug; en release no está, porque un subtotal
    corrido no es motivo para dejar a nadie sin su Excel.
  · **🔴 EL ESCENARIO NO TENÍA RECIBOS.** El test encontró la columna nueva
    vacía: 245 pagos y **CERO** recibos, contra el **100%** de producción. Un
    escenario que no se parece a producción no prueba lo que uno cree. Sembrados
    en los **DOS** generadores —Dart y SQL, 242 cada uno— porque ya divergieron
    tres veces.
  · **784 tests en verde** (la suite COMPLETA del repo, no sólo dashboard).
    Commits `ed2d2369`, `16a311a5`.

- **👉 NUEVO (2026-09-01 f, ÚLTIMO) — las cifras de "Estado actual" vuelven a
  formar UNA columna.**
  · **REPORTE DEL DUEÑO con capturas:** *"no está bien alineada la información,
    como que el formato visual no tiene boundaries y se va out of bounds…
    ¿podemos revisar que el UI y UX sea muy bien responsive?"*. **Medido ANTES
    de tocar nada:** a 1900px las cifras terminaban en **SIETE bordes derechos
    distintos**.
  · **LA CAUSA NO ES OBVIA, y conviene tenerla escrita.** Cada fila tenía en el
    MISMO `Row` un **`Flexible`** (el hint) y un **`Expanded`** (la cifra). Los
    dos son flex y **se reparten el espacio libre en partes iguales**; el
    `Flexible` es *loose*, así que usa sólo lo que su texto necesita y **el
    resto de su parte queda como hueco**, que el `Expanded` nunca ve. La cifra
    termina donde termina su fracción — un lugar distinto por fila, según cuán
    largo sea el hint. **La prueba estaba a la vista:** "Clientes activos" era la
    única fila SIN hint y la única cuya cifra llegaba al borde.
  · **LA FORMA CORRECTA: UN SOLO `Expanded`, y que sea el de la IZQUIERDA.**
    Absorbe todo el sobrante; la cifra va sin flex, con su ancho natural, o sea
    pegada al borde derecho. **1 solo borde** a 360, 800 y 1900px.
  · **Los CUATRO armadores de fila se unificaron en uno** (`_Fila`). Que cada
    uno tuviera su propio `Row` ERA la razón de que no formaran columna: cuatro
    implementaciones de lo mismo se alinean de cuatro maneras.
  · **Responsive de verdad:** en teléfono la fila **apila** (rótulo arriba,
    cifra abajo a la derecha) en vez de espichar el hint a dos letras y escalar
    la cifra hasta que no se lee.
  · **🔴 Y un overflow que apareció con el arreglo:** el rótulo no tenía
    `Flexible`, así que uno largo sin hint —"de eso, de contratos
    suspendidos"— rompía el `Row` a 360px **por 128px**. Un rótulo no puede
    romper el layout: si no entra, se trunca.
  · **TEST NUEVO `alineacion_test.dart`:** mide los bordes derechos de todas
    las cifras a **360 / 800 / 1900px** y exige que sean UNO. Esto **no lo caza
    `flutter analyze` ni ningún test de datos**: no hay excepción, el widget se
    dibuja, y sólo se nota mirando a un ancho concreto — el de la PC del dueño,
    que no es el que usaba ningún otro test.
  · **El globo NO tenía este problema** y se verificó: sus tres renglones tienen
    la misma estructura, así que el hueco es idéntico en los tres y las columnas
    coinciden igual.
  · **104 tests de dashboard en verde.** Commits `ebb2b4dc`, `83139025`.
    Build de prueba: **CRM TEST 0.38.4**.

- **👉 NUEVO (2026-09-01 e, ÚLTIMO) — el globo parte el día en sus dos
  mitades, y un overflow viejo que salió a la luz.**
  · **EL PROBLEMA NO ERA EL TEXTO, ERA QUE NO SE VEÍA LA SUMA.** Con "Cuotas
    cobradas 4" en grande y un renglón suelto de mora, había que DEDUCIR que
    las otras 3 entraron en fecha. Rubén: *"no me termina de convencer… cómo se
    complementan con las cuotas normales"*.
  · **Ahora son TRES RENGLONES QUE SUMAN**, con la misma forma que la tabla de
    arriba de la tarjeta: `a tiempo 3 · C$1.600` / `venían de mora 1 · C$500` /
    `cobradas 4 · C$2.100`, en columnas alineadas. Elegido de **cuatro
    propuestas** (mini tabla / número grande + barra / chips / lo de hoy más su
    contraparte). El trade-off que se aceptó: se pierde el número grande de
    "Cuotas cobradas", que había sido un pedido anterior del mismo dueño — ahora
    el total es la fila de cierre.
  · **LA MITAD "A TIEMPO" SALE DE RESTAR, sin consulta nueva.** La mora es un
    subconjunto ESTRICTO del mismo universo (los mismos pagos del día, con una
    condición más), así que `total − mora` es exactamente lo que entró en fecha.
    Verificado contra producción: 4 = 3 + 1 y C$2.100 = 1.600 + 500.
    Un día sin mora **no se parte**: una suma de un solo sumando es ruido.
  · **🔴 OVERFLOW PREEXISTENTE, destapado por el test nuevo:** `_tooltipRow`
    tenía los dos textos pelados con `mainAxisSize.min`, o sea que el `Row`
    pedía su ancho INTRÍNSECO y rebalsaba la caja de 250px del globo (33px y
    229px, medidos). Ya había pasado —el comentario del código cuenta que la caja
    se agrandó de 200 a 250 por *"Después del ciclo 2 cuotas · C$1.000,00"*— y
    **agrandar la caja sólo corre el límite**: el renglón siguiente que sea un
    poco más largo vuelve a rebalsar. Ahora los dos van en `Flexible` con
    ellipsis y el rótulo se encoge primero.
  · **EL TEST QUE FALTABA:** hasta ahora sólo estaba probado que el globo **NO**
    aparece sin hover — la mitad barata: un globo que directamente no se dibuja
    pasaba los dos tests de "no aparece" y nadie lo cazaba. El nuevo TOCA todos
    los días del ciclo hasta encontrar uno con mora y ahí verifica las tres filas
    juntas. Los días 0 y último son los únicos que muestran "antes/después del
    ciclo", que eran justo los que desbordaban.
  · **Dos vueltas para encontrar el lienzo del gráfico en el test:** buscarlo
    como "el `CustomPaint` más ancho" daba un fondo de **1200×2400** —hay 9 en la
    pantalla— y los taps caían en el medio de la nada, con el test fallando por
    la razón equivocada. Se identifica por su ALTO: 180px, el `chartHeight`.
  · **101 tests de dashboard en verde.** Commits `454a02e2`, `62656b86`.
    Build de prueba: **CRM TEST 0.38.3**.

- **👉 NUEVO (2026-09-01 d, ÚLTIMO) — la mora se reparte ADENTRO de la
  jerarquía, y el renglón del globo se muda a su lugar.**
  · **LOS MOMENTOS SON LA JERARQUÍA PRINCIPAL** (pedido de Rubén): la mora deja
    de ser una fila hermana y se desglosa dentro de *antes / en / después del
    ciclo*. Lo mismo en "Por recuperar", dentro de sus dos líneas (*con abono
    parcial* / *sin ningún pago*).
  · **LA FILA CAMBIA DE LUGAR, NO DE NÚMERO.** El monto sigue siendo el
    facturado de esas cuotas (`cm_f`), o sea lo mismo que mostraba la fila
    única. Dos tests nuevos verifican que las partes SUMAN el total que
    reemplazaron — en cuotas y en córdobas, en los dos lados.
  · **Y SE VE ALGO QUE LA FILA ÚNICA TAPABA:** en el escenario, las 2 cuotas de
    *"después del ciclo"* **NO** estuvieron en mora — pagaron pasado el 14 pero
    dentro de la gracia de su propia cuota. Ahora ese momento no dibuja renglón
    rojo, y **esa ausencia es el dato**. "Después del ciclo" y "en mora" no son
    lo mismo y hasta hoy no había forma de notarlo.
  · **🔴 DOS COSAS DEL CÓDIGO VIEJO, encontradas al mudarlo:**
    la fila hermana se dibujaba con `recuperadoCuotas > 0` —"hay algo
    recuperado"— y no con "hay mora", así que en un ciclo limpio mostraba
    **"venían de mora 0"**; y el argumento que yo mismo había escrito para
    ponerla ahí —*"anidarla pediría un CUARTO nivel"*— era **falso**: `fila3` ya
    dibuja tres y la mora entra como hermana de "con abono parcial", no debajo.
    **Un comentario que justifica una decisión de diseño también envejece.**
  · **EL GLOBO:** el renglón de mora sube ARRIBA del divisor y pasa a decir
    *"▲ de esas, N venía(n) de mora"*. Estaba abajo, junto al **Acumulado** —que
    es del PERÍODO— y por eso se leía como un tercer total en vez de como parte
    de las cuotas del día. Lo reportó Rubén: *"no está a como me habías
    presentado en el mockup"*. No era el texto: era el LUGAR.
  · **EL CRUCE QUE PIDIÓ, con test:** lo que el globo suma día a día tiene que
    dar la fila de la tabla. Hoy no divergen —medido contra producción:
    **13.507 cuotas con pago tardío** en los 3 tenants, historia completa, y
    **CERO** sin saldar— pero podrían: la curva cuenta toda cuota con pago
    tardío y la tabla sólo las que además quedaron SALDADAS. El test lo caza en
    CI antes que Rubén en pantalla.
  · **🔴 UN TEST MÍO QUE PASABA CON `0 = 0`:** el de "la mora por momento suma"
    había quedado DESPUÉS del test que reescribe las `fecha_pago` del escenario
    —los tests del archivo comparten UNA base (`setUpAll`) y ese no la
    restaura—, así que para cuando corría no quedaba una sola cuota en mora.
    Movido arriba y con `expect(cm_c, greaterThan(0))` adelante.
  · **SE PERDIERON** las filas *"se cobraron a tiempo"* y *"todavía en plazo"*:
    eran el complemento de la mora sobre su fila madre y ahora se leen restando
    (26 − 7 = 19). Con la mora repartida, replicarlas eran cuatro renglones para
    decir dos restas. Cómo volver: una fila `nivel2` más por momento con
    `d.saldadas - d.mora`.
  · **La mora del momento pide DOS clics** (abrir Recuperado, abrir el momento),
    donde antes pedía uno. Es el precio de que los momentos manden.
  · **100 tests de dashboard en verde.** Commits `afc948f4`, `0812bb94`.
    Build de prueba: **CRM TEST 0.38.2**.

- **👉 NUEVO (2026-09-01 c, ÚLTIMO) — separación clara entre tarjetas del
  Resumen, y un NaN que apareció de paso.**
  · **EL PROBLEMA ERA MEDIBLE, no una impresión:** la tarjeta es blanco puro
    (`#FFFFFF`) sobre un fondo de página `#FAFAFC` —**0,4% de diferencia**— con
    un filete de 0,5px en `#E5E5EA` que a escala normal casi no se ve, y 16px
    iguales entre las siete. Se leían como una sola masa continua. Pedido de
    Rubén: *"que se vea una separación clara entre cada gráfico"*.
  · **Elegido de tres opciones con mockup: borde de 1px `#D1D1D6` + aire de 16
    a 28.** Se descartó oscurecer el FONDO del Resumen a `#F2F2F7` (más
    efectivo, pero dejaba esta pantalla de otro color que el resto de la app) y
    se descartó tocar el `cardTheme` GLOBAL, que le cambiaría el borde a toda
    `Card` de la app — clientes, contratos, tickets. El override vive en un
    `Theme` que envuelve SOLO el Resumen; los diálogos y las hojas del (i) están
    en el overlay (otro subtree) y conservan el borde del tema.
  · **NO era lo que se había propuesto primero.** La primera propuesta fue
    agrupar en tres bloques temáticos con encabezado-pregunta y renombrar tres
    tarjetas; Rubén la bajó: *"no necesito que sea por bloques"*. Queda anotado
    porque la idea vuelve sola cada vez que alguien mira el Resumen largo: **lo
    que pedía era separación VISUAL, no jerarquía.**
  · **🔴 EL TEST DESTAPÓ UN NaN EN COBERTURA.** El grupo nuevo monta el Resumen
    con la base **VACÍA** —y resultó ser un caso que nadie probaba—: sin meta,
    sin cobros y sin mora, `yMax` da 0, `yOf` divide por cero y `drawCircle`
    recibe un `Offset` NaN. En debug es un assert que tumba el frame; en release
    el assert no está y el dibujo queda indefinido. **Es el tenant recién creado
    y el device ANTES del primer sync**, o sea la primera pantalla que ve
    alguien nuevo. Guard: `if (!(yMax > 0)) return;` después de la grilla (que no
    usa `yOf`) y después de la punteada de meta (guardada por `meta > 0`, que ya
    implica `yMax > 0`). El comentario del test avisa que sembrar datos ahí
    dejaría de probar el caso.
  · **El test mira el `Material`, no la `Card`:** `Card.shape` es **null** —la
    forma la resuelve el tema al construir—, así que la primera versión del test
    habría dado null con el override puesto Y sin ponerlo. Y el hueco se mide
    entre los RECTÁNGULOS pintados, no leyendo el `SizedBox`: si alguien mete un
    widget en el medio, el `SizedBox` sigue diciendo 28 y lo que se ve es otra
    cosa.
  · **BUILD DE PRUEBA INSTALADO:** `CRM TEST` **0.38.1**, identidad
    `com.sitecsa.crm.test` — paquete APARTE del Mairena 0.37.1, con su propia
    sesión y su propia base local. Se lanza con
    `shell:AppsFolder\com.sitecsa.crm.test_fxkeb4dgdm144!ispbilling`.
    **Cada build de prueba sube el patch**: `Add-AppxPackage` rechaza un MSIX de
    la misma versión que el instalado y el uninstall+reinstall a veces limpia el
    token. Dos tropiezos anotados: el `msix` de esta máquina (3.16.13) pide
    `--build-windows false`, **no** `--no-build-windows` (`build-release.ps1` lo
    detecta en runtime; el script de prueba lo tenía hardcodeado mal), y al morir
    ahí el script dejó `sc-release` en detached con el branding aplicado —
    restaurado a `release/v0.37.1` con su identidad `com.sitecsa.crm`.
  · **96 tests de dashboard en verde.** Commits `68b3b427`, `681cf133`.

- **👉 NUEVO (2026-09-01 b, ÚLTIMO) — "Estado actual" vuelve al Resumen y se
  COME a "Distribución de cuotas".**
  · **ERAN LA MISMA PARTICIÓN CONTADA DOS VECES.** `Cuotas por cobrar` de una
    es EXACTAMENTE `al día + en gracia + vencidas` de la otra, y "En mora" salía
    repetido en las dos con el mismo número. Verificado contra producción ANTES
    de fusionar (Mairena): `20.217 + 797 + 2.596 = 23.610` cuotas y
    `18.910.031 + 692.255 + 2.018.102 = 21.620.388` C$, al peso.
  · **Lo que se gana no es una tarjeta menos: es la PLATA de cada parte.**
    "Distribución" contaba cuotas y nada más, y un conteo sin monto no dice si
    2.596 vencidas son C$20.000 o C$2.000.000. Ahora cada parte trae cuotas,
    córdobas y % — y ese % **se calcula solo**: vivía escrito A MANO en el texto
    del (i) ("al 26/08/2026, 4 de cada 5 córdobas todavía no vencieron"), o sea
    congelado el día que alguien lo escribió.
  · **La consulta pasó a `dashboard_query.dart` y de SEIS subconsultas escalares
    a UNA pasada.** No es performance: es que el test corra la consulta REAL y
    que la partición se LEA en el SQL en vez de haber que creerla.
  · **Bug de fecha que venía de antes:** el provider no miraba
    `diaNicaraguaProvider`. `date('now','-6 hours')` vive dentro del SQL y
    `db.watch` sólo re-ejecuta cuando cambia una TABLA, así que a las 00:01
    clasificaba con el día de ayer hasta que alguien cobrara algo. Con un solo
    bucket dependiente de la fecha casi no se veía; con tres, una cuota que
    venció anoche se quedaba en "Al día" a la vista de todos.
  · **🔴 Y APARECIÓ OTRO, verificando éste: la pantalla de orden de tarjetas
    nunca guardó nada.** `escribirOrdenTarjetas` ya devuelve JSON y
    `settingsRepo.update` lo vuelve a codificar → en la base quedaba
    `"[{\"id\":..}]"`, un string JSON en vez de un array. Al leerlo,
    `jsonDecode` devuelve un String, no una List, y `leerOrdenTarjetas` cae al
    orden por defecto. Reordenás, dice "guardado", y el Resumen sigue igual, en
    silencio. Arreglado de los DOS lados: la pantalla manda la lista cruda
    (`ordenTarjetasCrudo`) y el lector acepta las dos formas, porque los valores
    viejos siguen en la base. **De los tres tenants el único con la forma rota
    es el Test Tenant — el único donde alguien usó la pantalla.**
  · **El test de la migración también se destrabó de `0263`:** leía un archivo
    hardcodeado, así que al cambiar el default en una migración nueva habría
    comparado contra la vieja y dado VERDE con los dos lados separados — justo
    lo que ese test existe para impedir. Ahora busca la última que define el
    seed.
  · **`0266` ESCRITA Y SIN CORRER, a propósito.** Enciende `operativo` para los
    tenants que ya tienen ajuste guardado, y la app instalada hoy (v0.37.1)
    tiene el Resumen VIEJO: correrla ahora le haría aparecer la grilla de KPIs
    vieja a Mairena y a Telenet, que no la pidieron. **Va con el release del
    Resumen nuevo.** Para probar, el **Test Tenant se encendió a mano**
    (verificado: Mairena `false`, Telenet `false`, Test Tenant `true`, 11
    tarjetas cada uno — ninguna se perdió).
  · **Lo que va a mostrar en el Test Tenant:** Por cobrar 273 cuotas ·
    C$191.385 → al día 213 · C$149.800 (78%) · en gracia 8 · C$5.400 (3%) · en
    mora 52 · C$36.185 (19%); de eso, 2 con abono que no alcanzó. Al pie: 58
    clientes activos y 241 cuotas ya pagadas.
  · **`distribucion` NO se borró:** sigue en el catálogo, apagada, para quien
    quiera los conteos sueltos.
  · **97 tests de dashboard en verde**, 0 rojos. Nuevos: `estado_actual_test`
    (la partición cierra en cuotas Y en córdobas; el escenario ejercita las tres
    situaciones — sin eso el primero pasaría con todo en cero),
    `estado_actual_ui_test` (llega a la pantalla y entra a 360 px) y dos de la
    doble codificación. Commits `f63c49b7`.
  · **FALTA del rework:** **Consultar período** con el estilo nuevo, y las dos
    decisiones chicas pendientes (formato compacto de Proyección, ancho de barra
    en PC maximizada).

- **👉 NUEVO (2026-09-01, ÚLTIMO) — la mora, COMPLETA en Cobertura: tabla,
  gráfica y globo.**
  · **CUATRO REFERENCIAS EN LA MISMA GRÁFICA** (Rubén lo aprobó así: *"me sirve
    tener de referencia del ciclo solo lo referente a la mora"*): la verde llena
    (Recuperado) con su punteada (Facturado del ciclo = el 100%), y la **roja
    llena** (Recuperado de mora) con su **punteada roja** (Cayó en mora = el
    techo de la roja).
  · **LA ROJA VA SIN RELLENO Y ENCIMA DE LA VERDE.** Es un SUBCONJUNTO —los
    mismos cobros con una condición más: entraron pasada la gracia—, así que dos
    áreas pintadas una sobre otra se leerían como una suma, y no se suman. Encima
    porque es la de adentro: debajo, la verde la tapa donde se tocan.
  · **CIERRA EXACTO CONTRA LA TARJETA DE MORA, verificado en producción:** la
    roja termina en C$513.827 y eso es lo que la tarjeta de Mora llama
    "Recuperado" en el ciclo en curso de Mairena. Y no es el número de hoy: se
    compararon las DOS fórmulas (`serieMoraDiaria` cruda vs `cobrado_tarde`
    clampeado a lo útil) sobre los 3 tenants, historia completa → **0 cuotas
    difieren**. Dónde SI podrían: un sobrepago hecho tarde levanta la curva y no
    la punteada — el MISMO caso que la verde ya tenía con su meta, y que el eje
    ya contempla (`math.max`). Queda escrito en el código para que no se
    re-litigue.
  · **La leyenda roja SOLO si el ciclo tuvo atraso** y el renglón
    "▲ Venían de mora" del globo **solo los días que hubo**: un ciclo limpio no
    carga con la referencia de una curva que no está dibujada.
  · **SIN CONSULTA NUEVA:** `serieMoraDiaria` existía desde antes, guardada con
    sus tests el 2026-08-13 *"para cuando se re-evalúe la mora"*. Estaba
    desenchufada, nada más.
  · **`shouldRepaint` era el bug que iba a pasar desapercibido:** el stream de
    mora llega DESPUÉS del primer pintado, así que sin agregarlo ahí el canvas se
    quedaba con el frame viejo y la curva nunca aparecía — exactamente el
    "compiló y no se pinta" que ya pasó en esta tarjeta el 2026-08-11.
  · **85 tests de dashboard en verde**, 0 rojos. Dos nuevos: que la leyenda
    llega a la pantalla (un `CustomPainter` no deja texto que buscar, pero su
    leyenda sí, y sale del MISMO flag que alimenta al painter) y que las cuatro
    filas de la tabla entran a 360 px.
  · **FALTA del rework:** rehacer **Estado actual** y **Distribución de cuotas**
    con el estilo nuevo, y después **Consultar período**. Commits `e9c2ee6d`,
    `67296aad` en `feature/dashboard-mora`. Producción sigue intacta en v0.37.1.

- **(2026-08-31 e) — la mora YA SE VE en la tabla de Cobertura;
  falta la gráfica y el globo.**
  · **CUATRO LÍNEAS NUEVAS, en el nivel 2 y con su propio chevron:** bajo
    *Recuperado* → `venían de mora` + `se cobraron a tiempo`; bajo *Por
    recuperar* → `en mora` + `todavía en plazo`. Arrancan **cerradas**, como el
    resto de los desgloses.
  · **VAN COMO HERMANAS DE LOS MOMENTOS, no colgando de ellos**, y el porqué
    importa: los momentos contestan *cuándo entró la plata*; la mora contesta
    *si se pagó dentro del plazo*. Son dos cortes distintos de las mismas cuotas.
    Anidarlo pediría un CUARTO nivel —`fila3` dibuja tres— y repetiría el dato
    en cada momento.
  · **Sin consulta nueva:** usa `cortesDelCiclo`, que ya devolvía las cuatro
    categorías y ya tenía su stream abierto en la tarjeta. Los campos se
    parseaban desde el 2026-08-13 y **nadie los pintaba**.
  · **🔴 UN BUG QUE CAZÓ EL TEST DE UI, no la lectura:** el chevron de
    *Recuperado* sólo aparecía si había desglose por momentos. Sin momentos, la
    fila no se podía abrir y **las dos líneas de mora quedaban inalcanzables** —
    existían en el árbol y el usuario no podía llegar a ellas. Ahora el chevron
    mira si hay ALGO adentro: momentos **o** mora.
  · **Tests: 4 de UI** (`mora_cobertura_ui_test.dart`) que verifican que las
    líneas **llegan a la pantalla**, que **arrancan cerradas** y que entran a
    **360 px**; más los 3 de números del commit anterior. **83 verdes** en el
    dashboard, 0 rojos.
  · **LA MORA VA EN ROJO** (pedido de Rubén, 2026-09-01), y es el MISMO
    `0xFFE24B4A` que usan "Por recuperar" acá y la tarjeta de Mora entera: que
    las dos tarjetas pinten la mora igual deja reconocer de un vistazo que
    hablan de la misma plata. Estuvo en ámbar —el de "con abono parcial"— y
    quedaba como un tercer estado entre lo bueno y lo malo; la mora no es un
    matiz.
  · **FALTA para cerrar la mora en Cobertura:** las dos líneas de la GRÁFICA
    (tope de mora punteado + curva de mora recuperada — el dato ya está en
    `cortes.recuperadoTarde` y `cortes.moraFacturadoReal`) y el renglón del
    GLOBO al pasar el mouse.


> Lo que sigue son los bloques de estado de sesiones pasadas, tal como se escribieron: valen como
> **historia** (el porqué de cada fix), NO como estado de hoy. Los "⚠️ sigue ABIERTO" de julio sobre el
> **correlativo del recibo** y el **espejo que pisa `monto_pagado`** están CERRADOS por 0215/0216/0218
> (ver la entrada de abajo). Entradas más nuevas arriba; más abajo siguen las entradas largas
> `## AAAA-MM-DD` del formato viejo, y al final el **📌 Backlog vivo**.

- **(2026-08-01/02) — el "efectivo fantasma": correlativo, espejo y cuarentena (0215-0218 + v0.31.12/13).**
  Los tres bugs tenían la MISMA raíz: la cuenta COMPARTIDA "Oficina" en varios devices sin sincronizar.
  **(1) 0215 — el correlativo del recibo lo asigna el SERVER.** El device calculaba `max(correlativo)+1`
  local y dos equipos de la misma cuenta sacaban el mismo número; **no existía unique en `numero_completo`**
  (el comentario del código que decía "choca 23505 → descarta" estaba DESACTUALIZADO) → pasaban duplicados
  silenciosos. Fix: contador atómico por `(tenant, prefijo)` (`recibo_correlativos`) + trigger
  `BEFORE INSERT` que reasigna correlativo y `numero_completo` ignorando el del device + UNIQUE de red.
  Restaura "server gana" para el numerado; solo en la carrera real el nº impreso puede diferir del guardado.
  **(2) 0216 — el server es el ÚNICO autor de las columnas DERIVADAS de la cuota.** El cliente escribía
  `monto_pagado`/`cargos_neto`/`estado` (que mantienen triggers) y PowerSync subía ese UPDATE: un device con
  el snapshot viejo **pisaba** el valor recién calculado y DESINFLABA en silencio (una cuota con dos pagos
  vivos de 916 decía 916) → podía dejar como pendiente una cuota ya pagada y cobrársela de nuevo al cliente.
  Contradecía el invariante #3 ("server gana"). Fix: trigger `BEFORE UPDATE` `cuotas_forzar_derivados` que
  recalcula e ignora lo que manda el device, sin recomputar `estado` si es 'anulada' (suspensión/absorción/
  plan) ni en cuotas de cargo manual. Convierte **INV2/3/12/14 de "mantenidos" a ENFORZADOS**. De paso, 0217
  arregló el corrector 0189 (usaba `cargos_neto` sin signo).
  **(3) 0218 + v0.31.12 — CUARENTENA "cobro en revisión".** Un sobrepago NO exacto sobre una cuota queda
  `en_revision=1` y **no cuenta en NINGUNA métrica** (caja, arqueo, dashboard, fiscal, recaudado, top
  cobradores, RPCs) hasta que una persona elige en "Cobros a revisar" cuál es el verdadero y los demás se
  anulan (`pagos_repo.elegirCobroVerdadero`); el duplicado EXACTO se sigue auto-anulando (guard 0214).
  Predicado canónico `anulado=false AND en_revision=false` + VIEW `pagos_contables`; la pantalla decide por
  FLAG y ya no por `monto_pagado > total`.
  **(4) v0.31.13 — hotfix del predicado en SQLite:** `en_revision = 0` descartaba los pagos históricos con
  `NULL` en la cache local (`NULL = 0` evalúa FALSE) → "Recuperado a 0" en el dashboard. Las ~17 queries
  pasaron a `COALESCE(p.en_revision, 0) = 0` / `COALESCE(p.anulado, 0) = 0`: NULL y 0 son cobros válidos,
  solo 1 es cuarentena.
  Todo aplicado y verificado en prod (**18 invariantes en cero** tras el deploy), con los server-side
  probados en transacción revertida. Cierra los 4 findings (F1-F5) de la auditoría contable.

- **(2026-08-01) — v0.31.11: semana domingo→sábado + limpieza del gráfico.**
  Dos ajustes pedidos por Rubén en el dashboard: (1) el KPI "Esta semana" ahora cuenta la
  semana de DOMINGO a sábado (antes lunes) — el sábado a medianoche (Nicaragua) resetea a 0;
  `inicioSemana` pasó de `weekday-1` a `weekday % 7`; el subtítulo dice "desde el domingo" y el
  (i) de "Cobros del período" lo explica. (2) Se quitó la nota "Base X recuperado antes del
  ciclo" de abajo del gráfico de tendencia y el rótulo "pre-ciclo" del painter; la curva SIGUE
  arrancando elevada (cierra en el total) y el tooltip lo aclara al pasar el mouse. Solo UI/
  display, `flutter analyze` limpio. Commit ccf0d2e. Deploy v0.31.11 (ambos tenants).

- **(2026-08-01) — v0.31.9/0.31.10: el mes mostrado vuelve al MES DE SERVICIO.**
  Los dueños reportaron que a los clientes de día de pago ≤14 el mes sale "1 adelantado"
  (SE0047/Jeymi instaló 05/ene, la 1ª cuota salía "Febrero" cuando debe ser "Enero"). La app/
  reportes/recibo nombraban la cuota por el mes del PERÍODO (vencimiento) — v0.31.3. **Fix
  (confirmado por Rubén):** volver al MES DE SERVICIO anclado al **día de pago FIJO**: día 1-14
  → periodo−1 · día 15+ → periodo. Anclado al día fijo + `periodo` (estables), NUNCA al día del
  vencimiento (ese trae el corrimiento domingo→lunes que saltaba el mes: PN0190 día 14 vencía el
  15). Un solo cambio en `Fmt.mesServicio` propaga a todo. **Revierte** el mes-de-período de ayer:
  Heizell (PN0190, día 14) pasa de Junio/Julio a **Mayo/Junio** — confirmado con Rubén que Jeymi
  y Heizell son el MISMO caso (ambos ≤14) y los dos deben correrse. Solo display, no toca un
  centavo (el prorrateo ya está anclado al día). Se borraron `mesServicio*DeVencimiento`/`*Seguro`
  (código muerto que reintroducía el corrimiento). 53 tests verdes; verificado contra prod (Jeymi
  y Heizell → Ene…Jun). Commit b8aba57. Impacto Mairena: ~1990 contratos (día ≤14) corren; ~2391
  (día ≥15) no. ARQUITECTURA §3.5 actualizado.

- **(2026-08-01) — v0.31.8: botón (i) por gráfica del dashboard.**
  A pedido de Rubén (misma raíz caja-vs-cobertura que venía confundiendo). Cada una de las 10
  secciones del Resumen suma un ícono (i) en su encabezado → diálogo SCROLLABLE con Eje
  (caja/cobertura/mora/foto-de-ahora) + Opciones (navegar período, rango, switch, chips) con la
  EXPECTATIVA de cada una + Incluye + No incluye. Componente reusable `InfoGraficaBoton` +
  textos DRY en `info_grafica_textos.dart` (aprobados). Los 2 bloques de KPIs sin título (Cobros
  del período, Estado actual) estrenan mini-encabezado para colgar la (i). Antes se VERIFICÓ
  contra prod que el KPI "Hoy" (42, caja) vs curva "Del día" (16, cobertura de agosto) NO es
  descuadre: los otros 26 son cobros de hoy sobre cuotas de OTROS meses (19 de julio). Aditivo
  puro (UI, sin dinero/SQL/providers), `flutter analyze` limpio. Deploy a prod (sitecsa-updates,
  ambos tenants, manifests 200, APK CN=SITECSA DEV, v0.31.7 borrado). Commit 77131c7.
  **⚠️ Sigue ABIERTO:** correlativo por servidor + espejo que pisa `monto_pagado` (cuenta
  Oficina compartida en varios devices) — diseño aprobado, sin implementar.

- **(2026-08-01) — v0.31.7: aclarar caja vs cobertura en el selector.**
  Los dueños tomaban por descuadre que el selector "Este período" diera 1,7M y la tendencia
  "Recuperado" del mismo rango diera 1,0M. NO es descuadre: el selector (card "Consultar
  período") mide CAJA (plata por fecha de pago, = KPI Caja del período, verificado IDÉNTICO) y
  la tendencia mide COBERTURA (cobrado de lo que vence en el período). El selector NO controla
  las tendencias (tienen sus flechas). Fix: el card dice "Plata que entró por fecha de pago
  (caja)" bajo el total, y el rango por defecto se alinea con "Este período" (15→hoy, no 15→14
  del mes que viene). Toda la data del dashboard verificada precisa; era claridad, no cálculo.

- **(2026-08-01) — v0.31.6: la curva de tendencia vuelve a CERRAR en el total.**
  El fix del audit (v0.31.5) separó el "cobrado después del ciclo" (tail) en un salto punteado
  aparte → la curva terminaba en base+ventana y NO en el "Recuperado" de la tabla; el % del
  hover (53%) tampoco pegaba con el de la tabla (71%). Rubén lo cazó comparando contra la
  v0.31.4. **Fix:** el tail se pliega al ÚLTIMO punto → la curva cierra en el total y el
  Cumplimiento coincide con la tabla; el "Del día" sigue REAL (no inflado) y el tooltip del
  último día aclara "Después del ciclo: X". **Lección:** priorizar la precisión por-día por
  encima de "el final concuerda con el total" fue un error — para el usuario, que la curva
  cierre en el total de la tabla es lo NO negociable. Fix de Mora (v0.31.5) intacto.

- **(2026-08-01) — v0.31.5: 2 fixes contables del dashboard (audit).**
  Un agente auditor especialista revisó los 10 gráficos del módulo Resumen contra prod y
  encontró 2 fallas reales (7 componentes limpios). **(1) Tabla de Mora** daba Recuperado >
  Total mora y cumplimientos de hasta 1502% al navegar meses cerrados → "Total mora" pasa a
  ser el universo BRUTO (impago + recuperado tarde), así Recuperado ≤ Total SIEMPRE. **(2) La
  curva** aplastaba los pagos de fuera de la ventana en un día (tooltip inflado 5×, fecha
  falsa) → `construirSerieTendencia` (función PURA testeable) separa base pre-ciclo / ventana /
  cola post-ciclo; el total sigue == "Recuperado" de la tabla. Verificado período por período.
  595 tests. **NO tocó** los otros 8 componentes. La pasada de "claridad" (v0.31.4) se
  REVIRTIÓ antes: Rubén solo quería los selectores período, no el rediseño visual.
  **⚠️ Sigue ABIERTO:** el correlativo por servidor (diseño aprobado, sin implementar) y el
  espejo que pisa monto_pagado — misma raíz (cuenta Oficina compartida en varios devices).

- **(2026-07-31) — v0.31.4: 3 cambios de UI de los dueños.**
  (1) Dashboard: presets "Este período/Período pasado" (ciclo 15→14, `usarPeriodos` en
  `mostrarRangoFechas`; SOLO dashboard, reportes siguen con mes calendario). (2) Recuperación
  por comunidad: cada comunidad se despliega en desglose por monto con línea de verificación
  (verde si la suma cierra, ROJA si no) — `recuperacionDesgloseProvider`, verificado contra
  prod (8 comunidades top cierran). (3) `selector_fecha_rapido`: calendario que aplica AL
  TOCAR, sin OK/Cancelar, en los 5 call-sites. 589 tests.
  **⚠️ Sigue ABIERTO (v0.31.1):** el ESPEJO DEL CLIENTE PISA AL SERVIDOR (`monto_pagado` que
  sube el device puede pisar el del trigger). Desinfla en silencio. Toca el modelo de sync.

- **(2026-07-31) — v0.31.3: el mes que se MUESTRA = el mes de PERÍODO.**
  Decisión de Rubén (con el trade-off explícito y confirmado): la cuota se nombra por el mes
  en que vence/se paga, NO por el mes de servicio consumido. Un solo cambio en
  `Fmt.mesServicio` (ignora `dia_pago`, devuelve el mes del período) propaga a TODO: app,
  reportes y recibo dicen el mismo mes. Heizell (PN0190) → Junio/Julio; Aurora (EC0030) →
  Julio/Agosto. **REVIERTE** el "mes de servicio" (v0.22.5/0.22.7). SOLO display: el prorrateo
  sigue anclado al `dia_pago`, no cambia. ARQUITECTURA §3.5 actualizado. 585 tests.
  **⚠️ Sigue ABIERTO y es lo más grave (v0.31.1):** el ESPEJO DEL CLIENTE PISA AL SERVIDOR —
  `pagos_repo` sube su propio `monto_pagado` y puede pisar el que calculó el trigger. Desinfla
  en silencio. El fix toca el modelo de sync y NO entró.

- **(2026-07-31) — v0.31.1: mes de servicio en reportes + 20 recibos generados.**
  **⚠️ HALLAZGO ABIERTO, el más grave del día — el ESPEJO DEL CLIENTE PISA AL SERVIDOR.**
  Una cuota con dos pagos vivos de 916 decía `monto_pagado = 916` (sumaban 1832): C$916
  cobrados que no figuraban. `pagos_repo` hace `UPDATE cuotas SET monto_pagado` en el SQLite
  local y PowerSync SUBE esa fila — el número sale del snapshot del device, no del server. Si
  ese device no recibió todavía el pago del otro, pisa el total que el trigger acababa de
  calcular bien. **Contradice el principio "server gana" (invariante #3).** Peor que un
  duplicado: el duplicado infla y se nota, esto DESINFLA en silencio y puede dejar una cuota
  pagada como pendiente → se le cobra de nuevo al cliente. **El mecanismo sigue vivo**; el
  fix toca el modelo de sync y NO entró en este release. La cuota se recalculó por el trigger.
  **Invariantes:** INV5 → 0 (los 20 recibos faltantes generados, OF-12292..12311).
  Quedan INV4=37 (36 históricos + el caso nuevo, ya visible en Cobros a revisar) e INV17=14
  (colchón de indefinidos que pagaron por adelantado; se corrige solo al correr el cron).

- **(2026-07-31) — v0.31.0: impresión de PC arreglada de raíz.**
  Las tildes NO eran la impresora: `esc_pos_utils_plus` codifica siempre en latin1 sin mirar
  la tabla que se le pidió, así que le decíamos CP850 y le mandábamos latin1. Y el borde
  cortado era **regresión de v0.30.0** (el margen corría el recibo sin achicarlo → se salía
  del papel), que es por qué pasaba en imagen Y texto a la vez. Las dos causas estaban en la
  app, no en el hardware → salen andando al actualizar.
  **NO verificado:** que esa térmica ejecute el `ESC *` que se agregó para el modo imagen.
  Si tampoco lo entiende, ese modo no le sirve a esa máquina — falta marca/modelo.
  Entra también la pantalla **Cobros a revisar**.

- **(2026-07-31) — Guard de sobrepago vivo en producción (0214, 55bf60e).**
  El server ya no acepta en silencio un cobro que deja la cuota sobre su total: si es copia
  exacta de uno existente lo **anula solo**; si excede pero es distinto, entra y queda para que
  lo mire una persona. Probado con 10 casos contra prod en transacción revertida.
  **Lo que sigue abierto:** INV4 marca **36** (los históricos del 26/07, congelados, esperan
  cotejo con talonarios) e INV5 marca **6** (pagos de Oficina del 30/07 sin recibo, sin
  diagnosticar). El resto de los invariantes, en cero. Falta la pantalla "Cobros a revisar" y
  entender por qué el historial de cobros no se ve (la data ESTÁ: `op_log` graba los 72 pagos).

- **(2026-07-29) — v0.29.8: la REGLA de qué aprueba el admin_usuarios.**
  Rubén la fijó explícitamente: **lo que toca CONTRATO necesita aprobación; lo que es del
  CLIENTE/usuario lo maneja el admin_usuarios directo.** Esa es la línea, no el rol.
  **CAMBIO (ee66d36):** desactivar cliente pasó a DIRECTO (se quitó "Solicitar desactivación").
  Junto con la 0.29.7 (reactivar directo), el estado del cliente queda 100% en manos del rol.
  **NO saltea la regla de negocio:** el guardado bloquea desactivar un cliente con contratos
  ACTIVOS (hay que suspender/cancelar primero, que es lo que frena las cuotas). Ese guard vive
  en el FORM, no en la cola, así que viaja con el camino directo — verificado antes de tocar.
  **Auditado que la regla queda consistente:** todo lo que sigue restringido para el rol es
  PLATA o CONTRATO (cobrar, pagar, cambio de fecha, multi-cuota, reimprimir deuda, revertir).
  Nada de cliente/usuario quedó bloqueado. Los 4 tipos de solicitud restantes son todos de
  contrato (crear/cancelar/suspender/reactivar) → el enum ya refleja la regla.
  **`TipoSolicitud.desactivarCliente` y su ejecución NO se borraron:** hay 10 solicitudes
  PENDIENTES en producción; sin la rama de ejecución quedarían irresolubles.
  **⚠️ HALLAZGO OPERATIVO (no es bug):** esas 10 pendientes son de HOY y **los 10 clientes tienen
  su contrato ACTIVO**, así que el guard las bloquea igual — con o sin aprobación. Y hay otras
  **10 pendientes de `suspender_contrato` para los contratos de ESOS MISMOS 10 clientes**
  (verificado con un join). O sea: están dando de baja 10 clientes y la cadena está frenada en
  el PASO 1 (suspender el contrato), que por la regla de arriba **sigue necesitando aprobación**.
  → **Pendiente OPERATIVO, no de código: un admin tiene que resolver esas 10 suspensiones.**
  552 tests verdes.

- **(2026-07-29) — v0.29.7: admin_usuarios no podía reactivar un cliente.**
  Reporte de campo. **NO era un permiso mal configurado: la opción no existía.** La sección
  Estado del form solo se dibujaba para ese rol con el cliente ACTIVO (para ofrecer
  "Solicitar desactivación"); con uno inactivo la sección entera desaparecía y quedaba sin salida.
  **FIX (98b1d00):** el rol queda ASIMÉTRICO a propósito (decisión de Rubén): **REACTIVAR es
  DIRECTO** —solo devuelve visibilidad (listas, mapa, cobros), no toca facturación— y
  **DESACTIVAR sigue pasando por la cola de aprobación**, que es la dirección con impacto.
  La visibilidad se decide por `_activoOriginal` y NO por `_activo`: con el valor vivo, tocar el
  interruptor cambiaba la condición y la sección se reemplazaba sola, sin poder deshacer antes
  de guardar.
  **Verificada la cadena COMPLETA antes de tocar UI** (el patrón "botón sin permiso" ya mordió
  4 veces): allowlist de rutas incluye `/admin/clientes/:id/editar` · el filtro de inactivos no
  tiene gate de rol · `puedeGestionar` incluye al rol · RLS `clientes_write_admin_usuarios` es
  FOR ALL con USING+WITH CHECK · ningún trigger bloquea `activo` (solo código-inmutable y
  propagación de cobrador) · el guardado ya emitía op_log.
  **SIN migración:** al no crear un tipo de solicitud nuevo, no se toca el CHECK de
  `solicitudes_accion.tipo` — que lista solo 5 tipos, así que agregar uno solo en Dart habría
  hecho fallar la solicitud AL SINCRONIZAR, en silencio (se verificó el CHECK por contenido).
  `admin_cobranza` queda como estaba (sin control de estado del cliente — decisión de Rubén).
  552 tests verdes. Releases: solo v0.29.7. Es gating de UI, verificado leyendo la cadena, sin
  test automático (el riesgo eran los eslabones, no la lógica booleana).

- **(2026-07-29) — v0.29.6: modo DIRECTO ESC/POS en Windows + versión por equipo.**
  Con la 0.29.5 el recibo volvió a cortarse por la DERECHA y con el texto opaco. Cuarto round:
  los 3 intentos previos calibraron la geometría contra el driver y cada uno movió el corte de
  lado. **El problema no era la geometría: era depender de una config de papel que la app NO
  puede leer.** (El "opaco" es la firma del reescalado del driver.)
  **FIX DEFINITIVO (06508fa):** `windows_raw_printer.dart` escribe el raster ESC/POS CRUDO en la
  cola de Windows (datatype RAW, vía win32 OpenPrinter/StartDocPrinter/WritePrinter) — lo mismo
  que Android hace por Bluetooth y sale perfecto. Sin escala que adivinar ni papel que suponer.
  El armado del raster se extrajo a `recibo_escpos.dart` para que los DOS transportes usen
  exactamente el mismo (15 tests fijan el contrato; uno cazó un bug real que introduje: con
  captura corrupta el decoder LANZA en vez de dar null, y el camino nuevo no lo atrapaba).
  **OPT-IN por PC** (`modoDirectoImpresoraProvider`, default OFF) + botón de prueba que usa el
  MISMO camino que después imprime + fallback automático al PDF si falla. El transporte
  Bluetooth NO se tocó (lección v0.22.10-13).
  **VERSIÓN POR EQUIPO (babd6e3):** la app declara `app_version` en `client_params` al conectar;
  el panel del VPS la muestra por dispositivo. Antes era imposible saberlo: el `user_agent` de
  PowerSync solo trae su propia versión de librería, idéntica en toda la flota. Los params NO
  los lee ninguna sync rule → no cambian buckets ni disparan re-sync.
  **PANEL DEL VPS mejorado:** sección Dispositivos (uno por `client_id`, con usuario/rol/tenant/
  plataforma/versión/bytes), registro persistente en `panel/devices.json` (antes releía 7 días de
  logs y tardaba 2m10s con cron cada 2 min → corridas pisándose; ahora hay `flock` + merge).
  **HALLAZGO:** "Oficina" (admin_cobranza Mairena) es una **cuenta COMPARTIDA con 5+ PCs
  conectadas a la vez** → 13 usuarios dan 25 instalaciones. Mirar por usuario nunca iba a servir
  para saber quién falta actualizar. Ojo: `client_id` identifica la INSTALACIÓN, no la máquina.
  552 tests verdes. **PENDIENTE: que Rubén pruebe el modo directo** (si la prueba no imprime, esa
  impresora no habla ESC/POS y hace falta el modelo) y devolver el logo de Mairena a COLOR.

- **(2026-07-29) — v0.29.5: el recibo cortaba a la IZQUIERDA (regresión mía).**
  Rubén: *"antes salía cortada a la derecha, y ahora sale cortada a la izquierda"*. El fix del
  27 corrigió un lado y rompió el otro.
  **CAUSA:** la página se hizo del ancho IMPRIMIBLE (72,07mm = 576 dots exactos). Arregló la
  nitidez, pero el driver la apoya en el borde del PAPEL, no donde arranca el cabezal → los
  primeros 3,96mm caen en zona muerta y el margen de 6pt (17 dots) no los cubría: se perdían
  **15 dots = 1,89mm = la primera letra de cada etiqueta** ("ecibo", "echa", "olector").
  **FIX (49198dd):** la página mide lo que el PAPEL (640 dots = 80,08mm — sigue ENTERO, así que
  la nitidez del fix anterior se conserva) y el contenido se mete media zona muerta (32 dots)
  de cada lado → cae exacto en los 576. **Lo importante: deja de depender de dónde apoya el
  driver**, que es la suposición que rompió los DOS intentos anteriores. Una página del tamaño
  del papel no se puede correr.
  **LOGO TRAMADO (2º síntoma de la misma foto):** el PDF lleva el texto VECTORIAL (sale sólido)
  y el logo RASTER (el driver le aplica trama de puntos) — por eso el texto salía nítido y el
  logo hecho un enrejado, aunque el azul sea casi negro (RGB(0,31,108) = 12% de brillo).
  NO era la compresión: verificado que ambos archivos tienen el mismo color.
  **FIX:** `data/utils/logo_monocromo.dart` pasa el logo a blanco y negro PURO al armar el
  recibo (sin grises no hay nada que tramar), con memo de 1 entrada porque corre en cada
  impresión. Sirve para cualquier tenant/logo. Los reportes a color NO se tocan.
  Además se subió el logo de Mairena ya en B/N (6.717 bytes) como alivio sin release.
  **PENDIENTE:** cuando Rubén confirme la impresión, devolver el logo a COLOR en Storage
  (la app ya lo convierte sola) para que vuelva a verse azul en pantalla y reportes.
  537 tests verdes (16 nuevos, con los de regresión de los DOS cortes). Releases: solo v0.29.5.

- **(2026-07-29) — solución DEFINITIVA de la fuga + logo comprimido.**
  Rubén cuestionó el diseño con razón: *"si la data ya está descargada localmente NO se
  necesita re-descargar a menos que haya habido un update, que para eso pago PowerSync"*.
  Tenía razón — el parche del 27 (flag en MEMORIA) dejaba dos agujeros:
  (a) se olvidaba al reiniciar → 1 descarga por arranque, para siempre;
  (b) **segunda fuga encontrada**: `logo_empresa_provider.dart:59` bajaba del bucket POR SU
  CUENTA cuando el disco estaba vacío — y corre en CADA recibo y en el header de CADA reporte.
  **FIX DEFINITIVO (a9a796b):** el archivo lleva su VERSIÓN en disco (`logo_<tenant>.ver` =
  `path|updated_at` de la fila de settings, que ya sincroniza PowerSync). Si coincide, cero
  red — para siempre, entre reinicios. El disparador deja de ser la conexión y pasa a ser el
  **cambio del dato** (`ps.db.watch` de la fila). Se versiona por `updated_at` y no por path
  porque el path es SIEMPRE `{tenant}/logo.png` (el archivo se pisa). Si hay bytes en disco se
  sirven al instante aunque la versión esté vencida: **imprimir nunca espera a la red**.
  **TERCER caso del mismo patrón, encontrado en el audit:** el worker de fotos colgado del
  mismo listener escaneaba `pagos` ENTERA (sin índice utilizable) y escribía prefs **25 veces
  por minuto** para no encontrar nada. Freno de 1 min en la función llamada + prefs solo si
  hay algo que borrar. El botón manual de perfil pasa `forzar: true`.
  **LOGO DE MAIRENA COMPRIMIDO: 580.906 → 41.034 bytes (14×).** Era 8000×4500 px (36 MP) con
  72 colores únicos, guardado como RGBA entrelazado, para imprimirse a 576 px. Verificado
  visualmente contra el original al tamaño de uso: indistinguible (dif. máx 16/255 en bordes
  antialias, 5% de píxeles). Respaldo del original en `Downloads/logo-mairena-ORIGINAL-respaldo.png`.
  Se tocó `settings.updated_at` a mano para que los equipos lo tomen.
  **Regla nueva en AUDIT-PROFUNDO §2:** auditar **FRECUENCIA, no solo corrección** —
  estado ≠ evento, el guard va en la función llamada, la versión va persistida.
  522 tests verdes, analyze limpio.
  **PUBLICADO: v0.29.4+216** (97d5088 + build-release -AllTenants). Verificado: manifests de
  ambos tenants apuntan a 0.29.4, los 4 instaladores bajan, y el APK quedó firmado con la
  llave REAL (`CN=SITECSA`, no la de debug — que habría hecho que Android rechazara la
  actualización). Sin migraciones: es puro cliente, no hubo ventana de app-nueva/base-vieja.
  **Releases limpiados** a la política del proyecto: quedó SOLO v0.29.4 (se borraron v0.28.0,
  v0.29.0-3 con `--cleanup-tag`). Seguro porque los manifests resuelven por el alias `latest`,
  nunca por una versión fija — verificado post-borrado que el auto-update sigue resolviendo.

- **(2026-07-27) — v0.29.3: fuga de 253 GB de egress por el logo.**
  Supabase marcó **Cached Egress 252,956 / 250 GB (101%)** con **Storage Size en 0**. Ese
  contraste era la pista: **2,65 MB guardados en total** (10 archivos) contra 253 GB
  servidos = más de un millón de descargas de los mismos archivitos.
  **CAUSA:** `LogoCacheService.refrescarLogo` se llama desde el listener de
  `ps.db.statusStream` en `main.dart` — que emite en CADA cambio de estado de sync, o sea
  cada pocos segundos con la app abierta — y bajaba el logo del bucket **sin fijarse si ya
  lo tenía**.
  **NÚMEROS MEDIDOS (auditoría 2026-07-29, corrigen la estimación inicial):** el logo de
  Mairena pesa **567,3 KB** (no los ~200 KB estimados) · los logs del VPS dan **766
  checkpoints en 10 min con 3 clientes = 25 eventos/min por equipo** · eso da
  **6,9 GB por equipo por día de trabajo**, y con 5-9 equipos **35-62 GB/día** — que es
  exactamente la franja del gráfico diario de Supabase (35-60).
  **Verificado que el churn de sync es LEGÍTIMO:** 17 escrituras en 45 s (cobros reales),
  no un bucle artificial. Y que **ninguna otra descarga corre en bucle**: fotos, adjuntos y
  documentos son a pedido del usuario.
  **FIX:** guard por corrida en `necesitaBajar` (función PURA, 7 tests, incluida la ráfaga
  de 500 llamadas). Se baja 1 vez por arranque o cuando cambia el path.
  A propósito **NO** se usa "hay archivo en disco" para saltear: si el admin cambia el logo
  con la app cerrada, el disco quedaría viejo para siempre. El alta de logo del admin pasa
  `forzar: true` (bytes nuevos, path que puede repetirse). La marca se pone DESPUÉS del
  éxito, así una descarga fallida se reintenta.
  **Este SÍ necesita release** (va en el código, no en el server). El contador de Supabase
  no baja: se reinicia con el ciclo de facturación. Las fotos de clientes NO eran el
  problema (5 archivos, 2 MB).
  ✅ **Impresión en PC CONFIRMADA OK por Rubén** con la v0.29.2.

- **(2026-07-27) — HOTFIX 0213: la verificación de invariantes moría por
  timeout Y mentía el conteo.** Reportado desde Operaciones de Mairena ("canceling statement
  due to statement timeout"). **CAUSA 1 — faltaba un índice:** el plan real de INV12 mostraba
  `Seq Scan on pagos (rows=19415 loops=4372)` — la tabla ENTERA de pagos escaneada una vez
  por contrato, 85M de filas, **27.417 ms** contra un `statement_timeout` de 8s. `pagos`
  tenía `(tenant_id, cuota_id)` pero las subconsultas buscan por `cuota_id` SOLO, y sin la
  primera columna del compuesto no hay búsqueda dirigida. Con `pagos_cuota_id_idx`:
  **27.417 → 173 ms (158x)**. La misma corrección acelera `super_admin_corregir_invariantes`,
  que hace el mismo lookup 2 veces por cuota (medido: 1.286 ms).
  **CAUSA 2 — el conteo topaba en 10:** cada chequeo hacía `count(*)` sobre un subselect con
  `LIMIT 10`. Medido en Mairena: **INV2 tiene 33 violaciones reales y la pantalla mostraba
  10** — y como el consejo de la UI es "corregí INV2 primero", el operador arreglaba 10,
  re-verificaba, leía 10 otra vez y concluía que no servía. Ahora `violaciones` es real y
  `ejemplo_ids` sigue trayendo 10.
  **Estado real de Mairena al 2026-07-27:** INV2 = 33 · INV12 = 7 (consecuencia de INV2) ·
  INV4 = 3 · INV14 = 0. Corregir INV2 primero.
  Cuerpo partido de `pg_get_functiondef`; único cambio: los 17 `LIMIT 10` y los 17
  agregadores recortados. **Server-side: arregla las apps instaladas sin release.**

- **(2026-07-27) — v0.29.2: impresión en PC, la causa REAL.**
  La v0.29.1 NO alcanzó. La foto del MISMO PDF impreso FUERA de la app salió completa y
  nítida → el PDF estaba bien, el problema era cómo la app se lo mandaba al driver.
  **CAUSA 1 (la de fondo):** el plugin arma el `DEVMODE` con
  `dmPaperLength = round(alto*254/72)` sobre un **`short`**, y le pasábamos
  `double.infinity` como alto (rollo continuo). Convertir infinito a entero es UB → el
  DEVMODE salía corrupto y **Windows lo descartaba entero**: la app NUNCA controló el papel.
  Por eso ni prender ni apagar "Ajustar al driver" cambiaba nada. Ahora el alto se MIDE del
  PDF (raster a 18 dpi) con fallback finito.
  **CAUSA 2:** la página medía el ancho FÍSICO (80mm) y no el IMPRIMIBLE (72,07mm). El
  plugin la dibuja a tamaño real apoyada en el borde → los ~8mm se perdían POR LA DERECHA
  (por eso la izquierda estaba intacta y el margen simétrico de v0.29.1 corrigió al revés).
  Y explica la CALIDAD: 80mm = 639,37 dots (fraccionario → cada glifo se reescala y sale
  gris); 72,07mm = 576,00 exactos → 1:1, negro nítido.
  **LA GEOMETRÍA ESTABA DUPLICADA EN 3 LUGARES.** El fix de v0.29.1 tocó uno que resulta
  que **solo usa la prueba de impresión**; el camino real de recibos (`_imprimirSistema` →
  `Printing.layoutPdf` en `recibo_screen.dart`) seguía intacto. Se detectó al verificar si
  Android estaba afectado y **se frenó el build antes de publicar**. Los 3 leen ahora
  `data/utils/papel_termica.dart`.
  ⚠️ **ANDROID NO SE TOCÓ y no puede verse afectado:** el térmico captura el widget
  `ReciboTicket` con Skia (576/384 dots) → ESC/POS. NO usa el PDF. (Un comentario viejo en
  `recibo_pdf.dart` decía lo contrario y casi cuesta un diagnóstico errado: corregido.)
  No se tocó `impresora_service_io.dart` ni el path de raster/transporte (v0.22.10-13).

- **(2026-07-27) — v0.29.1: primer intento del fix de impresión (insuficiente).**
  Reportado en producción (PC + térmica 80mm). **CAUSA:** ancho FÍSICO del rollo ≠ ancho
  IMPRIMIBLE del cabezal. En 80mm el cabezal alcanza **72mm** (576 dots @203dpi); el PDF de
  escritorio maquetaba a **74,4mm** (página de 80 menos un margen FIJO de 8pt) → se pasaba
  2,3mm y, como los valores van alineados a la derecha, se perdía el final de cada uno. En
  58mm era peor (52,4mm sobre un cabezal de 48). **Ningún toggle podía arreglarlo**: el
  contenido era más ancho que el cabezal.
  **Los dos caminos se contradecían:** el térmico YA usaba 576/384 dots correctos
  (`impresora_service_io.dart`); solo el PDF estaba mal. Ahora el margen se DERIVA de esas
  constantes (`data/utils/papel_termica.dart`) + colchón de 1pt (~0,35mm/lado) — sin él el
  contenido terminaba a 0,04mm del borde, que es coincidencia, no margen.
  ⚠️ **NO se tocó `impresora_service_io.dart` ni el path de raster/transporte** (el que
  rompió la flota en v0.22.10-13): las constantes se replican, no se importan.
  **BONUS:** la prueba de impresión daba FALSA CONFIANZA — mismo margen malo pero con texto
  corto centrado, salía bien igual. Ahora imprime una regla con flechas en ambos extremos.
  6 tests fijan la geometría. Release `v0.29.1` publicado, manifests verificados.

- **(2026-07-27) — HOTFIX 0212: el PIN del Resumen se pedía en LOOP.**
  Reportado en producción. **El PIN SÍ se guardaba** (verificado: `dashboard_pins` +
  `cobradores.dashboard_pin` correctos); lo que fallaba era el flag que la app consulta.
  **Causa:** `cobradores.dashboard_pin_configurado` era **GENERATED ALWAYS**, y **Postgres
  NO replica columnas generadas** (`publish_generated_columns` es de PG18; acá corre PG17).
  Confirmado con `pg_publication_tables`: la publicación mandaba `dashboard_pin` pero NO el
  flag → llegaba NULL a TODOS los dispositivos → el cliente lo lee con `?? 0` → false →
  "Configurá tu PIN" en cada visita, para siempre.
  **Fix (0212):** `DROP EXPRESSION` (conserva valores) + trigger que la mantiene. Al no ser
  generada, la publicación la envía. **100% server-side: arregla las apps YA INSTALADAS
  (v0.27/0.28/0.29) sin release.** Se tocaron las filas para forzar la replicación y se
  verificó en los logs del VPS que los clientes la recibieron.
  Era la ÚNICA columna generada del esquema. Regla agregada a `AUDIT-PROFUNDO.md`.

- **(2026-07-27) — v0.29.0 PUBLICADA: paquete tickets/inventario completo.**
  `main` = `9bf1935`. Las 4 fases mergeadas y releaseadas (`v0.29.0` en `sitecsa-updates`,
  4 instaladores branded). Migraciones **0204-0211** aplicadas y verificadas por contenido.
  **INERTE para Mairena y Telenet:** verificado que ninguno de los dos tiene los módulos
  `tickets`/`inventario` habilitados NI un solo ticket o serial (los 6 tickets y 4 seriales
  de la base son de Test Tenant). Se auditaron los 12 archivos tocados fuera del gate de
  módulo: el único que se filtraba era la pestaña "Por verificar" de solicitudes, corregida
  antes del release (`d7efb64`).
  **Dos audits:** el normal (4 findings) y el PROFUNDO de 4 especialistas (4 findings más,
  uno crítico: una fecha faltante tumbaba la ficha entera). Todos cerrados; queda 1 ítem de
  backlog con criterio. El proceso quedó documentado en **`AUDIT-PROFUNDO.md`**, invocable
  pidiendo "audit profundo", con entrega visual obligatoria de 4 mockups.
  **PENDIENTE:** (a) Rubén habilita los módulos en Test Tenant y crea los 4 usuarios de
  prueba — OJO: los roles de tickets solo aparecen en el selector si el módulo ya está
  habilitado; (b) correr los 16 pasos de `TESTING.md` §0.3; (c) recién después decidir si se
  prende `tickets.auto_cierre_dias` (hoy 0 = apagado en los 4 tenants) — la primera noche
  cerraría de golpe todo lo que lleve más de ese plazo en `resuelto`; (d) borrar el release
  `v0.28.0` cuando el testing pase (hoy se conserva como ÚNICO artefacto conocido-bueno).

- **(2026-07-26) — Fase 4: la orden cerrada pasa al gestor.** Branch
  `feature/tickets-inventario-nuevo-dueno`, commit `9767fdd`. **Migraciones 0209/0210
  aplicadas y verificadas POR CONTENIDO.** Al cerrarse una orden cuyo tipo tiene
  `efecto='instalacion'` (0172 — no hizo falta flag nuevo), un TRIGGER la deja en
  `verificacion_estado='pendiente'`. Es trigger y no código de la app porque una orden se
  cierra por TRES caminos y uno es el cron de auto-cierre, que corre sin ninguna app abierta.
  La bandeja "Por verificar" vive en `/admin/solicitudes` (el gestor NO tiene acceso a
  tickets y no lo necesita). **DOS BLOQUEOS encontrados antes de escribir el botón** — 3ª vez
  del mismo patrón: su bucket decía "NO baja tickets" (bandeja vacía) y `tk_write` no incluye
  `admin_usuarios` (el server le habría rechazado la escritura). **PAQUETE COMPLETO: las 4
  fases están cerradas.** Falta el testing en vivo y el merge a `main`.

- **(2026-07-26) — Fase 3 del pedido del nuevo dueño (cierre del call center).**
  Branch `feature/tickets-inventario-nuevo-dueno`, commit `14d68f8`. **Migración 0208 aplicada
  y verificada POR CONTENIDO.** El call center registra intentos de contacto (`ticket_eventos`
  con `tipo_evento='contacto'` — NO una tabla nueva: ya sincroniza, ya tiene RLS, ya sale en el
  timeline); tras N intentos (default 3) Y D días desde resuelto (default 2) se habilita
  "cerrar sin confirmar" con motivo obligatorio, marcado en `cerrado_sin_confirmar` para poder
  MEDIR cuántas se cierran a ciegas. Bandeja "Por cerrar" en la lista (solo `resuelto`).
  **LA MITAD YA EXISTÍA:** el auto-cierre por vencimiento (opción B de la decisión) está desde
  **0109** — `tickets_auto_cierre()` + cron `tickets_auto_cierre_diario` (06:30 UTC), con los
  días en el setting `tickets.auto_cierre_dias`. **Hoy está en 0 (desactivado) en los 4
  tenants** → prenderlo es decisión de configuración de Rubén, no código.
  **PENDIENTE:** Fase 4 (puente orden cerrada → gestor verifica → `admin` aprueba, montado
  sobre `solicitudes_accion` que ya existe) + testing en vivo antes de mergear a `main`.

- **(2026-07-26) — Fase 2 del pedido del nuevo dueño (el técnico + coordinador).**
  Branch `feature/tickets-inventario-nuevo-dueno` (NO en `main`: se testea antes de mergear).
  Commits `fd8d675` (retiro), `d763218` (cola), `0e7c8a2` (server coordinador), `343d928` (app).
  **Migraciones 0205/0206/0207 aplicadas y verificadas POR CONTENIDO en prod.**
  (1) **Retiro desde la orden:** el técnico devuelve lo que desinstala. NO escribe
  `inv_seriales` —no tiene RLS de UPDATE ahí, se vería OK offline y lo rechazaría el server—
  sino que inserta `ticket_materiales` con `tipo='retiro'` y el trigger lo mueve a revisión.
  (2) **Cola de una orden a la vez:** se libera con `resuelto`, NO con `cerrado` (si esperara
  al cierre, que es del call center, un cliente que no contesta paralizaría al técnico).
  `en_espera` queda fuera de la cola a propósito. Lógica pura en `cola_tecnico.dart`, 8 tests.
  (3) **Rol `coordinador`:** solo escribe `asignado_a` y `orden_cola`. Lo enforza un TRIGGER,
  no la RLS —que es row-level y no protege columnas—; vive en el shell `/admin-tickets`.
  Bucket `por_coordinador` desplegado al VPS.
  **BUG CAZADO EN LA PRUEBA (habría roto los tickets para TODOS):** el trigger del coordinador
  usaba `IF NOT is_coordinador()`; `current_user_rol()` da NULL sin usuario resuelto → en
  plpgsql `IF NOT NULL` NO se cumple → el return temprano se salteaba y bloqueaba escrituras
  legítimas de cualquier rol. Blindado con COALESCE en las dos capas.
  **PENDIENTE:** testing en vivo de todo el paquete antes de mergear a `main` y publicar.

- **(2026-07-26) — Fase 1 del pedido del nuevo dueño (inventario + geo).**
  Branch `main`, commit `397022e`. **Migración 0204 aplicada y verificada POR CONTENIDO en
  prod:** `inv_seriales.estado += 'en_revision'`, `inv_ubicaciones.tipo += 'redes'`,
  `tickets.lat/lng`. Ciclo del material: cliente/red → técnico → **revisión** → bodega si
  sirve, **descarte** si no. `descarte` es el LABEL de `baja` (el valor en DB no cambió).
  Geo de la orden con `UbicacionActual` extraído (la danza de permisos iba por su 3ª copia).
  **Sin redeploy de sync rules** (los 18 SELECT de esas tablas son `SELECT *`) y **sin bump
  de `_dbWipeVersion`** (aditivo). `flutter analyze` limpio, 491 tests verdes.
  **Dos trampas esquivadas:** (1) revisión NO deposita el equipo en una ubicación — el
  ledger es `Σdestino−Σorigen` y `darDeBajaEquipo` solo descuenta si estaba `en_stock`, así
  que habría inflado esa bodega para siempre; (2) las 4 transiciones nuevas se verificaron
  contra el guard 0118 ANTES de dar la fase por buena.
  **PENDIENTE de la fase siguiente (el técnico):** el retiro del equipo desde la orden
  **NO se puede hacer con una escritura del cliente** — el rol `tecnico` no tiene RLS de
  UPDATE sobre `inv_seriales`; hay que pasarlo por `ticket_materiales` + trigger
  server-side (patrón 0106). Se descubrió al auditar, antes de escribir el botón.

- **(2026-07-26) — Limpieza del repo + `UPDATE_REPO` a `main`.**
  Branch `main`, commit `49608d3`. Sesión de mantenimiento, sin cambios funcionales en la app.
  (1) **`UPDATE_REPO` configurable llega a `main`** (cherry-pick de `8abd57e`, la rama tenía 387
  commits de atraso): el canal de auto-update sale de `.env.json` en vez de estar hardcodeado, y el
  MISMO valor maneja dónde se publica (`build-release.ps1`) y a dónde consulta la app
  (`update_service.dart`). Backward-compatible: sin la clave, todo apunta al canal de hoy. Es el
  prerequisito para que el nuevo dueño migre el canal a su cuenta en el traspaso.
  (2) **Repo limpio:** se borraron las 2 ramas sueltas (`feature/ordenes-cobro-servicio` local+remota
  y `claude/distracted-taussig-c58c6f`) tras verificar que TODO su contenido ya estaba en `main` salvo
  ese commit; 2 worktrees muertos; 2 stashes obsoletos (BITACORA de v0.25.2 y un rebrand hardcodeado a
  Mairena, superado por el branding vía `releaseName`); 7 releases viejos de `sitecsa-updates` + el
  `v0.24.12` de `Template-TT` y sus tags (política: solo el vigente). Queda **solo v0.28.0** publicado.
  **PENDIENTE:** sin cambios respecto de la entrada anterior (ver abajo). Nota: al no quedar releases
  previos, ya no hay artefacto para rollback manual a una versión anterior.

- **(2026-07-26) — Rol `lectura`, traspaso, audit completo y fixes de dinero.**
  Branch `new-features`, ya mergeado a `main` y publicado como **v0.28.0+211** (`909f998`).
  **Publicado antes en la sesión:** v0.27.0 con PIN
  per-user + fix de reportes para admin_cobranza. **Lo demás está commiteado SIN publicar (13 commits).**
  (1) **Rol `lectura`** ("Solo lectura", 0198): ve todo el tenant incluida la plata, no modifica nada.
  3 barreras — UI sin acciones, guardia `ps.dbW` (86 escrituras) y policies solo-SELECT.
  (2) **SEGURIDAD (ya existía, cerrada en 0199):** `cobradores.password_texto` guarda contraseñas EN
  CLARO y RLS es row-level → `admin_cobranza` podía leer la de un `admin` y entrar como él. Se revocó
  el SELECT de tabla y se otorgaron las 10 columnas legítimas. Además 7 policies de escritura sin
  chequeo de rol (op_log, visitas, solicitudes, geografía) alcanzables por REST.
  (3) **Dashboard:** PIN por VISITA + re-bloqueo al pasar a segundo plano; corte del 15 unificado en
  todo el Resumen (`periodo_dashboard.dart`); Recuperación con toggle período/acumulada (default
  acumulada: "del período" da 0,87% de la mora real).
  (4) **PIN aislado (0201/0202):** se mudó a `dashboard_pins` (RLS self-only + bucket de una fila);
  nadie ve el de otro. Para ayudar: "Forzar cambio", que lo borra sin verlo.
  (5) **Recibos (causa de 34 cobros sin comprobante en Mairena):** el correlativo lo calcula el device
  y colisiona entre equipos que comparten cuenta; el connector descartaba el recibo pero el pago sí
  subía. Ahora reintenta con el próximo número. El reparador (0203) va por tandas + índice
  `recibos_pago_id_idx` (575ms → 89ms); antes era todo-o-nada contra un `statement_timeout` de 8s.
  (6) **Tope anti doble cobro** en `registrarCobro` (una cuota de C$1.282 quedó con C$2.564 pagados).
  (7) **Ranking:** "Top cobradores" y "Cobradores del mes" ya no filtran `rol='cobrador'` — ocultaban
  el 79% (Mairena) y 88% (Telenet) de la recaudación y no cerraban con el arqueo.
  (8) **Traspaso:** marca fuera de la app y 13 .md; `super_admin` se muestra como **«Dev»** (el rol
  interno NO cambió); guía de usuario sin Inventario/Tickets/Incidentes.
  **Migraciones aplicadas y verificadas en prod:** 0197-0203. **Sync rules desplegadas al VPS.**
  **PENDIENTE:** (a) separar la cuenta compartida "Oficina" en un usuario por persona — es la causa
  raíz de los recibos perdidos y no requiere código; (b) **sacar `cobradores.dashboard_pin` de los
  buckets** recién cuando no queden v0.27.0 en campo (hoy sigue por compatibilidad: esa versión lo lee
  y sin él su Resumen pide "Configurá tu PIN" en loop); (c) backlog del audit: ~10 diálogos con botón
  mudo si falta el motivo, `analysis_options.yaml` inexistente (los lints nunca corrieron),
  `invariantes_dinero.sql` satura el conteo en 10 por un LIMIT mal ubicado.

- **(2026-07-22) — Quitar referencias CRM + gráfico tendencia cobros/mora.**
  Branch `main`. (1) White-label: eliminadas TODAS las referencias a "CRM" de la app (título ventana,
  login, sidebar, shells, set-password). Solo queda la versión numérica. Commit `a6fa411`. (2) Dashboard admin:
  dos cards nuevos "Cobros del mes" y "Mora" con tabla meta/recuperado/por-recuperar, gráfico acumulado
  CustomPaint interactivo (hover PC + tap mobile), selector de mes. Audit de 3 agentes (Code+DB+UX) → 10 fixes
  aplicados: streams en initState, SQL alineado summary↔daily, filtro `!= 'suspendido'`, clamp negativos,
  tabla responsive, pctPill invertido, gate por settings existentes, error handling. Commit `b5327a0`.
  v0.25.7+206 (`9c98a00`). Build en curso.
- **(2026-07-21) — Deploy Fases 0-3 a producción + hotfixes.**
  Branch `main`. **Fases 0-3 de roles deployadas a producción:** migración 0192 (CHECK + handle_new_user +
  set_cobrador_rol con admin_usuarios), migración 0193 (solicitudes_accion), sync rules al VPS (4 buckets
  admin_usuarios), Edge Function invitar-cobrador re-deployada. **Bugs de producción encontrados y corregidos:**
  (1) Edge Function rechazaba admin_usuarios ("Rol inválido") — re-deploy del código que ya lo tenía; (2) migración
  0192 nunca se había deployado (verificación chequeó existencia, no contenido — lección documentada en memoria);
  (3) router faltaba `/admin/contratos` en allowlist admin_usuarios → flujo solicitudes inalcanzable; (4) emails no
  se refrescaban tras invitar (`ref.invalidate`); (5) `rolLabel`/`_rolDisplay` incompletos (3 archivos); (6) botón
  "Revertir cancelación" visible a admin_usuarios; (7) botón "Pagar" visible a admin_usuarios en el mapa (flag
  `sinDinero`). Commits: `3b3d6cf` (audit fixes), `9941941` (mapa Pagar), `173729c` (bump v0.25.2).
  Release v0.25.2 en curso.
- **(2026-07-19) — Fase 2 roles: gating admin_cobranza (auditoría completa) + fixes sesión.**
  Branch `claude/app-status-check-850cf6` (sin merge aún). **Requerimiento del tenant:** admin_cobranza ve
  Clientes/Rutas/Cobranza/Reportes/Mapa/Resumen pero NO montos recolectados — solo pendiente, mora, recuperación.
  **Principio:** ocultar RECAUDADO (lo que entró a caja), mantener PENDIENTE (lo que falta por cobrar).
  **Gating implementado (Dashboard + Reportes):** 5 secciones de dinero ocultas en Dashboard (CobrosKPIs,
  ConsultarPeriodo, Proyeccion, Sparkline, TopCobradores); 5 reportes de dinero ocultos (cobranza, cobros,
  por_cobrador, arqueo, fiscal); 2 tarjetas analíticas ocultas (RecaudacionMensual, CobradoresMes). Mantiene
  operativas.
  **Auditoría de Cobranza (3 sub-opciones) — decisiones aprobadas por Rubén:**
  - Centro de cobranza: sin cambio (montos son pendientes, no recaudado; suspender/reactivar = recuperación).
  - Cobros: sin cambio (herramienta de trabajo, muestra saldos pendientes).
  - Avisos: sin cambio (montos pendientes + WhatsApp).
  **Gating adicional aprobado (pendiente de implementar):**
  - Header contrato: ocultar "Recaudado" para admin_cobranza (dejar Total + Pendiente).
  - Cambiar plan: ocultar para admin_cobranza (gestión administrativa, no cobranza).
  - Pagos del contrato + PDF: dejar visible (contexto operativo por cliente).
  - Suspender/reactivar: dejar (recuperación de cartera).
  **Otros fixes de la sesión:** trigger RLS cuotas_check_cobrador_update ownership removido (migración 0191,
  deployada); desglose métodos en Mis cobros solo si 2+ con datos; recibo→detalle cliente go→push (fix back button);
  build-release.ps1 fix $base. **Archivos:** dashboard_admin_screen.dart, reportes_admin_screen.dart,
  contrato_detail_header.dart, contrato_detail_screen.dart, mis_cobros_screen.dart, recibo_screen.dart, app.dart,
  router.dart, app_shell.dart, ARQUITECTURA.md.
  **Pendiente:** implementar gating header contrato + cambiar plan, commit, audit, merge a main, build/release.
- **(2026-07-17) — Fix RLS op_log cobradores + corte PowerSync Cloud.**
  **op_log RLS bug (sistémico):** el upsert de PowerSync necesita policy SELECT para `RETURNING *`; op_log solo tenía
  SELECT para admin/admin_cobranza → todos los cobradores de todos los tenants fallaban con 42501 al sincronizar op_log.
  Fix: migración `0190` agrega `op_log_read_cobrador` (cobrador ve solo sus propias filas). Server-side, no requiere
  update de app. **PowerSync Cloud ELIMINADO:** la instancia cloud se descomisionó (estaba activa como respaldo desde
  2026-07-13). El VPS Hetzner (`65-109-1-217.sslip.io`) es el ÚNICO servicio de sync. Referencias al cloud limpiadas
  del código. Commits: `1840721` (fix RLS), merge a main.
- **(2026-07-15 septies) — Auto-fix invariantes + INV17 corregido + cron diario.**
  Botón "Corregir todo" en la pantalla de invariantes: corrige INV2, INV3, INV14, INV17 automáticamente via RPC
  `super_admin_corregir_invariantes` (migración 0189). INV17 (colchón insuficiente): 7 contratos tenían solo 2
  cuotas futuras por adelanto de agosto; regenerados. Cron `generar_cuotas_contrato` cambiado de mensual (`5 6 1 * *`)
  a **diario** (`5 6 * * *`) para que el colchón se regenere cada noche. Commit `d1a4766`.
- **(2026-07-15 sexies) — Sync gate fix + invariantes timeout + dashboard PowerSync → v0.24.11.**
  **Sync gate** (`router.dart:284`): la grace de 8s del sync gate bypasseaba el rol no resuelto en primer login (DB
  vacía) → cobrador veía UI vacía. Fix: `mustWait = rolNoResuelto || (!syncReady && !grace)` — grace solo bypassea sync,
  NUNCA el rol. **Migración DB** (`main.dart`): `_revertirDbNamespaceSiFalta` con `if (!await dest.exists())` preservaba
  DB stale y borraba la buena; fix: siempre sobreescribir. **Invariantes timeout** (migración `0188`): `ALTER FUNCTION
  SET statement_timeout = '120s'` para las 3 RPCs de invariantes (el default de Supabase ~8s mataba las queries en
  tenants con ~4600 clientes). **Dashboard PowerSync VPS** (`status-gen.sh` v4): reescrito con sección "Conexiones
  activas" en tiempo real (sync streams abiertos), botón "Actualizar", contador "datos de hace Xs", nombres reales de
  usuarios/tenant/rol, filtros por tenant. Cron `*/2 * * * *` configurado (antes no había cron → datos estale).
  Commits: `53fe57c` (sync gate), `ff95386` (timeout). Release v0.24.11 publicado. Dashboard:
  `https://65-109-1-217.sslip.io/panel-4b54f04c`.
- **(2026-07-15 quinquies) — Revertir namespace cross-app innecesario + impresión nativa Windows → v0.24.10.**
  El namespace por tenant slug de v0.24.7 era innecesario: MSIX ya aísla por `identity_name` y Android por
  `applicationId` — no comparten AppSupport ni AppDocuments. El subdirectorio `<slug>/` orfanaba la DB local (vista
  vacía "Nada por cobrar" post-update) y la migración borraba `logo_empresa/` causando la fuga de logo. Se revierte:
  DB vuelve a `<AppSupport>/` raíz, logo a `logo_empresa/` fijo. Migración v2 (`_revertirDbNamespaceSiFalta`) mueve
  los archivos de vuelta y limpia residuos (`logo_empresa_<slug>/`). Impresión PC: `directPrintPdf` seguía cortando
  en algunos drivers → se vuelve a `Printing.layoutPdf` (diálogo nativo de Windows). Archivos: `db.dart`, `main.dart`,
  `logo_local_storage_io.dart`, `logo_local_storage_web.dart`, `recibo_screen.dart`, `pubspec.yaml`. **477 tests OK ·
  analyze limpio.** Commit `9e76f5e`. **BUILD PENDIENTE.**
- **(2026-07-15 quater) — Fix período recibo (Mayo→Junio) + fecha cobro en lista cuotas → RELEASE v0.24.9.**
  Bug producción: cuota de mayo con `dia_pago=14` imprimía "Período: Junio" en el recibo. Causa:
  `periodoReciboSeguro(fecha_vencimiento, ...)` usaba `fecha_vencimiento.day` (14→15 por bump domingo) que cruzaba el
  umbral ≤14/≥15 de `mesServicio()`. Fix: TODOS los renderers (ticket/pdf/escpos, single + multi-cuota + mora = 9
  call sites) migrados de `mesServicioLabelSeguro(fecha_vencimiento,...)` / `periodoReciboSeguro(...)` a
  `mesServicioLabel(periodo, dia_pago)` / `periodoRecibo(dia_pago, periodo)` — usa el `dia_pago` estable del contrato
  (no se mueve por Sunday-bump). Mejora UX lista cuotas (variante C): muestra "Vence DD/MM" en todas, y "Cobro DD/MM"
  (verde) en pagadas. Subquery `MAX(fecha_pago)` agregada en `contratoCuotasProvider`. Archivos:
  `recibo_ticket/pdf/texto_escpos.dart`, `contrato_providers.dart`, `contrato_detail_cuotas.dart`, `pubspec.yaml`.
  **477 tests OK · analyze limpio.** Commit `5eed3ea`. Release en build.
- **(2026-07-15 ter) — Fix impresión PC cortada + toggle "Ajustar al driver" → RELEASE v0.24.8.**
  Reportado en campo: en PC (Windows) el recibo sale con la MITAD DERECHA CORTADA (valores como `SA-01…`,
  `System Ad…`, `EFECT…` truncados). Causa: `sistema_impresora_service.dart` llamaba a
  `Printing.directPrintPdf(usePrinterSettings: true)` desde v0.24.1 — ese flag le dice al paquete `printing` que
  IGNORE el `PdfPageFormat(80mm, ∞, marginAll: 0)` que se le pasa y use la config del driver. Si el driver de la
  térmica USB estaba configurado como Letter/A4 (default de muchos drivers OEM), rasterizaba el PDF al ancho ancho y
  el papel físico de 80mm solo captaba los primeros ~80mm → corte a la derecha. Se ve en la foto: logo + "COBRO"
  (centrados) intactos; las FILAS con label+valor perdían el valor. **Fix A+B:** (A) default cambiado a
  `usePrinterSettings: false` — el `format` exacto se respeta → PDF se manda con 80mm y el driver no re-escala.
  (B) toggle **"Ajustar al driver"** por-dispositivo (SharedPref `impresora_ajustar_a_driver`, default OFF, mismo
  patrón que "Envío lento" — nuevo provider `impresoraAjustarADriverProvider`), expuesto SOLO en desktop
  (`impresora_sistema_setup.dart` — el path Bluetooth de mobile no cambia). Escape hatch por si algún modelo raro
  necesita el modo viejo. Alcance: SOLO impresión por sistema (Windows/Linux/macOS); Android sigue con
  `print_bluetooth_thermal` intacto (path del cobrador de campo sin tocar, como pidió Rubén). Archivos:
  `sistema_impresora_service.dart`, `impresora_provider.dart`, `impresora_sistema_setup.dart`, `recibo_screen.dart`.
  **477 tests OK · analyze limpio (4 archivos).** **✅ RELEASE v0.24.8 PUBLICADO (2026-07-15)** (8 assets; v0.24.7
  borrado por política). Testing: en PC, cobrar → recibo COMPLETO (sin corte). Si algún modelo raro rompe con el fix,
  Perfil → Impresora → activar toggle **"Ajustar al driver"**. Detalle del release anterior (v0.24.7) ↓.
- **(2026-07-15 bis) — Fix REAL de fuga cross-app del logo → RELEASE v0.24.7.**
  Confirmado por Rubén: en v0.24.6 los usuarios con las 2 apps branded instaladas en la MISMA PC/tel siguen viendo el
  logo de la otra app en los previews de Settings / Editor de recibo al subir/actualizar (alterna). El fix de v0.24.6
  solo atacaba el asset baked (build-time) y una caché en memoria por proceso — no resuelve dos MSIX/APK viviendo en
  el mismo device compartiendo `~/Documents/`. Root cause identificada: `LogoLocalStorage` cacheaba en
  `<AppDocs>/logo_empresa/logo_<tenantId>.png` sin namespace por app (MSIX no virtualiza Documents sin
  `documentsLibrary`), y la caché de `Image.network` en el preview (`_LogoUploadWidget`) no se limpiaba tras el upload
  → miniatura vieja por 1-2 frames. **Fix en 3 capas + migración one-shot (rama `claude/app-status-check-850cf6`):**
  (1) Namespace por `--dart-define=TENANT=<slug>` de la carpeta de logos (`logo_empresa_<slug>/`) en
  `logo_local_storage_io.dart` y del directorio de PowerSync DB (`<AppSupport>/<slug>/`) en `powersync/db.dart` —
  aditivo, sin bump de `_dbWipeVersion` (se re-sincroniza una vez la primera vez que arranca la app branded post-update).
  (2) Evict de `PaintingBinding.instance.imageCache` en `_LogoUploadWidget` tras upload/delete y en `onDatabaseSwitched`
  + listener del `impersonatedTenantIdProvider` en `main.dart`. (3) Fix del race invalidate/refrescarLogo — el
  refrescarLogo ahora completa el await ANTES del invalidate. **Migración one-shot** en `main.dart`
  (`_migrarAislamientoCrossAppSiFaltaV1`, flag SharedPref) borra la carpeta legacy `<AppDocs>/logo_empresa/` una sola vez
  en apps branded (el build genérico la conserva). **477 tests OK · analyze limpio (5 archivos).**
  **✅ RELEASE v0.24.7 PUBLICADO (2026-07-15)** (8 assets: 2 msix + 2 apk + 2 version-*.json + 2 install-*.ps1;
  v0.24.5 y v0.24.6 borrados por política). ARQUITECTURA §R20 actualizada con la regla nueva de aislamiento cross-app
  (namespace por TENANT slug). Backlog para próximos sprints: `foto_local_storage_io`, `map_tile_cache`,
  `offline_routing_service` y `update_service` tienen el mismo patrón cross-app latente (fotos, tiles, descargas).
  **Testing manual pendiente:** Rubén verifica los 3 escenarios (upload cross-app / recibo impreso / migración one-shot)
  con las 2 apps instaladas. **Aviso a usuarios:** primer boot post-update va a re-sincronizar la DB completa
  (subcarpeta nueva `<slug>/`) — puede tardar minutos en 3G rural. Detalle previo (v0.24.6) ↓.
- **(2026-07-15) — Fix de fuga de logos e iconos cross-tenant → RELEASE v0.24.6.** Pedido: corregir
  el icono y logo de Mairena que se filtraban en los instaladores/apps de otros tenants. Solución: se añadió
  `flutter clean` y `flutter pub get` al inicio de `Build-One` en `build-release.ps1` para asegurar que Gradle y
  CMake limpien completamente los recursos cacheados entre compilaciones. También se incorporó el `tenantId` en la
  clave de la caché en memoria del logo de térmica (`_logoTermicaCache` en `recibo_screen.dart`) para aislar los
  logos procesados por tenant. Verificado en build local. **✅ RELEASE v0.24.6 PUBLICADO (2026-07-15)** (8 assets).
  **⚠️ INCOMPLETO — el fix solo cubría build-time; el vector runtime cross-app se resolvió en la entrada de arriba.**
- **(2026-07-14 bis) — Tamaños de logo Muy grande / Gigante → RELEASE v0.24.5.** Pedido: el logo
  se ve chico incluso en "grande". Se agregaron 2 tamaños SOLO para el logo (extraGrande 1.7× / gigante 2.2×) con
  escala dedicada `_logoScale`/`_pdfLogoScale` en los 3 renderers; el texto los TOPA en grande y el editor solo los
  ofrece en el bloque `logo` (con ícono de imagen). El logo crece hasta el ancho del papel: imagen/PDF con
  `BoxFit.contain`, compatible con clamp de ancho en `logo_termica` (nuevo param `maxAnchoDots`). Retrocompatible
  (enum solo gana valores, sin migración). Commits `9e5fbe0`/`d3b9e0c`. **✅ RELEASE v0.24.5 PUBLICADO (2026-07-14)**
  (8 assets, Latest, v0.24.4 borrado, manifests 0.24.5). Uso: Ajustes → Recibo → editor → bloque Logo → 5 tamaños.
- **(2026-07-14) — Envío lento v2 (write único + settle) → RELEASE v0.24.4.** Campo (3nStar):
  el envío lento v1 ARREGLÓ el pie pero ROMPIÓ el raster — las pausas del chunking de 512B caen EN MEDIO del bloque
  binario (GS v 0 + bitmap) → el firmware se desincroniza e imprime el bitmap como TEXTO (modo imagen = basura de
  símbolos; logo del compatible = franja rota). Clave del usuario: ANTES del chunking el logo salía BIEN → nunca hubo
  overflow; la única causa real del pie era el disconnect prematuro. **v2: write ÚNICO byte-idéntico + settle 2s antes
  del disconnect** (commit `a5b8b83`). Regla NUEVA: jamás chunkear un stream ESC/POS con pausas (desincroniza rasters);
  si algún día hace falta, cortar SOLO en límites de comando. Receta 3nStar: Compatible+Simplificado+Envío lento (sus
  tildes CP850/GBK sí son del firmware). Los otros modos de tildes muestran ¿/¬ (firmware, no nuestro). **✅ RELEASE
  v0.24.4 PUBLICADO (2026-07-14)** (8 assets, Latest, v0.24.3 borrado, manifests 0.24.4). PENDIENTE campo: confirmar
  logo+pie OK en la 3nStar. PENDIENTE PC: modo "Directo ESC/POS" (congelón ~10s del plugin printing) — aprobado.
- **(2026-07-13 bis) — Impresión: "Envío lento" por dispositivo → RELEASE v0.24.3.** La 3nStar
  roja del campo (Telenet) imprime el recibo pero el PIE sale EN BLANCO, en AMBOS modos (imagen y compatible) y con
  feed descartado → el común denominador es el TRANSPORTE BT: `writeBytes` retorna con datos aún encolados y el
  `disconnect` inmediato corta la transmisión (se pierde siempre la cola = el pie); su buffer chico sin control de
  flujo agrava. **Fix (lección v0.22.10-13 respetada):** toggle **"Envío lento"** en Perfil → Impresora, POR
  DISPOSITIVO (SharedPrefs, default OFF = transporte byte-idéntico): chunks de 512B + pausas 20ms + settle 1.5s antes
  de desconectar; aplica a imagen/compatible/prueba. Commit `53aa1a2`. **✅ RELEASE v0.24.3 PUBLICADO (2026-07-13)**
  (8 assets, v0.24.2 borrado; PRIMERA corrida exitosa del build-release.ps1 arreglado — sube desde Releases/).
  **Pendiente de campo:** el usuario de la 3nStar activa el toggle y prueba recibo largo con mora → si el pie sigue
  en blanco, siguiente hipótesis (firmware). Testing: activar toggle → Imprimir prueba completa → recibo con mora.
- **(2026-07-13) — PowerSync SELF-HOST en VPS Hetzner → CUTOVER v0.24.2.** Para escapar del overage
  de "Data Synced" del PowerSync cloud (~$66/mes, inflado por dev-churn), se montó el **PowerSync Service self-hosted**
  en un VPS Hetzner (Helsinki, CX23, ~$7/mes; IP 65.109.1.217; URL `https://65-109-1-217.sslip.io`). Stack Docker
  (powersync 1.23.3 + Postgres bucket-storage + Caddy/HTTPS), replicando de Supabase por conexión directa IPv6 con un
  **rol dedicado `powersync_selfhost`**. **El único escollo fue RLS** (el rol veía 0 filas en el snapshot inicial; fix:
  `ALTER ROLE ... BYPASSRLS` + re-snapshot). **Test cliente PASÓ**: 84.281 ops sincronizadas a un cliente real
  (super_admin impersonando Mairena) desde el server nuevo, auth JWKS OK. Cutover: release v0.24.2 con `POWERSYNC_URL`
  al server nuevo → **auto-update a todas las apps** (mismas apps, sin reinstalar; un re-sync único por device). El
  PowerSync cloud **ELIMINADO** (2026-07-17, ya no queda como respaldo). **Toda la receta,
  gotchas (RLS/BYPASSRLS, Docker IPv6, ban de Supabase, msix `--build-windows false`) y estado en la memoria del
  proyecto** `powersync-selfhost-hetzner`. Detalle previo (impresión) ↓.
- **(2026-07-13) — Windows imprime a impresoras del SISTEMA (USB/red) → RELEASE v0.24.1.** Reporte
  de usuarios de PC: no ven sus impresoras USB al imprimir recibo.
  Causa raíz: toda la impresión térmica corre sobre `print_bluetooth_thermal` (Bluetooth-only) y **en Windows ese
  plugin es un STUB** (`bluetoothenabled`→false fijo, resto `NotImplemented`) → la pantalla mostraba "Bluetooth
  desactivado" y las USB (registradas como impresoras del sistema, no BT) NUNCA aparecían. **Fix (Opción A, aprobada
  por Rubén):** en desktop la impresión pasa por el paquete **`printing`** (ya instalado+registrado en Windows):
  `listPrinters()` lista las impresoras que Windows tiene instaladas y `directPrintPdf` manda el **MISMO PDF de rollo**
  del recibo directo a la elegida, sin diálogo. **Todo aditivo, gateado por `impresionPorSistema`**
  (`defaultTargetPlatform`, sin `dart:io`) → **Android queda byte-idéntico** (Bluetooth intacto). Favorita del sistema
  en claves SharedPrefs propias (paralela a la BT). Archivos: `sistema_impresora_service.dart` (nuevo),
  `impresora_sistema_setup.dart` (nuevo), `impresora_provider.dart`, `impresora_setup_screen.dart`, `recibo_screen.dart`.
  **477 tests** · analyze limpio (5 archivos) · **build Windows OK**. **Fallback B (ESC/POS crudo por USB vía
  winspool)** planificado como modo opt-in por PC para el modelo raro que su driver no corte/dimensione bien.
  Probado por Rubén en USB real → **✅ RELEASE v0.24.1 PUBLICADO (2026-07-13)** (bump OBLIGADO: el auto-update no
  dispara si el nº repite el 0.24.0 del diseñador). Commits `4855354`/`452b098`/`4b44e23`. Riesgo residual: papel/corte
  dependen del driver (`usePrinterSettings:true`) → si un modelo descuadra, activar el fallback B (por PC).
- **(2026-07-11) — Recibo: espaciado por segmento + template por defecto · "generar recibos
  faltantes" · backfill INV5 (24 recibos).** El error masivo **"recibo duplicado"** es colisión de correlativo
  cliente-side del **System Admin** (max+1 por cobrador, identidad de alto volumen) — **NO pierde plata** (verificado);
  el **fix de fondo está EN PAUSA** esperando la decisión FISCAL de Rubén (¿el correlativo visible puede duplicarse?).
  Se agregó: **espaciado configurable ENTRE SEGMENTOS** por bloque (los 3 renderers, imagen/PDF/compatible); **layout
  por defecto = template** de los dueños (**Colector**, **Monto**/Total en mora, **cuota oculto**, WhatsApp al pie,
  **hora off**); y el botón super_admin **"Generar recibos faltantes"**. Commits `bfd9133` + `bde36b9`; migraciones
  **0186/0187 ya en prod**. **✅ RELEASE v0.24.0 PUBLICADO (2026-07-12)** (8 assets, previos borrados). Iteraciones de
  campo: **v0.23.1** 'amplio' ~1.4→~5mm (`reciboEspacioPx` no lineal, `3839257`); **v0.23.2** preview con código+mora
  de ejemplo (`f35e7ad`); **v0.24.0** el **diseñador de recibo pasa a NIVEL-CAMPO** — los bloques de info (empresa,
  meta, cliente, servicio, método) se abren en **campos reordenables (↑/↓) + habilitables** por separado; **"Código"→
  "ID"**; modelo `ReciboCampo`/`campos` + los 4 renderers iteran `b.campos` con seed de hora/código/cédula desde los
  toggles viejos (cero cambio visual al actualizar); 477 tests, audit adversarial sin críticos (commits `0334688` +
  `9a8cc43`). **PENDIENTE: decisión fiscal del correlativo** (destraba el fix de fondo del "recibo duplicado").
  Detalle ↓ en la entrada datada 2026-07-11.
- **(2026-07-11) — Modo de impresión COMPATIBLE (texto nativo ESC/POS) → v0.22.21:**
  Feature grande, pedido de Rubén tras confirmar que la **3nStar PPT305BT** (80mm, Mairena) sigue dando basura/corte
  en algunos teléfonos (desborde de buffer BT, ver backlog). **Segundo modo de impresión OPT-IN** para impresoras
  baratas: en vez de rasterizar toda la hoja (pesado → desborda), manda **TEXTO NATIVO ESC/POS** (liviano, no
  desborda) con **codepage CP850** → tildes correctas y SIN "caracteres chinos" (la barata sin `ESC t` interpreta los
  bytes con su codepage nativo). El logo va como imagen chica. **Config de 2 NIVELES (diseño de Rubén):** (1)
  **super_admin** (por tenant, tab Recibos → card `_ModosImpresionCard`) habilita qué modos están DISPONIBLES —
  Imagen es default y siempre queda ≥1; (2) **cobrador** (por dispositivo, `impresoraModoProvider` en SharedPrefs,
  selector en `impresora_setup_screen`) elige Imagen/Compatible **solo si el super_admin habilitó ambos**; si solo
  uno, se usa ese. **Default = Imagen** → los que ya andan (Telenet) NO cambian (opt-in). Piezas: renderer
  `recibo_texto_escpos.dart` (espeja la matemática del PDF → misma plata; single+multi+mora+cargos+USD), método
  `imprimirTexto` (mismo transporte, datos livianos), getters `modoImagen/CompatibleHabilitado`, dispatch en
  `_imprimir`, refactor `_logoProcesado` compartido. **Validado:** test del codepage (CP850 codifica 1 byte, no UTF-8
  crudo; emite `ESC t`) — el núcleo incierto FUNCIONA. **462 tests** · analyze limpio. Commit `126beb5`.
  **✅ RELEASE v0.22.20 PUBLICADO (2026-07-11):** 8 assets, Latest, v0.22.19 borrado.
  **HOTFIX v0.22.21 (mismo día):** la card `_ModosImpresionCard` del super_admin **no aparecía** — la tab Recibos
  hace early-return a `ReciboLayoutEditor` (settings_admin_screen:319-321), así que la inyección en la grilla de
  `_construirCategoria` era CÓDIGO MUERTO → el super_admin no podía habilitar Compatible. Fix: mover la card ADENTRO
  del `ReciboLayoutEditor` (tope de `editorChildren`, gateada a `esSuperAdmin`). El selector por-dispositivo ya estaba
  bien. Se cazó verificando las rutas de navegación ANTES de dar las instrucciones a Rubén. Commit `a758fcb`.
  **✅ RELEASE v0.22.21 PUBLICADO (2026-07-11):** 8 assets, Latest, v0.22.20 borrado.
  **HOTFIX 2 — v0.22.22, IDEOGRAMAS CHINOS en las tildes (probado en campo):** Rubén probó Compatible en la 3nStar:
  las tildes salían como ideogramas que se COMÍAN la letra siguiente ("Método"→"M闁odo", "Período"→"Per㟛odo").
  Causa raíz: las térmicas chinas ARRANCAN en **modo Kanji/GBK** — interpretan todo byte alto (0x80-0xFE) como la
  primera mitad de un carácter chino de 2 bytes; la tilde CP850 (1 byte alto) + la letra siguiente = ideograma.
  **Seleccionar el codepage (ESC t) NO alcanza: el modo Kanji tiene precedencia.** Fix principal: emitir **`FS .`
  (0x1C 0x2E, cancelar modo Kanji)** inmediatamente DESPUÉS del reset (ESC @ vuelve al default chino del firmware)
  + `setGlobalCodeTable(CP850)`. **Plan B GARANTIZADO (por-dispositivo):** toggle **"Imprimir tildes"** en
  Perfil→Impresora (`impresoraTildesProvider`, SharedPrefs, default ON) — apagado translitera TODO a ASCII puro
  (`quitarTildes`: á→a, ñ→n, resto no-ASCII→'?') → 0 bytes altos → imposible de corromper en cualquier firmware.
  El selector de modo ahora también aparece cuando Compatible es el ÚNICO habilitado (antes exigía ambos). Tests
  nuevos: FS . presente en el stream real del recibo, transliteración, 0 pares de bytes altos con tildes=false.
  **465 tests** · analyze limpio. Commit `584578e`. **✅ RELEASE v0.22.22 PUBLICADO (2026-07-11):** 8 assets, Latest,
  v0.22.21 borrado.
  **HOTFIX 3 — v0.22.23 (probado en campo por Rubén con fotos):** (a) el modo sin-tildes salía casi perfecto pero con
  **"732,00?C$"** — el `?` era el **NBSP (U+00A0)** que `NumberFormat.currency` mete entre monto y "C$" (confirmado:
  bytes `30 A0 43 24`); ese mismo NBSP era la "C" comida en CP850 ("732,00蜆$"). Fix: `_normEspacios` normaliza
  NBSP/NNBSP/thin → espacio común en TODO el texto del renderer (los 3 modos). (b) La 3nStar **IGNORA el `FS .`**
  (firmware CABLEADO a GBK) → CP850 no va a andar nunca ahí. **Solución REAL para tildes en chinas cableadas: nueva
  estrategia `'gbk'`** — codifica á é í ó ú ü como sus pares **PINYIN GB2312 nativos** (zona 0xA8: á=A8A2, é=A8A6,
  í=A8AA, ó=A8AE, ú=A8B2, ü=A8B9) con `FS &` (Kanji ON) al inicio: el acento sale REAL (glifo fullwidth, algo más
  ancho; 2 bytes = 2 celdas → la aritmética de `row` cuadra); Ñ/mayúsculas acentuadas → translit. Selector
  por-dispositivo de 3 estrategias en Perfil→Impresora: **Normal (cp850) / China (gbk) / Sin tildes (ascii)**
  (`impresoraTildesModoProvider`, migra el bool de v0.22.22). Tests: par pinyin en el stream real + FS & + NBSP→espacio
  + 0 bytes altos en ascii. **467 tests** · analyze limpio. Commit `97c7c88`. **✅ RELEASE v0.22.23 PUBLICADO
  (2026-07-11):** 8 assets, Latest, v0.22.22 borrado.
  **PULIDO — v0.22.24 (pedido de Rubén: Ñ + nombres formales):** (a) **eñe REAL en el modo alternativo**: ñ/Ñ no
  existen en GBK (ni en la zona pinyin) → se definen como **caracteres de USUARIO** (`ESC &`, bitmaps 12×24 tipografía
  VGA clásica, generados por script) en los códigos 0x7B/0x7D + `ESC % 1` (set de usuario ON; códigos no definidos
  caen a la fuente residente, spec Epson) → "Peña"/"Núñez" con eñe real también en chinas cableadas. Mapeo en
  `_gbkBytes` (ñ→0x7B, Ñ→0x7D). Caveat: si un firmware no soportara `ESC &`, la ñ saldría como '{' — confirmar en
  papel. (b) **Labels formales** del selector: Normal/China/Sin tildes → **Estándar / Alternativo / Simplificado**
  (valores internos sin cambio → la elección guardada se conserva); textos explicativos reescritos en tono formal.
  Tests: definición ESC & + activación ESC % + "Peña" codifica 0x7B en el stream real. **468 tests** · analyze limpio.
  Commit `2bf26f6`. **✅ RELEASE v0.22.24 PUBLICADO (2026-07-11):** 8 assets, Latest, v0.22.23 borrado. **Pendiente:**
  en la 3nStar elegir **"Alternativo"** e imprimir un recibo con cliente con ñ y tildes → acentos pinyin + eñe
  dibujada; si algo sale raro → "Simplificado" (probado OK en campo, monto limpio).
- **(2026-07-10) — Recibo: código del cliente + Hora toggleable → v0.22.19:**
  Feedback de campo (contenido del recibo, no impresión). **(1) Código del cliente:** el ID simbólico (`clientes.codigo`,
  ej. `SE0020`) NO aparecía en el recibo → ahora se muestra como línea "Código" en el bloque `cliente`, default ON,
  sub-toggle en el editor de layout. Se agregó `c.codigo AS cliente_codigo` a las queries (single+multi de
  `recibo_screen`) y se muestra en ticket + PDF + preview (paridad). **(2) Hora toggleable:** la "Hora" salía 00:00 →
  investigado: NO es bug — de 4017 pagos, los **3937 en 00:00 son TODOS del "System Admin"** (cobros históricos
  cargados sin hora); los cobros REALES del cobrador tienen hora correcta (`medianoche=0`). Solución: sub-toggle
  "Mostrar hora" en el bloque `meta`, default ON, para poder ocultarla. **Sin migración SQL** (el sub-toggle hace
  `upsert` + el getter Dart tiene default). Nuevos getters `reciboMostrarCodigo`/`reciboMostrarHora` (settings_repo),
  toggles en `recibo_layout_editor` (`_subOpciones`/`_subValor`) + labels en `settings_admin_screen`. **460 tests** ·
  analyze limpio. Commit `7754e3a`. **✅ RELEASE v0.22.19 PUBLICADO (2026-07-10):** 8 assets, Latest, v0.22.18 borrado.
- **(2026-07-10) — Logo del recibo en térmica: aparece + tonos gris + ANR corregido → v0.22.18:**
  Dos casos de campo (Mairena + Telenet), los dos del LOGO en impresión térmica. **Mairena (80mm): logo AUSENTE** en
  el print aunque preview/PDF lo mostraban. Causa: `_capturarReciboPng` leía el logo SOLO del cache local, y el logo
  gigante (8000×4500) no alcanzaba a pintar en el `delay` de 80ms de la captura offscreen → salía en blanco. **Telenet
  (58mm): naranja PERDIDO** — mi umbral 0.5 (v0.22.15) tira los tonos medios a blanco (1-bit no hace gris). Diagnóstico
  con render real de ambos logos: tienen necesidades OPUESTAS (Mairena sólido quiere umbral; Telenet quiere tono) →
  un algoritmo global único no sirve. **Fix (nuevo `lib/data/utils/logo_termica.dart` + `_capturarReciboPng`):** (1)
  el logo se toma del **`logoEmpresaBytesProvider`** (cache-o-red, igual que preview/PDF) → si el preview lo mostró, el
  print también lo tiene; (2) se **pre-redimensiona** a la altura de display (`60 × escala × baseFont`) → pinta al
  instante (fix Mairena); (3) **binarización HÍBRIDA**: umbral en los extremos (sólidos nítidos) + dither ordenado
  **Bayer 8×8 solo en la banda media [0.42, 0.82]** (naranja → gris) — da los DOS logos bien de una. **Solo el LOGO
  en térmica:** el texto sigue con umbral simple (nítido), el transporte BT **NO se toca** (lección grabada), preview/
  PDF **sin cambios**. Validado: render de los 2 logos reales + **test Dart del híbrido** (`logo_termica_test.dart`:
  negro sólido / blanco / gris-stipple) + PNG inválido → null (no rompe). **460 tests** · analyze limpio. Commit
  `5815a0f`. **✅ RELEASE v0.22.17 PUBLICADO (2026-07-10):** 8 assets, Latest, v0.22.16 borrado.
  **HOTFIX v0.22.18 — ANR de Android (mi regresión de v0.22.17):** en Mairena, al imprimir la app "se quedaba pegada"
  varios segundos y Android tiraba el prompt "la app dejó de responder" (ANR), recurrente. Causa: v0.22.17
  decodificaba el logo GIGANTE (8000×4500) — decode + resize + híbrido — **sincrónico en el hilo de UI** → lo bloqueaba
  segundos. Fix: correr `procesarLogoTermica` en un **isolate** (`compute` + wrapper `procesarLogoTermicaIsolate`,
  web-safe) + **cache en memoria** del logo procesado (`_logoTermicaCache`, por bytes+altura) → se procesa 1 vez, las
  impresiones siguientes instantáneas. Salida impresa IDÉNTICA (mismo híbrido). Commit `4b0dfc5` · **460 tests** ·
  analyze limpio. **✅ RELEASE v0.22.18 PUBLICADO (2026-07-10):** 8 assets, Latest, v0.22.17 borrado. **Pendiente:**
  confirmar en campo Mairena (logo aparece, SIN ANR) + Telenet (naranja gris); umbrales del híbrido (0.42/0.82)
  ajustables por hardware si hiciera falta (solo afecta al logo).
- **(2026-07-10) — PowerSync "Data Synced" 24 GB: churn diagnosticado + arreglado (server-only):**
  Rubén notó el "Data Synced" de PowerSync trepado a **24 GB** con solo ~11 dispositivos (la base entera pesa 0.55 GB).
  Clave: PowerSync cobra por **operaciones × dispositivos**, no por tamaño. Diagnóstico con `pg_stat_user_tables`
  (63 días): **#1 `notificaciones_mora` 130k UPDATES** — el cron DIARIO reescribía `dias_mora` (+1/día) en las ~23k
  filas vencidas → cada dispositivo re-descargaba la tabla ENTERA a diario (y escalaba con la cartera). **#2 `clientes`
  62k UPDATES** — el recalc de `vencimiento_mas_viejo` (color del mapa) escribía SIN guarda → no-ops en cada cuota
  futura generada. Auditado: los campos GUARDADOS `dias_mora`/`monto_adeudado` son **ESCRITURA-MUERTA** (los 4 lectores
  los calculan en vivo desde `cuotas`; el badge cuenta por `vista_en`/`resuelta_en`). **Fix = 2 migraciones SERVER-ONLY
  (sin app, sin redeploy de sync-rules, reversible):** **0184** cron `ON CONFLICT DO UPDATE`→`DO NOTHING` (solo alta de
  mora nueva); **0185** guarda `IS DISTINCT FROM v_new` en `recalc_vencimiento_mas_viejo` (preservando `SECURITY
  DEFINER` + la fórmula EXACTA de 0150 — 2 gates críticos: sin DEFINER el cobrador no puede escribir `clientes` por RLS
  y rompe el cobro; sin la fórmula literal los clientes con solo cuotas manuales pierden color). **Garantía pedida por
  Rubén:** verificación adversarial (workflow 5 agentes, TODOS safe/high, 0 bloqueantes) + rollback guardado + prueba
  `xmin` EN PROD (ambas filas `sin_reescritura=true` tras correr cron/recalc) + invariantes de dinero (mi cambio = 0
  impacto). **Aplicadas y verificadas en prod.** Efecto: el "Data Synced" deja de treparse. **Pendiente (Rubén):**
  (D) **compaction** de PowerSync en el dashboard para comprimir el historial YA acumulado (guía: **Compact** ahora
  = sin costo; **Defragment** DESPUÉS del 23-jul con los dispositivos en wifi = pico de re-sync one-time absorbido por
  el ciclo nuevo); (C) menos redeploys de sync-rules en prod.
  **Deuda de datos de dinero (pre-existente, RESUELTA en la misma sesión):** al correr invariantes salieron INV4 y
  INV5 (no causados por este cambio). Investigados: **INV4** = cliente de TEST `PRUEBA1` con una cuota triple-pagada
  (513×3=1539) por 3 cobradores en 12s → testing multi-dispositivo offline (límite aceptado #11) → **fix: DELETE de
  los 2 pagos duplicados** (recibos por CASCADE; el `pagos_guard_cobrador_trg` bloquea ANULAR en Mairena, pero es
  BEFORE UPDATE → DELETE lo bypassa). **INV5** = 18 cobros REALES del super_admin (clientes admin-managed, `cobrador_id
  NULL`) sin recibo → el "System Admin" es el admin del tenant (prefijo SA), cobrador VÁLIDO → **fix: generados 18
  recibos** SA-01370→01378 (Mairena) + SA-01824→01832 (Telenet), continuando la secuencia. **Los 17 invariantes → 0.**
  **Backlog:** el flujo del super_admin sigue pudiendo registrar cobros sin recibo (opción "arreglar para adelante" NO
  elegida) → si sigue cobrando así, aparecerán más; evaluar el fix del flujo más adelante.
- **(2026-07-10) — Audit F1 + impresión (logo nítido) + Guardar PDF en Android → v0.22.16:**
  **F1 (clientes/etiquetas/fotos_cliente/visitas):** audit por tabla (workflow 21 agentes) → 7 confirmados (SIN
  críticos) + 1 drift de dato. Titular: **deuda fantasma** — desactivar un cliente NO frenaba la generación de
  cuotas (gatea por contrato.estado, no cliente.activo) → deuda invisible acumulándose y reapareciendo al reactivar.
  Fix semántica C (aprobada por Rubén): se BLOQUEA desactivar con contratos activos (suspendé/cancelá el contrato
  primero) + texto del switch corregido. Otros: código inmutable re-mayusculizado volvía al cliente INEDITABLE (fix,
  1 caso real en prod) · op_log al borrar etiqueta (el CASCADE los desasignaba sin rastro) · UNIQUE folded de
  etiqueta (0183) · error FALSO al borrar foto offline · visitas_read alineada a tenant-wide (0183) + catálogo op_log
  muerto removido. Migración 0183 aplicada+verificada · drift de prod alineado. Fichas en ARQUITECTURA **§3.6.3**.
  **IMPRESIÓN — regresión mía, REVERTIDA (lección dura):** una térmica BT barata (roja, tenant Telenet) imprimía
  basura. **ERROR:** perseguí ESA impresora tocando el raster/transporte GLOBAL — 4 cambios encadenados (chunks →
  sin-dither → transporte robusto con pacing/settle/retry/drain → umbral 0.6+dilatación, v0.22.10→13). Pero el
  rasterizado de imagen YA funcionaba PERFECTO en la mayoría (la impresora de prueba de Rubén, la GOOJPRT PT-210); la
  roja tenía un problema PUNTUAL/pre-existente. Mis cambios **ROMPIERON el raster que andaba** → recibos ilegibles/
  distorsionados en TODAS (confirmado por Rubén con fotos: "antes" perfecta vs "ahora" rota). **RESOLUCIÓN: revertir
  `impresora_service_io.dart` EXACTO a `8c4e330`** (dithering + umbral 0.5 + transporte original, byte por byte).
  **✅ RELEASE v0.22.14 PUBLICADO (2026-07-10):** restaura la impresión que funcionaba; v0.22.8..13 borrados · **458
  tests** · analyze limpio. Commits `..2e913ee`. **REGLA GRABADA:** NUNCA cambiar el raster/transporte GLOBAL para
  arreglar UN modelo de impresora — si se aborda la roja del campo, tiene que ser un **modo de compatibilidad POR
  impresora (opt-in)**, PROBADO en ese modelo, sin tocar el path que ya anda.
  **IMPRESIÓN 2 — logo nítido (arreglo REAL, universal) → v0.22.15:** tras revertir, Rubén reportó que el logo salía
  "tiznado" (puntitos dispersos) en su PT-210 a 58mm. Arqueología dura: `impresora_service_io.dart` byte-idéntico a
  `8c4e330`, widget sin cambios visuales desde esa era, y el **dithering está desde v0.7.1** (NUNCA fue regresión —
  el logo siempre se ditheó). El resultado se destapó por 2 factores NO-código: **Telenet en 58mm** (384 dots = mitad
  de resolución que 80mm; confirmado en DB `recibo.formato_default_mm=58`) + cabezal PT-210 barato. Causa raíz: el
  pipeline dithereaba (Floyd-Steinberg) TODO el recibo, pero un recibo es **line-art** (texto + logo sólido), no una
  foto → el dither dispersa los trazos sólidos en puntitos. **Fix quirúrgico: quitar el dither y dejar que
  `_rasterGsv0` binarice por su umbral 0.5 existente.** Validado con render real de los **3 logos de producción**
  (Telenet, Mairena, SITECSA fondo-negro/inverso): todos nítidos, ninguno se rompe; 0.5 es el ÚNICO umbral seguro
  (0.6/0.7 se comen el logo inverso). CERO cambios de transporte/layout (respeta la lección). Commit `d659dfe` ·
  **458 tests** · analyze limpio. **Márgenes:** a 58mm el contenido ya llena los 384 dots imprimibles; el blanco de
  los lados es zona no-imprimible física del papel y la leve asimetría es alineación física de la PT-210 — NO se
  toca (mover ancho/centrado global fue lo que rompió todo). Commit `d659dfe` (v0.22.15).
  **GUARDAR PDF EN ANDROID (feature, pedido de Rubén) → v0.22.16:** el botón "Guardar PDF" del recibo estaba gateado
  SOLO a desktop; ahora se muestra también en **Android** (gate `esDesktop` → `!kIsWeb`). Reusa `guardarArchivo`
  (`FilePicker.saveFile`, `descarga_archivo.dart`) — en Android abre el selector de ubicación del sistema y escribe el
  archivo **SIN permisos de almacenamiento**, la MISMA ruta ya probada con la que se guardan los reportes. PDF al
  **ancho de rollo** (decisión de Rubén, no A4) y **100% OFFLINE** (fuente embebida + logo del cache + datos de
  PowerSync local). Renombrado `_imprimirSistema`→`_guardarPdf`. Web mantiene "Descargar PDF" (share). Sin lógica de
  dinero. Commit `a9e8c43` · **458 tests** · analyze limpio. **✅ RELEASE v0.22.16 PUBLICADO (2026-07-10):** 8 assets
  en sitecsa-updates (mairena+telenet MSIX/APK/manifest/install), Latest, manifests en 0.22.16, v0.22.15 borrado.
  **Pendiente de testeo de Rubén:** (1) impresión nítida del logo en la PT-210 real; (2) "Guardar PDF" en Android →
  toca → elegir ubicación → PDF guardado sin internet. **Backlog:** impresora roja del campo sigue ABIERTA
  (modo-por-impresora, sin apuro); luego F2 (planes+contratos).
- **(2026-07-09) — Audit POR TABLAS: FASE 0 (fundación) completa → v0.22.8:**
  Método nuevo pedido por Rubén (los audits por-diff dejaban pasar bugs de INTERACCIÓN entre tablas): auditar
  **tabla por tabla** con ciclo de vida completo + verificación adversarial, fase por fase, pidiendo OK entre cada
  una. **F0 = tenants/cobradores/settings/op_log:** workflow de 33 agentes → 13 hallazgos confirmados + 2 refutados;
  prod mayormente limpio. **Titular (CRÍTICO+ALTO): revocación de acceso** — "Desactivar" cobrador y suspender tenant
  eran COSMÉTICOS (no cortaban login/sync/cobro). Fix v1: `tenants.activo` + RPC `verificar_acceso` (gate de login,
  fail-open) + `AND activo=true` en 6 buckets del sync-rules + UI "Suspender/Reactivar ISP". **Otros:** op_log
  append-only por trigger (0179) · tenants.nombre único (0180) · revocación server (0181) · settings super-only +
  historial admin_tickets scopeado (0182) · prefijo en reenviar-invitacion · unicidad de prefijo · op_log alta/baja
  cobrador + documento de contrato · settings updated_at UTC · visor de historial de config. `super_admin_all` en 5
  tablas append-only/service-role = **NO-FIX documentado** (poner FOR ALL a un ledger contradice el append-only).
  Migraciones 0179-0182 aplicadas+verificadas en prod · sync-rules **Active v18** · 2 edge functions deployadas ·
  **458 tests** · analyze limpio. Commits `9ce30f3`..`dad8ba6`. Fichas en ARQUITECTURA **§3.6.2**.
  **✅ RELEASE v0.22.8 PUBLICADO (2026-07-09):** 8 assets en sitecsa-updates, v0.22.7 borrado, manifests 0.22.8.
  **Pendiente:** **F1 (clientes)** — siguiente fase del audit por tablas (esperando OK de Rubén). Testing sugerido:
  desactivar un cobrador → al reabrir/reconectar queda fuera (login) y deja de sincronizar; suspender un ISP desde
  /super → sus usuarios no entran.
- **(2026-07-09) — Mes simbólico: día 15 pasa a "mes del vencimiento" → v0.22.7:**
  Pedido de tenants: una instalación el **15/dic** cobra el **15/ene** → su cuota es de **Enero** (el mes en que se
  paga), pero el sistema mostraba **diciembre**. Causa: el umbral de `Fmt.mesServicio` (formatters.dart) estaba en
  15/16 (día ≤15 → mes anterior). **Fix (1 carácter):** umbral pasa a **14/15** — día ≤14 → mes anterior; día ≥15 →
  mes del vencimiento. El ÚNICO día que cambia es el **15** (los 1–14 y 16+ quedan idénticos) → en la práctica solo
  afecta contratos con **día de pago 15**. Es label **DERIVADO** (no columna) → **sin migración**: re-etiqueta solo
  al actualizar la app (los recibos YA impresos en papel no cambian). Los 4 ejemplos validados antes siguen intactos.
  Tests: día-15 flip a mes venc + test de borde 14/15 + rollover día-15→enero → **458 tests**, analyze OK. Commit
  `927d762`. **✅ RELEASE v0.22.7 PUBLICADO (2026-07-09):** build `-AllTenants` desde sc-test (Mairena + Telenet,
  8 assets en `sitecsa-updates`); v0.22.6 borrado (release+tag); manifests `version:0.22.7`; `main` en Template-TT.
  **Pendiente (iniciativa aparte, EN PAUSA):** audit exhaustivo por tablas — F0 (fundación: tenants/cobradores/
  settings/op_log) corrió como workflow y quedó GUARDADO sin presentar (4 verificadores cortaron por límite de
  sesión en findings de `cobradores`); retomar presentando F0 con mockups y pedir OK para avanzar a F1 (clientes).
- **(2026-07-07 quater) — Colchón indefinidos: no rellenar el hueco de una suspensión larga (0178):**
  Pedido de Rubén ("verificá que el colchón de 3 meses funcione perfecto; vi algunos con 4 cuotas"). **Verificación
  completa (prod + adversarial de 4 mecanismos):** el colchón está SANO — los ~3938 indefinidos activos tienen
  exactamente 3 futuras, 0 duplicados reales, 0 meses suspendidos facturados (INV17=0). El "4 cuotas" es BENIGNO
  (anular un pago adelantado deja una futura genuina que se auto-absorbe; ni se muestra en el header indefinido).
  **1 bug real LATENTE (0 casos en prod):** suspender un indefinido >3 meses y reactivar deja los meses de la pausa
  SIN fila; el generador (Dart + server) los rellenaba como 'pendiente' vencida = deuda FALSA (viola 0120). **Fix
  (Opción B, aprobada):** piso anti-backfill = mes siguiente a la cuota existente más nueva → nunca se generan períodos
  interiores anteriores; generación inicial (0 cuotas) intacta; scopeado a indefinidos (fijos ya inmunes: su hueco
  existe como fila anulada y el ON CONFLICT lo salta). `colchon_indefinido.dart` + migración **`0178`** (CREATE OR
  REPLACE `generar_cuotas_contrato`, sin backfill — 0 afectados). **Verificado en prod (vxxz):** función con el clamp,
  prueba del plpgsql con rollback (no materializa el hueco), INV17/INV11 = 0 · analyze limpio · +2 tests de regresión
  (13/13 del grupo colchón; suite completa **457 tests**). Commits `cab64db` (fix) + `c9877f2` (doc) + `3a44843`
  (bump), `main` en Template-TT. **✅ RELEASE v0.22.6 PUBLICADO (2026-07-08):** build `-AllTenants` desde `sc-test`
  (Mairena + Telenet, 8 assets en `sitecsa-updates`); v0.22.5 borrado (release+tag); manifests `version-<slug>.json`
  con `version:0.22.6`. La migración 0178 YA está en prod.
  **Backlog de invariantes revisado con Rubén (mockups):** eran PRE-EXISTENTES, ajenos al fix del colchón.
  **INV5** = 3 pagos de **Telenet** (real) sin recibo — plata correcta (en caja, cuota pagada), origen app por un
  admin, retro-fechados; causa probable = recibo rechazado al sync por choque de correlativo multi-device (el pago
  sube, el recibo se descarta). **→ RESUELTO (Opción A, aprobada):** regeneré los 3 recibos server-side
  (`SA-00671/672/673`, correlativo recalculado idempotente, `created_at`=fecha_pago); serie SA quedó contigua
  1..675 sin huecos/dups, `telenet_sin_recibo=0`, invariantes re-corridos OK. **INV9** = 1 cuota del **Test Tenant**
  con `cobrador_id` desalineado por anular+reasignar (organizativo, NO plata) → descartable, se deja anotado.
- **(2026-07-07 HOTFIX) — Meses de servicio repetidos/salteados (día de pago 15-16) → v0.22.5:**
  **EMERGENCIA reportada por tenants:** un contrato indefinido con día de pago 16 mostraba los meses
  `Enero, Marzo, Marzo, Mayo, Mayo, Julio, Julio…` en cuotas y recibos (meses repetidos y salteados) + un venc 17/08.
  **Diagnóstico:** la DATA está INTACTA (verificado en prod: 0 cuotas duplicadas, 0 períodos con día≠1; el 17/08 es la
  regla domingo→lunes de `calcular_fecha_pago`, correcta). El bug era SOLO el label: `Fmt.mesServicio` elegía el mes
  con MÁS días de servicio contando el largo real del mes (31/30/28) → con día 15-16 el ganador ALTERNABA mes a mes.
  **Fix (`formatters.dart`):** umbral fijo — día ≤15 → mes anterior; ≥16 → mes del vencimiento. Determinístico, labels
  únicos y consecutivos; mantiene los 4 ejemplos validados y pasa los tests EXISTENTES sin tocarlos (ya documentaban el
  umbral 16; la implementación era la desviada). +1 test de regresión con el caso real → **455 tests**. Sin migración.
  Commits `2bca3a6` (fix) + bump. **✅ RELEASE v0.22.5 PUBLICADO (2026-07-07):** 8 assets en `sitecsa-updates`, v0.22.4 borrado, `main` en Template-TT. Testing del tenant: abrir el contrato indefinido → los meses salen consecutivos (Febrero, Marzo, Abril…) sin tocar nada. Explicado a Rubén con mockup: el mes es DERIVADO (no columna) → por eso el fix no requirió migración ni corregir datos.
- **(2026-07-07) — GUIA-APP.md: guía de usuario visual por módulo (Etapa 1 de 3):**
  Pedido de Rubén (disparado por un tenant que preguntó cómo anular una cuota cobrada por error): **un solo documento**
  `Guia de uso/GUIA-APP.md` con el paso a paso ILUSTRADO de cada módulo (todos los escenarios, admin + cobrador, sin
  super_admin), mockups SVG y búsqueda rápida "¿cómo hago X?". **Arquitectura mantenible:** los mockups NO se dibujan a
  mano — son DATOS (`tools/flows_etapa1.py`) que un generador (`tools/mockups_guia.py`) renderiza a SVG autocontenidos
  (tema claro, GitHub-friendly); cambiar la app = editar el spec y re-correr. **Etapa 1 entregada (núcleo de dinero,
  26 mockups):** Clientes (5) · Contratos (7: crear/header/cambiar fecha/cambiar plan/suspender/reactivar/cancelar) ·
  Cuotas/Cobros (5, incl. **anular y re-cobrar** — el caso del tenant — y fuera de ruta) · Pagos/Recibos (4) · Mora ·
  Cargos/Descuentos (2) · Saldo a favor (2). Cada módulo: tabla de acciones por rol + flujos + FAQ. Regla de
  mantenimiento en AGENTS.md (fila 8b). Commit `00e9472`. **Pendiente:** Etapa 2 (Personal, Visitas, Mapa/Rutas,
  Geografía, Planes, Centro, Avisos, Reportes) · Etapa 3 (Inventario, Tickets, Incidentes, Red, Settings con "a qué
  módulo afecta cada ajuste"). Datos de ejemplo continuos: María Peña Ruíz / Juan López / Básico 10 Mbps C$450.
  **Etapa 2 ENTREGADA (mismo día):** Personal (invitar/editar/forzar password/stats) · Visitas · Mapa y rutas (día/
  ruta offline/vista admin) · Geografía · Planes · Centro de cobranza (tablero + lote) · Avisos/WhatsApp · Reportes/
  arqueo/dashboard — 15 mockups nuevos (41 totales, specs en `tools/flows_etapa2.py`).
  **Etapa 3 ENTREGADA (mismo día) — GUÍA COMPLETA ✅:** Inventario (catálogo/stock/custodia/ficha equipo) · Tickets
  (crear/día del técnico/orden de corte/cobrar desde ticket) · Incidentes · Red · Configuración (4 pestañas + mapa
  "qué ajuste afecta a qué" + lista de funciones gateadas por el dueño). 14 mockups nuevos → **55 totales, 20 módulos,
  706 líneas, 37 entradas de búsqueda rápida** (`tools/flows_etapa3.py`). La guía queda LISTA para compartir con los
  tenants; se mantiene editando el spec del flujo y regenerando (regla AGENTS fila 8b).
  **Rework de FIDELIDAD (pedido de Rubén, mismo día):** los mockups deben ser representaciones IGUALES a la
  app. 4 agentes extrajeron la UI exacta de cada pantalla (labels, diálogos, botones, chips) y los 3 specs se
  reescribieron con esos textos literales (form de contrato sin campo día-de-pago; cambiar-fecha cobra el puente
  en el diálogo; motivos de suspensión exactos; diálogo «Anular pago» textual; chips reales). El generador se
  rediseñó al lenguaje Material de la app (AppBar/pills/diálogos Flutter/tiles/switches/iconos). 55 SVGs
  regenerados. Gotcha reafirmado: a los agentes extractores se les dio el path absoluto del worktree principal.
  **Barrido final «perfecto» (2026-07-07):** replicas 1:1 de composiciones reales (nuevas piezas del generador:
  hero/twobox/kv/btnfull para el sheet del pago — el ejemplo que marco Ruben —, cardrow de Por cobrar con barra
  de color y SegmentedButton) + **explicacion detallada bajo cada uno de los 55 mockups** (que ves, que hace,
  que pasa por detras). GUIA-APP.md = 818 lineas. Datos de prueba unificados CL0102/CT0088/JL.
  **Verificacion 1:1 (Ruben cazo inconsistencias — Editar cobrador no se parecia):** fix raiz = los dialogos
  ahora renderizan campos/switches ADENTRO (items) + 3 verificadores compararon los 55 mockups contra su
  pantalla real (inventado/faltante/composicion/texto literal) -> **43 correcciones aplicadas** (campos
  faltantes, dropdowns vs chips, SimpleDialogs sin Cancelar, textos al literal, renglones reales del arqueo,
  elementos inventados eliminados). Etapa 1 verifico mayormente fiel; personal/mapa-admin/arqueo eran los
  peores y quedaron replica. Pendiente de Ruben: revision final contra la app en vivo.
- **(2026-07-06) — "Cobro extra" gateado por toggle super_admin (default OFF) + release v0.22.4:**
  Pedido de Rubén (urgente): el "cobro extra" / cobro puntual (multa u otro cargo) se mostraba SIEMPRE; debe ser un
  módulo que SOLO el super_admin habilita por tenant, **default OFF**. **Fix:** toggle `cobranza.cobro_extra` (mismo
  patrón que `reportes_detallados`) que gatea **las 2 entradas**: el botón "Cobro extra" del detalle del cliente
  (`cliente_detail_screen`) y el "Generar cobro" del detalle de ticket (`ticket_detail_screen._botonCobro`). Vive en
  Settings → Avanzado → "Reglas de cobro y dinero" → "Cobro extra (multa / otro)". Migración **`0177`** (seed=false en
  los 3 tenants + perform en el trigger de seed, cuerpo 0152 intacto — diff verificado; **aplicada y verificada en prod**,
  todos OFF). Getter `cobroExtraHabilitado` (default false = fail-closed). **Audit adversarial (3 agentes):** el gating
  cierra TODAS las entradas (único path a `crearCuotaManual` es el diálogo gateado; el deep-link `/cobro/:id` cobra
  cuotas EXISTENTES, no crea → no evade); **cazó un bug de ubicación** que introduje (el toggle caía en la tab Cobranza
  'Otros' en vez de Avanzado — faltaba registrarlo en `settings_groups.dart`; corregido). Gates: analyze limpio · **454
  tests**. **✅ RELEASE v0.22.4 PUBLICADO (2026-07-06):** 8 assets en `sitecsa-updates`, v0.22.3 borrado; `main` en
  Template-TT. Testing: el "Cobro extra" ya NO aparece por defecto; el super_admin lo activa desde Avanzado y reaparece.
- **(2026-07-05 quater) — Columna "Fecha de cobro" en el reporte legacy de cobranza:**
  Pedido de Rubén (visual-first: mockups aprobados antes de codear). El "reporte legacy" = la plantilla estándar de
  cobranza (`tipo:'cobranza'`, Excel, "como el cliente lo tenía"; los detallados/modernos se activan con el toggle
  super_admin "reportes detallados"). Se agregó la columna **"Fecha de cobro"** (= `pagos.fecha_pago`, wall-clock local
  Nicaragua, la misma del recibo) **después de "Mes"**, formato solo-fecha. Cada fila del reporte es UN pago → una sola
  fecha por fila (sin ambigüedad de abonos). Cambios: `reportes_admin_screen.dart` (suma `p.fecha_pago` al SELECT del
  caso cobranza — ya estaba en el FROM/WHERE) + `reporte_excel.dart` `construirReporteCobranzaBytes` (header nuevo, corre
  índice de Recibo#/Dólar/Córdoba/Compra-de-Divisas de 4/5/6/7 a 5/6/7/8, totales al col 8, widths 9, helper
  `_fechaCortaDe`). **Sin migración ni schema.** Tests de `reporte_excel_test.dart` actualizados al layout nuevo +
  cobertura de la fecha. Gates: analyze limpio · **454 tests**. Commit `bce369e`. **✅ RELEASE v0.22.3 publicado
  (2026-07-06):** build `-AllTenants` (Mairena + Telenet, 8 assets en `sitecsa-updates`); v0.22.2 borrado; sin migración
  ni sync rules. `main` pusheado a Template-TT. Testing en vivo: generar "Reporte de cobranza" → ver la columna nueva.
- **(2026-07-05 ter) — Audit módulo-por-módulo, FASE 3 (Plataforma + SaaS):**
  Último grupo del audit (dinero=F1, campo=F2, plataforma/SaaS=F3). Workflow de 11 auditores por clúster + verificación
  adversarial (28 agentes) → **12 confirmados** (1 crítico + 3 altos + 4 medios + 3 bajos), 3 plausibles, 2 refutados.
  **Reportes · Super-admin · Planes salieron LIMPIOS** (el núcleo de dinero/tenant). Rubén aprobó "todo lo confirmado".
  Fixes aplicados + re-verificados adversarialmente (8 agentes, 0 problemas):
  - **CRÍTICO seguridad (`348a57d`, migración `0176`):** invitar un `tecnico`/`admin_tickets` los coaccionaba a `admin`
    (escalación de privilegios) — `handle_new_user` (0026) nunca se sincronizó con los roles de tickets del CHECK 0103.
    Fix: whitelist + prefijo para los 3 que cobran. Partido del cuerpo vigente (diff = solo 2 líneas, lección 0151→0152).
    **Aplicado y verificado en prod.**
  - **ALTO auth (`e145498`):** el timeout del 2026-07-04 no cubría `updateUser` del onboarding ni `resetPasswordForEmail`
    (recuperar) → spinner infinito con red colgada. `.timeout(20s)` en ambos.
  - **ALTO/MEDIO datos (`aac7b4a`):** dedup fold-aware en etiquetas (crear/renombrar) y geografía (depto/muni/comunidad,
    scoped al padre) — sin él un nombre repetido se perdía al sync (23505) + atascaba la cola; auto-prefijo del cobrador
    plegado a ASCII (`Ángel`→`AN`, si no la edge function rechazaba la invitación).
  - **MEDIO/BAJO historial (`7bdaa79`):** visita al historial del cliente (usaba `entidad='visitas'` que nadie leía);
    booleanos Sí/No (no 1/0); estados de ticket sin guión; monto no duplicado; `puede_cambiar_fecha` en la allowlist.
  **Gates:** analyze limpio · **454 tests** · re-verificación adversarial 0 problemas. En `main` (`348a57d`,`e145498`,
  `aac7b4a`,`7bdaa79`).
  **✅ RELEASE v0.22.2 PUBLICADO (2026-07-05):** build `-AllTenants` desde sc-test (v0.22.2 synced local) → 8 assets en
  `sitecsa-updates` (Mairena + Telenet, MSIX+APK+manifest+install) → auto-update de prod ACTIVO. v0.22.1 borrado
  (política: solo el vigente). Migraciones `0175`/`0176` ya en prod; sync rules sin cambios. **`main` NO pusheado a
  Template-TT** (origin ahead-behind) — el código de la versión live vive solo local (ofrecer backup a GitHub).
  **Pendiente:** testear en vivo (correr GATE de build fresco → ver `0.22.2` en login; probar invitar-técnico, visita como
  cobrador REAL, etiqueta/geo duplicada, historial Sí/No, tab equipos por rol).
  Gotcha: el 1er workflow de verificación leyó el worktree equivocado (falso "el fix no existe") — se re-corrió blindado
  (prohibir git, solo path absoluto). Memoria [[git-workflow-una-carpeta-main]] actualizada.
- **(2026-07-05 bis) — Audit módulo-por-módulo, FASE 2 (Campo: Red · Inventario · Tickets · Incidentes) + cierre del backlog de nav:**
  Sigue el audit por grupos (Fase 1 = dinero; Fase 2 = campo). Workflow de 20 agentes → 1 ALTO $ + 4 MEDIO. **Fixes:**
  - **ALTO $ doble-cobro (`903df5c`):** el anti-doble-cobro del cobro-desde-ticket era 100% UI reactiva → dos admins/
    devices podían generar 2 cuotas del mismo ticket. Fix: índice UNIQUE parcial `0175` (server, aplicado+verificado en
    prod, inv. 17/17) + re-check DENTRO de la `writeTransaction` de `crearCuotaManual` (mismo device offline).
  - **MEDIO campo (`3055cf3`):** guard de borrado de puerto cuenta solo clientes `activo=1` (inactivo libera la boca) ·
    instalar serial vía ticket emite `op_log` sobre `inv_seriales` (aparece en la ficha) · tab Equipos del cliente salta
    a la ficha del equipo. **Regresión de MI propio fix cazada por el audit adversarial:** gateé el salto con
    `puedeGestionar` (incluye `admin_cobranza`), pero el router le bloquea `/admin/inventario` → tocar un equipo lo
    expulsaba al home perdiendo ficha Y detalle. Corregido: gate por `tieneAccesoAdmin` (admin ∪ super_admin).
  - **MEDIO nav — cierre del backlog 2026-06-30 (`e238832`, regla #12):** rutas del shell admin con `go` no `push`
    (título del AppBar quedaba en el del padre): catálogo + ficha equipo, campos del historial, detalle de incidente,
    tipos + detalle de ticket (tickets condicional: `admin_tickets` usa rutas con Scaffold propio → push) + back-target
    del incidente en `admin_shell`. Se dejan como push (correcto): forms con guard y saltos cross-module a ticket.
  **Gates:** analyze limpio · **454 tests** · audit adversarial (11 agentes) 3 confirmados/1 refutado (el refutado = quirk
  ya aceptado). En `main` (`903df5c`,`3055cf3`,`e238832`), sin pushear/release. **Pendiente:** Fase 3 (Plataforma · SaaS)
  → build v0.22.2 con TODO (auth + Fase 1/2/3).
- **(2026-07-04 bis) — Audit módulo-por-módulo, FASE 1 (núcleo de dinero + conexiones):**
  Rubén pidió un audit módulo por módulo + las conexiones entre ellos (rol/forms/código/UX), para mandar un solo
  update junto con los fixes de login/impersonación. Va por grupos; Fase 1 = núcleo de dinero. Workflow de 28 agentes
  (12 auditores + verificación adversarial) → 11 confirmados, 6 parciales. **Fixes aplicados + auditados (0 problemas
  en el re-audit):**
  - **CRÍTICO $ (`ced791f`):** el crédito por excedente se aplicaba como `cargos_extra origen='credito'` con el ícono
    de basura habilitado en el sheet de la cuota; borrarlo dejaba la fila `saldos_favor` huérfana (FK `SET NULL`) →
    el cliente PERDÍA el saldo a favor (viola inv. #4/#15). Fix: `quitarCargo` excluye `origen='credito'` + candado en
    la UI + etiqueta "Crédito aplicado". Test de regresión que lo fija.
  - **ALTO/BAJO TZ (`7b2363e`):** el lote suspender/reactivar del Centro y el preview del excedente en cancelación
    usaban `DateTime.now()` pelado (device) en vez de UTC-6 → prorrateo corrido un día. Fix: `.toUtc().subtract(6h)`.
  - **3× op_log (`d0d06d2`):** reasignar cobrador (inline en el detalle + masivo — que además decía falsamente "se
    registra en auditoría") y crear geografía inline desde el picker NO emitían op_log (el form completo sí) → gap en
    el historial. Fix: writeTransaction + op_log en los 3, patrón existente.
  - **Puerto de red duplicable (decisión Rubén: aviso forzable):** el ejemplo nodo→cliente — dos clientes podían
    quedar en el mismo puerto sin aviso. Fix: al guardar, si el puerto lo tiene otro cliente ACTIVO, diálogo "ya está
    asignado a X — ¿asignar igual?" (soft, se puede forzar; inactivo libera la boca). Falta la parte de marcar los
    ocupados en el picker → Fase 2.
  **Lo que salió SÓLIDO:** gating por rol, invariantes de saldo cross-pantalla, selectores (SelectorBuscable),
  búsqueda por tokens/fold ñ, streams, guardas de impersonación. **Gates:** analyze limpio · **454 tests** (+1 del
  crédito) · re-audit adversarial 0 problemas. En `main`. **Pendiente:** Fase 2 (Campo: Red · Inventario · Tickets ·
  Incidentes) → Fase 3 (Plataforma · SaaS) → build v0.22.2 con TODO (auth + Fase 1/2/3).
- **(2026-07-04) — 2 bugs de auth/ruteo (spinner de login infinito + flasheo de tenants al impersonar):**
  Rubén pidió revisar a fondo el ciclo de login/sync-gate/impersonación por 2 síntomas: (A) el botón de login gira
  para siempre; (B) al impersonar, flashea `/super/tenants` antes de entrar a `/admin`. **Aclaración del modelo:** el
  sync gate NO hace delta-syncs — PowerSync es el motor de delta-sync continuo; el gate es un semáforo de UI que espera
  a que PowerSync confirme un checkpoint posterior al cambio de identidad (con válvula de escape a 8s). **Revisión:**
  workflow de 7 cazadores + verificación adversarial (53 agentes) → 18 confirmados, 18 refutados (incl. la sospecha del
  deadlock del lock: el `connect` de PowerSync NO se cuelga en la red). **Causas raíz + fixes:**
  - **(A) `78cac9e`:** `signInWithPassword` sin `.timeout()` → si la red cuelga, el Future no resuelve → `_busy` nunca
    baja → spinner eterno. Fix: `.timeout(20s)` en login + diálogo de cambiar password (el `TimeoutException` cae en
    "Sin conexión").
  - **(B) `189b0d4`:** el router leía `impersonating` de la fila LOCAL `super_admin_impersonation` (llega por sync con
    lag) → al entrar (gate abre por grace-8s antes de que baje la fila) flasheaba `/super/tenants`; al salir (exit borra
    en server pero no en local) rebotaba `/admin`. Fix: **estado optimista en memoria** (`PendingImpersonacion`
    entrando/saliendo + `impersonatedTenantEfectivoProvider`) que da el estado real YA. Descartado el fix local-first
    (la tabla tiene PK `user_id`, no el `id` que PowerSync necesita para writes locales).
  - **Regresión cazada por el audit del fix (punto 3):** rutear `estaImpersonandoProvider` por el efectivo apagaba el
    **guard de dinero** en la ventana de SALIR (mientras la atribución cruda seguía en el tenant → cobro huérfano en
    System). Desacople: el efectivo es SOLO para ruteo; el guard de dinero sigue la fila cruda + ON al entrar, nunca
    OFF al salir hasta que la fila real se borre. 6 tests nuevos fijan ese contrato.
  **Gates:** analyze limpio · **453 tests** (447 + 6 del estado optimista) · router redirect 25/25. En `main`, **sin
  pushear/release todavía** (falta build v0.22.2 para testear en vivo). Backlog: secundarios confirmados (doble-connect
  del arranque, transición sin respetar "reducir movimiento", signOut sin try/catch) — no bloqueantes.
- **(2026-07-03 ter) — Bug de des-asignación (0174) + filtro por cobrador en Rutas:**
  **(1) BUG en prod (lo vio Rubén: snackbar "Faltó un dato obligatorio"):** quitarle el cobrador a un cliente
  (`clientes.cobrador_id = NULL`, operación legítima P3b) rebotaba con 23502 si el cliente tenía cargos: el trigger
  0122 propaga el NULL a las 6 tablas denormalizadas y **`cargos_extra.cobrador_id` era la ÚNICA NOT NULL**. Efecto
  colateral: tampoco se podía aplicar cargo/descuento a un cliente admin-managed. Forense por
  `RechazosSyncService` (shared_preferences del device — NO existe tabla error_logs server-side; comentario del
  connector corregido, era "triple rastro" y son 2). **Fix: migración `0174`** (DROP NOT NULL, alineada con sus 5
  hermanas) — corrida y VERIFICADA en prod, invariantes 17/17. Los 2 rechazos de Rubén (Sandra/Carlos) no se
  re-aplican solos: repetir el quitar-cobrador. Sin cambio de app.
  **(2) Feature (pedido de Rubén): filtro por cobrador en Rutas** (`5752f7d`): chip multi-select "Cobrador" (con
  "Sin asignar" y buscador) junto a Municipio; matchea comunidades donde el elegido tiene ≥1 cliente activo
  (`GROUP_CONCAT DISTINCT` en la misma query; filtro client-side/offline; compone con Municipio y búsqueda).
  Mockup aprobado antes de implementar. Audit adversarial: 7/7 OK (GROUP_CONCAT probado en vivo contra SQLite,
  semántica con data sintética; centinela local a propósito — la pantalla dice "Sin asignar" en sus cards).
  Gates: analyze limpio · 447 tests.
  **(3) RELEASE v0.22.1 PUBLICADO** (`e11a42d` bump + docs): `build-release.ps1 -AllTenants` → `sitecsa-updates`,
  8 assets (2 MSIX + 2 APK + 2 `version-<slug>.json` + 2 `install-<slug>.ps1`), manifests apuntan a v0.22.1,
  one-liner HTTP 200, **v0.22.0 borrado** (solo el vigente). Los dispositivos suben de v0.22.0 → v0.22.1 por
  auto-update y ahí llegan el filtro de Rutas + el fix del badge de mora (el fix 0174 ya estaba vivo, es
  server-side). Docs: PRODUCTO §5 (v0.22.1, migraciones 0001→0174) + TESTING §0.3 (checklists de des-asignar
  cliente con cargos, filtro de Rutas, badge de mora).
- **(2026-07-03 bis) — Fix badge de mora + docs al 100% vs schema real (mapa de 44 tablas para agentes AI):**
  **(1) Fix badge de mora (`0670d2a`):** el badge de Cobros del cobrador contaba TODA la mora del tenant pero por RLS
  (`notif_update_marca`) solo puede marcar la SUYA → mora de clientes sin-cobrador dejaba el badge pegado (hallazgo del
  testing en vivo). Ahora `mora_count_provider` cuenta SOLO `cobrador_id = uid` y `_marcarMoraComoVista` se scopea
  igual. **DECISIÓN (documentada a pedido del audit):** la mora admin-managed (cobrador_id NULL) NO la marca vista
  nadie — aceptado: ninguna UI la muestra como no-vista; si algún día se agrega un badge de mora al panel admin,
  revisar. Auditado (adversarial: SQL/params/consumidores/regresiones OK; la reasignación la cubre el trigger 0122
  que propaga cobrador_id a mora no-resuelta) · analyze limpio · 447 tests.
  **(2) Docs verificados contra la REALIDAD (workflow 5 agentes: schema de prod extraído — 124 FKs, 44 triggers, 44
  tablas+RLS — + diff de cada doc):** ~25 gaps arreglados. **ARQUITECTURA (`1674d00`)**: nueva **§3.6.1 mapa EXHAUSTIVO
  por tabla** (44 tablas: FKs entrantes/salientes con regla de borrado + triggers + RLS + SQL de regeneración — la
  referencia "si tocás X, mirá Y" para agentes futuros); árbol de FKs corregido (cargos_extra.pago_id NO es FK — link
  blando 0115; + ticket_id, visitas/fotos_cliente); RESTRICTs de catálogos; denorm cobrador_id = 6 tablas (0122);
  triggers peligrosos (⚠️ `limpiar_cuotas_excedentes` 0023 = DELETE físico al acortar fecha_fin; freeze_rol; guards
  0119); `admin_tickets` corregido a VIVO (verificado en código — un agente lo tenía al revés); sección Centro de
  cobranza; mini-tabla de los 11 buckets de sync. **Sweep (`001f4b3`)**: GUIA-TROUBLESHOOTING reescrita post-0140
  (audit_log→op_log en 7 lugares, dominio saldos_favor completo, 6 números de migración corregidos por grep del último
  CREATE OR REPLACE, "14 filas"→17); MODULOS (+Centro de cobranza, cobro-desde-ticket 0173, etiquetas catálogo-vs-
  asignación); PRODUCTO (números v0.22.0/0173/v17, galería sin "auditoría"); TESTING (smoke sin /admin/audit, 3
  checklists nuevos §0.3); AGENTS ("DEV"→vxxz ES producción); Install Steps (README one-liner, 1-Publicar 8 assets +
  keystore, 3-Android firma release real). **Todo en `main` y pusheado.** El fix del badge queda para el PRÓXIMO
  release (no urgente — mejora, no regresión).
- **(2026-07-03) — RELEASE OFICIAL v0.22.0 publicado + one-liner de instalación en PC nueva + main pusheado:**
  Rubén dio OK al release oficial. **(1) Fix del "problema con el comando" (Opción A):** en PCs nuevas Windows bloquea
  correr `.ps1` descargados (execution policy) — la causa real, no el script (que ya era PS 5.1-compatible y confía el
  cert self-signed solo). Solución: `build-release.ps1` ahora **sube `install-<slug>.ps1` como asset público** del
  release (commit `64c4276`), y el instalar en PC nueva es un **one-liner** en PowerShell admin:
  `irm https://github.com/rubenmaltez/sitecsa-updates/releases/latest/download/install-mairena.ps1 | iex` (bypassa el
  execution policy porque corre texto, no un archivo; baja+confía cert+instala solo). Doc reescrito en
  `2-Instalar-en-PC.md` (one-liner + fallback `-ExecutionPolicy Bypass`). **(2) `main` pusheado a `origin` (Template-TT,
  privado)** — 70 commits; `origin/main..main = 0` (GitHub al 100%). Secretos (`.env.json`/keystore) gitignored, no se
  filtraron; `origin` es privado. **(3) ARQUITECTURA** con nota del sync de tickets al bucket admin_cobranza (`68ba1b1`).
  **(4) Release `build-release.ps1 -AllTenants` (v0.22.0) → `sitecsa-updates`** (público, el que usan las apps): 8 assets
  (2 MSIX + 2 APK + 2 `version-<slug>.json` + 2 `install-<slug>.ps1`), manifest apunta a v0.22.0, URLs del one-liner
  HTTP 200, script servido correcto. **v0.19.0 borrado** (release+tag, política "solo el vigente") → queda solo v0.22.0
  Latest. Los dispositivos en campo (estaban en ~v0.19.0) suben a v0.22.0 vía auto-update. **Nota de firma:** el cert es
  el test-cert pineado del paquete `msix` (thumbprint `028BC99…`, válido hasta 2295) — estable entre releases, se confía
  1 vez por PC. Alternativa futura sin script/warning = comprar cert de firma (~US$200/año); evaluado, no tomado (ver
  mockups de la sesión). **Sin migraciones** (fixes client-side; sync rules ya Active v17).
- **(2026-07-02) — Auditoría Fable 5 por ESCENARIOS (todos los roles · offline/online): 6 hallazgos, los 6 arreglados:**
  Rubén pidió, con Fable 5, "auditoría exhaustiva de toda la app y sus módulos basada en escenarios de lifecycle con
  todos los roles y de la vida real offline/online". Enfoque nuevo: **por escenario/rol** (no por módulo) — encontró
  6 bugs reales de rol/edge/sync que los audits por módulo NO vieron; **el núcleo de dinero salió con 0 hallazgos**.
  **Los 6 (2 ALTO · 4 MEDIO), arreglados (commit `0b4d804`):**
  (1 ALTO) `contrato_detail_screen` — "Cambiar fecha" no tenía los gates que sus hermanos (suspender/plan): ahora
  `!impersonando + estado=='activo' + owner-scope (cobrador solo lo suyo)`. (6 ALTO) `sync-rules.yaml` — bucket
  `todo_tenant_admin_cobranza` no traía `tickets`/`ticket_tipos` → la cola "ya cortados" del Centro quedaba vacía
  para **admin_cobranza**; se agregaron (paridad con admin). (4 MEDIO) `mapa` — el **técnico** ahora ve todos sus
  clientes (`esSoporte |= esTecnico`). (5 MEDIO, DINERO) `contratos_repo` — el revert de crédito por excedente
  inserta un `revertido` **por cuota (con cuota_id)** para que el neteo A8 lo cancele y re-ofrezca el excedente en
  re-suspensión (antes: lump sin cuota_id → excedente indisponible). (2 MEDIO) `cuotas_list` — marcar mora-vista se
  gatea por **rol** (`esCobradorPuro`), no por `adminMode` (era código muerto). (8 MEDIO) `contrato_detail_pagos` —
  `_anular` bloquea al impersonar (atribución). **Re-audit adversarial (Agent)** cazó un **bug bloqueante** en el
  fix de dinero: `aRows.fold<double>` sobre un `aRows` **dinámico** revienta en runtime (`(dynamic,dynamic)=>dynamic`
  no es `(double,Row)=>double`) — reemplazado por un `for` (5 tests de revert crasheaban; ahora verdes). Nota: el
  agente diagnosticó mal la CAUSA (dijo "seed int"), lo confirmé corriendo la suite: el seed no era; era el receiver
  dinámico. **Gates (worktree principal):** analyze limpio · **447 tests** (los 8 de revert incluidos) · **invariantes
  17/17 en prod**. Tweak de build aparte (`ff01a15`, PS 5.1). **Sync Rules REDEPLOYADAS** por Rubén (Active v17 9d1a,
  por el fix #6). Sin migraciones. **En `main` local, NO pusheado.**
  **TESTEADO EN VIVO (2026-07-02, build v0.22.0 MSIX local, Test Tenant, 4 roles reales):** **4/6 fixes confirmados
  end-to-end** (incluidos los 2 ALTO), sin tocar la caja. **A** (Cambiar fecha): visible en activo/oculto en
  suspendido (admin) · oculto en contrato ajeno (cobrador con flag ON → owner-scope puro) · oculto impersonando.
  **B** (cola "Ya cortados"): renderiza como admin Y **como admin_cobranza** (target del fix; antes vacía) — lista el
  contrato real SEED10. **E** (mora-vista): el cobrador marca SU mora (verificado en Postgres `vista_en`+`vista_por`),
  el admin NO marca. **F** (anular): admin real abre el diálogo · impersonando → **snackbar de bloqueo** sin diálogo.
  **C** (dinero): NO live (requiere contrato pagado-a-futuro) — cubierto por 8 tests + invariantes. **D** (mapa
  técnico): NO live — no existe técnico en prod, requiere crearlo + tickets con geo. **Hallazgo aparte (chip
  `task_12059402`):** el badge de mora del cobrador (`mora_count_provider`) cuenta TODA la mora del tenant, pero por
  RLS `notif_update_marca` un cobrador puro solo marca la SUYA → mora de clientes sin-cobrador deja el badge pegado.
  Pre-existente (no del fix E, que mejoró); 3 opciones de fix en el chip. Método fix E: se insertó/borró una
  `notificaciones_mora` de prueba (data restaurada).
- **(2026-07-01) — Pendientes del checkpoint resueltos + TESTEADO EN VIVO + MERGEADO a main (local). Release diferido por Rubén:**
  Se retomó el checkpoint del audit de 6 bloques y se cerraron sus pendientes. **(A) Mora #1 — decisión de
  Rubén: toggle "Ver fuera de ruta"** (off, cobrador+admin) que anexa a Cobros la deuda de contratos
  **cancelados y suspendidos** (recuperación), antes solo visible como badge en Clientes. `cobrosFueraDeRutaQuery`
  (queries activas INTACTAS, #10), sección Recuperación + badge, se oculta "Cambiar fecha"; **cobrar NO reactiva**
  → aviso post-cobro si un suspendido queda en 0 (+ botón Reactivar solo admin). 3 tests. Commit `aaa2706`,
  auditado (workflow 4 lentes + dedicado) → 0 bloqueantes. **(B) Sweep de completitud** (workflow 6 lentes +
  crítico): 4 lentes CLEAN, 2 findings reales **arreglados** (`a377d85`): serial reusado invisible en el picker de
  materiales del ticket (NOT IN scopeado a consumo sin devolución posterior) + botón "Orden de corte" en Avisos
  gateado por rol (admin_cobranza rebotaba a /admin). **1 "bloqueante" resultó FALSA ALARMA:** los cambios de
  estado/reasignación de ticket SÍ se registran en `ticket_eventos` vía el **trigger server `trg_tickets_eventos_auto`
  (0118, verificado vivo en prod)**; un fix client-side se descartó porque duplicaba (lo cazó el re-audit adversarial).
  Backlog aceptado: el técnico offline ve el evento al sincronizar (diseño server-authoritative). **(C) ARQUITECTURA
  actualizada** (fuera de ruta en §Cobros + índice; recibo anulado en R3; menú agrupado Cobranza + form-discard del
  shell en R12). **Gates:** analyze limpio · **447 tests** · invariantes de dinero intactos (nada tocó pagos/cuotas).
  **TESTEADO EN VIVO** (v0.21.11 MSIX local, Test Tenant, Ruby Admin real, no impersonando): fuera de ruta
  end-to-end (display+badges+"Cambiar fecha" oculto+cobro sobre suspendido→recibo+aviso "deuda saldada"+botón
  Reactivar→diálogo); fix #2 serial reusado A/B (0099 reusado APARECE, 0003 sin-devolver OCULTO); fix #3
  "orden de corte" positivo (admin lo ve). **MERGEADO a `main`** (fast-forward, `762f36d`) — **NO pusheado a
  origin** (política backups solo-si-se-pide). **PENDIENTE (release, DIFERIDO por Rubén):** bump versión a
  **≥ 0.21.11** (hay builds locales 0.21.x en la máquina → con menos no actualizaría) → `build-release.ps1`
  desde el worktree PRINCIPAL (path corto + keystore; el worktree profundo rompe MSBuild por MAX_PATH) → borrar
  release/tag anterior (política "solo el vigente"). Sin cambios de DB/sync rules (0172/0173 ya en prod). Artefacto
  de test: cobro RA-00053 (José Antonio) en Test Tenant, anulable.
  **AUDIT EXHAUSTIVO FULL-APP (post-merge, pedido de Rubén):** workflow de 15 agentes Opus (11 lentes high-effort →
  panel adversarial 3-lentes por finding → crítico). **10/11 lentes CLEAN.** 1 finding MEDIO real: el **Excel** del
  reporte de Anulaciones filtraba por `date(fecha_pago)` mientras el **PDF** por `date(anulado_en,'-6h')` (fix
  incompleto de B5 — solo se había actualizado el PDF; el Excel además violaba #1b). **Arreglado** (`b0704e3`):
  Excel alineado al PDF. Gates objetivos: **invariantes 17/17 en prod** (3 tenants) · analyze limpio · 447 tests.
- **(2026-07-01) — Audit completo de la app (código+UI+UX, TODOS los módulos): 6 bloques de fixes — misma rama, CHECKPOINT:**
  Pedido de Rubén: "borrá lo que no se use, corramos un audito completo a nivel de código, UI, UX de TODOS los módulos
  (no solo lo del menú), y que toda la lógica de cobranza/tickets/inventario esté excelente tomando en cuenta el
  lifecycle y los roles; **después** actualizar todos los `.md` y mergear a main". Directiva: "todo tiene que ser
  resuelto, vamos en orden, auditando cada bloque a nivel de código + lifecycle antes de avanzar; te permito tomar la PC
  y probar con test tenant". **Se hizo:** workflow de **39 agentes → 46 findings**, resueltos en **6 bloques**, cada uno
  con **re-audit adversarial** (Agent/Workflow) que repetidamente cazó defectos que el análisis estático NO vio. Cada
  bloque comiteado:
  - **B1** (`cb81a89` nav/gating + `1549985` form-discard): nav y gating por rol (redirects, back-targets del shell);
    **el back-arrow del shell ahora dispara el descarte de forms** (lee `formDirtyProvider` + `confirmDiscardChanges` —
    el `_hasFormGuard` NO disparaba en forms **pusheados** porque el shell no reconstruye `matchedLocation`). Testeado
    en vivo (3 ramas: Descartar→lista / Seguir editando→queda / sección base→home).
  - **B2** (`6723246`): trazabilidad `op_log` (usuarioId) + **guards de impersonación** en settings, recibo-layout,
    ticket-tipos, ticket-detail (estado/reasignar/comentar/checklist/materiales/adjuntos/vincular), incidentes, rutas.
  - **B3** (`71152ef`): correctitud de dinero — `pagos_admin` grupo_vuelto, UTC-6 en cancelación/suspensión, red_admin
    lat/lng `,`→`.`, clamp≥0, **`parseMonto` con `maxDecimales`** (la tasa USD→C$ necesita 6 dec — el re-audit cazó que
    mi rechazo a 3 dec rompía la tasa BCN de 4 dec).
  - **B4** (`7205091`): inventario (búsqueda por tokens en equipos+existencias, alerta de stock **granel-only**
    `es_serializado=0`, stock flows race-safe con try/catch), incidente afectados hub/nodo + confirmación, ticket cancelado.
  - **B5** (`c90a2cd`): reportes — anulaciones UTC-6, **eficiencia por cobrador** re-armada (`LEFT JOIN cuotas ON
    cobrador_id`, `%` con clamp), PDFs (arqueo/eficiencia).
  - **B6** (`351aee1`): **recibo de pago ANULADO** — muestra sello "ANULADO" y OCULTA reimprimir; el re-audit halló un
    hueco **ALTO** en multi-cuota con anulación parcial (se podía reimprimir el ticket VÁLIDO de los pagos hermanos
    vivos) → `contrato_detail_pagos` fuerza el **path single** para anulados → **verificado con workflow de 3 lentes →
    SHIP**. + Centro métrica "A suspender" sin saturar en 50 (`colaCortesTotalProvider`) + `rolLabel`(tecnico/
    admin_tickets)/`moduloLabel` (chips traducidos) + set-password catch humanizado + **borrado dead code**
    (`clientes_list_screen.dart` 591 líneas huérfanas + `rolLabelOrDash`).
  **Gates verdes:** `flutter analyze` limpio (solo 4 `info` de deprecaciones pre-existentes) · **444 tests** · invariantes
  de dinero **17/17** (verificado en vivo antes). **PENDIENTE para la próxima sesión (lo que NO se completó):**
  **(1)** el **sweep final de completitud** (workflow 6 lentes cross-módulo: cobranza/tickets/inventario/regresión-grep/
  roles/UX) NO corrió — pegó el **límite de sesión de la cuenta ("resets 1am", hora Guatemala)**; los 7 agentes murieron.
  Re-correr (script: `.claude/…/workflows/scripts/sweep-final-pre-merge-wf_36395277-9aa.js`) o saltear (la cobertura
  por-bloque ya es sólida). **(2)** **Decisión de producto — mora #1**: ¿la deuda de contratos **CANCELADOS** aparece en
  la lista de **Cobros**? El diseño 0123 dice que sí, pero cambia el workflow del cobrador activo → dejado **sin
  implementar**, espera la decisión de Rubén. **(3)** **Actualizar `ARQUITECTURA.md`** con las recetas tocadas (recibo
  anulado, menú agrupado, form-discard del shell) — BITACORA ya actualizada, ARQUITECTURA falta. **(4)** **merge a `main`
  + release** (build-release.ps1) tras (1)-(3). **NO se mergea a main aún.** Sin cambios de DB/migraciones/sync rules en
  este audit (solo código Dart). Árbol limpio salvo los 3 `windows/flutter/generated_*` (artefactos de build, no tocar).
- **(2026-06-30) — Menú agrupado: cobranza en un solo botón — misma rama:**
  Pedido: el menú del admin se sentía saturado con opciones "repetidas" (4 cards de cobranza sueltas:
  Cobros/Centro/Avisos/Pagos). Tras iterar mockups, decisión de Rubén: NADA de refactor de 5 grupos;
  mantener la galería tipo galería, y **consolidar la cobranza en UN botón "Cobranza"** que abre
  su sub-galería (igual que "Administración"). **Implementado** (`admin_shell.dart`, `router.dart`):
  grupo "Cobranza" en `_adminMenu` (Centro/Cobros/Avisos/Pagos como children) → se van las 4 cards
  sueltas (home ~14→~11). `AdminSubGaleriaScreen`→`SubGaleriaScreen(grupoPath)` genérica **+ pasa
  `esAdminCobranza`** (sin él los hijos `cobranza:true` no se verían para ese rol); `destino` del home
  = `m.path` (cada grupo abre SU sub-galería, ya no hardcodeado a Administración); `_backTargetFor`
  manda el volver de Centro/Cobros/Avisos/Pagos → `/admin/cobranza`; ruta+título `/admin/cobranza`.
  Ambas cards de grupo muestran subtítulo del contenido. **`go`, no `push` (regla #12).** Además, a
  pedido de Rubén se **quitó el teaser "Pendientes de cobranza" del home** (su info está COMPLETA en
  Centro de cobranza) → el inicio queda solo la galería. analyze limpio · 442 tests. **Testeado en vivo
  (0.21.6 test, Mairena):** home con "Cobranza"→sub-galería (Centro/Cobros/Avisos; **Pagos oculto por
  setting off** ✓ gating)→Centro→volver a la sub-galería→volver al home ✓; home SIN teaser ✓. Commits
  `9740385` (grupo) + `2778d29` (quitar teaser). Build **0.21.4+157**. Nota: `pendientes_cobranza_panel.dart`
  quedó sin uso (candidato a borrar). NO se mergea a main.
- **(2026-06-30) — Fix nav: volver desde el Centro abierto por "Abrir centro" — misma rama:**
  Pedido: "al abrir el centro de cobranza por la opción de arriba a la derecha, sigo sin poder regresar al menú
  principal" (el fix de nav del 2026-06-29 arregló el card de galería pero NO este punto de entrada). **Causa raíz:**
  el link **"Abrir centro"** del bloque de pendientes usaba `context.push`; en un ShellRoute, `push` NO actualiza el
  `matchedLocation` del shell (el widget del shell se preserva) → `_tituloFor`/`_backTargetFor` se calculan contra la
  ruta PADRE. Para el Centro pusheado desde `/admin`, eso daba `_backTargetFor('/admin')=null` → **sin botón de volver**
  (trabado). Los cards de la galería ya usaban `go` (por eso ESOS andaban). **Fix:** `push`→`go` en
  `pendientes_cobranza_panel.dart` (1 línea) — era el ÚNICO `push` a una ruta del shell desde el home. **Verificado en
  vivo** (build 0.21.4 de test sobre el paquete `.mairena`): "Abrir centro"→Centro→volver→**Panel admin** ✓ y card de
  galería→Centro→volver→Panel admin ✓. **Quirk pre-existente hallado (backlog, NO tocado):** sub-rutas pusheadas desde
  un padre ≠ home (Catálogo de inventario, detalle de ticket/incidente/equipo) muestran el título/destino-de-volver del
  PADRE (mismo root cause; NO quedan trabadas porque su padre sí tiene botón de volver). Arreglarlo = cambiar esos
  `push`→`go` (cambia semántica de nav → requiere Fase 2). Commit `20c2e6c`. Build vuelve a **0.21.3+156** (el 0.21.4
  fue solo para poder reinstalar el MSIX en la PC de test — mismo código). NO se mergea a main.
- **(2026-06-30) — Audit de usabilidad + batch UX + QA profundo — misma rama:**
  Pedido: "¿hubo audit de UI/UX de cada feature?" → honestamente los audits previos eran de flujo/correctitud, no de
  usabilidad. Se corrió un **audit de usabilidad** (workflow 6 agentes, heurísticas desde la óptica de un admin de
  cobranza no-técnico): bien en lo grande (diálogos guiados, mostrar afectados, defaults seguros), fricción en los
  bordes (íconos sin label, jerga en líneas de plata, un concepto/3 nombres). **Batch de 10 archivos (aprobado con
  mockups):** métricas del Centro uniformes (plata + "N clientes"); colas con título claro ("Ya cortados — falta
  suspender") + verbos "Ver contrato" + badge "· atrasado"; subtítulos en cards del home; "Cobro puntual"→botón con
  TEXTO "Cobro extra" + diálogo "Cobrar multa o cargo"; ticket "Generar cobro" DESHABILITADO-con-motivo + chip
  "Cobrado" tappable al recibo; precio en la lista de tipos; lote con lenguaje claro + fallos con motivo + color de
  advertencia; glosario de jerga (excedente/re-ancla/Topología→Red). **QA profundo (workflow 6 agentes: UX +
  matemática visual pantallas/agregados + reportes + regresión):** matemática SÓLIDA, **cero descuadre de caja**,
  recibos en lockstep, cobros de evento aislados. **1 bug (B1):** "% éxito" de eficiencia por cobrador pasaba de 100%
  (contaba cobros de evento en numerador, no en denominador) → fix: query mensual-pura + clamp 100% (PDF/Excel/global).
  + M-1 (métricas del Centro subestimaban por LIMIT 50 → providers de agregado SIN LIMIT), M-2 (cards desbordaban con
  fuente grande → celda 132→148), M-3 (chip "Cobrado" muerto si recibo null → siempre responde + recibo más reciente),
  M-6 (vencenHoy filtra cl.activo). M-4-reportes/M-5/M-7/M-8/M-9 = backlog (inocuo/edge/cosmético). analyze limpio · 86
  tests · **invariantes 17/17 en 0** con data real. **Testeado en vivo (0.21.2, Test Tenant):** cards del home con
  subtítulos SIN overflow, métricas unificadas (Vencen hoy/En mora/A favor en C$ + "N clientes", A suspender conteo),
  "Ya cortados...", títulos de pantalla ✓. (El dropdown de TIPO de reporte no expandió en computer-use → PRE-EXISTENTE,
  no es de este batch; a investigar aparte.) Commits `d4817aa`(UX)…`5c0f7c1`(QA fixes). Build **0.21.2+155**. NO se
  mergea a main.
- **(2026-06-30) — Cobro DESDE el ticket (instalación/reconexión/etc, ligado al ticket) — misma rama:**
  Aclaración de Rubén del modelo: las cuotas del contrato son cobros a cuotas (mensual); el trabajo de CAMPO
  (instalación/reconexión/reinstalación/anexo) nace en un TICKET y su cobro/recibo va APARTE, ligado al ticket.
  Decisiones (AskUserQuestion): campo→ticket, multa→admin; precio default POR TIPO; cobra admin/cobranza.
  **Implementado (migración 0173 verificada en vxxz):** `ticket_tipos.precio` (>0 = cobrable) + `cuotas.ticket_id`
  (link). Tipos de ticket: campo "Precio del cobro". Detalle del ticket: botón **"Generar cobro"** (gateado
  admin/cobranza no-impersonando, precio>0, resuelto/cerrado; anti-doble-cobro vía stream `_cobroTicket`:
  generar→continuar→cobrado) → diálogo modo-ticket (monto PRECARGADO del precio, concepto = nombre del tipo, sin
  chips) → cobro → recibo **"Ticket #N"**. El botón del CLIENTE quedó acotado a Multa/Otro cargo. El recibo
  (térmica + PDF) ahora OMITE "Período" en cuotas manuales. Archivos: `0173_cobro_desde_ticket.sql`, `schema.dart`,
  `cobro_puntual.dart`(+`tipoCobroDeEfecto`/`kCobroPuntualAdminTipos`), `cuotas_repo.crearCuotaManual`(+ticketId),
  `cobro_puntual_dialog.dart`(2 modos), `ticket_tipos_screen.dart`, `ticket_detail_screen.dart`(`_botonCobro`),
  `recibo_screen/ticket/pdf`, `audit_changelog.dart`. **Audit Fase 4 (3 agentes):** regresión APROBADO · dinero
  APROBADO (`ticket_id` es metadato puro, no toca dinero) · UX 1 fix cosmético (botón al final del Wrap, aplicado).
  Backlog aceptado: índice UNIQUE contra doble-cobro multi-device (mismo límite que oldest-first, sin trigger
  server). analyze limpio · 86 tests. **Testeado en vivo (0.21.0, Test Tenant, admin real):** tipo "Instalación"
  precio 1500 → T-00006 (Ana Lucía) resuelto → "Generar cobro" aparece (oculto sin cliente → confirma el gate) →
  diálogo precargado → cobro → **recibo "Servicio: Instalación / Ticket: #6 / COBRADO 1.500 / RA-00052" SIN
  Período** → el ticket muestra **"Cobrado · 1.500"**. **Invariantes de dinero 17/17 en 0** con la data real.
  Commits `34dfb1f`(feat)…`f535f39`(audit). Build **0.21.0+153**. ARQUITECTURA actualizada. NO se mergea a main.
- **(2026-06-29) — Cobro puntual (cargo de una vez con recibo) + fix de navegación del shell admin — misma rama:**
  Pedido (resurgido): generar COBROS CON RECIBO para cargos de UNA vez
  (instalación, reinstalación tras suspensión/cancelación, anexo, multa,
  reconexión). **Hallazgo (subagente):** el primitivo "cuota manual"
  (`tipo_cargo_manual` NOT NULL, `contrato_id` NULL) ya existía end-to-end
  (cobro/recibo/op_log/invariantes) pero estaba DORMIDO (sin UI desde que se
  retiró `/admin/cuotas`). **Implementado "Cobro puntual"** reactivándolo:
  `CuotasRepo.crearCuotaManual` crea la cuota STANDALONE (op_log alta scoped,
  `cobrador_id` denormalizado, venc=hoy Nicaragua) → enruta al MISMO `/cobro/:id`
  → pago→recibo→correlativo (CERO cambios en la mecánica de dinero; el recibo
  imprime el concepto vía `cuota_descripcion`; venc=hoy no dispara reconexión/
  descuento espurio). Entry: acción en el AppBar del detalle del cliente (gateada
  admin/cobranza, oculta al impersonar). Archivos: `data/utils/cobro_puntual.dart`,
  `features/cobro/cobro_puntual_dialog.dart`, `cuotas_repo.dart`,
  `cliente_detail_screen.dart`. **Fix navegación:** `_tituloFor(location)` en
  `admin_shell.dart` — el AppBar mostraba "Panel admin" en TODAS las sub-pantallas
  (`ShellTitleScope.of` da null bajo el shell → el Centro parecía el home).
  **Audit Fase 4 (3 agentes: regresión / dinero+op_log / UX):** invariantes
  RESPETADOS, sin crash alcanzable ni doble-conteo (cuota `contrato_id` NULL: la
  caja SÍ incluye su pago, el total-de-contrato la EXCLUYE; INV11/oldest-first la
  ignoran por tipo). Fixes aplicados: `parseMonto` canónico, `hoy`→Nicaragua
  (regla #1b), guard del cast nullable en `pagos_repo:576`, exclusión de manuales
  del denominador de eficiencia del cobrador, verbo 'cobro_puntual' en el
  historial. analyze limpio · **86 tests pagos_repo (3 NUEVOS: alta+op_log /
  validaciones / cobro→caja→recibo)**. Commits `1e18cbd`(nav)…`6d6ad99`(fixes).
  Build **0.20.0+152**. ARQUITECTURA §Cuotas + índice actualizados. **Testeado en
  vivo (0.20.0, Test Tenant, admin real):** (1) nav fix — header dice "Centro de
  cobranza"/"Clientes" en vez de "Panel admin" ✅; (2) cobro puntual instalación
  C$1500 → diálogo (5 chips, descripción auto) → cobro → **recibo "Servicio:
  Instalación" / COBRADO 1.500,00 / RA-00051** ✅; (3) **invariantes de dinero 0
  violaciones (INV1–INV17)** con la data real (la cuota standalone no rompe nada).
  Nota menor (backlog): el cobro_screen titula la cuota manual "Cobro de <mes>" por
  el periodo=hoy — cosmético (el recibo sí muestra el concepto). Build local del
  worktree: MAX_PATH en rebuild completo → junction de ruta corta `C:\w`; el MSIX
  se actualizó vía identity `.mairena` solo para testear logueado (pubspec
  revertido). NO se mergea a main.
- **(2026-06-29) — Fase 2 de automatización: recordatorios escalados (niv 2) + lote 1-click (niv 3) — misma rama:**
  **Análisis ultracode** (workflow de 10 agentes: 5 enfoques juzgados) → VEREDICTO contra la intuición: la automatización
  "de verdad" (server suspende/reactiva solo) es el PEOR encaje (esfuerzo XL, riesgo alto/crítico — exigiría re-portar la
  lógica de prorrateo/anclaje a PL/pgSQL — justo lo que el "link liviano" evitó — + pg_cron no puede llamar edge functions +
  romper op_log/offline). GANADORES (cliente, reusan lo existente): **E recordatorios** (score 8) + **B lote 1-click**
  (score 7.5). Rubén eligió "el sistema le facilita al admin, no decide por él". **Implementado niv 2+3:** (1) las 2 colas de
  servicio enriquecidas — fila `ID·nombre / ID·plan / "En mora|Suspendido hace N días"` (badge ámbar >3, rojo >7), ordenadas
  por antigüedad; queries con `cliente_codigo`/`plan_nombre`/`precio_mensual`/`dias_*` (subquery sobre cuota impaga vieja /
  `contrato_suspensiones`). (2) botones **"Suspender/Reactivar los N"** SOLO en el Centro (gateados igual que el individual:
  admin/cobranza, no impersonando) → `lote_servicio_dialog.dart`: confirmación con la lista de afectados + defaults SEGUROS
  (motivo 'Falta de pago', fecha hoy, excedente 'acreditar' — NUNCA devolver/condonar) → loop que llama la lógica Dart YA
  VERIFICADA por contrato (cada uno su writeTransaction → offline-safe, un fallo no tumba al resto) → resumen "X listos, Y con
  problema". Cero servidor/migración/sync rules. Archivos: `colas_servicio_provider.dart`, `cola_card.dart`,
  `lote_servicio_dialog.dart` (nuevo), `centro_cobranza_screen.dart`. **Audit Fase 4 (2 agentes):** apto para producción, 1
  finding (el `-6h` en `dias_suspendido`, ya fixeado); confirmaron que el batch replica EXACTO el flujo individual + el
  `precioMensual` es el precio LIVE (misma fuente que el individual → sin bug de prorrateo) + defaults seguros + regla
  #7/#9/#11. analyze limpio · 439 tests. **Testeado en vivo (v0.19.5):** filas enriquecidas + orden por días OK; "Suspender los
  3" → confirmación → **3 suspendidos** → colas se actualizan solas; "Reactivar los 1" → **1 reactivado**. **Invariantes de
  dinero: 0 violaciones (INV1–INV17)** tras el batch. Commits `11a601e`(feat)…`2444f4e`(audit fix). NO se mergea a main.
- **(2026-06-29) — Centro de cobranza (propuesta A) — misma rama:**
  Evolución del bloque "Pendientes de cobranza" a PANTALLA dedicada (el "home base" del admin_cobranza). Junta todo lo
  accionable, agrupado: **Cobrar** (vencen hoy · gracia · mora) · **Servicio** (suspender · reactivar) · **Créditos a favor**,
  con una fila de métricas arriba. Reusa 4 providers ya existentes (gracia/mora de Avisos, cortes/reactivar de Fase 1) + 2
  NUEVOS: `vencenHoyProvider` (cuotas que vencen hoy) y `creditosFavorProvider` (`saldos_favor` disponible POR CLIENTE — el
  crédito cruza contratos). **Entrada (decisión de Rubén):** card "Centro de cobranza" en la galería + el header del bloque del
  home tappable ("Abrir centro"). Solo navega (Avisos / contrato / cliente); cero dinero/estado. Archivos:
  `data/providers/centro_cobranza_providers.dart`, `shared/widgets/cola_card.dart` (3 builders nuevos),
  `admin/avisos/centro_cobranza_screen.dart`, router, admin_shell, pendientes_cobranza_panel. **Audit Fase 4 (2 agentes):** 2
  findings, AMBOS fixeados — (1, Media) créditos agrupaba por contrato cuando es client-level → `GROUP BY cliente` + navega al
  cliente; (2, Baja) gracia/mora del Centro no gateaban por avisos → "Ver en Avisos" era dead-end con el toggle off → gateado
  como el panel. Resto limpio (SQLite/TZ/regla #9/#11/layout/gating). analyze limpio · 439 tests. **Testeado en vivo (v0.19.4,
  Test Tenant sembrado vencen-hoy/gracia/crédito):** el screen renderiza (métricas + 5 bloques + secciones; reactivar ausente
  por vacío); ambos entry points abren; el bloque de créditos navega al cliente y el monto coincide (500 Centro = 500 "Saldo a
  favor" con botón Aplicar) → confirma el fix client-level. Commits `b73684f`(feat)…`fd82ede`(audit). NO se mergea a main.
- **(2026-06-29) — Testing en vivo (Test Tenant) + FIX del recibo (mora) — misma rama:**
  Rubén autorizó testear en el Test Tenant (`8583a8f0`) con seeds. Se buildeó la rama (v0.19.2→0.19.3), se sembró el escenario
  (orden de corte ejecutada sobre un contrato + mora) y se manejó la app por computer-use como **admin real** (`admin@test.com`,
  no impersonando). **Verificado en vivo:** el bloque "Pendientes de cobranza" (cortes/mora/reactivar), la navegación, el
  encabezado **"¿Qué va a pasar?"** de Suspender, y el **ciclo completo** cortes→suspender→cobrar (4 pagos oldest-first)→**la
  cola "reactivar" se pobló sola**→reactivar; las 3 colas reaccionaron dinámicamente al cambio de estado; la matemática de
  dinero cerró exacto (Recaudado 3.540 / Pendiente 0). **BUG ENCONTRADO Y FIXEADO (producción):** el recibo EN PANTALLA
  listaba en "EN MORA" cuotas YA pagadas. Root cause: el preview leía la mora de `moraContratoProvider`, un
  `FutureProvider.family` **sin `autoDispose`** → cacheaba por (contrato, gracia) toda la sesión y no se refrescaba tras un
  cobro; los datos y cargos del recibo ya eran `ps.db.watch` (vivos) y el path de impresión/PDF usa `fetchMoraContrato`
  (one-shot fresco) → esos NUNCA tuvieron el bug (solo la preview de pantalla). **NO era bug de DINERO** (el cálculo canónico
  siempre dio bien). **Fix** (`9bcc85b`, `lib/features/recibo/recibo_mora.dart`): la mora del preview pasa a
  `StreamProvider.autoDispose` (ps.db.watch) — viva como cargos/datos; el SQL se extrajo a una const única que comparten
  preview e impresión (no pueden divergir) + `max(...,0)` para alinear con la fórmula canónica de consistencia #10. **Workflow
  ultracode:** fix-correctness 0 · **regression-sweep 0 (no hay OTRO `FutureProvider` cacheado con el mismo patrón en todo el
  codebase)** · 1 nit (el `max`, aplicado). `flutter analyze` limpio · 439 tests. **Re-test en vivo (v0.19.3):** con un
  contrato de 3 cuotas vencidas, se pagaron 2 en secuencia → el 2º recibo lista SOLO la cuota aún pendiente, ya no la pagada
  en el 1º. ✅ Confirmado. **Testing cerrado al 100% (misma sesión):** con `ajustes_habilitados` ON en el Test Tenant se
  verificaron en vivo, además — **Descuento** (Paso 1·2·3 + Resultado; aplicado y persistido con actor/fecha), **Cargo**
  (Resultado), **Cambiar fecha** (header "¿Qué va a pasar?" en contrato limpio), y la **integración Fase 1**: Avisos →
  "Orden de corte" abre el form con cliente precargado + contrato auto-seleccionado + guard (hint suave si sacás el contrato
  + confirmación dura "no aparecerá en las colas") + creación de ticket con contrato/efecto. **Autorización de Rubén:**
  manejo TOTAL de data en el Test Tenant (crear/mantener escenarios para futuros testings). **NO se mergea a main todavía**
  — se sigue en la rama hasta terminar todo el testing. **Pendiente menor:** la data de prueba (Gabriela `b3131b8d`,
  Carlos `0e71365f` con un descuento de prueba, Juan Pablo `33e7a451` reactivado, tickets de corte) queda como está.
- **(2026-06-29) — UX del admin_cobranza: bloque "Pendientes de cobranza" en el home (misma rama):**
  Tras un workflow de factibilidad (8 agentes: superficies/gating · flujos de acción · ajustes/crédito · el hueco del "qué
  hacer hoy"), Rubén pidió simplificar el trabajo del admin_cobranza. Hallazgo clave: ve solo 6 cards sueltas sin "qué hacer
  hoy", y — crítico — las 2 colas de Fase 1 (suspender/reactivar) viven en /admin/tickets, ruta que tiene VEDADA → no le
  servían. Recomendación elegida (híbrido C→A, esfuerzo S/riesgo bajo, **puro ENSAMBLE de lo existente**): un bloque
  **`PendientesCobranzaPanel`** arriba de la galería /admin que reusa las colas de Fase 1 + `avisosMoraProvider` (cortes a
  suspender · deuda saldada a reactivar · mora a avisar), cada uno con su botón de próximo paso (navega a /admin/contratos o
  /admin/avisos; **cero dinero** — las acciones siguen gateadas en el detalle del contrato). Se extrajo `ColaCard`/`ColaItem`
  + builders a `lib/features/shared/widgets/cola_card.dart` (DRY tickets↔home). Fix de gating: la card **Avisos** ahora la ve
  el admin_cobranza (flag `cobranza` en vez de `adminOnly`, alineado con el router que ya lo permitía + respeta el setting).
  **439 tests verdes · analyze limpio · audit Fase 4 del bloque: 0 hallazgos.** Commits `1311575`(bloque)…`952575b`. Hecho
  ADEMÁS la propuesta **B (pasos guiados)**: encabezado "¿Qué va a pasar?" en Suspender y Cambiar fecha + pasos numerados
  (1 tipo · 2 cuánto · 3 por qué) y rótulo "Resultado" en Descuento y Cargo (UI pura, cero dinero; el Cargo queda LIBRE sin
  tope a propósito — decisión de Rubén, a diferencia del Descuento que sí valida tope). **Evolución pendiente (a "A"):** Centro
  de cobranza como pantalla dedicada + bloques "vencen hoy" y "créditos a favor sin aplicar" — diferido hasta validar en vivo,
  + testing manual. Diseño completo: workflow `ux-admin-cobranza-simple`.
- **(2026-06-29) — Feature "órdenes de trabajo ↔ cobro/servicio" FASE 1 (rama `feature/ordenes-cobro-servicio`):**
  Tras 2 rondas de factibilidad (workflows multi-agente), Rubén eligió integrar tickets con el cobro/estado de servicio con
  el modelo **"link liviano"** (recomendado) + **taxonomía de dos puertas** (orden de trabajo = técnico al puerto físico;
  cobranza pura = solo plata: mora/anexos NO van por tickets). FASE 1 NÚCLEO construida: migración aditiva **`0172`**
  (`tickets.contrato_id` + `ticket_tipos.efecto` enum ninguno/instalacion/corte/reconexion) **aplicada y verificada en vxxz**
  (sin sync rules nuevas — tickets usa `SELECT *`) + `schema.dart`; **selector de contrato** en el form de ticket (dado el
  cliente lista sus contratos, auto-selecciona si hay uno) + **selector de "efecto"** en el catálogo de tipos; **2 colas
  derivadas** (`colas_servicio_provider`: "cortes ejecutados → falta suspender", "pagaron → falta reactivar") en un
  `ColasServicioPanel` arriba de la lista de tickets (solo shell admin) que navega al contrato. **CERO trigger de plata, cero
  acoplamiento con pagos/cuotas**: el cobro sigue en cobranza y suspender/reactivar siguen MANUALES (el panel recuerda +
  navega). El ciclo corte→pago→reconexión→reactivación anda end-to-end vía el form + las colas. Commits `cace700`(migración+
  schema)…`64f355c`(selectores)…colas. **439 tests verdes · analyze limpio** (solo 4 deprecaciones pre-existentes del
  framework). **Audit adversarial Fase 4: 3 dims limpias (INSERTs · dinero/estado intactos · boundary técnico) + 2 fixes**
  (overflow del panel acotado a 50% con scroll; dedup de cortes por contrato). Hecho además: **guard de contrato** en órdenes
  corte/reconexión (sin contrato no alimenta las colas → avisa) + botón **"Orden de corte" desde la lista de mora** (navega al
  form pre-cargado con el cliente) + **docs** (MODULOS/ARQUITECTURA con la taxonomía + colas). Commits hasta `d44e060` (+docs).
  **PENDIENTE Fase 1:** (opcional) atajo de cobro de instalación — YA cobrable como `cargos_extra 'otro'` desde el detalle del
  contrato — + **testing manual de Rubén** (al final, cuando todo esté implementado). **Fase 2 (diferida):** automatismo por
  trigger SECURITY DEFINER (cerrar ticket suspende/reactiva solo) + gate server "no paga→no reactiva". Diseño completo de ambas
  fases: las 2 entradas de factibilidad (viven en los outputs de los workflows).
- **(2026-06-28) — Auditoría profunda completa + 4 lotes de fixes (rama de trabajo, sin liberar):**
  Audit exhaustivo de toda la app (16 dimensiones × verificación adversarial; workflow de 27 agentes) + 2 checks en vivo
  contra prod `vxxz` (17 invariantes de dinero **0 violaciones** · cobertura RLS/`super_admin_all` **100%**). **0 críticos ·
  0 altos**; el núcleo duro (dinero, SQL, TZ, anclaje, RLS, denormalización, rutas, UI, case-folding, tablas/uniones)
  **limpio**; 8 confirmados (2 medios, 4 bajos, 2 nits) → **los 4 lotes aplicados** (`abea8e7` doc/copy · `236ceda` historial
  data-ops por tenant · `d5e3366` 2 pickers a `SelectorBuscable` in-memory · `f9a600a` op_log en cargos/descuentos + fotos).
  **439 tests verdes · analyze limpio.** Reporte y detalle en la entrada `## 2026-06-28 — Auditoría profunda` (abajo).
  **PENDIENTE:** testing manual (Fase 5) → merge a `main` → liberar (UI/repos, **cero DB/migraciones/sync rules**).
- **(2026-06-28) — Módulo Operaciones: +19 operaciones de Tickets e Inventario (LIBERADO v0.19.0):**
  Rubén pidió construir TODAS las operaciones útiles para Tickets e Inventario (autorización total, sesión nocturna).
  Se implementaron **19** (mismo patrón data-ops: SECURITY DEFINER + `is_super_admin()` + `p_tenant` + preview/
  ejecutar + `data_ops_log`), **migraciones `0156`-`0171`** + `data_ops_screen.dart`: **2 Verificar invariantes**
  (inventario `0156` 8 chequeos / tickets `0157` 7, read-only; `_VerificarInvariantesCard` parametrizado, 3
  instancias) · **5 masivas** (reasignar técnico `0158`, transferir equipos `0159`, cerrar tickets viejos `0160`,
  reabrir `0161`, resolver incidente+cerrar tickets `0162`) · **correcciones** (baja/recuperar serial `0163`,
  reconciliar huérfanos `0164`, ajuste por conteo `0165`, corregir vínculo `0166`/estado `0167` de serial) · **3
  alto riesgo** (corregir SLA `0168`, anular ticket+unwind `0169`) · **2 reversas** (movimiento `0170`/consumo
  `0171`) · **2 exports a Excel** (tickets+inventario). Cards genéricas nuevas (`_ReasignarMasivoCard`,
  `_OpInputCard`, `_AjusteConteoCard`, `_CorregirVinculoCard`, `_CorregirEstadoSerialCard`, `_ExportarCard`, helper
  `_cargarFuente`). **Cada RPC desplegado en vxxz y testeado server-side** (rollback contra el Test Tenant; los 2
  verificar validados contra TODA la data real = 0 falsos positivos). **Auditado** (workflow adversarial 4-dim) →
  **2 bloqueantes fixeados:** (a) `0168` guardaba `created_at` vía tz Managua → SLA +6h (fix: tz UTC, convención
  naive-as-if-UTC, regla 1b); (b) reversa granel `0170`/`0171` duplicable → doble-conteo silencioso (fix:
  idempotencia por `motivo` que embebe el id + selectores que excluyen reversas). `flutter analyze` limpio.
  **De las 21 pedidas: 19 construidas · #21 (stock mínimo) YA EXISTÍA** (campo en catálogo + `inventarioStockBajo
  CountProvider` + badge) · **#14 (re-derivar) NO APLICA** (los afectados se derivan en vivo de la topología,
  `clientes.puerto_id`; nada stale) · **#20 (importar por Excel) sin construir** (feature grande aparte —
  parser+validación+carga masiva, históricamente por SQL; conviene diseñarla con Rubén). Commits `931454a`..
  `2146688` en `main` (pusheado). **OJO de proceso:** la sesión arrancó en un worktree STALE (39 commits atrás);
  se trabajó en el **repo principal** (sobre `main`, donde estaba el trabajo previo + el link de Supabase).
  **Gating por módulo (`e0edc0a`):** las cards de Tickets/Inventario solo aparecen si el módulo está ON
  (`modulosHabilitadosProvider`, mismo mecanismo que el menú). **TESTEADO EN VIVO** (build MSIX `0.19.0` instalado
  sobre Mairena, impersonando el Test Tenant, manejado vía computer-use): panel renderiza sin crashear · las 3
  verificar (dinero 17/0 · inventario detectó 2 INVI1 con IDs · tickets 7/0) · **gating REACTIVO** (habilitar
  módulos → las cards aparecen solas) · SelectorBuscable · input+preview (oculta ejecutar si afectados=0) · y
  EJECUCIÓN real de "Reasignar técnico" (ticket movido + `data_ops_log` OK). Fix de un nit de pluralización
  ("1 ticket", `a6bf616`). **LIBERADO v0.19.0** (`0.19.0+150`) a sitecsa-updates; **v0.18.3 borrado** (política
  "solo el vigente"). Canal puente Template-TT NO republicado (las apps chequean sitecsa-updates, no el puente
  privado). Detalle: ARQUITECTURA §"Operaciones de datos".
- **(2026-06-28) — Módulo Operaciones: starter pack de 3 operaciones (sin liberar aún):**
  Tras un workflow de ideación (5 agentes: Operaciones actual + recetario `Troubleshooting SQL/` + entidades/huecos +
  pedidos históricos) que arrojó un menú de ~19 operaciones en 6 categorías, Rubén aprobó arrancar con un starter pack. Se
  implementaron 3 (todas siguen el patrón data-ops: SECURITY DEFINER + gate `is_super_admin()` + `p_tenant`): **(1)
  Verificar invariantes de dinero** (RPC `0153`, card read-only — corre los 17 invariantes scopeados al tenant; `b0e6eca`);
  **(2) Reasignar cobrador en masa** (RPC `0154`, card con `SelectorBuscable` — UPDATE clientes dispara el trigger 0002 que
  propaga a contratos/cuotas; organizativo, no toca dinero; `2cae45b`); **(3) Restaurar backup** (RPC `0155`
  triggers-off + botón en el historial — re-inserta el snapshot jsonb con `session_replication_role=replica` para no
  duplicar cuotas; `28becd8`). **Migraciones 0153/0154/0155 desplegadas y verificadas en vxxz** (RPCs aditivos, sin efecto
  hasta que un build llame las cards). **TESTEADO EN VIVO** (build local 0.18.4): #1 OK (Mairena REAL: 17/0, libros sanos)
  · #5 preview + ejecutar OK (reasignó 4) · #6 mecanismo server-verified (ciclo borrar→restaurar→verificar con rollback =
  `TODO_OK=t`, cuotas 4→4 sin duplicar). `flutter analyze` limpio. **HALLAZGO del test en vivo → FIX:** al reasignar, el
  trigger vigente (migración **0122**) CONGELA a propósito el cobrador de las cuotas **pagadas/anuladas** (auditoría: quién
  cobró); pero **INV9 no las excluía → falso positivo** tras cualquier reasignación con cuotas pagadas. Investigado a fondo
  (workflow adversarial + empírico: 0 cuotas congeladas en prod hoy = latente; `cuota.cobrador_id` es 100% ORGANIZATIVO — la
  plata agrupa por `pagos/recibos.cobrador_id`, nunca por la cuota): **acotado INV9 a `estado IN ('pendiente','parcial')`**
  en `invariantes_dinero.sql` + RPC `0153` (test: INV9 viejo flaguea 4, nuevo da 0; no enmascara bug — gana precisión).
  **PENDIENTE:** liberar en la próxima versión; resto del menú (las de DINERO: des-anular/mover/corregir pago — diseño+audit
  por op) en próximas sesiones.
- **(2026-06-28) — ✅ CHECKPOINT: v0.18.3 LIBERADO a ambos canales:**
  Release oficial **v0.18.3** (`0.18.3+149`, commit `565387a`) con 3 cambios, todos UI/build (**cero DB, cero migraciones,
  cero sync rules** — la DB ya tenía 0151/0152 de v0.18.2): (1) **tab Avanzado reorganizado en 5 categorías** (`8547bef`);
  (2) **instaladores con nombre branded** por ISP (`Telecable-Mairena-CRM-vX.Y.Z`, `Telenet-CRM-vX.Y.Z`, `b712b9c`);
  (3) **fix `mensajeErrorHumano`** (strip anclado al prefijo `^`, no mangla `SocketException`, `f9fad9d`). Publicado a
  **sitecsa-updates** (público, Latest — manifest→branded→HTTP 200, verificado) + **Template-TT** (puente privado, Latest,
  6 assets; 404 anónimo esperado por repo privado, igual que v0.18.2). **v0.18.2 borrado** de ambos (política "solo el
  vigente"). **Verificado en vivo:** las 5 categorías del Avanzado en la app Mairena instalada. **Fix de cadena cazado en
  el sweep de docs:** los `install-*.ps1` pedían el viejo nombre fijo → ahora resuelven la URL del manifest (como el
  auto-update). Docs al día (BITACORA · ARQUITECTURA · AGENTS · guías 1/2/3 · README · install scripts).
- **(2026-06-27) — Reorganización del tab Avanzado por categorías (`8547bef`):**
  El tab Avanzado del panel admin (super_admin) era un grab-bag: 14 secciones-grupo + 2 cards huérfanas (WhatsApp API,
  Campos del historial colgaban al final) tiradas en una grilla global de 2 columnas que mezclaba dominios. Se reorganizó
  en **5 CATEGORÍAS** con encabezado propio y mini-grilla por categoría: **Reglas de cobro y dinero** (reglas avanzadas,
  ajustes, pronto pago, reconexión, cambio de plan, crédito excedente) · **Permisos y operación del cobrador** (permisos,
  cambio de fecha, foto comprobante, pantallas opcionales) · **Avisos y notificaciones** (avisos + WhatsApp API reubicada)
  · **Visibilidad y reportes** (dashboard + reportes) · **Búsqueda e historial** (búsqueda + Campos del historial
  reubicada). Implementación: nuevo nivel `SettingCategoria` + `kCategoriasAvanzado` en `settings_groups.dart`
  (`kGruposAvanzado` ahora DERIVADO); en `settings_admin_screen.dart` early-return `_buildAvanzadoCategorizado` (itera
  categorías, header `_CategoriaHeader` + grilla por categoría, las 2 cards especiales caen en su bloque). **Cero claves
  nuevas, cero DB, cero migración** — solo agrupación/orden visual. `flutter analyze` limpio · audit 3-dim (render/
  regresión/paridad) **0 hallazgos confirmados** (las 28 claves redistribuidas sin perder ni duplicar). Aprobado por
  Rubén (5 categorías, implementar). Aplica desde la próxima versión.
- **(2026-06-27) — Post-release v0.18.2: limpieza de releases + fix de error + nombres branded:**
  (1) **Limpieza de releases** (política "solo el vigente"): borrados `v0.18.0`/`v0.18.1`/`v0.17.2` de AMBOS canales →
  cada uno queda solo con **v0.18.2 (Latest)**. (2) **Fix `mensajeErrorHumano`** (`f9fad9d`, +test, **438 tests**): el
  strip de `Exception:`/`Bad state:` ahora ancla al PREFIJO (`^(Exception|Bad state): `) — antes cortaba en cualquier
  posición y manglaba `SocketException: …` → `SocketConnection…` (perdía el marcador técnico y mostraba el garabato en vez
  del genérico). (3) **Nombres branded de instaladores** (`b712b9c`: `build-release.ps1` + `branding/*/config.json`
  `releaseName`): a futuro los APK/MSIX salen **`Telecable-Mairena-CRM-vX.Y.Z`** / **`Telenet-CRM-vX.Y.Z`** (guion,
  URL-safe). El asset branded ES el que se sube Y al que apunta el manifest; el manifest `version-<slug>.json` mantiene su
  nombre FIJO → **auto-update intacto**. Verificado con build local `-NoRelease` de Mairena (manifest → `Telecable-Mairena-
  CRM-v0.18.2.msix`). **Aplica desde la PRÓXIMA versión** (v0.18.2 ya salió con los nombres viejos).
- **(2026-06-27) — Feature "Cambio de plan" de contrato (LIBERADO en `v0.18.2`):**
  Cambiar el plan de un contrato manteniendo su vigencia: UPDATE `plan_id` + re-valúa el `monto` de las cuotas FUTURAS
  (anclado al día_pago; el precio vive en `planes`). Dos modos: **Próximo ciclo** (cero plata) y **Hoy con prorrateo**
  (upgrade→`cargos_extra` en la cuota en curso; downgrade→`saldos_favor` R17). Gateado: setting super-only OFF default +
  admin/admin_cobranza (no cobrador, no impersonando); SIN trigger server (server gana, auditado fase 2). **Total del header
  REDEFINIDO a Σ cuotas vivas** (invariante #5). Migraciones `0151` (setting) + `0152` (fix de la regresión del seed-trigger
  que el audit de regresión cazó). Math verificada **al centavo en vivo** (4 escenarios: ±0 ciclo/upgrade/downgrade/bloqueo).
  2 rediseños UX pedidos por Rubén: **diálogo explicativo** (de→a + delta + barra de fechas + resumen "qué cambia/cuándo/por
  qué" + nota de vigencia) y **detalle de pago con desglose** (cuota+cargos = total · cómo pagó · estado · datos del cobro);
  + **buscador siempre visible** en TODOS los selectores DB (`SelectorBuscable`). Bug de layout cazado en vivo
  (`IntrinsicHeight` en Row-stretch-en-scroll, AGENTS #11). **437 tests · analyze limpio · invariantes 0/17.** Receta **R22**.
  Commits clave: `7706ad3`(gate)…`6bf27f7`(audit)…`d46074d`(0152)…`63ab859`(UX2). ✅ **Mergeado a `main` (`d1699c5`) +
  liberado en `v0.18.2`** (`0.18.2+148`, commit `cd8b08b`) a AMBOS canales (sitecsa-updates público + Template-TT puente),
  ambos **Latest**. Migraciones `0151`+`0152` ya en vxxz. **Es UI/gate** (sin columnas/tablas → cero sync rules). Apps de
  los 2 ISP mostrarán el banner "Actualización disponible v0.18.2"; el botón "Cambiar plan" aparece solo si el super_admin
  prende el setting por tenant.
- **(2026-06-27) — Audit de calidad multi-agente + búsqueda por TOKENS + 8 fixes (`ec2d51e`):**
  Audit adversarial (8 dimensiones: lógica, dinero/matemática, entrelazado cross-tabla, SQL SQLite-vs-Postgres, TZ,
  case-folding, UI, UX; cada hallazgo verificado por un agente que intentaba refutarlo). Resultado: **14 brutos → 10
  confirmados (9 únicos) → 4 refutados** (re-flags de cosas ya aceptadas por diseño/código muerto). **Cero crítico/alto.**
  El núcleo (invariantes de dinero, SQL, denormalización en INSERTs, "quién cobró" por `pagos.cobrador_id`, rutas,
  dropdowns #10) quedó LIMPIO. **Mejora pedida por Rubén — búsqueda por TOKENS:** toda búsqueda de texto matchea palabra
  por palabra en cualquier orden ("maria ruiz" → "María Luisa Peña Ruíz"). Implementado en el helper central
  (`busqueda_cliente.dart`: `tokensBusqueda`/`coincideTokens`/`foldSqlTokens` + `busquedaClienteSql`/`Match` reescritos a
  token-AND) → lo heredan las 5 búsquedas de cliente + los ~15 selectores (`selector_buscable`) + `FiltroMultiDropdown`;
  migrados además cobrador-dialog, rutas (comunidad), global-search (recibos), pagos. **Regla en AGENTS §10.** **8 fixes:**
  folding #1d (cobrador/rutas/recibos), cobro_screen try/catch (no más spinner infinito), ticket_form PopScope (no perder
  lo tipeado), `mensajeErrorHumano` en planes/cobradores/cliente, EmptyState "Cliente no encontrado", sparkline 7d base
  UTC-6 (#1b). **`flutter analyze` limpio · 419 tests verdes (+10 de tokens).** **Hallazgo F** (dashboard "recaudado"
  bruto vs neto): por decisión de Rubén se RESOLVIÓ aclarando el doc (AGENTS invariante #4: bruto="cobros del período" ≡
  arqueo bruto; neto=−devoluciones; sin tocar números, `9ff0e2d`). **✅ Pusheado + liberado en `v0.18.1`** (`0.18.1+142`,
  `104996e`) a los 2 tenants en AMBOS canales (sitecsa-updates + Template-TT puente), ambos Latest. UI pura (sin DB).
- **(2026-06-27) — Release v0.18.0 publicado a los 2 tenants (Telecable Mairena + Telenet):**
  Tras mergear Inventario + `SelectorBuscable` a `main`, se publicó el **release v0.18.0** (`pubspec` `0.18.0+141`,
  commit `dbd9b9e`, pusheado). **Es UI pura** — verificado SIN migraciones/schema/sync rules nuevos → **cero deploy de
  DB** y nada que tocar en PowerSync. Build con `build-release.ps1 -AllTenants` desde un worktree de path corto
  (`C:\sc-rel`, evita el MAX_PATH de OneDrive; ya removido + copias de secrets borradas). **Publicado a AMBOS canales
  (puente, como v0.17.2):** `rubenmaltez/sitecsa-updates` (público, canal vigente) + `rubenmaltez/Template-TT` (privado,
  vía `-Repo`, titulado "puente al canal público") — cada uno con los **6 assets** (mairena+telenet: MSIX + APK +
  `version-<slug>.json`) y su `version.json` apuntando a SU propio repo. Ambos quedaron **Latest**. Las apps instaladas
  mostrarán el banner "Actualización disponible v0.18.0". **Pendiente:** instalar/avisar a los 2 ISP (guías `Install
  Steps/2-Instalar-en-PC.md` y `3-Instalar-en-Android.md`); (opcional) limpiar data de prueba del test tenant.
- **(2026-06-26) — Bug de dropdowns en diálogos + `SelectorBuscable` app-wide (rama `Inventario-Tickets`):**
  Testeando el Inventario en vivo apareció un bug real: los `DropdownButton(FormField)` **alimentados por DB DENTRO de
  diálogos** NO commitean su `onChanged` (el menú-overlay `_DropdownRoute` anida mal sobre el overlay del diálogo → el
  display cambia pero el estado del padre queda null y la validación falla). Aislado en vivo: los de **pantalla
  full-screen** y los de **enum estático** SÍ commitean; solo rompe **lista-DB + diálogo**. **Solución:**
  `SelectorBuscable` (`lib/features/shared/widgets/selector_buscable.dart`, `elegirConBuscador`): campo `TextField`
  read-only → diálogo con **buscador en vivo** (`foldBusqueda`, acentos/ñ insensible y simétrico; auto-oculto en listas
  ≤8). **Validado en vivo + verificado en DB:** ingreso granel/serializado (crea serial), movimiento egreso (baja stock),
  catálogo categoría — todos commitean y persisten. **Barrido app-wide (`816b9fd`):** ~15 dropdowns de lista-DB migrados
  (catálogo categoría · tickets tipo/asignado/incidente · ticket-materiales · incidentes nodo/hub/puerto · contratos
  cliente/plan · clientes cobrador · red/geo pickers) + 2 buscadores a `foldBusqueda` (cuotas, pagos). Enums fijos (rol,
  prioridad, método de pago, día…) y `FiltroMultiDropdown` quedan intactos. **Regla uniforme documentada en AGENTS §10.**
  Inventario migrado en `inv_stock_flows.dart` (commits `c932730`→`d0edd64`→`816b9fd`). **409 tests verdes · `flutter
  analyze` limpio.** **Verificado en vivo (2026-06-26):** contrato (cliente hidratado + plan) e incidente (nodo, cascada)
  commitean OK. **✅ MERGEADO a `main`** (merge `5f2bbdb`, sin conflictos de código — solo el doc `MODULOS.md`) +
  ARQUITECTURA documenta el widget en §3 Shared + índice §0 (`cb04af9`). **✅ Pusheado a `origin/main`; rama
  `Inventario-Tickets` + worktree `sc-inv` borrados.** Ya **liberado en v0.18.0** (ver entrada de arriba).
- **(2026-06-26) — Rediseño de Inventario COMPLETO (✅ MERGEADO a `main` 2026-06-26, merge `5f2bbdb`):**
  17 commits (`b6dfa8d`→`7079e45`). El monolito viejo (6 tabs, 2568 líneas, `inventario_screen.dart`) fue **borrado y
  reemplazado** en `/admin/inventario` por una arquitectura nueva:
  - **2 estándares reusables** (`lib/features/shared/widgets/`): `ListaPaginadaScroll` (scroll-windowing + `COUNT` real +
    `dbEpoch`; 4 tests) y `FiltrosBar`+`opcionesDesdeRows` ("todo/nada = sin filtrar `null`" + "Limpiar (N)"; 5 tests).
    + fix #1d: búsqueda de `FiltroMultiDropdown` acento-insensible (`foldBusqueda`) → mejora cobros/clientes/mapa.
  - **Vista operativa** `InventarioV2Screen` (`inventario_v2_screen.dart`, ruta `/admin/inventario`): tabs **Equipos**
    (seriales paginados + filtros estado/producto/ubicación + búsqueda) y **Existencias** (granel, stock derivado del
    ledger + "bajo mínimo") + botón **Catálogo**. (La clase conserva el sufijo `V2` por historia — cosmético.)
  - **Ficha de equipo** (`ficha_equipo_screen.dart`, `/admin/inventario/equipo/:id`): datos + cliente linkeable +
    tickets (vía `ticket_materiales`) + historial + **acciones** asignar/devolver/transferir/baja gateadas por estado.
  - **Catálogo** (`inventario_catalogo_screen.dart`, `/admin/inventario/catalogo`): 4 tabs de master data
    (Productos/Categorías/Ubicaciones/Proveedores), accesible con el botón "Catálogo".
  - **Utils compartidos**: `inv_seriales_acciones.dart` (write-paths de equipo) + `inventario_oplog.dart`
    (`InvError`/`actorOpLog`/`opLogMovimiento`) + `inventario_comun.dart` (labels/colores de estado).
  Proceso: doc-first (R21 + mapa de impacto) → estándares → vistas → ficha → extracción de write-paths → catálogo →
  cierre. **7 audits adversariales** (2 fixes aplicados, resto 0 hallazgos; el refactor de producción verificado con
  equivalencia línea-por-línea vs git). **409 tests verdes · `flutter analyze` sin issues nuevos.**
  **✅ TESTEADO EN VIVO (2026-06-26, vía computer-use)** — flujo inv↔tickets↔cliente de punta a punta OK (catálogo,
  ficha, Asignar, linkage bidireccional, consumo en ticket). **3 findings arreglados** (`492eb5c`): **F2** (faltaban
  Ingreso/Movimiento — re-agregados desde git a `inv_stock_flows.dart` + FABs), **F1** (empty-states), **F3** (back de
  catálogo/ficha). Re-testeado en vivo OK (Ingreso/Movimiento commitean y persisten). **✅ en `main`** (merge `5f2bbdb`).
  `docs/PROPUESTA-INVENTARIO.md`.
- **(2026-06-24) — Auditoría de continuidad de release + hardening del pipeline (`7bdc0af`):**
  Workflow de 7 agentes verificó que el próximo update llega bien a los clientes: **firma Android** (storeFile
  RELATIVO → inmune a mover carpeta), **identity Windows MSIX** (Publisher/PublisherId idénticos entre
  versiones/tenants) y **auto-update** (→ repo público `sitecsa-updates`) **OK, 0 bloqueantes**. El incidente
  histórico "certificados al cambiar de carpeta" NO era Android: era el MSIX con `certificate_path` atado a ruta
  (ya removido el 2026-06-09) → hoy mover la carpeta NO rompe firmas. Gotchas reales: instalar SIEMPRE por
  `install-<tenant>.ps1` (confía el cert) + MAX_PATH bajo OneDrive (rompe el BUILD, no la firma). **Hardening:**
  (1) `version.json` download_url Template-TT (privado) → `sitecsa-updates` + v0.17.2; (2) rama genérica de
  `build-release.ps1` reescribe download_url desde `$ghBase` (self-healing); (3) `msix` pin 3.16.13 + `publisher`
  (DN) explícito en `msix_config` = Subject del test cert → identidad de firma estable ante bumps del paquete.
  **Backup cifrado** (.7z AES-256: jks+key.properties+.env.json) en `C:\Users\ruben\sitecsa-key-backup\` (fuera de
  OneDrive → mover a pendrive/vault). **Git consolidado:** 1 sola carpeta (worktree principal) + `main`; borrados
  worktrees/ramas viejos + release/tag v0.17.1 + tags locales viejos. **Pendiente:** confirmar el `publisher` MSIX
  en el PRÓXIMO `build-release.ps1` (si `msix:create` falla por mismatch, revertir esa línea de `pubspec.yaml`).
- **(2026-06-24) — Releases a REPO PÚBLICO SEPARADO (para poder hacer privado el código) → v0.17.2,
  `main` @ `3460582`:** Repo público nuevo **`rubenmaltez/sitecsa-updates`** (solo instaladores, SIN código).
  Repuntados al público: `update_service` (de dónde baja la app), `build-release.ps1` (param **`-Repo`**, default
  `sitecsa-updates`, `--repo` en los `gh`) y `install-mairena/telenet.ps1`. **v0.17.2 publicada en AMBOS repos:**
  en `sitecsa-updates` (canal futuro) y en `Template-TT` (**PUENTE** — mismos binarios, `version.json` apuntando a
  Template-TT — para las apps en v0.17.1). **✅ `Template-TT` (CÓDIGO) YA ES PRIVADO (2026-06-24):** nadie clona la
  app; los releases van por `sitecsa-updates` (PÚBLICO). Se pudo hacer ya porque los clientes AÚN NO tienen la
  versión nueva (solo los 2 equipos de Rubén) → reciben la v0.17.2 vía el script + APK (que ya apuntan al público).
  **Único re-install pendiente: los 2 equipos de Rubén (PC+tel)** tenían v0.17.x apuntando a Template-TT (ahora
  privado) → reinstalar la v0.17.2 del repo público. (`install-latest.ps1` + los `.md` quedaron apuntando a
  Template-TT: build genérico deprecado / clone del código — ya no se usan para distribuir.)
- **(2026-06-24 PM) — AUDITORÍA INTEGRAL de 12 módulos + lote de fixes (en `main`):**
  Workflow adversarial (24 agentes: 12 auditan + 12 verifican) revisó la lógica y las uniones de cada módulo
  offline/online. Resultado: **43 uniones OK · 8 falsos positivos descartados · 1 ALTA + 7 MEDIA + 18 BAJA
  reales.** **ALTA (dinero) ARREGLADA (`5fa1e3c`):** `cuotas_repo.totalACobrar`/`_recalcularCuotaLocal` no
  restaban `credito_aplicado` → sobre-cobro; ahora resta (como el server) + espejo vmv en esos flujos, +1 test.
  **MEDIA/BAJA arregladas (`7e02b76`):** geo pre-check de duplicado offline, op_log al crear contrato,
  `puede_cambiar_fecha` con op_log + filtro tenant, hora Nicaragua en cargos auto, +6 comentarios/doc stale.
  **Documentadas como decisión aceptada (offline-first / intencional, NO bug — backlog "no urgente"):**
  reasignar cobrador offline (R15, self-heal), contrato offline sin cuotas, correlativo mismo-cobrador-2-devices,
  dashboard bruto vs arqueo neto, filtro mora, recovery por email, etc. **400 tests verdes · analyze sin issues
  nuevos.** Reporte + mockups del entrelazado entregados en chat. **✅ RELEASED v0.17.1** (`bff24b9`): el fix
  del sobre-cobro + el lote viajan por el canal de update branded → los equipos con la app branded se
  autoactualizan solos. (Los que aún tengan la app vieja genérica reciben el fix al migrar a la branded.)
- **(2026-06-24) — WHITE-LABEL por tenant (Opción B) + 2 fixes del mapa, ✅ RELEASED v0.17.0,
  validado en vivo (Windows):** Cada ISP instala la MISMA app con su **ícono, nombre** (APK + instalador
  Windows) y **logo en el login**. **2 tenants:** Telecable Mairena S.A. (`com.sitecsa.crm.mairena`) y
  Telenet (`com.sitecsa.crm.telenet`). Mecánica: `branding/<slug>/` (config.json + logo.png) +
  `tool/aplicar_branding.dart` (ícono cuadrado **forma A** = logo centrado en blanco, recortando margen
  transparente; + copia el logo del login — ambos desde el PNG del tenant) + `build-release.ps1
  -Tenant/-AllTenants/-NoRelease`. Cada app trae su **canal de update propio** (`version-<slug>.json`; el slug
  se hornea con `--dart-define=TENANT` y lo lee `update_service`). Branding **100% cosmético** — RLS sigue
  aislando (un user de Telenet en la app de Mairena solo ve SU data; sin tenant-lock por decisión). Detalle:
  **ARQUITECTURA Receta R20**. **MIGRACIÓN de equipos existentes (1 sola vez):** el paquete es nuevo → la app
  branded instala AL LADO de la vieja (genérica `com.example.isp_billing`); proceso: sincronizar la vieja →
  instalar la branded → verificar → desinstalar la vieja. De ahí en más auto-update in-place, sin reinstalar
  nunca más. **Rubén distribuye los instaladores a los clientes.** **Mapa (2 fixes):** (1) `recalcVmvDeContrato`
  (espejo offline del color del pin) extendido de SOLO-cobro a los **10 flujos** que mutan cuotas/estado
  (suspender, cancelar, cambiar-estado, reactivar, revertir×2, aplicar-crédito, anular, editar-pago,
  cambio-fecha) — money-safe, +2 tests; (2) el empty state ofrece **"Ver todos los clientes"** cuando el filtro
  cobrables queda vacío (un tenant sin contratos ya NO queda sin mapa; antes el empty state tapaba la barra de
  filtros). **399 tests verdes + analyze limpio.** Commits `48d0afc`/`d6968eb`/`03aacbd`.
- **(2026-06-23 PM) — lote de PERFORMANCE (Clientes + Mapa), `main` @ `11725ef`, ✅ RELEASED v0.16.0
  (Latest en GitHub, auto-update disparado, v0.15.0 borrado por política), validado en vivo con Mairena (4.606):** **Clientes:** lista PAGINADA (agrega solo la
  página visible ~60, no los 4.606) + spinner (no más "Sin clientes" mientras calcula) + **contador del total REAL**
  ("4.281 clientes" en vez de "60+", misma query que "Seleccionar todos") — `0bfe8ed`/`e2aad54`/`8720c4c`, `Fmt.entero`.
  **Mapa:** **(A)** default = solo cobrables (~154 vs 4.442 pines, filtro de fecha) + **(C)** spinner; **Opción 2** —
  el estado/color de cada pin sale de `clientes.vencimiento_mas_viejo` (FECHA de la cuota pendiente más vieja,
  precalculada por trigger server + mirror offline) en vez de cruzar 4.442 × cuotas → **"Ver todo" de ~16-19s a ~3s**;
  `_estadoDe` + color del setting `coloresEstados` INTACTOS (se guarda una FECHA, NO un color — no se hardcodea nada) —
  `2f402fa`/`f2bbb22`/`f0564cb`. **Migración 0150** (columna + 2 triggers `cuotas_vmv`/`contratos_vmv` + backfill) **YA EN
  PROD `vxxz`** + verificado **estado precalc == vivo, 0 mismatches / 4.442**. **SIN redeploy de sync rules** (`SELECT *`
  + backfill la sincronizan sola, confirmado en vivo). Audit adversarial: consistencia probada algebraicamente, sin
  riesgo de invariantes (vmv solo LEE cuotas, escribe `clientes`); + fix crash cobro de cargo manual (`9d93c8f`).
  **Límite v1:** el mirror offline cubre el COBRO; suspender/cambio-fecha/anular offline → color stale hasta sync (lo
  corrige el trigger online). analyze limpio. **Pendiente: prueba offline manual de Rubén + monitorear Data Synced.
  INV2/11/12 prod = 1 c/u → CONFIRMADAS en Test Tenant (data de prueba); Mairena/Telenet limpios → cerrado, no era de esta feature.**
- **(2026-06-23) — lote de 4 mejoras visuales, rama `claude/youthful-mahavira-d0b46e` (desde `main` v0.14.1),
  TODO commiteado + auditado:** **#1 colchón de indefinidos a prueba de offline** (`35fae3d`+`87d58d9`): espejo Dart
  `asegurarColchonIndefinido` (corre al COBRAR, NO al crear — colisionaba con el trigger server) + función server 0148
  (ancla `max(última pagada/parcial, mes actual)+3`, piso 3) + backfill + invariante **INV17** + 8 tests. **0148/0149
  YA EN PROD `vxxz`; INV17=0; el único indefinido roto quedó curado.** **#2 detalle del cobro** (`2f69b04`): texto más
  grande + "Cobro" en vez de "Cuota". **#3 buscador + filtro municipio en Rutas** (`0fcb331`). **#4 cobrador comparte
  vista admin** (`df0648b`+`f80a34c`): ve y COBRA todos los clientes del tenant en Cobros/Mapa/Clientes (RLS 0149 en
  prod; "Cambiar fecha" owner-scoped; `contrato_suspensiones` al bucket); NO edita. **+ Clientes con paridad de filtros**
  (`71fde9c`): la `/clientes` del cobrador usa `ClientesAdminScreen(soloLectura:true)` — mismos filtros que el admin,
  sin Nuevo/Export/reasignar. **✅ RELEASED v0.15.0** (`538bc6e`, tag/release **Latest** en GitHub, MSIX+APK+version.json;
  **v0.14.1 borrado** por política). **Sync rules tenant-wide DEPLOYADAS y Active** (version 16) por Rubén. **Validado
  en vivo** (build local v0.15.0, cobrador real de Test Tenant): #2 "Cobro de Junio" grande · #4 Cobros con dropdowns
  Cobrador/Zona + "Ver todo" (el dropdown lista TODOS los cobradores) · "Cambiar fecha" solo en clientes propios ·
  Clientes con los 5 filtros admin read-only. ⚠️ **VOLUMEN** (las sync rules aplican a TODOS los tenants): monitorear
  Data Synced de PowerSync; si Mairena pega fuerte, revertir o flag por-tenant + acelerar self-host. **Pre-existentes
  prod: INV9 (Mairena, denorm `cobrador_id`) ARREGLADO** (UPDATE re-sync, INV9=0); INV2/11/12 (Test Tenant, data de
  prueba) quedan. Suite **397 verde** · analyze limpio.
- **(2026-06-22) — `feature/super-admin-data-ops` @ v0.14.1, listo para merge+release:** trae el módulo
  **"Operaciones de datos"** del super_admin (corregir errores de carga: limpiar/eliminar cliente o contrato, con
  **preview + confirmación por código + backup restaurable + log**; migraciones **0146/0147 YA en prod `vxxz`**, 2
  tablas server-only que NO se sincronizan → sin redeploy de sync rules) + el **fix de búsqueda con ñ/acentos**
  (bug de PROD: clientes con ñ en el código eran invisibles; `foldBusqueda`/`foldSqlExpr` pliegan ambos lados a ASCII —
  **regla 1d** en AGENTS) + **placeholder de búsqueda dinámico** + **chip de código de contrato removido** de la
  tarjeta de cliente + **diálogos de invitar responsive**. `analyze` limpio + suite verde + audit adversarial de
  data-ops (5 fixes). **PENDIENTE: merge a `main` + release** (orden de deploy ya satisfecho — las migraciones
  corrieron en prod; el build/release sale después del merge). Detalle abajo (entrada 2026-06-22 v0.14.1).
- **(2026-06-21) — RELEASE v0.12.2: reportería plantilla + historial cliente + rework de filtros (TODO en
  `main`, validado en vivo por Rubén):**
  **(A) Rework de reportería** (`38810d8`): default = plantilla "Reporte de cobranza" (Excel); los reportes detallados
  se ocultan tras el toggle super_admin `cobranza.reportes_detallados` (Avanzado, OFF, migración **0141 en prod**).
  **(B) Historial de pagos por cliente** (`6dc892e`): PDF imprimible desde el detalle del cliente (admin/admin_cobranza),
  rango fijo (12m / este año / año pasado), datos + tabla de pagos de todos sus contratos + total.
  **(C) Rework de filtros (Clientes + Cobros + Mapa):** "Sin cobrador" DENTRO del dropdown de Cobrador (se quitó el
  toggle) · en Clientes, **Estado de servicio** multi (Al día/Gracia/Mora/Suspendido c-deuda/Cancelado c-deuda/Sin
  contrato) + **Activo/Inactivo** binario + badge **"debe C$X fuera de ruta"** (deuda de suspendidos/cancelados, antes
  invisible) · regla Y-entre/O-dentro · **nunca-vacío** (deseleccionar todo = todos) · **Limpiar (N)** + empty state
  inteligente · **Mapa con clustering** (paquete `flutter_map_marker_cluster`) para ~4000 pines. Helper
  `construirFiltroClientes` centraliza el WHERE (consistencia #10).
  **Las 3 auditadas** (workflows adversariales, findings LOW; fix de clustering `markerChildBehavior` aplicado) +
  `flutter analyze` limpio + **361 tests OK** + validadas en vivo. **Release oficial v0.12.2.**
- **👉 ESTADO (2026-06-21) — lote de 4 features en curso:** **Dashboard nuevo** (proyecciones por cobrador +
  secciones del Resumen toggleables por super_admin, migración 0133) **mergeado a `main`** (sin release todavía).
  Después se abrió un **lote de 4 features** en la rama `feature/cobros-pagos-avisos` (desde `main`), con
  **mockups aprobados por Rubén** (Fase 2): **(1) Cobros en 1 fila por contrato** · (2) historial de pagos en la
  ficha del cliente · (3) pantalla **Avisos** (gracia/mora, toggle super_admin) · (4) **notificar por WhatsApp**
  (`wa.me` Fase 1, manual; templates editables por admin). **Feature 1 DONE + mergeado a `main`**: la lista de
  Cobros pasó de tarjeta-por-cliente-con-desplegable a **una fila plana por contrato** (cuota más vieja), con
  plan·mes·fecha·estado + saldo + Pagar/Cambiar-fecha inline, **tap→ficha**, y chip **"+N cuotas · C$X más"**.
  `cobrosFlatQuery` reusa el CTE `lineas` → **consistencia #10 blindada con test**; audit adversarial (3 agentes)
  sin bloqueantes; **validado en vivo** (build 0.11.11.x local en Test Tenant con data PROY). **La v0.12.0 sale
  cuando cierren los 4.** Plan completo: memoria AI `features-plan-cobros-pagos-avisos-whatsapp`.
  **Feature 2 (historial de pagos READ-ONLY en la ficha del cliente, agrupado por contrato) DONE + mergeado a
  `main`.** **Feature 3 (pantalla Avisos: clientes en gracia/próximos a corte + en mora, ítem de menú gateado por
  toggle super_admin `cobranza.avisos_habilitado`, migración 0134) DONE + mergeado a `main`.**
  **Feature 4 (notificar por WhatsApp `wa.me` desde Avisos: botón por cliente + flujo "a todos", plantillas
  editables por admin, toggle super_admin `cobranza.notif_whatsapp_habilitado`, migración 0135) DONE + mergeado a
  `main`.** ✅ **LOTE DE 4 FEATURES COMPLETO.**
- **(2026-06-21) — WhatsApp por API (modo PAGO, opt-in) CONSTRUIDO y DORMIDO, MERGEADO a `main` +
  UI REDISEÑADA (reveal-gated) en `feature/whatsapp-api-ui`:** convive con el modo gratis (`wa.me` manual de Avisos). Es el
  envío AUTOMÁTICO por lote vía Cloud API de Meta, configurable en **Avanzado (solo super_admin)**: toggle + Phone
  Number ID + Access Token (server-only) + nombres de plantillas + idioma + hora + frecuencia + tope + botón
  "Probar". Migraciones **0137** (9 settings `cobranza.notif_api_*` + tablas `whatsapp_credenciales` server-only y
  `whatsapp_envios` log) **+ 0138** (función `whatsapp_clientes_a_notificar`) **YA en prod `vxxz`**. Edge functions
  `whatsapp-set-token` + `whatsapp-enviar` (uno/lote) escritas, **SIN deployar** (Dashboard manual). **Probado por
  SQL:** settings, tablas, elegibilidad gracia/mora + dedup por frecuencia. **NO probado (no tengo cuenta Meta ni la
  card es visible como admin):** Meta real, botón Probar, cron, la card super-only. **Audit 2-agentes:** UI sin
  findings; seguridad 5 no-críticos (3 fixeados, 3 documentados). **DORMIDO hasta el setup de Meta** (guía:
  `Install Steps/WhatsApp-API-setup.md`). Commits `feature/whatsapp-api`: feat + fix de audit.
- **✅ RELEASE v0.12.1 PUBLICADO (2026-06-21):** `0.12.1+122`, tag/release `v0.12.1` (Latest) con MSIX + APK +
  version.json. **APK release-firmado verificado** (SHA-256 `28fe94…0ed04`). **Sin wipe de DB.** v0.12.0 trajo
  dashboard 0133 + 4 features (0134/0135) + WhatsApp API (0137/0138/0139, DORMIDO); **v0.12.1 = eliminación
  completa de `audit_log`** (0140 corrida + verificada en prod: 0 triggers, tabla dropeada, op_log intacto).
  Release/tag v0.12.0 BORRADO (política). El modo API sigue apagado hasta el setup de Meta de Rubén.
- **Producción (`vxxz`) al día:** release **v0.12.1** publicado; migraciones **0133-0140** corridas (audit_log
  ELIMINADO en 0140), **invariantes de dinero en 0**, **sync rules Active v13** (audit_log fuera de los buckets; las settings
  nuevas son filas de una tabla ya sincronizada). Nada pendiente de deploy salvo, cuando Rubén active la API: las
  2 edge functions de WhatsApp + el cron (manual en Dashboard). Backlog vivo abajo (#2/#3 DIFERIDAS).
- **Git:** **`main` al día** (release v0.11.10 + **dashboard 0133** + **lote de 4 features: Cobros 1-fila + historial de pagos + Avisos 0134 + notificar WhatsApp 0135**; `origin/main` pusheado). Rama `feature/cobros-pagos-avisos` lista para borrar (lote cerrado).
  **Rama de trabajo activa: `feature/cobros-pagos-avisos`** (desde `main`, lleva los 4 features del lote; se mergea a
  `main` por feature y se borra al cerrar el lote). **GitHub tiene SOLO `main`** + el release v0.11.10. Worktrees locales vivos: **principal** (`main`, OneDrive — git OK pero build falla MSB3491),
  **`C:\sc-changelog`** (build/test, ruta corta, con `.env.json` de producción), **`C:\sc-contratos`** (build/test)
  y el de la sesión activa. **Acceso AI** (AGENTS §"Acceso del AI"): `supabase db query --linked` a `vxxz` + `gh` +
  PowerShell directo; solo las sync rules de PowerSync requieren a Rubén.
- **⚠️ PROD = `vxxzesbmilfolwjhfxgr`** ("Template TT"): es la base LIVE a donde apunta el `.env.json` del release y
  se conectan los usuarios reales (confirmado por Rubén 2026-06-20). El AGENTS lo llamaba **"DEV" por ERROR** —
  tratá sus cambios como producción. **NO hay una 2ª base PROD aparte** (existe `scqxraueqtbsgzkjzoyk` "TT's
  Project", propósito sin confirmar, NO es a donde apunta el release). El viejo "🚨 PELIGRO deploy a PROD" queda
  RESUELTO: como `vxxz` ES producción, las migraciones ya están aplicadas ahí.
- **Versiones:** último release a producción **0.12.1+122**; rama de trabajo **0.14.1+131** (NO releaseada todavía:
  data-ops + fix búsqueda ñ; pendiente merge+release) · PowerSync **schema in-place** (DB wipe v1; el aditivo
  ya no re-descarga — fix #1; ningún cambio de la rama tocó schema.dart → sin wipe) · producción (`vxxz`) con TODO el
  schema (incl. migraciones **0146/0147** de data-ops) + invariantes 0 + sync rules Active.
- **🔧 HOTFIX post-release 2026-06-20 (Android):** el 1er APK de v0.11.10 quedó firmado con la DEBUG key (lo compilé
  desde `sc-changelog`, que NO tenía `key.properties` + `sitecsa-release.jks` — gitignored, viven SOLO en el worktree
  principal) → Android rechazaba el update ("no instala"). Fix: copié la llave a `sc-changelog`, recompilé (firma
  release `CN=SITECSA DEV`, SHA-256 `28fe94…ed04`, verificado con apksigner) y re-subí el APK. `build-release.ps1`
  ahora ABORTA si falta `key.properties`. **Para releasear, el worktree de build necesita 3 secretos gitignored:
  `.env.json` + `key.properties` + `sitecsa-release.jks`** (memoria AI `android-release-keystore-firma`). Windows/MSIX
  NO está afectado (cert de test bundleado del paquete `msix`, igual en todo worktree). **CI quedó VERDE** (commit
  `ae6adef`: 4 lints `unnecessary_non_null_assertion` + falso positivo `date_trunc` en un comentario; ambos checks
  eran rojos hace rato, no los rompió el release).
- **HECHO esta sesión (2026-06-19, en `ui-improvements` @ `ebbbdbe`, schema v33) — TODO validado en vivo:**
  **Cold-start** (`a091858`): `_CobrosList` es ConsumerStatefulWidget + recrea su stream con `dbEpochProvider`,
  `conexionRealProvider` arranca optimista → fin del "ClosedException" en Cobros y del falso "Sin conexión" al
  recrear la DB por cambio de schema. **Rediseño de Cobros compacto + escala** (`df3d8f0`/`56735ed`/`94bccd2`): una
  **tarjeta-resumen por cliente** agregada en SQL (`cobros_query.dart`, Dart puro + test `cobros_resumen_test.dart`,
  8 casos vs SQLite real); se expande para ver/pagar por contrato; total = **cobrable ahora** (cuota más vieja por
  contrato); "Ver todo" escala a miles; buscador con debounce 250ms. **Chips de claridad** (`bfe768c`): "N cuotas
  vencidas · debe C$X" + "Parcial · abonó C$X de C$Y". **Lista de Clientes admin COMPLETA** (`8d99dc2`, sin "Cargar
  más"; la del cobrador sigue paginada). **Índice** `by_contrato_vencimiento` (v32→v33). `analyze` limpio · **suite
  340 verde** · audits Fase 4. **Validado en vivo (release v33 local, admin real):** cold-start · lista compacta +
  expandir + multi-contrato · scroll a 220+ clientes · chips · geo random en el mapa · **Reactivar D/A/B/E (los 4
  pasaron)** — D: jul prepagado quedó 900 NO 1.800; A: el calendario deshabilita días ≤ el de suspensión; B: corte
  jun intacto 900; E: cross-month jul=120 prorrateo, reanudadas 900 día 10, pausa no cobrada.
- **HECHO esta sesión (b) (2026-06-19, continuación):** evaluación de arquitectura PowerSync+Supabase (3 workflows
  con verificación adversarial) → **#4 chokepoint oldest-first** (`58a4d0c`: `pagos_repo._validarOldestFirst` +
  4 tests; cierra el 🔶 backlog del lado cliente, es el invariante #11 de AGENTS) y **#1 desacople wipe↔schema**
  (`5bfd07e`: `_schemaVersion`→`_dbWipeVersion`; los cambios ADITIVOS ya NO re-descargan; prueba de seguridad
  `test/powersync/schema_inplace_test.dart` confirmó que PowerSync 1.18 aplica columna/índice in-place sin error de
  cache). Suite **346 verde**. **#2 (audit_log on-demand) y #3 (prioridades de bucket) DIFERIDAS** — #2 porque rompe
  offline-first de los historiales (y Rubén va a reworkear los change logs igual); #3 porque la versión que vale toca
  el sync gate recién blindado y es manual-test-only (el grace de 8s ya cubre lo grueso). **Hallazgo clave
  (git + verificación):** la fuga histórica entre usuarios la arregló el **userId del filename + el `dbEpochProvider`**
  (commits `8fe71c6`/`a5a2167`), NO la versión (que entró 19h después por schema-cache) → quitar la versión es seguro
  para el aislamiento.
- **HECHO previo (lote v32, en `ui-improvements`):** P1-P5 · detalle en pestañas · cancelar permanente (0123) ·
  toggle Visitas (0125) · Revertir susp/cancel (0126) · Reactivar-cualquier-día · **CRÉDITO POR EXCEDENTE (0127)**
  (acreditar/devolver/condonar el sobrepago al suspender/cancelar; saldo a favor a nivel cliente; crédito =
  `cargos_extra credito_aplicado`, no toca recaudado/arqueo; audit Fase 4 = 9 findings fixeados; 3 disposiciones
  validadas en vivo con TEST-CE1..CE3). Decisión de Rubén (2026-06-16): push a GitHub SÍ, build/release NO todavía
  (no se distribuye a usuarios hasta el deploy ordenado).
- **🚨 PELIGRO — deploy a PROD pendiente:** PROD sigue en **v27** (usuarios = v0.11.9). La rama de esta sesión trae
  el lote v32 + crédito (0127) + rediseño de Cobros + **#4/#1**. NO correr `Install Steps/build-release.ps1` (crea el
  Release "Latest" → auto-update en prod) hasta deployar a PROD EN ORDEN: **0119→0127 + sync rules (con `saldos_favor`
  + `cliente_etiquetas`) Active**, y recién después el build. Un build antes del deploy = apps contra DB sin tablas/
  columnas → ROTURA. Orden seguro SIEMPRE: deploy a PROD primero, build/release después. **Migraciones que crean
  tablas/columnas que las apps nuevas esperan:** 0122 (etiquetas), 0123 (cancelación), 0127 (`saldos_favor`). **Nota
  #1 (transición de nombre de DB):** el primer build con `sitecsa_<uid>_w1.db` hace UN re-sync de transición por
  usuario (esperado, una sola vez); desde ahí los cambios aditivos de schema ya NO re-descargan.
- **DEV:** 0119→**0127** deployadas y verificadas + **sync rules Active** (`saldos_favor` en los 3 buckets admin).
  **Data de prueba (DEV-only):** `TEST-CE1..CE3` (crédito) · `TEST-R*` (reactivar/revertir, **reseteado a limpio**) ·
  `QA-VIS-*` (3, claridad) · `QA-SCROLL-*` (200, scroll + geo random en Nicaragua). Setting
  `cobranza.credito_excedente` = **ON**. Seeds versionados: `seed_credito_excedente.sql`, `seed_reactivar_revertir.sql`.
- **Edge Functions:** las 6 al día (2026-06-09).
- **🔶 Money-integrity (oldest-first) — RESUELTO del lado cliente (#4, 2026-06-19):** la regla "no saltear una cuota
  vieja impaga" ahora tiene una **red final centralizada** en `pagos_repo._validarOldestFirst` (chokepoint que corre
  en `registrarCobro`/`registrarCobroMultiple`, online y offline), además de los 6 guards de UI. Es el **invariante
  #11** de AGENTS. **El "fix sugerido" anterior (trigger `BEFORE INSERT ON pagos`) fue REFUTADO** por verificación
  adversarial: rompería el multi-cobro contiguo y la cascada offline de PowerSync (orden arbitrario), y como
  `cuotas.contrato_id` es NOT NULL la exención de cargos manuales no disparaba. **Por DECISIÓN de producto NO va
  trigger server** (la data no se ingresa por SQL en operación normal); el vector REST/SQL directo queda fuera de
  scope. Límite aceptado y documentado: **multi-device offline** sin sincronizar (ningún check de cliente lo cierra
  sin trigger server).
- **🔵 Backlog #3 — prioridades de bucket (DIFERIDA, diseño RESUELTO 2026-06-19):** evaluada a fondo (workflow +
  verificación). **DIFERIR**: HOY es un **NO-OP** (no hay `priority:` en `sync-rules.yaml` → `statusForPriority` cae
  al fallback = sync completo), el **grace de 8s ya cubre** el arranque (slice ~2 MB baja en <8s; si tarda más, la
  pantalla se rellena en vivo por los streams), y el beneficio observable es ~0–2s peor caso, 0 normal — y solo
  tocando el sync gate recién blindado (manual-test-only). El API de prioridades **SÍ existe** en PowerSync 1.18
  (`SyncStatus.statusForPriority(StreamPriority)`, `waitForFirstSync(priority:)`); el aislamiento entre usuarios NO
  está en juego (lo da la DB por `userId`). **Disparador para HACERLA:** slice a decenas de MB (años de cuotas/pagos)
  o cold-starts reales >8s en campo. **Diseño listo (no re-investigar):** `catalogo_tenant`→`priority: 1`; partir
  `por_cobrador` en `por_cobrador_core` (cobradores propia/clientes/contratos/cuotas/cargos_extra/cliente_etiquetas)→
  `priority: 1` y `por_cobrador_extra` (pagos/recibos/fotos_cliente/visitas/notificaciones_mora)→default; +
  `syncReadyProvider` (~10 líneas) usando `statusForPriority(StreamPriority(1))` en vez de `lastSyncedAt` + unit test
  con `SyncStatus` fake; va MONTADO sobre el deploy ordenado de sync rules (nunca un Active suelto extra).

---

## 2026-08-01 — v0.31.9: el mes mostrado vuelve al MES DE SERVICIO (día ≤14 → periodo−1)

**Qué se pidió / por qué:** los dueños reportaron que a varios clientes el mes sale "1
adelantado". Caso SE0047 (Jeymi): instaló 05/ene, día de pago 5, 1ª cuota vence 05/feb → la app
la nombraba "Febrero" cuando el servicio consumido es de ENERO. Toda la serie corrida un mes. La
regla de v0.31.3 (mes de PERÍODO = mes de vencimiento) es la culpable para los clientes de día ≤14.

**Análisis (data real de prod):** Jeymi (día 5) y Heizell (PN0190, día 14) son ESTRUCTURALMENTE
idénticos — ambos instalados en enero, ambos con 1ª cuota de periodo febrero. La regla que arregla
Jeymi (→ Enero) inevitablemente corre también a Heizell (Junio/Julio → Mayo/Junio), revirtiendo el
mes-de-período que se fijó AYER para Heizell. Se confirmó con Rubén (AskUserQuestion) que es lo
correcto: **todos los de día 1-14 se corren un mes atrás.**

**Qué se hizo:** un solo cambio en `Fmt.mesServicio` → `DateTime(periodo.year, periodo.month −
(diaPago ≤ 14 ? 1 : 0), 1)`. Anclado al **día de pago FIJO + periodo** (ambos estables), NUNCA al
día del vencimiento: `calcular_fecha_pago` corre el domingo→lunes y un día 14 en domingo vence el
15, lo que lo mal-clasificaría como ≥15 (bug PN0190). Con el día fijo el mes es CONSTANTE. Propaga
a app, reportes (`ct.dia_pago`) y recibo (`r['dia_pago']`) — todos ya pasaban el día real. Se
ELIMINARON `mesServicio*DeVencimiento`/`*Seguro` (código muerto sin callers que derivaba el día del
vencimiento corrido). Tests reescritos a la regla nueva (Jeymi día 5, Heizell día 14, corrimiento
domingo→lunes, cruce de año). SOLO display: el prorrateo (`prorrateo.dart`) no cambió, no toca un
centavo.

**Commits:** b8aba57 (fix + tests) + doc. **Verificación:** 53 tests verdes · `flutter analyze`
limpio · simulado contra prod (Jeymi y Heizell → Ene, Feb, Mar, Abr, May, Jun). **Deploy:** v0.31.9
a sitecsa-updates, ambos tenants. **Impacto Mairena:** ~1990 contratos (día ≤14) corren su etiqueta;
~2391 (día ≥15) no cambian. **Pendiente:** testing manual de Rubén (mirar Jeymi SE0047 y Heizell
PN0190 en app + reporte de cobranza + recibo → deben empezar en Enero).

## 2026-08-01 — v0.31.8: botón (i) por gráfica del dashboard

**Qué se pidió / por qué:** Rubén quería que cada gráfica del Resumen tuviera un (i) que
explique QUÉ filtra y QUÉ no, para que el admin del tenant sepa qué está viendo. Raíz: el
mismo caja-vs-cobertura que confundía (KPI "Hoy" 42 cobros ≠ curva "Del día" 16). Antes se
verificó contra prod que NO es descuadre: los 26 de diferencia son cobros de hoy sobre cuotas
de OTROS períodos (19 de julio = gente al día con el mes pasado, 2 adelantadas, 5 atrasadas).

**Qué se hizo:** componente reusable `InfoGraficaBoton` + `mostrarInfoGrafica` (diálogo
scrollable, ancho seguro para Android) en `lib/features/admin/dashboard/info_grafica.dart`;
textos DRY de las 10 secciones en `info_grafica_textos.dart` (Eje + Opciones con la expectativa
de cada opción interactiva + Incluye + No incluye). Enganchado en las 2 tendencias (shell),
Cobros KPIs, Consultar período, Sparkline 7d, Top cobradores ×2, Proyección, Recuperación,
Operativos y Distribución. Los 2 bloques de KPIs sin encabezado estrenan mini-título
(`_TituloConInfo`: "Cobros del período" / "Estado actual"). Aditivo puro (UI, sin dinero/SQL/
providers/DB), `flutter analyze` limpio. Redacción aprobada por Rubén con mockups (Fase 2).

**Commits:** 77131c7 (`main`, pusheado). **Deploy:** v0.31.8 a sitecsa-updates, ambos tenants;
manifests `version-{mairena,telenet}.json` = 0.31.8, descarga APK 200, firma CN=SITECSA DEV
(V2, release), v0.31.7 borrado. **Pendiente:** testing manual de Rubén en el release instalado.

## 2026-08-01 — v0.31.5: audit contable del dashboard + 2 fixes

**Qué se pidió:** un agente especialista en contabilidad que revisara cada gráfico del
dashboard, su objetivo y matemática, con foco en "los números no concuerdan al desplazar la
gráfica de tendencia". Deliverable: reporte con mockups.

**El audit (agente general-purpose opus, read-only, verificado contra prod):** 10 componentes,
2 findings, 7 limpios. La divergencia KPI-caja vs Recuperado-curva es intencional (invariante
#4), no bug.

**Fixes (3c317e7), los dos en `tendencia_cobros_card.dart`:**
1. **Mora bruta** — "Total mora" era solo lo impago (se achica al cobrar) mientras Recuperado
   acumula pagos tardíos (crece) → se cruzaban (269/974/1502% en meses cerrados, Por recuperar
   0). Ahora Total = universo BRUTO (saldo impago + pagos recuperados tarde) vía condición de
   universo `(pendiente/parcial OR EXISTS pago tardío)`. `Total − Rec = impago ≥ 0` por
   construcción. Verificado: ago 12%, jul 39%, jun 73%, may 86%, abr 91%, feb 94%.
2. **Curva sin aplastar** — filtraba por `fecha_vencimiento` (cobertura) pero dibujaba por
   `fecha_pago`; los pagos fuera de ventana se `.clamp`-eaban al día 0 / último día (tooltip
   "Del día" 5× inflado, fecha mentida). `construirSerieTendencia` (pura, 6 tests) separa
   baseline / en-ventana / tail; el painter dibuja base punteada rotulada + salto post-ciclo
   rotulado; el tooltip muestra el día REAL. granTotal (= base+ventana+tail) sigue == rec_m de
   la tabla. Verificado Cobros junio: 189k+1.749k+1.131k = 3.070k exacto.

**Nota de proceso:** la "pasada de claridad" que se había commiteado (93abfb4) se REVIRTIÓ por
pedido de Rubén (`git reset`, sin pushear) — solo quería los selectores período de v0.31.4, no
el rediseño de las tarjetas.

---

## 2026-07-31 — v0.31.4: 3 cambios de UI del dashboard (dueños)

**Qué se pidió (con mockups aprobados):** (1) presets del dashboard "Este mes/Mes pasado" →
"Este período/Período pasado"; (2) desglose desplegable por comunidad en Recuperación; (3)
calendario que aplica al tocar, sin OK/Cancelar.

**Qué se hizo (cd2ca19):**
1. `mostrarRangoFechas` toma `usarPeriodos` (default false). El dashboard lo pasa true → sus
   dos presets del medio usan el ciclo 15→14 (`ventanaPeriodoActual`/`periodoDe` de
   `periodo_dashboard.dart`), el MISMO que ya usan sus KPIs y tendencias. Decisión de Rubén:
   SOLO el dashboard; reportes y mis-cobros quedan en mes calendario.
2. `recuperacionDesgloseProvider` (autoDispose, family por cobrador×comunidad×período): repite
   EXACTO el WHERE de `recuperacionPorComunidadProvider` y agrupa por saldo. `_ComunidadRow`
   (stateful) despliega el desglose y `_Desglose` muestra la línea de verificación —
   verde/`check` si suma+conteo cierran contra la fila, ROJA/`error` si no (se avisa, no se
   esconde). Verificado contra prod: las 8 comunidades top cierran monto y conteo.
3. `selector_fecha_rapido.dart` (`elegirFechaRapida`): `Dialog` + `CalendarDatePicker` que
   hace `pop` en `onDateChanged`. Reemplaza `showDatePicker` en rango de fechas, cobro, alta
   de contrato y las 2 fechas de suspensión/reactivación. Quirk documentado: elegir AÑO por el
   dropdown también cierra. 4 widget tests (sin botones + tap devuelve la fecha).

---

## 2026-07-31 — v0.31.3: mes de PERÍODO (rediseño del labeling) + reversión de la regla

**Qué se pidió:** el reporte de cobranza seguía con el mes mal (PN0190 salía "Junio/Junio"
tras v0.31.1). El pedido derivó en una decisión de fondo sobre cómo se nombra una cuota.

**El nudo:** dos clientas con el MISMO día de pago (14) e idéntica alineación de contrato,
pero en distinto punto del ciclo (Heizell un mes más atrasada). Ninguna regla podía dar
Junio/Julio para las dos: crudo período daba Aurora Jul/Ago (mal), mes de servicio daba
Heizell May/Jun (mal), por vencimiento daba Heizell Jun/Jun (el colapso del domingo→lunes).
Se lo presenté a Rubén con la tabla de las tres reglas y **eligió el MES DE PERÍODO** (el mes
en que se paga), aceptando que Aurora vuelva a Julio/Agosto y que todo cliente con día 1-14
suba un mes.

**Qué se hizo (72173a5):** un solo cambio en `Fmt.mesServicio` — ignora `dia_pago` y devuelve
el mes del período. Como app (lista de cuotas, cobro, detalle), reportes (cobranza + historial)
y recibo (`*DeVencimiento`) pasan TODOS por esa función, se unificaron de una. El recibo dejó
de colapsar el caso domingo (PN0190: Junio/Junio → Junio/Julio). El reporte FISCAL agrupa por
`strftime(fecha_vencimiento)` = mes de período → quedó consistente sin tocarlo (cierra el
pendiente que estaba abierto). **Es SOLO etiqueta:** `prorrateo.dart` sigue anclado al
`dia_pago`, no cambió, no toca un centavo. Tests del mes reescritos + propiedad "dos cuotas
consecutivas nunca muestran el mismo mes". ARQUITECTURA §3.5-1 y §3.5-4 actualizados
(invariante de labeling REVERTIDO — la próxima sesión no debe reintroducir período−1).

---

## 2026-07-31 — v0.31.1: mes de SERVICIO en reportes · recibos faltantes · espejo que pisa

**Qué se pidió:** "en los reportes de cobranza el mes sale mal, debería ser junio y julio y
aparece julio y agosto" + correr invariantes + generar los recibos que faltaban.

**1. El mes de los reportes (ef9cd72).** Confirmado contra la base: EC0030, `dia_pago 14`,
cuota de `periodo` julio → vence 14/07 → cubre del 14-jun al 14-jul → **es de JUNIO**.
El reporte mostraba `cuotas.periodo` crudo, que es el mes de VENCIMIENTO. ARQUITECTURA §3.5
lo declara etiqueta INTERNA que no se muestra cruda — y esa MISMA sección ya avisaba del
error puntual para el bloque EN MORA del recibo; el reporte nunca se alineó. El mes ahora
sale del `fecha_vencimiento` HISTÓRICO (no del `dia_pago` VIVO): estable si mañana le
cambian el día de pago. Mismo bug y mismo fix en el PDF de historial del cliente.
**NO se tocó el reporte fiscal:** ese AGRUPA por mes de vencimiento → cambiarlo mueve los
montos de cada fila, no solo la etiqueta. Pendiente de decisión de Rubén. 6 tests nuevos.

**2. Recibos faltantes: eran 20, no 6.** Siguieron apareciendo durante el día mientras
Oficina cargaba histórico. Generados OF-12292..12311 con la fecha del COBRO (no la del
backfill), misma lógica que `super_admin_generar_recibos_faltantes` (0186) corrida por SQL
(su gate `is_super_admin()` no aplica al rol del CLI), + fila en `data_ops_log`. INV5 → 0.
Causa (ya documentada en `pagos_repo:155-160`): dos equipos del mismo cobrador calculan el
mismo correlativo, el 2º choca el UNIQUE y se descarta — pero el pago sí sube.

**3. ⚠️ El espejo del cliente pisa al servidor — ABIERTO, sin fix.** Ver ESTADO ACTUAL.

---

## 2026-07-31 — v0.31.0: impresión en PC (tildes, márgenes, imagen) + Cobros a revisar

**Qué se pidió:** "las tildes y caracteres especiales no aparecen, los márgenes siguen
dando problemas y el modo imagen no funciona — solo en PC".

**1. Tildes (51fc8f7) — NO era la impresora, era la app.** `esc_pos_utils_plus` declara
`Generator({this.codec = latin1})` y codifica SIEMPRE en latin1, sin mirar qué tabla se le
pidió con `ESC t`. Le decíamos "interpretá CP850" y le mandábamos bytes latin1: la impresora
hacía lo correcto con datos malos. Cada símbolo del papel calza exacto — `í`(0xED)→`Ý`,
`é`(0xE9)→`Ú`, `á`(0xE1)→`ß`, `Ó`(0xD3)→`Ë`, `º`(0xBA)→`║`: son los glifos CP850 del byte
latin1. **Eso explica por qué existían los planes B y C (`gbk`/`ascii`): se venía peleando
con el síntoma.** Fix: mapear cada carácter al CODEPOINT igual a su byte CP850 (latin1 mapea
U+00XX→0xXX) → NO cambia lo que se le pide a la impresora, así que la que hoy imprime bien
sigue igual. **Cierra un crash:** `latin1.encode` TIRA con codepoints >0xFF → un emoji en el
nombre dejaba el recibo sin imprimir. 12 tests fijan el byte que sale por el cable.

**2. Borde derecho cortado (c47537e, 2a37d46) — REGRESIÓN de v0.30.0.** El margen se
estrenó con 3mm de default pero NADIE achicaba el contenido: el `GS L` corría el recibo a la
derecha y se seguía generando al ancho del cabezal ENTERO (576 dots / 48 chars) → esos
24 dots caían FUERA del papel. **Por eso pasaba en imagen Y en texto a la vez** — la pista
que se había escapado. Ahora el margen se descuenta de los DOS lados en los dos modos
(imagen rasteriza a `576−2·margen`; texto deriva sus chars de la misma cuenta: 44 con 3mm).
Anda AL ACTUALIZAR, sin tocar sliders. Además el margen en texto nativo **no hacía nada**
(el slider se mostraba pero solo lo aplicaba imagen) → ya emite su `GS L`.

**3. Modo imagen ilegible.** Esa térmica recibe el `GS v 0` y lo imprime como caracteres.
Se agrega `ESC *` (bit image 24 dots, comando viejo) **opt-in por dispositivo**; `GS v 0`
sigue siendo el de todos y un test fija que, apagado, salgan los MISMOS bytes (el raster
compartido ya rompió la flota en v0.22.10-13). **NO verificado en hardware** — si ese modelo
tampoco ejecuta `ESC *`, el modo imagen no le sirve. El selector de tildes también se expuso
en la pantalla de Windows: existía desde v0.22.22 pero solo se llegaba desde la de Bluetooth.

**4. Pantalla "Cobros a revisar" (eecd6d6, f3a5389).** Cuotas cobradas por encima de su
total, agrupadas por cliente, con los pagos enfrentados y "Anular este". La ven admin,
admin_cobranza y lectura (sin botón). Badge en la card del grupo Cobranza y en la propia.
**La lista se DERIVA, no se marca** — sin columna "revisado" ni botón de "ya lo miré" que
esconda plata descuadrada. JOIN por `cliente_id` (NOT NULL), no por `contrato_id` (nullable,
dejaría la lista más corta que el badge).

**Android intacto** (parámetros opcionales con defaults iguales + tests que lo fijan).
583 tests verdes. Pendiente: probar el modo imagen en papel; falta marca/modelo de la térmica.

---

## 2026-07-31 — Guard de sobrepago en el server (0214)

**Qué se pidió:** cerrar el agujero por el que entraron pagos duplicados sin que nadie se
entere. Rubén: "no podemos estar haciendo chequeos manualmente y darnos la sorpresa".

**El diagnóstico, medido:** los 72 pagos que dejaron 36 cuotas sobrepagadas (C$30.003, 9
clientes) se cargaron **todos el 26/07**, en un día — dos usuarios (Oficina y Lester Tercero)
pisando el mismo histórico. **No apareció ninguno nuevo desde entonces: está congelado.**
33 son copia EXACTA (misma cuota, monto y día) y 3 son de Maria Eugenia con fecha distinta =
pago real imputado al mes equivocado. **Corrección de un supuesto viejo: `op_log` SÍ graba los
cobros** — los 72 tienen su fila, atribuida. Lo que falla es que no se MUESTRA (`op_log` solo
sincroniza a admin/admin_cobranza/super; el widget lee la copia local).

**Qué se hizo (55bf60e, migración 0214 aplicada y verificada por contenido):**
`trg_pagos_guard_sobrepago` BEFORE INSERT en `pagos`. Si el cobro deja la cuota sobre su total
Y ya hay uno idéntico → lo **anula solo** con motivo automático. Si excede pero NO es copia
(otro monto/otra fecha) → entra y lo resuelve una persona. **Anula en vez de rechazar:** un
rechazo tampoco trabaría la cola (`connector.dart` ya trata P0001 como permanente) pero
dejaría el pago solo en el device, con recibo impreso y sin respaldo server.
Segundo trigger en `cargos_extra`: descarta el descuento cuyo pago quedó auto-anulado (sube
DESPUÉS en el mismo batch, y `revertir_descuentos` es AFTER UPDATE → no dispara si nace
anulado). `pagos_anulacion_coherencia` abre el carve-out EXACTO para el actor nulo del sistema.
**INV18** nuevo vigila que ese carve-out no se abuse.

**Tres trampas que cazó el testing** (10 casos contra prod en transacción REVERTIDA, todos
pasan): `p.id <> new.id` es obligatorio porque el upload de PowerSync es UPSERT y sin eso un
reintento se auto-anula · `fecha_pago` guarda wall-clock local COMO UTC → `::date` con
`TimeZone=UTC` fijado (convertir a Managua corría un día para atrás todo pago retroactivo) ·
el CHECK exigía `anulado_por` y poner ahí al cobrador lo mostraría como si él hubiera anulado.

**Pendiente:** los 36 históricos NO se tocaron (esperan cotejo con los talonarios: 33 anular
uno de cada par, 3 re-imputar) · pantalla "Cobros a revisar" (la consulta ya está al pie de
0214) · por qué 6 pagos de Oficina del 30/07 no tienen recibo (INV5) · por qué el historial no
se ve en pantalla.

---

## 2026-07-26 — Limpieza del repo + `UPDATE_REPO` configurable a `main`

**Qué se pidió:** confirmar que local y GitHub estaban sincronizados y "empezar limpio" para los
cambios que vienen.
**Qué se hizo:**
- **Verificación:** `main` local = `origin/main` = `909f998` (v0.28.0+211), árbol limpio. Las 2 ramas
  sueltas parecían tener trabajo pendiente pero NO: se comparó el CONTENIDO contra `main`, no los
  commits. El fix del Excel de anulaciones (`928113f`) y el doc de MODULOS ya estaban en `main` por
  otros commits, y 3 de los 4 de `distracted-taussig` también (los archivos que borraban ya no
  existían). **Lección:** "ahead N" contra el remoto no significa trabajo perdido — verificar por
  contenido antes de decidir.
- **Único sobreviviente:** `8abd57e` (UPDATE_REPO configurable) → cherry-pick a `main` = `49608d3`.
  Conflicto en `install-mairena.ps1`/`install-telenet.ps1` (`main` les había agregado el forzado de
  TLS 1.2): resuelto conservando el TLS y tomando `$repo = $Repo`. Verificado: los 3 scripts parsean,
  `flutter analyze` limpio, y `build-release.ps1` ya hornea `.env.json` con `--dart-define-from-file`
  → `UPDATE_REPO` llega a `String.fromEnvironment`. Lo que queda hardcodeado son docs y los defaults
  de `param()`, que es el fallback buscado.
- **Borrado:** 2 ramas (local + la remota `feature/ordenes-cobro-servicio`), 2 worktrees muertos,
  2 stashes, 7 releases de `sitecsa-updates`, `v0.24.12` de `Template-TT` y 4 tags locales (todos
  apuntaban a commits ya contenidos en `main`).
**Pendiente:** `main` quedó **1 commit adelante de `origin/main`** — falta pushear. Sin releases
previos ya no hay artefacto para rollback manual.
**Deploy necesario:** ninguno (no hay migraciones ni sync rules; `UPDATE_REPO` no cambia
comportamiento hasta que se agregue la clave al `.env.json`).

---

## 2026-07-21 — Deploy Fases 0-3 roles a producción + 7 hotfixes

**Qué se pidió:** auditar Fases 0-3 antes de deploy a prod; buildear/release; luego corregir bugs de producción
encontrados durante testing de Rubén.
**Qué se hizo:**
- Audit 3 agentes (Code + DB Integrity + Docs) pre-deploy → fixes menores committeados (`3b3d6cf`).
- Deploy: migración 0192 + 0193, sync rules al VPS, Edge Function invitar-cobrador.
- Build/release v0.25.0 (ambos tenants).
- 7 bugs de producción corregidos: (1) Edge Function sin admin_usuarios → re-deploy; (2) migración 0192 nunca
  deployada (CHECK sin admin_usuarios) → corrida; (3) router sin `/admin/contratos` en allowlist → agregado;
  (4) emails sin refresh tras invite → `ref.invalidate`; (5) rolLabel/rolDisplay incompletos → 3 archivos;
  (6) Revertir cancelación visible → gate esAdminUsr; (7) Pagar en mapa visible → flag `sinDinero`.
- v0.25.1 con fixes 1-6; v0.25.2 con fix 7 (mapa).
**Commits:** `3b3d6cf`, `2cef027` (fixes+v0.25.1), `9941941` (mapa), `173729c` (v0.25.2).
**Pendiente:** Rubén testea v0.25.2 con admin_usuarios.

## 2026-07-11 — Recibo: espaciado por segmento + template por defecto · "generar recibos faltantes" · backfill INV5

**Qué se pidió:** (a) Rubén reportó el error masivo "recibo duplicado" en prod; (b) un botón super_admin para
generar recibos faltantes; (c) que el ajuste de recibo tenga campos por defecto = un template que mandaron los
dueños, con énfasis en el ESPACIADO entre segmentos, afectando modo imagen Y compatible.
**Qué se hizo:**
- **Diagnóstico "recibo duplicado":** colisión de correlativo cliente-side (max+1 por cobrador) en el System Admin
  (identidad de mayor volumen). NO pierde plata (verificado: recaudado/cuotas intactos). El fix de fondo (sufijo de
  desempate = opción "D", u opción A = consulta firme online) quedó **EN PAUSA** esperando la definición FISCAL de
  Rubén (¿el correlativo visible puede duplicarse en la carrera rara?). Se **backfillearon 24 recibos huérfanos** por
  SQL (INV5→0; los 17 invariantes de dinero en 0).
- **"Generar recibos faltantes"** (super_admin → Operaciones de datos): card + RPCs `super_admin_preview/
  generar_recibos_faltantes` (**0186**, SECURITY DEFINER, gate is_super_admin, correlativo MAX+1 por (tenant,prefijo),
  log data_ops_log). Idempotente, no toca dinero. Es la versión-botón del backfill manual. Commit `bfd9133`.
- **Recibo — espaciado + template** (commit `bde36b9`): `ReciboBloque.espacioAntes` (Ninguno/Chico/Normal/Amplio) por
  bloque en el editor, respetado por los 3 renderers (imagen `peso·2·baseFont`, PDF `peso·2pt`, compatible `feed`
  amortiguado: amplio=2 líneas, no 3). Sin migración (fromJson cae al default del catálogo). Layout DEFAULT = template:
  orden meta / cliente-servicio / Monto-letras-método / mora / WhatsApp-pie; **cuota oculto** (habilitable), WhatsApp al
  pie, **Hora off**, etiquetas **Colector** (era Cobrador), **Monto**/Total cobrado (era COBRADO grande), **Total en
  mora**. Rollout **0187**: el seed de tenants nuevos deja de sembrar `recibo.layout` (→ usa `porDefecto`); reset de los
  4 tenants existentes (borra `recibo.layout` + `recibo.mostrar_hora` → template + hora off).
**Verificación:** analyze limpio · tests del modelo 14/14 · 4 audits adversariales (workflows, cero críticos) ·
0186/0187 ya deployadas a prod. **Pendiente:** (1) **build/release** (bump de versión) para distribuir el UI nuevo;
(2) decisión FISCAL del correlativo (destraba el fix de fondo del "recibo duplicado").

## 2026-06-28 — Auditoría profunda completa + 4 lotes de fixes (rama `claude/intelligent-golick-a39fc2`)
**Qué se pidió:** una auditoría exhaustiva de toda la app (código, lógica, UI/UX, tablas/uniones)
medida contra el ciclo de vida y la visión, con reporte final.
**Cómo se hizo:** workflow de 16 dimensiones en paralelo (27 agentes), cada hallazgo verificado
adversarialmente (escéptico que abre el código + chequea el backlog + juzga impacto; críticos/altos
doble-verificados) + **2 verificaciones en vivo contra prod `vxxz`**: `invariantes_dinero.sql` = **0/17
violaciones**, cobertura RLS+`super_admin_all` = **100%** (solo `whatsapp_credenciales` es server-only a
propósito, no bug).
**Resultado:** **0 críticos · 0 altos**; el núcleo duro (dinero, SQL SQLite-vs-Postgres, TZ UTC-6,
anclaje al día_pago, RLS/multi-tenant, denormalización, rutas, anti-patrones UI, case-folding ñ/acentos,
tablas/schema/FKs) quedó **limpio**; **8 hallazgos confirmados** (2 medios, 4 bajos, 2 nits). Rubén
aprobó los 4 lotes → aplicados (cada uno con su commit, analyze limpio, **439 tests verdes**):
- **Lote A (`f9a600a`)** — op_log faltante: `cuotas_repo` ahora emite change-log al aplicar/quitar
  cargos y descuentos del admin (entidad `cuotas`; `quitarCargo` recibe `aplicadoPorId` y dejó de ser un
  DELETE mudo pese a prometer "queda en el historial"); `foto_gallery_widget` emite alta/baja de fotos
  (entidad `clientes`). 5 `_verbo` nuevos en `historial_op_log`. +1 test de regresión. (Raíz: 0140 dropeó
  los triggers de audit y el rework de op_log salteó estos 2 repos.)
- **Lote B (`236ceda`)** — el "Historial de operaciones" del panel de datos no filtraba por tenant
  (`_dataOpsLogProvider` ahora lee `tenantIdProvider` + `.eq('tenant_id', …)`): impersonando un ISP ya no
  se ven ops de otros, y el botón Restaurar no aparece en filas ajenas.
- **Lote C (`abea8e7`)** — doc/copy: `MODULOS` Total contrato = Σ cuotas vivas (#5/R22), EmptyState de
  cobradores sin la promesa de email, snackbar de cobro múltiple a vos, comentarios `audit_log` muertos.
- **Lote D (`d5e3366`)** — los 2 pickers de cliente (`inv_seriales_acciones` + `ticket_form`) migrados de
  `ps.db.watch`-en-build (re-suscripción por tecla) a `getAll` + `SelectorBuscable` in-memory; campo nuevo
  `OpcionSelector.textoBusqueda` para conservar la búsqueda por código/cédula/teléfono.
**Pendiente:** testing manual de Rubén (Fase 5) → merge a `main` → liberar en la próxima versión. Es
UI/repos puro: **sin DB, sin migraciones, sin sync rules** → cero deploy de DB.

---

## 2026-06-27 — Feature: cambio de plan de un contrato (rama `contract-new-feature`)
**Qué se pidió:** un dueño de tenant necesita cambiar el plan de un cliente a mitad de
contrato **manteniendo el contrato y su vigencia** (no crear uno nuevo), prorrateando lo
consumido. Gateado por el super_admin, accesible a admin/admin_cobranza.
**Qué se hizo (fase por fase, con audits):** **F0** análisis multi-agente (12 agentes) +
decisiones de Rubén (núcleo + "Hoy con prorrateo"; Total→Σ cuotas; admin-only). **F1** gate
(setting super-only `cobranza.cambio_plan_habilitado`, migr. `0151`). **F3a** math en
`prorrateo.dart` (`montoCuotaRevaluada`/`prorrateoCambioPlanHoy`, reusa `montoPuente`). **F3b**
`ContratosRepo.cambiarPlan` (UPDATE `plan_id` + re-valúa futuras; Hoy: upgrade→`cargos_extra`,
downgrade→`saldos_favor`). **F2** auditado: NO hace falta trigger server (server gana; cobrador
ya bloqueado por guards). **F4** UI + fix del Total del header a Σ cuotas vivas. **F5** audit
adversarial (15 agentes, 6 baja, arreglados). **Audit de regresión pre-merge** (8 dims) cazó la
**única regresión**: `0151` reescribió `tenants_seed_settings_trg()` desde el cuerpo viejo y
perdió 5 seed-calls → migr. `0152` lo repuso. **Testing en vivo** (admin@test.com): los 4
escenarios al centavo. **2 rediseños UX**: diálogo explicativo (fechas + resumen "qué cambia/
cuándo/por qué" + vigencia) y detalle de pago con desglose; + buscador siempre visible en todos
los selectores DB. Bug `IntrinsicHeight` (Row-stretch-en-scroll) cazado en vivo.
**Commits:** `7706ad3`(F1) `c1c395b`(F3a) `71bcde2`/`25f108c`(F3b) `d6d5144`(F4) `6bf27f7`(F5)
`86593a2`/`37d8fa0`(fixes vivo) `d46074d`(0152) `c59f213`(tests) `35fc6e0`/`02b20bc`(UX1)
`63ab859`(UX2). **Tests:** 437 verdes · analyze limpio · invariantes 0/17. Receta **R22**.
**✅ Mergeado a `main`** (`d1699c5`, fast-forward) **+ liberado en `v0.18.2`** (`0.18.2+148`, `cd8b08b`): `build-release.ps1
-AllTenants` al canal público `sitecsa-updates` + release puente manual (reusando los binarios) en `Template-TT` privado —
ambos **Latest** con los 6 assets (mairena+telenet: MSIX+APK+version.json). Migraciones `0151`+`0152` ya en vxxz; es UI/gate
→ sin sync rules. **Pendiente menor:** limpieza de releases viejos (política), seed prístino del test tenant (opcional).

---

## 2026-06-26 — Testing en vivo del inventario rediseñado + fixes (F2/F1/F3)

**Qué se hizo:** build de rama instalado local (MSIX) y **testeado a fondo vía computer-use** (super_admin impersonando
"Test Tenant"), simulando el flujo real inventario↔tickets↔cliente de inicio a fin.

**Validado en vivo (funciona):** catálogo CRUD (categorías/ubicaciones/productos serial+granel) + unicidad #1d + op_log;
Equipos paginado; ficha (datos + acciones gateadas); **Asignar end-to-end** (picker + aviso "sin red" + transacción +
op_log + UI reactiva); linkage **bidireccional** inv↔cliente; badge de stock bajo; tickets (tipo+ticket+material picker
que lee inventario); **linkage inv↔ticket↔cliente end-to-end** (consumir serial en ticket → instalado en el cliente →
la ficha del serial muestra el ticket).

**Findings → arreglados (`492eb5c`):**
- **F2 (ALTA, bloqueante):** la vista nueva NO tenía **Ingreso ni Movimiento** (se perdieron en el cierre) → imposible
  poblar el inventario por UI. **Fix:** recuperados de git a `inv_stock_flows.dart` (`ingresarStock`/`movimientoGranel`
  + diálogos; comportamiento idéntico — audit de equivalencia 0 hallazgos) + cableados como FABs (Equipos→Ingreso;
  Existencias→Ingreso+Movimiento).
- **F1 (BAJA):** empty-states de Equipos/Existencias decían "Ningún… coincide con el filtro" aun sin filtro → ahora
  condicional (vacío genuino sugiere "Ingreso").
- **F3 (MEDIA) — INTENTADO, NO confirmado:** se agregó `subParents['/admin/inventario/']` en `_backTargetFor`
  (admin_shell) para que el back de catálogo/ficha vuelva a la vista. Pero el **re-test en vivo mostró que el "←"
  sigue yendo al menú** — la lógica del back del shell tiene una sutileza que el cambio no resolvió (el botón tiene
  tooltip "Menú", así que ir al inicio puede ser su diseño). Minor; pendiente de profundizar (revisar
  `matchedLocation` vs `uri.path` y el path `Navigator.maybePop` vs `closeModalsAndGo`).

**Findings menores (NO bloqueantes, anotados):** botón "Registrar" material pegado al borde del sheet (no clickeable por
computer-use; el consumo SÍ funciona — verificado por trigger; confirmar con login real); serial instalado vía ticket
queda con "Historial: Sin movimientos" (el trigger 0106 no escribe op_log); actor "System Admin" vs "Rubén Maltez"
entre módulos.

**409 tests verdes · analyze 0 · 2 audits adversariales (0 hallazgos).** **Pendiente:** re-buildear para re-testear
Ingreso/Movimiento en vivo (el build instalado es previo al fix) → merge a `main`. **Deploy:** ninguno (UI; sin SQL/sync).

---

## 2026-06-25 — Rediseño de Inventario (arranque): doc-first + 2 componentes estándar de listas

**Qué se pidió:** empezar el rediseño de Inventario (rama `Inventario-Tickets`). Antes, volver **estándar de toda
la app** la optimización de Clientes (lista paginada + filtros); luego colgar las vistas nuevas sobre esos
estándares. Orden aprobado: doc-first → componentes → vistas.

**Qué se hizo (todo en la rama, `main` intacto):**
- **Doc-first** (`b6dfa8d`): `ARQUITECTURA.md` Receta **R21** + **mapa de impacto** del inventario (clientes vía
  `inv_seriales.cliente_id`, tickets vía `ticket_materiales`→trg 0106, red `puerto_id`, op_log, gate RLS 0114) +
  invariantes (stock derivado del ledger, guardas serial 0118, NO dinero). Docs flotantes → `docs/`.
- **`ListaPaginadaScroll`** (`6e24ba8`): generaliza el gold-standard de Clientes (`LIMIT n+1`, `COUNT(*)` real
  paralelo, build puro, reset por `filtroKey`, re-suscribe en `dbEpoch`). API por callbacks → **4 tests** sin DB.
- **`FiltrosBar` + `opcionesDesdeRows`** (`124df34`): canoniza "todo/nada = sin filtrar (`null`)" + "Limpiar (N)"
  (vivían copiados en cobros). **5 tests.** Ambos en `lib/features/shared/widgets/`.
- **Fix audit #1d** (`45172e7`): búsqueda de `FiltroMultiDropdown` de `toLowerCase()` → **`foldBusqueda`**
  (acento-insensible; "Núñez" tipeando "nunez"). Mejora cobros/clientes/mapa.
- **Vista beta del inventario** (`0db776d`): `InventarioV2Screen` (2 tabs) con el **tab Equipos COMPLETO** sobre los
  estándares — seriales paginados + `FiltrosBar` (estado/producto/ubicación) + búsqueda por serial/producto/cliente
  con `foldBusqueda` + tap→historial (`HistorialOpLog` sobre `inv_seriales`). Cableada en ruta/menú **TEMP-BETA**
  `/admin/inventario-v2` (mismo gate rol+módulo que la vieja; NO la reemplaza). Existencias = placeholder honesto.
  Mapeo previo con workflow (6 agentes) + audit adversarial (7 agentes): 3 findings crudos → **0 confirmados** (todos
  refutados: lag cosmético, estado inalcanzable, premisa falsa). 409 tests verdes · analyze sin issues nuevos.
- **Tab Existencias (granel)** (`7b73bf8`): productos a granel (`es_serializado=0`) con stock DERIVADO del ledger
  (Σdestino−Σorigen) + filtro Categoría + toggle "Bajo mínimo" (misma def. que el badge del menú, consistencia #10) +
  búsqueda nombre/código + tap→stock por ubicación. Audit del granel (3 agentes): 1 finding REAL (baja) → **fix
  aplicado**: las opciones de los chips se re-suscriben en `dbEpoch` (antes quedaban con datos del tenant viejo tras
  impersonar); ambos tabs ahora `ConsumerStatefulWidget`. 409 tests verdes.
- **Ficha de equipo — detalle (sub-paso 3a)** (`39900ac`): `ficha_equipo_screen.dart` (`/admin/inventario-v2/equipo/:id`,
  sub-ruta del shell): datos del serial (producto/MAC/ubicación/contrato/costo/notas) + **cliente linkeable** + **tickets**
  donde se usó (vía `ticket_materiales`, NO `inv_movimientos` — éste pierde consumos no materializados) + `HistorialOpLog`.
  El tap de la card de Equipos ahora abre la ficha (antes el historial). Extraídos `kEstadoSerial`/`estadoSerialColor`/
  `kEstadoSerialOpciones` a `inventario_comun.dart` (sin 3ra duplicación). Gate de módulo ampliado a la sub-ruta beta.
  Mapeo (4 agentes) + audit (3 agentes) = **0 hallazgos**. 409 tests verdes.
- **Ficha de equipo — acciones (sub-paso 3b)** (`e140a44`+`3a03678`): se **extrajeron** las 4 acciones
  (`_asignar`/`_devolver`/`_transferir`/`_darDeBaja`) de `_EquiposTabState` a funciones públicas en
  `inv_seriales_acciones.dart` (con sus pickers `_ClientePicker`/`_ContratoPicker`/`_pickUbicacion`/`_BajaDialog`), y
  la infra op_log (`InvError`/`actorOpLog`/`opLogMovimiento`) a `inventario_oplog.dart`. La pantalla vieja se
  **rewireó** para llamar las mismas funciones (591 líneas movidas; comportamiento idéntico). La ficha ahora tiene
  botones de acción gateados por estado. Extracción mecánica por agente + **verificación propia**: equivalencia
  línea-por-línea vs git (2 agentes) = **0 hallazgos**, analyze 0, 409 tests verdes.
- **Catálogo en panel de config (sub-paso 4)** (`615d65e`): `inventario_catalogo_screen.dart`
  (`/admin/inventario/catalogo`): los 4 tabs de catálogo (Productos/Categorías/Ubicaciones/Proveedores) **copiados**
  del inventario viejo (que queda intacto → aditivo, cero riesgo), reusando `inventario_oplog.dart`. Acceso: botón
  "Catálogo" a la derecha de los tabs de la vista beta. op_log sin cambios (las 4 entidades ya registradas). Audit de
  equivalencia (2 agentes) = **0 hallazgos**, analyze 0, 409 tests verdes.
- **CIERRE — reemplazo + borrado (sub-paso 5)** (`7079e45`): `/admin/inventario` (la card del menú) ahora sirve
  `InventarioV2Screen`; la ficha pasó a `/admin/inventario/equipo/:id`; **borrados** la `InventarioScreen` vieja
  (2568 líneas) + el cableado beta (rutas `-v2`, entrada soloAdmin, condiciones del gate, `_MenuItem` 'Inventario
  (beta)'). `equipos_en_baja.dart` NO se huerfanizó (es cross-módulo, no dependía de la pantalla). Audit del cierre
  (2 agentes) = **0 hallazgos**, `flutter analyze` full sin issues nuevos, 409 tests verdes.

**Estado del rediseño:** ✅ **COMPLETO Y EN PRODUCCIÓN** (5 sub-pasos). **Pendiente fuera del rediseño:** testing
manual de Rubén (capa 4) + decidir **merge a `main`** y release. **Deploy:** ninguno (solo UI/widgets; sin SQL/sync).

---

## 2026-06-24 — Auditoría de continuidad de release + hardening del pipeline

**Qué se pidió:** asegurar que de acá en adelante CUALQUIER update llegue a los clientes sin sorpresas (a raíz
del incidente histórico "cambié la app de carpeta y los instaladores fallaron por certificados") y que las
keys/.env vivan seguras localmente. Verificar que todo el flujo esté documentado y automatizado.
**Auditoría (workflow 7 agentes, 0 bloqueantes):** firma Android (`key.properties` storeFile RELATIVO → inmune
a mover carpeta; keystore presente), identity Windows MSIX (`Get-AppxPackage` confirma Publisher/PublisherId
`fxkeb4dgdm144` idénticos entre versiones y tenants), auto-update (`update_service.dart` baja de
`sitecsa-updates`), archivos locales (.env/jks/key.properties/local.properties presentes) y branding
(applicationId/msixIdentity estables) → **todo OK**. **Causa raíz del incidente aclarada:** era el MSIX con
`certificate_path` atado a una ruta (removido el 2026-06-09), NO Android. Hoy mover la carpeta NO rompe firmas;
el único path-dependiente vivo es `local.properties` (SDK, depende de la máquina, regenerable). Gotchas reales:
instalar por `install-<tenant>.ps1` (importa el cert a TrustedPeople) y MAX_PATH bajo OneDrive (rompe el BUILD).
**Hardening (`7bdc0af`):** (1) `version.json` 3 download_url Template-TT (privado) → `sitecsa-updates` + version
0.16.0→0.17.2; (2) rama genérica de `build-release.ps1` reescribe SIEMPRE download_url desde `$ghBase`
(self-healing); (3) `pubspec.yaml`: `msix` pin 3.16.13 (no `^`) + `publisher` (DN) explícito = Subject del test
cert → identidad de firma de Windows independiente de bumps del paquete. `flutter pub get` OK (lock sin cambios).
**Backup:** `.7z` AES-256 (jks+key.properties+.env.json) en `C:\Users\ruben\sitecsa-key-backup\` (fuera de
OneDrive; mover a pendrive/vault — el `.jks` es la única llave para firmar updates de Android).
**Pendiente:** confirmar el `publisher` explícito del MSIX en el próximo `build-release.ps1` (si `msix:create`
falla por mismatch del publisher, revertir esa línea de `pubspec.yaml`).

## 2026-06-24 — Releases a repo público separado (privacidad del código) → v0.17.2

**Qué se pidió:** hacer privado el repo del código (que nadie clone la app) manteniendo los releases públicos
(la auto-actualización los baja sin login — un repo privado los cerraría).
**Solución:** repo público separado SOLO para releases → `rubenmaltez/sitecsa-updates` (creado, sin código).
**Qué se hizo (`3460582`, v0.17.2):** repunté `update_service` (de dónde baja la app), `build-release.ps1`
(param `-Repo`, default `sitecsa-updates`, `--repo` en los `gh`) y `install-mairena/telenet.ps1`. Publiqué
v0.17.2 en `sitecsa-updates` (canal futuro) Y en `Template-TT` (PUENTE: mismos binarios reusados sin recompilar,
`version.json` apuntando a Template-TT) para que las apps en v0.17.1 se autoactualicen y migren de canal sin
cortarse. Ambos canales verificados (`latest/download/version-<slug>.json` resuelve en cada repo).
**Orden de privatización (CLAVE):** primero las apps pasan a v0.17.2 (apuntan a `sitecsa-updates`), RECIÉN
DESPUÉS se hace privado `Template-TT` — si no, las apps viejas pierden la auto-actualización.
**✅ Hecho:** `Template-TT` (código) → PRIVADO (2026-06-24); `sitecsa-updates` (releases) → público. Se pudo de
inmediato porque los clientes aún no tenían la versión nueva (solo los 2 equipos de Rubén, que reinstalan la
v0.17.2 del repo público).

## 2026-06-24 — Auditoría integral de módulos (adversarial) + lote de fixes

**Qué se pidió:** auditar que la lógica y las uniones de cada módulo/entidad funcionen offline y online
(ej. geografía→cliente), con reporte y mockups del entrelazado.
**Cómo:** workflow de 24 agentes (12 auditan leyendo el código real + 12 verifican adversarialmente) contra el
modelo §3.5/§3.6/§3.7; FKs y triggers cotejados con la DB de prod. **43 OK · 8 falsos positivos · 1 ALTA + 7
MEDIA + 18 BAJA.**
**Fixes aplicados:**
- ALTA (dinero, `5fa1e3c` + test): `cuotas_repo.totalACobrar` y `_recalcularCuotaLocal` no restaban
  `credito_aplicado` → saldo inflado → sobre-cobro (INV4 lo marcaba sobrepagado). Ahora resta, igual que el
  server (0127) y los mirrors. Y `_recalcularCuotaLocal` ahora espeja `vencimiento_mas_viejo` (los 2 call sites
  del mapa que faltaban: aplicarAjuste/aplicarCargo/quitarCargo).
- MEDIA/BAJA (`7e02b76`): geo_picker pre-chequea duplicado (folding ñ) y reusa id + guarda tenant_id; crear
  contrato emite op_log; `puede_cambiar_fecha` en lote → writeTransaction + op_log + filtro tenant; cargos auto
  usan día de Nicaragua (regla 1b); 6 comentarios/doc stale corregidos.
**Documentado como decisión aceptada (NO se codea — ver backlog "no urgente"):** reasignar cobrador offline
(R15, self-heal; replicar la cascada de 5 tablas = mayor riesgo/menor valor), contrato offline sin cuotas,
correlativo mismo-cobrador-multi-device, dashboard bruto vs arqueo neto, divergencia filtro mora, recovery por
email, flash 1-frame en restart, card Pagos del super por URL, granel offline negativo, código muerto
(`reimpresiones`, `audit_changelog.dart`).
**Verificación:** 400 tests verdes · `flutter analyze` sin issues nuevos (4 deprecations preexistentes).

## 2026-06-24 — White-label por tenant (Opción B) + fixes del mapa → v0.17.0

**Qué se pidió:** apps por tenant — misma app, ícono + nombre + logo de login distintos por ISP, en APK e
instalador Windows; un solo comando para buildear todos.
**Qué se hizo:**
- **White-label (Opción B — paquete por tenant):** `branding/<slug>/{config.json,logo.png}` +
  `tool/aplicar_branding.dart` (ícono forma A 1024² + logo del login) + rework de `build-release.ps1`
  (`-Tenant`/`-AllTenants`/`-NoRelease`; parcha label Android, título Windows, `display_name`+`identity_name`
  MSIX, applicationId; pasa `--dart-define=TENANT`; restaura el árbol con `git checkout`). `update_service`
  resuelve `version-<slug>.json` por el slug horneado. `BrandLoginLogo` en login y crear/restablecer
  contraseña (asset `assets/branding/login_logo.png`, default = app_icon). **Decisión: branding cosmético, sin
  tenant-lock** (RLS ya aísla; un user de Telenet en la app de Mairena solo ve su data). Commits `48d0afc`.
- **Mapa:** espejo `recalcVmvDeContrato` en los 10 flujos de mutación de cuotas/estado (`d6968eb`, +2 tests);
  empty state con "Ver todos los clientes" cuando el filtro cobrables queda vacío (`03aacbd`).
**Validado en vivo (Windows, build local `-NoRelease`):** branding OK (título "Telecable Mairena S.A.",
manifest `com.sitecsa.crm.mairena` / DisplayName correcto); usuario de tenant entra liso; impersonación OK
(el ciclado del sync gate era por tener 2 apps logueadas como el MISMO super_admin a la vez); GPS de Telenet
confirmado en prod (984 activos con coordenadas) → se ven con "Ver todos". **399 tests verdes.**
**Deploy:** v0.17.0 con los 2 instaladores branded. **SIN migraciones nuevas ni cambio de sync rules** (el
white-label es build-side; el espejo del mapa es Dart; el trigger 0150 ya existía).
**Pendiente:** Rubén distribuye los instaladores + migra los equipos (1 reinstall c/u, proceso arriba). El
"ciclado del sync gate del super_admin en instalación fresca" queda como ítem pre-existente (no del white-label).

## 2026-06-23 — Lote 4 mejoras visuales: colchón offline (#1) + detalle cobro (#2) + buscador Rutas (#3) + cobrador ve todo (#4)

**Pedido (Rubén):** 4 mejoras sobre `main` v0.14.1, visual-first con mockups. #1 es money/producción ("falla enorme").

**Hecho (rama `claude/youthful-mahavira-d0b46e`):**
- **#1 — Colchón de indefinidos a prueba de offline** (`35fae3d` + audit `87d58d9`): las cuotas colchón se generaban
  SOLO en el server (trigger 0015 + cron 0074) → offline o con data retroactiva el contrato quedaba sin cuotas por
  cobrar. Espejo Dart `lib/data/utils/colchon_indefinido.dart`, llamado al **COBRAR** (`pagos_repo` registrarCobro/
  Multiple; NO al crear — colisionaba con el trigger server por `(contrato_id,periodo)`, 23505). Regla: cuotas
  pendientes contiguas desde el mes-sig-al-inicio hasta **`max(última con pago, mes actual)+3`** (un adelanto, aun
  PARCIAL, corre el colchón; piso 3 aun con instalación futura). Server **0148** = misma lógica + backfill. **INV17**
  nuevo en `invariantes_dinero.sql`. 8 tests (grupo "colchón indefinidos"). **0148+0149 corridas en prod `vxxz`;
  INV17=0; el indefinido roto curado (2 cuotas generadas).**
- **#2 — Detalle del cobro** (`2f69b04`): `cobro_screen` _ClienteCuotaCard/_MultiCuotaCard a 22/17px + color con más
  contraste; "Cuota"→"Cobro". Solo presentación.
- **#3 — Buscador + filtro municipio en Rutas** (`0fcb331`): `rutas_screen` reusa `FiltroMultiDropdown` + buscador con
  debounce 250ms, client-side (offline).
- **#4 — Cobrador comparte vista admin** (`df0648b` + audit `f80a34c`): RLS **0149** (`is_personal_cobranza`) abre la
  lectura tenant-wide a admin/admin_cobranza/cobrador en 7 tablas; sync-rules `por_cobrador` pasa a tenant-wide
  (parametrizado por tenant → cobradores comparten bucket). UI: Cobros `adminMode`, Mapa `esAdminView` incluye cobrador,
  Clientes muestra todos. El cobrador ve y **cobra** a cualquiera (auto-estampándose, invariante #11) pero **NO edita**
  (write admin-only). Audit: "Cambiar fecha" gateado a clientes propios del cobrador (evita cobro fantasma) +
  `contrato_suspensiones` al bucket.

**Auditorías Fase 4** (workflows adversariales, verificación incluida): **#1** → 4 findings reales fixeados (colisión
al crear, piso `GREATEST(3)` para instalación futura, ancla incluye 'parcial', tests). **#4** → 2 fixeados (cambio de
fecha owner-scoped, suspensiones al bucket) + **volumen** flageado (cada cobrador baja todo el tenant).

**Pendiente:** **Rubén deploya las sync rules** de PowerSync (⚠️ volumen — deploy GRADUAL, monitorear) → testing manual
build fresco → merge a `main` → build/release. Migraciones 0148/0149 YA en prod. Violaciones pre-existentes prod: INV9
(Mairena, denorm `cobrador_id` del import — fix `UPDATE` espera OK de Rubén), INV2/11/12 (Test Tenant, data de prueba).

---

## 2026-06-22 — Operaciones de datos (super_admin) + fix de búsqueda con ñ/acentos → v0.14.1

**Pedido (Rubén):** dos cosas en la misma rama `feature/super-admin-data-ops`.
**(1)** Que el super_admin pueda **corregir errores de carga** (borrar/limpiar la
data de un cliente mal importado) DESDE LA APP, sin pedir por chat un SQL a mano —
con red de seguridad: previsualizar el daño, confirmar, y poder **deshacer**.
**(2)** Bug de PRODUCCIÓN: los clientes con **ñ** en el código eran invisibles en
la búsqueda.

- **(1) Panel "Operaciones de datos"** (NUEVO módulo super_admin): tab "Operaciones"
  en Config (gate `esSuperAdmin`). 3 operaciones predefinidas — **limpiar cliente**
  (borra su cobranza, conserva el cliente), **eliminar contrato** (uno solo),
  **eliminar cliente** (todo + el cliente). Flujo: tipear código → **Previsualizar**
  (cuenta qué se borra, NO toca nada) → tipear de nuevo el código RESUELTO para
  confirmar → ejecuta. Cada borrado deja **BACKUP restaurable** (`data_op_backups`,
  snapshot jsonb) + registro (`data_ops_log`). Migraciones **0146** (2 tablas, RLS
  super-only-READ, INSERT por las funciones) + **0147** (6 funciones SECURITY
  DEFINER preview/ejecutar). Detalle: ARQUITECTURA §3 "Operaciones de datos" + R19.
- **(2) Fix búsqueda ñ/acentos** (causa raíz: SQLite `lower()`/`upper()` son
  ASCII-only → NO bajan Ñ ni vocales acentuadas; Postgres y Dart sí). v0.13.3
  habilitó tipear ñ en los códigos (se guardan en MAYÚSCULA, ej. `JÑ0048`) pero NO
  tocó la búsqueda → `jñ0048` no matcheaba `lower('JÑ0048')='jÑ0048'`. Fix:
  `foldBusqueda`/`foldSqlExpr` en `busqueda_cliente.dart` pliegan AMBOS lados a
  ASCII-minúscula (ñ/acentos→base). Aplicado a las 5 búsquedas + pickers (inventario/
  tickets) + búsqueda de pagos por nombre + unicidad de código (cliente/contrato) +
  unicidad de categorías + `_resolverId` de data-ops. **Regla 1d** agregada a AGENTS.
- **(3) Placeholder de búsqueda dinámico** (`placeholderBusqueda`): el hint lista
  solo los campos habilitados por los toggles (apagás teléfono → no aparece).
- **(4) Chip de código de contrato REMOVIDO** de la tarjeta de cliente (admin + lista
  cobrador): solo se quería BUSCAR por código de contrato, no mostrarlo. La búsqueda
  sigue intacta.
- **(5) Diálogos de invitar responsive** (`scrollable:true`; no desbordan en pantalla
  chica).

Commits: `b4b6171` (invitar scrolleable) · `86d3dd4`+`6e82261` (data-ops tablas+
funciones+panel) · `c7976c0`+`87c6df2` (búsqueda ñ + regla 1d) · `6e38612`
(placeholder dinámico) · `62577bd` (quitar chip) + bumps 0.14.0/0.14.1.
`flutter analyze` limpio + suite verde + audit adversarial de data-ops (5 fixes
aplicados: snapshot incompleto, corrupción cross-contrato por crédito, validación
de tenant, confirmación robusta, comentario op_log). **Aprendizaje (causa raíz):**
SQLite `lower()`/`upper()` colapsan SOLO ASCII — cualquier comparación/unicidad/
búsqueda case-insensitive sobre texto que pueda traer ñ/acentos necesita folding
explícito en Dart y en SQL (no asumir que `lower()` "normaliza"). Es la **regla 1d**.

> ⚠️ **Pendiente de cierre:** merge a `main` + release. Migraciones **0146/0147 YA
> corridas y verificadas en prod (`vxxz`)**. No requiere redeploy de sync rules (las
> 2 tablas NO se sincronizan a clientes — el panel las lee por REST con el JWT del
> super_admin) ni edge functions nuevas.

## 2026-06-22 — Código de cliente/contrato acepta ñ (alfanumérico español) → v0.13.3

**Reporte de cliente:** al crear un cliente o un contrato, la **ñ no se podía
tipear** en el campo **Código**. Causa: el `inputFormatters` filtraba con
`FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-_]'))` → la ñ (y las
vocales con tilde) no pasaban el filtro (corre ANTES del `toUpperCase`). El campo
Nombre nunca tuvo bloqueo (ñ siempre anduvo ahí).

**Fix:** la regex pasa a **alfanumérico español** `[A-Za-z0-9ñÑáéíóúüÁÉÍÓÚÜ\-_]`
(minúscula y mayúscula porque el filtro corre antes del uppercase). Dos campos:
código de cliente (`cliente_form_screen.dart`) + código de contrato
(`contrato_form_screen.dart`). `flutter analyze` limpio. Release v0.13.3.
(El prefijo de recibo del cobrador usa la misma regex vieja — no se tocó; queda
como follow-up si hace falta.)

## 2026-06-22 — Password opcional manual al invitar/crear usuario → v0.13.2

**Pedido (Rubén):** que generar password sea OPCIONAL — poder escribir la
contraseña a mano y asignarla directo, ahorrando el paso de la random forzada.
Aplica a los 3 flujos de alta: invitar cobrador, invitar miembro de tenant
(super admin), y crear tenant.

- **UI**: widget reusable `shared/widgets/password_mode_selector.dart`
  (SegmentedButton Generar/Escribir + 2 campos con ojo + validación min-8 +
  coinciden; `onChanged` da la password válida o null). Integrado en los 3
  diálogos (cobradores_admin, tenant_dialogs_invitar, tenants_list). El selector
  solo se muestra en el **path no-email** (el default). El submit se bloquea
  hasta que la password manual sea válida.
- **Edge functions** (`invitar-cobrador`, `crear-tenant`): aceptan `password?`
  opcional. Si viene → `createUser` con ella (validación min-8 server-side; en
  crear-tenant ANTES de crear el tenant para no dejar huérfano); si no → genera
  random (como antes). La password manual **NO se eco-devuelve** (`nueva_password`/
  `admin_password` = null en manual → la UI usa la tipeada local) ni se loguea.
  `email_confirm:true` preservado → el user loguea directo, sin forzar cambio.
- **Sin forzar cambio**: el path no-email no manda a `/set-password`, así que la
  clave tipeada funciona al primer login. No hubo nada que tocar ahí.

Rama `feature/password-manual`. Fundación + reseña a cargo mío; cableado de los 3
diálogos + edge functions por subagente de contexto fresco (revisado). `flutter
analyze` limpio + **377 tests** + **audit de seguridad** (no-echo/no-log/min-8/
email-path-intacto verificados; 1 finding media de crear-tenant fixeado: fallback
`?? resultado.adminPassword`). Release v0.13.2.

> ⚠️ **REQUIERE redeploy de 2 edge functions** (Rubén, Dashboard):
> `invitar-cobrador` + `crear-tenant`. El modo "Escribir" NO funciona hasta
> deployarlas (la app vieja/edge vieja ignora `password` → usa random → mismatch).
> El modo "Generar" anda con las viejas (backward-compatible).

## 2026-06-22 — Búsqueda de cliente configurable por toggles (super_admin) → v0.13.1

**Pedido (Rubén):** la búsqueda de cliente daba falsos positivos por el TELÉFONO
(buscar "003" traía todo número con 003). Quería poder elegir, desde Settings como
super_admin, qué campos entran en la búsqueda en TODA la app. Sumó: poder buscar
al cliente por el **código de CONTRATO** (herencia padre-hijo) y verlo como
referencia (Opción 2: buscable + visible como chip).

- **Toggles** (super_admin, Avanzado → grupo "Búsqueda de clientes"): Código de
  cliente · Cédula · Teléfono · Código de contrato. El **NOMBRE siempre entra**
  (red de seguridad). Default todos TRUE = comportamiento previo. Migración
  **0145** (seed por tenant, default true; corrida en prod). Setting key-value
  `busqueda.por_*` + getters en `settings_repo` + grupo en `settings_groups.dart`
  + labels + `_superAdminOnly`.
- **Helper compartido** `data/utils/busqueda_cliente.dart`: `busquedaClienteSql`
  (WHERE para las 3 búsquedas SQL: clientes admin, lista cobrador, global) +
  `busquedaClienteMatch` (client-side, para Cobros y mapa que filtran en Dart por
  diseño anti-flicker). Mismo criterio en las 5. El teléfono strippea a dígitos
  AMBOS lados (query y columna vía `replace()` encadenado) → matchea importados
  con guiones, consistente entre SQL y client (fix audit).
- **Código de contrato consistente:** antes solo 3 de las 5 búsquedas lo incluían
  (faltaba en Cobros y mapa) — el helper lo unifica en las 5.
- **Chips** (Opción 2): el/los código(s) de contrato se muestran en las filas de
  cliente (lista admin + lista cobrador) vía `GROUP_CONCAT(codigo, char(30))`.
- **Verificado en la app** (build 0.13.1.18): toggles renderizan en Avanzado,
  search responde a los toggles. `flutter analyze` limpio + **377 tests** +
  **2 audits** (Fase 2/Fase 3 del helper) → findings menores fixeados.

Rama `feature/busqueda-configurable`. Implementación: fundación a mano + cableado
de las 5 búsquedas por un subagente de contexto fresco (caso ideal: plomería
mecánica multi-archivo). Release v0.13.1; **v0.13.0 borrado**. Migración 0145 ya
en prod; sin otros deploys manuales. Detalle: ARQUITECTURA (búsqueda de cliente).

## 2026-06-22 — Reforma del módulo de reportes (filtros unificados + generador único) → v0.13.0

**Pedido (Rubén):** unificar la reportería. Antes: filtro de cobrador solo en
"por cobrador" (diálogo propio), rango global + rango propio del arqueo, y la
generación dispersa (card de cobranza con su botón Excel + card de arqueo con su
botón PDF + FAB de PDFs + sub-menú de Excel). Ahora: **filtros COMPARTIDOS arriba
(período + cobradores) que valen para TODOS los reportes**, y **un solo "Generar
reporte" → diálogo (tipo + formato Excel/PDF)**. Hecho en 3 fases commiteadas, cada
una auditada (workflow de dinero) + `flutter analyze` limpio + **377 tests OK**.

- **Fase 1 — fundación** (`reportes` fase 1): `reporteCobradoresProvider` (Set?,
  null=todos) + helper `filtroCobradorSql` + card "Cobradores en los reportes" +
  presets **Hoy/Ayer** en el rango global + cobranza filtrada.
- **Fase 2 — filtro en TODAS las queries de cobro** (auditada CERO findings):
  cobros, por_cobrador, fiscal, anulaciones por `p.cobrador_id`; eficiencia y
  arqueo por `cb.id` (agrupan por cobrador). Los **por-cliente** (mora, estado,
  inactivos, padrón) lo IGNORAN. `_elegirCobradores` (diálogo viejo) eliminado.
- **Fase 3 — generador unificado** (auditada, 1 finding baja ya fixeado):
  `_GenerarReporteCard` con diálogo tipo+formato; descriptores `_TipoReporte`
  (qué tipos, qué formatos, `soloDetallado`, `filtraCobrador`). El **toggle de
  reportes detallados** controla los tipos: solo "cobranza" si OFF, los **11** si
  ON. **Arqueo unificado al rango global** (`reporteArqueoRangoProvider` borrado;
  presets Hoy/Ayer cubren el cierre diario). `_ReporteCobranzaCard`, `_ArqueoCajaCard`,
  `_DescargarPdfMenu` (FAB), `_mostrarMenuExcel`/`_excelOpcion` eliminados.
  **Verificado en la app** (build 0.13.0): módulo renderiza, diálogo OK, toggle +
  formato correctos. Neto del archivo: **−180 líneas** (más simple).

Rama `feature/reforma-reportes`. Audits: Fase 2 (2 agentes, params/columnas/scope)
CERO findings; Fase 3 (movimientos sin pérdida byte-idénticos, ruteo 9 PDF + 11
Excel sin no-op, pitfalls showDialog/Navigator OK). Release v0.13.0; **v0.12.4
borrado**. Sin deploys manuales (solo app). Ver ARQUITECTURA (módulo Reportes).

## 2026-06-22 — Hotfix recibo (preview en blanco) + búsqueda responsive → v0.12.4

**Reporte de cliente (URGENTE):** la vista previa del recibo (Configuración →
Recibos) salía EN BLANCO. Causa: el fix #1 (mes del recibo anclado a
`fecha_vencimiento`) hizo que `ReciboTicket`/`recibo_pdf` parseen ese campo, y la
fila de EJEMPLO del preview (`recibo_preview.dart`) NO lo traía →
`DateTime.parse(null)` reventaba. **La impresión REAL nunca estuvo rota** (las
cuotas reales tienen `fecha_vencimiento` NOT NULL y las 3 queries del recibo lo
traen). Fix triple: (1) agregado el campo a la fila de ejemplo; (2) renderers
ENDURECIDOS — `Fmt.periodoReciboSeguro`/`mesServicioLabelSeguro` caen al mes del
`periodo` si el vencimiento falta/no parsea → un recibo NUNCA rompe (preview en
blanco / no imprime); (3) 7 tests de regresión en `formatters_test`. **Verificado
en la app** (build 0.12.3.14): preview renderiza, Período = "Mayo 2026" correcto.

**Búsqueda responsive (clientes, pedido del cliente):** en teléfono la barra de
búsqueda quedaba mínima (los botones Nuevo cliente + descarga la apretaban).
Ahora en pantalla angosta (`MediaQuery < 600`), al enfocar o tener texto, esos
botones se COLAPSAN y la barra toma todo el ancho (`FocusNode` + rebuild on
focus). Desktop intacto; Cobros ya tenía la barra full-width (no se tocó).

Commits: `eeb8130` (hotfix recibo) · `43a09e4` (búsqueda responsive). Release
v0.12.4; **v0.12.3 borrado**. Sin deploys manuales (solo app).
**Pendiente de diseño (no implementado):** filtro de cobradores en reportes —
mockup presentado, recomendada Opción 1 (filtro persistente arriba, compartido
por el reporte moderno y los legacy, reusa `_elegirCobradores`). Espera decisión.

## 2026-06-22 — Bundle de backlog (6 ítems) → release v0.12.3

**Pedido (Rubén):** cerrar el backlog accionable de una ("todo junto"). Los 6,
auditados (workflow 3 agentes; findings LOW/MEDIA, sin bugs, todos fixeados) +
`flutter analyze` limpio + **370 tests OK**. Rama `feature/bundle-backlog`.
- **#1 — Recibo: mes de servicio ESTABLE** (`1775566` + fix audit): el rótulo se
  ancla al `fecha_vencimiento` HISTÓRICO de la cuota (no al `dia_pago` vivo) →
  reimprimir un recibo viejo ya NO corre el mes al cambiar el día de pago. Helpers
  nuevos en `formatters.dart`. Ver R13. Borde cosmético domingo (~0.5%).
- **#2 — error_logs ELIMINADO** (`c7c4086`): tabla + 2 RPCs + servicio + pantalla
  `/super/logs` + ruta + handler global (ahora `debugPrint`). Migración **0143**
  (drop; corre en el release). No se usaba. Mismo criterio que audit_log.
- **#3 — Rol admin_tickets COMPLETO** (`0e72fec` + fix mapa): shell móvil-first
  propio (Tickets/Mapa/Perfil) + redirect/guard en router + **bucket de sync
  `por_admin_tickets`** (tickets + clientes + catálogo, SIN dinero) + expuesto en
  los 3 forms (gateado por módulo tickets). RLS ya lo cubría (`is_ticket_staff`);
  `invitar-cobrador` ya lo aceptaba. Mapa en modo-soporte (todos los pines, sin
  chips/botones de cobranza). **Requiere deploy de sync rules (Rubén).**
- **#4 — Test reactivar indefinido** (`86e32f6`): cubre el colchón de 3 al reactivar.
- **#5 — Tests router + widget** (`6301a43`): `redirectInicialPorRol` extraído a
  función PURA + 25 tests de redirect por rol + 4 widget tests de `FiltroMultiDropdown`.
- **#6 — Lock anti-race en `reenviar-invitacion`** (`e32dbf4` + TTL 120s): tabla
  **`reinvite_locks`** (0144, YA en prod) + lock con finally. **Requiere redeploy
  del edge function `reenviar-invitacion` (Rubén).**
**Deploys manuales (Rubén) en el release:** (1) **sync rules** con `por_admin_tickets`
→ Active · (2) **edge function `reenviar-invitacion`**. Migraciones: **0142/0144 ya
en prod**; **0143 (drop error_logs) corre en el release** (tras publicar, como audit_log).
**Backlog accionable: CERRADO** (GREATEST(3), COALESCE, deuda-de-bajas,
suspensión-libre + estos 6). Quedan solo: 4 `info` de deprecación del Flutter SDK
(login_screen:57, tenant_dialogs_miembro:558-559, tenants_list_screen:222 —
pre-existentes, no bloquean) + los parqueados/dormidos.

## 2026-06-21 — Rework de filtros (Clientes + Cobros + Mapa) + release v0.12.2

**Pedido (Rubén):** rediseñar la LÓGICA de los filtros de las 3 vistas (la estética
del `FiltroMultiDropdown` con búsqueda+multi-select se mantiene), eliminando
redundancias/contradicciones. Aprobado con mockups (Fase 2).
**Diagnóstico:** cada vista tenía su propio set → "Sin cobrador" como toggle suelto
(redundante con el dropdown) que se contradecía con elegir un cobrador; "Con mora" +
"Suspendidos" + "Solo activos/Todos" se pisaban; deseleccionar todo en un dropdown
daba lista vacía (`1=0`); la deuda de suspendidos/cancelados era invisible.
**Qué se hizo (rama `feature/rework-filtros`, mergeada a `main`):**
- **Regla única:** AND entre categorías, OR dentro de cada multi-select; set null o
  vacío = sin filtrar (**nunca-vacío**). "Sin cobrador" pasó a ser una OPCIÓN dentro
  del dropdown de Cobrador en las 3 vistas (centinela `__sin_cobrador__`).
- **Clientes:** helper `construirFiltroClientes` centraliza el WHERE (lista + export +
  "seleccionar todos" → consistencia #10). Toggles "Con mora"/"Suspendidos" →
  **Estado de servicio** multi (`EstadoServicio`: alDia/gracia/mora/suspendidoDeuda/
  canceladoDeuda/sinContrato, predicados en `_predEstadoServicio`). "Estado" →
  **Activo/Inactivo** binario (se quitó "Todos"). Badge **"debe C$X fuera de ruta"**
  (columna `saldo_fuera_ruta`, subquery independiente; cierra el agujero de
  visibilidad sin romper el saldo de ruta).
- **Cobros:** `cobrosAdminFilterSql` set vacío → sin filtro (no `1=0`); never-empty en
  los dropdowns; **Limpiar (N)** + empty state inteligente. Chips de cobranza intactos.
- **Mapa:** **clustering** (`flutter_map_marker_cluster ^1.4.0`, compat. flutter_map 7;
  `MarkerClusterLayerWidget` + `markerChildBehavior:true` para tap determinista) →
  ~4000 pines en burbujas que se abren al zoom + culling de viewport interno;
  "Sin cobrador" en el dropdown; never-empty; **Limpiar (N)**.
**Audit (3 agentes):** findings LOW; el de clustering (gesture arena) fixeado con
`markerChildBehavior`. Diferido (pre-existente, fuera de scope): envolver
`monto_pagado` en COALESCE (fix global del codebase, no de este rework).
`flutter analyze` limpio · **361 tests OK** (consistencia #10 intacta) · validado en
vivo por Rubén.
**Release:** **v0.12.2 + 123** (bundlea reportería plantilla + historial + filtros).
Sin migraciones nuevas (0141 ya en prod). Sin cambios de sync rules.

## 2026-06-21 — Historial de pagos por cliente (PDF imprimible)

**Pedido (Rubén, nota a mano):** estado de cuenta imprimible POR CLIENTE, hasta
1 año, con sus datos personales + cada pago (fecha, cobrador, método, y si fue
transferencia la referencia).
**Decisiones (confirmadas):** solo **guardar PDF** (no impresión directa) ·
**admin + admin_cobranza** (el cobrador no lo ve) · rango por **opciones fijas**
(Últimos 12 meses / Este año / Año pasado, tope 1 año) · columnas extra:
**Período + Recibo # + Total pagado**.
**Qué se hizo (rama `feature/historial-pagos-cliente`):**
- `buildHistorialClientePdf` en `pdf/reporte_historial_cliente_pdf.dart`: header
  estándar + bloque de datos del cliente + tabla (Fecha · Período · Recibo # ·
  Cobrador · Método · Referencia · Monto) + Total. Reusa toda la infra PDF
  (`pdfTheme`, `buildHeaderEstandar/Footer`, `TableHelper`, NotoSans).
- Botón "Historial de pagos (PDF)" en el AppBar del detalle del cliente, gateado
  por `puedeGestionar` (admin ∪ admin_cobranza). SimpleDialog de rango →
  `_generarHistorialPdf` → query pagos (todos los contratos del cliente,
  anulado=0, rango) + datos del cliente → `guardarPdfConAviso`.
- Split monedas: C$ aplicado (`monto_cordobas`); USD muestra `C$X (US$Y)`. Total
  = Σ `monto_cordobas` (invariante #1). Pagos anulados excluidos.
**Audit (2 agentes):** 2 findings LOW (sin bugs). Lo crítico (¿el LEFT JOIN
recibos infla el total?) verificado SEGURO: recibos:pago es 1:1. Apliqué el fix
DRY (reusar `guardarPdfConAviso`). `flutter analyze` limpio.
**Pendiente:** mergear + build de prueba + testing manual de Rubén.

## 2026-06-21 — Rework reportería: plantilla de cobranza por defecto + toggle legacy

**Pedido (Rubén):** Mairena/Telenet compartieron una plantilla Excel que quieren
por DEFAULT en todos los tenants (actuales y futuros). No borrar los reportes
variados actuales: ocultarlos tras un toggle super_admin en Avanzado; por
defecto el módulo se basa en la plantilla.
**Análisis del template** (mail-merge `<<[campo]>>`, 1 hoja): reporte de cobranza
= banner + rango + 4 totales (SUBTOTAL CÓRDOBAS · CAMBIO COMPRA DE DIVISAS ·
TOTAL CÓRDOBAS · TOTAL DÓLARES) + tabla (ID · Nombre · Cobrador · Mes · Recibo #
· Dólar · Córdoba · Compra de Divisas). Toda la data ya existía (= cobros + split
de monedas del arqueo). 5 mapeos confirmados por Rubén: Recibo#=recibo real ·
ID=código del cliente · split C$/US$ · Compra de Divisas = US$×tasa
(monto_cordobas+vuelto) · Mes = período de la cuota.
**Qué se hizo (rama `feature/reportes-plantilla`):**
- `construirReporteCobranzaBytes` en `reporte_excel.dart`: arma el layout exacto
  de la plantilla (banner tipográfico — el paquete `excel` no embebe imágenes;
  el logo va en PDF). Split: NIO→Córdoba; USD→Dólar + Compra de Divisas.
- Card `_ReporteCobranzaCard` (default, siempre) en `reportes_admin_screen.dart`
  con su query de pagos del rango (reporte de CAJA: pagos efectivos sin filtrar
  por estado de contrato). Botón "Generar Excel".
- Toggle **`cobranza.reportes_detallados`** (super_admin, Avanzado, default OFF,
  migración **0141** corrida en prod). OFF → solo la plantilla; ON → además los
  reportes legacy (arqueo + analíticas + FAB PDF/Excel), sin borrar ninguno.
- Test nuevo de los 4 totales + split + layout (`reporte_excel_test.dart`).
**Audit (2 agentes):** 3 findings, todos LOW (sin bugs) — agregué el test
(finding #1) y documenté el criterio de caja (finding #2). Totales verificados
(700/368/1068/10), SQL SQLite-válida, sin duplicar por LEFT JOIN recibos, toggle
sin leak. `flutter analyze` limpio · 5/5 tests OK.
**Pendiente:** mergear + build de prueba + testing manual de Rubén (el Excel y el
toggle). PDF de la plantilla = fast-follow opcional.

## 2026-06-21 — Eliminación completa de audit_log (✅ COMPLETO — deployado en prod)

**Pedido (Rubén):** bajar el PowerSync Data Synced (7.35 GB > 2 GB free). Diagnóstico:
Supabase holgado; solo PowerSync se pasó, y mucho era churn de desarrollo. El driver
estructural real era **`audit_log`** (12 MB, 6.609 filas, crece rápido) que sincroniza
a TODO admin; `op_log` (104 kB) es insignificante. Rubén decidió **borrar `audit_log`
por completo** (era forense/debug, casi sin uso) y dejar solo `op_log`. Trade-off
aceptado: se pierde el rastro forense server-side de resets/impersonación/anulaciones.
**Qué se hizo (rama `feat/remove-audit-log`):**
- **Migración `0140_drop_audit_log.sql`** (verificada contra prod, NO corrida aún):
  drop de **33 triggers** + **9 funciones** + tabla + setting `cobranza.audit_visible_admin`;
  **3 RPCs vivos** (`set_cobrador_rol`/`set_cobrador_activo`/`set_tenant_modulo`)
  **redefinidos sin el insert a audit_log** (los llama el panel super_admin — sin esto
  reventaban al dropear la tabla). Sintaxis validada con begin/rollback en prod.
- **Sync rules:** `audit_log` fuera de los 3 buckets (op_log queda).
- **App (Dart):** borrado el panel `/admin/audit`, `audit_campos_screen`, `AuditEntry`,
  la "auditoría por cobrador" del super_admin (RPC `list_audit_cobrador` + timeline en
  miembro_detalle), los 3 inserts de audit_log en `impersonation_service`, la tabla en
  `schema.dart`, el getter `auditVisibleAdmin`, refs en router/menu/settings.
- **4 edge functions** (cambiar-email, eliminar-cobrador, reenviar-invitacion,
  forzar-password): quitados los inserts a audit_log + su manejo de error (flujos intactos).
- **NO se tocó:** `op_log`, `audit_changelog.dart` (op_log usa sus constantes),
  `op_log_campos_screen`, el getter `auditVisibleAdminCobranza` + setting
  `audit.visible_admin_cobranza` (gatean un historial de op_log VIVO en pagos_admin).
**Audit Fase 4 (2 agentes adversariales):** 5 findings → **4 críticos** (los 3 RPCs que
romperían + el sync-rules línea 313 que un replace_all colapsó) + **1 alto** (leak del
setting huérfano `audit.campos_visibles` como campo crudo, mismo patrón que notif_api).
**Todos corregidos.** Chequeo bulletproof: ninguna función/vista de prod referencia ya
`audit_log` salvo las que 0140 dropea/redefine. `flutter analyze` limpio.
**✅ DEPLOY COMPLETADO (2026-06-21), en orden:** 1) 4 edge functions deployadas (Dashboard);
2) **release v0.12.1** publicado; 3) sync rules flipeadas en PowerSync (Active v13); 4) migración
`0140` corrida en prod + **verificada** (0 triggers de audit, tabla dropeada, 3 RPCs vivos, op_log
intacto, 0 funciones referencian audit_log). Las menciones sueltas de audit_log en ARQUITECTURA
quedaron limpias en el mismo PR.

## 2026-06-21 — RELEASE v0.12.0 publicado

**Pedido:** mergear todo a `main` y buildear el release v0.12.0.
**Qué se hizo:** bump `0.11.10+120 → 0.12.0+121`; `Install Steps/build-release.ps1 -Tag v0.12.0 -Notes "…"`
(Windows MSIX + Android APK con `.env.json` baked + GitHub release + `version.json`). Para firmar el APK con la
release key se copiaron `key.properties` + `android/app/sitecsa-release.jks` (gitignored) a este worktree
(C:\sc-contratos) desde el principal — el de OneDrive compila con MSB3491. **Verificado:** APK firmado
`CN=SITECSA DEV` SHA-256 `28fe94…0ed04` (release, no debug) con `apksigner`; release v0.12.0 Latest con los 3
assets; tag re-apuntado a la HEAD final (`26ea9f3`); release/tag v0.11.10 borrado (`gh release delete
--cleanup-tag`). **Sin wipe de DB** (schema/_dbWipeVersion intactos). Contenido: dashboard 0133 + 4 features
(0134/0135) + WhatsApp API dormido (0137/0138/0139). Migraciones ya en prod; sin redeploy de sync rules.
**Pendiente (cuando Rubén active la API):** deploy de las 2 edge functions + cron en el Dashboard + setup de Meta
(guía `Install Steps/WhatsApp-API-setup.md`).

## 2026-06-21 — WhatsApp API: UI rediseñada a sección reveal-gated en Avanzado

**Pedido (Rubén, con capturas):** la config de la API tiene que estar en Avanzado (super_admin) como **su
propia sección que se habilita con un toggle** — al prender "WhatsApp API" recién aparece abajo la
configuración (estética como el mockup), separada del toggle del WhatsApp gratis (1×1). La primera versión
mostraba todo plano siempre.
**Diagnóstico extra (importante):** las capturas mostraban los campos `notif_api_*` CRUDOS en la pestaña
**Cobranza**. Eso NO es un bug del código nuevo: es el **build viejo** pintándolos genéricamente porque la
migración 0137 ya está en prod (`vxxz`) y la app vieja sincroniza las settings, pero su código no tiene el
`_hidden` + la card. Con un build fresco desaparecen.
**Qué se hizo:** reescribí `_WhatsappApiCard` con el patrón *reveal* del panel (`_DependenciaRevelable`):
header verde "WhatsApp API · PAGO · SUPER ADMIN" + toggle padre (estado local `_apiOn` para reveal
instantáneo, re-sync por `ref.listen`) que con `AnimatedSize`+`AnimatedSwitcher` revela las secciones
Credenciales / Plantillas / Envío automático + botones Guardar/Probar. Apagado = solo el toggle. Mostré
mockup (off/on) antes de implementar.
**Audit (workflow, 3 agentes):** 6 findings (0 críticos) → **fixeados los 4 reales:** `_guardarConfig` con
try/catch+flag+spinner (evita guardado parcial silencioso), toggle con `await`+revert+snackbar ante fallo,
header `Row` con `Expanded`+ellipsis (evita overflow en Android angosto), badge a `fontSize 11`.
**Estado:** mergeado a `main` + verificado en vivo con MSIX local (super_admin Test Mairena): la card y el
reveal andan. **Ajustes posteriores (feedback Rubén):**
- **Idioma** pasó de texto libre a **dropdown** (es / es_MX / es_AR / es_ES, default es) — evita typos que harían
  que Meta rechace el envío.
- **Plantillas con el MISMO editor que el WhatsApp gratis** (pedido de Rubén): cada estado (gracia/mora) tiene
  campo "Nombre de la plantilla en Meta" + botón "Editar mensaje" → editor full-screen (chips + vista previa +
  restaurar) reutilizado de `_PlantillaEditorDialog` con flag `paraMeta`, que agrega el bloque **"Copiar para
  Meta"**. El cuerpo redactado se guarda en `cobranza.notif_api_body_gracia/mora` (migración **0139**, default =
  mismos textos que los avisos gratis) — es BORRADOR/referencia para crear la plantilla en Meta, NO lo que se
  envía. Se pasó de variables posicionales a **CON NOMBRE** (`{{nombre}} {{monto}} {{dias}} {{empresa}}`): el
  editor convierte `{nombre}`→`{{nombre}}` y la **edge function `whatsapp-enviar` ahora manda `parameter_name`**
  (orden-independiente). Guía actualizada. `flutter analyze` limpio.

## 2026-06-21 — WhatsApp por API (modo pago, opt-in) construido y dormido

**Pedido (Rubén):** "dejame todo listo para que yo solo ingrese el access token y el número y haga las
configuraciones y así quede habilitado". Es decir: dejar el modo PAGO (envío automático por la Cloud API de Meta)
listo en el código, conviviendo con el modo gratis (`wa.me` manual) ya existente. Decisiones previas: las 2
opciones coexisten; la gratis se habilita/configura en Cobranza (super_admin); la de API solo se configura en
Avanzado (super_admin) y solo ahí se manda por lote a la hora configurada; frecuencia de re-notificación
configurable.
**Qué se hizo:**
- **Migración 0137** (en prod `vxxz`): 9 settings `cobranza.notif_api_*` (habilitado, phone_id, template_gracia/
  mora/lang, hora, frecuencia, tope_diario, token_configurado — super_admin, categoría cobranza) vía seed
  idempotente + backfill + hook al trigger de seed; tabla **`whatsapp_credenciales`** (server-only, RLS sin
  policies, NO en sync rules → el token nunca llega al cliente); tabla **`whatsapp_envios`** (log para dedup/tope).
- **Migración 0138** (en prod): función `whatsapp_clientes_a_notificar(tenant)` — gracia/mora por cuota más vieja,
  con teléfono, respeta frecuencia (una_vez_estado/cada_3/semanal/cada_15/diario) + tope. **Probada por SQL** con la
  data PROY: elegibilidad y dedup correctos.
- **Edge functions** (escritas, sin deployar — Dashboard manual): `whatsapp-set-token` (super_admin → token al
  server) y `whatsapp-enviar` (modo `uno`=botón Probar super_admin; modo `lote`=cron service-role, itera tenants
  por hora Nicaragua → Meta v21 template message).
- **UI:** `_WhatsappApiCard` en Avanzado (super_admin): toggle + credenciales + plantillas + hora + frecuencia +
  tope + "Guardar configuración" + "Probar con un cliente". Getters `notifApi*` en `AppSettings`; 9 claves en
  `_hidden`.
- **Guía** `Install Steps/WhatsApp-API-setup.md` (Meta → deploy → cron SQL → app) + notas operativas.
- **Audit 2-agentes:** UI sin findings; seguridad 5 no-críticos → **fixeados:** eco del nombre del tenant al
  guardar token (evita cargarlo en el tenant equivocado), insert-if-missing del setting reflejo, botón guardar
  explícito; **documentados:** cadencia del cron, tope vs tenants grandes, doble fuente de TZ.
**No probado** (sin cuenta Meta; la card vive en Avanzado super-only y la app está logueada como admin): envío real
de Meta, botón Probar, cron, render de la card. **Queda DORMIDO** hasta el setup de Meta de Rubén.
**Estado:** todo en `feature/whatsapp-api` (desde `main`), **pendiente de la decisión de merge de Rubén**. Las
migraciones 0137/0138 ya están en prod (aditivas, no afectan a nadie con el modo apagado).

## 2026-06-21 — Dashboard validado + lote de 4 features (Feature 1: Cobros 1 fila/contrato)

**Pedido:** validar el dashboard nuevo con data controlada antes de mergear, y luego un lote de 4 features de
UI/notificaciones.
**Dashboard:** creé 11 clientes de prueba (`PROY01-11`) en el Test Tenant cubriendo todos los escenarios
(hoy/próxima/mora/parcial/exclusiones por cliente inactivo + contrato cancelado); verifiqué que proyección y
recuperación dan **matemáticamente correcto** (esperado = SQL = app, consistencia #10). Mergeado a `main`
(dashboard 0133), **sin release**.
**Fase 2 de 4 features** (investigación con workflow + mockups aprobados): (1) Cobros 1 fila/contrato ·
(2) historial de pagos en la ficha · (3) Avisos gracia/mora (toggle super_admin) · (4) notificar por WhatsApp
(`wa.me` Fase 1, manual, templates editables por admin). Decisiones + tech en memorias AI
`features-plan-cobros-pagos-avisos-whatsapp` y `whatsapp-estado-real` (hoy WhatsApp = solo deep link manual,
sin API; sin infra de email ni columna email en clientes).
**Feature 1 (DONE, mergeado a `main`):** la lista de Cobros pasó de tarjeta-por-cliente-con-desplegable a **una
fila plana por contrato** (cuota más vieja, oldest-first); plan·mes·fecha·estado + saldo + Pagar/Cambiar-fecha
inline; **tap→ficha**; chip **"+N cuotas · C$X más"**. `cobrosFlatQuery` reusa el CTE `lineas` → saldo canónico
y **consistencia #10** (+2 tests; el audit adversarial escribió 6 tests extra). Audit (3 agentes) sin
bloqueantes (3 fixes menores aplicados). Validado en vivo (build local en Test Tenant, data PROY). Commit
`9e984ad`. **Archivos:** `lib/features/cuotas/cobros_query.dart`, `cuotas_list_screen.dart`,
`test/features/cuotas/cobros_resumen_test.dart`.
**Feature 2 (DONE, mergeado a `main`):** sección **"Historial de pagos" READ-ONLY** al final del tab Detalle de
la ficha del cliente (el detalle actual NO se tocó), agrupada por contrato (plan · N pagos), cada pago = mes de
servicio · fecha · método · monto (tachado si anulado). Provider nuevo `clientePagosProvider`
(`contrato_providers.dart`, mismo join que `contratoPagosProvider` pero por cliente, sin LIMIT) + widget
`_HistorialPagosSection`/`_PagoFilaReadOnly` (`cliente_detail_screen.dart`). **Pura UI, sin acciones** (no abre
detalle, no anula — eso vive en el detalle de contrato; NO se duplicó lógica de plata). Audit adversarial 1
agente: sin bloqueantes (fix de orden por mes de servicio aplicado). Validado en vivo con DEMO-001 (4 pagos,
1 anulado). Commit `0de7820`. **Nota de producto pendiente de decisión:** un cobrador ve solo SUS pagos del
cliente (regla de sync; igual que hoy en el detalle de contrato) — aceptar / restringir a admin / poner nota.
**Feature 3 (DONE, mergeado a `main`):** pantalla **Avisos** (`lib/features/admin/avisos/avisos_screen.dart`):
dos secciones — *Próximos a corte (en gracia)* y *En mora* — con tarjetas-resumen (conteo + total) y una fila por
cliente (nombre · comunidad · teléfono · días · monto, tap→ficha). Providers `avisosGracia/avisosMoraProvider`
reusan `cobrosResumenQuery` con filtro gracia/mora (mismo SQL canónico → consistente con los chips de Cobros).
Ítem de menú "Avisos" (adminOnly + `settingKey`) gateado por el toggle super_admin **`cobranza.avisos_habilitado`**
(default FALSE, opt-in; **migración 0134** corrida y verificada en `vxxz`) — gating en 3 capas (menú + ruta + RLS
super-only). Solo lo ven admin/admin_cobranza (NO cobrador). Audit adversarial: **sin findings bloqueantes**.
Validado en vivo (Test Tenant, toggle ON): gracia 4·3.000 / mora 3·2.000, días "corta en 9" / "en mora hace
40/21/6". Commit `d013db0`.
**Feature 4 (DONE, mergeado a `main`):** **notificar por WhatsApp desde Avisos**. Botón "WhatsApp" por cliente +
flujo guiado **"Notificar a todos"** (`_NotificarTodosSheet`, uno-por-uno: abre `wa.me/<505+tel>?text=<msg>` y
avanza). Plantillas de mensaje **editables por el admin** (`cobranza.aviso_msg_gracia`/`_mora`, tab Cobranza) con
placeholders `{nombre}{monto}{dias}{empresa}`; toggle **super_admin `cobranza.notif_whatsapp_habilitado`** (default
OFF) que muestra los botones. **Migración 0135** corrida en `vxxz`. `ExternalActions.whatsapp` reescrito: `?text=`
URL-encoded + normalización código país **505** + `https://wa.me` (elimina el bug viejo de `canLaunchUrl`/
`whatsapp://` — ver [[whatsapp-estado-real]]). Audit adversarial: **sin bloqueantes** (2 findings LOW diferidos:
tel no-nica de 7/9 díg sin 505; `{empresa}` vacío deja "— " colgando). Validado en vivo end-to-end: el link abrió
`api.whatsapp.com/send/?phone=50588880007&text=...` con el mensaje correcto. Commit `f0d5f36`.
**✅ LOTE DE 4 COMPLETO.**
**Refinamientos post-lote (rama `feature/editor-plantillas`):** (a) **fix** — `op_log.campos_visibles` se colaba como
JSON crudo en el grupo "Otros" de Cobranza → agregado a `_hidden` (commit `6f28278`); (b) **editor visual de
plantillas WhatsApp** (`_PlantillasWhatsappCard` + `_PlantillaEditorDialog` en `settings_admin_screen`): reemplaza
los campos de texto apretados por 2 tarjetas (preview + Editar) que abren un editor a pantalla completa con **chips
de variables tap-to-insert** (cero typos) + **vista previa en vivo** + restaurar default. Defaults extraídos a
consts `kAvisoMsg*Default` en `settings_repo`. Validado en vivo (insert + preview + restaurar). Commit `90fb1ae`.
**Pendiente:** release v0.12.0 (cuando Rubén quiera). **Deploy:** 0133/0134/0135 ya en prod; falta solo el
build/release de la app.

---

## 2026-06-20 (g) — Import masivo de clientes (Telecable Mairena) + fix del seed de settings

**Import Telecable Mairena:** 4.601 clientes importados desde un Excel del cliente (su sistema viejo) al tenant
`6fe4d28d` (prod). Geografía Chinandega (Somotillo/Villanueva/Santo Tomás del Norte, 98 comunidades, typos fusionados
+ Title Case). **Solo clientes + geografía** (sin contratos/cuotas — el Excel no traía facturación). Método: xlsx→CSV
(zip+XML), normalización en PowerShell, staging temp + INSERT...SELECT resolviendo `comunidad_id`, **dry-run
BEGIN…ROLLBACK antes del COMMIT**. Detalle en memoria del AI `telecable-mairena-import-clientes`. Sin op_log (alta por
SQL); audit_log forense sí.

**Fix seed de settings (migración `0132`, commit `4260e41`):** Rubén vio que un tenant nuevo (Telenet) no mostraba
"Días de cuota próxima" ni "Cambiar fecha de pago". Causa: **el panel solo dibuja settings que tienen FILA en
`settings`**, y `tenants_seed_settings_trg` quedó viejo — 6 settings agregados por migración (0113/0119/colores/recibo/
audit) se backfillearon a tenants existentes pero **nunca se sumaron al seed** → tenants NUEVOS nacían sin ellos. Fix:
helper `seed_settings_faltantes_0132` (DRY, idempotente) + backfill a todos los tenants + el trigger lo llama para los
futuros. Verificado (Telenet 54→60; 0 tenants sin las claves). **Receta R6 actualizada**: sembrar para tenants nuevos
es OBLIGATORIO, no solo backfillear.

**Pendientes:** ninguno. Telenet: refrescar/re-sincronizar la app para ver las opciones.

---

## 2026-06-20 (f) — Cierre Fase 6 retroactivo: docs canónicos reflejan op_log/email/galería/filtros

**Qué se pidió/por qué:** la verificación doc↔código (workflow) detectó que ARQUITECTURA/PRODUCTO/AGENTS NO
documentaban op_log (el rework central), `clientes.email`, el menú galería ni los filtros multi-selección — solo vivían
en `CHANGELOG-REWORK.md` + BITACORA. Es el tipo de drift que causó el bug de op_log (entró sin pasar por R10). Rubén
autorizó el cierre Fase 6 retroactivo.

**Qué se hizo** (workflow de 3 agentes, 1 por doc, + review manual del diff antes de commitear):
- **ARQUITECTURA.md** (+251/-102): sección Audit/Change log REESCRITA a op_log (modelo vigente) con `audit_log` como
  forense no-leído-en-UI; **R18** nueva ("emitir op_log en una entidad"); R10 actualizada (`super_admin_all` + UPDATE
  por upsert + op_log en vez de audit); R12 = galería de inicio; email (0130), filtros `FiltroMultiDropdown`, dashboard
  a `/admin/resumen`; §5 settings (`op_log.campos_visibles`), §6 wiring, §7 file map, footer (migraciones 0001→0131).
- **PRODUCTO.md**: galería de inicio (jornada admin paso 0), email opcional, change log = intención (principio 4).
- **AGENTS.md**: "Modelo del change log" = op_log (cliente escribe; `audit_log` forense); principio #1 RLS reforzado
  con `super_admin_all` a mano (ejemplo del bug op_log 0131); §0 ref R1-R18.
- Review manual: corregí `escribirOperacion`→`escribir` (método real de `OpLog`) y `R1-R12`→`R1-R18`.
- Commit `bdb5f13`.

**Pendientes:** ninguno. Los 8 docs del sistema quedan consistentes con el código en `main`.

---

## 2026-06-20 (e) — Fix: op_log rechazaba al super_admin (faltaba policy super_admin_all)

**Qué se pidió/por qué:** Rubén, impersonando "Test Mairena", toggleó "Permitir pago parcial" y saltó "Un cambio en
op_log fue rechazado por el servidor: Sin permiso para esta operación (o el módulo está desactivado)". El rework de
op_log emite una fila por cambio de setting, y el INSERT lo rechazaba RLS.

**Causa raíz:** las policies de op_log (0128 insert/read, 0129 update) chequean `tenant_id = current_tenant_id()`,
pero el super_admin (impersonando) no tiene un current_tenant_id() que matchee → todo INSERT/UPDATE de op_log del
super_admin se rechazaba (42501). Faltaba la policy `super_admin_all` (is_super_admin()) que R10 manda agregar a mano
y que SÍ tienen clientes/cuotas/cliente_etiquetas/saldos_favor. (El READ no se notaba: el super_admin lee op_log por
las sync rules de PowerSync, no por esta policy RLS.)

**Qué se hizo:** migración `0131_op_log_super_admin_policy.sql` (`super_admin_all FOR ALL USING/WITH CHECK
is_super_admin()`), aplicada a producción (`vxxz`) y verificada. Chequeo adversarial: **0 tablas** tenant-scoped
quedan sin bypass super_admin (op_log era la única). Commit `2ffda07`.

**Pendientes:** Rubén re-testea el toggle de setting impersonando (ya no debería salir el error).

---

## 2026-06-20 (d) — Hotfix: APK debug-signed (Android no actualizaba) + CI verde

**Qué se pidió/por qué:** Rubén reportó (1) GitHub "All checks have failed" y (2) que en Android el update de
v0.11.10 **no dejaba instalar** ("antes funcionaba").

**Qué se hizo:**
- **🔴 Causa raíz Android (firma):** compilé el release desde `C:\sc-changelog`, que NO tiene `android/key.properties`
  + `sitecsa-release.jks` (gitignored, solo en el worktree principal). `build.gradle.kts` cae a la **debug key** sin
  ellos → APK con firma distinta a v0.11.9 → Android rechaza el update (el comentario del propio gradle ya advertía
  esto). **Fix:** copié la llave a `sc-changelog`, recompilé el APK (firma release `CN=SITECSA DEV`, SHA-256
  `28fe94…ed04`, verificado con `apksigner verify --print-certs`, coincide con el keystore) y lo re-subí al release
  con `gh release upload v0.11.10 --clobber`. Windows/MSIX NO afectado (cert de test bundleado del paquete `msix`).
- **Prevención:** `build-release.ps1` ahora aborta si falta `android/key.properties` (commit `ae6adef`).
- **CI verde:** los 2 checks estaban rojos en TODOS los commits (pre-existente, no rompió el release). *Analyze+Test*:
  4 `unnecessary_non_null_assertion` en `contrato_detail_header.dart` (quitados los `!`). *SQL compatible*: falso
  positivo — `date_trunc` en un comentario de `pagos_repo.dart` (reescrito). `flutter analyze --no-fatal-infos` → 0
  warnings (quedan 4 info de deprecaciones SDK, no bloquean). Commit `ae6adef`.

**Pendientes:** ninguno. Rubén re-dispara el update en el teléfono (la app baja de nuevo `CRM.apk`, ya correcto).

---

## 2026-06-20 (c) — Merge a `main` + release v0.11.10 a producción + limpieza de ramas + aclaración PROD

**Qué se pidió/por qué:** Rubén: "subamos todo a main, ya es digno de producción; borrar todos los branches y dejar
solo main; subir el nuevo release v0.11.10." El lote: rework de change logs (op_log, ver `CHANGELOG-REWORK.md`) +
email opcional del cliente + menú de inicio tipo galería.

**Qué se hizo:**
- **Merge a `main`** (ff-only) de todo el lote + push a `origin/main`.
- **Limpieza de ramas:** borradas TODAS las remotas no-main (GitHub queda con solo `main`) + 10 locales + 4 worktrees
  obsoletos. Worktrees vivos: principal (`main`), `C:\sc-changelog` (build), `C:\sc-contratos`, el de la sesión activa.
- **🔎 Reconciliación DEV/PROD (clave):** se descubrió que los 3 `.env.json` apuntan a `vxxzesbmilfolwjhfxgr` (lo que
  hornea el release) y que hay 2 proyectos Supabase. Rubén CONFIRMÓ: **`vxxz` ("Template TT") = PRODUCCIÓN** (no "DEV"
  como decía el AGENTS). → el deploy a PROD ya estaba hecho (las migraciones 0119→0130 se corrieron contra `vxxz`).
- **Verificación de producción (`vxxz`):** schema completo (email/op_log/saldos_favor/cliente_etiquetas/cancelación) +
  `invariantes_dinero.sql` → todo 0 salvo INV9 ×2 (cuotas del cliente de prueba DEMO-001 con cobrador null) → corregido
  con UPDATE → re-check 0. Sync rules ya Active (op_log sincroniza, verificado en vivo). NO se tocó PowerSync.
- **Release v0.11.10:** `build-release.ps1 -Tag v0.11.10 -Notes "..."` (Windows MSIX + Android APK 96.8MB con el
  `.env.json` de producción) → GitHub Release creado (3 assets, `version.json`→0.11.10) → **auto-update vivo**.
  Borrado el release/tag viejo **v0.11.9** (`gh release delete --cleanup-tag`) → solo v0.11.10 como Latest.
- **Docs:** corregida la confusión DEV/PROD en AGENTS §"Acceso del AI" + este ESTADO ACTUAL; memoria del AI
  `supabase-vxxz-es-produccion` creada.

**Pendientes:** ninguno bloqueante. Worktrees `sc-changelog`/`sc-contratos` quedan (tienen `.env.json` + entorno de
build); limpiarlos cuando Rubén quiera (no afecta GitHub). Backlog vivo abajo sin cambios.

---

## 2026-06-19 (b) — Eval de arquitectura + chokepoint oldest-first (#4) + desacople wipe↔schema (#1)

**Qué se pidió/por qué:** tras el checkpoint, Rubén preguntó (1) si los bumps de schema que re-descargan todo siguen
siendo necesarios y cómo lo manejan apps Supabase+PowerSync bien hechas, y (2) que el oldest-first sea infranqueable
por la app (online y offline), aceptando NO poner trigger SQL. Pidió evaluación completa de arquitectura con feedback
y propuestas, explicada con gráficos, sin romper lo que funciona.

**Evaluación (3 workflows con verificación adversarial):**
- **Re-sync por bump = anti-patrón autoinfligido.** PowerSync es schemaless (el schema del cliente es una VIEW sobre
  JSON); cambiarlo NO debe re-descargar. La versión vivía en el NOMBRE del archivo → cada bump = DB nueva vacía =
  re-sync. **31 de 32 bumps fueron aditivos (97%)** → re-sync evitable. Sync rules BIEN diseñadas (el cobrador baja
  solo su slice, ~2 MB; no hay over-sync). Free tier no se agota hoy con un tenant; el costo es UX + datos móviles, y
  escala feo (≈usuarios × releases × slice).
- **Oldest-first:** el "fix" del backlog (trigger BEFORE INSERT) se REFUTÓ (rompe multi-cobro contiguo + cascada
  offline en orden arbitrario; `contrato_id` NOT NULL). La vía segura es un chokepoint CLIENTE.
- **Aislamiento entre usuarios:** la fuga histórica ("se veía data del usuario anterior por segundos") la arregló el
  **userId del filename** (`8fe71c6`) + el **`dbEpochProvider`** (`a5a2167`), NO la versión (entró 19h después por
  schema-cache, `8924bf3`). → quitar la versión es SEGURO para el aislamiento (lo da el userId, no la versión).

**Hecho (aprobado por Rubén: #4 + #1 ahora; #2/#3 diferidas):**
- **#4 — Chokepoint oldest-first (`58a4d0c`):** `pagos_repo._validarOldestFirst(cuotaIds)` al inicio de
  `registrarCobro`/`registrarCobroMultiple`, ANTES de cualquier INSERT, consultando el SQLite local (online y
  offline). Agrupa por contrato; excluye cargos manuales (`tipo_cargo_manual`) y anuladas; exige el prefijo contiguo
  más viejo; ties (misma venc+período) intercambiables. `CobroFueraDeOrdenException` (mensaje español vía
  `mensajeErrorHumano`). 4 tests nuevos. Es el **invariante #11** de AGENTS. Cierra el 🔶 backlog del lado cliente.
- **#1 — Desacople wipe↔schema (`5bfd07e`):** `_schemaVersion`→`_dbWipeVersion` (renombre + semántica). El sufijo del
  archivo pasa de `_v33` a `_w1`: los cambios ADITIVOS (columna/tabla/índice) ya NO bumpean ni re-descargan —
  PowerSync los aplica in-place al reabrir. Bump (wipe) reservado para destructivos/cache-corrupto. Política en
  ARQUITECTURA R4/R10. **Prueba de seguridad nueva** `test/powersync/schema_inplace_test.dart` (go/no-go): reabrir el
  mismo archivo con columna/índice nuevos preserva los datos y NO da el error de schema-cache → el bug histórico
  `8924bf3` NO reaparece en PowerSync 1.18. Suite completa **346 verde**.
- **#2 (audit_log on-demand) DIFERIDA (2C):** rompería el offline-first de los historiales y Rubén va a reworkear los
  change logs (audit_log) igual → se revisita en ese rework. **#3 (prioridades de bucket) DIFERIDA:** la versión que
  vale toca el sync gate recién blindado y es manual-test-only; el grace de 8s ya cubre lo grueso.

**Pendiente:** testear #1/#4 en build fresco (ver ESTADO ACTUAL → PRÓXIMA SESIÓN), merge a `main`, deploy PROD en
orden + build (primer build = un re-sync de transición por `_w1`). Rework de change logs = sesión futura de Rubén.

---

## 2026-06-19 — Fix cold-start + rediseño lista de Cobros (compacta + escala)

**Qué se pidió/por qué:** Rubén pidió (1) arreglar el bug de cold-start (pre-release), (2) un ajuste visual de la
lista de cobros con mockups, y (3) que "Ver todo" muestre TODOS los clientes y escale (qué pasa con +1000). Fase 2
con mockups + decisiones: **Propuesta B (compacta)**, **Opción 2 (resumen por cliente en SQL)**, total = **cobrable
ahora (oldest-first)**.

**Hecho (rama `claude/unruffled-austin-ffec41`, ff desde `ui-improvements 51f82b9`):**
- **Cold-start (`a091858`):** el "ClosedException" en Cobros y el falso "Sin conexión" eran por no respetar
  `dbEpochProvider` (#7). `_CobrosList` ahora es ConsumerStatefulWidget y recrea su stream al recrearse la DB (+ los
  streams admin del padre); `conexionRealProvider` observa el epoch → arranca optimista de nuevo. Patrón existente
  (`rutas_screen.dart:157`). Backlog: 3 `ps.db.watch` inline-en-build más (buscadores de inventario/tickets, geo).
- **Rediseño Cobros (`df3d8f0`):** Propuesta B compacta — una **tarjeta-resumen por cliente** (código·nombre ·
  comunidad · N a cobrar · estado + total + Pagar + barra de color); **tocarla EXPANDE** y carga el detalle (un
  renglón por contrato con Pagar/Cambiar fecha + "Ver ficha"). **Opción 2:** el stream principal trae **1 fila por
  cliente agregada en SQL** (ROW_NUMBER por contrato → cuota más vieja; SUM saldo canónico; el detalle se carga al
  expandir, memoizado). Antes traía TODAS las cuotas y agrupaba en Dart cada rebuild → ahora "Ver todo" escala a
  miles sin tironear. Total por cliente = **cobrable ahora** (Σ cuota más vieja por contrato, oldest-first; métrica
  propia, distinta del pendiente total del dashboard — decisión de Rubén). Índice `by_contrato_vencimiento`
  (schema **v32→v33**; el resumen NO lo usa pero sí mapa/contrato_detail) + debounce 250ms en el buscador. SQL
  extraído a `cobros_query.dart` (Dart puro) para testearlo igual que la app.
- **Verificación:** smoke confirmó que el SQLite de PowerSync corre window functions (sin precedente en el repo).
  Test nuevo `cobros_resumen_test.dart` (8 casos, **SQLite real**): total resumen == suma del detalle (#10), oldest
  determinista en empate, orden, clamp ≥0, filtro admin, exclusiones, y **watch refire** al pagar / asignar etiqueta
  (riesgo de lista congelada → descartado). `analyze` limpio · **suite 339 verde**.
- **Audit Fase 4 (`56735ed` + fix):** workflow adversarial 3 dim + verificación. 0 bugs accionables; 3 mejoras de
  calidad aplicadas en el path de dinero: `oldest_cuota_id` DETERMINISTA (2do ROW_NUMBER por cliente, saca la
  dependencia del bare-column-con-MIN), comentario del índice corregido (load-bearing para mapa/contrato_detail, no
  para el resumen — verificado con EQP), "N cuotas" → "N a cobrar" (era el conteo de líneas cobrables-ahora, no de
  cuotas pendientes).
- **Mejoras de claridad (QA visual en vivo, `bfe768c`):** del testing como cobrador novato salieron 2 (no cambian
  el flujo cobrable-ahora, solo dan contexto): chip rojo **"N cuotas vencidas · debe C$X"** cuando el cliente
  arrastra MÁS cuotas vencidas que las líneas cobrables-ahora (el resumen agrega `vencidas_count`/`vencido_total`);
  y **"Parcial · abonó C$X de C$Y"** en la cuota parcial. Sin schema. Test del agregado. Suite **340**.
- **Lista de Clientes (admin) COMPLETA (`8d99dc2`):** a pedido de Rubén, sin "Cargar más" — el watch local trae
  TODOS los clientes del filtro + `ListView` virtualizado (se quitó la paginación pageSize/_onLoadMore). + seed de
  **200 clientes `QA-SCROLL-*`** con geo random en Nicaragua (para el scroll de Clientes/Cobros y verlos en el mapa).
- **✅ TESTEO MANUAL EN VIVO (2026-06-19, release v33 local, admin real):** cold-start OK (Cobros carga sin
  ClosedException tras recrear la DB v32→v33, sin banner falso; redirige solo a /admin) · lista compacta + expandir
  + multi-contrato (RA0001 600+800=1.400) · "Ver todo" + **scroll a 220+ clientes** (Cobros trae todo virtualizado;
  Clientes ahora también completo) · `QA-VIS-*` con números EXACTOS vs la DB (cobrable-ahora, parcial 200, chip "5
  cuotas vencidas · debe 2.500", marca de parcial) · geo random en el mapa · **REACTIVAR D/A/B/E TODOS PASARON**
  (D: jul prepagado quedó 900, NO 1.800 = el gate del sobre-cobro funciona; A: el calendario deshabilita los días
  ≤ el de suspensión; B: corte jun intacto 900 + jul-mar revividas 900; E: cross-month jul=120 prorrateo, reanudadas
  900 día 10, pausa no cobrada — los 4 verificados en la DB). `credito_excedente` se apagó para el reactivar puro y
  se restauró a ON; seed TEST-R* reseteado a limpio. Validado.

**Pendiente:** merge `ui-improvements` → `main` + deploy a PROD (`0119→0127` + sync rules) + build/release (schema
**v33**). Seed `QA-VIS-*` sigue en DEV (limpiable). El "N a cobrar"/total es cobrable-ahora (matiz aceptado; el chip
de deuda vencida da el contexto del backlog).

---

## 2026-06-18 (c) — Crédito por excedente al suspender / cancelar (0127)

**Qué se pidió/por qué:** Rubén notó que si un cliente pagó por adelantado y suspende/cancela, el excedente (pago
por servicio que NO se prestará) se PERDÍA en silencio (quedaba como cuota "pagada" sin servicio, o clamp "sin
reembolso"). Pidió que admin/admin_cobranza pueda **acreditar / devolver / condonar** ese excedente (no automático),
habilitable por super_admin (default ON), saldo a favor a nivel CLIENTE (aplica a cualquier contrato suyo), no caduca.

**Modelo (validado adversarialmente ANTES de codear — 5 lentes vs 10 invariantes):** el primer diseño (crédito como
`pago metodo='credito'`) rompía ~15 agregados de caja → **pivote**: el crédito NO es un pago. Vive en tabla nueva
`saldos_favor` (libro append-only: acreditado/aplicado/devuelto/condonado/revertido). APLICARLO = `cargos_extra`
origen='credito' tipo='credito_aplicado' que RESTA del saldo canónico (no toca `pagos` ni el arqueo). Invariante #4
se PARTE: `recaudado_caja = SUM(pagos no anulados) − SUM(devuelto)` vs `cobertura_cuota = monto+cargos_neto−pagado`.

**Hecho (`ea1b65a`, schema v32):**
- **0127:** `saldos_favor` (R10: RLS + super_admin_all + append-only + trigger anti-sobregiro + audit) · tipo
  `cargos_extra credito_aplicado` · `calcular_cargos_neto` + `cuota_total_a_cobrar` restan credito_aplicado · setting
  `cobranza.credito_excedente` super-only default ON.
- **Cálculo:** `excedenteCuota` (prorrateo.dart, anclado día_pago) + `previewExcedente`/`registrarDisposicionExcedente`/
  `aplicarCredito`/`saldoFavorDisponible` (contratos_repo) + revert-aware en revertirSuspension/Cancelacion.
- **UI:** `DisposicionExcedenteSelector` (compartido susp/cancel) · chip "Saldo a favor" + Aplicar (detalle cliente,
  cross-contrato oldest-first) · aviso al desactivar el setting (settings_admin_screen, extensible).
- **Cierre money:** arqueo resta devoluciones (LEFT JOIN) · audit-changelog de saldos_favor · INV14 fix + INV15/16 ·
  seed `seed_credito_excedente.sql` (TEST-CE1..CE3).
- **Audit Fase 4 adversarial (15 agentes):** 9 findings (2 críticos: `cuota_total_a_cobrar` no restaba credito →
  server revertía la cuota; arqueo INNER JOIN perdía devoluciones), **todos fixeados**. `analyze` limpio · suite 331 ·
  invariantes 0 en DEV.

**Pendiente:** redeploy de sync rules (PowerSync) + rebuild v32 para testear en la app. Testing manual de las 3
disposiciones + aplicar (seed TEST-CE*). Detalle del modelo: ARQUITECTURA **Receta R17** + §3.5.

---

## 2026-06-18 (b) — Reactivar suspensión en CUALQUIER día (feedback de tenants)

**Qué se pidió/por qué:** los tenants pidieron reactivar una suspensión SIN esperar al mes siguiente (hoy el guard
obligaba a un mes posterior). Decisión de Rubén (Fase 2 con estudio adversarial + mockups): permitir reactivar
**cualquier día POSTERIOR** a la suspensión (mismo día → Revertir); se mantiene el modelo actual de reactivar
(re-ancla el `dia_pago` al día de reactivación, la pausa NO se cobra, sin puente de reingreso).

**Estudio (workflow, 4 frentes + verificación adversarial con barrido de 21.952 casos):** confirmó que relajar el
guard a secas SUB-COBRA en el sub-caso "suspendió DESPUÉS del día de pago + reactivó el MISMO ciclo" (~1 mes sin
facturar). Descartó la variante "puente de reingreso" (contradecía la decisión de no cobrar la pausa) y la de
"fecha fija".

**Hecho (`contratos_repo.dart` `reactivarContrato` + `suspension_dialogs.dart`):**
- **Guard relajado:** de "mes posterior" → "**día estrictamente posterior** a `suspendido_en`" (mismo día →
  Revertir, con su mensaje). El date-picker del diálogo permite cualquier día desde `suspendido_en + 1` (default: hoy).
- **Re-completar el corte (sub-caso 4):** cuando la cuota de corte (en_curso prorrateada) colisiona con el primer
  ciclo reanudado (`periodo == mesRNext`, UNIQUE) y no se revive, se **RE-COMPLETA** (prorrateo + mes reanudado,
  venc al día nuevo) → NO sub-cobra. Ej. corte 150 + reanudado 900 = cuota de 1050; el recibo desglosa ambos.
- **Tests** (con `dia_pago=20` ≠ 1, para no cegar el bug de anclaje §1c): guard del mismo día; mismo-mes ANTES del
  día de pago (corte intacto + revive desde la reactivación); sub-caso 4 (corte re-completado a 1050). Suite verde.
- **Docs:** R14 + §3.5 (la regla "mes posterior" deja de valer).
- **Audit Fase 4 (2 agentes adversariales):** 1 **CRÍTICO** encontrado + arreglado — la query del re-completar
  agarraba CUALQUIER cuota no-anulada en mesRNext, incluida una **ya pagada por adelantado** (sobre-cobro de un mes
  entero). Fix: gate `monto < precioMensual` (el corte siempre es < un ciclo; un mes pagado entero = precioMensual)
  + test. Resto limpio (clamp, indefinidos/UNIQUE, bordes del guard, invariantes #7/#8, anclaje §1c, SQLite-compat).

**Pendiente:** build para testeo manual + **re-testear el reactivar normal (cross-month)** porque cambió el guard.

---

## 2026-06-18 — Revertir suspensión/cancelación (deshacer por error)

**Qué se pidió/por qué:** poder deshacer una suspensión/cancelación hecha por ERROR, volviendo al estado EXACTO
previo (Rubén). **Reactivar NO sirve** para esto: es reinicio limpio tras una pausa real (no factura el período
pausado, exige mes posterior). Decisión (Fase 2, con mockup): Revertir admin-only + reforzar la confirmación de
Cancelar. Marcador code-only (sin migración).

**Hecho (`contratos_repo.dart` + `contrato_detail_screen.dart`):**
- **Snapshot del estado previo:** al suspender/cancelar se guarda `cuotas_previas` ({id, monto, estado,
  fecha_vencimiento, monto_pagado, cargos_neto}) dentro del `deuda_snapshot`/`cancelacion_deuda_snapshot` JSON —
  **sin migración** (la columna ya existe). Permite restaurar la cuota en curso a su monto ORIGINAL (que el
  prorrateo pisaba).
- **`revertirSuspension` / `revertirCancelacion`:** restauran cada cuota a su estado/monto/vencimiento previo
  (des-anulan), dejan el contrato `activo` (suspensión: SIN re-anclar dia_pago; cancelación: limpian `cancelado_*`
  y re-abren las notificaciones de mora resueltas). Append-only: el change-log audita el revert; la fila de
  suspensión se cierra (`reactivado_en`).
- **Guarda:** solo si NO se cobró NI se aplicó cargo/descuento después (compara `monto_pagado` + `cargos_neto` vs el
  snapshot); si no, aborta y manda a Reactivar/cobro normal. Admin/admin_cobranza, no impersonando. UI: botón
  "Revertir" en `_SuspensionCard` y "Revertir cancelación" en `_CancelacionCard` + diálogos + línea de refuerzo en
  el diálogo de Cancelar.
- **Audit Fase 4 adversarial de dinero** (24 agentes, 20 findings → 5 confirmados): 1 media (la guarda ignoraba
  `cargos_neto` → **FIXED**) + 2 bajas (re-escribía cuotas no tocadas → skip no-op; confundía "sin cuotas vivas"
  con "legacy" → `containsKey`) + 1 baja de doc (abajo). 15 descartados (incl. 2 "INV3 roto" NO alcanzables).
  **46 tests** (6 de revert) + analyze limpio.

**Aceptado (no se arregla):** revertir una suspensión que clampeó una cuota a 'pagada' puede re-abrir su
notificación de mora vía el trigger server `trg_reabrir_notificacion_al_anular_pago` — es correcto (la cuota vuelve
a deber) y round-trip neutro (la suspensión la había resuelto antes).

**Fix en testing manual (jsonb double-encode):** al revertir una cancelación saltaba `type
'String' is not a subtype of Map`. Causa: `cancelacion_deuda_snapshot` (0123) es **`jsonb`** y el
round-trip de PowerSync deja el snapshot DOBLE-codificado (`"{...}"`) → `jsonDecode` daba un
String. (El `deuda_snapshot` de suspensión es `text` y no sufre esto.) Fix: **decode robusto**
en el cliente (`decodeSnapshotMap`, tolera ambos formatos; usado en revert/PDF/tarjeta) +
**migración 0126** (jsonb→text, consistente con suspensión + des-doble-codifica lo existente).
Además la validación del revert se movió FUERA de la transacción (el `StateError` llegaba
enmascarado a la UI como mensaje genérico).

**Pendiente:** build con Revertir para el testeo manual + correr **0126** en DEV (opcional con
el decode robusto, pero recomendado por consistencia).

---

## 2026-06-17 (f) — Audit Fase 4 de cierre del lote + 2 bugs de código + docs + proceso

**Qué se pidió/por qué:** al testear el toggle de Visitas no aparecía → se descubrió que Rubén testeó TODA la
sesión contra la app INSTALADA vieja (MSIX v0.11.9.0) mientras el código estaba en v0.11.10 sin compilar (el
`.exe` del runner no cambia de timestamp; el código vive en `data/app.so`). Pidió auditar todo el lote y los
`.md`, y reforzar el proceso para que no se repita.

**Hecho (audit multi-agente: 4 dimensiones + verificación adversarial; 10/13 findings confirmados, 3 descartados):**
- **D1 (código, ALTA):** las listas de clientes (cobrador + admin) y el export a Excel contaban mora/saldo de
  contratos SUSPENDIDOS/cancelados — el resto del lote (mapa, dashboard, cron 0124) ya los excluía (rompía inv. #10).
  Fix: filtro `COALESCE((SELECT ct2.estado…),'activo')='activo'` en el JOIN de cuotas (espeja el mapa). Decisión de
  Rubén: cancelados fuera de los flujos diarios; su deuda se cobra desde el detalle (+ backlog: reporte de bajas).
- **D2 (código, MEDIA):** un contrato suspendido caía bajo el header "Contratos cancelados" (tachado, gris) en el
  detalle en pestañas. Fix: split en 3 (activos / suspendidos prominentes con su badge / terminales colapsados).
- **Descartados (3):** sobre-abono del mes en curso sin reembolso (decisión cerrada, espeja suspender), snapshot de
  deuda "no refleja mora futura" (mecanismo falso: `cargos_neto` no crece con el tiempo), `cancelado_por` (CLEAN).
- **Cierre de docs (Fase 6):** BITACORA (esta entrada + ESTADO ACTUAL + deploy v31/0119→0125), ARQUITECTURA
  (cancelar = dinámica permanente + receta R16 + schema v31 + módulo etiquetas/tabs/visitas), PRODUCTO (matiz
  visitas opt-in + footers), TESTING (cancelar reescrito + checklist visitas).
- **Proceso (lo que más dolió):** TESTING §0.0 GATE de build fresco + §0.3.0 rol/identidad de prueba; AGENTS Fase 5
  ahora exige declarar build esperado + rol/identidad en cada handoff.

**Pendiente:** build schema **v31** para el testing manual + merge a `ui-improvements`.

---

## 2026-06-17 (e) — Detalle de cliente en pestañas + cancelar permanente + toggle de Visitas

**Qué se pidió/por qué:** rediseñar el detalle del cliente con pestañas en forma de botones (Detalle / Contratos /
Equipos / Visitas) con la identidad fija debajo; que cancelar un contrato deje de liquidar a 0 y pase a la dinámica
de suspender pero PERMANENTE (deuda real cobrable); y que el registro de visitas sea opcional por tenant.

**Hecho (commits `db2015d` → `ed110fc`):**
- **Detalle en pestañas** (`db2015d`/`ab72fb6`/`9b92d87`): `_TabButton` (Detalle/Contratos/Equipos/Visitas), header
  de identidad persistente, tab Detalle estilo Opción A (etiquetas + fotos en 2 columnas), `_ContratoPreviewCard`
  (la tarjeta del detalle de contrato + "Pagadas X/Y"). Equipos solo con módulo de inventario. **Fix:** la foto ya
  no recarga al cambiar de pestaña (cache estática de URLs firmadas en `foto_gallery_widget.dart`).
- **Cancelar = suspensión permanente** (`4a20ca3`, **0123**, schema **v30→v31**): `ContratosRepo.cancelarContrato`
  espeja `suspenderContrato` (cumplido=intacto, en_curso=prorrateo por ventana de servicio del día_pago, futuro=anular),
  deja viva/cobrable la deuda real, imprime documento de deuda, resuelve notificaciones de mora, y NO reactiva.
  Columnas `cancelado_en/cancelado_por/motivo_cancelacion/cancelacion_deuda_snapshot`. **0124**: el cron de mora
  excluye contratos no-activos (fix del badge fantasma). Tarjeta de cobro en el detalle del contrato.
- **Toggle de Visitas** (`ed110fc`, **0125**): la pestaña Visitas es opcional, gateada por el setting super-admin
  `cobranza.registrar_visitas` (default OFF, patrón de pantalla de pagos / auditoría). "Registrar visita" oculto +
  bloqueado en el servicio al impersonar (se atribuiría al super_admin). Botón "Etiqueta" movido arriba.

**Pendiente:** auditado y cerrado en la entrada (f).

---

## 2026-06-17 (d) — P5: módulo de etiquetas personalizables de clientes

**Qué se pidió/por qué:** marcar clientes con etiquetas libres (VIP, moroso histórico, zona difícil…) con color
+ icono, visibles en lista/cobros/mapa. **Decisiones de Rubén (Fase 2, con mockups):** un cliente puede tener
VARIAS; el catálogo lo crea el admin; **ASIGNAR = solo admin/admin_cobranza** (el cobrador solo LAS VE); en el
mapa el pin sigue coloreado por estado de cobro y la etiqueta va como **punto extra + popup**; **sin filtro** por
etiqueta por ahora.

**Hecho (commits `7c0c3cc` → `b39ed14`):**
- **Migración 0122** (DEV, verificada): tablas `etiquetas` (catálogo) + `cliente_etiquetas` (M2M) — R10 ×2: RLS
  (read tenant, write admin/cobranza, `super_admin_all` a mano), audit triggers, `cobrador_id` denormalizado +
  extensión de la cascada `propagate_cobrador_id_from_cliente` (0068). **Schema v29→v30**, sync rules v11.
- **Data layer:** `icono_helpers.dart` (icon picker, clave→IconData), modelo `Etiqueta`, `EtiquetasRepo`
  (CRUD + asignar/quitar idempotente), `EtiquetaChip` (parser GROUP_CONCAT con `char(31)`/`char(30)`), registro
  en `audit_changelog.dart` + lookup `etiqueta_id`→nombre.
- **UI:** pantalla de catálogo en Administración → **Etiquetas** (color picker reusado + icon grid + preview);
  asignación en el detalle del cliente (sheet con checks); chips en **lista cobrador + lista admin + cobros +
  detalle**; **mapa** (punto sobre el pin + lista en el popup). Subquery escalar (no fan-out).
- **Audit Fase 4** (3 agentes + verificación adversarial): 1 finding **media** confirmado (faltaba
  `cliente_etiquetas` en el agregador `HistorialClienteWidget`) + 2 bajas → **los 3 aplicados** (`b39ed14`):
  agregador + resolución de nombre + `asignar` idempotente. Resto **clean** (RLS, cascada byte-idéntica sin
  regresión, sync rules, SQLite-compat, lifecycle, denormalización en INSERT). `analyze` limpio · suite **315**.

**Pendiente:** ✅ sync rules v11 en DEV (Active). Build para testeo quedó englobado en el build schema **v31** del
cierre del lote (entrada (f)); sin build/release a usuarios (sigue el gate de deploy a PROD primero).

---

## 2026-06-17 (c) — P4: tag de cantidad de contratos siempre visible en clientes

**Qué se pidió/por qué:** que la lista de clientes muestre SIEMPRE cuántos contratos tiene cada cliente. Hasta
ahora el chip solo aparecía con 2+ (indicador de multi-contrato); con 1 contrato no se veía nada → de un
vistazo no se sabía cuántos servicios tiene.

**Hecho (commit `6b4d413`):**
- Umbral del chip bajado de `>= 2` a siempre visible, en LAS DOS listas (consistencia inv. #10): cobrador
  (`clientes_list_screen.dart`) y admin (`clientes_admin_screen.dart`).
- Singular/plural: `1 contrato` / `N contratos` (color primary). **0 contratos activos** (cliente nuevo sin
  contrato o con su único contrato SUSPENDIDO) → chip gris **`Sin contrato`** (decisión de Rubén: mostrarlo
  igual; un solo-suspendido también lo muestra).
- `contratos_activos` (COUNT estado activo) YA venía en ambas queries → **cero cambios de SQL/schema/dinero/
  rutas/sync**. Puro cliente; reusa `Icons.description_outlined`.

**Audit (Fase 4):** sin findings. `analyze` limpio en los 2 archivos · suite **315 verdes**. Testing manual en
build pendiente (basta hot reload; checklist en TESTING §0.3).

**Pendiente:** P5 (módulo de tags personalizables color+icono para clientes — tipo R10).

---

## 2026-06-17 (b) — P3 (reasignación masiva de cobrador) + P3b (clientes/contratos sin cobrador)

**Qué se pidió/por qué:** un tenant pidió poder rotar cobradores por zona (reasignación masiva) y que un
cliente/contrato pueda existir SIN cobrador. **Aclaración clave de Rubén (regla de oro):** el `cobrador_id`
del CLIENTE es solo organizativo (en qué lista/ruta/mapa aparece); QUIÉN cobró de verdad lo captura
`pagos.cobrador_id` (el usuario logueado: cobrador, admin o admin_cobranza) y el recibo + la reportería
agrupan por eso. Reasignar un cliente NO cambia el historial de quién cobró.

**P3 — reasignación masiva (commits `2e324ae`, `5fe6ff5`, `130733d`):**
- **Pantalla "Rutas"** nueva (`/admin/rutas`, menú admin, no adminOnly): comunidades con su cobrador derivado
  (o "Mixto"/"Sin asignar" en ROJO) + #clientes; "Reasignar ruta" → `UPDATE clientes SET cobrador_id WHERE
  comunidad_id AND activo=1` (resetea TODOS los activos; los especiales se re-ajustan después). El selector
  tiene buscador + resumen "Asignación actual" (desglose por cobrador, incl. inactivo).
- **Lista de clientes:** "Seleccionar todos del filtro" (no solo la página) → asignación masiva sobre el set
  filtrado. Lista de clientes y de cobros muestran cuántos hay cargados.
- El server propaga `cobrador_id` a cuotas vía trigger 0068 → requiere online. `SeleccionarCobradorDialog`
  extraído a archivo propio (reusado por lista + Rutas).
- Audit Fase 4 (3 dim + verificación): findings reales aplicados; falsos positivos descartados.

**P3b — clientes/contratos sin cobrador (commits `5819438`, `537f9f0`, `3af6c32`):**
- **Migración 0121** (DEV, verificada): DROP de los triggers `0058` (bloqueaba desasignar con contratos
  activos) y `0025 E1` (bloqueaba crear contrato sin cobrador). Sin bump de schema, no toca dinero ni sync rules.
- UI: quitados los 3 guards cliente-side (cliente form, contrato form, botón "Nuevo" del detalle del cliente);
  Rutas re-habilita "Desasignar"; **filtro "Sin cobrador"** en Cobros (Clientes ya lo tenía).
- **Regla:** un cliente sin cobrador → cuotas con `cobrador_id NULL` → el bucket `por_cobrador` NO las baja;
  SOLO admin/admin_cobranza las ven, filtran y cobran (bucket de tenant completo). La deuda NO se pierde
  (admin-managed) hasta reasignar. El cobro lo registra el admin → pago/recibo con SU id (quién cobró).
- Audit Fase 4: único fix real = **INV8** de `invariantes_dinero.sql` (exigía "contrato activo tiene cobrador"
  → ahora valida `contrato.cobrador_id = cliente.cobrador_id`, `IS DISTINCT FROM`). Arqueo/reporte-por-cobrador/
  recibo = falsos positivos (joinean sobre `pago.cobrador_id` = quién cobró, NOT NULL, fila en cobradores).

**Testing (Rubén, build v29 de `ui-improvements`):** P3 OK (Rutas, selector con buscador/desglose, seleccionar
todos, conteos) · P3b OK (desasignar con contrato, crear contrato sin cobrador, filtros "Sin cobrador" en
Clientes/Cobros, cobrar como admin, reasignar y reaparece para el cobrador). `analyze` limpio · suite **315
verdes** (P3 y P3b no tocan lógica de dinero). Sin build/release a usuarios.

**Pendiente:** P4 (tag de contratos siempre visible) · P5 (módulo de tags). Backlog menor: filtro "Sin cobrador"
en mapa/reportes; comentarios de doc en dashboard/registrarCobro.

---

## 2026-06-17 — UI improvements P1 (mapa satelital rural) + P2 (banner offline real)

**Qué se pidió/por qué:** Rubén abrió un lote de mejoras de UI/UX (6 puntos). Acordamos ir de a uno con
mockups + lifecycle. Cerrados y **testeados OK por Rubén** los dos primeros:

- **P1 — Mapa satelital en zona rural.** El `TileLayer` Esri no tenía `maxNativeZoom`, así que al pasar la
  cobertura de foto rural (~z17) mostraba el gris "Map data not yet available". Fix: `maxNativeZoom: 17`
  (satélite) / 19 (OSM) → upscale del último tile en vez del gris; `maxZoom` de cámara 19→**20** (un nivel
  extra de acercamiento, a pedido). En `mapa_screen` y `mapa_picker`. Commits `a611547`, `f51f9d4`.
- **P2 — Banner "Sin conexión" falso/ausente.** Dependía de `SyncStatus.connected` de PowerSync, que NO es
  conectividad real: bajaba por hipos (token/backoff) con señal buena (falsos positivos) y NO detectaba la
  caída silenciosa del wifi (la conexión TCP queda colgada sin error → no salía el rojo ni tras 30s).
  **Decisión Rubén:** opción B (sin dependencia nueva), rojo solo cuando realmente no hay conexión.
  Fix: nuevo `conexionRealProvider` (sondeo TCP a Supabase cada 7s vía `dart:io`; 2 fallos ≈15s = offline);
  el `OfflineBanner` ahora escucha ese provider, no PowerSync. Quitado el aviso ámbar "red inestable".
  Commits `8734aa9` (intento previo solo-debounce, superado), `f7f456c` (sondeo real).

**Testing manual (Rubén, build release v29 local de `ui-improvements`):** P1 OK (acerca más, borroso pero
útil; sin gris) · P2 OK (rojo aparece ~15s al cortar wifi, desaparece al volver, NO sale solo con señal buena).
`analyze` limpio en los 5 archivos tocados. Sin schema/migración/sync (puro cliente). **NO build/release a
usuarios.** Docs actualizadas (ARQUITECTURA mapa/banner/providers, TESTING §0.3).

**Pendiente del lote (4 puntos, no empezados):** P3 reasignación masiva de cobrador (falta presentar
alternativas) · P3b crear contratos / clientes SIN cobrador (cambio de modelo de datos) · P4 tag de cantidad
de contratos siempre visible en lista de clientes · P5 módulo de tags personalizables (color+icono).

---

## 2026-06-16 (d) — Re-revisión de los backlog BAJA + branch `ui-improvements`

**Qué se pidió/por qué:** Rubén frenó al ver (b)/(c)/(d) presentados como findings: contradecían el diseño y
habían pasado auditorías exhaustivas. Pidió revisar de PRIMERA MANO (sin confiar en subagentes; uno se
contradijo en su aritmética) si de verdad eran bugs o si se perdió contexto. Sus 3 reglas: (1) las cuotas
previas a un cambio de fecha/suspensión son históricas y NO cambian; (2) el modelo NO debe fusionar períodos
de servicio; (3) un indefinido SIEMPRE tiene colchón de 3 cuotas desde la primera cuota de pago.

**Hallazgo (lectura directa del código + callers):**
- **(c) RETIRADO — no es bug.** El escenario era irrealizable: R13 bloquea el cambio con 2+ vencidas o parcial
  en curso, la única vencida se cobra en la transacción, y el trigger `0018:110-116` re-fecha todas las
  pendientes `periodo >= mes_actual`. La lista de cobro nunca tiene una pendiente con venc desalineado → el
  modelo NO fusiona períodos (regla 2 de Rubén confirmada).
- **(b) cosmético/inalcanzable.** El recibo usa el `dia_pago` vivo (`recibo_screen.dart:75,104`), pero la cuota
  queda histórica intacta (regla 1 OK); solo la etiqueta del mes se recalcula al reimprimir un recibo previo a
  un cambio de día. No toca dinero. Candidato a "no se arregla".
- **(d) real pero solo con instalación FUTURA.** `0074:88-94` da `GREATEST(0, meses+1+3)`: instalación mes
  actual/pasada → ≥3 (colchón OK, regla 3 cumplida); futura → 2/1/0 según cuán adelante. Fix de 1 línea
  `GREATEST(3,…)` para blindarlo. Requiere migración.

**Hecho:** corregido el bloque de backlog en BITACORA (detalle arriba). Branch nuevo **`ui-improvements`**
creado desde `main` (4fbf3fe) como rama de trabajo para los próximos cambios de UI; reemplaza a
`test-contratos`. SIN cambios de código (solo doc). Disculpa registrada: los mockups anteriores sobredimensionaron
(b) y (c).

---

## 2026-06-16 (c) — Checkpoint: detalle de contrato + fixes reportería/recibo + docs + merge a `main`

**Qué se pidió/por qué:** Rubén pidió cerrar lo pendiente, rediseñar el detalle del contrato, dejar TODA la
documentación al día (en especial la dinámica de dinero/reportería y cómo funcionan contratos/cambio-de-fecha/
suspensión) y hacer checkpoint a `main` — SIN build/release todavía.

**Hecho (rama `test-contratos`):**
- **Rediseño del detalle de contrato:** "Total contrato" muestra el total REAL en grande (con hint "ajustado por
  suspensión" si bajó del nominal); doble panel cuotas|pagos en pantallas anchas (≥820px); chips "Primera/Última
  cuota" del min/max venc de cuotas vivas + "Día de pago"; fila "Instalación"; flechas ↑/↓ para ordenar; recibo y
  deuda de suspensión reimprimen con "Guardar como" (no térmica). Forzar "Abono previo" en el recibo.
- **3 fixes finales de reportería/recibo (`42edbbc`):** **B1** las 3 queries de mora (PDF/Excel/card por comunidad)
  excluyen suspendidos (`!= 'suspendido'`) — consistente con el dashboard (inv. #10); **C1** `dias_mora` del reporte
  resta `diasGracia` → coincide con el badge "Vencida Nd" de la UI; **B2** el bloque EN MORA de los recibos rotula
  con `mesServicioLabel(periodo, dia_pago)` (`fetchMoraContrato` ahora trae `dia_pago`), no `Fmt.mes`.
- **Docs:** nuevo **§3.5 de ARQUITECTURA** (modelo de dinero/facturación vencida/ancla día_pago/reportería = regla
  de oro) + R14 reescrita con el anclaje por ventana de servicio + sección Contratos con el rediseño + fila §0.

**Commits:** `42edbbc` (B1/C1/B2) + commits de UI previos + este de docs. `analyze` limpio · `pagos_repo` **40** ·
suite **315 verdes**. **Sin cambio de schema** (v29). **Merge `test-contratos`→`main`** (checkpoint). **NO** build/
release (decisión Rubén). Backlog que queda: BAJA(b)(c) de formatters + BAJA(d) indefinido instalación futura.

---

## 2026-06-16 (b) — Fix del bug de anclaje día_pago (la matemática del dinero, regla de oro)

**Qué se pidió/por qué:** Rubén, testeando S3, descubrió que la suspensión prorrateaba MAL (decía deuda 0 cuando el
período de servicio ya estaba cumplido). Pidió frenar todo y re-evaluar: "este error no tuvo que haber pasado…
este fundamento de la app y su matemática debería ser regla de oro total e irrompible". Auditoría integral (23
agentes, verificación adversarial): el núcleo CONTABLE (saldo canónico, recaudado, total fijo, cambio-de-fecha)
quedó SANO; el daño estaba acotado a la suspensión/reactivación, que anclaban por **mes calendario** en vez del
**ciclo de servicio del día_pago**. Para día_pago≠1 (el caso normal) prorrateaban un período ya cumplido y anulaban
el en curso → sub-cobro.

**Hecho (`66fbed2`):** helper único `ventanaServicio`/`estadoServicio`/`servicioFin` en `prorrateo.dart` (ventana
`(venc_anterior, venc_propio]` anclada al día_pago; clasifica cumplido/en_curso/futuro). `suspenderContrato` y
`_calcularDeudaSuspension` clasifican cada cuota por servicio (cumplido=entera, en_curso=`montoPuente` días
consumidos con clamp al pago, futuro=anular). `reactivarContrato`: **reinicio limpio desde `mesR+1`** (facturación
vencida: la cuota cuyo venc = mes de reactivación cubre el mes suspendido previo). Diálogo usa flags
`en_curso`/`dias_consumidos`/`dias_ciclo`. Tests `pagos_repo` reescritos con números de ventana de servicio.

**Audit:** 2 rondas adversariales limpias. **Validado en la app S1–S6** con números exactos (día_pago 15: junio
prorratea 1/30; día_pago 6: junio prorratea 10/30). `pagos_repo` **40 verdes** · suite **315**. **Decisión de
Rubén:** reactivación = "reinicio limpio desde la fecha". **Por qué se escapó:** los audits previos verificaron
consistencia de fórmulas/SQL pero NO el supuesto del ancla del período → regla nueva: auditar SIEMPRE el anclaje,
no solo la aritmética. Detalle del modelo: **§3.5 de ARQUITECTURA**.

---

## 2026-06-16 — Rediseño del ciclo de vida de la suspensión

**Qué se pidió/por qué:** los contratos suspendidos NO deben aparecer en cobros ni mapa; deben tener filtro propio
en Clientes; para reactivar hay que cobrar primero lo pendiente **cuota por cuota** (un recibo c/u, no factura
única); y la reportería debe **clasificar** la deuda suspendida aparte (sigue contando en contabilidad). Antes:
Rubén pidió un desglose por cuota en el diálogo de suspender.

**Hecho (rama `test-contratos`, 6 items):**
- Desglose por cuota en el diálogo Suspender (+ info de parcial si la feature está ON) y en el PDF de deuda.
- (1) suspendidos fuera de la lista de cobros (`cuotas_list_screen`) y del mapa (`mapa_screen`).
- (2) filtro **"Suspendidos"** en Clientes (admin/admin_cobranza; lista principal + export).
- (3) Reactivar gateado a `cobrable < 0.01`; si hay pendiente → botón **"Cobrar pendiente"** (cuota más vieja,
  oldest-first, un recibo c/u) + aviso. (El gate a nivel repo/server → backlog: rompía los tests de reactivar.)
- (5) prompt para **imprimir** la deuda al confirmar la suspensión (helper compartido `imprimirDeudaSuspension`).
- (6) dashboard: titular "por cobrar"/"vencido" **excluye** suspendidos + KPI nuevo "Suspendido (por reactivar)";
  reporte clientes (PDF+Excel): subtotales Activo/Suspendido/Total + sufijo "(susp.)" por fila.

**Audit Fase 4** (3 agentes: SQL/DB · código/Flutter · QA/invariantes): limpio salvo 1 BAJA cosmética (doble
umbral 0.01/0.009 → unificado a 0.01). Las 3 fórmulas de saldo suspendido (gate/KPI/reporte) son idénticas (inv. #10 OK).

**Commits:** `654e5fe` (items 1+2+3) · `e922736` (items 5+6 + fix BAJA). **Sin cambio de schema** (v29 sigue;
no se redeploya nada). `analyze` limpio · `pagos_repo` 40 · suite **315 verdes**.

**PENDIENTE:** testing manual del ciclo completo en build v29 (suspender → sale de cobros/mapa → filtro
Suspendidos → cobrar pendiente → reactivar → imprimir). Backlog: regla 0/1/2+ mora antes de suspender + guards
server-side (oldest-first + reactivar-exige-pagado).

---

## 2026-06-15 (b) — Audit adversarial de la suspensión + reportería → 6 fixes de dinero

**Qué se pidió/por qué:** antes de mergear Feature A, Rubén pidió máxima precisión matemática y que TODA la
reportería refleje los escenarios de dinero (suspensión, parciales, cambio de fecha). Se lanzaron 2 auditorías
adversariales multi-agente (cada hallazgo lo refuta un 2º agente con números) sobre la matemática de la
suspensión y sobre la reportería. La lógica de dinero ya pasaba 315 tests, pero NO cubría cuotas `parcial`.

**Fixes (rama efímera `fix-suspension-parcial`, 3 commits → mergeada a `test-contratos`):**
- **Suspensión vs cuotas `parcial`** (antes solo tocaba `pendiente` → sobrecobro/inconsistencia): mes en curso
  parcial → prorratea con CLAMP al pago (`monto=max(prorrateo,abonado)`; si el abono cubre → `'pagada'` sin
  reembolso); futura parcial sobrevive (tiene pago) y entra al snapshot/PDF. Mutación == `_calcularDeudaSuspension`.
- **INV11** (`invariantes_dinero.sql`): reintegra al conteo las anuladas con `motivo='Suspensión temporal'`
  (activas + gap = `duracion_meses`) → fin del falso positivo en fijos suspendidos-reactivados.
- **Reportería (display — los TOTALES de dinero ya eran correctos):** header "Pendiente" = deuda **cobrable**
  (= fórmula de los reportes, no nominal); `total_cuotas` de "X/N pagadas" excluye anuladas (`cliente_detail` +
  `contratos_admin`); distribución del dashboard = eje vigencia disjunto + "Con pago parcial" como overlay
  (visible solo si la feature está ON o ya hay parciales).

**Decisiones de Rubén:** contemplar el pago (no bloquear) · Pendiente = cobrable real · distribución 2 ejes con
overlay. **Matiz invariante #5** (AGENTS): fijos con suspensión → pendiente = Σ saldos cobrables (no nominal).

**Commits:** `cbe3ffb` (parciales) · `162edf0` (INV11) · `e26e059` (reportería). **Sin cambio de schema** (v29
sigue; no se redeploya nada). `pagos_repo` **40 verdes** · suite **315** · `analyze` sin issues nuevos.

**PENDIENTE:** testing manual en build v29 (ahora con los bordes `parcial` cubiertos).

---

## 2026-06-15 — Fix recibo + rediseño cobros + Feature A (suspensión temporal)

**Qué se pidió/por qué:** tras testear Feature C en build de release, Rubén pidió: (a) arreglar el recibo del
cambio-de-fecha (mostraba TODOS los puentes acumulados en la cuota, no el del pago de ese recibo); (b) rediseñar
la lista de cobros agrupada por cliente; (c) que para cambios de UI le muestre un **mockup visual** antes de
implementar; (d) construir la **suspensión temporal de contrato (Feature A)**.

**Hecho (rama `test-contratos`):**
- **Recibo cambio-fecha:** el desglose trae los cargos `origen='puente'` por `pago_id` del recibo (no por
  `cuota_id`) → cada recibo muestra solo SU puente. `recibo_screen.dart` + `recibo_cargos.dart` + test. (Bug:
  era de presentación; la plata estaba bien — confirmado por queries en DEV.)
- **Rediseño lista de cobros:** una tarjeta por cliente (código · nombre · comunidad·municipio) + un renglón por
  contrato con Pagar/Cambiar fecha. `cuotas_list_screen.dart`. Audit Fase 4 limpio.
- **AGENTS.md:** regla "cambios de UI/UX → mockup visual al proponer". **ARQUITECTURA:** Receta R13.
- **Feature A — suspensión temporal (A1–A6):** estado `'suspendido'` + tabla `contrato_suspensiones`
  (migración **0120**, patrón R10); `ContratosRepo.suspenderContrato`/`reactivarContrato` (offline, prorrateo =
  el del puente, NUNCA toca cuotas con pago; reactivar re-ancla el día SIN estirar `fecha_fin`, revive el gap
  anulado); `previewDeudaSuspension` DRY (preview = snapshot); PDF de deuda reimprimible del snapshot; UI (badge
  ámbar + diálogos Suspender/Reactivar + tarjeta) gateada a admin/admin_cobranza. **Audit Fase 4** (3 dim +
  verif. adversarial, 7 agentes): 5 findings aplicados — guard fecha de reactivación (mes posterior al de
  suspensión), gating de Reactivar por rol + impersonación, historial del contrato (agregador `HistorialContrato
  Widget`), `contrato_suspensiones` en bucket `impersonated_tenant`, ocultar botones al impersonar.

**Commits clave:** recibo `f11c0a4` · mockup-rule `741b57c` · cobros `868f338` · R13 `fe7f39b` · A1 `e6cdef8` ·
A2 `6accb09` · A3 `5ca4244` · A5(1) `473eb47` · A5(2)+A4 + audit `da5a843`. `flutter analyze` limpio · `pagos_repo` 37 verdes.

**Deploy:** DEV → 0119 + 0120 + sync rules **v10 Active**. **NO se buildeo ni releaseó** (decisión Rubén:
seguir en branch, vienen más cambios de UI). Schema local saltó a **v29**.

**PENDIENTE:** testing manual en build v29 (suspensión + re-confirmar recibo/cobros) → luego merge a main +
deploy a PROD (0119+0120+sync) + build/release, todo junto.

---

## 2026-06-15 — Feature C: REDISEÑO del modelo (regla de mora + 1 recibo)

**Por qué:** al testear, el dueño rechazó el modelo de la entrada de abajo: el puente NO debía ser un recibo
aparte, y debía permitirse 1 mes de mora. **Decisiones (Rubén):** (a) regla ESTRICTA por cuotas VENCIDAS
(venc<hoy): 0 = al día (cobra solo el puente, sobre la última pagada), 1 = cobra esa cuota vencida + puente
en UN recibo, 2+ = bloquea (sería multi-cuota + puente); (b) el puente sigue siendo cargos_extra origen='puente'
sobre la cuota que se cobra; (c) habilitar usuarios desde Settings con multi-select (estilo reportes); (d)
botones Pagar + Cambiar fecha también en el detalle de contrato.

**Hecho (rama `test-contratos`):** `registrarCambioFecha` reescrito (el pago aplica saldo de la cuota + puente;
pagado-hasta = día nominal del período del host). Diálogo con desglose "Cuota vencida + Puente = Total".
Multi-select en Settings→Cobranza. Botones en contrato detail. Recibo del caso al-día "solo el puente" (omite
"Cuota base"/período de la cuota ya saldada; la línea "Puente de pago" se muestra SIEMPRE, no atada al toggle
de descuentos — es lo cobrado). 0119 corregida (settings.valor es text, no jsonb) + idempotente.

**Audit (3ª ronda, 11 agentes):** dinero verificado LIMPIO (invariantes #1–#11, al-día y 1-mora). 6 hallazgos
bajos (todos del recibo al-día) → resueltos. 2 refutados (timezone ya parchado por 0087; TOCTOU de cargo cubierto).

**Commits:** `1096d8f` (0119 text/jsonb) · `4f0688e` (tx) · `77f8e56` (diálogo) · `54a5057` (botones contrato)
· `73fff12` (settings multi) · `0c25ce8` (recibo al-día). **305 tests verdes.** 0119 + sync rules v8 en DEV.

**PENDIENTE:** terminar testing manual en dev → merge a main → deploy 0119 + sync rules en PROD + build/release
(schema v28), una sola vez. **Feature A (suspensión) NO empezada.**

---

## 2026-06-14 (cont.) — Feature C COMPLETA (código) + 2 rondas de audit (modelo VIEJO, reemplazado por el rediseño de arriba)

**Continuación del diseño cerrado de la entrada de abajo: se completaron los 5 items.**
- **Transacción** `PagosRepo.registrarCambioFecha` (Diseño A — puente = `cargos_extra` origen='puente'
  tipo='otro' sobre la ÚLTIMA cuota pagada): cobra el puente + recibo, absorbe (anula) las cuotas que caen
  en la ventana, re-fecha futuras (port Dart `calcularFechaPago`, espejo de 0014), en fijos agrega cuota de
  cierre por absorbida. Guards: al-día, sin parciales, día-nuevo ≠ actual. `pagadoHasta` = día NOMINAL.
- **0119 ampliada:** CHECK `origen` admite 'puente'; **relaja `cuotas_check_cobrador_update`** + agrega
  **`contratos_check_cobrador_update`** (BEFORE UPDATE) acotando al cobrador habilitado a SOLO sus cuotas y
  solo `dia_pago`/`fecha_fin` (forward) en contratos. **INV11** (invariantes_dinero.sql) cuenta solo activas.
- **UI:** `cambio_fecha_dialog.dart` (mini-cobro con preview, reusa CobroCalculo) + botón "Cambiar fecha" en
  `cuotas_list_screen` y pin del mapa + línea "Puente de pago" en el recibo (`recibo_cargos.dart`). Gateado
  por `puedeCambiarFechaPagoProvider` + guard de impersonación. `precio_mensual` agregado a ambas queries.
- **Audits Fase 4 (2 rondas, 18 agentes):** tx → 6 hallazgos, 5 fixes (incl. 2 de SEGURIDAD: el guard
  relajado sin scope de dueño dejaba anular deuda ajena por API, y `contratos` sin guard dejaba borrar
  cuotas vía `fecha_fin`→limpiar_excedentes). UI → 1 fix (re-chequeo de `dia_pago` antes de cobrar).
  Diferido (cosmético, item futuro): `pendiente` subreportado cerca del fin en fijos (trade-off de #9).
- **Commits:** `c923318` (tx) · `896e959` (fixes tx) · `fe032d7` (UI) · `a64d1bf` (fix UI). **304 tests** verdes.

**PENDIENTE:** testing manual de Rubén → deploy 0119 + sync rules "Active" → build schema v28 → merge a main,
todo junto una sola vez. **Feature A (suspensión temporal) NO empezada** (sigue en la entrada de abajo).

---

## 2026-06-14 (cont.) — Contratos: Feature C (cambio de fecha de pago por días) EN PROGRESO

**Contexto:** Rubén pidió 3 features de flexibilidad de contrato. Tras consolidar: quedaron **2**
(la "restructura B" se fundió en C). Esta sesión arrancó **Feature C**; **Feature A (suspensión)**
NO empezó. Trabajo en rama `claude/awesome-joliot-a2bd43` (4 commits sobre main, NO mergeados).

**Feature C — cambio de fecha de pago por días. DISEÑO CERRADO (decisiones de Rubén):**
- El cliente AL DÍA mueve su día de pago. Paga los **días puente** entre lo pagado y el día nuevo,
  prorrateados a **precio_mensual ÷ días reales del mes** (cada día con los días de su propio mes).
- **Regla del ancla:** primera ocurrencia del día nuevo DESPUÉS de "pagado hasta". La cuota que cae en
  la ventana del puente se **absorbe (anula)**; la 1ª cuota completa cae en el día nuevo. Ejemplos
  validados: 15→30 = puente 15d (C$450 con plan 900) · 15→10 = puente 25d, 1er pago 10-ago · 15→14 =
  puente 29d, 1er pago 14-ago. Helper `lib/data/utils/prorrateo.dart` (18 tests).
- **Puente = `cargos_extra` (origen 'puente', "Puente de pago")** sobre la cuota que el cliente paga en
  ese momento ("se aprovecha"); aparece en EL RECIBO de ese cobro. NO es una cuota suelta (chocaría con
  el unique (contrato_id, periodo)). Entra a recaudado; NO infla el total fijo (es extra, como reconexión).
- **Re-anclaje:** anular la cuota absorbida + el trigger `0018` mueve el día de las futuras pendientes
  (espejar local offline) + en contratos FIJOS agregar 1 cuota de cierre al final (conserva el conteo →
  el contrato termina unos días después, los del puente). Indefinidos: solo se re-ancla el cushion.
- **Gating 2 niveles:** super_admin activa la feature por tenant (setting super-only
  `cobranza.cambio_fecha_habilitado`); el admin habilita por usuario (`cobradores.puede_cambiar_fecha`)
  a cobradores/admin_cobranza (el rol admin siempre). Botón "Cambiar fecha" al lado de "Pagar" en la
  vista Por Cobrar Y en el mapa. Sin flujo de aprobación extra. RLS server `puede_cambiar_fecha_pago()`.
- **Offline-first:** el cobrador escribe local (writeTransaction + espejo de triggers) y sincroniza; por
  eso la `0119` EXTIENDE la RLS de contratos/cuotas para el personal habilitado, solo sobre SUS contratos.

**Hecho y commiteado (rama, 4 commits):**
- `42b8baf` `prorrateo.dart` + tests. · `6e72143` migración **0119** (permiso col, setting super-only,
  helper `puede_cambiar_fecha_pago()`, RLS contratos/cuotas) + schema.dart (cobradores.puede_cambiar_fecha,
  v27→**v28**) + sync rules (columna agregada a los SELECT de cobradores). · `9c1c0d8` modelo
  `Cobrador.puedeCambiarFecha` + `puedeCambiarFechaPagoProvider` + getter `cambioFechaHabilitado`. ·
  `0bcfe1f` gating UI (grupo en tab Avanzado + `_superAdminOnly` + toggle por usuario en _EditarCobradorDialog).

**PENDIENTE Feature C (orden sugerido):**
1. Transacción offline (repo): calcular "pagado hasta" (max venc de cuotas 'pagada') + guard al-día,
   cargo puente sobre la cuota cobrada, cobro+recibo, anular absorbida, mover futuras (espejo), fijos:
   cuota de cierre, UPDATE dia_pago (+ fecha_fin fijos). Tests + invariantes_dinero.
2. Diálogo "Cambiar fecha" con preview (usar `calcularPuenteCambioFecha`).
3. Botón en `cuotas_list_screen.dart` (al lado de Pagar) y en el pin del mapa.
4. Recibo: línea "Puente de pago" (mapear origen='puente'); verificar CHECK de cargos_extra.origen
   (¿hay que extenderlo? revisar 0007/0115) y el tipo (usar 'otro' que SUMA).
5. Reportería/dashboard: el puente entra a recaudado; verificar invariante #10 (totales idénticos).
6. Audit Fase 4 (Code+QA dinero+Security por la RLS) + testing manual.

**PENDIENTE Feature A — suspensión temporal (NO empezada):** estado contrato 'suspendido' + motivo
(tabla `contrato_suspensiones`, Receta R10), pausa de generación (cron ya saltea no-activo), anti-backfill
al reactivar, prorrateo de días consumidos, **PDF de deuda pendiente**. Decisiones cerradas: no se cobra el
período suspendido, contrato termina igual; solo admin/admin_cobranza suspenden; indefinidos solo pausan,
fijos anulan cuotas del período.

**DEPLOY de Feature C (cuando esté completa, JUNTO con el build):** correr `0119` en Dashboard (verificar)
→ redeploy sync rules a "Active" → build con el schema v28. NO deployar suelto (el bump de schema fuerza
DB local fresca; hacerlo una sola vez).

---

## 2026-06-14 — Sprint A+B: mapa picker, bug red, logo, vista Por Cobrar, reporte por cobrador

**Qué se pidió (6 features):** 1) mapa de geolocalización del cliente consistente
con el mapa principal; 2) bug: al asignar nodo a cliente no aparecían Hub/Puerto;
3) vista de cobros sin tab "Por cliente", "Por cobrar" única con buscador + 1 cuota
(la más antigua) + botón Pagar + tap→detalle; 4) reporte por cobrador que incluya
admins + multi-select; 5) export Excel de ese reporte; 6) logo de la app en el login.

**Decisiones de Rubén (AskUserQuestion):** #2 es bug real (creó hub+puerto y no salían) ·
#3 una fila POR CONTRATO (no por cliente) y **el admin también paga** desde la lista ·
#6 usar el ícono actual `app_icon.png`, **sin** el texto "CRM" · defaults #4/#5
confirmados (incluir cobrador+admin+admin_cobranza + inactivos con pagos; "Todos" default;
PDF agrupado con subtotal + total general).

**Qué se hizo** (rama `claude/awesome-joliot-a2bd43`, 9 commits `bb700a7`→`7883318`):
- **#1** `mapa_picker_screen.dart` enriquecido (brújula, pin GPS, toggle satélite, atribución);
  `UbicacionActualMarker`/`MapAttributionBanner` extraídos a `shared/widgets/mapa_widgets_compartidos.dart`
  (DRY con `mapa_screen`). Beneficia también al picker de nodos de red.
- **#2** `red_picker.dart`: `emptyHint` en Hub/Puerto (autoexplica el vacío y sirve de diagnóstico) +
  `key` por nivel de cascada (anti estado viejo de `initialValue`). **Causa raíz no reproducible
  estáticamente** — toda la cadena (schema/sync/RLS/INSERT/cascada) está correcta; el `emptyHint`
  dirá en el dispositivo si la query devuelve 0 filas (dato) o si es otro mecanismo.
- **#6** logo `app_icon.png` en recuadro negro redondeado en login + set-password (sin el texto, decisión de Rubén).
- **#3** `cuotas_list_screen.dart` REESCRITO: vista única, 1 fila por contrato (cuota más antigua,
  desempate por periodo = paridad con el mapa), buscador client-side, botón Pagar (admin+cobrador)
  → `/cobro/:id`, tap→detalle; indicador "N cuotas · debe C$total" por contrato; sin tabs ni multi-select.
- **#4+#5** `reportes_admin_screen.dart` + `pdf/reporte_por_cobrador_pdf.dart`: selector multi-cobrador
  (incluye admins + inactivos con pagos vía EXISTS), PDF agrupado por `cobrador_id` con subtotal/total,
  export Excel desde la misma query `_rowsPorCobrador` (totales idénticos PDF↔Excel).
- **Audit Fase 4 (6 agentes, 2 tandas):** Sprint A → 1 MEDIO (logo se estiraba a barra negra por
  `stretch`) + BAJOs, todos fixeados (`5df418f`). Sprint B → 1 MEDIO (se perdía el contexto de deuda
  por cliente) + BAJOs, fixeados (`7883318`: indicador de deuda, desempate por periodo, clamp del saldo
  del mapa, PDF por id anti-homónimos, botón Pagar más tocable, fin de mutación de estado en build).

**Testing manual de Rubén (2026-06-14, debug Windows) + fixes** (commits `062665c`→`00f8425`):
corrido desde una **worktree de ruta corta** (`C:\Users\ruben\sc`) porque el build Windows desde
la worktree bajo OneDrive excedía MAX_PATH (MSB3491 en los `.tlog`). Fixes que salieron del testing:
- **Bug guardado de cliente (causa raíz real):** `ref` NO es usable en `dispose()` (Riverpod 2.6.1
  lanza "Cannot use ref after the widget was disposed") → se captura el `StateController` de
  `formDirtyProvider` en `initState` (`_formDirtyCtrl`) y se usa en dispose. Mismo fix en
  `contrato_form_screen`. Además en `_guardar` se capturan `ScaffoldMessenger`/`GoRouter` ANTES del
  await (el árbol se reconstruye por PowerSync y desactiva el context → "ancestor unsafe").
- **Vista cobros (pedido de Rubén):** fila con **código arriba** → nombre+municipio → mes → fecha
  (se agregó join a `municipios`); **se quitó** la línea "N cuotas · debe total" (Rubén la pidió out).
- **Cédula** alfanumérica libre (se quitó el validator de formato 000-000000-0000A).
- **Legibilidad:** `scheme.secondary` (= primary al 10%, color de relleno) se usaba como color de
  TEXTO/ÍCONO → ilegible. Arreglado en: notas de visita (Promesa de pago), dashboard (Pago parcial),
  estado de ticket "Asignado", avatares de rol `admin_cobranza`, íconos del log de auditoría.
- **Robustez:** el sheet de equipos en baja no bloquea el cierre del form de cliente (try/catch).

**Backlog/aceptado:** `pi` sin import explícito (vía latlong2, pre-existente) · chips "Próximas/Vencen
hoy" muestran la cuota futura aunque haya mora (semántica de filtro, aceptada) · **fix completo del
context estable para `ofrecerGestionEquiposEnBaja`** en el path de baja (cliente y contrato_detail) —
hoy mitigado con try/catch; pendiente capturar un Navigator estable (chip `task_5c833dc7`).

---

## 2026-06-13 (a) — Diagnóstico y Backfill de Setting Faltante (Días Cuotas Próximas)

**Qué se pidió:** Resolver por qué la opción "Días de cuotas próximas" no aparecía en algunos tenants y aclarar si se debe hacer un proceso manual para cada nuevo tenant.

**Qué se hizo:**
- **Base de Datos**: Se diagnosticó que el setting `cobranza.dias_cuotas_visibles` estaba ausente en la tabla `settings` para el tenant "System Admin" (por haber sido creado antes de la migración `0113`).
- **Solución**: Se ejecutó una consulta SQL de backfill para poblar la clave faltante con valor por defecto `5` en los tenants existentes.
- **Clarificación**: Se verificó en `0113` y `0115` que el trigger `tenants_seed_settings_trg` de Supabase se ejecuta `AFTER INSERT ON public.tenants` y automáticamente inicializa este y otros valores por defecto, eliminando la necesidad de realizar este paso de forma manual en futuros tenants.

---

## 2026-06-12 (l) — Onboarding con Contraseña por Defecto + Ocultación de Toggles de Email + Release v0.11.9

**Qué se pidió:** Cambiar el flujo para que por defecto siempre se generen contraseñas en lugar de invitaciones por correo electrónico al crear usuarios, y ocultar visualmente el interruptor de invitaciones por email en todas las pantallas donde se invite a nuevos usuarios (cobradores, tenants, administradores y reenvíos).

**Qué se hizo:**
- **UI/UX**: Modificados 4 diálogos (`_InvitarDialog` en `cobradores_admin_screen.dart`, `_CrearTenantDialog` en `tenants_list_screen.dart`, `InvitarAdminDialog` en `tenant_dialogs_invitar.dart`, y `ReenviarInvitacionDialog` en `tenant_dialogs_miembro.dart`) para cambiar el valor inicial a `_enviarEmail = false` y comentar los widgets `SwitchListTile` correspondientes.
- **Validación**: Análisis estático `flutter analyze` libre de advertencias `dead_code`, y suite completa de tests de la app (`flutter test` con 275 aprobados).
- **Release**: Incrementada la versión a `0.11.9+119`, ejecutado script de build, y publicado release en GitHub, barriendo el tag/release obsoleto `v0.11.8`.

---

## 2026-06-12 (k) — Fix de pantalla negra en Ruta + Reglas Audit 7-9 + Release v0.11.8

**Qué se pidió:** Corregir el bug donde la pantalla quedaba negra y bloqueada al presionar el botón "Ruta" tanto en Android como en Windows.

**Qué se hizo:**
- **UI/UX**: Modificado `mapa_screen.dart` para eliminar el uso de `showDialog` como indicador de carga para el cálculo de rutas (anti-patrón de Flutter). Implementado un indicador de carga reactivo basado en un flag de estado interno (`_isCalculatingRoute`) y un overlay condicional en el `Stack` principal.
- **Robustez**: Se envolvió el flujo asíncrono de cálculo en un bloque `try/catch/finally` para asegurar que `_isCalculatingRoute = false` se ejecute siempre, previniendo pantallas bloqueadas en caso de excepciones.
- **AGENTS.md**: Agregadas las Reglas de Audit 7, 8 y 9 para prohibir `showDialog` para loadings, alertar sobre desajustes de contexto con GoRouter al usar `Navigator.pop()`, y obligar a verificar los caminos de error asíncronos.
- **Release**: Incrementada versión a `0.11.8+118`, ejecutado script de build, y publicado release en GitHub con APK y MSIX, limpiando releases viejos hasta `v0.11.7`.


---

## 2026-06-12 (j) — Rotación de Mapa y Motor de Ruteo 100% Offline (SQLite + A*)

**Qué se pidió:** 1) Rotar la orientación del mapa con dos dedos y reorientar al norte con brújula; 2) Ruteo y trazado de caminos reales de Nicaragua de forma interna, 100% local y offline, sin abrir Google Maps externo (salvo como fallback).

**Qué se hizo:**
- **Mapa**: Habilitada la rotación en `MapOptions`. Creado el botón flotante de Brújula que se orienta de manera inversa a la cámara y resetea a 0 grados.
- **Ruteo Offline**: Compilada una base de datos local SQLite (`rutas_nicaragua.db`, 11.08MB) filtrando la red vial principal de Nicaragua desde OpenStreetMap (Overpass API) y formateando coordenadas a 5 decimales.
- **Dart**: Creado `OfflineRoutingService` ejecutando el algoritmo A* en memoria con cola de prioridad y decodificación geométrica de tramos. Dibujo de la ruta mediante `PolylineLayer` y panel inferior de control.
- **Verificación**: `flutter analyze` exitoso (0 errores). Bump a `v0.11.7+117`.

---

## 2026-06-12 (i) — Simplificación del banner de actualización + Release v0.11.6

**Qué se pidió:** Quitar el detalle de las notas de versión (release notes) en el banner superior de actualización para evitar problemas de codificación (tildes raras) y tener una interfaz más limpia, mostrando únicamente el aviso de actualización y el botón.

**Qué se hizo:**
- **UI**: Modificado `update_banner.dart` para remover el renderizado de `update.releaseNotes` en la columna del banner.
- **Verificación**: `flutter analyze` exitoso (0 errores, 4 deprecaciones conocidas) y `flutter test` (275 exitosos). Bump a `v0.11.6+116`.

---

## 2026-06-12 (h) — Fix de filtros congelados + Release v0.11.5 (Filtros de Cobrador/Zona/Nodo)

**Qué se pidió:** Corregir bug donde al seleccionar "Todas" o "Todos" en los filtros desplegables de cobrador, zona o nodo en el mapa y lista de cuotas, el filtro se quedaba congelado en el valor anterior.

**Qué se hizo:**
- **Shared widgets**: Modificado `dropdown_filtro.dart` para cambiar el tipo genérico del `PopupMenuButton` de `String?` a `String`, utilizando `'__TODOS__'` como valor interno para la opción general. Esto previene que Flutter interprete la selección de `null` como una cancelación del menú y descarte el trigger de selección.
- **Verificación**: `flutter analyze` exitoso (0 errores, 4 deprecaciones conocidas) y `flutter test` (275 exitosos). Bump a `v0.11.5+115`.

---

## 2026-06-12 (g) — Opción A & Opción B / Sprint 4 (baja terminal, motivo obligatorio, saldo >= 0, auto-eventos)

**Qué se pidió:** Implementar la Opción A (seriales: baja es estado terminal, bloquear transferencias de instalado sin volver a stock; contratos: motivo de cancelación obligatorio) y Opción B / Sprint 4 (saldo clampeado a >= 0 para evitar saldos negativos por sobre-pagos; auto-eventos de ticket en el servidor).

**Qué se hizo:**
- **Base de Datos**: Creada migración `0118_serial_baja_transferencias_tardias.sql` que actualiza el trigger guard de transiciones de seriales y crea el trigger `trg_tickets_eventos_auto` para centralizar la inserción de eventos de ticket en el servidor.
- **Contratos**: Añadido diálogo stateful obligatorio `_CancelarContratoDialog` en `contrato_detail_screen.dart` para capturar el motivo de cancelación, y propagación del mismo a cuotas y cargos de liquidación. Clampero de saldos en cuotas parciales.
- **Clampero de Saldos**: Modificados `clientes_list_screen.dart`, `clientes_admin_screen.dart` (lista y Excel), `dashboard_providers.dart` (KPIs), y `reportes_admin_screen.dart` (las 6 consultas PDF/Excel) para clampear el saldo de cada cuota a `>= 0` vía `max(..., 0)`.
- **Tickets**: Eliminadas inserciones manuales de eventos de ticket (`creado`, `asignado`, `cambio_estado`, `reasignado`) en `ticket_form_screen.dart` y `ticket_detail_screen.dart` (los comentarios, materiales y adjuntos siguen haciéndose desde el cliente).
- **Verificación**: `flutter analyze` exitoso (0 errores, 4 deprecaciones pre-existentes) y `flutter test` (275 exitosos).

---

## 2026-06-12 (f) — Release v0.11.3 (compresión de media + branding de reportes)

**Qué se pidió:** dejar la carpeta local al día, correr analyze/tests y
publicar la build v0.11.3 con el sprint de compresión + branding (Rubén
decidió testear directo con la versión instalada, sin pasada previa en rama).

**Qué se hizo:**
- Merge fast-forward de `compress-media-and-report-ui` a `main` (6 commits,
  `2ead790`→`be6453d`) y rama efímera BORRADA (local + GitHub).
- Bump `pubspec.yaml` a `0.11.3+113`. Sin migraciones SQL ni cambios de
  schema/sync rules (sprint 100% client-side).
- Verificación sobre `main`: `flutter analyze` (solo las 4 deprecaciones
  conocidas) y `flutter test` (275 pasan).
- `build-release.ps1` con notas de versión → instaladores versionados en
  `Releases\v0.11.3\` + Escritorio, release `v0.11.3` en GitHub con assets
  fijos y `version.json` actualizado.

**Pendiente:** testing manual de Rubén con la v0.11.3 instalada (los 9 pasos
de la entrada (e) + §0.3 de TESTING.md).

---

## 2026-06-12 (e) — Compresión de media + branding de reportes (rama compress-media-and-report-ui, MERGEADA en (f))

**Qué se pidió:** 1) comprimir fotos/documentos al subir a Storage sin
degradar calidad visible (el storage se llenaba rápido); 2) reportes PDF y
Excel con header estilo la referencia de Telecable Mairena (logo del tenant,
el mismo del recibo).

**Qué se hizo** (6 commits `2ead790`→`e9aa01f`):
- `imagen_compresion.dart` NUEVO: pipeline en isolate (resize 1920px/JPEG 85,
  EXIF horneado, alpha→blanco, escalera de calidad hasta cumplir el bucket,
  passthrough anti doble-compresión). Razón: en WINDOWS `image_picker` ignora
  `imageQuality/maxWidth` → el admin subía fotos crudas. Aplicado en los 6
  puntos de subida (fotos cliente/ticket/comprobante/logo/documento-foto).
  PDF/Word NO se recomprimen: peso visible + confirmación si >5 MB.
- Logo del tenant en los 9 PDF (`buildHeaderEstandar(logo:)`, bytes offline
  de `logoEmpresaBytesProvider`); Excel con header tipográfico (la lib
  `excel` no embebe imágenes — decisión de Rubén: NO migrar a syncfusion).
- Audit Fase 4 (Code+QA+UX): 0 ALTO, 6 MEDIO + 6 BAJO, TODOS fixeados
  (`e9aa01f`): spinners durante compresión, logo fresco tras reemplazo
  (invalidación + cache disco), PNG real en logo, guard 10 MB post-compresión
  para fotos, timeout 8s del download. Decisión aceptada: período PDF
  mora/clientes queda "Junio 2026" (Excel dice "Al dd/mm"). Tests 275 ✓.

**Pendiente:** testing manual (pasos abajo) → merge a `main` + borrar rama.
Backlog nuevo: "1024 KB" en el borde de `Fmt.pesoArchivo` · string "3 meses"
duplicado en inactivos · mapear 413 de Storage a mensaje humano.

---

## 2026-06-12 (d) — Release v0.11.2 (Ubicación GPS y Exportación de Clientes)

**Qué se pidió:** Merge de la rama `mapa-lista-clientes` a `main`, bump de versión a `0.11.2` y publicación de la build para probar el banner de actualización en dispositivos de campo.

**Qué se hizo:**
- Fusionada la rama `mapa-lista-clientes` a `main` sin conflictos. Pushed a GitHub y eliminada la rama efímera.
- Incrementada la versión en `pubspec.yaml` a `0.11.2+112`.
- Ejecutado el script `build-release.ps1` con notas de versión. Generados instaladores versionados para Windows (`.msix`) y Android (`.apk`), copiados automáticamente al Escritorio.
- Actualizado `version.json` y cargado el nuevo release en el repositorio de GitHub con el tag `v0.11.2`.

## 2026-06-12 (c) — Ubicación GPS y Exportación de Clientes (Rama mapa-lista-clientes)

**Qué se pidió:** 1) Mostrar la ubicación actual con un pin estilo Google Maps en el mapa que funcione online/offline con un botón de centrado rápido. 2) Añadir un botón de exportar clientes a Excel directamente en la vista de clientes (admin/admin_cobranza) con soporte para exportar todos o con la vista filtrada actual.

**Qué se hizo:**
- Agregada dependencia `geolocator: ^13.0.2` en `pubspec.yaml` + permisos en `AndroidManifest.xml` (Android) y capabilities de `location` en `pubspec.yaml` (Windows MSIX).
- Modificado `lib/features/mapa/mapa_screen.dart` para integrar Geolocator en tiempo real, agregando el marcador animado pulsante `_UbicacionActualMarker` y el botón flotante de centrado rápido (`my_location`).
- Modificado `lib/features/admin/clientes/clientes_admin_screen.dart` para agregar un `PopupMenuButton` de exportación. Soporta exportar todos los clientes o la vista actual, clonando dinámicamente las condiciones del filtro en la consulta SQL.
- Verificación: `flutter analyze` exitoso (0 errores, 4 deprecaciones conocidas) y `flutter test` (263 exitosos).

---

## 2026-06-12 (b) — Vista previa dinámica del recibo (Rama test-receipt)

**Qué se pidió:** hacer que los cargos/descuentos de ejemplo de la vista previa del recibo en Configuración -> Recibos sean dinámicos según el estado de la configuración (ajustes y reconexión), para que no se muestren si están desactivados y la matemática cierre siempre. Cambios en la rama `test-receipt`.

**Qué se hizo:**
- Creada rama `test-receipt` y hecho checkout (`fe1dfa2`).
- Modificado `lib/features/admin/settings/recibo_preview.dart` para recibir `AppSettings` en `_sampleCargos` and `_sampleRow`. Los cargos de ejemplo y la matemática (cargos_neto, monto_cordobas) ahora se recalculan dinámicamente.
- Verificación: `flutter analyze` exitoso (0 errores/warnings, 4 deprecaciones conocidas) y `flutter test` (263 exitosos). Pushed a GitHub.

---

## 2026-06-12 — Rediseño de descuentos (cierra el feedback 2026-06-11 d)

**Qué se pidió:** unificar los DOS diálogos de descuento, semántica
ajuste/promo, recibo con desglose, settings descubribles, y retirar
`/admin/cuotas` (decisiones de Rubén vía AskUserQuestion; multi-cuota NO).

**Qué se hizo** (rama `claude/adoring-carson-w6l6rj`, 9 commits `16337be`→
`5d2f169`): `DescuentoDialog` ÚNICO (contrato: selector Ajuste/Promo →
`aplicarAjuste(origen:)`; cobro: devuelve `CargoPendiente` DIFERIDO — nada
se graba hasta confirmar, viaja con `pago_id` → anular revierte; fin del
"descuento fantasma") · `CargoDialog` aparte (reconexión/otro, diferido) ·
recibo: desglose en el bloque `cuota` con sub-toggles (3 renderers) ·
settings: grupos Ajustes/Descuentos del cobrador/Pronto pago en Avanzado ·
`/admin/cuotas` RETIRADA (anular cuota y cuotas manuales fuera del
producto) · **migración 0117** (guard promo + motivo server del cobro +
CONDONACIÓN: descuento 100% → cuota `pagada`, espejo en `cuota_estado`).
**Audit Fase 4:** 3 agentes (Code/QA dinero/UX) — 2 ALTOS (USD pisado en
C$, condonación) + 7 menores, TODOS fixeados (`5d2f169`). Tests nuevos:
promos, condonación, descuento manual diferido.

**Iteración 2 (mismo día, feedback de Rubén en el manual):** el COBRADOR
NO descuenta — gestión centralizada en el contrato: sheet "Descuentos y
cargos de la cuota" (lista TODOS los orígenes; pago_id = solo-lectura) con
"Aplicar descuento" + "Cargo extra" (`aplicarCargo` origen='cobro' sin
pago_id, `quitarCargo` protege pago_id/liquidación); el cobro solo
REFERENCIA ("Ver descuentos y cargos"); settings descuento_* del cobrador
a `_hidden`; sub-toggles del recibo visibles solo con features ON (la data
aplicada se sigue imprimiendo). 0117 NO cambió (ya estaba deployada).

**Pendiente:** analyze/test/invariantes → manual §0.3 (deploy 0117 ✓
2026-06-12) → SQL Byr → merge a main. Backlog nuevo: tope ajuste default
50 cliente vs 0 server (pre-0115) · "ANULADO" en recibo de pago anulado ·
reimpresión lee cargos vivos (sin corte temporal).

---

## 2026-06-11 (d) — CHECKPOINT: feedback de Rubén sobre Ajustes (rediseño pendiente)

**Testing del mega-sprint:** pasos 1-6 TODOS verdes (deploy 0115+0116
verificados, invariantes 14/14=0, pub get, analyze 4 infos, tests 254).
El manual destapó 4 problemas de PRODUCTO/UX — la próxima sesión arranca
acá: evaluar el approach y proponer el rediseño ANTES de seguir.

**Feedback de Rubén (verbatim resumido) + diagnóstico preliminar:**
1. **No encuentra el toggle "Ajustes de cuota" en Avanzado** — activó
   "Permitir descuentos" (que es OTRO feature: el del cobrador en campo).
   Causa: los 3 settings nuevos de ajustes no tienen GRUPO curado en el
   panel → caen al final en "Otros" (el F3 que QA flaggeó como backlog
   resultó bloqueante de descubribilidad). Consecuencia: nunca vio el
   icono % ni el AjustarCuotaDialog (motivo+preview) — lo que probó fue el
   viejo AplicarCargoDialog del flujo de cobro, que le pareció poco
   intuitivo. HAY DOS DIÁLOGOS y se confunden → candidato a unificar.
2. **Quiere ajustes a UNA O VARIAS cuotas pendientes a la vez** (ej. días
   sin internet que afectan 2 meses) con semántica clara ajuste vs promo.
3. **Espera los toggles del recibo** (mostrar ajustes/promos) — eso era
   Sprint 3 (bloque "Descuentos y ajustes" del diseñador, no implementado).
   Alinear: adelantarlo al rediseño.
4. **El tab Cuotas re-linkeado (M25) lo afectó:** anuló una cuota de prueba
   y NO HAY des-anular (la anulación de cuota es terminal). Decidir:
   des-anular cuota (trivial sin pagos; complejo con pagos por la cascada
   0023) o sacar/endurecer "Anular cuota" de esa pantalla.

**Reparación de data pendiente (SQL en Dashboard):** des-anular la cuota
de prueba (cliente Byr, Febrero 2026, sin pagos) — SELECT id de la anulada
y UPDATE estado='pendiente', anulada_en/por/motivo_anulacion = NULL.

**Plan próxima sesión (pedido explícito):** re-evaluar el approach completo
de ajustes/promos/descuentos con sugerencias de diseño: (a) panel Avanzado
con grupo propio "Ajustes" (y revisar nombres/UX de los 3 settings), (b) UN
solo flujo intuitivo de descuentos (¿unificar AplicarCargoDialog +
AjustarCuotaDialog?), (c) ajustes multi-cuota desde el contrato, (d) bloque
de recibo + toggles, (e) destino de /admin/cuotas y des-anular. La base
contable (cargos_extra origen/pago_id/grupo_promo + guards 0115/0116 +
INV13/14) está deployada y sólida — el rediseño es de UX/entrada, no del
motor.

---

## 2026-06-11 (c) — Mega-sprint de correcciones (todo el backlog arreglable)

**Por qué:** decisión de Rubén: "corrijamos todo lo faltante primero y
dejamos para último los tests" — atacar TODOS los HIGH restantes del audit
integral + los MEDIUM/LOW técnicos acumulados, y testear todo junto.

**Qué se hizo** (commits `1cc16e3`→`8c4e330`; detalle por commit en git):
- **Los 7 HIGH restantes**: #3 cargos auto re-deduplicados al aplicar cargo
  manual · #4 enforce server de cobrador_anula/edita_cobros · #6 PopScope en
  cobro · #7 doble-submit en forms de cliente/contrato · #8 confirmación al
  cancelar contrato · #9 changelog de `cobradores` (+ botón Historial) ·
  #10 guard server de transiciones de seriales.
- **Migración 0116** (NO corrida aún): los guards #4/#9/#10 + correlativo de
  tickets re-asignado en server (M18) + audit_log append-only para el súper
  (M23) + sin filas update fantasma (no-op guard en la función de changelog).
- **MEDIUMs**: M8 coma decimal en TODOS los montos (parseMonto) · M9 flush
  del debounce de settings · M11 fin del flash "Recibo no encontrado" · M12
  el admin ya no borra el badge de mora del cobrador · M13 KPIs con error
  visible · M14 `mensajeErrorHumano` en ~40 spots · M15 gates de edición en
  historial · M16 confirmación de transiciones terminales de tickets · M17
  updater sin re-descarga post-permiso · M21 UTC en inventario · M25 menú
  Cuotas re-linkeado · M26 build-release -Notes · M5 lock con while.
- **LOWs**: aplicado_en UTC · OfflineBanner en SuperShell · aviso de
  retry-loop en _SyncCard · copy Bluetooth · auth humanizado · mounted tras
  awaits · Cargar más en historial · geolocator fuera / web_plugins
  declarado · 50 de los 54 infos del analyze (42 initialValue + 8 imports).
- **Decisiones tomadas** (revisables): #4 ENFORZADO server-side (no solo
  documentado) · /admin/cuotas RE-LINKEADA (recupera "Anular cuota") · una
  cuota con ajuste NO recibe además pronto-pago (anti doble-descuento).

**Diferido (consciente):** promos (Sprint 3 aprobado en diseño) · M19/M20
(evento server de tickets / cola offline de firma: diseño) · compresión real
de fotos (dep nueva) · M4 clamp de saldo (decisión de semántica) · vista de
rechazos para admin/súper · deprecations announce/Radio/translate.

---

## 2026-06-11 (b) — Sprint 2: Ajustes de cuota + rieles de cargos (M2/M3/M22)

**Por qué:** Rubén pidió evaluar promos y ajustes de cuota; se aprobó el
diseño "todo descuento es cargos_extra, nunca mutar cuotas.monto" + retirar
"Editar monto" + topes preventivos. Promos (opción A) quedan para Sprint 3.

**Qué se hizo** (commits `c98251f`→`fa00fa3`, rama de trabajo):
- **Migración 0115** (NO corrida aún): cargos_extra.origen/grupo_promo/
  pago_id · setting_bool · settings super-only `ajustes_habilitados` +
  topes · `trg_cargos_ajuste_guard` (guard server REAL del feature) ·
  `trg_pagos_revertir_descuentos` (M3). Schema v27 (resync al actualizar).
- **Feature Ajustes:** CuotasRepo.aplicarAjuste/quitarAjuste/ajustesDeCuota
  con mirrors · AjustarCuotaDialog (preview, motivo, topes, coma decimal) ·
  icono % por cuota en el detalle del contrato + sheet con quitar.
- **Fixes del audit:** M22 (agregadores leen `$.padre_id` del snapshot —
  los cargos borrados conservan rastro) · M2 (tope en editarPago) · M3
  (anular pago borra SUS descuentos; reconexión se preserva; cargos del
  cobro llevan pago_id) · M1/M25 ("Editar monto" RETIRADO; setting a
  `_hidden`).
- INV13 en `invariantes_dinero.sql` · tests: 5 de ajustes + 3 de reversión
  + 2 de tope (harness PowerSync real).

**Audit Fase 4 (Code+QA+Regresión): 3 aprobados**; fixes aplicados (seed
chain 0113 · guard sin rebote de cascadas · DELETE de cargos para
admin_cobranza · INV14 anti-fantasma · UX quitar en pagadas).
**Pendiente:** deploy 0115 + sync rules → testing Rubén → merge.
**Backlog nuevo (QA/Regresión, no bloquea):** descuento MANUAL del cobro
(sin pago_id) no se auto-revierte al anular · settings de ajustes caen en
"Otros" del tab Avanzado (agruparlos) · "Exception:" crudo al editar pago
(M15) · guard server sin validación de saldo (INV4/14 lo detectan) ·
'origen' no seleccionable en el catálogo del viewer de audit · DECISIÓN
Rubén: cuota con ajuste no recibe además pronto-pago (anti doble-descuento,
default actual) · el cobrador ve bajar el saldo sin el motivo (capacitación
o mostrar el ajuste en su vista).

---

## 2026-06-11 — Audit integral profundo (8 agentes) + Sprint 1 de fixes

**Por qué:** pedido de Rubén: audit completo de la app (módulos, entidades,
interacciones) con agentes especializados en UI/UX/lógica buscando bugs no
encontrados antes; luego aprobó implementar la recomendación (Sprint 1).

**Audit:** 8 agentes en paralelo + re-verificación manual de cada HIGH →
1 CRITICAL + 9 HIGH + ~26 MEDIUM + ~20 LOW. Reporte completo con plan de
4 sprints: `docs/archive/AUDIT-INTEGRAL-2026-06-11.md` (commit `87a277d`).
Veredicto: dinero/multi-tenant/SQL/TZ sólidos; el riesgo real está en la
divergencia silenciosa y en escrituras offline sin guard server-side.

**Sprint 1 — "ningún cobro se pierde en silencio"** (commits `c9175d1` ·
`c6c5293` · `3436466` + commit de cierre con los fixes de Fase 4):
- `connector.dart`: **allowlist** SQLSTATE (P0001/23/42/22 de 5 chars) —
  PGRST301 (JWT expirado), 429 y desconocidos ahora REINTENTAN; antes se
  descartaba el cobro de la cola para siempre (CRITICAL #1).
- **`CorrelativoStore`** (nuevo): high-water mark monotónico del correlativo
  por cobrador+prefijo (SharedPreferences) + `.timeout(5s)` del piso server —
  no se reusa un número impreso tras anulación+offline (HIGH #2 + M6).
- **`RechazosSyncService`** (nuevo) + card "Cambios sin sincronizar" en el
  Perfil (cobrador/técnico) + SnackBars humanizados en los 4 shells con VER +
  `opData` en error_logs (HIGH #5). Dedupe por retry de batch + writes
  serializados (fixes del audit Fase 4: Code+QA+Regresión, 3 aprobados).
- Tests nuevos: clasificador del connector · monotonicidad del hwm · 2
  regresiones en `pagos_repo_test` (sync borra recibo anulado) · rechazos.

**Testing de Rubén (2026-06-11): APROBADO** — `flutter analyze` sin issues del
sprint (54 infos pre-existentes: deprecations `value→initialValue` etc., quedan
para una pasada de limpieza) · `flutter test` 244 verdes (se actualizó
`recibo_layout_test` que esperaba el orden PRE-954b624, no era regresión) ·
smoke manual OK (pre-check de código duplicado + cobro con correlativo
correcto). **Mergeado a `main`; rama borrada.**

**Pendiente/backlog nuevo:** fotos de cliente SIN compresión → Storage rechaza
con 413 y el SnackBar muestra el error crudo en inglés (visto en el smoke;
candidato Sprint 2 junto con M14 errores crudos) · avisos de rechazo invisibles
para admin/súper (sin pantalla Perfil; decidir si darles vista) · surfacear el
retry-loop de una op envenenada en `_SyncCard` · `rechazos_sync_v1` es
per-device, no per-user (aceptado: equipos personales).

---

## 2026-06-10 — Auto-update in-app + fix de firma del APK + limpieza de releases

**Por qué:** el banner de update delegaba la descarga al browser — en Android
Chrome nunca completaba la descarga (moría en los redirects de GitHub) y en
Windows quedaba en Descargas con instalación manual. Rubén eligió la opción A
(updater in-app, GitHub sigue de host; la opción B —Supabase Storage, que
permitiría repo privado— quedó documentada como alternativa futura).

**Qué se hizo (commits `fc1583a` + `2fdcb3c` + `66e09e5`):**
- **Updater in-app**: la app descarga el binario ella misma (http streamed,
  timeout 30s handshake + por-chunk, progreso 0-100% en el banner, errores en
  español con Reintentar + plan B "Navegador") y lanza el instalador del
  sistema vía `open_filex` (+1 dep): Android → diálogo "¿Instalar?" (permiso
  `REQUEST_INSTALL_PACKAGES` runtime, 1 toggle la 1ª vez), Windows → App
  Installer. Web mantiene fallback browser. Estado `_instalando` evita doble
  descarga. Archivos: `update_service.dart`, `update_banner.dart`, manifest.
- **Fix CRÍTICO de firma del APK** (encontrado por el audit de plataforma):
  el release firmaba con la **debug key de la PC** → un APK de otra PC no
  podía actualizar instalaciones existentes (y "arreglarlo" = desinstalar =
  perder la DB offline del cobrador). Ahora `build.gradle.kts` firma con
  keystore dedicado (`android/key.properties` + `sitecsa-release.jks`,
  LOCALES — gitignored) con fallback a debug para dev. **Rubén debe generar
  el keystore 1 vez** (pasos en `Install Steps/0-Setup-PC-desarrollo.md` §3b).
  ⚠️ Transición: el PRÓXIMO release tendrá firma nueva → las apps ya
  instaladas (firmadas debug) deben desinstalar/reinstalar UNA vez (sincronizar
  antes). Después, updates normales para siempre.
- **Releases viejos limpiados** (con Rubén, gh CLI): quedó solo `v0.9.0`
  (endpoint vivo del auto-update) + tags `pre-mvp-v1/v2`. 18 releases borrados.
- **Pendiente (Rubén):** ~~pub get~~ ✓ · ~~keystore~~ ✓ (generado y
  verificado, backup recomendado) · smoke tests B.2-B.6 + flujo del updater →
  publicar release nuevo (`v0.11.0`) → borrar `v0.9.0`.

## 2026-06-09 (e) — Limpieza de PC local + setup multi-PC

**Por qué:** la carpeta local de Rubén tenía restos de versiones anteriores;
y quiere poder trabajar desde otras PCs con solo `git clone`.

**Qué se hizo:**
- Carpeta local limpiada con `git clean -fdx` (dry-run revisado; exclusiones:
  `.env.json`, `Releases\`, cert y DLLs) → working tree = `main` exacto.
- **Binarios de soporte AL repo** (cambio de `.gitignore`): `powersync_x64.dll`
  (core nativo para los tests de dinero en Windows) y
  `CRM.cer` (cert PÚBLICO del MSIX — no es secreto). `.env.json`
  sigue SIEMPRE fuera de git (keys; a PC nueva va por canal seguro).
- **`Install Steps/0-Setup-PC-desarrollo.md`** (nuevo): guía completa de PC
  de dev nueva (herramientas → clone → .env.json → pub get → run → tests →
  gh para releases). La firma MSIX usa el cert de prueba del paquete `msix`
  (sin certificate_path) → releases compatibles desde cualquier PC.
- `pubspec.lock` actualizado (faltaba `mobile_scanner` — pendiente viejo).

## 2026-06-09 (d) — Consolidación de ramas: main + tags pre-mvp

**Por qué:** había 4 ramas en GitHub (2 de Claude viejas, el checkpoint
`pre-mvp-v1`, y la default era una rama muerta `claude/plan-billing-app-q9mC4`)
— confuso para sesiones futuras y para ver el código actual en GitHub.

**Qué se hizo (decisión de Rubén — opción A):**
- **`main`** creada desde el estado auditado (todo el trabajo del 2026-06-09)
  → **única rama permanente y default del repo**.
- Checkpoints convertidos a **tags inmutables**: `pre-mvp-v2` (= este estado,
  audit integral + fixes + docs rework) y `pre-mvp-v1` (= `48111e5`, el
  checkpoint previo).
- **Borradas** todas las demás ramas: `claude/hopeful-ride-u1ivz5`,
  `claude/new-features-inventory-tickets-and-technicians`, `pre-mvp-v1`,
  `claude/plan-billing-app-q9mC4`.
- Modelo de branching documentado acá (§ESTADO ACTUAL) y en `AGENTS.md`
  (§Git/branching): ramas efímeras desde `main` → merge → borrar; hitos = tags.
- **`AGENTS.md` = LA fuente única de reglas** (decisión de Rubén, patrón
  oficial de Claude Code): todas las reglas/invariantes/proceso viven en
  `AGENTS.md` (estándar que leen OpenCode/Codex/Cursor/Antigravity directo);
  `CLAUDE.md` quedó como shim de 1 línea (`@AGENTS.md`) solo para que Claude
  Code lo cargue automáticamente. Las referencias de los demás docs apuntan
  a `AGENTS.md`. NO editar reglas en CLAUDE.md.

## 2026-06-09 (c) — Rework del sistema de documentación + build a Install Steps

**Por qué:** pedido de Rubén (prioridad máxima): que cualquier modelo futuro
pueda hacer cambios SIN escanear todo el código, con docs que se
auto-referencien y se mantengan al día.

**Qué se hizo:**
- Nuevo sistema de 4 docs activos en la raíz: `PRODUCTO.md` (misión/visión/
  día-a-día/stack+porqués) · `ARQUITECTURA.md` (rework: esquema dual
  humano/AI, módulo por módulo con conexiones + **recetas de cambios
  comunes**) · `BITACORA.md` (este archivo) · `AGENTS.md` (adelgazado: reglas/
  proceso/invariantes + índice maestro).
- `build-release.ps1` movido de la raíz a **`Install Steps/`** (con auto-cd a
  la raíz del repo para que las rutas relativas sigan funcionando);
  referencias actualizadas.
- Docs históricos movidos a **`docs/archive/`** (HANDOFF, REPORTE-SESION,
  ESTADO-APP, STACK, ROADMAP, planes BULK/FASE3, audits, RELEASE) con README
  índice. Nada se borró: historia completa en archive + git.

## 2026-06-09 (b) — Audit integral profundo + TODOS los findings resueltos + deploy

**Por qué:** pedido de Rubén: audit completo de lógica de módulos +
interacciones + conformidad con lifecycle/misión, y resolver todo.

**Qué se hizo (commits `2917a73` → `d31bbb8` → `9f60ab9` → `8eb19e9` → `3f162eb`):**
- **Audit 6 agentes** (dinero, offline-first, change log, inventario/tickets,
  multi-tenant/seguridad, integridad estructural) → veredicto: app sólida,
  sin CRITICAL/HIGH. 6 MEDIUM + 8 LOW, **todos atacados**.
- Fixes clave: lock de `connectPowerSync` (cierra el sync-gate-stuck
  post-forzar-password) · clase 40 retryable en el connector · SLA de tickets
  sin corrimiento de 6h post-sync (`parseTicketWallClock`) · mirror local de
  cargos (saldo correcto offline) · migración **0114** (gate de módulos
  server-side: escritura de inv_*/tickets/incidentes + storage exige
  `tenant_tiene_modulo`) · `eliminar-cobrador` con 12 conteos nuevos tolerante
  a `PGRST205` · `HistorialTicketWidget` (agregador) · UploadResult de fotos
  persistido · password sin sesgo de módulo · viewer de audit ordena por
  `ocurrido_en`.
- **Audit final** (3 agentes sobre todo el diff): sin gaps de código.
- **Deploy verificado CON Rubén:** migraciones 0099→0112 confirmadas corridas
  (tablas 15/15, columnas 6/6, triggers 7/7) · 0114 corrida y verificada
  (~19 policies con el gate) · 4 edge functions redeployadas.
- **Pendiente:** smoke tests en la app — B.2 regresión 0114 con módulo ON ·
  B.3 forzar-password sin F5 · B.4 cargo offline · B.5 SLA estable tras sync ·
  B.6 historial del ticket.

## 2026-06-09 (a) — Checkpoint pre-MVP v1 (sesiones anteriores)

Estado al cierre de la ventana anterior: colores configurables de estados de
cuota across-app (6 estados, gate por rango del cobrador) · limpieza de
settings + recibo con zonas + "Restaurar layout" · fix pantalla negra del
reset · menú Pagos respetando setting para el super. Migración 0113 corrida.
Branch checkpoint: `pre-mvp-v1` (commit `48111e5`).

## Historia anterior (resumen telegráfico — detalle en el historial git)

- **2026-06-08:** audit integral multi-agente (11 agentes) + cancelar contrato
  = saldo 0 + 16 commits de fixes. Migraciones 0111/0112.
- **2026-06-05→07:** Fase 3 completa (tickets 3A→3E: técnico, materiales,
  incidentes, SLA offline) + inventario v2 + red. Schema v17→v26.
- **2026-06-04→06:** impresión térmica resuelta (GS v 0) · mapa offline ·
  reportes Excel/PDF · distribución Windows/Android (MSIX/APK + auto-update).
- **2026-05-23→06-03:** fundación: multi-tenant + RLS + PowerSync per-user ·
  invariantes de dinero + fix del vuelto · change log universal · impersonación
  · BULK 11/12 (multi-cuota, UX admin) · hardening de Edge Functions.

---

## 📌 Backlog vivo (lo REALMENTE pendiente — no re-flagear lo resuelto)

**🔵 DEL AUDIT DEL 2026-09-03 (abiertos):**

- **`app_dispositivos` es ciega al campo.** 38 filas, **ninguna de un cobrador**
  (0 de 8 activos; también 0 de 3 `admin_usuarios`). **5.582 recibos** emitidos
  desde equipos que el registro nunca vio, desde 2026-01-10. RLS **descartada
  empíricamente** (el INSERT con identidad real de cobrador pasa). Causa: la
  telemetría va DIRECTA por Supabase en vez de por la cola de PowerSync que
  reintenta, dispara **una vez por proceso** con `_versionReportada = true`
  puesto ANTES del await, y se traga el error — el cobrador arranca sin señal y
  esa sesión se pierde para siempre. **Importa porque el paso 1 del triaje de
  `/pedido` ("¿con qué versión se hizo?") es inaplicable justo en el rol
  offline-first**, que es el más probable de estar desactualizado.
  Fix candidato: encolar por PowerSync, o reintentar cuando vuelve la conexión.

- **`solicitudes_screen.dart:457` — `case` duplicado, único warning del repo.**
  `crearContrato` está agrupado con `desconocido` → `return null`, y el bloque
  que SÍ está escrito para él (su comentario y su query lo dicen) quedó rotulado
  `desactivarCliente`, que ya se maneja en la :430. Efecto: la tarjeta de una
  solicitud "Crear contrato" se muestra **sin nombre ni código de cliente**.
  Preexistente (está en `3f9385cc`). Hay un task spawneado con el detalle.

- **INV11 va a reportar 3 para siempre** (Mairena). Son las 3 cuotas anuladas a
  mano en la limpieza del cuaderno de agosto ("cliente al día según ISP, pagos
  fuera del sistema"). Un chequeo que SIEMPRE da >0 se termina ignorando y tapa
  el día que haya algo real (regla 14). O se acota el predicado, o se documenta
  la excepción de forma que el chequeo pueda volver a cero.

- **Los dos generadores de escenario no siembran el camino congelado del
  recibo.** `plan_label`: 0 referencias en los DOS. `periodo_label`: en el
  generador SQL sí, en el Dart no. Todo test que renderice un recibo ejercita la
  rama vieja — o sea justo lo que `0268` vino a cerrar. En producción el 100% de
  los recibos nuevos lo lleva; en el escenario, 0% (regla 16).

**✅ AUDITORÍA DE ROLES Y FLUJOS (2026-08-08) — CERRADA 8/8, verificada contra la base el
2026-08-23.** Se fueron aplicando sin tacharse acá, y el backlog quedó mintiendo dos semanas:
planificar sobre él costaba tiempo en cosas ya resueltas. Estado real de cada uno:
`#1` cuarentena/cuota fantasma → el trigger ya escucha `en_revision`, 0 fantasmas ·
`#2` códigos de contrato duplicados → 0 hoy · `#3` writes rechazados mudos → cerrado en
v0.36.0 (`.select('id')` en patch y delete + `_filaSigueVisible` + triple rastro), **y ya
pagó**: al volverse ruidoso destapó el colchón de indefinidos que se rechazaba en silencio
desde el día uno → 0241 · `#4` guard de desactivar → la app espeja literal el guard 0220 y
frena ANTES del write · `#5` admin_usuarios con Total falso → lee el rol dentro de
`_ContratoResumen` y muestra conteo de cuotas · `#6` revalidar código al aprobar → valida
local **y** contra el server · `#7` impersonación + op_log en solicitudes → las dos mitades,
con cobertura de op_log **0% hasta el 08-10 y 100% desde el 08-12** · `#8` export de Clientes
→ salieron "Deuda fuera de ruta" y "Deuda total".
**Lección de proceso: el backlog se tacha en el mismo commit que lo cierra.**

**⚠️ CORRECCIÓN al bullet de "clientes sin salida por CONDONACIÓN" (no borrar, releer).** El
número (40 clientes / C$108.512,58) es correcto pero la LECTURA estaba mal y la propuesta que
salía de ahí era peligrosa: **28 de esos 40 (C$89.153, el 82,9%) tienen contrato SUSPENDIDO,
o sea mora normal, reversible y COBRABLE** — y 32 de los 40 tienen historial de pagos. Prender
`ajustes_habilitados` y descontarles habría condonado C$89.000 cobrables. La población real
del problema son **11 clientes por C$18.429,57** (solo cancelados), y la salida YA EXISTE
desde 0244/0245: `super_admin_baja_deuda_impl`, con preview, motivo, backup y triple registro.

**No re-flagear:** los 177 cobros de julio sin `op_log` tienen causa identificada y cerrada
(RLS de `op_log` para cobradores: sin policy de SELECT el upsert moría con 42501 en el
RETURNING y el connector lo descartaba → 0190, 2026-07-17). Firma clara: los dos cobradores
con 0 filas antes de esa fecha y cientos después; la oficina nunca perdió una. Un solo caso
posterior en toda la base.

**🔻 Lo que sigue abierto de esa auditoría: NADA.** Lo pendiente vivo está en
`docs/AUDIT-INTEGRAL-2026-08-22.md` (42 de 47) y `docs/PLAN-CONSISTENCIA-2026-08-23.md`.
Metodología: 7 ejes en paralelo + sintetizador + crítico adversarial, después 8 specs de
pantalla con verificador por spec. Todo re-verificado con SELECT contra `vxxz`. El crítico
tumbó 2 hallazgos falsos del informe (la lista de Clientes YA muestra la deuda fuera de ruta
vía `saldo_fuera_ruta` + chip; y el rol `coordinador` SÍ tiene migración, `0207`) y un
verificador cazó un cliente inventado (EG0117). **No re-flagear esos tres.**

- **#1 CRÍTICO — resolver una cuarentena deja la cuota fantasma.** `trg_pagos_update_recalcular`
  es `AFTER UPDATE OF monto_cordobas, cuota_id, anulado` y **le falta `en_revision`**.
  `pagos_repo.elegirCobroVerdadero` (`pagos_repo.dart:834-887`) anula primero los otros (dispara
  el trigger, deja la cuota en 0 porque el elegido sigue `en_revision=1`) y recién después hace
  `UPDATE pagos SET en_revision=0`, que el trigger NO escucha. Queda cuota pendiente con la plata
  cobrada: traba oldest-first, infla mora, impide desactivar. El comentario de `pagos_repo.dart:828`
  ("el server recalcula") es FALSO para este camino. **Daño hoy: 0 cuotas** (nadie lo disparó);
  1 pago en cuarentena vivo, en Test Tenant. **Auto-sanación parcial:** `cuotas_forzar_derivados_trg`
  es BEFORE UPDATE, así que cualquier escritura posterior sobre esa cuota la repara.
  **Fix: 1 línea de migración** (agregar `en_revision` al `AFTER UPDATE OF`).
- **#2 CRÍTICO — códigos de contrato duplicados: EL DAÑO YA ESTÁ HECHO.** 10 códigos fueron
  aprobados DOS veces (20 solicitudes 'aprobada') y solo existen 10 contratos → **10 contratos
  nunca llegaron al server**; **8 clientes de Telecable Mairena están activos, con servicio,
  con 0 contratos y 0 cuotas** (RA0028, CNS032, RA0006, RA0016, SE0368, SA0076, SA0030, LF0103).
  Nadie les factura. Y **sigue creciendo**: 7 pares pendientes (000126/127/129/130/131/132/135),
  4 segundas mitades cargadas el 08/08 entre 22:05 y 23:12 → **el dispositivo del digitador NO
  tiene v0.31.24** (que ya trae el guard en `contrato_form_screen.dart:434`). El aviso de rechazo
  existe pero es genérico y llega DESPUÉS del SnackBar verde "Crear contrato aprobada y ejecutada".
  **Falta:** actualizar la app del digitador · limpiar los 7 pares · reponer los 8 contratos ·
  revalidar el código en `_ejecutarCrearContrato` · chip de choque en la tarjeta de Pendientes.
- **#3 ALTO — writes rechazados que desaparecen sin aviso** (`connector.dart:76/:80`). El `patch`
  y el `delete` van sin `.select()`: si la RLS filtra por USING, PostgREST devuelve 204 sin error,
  el connector hace `transaction.complete()` y al drenar el checkpoint el valor **vuelve solo**.
  El `put` (upsert) SÍ avisa. Alcance: **57 policies en 32 tablas**. Caso medido: 3.279
  `notificaciones_mora` que un cobrador nunca logra marcar (ya documentado empíricamente en
  `mora_count_provider.dart:14-15`). **Con el modelo corregido (revert, no corrupción) este fix
  sube al podio**: es lo que vuelve visible una clase entera de bugs. Fix: `.select('id')` +
  tratar respuesta vacía como rechazo. Hueco extra: admin/admin_cobranza/admin_usuarios (9 de 19
  usuarios) **no tienen ruta a PerfilScreen**, así que la tarjeta "Cambios sin sincronizar" no
  existe para ellos.
- **#4 ALTO — desactivar cliente: el guard de la app y el del server usan criterios distintos.**
  `cliente_form_screen.dart:385-402` bloquea por CONTRATOS ACTIVOS; `trg_clientes_guard_desactivar`
  (0220) bloquea por DEUDA. **5 clientes** caen en el hueco (C$4.925,24): CNC046 Irania C$2.432,61 ·
  CR0050 Victoriano C$711,58 · CNC106 Donald C$496,45 · LV0031 Anabel C$384,60 · SEED05 (Test).
  Se pierde TODO el guardado (teléfono, dirección, geo), y el `op_log` del mismo writeTransaction
  SÍ sube → historial de un cambio que el server nunca aceptó. **El rechazo NO es mudo**
  (SnackBar rojo 6s con el texto del trigger + tarjeta en Perfil) pero llega DESPUÉS de
  "Cambios guardados" y en otra pantalla. Fix: espejar el guard del server en el form, con aviso
  preventivo al apagar el switch.
- **#5 ALTO — `admin_usuarios` ve un Total de contrato FALSO.** `contrato_detail_header.dart:257`
  renderiza `_ContratoResumen` sin gate de rol; `Recaudado` sale de `pagos`, tabla que su bucket
  (`todo_tenant_admin_usuarios`) no baja → 0, y `Total = recaudado + pendiente` (`:341`) arrastra
  el 0. Contrato real 1797: el admin ve 19.776,00 C$ y el admin_usuarios 8.240,00 C$ (**−58%**).
  Contradice el "Pagadas 7/12" que la misma app le muestra un paso antes. 3 usuarios vivos.
  Fix: leer `esAdminUsuarios` DENTRO de `_ContratoResumen` (arregla los 2 call sites) y mostrar
  conteo de cuotas en vez de plata.
- **#6 ALTO — revalidar el código en `_ejecutarCrearContrato`** al aprobar (hoy no revalida).
- **#7 MEDIO — `solicitudes_screen` no chequea `bloqueadoPorImpersonacion`** (0 llamadas en toda
  la carpeta, 31 en el resto de `lib/features/`). Un super_admin impersonando que aprueba estampa
  su id en `aprobador_id`/`suspendido_por`/`anulada_por`. **Daño ya hecho: CERO** (0 de 202
  resueltas). Fix: 3 líneas con el mensaje que ya existe. Aparte: `solicitudes_accion` no está en
  el catálogo de `op_log_campos.dart` → aprobar/rechazar no deja NINGUNA fila de `op_log`.
- **#8 MEDIO — el export de Clientes a Excel subestima la cartera.** La pantalla muestra dos
  cifras (saldo de ruta + chip "fuera de ruta"), el Excel exporta solo la primera. Quedan afuera
  **380.462,10 C$ de 129 clientes**, y **45 clientes se exportan con saldo 0 debiendo 86.594,65 C$**.
  Ejemplo CE0012: Excel 3.664,00 vs chip 26.922,00. Fix: agregar "Deuda fuera de ruta (C$)" y
  "Deuda total (C$)". **NO tocar la query de pantalla.**
- **MEDIO — los 5 clientes sin salida por CONDONACIÓN.** El trigger dice "cobrale o anulá esas
  cuotas", pero no existe acción de anular cuota en la app y "Aplicar descuento" cuelga de
  `cobranza.ajustes_habilitados`, **false en los 4 tenants** (setting super_admin-only).
  **Corrección: el COBRO sí es salida real y señalizada** (el botón "Pagar" funciona sobre
  contratos cancelados; los suspendidos tienen "Cobrar pendiente"). Lo que falta es cerrar la
  cuenta sin cobrar. Opciones: ventana controlada prendiendo el setting, o una acción propia
  de "Condonar y dar de baja".
- **MEDIO — 4 providers sin `dbEpochProvider`** · **BAJO-MEDIO — "Tus cobros anteriores" no
  filtra por `cobrador_id`** (los 3 flags que lo exponen están en false en los 4 tenants; el
  bucket `por_cobrador` baja todo el tenant POR DISEÑO, así que el bug es el rótulo, no la query).
- **DOC (13 divergencias) — el área más débil.** La que más contagia es **D5**: `AGENTS.md`
  invariantes #4/#7 definen los pagos vivos como `anulado=false`, pero el predicado canónico real
  es `anulado=false AND en_revision=false` (en `recalcular_cuota_desde_pagos`,
  `pagos_guard_sobrepago_trg` y `cuotas_forzar_derivados`). Corregir eso PRIMERO. También:
  `admin_cobranza` NO aprueba solicitudes (el router lo rebota aunque la RLS lo permita), los
  ajustes de impresora viven en **Perfil → Impresora**, y `coordinador`/`admin_tickets` están mal
  documentados en `MODULOS.md`/`ARQUITECTURA.md`. Sugerencia del crítico: generar §3.6.1 y la
  tabla de buckets con un script desde `pg_trigger`/`pg_policies`/`sync-rules.yaml` en vez de
  mantenerlas a mano, y **borrar los conteos hardcodeados**.
- **NO TOCAR (verificado, riesgo del fix > riesgo del agujero):** la query de saldo de la lista de
  Clientes · `cuotas_update_cobrador_propio` · los 7 `LEFT JOIN recibos` sin `anulado=0` · el
  diseño del correlativo de recibo · `por_cobrador` bajando todo el tenant · el path de impresión
  compartido.
- **Fragilidad latente:** la barrera de columnas del `coordinador` funciona porque su trigger
  ordena alfabéticamente primero entre los 4 BEFORE UPDATE de `tickets`. Un trigger nuevo
  `trg_tickets_a*`/`b*` lo dejaría sin poder hacer nada. Vale un comentario en 0207 y una nota en R10.

**🔴 PEDIDOS DEL DUEÑO DEL TENANT (2026-08-08, carpeta `Downloads/revision 3`):**
- **Dashboard › Resumen — la matemática no cuadra (EN AUDITORÍA).** Telecable Mairena, período
  "Agosto 2026" (15 jul – 14 ago): Cobros 3.969.521,11 · Recuperado 1.821.490,92 (46%) ·
  Por recuperar 2.148.030,19 (54%) · Mora total 939.039,00 · Mora recuperada 207.343,00 (22%) ·
  **Este período (caja) 2.965.968,81 / 3366 cobros**. El dueño suma 1.821.490,92 + 207.343 =
  2.028.833,92 y la app le da 2.965.968,81 → **hueco de 937.134,89 C$**. Hipótesis a confirmar:
  la pantalla mezcla dos ejes (por FECHA DE PAGO vs por PERÍODO DE LA CUOTA) sin decirlo; el
  "Antes del ciclo" de 171.821,92 del gráfico es la prueba de que "Recuperado" incluye plata
  pagada antes de que arrancara la ventana. También pregunta **qué significa "Antes del ciclo"**.
- **Cambiar la TARIFA de un contrato sin crear uno nuevo** (audio 08/08): hoy, cuando cambia el
  precio, cancelan el contrato y hacen uno nuevo, "y se nos está generando un conflicto".
  Es exactamente la feature de **cambio de plan (R22)**, con diseño aprobado y las fases 1 (gate)
  y 3a (matemática) hechas — falta repo/trigger/UI/audit. Ver memoria `feature-cambio-plan-contrato`.

**🟢 No urgente (parqueado por decisión de Rubén 2026-06-24 — NO re-flagear como pendiente urgente):**
- **Impresión térmica Bluetooth — desborde de buffer en impresoras baratas (código HECHO, falta confirmarlo en
  campo):** la **3nStar PPT305BT** (80mm, Mairena) imprime **cortado** (falta el pie) y en el reintento sale
  **basura + de más**; pero el MISMO setup anda bien en OTRO teléfono. Diagnóstico: BT SPP no tiene control de
  flujo confiable → el teléfono manda el raster (~70KB) más rápido de lo que la impresora imprime (72 mm/s) → su
  buffer se desborda → se pierde la cola (corte) o pierde sincronismo del comando de imagen (basura). Es la
  **combinación teléfono+impresora**, no la app ni la impresora solas. **El "envío lento" ya existe**
  (`impresoraEnvioLentoProvider`, toggle **opt-in por dispositivo** en Perfil → Impresora, default OFF). **Ojo con
  qué hace hoy en Bluetooth:** es un write ÚNICO + **settle de 2s antes del disconnect** — el chunking de 512B con
  pausas de la v1 (v0.24.3) se ELIMINÓ en v0.24.4 porque las pausas caían dentro del bloque binario del `GS v 0` y
  rompían el raster en la 3nStar; o sea que ataca el disconnect prematuro, NO el desborde de buffer. El pacing real
  por bandas solo existe en Windows/USB (`WindowsRawPrinter.enviarSegmentos`, cada banda es un comando completo).
  Es la versión CORRECTA de lo que se revirtió en v0.22.10-13 (opt-in, NO
  global — memoria `impresion-no-tocar-raster-global`). **Falta:** probarlo en el teléfono que fallaba; si el pie
  sigue en blanco, el desborde de buffer BT sigue sin fix (habría que cortar SOLO en límites de comando). Sugerencias
  sin código ya dadas: quitar ahorro de batería de la app en ese teléfono (Xiaomi/Redmi son agresivos con BT),
  re-emparejar, proximidad, cargar la impresora, self-test/config de velocidad de la impresora.
- **PowerSync — volumen:** el self-host **YA SE HIZO** (VPS Hetzner desde 2026-07-13, ARQUITECTURA §3.8) y con
  eso el "Data Synced" dejó de ser un límite de plan. Lo que queda es vigilar volumen/costo del VPS a escala
  (memoria AI `powersync-limite-self-host-sandbox`, ya histórica).
- **WhatsApp API (envío automático por lote):** construido y DORMIDO; falta el setup de Meta de Rubén (no es
  código). El modo gratis `wa.me` manual desde Avisos ya funciona.
- **Resend / dominio de email:** parqueado (onboarding sin email; no hay columna email).
- **Flags `modo_ruta` / `caja_chica`:** ocultos por decisión. **Geo del cobro:** parqueado.
- **Sync gate del super_admin en instalación fresca:** cicla varias pasadas (muchos buckets); pre-existente,
  no del white-label. Suavizarlo (UX) es ítem aparte.
- **`admin_tickets` (rol): ✅ RESUELTO, ya no es backlog** — se ofrece al invitar/editar personal cuando el tenant
  tiene el módulo tickets (`cobradores_admin_screen.dart`, junto a `tecnico`/`coordinador`) y tiene shell y bucket
  propios. Sin usuarios asignados en prod, pero disponible.
- **Empty-state del mapa para cobrador:** el atajo "Ver todos" se agregó solo para admin (el cobrador no tiene
  esa vista por diseño); si un cobrador sin cobrables-con-GPS necesitara verlos, es un caso aparte.

**Hallazgos de la AUDITORÍA 2026-06-24 aceptados como DISEÑO (no bug — no re-flagear):**
- **Reasignar cobrador offline → ACEPTADO POR DISEÑO (confirmado Rubén 2026-06-24):** la reasignación se hace
  ONLINE (el admin arma la ruta con conexión); ahí el trigger server 0068 cascadea `cobrador_id` a
  contratos/cuotas/cargos/notif/fotos y PowerSync lo sincroniza, así el cobrador sale a campo con el estado YA
  correcto y trabaja offline sin problema. La staleness que vio la auditoría solo aplicaría si se reasignara
  OFFLINE, que NO es el flujo. No toca dinero (la reportería agrupa por `pagos.cobrador_id`) ni oculta data
  (bucket por_cobrador tenant-wide). R15. No se codea el espejo offline (sería replicar una cascada de 5 tablas,
  mayor riesgo/menor valor); si alguna vez se prioriza: leer 0068 + replicar con test.
- **Contrato creado offline** queda sin cuotas hasta sync (las genera el trigger server; el colchón se reasegura
  en el 1er cobro). Facturación vencida → no hay cobro offline inmediato dependiente.
- **Correlativo mismo cobrador en 2 devices offline:** colisión 23505 al sync (el 2º recibo se descarta, el pago
  persiste sin recibo). Análogo al oldest-first multi-device (#11), aceptado.
- **Dashboard bruto vs arqueo neto:** cobros/top-cobradores/por-cobrador/fiscal/eficiencia reportan BRUTO; solo
  el arqueo resta devoluciones (invariante #4 — métricas distintas, consistente entre las vistas brutas).
- **Filtro mora:** "En mora" usa `!= suspendido` (incluye cancelados con deuda viva) vs "Recuperación/Proyección"
  usan `= activo`; intencional (rutas), puede confundir al comparar cards. No viola #10.
- **Recovery de password por email** pese al modelo sin-email → decisión de producto: ocultar/reetiquetar el
  botón "Olvidé mi contraseña" para tenants sin email.
- **Card Pagos:** el super_admin entra por URL `/admin/pagos` aunque el toggle del tenant esté OFF (el menú la
  oculta) — inconsistencia menor de UX, solo super, sin impacto de datos.
- **Granel offline puede ir negativo** (aceptado en 0106; el ledger es la verdad y concilia al sync).
- **Código muerto:** `recibos.reimpresiones` (siempre 0) y `audit_changelog.dart` (huérfano post-0140) — limpiar
  cuando toque (borrar columna sincronizada = cambio destructivo, no urgente).
- **Asimetría código duplicado:** el cliente pliega ñ/acentos, el `UNIQUE` server (`upper()`) no → el cliente es
  MÁS estricto (lado seguro, intencional). Flash 1-frame en restart de mismo usuario (self-corrige).

**✅ RESUELTO — BUG DE ANCLAJE día_pago vs mes calendario (auditoría integral 2026-06-16, 23 agentes):**
Lo destapó Rubén testeando S3 (suspensión decía deuda 0 cuando el período de servicio ya estaba cumplido).
El núcleo CONTABLE (saldo canónico, recaudado, total fijo, cambio-de-fecha) quedó SANO; el daño estaba
acotado a EVENTOS DE CICLO (suspensión/reactivación) que anclaban por MES CALENDARIO en vez del ciclo de
servicio del día_pago. **Modelo correcto ahora documentado en §3.5 de ARQUITECTURA** (regla de oro).
- ✅ **ALTA — anclaje (`66fbed2`):** helper `ventanaServicio`/`estadoServicio` en `prorrateo.dart` +
  clasificación por ventana de servicio en `suspenderContrato`/`_calcularDeudaSuspension`/`reactivarContrato`
  (reinicio limpio desde mesR+1) + label del diálogo. 2 audits adversariales limpios + 40 tests reescritos +
  validado en app S1–S6.
- ✅ **MEDIA — reportería (#10) (`42edbbc`):** las 3 queries de mora (`reportes_admin_screen.dart` PDF/Excel +
  `_MoraPorComunidadCard`) ahora excluyen suspendidos (`!= 'suspendido'`) — consistente con el dashboard.
- ✅ **MEDIA — recibo (#10) (`42edbbc`):** bloque EN MORA del recibo rotula con `mesServicioLabel(periodo,
  dia_pago)` (`fetchMoraContrato` trae `dia_pago`), no `Fmt.mes`.
- ✅ **BAJA(a) (`42edbbc`):** `dias_mora` del reporte resta `diasGracia` → coincide con el badge "Vencida Nd".
- **(b) — cosmético, casi inalcanzable (re-revisado de primera mano 2026-06-16):** el recibo trae el
  `dia_pago` VIVO (`ct.dia_pago` por JOIN, `recibo_screen.dart:75,104`) y la etiqueta del mes la deriva
  `Fmt.periodoRecibo`→`mesServicio` (`formatters.dart:98,115`). La CUOTA queda histórica intacta (periodo/
  venc/monto — invariante #1 de Rubén); SOLO la ETIQUETA del mes se recalcula al REIMPRIMIR un recibo de una
  cuota pagada ANTES de un cambio de día → puede saltar de mes. No toca dinero ni datos. Candidato a "no se
  arregla" (o snapshot de `dia_pago` en `recibos` — columna + migración).
- **(c) — ✅ RETIRADO, NO es bug (re-revisado de primera mano 2026-06-16):** el subagente inventó un escenario
  irrealizable. `periodoServicioRango` usa día vivo + venc histórico, PERO para verse mal haría falta una
  cuota PENDIENTE con venc viejo en la lista de cobro, y eso NO llega a pasar: R13 bloquea el cambio de fecha
  con 2+ vencidas o parcial en curso, la única vencida se cobra en la misma transacción, y el trigger
  `contratos_actualizar_cuotas_futuras_trg` (`0018:110-116`) re-fecha TODAS las pendientes con
  `periodo >= mes_actual`. El modelo NO fusiona períodos (confirma el punto de Rubén).
- **✅ (d) RESUELTO (migración 0142, 2026-06-22, LIVE en prod):** `generar_cuotas_contrato` pasó de
  `GREATEST(0,…)` a `GREATEST(3,…)` → un indefinido SIEMPRE arranca con el colchón de 3 cuotas desde la primera
  cuota de pago, sin importar la fecha de instalación (antes, instalación futura → <3 o 0 cuotas). Función
  server-side idempotente; no toca cuotas existentes; efecto inmediato sin build. Backlog menor (sigue): test
  del path *indefinido* de `reactivarContrato`.
- **✅ COALESCE(monto_pagado) global RESUELTO (2026-06-22):** se envolvió `monto_pagado` en `COALESCE(…,0)` en
  las 22 ocurrencias de la fórmula de saldo en `lib/` (8 archivos; `cobros_query` ya lo tenía). Defensa: una
  cuota con `monto_pagado` NULL ya no desaparece del SUM (sub-cuenta silenciosa). Es Dart → se activa con el
  próximo build/release. `flutter analyze` limpio · 361 tests OK.
- **Por qué se escapó:** los audits previos verificaron consistencia de fórmulas y SQL, pero NO el
  supuesto del modelo de período (tomaron `montoPuente(1°mes,…)` como dado). Regla nueva implícita:
  auditar SIEMPRE el anclaje del período, no solo la aritmética.

**Operativo (Rubén):**
- Smoke tests B.2–B.6 (ver entrada 2026-06-09 b).
- `flutter analyze` + `dart format` en el próximo build local.

**LOW / cuando toque (contexto: audit del 2026-06-09, en el historial git):**
- Tests: widget + integración + redirects del router (hoy 0).
- **`analysis_options.yaml` no existe** → los lints del proyecto nunca corrieron (`flutter analyze` va
  con los defaults del SDK). Crearlo es barato; puede destapar ruido acumulado.
- `/super/logs`: filtro de fechas + cron de retención >90d.
- `reenviar-invitacion`: lock delete→create (solo afecta con 2+ super_admins).
- Edge cases teóricos documentados: cross-tab sin sync, race autoDispose entre
  tenants, PKCE recovery user-switch, `lastSyncedAt` semantics.
- Config de distribución de producción: applicationId, cert, deep-links.

**Suspensión — ✅ DECIDIDO (Rubén 2026-06-22): NO se implementa ninguna de las 2 (cerradas):**
- **Umbral de mora para suspender → NO. Suspender queda LIBRE (como hoy).** Razón de Rubén: la
  suspensión es MULTI-MOTIVO — un cliente AL DÍA puede pedir pausar el servicio (ej. viaje) y volver
  en X meses. Atar la suspensión a tener mora rompería ese caso legítimo. Se descarta la regla 0/1/2+
  (no se crea setting ni gate de umbral).
- **Guard server-side "reactivar exige 0 pendiente" → NO. Queda UI-only.** Se mantiene el gate de UI
  (`cobrable < 0.01` en `_SuspensionCard`); no se agrega trigger. El **oldest-first** también queda como
  está (red en `pagos_repo` + 6 guards de UI, sin trigger, por decisión previa). Límite offline/SQL
  multi-device aceptado a conciencia.

**Cancelar contrato (decisión Rubén 2026-06-17):**
- **✅ RESUELTO (v0.12.2, rework de filtros):** el filtro **Estado de servicio** en la lista de Clientes incluye
  "Suspendido con deuda" y "Cancelado con deuda", y la tarjeta muestra el badge **"debe C$X fuera de ruta"**
  (columna `saldo_fuera_ruta`). El admin ya puede encontrar/ver a los deudores de bajas sin ensuciar los flujos
  diarios (siguen fuera de Cobros/mapa/badge de mora por diseño).

**Parqueados por decisión de Rubén:** flags `modo_ruta`/`caja_chica` (ocultos) ·
geo del cobro · Resend/dominio (externo).
