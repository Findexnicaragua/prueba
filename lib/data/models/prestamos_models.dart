library;

/// Modelos de datos para el módulo de Microfinanzas y Préstamos de Findex.

class ResumenCartera {
  final int clientesCount;
  final int prestamosCount;
  final int activosCount;
  final double activosMonto;
  final int moraVigenteCount;
  final double moraVigenteMonto;
  final int porVencerCount;
  final double porVencerMonto;
  final int moraVencidaCount;
  final double moraVencidaMonto;
  final int pagadosCount;
  final double pagadosMonto;
  final int enMoraCount;
  final double enMoraMonto;
  final int casosPendientesCount;
  final int creditosAprobadosCount;
  final int desembolsosHoyCount;
  final double desembolsosHoyMonto;

  const ResumenCartera({
    this.clientesCount = 0,
    this.prestamosCount = 0,
    this.activosCount = 0,
    this.activosMonto = 0.0,
    this.moraVigenteCount = 0,
    this.moraVigenteMonto = 0.0,
    this.porVencerCount = 0,
    this.porVencerMonto = 0.0,
    this.moraVencidaCount = 0,
    this.moraVencidaMonto = 0.0,
    this.pagadosCount = 0,
    this.pagadosMonto = 0.0,
    this.enMoraCount = 0,
    this.enMoraMonto = 0.0,
    this.casosPendientesCount = 0,
    this.creditosAprobadosCount = 0,
    this.desembolsosHoyCount = 0,
    this.desembolsosHoyMonto = 0.0,
  });

  double get totalCarteraAdeudada => activosMonto + moraVigenteMonto + moraVencidaMonto;
}

class EstadoCaja {
  final double cajaInicial;
  final double capitalAportado;
  final double ingresosNetos;
  final double egresos;
  final double cajaActual;
  final double cajaPrestamos;
  final double bancos;
  final double gastosDiarios;
  final double capitalRecuperado;
  final double interesesCobrados;
  final double proyeccionInteres;
  final double interesesAcumulados;

  const EstadoCaja({
    this.cajaInicial = 15733.34,
    this.capitalAportado = 50000.00,
    this.ingresosNetos = 0.0,
    this.egresos = 0.0,
    this.cajaActual = 15733.34,
    this.cajaPrestamos = 12000.00,
    this.bancos = 5000.00,
    this.gastosDiarios = 0.0,
    this.capitalRecuperado = 0.0,
    this.interesesCobrados = 0.0,
    this.proyeccionInteres = 733.33,
    this.interesesAcumulados = 1191.67,
  });

  double get totalRecaudado => capitalRecuperado + interesesCobrados;
}

class DesembolsoItem {
  final String id;
  final String codigo;
  final String clienteNombre;
  final String cedula;
  final double monto;
  final DateTime fechaDesembolso;
  final int plazoCuotas;
  final String sucursal;
  final String oficialNombre;
  final String estado;

  const DesembolsoItem({
    required this.id,
    required this.codigo,
    required this.clienteNombre,
    required this.cedula,
    required this.monto,
    required this.fechaDesembolso,
    required this.plazoCuotas,
    required this.sucursal,
    required this.oficialNombre,
    this.estado = 'desembolsado',
  });
}

class IndicadorOficial {
  final String id;
  final String nombre;
  final String sucursal;
  final DateTime fecha;
  final double saldoCartera;
  final int prestamosTotales;
  final double porcentajeMoraTotal;
  final double montoMoraTotal;
  final double recuperacionMes;
  final int creditosEnMora;

  const IndicadorOficial({
    required this.id,
    required this.nombre,
    required this.sucursal,
    required this.fecha,
    required this.saldoCartera,
    required this.prestamosTotales,
    required this.porcentajeMoraTotal,
    required this.montoMoraTotal,
    required this.recuperacionMes,
    this.creditosEnMora = 0,
  });
}

class IndicadorSucursal {
  final String sucursal;
  final double saldoCartera;
  final int clientesTotales;
  final int prestamosTotales;
  final double montoMoraTotal;
  final double porcentajeMoraTotal;
  final double recuperacionMes;
  final int creditosEnMora;

  const IndicadorSucursal({
    required this.sucursal,
    required this.saldoCartera,
    required this.clientesTotales,
    required this.prestamosTotales,
    required this.montoMoraTotal,
    required this.porcentajeMoraTotal,
    required this.recuperacionMes,
    this.creditosEnMora = 0,
  });
}