import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/op_log_campos.dart';
import '../../shared/widgets/empty_state.dart';

/// Verde de "campo visible" (mismo del cobro), legible en claro y oscuro.
const _verde = Color(0xFF1D9E75);
const _verdeOscuro = Color(0xFF0F6E56);

/// Panel del super_admin: por ENTIDAD/tabla (clientes, contratos, cuotas,
/// equipos, etc.), qué campos aparecen en el change log unificado
/// (`HistorialOpLog`). La selección se guarda en el setting per-tenant
/// `op_log.campos_visibles` (map JSONB `{entidad: [campos]}`).
///
/// Sin config guardada para una entidad → el render cae a los defaults curados
/// (`kOpLogCamposVisiblesDefault`). Gate: solo super_admin.
class OpLogCamposScreen extends ConsumerStatefulWidget {
  const OpLogCamposScreen({super.key});

  @override
  ConsumerState<OpLogCamposScreen> createState() => _OpLogCamposScreenState();
}

class _OpLogCamposScreenState extends ConsumerState<OpLogCamposScreen> {
  // {entidad: {campos marcados}}.
  Map<String, Set<String>>? _seleccion;
  bool _guardando = false;

  Map<String, Set<String>> _estadoInicial(Map<String, List<String>> cfg) {
    final out = <String, Set<String>>{};
    for (final entidad in kOpLogCamposCatalogo.keys) {
      final desdeConfig = cfg[entidad];
      if (desdeConfig != null) {
        final catalogo = kOpLogCamposCatalogo[entidad]!.toSet();
        out[entidad] = desdeConfig.where(catalogo.contains).toSet();
      } else {
        out[entidad] = {...?kOpLogCamposVisiblesDefault[entidad]};
      }
    }
    return out;
  }

  Future<void> _guardar() async {
    final seleccion = _seleccion;
    if (seleccion == null) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null || tenantId.isEmpty) return;

    setState(() => _guardando = true);
    try {
      final valor = <String, List<String>>{};
      for (final entidad in kOpLogCamposCatalogo.keys) {
        final marcados = seleccion[entidad] ?? const <String>{};
        valor[entidad] =
            kOpLogCamposCatalogo[entidad]!.where(marcados.contains).toList();
      }
      await ref.read(settingsRepoProvider).upsert(
            tenantId,
            'op_log.campos_visibles',
            valor,
            tipo: 'json',
            categoria: 'cobranza',
            // Clave SÓLO del super_admin (fix F0): así la RLS impide que un
            // admin del tenant la sobreescriba.
            editablePor: 'super_admin',
            usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Campos del historial guardados')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e, contexto: 'guardar'))),
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;

    if (cobrador != null && !cobrador.esSuperAdmin) {
      return const EmptyState(
        icon: Icons.lock_outline,
        titulo: 'Acceso restringido',
        descripcion: 'Solo el Dev puede configurar esto.',
      );
    }

    final settingsAsync = ref.watch(settingsMapProvider);
    if (!settingsAsync.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    _seleccion ??= _estadoInicial(
      ref.read(appSettingsProvider).opLogCamposOverride,
    );
    final seleccion = _seleccion!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune, color: scheme.primary, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Qué se ve en el historial de cambios',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Elegí, por tabla/entidad (clientes, contratos, cuotas, '
                  'equipos, etc.), qué campos aparecen en el historial. Tocá un '
                  'campo para mostrarlo (verde) u ocultarlo. Sin tocar una '
                  'entidad, se usan los campos recomendados por defecto. Aplica '
                  'a este tenant.',
                  style: TextStyle(color: scheme.outline, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ...kOpLogCamposCatalogo.keys.map((entidad) {
          final campos = kOpLogCamposCatalogo[entidad]!;
          final marcados = seleccion[entidad] ?? <String>{};
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.history, color: scheme.primary, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          opLogEntidadLabel(entidad),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                      ),
                      Text(
                        '${marcados.length}/${campos.length}',
                        style:
                            TextStyle(color: scheme.outline, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: campos.map((campo) {
                      final on = marcados.contains(campo);
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          setState(() {
                            final set = seleccion.putIfAbsent(
                                entidad, () => <String>{});
                            if (on) {
                              set.remove(campo);
                            } else {
                              set.add(campo);
                            }
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: on
                                ? _verde.withValues(alpha: 0.10)
                                : null,
                            border: Border.all(
                              color: on ? _verde : scheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                on ? Icons.toggle_on : Icons.toggle_off,
                                size: 22,
                                color: on ? _verde : scheme.outline,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                opLogCampoLabel(campo),
                                style: TextStyle(
                                  color: on
                                      ? _verdeOscuro
                                      : scheme.onSurfaceVariant,
                                  fontWeight:
                                      on ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _guardando ? null : _guardar,
          icon: _guardando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: Text(_guardando ? 'Guardando...' : 'Guardar'),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
