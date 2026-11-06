#!/usr/bin/env python3
"""What the DICOM network and the web portal write stays out of /tmp.

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
from sources import source_path, class_text  # noqa: E402
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        # A file the revision did not have yet holds nothing to check.
        return shown.stdout.decode('latin1') if shown.returncode == 0 else ''
    if not (root / path).exists():
        return ''
    return (root / path).read_bytes().decode('latin1')


def code(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


failures = []
# The listener is the DCMTK adapter's IsiXDCMTKQueryRetrieveSCP and
# IsiXDCMTKSCPDatabase, and the Swift that answers it; earlier revisions had
# HorosQueryRetrieveServer.mm and OsiriXSCPDataHandler.mm.
LISTENER = ('Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.mm', 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKSCPDatabase.mm',
            'Horos/Sources/DCMTKQueryRetrieveSCP.swift', 'Horos/Sources/SCPDatabaseSession.swift',
            'Horos/Sources/SCPDatabaseSession+Find.swift', 'Horos/Sources/SCPDatabaseSession+Retrieve.swift',
            'Horos/Sources/HorosQueryRetrieveServer.mm', 'Horos/Sources/OsiriXSCPDataHandler.mm')
for path in ('Horos/Sources/DICOMTLS.h', 'Horos/Sources/DICOMTLS.swift', *LISTENER,
             'Horos/Sources/WebPortalConnection+Data.swift', 'Horos/Sources/WebPortalConnection.swift'):
    if re.search(r'"/tmp', code(read(path))):
        failures.append(f'{path} still writes to /tmp')
# AppController is Swift; its C functions stayed in AppController+CAPI.m.
for path in (str(source_path('BrowserController').relative_to(root)), 'Horos/Sources/BrowserController+CAPI.m',
             str(source_path('AppController').relative_to(root)),
             str(source_path('AppController+CAPI').relative_to(root))):
    for line in code(read(path)).split('\n'):
        if re.search(r'lock_process|process_state', line) and '/tmp' in line:
            failures.append(f'{path} still looks for the association processes\' files in /tmp')
            break
browser = code(class_text('BrowserController'))
kill_block = browser[browser.find('lock_process-'):browser.find('kill( pid, 15)') + 20] if 'kill( pid, 15)' in browser else ''
if '@"/tmp"' in kill_block:
    failures.append('the browser still kills processes named by files in /tmp')

tls = code(read('Horos/Sources/DICOMTLS.swift'))
if 'NSTemporaryDirectory()' not in tls or '0o700' not in tls:
    failures.append('the TLS files are not in a folder of the user\'s own')
# The seed path DCMTK takes is a C string kept for the life of the application,
# not one of a computed path that dies with its autorelease pool.
if 'strdup(' not in tls[tls.find('seedFile ='):]:
    failures.append('the TLS seed path is not kept as a C string of its own')
for user in ('Horos/Sources/DCMTKStoreSCU+Association.swift', 'Horos/Sources/DCMTKQueryNode.swift'):
    if 'TLS_SEED_FILE' in code(read(user)) or 'DICOMTLS.seedFilePath()' not in code(read(user)):
        failures.append(f'{user} does not take the seed path DICOMTLS keeps')

# The Keychain exports and the web server's identity run openssl with their
# passwords in its environment, not on its command line.
keychain = '\n'.join(code(read(path)) for path in ('Modules/IsiXKeychain/Sources/KeychainExport.swift',
                                                   'Modules/IsiXKeychain/Sources/WebServerIdentity.swift'))
if re.search(r'"pass:', keychain) or keychain.count('env:') < 3:
    failures.append('a TLS key\'s password is on openssl\'s command line')

server = '\n'.join(code(read(path)) for path in LISTENER)
# The listener no longer forks: no child process, no lock or state files
# to exchange with one; the folder stays the user's own for what an earlier
# version left there.
if re.search(r'\bfork\s*\(', server):
    failures.append('the listener still forks a process per association')
folder = server[server.find('HorosDICOMProcessFolder'):] if 'HorosDICOMProcessFolder' in server else ''
if 'NSTemporaryDirectory()' not in folder[:600]:
    failures.append('the processes\' folder is not the user\'s own temporary folder')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: DICOM TLS, the Q/R server and the portal keep their files in the user\'s temporary folder; no password on a command line')
