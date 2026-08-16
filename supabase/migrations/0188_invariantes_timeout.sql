-- 0188 — Aumentar statement_timeout de las RPCs de invariantes.
-- Supabase impone ~8s para API; las queries con JOINs/subqueries lo exceden
-- en tenants con data real (~4600 clientes). ALTER SET aplica SOLO durante
-- la ejecución de la función, no cambia el global.

alter function public.super_admin_verificar_invariantes(uuid)
  set statement_timeout = '120s';

alter function public.super_admin_verificar_invariantes_inventario(uuid)
  set statement_timeout = '120s';

alter function public.super_admin_verificar_invariantes_tickets(uuid)
  set statement_timeout = '120s';
