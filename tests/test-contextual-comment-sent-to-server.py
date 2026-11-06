#!/usr/bin/env python3
"""The viewer's contextual comment menu tells a shared database the comment it sets.

The menu item writes its composed title as the series comment of the image
shown. A study of a shared database also has the server told, and that value
must be the same composed title: it used to be the comments panel's text field,
which holds whatever the panel last showed, so the server's comment differed
from the one written here until the next update of the index replaced it.

Reads the comment action of ViewerContextualMenuBuilder.swift.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
swift = (root / 'Horos/Sources/ViewerContextualMenuBuilder.swift').read_text()

start = swift.index('// same action as endSetComments, but with composedMenuTitle')
end = swift.index('viewer.buildMatrixPreview(false)', start)
action = swift[start:end]

if 'file?.series?.comment = composedMenuTitle' not in action:
    sys.exit('the menu must still write its composed title as the series comment:\n' + action)
sends = re.findall(r'\.object\(file, setValue: ([^,]+), forKey: "series\.comment"\)', action)
if not sends:
    sys.exit('the menu must tell a shared database the series comment:\n' + action)
for value in sends:
    if value.strip() != 'composedMenuTitle':
        sys.exit('the server is told %r, not the comment written here (composedMenuTitle)' % value.strip())
print('contextual comment: the server is told the comment set locally')
