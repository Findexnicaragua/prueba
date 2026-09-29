-- 0253_sync_rechazos_dedupe.sql
--
-- `_subirRechazo` (connector.dart) hace un INSERT pelado, sin `on conflict`, y
-- la tabla no tiene indice unico. Si el batch se reintenta -por ejemplo una op
-- descartada y otra retryable en el MISMO batch- el mismo aviso entra N veces:
-- el admin ve el mismo cobro repetido y no sabe si son N cobros distintos o
-- uno solo avisado N veces. Con plata de por medio, esa duda es cara.
--
-- PARCIAL SOBRE `resuelto = false` A PROPOSITO: si el mismo rechazo vuelve a
-- ocurrir meses despues, tiene que poder entrar como aviso NUEVO. Lo que se
-- impide es la duplicacion de lo que sigue PENDIENTE, no la reincidencia.
--
-- DEL LADO DART NO HAY QUE TOCAR NADA: el 23505 cae en el `catch (e)` de
-- `_subirRechazo`, que loguea y no propaga. Verificado leyendo el metodo. Ese
-- ES el comportamiento deseado - el rastro local ya quedo, y ese es la copia
-- de ultima instancia.
--
-- PRECONDICION VERIFICADA en el momento de correrla: 0 grupos duplicados entre
-- los pendientes.

CREATE UNIQUE INDEX IF NOT EXISTS sync_rechazos_dedupe_pendiente
  ON public.sync_rechazos (tabla, registro_id, coalesce(codigo, ''))
  WHERE resuelto = false;
