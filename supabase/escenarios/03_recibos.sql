-- Los 3 pagos del escenario se insertaron por SQL sin recibo, y eso rompe el
-- invariante INV5 ("todo pago no anulado tiene recibo"). La app SIEMPRE emite
-- recibo al cobrar; el escenario tiene que reflejar eso.
INSERT INTO public.recibos (id, tenant_id, pago_id, cobrador_id, prefijo,
                            correlativo, numero_completo, reimpresiones,
                            created_at, anulado)
SELECT gen_random_uuid(), p.tenant_id, p.id, p.cobrador_id,
       COALESCE(cb.prefijo_recibo, 'TT'),
       nextval_correlativo.n,
       COALESCE(cb.prefijo_recibo, 'TT') || '-' ||
         lpad(nextval_correlativo.n::text, 6, '0'),
       0, p.fecha_pago, false
  FROM public.pagos p
  JOIN public.cobradores cb ON cb.id = p.cobrador_id
  CROSS JOIN LATERAL (
    SELECT COALESCE((SELECT max(r2.correlativo) FROM public.recibos r2
                      WHERE r2.tenant_id = p.tenant_id), 0)
           + row_number() OVER (ORDER BY p.fecha_pago) AS n
  ) AS nextval_correlativo
 WHERE p.tenant_id = '8583a8f0-191d-4750-a07d-923c01a45300'
   AND COALESCE(p.anulado, false) = false
   AND NOT EXISTS (SELECT 1 FROM public.recibos r WHERE r.pago_id = p.id);
