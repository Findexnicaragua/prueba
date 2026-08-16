import 'package:flutter/material.dart';

/// Caja con pulso suave de opacidad, usada como placeholder mientras
/// carga data. Más amigable que un spinner porque preserva la forma del
/// layout y le da al user la sensación de "ya está cargando algo".
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius = 8,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return _SkeletonPulse(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
    );
  }
}

/// Avatar circular skeleton — para preservar el lugar de un CircleAvatar.
class SkeletonAvatar extends StatelessWidget {
  const SkeletonAvatar({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return _SkeletonPulse(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Card placeholder que imita la silueta de un card de lista
/// (avatar + 2 líneas de texto + chip). Repetir N veces para listas.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    super.key,
    this.hasAvatar = true,
    this.hasChip = true,
    this.marginBottom = 8,
  });

  final bool hasAvatar;
  final bool hasChip;

  /// Para evitar layout jump al cargar, el caller pasa el mismo margin
  /// que usen los cards reales (8 para MiembroCard, 12 para _TenantCard).
  final double marginBottom;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.only(bottom: marginBottom),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasAvatar) ...[
              const SkeletonAvatar(),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBox(width: 160, height: 16),
                  const SizedBox(height: 6),
                  const SkeletonBox(width: 200, height: 12),
                  const SizedBox(height: 8),
                  const SkeletonBox(width: 120, height: 12),
                  if (hasChip) ...[
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        SkeletonBox(width: 64, height: 16, borderRadius: 10),
                        SizedBox(width: 8),
                        SkeletonBox(width: 80, height: 16, borderRadius: 10),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lista de N skeleton cards. Usar en estado `loading` de un FutureProvider.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.count = 3,
    this.hasAvatar = true,
    this.hasChip = true,
    this.cardMarginBottom = 8,
  });

  final int count;
  final bool hasAvatar;
  final bool hasChip;
  final double cardMarginBottom;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (_) => SkeletonCard(
          hasAvatar: hasAvatar,
          hasChip: hasChip,
          marginBottom: cardMarginBottom,
        ),
      ),
    );
  }
}

/// Wrapper interno que aplica el pulso de opacidad al child.
/// Se separa para reutilizar entre Box y Avatar.
class _SkeletonPulse extends StatefulWidget {
  const _SkeletonPulse({required this.child});
  final Widget child;

  @override
  State<_SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<_SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Reduce motion: skeleton estático en opacidad media — sin pulso.
      _ctrl.value = 0.5;
    } else {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        // Opacity entre 0.4 y 0.8 — pulso visible pero no irritante.
        return Opacity(
          opacity: 0.4 + 0.4 * _ctrl.value,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
