#!/usr/bin/env python3
"""Hook PreToolUse (Edit|Write): avisa si el archivo es superficie de una regla.

POR QUE EXISTE
--------------
El bug arquetipo del proyecto: se edita un archivo sin saber que ese archivo
MUESTRA una regla de negocio que se acaba de cambiar en otro lado. Este hook
mira el archivo que se va a tocar, busca en que fichas de docs/reglas/ figura
como superficie, y lo dice EN EL MOMENTO, no tres dias despues en produccion.

Modo AVISO (default): inyecta el aviso y deja seguir.
Modo FRENO: exportar CRM_HOOK_EDITAR=freno para que NIEGUE la edicion hasta que
se haya corrido el indice de esa regla. Empezar en aviso; endurecer si hace
falta.
"""

import json
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGLAS = os.path.join(RAIZ, 'docs', 'reglas')

VIGILADO = ('lib/', 'supabase/migrations/', 'powersync/')


def rel(ruta):
    """Ruta relativa a la raiz del repo, tolerante al formato.

    El hook puede recibir `C:\\Users\\...` (Windows), `/c/Users/...` (Git Bash) o
    ya relativa. `os.path.relpath` no sirve: entre `/c/Users` y `C:/Users` tira
    ValueError y el hook se quedaba MUDO, que es la peor falla posible en algo
    que existe para avisar. Lo cazo el pipe-test, no el ojo.
    """
    r = ruta.replace('\\', '/').lstrip('./')
    if r.startswith(VIGILADO):
        return r
    base = RAIZ.replace('\\', '/')
    if r.lower().startswith(base.lower()):
        return r[len(base):].lstrip('/')
    for pref in VIGILADO:
        i = r.find('/' + pref)
        if i != -1:
            return r[i + 1:]
    return r


def superficies_declaradas():
    """{archivo: [reglas que lo listan]} leyendo el bloque `superficies:`."""
    mapa = {}
    if not os.path.isdir(REGLAS):
        return mapa
    for nombre in sorted(os.listdir(REGLAS)):
        if not nombre.endswith('.md'):
            continue
        ruta = os.path.join(REGLAS, nombre)
        dentro = False
        en_superficies = False
        try:
            with open(ruta, encoding='utf-8') as fh:
                for linea in fh:
                    s = linea.strip()
                    if s == '```regla':
                        dentro = True
                        continue
                    if dentro and s.startswith('```'):
                        break
                    if not dentro or not s:
                        continue
                    if s.endswith(':'):
                        en_superficies = (s == 'superficies:')
                        continue
                    if en_superficies:
                        mapa.setdefault(s, []).append(nombre[:-3])
        except OSError:
            continue
    return mapa


def main():
    try:
        payload = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        return 0

    ruta = (payload.get('tool_input') or {}).get('file_path') or ''
    if not ruta:
        return 0
    archivo = rel(ruta)
    if not archivo.startswith(VIGILADO):
        return 0

    reglas = superficies_declaradas().get(archivo, [])
    if not reglas:
        return 0

    lista = ', '.join(reglas)
    aviso = (
        'ATENCION -- %s es SUPERFICIE de la regla de negocio: %s.\n'
        'Antes de editarlo corre `python tools/regla.py %s` y revisa TODAS sus '
        'superficies, no solo esta: el bug tipico de este proyecto es arreglar '
        'donde la regla se EJECUTA y dejar mintiendo donde se MUESTRA.\n'
        'Al cerrar, si cambio el mapa: `python tools/regla.py %s --actualizar`.'
        % (archivo, lista, reglas[0], reglas[0])
    )

    if os.environ.get('CRM_HOOK_EDITAR', '').lower() == 'freno':
        salida = {
            'hookSpecificOutput': {
                'hookEventName': 'PreToolUse',
                'permissionDecision': 'ask',
                'permissionDecisionReason': aviso,
            }
        }
    else:
        salida = {
            'hookSpecificOutput': {
                'hookEventName': 'PreToolUse',
                'additionalContext': aviso,
            }
        }
    sys.stdout.write(json.dumps(salida, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
