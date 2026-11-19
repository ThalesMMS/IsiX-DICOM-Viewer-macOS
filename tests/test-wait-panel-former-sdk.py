#!/usr/bin/env python3
"""The wait panel answers a plugin whichever headers of the plugin SDKs it was
built with.

The headers of the Horos and OsiriX plugin SDKs do not declare the same wait
panel. Some declare -progress as a progress indicator, others as a level
indicator, and some declare selectors the others do not have: a maximum, the
class methods that show a panel, a bar that sweeps, a message that changes. A
plugin sends what its headers declared, and a selector the panel or its bar
does not have raises "unrecognized selector" in the middle of the plugin's
work.

The panel is compiled here alone, in the language mode of the application:
Wait.swift, its extension for the plugin SDKs, the two types that keep its
bars, and the files it needs. The ten localized copies of Wait.xib are
compiled with ibtool, and a driver written as a plugin of those SDKs was
(Objective-C without ARC, declaring the panel as the headers did) loads the
panel from each copy and checks:

- the bar the panel answers stands where the bar of the nib stood, in the
  same constraints, and is a progress indicator: it takes -startAnimation:,
  -setIndeterminate: and -setUsesThreadedAnimation:;
- it answers the selectors AppKit declares for NSLevelIndicator with the type
  encodings of NSLevelIndicator's own methods, keeps and reads back the
  thresholds, the tick marks and the colours, and gives its value as a control
  does; it is no kind of NSLevelIndicator, which is the known limit;
- -setIndeterminate: YES hides the determinate bar and shows a second one,
  indeterminate, in the same place; NO does the opposite; the determinate bar
  is never made indeterminate and keeps its value, which -incrementBy: goes on
  changing meanwhile;
- -maxProgress, -setProgressValue:, -increment, -run and -setString: do what
  their names say, and the two class methods answer a panel on screen with
  that maximum and that button;
- each selector of the panel in tests/fixtures/former-sdk-selector-types.json
  has that type encoding.

    python3 tests/test-wait-panel-former-sdk.py

Exit status 2 without the compilers. The class methods put a small panel on
screen for an instant: the test needs the graphic session.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
TYPES = {key: value for key, value in
         json.loads((ROOT / 'tests/fixtures/former-sdk-selector-types.json').read_text())['types'].items()
         if key.startswith('Wait ')}
# The selectors only some headers declare, which the fixture must name.
ADDED = ['Wait -maxProgress', 'Wait -setMaxProgress:', 'Wait +showWithString:', 'Wait +showWithString:maxProgress:showCancel:',
         'Wait -setProgressValue:', 'Wait -increment', 'Wait -run', 'Wait -indeterminateIndicator', 'Wait -setIndeterminate:',
         'Wait -setString:']

# What the panel names of the application and this test does not exercise.
STUBS = r'''
import AppKit

@objc(WaitRendering) public final class WaitRendering: NSWindowController {}
'''

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// The panel as the headers of the plugin SDKs declared it, all of them
// together; -progress is an indicator of one class or of the other.
@interface Wait : NSWindowController
@property (nonatomic) int maxProgress;
+ (Wait *)showWithString:(NSString *)str;
+ (Wait *)showWithString:(NSString *)str maxProgress:(int)maxValue showCancel:(BOOL)showCancel;
- (id)initWithString:(NSString *)str :(BOOL)useSession;
- (id)initWithString:(NSString *)str;
- (void)setProgressValue:(double)v;
- (void)incrementBy:(double)delta;
- (void)increment;
- (void)run;
- (id)progress;
- (NSProgressIndicator *)indeterminateIndicator;
- (void)setIndeterminate:(BOOL)v;
- (BOOL)aborted;
- (void)setCancel:(BOOL)val;
- (void)setString:(NSString *)str;
- (NSTextField *)text;
- (NSButton *)abort;
@end

static int failures = 0;
static NSString *language;

static void check(BOOL holds, NSString *what) {
    if (!holds) { failures++; printf("FAIL: %s: %s\n", language.UTF8String, what.UTF8String); }
}

static NSUInteger constraintsNaming(NSView *view) {
    NSUInteger count = 0;
    for (NSLayoutConstraint *constraint in view.superview.constraints)
        if (constraint.firstItem == view || constraint.secondItem == view) count++;
    return count;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        language = [NSString stringWithUTF8String:argv[1]];
        BOOL shows = argc > 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        Wait *wait = [[Wait alloc] initWithString:@"QA wait" :NO];
        NSView *content = wait.window.contentView;
        check(content != nil, @"the panel has no window: the nib did not load");
        [content layoutSubtreeIfNeeded];

        // The bar of the nib is replaced where it stood.
        NSProgressIndicator *bar = [wait progress];
        check([bar isKindOfClass:[NSProgressIndicator class]], @"-progress does not answer a progress indicator");
        check([NSStringFromClass([bar class]) isEqualToString:@"IsiXWaitProgressIndicator"],
              [@"-progress answers a " stringByAppendingString:NSStringFromClass([bar class])]);
        check(![bar isKindOfClass:[NSLevelIndicator class]], @"the bar became a kind of NSLevelIndicator: the limit this test records changed");
        check(bar.superview == content, @"the bar is not in the panel");
        NSUInteger bars = 0;
        for (NSView *view in content.subviews) if ([view isKindOfClass:[NSProgressIndicator class]]) bars++;
        check(bars == 1, [NSString stringWithFormat:@"the panel has %lu progress indicators after loading", (unsigned long)bars]);
        check(constraintsNaming(bar) == 4, [NSString stringWithFormat:@"%lu constraints name the bar, the nib has 4", (unsigned long)constraintsNaming(bar)]);
        check(!bar.hasAmbiguousLayout, @"the layout of the bar is ambiguous");
        check(fabs(NSMinX(bar.frame) - 19) < 0.5 && fabs(NSMaxX(bar.frame) - (NSWidth(content.frame) - 19)) < 0.5 && NSHeight(bar.frame) > 0,
              [@"the bar is at " stringByAppendingString:NSStringFromRect(bar.frame)]);
        NSTextField *elapsed = nil;
        for (NSLayoutConstraint *constraint in content.constraints)
            if (constraint.secondItem == bar && constraint.secondAttribute == NSLayoutAttributeBottom) elapsed = constraint.firstItem;
        check(elapsed && fabs(NSMaxY(elapsed.frame) - NSMinY(bar.frame)) < 0.5, @"the field under the bar no longer follows it");
        check(!bar.isIndeterminate && bar.minValue == 0 && bar.maxValue == 100 && bar.doubleValue == 0 && !bar.isHidden,
              @"the bar lost the settings of the nib");

        // As a progress indicator.
        [bar setUsesThreadedAnimation:YES];
        [bar startAnimation:nil];
        [bar stopAnimation:nil];
        [bar setIndeterminate:NO];
        [wait incrementBy:10];
        check(bar.doubleValue == 10, @"-incrementBy: did not move the bar");

        // As a level indicator: the selectors NSLevelIndicator.h declares, with its types.
        NSArray *level = @[@"levelIndicatorStyle", @"setLevelIndicatorStyle:", @"isEditable", @"setEditable:", @"minValue", @"setMinValue:",
                           @"maxValue", @"setMaxValue:", @"warningValue", @"setWarningValue:", @"criticalValue", @"setCriticalValue:",
                           @"tickMarkPosition", @"setTickMarkPosition:", @"numberOfTickMarks", @"setNumberOfTickMarks:",
                           @"numberOfMajorTickMarks", @"setNumberOfMajorTickMarks:", @"tickMarkValueAtIndex:", @"rectOfTickMarkAtIndex:",
                           @"fillColor", @"setFillColor:", @"warningFillColor", @"setWarningFillColor:", @"criticalFillColor",
                           @"setCriticalFillColor:", @"drawsTieredCapacityLevels", @"setDrawsTieredCapacityLevels:",
                           @"placeholderVisibility", @"setPlaceholderVisibility:", @"ratingImage", @"setRatingImage:",
                           @"ratingPlaceholderImage", @"setRatingPlaceholderImage:",
                           // and the value of a control
                           @"doubleValue", @"setDoubleValue:", @"intValue", @"setIntValue:", @"integerValue", @"setIntegerValue:",
                           @"floatValue", @"setFloatValue:", @"objectValue", @"setObjectValue:", @"isEnabled", @"setEnabled:"];
        for (NSString *name in level) {
            Method ours = class_getInstanceMethod([bar class], NSSelectorFromString(name));
            Method theirs = class_getInstanceMethod([NSLevelIndicator class], NSSelectorFromString(name));
            if (!theirs) { check(NO, [name stringByAppendingString:@" is no method of NSLevelIndicator: the list of this test is wrong"]); continue; }
            if (!ours) { check(NO, [@"the bar does not answer " stringByAppendingString:name]); continue; }
            printf("LEVEL %s %s %s\n", name.UTF8String, method_getTypeEncoding(ours), method_getTypeEncoding(theirs));
        }
        NSLevelIndicator *asLevel = (NSLevelIndicator *)bar;
        asLevel.warningValue = 70;
        asLevel.criticalValue = 90;
        asLevel.levelIndicatorStyle = NSLevelIndicatorStyleDiscreteCapacity;
        asLevel.numberOfTickMarks = 5;
        asLevel.numberOfMajorTickMarks = 2;
        asLevel.tickMarkPosition = NSTickMarkPositionAbove;
        asLevel.editable = YES;
        asLevel.enabled = NO;
        asLevel.drawsTieredCapacityLevels = YES;
        asLevel.placeholderVisibility = NSLevelIndicatorPlaceholderVisibilityAlways;
        asLevel.fillColor = [NSColor blueColor];
        NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(4, 4)] autorelease];
        asLevel.ratingImage = image;
        check(asLevel.warningValue == 70 && asLevel.criticalValue == 90, @"the thresholds do not read back");
        check(asLevel.levelIndicatorStyle == NSLevelIndicatorStyleDiscreteCapacity && asLevel.numberOfTickMarks == 5
              && asLevel.numberOfMajorTickMarks == 2 && asLevel.tickMarkPosition == NSTickMarkPositionAbove && asLevel.isEditable
              && !asLevel.isEnabled && asLevel.drawsTieredCapacityLevels
              && asLevel.placeholderVisibility == NSLevelIndicatorPlaceholderVisibilityAlways, @"the settings of a level indicator do not read back");
        check([asLevel.fillColor isEqual:[NSColor blueColor]] && asLevel.ratingImage == image && asLevel.ratingPlaceholderImage == nil,
              @"the colour or the image does not read back");
        asLevel.fillColor = nil;
        check(asLevel.fillColor != nil && asLevel.warningFillColor != nil && asLevel.criticalFillColor != nil, @"a colour reads back nil");
        check([asLevel tickMarkValueAtIndex:2] == 50 && NSIsEmptyRect([asLevel rectOfTickMarkAtIndex:2]), @"the tick marks do not answer");
        asLevel.intValue = 30;
        check(bar.doubleValue == 30 && asLevel.intValue == 30 && asLevel.integerValue == 30 && asLevel.floatValue == 30
              && [asLevel.objectValue isEqual:@30], @"the value of a control does not reach the bar");
        asLevel.objectValue = @12.5;
        asLevel.objectValue = @"no number";
        check(bar.doubleValue == 12.5 && asLevel.intValue == 12, @"-setObjectValue: does not take a number, or took another object");
        asLevel.floatValue = 20;
        asLevel.integerValue = 10;
        check(bar.doubleValue == 10 && bar.maxValue == 100 && !bar.isIndeterminate, @"the bar is no longer the progress bar it was");

        // The two bars take turns.
        NSProgressIndicator *sweeping = [wait indeterminateIndicator];
        check([sweeping isKindOfClass:[NSProgressIndicator class]] && sweeping != bar && sweeping.isIndeterminate && sweeping.isHidden
              && sweeping.superview == content, @"-indeterminateIndicator does not answer a second bar, indeterminate and hidden, in the panel");
        check([wait indeterminateIndicator] == sweeping, @"-indeterminateIndicator answers another bar each time");
        [wait setIndeterminate:NO];
        check(!bar.isHidden && sweeping.isHidden, @"-setIndeterminate: NO changed a panel that was determinate");
        [wait setIndeterminate:YES];
        [content layoutSubtreeIfNeeded];
        check(bar.isHidden && !sweeping.isHidden, @"-setIndeterminate: YES does not show the bar that sweeps alone");
        check(!bar.isIndeterminate && sweeping.isIndeterminate, @"-setIndeterminate: YES changed the mode of a bar");
        check(NSEqualRects(bar.frame, sweeping.frame), [NSString stringWithFormat:@"the bar that sweeps is at %@, the determinate one at %@",
                                                        NSStringFromRect(sweeping.frame), NSStringFromRect(bar.frame)]);
        [wait incrementBy:5];
        check(bar.doubleValue == 15, @"the determinate bar does not keep counting while hidden");
        [wait setIndeterminate:YES];
        check(bar.isHidden && !sweeping.isHidden, @"-setIndeterminate: YES twice");
        [wait setIndeterminate:NO];
        check(!bar.isHidden && sweeping.isHidden, @"-setIndeterminate: NO does not show the determinate bar alone");
        check(!bar.isIndeterminate && bar.doubleValue == 15, @"the determinate bar came back with another mode or value");
        check([wait progress] == bar, @"-progress answers another bar after the turns");

        // The other selectors.
        check(wait.maxProgress == 100, @"-maxProgress is not the maximum of the bar");
        wait.maxProgress = 250;
        check(wait.maxProgress == 250 && bar.maxValue == 250 && bar.minValue == 0, @"-setMaxProgress: does not set the maximum of the bar");
        [wait setProgressValue:40];
        check(bar.doubleValue == 40, @"-setProgressValue: does not take the bar to the value");
        [wait increment];
        check(bar.doubleValue == 41, @"-increment does not add one");
        [wait run];
        check(![wait aborted], @"-run aborted the panel");
        [wait setString:@"QA another message"];
        check([[wait text].stringValue isEqualToString:@"QA another message"], @"-setString: does not change the message");
        [wait setString:nil];
        check([[wait text].stringValue isEqualToString:@""], @"-setString: nil does not empty the message");

        for (NSString *key in [[NSProcessInfo processInfo].environment[@"QA_WAIT_SELECTORS"] componentsSeparatedByString:@"\n"]) {
            NSArray *parts = [key componentsSeparatedByString:@" "];
            if (parts.count != 2) continue;
            NSString *selector = [parts[1] substringFromIndex:1];
            Method method = [parts[1] hasPrefix:@"+"] ? class_getClassMethod([Wait class], NSSelectorFromString(selector))
                                                      : class_getInstanceMethod([Wait class], NSSelectorFromString(selector));
            printf("TYPE %s|%s\n", key.UTF8String, method ? method_getTypeEncoding(method) : "unrecognized selector");
        }
        // A plugin sends the same selectors from a thread of its own while the main thread runs its loop: none may
        // end the process, what was sent is done in the order sent, and what is asked is answered.
        __block BOOL sent = NO;
        __block int maximumThere = 0, valueThere = 0;
        __block double criticalThere = 0;
        __block id barThere = nil, sweepingThere = nil;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            barThere = [wait progress];
            [wait setMaxProgress:50];
            [wait incrementBy:3];
            [wait setIndeterminate:YES];
            [wait setIndeterminate:NO];
            [(NSLevelIndicator *)barThere setWarningValue:66];
            [(NSLevelIndicator *)barThere setCriticalValue:77];
            criticalThere = [(NSLevelIndicator *)barThere criticalValue];
            [wait setString:@"QA thread"];
            [wait setElapsedString:@"QA elapsed"];
            [wait setCancel:YES];
            [wait setProgressValue:12];
            [wait increment];
            [wait run];
            (void)[wait aborted];
            maximumThere = wait.maxProgress;
            valueThere = [(NSLevelIndicator *)barThere intValue];
            sweepingThere = [wait indeterminateIndicator];
            sent = YES;
        }];
        [thread start];
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!sent && limit.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [thread release];
        check(sent, @"the selectors sent from another thread did not all return in 20 s");
        check(barThere == bar && sweepingThere == [wait indeterminateIndicator], @"another thread is not answered the bars of the panel");
        check(maximumThere == 50 && valueThere == 13 && criticalThere == 77,
              [NSString stringWithFormat:@"another thread read maximum %d, value %d and critical value %g after sending 50, 12 + 1 and 77",
               maximumThere, valueThere, criticalThere]);
        check(bar.doubleValue == 13 && bar.maxValue == 50 && [(NSLevelIndicator *)bar warningValue] == 66 && !bar.isHidden
              && [[wait text].stringValue isEqualToString:@"QA thread"] && ![wait abort].isHidden,
              @"what another thread sent the panel was not all done");

        [wait close];
        [wait release];

        if (shows) {
            Wait *shown = nil, *plain = nil;
            @autoreleasepool {
                shown = [[Wait showWithString:@"QA shown" maxProgress:7 showCancel:YES] retain];
                plain = [[Wait showWithString:@"QA plain"] retain];
            }
            check([shown isKindOfClass:[Wait class]] && shown.window.isVisible && shown.maxProgress == 7 && ![shown abort].isHidden
                  && [[shown text].stringValue isEqualToString:@"QA shown"],
                  @"+showWithString:maxProgress:showCancel: does not answer a panel on screen with that message, maximum and button");
            check([plain isKindOfClass:[Wait class]] && plain != shown && plain.window.isVisible && [plain abort].isHidden
                  && [[plain text].stringValue isEqualToString:@"QA plain"], @"+showWithString: does not answer a panel on screen with that message");
            [shown close];
            [plain close];
            check(!shown.window.isVisible && !plain.window.isVisible, @"-close leaves a panel on screen");
            [shown release];
            [plain release];
        }
    }
    return failures ? 1 : 0;
}
'''


def without_offsets(encoding):
    """A method's type encoding without its frame offsets; the sizes of its C arrays stay."""
    return re.sub(r'\[\d+|\d+', lambda found: found.group(0) if found.group(0).startswith('[') else '', encoding)


def run(command, what, timeout=300):
    done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if done.returncode:
        print((done.stdout + done.stderr)[-6000:], file=sys.stderr)
        print(f'FAIL: {what}', file=sys.stderr)
        sys.exit(1)
    return done


def main():
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc, clang and ibtool)', file=sys.stderr)
        return 2
    failures = [f'{key}: the fixture of the selector types does not name it' for key in ADDED if key not in TYPES]
    xibs = sorted((ROOT / 'Horos/Resources').glob('*.lproj/Wait.xib'))
    if len(xibs) != 10:
        failures.append(f'{len(xibs)} localized copies of Wait.xib instead of 10')
    with tempfile.TemporaryDirectory(prefix='isix-wait-panel-') as folder:
        folder = Path(folder).resolve()
        (folder / 'Stubs.swift').write_text(STUBS)
        (folder / 'main.m').write_text(DRIVER)
        swift = [str(SOURCES / name) for name in ('Wait.swift', 'Wait+LegacyPluginSDK.swift', 'WaitProgressIndicator.swift',
                                                   'WaitIndeterminateBar.swift', 'KeyWindowReturn.swift', 'ProgressPanel.swift',
                                                   'MainActorCallbacks.swift')]
        run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-Wno-deprecated-declarations', str(folder / 'main.m'), '-o', str(folder / 'main.o')],
            'the driver does not compile')
        # The language mode and the concurrency checking of the application.
        run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library', '-module-name', 'WaitPanel',
             *swift, str(folder / 'Stubs.swift'), str(folder / 'main.o'), '-o', str(folder / 'wait-panel')],
            'the wait panel does not compile alone in the language mode of the application')
        for xib in xibs:
            language = xib.parent.name.removesuffix('.lproj')
            place = folder / language
            place.mkdir()
            run(['xcrun', 'ibtool', '--compile', str(place / 'Wait.nib'), str(xib)], f'{xib.relative_to(ROOT)} does not compile')
            shutil.copy2(folder / 'wait-panel', place / 'wait-panel')
            # The class methods put a panel on screen: once is enough.
            shows = ['show'] if language == 'en' else []
            ran = subprocess.run([str(place / 'wait-panel'), language, *shows], capture_output=True, text=True, timeout=120,
                                 env={'QA_WAIT_SELECTORS': '\n'.join(sorted(TYPES)), 'PATH': '/usr/bin:/bin'})
            failures += [line[6:] for line in ran.stdout.splitlines() if line.startswith('FAIL: ')]
            if ran.returncode and not any(line.startswith('FAIL: ') for line in ran.stdout.splitlines()):
                failures.append(f'{language}: the driver ended with {ran.returncode}: {(ran.stdout + ran.stderr)[-1500:]}')
            for line in ran.stdout.splitlines():
                if line.startswith('LEVEL '):
                    _, name, ours, theirs = line.split(' ')
                    if without_offsets(ours) != without_offsets(theirs):
                        failures.append(f'{language}: the bar answers {name} with the types {without_offsets(ours)}, '
                                        f'NSLevelIndicator with {without_offsets(theirs)}')
                elif line.startswith('TYPE '):
                    key, answered = line[5:].split('|')
                    if TYPES[key] is not None and without_offsets(answered) != TYPES[key]:
                        failures.append(f'{language}: {key} answers with the types {without_offsets(answered)}, the SDK declared {TYPES[key]}')
            if ran.stdout.count('TYPE ') != len(TYPES) and not ran.returncode:
                failures.append(f'{language}: {ran.stdout.count("TYPE ")} of the {len(TYPES)} selectors of the panel were compared')
    for failure in sorted(set(failures)):
        print('FAIL: ' + failure)
    if failures:
        return 1
    print(f'PASS: the wait panel of each of the {len(xibs)} localized nibs answers a plugin of either SDK: its bar as a progress '
          f'indicator and as a level indicator, the two bars that take turns, and the {len(TYPES)} selectors of the panel with the '
          f'types the SDKs declared')
    return 0


if __name__ == '__main__':
    sys.exit(main())
