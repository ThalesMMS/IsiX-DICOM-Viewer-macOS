#!/usr/bin/env python3
"""Check that the "unknown plugin" diagnostic does not raise, and cannot skip launch.

`+[PluginManager startProtectForCrashWithFilter:]` matches a filter against the
loaded plugin bundles by `-class`, and its diagnostic for the no-match case
asked the filter for `-principalClass`, which belongs to NSBundle. Every filter
without a matching bundle therefore raised NSInvalidArgumentException out of
`-[AppController applicationWillFinishLaunching:]`, whose remaining statements
are DCMTK, the store SCP, the database and browser classes, the Web Portal, the
Bonjour publisher and the XML-RPC interface. The application stayed on screen
with none of them initialised.

The first check compiles the shipped body of the method and calls it with a
filter that matches nothing. PluginManager is Swift since #720: the method is
compiled with the Objective-C messaging helpers of PluginManager.swift, and a
raised NSException is caught by HorosObjCException and reported. The second requires the launch-time call into the
plugins to be inside a handler, so a third-party plugin cannot take the rest of
the sequence with it. AppController is Swift since #830: the handler is a
`HorosObjCException.perform` closure with a `catch` after it, as the Swift
spelling of @try/@catch.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402


def source(name, path=None):
    path = path or 'Horos/Sources/' + name
    return (subprocess.check_output(['git', 'show', sys.argv[1] + ':' + path])
            if len(sys.argv) > 1 else (root / path).read_bytes()).decode('utf-8' if path.endswith('.swift') else 'latin1')


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it,
    outside comments and string literals."""
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.index('*/', index) + 2
            continue
        if text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == '\\' else 1
        elif text[index] == '{':
            depth, opened = depth + 1, True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[at:index + 1]
        index += 1
    return ''


# PluginManager is Swift since #720: the shipped method is compiled with the
# helpers it calls, the Objective-C messaging of PluginManager.swift.
plugins = source('PluginManager.swift', str(source_path('PluginManager').relative_to(root)))
method = swift_block(plugins, plugins.index('@objc(startProtectForCrashWithFilter:)'))
helpers = swift_block(plugins, plugins.index('fileprivate enum ObjC {'))
registry = swift_block(plugins, plugins.index('fileprivate enum Registry {'))

code = r'''
import AppKit

REGISTRY

HELPERS

@objc(PluginManager) final class PluginManager: NSObject {
    @objc(startProtectForCrashWithPath:)
    class func startProtectForCrash(withPath path: String!) {}

METHOD
}

// A filter is a plugin's filter instance, not its bundle: it answers -class and
// nothing else the diagnostic might reach for.
@objc(ROIEnhancementFilter) final class ROIEnhancementFilter: NSObject {}

func attempt(_ what: String) -> Bool {
    do {
        try HorosObjCException.perform {
            PluginManager.startProtectForCrash(withFilter: ROIEnhancementFilter())
        }
        return true
    } catch {
        let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        FileHandle.standardError.write("FAIL: the diagnostic raised \(what)\(e?.name.rawValue ?? ""): \(e?.reason ?? "")\n".data(using: .utf8)!)
        return false
    }
}

// No bundle matches, which is the path that used to raise.
Registry.pluginsBundleDictionnary = NSMutableDictionary()
if !attempt("") { exit(1) }
// A real bundle in the dictionary must still be matched by principal class.
Registry.pluginsBundleDictionnary = NSMutableDictionary(object: Bundle.main, forKey: "main" as NSString)
if !attempt("with a bundle present ") { exit(1) }
print("PASS: the unknown-plugin diagnostic returns instead of raising")
'''.replace('REGISTRY', registry).replace('HELPERS', helpers).replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='horos-plugin-crash-guard-') as name:
    directory = Path(name)
    (directory / 'main.swift').write_text(code)
    (directory / 'bridge.h').write_text('#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(directory / 'exception.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'CrashGuard', '-import-objc-header', str(directory / 'bridge.h'),
                    '-Xcc', '-I' + str(root / 'Horos/Sources'), str(directory / 'main.swift'), str(directory / 'exception.o'),
                    '-o', str(directory / 'test')], check=True)
    subprocess.run([str(directory / 'test')], check=True)

# The launch sequence must survive a plugin that raises anyway. AppController is
# Swift since #830: @try is `try HorosObjCException.perform { ... }` and @catch
# the `catch` that follows it.
controller = source('AppController.swift', str(source_path('AppController').relative_to(root)))
method = swift_block(controller, controller.index('@objc(applicationWillFinishLaunching:)'))
call = method.index('PluginManager.setMenus(')
before = method[:call]
# The call has to sit inside a HorosObjCException.perform closure whose catch
# comes after it, and the statements that follow have to be outside that handler.
opened = before.rindex('HorosObjCException.perform') if 'HorosObjCException.perform' in before else -1
if opened < 0:
    print('FAIL: the launch-time PluginManager call is not inside a HorosObjCException.perform', file=sys.stderr)
    raise SystemExit(1)
if call >= opened + len(swift_block(method, opened)):
    print('FAIL: the nearest HorosObjCException.perform before the launch-time PluginManager call is already closed',
          file=sys.stderr)
    raise SystemExit(1)
after = method[call:]
if not re.search(r'\bcatch\b[^{]*\{[^}]*\}', after, re.S):
    print('FAIL: the launch-time PluginManager call has no handler after it', file=sys.stderr)
    raise SystemExit(1)
handler = re.search(r'\bcatch\b', after).start()
# initDCMTK stayed in Objective-C++ (AppController+CAPI.m): Swift calls it as
# AppControllerCAPIInitDCMTK(self).
for required in ('AppControllerCAPIInitDCMTK', 'restartSTORESCP', 'httpXMLRPCServer'):
    if required not in after[handler:]:
        print('FAIL: %s no longer follows the handler; the check has drifted' % required,
              file=sys.stderr)
        raise SystemExit(1)
print('PASS: the launch-time plugin menu setup is handled and the DICOM stack follows it')
