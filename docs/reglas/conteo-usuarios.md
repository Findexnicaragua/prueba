# Regla: la columna "Usuarios" cuenta PERSONAS, y por eso NO cuadra con "Cuotas"

**Enunciado, en una línea.** Los seis conteos de usuarios del Resumen —los tres
de Cobertura del ciclo y los tres de Mora— son **`COUNT(DISTINCT cliente_id)`**
sobre exactamente el mismo `WHERE` que su columna de cuotas, y **el Excel cuenta
igual**. La diferencia contra "Cuotas" **no es un descuadre: es el dato**.

**Para qué existe la columna** (palabras del dueño del tenant, 2026-09-02): *"al
ver visualmente la cantidad de usuarios y las cuotas, si ve que hay más cuotas
revisa si por accidente un usuario tiene 2 contratos"*. O sea: la columna sirve
**solo si puede diferir**. Contando contratos da 1:1 siempre, por construcción, y
la herramienta queda inútil sin que nada falle.

## 🔴 Esto se decidió DOS VECES, en sentidos opuestos

Antes de "arreglar" que hay más cuotas que usuarios, leer esto:

| Fecha | Qué contaba | Por qué se cambió |
|---|---|---|
| hasta 2026-08-24 | personas | — |
| **2026-08-24** | **contratos** | el dueño vio "más cuotas que usuarios" y lo reportó como error de la app |
| 2026-08-27 | contratos | se le cambió el RÓTULO a "Servicios" para que dijera lo que contaba (el rótulo se perdió al volver al Resumen anterior en v0.37.1) |
| **2026-09-02** | **personas** | el dueño explicó PARA QUÉ la usa; contando contratos eso es imposible de ver |

Medido en los tres tenants antes de cambiarlo: con contratos, Mairena da
**4.414 = 4.414**; con personas, **4.409 contra 4.414** = cinco clientes con dos
servicios (CATV + COMBO), todos legítimos. Telenet difiere en 1, Test Tenant en 4.

**Sin `COALESCE`, a diferencia de la versión de contratos:** `cliente_id` es
NOT NULL en las 61.059 cuotas vivas de producción — una cuota siempre pertenece a
alguien, incluso un cargo manual, que tiene `contrato_id` NULL pero cliente sí.
Verificado antes de sacarlo.

## Las dos causas de que difieran, y ninguna es un bug

1. **Alguien con dos contratos** — lo que el dueño busca ver.
2. **Un contrato con dos vencimientos en la misma ventana 15→14** — pasa si el
   día de pago cae domingo y `calcular_fecha_pago` corre el vencimiento al lunes,
   empujándolo al ciclo próximo junto al que ya estaba (14/6/2026: 129 casos en
   Mairena, 21 en Telenet). Son dos cobros reales de UNA persona con UN contrato.

## Lo que se rompe callado

**El Excel.** Su fila de cierre dice `N usuarios`, y hasta el 2026-09-02 contaba
SERVICIOS mientras la tarjeta ya contaba personas: habría dicho 4.414 contra
4.409 en la pantalla. Los dos números son creíbles y nada falla — solo se
contradicen. Lo cubre `usuarios_cierran_con_excel_test.dart`, que compara contra
el número que el archivo **realmente escribe**, no contra el universo
reconstruido a mano.

**El `WHERE` de cada `*_u` tiene que ser idéntico al de su `*_c`.** Es lo único
que garantiza que la columna cierre contra el desglose del Excel, que recorre ese
mismo universo. Al tocar un filtro de un lado, grepear el otro.

**No hay texto explicativo en la tabla, y es deliberado** (*"en tenants grandes
eso puede ser demasiado contexto visual"*). La explicación vive en el globo de
ayuda de la tarjeta ("POR QUÉ HAY MÁS CUOTAS QUE CLIENTES") y el detalle de
QUIÉNES, en el Excel.

```regla
simbolos:
  meta_u
  rec_u
  porrec_u
  mora_u
  pend_u
  metaUsuarios
  recUsuarios
  porRecUsuarios
  moraUsuarios
  pendUsuarios
  cliente_id AS cliente_id
prohibido:
  COUNT(DISTINCT COALESCE(cu.contrato_id
docs:
  ARQUITECTURA.md -> §Dashboard admin, "La columna Usuarios cuenta PERSONAS"
superficies:
  ARQUITECTURA.md
  lib/features/admin/dashboard/dashboard_query.dart
  lib/features/admin/dashboard/mora_ciclos_card.dart
  lib/features/admin/dashboard/tendencia_cobros_card.dart
  lib/features/cuotas/cobros_query.dart
  test/features/admin/dashboard/dashboard_numeros_test.dart
  test/features/admin/dashboard/mora_cobertura_ui_test.dart
  test/features/admin/dashboard/usuarios_cierran_con_excel_test.dart
```
