#!/usr/bin/env python3
"""Indice de una REGLA DE NEGOCIO: todas las superficies donde se ve.

POR QUE EXISTE
--------------
`impacto.py` contesta "esta TABLA, donde vive". Contesta bien, y por eso los
cambios de columna salen bien. Pero el modo de falla mas caro no es una tabla:
es una REGLA que se arregla en el repo que la EJECUTA y queda mintiendo en las
superficies que la MUESTRAN.

El caso que lo motivo (2026-08-24/26): cambio la regla de cancelacion (cancelar
CONDONA la deuda). Se arreglo `contratos_repo`, se escribio la migracion 0259 y
se reescribio la receta R16 de ARQUITECTURA... y el filtro "Cancelado con deuda"
de la lista de clientes siguio ofreciendo una categoria abolida. R16 nombra los
archivos que EJECUTAN la cancelacion; el filtro vive en uno que R16 no nombra.
O sea: leyendo la documentacion entera y actualizada, no habia forma de llegar.

QUE HACE
--------
La ficha (docs/reglas/<nombre>.md) declara A MANO ~10 renglones: los SIMBOLOS
que representan la regla y los patrones PROHIBIDOS. Las superficies NO se
escriben a mano: las encuentra este script contra el codigo de HOY, y por eso
no envejecen. El bloque `superficies:` es un SNAPSHOT generado (--actualizar)
que sirve de linea base: si manana aparece una superficie que nadie miro,
--verificar falla.

  python tools/regla.py --lista                  las reglas con ficha
  python tools/regla.py cancelacion              el indice completo de una
  python tools/regla.py cancelacion --actualizar regenera el snapshot
  python tools/regla.py --verificar              todas; exit 1 si hay deriva

LIMITES (los mismos que impacto.py)
-----------------------------------
Es grep: trae falsos positivos (un comentario que nombra el simbolo) y pierde
accesos escritos de forma indirecta. Sirve para que NADA obvio se escape, no
para reemplazar leer el codigo.
"""

from __future__ import annotations

import os
import re
import sys

from impacto import CAPAS, RAIZ, buscar

REGLAS_DIR = os.path.join(RAIZ, 'docs', 'reglas')

# Las 8 capas de impacto.py + la carpeta docs/ (su capa DOCS es solo-raiz).
CAPAS_REGLA = list(CAPAS) + [
    ('DOCS - docs/', 'docs', ('.md',),
     'planes y auditorias que describen la regla'),
]

BLOQUES = ('simbolos', 'prohibido', 'docs', 'superficies')


def fichas():
    if not os.path.isdir(REGLAS_DIR):
        return []
    return sorted(n[:-3] for n in os.listdir(REGLAS_DIR) if n.endswith('.md'))


def leer_ficha(nombre):
    """Parsea los bloques ```regla ... ``` de la ficha. Sin dependencias."""
    ruta = os.path.join(REGLAS_DIR, nombre + '.md')
    if not os.path.isfile(ruta):
        raise SystemExit('No existe la ficha: docs/reglas/%s.md' % nombre)
    with open(ruta, encoding='utf-8') as fh:
        lineas = fh.read().splitlines()

    datos = dict((b, []) for b in BLOQUES)
    dentro = False
    clave = None
    for linea in lineas:
        if linea.strip() == '```regla':
            dentro = True
            clave = None
            continue
        if dentro and linea.strip().startswith('```'):
            dentro = False
            clave = None
            continue
        if not dentro or not linea.strip() or linea.strip().startswith('#'):
            continue
        sin_indent = linea.lstrip()
        if sin_indent.endswith(':') and sin_indent[:-1] in BLOQUES:
            clave = sin_indent[:-1]
            continue
        if clave:
            datos[clave].append(sin_indent.rstrip())
    datos['_ruta'] = 'docs/reglas/%s.md' % nombre
    return datos


def patron_de(simbolos):
    if not simbolos:
        raise SystemExit('La ficha no declara ningun simbolo.')
    return re.compile('|'.join(re.escape(s) for s in simbolos))


def escanear(simbolos):
    """{titulo de capa: {archivo: [(linea, texto), ...]}}"""
    patron = patron_de(simbolos)
    fuera = {}
    for titulo, carpeta, exts, _por_que in CAPAS_REGLA:
        # Las fichas nombran los simbolos, asi que se encontrarian a si mismas.
        hits = dict((a, h) for a, h in buscar(patron, carpeta, exts).items()
                    if not a.startswith('docs/reglas/'))
        if hits:
            fuera[titulo] = hits
    return fuera


def es_superficie(ruta):
    """Lo que el usuario VE. La distincion que el bug de la cancelacion expuso."""
    return ruta.startswith('lib/features/')


def es_simbolo_dart(s):
    """¿Este simbolo SOLO puede existir en Dart?

    `ventanaServicio`, `_validarOldestFirst`, `CobroFueraDeOrdenException` son
    identificadores de Dart: camelCase, con guion bajo adelante o con mayuscula
    inicial. NUNCA van a aparecer en un .sql ni en un .yaml. En cambio
    `saldos_favor` o `cancelado_en` son snake_case y pueden ser tabla o columna.
    """
    return bool(re.match(r'^_?[a-z]+[A-Z]', s)) or (s[:1].isupper() if s else False)


def capa_es_de_sql(exts):
    """Capas que solo contienen SQL o YAML: ahi un simbolo Dart no puede estar."""
    return exts in (('.sql',), ('.yaml',), ('.py', '.sql'))


def prohibidos(reglas):
    """Cada renglon es `patron | por que no debe existir`. Devuelve los hits.

    Se busca SOLO en codigo, nunca en `.md`: la documentacion tiene que poder
    NARRAR el comportamiento abolido (la bitacora cuenta el bug que lo abolio).
    Buscarlo tambien ahi hacia que el chequeo fallara siempre, y un chequeo que
    siempre falla se termina ignorando y tapa el dia que haya algo real
    (AGENTS.md -> checklist de audit #14).
    """
    encontrados = []
    for renglon in reglas:
        if '|' not in renglon:
            continue
        crudo, motivo = renglon.split('|', 1)
        patron = re.compile(crudo.strip())
        for _titulo, carpeta, exts, _pq in CAPAS_REGLA:
            if exts == ('.md',):
                continue
            for archivo, hits in buscar(patron, carpeta, exts).items():
                for nro, _txt in hits:
                    encontrados.append((motivo.strip(), archivo, crudo.strip(), nro))
    return encontrados


def archivos_hallados(mapa):
    vistos = set()
    for hits in mapa.values():
        vistos.update(hits)
    return sorted(vistos)


def _renglon(archivo, hits_archivo):
    """Una linea por archivo: la ruta y en que lineas aparece. Compacto a
    proposito: un muro de 500 lineas no lo lee nadie y es el mismo problema
    que este script viene a resolver."""
    nros = ', '.join(str(n) for n, _t in hits_archivo[:12])
    if len(hits_archivo) > 12:
        nros += ', +%d' % (len(hits_archivo) - 12)
    return '  %-58s %2d: %s' % (archivo, len(hits_archivo), nros)


def imprimir(nombre, ficha, mapa):
    print('=' * 78)
    print('REGLA  %s      ficha: %s' % (nombre, ficha['_ruta']))
    print('simbolos: %s' % ', '.join(ficha['simbolos']))
    print('=' * 78)

    vacias = []
    for titulo, _c, _e, por_que in CAPAS_REGLA:
        hits = mapa.get(titulo)
        if not hits:
            vacias.append((titulo, por_que))
            continue

        # La capa DART se parte en dos: lo que el usuario VE va primero y
        # aparte. Esa es la distincion que el bug de la cancelacion expuso.
        superficie = sorted(a for a in hits if es_superficie(a))
        resto = sorted(a for a in hits if not es_superficie(a))

        if superficie:
            print('')
            print('SUPERFICIES -- lo que el usuario VE  (%d archivos)' % len(superficie))
            for a in superficie:
                print(_renglon(a, hits[a]))
        if resto:
            print('')
            print('%s  (%d archivos)' % (titulo, len(resto)))
            for a in resto:
                print(_renglon(a, hits[a]))

    if vacias:
        # Un simbolo de Dart no puede aparecer en un .sql: marcar esa capa como
        # "sin cobertura" es un FALSO NEGATIVO, y ya hizo leer como hueco lo que
        # estaba cubierto (2026-08-26). Se separan las dos listas.
        solo_dart = all(es_simbolo_dart(s) for s in ficha['simbolos'])
        exts_por_titulo = dict((t, e) for t, _c, e, _p in CAPAS_REGLA)
        preguntas = [(t, p) for t, p in vacias
                     if not (solo_dart and capa_es_de_sql(exts_por_titulo.get(t, ())))]
        esperadas = [(t, p) for t, p in vacias if (t, p) not in preguntas]

        if preguntas:
            print('')
            print('CAPAS SIN HITS -- cada una es una PREGUNTA, no un OK')
            for titulo, por_que in preguntas:
                print('  %-32s %s' % (titulo, por_que))
        if esperadas:
            print('')
            print('CAPAS SIN HITS ESPERADAS -- los simbolos de esta regla son de')
            print('Dart, asi que NO pueden aparecer en SQL/YAML. Que esten vacias')
            print('no dice nada sobre la cobertura: para saberlo hay que mirar los')
            print('tests y los casos del escenario, no este grep.')
            for titulo, _p in esperadas:
                print('  %s' % titulo)

    if ficha['docs']:
        print('')
        print('DOCS QUE DESCRIBEN LA REGLA (declarados en la ficha)')
        for d in ficha['docs']:
            print('  %s' % d)

    total = len(archivos_hallados(mapa))
    sup = len([a for a in archivos_hallados(mapa) if es_superficie(a)])
    print('')
    print('TOTAL: %d archivos tocan esta regla, %d de ellos son superficies.' % (total, sup))

    hits_prohibidos = prohibidos(ficha['prohibido'])
    print('')
    print('-' * 74)
    if hits_prohibidos:
        print('PROHIBIDO Y PRESENTE -- %d hallazgo(s):' % len(hits_prohibidos))
        for motivo, archivo, patron, nro in hits_prohibidos:
            print('    %s:%d' % (archivo, nro))
            print('        patron  : %s' % patron)
            print('        por que : %s' % motivo)
    else:
        print('Patrones prohibidos: ninguno presente.')


def snapshot(mapa):
    return archivos_hallados(mapa)


def deriva(ficha, mapa):
    hoy = set(snapshot(mapa))
    declarado = set(ficha['superficies'])
    return sorted(hoy - declarado), sorted(declarado - hoy)


def actualizar(nombre, ficha, mapa):
    ruta = os.path.join(RAIZ, ficha['_ruta'])
    with open(ruta, encoding='utf-8') as fh:
        texto = fh.read()
    nuevo = '\n'.join('  ' + a for a in snapshot(mapa))
    patron = re.compile(r'(^\s*superficies:[ \t]*$)(.*?)(?=^\s*```)', re.M | re.S)
    if not patron.search(texto):
        raise SystemExit('La ficha no tiene bloque `superficies:` para regenerar.')
    texto = patron.sub(lambda m: m.group(1) + '\n' + nuevo + '\n', texto, count=1)
    with open(ruta, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(texto)
    print('Snapshot regenerado en %s (%d archivos).'
          % (ficha['_ruta'], len(snapshot(mapa))))


def verificar():
    nombres = fichas()
    if not nombres:
        print('No hay fichas en docs/reglas/. Nada que verificar.')
        return 0
    fallo = 0
    for nombre in nombres:
        ficha = leer_ficha(nombre)
        mapa = escanear(ficha['simbolos'])
        nuevas, perdidas = deriva(ficha, mapa)
        hits_prohibidos = prohibidos(ficha['prohibido'])
        if not nuevas and not perdidas and not hits_prohibidos:
            print('OK    %-24s %d superficies' % (nombre, len(snapshot(mapa))))
            continue
        fallo = 1
        print('FALLA %s' % nombre)
        for a in nuevas:
            print('   + aparecio una superficie que la ficha no contempla: %s' % a)
        for a in perdidas:
            print('   - la ficha declara una superficie que ya no existe: %s' % a)
        for motivo, archivo, _p, nro in hits_prohibidos:
            print('   ! %s:%d -- %s' % (archivo, nro, motivo))
    if fallo:
        print('')
        print('Revisar cada hallazgo y, si el cambio es correcto, regenerar con')
        print('  python tools/regla.py <regla> --actualizar')
        print('Ver AGENTS.md -> LA REGLA DE ORO.')
    return fallo


def main():
    args = sys.argv[1:]
    if '--lista' in args:
        nombres = fichas()
        print('Reglas con ficha en docs/reglas/:')
        for n in nombres or ['(ninguna todavia)']:
            print('  %s' % n)
        return 0
    if '--verificar' in args:
        return verificar()

    posicionales = [a for a in args if not a.startswith('--')]
    if not posicionales:
        print(__doc__)
        return 2
    nombre = posicionales[0]
    ficha = leer_ficha(nombre)
    mapa = escanear(ficha['simbolos'])
    if '--actualizar' in args:
        actualizar(nombre, ficha, mapa)
        return 0
    imprimir(nombre, ficha, mapa)
    nuevas, perdidas = deriva(ficha, mapa)
    if nuevas or perdidas:
        print('')
        print('DERIVA contra el snapshot de la ficha:')
        for a in nuevas:
            print('   + nueva: %s' % a)
        for a in perdidas:
            print('   - ya no existe: %s' % a)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
