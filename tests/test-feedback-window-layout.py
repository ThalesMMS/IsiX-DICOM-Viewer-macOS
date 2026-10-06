#!/usr/bin/env python3
"""The feedback window is laid out from its content and never asks for Contacts.

The window comes from the provider's nibs, one per localization, with fixed
frames and springs from an older system. Hiding the details shrank the tab view
to no height and its pages were drawn over the rows around it; translated
headings were cut. The host controller lays the controls out with constraints
and hides the tab view instead. It offered the user's own addresses from the
contact card, which asks for Contacts access on the main thread; it now offers
"anonymous" and the address last used.

The controller selected by the real build is compiled with the provider's
sources against every localized nib the framework ships, in a disposable
bundle. The window is loaded and laid out but never shown. In each localization,
with the details hidden and shown, every visible control must lie inside the
window, no two may overlap, the texts must fit their fields, the buttons their
titles, and the page of the tab view must stay below its tabs.

--controller-source runs the same checks on another revision of the controller
(a negative control). Its reading of the contact card is replaced by no card
before it is compiled, so that the check itself never asks for Contacts.
"""
from pathlib import Path
import argparse
import importlib.util
import plistlib
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--controller-source', type=Path,
                    help='controller to check instead of the selected one, e.g. an earlier revision')
parser.add_argument('--verbose', action='store_true', help='print the window and tab sizes of each run')
arguments = parser.parse_args()

spec = importlib.util.spec_from_file_location('feedback_prepare', root / 'Horos/Scripts/FeedbackReporter/prepare.py')
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


# No Contacts: not in the host's reporter sources, not linked by the application
# or the framework, and no usage description left for a permission never asked.
CONTACTS = re.compile(r'ABAddressBook|ABPerson|ABMultiValue|ABMutableMultiValue|kABEmailProperty|'
                      r'AddressBook/AddressBook\.h|Contacts/Contacts\.h|CNContact|@import\s+(Contacts|AddressBook)')
host_sources = sorted((root / 'Horos/FeedbackReporter').glob('*.m'))
controller_source = arguments.controller_source or root / 'Horos/FeedbackReporter/FRFeedbackController.m'
for source in [path for path in host_sources if path.name != 'FRFeedbackController.m'] + [controller_source]:
    found = CONTACTS.search(source.read_text(encoding='utf-8'))
    require(found is None, '%s reads Contacts (%s)' % (source.name, found and found.group(0)))
if arguments.controller_source is None:
    for project in ('Horos.xcodeproj/project.pbxproj', 'Horos/Scripts/FeedbackReporter/Framework.project'):
        text = (root / project).read_text(encoding='utf-8')
        require('AddressBook.framework' not in text and 'Contacts.framework' not in text,
                project + ' links a Contacts framework')
    information = plistlib.loads((root / 'Horos/Info.plist').read_bytes())
    require('NSContactsUsageDescription' not in information, 'Info.plist still describes a Contacts use')

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import "FRFeedbackController.h"

static NSMutableArray<NSString *> *failures;
static NSString *language;
static void fail(NSString *state, NSString *message) { [failures addObject:[NSString stringWithFormat:@"%@, %@: %@", language, state, message]]; }

@interface FRFeedbackController (Probe)
- (void) insertTabViewItemInCorrectOrder:(NSTabViewItem *)item;
@end

static NSString *nameOf(NSView *view) {
    if ([view respondsToSelector:@selector(title)] && [(id)view title].length) return [NSString stringWithFormat:@"%@ \"%@\"", view.className, [(id)view title]];
    if ([view isKindOfClass:NSTextField.class]) return [NSString stringWithFormat:@"%@ \"%@\"", view.className, [(NSTextField *)view stringValue]];
    return view.className;
}

static BOOL inside(NSRect inner, NSRect outer) {
    return NSMinX(inner) >= NSMinX(outer) - 0.5 && NSMinY(inner) >= NSMinY(outer) - 0.5 &&
           NSMaxX(inner) <= NSMaxX(outer) + 0.5 && NSMaxY(inner) <= NSMaxY(outer) + 0.5;
}

static void check(FRFeedbackController *controller, NSString *state, BOOL detailsExpected, NSSize tabMinimum) {
    NSWindow *window = [controller window];
    NSView *content = [window contentView];
    [content layoutSubtreeIfNeeded];
    NSRect bounds = [content bounds];
    NSTabView *tabView = [controller valueForKey:@"tabView"];
    printf("INFO: %s, %s: content %s, tab view %s, six tabs need %s\n", language.UTF8String, state.UTF8String,
           NSStringFromSize(bounds.size).UTF8String, NSStringFromRect([tabView frame]).UTF8String, NSStringFromSize(tabMinimum).UTF8String);
    if (!NSEqualSizes([window contentRectForFrameRect:[window frame]].size, bounds.size))
        fail(state, @"the content view does not fill the window");
    NSMutableArray<NSView *> *visible = [NSMutableArray array];
    for (NSView *view in [content subviews]) {
        if ([view isHidden]) continue;
        [visible addObject:view];
        NSRect frame = [view frame];
        if (NSIsEmptyRect(frame)) { fail(state, [nameOf(view) stringByAppendingString:@" has no size"]); continue; }
        if (!inside(frame, bounds))
            fail(state, [NSString stringWithFormat:@"%@ %@ is not inside the window %@", nameOf(view), NSStringFromRect(frame), NSStringFromRect(bounds)]);
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField *field = (NSTextField *)view;
            NSSize needed = [[field cell] cellSizeForBounds:NSMakeRect(0, 0, NSWidth(frame), CGFLOAT_MAX)];
            if (needed.height > NSHeight(frame) + 0.5 || needed.width > NSWidth(frame) + 0.5)
                fail(state, [NSString stringWithFormat:@"%@ needs %@ and has %@", nameOf(view), NSStringFromSize(needed), NSStringFromSize(frame.size)]);
        } else if ([view isKindOfClass:NSButton.class]) {
            NSSize needed = [view fittingSize];
            if (needed.width > NSWidth(frame) + 0.5)
                fail(state, [NSString stringWithFormat:@"%@ needs %@ and has %@", nameOf(view), NSStringFromSize(needed), NSStringFromSize(frame.size)]);
        }
    }
    for (NSView *view in visible)
        if ([view hasAmbiguousLayout]) fail(state, [nameOf(view) stringByAppendingString:@" has an ambiguous layout"]);
    for (NSUInteger i = 0; i < visible.count; i++) {
        for (NSUInteger j = i + 1; j < visible.count; j++) {
            NSRect a = [visible[i] alignmentRectForFrame:[visible[i] frame]];
            NSRect b = [visible[j] alignmentRectForFrame:[visible[j] frame]];
            NSRect overlap = NSIntersectionRect(a, b);
            if (NSWidth(overlap) > 0.5 && NSHeight(overlap) > 0.5)
                fail(state, [NSString stringWithFormat:@"%@ %@ overlaps %@ %@", nameOf(visible[i]), NSStringFromRect(a), nameOf(visible[j]), NSStringFromRect(b)]);
        }
    }
    NSTabView *tabs = [controller valueForKey:@"tabView"];
    if (detailsExpected == [tabs isHidden])
        fail(state, detailsExpected ? @"the details are hidden" : @"the details are shown");
    if (![tabs isHidden]) {
        if (NSWidth([tabs frame]) + 0.5 < tabMinimum.width)
            fail(state, [NSString stringWithFormat:@"the tab view is %g wide and its six tabs need %g", NSWidth([tabs frame]), tabMinimum.width]);
        NSRect area = [tabs contentRect];
        NSView *page = [[tabs selectedTabViewItem] view];
        for (NSView *view in [page subviews]) {
            NSRect frame = [page convertRect:[view frame] toView:tabs];
            if (NSIsEmptyRect([view frame]) || !inside(frame, area))
                fail(state, [NSString stringWithFormat:@"the page's %@ %@ is not inside the tab view's content %@", view.className, NSStringFromRect(frame), NSStringFromRect(area)]);
        }
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    [NSApplication sharedApplication];
    failures = [NSMutableArray array];
    language = [NSBundle.mainBundle preferredLocalizations].firstObject;
    FRFeedbackController *controller = [[FRFeedbackController alloc] init];
    NSWindow *window = [controller window];
    if (window == nil) { puts("FAIL: the nib has no window"); return 1; }
    // Every tab, with its translated label, is in the fresh nib.
    NSTabView *tabs = [controller valueForKey:@"tabView"];
    NSSize tabMinimum = [tabs minimumSize];

    // As the reporter does for a crash, and as a full report fills the tabs.
    [controller reset];
    NSBundle *strings = [NSBundle bundleWithIdentifier:@"org.vafer.FeedbackReporter"];
    NSString *heading = [strings localizedStringForKey:@"%@ has recently crashed!" value:nil table:@"FeedbackReporter"];
    [controller setHeading:[heading stringByReplacingOccurrencesOfString:@"%@" withString:@"IsiX DICOM Viewer"]];
    [controller setSubheading:[strings localizedStringForKey:@"Send crash report" value:nil table:@"FeedbackReporter"]];
    [controller setType:FR_CRASH];
    [(NSTextField *)[controller valueForKey:@"messageLabel"] setStringValue:[strings localizedStringForKey:@"Comments:" value:nil table:@"FeedbackReporter"]];
    for (NSString *key in @[@"tabSystem", @"tabConsole", @"tabCrash", @"tabScript", @"tabPreferences", @"tabException"])
        [controller insertTabViewItemInCorrectOrder:[controller valueForKey:key]];
    SEL fit = NSSelectorFromString(@"fitWindowToContent");
    if ([controller respondsToSelector:fit]) ((void (*)(id, SEL))[controller methodForSelector:fit])(controller, fit);

    // The addresses offered, without Contacts.
    NSComboBox *email = [controller valueForKey:@"emailBox"];
    NSString *remembered = [NSUserDefaults.standardUserDefaults stringForKey:@"FRFeedbackReporter.sender"];
    NSArray *offered = [email objectValues];
    NSString *anonymous = [strings localizedStringForKey:@"anonymous" value:nil table:@"FeedbackReporter"];
    NSArray *expected = remembered ? @[anonymous, remembered] : @[anonymous];
    if (![offered isEqualToArray:expected])
        fail(@"email", [NSString stringWithFormat:@"offers %@ instead of %@", offered, expected]);
    if (remembered && [email indexOfSelectedItem] != 1)
        fail(@"email", @"the address last used is not selected");
    if ([[NSBundle bundleWithPath:@"/System/Library/Frameworks/AddressBook.framework"] isLoaded] ||
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/Contacts.framework"] isLoaded])
        fail(@"email", @"a Contacts framework is loaded");

    NSButton *disclosure = [controller valueForKey:@"detailsButton"];
    check(controller, @"details hidden", NO, tabMinimum);
    [disclosure performClick:nil];
    check(controller, @"details shown", YES, tabMinimum);
    [disclosure performClick:nil];
    check(controller, @"details hidden again", NO, tabMinimum);

    for (NSString *failure in failures) printf("FAIL: %s\n", failure.UTF8String);
    return failures.count ? 1 : 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-feedback-layout-') as temporary:
    folder = Path(temporary)
    selected = selection.prepare(root / 'FeedbackReporter', folder / 'selected')
    main = selected / 'Sources/Main'
    controller = controller_source
    frameworks = ['Cocoa', 'OSLog', 'SystemConfiguration']
    if arguments.controller_source is not None:
        text = arguments.controller_source.read_text(encoding='utf-8')
        text = text.replace('[[ABAddressBook sharedAddressBook] me]', 'nil')
        controller = folder / 'FRFeedbackController.m'
        controller.write_text(text, encoding='utf-8')
        if 'AddressBook' in text:
            frameworks.append('AddressBook')
    sources = [path for path in sorted(main.glob('*.m'))
               if path.name not in ('FRFeedbackController.m', 'FRExceptionReportingApplication.m')]

    contents = folder / 'Probe.app/Contents'
    resources = contents / 'Resources'
    (contents / 'MacOS').mkdir(parents=True)
    probe = folder / 'probe.m'
    probe.write_text(PROBE, encoding='utf-8')
    command = ['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=26.0', '-Wno-deprecated-declarations',
               '-include', str(main / 'FeedbackReporter.pch'), '-I', str(main),
               str(probe), str(controller)] + [str(path) for path in sources]
    for framework in frameworks:
        command += ['-framework', framework]
    built = subprocess.run(command + ['-o', str(contents / 'MacOS/probe')], capture_output=True, text=True, timeout=300)
    if built.returncode != 0:
        print(built.stderr[-4000:])
        print('FAIL: the controller and the provider sources do not compile')
        sys.exit(1)
    # Every localization the framework ships: its own nib where it has one,
    # the base nib otherwise, and its strings.
    languages = []
    for directory in sorted((selected / 'Resources').glob('*.lproj')):
        target = resources / directory.name
        target.mkdir(parents=True)
        for item in directory.iterdir():
            if item.suffix == '.xib' and item.stem == 'FeedbackReporter':
                compiled = subprocess.run(['xcrun', 'ibtool', '--compile', str(target / 'FeedbackReporter.nib'), str(item)],
                                          capture_output=True, text=True, timeout=300)
                if compiled.returncode != 0:
                    print(compiled.stdout[-2000:], compiled.stderr[-2000:])
                    print('FAIL: ibtool could not compile ' + str(item.relative_to(selected)))
                    sys.exit(1)
            elif item.suffix == '.strings':
                target.joinpath(item.name).write_bytes(item.read_bytes())
        if directory.name != 'Base.lproj':
            languages.append(directory.stem)
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'probe', 'CFBundleIdentifier': 'org.vafer.FeedbackReporter',
        'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en',
        'CFBundleLocalizations': languages,
    }))
    require('de' in languages and 'en' in languages, 'the framework no longer ships English and German')

    runs = [(language, []) for language in languages]
    # The address last used is offered and selected.
    runs.append(('de', ['-FRFeedbackReporter.sender', 'synthetic@example.invalid']))
    for language, extra in runs:
        ran = subprocess.run([str(contents / 'MacOS/probe'), '-AppleLanguages', '(%s)' % language] + extra,
                             capture_output=True, text=True, timeout=120)
        lines = [line[len('FAIL: '):] for line in ran.stdout.splitlines() if line.startswith('FAIL: ')]
        failures.extend(lines)
        if arguments.verbose:
            print('\n'.join(line for line in ran.stdout.splitlines() if line.startswith('INFO: ')))
        if ran.returncode != 0 and not lines:
            failures.append('%s: the probe ended with %d: %s' % (language, ran.returncode, ran.stderr[-1000:]))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: in %d localizations, with the details hidden and shown, the feedback window keeps every control '
      'inside it without overlap, fits its texts, buttons and tabs, and offers "anonymous" and the address last '
      'used without Contacts' % len(languages))
