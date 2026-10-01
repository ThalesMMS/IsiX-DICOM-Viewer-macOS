#!/usr/bin/env python3
"""Run the actual Bonjour advertisement lifecycle with controlled publication.

Since #606 the publication itself is `HorosBonjourAdvertisement`
(`DNSServiceRegister`); the legacy `NSNetService` object stays for the
deprecated accessor its callers still read. Both are modelled here, and the
advertisement must follow the listener exactly: none while sharing is off, the
live port when it comes up, stopped and released when it goes, the new port
after a change, and the new name after a rename (#615). The legacy object is deliberately **not** published any more:
two registrations of the same name and port from one process make the daemon
rename one of them. It stays only so the deprecated accessor keeps its type.

BonjourPublisher is Swift since #716: its methods are compiled with Swift
stand-ins for the listener, the service and the advertisement.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
source=sources.source_text('BonjourPublisher')
def method(signature):
 start=source.index(signature);start=source.rindex('\n',0,start)+1;opening=source.index('{',start);depth=0
 for end in range(opening,len(source)):
  if source[end]=='{':depth+=1
  elif source[end]=='}':
   depth-=1
   if depth==0:return source[start:end+1]
code=r'''
import Foundation
var sharingName="synthetic sharing"
extension UserDefaults{static func bonjourSharingName()->String?{return sharingName}}
final class AppController{static func uid()->String?{return "synthetic"}}
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
 var port:Int;var name:String;var isPublished=false;var txtRecord:[String:String]=[:]
 init(name:String,type:String,port:Int){self.port=port;self.name=name}
 func publish(txtRecord:[String:String]){isPublished=true;self.txtRecord=txtRecord}
 func stop(){isPublished=false}
}
typealias NetService=FakeService
typealias BonjourAdvertisement=FakeAdvertisement
final class BonjourPublisher:NSObject{
 var _listener:Listener?;var _bonjour:FakeService?;var _advertisement:FakeAdvertisement?
ACTUAL_METHODS
}
func check(_ condition:Bool,_ message:String){if !condition{print("FAIL:",message);exit(1)}}
let p=BonjourPublisher();p.updateBonjour()
check(p._bonjour==nil,"disabled startup must not reserve a zero-port service")
check(p._advertisement==nil,"disabled startup must not create an advertisement")
p._listener=Listener();p._listener!.port=8780;p.updateBonjour()
check(p._bonjour?.port==8780,"first activation builds the legacy service on the live port")
check(p._bonjour?.published==false,"the legacy service must not publish beside the advertisement")
check(p._advertisement?.port==8780 && p._advertisement?.isPublished==true,"the advertisement carries the live listener port")
check(p._advertisement?.txtRecord["AETitle"] != nil,"the advertisement publishes the host TXT record")
let old=p._bonjour!;let oldAd=p._advertisement!;p._listener=nil;p.updateBonjour()
check(p._bonjour==nil && !old.published && old.delegate==nil,"disable stops and releases service")
check(p._advertisement==nil && !oldAd.isPublished,"disable stops and releases the advertisement")
p._listener=Listener();p._listener!.port=8781;p.updateBonjour()
check(p._bonjour?.port==8781,"reenable uses new endpoint")
check(p._advertisement?.port==8781 && p._advertisement?.isPublished==true,"the advertisement follows the new port")
p.netService(old,didNotPublish:[:])
check(p._bonjour?.port==8781,"stale failure must not clear new service")
p.netService(p._bonjour!,didNotPublish:[:]);check(p._bonjour==nil,"failure clears service")
p.updateBonjour();check(p._bonjour?.port==8781,"recovery rebuilds the legacy service on the live endpoint")
check(p._advertisement?.port==8781 && p._advertisement?.isPublished==true,"recovery republishes the advertisement")
let named=p._advertisement!;sharingName="renamed sharing";p.updateBonjour()
check(!named.isPublished,"a rename stops the advertisement under the old name")
check(p._advertisement?.name=="renamed sharing" && p._advertisement?.isPublished==true && p._advertisement?.port==8781,"a rename publishes the new name on the same port")
print("ok: disabled startup, real port, disable, changed port, stale failure and recovery, and rename, for service and advertisement")
'''.replace('ACTUAL_METHODS','\n'.join(method(s) for s in ('func updateBonjour() {','func netService(_ sender: NetService, didNotPublish',
                                                         'private static func isEqual(','private static func dataFromTXTRecordDictionary(')))
with tempfile.TemporaryDirectory(prefix='horos-sharing-') as t:
 p=Path(t);(p/'main.swift').write_text(code)
 # The main-actor callbacks the publisher uses since #1004.
 r=subprocess.run(['xcrun','swiftc',str(p/'main.swift'),str(root/'Horos/Sources/MainActorCallbacks.swift'),'-o',str(p/'probe')],capture_output=True,text=True)
 assert r.returncode==0,r.stderr
 r=subprocess.run([str(p/'probe')],capture_output=True,text=True,timeout=10)
 assert r.returncode==0,r.stdout+r.stderr
 print(r.stdout,end='')
