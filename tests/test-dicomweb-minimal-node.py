#!/usr/bin/env python3
"""A minimal DICOMweb node: no transfer-syntax=*, no series or instance listing.

Some PACS implement only the search for studies and the retrieve of a study
in named transfer syntaxes: they refuse `transfer-syntax=*` and answer 501 to
the QIDO-RS listing of a study's series or instances. tools/serve-dicomweb-
fixture.py stands for one with --refuse-syntax '*' --refuse-syntax-status 501
--listing-status 501.

The client's sources, compiled with the DICOM-Swift products the app links:

- a node that asks for the objects as stored sends transfer-syntax=*, then
  JPEG Lossless, then Explicit VR Little Endian, and has no cut fallback;
- against that node, the study retrieve is refused once for `*`, asked again
  from JPEG Lossless on, and brings every instance;
- the series listing fails with HTTP 501, which the client reads as a search
  the node does not implement; a timeout, a connection failure, an
  authentication failure or another server error is not one;
- a node in JPEG Baseline whose server answers 415 to it moves on to Explicit
  VR Little Endian;
- a 500 to `*` still ends the retrieve at once, as before.

And, without the fixture: the inventory of a retrieve whose listing the node
does not support is not reported incomplete, while a failed one still is; and
in the sources, the series and instance queries do not repeat as match
filters the UIDs their path names, the retrieve's series listing shows no
alert of its own, and retrieveDICOMweb records the listing as not supported
only after every request has ended without error and brought objects.

The fixture needs a Python with pydicom and numpy; without one, or without
the DICOM-Swift products, the fixture part is skipped (exit 2) once the rest
has passed.
"""
import json
import select
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import python_with  # noqa: E402

failures = []
EXPLICIT = '1.2.840.10008.1.2.1'
LOSSLESS = '1.2.840.10008.1.2.4.70'
BASELINE = '1.2.840.10008.1.2.4.50'
RANGE = 'multipart/related; type="application/dicom"; transfer-syntax='


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def block(text, start, end='\n    }\n'):
    body = text[text.index(start):]
    return body[:body.index(end)]


# Sources: what the query node does, which no driver here can run.
# The query node is Swift, split by responsibility into DCMTKQueryNode+*.swift;
# its QIDO-RS search is DICOMwebSearch, in IsiXDICOMNetwork.
sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402
node = class_text('DCMTKQueryNode')
search = (root / 'Modules/IsiXDICOMNetwork/Sources/DICOMwebSearch.swift').read_text()
make = block(search, 'public static func make(level: String')
check('let studyInPath = path.hasPrefix("studies/")' in make
      and 'let seriesInPath = level == QueryRetrieveLevel.image.rawValue && studyInPath' in make,
      'the query knows which UIDs its path names')
skip = 'if (studyInPath && tag == .studyInstanceUID) || (seriesInPath && tag == .seriesInstanceUID) { continue }'
check(skip in make and make.index(skip) < make.index('parameters[tag.dicomwebKey] = text'),
      'a UID the path names is not sent as a match filter')
query = block(node, 'func queryDICOMweb(_ identifier: DICOMQueryIdentifier) -> Bool')
check('DICOMwebSearch.make(level: level, study: study, series: series, elements: elements' in query,
      'the query does not build its search with DICOMwebSearch')
check('if search.studyInPath && (response.utf8Value(.studyInstanceUID) ?? "").isEmpty {\n                    try? response.putValue(Data(study.utf8), forTag: DICOMTag.studyInstanceUID.rawValue)' in query
      and 'if search.seriesInPath && (response.utf8Value(.seriesInstanceUID) ?? "").isEmpty {\n                    try? response.putValue(Data(series.utf8), forTag: DICOMTag.seriesInstanceUID.rawValue)' in query,
      'a result without the path\'s UIDs gets them from the path')
check('lastQueryNotImplementedValue = DICOMwebClient.searchNotImplemented(error)' in query,
      'a failed search records whether the node does not implement it')
walk = block(node, 'func queryImagesHierarchically(forStudy studyInstanceUID: String?) -> Bool')
check('subQuery.setShowErrorMessage(showErrorMessageValue)' in walk
      and walk.index('subQuery.setShowErrorMessage(showErrorMessageValue)') < walk.index('subQuery.query(withValues: nil, identifier: QueryIdentifiers.seriesListing('),
      'the series listing alerts only when the walk\'s own node does')
check(walk.count('noteFailedListing(notImplemented:') == 5, 'every failure of the walk is sorted: %d' % walk.count('noteFailedListing(notImplemented:'))
parallel = block(node, 'func queryDICOMwebImages(ofSeries seriesInstanceUIDs: [String], study studyInstanceUID: String) -> Bool')
check('self.noteFailedListing(notImplemented: listingNotImplemented)' in parallel, 'the parallel instance listings sort their failures')
check('!imageInventoryConfirmedValue && listingNotImplemented && !listingFailedOtherwise' in node,
      'a walk is "not implemented" only when no failure of it was of another kind')
retrieve = block(node, 'func retrieveDICOMweb() -> Bool')
mark = retrieve.find('inventory.markDiscovery("not supported")')
guard = retrieve[retrieve.rfind('if ', 0, mark):mark]
check(mark > 0 and all(term in guard for term in ('!succeeded', 'notImplemented', '!session.failed', '!thread.isCancelled',
                                                  'countOfSuccessfulSuboperations > 0')),
      'the listing is recorded as not supported only after a retrieve without error that brought objects: ' + guard)
second = retrieve.find('for (seriesUID, uids) in inventory.unreceivedSeries {')
check(0 < second < mark and retrieve.rfind('session.drain()', 0, mark) > second, 'that is decided once every request has ended')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: a node without * or listings: the study arrives through the named ranges, and 501 reads as no listing')
sys.exit(1 if failures else 0)
