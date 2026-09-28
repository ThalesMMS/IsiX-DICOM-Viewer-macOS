#!/usr/bin/env python3
"""Publish the generated Horos-Swift.h so that a plugin can use it on any machine.

swiftc writes into Horos-Swift.h an import of the bridging header by the absolute
path it had on the build machine. Every compatibility header of a class migrated
to Swift imports Horos-Swift.h, so a plugin built elsewhere failed with "file not
found" as soon as it imported one of them (#754).

This copies the generated header into each framework's Headers folder with that
import pointing at a Horos-Bridging-Header.h published beside it. The published
bridging header names its headers by file name, as the framework's other headers
do, and the headers it reaches that the framework did not publish yet (the DCM
framework, cocoahttpserver, a few preference panes and helpers) are published
with it, following their quoted imports.

    publish-swift-header.py SRCROOT GENERATED_HEADER HEADERS_DIR [HEADERS_DIR ...]
"""
from pathlib import Path
import re
import sys

srcroot = Path(sys.argv[1])
generated = Path(sys.argv[2]).read_text(encoding='utf-8')
destinations = [Path(p) for p in sys.argv[3:]]

absolute = re.compile(r'^(\s*#\s*(?:import|include)\s+)"(/[^"]*/Horos-Bridging-Header\.h)"', re.M)
match = absolute.search(generated)
if not match:
    # Nothing names the build machine: the header is published as it is.
    for headers in destinations:
        if headers.is_dir():
            (headers / 'Horos-Swift.h').write_text(generated, encoding='utf-8')
    sys.exit(0)
bridging = Path(match.group(2))

# The project's own header folders, searched by file name; Horos/Sources wins.
roots = ['Horos/Sources', 'Nitrogen/Sources', 'DCM Framework', 'cocoahttpserver',
         'Preference Panes', 'NSFont_OpenGL', 'LetsMoveAndDock', 'DICOMPrint']
index = {}
for root in roots:
    for header in sorted((srcroot / root).rglob('*.h')):
        index.setdefault(header.name, header)

quoted = re.compile(r'^(\s*#\s*(?:import|include)\s+)"([^"]+)"', re.M)


def flatten(text):
    """Quoted imports of the project's headers by file name, as they resolve
    inside Headers/; others ("UserNotifications/UserNotifications.h") stay."""
    def by_name(m):
        name = Path(m.group(2)).name
        return '%s"%s"' % (m.group(1), name) if name in index else m.group(0)
    return quoted.sub(by_name, text)


def read(path):
    data = path.read_bytes()
    try:
        return data.decode('utf-8'), 'utf-8'
    except UnicodeDecodeError:
        return data.decode('mac_roman'), 'mac_roman'


for headers in destinations:
    if not headers.is_dir():
        continue
    # A bridging-header import whose name the framework already gives to another
    # header - "Horos.h" is the class Horos in the project and the SDK's umbrella
    # header in the framework - is published under a name of its own.
    aliases = {}
    for name in quoted.findall(read(bridging)[0]):
        name = Path(name[1]).name
        published_copy = headers / name
        if name in index and published_copy.exists() and not name.startswith('HorosBridged-'):
            project = read(index[name])[0]
            if read(published_copy)[0] not in (project, flatten(project)):
                aliases[name] = 'HorosBridged-' + name
                (headers / aliases[name]).write_bytes(flatten(project).encode(read(index[name])[1]))
    # Headers the framework already publishes are read too: WebPortal.h, for one,
    # imports cocoahttpserver's HTTPServer.h, which it never published.
    pending = [bridging]
    seen = set()
    published = set()
    while pending:
        source = pending.pop()
        if source.name in seen:
            continue
        seen.add(source.name)
        text, encoding = read(source)
        target = headers / source.name
        if source == bridging:
            flat = quoted.sub(lambda m: '%s"%s"' % (m.group(1), aliases.get(Path(m.group(2)).name, Path(m.group(2)).name)), text)
            target.write_bytes(flat.encode(encoding))
            published.add(source.name)
        elif not target.exists() or flatten(text) != text:
            # A header published before with an import by a source-tree path
            # (HorosReportExtraction.h names "ThirdParty/Libarchive/archive.h")
            # is rewritten too: the path means nothing inside Headers/.
            target.write_bytes(flatten(text).encode(encoding))
            published.add(source.name)
        for name in quoted.findall(text):
            if '/' in name[1] and Path(name[1]).name not in index:
                continue
            name = Path(name[1]).name
            if source == bridging and name in aliases:
                # Published above under its alias; the framework's header of
                # that name is not the one the bridging header means.
                seen.add(name)
                continue
            if name in seen or name == 'Horos-Swift.h':
                continue
            if (headers / name).exists():
                pending.append(headers / name)
            elif name in index:
                pending.append(index[name])
            else:
                print('warning: %s imports %s, which is not in the project; not published' % (source.name, name))
    (headers / 'Horos-Swift.h').write_text(
        absolute.sub(lambda m: '%s"Horos-Bridging-Header.h"' % m.group(1), generated), encoding='utf-8')
    print('Published Horos-Swift.h and %d headers into %s' % (len(published), headers))
