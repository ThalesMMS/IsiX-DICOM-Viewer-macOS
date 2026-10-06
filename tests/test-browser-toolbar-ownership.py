#!/usr/bin/env python3
"""The browser's report icon keeps its date whole, and its toolbar and MPEG-2 icon are not leaked.

-setToolbarReportIconForItem: forces the report item to be rebuilt by storing
the seconds since 2001 in reportToolbarItemType, an int, which overflows
around 2069; the Swift translation truncated them to 32 bits. The ivar,
its accessors and the assignment are now NSInteger.

The Objective-C -setupToolbar assigned a new toolbar to the ivar without
releasing the previous one, and -matrixNewIcon:: never released the MPEG-2
image it allocated. Their Swift translations own neither: the toolbar reaches
the ivar through the retaining setter of BrowserController+SwiftIvars, which
releases the previous one, and the image is a Swift NSImage. The checks keep
it so.

Checked in the sources. `<git revision>` as an optional argument reads the
sources of that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    try:
        if revision:
            return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'],
                                           stderr=subprocess.DEVNULL).decode('utf-8')
        return (root / path).read_text(encoding='utf-8')
    except (subprocess.CalledProcessError, FileNotFoundError):
        failures.append('%s is missing' % path)
        return ''


def code(text):
    return '\n'.join(line.split('//')[0].rstrip() for line in text.split('\n'))


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


# The date of the report icon.
header = code(read('Horos/Sources/BrowserController.h'))
if not re.search(r'\bNSInteger\s+reportToolbarItemType;', header):
    failures.append('BrowserController.h does not keep reportToolbarItemType in an NSInteger')
ivars_h = code(read('Horos/Sources/BrowserController+SwiftIvars.h'))
if '@property(assign) NSInteger horos_reportToolbarItemType;' not in ivars_h:
    failures.append('BrowserController+SwiftIvars.h does not declare horos_reportToolbarItemType as NSInteger')
ivars_m = code(read('Horos/Sources/BrowserController+SwiftIvars.m'))
for accessor in ('-(NSInteger)horos_reportToolbarItemType', '-(void)setHoros_reportToolbarItemType:(NSInteger)value'):
    if accessor not in ivars_m:
        failures.append('BrowserController+SwiftIvars.m has no %s' % accessor)
reports = code(read('Horos/Sources/BrowserController+Reports.swift'))
icon = block(reports, '@objc(setToolbarReportIconForItem:)')
dated = re.findall(r'horos_reportToolbarItemType = ([^\n]*timeIntervalSinceReferenceDate[^\n]*)', icon)
if not dated:
    failures.append('-setToolbarReportIconForItem: no longer stores the date; this test needs a new look')
elif dated != ['Int(Date.timeIntervalSinceReferenceDate)']:
    failures.append('-setToolbarReportIconForItem: stores the date as %r, not whole' % dated[0])

# The toolbar: through the retaining setter, which releases the previous one.
toolbar = block(code(read('Horos/Sources/BrowserController+Toolbar.swift')), '@objc(setupToolbar)')
if not toolbar:
    failures.append('-setupToolbar is not in BrowserController+Toolbar.swift; this test needs a new look')
elif 'self.horos_toolbar = toolbar' not in toolbar or re.search(r'passRetained|\.retain\(\)', toolbar):
    failures.append('-setupToolbar does not hand its toolbar to the retaining setter alone')
setter = block(ivars_m, '-(void)setHoros_toolbar:(NSToolbar*)value')
if statements := [line.strip() for line in setter.split('\n') if line.strip() not in ('', '{', '}')]:
    if statements != ['[value retain];', '[toolbar release];', 'toolbar = value;']:
        failures.append('the toolbar setter does not release the previous toolbar: %r' % statements)
else:
    failures.append('BrowserController+SwiftIvars.m has no toolbar setter')

# The MPEG-2 icon: a Swift image, released with the scope.
preview = block(code(read('Horos/Sources/BrowserController+Preview.swift')), '@objc(matrixNewIcon::)')
mpeg2 = [line.strip() for line in preview.split('\n') if 'pathForImageResource("mpeg2")' in line]
if mpeg2 != ['img = Bundle.main.pathForImageResource("mpeg2").flatMap { NSImage(contentsOfFile: $0) }']:
    failures.append('-matrixNewIcon:: makes the MPEG-2 image as %r; it should be a Swift NSImage' % mpeg2)
elif re.search(r'passRetained|\.retain\(\)', preview):
    failures.append('-matrixNewIcon:: retains an object by hand')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the report icon keeps its date whole, and neither the toolbar nor the MPEG-2 icon is leaked')
