-- 0200 — `puede_cambiar_fecha_pago()` excluye al rol `lectura`
--
-- La función gatea las policies `contratos_cambiar_fecha` y
-- `cuotas_cambiar_fecha_*`. Su condición de rol es
-- `c.rol = 'admin' OR c.puede_cambiar_fecha`, así que un usuario migrado DESDE
-- `cobrador` a `lectura` la satisface: ni `set_cobrador_rol` ni el form limpian
-- ese flag al cambiar de rol (solo limpian `prefijo_recibo`).
--
-- Alcanzable por REST directo (no pasa por la cola de PowerSync, así que la
-- guardia del cliente no lo contiene). El espejo en Dart es el early-return de
-- `puedeCambiarFechaPagoProvider`.
--
-- Partido del cuerpo VIGENTE en la DB (verificado con pg_get_functiondef antes
-- de escribir esta migración).

CREATE OR REPLACE FUNCTION public.puede_cambiar_fecha_pago()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    coalesce((
      -- settings.valor es TEXT (0011 lo migró de jsonb a text serializado para
      -- el cliente SQLite); el cliente lo escribe con jsonEncode(bool) → 'true'
      -- /'false'. Comparar como texto (no como jsonb).
      select s.valor = 'true'
        from public.settings s
       where s.tenant_id = public.current_tenant_id()
         and s.clave = 'cobranza.cambio_fecha_habilitado'
    ), false)
    and coalesce((
      select (c.rol <> 'lectura' and (c.rol = 'admin' or c.puede_cambiar_fecha))
        from public.cobradores c
       where c.id = auth.uid()
    ), false);
$function$;
