"""Genera la POBLACION del escenario del dashboard: los clientes de relleno que
le dan FORMA a las graficas, para que las tarjetas se puedan leer y entender.

    python supabase/escenarios/poblacion.py        # reescribe dashboard.json

QUE ES Y QUE NO ES
------------------
Los 15 clientes CURADOS de `dashboard.json` cubren los 31 casos borde (sobrepago,
credito, cuarentena, cancelacion...) y NO se tocan: cada uno esta ahi por una
razon escrita en su `caso_que_cubre`.

Esto agrega 45 clientes de POBLACION. No cubren casos: cubren VOLUMEN y FORMA.
Sin ellos las barras de la tarjeta de mora tienen 3 pixeles y el ranking de
cobradores tiene una sola linea. Con ellos el dashboard se parece a Mairena.

LA FORMA QUE SE BUSCA (y por que)
---------------------------------
La curva de recuperacion REAL de Telecable Mairena, medida el 2026-08-27, cae
de 98% en marzo a 43% en agosto: los ciclos viejos estan casi cobrados y los
recientes no. Un escenario donde todos pagan igual no ensena nada; este replica
esa caida, que es lo que hace que la tarjeta de mora se entienda de un vistazo.

COMO SE CONSIGUE: no se "escribe" la curva. Se le da a cada cliente un PERFIL DE
PAGO (puntual, tardio, irregular, moroso desde tal ciclo) y la curva SALE de
sumar los 60. Si se escribiera el total a mano, el escenario no probaria nada:
seria una foto de si mismo.

INVARIANTES DE DINERO QUE ESTA POBLACION RESPETA (AGENTS.md)
------------------------------------------------------------
· #11 oldest-first: nadie paga una cuota dejando atras otra mas vieja impaga del
  mismo contrato. Los perfiles pagan por orden de vencimiento, siempre.
· #7  `monto_pagado` NO se escribe: lo calcula el trigger del server sumando los
  pagos vivos. Acá solo se declaran los pagos.
· #1  `monto_cordobas` = lo APLICADO. La poblacion paga exacto y en cordobas
  (moneda NIO, tasa 1, vuelto 0); los casos de USD, vuelto y sobrepago viven en
  los 15 curados, que es donde corresponde.
· 6b  Cancelar NO deja deuda: la cuota sin pago se anula y la que tiene pago
  queda 'pagada' con monto = lo pagado. Suspender SI conserva la deuda.
· #5  El colchon de cuotas futuras lo agrega el generador (INV17), no esto.

EL ANCLA DE TIEMPO
------------------
El escenario tiene fechas ABSOLUTAS, asi que depende de que dia sea "hoy". El
ancla vive en `HOY` acá abajo y se copia a `dashboard.json` como `ancla_hoy`.
Los tests la congelan (`hoyFijo`); la app usa la fecha real, asi que el
escenario se ve bien en pantalla cerca de esa fecha. Para re-anclarlo: cambiar
`HOY`, correr esto, y regenerar los dos seeds.
"""
import io
import json
import os
from datetime import date, timedelta

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JSON = os.path.join(RAIZ, 'supabase', 'escenarios', 'dashboard.json')

# ── EL ANCLA ────────────────────────────────────────────────────────────────
HOY = date(2026, 8, 27)

# ── CICLOS (ventana administrativa del dashboard: del 15 al 14) ─────────────
# El ciclo "septiembre" son los vencimientos del 15/ago al 14/sep. Es OTRA cosa
# que el ancla del `dia_pago` de la cuota (ARQUITECTURA 3.5): esta es la ventana
# de corte del Resumen, aquella decide que MES de servicio se le muestra.
CICLOS = [
    ('abr', date(2026, 3, 15), date(2026, 4, 15)),
    ('may', date(2026, 4, 15), date(2026, 5, 15)),
    ('jun', date(2026, 5, 15), date(2026, 6, 15)),
    ('jul', date(2026, 6, 15), date(2026, 7, 15)),
    ('ago', date(2026, 7, 15), date(2026, 8, 15)),
    ('sep', date(2026, 8, 15), date(2026, 9, 15)),   # EN CURSO (hoy 27/ago)
]

DIAS_GRACIA = 7

# ── LOS CUATRO GRUPOS DE COBRO ──────────────────────────────────────────────
# `null` = sin cobrador asignado ("admin-managed"): es un caso REAL y grande —
# en Telenet es el 100% de los clientes y en Mairena el 98,6%. Tiene que existir
# en el escenario o la tarjeta se prueba contra un mundo que no es el de nadie.
COBRADORES = [
    ('Cobrador Test',  15),
    ('Cobrador2 Test', 12),
    ('ACobranza',       9),   # la oficina: en Mairena es "Responsable de Cartera"
    (None,              9),
]

# ── COMUNIDADES ─────────────────────────────────────────────────────────────
# Nombres reales: las que existian en el tenant se llamaban "QA-SCROLL Barrio" y
# "TEST-R Barrio", que en el eje de una grafica no dicen nada.
COMUNIDADES = [
    ('El Calvario',   'Somotillo'),
    ('San Antonio',   'Somotillo'),
    ('Las Mercedes',  'Somotillo'),
    ('La Esperanza',  'Villanueva'),
    ('Los Robles',    'Villanueva'),
    ('El Tamarindo',  'Cinco Pinos'),
]

PRECIOS = [500, 600, 700, 800, 900]

# ── PERFILES DE PAGO ────────────────────────────────────────────────────────
# `demora` = dias despues del vencimiento en que paga. None = no paga.
# La MEZCLA es lo que produce la curva; los porcentajes de abajo se verifican al
# final y el script AVISA si la curva se aparta de la forma buscada.
PERFILES = {
    # nombre        demora   desde_que_ciclo_deja_de_pagar
    'puntual':      (2,      None),
    'gracia':       (6,      None),   # paga dentro de la gracia (7 dias)
    'tardio':       (16,     None),   # paga pasada la gracia -> mora recuperada
    'muy_tardio':   (38,     None),   # paga el ciclo siguiente -> "tail" de la curva
    'dejo_jun':     (9,      'jun'),
    'dejo_jul':     (9,      'jul'),
    'dejo_ago':     (4,      'ago'),
    'dejo_may':     (11,     'may'),
    'nunca':        (None,   'abr'),
}

# 🔴 NO existe un perfil "saltea un ciclo y sigue pagando", y no es un olvido.
# Lo intente y rompio INV21: el invariante #11 (oldest-first) prohibe cobrar una
# cuota dejando atras otra mas vieja impaga del mismo contrato, y la app lo
# enforza en `pagos_repo._validarOldestFirst`. Un escenario con esa forma
# describe algo que por la app NO se puede hacer.
# La variacion entre ciclos sale de otro lado: de que cada grupo deja de pagar
# en un ciclo distinto (dejo_may, dejo_jun, dejo_jul, dejo_ago) y de las altas
# escalonadas. Eso si respeta oldest-first: el que deja de pagar, deja de pagar
# de ahi en adelante.

# Altas ESCALONADAS: un ISP no nace con toda su cartera. Estos clientes entran
# en el ciclo indicado, asi que los ciclos viejos facturan menos que los nuevos
# y la linea de facturado CRECE, como en la vida real.
ALTAS = {i: c for i, c in [(2, 'may'), (9, 'may'), (17, 'jun'), (23, 'jun'),
                           (28, 'jul'), (35, 'jul'), (40, 'ago'), (43, 'ago')]}

# La mezcla, cliente por cliente. 45 entradas. Se eligio a mano (no al azar)
# para que la curva de recuperacion baje como la real y para que cada cobrador
# tenga una cartera de calidad distinta — si todos rinden igual, el ranking y la
# tarjeta de recuperacion no ensenan nada.
MEZCLA = (
    ['puntual'] * 10 +
    ['gracia'] * 6 +
    ['tardio'] * 8 +
    ['muy_tardio'] * 4 +
    ['dejo_may'] * 3 +
    ['dejo_jun'] * 4 +
    ['dejo_jul'] * 4 +
    ['dejo_ago'] * 3 +
    ['nunca'] * 3
)
assert len(MEZCLA) == 45, len(MEZCLA)

PRIMER_NUNCA = -1

NOMBRES = [
    'María Auxiliadora Pérez', 'Juan Carlos Mendoza', 'Rosa Amelia Castillo',
    'Pedro Antonio Rivera', 'Ana Julia Sandoval', 'Carlos Enrique Munguía',
    'Martha Lorena Vílchez', 'José Luis Aguilar', 'Silvia Elena Gutiérrez',
    'Francisco Javier Ortiz', 'Karla Vanessa Espinoza', 'Denis Alberto Zamora',
    'Yolanda del Carmen Ruiz', 'Marvin Antonio Salgado', 'Claudia Patricia Reyes',
    'Óscar Danilo Herrera', 'Reyna Isabel Flores', 'Wilfredo José Cruz',
    'Xiomara Elizabeth Toruño', 'Bayardo Ramón Gómez', 'Migdalia Esther Núñez',
    'Álvaro Ernesto Cerda', 'Fátima Raquel Obando','Douglas Iván Peralta',
    'Norma Cecilia Lanuza', 'Erick Josué Membreño', 'Perla María Bermúdez',
    'Gerardo Antonio Solís', 'Aracely del Socorro Vega', 'Mauricio Enrique Lira',
    'Blanca Rosa Ampié', 'Nelson Ariel Chavarría', 'Ivania Lucía Baltodano',
    'Hernaldo José Corea', 'Scarleth Massiel Duarte', 'Ronald Alexander Pavón',
    'Damaris Antonia Fonseca', 'Julio César Matamoros', 'Heydi Johana Quintero',
    'Rigoberto de Jesús Alaniz', 'Verónica Auxiliadora Ubau', 'Elmer Antonio Bravo',
    'Lucía Margarita Espinales', 'Freddy Ramón Calderón', 'Sonia María Guevara',
]
assert len(NOMBRES) == 45


def clamp_dia(anio, mes, dia):
    """El dia de pago clampeado al ultimo dia real del mes (31 en abril -> 30)."""
    d = date(anio, mes, 1)
    fin = (date(anio + (mes == 12), (mes % 12) + 1, 1) - timedelta(days=1)).day
    return d.replace(day=min(dia, fin))


def idx_de(nombre):
    return [c[0] for c in CICLOS].index(nombre)


def ciclo_de(venc):
    """En que ciclo del dashboard cae un vencimiento."""
    for nombre, ini, fin in CICLOS:
        if ini <= venc < fin:
            return nombre
    return None


def construir():
    # El primer 'nunca' que NO sea de alta reciente: ese se queda activo.
    global PRIMER_NUNCA
    PRIMER_NUNCA = next(i for i, pf in enumerate(MEZCLA)
                        if pf == 'nunca' and i not in ALTAS)
    clientes = []
    orden_cob = [c for c, n in COBRADORES for _ in range(n)]
    for i in range(45):
        perfil = MEZCLA[i]
        demora, deja = PERFILES[perfil]
        cob = orden_cob[i]
        com, mun = COMUNIDADES[i % len(COMUNIDADES)]
        dia_pago = [3, 5, 8, 10, 12, 14, 16, 18, 20, 22, 25, 28][i % 12]
        precio = PRECIOS[i % len(PRECIOS)]

        # Estado del contrato. 3 suspendidos y 2 cancelados repartidos entre los
        # que dejaron de pagar, que es como pasa en la vida real.
        estado, nota_estado = 'activo', ''
        # Solo ALGUNOS de los que nunca pagaron terminan cancelados. El otro
        # sigue activo y debiendo: sin el, los ciclos viejos dan 100% de
        # recuperacion, porque cancelar condona y su deuda desaparece de la
        # historia. Un dashboard donde el pasado siempre esta perfecto no
        # muestra el efecto mas importante de la regla de cancelacion.
        # De los que nunca pagaron, el PRIMERO queda activo y debiendo; los
        # demas terminaron cancelados. Tiene que ser uno que este desde el
        # principio (no de alta reciente), porque si no los ciclos viejos dan
        # 100% de recuperacion: cancelar condona, y la deuda del cancelado
        # desaparece de la historia.
        if perfil == 'nunca' and i != PRIMER_NUNCA:
            estado = 'cancelado (cancelado el 20 ago 2026)'
            nota_estado = ' Contrato CANCELADO: su deuda quedo condonada (regla 2026-08-24), solo sobrevive lo que ya habia pagado.'
        elif perfil in ('dejo_jun', 'dejo_jul') and i % 3 == 0:
            estado = 'suspendido (suspendido el 10 ago 2026)'
            nota_estado = ' Contrato SUSPENDIDO: conserva la deuda y cuenta como mora (regla 2026-08-26).'

        cuotas = []
        for nombre_ciclo, ini, fin in CICLOS:
            # La cuota de este cliente que cae en este ciclo.
            venc = None
            for mes_off in (0, 1):
                m = ini.month + mes_off
                a = ini.year + (m > 12)
                cand = clamp_dia(a, ((m - 1) % 12) + 1, dia_pago)
                if ini <= cand < fin:
                    venc = cand
                    break
            if venc is None:
                continue
            # Todavia no era cliente: no hay cuota.
            if i in ALTAS and idx_de(nombre_ciclo) < idx_de(ALTAS[i]):
                continue

            # ¿La paga?
            idx_ciclo = idx_de(nombre_ciclo)
            idx_deja = idx_de(deja) if deja else None
            paga = demora is not None and (idx_deja is None or idx_ciclo < idx_deja)
            fpago = venc + timedelta(days=demora) if paga else None
            # Un pago no puede ser del futuro.
            if fpago and fpago > HOY:
                paga, fpago = False, None

            q = {
                'vence': venc.isoformat(),
                'monto': precio,
                'cargos_neto': 0,
                'estado': 'pagada' if paga else 'pendiente',
                'pagos': ([{'fecha': fpago.isoformat(), 'monto': precio,
                            'nota': f'perfil {perfil} (+{demora}d)'}] if paga else []),
            }
            # Cancelado: la cuota SIN pago se anula (no queda deuda, invariante 6b).
            if estado.startswith('cancelado') and not paga:
                q['estado'] = 'anulada'
                q['pagos'] = []
            cuotas.append(q)

        clientes.append({
            'codigo': f'PB-{i + 1:02d}',
            'nombre': NOMBRES[i],
            'plan_precio': precio,
            'dia_pago': dia_pago,
            'estado_contrato': estado,
            'cobrador': cob,
            'comunidad': com,
            'municipio': mun,
            'cliente_activo': not (perfil == 'nunca' and i % 3 == 0),
            'caso_que_cubre': (
                f'POBLACION (no es un caso borde). Perfil de pago "{perfil}": '
                + ('paga siempre, ' + f'{demora} dias despues del vencimiento. '
                   if demora is not None else 'nunca pago. ')
                + (f'Deja de pagar a partir del ciclo {deja}. ' if deja else '')
                + f'Cobrador: {cob or "SIN ASIGNAR (admin-managed)"}. '
                + f'Comunidad: {com}.' + nota_estado),
            'cuotas': cuotas,
        })
    return clientes


def curva(clientes):
    """La curva de recuperacion que SALE de la poblacion, ciclo por ciclo.

    Se calcula por un camino INDEPENDIENTE del que la genera: se recorren las
    cuotas ya sembradas y se clasifican por ciclo, igual que hace la tarjeta.
    Si coincidiera por construccion no probaria nada.
    """
    out = []
    for nombre, ini, fin in CICLOS:
        fact = rec = 0
        for c in clientes:
            for q in c['cuotas']:
                v = date.fromisoformat(q['vence'])
                if not (ini <= v < fin) or q['estado'] == 'anulada':
                    continue
                fact += q['monto'] + q.get('cargos_neto', 0)
                rec += sum(p['monto'] for p in (q['pagos'] or []))
        out.append((nombre, fact, rec, round(100 * rec / fact, 1) if fact else 0))
    return out


def main():
    d = json.load(io.open(JSON, encoding='utf-8'))
    curados = [c for c in d['clientes'] if not c['codigo'].startswith('PB-')]
    nuevos = construir()

    d['ancla_hoy'] = HOY.isoformat()
    d['clientes'] = curados + nuevos
    io.open(JSON, 'w', encoding='utf-8').write(
        json.dumps(d, ensure_ascii=False, indent=1) + '\n')

    print(f'  curados que NO se tocaron : {len(curados)}')
    print(f'  poblacion generada        : {len(nuevos)}')
    print(f'  ancla                     : {HOY}')
    print()
    print('  La curva de recuperacion que produce la poblacion:')
    for nombre, fact, rec, pct in curva(nuevos):
        barra = '#' * int(pct / 4)
        print(f'    {nombre}  facturado C${fact:>7,}  recuperado C${rec:>7,}  {pct:>5.1f}%  {barra}')
    print()
    reparto = {}
    for c in nuevos:
        reparto[c['cobrador'] or '(sin cobrador)'] = reparto.get(c['cobrador'] or '(sin cobrador)', 0) + 1
    print('  Reparto por cobrador:', reparto)
    est = {}
    for c in nuevos:
        k = c['estado_contrato'].split(' ')[0]
        est[k] = est.get(k, 0) + 1
    print('  Estados de contrato  :', est)


if __name__ == '__main__':
    main()
