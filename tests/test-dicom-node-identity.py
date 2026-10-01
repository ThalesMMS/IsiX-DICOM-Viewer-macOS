#!/usr/bin/env python3
"""A DICOM node compares by its own host, port and AE title (#805).

-[DicomNodeIdentifier isEqualToDataNodeIdentifier:] read host, port and AE
title only from an "AET@host" location, and read the other node with this
one's port. The nodes the browser lists, entered in the preferences or resolved
through Bonjour, keep them in separate fields: they compared different, even
to themselves, and Bonjour's "Already known" never recognized an entered node.

This compiles RemoteDataNodeIdentifier.swift against a stand-in for the
Objective-C DataNodeIdentifier and checks, without DNS:

1. an entered node and the same node announced by Bonjour are equal, and a node
   is equal to itself;
2. a different host, port or AE title is a different node; no port is 11112;
   host case, a final dot, IPv6 spelling and an IPv4-mapped address do not
   count; a name and an address stay different (no lookup);
3. the "AET@host" form reads each node with its own port;
4. -isEqualToDictionary: matches a server of the preferences the same way;
5. the comparison is symmetric and never equal across node classes;
6. the comparator asks no Host (DNS) for either node.

And, in BrowserController+Sources.swift, that the entered servers are matched
to the listed nodes with that comparison, not by location against the
"Address+Port+AETitle" key, and that Bonjour does not replace the dictionary
of an entered DICOM node it merges.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
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


def block(text, start):
    at = text.find(start)
    if at < 0:
        return None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return None


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


nodes = read('Horos/Sources/RemoteDataNodeIdentifier.swift')
browser = read('Horos/Sources/BrowserController+Sources.swift')

# A stand-in for DataNodeIdentifier.m, PrettyCell and NSHost+N2: the same
# selectors, the base comparisons of the Objective-C class.
STUB = r'''
import Cocoa

public class PrettyCell: NSObject { public var image: NSImage? }

public func DataNodeIdentifierLogStackTrace(_ message: String) {}

var hostLookups = 0
extension Host {
    class func host(withAddressOrName name: NSString) -> Host {
        hostLookups += 1
        return Host(address: name as String)
    }
}

open class DataNodeIdentifier: NSObject {
    @objc public var location: String?
    @objc public var port: UInt = 0
    @objc public var aetitle: String?
    public var text: String?
    @objc public var dictionary: [AnyHashable: Any]?
    @objc public var detected = false
    @objc public var entered = false
    public required override init() { super.init() }

    // -[DataNodeIdentifier isEqual:], which -indexOfObject: and -containsObject: send.
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DataNodeIdentifier else { return false }
        return isEqual(to: other)
    }

    open func isEqual(to dni: DataNodeIdentifier!) -> Bool {
        if let mine = dictionary as NSDictionary?, let theirs = dni.dictionary as NSDictionary?, mine === theirs {
            return true
        }
        guard let location = location, let other = dni.location else { return false }
        return location == other
    }

    open func isEqual(to d: [AnyHashable: Any]!) -> Bool {
        guard let mine = dictionary, let d = d else { return false }
        return (mine as NSDictionary).isEqual(d as NSDictionary)
    }

    open func willDisplay(_ cell: PrettyCell!) {}
}

public func DataNodeIdentifierCreate(_ cls: AnyClass, _ location: String?, _ port: UInt, _ aetitle: String?, _ description: String?, _ dictionary: Any?) -> Any {
    let node = (cls as! DataNodeIdentifier.Type).init()
    node.location = location
    node.port = port
    node.aetitle = aetitle
    node.text = description
    node.dictionary = dictionary as? [AnyHashable: Any]
    return node
}
'''

MAIN = r'''
import Foundation

func dicom(_ location: String?, _ port: UInt, _ aet: String?) -> DataNodeIdentifier {
    return DicomNodeIdentifier.dicomNodeIdentifier(withLocation: location, port: port, aetitle: aet, description: "node", dictionary: nil) as! DataNodeIdentifier
}

var failed = false
func expect(_ condition: Bool, _ what: String) {
    if !condition { print("FAIL: " + what); failed = true }
}
func same(_ a: DataNodeIdentifier, _ b: DataNodeIdentifier, _ what: String) {
    expect(a.isEqual(to: b) && b.isEqual(to: a), what + " compare different")
}
func differ(_ a: DataNodeIdentifier, _ b: DataNodeIdentifier, _ what: String) {
    expect(!a.isEqual(to: b) && !b.isEqual(to: a), what + " compare equal")
}

// 1
let entered = dicom("192.168.1.5", 11112, "PACS")
let bonjour = dicom("192.168.1.5", 11112, "PACS")
same(entered, bonjour, "an entered node and the same node from Bonjour")
expect(entered.isEqual(to: entered), "a node compares different from itself")
expect((NSArray(array: [dicom("10.0.0.1", 104, "A"), entered]).index(of: bonjour)) == 1, "Bonjour's \"Already known\" does not find the entered node")

// 2
differ(entered, dicom("192.168.1.6", 11112, "PACS"), "two hosts")
differ(entered, dicom("192.168.1.5", 104, "PACS"), "two ports")
differ(entered, dicom("192.168.1.5", 11112, "OTHER"), "two AE titles")
differ(entered, dicom("192.168.1.5", 11112, "pacs"), "AE titles of another case")
same(entered, dicom("192.168.1.5", 0, "PACS"), "no port and port 11112")
same(entered, dicom("192.168.1.5", 11112, "PACS  "), "an AE title with trailing spaces")
same(dicom("PACS.Example.org.", 104, "A"), dicom("pacs.example.org", 104, "A"), "a host name in another case or with a final dot")
same(dicom("::1", 104, "A"), dicom("0:0:0:0:0:0:0:1", 104, "A"), "two spellings of an IPv6 address")
same(dicom("[fe80::1%en0]", 104, "A"), dicom("fe80::1", 104, "A"), "an IPv6 address in brackets or with its zone")
same(dicom("::ffff:10.0.0.7", 104, "A"), dicom("10.0.0.7", 104, "A"), "an IPv4-mapped address and its IPv4 address")
differ(dicom("localhost", 104, "A"), dicom("127.0.0.1", 104, "A"), "a name and an address (no lookup)")
differ(dicom(nil, 0, ""), dicom(nil, 0, ""), "two unresolved Bonjour nodes")
differ(dicom(nil, 0, "PACS"), entered, "an unresolved Bonjour node and an entered node")

// 3
same(dicom("PACS@192.168.1.5", 11112, nil), entered, "an \"AET@host\" location and the same node in fields")
differ(dicom("PACS@10.0.0.1", 104, nil), dicom("PACS@10.0.0.1", 11112, nil), "\"AET@host\" nodes on two ports")

// 4
let server: [AnyHashable: Any] = ["Address": "192.168.1.5", "Port": "11112", "AETitle": "PACS", "Description": "PACS"]
expect(bonjour.isEqual(to: server), "a node does not match its server in the preferences")
expect(dicom("192.168.1.5", 0, "PACS").isEqual(to: server), "a node without a port does not match its server on 11112")
expect(!entered.isEqual(to: ["Address": "192.168.1.5", "Port": 104, "AETitle": "PACS"] as [AnyHashable: Any]), "a node matches a server on another port")
expect(!entered.isEqual(to: ["Address": "192.168.1.9", "Port": 11112, "AETitle": "PACS"] as [AnyHashable: Any]), "a node matches a server on another host")

// 5
let all = [entered, bonjour, dicom("192.168.1.6", 11112, "PACS"), dicom("PACS@192.168.1.5", 104, nil),
           dicom("pacs.example.org", 104, "A"), dicom("PACS.example.org.", 104, "A"), dicom(nil, 0, "")]
for a in all { for b in all { expect(a.isEqual(to: b) == b.isEqual(to: a), "the comparison is not symmetric for \(a.location ?? "nil") and \(b.location ?? "nil")") } }
let database = RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: "192.168.1.5", port: 11112, description: "db", dictionary: nil) as! DataNodeIdentifier
expect(!entered.isEqual(to: database) && !database.isEqual(to: entered), "a DICOM node equals a remote database")

// 6
hostLookups = 0
for a in all { for b in all { _ = a.isEqual(to: b) } }
expect(hostLookups == 0, "the DICOM node comparison asked Host for \(hostLookups) lookups")

print(failed ? "failed" : "ok")
'''

with tempfile.TemporaryDirectory(prefix='horos-dicom-node-identity-') as folder:
    folder = Path(folder)
    (folder / 'stub.swift').write_text(STUB, encoding='utf-8')
    (folder / 'nodes.swift').write_text(nodes, encoding='utf-8')
    (folder / 'main.swift').write_text(MAIN, encoding='utf-8')
    binary = str(folder / 'identity')
    built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(folder / 'stub.swift'), str(folder / 'nodes.swift'),
                            str(folder / 'main.swift'), '-o', binary], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the harness does not compile:\n' + built.stderr[-2500:])
    else:
        result = subprocess.run([binary], capture_output=True, text=True, timeout=120)
        lines = result.stdout.strip().splitlines()
        if result.returncode != 0:
            failures.append('the harness died (%d): %s' % (result.returncode, result.stderr[-500:]))
        failures += [line[len('FAIL: '):] for line in lines if line.startswith('FAIL: ')]
        if not lines or lines[-1] not in ('ok', 'failed'):
            failures.append('the harness did not finish: %r' % result.stdout[-500:])

dicom_class = nodes[nodes.find('@objc(DicomNodeIdentifier)'):]
equal = block(dicom_class, '    public override func isEqual(to dni: DataNodeIdentifier!)')
if equal is None or 'Host' in code(equal) or 'self.port, to' in code(equal):
    failures.append('DicomNodeIdentifier compares through Host (DNS) or with this node\'s port for the other')

servers = block(browser, '            if context == DicomBrowserSourcesContext.pointer {')
if servers is None or 'objcContains(aa.allKeys as NSArray, dni.location)' in servers \
        or 'objcIndex(arrayValues(content, forKey: "location"), aak)' in servers \
        or servers.count('isEqual(to:') < 2:
    failures.append('the entered servers are matched by location against the Address+Port+AETitle key')

resolved = block(browser, '    public func netServiceDidResolveAddress(_ service: NetService) {')
if resolved is None or '} else if !source.entered {' not in resolved:
    failures.append('Bonjour replaces the dictionary of an entered DICOM node it merges')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: DICOM nodes compare by their own host, port and AE title, and Bonjour merges entered ones (#805)')
