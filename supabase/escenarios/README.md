# Escenarios de prueba controlados

Datos con **resultado conocido de antemano**, para verificar que los números del
Resumen son los correctos.

La idea: con 4.600 clientes reales, cuando un número no cuadra hay que
investigar. Con clientes cuyos pagos elegimos nosotros, el número esperado se
calcula a mano y la comparación es inmediata.

## Escenario "aritmética del Resumen"

**15 clientes repartidos en 6 ciclos (mar–ago 2026).** Cada uno existe para
disparar un caso de borde distinto:

| Cliente | Qué caso cubre |
|---|---|
| TT-01 | Control: paga siempre dentro de la gracia. Y un adelanto |
| TT-02 | Moroso crónico que siempre se pone al día tarde |
| TT-03 | Paga el ÚLTIMO día de gracia exacto (el borde) |
| TT-04 | Paga un día después de vencer (dentro de la gracia) |
| TT-05 | **Un cliente con DOS contratos** (dos puntos en la misma casa) |
| TT-06 | Cuota con abono PARCIAL en el ciclo en curso |
| TT-07 | Crédito a favor aplicado (cargo negativo, sin fila en pagos) |
| TT-08 | Dos cobros sobre la MISMA cuota + cuota que vence el primer día del ciclo |
| TT-09 | **Contrato suspendido** que pagó los ciclos cerrados + cuota anulada |
| TT-10 | Contrato cancelado con deuda |
| TT-11 | Cargo extra positivo (reconexión) + pagos tardíos |
| TT-12 | Pago anulado + pago en revisión + cuota anulada |
| TT-13 | Pre-pago antes del inicio del ciclo + cobro puntual |
| TT-14 | Descuento (cargo negativo) + borde final de la ventana |

**TT-09 es el importante.** Pagó de marzo a julio y se suspende en agosto: con
el filtro de suspendidos que había antes, esa plata desaparecía de los cinco
ciclos cerrados donde entró.

## Los dos usos del mismo escenario

`dashboard.json` es la fuente única. Dos generadores lo bajan a dos lados:

```bash
# 1. SQLite, para el test: corre las consultas de produccion y compara
python supabase/escenarios/generar_seed_dart.py
flutter test test/features/admin/dashboard/dashboard_numeros_test.dart
```

```bash
# 2. Postgres, para VER el escenario en la app (tenant de prueba)
python supabase/escenarios/generar_seed_sql.py
supabase db query --linked -f supabase/escenarios/dashboard_seed.sql
```

El seed de Postgres **borra** la data operativa del tenant de prueba y la
reemplaza. Deja los 20 invariantes de dinero en cero.

## Qué tiene que dar

Ciclo en curso **15 jul – 14 ago 2026**, con 7 días de gracia:

| Tarjeta | Fila | Usuarios | Cuotas | Monto |
|---|---|---|---|---|
| Cobros del mes | Cobros | 13 | 15 | 11.200 |
| Cobros del mes | Recuperado | 7 | 8 | 5.800 |
| Cobros del mes | ↳ tarde | — | — | 1.570 |
| Cobros del mes | Por recuperar | 8 | 8 | 5.400 |
| Mora del ciclo | Total mora | 6 | 7 | 4.525 |
| Mora del ciclo | Recuperado | 2 | 2 | 1.570 |
| Mora del ciclo | Por recuperar | 5 | 5 | 2.955 |

Los 6 ciclos de la histórica, con la mora moviéndose mes a mes:

| Ciclo | Total | Recuperado | Sigue debiéndose |
|---|---|---|---|
| mar | 2.030 | 2.030 | 0 |
| abr | 3.355 | 3.355 | 0 |
| may | 5.260 | 5.260 | 0 |
| jun | 3.655 | 3.340 | 315 |
| jul | 3.125 | 2.510 | 615 |
| ago (en curso) | 4.525 | 1.570 | 2.955 |

## Dos cosas que el escenario enseñó

**El sobrepago no es alcanzable por doble cobro.** TT-08 se diseñó con dos
cobros sobre la misma cuota para provocar una cuota sobrepagada. Al sembrarlo
contra el server real, el guard de la migración 0218 mandó el segundo pago a
REVISIÓN por sobrepago, y `monto_pagado` quedó correcto. O sea que ese camino ya
está cerrado: el saldo negativo solo se alcanza BAJANDO el total después de
cobrar (quitar un cargo de una cuota ya pagada, o la cancelación de contrato).
El escenario se corrigió para reflejar lo que el server realmente hace.

**Las cuotas las genera el server.** Insertar un contrato dispara el trigger que
las crea solas. Por eso el seed las borra antes de poner las del escenario, con
sus fechas exactas.

## Ojo con las fechas

Las fechas son FIJAS (mar–ago 2026) porque los números esperados dependen de
ellas. Corrido mucho después, hay que mirar el ciclo de agosto 2026 con las
flechas de la tarjeta, no el que abre por defecto.
