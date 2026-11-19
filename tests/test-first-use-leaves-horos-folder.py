#!/usr/bin/env python3
"""Nothing is written into a Horos or OsiriX data folder before first use is answered.

A launch whose location is still a Horos database asks "IsiX DICOM Viewer is
using the Horos database" before the database opens, and says the Horos
database is left as it is. The report templates (PAGES TEMPLATES/IsiX Basic
Report.pages, WORD TEMPLATES/Basic Report Template.docx) were installed at the
start of the launch, before that question, into whatever folder the location
resolved to: the Horos one. They are installed now only when no first-use
answer is pending; the database the answer opens gets them as it opens.

The browser's window loads before that question, and its toolbar asks for the
Word or Pages templates as the Report item is made. Without a database yet,
the templates folder came from the location the launch opens: the Word one was
created there, and the Pages '09 templates were copied into the Pages one.
While first use is pending there is no templates folder now, and the copy
waits for one.

Checked in the sources, as the launch reaches them only through the
application. Pass --source <ApplicationLifecycle.swift> or
--reports <Reports.swift> to check an earlier copy as a negative control.
"""
import argparse
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=root / 'Horos/Sources/ApplicationLifecycle.swift')
parser.add_argument('--reports', type=Path, default=root / 'Horos/Sources/Reports.swift')
args = parser.parse_args()
failures = []

launch = args.source.read_text()
start = launch.index('static func initializeProcess()')
initialize = launch[start:launch.index('\n    }\n', start)]
guarded = re.search(r'\n( +)if !DatabaseFirstUse\.hasPendingChoice \{\n'
                    r'\1    Reports\.checkForWordTemplates\(\)\n'
                    r'\1    Reports\.checkForPagesTemplate\(\)\n'
                    r'\1\}\n', initialize + '\n')
if not guarded:
    failures.append('the start installs the report templates while a first-use answer is pending')
if initialize.count('Reports.checkFor') != 2:
    failures.append('the start installs report templates %d times, expected the two guarded calls' % initialize.count('Reports.checkFor'))
# The crash marker of the start is not written there either.
if 'if !DatabaseFirstUse.hasPendingChoice {\n            let path = (DicomDatabase.defaultBaseDirPath()' not in initialize:
    failures.append('the Loading marker of the start is written while a first-use answer is pending')

# The database the answer opens installs them as it opens: they come from the
# browser's database or, before it has one, from the location the answer set.
database = (root / 'Horos/Sources/DicomDatabase.swift').read_text()
opening = database[database.index('// report templates'):]
opening = opening[:opening.index('DatabaseTemplateInstaller(database: self).install()')]
# In every channel: the App Store build makes reports too, and when the
# condition of that build left this out, a database it opened had no template.
installed = database[database.index('// report templates'):database.index('DatabaseTemplateInstaller(database: self).install()')]
if 'MACAPPSTORE' in installed:
    failures.append('the App Store build no longer installs the report templates in the database it opens')
for call in ('Reports.checkForPagesTemplate()', 'Reports.checkForWordTemplates()'):
    if call not in opening:
        failures.append('a database that opens does not install its templates (%s)' % call)

# The templates folders come from one place: the browser's database or, before
# it has one, the location chosen; none while first use is pending, since the
# browser's toolbar lists the templates before the question.
reports = args.reports.read_text()


def body_of(function):
    if function not in reports:
        return None
    body = reports[reports.index(function):]
    return body[:body.index('\n    }\n')]


helper = body_of('func templatesDatabaseDirPath()')
if helper is None:
    failures.append('Reports has no single source of its templates folders (templatesDatabaseDirPath)')
else:
    browser = helper.find('BrowserDatabaseSource.process.browserDatabase?.baseDirPath')
    pending = re.search(r'if DatabaseFirstUse\.hasPendingChoice \{\s*return nil\s*\}', helper)
    location = helper.find('DicomDatabase.defaultBaseDirPath()')
    if browser < 0 or location < 0:
        failures.append('the templates folders no longer come from the browser database, or the location chosen')
    elif not pending or not browser < pending.start() < location:
        failures.append('the templates folders come from the location the launch opens while a first-use answer is pending')
for function in ('func checkForWordTemplates()', 'func databaseWordTemplatesDirPath()', 'func databasePagesTemplatesDirPath()'):
    body = body_of(function)
    if body is None or 'templatesDatabaseDirPath()' not in body:
        failures.append('%s does not take its folder from templatesDatabaseDirPath()' % function)
if reports.count('defaultBaseDirPath()') != 1:
    failures.append('Reports asks %d times for the location the launch opens, expected once, in templatesDatabaseDirPath()'
                    % reports.count('defaultBaseDirPath()'))
# The Word list creates its folder through databaseWordTemplatesDirPath; the
# Pages list copies the Pages '09 templates once per process, and only into a
# folder: with none, the copy is neither made nor spent.
word = body_of('func resolvedDatabaseWordTemplatesDirPath()')
if word is None or 'self.databaseWordTemplatesDirPath()' not in word:
    failures.append('the Word templates list no longer takes its folder from databaseWordTemplatesDirPath()')
pages = body_of('func pagesTemplatesList()')
if (pages is None or 'self.databasePagesTemplatesDirPath()' not in pages
        or not re.search(r'if let templateDirectory, pagesTemplatesFirstTime\.exchange\(', pages)
        or pages.count('pagesTemplatesFirstTime') != 1):
    failures.append("the Pages '09 templates are copied, or their once-per-process copy is spent, without a templates folder")

# Nobody else installs them: a new caller has to be weighed against first use.
callers = []
for path in sorted((root / 'Horos/Sources').rglob('*')):
    if path.suffix not in ('.swift', '.m', '.mm') or path.name == 'Reports.swift':
        continue
    text = path.read_text(errors='replace')
    if re.search(r'\bcheckFor(Word|Pages)Templates?\b', text):
        callers.append(path.name)
if callers != ['ApplicationLifecycle.swift', 'DicomDatabase.swift']:
    failures.append('the report templates are installed from %s' % callers)

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('PASS: no report template or templates folder is written before a first-use answer, by the start or by the toolbar; '
      'the database the answer opens installs them')
