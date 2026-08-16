// Entry point con conditional import. En mobile/desktop carga la
// implementación con dart:io + path_provider; en web carga el stub
// (web no imprime en térmica y no tiene filesystem persistente).
export 'logo_local_storage_io.dart'
    if (dart.library.html) 'logo_local_storage_web.dart';
