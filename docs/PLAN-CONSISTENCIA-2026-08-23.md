## QUE HAY QUE HACER, EN UNA LINEA

Poner **11 invariantes nuevos** (INV21-31, los 11 dan cero hoy) + **atribución server-side** en las 6 RPC que hoy mueven datos sin dejar rastro, y **arreglar tres agujeros vivos del camino del cobro**: el rastro del rechazo que corre en carrera con el borrado de la op, el rechazo de patch/delete que sube con `tenant_id` NULL y por eso el ISP nunca lo ve, y el fallback offline del PIN que escribe una columna que no existe.

---

## LO QUE YA NO APLICA

**Antes que nada — el worktree `.claude/worktrees/app-status-check-850cf6` está PODRIDO y hay que borrarlo.** Está en v0.28.0 / migración 0203; `main` está en v0.36.1 / 0247 (44 migraciones y 126 archivos atrás). **Tres de las cuatro lentes se comieron findings fantasma por leer ese árbol** — y con `grep` "probaron" bugs que en producción no existen. Es el modo de falla más caro que hay, porque la evidencia parece real. Verificado hoy: `main` = `44036c4`, `connector.dart` 440 líneas vs 262 en el worktree.

Tachar de `BITACORA.md` §Backlog vivo (2026-08-08), **los 8 ítems, está 8/8 cerrado**:

| # | Qué decía | Por qué ya no aplica |
|---|---|---|
| #1 | Cuarentena deja cuota fantasma | `trg_pagos_update_recalcular` ya escucha `en_revision`; 0 cuotas fantasma |
| #2 | Códigos de contrato duplicados | 0 duplicados hoy |
| #3 | Writes rechazados que desaparecen sin aviso | `dd8b691` + 4 commits de refinamiento, en v0.36.0. `.select('id')` en patch y delete, `_filaSigueVisible`, `_espejosLocales`, código `RLS0` y triple rastro. **Ya pagó**: al volverse ruidoso destapó el colchón de indefinidos que se rechazaba en silencio "desde el día uno" (7 capturas en 2 días, 3 cobradores, 2 tenants) → cerrado en 0241 |
| #4 | Guard de desactivar cliente app≠server | `cliente_form_screen.dart` tiene el espejo literal del guard 0220 (mismos estados, mismo umbral 0.01, misma fórmula). Frena ANTES del `writeTransaction` |
| #5 | `admin_usuarios` veía Total de contrato falso (−58%) | `contrato_detail_header.dart:321` lee el rol adentro de `_ContratoResumen` y muestra conteo de cuotas. Barrido adversarial: no queda otra pantalla de la clase |
| #6 | Revalidar código de contrato al aprobar | `solicitudes_repo.dart:382` valida local (con `foldSqlExpr`) **y** contra el server antes del INSERT. 0 duplicados |
| #7 | Solicitudes sin guard de impersonación ni op_log | Las dos mitades cerradas. **Evidencia viva**: cobertura de op_log 0% hasta el 08-10 y **100% desde el 08-12** (23/23, 6/6, 5/5, 9/9, 27/27, 2/2, 1/1, 2/2, 17/17) |
| #8 | Export de Clientes subestimaba la cartera | Salieron "Deuda fuera de ruta" y "Deuda total"; los C$241.697 de contratos no-activos ya no se caen del Excel |

**Y hay que RE-ESCRIBIR, no tachar, el bullet "clientes sin salida por condonación".** El número (40 clientes / C$108.512,58) es correcto pero la lectura está mal y la propuesta que salió de ahí era peligrosa. Desglose que corrí hoy:

| Grupo | Mairena | Telenet | Test | Total |
|---|---|---|---|---|
| **con contrato SUSPENDIDO** (mora normal, reversible, cobrable) | 2 / C$632,83 | 26 / C$88.520,18 | — | **28 / C$89.153,01** |
| **solo CANCELADO** (baja real) | 5 / C$7.917,00 | 6 / C$10.512,57 | 1 / C$930 | **12 / C$19.359,57** |

**82,9% de esa plata son suspendidos**, o sea cartera morosa operando como debe — y 32 de los 40 tienen historial de pagos (el "peor caso", RL0014, ya pagó C$10.256). La propuesta de "prender `ajustes_habilitados` y descontar a los 39" condonaba **C$89.000 cobrables**. Además la salida YA EXISTE: `super_admin_baja_deuda_impl` (0244, hardening 0245), con preview, motivo obligatorio, backup, `data_ops_log` y `op_log`, cableada en `data_ops_screen.dart` (`_BajaDeudaCard`). **La población real del problema son 11 clientes por C$18.429,57**, no 39 por C$107.582.

**No re-flagear tampoco:** los 177 cobros de julio sin op_log tienen causa identificada y cerrada — el bug de RLS de `op_log` para cobradores (sin policy de SELECT el upsert fallaba con 42501 en el `RETURNING` y el connector lo descartaba), arreglado por **0190 el 2026-07-17**. Firma: Snay Espinoza y Lester Tercero con 0 filas antes de esa fecha y cientos después; la oficina, que sí tenía la policy, nunca perdió una. **Un solo caso posterior al fix** en toda la base: pago `b629194b-80a9-43c4-bd23-d77c92f76f24` (PI0052, C$513, 30/07).

---

## PLAN, EN ORDEN DE EJECUCION

### Bloque 0 — Antes de tocar nada (2 minutos)

```powershell
cd "C:\Users\ruben\OneDrive\Escritorio\Antigravity\SITECSA CRM"
git worktree remove .claude\worktrees\app-status-check-850cf6 --force
git worktree prune
```
**Por qué va primero:** todo lo que sigue se verifica leyendo código. Si queda ese árbol, la próxima sesión vuelve a diagnosticar bugs de 2026-06 como si fueran de hoy.

---

### (1) LO QUE SE PUEDE HACER HOY, SIN BUILD

> Todo contra `vxxz`, que **es producción**. Los pasos 1 y 2 son read-only; del 3 al 8 escriben y van con confirmación explícita de Rubén, uno por vez.

#### Paso 1 — Los 11 invariantes al archivo *(read-only, riesgo cero)*

**Qué se cambia:** `supabase/tests/invariantes_dinero.sql` — pegar los 11 bloques CTE entre el cierre de `inv20` y la línea `SELECT * FROM inv1`, y sumar las 11 líneas `UNION ALL` al final. SQL completo en la sección **LOS INVARIANTES NUEVOS**.

Además, dos líneas en el encabezado del archivo:

```sql
-- BASELINE ACEPTADO (no son bugs, están documentados en BITACORA):
--   INV11 = 3   ·   INV19 = 7
--
-- ALCANCE: estos chequeos verifican COHERENCIA entre tablas, no CORRECCIÓN
-- del cálculo. Un monto prorrateado mal, un plan facturado a precio
-- equivocado o una fecha de vencimiento mal derivada CIERRAN igual y NO
-- aparecen acá. Para eso están los tests de `prorrateo.dart` y el manual.
```

**Por qué va primero:** es el instrumento de medición de todo lo que sigue. Y es lo único de la lista con riesgo estrictamente cero.

**Cómo se verifica:** `supabase db query --linked -f supabase\tests\invariantes_dinero.sql` → **31 filas, 29 en cero**, INV11=3 e INV19=7. Corrida completa medida hoy: **9-10 segundos** (los 20 viejos ya tardaban 9 s; ~1 s de costo marginal sobre 57.136 cuotas y 31.826 pagos, contra un `statement_timeout` de 120 s).

**Qué lo puede romper:** nada en producción. El riesgo es de *lectura*: que "31 invariantes en cero" se lea como "la plata está toda verificada". Por eso la línea de ALCANCE es obligatoria, no decorativa.

---

#### Paso 2 — Portar los 11 a la RPC del panel *(migración 0248)*

**Qué se cambia:** `super_admin_verificar_invariantes` — la que corre el Dev desde el panel. Hoy reporta 20; sin este paso, **el archivo y el panel dicen cosas distintas**, que es exactamente el problema que 0220 vino a arreglar.

```sql
-- 0248_invariantes_21_31.sql
-- OJO: partir de pg_get_functiondef('public.super_admin_verificar_invariantes'::regproc),
-- la definición VIVA (0213 → 0218 → 0219 → 0220). NUNCA del cuerpo de una migración
-- vieja: es la lección 0151→0152 (un CREATE OR REPLACE desde un cuerpo viejo dropea
-- llamadas sin avisar).
```

Tres diferencias obligatorias respecto del archivo, porque la RPC es per-tenant:
- agregar `tenant_id = p_tenant` a la tabla externa de cada chequeo;
- en INV27, agregar además `AND o.tenant_id = p.tenant_id` al `NOT EXISTS`, para que use el índice `op_log(tenant_id, entidad, entidad_id, ocurrido_en)`;
- reemplazar `string_agg(...)` por `array_to_string((array_agg(... ORDER BY ...))[1:10], ', ')` — sin tope, INV27 escupe 91 UUIDs justo el día que sirve.
- INV21 aporta **dos CTE auxiliares** (`of_regs`, `of_tope`) además de `inv21`: entran igual en la misma cadena `with`, solo hay que filtrarles el tenant.

**Por qué va acá:** después del Paso 1 (que fija el texto SQL canónico) y **antes** del Paso 5, porque el preview de esta RPC es lo que dimensiona el volumen de `corregir_invariantes`.

**Cómo se verifica:** `SELECT * FROM super_admin_verificar_invariantes('8583a8f0-191d-4750-a07d-923c01a45300')` → 31 filas; y contra Mairena y Telenet, mismos números que el archivo.

**Qué lo puede romper:** el `CREATE OR REPLACE` acumulativo. Si se reescribe de memoria, se pierden chequeos en silencio. Segundo: el panel va a mostrar las 11 filas nuevas **sin explicación** hasta que salga el build con `kInvInfo` (Bloque 2). Es degradación aceptable — prefiero detección sin etiqueta que etiqueta sin detección.

---

#### Paso 3 — Backfill de las 14 filas de op_log de duplicados auto-anulados *(migración 0249 · ESCRIBE)*

**Verificado hoy: exactamente 14 filas.** Son pagos auto-anulados por `pagos_guard_sobrepago_trg` **antes** de que el trigger emitiera op_log — 13 de Mairena el 01/08 (12×C$513 + 1×C$1.282 = **C$7.938**) y 1 del Test Tenant (C$850). `select count(*) from op_log where tipo_op ilike '%duplicado%'` → **0**, o sea que el mecanismo ya está arreglado hacia adelante y esto es solo la deuda histórica.

```sql
INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                           actor_id, actor_label, accion, diff, ocurrido_en)
SELECT gen_random_uuid(), p.tenant_id, gen_random_uuid(),
       'duplicado_auto_anulado', 'cuotas', p.cuota_id,
       NULL, 'Sistema', 'update',
       jsonb_build_object(
         'campos', '[]'::jsonb,
         'resumen', jsonb_build_object(
           'monto',  p.monto_cordobas,
           'motivo', 'Backfill: pago auto-anulado por duplicado exacto (registro '
                     || 'reconstruido, ' || p.anulado_en::date || ')'))::text,
       COALESCE(p.anulado_en, p.created_at)
  FROM public.pagos p
 WHERE p.anulado
   AND p.anulado_por IS NULL
   AND p.motivo_anulacion LIKE 'Duplicado autom%'
   AND NOT EXISTS (SELECT 1 FROM public.op_log o
                    WHERE o.entidad='cuotas' AND o.entidad_id=p.cuota_id
                      AND o.tipo_op='duplicado_auto_anulado');
```

**Por qué acá:** es la única escritura de la tanda que no toca ninguna función; sale sola y deja el historial limpio antes de que empiece la cirugía de RPC.

**Cómo se verifica:** debe insertar **exactamente 14**. Después: la query de detección baja de 15 a 1 (queda solo un pago de prueba del Test Tenant anulado a mano), y `invariantes_dinero.sql` sin cambios.

**Qué lo puede romper:** el `LIKE` del motivo. Correr primero el SELECT de conteo (debe dar 14). El `NOT EXISTS` lo hace idempotente ante una doble corrida. No toca `pagos` ni `cuotas` ni ninguna métrica de caja.

---

#### Paso 4 — Atribución de las 5 RPC del super_admin *(migración 0250)*

**Verificado:** `set_cobrador_rol`, `set_cobrador_activo`, `set_tenant_modulo`, `set_tenant_activo` y `forzar_reset_dashboard_pin` no escriben **ni op_log ni data_ops_log**. Hoy no hay forma de contestar "¿quién convirtió a X en admin_cobranza?", "¿quién desactivó a este cobrador?" ni "¿quién le reseteó el PIN del dashboard?". Y el rol decide quién cobra y quién ve la plata; peor, `set_cobrador_rol` **borra `prefijo_recibo`** en silencio al degradar a un rol sin cobro.

Patrón, después del UPDATE (nunca antes — la función tiene un early `RETURN` cuando el rol no cambia):

```sql
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), c.tenant_id, gen_random_uuid(), 'edicion_entidad',
         'cobradores', p_cobrador_id, NULL, 'System Admin', 'update',
         jsonb_build_object('campos', jsonb_build_array(
           jsonb_build_object('campo','rol','antes',v_target_rol,'despues',p_nuevo_rol)))::text,
         now()
    FROM public.cobradores c WHERE c.id = p_cobrador_id;
```

Idem para `set_cobrador_activo` (campo `activo`) y `forzar_reset_dashboard_pin` (`tipo_op: 'editar'`, resumen `{'motivo':'PIN del dashboard reseteado por el administrador'}` — **nunca el PIN**). `set_tenant_modulo` / `set_tenant_activo` no tienen entidad con pantalla en el tenant: van a `data_ops_log`.

**Por qué acá:** las tres primeras **se ven solas, sin build** — la pantalla de Personal ya monta `HistorialOpLog(entidad:'cobradores')` en `cobradores_admin_screen.dart:759`. Registro nuevo con cero código Dart.

**Cómo se verifica:** cambiar el rol de un miembro del Test Tenant y confirmar la entrada en su historial, con actor "System Admin".

**Qué lo puede romper:** poco. `op_log` tiene `super_admin_all` desde 0131 y estas funciones son SECURITY DEFINER. El cuidado real es el orden (insert DESPUÉS del UPDATE) y partir del cuerpo vigente.

---

#### Paso 5 — `super_admin_corregir_invariantes` con triple registro *(migración 0251)*

**Es la única operación de dinero del panel del Dev sin ningún rastro.** Verificado: `oplog=no`, `dataops=no`, y `data_ops_log` tiene 90 filas de 7 operaciones — ninguna es `corregir_invariantes`. Y hace **cuatro mutaciones masivas por tenant**: reescribe `cargos_neto` (INV14), `monto_pagado` (INV2), `estado` (INV3) y regenera cuotas (INV17). Si la fórmula de `calcular_cargos_neto` tiene un borde mal (ya pasó, fix F5 del 02/08), el botón repara mal miles de cuotas de Mairena y no hay forma de saber cuáles ni de volver atrás.

Patrón, por bloque:

```sql
WITH tocadas AS (
  UPDATE public.cuotas q SET monto_pagado = ... WHERE ... RETURNING q.id, q.tenant_id
)
INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                           actor_id, actor_label, accion, diff, ocurrido_en)
SELECT gen_random_uuid(), t.tenant_id, v_op_id, 'correccion_invariante', 'cuotas', t.id,
       NULL, 'System Admin', 'update',
       jsonb_build_object('campos','[]'::jsonb,
         'resumen', jsonb_build_object('motivo',
           'Corrección automática INV2 (monto_pagado re-sincronizado)'))::text,
       now()
FROM tocadas t;
```
y al cierre, una sola fila de resumen en `data_ops_log` (`operacion='corregir_invariantes'`, `target_label='INV14/INV2/INV3/INV17'`, `afectados=v_total`).

**Por qué después del Paso 2:** el preview (`super_admin_verificar_invariantes`) es lo que te dice cuántas filas va a tocar **antes** de correrlo.

**Cómo se verifica:** preview → ejecutar en Test Tenant → `data_ops_log` con 1 fila `corregir_invariantes` + las filas op_log en las cuotas esperadas → `invariantes_dinero.sql` en cero.

**Qué lo puede romper:** dos cosas. (a) Volumen: si se corre sobre Mairena con muchas cuotas desalineadas, el op_log por cuota mete miles de filas de golpe — acotado porque los UPDATE ya filtran a las que cambian, pero **medí con el preview antes**. (b) El orden de los cuatro bloques: **INV14 va antes de INV3 a propósito** (el estado depende de `cargos_neto`). Reescribirlo de memoria lo rompe.

---

#### Paso 6 — `sync_rechazos`: historial visible + motivo al descartar *(migración 0252)*

Descartar un rechazo es **declarar perdido un cobro real** (hay recibo en papel, el cliente pagó). Hoy `sync_rechazo_descartar` solo marca `resuelto` y el tile sale de la única lista. Su hermano `sync_rechazo_registrar` sí escribe `cobro_recuperado`.

**El matiz importante, que corregí:** la fila **nunca se borra** — quedan `resuelto/_en/_por` y el `payload` completo para siempre. Y ya hay triple rastro por diseño. **Lo que falta no es registro, es visibilidad + motivo.** Por eso **NO** metemos un insert de op_log adentro de esa función: `op_log.tenant_id` es NOT NULL **con FK a tenants**, y 0247 reserva a propósito las filas huérfanas (tenant NULL) al super_admin → un insert ahí lo brickearía; y la función **no tiene bloque `exception`**, así que cualquier error sube crudo y deja la fila indescartable. Descartar es la salida de emergencia documentada del aviso dañado — no se puede romper.

La versión segura, copiando el precedente de 0242 (`recibos_huecos_ignorados`):

```sql
-- 0252_sync_rechazos_historial.sql
BEGIN;

ALTER TABLE public.sync_rechazos ADD COLUMN IF NOT EXISTS motivo text;

-- Nueva, ADITIVA: no toca sync_rechazos_pendientes (que la app llama hoy).
CREATE OR REPLACE FUNCTION public.sync_rechazos_historial()
RETURNS SETOF public.sync_rechazos LANGUAGE sql SECURITY DEFINER
SET search_path = public AS $$
  SELECT sr.* FROM public.sync_rechazos sr
   WHERE public.sync_rechazo_autorizado(sr.tenant_id)
   ORDER BY sr.ocurrido_en DESC LIMIT 200;
$$;
GRANT EXECUTE ON FUNCTION public.sync_rechazos_historial() TO authenticated;

-- p_motivo con DEFAULT: la app actual (que llama solo con p_id) sigue andando.
-- CREATE OR REPLACE no puede agregar parámetros -> DROP+CREATE en la MISMA
-- transacción, partiendo del cuerpo VIGENTE de 0247 (conserva el orden
-- anclaje-antes-del-atajo-de-idempotencia y el gate sync_rechazo_autorizado).
DROP FUNCTION IF EXISTS public.sync_rechazo_descartar(uuid);
CREATE FUNCTION public.sync_rechazo_descartar(p_id uuid, p_motivo text DEFAULT NULL)
... -- cuerpo vigente + `motivo = nullif(btrim(p_motivo),'')` en el UPDATE
COMMIT;

NOTIFY pgrst, 'reload schema';
```

**Por qué acá:** el toggle "ver resueltos" y el diálogo de motivo son Bloque 2, pero la función y la columna pueden estar listas antes, y `sync_rechazos_historial()` no puede romper nada porque nadie la llama todavía.

**Cómo se verifica:** `SELECT * FROM sync_rechazos_historial()` como admin de Telenet → solo sus filas; como super_admin → las 11. Y descartar un rechazo de prueba con el app actual (sin `p_motivo`) debe seguir funcionando.

**Qué lo puede romper:** la ventana del DROP+CREATE (milisegundos, dentro de una transacción) y el cache de esquema de PostgREST — por eso el `NOTIFY`.

---

#### Paso 7 — Dedupe de `sync_rechazos` *(migración 0253)*

`_subirRechazo` hace un INSERT pelado sin `on conflict` y la tabla no tiene índice único. Si el batch se reintenta (una op descartada + una retryable en el MISMO batch), el mismo rechazo entra N veces → el admin ve el mismo cobro repetido y no sabe si son N cobros o uno.

```sql
CREATE UNIQUE INDEX IF NOT EXISTS sync_rechazos_dedupe_pendiente
  ON public.sync_rechazos (tabla, registro_id, coalesce(codigo, ''))
  WHERE resuelto = false;
```
Parcial sobre `resuelto = false` **a propósito**: si el mismo rechazo vuelve a ocurrir meses después, tiene que poder entrar como aviso nuevo. Del lado Dart no hay que tocar nada: el 23505 lo traga el `catch` de `_subirRechazo`, que es el comportamiento deseado (el rastro local ya quedó).

**Cómo se verifica antes:** `select tabla, registro_id, codigo, count(*) from sync_rechazos group by 1,2,3 having count(*)>1` → **0 hoy**, entra limpio. Re-verificar en el momento de correrla.

---

#### Paso 8 — CHECK de atribución de cancelación *(migración 0254 · el más riesgoso, va último)*

```sql
ALTER TABLE public.contratos
  ADD CONSTRAINT contratos_cancelacion_coherencia CHECK (
    estado <> 'cancelado'
    OR (cancelado_en IS NOT NULL
        AND cancelado_por IS NOT NULL
        AND COALESCE(btrim(motivo_cancelacion), '') <> '')
  ) NOT VALID;
```

**Verificado hoy:** 189 contratos cancelados, **94 sin atribución completa** — pero el desglose exculpa a la app: 37 legacy sin ningún rastro + **57 de una limpieza SQL manual del 19/08**. Los 129 cancelados de agosto hechos POR LA APP tienen los tres campos, incluyendo aprobación de solicitudes (26 casos) y prorrateo. **Ningún camino de la app deja el actor vacío.** `NOT VALID` ignora los 94 viejos y solo exige a las escrituras nuevas.

**Por qué va último:** es lo único de la tanda que puede hacer fallar una acción de usuario. Si un camino cancela sin poner los tres campos, el ISP ve un error al dar de baja.

**Cómo se verifica:** dar de baja un contrato de prueba en el Test Tenant y confirmar que no rebota; después, `SELECT count(*) FROM contratos WHERE estado='cancelado' AND (...)` debe seguir en 94 (los que NOT VALID ignora).

**Qué lo puede romper:** el próximo script SQL de limpieza manual. Con el CHECK puesto habría fallado el del 19/08 — que es lo deseado, pero hay que avisarle a quien escriba el siguiente.

---

### (2) LO QUE NECESITA BUILD

#### B1 — El rastro del rechazo, antes de destruir la evidencia *(el más importante del bloque)*

**Qué pasa hoy** (`lib/powersync/connector.dart`): `_registrarRechazo` es `void` y dispara dos `unawaited`; tres call sites lo llaman sin `await` (**:95** patch cero-filas, **:112** delete cero-filas, **:147** excepción Postgrest — la propuesta original decía dos y dejaba el delete afuera), y en **:62 / :153** corre `await transaction.complete()`, que borra la op para siempre. Verifiqué en `powersync_core-1.8.0` que `complete()` borra las ops de la cola y que el isolate hace `await connector.uploadData(this)` **sin timeout**.

**El cambio** (un solo flush, no un `await` por call site — un `await` adentro del loop retiene el batch entero si un cambio de policy rechaza cientos de ops):

```dart
// en uploadData, antes del for:
final pendientes = <RechazoSync>[];

// _registrarRechazo sigue siendo void (snackbar + unawaited(_subirRechazo)),
// pero en vez de unawaited(registrar(...)) hace:
pendientes.add(RechazoSync(...));

// justo antes de transaction.complete():
if (pendientes.isNotEmpty) {
  try {
    await RechazosSyncService.instance
        .registrarVarios(pendientes)
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('[CRUD] no se pudo persistir el rastro local: $e');
  }
}
await transaction.complete();
```
Agregar `Future<void> registrarVarios(List<RechazoSync>)` a `RechazosSyncService` = **un** read-modify-write de prefs para todo el batch (hoy serían N, cada uno decodificando hasta 50 JSON por el dedupe).

**El timeout y el catch NO son opcionales.** `registrar()` devuelve `_serial`, la cola compartida (`_serial = _serial.then(...); return _serial;`). Si un eslabón nunca resuelve, **todo upload posterior de ese device se traba para siempre** — el escenario que 0236 declara inaceptable. Y si un eslabón falla, el error queda en la cadena y se propaga a todos los `.then` siguientes → sube al catch externo → `rethrow` → el batch se reintenta → la op se re-rechaza → la cola no drena nunca.

**Decilo por su nombre en el commit:** esto **angosta una ventana de decenas de ms**, no crea una garantía. Si el flush timeoutea, la op igual se descarta sin rastro. Y **no** atribuirle el incidente de los 10 cobros de Telenet: `sync_rechazos` no existía entonces (la creó 0236 *por* ese incidente) y el rastro local sí existía — los 19 días ciegos fueron por **visibilidad**, no por la carrera.

**Test que sí se puede correr** (matar la app en una ventana de decenas de ms no es verificable a mano): mock de prefs que nunca completa → `uploadData` debe retornar dentro del timeout y `transaction.complete()` debe haberse llamado. Va junto a `test/powersync/connector_clasificacion_test.dart`.

---

#### B2 — El rechazo de patch/delete sube con `tenant_id` NULL y el ISP nunca lo ve *(agujero abierto y permanente)*

**Verificado en `connector.dart:301`:**
```dart
final tenantId = op.opData?['tenant_id'] as String?;
```
En un **DELETE**, `opData` es null → `tenant_id` NULL. En un **PATCH**, `opData` trae solo las columnas *cambiadas*, y nadie patchea `tenant_id` → NULL también. Y 0247 reserva las filas con tenant NULL al super_admin. O sea: **una clase entera de rechazos llega al server y es invisible para el ISP**, aunque el rastro exista. Hoy da 0 filas con tenant NULL solo porque el camino patch/delete todavía no se disparó en producción.

**El fix:** resolver el tenant desde la fila local cuando `opData` no lo trae, antes de subir:
```dart
final tenantId = op.opData?['tenant_id'] as String? ??
    (await _db.getOptional(
        'SELECT tenant_id FROM ${op.table} WHERE id = ?', [op.id]))?['tenant_id'] as String?;
```
(dentro del `try` de `_subirRechazo`, cuya regla es que ninguna línea puede tirar hacia afuera).

**Esto es más urgente que B1**: B1 angosta milisegundos, B2 cierra un agujero estructural y permanente. Si hay que elegir uno, es este.

---

#### B3 — La ruta al aviso persistente

El aviso de rechazo vive en `PerfilScreen`. En `router.dart` hay `/perfil`, `/tecnico/perfil` y `/admin-tickets/perfil`; el admin además tiene el badge en `admin_shell.dart:28` y `RechazosSyncSeccion` en `cobros_a_revisar_screen.dart:194`. **Verificar rol por rol quién llega efectivamente**, y cerrar el que falte. Esta es la causa documentada de los 19 días ciegos del incidente de Telenet — más impacto que cualquier micro-optimización del connector.

---

#### B4 — Test de repo: todo camino de cobro emite op_log

Es lo único que ataca la **causa** que INV27 solo puede *detectar*: hoy nada impide que un flujo de cobro nuevo o refactorizado se despache sin su `OpLog.escribir` (`pagos_repo`, `contratos_repo`, `cuotas_repo` lo emiten a mano). Un test en la suite de `pagos_repo` que falle si `registrarCobro`/`registrarCobroMultiple`/recuperación no dejan fila. Corre **en cada commit**, no una vez por deploy.

---

#### B5 — El fallback offline del PIN está roto *(bug vivo, lo verifiqué yo)*

`dashboard_admin_screen.dart` cae, cuando la RPC `set_mi_dashboard_pin` falla, a:
```dart
await ps.dbW.execute('UPDATE cobradores SET dashboard_pin = ? WHERE id = ?', [pin, cobrador.id]);
```
Pero `dashboard_pin` **no es columna** de `cobradores` en `lib/powersync/schema.dart` — el schema tiene `dashboard_pin_configurado` y el valor vive en la tabla `dashboard_pins` (0201/0202); el propio comentario de `schema.dart:618` lo dice. O sea: el `execute` tira *"no such column"*, lo agarra el catch externo y el admin ve un error — **justo el caso que el comentario de :176-184 dice que el fallback existe para evitar** ("un admin sin PIN y sin internet quedaría encerrado sin poder abrir su propio dashboard").

Fix: escribir en `dashboard_pins` local, no en `cobradores`.

**Corolario:** esto **anula** la propuesta de agregar `'cobradores': {'dashboard_pin'}` a `_espejosLocales`. Ese write nunca llega a la cola, así que no hay nada que silenciar.

---

#### B6 — `.select('id')` es load-bearing: un solo bloque, fusionado

**Verificado empíricamente contra producción** (con `set_config` de `request.jwt.claims` + `set role authenticated`): `select id from cobradores limit 1` → OK; `select * from cobradores limit 1` → **ERROR 42501, permission denied for table cobradores**. `cobradores` es la **única** tabla con UPDATE/DELETE y sin SELECT de tabla para `authenticated` (0199 lo revocó y lo re-otorgó por columna; `dashboard_pin` y `password_texto` quedaron afuera a propósito). Y 42501 cae en `esCodigoNoRetryable` (`connector.dart:415`, prefijo '42') → **el write se descarta, no se reintenta**.

Hay **tres** `.select('id')` load-bearing: :91 (patch), :105 (delete) y **:226 (dentro de `_filaSigueVisible`)** — el tercero es el más frágil porque parece un read inocente.

**No agregar un bloque paralelo: fusionar.** `connector.dart:81` ya tiene un comentario que explica la razón A (un UPDATE filtrado por USING devuelve 0 filas sin excepción). Falta la razón B (el column-grant). Dos bloques de 10 líneas sobre la misma expresión es peor que uno. Y **corregir el dato falso**: el descarte **no** es silencioso desde 0236 — deja SnackBar + registro persistente en el device + fila en `sync_rechazos`.

**Y un comentario no falla en CI** (el propio archivo tiene precedente de un comentario que quedó FALSO tras 0230). Si se quiere enforcement real: un test que lea el fuente y afirme **exactamente 3** ocurrencias de `.select('id')`. Feo, pero es lo único que rompe el build. **No** meter esto al checklist de `AGENTS.md` §audit — ese checklist es para clases de bug cross-cutting, y una expresión en un archivo lo diluye.

---

#### B7 — Extraer la decisión del rechazo a una función pura

`grep -rn "RLS0|filaSigueVisible|esEspejoLocal" test/` → **cero**. La lógica que decide si un cobro de C$500 se marca perdido o se da por bueno no tiene un solo test, y los 4 commits de refinamiento (`31e64ed` "el guard comparaba tipos y habría dado rechazos falsos" se arregló **el mismo día**, o sea que llegó roto a main) son bugs que un test hubiera cazado.

```dart
enum AccionTrasEscritura { seguir, registrarRechazo }

@visibleForTesting
AccionTrasEscritura evaluarEscritura({
  required UpdateType op, required bool huboFilas,
  required bool esEspejoLocal, required bool filaSigueVisible,
}) {
  if (huboFilas) return AccionTrasEscritura.seguir;
  if (esEspejoLocal) return AccionTrasEscritura.seguir;
  if (!filaSigueVisible) return AccionTrasEscritura.seguir;
  return AccionTrasEscritura.registrarRechazo;
}
```
**Cuidado:** hoy `_filaSigueVisible` NO se llama si `_esEspejoLocal` es true (corto-circuito del `&&`). Hay que preservarlo o se agrega un round-trip por cada cobro con espejo.

---

#### B8 — `settings` al catálogo del historial

`settings` es el **segundo tipo de op_log más numeroso (497 filas, verificado)** y la **única entidad que escribe sin estar en el catálogo**: cae al camino permisivo de `opLogCamposVisibles` (que devuelve `null` para entidades no catalogadas) y se renderiza con las **claves crudas**; el panel de campos visibles no ofrece sección Configuración. Es la peor legibilidad del sistema justo donde se registran las compuertas de dinero (`cambio_plan_habilitado`, `cambio_fecha_habilitado`, `credito_excedente`).

**Riesgo real de regresión:** al entrar al catálogo pasa a mostrar **solo** lo listado. Si los nombres no coinciden con lo que emite el `diff`, las 497 filas dejan de mostrar cualquier campo. **Paso previo obligatorio:** leer los 4 call sites (`settings_repo.dart:79,135,158` y `settings_admin_screen.dart:1430`) y sacar los nombres reales.

---

#### B9 — Las 9 entidades con toggles inertes

`cargos_extra`, `cliente_etiquetas`, `contrato_suspensiones`, `fotos_cliente`, `recibos`, `saldos_favor`, `ticket_adjuntos`, `ticket_eventos`, `ticket_materiales` están en el catálogo pero **nunca se escriben** (sus eventos van scoped al padre, que es el contrato del modelo y está bien). El panel renderiza 9 secciones cuyos checkboxes no hacen nada. Es cosmético, pero invita al diagnóstico equivocado: "no veo los cargos en el historial" → el primer lugar donde van a mirar es un toggle muerto, cuando la config que manda es la de `cuotas`. Preferible la opción (b): dejarlas visibles pero deshabilitadas, con "Se registra en el historial de **Cuotas**".

---

#### B10 — `kInvInfo` + el string hardcodeado

Entradas `INV21`..`INV31` en `lib/features/admin/settings/invariantes_detalle.dart` (sin ellas el panel muestra la fila sin explicación ni qué hacer). **NO** agregarlos a `kAutoFixCodes`: INV27 no tiene arreglo (append-only, no se conoce actor ni momento). Y actualizar `lib/features/super_admin/diagnostico_screen.dart:631`, que dice *"Las 20 invariantes dan 0 violaciones"*.

---

#### B11 — Un paso de testing, no un fix: `reimpresion_recibo`

El código está desde el 18/08 (`54ff73b`) y **hoy sigue en 0 filas sobre 31.801 recibos** (verificado). Que el build en la calle es posterior lo prueba `cambio_plan` con 37 filas del 22/08. Puede ser inocente (nadie reimprimió) o el path no dispara — desde la base no se distingue.

Con **identidad REAL** (el guard corta si `actorId == null`, así que **no impersonando**): abrir un recibo ya impreso, reimprimirlo, mirar el relojito de la cuota, y `select count(*) from op_log where tipo_op='reimpresion_recibo'` ≥ 1. Si da 0, el diagnóstico está acotado a: (a) `actorId` null, (b) el JOIN no resuelve `cuota_id` en recibos de cobro múltiple, (c) **la más probable** — `impreso_en` no se setea en la primera impresión, con lo cual la segunda se evalúa como primera y `esReimpresion` da false **para siempre**.

Importa porque reimprimir es el vector clásico de cobrar dos veces con el mismo papel.

---

### (3) LO QUE ES DECISION DEL DUEÑO

| # | Decisión | Qué hay que saber |
|---|---|---|
| D1 | **Los 11 clientes cancelados con deuda (C$18.429,57)** | Usar `super_admin_ejecutar_baja_deuda` desde el panel del Dev, **uno por uno, confirmados con el ISP**. 1 de los 40 tiene cuota parcial → lo bloquea INV12, con las dos salidas que la función explica |
| D2 | **Los 28 suspendidos (C$89.153,01): NO tocar** | Es cartera morosa normal y reversible; 32 de los 40 tienen historial de pagos. Su salida es cobrarles o reactivarlos |
| D3 | **NO prender `cobranza.ajustes_habilitados`** | Está en `false` en Mairena y Telenet. Prenderlo abre descuento discrecional tenant-wide con topes **solo client-side** sobre 5.500 clientes. Además Telenet tiene `ajuste_max_porcentaje = 50` → un descuento del 100% se rechaza igual, y `ajuste_max_monto = 0` desactiva el tope por monto |
| D4 | ¿El admin del tenant debería poder cerrar un moroso sin depender del super_admin? | Propuesta de producto Fase 2, dimensionada en **11 clientes**, y **debe ser un RPC server** como el que ya existe — nunca un `writeTransaction` de cliente (una condonación encolada offline y reproducida después corre contra el guard 0220 y el trigger 0234) |
| D5 | **22 clientes activos sin contrato** (21 Mairena + 1 Telenet) + los 8 huérfanos de la importación (RA0028, CNS032, RA0006, RA0016, SE0368, SA0076, SA0030, LF0103) | Pregunta para el ISP, no bug de código |
| D6 | ¿Un cobrador puede **devolver** un saldo a favor un día en que no cobró nada? | Afina INV28. Contablemente eso es caja negativa; si el negocio lo permite, hay que aflojar a nivel arqueo cerrado o documentar la excepción |
| D7 | ¿El **recibo** es obligatorio en una devolución? | Afina INV29. Si se decide que es opcional, se saca esa condición (una línea) |
| D8 | Confirmar las 2 escrituras estructurales en PROD | El backfill de 14 filas (Paso 3) y el CHECK NOT VALID (Paso 8) |
| D9 | Los **177 cobros históricos sin op_log** | **Documentar en BITACORA con la causa correcta (bug de RLS, cerrado por 0190), no backfillear.** `op_log` es el log de intención del cliente: inventarle filas al pasado lo contamina |

---

## LOS INVARIANTES NUEVOS

Los 11 **dan cero hoy contra producción**, así que entran sin una sola alarma que limpiar. Van entre el cierre de `inv20` y la línea `SELECT * FROM inv1`. Corrida completa medida: 9-10 s.

```sql
-- ============================================================================
-- INV 21: oldest-first (invariante #11 de AGENTS). La ÚNICA regla de dinero
-- que no tenía red: por DECISIÓN de producto NO hay trigger server, solo el
-- guard del cliente (`pagos_repo._validarOldestFirst`), que es ciego al
-- multi-device offline. `k` = (fecha_vencimiento, período) = el MISMO criterio
-- de orden que usa `keyDe` en el guard. Una violación por CUOTA SALTADA.
-- SOLO cuenta la que NUNCA vio plata (`pendiente` + monto_pagado <= 0.01):
-- incluir 'parcial' da 1 falso positivo (una cuota pagada completa que después
-- recibe un cargo vuelve a 'parcial' sin que nadie viole el orden).
-- ============================================================================
,of_regs AS (
  SELECT cu.id, cu.contrato_id, cu.estado, cu.monto_pagado, cu.monto, cu.cargos_neto,
         to_char(cu.fecha_vencimiento,'YYYYMMDD') || to_char(cu.periodo,'YYYYMMDD') AS k
  FROM public.cuotas cu
  WHERE cu.contrato_id IS NOT NULL
    AND cu.tipo_cargo_manual IS NULL
    AND cu.estado <> 'anulada'
)
,of_tope AS (
  SELECT contrato_id, max(k) AS k_max
  FROM of_regs WHERE monto_pagado > 0.01 GROUP BY contrato_id
)
,inv21 AS (
  SELECT 'INV21: ninguna cuota vieja saltada por un cobro posterior (#11 oldest-first)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT r.id
    FROM of_regs r
    JOIN of_tope t ON t.contrato_id = r.contrato_id
    WHERE r.estado = 'pendiente'
      AND r.monto_pagado <= 0.01
      AND (r.monto + COALESCE(r.cargos_neto,0)) > 0.01
      AND r.k < t.k_max
  ) t
)

-- ============================================================================
-- INV 22: INV5 es unidireccional (pago vivo -> recibo). Este es el reverso.
-- Un recibo vivo sin pago vivo detrás es un comprobante con número fiscal
-- circulando sin plata en caja.
-- ============================================================================
,inv22 AS (
  SELECT 'INV22: todo recibo vivo cuelga de un pago vivo (reverso de INV5)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT r.id
    FROM public.recibos r
    LEFT JOIN public.pagos p ON p.id = r.pago_id
    WHERE COALESCE(r.anulado, false) = false
      AND (r.pago_id IS NULL OR p.id IS NULL OR p.anulado = true)
  ) t
)

-- ============================================================================
-- INV 23: INV5 se satisface con un recibo ANULADO (solo pregunta NOT EXISTS).
-- Este exige EXACTAMENTE UNO vivo: caza el cobro sin comprobante válido Y el
-- duplicado que quema un correlativo. SUBSUME a INV5; se dejan los dos porque
-- si divergen (INV5=0, INV23=N) el par te dice que el problema son recibos
-- anulados y no recibos faltantes.
-- ============================================================================
,inv23 AS (
  SELECT 'INV23: todo pago vivo tiene EXACTAMENTE un recibo vivo (refuerza INV5)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE p.anulado = false
      AND (SELECT COUNT(*) FROM public.recibos r
            WHERE r.pago_id = p.id AND COALESCE(r.anulado,false) = false) <> 1
  ) t
)

-- ============================================================================
-- INV 24: el hueco entre INV2 (excluye anuladas) e INV12 (recorre contratos).
-- Un pago VIVO sobre una cuota anulada o inexistente no lo mira NADIE, y esa
-- plata SÍ entra al arqueo y al dashboard (que suman monto_cordobas bruto).
-- Las cuotas manuales pueden tener contrato_id NULL (hay 2 en prod), así que
-- INV12 tampoco llega por ese lado.
-- ============================================================================
,inv24 AS (
  SELECT 'INV24: ningún pago vivo cuelga de una cuota anulada o inexistente' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    LEFT JOIN public.cuotas cu ON cu.id = p.cuota_id
    WHERE p.anulado = false
      AND (p.cuota_id IS NULL OR cu.id IS NULL OR cu.estado = 'anulada')
  ) t
)

-- ============================================================================
-- INV 25: verifica que la red de 0234 (anular cuotas futuras al dar de baja)
-- haya funcionado. 0234 nació de 8 cuotas por C$6.411 que se siguieron
-- facturando después de la baja.
-- ¡OJO! El predicado del WHERE es COPIA EXACTA del CTE `futuras` de
-- `contratos_anular_cuotas_futuras_trg`, A PROPÓSITO: si el trigger cambia,
-- este invariante tiene que cambiar con él.
-- Anclado a la VENTANA DE SERVICIO, nunca al mes calendario (regla 1c de
-- AGENTS): anclado al mes da 14 FALSOS POSITIVOS que son prorrateos de baja
-- correctos (facturación vencida con dia_pago <> 1).
-- ============================================================================
,inv25 AS (
  SELECT 'INV25: contrato dado de baja sin cuotas FUTURAS vivas (red 0234)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id
    FROM public.contratos ct
    JOIN LATERAL (
      SELECT CASE WHEN ct.estado = 'cancelado' THEN ct.cancelado_en::date
                  ELSE (SELECT s.suspendido_en::date FROM public.contrato_suspensiones s
                         WHERE s.contrato_id = ct.id AND s.reactivado_en IS NULL
                         ORDER BY s.suspendido_en DESC LIMIT 1) END AS fecha
    ) b ON true
    JOIN public.cuotas cu ON cu.contrato_id = ct.id
    WHERE ct.estado IN ('cancelado','suspendido')
      AND b.fecha IS NOT NULL
      AND cu.estado = 'pendiente'
      AND cu.tipo_cargo_manual IS NULL
      AND COALESCE(cu.monto_pagado, 0) <= 0.009
      AND COALESCE(
            (SELECT max(cu2.fecha_vencimiento) FROM public.cuotas cu2
              WHERE cu2.contrato_id = cu.contrato_id
                AND cu2.fecha_vencimiento < cu.fecha_vencimiento
                AND cu2.estado <> 'anulada'),
            (cu.fecha_vencimiento - interval '1 month')::date
          ) > b.fecha
  ) t
)

-- ============================================================================
-- INV 26: cancelar contrato es el único evento de plata sin CHECK de
-- atribución (`pagos` y `cuotas` sí tienen el suyo). CORTE 2026-08-20: los 94
-- históricos sin atribuir son 37 legacy + 57 de una limpieza SQL manual del
-- 19/08. Ningún camino de la APP deja el actor vacío. La segunda rama cubre
-- el caso sin fecha, que si no se escaparía por el propio filtro de fecha.
-- ============================================================================
,inv26 AS (
  SELECT 'INV26: cancelación de contrato atribuida (desde 2026-08-20)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE ct.estado = 'cancelado'
      AND (ct.cancelado_en >= DATE '2026-08-20'
           OR (ct.cancelado_en IS NULL AND ct.created_at >= DATE '2026-08-20'))
      AND (ct.cancelado_por IS NULL
           OR ct.cancelado_en IS NULL
           OR COALESCE(btrim(ct.motivo_cancelacion), '') = '')
  ) t
)

-- ============================================================================
-- INV 27: `op_log` es el ÚNICO registro de cambios (audit_log se eliminó en
-- 0140) y lo escribe el CLIENTE -> la fila puede perderse sin que el cobro se
-- pierda. Ningún INV1-20 lo miraba.
--
-- CORTE 2026-08-20 + GRACIA DE 48 h. El corte deja afuera los 177 cobros
-- históricos (causa conocida: `op_log` no tenía policy de SELECT para
-- cobrador, el upsert fallaba con 42501 y el connector lo descartaba;
-- cerrado por 0190 el 2026-07-17). La gracia de 48 h evita el FALSO POSITIVO
-- del cobrador offline: `uploadData` sube las ops de a una y el insert de
-- op_log es la ÚLTIMA del writeTransaction del cobro; si se corta la señal en
-- el medio, el server queda con el pago y sin rastro hasta la próxima sync.
--
-- QUÉ NO VE: (a) el 2º pago o posterior sobre la MISMA cuota (es EXISTS, no
-- conteo: ~3% de los pagos de Mairena desde julio); (b) los 177 históricos,
-- a propósito. La variante estricta por conteo también arranca en 0 hoy.
-- ============================================================================
,inv27 AS (
  SELECT 'INV27: todo cobro deja rastro en op_log (desde 2026-08-20, gracia 48h)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE COALESCE(p.ocurrido_en, p.fecha_pago) >= TIMESTAMPTZ '2026-08-20 00:00-06'
      AND COALESCE(p.ocurrido_en, p.fecha_pago) < now() - INTERVAL '48 hours'
      AND NOT EXISTS (
        SELECT 1 FROM public.op_log o
         WHERE o.tenant_id = p.tenant_id
           AND o.entidad = 'cuotas' AND o.entidad_id = p.cuota_id
           AND o.tipo_op IN ('cobro', 'cobro_recuperado'))
  ) t
)

-- ============================================================================
-- INV 28: el invariante #4 tiene DOS sumandos
-- (`recaudado_caja = SUM(pagos) - SUM(saldos_favor devuelto)`) y los 20
-- chequeos vigentes miran solo el primero. Bucketea por `fecha_devolucion` y
-- `fecha_pago::date` — local-naive A PROPÓSITO, igual que el arqueo
-- (regla 1b: el wall-clock de fecha_pago sostiene el bucketing). Solo
-- `metodo='efectivo'`: una devolución en efectivo no sale de una transferencia.
-- PREVENCIÓN PURA: hoy hay 0 filas tipo='devuelto' en toda la base, pero
-- C$18.207 acreditados esperando a que alguien los aplique.
-- El `ejemplo_ids` devuelve `cobrador_id@fecha`, no un uuid: la violación es
-- del PAR, no de una fila.
-- ============================================================================
,inv28 AS (
  SELECT 'INV28: devoluciones del día <= efectivo cobrado ese día (#4 caja neta)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(clave, ', ' ORDER BY clave), '') AS ejemplo_ids
  FROM (
    SELECT d.cobrador_id::text || '@' || d.fecha_devolucion::text AS clave
    FROM public.saldos_favor d
    WHERE d.tipo = 'devuelto' AND d.cobrador_id IS NOT NULL AND d.fecha_devolucion IS NOT NULL
    GROUP BY d.tenant_id, d.cobrador_id, d.fecha_devolucion
    HAVING SUM(d.monto) > COALESCE((
        SELECT SUM(p.monto_cordobas) FROM public.pagos p
         WHERE p.tenant_id = d.tenant_id AND p.cobrador_id = d.cobrador_id
           AND p.anulado = false AND p.metodo = 'efectivo'
           AND p.fecha_pago::date = d.fecha_devolucion), 0) + 0.005
  ) t
)

-- ============================================================================
-- INV 29: sin cobrador+fecha la devolución no cae en NINGÚN bucket del arqueo
-- (el ISP sigue mostrando en caja plata que ya devolvió); sin recibo no hay
-- papel de la salida de efectivo. Las tres columnas son NULLABLE y no hay
-- CHECK que las exija. Va de la mano de INV28: sin INV29, INV28 es EVADIBLE
-- (una devolución sin cobrador ni fecha se saltea su GROUP BY).
-- ============================================================================
,inv29 AS (
  SELECT 'INV29: devolución de saldo con cobrador, fecha y recibo (#2/#4)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT sf.id
    FROM public.saldos_favor sf
    WHERE sf.tipo = 'devuelto'
      AND (sf.cobrador_id IS NULL OR sf.fecha_devolucion IS NULL OR sf.recibo_id IS NULL)
  ) t
)

-- ============================================================================
-- INV 30: la moneda es el único ángulo del modelo contable cuyo SÍ es por
-- código y no por datos: los 31.826 pagos son todos NIO, efectivo, vuelto 0.
-- INV1 verifica la CONSISTENCIA de la ecuación, no la SANIDAD de sus factores:
-- con tasa=0 pasa a exigir monto_cordobas+vuelto=0, y un pago marcado NIO con
-- tasa 36 cumple igual si monto_original se guardó 36 veces más chico.
-- Supuesto NIO => tasa=1 verificado al 100% sobre los 31.826 pagos.
-- ============================================================================
,inv30 AS (
  SELECT 'INV30: moneda y tasa coherentes en pagos vivos (#3)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE p.anulado = false
      AND (p.tasa_conversion IS NULL OR p.tasa_conversion <= 0
           OR p.monto_original IS NULL OR p.monto_original <= 0
           OR (p.moneda = 'NIO' AND ABS(p.tasa_conversion - 1) > 0.0001))
  ) t
)

-- ============================================================================
-- INV 31: el crédito por excedente (0127) se escribe en DOS tablas desde el
-- CLIENTE, en la misma writeTransaction, y nadie verifica el puente.
-- Si entra SOLO el cargo: la cuota se descuenta sin consumir saldo -> el
-- cliente usa el mismo crédito infinitas veces. Si entra SOLO el saldo: se
-- consume el crédito sin descontar la cuota. Ninguno rompe INV14 (mira la suma
-- de los cargos que SÍ llegaron) ni INV15 (mira el neto de saldos_favor).
-- Prefijo saldo:/cargo: igual que INV10, para saber a qué tabla ir.
-- ============================================================================
,inv31 AS (
  SELECT 'INV31: crédito aplicado <-> cargo credito_aplicado, mismo monto (#4)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(ofensor, ', ' ORDER BY ofensor), '') AS ejemplo_ids
  FROM (
    SELECT 'saldo:' || sf.id::text AS ofensor
    FROM public.saldos_favor sf
    LEFT JOIN public.cargos_extra ce ON ce.id = sf.cargo_id
    WHERE sf.tipo = 'aplicado'
      AND (ce.id IS NULL OR ce.tipo <> 'credito_aplicado' OR ABS(sf.monto - ce.monto) > 0.01)
    UNION ALL
    SELECT 'cargo:' || ce.id::text
    FROM public.cargos_extra ce
    WHERE ce.tipo = 'credito_aplicado'
      AND NOT EXISTS (SELECT 1 FROM public.saldos_favor sf
                       WHERE sf.cargo_id = ce.id AND sf.tipo = 'aplicado')
  ) t
)
```

Y al final del archivo, después de `UNION ALL SELECT * FROM inv20`:

```sql
UNION ALL SELECT * FROM inv21
UNION ALL SELECT * FROM inv22
UNION ALL SELECT * FROM inv23
UNION ALL SELECT * FROM inv24
UNION ALL SELECT * FROM inv25
UNION ALL SELECT * FROM inv26
UNION ALL SELECT * FROM inv27
UNION ALL SELECT * FROM inv28
UNION ALL SELECT * FROM inv29
UNION ALL SELECT * FROM inv30
UNION ALL SELECT * FROM inv31
ORDER BY invariante;
```

> **Sin estas 11 líneas el cambio no chequea nada.** Postgres acepta CTEs no usadas sin error: se "aplica" el invariante y nunca corre. Es el modo de falla más silencioso de todo este documento.

### Resultado de hoy contra producción

| Invariante | Hoy | Lectura |
|---|---|---|
| INV21 oldest-first | **0** | verificado hoy. Cubre el invariante #11, el único que no tenía NINGUNA red |
| INV22 recibo vivo → pago vivo | **0** | 854 recibos anulados vs 879 pagos anulados: los 25 de diferencia son pagos anulados que nunca tuvieron recibo (pre-0186), no hay papel circulando |
| INV23 exactamente 1 recibo vivo | **0** | sobre 30.947 pagos vivos |
| INV24 pago vivo sobre cuota anulada | **0** | las 1.106 cuotas anuladas tienen `monto_pagado = 0` |
| INV25 red 0234 | **0** | anclado a ventana de servicio. **Anclado al mes calendario daría 14** — todos falsos |
| INV26 atribución de cancelación | **0** | verificado hoy. 94 históricos quedan bajo el corte |
| INV27 op_log del cobro | **0** | verificado hoy, **con y sin** la gracia de 48 h |
| INV28 devoluciones ≤ efectivo | **0** | trivial: 0 filas `tipo='devuelto'` en toda la base |
| INV29 devolución imputable | **0** | trivial, misma razón |
| INV30 moneda y tasa | **0** | supuesto NIO⇒tasa=1 se cumple en los 31.826 |
| INV31 puente crédito↔cargo | **0** | trivial: 0 filas `tipo='aplicado'` |

**Ninguno da > 0, así que no hay nada que reformular.** El que estuvo a punto de dar > 0 —"cuota viva con período posterior a la cancelación", anclado al mes calendario, 14 hits— **está descartado y hay que dejarlo escrito con nombre y apellido** para que nadie salga a "arreglar" 14 prorrateos correctos: contratos 000995, 00597, 0573, 0639, 0771, 0902, 1331, 1619, 2478, 3779 de Mairena y 00561, 0193, 265, 324 de Telenet.

**Vigilancia del INV31**, para cuando aparezca la primera fila `'aplicado'`: `saldos_favor.cargo_id` es `ON DELETE SET NULL`. Si el flujo de reversión BORRA el cargo en vez de escribir una fila `'revertido'`, la primera rama se enciende sin que haya bug. Hay que verificarlo antes de la primera aplicación real de crédito.

---

## LO QUE RECOMIENDO NO TOCAR (y por qué)

1. **No condonar a los 28 clientes suspendidos (C$89.153,01).** Es cartera cobrable y el estado es reversible. Perdonarla es lo más dañino que se le puede hacer a la caja de un ISP, y con `cargos_extra` sobre 132 cuotas es irreversible en la práctica.
2. **No prender `cobranza.ajustes_habilitados`.** Sus topes son **solo client-side** (`descuento_dialog.dart:98`), sin enforcement server, y `ajuste_max_monto = 0` desactiva el tope por monto — un descuento por monto fijo esquiva el porcentual. Prenderlo abre descuento discrecional tenant-wide sobre 5.500 clientes.
3. **No reimplementar `baja_deuda` del lado cliente.** Ya existe como RPC `security definer`, online, super_admin-only → no toca el camino offline del cobrador ni la cola de PowerSync. Una versión con `writeTransaction` sí lo tocaría: encolada offline y reproducida después, corre contra el guard 0220 y el trigger 0234.
4. **No backfillear** las ~194 resoluciones de solicitudes previas al 12/08, ni los 177 cobros de julio, ni reescribir el `actor_label` "System Admin" de los 12.364 cobros de la carga histórica. `op_log` es append-only y client-written; meterle filas o nombres inferidos por SQL rompe su semántica. **La atribución de dinero NO se perdió**: `pagos.cobrador_id` y `recibos.cobrador_id` tienen **0 NULL** sobre 31.826 y 31.801 filas, y toda la reportería agrupa por ahí (AGENTS §3.5 4b).
5. **No agregar `cuotas` a `_espejosLocales`.** Silenciaría `cargos_neto`/`estado`/`monto_pagado`, que son justo donde un rechazo real significa plata mal contabilizada (invariantes #7 y #10). **Pero documentar el acoplamiento**, que hoy no está en ningún lado: los espejos de cuotas no generan avisos **no** por esa lista, sino porque `cuotas_update_cobrador_propio` (tenant + `rol='cobrador'`, sin más) deja a cualquier cobrador actualizar cualquier cuota de su tenant → el UPDATE siempre devuelve 1 fila. **El día que alguien estreche esa policy por seguridad, cada cobro genera una alarma roja sobre la tabla de plata.** Va como nota en `connector.dart` y en la receta R10 de `ARQUITECTURA.md`.
6. **No agregar `cobradores: {dashboard_pin}` a `_espejosLocales`.** El write local ni siquiera llega a la cola (B5). El fix es el otro.
7. **No meter un insert de `op_log` dentro de `sync_rechazo_descartar`** (ver Paso 6: NOT NULL + FK a tenants, huérfanas reservadas al super_admin, sin bloque `exception`, y `entidad_id` colgando de una cuota que en el caso 23503 **no existe**).
8. **No agregar los 8 candidatos de invariante descartados**, en especial el del mes calendario. Los otros: cuota sin contrato (2 hits, manuales del Test Tenant, válidas por diseño), período distinto del día 1 (las mismas 2), oldest-first con 'parcial' (1 hit sembrado), `recibo.cobrador_id = pago.cobrador_id` (0, sin camino de divergencia), huecos de correlativo (ya existe `recibos_huecos()` con su propio triage y `huecos_ignorados`), `fecha_pago` futura (el reloj del device se desfasa, sin daño contable).
9. **No tocar `dashboard_seed.sql`.** Sus fechas son FIJAS (máximo 2026-08-11) y nunca cruzan el corte; y el seed **borra pagos/cuotas/recibos pero NO borra `op_log`**, así que meterle inserts hace que cada re-siembra acumule filas sobre ids deterministas que van a **TAPAR violaciones futuras** del Test Tenant. Si algún día molesta, el filtro correcto es estructural (`p.ocurrido_en IS NOT NULL`: los 86 pagos con NULL de toda la base son exactamente los del seed).
10. **No agregar un invariante de prorrateo.** Un monto prorrateado mal es **aritméticamente indistinguible** de uno bien: para detectarlo habría que reimplementar `ventanaServicio`/`estadoServicio` en SQL, con el riesgo de que la copia derive del original. Su red son los tests de `prorrateo.dart` — y ahí sí conviene verificar que exista un caso con `dia_pago ≠ 1` (con `dia_pago = 1` el bug es invisible, regla 1c).
11. **No tocar el raster/transporte GLOBAL de impresión** aunque B11 encuentre algo. Arreglar un modelo puntual tocando el path compartido ya rompió a toda la flota (v0.22.10-13).
12. **No meter la regla del `.select('id')` al checklist de audit de `AGENTS.md`.** Ese checklist es para clases de bug cross-cutting; una expresión en un archivo lo diluye. Va dentro del comentario, que es donde el que edita la línea la va a ver.

---

## COMO QUEDA LA RED DESPUES

Lo que **hoy pasaría desapercibido** y a partir de este plan se detecta:

**Se detecta el mismo día que se corren los invariantes:**
- Un cobrador cobra agosto dejando julio impago porque dos devices offline no se vieron. **Hoy no lo detecta absolutamente nada** — no hay trigger server por decisión de producto, y el guard del cliente es ciego al multi-device (INV21).
- Un lote de writes de `op_log` que se pierde mientras los pagos entran. Los 177 de julio se descubrieron **un mes después**, cruzando tablas a mano (INV27).
- Un cobro vivo sin comprobante válido, o dos recibos vivos para el mismo cobro. El incidente COL-00020..29 tuvo **19 días ciegos** hasta que una clienta reclamó por WhatsApp (INV22 + INV23).
- Un cliente al que se le sigue facturando después de la baja porque la red de 0234 se rompió en un `CREATE OR REPLACE`. Hoy es una función de trigger que corre en silencio: nadie se entera hasta que llama un cliente (INV25).
- La **primera** devolución de efectivo, la **primera** aplicación de crédito y el **primer** cobro en dólares — tres caminos que nunca se ejercieron en producción y que hoy se estrenarían sin ninguna verificación (INV28, INV29, INV30, INV31).
- Un pago vivo colgando de una cuota anulada: plata que entra al arqueo y al dashboard sin ninguna cuota que la explique. Ni INV2 (salta anuladas) ni INV12 (llega por contrato) lo miraban (INV24).

**Se detecta en el momento, en vez de nunca:**
- Un script SQL de limpieza que cancela contratos sin decir quién ni por qué: el CHECK lo rebota (el del 19/08 habría fallado, y dejó 57 cancelaciones sin actor).
- Un rechazo de patch o delete: pasa de ser **invisible para el ISP** (tenant NULL → solo super_admin) a llegarle a la oficina, que es quien puede hacer algo (B2).
- Un flujo de cobro nuevo o refactorizado que se despacha sin `OpLog.escribir`: el test de repo lo caza **en el commit**, no en el próximo deploy (B4).
- Alguien que "limpia" `.select('id')` a `.select('*')`: rompe el build en vez de convertir todos los patches sobre `cobradores` en descarte (B6).

**Deja de ser una pregunta sin respuesta:**
- "¿Quién lo hizo?" para: cambiar un rol, desactivar a un cobrador, resetear el PIN del dashboard de otro, prender o apagar un módulo de tenant, correr "Corregir invariantes" sobre un tenant entero, limpiar un cliente desde data-ops, y descartar un cobro rechazado. **Las siete son operaciones que hoy no dejan una sola línea en ningún lado.**

**Lo que sigue sin red, y hay que decirlo:** el **monto** del prorrateo. Un prorrateo mal calculado cierra la aritmética igual y ningún invariante puede verlo — es exactamente el hallazgo #1 del audit del 22, el único punto donde la app escribe un monto de plata equivocado por su cuenta. **"31 invariantes en cero" no significa "la plata está toda bien"**, y por eso la línea de ALCANCE del Paso 1 es parte del entregable, no un adorno.