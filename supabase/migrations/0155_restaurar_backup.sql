-- 0155 — Restaurar un backup de data-ops (módulo Operaciones, super_admin).
-- Deshace un borrado (limpiar_cliente / eliminar_contrato / eliminar_cliente)
-- re-insertando el snapshot jsonb de data_op_backups. El RPC ya guardaba el
-- snapshot (0146/0147) pero NO había forma de revertirlo desde la app — solo
-- SQL manual sobre el jsonb. Esto cierra ese ciclo.
--
-- CLAVE — triggers desactivados durante la re-inserción
-- (`session_replication_role = replica`): si los triggers corrieran, insertar el
-- contrato dispararía la GENERACIÓN de cuotas (→ duplicados) y el insert de pagos/
-- cargos recalcularía monto_pagado/cargos_neto. El snapshot YA es contablemente
-- consistente (se capturó del estado real antes de borrar) → lo restauramos TAL
-- CUAL. Tras restaurar conviene correr "Verificar invariantes" (0153).
--
-- ROBUSTO: `on conflict do nothing` (no pisa data actual ni falla si algo ya
-- existe → idempotente, re-restaurar es no-op) y `jsonb_populate_recordset` (drift
-- de schema OK: columna nueva → NULL/default; columna vieja en el jsonb → ignorada).
-- Orden de tablas = orden FK (padres antes que hijos). 'cliente' → tabla clientes.

create or replace function public.super_admin_restaurar_backup(
  p_backup_id uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  v_tenant uuid; v_operacion text; v_label text; v_snapshot jsonb;
  v_restaurados jsonb := '{}'::jsonb; v_total int := 0;
  v_orden text[] := array[
    'cliente','contratos','cuotas','pagos','recibos','cargos_extra',
    'contrato_suspensiones','notificaciones_mora','saldos_favor',
    'cliente_etiquetas','fotos_cliente','visitas','op_log'];
  v_key text; v_table text; v_rows jsonb; v_n int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  select tenant_id, operacion, target_label, snapshot
    into v_tenant, v_operacion, v_label, v_snapshot
    from data_op_backups where id = p_backup_id;
  if v_tenant is null then raise exception 'El respaldo no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El respaldo no pertenece al tenant en contexto'; end if;

  set local session_replication_role = replica;

  foreach v_key in array v_orden loop
    v_rows := v_snapshot -> v_key;
    if v_rows is null or jsonb_typeof(v_rows) <> 'array' or jsonb_array_length(v_rows) = 0 then
      continue;
    end if;
    v_table := case when v_key = 'cliente' then 'clientes' else v_key end;
    execute format(
      'insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1) '
      'on conflict do nothing', v_table, v_table) using v_rows;
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    v_restaurados := v_restaurados || jsonb_build_object(v_key, v_n);
  end loop;

  set local session_replication_role = origin;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'restaurar', 'Restauró: ' || v_label, v_restaurados, p_backup_id, auth.uid(), p_actor_label);

  return jsonb_build_object(
    'ok', true,
    'operacion_original', v_operacion,
    'target_label', v_label,
    'restaurados', v_restaurados,
    'total', v_total);
end; $fn$;
