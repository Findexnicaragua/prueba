-- Escenario controlado para Test Tenant: 4 clientes que cubren los 4 casos
-- donde la lectura del dashboard se presta a confusión.
--   Ana   — paga a tiempo
--   Beto  — no paga, cae en mora
--   Carla — paga TARDE (pasada la gracia)
--   Dani  — paga este mes una cuota de un ciclo ANTERIOR
-- El contrato se inserta y el trigger del server genera las cuotas solo, como
-- en la vida real; los pagos se aplican después contra las cuotas generadas.
BEGIN;

WITH datos(nom, cod, plan, dia, inicio) AS (VALUES
  ('Ana Lucía Mendoza',   'T0001', 'Internet 5 Mbps',             20, DATE '2026-06-20'),
  ('Beto Ramírez Solís',  'T0002', 'Internet 20 Mbps',            16, DATE '2026-06-16'),
  ('Carla Ortega Vega',   'T0003', 'Combo TV + Internet 10 Mbps', 18, DATE '2026-06-18'),
  ('Dani Herrera Cruz',   'T0004', 'Internet 15 Mbps',            20, DATE '2026-05-20')
), ins_cli AS (
  INSERT INTO public.clientes (id, tenant_id, codigo, nombre, telefono, direccion,
                               activo, created_at, updated_at, ocurrido_en)
  SELECT gen_random_uuid(), '8583a8f0-191d-4750-a07d-923c01a45300', d.cod, d.nom,
         '8555-000' || right(d.cod, 1), 'Barrio de prueba', true, now(), now(), now()
    FROM datos d
  RETURNING id, codigo
)
INSERT INTO public.contratos (id, tenant_id, cliente_id, codigo, plan_id, dia_pago,
                              fecha_inicio, fecha_primer_cobro, estado,
                              created_at, ocurrido_en)
SELECT gen_random_uuid(), '8583a8f0-191d-4750-a07d-923c01a45300', c.id,
       'C' || right(d.cod, 4), p.id, d.dia, d.inicio,
       d.inicio + INTERVAL '1 month', 'activo', now(), now()
  FROM datos d
  JOIN ins_cli c ON c.codigo = d.cod
  JOIN public.planes p ON p.nombre = d.plan
   AND p.tenant_id = '8583a8f0-191d-4750-a07d-923c01a45300';

COMMIT;
