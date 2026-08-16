-- 0108: incidentes — snapshot del alcance (fix del audit cross-módulo 3D).
--
-- Problema: el alcance (nodo/hub/puerto) es FK ON DELETE SET NULL. Si más tarde se
-- borra ese nodo/hub/puerto, el incidente histórico pierde su nivel (FK → NULL) y
-- la UI lo lee como "corte general (todos los clientes)" — engañoso en un post-mortem.
-- El delete-guard de red ya impide borrar un puerto/hub/nodo CON clientes, pero el
-- residual (borrar tras mover los clientes, con un incidente histórico apuntando) deja
-- una ambigüedad de etiqueta.
--
-- Fix: columna denormalizada `alcance_label` que captura el nombre legible del alcance
-- al crear (ej. "Puerto: Puerto 3" / "Corte general"). La UI prefiere el nombre VIVO del
-- FK (maneja renombres) y cae al snapshot cuando el FK quedó NULL (borrado). Es el mismo
-- patrón de denormalización que cobrador_id en cuotas/pagos. Idempotente.

BEGIN;

ALTER TABLE public.incidentes
  ADD COLUMN IF NOT EXISTS alcance_label text;

COMMIT;
