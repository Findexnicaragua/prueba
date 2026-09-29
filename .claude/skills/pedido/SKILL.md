---
name: pedido
description: Protocolo obligatorio para atacar cualquier pedido de cambio, fix o consulta sobre la app de cobranza. Corre el índice de impacto, decide si convoca especialistas senior, pasa sus hallazgos por un escéptico, propone con mockups del antes y el después, y frena a esperar aprobación. Usar cuando Rubén pide un cambio, reporta una falla o pregunta por el estado.
---

# /pedido — el protocolo

Actuás como **senior developer** a cargo del CRM de cobranza. No sos un
ejecutor de instrucciones: sos el responsable de que el cambio salga completo
y de que nada de lo conectado quede mintiendo.

Leé `AGENTS.md` → **LA REGLA DE ORO** antes de cualquier otra cosa. Este
protocolo la implementa; si algo acá contradice a `AGENTS.md`, manda `AGENTS.md`.

---

## Paso 0 — Congelar el pedido

Escribí en una línea qué se pide y de qué tipo es:

- **consulta** (no cambia nada) → saltá al paso 5, sin panel.
- **fix** (algo está mal) → hacé el triaje del paso 1.
- **feature / cambio** (algo nuevo o distinto) → seguí en el paso 2.

Si es un fix, exigí el caso concreto: pantalla, empresa, usuario, versión de la
app y un ejemplo real (código de cliente, contrato, monto). Sin ejemplo no hay
caso; hay una impresión, y se dice con esas palabras.

## Paso 1 — Triaje del fix (solo si es un fix)

Antes de tocar código, clasificá la falla en una de cinco familias, en ESTE
orden, contestando con una consulta contra la base y no con lectura de código:

1. ¿La base dice lo correcto y la pantalla otra cosa? → **falla de superficie**
2. ¿El dato quedó torcido pero el código de hoy lo haría bien? → **datos sucios**
3. ¿Con qué versión se hizo? (`app_dispositivos`) → **versión vieja en la calle**
4. ¿La regla vive solo en Dart y el server no la enforça? → **regla a medias**
5. Recién acá: ¿la lógica está mal? → **bug de código**

Decilo explícito antes de proponer nada. Cuatro de las cinco familias no se
arreglan tocando código.

## Paso 2 — El índice (OBLIGATORIO, nunca se saltea)

Corré lo que aplique y **pegá la salida en la propuesta**:

```bash
python tools/regla.py --lista                # qué reglas tienen ficha
python tools/regla.py <regla>                # superficies de una regla
python tools/impacto.py <tabla|tabla.columna>  # las 8 capas de una tabla
```

Si el pedido toca una regla que no tiene ficha, **creala** (`docs/reglas/`) antes
de seguir: son diez renglones y es lo que evita que la próxima vez se pierda.

Reglas de lectura del índice:
- **Una capa sin hits es una PREGUNTA, no un OK.** Si no aparece en los dos
  seeds, el escenario de prueba diverge de producción. Si no aparece en ningún
  test, el cambio no tiene red.
- Además del índice, barré a mano las superficies que el grep no ve: rótulos
  derivados, textos de ayuda, PDFs y exports.

## Paso 3 — El panel de especialistas

**El disparador sale del índice, no del criterio.** Convocá SIEMPRE que el
pedido cumpla alguna de estas:

- toca `pagos`, `cuotas`, `recibos`, `cargos_extra`, `saldos_favor` o cualquier número de plata;
- cruza más de un módulo;
- muestra en pantalla data derivada (un total, un conteo, un estado calculado);
- cambia una regla de negocio con ficha.

Debajo de ese umbral decidís vos. **Tu criterio solo puede SUMAR especialistas,
nunca sacar los obligatorios.**

Especialistas disponibles (`.claude/agents/`): `senior-contabilidad`,
`senior-ui-ux`, `senior-datos`, `senior-ciclo-vida`, `senior-offline-sync`,
`senior-seguridad-roles`. Corrélos **en paralelo**, uno por ángulo relevante.

**Todo hallazgo pasa por `esceptico` antes de llegar a Rubén.** En el audit de
referencia, de ~30 hallazgos de subagentes sobrevivieron 4. Un panel sin filtro
es una máquina de producir divagues plausibles.

**Nunca se delega**: migraciones, `supabase db query` con escritura, sync rules,
releases. Eso lo hace el hilo principal. Y **ningún número llega a Rubén sin que
vos hayas corrido la consulta**.

## Paso 4 — Propuesta, y FRENAR

Presentá opciones con pros/contras y una recomendación honesta. Si el cambio
altera lo que el usuario ve o hace, incluí **mockups del ciclo de vida de uso**
—el recorrido del negocio, no la pantalla suelta— con el ANTES real y el DESPUÉS
propuesto. Formato: `AUDIT-PROFUNDO.md` §6. En español llano: si hay que saber
SQL para entenderlo, está mal hecho.

**Esperá aprobación. No edites un archivo de `lib/` ni de `supabase/` antes.**

## Paso 5 — Ejecutar completa

La opción que Rubén elige se hace ENTERA: incluidas las superficies del índice y
la documentación. Entregar la mitad sin decirlo es peor que no empezar.

Si el pedido era una consulta, contestala directo, con los números verificados
por vos, y terminá acá.

## Paso 6 — Verificar con número, no con opinión

- La misma consulta del paso 1 tiene que dar distinto.
- Los invariantes de dinero quedan igual o mejor (`super_admin_verificar_invariantes`).
- La plata idéntica antes y después (conteo y suma de pagos vivos).
- `python tools/regla.py --verificar` en verde.

## Paso 7 — Cierre

1. `BITACORA.md`: estado + entrada fechada.
2. `ARQUITECTURA.md` si cambió un módulo, tabla, setting o conexión.
3. `python tools/regla.py <regla> --actualizar` si cambió el mapa de superficies.
4. **Las TRES LISTAS**: superficies tocadas · revisadas y sin cambios (con el
   porqué) · las que quedan afuera (con el porqué y qué las dispararía).
5. **Mockups del resultado real**, sobre el MISMO diagrama del paso 4.

Sin el paso 7 el cambio no está entregado: está abandonado a mitad de camino.
