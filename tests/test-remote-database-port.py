#!/usr/bin/env python3
"""A remote database is created with the port it is looked up by (#847).

+[RemoteDicomDatabase databaseForLocation:port:name:update:] resolves the
location and the port it is given with
+[RemoteDatabaseNodeIdentifier location:port:toHost:port:], which answers the
port given, or the default port 8780 for 0, and looks for a database already
open at that host and that resolved port. It created the new database with the
port it was given, though: a caller that passed 0 got a database at port 0,
which the next lookup, at 8780, never found, so another one was created for the
same server each time. The new database now takes the resolved port, as
-initWithLocation:port: always did.

The resolver runs compiled from the source with xcrun swiftc, to show that the
two ports differ for 0; -databaseForLocation:port:name:update: needs the
database classes around it, so which port it compares and which it creates the
database with is read from the source. `<git revision>` as an optional argument
reads the sources of that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
SOURCE = 'Horos/Sources/RemoteDicomDatabase.swift'
IDENTIFIER = 'Horos/Sources/RemoteDataNodeIdentifier.swift'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text()


def block(source, start):
    """From `start` to the brace that closes the first brace after it."""
    opening = source.find('{', start)
    if start < 0 or opening < 0:
        return ''
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ''


text = read(SOURCE)
method = block(text, text.find('@objc(databaseForLocation:port:name:update:)'))
if not method:
    failures.append('+databaseForLocation:port:name:update: is not in %s' % SOURCE)
else:
    resolved = re.search(r'location\(location, port: port, to: &host, port: &(\w+)\)', method)
    compared = re.search(r'if db\.port == (\w+)', method)
    created = re.search(r'RemoteDicomDatabase\(host: host, port: ([^,]+), update: flagUpdate\)', method)
    if not resolved or not compared or not created:
        failures.append('the lookup or the creation of the database changed; this test needs a new look')
    else:
        if compared.group(1) != resolved.group(1):
            failures.append('the lookup does not compare the resolved port (%s)' % compared.group(1))
        if created.group(1).strip() != resolved.group(1):
            failures.append('the new database is created with %s, not with the port the lookup compared (%s)'
                            % (created.group(1).strip(), resolved.group(1)))

# The two ports differ: the resolver answers 8780 for 0.
identifier = read(IDENTIFIER)
resolver = block(identifier, identifier.find('@objc(location:port:toAddress:port:defaultPort:)'))
DRIVER = '''
import Foundation
func DataNodeIdentifierLogStackTrace(_ message: String) {}
enum Resolver {
    static func resolve(_ port: UInt) -> Int {
        var output = -1
        _ = location("localhost", port: port, toAddress: nil, port: &output, defaultPort: 8780)
        return output
    }
}
print("0=\\(Resolver.resolve(0))")
print("11112=\\(Resolver.resolve(11112))")
'''
if not resolver:
    failures.append('the location resolver is not in %s' % IDENTIFIER)
else:
    function = resolver[resolver.find('public class func '):].replace('public class func ', 'func ', 1)
    with tempfile.TemporaryDirectory(prefix='horos-remote-port-') as directory:
        directory = Path(directory)
        (directory / 'resolver.swift').write_text('import Foundation\n\n' + function + '\n')
        (directory / 'main.swift').write_text(DRIVER)
        binary = directory / 'resolver'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'resolver.swift'), str(directory / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the resolver does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            found = dict(line.split('=', 1) for line in run.stdout.splitlines() if '=' in line)
            if found != {'0': '8780', '11112': '11112'}:
                failures.append('the resolver answers %r; this test needs a new look' % found)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a remote database is created with the resolved port it is looked up by')
