-- 0197: PIN del dashboard per-user (antes era un setting de tenant).
-- Solo aplica a usuarios con rol 'admin'. Cada admin tiene su propio PIN.
-- El super_admin bypassa el gate; los demás roles no ven el gate.

ALTER TABLE cobradores ADD COLUMN IF NOT EXISTS dashboard_pin TEXT NOT NULL DEFAULT '';
