#!/usr/bin/env python3
"""What the DICOM network and the web portal write stays out of /tmp (#801).

/tmp is writable by every user of the machine, and these files had fixed or
predictable names there, so another user could put them in place first:
- DICOM TLS: the trusted certificates' folder (a CA of theirs would be
  trusted), the private key, the certificate and the seed files; eraseKeys
  removed every /tmp entry with those prefixes, whoever had made it;
- the Query/Retrieve server's lock, state and error files, named after the
  association process's pid, which the browser also used to pick processes to
  kill;
- the portal's study and series ZIPs and its DICOM SR pages.
They go to the user's own temporary folder. And the TLS key's password is no
longer on openssl's command line, where every user saw it in ps.

Checked in the sources. `<git revision>` as an optional argument reads them from
that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def code(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


failures = []
for path in ('Horos/Sources/DICOMTLS.h', 'Horos/Sources/DICOMTLS.mm', 'Horos/Sources/HorosQueryRetrieveServer.mm',
             'Horos/Sources/OsiriXSCPDataHandler.mm', 'Horos/Sources/WebPortalConnection+Data.swift',
             'Horos/Sources/WebPortalConnection.swift'):
    if re.search(r'"/tmp', code(read(path))):
        failures.append(f'{path} still writes to /tmp')
# AppController is Swift since #830; its C functions stayed in AppController+CAPI.m.
for path in ('Horos/Sources/BrowserController.m', str(source_path('AppController').relative_to(root)),
             str(source_path('AppController+CAPI').relative_to(root))):
    for line in code(read(path)).split('\n'):
        if re.search(r'lock_process|process_state', line) and '/tmp' in line:
            failures.append(f'{path} still looks for the association processes\' files in /tmp')
            break
browser = code(read('Horos/Sources/BrowserController.m'))
kill_block = browser[browser.find('lock_process-'):browser.find('kill( pid, 15)') + 20] if 'kill( pid, 15)' in browser else ''
if '@"/tmp"' in kill_block:
    failures.append('the browser still kills processes named by files in /tmp')

tls = code(read('Horos/Sources/DICOMTLS.mm'))
if 'NSTemporaryDirectory()' not in tls or '0700' not in tls:
    failures.append('the TLS files are not in a folder of the user\'s own')
for user in ('Horos/Sources/DCMTKStoreSCU.mm', 'Horos/Sources/DCMTKServiceClassUser.mm'):
    if 'TLS_SEED_FILE cStringUsingEncoding' in code(read(user)):
        failures.append(f'{user} keeps a C string of a computed path past its autorelease pool')

keychain = code(read('cocoahttpserver/DDKeychain.m'))
if re.search(r'"pass:%@"', keychain):
    failures.append('the TLS key\'s password is still on openssl\'s command line')

server = code(read('Horos/Sources/HorosQueryRetrieveServer.mm'))
fork_at = server.find('fork()')
if fork_at < 0 or 'HorosDICOMProcessFolder();' not in server[max(0, fork_at - 200):fork_at]:
    failures.append('the processes\' folder is not settled in the app before it forks')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: DICOM TLS, the Q/R server and the portal keep their files in the user\'s temporary folder; no password on a command line')
