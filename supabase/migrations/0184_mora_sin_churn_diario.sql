-- 0184: mora — eliminar el CHURN DIARIO de sincronización de PowerSync
-- Diagnóstico 2026-07-10: "Data Synced" de PowerSync trepó a 24 GB con solo
-- ~11 dispositivos. Causa #1 medida (pg_stat): notificaciones_mora con 130.289
-- UPDATES en 63 días (5,7× la tabla entera).
--
-- POR QUÉ: el cron diario `actualizar_notificaciones_mora` hacía UPSERT con
-- `ON CONFLICT DO UPDATE SET dias_mora, monto_adeudado`. Como
-- `dias_mora = current_date - fecha_vencimiento - gracia` crece +1 CADA DÍA,
-- todos los días TODAS las filas de mora vencida (~23k) cambian de verdad →
-- PowerSync re-sincroniza la tabla ENTERA a CADA dispositivo, todos los días
-- (y escala con la cartera vencida).
--
-- CLAVE (auditado): los campos GUARDADOS `dias_mora`/`monto_adeudado` son
-- ESCRITURA-MUERTA — NADIE los lee. Los 4 consumidores del cliente (reporte de
-- mora `reporte_mora_pdf`/`reportes_admin_screen`, colas `colas_servicio_provider`,
-- `cola_card`) los calculan EN VIVO desde `cuotas` (`... AS dias_mora`). El
-- estado que SÍ importa (`vista_en`/`resuelta_en`, que alimenta el badge) lo
-- manejan los mirrors del cliente + triggers, NO este cron.
--
-- FIX: el cron solo INSERTA filas para cuotas recién vencidas; ya NO re-actualiza
-- las existentes (`ON CONFLICT DO NOTHING`). Cero lectores afectados, badge de
-- mora intacto, resolución intacta. Mata el churn diario para siempre.
-- Server-only: sin cambio de app ni de sync-rules (la tabla sigue sincronizada
-- por su estado vista_en/resuelta_en, que casi no cambia).
CREATE OR REPLACE FUNCTION public.actualizar_notificaciones_mora(p_tenant_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- row_security off: el cron corre sin auth.uid(); SECURITY DEFINER da rol
  -- postgres (BYPASSRLS), lo explicitamos por las dudas.
  set local row_security = off;

  insert into public.notificaciones_mora (
    tenant_id, cuota_id, cliente_id, cobrador_id,
    dias_mora, monto_adeudado
  )
  select
    cu.tenant_id,
    cu.id,
    cu.cliente_id,
    cu.cobrador_id,
    greatest((current_date - cu.fecha_vencimiento) - v_dias_gracia, 0),
    cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
    -- Solo contratos ACTIVOS (0124): suspendido/cancelado salen del flujo de
    -- mora del cobrador aunque conserven cuotas vivas.
    and coalesce(
          (select ct.estado from public.contratos ct where ct.id = cu.contrato_id),
          'activo') = 'activo'
  -- ANTES: `do update set dias_mora = excluded.dias_mora, monto_adeudado = ...`
  -- → reescribía TODAS las filas vencidas cada día (dias_mora +1/día) → el #1
  -- driver del Data Synced. Esos campos son escritura-muerta (se calculan en
  -- vivo desde cuotas). AHORA `do nothing`: solo alta de cuotas recién vencidas;
  -- las existentes NO se tocan → sin churn diario.
  on conflict (cuota_id) do nothing;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$function$;
