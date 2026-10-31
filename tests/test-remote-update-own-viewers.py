#!/usr/bin/env python3
"""A shared database's index updates are held back only by its own viewers.

A viewer of a shared database reads the index it opened with, so neither an
update that is about to start (-initiateUpdate) nor one that has run
(-updateOnMainThread:) replaces the index while such a viewer is open. A
viewer of another database, a local one beside it, has nothing to do with
that index: -initiateUpdate used to refuse while any 2D viewer was open, so
with a local study's viewer open the shared database never updated.

Reads RemoteDicomDatabase.swift: both count the viewers through the same
helper, which compares each viewer's database with this one, and both ask
SharedIndexReplacement.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
swift = (root / 'Horos/Sources/RemoteDicomDatabase.swift').read_text()


def body(signature):
    start = swift.index(signature)
    depth, i = 0, swift.index('{', start)
    while True:
        depth += {'{': 1, '}': -1}.get(swift[i], 0)
        if depth == 0:
            return swift[start:i + 1]
        i += 1


helper = body('private static func openViewers(of database: ObjectIdentifier) -> Int')
if 'getDisplayed2DViewers()' not in helper or '.database.map(ObjectIdentifier.init) == database' not in helper:
    sys.exit('the helper must count only the viewers of this database:\n' + helper)

for signature in ('@objc public func initiateUpdate() -> Thread?', 'func updateOnMainThread(_ path: String?)'):
    method = body(signature)
    if 'Self.openViewers(of:' not in method or 'SharedIndexReplacement.replacesIndex(openViewersOfDatabase:' not in method:
        sys.exit('%s must count its own viewers and ask SharedIndexReplacement:\n%s' % (signature, method))
    if re.search(r'getDisplayed2DViewers\(\)\?\.count', method):
        sys.exit('%s still counts every 2D viewer' % signature)
print('shared index updates: held back only by viewers of the same database')
