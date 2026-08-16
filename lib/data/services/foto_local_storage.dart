// Entry point con conditional import. En mobile/desktop carga la
// implementación con dart:io; en web carga el stub.
export 'foto_local_storage_io.dart'
    if (dart.library.html) 'foto_local_storage_web.dart';
