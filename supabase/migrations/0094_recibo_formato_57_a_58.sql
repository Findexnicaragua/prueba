-- Migración 0094: estandarizar el ancho de recibo angosto a 58mm.
--
-- El formato angosto pasó de 57mm a 58mm (estándar real de las térmicas de
-- 58mm). El recibo ahora imprime rasterizando el PDF (no texto ESC/POS), así
-- que el ancho importa para el cálculo de dots/puntos. Migramos los tenants
-- que tengan el valor legacy 57 al nuevo 58.
--
-- El valor vive en settings(clave='recibo.formato_default_mm') como JSONB
-- numérico. Idempotente: solo toca filas con valor 57; correrla de nuevo no
-- hace nada.

update public.settings
   set valor = '58'::jsonb
 where clave = 'recibo.formato_default_mm'
   and valor::text = '57';
