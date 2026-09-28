#!/usr/bin/env python3
"""Custom views must lay their drawing out from their bounds, not the dirty rect.

Until macOS 13 AppKit clipped drawing to a view's bounds, so building the
geometry from the rectangle handed to drawRect: only misplaced content during a
partial redraw. Since macOS 14 NSView.clipsToBounds defaults to NO, so the same
code paints over everything around it.
"""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
roots = ['Horos/Sources', 'Nitrogen/Sources', 'Preference Panes', 'DCM Framework', 'DICOMPrint']
# Primitives that turn a rectangle into something drawn on screen.
primitives = ['NSMakeRect', 'NSRectFill', 'NSRectFillUsingOperation', 'NSFrameRect',
              'bezierPathWithRect:', 'bezierPathWithRoundedRect:', 'bezierPathWithOvalInRect:',
              'fillRect:', 'strokeRect:', 'drawInRect:', 'compositeToPoint:']
findings, checked = [], 0

for name in roots:
    folder = root / name
    if not folder.exists():
        continue
    for source in sorted(list(folder.rglob('*.m')) + list(folder.rglob('*.mm'))):
        text = source.read_bytes().decode('latin1')
        for m in re.finditer(r'-\s*\(void\)\s*drawRect:\s*\(NSRect\)\s*(\w+)[^{]*\{', text):
            param = m.group(1)
            checked += 1
            end = re.search(r'\n(?=[-+@]\s*[\(a-z])', text[m.end():])
            body = text[m.end(): m.end() + (end.start() if end else 6000)]
            # Reassigning the parameter from the view's own geometry is the fix,
            # and so is shadowing it with a local rectangle of the same name.
            if re.search(r'\b%s\s*=\s*(self\.bounds|\[self bounds\])' % param, body):
                continue
            if re.search(r'\bNSRect\s+%s\s*[;=]' % param, body):
                continue
            for line_no, line in enumerate(body.split('\n')):
                if line.lstrip().startswith('//'):
                    continue
                if not re.search(r'\b%s\b' % param, line):
                    continue
                if any(p in line for p in primitives):
                    findings.append('%s:%d: drawRect: builds drawing geometry from its %s parameter: %s'
                                    % (source.relative_to(root),
                                       text[:m.end()].count('\n') + 1 + line_no, param, line.strip()))

# The same rule for Swift views (#711 and the rest of the Swift track): an
# override of draw(_:) builds its geometry from bounds, not from its parameter.
swift_primitives = ['NSMakeRect', 'NSRect(', 'NSRectFill', 'NSFrameRect', 'NSBezierPath(rect:',
                    'NSBezierPath(roundedRect:', 'NSBezierPath(ovalIn:', 'RoundedRectPath(',
                    '.fill(', '.frame(', 'draw(in:', 'draw(at:']


def swift_body(text, start):
    """The text of the brace-delimited body that opens just before `start`."""
    depth = 1
    for index in range(start, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index]
    return text[start:]


for name in roots:
    folder = root / name
    if not folder.exists():
        continue
    for source in sorted(folder.rglob('*.swift')):
        text = source.read_text(errors='replace')
        for m in re.finditer(r'\bfunc\s+draw\(\s*_\s+(\w+)\s*:\s*NSRect\s*\)[^{]*\{', text):
            param = m.group(1)
            if text[text.rfind('\n', 0, m.start()) + 1:m.start()].lstrip().startswith(('//', '/*')):
                continue
            checked += 1
            body = swift_body(text, m.end())
            # Shadowing the parameter with a rectangle of the view's own is the fix.
            if re.search(r'\b(?:var|let)\s+%s\b' % param, body):
                continue
            for line_no, line in enumerate(body.split('\n')):
                if line.lstrip().startswith('//'):
                    continue
                if not re.search(r'\b%s\b' % param, line):
                    continue
                if any(p in line for p in swift_primitives):
                    findings.append('%s:%d: draw(_:) builds drawing geometry from its %s parameter: %s'
                                    % (source.relative_to(root),
                                       text[:m.end()].count('\n') + 1 + line_no, param, line.strip()))

print('checked %d drawRect: implementations' % checked)
if findings:
    print('FAIL:')
    for f in findings:
        print(' ', f)
    sys.exit(1)
print('PASS: every drawRect: lays out from the view, so nothing draws outside it '
      'now that macOS no longer clips to bounds')
