#!/usr/bin/env python3
"""A request the web portal cannot parse must not end its connection thread (#757).

The portal serves every connection on one of four threads. An exception raised
while handling a request - invalid UTF-8 in a parameter, a token or username
without a value or given twice, a POST body of 0 or 1 byte - used to unwind out
of the connection and end its thread, so four such requests, without signing
in, stopped the portal.

This checks, in WebPortalConnection (Objective-C now, Swift after #718), that:
- replyToHTTPRequest runs the request inside an exception guard, answers a
  generic 400 when it catches one, and always clears the per-request state;
- processDataChunk runs inside a guard that resets the POST;
- the multipart separator scan cannot wrap its bound around for a body shorter
  than the separator.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path, source_text  # noqa: E402

path = source_path('WebPortalConnection')
text = source_text('WebPortalConnection')
swift = path.suffix == '.swift'
failures = []


def body(signature):
    """The body of the method whose declaration contains `signature`."""
    at = text.find(signature)
    if at < 0:
        failures.append(f'{path.name}: no {signature}')
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    return ''


guard = 'HorosObjCException.perform' if swift else '@try'
catch = 'catch' if swift else '@catch'

reply = body('func replyToHTTPRequest()' if swift else '-(void)replyToHTTPRequest {')
if guard not in reply or 'replyToHTTPRequestUnguarded' not in reply:
    failures.append('replyToHTTPRequest does not run the request inside an exception guard')
if not re.search(r'statusCode\s*[=(:]\s*400|setStatusCode\(400\)|statusCode = 400', reply):
    failures.append('replyToHTTPRequest does not answer 400 when the request raises')
if 'handleResourceNotFound' not in reply:
    failures.append('replyToHTTPRequest does not send the error response when the request raises')
for state in ('response', 'user', 'session'):
    if not re.search(r'self\.%s\s*=\s*(nil|NULL)' % state, reply):
        failures.append(f'replyToHTTPRequest does not always clear self.{state}')

chunk = body('func processDataChunk(' if swift else '- (void)processDataChunk:(NSData *)postDataChunk\n{')
if guard not in chunk or 'processDataChunkUnguarded' not in chunk or 'resetPOST' not in chunk:
    failures.append('processDataChunk does not run inside a guard that resets the POST')

# A body shorter than the two-byte separator: the old unsigned bound wrapped.
if re.search(r'for\s*\(\s*int\s+i\s*=\s*0\s*;\s*i\s*<\s*\[postDataChunk length\]\s*-\s*l\s*;', text):
    failures.append('the separator scan still subtracts from an unsigned length')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print(f'PASS: {path.name} guards replyToHTTPRequest and processDataChunk, and the separator scan is signed')
