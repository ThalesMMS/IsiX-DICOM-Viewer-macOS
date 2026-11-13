#!/usr/bin/env python3
"""The images of a .docx report are written into the document, with no Word.

Inserting the selected images into a Word report asked Word to draw them, with
a script that never compiled against Word 16's dictionary (`make inline picture
... file name`, -2741): no image was ever inserted. A .docx is a ZIP archive of
XML parts, so the figures are written into it instead - the image under
`word/media`, a relationship from the document part, a content type, and a
paragraph that holds the drawing in line with the text, at the end of the body.

The production WordDocumentFigures is compiled here and run on documents made
below and on the template the app ships. What it writes is read back with
Python's zipfile and XML parser, which are no part of it: the archive is whole,
every part that was there is byte for byte what it was except the three it has
to change, the document part is the old one with the paragraphs put in at one
place, each figure has the size asked in EMU and points at the image that was
given, and a second insertion collides with nothing of the first. A document it
cannot be sure of is refused and left as it was. textutil - Apple's own reader
of .docx - still reads the text of the result.

The copy the figures are written into then takes the place of the report. A
Word that has the report itself open would keep the document it read, so a Word
that is running is asked which files it has open, and a report among them is
refused untouched, as is everything when Word cannot be asked; a Word that is
not running is sent nothing. That is run here with answers of the test's.

No Word, no Automation and no screen are needed.
"""
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
import zlib

root = Path(__file__).resolve().parents[1]
failures = []
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
WP = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PACKAGE = 'http://schemas.openxmlformats.org/package/2006/relationships'
TYPES = 'http://schemas.openxmlformats.org/package/2006/content-types'


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def png(path, w, h):
    raw = b''.join(b'\x00' + b''.join(bytes((x * 255 // w, y * 255 // h, 128)) for x in range(w)) for y in range(h))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


CONTENT_TYPES = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="%s">'
                 '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                 '<Default Extension="xml" ContentType="application/xml"/>'
                 '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.'
                 'wordprocessingml.document.main+xml"/></Types>' % TYPES)
PACKAGE_RELS = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="%s"><Relationship Id="rId1" '
                'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
                'Target="word/document.xml"/></Relationships>' % PACKAGE)


def docx(path, body, prefix='w', namespace=W, rels=None, parts=None):
    """A small document whose body is `body`, written with `prefix` for the main namespace."""
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<%s:document xmlns:%s="%s" xmlns:r="%s"><%s:body>%s</%s:body></%s:document>'
                % (prefix, prefix, namespace, R, prefix, body, prefix, prefix))
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', CONTENT_TYPES)
        archive.writestr('_rels/.rels', PACKAGE_RELS)
        archive.writestr('word/document.xml', document)
        if rels is not None:
            archive.writestr('word/_rels/document.xml.rels', rels)
        for name, data in (parts or {}).items():
            archive.writestr(name, data)


def parts_of(path):
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        check(bad is None, '%s: the archive is damaged at %s' % (path.name, bad))
        return archive.namelist(), {name: archive.read(name) for name in archive.namelist()}


def figures(document):
    """The figures of a document part, in order: (relationship id, cx, cy, drawing id), and what the body ends with."""
    tree = ET.fromstring(document)
    body = tree.find('{%s}body' % W)
    children = list(body)
    last = children[-1].tag if children else None
    found = []
    for child in children:
        for inline in child.iter('{%s}inline' % WP):
            extent = inline.find('{%s}extent' % WP)
            blip = next(inline.iter('{%s}blip' % A))
            found.append((blip.get('{%s}embed' % R), int(extent.get('cx')), int(extent.get('cy')),
                          inline.find('{%s}docPr' % WP).get('id'), children.index(child)))
    return found, last, len(children)


def inserted(name, before_path, after_path, images, sizes, expect_section_last):
    """Everything a document that took `images` has to be, against what it was."""
    old_names, old = parts_of(before_path)
    new_names, new = parts_of(after_path)
    label = '%s: ' % name
    check(new_names[:len(old_names)] == old_names or set(old_names) <= set(new_names), label + 'a part of the document is gone')
    changed = {'word/document.xml', 'word/_rels/document.xml.rels', '[Content_Types].xml'}
    for part in old_names:
        if part not in changed:
            check(new[part] == old[part], label + '%s was changed' % part)
    media = [n for n in new_names if n not in old_names and n != 'word/_rels/document.xml.rels']
    check(len(media) == len(images) and all(n.startswith('word/media/') and n.endswith('.jpeg') for n in media),
          label + 'the new parts are %s' % media)
    # The document part is the old one with something put in at one place.
    before, after = old['word/document.xml'], new['word/document.xml']
    prefix = next((i for i in range(len(before)) if before[i:i + 1] != after[i:i + 1]), len(before))
    suffix = len(before) - prefix
    check(after[:prefix] == before[:prefix] and after[len(after) - suffix:] == before[prefix:], label + 'the document part was rewritten, not added to')
    old_figures, _, old_count = figures(before)
    found, last, count = figures(after)
    added = found[len(old_figures):]
    check(len(added) == len(images) and count == old_count + len(images), label + 'the body gained %d paragraphs for %d images' % (count - old_count, len(images)))
    if expect_section_last:
        check(last == '{%s}sectPr' % W, label + 'the body no longer ends with its section properties')
        check([f[4] for f in added] == list(range(count - 1 - len(images), count - 1)), label + 'the figures are not the last paragraphs of the body')
    else:
        check([f[4] for f in added] == list(range(count - len(images), count)), label + 'the figures are not the last of the body')
    relationships = {r.get('Id'): r for r in ET.fromstring(new['word/_rels/document.xml.rels'])}
    check(len(relationships) == len(list(ET.fromstring(new['word/_rels/document.xml.rels']))), label + 'two relationships share an id')
    for (relationship, cx, cy, _, _), image, (width, height) in zip(added, images, sizes):
        check((cx, cy) == (round(width * 12700), round(height * 12700)), label + 'a figure of %s x %s points is %d x %d EMU' % (width, height, cx, cy))
        target = relationships.get(relationship)
        if check(target is not None and target.get('Type', '').endswith('/image'), label + 'a figure points at no image relationship'):
            check(new.get('word/' + target.get('Target')) == image.read_bytes(), label + 'the image in the document is not the one given')
    ids = [f[3] for f in found]
    check(len(set(ids)) == len(ids), label + 'two drawings share an id: %s' % ids)
    defaults = [d.get('Extension').lower() for d in ET.fromstring(new['[Content_Types].xml']) if d.tag == '{%s}Default' % TYPES]
    check(defaults.count('jpeg') == 1, label + 'the content types name jpeg %d times' % defaults.count('jpeg'))
    return media


program = r'''
import Foundation

let arguments = CommandLine.arguments
switch arguments[1] {
case "insert":
    // insert <docx> then width height path for each image
    var images: [ReportPreparedImage] = []
    var index = 3
    while index + 2 < arguments.count + 0 {
        images.append(ReportPreparedImage(path: arguments[index + 2], widthPoints: Double(arguments[index])!, heightPoints: Double(arguments[index + 1])!))
        index += 3
    }
    do {
        try WordDocumentFigures.insert(images, intoDocumentAt: arguments[2])
        print("inserted")
    } catch {
        print("refused: \(error)")
    }
case "report":
    // The application's own entry, for a .docx: no editor is asked.
    let done = ReportImageInsertion.insert(reportPath: arguments[2], sources: Array(arguments.dropFirst(3)))
    print(done ? "inserted" : "failed: \(ReportImageInsertion.lastErrorMessage())")
case "guard":
    // guard <copy> <report> <image> <running|quit> then what Word answers: "deaf", or the files it has open.
    let image = ReportPreparedImage(path: arguments[4], widthPoints: 340, heightPoints: 255)
    var asked = 0
    let done = ReportImageInsertion.write([image], intoCopy: arguments[2], ofReportAt: arguments[3], wordIsRunning: arguments[5] == "running", send: { source, _ in
        asked += 1
        guard source == ReportImageInsertion.wordDocumentsScript else { print("FAIL: another script was sent"); exit(1) }
        if arguments.dropFirst(6).first == "deaf" { return nil }
        let list = NSAppleEventDescriptor.list()
        for (index, file) in arguments.dropFirst(6).enumerated() { list.insert(NSAppleEventDescriptor(string: file), at: index + 1) }
        return list
    })
    print("\(done ? "inserted" : "failed") asked=\(asked) \(done ? "" : ReportImageInsertion.lastErrorMessage())")
default:
    exit(2)
}
'''

with tempfile.TemporaryDirectory(prefix='horos-word-figures-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(program)
    (work / 'bridge.h').write_text('#include "%s"\n#include "%s"\n' % (
        root / 'Horos/Sources/ThirdParty/Libarchive/archive.h', root / 'Horos/Sources/ThirdParty/Libarchive/archive_entry.h'))
    built = subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(work / 'bridge.h'),
                            *(str(root / 'Horos/Sources' / name) for name in (
                                'WordDocumentFigures.swift', 'ReportImagePlacement.swift', 'PagesHeaderFooterFill.swift',
                                'PagesApplication.swift', 'PagesDocumentFill.swift', 'MainActorCallbacks.swift')),
                            str(work / 'main.swift'), '-larchive', '-o', str(work / 'figures')],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        print('FAIL: the production WordDocumentFigures did not compile:\n%s' % (built.stderr or built.stdout)[-3000:])
        sys.exit(1)

    def run(*args):
        return subprocess.run([str(work / 'figures'), *map(str, args)], capture_output=True, text=True, timeout=120).stdout.strip()

    # Two JPEGs, as the application prepares them, and their sizes in points.
    images = []
    for index, (w, h) in enumerate(((64, 48), (96, 48))):
        png(work / ('picture-%d.png' % index), w, h)
        subprocess.run(['sips', '-s', 'format', 'jpeg', str(work / ('picture-%d.png' % index)), '--out', str(work / ('picture-%d.jpg' % index))],
                       capture_output=True, check=True)
        images.append(work / ('picture-%d.jpg' % index))
    sizes = [(340, 255), (340, 170)]

    def insert(path, pictures=None, dimensions=None):
        arguments = []
        for image, (width, height) in zip(pictures or images, dimensions or sizes):
            arguments += [width, height, image]
        return run('insert', path, *arguments)

    # The template the application ships, twice: the second insertion collides with nothing of the first.
    original = work / 'template.docx'
    shutil.copy(root / 'Horos/Resources/ReportTemplate.docx', original)
    once = work / 'once.docx'
    shutil.copy(original, once)
    answer = insert(once)
    check(answer == 'inserted', 'the shipped template: %s' % answer)
    first = inserted('the shipped template', original, once, images, sizes, True)
    twice = work / 'twice.docx'
    shutil.copy(once, twice)
    check(insert(twice) == 'inserted', 'a second insertion was refused')
    second = inserted('a second insertion', once, twice, images, sizes, True)
    check(not set(first) & set(second), 'the second insertion wrote over the images of the first: %s' % sorted(set(first) & set(second)))
    text = subprocess.run(['textutil', '-convert', 'txt', '-stdout', str(twice)], capture_output=True, text=True)
    check(text.returncode == 0 and 'Report' in text.stdout and 'Conclusion' in text.stdout, 'textutil no longer reads the report: %s' % text.stderr[-300:])

    paragraph = '<w:p><w:r><w:t xml:space="preserve">Synthetic text </w:t></w:r></w:p>'
    section = '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>'
    cases = {
        # No relationships of the document part yet, and a body that ends with its section properties.
        'no relationships yet': (paragraph + section, True, {}),
        # Section properties with nothing in them.
        'empty section properties': (paragraph + '<w:sectPr/>', True, {}),
        # A tracked change of the section holds a copy of the properties inside them.
        'a tracked section change': (paragraph + '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:sectPrChange w:id="1" w:author="a">'
                                     '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:sectPrChange></w:sectPr>', True, {}),
        # A section break inside the last paragraph is not the body's own section.
        'a section break in a paragraph': (paragraph + '<w:p><w:pPr><w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:pPr></w:p>', False, {}),
        # A body with no section properties at all, and one with nothing in it.
        'no section properties': (paragraph, False, {}),
        'white space before the end': (paragraph + section + '\n  ', True, {}),
    }
    for name, (body, section_last, _) in cases.items():
        source = work / ('%s.docx' % name)
        docx(source, body)
        target = work / ('%s after.docx' % name)
        shutil.copy(source, target)
        answer = insert(target)
        if check(answer == 'inserted', '%s: %s' % (name, answer)):
            inserted(name, source, target, images, sizes, section_last) if (source.read_bytes() and
                'word/_rels/document.xml.rels' in zipfile.ZipFile(source).namelist()) else None
            # Without relationships before, the comparison of the old relationships part does not apply.
            new_names, new = parts_of(target)
            found, last, count = figures(new['word/document.xml'])
            check(len(found) == 2, '%s: %d figures' % (name, len(found)))
            check((last == '{%s}sectPr' % W) == section_last, '%s: the body ends with %s' % (name, last))
            check([f[4] for f in found] == ([count - 3, count - 2] if section_last else [count - 2, count - 1]),
                  '%s: the figures are at %s of %d' % (name, [f[4] for f in found], count))
            relationships = {r.get('Id'): r.get('Target') for r in ET.fromstring(new['word/_rels/document.xml.rels'])}
            check(all(new.get('word/' + relationships.get(f[0], '?')) == image.read_bytes() for f, image in zip(found, images)),
                  '%s: a figure does not point at its image' % name)

    # Relationships and a jpeg type that are already there, an image of the same name, and another prefix.
    source = work / 'busy.docx'
    docx(source, (paragraph + section).replace('<w:', '<doc:').replace('</w:', '</doc:').replace(' w:', ' doc:'), prefix='doc',
         rels='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="%s"><Relationship Id="rId7" '
              'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/isix-figure-1.jpeg"/>'
              '<Relationship Id="other" Type="http://example.invalid/other" Target="other.xml"/></Relationships>' % PACKAGE,
         parts={'word/media/isix-figure-1.jpeg': b'an image that was there'})
    with zipfile.ZipFile(source) as archive:
        kept = {name: archive.read(name) for name in archive.namelist()}
    kept['[Content_Types].xml'] = CONTENT_TYPES.replace('</Types>', '<Default Extension="JPEG" ContentType="image/jpeg"/></Types>').encode()
    with zipfile.ZipFile(source, 'w') as archive:
        for name, data in kept.items():
            archive.writestr(name, data)
    target = work / 'busy after.docx'
    shutil.copy(source, target)
    answer = insert(target)
    if check(answer == 'inserted', 'a document with images of its own: %s' % answer):
        names, new = parts_of(target)
        check(new['word/media/isix-figure-1.jpeg'] == b'an image that was there', 'an image that was there was written over')
        check('word/media/isix-figure-2.jpeg' in names and 'word/media/isix-figure-3.jpeg' in names, 'the new images are %s' % names)
        ids = [r.get('Id') for r in ET.fromstring(new['word/_rels/document.xml.rels'])]
        check(ids == ['rId7', 'other', 'rId8', 'rId9'], 'the relationships are %s' % ids)
        check(new['[Content_Types].xml'].lower().count(b'extension="jpeg"') == 1, 'jpeg was given a second content type')
        check(b'<doc:p><doc:r><doc:drawing>' in new['word/document.xml'], "the paragraph is not in the document's own prefix")
        check(len(figures(new['word/document.xml'])[0]) == 2, 'the figures are not read back with another prefix')

    # What it cannot be sure of is refused, and the file is as it was.
    refusals = {}
    refusals['not an archive'] = work / 'not an archive.docx'
    refusals['not an archive'].write_bytes(b'this is not a ZIP archive' * 40)
    refusals['strict'] = work / 'strict.docx'
    docx(refusals['strict'], paragraph, namespace='http://purl.oclc.org/ooxml/wordprocessingml/main')
    refusals['no body'] = work / 'no body.docx'
    docx(refusals['no body'], paragraph)
    with zipfile.ZipFile(refusals['no body']) as archive:
        kept = {name: archive.read(name) for name in archive.namelist()}
    kept['word/document.xml'] = kept['word/document.xml'].replace(b'w:body', b'w:elsewhere')
    with zipfile.ZipFile(refusals['no body'], 'w') as archive:
        for name, data in kept.items():
            archive.writestr(name, data)
    refusals['no document part'] = work / 'no document part.docx'
    with zipfile.ZipFile(refusals['no document part'], 'w') as archive:
        archive.writestr('[Content_Types].xml', CONTENT_TYPES)
        archive.writestr('_rels/.rels', PACKAGE_RELS.replace('officeDocument"', 'somethingElse"'))
    for name, path in refusals.items():
        before = path.read_bytes()
        answer = insert(path)
        check(answer.startswith('refused'), '%s was not refused: %s' % (name, answer))
        check(path.read_bytes() == before, '%s was changed by a refused insertion' % name)
    missing = work / 'missing image.docx'
    docx(missing, paragraph + section)
    before = missing.read_bytes()
    check(insert(missing, [work / 'no such image.jpg'], [(340, 255)]).startswith('refused') and missing.read_bytes() == before,
          'an image that is not there was not refused, or the document changed')
    check(not list(work.glob('*.figures')), 'a file of the writing was left behind: %s' % list(work.glob('*.figures')))

    # A document that already has a figure of this kind - the shipped template after one insertion - and
    # one with none: relationship ids, image names and drawing ids of the second collide with nothing.
    with zipfile.ZipFile(twice) as archive:
        document = archive.read('word/document.xml')
        targets = [r.get('Target') for r in ET.fromstring(archive.read('word/_rels/document.xml.rels')) if r.get('Type', '').endswith('/image')]
    check(len(targets) == len(set(targets)) == 4, 'four figures have the images %s' % targets)
    check(len(set(re.findall(rb'<wp:docPr id="(\d+)"', document))) == 4, 'four figures do not have four drawing ids')

    # The report open in Word: nothing is written under it. `os.path.realpath` is how Word writes a path.
    import os
    report = work / 'REPORTS' / 'Synthetic study.docx'
    report.parent.mkdir()
    shutil.copy(root / 'Horos/Resources/ReportTemplate.docx', report)
    copy = work / 'Horos-inserted-report.docx'

    def guarded(running, *answer):
        shutil.copy(report, copy)
        before = copy.read_bytes()
        result = run('guard', copy, report, images[0], 'running' if running else 'quit', *answer)
        return result, copy.read_bytes() != before

    result, written = guarded(False)
    check(result.startswith('inserted asked=0') and written, 'with Word not running: %s' % result)
    result, written = guarded(True)
    check(result.startswith('inserted asked=1') and written, 'with a Word that has nothing open: %s' % result)
    result, written = guarded(True, '/somewhere/else/Synthetic study.docx', 'Document1')
    check(result.startswith('inserted asked=1') and written, 'with a Word that has a namesake and an unsaved document open: %s' % result)
    for spelling in (str(report), os.path.realpath(report)):
        result, written = guarded(True, '/somewhere/else/other.docx', spelling)
        check(result.startswith('failed asked=1') and 'open in Microsoft Word' in result and not written,
              'with the report open in Word as %s: %s, copy written %s' % (spelling, result, written))
    result, written = guarded(True, 'deaf')
    check(result.startswith('failed asked=1') and '-1712' in result and not written, 'with a Word that does not answer: %s' % result)

    # The application's own entry asks a Word that is running what it has open. This test sends Word
    # nothing: with Word running, the entry is left out and the result says so.
    word_running = subprocess.run(['pgrep', '-f', 'Microsoft Word.app/Contents/MacOS/Microsoft Word'], capture_output=True).returncode == 0
    if word_running:
        print("note: Microsoft Word is running; the application's own entry was not run, so as to send Word nothing")

    # A copy that cannot be written into: the application says so with the sentence it has, and the report is as it was.
    broken = work / 'Broken report.docx'
    broken.write_bytes(b'this is not a ZIP archive' * 40)
    before = broken.read_bytes()
    answer = None if word_running else run('report', broken, work / 'picture-0.png')
    check(word_running or (answer == 'failed: The selected images could not be inserted. The original report and the source images have been preserved.'
                           and broken.read_bytes() == before), 'a report that cannot be written into: %s' % answer)

    # The application's own entry: a .docx report takes its figures with no editor asked.
    report = work / 'Synthetic report.docx'
    shutil.copy(root / 'Horos/Resources/ReportTemplate.docx', report)
    answer = 'not run' if word_running else run('report', report, work / 'picture-0.png')
    if not word_running and check(answer == 'inserted', "the application's insertion into a .docx: %s" % answer):
        names, new = parts_of(report)
        media = [n for n in names if n.startswith('word/media/')]
        found, last, _ = figures(new['word/document.xml'])
        check(len(media) == 1 and new[media[0]][:2] == b'\xff\xd8', 'the report holds %s' % media)
        # 64 x 48 pixels in the box of 340 x 255 points.
        check([(f[1], f[2]) for f in found] == [(340 * 12700, 255 * 12700)], 'the figure of the report is %s' % [(f[1], f[2]) for f in found])
    check((work / 'picture-0.png').exists(), 'the source image is gone')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the figures of a .docx report are written into the document - image, relationship, type and an inline paragraph at '
      'the end of the body - with every other byte as it was, and what cannot be written into is refused untouched')
