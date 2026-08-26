"""Build the styled pandoc reference.docx used by build-word-docs.py.

Run this once before building the Word docs:

    mkdir -p tools/.build
    pandoc -o tools/.build/ref-default.docx --print-default-data-file reference.docx
    python tools/make-word-template.py

Note: Word resolves a style's w:asciiTheme in preference to its explicit
w:ascii font, so setting a font via python-docx alone is silently ignored.
This script therefore also rewrites the document theme and strips the theme
font references from styles.xml.
"""
import copy
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

SRC = ".build/ref-default.docx"
OUT = ".build/chorus-reference.docx"

BODY_FONT = "Segoe UI"
MONO_FONT = "Consolas"
INK = RGBColor(0x1A, 0x20, 0x2C)        # near-black
ACCENT = RGBColor(0x1E, 0x3A, 0x5F)     # deep navy
MUTED = RGBColor(0x4A, 0x55, 0x68)      # slate

doc = Document(SRC)


def set_font(style, name=None, size=None, color=None, bold=None, italic=None,
             space_before=None, space_after=None, keep_with_next=None):
    f = style.font
    if name:
        f.name = name
        rpr = style.element.get_or_add_rPr()
        rf = rpr.find(qn('w:rFonts'))
        if rf is None:
            rf = OxmlElement('w:rFonts')
            rpr.append(rf)
        for attr in ('w:ascii', 'w:hAnsi', 'w:cs', 'w:eastAsia'):
            rf.set(qn(attr), name)
    if size is not None:
        f.size = Pt(size)
    if color is not None:
        f.color.rgb = color
    if bold is not None:
        f.bold = bold
    if italic is not None:
        f.italic = italic
    pf = getattr(style, 'paragraph_format', None)
    if pf is not None:
        if space_before is not None:
            pf.space_before = Pt(space_before)
        if space_after is not None:
            pf.space_after = Pt(space_after)
        if keep_with_next is not None:
            pf.keep_with_next = keep_with_next


S = doc.styles

# --- body text ---
set_font(S['Normal'], BODY_FONT, 10.5, INK, space_after=8)
S['Normal'].paragraph_format.line_spacing = 1.15

# --- headings ---
heading_spec = {
    'Title':     (26, ACCENT, True,  0, 4),
    'Subtitle':  (13, MUTED,  False, 0, 18),
    'Heading 1': (19, ACCENT, True,  20, 8),
    'Heading 2': (15, ACCENT, True,  16, 6),
    'Heading 3': (12.5, INK,  True,  12, 4),
    'Heading 4': (11, MUTED,  True,  10, 4),
    'Heading 5': (10.5, MUTED, True, 8, 3),
    'Heading 6': (10.5, MUTED, True, 8, 3),
}
for name, (size, color, bold, sb, sa) in heading_spec.items():
    try:
        set_font(S[name], BODY_FONT, size, color, bold=bold,
                 space_before=sb, space_after=sa, keep_with_next=True)
    except KeyError:
        pass

# --- monospace / code ---
for name in ('Source Code', 'Verbatim Char', 'Macro Text'):
    try:
        set_font(S[name], MONO_FONT, 8.5, INK)
    except KeyError:
        pass

# --- captions ---
try:
    set_font(S['Image Caption'], BODY_FONT, 9, MUTED, italic=True, space_after=12)
    S['Image Caption'].paragraph_format.alignment = WD_ALIGN_PARAGRAPH.CENTER
except KeyError:
    pass
try:
    set_font(S['Caption'], BODY_FONT, 9, MUTED, italic=True)
except KeyError:
    pass

# --- table text a touch smaller so wide tables fit ---
for name in ('Table Caption', 'Compact'):
    try:
        set_font(S[name], BODY_FONT, 9.5, INK)
    except KeyError:
        pass

# --- page setup: letter, 1in margins, landscape-friendly width ---
for section in doc.sections:
    section.left_margin = Inches(0.9)
    section.right_margin = Inches(0.9)
    section.top_margin = Inches(0.9)
    section.bottom_margin = Inches(0.9)

doc.save(OUT)
print("wrote", OUT)


# --- post-process the package: theme fonts + strip theme font references ---
# Word resolves w:asciiTheme in preference to w:ascii, so an explicit font on a
# style is ignored unless the theme attributes are removed (or the theme itself
# is changed). Do both.
import re as _re, shutil as _shutil, zipfile as _zip

TMP = OUT + ".tmp"
_shutil.move(OUT, TMP)

with _zip.ZipFile(TMP, "r") as zin, _zip.ZipFile(OUT, "w", _zip.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == "word/theme/theme1.xml":
            xml = data.decode("utf-8")
            xml = _re.sub(r'(<a:latin typeface=")[^"]*(")', r'\1' + BODY_FONT + r'\2', xml)
            xml = _re.sub(r'(<a:cs typeface=")[^"]*(")', r'\1' + BODY_FONT + r'\2', xml)
            data = xml.encode("utf-8")
        elif item.filename == "word/styles.xml":
            xml = data.decode("utf-8")
            xml = _re.sub(r'\s+w:(ascii|hAnsi|cs|eastAsia)Theme="[^"]*"', "", xml)
            data = xml.encode("utf-8")
        zout.writestr(item, data)

import os as _os
_os.remove(TMP)
print("patched theme fonts ->", BODY_FONT)
