import 'package:flutter/material.dart';

/// Botón "Cargar más" que aparece como item sentinel al final de listas
/// paginadas. Disabled + spinner mientras `loading=true` para evitar
/// taps rápidos que salten varias páginas sin feedback.
///
/// Se usa en la lista de clientes (`clientes_admin_screen`), que sirve tanto
/// al admin como al cobrador (soloLectura). Misma estética en ambos contextos.
class CargarMasButton extends StatelessWidget {
  const CargarMasButton({
    super.key,
    required this.loading,
    required this.onPressed,
  });

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Center(
        child: OutlinedButton.icon(
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more),
          label: Text(loading ? 'Cargando…' : 'Cargar más'),
          onPressed: loading ? null : onPressed,
        ),
      ),
    );
  }
}
