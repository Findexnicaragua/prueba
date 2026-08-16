-- 0174 — cargos_extra.cobrador_id acepta NULL (fix rechazo 23502, 2026-07-03)
--
-- BUG: al quitarle el cobrador a un cliente (clientes.cobrador_id = NULL,
-- operación legítima — "admin-managed", §3.5-4b), el trigger de propagación
-- (propagate_cobrador_id_from_cliente, 0122) empuja ese NULL a las 6 tablas
-- denormalizadas. cargos_extra era la ÚNICA de las 6 con NOT NULL → el UPDATE
-- entero rebotaba con 23502 ("null value in column cobrador_id of relation
-- cargos_extra") y el cliente quedaba imposible de des-asignar si tenía
-- cargos/descuentos. Efecto colateral del mismo NOT NULL: tampoco se podía
-- aplicar un cargo/descuento a un cliente sin cobrador (el INSERT desde Dart
-- pasa el cobrador_id de la cuota, que es NULL en admin-managed).
--
-- El cobrador_id de cargos_extra es ORGANIZATIVO (propagado por 0122), igual
-- que sus 5 hermanas nullable (contratos, cuotas, notificaciones_mora,
-- cliente_etiquetas, fotos_cliente). Quién EJECUTÓ el cargo lo captura
-- aplicado_por (NOT NULL sigue intacto). Ningún consumidor agrupa por
-- cargos_extra.cobrador_id (la reportería usa pagos.cobrador_id — §3.5-4b).

ALTER TABLE public.cargos_extra ALTER COLUMN cobrador_id DROP NOT NULL;
