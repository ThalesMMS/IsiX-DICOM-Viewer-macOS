#!/usr/bin/env python3
"""The browser leaves its queue/lock before exceptions, bounds rows and preserves export columns.

Three defects of BrowserController kept by its translation to Swift:

1. -relatedStudiesForStudy: locked the database's context and
   -isUsingExternalViewer: the database, and an exception raised before the
   unlock went on with them locked, which stalls every thread that locks them
   next. Historical revisions use objcTry followed by unlock and rethrow. Current
   consumers run on the context queue; the queue helper captures exceptions,
   releases the context and rethrows after performBlockAndWait returns.
2. -doubleClickComparativeStudy: and the comparative table's tool tip called
   -objectAtIndex: with row -1 (a click or a pointer outside the rows), which
   raised NSRangeException. Now a row outside the studies reads nothing.
3. -exportDBListOnlySelected: counted the column and wrote its tab inside the
   objcTry of the column, so a column that raised shifted the next ones under
   the wrong header, and read their formatter from the wrong column. Now the
   count and the tab come after the objcTry.

Consumer guards are checked in the sources, since the methods need the browser,
its database and its outline around them. The production queue helper is also
compiled and exercised with a real private-queue Core Data context. `<git revision>` as an optional argument reads the
sources of that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def code(text):
    """Without line comments and string contents, so that neither is taken for code."""
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    return '\n'.join(line.split('//')[0].rstrip() for line in text.split('\n'))


def closing(text, opening):
    """The index of the brace that closes the one at `opening`."""
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return index
    return -1


def method(path, selector):
    text = code(read(path))
    at = text.find('@objc(%s)' % selector)
    if at < 0:
        failures.append('%s no longer implements -%s; this test needs a new look' % (path, selector))
        return ''
    opening = text.index('{', at)
    return text[opening:closing(text, opening) + 1]


def statements(text):
    return [line.strip() for line in text.split('\n') if line.strip()]


# The actual helper must carry exceptions out of the context queue before
# propagating them. Its release belongs to the outer finally, not the block.
def queue_helper():
    text = read('Nitrogen/Sources/N2ManagedDatabase.mm')
    at = text.find('void N2ManagedObjectContextPerformAndWait(')
    if at < 0:
        failures.append('the synchronous context helper is absent')
        return ''
    opening = text.index('{', at)
    return text[at:closing(text, opening) + 1]


def check_queue_helper(helper):
    text = code(helper)
    call = text.find('[context performBlockAndWait:^{')
    if call < 0:
        failures.append('the context helper no longer performs on its queue')
        return
    opening = text.index('{', call)
    end = closing(text, opening)
    queued = text[opening:end + 1]
    if not re.search(r'@try\s*\{\s*block\(\);\s*\}\s*@catch\s*\(id (\w+)\)\s*\{\s*exception = \[\1 retain\];\s*\}', queued):
        failures.append('the context helper does not capture the block exception inside the queue')
    after = text[end + 1:]
    if not re.search(r'@finally\s*\{\s*\[context release\];\s*\}\s*if \(exception\)\s*@throw \[exception autorelease\];', after):
        failures.append('the context helper does not release the context and then rethrow outside the queue')
    if '[context retain];' not in text[:call]:
        failures.append('the context helper does not retain its context across queue execution')


def run_queue_helper(helper):
    # Compile the production function, with a real private-queue Core Data
    # context. The subclass marks the interval inside performBlockAndWait so
    # the caller can verify where the original exception arrives.
    driver = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#include <stdlib.h>
#define check(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", #c); abort(); } } while (0)
@interface TrackingContext : NSManagedObjectContext
@property BOOL performing;
@property NSUInteger calls;
@end
@implementation TrackingContext
- (void)performBlockAndWait:(void (^)(void))block {
    self.performing = YES;
    self.calls += 1;
    @try { [super performBlockAndWait:block]; }
    @finally { self.performing = NO; }
}
@end
HELPER
int main(void) { @autoreleasepool {
    TrackingContext *context = [[TrackingContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    __block int ran = 0;
    N2ManagedObjectContextPerformAndWait(context, ^{ check(context.performing); ran++; });
    check(ran == 1 && context.calls == 1 && !context.performing);
    NSException *original = [NSException exceptionWithName:@"SyntheticQueueException" reason:@"synthetic" userInfo:nil];
    BOOL caught = NO;
    @try {
        N2ManagedObjectContextPerformAndWait(context, ^{ check(context.performing); @throw original; });
    } @catch (NSException *exception) {
        check(exception == original && !context.performing && context.calls == 2);
        caught = YES;
    }
    check(caught);
    N2ManagedObjectContextPerformAndWait(context, ^{ ran++; });
    check(ran == 2 && context.calls == 3 && !context.performing);
    [context release];
    TrackingContext *main = [[TrackingContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    N2ManagedObjectContextPerformAndWait(main, ^{ check(main.performing); ran++; });
    check(ran == 3 && main.calls == 1 && !main.performing);
    [main release];
    // SDK's historical no-queue type has raw value zero. Its direct execution
    // remains a plugin compatibility contract, without naming a deprecated API.
    TrackingContext *legacy = [[TrackingContext alloc] initWithConcurrencyType:(NSManagedObjectContextConcurrencyType)0];
    N2ManagedObjectContextPerformAndWait(legacy, ^{ check(!legacy.performing); ran++; });
    check(ran == 4 && legacy.calls == 0);
    [legacy release];
    N2ManagedObjectContextPerformAndWait(nil, ^{ ran++; });
    check(ran == 5);
    puts("ok: production queue helper returns before propagating the original exception and remains usable");
} return 0; }
'''.replace('HELPER', helper)
    with tempfile.TemporaryDirectory(prefix='horos-browser-queue-') as folder:
        path = Path(folder)
        (path / 'check.m').write_text(driver)
        built = subprocess.run(['xcrun', 'clang', '-DNDEBUG', '-fno-objc-arc', '-framework', 'Foundation',
                                '-framework', 'CoreData', str(path / 'check.m'), '-o', str(path / 'check')],
                               capture_output=True, text=True)
        if built.returncode:
            failures.append('production queue helper does not compile: ' + built.stderr[-2000:])
            return
        # DNDEBUG only excludes the production helper's diagnostic logging.
        # The driver uses check(), which stays enabled despite that flag.
        run = subprocess.run([str(path / 'check')], capture_output=True, text=True, timeout=30)
        if run.returncode:
            failures.append('production queue helper failed: ' + run.stdout[-1000:] + run.stderr[-2000:])


# 1. Unlocked before an exception goes on.
LOCKED = (
    ('Horos/Sources/BrowserController+Plugins.swift', 'relatedStudiesForStudy:', 'context?'),
    ('Horos/Sources/BrowserController+DatabaseDragExport.swift', 'isUsingExternalViewer:', 'self.database?'),
)
for path, selector, lock in LOCKED:
    body = method(path, selector)
    if not body:
        continue
    queue = re.search(r'N2ManagedObjectContextPerformAndWait\(([^\n]+)\)\s*\{', body)
    if queue:
        helper = queue_helper()
        check_queue_helper(helper)
        opening = body.index('{', queue.start())
        end = closing(body, opening)
        queued, rest = body[opening:end + 1], body[end + 1:]
        expected_context = 'context' if selector == 'relatedStudiesForStudy:' else 'self.database?.managedObjectContext'
        if queue.group(1) != expected_context:
            failures.append('-%s uses the wrong managed context queue' % selector)
        if '.lock()' in body or '.unlock()' in body:
            failures.append('-%s still uses the deprecated lock API in its queued operation' % selector)
        if selector == 'relatedStudiesForStudy:':
            captured = re.search(r'(\w+) = objcTry \{', queued)
            if not captured or not re.search(r'if let %s \{ %s\.raise\(\) \}' % (captured.group(1), captured.group(1)), rest):
                failures.append('-relatedStudiesForStudy: does not rethrow its captured exception after leaving the queue')
        else:
            captured = re.search(r'let (\w+) = objcTry \{', queued)
            if not captured or not re.search(r'if let %s \{ %s\.raise\(\) \}' % (captured.group(1), captured.group(1)), queued):
                failures.append('-isUsingExternalViewer: does not propagate its captured exception to the queue helper')
        continue
    at = body.find(lock + '.lock()')
    if at < 0:
        failures.append('-%s no longer locks %s; this test needs a new look' % (selector, lock))
        continue
    after = body[at + len(lock + '.lock()'):]
    guarded = re.search(r'let (\w+) = objcTry \{', after)
    before = statements(after[:guarded.start()] if guarded else after)
    if not guarded or any(not re.fullmatch(r'var \w+: [\w.]+\? = nil', line) for line in before):
        failures.append('-%s runs %r with %s locked, outside an objcTry' % (selector, (before or ['?'])[0], lock))
        continue
    end = closing(after, after.index('{', guarded.start()))
    rest = statements(after[end + 1:])
    expected = [lock + '.unlock()', 'if let %s { %s.raise() }' % (guarded.group(1), guarded.group(1))]
    if rest[:2] != expected:
        failures.append('-%s does not unlock %s and then raise the exception again: %r' % (selector, lock, rest[:2]))

if not revision and not failures:
    run_queue_helper(queue_helper())

# 2. No row -1.
path = 'Horos/Sources/BrowserController+AlbumsTableView.swift'
tip = method(path, 'tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:')
if tip and not re.search(r'row >= 0\b.*row < \w+\.count', tip):
    failures.append('the comparative table\'s tool tip reads its studies at a row it does not bound, -1 outside the rows')
double = method(path, 'doubleClickComparativeStudy:')
if double:
    if 'object(at: horos_comparativeTable?.selectedRow' in double:
        failures.append('-doubleClickComparativeStudy: reads its studies at the selected row, -1 when none is')
    elif not re.search(r'row >= 0 && row < \(?\w+\??\.count', double):
        failures.append('-doubleClickComparativeStudy: does not bound the selected row by the studies')

# 3. The export's columns stay in place.
export = method('Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift', 'exportDBListOnlySelected:')
if export:
    tries = [m.start() for m in re.finditer(r'objcTry\(\{', export)]
    if len(tries) != 2:
        failures.append('-exportDBListOnlySelected: has %d objcTry, not the header\'s and the column\'s; '
                        'this test needs a new look' % len(tries))
    for number, start in enumerate(tries, 1):
        closure = export[start:closing(export, export.index('{', start)) + 1]
        if 'i += 1' in closure or 'string.append("")' in closure:
            failures.append('-exportDBListOnlySelected: counts the column or writes its tab inside objcTry #%d, '
                            'so a column that raises shifts the next ones' % number)
    if export.count('i += 1') != 2:
        failures.append('-exportDBListOnlySelected: counts its columns %d times, not once in each loop'
                        % export.count('i += 1'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the browser leaves its queue/lock before an exception goes on, bounds the comparative rows, '
      'and keeps its export columns in place')
