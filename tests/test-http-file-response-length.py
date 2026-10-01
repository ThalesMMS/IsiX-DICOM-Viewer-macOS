#!/usr/bin/env python3
"""A file response announces the length of the bytes it serves, also through a symbolic link.

HTTPFileResponse and HTTPAsyncFileResponse read through an NSFileHandle, which
follows a symbolic link to its target. They took the Content-Length from the
attributes of the path, which describe the link itself: a link named "payload"
is seven bytes long, so a 1024 byte body was announced as seven and the rest of
it either was cut off or ran into the next response of a kept-alive connection.

This compiles the two production classes with the address and undefined
behaviour sanitizers and checks, on a synthetic file made here:

- a regular path, a relative link and a link to a link all announce the size of
  the target, and that is exactly what reading to the end delivers;
- an offset set for a Range request reads from there and still ends at the
  announced length;
- a missing path and a link whose target is gone give no response at all;
- the response keeps and closes its own file handle.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

HELPER = r'''
#import "HTTPResponse.h"
#import "HTTPAsyncFileResponse.h"

static int failures;
#define check(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); failures++; } } while (0)

static void exercise(NSString *path, unsigned long long expected)
{
    HTTPFileResponse *response = [[HTTPFileResponse alloc] initWithFilePath:path];
    check(response != nil);
    check([response contentLength] == expected);
    check([[response filePath] isEqualToString:path]);
    check(![response isDone]);
    NSMutableData *body = [NSMutableData data];
    while (![response isDone]) {
        NSData *chunk = [response readDataOfLength:300];
        if ([chunk length] == 0) break;
        [body appendData:chunk];
    }
    check([body length] == expected);
    check([response isDone]);
    check([response offset] == expected);
    // A Range request moves the offset; the remainder still ends at the announced length.
    [response setOffset:1000];
    check([[response readDataOfLength:4096] length] == expected - 1000);
    check([response isDone]);
    [response release];

    HTTPAsyncFileResponse *asynchronous = [[HTTPAsyncFileResponse alloc] initWithFilePath:path forConnection:nil
                                                                             runLoopModes:@[NSDefaultRunLoopMode]];
    check(asynchronous != nil);
    check([asynchronous contentLength] == expected);
    [asynchronous release];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        for (NSString *name in @[@"payload", @"link", @"link to link"])
            exercise([folder stringByAppendingPathComponent:name], 1024);
        for (NSString *name in @[@"missing", @"dangling"]) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            check([[[HTTPFileResponse alloc] initWithFilePath:path] autorelease] == nil);
            check([[[HTTPAsyncFileResponse alloc] initWithFilePath:path forConnection:nil
                                                      runLoopModes:@[NSDefaultRunLoopMode]] autorelease] == nil);
        }
    }
    // Every handle a response opened is closed with it.
    int descriptor = open("/dev/null", O_RDONLY);
    check(descriptor == 3);
    close(descriptor);
    if (failures) return 1;
    puts("PASS: regular file, link and link to link announce and serve 1024 bytes; missing and dangling paths give no response");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-http-file-response-') as directory:
    folder = Path(directory)
    data = folder / 'data'
    data.mkdir()
    (data / 'payload').write_bytes(bytes(range(256)) * 4)
    os.symlink('payload', data / 'link')
    os.symlink('link', data / 'link to link')
    os.symlink('gone', data / 'dangling')
    assert os.lstat(data / 'link').st_size == 7
    (folder / 'helper.m').write_text(HELPER)
    sources = [root / 'cocoahttpserver' / name for name in ('HTTPResponse.m', 'HTTPAsyncFileResponse.m')]
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                    '-I', str(root / 'cocoahttpserver'), str(folder / 'helper.m'), *map(str, sources),
                    '-framework', 'Foundation', '-o', str(folder / 'helper')], check=True, timeout=120)
    result = subprocess.run([str(folder / 'helper'), str(data)], capture_output=True, text=True, timeout=30)
    print(result.stdout + result.stderr, end='')
    raise SystemExit(result.returncode)
