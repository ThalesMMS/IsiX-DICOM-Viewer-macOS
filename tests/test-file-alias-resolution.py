#!/usr/bin/env python3
"""Paths through symbolic links and Finder aliases resolve as they did in
Objective-C; regular import files skip bookmark resolution.

The resolution is IsiXStorage's NSString extension (PathAliasResolution.swift),
which keeps the selectors of the former NSString (SymlinksAndAliases)
category. Two checks:

- bookmark reads: a Swift driver counts +[NSURL bookmarkDataWithContentsOfURL:error:]
  (the bookmark read, swapped for a counting one) while 100 ordinary files,
  a Finder alias, a symbolic link to the alias and a missing path resolve.
  Only the alias and the link may read a bookmark;
- equivalence: the six selectors answer the same, on the same paths, as the
  Objective-C category of the last revision that had it, read from git and
  compiled as it was: an ordinary file and folder, an alias to each, absolute
  and relative links, a link to an alias, a link to nothing, a link to a link,
  an alias inside a path, a missing path and a relative one.

Everything happens in a temporary folder.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
FORMER = 'LetsMoveAndDock/NSString+SymlinksAndAliases.m'
reference = history_reference.before_removal(FORMER)
if reference is None and subprocess.run(['git', '-C', str(root), 'cat-file', '-e', 'HEAD:' + FORMER],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'

SELECTORS = ['stringByResolvingSymlinksAndAliases', 'stringByIterativelyResolvingSymlinkOrAlias',
             'stringByResolvingSymlink', 'stringByConditionallyResolvingSymlink',
             'stringByResolvingAlias', 'stringByConditionallyResolvingAlias']

# Prints, for each path argument, what each selector answers ("<nil>" for nil).
PRINTER = r'''#import <Foundation/Foundation.h>
int main(int argc, char **argv) { @autoreleasepool {
    NSArray *selectors = @[%s];
    NSMutableArray *rows = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        NSString *path = @(argv[i]);
        NSMutableArray *row = [NSMutableArray arrayWithObject:path];
        for (NSString *name in selectors) {
            id value = [path performSelector:NSSelectorFromString(name)];
            [row addObject:value ?: @"<nil>"];
        }
        [rows addObject:row];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:0 error:NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    return 0;
}}
''' % ', '.join('@"%s"' % name for name in SELECTORS)

COUNTER = r'''
import Foundation
import IsiXStorage
import ObjectiveC

// +[NSURL bookmarkDataWithContentsOfURL:error:] replaced by one that counts
// and calls the original.
typealias BookmarkRead = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutableRawPointer?) -> AnyObject?
nonisolated(unsafe) var bookmarkReads = 0
let selector = NSSelectorFromString("bookmarkDataWithContentsOfURL:error:")
let method = class_getClassMethod(NSURL.self, selector)!
nonisolated(unsafe) let original = unsafeBitCast(method_getImplementation(method), to: BookmarkRead.self)
let counting: @convention(block) (AnyObject, AnyObject, UnsafeMutableRawPointer?) -> AnyObject? = { receiver, url, error in
    bookmarkReads += 1
    return original(receiver, selector, url, error)
}
method_setImplementation(method, imp_implementationWithBlock(counting))

func check(_ condition: Bool, _ label: String) {
    if !condition { print("FAIL: \(label)"); exit(1) }
}
let folder = (CommandLine.arguments[1] as NSString).standardizingPath
let file = (folder as NSString).appendingPathComponent("image.dcm")
try! Data("synthetic".utf8).write(to: URL(fileURLWithPath: file))
for _ in 0..<100 {
    check(((file as NSString).resolvingSymlinksAndAliases() as NSString?)?.standardizingPath == (file as NSString).standardizingPath, "ordinary file")
}
check(bookmarkReads == 0, "ordinary files read \(bookmarkReads) bookmarks")
let bookmark = try! URL(fileURLWithPath: file).bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
let alias = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("image alias"))
try! URL.writeBookmarkData(bookmark, to: alias)
check(((alias.path as NSString).resolvingSymlinksAndAliases() as NSString?)?.standardizingPath == (file as NSString).standardizingPath, "alias")
check(bookmarkReads == 1, "the alias read \(bookmarkReads) bookmarks, not 1")
let link = (folder as NSString).appendingPathComponent("image link")
try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: alias.path)
check(((link as NSString).resolvingSymlinksAndAliases() as NSString?)?.standardizingPath == (file as NSString).standardizingPath, "link to alias")
check(bookmarkReads == 2, "the link to the alias read \(bookmarkReads - 1) bookmarks, not 1")
let missing = (folder as NSString).appendingPathComponent("missing")
let missingResolved = (missing as NSString).resolvingSymlinksAndAliases()
check((missingResolved as NSString?)?.lastPathComponent == "missing", "missing path")
check(!FileManager.default.fileExists(atPath: missingResolved ?? "/"), "missing path exists")
print("PASS: 100 ordinary files make no bookmark reads; Finder alias, symlink to alias and absent path resolve correctly")
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def make_scenario(folder):
    """The paths both implementations resolve."""
    import os
    folder.mkdir()
    (folder / 'file.dcm').write_text('synthetic')
    (folder / 'folder').mkdir()
    (folder / 'folder/inner.dcm').write_text('synthetic')
    os.symlink(str(folder / 'file.dcm'), folder / 'absolute link')
    os.symlink('file.dcm', folder / 'relative link')
    os.symlink('folder', folder / 'folder link')
    os.symlink('nothing', folder / 'dangling link')
    os.symlink('relative link', folder / 'link to link')
    return folder


ALIASES = r'''
import Foundation
let folder = CommandLine.arguments[1]
for (target, name) in [("file.dcm", "file alias"), ("folder", "folder alias")] {
    let url = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(target))
    let bookmark = try! url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try! URL.writeBookmarkData(bookmark, to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)))
}
try! FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("link to alias"),
                                            withDestinationPath: "file alias")
'''

failures = []
with tempfile.TemporaryDirectory(prefix='isix-alias-resolution-') as temporary:
    work = Path(temporary)
    target = ['-target', 'arm64-apple-macos15.0']
    flags = isix_modules.module_flags('IsiXStorage', work / 'modules', target)
    (work / 'counter.swift').write_text(COUNTER)
    # The extension is reached by selector only: load the whole library.
    run(['xcrun', 'swiftc', '-swift-version', '6', *target, *flags, '-Xlinker', '-all_load',
         str(work / 'counter.swift'), '-o', str(work / 'counter')])
    counted = subprocess.run([str(work / 'counter'), str(work)], capture_output=True, text=True, timeout=60)
    print(counted.stdout.strip())
    if counted.returncode != 0:
        failures.append(f'bookmark reads: exit {counted.returncode} ' + (counted.stdout + counted.stderr).strip()[-2000:])

    scenario = make_scenario(work / 'scenario')
    (work / 'aliases.swift').write_text(ALIASES)
    run(['xcrun', 'swiftc', *target, str(work / 'aliases.swift'), '-o', str(work / 'aliases')])
    run([str(work / 'aliases'), str(scenario)])
    paths = [str(scenario / name) for name in ('file.dcm', 'folder', 'file alias', 'folder alias', 'absolute link',
                                               'relative link', 'folder link', 'dangling link', 'link to link',
                                               'link to alias', 'folder alias/inner.dcm', 'missing',
                                               'folder link/../file.dcm')] + ['relative/path']

    (work / 'printer.m').write_text(PRINTER)
    # The new implementation: the printer linked with IsiXStorage.
    run(['xcrun', 'clang', '-fobjc-arc', '-w', *target, '-c', str(work / 'printer.m'), '-o', str(work / 'printer.o')])
    toolchain = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parents[1]
    run(['xcrun', 'clang', *target, str(work / 'printer.o'), '-Wl,-all_load',
         *isix_modules.link_flags('IsiXStorage', work / 'modules'), '-L' + str(toolchain / 'lib/swift/macosx'),
         '-framework', 'Foundation', '-o', str(work / 'new')])
    current = json.loads(run([str(work / 'new'), *paths], text=True).stdout)
    if reference:
        former = work / 'former'
        former.mkdir()
        for name in ('NSString+SymlinksAndAliases.h', 'NSString+SymlinksAndAliases.m'):
            (former / name).write_bytes(history_reference.show(reference, 'LetsMoveAndDock/' + name))
        run(['xcrun', 'clang', '-fobjc-arc', '-w', *target, '-I', str(former), str(work / 'printer.m'),
             str(former / 'NSString+SymlinksAndAliases.m'), '-framework', 'Cocoa', '-o', str(work / 'old')])
        before = json.loads(run([str(work / 'old'), *paths], text=True).stdout)
        for old, new in zip(before, current):
            if old != new:
                failures.append(f'{Path(old[0]).name}: Objective-C {old[1:]}, Swift {new[1:]}')
        if len(before) == len(current) and not failures:
            print(f'PASS: the six selectors answer as the Objective-C category of {reference[:10]} on {len(paths)} paths')
    else:
        print('note: no revision of this history has the Objective-C category; the comparison was not run')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
