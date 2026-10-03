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
another syntax refused;

The Accept of a retrieve lists the node's syntax, then Explicit VR Little
Endian; a node that answers 406 to the first is asked again with the second,
and the parts it sends in that syntax are kept; one that refuses both ends
with a 406 error. Implicit VR Little Endian, which WADO-RS does not send, asks
for the objects as stored; Basic, API key and Bearer credentials sent exactly as
stored and no secret in any error or output; Test classifying network, TLS,
timeout, 401/403 and 404; STOW-RS to {address}/studies in batches, with
per-instance success, warning and failure, a partial failure (202), a conflict
(409), an answer in Native DICOM Model XML, a 401 that stops the batches
after it, a file that is not DICOM, and 144 MiB sent in 48 MiB files with the
peak RSS below 128 MiB.

A node's client certificate, read through its Keychain reference, is
presented to a server that requires one (mutual TLS); without it the
connection fails as TLS, also after a connection with it, and a reference no
longer in the keychain is a credentials error.

Paging and batches are DICOM-Swift's: a result repeated on the next page is
returned once, and a node that ignores offset ends the query with what it
sent and a warning.

Pass a git revision to compile the DICOMweb sources of that revision instead.
One before #799 lacks the node, STOW and credential kinds and fails to build.
"""
import hashlib, http.server, os, socket, ssl, struct, threading, time, subprocess, tempfile, json, urllib.parse
from pathlib import Path
from dicomweb_package import swift_flags
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from local_http import ThreadingLocalHTTPServer  # a fixture binds without the DNS (#647)

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
BIND_ADDRESS = os.environ.get("DICOMWEB_TEST_HOST", "127.0.0.1")
SECRETS = ['pw-SYNTHETIC-799', 'key-SYNTHETIC-799', 'tok-SYNTHETIC-799']
redirect_hits = []
# What a refusing node says: its reason, shown, and a credential echoed in a
# header line, removed before anything reaches an error.
REFUSAL = b'node reason 1155.\r\nAuthorization: Bearer tok-SYNTHETIC-799'
requests = []
stow_requests = []
budget_transfers = {}
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

    def send_budget(self, mode):
        # Tiny thresholds exercise receive-time guards without large fixtures.
        chunked = 'chunked' in mode
        default = 'default' in mode
        exact = 'exact' in mode
        status = 500 if 'error' in mode else 409 if 'conflict' in mode else 200
        size = (32 << 20) + 1 if default else 4096 if exact else 65536
        self.send_response(status)
        # A retrieve's multipart body is parsed while it arrives: its type must
        # pass the parser for the budget, not the type, to stop it.
        retrieve = 'wado' in mode and status == 200
        self.send_header('Content-Type', 'multipart/related; type="application/dicom"; boundary=budget' if retrieve else 'application/dicom+json')
        self.send_header('Transfer-Encoding' if chunked else 'Content-Length', 'chunked' if chunked else str(size))
        self.end_headers()
        sent = 0
        try:
            # Let the delegate reject the headers before body writes begin.
            time.sleep(0.1)
            while sent < size:
                block = b'x' * min(512, size - sent)
                self.wfile.write((f'{len(block):x}\r\n'.encode() + block + b'\r\n') if chunked else block)
                self.wfile.flush()
                sent += len(block)
                time.sleep(0.01)
            if chunked:
                self.wfile.write(b'0\r\n\r\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock:
                budget_transfers[mode] = (sent, size)
        self.close_connection = True

    def do_GET(self):
        entry = self.record()
        parts = entry['path'].strip('/').split('/')
        mode, rest = parts[0], '/'.join(parts[1:])
        if mode.startswith('budget-'):
            return self.send_budget(mode)
        if mode == 'large' and rest == 'studies/large':
            return self.send_large()
        if mode == 'redirect-target':
            redirect_hits.append(True)
        if mode in ('auth-basic', 'auth-key', 'auth-bearer') and rest.startswith('studies/'):
            body = (b'--b1064\r\nContent-Type: application/dicom\r\n\r\n' + part10('2.25.1064')
                    + b'\r\n--b1064--\r\n')
            return self.reply(200, body, 'multipart/related; type="application/dicom"; boundary=b1064')
        if mode == 'node':
            # Separate paths: QIDO at /node/qido-rs, WADO at /node/wado/rs.
            if rest == 'qido-rs/studies':
                return self.reply(200, json.dumps([{'0020000D': attribute('UI', '2.25.1')}]).encode())
            if rest.startswith('wado/rs/studies/'):
                syntax = 'transfer-syntax=1.2.840.10008.1.2.4.50' in entry['headers'].get('accept', '')
                declared = '1.2.840.10008.1.2.4.90' if 'wrong' in rest else ('1.2.840.10008.1.2.4.50' if syntax else '')
                content = 'application/dicom' + ('; transfer-syntax=' + declared if declared else '')
                body = (b'--b799\r\nContent-Type: ' + content.encode() + b'\r\n\r\n' + part10('2.25.7')
                        + b'\r\n--b799--\r\n')
                return self.reply(200, body, 'multipart/related; type="application/dicom"; boundary=b799')
            return self.reply(404)
        if mode in ('refuse-first', 'refuse-all') and rest.startswith('studies/'):
            # A node that cannot convert: 406 to an Accept that asks first for
            # JPEG Baseline, objects in Explicit VR Little Endian otherwise.
            first = entry['headers'].get('accept', '').split(',')[0]
            if mode == 'refuse-all' or 'transfer-syntax=1.2.840.10008.1.2.4.50' in first:
                return self.reply(406)
            body = (b'--b406\r\nContent-Type: application/dicom; transfer-syntax=1.2.840.10008.1.2.1\r\n\r\n'
                    + part10('2.25.406') + b'\r\n--b406--\r\n')
            return self.reply(200, body, 'multipart/related; type="application/dicom"; boundary=b406')
        status = {'unauthorized': 401, 'forbidden': 403, 'failure': 500, 'redirect': 302, 'redirect-origin': 302, 'empty': 204,
                  'missing': 404, 'too-large-http': 413}.get(mode, 200)
        body = b'[]' if status == 200 else REFUSAL
        extra = []
        if mode == 'wire-corpus':
            body = json.dumps([{'0020000D': attribute('UI', '2.25.799.666'),
                               '00100010': {'vr': 'PN', 'Value': [{'Alphabetic': 'WIRE^Test', 'Ideographic': None}, None]},
                               '00000000': {'vr': 'ZZ', 'Value': [None, 1.25, {'Nested': True}]}}]).encode()
        if mode in ('paged', 'repeat'):
            offset = int(entry['query'].get('offset', ['0'])[0])
            numbers = [1] if mode == 'repeat' else list(range(1, 4))[offset:offset + 2]
            body = json.dumps([{'0020000D': attribute('UI', f'2.25.{n}')} for n in numbers]).encode()
            if mode == 'repeat' or offset == 0:
                extra.append(('Warning', '299 localhost "There are additional results that can be requested"'))
        if mode in ('fuzzy-warning', 'ignores-limit', 'overlap', 'series-identities', 'missing-identity'):
            offset = int(entry['query'].get('offset', ['0'])[0])
            numbers = list(range(1, 151)) if mode == 'ignores-limit' else [1, 2]
            if mode == 'overlap' and offset:
                numbers = [2, 3]
            records = [{'0020000D': attribute('UI', f'2.25.{n}')} for n in numbers]
            if mode == 'series-identities':
                records = [{'0020000D': attribute('UI', '2.25.1'),
                            '0020000E': attribute('UI', f'2.25.1.{n}'),
                            '00080018': attribute('UI', '2.25.9')} for n in numbers]
            if mode == 'missing-identity':
                records = [{'0020000D': attribute('UI', '2.25.1')}]
            body = json.dumps(records).encode()
            if mode == 'fuzzy-warning':
                extra.append(('Warning', '299 localhost "The fuzzymatching parameter is not supported. Only literal matching has been performed."'))
            if mode == 'overlap' and not offset:
                extra.append(('Warning', '299 localhost "There are additional results that can be requested"'))
        if mode == 'redirect':
            extra.append(('Location', '/redirect-target/studies'))
        if mode == 'redirect-origin':
            extra.append(('Location', f'http://127.0.0.1:{origin_server.server_port}/redirect-target/studies'))
        if status == 204:
            body = b''
        if mode == 'slow':
            self.send_response(200)
            self.send_header('Content-Type', 'application/dicom+json')
            self.send_header('Content-Length', '2')
            self.end_headers()
            try:
                self.wfile.write(b'[')
                self.wfile.flush()
                time.sleep(3)
                self.wfile.write(b']')
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
        if mode.startswith('budget-'):
            return self.send_budget(mode)
        if mode == 'stow-401':
            return self.reply(401, REFUSAL)
        if mode == 'stow-legacy':
            return self.reply(200, json.dumps({'sopInstanceUIDs': [p['uid'] for p in stow['parts']]}).encode(), content_type='application/json')
        if mode == 'stow-xml':
            # A Native DICOM Model answer: the second instance refused, the others stored.
            def item(number, part, reason=None):
                xml = (f'<Item number="{number}"><DicomAttribute tag="00081150" vr="UI"><Value number="1">1.2.840.10008.5.1.4.1.1.7</Value></DicomAttribute>'
                       f'<DicomAttribute tag="00081155" vr="UI"><Value number="1">{part["uid"]}</Value></DicomAttribute>')
                if reason is not None:
                    xml += f'<DicomAttribute tag="00081197" vr="US"><Value number="1">{reason}</Value></DicomAttribute>'
                return xml + '</Item>'
            stored = ''.join(item(n, part) for n, part in enumerate((p for p in stow['parts'] if not p['uid'].endswith('.2')), 1))
            refused = ''.join(item(n, part, 0xC000) for n, part in enumerate((p for p in stow['parts'] if p['uid'].endswith('.2')), 1))
            xml = ('<?xml version="1.0" encoding="UTF-8"?><NativeDicomModel xmlns="http://dicom.nema.org/PS3.19/models/NativeDICOM" xml:space="preserve">'
                   f'<DicomAttribute tag="00081199" vr="SQ">{stored}</DicomAttribute>'
                   + (f'<DicomAttribute tag="00081198" vr="SQ">{refused}</DicomAttribute>' if refused else '')
                   + '</NativeDicomModel>')
            return self.reply(202 if refused else 200, xml.encode(), content_type='application/dicom+xml')
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


server = ThreadingLocalHTTPServer((BIND_ADDRESS, 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
origin_server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=origin_server.serve_forever, daemon=True).start()
closed = socket.socket()
closed.bind(('127.0.0.1', 0))
closed_port = closed.getsockname()[1]
closed.close()  # nothing listens here: a refused connection

source = r'''
import Foundation
import Security
// The TMPDIR given to this check, which only it uses, and NSTemporaryDirectory(),
// which does not read TMPDIR and which every process of the user shares: there,
// only spool files the client or CFNetwork names count, so another test's
// outer fixture folder and another process's
// file (a concurrent swiftc's TemporaryDirectory.*) is not blamed on the client.
let folders=[ProcessInfo.processInfo.environment["TMPDIR"]!,NSTemporaryDirectory()]
let shared=(folders[0] as NSString).standardizingPath != (folders[1] as NSString).standardizingPath
// The listing drains its own pool: it runs on the thread whose pool is never
// drained, and NSTemporaryDirectory() may hold tens of thousands of other
// processes' files, whose autoreleased names would otherwise stay in memory
// until the end and count against the client's RSS bounds.
func entries()->[Set<String>] {
 autoreleasepool{folders.enumerated().map{index,folder in
  Set(((try? FileManager.default.contentsOfDirectory(atPath:folder)) ?? []).filter{
   index==0 || !shared || $0.hasPrefix("CFNetworkDownload") ||
   ($0.hasPrefix("horos-dicomweb-") && UUID(uuidString:String($0.dropFirst("horos-dicomweb-".count))) != nil)})}}
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
 return !text.contains("127.0.0.1") && !text.contains(URL(string: CommandLine.arguments[1])!.host!) && !secrets.contains{text.contains($0)}
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
  let allowHTTP=ProcessInfo.processInfo.environment["DICOMWEB_TEST_HOST"] != nil
  func configured(_ address:String,timeout:Double=1) throws -> DICOMwebClient {
   DICOMwebClient(node:try DICOMwebNodeConfiguration(address:address,qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"",allowInsecureHTTP:allowHTTP),timeout:timeout)
  }
  // Never on the main thread: every operation refuses it before sending anything.
  let onMain=try! configured(base+"/ok")
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
     DICOMwebClient(node:try DICOMwebNodeConfiguration(address:base+"/"+mode,qidoPath:qido,wadoPath:wado,credentialIdentifier:credential,retrieveTransferSyntax:syntax,allowInsecureHTTP:allowHTTP),timeout:timeout)
    }
    if ProcessInfo.processInfo.environment["DICOMWEB_DISK_WRITE_FAILURE"] == "1" {
     signal(SIGXFSZ,SIG_IGN)
     var limit = rlimit(rlim_cur:1024,rlim_max:1024)
     check(setrlimit(RLIMIT_FSIZE,&limit) == 0,"test file-size limit configured")
     let before = entries()
     do { _ = try node("budget-disk-write",timeout:3).query(path:"studies",parameters:[:]);check(false,"disk-write failure accepted") }
     catch {
      let e = error as NSError
      check(e.code == 4 && DICOMwebClient.errorKind(for:e) == .invalidResponse && clean(e),"disk-write failure sanitized")
      check(!e.localizedDescription.contains("local size limit"),"disk failure distinct from response budget")
     }
     requireNothingLeft("disk-write failure",since:before)
     if leaked { exit(1) }
     print("PASS: partial spool removed after disk-write failure")
     return
    }

    // Credential reads: cancelled and timed out while the keychain does not answer.
    let client=try configured(base+"/ok")
    let credentialCancel=Date().addingTimeInterval(0.2)
    do {_ = try client.authorization(cancelled:{Date()>=credentialCancel}) {Thread.sleep(forTimeInterval:2);return "secret"};fatalError("credential cancel ignored")}
    catch {precondition((error as NSError).code==NSURLErrorCancelled);precondition(Date().timeIntervalSince(credentialCancel)<0.5)}
    do {_ = try client.authorization(cancelled:{false}) {Thread.sleep(forTimeInterval:2);return "secret"};fatalError("credential timeout ignored")}
    catch {precondition((error as NSError).code==NSURLErrorTimedOut)}

    if allowHTTP {
     do {_ = try DICOMwebNodeConfiguration(address:base+"/ok",qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"");check(false,"remote HTTP worked without permission")}
     catch {check(DICOMwebClient.errorKind(for:error as NSError) == .configuration,"remote HTTP without permission is a configuration error")}
    }
    // C-FIND multi-value filters ("\\") become QIDO comma lists; a single value is unchanged.
    func qidoURL(_ path: String, _ parameters: [String: String]) throws -> String {
     try DICOMwebClient.searchParameters(path:path,parameters:parameters).url(relativeTo:URL(string:"http://127.0.0.1/qido")!).absoluteString
    }
    func qidoValue(_ url: String, _ name: String) -> String? {
     URLComponents(string:url)?.queryItems?.first(where:{$0.name==name})?.value
    }
    let modalities=try qidoURL("studies",["00080061":"CT\\MR"])
    check(qidoValue(modalities,"00080061")=="CT,MR" && modalities.contains("00080061=CT,MR") && !modalities.contains("%2C") && !modalities.contains("%5C"),"two modalities become ModalitiesInStudy=CT,MR with a literal comma: "+modalities)
    check(try DICOMwebClient.searchParameters(path:"studies",parameters:["00080061":"CT\\MR"]).matches.first?.values==["CT","MR"],"two modalities go as separate values")
    let named=try qidoURL("studies",["00081030":"Head, neck"])
    check(named.contains("00081030=Head%2C%20neck"),"a comma inside one value stays encoded: "+named)
    let studyUIDs=try DICOMwebClient.searchParameters(path:"studies",parameters:["0020000D":"2.25.1\\2.25.2\\2.25.3"])
    check(studyUIDs.matches.first?.values==["2.25.1","2.25.2","2.25.3"],"a StudyInstanceUID list goes as separate values")
    check(qidoValue(try studyUIDs.url(relativeTo:URL(string:"http://127.0.0.1/qido")!).absoluteString,"0020000D")=="2.25.1,2.25.2,2.25.3","a StudyInstanceUID list becomes a comma list")
    let single=try qidoURL("studies",["00080061":"CT","0020000D":"2.25.1","00100010":"José*"])
    check(qidoValue(single,"00080061")=="CT" && qidoValue(single,"0020000D")=="2.25.1" && qidoValue(single,"00100010")=="José*","a single value is unchanged: "+single)
    check(try DICOMwebClient.searchParameters(path:"studies",parameters:["00080061":"CT"]).matches.first?.values==["CT"],"a single value stays one value")
    // QIDO paging, 204 and a repeated page, by DICOM-Swift's pager.
    check(try node("ok").query(path:"studies",parameters:[:]).isEmpty,"no results")
    let paged = try node("paged").search(path:"studies",parameters:["00100010":"José*","includefield":"00100020"],cancelled:{false})
    check(paged.records.count==3 && paged.warning==nil,"three paged results")
    // A node that ignores offset sends its first page again: the query ends
    // with what it has and a warning, after one more request.
    let repeated = try node("repeat").search(path:"studies",parameters:[:],cancelled:{false})
    check(repeated.records.count==1 && repeated.warning?.contains("repeated results") == true,"a repeated page ends the query with a warning: \(repeated)")
    // A result repeated on the next page is returned once.
    let overlap = try node("overlap").search(path:"studies",parameters:[:],cancelled:{false})
    let overlapUIDs = overlap.records.map { (($0["0020000D"] as? [String:Any])?["Value"] as? [String])?.first ?? "" }
    check(overlapUIDs==["2.25.1","2.25.2","2.25.3"] && overlap.warning==nil,"a result repeated across pages is kept once: \(overlapUIDs)")
    check(try node("fuzzy-warning").query(path:"studies",parameters:[:]).count==2,"a non-pagination 299 ends a short page")
    check(try node("ignores-limit").query(path:"studies",parameters:[:]).count==150,"an untruncated response larger than limit is accepted")
    check(try node("series-identities").query(path:"studies/2.25.1/series",parameters:[:]).count==2,"series paging uses SeriesInstanceUID")
    do {_ = try node("missing-identity").query(path:"studies/2.25.1/series",parameters:[:]);fatalError("accepted incomplete identities")}
    catch {precondition((error as NSError).code==4)}
    check(try node("empty").query(path:"studies",parameters:[:]).isEmpty,"204 is no results")
    do {_ = try node("ok").query(path:"studies/../x",parameters:[:]);fatalError("accepted a dot path")} catch {}

    // Receive limits: operation and status select the budget before parsing.
    let defaults = DICOMwebResponseBudgets()
    check(defaults.metadataBytes == 32*1024*1024 && defaults.retrieveBytes == 64*1024*1024*1024 && defaults.errorBytes == 1024*1024,"host response budgets")
    var tiny = defaults
    tiny.metadataBytes = 4096; tiny.retrieveBytes = 8192; tiny.errorBytes = 1024
    for operation in ["qido", "stow", "wado", "error", "conflict", "stow-error", "wado-error"] {
     for framing in ["length", "chunked"] {
      let mode = "budget-" + operation + "-" + framing
      let limited = try node(mode, timeout:3)
      limited.responseBudgets = tiny
      let before = entries()
      if operation.hasPrefix("stow") || operation == "conflict" {
       let result = try limited.store(files:[CommandLine.arguments[7]+"/small-1.dcm"])
       check(result.count == 1 && result[0].status == .failure && result[0].httpStatus == 0,"local STOW limit is no invented HTTP status")
       check(result[0].reason.contains("local size limit") && clean(NSError(domain:"x",code:0,userInfo:[NSLocalizedDescriptionKey:result[0].reason])),"STOW limit sanitized")
      } else {
       do {
        if operation.hasPrefix("wado") { _ = try limited.retrieve(path:"studies/1",stagingDirectory:CommandLine.arguments[2]+"-budget") }
        else { _ = try limited.query(path:"studies",parameters:[:]) }
        check(false,"accepted oversized " + mode)
       } catch {
        let e = error as NSError
        check(e.code == 4 && DICOMwebClient.errorKind(for:e) == .invalidResponse && e.localizedDescription.contains("local size limit"),"local receive limit classified " + mode)
        check(clean(e),"receive limit sanitized")
       }
       check(!FileManager.default.fileExists(atPath:CommandLine.arguments[2]+"-budget"),"limit discards retrieve staging")
      }
      requireNothingLeft(mode,since:before)
     }
    }
    do {
     let wire = try node("wire-corpus").query(path:"studies",parameters:[:])
     let unknown = wire[0]["00000000"] as! [String:Any]
     let unknownValues = unknown["Value"] as! [Any]
     let names = (wire[0]["00100010"] as! [String:Any])["Value"] as! [Any]
     check(unknown["vr"] as? String == "ZZ" && unknownValues[0] is NSNull && (unknownValues[1] as? NSNumber)?.doubleValue == 1.25,"QIDO preserves unknown VR/null/number")
     check((names[0] as! [String:Any])["Ideographic"] is NSNull && names[1] is NSNull,"QIDO preserves wire person names")
    }
    let legacy = try node("stow-legacy").store(files:[CommandLine.arguments[7]+"/small-1.dcm"])
    check(legacy.count == 1 && legacy[0].status == .failure && legacy[0].httpStatus == 200,"HTTP 200 reported legacy unknown instance remains a failure")
    // The production metadata threshold is tested by headers without sending 32 MiB.
    for operation in ["qido", "stow"] {
     let limited = try node("budget-default-" + operation,timeout:3)
     let before = entries()
     if operation == "stow" {
      let result = try limited.store(files:[CommandLine.arguments[7]+"/small-1.dcm"])
      check(result[0].status == .failure && result[0].httpStatus == 0 && result[0].reason.contains("local size limit"),"default STOW budget")
     } else {
      do { _ = try limited.query(path:"studies",parameters:[:]);check(false,"default QIDO budget ignored") }
      catch { check((error as NSError).localizedDescription.contains("local size limit"),"default QIDO budget") }
     }
     requireNothingLeft("default metadata limit",since:before)
    }
    // Exercise the transport's exact-boundary success and disk-open failure.
    let transportDone = DispatchSemaphore(value:0)
    Task {
     defer { transportDone.signal() }
     do {
      for framing in ["length", "chunked"] {
       let before = entries()
       let transport = DICOMwebTransport(timeout:3,transferCeiling:3,budgets:tiny)
       let request = DicomWebHTTPRequest(method:.get,url:URL(string:base+"/budget-exact-"+framing+"/studies")!)
       let response = try await transport.stream(request)
       let names = zip(entries(),before).flatMap { $0.subtracting($1) }
       for folder in folders {
        for name in names where name.hasPrefix("horos-dicomweb-") {
         if let attrs = try? FileManager.default.attributesOfItem(atPath:(folder as NSString).appendingPathComponent(name)) {
          check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,"spool permissions 0600")
         }
        }
       }
       var count = 0
       for try await chunk in response.body { count += chunk.count }
       response.cancel()
       check(count == tiny.metadataBytes,"exact response budget accepted")
       requireNothingLeft("exact-budget response",since:before)
      }
      let before = entries()
      let missing = URL(fileURLWithPath:CommandLine.arguments[2]+"-missing-parent")
      let disk = DICOMwebTransport(timeout:3,transferCeiling:3,temporaryDirectory:missing)
      do { _ = try await disk.stream(.init(method:.get,url:URL(string:base+"/ok/studies")!));check(false,"disk failure accepted") }
      catch { check(!(error is DicomWebError),"disk failure retained as local error") }
      check(!FileManager.default.fileExists(atPath:missing.path),"disk failure creates no material")
      requireNothingLeft("disk failure",since:before)
     } catch { print("FAIL: transport budget check",error);leaked=true }
    }
    transportDone.wait()

    // HTTP failures, redirects and timeout: codes, kinds, sanitized, nothing left.
    let beforeFailures=entries()
    for (mode,expected,kind) in [("unauthorized",401,DICOMwebErrorKind.authentication),("forbidden",403,.authentication),
                                 ("failure",500,.http),("too-large-http",413,.http),("redirect",302,.redirect),("redirect-origin",302,.redirect),("missing",404,.notFound),
                                 ("slow",NSURLErrorTimedOut,.timeout)] {
     let before=entries()
     do {_ = try node(mode).query(path:"studies",parameters:[:]);fatalError("accepted failure")}
     catch {let e=error as NSError;check(e.code==expected,"\(mode) code \(e.code)");check(DICOMwebClient.errorKind(for:e)==kind,"\(mode) kind");check(clean(e),"\(mode) error is sanitized")
      check(e.localizedDescription.contains("The node said: node reason 1155. Authorization: [redacted]") == (kind != .redirect && kind != .timeout),"\(mode) shows what the node said: \(e.localizedDescription)")}
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
     do {try configured(address,timeout:2).verify(cancelled:{false});check(false,"verify accepted \(kind)")}
     catch {check(DICOMwebClient.errorKind(for:error as NSError)==kind,"verify classifies \(kind.rawValue), got \(DICOMwebClient.errorKind(for:error as NSError).rawValue) \((error as NSError).code)");check(clean(error),"verify error is sanitized")}
    }
    let untrusted=try DICOMwebNodeConfiguration(address:CommandLine.arguments[10],qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"",allowInsecureHTTP:true)
    do {try DICOMwebClient(node:untrusted,timeout:3).verify();check(false,"HTTP permission accepted an untrusted HTTPS certificate")}
    catch {check(DICOMwebClient.errorKind(for:error as NSError) == .tls,"untrusted HTTPS certificate remains refused");check(clean(error),"TLS refusal is sanitized")}
    // A node that names the server's certificate trusts it, and only it: its
    // host name and dates are still checked.
    let fingerprint=CommandLine.arguments[11]
    func pinned(_ address:String,_ sha:String) throws -> DICOMwebClient {
     DICOMwebClient(node:try DICOMwebNodeConfiguration(address:address,qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"",
                                                       allowInsecureHTTP:false,trustedCertificateSHA256:sha),timeout:3)
    }
    let colons=stride(from:0,to:64,by:2).map{String(Array(fingerprint)[$0..<$0+2])}.joined(separator:":").uppercased()
    check(try DICOMwebNodeConfiguration(address:CommandLine.arguments[10],qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"",
                                        allowInsecureHTTP:false,trustedCertificateSHA256:colons).trustedCertificateSHA256==fingerprint,"a fingerprint with colons is stored as 64 lowercase digits")
    do {try pinned(CommandLine.arguments[10],colons).verify();_ = try pinned(CommandLine.arguments[10],fingerprint).query(path:"studies",parameters:[:])}
    catch {check(false,"the node's trusted certificate was refused: \(error)")}
    let other=String(fingerprint.reversed())
    do {try pinned(CommandLine.arguments[10],other).verify();check(false,"another certificate's fingerprint trusted the server")}
    catch {check(DICOMwebClient.errorKind(for:error as NSError) == .tls,"another fingerprint leaves the certificate refused");check(clean(error),"pinned TLS refusal is sanitized")}
    do {try pinned(CommandLine.arguments[10].replacingOccurrences(of:"127.0.0.1",with:"localhost"),fingerprint).verify();check(false,"a host the certificate does not name was trusted")}
    catch {check(DICOMwebClient.errorKind(for:error as NSError) == .tls,"the trusted certificate still has to name the host")}
    for bad in ["abc","g"+String(fingerprint.dropFirst()),fingerprint+"00"] {
     do {_ = try DICOMwebNodeConfiguration(address:CommandLine.arguments[10],qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"",
                                           allowInsecureHTTP:false,trustedCertificateSHA256:bad);check(false,"fingerprint \(bad) accepted")}
     catch {check(DICOMwebClient.errorKind(for:error as NSError) == .configuration,"a malformed fingerprint is a configuration error")}
    }
    // A node's client certificate, read through its Keychain reference, is
    // presented to its server when it asks for one; without it, a server that
    // requires one refuses the connection, and the two never share one.
    let mutual=CommandLine.arguments[12]
    var imported:CFArray?
    let importStatus=SecPKCS12Import(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[13])) as CFData,
                                     [kSecImportExportPassphrase as String:"dicomweb-test",kSecImportToMemoryOnly as String:true] as CFDictionary,&imported)
    precondition(importStatus==errSecSuccess)
    let testIdentity=(imported as! [[String:Any]])[0][kSecImportItemIdentity as String] as! SecIdentity
    let reference=Data("persistent-reference".utf8)
    var lookups=0
    DICOMwebCredentials.identityLookup={given in
     lookups+=1
     guard given==reference else {throw NSError(domain:"HorosDICOMwebCredentials",code:Int(errSecItemNotFound))}
     return testIdentity
    }
    func mutualNode(_ identity:Data?) throws -> DICOMwebClient {
     DICOMwebClient(node:try DICOMwebNodeConfiguration(address:mutual,qidoPath:"",wadoPath:"",credentialIdentifier:"",retrieveTransferSyntax:"",
                                                       allowInsecureHTTP:false,trustedCertificateSHA256:fingerprint,
                                                       clientIdentityReference:identity,authorization:nil),timeout:3)
    }
    func refusedWithoutCertificate(_ what:String) {
     do {try mutualNode(nil).verify();check(false,"\(what): a server that requires a client certificate answered without one")}
     catch {check(DICOMwebClient.errorKind(for:error as NSError) == .tls,"\(what): without a client certificate the connection fails as TLS, got \((error as NSError).localizedDescription)");check(clean(error),"client certificate refusal is sanitized")}
    }
    refusedWithoutCertificate("before")
    do {try mutualNode(reference).verify();_ = try mutualNode(reference).query(path:"studies",parameters:[:])}
    catch {check(false,"the node's client certificate was not accepted: \(error)")}
    check(lookups==2,"the identity is read through the node's reference for each operation (\(lookups))")
    refusedWithoutCertificate("after")
    do {try mutualNode(Data("gone".utf8)).verify();check(false,"a client certificate no longer in the keychain was presented")}
    catch {check(DICOMwebClient.errorKind(for:error as NSError) == .credentials,"a missing client certificate is a credentials error")}
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
     let authenticated = try node(mode,credential:credential)
     try authenticated.verify()
     _ = try authenticated.query(path:"studies",parameters:[:])
     let folder = CommandLine.arguments[2] + "-" + mode
     let received = try authenticated.retrieve(path:"studies/2.25.1064",stagingDirectory:folder)
     check(received.count == 1,"authenticated WADO retrieves one instance")
     try FileManager.default.removeItem(atPath:folder)
     let sent = try authenticated.store(files:[CommandLine.arguments[7]+"/small-1.dcm"])
     check(sent.count == 1 && sent[0].status == .success,"authenticated STOW stores one instance")
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
    check(jpeg.retrieveAcceptHeader=="multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.4.50, multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1; q=0.9","an explicit syntax is asked for, then Explicit VR Little Endian")
    check((try? jpeg.retrieveAccept().fallbackStatuses)==[406,500],"a 406, or a 500 to the named syntax, moves on to Explicit VR Little Endian")
    let explicitNode=try node("node",syntax:"1.2.840.10008.1.2.1")
    check(explicitNode.retrieveAcceptHeader=="multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1","Explicit VR Little Endian is asked for alone")
    let implicitNode=try node("node",syntax:"1.2.840.10008.1.2")
    check(implicitNode.node.retrieveTransferSyntax=="" && implicitNode.retrieveAcceptHeader==asStored.retrieveAcceptHeader,"Implicit VR Little Endian asks for the objects as stored")
    check(jpeg.accepts(retrievedTransferSyntax:"1.2.840.10008.1.2.4.50") && jpeg.accepts(retrievedTransferSyntax:"1.2.840.10008.1.2.1")
          && !jpeg.accepts(retrievedTransferSyntax:"1.2.840.10008.1.2.4.90") && asStored.accepts(retrievedTransferSyntax:"1.2.840.10008.1.2.4.90"),
          "an object is taken in any syntax asked for, and in any syntax as stored")
    files=try node("refuse-first",syntax:"1.2.840.10008.1.2.4.50").retrieve(path:"studies/2.25.1",stagingDirectory:staging+"-e",cancelled:{false})
    check(files.count==1,"after a 406 the retrieve ends with the alternative syntax")
    try FileManager.default.removeItem(atPath:staging+"-e")
    do {_ = try node("refuse-all",syntax:"1.2.840.10008.1.2.4.50").retrieve(path:"studies/2.25.1",stagingDirectory:staging+"-f",cancelled:{false});check(false,"a node that refuses every syntax succeeded")}
    catch {check((error as NSError).code==406 && !FileManager.default.fileExists(atPath:staging+"-f"),"refused syntaxes end with 406 and no staging folder")}
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
    for name in ["meta-below", "meta-limit"] {
     check(DICOMwebClient.inspect(URL(fileURLWithPath:"\(dicom)/\(name).dcm")) != nil,"bounded File Meta is accepted")
    }
    for name in ["meta-over", "meta-hostile", "meta-truncated", "meta-inconsistent"] {
     check(DICOMwebClient.inspect(URL(fileURLWithPath:"\(dicom)/\(name).dcm")) == nil,"invalid File Meta is refused")
    }
    let coreDone=DispatchSemaphore(value:0)
    Task {
     defer {coreDone.signal()}
     let core=DicomWebClient(configuration:.init(baseURL:URL(string:base+"/stow-meta-rejected")!),
                             transport:DICOMwebTransport(timeout:1,transferCeiling:1))
     for name in ["meta-over", "meta-hostile"] {
      do {_ = try await core.storeInstances(files:[URL(fileURLWithPath:"\(dicom)/\(name).dcm")]);check(false,"core accepted excessive File Meta")}
      catch DicomWebClientError.invalidStorePart10FileMeta(let index) {check(index==0,"File Meta error keeps the input index")}
      catch {check(false,"unexpected File Meta error: \(error)")}
     }
    }
    coreDone.wait()
    let metaResults=try node("stow-meta").store(files:[small[0],"\(dicom)/meta-over.dcm","\(dicom)/meta-limit.dcm",small[1]],cancelled:{false})
    check(metaResults.map(\.status)==[.success,.failure,.success,.success],"invalid File Meta leaves adjacent valid files sendable")
    check(metaResults[1].httpStatus==0,"excessive File Meta was not sent")
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
    results=try node("stow-xml").store(files:small,cancelled:{false})
    check(results.map(\.status)==[.success,.failure,.success,.success,.success] && results[1].reasonCode==0xC000 && results[1].httpStatus==202,"an XML store answer gives each instance's outcome: \(results.map(\.reason))")
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
    let large=try configured(base+"/large",timeout:120)
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
    print("PASS: QIDO paging/204, separate QIDO and WADO paths, retrieve syntax, Basic/API key/Bearer headers, a trusted server certificate, a client certificate (mutual TLS), Test classification, STOW batches with per-instance results, 401/403/404/500, redirects, timeout, cancellation, sanitized errors, no temporary files left, bounded RSS for a large retrieve and a large send")
   } catch {print("FAIL",error);exit(1)}
  }
  done.wait()
 }
}
'''


def sources_at(revision, folder):
    names = ['Horos/Sources/DICOMwebCredentials.swift', 'Horos/Sources/DICOMwebMultipart.swift', 'Horos/Sources/DICOMwebClient.swift',
             'Horos/Sources/DICOMwebNode.swift']
    if not revision: names.append('Horos/Sources/NonInteractiveKeychainRead.swift')
    if revision:
        listed = subprocess.run(['git', 'ls-tree', '--name-only', revision, 'Horos/Sources/DICOM-Swift/'], cwd=root,
                                capture_output=True, text=True).stdout.split()
        paths = []
        for name in names + [n for n in listed if n.endswith('.swift')]:
            target = folder / name.replace('/', '_')
            target.write_bytes(subprocess.check_output(['git', 'show', f'{revision}:{name}'], cwd=root))
            paths.append(str(target))
        return paths
    return [str(root / n) for n in names]


tls_server = None
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-http-') as tmp:
        p = Path(tmp)
        check_source = source
        if revision:
            start = check_source.index('    // Receive limits:')
            end = check_source.index('    // HTTP failures,', start)
            check_source = check_source[:start] + check_source[end:]
        (p / 'check.swift').write_text(check_source if revision else check_source.replace("import Foundation\n", "import Foundation\nimport DicomWebClient\nimport DicomData\n").replace(" static func main() {", " static func main() {\n  if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }"))
        (p / 'src').mkdir()
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', *sources_at(revision, p / 'src'),
                        str(p / 'check.swift'), *(swift_flags(p) if not revision else []), '-o', str(p / 'check')], check=True)
        dicom = p / 'dicom'
        dicom.mkdir()
        for n in range(1, 6):
            (dicom / f'small-{n}.dcm').write_bytes(part10(f'2.25.799.{n}', bytes(range(256)) * 4))
        (dicom / 'not-dicom.txt').write_text('not DICOM')
        meta_base = part10('2.25.799.600')
        meta_count = struct.unpack_from('<I', meta_base, 140)[0]
        for name, count in [('meta-below', 65534), ('meta-limit', 65536), ('meta-over', 65538)]:
            padding = element(2, 0x102, b'OB', b'\0' * (count - meta_count - 12))
            bounded = meta_base[:140] + struct.pack('<I', count) + meta_base[144:144 + meta_count] + padding + meta_base[144 + meta_count:]
            (dicom / f'{name}.dcm').write_bytes(bounded)
        (dicom / 'meta-hostile.dcm').write_bytes(meta_base[:140] + struct.pack('<I', 0xFFFFFFFF) + meta_base[144:])
        (dicom / 'meta-truncated.dcm').write_bytes(meta_base[:150])
        (dicom / 'meta-inconsistent.dcm').write_bytes(meta_base[:140] + struct.pack('<I', meta_count - 2) + meta_base[144:])
        block = bytes(range(256)) * 4096
        for n in range(1, BIG_FILES + 1):
            with open(dicom / f'big-{n}.dcm', 'wb') as out:
                header = part10(f'2.25.799.{100 + n}')
                # PixelData of BIG_FILE_MIB MiB, written without holding it in memory.
                out.write(header + struct.pack('<HH', 0x7FE0, 0x10) + b'OB\0\0' + struct.pack('<I', BIG_FILE_MIB << 20))
                for _ in range(BIG_FILE_MIB):
                    out.write(block)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(p / 'key.pem'), '-out', str(p / 'cert.pem'), '-days', '1',
                        '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                        # macOS requires server authentication usage of a certificate a node trusts.
                        '-addext', 'extendedKeyUsage=serverAuth'],
                       check=True, capture_output=True, text=True)
        tls_server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(p / 'cert.pem'), str(p / 'key.pem'))
        tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
        threading.Thread(target=tls_server.serve_forever, daemon=True).start()
        # A client certificate with client authentication usage, and a server
        # on the same certificate that requires it (mutual TLS).
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(p / 'client-key.pem'), '-out', str(p / 'client.pem'), '-days', '1',
                        '-subj', '/CN=Horos DICOMweb test client', '-addext', 'extendedKeyUsage=clientAuth'],
                       check=True, capture_output=True, text=True)
        subprocess.run(['openssl', 'pkcs12', '-export', '-inkey', str(p / 'client-key.pem'), '-in', str(p / 'client.pem'),
                        '-out', str(p / 'client.p12'), '-passout', 'pass:dicomweb-test'], check=True, capture_output=True, text=True)
        mutual_server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
        mutual = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        mutual.load_cert_chain(str(p / 'cert.pem'), str(p / 'key.pem'))
        mutual.verify_mode = ssl.CERT_REQUIRED
        mutual.load_verify_locations(str(p / 'client.pem'))
        mutual_server.socket = mutual.wrap_socket(mutual_server.socket, server_side=True, do_handshake_on_connect=False)
        threading.Thread(target=mutual_server.serve_forever, daemon=True).start()
        (p / 'tmp').mkdir()
        run = subprocess.run([str(p / 'check'), f'http://{BIND_ADDRESS}:{server.server_port}', str(p / 'staging'),
                              str(LARGE_PARTS), str(LARGE_BLOCKS * len(LARGE_BLOCK)), str(RSS_LIMIT_MIB), str(closed_port),
                              str(dicom), str(BIG_FILES), str(BIG_FILE_MIB), f'https://127.0.0.1:{tls_server.server_port}/ok',
                              hashlib.sha256(ssl.PEM_cert_to_DER_cert((p / 'cert.pem').read_text())).hexdigest(),
                              f'https://127.0.0.1:{mutual_server.server_port}/ok', str(p / 'client.p12')],
                             timeout=300, env=dict(os.environ, TMPDIR=f"{p/'tmp'}/"), capture_output=True, text=True)
        if run.returncode == 0 and not revision:
            disk_run = subprocess.run(run.args, timeout=30,
                                      env=dict(os.environ, TMPDIR=f"{p/'tmp'}/", DICOMWEB_DISK_WRITE_FAILURE='1'),
                                      capture_output=True, text=True)
            print((disk_run.stdout + disk_run.stderr).strip())
            assert disk_run.returncode == 0, 'disk-write failure check failed'
            time.sleep(0.2)  # allow the server to observe the aborted connection
        output = run.stdout + run.stderr
        print(output.strip())
        assert run.returncode == 0, 'the client check failed'
        assert not any(secret in output for secret in SECRETS), 'a secret reached the output'
    assert not redirect_hits, 'Redirect request reached another resource'
    if not revision:
        assert len(budget_transfers) == 19, budget_transfers
    for mode, (sent, size) in budget_transfers.items():
        if 'exact' in mode:
            assert sent == size, (mode, sent, size)
        else:
            assert sent < size, ('oversized response was sent in full', mode, sent, size)
            # Socket buffers may transmit beyond the client budget before the
            # server observes cancellation. The spool budget bounds writes, not
            # bytes already queued by the peer.
    if not revision:
        print('PASS: Content-Length/chunked receive budgets, exact boundary, early cancellation and disk-open cleanup')

    def seen(mode):
        return [r for r in requests if r['path'].startswith('/' + mode + '/')]
    # Each credential kind sent exactly its header, and nothing else carried a secret.
    import base64
    basic = 'Basic ' + base64.b64encode(b'reader:' + SECRETS[0].encode()).decode()
    assert all(r['headers'].get('authorization') == basic and 'x-api-key' not in r['headers'] for r in seen('auth-basic')), 'Basic header'
    assert all(r['headers'].get('x-api-key') == SECRETS[1] and 'authorization' not in r['headers'] for r in seen('auth-key')), 'API key header'
    assert all(r['headers'].get('authorization') == 'Bearer ' + SECRETS[2] for r in seen('auth-bearer')), 'Bearer header'
    for mode in ('auth-basic', 'auth-key', 'auth-bearer'):
        assert any(r['path'].endswith('/studies/2.25.1064') for r in seen(mode)), 'authenticated WADO'
        assert any(r['method'] == 'POST' for r in seen(mode)), 'authenticated STOW'
        assert any(r['query'].get('limit') == ['1'] for r in seen(mode)), 'authenticated Test'
    for r in requests:
        if r['path'].split('/')[1] not in ('auth-basic', 'auth-key', 'auth-bearer', 'unauthorized', 'stow-401'):
            assert not any(s in json.dumps(r['headers']) for s in SECRETS), 'a secret went to ' + r['path']
    # Paths: QIDO and WADO under their own paths, the Test query with limit=1.
    node = seen('node')
    assert any(r['path'] == '/node/qido-rs/studies' and r['query'].get('limit') == ['1'] for r in node), 'Test used the QIDO path with limit=1'
    wado = [r for r in node if r['path'].startswith('/node/wado/rs/studies/')]
    assert wado and all('transfer-syntax' in r['headers']['accept'] for r in wado), 'WADO used its own path'
    assert wado[0]['headers']['accept'] == 'multipart/related; type="application/dicom"; transfer-syntax=*', wado[0]['headers']['accept']
    assert wado[1]['headers']['accept'] == ('multipart/related; type="application/dicom"; transfer-syntax=1.2.840.10008.1.2.4.50, '
                                         'multipart/related; type="application/dicom"; transfer-syntax=1.2.840.10008.1.2.1; q=0.9'), wado[1]['headers']['accept']
    # 406 to the first range: asked again with Explicit VR Little Endian alone.
    refused = [r['headers']['accept'] for r in seen('refuse-first')]
    assert refused == [wado[1]['headers']['accept'], 'multipart/related; type="application/dicom"; transfer-syntax=1.2.840.10008.1.2.1'], refused
    assert len(seen('refuse-all')) == 2, seen('refuse-all')
    paged = [r for r in requests if r['path'] == '/paged/studies']
    assert paged[0]['query'].get('00100010') == ['José*'] and paged[0]['query'].get('includefield') == ['00100020'], paged[0]['query']
    assert [r['query']['offset'] for r in paged] == [['0'], ['2']], 'offset advances by the received page size'
    assert [r['query']['offset'] for r in requests if r['path'] == '/repeat/studies'] == [['0'], ['1']], 'a node that ignores offset is asked twice'
    assert [r['query']['offset'] for r in requests if r['path'] == '/overlap/studies'] == [['0'], ['2']], 'the overlapping page ends the query'
    xml = [r for r in requests if r['method'] == 'POST' and r['path'].startswith('/stow-xml')]
    assert xml and all('application/dicom+xml' in r['headers'].get('accept', '') for r in xml), 'a send accepts an XML answer'
    for mode in ('fuzzy-warning', 'ignores-limit'):
        assert len(seen(mode)) == 1, mode + ' should not trigger a spurious second request'
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
    assert not [s for s in stow_requests if s['mode'] == 'stow-meta-rejected'], 'invalid File Meta never reaches transport'
    meta = [s for s in stow_requests if s['mode'] == 'stow-meta']
    assert [p['uid'] for s in meta for p in s['parts']] == ['2.25.799.1', '2.25.799.600', '2.25.799.2'], 'valid neighbors retain order and payload identity'
    big = [s for s in stow_requests if s['mode'] == 'stow-big']
    assert len(big) == BIG_FILES and all(s['bytes'] > BIG_FILE_MIB << 20 for s in big), [s['bytes'] for s in big]
    print('PASS: headers per credential kind, QIDO/WADO paths, Accept per retrieve syntax, STOW batching and part types, no secret sent elsewhere')
finally:
    origin_server.shutdown()
    origin_server.server_close()
    if tls_server is not None:
        tls_server.shutdown()
        tls_server.server_close()
    server.shutdown()
    server.server_close()
