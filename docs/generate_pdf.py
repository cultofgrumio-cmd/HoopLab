"""
Convert hooplab_technical_overview.md to a well-formatted PDF using reportlab.
Run: python generate_pdf.py
"""

import re
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib import colors
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    HRFlowable, PageBreak, Preformatted
)
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_JUSTIFY
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
import os

# ── Output path ────────────────────────────────────────────────────────────────
OUT = os.path.join(os.path.dirname(__file__), "hooplab_technical_overview.pdf")
MD  = os.path.join(os.path.dirname(__file__), "hooplab_technical_overview.md")

# ── Colors ─────────────────────────────────────────────────────────────────────
BLUE_DARK   = colors.HexColor("#1565C0")
BLUE_MID    = colors.HexColor("#1976D2")
BLUE_LIGHT  = colors.HexColor("#E3F2FD")
MONO_BG     = colors.HexColor("#F5F5F5")
MONO_BORDER = colors.HexColor("#CCCCCC")
GREY_TEXT   = colors.HexColor("#37474F")

# ── Styles ─────────────────────────────────────────────────────────────────────
base = getSampleStyleSheet()

def make_style(name, parent="Normal", **kw):
    s = ParagraphStyle(name, parent=base[parent], **kw)
    return s

cover_title = make_style("CoverTitle",
    fontSize=30, textColor=BLUE_DARK, spaceAfter=8,
    fontName="Helvetica-Bold", alignment=TA_CENTER)

cover_sub = make_style("CoverSub",
    fontSize=14, textColor=BLUE_MID, spaceAfter=4,
    fontName="Helvetica", alignment=TA_CENTER)

cover_meta = make_style("CoverMeta",
    fontSize=11, textColor=GREY_TEXT, spaceAfter=2,
    fontName="Helvetica", alignment=TA_CENTER)

h1 = make_style("H1",
    fontSize=16, textColor=BLUE_DARK, spaceBefore=18, spaceAfter=6,
    fontName="Helvetica-Bold", borderPad=4,
    backColor=BLUE_LIGHT)

h2 = make_style("H2",
    fontSize=13, textColor=BLUE_MID, spaceBefore=12, spaceAfter=4,
    fontName="Helvetica-Bold")

h3 = make_style("H3",
    fontSize=11, textColor=BLUE_MID, spaceBefore=8, spaceAfter=3,
    fontName="Helvetica-BoldOblique")

body = make_style("Body",
    fontSize=10, textColor=GREY_TEXT, spaceAfter=6, leading=15,
    alignment=TA_JUSTIFY)

bullet_style = make_style("Bullet",
    fontSize=10, textColor=GREY_TEXT, spaceAfter=3, leading=14,
    leftIndent=16, firstLineIndent=-10)

code_style = make_style("Code",
    fontSize=8.5, fontName="Courier", textColor=colors.HexColor("#1A237E"),
    backColor=MONO_BG, spaceBefore=4, spaceAfter=4,
    leading=12, leftIndent=12, rightIndent=12)

footer_style = make_style("Footer",
    fontSize=8, textColor=colors.grey, alignment=TA_CENTER)

# ── Header / Footer ────────────────────────────────────────────────────────────
def on_page(canvas, doc):
    canvas.saveState()
    w, h = letter
    # header bar
    canvas.setFillColor(BLUE_DARK)
    canvas.rect(0, h - 0.5*inch, w, 0.5*inch, fill=1, stroke=0)
    canvas.setFillColor(colors.white)
    canvas.setFont("Helvetica-Bold", 9)
    canvas.drawString(0.75*inch, h - 0.32*inch, "HoopLab")
    canvas.setFont("Helvetica", 9)
    canvas.drawRightString(w - 0.75*inch, h - 0.32*inch, "Technical Overview · GameGala Demo")
    # footer
    canvas.setFillColor(GREY_TEXT)
    canvas.setFont("Helvetica", 8)
    canvas.drawCentredString(w/2, 0.4*inch, f"Page {doc.page}")
    canvas.restoreState()

def on_first_page(canvas, doc):
    # no header on cover page
    canvas.saveState()
    w, h = letter
    canvas.setFillColor(GREY_TEXT)
    canvas.setFont("Helvetica", 8)
    canvas.drawCentredString(w/2, 0.4*inch, "Confidential — GameGala Demo")
    canvas.restoreState()

# ── Markdown parser ────────────────────────────────────────────────────────────
def inline(text):
    """Convert inline markdown (`code`, **bold**, *italic*) to reportlab markup."""
    # escape & < > first
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    # backtick code
    text = re.sub(r'`([^`]+)`', r'<font name="Courier" color="#1A237E">\1</font>', text)
    # bold
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    # italic
    text = re.sub(r'\*(.+?)\*', r'<i>\1</i>', text)
    return text

def parse_table(lines):
    """Parse a markdown table into a list of row lists."""
    rows = []
    for line in lines:
        if re.match(r'\s*\|[-:| ]+\|\s*$', line):
            continue  # separator row
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        rows.append(cells)
    return rows

def build_table_flowable(rows):
    if not rows:
        return []
    col_count = max(len(r) for r in rows)
    # Pad rows
    padded = [r + [''] * (col_count - len(r)) for r in rows]

    # Build paragraph cells
    header_cell = make_style("TH", fontSize=9, fontName="Helvetica-Bold",
                              textColor=colors.white, alignment=TA_LEFT, leading=12)
    data_cell   = make_style("TD", fontSize=9, fontName="Helvetica",
                              textColor=GREY_TEXT, alignment=TA_LEFT, leading=12)

    table_data = []
    for i, row in enumerate(padded):
        style = header_cell if i == 0 else data_cell
        table_data.append([Paragraph(inline(cell), style) for cell in row])

    col_width = (6.5 * inch) / col_count
    t = Table(table_data, colWidths=[col_width] * col_count, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND",  (0, 0), (-1, 0),  BLUE_DARK),
        ("BACKGROUND",  (0, 1), (-1, -1), colors.white),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, BLUE_LIGHT]),
        ("GRID",        (0, 0), (-1, -1), 0.5, MONO_BORDER),
        ("TOPPADDING",  (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING",(0, 0), (-1, -1), 6),
        ("VALIGN",      (0, 0), (-1, -1), "TOP"),
    ]))
    return [t, Spacer(1, 8)]

def md_to_flowables(md_text):
    lines = md_text.splitlines()
    flowables = []
    i = 0

    # Skip YAML front matter
    if lines and lines[0].strip() == "---":
        i = 1
        while i < len(lines) and lines[i].strip() != "---":
            i += 1
        i += 1  # skip closing ---

    in_code = False
    code_buf = []
    in_table = False
    table_buf = []

    while i < len(lines):
        line = lines[i]

        # ── code blocks ──────────────────────────────────────────────────────
        if line.strip().startswith("```"):
            if not in_code:
                in_code = True
                code_buf = []
            else:
                in_code = False
                code_text = "\n".join(code_buf)
                flowables.append(Preformatted(code_text, code_style,
                                              maxLineLength=85))
                flowables.append(Spacer(1, 4))
                code_buf = []
            i += 1
            continue

        if in_code:
            code_buf.append(line)
            i += 1
            continue

        # ── table detection ───────────────────────────────────────────────────
        if re.match(r'\s*\|', line):
            if not in_table:
                in_table = True
                table_buf = []
            table_buf.append(line)
            i += 1
            continue
        else:
            if in_table:
                in_table = False
                rows = parse_table(table_buf)
                flowables.extend(build_table_flowable(rows))
                flowables.append(Spacer(1, 6))
                table_buf = []

        stripped = line.strip()

        # ── page breaks ───────────────────────────────────────────────────────
        if stripped == r"\newpage" or stripped == "---":
            if stripped == "---":
                flowables.append(HRFlowable(width="100%", thickness=0.5,
                                            color=BLUE_MID, spaceAfter=6))
            i += 1
            continue

        # ── headings ─────────────────────────────────────────────────────────
        m = re.match(r'^(#{1,3})\s+(.*)', stripped)
        if m:
            level = len(m.group(1))
            text = m.group(2)
            # strip trailing markdown from heading
            text = re.sub(r'\s*#+\s*$', '', text)
            if level == 1:
                flowables.append(Spacer(1, 6))
                flowables.append(Paragraph(inline(text), h1))
                flowables.append(HRFlowable(width="100%", thickness=1,
                                            color=BLUE_DARK, spaceAfter=4))
            elif level == 2:
                flowables.append(Paragraph(inline(text), h2))
            else:
                flowables.append(Paragraph(inline(text), h3))
            i += 1
            continue

        # ── bullet points ─────────────────────────────────────────────────────
        m = re.match(r'^[-*]\s+(.*)', stripped)
        if m:
            flowables.append(Paragraph("• " + inline(m.group(1)), bullet_style))
            i += 1
            continue

        # ── blank line ────────────────────────────────────────────────────────
        if not stripped:
            flowables.append(Spacer(1, 4))
            i += 1
            continue

        # ── normal paragraph ──────────────────────────────────────────────────
        flowables.append(Paragraph(inline(stripped), body))
        i += 1

    # flush table if file ends inside one
    if in_table and table_buf:
        rows = parse_table(table_buf)
        flowables.extend(build_table_flowable(rows))

    return flowables

# ── Cover page ─────────────────────────────────────────────────────────────────
def cover_flowables():
    items = []
    items.append(Spacer(1, 1.8*inch))
    items.append(Paragraph("HoopLab", cover_title))
    items.append(Spacer(1, 0.1*inch))
    items.append(HRFlowable(width="60%", thickness=2, color=BLUE_MID,
                             hAlign="CENTER", spaceAfter=12))
    items.append(Paragraph("Computer Vision Basketball Shot Analysis", cover_sub))
    items.append(Spacer(1, 0.1*inch))
    items.append(Paragraph("Technical Overview &amp; Codebase Reference", cover_sub))
    items.append(Spacer(1, 0.5*inch))
    items.append(Paragraph("GameGala Demo · April 2026", cover_meta))
    items.append(Paragraph("Austin A.", cover_meta))
    items.append(Spacer(1, 0.5*inch))
    items.append(HRFlowable(width="40%", thickness=1, color=BLUE_LIGHT,
                             hAlign="CENTER", spaceAfter=12))
    items.append(Paragraph(
        "Built with Flutter · YOLOv8 · Google ML Kit · On-Device Inference",
        cover_meta))
    items.append(PageBreak())
    return items

# ── Build PDF ──────────────────────────────────────────────────────────────────
def main():
    with open(MD, encoding="utf-8") as f:
        md_text = f.read()

    doc = SimpleDocTemplate(
        OUT,
        pagesize=letter,
        leftMargin=0.75*inch,
        rightMargin=0.75*inch,
        topMargin=0.75*inch,
        bottomMargin=0.7*inch,
        title="HoopLab Technical Overview",
        author="Austin A.",
        subject="GameGala Demo",
    )

    story = cover_flowables() + md_to_flowables(md_text)

    doc.build(story,
              onFirstPage=on_first_page,
              onLaterPages=on_page)

    print(f"PDF written: {OUT}")

if __name__ == "__main__":
    main()
