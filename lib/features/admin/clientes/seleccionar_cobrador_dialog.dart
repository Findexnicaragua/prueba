import 'package:flutter/material.dart';

import '../../../data/utils/busqueda_cliente.dart' show coincideTokens;
import '../../../data/utils/errores.dart';
import '../../../powersync/db.dart' as ps;

/// Diálogo para elegir un cobrador (activos, rol 'cobrador') o "Desasignar".
/// Devuelve `({String? id, String label})` vía `Navigator.pop`, o null si se
/// cancela. Compartido por la lista de clientes (asignación masiva) y la
/// pantalla de Rutas (reasignar comunidad entera).
///
/// [permitirDesasignar]: si es false, oculta la opción "Desasignar (sin
/// cobrador)".
/// [distribucionActual]: resumen pre-resuelto (con nombres) de cómo están
/// asignados HOY los clientes en juego — ej. [(Cobrador A, 95), (Cobrador B, 5),
/// (Sin cobrador, 2)]. Se muestra arriba del selector. La pantalla Rutas lo
/// pasa; el multi-select por cliente no.
class SeleccionarCobradorDialog extends StatefulWidget {
  const SeleccionarCobradorDialog({
    super.key,
    this.permitirDesasignar = true,
    this.distribucionActual,
  });

  final bool permitirDesasignar;
  final List<({String etiqueta, int cantidad})>? distribucionActual;

  @override
  State<SeleccionarCobradorDialog> createState() =>
      _SeleccionarCobradorDialogState();
}

class _SeleccionarCobradorDialogState extends State<SeleccionarCobradorDialog> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;
  String _busqueda = '';

  @override
  void initState() {
    super.initState();
    _cobradoresStream = ps.db.watch(
      '''
      SELECT id, nombre, prefijo_recibo FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Ancho responsive: 400 en desktop/tablet, 90% del viewport en mobile
    // chico (un 400 fijo desborda el AlertDialog en pantallas ~360px).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    final dist = widget.distribucionActual;
    return AlertDialog(
      title: const Text('Asignar cobrador'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Resumen de la asignación actual (solo si se pasó — pantalla Rutas).
            if (dist != null && dist.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Asignación actual',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    ...dist.map((d) => Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Text(d.etiqueta,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: scheme.onSurfaceVariant)),
                              ),
                              Text('${d.cantidad}',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            // Buscador de cobradores (útil con muchos cobradores en el tenant).
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar cobrador',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _busqueda = v.trim()),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _cobradoresStream,
                initialData: const [],
                builder: (context, snap) {
                  if (snap.hasError) {
                    return SizedBox(
                        height: 100,
                        child: Center(
                            child: Text(mensajeErrorHumano(snap.error!))));
                  }
                  final rows = _busqueda.isEmpty
                      ? snap.data!
                      : snap.data!
                          .where((r) =>
                              coincideTokens(r['nombre'] as String, _busqueda))
                          .toList();
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      // "Desasignar" solo sin búsqueda activa (no es un cobrador).
                      if (widget.permitirDesasignar && _busqueda.isEmpty) ...[
                        ListTile(
                          leading: const Icon(Icons.person_off),
                          title: const Text('Desasignar (sin cobrador)'),
                          onTap: () => Navigator.pop(
                              context, (id: null, label: 'Sin cobrador')),
                        ),
                        const Divider(height: 1),
                      ],
                      ...rows.map((r) => ListTile(
                            leading: const Icon(Icons.person),
                            title: Text(r['nombre'] as String),
                            subtitle: Text(r['prefijo_recibo'] as String? ?? '—'),
                            onTap: () => Navigator.pop(
                                context,
                                (
                                  id: r['id'] as String,
                                  label: r['nombre'] as String
                                )),
                          )),
                      if (rows.isEmpty && _busqueda.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Sin resultados'),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
