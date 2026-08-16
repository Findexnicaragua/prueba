-- 0227 — Nota interna del cliente
-- El CONTRATO ya tenía `notas` (contexto del servicio: "instalación con cable
-- extra"); el CLIENTE no tenía dónde anotar contexto de la PERSONA ("atiende la
-- hija después de las 3", "el perro está suelto"). Esa nota sobrevive a los
-- contratos del cliente, por eso va acá y no en `contratos`.
--
-- Interna: no sale en recibo, PDF ni export (decisión de Rubén 2026-08-09).
-- La ven y la editan TODOS los roles operativos — la escribe justamente quien
-- llega a la casa. `lectura` queda afuera por su guardia de solo-lectura, no
-- por una regla propia de esta columna.
--
-- Aditivo: las apps nuevas la esperan; las viejas la ignoran. Los 9 buckets de
-- `clientes` en sync-rules.yaml usan `SELECT *` → la columna se sincroniza sola
-- (no hay que editar el YAML, pero sí reiniciar el servicio en el VPS para que
-- re-lea el schema de la fuente). NO se bumpea `_dbWipeVersion` (columna
-- aditiva, PowerSync la aplica in-place — política R4).
--
-- Sin GRANT extra: los únicos GRANT/REVOKE por columna del repo (0199, 0201,
-- 0202) son sobre `cobradores`; `public.clientes` conserva el grant a nivel de
-- TABLA, así que la columna nueva nace legible y escribible.

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS notas text;

COMMENT ON COLUMN public.clientes.notas IS
  'Nota interna sobre el cliente (opcional). La ven y la editan todos los '
  'roles operativos. Nunca se imprime en recibo ni PDF.';
