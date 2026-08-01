#!/usr/bin/env python3
# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
"""Build a single PDF of the MEDS-V guide book.

Pipeline:  markdown  ->  pandoc  ->  standalone HTML  ->  headless Chrome  ->  PDF

There is no LaTeX engine on this machine, so Chrome's print-to-PDF does the
rendering.  That turns out to suit this book better than LaTeX would: the
chapters are full of box-drawing diagrams that need a monospace font with good
U+2500 coverage and absolutely no line wrapping, which is easier to guarantee
with CSS than with a LaTeX verbatim environment.

Requires: pandoc, and google-chrome or chromium.

Usage:
    python3 scripts/build_pdf.py
    python3 scripts/build_pdf.py --keep-html     # also leave the intermediate HTML
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOOK = ROOT / "book"

# Chapter order.  Explicit rather than globbed, so the sequence is auditable.
CHAPTERS = [
    "00-preface.md",
    "part1/01-why-vectors.md",
    "part1/02-anatomy-of-a-vector-processor.md",
    "part1/03-from-cray-to-riscv.md",
    "part2/04-rvv-programmers-model.md",
    "part2/05-rvv-instruction-set-tour.md",
    "part2/06-writing-and-running-rvv-code.md",
    "part2/07-vector-length-agnostic-programming.md",
    "part3/08-big-picture-block-diagram.md",
    "part3/09-building-blocks.md",
    "part3/10-design-space.md",
    "part4/11-project-roadmap.md",
    "part4/12-rtl-skeleton-walkthrough.md",
    "part4/13-verification-strategy.md",
    "part5/14-workloads.md",
    "part5/15-benchmarking-and-comparison.md",
    "part5/16-beyond-v1.md",
    "appendix/A-instruction-quickref.md",
    "appendix/B-glossary.md",
    "appendix/C-toolchain-setup.md",
    "appendix/D-reading-list.md",
    "appendix/E-scope-contract.md",
]

# Part dividers, keyed by the chapter they precede.
PARTS = {
    "part1/01-why-vectors.md":            ("Part I",   "Foundations"),
    "part2/04-rvv-programmers-model.md":  ("Part II",  "The RVV 1.0 Instruction Set"),
    "part3/08-big-picture-block-diagram.md": ("Part III", "Microarchitecture"),
    "part4/11-project-roadmap.md":        ("Part IV",  "Building It"),
    "part5/14-workloads.md":              ("Part V",   "Proving It"),
    "appendix/A-instruction-quickref.md": ("Appendices", ""),
}

# A custom template, rather than pandoc's default, purely to control ORDER:
# the default html5 template emits the TOC before the document body, which puts
# the contents page ahead of the title page.
TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$title$</title>
  $for(css)$<style>$styles$</style>$endfor$
  <style>
$style-inline$
  </style>
</head>
<body>

<div class="titlepage">
  <div class="tp-kicker">Maktab-e-Digital Systems &middot; Lahore</div>
  <div class="tp-title">Building a RISC-V<br>Vector Processor</div>
  <div class="tp-sub">From first principles to a benchmarked design</div>
  <div class="tp-rule"></div>
  <div class="tp-meta">
    A complete guide to the RISC-V &ldquo;V&rdquo; Vector Extension 1.0,<br>
    and to designing, verifying and measuring <strong>MEDS-V</strong>.
  </div>
  <div class="tp-foot">
    Apache License 2.0 &nbsp;&middot;&nbsp; Every encoding verified against the assembler;<br>
    every measurement captured from a real run.
  </div>
</div>

$if(toc)$
<h1 class="toc-title">Contents</h1>
<nav id="TOC" role="doc-toc">
$table-of-contents$
</nav>
$endif$

$body$
</body>
</html>
"""

CSS = r"""
@page {
  size: A4;
  margin: 20mm 18mm 22mm 18mm;
  @bottom-center { content: counter(page); }
}

html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }

body {
  font-family: "DejaVu Serif", Georgia, serif;
  font-size: 9.9pt;
  line-height: 1.5;
  color: #1a1a1a;
  max-width: none;
  margin: 0;
}

/* ---------- title page ---------- */
.titlepage { text-align: center; padding-top: 55mm; }
.tp-kicker {
  font-family: "DejaVu Sans", sans-serif; font-size: 10pt;
  letter-spacing: 0.22em; text-transform: uppercase; color: #6b6b6b;
}
.tp-title {
  font-family: "DejaVu Sans", sans-serif; font-size: 34pt; font-weight: 700;
  line-height: 1.15; margin: 14mm 0 6mm 0; border: none; padding: 0; color: #111;
}
.tp-sub { font-size: 13pt; font-style: italic; color: #444; }
.tp-rule { width: 60mm; height: 2px; background: #b03a2e; margin: 12mm auto; }
.tp-meta { font-size: 10.5pt; color: #333; line-height: 1.7; }
.tp-foot { margin-top: 30mm; font-size: 8.5pt; color: #777; line-height: 1.6; }

/* ---------- part dividers ---------- */
.partpage { text-align: center; padding-top: 75mm; page-break-before: always; }
.partpage .pp-num {
  font-family: "DejaVu Sans", sans-serif; font-size: 13pt; letter-spacing: 0.3em;
  text-transform: uppercase; color: #b03a2e;
}
.partpage .pp-name {
  font-family: "DejaVu Sans", sans-serif; font-size: 26pt; font-weight: 700;
  margin-top: 8mm; color: #111;
}

/* ---------- headings ---------- */
h1, h2, h3, h4 { font-family: "DejaVu Sans", sans-serif; color: #111; line-height: 1.25; }
h1 {
  font-size: 20pt; page-break-before: always; padding-bottom: 3mm;
  border-bottom: 2px solid #b03a2e; margin: 0 0 7mm 0;
}
h1.no-break, .titlepage h1 { page-break-before: avoid; }
h2 { font-size: 13pt; margin: 8mm 0 3mm 0; page-break-after: avoid; }
h3 { font-size: 11pt; margin: 6mm 0 2mm 0; page-break-after: avoid; }
h4 { font-size: 10pt; margin: 4mm 0 2mm 0; page-break-after: avoid; }

p { margin: 0 0 2.6mm 0; orphans: 3; widows: 3; }

/* ---------- code ---------- */
code {
  font-family: "DejaVu Sans Mono", monospace; font-size: 0.86em;
  background: #f2f2f0; padding: 0.5pt 2pt; border-radius: 2px;
}
pre {
  font-family: "DejaVu Sans Mono", monospace;
  font-size: 7.1pt;            /* small enough that 100-col ASCII diagrams fit A4 */
  line-height: 1.28;
  background: #f7f7f5;
  border: 0.6pt solid #dcdcd6;
  border-left: 2.5pt solid #b03a2e;
  padding: 2.5mm 3mm;
  margin: 3mm 0;
  white-space: pre;            /* never wrap a diagram */
  overflow: visible;
  page-break-inside: avoid;
}
pre code { background: none; padding: 0; font-size: inherit; }

/* Very long diagrams may exceed one page; allow those to break rather than
   overflow off the bottom of the sheet. */
pre.tall { page-break-inside: auto; }

/* ---------- tables ---------- */
table {
  border-collapse: collapse; width: 100%; margin: 3mm 0;
  font-size: 8.3pt; page-break-inside: avoid;
}
th, td {
  border: 0.5pt solid #ccc; padding: 1.1mm 1.8mm; text-align: left;
  vertical-align: top;
}
th { background: #efefec; font-family: "DejaVu Sans", sans-serif; font-weight: 700; }
tr:nth-child(even) td { background: #fafaf8; }
td code, th code { font-size: 0.92em; }

/* ---------- callout blockquotes ---------- */
blockquote {
  margin: 3.5mm 0; padding: 2.5mm 3.5mm;
  background: #f6f6fb; border-left: 2.5pt solid #5566aa;
  page-break-inside: avoid; font-size: 0.97em;
}
blockquote p:last-child { margin-bottom: 0; }

/* ---------- lists ---------- */
ul, ol { margin: 0 0 2.6mm 0; padding-left: 6mm; }
li { margin-bottom: 0.8mm; }

hr { border: none; border-top: 0.5pt solid #ddd; margin: 5mm 0; }

a { color: #1a4f8a; text-decoration: none; }

/* ---------- table of contents ---------- */
h1.toc-title {
  page-break-before: always; font-size: 20pt;
  border-bottom: 2px solid #b03a2e; padding-bottom: 3mm; margin: 0 0 6mm 0;
}
#TOC { page-break-after: always; }
#TOC > ul { list-style: none; padding-left: 0; font-family: "DejaVu Sans", sans-serif; }
#TOC > ul > li { margin: 1.6mm 0; font-weight: 700; font-size: 10pt; }
#TOC ul ul { list-style: none; padding-left: 5mm; font-weight: 400; font-size: 8.6pt; }
#TOC ul ul ul { display: none; }   /* depth 3+ would double the TOC length */
#TOC a { color: #222; }

.page-break { page-break-after: always; }
"""


def find_chrome() -> str:
    for c in ("google-chrome", "chromium", "chromium-browser", "chrome"):
        p = shutil.which(c)
        if p:
            return p
    sys.exit("error: no Chrome/Chromium found; cannot render the PDF")


def anchor_for(path: str, text: str) -> str:
    """Pandoc's auto-id for a heading, close enough for internal links."""
    s = text.lower()
    s = re.sub(r"[^\w\s-]", "", s)
    return re.sub(r"[\s_]+", "-", s).strip("-")


# The circled block numerals are the ONLY characters used in the ASCII diagrams
# that DejaVu Sans Mono does not contain (checked with fontTools against the
# full set of box-drawing, arrow and geometric glyphs the book uses).  A missing
# glyph falls back to a proportional face, which is wider than one monospace
# cell and ragged-edges every box it appears in.  Inside code fences they are
# therefore swapped for plain digits, which are exactly one cell wide.
# In prose they are left alone -- body text is set in DejaVu Serif, which also
# lacks them, but there the fallback to DejaVu Sans is invisible and correct.
CIRCLED = {ord(c): str(i + 1) for i, c in enumerate("①②③④⑤⑥⑦⑧⑨")}


def ascii_safe_code_blocks(md: str) -> str:
    """Replace circled numerals with plain digits inside fenced code blocks."""
    out, in_fence = [], False
    for line in md.split("\n"):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(line)
        else:
            out.append(line.translate(CIRCLED) if in_fence else line)
    return "\n".join(out)


def preprocess(md: str, rel: str, anchors: dict[str, str]) -> str:
    # Mermaid renders only with a JS library; the same diagram already appears
    # as ASCII art immediately above it, so drop the duplicate for print.
    md = re.sub(r"```mermaid\n.*?\n```\n", "", md, flags=re.S)

    md = ascii_safe_code_blocks(md)

    # Rewrite cross-chapter links to in-document anchors.
    def fix(m):
        label, target = m.group(1), m.group(2)
        key = pathlib.PurePosixPath(
            (pathlib.PurePosixPath(rel).parent / target)).as_posix()
        key = re.sub(r"(^|/)\./", r"\1", key)
        while "/../" in key:
            key = re.sub(r"[^/]+/\.\./", "", key, count=1)
        if key in anchors:
            return f"[{label}](#{anchors[key]})"
        return label            # link out of the book: keep the words, drop the link
    md = re.sub(r"\[([^\]]+)\]\((?!https?:|mailto:|#)([^)]+\.md)\)", fix, md)

    # Links to source files have no meaning in a PDF.
    md = re.sub(r"\[([^\]]+)\]\((?!https?:|mailto:|#)[^)]+\)", r"\1", md)

    # Drop the "Next: ..." footer line; the PDF is read in order.
    md = re.sub(r"\n\*Next: .*?\*\n", "\n", md)
    md = re.sub(r"\n\*Part [IV]+ complete\. Next: .*?\*\n", "\n", md, flags=re.S)
    return md


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs" / "MEDS-V-Building-a-RISC-V-Vector-Processor.pdf"))
    ap.add_argument("--keep-html", action="store_true")
    a = ap.parse_args()

    if not shutil.which("pandoc"):
        sys.exit("error: pandoc not found")
    chrome = find_chrome()

    # Pass 1: work out the anchor each chapter file will land on.
    anchors: dict[str, str] = {}
    for rel in CHAPTERS:
        first_h1 = next((ln[2:].strip()
                         for ln in (BOOK / rel).read_text().splitlines()
                         if ln.startswith("# ")), rel)
        anchors[rel] = anchor_for(rel, first_h1)

    # Pass 2: assemble.
    parts: list[str] = []
    for rel in CHAPTERS:
        if rel in PARTS:
            num, name = PARTS[rel]
            parts.append(
                f'\n<div class="partpage"><div class="pp-num">{num}</div>'
                f'<div class="pp-name">{name}</div></div>\n\n')
        parts.append(preprocess((BOOK / rel).read_text(), rel, anchors))
        parts.append("\n\n")

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        (tmp / "book.md").write_text("".join(parts))
        (tmp / "template.html").write_text(TEMPLATE.replace("$style-inline$", CSS))
        html = tmp / "book.html"

        r = subprocess.run([
            "pandoc", str(tmp / "book.md"),
            "--standalone", "--toc", "--toc-depth=2",
            "--template", str(tmp / "template.html"),
            "--metadata", "title=Building a RISC-V Vector Processor",
            "--metadata", "lang=en",
            "--from", "gfm+tex_math_dollars",
            "--to", "html5",
            "-o", str(html),
        ], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"pandoc failed:\n{r.stderr}")

        out = pathlib.Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run([
            chrome, "--headless", "--disable-gpu", "--no-sandbox",
            "--no-pdf-header-footer",
            "--virtual-time-budget=20000",
            f"--print-to-pdf={out}", html.as_uri(),
        ], capture_output=True, text=True)
        if not out.exists():
            sys.exit(f"chrome failed to produce a PDF:\n{r.stderr[-2000:]}")

        if a.keep_html:
            shutil.copy(html, out.with_suffix(".html"))

    size_mb = out.stat().st_size / 1e6
    print(f"  wrote {out}  ({size_mb:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
