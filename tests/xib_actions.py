"""Whether the actions of a nib have an implementation.

A nib action whose target does not implement it does nothing, or worse: a
sheet whose buttons send it can be opened and never closed. Each
<action selector target> of a xib is resolved to the class of its target - the
File's Owner, a custom view or object, or an AppKit object (a window, a
control) - and looked up:

- in the app's classes, statically, in their Swift (members exposed to
  Objective-C: @objc, @IBAction, override, dynamic, or any member of an
  @objc @implementation extension) and Objective-C sources (@interface and
  @implementation), up their superclasses to the first AppKit one;
- in AppKit, at run time, with -instancesRespondToSelector: of a small
  program compiled here.

An action sent to the first responder has no class to start from: the
responder chain decides at run time who answers it. It counts as implemented
when some class of the app declares it to Objective-C, or when NSApplication,
NSWindow or NSView (the AppKit links of the chain) answers it.
"""
import re
import subprocess
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'


def block(text, start):
    """The text from `start` to the brace that closes the first one after it."""
    brace = text.index('{', start)
    depth = 0
    for index in range(brace, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[brace:index + 1]
    return text[brace:]


SWIFT_FILES = {path: path.read_text(encoding='utf-8', errors='replace') for path in SOURCES.rglob('*.swift')}
OBJC_FILES = {path: path.read_text(encoding='latin-1')
              for pattern in ('*.h', '*.m', '*.mm') for path in SOURCES.rglob(pattern)}


def swift_selector(declaration):
    """The Objective-C selector of a Swift func declaration `name(params`."""
    match = re.match(r'func\s+(\w+)\s*\(([^)]*)\)', declaration)
    if not match:
        return None
    name, parameters = match.group(1), match.group(2).strip()
    if not parameters:
        return name
    labels = []
    for parameter in parameters.split(','):
        words = parameter.split(':')[0].split()
        labels.append(words[0] if words else '_')
    first = labels[0]
    selector = name + ('' if first == '_' else 'With' + first[0].upper() + first[1:]) + ':'
    return selector + ''.join(('' if label == '_' else label) + ':' for label in labels[1:])


def class_info(name):
    """The selectors the app's sources give class `name`, and its superclass."""
    selectors, superclass = set(), None
    declaration = re.compile(r'(@objc[^\n]*\s+)?(?:(?:final|open|public)\s+)*(class|extension)\s+%s\b([^{]*)' % re.escape(name))
    for text in SWIFT_FILES.values():
        for match in declaration.finditer(text):
            header = match.group(3)
            if match.group(2) == 'class':
                inherited = re.match(r'\s*:\s*(\w+)', header)
                superclass = superclass or (inherited.group(1) if inherited else None)
            exposed_all = bool(match.group(1) and '@implementation' in match.group(1))
            body = block(text, match.end())
            for member in re.finditer(r'((?:@\w+(?:\([^)]*\))?\s+|(?:override|dynamic|public|private|fileprivate|'
                                      r'internal|final|nonisolated|static|class)\s+)*)(func\s+\w+\s*\([^)]*\))', body):
                attributes, func = member.group(1), member.group(2)
                explicit = re.search(r'@objc\(([^)]+)\)', attributes)
                if explicit:
                    selectors.add(explicit.group(1))
                elif exposed_all or re.search(r'@objc|@IBAction|override|dynamic', attributes):
                    selectors.add(swift_selector(func))
    for text in OBJC_FILES.values():
        for match in re.finditer(r'@(interface|implementation)\s+%s\b\s*(:\s*(\w+))?[^\n]*\n(.*?)@end' % re.escape(name),
                                 text, flags=re.S):
            if match.group(3):
                superclass = superclass or match.group(3)
            for method in re.finditer(r'^\s*-\s*\([^)]*\)\s*(\w+)(\s*:)?', match.group(4), flags=re.M):
                selectors.add(method.group(1) + (':' if method.group(2) else ''))
    return selectors, superclass


APPKIT_CHECK = r'''
#import <AppKit/AppKit.h>
int main(int argc, char **argv)
{
    @autoreleasepool {
        for (int i = 1; i + 1 < argc; i += 2) {
            Class cls = NSClassFromString([NSString stringWithUTF8String:argv[i]]);
            SEL selector = NSSelectorFromString([NSString stringWithUTF8String:argv[i + 1]]);
            printf("%s %s %d\n", argv[i], argv[i + 1], cls && [cls instancesRespondToSelector:selector]);
        }
    }
    return 0;
}
'''


def appkit_answers(pairs, folder):
    if not pairs:
        return {}
    program = folder / 'appkit'
    if not program.exists():
        (folder / 'appkit.m').write_text(APPKIT_CHECK)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', str(folder / 'appkit.m'), '-framework', 'AppKit', '-o',
                        str(program)], check=True, capture_output=True, timeout=300)
    run = subprocess.run([str(program), *[part for pair in sorted(pairs) for part in pair]], capture_output=True,
                         text=True, timeout=60, check=True)
    return {(cls, selector): answer == '1' for cls, selector, answer in (line.split() for line in run.stdout.splitlines())}


def nib_actions(text):
    """(selector, class of the target) of every action of the nib."""
    root = ElementTree.fromstring(text)
    classes = {}
    for element in root.iter():
        identifier = element.get('id')
        if identifier:
            classes[identifier] = element.get('customClass') or 'NS' + element.tag[0].upper() + element.tag[1:]
    actions = []
    for action in root.iter('action'):
        target = action.get('target')
        if target == '-1':
            cls = 'FirstResponder'
        else:
            cls = classes.get(target, '?')
        actions.append((action.get('selector'), cls))
    return actions


_resolved = {}
RESPONDER_CHAIN = ('NSApplication', 'NSWindow', 'NSView')


def app_declares(selector):
    """Whether some class of the app's sources declares `selector` to Objective-C."""
    for text in SWIFT_FILES.values():
        if '@objc(%s)' % selector in text:
            return True
        for member in re.finditer(r'((?:@\w+(?:\([^)]*\))?\s+|(?:override|dynamic|public|final|nonisolated)\s+)*)'
                                  r'(func\s+\w+\s*\([^)]*\))', text):
            if re.search(r'@objc\b(?!\()|@IBAction|override|dynamic', member.group(1)) \
                    and swift_selector(member.group(2)) == selector:
                return True
    name = selector.split(':')[0]
    objc = re.compile(r'^\s*-\s*\([^)]*\)\s*%s%s' % (re.escape(name), r'\s*:' if ':' in selector else r'\s*[;{]'), re.M)
    return any(objc.search(text) for text in OBJC_FILES.values())


def missing_actions(actions, folder):
    """The (selector, class) of `actions` that nothing implements; `folder` holds the AppKit probe."""
    pending, appkit = [], set()
    for selector, cls in set(actions):
        current, found = cls, False
        while current and not current.startswith('NS') and current != 'FirstResponder':
            if current not in _resolved:
                _resolved[current] = class_info(current)
            selectors, superclass = _resolved[current]
            if selector in selectors:
                found = True
                break
            current = superclass
        if found:
            continue
        if current == 'FirstResponder':
            if not app_declares(selector):
                appkit.update((link, selector) for link in RESPONDER_CHAIN)
                pending.append((selector, cls, RESPONDER_CHAIN))
            continue
        if current and current.startswith('NS'):
            appkit.add((current, selector))
            pending.append((selector, cls, current))
        else:
            pending.append((selector, cls, None))
    answers = appkit_answers(appkit, folder)

    def answered(selector, base):
        links = base if isinstance(base, tuple) else (base,) if base else ()
        return any(answers.get((link, selector)) for link in links)
    return sorted((selector, cls) for selector, cls, base in pending if not answered(selector, base))
