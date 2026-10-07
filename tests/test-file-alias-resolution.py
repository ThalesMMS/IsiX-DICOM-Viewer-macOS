#!/usr/bin/env python3
"""Regular import files skip bookmark resolution; Finder aliases still resolve."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
driver = r'''#import <Foundation/Foundation.h>
#import "NSString+SymlinksAndAliases.h"
static unsigned bookmarkReads;
CFDataRef CountBookmarkReads(CFAllocatorRef allocator, CFURLRef url, CFErrorRef *error) {
    bookmarkReads++;
    return CFURLCreateBookmarkDataFromFile(allocator, url, error);
}
#define check(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while (0)
int main(int argc, char **argv) { @autoreleasepool {
    NSString *folder = [@(argv[1]) stringByStandardizingPath];
    NSString *file = [folder stringByAppendingPathComponent:@"image.dcm"];
    check([[@"synthetic" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
    for (NSUInteger i = 0; i < 100; i++)
        check([[[file stringByResolvingSymlinksAndAliases] stringByStandardizingPath] isEqualToString:[file stringByStandardizingPath]]);
    check(bookmarkReads == 0);
    NSURL *target = [NSURL fileURLWithPath:file];
    NSData *bookmark = [target bookmarkDataWithOptions:NSURLBookmarkCreationSuitableForBookmarkFile
                      includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];
    NSURL *alias = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"image alias"]];
    check(bookmark != nil && [NSURL writeBookmarkData:bookmark toURL:alias options:0 error:NULL]);
    check([[[alias.path stringByResolvingSymlinksAndAliases] stringByStandardizingPath] isEqualToString:[file stringByStandardizingPath]]);
    check(bookmarkReads == 1);
    NSString *link = [folder stringByAppendingPathComponent:@"image link"];
    check([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:alias.path error:NULL]);
    check([[[link stringByResolvingSymlinksAndAliases] stringByStandardizingPath] isEqualToString:[file stringByStandardizingPath]]);
    check(bookmarkReads == 2);
    NSString *missing = [folder stringByAppendingPathComponent:@"missing"];
    NSString *missingResolved = [missing stringByResolvingSymlinksAndAliases];
    check([missingResolved.lastPathComponent isEqualToString:@"missing"]);
    check(![NSFileManager.defaultManager fileExistsAtPath:missingResolved]);
    puts("PASS: 100 ordinary files make no bookmark reads; Finder alias, symlink to alias and absent path resolve correctly");
    return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-alias-resolution-') as temporary:
    folder = Path(temporary)
    (folder / 'main.m').write_text(driver)
    # Intercept the expensive system call in the real implementation only.
    (folder / 'counter.h').write_text('#import <Foundation/Foundation.h>\n'
                                    'CFDataRef CountBookmarkReads(CFAllocatorRef, CFURLRef, CFErrorRef *);\n'
                                    '#define CFURLCreateBookmarkDataFromFile CountBookmarkReads\n')
    common = ['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
              '-I', str(root / 'LetsMoveAndDock')]
    subprocess.run(common + ['-include', str(folder / 'counter.h'), '-c',
                            str(root / 'LetsMoveAndDock/NSString+SymlinksAndAliases.m'),
                            '-o', str(folder / 'resolver.o')], check=True, capture_output=True)
    subprocess.run(common + [str(folder / 'main.m'), str(folder / 'resolver.o'),
                            '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check'), str(folder)], check=True)
