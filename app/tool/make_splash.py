"""Genera las imágenes de la pantalla de presentación.

- B2B_splash.png: el glifo del logo dibujado solo con su contorno, en violeta,
  centrado en el lienzo del ícono de Android 12 (1152 px = 288 dp).
- B2B_splash_branding.png: "B2B MESH" fino y espaciado, en gris, para la
  imagen de marca que Android muestra al pie (800x320 px = 200x80 dp).

Uso (desde app/):
    python3 tool/make_splash.py assets/icon/B2B_logo_transparent.png assets/icon
    dart run flutter_native_splash:create

Requiere Pillow y Montserrat Regular; la ruta de FONT es la de Fedora
(paquete julietaula-montserrat-fonts).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

LOGO, OUT_DIR = sys.argv[1], sys.argv[2]

GLYPH_COLOR = (166, 114, 235)      # #A672EB
TEXT_COLOR = (153, 154, 156)       # #999A9C
FONT = '/usr/share/fonts/julietaula-montserrat-fonts/Montserrat-Regular.otf'

S = 4                              # supermuestreo para bordes suaves
ICON_CANVAS = 1152                 # 288 dp a 4x
GLYPH_HEIGHT = 320                 # ~80 dp: el glifo ocupa poco, como en la referencia
STROKE = 6                         # ~1,5 dp
BRAND_W, BRAND_H = 800, 320        # 200x80 dp a 4x
TEXT_WIDTH = 512                   # ~128 dp
TRACKING = 0.42                    # espaciado entre letras, en em


def glyph_outline():
    alpha = Image.open(LOGO).convert('RGBA').getchannel('A')
    mask = alpha.point(lambda v: 255 if v > 128 else 0)
    mask = mask.crop(mask.getbbox())
    h = GLYPH_HEIGHT * S
    mask = mask.resize((round(mask.width * h / mask.height), h), Image.LANCZOS)
    mask = mask.point(lambda v: 255 if v > 127 else 0)
    # Margen: MinFilter repite los píxeles del borde y no erosionaría las
    # partes del glifo que lo tocan.
    pad = 4 * STROKE * S
    padded = Image.new('L', (mask.width + 2 * pad, mask.height + 2 * pad))
    padded.paste(mask, (pad, pad))
    mask = padded
    # Contorno hacia adentro: la silueta exterior conserva su tamaño.
    eroded = mask
    for _ in range(STROKE * S):
        eroded = eroded.filter(ImageFilter.MinFilter(3))
    edge = Image.eval(mask, lambda v: v)
    edge.paste(0, (0, 0), eroded)
    edge = edge.resize((edge.width // S, edge.height // S), Image.LANCZOS)

    layer = Image.new('RGBA', edge.size, GLYPH_COLOR + (0,))
    layer.putalpha(edge)
    canvas = Image.new('RGBA', (ICON_CANVAS, ICON_CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(
        layer,
        ((ICON_CANVAS - layer.width) // 2, (ICON_CANVAS - layer.height) // 2),
    )
    return canvas


def branding():
    text = 'B2B MESH'
    size = 100 * S
    font = ImageFont.truetype(FONT, size)
    tracking = TRACKING * size
    adv = [font.getlength(c) for c in text]
    w = int(sum(adv) + tracking * (len(text) - 1)) + size
    m = Image.new('L', (w, size * 2))
    d = ImageDraw.Draw(m)
    x = size // 2
    for c, a in zip(text, adv):
        d.text((x, size // 2), c, font=font, fill=255)
        x += a + tracking
    m = m.crop(m.getbbox())
    target_w = TEXT_WIDTH
    m = m.resize((target_w, round(m.height * target_w / m.width)), Image.LANCZOS)

    layer = Image.new('RGBA', m.size, TEXT_COLOR + (0,))
    layer.putalpha(m)
    canvas = Image.new('RGBA', (BRAND_W, BRAND_H), (0, 0, 0, 0))
    canvas.alpha_composite(
        layer, ((BRAND_W - layer.width) // 2, (BRAND_H - layer.height) // 2)
    )
    return canvas


if __name__ == '__main__':
    glyph_outline().save(os.path.join(OUT_DIR, 'B2B_splash.png'), optimize=True)
    branding().save(
        os.path.join(OUT_DIR, 'B2B_splash_branding.png'), optimize=True
    )
    print('ok')
