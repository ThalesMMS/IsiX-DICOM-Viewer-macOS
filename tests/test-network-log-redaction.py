#!/usr/bin/env python3
"""No log call of a network source takes a patient's value, a file, a URL as it is or a description.

`NSLog` goes to the unified system log, which every process of the user can
read and which travels in sysdiagnose reports; the standard error and output
are on screen or in a transcript when the application is started from a
terminal or by a script. The send and the Query/Retrieve each have a test of
what they log (test-send-log-redaction.py, test-query-log-redaction.py). This
one reads the rest - the retrieve by WADO and by DICOMweb, the listener and
what it serves, Bonjour, the shared database, XML-RPC and the links that call
it, the URL import - and holds the three together: it reads EVERY network
source, the ones the two others read included, and tells which sources those
are by a rule (tests/network_log_scan.py), so a source added tomorrow is read
without anyone listing it.

It is a test of its own because what it adds is not a third protocol but the
closing of the set: the rule, the check that the two other tests read nothing
the rule does not know, and the scan with the widest refusals, which neither
of them could carry without reading the other's sources.

What the retrieve side wrote to the log, and no longer does:

  - a retrieve by WADO that was not complete: for each instance that did not
    arrive, the description the system has of the error of its request, and,
    for a URL that names no instance, the URL itself with its query string;
  - a notice of the query nodes, whole: the notice of a failed DICOMweb query
    or retrieve ends with what the node said, the notice of an incomplete
    retrieve gives the path of its manifest and that of several studies names
    them;
  - the description of each series a node's rules left out of a retrieve, and
    of the one clicked to retrieve it;
  - the reason a response in one transfer syntax stopped, as the client words
    it for the person;
  - the address a WADO request could not be made of, with the path of the
    node's setting as someone typed it;
  - what a C-FIND or a C-MOVE the listener serves raised in the database: a
    condition that cannot be evaluated is quoted whole, with the patient's
    name or identifier the peer asked for; the condition of every C-MOVE that
    failed; and a value the answer's character set cannot carry, which is a
    patient's name more often than anything;
  - the reason of every exception these sources catch, through the
    application's exception log: what is raised over a predicate, the keys of
    a query or a path quotes it;
  - what an XML-RPC method raised over the predicate or the filters of its
    request, the message of a request that found nothing, with the values of
    its filters, and a horos:// link that was not carried out, with its
    parameters;
  - what was typed in the search field of the database window when PACS
    On-Demand asks the nodes for it, and the name of the album searched;
  - the paths a client of the shared database asked for and was refused;
  - the report of a URL import, with each URL that brought nothing and the
    description of why.

What the user is SHOWN is as it was: the notices, the alerts, the activity
status and the network logs of the database say all of it. The log is told an
error by its domain and code, an exception by its name and the length of its
reason, a URL by its origin and path, a text by its length, a series and a
study by their UIDs (`LogText`, in the module every source can reach, compiled
and run here; its own tests are the module's).

Checked here: the rule tells a network source from another, and finds the
sources the two other tests read; nothing excused from the rule or from the
scan is excused for nothing; no log call of any network source takes what the
scan refuses, with controls of a patient's value, a file's name, a URL with
its query string and the description of an error, in Swift and in the
Objective-C++ of the DCMTK adapters; none writes an exception through the
application's exception log; the lines that replaced the leaks are in
the sources, and what the user is shown still says what it said; `LogText`
and the detail of a retrieve for the log, compiled and run, hold no name, no
query string and no description.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import network_log_scan as scan

root = Path(__file__).resolve().parents[1]
failures = []
sources = root / 'Horos/Sources'

# --- which sources ----------------------------------------------------------------
network = scan.network_sources()
if len(network) < 60:
    failures.append('the rule finds %d network sources that log, fewer than there are' % len(network))

# The rule tells a network source by its name or by what it does, and leaves
# out what does neither, what does not log and what is named as outside.
RULE_CONTROLS = (
    ('WADOThumbnails.swift', 'func load() { NSLog("loading") }', True),                       # by its name
    ('NewArchivePush.swift', 'let link = NWConnection(to: endpoint, using: .tcp)\nNSLog("pushed")', True),   # by what it does
    ('StudyUploader.swift', 'let task = URLSession.shared.dataTask(with: request)\nprint("sent")', True),
    ('IsiXDCMTKNewService.mm', 'cond = ASC_requestAssociation(net, params, &assoc);\nNSLog(@"asked");', True),
    ('NewArchivePush.swift', 'let link = NWConnection(to: endpoint, using: .tcp)', False),     # logs nothing
    ('ViewerOverlay.swift', 'func draw() { NSLog("drawn") }', False),                          # neither
    ('WebPortalConnection+Data.swift', 'let task = URLSession.shared\nNSLog("served")', False),    # named as outside
)
for name, text, expected in RULE_CONTROLS:
    if scan.is_network_source(name, text) != expected:
        failures.append('the rule reads %s (%r) as %s' % (name, text, 'no network source' if expected else 'a network source'))

# The two other tests read nothing the rule does not know: a source they read
# is a network source by the rule, and is read here from the day it logs.
for kind, read in (('send', scan.send_sources() + scan.dicomweb_sources()), ('Query/Retrieve', scan.query_sources())):
    if len(read) < 10:
        failures.append('the sources the test of the %s reads are not found: %d' % (kind, len(read)))
    for path in read:
        if not path.is_file():
            failures.append('%s, which the test of the %s reads, is not there' % (path.name, kind))
        elif scan.outside(path.name) or not (scan.NAME.search(path.name) or scan.CONTENT.search(scan.read(path))):
            failures.append('%s, which the test of the %s reads, is no network source by the rule' % (path.name, kind))
        elif scan.logs(path.name, scan.read(path)) and path not in network:
            failures.append('%s logs and is not among the network sources' % path.name)
# The send of the web portal, the one part of it that is the DICOM network's,
# is read by the test of the send.
send_test = (root / 'tests/test-send-log-redaction.py').read_text()
if "portal.find('func sendImagesToDicomNodeThread(')" not in send_test:
    failures.append('the send of the web portal, in a source left outside here, is no longer read by the test of the send')
for name, test in (('test-send-log-redaction.py', send_test),
                   ('test-query-log-redaction.py', (root / 'tests/test-query-log-redaction.py').read_text())):
    if 'network_log_scan' not in test or 'control_failures(' not in test:
        failures.append('%s no longer reads its sources with the scan of the network sources and its controls' % name)

# Nothing is excused for nothing.
for start in scan.stale_outside():
    failures.append('%r is named as outside the network sources and no source is called so' % start)
for entry in scan.stale_technical(network):
    failures.append('the scan excuses an argument no source logs any more: %s' % entry)
for name in list(scan.TECHNICAL) + list(scan.OBJC_TECHNICAL):
    if not any(path.name == name for path in network):
        failures.append('%s has arguments excused and is not a network source' % name)

# --- the log calls ------------------------------------------------------------------
calls = 0
for path, text in sorted(network.items()):
    where = path.relative_to(root)
    if path.suffix == '.swift':
        calls += len(scan.log_calls(text))
        for number, argument in scan.refused_in(path, text):
            failures.append('%s:%d logs %r' % (where, number, argument))
    else:
        calls += len([line for line in text.splitlines() if scan.OBJC_CALL.search(line) and not line.lstrip().startswith('//')])
        for number, line in scan.refused_lines_in(path, text):
            failures.append('%s:%d prints %s' % (where, number, line))
if calls < 350:
    failures.append('the scan found %d log calls in the network sources, fewer than they hold' % calls)

# An exception is written by its name, the length of its reason and its stack:
# no network source calls the application's exception log, which writes the
# reason. What a network source catches was raised over what someone sent or
# typed - a predicate, the keys of a query, a path - and the reason quotes it.
for path, text in sorted(network.items()):
    for number in scan.exception_log_calls(text):
        failures.append('%s:%d writes an exception to the log with its reason' % (path.relative_to(root), number))
for line in ('_N2LogExceptionImpl(exception, true, "-[XMLRPCInterface _FindObject:inDatabase:error:]")',
             'DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase(Routing) routing]")',
             'BrowserObjC.log(raised, stack: false, "+[BrowserController federatedStudiesMatchingPredicate:]")',
             'N2LogExceptionWithStackTrace(e);'):
    if not scan.exception_log_calls(line):
        failures.append('the scan no longer finds the application\'s exception log in %r' % line)
for line in ('LogText.log(exception, stack: true, in: "-[XMLRPCInterface _FindObject:inDatabase:error:]")',
             'QueryController.log(error, "-[QueryController performRetrieve:]")',
             'Self.log(exception, stack: false, "-[XMLRPCInterface _DisplayStudy:inDatabase:error:]")'):
    if scan.exception_log_calls(line):
        failures.append('the scan takes %r for the application\'s exception log' % line)
logging = scan.read(root / 'Modules/IsiXLogging/Sources/LogText.swift')
if 'unifiedLogv("exception in %@: %@%@", [function as NSString, LogText.exception(exception) as NSString,' not in logging \
        or '.reason' in logging[logging.find('public static func log('):logging.find('/// A URL by its scheme')]:
    failures.append('LogText.log no longer writes an exception by its name and the length of its reason alone')

# The scan refuses a patient's value, a file's name, a URL with its query
# string and the description of an error, and accepts each told as the log may
# have it.
failures += scan.control_failures()
OBJC_REFUSED = (
    'NSLog(@"DICOM listener: the database\'s %s raised %@", step, exception);',
    'NSLog(@"DICOM association failed: %@", exception);',
    'fprintf(stderr, "%s: Store Failed, file: %s:\\n", OFFIS_CONSOLE_APPLICATION, path);',
    'NSLog(@"Refused %@ of %@", sopInstance, study.patientName);',
    'NSLog(@"could not read: %@", error.localizedDescription);',
    'NSLog(@"asking %@", request.URL);',
)
OBJC_ACCEPTED = (
    'NSLog(@"DICOM listener: the database\'s %s raised %@", step, IsiXDCMTKLoggedException(exception));',
    'NSLog(@"Refused %s from %.16s: it declares an image but its Pixel Data is empty",',
    'if (closedForIdling) NSLog(@"%@ - closed as idle", endMessage(result));',
    'printf("Move SCP Response %d [status: %s]\\n", responseCount,',
)
for line in OBJC_REFUSED:
    if not scan.refused_lines(line):
        failures.append('the scan of the adapters no longer refuses %r' % line)
for line in OBJC_ACCEPTED:
    if scan.refused_lines(line):
        failures.append('the scan of the adapters refuses %r' % line)


# --- what replaced the leaks, and what the user is still shown ----------------------
def source(name, folder=sources):
    path = folder / name
    return path.read_text() if path.is_file() else ''


LOGGED = (
    ('WADODownload.swift', 'NSLog("------ WADO retrieve incomplete: %@", manifest.logDetail(limit: 20))'),
    ('WADODownload.swift', 'manifest?.recordFailure(forURL: url, statusCode: 0, reason: error.localizedDescription, logReason: logReason)'),
    ('DCMTKQueryNode+WADO.swift', 'NSLog("------ WADO retrieve: the node\'s credentials could not be read: %@", LogText.error(error))'),
    ('DCMTKQueryNode+WADO.swift', 'NSLog("****** no url for instance %@ of series %@ of study %@", objectUID, uid() ?? "(null)", study?.uid() ?? "(null)")'),
    ('DCMTKQueryNode+DICOMweb.swift', 'wantedSyntax, DICOMwebClient.logReason(for: cut.error as NSError) ?? "(null)", fallback)'),
    ('DCMTKQueryNode.swift', 'NSLog("*** listener error: %@", LogText.notice(title: title, text: text))'),
    ('DCMTKQueryNode+Query.swift', 'NSLog("---- DICOMweb query failed: %@", DICOMwebClient.logReason(for: error) ?? "(null)")'),
    ('DCMTKQueryNode+Retrieve.swift', 'NSLog("---- DICOMweb retrieve failed: %@", DICOMwebClient.logReason(for: error) ?? "(null)")'),
    ('DCMTKQueryNode+Retrieve.swift', 'NSLog("---- excluded series %@ clicked: not retrieved", seriesUID)'),
    ('DCMTKQueryNode+Network.swift', 'NSLog("---- C-MOVE failed: %@", condition.conditionText)'),
    ('DCMTKQueryNode+Network.swift', 'NSLog("---- C-GET failed: %@", failure.conditionText)'),
    ('SCPDatabaseSession+Find.swift', 'NSLog("%@ level, keys %@: the database raised %@", level ?? "(null)", asked, LogText.shape(of: description))'),
    ('SCPDatabaseSession+Retrieve.swift', 'failed("the database raised " + LogText.shape(of: description))'),
    ('SCPDatabaseSession+Retrieve.swift', 'NSLog("%@ level, keys %@", level ?? "(null)", asked)'),
    ('XMLRPCInterface.swift', 'LogText.log(exception, stack: stack, in: function)'),
    ('QueryController.swift', 'LogText.log(exception, stack: true, in: function)'),
    ('QueryController.swift', 'NSLog("%@: %@", function, LogText.error(error))'),
    ('RemoteDicomDatabase.swift', 'LogText.log(SharedDatabaseClientFailure.exception(for: error), stack: true, in: "-[RemoteDicomDatabase updateThread:]")'),
    ('BonjourPublisher.swift', 'LogText.log(exception, stack: true, in: "-[O2DatabaseConnection run]")'),
    ('DatabaseRouting.swift', 'LogText.log(exception, stack: true, in: "-[DicomDatabase(Routing) __applyRoutingRules:toImages:]")'),
    ('XMLRPCInterface+Retrieve.swift', 'N2LogStackTraceMessage("URL is not valid: \\(LogText.url(string: address))")'),
    ('RISRequestAlert.swift', 'NSLog("RIS request failed (%d): %@", code, LogText.shape(of: message))'),
    ('BrowserController+DistantSearch.swift', 'LogText.shape(of: searchString))'),
    ('BrowserController+DistantSearch.swift', 'NSLog("Search album: %@", LogText.shape(of: albumName))'),
    ('BonjourPublisher.swift', 'throw _rejectRequest("a path of \\(LogText.shape(of: requested)) does not name a file of the database")'),
    ('URLImportOperation.swift', 'NSLog("---- url import: %@", report.logSummary)'),
    ('RemoteDicomDatabase.swift', 'NSLog("---- shared database: %@ %@", LogText.exception(exception), guidance)'),
)
for name, line in LOGGED:
    if line not in source(name):
        failures.append('%s no longer logs %r' % (name, line))
for name, line, folder in (
        ('SCPResponseIdentifiers.swift', 'log("--- cannot encode \\(LogText.shape(of: text)) -> switch to dcm file encoding")',
         root / 'Modules/IsiXDICOMNetwork/Sources'),
        ('N2XMLRPCConnection.swift', 'NSLog("Warning: [N2XMLRPCConnection handleRequest:] %@ failed: %@", methodName ?? "(null)", LogText.shape(of: failure))',
         root / 'Nitrogen/Sources'),
        ('IsiXDCMTKSCPDatabase.mm', 'NSLog(@"DICOM listener: the database\'s %s raised %@", step, IsiXDCMTKLoggedException(exception));',
         sources / 'Adapters/DCMTK')):
    if line not in scan.read(folder / name):
        failures.append('%s no longer logs %r' % (name, line))
# No log call of the adapters of the listener writes an exception whole.
for name in ('IsiXDCMTKSCPDatabase.mm', 'IsiXDCMTKQueryRetrieveSCP.mm'):
    for number, line in enumerate(scan.read(sources / 'Adapters/DCMTK' / name).splitlines(), 1):
        if re.search(r'NSLog\(.*,\s*exception\s*\)', line):
            failures.append('%s:%d writes an exception whole to the log' % (name, number))

# The person is shown what they were shown: the notice, the status and the
# alert take the text the log no longer does.
SHOWN = (
    ('DCMTKQueryNode.swift', 'NetworkNotices.post(title: title, message: text)'),
    ('DCMTKQueryNode+Query.swift', 'Self.postNotice(NSLocalizedString("DICOMweb Query Failed", comment: ""), error.localizedDescription)'),
    ('DCMTKQueryNode+Retrieve.swift', 'Self.postNotice(NSLocalizedString("DICOMweb Retrieve Failed", comment: ""), error.localizedDescription)'),
    ('DCMTKQueryNode+Retrieve.swift', '"\\(shortListing)\\(inventory.summary)\\nManifest: \\(inventory.path)")'),
    ('DCMTKQueryNode+Retrieve.swift', 'comment: "Activity, after a click on a DICOMweb placeholder that brought nothing"), description)'),
    ('DCMTKQueryNode+Retrieve.swift', 'Thread.current.status = text'),
    ('DCMTKQueryNode+WADO.swift', 'Self.postNotice(NSLocalizedString("WADO Retrieve Failed", comment: ""), error.localizedDescription)'),
    ('WADODownload.swift', 'with: [NSLocalizedString("WADO Retrieve Incomplete", comment: ""), manifest.summary, NSLocalizedString("Continue", comment: "")],'),
    ('RISRequestAlert.swift', 'show(text(message, code: code))'),
    ('ExternalRequestHandler.swift', '+ "\\r\\r" + RISRequestAlert.notCarriedOut(request)'),
    ('URLImportOperation.swift', 'return URLImportResult(entries: ordered, report: summary,'),
    ('ModalityWorklistService.swift', 'failures.append(.init(node: name, reason: IsiXUserMessage(for: error)))'),
)
for name, line in SHOWN:
    if line not in source(name):
        failures.append('%s no longer shows %r' % (name, line))
connection = scan.read(root / 'Nitrogen/Sources/N2XMLRPCConnection.swift')
if 'XMLRPCRequestContract.fault(forFailedMethodName: methodName, reason: failure)' not in connection \
        or 'XMLRPCRequestContract.fault(forUnparsableRequest: reason)' not in connection:
    failures.append('the caller of an XML-RPC method is no longer answered what failed')

# --- a notice, shown or not -----------------------------------------------------------
# A notice goes to the log by its title and the length of its text, through
# LogText.notice, and so does one the person asked not to be shown
# (hideListenerError). The retrieve by WADO wrote such a notice whole - its
# title, its text, which counts what did not arrive, and the name of its
# button - and the two other lines of the kind wrote whatever text they were
# handed. Checked here: the lines are in the sources; no log call that says
# its notice was not displayed, in any source, takes anything but that form
# or the length of a text, with the former lines as controls; and the form,
# compiled and run, holds the title and a length.
NOTICES = (
    ('DCMTKQueryNode.swift', 'NSLog("*** listener error: %@", LogText.notice(title: title, text: text))'),
    ('WADODownload.swift',
     'NSLog("*** listener error (not displayed - hideListenerError): %@", LogText.notice(title: title, text: text))'),
    ('BonjourBrowser.swift',
     'NSLog("*** Bonjour Browser Error (not displayed - hideListenerError): %@", LogText.notice(title: "Network Error", text: s))'),
    ('StudyDeletionJob.swift', 'NSLog("*** DICOM Network Error (not displayed - hideListenerError): %@", LogText.shape(of: message))'),
)
for name, line in NOTICES:
    if line not in source(name):
        failures.append('%s no longer logs %r' % (name, line))
if 'HorosAlertPanel.runCritical(title: msg[0] as? String, message: msg[1] as? String ?? "", defaultButton: msg[2] as? String,' \
        not in source('WADODownload.swift'):
    failures.append('WADODownload.swift no longer shows the notice of an incomplete retrieve as it did')


def hidden_notices_written_whole(text):
    """(line, what it takes) of every log call of Swift `text` that says its
    notice was not displayed and takes anything but LogText.notice or the
    length of a text; and how many such calls `text` has."""
    refused, found = [], 0
    for call in scan.CALL.finditer(text):
        end, arguments, interpolations = scan.scan(text, call.end())
        if 'not displayed' not in text[call.end():end]:
            continue
        found += 1
        taken = [argument for argument in arguments[1:] + interpolations
                 if not argument.startswith(('LogText.notice(', 'LogText.shape('))]
        if taken or len(arguments) < 2:
            refused.append((text.count('\n', 0, call.start()) + 1, ', '.join(taken) or 'nothing'))
    return refused, found


hidden = 0
for path in sorted(sources.glob('*.swift')) + sorted((root / 'Modules').glob('*/Sources/*.swift')) \
        + sorted((root / 'Nitrogen/Sources').glob('*.swift')) + sorted((root / 'DICOMPrint').glob('*.swift')):
    refused, found = hidden_notices_written_whole(path.read_text())
    hidden += found
    for number, taken in refused:
        failures.append('%s:%d writes a notice that is not displayed whole: %s' % (path.relative_to(root), number, taken))
if hidden < 3:
    failures.append('the log calls of the notices that are not displayed are not all found: %d' % hidden)
for line in ('NSLog("*** listener error (not displayed - hideListenerError): %@ %@ %@", "\\(msg[0])", "\\(msg[1])", "\\(msg[2])")',
             'NSLog("*** Bonjour Browser Error (not displayed - hideListenerError): %@", s)',
             'NSLog("*** DICOM Network Error (not displayed - hideListenerError): %@", message)',
             'NSLog("*** listener error (not displayed - hideListenerError): %@ %@",\n      LogText.notice(title: title, text: text), text)'):
    if not hidden_notices_written_whole(line)[0]:
        failures.append('the check of the notices that are not displayed no longer refuses %r' % line)
for name, line in NOTICES[1:]:
    if hidden_notices_written_whole(line) != ([], 1):
        failures.append('the check of the notices that are not displayed refuses %r' % line)

NOTICE_DRIVER = r'''
import Foundation
print(LogText.notice(title: "WADO Retrieve Incomplete", text: "0 of 1 instances received, 1 missing."))
print(LogText.notice(title: "DICOMweb Retrieve Failed", text: "The node said: no patient DOE^JOHN born 19700101"))
print(LogText.notice(title: "Network Error", text: "x"))
'''
with tempfile.TemporaryDirectory(prefix='horos-notice-log-') as directory:
    (Path(directory) / 'main.swift').write_text(NOTICE_DRIVER)
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(Path(directory) / 'notice'),
                            str(root / 'Modules/IsiXLogging/Sources/LogText.swift'),
                            str(root / 'Modules/IsiXLogging/Sources/UnifiedLog.swift'), str(Path(directory) / 'main.swift')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the log form of a notice does not compile:\n%s' % built.stderr[-1500:])
    else:
        told = subprocess.run([str(Path(directory) / 'notice')], capture_output=True, text=True).stdout.splitlines()
        if told != ['WADO Retrieve Incomplete (a notice of 37 characters)', 'DICOMweb Retrieve Failed (a notice of 48 characters)',
                    'Network Error (a notice of 1 character)']:
            failures.append('a notice is told to the log as %r, not by its title and the length of its text' % told)

# --- compiled and run ---------------------------------------------------------------
DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String) { print(key + "\t" + value.replacingOccurrences(of: "\n", with: " | ")) }

// What the log is told of an error, an exception, a URL and a text.
let address = URL(string: "https://reader:s3cret@pacs.example:8443/wado?requestType=WADO&PatientID=12345&token=abc")!
let timedOut = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: address])
emit("error.url", LogText.error(timedOut))
emit("error.url.described", String(describing: timedOut as NSError))
let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [
    NSFilePathErrorKey: "/Volumes/CD/DOE^JOHN/IM1",
    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: nil)])
emit("error.file", LogText.error(missing))
emit("error.file.described", missing.localizedDescription)
emit("error.node", LogText.error(NSError(domain: "HorosDICOMweb", code: 409, userInfo: [
    NSLocalizedDescriptionKey: "The node refused the request. The node said: no patient DOE^JOHN born 19700101"])))
let raised = NSException(name: .invalidArgumentException, reason: "Unable to parse the format string \"name == 'DOE^JOHN'\"", userInfo: nil)
emit("exception", LogText.exception(raised))
emit("url", LogText.url(address))
emit("url.file", LogText.url(URL(fileURLWithPath: "/Volumes/CD/DOE^JOHN/IM1")))
emit("url.text", LogText.url(string: "DOE^JOHN 19700101"))
emit("shape", LogText.shape(of: "DOE^JOHN"))

// A retrieve by WADO that was not complete: what it records, and what the log is told.
let first = URL(string: "http://pacs.example/wado?requestType=WADO&studyUID=1.2&seriesUID=1.2.3&objectUID=1.2.3.4")!
let second = URL(string: "http://pacs.example/wado?requestType=WADO&studyUID=1.2&seriesUID=1.2.3&objectUID=1.2.3.5")!
let third = URL(string: "http://pacs.example/wado?requestType=WADO&studyUID=1.2&seriesUID=1.2.3&objectUID=1.2.3.6")!
let named = URL(string: "https://pacs.example/files/DOE_JOHN.dcm?PatientID=12345&token=abc")!
let manifest = RetrieveManifest(urls: [first, second, third, named])
manifest.recordSuccess(forURL: first)
manifest.recordFailure(forURL: second, statusCode: 404, reason: "HTTP 404")
manifest.recordFailure(forURL: third, statusCode: 0, reason: "The file “DOE JOHN.dcm” couldn’t be opened.",
                       logReason: "Transport NSURLErrorDomain -1001")
manifest.recordFailure(forURL: named, statusCode: 0, reason: "The request for \(named.absoluteString) timed out.")
emit("manifest.shown", manifest.detail(limit: 10))
emit("manifest.logged", manifest.logDetail(limit: 10))
emit("manifest.bounded", manifest.logDetail(limit: 1))
emit("manifest.summary", manifest.summary)
let whole = RetrieveManifest(urls: [first])
whole.recordSuccess(forURL: first)
emit("manifest.whole", whole.logDetail(limit: 10))

// The report of a URL import.
let report = URLImportReport()
report.recordIndexed(url: "https://pacs.example/a.dcm")
report.recordFailed(url: "https://reader:s3cret@pacs.example/files/b.dcm?PatientID=12345", reason: "The request timed out for DOE^JOHN.")
report.recordRefused(url: "DOE^JOHN 19700101", reason: "42 bytes that are neither a DICOM object nor an archive")
emit("import.shown", report.summary)
emit("import.logged", report.logSummary)
'''

results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-network-log-') as directory:
        # Top-level statements are only allowed in a file called main.swift.
        (Path(directory) / 'main.swift').write_text(DRIVER)
        binary = Path(directory) / 'logged'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(root / 'Modules/IsiXLogging/Sources/LogText.swift'),
                                str(root / 'Modules/IsiXLogging/Sources/UnifiedLog.swift'), str(sources / 'RetrieveManifest.swift'),
                                str(sources / 'URLImportReport.swift'), str(Path(directory) / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the log forms do not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the driver of the log forms failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {
        'error.url': 'NSURLErrorDomain -1001',
        'error.file': 'NSCocoaErrorDomain 260 (NSPOSIXErrorDomain 2)',
        'error.node': 'HorosDICOMweb 409',
        'exception': 'NSInvalidArgumentException <a reason of 54 characters>',
        'url': 'https://pacs.example:8443/wado <with a user, a query of 42 characters>',
        'url.file': 'file:<a path of 24 characters>',
        'url.text': '<not a URL, 17 characters>',
        'shape': '<8 characters>',
        'manifest.whole': '1 of 1 instances received.',
    }
    for key, value in expected.items():
        if results.get(key) != value:
            failures.append('%s is %r, expected %r' % (key, results.get(key), value))
    # What the descriptions the log no longer takes would have written.
    if 'PatientID=12345' not in results.get('error.url.described', '') or 'IM1' not in results.get('error.file.described', ''):
        failures.append('the description of a URL error or of a file error no longer shows what the log is kept from: %r, %r'
                        % (results.get('error.url.described'), results.get('error.file.described')))
    shown, logged = results.get('manifest.shown', ''), results.get('manifest.logged', '')
    # The record keeps the reasons it was given, and what a URL without objectUID is known by.
    for text in ('1.2.3.5: HTTP 404', '1.2.3.6: The file “DOE JOHN.dcm” couldn’t be opened.',
                 'https://pacs.example/files/DOE_JOHN.dcm?PatientID=12345&token=abc: The request for'):
        if text not in shown:
            failures.append('the detail of a retrieve no longer records %r: %r' % (text, shown))
    wanted = ('%s |   1.2.3.5: HTTP 404 |   1.2.3.6: Transport NSURLErrorDomain -1001 |   request 4 <an address of 65 characters>: no answer'
              % results.get('manifest.summary', ''))
    if logged != wanted:
        failures.append('the detail of a retrieve for the log is not its summary, each instance by its UID and each reason '
                        'as recorded for the log:\n  logged   %r\n  expected %r' % (logged, wanted))
    if 'and 2 more' not in results.get('manifest.bounded', ''):
        failures.append('the detail of a retrieve for the log lost its bound: %r' % results.get('manifest.bounded'))
    if 'reader' not in results.get('import.shown', '') and 'DOE^JOHN' not in results.get('import.shown', ''):
        failures.append('the report of a URL import the person reads no longer names what failed: %r' % results.get('import.shown'))
    if results.get('import.logged') != ('1 added to the database; 0 handed to the import folder; 1 not downloaded; '
                                        '1 not something this database can take; '
                                        'https://pacs.example/files/b.dcm <with a user, a query of 15 characters>; '
                                        '<not a URL, 17 characters>'):
        failures.append('the report of a URL import for the log is %r' % results.get('import.logged'))
    for key in ('error.url', 'error.file', 'error.node', 'exception', 'url', 'url.file', 'url.text', 'shape',
                'manifest.logged', 'manifest.bounded', 'import.logged'):
        for word in ('DOE', 'JOHN', '12345', 's3cret', 'reader', 'token', 'abc', 'IM1', '/Volumes', '19700101', 'timed out', 'opened'):
            if word in results.get(key, word):
                failures.append('%s, written to the log, carries %r: %r' % (key, word, results.get(key)))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: %d log calls of %d network sources take no patient\'s value, no file, no URL as it is and no description; '
      'the notices, the alerts and the status say what they said' % (calls, len(network)))
