#!/usr/bin/env python3
"""What each distribution channel is entitled to ask of other applications.

Four features talk to another application with Apple Events: the import into
Photos, the draft in Mail and the reports in Microsoft Word and in Pages. A channel without
the App Sandbox needs the Apple Events entitlement of the hardened runtime and
the text of the consent panel. A sandboxed channel sends an Apple Event to
another application only with the scripting targets entitlement (the access
groups the application publishes in its scripting definition) or with the
Apple Events temporary exception (a list of bundle identifiers); the Photos
library, used without Apple Events, has an entitlement and a text of its own.

The expectations are the table below, one row per channel, read against the
entitlements files the channels' configurations name and the Info.plist both
share. Whatever a row allows must name only applications the sources address.

A second table has every application a script of the application names, file
by file, with what the App Store channel does about it. The sources and the
script resources are searched for the applications their scripts address
(`tell application`, `using terms from application`, by name or by
identifier, and the JavaScript form), and for who asks macOS about an
application by its bundle identifier: one the table does not have fails the
test, so an application is never reached from the sandbox without a decision.

Nothing is refused in the App Store channel. The one script the sandbox would
refuse, the Mail client that tells Mail to send, is not run there: the web
portal's e-mails, its only use, go by SMTP to the portal's own server, and the
route through Mail is compiled for the direct channel alone. And no source
addresses a spreadsheet application: the surgical log is imported from CSV.
"""
from pathlib import Path
import plistlib
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import FOLDERS, source_text  # noqa: E402

SANDBOX = 'com.apple.security.app-sandbox'
AUTOMATION = 'com.apple.security.automation.apple-events'
TARGETS = 'com.apple.security.scripting-targets'
EXCEPTION = 'com.apple.security.temporary-exception.apple-events'
PHOTOS_LIBRARY = 'com.apple.security.personal-information.photos-library'
ABSENT = None

# The applications the exports address, and the source that names each.
ADDRESSED = {
    'com.apple.Photos': 'Photos',
    'com.apple.mail': 'MailDraftComposer',
    'com.microsoft.Word': 'WordReportAutomation',
    'com.apple.Pages': 'PagesApplication',
    'com.apple.iWork.Pages': 'PagesApplication',
}

# ---------------------------------------------------------------------------
# THE APP STORE ROW. The sandboxed channel reaches Photos and Mail by the
# access groups they publish: the import and the albums of Photos, the
# outgoing messages of Mail. Microsoft Word and Pages publish no access group
# for what a report needs of them (opening, filling, saving, exporting), so
# the reports reach them by the Apple Events exception, under both bundle
# identifiers Pages has had. This is the one expectation to change with the
# entitlements file (and Info.plist, for the Photos library) in the same
# change. TARGETS is a dictionary of bundle identifier to access groups,
# EXCEPTION a list of bundle identifiers, the two others True.
# ---------------------------------------------------------------------------
APP_STORE_TARGETS = {
    'com.apple.Photos': ['com.apple.Photos.import', 'com.apple.Photos.library.read-write'],
    'com.apple.mail': ['com.apple.mail.compose'],
}
APP_STORE_EXCEPTION = ['com.microsoft.Word', 'com.apple.Pages', 'com.apple.iWork.Pages']
APP_STORE_AUTOMATION = {AUTOMATION: ABSENT, TARGETS: APP_STORE_TARGETS, EXCEPTION: APP_STORE_EXCEPTION,
                        PHOTOS_LIBRARY: ABSENT}

CHANNELS = {
    'GitHub': ('Horos/Horos.entitlements',
               {SANDBOX: ABSENT, AUTOMATION: True, TARGETS: ABSENT, EXCEPTION: ABSENT, PHOTOS_LIBRARY: ABSENT}),
    'AppStore': ('Horos/Configuration/AppStore.entitlements', {SANDBOX: True, **APP_STORE_AUTOMATION}),
}

for bundle, source in ADDRESSED.items():
    assert '"%s"' % bundle in source_text(source), '%s no longer names %s' % (source, bundle)

info = plistlib.loads((root / 'Horos/Info.plist').read_bytes())
uses_photos_library = False
for channel, (path, expected) in CHANNELS.items():
    configuration = (root / 'Horos/Configuration' / (channel + '.xcconfig')).read_text()
    assert 'HOROS_APP_ENTITLEMENTS = %s\n' % path in configuration, '%s does not sign with %s' % (channel, path)
    entitlements = plistlib.loads((root / path).read_bytes())
    for key, value in expected.items():
        assert entitlements.get(key) == value, '%s: %s is %r, expected %r' % (channel, key, entitlements.get(key), value)

    sandboxed = entitlements.get(SANDBOX) is True
    targets = entitlements.get(TARGETS) or {}
    exception = entitlements.get(EXCEPTION) or []
    assert isinstance(targets, dict) and isinstance(exception, list), channel
    for bundle, groups in targets.items():
        assert bundle in ADDRESSED, '%s: scripting target %s is not an application the exports address' % (channel, bundle)
        assert groups and all(isinstance(group, str) and group.startswith(bundle + '.') for group in groups), (channel, bundle, groups)
    for bundle in exception:
        assert bundle in ADDRESSED, '%s: Apple Events exception for %s, which no export addresses' % (channel, bundle)
        assert bundle not in targets, '%s: %s has both access groups and the exception' % (channel, bundle)
    if not sandboxed:
        # Without the sandbox the two sandbox keys do nothing: the hardened
        # runtime's entitlement is the one that lets the consent panel show.
        assert not targets and not exception, '%s: sandbox entitlements without the sandbox' % channel
    sends_apple_events = bool(entitlements.get(AUTOMATION) or targets or exception)
    if sends_apple_events:
        assert info.get('NSAppleEventsUsageDescription', '').strip(), 'no text for the Automation consent panel'
    uses_photos_library = uses_photos_library or bool(entitlements.get(PHOTOS_LIBRARY))
    print('%s: sandbox %s, Apple Events %s' % (
        channel, 'on' if sandboxed else 'off',
        'by ' + ', '.join(key.rsplit('.', 1)[-1] for key in (AUTOMATION, TARGETS, EXCEPTION) if entitlements.get(key))
        if sends_apple_events else 'not entitled'))

# The Photos library asks with a text of its own, and only a channel that is
# entitled to the library needs it.
photos_texts = [key for key in ('NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription') if key in info]
assert bool(photos_texts) == uses_photos_library, (photos_texts, uses_photos_library)
assert all(info[key].strip() for key in photos_texts)
# The GitHub channel is the one that works today: its consent text is there.
assert info['NSAppleEventsUsageDescription'].strip()
print('PASS: the entitlements of both channels for Apple Events and the Photos library are the expected ones')

# ---------------------------------------------------------------------------
# EVERY APPLICATION A SCRIPT NAMES, file by file, and what the App Store
# channel does about it:
#   GROUPS    the script keeps to what the access groups of the channel cover;
#   EXCEPTED  the application is in the Apple Events exception;
#   NOT_RUN   nothing entitles what is sent, and the channel never sends it:
#             the script is compiled, for the class and the selectors it is
#             part of, and the application's own callers are compiled for the
#             direct channel alone. The row says what does the work instead,
#             and the callers are checked below;
#   REFUSED   nothing entitles what is sent: the sandbox refuses it. A row
#             stays here until the feature is given another way or is not
#             offered in that channel, and says what keeps it out.
# The GitHub channel sends them all, with the user's consent.
# ---------------------------------------------------------------------------
GROUPS, EXCEPTED, NOT_RUN, REFUSED = 'access groups', 'exception', 'not run', 'refused'
APPLICATIONS = {
    'Photos': ('com.apple.Photos',),
    'Mail': ('com.apple.mail',),
    'Microsoft Word': ('com.microsoft.Word',),
    'Pages': ('com.apple.Pages', 'com.apple.iWork.Pages'),
}
# How a script spells an application it finds at run time: always Pages, by
# the identifier of the copy that is installed.
COMPUTED = {'bundleId': 'Pages', '__PAGES_BUNDLE_ID__': 'Pages', r'\(application)': 'Pages', r'\(pages.identifier)': 'Pages'}
SCRIPTS = {
    'Horos/Sources/Photos.swift': {'Photos': GROUPS},
    'Horos/Sources/Mailer.swift': {'Mail': GROUPS},
    'Horos/Resources/Mail.applescript': {'Mail': GROUPS},
    # The web portal's e-mails through Mail: `send`, which no access group of
    # Mail has. The App Store channel sends them by SMTP instead.
    'Horos/Sources/CSMailMailClient.swift': {'Mail': NOT_RUN},
    'Horos/Sources/Reports.swift': {'Microsoft Word': EXCEPTED},
    'Horos/Sources/ReportImagePlacement.swift': {'Microsoft Word': EXCEPTED, 'Pages': EXCEPTED},
    'Horos/Resources/ReportsToPDF/word2pdf.applescript': {'Microsoft Word': EXCEPTED},
    'Horos/Sources/PagesApplication.swift': {'Pages': EXCEPTED},
    'Horos/Sources/PagesDocumentFill.swift': {'Pages': EXCEPTED},
    'Horos/Sources/PagesPDFConversion.swift': {'Pages': EXCEPTED},
}
# Who names an application by its bundle identifier outside a script: to ask
# macOS whether it may automate it, or to send it an event made by hand.
DESCRIPTORS = {
    'Horos/Sources/MailDraftComposer.swift': {'Mail': GROUPS},
    'Horos/Sources/WordReportAutomation.swift': {'Microsoft Word': EXCEPTED},
    # Quits Mail before a message with a Reply-To: the same route through Mail.
    'Horos/Sources/CSMailMailClient.swift': {'Mail': NOT_RUN},
}

TARGET = re.compile(r'(?:\btell|\busing terms from) application(?: id)? (?:\\?"((?:[^"\\]|\\\()+)\\?"|([A-Za-z_]\w*))'
                    r'''|\bApplication\(\s*["']([^"']+)["']''')
DESCRIPTOR = re.compile(r'NSAppleEventDescriptor\(bundleIdentifier:|typeApplicationBundleID')
COMMENT = ('//', '--', '*', '/*')
files = sorted({path for folder in FOLDERS for path in (root / folder).rglob('*') if path.suffix in ('.swift', '.m', '.mm')}
               | {path for path in (root / 'Horos/Resources').rglob('*') if path.suffix in ('.applescript', '.jxa')})
# A compiled script cannot be read here: the resources keep their scripts as text.
compiled = [str(path.relative_to(root)) for path in (root / 'Horos/Resources').rglob('*.scpt*')]
assert not compiled, 'compiled scripts among the resources, which this test cannot read: %s' % compiled

scripted, described = {}, set()
for path in files:
    name = str(path.relative_to(root))
    for line in path.read_bytes().decode('utf-8', 'replace').splitlines():
        if line.lstrip().startswith(COMMENT):
            continue
        for match in TARGET.finditer(line):
            spelling = next(group for group in match.groups() if group)
            application = COMPUTED.get(spelling, spelling)
            assert application in APPLICATIONS, (
                '%s has a script that addresses %r, an application the table of this test does not have: '
                'decide what the App Store channel does about it' % (name, spelling))
            scripted.setdefault(name, set()).add(application)
        if DESCRIPTOR.search(line):
            described.add(name)
assert scripted == {name: set(row) for name, row in SCRIPTS.items()}, (
    'the scripts and the table differ: %s' % sorted(
        (name, sorted(scripted.get(name, ())), sorted(SCRIPTS.get(name, ()))) for name in set(scripted) | set(SCRIPTS)
        if scripted.get(name, set()) != set(SCRIPTS.get(name, ()))))
assert described == set(DESCRIPTORS), sorted(described ^ set(DESCRIPTORS))
for name, row in DESCRIPTORS.items():
    text = (root / name).read_text()
    assert any('"%s"' % bundle in text for application in row for bundle in APPLICATIONS[application]), name

# Each row against the entitlements of the App Store channel.
refused, not_run = set(), set()
for name, row in sorted({**SCRIPTS, **{name + ' (descriptor)': row for name, row in DESCRIPTORS.items()}}.items()):
    for application, status in row.items():
        bundles = APPLICATIONS[application]
        if status == GROUPS:
            assert all(bundle in APP_STORE_TARGETS for bundle in bundles), (name, application)
        elif status == EXCEPTED:
            assert all(bundle in APP_STORE_EXCEPTION for bundle in bundles), (name, application)
        elif status == NOT_RUN:
            not_run.add((name.split(' ')[0], application))
        else:
            assert status == REFUSED, (name, application, status)
            refused.add((name.split(' ')[0], application))
assert not refused, sorted(refused)
assert not_run == {('Horos/Sources/CSMailMailClient.swift', 'Mail')}, sorted(not_run)

# What makes each row what it is. Mail's group has the outgoing message, its
# text and attachments, and no `send`: the scripts within it never send, and
# the one that does is the one the App Store channel does not run.
mailer = ''.join(re.findall(r's\.append\("(.*)"\)', source_text('Mailer')))
assert 'make new outgoing message' in mailer and not re.search(r'\bsend\b', mailer), mailer
assert not re.search(r'\bsend\b', (root / 'Horos/Resources/Mail.applescript').read_text())
assert '"    send msg\\n"' in source_text('CSMailMailClient')


def store_lines(text):
    """The lines of a Swift source the App Store build compiles, directives aside."""
    conditions, lines = [], []
    for line in text.splitlines():
        directive = line.strip()
        if directive.startswith('#if'):
            conditions.append({'MACAPPSTORE': True, '!MACAPPSTORE': False}.get(directive[3:].strip()))
        elif directive.startswith('#elseif'):
            conditions[-1] = None
        elif directive.startswith('#else'):
            conditions[-1] = None if conditions[-1] is None else not conditions[-1]
        elif directive.startswith('#endif'):
            conditions.pop()
        elif all(condition is not False for condition in conditions):
            lines.append(line)
    return lines


# NOT_RUN: the client's script runs from -deliverMessage:headers: and the
# selectors it calls, and no line the App Store build compiles sends them,
# by name or through a selector made from text. The one caller is the portal's
# delivery, which gives the route through Mail to the direct channel alone and
# refuses to keep one in the App Store build whoever gives it.
DELIVERS = re.compile(r'deliverMessage|doHandler|deliver_message|construct_message')
callers = {}
for path in files:
    name = str(path.relative_to(root))
    if name == 'Horos/Sources/CSMailMailClient.swift':
        continue
    text = path.read_bytes().decode('utf-8', 'replace')
    compiled = store_lines(text) if path.suffix == '.swift' else text.splitlines()
    found = [line.strip() for line in compiled if DELIVERS.search(line) and not line.lstrip().startswith(COMMENT)]
    if DELIVERS.search(text):
        callers[name] = found
assert callers == {'Horos/Sources/WebPortalMailPassword.swift': []}, callers
assert DELIVERS.search('\n'.join(store_lines(source_text('CSMailMailClient')))), 'the control: the client itself is compiled'
delivery = source_text('WebPortalMailDelivery')
assert 'static let sendsThroughMailApplication = false' in store_lines(delivery)[
    store_lines(delivery).index('    /// Whether this build may send through the Mail application.') + 1], 'the App Store build keeps a route through Mail'
assert 'self.mailApplication = WebPortalMailDelivery.sendsThroughMailApplication ? mailApplication : nil' in delivery
# No source addresses a spreadsheet application, by name or by identifier: the
# reader of such a document that the surgical log's model keeps is run by
# nothing, and the browser asks macOS nothing about one.
assert [str(path.relative_to(root)) for path in files if 'numbersReaderScript' in path.read_bytes().decode('utf-8', 'replace')] \
    == ['Horos/Sources/SurgicalProcedureImport.swift']
assert not [str(path.relative_to(root)) for path in files
            if re.search(r'com\.apple\.(?:iWork\.)?Numbers', path.read_bytes().decode('utf-8', 'replace'))]
# System Settings is opened by its address, which is no Apple Event: the scan
# above found no script that names it, and the pane that opens it has none.
listener = source_text('OSIListenerPreferencePanePref')
assert 'NSAppleScript' not in listener and 'x-apple.systempreferences:' in listener
print('PASS: %d files address %d applications by script, each with its row; refused in the App Store channel: none; '
      'compiled and not run there: %s' % (
          len(scripted), len({application for row in scripted.values() for application in row}),
          ', '.join('%s (%s)' % (application, Path(name).name) for name, application in sorted(not_run))))
