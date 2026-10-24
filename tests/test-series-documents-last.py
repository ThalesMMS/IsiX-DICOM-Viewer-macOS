#!/usr/bin/env python3
"""The series of pictures come before the documents of a study.

Series are ordered by number, and a PDF, a structured report or a waveform
numbered 0 came before every image: an MR showed its documents at the top of
the viewer's series list. DicomStudy.imagesBeforeDocuments keeps the pictures
first and the documents after them, each in the order they came, and both the
viewer's list (imageSeries) and the database's thumbnails (allSeries, which
already moved the reports to the end) go through it.

The two functions are compiled from the source with stand-ins for the series
and the SOP class registry and run; the wiring is checked in the sources.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
study = (root / 'Horos/Sources/DicomStudy.swift').read_text()
browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('latin1')

start = study.index('    /// Whether a series of this SOP class holds pictures')
end = study.index('    @objc public dynamic func imageSeries()')
functions = study[start:end]

IMAGE, PDF, SR, ECG = '1.2.840.10008.5.1.4.1.1.4', '1.2.840.10008.5.1.4.1.1.104.1', '1.2.840.10008.5.1.4.1.1.88.22', '1.2.840.10008.5.1.4.1.1.9.1.1'
DRIVER = '''
import Foundation
final class DicomSeries: NSObject {
    @objc var seriesSOPClassUID: String?
    let label: String
    init(_ label: String, _ uid: String?) { self.label = label; seriesSOPClassUID = uid }
}
final class DCMAbstractSyntaxUID: NSObject {
    static func isImageStorage(_ uid: String?) -> Bool { ["%(image)s", "%(pdf)s"].contains(uid ?? "") }
    static func pdfStorageClassUID() -> String { "%(pdf)s" }
}
final class DicomStudy: NSObject {
%(functions)s
}
let given: [DicomSeries] = [DicomSeries("pdf-0", "%(pdf)s"), DicomSeries("sr-0", "%(sr)s"), DicomSeries("t1", "%(image)s"),
                            DicomSeries("ecg", "%(ecg)s"), DicomSeries("unknown", nil), DicomSeries("t2", "%(image)s")]
let sorted = DicomStudy.imagesBeforeDocuments(given as NSArray) as! [DicomSeries]
print(sorted.map(\\.label).joined(separator: ","))
''' % {'image': IMAGE, 'pdf': PDF, 'sr': SR, 'ecg': ECG, 'functions': functions}

with tempfile.TemporaryDirectory(prefix='horos-series-order-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), '-o', str(work / 'order')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the ordering does not compile:\n' + built.stderr[-1500:])
    else:
        out = subprocess.run([str(work / 'order')], capture_output=True, text=True, timeout=60).stdout.strip()
        if out != 't1,unknown,t2,pdf-0,sr-0,ecg':
            failures.append('pictures first, then documents, each in its order: got %r' % out)

pixels = study[study.index('public dynamic func imageSeriesContainingPixels'):study.index('    /// Whether a series of this SOP class holds pictures')]
if 'result = DicomStudy.imagesBeforeDocuments(newArray)' not in pixels:
    failures.append("the viewer's series list does not put the documents after the pictures")
children = browser[browser.index('if ([[item valueForKey:@"type"] isEqualToString:@"Study"])'):]
children = children[:children.index('@catch')]
if '[DicomStudy imagesBeforeDocuments: [item valueForKey:@"allSeries"]]' not in children:
    failures.append("the database's thumbnails do not put the documents after the pictures")

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: the series of pictures come before the documents, in the viewer and in the database')
