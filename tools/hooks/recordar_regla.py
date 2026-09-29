#!/usr/bin/env python3
"""Hook UserPromptSubmit: mete LA REGLA DE ORO en contexto en cada mensaje.

POR QUE EXISTE
--------------
`AGENTS.md` se carga al abrir la sesion y son 800+ lineas. Sesenta mensajes
despues esta enterrado, y ahi es donde se pierde el seguimiento de las reglas.
Esto las vuelve a poner arriba de todo en CADA mensaje, con la lista de reglas
que hoy tienen ficha.

No tiene dientes (inyecta texto, no bloquea). Los que frenan de verdad son
al_editar.py (puede negar la edicion) y al_cerrar.py (puede negar el cierre).
"""

import json
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGLAS = os.path.join(RAIZ, 'docs', 'reglas')

TEXTO = """LA REGLA DE ORO (AGENTS.md) -- vale para este mensaje:

1. Antes de tocar codigo, corre el indice y pega la salida:
     python tools/regla.py <regla>      (superficies de una regla de negocio)
     python tools/impacto.py <tabla>    (las 8 capas de una tabla)
2. Una regla de negocio NO vive solo en el repo que la ejecuta: vive en los
   filtros, chips, conteos, exports, textos y documentacion. Barrelas todas.
3. La opcion que Ruben elige se ejecuta COMPLETA, no la mitad mas facil.
4. Se cierra con las TRES LISTAS: superficies tocadas / revisadas y sin cambios
   (con el porque) / las que quedan afuera (con el porque).
5. Si cambia lo que el usuario ve o hace: mockups del ciclo de uso, antes y
   despues, sobre el mismo diagrama.
6. Tu criterio puede SUMAR trabajo, nunca sacarlo. El barrido y la doc no son
   opcionales aunque el cambio parezca chico.

Para un pedido de cambio o un reporte de falla, segui el protocolo /pedido
(.claude/skills/pedido/SKILL.md): triaje, indice, panel si corresponde,
esceptico, propuesta con mockups y FRENAR a esperar aprobacion."""


def reglas_con_ficha():
    if not os.path.isdir(REGLAS):
        return []
    return sorted(n[:-3] for n in os.listdir(REGLAS) if n.endswith('.md'))


def main():
    # El payload de stdin no se usa, pero hay que drenarlo igual.
    try:
        sys.stdin.read()
    except Exception:
        pass

    fichas = reglas_con_ficha()
    extra = ''
    if fichas:
        extra = '\n\nReglas con ficha hoy: ' + ', '.join(fichas) + '.'
    else:
        extra = '\n\nTodavia no hay fichas en docs/reglas/. Si el pedido toca una regla de negocio, creala antes de tocar codigo.'

    salida = {
        'hookSpecificOutput': {
            'hookEventName': 'UserPromptSubmit',
            'additionalContext': TEXTO + extra,
        }
    }
    sys.stdout.write(json.dumps(salida, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
