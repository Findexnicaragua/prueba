-- 0121_p3b_permitir_sin_cobrador.sql
-- P3b (decisión Rubén 2026-06-17): un cliente —INCLUSO con contratos— puede
-- quedar SIN cobrador. Sus cuotas quedan con cobrador_id NULL → el bucket
-- por_cobrador NO las baja, así que SOLO admin/admin_cobranza las ven, filtran
-- y cobran (bajan el bucket del tenant completo). La deuda NO se pierde: queda
-- admin-managed hasta asignar un cobrador (pantalla Rutas o por cliente, que
-- propaga cobrador_id a las cuotas vía trigger 0068).
--
-- Relaja dos guards que asumían "cliente siempre con cobrador":
--   - 0058  trg_clientes_check_cobrador_no_null  (BEFORE UPDATE clientes):
--           bloqueaba poner cobrador_id = NULL si había contratos activos.
--   - 0025  trg_contratos_check_cliente_con_cobrador (BEFORE INSERT contratos):
--           bloqueaba crear un contrato si el cliente no tenía cobrador.
--
-- Se eliminan los TRIGGERS (las funciones quedan por si se quisieran reactivar).
-- No toca schema del cliente ni sync rules (sin bump de versión). No toca
-- dinero: las cuotas sin cobrador siguen contando para recaudado/saldo, solo
-- cambia QUIÉN las ve/cobra (admin, no el cobrador de campo).

DROP TRIGGER IF EXISTS trg_clientes_check_cobrador_no_null ON public.clientes;
DROP TRIGGER IF EXISTS trg_contratos_check_cliente_con_cobrador ON public.contratos;
