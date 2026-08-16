-- 0183 — F1: unicidad de etiqueta case/acento-insensitive + visitas_read alineada.
--
-- (etiquetas) 0122 dejó `UNIQUE(tenant_id, nombre)` case/acento-SENSITIVE, pero el
-- pre-check del cliente pliega con foldSqlExpr (ñ/acentos→ASCII + lower). Dos admins
-- offline (o uno en 2 devices) podían crear "Moroso"/"moroso"/"Morosó": todas pasan
-- el check local y el server las acepta → catálogo con duplicados visuales. Índice
-- canónico que IGUALA foldSqlExpr: lower(translate(...)) es IMMUTABLE. Verificado:
-- 0 colisiones en prod al crear el índice.
--
-- (visitas) `visitas_read` limitaba al cobrador a SUS visitas (cobrador_id=auth.uid()),
-- pero el bucket `por_cobrador` del sync-rules ya le baja TODAS las del tenant (modelo
-- vigente "el cobrador ve todo el tenant", ARQUITECTURA §4b) → la restricción era
-- dead-code offline (RLS y sync decían cosas distintas). Se alinea la RLS a tenant-wide.

CREATE UNIQUE INDEX IF NOT EXISTS etiquetas_nombre_fold_unico
  ON public.etiquetas (
    tenant_id,
    lower(translate(nombre, 'ÑñÁáÉéÍíÓóÚúÜü', 'nnaaeeiioouuuu'))
  );

DROP POLICY IF EXISTS "visitas_read" ON public.visitas;
CREATE POLICY "visitas_read" ON public.visitas
  FOR SELECT USING (tenant_id = public.current_tenant_id());
