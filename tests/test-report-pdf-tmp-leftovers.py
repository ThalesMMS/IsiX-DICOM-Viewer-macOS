#!/usr/bin/env python3
"""A report converted to a PDF in the temporary folder leaves nothing else there.

`-[DicomStudy saveReportAsPdfInTmp]` and its Swift form `reportPDFInTmp()`
(the DICOM PDF of a report, a report on a medium) take a name from
`-[NSFileManager tmpFilePathInTmp]`, which reserves it with mkstemp's empty
file, and write the PDF at that name with `.pdf` added. The empty file was never
removed: each conversion left a `file-XXXXXX` in the temporary folder.

The function is compiled here from its source, beside the real
`tmpFilePath(inDir:)` pointed at a folder of the test's own, with a study whose
conversion either writes a PDF, writes half of one and fails, or fails without
writing:

* a conversion that succeeds leaves the PDF it returns, and nothing else;
* a conversion that fails, with or without a half-written PDF, leaves nothing.

The callers are read too: the DICOM PDF removes the PDF it encapsulated.
"""
from pathlib import Path
import re
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  (the toolchain's leftovers go with the test)
from sources import source_text

failures = []


def body(text, signature):
    """The declaration that starts at `signature`, to its closing brace."""
    start = text.index(signature)
    open_brace = text.index('{', start)
    depth = 0
    for index in range(open_brace, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise ValueError(f'{signature} is not closed')


report = source_text('DicomStudy+Report')
nitrogen = source_text('NSFileManager+N2')
conversion = body(report, 'func reportPDFInTmp() throws -> String? {')
reservation = body(nitrogen, 'func tmpFilePath(inDir dirPath: String?) -> String {')

dicom = body(report, 'func writeReportAsDicom(atPath path: String?) throws {')
code = re.sub(r'//[^\n]*', '', dicom)
if 'removeItem(atPath: pdfPath)' not in code or code.index('defer') > code.index('encapsulateReportPDF'):
    failures.append('the DICOM PDF no longer removes the temporary PDF it encapsulated')

driver = r'''
import Foundation

let folder = CommandLine.arguments[1]

private func raise(_ name: NSExceptionName, _ reason: String) -> Never {
    fatalError("\(name.rawValue): \(reason)")
}

extension FileManager {
''' + reservation + r'''

    func tmpFilePathInTmp() -> String {
        tmpFilePath(inDir: folder)
    }
}

struct ConversionFailed: Error {}

enum Outcome { case pdf, halfWritten, nothingWritten }

final class Study {
    let outcome: Outcome
    init(_ outcome: Outcome) { self.outcome = outcome }

    func writeReportPDF(atPath path: String?) throws {
        let url = URL(fileURLWithPath: path!)
        switch outcome {
        case .pdf:
            try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: url)
        case .halfWritten:
            try Data("%PDF-1.4\n".utf8).write(to: url)
            throw ConversionFailed()
        case .nothingWritten:
            throw ConversionFailed()
        }
    }

''' + conversion + r'''
}

var failed = false
func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); failed = true }
}
func entries() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
}

do {
    let path = try Study(.pdf).reportPDFInTmp()
    let name = (path as NSString?)?.lastPathComponent ?? ""
    expect(name.hasSuffix(".pdf"), "the converted report is a .pdf: \(name)")
    expect(entries() == [name], "a conversion leaves only its PDF in the temporary folder: \(entries())")
    if let path { try? FileManager.default.removeItem(atPath: path) }
} catch {
    expect(false, "the conversion failed: \(error)")
}

for outcome in [Outcome.halfWritten, .nothingWritten] {
    do {
        _ = try Study(outcome).reportPDFInTmp()
        expect(false, "a failed conversion (\(outcome)) returned a PDF")
    } catch {
        expect(error is ConversionFailed, "the failure goes on to the caller: \(error)")
    }
    expect(entries().isEmpty, "a failed conversion (\(outcome)) leaves nothing in the temporary folder: \(entries())")
}

print(failed ? "FAILED" : "ok")
exit(failed ? 1 : 0)
'''

if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-report-pdf-tmp-') as temporary:
        work = Path(temporary)
        (work / 'main.swift').write_text(driver)
        binary = work / 'reportpdftmp'
        built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'ReportPDFTmp', str(work / 'main.swift'), '-o', str(binary)],
                               capture_output=True, text=True, timeout=600)
        if built.returncode != 0:
            failures.append('reportPDFInTmp() does not build on its own: ' + built.stderr[-2000:])
        else:
            folder = work / 'tmp'
            folder.mkdir()
            run = subprocess.run([str(binary), str(folder)], capture_output=True, text=True, timeout=120)
            if run.returncode != 0:
                failures.append((run.stdout + run.stderr).strip())

if failures:
    print('\n'.join(f if f.startswith('FAIL') else 'FAIL: ' + f for f in failures))
    raise SystemExit(1)
print('report PDF in the temporary folder: only the PDF after a conversion, nothing after a failure')
