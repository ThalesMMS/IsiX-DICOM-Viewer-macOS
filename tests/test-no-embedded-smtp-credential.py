#!/usr/bin/env python3
"""The crash reporter carries no SMTP account or password.

AppController used to return, in clear text, the server, account and password
of the original project's crash report mailbox. FeedbackReporter never asked
for them; they only put a credential in the source and in the binary.
"""
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []

source = sources.source_text('AppController')
for selector in ('smtpServerForFeedbackReport', 'smtpPortForFeedbackRerport', 'smtpUsername', 'smtpPassword'):
    if 'func ' + selector + '(' in source:
        failures.append('AppController still answers %s' % selector)

binary = root / 'build/Build/Products/Debug/IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer'
if binary.is_file():
    strings = subprocess.run(['/usr/bin/strings', '-a', str(binary)], capture_output=True, text=True).stdout
    for selector in ('smtpPassword', 'smtpUsername', 'crashreport@gmail.com'):
        if selector in strings:
            failures.append('the Debug executable still contains %s' % selector)
else:
    print('note: no Debug build; checked the source only')

if failures:
    print('\n'.join('FAIL: ' + f for f in failures))
    sys.exit(1)
print('PASS: no SMTP account or password in AppController or the executable')
