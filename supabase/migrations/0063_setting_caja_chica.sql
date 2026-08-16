-- 0063: Setting caja_chica.habilitada (toggle admin).
--
-- Feature futura: tracking de caja chica del cobrador para reconciliar
-- vueltos entregados vs efectivo cobrado vs efectivo entregado al admin
-- al final del día.
--
-- Esta migración solo agrega el toggle. La feature real (tabla
-- cajas_chicas + UI de asignación/reconciliación) queda para sprint
-- futuro cuando el toggle esté en ON en algún tenant que lo necesite.

INSERT INTO public.settings
  (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'caja_chica.habilitada', 'false'::jsonb, 'boolean', 'cobranza',
       'Habilitar gestión de caja chica del cobrador (asignación diaria y reconciliación de efectivo)',
       'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;
