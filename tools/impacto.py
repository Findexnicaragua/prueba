#!/usr/bin/env python3
"""Mapa de impacto de una TABLA o COLUMNA: todo lo que hay que tocar con ella.

POR QUE EXISTE
--------------
El modo de falla mas caro del proyecto, dicho por Ruben: "se piden cambios que
por jerarquia van encadenados con otras tablas, esas tablas se quedan fuera y
esos cambios danan la interaccion". La regla para evitarlo YA existe
(ARQUITECTURA R4/R10, checklist 4 de AGENTS: "grepea todas las queries que
tocan la tabla") — pero depende de que alguien se acuerde de correrla y de que
la corra COMPLETA. Cuando falla, falla en produccion, dias despues.

Esto la vuelve mecanica. Se corre ANTES de proponer un cambio y su salida se
pega en la propuesta de Fase 2, para que Ruben vea la lista entera de lo que se
toca ANTES de aprobar — y no descubra lo que faltaba tres dias despues.

  python tools/impacto.py cuotas
  python tools/impacto.py cuotas.cargos_neto
  python tools/impacto.py --lista          # las tablas que conoce el schema

QUE MIRA (las 8 capas donde una tabla vive en este repo)
--------------------------------------------------------
  1. Postgres    migraciones: CREATE TABLE, columnas, triggers, policies, CHECK
  2. SQLite      powersync/schema.dart — si falta, el cliente NO ve la columna
  3. Sync        powersync/sync-rules.yaml — en que buckets viaja, por rol
  4. Dart        lib/ — cada query y cada repo que la lee o escribe
  5. Tests       test/ — que la cubre hoy
  6. Escenarios  supabase/escenarios/ — los dos seeds (Postgres y SQLite)
  7. Exports     los Excel/PDF que la muestran
  8. Docs        ARQUITECTURA / AGENTS / MODULOS

NO es exhaustivo ni pretende serlo: es grep sobre el repo, asi que puede traer
falsos positivos (un comentario que nombra la tabla) y perder un acceso escrito
de forma indirecta. Sirve para que NADA obvio se escape, no para reemplazar
leer el codigo.
"""

from __future__ import annotations

import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# La consola de Windows arranca en cp1252 y los guiones de las cabeceras la
# hacen explotar (UnicodeEncodeError). Forzar UTF-8 en la salida.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# Cada capa: (titulo, carpeta, extensiones, por que importa si aparece aca)
CAPAS = [
    ('POSTGRES · migraciones', 'supabase/migrations', ('.sql',),
     'triggers, policies RLS y CHECKs que se rompen o hay que extender'),
    ('SQLITE · schema del cliente', 'lib/powersync', ('.dart',),
     'si la columna no esta aca, la app NO la ve aunque exista en el server'),
    ('SYNC · reglas del VPS', 'powersync', ('.yaml',),
     'en que buckets viaja; si falta, un rol no recibe la fila (ver §3.8)'),
    ('DART · queries y repos', 'lib', ('.dart',),
     'cada lugar que la lee o escribe — el que se olvida es el que rompe'),
    ('TESTS', 'test', ('.dart',),
     'lo que hoy la cubre; si el cambio no toca ningun test, sospechar'),
    ('ESCENARIOS · los dos seeds', 'supabase/escenarios', ('.py', '.sql'),
     'Postgres y SQLite tienen que quedar IGUALES (ya divergieron 3 veces)'),
    ('SQL de verificacion', 'supabase/tests', ('.sql',),
     'invariantes de dinero: correrlos despues si el cambio toca plata'),
    ('DOCS', '.', ('.md',),
     'ARQUITECTURA/AGENTS/MODULOS: la receta que hay que actualizar'),
]

EXCLUIR = ('.git', 'build', '.dart_tool', 'node_modules', '.claude',
           'docs/archive', 'windows', 'android', 'ios')


def archivos(carpeta: str, exts: tuple[str, ...]):
    base = os.path.join(RAIZ, carpeta)
    if not os.path.isdir(base):
        return
    solo_raiz = carpeta == '.'
    for dirpath, dirnames, filenames in os.walk(base):
        rel_dir = os.path.relpath(dirpath, RAIZ).replace('\\', '/')
        if any(rel_dir == e or rel_dir.startswith(e + '/') for e in EXCLUIR):
            dirnames[:] = []
            continue
        if solo_raiz and dirpath != base:
            dirnames[:] = []
            continue
        for n in sorted(filenames):
            if n.endswith(exts):
                yield os.path.join(dirpath, n)


def buscar(patron: re.Pattern, carpeta: str, exts: tuple[str, ...]):
    """Devuelve {ruta relativa: [(nro_linea, texto), ...]}."""
    hits: dict[str, list[tuple[int, str]]] = {}
    for ruta in archivos(carpeta, exts):
        try:
            with open(ruta, encoding='utf-8', errors='replace') as fh:
                for i, linea in enumerate(fh, 1):
                    if patron.search(linea):
                        rel = os.path.relpath(ruta, RAIZ).replace('\\', '/')
                        hits.setdefault(rel, []).append((i, linea.strip()[:150]))
        except OSError:
            continue
    return hits


# Cosas que, si aparecen, merecen un aviso aparte: son las que rompen callado.
ALERTAS = [
    (re.compile(r'CREATE\s+(OR\s+REPLACE\s+)?TRIGGER', re.I),
     'TRIGGER: recalcula solo. El cliente NO lo corre — hay que espejarlo en Dart'),
    (re.compile(r'CREATE\s+POLICY|USING\s*\(', re.I),
     'RLS: toda tabla tenant-scoped necesita `super_admin_all` A MANO (R10)'),
    (re.compile(r'\bCHECK\s*\(', re.I),
     'CHECK: verificar por CONTENIDO que acepta los valores nuevos, no que exista'),
    (re.compile(r'GENERATED|DEFAULT\s+', re.I),
     'DEFAULT/GENERATED: el INSERT desde Dart no lo hereda'),
    (re.compile(r'REFERENCES\s+\w+', re.I),
     'FK: la tabla del otro lado tambien entra en el cambio'),
]


def main() -> int:
    args = [a for a in sys.argv[1:] if a != '--lista']
    if '--lista' in sys.argv[1:]:
        sch = os.path.join(RAIZ, 'lib/powersync/schema.dart')
        with open(sch, encoding='utf-8') as fh:
            tablas = re.findall(r"Table\(\s*'(\w+)'", fh.read())
        print(f'{len(tablas)} tablas en el schema del cliente:\n')
        for t in sorted(tablas):
            print(' ', t)
        return 0

    if not args:
        print(__doc__)
        return 2

    objetivo = args[0]
    tabla, _, columna = objetivo.partition('.')
    # La columna manda si vino: buscar la tabla entera trae demasiado ruido.
    aguja = columna or tabla
    patron = re.compile(r'\b' + re.escape(aguja) + r'\b')

    print('=' * 78)
    print(f'MAPA DE IMPACTO · {objetivo}')
    if columna:
        print(f'  (se busca la COLUMNA `{columna}`; para la tabla entera: '
              f'python tools/impacto.py {tabla})')
    print('=' * 78)

    total = 0
    vacias = []
    alertas_vistas: list[str] = []

    for titulo, carpeta, exts, porque in CAPAS:
        hits = buscar(patron, carpeta, exts)
        n = sum(len(v) for v in hits.values())
        total += n
        if not hits:
            vacias.append((titulo, porque))
            continue
        print(f'\n── {titulo}  ({n} hits en {len(hits)} archivos)')
        print(f'   {porque}')
        for ruta in sorted(hits):
            print(f'   {ruta}')
            for nro, txt in hits[ruta][:4]:
                print(f'       {nro}: {txt}')
            if len(hits[ruta]) > 4:
                print(f'       … y {len(hits[ruta]) - 4} mas')
            if carpeta == 'supabase/migrations':
                for rx, aviso in ALERTAS:
                    if any(rx.search(t) for _, t in hits[ruta]) \
                            and aviso not in alertas_vistas:
                        alertas_vistas.append(aviso)

    if alertas_vistas:
        print('\n' + '=' * 78)
        print('OJO — lo que rompe callado')
        print('=' * 78)
        for a in alertas_vistas:
            print(f'  · {a}')

    if vacias:
        print('\n' + '=' * 78)
        print('CAPAS SIN HITS — cada una es una pregunta, no un OK')
        print('=' * 78)
        for titulo, porque in vacias:
            print(f'  · {titulo}: {porque}')

    print('\n' + '=' * 78)
    print(f'{total} hits. Pegar esto en la propuesta de Fase 2 ANTES de '
          f'pedir aprobacion.')
    print('=' * 78)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
