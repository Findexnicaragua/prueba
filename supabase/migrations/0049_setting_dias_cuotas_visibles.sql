-- 0049: Setting para controlar cuántos días de cuotas futuras ve el cobrador.
-- Default 30: muestra cuotas vencidas + próximos 30 días.

INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'cobranza.dias_cuotas_visibles', '30'::jsonb, 'number', 'cobranza',
       'Días de cuotas futuras visibles para el cobrador (0 = solo vencidas)', 'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;
