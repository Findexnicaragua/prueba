-- 0143 — Eliminar error_logs por completo (decisión Rubén 2026-06-22).
--
-- Era el log de crashes del cliente Flutter (pantalla /super/logs). No se usó
-- para debug; se quita junto con su servicio/pantalla/ruta en la app. NO está
-- en las sync rules ni en schema.dart (se escribía por REST y se leía por RPC),
-- así que NO requiere deploy de sync rules. Drop de la tabla + sus 2 RPCs
-- (list_error_logs / purge_error_logs). Destructivo y autorizado.

begin;

-- Drop de las funciones por su firma real (robusto ante overloads/cambios).
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig
      from pg_proc
     where proname in ('list_error_logs', 'purge_error_logs')
       and pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

drop table if exists public.error_logs cascade;

commit;
