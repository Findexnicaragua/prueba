# GUÍA DE TROUBLESHOOTING SQL — CRM

> **Para quién es este documento:** una AI (o un humano técnico) a la que se
> le pide corregir un error de DATOS de un tenant directamente en Postgres
> (Supabase Dashboard → SQL Editor). Ejemplos: "este pago se anuló por
> error", "este cobro quedó en la cuota equivocada", "el monto de este pago
> está mal". El objetivo: que el fix toque EXACTAMENTE lo necesario y nada
> más, y que la app (offline-first) converja sola.
>
> **Cómo usarlo (instrucciones para la AI):**
> 1. Leé este archivo COMPLETO + las "Invariantes de dinero" de `AGENTS.md`.
> 2. Identificá el caso en el RECETARIO (§5). Si no existe, razoná con el
>    mapa de acoplamiento (§3) y los triggers (§4).
> 3. Respondé SIEMPRE con esta plantilla:
>    **(a)** SELECT de diagnóstico (ver el estado real antes de tocar) →
>    **(b)** el fix en UNA transacción (`BEGIN; ... COMMIT;`) con el
>    `tenant_id` SIEMPRE en los WHERE →
>    **(c)** verificación (SELECT post-fix + correr
>    `supabase/tests/invariantes_dinero.sql` → TODAS las filas (hoy 17,
>    INV1-INV17) en `violaciones = 0` — no hardcodees el conteo) →
>    **(d)** efectos colaterales esperados (qué recalculan los triggers,
>    qué va a ver el usuario en la app tras el próximo sync).
> 4. Ante CUALQUIER duda sobre el alcance, pedí el SELECT de diagnóstico
>    primero y decidí con data real. Nunca asumas.

---

## §1. Contexto mínimo de la app

SaaS multi-tenant de cobranza para ISPs (Nicaragua). **Postgres es la fuente
de verdad** ("server gana"); los clientes Flutter llevan una réplica SQLite
vía **PowerSync** y suben escrituras por una cola CRUD. Implicaciones para
quien corre SQL en el server:

- **Todo fix server-side baja SOLO a los dispositivos** en el próximo
  checkpoint de sync. NUNCA hay que "arreglar el teléfono": pedile al
  usuario que abra la app con internet y espere unos segundos.
- **Riesgo de pisada:** si un dispositivo tiene escrituras pendientes de
  subir sobre la MISMA fila, pueden pisar tu fix al sincronizar. Antes de
  un fix delicado: confirmar que el dispositivo del cobrador involucrado
  está sincronizado (sin cambios pendientes).
- En el SQL Editor corrés como rol privilegiado: **la RLS no te frena**.
  Por eso el `tenant_id` en el WHERE no es opcional: es tu único cinturón
  contra tocar data de otro ISP.
- Los **triggers SÍ corren** con tus UPDATEs (a diferencia del SQLite del
  cliente). Esto es una VENTAJA: casi nunca hay que recalcular columnas
  derivadas a mano (§4).

## §2. Reglas de oro (violarlas = romper el negocio)

1. **`op_log` es APPEND-ONLY y lo escribe el CLIENTE** (la app, dentro de su
   `writeTransaction`). Jamás UPDATE/DELETE ahí; para "deshacer" se agregan
   filas nuevas. NO hay triggers de audit en el server (`audit_log` se
   ELIMINÓ en 0140) → **un fix por SQL NO genera historial en la app**: el
   usuario no va a ver tu corrección en las pantallas de historial, y el
   único rastro del fix es tu propio reporte (SQL + diagnóstico).
2. **`inv_movimientos` es un LEDGER append-only.** Ídem.
3. **Soft-delete, no DELETE:** pagos y cuotas se ANULAN (`anulado=1` /
   `estado='anulada'`), nunca se borran. Excepción legítima de DELETE:
   `cargos_extra` (la reversión de ajustes/descuentos borra físico; rastro
   solo si el CLIENTE emitió `op_log` — un DELETE por SQL no deja ninguno,
   ver regla 1).
4. **Nunca tocar columnas derivadas a mano** sin agotar la vía del trigger:
   `cuotas.monto_pagado`, `cuotas.cargos_neto` y `cuotas.estado` los
   mantienen triggers a partir de `pagos` y `cargos_extra`. Tocá la fila
   FUENTE y dejá que recalculen. (Excepción documentada en T-CUOTA-MONTO.)
5. **Coherencia de moneda (invariante #3):** si tocás `monto_cordobas`,
   revisá `monto_original` y `tasa_conversion`:
   `monto_original × tasa ≈ monto_cordobas + vuelto_cordobas`.
6. **Timestamps:** `ocurrido_en`/`aplicado_en`/`anulado_en` van en **UTC**
   (ISO con `Z` o `now()`). `fecha_pago` y `tickets.created_at` son
   **local-naive A PROPÓSITO** (sin `Z`, hora de Nicaragua): NO los
   normalices — los reportes los bucketean crudos.
7. **No deshabilites triggers** (`session_replication_role` etc.). Si un
   guard te rechaza (P0001), es información: o el fix está mal planteado,
   o hay que satisfacer la condición del guard (p.ej. un setting).
8. **Una transacción por fix** y verificación después. Si la verificación
   falla, `ROLLBACK` mental: revisá antes de seguir tocando.
9. **Reportes/recaudado/dashboards NO se "arreglan"**: son fórmulas sobre
   `pagos`/`cuotas`/`saldos_favor`. `recaudado_caja` (el TOTAL NETO del
   arqueo) = `SUM(pagos.monto_cordobas no anulados) − SUM(saldos_favor
   devuelto)`; el dashboard y el "ingreso bruto" del arqueo muestran el
   BRUTO (`SUM(monto_cordobas)` sin restar devoluciones) **a propósito** —
   solo divergen del neto si hubo devolución de saldo a favor en efectivo,
   no es bug. Arreglada la fila fuente, todo cuadra solo en todas las
   pantallas.
10. **Después de TODO fix de dinero:** correr
    `supabase/tests/invariantes_dinero.sql` → TODAS las filas (hoy 17,
    INV1-INV17) en `violaciones = 0`. Es no-negociable.

## §3. Mapa de acoplamiento — "si toco X, ¿qué arrastra?"

### Dominio DINERO (el grafo caliente)

```
contratos ──genera(trigger server)──▶ cuotas ◀──recalculan── pagos
    │                                  ▲  ▲                    │
    │ (total = precio_mensual×meses,   │  └──recalculan── cargos_extra
    │  se CALCULA en cliente, no       │                   (origen: cobro/
    │  hay columna que arreglar)       │                    ajuste/promo/
    │                                  │                    liquidacion/
    └── estado: activo/completado/     │                    puente/credito;
        cancelado (cancelado=terminal) │                    pago_id si nació
                                       │                    de un cobro)
recibos ──pertenece a──▶ pagos    notificaciones_mora ──según── cuotas
(numero_completo = prefijo-#####,  (resuelta/reabierta por triggers
 UNIQUE por cobrador+prefijo)       al pagar/anular)

saldos_favor (libro append-only a nivel CLIENTE: acreditado/aplicado/
 devuelto/condonado/revertido). Aplicar crédito = cargos_extra con
 origen='credito' tipo='credito_aplicado', que RESTA del saldo canónico
 de la cuota SIN tocar pagos — el crédito NO es un pago, no toca caja.

op_log ◀── lo escribe el CLIENTE (no hay triggers de audit; audit_log
 se eliminó en 0140) — tu fix por SQL NO deja rastro acá
```

**Tocar `pagos`** arrastra: `cuotas` (recalc automático), `recibos` (si
anulás/des-anulás, su recibo acompaña), `cargos_extra` (anular BORRA los
descuentos con ese `pago_id` — trigger 0115; des-anular NO los restaura),
`notificaciones_mora` (reabre/resuelve). Reportes, dashboard, arqueo y
recaudado del contrato derivan solos.

**Tocar `cargos_extra`** arrastra: `cuotas.cargos_neto` + `estado`
(triggers 0075/0117). Nada más.

**Tocar `saldos_favor`**: solo INSERT de movimientos nuevos (append-only;
"deshacer" una acreditación = fila nueva `tipo='revertido'`, nunca editar
filas). El saldo NO es una columna: `disponible = SUM(+acreditado) −
SUM(aplicado+devuelto+condonado+revertido)`, y el guard
`trg_saldos_favor_no_sobregiro` (0127) rechaza todo movimiento que lo
deje < 0. El `monto` va SIEMPRE positivo: el signo lo da el `tipo`.

**Tocar `cuotas.estado` a 'anulada'** arrastra: CASCADA que anula sus
pagos asociados (trigger 0023) → y esos pagos arrastran sus recibos y
descuentos. Des-anular una cuota exige deshacer la cascada A MANO (T2).

**NO se tocan entre sí:** dinero ↔ inventario/tickets/incidentes/red/
geografía. Un fix de pago JAMÁS toca equipos ni tickets. La única unión es
`ticket_materiales` ↔ inventario (otro dominio, mismo principio).

### Dominio INVENTARIO/TICKETS (resumen)

`inv_seriales.estado` tiene guard de transiciones (0118): instalar exige
venir de `en_stock`. El stock NO es una columna: se deriva del ledger
`inv_movimientos`. Tickets: `correlativo` UNIQUE por tenant con
re-asignación automática en conflicto (0116).

### Catálogos y settings

`settings` por tenant (clave/valor jsonb): los super-only tienen
`editable_por='super_admin'`. Los guards de dinero LEEN settings
(`setting_bool`/`setting_number`) — un INSERT de ajuste por SQL respeta el
guard: exige `cobranza.ajustes_habilitados=true`, motivo y topes.

## §4. Triggers que corren SOLOS con tu SQL (tabla de referencia)

| Tocás | Trigger | Efecto automático |
|---|---|---|
| `pagos` I/U/D | `recalcular_cuota_desde_pagos` (0117) | `cuotas.monto_pagado` y `estado` de la cuota |
| `pagos.anulado→true` | `trg_pagos_revertir_descuentos` (0115) | BORRA descuentos `cargos_extra` con ese `pago_id` |
| `pagos` U (rol cobrador) | `trg_pagos_guard_cobrador` (0116) | rechaza si settings OFF (a vos como postgres no te aplica) |
| `cargos_extra` I/U/D | `actualizar_neto` (0075) + recalc (0117) | `cuotas.cargos_neto` y `estado` |
| `cargos_extra` I/U con `origen='ajuste'` | `trg_cargos_ajuste_guard` (0117) | exige setting ON + motivo + tipo descuento_* + topes |
| `cuotas.estado→'anulada'` | `cuotas_anular_pagos_asociados` (0023) | anula los pagos de esa cuota (cascada) |
| `contratos.fecha_fin` UPDATE (acortar) | `trg_contratos_limpiar_cuotas_excedentes` (0023) | ⚠️ DELETE FÍSICO de cuotas `pendiente` con `fecha_vencimiento >= nueva fecha_fin` — irrecuperable, única excepción al principio "cuotas se anulan, no se borran" |
| `saldos_favor` INSERT | `trg_saldos_favor_no_sobregiro` (0127) | rechaza `aplicado`/`devuelto`/`condonado`/`revertido` que dejen el disponible del cliente < 0 |
| `cuotas` I/U/D · `contratos` U | `trg_cuotas_vmv` / `trg_contratos_vmv` (0150) | recalculan `clientes.vencimiento_mas_viejo` (color del pin del mapa) — NO tocar esa columna a mano, converge sola con tu fix |
| `cobradores` UPDATE de `rol` | `cobradores_freeze_rol` (0066) | rechaza el write directo; usá el RPC `set_cobrador_rol` (super_admin) |
| DELETE de `comunidades`/`inv_proveedores`/`inv_ubicaciones`/`red_puertos` | `trg_*_guard_borrado` (0102) | rechaza si el registro está en uso — primero desvincular |
| `pagos/cargos/recibos/visitas` I/U | `validar_tenant_coherente` (0082) | rechaza si `tenant_id` ≠ el del padre |
| `inv_seriales` U | guard transiciones (0118) | rechaza instalar sin venir de stock |
| `tickets` I | correlativo (0116) | re-asigna en conflicto |
| `cuotas.monto` U | **NINGUNO recalcula estado** | ⚠️ ver T-CUOTA-MONTO |

## §5. RECETARIO de casos comunes

> Formato: Diagnóstico → Fix → Verificación. Reemplazá `:tenant`, `:id` etc.
> SIEMPRE conseguí los UUIDs con el SELECT de diagnóstico, nunca de memoria.

### T1 — Des-anular un PAGO anulado por error

```sql
-- (a) Diagnóstico: el pago, su recibo y su cuota
select p.id, p.anulado, p.monto_cordobas, p.cuota_id, p.tenant_id,
       r.id as recibo_id, r.anulado as recibo_anulado, r.numero_completo,
       cu.estado, cu.monto_pagado
  from pagos p
  left join recibos r on r.pago_id = p.id
  join cuotas cu on cu.id = p.cuota_id
 where p.id = ':pago';
```
```sql
-- (b) Fix: des-anular pago + recibo. El trigger recalcula la cuota solo.
begin;
update pagos
   set anulado = false, anulado_en = null, anulado_por = null,
       motivo_anulacion = null
 where id = ':pago' and tenant_id = ':tenant';
update recibos
   set anulado = false, anulado_en = null, anulado_por = null
 where pago_id = ':pago' and tenant_id = ':tenant';
commit;
```
**⚠️ Colateral:** si el cobro original traía DESCUENTOS automáticos
(pronto pago), la anulación los BORRÓ (trigger 0115) y des-anular NO los
restaura → la cuota quedaría debiendo el descuento. **NO hay rastro
forense server-side para recuperarlos** (`audit_log` se eliminó en 0140).
Los datos del descuento borrado solo pueden reconstruirse desde:
1. **`op_log`**, si el cliente emitió la intención del cobro original
   (buscá las filas de esa entidad/`op_id` con el descuento en su diff), o
2. **`data_op_backups`**, si el borrado vino de una operación de datos
   R19 (0146/0147).
Si no hay rastro en ninguno, reconstruí el monto desde el recibo impreso /
lo que reporte el cobrador y re-insertá el cargo con la receta T5.
**Verificación:** la cuota volvió a `pagada`/`parcial` con `monto_pagado`
correcto + invariantes TODAS en 0 (INV1-INV17).

### T2 — Des-anular una CUOTA anulada por error

```sql
-- (a) ¿Tenía pagos? (la cascada 0023 los anuló junto con ella)
select cu.id, cu.estado, cu.monto, cu.tenant_id,
       p.id as pago_id, p.anulado, p.anulado_en
  from cuotas cu left join pagos p on p.cuota_id = cu.id
 where cu.id = ':cuota';
```
- **Sin pagos** (caso típico de prueba): trivial —
```sql
update cuotas
   set estado = 'pendiente', anulada_en = null, anulada_por = null,
       motivo_anulacion = null
 where id = ':cuota' and tenant_id = ':tenant';
```
- **Con pagos**: además hay que des-anular los pagos que la cascada anuló
  (los que tienen `anulado_en` ≈ el `anulada_en` de la cuota) con la receta
  T1 (incluida la nota de descuentos). El estado final correcto lo
  recalcula el trigger al des-anular los pagos; si la dejás 'pendiente' y
  des-anulás pagos, el trigger la sube a parcial/pagada solo.

### T3 — Pago aplicado a la CUOTA EQUIVOCADA (mismo cliente u otro)

```sql
-- (b) Mover el pago: los triggers recalculan AMBAS cuotas (la vieja baja,
-- la nueva sube). El recibo no cambia (acompaña al pago por pago_id).
update pagos set cuota_id = ':cuota_correcta'
 where id = ':pago' and tenant_id = ':tenant';
```
**Guards:** 0078 exige que la cuota destino sea del MISMO tenant. Si el
pago tenía cargos automáticos ligados (`cargos_extra.pago_id = :pago`),
evaluá si esos cargos pertenecen a la cuota vieja o deben moverse también
(`update cargos_extra set cuota_id = ... where pago_id = ...`).
**Verificación:** ambas cuotas con estado/monto_pagado coherentes.

### T4 — MONTO de un pago mal registrado

```sql
-- Solo pagos NIO sin vuelto (los USD/con vuelto: anular y recobrar bien).
update pagos
   set monto_cordobas = :nuevo, monto_original = :nuevo
 where id = ':pago' and tenant_id = ':tenant'
   and moneda = 'NIO' and vuelto_cordobas = 0;
```
**Regla:** el nuevo monto NO puede exceder
`cuota.monto + cargos_neto − (pagado por otros pagos)` — INV4 (sobrepago)
te lo va a gritar si te pasás. El trigger recalcula la cuota.

### T5 — CARGO o DESCUENTO erróneo en una cuota

```sql
-- DELETE físico es legítimo acá; neto y estado recalculan solos. OJO:
-- server-side NO queda rastro (audit_log eliminado en 0140) y op_log solo
-- registra lo que emite el CLIENTE — este DELETE no aparece en el
-- historial de la app: dejá constancia en tu reporte.
delete from cargos_extra
 where id = ':cargo' and tenant_id = ':tenant';
```
Para AGREGAR un ajuste por SQL: respetá el guard — `origen='ajuste'` exige
`cobranza.ajustes_habilitados=true` en ese tenant, `tipo` descuento_*,
`descripcion` (motivo) no vacía y topes. Incluí SIEMPRE: `id` (uuid nuevo),
`tenant_id`, `cuota_id`, `cobrador_id` (el de la cuota — denormalizado para
sync), `aplicado_por`, `aplicado_en`/`ocurrido_en` en UTC, `client_local_id`
(uuid nuevo).

### T6 — Cuota manual creada por error

Anularla (no borrarla): `update cuotas set estado='anulada',
anulada_en=now(), motivo_anulacion='...' where id/tenant`. Si tenía pagos
buenos, primero movelos (T3).

### T-CUOTA-MONTO — Cambiar `cuotas.monto` (precio mal cargado)

⚠️ ÚNICO caso donde el estado NO se recalcula solo (no hay trigger sobre
`monto`). Hacelo en dos pasos:
```sql
update cuotas set monto = :nuevo where id = ':cuota' and tenant_id = ':tenant';
-- Forzar el recálculo de estado tocando la fuente (no-op de un cargo):
-- la forma más simple: un UPDATE inocuo sobre un pago de la cuota, o
-- recalcular a mano:
update cuotas cu
   set estado = case
     when cu.monto_pagado + 0.005 >= cu.monto + coalesce(cu.cargos_neto,0)
       then 'pagada'
     when cu.monto_pagado > 0 then 'parcial'
     else 'pendiente' end
 where cu.id = ':cuota' and cu.tenant_id = ':tenant'
   and cu.estado in ('pendiente','parcial','pagada');
```
Preferí SIEMPRE la alternativa de negocio: no tocar `monto` y aplicar un
AJUSTE (T5) — deja motivo y rastro.

### T7 — Recibo con numeración duplicada (post-fix no debería ocurrir)

```sql
select cobrador_id, prefijo, correlativo, count(*)
  from recibos where tenant_id = ':tenant'
 group by 1,2,3 having count(*) > 1;
-- Fix: al duplicado MÁS NUEVO asignarle MAX+1 de su (cobrador, prefijo)
-- y regenerar numero_completo = prefijo || '-' || lpad(correlativo::text,5,'0').
```

### T8 — "Mover" algo de tenant → NO

`validar_tenant_coherente` (0078) lo bloquea y es a propósito. Lo correcto
es recrear la entidad en el tenant destino con los flujos de la app.

### T9 — Un dispositivo muestra data vieja/divergente

No es un problema de SQL. Orden: (1) abrir la app con internet y esperar el
checkpoint; (2) si persiste, cerrar sesión/entrar (re-sync); (3) último
recurso: reinstalar la app (la DB local se reconstruye del server — los
writes NO subidos se pierden: confirmar con el usuario antes).

## §6. Verificación estándar post-fix (SIEMPRE)

1. SELECT de las filas tocadas + sus dependientes (cuota del pago, etc.).
2. `supabase/tests/invariantes_dinero.sql` → **TODAS las filas (hoy 17,
   INV1-INV17), violaciones = 0**.
3. **No esperes rastro automático:** `audit_log` se eliminó (0140) y
   `op_log` lo escribe solo el CLIENTE — tu fix por SQL no queda
   registrado en ningún lado. El rastro ES tu reporte: dejá el SQL
   ejecutado + los SELECTs antes/después por escrito (BITÁCORA/ticket).
4. Avisarle al usuario qué va a ver en la app tras sincronizar.

## §7. Prohibido / fuera de alcance de un fix SQL

- UPDATE/DELETE en `op_log`, `saldos_favor` o `inv_movimientos`
  (append-only los tres).
- Tocar `auth.users` / passwords (eso va por las Edge Functions).
- Cambiar `settings.editable_por`, policies, triggers o funciones como
  parte de un "fix de datos" (eso es una MIGRACIÓN: otro proceso, ver
  `ARQUITECTURA.md` Receta R4/R10).
- DELETE de pagos/cuotas/recibos/clientes/contratos (soft-delete o flujos
  de la app).
- Fixes masivos multi-tenant sin un WHERE por tenant y sin dry-run
  (`select count(*)` primero con el MISMO where).

## §8. Apéndice — convenciones rápidas

- IDs: uuid v4 en todas las tablas; el cliente genera `client_local_id`
  aparte (poné uno nuevo si insertás filas).
- `tenant_id` NOT NULL en toda tabla operativa; denormalizados para sync:
  `cobrador_id` en pagos/recibos/cargos/cuotas/notificaciones.
- Dinero: numeric(10,2) en C$ (córdobas); USD solo en
  `monto_original`+`tasa_conversion` del pago.
- Día de negocio = Nicaragua UTC−6 sin DST (`America/Managua`); los crons
  corren 06:05 UTC.
- Fórmula canónica de saldo de cuota (idéntica en TODA la app):
  `monto + COALESCE(cargos_neto,0) − monto_pagado`.
