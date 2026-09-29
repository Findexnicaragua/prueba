# INFORME DE AUDIT INTEGRAL — Cobranza ISP (CRM)
**Fecha:** 2026-08-22 · **Base:** `vxxzesbmilfolwjhfxgr` (PRODUCCIÓN, solo lectura) · **Código:** `main` @ `1c7b758` + tag publicado `v0.36.0` @ `e5a141c` · **Lentes:** 7 + refutación de los 12 hallazgos más severos

---

## VEREDICTO EN 5 LÍNEAS

1. **El sistema está sano donde más importa: la plata cuadra.** Corrí yo mismo los 20 invariantes contra producción: 18 en cero, y los 2 que no (INV11=3, INV19=7) son exactamente los preexistentes que BITÁCORA ya declara y cuantifica. Ninguna violación nueva en 57.000 cuotas, 31.813 pagos y C$27,5M de recaudación histórica.
2. **Duele en un solo lugar, y duele de verdad: el prorrateo de suspensión/cancelación.** Es el único punto donde la app escribe un monto de plata equivocado por su cuenta, en el build que está en la calle, con la vista previa mostrando el mismo número malo — o sea, sin control humano posible. Ya lo hizo una vez (SE0294, Telenet-Mairena) y hoy hay 16 cuotas armadas.
3. **El segundo dolor es silencioso: reactivar un contrato pierde meses facturables.** Hay un contrato de Telenet (MV0167) cargado ahora mismo para perder C$1.832 en el momento en que alguien apriete "Reactivar", sin que nada avise.
4. **El fix cross-tenant de 0246/0247 está bien hecho y verificado en vivo** — pero dejó dos huecos gemelos sin cerrar (el arqueo y un selector de técnico) y un fix de seguridad que la bitácora da por publicado y no viajó.
5. **Arreglá primero, en este orden: el clamp del prorrateo (3 líneas), el filtro de motivos de `reactivarContrato` (1 línea) y las cuatro mentiras de la guía de troubleshooting SQL.** Todo lo demás puede esperar al próximo sprint.

---

## HALLAZGOS POR SEVERIDAD

| # | Sev | Área | Objeto | Qué está mal | A quién le pasa |
|---|-----|------|--------|--------------|-----------------|
| 1 | **CRÍTICA** | Contable | `contratos_repo.dart:224` (suspender), `:630` (cancelar), `:1389` (preview), `prorrateo.dart:excedenteCuota` | Prorratea el ciclo en curso con `planes.precio_mensual` **LIVE** en vez del monto snapshot de la cuota, y clampea solo por abajo (al pago). Puede **SUBIR** la cuota por encima del mes entero. | Admin / admin_cobranza de Mairena y Telenet, con su identidad real, en un flujo rutinario |
| 2 | **ALTA** | Cuotas | `contratos_repo.dart:865-872` vs `0234` | `reactivarContrato` revive filtrando por el string `motivo_anulacion = 'Suspensión temporal'`; el trigger del server y la reparación 0234 escriben otros dos motivos → esas cuotas quedan anuladas para siempre y el colchón no las repone (UNIQUE contrato+periodo) | Telenet hoy (MV0167, C$1.832); cualquier suspensión futura que caiga en la carrera de sync |
| 3 | **ALTA** | Doc / contable | `Troubleshooting SQL/GUIA-TROUBLESHOOTING-SQL.md` §4 (:156-174) | La tabla de "triggers que corren solos" se congeló en 0150: falta `z_contratos_anular_cuotas_futuras` (0234), que ante un `UPDATE contratos.estado` **anula cuotas en masa**, más los 2 guards de sobrepago y 5 triggers más | Quien corrija data de un tenant por SQL — el flujo documentado del proyecto |
| 4 | **ALTA** | Doc / contable | Misma guía, :20, :89, :217, :338 | Define la verificación post-fix obligatoria como "todas las filas (INV1-INV17) en 0". El script emite **20**. INV19 tiene **7 violaciones vivas** hoy y queda fuera del rango | El operador o el AI que cierra un fix de plata creyendo que pasó el control |
| 5 | **ALTA** | Arquitectura / contable | `ARQUITECTURA.md:1486` (§3.5-3) vs `:2911` (R22) vs AGENTS #5 | La "regla de oro" define el Total de contrato fijo como `precio × meses`, al revés del invariante #5 redefinido — y su encabezado dice "si una pantalla no cuadra con esto, la pantalla está mal" | La próxima sesión que toque el header del contrato con `cambio_plan_habilitado = true` (ambos ISP) |

### Los CRÍTICA / ALTA, uno por uno

---

**#1 — Prorratear con el precio del plan puede subir la deuda del cliente que pide la baja**

Lo verifiqué con mis propios ojos en el código vigente (`sed -n '215,232p'`, `'622,636p'`, `'1382,1396p'` de `contratos_repo.dart`): los tres puntos hacen `montoPuente(v.inicio, fecha, precioMensual)` y los tres cierran con `final nuevoMonto = prorrateado < pagado ? pagado : prorrateado;` — clamp **solo contra el pago**, ningún techo en `montoAntes`. Y `precioMensual` sale de un `JOIN planes` en el momento de abrir el diálogo, o sea el precio VIVO. AGENTS #5 dice explícitamente lo contrario: las cuotas son snapshots del precio de su momento.

La aritmética se reproduce sola. **SE0338** (Mairena, `dia_pago` 27, cuota de agosto C$513, plan C$1.282): suspender hoy le deja la cuota en **C$1.075,23** — más del doble de su propia cuota — por 26 días de servicio. **SE0277**: C$513 → C$708,39. Y al revés también pierde el ISP: **LB0175** debería prorratear C$797,42 y prorratea C$620,32. Hay **16 cuotas vivas en 10 contratos ACTIVOS** de Mairena con el monto desalineado del precio del plan. **Y ya se consumó una vez**: op_log registra `tipo_op='cancelacion'` sobre **SE0294** el 2026-08-11, campo `monto`, antes **479,90** → después **496,45**. Un cliente canceló y el sistema le subió la deuda.

Lo que lo vuelve crítico no es el C$16,55 acumulado — es la trayectoria y la ausencia total de red: (a) el vector está **ACTIVO**, lo verifiqué contra la base: `cobranza.cambio_plan_habilitado = true` en Mairena y en Telenet, con `op_log` de cambios de plan del día de hoy; (b) hay un **segundo vector sin ningún gate**: editar `planes.precio_mensual` desde el panel desalinea de golpe todos los contratos de ese plan; (c) la **vista previa usa la misma función**, así que el cobrador ve el número malo con total confianza; (d) el Centro de cobranza tiene "Suspender los N" sobre la cola de mora, que barrería a todos los expuestos en un clic; (e) no hay trigger, ni CHECK, ni guard de UI que lo frene — busqué los cuatro y no existe ninguno.

**Fix (por orden de urgencia):**
1. **Red dura, 3 líneas, aplicable ya:** `final nuevoMonto = math.min(prorrateado < pagado ? pagado : prorrateado, montoAntes);` en `:225`, `:631` **y `:1390` (el preview — si clampeás la mutación y no el preview, el diálogo muestra un número y la app escribe otro)**. Prorratear nunca puede subir una cuota. No rompe nada: hoy ninguna suspensión legítima necesita subir un monto.
2. **Fix real:** columna `cuotas.precio_base` (snapshot del precio al generar y al cambiar de plan) y prorratear contra eso. **Ojo:** el atajo de "pasar `montoAntes` a `montoPuente`" que propuso el lente es inseguro tal cual — una cuota ya prorrateada por una suspensión previa (el caso SE0294, monto 479,90) no es una tarifa mensual, y re-prorratearla sub-cobra. El clamp del punto 1 no tiene ese problema porque solo acota por arriba.
3. Reemplazar el gate del caso-corte de reactivación (`:832`, `AND monto < precioMensual`) por una marca explícita en `deuda_snapshot` — **con fallback**, porque hay 16 reactivaciones registradas cuyos snapshots no la tienen.
4. Test en `prorrateo_test.dart`: cuota con monto ≠ precio del plan, suspensión a 2/3 del ciclo → el resultado debe ser ≤ el monto original.

---

**#2 — Reactivar un contrato no revive las cuotas que anuló el server: los meses se pierden en silencio**

Confirmado en código y en base. `contratos_repo.dart:865-872` filtra literal `AND motivo_anulacion = 'Suspensión temporal'`. La migración 0234 escribe otros dos motivos, que grepeé yo mismo: línea 58 `'Suspensión de contrato (red del server)'` y línea 156 `'(reparación 0234)'`. El hueco es **permanente**: el `unique index cuotas(contrato_id, periodo)` + el `ON CONFLICT DO NOTHING` de `generar_cuotas_contrato` + el piso anti-backfill hacen que ni el cron ni el colchón las repongan nunca — y el espejo Dart (`colchon_indefinido.dart:106-130`) chequea existencia **en cualquier estado**, anuladas incluidas.

El lente lo declaró "latente"; la refutación demostró que **no lo es**. Midió solo el motivo del trigger (0 filas, correcto) y no vio el tercero: **Telenet, contrato `f3185fd1-9e26-4800-927c-552d8ff7280f` (cliente MV0167, Juan José Castro López)**, suspendido desde el 2026-07-06 con la suspensión abierta, tiene los períodos 2026-08 / 09 / 10 anulados el 12/08 con el motivo de reparación y **cero filas con 'Suspensión temporal'**. Simulando la reactivación de hoy: paso 2 revive 0 filas, paso 3 no inserta (las cuotas existen, anuladas) → el contrato vuelve a estar activo y los dos meses de servicio realmente prestados quedan **sin cuota facturable: 2 × C$916 = C$1.832**, invisibles (están anuladas, no salen en ninguna lista) y con el saldo del cliente mostrando menos deuda de la real. El propio `deuda_snapshot` de esa suspensión es `[]`, o sea que `revertirSuspension` tampoco lo salva.

**Fix:** lo barato es ampliar el filtro a los tres motivos, pero **atar el revivir a un string es la causa raíz**. Lo correcto: columna `anulada_por_evento_id` → `contrato_suspensiones.id`, escrita tanto por el cliente como por el trigger. Puente inmediato y seguro: revivir toda cuota `anulada` del contrato con `monto_pagado = 0`, `tipo_cargo_manual IS NULL` y `periodo >= mesRNext` — en un contrato suspendido no puede ser otra cosa que un mes futuro anulado por la baja. Y agregar un INV al `invariantes_dinero.sql`, porque el hueco es invisible en la UI.

---

**#3 — La tabla de "triggers que corren solos" omite el que borra facturación en masa**

§4 de la guía de troubleshooting es lo que un humano o un AI consulta **antes** de escribir un fix por SQL contra producción, y su última entrada es de la época 0150. Desde entonces se agregaron 8 triggers a las tablas de dinero. El grave: `z_contratos_anular_cuotas_futuras` (0234) — un `UPDATE contratos.estado` a `'cancelado'` o `'suspendido'` dispara la **anulación masiva** de todas las cuotas pendientes sin pago posteriores a la fecha de baja. Alguien corrige el estado de un contrato creyendo que toca una columna y se lleva N cuotas por delante, en silencio. La ironía es que ARQUITECTURA sí lo documenta, pero al revés: avisa que la operación 0245 captura los ids *antes* de cancelar "porque el trigger 0234 anula las futuras".

Peor todavía, la propia receta **T1** de la guía ("Des-anular un PAGO anulado por error", :198-204) hace `update pagos set anulado=false`, lo que dispara `pagos_guard_sobrepago_update_trg` — y ese guard **no falla**: pone el pago en `en_revision = true` en silencio. Un pago en revisión no cuenta para `monto_pagado`, así que la cuota queda debiendo, la verificación da 0 violaciones y el operador se va convencido de que arregló el problema.

**Fix:** agregar las 8 filas faltantes con el mismo tratamiento de advertencia (⚠) que ya tiene `trg_contratos_limpiar_cuotas_excedentes`, empezando por 0234 con la instrucción "capturá los ids ANTES del UPDATE". Y agregarle a T1 la nota del guard de sobrepago con su SELECT de verificación.

---

**#4 — La verificación obligatoria de plata cubre 17 de 20 chequeos, y el que queda afuera tiene 7 violaciones**

La guía define su cierre no-negociable como "todas las filas (INV1-INV17) en violaciones = 0", en **cuatro lugares distintos**, e irónicamente el mismo renglón aclara "no hardcodees el conteo". Corrí el script yo mismo: emite **20** filas. INV18 (anulación sin actor), INV19 (cliente desactivado con deuda) e INV20 (`vencimiento_mas_viejo` divergente) quedan fuera del rango nombrado. **INV19 devuelve 7 hoy**: siete clientes desactivados que siguen debiendo C$29.018,53 que nadie va a cobrar porque ya no aparecen en ninguna ruta.

**Fix:** reemplazar las 4 ocurrencias por "TODAS las filas que emita el script (hoy INV1-INV20)" — que es lo que la propia línea :20 pedía — y agregar la línea de **baseline**, sin la cual "todo en cero" es inalcanzable y el operador aprende a ignorar el resultado: *"esperado hoy: INV11=3 e INV19=7 (preexistentes, ver BITÁCORA); cualquier otra fila ≠ 0, o estas dos por encima del baseline, es regresión de tu fix."* Actualizar también `ARQUITECTURA.md:1031` ("corre los 17 invariantes").

---

**#5 — La regla de oro del modelo de dinero se contradice con el invariante que dice sostener**

`ARQUITECTURA.md:1486` dice textual: «**Total de contrato FIJO** = `precio_mensual × duracion_meses` (NUNCA la suma de cuotas)». AGENTS #5 y la receta R22 —1.400 líneas más abajo, en el **mismo archivo**— dicen lo opuesto y marcan que fue REDEFINIDO el 2026-06-27 justamente para el cambio de plan. El código sigue a R22 y está bien (`contrato_detail_header.dart:247`, con el comentario explicando por qué).

El riesgo no es hoy, es la próxima sesión: §0 manda a §3.5 para "entender el modelo de dinero", y el encabezado de §3.5 dice «si una pantalla no cuadra con esto, la pantalla está mal, no el modelo». Un agente que aplique esa instrucción rompe el header del contrato — y pega justo donde más duele, porque verifiqué contra la base que `cobranza.cambio_plan_habilitado = true` en **los dos ISP reales**: tras un cambio de plan las cuotas se re-valúan y `precio × meses` queda descuadrado por diseño.

**Fix:** reemplazar el bullet :1486-1489 por la definición vigente (Σ cuotas vivas = recaudado + pendiente; `precio × meses` queda SOLO como discriminador fijo-vs-indefinido) con el link cruzado a R22 en el mismo bullet.

---

### MEDIA

| # | Sev | Área | Objeto | Qué está mal | A quién le pasa |
|---|-----|------|--------|--------------|-----------------|
| 6 | MEDIA | Contable | 6 contratos de Telenet, `contratos.cancelacion_deuda_snapshot` (lote B, `docs/cuadernos/telenet-ejecucion-2026-08-21.sql:104-116`) | El paso 3 armó el snapshot filtrando por `estado in ('pendiente','parcial')` y corrió **antes** de anular → el snapshot es la unión de condonado + vivo. El PDF "Estado de deuda" reclama como cobrables C$17.511 ya perdonados. **Fix: recalcular sobre las cuotas SOBREVIVIENTES** (280→8.974, 488→8.974, 00255→3.591, 0523→2.565, 487→7.692, 272→7.328) — NO sobre las anuladas, eso es el error opuesto y más grande. Y en el script, `not in (select cuota_id from _cuo)` | 5 clientes ACTIVOS de Telenet si les imprimen el estado de cuenta |
| 7 | MEDIA | Contable | `super_admin_baja_deuda_impl` (0245, **ya publicada en v0.36.0**) | Misma colisión semántica que #6, pero por diseño: arma el snapshot con las cuotas que **da de baja** y la card lo rotula «Deuda al cancelar (cobrable)». **Fix: decisión de producto — o el snapshot pasa a ser la deuda sobreviviente (como `cancelarContrato`), o cambia el wording de la card/PDF cuando el origen es una baja** | Cualquier tenant en el que el Dev use la operación |
| 8 | MEDIA | Contable | `recibo_screen.dart:90` y `:122` → `Fmt.mesServicio` | El mes de servicio del recibo se recalcula con el `dia_pago` **actual** del contrato. Cambiar la fecha de pago cruzando el límite del 14 re-etiqueta recibos ya impresos: **27 cuotas pagadas con recibo entregado en 6 contratos** de Mairena (GP0155 pasó de día 24 a día 2 → "Enero" reimprime "Diciembre"). Verifiqué que `cambio_fecha_habilitado = true` en ambos ISP. **Fix: snapshotear `dia_pago` en el pago/recibo al cobrar, como ya hace el PDF de suspensión** | El cliente con el recibo en la mano discutiendo qué mes pagó |
| 9 | MEDIA | Arquitectura | `arqueo_query.dart:44-52` (PDF `:815` y Excel `:1619`) | Arranca en `FROM cobradores cb` **sin filtro de tenant** — el mismo hueco que el audit sí cerró en su gemelo Eficiencia (2b7adf2). Verificado: `grep tenant_id arqueo_query.dart` → 0 hits. Su única barrera es el `HAVING COUNT(p.id) > 0`, que no tapa nada cuando hay residuo de `pagos`. **Fix: `cb.tenant_id = ?` + filtrar el subquery de `saldos_favor`; actualizar `dashboard_numeros_test.dart:429`** | El super_admin generando un cierre de caja dentro de la ventana de residuo tras saltar de empresa |
| 10 | MEDIA | Offline | `connector.dart:303` (`_subirRechazo`) | PowerSync manda en un PATCH **solo las columnas que cambiaron** y en un DELETE `opData` null → todo rechazo de patch/delete sube a `sync_rechazos` con `tenant_id` NULL, y `sync_rechazo_autorizado` solo lo muestra al super_admin. El comentario de 0246 documenta un caso que casi no puede ocurrir. **Fix: fallback al `tenant_id` de la fila local / de `cobradores` (con cuidado del super_admin impersonando), y extender `_esEspejoLocal` a `cuotas` antes, o la bandeja se llena de ruido** | Los caminos vivos hoy son cobrador editando fecha y admin con FK 23503; los graves están apagados por setting |
| 11 | MEDIA | Offline | `connector.dart:247-270` vs `:153` | `_registrarRechazo` es `void` y dispara los dos rastros con `unawaited`; después se ejecuta `await transaction.complete()`, que **borra la op para siempre**. Si el device muere en esa ventana, queda un recibo en papel y cero rastro. Es el incidente de Derling con la única red corriendo sin `await`. **Fix: `Future<void>` + `await Future.wait(pendientes)` antes del `complete()` (al menos la parte local, que no depende de red)** | El cobrador de campo en Android |
| 12 | MEDIA | Offline | `sync_ready_provider.dart:52` + `router.dart:290` | El sync gate se abre a los **8 segundos fijos**, sin mirar si el sync terminó. Impersonar Mairena son ~144.000 filas: el Dev entra al Dashboard y ve números de plata reales pero incompletos, sin más señal que un iconito. **Fix: para impersonación, liberar por progreso de descarga, no por tiempo — o banda persistente hasta el primer checkpoint** | El super_admin diagnosticando un tenant (flujo de primera clase desde 0243/0244) |
| 13 | MEDIA | Contable | `formatters.dart:151-165` (`periodoServicioRango`) → `cobro_screen.dart:1092`, `:1209` | Deriva la ventana del *mes anterior al vencimiento* en vez de anclarla a `periodo` + `dia_pago`. Cuando el corrimiento domingo→lunes cruza de mes, el rango colapsa a 1-3 días: **165 cuotas en 142 contratos**. **Fix: delegar en `ventanaServicio(periodo, diaPago)`, la única definición de ventana que debe existir** | El cobrador leyendo "Período de servicio: 28/02 a 01/03" mientras cobra un mes entero |
| 14 | MEDIA | Contable | `reporte_deuda_suspension_pdf.dart:46` | `contratos.cancelado_en` se guarda en UTC y el PDF lo formatea crudo; la pantalla sí hace `.toLocal()`. Toda cancelación entre 18:00 y 23:59 imprime el día siguiente: **8 contratos ya emitidos** (7 Telenet, 1 Mairena). **Fix: `-6 hours` antes de `fmtFechaCorta`; reimprimir alcanza** | El cliente con el documento de corte que no coincide con la app |
| 15 | MEDIA | Contable / permisos | `reportes_admin_screen.dart:465` + `ARQUITECTURA.md:906-909` | El "Reporte de cobranza" es el **único sin `soloAdmin`** y encima con `soloDetallado: false`: el `admin_cobranza` baja un Excel con `monto_cordobas`, `monto_original` y `vuelto` de todos los pagos. La doc afirma justo lo contrario en 2 de los 5. **Fix: decidir el gate (`soloAdmin: true` o sacarle las columnas de monto a ese rol) y corregir la lista de los 5 en ARQUITECTURA (es eficiencia, no cobranza)** | El rol cuyo principio declarado es "oculta recaudado, mantiene operativo" |
| 16 | MEDIA | Contable | `contratos_estado_check` en prod + `clientes_admin_screen.dart:1234` y `cobros_query.dart:312` | `'completado'` sigue permitido en el CHECK (el bloque (b2) de 0221 nunca se corrió) y hay pantallas donde su deuda **no cae en ninguno de los dos baldes** — ni "en ruta" ni "fuera de ruta". El Excel de la misma pantalla sí lo contempla. Hoy hay 0 filas. **Fix: correr el bloque (b2) — ya es seguro — y alinear los 3 consumidores a `<> 'activo'`** | Latente: una app vieja sincronizando `'completado'` |
| 17 | MEDIA | Doc | `AGENTS.md:37-40` y `MODULOS.md:536` | Documentan 7 de los 9 roles. Faltan `lectura` (el dueño del ISP mirando toda la plata sin escribir) y `coordinador` (el único limitado a nivel de **columna**). El CHECK de prod tiene los 9; PRODUCTO.md sí los lista → contradicción entre hermanos. **Fix: completar los 9, o mejor, que AGENTS y MODULOS apunten a la tabla de PRODUCTO.md:44-53 como fuente única** | El agente que escribe un gate nuevo "por descarte" — el bug exacto que ya mordió con `admin_cobranza` |
| 18 | MEDIA | Doc | `Guia de uso/GUIA-APP.md` :19, :169, :170, :218 y `MODULOS.md:171-172` | Dicen que el `admin_cobranza` suspende/cancela directo y que cambiar plan es "solo admin". Desde el 2026-08-09 los **solicita** (`aprobaciones_provider.dart:33-40`) y sí ve el cambio de plan. El rol decide el 55% de las bajas. **Fix: reescribir la regla real — ejecutan directo admin y super_admin; todos los demás SOLICITAN** | El admin_cobranza que no encuentra el botón y el admin que no sabe que le llega una cola |
| 19 | MEDIA | Arquitectura | `ARQUITECTURA.md:2285` (R4, paso 4) | La receta más usada manda a redeployar sync rules "en PowerSync Dashboard → Active". Ese Dashboard se retiró el 2026-07-13; §3.8 del mismo archivo lo dice 147 líneas más arriba. Saltear ese paso deja la columna nueva vacía en todos los dispositivos, **sin error**. **Fix: SSH al VPS + `docker compose restart powersync`; y el paso 1 a `supabase db query --linked`** | Cualquier agente siguiendo la cadena de integridad |
| 20 | MEDIA | Arquitectura | `ARQUITECTURA.md:236-246` (tabla de buckets) | Dice "los 11 reales" y hay **15**; faltan `todo_tenant_lectura`, `por_coordinador` y `mi_pin_dashboard`. Los números de línea están corridos hasta 154, y dos (`super_admin_self`, `impersonated_tenant`) apuntan **adentro de otro bucket**. **Fix: regenerar con `grep -nP '^\s{2}[a-z_]+:'` y borrar los números de línea, que rotan en cada edición** | R10 paso 3: una tabla nueva nace sin llegar al rol `lectura` → pantalla vacía sin error |
| 21 | MEDIA | Arquitectura | `ARQUITECTURA.md:1867-1943` (§3.6.1, "mapa EXHAUSTIVO") | 45 de 50 tablas. Faltan las dos protagonistas del fix cross-tenant de anteayer (`sync_rechazos`, `recibos_huecos_ignorados`), `recibo_correlativos` (numeración legal), `app_dispositivos` y `dashboard_pins`. Los conteos de RLS quedaron viejos (0198 agregó 38 policies después). **Fix: regenerar con las 3 queries que el propio bloque ya deja escritas + agregar el paso a R10** | R19 (borrado seguro) calcula cascades y snapshots contra un mapa incompleto |
| 22 | MEDIA | Arquitectura | `ARQUITECTURA.md:2195-2233` (§5, catálogo de settings) | Documenta 21-44 de las **98 claves** vivas. Entre las ausentes, los **3 gates de dinero**: `cambio_plan_habilitado` (R22), `cambio_fecha_habilitado` (R13), `credito_excedente` (R17) — más las 13 `notif_api_*` y las 7 `dashboard.*_visible`. **Fix: regenerar por prefijo desde `settings_repo.dart` marcando las compuertas, con la query de verificación al pie** | "No me aparece el botón de cambiar el plan" no tiene dónde mandar a mirar |
| 23 | MEDIA | Doc | `AGENTS.md:277` (Fase 5) + §Git/branching | Exige declarar "Build esperado: la versión de `pubspec.yaml`". Por política el bump se hace en la rama de release: main dice **0.34.2+256** y en la calle corre **0.36.0+260**. La regla anti-bug-fantasma, aplicada literal, produce el número equivocado. **Fix: cambiar la fuente al último tag publicado / al `version` del manifest, y escribir la política de versionado en Git/branching** | El GATE de build fresco, que existe por el incidente del 2026-06-17 |

### BAJA

| # | Sev | Área | Objeto | Qué está mal | A quién le pasa |
|---|-----|------|--------|--------------|-----------------|
| 24 | BAJA | Cuotas | `pagos_repo.dart:~618` (`registrarCobroMultiple`) | No tiene el tope contra el saldo vivo que sí tiene `registrarCobro` (`:357-366`). Hoy es inalcanzable: verifiqué `cobranza.pago_adelantado = false` en los 3 ISP y 0 de 31.813 pagos tienen `grupo_cobro`. **Pero el seed de tenants nuevos lo crea en `true`.** Fix: extraer el tope a un helper y llamarlo en el loop (4 líneas), antes de onboardear otro ISP | Latente — se activa con un toggle o con un tenant nuevo |
| 25 | BAJA | Regresión | `dashboard_providers.dart` en `v0.36.0` vs `main` | El filtro de empresa del ranking **no viajó** (verificado: 0 hits de `tenant_id` en el tag, 2 en main) pero BITÁCORA lo lista dentro de "App (viaja en v0.36.0)". No es regresión (v0.35.2 tampoco lo tenía) y la fila ajena es "Ruben Maltez", no "System Admin". Fix: corregir la línea de BITÁCORA; el código se cura solo en el bump ≥0.37.0 | Solo el super_admin, en su propio device |
| 26 | BAJA | Arquitectura | `ticket_detail_screen.dart:1478` | El selector de técnico de la **reasignación** quedó sin `AND tenant_id = ?`; su gemelo del alta sí se arregló. Hoy lo tapa el `bloqueadoPorImpersonacion` de la línea :1476. Fix: una línea, para no depender de que el guard siga ahí | Latente |
| 27 | BAJA | Contable | `super_admin_corregir_invariantes` (0217) | Última función viva de dinero con el predicado VIEJO (`anulado=false` sin `en_revision`). El trigger 0216 pisa lo que escribe y el botón ni se renderiza hoy (los 4 auto-fixeables en 0). Fix: `CREATE OR REPLACE` partiendo de la def vigente, agregando `AND p.en_revision = false` en las 2 apariciones | Nadie hoy; es footgun si alguien copia ese UPDATE |
| 28 | BAJA | Contable | `super_admin_corregir_invariantes`, bloque INV17 | Usa `periodo >= date_trunc('month', CURRENT_DATE)` mientras el invariante usa `>` + el ancla del último período pagado → el panel puede decir "0 corregidas" con la violación en rojo. Fix: copiar el predicado del invariante, o que el corrector consuma el verificador | El dueño apretando "Corregir" sin que pase nada |
| 29 | BAJA | Contable | `reporte_eficiencia_pdf.dart:72`, `:139` + `reportes_admin_screen.dart:1528` | La columna dice "Total recaudado (C$)" y muestra **cartera asignada** (decisión de producto documentada). C$53.152 donde entraron C$3.624.427. Invisible hoy: `reportes_detallados = false` en los 3 ISP (verificado). Fix: renombrar a "Cobrado de su cartera (C$)" en los **tres** puntos — no tocar la query | Latente; hoy solo el super_admin con el toggle prendido |
| 30 | BAJA | Contable | `reportes_admin_screen.dart:1669-1683` | "Recaudación últimos 6 meses" filtra por `fecha_pago` y agrupa por `fecha_vencimiento`: 21 barras, 11 de meses futuros. Apagada por el mismo toggle. Fix: agrupar por `strftime('%Y-%m', pagos.fecha_pago)` **+ techo superior** (el pago histórico del Dev puede adelantar fechas); y anclarla al tenant en el mismo commit — es la única tarjeta de Reportes sin filtro | Latente |
| 31 | BAJA | Contable | `contrato_providers.dart:163` | El hint "ajustado (meses anulados)" cuenta cargos manuales como meses, así que se apaga justo cuando debería avisar. INV11 y el panel sí los excluyen. Fix: `AND tipo_cargo_manual IS NULL` en el COUNT de `vivas` | Impacto nulo hoy (2 cuotas manuales, ambas en Test) |
| 32 | BAJA | Contable | `mis_cobros_screen.dart:78-95` vs `arqueo_query.dart:22-31` | El desglose por método del cobrador usa `monto_cordobas` y el del arqueo `monto_original`; y el pill "USD" formatea córdobas. Fix: alinear a las expresiones del arqueo y renombrar a "US$" con `Fmt.dolares` | Dormido: 0 pagos con vuelto, 0 en USD en toda la base |
| 33 | BAJA | Contable | `centro_cobranza_providers.dart:78-105` | La lista de créditos hace `JOIN clientes` y la métrica no → universos distintos. Fix: `LEFT JOIN` + `COALESCE(cl.nombre, '(no sincronizado)')` | Hoy coinciden; es la otra mitad del fix del LIMIT 50 |
| 34 | BAJA | Contable | Cobertura de `invariantes_dinero.sql` | Cuatro huecos: no hay INV de **oldest-first** (#11, el único sin trigger server), ni de **devoluciones** de `saldos_favor` (el segundo sumando de #4), INV5 es unidireccional (no chequea recibo vivo → pago vivo), e INV2 excluye anuladas mientras INV12 recorre contratos → una cuota manual anulada (`contrato_id` NULL) con pago vivo no la mira nadie. Fix: 4 chequeos de ~10 líneas cada uno | Preventivo: hoy los 4 dan 0 |
| 35 | BAJA | Contable | `contratos` (sin CHECK de atribución) | Cancelar es el evento que más plata mueve de un saque (dispara 0234) y es el único sin CHECK de actor/fecha/motivo: **94 de 189 cancelaciones sin `cancelado_por`**, 37 sin fecha ni motivo. `pagos` y `cuotas` sí lo fuerzan. Fix: CHECK espejo `NOT VALID` + invariante para las nuevas | "¿Quién dio de baja esto?" sin respuesta en la mitad de los casos |
| 36 | BAJA | Offline | `cola_atascada_banner.dart:40` | `_desde` vive en memoria: cada apertura de la app reinicia el reloj de 30 min, así que en Android (sesiones cortas) el aviso puede no dispararse nunca aunque haya 40 cobros sin subir hace días. Fix: persistir en SharedPreferences (~10 líneas), como ya hacen `CorrelativoStore` y `RechazosSyncService` | El cobrador de campo — justo donde más importa |
| 37 | BAJA | Contable | `0241_colchon_cobrador_policy.sql:70-76` (§2) | El bloque de reposición arma el vencimiento inline sin el corrimiento domingo→lunes. Los dos caminos vivos (cron y colchón) sí usan el canónico. 21 cuotas afectadas, todas en Test Tenant. Fix: usar `public.calcular_fecha_pago(...)` en cualquier re-ejecución o migración derivada | Test Tenant hoy |
| 38 | BAJA | Offline | `connector.dart:110-128`, `:348-390` | El reintento de correlativo quedó muerto desde 0215 (el server asigna el número desde un contador atómico e ignora el del device) y su comentario explica algo que ya no ocurre — el mismo tipo de comentario desactualizado que 0215 señala como causa raíz. Fix: borrarlo y reescribir el comentario | Mantenimiento |
| 39 | BAJA | Offline | `pagos_repo.dart` (cobro) vs `trg_resolver_notificacion_al_pagar` | El cliente no espeja el trigger que resuelve la notificación de mora al pagar; `cancelarContrato` sí. El badge rojo sigue contando la cuota recién cobrada offline. Fix: UPDATE a `notificaciones_mora` en el mismo `writeTransaction` — verificando antes la policy del cobrador | El cobrador que cierra el día con el badge en 5 y las 5 ya cobradas |
| 40 | BAJA | Doc | `AGENTS.md:190` y `CHANGELOG-REWORK.md:245`, `:290` | Documentan `op_log.actor` (no existe; es `actor_id`/`actor_label`) y `diff jsonb` (es TEXT desde 0129). **Ya hizo fallar el SQL de Telenet** — la lección se anotó en la bitácora y nunca volvió a los documentos que la causaron. Además el bloque RLS de :255-258 muestra el patrón `OR is_super_admin()` que AGENTS §1 prohibió tras 0246. Fix: corregir los tres | La próxima sesión de SQL sobre producción |
| 41 | BAJA | Doc | `ARQUITECTURA.md:1107` | Dice que `/super/diagnostico` lee `recibos_huecos()`; desde 0246 lee `recibos_huecos_todos()`. Apuntarlo de vuelta a la anclada produce el "falso todo-en-orden" que 0246 advierte en su encabezado. Fix: corregir la ficha y agregar 0247 (0 menciones en ARQUITECTURA) | El Dev dejando de ver los huecos de talonario sin enterarse |
| 42 | BAJA | Doc | `GUIA-APP.md:60`, `:61`, `:106` | 2 enlaces muertos de 33 (ficha de equipo, orden de corte) a features que **sí existen**; y dice que el admin_cobranza desactiva clientes cuando el gate es `admin` + `admin_usuarios`. Fix: escribir las 2 secciones o borrar las filas; partir la fila de Clientes | El personal del ISP que deja de confiar en el manual |
| 43 | BAJA | Doc | `AGENTS.md:24` (fila 8b) | Manda a regenerar la guía con `mockups_guia.py`, que **solo escribe SVG** — el texto de GUIA-APP.md se edita a mano y la instrucción no lo dice. Es la causa mecánica de #18 y #42. Fix: agregar "Y actualizar a mano el texto" con la lista de tablas, y corregir la ruta de invocación | Cualquier corrección de la guía se vuelve a desincronizar |
| 44 | BAJA | Doc | `MODULOS.md:1298`, `:1300`, `:1028-1070`; `ARQUITECTURA.md:972-975`, `:520`, `:248-263`, `:2414`, `:2871`; `AGENTS.md:28`; `PRODUCTO.md:145` | Ristra de conteos y referencias vencidas: "Edge Functions (6)" y hay 9 (falta `ver-password-cobrador`, la que devuelve la contraseña en claro, 0 menciones en todo el repo doc) · `clientes_list_screen.dart` borrado y citado en 2 archivos · §2 documenta 7 roles y el router maneja 9 · R11 dice "14 tests" y hay 92 · R21 cita `/admin/inventario-v2`, que no existe · "recetas R1-R18" y son 22 · "las 10 invariantes" y son 11 · `app_dispositivos` + `dispositivo_service` con 0 menciones · MODULOS no registra `/super/diagnostico` ni sus 3 ops de dinero · MODULOS afirma que Eficiencia filtra por `fecha_pago` y agrupa por `pagos.cobrador_id` (hace lo contrario, a propósito). Fix: ver §LA DOCUMENTACIÓN | Minutos perdidos por sesión y falsa confianza |
| 45 | BAJA | Doc | `BITACORA.md:5078-5150` (§Backlog vivo) | Lista como PENDIENTES 4 findings ya resueltos (#1 en 0224, #3 en el connector, #5 en `contrato_detail_header`, #7 en `solicitudes_screen`) — la misma BITÁCORA los da por cerrados 4.400 líneas más arriba. El #1 se "arregla" con un `CREATE OR REPLACE` acumulativo, que es la clase de reescritura que ya rompió cosas en silencio (0151/0152). Fix: mover a un bloque "RESUELTO — no re-flagear" con su commit; tachar en el mismo commit que arregla | La primera página que lee toda sesión nueva |
| 46 | BAJA | Doc / datos | `contratos.fecha_primer_cobro` | Data muerta desde 0074 (no la lee nadie) y **desalineada en 765 de 5.665 contratos**. Parece autoridad y no lo es. Fix: retirarla, o mantenerla con trigger; mínimo un `COMMENT ON COLUMN` + una línea en la guía de troubleshooting | Quien arregle data por SQL creyéndole |
| 47 | BAJA | Doc | `AGENTS.md` invariantes #5 vs #9 | #9 dice que los cargos manuales no cuentan para el total fijo; #5 redefinido incluye `cargos_neto` en Σ cuotas vivas. El código sigue a #5. Fix: reescribir #9 para que hable de **cuotas manuales** (`contrato_id` NULL, que sí quedan fuera) y separarlo de los `cargos_extra` de la cuota | Un audit futuro marcando como bug lo correcto |

---

## DESCARTADOS EN LA REFUTACIÓN

Esto importa tanto como los hallazgos: si no queda escrito, se vuelve a levantar el sprint que viene.

**1. "Cola futura viva en el contrato 4157 (FR0029), C$7.692 que se van a seguir cobrando" — FALSO POSITIVO, y el fix era destructivo.** Los datos eran exactos pero la lectura estaba invertida. El `op_log` a nivel CONTRATO de la misma transacción del 19/08 dice `{"lote":"B","motivo":"Cuaderno de decisiones de Mairena 08/2026 - Reactivar cliente"}`. La decisión del ISP fue **reactivar**, no dar de baja: se perdona el período sin servicio y el cliente vuelve, por eso el contrato sigue activo y las 6 cuotas futuras son facturación legítima. No es un outlier: hay **12 contratos "Reactivar cliente"** en ese lote, todos en el mismo estado por diseño. Aplicar el fix habría borrado C$7.692 reales y, aplicado "como regla al recetario", otros ~C$27.000. Además BITÁCORA ya nombra este contrato: *"INV11=3 ACEPTADA: los fijos reactivados (CT0035/FR0029/PG0169)"*. **La regla vigente es correcta: si el contrato se CANCELA, el trigger barre la cola futura solo; si el cliente se REACTIVA, la cola futura se conserva a propósito.**

**2. "El corrector de invariantes usa el predicado viejo" — de MEDIA a BAJA.** El mecanismo es real (es la última función viva de dinero sin `en_revision`), pero el daño contable es **estructuralmente imposible**: `cuotas_forzar_derivados_trg` es BEFORE UPDATE sin cláusula WHEN y pisa lo que el corrector escribe. Y el síntoma descrito ("apretás Corregir y ves INV2: 2 corregidas, siempre") **no es reproducible**: el botón está detrás de `_hayAutoFixeables`, y los 4 auto-fixeables dan 0 en los 4 tenants. Vale el fix como higiene, no como incidente.

**3. "Eficiencia por cobrador muestra el 1,5% de la plata" (ALTA) — a BAJA.** Los números eran exactos y el reporte es **inalcanzable**: `soloDetallado` hereda `true` y `cobranza.reportes_detallados = false` en los tres tenants (lo verifiqué yo), con `editable_por='super_admin'`. Además la semántica "cartera asignada" es **decisión de producto documentada en el propio código** (`reportes_admin_screen.dart:1801-1803`, audit 2026-06-30). El bug real es la **etiqueta**, no el número — y el fix (b) propuesto (sacar el filtro de rol y agregar recaudado real) contradice esa decisión y es cambio de producto, no bug fix.

**4. "Recaudación últimos 6 meses: 21 barras" (ALTA) — a BAJA.** Mismo gate apagado. Defecto latente, no plata mal mostrada hoy.

**5. "Multi-cuota sin tope de saldo vivo" (ALTA) — a BAJA.** `cobranza.pago_adelantado = false` en los 3 ISP (verificado) y **0 de 31.813 pagos tienen `grupo_cobro`**: `registrarCobroMultiple` nunca se ejecutó en producción. El escenario descrito no lo puede vivir nadie hoy. Queda como deuda a pagar antes del próximo onboarding, porque el seed nace en `true`.

**6. "Rechazos de PATCH/DELETE con tenant NULL" (ALTA) — a MEDIA.** La premisa central era falsa: **un COBRO es siempre un `put`, y el `put` lleva `tenant_id`** → ningún cobro cae en la bolsa huérfana. El modo de falla de Derling sigue cubierto al 100%. Y "el cobrador anula un pago" no es alcanzable: `cobrador_anula_cobros` y `cobrador_edita_cobros` están en `false` en los 4 tenants. Lo que queda es real igual: un bucket no intencional y una doc que describe un caso imposible.

**7. "El snapshot del lote B reclama C$17.511 perdonados" (ALTA) — a MEDIA, y el fix estaba invertido.** La plata **no es cobrable por ninguna vía** (las cuotas están anuladas: no salen en Cobros, ni en el mapa, ni en oldest-first) y **no hay doble conteo**: `cancelacion_deuda_snapshot` se lee en 3 lugares, todos dentro del detalle del contrato — ningún reporte ni agregado de cartera la toca. Además, antes del 21/08 esos 6 tenían el snapshot NULL y la misma card decía "C$0,00", escondiendo C$39.124 de deuda real. Lo importante: **el fix propuesto (restringir a las cuotas anuladas) es el error opuesto y más grande** — dejaría la card diciendo "cobrable: C$2.564" sobre el monto condonado y borraría los C$39.124 vivos. El correcto es la deuda **sobreviviente**.

**8. "El filtro del ranking del dashboard no viajó" — a BAJA, y no es regresión.** Verificado: 0 hits de `tenant_id` en el tag, 2 en main. Pero **v0.35.2 tampoco lo tenía**: nunca viajó en ninguna versión, así que nada empeoró. La fila ajena se llama **"Ruben Maltez"**, no "System Admin" (que es un cobrador legítimo de Mairena y de Telenet — BITÁCORA ya advierte de esa confusión). Y con datos reales, en Mairena queda **6º** con `LIMIT 5`: ni aparece. Publicar un release entero para eso no cierra; se cura solo en el bump ≥0.37.0. Lo que sí queda es la línea de BITÁCORA que miente.

**9. Sobre el prorrateo (#1): la refutación lo confirmó y lo bajó a ALTA. Yo lo devuelvo a CRÍTICA, y digo por qué.** Los argumentos del refutador para bajarlo son buenos (daño realizado C$16,55, población 16 cuotas, magnitud acotada por el mes live, todo trazable en op_log). Los desestimo por tres razones que su propia evidencia sostiene: (a) es el **único** punto del sistema donde la app escribe un monto de plata equivocado por decisión propia, con la vista previa cómplice — no hay control humano posible; (b) el vector no está estable en 16, **crece con trabajo normal de admin**: cada cambio de plan acuña un contrato expuesto (y está ON en los dos ISP, usándose hoy) y editar el precio de un plan desalinea de golpe todos sus contratos, sin ningún gate; (c) "Suspender los N" del Centro de cobranza puede barrer toda la cola expuesta en un clic, en silencio. La severidad es por mecanismo y trayectoria, no por el acumulado.

**10. Sobre reactivar/0234 (#2): confirmado y AMPLIADO.** El lente lo declaró latente; la refutación encontró el tercer motivo (`reparación 0234`) y el contrato **MV0167 de Telenet ya armado**. El fix propuesto por el lente, tal como estaba escrito, **no cubre el único caso materializado**.

---

## EL MODELO CONTABLE: ¿CIERRA?

**SÍ. Cierra, y cierra al centavo.** Lo digo tajante porque lo verifiqué con números, no de lectura.

**Los invariantes.** Corrí `supabase/tests/invariantes_dinero.sql` completo contra producción (verifiqué antes que no contiene una sola sentencia de escritura: `grep -icE "insert|update|delete|alter|drop|create"` → **0**). Emite 20 filas: **18 en cero**. Las 2 que no son exactamente las que BITÁCORA ya declara y cuantifica: **INV11 = 3** (CT0035, PG0169 y FR0029 de Mairena — los tres fijos *reactivados* con meses anulados por la limpieza, aceptados por decisión) e **INV19 = 7** (C$29.018,53 de clientes desactivados con deuda, 6 de Telenet + SM2095 de Mairena, todos anteriores al guard 0220). **Ninguna violación nueva.** Y el RPC del panel (`super_admin_verificar_invariantes`, la copia que ARQUITECTURA advierte que puede derivar) da exactamente lo mismo: hoy no derivó.

**La consistencia cross-pantalla (#10).** Las 6 variantes de fórmula de saldo que existen en el código dan **idéntico** sobre clientes complejos reales (con crédito, con cuota parcial + cargo manual, con descuento + reconexión): C$2.565,00 / C$3.300,00 / C$2.700,00 en las seis, desvío **C$0,00**. La deuda del tenant cierra por tres cortes distintos: Mairena lista en-ruta 19.186.978,00 + fuera-de-ruta 47.469,55 = **19.234.447,55** = dashboard por-cobrar 19.228.467,38 + suspendido 5.980,17 = total pendiente/parcial. La única diferencia (C$2.837,50 contra el reporte "Estado de clientes") es exactamente la deuda de clientes inactivos, que ese reporte excluye a propósito.

**Los derivados.** Sobre las **57.003 cuotas** de las tres empresas: **0** con `cargos_neto` distinto de `calcular_cargos_neto(id)`, **0** con `monto_pagado` distinto de `SUM(pagos vivos)`, **0** con el `estado` fuera de la fórmula canónica, **0** sobre-cubiertas. Σ`cuotas.monto_pagado` == Σ`pagos` vivos al centavo: Mairena **C$22.173.869,78**, Telenet **C$5.360.663,36**. El invariante #7 (lo mantiene el trigger, el cliente solo espeja) se cumple al 100%, y está enforzado, no confiado: `cuotas_forzar_derivados_trg` es BEFORE UPDATE **sin cláusula WHEN**, así que el espejo del cliente nunca puede pisar la verdad del server.

**El invariante #5 redefinido (R22).** `recaudado + cobrable` == `Σ (monto + cargos_neto)` de las cuotas vivas en los **5.680 contratos**, diferencia máxima **0,00**. Y ningún camino puede anular una cuota con plata encima: lo verifiqué en los 4 (suspensión de la app, trigger 0234, `super_admin_cuota_estado_impl`, `super_admin_baja_deuda_impl`) → **0 cuotas anuladas con pagos vivos**, y las 1.106 anuladas tienen `monto_pagado = 0`.

**Bruto vs neto (#4).** Es como dice AGENTS. El álgebra de `ArqueoCalculo.equivalenteTotalC` se reduce a `ingresoTotal − devoluciones` si y solo si el efectivo NIO cumple el invariante #3 con tasa 1 — que se cumple. Los buckets del arqueo cubren el dominio **completo** de `pagos.metodo` (el CHECK admite exactamente los 4 que suma), así que no hay plata que caiga fuera. Caja del ciclo en curso: Mairena **C$1.129.843,74** (1.291 cobros), Telenet **C$392.008,00** (407) — el mismo número por el arqueo y por el KPI del dashboard, y julio de Mairena da **C$3.624.427,43** por los dos caminos, con la suma por rol cerrando exacto.

**El crédito a favor.** No toca `pagos`, tal como dice la doc: `SUM(cargos_extra tipo='credito_aplicado')` = **0,00** = `SUM(saldos_favor tipo='aplicado')`. El libro cierra: 12 clientes, **0 con disponible negativo**, C$739,28 vivos. El espejo cliente de `cargos_neto` es byte a byte la misma lógica que el server, y el CHECK de `cargos_extra.tipo` admite exactamente los 5 tipos que ambos lados saben sumar: no hay tipo huérfano que uno cuente y el otro ignore.

**La moneda: cumple perfecto, pero SIN COBERTURA REAL.** Los 31.813 pagos cumplen `monto_original × tasa = monto_cordobas + vuelto_cordobas` con desvío **0,0000**. Pero eso es porque son **todos NIO, efectivo, con vuelto 0**: no hay ni un pago en USD ni uno con vuelto en toda la base. La matemática de `cobro_calculo.dart` (el vuelto se imputa al último pago y `monto_original` se deriva, así que el invariante se cumple por construcción) está bien leída, pero **nunca se probó en la vida real**. Es el único ángulo del modelo contable donde mi "SÍ" es por código y no por datos, y conviene decirlo en voz alta.

**El único descuadre real del período** es #1: la app puede escribir un `cuotas.monto` que no corresponde a ningún servicio prestado. No rompe ningún invariante (INV4 mira sobrepago, no sobre-facturación) y por eso ninguna red lo atrapó. Es exactamente el tipo de error que los invariantes no cubren: la aritmética cierra, el supuesto está mal.

---

## EL CICLO OFFLINE: ¿ES PRECISO?

**SÍ, con una salvedad real y dos huecos de observabilidad.**

**Paridad cliente/servidor: exacta en los que importan.** Se enumeraron los 41 triggers con lógica de negocio sobre las tablas de dinero y se comparó cada uno contra su espejo Dart. `calcularEstadoCuota` reproduce literalmente `recalcular_cuota_desde_pagos` (incluidos el clamp a 0, la condonación con total ≤ 0 y la comparación en centavos enteros para no desalinearse del `numeric(10,2)`). `_deltaCargosExtra` es idéntico a `calcular_cargos_neto`. `recalcVmvDeContrato` reproduce `recalc_vencimiento_mas_viejo` con el mismo `COALESCE(estado,'activo')='activo'`. `calcularFechaPago` == `calcular_fecha_pago`, clamp de fin de mes **y** corrimiento domingo→lunes. Los 39 triggers relevantes están con `tgenabled='O'`: ninguno deshabilitado.

**"Server gana" está enforzado.** Verificado arriba: `cuotas_forzar_derivados` sin WHEN. Y los 4 lugares donde el cliente inserta cuotas escriben `monto_pagado = 0` literal. Ningún camino de la app borra pagos ni cuotas.

**La cola resiste el reintento.** `esCodigoNoRetryable` es **allowlist** (23xxx/42xxx/22xxx/P0001, exigiendo 5 caracteres para que un '429' HTTP no matchee): ante la duda preserva el dato en vez de descartarlo. El re-upload de un batch fallido a mitad es idempotente donde importa: `pagos_guard_sobrepago_trg` excluye `p.id <> new.id` y `recibos_asignar_correlativo` (0220) devuelve el correlativo ya guardado si la fila existe — **un reintento no renumera un recibo impreso ni duplica el conteo de sobrepago**. El camino RLS0 desambigua con `_filaSigueVisible` en vez de comparar valores entre dos sistemas de tipos, que es la decisión correcta. Y `_espejosLocales` evita ~1.900 falsos positivos mensuales.

**Los 4 escenarios de conflicto: cubiertos.** (a) Mismo cobro en oficina y calle → el guard 0218/0240 auto-anula el gemelo exacto y deja rastro en op_log; el no-exacto va a cuarentena y sale de toda métrica. (b) Dos devices sobre la misma cuota → mismo camino, y el correlativo ya no colisiona porque lo asigna el server. (c) Cobro offline sobre cuota anulada en el server → 0 casos, y `cuotas_anular_pagos_asociados_trg` lo mantiene en cero. (d) Contrato cancelado en el medio → la red 0234 cierra la carrera. La bandeja online de rechazos preserva el número impreso si sigue libre.

**Datos que respaldan la precisión:** 0 pagos vivos sobre cuota anulada, 0 pagos vivos sin recibo, 0 recibos vivos colgando de un pago anulado sobre **879 anulaciones**, 0 recibos huérfanos, 0 pagos con más de un recibo vivo, 0 correlativos duplicados, 0 pagos con fecha futura, 0 `vencimiento_mas_viejo` desalineado en **6.097 clientes**.

**El reloj de la flota está en hora** — esto era el riesgo silencioso y se midió: comparando `ocurrido_en` (UTC) contra `fecha_pago` (local-naive) sobre 120 días y 5.000+ pagos, **todos** los cobradores de los dos ISP dan 6,00-6,08 h. Ni un equipo con la zona horaria mal, que es lo que corrompería el bucketing por día del arqueo sin dejar rastro.

**La salvedad real:** #11 — el rastro de un cobro rechazado se escribe con `unawaited` mientras `transaction.complete()` borra la op de forma irreversible. Es la única red contra el incidente de Derling y corre en carrera con el borrado. Son 6 líneas y convierte "probablemente quedó el rastro" en "el rastro quedó o la op no se descarta".

**Los dos huecos de observabilidad:** #10 (los rechazos de PATCH/DELETE nacen sin dueño → el admin del ISP no los ve) y #36 (el banner de cola atascada reinicia su reloj en cada apertura, o sea que en Android puede no dispararse nunca). Ninguno de los dos pierde plata; los dos hacen que un problema tarde más en aparecer.

**Lo que sigue siendo límite aceptado y no hay que re-flagear:** correlativo en 2 devices offline, oldest-first multi-device sin sincronizar (medido: **0 violaciones en Mairena y 0 en Telenet** — el guard del cliente está funcionando aunque no haya trigger server), contrato creado offline sin cuotas, y el residuo al saltar entre empresas grandes.

---

## LA DOCUMENTACIÓN: ¿DICE LA VERDAD?

Parcialmente. La doc está **bien mantenida en el corazón** (§3.5 tabla de caminos de plata: verifiqué sus 13 referencias `archivo:línea` una por una y dan en el clavo; §3.9 rol lectura: "38 policies `lectura_select`" da 38 exacto; §3.10 PIN: correcta) y **envejecida en los índices y catálogos**, que es justo donde un agente entra. El patrón es sistemático: todo lo que tiene un **número hardcodeado** se desincronizó.

### `Troubleshooting SQL/GUIA-TROUBLESHOOTING-SQL.md` — lo primero, es la guía que se usa contra producción
- §4: agregar las 8 filas de triggers faltantes, empezando por `z_contratos_anular_cuotas_futuras` (0234) con marca ⚠ (**#3**).
- Receta T1: nota de que el `UPDATE` dispara el guard de sobrepago 0214/0218, que no falla sino que deja el pago `en_revision` (invisible para `monto_pagado`), con su SELECT de verificación (**#3**).
- :20, :89, :217, :338: "INV1-INV17" → "todas las filas que emita el script" **+ el baseline INV11=3 / INV19=7** (**#4**).
- Agregar una línea sobre `contratos.fecha_primer_cobro`: no es autoridad y está desalineada en 765 contratos (**#46**).

### `ARQUITECTURA.md`
- :1486 (§3.5-3): Total de contrato fijo = Σ cuotas vivas, con link a R22 (**#5**).
- :2285 (R4 paso 4): sync rules por SSH al VPS, no PowerSync Dashboard; y paso 1 a `supabase db query --linked` (**#19**).
- :2486-2492 (R13): borrar la nota que manda a `mesServicioLabelDeVencimiento`/`periodoReciboDeVencimiento` — **eliminadas el 2026-08-01** — y escribir la consecuencia real: el rótulo se ancla al `dia_pago` vivo, así que reimprimir un recibo anterior a un cambio de fecha puede mostrar otro mes (**#8**).
- :236-246: regenerar la tabla de buckets (15, no 11) y **borrar los números de línea** (**#20**).
- :1867-1943 (§3.6.1): regenerar el mapa (50 tablas) + agregar el paso a R10 (**#21**).
- :2195-2233 (§5): regenerar el catálogo de settings marcando las compuertas de feature (**#22**).
- :906-909: la lista de los 5 `soloAdmin` es cobros/por_cobrador/arqueo/fiscal/**eficiencia**; aclarar dónde queda 'cobranza' (**#15**).
- :1107: `/super/diagnostico` lee `recibos_huecos_todos()`; agregar 0247 (0 menciones hoy) (**#41**).
- :972-975: son 9 Edge Functions, no 6; sumar `ver-password-cobrador` con quién puede llamarla (**#44**).
- :520 y :248-263 y :2414 y :2871: lista única de clientes (no existe `clientes_list_screen.dart`); 9 roles en el router; sacar el "14 tests"; rutas definitivas de inventario (**#44**).
- Agregar `app_dispositivos` + `DispositivoService` a §1, §3.6.1 y §0 — es la telemetría de versiones de la flota y responde a ciegas la pregunta del GATE de build fresco (**#44**).

### `AGENTS.md`
- :37-40: los 9 roles, marcando `lectura` y `coordinador` — o apuntar a PRODUCTO.md:44-53 como fuente única (**#17**).
- :190: `actor_id`/`actor_label`, no `actor` (**#40**).
- :277 (Fase 5): "Build esperado" = último tag publicado, no `pubspec.yaml`; y escribir la política de versionado en §Git/branching (**#23**).
- :24 (fila 8b): el generador **solo** produce los SVG; el texto de GUIA-APP.md se edita a mano (**#43**).
- :28: "recetas R1-R22" (o mejor, "el índice R* de §0") (**#44**).
- Invariante #9: reescribirlo para que hable de cuotas manuales, no de `cargos_extra` (**#47**).

### `CHANGELOG-REWORK.md`
- :245: `diff text NOT NULL` con la nota del `::text`; :290: `actor_id`/`actor_label`; :255-258: corregir el bloque RLS, que todavía muestra el patrón `OR is_super_admin()` que AGENTS §1 prohibió tras 0246 (**#40**).

### `Guia de uso/GUIA-APP.md`
- :19, :169, :170, :218: el gating real de suspender/reactivar/cancelar y de cambiar plan (**#18**).
- :106: partir la fila de Clientes (desactivar = admin + admin_usuarios, bloqueado con contratos activos) (**#42**).
- :60, :61: escribir las dos secciones o borrar las filas (**#42**).

### `MODULOS.md`
- :171-172 (gating de ciclo de contrato) (**#18**), :536 (roles ofrecidos) (**#17**), :1298 y :1300 (Eficiencia **no** filtra por `fecha_pago` ni agrupa por `pagos.cobrador_id`) (**#44**), :126 (`clientes_list_screen.dart` no existe) y :1028-1070 (agregar `/super/diagnostico` y sus 3 operaciones de dinero) (**#44**).

### `PRODUCTO.md`
- :145: "las **11** invariantes", y aclarar que los 20 chequeos `INVn` son la **verificación** de esas 11 reglas — hoy conviven tres números (10, 11, 20) sin que ningún documento explique la relación (**#44**).

### `BITACORA.md`
- Sacar "ranking del dashboard" de "App (viaja en v0.36.0)" (**#25**).
- Mover los 4 findings ya resueltos del §Backlog vivo a un bloque "RESUELTO" con su commit (**#45**).

---

## LO QUE ESTÁ SANO (y conviene no romper)

| Área | Qué se verificó | Números |
|---|---|---|
| **Invariantes de dinero** | Los 20 del archivo canónico, corridos contra prod | **18 en cero**; INV11=3 e INV19=7, los 2 preexistentes declarados. El RPC del panel da lo mismo que el .sql: no derivó |
| **Derivados de cuota** | `cargos_neto`, `monto_pagado` y `estado` contra su fuente | **0 desalineados** sobre 57.003 cuotas. Σ`monto_pagado` == Σ`pagos` vivos al centavo |
| **Total de contrato (#5)** | `recaudado + cobrable` == Σ cuotas vivas | **5.680 contratos**, diferencia máxima 0,00 |
| **Consistencia cross-pantalla (#10)** | Las 6 variantes de fórmula de saldo sobre clientes complejos | Desvío **C$0,00** en las seis |
| **`vencimiento_mas_viejo`** | Recalculado con el criterio del trigger 0150 | **0 desalineados en 6.097 clientes**, después de las 70 anulaciones de ayer |
| **Integridad recibo↔pago** | Sobre 879 anulaciones (862 individuales + 14 del guard 0214) | 0 recibos vivos sobre pago anulado, 0 huérfanos, 0 pagos con 2 recibos, 0 correlativos duplicados |
| **Generación de cuotas** | Huérfanas, duplicadas, monto ≤ 0, colchón, fuera de `fecha_fin` | **0 en todo**. 5.126 indefinidos activos, **0 sin colchón**. 0 fijos activos con conteo ≠ `duracion_meses` |
| **Cron** | `generar_cuotas_mensual` + mora + tickets + whatsapp | **20 de 20** corridas verdes en 20 días, 3 s la más lenta |
| **Anclaje al `dia_pago` (#1c)** | `ventanaServicio`/`estadoServicio`/`servicioFin` como único ancla de suspensión, cancelación, cambio de plan y excedente | Intacto. Los `DateTime(y,m,1)` que quedan son legítimos (bucketing de `periodo`, ventana 15→14 del dashboard) |
| **Mes de servicio** | Todas las superficies pasan por `Fmt.mesServicio` | **Una sola función, sin copias**: detalle, lista, mapa, cobro, los 3 recibos, Excel, PDF de historial y de suspensión |
| **Fuga cross-tenant 0246/0247** | Simulando al super_admin real, con RLS aplicada | `recibos_huecos()` = **0** (antes 8 ajenos) · `recibos_huecos_todos()` = 8 (el Dev sigue viendo todo, sin falso verde) · `log_cobertura(7)` = 2 (antes 31.391) |
| **Antipatrón `is_super_admin() or`** | Barrido de `pg_proc` y `pg_policy` | **0 policies** con el patrón; las 7 funciones que lo contienen, revisadas una por una, están todas en la forma canónica o son globales a propósito |
| **Gates totales (regla 0247)** | Todos los `if not <gate>` de plpgsql | `is_super_admin()` es `coalesce(...,false)`; `sync_rechazo_autorizado` envuelta en `coalesce`. **Ningún fail-open** |
| **Schema ↔ sync rules** | `schema.dart` vs `sync-rules.yaml` | **39 == 39**, exactas. Las 11 tablas restantes son server-only a propósito |
| **Triggers de dinero** | 41 con lógica de negocio; espejo Dart de cada uno | **39/39 con `tgenabled='O'`**. Los 7 caminos de recálculo cubiertos, incluido `UPDATE OF en_revision` |
| **CHECK de plata** | Los 8 constraints, todos VALIDATED | Coherencia de moneda NIO/USD, tasa > 0, vuelto ≥ 0, 4 métodos, 5 tipos de cargo, actor+motivo en anulaciones |
| **Oldest-first (#11)** | Guard del cliente en la data real | **0 violaciones en Mairena, 0 en Telenet** (la única está en Test, es el escenario de prueba). El RPC del Dev replica la misma regla |
| **Reloj de la flota** | Offset implícito por cobrador, 120 días, 5.000+ pagos | **Todos en 6,00-6,08 h**. Ni un equipo con la zona horaria mal |
| **Redondeo** | Columnas `numeric(10,2)`, tasa `(10,4)`, 8 puntos de redondeo | Sin acumulación: `montoPuente` acumula sin redondear y redondea una vez al final |
| **Limpiezas del cuaderno** | Contadas contra la base | Telenet **70 cuotas / C$59.595,51 / 27 contratos** (declarado: idéntico). Mairena **383 / C$322.887,63** (declarado: C$322.888). Trío de anulación completo, op_log 1 fila por objeto bajo un solo `op_id`, 27 backups con los uuid adentro |
| **Ops de dinero del Dev (0244/0245)** | Nunca ejecutadas en prod; los 4 casos borde | 0 filas en `data_ops_log`. Doble corrida, cambio entre preview y ejecutar, contrato cancelado en el medio y correlativo: los 4 cubiertos |
| **Greps de regresión de AGENTS** | SQL Postgres-only en `lib/`, `date('now')` pelado | **0 hits reales** en todos (los que aparecen son comentarios explicando por qué no se usan) |
| **Referencias del repo** | Los ~30 símbolos que AGENTS cita; los 177 `.dart` que ARQUITECTURA cita; los 47 SVG de la guía | **0 símbolos muertos**; 176/177 archivos existen; **47/47 SVG presentes**, 0 huérfanos |
| **Release** | Canal, nombres y assets | Un solo release (v0.36.0) y un solo tag; los 8 assets branded + versionados exactamente como AGENTS los describe |

---

## PLAN DE ACCIÓN SUGERIDO

### Ahora (esta sesión o la próxima — alto impacto, esfuerzo mínimo)

1. **El clamp del prorrateo — 3 líneas, en los 3 puntos** (`:225`, `:631` y **`:1390`, el preview**). `min(prorrateado, montoAntes)`. Es el mejor impacto/esfuerzo de todo el informe: cierra la única CRÍTICA sin cambiar semántica, sin migración y sin release de emergencia (el snapshot de precio viene después). **Antes de eso, hoy: no correr "Suspender los N" sobre la cola de mora hasta que el clamp esté.** [#1]
2. **El filtro de motivos de `reactivarContrato` — 1 línea** (`IN` con los tres motivos, o mejor el predicado por `monto_pagado = 0 AND periodo >= mesRNext`). Y **revisar MV0167 de Telenet antes de que alguien lo reactive**: son C$1.832 cargados. [#2]
3. **Las cuatro correcciones de la guía de troubleshooting SQL** (§4 + T1 + INV1-INV20 + baseline). Es la red de seguridad de todo fix de datos en producción y hoy está 15% ciega. Media hora de escritura. [#3, #4]
4. **`ARQUITECTURA.md:1486`** — la regla de oro contradiciendo el invariante #5. Un bullet. [#5]

### Este sprint (real, con costo, sin urgencia)

5. **Snapshot de precio en `cuotas`** (`precio_base`) — el fix estructural de #1. Sin él, el lado de sub-cobro (LB0175: el ISP pierde C$177) sigue abierto.
6. **Recalcular los 6 snapshots del lote B de Telenet sobre las cuotas SOBREVIVIENTES** (280→8.974, 488→8.974, 00255→3.591, 0523→2.565, 487→7.692, 272→7.328) y corregir el script. Y **decidir la semántica de `super_admin_baja_deuda_impl`**, que ya está publicada con la misma colisión. [#6, #7]
7. **`cb.tenant_id = ?` en `arqueo_query.dart`** — el gemelo de Eficiencia, y el único de la familia que mueve dinero. [#9]
8. **`await` de los rastros de rechazo antes de `transaction.complete()`** — 6 líneas, y convierte la única red contra el incidente de Derling en garantía. [#11]
9. **Snapshot de `dia_pago` al cobrar** — cierra el re-etiquetado de los recibos (27 casos ya expuestos, con el gate activo en ambos ISP). [#8]
10. **`periodoServicioRango` delegando en `ventanaServicio`** (165 cuotas) y el **`-6 hours` del PDF de cancelación** (8 contratos, reimprimir alcanza). [#13, #14]
11. **Decidir el gate del "Reporte de cobranza"** para `admin_cobranza` — hoy baja todos los montos a dos clicks. [#15]
12. **Correr el bloque (b2) de 0221** (`contratos_estado_check`) — ya es seguro, hay 0 filas. [#16]
13. **Regenerar los tres catálogos por script** (§3.6.1, §5, tabla de buckets) y dejar el generador en `tool/` como paso de Fase 6. El patrón es claro: todo número hardcodeado en la doc envejece solo. [#20, #21, #22]

### Puede esperar (deuda aceptable, pero anotada)

14. **El tope de `registrarCobroMultiple`** — hoy inalcanzable, pero **antes del próximo onboarding**, porque el seed de tenants nuevos nace con `pago_adelantado = true`. [#24]
15. **Los 4 invariantes faltantes** (oldest-first, devoluciones, INV5 bidireccional, cuota anulada sin contrato) y el **CHECK de atribución de cancelación**. Preventivos: hoy los cinco dan 0. [#34, #35]
16. **El sync gate por progreso al impersonar** y el **`_desde` persistido del banner de cola atascada**. Los dos son UX de diagnóstico. [#12, #36]
17. **La limpieza de doc menor** (#40-#47): conteos, referencias muertas, el `ver-password-cobrador` sin documentar, `app_dispositivos`, y **la instrucción de regenerar la guía** — esta última primero, porque es la causa mecánica de que la guía de usuario se desincronice sola en cada sprint. [#43]
18. **Higiene**: el predicado del corrector de invariantes, el auto-fix de INV17, el reintento de correlativo muerto, `fecha_primer_cobro`. Todo de mantenimiento, cero plata. [#27, #28, #38, #46]

### Decisión del dueño (no son bugs, son preguntas)

- **INV19 = 7 clientes desactivados con C$29.018,53 de deuda**: ¿se da de baja, se reactiva el cliente para cobrarla, o se acepta como incobrable? Está pendiente desde antes de esta ventana.
- **INV11 = 3**: refinar el invariante para que no cuente como violación a los fijos *reactivados* con meses anulados por limpieza, igual que ya exceptúa "Suspensión temporal".
- **Ninguna cobertura real de USD ni de vuelto** en 31.813 pagos: si el negocio va a usar dólares, ese camino nunca se ejerció en producción y conviene un piloto controlado antes que un descubrimiento en caja.