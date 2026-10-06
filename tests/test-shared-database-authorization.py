#!/usr/bin/env python3
"""Execute authorization framing and incremental parsing, and guard server routing."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
code=r'''
import Foundation
let auth = SharedDatabaseAuthorization.self
let request = Data("DATAB\0".utf8)
let password = "synthetic-é"
let frame = auth.authenticatedRequest(request, password: password)!
for count in 0..<frame.count {
    precondition(auth.authorizedPrefixLength(Data(frame.prefix(count)), password: password, required: true) == 0)
}
let consumed = auth.authorizedPrefixLength(frame, password: password, required: true)
precondition(consumed > 0 && Data(frame.dropFirst(consumed)) == request)
precondition(auth.authorizedPrefixLength(frame, password: "incorrect", required: true) == -1)
precondition(auth.authorizedPrefixLength(frame, password: nil, required: true) == -1)
precondition(auth.authorizedPrefixLength(frame, password: nil, required: false) == consumed)
var huge = frame
huge.replaceSubrange(6..<10, with: [255,255,255,255])
precondition(auth.authorizedPrefixLength(huge, password: password, required: true) == -1)
var zero = frame
zero.replaceSubrange(6..<10, with: [0,0,0,0])
precondition(auth.authorizedPrefixLength(zero, password: password, required: true) == -1)
var badCommand = frame; badCommand[badCommand.count-1] = 1
precondition(auth.authorizedPrefixLength(badCommand, password: password, required: true) == -1)
precondition(auth.authenticatedRequest(request, password: "") == nil)
precondition(auth.authenticatedRequest(request, password: String(repeating:"x", count:4097)) == nil)
precondition(auth.authenticatedRequest(Data("AUTHR\0".utf8), password: password) == nil)
let offset = (Data([0,0]) + frame).dropFirst(2)
precondition(auth.authorizedPrefixLength(offset, password: password, required: true) == consumed)
for command in ["DATAB","DBSIZ","VERSI","SENDD","SENDG","NEWMS","ADDAL","REMAL","SETVA","MFILE","DCMSE","DICOM","UNKNOWN"] {
    precondition(!auth.isPublicCommand(command))
}
for command in ["DBVER","ISPWD","PASWD","AUTHV","GETDI"] {precondition(auth.isPublicCommand(command))}
print("ok: fragmented authorization, wrong/empty password, malformed lengths, command policy and nonzero data offsets")
'''
with tempfile.TemporaryDirectory(prefix='horos-auth-') as temp:
    folder=Path(temp);(folder/'main.swift').write_text(code);binary=folder/'probe'
    build=subprocess.run(['xcrun','swiftc',str(root/'Horos/Sources/SharedDatabaseAuthorization.swift'),str(folder/'main.swift'),'-o',str(binary)],capture_output=True,text=True)
    assert build.returncode==0,build.stderr
    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
    assert result.returncode==0,result.stderr
    print(result.stdout,end='')
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
# BonjourPublisher is Swift.
server=sources.source_text('BonjourPublisher')
gate=server.index('protected && !_authorized')
assert gate < server.index('if strcmp(command, "DATAB") == 0')
assert 'guard let name = NSString(utf8String: command) else { close(); return }' in server and 'command[5] != 0' in server
assert 'length == 0 || length > 4097' in server
# RemoteDicomDatabase is Swift: the client's source, whatever its language.
client=sources.source_text('RemoteDicomDatabase')
assert ('SharedDatabaseAuthorization.authenticatedRequest(request as Data, password:' if sources.is_swift('RemoteDicomDatabase')
        else 'authenticatedRequest:request password:') in client
assert 'supportsAuthenticatedRequests' in client and 'Unauthenticated fallback is disabled.' in client
print('ok: all sensitive server commands gated before dispatch; client has no protected legacy fallback')
