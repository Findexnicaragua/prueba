#!/usr/bin/env python3
"""Verifica que las tablas de ARQUITECTURA que se declaran COMPLETAS lo sean.

POR QUE EXISTE
--------------
Dos tablas de `ARQUITECTURA.md` se mantienen a mano y las dos se atrasaron:

  * **§3.6.1 "Mapa EXHAUSTIVO por tabla"** decia estar generado del schema real
    el 2026-07-03 y le faltaban CINCO tablas creadas despues.
  * **§3.8 los buckets de sync**: ni siquiera habia tabla, y cinco buckets no se
    nombraban en ningun lado — incluido el del rol `lectura`.

Las dos son documentos que un agente lee para orientarse ANTES de tocar nada.
Un mapa que dice "exhaustivo" y no lo es, es peor que no tener mapa: se confia
en el. Igual que `regla.py` vigila las reglas de negocio, esto vigila la
ESTRUCTURA — y es lo mismo que ya hicimos con el checklist de audit: convertir
una regla que dependia de acordarse en un grep que falla solo.

QUE COMPARA (todo desde el REPO, sin tocar la base: asi corre en el CI)
----------------------------------------------------------------------
  1. Tablas: las que crean las migraciones (CREATE TABLE menos DROP TABLE)
     contra las filas de §3.6.1.
  2. Buckets: los de `powersync/sync-rules.yaml` contra las filas de §3.8.

La derivacion de (1) se valido contra produccion el 2026-08-26: 50 tablas
derivadas del repo, 50 reales, CERO diferencias en ambas direcciones. Si alguna
vez alguien crea una tabla fuera de una migracion, esa validacion se rompe — y
crear tablas fuera de migraciones ya es un problema por si mismo.

  python tools/estructura.py              muestra el estado
  python tools/estructura.py --verificar  exit 1 si algo falta (para el CI)

LIMITE: verifica que la tabla ESTE listada, no que su fila diga la verdad. Las
FKs, triggers y policies de §3.6.1 siguen siendo a mano; para refrescarlas hay
que consultar la base (ver la nota en §3.6.1).
"""

from __future__ import annotations

import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ARQ = os.path.join(RAIZ, 'ARQUITECTURA.md')
MIGS = os.path.join(RAIZ, 'supabase', 'migrations')
YAML = os.path.join(RAIZ, 'powersync', 'sync-rules.yaml')

RE_CREATE = re.compile(r'create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_]+)', re.I)
RE_DROP = re.compile(r'drop\s+table\s+(?:if\s+exists\s+)?(?:public\.)?([a-z_]+)', re.I)
RE_BUCKET = re.compile(r'^  ([a-z_]+):\s*$')
RE_FILA = re.compile(r'^\|\s*`([a-z_]+)`\s*\|')


def tablas_del_repo():
    """CREATE TABLE menos DROP TABLE en las migraciones."""
    creadas, dropeadas = set(), set()
    for nombre in sorted(os.listdir(MIGS)):
        if not nombre.endswith('.sql'):
            continue
        with open(os.path.join(MIGS, nombre), encoding='utf-8', errors='replace') as fh:
            txt = fh.read()
        creadas.update(m.lower() for m in RE_CREATE.findall(txt))
        dropeadas.update(m.lower() for m in RE_DROP.findall(txt))
    return creadas - dropeadas


def buckets_del_yaml():
    if not os.path.isfile(YAML):
        return set()
    fuera = set()
    with open(YAML, encoding='utf-8', errors='replace') as fh:
        for linea in fh:
            m = RE_BUCKET.match(linea.rstrip('\n'))
            if m:
                fuera.add(m.group(1))
    return fuera


def filas_de_seccion(desde, hasta):
    """Nombres en la primera columna de la tabla markdown entre dos encabezados."""
    fuera = set()
    dentro = False
    with open(ARQ, encoding='utf-8', errors='replace') as fh:
        for linea in fh:
            if desde in linea:
                dentro = True
                continue
            if dentro and hasta in linea:
                break
            if dentro:
                m = RE_FILA.match(linea)
                if m:
                    fuera.add(m.group(1))
    return fuera


def comparar(titulo, reales, documentadas, donde, como_arreglar):
    faltan = sorted(reales - documentadas)
    sobran = sorted(documentadas - reales)
    print('')
    print('== %s ==' % titulo)
    print('   en el repo: %d   |   documentadas: %d' % (len(reales), len(documentadas)))
    if not faltan and not sobran:
        print('   OK, la lista esta completa.')
        return 0
    for x in faltan:
        print('   + EXISTE y NO esta documentada: %s' % x)
    for x in sobran:
        print('   - documentada y YA NO existe:   %s' % x)
    print('   -> %s' % donde)
    print('   -> %s' % como_arreglar)
    return 1


def main():
    verificar = '--verificar' in sys.argv[1:]

    fallo = 0
    fallo |= comparar(
        'TABLAS (migraciones vs ARQUITECTURA 3.6.1)',
        tablas_del_repo(),
        filas_de_seccion('### §3.6.1', '### §3.6.2'),
        'ARQUITECTURA.md -> §3.6.1 Mapa EXHAUSTIVO por tabla',
        'agregar la fila en la MISMA migracion que crea la tabla (Receta R10)')
    fallo |= comparar(
        'BUCKETS (sync-rules.yaml vs ARQUITECTURA 3.8)',
        buckets_del_yaml(),
        filas_de_seccion('### Los 15 buckets', '**Al agregar una tabla**'),
        'ARQUITECTURA.md -> §3.8, la tabla de buckets',
        'agregar la fila al agregar el bucket en el yaml')

    if fallo:
        print('')
        print('Un documento que se declara COMPLETO y no lo es es peor que no')
        print('tenerlo: el proximo que lo lea va a confiar en el.')
    if verificar:
        return fallo
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
