-- ============================================================================
-- 0223: NORMALIZAR LAS CEDULAS COMODIN A NULL (producción, vxxzesbmilfolwjhfxgr)
-- ============================================================================
--
-- QUÉ PASÓ: `clientes.cedula` es opcional, pero cuando el cliente no traía
-- documento la oficina igual escribía ALGO en el campo — casi siempre un '0'.
-- Quedaron 864 clientes con un comodín guardado como si fuera un documento
-- real. Eso ensucia todo lo que cuelga de la columna:
--
--   · EL RECIBO lo imprime: "Cédula: 0" en la cara del cliente.
--   · LA BÚSQUEDA por cédula: tipear "0" traía media cartera (el `LIKE %0%` de
--     `busquedaClienteSql` matchea a los 861).
--   · EL AVISO de "esta cédula ya está en uso" (feature nueva de esta tanda):
--     sin esto, cada alta con cédula vacía daría 861 falsos positivos.
--
-- Guardar NULL es la forma honesta de decir "no tenemos la cédula".
--
-- ----------------------------------------------------------------------------
-- CONSECUENCIA VISIBLE EN EL RECIBO (verificada en el código, no supuesta)
-- ----------------------------------------------------------------------------
-- Hoy el recibo imprime la línea "Cédula: 0" para 787 clientes que YA tienen
-- recibos emitidos (803 de los afectados tienen contrato). Al pasar a NULL esa
-- línea simplemente NO SE IMPRIME: los tres renderers omiten el campo cuando
-- viene null, cada uno con su propio guard —
--
--   · lib/features/recibo/recibo_ticket.dart:286        (ticket en pantalla)
--   · lib/features/recibo/recibo_texto_escpos.dart:622  (ESC/POS, recibo simple)
--   · lib/features/recibo/recibo_texto_escpos.dart:758  (ESC/POS, recibo multi)
--   · lib/features/recibo/recibo_pdf.dart:241 y :501    (PDF simple y multi)
--
-- los cinco con la forma `r['cliente_cedula'] != null ? _fila(...) : null`, y el
-- `_emitirCampos*` descarta las entradas null. El dato lo trae
-- `recibo_screen.dart:90` como `c.cedula AS cliente_cedula`, sin coalesce.
--
-- ⚠️ POR ESO SE ESCRIBE NULL Y **NO** CADENA VACÍA: el guard es `!= null`, así
-- que un '' pasaría el filtro e imprimiría "Cédula:" con el valor en blanco —
-- peor que hoy. NULL es el único valor que hace desaparecer la línea.
-- (El resto del layout no se toca: la línea sigue gobernada por el setting
-- `recibo.mostrar_cedula` / `cliente.cedula`, ver settings_repo.dart:487.)
--
-- ----------------------------------------------------------------------------
-- LO QUE ESTA MIGRACIÓN **NO** HACE — Y POR QUÉ
-- ----------------------------------------------------------------------------
-- NO agrega un UNIQUE ni un CHECK sobre `cedula`. Decisión del dueño: la cédula
-- se AVISA, no se bloquea. Medido en producción: de los grupos de clientes que
-- comparten cédula, 49 son PERSONAS DISTINTAS registradas con el documento de
-- un familiar — práctica normal en Nicaragua. Un UNIQUE rompería 49 altas
-- legítimas. (El aviso informativo lo hace la app, en el form del cliente.)
--
-- Tampoco endurece nada con un CHECK "prohibido guardar '0'": la app INSTALADA
-- hoy todavía puede escribirlo, y un `check_violation` (23514) le tira un error
-- feo en pantalla al usuario con la versión vieja. Misma lección que 0221 (b2).
-- El bloqueo de entrada va del lado del cliente (`_cedulaNormalizada` en
-- `cliente_form_screen.dart`), que ya manda estos valores a null al guardar.
--
-- NO toca las 3 cédulas MAL CARGADAS que hay en producción (un nombre o una
-- dirección tipeados en el campo cédula):
--     [Frente al centro de Salud] · [Juan Ramon Aguilar Gunera] ·
--     [Leonsa del Socorro Salinas Quintero]
-- No son comodines: son datos reales puestos en la columna equivocada, y
-- decidir qué hacer con ellos (mover a `direccion`, corregir a mano, borrar) es
-- una decisión de la oficina, no de una migración. Se dejan a propósito.
--
-- NO escribe `op_log`: `op_log` es el log de intención del CLIENTE (lo escribe
-- Dart dentro de su writeTransaction). Una reparación server-side no genera
-- historial visible en la ficha — igual que 0221. Esta migración es el rastro.
--
-- NO toca plata: no hay una sola cuota, pago, recibo ni cargo en el archivo.
-- Solo se pisa `clientes.cedula`. El assert de más abajo lo demuestra en vez de
-- prometerlo (huella md5 de las otras columnas antes/después).
--
-- ----------------------------------------------------------------------------
-- PREDICADO: ESPEJA A `_cedulaNormalizada()` DEL FORM
-- ----------------------------------------------------------------------------
-- El bloque (a) usa EXACTAMENTE la misma definición de "comodín" que
-- `cliente_form_screen.dart` (`_cedulaNormalizada`, que se apoya en
-- `_cedulaComparable`), para que server y cliente coincidan: lo que la app deja
-- de guardar de ahora en más es lo mismo que acá se limpia del pasado.
--
--   Dart:  foldBusqueda(s).replaceAll(RegExp(r'[\s./\-_]'), '')
--          → null si: queda vacío  |  ^0+$  |  está en {na, nd, sn, sincedula,
--                                                       sinced, ninguna, ninguno}
--   SQL:   regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g')
--
-- (Acá alcanza con `lower()` a secas: `lower()` de POSTGRES sí es unicode —
-- la trampa de la regla #1d es el `lower()` de SQLITE, que es ASCII-only. Y
-- ninguno de los comodines de la lista lleva ñ ni acentos.)
--
-- ----------------------------------------------------------------------------
-- MEDICIONES REALES (SELECTs corridos contra vxxz el 2026-08-08, ANTES de
-- aplicar nada). Cada bloque cita las suyas.
-- ----------------------------------------------------------------------------
--   SELECT '[' || cedula || ']', count(*) FROM clientes
--    WHERE cedula IS NOT NULL
--      AND regexp_replace(lower(btrim(cedula)),'[[:space:]./_-]','','g')
--          IN ('','na','nd','sn','sincedula','sinced','ninguna','ninguno','notiene')
--       OR regexp_replace(lower(btrim(cedula)),'[[:space:]./_-]','','g') ~ '^0+$'
--    GROUP BY 1;
--
--     [0]         861      -> bloque (a), 'todos ceros'
--     [00]          1      -> bloque (a), 'todos ceros'
--     [No Tiene]    1      -> bloque (b), EXTRA (ver la advertencia del bloque)
--     [NO TIENE]    1      -> bloque (b), EXTRA
--     ------------------
--     TOTAL       864
--
--   Ningún otro comodín de la lista existe en la base: '000', 'N/A', 'NA', '-',
--   '' (cadena vacía), 'S/N', 'X', 'NINGUNA'... todos dan 0 filas. No se listan
--   en el predicado por adivinanza: el predicado los cubre igual si aparecen
--   mañana, pero lo que HOY se toca son esas 864 filas y nada más.
--
--   Universo y reparto:
--     clientes en la base ................ 6096
--     afectados .......................... 864   (862 Telecable Mairena + 2 Telenet)
--     de ellos, con contrato ............. 803
--     de ellos, con recibo emitido ....... 787   <- los que hoy ven "Cédula: 0"
--     ya tenían cedula NULL ................. 3
--     cédulas con al menos un dígito ..... 6088  -> quedan 5226 (bajan los 862
--                                                  comodines numéricos, ni una más)
--     -> después de correr esto: 867 clientes con cedula NULL (14,2% de 6096)
--
-- ----------------------------------------------------------------------------
-- ES RE-EJECUTABLE: los UPDATE están acotados por el predicado del daño (no por
-- listas de IDs), así que una segunda corrida toca 0 filas. Las temp tables son
-- ON COMMIT DROP.
--
-- EFECTO EN POWERSYNC (esperado, benigno): son 864 UPDATEs, o sea 864 filas de
-- `clientes` que se replican de nuevo a todos los dispositivos del tenant. Es
-- una corrida única y `clientes` es una tabla angosta — pero conviene correrlo
-- en horario de baja actividad y no repetirlo por gusto (el self-host de
-- Hetzner paga el ancho de banda del re-sync).
--
-- TRIGGERS DE `clientes` (los 2 vivos, verificados en producción — ninguno
-- dispara con este UPDATE):
--   · trg_clientes_codigo_inmutable      BEFORE UPDATE, pero solo lanza si
--     `NEW.codigo IS DISTINCT FROM OLD.codigo`. Acá `codigo` no se toca.
--   · trg_propagate_cobrador_id_clientes AFTER UPDATE **OF cobrador_id**. Acá
--     `cobrador_id` no se toca -> no se ejecuta.
-- Y `cedula` no aparece en ningún índice ni en ninguna CHECK constraint de la
-- tabla (verificado con pg_indexes y pg_constraint: 0 filas en ambos).
-- ============================================================================

-- Lección 0218 -> 0219 (y 0221): forzar el encoding de la sesión y NO meter
-- acentos ni flechas en literales SQL que se devuelven o se guardan. Los
-- acentos quedan SOLO en comentarios, que no viajan a ningún lado.
SET client_encoding = 'UTF8';

BEGIN;

-- ── Snapshot: la red de seguridad ───────────────────────────────────────────
-- `huella` es un md5 de TODAS las columnas de `clientes` que NO son la cédula.
-- Si al cerrar la transacción la huella cambió, es que se tocó algo que no se
-- debía y el assert revierte todo. Es la prueba de que la migración solo pisa
-- una columna.
CREATE TEMP TABLE _0223_snapshot ON COMMIT DROP AS
SELECT count(*)                                              AS clientes,
       count(*) FILTER (WHERE c.cedula IS NULL)              AS cedula_null,
       md5(string_agg(
             c.id::text                         || '|' ||
             coalesce(c.nombre, '')             || '|' ||
             coalesce(c.codigo, '')             || '|' ||
             coalesce(c.telefono, '')           || '|' ||
             coalesce(c.direccion, '')          || '|' ||
             coalesce(c.email, '')              || '|' ||
             coalesce(c.cobrador_id::text, '')  || '|' ||
             coalesce(c.tenant_id::text, '')    || '|' ||
             coalesce(c.activo::text, '')       || '|' ||
             coalesce(c.vencimiento_mas_viejo::text, ''),
             E'\n' ORDER BY c.id))                           AS huella,
       (SELECT count(*) FROM public.pagos WHERE anulado = false) AS pagos_vivos
  FROM public.clientes c;


-- ============================================================================
-- (a) COMODINES: ceros, vacíos y placeholders de texto  ->  NULL
-- ============================================================================
-- Medido el 2026-08-08: 862 filas (861 con '0' + 1 con '00'). Los demás valores
-- de la lista no existen hoy en la base; van igual porque el predicado tiene que
-- describir la REGLA (la misma que aplica la app al guardar), no la foto de hoy.
--
-- Cubre, sobre la forma comparable (minúsculas, sin espacios ni . / _ -):
--   · cadena que queda vacía  ->  '', '   ', '-', '- -', '...'
--   · solo ceros              ->  '0', '00', '000', '0-0'
--   · placeholders de texto   ->  'na', 'n/a', 'N.A.', 'nd', 'sn', 's/n',
--                                 'sin cedula', 'sinced', 'ninguna', 'ninguno'
UPDATE public.clientes
   SET cedula = NULL
 WHERE cedula IS NOT NULL
   AND (
     regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = ''
     OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') ~ '^0+$'
     OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g')
        IN ('na', 'nd', 'sn', 'sincedula', 'sinced', 'ninguna', 'ninguno')
   );


-- ============================================================================
-- (b) EXTRA: "No Tiene" / "NO TIENE"  ->  NULL     [2 filas, se puede comentar]
-- ============================================================================
-- ⚠️ ESTE BLOQUE VA MÁS ALLÁ DE LA LISTA APROBADA — leer antes de correr.
--
-- Al medir la base aparecieron 2 clientes con la cédula literal "No Tiene" /
-- "NO TIENE". Es el mismo comodín de siempre escrito con palabras, y hoy se
-- imprime en el recibo como "Cédula: No Tiene", que es exactamente el problema
-- que esta migración viene a resolver. Por eso se limpia.
--
-- PERO ES UNA DIVERGENCIA DECLARADA CON EL CLIENTE: `_cedulaNormalizada` del
-- form compacta "No Tiene" a 'notiene', que NO está en su set de comodines, así
-- que la app de HOY dejaría volver a guardarlo. Son 2 filas y no se puede
-- reincidir en masa, pero para cerrarlo del todo hay que agregar 'notiene' al
-- `const comodines` de `cliente_form_screen.dart:249`.
--
-- SI NO SE QUIERE ESTA LIMPIEZA: comentar el UPDATE de abajo. El resto del
-- archivo es independiente y corre igual (la verificación final lo reporta por
-- separado, no lo assertea).
UPDATE public.clientes
   SET cedula = NULL
 WHERE cedula IS NOT NULL
   AND regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = 'notiene';


-- ============================================================================
-- ASSERT — si se tocó cualquier cosa que no sea `cedula`, esto revierte TODO
-- ============================================================================
-- No debería poder pasar (ningún trigger de `clientes` dispara con este UPDATE,
-- ver la cabecera), pero lo verificamos en vez de asumirlo: la app tiene
-- triggers que recalculan solos y un UPDATE mal escrito podría despertarlos.
DO $$
DECLARE
  a record;
  d record;
BEGIN
  SELECT * INTO a FROM _0223_snapshot;

  SELECT count(*)                                              AS clientes,
         count(*) FILTER (WHERE c.cedula IS NULL)              AS cedula_null,
         md5(string_agg(
               c.id::text                         || '|' ||
               coalesce(c.nombre, '')             || '|' ||
               coalesce(c.codigo, '')             || '|' ||
               coalesce(c.telefono, '')           || '|' ||
               coalesce(c.direccion, '')          || '|' ||
               coalesce(c.email, '')              || '|' ||
               coalesce(c.cobrador_id::text, '')  || '|' ||
               coalesce(c.tenant_id::text, '')    || '|' ||
               coalesce(c.activo::text, '')       || '|' ||
               coalesce(c.vencimiento_mas_viejo::text, ''),
               E'\n' ORDER BY c.id))                           AS huella,
         (SELECT count(*) FROM public.pagos WHERE anulado = false) AS pagos_vivos
    INTO d
    FROM public.clientes c;

  -- Mensajes de RAISE en ASCII puro a proposito: la salida de psql/CLI ya
  -- rompio acentos antes en este repo (ver 0219_fix_mojibake_*).
  IF d.clientes <> a.clientes THEN
    RAISE EXCEPTION
      '0223 ABORTADA: cambio la cantidad de clientes (% -> %). Un UPDATE no borra filas: revisar.',
      a.clientes, d.clientes;
  END IF;

  IF d.huella <> a.huella THEN
    RAISE EXCEPTION
      '0223 ABORTADA: cambio alguna columna de clientes que NO es cedula (huella md5 distinta).';
  END IF;

  IF d.pagos_vivos <> a.pagos_vivos THEN
    RAISE EXCEPTION
      '0223 ABORTADA: cambio la cantidad de pagos vivos (% -> %). Esta migracion no toca plata.',
      a.pagos_vivos, d.pagos_vivos;
  END IF;

  RAISE NOTICE '0223 OK: % cedulas comodin pasadas a NULL (cedula_null % -> %). Resto de clientes intacto (huella md5 igual), % pagos vivos sin tocar.',
    d.cedula_null - a.cedula_null, a.cedula_null, d.cedula_null, d.pagos_vivos;
END;
$$;

COMMIT;


-- ============================================================================
-- VERIFICACIÓN "DESPUÉS" — correr esto y leer la columna `resultado`
-- ============================================================================
-- Las filas cuyo `esperado` es 0 son ASERCIONES DURAS: si no dan 0, algo falló.
-- Las demás son de REFERENCIA (los totales se mueven solos con las altas
-- normales de clientes).
SELECT 'a) cedulas comodin que quedan (ceros/vacios/placeholders)' AS chequeo,
       (SELECT count(*) FROM public.clientes
         WHERE cedula IS NOT NULL
           AND (regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = ''
             OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') ~ '^0+$'
             OR regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g')
                IN ('na','nd','sn','sincedula','sinced','ninguna','ninguno')))::text AS resultado,
       '0 (antes 2026-08-08: 862 = 861 con [0] + 1 con [00])' AS esperado

UNION ALL
SELECT 'b) cedulas literales "no tiene" que quedan',
       (SELECT count(*) FROM public.clientes
         WHERE cedula IS NOT NULL
           AND regexp_replace(lower(btrim(cedula)), '[[:space:]./_-]', '', 'g') = 'notiene')::text,
       '0 si corriste el bloque (b) / 2 si lo comentaste a proposito'

UNION ALL
SELECT 'total de clientes con cedula NULL',
       (SELECT count(*) FROM public.clientes WHERE cedula IS NULL)::text,
       '867 (antes eran 3: tiene que SUBIR en 864)'

UNION ALL
SELECT 'total de clientes (no se borro ninguno)',
       (SELECT count(*) FROM public.clientes)::text,
       '6096 (ref. 2026-08-08; sube solo con altas nuevas)'

UNION ALL
-- Prueba de que NO se convirtio nada en cadena vacia: un '' pasaria el guard
-- `!= null` de los renderers e imprimiria "Cedula:" en blanco en el recibo.
SELECT 'cedulas guardadas como cadena vacia o solo espacios',
       (SELECT count(*) FROM public.clientes WHERE cedula IS NOT NULL AND btrim(cedula) = '')::text,
       '0'

UNION ALL
-- Control de que la limpieza no se llevo puesta ninguna cedula real. Los unicos
-- comodines CON digitos son los 862 del bloque (a) ([0] y [00]), asi que la
-- cuenta tiene que bajar EXACTAMENTE en 862: 6088 medidos antes - 862 = 5226.
-- Si baja mas, el predicado se comio documentos validos.
SELECT 'clientes con cedula real (con al menos un digito)',
       (SELECT count(*) FROM public.clientes WHERE cedula ~ '[0-9]')::text,
       '5226 (antes 2026-08-08: 6088; tiene que bajar exactamente 862)'

UNION ALL
-- Las 3 mal cargadas (nombre/direccion en el campo cedula) NO se tocan: quedan
-- para que la oficina las corrija a mano. Antes de correr esto daban 5, porque
-- los 2 "No Tiene" tampoco tienen digitos; el bloque (b) los saca.
SELECT 'cedulas mal cargadas sin ningun digito (se dejan a proposito)',
       (SELECT count(*) FROM public.clientes
         WHERE cedula IS NOT NULL AND cedula !~ '[0-9]')::text,
       '3 con el bloque (b) / 5 si lo comentaste. Antes: 5. Los 3 que quedan son '
       || 'Frente al centro de Salud, Juan Ramon Aguilar Gunera, Leonsa del Socorro Salinas Quintero';
