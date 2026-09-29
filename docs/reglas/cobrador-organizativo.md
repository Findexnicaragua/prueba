# Regla: el cobrador asignado organiza; el que cobró es otro dato

**Enunciado, en una línea.** `clientes.cobrador_id` dice **en qué lista o mapa
aparece** un cliente. **QUIÉN cobró** lo dice `pagos.cobrador_id` / `recibos.cobrador_id`,
y **toda la reportería agrupa por ESE campo**, nunca por el asignado.

**Por qué son dos cosas distintas.** El asignado es organizativo y cambia: se
reasigna una ruta, alguien se va, entra otro. Puede incluso ser NULL
("admin-managed": solo lo ven y cobran admin/admin_cobranza). El que cobró es un
hecho histórico: esa persona recibió esa plata ese día. **Reasignar un cliente NO
reescribe el historial de quién cobró** — si el arqueo o el reporte "por cobrador"
agruparan por el asignado, cada reasignación de ruta cambiaría los números de
meses ya cerrados.

**Dónde se enforça.** El arqueo (`arqueoSql`) agrupa por `pagos.cobrador_id` y
por `date(fecha_pago)`, sin joinear cuotas. El `cobrador_id` de `pagos` y `recibos`
es NOT NULL: es el usuario que registró el cobro, no el de la ficha.

**La denormalización, y su trampa.** `cobrador_id` está copiado en `contratos` y
`cuotas` para que el filtro de ruta sea barato, y lo mantiene el trigger server
`propagate_cobrador_id_from_cliente`. **Los triggers no corren en SQLite**, así que
todo INSERT desde Dart tiene que escribir la columna denormalizada a mano
(checklist #6 de `AGENTS.md`). Y ojo con el efecto lateral: ese trigger updatea
TODOS los contratos del cliente al reasignar, sin filtrar por estado — un `CHECK`
sobre contratos históricos puede quedar atrapado ahí (fue el caso de `0254`).

**Señal de alarma en una revisión:** un `GROUP BY` o un `WHERE` de reportería que
use `clientes.cobrador_id` o `cuotas.cobrador_id` en vez de `pagos.cobrador_id`.

```regla
simbolos:
  arqueoSql
  propagate_cobrador_id_from_cliente
prohibido:
docs:
  ARQUITECTURA.md -> §3.5 (4b)
  AGENTS.md -> Invariantes de dinero (cobrador)
superficies:
  AGENTS.md
  ARQUITECTURA.md
  BITACORA.md
  lib/features/admin/reportes/arqueo_query.dart
  lib/features/admin/reportes/reportes_admin_screen.dart
  supabase/migrations/0002_denormalize_cobrador.sql
  supabase/migrations/0016_fixes_finales.sql
  supabase/migrations/0017_fixes_2da_auditoria.sql
  supabase/migrations/0023_fixes_simulacion_e2e.sql
  supabase/migrations/0025_fix_b2_reasignacion_offline.sql
  supabase/migrations/0034_db_integrity_hardening.sql
  supabase/migrations/0068_consolidar_cascade_cobrador.sql
  supabase/migrations/0122_etiquetas_clientes.sql
  supabase/migrations/0174_cargos_extra_cobrador_null.sql
  supabase/migrations/0231_barrera_notas_no_pisa_al_server.sql
  supabase/migrations/0254_guard_cancelacion_atribuida.sql
  supabase/tests/invariantes_dinero.sql
  test/features/admin/dashboard/dashboard_numeros_test.dart
```
