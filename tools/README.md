# Documentation tools

Everything needed to validate the Mermaid diagrams and render the documentation set to Word.

| Tool | Purpose |
|---|---|
| `validate-diagrams.mjs` | Parse every Mermaid diagram and fail on a syntax error |
| `make-word-template.py` | Build the styled pandoc reference template |
| `build-word-docs.py` | Rasterise diagrams and produce `docs/word/*.docx` |
| `unblock-word-files.ps1` | Clear Word's blacklist when it refuses to open a file |

---

## Setup

```bash
# pandoc 3.x from https://pandoc.org/installing.html
pandoc --version

pip install python-docx pillow

cd tools
PUPPETEER_SKIP_DOWNLOAD=true npm install @mermaid-js/mermaid-cli
npm install mermaid@11 jsdom
```

Then create `tools/puppeteer-config.json` pointing at your browser:

```json
{
  "executablePath": "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "args": ["--no-sandbox", "--disable-setuid-sandbox"]
}
```

**Forward slashes only.** A Windows path with backslashes is invalid JSON escaping, and the failure message points at a character offset rather than at the path.

`PUPPETEER_SKIP_DOWNLOAD` reuses the Chrome you already have instead of pulling a 150 MB Chromium.

---

## validate-diagrams.mjs

```bash
node tools/validate-diagrams.mjs .
```

Parses every fenced `mermaid` block in the repository with the real Mermaid parser. Exit code 0 means all valid, 1 means at least one failed.

Run this before pushing documentation changes. A malformed diagram renders as an error box on GitHub rather than failing loudly.

---

## make-word-template.py

```bash
python tools/make-word-template.py
```

Produces the styled reference template the Word build uses. Run once, or again after changing fonts or page setup.

It sets fonts, heading sizes and colours, and 0.9 inch margins. It also patches the document theme and strips `w:*Theme` attributes from `styles.xml`, which is necessary because **Word resolves `w:asciiTheme` in preference to `w:ascii`**. Without that step, fonts set through python-docx are silently ignored.

---

## build-word-docs.py

```bash
python tools/build-word-docs.py
```

Renders every Mermaid diagram to PNG, substitutes them into a copy of each Markdown file, and converts to `.docx` with pandoc. Output goes to `docs/word/`.

Four behaviours are worth knowing about, each of which exists because of a specific failure. Details are in [BUILD-NOTES.md](../docs/BUILD-NOTES.md).

**It re-lays tall diagrams.** A top down flowchart with a dozen nodes has roughly a 1:7 aspect ratio. Fitted to page height it lands at about 2.3 inches wide, putting label text near 4pt. For anything taller than 1.5 times its width the script also renders a left to right variant and keeps whichever displays larger. Layout direction is presentation, not meaning, so the Markdown keeps the natural top down form for GitHub.

**It disables syntax highlighting.** Highlighted code becomes a single Word paragraph containing hundreds of separately styled runs. A 54 KB, 619 run paragraph hung Word indefinitely.

**It stamps DPI on each PNG** so pandoc sizes images inside the page box rather than overflowing it.

**It strips hand-written Contents sections.** Their anchor links are dead in Word, and pandoc's `--toc` supplies a working one.

To add a document, append it to `DOCS`. Paths are relative to the repository root, so root level files such as `REPRODUCE.md` work alongside those in `docs/`.

### After building

Open each document and press `Ctrl+A` then `F9` to populate the table of contents. Pandoc writes it as a field that Word fills in on demand, so page numbers show as placeholders until you do this once.

---

## unblock-word-files.ps1

```powershell
.\tools\unblock-word-files.ps1 -List            # show what Word has blacklisted
.\tools\unblock-word-files.ps1 -Match chorus    # clear entries matching a pattern
```

When Word hangs or is force closed while opening a document, it records that exact path under `HKCU\Software\Microsoft\Office\<ver>\Word\Resiliency\DisabledItems`. From then on it hangs or refuses on that path no matter how healthy the file is.

This is self reinforcing: force closing Word to escape the hang adds another entry.

**The diagnostic tell** is that a byte identical copy under a different filename opens instantly. If that is true, the problem is not the file.

The script leaves unrelated entries, such as add ins and other documents, untouched.
