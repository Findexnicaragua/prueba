-- 0187 — Recibo por defecto = template pedido (2026-07-11).
--
-- El layout/orden por defecto del recibo ahora vive en el catálogo Dart
-- (ReciboLayout.porDefecto): encabezado → meta → cliente/servicio →
-- Monto/letras/método → mora → WhatsApp/pie, con 'cuota' oculto y el espaciado
-- por segmento. Etiquetas nuevas (Colector, Monto, Total en mora) salen en los
-- 3 renderers por código. Esta migración hace el ROLLOUT de datos:
--
--   1. SEED de tenants nuevos: dejar de sembrar 'recibo.layout' con el JSON
--      viejo. Sin fila, el cliente usa ReciboLayout.porDefecto = el template, y
--      además sigue AUTOMÁTICAMENTE cualquier cambio futuro del catálogo (no se
--      duplica el JSON en SQL). Se conserva la siembra de 'recibo.mostrar_cedula'.
--   2. Tenants EXISTENTES: borrar su 'recibo.layout' (orden viejo + cuota
--      visible + whatsapp mal ubicado) y su 'recibo.mostrar_hora' → el cliente
--      cae a porDefecto (template) y a la Hora apagada por defecto. Los settings
--      de CONTENIDO (logo, empresa, título, pie) NO se tocan.
--
-- No toca dinero (solo layout de comprobante). settings es key-value → sin bump
-- de schema ni sync rules. Idempotente.

-- ── 1. Seed de tenants nuevos: ya NO siembra recibo.layout ──────────────────
-- (Se parte del cuerpo VIGENTE de 0090 y se le quita solo el insert de
--  recibo.layout; el trigger tenants_seed_settings_trg NO se toca.)
create or replace function public.seed_settings_recibo_layout(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  -- Sin 'recibo.layout': el cliente usa ReciboLayout.porDefecto (template del
  -- catálogo Dart) y sigue sus cambios futuros. Se mantiene mostrar_cedula.
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'recibo.mostrar_cedula', 'true'::jsonb, 'boolean', 'recibos',
     'Mostrar la cédula del cliente en el recibo', 'admin')
  on conflict (tenant_id, clave) do nothing;
end $$;

-- ── 2. Tenants existentes → template + hora off ────────────────────────────
delete from public.settings where clave = 'recibo.layout';
delete from public.settings where clave = 'recibo.mostrar_hora';
