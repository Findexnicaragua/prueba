"""Genera el seed SQL del escenario del dashboard para el tenant de PRUEBA.

    python supabase/escenarios/generar_seed_sql.py
    supabase db query --linked -f supabase/escenarios/dashboard_seed.sql

Hermano de `generar_seed_dart.py`: los dos leen `dashboard.json`, uno siembra
Postgres (para ver el escenario en la app) y el otro SQLite (para el test).

Los ids salen de md5 del código del cliente, NO de `hash()`: el hash de Python
está aleatorizado por proceso, así que dos corridas generaban ids distintos y
re-sembrar dejaba huérfanos.

Cuando un contrato tiene dos cuotas en el mismo mes calendario, UNA de las dos
es un COBRO PUNTUAL — `contrato_id` NULL y `periodo` = el día exacto —, que es
como los crea la app (`cuotas_repo.registrarCobroPuntual`). Sin eso choca contra
el índice único `(contrato_id, periodo)`.

CUÁL de las dos: la que NO vence el `dia_pago` del contrato. La mensualidad
siempre cae ese día; el cargo manual cae el día en que se creó. Antes se elegía
"la segunda en orden de fecha", y eso salió al revés: a Marvin (TT-13, día 12)
le desprendió del contrato la MENSUALIDAD del 12 de agosto y dejó pegado el
cargo de C$1.500 del día 5. En la app se veía el cargo dentro del contrato y la
mensualidad flotando sin contrato — exactamente lo contrario de la realidad.
"""
import hashlib
import io
import json
import os

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ORIGEN = os.path.join(RAIZ, 'supabase', 'escenarios', 'dashboard.json')
DESTINO = os.path.join(RAIZ, 'supabase', 'escenarios', 'dashboard_seed.sql')

TENANT = '8583a8f0-191d-4750-a07d-923c01a45300'  # Test Tenant
COBRADOR = '79c45dce-d5a6-4568-9835-dcb89d9909db'  # Cobrador Test (por defecto)

# Los cobradores REALES del tenant. No se pueden crear por SQL: `cobradores.id`
# tiene FK contra `auth.users`, o sea que un cobrador ES una cuenta que inicia
# sesion. Estos tres ya existen; para tener mas hay que crear cuentas.
COBRADORES_ID = {
    'Cobrador Test':  '79c45dce-d5a6-4568-9835-dcb89d9909db',
    'Cobrador2 Test': 'f2d45b71-4638-439c-a907-25c90e63fa18',
    'ACobranza':      '16b7cf1a-8b99-431e-9785-6b91b048c0c9',
}
# La OFICINA: quien cobra a los clientes que no tienen cobrador asignado.
# `pagos.cobrador_id` es NOT NULL y significa QUIEN COBRO — nunca queda vacio,
# aunque el cliente sea admin-managed (ARQUITECTURA 3.5-4b). Es la forma real de
# Mairena: la oficina recauda la cartera sin asignar.
OFICINA = COBRADORES_ID['ACobranza']


def cob_asignado(c):
    """El cobrador ASIGNADO al cliente (organizativo).

    La distincion importa y es sutil:
      · el campo AUSENTE  -> Cobrador Test. Son los 14 curados, que se escribieron
        antes de que el escenario tuviera cobradores; dejarlos sin asignar los
        metia a todos en el grupo "(sin cobrador)" y desfiguraba las graficas.
      · el campo en NULL  -> sin asignar DE VERDAD (admin-managed). Es un caso
        real y buscado: en Telenet es el 100% de la cartera.
    """
    if 'cobrador' not in c:
        # Repartidos de forma estable entre los tres. Mandarlos a todos al mismo
        # dejaba el ranking en 29/12/9/9: una barra del doble que la siguiente
        # solo porque los curados se escribieron antes que los cobradores.
        tres = list(COBRADORES_ID.values())
        # Se hashea el codigo BASE, no el del contrato: TT-05a y TT-05b son dos
        # contratos del MISMO cliente y con el codigo completo les tocaban
        # cobradores distintos -> INV8 (contrato.cobrador_id != cliente.cobrador_id).
        base_cod = c['codigo'][:5] if c['codigo'].startswith('TT-05') else c['codigo']
        h = int(hashlib.md5(('cob' + base_cod).encode()).hexdigest(), 16)
        return tres[h % 3]
    n = c.get('cobrador')
    return COBRADORES_ID.get(n) if n else None


def comunidad_de(c):
    """La comunidad del cliente. Los curados no la declaran, asi que se les
    reparte una de forma estable (por el codigo) — si no, 14 de 59 clientes
    caerian en '(sin comunidad)' y el eje de la tarjeta quedaria dominado por
    un grupo que no significa nada."""
    if c.get('comunidad'):
        return uid('e', c['comunidad'])
    fijas = ['El Calvario', 'San Antonio', 'Las Mercedes',
             'La Esperanza', 'Los Robles', 'El Tamarindo']
    h = int(hashlib.md5(c['codigo'].encode()).hexdigest(), 16)
    return uid('e', fijas[h % len(fijas)])


def cob_cobro(c):
    """Quien COBRA: el asignado, o la oficina si no tiene. Nunca None."""
    return cob_asignado(c) or OFICINA
DIAS_GRACIA = 7

# Planes existentes del tenant, por precio. Se elige el más cercano al del
# escenario: el monto real de cada cuota va en la cuota, no en el plan.
PLANES = [
    (500, 'b90347aa-caa1-45a8-ac80-d1b6790a6a2b'),
    (600, 'c0fb615a-3021-4105-8f3a-439e0f22f494'),
    (700, '73d65f8b-7b86-40ad-83ae-e80774bd2e98'),
    (800, '66304b98-4f33-49cb-a480-463b1d257d17'),
    (900, '2e00d46c-eca0-4faf-a662-2b8e8dd9205c'),
]

# Orden seguro de borrado: hijos antes que padres.
BORRAR = ['recibos', 'saldos_favor', 'cargos_extra', 'notificaciones_mora',
          'pagos', 'visitas', 'cliente_etiquetas', 'fotos_cliente',
          'contrato_suspensiones', 'cuotas', 'contratos', 'clientes']


def sql_id(v):
    """UUID entre comillas, o NULL. El NULL de cobrador_id es un caso REAL
    ('admin-managed'), no un dato faltante: hay que poder sembrarlo."""
    return f"'{v}'" if v else 'NULL'


def uid(prefijo, semilla):
    """UUID v4-ish estable, derivado de la semilla. Reproducible entre corridas.

    🔴 El prefijo tiene que ser un DIGITO HEXADECIMAL (0-9, a-f). Se usaron 'm'
    y 'n' para comunidad y municipio y Postgres los rechazo con 22P02 — el
    error no dice "prefijo invalido", dice "invalid input syntax for type uuid",
    asi que cuesta verlo. Ocupados: a=cliente b=contrato c=cuota d=pago
    e=comunidad f=municipio.
    """
    assert prefijo in '0123456789abcdef', f'prefijo no hexadecimal: {prefijo}'
    h = hashlib.md5(semilla.encode()).hexdigest()
    return f'{prefijo}0000000-0000-4000-8000-{h[:12]}'


MESES = {'ene': 1, 'feb': 2, 'mar': 3, 'abr': 4, 'may': 5, 'jun': 6,
         'jul': 7, 'ago': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dic': 12}


def fecha_baja(c):
    """La fecha de baja, leida del rotulo del escenario
    ('cancelado (cancelado el 20 ago 2026)'). Si no trae fecha, hoy."""
    import re as _re
    m = _re.search(r'el (\d{1,2}) (\w{3})\w* (\d{4})',
                   c.get('estado_contrato') or '')
    if not m:
        return '2026-08-20'
    d, mes, a = m.group(1), m.group(2)[:3].lower(), m.group(3)
    return f'{a}-{MESES.get(mes, 8):02d}-{int(d):02d}'


def plan_de(precio):
    return min(PLANES, key=lambda x: abs(x[0] - precio))[1]


def q(valor):
    return "'" + str(valor).replace("'", "''") + "'"


def main():
    esc = json.load(io.open(ORIGEN, encoding='utf-8'))
    L = [
        '-- Escenario del dashboard en el tenant de PRUEBA. GENERADO.',
        '--   python supabase/escenarios/generar_seed_sql.py',
        '--',
        '-- 15 clientes en 6 ciclos (mar-ago 2026). Cada uno dispara un caso de',
        '-- borde de la aritmetica del Resumen. Los valores esperados de cada',
        '-- fila estan en test/features/admin/dashboard/dashboard_numeros_test',
        '-- .dart, que corre las MISMAS consultas contra SQLite.',
        '--',
        '-- BORRA la data operativa del tenant. No correr con otro tenant_id.',
        'BEGIN;',
        '',
    ]
    for t in BORRAR:
        L.append(f"DELETE FROM public.{t} WHERE tenant_id = '{TENANT}';")
    L += ['',
          f"UPDATE public.settings SET valor = '{DIAS_GRACIA}'::jsonb",
          f" WHERE tenant_id = '{TENANT}' AND clave = 'cobranza.dias_gracia';",
          '',
          '-- El escenario aplica cargos y descuentos: el guard de 0115 los',
          '-- rechaza si el tenant no los tiene habilitados.',
          "UPDATE public.settings SET valor = 'true'::jsonb",
          f" WHERE tenant_id = '{TENANT}'",
          "   AND clave = 'cobranza.ajustes_habilitados';",
          '']

    # ── Municipios y comunidades del escenario ──────────────────────────────
    # El eje "por comunidad" de la tarjeta de Recuperacion no se puede probar
    # sin esto. Las que habia en el tenant se llamaban "QA-SCROLL Barrio" y
    # "TEST-R Barrio": en el eje de una grafica no dicen nada, asi que el
    # escenario trae las suyas con nombres reales.
    # Se hace con ON CONFLICT DO NOTHING y NO se borran: hay clientes viejos
    # del tenant colgando de las de QA, y borrarlas los dejaria huerfanos.
    munis, comus = {}, {}
    for c in esc['clientes']:
        if not c.get('comunidad'):
            continue
        mun = c.get('municipio') or 'Somotillo'
        munis[mun] = uid('f', mun)
        comus[c['comunidad']] = (uid('e', c['comunidad']), mun)
    if comus:
        L.append('-- Municipios y comunidades con nombres reales, para que el')
        L.append('-- eje de la tarjeta de Recuperacion se pueda leer.')
        # `municipios.departamento_id` es NOT NULL. Los tres municipios del
        # escenario (Somotillo, Villanueva, Cinco Pinos) son de CHINANDEGA en
        # la geografia real de Nicaragua, y ese departamento ya existe en el
        # tenant — asi que se reusa por NOMBRE y solo se crea si falta.
        L.append('INSERT INTO public.departamentos (id, tenant_id, nombre)')
        L.append(f"SELECT '{uid('f', 'depto-CHINANDEGA')}', '{TENANT}', "
                 "'CHINANDEGA'")
        L.append(' WHERE NOT EXISTS (SELECT 1 FROM public.departamentos'
                 f" WHERE tenant_id = '{TENANT}' AND nombre = 'CHINANDEGA');")
        depto = ("(SELECT id FROM public.departamentos"
                 f" WHERE tenant_id = '{TENANT}' AND nombre = 'CHINANDEGA'"
                 " ORDER BY created_at LIMIT 1)")
        for nom, mid in sorted(munis.items()):
            L.append('INSERT INTO public.municipios '
                     '(id, tenant_id, nombre, departamento_id) '
                     f"SELECT '{mid}', '{TENANT}', {q(nom)}, {depto} "
                     'WHERE NOT EXISTS (SELECT 1 FROM public.municipios '
                     f"WHERE id = '{mid}');")
        for nom, (cid_, mun) in sorted(comus.items()):
            L.append('INSERT INTO public.comunidades '
                     '(id, tenant_id, nombre, municipio_id) '
                     f"SELECT '{cid_}', '{TENANT}', {q(nom)}, "
                     f"'{munis[mun]}' WHERE NOT EXISTS (SELECT 1 FROM "
                     f"public.comunidades WHERE id = '{cid_}');")
        L.append('')

    clientes = {}
    n_ctr = n_cuo = n_pag = n_puntual = n_rec = 0
    # Se emiten en tres tandas: primero clientes y contratos, después las
    # cuotas y al final los pagos. Motivo: insertar un contrato dispara el
    # trigger del server que GENERA las cuotas solo (como en la vida real), y
    # esas autogeneradas chocan contra las del escenario por el índice único
    # (contrato_id, periodo). Entre tanda y tanda se borran.
    cuotas_sql, pagos_sql, recibos_sql = [], [], []
    # Cuotas cuyo cargo NO es un descuento generico: declaran su tipo y su
    # fecha en el JSON (hoy, el credito a favor aplicado de TT-07).
    cargos_especiales = []

    for c in esc['clientes']:
        cod = c['codigo']
        # Se salta SOLO el pseudo-cliente de setup. Antes decia
        # `not cod.startswith('TT-')`, y eso descartaba en silencio a los 45
        # clientes de poblacion (prefijo PB-): el seed salia con 14 clientes y
        # nadie se enteraba, porque no falla — simplemente no siembra.
        if cod == 'SETUP':
            continue
        base = cod[:5] if cod.startswith('TT-05') else cod
        if base not in clientes:
            clientes[base] = uid('a', base)
            L.append(
                'INSERT INTO public.clientes '
                '(id, tenant_id, codigo, nombre, cobrador_id, comunidad_id, '
                'activo) VALUES '
                f"('{clientes[base]}', '{TENANT}', {q(base)}, "
                f"{q(c['nombre'])}, {sql_id(cob_asignado(c))}, "
                f"{sql_id(comunidad_de(c))}, "
                f"{str(c.get('cliente_activo', True)).lower()});")
        cid = clientes[base]
        ctr = uid('b', cod)
        estado = (c.get('estado_contrato') or 'activo').split()[0]
        # Codigo correlativo como en produccion (Mairena y Telenet lo tienen en
        # el 100% de sus contratos). Sin el, la columna 'Contrato' del export
        # sale vacia y el escenario deja de representar lo real.
        n_ctr += 1
        codigo_ctr = f'{4000 + n_ctr}'
        # Un contrato que NACE cancelado tiene que traer quien lo dio de baja y
        # por que: lo exige el guard de 0254 (`contratos_guard_cancelacion_
        # atribuida`), que aplica tambien al INSERT — no solo al UPDATE. La
        # fecha sale del rotulo del escenario ("cancelado el 20 ago 2026").
        baja_cols, baja_vals = '', ''
        if estado == 'cancelado':
            baja_cols = ', cancelado_en, cancelado_por, motivo_cancelacion'
            baja_vals = (f", TIMESTAMP '{fecha_baja(c)} 12:00:00', "
                         f"'{cob_cobro(c)}', 'Baja del escenario de prueba'")
        L.append(
            'INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id,'
            ' codigo, dia_pago, fecha_inicio, estado, cobrador_id'
            f'{baja_cols}) VALUES '
            f"('{ctr}', '{TENANT}', '{cid}', '{plan_de(c['plan_precio'])}', "
            f"'{codigo_ctr}', "
            f"{c.get('dia_pago', 15)}, DATE '2026-02-01', {q(estado)}, "
            f"{sql_id(cob_asignado(c))}{baja_vals});")

        # Que cuota es COBRO PUNTUAL se decide ANTES de emitir, mirando el mes
        # entero: si dos caen en el mismo mes calendario, la puntual es la que
        # NO vence el dia_pago del contrato (la mensualidad siempre cae ese
        # dia; el cargo manual cae el dia en que se creo).
        dia_pago = c.get('dia_pago', 15)
        por_mes = {}
        for k, cu in enumerate(c.get('cuotas', [])):
            por_mes.setdefault(cu['vence'][:7], []).append((k, cu))
        puntuales = set()
        for _mes, grupo in por_mes.items():
            if len(grupo) < 2:
                continue
            for k, cu in grupo:
                if int(cu['vence'][8:10]) != dia_pago:
                    puntuales.add(k)
            # Si ninguna difiere del dia_pago (no deberia pasar), la segunda.
            if not any(k in puntuales for k, _ in grupo):
                puntuales.add(grupo[1][0])

        for k, cu in enumerate(c.get('cuotas', [])):
            qid = uid('c', f'{cod}-{k}')
            # Cuotas que declaran su cargo EXPLICITO en el JSON. Sin esto el
            # generador tipaba TODO cargos_neto negativo como
            # 'descuento_monto' y con la fecha en que corrio el seed: un
            # credito a favor aplicado quedaba indistinguible de un descuento
            # del admin, y su fecha caia en el ciclo equivocado. El escenario
            # de TT-07 dice cubrir la regla del credito por excedente y asi no
            # la probaba.
            if cu.get('cargo_tipo'):
                cargos_especiales.append((qid, cid, ctr, cu))
            vence = cu['vence']
            periodo = vence[:8] + '01'
            # Una cuota anulada exige la terna completa
            # (CHECK cuotas_anulacion_coherencia): sin motivo no entra.
            estado_cuo = cu.get('estado', 'pendiente')
            anul = (', anulada_en, anulada_por, motivo_anulacion'
                    if estado_cuo == 'anulada' else '')
            anul_val = (f", TIMESTAMP '{vence} 00:00:00', '{cob_cobro(c)}', "
                        "'Anulada por el escenario de prueba'"
                        if estado_cuo == 'anulada' else '')
            puntual = k in puntuales
            if puntual:
                n_puntual += 1
                cuotas_sql.append(
                    'INSERT INTO public.cuotas (id, tenant_id, cliente_id, '
                    'contrato_id, periodo, fecha_vencimiento, monto, '
                    'cargos_neto, estado, cobrador_id, tipo_cargo_manual, '
                    f'descripcion{anul}) VALUES '
                    f"('{qid}', '{TENANT}', '{cid}', NULL, DATE {q(vence)}, "
                    f"DATE {q(vence)}, {cu['monto']}, "
                    f"{cu.get('cargos_neto', 0)}, {q(estado_cuo)}, "
                    f"{sql_id(cob_asignado(c))}, 'otro', "
                    f"'Cobro puntual del escenario'{anul_val});")
            else:
                cuotas_sql.append(
                    'INSERT INTO public.cuotas (id, tenant_id, cliente_id, '
                    'contrato_id, periodo, fecha_vencimiento, monto, '
                    f'cargos_neto, estado, cobrador_id{anul}) VALUES '
                    f"('{qid}', '{TENANT}', '{cid}', '{ctr}', "
                    f"DATE {q(periodo)}, DATE {q(vence)}, {cu['monto']}, "
                    f"{cu.get('cargos_neto', 0)}, "
                    f"{q(estado_cuo)}, {sql_id(cob_asignado(c))}"
                    f"{anul_val});")
            n_cuo += 1

            for j, p in enumerate(cu.get('pagos') or []):
                pid = uid('d', f'{cod}-{k}-{j}')
                # Un pago anulado exige la terna completa, igual que la cuota
                # (CHECK pagos_anulacion_coherencia).
                es_anul = bool(p.get('anulado'))
                cols = (', anulado_en, anulado_por, motivo_anulacion'
                        if es_anul else '')
                vals = (f", TIMESTAMP '{p['fecha']} 12:00:00', '{cob_cobro(c)}', "
                        "'Anulado por el escenario de prueba'"
                        if es_anul else '')
                rev = bool(p.get('en_revision'))
                cols += ', revision_motivo' if rev else ''
                vals += ", 'Cuarentena del escenario de prueba'" if rev else ''
                pagos_sql.append(
                    'INSERT INTO public.pagos (id, tenant_id, cuota_id, '
                    'cobrador_id, monto_cordobas, monto_original, moneda, '
                    'tasa_conversion, metodo, fecha_pago, vuelto_cordobas, '
                    f'anulado, en_revision{cols}) VALUES '
                    f"('{pid}', '{TENANT}', '{qid}', '{cob_cobro(c)}', "
                    f"{p['monto']}, {p['monto']}, 'NIO', 1, 'efectivo', "
                    f"TIMESTAMP {q(p['fecha'] + ' 10:00:00')}, 0, "
                    f"{str(es_anul).lower()}, {str(rev).lower()}{vals});")
                n_pag += 1
                # UN RECIBO POR PAGO VIVO — igual que en el generador Dart, y
                # por el mismo motivo: en produccion los 32.609 pagos vivos
                # tienen uno (medido 2026-09-01), asi que un escenario sin
                # recibos no representa a ningun tenant real. Los anulados y
                # los en revision no llevan: el recibo comprueba un cobro que
                # vale.
                #
                # Los DOS generadores tienen que emitirlos o vuelven a
                # divergir, que ya paso tres veces (AGENTS, capa 7).
                if not es_anul and not rev:
                    n_rec += 1
                    recibos_sql.append(
                        'INSERT INTO public.recibos (id, tenant_id, pago_id, '
                        'cobrador_id, prefijo, correlativo, numero_completo, '
                        'anulado) VALUES '
                        f"('{uid('e', f'{cod}-{k}-{j}')}', '{TENANT}', "
                        f"'{pid}', '{cob_cobro(c)}', 'ESC', {n_rec}, "
                        f"'ESC-{n_rec:05d}', false);")

    L += ['',
          '-- El trigger del server ya genero cuotas al insertar los contratos.',
          '-- Se descartan y se ponen las del escenario, con sus fechas exactas.',
          f"DELETE FROM public.cuotas WHERE tenant_id = '{TENANT}';",
          '']
    L += cuotas_sql
    L += ['']
    L += pagos_sql
    L += recibos_sql

    # INV14: cargos_neto tiene que ser la SUMA REAL de cargos_extra. Poner el
    # neto a mano sin las filas que lo respaldan deja la cuota incoherente. El
    # signo lo da el TIPO, no el monto (hay un CHECK monto >= 0).
    # Primero los ESPECIALES, con su tipo, su origen y su FECHA REAL. Van
    # antes del blanket para poder excluirlos ahi por id.
    ids_especiales = [qid for qid, _c, _t, _cu in cargos_especiales]
    for qid, cid_e, ctr_e, cu_e in cargos_especiales:
        cargo_id = uid('e', qid)
        L += ['',
              f"-- {cu_e.get('cargo_tipo')} declarado por el escenario "
              f"(cuota {cu_e['vence']}).",
              'INSERT INTO public.cargos_extra (id, tenant_id, cuota_id, tipo, '
              'monto, aplicado_por, origen, descripcion, aplicado_en) VALUES',
              f"  ('{cargo_id}', '{TENANT}', '{qid}', "
              f"{q(cu_e['cargo_tipo'])}, {abs(cu_e.get('cargos_neto', 0))}, "
              f"'{COBRADOR}', {q(cu_e.get('cargo_origen', 'ajuste'))}, "
              "'Cargo del escenario de prueba', "
              f"TIMESTAMP {q(cu_e['cargo_fecha'] + ' 12:00:00')});"]
        # Y el saldo a favor del que salio ese credito: sin estas dos filas el
        # escenario muestra el EFECTO (cuota en cero) sin el MECANISMO, y la
        # regla credito-excedente sigue sin probarse.
        cre = cu_e.get('credito_de')
        if cre:
            L += ['INSERT INTO public.saldos_favor (id, tenant_id, cliente_id, '
                  'contrato_id, tipo, monto, cuota_id, cargo_id, creado_por, '
                  'ocurrido_en) VALUES',
                  f"  ('{uid('f', qid + '-a')}', '{TENANT}', '{cid_e}', "
                  f"'{ctr_e}', 'acreditado', {cre['monto']}, NULL, NULL, "
                  f"'{COBRADOR}', TIMESTAMP "
                  f"{q(cre['acreditado_el'] + ' 12:00:00')}),",
                  f"  ('{uid('f', qid + '-b')}', '{TENANT}', '{cid_e}', "
                  f"'{ctr_e}', 'aplicado', {cre['monto']}, '{qid}', "
                  f"'{cargo_id}', '{COBRADOR}', TIMESTAMP "
                  f"{q(cu_e['cargo_fecha'] + ' 12:00:00')});"]
    L += ['']

    # El resto: un cargo generico por cada cargos_neto que no sea especial.
    excl = ''
    if ids_especiales:
        lista = ', '.join(f"'{i}'" for i in ids_especiales)
        excl = ('   AND cu.id NOT IN (' + lista + ')' + chr(10))
    L += ['-- INV14: las filas de cargos_extra que respaldan cada cargos_neto.',
          'INSERT INTO public.cargos_extra (id, tenant_id, cuota_id, tipo, '
          'monto, aplicado_por, origen, descripcion)',
          'SELECT gen_random_uuid(), cu.tenant_id, cu.id,',
          "       CASE WHEN cu.cargos_neto > 0 THEN 'reconexion'",
          "            ELSE 'descuento_monto' END,",
          '       abs(cu.cargos_neto),',
          f"       '{COBRADOR}',",
          "       CASE WHEN cu.cargos_neto > 0 THEN 'cobro' ELSE 'ajuste' END,",
          "       'Cargo del escenario de prueba'",
          f"  FROM public.cuotas cu WHERE cu.tenant_id = '{TENANT}'",
          f'{excl}   AND COALESCE(cu.cargos_neto, 0) <> 0;',
          '']

    # INV17: un contrato indefinido activo necesita >= 3 cuotas pendientes
    # futuras de colchón (en la vida real las genera el cron). Van DESPUÉS del
    # ciclo en curso, así que no tocan ninguno de los 6 que se verifican.
    # El colchon arranca DESPUES de la ultima cuota que ya tiene el contrato, no
    # en una fecha fija. Con fecha fija (2026-09-01) chocaba contra el indice
    # unico (contrato_id, periodo): los clientes con dia_pago <= 14 ya tienen
    # una cuota de septiembre dentro del ciclo en curso.
    L += ['-- INV17: colchón de 3 cuotas futuras por contrato activo, a partir',
          '-- del mes siguiente a la última cuota que ya tiene.',
          'INSERT INTO public.cuotas (id, tenant_id, cliente_id, contrato_id, '
          'periodo, fecha_vencimiento, monto, cargos_neto, estado, cobrador_id)',
          'SELECT gen_random_uuid(), ct.tenant_id, ct.cliente_id, ct.id,',
          "       (u.desde + (n || ' months')::interval)::date,",
          "       (u.desde + (n || ' months')::interval)::date",
          '         + (ct.dia_pago - 1),',
          "       pl.precio_mensual, 0, 'pendiente', ct.cobrador_id",
          '  FROM public.contratos ct',
          '  JOIN public.planes pl ON pl.id = ct.plan_id',
          '  CROSS JOIN LATERAL (',
          '       SELECT GREATEST(',
          "         (COALESCE(MAX(cu.periodo), DATE '2026-08-01')",
          "            + INTERVAL '1 month')::date,",
          "         (date_trunc('month', CURRENT_DATE)",
          "            + INTERVAL '1 month')::date) AS desde",
          '         FROM public.cuotas cu WHERE cu.contrato_id = ct.id) u,',
          '       generate_series(0, 2) AS n',
          f" WHERE ct.tenant_id = '{TENANT}' AND ct.estado = 'activo';",
          '']

    # INV27: todo cobro deja rastro en `op_log`. Lo escribe la app dentro de la
    # misma transaccion del cobro (`pagos_repo`), asi que un seed que inserta
    # pagos "a mano" tiene que emitirlo igual — si no, el escenario nace
    # violando un invariante que en produccion se cumple.
    # Se emite para TODO pago vivo, no solo los recientes: el invariante mira
    # los posteriores al 2026-08-20, pero un rastro parcial seria peor que
    # ninguno — daria la impresion de que el historial esta completo.
    L += ['',
          '-- INV27: el rastro en op_log de cada cobro, como lo escribe la app.',
          'INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad,',
          '  entidad_id, actor_id, actor_label, accion, diff, ocurrido_en)',
          'SELECT gen_random_uuid(), p.tenant_id, gen_random_uuid(),',
          "       'cobro', 'cuotas', p.cuota_id, p.cobrador_id,",
          "       COALESCE(cb.nombre, 'Escenario'), 'update',",
          '       jsonb_build_object(',
          "         'campos', jsonb_build_array(jsonb_build_object(",
          "            'campo', 'saldo', 'antes', p.monto_cordobas, 'despues', 0)),",
          "         'resumen', jsonb_build_object(",
          "            'monto', p.monto_cordobas, 'entregado', p.monto_original,",
          "            'moneda', p.moneda, 'vuelto', p.vuelto_cordobas)),",
          '       p.fecha_pago',
          '  FROM public.pagos p',
          '  LEFT JOIN public.cobradores cb ON cb.id = p.cobrador_id',
          f" WHERE p.tenant_id = '{TENANT}'",
          '   AND p.anulado = false AND p.en_revision = false;',
          '']

    # Un recibo por pago vivo: el invariante INV5 exige que todo pago no
    # anulado tenga el suyo.
    # `periodo_label` (0262): el recibo CONGELA el mes que imprime. Se calca la
    # regla de `Fmt.periodoRecibo` en SQL — dia_pago <= 14 corre el mes uno
    # atras — para que el escenario produzca lo MISMO que produce la app en
    # produccion. Sin esto los recibos del seed nacen con NULL y el escenario
    # ejercita el camino viejo (calcular) en vez del nuevo (leer el congelado).
    # Una cuota sin plan es "manual": el recibo NO imprime periodo -> NULL.
    # Los meses van a MANO y no con to_char(...,'TMMonth'): la base corre en
    # lc_time = en_US.UTF-8, asi que TMMonth devuelve 'June 2026' y el seed
    # habria divergido de la app en ingles (verificado contra vxxz).
    L += ['',
          '-- INV5: todo pago vivo necesita su recibo.',
          'INSERT INTO public.recibos (id, tenant_id, pago_id, cobrador_id, '
          'prefijo, correlativo, numero_completo, periodo_label)',
          'SELECT gen_random_uuid(), p.tenant_id, p.id, p.cobrador_id,',
          "       'ESC', n.i,",
          "       'ESC-' || lpad(n.i::text, 5, '0'),",
          '       (SELECT CASE WHEN pl.id IS NULL THEN NULL ELSE',
          "                 (ARRAY['Enero','Febrero','Marzo','Abril','Mayo',",
          "                        'Junio','Julio','Agosto','Septiembre',",
          "                        'Octubre','Noviembre','Diciembre'])[",
          '                   extract(month from cu.periodo',
          "                     - (CASE WHEN ct.dia_pago <= 14",
          "                             THEN interval '1 month'",
          "                             ELSE interval '0 month' END))::int]",
          "                 || ' ' || extract(year from cu.periodo",
          "                     - (CASE WHEN ct.dia_pago <= 14",
          "                             THEN interval '1 month'",
          "                             ELSE interval '0 month' END))::int::text",
          '               END',
          '          FROM public.cuotas cu',
          '     LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id',
          '     LEFT JOIN public.planes pl    ON pl.id = ct.plan_id',
          '         WHERE cu.id = p.cuota_id)',
          '  FROM (SELECT p.*, row_number() OVER (ORDER BY p.fecha_pago, p.id)',
          '                   AS i',
          f"          FROM public.pagos p WHERE p.tenant_id = '{TENANT}'",
          '           AND COALESCE(p.anulado, false) = false) n,',
          '       public.pagos p',
          ' WHERE p.id = n.id;',
          '',
          'COMMIT;']

    io.open(DESTINO, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
    print(f'clientes={len(clientes)} contratos={n_ctr} cuotas={n_cuo} '
          f'(de esas {n_puntual} como cobro puntual) pagos={n_pag} '
          f'recibos={n_rec}')
    print('->', os.path.relpath(DESTINO, RAIZ))


if __name__ == '__main__':
    main()
