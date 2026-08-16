-- 0070_fix_audit_registrar_overload.sql
--
-- BUG: editar CUALQUIER setting (WhatsApp, tasa USD, nombre empresa, config de
-- cobranza, recibos, etc.) tiraba:
--   "function public.audit_registrar(uuid, unknown, uuid, text, jsonb, jsonb)
--    is not unique"
-- y la sincronización a Postgres se rechazaba, así que el valor NO persistía.
--
-- CAUSA RAÍZ: la migración 0069 agregó el overload de 8 args (con p_ocurrido_en)
-- pero NO dropeó el de 7 args que había dejado 0047. Ambos aceptan una llamada
-- de 6 args (rellenan sus DEFAULT), así que `audit_settings_trg` (0020) — el
-- único trigger viejo que sobrevivió al barrido de 0047 y todavía llama con
-- 6 args — no podía resolver a cuál de los dos invocar → ambigüedad.
--
-- Por qué solo settings fallaba: 0047 reemplazó los triggers específicos de
-- pagos/cuotas/clientes/recibos por el genérico `audit_changelog_trg` (que
-- llama con 8 args, sin ambigüedad), pero `trg_audit_settings` quedó afuera.
--
-- FIX (dos partes):
--   1. Eliminar el overload redundante de 7 args (causa raíz de la ambigüedad).
--   2. Modernizar `audit_settings_trg` para que invoque el de 8 args EXPLÍCITO:
--      ya no depende de la resolución por defaults (defensa en profundidad) y
--      conserva el audit por-clave limpio (mejor que el genérico, que logearía
--      el row completo de settings).
--
-- Solo función server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

-- 1. Eliminar el overload de 7 args que colisiona con el de 8 args (0069).
DROP FUNCTION IF EXISTS public.audit_registrar(
  uuid, text, uuid, text, jsonb, jsonb, text
);

-- 2. Reescribir el trigger de settings para invocar el de 8 args explícito.
--    (El trigger `trg_audit_settings` sigue enganchado; solo cambia el cuerpo.)
CREATE OR REPLACE FUNCTION public.audit_settings_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF new.valor IS DISTINCT FROM old.valor THEN
    PERFORM public.audit_registrar(
      new.tenant_id,           -- p_tenant_id
      'settings',              -- p_tabla
      new.id,                  -- p_registro_id
      new.clave,               -- p_campo
      to_jsonb(old.valor),     -- p_valor_anterior
      to_jsonb(new.valor),     -- p_valor_nuevo
      'update',                -- p_accion (explícito)
      NULL                     -- p_ocurrido_en (settings no tiene la columna)
    );
  END IF;
  RETURN new;
END;
$$;

COMMIT;
