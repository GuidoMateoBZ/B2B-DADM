"""Genera la imagen de la pantalla de carga: glifo + 'B2B' + 'MESH' tallados.

Uso (desde app/):
    python3 tool/make_splash.py assets/icon/B2B_logo_transparent.png \
        assets/icon/B2B_splash.png <carpeta_de_vistas_previas> [estilo]

estilo: "tenue" (por defecto, texto plano apenas más claro que el fondo),
"medio" (un poco más de contraste) o "tallado".
    dart run flutter_native_splash:create

Requiere Pillow y la tipografía Montserrat (Black y Bold); las rutas de
BLACK y BOLD son las de Fedora (paquete julietaula-montserrat-fonts).
"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageChops, ImageFilter

LOGO, OUT, PREV = sys.argv[1], sys.argv[2], sys.argv[3]
STYLE = sys.argv[4] if len(sys.argv) > 4 else 'tenue'
# Color de "B2B" y de "MESH" para los estilos planos.
FLAT = {
    'tenue': ((58, 48, 92), (88, 66, 140)),
    'medio': ((84, 72, 124), (118, 86, 186)),
}
BG = (23, 18, 40)                 # #171228
CANVAS, CIRCLE = 1152, 768        # Android 12: lienzo 288 dp, círculo visible 192 dp
BLACK = '/usr/share/fonts/julietaula-montserrat-fonts/Montserrat-Black.otf'
BOLD = '/usr/share/fonts/julietaula-montserrat-fonts/Montserrat-Bold.otf'
S = 4                              # supermuestreo para bordes suaves


def text_mask(text, font_path, size, tracking=0):
    font = ImageFont.truetype(font_path, size)
    widths = [font.getbbox(c)[2] - font.getbbox(c)[0] for c in text]
    adv = [font.getlength(c) for c in text]
    w = int(sum(adv) + tracking * (len(text) - 1)) + size
    m = Image.new('L', (w, int(size * 1.4)))
    d = ImageDraw.Draw(m)
    x = size // 2
    for c, a in zip(text, adv):
        d.text((x, size // 5), c, font=font, fill=255)
        x += a + tracking
    return m.crop(m.getbbox())


def flat(mask, color):
    layer = Image.new('RGBA', mask.size, (0, 0, 0, 0))
    layer.paste(color + (255,), (0, 0), mask)
    return layer


def engrave(mask, fill, depth):
    """Capa RGBA con el texto 'tallado' sobre el fondo."""
    w, h = mask.size
    pad = depth * 2
    big = Image.new('L', (w + 2 * pad, h + 2 * pad)); big.paste(mask, (pad, pad))
    down = ImageChops.offset(big, 0, depth)
    up = ImageChops.offset(big, 0, -depth)
    layer = Image.new('RGBA', big.size, (0, 0, 0, 0))
    # brillo del borde inferior (fuera de la letra, debajo)
    rim = ImageChops.subtract(down, big).filter(ImageFilter.GaussianBlur(depth / 3))
    layer.paste((92, 76, 140, 255), (0, 0), rim.point(lambda v: v * 0.55))
    # relleno apenas más oscuro que el fondo
    layer.paste(fill + (255,), (0, 0), big)
    # sombra del borde superior interno
    shadow = ImageChops.subtract(big, down).filter(ImageFilter.GaussianBlur(depth / 3))
    layer.paste((6, 4, 14, 255), (0, 0), shadow.point(lambda v: v * 0.9))
    return layer


# glifo (con su halo) recortado
glyph = Image.open(LOGO).convert('RGBA')
glyph = glyph.crop(glyph.getchannel('A').getbbox())

b2b = text_mask('B2B', BLACK, 300 * S, tracking=22 * S)
mesh = text_mask('MESH', BOLD, 92 * S, tracking=120 * S)

# composición en una escala base y después se ajusta al círculo
gh = 520 * S
glyph = glyph.resize((round(glyph.width * gh / glyph.height), gh), Image.LANCZOS)
b2b_w = round(glyph.height * 0.95)
b2b = b2b.resize((b2b_w, round(b2b.height * b2b_w / b2b.width)), Image.LANCZOS)
mesh_w = round(b2b_w * 0.92)
mesh = mesh.resize((mesh_w, round(mesh.height * mesh_w / mesh.width)), Image.LANCZOS)
gap1, gap2 = 70 * S, 46 * S
depth = 6 * S

if STYLE == 'tallado':
    b2b_layer = engrave(b2b, (16, 12, 29), depth)
    mesh_layer = engrave(mesh, (18, 13, 33), depth)
else:
    b2b_color, mesh_color = FLAT[STYLE]
    b2b_layer, mesh_layer = flat(b2b, b2b_color), flat(mesh, mesh_color)
parts = [(glyph, None), (b2b_layer, None), (mesh_layer, None)]
W = max(p.width for p, _ in parts)
H = sum(p.height for p, _ in parts) + gap1 + gap2
comp = Image.new('RGBA', (W, H), (0, 0, 0, 0))
y = 0
for (p, _), gap in zip(parts, [gap1, gap2, 0]):
    comp.alpha_composite(p, ((W - p.width) // 2, y)); y += p.height + gap

# escalar para que todo lo visible entre en el círculo con margen
alpha = comp.getchannel('A')
bb = alpha.getbbox(); comp = comp.crop(bb)
cw, ch = comp.size
target = CIRCLE - 70                       # margen respecto del recorte
scale = target / ((cw * cw + ch * ch) ** 0.5)
# una composición alta y angosta se puede agrandar más que su diagonal
for _ in range(40):
    w2, h2 = cw * scale, ch * scale
    pts = [(x, yy) for x in (-w2 / 2, w2 / 2) for yy in (-h2 / 2, h2 / 2)]
    if max((x * x + yy * yy) ** 0.5 for x, yy in pts) > target / 2:
        break
    scale *= 1.01
# comprobar píxel por píxel contra el círculo
comp = comp.resize((round(cw * scale), round(ch * scale)), Image.LANCZOS)
def fits(img):
    a = img.getchannel('A').point(lambda v: 255 if v > 40 else 0)
    w, h = img.size
    data = a.load()
    r = CIRCLE / 2 - 20
    for yy in range(0, h, 2):
        for x in range(0, w, 2):
            if data[x, yy] and ((x - w / 2) ** 2 + (yy - h / 2) ** 2) ** 0.5 > r:
                return False
    return True
while not fits(comp):
    comp = comp.resize((round(comp.width * 0.97), round(comp.height * 0.97)), Image.LANCZOS)

out = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
out.alpha_composite(comp, ((CANVAS - comp.width) // 2, (CANVAS - comp.height) // 2))
out.save(OUT, optimize=True)
print('composición', comp.size)

# vistas previas: tamaño real aproximado en un teléfono (~2,6x) y ampliada con la guía del círculo
prev = Image.new('RGBA', (CANVAS, CANVAS), BG + (255,)); prev.alpha_composite(out)
g = prev.copy(); ImageDraw.Draw(g).ellipse(((CANVAS - CIRCLE) // 2,) * 2 + ((CANVAS + CIRCLE) // 2,) * 2, outline=(255, 80, 80, 255), width=3)
g.resize((576, 576), Image.LANCZOS).save(PREV + '/prev_guide.png')
phone = Image.new('RGB', (1080, 1500), BG); small = prev.resize((750, 750), Image.LANCZOS)
phone.paste(small, ((1080 - 750) // 2, 375)); phone.resize((540, 750), Image.LANCZOS).save(PREV + '/prev_phone.png')
