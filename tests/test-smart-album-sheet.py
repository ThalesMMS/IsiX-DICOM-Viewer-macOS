#!/usr/bin/env python3
"""The smart album sheet closes on Esc and keeps its buttons clear (#743).

Esc typed in the album name field never reached the Cancel button: the field
editor turns it into -cancelOperation:, which NSTextView answers with word
completion. The controller now handles that command as the field's delegate.
This runs the controller's real -control:textView:doCommandBySelector: and
-cancelOperation: against a stub that records -cancelAction:, and checks that
the content-criterion checkbox is laid out by constraints, not frames.

SmartWindowController is Swift since #714: the handlers are compiled from its
Swift source into the stub, and the assertions read the Swift spelling.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
source = sources.source_text('SmartWindowController')
failures = []


def method(signature):
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start) + 7]


handlers = method('    public override func cancelOperation(_ sender: Any?) {') + \
    method('    public func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {')
program = r'''
import AppKit
final class Sheet: NSResponder, NSTextFieldDelegate {
    var cancelled = 0
    func cancelAction(_ sender: Any!) { cancelled += 1 }
HANDLERS
}
func fail(_ message: String) -> Never { print(message); exit(1) }
let sheet = Sheet()
let field = NSTextField()
// The selector a field's delegate is sent: the Swift method must answer it.
if !sheet.responds(to: #selector(NSTextFieldDelegate.control(_:textView:doCommandBy:))) {
    fail("FAIL: the handler is not -control:textView:doCommandBySelector:")
}
var handled = sheet.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
if !handled || sheet.cancelled != 1 { fail("FAIL: Esc in the name field does not cancel the sheet") }
handled = sheet.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
if handled || sheet.cancelled != 1 { fail("FAIL: other commands in the name field are taken over") }
(sheet as NSResponder).cancelOperation(nil)
if sheet.cancelled != 2 { fail("FAIL: Esc from a control does not cancel the sheet") }
print("PASS: Esc cancels the sheet from the name field and from its controls")
'''.replace('HANDLERS', handlers)

with tempfile.TemporaryDirectory() as folder:
    path = Path(folder)
    (path / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(path / 'main.swift'), '-o', str(path / 'probe')],
                           capture_output=True, text=True)
    if built.returncode:
        failures.append('the Esc handlers do not compile:\n' + built.stderr[-1500:])
    else:
        run = subprocess.run([str(path / 'probe')], capture_output=True, text=True, timeout=30)
        print(run.stdout.strip())
        if run.returncode:
            failures.append(run.stdout.strip())

if 'self.nameField?.delegate = self' not in source or not re.search(r'class SmartWindowController\b[^{]*\bNSTextFieldDelegate\b', source):
    failures.append('the name field has no delegate to hand Esc to the sheet')
installer = method('    @objc func installContentCriterionCheckbox() {')
if 'translatesAutoresizingMaskIntoConstraints = false' not in installer or 'NSLayoutConstraint.activate' not in installer:
    failures.append('the checkbox is not laid out by constraints')
if re.search(r'f\.origin\.y \+= ', installer):
    failures.append('the checkbox installer still moves frames by hand')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
