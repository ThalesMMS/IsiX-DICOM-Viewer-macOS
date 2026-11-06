#!/usr/bin/env python3
"""The burner removes the report PDF it had converted in the temporary folder.

reportPDFInTmp() leaves the PDF it returns for the caller to remove. The burner
copies it onto the medium, or copies the original report when the conversion
gave nothing, and in either case the temporary PDF must not stay behind: every
study burned with a report used to leave one in $TMPDIR.

Reads the report block of BurnerWindowController.swift: after the copy, on both
branches, the path reportPDFInTmp() returned is removed.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
swift = (root / 'Horos/Sources/BurnerWindowController.swift').read_text()

start = swift.index('pdfPath = try study.reportPDFInTmp()')
end = swift.index('if self.cancelled {', start)
block = swift[start:end]

copy = block.index('manager.copyItem(atPath: pdfPath!')
removal = re.search(r'if let pdfPath \{ try\? manager\.removeItem\(atPath: pdfPath\) \}', block)
if removal is None:
    sys.exit('the burner must remove the temporary report PDF:\n' + block)
if removal.start() < copy:
    sys.exit('the temporary report PDF must be removed after its copy onto the medium')
# Outside the if/else, so the fallback copy of the original report removes it too.
def depth(text):
    return text.count('{') - text.count('}')
branch = block.index('if ((pdfPath as NSString?)?.length')
if depth(block[:removal.start()]) != depth(block[:branch]):
    sys.exit('the removal must follow both branches of the copy, at the depth of their if/else')
print('burner: temporary report PDF removed after the copy')
