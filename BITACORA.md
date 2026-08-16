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

- **👉 NUEVO (2026-08-10, ÚLTIMO) — Notas internas, se elimina la suspensión por lote, y la deuda
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

**🔴 AUDITORÍA DE ROLES Y FLUJOS (2026-08-08) — findings abiertos, ninguno aplicado todavía.**
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
