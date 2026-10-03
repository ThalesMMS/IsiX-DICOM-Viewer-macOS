#!/usr/bin/env python3
"""DICOMweb requests of one node share a URL session and its connections.

Over a loopback HTTP/1.1 node that keeps connections alive, against the
client's own sources:
- successive queries, and a query followed by a retrieve, of one node travel
  on one connection, as the server sees it and as the client's own metrics
  report it (requests, reused, protocol); the pool made one session;
- a node with another configuration (another address, plain HTTP allowed or
  not) gets another session and connection;
- a retrieve cancelled while another request of the same node runs cancels
  only itself: the other completes, and the session is used again after;
- a query that keeps receiving bytes past its timeout still ends at it (the
  deadline is the request's, not the shared session's);
- a session without requests ends after its idle lifetime, when nodes are
  saved (endIdleSessions), and beyond the idle limit;
- no spool file is left.

HTTP/2 needs a TLS peer that negotiates it; none runs here, so the protocol
check is the report itself (http/1.1).
"""
import http.server
import os
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
BOUNDARY = 'reuse1137'
connections = {}
lock = threading.Lock()


def part10(uid):
    import struct

    def element(group, elem, vr, value):
        if len(value) % 2:
            value += b'\0'
        if vr == b'OB':
            return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
        return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', b'1.2.840.10008.5.1.4.1.1.7')
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', b'1.2.840.10008.1.2.1'))
    data = element(8, 0x16, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(8, 0x18, b'UI', uid.encode())
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        scenario = self.path.strip('/').split('/')[0]
        with lock:
            connections.setdefault(scenario, set()).add(self.client_address[1])
        wado = 'multipart/related' in (self.headers.get('Accept') or '')
        if scenario == 'dribble':
            self.send_response(200)
            self.send_header('Content-Type', 'application/dicom+json')
            self.send_header('Content-Length', '4000')
            self.end_headers()
            try:
                for _ in range(20):
                    self.wfile.write(b' ' * 10)
                    self.wfile.flush()
                    time.sleep(0.25)
            except OSError:
                pass
            self.close_connection = True
            return
        if wado:
            if scenario == 'slow':
                time.sleep(3)
            body = (f'--{BOUNDARY}\r\nContent-Type: application/dicom\r\n\r\n'.encode() + part10('2.25.1137.1')
                    + f'\r\n--{BOUNDARY}--\r\n'.encode())
            content_type = f'multipart/related; type="application/dicom"; boundary={BOUNDARY}'
        else:
            body = b'[]'
            content_type = 'application/dicom+json'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


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

@main struct Check {
 static func main() {
  if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }
  let base=CommandLine.arguments[1], work=CommandLine.arguments[2]
  let done=DispatchSemaphore(value:0)
  Thread.detachNewThread {
   defer{done.signal()}
   do {
    let pool=DICOMwebSessionPool()
    func client(_ scenario:String,insecure:Bool=false,timeout:Double=10,in p:DICOMwebSessionPool=pool) throws -> DICOMwebClient {
     let node=try DICOMwebNodeConfiguration(address:base+"/"+scenario,qidoPath:"",wadoPath:"",credentialIdentifier:"",
                                             retrieveTransferSyntax:"",allowInsecureHTTP:insecure)
     let c=DICOMwebClient(node:node,timeout:timeout); c.sessionPool=p; return c
    }
    let before=spools()

    // Successive queries of one node: one session, connections reused.
    let a=try client("reuse")
    for _ in 0..<3 { _ = try a.query(path:"studies",parameters:[:]) }
    print("three queries:",a.lastConnectionReport)
    check(a.lastConnectionReport.hasSuffix("protocol http/1.1"),"the protocol is reported")
    check(pool.created==1,"one session for the node, \(pool.created)")
    // Each query is an operation of its own; the last one reused the connection.
    check(a.lastConnectionReport.hasPrefix("1 request(s), 1 on a reused connection"),"the last query reused a connection: \(a.lastConnectionReport)")
    // A retrieve after the queries, through another client of the same node.
    let a2=try client("reuse")
    let staged=try a2.retrieve(path:"studies/2.25.1137",stagingDirectory:work+"/staged-reuse",cancelled:{false})
    print("retrieve after queries:",a2.lastConnectionReport)
    check(staged.count==1 && a2.lastConnectionReport.contains("1 on a reused connection"),"the retrieve reused the queries' connection")
    check(pool.created==1,"still one session")
    try? FileManager.default.removeItem(atPath:work+"/staged-reuse")

    // Another configuration of the same address: another session.
    let b=try client("reuse",insecure:true)
    _ = try b.query(path:"studies",parameters:[:])
    check(pool.created==2 && b.lastConnectionReport.contains("0 on a reused connection"),"another configuration, another session: \(b.lastConnectionReport)")
    let c=try client("other")
    _ = try c.query(path:"studies",parameters:[:])
    check(pool.created==3,"another address, another session")

    // A retrieve cancelled while a query of the same node runs.
    let slow=try client("slow")
    let stop=Date().addingTimeInterval(0.5)
    var cancelledError:NSError?=nil
    let worker=Thread{
     do {_ = try slow.retrieve(path:"studies/2.25.1137",stagingDirectory:work+"/staged-slow",cancelled:{Date()>stop})}
     catch {cancelledError=error as NSError}
    }
    worker.start()
    Thread.sleep(forTimeInterval:0.2)
    let other=try client("slow")
    _ = try other.query(path:"studies",parameters:[:])
    while worker.isExecuting || cancelledError==nil { Thread.sleep(forTimeInterval:0.05); if Date()>stop.addingTimeInterval(15) {break} }
    check(DICOMwebClient.errorKind(for:cancelledError) == .cancelled,"the slow retrieve was cancelled: \(String(describing:cancelledError))")
    _ = try other.query(path:"studies",parameters:[:])
    check(other.lastConnectionReport.contains("1 on a reused connection"),"the session is used again after the cancellation: \(other.lastConnectionReport)")
    check(!FileManager.default.fileExists(atPath:work+"/staged-slow"),"cancelled staging removed")

    // A query whose bytes keep coming past its timeout ends at it.
    let dribble=try client("dribble",timeout:1.5)
    let started=Date()
    do {_ = try dribble.query(path:"studies",parameters:[:]);check(false,"the dribbling query succeeded")}
    catch {
     let seconds=Date().timeIntervalSince(started)
     print(String(format:"dribbling query ended after %.1f s",seconds))
     check(DICOMwebClient.errorKind(for:error as NSError) == .timeout && seconds<4,"the request's own deadline: \(error)")
    }

    // Idle sessions end: after their lifetime, when nodes are saved, beyond the limit.
    let short=DICOMwebSessionPool(); short.idleLifetime=0.3
    _ = try client("idle",in:short).query(path:"studies",parameters:[:])
    check(short.count==1,"kept while idle")
    Thread.sleep(forTimeInterval:1.0)
    check(short.count==0,"ended after its idle lifetime")
    _ = try client("idle",in:short).query(path:"studies",parameters:[:])
    short.endIdleSessions()
    check(short.count==0,"ended when nodes are saved")
    let small=DICOMwebSessionPool(); small.maximumIdleSessions=1
    for n in 1...3 { _ = try client("limit\(n)",in:small).query(path:"studies",parameters:[:]) }
    check(small.count==1 && small.created==3,"at most one idle session kept: \(small.count)")

    Thread.sleep(forTimeInterval:0.5)
    check(spools().subtracting(before).isEmpty,"no spool file left")
   } catch { print("FAIL",error); failed=true }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: one session per node configuration, connections reused across queries and a retrieve, isolation by configuration, cancellation of one request only, the request's own deadline, idle sessions ended")
 }
}
'''

failures = []
editor = (root / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
save = editor[editor.index('private func save() {'):]
save = save[:save.index('}')]
if 'DICOMwebSessionPool.shared.endIdleSessions()' not in save:
    failures.append('saving the nodes ends the idle sessions')

with tempfile.TemporaryDirectory(prefix='horos-session-reuse-') as tmp:
    p = Path(tmp)
    (p / 'tmp').mkdir()
    (p / 'work').mkdir()
    (p / 'check.swift').write_text(source)
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
    with lock:
        print('connections seen by the node:', {k: len(v) for k, v in sorted(connections.items())})
        if len(connections.get('reuse', ())) != 2:
            failures.append('the node saw one connection per configuration of "reuse" (two configurations)')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
