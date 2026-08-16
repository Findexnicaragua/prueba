// Entry point con conditional import. En mobile carga la implementación
// real con print_bluetooth_thermal; en web carga el stub.

export 'impresora_service_io.dart'
    if (dart.library.html) 'impresora_service_web.dart';
