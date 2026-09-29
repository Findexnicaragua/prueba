#!/usr/bin/env python3
"""Hook Stop: no deja cerrar un cambio de codigo sin la documentacion al dia.

POR QUE EXISTE
--------------
Es la unica pata del sistema con dientes de verdad del lado del agente. Todo lo
demas (AGENTS.md, el recordatorio de cada mensaje, el aviso al editar) es texto
que hay que cumplir. Esto NIEGA el cierre.

Bloquea si en la rama hay cambios en `lib/`, `supabase/` o `powersync/` y NINGUN
cambio en un `.md`; y si `tools/regla.py --verificar` no esta en verde.

ANTI-LOOP: si ya bloqueo por el mismo estado exacto en esta sesion, la segunda
vez solo avisa y deja pasar. Un hook que bloquea para siempre es peor que no
tener hook -- Ruben se queda trabado y termina apagandolo.
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CODIGO = ('lib/', 'supabase/', 'powersync/')


def git(*args):
    try:
        salida = subprocess.run(['git'] + list(args), cwd=RAIZ,
                                capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ''
    return salida.stdout if salida.returncode == 0 else ''


def archivos_de_la_rama():
    """Todo lo que cambio en esta rama (commiteado o no)."""
    vistos = set()
    base = git('merge-base', 'main', 'HEAD').strip()
    if base:
        for linea in git('diff', '--name-only', base, 'HEAD').splitlines():
            if linea.strip():
                vistos.add(linea.strip())
    for linea in git('status', '--porcelain').splitlines():
        ruta = linea[3:].strip()
        if '->' in ruta:                      # renombrado
            ruta = ruta.split('->')[-1].strip()
        if ruta:
            vistos.add(ruta.strip('"'))
    return sorted(vistos)


def verificar_reglas():
    try:
        salida = subprocess.run([sys.executable, os.path.join('tools', 'regla.py'),
                                 '--verificar'], cwd=RAIZ, capture_output=True,
                                text=True, timeout=180)
    except (OSError, subprocess.SubprocessError):
        return 0, ''
    return salida.returncode, (salida.stdout or '') + (salida.stderr or '')


def ya_bloqueo(session_id, firma):
    """True si ya se bloqueo por este mismo estado (anti-loop)."""
    marca = os.path.join(tempfile.gettempdir(),
                         'crm_hook_cierre_%s.txt' % (session_id or 'sin_sesion'))
    previo = ''
    try:
        with open(marca, encoding='utf-8') as fh:
            previo = fh.read().strip()
    except OSError:
        pass
    if previo == firma:
        return True
    try:
        with open(marca, 'w', encoding='utf-8') as fh:
            fh.write(firma)
    except OSError:
        pass
    return False


def main():
    try:
        payload = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        payload = {}
    session_id = str(payload.get('session_id') or '')

    archivos = archivos_de_la_rama()
    codigo = [a for a in archivos if a.startswith(CODIGO)]
    docs = [a for a in archivos if a.endswith('.md')]

    motivos = []
    if codigo and not docs:
        motivos.append(
            'Cambiaste %d archivo(s) de codigo y NINGUN .md:\n  %s\n'
            'La regla de oro (AGENTS.md) pide barrer las superficies conectadas y '
            'dejar la documentacion diciendo la verdad. Actualiza BITACORA.md y, si '
            'cambio un modulo/tabla/setting/conexion, ARQUITECTURA.md. Si el cambio '
            'toca una regla de negocio: python tools/regla.py <regla> --actualizar.'
            % (len(codigo), '\n  '.join(codigo[:15]))
        )

    if codigo:
        rc, salida = verificar_reglas()
        if rc != 0:
            motivos.append('`python tools/regla.py --verificar` NO esta en verde:\n'
                           + salida.strip())

    if not motivos:
        return 0

    razon = '\n\n'.join(motivos)
    firma = hashlib.sha1(razon.encode('utf-8', 'replace')).hexdigest()

    if ya_bloqueo(session_id, firma):
        salida = {'systemMessage':
                  'Aviso repetido del hook de cierre (ya bloqueo por lo mismo, se '
                  'deja pasar para no trabar la sesion): documentacion pendiente.'}
        sys.stdout.write(json.dumps(salida, ensure_ascii=True))
        return 0

    salida = {'decision': 'block', 'reason': razon}
    sys.stdout.write(json.dumps(salida, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
