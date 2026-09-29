"""Genera el seed Dart del escenario del dashboard desde `dashboard.json`.

    python supabase/escenarios/generar_seed_dart.py

Salida: `test/features/admin/dashboard/escenario_seed.dart`.

Por qué un generador y no un .dart escrito a mano: el escenario son 93 cuotas y
86 pagos con fechas exactas. Mantenerlo a mano garantiza que en la tercera
edición un monto deje de coincidir con el valor esperado y el test empiece a
medir otra cosa.

Los estados se validan contra la lista permitida y el script FALLA si aparece
otro. El escenario venía con 'suspendido (suspendido el 5 ago 2026)' — texto
descriptivo, no un estado — y escribirlo literal hacía que `ct.estado =
'suspendido'` no matcheara: el test pasaba en verde midiendo cero filas.
"""
import io
import json
import os
import re
import sys
import unicodedata

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ORIGEN = os.path.join(RAIZ, 'supabase', 'escenarios', 'dashboard.json')
DESTINO = os.path.join(RAIZ, 'test', 'features', 'admin', 'dashboard',
                       'escenario_seed.dart')

ESTADOS_CONTRATO = {'activo', 'suspendido', 'cancelado', 'completado'}
ESTADOS_CUOTA = {'pendiente', 'parcial', 'pagada', 'anulada'}

CABECERA = """// GENERADO — no editar a mano.
// Fuente: supabase/escenarios/dashboard.json
// Regenerar: python supabase/escenarios/generar_seed_dart.py
//
// Escenario de 15 clientes repartidos en 6 ciclos (mar-ago 2026), disenado para
// que cada caso de borde de la aritmetica del Resumen tenga un cliente que lo
// dispare. Los valores esperados de cada fila viven en el test que lo usa.
//
// `monto_pagado` se calcula aca con el MISMO predicado que el trigger del
// server (pago vivo = no anulado y no en revision), porque el SQLite local no
// tiene triggers: si se calculara distinto, el test mediria otra cosa.
library;

import 'package:powersync/powersync.dart';

const tenantEscenario = 't-escenario';

/// El cobrador que registro TODOS los pagos. Existe porque el arqueo arranca
/// FROM cobradores: sin la fila, su consulta devuelve cero aunque los pagos
/// esten. Es el mismo id que usa el seed de Postgres.
const cobradorEscenario = '79c45dce-d5a6-4568-9835-dcb89d9909db';

/// Los otros dos. El escenario reparte la cartera entre tres, y el arqueo
/// arranca FROM cobradores: sin sus filas, sus columnas dan cero.
const cobrador2Escenario = 'f2d45b71-4638-439c-a907-25c90e63fa18';
const oficinaEscenario = '16b7cf1a-8b99-431e-9785-6b91b048c0c9';

Future<void> sembrarEscenario(PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {"""


def normalizar(valor, permitidos, quien):
    """'suspendido (suspendido el 5 ago 2026)' -> 'suspendido', validando."""
    crudo = (valor or 'activo').strip()
    token = crudo.split()[0].strip('(),')
    if token not in permitidos:
        sys.exit(f'ERROR: estado {crudo!r} de {quien} no es ninguno de '
                 f'{sorted(permitidos)}')
    return token


def dq(s):
    return "'" + str(s).replace('\\', '\\\\').replace("'", "\\'") + "'"


def slug(nombre):
    """Id estable a partir del nombre de la comunidad.

    No hace falta que coincida con el uuid del seed de Postgres: el SQLite del
    test es una base aparte. Lo que SI tiene que coincidir entre los dos
    generadores es que las comunidades EXISTAN, que es lo que faltaba aca.
    """
    t = unicodedata.normalize('NFD', str(nombre))
    t = ''.join(ch for ch in t if unicodedata.category(ch) != 'Mn')
    return re.sub(r'[^a-z0-9]+', '-', t.lower()).strip('-')


# Planes del escenario. Los ids son fijos para que el seed sea reproducible.
# Espejan la forma de produccion: tres tipos, y dos planes que COMPARTEN nombre
# con distinto precio.
PLANES_ESCENARIO = [
    ('e1000000-0000-4000-8000-000000000001', 'CATV', 'tv', 500),
    ('e1000000-0000-4000-8000-000000000002', 'CATV', 'tv', 700),
    ('e1000000-0000-4000-8000-000000000003', 'Internet 20MB', 'internet', 600),
    ('e1000000-0000-4000-8000-000000000004', 'Combo 20M+Catv', 'combo', 900),
]


def main():
    esc = json.load(io.open(ORIGEN, encoding='utf-8'))
    cli_ids, n_ctr, n_cuo, n_pag, n_rec = {}, 0, 0, 0, 0
    comunidades = {}
    # El arqueo arranca FROM cobradores: sin esta fila su consulta devuelve
    # cero aunque los pagos existan, y la comparacion contra la caja del
    # dashboard pasaria en verde midiendo la nada.
    lineas = [
        "    await tx.execute('INSERT INTO cobradores (id, tenant_id, nombre, "
        "rol, activo) VALUES (?, ?, ?, ?, 1)', "
        "[cobradorEscenario, tenantEscenario, 'Cobrador Test', 'cobrador']);",
        "    await tx.execute('INSERT INTO cobradores (id, tenant_id, nombre, "
        "rol) VALUES (?, ?, ?, ?)', "
        "[cobrador2Escenario, tenantEscenario, 'Cobrador2 Test', 'cobrador']);",
        "    await tx.execute('INSERT INTO cobradores (id, tenant_id, nombre, "
        "rol) VALUES (?, ?, ?, ?)', "
        "[oficinaEscenario, tenantEscenario, 'ACobranza', 'admin_cobranza']);"]

    # PLANES. Sin esta tabla el chip "Plan" de Clientes/Cobros/Mapa sale VACIO
    # y cualquier test suyo pasa en verde midiendo la nada — la regla 16 del
    # AGENTS, literal. En produccion el 100% de los contratos tiene plan.
    #
    # Los tres TIPOS estan representados a proposito (tv / internet / combo):
    # el filtro AGRUPA por ese campo, asi que con un solo tipo no se probaria
    # la agrupacion. Y hay DOS planes con el mismo nombre y distinto precio,
    # que es el caso real de Mairena (siete planes se llaman "CATV") y lo que
    # obliga a que el subtitulo lleve el precio.
    for pid, nombre, tipo, precio in PLANES_ESCENARIO:
        lineas.append(
            "    await tx.execute('INSERT INTO planes (id, tenant_id, nombre, "
            "tipo, precio_mensual, activo) VALUES (?, ?, ?, ?, ?, 1)', "
            f"[{dq(pid)}, tenantEscenario, {dq(nombre)}, {dq(tipo)}, {precio}]);")

    for c in esc['clientes']:
        cod = c['codigo']
        # Se salta SOLO el pseudo-cliente de setup. El filtro decia
        # `not cod.startswith('TT-')` y descartaba en silencio los 45 clientes
        # de poblacion (prefijo PB-), dejando este seed en 14 clientes mientras
        # el de Postgres tenia 59. Es LA divergencia contra la que advierte el
        # mapa de impacto ("los dos seeds ya divergieron 3 veces"): no falla,
        # simplemente siembra otra cosa, y a partir de ahi los tests prueban un
        # mundo que no es el que se ve en la app.
        if cod == 'SETUP':
            continue  # la fila SETUP no es un cliente
        # TT-05-A y TT-05-B son el MISMO cliente con dos contratos.
        base = cod[:5] if cod.startswith('TT-05') else cod
        if base not in cli_ids:
            cli_ids[base] = 'cli-' + base.lower()
            # `comunidad_id` NO estaba y el seed de Postgres SI la siembra:
            # los dos generadores habian divergido y nadie lo notaba porque
            # ningun test miraba el eje "por comunidad". Sin esto, la tarjeta
            # de Recuperacion agrupa TODO en un solo "Sin comunidad" y
            # cualquier test sobre sus tres niveles pasa sin probar nada
            # (leccion 16 de AGENTS).
            com = c.get('comunidad')
            com_id = 'com-' + slug(com) if com else None
            if com and com_id not in comunidades:
                comunidades[com_id] = com
            lineas.append(
                "    await tx.execute('INSERT INTO clientes (id, tenant_id, "
                "codigo, nombre, activo, comunidad_id) "
                "VALUES (?, ?, ?, ?, 1, ?)', "
                f"[{dq(cli_ids[base])}, tenantEscenario, {dq(base)}, "
                f"{dq(c['nombre'])}, {dq(com_id) if com_id else 'null'}]);")
        cid, ctr = cli_ids[base], 'ctr-' + cod.lower()
        estado_ctr = normalizar(c.get('estado_contrato'), ESTADOS_CONTRATO, cod)
        n_ctr += 1
        # Codigo correlativo, igual que el seed de Postgres. En produccion el
        # 100% de los contratos lo tiene; sin el, la columna 'Contrato' del
        # export salia vacia y el test no lo notaba.
        codigo_ctr = str(4000 + n_ctr)
        lineas.append(
            "    await tx.execute('INSERT INTO contratos (id, tenant_id, "
            "cliente_id, codigo, estado, dia_pago, plan_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)', "
            f"[{dq(ctr)}, tenantEscenario, {dq(cid)}, {dq(codigo_ctr)}, "
            f"{dq(estado_ctr)}, {c.get('dia_pago', 15)}, "
            # Reparte los 4 planes de forma estable (no aleatoria: el seed
            # tiene que dar igual en cada corrida).
            f"{dq(PLANES_ESCENARIO[n_ctr % len(PLANES_ESCENARIO)][0])}]);")

        # Que cuota es COBRO PUNTUAL: la misma regla que el seed de Postgres
        # (generar_seed_sql.py). Si los dos seeds no coincidieran, el test
        # mediria un escenario que no es el que se ve en la app — que es
        # exactamente lo que paso: aca TODAS colgaban de un contrato y el
        # detalle exportable no tenia ningun cobro puntual que contar.
        dia_pago = c.get('dia_pago', 15)
        por_mes = {}
        for k, q in enumerate(c.get('cuotas', [])):
            por_mes.setdefault(q['vence'][:7], []).append((k, q))
        puntuales = set()
        for _mes, grupo in por_mes.items():
            if len(grupo) < 2:
                continue
            for k, q in grupo:
                if int(q['vence'][8:10]) != dia_pago:
                    puntuales.add(k)
            if not any(k in puntuales for k, _ in grupo):
                puntuales.add(grupo[1][0])

        for k, q in enumerate(c.get('cuotas', [])):
            qid = f'cuo-{cod.lower()}-{k}'
            pagos = q.get('pagos') or []
            vivos = [p for p in pagos
                     if not p.get('anulado') and not p.get('en_revision')]
            pagado = round(sum(p['monto'] for p in vivos), 2)
            estado_cuo = normalizar(q.get('estado'), ESTADOS_CUOTA, qid)
            lineas.append(
                "    await tx.execute('INSERT INTO cuotas (id, tenant_id, "
                "cliente_id, contrato_id, fecha_vencimiento, monto, "
                "cargos_neto, monto_pagado, estado) VALUES "
                "(?, ?, ?, ?, ?, ?, ?, ?, ?)', "
                f"[{dq(qid)}, tenantEscenario, {dq(cid)}, "
                f"{'null' if k in puntuales else dq(ctr)}, "
                f"{dq(q['vence'])}, {q['monto']}, {q.get('cargos_neto', 0)}, "
                f"{pagado}, {dq(estado_cuo)}]);")
            n_cuo += 1
            for j, p in enumerate(pagos):
                lineas.append(
                    # `fecha_cobro` (0273): el DIA del cobro. En produccion la
                    # llena un trigger Y la escribe el cliente al insertar;
                    # aca hay que sembrarla o TODO el dashboard da cero,
                    # porque desde el 2026-09-04 filtra el ciclo por esta
                    # columna en vez de por `date(fecha_pago)`. Es la regla 16:
                    # un escenario que no siembra lo que produccion tiene no
                    # prueba lo que creemos.
                    "    await tx.execute('INSERT INTO pagos (id, tenant_id, "
                    "cuota_id, cobrador_id, monto_cordobas, monto_original, "
                    "moneda, metodo, fecha_pago, fecha_cobro, anulado, "
                    "en_revision) VALUES "
                    "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', "
                    f"[{dq(f'pag-{cod.lower()}-{k}-{j}')}, tenantEscenario, "
                    f"{dq(qid)}, cobradorEscenario, {p['monto']}, "
                    f"{p['monto']}, 'NIO', 'efectivo', {dq(p['fecha'])}, "
                    f"{dq(p['fecha'][:10])}, "
                    f"{1 if p.get('anulado') else 0}, "
                    f"{1 if p.get('en_revision') else 0}]);")
                n_pag += 1
                # UN RECIBO POR PAGO VIVO. En produccion los 32.609 pagos
                # vivos tienen uno (medido 2026-09-01), asi que un escenario
                # sin recibos no representa a ningun tenant real — y la
                # columna "Recibo" del Excel salia vacia en los tests aunque
                # el codigo estuviera bien.
                #
                # Los ANULADOS y los EN REVISION no llevan: el recibo es el
                # comprobante de un cobro que vale.
                if not p.get('anulado') and not p.get('en_revision'):
                    n_rec += 1
                    lineas.append(
                        "    await tx.execute('INSERT INTO recibos (id, "
                        "tenant_id, pago_id, cobrador_id, prefijo, "
                        "correlativo, numero_completo, anulado) VALUES "
                        "(?, ?, ?, ?, ?, ?, ?, ?)', "
                        f"[{dq(f'rec-{cod.lower()}-{k}-{j}')}, "
                        f"tenantEscenario, {dq(f'pag-{cod.lower()}-{k}-{j}')}, "
                        f"cobradorEscenario, 'ESC', {n_rec}, "
                        f"{dq(f'ESC-{n_rec:05d}')}, 0]);")

    # Las comunidades van ARRIBA de los clientes: se descubren recorriendolos,
    # asi que se anteponen al escribir. En SQLite no hay FK que lo exija, pero
    # un seed que inserta el hijo antes que el padre se lee como un error.
    cabeza = []
    if comunidades:
        cabeza.append('    // Las comunidades del escenario. El eje "por '
                      'comunidad" de la')
        cabeza.append('    // tarjeta de Recuperacion NO se puede probar sin '
                      'esto: sin ellas la')
        cabeza.append('    // consulta agrupa todo en un solo "Sin comunidad" '
                      'y cualquier test')
        cabeza.append('    // sobre sus tres niveles pasa sin medir nada.')
        for cid_ in sorted(comunidades):
            cabeza.append(
                "    await tx.execute('INSERT INTO comunidades (id, "
                "tenant_id, nombre) VALUES (?, ?, ?)', "
                f"[{dq(cid_)}, tenantEscenario, {dq(comunidades[cid_])}]);")
        cabeza.append('')

    io.open(DESTINO, 'w', encoding='utf-8').write(
        CABECERA + '\n' + '\n'.join(cabeza + lineas) + '\n  });\n}\n')
    print(f'clientes={len(cli_ids)} comunidades={len(comunidades)} '
          f'contratos={n_ctr} cuotas={n_cuo} '
          f'pagos={n_pag} recibos={n_rec}  ->  '
          f'{os.path.relpath(DESTINO, RAIZ)}')


if __name__ == '__main__':
    main()
