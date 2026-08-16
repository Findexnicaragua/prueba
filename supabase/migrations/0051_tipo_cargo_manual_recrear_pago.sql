-- 0051: tipo_cargo_manual en cuotas + setting recrear_pago_anulado.

-- 1. Columna para clasificar cuotas manuales (filtrable en reportes).
ALTER TABLE public.cuotas ADD COLUMN IF NOT EXISTS tipo_cargo_manual text;

-- 2. Setting: toggle para permitir recrear pagos anulados.
INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'cobranza.recrear_pago_anulado', 'false'::jsonb, 'boolean', 'cobranza',
       'Permitir recrear pagos anulados por error', 'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;
