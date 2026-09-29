-- 0260_desactivar_cliente_cancela_y_condona.sql
--
-- QUE: desactivar un cliente pasa a CANCELAR todos sus contratos vivos, lo que
-- a su vez CONDONA la deuda (via el trigger de 0259). Solo el historico -lo ya
-- pagado- sobrevive.
--
-- REGLA (dueño, 2026-08-26): "si un cliente esta DESACTIVADO, significa que
-- todo queda condonado; incluso si un contrato esta suspendido tiene que pasar
-- a cancelado, porque no puede quedar nada pendiente. Obviamente solo el
-- historico cuenta."
--
-- POR QUE ESTO DA VUELTA LA 0220: aquel guard bloquea desactivar a un cliente
-- con deuda, y su comentario cita la regla ANTERIOR del dueño ("mientras tenga
-- deuda debe seguir ACTIVO"). Con la regla nueva la deuda ya no es el motivo
-- para impedir la baja: es lo que la baja resuelve. El guard queda apuntando al
-- reves, asi que se REEMPLAZA por la cascada.
--
-- ALCANCE medido en produccion antes de escribir esto (2026-08-26):
--   9 clientes desactivados tienen contratos vivos -los 9 SUSPENDIDOS, ninguno
--   activo- con C$18.740,65 de deuda en 27 cuotas. Cero pagos en cuarentena en
--   toda la poblacion, asi que ningun caso queda atrapado en la rama (a) de
--   `condonar_deuda_contrato`.
--   4 de Mairena (3 de ellos SIN deuda) y 5 de Telenet.
--
-- QUE NO HACE, A PROPOSITO: el camino inverso. Hay 45 clientes ACTIVOS sin
-- ningun contrato vivo (39 Mairena, 6 Telenet) y NO se los desactiva: bajo esta
-- misma regla eso les borraria la deuda, y entre ellos estan los contratos que
-- 0258 preservo porque el ISP los sigue cobrando. Desactivar es una decision
-- del ISP, no un barrido automatico.

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 1 — La cascada, escrita UNA vez
-- ═══════════════════════════════════════════════════════════════════════════
-- Se usa desde el trigger (con `auth.uid()`) y desde el backfill (con un actor
-- explicito). Por eso el actor es PARAMETRO y no se lee adentro: un backfill
-- por `supabase db query` corre sin JWT, y `a_trg_contratos_guard_cancelacion`
-- (0254) rechaza con 23514 toda transicion a 'cancelado' sin `cancelado_por` y
-- sin motivo.
--
-- NO condona por su cuenta: solo mueve el contrato a 'cancelado'. La
-- condonacion la hace `zz_contratos_condonar_deuda` (0259), que dispara en esa
-- misma transicion con las tres ramas ya auditadas -sin pago: anular; con
-- abono: `monto = pagado`; con pago en cuarentena: NO se toca-. Duplicar esa
-- aritmetica aca seria un segundo lugar donde la regla puede divergir.
CREATE OR REPLACE FUNCTION public.cancelar_contratos_por_baja_cliente(
  p_cliente uuid,
  p_actor   uuid,
  p_motivo  text DEFAULT 'Cliente desactivado'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_ct       record;
  v_op       uuid := gen_random_uuid();
  v_n        int  := 0;
  v_tenant   uuid;
BEGIN
  IF p_cliente IS NULL OR p_actor IS NULL THEN
    -- Sin actor no se puede firmar la baja (0254). Se devuelve el motivo en vez
    -- de tirar: el llamador decide si eso aborta o solo se registra.
    RETURN jsonb_build_object('contratos', 0, 'motivo', 'sin_actor');
  END IF;

  SELECT tenant_id INTO v_tenant FROM public.clientes WHERE id = p_cliente;
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('contratos', 0, 'motivo', 'cliente_inexistente');
  END IF;

  FOR v_ct IN
    SELECT id, codigo, estado
      FROM public.contratos
     WHERE cliente_id = p_cliente
       AND estado IN ('activo', 'suspendido')
     ORDER BY created_at
  LOOP
    -- `cancelado_en = now()` a proposito, NO la fecha de la suspension: el gate
    -- de 0259 exige `cancelado_en >= 2026-08-24`, asi que fechar la baja hacia
    -- atras dejaria el contrato cancelado CON la deuda viva — y el titular
    -- "Por cobrar" del dashboard excluye 'suspendido' pero NO 'cancelado', o
    -- sea que esa plata saltaria a la portada del ISP.
    UPDATE public.contratos
       SET estado              = 'cancelado',
           cancelado_en        = now(),
           cancelado_por       = p_actor,
           motivo_cancelacion  = p_motivo
     WHERE id = v_ct.id;

    INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                               actor_id, actor_label, accion, diff, ocurrido_en)
    VALUES (gen_random_uuid(), v_tenant, v_op, 'cancelacion', 'contratos', v_ct.id,
            p_actor,
            coalesce((SELECT nombre FROM public.cobradores WHERE id = p_actor),
                     'System Admin'),
            'update',
            jsonb_build_object(
              'campos', jsonb_build_array(
                jsonb_build_object('campo', 'estado',
                                   'antes', v_ct.estado, 'despues', 'cancelado')),
              'resumen', jsonb_build_object('motivo', p_motivo))::text,
            now());

    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('contratos', v_n, 'motivo', 'ok');
END $fn$;

REVOKE ALL ON FUNCTION public.cancelar_contratos_por_baja_cliente(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.cancelar_contratos_por_baja_cliente(uuid, uuid, text) IS
  'Regla 2026-08-26: desactivar un cliente cancela sus contratos vivos. La '
  'condonacion la hace el trigger de 0259 en la misma transaccion.';

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 2 — El guard de 0220 sale; entra la cascada
-- ═══════════════════════════════════════════════════════════════════════════
-- El guard viejo se DROPEA (no se deja en false ni comentado): mientras exista,
-- desactivar a un cliente con deuda sigue siendo imposible, que es exactamente
-- lo que la regla nueva viene a permitir.
DROP TRIGGER IF EXISTS trg_clientes_guard_desactivar ON public.clientes;
DROP FUNCTION IF EXISTS public.clientes_guard_desactivar_con_deuda_trg();

CREATE OR REPLACE FUNCTION public.clientes_baja_cancela_contratos_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  -- NUNCA levanta excepcion (misma decision que 0259): PowerSync clasifica
  -- P0001 como error PERMANENTE y DESCARTA la operacion. Si esto tirara, la
  -- desactivacion entera se perderia y el usuario no se enteraria. Se prefiere
  -- una deuda que sobrevive -visible, la caza INV19- antes que una baja que
  -- desaparece en silencio.
  BEGIN
    v_res := public.cancelar_contratos_por_baja_cliente(
               new.id, auth.uid(), 'Cliente desactivado');
    IF (v_res->>'motivo') <> 'ok' THEN
      RAISE LOG 'clientes_baja_cancela_contratos_trg: cliente=% motivo=%',
                new.id, v_res->>'motivo';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'clientes_baja_cancela_contratos_trg: cliente=% error=% (%)',
              new.id, SQLERRM, SQLSTATE;
  END;
  RETURN NULL;
END $fn$;

-- AFTER: la fila del cliente ya quedo en `activo = false` cuando corre esto.
-- Prefijo `zz_` para quedar despues de los demas BEFORE/AFTER de la tabla, por
-- la misma razon que 0259.
--
-- La condicion es sobre la TRANSICION, no sobre la fila: un re-put de PowerSync
-- sobre un cliente que YA estaba inactivo no la dispara. Sin eso, cada
-- sincronizacion de un cliente inactivo intentaria cancelar de nuevo (no haria
-- daño -no quedan contratos vivos- pero ensuciaria el `op_log`).
DROP TRIGGER IF EXISTS zz_clientes_baja_cancela_contratos ON public.clientes;
CREATE TRIGGER zz_clientes_baja_cancela_contratos
  AFTER UPDATE OF activo ON public.clientes
  FOR EACH ROW
  WHEN (new.activo = false AND old.activo IS DISTINCT FROM false)
  EXECUTE FUNCTION public.clientes_baja_cancela_contratos_trg();

COMMENT ON TRIGGER zz_clientes_baja_cancela_contratos ON public.clientes IS
  'Regla 2026-08-26: un cliente desactivado no puede tener nada pendiente. '
  'Cancela sus contratos vivos; 0259 condona la deuda en la misma transaccion.';

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 3 — Backfill de los 9 que ya estan desactivados
-- ═══════════════════════════════════════════════════════════════════════════
-- Estos NO los alcanza el trigger: su transicion `true -> false` ya ocurrio.
-- El actor es el admin del tenant, que es quien habria autorizado la baja; el
-- motivo dice de donde sale para que el historial no invente una razon.
DO $backfill$
DECLARE
  v_cli    record;
  v_actor  uuid;
  v_res    jsonb;
  v_total  int := 0;
BEGIN
  FOR v_cli IN
    SELECT DISTINCT c.id, c.tenant_id, c.codigo, c.nombre
      FROM public.clientes c
      JOIN public.contratos ct ON ct.cliente_id = c.id
     WHERE c.activo = false
       AND ct.estado IN ('activo', 'suspendido')
     ORDER BY c.codigo
  LOOP
    SELECT id INTO v_actor
      FROM public.cobradores
     WHERE tenant_id = v_cli.tenant_id AND rol = 'admin' AND activo
     ORDER BY created_at
     LIMIT 1;

    IF v_actor IS NULL THEN
      RAISE LOG '0260 backfill: sin admin para el tenant % (cliente %)',
                v_cli.tenant_id, v_cli.codigo;
      CONTINUE;
    END IF;

    v_res := public.cancelar_contratos_por_baja_cliente(
               v_cli.id, v_actor,
               'Cliente desactivado (alineacion regla 2026-08-26)');
    v_total := v_total + coalesce((v_res->>'contratos')::int, 0);
    RAISE LOG '0260 backfill: % (%) -> %', v_cli.codigo, v_cli.nombre, v_res;
  END LOOP;

  RAISE LOG '0260 backfill: % contratos cancelados en total', v_total;
END $backfill$;

COMMIT;
