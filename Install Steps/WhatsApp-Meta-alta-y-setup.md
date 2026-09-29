# WhatsApp por Meta — alta del ISP y conexión de la app

**Guía operativa · redactada 2026-08-21**

Esta guía **reemplaza** a `Install Steps/WhatsApp-API-setup.md` (que quedó desactualizada en dos puntos concretos — ver §9). Está partida en dos mitades con dueños distintos:

- **PARTE A — la hace el dueño del ISP** (Telecable Mairena / Telenet). No es técnico. Cada paso dice qué va a ver en pantalla y qué tiene que anotar.
- **PARTE B — la hacemos nosotros** (super_admin). Es cargar 4 datos en una pantalla y probar.

**Decisión ya tomada: vamos por Meta directo, no por un intermediario.** El trámite con Meta (verificación del negocio, alta del número, moneda, medio de pago, plantillas) es **exactamente el mismo** con o sin intermediario — el intermediario no saltea ni un paso del papeleo, solo cobra una suscripción arriba del costo por mensaje de Meta.

> **Convención de esta guía:** todo lo marcado con **⚠ verificar en pantalla** es un nombre de menú o un comportamiento que **no pudimos confirmar en documentación oficial de Meta**. La UI del Business Manager cambia seguido: guiate por el ícono/la sección, no por el texto literal.

---

## 0) Las tres cajas de Meta (leer esto antes de tocar nada)

El 90% de la confusión sale de mezclar estas cosas. Son objetos distintos:

```
  PORTFOLIO COMERCIAL  (business.facebook.com)   ← el contenedor de la empresa
  "antes se llamaba Business Manager"
  │
  ├── WABA — WhatsApp Business Account            ← acá viven las plantillas
  │    │                                             y el medio de pago
  │    └── NÚMERO de teléfono  →  te da el PHONE NUMBER ID  ← esto nos pasás
  │
  └── (al costado) APP DE META  (developers.facebook.com/apps)
       └── SYSTEM USER  →  te da el ACCESS TOKEN                ← esto nos pasás
```

Dos cosas que confunden siempre:

- **"Phone Number ID" NO es el número de teléfono.** Es un ID largo de dígitos que te da Meta (ej. `1274245055770033`). El número (`+505 8xxx xxxx`) no nos sirve.
- **El token que aparece en la pantalla "API Setup" de la app es TEMPORAL de 24 horas.** Ese no sirve. El bueno se genera desde el System User (paso A9). Si el envío anda un día y al otro deja de andar, fue esto.

---

# PARTE A — Lo que hace el ISP

> Tiempo total de trabajo del dueño: **una tarde**. Tiempo de calendario: **de 2 días a 2 semanas**, casi todo esperando la verificación del negocio (§7).
>
> **Arrancá por el paso A3 (verificación del negocio) apenas puedas**: es lo único que tarda y no depende de nadie más. Todo lo demás se puede hacer mientras esa verificación está en trámite.

## A1) Lo que necesitás antes de empezar

Meta pide textualmente tres cosas:

- [ ] **Una cuenta de Facebook** (la personal sirve) o una cuenta de Meta administrada.
- [ ] **Registrarte como desarrollador** en `developers.facebook.com/async/registration/` — es un formulario de un minuto, gratis.
- [ ] **Un celular con WhatsApp instalado**, para recibir el mensaje de prueba.

**NO hace falta una Página de Facebook.** Si ya tenés, no molesta; si no tenés, no la crees — no es requisito (confirmado en tres páginas oficiales de Meta).

Además vas a necesitar, aunque Meta no lo ponga en esa lista:

- [ ] **Un número de teléfono DEDICADO** para el sistema (ver A6 — es importante y tiene una trampa fea).
- [ ] **Una tarjeta de crédito** habilitada para consumos internacionales, a nombre de la empresa (ver A7).
- [ ] **Los papeles de la empresa** en PDF o foto clara (ver A3).

## A2) Crear el portfolio comercial

1. Entrá a **`https://business.facebook.com/`** con tu cuenta de Facebook.
2. Creá un **portfolio comercial** (si ya tenés uno de la empresa, usá ese). En pantallas viejas se llama **"Business Manager"** — es lo mismo.
3. Andá a la información del negocio y cargá el **nombre legal EXACTO**, la dirección y el número de registro/RUC **tal cual figuran en los documentos de constitución**.

> **Este es el error #1 de rechazo.** Si escribís el nombre comercial ("Telecable Mairena") y el documento dice el nombre legal de la sociedad ("TELECABLE MAIRENA S.A."), Meta rechaza la verificación. Tiene que coincidir **carácter por carácter**, incluidos acentos, puntos y "S.A.".
> ⚠ verificar en pantalla: el nombre exacto de la sección donde se carga esto ("Business Info" / "Información del negocio").

**Anotá:** el nombre del portfolio y con qué cuenta de Facebook lo creaste.

## A3) Arrancar la verificación del negocio — HACELO PRIMERO

Es lo que más tarda y es **bloqueante para Telecable Mairena** (ver §5, límites).

**Dónde:** Meta Business Suite → tu portfolio → configuración → bajar hasta **"Security Center" / "Centro de seguridad"** → sección **Business Verification** → **"Start Verification"**.
⚠ verificar en pantalla — esta ruta viene de guías de integradores, no de doc oficial de Meta. La ruta que **sí** está en doc oficial es la del panel de la app: **Settings → Basic → Verification → "Start Verification"** (te va a servir recién después del paso A5).

**Quién:** tenés que ser **administrador del portfolio**. Un empleado no puede dispararla.

**Documentos.** Meta acepta cinco tipos ⚠ (lista cruzada de fuentes de integradores, no de doc oficial):

1. Certificado o acta constitutiva
2. Registro o licencia del negocio
3. Documento fiscal emitido por el gobierno (para Nicaragua: la **constancia de RUC de la DGI** encaja acá)
4. Estado de cuenta bancario del negocio
5. Factura de servicios públicos

Te van a pedir 2 o 3 que **juntos** prueben nombre legal + dirección + teléfono. Reglas que hacen fallar el trámite:

- La **factura de servicios NO sirve para probar el nombre legal** — solo dirección y teléfono. El nombre legal exige acta constitutiva, registro mercantil o documento fiscal.
- El nombre **y** la dirección (o el teléfono) tienen que aparecer **en el mismo documento**.
- Los documentos deben tener **menos de 12 meses**.
- **En español van tal cual**: no hace falta traducción ni apostilla (español está en la lista de idiomas aceptados de Meta).

**Cuánto tarda:** Meta **no publica un plazo oficial**. El consenso de integradores es **1 a 5 días hábiles**, con casos que salen en minutos y otros que se estiran a dos semanas. **No prometas una fecha.** El resultado llega por email y como notificación en el portfolio. Si te rechazan, se puede corregir y reintentar.

**Anotá:** la fecha en que la mandaste, para poder reclamar.

## A4) Crear la app de Meta

1. Entrá a **`https://developers.facebook.com/apps`** → **"Create App"**.
2. Poné un nombre (ej. "Telecable Mairena CRM") y tu email.
3. Elegí el caso de uso **"Connect with customers through WhatsApp"**.
4. **Importante:** en el desplegable de portfolio, **elegí el portfolio que creaste en A2**. Si creás la app "suelta", después hay que reconectarla a mano y es engorroso.
5. **"Create app"** → después **"Start using the API"**, que te lleva a la sección **"API Setup"**.

## A5) Crear/conectar la WABA (la cuenta de WhatsApp del negocio)

En la pantalla **API Setup** de la app vas a poder crear una WABA nueva o conectar una existente. Alternativa por menú: engranaje (**Settings**) → **Accounts** → **WhatsApp accounts** → botón azul **"+Add"** → **"Create a new WhatsApp Business account"**.

> ⚠ Meta advierte que esa opción del menú *"is being released gradually... and may not be available to you immediately"*. **Si no te aparece el botón, no es un error tuyo**: usá la vía del App Dashboard. De hecho, la WABA puede haberse creado sola al crear la app.

**Anotá:** el **WhatsApp Business Account ID (WABA ID)**. No lo necesitamos para el panel del CRM, pero hace falta para asignar permisos (A9) y para cualquier reclamo a soporte de Meta.

## A6) Registrar el número — LEER ANTES DE TOCAR NADA

> ### 🛑 Advertencia que cuesta plata y chats
> **El número que registres en la API no puede tener una cuenta de WhatsApp común activa.** Para registrarlo hay que **borrar esa cuenta desde la app**, y eso **destruye todos los chats de ese número, sin vuelta atrás**.
>
> Si hoy atendés clientes a mano desde ese número, **vas a perder el historial completo**.
>
> **Recomendación: usá un número NUEVO, dedicado al sistema.** La alternativa ("Coexistence", que deja el mismo número funcionando a mano y por API a la vez) **existe pero no la podés activar solo**: Meta exige que la integre un Solution Partner / Tech Provider con Embedded Signup — o sea, volver a pagarle una suscripción a un intermediario, que es justo lo que estamos evitando.

Con eso claro:

1. En **API Setup** → **"Add phone number"**.
2. Puede ser **celular o fijo**. Si es fijo, elegí verificación **por llamada de voz** (a un fijo el SMS no le llega) y tené a alguien atendiendo ese teléfono en ese momento.
3. Te llega un **código OTP** (SMS o llamada) → lo cargás.
4. **Te va a pedir un PIN de verificación en dos pasos de 6 dígitos. Es obligatorio.**
   > 📌 **Anotá ese PIN donde guardás las llaves de la oficina.** No se recupera con un click. Sin él no vas a poder migrar ni dar de baja el número más adelante.
5. **Nombre para mostrar (display name):** es lo que ve el cliente arriba del chat. Poné el nombre real del negocio (**"Telecable Mairena"**), no genéricos tipo "Cobros" o "Info" — los genéricos se rechazan. Se puede cambiar hasta 10 veces cada 30 días.

**Buena noticia:** el chip **sigue sirviendo para llamadas y SMS normales**. Lo único que pierde es WhatsApp común.

**Anotá:** el **Phone Number ID** (el número largo de dígitos que aparece en API Setup, NO el teléfono).

## A7) Moneda, zona horaria y tarjeta — esto es lo que destraba el error 131042

> ### 🛑 La moneda se elige UNA vez y en la práctica no se cambia
> Meta dice textual: *"A WABA's time zone and currency cannot be edited once a line of credit has been attached to it"*. Existe una API de migración de moneda (desde el 2026-06-01) pero **no soporta el caso tarjeta → tarjeta**, que es el nuestro. **Elegí bien la primera vez.**

1. **Moneda: USD.** No hay opción en córdobas — el córdoba (NIO) no está entre las monedas de facturación de Meta. Los rate cards se publican en 15 monedas y ninguna es NIO.
2. **Zona horaria:** la de Nicaragua (**America/Managua**).
3. **Medio de pago:** cargá una **tarjeta de crédito** de la empresa.
   - ⚠ verificar en pantalla — la ruta reportada por integradores es: Business Manager → **Billing and Payments** → **Payment Methods** → *Add Business Payment Method* → y **después** ir a la pestaña **WhatsApp Business Accounts**, elegir la WABA y **"Add payment method"**. Ruta alternativa reportada: Settings → Accounts → WhatsApp Accounts → la WABA → Payment Settings.
   - **El paso que todo el mundo se saltea:** no alcanza con tener la tarjeta en el portfolio. Hay que **asignarla específicamente a la WhatsApp Business Account**.
   - Para gestionar medios de pago hay que tener el rol **Finance Editor** en el Business Manager ⚠. Si delegás esto en un empleado y no le diste ese rol, no le van a aparecer las opciones.
   - **Preferí crédito sobre débito.** Meta corre autorizaciones recurrentes; muchas tarjetas de débito nicaragüenses y todas las prepagas/gift card fallan. ⚠ **No pudimos confirmar en fuente oficial qué medios de pago habilita Meta específicamente para Nicaragua** — probá la tarjeta antes de comprometer una fecha.
4. **Es postpago, no prepago.** No se "carga saldo": Meta cobra automáticamente al alcanzar un umbral o al cierre del mes, y manda la factura por email en la primera semana. Necesitás tarjeta con cupo disponible siempre.

**Si este paso queda a medias, el sistema NO manda ningún mensaje** y devuelve el error **131042** (ver §8).

## A8) Crear las 2 plantillas

El CRM manda **exactamente dos** mensajes distintos, según en qué situación esté el cliente:

| Plantilla | Cuándo se manda | Qué significa `{{dias}}` |
|---|---|---|
| **Gracia** — "próximo a corte" | Tiene deuda vencida pero todavía está dentro de los días de gracia | Los días que **faltan** para el corte |
| **Mora** — "corte" | Se le vencieron los días de gracia | Los días que **hace** que está cortado |

**Dónde:** entrá directo a **`https://business.facebook.com/latest/whatsapp_manager/message_templates`** → **"Create template"**. (Usá esa URL, no el camino por menús: WhatsApp Manager está escondido dentro de Business Suite y cambia de lugar seguido.)

### Las 5 reglas que no se negocian

1. **Categoría: `Utility`** (utilidad). No `Marketing`. Es la diferencia entre pagar **US$0,0113** y **US$0,074** por mensaje — 6,5 veces más (§6).
2. **Idioma: "Spanish" a secas (código `es`).** No `es_MX`, no `es_AR`, no `es_NI`. El CRM solo puede seleccionar `es`, `es_MX`, `es_AR` y `es_ES`; si creás la plantilla en cualquier otro idioma, **todos los envíos fallan**. Elegí `es` y listo.
3. **Variables CON NOMBRE, no numeradas.** El CRM manda las variables por nombre: `nombre`, `monto`, `dias`, `empresa` (todo en minúscula, sin acentos). El formato **por defecto de Meta es el posicional `{{1}} {{2}}`, que NO sirve**.
   > ⚠ **NO pudimos confirmar en doc oficial de Meta cómo se elige "con nombre" dentro de la pantalla de WhatsApp Manager.** Si no encontrás la opción, **frená y avisanos**: nosotros podemos crear las dos plantillas por API con el formato correcto y vos solo las ves aprobadas. No las crees en formato numerado "para probar" — habría que rehacerlas.
4. **Las cuatro variables tienen que estar en el cuerpo.** El CRM manda siempre las 4; si la plantilla declara menos, el envío puede ser rechazado.
5. **El mensaje NO puede empezar ni terminar con una variable.** Es causa de rechazo textual de Meta (*"The message template cannot start or end with a parameter"*).

### Cuerpos sugeridos (ya cumplen las 5 reglas)

**Gracia:**
> Hola {{nombre}}, le recordamos que su servicio de internet con {{empresa}} tiene un saldo pendiente de {{monto}}. Para evitar la suspensión, puede pagar dentro de los próximos {{dias}} días. Gracias por su preferencia.

**Mora:**
> Hola {{nombre}}, su servicio de internet con {{empresa}} está suspendido por un saldo pendiente de {{monto}}, con {{dias}} días de atraso. Puede acercarse a pagar para reactivarlo. Quedamos atentos.

> El CRM tiene un editor con vista previa y un botón **"Copiar para Meta"** que te da el cuerpo listo con las llaves dobles. Pedínoslo y te lo pasamos armado — así no hay error de tipeo.

### Lo que hace que te rechacen la plantilla

- Empezar o terminar con una variable.
- Llaves desparejadas (`{{nombre}` en vez de `{{nombre}}`).
- Amenazar: mencionar **acciones legales** o escrachar al cliente = rechazo directo. "Para evitar la suspensión" es informativo y pasa.
- Pedir datos sensibles: número de tarjeta, cuenta bancaria, cédula completa.
- Ser un duplicado exacto de otra plantilla.
- Mezclar cobranza con promoción ("aprovechá y contratá el plan premium") → te la recategorizan a **Marketing** y pagás 6,5 veces más.
- Evitá el signo `$` en el **texto fijo** de la plantilla (el monto ya viene con "C$" adentro de la variable) ⚠. Si al pedirte valores de ejemplo te rechaza por caracteres especiales, probá con un ejemplo sin símbolo (ej. `1,200.00`).

### Nombres

El nombre solo admite **minúsculas, números y guión bajo**. Si escribís "Aviso Gracia", Meta lo guarda como `aviso_gracia`.

> **Anotá el nombre EXACTO tal como quedó guardado**, no como lo tipeaste. El CRM lo manda literal, sin corregir nada: una mayúscula de más y no sale ni un mensaje.

Sugeridos: `aviso_gracia` y `aviso_mora`.

**Cuánto tarda la aprobación:** Meta dice **hasta 24 horas**; en la práctica suele salir en minutos. El estado **"Active - Quality pending"** significa **aprobada y lista para usar** (todavía no tiene datos de calidad) — no es un problema. Si te la rechazan, corregís y apelás; las apelaciones también se resuelven dentro de 24 h.

## A9) Generar el Access Token permanente

1. Entrá a **`https://business.facebook.com/latest/settings`** → barra lateral → **"System users"** → **"+Add"**.
2. Poné un nombre reconocible (ej. **"CRM Cobranza"** — así el día de mañana sabés qué revocar) y asignale el rol **Admin**.
   > Con rol "Employee" el botón de generar token queda gris y parece que está roto.
3. Click en el nombre del system user → **"Assign assets"**:
   - Asignale la **APP** con permiso **"Manage app"** / control total.
   - Asignale **también la WhatsApp Business account (WABA)** con **"Full control"**.
   > **Trampa clásica:** asignar solo la app. El token se genera igual, pero al enviar Meta devuelve error de permisos sobre la WABA. Tienen que estar **los dos**.
4. **Recargá la página.** Sin recargar, el botón "Generate token" queda deshabilitado y parece que falló.
5. **"Generate token"** → tildá **los tres permisos**:
   - `whatsapp_business_messaging`
   - `whatsapp_business_management`
   - `business_management` ← este se olvida siempre porque el nombre no dice "whatsapp"
6. **Elegí la opción de expiración "sin vencimiento" / "Never".** ⚠ verificar en pantalla — confirmamos que el selector de expiración existe, pero no el texto exacto de la opción.
7. Copiá el token. **Es larguísimo (~200 caracteres).** Si el que copiaste es corto, copiaste el temporal de 24 h de la pantalla API Setup — ese no sirve.

---

## 📩 EL SOBRE — los 4 datos que nos tenés que pasar

**Sin estos cuatro no podemos hacer absolutamente nada.** No hay forma de que los saquemos nosotros: viven adentro de tu cuenta de Meta.

| # | Dato | Cómo se ve | De dónde sale |
|---|---|---|---|
| **1** | **Access Token permanente** | texto larguísimo, ~200 caracteres, empieza con letras y números | Paso **A9** (System User → Generate token) |
| **2** | **Phone Number ID** | solo dígitos, ej. `1274245055770033` | Paso **A6** (pantalla API Setup). **NO es el número de teléfono** |
| **3** | **Nombre exacto de las 2 plantillas aprobadas** | ej. `aviso_gracia` y `aviso_mora` — minúsculas y guión bajo, **copiado tal cual quedó guardado** | Paso **A8** (WhatsApp Manager) |
| **4** | **Código de idioma de las plantillas** | normalmente **`es`** | Paso **A8** (el que elegiste al crearlas) |

**Cómo mandarlos:**

- El **token es una llave de producción**: con él se pueden mandar mensajes facturados a tu nombre. **No lo mandes por WhatsApp ni por mail sin cifrar.** Coordinalo con nosotros por un canal acordado, y una vez cargado lo podés rotar cuando quieras desde el System User.
- Guardá **para vos** (no hace falta mandárnoslos, pero anotalos): el **WABA ID**, el **PIN de 6 dígitos** del número y con qué cuenta de Facebook creaste el portfolio. Sin esos tres no se puede hacer soporte ni traspasar nada más adelante.

**Y confirmanos también, para no frenar el arranque:**

- [ ] Que la **verificación del negocio** está **aprobada** (o en qué fecha la mandaste).
- [ ] Que la **tarjeta está cargada y asignada a la WABA**, con **moneda USD** y zona horaria de Nicaragua.
- [ ] **El nombre de tu empresa tal como querés que aparezca firmando el mensaje** (Telenet: hoy lo tenemos **vacío** en el sistema — ver §4).

---

# PARTE B — Lo que hacemos nosotros

> Tiempo: **15 minutos** por ISP, una sola vez. No hay que deployar nada, ni correr migraciones, ni tocar el cron: **el cron ya está instalado, es uno solo y recorre todos los tenants**. Dar de alta un ISP es 100% cargar settings desde la app.

## B0) Antes de conectar el PRIMER ISP real (deuda técnica y pre-chequeos)

Esto va antes de cargar credenciales, no después.

1. **Subir la versión de Graph API.** `supabase/functions/whatsapp-enviar/index.ts` tiene `const META_VERSION = "v21.0"` hardcodeado. **v21.0 expira el 2027-01-21**: cuando expire, **todos** los envíos por Meta fallan de golpe. Subir a **v23.0** (expira 2027-10-08) o **v24.0** (expira 2028-02-18). Es una línea + redeploy de la function. **Hacerlo antes de poner tenants reales, no después.**
2. **Cargar `empresa.nombre` en Telenet** — hoy está **vacío**. La variable `{{empresa}}` sale de ese setting; con el campo vacío el mensaje sale firmado en blanco y Meta puede rechazar el envío por parámetro vacío. Lo edita el admin del ISP en la pestaña Empresa (o nosotros impersonando).
3. **Darle a cada ISP una hora distinta.** Hoy los tres tenants tienen `hora = 8`. El lote es **secuencial** (tenant por tenant, cliente por cliente, esperando cada respuesta) y cada cliente cuesta dos idas y vueltas de red. Con la única medición real que tenemos (~0,7 s por envío, n=2), 200 envíos ≈ **2,5 minutos** y 400 ≈ **5 minutos**. El límite de una Edge Function de Supabase es **150 s en plan gratuito y 400 s en plan pago**. Con los dos ISP a la misma hora, el lote se corta a la mitad y los últimos clientes no reciben nada.
   → **Mairena hora 8, Telenet hora 9.** Y **verificar en el dashboard de Supabase si el proyecto está en plan gratuito o pago** — de eso depende si el techo es 150 s o 400 s.
4. **Elegir el tope diario con la cuenta hecha** (§5). Arrancar conservador (120–150) hasta medir una corrida real con volumen.
5. **Limpiar teléfonos basura** (§4). En Mairena hay **293 clientes cuyo teléfono es literalmente `"0"`**: fallan todos los días y consumen cupo todos los días (el dedupe solo bloquea envíos exitosos).

## B1) Entrar a la pantalla

1. Login como **super_admin**.
2. **IMPERSONAR al tenant** que vas a configurar. 🛑 **Si configurás parado en el tenant System, escribís los settings del System y no pasa nada.** Los 12 settings de WhatsApp son `editable_por = 'super_admin'` y el `tenant_id` sale del provider de impersonación.
3. Ruta: **`/admin/settings`** → pestaña **"Avanzado"** (solo existe para super_admin) → categoría **"Avisos y notificaciones"** → tarjeta **"WhatsApp API"** (badge "PAGO · SUPER ADMIN", ícono verde de robot).

> El dueño del ISP (rol `admin`) **nunca ve esta tarjeta**. Este paso es nuestro por diseño.

## B2) Campo por campo, en orden

| # | Control | Qué poner |
|---|---|---|
| 1 | Switch **"Activar WhatsApp API"** | **Prenderlo.** Revela todo lo demás. También hace falta prenderlo para poder usar "Probar" |
| 2 | **"Por dónde se manda"** → `Meta directo` \| `WhatChimp` | **Meta directo** |
| 3 | **"Phone Number ID"** (sección "Credenciales de Meta") | El dato **2** del sobre |
| 4 | **"Access Token"** (campo oculto) → botón **"Guardar"** | El dato **1** del sobre |
| 5 | **"Próximo a corte (gracia)"** → *"Nombre de la plantilla en Meta"* | El nombre de la plantilla de gracia (dato 3) |
| 6 | **"Corte (mora)"** → *"Nombre de la plantilla en Meta"* | El nombre de la plantilla de mora (dato 3) |
| 7 | **"Idioma de las plantillas"** | `Español` (`es`) — el dato **4** |
| 8 | **"Hora (0-23)"** | Mairena `8` · Telenet `9` (hora Nicaragua) |
| 9 | **"Re-notificar al mismo cliente"** | Ver §5 — recomendado arrancar en **"Cada 15 días"** |
| 10 | **"Tope diario"** | Ver §5 |
| 11 | Botón **"Guardar configuración"** | |

**Verificación del token (paso 4).** Tienen que pasar las tres cosas:

- Snackbar **"Token guardado para \<nombre del tenant\>"** — **leé el nombre**: está ahí a propósito para cazar el error de configurar el tenant equivocado.
- Aparece el check verde **"Token configurado — vive en el servidor, no se sincroniza."**
- Chequeo por SQL (solo lectura):
  ```sql
  select t.nombre, c.actualizado_en, length(c.access_token)
  from public.whatsapp_credenciales c
  join public.tenants t on t.id = c.tenant_id;
  ```
  Un token permanente de System User de Meta ronda los **200 caracteres**. Si ves 54, es un token de WhatChimp o el temporal de 24 h.

> **Argumento de venta para el ISP:** la tabla `whatsapp_credenciales` tiene RLS **sin ninguna policy** y **no está en las sync rules de PowerSync**. O sea: el token nunca sale del servidor ni llega al celular de ningún cobrador.

**Dos cosas que confunden en esta pantalla:**

- El botón **"Editar mensaje"** abre un editor con vista previa y "Copiar para Meta". **Ese cuerpo NO es lo que se envía** — es un borrador de referencia para crear la plantilla en Meta. Lo que se envía es la plantilla **aprobada en Meta**. Editar el borrador después de aprobar no cambia nada de lo que reciben los clientes.
- Un tenant tiene **un solo token** (la tabla tiene PK en `tenant_id`). Cambiar de proveedor pisa el token **y** obliga a **recrear las dos plantillas** (Meta usa variables con nombre; WhatChimp, posicionales — no son intercambiables).

## B3) Prueba de humo

1. Botón **"Probar con un cliente"**.
   > 🛑 **Le manda a un CLIENTE REAL del tenant** — el de la cuota más vieja — y **consume su ventana de dedupe**. No es un número de prueba. Coordinalo con el ISP, o probá primero en el Test Tenant.
2. Esperado: snackbar **"Enviado a \<nombre\> ✓"**.
3. **Confirmá con el ISP que el mensaje LLEGÓ al teléfono.** Esto no es opcional: en nuestra base **`ok = true` significa "el proveedor aceptó el pedido", NO "el cliente lo recibió"**. No hay webhook de entrega en el código. Un bloqueo posterior de Meta (como el 131042) **no deja ningún rastro en `whatsapp_envios`** — de hecho las 2 únicas filas que existen figuran `ok = true` y el mensaje nunca llegó.
4. Chequeo por SQL:
   ```sql
   select t.nombre, e.estado, e.canal, e.ok, e.error, e.enviado_en
   from public.whatsapp_envios e
   join public.tenants t on t.id = e.tenant_id
   order by e.enviado_en desc limit 20;
   ```
   El canal va a decir **`api:meta`** (desde la migración 0235 ya no es `api` a secas — si filtrás por `canal = 'api'` no encontrás nada; usá `canal like 'api%'`).
5. **Al día siguiente, a la hora configurada**, verificá que el lote automático corrió:
   ```sql
   select id, status_code, created, content
   from net._http_response order by created desc limit 10;
   ```
   Esperado: `status_code = 200` y `{"ok":true,"tenantsProcesados":1,"enviados":N,...}` en el minuto `:05` de la hora Nicaragua configurada (hora UTC = hora Nicaragua + 6).
   > **`cron.job_run_details` MIENTE**: dice `succeeded` aunque la función devuelva 401, porque solo registra que el `http_post` se encoló. **Mirá siempre `net._http_response`.**
   > Y el cron dispara con timeout de 2 s del lado de Postgres (default de `pg_net`): puede figurar `timeout` ahí aunque el lote haya andado perfecto. No lo tomes como error.

## B4) Cómo se apaga esto (importante y contraintuitivo)

**El envío automático NO respeta los toggles de Avisos.** El lote lee 9 settings y **ninguno** es `cobranza.avisos_habilitado` ni `cobranza.notif_whatsapp_habilitado` — esos dos gatean únicamente la pantalla `/admin/avisos` y los botones de wa.me manual.

**Un tenant con la pantalla de Avisos apagada y "notificar por WhatsApp" apagado igual le manda mensajes facturados a todos sus morosos si el modo API está prendido con token.**

Para frenar el envío automático hay exactamente dos maneras:

1. Apagar el switch **"Activar WhatsApp API"** de la tarjeta, o
2. Borrar la fila del tenant en `whatsapp_credenciales`.

Y para frenar **todo, de todos los tenants**: `select cron.unschedule('whatsapp-lote-hourly');`

---

# 1) Estado hoy, por tenant

Datos leídos de producción (`vxxz`) el **2026-08-21**.

## Infraestructura — ✅ probada de punta a punta

| Pieza | Estado |
|---|---|
| Edge function `whatsapp-enviar` | **ACTIVE**, versión 4 (2026-08-19) |
| Edge function `whatsapp-set-token` | **ACTIVE**, versión 2 (2026-08-17) |
| Cron `whatsapp-lote-hourly` (jobid 8, `5 * * * *`) | **ACTIVO**, 61 corridas, todas OK |
| Corrida real del 2026-08-21 14:05 UTC (= 8:05 Nicaragua) | **HTTP 200** → `{"ok":true,"tenantsProcesados":1,"enviados":0,"fallidos":0}` |

La cañería completa está verificada: el cron dispara, autentica bien, calcula la hora Nicaragua y selecciona el tenant correcto. **Lo único que falta es del lado de Meta.**

## Configuración y volumen

| | **Telecable Mairena** | **Telenet** | **Test Tenant** |
|---|---|---|---|
| Clientes activos | 4.458 | 1.042 | 14 |
| **Notificables hoy** | **1.803** (540 gracia / 1.263 mora) | **445** (98 / 347) | 7 (solo 2 con teléfono) |
| Teléfonos usables | **1.502 (83%)** | **433 (97%)** | 2 |
| Saldo vencido involucrado | C$ 511.460 gracia + C$ 2.262.406 mora | C$ 99.892 + C$ 545.865 | — |
| Días de gracia | 10 | 5 | 7 |
| `empresa.nombre` | ✅ "TELECABLE MAIRENA S.A." | ❌ **VACÍO** | ✅ "Test Tenant" |
| Proveedor | `meta` (default, sin tocar) | `meta` (default) | `whatchimp` |
| Phone Number ID | ❌ vacío | ❌ vacío | ✅ `1274245055770033` |
| Access Token | ❌ no existe | ❌ no existe | ✅ (54 chars, 19-ago) |
| Plantillas | ❌ vacías | ❌ vacías | ✅ `aviso_gracia` / `aviso_mora` |
| Modo API | ❌ apagado | ❌ apagado | ✅ prendido |
| Modo gratis (wa.me) | ❌ apagado | ❌ apagado | ✅ prendido |
| Hora / frecuencia / tope | 8 / semanal / 200 | 8 / semanal / 200 | 8 / semanal / 200 |
| Envíos registrados | **0** | **0** | 2 (19-ago, `api:whatchimp`) |

### Qué le falta a TELECABLE MAIRENA

- [ ] **Todo el trámite de Meta desde cero** (A1 a A9).
- [ ] **La verificación del negocio es OBLIGATORIA para él** si va a frecuencia semanal: necesita ~258 envíos/día y el techo sin verificar es **250/día** (§5).
- [ ] Nuestro lado: pegar los 4 datos + elegir tope/frecuencia + hora 8.
- [ ] **Limpiar 293 teléfonos que dicen literalmente "0"** (16% de los envíos se van a la basura todos los días).
- [ ] Ya tiene bien cargado el nombre de empresa ✅.
- ⚡ **Hoy, sin Meta, sin plata y sin trámite:** se le puede prender el **modo gratis (wa.me)** con 1 click nuestro (`cobranza.notif_whatsapp_habilitado` → true). Hoy ni siquiera eso está prendido.

### Qué le falta a TELENET

- [ ] **Todo el trámite de Meta desde cero** (A1 a A9).
- [ ] **Paso propio que Mairena no tiene: cargar el nombre de la empresa** (`empresa.nombre` está vacío → el mensaje sale sin firma).
- [ ] Nuestro lado: los 4 datos + **hora 9** (para no chocar con Mairena).
- [ ] Limpiar 9 clientes que tienen **dos teléfonos pegados en un solo campo** (16 dígitos, tipo `8888 8888 / 7777 7777`) — se mandan como un número inexistente y fallan siempre.
- ✅ **Ventaja: con ~64 envíos/día entra cómodo debajo del techo de 250 de una cuenta sin verificar** → puede empezar a mandar **mientras la verificación está en trámite**. Su tope de 200 está bien y no hay que tocarlo.
- ⚡ También le sirve el modo gratis wa.me hoy mismo.

### Qué le falta al TEST TENANT

- ✅ Configuración completa (WhatChimp, token, phone id, 2 plantillas, todo prendido) y el cron lo procesa bien a las 8 am.
- [ ] Lo único que falta es que la cuenta de Meta detrás tenga **método de pago** → es el **131042**.
- ⚠ **Para volver a probar hay que pasar la frecuencia a "Todos los días"**: sus 2 únicos clientes con teléfono fueron notificados el 19-ago y el dedupe semanal los tapa hasta el 26. Si no, "Probar con un cliente" va a devolver *"No hay clientes elegibles para probar ahora"* y se va a diagnosticar como un bug del pipeline cuando es el dedupe funcionando bien.

---

# 2) Costos

## Precio por mensaje

Nicaragua no tiene tarifa propia: cae en el mercado **"Rest of Latin America"**, y el precio se determina por el **código de país de quien RECIBE** (+505), no por dónde está la empresa. O sea, no hay forma de pagar menos cambiando el domicilio de la cuenta.

| Categoría | Precio por mensaje **entregado** (USD) | ¿Descuento por volumen? |
|---|---|---|
| **Utility** (nuestros avisos de cobranza) | **US$ 0,0113** | Sí, pero recién arriba de 100.000 msj/mes → **no aplica** |
| **Marketing** (si te recategorizan) | **US$ 0,074** | **Nunca** |
| Authentication (no usamos) | US$ 0,0113 | Sí |
| Service (respuesta dentro de ventana) | **US$ 0** | — |

> **Tarifas verificadas contra la calculadora oficial de Meta el 2026-08-21** (rate card vigente desde el 2026-07-01).
> Meta solo puede cambiar precios el **1 de enero / abril / julio / octubre**, y ya anunció una ronda para el **2026-10-01** cuyos valores se publican antes del 1-sep-2026 — **"Rest of Latin America" NO figura en esa ronda**, pero **re-verificar el número en `business.whatsapp.com/products/platform-pricing#rates`** (Market: *Rest of Latin America* · Currency: *USD* · Category: *Utility*) antes de cerrar un presupuesto.

**Tres cosas que hay que decir y no se dicen:**

- **Se cobra por mensaje ENTREGADO, no por conversación de 24 h.** El modelo viejo por conversación murió el 2025-07-01 — la mitad de los blogs y calculadoras de terceros que va a googlear el dueño siguen publicando el modelo viejo.
- **No queda ningún tier gratis** para lo que mandamos. Las "1.000 conversaciones gratis por mes" desaparecieron: hoy lo gratis son las conversaciones de **Service** (las que inicia el cliente). Nuestro blast a morosos **se cobra desde el mensaje #1**.
- **Lo que no se entrega, no se cobra.** Un teléfono inválido o un cliente sin WhatsApp no genera cargo — pero **sí consume el cupo diario de Meta y se reintenta al día siguiente**.
- **Si el cliente te contesta**, se abre una ventana de 24 h y todo lo que mandes ahí adentro (incluidas plantillas Utility) sale **gratis**. El blast se paga; la conversación que dispara, no.

## Proyección mensual (Utility, US$ 0,0113)

Los escenarios **no son arbitrarios**: se corresponden uno a uno con la palanca "Re-notificar al mismo cliente" que ya está en la app.

| Frecuencia configurada | **Mairena** (1.803 notificables) | **Telenet** (445) | **Total mensual** |
|---|---|---|---|
| **Una sola vez por estado** | ~1.800 msj → **US$ 20** | ~445 → **US$ 5** | **~US$ 25** |
| **Cada 15 días** ← recomendado para arrancar | 3.660 msj → **US$ 41** | 903 → **US$ 10** | **~US$ 52** |
| **Una vez por semana** (lo que está hoy) | 7.807 msj → **US$ 88** | 1.927 → **US$ 22** | **~US$ 110** |
| **Cada 3 días** | 18.210 msj → **US$ 206** | 4.494 → **US$ 51** | **~US$ 257** |
| **Todos los días** | ❌ no recomendado — ver §5 | ❌ | — |

## El escenario de desastre: recategorización a Marketing

Si Meta decide que la plantilla es Marketing (lo hace **automáticamente**, por contenido, sin que nadie toque nada), la misma cantidad de mensajes pasa a **US$ 0,074**:

| Frecuencia | Utility | **Marketing** | Diferencia |
|---|---|---|---|
| Cada 15 días | US$ 52 | **US$ 338** | +US$ 286/mes |
| Semanal | US$ 110 | **US$ 720** | +US$ 610/mes |

Desde el 2025-04-09, si elegís Utility y Meta determina que es Marketing, **la plantilla se aprueba directamente como Marketing**. Y para negocios que abusan de la categorización, desde el 2025-04-16 **ya no hay aviso previo de 24 h**. Se puede pedir revisión hasta 60 días después.

> 🔁 **Chequeo mensual obligatorio: mirar la categoría de las 2 plantillas en WhatsApp Manager.** No hay nada que podamos hacer desde el código — la categoría no viaja en el envío, se define en Meta al crear la plantilla. Hoy `whatsapp_envios` **no guarda la categoría**: es un hueco conocido.

## Quién paga y por qué la cuenta va a nombre del ISP

**Paga el ISP, directo a Meta, con su propia tarjeta.** Nosotros no facturamos mensajes ni ponemos la tarjeta. Las razones no son de comodidad — son de Meta y de riesgo:

1. **La WABA no se puede transferir.** Meta dice textual: *"You cannot migrate a WABA from one business to another"* y *"A WABA must belong to only one business portfolio"*. Si la creamos nosotros "para ayudar", **después no se la podemos pasar nunca**. Habría que rehacer todo: número, plantillas, verificación.
2. **El límite de mensajería se comparte por portfolio.** Desde el 2025-10-07 el tope es **por business portfolio, compartido por todos los números que cuelgan de él**. Si Mairena y Telenet colgaran del mismo portfolio, **se pelean los mismos 250/día** y el segundo empieza a fallar sin causa aparente cuando el primero ya gastó la cuota.
   > Matiz honesto: Meta **no prohíbe** que un portfolio tenga varias WABAs (permite hasta ~20). O sea, técnicamente se podría. La recomendación de un portfolio por ISP es por **negocio y riesgo**, no porque Meta lo impida.
3. **Cada uno verifica con SUS documentos.** La verificación del negocio se hace con el acta constitutiva y el RUC del ISP. No hay forma de hacerla "por" otro.
4. **Si a un ISP le restringen la cuenta, no arrastra al otro.**
5. **El número y la relación con los clientes son del ISP.** El día que nos separemos, el ISP se queda con su número y su historial — y nosotros sin un pasivo ajeno. (Relevante para el traspaso.)
6. **Para pagar nosotros por todos habría que ser Solution Partner aprobado por Meta** ⚠ (programa formal, no un checkbox) y poner **nuestra propia línea de crédito** — asumiendo el riesgo crediticio de todos los ISP. Además Meta **deprecó** el modelo viejo "On-Behalf-Of" donde el partner era dueño de la WABA del cliente: hoy empuja a que la cuenta sea del negocio final.

**Impuestos.** El contrato de Meta dice textual: *"You are responsible for bearing and remitting any taxes that apply to your transactions"*. La factura llega en **USD**. ⚠ **No pudimos confirmar** si Meta le agrega IVA a una empresa nicaragüense (Nicaragua no aparece en la lista publicada de países donde Meta recauda IVA por cuenta propia, pero no pudimos leer la lista completa), ni qué obligación local tiene el ISP de autoliquidar IVA por servicio importado o retener sobre pagos al exterior. **Eso lo consulta el ISP con su contador. No damos ninguna cifra.**

## Comparación con el intermediario (WhatChimp)

| | **Meta directo** | **WhatChimp** |
|---|---|---|
| Suscripción | **US$ 0** | ⚠ desde **US$ 24/mes por número** (dato del contexto del pedido, **no verificado por nosotros** — verificalo antes de ponerlo por escrito ante el ISP) |
| Costo por mensaje | US$ 0,0113 (a Meta) | **el mismo** US$ 0,0113 a Meta, **además** de la suscripción |
| Trámite con Meta | Completo | **Exactamente el mismo trámite** |
| Variables de plantilla | Con nombre (el orden no importa) | Posicionales (`{{1}}..{{4}}`, el orden ES el dato) |
| Extras | ninguno | bandeja de entrada, chatbot, campañas |

Para dos ISP eso es **~US$ 48/mes = US$ 576/año** de sobrecosto (≈44% de la factura de mensajes en el escenario semanal), a cambio de cero pasos de papeleo ahorrados.

---

# 3) Límites de Meta y qué frecuencia elegir

## Los escalones reales (no son 250 → 1.000 → 10.000)

**250 → 2.000 → 10.000 → 100.000 → ilimitado.** El escalón de 1.000 **ya no existe** (cambió en 2025) — si la guía dice 1.000, el dueño va a pensar que algo está mal cuando vea 2.000 en su panel.

- El límite cuenta **destinatarios ÚNICOS** a los que se entrega un mensaje **fuera de la ventana de atención**, en una ventana **móvil de 24 horas** (no el día calendario). Reenviarle 3 veces al mismo cliente cuenta 1.
- **De 250 a 2.000:** tres caminos alternativos — (a) verificar el negocio, (b) que lo verifique un partner, o (c) entregar 2.000 mensajes a números únicos en 30 días con plantillas de buena calidad. **El camino (c) es una trampa**: exige mandar 2.000 estando topeado en 250/día = 8+ días de goteo. **Verificar es el camino corto**, y el ISP la necesita igual. Aprobada la verificación, el salto a 2.000 es **inmediato**.
- **De 2.000 en adelante sube solo**, +1 escalón **en 6 horas**, pero **con condición de uso**: hay que mandar con buena calidad **y** haber usado **al menos la mitad del límite** en los últimos 7 días. Mairena con 258/día contra un tope de 2.000 usa el 13% → nunca va a auto-escalar a 10.000, **y no lo necesita**.
- **La mala calidad ya no baja el escalón** (el estado "Flagged" desapareció en oct-2025). No es vía libre igual: la calidad sigue afectando la aprobación y la pausa de plantillas.

## La cuenta que define la frecuencia

| Frecuencia | Mairena: envíos/día | Telenet: envíos/día | ¿Entra en 250 (sin verificar)? | ¿Entra en el tope 200 de la app? |
|---|---|---|---|---|
| Cada 15 días | **120** | 30 | ✅ sí | ✅ sí |
| **Semanal (lo de hoy)** | **258** | 64 | ❌ **NO (Mairena)** | ❌ **NO (Mairena)** |
| Cada 3 días | 601 | 148 | ❌ | ❌ |
| Todos los días | 1.803 | 445 | ❌ | ❌ |

> 🛑 **Confirmado en vivo, y es el hallazgo más accionable de todos:** hoy, llamando a la función para Mairena con el tope en 200, devuelve **exactamente 200 filas y las 200 son de MORA — cero de gracia**. La cola se ordena por deuda más vieja primero, así que **con el tope actual los avisos PREVENTIVOS (los únicos que evitan el corte) nunca se mandarían**.

**Recomendación para arrancar Mairena: frecuencia "Cada 15 días"** → 120/día. Entra debajo del techo de 250 sin verificar, entra en el tope de la app, entra en el presupuesto (US$41/mes) y **deja pasar los avisos de gracia**. Cuando la verificación esté aprobada (2.000/día) se puede subir a semanal, y ahí sí subir el tope de 200 a 300 — **pero antes medir la duración real de una corrida** contra el límite de la Edge Function (§B0.3).

> ⚠ **"Todos los días" es una trampa**: el tope es un `LIMIT` por corrida, no un contador acumulado. Con frecuencia diaria y tope 200, los mismos 200 clientes más viejos reciben el mensaje **todos los días** y el resto nunca. No la uses en un tenant grande.

Y ojo con el dedupe: **solo bloquean los envíos con `ok = true`**. Un teléfono basura falla, no consume la ventana, y se reintenta al día siguiente — **todos los días, para siempre**, quemando cupo.

---

# 4) Teléfonos: lo que hay que limpiar antes de prender el automático

La función que elige a quién avisar solo exige que el teléfono **no sea nulo ni vacío** — no valida el formato. La app agrega el `505` **solo si quedan exactamente 8 dígitos**; cualquier otro largo se manda **tal cual**.

| Tenant | Con 8 dígitos válidos | Basura | Detalle |
|---|---|---|---|
| Mairena | 3.709 | **652** | **629 dicen literalmente `"0"`**, 9 tienen 16 dígitos, 4 tienen texto ("Somotillo", "Villanueva"), el resto largos raros |
| Telenet | 986 | **21** | 15 con **dos números pegados** (16 dígitos, `NNNN NNNN / NNNN NNNN`), 2 con `"0"` |

**Cero clientes en toda la base tienen el 505 guardado** — está bien así, no hay que pedirle al ISP que lo agregue.

En el universo notificable de hoy eso significa: **Mairena manda ~16% de sus avisos a la basura**, todos los días.

---

# 5) Tiempos realistas

| Paso | Cuánto tarda | ¿Quién depende? |
|---|---|---|
| Registro de desarrollador | Minutos | ISP |
| Crear portfolio + cargar datos del negocio | 15 min | ISP |
| **Verificación del negocio** | ⚠ **Meta no publica un SLA.** Consenso de integradores: **1 a 5 días hábiles**; hay casos en minutos y otros de hasta 2 semanas. **NO prometas una fecha** | Meta |
| Crear la app + la WABA | 15 min | ISP |
| Registrar y verificar el número (OTP + PIN) | Minutos (el OTP llega al instante) | ISP |
| Cargar moneda, zona horaria y tarjeta | 15 min, pero el estado de elegibilidad puede tardar **hasta 24 h** en refrescar ⚠ | ISP + su banco |
| **Aprobación de las plantillas** | **Hasta 24 h** (oficial). En la práctica suele salir en minutos. Las apelaciones también dentro de 24 h | Meta |
| Salto de 250 → 2.000 | **Inmediato** al aprobarse la verificación | Meta |
| Salto de 2.000 → 10.000 | 6 h, **si se cumple la condición de uso** (≥ mitad del tope, 7 días) | Meta |
| **Nuestro setup en el panel** | **15 minutos** | Nosotros |
| Prueba de humo + confirmación de entrega | 10 min | Nosotros + ISP |

**Cronograma honesto para decirle al ISP:** *"de 2 días a 2 semanas, y el que manda el reloj es la verificación del negocio — todo lo demás sale el mismo día."*

**Los dos pasos que NO tienen workaround y de los que hay que hacer seguimiento:** la **verificación del negocio** (A3) y la **tarjeta asignada a la WABA** (A7).

---

# 6) Troubleshooting

## 6.1 — Error 131042 (el que nos frenó) — *"Business Eligibility Payment Issue"*

**Qué significa:** Meta no encuentra un medio de pago válido para cubrir los cargos. **Mientras dure, los mensajes salientes quedan COMPLETAMENTE bloqueados.**

**Quién lo resuelve: SOLO el dueño de la WABA.** Nosotros no podemos hacer nada.

**Las 8 causas oficiales de Meta** (lista completa, usar tal cual como checklist — no la versión de los blogs):

1. La cuenta de pago no está vinculada a la WhatsApp Business Account
2. Se excedió el límite de la línea de crédito
3. La línea de crédito no está activa o no está configurada
4. La WABA fue borrada
5. La WABA está suspendida
6. **Zona horaria sin configurar**
7. **Moneda sin configurar**
8. La solicitud "On Behalf Of" está pendiente o fue rechazada

> **Dato que casi nadie menciona: los puntos 6 y 7 son causas por sí solas.** Podés tener la tarjeta cargada y perfecta y seguir con 131042 si la WABA no tiene moneda y zona horaria definidas.

**Orden de diagnóstico** ⚠ (frecuencia según integradores, no doctrina de Meta):

1. **La tarjeta está en el portfolio pero NO vinculada a esa WABA en particular.** Es lo más común. Agregar el medio de pago al portfolio (para Ads) **no alcanza**.
2. Moneda y/o zona horaria sin setear en la WABA.
3. Falta información fiscal en el Business Manager.
4. La tarjeta rebotó (débito nicaragüense sin cargos recurrentes internacionales, prepaga, sin cupo).

Una vez bien vinculada, el error **suele limpiarse al instante**, pero puede tardar **hasta 24 h** en refrescar.

## 6.2 — Tabla de errores

| Síntoma | Qué es | Quién lo resuelve |
|---|---|---|
| **131042** | Falta medio de pago / moneda / zona horaria en la WABA | **El ISP** (§6.1) |
| Meta responde *"template name does not exist in the translation"* | El **nombre** o el **idioma** de la plantilla en la app no coincide **exacto** con Meta. Ojo con `es` vs `es_MX`, y con mayúsculas (Meta guarda todo en minúscula + guión bajo) | Nosotros (corregir el setting) |
| Meta rechaza por parámetros | La plantilla se creó en formato **posicional** (`{{1}}`) y la app manda variables **con nombre** ⚠ (no confirmamos el código de error exacto) | El ISP: hay que **recrear** la plantilla en formato con nombre |
| Meta rechaza el envío por componentes | La plantilla tiene un **header con variable** o un **botón con URL variable**. La app manda **un solo componente: `body`** | El ISP: rehacer la plantilla con variables **solo en el cuerpo** |
| El mensaje sale con el monto donde va el nombre | Solo pasa en WhatChimp (variables posicionales desordenadas). En Meta el orden no importa | — |
| El mensaje sale firmado en blanco | `empresa.nombre` vacío en settings (**caso Telenet hoy**) | Nosotros / el admin del ISP |
| Plantilla **rechazada** por Meta | Empieza o termina con variable · llaves desparejadas · tono amenazante · pide cédula/tarjeta · duplicado exacto | El ISP (corregir y apelar; se resuelve en ≤24 h) |
| **La factura se multiplicó por 6,5** | La plantilla se **recategorizó a Marketing** | El ISP: pedir revisión en WhatsApp Manager (hasta 60 días) |
| El lote devuelve **401 "No autorizado"** | `CRON_SECRET` (lado función) y el secret `whatsapp_cron_secret` del Vault (lado cron) se **desincronizaron**. No se puede leer el valor: hay que **resetear los dos a la vez** | Nosotros |
| `net._http_response` dice **`tenantsProcesados: 0`** | El tenant no pasó uno de los 3 gates: modo API apagado, token no configurado, o **no es su hora**. **No deja rastro en `whatsapp_envios`** | Nosotros |
| `tenantsProcesados: 1, enviados: 0` | Pasó los gates y **no había clientes elegibles** (dedupe). No es un error | — |
| *"No hay clientes elegibles para probar ahora"* al apretar **Probar** | La ventana de dedupe tapó a todos. Para re-probar, pasar la frecuencia a **"Todos los días"** | Nosotros |
| *"Falta cargar el Access Token"* al apretar Probar | El setting espejo `token_configurado` está en true pero **no hay fila** en `whatsapp_credenciales` | Nosotros (re-guardar el token) |
| **El log dice `ok = true` pero el cliente no recibió nada** | **`ok` = "el proveedor aceptó el pedido", NO "se entregó".** No hay webhook de entrega. **Fue exactamente lo que pasó el 19-ago con el 131042** | Mirar el panel de Meta / Business Manager — **nuestro log no ve la entrega** |
| **Todos los envíos por Meta empiezan a fallar de golpe, sin cambios** | La versión de Graph API **v21.0 expiró** (fecha: **2027-01-21**) | Nosotros (una línea + redeploy) |
| El lote se corta a la mitad | **Timeout de la Edge Function** (150 s en plan Free / 400 s en plan pago) por lote secuencial demasiado largo | Nosotros (bajar tope, separar horas) |
| El envío deja de andar exactamente a las 24 h de haberlo configurado | Se copió el **token temporal** de la pantalla API Setup en vez del **permanente del System User** | El ISP (regenerar en A9) |
| `cron.job_run_details` dice `succeeded` pero no pasó nada | **Ese log miente**: solo registra que el `http_post` se encoló | Mirar `net._http_response` |

---

# 7) Correcciones a la documentación previa (para el equipo)

Al cerrar, hay que arreglar estas dos cosas que hoy le mienten a la próxima sesión:

1. **`Install Steps/WhatsApp-API-setup.md` §3** publica el cron viejo con `Authorization: Bearer <SERVICE_ROLE_KEY>`. **Eso ya no funciona**: desde la migración 0239 (corrida en prod el 2026-08-18) la autenticación es por header **`x-cron-secret`** contra el secret `CRON_SECRET`, porque tras la migración de claves de Supabase de agosto 2026 la comparación contra la service key dejó de matchear. **Si alguien copia ese SQL viejo y re-crea el job, el lote empieza a devolver 401.** El cron ya existe, es **uno solo y global** — no hay que crearlo por tenant.
2. **`ARQUITECTURA.md:458`** dice *"El cron sigue SIN instalar → hoy no sale nada solo"*. **Es falso desde el 2026-08-19**: está activo, con 61 corridas y respuesta 200 verificada.

También hay que actualizar las etiquetas: la tarjeta hoy se llama **"WhatsApp API"** (no "WhatsApp por API") y el switch **"Activar WhatsApp API"** (no "Activar envío automático por API").

---

## Resumen ejecutivo en 6 líneas

1. **La infraestructura está lista y probada end-to-end.** Falta únicamente el trámite de cada ISP con Meta.
2. **Los 4 datos del sobre son lo único que necesitamos.** Sin ellos no hay nada que hacer de nuestro lado.
3. **La verificación del negocio se arranca primero** — es lo que tarda, y Mairena no puede operar sin ella a frecuencia semanal.
4. **La cuenta y la tarjeta van a nombre del ISP**, porque una WABA no se transfiere nunca.
5. **Presupuesto realista: US$41/mes Mairena + US$10/mes Telenet** arrancando en "cada 15 días"; US$110/mes total si van a semanal.
6. **Mientras tanto, hoy mismo y gratis:** prenderles el modo wa.me manual con un click.