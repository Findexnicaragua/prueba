import '../../../powersync/db.dart' as ps;

/// Freno de las consultas del Resumen.
///
/// `db.watch` re-ejecuta su consulta **entera** ante cualquier cambio en las
/// tablas que toca, y por defecto espera sólo **30 ms** entre re-ejecuciones.
/// Con 16 consultas vivas y un sync que trae cambios todo el tiempo, eso
/// mantenía ocupadas de forma permanente las **5 lecturas concurrentes** que
/// abre PowerSync (`defaultMaxReaders`): la lista de clientes y el filtro de
/// planes quedaban en la cola y devolvían vacío. Es el incidente del
/// 2026-09-03 — la app entera en blanco después de pasar por el Resumen.
///
/// Un dashboard no necesita moverse solo mientras uno lo mira. Segundo y medio
/// es imperceptible para quien lee un total, y le devuelve el aire al resto de
/// la app.
const Duration kFrenoResumen = Duration(milliseconds: 1500);

/// `ps.db.watch` con el freno del Resumen puesto.
///
/// Existe como función y no como un parámetro más en cada llamada por una
/// razón práctica: son 20 consultas repartidas en 9 archivos, y agregarles un
/// argumento a mano —o peor, con un reemplazo automático— es exactamente como
/// se rompe algo sin querer. Cambiar `ps.db.watch(` por `watchResumen(` es un
/// cambio de NOMBRE: la firma es la misma, así que no puede alterar los
/// argumentos de nadie.
///
/// Si alguna consulta del Resumen necesitara ser más viva que las demás, se
/// le pasa su propio `throttle`; el default es el freno común.
Stream<List<Map<String, dynamic>>> watchResumen(
  String sql, {
  List<Object?> parameters = const [],
  Duration throttle = kFrenoResumen,
}) =>
    ps.db.watch(sql, parameters: parameters, throttle: throttle);
