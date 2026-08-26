"""Render the Mermaid diagrams and build the Word (.docx) documentation set.

Word cannot render Mermaid, so each diagram is rasterised to PNG first and
embedded as a figure. Tall top-down flowcharts scale down badly on a portrait
page (a 1:3 aspect diagram fitted to page height leaves ~4pt text), so for those
a left-right variant is also rendered and whichever displays larger is kept.

Requirements
------------
  pandoc            https://pandoc.org           (tested with 3.10)
  Node.js           for @mermaid-js/mermaid-cli
  Chrome or Edge    used headlessly by mermaid-cli
  python packages   python-docx, pillow

Setup
-----
  npm install @mermaid-js/mermaid-cli
  pip install python-docx pillow

  Create puppeteer-config.json next to this script, pointing at your browser
  (forward slashes, not backslashes):

      {
        "executablePath": "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
        "args": ["--no-sandbox", "--disable-setuid-sandbox"]
      }

Usage
-----
  python tools/build-word-docs.py

Output lands in docs/word/.
"""
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DOCS_DIR = REPO / "docs"
OUTDIR = DOCS_DIR / "word"
WORK = HERE / ".build"
IMGDIR = WORK / "diagrams"
MMDC = HERE / "node_modules" / "@mermaid-js" / "mermaid-cli" / "src" / "cli.js"
PCONF = HERE / "puppeteer-config.json"
REF = WORK / "chorus-reference.docx"

MAX_W_IN = 6.6      # US Letter width minus 0.9in margins
MAX_H_IN = 8.4      # page height minus margins, leaving room for a caption
RENDER_SCALE = "3"  # supersample so text stays crisp when scaled to the page
TALL_RATIO = 1.5    # h/w above which a landscape re-layout is attempted

# Paths are relative to the repository root, so root-level documents work too.
DOCS = [
    ("docs/ARCHITECTURE.md", "How It Works, A Visual Guide"),
    ("docs/PRD.md", "Product Requirements Document"),
    ("docs/TRD.md", "Technical Requirements Document"),
    ("docs/UI-FLOW.md", "UI Flow Specification"),
    ("docs/SCHEMA.md", "Backend Schema"),
    ("docs/USER-MANUAL.md", "User Manual"),
    ("REPRODUCE.md", "Reproduction Guide"),
    ("docs/BUILD-NOTES.md", "Build Notes"),
]
PRODUCT = "Chorus: Multi-Output Synchronised Audio Hub"

MERMAID_RE = re.compile(r"```mermaid\r?\n(.*?)```", re.DOTALL)
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$", re.MULTILINE)


def preflight():
    problems = []
    if subprocess.run(["pandoc", "--version"], capture_output=True).returncode != 0:
        problems.append("pandoc not found on PATH")
    if not MMDC.exists():
        problems.append(f"mermaid-cli not found, run: npm install @mermaid-js/mermaid-cli (in {HERE})")
    if not PCONF.exists():
        problems.append(f"missing {PCONF.name}, see the module docstring")
    if problems:
        for p in problems:
            print("ERROR:", p)
        sys.exit(1)


def strip_contents(md):
    """Drop a hand-written Contents block.

    Its anchor links are dead in Word, and pandoc --toc supplies a real one.
    """
    newline = chr(10)
    out = []
    skipping = False
    for line in md.split(newline):
        stripped = line.strip()
        if stripped == "## Contents":
            skipping = True
            continue
        if skipping:
            if stripped.startswith("---") or stripped.startswith("## "):
                skipping = False
            else:
                continue
        out.append(line)
    return newline.join(out)

def nearest_heading(text, pos):
    best = ""
    for m in HEADING_RE.finditer(text, 0, pos):
        best = m.group(1).strip()
    best = re.sub(r"[`*_]", "", best)
    return re.sub(r"^\d+(\.\d+)*\.?\s*", "", best)


def render(code, png_path):
    mmd = png_path.with_suffix(".mmd")
    mmd.write_text(code, encoding="utf-8")
    cmd = ["node", str(MMDC), "-i", str(mmd), "-o", str(png_path),
           "-p", str(PCONF), "-b", "white", "-s", RENDER_SCALE]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if r.returncode != 0 or not png_path.exists():
        raise RuntimeError(f"render failed: {png_path.name}\n{r.stdout}\n{r.stderr}")
    with Image.open(png_path) as im:
        return im.size


def display_scale(px_w, px_h):
    """Inches per pixel once fitted to the page box. Larger means bigger text."""
    return min(MAX_W_IN / px_w, MAX_H_IN / px_h)


def to_landscape(code):
    """Swap a top-down flow/state diagram to left-right, or None if N/A."""
    head = code.strip().split("\n", 1)[0]
    if re.match(r"^\s*(flowchart|graph)\s+(TD|TB)\s*$", head):
        return re.sub(r"^(\s*(?:flowchart|graph)\s+)(TD|TB)\s*$", r"\1LR",
                      code, count=1, flags=re.MULTILINE)
    if re.match(r"^\s*stateDiagram-v2\s*$", head) and "direction" not in code:
        lines = code.split("\n")
        for i, ln in enumerate(lines):
            if ln.strip().startswith("stateDiagram"):
                lines.insert(i + 1, "    direction LR")
                break
        return "\n".join(lines)
    return None


def fit_dpi(png_path):
    """Stamp DPI metadata so pandoc sizes the image inside the page box."""
    with Image.open(png_path) as im:
        w, h = im.size
        dpi = w / MAX_W_IN
        if h / dpi > MAX_H_IN:
            dpi = h / MAX_H_IN
        im.save(png_path, dpi=(dpi, dpi))
        return round(w / dpi, 2), round(h / dpi, 2)


def main():
    preflight()
    for d in (IMGDIR, WORK, OUTDIR):
        d.mkdir(parents=True, exist_ok=True)

    if not REF.exists():
        print(f"ERROR: {REF} missing, run tools/make-word-template.py first")
        sys.exit(1)

    total = relaid = 0
    for fname, doc_title in DOCS:
        text = (REPO / fname).read_text(encoding="utf-8")
        stem = Path(fname).stem.lower()
        fig_no = 0
        replacements = []

        for m in MERMAID_RE.finditer(text):
            fig_no += 1
            total += 1
            code = m.group(1)
            png = IMGDIR / f"{stem}-fig{fig_no:02d}.png"

            w, h = render(code, png)
            best = display_scale(w, h)
            note = ""

            if h / w > TALL_RATIO:
                alt = to_landscape(code)
                if alt:
                    alt_png = IMGDIR / f"{stem}-fig{fig_no:02d}-lr.png"
                    try:
                        aw, ah = render(alt, alt_png)
                        if display_scale(aw, ah) > best * 1.15:
                            png.unlink(missing_ok=True)
                            alt_png.replace(png)
                            note = "  [re-laid landscape]"
                            relaid += 1
                        else:
                            alt_png.unlink(missing_ok=True)
                    except RuntimeError:
                        pass

            win, hin = fit_dpi(png)
            ctx = nearest_heading(text, m.start())
            caption = f"Figure {fig_no}. {ctx}" if ctx else f"Figure {fig_no}"
            replacements.append((m.span(), f"\n![{caption}]({png.as_posix()})\n"))
            print(f"  {png.stem:22s} {win:5.2f} x {hin:5.2f} in   {caption}{note}")

        out, last = [], 0
        for (s, e), rep in replacements:
            out.append(text[last:s])
            out.append(rep)
            last = e
        out.append(text[last:])
        body = "".join(out)

        # sibling .md cross-links are dead in Word, keep the text, drop the link
        body = re.sub(r"\[([^\]]+)\]\([^)]*\.md(?:#[^)]*)?\)", r"\1", body)
        body = re.sub(r"^#\s+.*\n", "", body, count=1)   # title comes from metadata
        body = strip_contents(body)

        front = (f'---\ntitle: "{doc_title}"\nsubtitle: "{PRODUCT}"\n'
                 f'toc-title: "Contents"\n---\n\n')
        md_out = WORK / Path(fname).name
        md_out.write_text(front + body, encoding="utf-8")

        docx_out = OUTDIR / f"Chorus - {doc_title}.docx"
        r = subprocess.run(
            ["pandoc", str(md_out), "-o", str(docx_out),
             f"--reference-doc={REF}",
             "--from=gfm+pipe_tables+yaml_metadata_block+implicit_figures",
             "--to=docx", "--toc", "--toc-depth=3", "--standalone",
             # Word's layout engine hangs on a single paragraph containing
             # hundreds of runs. Syntax highlighting turns each code block into
             # exactly that (a 54KB / 619-run paragraph hung Word indefinitely),
             # so code is emitted as plain monospace instead.
             "--syntax-highlighting=none",
             f"--resource-path={IMGDIR}"],
            capture_output=True, text=True)
        if r.returncode != 0:
            print("PANDOC FAIL:", r.stderr[:800])
            sys.exit(1)
        print(f"OK  {docx_out.name}  ({fig_no} figures)\n")

    print(f"{total} diagrams rendered, {relaid} re-laid landscape for readability")
    print(f"Output: {OUTDIR}")


if __name__ == "__main__":
    main()
