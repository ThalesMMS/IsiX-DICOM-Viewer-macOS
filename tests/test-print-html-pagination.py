#!/usr/bin/env python3
"""The HTML and XML reports print to a paginated PDF, without a printer or visible UI.

The Decompress service prints them (Decompress/ReportPDFRenderer.swift), on its
main thread, from the contents the application sends. Compiled here on its own
with a driver, it must:

1. print every page WebKit lays out - a page break per section, and a last page
   with only graphics, which is content and not a blank trailer - whatever
   print range an earlier print left in the shared print info;
2. keep the encoding the page declares (a Latin-1 page stays Latin-1);
3. answer nothing for a page it is given no time to print.

With the service built (decompress_service.py), the application's side
(DecompressService.updateReportPDF, through the tests' client) must also
replace <report>.pdf atomically from a fresh print, keep the previous PDF when
the report cannot be printed, never touch the report, and leave no staged file.

    python3 tests/test-print-html-pagination.py [--helper PATH]
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import decompress_service  # noqa: E402

driver = r'''
import AppKit
import PDFKit

final class Answer: @unchecked Sendable {
    var pdf: Data?
    var done = false
}

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
        exit(1)
    }
}

@MainActor func render(_ document: Data, _ mimeType: String, timeout: TimeInterval) -> Data? {
    let answer = Answer()
    ReportPDFRenderer.render(document, mimeType: mimeType, timeout: timeout) { pdf in
        DispatchQueue.main.async { answer.pdf = pdf; answer.done = true }
    }
    let deadline = Date().addingTimeInterval(60)
    while !answer.done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    check(answer.done, "no answer")
    return answer.pdf
}

_ = NSApplication.shared
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
// A stale previous print range must not truncate report conversion.
let shared = NSPrintInfo.shared.dictionary()
shared[NSPrintInfo.AttributeKey.allPages] = false
shared[NSPrintInfo.AttributeKey.firstPage] = 2
shared[NSPrintInfo.AttributeKey.lastPage] = 2

let html = try! Data(contentsOf: folder.appendingPathComponent("fixture.html"))
guard let printed = render(html, "text/html", timeout: 20), let document = PDFDocument(data: printed) else {
    check(false, "the report did not print"); exit(1)
}
check(document.pageCount == 3, "\(document.pageCount) pages")
check(document.page(at: 0)?.string?.contains("PRINT384-FIRST") == true, "first page")
check(document.page(at: 1)?.string?.contains("PRINT384-SECOND") == true, "second page")
let last = document.page(at: 2)!
check(last.numberOfCharacters == 0, "the last page has text")
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.drawPDFPage(last.pageRef!)
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
var red = 0
for i in 0..<(612 * 792) where pixels[i * 4] > 240 && pixels[i * 4 + 1] < 10 && pixels[i * 4 + 2] < 10 { red += 1 }
check(red > 10000, "a graphics-only final page is real content, not a blank trailer")

let latin = try! Data(contentsOf: folder.appendingPathComponent("latin1.html"))
guard let encoded = render(latin, "text/html", timeout: 20), let text = PDFDocument(data: encoded)?.string else {
    check(false, "the Latin-1 report did not print"); exit(1)
}
check(text.contains("Jos\u{E9} \u{C1}vila"), "the declared encoding was not kept: \(text)")

check(render(html, "text/html", timeout: 0) == nil, "a report given no time printed")
print("PASS: WebKit completion, 3 ordered pages including a graphics-only last page, stale-range reset, declared encoding, timeout")
exit(0)
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-print-384-html-') as temporary:
    folder = Path(temporary)
    fixture = folder / 'fixture.html'
    fixture.write_text('''<!doctype html><html><head><style>
.page { break-after: page; height: 200px; }</style></head><body>
<div class="page">PRINT384-FIRST</div><div class="page">PRINT384-SECOND</div>
<svg width="200" height="150"><rect width="200" height="150" fill="red"/></svg></body></html>''')
    (folder / 'latin1.html').write_bytes('<!doctype html><html><head><meta charset="iso-8859-1"></head>'
                                         '<body><p>José Ávila</p></body></html>'.encode('latin-1'))
    (folder / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0',
                    str(root / 'Decompress/ReportPDFRenderer.swift'), str(folder / 'main.swift'),
                    '-o', str(folder / 'check')], check=True, timeout=300)
    subprocess.run([str(folder / 'check'), str(folder)], check=True, timeout=120)

    client = decompress_service.helper(sys.argv[1:])
    if client is None:
        print('skipped part: the atomic update through the service needs the built Decompress service')
    else:
        original = fixture.read_bytes()
        derived = folder / 'fixture.html.pdf'
        previous = b'PREVIOUS-DERIVED-PDF'
        derived.write_bytes(previous)
        result = subprocess.run([str(client), str(fixture), 'pdfFromURL'], capture_output=True, timeout=120)
        if result.returncode != 0 or not derived.read_bytes().startswith(b'%PDF'):
            failures.append(f'the derived PDF was not replaced ({result.returncode}): {result.stderr[-400:]!r}')
        if fixture.read_bytes() != original:
            failures.append('the report itself changed')
        absent = folder / 'absent.html'
        retained = folder / 'absent.html.pdf'
        retained.write_bytes(previous)
        result = subprocess.run([str(client), str(absent), 'pdfFromURL'], capture_output=True, timeout=120)
        if result.returncode == 0 or retained.read_bytes() != previous:
            failures.append('a report that cannot be printed replaced the previous PDF')
        if [p.name for p in folder.iterdir() if p.name.startswith('horos-html-print-')]:
            failures.append('a staged PDF was left beside the report')
        if not failures:
            print('PASS: atomic refresh of the derived report through the service preserves the prior PDF on failure')

# The callers send their reports to the service and never trim graphics by character count.
renderer = (root / 'Decompress/ReportPDFRenderer.swift').read_text(encoding='utf-8')
if 'numberOfCharacters' in renderer or 'removePage' in renderer:
    failures.append('the renderer trims pages by their characters')
for name in ('BrowserController+DatabaseDragExport.swift', 'BrowserController+DatabaseDragExport+Selection.swift',
             'BrowserController+MovieExport.swift', 'DCMPix+EncapsulatedDocuments.swift', 'DicomFile+Formats.swift',
             'WebPortalConnection+Data.swift'):
    text = (root / 'Horos/Sources' / name).read_text(encoding='utf-8')
    if 'updateReportPDF(atPath:' not in text or 'pdfFromURL"' in text:
        failures.append(f'{name} does not print its report through the Decompress service')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
