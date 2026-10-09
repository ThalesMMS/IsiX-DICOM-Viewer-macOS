#!/usr/bin/env python3
"""Generate the default report templates the app installs.

    python3 tools/generate-report-templates.py            # both
    python3 tools/generate-report-templates.py --word     # only the .docx
    python3 tools/generate-report-templates.py --pages    # only the .pages

The Word template, Horos/Resources/ReportTemplate.docx, is written here as raw
Office Open XML with the merge fields of the former ReportTemplate.doc. Its zip
entries carry a fixed date, so the same source gives the same bytes.

The Pages template, Horos/Resources/ReportTemplate.pages, cannot be written
without Pages: its format is Pages' own. A Word document is written with the
layout and the «field» placeholders, Pages opens it and saves it as a Pages
document in its current format. Pages is driven by AppleScript, so the first
run asks for permission to control it. The text of a Pages header is not
reachable by the report's AppleScript, so the fields in the top margin are in a
text box that Pages places on the section layout, where it repeats on every
page and the report can fill it in.

Neither template holds anything but labels and placeholders.
"""
import argparse
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
WORD_OUTPUT = ROOT / 'Horos/Resources/ReportTemplate.docx'
PAGES_OUTPUT = ROOT / 'Horos/Resources/ReportTemplate.pages'

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
NAMESPACES = ' '.join([
    f'xmlns:w="{W}"', f'xmlns:r="{R}"',
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
])
FIXED_DATE = (2026, 1, 1, 0, 0, 0)


# MARK: Office Open XML

def run(text, bold=False, underline=False, size=None):
    properties = ''.join(filter(None, ['<w:b/>' if bold else '', '<w:u w:val="single"/>' if underline else '',
                                       f'<w:sz w:val="{size}"/>' if size else '']))
    properties = f'<w:rPr>{properties}</w:rPr>' if properties else ''
    pieces = text.split('\t')
    body = '<w:tab/>'.join(f'<w:t xml:space="preserve">{escape(piece)}</w:t>' for piece in pieces)
    return f'<w:r>{properties}{body}</w:r>'


def merge_field(name):
    """A Word merge field showing «name» until the merge replaces it."""
    return ('<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
            f'<w:r><w:instrText xml:space="preserve"> MERGEFIELD {name} </w:instrText></w:r>'
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
            f'<w:r><w:t>«{name}»</w:t></w:r>'
            '<w:r><w:fldChar w:fldCharType="end"/></w:r>')


def date_field():
    return ('<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
            '<w:r><w:instrText xml:space="preserve"> TIME \\@ "dddd, MMMM d, yyyy" </w:instrText></w:r>'
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
            '<w:r><w:t>Date</w:t></w:r>'
            '<w:r><w:fldChar w:fldCharType="end"/></w:r>')


def paragraph(*runs, align=None, space_after=None):
    properties = ''
    if align:
        properties += f'<w:jc w:val="{align}"/>'
    if space_after is not None:
        properties += f'<w:spacing w:after="{space_after}"/>'
    properties = f'<w:pPr>{properties}</w:pPr>' if properties else ''
    return f'<w:p>{properties}{"".join(runs)}</w:p>'


def table(rows):
    def cell(content, width, bold):
        return (f'<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/></w:tcPr>'
                f'{paragraph(run(content, bold=bold))}</w:tc>')
    borders = ''.join(f'<w:{side} w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
                      for side in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'))
    body = ''.join(f'<w:tr>{cell(label, 2600, True)}{cell(value, 6400, False)}</w:tr>' for label, value in rows)
    return ('<w:tbl><w:tblPr><w:tblW w:w="9000" w:type="dxa"/>'
            f'<w:tblBorders>{borders}</w:tblBorders></w:tblPr>'
            '<w:tblGrid><w:gridCol w:w="2600"/><w:gridCol w:w="6400"/></w:tblGrid>'
            f'{body}</w:tbl>')


def text_box(text, x, y, width, height, identifier):
    """A text box positioned on the page; in a header, Pages puts it on the section layout."""
    return (
        '<w:p><w:r><w:drawing>'
        '<wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="1" behindDoc="0" '
        'locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>'
        f'<wp:positionH relativeFrom="page"><wp:posOffset>{x}</wp:posOffset></wp:positionH>'
        f'<wp:positionV relativeFrom="page"><wp:posOffset>{y}</wp:posOffset></wp:positionV>'
        f'<wp:extent cx="{width}" cy="{height}"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>'
        f'<wp:docPr id="{identifier}" name="Text Box {identifier}"/><wp:cNvGraphicFramePr/>'
        '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">'
        '<wps:wsp><wps:cNvSpPr txBox="1"/><wps:spPr>'
        f'<a:xfrm><a:off x="0" y="0"/><a:ext cx="{width}" cy="{height}"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></wps:spPr>'
        f'<wps:txbx><w:txbxContent>{paragraph(run(text, size=18), align="right")}</w:txbxContent></wps:txbx>'
        '<wps:bodyPr lIns="0" tIns="0" rIns="0" bIns="0"/></wps:wsp>'
        '</a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>')


def styles(font):
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<w:styles xmlns:w="{W}"><w:docDefaults><w:rPrDefault><w:rPr>'
            f'<w:rFonts w:ascii="{font}" w:hAnsi="{font}" w:cs="{font}" w:eastAsia="{font}"/>'
            '<w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>'
            '<w:pPrDefault><w:pPr><w:spacing w:after="80"/></w:pPr></w:pPrDefault></w:docDefaults>'
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
            '</w:styles>')


def write_docx(path, body, font, header=None):
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        + ('<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>'
           if header else '') +
        '</Types>')
    package_relationships = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>')
    document_relationships = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        + ('<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>'
           if header else '') +
        '</Relationships>')
    section = ('<w:sectPr>' + ('<w:headerReference w:type="default" r:id="rId2"/>' if header else '') +
               '<w:pgSz w:w="11906" w:h="16838"/>'
               '<w:pgMar w:top="1700" w:right="1300" w:bottom="1300" w:left="1300" w:header="600" w:footer="600" w:gutter="0"/>'
               '</w:sectPr>')
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                f'<w:document {NAMESPACES}><w:body>{"".join(body)}{section}</w:body></w:document>')
    parts = [('[Content_Types].xml', content_types), ('_rels/.rels', package_relationships),
             ('word/_rels/document.xml.rels', document_relationships), ('word/styles.xml', styles(font)),
             ('word/document.xml', document)]
    if header:
        parts.append(('word/header1.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                                          f'<w:hdr {NAMESPACES}>{"".join(header)}</w:hdr>'))
    with zipfile.ZipFile(path, 'w') as archive:
        for name, text in parts:
            entry = zipfile.ZipInfo(name, FIXED_DATE)
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, text.encode('utf-8'))


# MARK: the two templates

LETTERHEAD = ('Radiology Department', 'Institution', 'Address')
SECTIONS = ('Indication', 'Protocol', 'Description', 'Conclusion')


def word_template(path):
    """The fields and layout of the former ReportTemplate.doc, as Word merge fields."""
    body = [paragraph(run(line)) for line in LETTERHEAD]
    body += [paragraph(),
             paragraph(run('\t\t\t\t\t\t'), merge_field('referringPhysician')),
             paragraph(),
             paragraph(run('Name:\t\t\t'), merge_field('name'), run(' ('), merge_field('patientID'), run(')')),
             paragraph(run('Birthdate:\t\t\t'), merge_field('dateOfBirth')),
             paragraph(run('Accession Number:\t\t'), merge_field('accessionNumber')),
             paragraph(),
             paragraph(date_field()),
             paragraph(),
             paragraph(run('Report', bold=True, underline=True), align='center'),
             paragraph(),
             paragraph(merge_field('modality'), run(' - '), merge_field('studyName'), align='center'),
             paragraph(merge_field('date'), align='center'),
             paragraph(),
             paragraph(run('Study performed by: '), merge_field('performingPhysician'), run(' - '),
                       merge_field('institutionName'), align='center'),
             paragraph(),
             paragraph(run('Indication', bold=True), run(':')),
             paragraph(),
             paragraph(run('Technique', bold=True), run(': modality: '), merge_field('modality'),
                       run(', number of images: '), merge_field('numberOfImages')),
             paragraph()]
    for title in ('Quality', 'Description', 'Conclusion'):
        body += [paragraph(run(title, bold=True), run(':')), paragraph()]
    body += [paragraph(), paragraph(run('Sincerely,')), paragraph(), paragraph(merge_field('performingPhysician'))]
    write_docx(path, body, 'Helvetica')


def pages_source(path):
    """The Word document Pages converts into the default Pages template."""
    header = [paragraph(run(LETTERHEAD[0], bold=True)),
              paragraph(run(f'{LETTERHEAD[1]} · {LETTERHEAD[2]}', size=18)),
              text_box('«name» · ID «patientID» · Acc. «accessionNumber»', 3_500_000, 400_000, 3_250_000, 220_000, 1)]
    body = [paragraph(run('Radiology Report', bold=True, size=32), align='center', space_after=240),
            paragraph(run('Referring physician: '), run('«referringPhysician»')),
            paragraph(),
            table([('Patient', '«name»'), ('Patient ID', '«patientID»'), ('Birthdate', '«dateOfBirth»'),
                   ('Accession number', '«accessionNumber»'), ('Study', '«modality» - «studyName»'),
                   ('Study date', '«date»'), ('Report date', '«longtoday»')]),
            paragraph()]
    for title in SECTIONS:
        body += [paragraph(run(f'{title}:', bold=True)), paragraph(), paragraph()]
    body += [paragraph(run('«performingPhysician» - «institutionName»'))]
    write_docx(path, body, 'Helvetica Neue', header)


PAGES_SCRIPT = '''
on run argv
  set nm to item 1 of argv
  set outputPath to item 2 of argv
  with timeout of 300 seconds
  tell application id "com.apple.Pages"
    set d to missing value
    repeat with attempt from 1 to 120
      repeat with candidate in documents
        if (name of candidate) is nm then
          set d to contents of candidate
          exit repeat
        end if
      end repeat
      if d is not missing value then exit repeat
      delay 0.5
    end repeat
    if d is missing value then error "Pages did not open " & nm
    save d in POSIX file outputPath
    close d saving no
  end tell
  end timeout
  return "done"
end run
'''


def pages_template(path):
    with tempfile.TemporaryDirectory(prefix='report-template-') as folder:
        name = 'IsiX Report Template Source'
        source = Path(folder) / f'{name}.docx'
        pages_source(source)
        # Through LaunchServices, which is what grants a sandboxed Pages the file.
        subprocess.run(['open', '-g', '-b', 'com.apple.Pages', str(source)], check=True, timeout=60)
        output = Path(folder) / 'ReportTemplate.pages'
        subprocess.run(['osascript', '-', name, str(output)], input=PAGES_SCRIPT, text=True,
                       check=True, timeout=330)
        for _ in range(60):
            if output.exists():
                break
            time.sleep(0.5)
        if not zipfile.is_zipfile(output):
            raise SystemExit(f'Pages did not save a single-file document at {output}')
        names = zipfile.ZipFile(output).namelist()
        if 'Index/Document.iwa' not in names or 'index.xml' in names:
            raise SystemExit('Pages did not save the document in its current format')
        path.write_bytes(output.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--word', action='store_true', help='write only the Word template')
    parser.add_argument('--pages', action='store_true', help='write only the Pages template')
    arguments = parser.parse_args()
    both = not arguments.word and not arguments.pages
    if arguments.word or both:
        word_template(WORD_OUTPUT)
        print(f'wrote {WORD_OUTPUT.relative_to(ROOT)}')
    if arguments.pages or both:
        pages_template(PAGES_OUTPUT)
        print(f'wrote {PAGES_OUTPUT.relative_to(ROOT)}')


if __name__ == '__main__':
    sys.exit(main())
