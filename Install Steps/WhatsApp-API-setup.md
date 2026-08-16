# WhatsApp por API (envío automático) — guía de activación

El código y la config ya están en la app. Esto es lo que falta **una vez**, cuando
tengas la cuenta paga de Meta, para dejarlo andando. Orden: Meta → Deploy → Cron →
App.

> El modo **gratis** (abrir WhatsApp a mano desde Avisos) ya funciona sin nada de
> esto. Esta guía es SOLO para el **envío automático por lote** (modo pago).

---

## 1) En Meta (una sola vez)

1. **Meta Business** + **verificación del negocio** (suben documentos de la empresa).
2. Agregá el producto **WhatsApp** → registrá un **número WhatsApp Business** y
   verificalo. Anotá:
   - **Phone Number ID** (NO el número a secas — es el ID que da Meta).
   - WhatsApp Business Account ID (por si lo pide).
3. Generá un **Access Token permanente** (recomendado: System User token, no el
   temporal de 24h).
4. Creá **2 plantillas** en el Business Manager → categoría **Utility** →
   esperá la **aprobación de Meta** (24-48h). Usá **variables CON NOMBRE**
   (formato "Named", no posicional): `{{nombre}}`, `{{monto}}`, `{{dias}}`,
   `{{empresa}}` (así el orden en el texto no importa).
   - **No hace falta inventarlo a mano:** en la app (paso 4, "Editar mensaje")
     redactás el cuerpo con chips + vista previa y el botón **"Copiar para
     Meta"** te da el texto listo con `{{nombre}}…` para pegar acá.
   - Ejemplo de cuerpo (gracia): *"Hola {{nombre}}, le recordamos que tiene un
     saldo pendiente de {{monto}}. Para evitar la suspensión, pague en los
     próximos {{dias}} días. Gracias — {{empresa}}"*
   - Anotá el **nombre** de cada plantilla (ej. `aviso_corte_gracia_v1`,
     `aviso_corte_mora_v1`) y el **idioma** (ej. `es` o `es_MX`).

## 2) Deploy de las edge functions (Dashboard de Supabase)

Las env vars (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`)
ya las inyecta Supabase — no hay que configurarlas.

1. Dashboard → **Edge Functions** → deploy **`whatsapp-set-token`**
   (pegar `supabase/functions/whatsapp-set-token/index.ts`).
2. Deploy **`whatsapp-enviar`** (pegar `supabase/functions/whatsapp-enviar/index.ts`).
3. Verificá que ambas queden "deployed a few seconds ago".

## 3) El cron diario (correr DESPUÉS de deployar las functions)

El cron corre **cada hora** y la function decide, por tenant, si es la hora
configurada. Necesita las extensiones `pg_cron` + `pg_net` (Dashboard → Database
→ Extensions, o por SQL). Reemplazá `<PROJECT_REF>` y `<SERVICE_ROLE_KEY>`:

```sql
-- una sola vez
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'whatsapp-lote-hourly',
  '5 * * * *',  -- minuto 5 de cada hora
  $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/whatsapp-enviar',
    headers := jsonb_build_object(
      'Authorization', 'Bearer <SERVICE_ROLE_KEY>',
      'Content-Type', 'application/json'),
    body := '{"modo":"lote"}'::jsonb
  );
  $$
);
```

> Es seguro dejarlo corriendo: la function NO manda nada si el tenant tiene el
> modo API apagado, sin token, o si no es su hora. Para frenar todo:
> `select cron.unschedule('whatsapp-lote-hourly');`

## 4) En la app (super_admin → Configuración → Avanzado → "WhatsApp por API")

1. **Access Token** → pegar → **Guardar** (queda en el servidor, no se sincroniza).
2. **Phone Number ID**.
3. **Plantillas**: por cada una (gracia/mora) poné el **nombre** (idéntico al de
   Meta) y, con **"Editar mensaje"**, redactá el cuerpo (de ahí sale el "Copiar
   para Meta" del paso 1.4). Elegí el **idioma** (dropdown).
4. **Hora** del envío (0-23, hora Nicaragua) · **frecuencia** de re-notificación ·
   **tope diario**.
5. **Probar con un cliente** → confirmá que el mensaje llega.
6. Prendé **"Activar envío automático por API"**.

Listo: a la hora configurada, el cron manda solo a los clientes en gracia/mora
(respetando la frecuencia y el tope). El log queda en la tabla `whatsapp_envios`.

### Notas operativas (importantes)

- **Cadencia del cron:** programalo EXACTO una vez por hora (`5 * * * *`). La
  function compara la hora configurada contra la hora actual Nicaragua, así que
  dispara una sola vez al día. Si lo ponés cada 30 min o a `:00` y `:30`, podría
  mandar dos veces — no lo hagas.
- **Tope vs tenants grandes:** el tope es por corrida (LIMIT). Con dedup, los
  clientes se van drenando en días sucesivos (hoy los 200 más viejos, mañana los
  siguientes, etc.). Pero si la cantidad de morosos supera `tope × días-de-la-
  ventana`, los más nuevos pueden no recibir aviso dentro de la ventana. Para un
  tenant grande (ej. Mairena ~4600), subí el tope para cubrir el volumen diario
  esperado, o usá frecuencia `diario`.
- **Zona horaria:** todo asume Nicaragua UTC-6 fijo (sin DST). La hora del cron
  se calcula en la edge function; los clientes elegibles, en Postgres. Hoy
  coinciden; si algún día se introdujera DST habría que tocar ambos lados.

---

## Qué quedó probado y qué no (estado al construirlo, 2026-06-21)

- ✅ **Probado:** migraciones 0137/0138 en prod (settings + tablas) · la función
  `whatsapp_clientes_a_notificar` (devuelve gracia/mora con teléfono, monto/días
  correctos, y respeta la frecuencia — verificado por SQL con la data de prueba).
- ⚠️ **NO probado (no hay cuenta Meta ni functions deployadas):** las edge
  functions contra la API real de Meta · el botón "Probar"/el cron · la card de
  config (vive en Avanzado, super-only — se prueba con login super_admin). El
  código está según la doc v21 de Meta; el primer envío real es tu test del paso 4.5.
