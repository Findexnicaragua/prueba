# Escenarios de prueba controlados

Datos de prueba con **resultado conocido de antemano**, para verificar que los
números del Resumen son los correctos.

La idea: con 4.500 clientes reales, cuando un número no cuadra hay que
investigar. Con 4 clientes cuyos pagos elegimos nosotros, el número esperado se
calcula a mano en un minuto y la comparación es inmediata.

## Escenario "lectura del dashboard" — Test Tenant

Cuatro clientes que cubren los cuatro casos donde la lectura se presta a
confusión:

| Cliente | Cuota | Vence | Qué hace |
|---|---|---|---|
| Ana | 500 | 20 jul | Paga el mismo día — **a tiempo** |
| Beto | 800 | 16 jul | **No paga** — cae en mora |
| Carla | 600 | 18 jul | Paga el 5 ago — **tarde**, pasada la gracia |
| Dani | 700 | 20 **jun** | Paga el 1 ago una cuota **de otro ciclo** |

**Dani es el caso importante.** Su plata entra en la caja del período pero no
aparece en "Recuperado", porque cubre un mes anterior. Es exactamente el hueco
donde al dueño del tenant no le cerró la cuenta en agosto de 2026 — reproducido
en miniatura.

### Cómo correrlo

Contra el tenant de pruebas, **en este orden** (el segundo depende de las cuotas
que genera el trigger del server al insertar los contratos):

```bash
supabase db query --linked -f supabase/escenarios/01_clientes_y_contratos.sql
supabase db query --linked -f supabase/escenarios/02_pagos.sql
supabase db query --linked -f supabase/escenarios/03_recibos.sql
```

Los contratos se insertan y las cuotas las genera el servidor solo, como en la
vida real. Los pagos se aplican después, buscando la cuota por
(cliente, fecha de vencimiento) — así no dependen de ids que cambian al
re-sembrar.

### Qué tiene que dar

Ciclo **agosto 2026** (15 jul – 14 ago), con 10 días de gracia:

| Tarjeta | Fila | Esperado |
|---|---|---|
| Cobros del mes | Cobros | 2.600 |
| Cobros del mes | Recuperado | 1.100 |
| Cobros del mes | Por recuperar | 1.500 |
| Mora del ciclo | Total mora | 2.100 |
| Mora del ciclo | Recuperado | 600 |
| Mora del ciclo | Por recuperar | 1.500 |
| Desglose de caja | Cuotas del ciclo | 1.100 |
| Desglose de caja | Deuda vieja | 700 |
| Desglose de caja | **Total que entró** | **1.800** |

Verificado contra la base el 2026-08-11: los siete coinciden exactamente.

**La lección del escenario:** "Recuperado" dice 1.100 y a la caja entraron
1.800. No es un error — son dos preguntas distintas. "Recuperado" mide cuánto de
lo que vence este mes ya se cobró; la caja mide cuánta plata entró, sin importar
qué mes cubre.

### Ojo con las fechas

El escenario tiene fechas FIJAS (julio/agosto 2026) porque los números esperados
dependen de ellas. Corrido mucho después, las cuotas siguen donde están pero el
ciclo "en curso" ya es otro: hay que mirar el período de agosto 2026 con las
flechas de la tarjeta, no el que abre por defecto.

### Para limpiar

El tenant se vacía con el mismo orden seguro de FKs que se usó en la limpieza
del 2026-08-09 (pagos → cuotas → contratos → clientes).
