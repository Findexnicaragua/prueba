# -*- coding: utf-8 -*-
"""Generador de mockups SVG de la GUIA-APP (Guia de uso/GUIA-APP.md).

Los mockups imitan la UI REAL de la app (Material 3: AppBar, botones pill,
dialogos Flutter, list tiles, chips, switches). Cada FLUJO se define como
DATOS en flows_etapa*.py y este script lo dibuja consistente en ../img/:

    python "Guia de uso/tools/mockups_guia.py"

SVG autocontenidos (colores fijos, tema claro) — renderizan en GitHub/VS Code.

Elementos soportados en `mock`:
  appbar   {title, back?, actions?:[str | ("icon", nombre)]}
  tile     {text, sub?, avatar?/icon?, right?, pill?, btn?, iconbtn?, tachado?}
  row      {text, sub?, right?, pill?, btn?, tachado?}      (fila simple)
  field    {label, value?}                                   (TextField outline)
  chipbar  {chips: [(label, seleccionado)]}                  (filter chips)
  switchrow{text, on}                                        (SwitchListTile)
  dialog   {title, body?, field?, field2?, actions:[(label, tipo)]}
  label    {text}                                            (header de seccion)
  btnrow   {buttons: [(label, tipo)]}
  fab      {label}                                           (FAB extendido)

Tipos de boton: primary (FilledButton azul) · tonal (celeste) · text
(TextButton) · danger (rojo) · success (verde) · neutral (outline gris).
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

# ── Paleta Material (tema claro de la app) ──────────────────────────────────
TXT = "#1F1F1F"
MUT = "#5F6368"
BRD = "#DADCE0"
PAGE = "#F8F9FA"       # fondo de pagina (fuera de la "pantalla")
WHITE = "#FFFFFF"
COLORS = {
    "primary": ("#1A73E8", "#E8F0FE"),
    "danger":  ("#C5221F", "#FCE8E6"),
    "success": ("#188038", "#E6F4EA"),
    "warn":    ("#B06000", "#FEF7E0"),
    "neutral": (MUT, WHITE),
}

W = 720
PX = 56
PW = W - PX - 12
FONT = "Segoe UI, Arial, sans-serif"


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def tw(s, size):
    return int(len(s) * size * 0.52) + 2


def wrap(s, maxch):
    out, line = [], ""
    for w in s.split():
        if len(line) + len(w) + 1 > maxch:
            out.append(line)
            line = w
        else:
            line = w if not line else line + " " + w
    if line:
        out.append(line)
    return out


# ── Iconos minimos (stroke, caja 16px, centrados en x,y) ────────────────────

def icon_svg(name, x, y, color):
    x0, y0 = x - 8, y - 8
    st = (f'stroke="{color}" stroke-width="1.5" fill="none" '
          f'stroke-linecap="round" stroke-linejoin="round"')
    p = {
        "back":    f'<path d="M{x0+10} {y0+3} L{x0+5} {y0+8} L{x0+10} {y0+13}" {st}/>',
        "chevron": f'<path d="M{x0+6} {y0+3} L{x0+11} {y0+8} L{x0+6} {y0+13}" {st}/>',
        "plus":    f'<path d="M{x0+8} {y0+3} V{y0+13} M{x0+3} {y0+8} H{x0+13}" {st}/>',
        "search":  (f'<circle cx="{x0+7}" cy="{y0+7}" r="4" {st}/>'
                    f'<path d="M{x0+10} {y0+10} L{x0+13.5} {y0+13.5}" {st}/>'),
        "pencil":  f'<path d="M{x0+3} {y0+13} L{x0+3} {y0+10.5} L{x0+10.5} {y0+3} L{x0+13} {y0+5.5} L{x0+5.5} {y0+13} Z" {st}/>',
        "clock":   (f'<circle cx="{x}" cy="{y}" r="6" {st}/>'
                    f'<path d="M{x} {y-3} V{y} L{x+2.5} {y+1.5}" {st}/>'),
        "doc":     (f'<path d="M{x0+4} {y0+2} H{x0+10} L{x0+13} {y0+5} V{y0+14} H{x0+4} Z" {st}/>'
                    f'<path d="M{x0+6} {y0+8} H{x0+11} M{x0+6} {y0+11} H{x0+11}" {st}/>'),
        "ban":     (f'<circle cx="{x}" cy="{y}" r="6" {st}/>'
                    f'<path d="M{x-4.2} {y-4.2} L{x+4.2} {y+4.2}" {st}/>'),
        "print":   (f'<rect x="{x0+3}" y="{y0+6}" width="10" height="6" rx="1" {st}/>'
                    f'<path d="M{x0+5} {y0+6} V{y0+2.5} H{x0+11} V{y0+6} M{x0+5} {y0+10} H{x0+11} V{y0+14} H{x0+5} Z" {st}/>'),
        "trash":   (f'<path d="M{x0+4} {y0+5} H{x0+12} M{x0+7} {y0+3} H{x0+9}" {st}/>'
                    f'<path d="M{x0+5} {y0+5} L{x0+5.7} {y0+13.5} H{x0+10.3} L{x0+11} {y0+5}" {st}/>'),
        "camera":  (f'<rect x="{x0+2.5}" y="{y0+5}" width="11" height="8" rx="2" {st}/>'
                    f'<circle cx="{x}" cy="{y+1}" r="2.2" {st}/>'),
        "pin":     (f'<path d="M{x} {y+6} C{x-4} {y+1} {x-4.5} {y-2} {x} {y-5.5} '
                    f'C{x+4.5} {y-2} {x+4} {y+1} {x} {y+6} Z" {st}/>'
                    f'<circle cx="{x}" cy="{y-1.5}" r="1.6" {st}/>'),
        "check":   f'<path d="M{x0+3.5} {y0+8.5} L{x0+6.7} {y0+11.5} L{x0+12.5} {y0+4.5}" {st}/>',
        "qr":      (f'<rect x="{x0+3}" y="{y0+3}" width="4" height="4" {st}/>'
                    f'<rect x="{x0+9}" y="{y0+3}" width="4" height="4" {st}/>'
                    f'<rect x="{x0+3}" y="{y0+9}" width="4" height="4" {st}/>'
                    f'<path d="M{x0+9} {y0+11} H{x0+13} M{x0+11} {y0+9} V{y0+13}" {st}/>'),
    }
    return p.get(name, "")


class Svg:
    def __init__(self):
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=12, color=TXT, weight="400", anchor="start",
             style=""):
        self.add(f'<text x="{x}" y="{y}" font-family="{FONT}" '
                 f'font-size="{size}" fill="{color}" font-weight="{weight}" '
                 f'text-anchor="{anchor}" {style}>{esc(s)}</text>')

    def rect(self, x, y, w, h, fill, stroke=None, rx=6, sw=1):
        st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
                 f'fill="{fill}"{st}/>')

    def pill(self, x, y, label, tipo, size=10):
        fg, bg = COLORS[tipo]
        w = tw(label, size) + 14
        self.rect(x, y, w, 18, bg, rx=9)
        self.text(x + w / 2, y + 12.7, label, size, fg, "500", "middle")
        return w

    def button(self, x, y, label, tipo, size=11.5):
        """Boton Material: pill de 28px. 'text' = TextButton sin fondo."""
        fg, bg = COLORS["primary"] if tipo in ("text", "tonal") \
            else COLORS.get(tipo, COLORS["neutral"])
        w = tw(label, size) + 26
        if tipo == "text":
            self.text(x + w / 2, y + 18.5, label, size, COLORS["primary"][0],
                      "500", "middle")
            return w
        if tipo in ("primary", "danger", "success"):
            self.rect(x, y, w, 28, fg, rx=14)
            self.text(x + w / 2, y + 18.5, label, size, WHITE, "500", "middle")
        elif tipo == "tonal":
            self.rect(x, y, w, 28, bg, rx=14)
            self.text(x + w / 2, y + 18.5, label, size, fg, "500", "middle")
        else:  # neutral = OutlinedButton
            self.rect(x, y, w, 28, WHITE, stroke=BRD, rx=14)
            self.text(x + w / 2, y + 18.5, label, size, COLORS["primary"][0],
                      "500", "middle")
        return w

    def avatar(self, x, y, iniciales):
        fg, bg = COLORS["primary"]
        self.add(f'<circle cx="{x}" cy="{y}" r="13" fill="{bg}"/>')
        self.text(x, y + 3.8, iniciales, 10.5, fg, "600", "middle")


# ── Render de elementos ──────────────────────────────────────────────────────

def h_appbar(el):
    return 46


def draw_appbar(svg, el, x, y, w):
    svg.add(f'<line x1="{x}" y1="{y + 45}" x2="{x + w}" y2="{y + 45}" '
            f'stroke="{BRD}" stroke-width="0.8"/>')
    tx = x + 14
    if el.get("back", True):
        svg.add(icon_svg("back", x + 20, y + 23, TXT))
        tx = x + 40
    svg.text(tx, y + 27.5, el["title"], 13.5, TXT, "600")
    rx = x + w - 12
    for a in reversed(el.get("actions", [])):
        if isinstance(a, tuple) and a[0] == "icon":
            rx -= 24
            svg.add(icon_svg(a[1], rx + 8, y + 23, MUT))
            rx -= 8
        else:
            bw = tw(a, 11.5) + 10
            rx -= bw
            svg.text(rx + bw / 2, y + 27, a, 11.5, COLORS["primary"][0],
                     "500", "middle")
            rx -= 12
    return 46


def _h_tilelike(el):
    return 48 if el.get("sub") else 36


def _draw_tilelike(svg, el, x, y, w, con_avatar):
    h = _h_tilelike(el)
    svg.add(f'<line x1="{x + 12}" y1="{y + h}" x2="{x + w - 12}" y2="{y + h}" '
            f'stroke="#EEEEEE" stroke-width="0.8"/>')
    tx = x + 14
    if con_avatar and el.get("avatar"):
        svg.avatar(x + 26, y + h / 2, el["avatar"])
        tx = x + 46
    elif el.get("icon"):
        svg.add(icon_svg(el["icon"], x + 24, y + h / 2, MUT))
        tx = x + 42
    ty = y + (20 if el.get("sub") else h / 2 + 4.2)
    rx = x + w - 12
    for key in ("iconbtn", "iconbtn2"):
        if not el.get(key):
            continue
        nombre, tip = el[key]
        rx -= 24
        color = COLORS["danger"][0] if nombre in ("ban", "trash") else MUT
        svg.add(icon_svg(nombre, rx + 8, y + h / 2, color))
        rx -= 10
    if el.get("btn"):
        label, tipo = el["btn"]
        bw = tw(label, 11.5) + 26
        rx -= bw
        svg.button(rx, y + (h - 28) / 2, label, tipo)
        rx -= 10
    if el.get("pill"):
        label, tipo = el["pill"]
        pw = tw(label, 10) + 14
        rx -= pw
        svg.pill(rx, y + (h - 18) / 2, label, tipo)
        rx -= 10
    if el.get("right"):
        svg.text(rx, ty, el["right"], 12, TXT, "600", "end")
        rx -= tw(el["right"], 12) + 10
    tach = 'text-decoration="line-through"' if el.get("tachado") else ""
    svg.text(tx, ty, el["text"], 12.5,
             MUT if el.get("tachado") else TXT, "500" if el.get("sub") else "400",
             style=tach)
    if el.get("sub"):
        svg.text(tx, y + 36, el["sub"], 10.5, MUT)
    return h


def h_tile(el):
    return _h_tilelike(el)


def draw_tile(svg, el, x, y, w):
    return _draw_tilelike(svg, el, x, y, w, con_avatar=True)


def h_row(el):
    return _h_tilelike(el)


def draw_row(svg, el, x, y, w):
    return _draw_tilelike(svg, el, x, y, w, con_avatar=False)


def h_field(el):
    return 46 + (14 if el.get("helper") else 0)


def draw_field(svg, el, x, y, w):
    # TextField Material outline con label flotante sobre el borde.
    svg.rect(x + 12, y + 10, w - 24, 32, WHITE, stroke=BRD, rx=8)
    lw = tw(el["label"], 9.5) + 8
    svg.rect(x + 22, y + 5, lw, 10, WHITE, rx=2)
    svg.text(x + 26, y + 13, el["label"], 9.5, MUT)
    if el.get("value"):
        svg.text(x + 24, y + 30.5, el["value"], 12, TXT)
    if el.get("dropdown"):
        cx = x + w - 30
        svg.add(f'<path d="M{cx - 4} {y + 24} L{cx} {y + 29} L{cx + 4} {y + 24}" '
                f'stroke="{MUT}" stroke-width="1.5" fill="none" '
                f'stroke-linecap="round" stroke-linejoin="round"/>')
    if el.get("helper"):
        svg.text(x + 24, y + 54, el["helper"], 9.5, MUT)
        return 60
    return 46


def h_chipbar(el):
    return 40


def draw_chipbar(svg, el, x, y, w):
    cx = x + 12
    for label, sel in el["chips"]:
        fg, bg = COLORS["primary"]
        cw = tw(label, 11) + (36 if sel else 22)
        if sel:
            svg.rect(cx, y + 7, cw, 26, bg, rx=8)
            svg.add(icon_svg("check", cx + 14, y + 20, fg))
            svg.text(cx + 24, y + 24, label, 11, fg, "500")
        else:
            svg.rect(cx, y + 7, cw, 26, WHITE, stroke=BRD, rx=8)
            svg.text(cx + cw / 2, y + 24, label, 11, TXT, "400", "middle")
        cx += cw + 8
    return 40


def h_switchrow(el):
    return 50 if el.get("sub") else 36


def draw_switchrow(svg, el, x, y, w):
    h = 50 if el.get("sub") else 36
    ty = y + (21 if el.get("sub") else 22.5)
    svg.text(x + 14, ty, el["text"], 12.5, TXT)
    if el.get("sub"):
        svg.text(x + 14, y + 38, el["sub"], 10, MUT)
    on = el.get("on", True)
    tx0 = x + w - 48
    track = COLORS["primary"][0] if on else "#BDC1C6"
    svg.rect(tx0, y + (h - 18) / 2, 34, 18, track, rx=9)
    cx = tx0 + (25 if on else 9)
    svg.add(f'<circle cx="{cx}" cy="{y + h / 2}" r="7" fill="{WHITE}"/>')
    return h


def h_dialog(el):
    body_lines = wrap(el.get("body", ""), 76) if el.get("body") else []
    h = 22 + 24 + len(body_lines) * 15
    for k in ("field", "field2"):
        if el.get(k):
            h += 44
    for it in el.get("items", []):
        h += ELEMS[it["t"]][0](it)
    if el.get("actions"):
        h += 42
    return h + 12


def draw_dialog(svg, el, x, y, w):
    h = h_dialog(el)
    # AlertDialog Material: card angosta centrada con esquinas 16.
    dw = min(w - 60, 520)
    dx = x + (w - dw) / 2
    svg.rect(dx, y + 6, dw, h - 12, WHITE, stroke=BRD, rx=16)
    yy = y + 32
    svg.text(dx + 22, yy, el["title"], 14.5, TXT, "600")
    yy += 6
    for ln in wrap(el.get("body", ""), 76) if el.get("body") else []:
        yy += 15
        svg.text(dx + 22, yy, ln, 11, MUT)
    for k in ("field", "field2"):
        if el.get(k):
            yy += 12
            svg.rect(dx + 22, yy - 2, dw - 44, 32, WHITE, stroke=BRD, rx=8)
            svg.text(dx + 32, yy + 17.5, el[k], 10.5, MUT,
                     style='font-style="italic"')
            yy += 32
    for it in el.get("items", []):
        yy += ELEMS[it["t"]][1](svg, it, dx + 8, yy, dw - 16)
    if el.get("actions"):
        yy += 12
        bx = dx + dw - 20
        for label, tipo in reversed(el["actions"]):
            bw = tw(label, 11.5) + 26
            bx -= bw
            svg.button(bx, yy, label, "text" if tipo in ("neutral", "text") else tipo)
            bx -= 6
    return h


def h_hero(el):
    return 62


def draw_hero(svg, el, x, y, w):
    """Encabezado de sheet: check grande + monto bold + subtitulo (+ reloj)."""
    fg, bg = COLORS.get(el.get("tipo", "success"), COLORS["success"])
    svg.add(f'<circle cx="{x + 30}" cy="{y + 26}" r="11" fill="{fg}"/>')
    svg.add(icon_svg("check", x + 30, y + 26, WHITE))
    svg.text(x + 50, y + 32, el["monto"], 19, TXT, "700")
    if el.get("sub"):
        svg.text(x + 50, y + 50, el["sub"], 10.5, MUT)
    svg.add(icon_svg("clock", x + w - 26, y + 26, MUT))
    return 62


def h_twobox(el):
    return 78


def draw_twobox(svg, el, x, y, w):
    """Dos cajas lado a lado (COMO PAGO / LA CUOTA QUEDO)."""
    bw = (w - 36) / 2
    for i, key in enumerate(("a", "b")):
        d = el[key]
        bx = x + 12 + i * (bw + 12)
        tint = d.get("tint")
        fill = COLORS[tint][1] if tint else "#F1F3F4"
        svg.rect(bx, y + 6, bw, 64, fill, rx=8)
        svg.text(bx + 12, y + 22, d["label"], 9, MUT, "600")
        c1 = COLORS[tint][0] if tint else TXT
        svg.text(bx + 12, y + 41, d["l1"], 13, c1, "700")
        if d.get("l2"):
            svg.text(bx + 12, y + 57, d["l2"], 10.5, MUT)
    return 78


def h_kv(el):
    return 24 + len(el["rows"]) * 24


def draw_kv(svg, el, x, y, w):
    """Seccion 'DATOS DEL COBRO': label + filas etiqueta/valor."""
    svg.text(x + 14, y + 16, el["label"], 9.5, MUT, "600")
    yy = y + 24
    for k, v in el["rows"]:
        svg.text(x + 14, yy + 16, k, 11.5, MUT)
        svg.text(x + 130, yy + 16, v, 11.5, TXT, "500")
        yy += 24
    return 24 + len(el["rows"]) * 24


def h_btnfull(el):
    return 42


def draw_btnfull(svg, el, x, y, w):
    """Boton a lo ancho (como los del sheet del pago)."""
    tipo = el.get("tipo", "primary")
    bx, bw = x + 12, w - 24
    if tipo == "danger_outline":
        fg = COLORS["danger"][0]
        svg.rect(bx, y + 6, bw, 32, WHITE, stroke=BRD, rx=16)
        svg.add(icon_svg("ban", x + w / 2 - tw(el["label"], 12) / 2 - 14,
                         y + 22, fg))
        svg.text(x + w / 2 + 8, y + 26, el["label"], 12, fg, "500", "middle")
    else:
        fg, _ = COLORS.get(tipo, COLORS["primary"])
        svg.rect(bx, y + 6, bw, 32, fg, rx=16)
        if el.get("icon"):
            svg.add(icon_svg(el["icon"],
                             x + w / 2 - tw(el["label"], 12) / 2 - 14,
                             y + 22, WHITE))
        svg.text(x + w / 2 + 8, y + 26, el["label"], 12, WHITE, "500",
                 "middle")
    return 42


def h_cardrow(el):
    return 74


def draw_cardrow(svg, el, x, y, w):
    """Card de 'Por cobrar' (replica): barra de color lateral + codigo·nombre
    bold + linea plan·mes·fecha + badge de estado + saldo bold + Pagar."""
    color = COLORS.get(el.get("color", "primary"), COLORS["primary"])[0]
    svg.rect(x + 12, y + 5, w - 24, 64, WHITE, stroke=BRD, rx=10)
    svg.rect(x + 12, y + 5, 5, 64, color, rx=2)
    svg.text(x + 28, y + 26, el["texto"], 13, TXT, "600")
    if el.get("sub"):
        svg.text(x + 28, y + 44, el["sub"], 10.5, MUT)
    if el.get("badge"):
        label, tipo = el["badge"]
        svg.pill(x + 28, y + 50, label, tipo)
    # Columna derecha: saldo arriba, boton(es) abajo.
    rx = x + w - 24
    svg.text(rx, y + 27, el.get("saldo", ""), 14.5, TXT, "700", "end")
    bx = rx
    for b in reversed(el.get("btns", [("Pagar", "primary")])):
        label, tipo = b
        bw = tw(label, 11.5) + 26
        bx -= bw
        svg.button(bx, y + 34, label, tipo)
        bx -= 8
    return 74


def h_segmented(el):
    return 42


def draw_segmented(svg, el, x, y, w):
    """SegmentedButton Material: segmentos unidos, el activo tinteado."""
    fg, bg = COLORS["primary"]
    widths = [tw(o, 11.5) + (44 if sel else 28) for o, sel in el["opts"]]
    total = sum(widths)
    sx = x + 14
    svg.rect(sx, y + 7, total, 28, WHITE, stroke=BRD, rx=14)
    cx = sx
    for (label, sel), cw in zip(el["opts"], widths):
        if sel:
            svg.rect(cx, y + 7, cw, 28, bg, rx=14)
            svg.add(icon_svg("check", cx + 16, y + 21, fg))
            svg.text(cx + cw / 2 + 8, y + 25, label, 11.5, fg, "500", "middle")
        else:
            svg.text(cx + cw / 2, y + 25, label, 11.5, TXT, "400", "middle")
        cx += cw
    return 42


def h_label(el):
    return 26


def draw_label(svg, el, x, y, w):
    svg.text(x + 14, y + 17, el["text"], 10.5, MUT, "600")
    return 26


def h_btnrow(el):
    return 40


def draw_btnrow(svg, el, x, y, w):
    bx = x + 12
    for b in el["buttons"]:
        label, tipo = b
        bw = svg.button(bx, y + 6, label, tipo)
        bx += bw + 10
    return 40


def h_fab(el):
    return 44


def draw_fab(svg, el, x, y, w):
    fg = COLORS["primary"][0]
    label = el["label"]
    bw = tw(label, 12) + 46
    fx = x + w - bw - 14
    svg.rect(fx, y + 4, bw, 34, fg, rx=12)
    svg.add(icon_svg("plus", fx + 18, y + 21, WHITE))
    svg.text(fx + 32, y + 25.5, label, 12, WHITE, "500")
    return 44


ELEMS = {
    "cardrow": (h_cardrow, draw_cardrow),
    "segmented": (h_segmented, draw_segmented),
    "hero": (h_hero, draw_hero),
    "twobox": (h_twobox, draw_twobox),
    "kv": (h_kv, draw_kv),
    "btnfull": (h_btnfull, draw_btnfull),
    "appbar": (h_appbar, draw_appbar),
    "tile": (h_tile, draw_tile),
    "row": (h_row, draw_row),
    "field": (h_field, draw_field),
    "chipbar": (h_chipbar, draw_chipbar),
    "switchrow": (h_switchrow, draw_switchrow),
    "dialog": (h_dialog, draw_dialog),
    "label": (h_label, draw_label),
    "btnrow": (h_btnrow, draw_btnrow),
    "fab": (h_fab, draw_fab),
}


# ── Render del flujo completo ────────────────────────────────────────────────

def render_flow(flow):
    svg = Svg()
    y = 14
    svg.text(16, y + 12, flow["titulo"], 15, TXT, "600")
    y += 20
    if flow.get("rol"):
        svg.text(16, y + 12, "Quién puede: " + flow["rol"], 11, MUT)
        y += 18
    y += 6
    for paso in flow["pasos"]:
        cy = y + 12
        fg, bg = COLORS["primary"]
        svg.add(f'<circle cx="28" cy="{cy}" r="11" fill="{bg}"/>')
        svg.text(28, cy + 4, str(paso["n"]), 11.5, fg, "600", "middle")
        tlines = wrap(paso["titulo"], 92)
        for i, ln in enumerate(tlines):
            svg.text(PX, y + 16 + i * 15, ln, 12.5, TXT,
                     "600" if i == 0 else "400")
        y += 16 + (len(tlines) - 1) * 15 + 8
        if paso.get("mock"):
            mh = sum(ELEMS[el["t"]][0](el) for el in paso["mock"]) + 10
            # "Pantalla": card blanca estilo app sobre el fondo de pagina.
            svg.rect(PX, y, PW, mh, WHITE, stroke=BRD, rx=10)
            yy = y + 5
            for el in paso["mock"]:
                yy += ELEMS[el["t"]][1](svg, el, PX, yy, PW)
            y += mh + 14
        else:
            y += 6
    if flow.get("nota"):
        lines = wrap("Nota: " + flow["nota"], 96)
        nh = len(lines) * 15 + 14
        svg.rect(16, y, W - 32, nh, "#E8F0FE", rx=8)
        for i, ln in enumerate(lines):
            svg.text(28, y + 19 + i * 15, ln, 11, "#174EA6")
        y += nh + 10
    h = y + 8
    body = "\n".join(svg.parts)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" '
            f'height="{h}" viewBox="0 0 {W} {h}" role="img">\n'
            f'<rect width="{W}" height="{h}" fill="{PAGE}" rx="10" '
            f'stroke="{BRD}"/>\n{body}\n</svg>\n')


def main(flows):
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "img")
    os.makedirs(out_dir, exist_ok=True)
    for flow in flows:
        path = os.path.join(out_dir, flow["id"] + ".svg")
        with open(path, "w", encoding="utf-8") as f:
            f.write(render_flow(flow))
        print("OK", flow["id"] + ".svg")


if __name__ == "__main__":
    from flows_etapa1 import FLOWS as F1  # noqa: E402
    from flows_etapa2 import FLOWS as F2  # noqa: E402
    from flows_etapa3 import FLOWS as F3  # noqa: E402
    main(F1 + F2 + F3)
