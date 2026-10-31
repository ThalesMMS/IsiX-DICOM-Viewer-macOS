#!/usr/bin/env python3
"""What each transport does around publishing a file, and who may touch the queue.

Publishing is where a received file stops being the transport's. The order of
the steps around it is what the peer and the retrieve were promised, and a new
type in between makes it easy to lose:

- a C-STORE: the rename of DatabaseIngest is synchronous, nothing in it hops to
  another thread, its errno comes back to the session, and the adapter answers
  from that before it sets Success;
- DICOMweb: the identity checks come before the publication, and `queue.take` and
  `inventory.record` follow it at once, with nothing in between that could
  wait, so that a retrieve never asks twice for what it has;
- WADO-URI: hidden write, magic check, count, rename, in that order, so that the
  scan never sees a file that is not checked or not counted.

And what is left of the old way: no file of the app asks for the import of the
queue, imports it, or writes a received file into it, other than through
DatabaseIngest. What is left of direct_ingest (tools/swift-idiom-indicator.py)
is registered as exceptions with their reasons; the calls that move nothing are named
in FORWARDERS, with why. Who reaches the index and the folder at all, in the
app, its modules, Nitrogen and the legacy bridge, is tests/test-single-ingest-entry.py.
"""
from pathlib import Path
import importlib.util
import re
import sys

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def text(name):
    return (root / 'Horos/Sources' / name).read_text(encoding='utf-8')


def member(source, signature):
    at = source.index(signature)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


def in_order(source, what, *steps):
    places = [source.find(step) for step in steps]
    for step, place in zip(steps, places):
        check(place >= 0, f'{what}: {step!r} is gone')
    if all(place >= 0 for place in places):
        check(places == sorted(places), f'{what}: the order is no longer {steps}')


# --- C-STORE -----------------------------------------------------------------------
ingest = text('DatabaseIngest.swift')
publish = member(ingest, 'func publish(fileAt path: String, named name: String, into folder: IngestFolder, preset: IngestPreset) -> IngestPublication {')
code = indicator.swift_code(publish)
in_order(code, 'publishing', 'rename(path, destination)', 'failure = errno', 'IngestPublication(errorNumber: failure')
for word in ('Task', 'await', 'DispatchQueue', 'Thread', 'perform'):
    check(not re.search(r'\b' + word + r'\b', code), f'publishing is no longer synchronous: it uses {word}')
session = member(text('SCPDatabaseSession.swift'), 'func publishReceivedFile(atPath path: String) -> String? {')
in_order(session, 'the session', 'ingest.publish(fileAt: path', 'guard !publication.succeeded else { return nil }', 'publication.errorNumber')
check('(errno \\(failure))' in session, 'the refusal does not say errno')
adapter = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKSCPDatabase.mm').read_text(encoding='latin1')
store = adapter[adapter.index('OFCondition IsiXDCMTKSCPDatabaseHandle::storeRequest('):]
store = store[:store.index('\n}\n')]
in_order(store, 'the adapter', 'publishReceivedFileAtPath', 'status->setStatus(STATUS_Success)')

# --- DICOMweb ----------------------------------------------------------------------
take = member(text('DCMTKQueryNode+DICOMweb.swift'), 'func take(_ request: DICOMwebRetrieveRequest) -> DICOMwebRequestFailure?')
in_order(take, 'DICOMweb', 'DICOMwebRetrieveQueue.belongs(', 'client.accepts(retrievedTransferSyntax:', 'ingest.publish(fileAt: file',
         'unique.insert(objectUID)\n            queue.take(objectUID)', 'inventory.record(', 'node.synchronized {')
published = take[take.index('ingest.publish(fileAt: file'):take.index('let count: UInt = node.synchronized {')]
for word in ('await', 'Task', 'DispatchQueue', 'Thread.sleep', 'requestImport'):
    check(word not in indicator.swift_code(published), f'DICOMweb: {word} comes between the publication and the record of it')

# --- WADO-URI ----------------------------------------------------------------------
download = member(text('WADODownload.swift'), 'private func didFinishLoading(task: Int) {')
in_order(download, 'WADO', 'let draft = IngestDraft(', 'd.write(toFile: file, atomically: true)', 'WADORequestRules.looksLikeDICOM(head)',
         'ingest.discard(draft)', 'countOfSuccesses += 1', 'ingest.publish(draft, preset: .wado)')
hidden = indicator.swift_code((root / 'Modules/IsiXContracts/Sources/DICOMIngesting.swift').read_text(encoding='utf-8'))
check('"." + name' in (root / 'Modules/IsiXContracts/Sources/DICOMIngesting.swift').read_text(encoding='utf-8') and 'func hiddenPath' in hidden,
      'a draft is no longer hidden from the scan')

# --- who touches the queue ---------------------------------------------------------
QUEUE = re.compile(r'\bimportFiles\s*\(\s*fromIncomingDir\b|\bimportFilesFromIncomingDir\s*\('
                   r'|\.\s*initiateImportFilesFromIncomingDirUnlessAlreadyImporting\s*\(')
FORWARDERS = {
    'DatabaseIngest.swift': 'the single entry',
    'IncomingAdmission.swift': 'the dynamic methods themselves, one calling the next',
}
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    code = indicator.swift_code(path.read_text(encoding='utf-8'))
    for number, line in enumerate(code.split('\n'), 1):
        if QUEUE.search(line) and 'func ' not in line and path.name not in FORWARDERS:
            failures.append(f'{path.name}:{number} reaches the queue without DatabaseIngest')

# --- who converts -------------------------------------------------------------------
CONVERSION = re.compile(r'\b(?:compress|decompress)DicomFiles\s*\(|\binitiate(?:Compress|Decompress)Files\s*\('
                        r'|\.\s*(?:compress|decompress)Files\s*\(\s*atPaths|\.\s*processFiles\s*\(\s*atPaths|\bfilesRefused\s*\(byValidation')
CONVERTERS = {
    'DatabaseFileConversion.swift': 'the forwarders of the selectors, one calling the next',
    'DicomDatabase+DCMTK.swift': 'the forwarders of the selectors, one calling the next',
    'MediaImportJob.swift': 'the validation of a copy, which converts nothing',
}
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    if CONVERSION.search(indicator.swift_code(path.read_text(encoding='utf-8'))) and path.name not in CONVERTERS:
        failures.append(f'{path.name} converts without DatabaseFileConverting')
for retired in ('horos_compressDecompressThread', 'threadBridgeForProcessFiles', 'threadCompressDecompress'):
    for path in sorted((root / 'Horos/Sources').glob('*.swift')):
        if retired in path.read_text(encoding='utf-8'):
            failures.append(f'{path.name} still has {retired}')
# The selectors of the contract stay on the class, with nothing of the work.
MEMBER = re.compile(r'^    (?:@objc\([^)]*\) )?(?:private final |private |final )?(?:class )?(?:func|var) .*\{\n(.*?)^    \}\n', re.S | re.M)
for name, category in (('IncomingAdmission.swift', 'IncomingImport'), ('DatabaseFileConversion.swift', 'Compression'),
                       ('DicomDatabase+DCMTK.swift', 'DCMTK'), ('DicomFileIndexer.swift', 'Import'), ('ImportFeedback.swift', 'ImportAlerts')):
    source = text(name)
    forwarders = source[source.index(f'@objc({category}) @implementation extension DicomDatabase'):]
    for member in MEMBER.finditer(forwarders):
        if member.group(1).count('\n') > 6:
            failures.append(f'{name}: a member of the category does more than forward: {member.group(0).splitlines()[0].strip()}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: C-STORE, DICOMweb and WADO-URI keep their order around the publication; the rename is synchronous and its errno reaches the '
      f'peer; nothing but the single entry asks for or runs the import')
