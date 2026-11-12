#!/usr/bin/env python3
"""The log of a DICOM send names no file, patient or study description.

`NSLog` goes to the unified system log, which every process of the user can
read and which travels in sysdiagnose reports, and to the standard error, which
is on screen or in a transcript when the application is started from a terminal
or by a script. A send (the Send sheet, routing, the shared database, the web
portal, a plugin) wrote into them

  - the name of every file that did not arrive, with the report's detail, and
    the name of each file it decompressed;
  - the whole path of a file it could not read, to the standard error;
  - in routing, the path of every file of a batch that failed, the path of a
    queued file that is gone, the study description of each batch and the
    patient's name of a batch to try again.

A file the database copied is named by a number. One it indexed where it lies
(the database can be told not to copy), one read from a disc, or one a plugin
handed over keeps the name and the folders its owner gave it, and people name
files and folders after patients.

What the user is SHOWN is as it was: the alerts and the exception of
-[DCMTKStoreSCU run:] name each file that did not arrive. The log tells a file
by its place among the files of the send and the shape of its name, and a study
by its Study Instance UID.

Checked here: `StoreReport`, compiled and run, writes for the log what it writes
for the user with the names replaced; what failed in a send is a case of a
closed set, as the alerts title it; and no log call of the send's sources takes
a path, a file name, a patient's name, a study description or the reason the
user is shown. The scan reads calls that span lines, and controls hold it to
what it refuses.

A send to a DICOMweb node (STOW-RS) wrote its own report's detail: an instance
with no SOP Instance UID to be told by (a file that is not DICOM, one that
names no instance, and every file a cancelled send never read) by the name of
its file, and each reason as the user is shown it, which for a request the node
refused ends with what the node said. The node's words are its own: one that
refuses an instance or a query may quote the name, the identifier or the date
it was sent. The client itself wrote to the log the whole of what a node said
about any refused request, and the Warning of a search. The alert and the
activity panel still name the files and say what the node said; the log is told
an instance by its UID or by the place and the shape of the name of its file, a
refusal by its HTTP status or DICOM reason code, and what the node said by its
error code, its warn-code and its length.

Checked here for DICOMweb: no log call of the DICOMweb sources takes, besides
the above, a detail, a message, an error's description, or a reason, a Warning
or a body by those names; every result of a store that is not a success is
given a reason for the log made of a text of the client, a reason code or the
kind of an error; the report for the log takes the reasons for the log and no
file name. What the client writes is run against a node that refuses, with a
file named after a patient, in the test of the node's diagnostics.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import network_log_scan

root = Path(__file__).resolve().parents[1]
failures = []
sources = root / 'Horos/Sources'
network = root / 'Modules/IsiXDICOMNetwork/Sources'

# --- the report, compiled and run -----------------------------------------------
DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String) { print(key + "\t" + value.replacingOccurrences(of: "\n", with: " | ")) }

let report = StoreReport()
report.recordSent(path: "/db/DATABASE.noindex/10000/1.dcm", statusText: "status 0x0000 (Success)")
report.recordRejected(path: "/Volumes/CD/DOE^JOHN/DOE JOHN knee.dcm", statusText: "status 0xa700 (Refused: OutOfResources)")
report.recordUnreadable(path: "/Users/reader/Desktop/Maria Silva/IM1", reason: "No such file or directory")
report.recordNoPresentationContext(path: "/db/DATABASE.noindex/10000/4.dcm",
                                   sopClassUID: "1.2.840.10008.5.1.4.1.1.6.1 (US)", transferSyntax: "LittleEndianExplicit")
report.recordWithoutIdentity(path: "/exports/SILVA_MARIA_19700101.dcm")
emit("shown", report.detail(limit: 10))
emit("logged", report.logDetail(limit: 10))
emit("loggedBounded", report.logDetail(limit: 1))
emit("summary", report.summary)
emit("name", StoreReport.logName(ofFileAtPath: "/exports/SILVA_MARIA_19700101.dcm"))
emit("nameOfOne", StoreReport.logName(ofFileAtPath: "/a/b/x"))

let broken = StoreReport()
broken.recordSent(path: "/db/1.dcm", statusText: "status 0x0000 (Success)")
broken.recordSent(path: "/db/2.dcm", statusText: "status 0x0000 (Success)")
broken.recordTransportFailure(path: "/Volumes/CD/DOE^JOHN/third", reason: "DUL peer aborted")
emit("transport", broken.logDetail(limit: 10))

let clean = StoreReport()
clean.recordSent(path: "/Volumes/CD/DOE^JOHN/first", statusText: "status 0x0000 (Success)")
emit("clean", clean.logDetail(limit: 10))
emit("cleanSummary", clean.summary)
'''

results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-send-log-') as directory:
        # Top-level statements are only allowed in a file called main.swift.
        (Path(directory) / 'main.swift').write_text(DRIVER)
        binary = Path(directory) / 'report'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(sources / 'StoreReport.swift'), str(Path(directory) / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the report does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the report driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    shown, logged = results.get('shown', ''), results.get('logged', '')
    # The user is still told which files.
    for name in ('DOE JOHN knee.dcm: the node answered the C-STORE with status 0xa700',
                 'IM1: the file could not be read as DICOM',
                 'SILVA_MARIA_19700101.dcm: the file has no SOP Class and SOP Instance UID'):
        if name not in shown:
            failures.append('the detail the user is shown no longer says %r: %r' % (name, shown))
    # The log is told the same of each, without its name.
    renamed = shown
    for position, name in ((2, 'DOE JOHN knee.dcm'), (3, 'IM1'), (4, '4.dcm'), (5, 'SILVA_MARIA_19700101.dcm')):
        renamed = renamed.replace('  %s: ' % name, '  file %d <name of %d characters>: ' % (position, len(name)))
    if logged != renamed:
        failures.append('the detail for the log is not the detail shown with each name replaced by its place '
                        'and shape:\n  logged   %r\n  expected %r' % (logged, renamed))
    for text in ('logged', 'loggedBounded', 'transport', 'clean'):
        for word in ('DOE', 'JOHN', 'knee', 'Maria', 'Silva', 'SILVA', 'IM1', '.dcm', '/Volumes', '/Users', 'Desktop',
                     '/exports', 'DATABASE', 'third', 'first'):
            if word in results.get(text, word):
                failures.append('%s, written to the log, carries %r: %r' % (text, word, results.get(text)))
    if results.get('summary', '') not in logged or 'and 3 more' not in results.get('loggedBounded', ''):
        failures.append('the detail for the log lost its summary or its bound: %r' % results.get('loggedBounded'))
    if 'file 3 <name of 5 characters>: the transmission failed — DUL peer aborted' not in results.get('transport', ''):
        failures.append('a file is not told by its place among those attempted: %r' % results.get('transport'))
    if results.get('clean') != results.get('cleanSummary'):
        failures.append('a send with nothing missing is not logged as its summary: %r' % results.get('clean'))
    if results.get('name') != '<name of 24 characters>' or results.get('nameOfOne') != '<name of 1 character>':
        failures.append('the name of a file is not written as its shape: %r, %r'
                        % (results.get('name'), results.get('nameOfOne')))

# --- what failed is a case of a closed set ------------------------------------
scu = (sources / 'DCMTKStoreSCU.swift').read_text()
declared = re.search(r'struct StoreSendFailure: Error \{.*?\n\}', scu, re.S)
body = declared.group(0) if declared else ''
if not body or not re.search(r'enum Category: String \{', body) \
        or not re.search(r'^\s*let category: Category$', body, re.M) \
        or re.search(r'\b(?:let|var) name\b', body):
    failures.append('what failed in a send is no longer a case of a closed set: a free string there is text '
                    'the alerts and the log would write as it comes')
# The titles are what the alerts show and what -run: names its exception.
for case, title in (('store', 'DICOM Network Failure (STORE-SCU)'), ('secureStore', 'DICOM Network Failure (STORE-SCU TLS)'),
                    ('network', 'DICOM Network Failure'), ('generic', 'NSGenericException')):
    if not re.search(r'^\s*case %s = "%s"$' % (case, re.escape(title)), body, re.M):
        failures.append('the failure of a send is no longer titled %r' % title)
if not re.search(r'^\s*let reason: String$', body, re.M) or not re.search(r'^\s*let logReason: String$', body, re.M):
    failures.append('the failure of a send no longer keeps what the user is shown apart from what the log writes')
if not re.search(r'recorded = StoreSendFailure\(category: \.store, reason: report\.detail\(limit: 5\), '
                 r'logReason: report\.logDetail\(limit: 5\)\)', scu):
    failures.append('the failure of a send with files missing does not take the detail shown and the detail for the log')

# The user is shown the reason that names the files; the log is handed the other.
transport = (sources / 'ActivitySendTransport.swift').read_text()
delivery = (sources / 'DatabaseRoutingDelivery.swift').read_text()
queue = (network / 'RoutingQueue.swift').read_text()
if 'failure.category.rawValue, failure.reason)' not in transport or 'runCritical(' not in transport:
    failures.append('the alert of a send no longer shows what failed and the reason that names the files')
if 'failure.name, failure.reason, aet, address, port))' not in delivery:
    failures.append('the alert of a routed send no longer shows what failed and the reason that names the files')
if 'RoutingSendFailure(name: failure.category.rawValue, reason: failure.reason, logReason: failure.logReason)' not in delivery:
    failures.append('a routed send does not hand the routing queue the reason for the log beside the reason shown')
routed = re.search(r'public struct RoutingSendFailure: Sendable, Hashable \{.*?\n\}', queue, re.S)
if not routed or 'public var logReason: String' not in routed.group(0) or 'logReason ?? reason' not in routed.group(0):
    failures.append('the failure of a routed send no longer carries a reason for the log')

# --- the log calls ------------------------------------------------------------
# What writes to the unified log, the standard error or the standard output.
CALL = re.compile(r'\b(NSLog|storeSCUDiagnostic|print|standardError\.write)\s*\(')
# What an argument must not be: a path or a file's name, a list of them, a
# patient's name or identifier, a study description, a birth date, an accession
# number, the reason or the report's detail the user is shown (they name the
# files), or a member called `name` whatever it belongs to.
FORBIDDEN = re.compile(
    r'patientID|patientName|accessionNumber|theDescription|studyName|studyDescription|dateOfBirth|\bname\b'
    r'|[Pp]aths?\b(?!\.count)|lastPathComponent|\bfiles\b(?!\.count)|filesToSend(?!\.count)'
    r'|\.reason\b|\.detail\(')
# Read as patient data and not: the name DCMTK gives a transfer syntax UID.
ALLOWED = ('IsiXDCMTKUIDs.name(ofUID:',)


def scan(text, at):
    """From just after an opening parenthesis: the index of its closing one, its
    top-level arguments with their string literals emptied, and the
    interpolations of those literals, each read the same way."""
    arguments, interpolations, current, depth = [], [], '', 0
    while at < len(text):
        character = text[at]
        if character == '"':
            at += 1
            while at < len(text) and text[at] != '"':
                if text.startswith('\\(', at):
                    at, inner, deeper = scan(text, at + 2)
                    interpolations.append(', '.join(inner))
                    interpolations += deeper
                    at += 1
                elif text[at] == '\\':
                    at += 2
                else:
                    at += 1
            current += '""'
            at += 1
            continue
        if character in '([{':
            depth += 1
        elif character in ')]}':
            if depth == 0:
                break
            depth -= 1
        if character == ',' and depth == 0:
            arguments.append(current.strip())
            current = ''
        else:
            current += character
        at += 1
    arguments.append(current.strip())
    return at, arguments, interpolations


def refused_arguments(text, forbidden=FORBIDDEN):
    """The line and text of every log argument of `text` that may name a file or a patient."""
    refused = []
    for call in CALL.finditer(text):
        start = text.rfind('\n', 0, call.start()) + 1
        before = text[start:call.start()]
        if before.lstrip().startswith('//') or re.search(r'\bfunc\s+$', before):
            continue
        _, arguments, interpolations = scan(text, call.end())
        for argument in arguments + interpolations:
            considered = argument
            for allowed in ALLOWED:
                considered = considered.replace(allowed, '')
            if forbidden.search(considered):
                refused.append((text.count('\n', 0, call.start()) + 1, argument))
    return refused


send_sources = sorted(sources.glob('DCMTKStoreSCU*.swift'))
if len(send_sources) < 3:
    failures.append('the Swift files of the send are not all read: %s' % [path.name for path in send_sources])
send_sources += [sources / name for name in ('StoreReport.swift', 'ActivitySendTransport.swift', 'DatabaseRoutingDelivery.swift',
                                             'BonjourPublisher.swift', 'IsiXNetworkAdapter.swift')]
send_sources += [network / name for name in ('RoutingQueue.swift', 'RoutingSelection.swift', 'DICOMSendQueue.swift')]
# The sources read here are the ones the scan of all the network sources knows
# this test to read (tests/network_log_scan.py, test-network-log-redaction.py).
if set(send_sources) != set(network_log_scan.send_sources()):
    failures.append('the sources of the send read here are not those the scan of the network sources says this test reads')
scanned = {path: path.read_text() for path in send_sources}
# The send of the web portal, in a file that logs much else.
portal = (sources / 'WebPortalConnection+Data.swift').read_text()
at = portal.find('func sendImagesToDicomNodeThread(')
portal_send = portal[at:portal.find('\n    @objc(', at)] if at >= 0 else ''
if 'DCMTKStoreSCU(' not in portal_send:
    failures.append('the send of the web portal is not found')
scanned[sources / 'WebPortalConnection+Data.swift (sendImagesToDicomNodeThread)'] = portal_send

calls = 0
for path, text in scanned.items():
    calls += len(CALL.findall(text))
    for number, argument in refused_arguments(text):
        failures.append('%s:%d logs %r' % (path.name, number, argument))
if calls < 60:
    failures.append('the scan found %d log calls in the sources of the send, fewer than they hold' % calls)

# The scan refuses what the send used to log, on one line or on two.
REFUSED_CONTROLS = (
    ('NSLog("********* Store Exception: %@", stopped.reason)', 'stopped.reason'),
    ('NSLog("DCMTKStoreSCU: %@", report.detail(limit: 20))', 'report.detail(limit: 20)'),
    ('NSLog("SEND - decompress: %@", (path as NSString).lastPathComponent)', 'lastPathComponent'),
    ('storeSCUDiagnostic("Bad DICOM file: \\(path): \\(error.conditionText)")', 'path'),
    ('storeSCUDiagnostic("No SOP Class & Instance UIDs in file: \\(copyPath)")', 'copyPath'),
    ('FileHandle.standardError.write(Data("\\(file.path ?? "(null)")\\n".utf8))', 'file.path'),
    ('NSLog("**** Autorouting error reported for %@@%@:%@ - %@", aet, address, port, failure.reason)', 'failure.reason'),
    ('NSLog("%@", (failure?.name ?? "") as NSString)', 'failure?.name'),
    ('NSLog(" Autorouting: %@ - %@", first.study.studyName ?? "(null)", Self.count(batch.count, "object", "objects"))',
     'first.study.studyName'),
    ('NSLog("Autorouting for %@ : failure count: %d", first.study.patientName ?? "(null)", order.failureRetry)',
     'first.study.patientName'),
    ('NSLog("Autorouting FAILED : %@ - %@", failure.logReason, batch.compactMap(\\.path).joined(separator: ", "))', '\\.path'),
    ('NSLog(" Autorouting: not sending %@ - the file is not there",\n          file.path ?? "(null)")', 'file.path'),
    ('NSLog("IsiX plugin send: %@ to %@", paths, id)', 'paths'),
    ('NSLog("sending %@", files)', 'files'),
    ('print("sending \\(node.name): \\(IsiXDCMTKUIDs.name(ofUID: uid) ?? "(null)")")', 'node.name'),
)
for line, argument in REFUSED_CONTROLS:
    if not any(argument in found for _, found in refused_arguments(line)):
        failures.append('the scan no longer refuses %r in %r' % (argument, line))
# And accepts what the send logs now.
ACCEPTED_CONTROLS = (
    'NSLog("********* Store Exception: %@", stopped.logReason)',
    'NSLog("DCMTKStoreSCU: %@", report.logDetail(limit: 20))',
    'NSLog("SEND - decompress: %@", loggedName)',
    'storeSCUDiagnostic("Bad DICOM file: \\(loggedName): \\(error.conditionText)")',
    'NSLog("**** Autorouting error reported for %@@%@:%@ - %@", aet, address, port, failure.logReason)',
    'NSLog("%@", (failure?.category.rawValue ?? "") as NSString)',
    'NSLog("Autorouting FAILED : %@ - %@ of study %@", failure.logReason, Self.count(batch.count, "file", "files"), study)',
    'NSLog("IsiX plugin send: %lu files to %@", UInt(paths.count), id)',
    'print("------ Warning! Recompression: \\(IsiXDCMTKUIDs.name(ofUID: syntax.uid) ?? "(null)")")',
)
for line in ACCEPTED_CONTROLS:
    if refused_arguments(line):
        failures.append('the scan refuses %r: %r' % (line, refused_arguments(line)))
for line, where in ((ACCEPTED_CONTROLS[0], scu), (ACCEPTED_CONTROLS[1], scu),
                    (ACCEPTED_CONTROLS[2], scanned[sources / 'DCMTKStoreSCU+File.swift']),
                    (ACCEPTED_CONTROLS[4], delivery), (ACCEPTED_CONTROLS[5], scanned[sources / 'BonjourPublisher.swift']),
                    (ACCEPTED_CONTROLS[6], queue)):
    if line not in where:
        failures.append('the send no longer logs %r' % line)
# The send of the web portal has no one to show what ended it to: its log line
# is given the reason for the log by the send, and nothing else.
logging = re.search(r'\n    func sendLoggingFailure\(_ log: \(String\) -> Void\) \{\n(.*?)\n    \}\n', scu, re.S)
if '.sendLoggingFailure { NSLog("Error: [WebServiceConnection sendImagesToDicomNodeThread:] %@", $0) }' not in portal_send \
        or '.run(nil)' in portal_send or not logging \
        or [line.strip() for line in logging.group(1).splitlines()] != ['if let failure = sendReportingFailure() {',
                                                                        'log(failure.logReason)', '}']:
    failures.append('the send of the web portal logs the exception of -run:, whose reason names the files')

# --- the scan every network source is read with -----------------------------------
# Besides a file, a patient and a description of a study, a log argument of the
# send is not a URL as it is, nor the description of an error or of what a peer
# said: the sources of the send, of the DICOMweb send and the send of the web
# portal are read with the refusals every network source is read with, held to
# their controls here too - a patient's value, the name of a file, a URL with
# its query string and the description of an error.
for path in send_sources + sorted(sources.glob('DICOMweb*.swift')):
    for number, argument in network_log_scan.refused_in(path, path.read_text()):
        failures.append('%s:%d logs %r' % (path.name, number, argument))
for number, argument in network_log_scan.refused_arguments(portal_send):
    failures.append('WebPortalConnection+Data.swift (sendImagesToDicomNodeThread), call %d, logs %r' % (number, argument))
failures += network_log_scan.control_failures()
for line in ('NSLog("Shared database: request from %@ ended: %@", address, error.localizedDescription)',
             'NSLog("IsiX plugin %@ XML-RPC method %@ failed: %@", id, methodName, String(describing: thrown))',
             'NSLog("********* Store Exception: %@", error.localizedDescription)',
             'throw _rejectRequest(String(format: "a path outside the database that no image links to, among %@", linkedPaths))',
             'NSLog("DICOMweb send to %@", node.url.absoluteString)'):
    if not network_log_scan.refused_arguments(line):
        failures.append('the scan of the network sources no longer refuses %r' % line)

# --- the DICOMweb send ---------------------------------------------------------
# Besides the above, what a log argument of the DICOMweb sources must not be:
# the detail or the status line the user is shown, a message or an error's
# description (they end with what the node said), and a reason, a Warning or a
# body by those names, which is how the node's own words are called there.
DICOMWEB_FORBIDDEN = re.compile(FORBIDDEN.pattern + r'|\bdetail\b|statusLine|\bmessage\b|localizedDescription'
                                r'|\breason\b|\bwarning\b|\bbody\b|bodyPreview')
dicomweb_sources = sorted(sources.glob('DICOMweb*.swift'))
dicomweb = {path.name: path.read_text() for path in dicomweb_sources}
for name in ('DICOMwebClient.swift', 'DICOMwebClient+LogText.swift', 'DICOMwebIntegration.swift', 'DICOMwebSendActivity.swift'):
    if name not in dicomweb:
        failures.append('%s, of the DICOMweb send, is not read' % name)
        dicomweb[name] = ''
dicomweb_calls = 0
for name, text in dicomweb.items():
    dicomweb_calls += len(CALL.findall(text))
    for number, argument in refused_arguments(text, DICOMWEB_FORBIDDEN):
        failures.append('%s:%d logs %r' % (name, number, argument))
if dicomweb_calls < 11:
    failures.append('the scan found %d log calls in the DICOMweb sources, fewer than they hold' % dicomweb_calls)

# The scan refuses what the DICOMweb send and its client used to log.
DICOMWEB_REFUSED_CONTROLS = (
    ('NSLog("DICOMweb send to %@:\\n%@", node.name, detail)', 'detail'),
    ('NSLog("DICOMweb send to %@:\\n%@", node.name, detail)', 'node.name'),
    ('NSLog("DICOMweb send to %@:\\n%@", destination,\n      report.detail(limit: 20))', 'report.detail(limit: 20)'),
    ('NSLog("DICOMweb send to %@ failed: %@", node.name, message)', 'message'),
    ('NSLog("DICOMweb send to %@ failed: %@", destination, (error as NSError).localizedDescription)', 'localizedDescription'),
    ('NSLog("DICOMweb send to %@: %@", destination, report.statusLine)', 'report.statusLine'),
    ('NSLog("DICOMweb HTTP %ld: the node said: %@", status, reason)', 'reason'),
    ('NSLog("DICOMweb query: the node answered with %@", String(warning.prefix(1024)))', 'warning.prefix'),
    ('NSLog("DICOMweb HTTP \\(status): \\(web.bodyPreview ?? "")")', 'web.bodyPreview'),
    ('NSLog("DICOMweb send: %@ not stored: %@", (result.path as NSString).lastPathComponent, result.logReason)', 'result.path'),
    ('NSLog("DICOMweb send: %@ not stored: %@", result.sopInstanceUID, result.reason)', 'result.reason'),
)
for line, argument in DICOMWEB_REFUSED_CONTROLS:
    if not any(argument in found for _, found in refused_arguments(line, DICOMWEB_FORBIDDEN)):
        failures.append('the scan no longer refuses %r in %r' % (argument, line))
# And accepts what they log now, which is in the sources.
client, integration, activity = (dicomweb[name] for name in ('DICOMwebClient.swift', 'DICOMwebIntegration.swift',
                                                             'DICOMwebSendActivity.swift'))
DICOMWEB_ACCEPTED_CONTROLS = (
    ('NSLog("DICOMweb send to %@: %@", destination, report.summary)', activity),
    ('NSLog("DICOMweb send to %@:\\n%@", destination, report.logDetail(limit: 20))', activity),
    ('NSLog("DICOMweb send to %@ failed: %@", destination, DICOMwebClient.logReason(for: error as NSError) ?? "(null)")', activity),
    ('NSLog("DICOMweb HTTP %ld: the node said: %@", status, shape ?? "(null)")', client),
    ('NSLog("DICOMweb query: the node answered with %@", shape)', client),
    ('NSLog("DICOMweb query: %@", stopped)', client),
)
for line, where in DICOMWEB_ACCEPTED_CONTROLS:
    if refused_arguments(line, DICOMWEB_FORBIDDEN):
        failures.append('the scan refuses %r: %r' % (line, refused_arguments(line, DICOMWEB_FORBIDDEN)))
    if line not in where:
        failures.append('the DICOMweb sources no longer log %r' % line)
# What the log is told of what a node said comes from the function that keeps
# codes and lengths (IsiXDICOMNetwork's DICOMwebNodeAnswer, whose own tests say
# what it writes), and nothing else of a refusal is logged by the client.
if not re.search(r'shape = DICOMwebNodeAnswer\.logReason\(code: web\.code, warning: web\.warning, body: web\.bodyPreview\)', client) \
        or not re.search(r'if let shape = DICOMwebNodeAnswer\.logReason\(code: nil, warning: page\.warning, body: nil\)', client):
    failures.append('what the log is told of what a node said is no longer its error code, warn-code and lengths')

# The user is still shown the names and the node's words.
if 'let detail = report.detail(limit: 20)' not in activity or 'alert(detail)' not in activity \
        or 'thread.status = report.statusLine' not in activity or 'alert(message)' not in activity:
    failures.append('the alert and the activity panel of a DICOMweb send no longer show the detail that names the files')
shown = re.search(r'@objc\(detailWithLimit:\)\n    public func detail\(limit: Int\) -> String \{.*?\n    \}\n', integration, re.S)
logged = re.search(r'@objc\(logDetailWithLimit:\)\n    public func logDetail\(limit: Int\) -> String \{.*?\n    \}\n', integration, re.S)
if not shown or 'lastPathComponent' not in shown.group(0) or 'result.reason' not in shown.group(0):
    failures.append('the detail of a DICOMweb send the user is shown no longer names the file and gives the reason')
if not logged or 'StoreReport.logName(ofFileAtPath: result.path)' not in logged.group(0) \
        or 'Self.hasFormOfUID(result.sopInstanceUID) ? result.sopInstanceUID' not in logged.group(0) \
        or 'result.logReason' not in logged.group(0) \
        or re.search(r'lastPathComponent|result\.reason\b|NSLocalizedString', logged.group(0)):
    failures.append('the detail of a DICOMweb send for the log does not tell a file by its place and the shape of its '
                    'name, an instance by a UID that has the form of one, and each reason as the log may write it')

# Every result that is not a success is given its reason for the log, and that
# reason is a text of the client (`fixed`, a literal), one made of a DICOM
# reason code (`coded`), the kind of an error, or the one a result already has.
LOG_REASON = re.compile(r'logReason: (?:fixed|coded|result\.logReason|""|(?:"" \+ )?Self\.logSentence\(for: error\))$')
constructions = 0
for name in ('DICOMwebClient.swift', 'DICOMwebIntegration.swift'):
    text = dicomweb[name]
    for made in re.finditer(r'\bDICOMwebStoreResult\(', text):
        _, arguments, _ = scan(text, made.end())
        constructions += 1
        number = text.count('\n', 0, made.start()) + 1
        given = [argument for argument in arguments if argument.startswith('logReason:')]
        if 'status: .success' in arguments:
            continue
        if len(given) != 1:
            failures.append('%s:%d makes a result that is not a success without its reason for the log' % (name, number))
        elif not LOG_REASON.match(given[0]):
            failures.append('%s:%d gives a result a reason for the log that is not a text of the client, a reason code '
                            'or the kind of an error: %r' % (name, number, given[0]))
if constructions < 13:
    failures.append('the results a DICOMweb store makes are not all found: %d' % constructions)
for declared in re.finditer(r'\blet (fixed|coded) = ([^\n]*)', client + integration):
    kind, value = declared.groups()
    if kind == 'fixed' and not re.fullmatch(r'"[^"\\]*"', value):
        failures.append('a reason called fixed is not a text of the client alone: %r' % value)
    if kind == 'coded' and not re.fullmatch(r'(?:code == 0 \? "[^"\\]*" : )?DICOMwebStoreResult\.describe\(reason: code, warning: (?:true|false)\)',
                                            value):
        failures.append('a reason called coded is not made of a DICOM reason code alone: %r' % value)
if len(re.findall(r'\blet (?:fixed|coded) = ', client + integration)) < 4:
    failures.append('the reasons of a DICOMweb store that are logged as shown are not all found')
# A result nothing gave a reason for the log is logged by its codes.
if not re.search(r'self\.logReason = logReason \?\? Self\.logReason\(status: status, reasonCode: reasonCode, httpStatus: httpStatus\)',
                 client) \
        or 'static func logReason(status: DICOMwebStoreStatus, reasonCode: Int, httpStatus: Int) -> String {' \
        not in dicomweb['DICOMwebClient+LogText.swift']:
    failures.append('a result of a DICOMweb store given no reason for the log no longer falls back on its codes')

# --- the DCMTK adapter of the send ----------------------------------------------
# Its diagnostics go to the standard error and output of the process.
adapter = (sources / 'Adapters/DCMTK/IsiXDCMTKStoreSCU.mm').read_bytes().decode('latin1')
OBJC_PRINT = re.compile(r'\b(?:fprintf|printf|NSLog)\s*\((.*)$')
OBJC_FORBIDDEN = re.compile(r'\bpath\b|\.path\b|fileSystemRepresentation')


def refused_adapter_lines(text):
    return [(number, line.strip()) for number, line in enumerate(text.splitlines(), 1)
            if not line.lstrip().startswith('//') and OBJC_PRINT.search(line)
            and OBJC_FORBIDDEN.search(OBJC_PRINT.search(line).group(1))]


for number, line in refused_adapter_lines(adapter):
    failures.append('IsiXDCMTKStoreSCU.mm:%d prints the path of a file: %s' % (number, line))
if not refused_adapter_lines('    fprintf(stderr, "%s: Store Failed, file: %s:\\n", OFFIS_CONSOLE_APPLICATION, path);'):
    failures.append('the scan of the adapter no longer refuses the path of the file a store failed on')
if 'Store Failed, instance: %s:\\n", OFFIS_CONSOLE_APPLICATION, request.AffectedSOPInstanceUID)' not in adapter:
    failures.append('a store that failed is no longer told by the UID of its instance')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the log of a send tells a file by its place and the shape of its name and a study by its UID, '
      'never by a path, a file name, a patient or a description; the alerts name the files as before')
