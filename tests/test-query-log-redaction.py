#!/usr/bin/env python3
"""The Query/Retrieve log does not carry patient names, identifiers or accession numbers.

`NSLog` goes to the unified system log: every process of the user can read it,
and it travels in sysdiagnose reports. The Query/Retrieve code wrote into it the
patient identifier of every entry of a list query, the whole of a `DicomStudy`
(whose description lists its attributes), the patient name typed ahead in the
results, and the description, patient ID and accession number of everything it
auto-retrieved; the C-FIND summary wrote the value of every key it sent, and
the XML-RPC `Retrieve` wrote its whole filter when it found nothing.

The C-FIND summary is worth keeping - it is how one tells a node that ignored an
attribute from a query that never sent it - so its values now go through
`HorosQueryLog`, which writes technical values (modality, dates, UIDs) as they
are and every other value as its shape. That helper is compiled and run here;
the log calls of the Query/Retrieve sources are checked in source.

The standard output is not the system log, but it is on screen or in a
transcript when the application is started from a terminal or by a script, and
the service class users printed there the identifier of every C-FIND, C-MOVE and
C-GET (the values of the keys asked: a name, an ID, a birth date, an accession
number), the identifiers and status details answered, and a response that
could not be read. Those dumps now wait for a switch that is off unless the
user default DICOMDatasetDump is set; the progress lines stay. Checked in
source, in the DCMTK adapter and in its Swift callers.

The listener printed the same of what a peer asked it: the identifier of a
C-MOVE to the standard output, from its own move context, and that of a C-FIND
to the standard error, from DCMTK's find context, both for as long as DCMTK's
own log was at INFO - the level DCMTK starts it at, which only the set-up of
the first send lowered. The move context's prints now wait for the same
switch, handed to the listener in its settings, and the level of DCMTK's log
is set by one function, to WARN, or to INFO for the switch, as the process
starts, by each listener as it is made and by each send. Checked in source
here; test-listener-dataset-dump-switch.py runs a listener and asks it.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import network_log_scan

root = Path(__file__).resolve().parents[1]
failures = []
helper = root / 'Horos/Sources/QueryLog.swift'
# No Objective-C source logs queries any more.
sources = []
# The query nodes, the Query window and the XML-RPC interface are Swift.
node_sources = sorted(path.name for path in (root / 'Horos/Sources').glob('DCMTK*QueryNode*.swift'))
window_sources = sorted(path.name for path in (root / 'Horos/Sources').glob('QueryController*.swift'))
xmlrpc_sources = sorted(path.name for path in (root / 'Horos/Sources').glob('XMLRPCInterface*.swift'))
swift_sources = node_sources + window_sources + xmlrpc_sources

DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String) { print(key + "\t" + value) }

emit("name", QueryLog.term(key: "PatientsName", value: "DOE^JOHN"))
emit("nameWildcard", QueryLog.term(key: "PatientsName", value: "DO*"))
emit("id", QueryLog.term(key: "PatientID", value: "1"))
emit("accession", QueryLog.term(key: "AccessionNumber", value: "A123"))
emit("custom", QueryLog.term(key: "InstitutionName", value: "General"))
emit("birth", QueryLog.term(key: "PatientBirthDate", value: Date(timeIntervalSince1970: 0)))
emit("none", QueryLog.term(key: "PatientID", value: nil))
emit("null", QueryLog.term(key: "PatientID", value: NSNull()))
emit("modality", QueryLog.term(key: "ModalitiesinStudy", value: "CT\\MR"))
emit("level", QueryLog.term(key: "QueryRetrieveLevel", value: "STUDY"))
emit("uid", QueryLog.term(key: "StudyInstanceUID", value: "1.2.3"))
emit("date", QueryLog.term(key: "StudyDate", value: "20260101-20260131"))
emit("noKey", QueryLog.describe("DOE", forKey: nil))
emit("retrieve", QueryLog.describeRetrieveParameters([
    "serverName": "PACS", "retrieveMode": "1",
    "filterKey": "PatientID", "filterValue": "ID-1,ID-2",
    "filterKey2": "StudyDate", "filterValue2": "20260101"]))
'''

results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-query-log-') as directory:
        # Top-level statements are only allowed in a file called main.swift.
        (Path(directory) / 'main.swift').write_text(DRIVER)
        binary = Path(directory) / 'querylog'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(helper), str(Path(directory) / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the helper does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the helper driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {
        'name': 'PatientsName=<8 characters>',
        'nameWildcard': 'PatientsName=<3 characters, wildcard>',
        'id': 'PatientID=<1 character>',
        'accession': 'AccessionNumber=<4 characters>',
        'custom': 'InstitutionName=<7 characters>',
        'none': 'PatientID=<none>',
        'null': 'PatientID=<none>',
        'modality': 'ModalitiesinStudy=CT\\MR',
        'level': 'QueryRetrieveLevel=STUDY',
        'uid': 'StudyInstanceUID=1.2.3',
        'date': 'StudyDate=20260101-20260131',
        'noKey': '<3 characters>',
        'retrieve': 'serverName=PACS, retrieveMode=1, PatientID=<9 characters>, StudyDate=20260101',
    }
    for key, value in expected.items():
        if results.get(key) != value:
            failures.append('%s is %r, expected %r' % (key, results.get(key), value))
    birth = results.get('birth', '')
    if '1970' in birth or '1969' in birth or not birth.startswith('PatientBirthDate=<'):
        failures.append('a birth date that is not a string is written: %r' % birth)

# --- the log calls -------------------------------------------------------------
# What a log argument must not be: an accessor for a patient attribute, the text
# typed into the results, a raw filter value, or a whole study, node or filter
# dictionary (their descriptions carry the rest).
FORBIDDEN_ACCESSOR = re.compile(
    r'patientID|accessionNumber|theDescription|dateOfBirth|\bname\b|pressedKeys|customValue')
FORBIDDEN_BARE = {'study', 'item', 'identifier', 'value', 's', 'd', 'object', 'filters',
                  'paramDict'}
LOG = re.compile(r'NSLog\s*\(\s*@"((?:[^"\\]|\\.)*)"(.*)$')
# Arguments that look like patient data and are not: a list summary that counts
# identifiers, and a column identifier of the results table.
ALLOWED_ARGUMENT = ('HorosQueryLog', 'summaryForText:', 'PatientIdentifierList.summary(forText:')
ALLOWED_FORMAT = ('QR: item not found',)


def arguments(rest):
    """The top-level arguments after the format string of one NSLog line."""
    rest = rest.strip()
    if not rest.startswith(','):
        return []
    parts, depth, current = [], 0, ''
    for character in rest[1:]:
        if character in '([':
            depth += 1
        elif character in ')]':
            if depth == 0:
                break
            depth -= 1
        if character == ',' and depth == 0:
            parts.append(current.strip())
            current = ''
        else:
            current += character
    parts.append(current.strip())
    return parts


for name in sources:
    text = (root / 'Horos/Sources' / name).read_bytes().decode('latin1')
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        match = LOG.search(line)
        if not match:
            continue
        if any(allowed in match.group(1) for allowed in ALLOWED_FORMAT):
            continue
        for argument in arguments(match.group(2)):
            if any(allowed in argument for allowed in ALLOWED_ARGUMENT):
                continue
            if FORBIDDEN_ACCESSOR.search(argument) or argument in FORBIDDEN_BARE:
                failures.append('%s:%d logs %r' % (name, number, argument))

# In Swift, a log argument is an argument of NSLog or an interpolation in its format.
SWIFT_LOG = re.compile(r'NSLog\s*\(\s*"((?:[^"\\]|\\.)*)"(.*)$')
if len(node_sources) < 11:
    failures.append('the Swift query nodes are not all read: %s' % node_sources)
if len(window_sources) < 7:
    failures.append('the Query window\'s Swift files are not all read: %s' % window_sources)
if len(xmlrpc_sources) < 6:
    failures.append('the XML-RPC interface\'s Swift files are not all read: %s' % xmlrpc_sources)


def refused_swift_arguments(text):
    """The line and text of every log argument of `text` that may be patient data."""
    refused = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        match = SWIFT_LOG.search(line)
        if not match:
            continue
        if any(allowed in match.group(1) for allowed in ALLOWED_FORMAT):
            continue
        interpolated = re.findall(r'\\\((.*?)\)(?:&|"|$|\\)', match.group(1))
        for argument in arguments(match.group(2)) + interpolated:
            if any(allowed in argument for allowed in ALLOWED_ARGUMENT + ('QueryLog.',)):
                continue
            if FORBIDDEN_ACCESSOR.search(argument) or argument in FORBIDDEN_BARE:
                refused.append((number, argument))
    return refused


for name in swift_sources:
    for number, argument in refused_swift_arguments((root / 'Horos/Sources' / name).read_text()):
        failures.append('%s:%d logs %r' % (name, number, argument))

# The sources read here are the ones the scan of all the network sources knows
# this test to read (tests/network_log_scan.py, test-network-log-redaction.py),
# and they are read with its refusals too: besides a patient's value, a log
# argument of the Query/Retrieve sources is not a file, a URL as it is, nor
# the description of an error or of what a node said - a notice, the reason a
# retrieve stopped, what a method of the XML-RPC interface raised over its
# request. That scan reads calls that span lines, and is held to its controls
# here as well: a patient's value, the name of a file, a URL with its query
# string and the description of an error.
if sorted(swift_sources) != sorted(path.name for path in network_log_scan.query_sources()):
    failures.append('the Query/Retrieve sources read here are not those the scan of the network sources says this test reads')
for path in network_log_scan.query_sources():
    for number, argument in network_log_scan.refused_in(path, path.read_text()):
        failures.append('%s:%d logs %r' % (path.name, number, argument))
failures += network_log_scan.control_failures()
for line in ('NSLog("*** listener error: %@ %@", title, text)\nNSLog("---- %@", error.localizedDescription)',
             'NSLog("---- retrieve: the response in %@ stopped (%@)",\n      wantedSyntax, cut.error.localizedDescription)',
             'NSLog("---- excluded series %@ clicked: not retrieved", description)',
             'NSLog("****** no url : %@", baseURL + "&studyUID=\\(uid() ?? "(null)")&objectUID=\\(objectUID)")',
             'NSLog("%@", predicate.description)',
             'NSLog("%@", describe(error))\nNSLog("******* %@: %@", kind, exception.reason ?? kind)',
             'N2LogStackTraceMessage("URL is not valid: \\(address) \\(url.absoluteString)")'):
    if not network_log_scan.refused_arguments(line):
        failures.append('the scan of the network sources no longer refuses %r' % line)

# The scan reads a member called `name` as a patient's name whatever it belongs
# to, and no log call is excused from that. A failed association is logged with
# what failed and why: the first is a case of a closed set, and it is not called
# a name, so its log line passes without the scan giving anything up.
REFUSED_CONTROLS = (
    ('NSLog("---- %@: %@ (another level follows)", study.name, failure.reason)', 'study.name'),
    ('NSLog("---- %@: %@ (another level follows)", failure.name, failure.reason)', 'failure.name'),
    ('NSLog("---- \\(node.name): \\(failure.reason)")', 'node.name'),
    ('NSLog("---- retrieving %@", study.patientID)', 'study.patientID'),
)
for line, argument in REFUSED_CONTROLS:
    # An interpolation is read up to the end of the format: the text refused
    # holds the argument, and may hold more.
    if not any(argument in found for _, found in refused_swift_arguments(line)):
        failures.append('the scan no longer refuses %r in %r' % (argument, line))
ACCEPTED_CONTROL = 'NSLog("---- %@: %@ (another level follows)", failure.category.rawValue, failure.reason)'
if refused_swift_arguments(ACCEPTED_CONTROL):
    failures.append('the scan refuses the category and the reason of a failed association')
network = (root / 'Horos/Sources/DCMTKQueryNode+Network.swift').read_text()
if ACCEPTED_CONTROL not in network:
    failures.append('the failure of an attempt another level follows is no longer logged by category and reason')
declared = re.search(r'struct AssociationFailure: Error \{.*?\n\}', network, re.S)
if not declared or not re.search(r'enum Category: String \{', declared.group(0)) \
        or not re.search(r'^\s*let category: Category$', declared.group(0), re.M) \
        or re.search(r'\b(?:let|var) name\b', declared.group(0)):
    failures.append('what failed in an association is no longer a case of a closed set: '
                    'a free string there is text the log would write as it comes')

# A node's description is what `%@` writes for it anywhere in the log.
for name in ('DCMTKQueryNode.swift', 'DCMTKImageQueryNode.swift'):
    text = (root / 'Horos/Sources' / name).read_text()
    at = text.find('override var description: String')
    body = text[at:text.find('\n', text.find('{', at) + 1) + 80] if at >= 0 else ''
    body = body[:body.find('}') + 1] if '}' in body else body
    if not body:
        failures.append('%s has no description to check' % name)
    elif re.search(r'nameValue|accessionNumberValue|patientIDValue|dateValue|birthdateValue', body):
        failures.append('the description of %s carries patient data' % name)
    elif 'uidValue' not in body:
        failures.append('the description of %s no longer names the node by UID' % name)

# The C-FIND summary still says what was asked, through the helper.
node = (root / 'Horos/Sources/DCMTKQueryNode+Query.swift').read_text()
if node.count('QueryLog.term(key:') < 2 or 'C-FIND asks for' not in node:
    failures.append('the C-FIND summary no longer lists its terms through QueryLog')

# --- the standard output ---------------------------------------------------------
# A dataset is printed only inside a block whose opening statement asks the
# switch: not under `verbose`, which is always on, and not in an `else` of it.


def unguarded(text, call, guard):
    """The line of every `call` in `text` that no enclosing block opens on `guard`."""
    found = []
    at = text.find(call)
    while at >= 0:
        depth, index, guarded = 0, at, False
        while index > 0 and not guarded:
            index -= 1
            if text[index] == '}':
                depth += 1
            elif text[index] == '{':
                if depth:
                    depth -= 1
                else:
                    # The statement that opens this block: its line.
                    start = text.rfind('\n', 0, index) + 1
                    guarded = guard in text[start:index]
        if not guarded:
            found.append(text.count('\n', 0, at) + 1)
        at = text.find(call, at + 1)
    return found


DUMP_CONTROLS = (
    # (source, whether its dump is asked for)
    ('if (_dumpsDatasets) {\n    printf("REQUEST:\\n");\n    dataset->print(COUT);\n}\n', True),
    ('if (_dumpsDatasets && identifiers) {\n    identifiers->print(COUT);\n}\n', True),
    ('if (statusDetail) {\n    if (_dumpsDatasets) {\n        statusDetail->print(COUT);\n    }\n    delete statusDetail;\n}\n', True),
    ('if (_verbose) {\n    printf("REQUEST:\\n");\n    dataset->print(COUT);\n}\n', False),
    ('if (statusDetail) {\n    printf("  Status Detail:\\n");\n    statusDetail->print(COUT);\n}\n', False),
    ('if (_dumpsDatasets) {\n    printf("asked\\n");\n} else {\n    dataset->print(COUT);\n}\n', False),
    ('if (_dumpsDatasets) {\n    printf("asked\\n");\n}\ndataset->print(COUT);\n', False),
)
for source, asked in DUMP_CONTROLS:
    if bool(unguarded(source, '->print(COUT)', '_dumpsDatasets')) == asked:
        failures.append('the check of the dumps reads %r as %s' % (source, 'unasked' if asked else 'asked for'))

adapters = root / 'Horos/Sources/Adapters/DCMTK'
scu_adapter = (adapters / 'IsiXDCMTKQueryRetrieveSCU.mm').read_bytes().decode('latin1')
store_adapter = (adapters / 'IsiXDCMTKStoreSCU.mm').read_bytes().decode('latin1')
if scu_adapter.count('->print(COUT)') < 7:
    failures.append('the dumps of the Query/Retrieve adapter are not all found: %d' % scu_adapter.count('->print(COUT)'))
for number in unguarded(scu_adapter, '->print(COUT)', '_dumpsDatasets'):
    failures.append('IsiXDCMTKQueryRetrieveSCU.mm:%d prints a dataset to the standard output unasked' % number)
for number in unguarded(store_adapter, '->print(COUT)', 'IsiXDCMTKAssociationDumpsDatasets(self)'):
    failures.append('IsiXDCMTKStoreSCU.mm:%d prints a dataset to the standard output unasked' % number)
# --- what the listener serves, and DCMTK's own log ---------------------------------
# The C-MOVE the listener serves prints the identifier it was asked with, the
# identifiers it answers and status details only when the listener was opened
# with the switch. They used to wait for DCMTK's own log to be at INFO, which
# was read as a level nothing raises: it is the level DCMTK STARTS that log
# at. From the launch to the first send, which lowered it as a side effect,
# the listener printed the identifier of every C-MOVE a peer sent to the
# standard output, and DCMTK's own find context that of every C-FIND to the
# standard error. A block that opens on the level of the log waits for nothing.
move_context = (adapters / 'IsiXDCMTKMoveContext.mm').read_bytes().decode('latin1')
move_header = (adapters / 'IsiXDCMTKMoveContext.hpp').read_bytes().decode('latin1')
listener = (adapters / 'IsiXDCMTKQueryRetrieveSCP.mm').read_bytes().decode('latin1')
INFO = 'DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)'
MOVE_SWITCH = 'if (dumpsDatasets)'
if move_context.count('->print(COUT)') < 4:
    failures.append('the dumps of the C-MOVE the listener serves are not all found: %d' % move_context.count('->print(COUT)'))
for number in unguarded(move_context, '->print(COUT)', MOVE_SWITCH):
    failures.append('IsiXDCMTKMoveContext.mm:%d prints a dataset to the standard output unasked' % number)
MOVE_CONTROLS = (
    # (source, whether its dump is asked for)
    ('if (dumpsDatasets) {\n    printf("Move SCP Request Identifiers:\\n");\n    requestIdentifiers->print(COUT);\n}\n', True),
    ('if (dumpsDatasets) {\n    if (*stDetail) {\n        (*stDetail)->print(COUT);\n    }\n}\n', True),
    ('if (%s) {\n    requestIdentifiers->print(COUT);\n}\n' % INFO, False),
    ('if (%s) {\n    DIMSE_printCMoveRSP(stdout, response);\n    if (*stDetail) {\n        (*stDetail)->print(COUT);\n    }\n}\n' % INFO, False),
    ('if (!dumpsDatasets) {\n    requestIdentifiers->print(COUT);\n}\n', False),
    ('if (dumpsDatasets) {\n    printf("asked\\n");\n}\nrequestIdentifiers->print(COUT);\n', False),
)
for source, asked in MOVE_CONTROLS:
    if bool(unguarded(source, '->print(COUT)', MOVE_SWITCH)) == asked:
        failures.append('the check of the dumps of the C-MOVE reads %r as %s' % (source, 'unasked' if asked else 'asked for'))
# The switch of a move is off unless set, and set from the listener's own,
# which is the one its settings were given, NO unless set.
ASSIGNED = r'\bdumpsDatasets\s*=[^=][^;]*;'
if sorted(re.findall(ASSIGNED, move_header + move_context)) != ['dumpsDatasets = OFFalse;', 'dumpsDatasets = dumps;'] \
        or 'OFBool dumpsDatasets = OFFalse;' not in move_header:
    failures.append('the C-MOVE the listener serves does not start with its dump switch off, or takes it from more than its setter')
opened = listener[listener.find('- (instancetype)initWithSettings:'):listener.find('- (void)dealloc')]
if re.findall(ASSIGNED, listener) != ['dumpsDatasets = OFFalse;', 'dumpsDatasets = settings.dumpsDatasets ? OFTrue : OFFalse;'] \
        or '_listener->dumpsDatasets = settings.dumpsDatasets ? OFTrue : OFFalse;' not in opened \
        or listener.count('move.setDumpsDatasets(listener_.dumpsDatasets);') != 1 \
        or len(re.findall(r'\bIsiXDCMTKMoveContext move\(', listener)) != 1 \
        or not re.search(r'@implementation IsiXDCMTKListenerSettings\s*@end', listener):
    failures.append('the listener does not hand the C-MOVE it serves the dump switch of its settings, off unless set')

# Every print of a dataset in the DCMTK adapters, on the side that asks and on
# the side that serves, is in a source whose prints wait for a switch, or is
# one of the few named here that write to no output of the process.
DATASET_PRINTS = ('->print(', '.print(', 'PrintHelper', 'DIMSE_dumpMessage')
SWITCHED = {'IsiXDCMTKQueryRetrieveSCU.mm': '_dumpsDatasets', 'IsiXDCMTKStoreSCU.mm': 'IsiXDCMTKAssociationDumpsDatasets(self)',
            'IsiXDCMTKMoveContext.mm': MOVE_SWITCH}
ELSEWHERE = {
    'IsiXDCMTKQueryRetrieveSCU.mm': {
        'statusDetail->print(stream);': 'the status detail of a C-FIND, handed to its caller as a string, for the notice the person reads',
        'DIMSE_dumpMessage(dump, response, DIMSE_INCOMING);': 'the command of the last response of a retrieve, without a dataset, '
                                                              'kept as a string',
    },
    'IsiXDCMTKDataset.mm': {
        '_dataset->print(stream);': 'the text of a dataset, handed to its caller as a string',
        '_dataset->print(COUT);': '-printToStandardOutput, whose callers, in Swift, are read below',
    },
    'HorosStructuredReportBridge.cpp': {
        'impl_->document.print(out, flags)': 'a structured report, written to the stream its caller gives',
    },
}


def dataset_prints(name, text):
    """What is wrong with the prints of a dataset in the source `name`, and how many it has."""
    wrong, found, lines = [], 0, text.splitlines()
    for call in DATASET_PRINTS:
        found += text.count(call)
        if name in SWITCHED:
            numbers = unguarded(text, call, SWITCHED[name])
        else:
            numbers = [number for number, line in enumerate(lines, 1) if call in line and not line.lstrip().startswith('//')]
        for number in numbers:
            if not any(mark in lines[number - 1] for mark in ELSEWHERE.get(name, {})):
                wrong.append('%s:%d prints a dataset %s' % (name, number, 'unasked' if name in SWITCHED
                                                             else 'in a source whose prints wait for no switch'))
    return wrong, found


cxx_sources = {}
for folder in (root / 'Horos/Sources', root / 'Nitrogen/Sources'):
    for path in sorted(folder.rglob('*')):
        if path.is_file() and path.suffix in ('.mm', '.m', '.cpp', '.cc', '.hpp', '.h'):
            cxx_sources[path] = path.read_bytes().decode('latin1')
printed_datasets = {}
for path, text in cxx_sources.items():
    if 'dcmtk/' not in text and path.parent != adapters:
        continue
    wrong, found = dataset_prints(path.name, text)
    failures += wrong
    if found:
        printed_datasets[path.name] = found
if sorted(printed_datasets) != sorted(set(SWITCHED) | set(ELSEWHERE)):
    failures.append('the sources of the adapters that print a dataset are not the ones known: %r' % sorted(printed_datasets))
for name in ('IsiXDCMTKQueryRetrieveSCP.mm', 'IsiXDCMTKSCPDatabase.mm', 'IsiXDCMTKSCPDatabase.hpp', 'IsiXDCMTKGetUser.mm',
             'IsiXDCMTKMoveUser.mm', 'IsiXDCMTKMoveContext.hpp'):
    if not (adapters / name).is_file():
        failures.append('%s, of what the listener serves, is not there to be read' % name)
for name, marks in ELSEWHERE.items():
    for mark in marks:
        if mark not in (adapters / name).read_bytes().decode('latin1'):
            failures.append('%s no longer has the print %r, named as writing to no output' % (name, mark))
for name, source, refused in (
        ('IsiXDCMTKQueryRetrieveSCP.mm', 'if (verbose) {\n    identifiers->print(COUT);\n}\n', True),
        ('IsiXDCMTKSCPDatabase.mm', 'DCMQRDB_INFO("Find SCP Request Identifiers:" << OFendl << DcmObject::PrintHelper(*identifiers));\n', True),
        ('IsiXDCMTKGetUser.mm', 'DCMNET_WARN(DIMSE_dumpMessage(text, response, DIMSE_INCOMING, identifiers));\n', True),
        ('IsiXDCMTKMoveContext.mm', 'if (%s) {\n    stDetail->print(COUT);\n}\n' % INFO, True),
        ('IsiXDCMTKDataset.mm', 'query.print(COUT);\n', True),
        ('IsiXDCMTKDataset.mm', '        _dataset->print(stream);\n', False),
        ('IsiXDCMTKMoveContext.mm', 'if (dumpsDatasets) {\n    stDetail->print(COUT);\n}\n', False),
        ('IsiXDCMTKQueryRetrieveSCP.mm', '// identifiers->print(COUT);\nprintf("Move SCP Response %d\\n", count);\n', False)):
    if bool(dataset_prints(name, source)[0]) != refused:
        failures.append('the check of the prints of the adapters reads %r in %s as %s' % (source, name, 'asked for' if refused else 'unasked'))

# DCMTK's own log is the process's and is written to the standard error. One
# function sets its level, to WARN, or to INFO for the switch; nothing else
# sets a level, and nothing names INFO, DEBUG or TRACE but that function and
# the questions that ask whether a level is on.
SETS_LEVEL = re.compile(r'OFLog::\w*configure\w*\s*\(|\bsetLogLevel\s*\(|PropertyConfigurator|\bconfigureLogger\s*\(')
ASKS_LEVEL = re.compile(r'isEnabledFor\(OFLogger::\w+_LOG_LEVEL\)')
NAMES_LEVEL = re.compile(r'\b(?:TRACE|DEBUG|INFO)_LOG_LEVEL\b')
THE_LEVEL = 'OFLog::configure(dumpsDatasets ? OFLogger::INFO_LOG_LEVEL : OFLogger::WARN_LOG_LEVEL);'


def level_lines(text):
    """The lines of `text` that set the level of DCMTK's log, and those that
    name INFO, DEBUG or TRACE otherwise than to ask whether it is on."""
    lines = [line.strip() for line in text.splitlines() if not line.lstrip().startswith(('//', '*', '/*'))]
    return ([line for line in lines if SETS_LEVEL.search(line)],
            [line for line in lines if NAMES_LEVEL.search(ASKS_LEVEL.sub('', line))])


levels = {}
for path, text in cxx_sources.items():
    sets, names = level_lines(text)
    if sets or names:
        levels[path.name] = (sets, names)
if levels != {'IsiXDCMTKError.mm': ([THE_LEVEL], [THE_LEVEL])}:
    failures.append('the level of DCMTK\'s log is not set in one place alone, to WARN, or to INFO for the dump switch: %r' % levels)
for line, sets, names in (
        ('OFLog::configure(verbose ? OFLogger::DEBUG_LOG_LEVEL : OFLogger::WARN_LOG_LEVEL);', True, True),
        ('OFLog::configure(OFLogger::WARN_LOG_LEVEL);', True, False),
        ('dump.setLogLevel(dcmtk::log4cplus::DEBUG_LOG_LEVEL);', True, True),
        ('rootLogger.setLogLevel(level);', True, False),
        ('dcmtk::log4cplus::PropertyConfigurator::doConfigure(logger);', True, False),
        ('OFLog::configureFromCommandLine(command, application, OFLogger::TRACE_LOG_LEVEL);', True, True),
        ('const OFLogger::LogLevel wanted = OFLogger::INFO_LOG_LEVEL;', False, True),
        ('if (DCM_dcmnetLogger.isEnabledFor(OFLogger::DEBUG_LOG_LEVEL))', False, False),
        ('return DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL) ? OFTrue : OFFalse;', False, False),
        ('// OFLog::configure(OFLogger::DEBUG_LOG_LEVEL);', False, False)):
    if (bool(level_lines(line)[0]), bool(level_lines(line)[1])) != (sets, names):
        failures.append('the check of the level of DCMTK\'s log misreads %r' % line)
# That function is called where the DICOM network starts and by nothing that
# does not hand it the switch: as the application starts, by each listener
# before it opens its port, and by each send - which was the only one, so the
# level waited for the first send.
CONFIGURES = re.compile(r'^(?!void )[^\n/]*\bIsiXDCMTKConfigureLog\s*\(([^)]*)\)', re.M)
configured = {path.name: CONFIGURES.findall(text) for path, text in cxx_sources.items() if CONFIGURES.search(text)}
if configured != {'IsiXDCMTKError.mm': ['dumpsDatasets'], 'IsiXDCMTKQueryRetrieveSCP.mm': ['settings.dumpsDatasets'],
                  'IsiXDCMTKStoreSCU.mm': ['dumpsDatasets']}:
    failures.append('the level of DCMTK\'s log is not set by the application\'s start, each listener and each send alone, '
                    'each from the dump switch: %r' % configured)
error_adapter = cxx_sources[adapters / 'IsiXDCMTKError.mm']
if not re.search(r'\+ \(void\)configureDumpingDatasets:\(BOOL\)dumpsDatasets\n\{[^}]*IsiXDCMTKConfigureLog\(dumpsDatasets\);', error_adapter) \
        or not re.search(r'void IsiXDCMTKConfigureLog\(BOOL dumpsDatasets\)\n\{\n\s*%s\n\}' % re.escape(THE_LEVEL), error_adapter):
    failures.append('IsiXDCMTKLog no longer sets the level of DCMTK\'s log through the one function, from the switch it is given')
if 'IsiXDCMTKConfigureLog(settings.dumpsDatasets);' not in opened:
    failures.append('a listener no longer sets the level of DCMTK\'s log as it is made, before its port opens')
if not re.search(r'\+ \(void\)configureForSendingDumpingDatasets:\(BOOL\)dumpsDatasets deflateLevel:\(NSInteger\)level '
                 r'deflated:\(BOOL\)deflated\n\{[^}]*IsiXDCMTKConfigureLog\(dumpsDatasets\);', store_adapter) \
        or 'verbose' in store_adapter.lower():
    failures.append('the set-up of a send no longer sets the level of DCMTK\'s log from the dump switch, or can be told to be verbose')
# In Swift, each of the three is handed the user default and nothing else.
DUMP_SWITCH = 'preferences[NetworkPreferences.dumpsDICOMDatasets]'
app_swift = {path.name: path.read_text() for path in sorted((root / 'Horos/Sources').glob('*.swift'))}
START = 'IsiXDCMTKLog.configure(dumpsDatasets: PreferencesSource.process.' + DUMP_SWITCH + ')'
lifecycle = app_swift.get('ApplicationLifecycle.swift', '')
process = lifecycle[lifecycle.find('static func initializeProcess()'):lifecycle.find('private static func logMachine()')]
if [name for name, text in app_swift.items() if 'IsiXDCMTKLog.configure(' in text] != ['ApplicationLifecycle.swift'] \
        or lifecycle.count('IsiXDCMTKLog.configure(') != 1 \
        or not 0 <= process.find(START) < process.find('AppController.registerDCMTKCodecs()') < process.find('PluginManager()') \
        or 'restartSTORESCP' in process:
    failures.append('the level of DCMTK\'s log is no longer set once as the process starts, before the codecs, the plugins '
                    'and the listeners')
serving = app_swift.get('DCMTKQueryRetrieveSCP.swift', '')
if not 0 <= serving.find('settings.dumpsDatasets = ' + DUMP_SWITCH + '\n') < serving.find('IsiXDCMTKListener(settings: settings,'):
    failures.append('the listener is no longer opened with the dump switch of the user default')
sending = app_swift.get('DCMTKStoreSCU.swift', '')
if 'IsiXDCMTKAssociation.configureForSending(dumpsDatasets: ' + DUMP_SWITCH + ',' not in sending \
        or sum(text.count('configureForSending(') for text in app_swift.values()) != 1:
    failures.append('the send no longer sets the level of DCMTK\'s log from the dump switch, or something else sets it')


def unswitched_arguments(text):
    """Every `dumpsDatasets:` argument of Swift `text` that is not the user default."""
    return [given.strip() for given in re.findall(r'\bdumpsDatasets:\s*([^,)\n]*)', text) if not given.strip().endswith(DUMP_SWITCH)]


for name, text in app_swift.items():
    for given in unswitched_arguments(text):
        failures.append('%s hands DCMTK a dump switch that is not the user default: %r' % (name, given))
if unswitched_arguments('IsiXDCMTKLog.configure(dumpsDatasets: true)') != ['true'] \
        or unswitched_arguments('configureForSending(dumpsDatasets: verbose, deflateLevel: 6, deflated: false)') != ['verbose'] \
        or unswitched_arguments(START) or unswitched_arguments('configureForSending(dumpsDatasets: ' + DUMP_SWITCH + ', deflateLevel: 6)'):
    failures.append('the check of the switch DCMTK is handed no longer tells the user default from another value')
# The switch of an association is the one its parameters were given, NO unless set.
if re.findall(r'_dumpsDatasets\s*=[^=][^;]*;', scu_adapter) != ['_dumpsDatasets = parameters.dumpsDatasets;']:
    failures.append('the association does not take its dump switch from its parameters alone')
parameters = re.search(r'@implementation IsiXDCMTKAssociationParameters.*?@end', scu_adapter, re.S)
if not parameters or 'umpsDatasets' in parameters.group(0):
    failures.append('the parameters of an association no longer start with the dump switch off')

# In Swift: the switch is a user default that nothing registers, no pane shows
# and the application never writes; an association is given what it says and
# nothing else, and a dataset is printed only where it is asked.
swift = {path.name: path.read_text() for path in sorted((root / 'Horos/Sources').glob('*.swift'))}
preferences = (root / 'Modules/IsiXPreferences/Sources/NetworkPreferences.swift').read_text()
if not re.search(r'^\s*public static let dumpsDICOMDatasets = PreferenceKey<Bool>\("DICOMDatasetDump"\)$', preferences, re.M):
    failures.append('the dump switch is no longer an unregistered user default, off while never written')
SWITCH = 'preferences[NetworkPreferences.dumpsDICOMDatasets]'
for name, text in swift.items():
    if '"DICOMDatasetDump"' in text or re.search(r'\.set\([^\n]*dumpsDICOMDatasets', text):
        failures.append('%s writes the dump switch, or reads it by another name than its key' % name)
    for assigned in re.findall(r'\.dumpsDatasets\s*=[^=]\s*([^\n]*)', text):
        if assigned.strip() != SWITCH:
            failures.append('%s gives an association a dump switch that is not the user default: %r' % (name, assigned))
if 'parameters.dumpsDatasets = ' + SWITCH not in network:
    failures.append('the associations of the query nodes no longer take the dump switch')
printed = 0
for name, text in swift.items():
    printed += text.count('.printToStandardOutput()')
    for number in unguarded(text, '.printToStandardOutput()', SWITCH):
        failures.append('%s:%d prints a dataset to the standard output unasked' % (name, number))
if printed < 2:
    failures.append('the Swift callers that print a dataset are not all found: %d' % printed)
if unguarded('if verbose { response.printToStandardOutput() }', '.printToStandardOutput()', SWITCH) != [1] \
        or unguarded('if processGraph.%s { response.printToStandardOutput() }' % SWITCH, '.printToStandardOutput()', SWITCH):
    failures.append('the check of the Swift dumps no longer tells one asked for from one that is not')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the Query/Retrieve log names keys, shapes, counts and UIDs, never a patient name, '
      'identifier, accession number or birth date')
