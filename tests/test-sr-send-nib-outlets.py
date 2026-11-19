#!/usr/bin/env python3
"""The outlets SR.xib and Send.xib connect are outlets of their owners.

A nib connects an outlet by name: the loader sets the value of that key on
the File's Owner. Two connections named a key that is no outlet:

- SR.xib connected `decimate` and `smooth` to two text fields of the settings
  sheet. In the surface rendering controller those names are numbers, the
  values the fields are bound to: the setter of a number received the pointer
  of a field, and the number held part of it until the sheet opened;
- Send.xib connected `sendSCU`, a key its controller does not have, which the
  loader reported and dropped.

Each of the ten copies of both nibs is compiled and loaded with an owner that
records every key the loader sets and the class of the value. A key that
receives a view, a cell or a window must be declared by the controller as a
variable of an AppKit class (or be `window`, or have a setter of its own).
The ten copies connect the same outlets.

The controller still reaches the two fields of the sheet: the function that
finds a text field by the key its value is bound to, compiled from
SRController.swift as it is, finds one for `decimate` and another for
`smooth` in the settings sheet of every copy.

`<git revision>` as an optional argument reads the nibs and the controllers
from that revision: that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
NIBS = {'SR': 'SRController', 'Send': 'SendController'}
failures = []


def tracked(pattern):
    """The paths of the tree, or of the revision, that match `pattern`."""
    if revision is None:
        return sorted(str(path.relative_to(root)) for path in root.glob(pattern))
    listed = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision, '--',
                                      str(Path(pattern).parent.parent if '*.lproj' in pattern else Path(pattern).parent)],
                                     text=True).splitlines()
    return sorted(path for path in listed if Path(path).match(pattern))


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'], stderr=subprocess.DEVNULL)


def block(text, start, what):
    """The declaration that begins at `start`, to its closing brace."""
    begin = text.index(start)
    depth = 0
    for index in range(text.index('{', begin), len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[begin:index + 1]
    sys.exit(f'{what}: the declaration does not end')


def is_outlet(key, source):
    """Whether the controller declares `key` as a variable of an AppKit class."""
    if key == 'window':
        return True
    if f'@objc(set{key[0].upper()}{key[1:]}:)' in source:
        return True
    return re.search(r'\bvar (?:[^\n=]*[ ,])?%s: NS\w+[?!]' % re.escape(key), source) is not None


sources = {}
for nib, controller in NIBS.items():
    paths = tracked(f'Horos/Sources/{controller}*.swift')
    sources[nib] = '\n'.join(read(path).decode('utf-8') for path in paths)
    if f'class {controller}' not in sources[nib]:
        sys.exit(f'{controller} was not found in {paths}')
finder = block(sources['SR'], 'private static func textField(in view: NSView?, boundTo keyPath: String)', 'textField(in:boundTo:)')

MAIN = r'''
import AppKit

/// The File's Owner: it records each key the loader sets and what it is given.
/// The loader connects an outlet through the setter of its key, so the owner
/// is given a setter for each key a copy of the nib connects.
final class Owner: NSObject {
    var given: [(key: String, value: AnyObject?)] = []
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}

    static func answer(_ keys: [String]) {
        for key in keys {
            let setter: @convention(block) (Owner, AnyObject?) -> Void = { owner, value in owner.given.append((key, value)) }
            class_addMethod(Owner.self, NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):"),
                            imp_implementationWithBlock(setter), "v@:@")
        }
    }
}

enum Sheet {
    FINDER
}
extension Sheet {
    static func field(in window: NSWindow?, boundTo key: String) -> NSTextField? {
        textField(in: window?.contentView, boundTo: key)
    }
}

@main struct Test {
    @MainActor static func main() {
        _ = NSApplication.shared
        // name of the nib, the keys its copies connect, then pairs of
        // language and compiled nib
        var arguments = Array(CommandLine.arguments.dropFirst())
        let name = arguments.removeFirst()
        Owner.answer(arguments.removeFirst().split(separator: ",").map(String.init))
        while arguments.count >= 2 {
            let language = arguments.removeFirst(), path = arguments.removeFirst()
            let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
            let owner = Owner()
            var top: NSArray?
            guard nib.instantiate(withOwner: owner, topLevelObjects: &top) else { print("\(language)\tFAILED"); continue }
            for (key, value) in owner.given {
                let kind = value is NSResponder || value is NSCell ? "object" : "value"
                print("\(language)\tset\t\(key)\t\(kind)")
            }
            guard name == "SR" else { continue }
            let sheet = owner.given.first { $0.key == "SRSettingsWindow" }?.value as? NSWindow
            for key in ["decimate", "smooth"] {
                let field = Sheet.field(in: sheet, boundTo: key)
                print("\(language)\tfield\t\(key)\t\(field.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? "none")")
            }
        }
    }
}
'''.replace('FINDER', finder)

with tempfile.TemporaryDirectory(prefix='horos-sr-send-outlets-') as folder:
    work = Path(folder)
    (work / 'Test.swift').write_text(MAIN, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-suppress-warnings',
                            str(work / 'Test.swift'), '-o', str(work / 'test')], capture_output=True, text=True)
    if built.returncode:
        sys.exit(f'FAIL: the finder of the bound fields did not compile\n{built.stdout}{built.stderr}')

    for nib, controller in NIBS.items():
        copies = tracked(f'Horos/Resources/*.lproj/{nib}.xib')
        if len(copies) != 10:
            failures.append(f'{nib}.xib: {len(copies)} copies, not ten')
        arguments = [nib]
        declared = {}
        for copy in copies:
            language = Path(copy).parent.name
            data = read(copy)
            owner = ET.fromstring(data).find('.//customObject[@id="-2"]')
            if owner is None or owner.get('customClass') != controller:
                failures.append(f'{copy}: the File\'s Owner is not a {controller}')
                continue
            declared[language] = sorted((outlet.get('property'), outlet.get('destination')) for outlet in owner.iter('outlet'))
            xib = work / f'{nib}-{language}.xib'
            xib.write_bytes(data)
            compiled = work / f'{nib}-{language}.nib'
            result = subprocess.run(['xcrun', 'ibtool', '--errors', '--compile', str(compiled), str(xib)],
                                    capture_output=True, text=True)
            if result.returncode or not compiled.exists():
                failures.append(f'{copy}: did not compile\n{result.stdout}{result.stderr}')
                continue
            arguments += [language, str(compiled / 'keyedobjects.nib' if compiled.is_dir() else compiled)]
        english = declared.get('en.lproj')
        for language, outlets in declared.items():
            if outlets != english:
                failures.append(f'{nib}.xib: {language} connects other outlets than the English copy: '
                                f'{sorted(set(outlets) ^ set(english or []))}')

        # The classes of the application are not here: the loader says so for
        # each and goes on with the AppKit class, which is all this reads.
        keys = sorted({key for outlets in declared.values() for key, _ in outlets})
        run = subprocess.run([str(work / 'test'), nib, ','.join(keys), *arguments[1:]], capture_output=True, text=True)
        if run.returncode:
            failures.append(f'{nib}.xib: the copies did not load\n{run.stderr[-2000:]}')
            continue
        loaded, fields = {}, {}
        for line in run.stdout.splitlines():
            language, what, *rest = line.split('\t')
            if what == 'FAILED':
                failures.append(f'{nib}.xib: {language} did not load')
            elif what == 'set':
                loaded.setdefault(language, []).append(tuple(rest))
            elif what == 'field':
                fields.setdefault(language, {})[rest[0]] = rest[1]
        for language in declared:
            objects = sorted({key for key, kind in loaded.get(language, []) if kind == 'object'})
            if sorted({key for key, _ in declared[language]}) != objects:
                failures.append(f'{nib}.xib: {language}: the loader set {objects}, and the nib connects '
                                f'{sorted({key for key, _ in declared[language]})}')
            for key in objects:
                if not is_outlet(key, sources[nib]):
                    failures.append(f'{nib}.xib: {language}: connects `{key}`, which {controller} does not declare as an outlet')
            if nib == 'SR':
                found = fields.get(language, {})
                if 'none' in (found.get('decimate', 'none'), found.get('smooth', 'none')) or found['decimate'] == found['smooth']:
                    failures.append(f'SR.xib: {language}: the fields bound to decimate and smooth were not found: {found}')
        print(f'{nib}.xib: {len(declared)} copies loaded, {len(english or [])} outlets each')

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: every outlet SR.xib and Send.xib connect is an outlet of its controller, and the sheet\'s two bound fields are found')
