# AUDIT-PROFUNDO.md

> **Cómo se invoca:** cuando Rubén pide un **"audit profundo"** (o "auditoría
> profunda", "audito profundo"), se ejecuta ESTE documento completo. No es el
> audit de rutina de la Fase 4 de `AGENTS.md` —ese es el piso—: esto es el
> techo, y se corre sobre cambios grandes, antes de un release, o cuando algo
> huele mal y no se sabe dónde.
>
> **Regla que ordena todo lo demás:** un audit que no encuentra nada no es un
> audit bueno, es un audit que no buscó. Si al terminar no hay findings, hay que
> explicar QUÉ se intentó romper y por qué aguantó — no basta con decir "limpio".

---

## 0. Cómo se corre

Se simulan **cuatro especialistas senior** revisando el mismo cambio desde
ángulos distintos. Cada uno tiene su mandato, sus preguntas y su forma de
fallar. Se recorren los cuatro **en orden**, porque cada uno usa lo que
encontró el anterior.

No se confía en la memoria ni en lo que dicen los comentarios del código: **todo
hallazgo se verifica contra la base real o ejecutando algo.** Un audit que
concluye leyendo es una opinión.

**Prohibido:**
- Dar por bueno un invariante porque un comentario dice que se cumple.
- Auditar solo el diff. El diff no muestra al que llama, y ahí vive la mitad de
  los bugs.
- Reportar como finding algo que ya figura resuelto o aceptado en `BITACORA.md`.
- Confundir "el analizador no se queja" con "está bien". Las tres peores fallas
  de este proyecto pasaron el analizador y los tests.

---

## 1. Especialista en ciclo de vida de la app

**Mandato:** verificar que la app siga contando una historia coherente de punta
a punta, no que cada pieza funcione aislada.

Recorre el ciclo completo del negocio —cliente entra, contrata, se le instala,
se le cobra, se le repara, se le corta, se va— y pregunta en cada salto:

- **¿Hay callejones sin salida?** Un estado al que se entra y no se puede
  salir. Un registro que queda esperando a alguien que no tiene cómo verlo.
- **¿Hay datos que se capturan y nadie lee?** Buscar cada columna nueva desde
  donde se escribe hasta donde se muestra. Si no llega a ninguna pantalla ni a
  ningún reporte, el feature está a medio construir aunque el código esté bien.
  *(Así se encontraron `tickets.lat/lng` y `cerrado_sin_confirmar`.)*
- **¿Quién queda bloqueado esperando a quién?** Todo paso que depende de otra
  persona necesita una válvula. Si A no puede avanzar hasta que B haga algo, y B
  puede no hacerlo nunca, eso es una trampa.
- **¿El offline-first se sostiene?** Toda acción de campo tiene que poder
  ejecutarse sin señal y reconciliar después. Si algo exige conexión sincrónica,
  tiene que estar declarado.
- **¿Se respeta "server gana"?** Ningún estado de negocio lo decide el cliente.
  El cliente declara intención; Postgres decide.

**Cómo falla este especialista:** aprobando un flujo porque cada pantalla anda,
sin haber recorrido nunca el camino completo con un caso concreto.

---

## 2. Especialista en lógica de programación

**Mandato:** romper el código con entradas que nadie probó.

- **Los tres valores olvidados: `null`, cero y vacío.** Para cada rama nueva:
  ¿qué pasa si esto viene null? ¿si la lista está vacía? ¿si el número es 0?
  En plpgsql, ojo especial: **`IF NOT NULL` no se cumple**, así que un guard
  escrito como `IF NOT es_algo()` se saltea entero cuando la función devuelve
  null. *(Bug real: el trigger del coordinador bloqueaba a todos.)*
- **Concurrencia y doble ejecución.** ¿Qué pasa si esto corre dos veces? ¿Si dos
  dispositivos lo hacen a la vez? ¿Si el usuario toca dos veces el botón? Toda
  escritura offline tiene que ser idempotente o tener guard de re-validación
  dentro de la transacción.
- **FRECUENCIA, no solo corrección.** *(Regla nacida del bug más caro del
  proyecto: 35-62 GB/día de egress con 2,7 MB guardados en total.)* Para toda
  llamada que cueste algo — red, disco, escritura de prefs, escaneo de tabla —
  la pregunta no es solo "¿hace lo correcto?" sino **"¿quién la dispara y
  cuántas veces por minuto?"**. Un `download()` correcto, offline-first y bien
  manejado sigue siendo una catástrofe si corre 25 veces por minuto.
  - **Estado ≠ evento.** `if (status.connected)` NO es "se conectó": es "está
    conectado", y se re-evalúa en cada emisión del stream. Lo mismo vale para
    `watch`, `connectivity` y cualquier stream de ESTADO. Si el código quería
    la transición y leyó el nivel, corre para siempre.
  - **El guard va en la función llamada, no en la disciplina del caller.** Una
    función que "refresca" y confía en que la llamen en momentos sensatos es
    una bomba con temporizador: alguien la va a colgar de un latido. La versión
    correcta se pregunta ella misma si hace falta hacer el trabajo.
  - **La versión tiene que ser PERSISTIDA, no de memoria.** Un flag en RAM se
    olvida en cada arranque → una descarga por sesión, para siempre. Guardá al
    lado del archivo qué versión es, y comparala contra el dato que ya
    sincroniza PowerSync. Si el dato no cambió, no hay nada que bajar.
  - **Ojo con el `updated_at` cuando el path es fijo.** Si el archivo siempre
    vive en la misma ruta (`{tenant}/logo.png`), el path no distingue el nuevo
    del viejo: versioná por `updated_at` de la fila que lo referencia.
  - **Grep de regresión:** `statusStream.listen`, `connectivity`, `.watch(` →
    por cada callback, listar TODO lo que hace y descartar red/disco no
    guardado. Y `.storage` fuera de un servicio de cache → ninguna pantalla
    habla con Storage directo.
- **Aritmética y redondeo.** Cualquier número que llegue a la pantalla o a la
  base: ¿puede dar negativo? ¿puede dividir por cero? ¿acumula error?
- **Orden de ejecución.** Si hay varios triggers sobre la misma tabla, ¿en qué
  orden disparan? ¿alguno pisa lo que hizo el otro? En Postgres los BEFORE
  disparan en orden **alfabético por nombre** — depender de eso sin saberlo es
  una bomba.
- **Fallos a mitad de camino.** Si esto revienta después del primer paso, ¿qué
  queda a medias? ¿Hay `try/catch/finally` con limpieza garantizada?
- **Compatibilidad SQLite vs Postgres.** El cliente corre SQLite: nada de
  `FILTER (WHERE)`, casts `::`, `RETURNING`, `ILIKE`, `ANY(`, `ARRAY[`. Y el
  día local es Nicaragua UTC-6: `date('now','-6 hours')`, nunca `date('now')`.

**Cómo falla este especialista:** probando el camino feliz y declarándolo
correcto.

---

## 3. Especialista en datos y uniones entre tablas

**Mandato:** encontrar dónde los datos se contradicen entre sí.

- **Seguir cada FK en las dos direcciones.** ¿Qué pasa al borrar el padre?
  ¿`CASCADE`, `SET NULL`, `RESTRICT`? ¿Es lo que el negocio quiere?
- **Denormalización desincronizada.** Este proyecto denormaliza `cobrador_id` y
  `tenant_id` en varias tablas. Los triggers no corren en SQLite, así que
  **todo INSERT desde Dart tiene que setear las columnas denormalizadas a mano.**
- **Doble contabilidad.** Cuando un dato se deriva de un ledger (el stock por
  ubicación es `Σdestino − Σorigen`), verificar que ninguna operación nueva
  sume o reste dos veces, y que toda salida tenga su entrada correspondiente.
  *(Así se evitó que "en revisión" inflara una bodega para siempre.)*
- **Invariantes de dinero.** Si el cambio toca `pagos`, `cuotas`, `recibos`,
  `contratos` o `cargos_extra`: correr `supabase/tests/invariantes_dinero.sql` y
  exigir `violaciones = 0`. Sin excepción.
- **Consistencia cross-pantalla.** El mismo número tiene que dar idéntico en
  todas las pantallas. Si dos difieren, una está mal — investigar antes de
  seguir, nunca "ajustar" la que se ve peor.
- **Columnas `NOT NULL` nuevas.** El SQLite local no tiene DEFAULTs y el
  conector sube la fila entera: una columna `NOT NULL` que el cliente no setee
  viaja como null, la rechaza Postgres y **traba la cola de subida del
  dispositivo entero** — no solo esa fila.
- **Verificación por CONTENIDO, no por existencia.** Después de una migración,
  no alcanza con que el objeto exista: hay que comprobar que tiene los valores
  nuevos. *(Un CHECK existía sin el valor agregado y la verificación lo dio por
  bueno.)*
- **Columnas `GENERATED ALWAYS`: NO se replican.** La replicación lógica de
  Postgres no publica columnas generadas (la opción `publish_generated_columns`
  recién existe en PG18; acá corre PG17). Una columna generada llega **NULL a
  todos los dispositivos, siempre** — y como el cliente la lee con un `?? 0`
  de fallback, no falla: miente en silencio. Si el valor tiene que llegar al
  dispositivo, va **columna normal + trigger**, nunca generada. Se verifica con
  `pg_publication_tables.attnames`. *(Bug real en producción: el PIN del
  Resumen se pedía configurar en loop para siempre.)*
- **Funciones `CREATE OR REPLACE`.** Partir SIEMPRE de la definición **viva** en
  la base (`pg_get_functiondef`), nunca de la migración que la creó ni de la
  memoria. Reescribir desde un cuerpo viejo pierde en silencio lo que se le
  agregó en el medio, y nada avisa.

- **Descargas en un listener de eventos.** Todo lo que cuelgue de un stream que
  emite seguido (estado de sync, conectividad, foco) tiene que preguntarse ANTES
  si hace falta. Un `download()` sin guard ahí no se nota en desarrollo y en
  producción son cientos de GB. Señal de alarma barata: **egress alto con
  storage chico** — significa que se baja lo mismo miles de veces. *(Bug real:
  253 GB/mes bajando un logo de 200 KB en cada evento de sync.)*

**Cómo falla este especialista:** auditando el esquema y no los datos reales.

---

## 4. Especialista en UI y UX

**Mandato:** encontrar dónde la app le miente al usuario.

- **La pregunta que más findings da: ¿puede el usuario EMPEZAR algo que va a
  fallar?** Para cada botón nuevo, cruzar tres cosas: qué rol lo ve, qué dice su
  RLS, y qué baja su bucket de sincronización. **En una app offline-first, un
  botón sin permiso escribe local, se ve como que funcionó, y falla al
  sincronizar — cuando el usuario ya se fue de la casa del cliente.**
  *(Este patrón apareció tres veces seguidas en el mismo paquete.)*
- **Estados vacíos y de error.** ¿Qué se ve cuando no hay datos? ¿Cuando falla?
  Un mensaje tiene que decir **qué falta o qué hacer**, no solo que no se puede.
  "Faltan 2 intentos" sirve; "no disponible" no.
- **Vocabulario.** Ningún valor interno puede llegar a la pantalla. Si un
  `switch` de etiquetas tiene un `_ => valor` de fallback, cada valor nuevo del
  dominio necesita su caso. *(Así se coló "contacto" crudo en la bitácora.)*
- **Layout en runtime.** Un `Row` con `CrossAxisAlignment.stretch` dentro de un
  scroll reclama altura infinita y **empuja al vacío todo lo que va después**.
  No lo cazan el analizador ni los tests: solo el render.
- **Diálogos y carga.** Nunca `showDialog` como indicador de carga: si la
  operación falla, la barrera queda pegada y la pantalla muere. Flag de estado +
  overlay, limpiado en `finally`.
- **Selección de lista de DB dentro de un diálogo.** Los `DropdownButton`
  alimentados por la base NO commitean adentro de un diálogo. Va
  `SelectorBuscable`. Los enum fijos y cortos sí pueden ser dropdown.
- **Navegación.** Las rutas del shell admin se navegan con `go`, nunca con
  `push`: con `push` el shell no se reconstruye y el botón de volver apunta al
  padre equivocado, o directamente no aparece.
- **Búsqueda con ñ y acentos.** `lower()` de SQLite es ASCII-only. Toda
  comparación case-insensitive sobre texto en español va con `foldBusqueda` /
  `foldSqlExpr`. Es un falso negativo silencioso: no falla, simplemente no
  encuentra.

**Cómo falla este especialista:** revisando el código de la UI en vez de
imaginar a una persona real usándola con guantes, con sol en la pantalla y sin
señal.

---

## 5. Formato del reporte

```
## REPORTE DE AUDIT PROFUNDO — [qué se auditó]

### Alcance y método
Qué se revisó, qué se ejecutó para verificarlo, y qué NO se cubrió.

### Findings
| # | Severidad | Especialista | Archivo:línea | Problema | Impacto real |

Por cada finding:
  · Cómo se encontró (qué se ejecutó, no "revisando el código")
  · El escenario concreto que lo dispara, con nombres y datos
  · Por qué el código actual falla ahí
  · El fix propuesto

### Lo que se intentó romper y aguantó
Tabla por categoría. Vale tanto como los findings: dice dónde YA se miró.

### Backlog
Lo que no bloquea, con el criterio de por qué no bloquea.

### Lo que este audit NO cubrió
Explícito y sin adornos. Si no se corrió la app, se dice.
```

**Severidades.** *Crítica*: corrompe datos, bloquea a un rol, o rompe algo que
hoy funciona en producción. *Media*: el feature no cumple su propósito, o el
usuario se confunde. *Baja*: cosmético o caso borde poco probable.

---

## 6. Entrega visual (OBLIGATORIA — el audit no está cerrado sin esto)

El reporte de la §5 es el registro técnico. **La entrega a Rubén son mockups**,
porque el texto solo no le deja evaluar si lo encontrado importa. Al terminar
todo audit profundo se entregan **cuatro visuales, en este orden**, resumidos y
claros — no exhaustivos:

| # | Visual | Qué tiene que responder |
|---|---|---|
| 1 | **En qué se basó el audit** | Los cuatro especialistas, la pregunta central de cada uno y su forma típica de fallar. Deja ver qué ángulos se cubrieron y cuáles no. |
| 2 | **Qué se encontró fallando, sobre el ciclo de vida** | El recorrido del negocio con cada hallazgo clavado en el punto EXACTO donde corta el flujo. No una lista: un mapa. |
| 3 | **Qué se hizo y cómo se resolvió** | Antes y después por hallazgo, con la **causa de fondo**, no solo el síntoma. Si la causa fue una regla duplicada o un supuesto equivocado, se dice. |
| 4 | **El resultado sobre el ciclo de vida** | El mismo recorrido del visual 2, ahora sin cortes. Se ve de un vistazo que el lazo cerró. |

**Reglas de estos visuales:**
- **En español llano, sin jerga.** El destinatario decide con esto; si hay que
  saber SQL para entenderlo, está mal hecho.
- **El visual 2 y el 4 usan el MISMO diagrama**, para que la comparación sea
  inmediata. Cambia el color y desaparecen las marcas, no el layout.
- **Severidad por color, siempre con leyenda.**
- Lo que el audit NO cubrió va en el texto que acompaña, no escondido.

---

## 7. Cierre

Al terminar: los findings críticos y medios se arreglan antes de testear. El
backlog se anota en `BITACORA.md` con su criterio. Y si el audit descubrió una
regla nueva —una forma de fallar que no estaba contemplada— **se agrega a este
documento**, para que el próximo audit ya la busque.

Este archivo crece con cada bug que se nos escapó.

> **Historial de reglas nacidas de un bug real:**
> · `IF NOT NULL` no se cumple en plpgsql → el guard se saltea (trigger del coordinador).
> · Un botón sin permiso en una app offline-first falla al sincronizar, no al tocarlo (3 veces en un mismo paquete).
> · Una regla escrita en dos lugares se arregla en uno solo (el botón de alta del estado vacío).
> · Un dato que se guarda y nadie lee es un feature a medio construir (geolocalización, cierres sin confirmar).
> · Una columna GENERATED nunca llega al dispositivo: la replicación lógica no la manda (PIN del Resumen en loop).
> · Un `download()` colgado de un listener frecuente son cientos de GB de egress (el logo, 35-62 GB/DÍA). Código correcto, frecuencia equivocada: ninguna auditoría preguntaba "¿cuántas veces por minuto?".
> · Un guard que vive en memoria se olvida al reiniciar; el que vive al lado del archivo, no (el mismo logo, segunda vuelta).
> · La misma constante escrita en 3 archivos: se arregla uno y se cree resuelto (la geometría de impresión, 3 intentos).
