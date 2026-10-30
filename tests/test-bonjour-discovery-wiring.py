#!/usr/bin/env python3
"""Sources and the database publisher use the native Bonjour path.

Source level, with `<git revision>` as an optional argument for the negative
control:

* the Sources helper browses with `HorosBonjourBrowser` for both service types
  and stops them on teardown;
* it handles find, remove and **update**, and an update refreshes the row it
  already has instead of removing and re-adding it;
* the database publisher advertises through `HorosBonjourAdvertisement`,
  created only for a live listener's port and stopped with it;
* the DICOM listener is advertised (`_dicom._tcp`, AE title, TXT record) through
  `HorosBonjourAdvertisement` too, and DICOM nodes are discovered with
  `HorosBonjourBrowser` (Network.framework) by `DICOMBonjourDiscovery`, never
  with NSNetServiceBrowser or a published NSNetService;
* the NSNetService-typed API other code still uses is kept: the deprecated
  `-netService` accessor and `AppController.dicomBonjourPublisher` (declared
  in Swift);
* no Bonjour TXT record carries a token or a secret.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources as source_files  # `sources` below is the Sources helper's text


def read(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


# BrowserController (Sources) is Swift: its helper is read in the Swift source.
sources = read(str(source_files.source_path('BrowserController+Sources').relative_to(root)))
# BonjourPublisher is Swift: its members are read in the Swift source.
publisher = read(str(source_files.source_path('BonjourPublisher').relative_to(root)))
# AppController is Swift: dicomBonjourPublisher is declared in the Swift source.
app = read(str(source_files.source_path('AppController').relative_to(root)))
node_service = read('Horos/Sources/DICOMNodeService.swift')
try:
    dicom_discovery = read('Horos/Sources/DICOMBonjourDiscovery.swift')
except Exception:
    dicom_discovery = ''
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


def swift_method(source, signature):
    """A Swift method, from its signature to the brace that closes its body."""
    start = source.find(signature)
    if start < 0:
        return ''
    depth = 0
    for end in range(source.index('{', start), len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    return ''


# --- Sources ------------------------------------------------------------------
if 'private var _nsbOsirix: HorosBonjourBrowser?' not in sources or 'private var _nsbDicom: HorosBonjourBrowser?' not in sources:
    failures.append('the Sources helper still browses with NSNetServiceBrowser')
if 'HorosBonjourBrowserDelegate' not in sources:
    failures.append('the Sources helper does not implement the native browser delegate')
for selector in ('didFindService:', 'didRemoveService:', 'didUpdateService:', 'didNotSearch:'):
    if '@objc(horosBonjourBrowser:%s)' % selector not in sources:
        failures.append('the Sources helper does not handle %s' % selector)
update = swift_method(sources, 'public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didUpdate service: BonjourService)')
if 'resolve(withTimeout' not in update:
    failures.append('an updated service is not resolved again')
if 'removeObject' in update or 'didRemove' in update:
    failures.append('an update must refresh the row, never remove it')
if '_nsbDicom?.stop()' not in sources or '_nsbOsirix?.stop()' not in sources:
    failures.append('the browsers are not stopped on teardown')
if re.search(r'\b(NS)?NetServiceBrowser\(', sources):
    failures.append('an NSNetServiceBrowser is still constructed for the Sources list')

# --- publisher ----------------------------------------------------------------
update_bonjour = swift_method(publisher, 'func updateBonjour() {')
if 'BonjourAdvertisement(name:' not in update_bonjour:
    failures.append('the database publisher does not advertise natively')
# The advertisement is made on the main actor, from the port read
# off the listener before the hop.
if not re.search(r'let listener = _listener\b', update_bonjour) or not (
        re.search(r'BonjourAdvertisement\(name:[^;]*?port: listener\.port\)', update_bonjour)
        or (re.search(r'let port = listener\.port\b', update_bonjour)
            and re.search(r'BonjourAdvertisement\(name:[^;]*?port: port\)', update_bonjour))):
    failures.append('the advertisement is not created from the live listener port')
if 'publish(txtRecord: txtrec' not in update_bonjour and not (
        'let record = txtrec' in update_bonjour and 'publish(txtRecord: record)' in update_bonjour):
    failures.append('the advertisement does not publish the TXT record the host builds')
if not re.search(r'_?advertisement\??\.stop\(\)', update_bonjour):
    failures.append('the advertisement is not stopped when the listener goes')
if publisher.count('_advertisement = nil') < 2:
    failures.append('the advertisement is not released on teardown and on listener change')
if '@objc public func netService() -> NetService?' not in publisher:
    failures.append('the deprecated netService accessor was removed while it still has callers')
# Two registrations of one name and port from one process make the daemon rename
# one of them: the legacy object stays for its accessor's type, unpublished.
if re.search(r'_bonjour\??!?\.publish\(', update_bonjour):
    failures.append('the legacy NSNetService is published beside the native advertisement')

# --- preserved public API -----------------------------------------------------
if not re.search(r'@objc public var dicomBonjourPublisher: NetService!? \{', app):
    failures.append('AppController.dicomBonjourPublisher changed type; plugins read it')

# --- DICOM node advertisement and discovery -----------------------------------
start_dicom = swift_method(app, '@objc(startDICOMBonjour:) func startDICOMBonjour(')
if not re.search(r'BonjourAdvertisement\(name: name, type: "_dicom\._tcp\.", port: Int\(port\)\)', start_dicom):
    failures.append('the DICOM listener is not advertised natively as _dicom._tcp')
if 'publish(txtRecord: record)' not in start_dicom:
    failures.append('the DICOM advertisement does not publish the TXT record built for it')
if re.search(r'BonjourDICOMService\??!?\.publish\(', app):
    failures.append('the legacy NSNetService of the DICOM listener is published')
if 'DICOMNodeService.shared.publisher = advertisement' not in start_dicom:
    failures.append('the node list does not leave this process\'s own advertisement out')
if 'HorosBonjourBrowser()' not in dicom_discovery or '"_dicom._tcp."' not in dicom_discovery:
    failures.append('DICOM nodes are not discovered with the native browser')
if re.search(r'\b(NS)?NetServiceBrowser\b', node_service + dicom_discovery):
    failures.append('the DICOM node list still browses with NSNetServiceBrowser')
if '@objc public var advertisement: BonjourAdvertisement?' not in publisher:
    failures.append('the publisher does not expose its advertisement for validation')
if 'private var _advertisement: BonjourAdvertisement?' not in publisher:
    failures.append('the publisher has no advertisement ivar')

# --- no secrets on the wire ---------------------------------------------------
txt_keys = set(re.findall(r'txtrec\.setObject\([^\n]*forKey: "([^"]+)" as NSString\)', publisher))
forbidden = {key for key in txt_keys if re.search(r'token|secret|password|key$|credential', key, re.I)}
if forbidden:
    failures.append('a Bonjour TXT record would carry %s' % ', '.join(sorted(forbidden)))
if not {'AETitle', 'port'} <= txt_keys:
    failures.append('the advertised TXT lost the AE title or the port: %s' % sorted(txt_keys))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: Sources and the database publisher use native Bonjour; NSNetService API preserved')
