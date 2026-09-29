-- 0252_sync_rechazos_historial.sql
--
-- Descartar un aviso de sincronizacion es DECLARAR PERDIDO UN COBRO REAL: hay
-- un recibo en papel y el cliente pago. Hoy `sync_rechazo_descartar` solo marca
-- `resuelto` y el tile desaparece de la unica lista que existe. Su hermano
-- `sync_rechazo_registrar` si deja rastro (`cobro_recuperado` en op_log).
--
-- EL MATIZ (por el que esta migracion es chica): la fila NUNCA se borra -
-- quedan `resuelto`/`resuelto_en`/`resuelto_por` y el `payload` completo para
-- siempre. Lo que falta NO es registro: es VISIBILIDAD y MOTIVO.
--
-- POR ESO NO se mete un insert de op_log adentro de `sync_rechazo_descartar`:
--   1. `op_log.tenant_id` es NOT NULL con FK a tenants, y 0247 reserva a
--      proposito las filas HUERFANAS (tenant_id NULL) al super_admin. Un
--      insert ahi las volveria imposibles de descartar.
--   2. La funcion no tiene bloque `exception`: cualquier error sube crudo y
--      deja la fila trabada. Descartar es la salida de emergencia del aviso
--      danado (el caso del identificador corrupto) - no se puede romper.
--
-- Se copia el precedente de 0242 (`recibos_huecos_ignorados`): una funcion
-- ADITIVA nueva, sin tocar la que la app ya llama.
--
-- ADEMAS: `p_motivo` con DEFAULT NULL. La app actual llama con solo `p_id` y
-- sigue andando igual; el dialogo de motivo llega con el build. CREATE OR
-- REPLACE no puede agregar parametros -> DROP + CREATE en la MISMA
-- transaccion, partiendo del cuerpo VIGENTE de 0247 (que conserva el orden
-- anclaje-ANTES-del-atajo-de-idempotencia: con el orden invertido, un aviso
-- ajeno ya resuelto contestaba "listo, ya estaba" en vez de "es de otra
-- empresa"; lo cazo la verificacion en vivo).

BEGIN;

ALTER TABLE public.sync_rechazos ADD COLUMN IF NOT EXISTS motivo text;

COMMENT ON COLUMN public.sync_rechazos.motivo IS
  'Por que se descarto el aviso. Lo escribe sync_rechazo_descartar(p_motivo). '
  'NULL en los descartes anteriores a 0252 y en los avisos aun pendientes.';

-- ---------------------------------------------------------------------------
-- Historial: incluye los RESUELTOS. Aditiva - `sync_rechazos_pendientes` (la
-- que la app llama hoy) no se toca. Misma forma de columnas que aquella, mas
-- como termino cada uno, para que el mapeo del cliente se reuse tal cual.
-- El gate es el MISMO `sync_rechazo_autorizado`: anclado al tenant en contexto,
-- con la rama de huerfanos para el super_admin.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_rechazos_historial()
RETURNS TABLE(id uuid, tabla text, registro_id text, codigo text, mensaje text,
              ocurrido_en timestamp with time zone, cobrador text,
              cliente_codigo text, cliente_nombre text, monto numeric,
              recibo_numero text, pago_id text,
              resuelto boolean, resuelto_en timestamp with time zone,
              resuelto_por_nombre text, motivo text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select sr.id, sr.tabla, sr.registro_id, sr.codigo, sr.mensaje,
         sr.ocurrido_en,
         co.nombre as cobrador,
         cl.codigo as cliente_codigo,
         cl.nombre as cliente_nombre,
         case when sr.tabla = 'pagos'
              then nullif(sr.payload->>'monto_cordobas','')::numeric
         end as monto,
         case
           when sr.tabla = 'recibos' then
             (sr.payload->>'prefijo') || '-' ||
             lpad(coalesce(sr.payload->>'correlativo','0'), 5, '0')
         end as recibo_numero,
         case when sr.tabla = 'recibos' then sr.payload->>'pago_id'
         end as pago_id,
         sr.resuelto,
         sr.resuelto_en,
         rp.nombre as resuelto_por_nombre,
         sr.motivo
  from public.sync_rechazos sr
  left join public.cobradores co on co.id = sr.cobrador_id
  left join public.cobradores rp on rp.id = sr.resuelto_por
  left join public.cuotas cu
         on sr.tabla = 'pagos'
        and cu.id = nullif(sr.payload->>'cuota_id','')::uuid
  left join public.clientes cl on cl.id = cu.cliente_id
  where public.sync_rechazo_autorizado(sr.tenant_id)
  order by sr.ocurrido_en desc
  limit 200;
$function$;

REVOKE ALL ON FUNCTION public.sync_rechazos_historial() FROM public;
REVOKE ALL ON FUNCTION public.sync_rechazos_historial() FROM anon;
REVOKE ALL ON FUNCTION public.sync_rechazos_historial() FROM service_role;
GRANT EXECUTE ON FUNCTION public.sync_rechazos_historial() TO authenticated;

-- ---------------------------------------------------------------------------
-- Descartar, con motivo opcional. Cuerpo VIGENTE de 0247 + el motivo.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.sync_rechazo_descartar(uuid);

CREATE FUNCTION public.sync_rechazo_descartar(p_id uuid, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tenant uuid := public.current_tenant_id();
  v_fila public.sync_rechazos%rowtype;
begin
  if v_tenant is null
     or not coalesce(public.is_super_admin()
                     or public.is_admin_or_cobranza(), false) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso para descartar avisos');
  end if;

  select * into v_fila from public.sync_rechazos where id = p_id;
  if v_fila.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese aviso ya no existe.');
  end if;
  -- Anclaje ANTES del atajo de idempotencia (lo cazó la verificación en vivo
  -- de 0246): con el orden invertido, un aviso AJENO ya resuelto contestaba
  -- "listo, ya estaba" en vez de "es de otra empresa".
  if not public.sync_rechazo_autorizado(v_fila.tenant_id) then
    return jsonb_build_object('ok', false,
      'error', 'Ese aviso es de otra empresa. Entrá a esa empresa para resolverlo.');
  end if;
  if v_fila.resuelto then
    return jsonb_build_object('ok', true, 'ya_estaba', true);
  end if;

  update public.sync_rechazos
     set resuelto = true, resuelto_en = now(), resuelto_por = auth.uid(),
         motivo = nullif(btrim(p_motivo), '')
   where id = p_id;
  return jsonb_build_object('ok', true);
end $function$;

-- Los grants se pierden con el DROP: se reponen EXACTAMENTE los que tenía
-- (postgres + authenticated; anon y service_role ya los había sacado 0247).
REVOKE ALL ON FUNCTION public.sync_rechazo_descartar(uuid, text) FROM public;
REVOKE ALL ON FUNCTION public.sync_rechazo_descartar(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.sync_rechazo_descartar(uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.sync_rechazo_descartar(uuid, text) TO authenticated;

COMMIT;

-- PostgREST cachea la firma de las funciones: sin esto, la app seguiria
-- llamando a la vieja (que ya no existe) hasta el proximo reload.
NOTIFY pgrst, 'reload schema';
