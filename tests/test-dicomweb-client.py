#!/usr/bin/env python3
"""Exercise the DICOMweb client over loopback: QIDO, WADO-RS, STOW-RS, auth and failures.

The client is Horos's adapter over DICOM-Swift's DicomWebClient (#799). This
fake node answers under a base path that names the scenario, so each case is
one node address.

Kept from the pilot (#197, #814, #819): QIDO paging, 204, repeated pages,
401/403/500, redirects not followed, timeout, cancellation, sanitized errors,
refused unsafe addresses, credential reads that time out or are cancelled, no
temporary file left in TMPDIR nor, among the names the client or CFNetwork use,
in NSTemporaryDirectory(); and a 256 MiB study, generated as it is sent,
retrieved from a background thread whose autorelease pool nobody drains, with
the peak RSS below 128 MiB.

Added for #799: QIDO and WADO paths different from the address; the Retrieve
Syntax in the Accept header ("as stored" and an explicit UID) and a part in
another syntax refused; Basic, API key and Bearer credentials sent exactly as
stored and no secret in any error or output; Test classifying network, TLS,
timeout, 401/403 and 404; STOW-RS to {address}/studies in batches, with
per-instance success, warning and failure, a partial failure (202), a conflict
(409), a 401 that stops the batches after it, a file that is not DICOM, and
144 MiB sent in 48 MiB files with the peak RSS below 128 MiB.

Pass a git revision to compile the DICOMweb sources of that revision instead.
One before #799 lacks the node, STOW and credential kinds and fails to build.
"""
import http.server, os, socket, struct, threading, time, subprocess, tempfile, json, urllib.parse
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from local_http import ThreadingLocalHTTPServer  # a fixture binds without the DNS (#647)

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
SECRETS = ['pw-SYNTHETIC-799', 'key-SYNTHETIC-799', 'tok-SYNTHETIC-799']
redirect_hits = []
requests = []
stow_requests = []
lock = threading.Lock()
# A whole study in four parts, generated while it is sent, never stored.
LARGE_PARTS = 4
LARGE_BLOCK = bytes(range(256)) * 4096  # 1 MiB with no CRLF, so no boundary in the payload
LARGE_BLOCKS = 64
LARGE_BOUNDARY = b'large819'
RSS_LIMIT_MIB = 128
BIG_FILE_MIB = 48
BIG_FILES = 3


def element(group, elem, vr, value):
    if len(value) % 2:
        value += b'\0' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'):
        return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
    return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value


def part10(uid, payload=b'', syntax=b'1.2.840.10008.1.2.1'):
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', b'1.2.840.10008.5.1.4.1.1.7')
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', syntax))
    data = element(8, 0x16, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(8, 0x18, b'UI', uid.encode())
    if payload:
        data += element(0x7FE0, 0x10, b'OB', payload)
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


def meta_uid(data):
    offset = 132
    while offset + 8 <= len(data):
        group, elem = struct.unpack_from('<HH', data, offset)
        if group != 2:
            break
        vr = data[offset + 4:offset + 6]
        if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'):
            length = struct.unpack_from('<I', data, offset + 8)[0]; start = offset + 12
        else:
            length = struct.unpack_from('<H', data, offset + 6)[0]; start = offset + 8
        if elem == 3:
            return data[start:start + length].rstrip(b'\0 ').decode()
        offset = start + length
    return ''


def attribute(vr, value):
    return {'vr': vr, 'Value': [value]}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def record(self):
        entry = {'method': self.command, 'path': self.path.split('?')[0],
                 'query': urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query),
                 'headers': {k.lower(): v for k, v in self.headers.items()}}
        with lock:
            requests.append(entry)
        return entry

    def reply(self, status, body=b'', content_type='application/dicom+json', extra=()):
        self.send_response(status)
        for key, value in extra:
            self.send_header(key, value)
        if status != 204:
            self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        entry = self.record()
        parts = entry['path'].strip('/').split('/')
        mode, rest = parts[0], '/'.join(parts[1:])
        if mode == 'large' and rest == 'studies/large':
            return self.send_large()
        if mode == 'redirect-target':
            redirect_hits.append(True)
        if mode == 'node':
            # Separate paths: QIDO at /node/qido-rs, WADO at /node/wado/rs.
            if rest == 'qido-rs/studies':
                return self.reply(200, json.dumps([{'0020000D': attribute('UI', '2.25.1')}]).encode())
            if rest.startswith('wado/rs/studies/'):
                syntax = 'transfer-syntax=1.2.840.10008.1.2.4.50' in entry['headers'].get('accept', '')
                declared = '1.2.840.10008.1.2.1' if 'wrong' in rest else ('1.2.840.10008.1.2.4.50' if syntax else '')
                content = 'application/dicom' + ('; transfer-syntax=' + declared if declared else '')
                body = (b'--b799\r\nContent-Type: ' + content.encode() + b'\r\n\r\n' + part10('2.25.7')
                        + b'\r\n--b799--\r\n')
                return self.reply(200, body, 'multipart/related; type="application/dicom"; boundary=b799')
            return self.reply(404)
        status = {'unauthorized': 401, 'forbidden': 403, 'failure': 500, 'redirect': 302, 'empty': 204,
                  'missing': 404}.get(mode, 200)
        body = b'[]' if status == 200 else b'secret-marker-should-not-appear'
        extra = []
        if mode in ('paged', 'repeat'):
            offset = int(entry['query'].get('offset', ['0'])[0])
            numbers = [1] if mode == 'repeat' else list(range(1, 4))[offset:offset + 2]
            body = json.dumps([{'0020000D': attribute('UI', f'2.25.{n}')} for n in numbers]).encode()
            if mode == 'repeat' or offset == 0:
                extra.append(('Warning', '299 more results'))
        if mode == 'redirect':
            extra.append(('Location', '/redirect-target/studies'))
        if status == 204:
            body = b''
        if mode == 'slow':
            self.send_response(200)
            self.send_header('Content-Type', 'application/dicom+json')
            self.send_header('Content-Length', '2')
            self.end_headers()
            time.sleep(3)
            try:
                self.wfile.write(b'[]')
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.reply(status, body, extra=extra)

    def send_large(self):
        header = b'--' + LARGE_BOUNDARY + b'\r\nContent-Type: application/dicom\r\n\r\n'
        between = b'\r\n'
        closing = b'\r\n--' + LARGE_BOUNDARY + b'--\r\n'
        length = LARGE_PARTS * (len(header) + LARGE_BLOCKS * len(LARGE_BLOCK)) + (LARGE_PARTS - 1) * len(between) + len(closing)
        self.send_response(200)
        self.send_header('Content-Type', f'multipart/related; type="application/dicom"; boundary={LARGE_BOUNDARY.decode()}')
        self.send_header('Content-Length', str(length))
        self.end_headers()
        try:
            for part in range(LARGE_PARTS):
                if part:
                    self.wfile.write(between)
                self.wfile.write(header)
                for _ in range(LARGE_BLOCKS):
                    self.wfile.write(LARGE_BLOCK)
            self.wfile.write(closing)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        entry = self.record()
        mode = entry['path'].strip('/').split('/')[0]
        length = int(self.headers.get('Content-Length', '0'))
        media = self.headers.get('Content-Type', '')
        boundary = media.split('boundary=')[-1].strip('"').encode()
        if mode == 'stow-big':
            # Read and drop: the size is what matters, and the node keeps nothing.
            remaining, head, read = length, b'', 0
            while remaining:
                chunk = self.rfile.read(min(remaining, 1 << 20))
                if not chunk:
                    break
                remaining -= len(chunk)
                read += len(chunk)
                if len(head) < 4096:
                    head += chunk[:4096]
            uid = meta_uid(head[head.index(b'\r\n\r\n') + 4:]) if b'\r\n\r\n' in head else ''
            stow = {'mode': mode, 'bytes': read, 'parts': [{'uid': uid}]}
        else:
            body = self.rfile.read(length)
            length = len(body)
            segments = body.split(b'--' + boundary)
            parts = []
            for segment in segments[1:-1]:
                segment = segment[2:] if segment.startswith(b'\r\n') else segment
                head, _, payload = segment.partition(b'\r\n\r\n')
                if payload.endswith(b'\r\n'):
                    payload = payload[:-2]
                headers = dict(line.split(': ', 1) for line in head.decode().split('\r\n') if ': ' in line)
                parts.append({'type': headers.get('Content-Type', ''), 'length': int(headers.get('Content-Length', '-1')),
                              'size': len(payload), 'uid': meta_uid(payload)})
            stow = {'mode': mode, 'bytes': length, 'parts': parts}
        with lock:
            stow['media'] = media
            stow_requests.append(stow)
        if mode == 'stow-401':
            return self.reply(401, b'secret-marker-should-not-appear')
        if mode == 'stow-quiet':
            return self.reply(200, b'{}')
        referenced, failed = [], []
        for part in stow['parts']:
            item = {'00081150': attribute('UI', '1.2.840.10008.5.1.4.1.1.7'), '00081155': attribute('UI', part['uid'])}
            if mode == 'stow-conflict':
                item['00081197'] = {'vr': 'US', 'Value': [0x0110]}; failed.append(item)
            elif mode == 'stow-partial' and part['uid'].endswith('.2'):
                item['00081197'] = {'vr': 'US', 'Value': [0xC000]}; failed.append(item)
            elif mode == 'stow-partial' and part['uid'].endswith('.3'):
                item['00081196'] = {'vr': 'US', 'Value': [0xB000]}; referenced.append(item)
            else:
                referenced.append(item)
        response = {}
        if referenced:
            response['00081199'] = {'vr': 'SQ', 'Value': referenced}
        if failed:
            response['00081198'] = {'vr': 'SQ', 'Value': failed}
        status = 409 if mode == 'stow-conflict' else 202 if failed or mode == 'stow-partial' else 200
        self.reply(status, json.dumps(response).encode())


server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
closed = socket.socket()
closed.bind(('127.0.0.1', 0))
closed_port = closed.getsockname()[1]
closed.close()  # nothing listens here: a refused connection

source = r'''
import Foundation
// The TMPDIR given to this check, which only it uses, and NSTemporaryDirectory(),
// which does not read TMPDIR and which every process of the user shares: there,
// only what the client or CFNetwork names counts, so that another process's
// file (a concurrent swiftc's TemporaryDirectory.*) is not blamed on the client.
let folders=[ProcessInfo.processInfo.environment["TMPDIR"]!,NSTemporaryDirectory()]
let shared=(folders[0] as NSString).standardizingPath != (folders[1] as NSString).standardizingPath
func entries()->[Set<String>] {
 folders.enumerated().map{index,folder in
  Set(((try? FileManager.default.contentsOfDirectory(atPath:folder)) ?? []).filter{
   index==0 || !shared || $0.hasPrefix("CFNetworkDownload") || $0.lowercased().contains("dicomweb")})}
}
var leaked=false
func requireNothingLeft(_ name:String,since before:[Set<String>]) {
 let left=zip(folders,zip(before,entries())).flatMap{folder,sets in sets.1.subtracting(sets.0).sorted().map{(folder as NSString).appendingPathComponent($0)}}
 if !left.isEmpty {print("FAIL: \(name) left \(left.joined(separator:", "))");leaked=true}
}
func check(_ ok:Bool,_ what:String) { if !ok {print("FAIL: \(what)");leaked=true} }
let secrets=["pw-SYNTHETIC-799","key-SYNTHETIC-799","tok-SYNTHETIC-799"]
func clean(_ error:Error)->Bool {
 let text=String(describing:(error as NSError).userInfo)+(error as NSError).localizedDescription
 return !text.contains("secret-marker") && !text.contains("127.0.0.1") && !secrets.contains{text.contains($0)}
}
final class Memory { var items:[String:(Data,Data?)]=[:] }
let memory=Memory()
@main struct Check {
 static func main() {
  DICOMwebCredentials.backend=DICOMwebCredentials.Backend(
   read:{id,wantData in memory.items[id].map{(wantData ? $0.0 : nil,$0.1)}},
   add:{id,data,generic in memory.items[id]=(data,generic)},
   update:{id,data,generic in guard let item=memory.items[id] else {return false};memory.items[id]=(data ?? item.0,generic);return true},
   delete:{id in memory.items[id]=nil})
  let base=CommandLine.arguments[1]
  // Never on the main thread: every operation refuses it before sending anything.
  let onMain=try! DICOMwebClient(endpoint:base+"/ok",credentialIdentifier:"",timeout:1)
  for attempt in [{_ = try onMain.query(path:"studies",parameters:[:])},{try onMain.verify()},
                  {_ = try onMain.store(files:["/nonexistent.dcm"])},{_ = try onMain.retrieve(path:"studies/1",stagingDirectory:"/nonexistent")}] as [() throws -> Void] {
   do {try attempt();print("FAIL: an operation ran on the main thread");exit(1)}
   catch {precondition((error as NSError).code==2)}
  }
  let done=DispatchSemaphore(value:0)
  Thread.detachNewThread {
   defer{done.signal()}
   do {
    func node(_ mode:String,qido:String="",wado:String="",credential:String="",syntax:String="",timeout:Double=1) throws -> DICOMwebClient {
     DICOMwebClient(node:try DICOMwebNodeConfiguration(address:base+"/"+mode,qidoPath:qido,wadoPath:wado,credentialIdentifier:credential,retrieveTransferSyntax:syntax),timeout:timeout)
    }
    // Credential reads: cancelled and timed out while the keychain does not answer.
    let client=try DICOMwebClient(endpoint:base+"/ok",credentialIdentifier:"",timeout:1)
    let credentialCancel=Date().addingTimeInterval(0.2)
    do {_ = try client.authorization(cancelled:{Date()>=credentialCancel}) {Thread.sleep(forTimeInterval:2);return "secret"};fatalError("credential cancel ignored")}
    catch {precondition((error as NSError).code==NSURLErrorCancelled);precondition(Date().timeIntervalSince(credentialCancel)<0.5)}
    do {_ = try client.authorization(cancelled:{false}) {Thread.sleep(forTimeInterval:2);return "secret"};fatalError("credential timeout ignored")}
    catch {precondition((error as NSError).code==NSURLErrorTimedOut)}

    // QIDO paging, 204 and a repeated page.
    check(try node("ok").query(path:"studies",parameters:[:]).isEmpty,"no results")
    check(try node("paged").query(path:"studies",parameters:["00100010":"José*","includefield":"00100020"]).count==3,"three paged results")
    do {_ = try node("repeat").query(path:"studies",parameters:[:]);fatalError("accepted repeated page")}
    catch {precondition((error as NSError).code==4)}
    check(try node("empty").query(path:"studies",parameters:[:]).isEmpty,"204 is no results")
    do {_ = try node("ok").query(path:"studies/../x",parameters:[:]);fatalError("accepted a dot path")} catch {}

    // HTTP failures, redirects and timeout: codes, kinds, sanitized, nothing left.
    let beforeFailures=entries()
    for (mode,expected,kind) in [("unauthorized",401,DICOMwebErrorKind.authentication),("forbidden",403,.authentication),
                                 ("failure",500,.http),("redirect",302,.redirect),("missing",404,.notFound),
                                 ("slow",NSURLErrorTimedOut,.timeout)] {
     let before=entries()
     do {_ = try node(mode).query(path:"studies",parameters:[:]);fatalError("accepted failure")}
     catch {let e=error as NSError;check(e.code==expected,"\(mode) code \(e.code)");check(DICOMwebClient.errorKind(for:e)==kind,"\(mode) kind");check(clean(e),"\(mode) error is sanitized")}
     requireNothingLeft(mode=="slow" ? "the timeout" : "HTTP \(expected)",since:before)
    }
    let beforeCancel=entries()
    let deadline=Date().addingTimeInterval(0.2)
    do {_ = try node("slow").query(path:"studies",parameters:[:],cancelled:{Date()>=deadline});fatalError("accepted cancellation")}
    catch {precondition((error as NSError).code==NSURLErrorCancelled)}
    check(Date().timeIntervalSince(deadline)<1,"cancellation returns promptly")
    requireNothingLeft("the cancellation",since:beforeCancel)

    // Test (verify): which failure it was.
    let unreachable=CommandLine.arguments[6]
    for (address,kind) in [("http://127.0.0.1:"+unreachable+"/dicom-web",DICOMwebErrorKind.network),
                           (base.replacingOccurrences(of:"http://",with:"https://")+"/ok",.tls),
                           (base+"/missing",.notFound),(base+"/unauthorized",.authentication),(base+"/forbidden",.authentication)] {
     do {try DICOMwebClient(endpoint:address,credentialIdentifier:"",timeout:2).verify(cancelled:{false});check(false,"verify accepted \(kind)")}
     catch {check(DICOMwebClient.errorKind(for:error as NSError)==kind,"verify classifies \(kind.rawValue), got \(DICOMwebClient.errorKind(for:error as NSError).rawValue) \((error as NSError).code)");check(clean(error),"verify error is sanitized")}
    }
    try node("empty").verify(cancelled:{false})
    try node("node",qido:"qido-rs",wado:"wado/rs").verify(cancelled:{false})

    // Unsafe or invalid node settings are refused before anything is sent.
    for (address,qido,wado,syntax) in [("http://example.com/dicom-web","","",""),("https://user:password@example.com","","",""),
                                       ("https://example.com?token=secret","","",""),("https://example.com","../other","",""),
                                       ("https://example.com","","https://evil.example/wado",""),("https://example.com","","","1.2.x")] {
     do {_ = try DICOMwebNodeConfiguration(address:address,qidoPath:qido,wadoPath:wado,credentialIdentifier:"",retrieveTransferSyntax:syntax);check(false,"accepted unsafe node \(address) \(qido) \(wado) \(syntax)")}
     catch {check(DICOMwebClient.errorKind(for:error as NSError) == .configuration,"unsafe node is a configuration error")}
    }
    let split=try DICOMwebNodeConfiguration(address:"https://pacs.example/dicom-web/",qidoPath:"/qido",wadoPath:"wado/rs",credentialIdentifier:"",retrieveTransferSyntax:"*")
    check(split.qidoURLString=="https://pacs.example/dicom-web/qido" && split.wadoURLString=="https://pacs.example/dicom-web/wado/rs"
          && split.storeURLString=="https://pacs.example/dicom-web/studies" && split.retrieveTransferSyntax=="","paths resolve below the address")

    // Credentials: each kind sends its header; the server records them.
    let basic=try DICOMwebCredentials.store(kind:.basic,username:"reader",secret:secrets[0],headerName:"")
    let key=try DICOMwebCredentials.store(kind:.apiKey,username:"",secret:secrets[1],headerName:"X-Api-Key")
    let bearer=try DICOMwebCredentials.store(kind:.bearer,username:"",secret:secrets[2],headerName:"")
    for (mode,credential) in [("auth-basic",basic),("auth-key",key),("auth-bearer",bearer)] {
     _ = try node(mode,credential:credential).query(path:"studies",parameters:[:])
    }
    do {_ = try node("unauthorized",credential:key).query(path:"studies",parameters:[:]);check(false,"401 accepted")}
    catch {check(clean(error),"a 401 with a credential names no secret")}
    let missing=UUID().uuidString
    do {_ = try node("ok",credential:missing).query(path:"studies",parameters:[:]);check(false,"a missing credential was ignored")}
    catch {check(DICOMwebClient.errorKind(for:error as NSError) == .credentials,"a missing credential is a credentials error")}

    // WADO path, Retrieve Syntax and the Accept header.
    let staging=CommandLine.arguments[2]
    let asStored=try node("node",qido:"qido-rs",wado:"wado/rs")
    check(asStored.retrieveAcceptHeader=="multipart/related; type=\"application/dicom\"; transfer-syntax=*","as stored asks for transfer-syntax=*")
    var files=try asStored.retrieve(path:"studies/2.25.1",stagingDirectory:staging+"-a",cancelled:{false})
    check(files.count==1,"one object retrieved through the WADO path")
    try FileManager.default.removeItem(atPath:staging+"-a")
    let jpeg=try node("node",qido:"qido-rs",wado:"wado/rs",syntax:"1.2.840.10008.1.2.4.50")
    check(jpeg.retrieveAcceptHeader=="multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.4.50","an explicit syntax is asked for")
    files=try jpeg.retrieve(path:"studies/2.25.1/series/2.25.2",stagingDirectory:staging+"-b",cancelled:{false})
    check(files.count==1,"one object in the requested syntax")
    try FileManager.default.removeItem(atPath:staging+"-b")
    do {_ = try jpeg.retrieve(path:"studies/2.25.wrong",stagingDirectory:staging+"-c",cancelled:{false});check(false,"accepted another syntax")}
    catch {check(!FileManager.default.fileExists(atPath:staging+"-c"),"a refused response leaves no staging folder")}
    for bad in ["studies","series/2.25.1","studies/2.25.1/instances/2.25.3","studies/2.25.1/series"] {
     do {_ = try jpeg.retrieve(path:bad,stagingDirectory:staging+"-d",cancelled:{false});check(false,"accepted retrieve path \(bad)")}
     catch {check(!FileManager.default.fileExists(atPath:staging+"-d"),"an invalid path creates nothing")}
    }

    // STOW-RS.
    let dicom=CommandLine.arguments[7]
    let small=(1...5).map{"\(dicom)/small-\($0).dcm"}
    let beforeStow=entries()
    let ok=try node("stow-ok")
    ok.storeBatchMaximumCount=2
    var progress:[Int]=[]
    ok.storeProgress={done,total in precondition(total==6);progress.append(done)}
    var results=try ok.store(files:small+["\(dicom)/not-dicom.txt"],cancelled:{false})
    check(results.count==6 && results.prefix(5).allSatisfy{$0.status == .success && $0.httpStatus==200},"five instances stored")
    check(results[5].status == .failure && results[5].httpStatus==0 && results[5].sopInstanceUID=="","a file that is not DICOM is not sent")
    check(results.map(\.sopInstanceUID).prefix(5)==["2.25.799.1","2.25.799.2","2.25.799.3","2.25.799.4","2.25.799.5"],"results keep the files' order")
    check(progress==[3,5,6],"progress after each batch: \(progress)")
    results=try node("stow-partial").store(files:small,cancelled:{false})
    check(results[0].status == .success && results[3].status == .success && results[4].status == .success,"partial: the others stored")
    check(results[1].status == .failure && results[1].reasonCode==0xC000 && results[1].reason.contains("0xC000") && results[1].httpStatus==202,"partial: a failure with its reason")
    check(results[2].status == .warning && results[2].reasonCode==0xB000 && results[2].reason.contains("0xB000"),"partial: a warning with its reason")
    results=try node("stow-conflict").store(files:Array(small.prefix(2)),cancelled:{false})
    check(results.allSatisfy{$0.status == .failure && $0.reasonCode==0x0110 && $0.httpStatus==409},"409: every instance failed with its reason")
    results=try node("stow-quiet").store(files:Array(small.prefix(2)),cancelled:{false})
    check(results.allSatisfy{$0.status == .success},"200 without a list stores everything")
    let refused=try node("stow-401",credential:basic)
    refused.storeBatchMaximumCount=2
    results=try refused.store(files:small,cancelled:{false})
    check(results.allSatisfy{$0.status == .failure},"401: nothing stored")
    check(results[0].httpStatus==401 && results[2].httpStatus==0 && results[2].reason.hasPrefix("Not sent."),"401 stops the batches after it")
    check(results.allSatisfy{clean(NSError(domain:"x",code:0,userInfo:[NSLocalizedDescriptionKey:$0.reason]))},"store reasons are sanitized")
    requireNothingLeft("STOW-RS",since:beforeStow)
    do {_ = try ok.store(files:[],cancelled:{false});check(false,"stored nothing")} catch {}

    // A large send from this background thread, in files bigger than a batch.
    let big=try node("stow-big",timeout:60)
    big.storeBatchMaximumBytes=64*1024*1024
    let bigFiles=(1...Int(CommandLine.arguments[8])!).map{"\(dicom)/big-\($0).dcm"}
    let stowStarted=Date()
    results=try big.store(files:bigFiles,cancelled:{false})
    var usage=rusage();getrusage(RUSAGE_SELF,&usage)
    let stowPeak=Int(usage.ru_maxrss)/1048576
    check(results.allSatisfy{$0.status == .success},"the large send is stored")
    print("peak RSS \(stowPeak) MiB after sending \(bigFiles.count) files of \(CommandLine.arguments[9]) MiB in \(String(format:"%.1f",Date().timeIntervalSince(stowStarted))) s")
    let limit=Int(CommandLine.arguments[5])!
    check(stowPeak<limit,"a large send peaked at \(stowPeak) MiB of RSS, at least \(limit) MiB")

    // Nothing turns up later either, once the slow responses are over.
    Thread.sleep(forTimeInterval:0.5)
    requireNothingLeft("a failed request",since:beforeFailures)
    // A whole study, retrieved from this background thread, whose autorelease
    // pool is drained only when the thread ends (#819).
    let partCount=Int(CommandLine.arguments[3])!,partSize=Int(CommandLine.arguments[4])!
    let large=try DICOMwebClient(endpoint:base+"/large",credentialIdentifier:"",timeout:120)
    let beforeLarge=entries()
    let started=Date()
    let parts=try large.retrieve(path:"studies/large",stagingDirectory:staging,cancelled:{false})
    let seconds=Date().timeIntervalSince(started)
    getrusage(RUSAGE_SELF,&usage)
    let peak=Int(usage.ru_maxrss)/1048576,body=partCount*partSize/1048576
    precondition(parts.count==partCount)
    for part in parts {
     let size=(try FileManager.default.attributesOfItem(atPath:part)[.size] as! NSNumber).intValue
     precondition(size==partSize)
    }
    try FileManager.default.removeItem(atPath:staging)
    requireNothingLeft("the large retrieve",since:beforeLarge)
    print("peak RSS \(peak) MiB after retrieving \(body) MiB in \(String(format:"%.1f",seconds)) s (limit \(limit) MiB)")
    if peak>=limit {print("FAIL: a \(body) MiB retrieve peaked at \(peak) MiB of RSS, at least \(limit) MiB");leaked=true}
    if leaked {exit(1)}
    print("PASS: QIDO paging/204, separate QIDO and WADO paths, retrieve syntax, Basic/API key/Bearer headers, Test classification, STOW batches with per-instance results, 401/403/404/500, redirects, timeout, cancellation, sanitized errors, no temporary files left, bounded RSS for a large retrieve and a large send")
   } catch {print("FAIL",error);exit(1)}
  }
  done.wait()
 }
}
'''


def sources_at(revision, folder):
    names = ['Horos/Sources/DICOMwebCredentials.swift', 'Horos/Sources/DICOMwebMultipart.swift', 'Horos/Sources/DICOMwebClient.swift']
    if revision:
        listed = subprocess.run(['git', 'ls-tree', '--name-only', revision, 'Horos/Sources/DICOM-Swift/'], cwd=root,
                                capture_output=True, text=True).stdout.split()
        paths = []
        for name in names + [n for n in listed if n.endswith('.swift')]:
            target = folder / name.replace('/', '_')
            target.write_bytes(subprocess.check_output(['git', 'show', f'{revision}:{name}'], cwd=root))
            paths.append(str(target))
        return paths
    return [str(root / n) for n in names] + [str(p) for p in sorted((root / 'Horos/Sources/DICOM-Swift').glob('*.swift'))]


try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-http-') as tmp:
        p = Path(tmp)
        (p / 'check.swift').write_text(source)
        (p / 'src').mkdir()
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', *sources_at(revision, p / 'src'),
                        str(p / 'check.swift'), '-o', str(p / 'check')], check=True)
        dicom = p / 'dicom'
        dicom.mkdir()
        for n in range(1, 6):
            (dicom / f'small-{n}.dcm').write_bytes(part10(f'2.25.799.{n}', bytes(range(256)) * 4))
        (dicom / 'not-dicom.txt').write_text('not DICOM')
        block = bytes(range(256)) * 4096
        for n in range(1, BIG_FILES + 1):
            with open(dicom / f'big-{n}.dcm', 'wb') as out:
                header = part10(f'2.25.799.{100 + n}')
                # PixelData of BIG_FILE_MIB MiB, written without holding it in memory.
                out.write(header + struct.pack('<HH', 0x7FE0, 0x10) + b'OB\0\0' + struct.pack('<I', BIG_FILE_MIB << 20))
                for _ in range(BIG_FILE_MIB):
                    out.write(block)
        (p / 'tmp').mkdir()
        run = subprocess.run([str(p / 'check'), f'http://127.0.0.1:{server.server_port}', str(p / 'staging'),
                              str(LARGE_PARTS), str(LARGE_BLOCKS * len(LARGE_BLOCK)), str(RSS_LIMIT_MIB), str(closed_port),
                              str(dicom), str(BIG_FILES), str(BIG_FILE_MIB)],
                             timeout=300, env=dict(os.environ, TMPDIR=f"{p/'tmp'}/"), capture_output=True, text=True)
        output = run.stdout + run.stderr
        print(output.strip())
        assert run.returncode == 0, 'the client check failed'
        assert not any(secret in output for secret in SECRETS), 'a secret reached the output'
    assert not redirect_hits, 'Redirect request reached another resource'

    def seen(mode):
        return [r for r in requests if r['path'].startswith('/' + mode + '/')]
    # Each credential kind sent exactly its header, and nothing else carried a secret.
    import base64
    basic = 'Basic ' + base64.b64encode(b'reader:' + SECRETS[0].encode()).decode()
    assert all(r['headers'].get('authorization') == basic and 'x-api-key' not in r['headers'] for r in seen('auth-basic')), 'Basic header'
    assert all(r['headers'].get('x-api-key') == SECRETS[1] and 'authorization' not in r['headers'] for r in seen('auth-key')), 'API key header'
    assert all(r['headers'].get('authorization') == 'Bearer ' + SECRETS[2] for r in seen('auth-bearer')), 'Bearer header'
    assert seen('auth-basic') and seen('auth-key') and seen('auth-bearer')
    for r in requests:
        if r['path'].split('/')[1] not in ('auth-basic', 'auth-key', 'auth-bearer', 'unauthorized', 'stow-401'):
            assert not any(s in json.dumps(r['headers']) for s in SECRETS), 'a secret went to ' + r['path']
    # Paths: QIDO and WADO under their own paths, the Test query with limit=1.
    node = seen('node')
    assert any(r['path'] == '/node/qido-rs/studies' and r['query'].get('limit') == ['1'] for r in node), 'Test used the QIDO path with limit=1'
    wado = [r for r in node if r['path'].startswith('/node/wado/rs/studies/')]
    assert wado and all('transfer-syntax' in r['headers']['accept'] for r in wado), 'WADO used its own path'
    assert wado[0]['headers']['accept'] == 'multipart/related; type="application/dicom"; transfer-syntax=*', wado[0]['headers']['accept']
    assert wado[1]['headers']['accept'] == 'multipart/related; type="application/dicom"; transfer-syntax=1.2.840.10008.1.2.4.50'
    paged = [r for r in requests if r['path'] == '/paged/studies']
    assert paged[0]['query'].get('00100010') == ['José*'] and paged[0]['query'].get('includefield') == ['00100020'], paged[0]['query']
    # STOW: batches of two to {address}/studies, parts typed with their syntax.
    ok = [s for s in stow_requests if s['mode'] == 'stow-ok']
    assert [len(s['parts']) for s in ok] == [2, 2, 1], [len(s['parts']) for s in ok]
    assert all(r['path'] == '/stow-ok/studies' for r in requests if r['method'] == 'POST' and r['path'].startswith('/stow-ok'))
    for s in ok:
        assert s['media'].startswith('multipart/related; type="application/dicom"; boundary='), s['media']
        for part in s['parts']:
            assert part['type'] == 'application/dicom; transfer-syntax=1.2.840.10008.1.2.1', part['type']
            assert part['length'] == part['size'], 'Content-Length of each part'
    assert len([s for s in stow_requests if s['mode'] == 'stow-401']) == 1, 'a 401 stops the send'
    big = [s for s in stow_requests if s['mode'] == 'stow-big']
    assert len(big) == BIG_FILES and all(s['bytes'] > BIG_FILE_MIB << 20 for s in big), [s['bytes'] for s in big]
    print('PASS: headers per credential kind, QIDO/WADO paths, Accept per retrieve syntax, STOW batching and part types, no secret sent elsewhere')
finally:
    server.shutdown()
    server.server_close()
