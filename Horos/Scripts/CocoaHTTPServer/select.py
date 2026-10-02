#!/usr/bin/env python3
"""Select the original HTTP core sources out of the pinned CocoaHTTPServer source.

    select.py SOURCE MANIFEST DESTINATION

SOURCE is the tree Horos/Scripts/external-inputs.sh resolved for
CocoaHTTPServer. MANIFEST is cocoahttpserver/UPSTREAM.json: each core file and
the original license, with the place the wrappers include it from and its
SHA-256 upstream. DESTINATION receives them at those places, so that
`#include "upstream/HTTPServer.m"` in a wrapper finds the original through a
search path, and the original finds its own headers beside it.

A file that differs from the manifest stops the selection. A file already in
place with the same bytes is left alone, so that nothing is compiled again for
it; anything else found in the selected folder is removed.
"""
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath


def select(source: Path, manifest: Path, destination: Path):
    record = json.loads(manifest.read_text())
    wanted = {entry['path']: (name, entry['upstreamSHA256']) for name, entry in record['coreFiles'].items()}
    license = record['originalLicense']
    wanted[license['path']] = (record['license'], license['sha256'])
    folder = record['originalSourceDirectory']
    selected = {}
    for place, (name, digest) in wanted.items():
        path = PurePosixPath(place)
        if path.parts != (folder, path.name) or len(PurePosixPath(name).parts) != 1 or '..' in (folder, path.name, name):
            raise ValueError('unsafe HTTP core selection: ' + place)
        data = (source / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('%s differs from the pinned HTTP core source' % name)
        selected[path.name] = data
    target = destination / folder
    target.mkdir(parents=True, exist_ok=True)
    for path in target.iterdir():
        if path.name not in selected and (path.is_file() or path.is_symlink()):
            path.unlink()
    for name, data in selected.items():
        path = target / name
        if not path.is_file() or path.is_symlink() or path.read_bytes() != data:
            if path.is_symlink():
                path.unlink()
            path.write_bytes(data)
    return destination


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit('usage: select.py SOURCE MANIFEST DESTINATION')
    try:
        select(*map(Path, sys.argv[1:]))
    except (OSError, ValueError, KeyError) as error:
        sys.exit('error: HTTP core selection: %s' % error)
