/// Conceptos de **COBRO PUNTUAL**: cargos de una sola vez, FUERA del ciclo
/// mensual del contrato. Cada uno se materializa como una **cuota manual**
/// (`tipo_cargo_manual` NOT NULL, `contrato_id` NULL → standalone) que se cobra
/// y recibe igual que una cuota mensual, pero queda EXCLUIDA del total facturable
/// y de los invariantes (INV11). Reactiva el primitivo de cuota manual.
///
/// El concepto FINO (lo que sale en el recibo) va en la `descripcion` de la
/// cuota — el nombre del tipo de ticket (cobro de campo) o lo que tipea el admin.
/// Estos son la CATEGORÍA coarse (el tag `tipo_cargo_manual`) + su etiqueta.
const Map<String, String> kCobroPuntualTipos = <String, String>{
  'instalacion': 'Instalación',
  'reinstalacion': 'Reinstalación',
  'reconexion': 'Reconexión',
  'anexo': 'Anexo',
  'multa': 'Multa',
  'otro': 'Otro cargo',
};

/// Conceptos que ofrece el botón "Cobro puntual" del CLIENTE: cargos que DECIDE
/// el admin (multa, otro cargo). El trabajo de campo (instalación, reconexión,
/// reinstalación, anexo) se cobra DESDE EL TICKET (0173), no desde el cliente.
const List<String> kCobroPuntualAdminTipos = <String>['multa', 'otro'];

/// Etiqueta legible de un `tipo_cargo_manual` (fallback: el código crudo).
String etiquetaCobroPuntual(String tipo) => kCobroPuntualTipos[tipo] ?? tipo;

/// Categoría de cobro a partir del `efecto` de un tipo de ticket (cobro desde el
/// ticket). instalacion/reconexion conservan su categoría; el resto cae a 'otro'
/// (el concepto fino lo da la `descripcion` = nombre del tipo de ticket).
String tipoCobroDeEfecto(String? efecto) =>
    (efecto == 'instalacion' || efecto == 'reconexion') ? efecto! : 'otro';
