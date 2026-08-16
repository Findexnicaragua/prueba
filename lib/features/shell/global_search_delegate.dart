import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/busqueda_cliente.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;

class GlobalSearchDelegate extends SearchDelegate<String?> {
  GlobalSearchDelegate({required this.settings}) : super(
    searchFieldLabel: 'Buscar cliente, cédula o recibo',
    searchFieldStyle: const TextStyle(fontSize: 16),
  );

  /// Campos de búsqueda habilitados (toggles super_admin). Lo consume el helper
  /// compartido `busquedaClienteSql`.
  final AppSettings settings;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildSuggestions(BuildContext context) => _buildResults(context);

  @override
  Widget buildResults(BuildContext context) => _buildResults(context);

  Widget _buildResults(BuildContext context) {
    if (query.trim().length < 2) {
      return Center(
        child: Text(
          'Escribí al menos 2 caracteres',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }

    return FutureBuilder<List<_SearchResult>>(
      future: _search(query),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snap.data ?? [];
        if (results.isEmpty) {
          return Center(
            child: Text(
              'Sin resultados para "$query"',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          );
        }

        return ListView.separated(
          itemCount: results.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = results[i];
            final scheme = Theme.of(context).colorScheme;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: r.tipo == 'cliente'
                    ? scheme.primaryContainer
                    : scheme.tertiaryContainer,
                child: Icon(
                  r.tipo == 'cliente' ? Icons.person : Icons.receipt_long,
                  color: r.tipo == 'cliente' ? scheme.primary : scheme.tertiary,
                ),
              ),
              title: Text(r.titulo),
              subtitle: Text(r.subtitulo,
                  style: TextStyle(color: scheme.outline, fontSize: 12)),
              onTap: () {
                close(context, null);
                context.push(r.ruta);
              },
            );
          },
        );
      },
    );
  }

  Future<List<_SearchResult>> _search(String queryRaw) async {
    final results = <_SearchResult>[];

    // Búsqueda de cliente configurable (toggles super_admin) vía el helper
    // compartido — respeta qué campos están habilitados (nombre siempre entra).
    final b = busquedaClienteSql(queryRaw, settings, alias: 'c');
    final clientes = await ps.db.getAll(
      '''
      SELECT c.id, c.codigo, c.nombre, c.cedula, co.nombre AS comunidad
        FROM clientes c
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE c.activo = 1
         ${b.sql.isEmpty ? '' : 'AND ${b.sql}'}
       ORDER BY c.nombre
       LIMIT 10
      ''',
      b.params,
    );
    for (final c in clientes) {
      results.add(_SearchResult(
        tipo: 'cliente',
        titulo: c['nombre'] as String,
        subtitulo: [
          if (c['codigo'] != null) c['codigo'] as String,
          if (c['cedula'] != null) c['cedula'] as String,
          if (c['comunidad'] != null) c['comunidad'] as String,
        ].join(' · '),
        ruta: '/clientes/${c['id']}',
      ));
    }

    // Recibos por número con búsqueda por TOKENS plegada (consistente con pagos
    // y el resto; #1d). foldSqlTokens devuelve sql:'' si la query está vacía.
    final reciboBusq = foldSqlTokens('r.numero_completo', queryRaw);
    final recibos = reciboBusq.sql.isEmpty
        ? const <Map<String, dynamic>>[]
        : await ps.db.getAll(
            '''
      SELECT r.id, r.numero_completo, p.fecha_pago, p.monto_cordobas,
             c.nombre AS cliente
        FROM recibos r
        JOIN pagos p ON p.id = r.pago_id
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
       WHERE ${reciboBusq.sql}
       ORDER BY r.created_at DESC
       LIMIT 10
      ''',
            reciboBusq.params,
          );
    for (final r in recibos) {
      results.add(_SearchResult(
        tipo: 'recibo',
        titulo: r['numero_completo'] as String,
        subtitulo:
            '${r['cliente']} · ${Fmt.cordobas(r['monto_cordobas'] as num)}',
        ruta: '/recibo/${r['id']}',
      ));
    }

    return results;
  }
}

class _SearchResult {
  const _SearchResult({
    required this.tipo,
    required this.titulo,
    required this.subtitulo,
    required this.ruta,
  });
  final String tipo;
  final String titulo;
  final String subtitulo;
  final String ruta;
}
