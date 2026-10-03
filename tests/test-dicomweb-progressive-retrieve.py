#!/usr/bin/env python3
"""A WADO-RS retrieve hands each object over while the response still arrives.

The DICOMweb client parses a retrieve's multipart body as it is written to the
spool, and gives each part to the caller's object handler as soon as the part
has ended, before the next one is read. The handler validates the object and
takes its file (DCMTKQueryNode moves it into the database's incoming folder),
or refuses it, which ends the retrieve.

Over loopback, against the client's own sources:
- a first part followed by a pause is handed over before the response ends,
  and the parts after it are handed over in the same retrieve;
- a large part arrives in many chunks and is handed over whole;
- a refused part (a mismatched identifier or a duplicate, as the handler
  decides), a response cut after one complete part, an idle timeout after
  one part, and a cancellation during the pause all keep only what was handed
  over before, say how many objects that was, report the retrieve as stopped
  (never as complete), hand over no partial part and leave no staging folder
  and no spool file;
- two retrieves at the same time each receive only their own objects, and
  one client shared by eight threads retrieves on all of them at once;
- an error answer (HTTP 500) is still classified by its status;
- a study larger than the spool's allowance, read by a slow handler, is
  spooled in segment files removed once read, and delivery is held while the
  handler is behind: the spool on disk never holds much more than the
  allowance, the objects arrive byte for byte, and a handler slower than the
  inactivity timeout does not time the held transfer out;
- a transfer that keeps progressing for several times the inactivity timeout
  completes, there being no total deadline but a high ceiling: the ceiling
  defaults to a day, follows DICOMwebTransferCeiling up to a week, and a
  reduced one ends a transfer that outlives it as a timeout.

And in the sources: retrieveDICOMweb validates the study, series and SOP
Instance UIDs, the expected UID, duplicates and the transfer syntax of each
object in the handler, before moving it into the incoming folder and recording
it in the inventory; then it nudges the importer, which otherwise scans the
incoming folder on a timer, while a viewer waits for the study. The object is
read for this only up to its Pixel Data.
"""
import http.server
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from dicomweb_package import swift_flags

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from local_http import ThreadingLocalHTTPServer

root = Path(__file__).resolve().parents[1]
BOUNDARY = 'progressive1135'
PAUSE = 1.5
LARGE = 3 * 1024 * 1024
# The spool scenario: 80 objects of 2 MiB; the check sets 1 MiB segments and
# an 8 MiB allowance ahead of the handler.
SPOOL_PARTS = 80
SPOOL_PAYLOAD = 2 * 1024 * 1024
STEPS = 8
STEP_PAUSE = 0.6
sent_all = {}
lock = threading.Lock()


def element(group, elem, vr, value):
    if len(value) % 2:
        value += b'\0' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'):
        return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
    return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value


def part10(uid, payload=b''):
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', b'1.2.840.10008.5.1.4.1.1.7')
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', b'1.2.840.10008.1.2.1'))
    data = element(8, 0x16, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(8, 0x18, b'UI', uid.encode())
    if payload:
        data += element(0x7FE0, 0x10, b'OB', payload)
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


def spool_payload(index):
    pattern = bytes(range(251))
    pattern = pattern[index:] + pattern[:index]
    return (pattern * (SPOOL_PAYLOAD // len(pattern) + 1))[:SPOOL_PAYLOAD]


def part(uid, payload=b''):
    return (f'--{BOUNDARY}\r\nContent-Type: application/dicom\r\n\r\n'.encode()
            + part10(uid, payload) + b'\r\n')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def write(self, data):
        self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n')
        self.wfile.flush()

    def do_GET(self):
        scenario = self.path.strip('/').split('/')[0]
        if scenario == 'error':
            body = b'{"error":"synthetic"}'
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header('Content-Type', f'multipart/related; type="application/dicom"; boundary={BOUNDARY}')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        prefix = scenario
        try:
            if scenario == 'spool':
                for index in range(SPOOL_PARTS):
                    data = part(f'2.25.1135.spool.{index + 1}', spool_payload(index))
                    for offset in range(0, len(data), 256 * 1024):
                        self.write(data[offset:offset + 256 * 1024])
            elif scenario in ('progressing', 'ceiling'):
                # A part every STEP_PAUSE seconds, the pause inside the next
                # one: always progressing, never idle for the timeout.
                parts = [part(f'2.25.1135.{scenario}.{n}', b'p' * 2048) for n in range(1, STEPS + 1)]
                self.write(parts[0] + parts[1][:300])
                for n in range(1, STEPS):
                    time.sleep(STEP_PAUSE)
                    self.write(parts[n][300:] + (parts[n + 1][:300] if n + 1 < STEPS else b''))
            elif scenario == 'large':
                payload = bytes(range(256)) * (LARGE // 256)
                data = part('2.25.1135.large.1', payload)
                for offset in range(0, len(data), 32 * 1024):
                    self.write(data[offset:offset + 32 * 1024])
                self.write(part('2.25.1135.large.2'))
            else:
                # A part is known to have ended when the next delimiter
                # arrives: the pause comes inside the second part, as a slow
                # node's would.
                second = part(f'2.25.1135.{prefix}.2', b'z' * 4096)
                self.write(part(f'2.25.1135.{prefix}.1') + second[:600])
                if scenario == 'truncated':
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                time.sleep(4 if scenario == 'stall' else 0 if scenario.startswith('quick') else PAUSE)
                self.write(second[600:] + part(f'2.25.1135.{prefix}.3'))
            self.write(f'--{BOUNDARY}--\r\n'.encode())
            self.wfile.write(b'0\r\n\r\n')
            self.wfile.flush()
            with lock:
                sent_all[scenario] = time.monotonic()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True


source = r'''
import Foundation
import DicomWebClient
import DicomData

let folders=[ProcessInfo.processInfo.environment["TMPDIR"]!,NSTemporaryDirectory()]
func spools()->Set<String> {
 Set(folders.flatMap{folder in ((try? FileManager.default.contentsOfDirectory(atPath:folder)) ?? []).filter{
  $0.hasPrefix("CFNetworkDownload") || $0.hasPrefix("horos-dicomweb-")}.map{folder+"/"+$0}})
}
var failed=false
func check(_ ok:Bool,_ what:String){ if !ok {print("FAIL: \(what)");failed=true} }

final class Taken: @unchecked Sendable {
 let lock=NSLock(); var uids:[String]=[]; var times:[Double]=[]
 func add(_ uid:String){lock.lock();uids.append(uid);times.append(Date().timeIntervalSince1970);lock.unlock()}
}

func uid(_ file:String)->String {
 let data=FileManager.default.contents(atPath:file) ?? Data()
 let text=String(decoding:data.prefix(400),as:UTF8.self)
 let found=text.range(of:#"2\.25\.1135\.[a-z-]+\.[0-9]+"#,options:.regularExpression)
 return found.map{String(text[$0])} ?? ""
}

@main struct Check {
 static func main() {
  let base=CommandLine.arguments[1], work=CommandLine.arguments[2]
  let done=DispatchSemaphore(value:0)
  // The client refuses the main thread.
  Thread.detachNewThread {
   defer{done.signal()}
   do {
    func client(_ scenario:String,timeout:Double=10) throws -> DICOMwebClient {
     let node=try DICOMwebNodeConfiguration(address:base+"/"+scenario,qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"")
     return DICOMwebClient(node:node,timeout:timeout)
    }
    func run(_ scenario:String,timeout:Double=10,refuse:((String)->String?)?=nil,cancelAfter:Int?=nil,
             configure:((DICOMwebClient)->Void)?=nil,each:((String)->Void)?=nil)
     -> (taken:Taken,count:Int?,error:NSError?,staging:String,ended:Double) {
     let taken=Taken(), staging=work+"/staging-"+scenario, out=work+"/taken-"+scenario
     try? FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
     var count:Int?=nil, failure:NSError?=nil
     do {
      let c=try client(scenario,timeout:timeout)
      configure?(c)
      let result=try c.retrieve(path:"studies/2.25.1135",stagingDirectory:staging,objectHandler:{ (url:URL) -> String? in
       let id=uid(url.path)
       each?(id)
       if let reason=refuse?(id) { return reason }
       do { try FileManager.default.moveItem(atPath:url.path,toPath:out+"/"+id+".dcm") } catch { return "move failed" }
       taken.add(id)
       return nil
      },cancelled:{ cancelAfter.map{ n in taken.lock.lock(); defer{taken.lock.unlock()}; return taken.uids.count>=n } ?? false })
      count=result.handedOver
      check(result.files.isEmpty,scenario+": nothing left staged")
     } catch { failure=error as NSError }
     return (taken,count,failure,staging,Date().timeIntervalSince1970)
    }
    let before=spools()

    // A first part, a pause, then the rest: the first is taken before the end.
    var r=run("paused")
    check(r.error==nil && r.count==3 && r.taken.uids==["2.25.1135.paused.1","2.25.1135.paused.2","2.25.1135.paused.3"],"paused: three objects in order, \(r.taken.uids) \(String(describing:r.error))")
    if r.taken.times.count==3 {
     let early=r.ended-r.taken.times[0], gap=r.taken.times[1]-r.taken.times[0]
     print(String(format:"first object handed over %.2f s before the retrieve ended; the second %.2f s after it",early,gap))
     check(early>1.0 && gap>1.0,"paused: the first object was handed over before the rest arrived")
    }
    check(!FileManager.default.fileExists(atPath:r.staging),"paused: staging removed")

    // A part of several MiB arrives in many chunks and is handed over whole.
    r=run("large")
    check(r.error==nil && r.count==2,"large: two objects \(String(describing:r.error))")
    let size=(try? FileManager.default.attributesOfItem(atPath:work+"/taken-large/2.25.1135.large.1.dcm")[.size] as? NSNumber)?.intValue ?? 0
    check(size>3*1024*1024,"large: the part was handed over whole (\(size) bytes)")

    func stopped(_ name:String,_ r:(taken:Taken,count:Int?,error:NSError?,staging:String,ended:Double),kind:DICOMwebErrorKind?=nil) {
     check(r.count==nil && r.error != nil,name+": not a success")
     check(r.taken.uids==["2.25.1135.\(name).1"],name+": only the first object was taken, \(r.taken.uids)")
     check((r.error?.userInfo["HorosDICOMwebObjectsHandedOver"] as? Int)==1,name+": the error counts the object handed over")
     check(r.error?.localizedDescription.contains("stopped after 1 objects") == true && r.error?.localizedDescription.contains("No objects were imported") == false,
           name+": the message says the retrieve stopped: \(r.error?.localizedDescription ?? "")")
     if let kind { check(DICOMwebClient.errorKind(for:r.error)==kind,name+": kind \(DICOMwebClient.errorKind(for:r.error).rawValue)") }
     check(!FileManager.default.fileExists(atPath:r.staging),name+": staging removed")
     let kept=(try? FileManager.default.contentsOfDirectory(atPath:work+"/taken-"+name)) ?? []
     check(kept==["2.25.1135.\(name).1.dcm"],name+": no partial object kept, \(kept)")
    }
    // The handler refuses the second object (a mismatched identifier or a duplicate).
    stopped("refused",run("refused",refuse:{ $0.hasSuffix(".2") ? "WADO-RS returned invalid, duplicate or mismatched DICOM identifiers. That object was not imported." : nil }),kind:.invalidResponse)
    // The response ends inside the second part.
    stopped("truncated",run("truncated"))
    // The node stops sending after the first part, longer than the timeout.
    stopped("stall",run("stall",timeout:1.5),kind:.timeout)
    // Cancelled during the pause.
    stopped("cancelled",run("cancelled",cancelAfter:1),kind:.cancelled)

    // Two retrieves at once take their own objects only.
    var a:(taken:Taken,count:Int?,error:NSError?,staging:String,ended:Double)?=nil
    let other=Thread{ a=run("concurrent-a") }
    other.start()
    let b=run("concurrentb")
    while a==nil { Thread.sleep(forTimeInterval:0.05) }
    check(a!.error==nil && a!.taken.uids.allSatisfy{$0.contains(".concurrent-a.")} && a!.count==3,"concurrent: first retrieve \(a!.taken.uids)")
    check(b.error==nil && b.taken.uids.allSatisfy{$0.contains(".concurrentb.")} && b.count==3,"concurrent: second retrieve \(b.taken.uids)")

    // One client shared by eight threads at once, as a retrieve's request
    // pool shares it: every retrieve takes its three objects.
    let shared=try! client("quick")
    let sharedDone=DispatchGroup(), sharedLock=NSLock(); var sharedCounts:[Int]=[]
    for n in 0..<8 {
     sharedDone.enter()
     Thread.detachNewThread {
      for k in 0..<3 {
       let out=work+"/shared-\(n)-\(k)"
       try? FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
       let count=(try? shared.retrieve(path:"studies/2.25.1135",stagingDirectory:work+"/staging-shared-\(n)-\(k)",objectHandler:{ (url:URL) -> String? in
        (try? FileManager.default.moveItem(atPath:url.path,toPath:out+"/"+UUID().uuidString)) == nil ? "move failed" : nil
       },cancelled:{false}).handedOver) ?? -1
       sharedLock.lock(); sharedCounts.append(count); sharedLock.unlock()
      }
      sharedDone.leave()
     }
    }
    sharedDone.wait()
    check(sharedCounts.count==24 && sharedCounts.allSatisfy{$0==3},"a client shared by eight threads: \(sharedCounts)")
    check(shared.lastConnectionReport.contains("request(s)"),"its report is whole")

    // A study larger than the spool's allowance, with a handler slower than
    // the network and, once, slower than the inactivity timeout: the spool
    // holds about the allowance, in segments removed once read.
    let spoolBefore=spools()
    final class Peak: @unchecked Sendable { let lock=NSLock(); var bytes=0, files=0; var running=true }
    let peak=Peak()
    let sampler=Thread {
     while true {
      let now=spools().subtracting(spoolBefore)
      let bytes=now.reduce(0){ $0+((try? FileManager.default.attributesOfItem(atPath:$1)[.size] as? NSNumber)?.intValue ?? 0) }
      peak.lock.lock(); peak.bytes=max(peak.bytes,bytes); peak.files=max(peak.files,now.count); let go=peak.running; peak.lock.unlock()
      if !go { break }
      Thread.sleep(forTimeInterval:0.002)
     }
    }
    sampler.start()
    let spoolStarted=Date()
    r=run("spool",timeout:1,configure:{ c in
     c.responseBudgets.retrieveSegmentBytes=1024*1024
     c.responseBudgets.retrieveAheadBytes=8*1024*1024
    },each:{ id in Thread.sleep(forTimeInterval:id.hasSuffix(".3") ? 1.5 : 0.05) })
    peak.lock.lock(); peak.running=false; peak.lock.unlock()
    while sampler.isExecuting { Thread.sleep(forTimeInterval:0.01) }
    print(String(format:"spool: %d objects of 2 MiB in %.1f s, at most %.1f MiB in %d spool files at once",
                 r.count ?? -1,Date().timeIntervalSince(spoolStarted),Double(peak.bytes)/1048576,peak.files))
    check(r.error==nil && r.count==80,"spool: every object handed over, the 1.5 s handler did not time the 1 s transfer out \(String(describing:r.error))")
    // The allowance, the chunk that went over it and the segment being
    // read, far below the 160 MiB body.
    check(peak.bytes>0 && peak.bytes<=16*1024*1024,"spool: about the allowance on disk, \(peak.bytes) bytes")
    check(peak.files>1,"spool: the body went into several files")

    // Always progressing, for three times the inactivity timeout: no total
    // deadline ends it.
    check(DICOMwebClient.defaultTransferCeiling==24*3600,"the ceiling defaults to a day")
    UserDefaults.standard.register(defaults:["DICOMwebTransferCeiling":600])
    check(DICOMwebClient.defaultTransferCeiling==600 && (try! client("x")).transferCeiling==600,"the ceiling follows DICOMwebTransferCeiling")
    UserDefaults.standard.register(defaults:["DICOMwebTransferCeiling":30*24*3600])
    check(DICOMwebClient.defaultTransferCeiling==7*24*3600,"the ceiling is at most a week")
    UserDefaults.standard.register(defaults:["DICOMwebTransferCeiling":0])
    let progressingStarted=Date()
    r=run("progressing",timeout:1.2)
    let lasted=Date().timeIntervalSince(progressingStarted)
    check(r.error==nil && r.count==8 && lasted>3*1.2,"progressing: \(r.count ?? -1) objects in \(lasted) s with a 1.2 s inactivity timeout \(String(describing:r.error))")
    // The same transfer with the ceiling reduced to 1.5 s is ended by it.
    r=run("ceiling",timeout:1.2,configure:{ $0.transferCeiling=1.5 })
    check(r.count==nil && DICOMwebClient.errorKind(for:r.error) == .timeout,"ceiling: a transfer beyond the ceiling times out, \(String(describing:r.error))")
    check(r.taken.uids.count>=1 && r.taken.uids.count<8 && r.error?.localizedDescription.contains("stopped after") == true,"ceiling: the objects before it were kept and the retrieve reported stopped, \(r.taken.uids)")
    check(!FileManager.default.fileExists(atPath:r.staging),"ceiling: staging removed")

    // An error answer is classified by its status, nothing handed over.
    r=run("error")
    check(r.error?.code==500 && DICOMwebClient.errorKind(for:r.error) == .http && r.taken.uids.isEmpty,"HTTP 500 classified: \(String(describing:r.error))")

    Thread.sleep(forTimeInterval:0.5)
    let left=spools().subtracting(before)
    check(left.isEmpty,"no spool file left: \(left.sorted())")
   }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: objects handed over while the response arrives; refusal, truncation, timeout and cancellation keep only complete objects handed over before and report the retrieve stopped; concurrent retrieves isolated; no staging or spool left")
 }
}
'''

failures = []
retrieve = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
start = retrieve.index('- (BOOL)retrieveDICOMweb')
body = retrieve[start:retrieve.index('\n}\n', start)]
handler = body[body.index('^NSString *(NSString *file)'):body.index('return nil;\n        };')]
move = handler.index('moveItemAtPath:file')
for what, needle in [('study', 'DCM_StudyInstanceUID'), ('series', 'DCM_SeriesInstanceUID'), ('SOP instance', 'DCM_SOPInstanceUID'),
                     ('expected UID', 'expectedUID isEqualToString:objectUID'), ('duplicate', '[unique containsObject:objectUID]'),
                     ('transfer syntax', 'DCM_TransferSyntaxUID')]:
    if needle not in handler or handler.index(needle) > move:
        failures.append(f'retrieveDICOMweb checks the {what} before queueing an object')
if handler.index('recordUID:objectUID') < move:
    failures.append('the inventory records an object once it is queued')
if 'importNudgeWantedForStudyUID:study' not in handler or handler.index('importNudgeWantedForStudyUID') < move:
    failures.append('a queued object nudges the importer while a viewer waits for the study')
if 'objectHandler:queue' not in body:
    failures.append('retrieveDICOMweb hands the handler to the client')
if not re.search(r'dicom\.loadFileUntilTag\(\[file fileSystemRepresentation\],[^;]*DCM_PixelData\)', handler) or 'dicom.loadFile(' in handler:
    failures.append('retrieveDICOMweb reads each object only up to its Pixel Data to validate it')

with tempfile.TemporaryDirectory(prefix='horos-progressive-') as tmp:
    p = Path(tmp)
    (p / 'tmp').mkdir()
    (p / 'work').mkdir()
    (p / 'check.swift').write_text(source.replace('@main struct Check {\n static func main() {',
        '@main struct Check {\n static func main() {\n  if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }'))
    sources = [str(root / n) for n in ('Horos/Sources/DICOMwebCredentials.swift', 'Horos/Sources/DICOMwebMultipart.swift',
                                         'Horos/Sources/DICOMwebClient.swift', 'Horos/Sources/DICOMwebNode.swift',
                                         'Horos/Sources/NonInteractiveKeychainRead.swift')]
    flags = swift_flags(p)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', *sources, str(p / 'check.swift'),
                    *flags, '-o', str(p / 'check')], check=True)
    server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = subprocess.run([str(p / 'check'), f'http://127.0.0.1:{server.server_port}', str(p / 'work')],
                         timeout=120, env=dict(os.environ, TMPDIR=f"{p / 'tmp'}/"), capture_output=True, text=True)
    server.shutdown()
    print((run.stdout + run.stderr).strip())
    if run.returncode != 0:
        failures.append('the client check failed')
    # The spooled objects arrived byte for byte, across segments and pauses.
    for index in range(SPOOL_PARTS):
        uid = f'2.25.1135.spool.{index + 1}'
        taken = p / 'work/taken-spool' / (uid + '.dcm')
        if not taken.is_file() or taken.read_bytes() != part10(uid, spool_payload(index)):
            failures.append(f'spool: {uid} was not received byte for byte')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
