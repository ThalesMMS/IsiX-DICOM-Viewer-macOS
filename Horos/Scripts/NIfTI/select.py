#!/usr/bin/env python3
"""Select the NIfTI-1 I/O library and znzlib out of the pinned nifti_clib source.

    select.py SOURCE MANIFEST DESTINATION

SOURCE is the tree Horos/Scripts/external-inputs.sh resolved for NIfTI. MANIFEST
is UPSTREAM.json: for each selected file, its place upstream, its size and its
SHA-256. DESTINATION receives those files side by side, which is how the two
sources include their headers and how the callers in Horos include them.

A file that differs from the manifest stops the selection. A file already in
DESTINATION with the same bytes is left alone, so that nothing is compiled
again for it; anything else found there is removed.
"""
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath


def select(source: Path, manifest: Path, destination: Path):
    files = json.loads(manifest.read_text())['files']
    selected = {}
    for name, record in files.items():
        relative = PurePosixPath(record['upstream_path'])
        if len(PurePosixPath(name).parts) != 1 or relative.is_absolute() or '..' in relative.parts:
            raise ValueError('unsafe NIfTI selection: ' + name)
        data = (source / relative).read_bytes()
        if len(data) != record['size'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError('%s differs from the pinned NIfTI selection' % record['upstream_path'])
        selected[name] = data
    destination.mkdir(parents=True, exist_ok=True)
    for path in destination.iterdir():
        if path.name not in selected and (path.is_file() or path.is_symlink()):
            path.unlink()
    for name, data in selected.items():
        path = destination / name
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
        sys.exit('error: NIfTI selection: %s' % error)
