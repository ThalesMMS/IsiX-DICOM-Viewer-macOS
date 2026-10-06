#!/usr/bin/env python3
"""NSMutableArray's duplicate removal removes the duplicate itself, and mergeWithArray: adds nothing twice.

MutableArrayCategory.swift is compiled as it is and called from Objective-C,
by its selectors, as BrowserController, DCMTKStoreSCU, OsiriXSCPDataHandler
and the others call it. Each case runs in a process of its own, since the old
code could raise:
- objects: -removeDuplicatedObjects on [X, Y, Y, B, B], X equal to Y but not
  the same object. -indexOfObject: removed the first object equal to the
  duplicate, X, and left Y twice; X, Y and B must stay, in that order.
- strings: -removeDuplicatedStrings on equal strings that are different
  objects. The first of each must be kept where it was, not the last.
- sync: -removeDuplicatedStringsInSyncWithThisArray: on paths paired with
  the images of a multi-frame file. Both arrays must lose the same indexes,
  and each path keep the image it was first paired with.
- null: a path array with NSNull, which -valueForKey: puts for an image
  without a path. Sorting with -compare: raised (-[NSNull length]); NSNull
  must stay.
- equivalent: a string between two literal copies of a canonically
  equivalent one. -compare: sorted the three as equal and the copies were
  not always next to each other; the second copy must go.
- merge: -mergeWithArray: with an object twice in the array it receives.
  The search stopped at the array's original length; the object must be
  added once.

`<git revision>` as an optional argument reads the category from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/MutableArrayCategory.swift'
source = (subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
          if revision else (root / path).read_text())

driver = r'''
#import <Foundation/Foundation.h>

@interface NSMutableArray (MutableArrayCategoryUnderTest)
- (void)mergeWithArray:(NSArray *)array;
- (void)removeDuplicatedStrings;
- (void)removeDuplicatedStringsInSyncWithThisArray:(NSMutableArray *)otherArray;
- (void)removeDuplicatedObjects;
@end

@interface NSArray (ShuffleUnderTest)
- (NSArray *)shuffledArray;
@end

// Equal to any Key of the same name, whatever the object.
@interface Key : NSObject
@property (copy) NSString *name;
@end
@implementation Key
+ (instancetype)named:(NSString *)name { Key *k = [Key new]; k.name = name; return k; }
- (BOOL)isEqual:(id)other { return [other isKindOfClass:[Key class]] && [[other name] isEqual:self.name]; }
- (NSUInteger)hash { return self.name.hash; }
- (NSString *)description { return [NSString stringWithFormat:@"%@@%p", self.name, self]; }
@end

static BOOL identical(NSArray *a, NSArray *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) if (a[i] != b[i]) return NO;
    return YES;
}

static NSString *copyOf(NSString *s) { return [NSMutableString stringWithString:s]; }

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *which = @(argv[1]);
        BOOL ok = NO;
        NSString *got = nil;
        if ([which isEqual:@"shuffle"]) {
            ok = YES;
            for (NSUInteger count = 0; count <= 256; count += count < 2 ? 1 : 17) {
                NSMutableArray *input = [NSMutableArray array];
                for (NSUInteger i = 0; i < count; ++i) [input addObject:[Key named:[NSString stringWithFormat:@"%lu", (unsigned long)i]]];
                NSArray *before = [input copy];
                for (NSUInteger iteration = 0; iteration < 40; ++iteration) {
                    NSArray *shuffled = [input shuffledArray];
                    ok &= identical(input, before) && shuffled.count == before.count;
                    for (id value in before) ok &= [shuffled indexOfObjectIdenticalTo:value] != NSNotFound;
                }
            }
        } else if ([which isEqual:@"objects"]) {
            Key *x = [Key named:@"a"], *y = [Key named:@"a"], *b = [Key named:@"b"];
            NSMutableArray *a = [NSMutableArray arrayWithObjects:x, y, y, b, b, nil];
            [a removeDuplicatedObjects];
            ok = identical(a, @[x, y, b]);
            got = a.description;
        } else if ([which isEqual:@"strings"]) {
            NSString *b1 = copyOf(@"/b"), *a1 = copyOf(@"/a"), *b2 = copyOf(@"/b"), *c1 = copyOf(@"/c"), *a2 = copyOf(@"/a");
            NSMutableArray *a = [NSMutableArray arrayWithObjects:b1, a1, b2, c1, a2, nil];
            [a removeDuplicatedStrings];
            ok = identical(a, @[b1, a1, c1]);
            got = a.description;
        } else if ([which isEqual:@"sync"]) {
            NSMutableArray *paths = [NSMutableArray arrayWithObjects:copyOf(@"/mf"), copyOf(@"/x"), copyOf(@"/mf"), copyOf(@"/y"), copyOf(@"/x"), copyOf(@"/mf"), nil];
            NSArray *originalPaths = [paths copy];
            NSMutableArray *images = [NSMutableArray arrayWithObjects:@"mf-frame1", @"x-1", @"mf-frame2", @"y-1", @"x-2", @"mf-frame3", nil];
            [paths removeDuplicatedStringsInSyncWithThisArray:images];
            ok = identical(paths, @[originalPaths[0], originalPaths[1], originalPaths[3]])
                && [images isEqual:@[@"mf-frame1", @"x-1", @"y-1"]];
            NSMutableArray *alone = [NSMutableArray arrayWithObjects:@"/p", @"/p", nil];
            [alone removeDuplicatedStringsInSyncWithThisArray:nil];
            ok = ok && [alone isEqual:@[@"/p"]];
            got = [NSString stringWithFormat:@"%@ %@", paths, images];
        } else if ([which isEqual:@"null"]) {
            NSMutableArray *paths = [NSMutableArray arrayWithObjects:@"/p", [NSNull null], copyOf(@"/p"), [NSNull null], nil];
            NSMutableArray *images = [NSMutableArray arrayWithObjects:@"1", @"2", @"3", @"4", nil];
            [paths removeDuplicatedStringsInSyncWithThisArray:images];
            ok = [paths isEqual:@[@"/p", [NSNull null], [NSNull null]]] && [images isEqual:@[@"1", @"2", @"4"]];
            got = [NSString stringWithFormat:@"%@ %@", paths, images];
        } else if ([which isEqual:@"equivalent"]) {
            NSString *composed = @"/café", *decomposed = @"/café";
            NSMutableArray *a = [NSMutableArray arrayWithObjects:composed, decomposed, copyOf(composed), nil];
            [a removeDuplicatedStrings];
            ok = [a isEqual:@[composed, decomposed]] && a[0] == composed;
            got = a.description;
        } else if ([which isEqual:@"merge"]) {
            NSMutableArray *a = [NSMutableArray arrayWithObjects:@"a", nil];
            [a mergeWithArray:@[@"b", @"b", copyOf(@"a"), @"c", copyOf(@"c")]];
            [a mergeWithArray:nil];
            ok = [a isEqual:@[@"a", @"b", @"c"]];
            got = a.description;
        }
        printf("%s %s\n", ok ? "ok" : "wrong", [[got stringByReplacingOccurrencesOfString:@"\n" withString:@""] UTF8String]);
        return ok ? 0 : 1;
    }
}
'''

CASES = {
    "shuffle": "bounded production shuffle preserves exact object identities/count and input for empty/single/many arrays",
    'objects': 'removeDuplicatedObjects removes the duplicate, not the first object equal to it',
    'strings': 'removeDuplicatedStrings keeps the first of equal strings where it was',
    'sync': 'removeDuplicatedStringsInSyncWithThisArray: keeps each path with its first object',
    'null': 'a path array with NSNull is deduplicated without raising',
    'equivalent': 'a literal duplicate is removed when an equivalent string sorts between',
    'merge': 'mergeWithArray: adds an object once when it receives it twice',
}

failures = []
with tempfile.TemporaryDirectory(prefix='horos-array-duplicates-') as tmp:
    p = Path(tmp)
    (p / 'MutableArrayCategory.swift').write_text(source)
    (p / 'main.m').write_text(driver)
    try:
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'Horos', '-c',
                        str(p / 'MutableArrayCategory.swift'), '-o', str(p / 'category.o')],
                       check=True, capture_output=True)
        subprocess.run(['xcrun', 'clang', '-c', '-fsanitize=address', '-Werror', '-DHOROS_BRIDGING_HEADER=1', '-I', str(root/'Horos/Sources'), str(root/'Horos/Sources/MutableArrayCategory+CAPI.m'), '-o', str(p/'shuffle.o')], check=True, capture_output=True)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fsanitize=address', '-c', str(p / 'main.m'), '-o', str(p / 'main.o')],
                       check=True, capture_output=True)
        subprocess.run(['xcrun', 'swiftc', '-sanitize=address', str(p / 'main.o'), str(p / 'category.o'), str(p/'shuffle.o'), '-o', str(p / 'arrays')],
                       check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print('FAIL: the category did not build:', e.stderr.decode(errors='replace')[-2000:])
        sys.exit(1)
    for case, claim in CASES.items():
        run = subprocess.run([str(p / 'arrays'), case], capture_output=True, text=True, timeout=30)
        if run.returncode == 0:
            print('ok:', claim)
        else:
            lines = (run.stdout.strip() or run.stderr.strip()).splitlines()
            detail = lines[0] if lines else f'exit {run.returncode}'
            failures.append(f'{claim}: {detail}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: duplicate removal removes the duplicate itself and keeps paired arrays together; merge adds each object once')
