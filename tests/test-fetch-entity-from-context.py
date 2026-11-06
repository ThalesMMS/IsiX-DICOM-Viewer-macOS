#!/usr/bin/env python3
"""A fetch of the database goes by the entity's name, or by the context's model.

The application keeps a copy of the model in the database folder and opens the
index with a model merged from it, so the coordinator's model is another instance
than -[DicomDatabase managedObjectModel]. A fetch request with an entity of the
latter makes Core Data log that it "appears to be from a different
NSManagedObjectModel than this context's", and it could give a wrong result if the
two ever differ. NSFetchRequest(entityName:) resolves the name against the model of
the context that runs it.

The upgrade is left out: its contexts sit on coordinators it makes on those very
models. Reading the attributes of an entity is not a fetch; only `.entity =` counts.

What the rebuild does on such an index runs in test-database-rebuild-failure.py
(kept-cleanup-model). `<git revision>` as an optional argument reads the sources of
that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
# Horos/Sources and what is under it.
UPGRADE = 'DatabaseModelUpgrade'
ENTITY = re.compile(r'\.entity\s*=\s*.*(?:entitiesByName|managedObjectModel|\bentities\?\[)')


def sources():
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision, 'Horos/Sources'], text=True).splitlines()
        for name in names:
            if name.endswith(('.swift', '.m', '.mm')):
                shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{name}'], capture_output=True)
                yield name, shown.stdout.decode('utf-8', 'replace')
    else:
        for path in sorted((root / 'Horos/Sources').rglob('*')):
            if path.suffix in ('.swift', '.m', '.mm'):
                yield str(path.relative_to(root)), path.read_bytes().decode('utf-8', 'replace')


hits = []
for name, text in sources():
    if UPGRADE in name:
        continue
    for number, line in enumerate(text.splitlines(), 1):
        if ENTITY.search(line):
            hits.append(f'{name}:{number}: {line.strip()}')

if hits:
    print('FAIL: a fetch takes its entity from a model that may not be the context\'s:')
    print('\n'.join(hits))
    sys.exit(1)
print('PASS: no fetch outside the upgrade takes its entity from the database\'s model')
