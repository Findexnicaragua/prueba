import 'package:flutter/material.dart';

/// Logo de marca para las pantallas de autenticación (login y crear/
/// restablecer contraseña).
///
/// White-label (Opción B): muestra `assets/branding/login_logo.png`. En un
/// build branded por tenant ese asset es el logo del ISP (el MISMO del
/// recibo, horneado por `tool/aplicar_branding.dart`); en el build genérico es
/// el logo por defecto. Va sobre una tarjeta blanca redondeada para
/// que cualquier logo (ancho, oscuro o con transparencia) se vea bien en tema
/// claro y oscuro.
class BrandLoginLogo extends StatelessWidget {
  const BrandLoginLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 92),
          child: Image.asset(
            'assets/branding/login_logo.png',
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
