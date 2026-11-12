"""Which sources are the network's, and what their log calls may not take.

`NSLog` goes to the unified system log, which every process of the user can
read and which travels in sysdiagnose reports; the standard error and output
are on screen or in a transcript when the application is started from a
terminal or by a script. The log of the network code gets technical text only:
UIDs, counts, status and reason codes, hosts, ports, AE titles, transfer
syntaxes, shapes and lengths. What the user is shown is another matter.

Three tests read the log calls of the network sources: the send's
(test-send-log-redaction.py), the Query/Retrieve's
(test-query-log-redaction.py) and, for every network source whatever else
reads it, test-network-log-redaction.py. This module is what they share:

  - `network_sources()`: the network sources, told by rule. A source is one by
    its NAME (the protocol families: DIMSE, Query/Retrieve, WADO, DICOMweb,
    routing, the listener, Bonjour, the shared database, XML-RPC, the embedded
    HTTP server, DICOM print) or by its CONTENT (it opens a connection, a listener or an
    association itself), unless it is one of `OUTSIDE`, each with the reason
    it is not the DICOM network's. A new source that matches is read without
    anyone adding it to a list.
  - `send_sources()` and `query_sources()`: what the two other tests read.
  - `refused_arguments()`: every argument of a log call, and every
    interpolation of its format, that may be a patient's value, a file's name
    or path, a URL as it is, or the description of an error or of what a peer
    said. The scan reads calls that span lines. `LOG_FORMS` are the calls that
    write such a value as the log may have it, and what is inside them is not
    read.
  - `refused_lines()`: the same for the Objective-C++ of the DCMTK adapters,
    a line at a time.
  - `exception_log_calls()`: the calls of the application's exception log,
    which writes the reason of an exception. A network source catches what is
    raised over values someone sent or typed, and such a reason quotes them, so
    it writes an exception through `LogText.log`: its name, the length of its
    reason and its stack.
  - `control_failures()`: the controls that hold a scan to what it refuses - a
    patient's value, a file's name, a URL with its query string and the
    description of an error - and to what it accepts.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
ADAPTERS = SOURCES / 'Adapters/DCMTK'
MODULES = ROOT / 'Modules'
NITROGEN = ROOT / 'Nitrogen/Sources'
PRINT = ROOT / 'DICOMPrint'

# --- which sources ----------------------------------------------------------------
# By name: the protocol families and the parts of the application that speak them.
NAME = re.compile(
    r'WADO|DICOMweb|QueryNode|QueryController|QueryRetrieve|QueryArray|QueryWindow|QueryLog|Retrieve|StoreSCU|StoreReport'
    r'|SCPDatabase|SCPQuery|SCPResponse|SCPLocal|Listener|ListenBind|Routing|Bonjour|Network|XMLRPC|SharedDatabase'
    r'|RemoteDicomDatabase|DatabaseServer|SendController|ActivitySend|DICOMSend|DICOMNode|DIMSE|MoveContext|MoveUser|GetUser'
    r'|Worklist|DirectTransfer|HTTPConnection|HTTPServer|URLImport|ExternalRequest|RISRequest|DistantS|NodeRequest|DicomPrint')
# By content: the source itself opens a connection, a listener or an association.
CONTENT = re.compile(
    r'\bURLSession\b|\bURLRequest\b|\bNWConnection\b|\bNWListener\b|\bNWBrowser\b|\bNetService\b|\bNetServiceBrowser\b'
    r'|\bCFSocket|\bDNSService|^import Network\b|\bASC_[a-z]|\bDIMSE_[a-z]|\bT_ASC_|\bDcmSCP\b|\bDUL_[A-Z]'
    r'|\bIsiXDCMTKAssociation\b|\bIsiXDCMTKQueryRetrieveSCP\b|\bN2Connection\b|\bsocket\s*\(|\bgetaddrinfo\b', re.M)
# Sources the rule finds that are not the DICOM network's, by the start of their
# name, with why. Each must still be there, so the list does not outlive them.
OUTSIDE = {
    'WebPortal': 'the web portal, an HTTP server of its own with its own users and its own log; its DICOM send is read '
                 'by the test of the send',
    'PortalStudyLinks': 'the links the web portal mails',
    'AppController.swift': 'the application delegate, which starts and stops the listeners and logs the application\'s own launch',
    'BrowserController+Sources.swift': 'the sources list of the database window, which scans mounted volumes',
    'SourceList.swift': 'the sources list of the database window',
    'PluginManagerController.swift': 'the plugin manager, which downloads plugins, not DICOM',
    'UpdateArchive.swift': 'the download of an update of the application',
    'UpdateFeedClient.swift': 'the feed of the updates of the application',
    'SMTPConnection.swift': 'the mail client',
    'CSMailMailClient.swift': 'the mail client',
    'N2WebServiceClient.swift': 'a generic web service client no DICOM source uses to log',
    'NetworkPreferences.swift': 'the names of the preferences, which log nothing of a node',
    'ViewerController+RetrieveAndView.swift': 'the viewer side of Retrieve and View: it opens what arrived and exports '
                                              'series, and speaks to no node',
}
# What writes to the unified log, the standard error or the standard output.
# `_rejectRequest` is the reason a request of the shared database is closed with, which is logged.
CALL = re.compile(r'\b(NSLog|storeSCUDiagnostic|print|debugPrint|standardError\.write|N2LogStackTraceMessage|os_log|environment\.log'
                  r'|_rejectRequest)\s*\(')
OBJC_CALL = re.compile(r'\b(?:fprintf|printf|NSLog|N2LogStackTraceMessage)\s*\(|\bCOUT\b|\bCERR\b|lockCerr\(\)')


def read(path):
    """Swift is UTF-8; the Objective-C of the adapters is read byte for byte."""
    if path.suffix == '.swift':
        return path.read_text(encoding='utf-8')
    return path.read_bytes().decode('latin1')


def candidates():
    found = []
    for folder, patterns in ((SOURCES, ('*.swift', '*.m', '*.mm')), (ADAPTERS, ('*.mm', '*.cpp', '*.hpp', '*.h')),
                             (NITROGEN, ('*.swift', '*.m', '*.mm')), (PRINT, ('*.swift', '*.m', '*.mm'))):
        for pattern in patterns:
            found += sorted(folder.glob(pattern))
    return found + sorted(MODULES.glob('*/Sources/*.swift'))


def outside(name):
    """Why the source called `name` is not the DICOM network's, or None."""
    return next((reason for start, reason in OUTSIDE.items() if name.startswith(start)), None)


def logs(name, text):
    return bool((CALL if name.endswith('.swift') else OBJC_CALL).search(text))


def is_network_source(name, text):
    """Whether a source called `name` that holds `text` is one the scans read:
    a network source, by its name or by what it does, that writes to the log."""
    return not outside(name) and bool(NAME.search(name) or CONTENT.search(text)) and logs(name, text)


def network_sources():
    """{path: text} of every network source that writes to the log."""
    found = {}
    for path in candidates():
        text = read(path)
        if is_network_source(path.name, text):
            found[path] = text
    return found


def stale_outside():
    """The entries of OUTSIDE no source answers to any more."""
    names = [path.name for path in candidates()]
    return [start for start in OUTSIDE if not any(name.startswith(start) for name in names)]


def send_sources():
    """The Swift sources the test of the send reads whole."""
    return (sorted(SOURCES.glob('DCMTKStoreSCU*.swift'))
            + [SOURCES / name for name in ('StoreReport.swift', 'ActivitySendTransport.swift', 'DatabaseRoutingDelivery.swift',
                                           'BonjourPublisher.swift', 'IsiXNetworkAdapter.swift')]
            + [MODULES / 'IsiXDICOMNetwork/Sources' / name for name in ('RoutingQueue.swift', 'RoutingSelection.swift',
                                                                         'DICOMSendQueue.swift')])


def dicomweb_sources():
    return sorted(SOURCES.glob('DICOMweb*.swift'))


def query_sources():
    """The Swift sources the test of the Query/Retrieve log reads: the query
    nodes, the Query window and the XML-RPC interface."""
    return (sorted(SOURCES.glob('DCMTK*QueryNode*.swift')) + sorted(SOURCES.glob('QueryController*.swift'))
            + sorted(SOURCES.glob('XMLRPCInterface*.swift')))


# --- what a log argument may not be ------------------------------------------------
FORBIDDEN = re.compile('|'.join((
    # A patient's value, or a whole record whose description carries them.
    r'patientID|patientName|patientsName|accessionNumber|theDescription|studyName|studyDescription|seriesDescription',
    r'dateOfBirth|birth[dD]ate|referringPhysician|\bname\b|pressedKeys|customValue|searchString|albumName',
    # A file: its path, its name, a list of them.
    r'[Pp]aths?\b(?!\.count)|lastPathComponent|\bfiles?\b(?!\.count)|[fF]ile[nN]ame|filesToSend(?!\.count)',
    # A URL as it is: its query string carries matching keys or a token, its authority a user and a password.
    r'absoluteString|(?<![A-Za-z])(?:url|URL)\b(?!s?\.count)|[a-z](?:URL|Url)\b|\bqueryItems\b|^\(?request(?: as \w+)?\)?$',
    # An error or an exception told by its description, and what a peer said.
    r'localizedDescription|localizedFailureReason|String\(describing:(?! type\(of:)|\berror\b(?! as NSError\)\.(?:code|domain)\b)',
    r'\bas NSError$|\.description\b|\bdescription\b|\.reason\b|\breason\b|\bexception\b|\bmessage\b|\.detail\(|\bdetail\b',
    r'statusLine|\bwarning\b|\bbody\b|bodyPreview|IsiXUserMessage',
)))
# The calls that write such a value as the log may have it: what is inside
# their parentheses is not read.
LOG_FORMS = ('LogText.error(', 'LogText.exception(', 'LogText.url(', 'LogText.shape(', 'QueryLog.term(', 'QueryLog.describe(',
             'QueryLog.describeRetrieveParameters(', 'PatientIdentifierList.summary(forText:', 'StoreReport.logName(ofFileAtPath:',
             'DICOMwebClient.logReason(for:', 'IsiXDCMTKUIDs.name(ofUID:', 'String(describing: type(of:',
             # A number is technical whatever it counts.
             'Int32(', 'Int64(', 'UInt32(', 'UInt(', 'Int(', 'Double(')
# Members that are technical whatever they belong to, with what they belong to:
# the reason, the detail and the name made for the log, the case of a closed
# set or the name of an exception and its stack, the text DCMTK has of a
# condition, and a UID.
LOG_MEMBERS = re.compile(r'[\w?!.]*\.(?:logReason|logText|loggedName|conditionText|conditionDescription)\b'
                         r'|[\w?!.]*\.logDetail\(limit: \d+\)|[\w?!.]*\.(?:category|name)\.rawValue\b|[\w?!.]*\.logSummary\b'
                         r'|[\w?!.]*\.callStackSymbols\b'
                         r'|[\w?!.()]*\b(?:studyInstanceUID|seriesInstanceUID|sopInstanceUID)\b(?:\(\))?|[\w?!.()]*\buid\(\)')
# Arguments the scan would refuse by their name and that are technical, by
# source, each with what it is. An argument is excused in its source alone,
# and one no source logs any more is an error: the list cannot outlive what
# it excuses.
TECHNICAL = {
    'BonjourDiscovery.swift': {
        'name': 'the name of a Bonjour service, which is the computer\'s',
        'owner.name': 'the name of a Bonjour service, which is the computer\'s',
    },
    'BonjourPublisher.swift': {
        'description': 'what the system says of the error of the listening socket of the shared database: an errno and its text',
        'reason': 'why a request of the shared database was closed: every one is made by `_rejectRequest`, which the scan '
                  'reads, or by the request parser, of sizes and of names of fields',
    },
    'DCMTKQueryNode+Network.swift': {
        'failure.reason': 'the reason of an AssociationFailure: the step that failed with its DCMTK condition, a status, or '
                          'the diagnosis of the connection, never a value of the identifier',
    },
    'DCMTKStoreSCU.swift': {
        'message': 'the body of storeSCUDiagnostic, whose callers the scan reads',
    },
    'DICOMListenerController.swift': {
        'message as NSString': 'what a listener reports: the calling and called AE titles with the DCMTK condition an '
                               'association ended on, or what in the listener\'s own settings kept it from starting',
    },
    'ListenerHost.swift': {
        'message': 'the calling and called AE titles of an association and the DCMTK condition it ended on',
    },
    'ExternalRequestHandler.swift': {
        'parsed.message as NSString': 'what the parser of a horos:// link found wrong, in its own words: none quotes the link',
        '(reason ?? "") as NSString': 'why a study did not open: a sentence of StudyNotOpenedReason, with a Study Instance UID',
    },
    'XMLRPCInterface+Display.swift': {
        'reason as NSString': 'why a study did not open: a sentence of StudyNotOpenedReason, with a Study Instance UID',
    },
    'ModalityWorklistService.swift': {
        'name': 'the name the node was given in Locations',
    },
    'QueryController.swift': {
        'message': 'the body of logStackTrace, which is called with texts of the application alone',
    },
    'SCPDatabaseSession+Find.swift': {
        'message': 'the body of the log the matching of a C-FIND is given, whose callers the scan reads',
    },
    'SCPQueryMatching.swift': {
        'name': 'the level of a query: PATIENT, STUDY, SERIES or IMAGE',
        'element.name': 'the keyword of an attribute of the identifier',
    },
    'RoutingQueue.swift': {
        'node[DICOMNode.Key.description]?.text ?? ""': 'the name the destination node was given in Locations',
    },
}

# --- a notice -----------------------------------------------------------------------
# A notice is what the person reads in the notices panel or in an alert: its
# text can end with what a node said, name the studies that did not arrive
# whole or give the path of a manifest. Shown or not, the log is told its
# title and the length of its text, through `LogText.notice`. A notice the
# person had asked not to be shown went to the log whole, as the elements of
# the array it is handed in, which the sources call `msg`: a log argument is
# not that either.
LOG_FORMS += ('LogText.notice(',)
FORBIDDEN = re.compile(FORBIDDEN.pattern + r'|\bmsg\b')


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


def without_log_forms(argument):
    """`argument` with every call of LOG_FORMS, and what it takes, taken out."""
    for form in LOG_FORMS:
        at = argument.find(form)
        while at >= 0:
            depth, end = 1, at + len(form)
            while end < len(argument) and depth:
                depth += {'(': 1, ')': -1}.get(argument[end], 0)
                end += 1
            argument = argument[:at] + '<log form>' + argument[end:]
            at = argument.find(form)
    return LOG_MEMBERS.sub('<log form>', argument)


def log_calls(text):
    """(line, arguments and interpolations) of every log call of Swift `text`."""
    found = []
    for call in CALL.finditer(text):
        start = text.rfind('\n', 0, call.start()) + 1
        before = text[start:call.start()]
        if before.lstrip().startswith('//') or re.search(r'\bfunc\s+$', before):
            continue
        _, arguments, interpolations = scan(text, call.end())
        found.append((text.count('\n', 0, call.start()) + 1, arguments + interpolations))
    return found


def refused_arguments(text, forbidden=FORBIDDEN):
    """The line and text of every log argument of Swift `text` that may be a
    patient's value, a file, a URL as it is or a description."""
    return [(line, argument) for line, arguments in log_calls(text) for argument in arguments
            if forbidden.search(without_log_forms(argument))]


def refused_in(path, text):
    """`refused_arguments` of the source at `path`, less what TECHNICAL excuses there."""
    excused = TECHNICAL.get(path.name, {})
    return [(line, argument) for line, argument in refused_arguments(text) if argument not in excused]


def stale_technical(sources):
    """The entries of TECHNICAL and OBJC_TECHNICAL that excuse nothing in
    `sources` ({path: text}) any more."""
    stale = []
    for name, excused in TECHNICAL.items():
        found = {argument for path, text in sources.items() if path.name == name for _, argument in refused_arguments(text)}
        stale += ['%s: %r' % (name, argument) for argument in excused if argument not in found]
    for name, excused in OBJC_TECHNICAL.items():
        found = [line for path, text in sources.items() if path.name == name for _, line in refused_lines(text)]
        stale += ['%s: %r' % (name, mark) for mark in excused if not any(mark in line for line in found)]
    return stale


# The Objective-C++ of the adapters, a line at a time: what follows the call.
OBJC_FORBIDDEN = re.compile(r'\bpath\b|\.path\b|fileSystemRepresentation|lastPathComponent|[Pp]atientName|[Pp]atientID|patientsName'
                            r'|accessionNumber|localizedDescription|\bdescription\b|absoluteString|\bURL\b'
                            # An exception or an error written whole, which is its reason or its description.
                            r'|,\s*(?:exception|error|e)\s*\)|\breason\b(?!\.length)')


# Lines of the adapters the scan would refuse by a name and that are technical:
# by source, a text of the line and what it prints.
OBJC_TECHNICAL = {
    'IsiXDCMTKError.mm': {
        'threw a C++ exception': 'what() of a C++ exception caught at the boundary of an adapter: the text the standard '
                                 'library or DCMTK has of an error of the program, not of a dataset',
    },
}


def refused_lines_in(path, text):
    """`refused_lines` of the adapter at `path`, less what OBJC_TECHNICAL excuses there."""
    excused = OBJC_TECHNICAL.get(path.name, {})
    return [(number, line) for number, line in refused_lines(text) if not any(mark in line for mark in excused)]


def refused_lines(text):
    """The line and text of every line of Objective-C++ `text` that prints a
    path, a patient's value, a URL, a description or an exception whole."""
    refused = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        call = OBJC_CALL.search(line)
        if call and OBJC_FORBIDDEN.search(line[call.end():]):
            refused.append((number, line.strip()))
    return refused


# The application's exception log, and the wrappers over it, which write the
# reason of an exception.
EXCEPTION_LOG = re.compile(r'_N2LogExceptionImpl\s*\(|\bN2LogException\w*\s*\(|\b\w+ObjC\.log\s*\(')


def exception_log_calls(text):
    """The lines of `text` that call the application's exception log."""
    return [number for number, line in enumerate(text.splitlines(), 1)
            if EXCEPTION_LOG.search(line) and not line.lstrip().startswith('//')]


# --- the controls -----------------------------------------------------------------
# What a scan must refuse, by what it is: (line of source, the argument refused).
REFUSED_CONTROLS = {
    'a patient\'s value': (
        ('NSLog("---- retrieving %@", study.patientID)', 'study.patientID'),
        ('NSLog("---- excluded series %@ clicked: not retrieved", placeholder.seriesDescription)', 'placeholder.seriesDescription'),
        ('NSLog("Search For %@: %@", kind,\n      searchString ?? "(null)")', 'searchString'),
        ('print("retrieving \\(node.name)")', 'node.name'),
    ),
    'the name of a file': (
        ('NSLog("---- WADO: wrote %@", (file as NSString).lastPathComponent)', 'lastPathComponent'),
        ('NSLog("---- retrieve: the manifest is at %@", inventory.path)', 'inventory.path'),
        ('FileHandle.standardError.write(Data("\\(draft.path)\\n".utf8))', 'draft.path'),
    ),
    'a URL with its query string': (
        ('NSLog("****** no url : %@", baseURL + "&studyUID=\\(uid)&objectUID=\\(objectUID)")', 'baseURL'),
        ('NSLog("---- WADO: asking %@", url.absoluteString)', 'url.absoluteString'),
        ('NSLog("horos URL not carried out, URL support is off: %@", request as NSString)', 'request'),
        ('N2LogStackTraceMessage("URL is not valid: \\(address.absoluteString)")', 'absoluteString'),
    ),
    'the description of an error': (
        ('NSLog("------ WADO retrieve: the credentials could not be read: %@", error.localizedDescription)', 'error.localizedDescription'),
        ('NSLog("---- retrieve: the response stopped (%@)",\n      cut.error.localizedDescription, fallback)', 'cut.error.localizedDescription'),
        ('NSLog("Shared database: request from %@ ended: %@", address, "\\(error)")', 'error'),
        ('NSLog("Horos Bonjour waiting for %@: %@", type, String(describing: error))', 'String(describing: error)'),
        ('NSLog("Horos Bonjour invalid TXT record: %@", error as NSError)', 'error as NSError'),
        ('NSLog("------ WADO retrieve incomplete: %@", manifest.detail(limit: 20))', 'manifest.detail(limit: 20)'),
        ('NSLog("*** listener error: %@ %@", title, message)', 'message'),
    ),
}
# And what it must accept: the same told as the log may have it.
ACCEPTED_CONTROLS = (
    'NSLog("---- retrieving %@", study.studyInstanceUID ?? "(null)")',
    'NSLog("---- C-FIND asks for: %@", QueryLog.term(key: key, value: study.patientID))',
    'NSLog("---- WADO: wrote %@", StoreReport.logName(ofFileAtPath: file))',
    'NSLog("---- WADO: asking %@", LogText.url(url))',
    'NSLog("------ WADO retrieve: the credentials could not be read: %@", LogText.error(error))',
    'NSLog("%@ (in %@): %@", exception.name.rawValue, function, LogText.exception(exception))',
    'NSLog("Search For %@: %@", kind, LogText.shape(of: searchString))',
    'NSLog("DNS-SD error=%d on port %ld, %d files", Int32(error), port, Int32(truncatingIfNeeded: files?.count ?? 0))',
    'NSLog("Shared database: request from %@ ended: %@ (%ld)", address, (error as NSError).domain, (error as NSError).code)',
    'NSLog("------ WADO retrieve incomplete: %@", manifest.logDetail(limit: 20))',
    'NSLog("---- %@: %@ files of %d", failure.category.rawValue, failure.logReason, Int32(paths.count))',
    'NSLog("***** unknown class: %@", String(describing: type(of: item)))',
)

# The text of a notice, shown or not: refused whole, accepted by its title and its length.
REFUSED_CONTROLS['the text of a notice'] = (
    ('NSLog("*** listener error (not displayed - hideListenerError): %@ %@ %@", "\\(msg[0])", "\\(msg[1])", "\\(msg[2])")', 'msg[1]'),
    ('NSLog("*** Bonjour Browser Error (not displayed - hideListenerError): %@", message)', 'message'),
    ('NSLog("*** listener error: %@ %@", LogText.notice(title: title, text: text), "\\(msg[1])")', 'msg[1]'),
)
ACCEPTED_CONTROLS += (
    'NSLog("*** listener error (not displayed - hideListenerError): %@", LogText.notice(title: title, text: text))',
    'NSLog("*** listener error: %@", LogText.notice(title: title, text: message))',
)


def control_failures(refuse=refused_arguments, kinds=None):
    """What `refuse` no longer refuses or accepts of the controls."""
    failures = []
    for kind, controls in REFUSED_CONTROLS.items():
        if kinds is not None and kind not in kinds:
            continue
        for line, argument in controls:
            if not any(argument in found for _, found in refuse(line)):
                failures.append('the scan no longer refuses %s, %r in %r' % (kind, argument, line))
    for line in ACCEPTED_CONTROLS:
        if refuse(line):
            failures.append('the scan refuses %r: %r' % (line, refuse(line)))
    return failures


if __name__ == '__main__':
    # What the rule finds, and every log call with what the scan says of it.
    import sys
    wanted = sys.argv[1:]
    for path, text in sorted(network_sources().items()):
        if wanted and not any(word in path.name for word in wanted):
            continue
        if path.suffix == '.swift':
            calls = log_calls(text)
            refused = {(line, argument) for line, argument in refused_in(path, text)}
            print('=== %s (%d calls)' % (path.relative_to(ROOT), len(calls)))
            for line, arguments in calls:
                for argument in arguments[1:] if arguments and arguments[0] == '""' else arguments:
                    if argument and argument != '""':
                        print('  %s%d: %s' % ('REFUSED ' if (line, argument) in refused else '', line, argument[:200]))
        else:
            print('=== %s (%d lines)' % (path.relative_to(ROOT), len([l for l in text.splitlines() if OBJC_CALL.search(l)])))
            for line, source in refused_lines_in(path, text):
                print('  REFUSED %d: %s' % (line, source[:200]))
