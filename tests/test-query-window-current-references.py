#!/usr/bin/env python3
"""The query window leaves no reference to itself behind when it goes.

The class keeps the two current windows, the manual and the automatic one,
and the browser keeps a pointer to the manual one. The former two were plain
pointers, set to nil when the window was freed. They are weak references now,
and a weak reference to an object already reads nil while that object is being
freed: nothing has to clear them, and a comparison with `self` there is never
true. The browser's pointer is not retained and not weak, so the window must
still clear it.

Checked in QueryController.swift: the two current windows are weak; the
deinit does not read them; the deinit clears the browser's pointer, and that
pointer is still an unretained one. A program shows what the first two rest
on: a weak class reference to a window controller reads nil in its deinit,
and an unretained one still holds it.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(relative):
    if revision is None:
        return (root / relative).read_text(encoding='utf-8')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


text = read('Horos/Sources/QueryController.swift')
for name in ('currentWindow', 'currentAutomaticWindow'):
    if not re.search(r'static weak var %s: QueryController\?' % name, text):
        failures.append(f'{name} is not a weak class reference: the window must clear it when it goes')
begin = text.index('isolated deinit {')
depth, end = 0, begin
for end in range(text.index('{', begin), len(text)):
    depth += (text[end] == '{') - (text[end] == '}')
    if depth == 0:
        break
deinit = text[begin:end]
for name in ('currentWindow', 'currentAutomaticWindow'):
    if re.search(r'\b%s\b' % name, deinit):
        failures.append(f'the deinit reads {name}, a weak reference that is nil by then: the code does nothing')
if not re.search(r'_queryController === self \{ browser\._queryController = nil \}', deinit):
    failures.append('the deinit no longer clears the pointer the browser keeps to the window')
if not re.search(r'unowned\(unsafe\) var [^\n]*\b_queryController: QueryController\?', read('Horos/Sources/BrowserController.swift')):
    failures.append('the pointer the browser keeps to the window is no longer an unretained one: review what the deinit does with it')

PROGRAM = r'''
import AppKit

final class Window: NSWindowController {
    static weak var current: Window?
    nonisolated(unsafe) static unowned(unsafe) var pointer: Window?
    nonisolated(unsafe) static var weakWasNil = false, pointerWasSelf = false
    isolated deinit {
        Window.weakWasNil = Window.current == nil
        Window.pointerWasSelf = Window.pointer === self
        Window.pointer = nil
    }
}

@main struct Test {
    @MainActor static func main() {
        autoreleasepool {
            let window = Window(window: nil)
            Window.current = window
            Window.pointer = window
        }
        print(Window.weakWasNil && Window.pointerWasSelf && Window.current == nil ? "as expected" :
              "weak nil in deinit: \(Window.weakWasNil), pointer was self: \(Window.pointerWasSelf)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-query-window-references-') as folder:
    work = Path(folder)
    (work / 'Test.swift').write_text(PROGRAM, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(work / 'Test.swift'),
                            '-o', str(work / 'test')], capture_output=True, text=True)
    if built.returncode:
        sys.exit(f'FAIL: the program did not compile\n{built.stdout}{built.stderr}')
    answer = subprocess.run([str(work / 'test')], capture_output=True, text=True).stdout.strip()
    if answer != 'as expected':
        failures.append(f'a weak reference no longer reads nil in the deinit of its object ({answer}): the deinit must clear the two')

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: the current query windows are weak and clear themselves; the deinit clears the browser\'s pointer')
