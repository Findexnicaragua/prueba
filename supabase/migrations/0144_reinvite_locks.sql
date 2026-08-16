-- 0144 — Lock anti-race para `reenviar-invitacion` (#6).
--
-- Reenviar borra el usuario de auth y lo recrea. Dos super_admins reenviando el
-- MISMO cobrador pendiente a la vez se pisaban (uno borra, el otro 404→409, y si
-- la recreación del primero falla queda inconsistente). Esta tabla es un lock
-- por cobrador: la edge function inserta una fila (PK única) al entrar; si ya
-- existe (otro reenvío en curso) rebota con 409; la borra al terminar (finally).
-- Limpieza de locks huérfanos por TTL (>120s) en la propia función. Server-only:
-- solo el service_role la toca → bypassa RLS; NO se sincroniza.

create table if not exists public.reinvite_locks (
  cobrador_id uuid primary key,
  locked_at   timestamptz not null default now()
);

alter table public.reinvite_locks enable row level security;
-- Sin policies a propósito: ningún usuario normal la lee/escribe; solo la edge
-- function (service_role, que bypassa RLS).
