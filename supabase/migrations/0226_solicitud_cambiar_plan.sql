-- 0226 — nuevo tipo de solicitud: `cambiar_plan`.
--
-- POR QUÉ. Ruben pidió que el admin_cobranza pueda PEDIR el cambio de plan con
-- aprobación del admin. Hoy ni siquiera lo ve (`puedeCambiarPlanProvider` exige
-- rol admin), y no existía el tipo de solicitud para pedirlo.
--
-- Y hay una razón más fuerte, medida: **3 de cada 4 "cancelaciones" de la base
-- son cambios de plan disfrazados**. De 61 contratos cancelados, 53 tienen otro
-- contrato del mismo cliente creado alrededor de la misma fecha, y 45 de esos
-- con plan DISTINTO (upgrades y downgrades reales: CATV→Internet 20MB,
-- Combo 40→Combo 20…). El contrato nuevo se crea ANTES de cancelar el viejo
-- (44 h antes en Mairena, 6 h en Telenet). Cada uno de esos casos pierde el
-- historial: contrato nuevo, cuotas nuevas, numeración nueva. Lo hacen así
-- porque la feature de cambio de plan está apagada y no tienen otra salida.
--
-- SIN RIESGO DE ROLLOUT. Una app VIEJA que reciba una solicitud de este tipo la
-- parsea con el fallback `_parseTipo` → la mostraría como "Crear contrato" y su
-- ejecutor intentaría un INSERT con datos que no le corresponden. Por eso el
-- botón para crear estas solicitudes queda detrás del setting
-- `cobranza.cambio_plan_habilitado`, que está en **false en los 4 tenants**: no
-- puede nacer una sola fila de este tipo hasta que se prenda a propósito, y para
-- entonces `app_dispositivos` (0225) permite verificar que todos actualizaron.
alter table public.solicitudes_accion
  drop constraint if exists solicitudes_accion_tipo_check;

alter table public.solicitudes_accion
  add constraint solicitudes_accion_tipo_check
  check (tipo = any (array[
    'crear_contrato',
    'cancelar_contrato',
    'suspender_contrato',
    'reactivar_contrato',
    'desactivar_cliente',
    'cambiar_plan'
  ]));

comment on constraint solicitudes_accion_tipo_check on public.solicitudes_accion is
  'Tipos de solicitud validos. Al agregar uno: (1) ampliar este CHECK, (2) el enum '
  'TipoSolicitud + tipoDb + _parseTipo + tipoLabel en solicitud_accion.dart, '
  '(3) el ejecutor en solicitudes_repo.ejecutarAccionAprobada, (4) la tarjeta en '
  'solicitudes_screen. OJO con el rollout: las apps viejas caen al fallback de '
  '_parseTipo y muestran el tipo desconocido como crear_contrato, asi que el tipo '
  'nuevo tiene que nacer detras de un gate apagado.';
