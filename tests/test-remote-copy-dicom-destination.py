#!/usr/bin/env python3
"""Images of a remote Horos database reach a DICOM node at its own address.

-[BrowserController copyRemoteImagesToRemoteBrowserSourceThread:] read the DICOM
destination with the "AET@host" parser. A node entered in the preferences or
resolved through Bonjour keeps its host, port and AE title in separate fields,
without an "@": the other Horos was asked to send the images to no address, on
port 0, with the node's address as AE title. DataNodeIdentifier overrode
-isEqual: without -hash, so equal nodes landed apart in sets and dictionaries.

This compiles, against stubs for what they import, DataNodeIdentifier.m,
RemoteDataNodeIdentifier.swift and the destination part of the copy thread
(from the DicomNodeIdentifier case to the SCU request), then:

1. resolves, as the thread does, an entered node, a node resolved through
   Bonjour and a node with an "AET@host" location, all naming a fake store SCP
   on 127.0.0.1 that requires its AE title, and sends a synthetic CT image to
   what each resolved, as the other Horos does with the DCMSE request: each
   must arrive;
2. resolves a node without a port to 11112, and refuses a Bonjour node not yet
   resolved instead of sending it anywhere;
3. checks that equal nodes, DICOM, local and remote databases, have the same
   -hash, and that a set holds a DICOM node once however it was listed.

Needs a Python with pydicom and pynetdicom: local-validation/fixture-venv (here
or in the main checkout); without one it is skipped (exit 2). Only 127.0.0.1.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import json
import socket
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8')


def network_python():
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True).stdout.strip()
    checkouts = [root] + ([Path(common).parent] if common else [])
    candidates = [Path(sys.executable)]
    for checkout in checkouts:
        for venv in ('fixture-venv', 'dcmtk-venv', 'venv'):
            candidates.append(checkout / 'local-validation' / venv / 'bin' / 'python')
    for candidate in candidates:
        if candidate.is_file() and subprocess.run([str(candidate), '-c', 'import pydicom, pynetdicom'],
                                                  capture_output=True).returncode == 0:
            return str(candidate)
    return None


python = network_python()
if python is None:
    print('skipped: needs local-validation/fixture-venv with pydicom and pynetdicom', file=sys.stderr)
    sys.exit(2)

nodes = read('Horos/Sources/RemoteDataNodeIdentifier.swift')
base = read('Horos/Sources/DataNodeIdentifier.m')
header = read('Horos/Sources/DataNodeIdentifier.h')
copy = read('Horos/Sources/BrowserController+Sources+Copy.swift')

thread = copy[copy.index('func copyRemoteImagesToRemoteBrowserSourceThread'):]
start = thread.index('if let destination = destination as? DicomNodeIdentifier {')
end = thread.index('thread.status = String(format: NSLocalizedString("Sending SCU request...', start)
destination_part = thread[start:end]
# The helper the part reads its ports with, where the file has it.
helper_start = copy.find('fileprivate func copyIntegerValue(')
copy_helper = copy[helper_start:copy.index('\n}\n', helper_start) + 3] if helper_start >= 0 else ''

# What DataNodeIdentifier.m and .h import, with only what they use.
STUBS = {
    'PrettyCell.h': '#import <Cocoa/Cocoa.h>\n@interface PrettyCell : NSTextFieldCell\n@end\n',
    'RemoteDicomDatabase.h': '#import <Cocoa/Cocoa.h>\n@interface DicomDatabase : NSObject\n'
                             '+(NSString*)baseDirPathForPath:(NSString*)path;\n@end\n',
    'NSImage+N2.h': '#import <Cocoa/Cocoa.h>\n@interface NSImage (N2Stub)\n'
                    '-(NSSize)sizeByScalingProportionallyToSize:(NSSize)size;\n@end\n',
    'NSHost+N2.h': '#import <Cocoa/Cocoa.h>\n',
    'N2Debug.h': '#define N2LogStackTrace(...) NSLog(__VA_ARGS__)\n',
    'Horos-Swift.h': '@interface RemoteDataNodeIdentifier : DataNodeIdentifier\n@end\n'
                     '@interface RemoteDatabaseNodeIdentifier : RemoteDataNodeIdentifier\n@end\n'
                     '@interface DicomNodeIdentifier : RemoteDataNodeIdentifier\n@end\n',
    'stubs.m': '#import "PrettyCell.h"\n#import "RemoteDicomDatabase.h"\n#import "NSImage+N2.h"\n'
               '@implementation PrettyCell\n@end\n'
               '@implementation DicomDatabase\n+(NSString*)baseDirPathForPath:(NSString*)path { return path; }\n@end\n'
               '@implementation NSImage (N2Stub)\n-(NSSize)sizeByScalingProportionallyToSize:(NSSize)size { return size; }\n@end\n',
    'bridge.h': '#define HOROS_BRIDGING_HEADER 1\n#import "PrettyCell.h"\n#import "DataNodeIdentifier.h"\n',
}

# -[NSHost hostWithAddressOrName:] of NSHost+N2, without DNS.
HOST = r'''
import Foundation
extension Host {
    class func host(withAddressOrName name: NSString) -> Host {
        return Host(address: name as String)
    }
}
'''

MAIN = r'''
import Foundation

final class ProgressThread { var status: String? }

''' + copy_helper + r'''
// The destination part of -copyRemoteImagesToRemoteBrowserSourceThread:, as the
// sources have it; what it would hand -storeScuImages:toDestinationAETitle:….
func resolve(_ name: String, _ destination: DataNodeIdentifier?) {
    let thread = ProgressThread()
    var dstAddress: NSString? = nil
    var dstAET: NSString? = nil
    var dstPort: Int = 0
    var dstSyntax: Int = 0
    defer { if let status = thread.status { print("STATUS\t\(name)\t\(status)") } }
    ''' + '\n    '.join(destination_part.splitlines()) + r'''
    print("SEND\t\(name)\t\(dstAddress ?? "nil")\t\(dstPort)\t\(dstAET ?? "nil")\t\(dstSyntax)")
    _ = (dstAddress, dstAET, dstPort, dstSyntax)
}

func dicom(_ location: String?, _ port: UInt, _ aet: String?, _ dictionary: NSDictionary? = nil) -> DataNodeIdentifier {
    return DicomNodeIdentifier.dicomNodeIdentifier(withLocation: location, port: port, aetitle: aet, description: "node", dictionary: dictionary) as! DataNodeIdentifier
}

let port = UInt(CommandLine.arguments[1])!
let aet = CommandLine.arguments[2]
let folder = CommandLine.arguments[3]

// 1, 2
let server: NSDictionary = ["Address": "127.0.0.1", "Port": String(port), "AETitle": aet, "Description": "store", "TransferSyntax": 0]
let entered = dicom("127.0.0.1", port, aet, server)
let bonjour = dicom("127.0.0.1", port, aet)
let legacy = dicom("\(aet)@127.0.0.1", port, nil)
resolve("entered", entered)
resolve("bonjour", bonjour)
resolve("legacy", legacy)
resolve("default-port", dicom("127.0.0.1", 0, aet))
resolve("unresolved", dicom(nil, 0, ""))

// 3
var failed = false
func expect(_ condition: Bool, _ what: String) {
    if !condition { print("FAIL\t" + what); failed = true }
}
let path = folder + "/Horos Data"
try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: path)
let all: [(String, DataNodeIdentifier)] = [
    ("entered", entered), ("bonjour", bonjour), ("legacy", legacy),
    ("upper-case host", dicom("PACS.example.org", 104, "A")), ("lower-case host", dicom("pacs.example.org.", 104, "A")),
    ("IPv6", dicom("::1", 104, "A")), ("IPv6 long", dicom("0:0:0:0:0:0:0:1", 104, "A")),
    ("other AE title", dicom("127.0.0.1", port, "OTHER")), ("unresolved", dicom(nil, 0, "")),
    ("local", LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: path) as! DataNodeIdentifier),
    ("local again", LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: path) as! DataNodeIdentifier),
    ("local through a link", LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: folder + "/link") as! DataNodeIdentifier),
    ("remote database", RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: "127.0.0.1", port: 8780, description: "db", dictionary: nil) as! DataNodeIdentifier),
    ("remote database again", RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: "127.0.0.1", port: 8780, description: "db", dictionary: nil) as! DataNodeIdentifier),
]
var pairs = 0
for (a, x) in all {
    for (b, y) in all where x !== y && x.isEqual(y) {
        pairs += 1
        expect(x.hash == y.hash, "\(a) equals \(b) but their hashes differ")
    }
}
expect(pairs >= 12, "only \(pairs) equal pairs: the list no longer exercises the hash")
let set = NSMutableSet(array: [entered, bonjour, legacy])
expect(set.count == 1, "a set holds \(set.count) copies of one DICOM node")
expect(NSSet(object: entered).contains(dicom("127.0.0.1", port, aet)), "a set does not find a DICOM node listed again")
expect(NSSet(object: entered).member(bonjour) as AnyObject? === entered, "a set does not find a DICOM node by the same node from Bonjour")
expect(Set([entered, bonjour, legacy]).count == 1, "a Swift set holds one DICOM node more than once")
print(failed ? "failed" : "ok")
'''

NETWORK = r'''
import json, sys, threading
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, generate_uid
from pynetdicom import AE, ALL_TRANSFER_SYNTAXES, evt
from pynetdicom.sop_class import CTImageStorage

port, aet, sends = int(sys.argv[1]), sys.argv[2], json.loads(sys.argv[3])
received = set()

def on_store(event):
    received.add(str(event.dataset.SOPInstanceUID))
    return 0x0000

scp = AE(ae_title=aet)
scp.require_called_aet = True
scp.add_supported_context(CTImageStorage, ALL_TRANSFER_SYNTAXES)
server = scp.start_server(('127.0.0.1', port), block=False, evt_handlers=[(evt.EVT_C_STORE, on_store)])

results = {}
try:
    for send in sends:
        if send['address'] in ('', 'nil') or send['port'] <= 0:
            results[send['name']] = 'nothing to connect to'
            continue
        ds = Dataset()
        ds.file_meta = FileMetaDataset()
        ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds.SOPClassUID = CTImageStorage
        ds.SOPInstanceUID = generate_uid()
        ds.StudyInstanceUID, ds.SeriesInstanceUID = generate_uid(), generate_uid()
        ds.PatientName, ds.PatientID, ds.Modality = 'SYNTHETIC^811', 'SYN811', 'CT'
        ds.Rows = ds.Columns = 2
        ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, 'MONOCHROME2'
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 16, 15, 0
        ds.PixelData = bytes(8)
        scu = AE(ae_title='HOROS811')
        scu.acse_timeout = scu.network_timeout = scu.connection_timeout = 5
        scu.add_requested_context(CTImageStorage, ExplicitVRLittleEndian)
        try:
            assoc = scu.associate(send['address'], send['port'], ae_title=send['aet'])
        except Exception as error:
            results[send['name']] = 'association refused: %s' % error
            continue
        if not assoc.is_established:
            results[send['name']] = 'association rejected or unreachable'
            continue
        status = assoc.send_c_store(ds)
        assoc.release()
        stored = status and status.Status == 0x0000 and str(ds.SOPInstanceUID) in received
        results[send['name']] = 'stored' if stored else 'not stored'
finally:
    server.shutdown()
print(json.dumps(results))
'''

with tempfile.TemporaryDirectory(prefix='horos-remote-copy-dicom-') as folder:
    folder = Path(folder)
    for name, text in STUBS.items():
        (folder / name).write_text(text, encoding='utf-8')
    (folder / 'DataNodeIdentifier.h').write_text(header, encoding='utf-8')
    (folder / 'DataNodeIdentifier.m').write_text(base, encoding='utf-8')
    (folder / 'nodes.swift').write_text(nodes, encoding='utf-8')
    (folder / 'host.swift').write_text(HOST, encoding='utf-8')
    (folder / 'main.swift').write_text(MAIN, encoding='utf-8')
    binary = str(folder / 'harness')
    built = None
    for source in ('DataNodeIdentifier.m', 'stubs.m'):
        built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-w', '-I', str(folder), str(folder / source),
                                '-o', str(folder / (source + '.o'))], capture_output=True, text=True)
        if built.returncode != 0:
            break
    if built.returncode == 0:
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(folder / 'bridge.h'),
                                '-Xcc', '-I' + str(folder), str(folder / 'nodes.swift'), str(folder / 'host.swift'),
                                str(folder / 'main.swift'), str(folder / 'DataNodeIdentifier.m.o'), str(folder / 'stubs.m.o'),
                                '-o', binary], capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL: the harness does not compile:\n' + built.stderr[-3000:])
        sys.exit(1)

    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    aet = 'STORE811'
    (folder / 'nodes').mkdir()
    result = subprocess.run([binary, str(port), aet, str(folder / 'nodes')], capture_output=True, text=True, timeout=120)
    lines = result.stdout.strip().splitlines()
    if result.returncode != 0:
        failures.append('the harness died (%d): %s' % (result.returncode, result.stderr[-500:]))
    if not lines or lines[-1] not in ('ok', 'failed'):
        failures.append('the harness did not finish: %r' % result.stdout[-500:])
    failures += [line.split('\t', 1)[1] for line in lines if line.startswith('FAIL\t')]

    sends, statuses = {}, {}
    for line in lines:
        fields = line.split('\t')
        if fields[0] == 'SEND':
            sends[fields[1]] = {'name': fields[1], 'address': fields[2], 'port': int(fields[3]), 'aet': fields[4]}
        elif fields[0] == 'STATUS':
            statuses[fields[1]] = fields[2]
    for name, send in sends.items():
        print('resolved %-12s address=%s port=%s aet=%s' % (name, send['address'], send['port'], send['aet']))
    for name, status in statuses.items():
        print('status   %-12s %s' % (name, status))

    # 1: what the other Horos does with the request, against the fake SCP.
    network_sends = [sends[name] for name in ('entered', 'bonjour', 'legacy') if name in sends]
    stored = subprocess.run([python, '-c', NETWORK, str(port), aet, json.dumps(network_sends)],
                            capture_output=True, text=True, timeout=180)
    try:
        outcome = json.loads(stored.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError):
        outcome = {}
        failures.append('the fake SCP run failed: %s' % stored.stderr[-800:])
    for name in ('entered', 'bonjour', 'legacy'):
        if name not in sends:
            failures.append('the %s node was never sent' % name)
            continue
        print('store    %-12s %s' % (name, outcome.get(name, 'no result')))
        if outcome.get(name) != 'stored':
            send = sends[name]
            failures.append('the %s node was sent to address %s, port %d, AE title %s: %s'
                            % (name, send['address'], send['port'], send['aet'], outcome.get(name, 'no result')))

    # 2
    default = sends.get('default-port')
    if default is None or (default['address'], default['port'], default['aet']) != ('127.0.0.1', 11112, aet):
        failures.append('a node without a port resolves to %r, not 127.0.0.1:11112 %s' % (default, aet))
    if 'unresolved' in sends:
        failures.append('a Bonjour node not yet resolved is sent anyway: %r' % sends['unresolved'])
    elif statuses.get('unresolved') != 'Error: destination is unavailable':
        failures.append('a Bonjour node not yet resolved stops without saying so: %r' % statuses.get('unresolved'))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a remote Horos sends to a DICOM node at its own host, port and AE title; equal nodes hash alike')
