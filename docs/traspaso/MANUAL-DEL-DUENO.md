# MANUAL DEL DUEÑO — CRM

*Guía para el dueño del negocio. No necesitás saber programar para leerla entera.*

---

## Bienvenida: qué estás recibiendo

Hola.

Si estás leyendo esto, es porque estás por recibir el control de **CRM**, el sistema de cobranza que se construyó para proveedores de internet en Nicaragua. Lo primero que quiero que te quede claro: **no te estoy pasando una idea ni un proyecto a medias. Te estoy entregando un negocio que ya está andando**, con clientes reales que lo usan todos los días y plata de verdad pasando por adentro. Eso es lo más valioso de todo, y también lo que más cuidado pide.

Este manual está escrito para vos, que sabés de negocios pero no de programación. No vas a encontrar acá nombres de archivos ni código —eso vive en otro documento, el "traspaso técnico", que se lo vas a pasar al programador que contrates—. Acá vas a encontrar todo lo que necesitás entender como **dueño**: qué hace la app y por qué vale, qué piezas la mantienen viva y cuáles pagás vos, qué reglas son sagradas, qué cosas son irreemplazables, y de qué sos responsable de ahora en más.

Voy a ser honesto desde el arranque con algo, así no te sorprende después: **esta app necesita un programador para mantenerse y crecer.** Tu rol como dueño NO es escribir código. Tu rol es ser el dueño de las cuentas, los secretos y el dinero, y trabajar codo a codo con ese programador. Hay una sección entera sobre esto más abajo. Pero quería que lo supieras desde la primera página.

Respirá. Vamos por partes, tranquilo.

---

## 1. Qué hace tu app (y por qué vale plata)

CRM le resuelve a un proveedor de internet (un "ISP") el dolor de cabeza más grande que tiene: **cobrar y no perder plata en el camino.**

Imaginate una empresa de internet de barrio o de pueblo. Tiene cientos o miles de clientes que pagan una mensualidad. Tiene cobradores que salen a la calle, casa por casa, a cobrar en efectivo. Y tiene una oficina que necesita saber, al final del día, **cuánta plata entró, quién la cobró, y a quién hay que ir a cortarle el servicio porque no pagó.** Antes eso se hacía con cuadernos, Excel y mucha fe. La app lo convierte en un sistema ordenado, a prueba de "se me perdió la cuenta".

Pensala como la **caja registradora + la libreta de clientes + el mapa de cobradores** de una empresa de internet, todo en una sola app.

Lo más lindo del modelo: **la misma app le sirve a varias empresas a la vez**, cada una con su nombre y su logo, y los datos de una **jamás** se mezclan con los de otra. En el rubro a esto se le dice *white-label* (marca blanca): es como un edificio de oficinas donde cada empresa tiene su piso cerrado con llave, y nadie entra al piso del vecino.

**Hoy, dos empresas reales ya viven adentro, pagando, con plata real moviéndose:**

| Empresa | Cuántos clientes maneja |
|---|---|
| **Telecable Mairena** | ~4.600 clientes |
| **Telenet** | ~1.187 clientes |

Eso es casi **6.000 hogares** cuya cobranza pasa por este sistema todos los meses. No es un demo. Es plata real, de empresas reales, que confían en que la app no se equivoca. Esa confianza es, literalmente, el activo más importante del negocio.

La versión que recibís es la **v0.17.2**, estable y en producción (o sea: la que están usando los clientes reales ahora mismo). Corre en dos lugares:

- **Celulares Android** → los cobradores que andan en la calle. **Funciona SIN internet** (más sobre esto abajo, es la magia del producto).
- **Computadoras Windows** → la oficina: administración y reportes.

### El corazón del producto: trabaja SIN internet

Esta es la característica más ingeniosa del sistema y vale la pena que la entiendas, porque define todo lo demás.

El cobrador anda por barrios donde muchas veces **no hay señal**. Si la app necesitara internet para cobrar, sería inútil. Así que está diseñada para que **el cobrador cobre, registre pagos, imprima recibos y trabaje normal sin una sola barra de señal.** El celular lleva adentro una copia de su parte de la información. Cuando vuelve a tener internet (en la oficina, en su casa), todo lo que hizo **sube solo**, sin que nadie apriete ningún botón.

Pensalo como un cajero de banco que sigue anotando todo en su libreta cuando se corta la luz, y cuando la luz vuelve, la libreta se copia sola al sistema central. Nunca se pierde un cobro.

En el mundo del software a esto se le dice *offline-first* (primero sin conexión) y es el ADN del producto. Cualquier cosa nueva que se le quiera agregar tiene que respetar esta regla.

### Lo que la app ya sabe hacer hoy

Esto es el valor que estás comprando: la app ya hace todo esto, hoy, sin que nadie le agregue nada.

- **Clientes, contratos y cuotas** — da de alta clientes, sus contratos (cuánto pagan, cada cuánto, desde cuándo) y genera solas las cuotas mensuales.
- **Cobro de pagos** (acá está la inteligencia del negocio) — registra el pago en efectivo, calcula el **vuelto**, acepta **varias monedas** (el cliente puede pagar en dólares aunque la cuota esté en córdobas) y maneja **crédito a favor** (si paga de más, ese excedente le queda como saldo para la próxima).
- **Recibos** — genera el comprobante para entregarle al cliente.
- **Mora y suspensiones** — controla quién está atrasado y cuánto, y maneja el corte de servicio a los que no pagan.
- **Tickets técnicos** — un módulo de soporte para reportar y seguir problemas de los clientes (un internet que no anda, una visita pendiente).
- **Mapa de clientes** — para que el cobrador vea dónde están sus clientes y arme su recorrido. Usa mapas públicos gratuitos, sin costo de licencia.
- **Aviso por WhatsApp** — hoy funciona el modo **gratis**: la app abre WhatsApp con el mensaje ya escrito y la persona solo aprieta enviar. (Existe además una versión **automática** ya construida pero **apagada** — más abajo te cuento.)
- **Reportes de caja por cobrador** — al cierre del día, la app dice **cuánta plata entró y quién la cobró.** Esto es oro para el dueño del ISP: es el control anti-robo y anti-error.
- **Multi-empresa con datos blindados** — varias empresas en el mismo sistema, **100% aisladas**. Mairena nunca ve un cliente de Telenet, y viceversa. No es una promesa: está garantizado por la forma en que está construida la base de datos.

---

## 2. Cómo está hecha y qué necesitás para mantenerla viva

Acá viene la parte más importante para vos como dueño. La app no es "una sola cosa": son **varios servicios trabajando juntos**, como los proveedores de un local (el de la carne, el de la luz, el del alquiler). El dueño del local —vos— no cocina, pero sabe quién es cada proveedor y qué pasa si deja de pagarle a alguno. Algunos los pagás todos los meses, todos te pertenecen, y si te olvidás de uno crítico, la cocina se apaga.

Te lo dibujo en lenguaje de negocio:

```
   ┌──────────────────────────────────────────────────────────┐
   │   LA APP (en el celular del cobrador o la PC de oficina)  │
   │   La que la gente toca y usa todos los días.             │
   │   Lleva adentro una copia para trabajar SIN internet.   │
   └─────────────────┬───────────────────────┬────────────────┘
                     │                       │
        cuando hay señal,           entra con usuario y clave
        sincroniza                          │
                     ▼                       ▼
   ┌──────────────────────────┐   ┌──────────────────────────────┐
   │  EL MENSAJERO OFFLINE    │──►│  EL CEREBRO EN LA NUBE        │
   │  (PowerSync)             │   │  (Supabase)                   │
   │                          │   │                               │
   │  Hace que el cobrador    │   │  Guarda TODO: clientes,       │
   │  trabaje sin señal y      │   │  pagos, usuarios, recibos.    │
   │  que el celular y el      │   │  Es la verdad oficial. Si     │
   │  cerebro se pongan de     │   │  esto se cae, la oficina no   │
   │  acuerdo solos.          │   │  ve nada.                     │
   └──────────────────────────┘   └──────────────────────────────┘

   ┌──────────────────────────────────────────────────────────┐
   │   LAS DOS CAJAS FUERTES (GitHub)                          │
   │   ① PRIVADA: el "plano" completo de la app + la docu.    │
   │      Solo la ven vos y tu programador.                   │
   │   ② PÚBLICA: de acá los celulares bajan solos las        │
   │      actualizaciones. Debe quedar pública.               │
   └──────────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────┐
   │   LA FIRMA DIGITAL DE LA APP (el "keystore")             │
   │   IRREEMPLAZABLE. Sin ella, ningún celular acepta una    │
   │   actualización nueva. NUNCA jamás se puede perder.      │
   └──────────────────────────────────────────────────────────┘
```

Ahora, pieza por pieza, en criollo:

### El cerebro en la nube — "Supabase"

Supabase es **la base de datos en la nube**: el lugar donde vive absolutamente toda la información del negocio. Clientes, contratos, cada pago que se cobró, cada usuario, cada recibo. (Una "base de datos" es simplemente el gran archivero digital donde se guarda todo en orden.) Es la **fuente de la verdad**: si dos pantallas no coinciden, la que manda es esta.

Pensalo como **la bóveda central del banco**: toda la información está ahí, y todas las sucursales (los celulares) consultan contra ella.

- **Es lo más crítico de todo.** Si se cae Supabase, la oficina deja de ver datos.
- **Tiene plan pago.** Cuesta plata por mes según cuánta información guardás y cuánto movimiento tiene. Con casi 6.000 clientes, esto ya está en zona de plan pago. Es un costo fijo que vas a tener.
- **Acá viven los datos de Mairena y Telenet.** Por eso, en el traspaso, lo ideal es **transferirte el proyecto entero** en vez de crear uno nuevo: así no se mueve ni un dato y todo sigue conectado solo.

### El mensajero offline — "PowerSync"

PowerSync es el servicio que hace posible el "trabaja sin internet". Es **el que se encarga de que la copia del celular y el cerebro en la nube se pongan de acuerdo** cuando vuelve la señal, mandándole a cada cobrador solo la parte que le toca.

Pensalo como **el servicio de mensajería que lleva y trae los paquetes** entre cada sucursal y la bóveda central, asegurándose de que nada se pierda ni se duplique.

- **También tiene plan pago**, que sube según cuántos celulares y cuántos clientes hay. **Ojo con esto:** ya se rozó una vez el límite del plan gratuito. A medida que sumás empresas grandes, este costo escala. Conviene tener una alerta puesta antes de subir un cliente nuevo y grande.
- Es un servicio **aparte** de Supabase, con su propio panel de control. Son dos cosas distintas que conversan entre sí.

> **Un detalle que tu programador tiene que conocer:** Supabase y PowerSync están conectados por una credencial de confianza que se configura a mano en el panel de PowerSync. Si esa conexión se rompe, pasa algo confuso: **la app deja entrar a la gente, pero no sincroniza nada** (todo queda como si no hubiera internet). El síntoma no grita "es esto", así que tu dev tiene que saber dónde mirar. Está documentado.

### Las dos cajas fuertes — "GitHub"

GitHub es donde se guardan dos cosas, en dos "cajas fuertes" separadas. (Cada caja fuerte es lo que en el rubro llaman un *repositorio* o *repo*: simplemente una carpeta en la nube con todo adentro y su historial de cambios.)

1. **La caja PRIVADA** guarda el **plano completo de la app** —el "código fuente", o sea las instrucciones con las que un programador construye, arregla o mejora la app— **más toda la documentación** del proyecto. Esta es la memoria del negocio. Tiene que quedar **privada**: nadie de afuera la ve.

2. **La caja PÚBLICA** es de donde **los celulares y las computadoras bajan solas las actualizaciones**. Cuando tu programador publica una versión nueva, las apps de Mairena y Telenet la detectan y se actualizan solas desde acá. Esta caja **tiene que quedar PÚBLICA**, sí o sí. Si por error quedara privada, **las apps dejarían de actualizarse y nadie se daría cuenta** (falla en silencio, sin aviso). Tranquilo: esta caja solo guarda los instaladores, no el código.

Pensalo así: la caja privada es **el plano del edificio guardado bajo llave**; la caja pública es **el buzón de la entrada por donde llegan las mejoras.**

- GitHub **puede ser gratis** para esto. No es un costo grande, pero la cuenta tiene que ser tuya.

### La firma digital — el "keystore" (LO MÁS IRREEMPLAZABLE)

Esto necesito que lo leas dos veces.

Cada app de Android está **firmada** con una llave digital única, como la **firma notariada del dueño**. Android tiene una regla de fierro: **una actualización solo se acepta si está firmada con la MISMA llave que la versión anterior.** Es su forma de asegurarse de que la actualización viene de quien dice venir.

Esa llave —el "keystore"— **es única, no se puede regenerar, y vive en un archivo.** Si ese archivo se pierde:

> **Ningún celular Android ya instalado vuelve a actualizarse JAMÁS.** Para arreglarlo habría que desinstalar y reinstalar la app en cada celular de cada cobrador, **perdiendo toda la información que tenían guardada offline.** Para casi 6.000 clientes repartidos entre cobradores, es un desastre operativo.

Por eso, **apenas recibas ese archivo, sacale una copia a un pendrive o una caja fuerte digital que NO esté en la computadora.** Si la computadora se rompe o se formatea y solo estaba ahí, lo perdiste para siempre.

La buena noticia: ya existe un **respaldo cifrado** (un archivo protegido con contraseña, como un cofre con candado) que guarda la firma y los otros secretos juntos. Lo vas a recibir, junto con la contraseña para abrirlo (que se entrega por un canal separado, por seguridad).

### Los mapas

Gratis, sin cuenta ni nada que pagar. La app usa mapas públicos. No te preocupes por esta pieza.

---

## 3. ¿Necesito un programador?

**Sí. Sin vueltas.** Esta app es un producto de software vivo: tiene clientes reales, recibe pagos reales, y va a necesitar arreglos y mejoras. **Vos no la vas a mantener tocando código** —ese no es tu rol—.

**Lo que es TUYO (no necesitás programar para esto):**
- Ser el **dueño de todas las cuentas y secretos** (Supabase, PowerSync, GitHub, la firma digital).
- **Pagar los servicios** mensuales y vigilar que no se disparen los costos (sobre todo PowerSync cuando crezcan los clientes).
- **Guardar los respaldos** a salvo.
- **Decidir el rumbo del producto**: qué clientes nuevos sumar, qué features priorizar, qué cobrar.
- **Ser el guardián de las reglas de dinero** (sección 4): ante cualquier cambio que toque la plata, exigir que se respeten y se verifiquen.

**Lo que necesita un PROGRAMADOR (no lo hagas vos):**
- Publicar versiones nuevas de la app.
- Corregir errores y agregar funcionalidades.
- Tocar la base de datos o arreglar los datos de un cliente.
- Activar la integración automática de WhatsApp si algún día querés.
- Cualquier cosa que diga "configurar", "publicar", "migrar" o "código".

**Te lo digo claro y sin vueltas:** sin un programador, esta app **sigue funcionando** para los clientes que ya la tienen, pero **no podés actualizarla, arreglarla ni crecer.** No tenés que contratar a alguien full-time desde el día uno, pero sí necesitás un dev de confianza disponible. Ese costo (un programador, por hora o por proyecto) es parte del costo real de ser dueño de esto. Tenelo en el presupuesto.

**Qué buscar en ese programador:** alguien cómodo con Flutter (el lenguaje en que está hecha la app) y con bases de datos. La buena noticia es que el proyecto está **muy bien documentado**: hay una serie de documentos que explican cómo está hecho todo, las reglas, las trampas y hasta el historial de decisiones. Un buen dev se pone al día leyendo eso. Pasale el documento técnico de traspaso —está hecho para él—.

> Hay **una sola cosa** en todo el mantenimiento que, por cómo está armado PowerSync, hoy requiere un paso manual de copiar-y-pegar en un panel web. No es complicado, pero es bueno que sepas que existe: tu programador lo va a manejar.

---

## 4. Las reglas sagradas del dinero (no se tocan)

Esta es la parte que separa una app de cobranza confiable de una que pierde clientes. Te las explico no como reglas técnicas, sino como **principios del negocio**, porque eso es lo que son.

El motivo de fondo es uno solo: **si la caja no cuadra, el ISP pierde confianza en el sistema, y si pierde confianza, se va.** La confianza es el producto. Estas reglas son lo que la sostiene.

Cualquier programador que toque la lógica de plata **tiene que respetarlas a rajatabla.** Tu trabajo como dueño es **conocerlas y exigir que se respeten.** Estas son las principales, en criollo:

**1. Lo que entra a la caja es lo que se aplica a la cuota, NO lo que el cliente sacó del bolsillo.**
Si la cuota es 500 y el cliente te da 1.000, a la caja entran 500 (lo de la cuota), no 1.000. La diferencia es vuelto o crédito, no recaudación. Mezclar esto inflaría la caja con plata que en realidad volvió al cliente.

**2. El vuelto SIEMPRE se da en córdobas, aunque el cliente haya pagado en dólares.**
El cliente puede pagar con un billete de dólar, pero el cambio se le devuelve en moneda local. Nunca al revés. Es la práctica real del negocio.

**3. El crédito a favor NO es plata que entró a la caja.**
Si un cliente queda con saldo a favor y después lo usa, eso es un descuento contra una cuota futura, no un cobro nuevo. Es deuda tuya con él, no caja tuya. Tratarlo como ingreso contaría la misma plata dos veces.

**4. Todas las pantallas tienen que mostrar el MISMO número.**
El saldo de un cliente tiene que dar idéntico lo mires desde donde lo mires: en el arqueo del día, en el reporte, en la ficha del cliente. Si dos pantallas muestran números distintos, **una está mal**, y eso es una alarma roja: hay que parar y averiguar antes de seguir. Un número que baila destruye la confianza al instante.

**5. No se cobra una cuota nueva dejando una vieja sin pagar (del mismo cliente).**
Se cobra de la más vieja a la más nueva. El sistema lo obliga. Esto evita que un cliente quede con un mes saltado y un lío de mora imposible de desenredar.

**6. Quién cobró queda registrado para siempre, y no se reescribe.**
El reporte de "cuánto cobró cada cobrador" se arma con **quién registró el pago**, no con a quién está asignado el cliente hoy. Si mañana le reasignás un cliente a otro cobrador, **el historial de quién cobró qué no se altera.** Esto es clave para el control y para pagar comisiones bien.

**7. Anular un pago no lo borra.**
Queda el registro de que existió y de que se anuló. Nunca se borra historial: para "deshacer" algo, se agrega un movimiento nuevo. Esto te protege a vos: siempre hay rastro de qué pasó.

**8. Hay una regla sutil pero crítica con las fechas de cobro.**
El sistema factura "vencido" (cobra al final del período) y todo se calcula según el **día de pago de cada cliente**, no según el mes del calendario. Suena menor, pero si un programador se equivoca acá, **le sub-cobra o sobre-cobra a clientes reales sin darse cuenta.** Esta fue una fuente de errores reales en el pasado, así que tu dev tiene que tomarlo en serio.

> **Cómo se verifica que la plata cuadra:** existe una prueba automática (un chequeo de "invariantes de dinero") que se corre cada vez que se toca algo de plata. Tiene que dar **cero problemas**. Si alguna vez tu programador propone un cambio que toca la plata, la pregunta que le hacés es: *"¿esto respeta las reglas de dinero y corriste la prueba que las verifica?"* Si la respuesta no es un sí claro, no se publica. Es tu póliza de seguro contra descuadres.

---

## 5. Lo único que NO podés perder

Si perdés cualquiera de estas cosas, el daño es **permanente** —no es "lo rehacemos", es "se rompió para siempre"—. Tratalas como las escrituras de una casa.

| Qué | Por qué es irreemplazable |
|---|---|
| **La firma digital (keystore) + sus claves** | Es el archivo que firma las actualizaciones de Android. Si se pierde, ningún celular que ya tiene la app vuelve a actualizarse jamás. Habría que desinstalar y reinstalar en cada celular, perdiendo el trabajo offline de cada cobrador. **No se regenera.** Copialo a un pendrive apenas lo recibas. |
| **Los datos de Mairena y Telenet** | Los ~4.600 clientes de Mairena y los ~1.187 de Telenet viven SOLO en el cerebro (Supabase). El código sabe armar la estructura vacía, pero **no recrea los datos**. Solo viajan si **transferís** la cuenta de Supabase (no si la recreás de cero). |
| **Las contraseñas de login de los usuarios** | Como la app **no usa email** (el alta es sin correo, las claves se mandan por WhatsApp), no hay "recuperar contraseña". Viajan bien si se transfiere Supabase, pero si algún día se migra a otro tipo de servidor se perderían, y habría que re-asignarle clave a TODOS los usuarios a mano, uno por uno. |
| **La caja privada de GitHub** (el plano + la documentación) | Es la ÚNICA copia de todo el conocimiento del negocio: cómo está hecho, las reglas, la historia y las decisiones. No hay copia externa. Sin ella, un programador nuevo arranca a ciegas. |
| **El cofre cifrado de respaldo** | Es la red de seguridad de todo lo anterior: junta los secretos críticos en un solo archivo protegido con contraseña. Sacalo a un pendrive offline apenas lo tengas. |

> **Acción más urgente, el primer día:** existe un **backup cifrado** (un archivo protegido con contraseña) que junta los tres secretos críticos en un solo lugar. Recibilo, sacalo a un pendrive o caja fuerte digital **fuera de la computadora**, y guardá la contraseña de ese backup en un lugar **separado** del archivo. Si la PC se formatea y ese backup estaba solo ahí, perdés lo irreemplazable. Son diez minutos que te ahorran una catástrofe.

---

## 6. De qué sos responsable y cuánto cuesta por mes

### Tus responsabilidades como dueño (checklist)

- [ ] **Pagar los servicios** a tiempo (Supabase, PowerSync y el programador). Si dejás de pagar Supabase o PowerSync, la app deja de funcionar para los clientes.
- [ ] **Custodiar los secretos.** Sobre todo la firma digital (keystore) y su backup. Guardalos offline, en más de un lugar.
- [ ] **Ser dueño de las cuentas.** Que Supabase, PowerSync y GitHub estén a tu nombre.
- [ ] **Hacer cumplir las reglas de plata** (sección 4). Si un cambio toca dinero, exigí que se corra el chequeo de invariantes y dé cero.
- [ ] **No cambiar la identidad de la app sin un plan.** La firma, los nombres internos de cada empresa y el canal de actualización están atados entre sí. Cambiar uno mal **deja a los celulares sin poder actualizarse.** Tu programador sabe esto; tu trabajo es no improvisar acá.
- [ ] **Vigilar los límites de uso.** PowerSync y Supabase crecen con la cantidad de clientes. Antes de sumar una empresa grande nueva, que el dev revise que los planes aguanten.
- [ ] **Tener un plan de continuidad.** Si tu programador desaparece, ¿quién tiene acceso a las cuentas y los secretos? Esa respuesta tenés que tenerla vos.

### Los costos que tenés que tener en la cabeza

| Servicio | Para qué sirve | ¿Cuánto cuesta? |
|---|---|---|
| **Supabase** (el cerebro) | Guarda todos los datos y maneja el login | **Sí, plan pago según uso.** Con ~6.000 clientes ya estás en zona de plan pago. Costo fijo y crítico. |
| **PowerSync** (el mensajero) | Que el cobrador trabaje sin señal | **Sí, plan pago.** Ya se rozó el límite gratis una vez. Sube si crecés. Poné alerta. Crítico. |
| **GitHub** (las cajas fuertes) | Guarda el código y distribuye actualizaciones | **Puede ser gratis** en muchos casos. Crítico igual. |
| **Mapas** | Mapa para los cobradores | **Gratis.** Sin cuenta. |
| **WhatsApp automático** | Avisos automáticos (HOY apagado) | Solo si lo encendés, con su propio trámite/costo vía Meta. Opcional. |
| **Programador** | Mantener y mejorar la app | **El costo más fácil de subestimar.** Por hora o por proyecto. Real y necesario. |

---

## 7. Riesgos en criollo (cosas que NO son errores)

Para ahorrarte sustos, te dejo algunas cosas que parecen problemas pero son **a propósito**. Si tu programador las ve y duda, la respuesta está en la documentación.

- **Los clientes de Mairena no tienen historial viejo de cobranza.** Se cargaron desde su sistema anterior, no desde cero en la app. Es normal, no es un bug.
- **La app no manda emails.** Es a propósito: todo el alta de usuarios y las contraseñas van por WhatsApp. No falta nada.
- **La integración automática de WhatsApp está "dormida".** Está construida pero apagada. Activarla es una decisión tuya y requiere trámites con Meta. No está rota.
- **La caja pública de GitHub está "abierta a todos".** Es así a propósito: es de donde las apps bajan las actualizaciones. Solo guarda instaladores, no el código.
- **Si la app deja entrar a la gente pero no sincroniza**, no es la app: es la conexión entre el cerebro y el mensajero que se rompió. Tu programador sabe dónde mirar (está en el detalle de la sección 2).

---

## 8. Glosario en criollo

Para que no te vendan humo y entiendas lo que te dicen.

- **App / aplicación** → el programa que usan los cobradores y la oficina.
- **Supabase** → el cerebro en la nube. La base de datos central donde vive todo.
- **Base de datos** → el archivero gigante y ordenado donde se guardan clientes, pagos, recibos, etc.
- **PowerSync** → el mensajero offline. Lo que sincroniza el celular con el cerebro cuando vuelve la señal.
- **GitHub** → las dos cajas fuertes: una privada (el plano + la docu), una pública (de donde bajan las actualizaciones).
- **Repo (repositorio)** → una carpeta en GitHub con el código y su historial de cambios.
- **Keystore / firma digital** → el archivo único que firma las actualizaciones de Android. La firma notariada, irreemplazable. Sin ella no hay actualizaciones.
- **White-label / multi-empresa (multi-tenant)** → una misma app sirve a varias empresas, con datos totalmente separados. Un edificio con un piso cerrado por empresa.
- **Tenant** → cada empresa cliente (Mairena es un tenant, Telenet es otro). Cada tenant es un "piso" aislado.
- **Offline-first** → diseñado para trabajar sin internet y sincronizar después.
- **Onboarding / alta** → el proceso de dar de alta a un usuario nuevo (acá, sin email: la clave va por WhatsApp).
- **Flutter** → el lenguaje con que está construida la app. Útil saberlo al contratar un dev.
- **Build / release / publicar** → el acto de compilar la app y lanzar una versión nueva que los celulares bajan solos.
- **Auto-update** → el mecanismo por el que las apps en la calle se actualizan solas.
- **Bug** → un error en la app. **Feature** → una funcionalidad.
- **Invariantes de dinero** → las reglas sagradas de plata de la sección 4, y el chequeo automático que verifica que la caja cuadra.

---

## 9. Primeros pasos (qué hacer el primer mes)

**Semana 1 — Asegurá lo irreemplazable.**
- [ ] Recibí del dueño actual el **backup cifrado** con los tres secretos y su contraseña (por canales separados).
- [ ] Copiá la **firma digital (keystore)** a un pendrive y a una caja fuerte digital. Fuera de la PC.
- [ ] Conseguí un programador (aunque sea de guardia) y pasale el **documento técnico de traspaso**.

**Semana 2 — Hacete dueño de las cuentas.**
- [ ] Que te **transfieran** (no recreen) las cuentas de Supabase, PowerSync y los dos repos de GitHub. Transferir conserva todo intacto; recrear de cero rompe las conexiones y obligaría a reinstalar la app en los ~5.800 celulares que ya la tienen. **Transferir = poco riesgo. Recrear = mucho riesgo.**
- [ ] Pasá el **método de pago** de los servicios a tu nombre.
- [ ] Confirmá que la caja fuerte de actualizaciones (GitHub público) **siga siendo pública** — si queda privada, las apps dejan de actualizarse en silencio.

**Semana 3 — Que tu programador valide.**
- [ ] Que arme su PC, baje el código y logre **compilar y correr** la app.
- [ ] Que corra el **chequeo de invariantes de dinero** y confirme que da cero con los clientes reales.
- [ ] Que haga **una publicación de prueba** y confirme que un celular recibe la actualización.

> **Sobre el orden del traspaso:** hay una lógica que no es negociable. Primero se aseguran los respaldos, después se transfiere la propiedad de las cuentas conservando todo conectado, y **recién al final** se toca el "interruptor" de las actualizaciones (el dueño de la caja pública). Si se hace al revés, las apps que andan en la calle pueden quedar colgadas para siempre. Tu programador sabe ejecutar esto siguiendo la lista de chequeo del documento técnico; vos solo tenés que saber que **el orden importa.**

**Semana 4 — Conocimiento y continuidad.**
- [ ] Que tu programador lea los documentos del proyecto, **empezando por la bitácora (el "dónde quedamos") y las reglas de dinero.**
- [ ] Anotá vos, en un lugar seguro, **dónde está cada cuenta, cada secreto y cada contraseña.** Ese mapa es tuyo, no del programador.

---

## Última palabra, de mí para vos

Lo que más fácil se subestima en este traspaso **no son las cuentas ni los costos mensuales.** Son **dos cosas**: cuidar la firma digital (que no se puede recuperar) y respetar las reglas de dinero (porque atrás de cada número hay caja real de dos empresas que confían en vos).

Si cuidás esas dos cosas, pagás los servicios a tiempo y trabajás con un buen programador, este negocio te va a dar de comer y va a crecer. Está bien hecho, está andando, y tiene clientes que ya lo eligieron.

Te lo entrego con orgullo. Cuidalo.

— El fundador