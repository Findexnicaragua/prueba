import 'dart:async';

import 'package:flutter/material.dart';

/// Anima el primer render de un ítem de lista con fade + slide-up,
/// escalonando el inicio según `index` para crear el efecto de cascada.
///
/// Usar dentro de un ListView.builder o Column:
///   children: items.asMap().entries.map((e) => AnimatedListEntry(
///     index: e.key,
///     child: MyCard(item: e.value),
///   )).toList()
///
/// La animación corre una sola vez al primer build. Si la lista cambia
/// después (provider invalidate), los items existentes no re-animan
/// (Flutter recicla el State).
class AnimatedListEntry extends StatefulWidget {
  const AnimatedListEntry({
    super.key,
    required this.index,
    required this.child,
    this.duration = const Duration(milliseconds: 280),
    this.delayPerIndex = const Duration(milliseconds: 50),
    this.maxDelay = const Duration(milliseconds: 400),
  });

  final int index;
  final Widget child;
  final Duration duration;
  final Duration delayPerIndex;
  final Duration maxDelay;

  @override
  State<AnimatedListEntry> createState() => _AnimatedListEntryState();
}

class _AnimatedListEntryState extends State<AnimatedListEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;
  Timer? _startTimer;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Schedule sólo la primera vez — didChangeDependencies puede ser
    // llamado múltiples veces si cambia el theme/locale.
    if (_scheduled) return;
    _scheduled = true;

    // Si el usuario tiene 'reducir animaciones' activado a nivel OS,
    // salteamos al estado final inmediatamente (WCAG 2.3.3).
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.value = 1.0;
      return;
    }

    // Delay escalonado por índice, cap a maxDelay.
    final rawDelayMs = widget.delayPerIndex.inMilliseconds * widget.index;
    final cappedMs =
        rawDelayMs.clamp(0, widget.maxDelay.inMilliseconds).toInt();
    _startTimer = Timer(Duration(milliseconds: cappedMs), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}
