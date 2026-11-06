#!/usr/bin/env python3
"""Run the actual Bonjour advertisement lifecycle with controlled publication.

The publication itself is `HorosBonjourAdvertisement`
(`DNSServiceRegister`); the legacy `NSNetService` object stays for the
deprecated accessor its callers still read. Both are modelled here, and the
advertisement must follow the listener exactly: none while sharing is off, the
live port when it comes up, stopped and released when it goes, the new port
after a change, and the new name after a rename. The legacy object is deliberately **not** published any more:
two registrations of the same name and port from one process make the daemon
rename one of them. It stays only so the deprecated accessor keeps its type.

BonjourPublisher is Swift: its methods are compiled with Swift
stand-ins for the listener, the service and the advertisement.

What is announced moved to IsiXDICOMNetwork (SharedDatabaseAnnouncement). The
same methods of the revision before that move are compiled with the same
stand-ins, and both run the same lifecycle under several preferences (given in
the argument domain, so nothing is written), direct transfer offered or not,
and a missing sharing name: the services, the advertisements and the TXT
records they publish must be the same at every step.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402
import sources  # noqa: E402

PUBLISHER = 'Horos/Sources/BonjourPublisher.swift'
# The TXT record as the publisher built it before the announcement was a type of its own.
MARK = 'let txtrec = NSMutableDictionary()'
reference = ('HEAD' if MARK in history_reference.show('HEAD', PUBLISHER).decode('utf-8')
             else history_reference.before_text_removed(PUBLISHER, MARK))


def method(source, signature):
    start = source.index(signature); start = source.rindex('\n', 0, start) + 1; opening = source.index('{', start); depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0: return source[start:end + 1]


def methods(source):
    found = []
    for signature in ('func updateBonjour() {', 'func netService(_ sender: NetService, didNotPublish',
                      'static func isEqual(', 'private static func dataFromTXTRecordDictionary('):
        if signature in source:
            found.append(method(source, signature))
    return '\n'.join(found)


code = r'''
import Foundation
import IsiXDICOMNetwork
let environment = ProcessInfo.processInfo.environment
var sharingName: String? = environment["PROBE_NO_NAME"] == nil ? "synthetic sharing" : nil
extension UserDefaults{static func bonjourSharingName()->String?{return sharingName}}
final class AppController{static func uid()->String?{return "synthetic"}}
// The direct transfer between Horos peers, offered as the environment says.
@objc(HorosDirectTransferPolicy) final class DirectTransferPolicy: NSObject {
 @objc class func bonjourTXTFields() -> NSDictionary? {
  switch environment["PROBE_DIRECT"] {
  case "full": return ["HorosDirectTransferVersion": "1", "HorosDirectTransferPort": "8781"]
  case "empty": return ["HorosDirectTransferVersion": "", "HorosDirectTransferPort": ""]
  case "number": return ["HorosDirectTransferVersion": NSNumber(value: 1), "HorosDirectTransferPort": "8781"]
  default: return nil
  }
 }
}
final class Graph{var preferences:UserDefaults{return .standard}}
final class Listener{var port=0}
final class FakeService:NSObject{
 var port:Int;var name:String;var delegate:AnyObject?;var published=false
 init(domain:String,type:String,name:String,port:Int32){self.port=Int(port);self.name=name}
 @objc(dataFromTXTRecordDictionary:) class func dataFromTXTRecordDictionary(_ d:NSDictionary)->Data{return Data()}
 func setTXTRecord(_ d:Data?)->Bool{return true}
 func publish(){published=true}
 func stop(){published=false}
}
final class FakeAdvertisement{
 var port:Int;var name:String;var type:String;var isPublished=false;var txtRecord:[String:String]=[:]
 init(name:String,type:String,port:Int){self.port=port;self.name=name;self.type=type}
 func publish(txtRecord:[String:String]){isPublished=true;self.txtRecord=txtRecord}
 func stop(){isPublished=false}
}
typealias NetService=FakeService
typealias BonjourAdvertisement=FakeAdvertisement
final class BonjourPublisher:NSObject{
 let processGraph=Graph()
 var _listener:Listener?;var _bonjour:FakeService?;var _advertisement:FakeAdvertisement?
ACTUAL_METHODS
}
func check(_ condition:Bool,_ message:String){if !condition{print("FAIL:",message);exit(1)}}
func trace(_ step:String,_ p:BonjourPublisher){
 let service=p._bonjour.map{"service \($0.name):\($0.port) published=\($0.published)"} ?? "no service"
 let ad=p._advertisement.map{"advertisement \($0.name) \($0.type):\($0.port) published=\($0.isPublished) TXT \($0.txtRecord.sorted{$0.key<$1.key})"} ?? "no advertisement"
 print("\(step): \(service); \(ad)")
}
let named=sharingName != nil
let p=BonjourPublisher();p.updateBonjour();trace("disabled",p)
check(p._bonjour==nil,"disabled startup must not reserve a zero-port service")
check(p._advertisement==nil,"disabled startup must not create an advertisement")
p._listener=Listener();p._listener!.port=8780;p.updateBonjour();trace("activated",p)
check(p._bonjour?.port==8780,"first activation builds the legacy service on the live port")
check(p._bonjour?.published==false,"the legacy service must not publish beside the advertisement")
check(p._advertisement?.port==8780 && p._advertisement?.isPublished==true,"the advertisement carries the live listener port")
check(p._advertisement?.txtRecord["AETitle"] != nil,"the advertisement publishes the host TXT record")
p.updateBonjour();trace("updated",p)
let old=p._bonjour!;let oldAd=p._advertisement!;p._listener=nil;p.updateBonjour();trace("deactivated",p)
check(p._bonjour==nil && !old.published && old.delegate==nil,"disable stops and releases service")
check(p._advertisement==nil && !oldAd.isPublished,"disable stops and releases the advertisement")
p._listener=Listener();p._listener!.port=8781;p.updateBonjour();trace("port changed",p)
check(p._bonjour?.port==8781,"reenable uses new endpoint")
check(p._advertisement?.port==8781 && p._advertisement?.isPublished==true,"the advertisement follows the new port")
p.netService(old,didNotPublish:[:]);trace("stale failure",p)
check(p._bonjour?.port==8781,"stale failure must not clear new service")
p.netService(p._bonjour!,didNotPublish:[:]);check(p._bonjour==nil,"failure clears service");trace("failure",p)
p.updateBonjour();check(p._bonjour?.port==8781,"recovery rebuilds the legacy service on the live endpoint");trace("recovered",p)
check(p._advertisement?.port==8781 && p._advertisement?.isPublished==true,"recovery republishes the advertisement")
if named {
 let before=p._advertisement!;sharingName="renamed sharing";p.updateBonjour();trace("renamed",p)
 check(!before.isPublished,"a rename stops the advertisement under the old name")
 check(p._advertisement?.name=="renamed sharing" && p._advertisement?.isPublished==true && p._advertisement?.port==8781,"a rename publishes the new name on the same port")
}
print("ok: disabled startup, real port, disable, changed port, stale failure and recovery, and rename, for service and advertisement")
'''

# Preferences in the argument domain: read as UserDefaults.standard reads them, never written.
CASES = [([], {}), (['-AETITLE', 'HOROS', '-AEPORT', '104'], {}), (['-AETITLE', '', '-AEPORT', ''], {}),
         ([], {'PROBE_DIRECT': 'full'}), ([], {'PROBE_DIRECT': 'empty'}), ([], {'PROBE_DIRECT': 'number'}),
         (['-AETITLE', 'HOROS'], {'PROBE_NO_NAME': '1'})]

failures = []
with tempfile.TemporaryDirectory(prefix='horos-sharing-') as t:
    folder = Path(t)
    modules = isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules')
    binaries = {}
    revisions = [('current', (root / PUBLISHER).read_text(encoding='utf-8'))]
    if reference and reference != 'HEAD' or reference == 'HEAD' and MARK not in (root / PUBLISHER).read_text(encoding='utf-8'):
        revisions.append(('previous', history_reference.show(reference, PUBLISHER).decode('utf-8')))
    for label, source in revisions:
        (folder / label).mkdir()
        (folder / label / 'main.swift').write_text(code.replace('ACTUAL_METHODS', methods(source)))
        # The main-actor callbacks the publisher uses.
        r = subprocess.run(['xcrun', 'swiftc', *modules, str(folder / label / 'main.swift'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'), '-o', str(folder / label / 'probe')],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        binaries[label] = folder / label / 'probe'
    for arguments, environment in CASES:
        outputs = {}
        for label, binary in binaries.items():
            r = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10,
                               env={**environment, 'PATH': '/usr/bin:/bin'})
            assert r.returncode == 0, (label, arguments, environment, r.stdout + r.stderr)
            outputs[label] = r.stdout
        if 'previous' in outputs and outputs['previous'] != outputs['current']:
            failures.append(f'{arguments} {environment}:\n previous:\n{outputs["previous"]} current:\n{outputs["current"]}')
    print(outputs['current'].splitlines()[-1])

if failures:
    print('FAIL: the announcement differs from the previous revision\'s\n' + '\n'.join(failures))
    sys.exit(1)
if 'previous' in binaries:
    print(f'ok: services, advertisements and TXT records as at {reference[:10]}, in {len(CASES)} cases of '
          'preferences, direct transfer and sharing name')
else:
    print('skipped the comparison: the history does not reach the revision before the announcement type')
