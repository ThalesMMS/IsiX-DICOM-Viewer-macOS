#!/usr/bin/env python3
"""Build local synthetic plugins, of the former API and of the version 1 API.

Former plugins: QAUniversal.horosplugin (an image filter), QAOsiriX.osirixplugin
(a database plugin) and the other QA*.horosplugin cases link only AppKit.
QAHostLinked.horosplugin is built as the plugins of the former SDK were: its
principal class is an Objective-C subclass of the host's PluginFilter, whose
+filter and -prepareFilter: it inherits, it messages the host's PluginManager
class, both found at run time with -undefined dynamic_lookup, and its load
commands name the SDK frameworks by their install names in the application
(Horos, HorosAPI, OsiriXAPI, OsiriX Headers, HorosDCM), built here as
stand-ins; it loads only in the application. QAMissingSymbol.horosplugin
looks up a constant that no application defines, and never loads. With
HOROS_PLUGIN_MARKER_DIR set,
a former plugin's -filterImage: leaves <Class>.executed there instead of
showing an alert, and QAHostLinked's -initPlugin, which the host's -init calls
when +filter makes its filter, leaves QAHostLinked.initPlugin.

QAModalDialog.horosplugin is a database plugin whose command keeps a modal
dialog open: the moment the application can be asked to quit with the code of
a plugin still on the stack. Left alone it only shows its dialog. To drive it
without a hand on the mouse, HOROS_PLUGIN_MODAL_AUTORUN=<seconds> makes it
choose its own menu item that long after the launch finishes, and
HOROS_PLUGIN_MODAL_QUIT says what it does two seconds after the dialog opens:
`key` posts Command-Q to the application's event queue, as the keyboard does;
`delegate` sends -terminate: to the application's delegate from a block of the
main run loop in the common modes, which is where the installation of an
update asks the application to quit; `application` sends -terminate: to
NSApplication. With HOROS_PLUGIN_MARKER_DIR set it also writes what it saw,
the note naming the running plugin included, to QAModalDialog.trace there.

QA.horosplugin (version 1.0) and QA.osirixplugin (version 2.0) are one database
plugin under the two former extensions, as two installers of one author leave
it; -filterImage: says which bundle and version ran, in QA.executed when
HOROS_PLUGIN_MARKER_DIR is set.

Never installs them.
"""
from pathlib import Path
import argparse
import os
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
if any(args.destination.iterdir()):
    parser.error('destination must be empty')
for name, architectures, principal, throws, extension, plugin_type in [
    ('QADisabled', ['arm64', 'x86_64'], 'QADisabled', False, 'horosplugin', 'imageFilter'),
    ('QAUniversal', ['arm64', 'x86_64'], 'QAUniversal', False, 'horosplugin', 'imageFilter'),
    ('QAOsiriX', ['arm64', 'x86_64'], 'QAOsiriX', False, 'osirixplugin', 'Database'),
    ('QAIntel', ['x86_64'], 'QAIntel', False, 'horosplugin', 'imageFilter'),
    ('QAMissingClass', ['arm64', 'x86_64'], 'QAAbsent', False, 'horosplugin', 'imageFilter'),
    ('QAInvalidSignature', ['arm64', 'x86_64'], 'QAInvalidSignature', False, 'horosplugin', 'imageFilter'),
    ('QAInitializationFailure', ['arm64', 'x86_64'], 'QAInitializationFailure', True, 'horosplugin', 'imageFilter'),
]:
    bundle = args.destination / (name + '.' + extension)
    executable = bundle / 'Contents/MacOS' / name
    executable.parent.mkdir(parents=True)
    source = args.destination / (name + '.m')
    source.write_text('''#import <AppKit/AppKit.h>
@interface CLASS : NSObject
+ (id)filter;
- (long)filterImage:(NSString*)menu;
@end
@implementation CLASS
// +load runs while the loader is still inside -[NSBundle loadAndReturnError:],
// which is the only moment the note naming the plugin being loaded is true.
// Silent unless HOROS_PLUGIN_MARKER_DIR says where to look.
+ (void)load {
    const char *directory = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (!directory) return;
    NSString *where = @(directory);
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:where error:NULL])
        if ([entry hasPrefix:@"Plugin_Loading"])
            NSLog(@"PLUGINFIXTURE while CLASS loads, %@ names %@", entry,
                  [NSString stringWithContentsOfFile:[where stringByAppendingPathComponent:entry]
                                            encoding:NSUTF8StringEncoding error:NULL]);
}
+ (id)filter { BODY }
- (long)prepareFilter:(id)viewer { return 0; }
- (long)filterImage:(NSString*)menu {
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) {
        [menu writeToFile:[@(markers) stringByAppendingPathComponent:@"CLASS.executed"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return 0;
    }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Synthetic plugin executed";
    alert.informativeText = @"QA universal filter completed without changing images.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return 0;
}
@end
'''.replace('CLASS', name).replace('BODY', '@throw [NSException exceptionWithName:@"SyntheticFailure" reason:@"Synthetic initialization failure" userInfo:nil];' if throws else 'return [[[self alloc] init] autorelease];'))
    command = ['xcrun', 'clang', '-bundle', '-framework', 'AppKit']
    for architecture in architectures:
        command += ['-arch', architecture]
    # clang leaves an empty folder per architecture in TMPDIR when it links a
    # universal binary; give it one that goes away with the build.
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(command + [str(source), '-o', str(executable)], check=True,
                       env=dict(os.environ, TMPDIR=scratch + '/'))
    info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.horosproject.qa.' + name,
            'CFBundleName': name, 'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL',
            'NSPrincipalClass': principal, 'pluginType': plugin_type, 'MenuTitles': [name]}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    resources = bundle/'Contents/Resources'
    resources.mkdir()
    (resources/'seal.txt').write_text('Original synthetic resource')
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    if name == 'QAInvalidSignature':
        (resources/'seal.txt').write_text('Modified after signing')

# A former plugin built against the former SDK: stand-ins of its frameworks,
# with the install names the application gives them, and a class that messages
# the host's PluginManager, which dyld finds at run time.
sdk = args.destination / 'FormerSDK'
sdk_source = args.destination / 'FormerSDK.c'
sdk_source.write_text(''.join(f'double {v}VersionNumber = 100;\nconst unsigned char {v}VersionString[] = "1.0.0";\n'
                              for v in ('HorosAPI', 'OsiriXAPI', 'OsiriX_Headers', 'HorosDCM')))
sdk_frameworks = ['Horos', 'HorosAPI', 'OsiriXAPI', 'OsiriX Headers', 'HorosDCM']
for framework in sdk_frameworks:
    binary = sdk / f'{framework}.framework/Versions/A/{framework}'
    binary.parent.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                        '-install_name', f'@executable_path/../Frameworks/{framework}.framework/Versions/A/{framework}',
                        str(sdk_source), '-o', str(binary)], check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
    (sdk / f'{framework}.framework/Versions/Current').symlink_to('A')
    (sdk / f'{framework}.framework/{framework}').symlink_to(f'Versions/Current/{framework}')
host_linked = args.destination / 'QAHostLinked.horosplugin'
(host_linked / 'Contents/MacOS').mkdir(parents=True)
host_source = args.destination / 'QAHostLinked.m'
host_source.write_text('''#import <Foundation/Foundation.h>
// What the former SDK declared of the host's classes; the classes themselves are the application's.
@interface PluginManager : NSObject
+ (NSMutableDictionary *)plugins;
@end
@interface PluginFilter : NSObject
+ (PluginFilter *)filter;
- (long)filterImage:(NSString *)menuName;
- (void)initPlugin;
- (long)prepareFilter:(id)vC;
@end
extern double HorosAPIVersionNumber, OsiriXAPIVersionNumber, OsiriX_HeadersVersionNumber, HorosDCMVersionNumber;
static void QAHostLinkedMark(NSString *name, NSString *text) {
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) [text writeToFile:[@(markers) stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
@interface QAHostLinked : PluginFilter
@end
@implementation QAHostLinked
- (void)initPlugin {
    QAHostLinkedMark(@"QAHostLinked.initPlugin", [NSStringFromClass([PluginManager class]) stringByAppendingFormat:@" %@ %@",
        NSStringFromClass([self class]), NSStringFromClass([self superclass])]);
}
- (long)filterImage:(NSString *)menu {
    QAHostLinkedMark(@"QAHostLinked.executed", [NSString stringWithFormat:@"%@ %@ %lu %g %g %g %g", menu, NSStringFromClass([PluginManager class]),
        (unsigned long)[[PluginManager plugins] count], HorosAPIVersionNumber, OsiriXAPIVersionNumber, OsiriX_HeadersVersionNumber, HorosDCMVersionNumber]);
    return 0;
}
@end
''')
command = ['xcrun', 'clang', '-bundle', '-framework', 'Foundation', '-mmacosx-version-min=15.0', '-arch', 'arm64', '-arch', 'x86_64',
           '-undefined', 'dynamic_lookup', '-F', str(sdk)]
for framework in sdk_frameworks:
    command += ['-framework', framework]
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(command + [str(host_source), '-o', str(host_linked / 'Contents/MacOS/QAHostLinked')], check=True,
                   env=dict(os.environ, TMPDIR=scratch + '/'))
(host_linked / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QAHostLinked', 'CFBundleIdentifier': 'org.horosproject.qa.QAHostLinked', 'CFBundleName': 'QAHostLinked',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QAHostLinked', 'pluginType': 'Database',
    'MenuTitles': ['QAHostLinked A', '(-', 'QAHostLinked B']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(host_linked)], check=True, capture_output=True)

# A former plugin whose binary looks, as the former SDK's plugins do with
# -undefined dynamic_lookup, for a constant that no application defines:
# dyld refuses it with a link error that names the symbol.
missing_symbol = args.destination / 'QAMissingSymbol.horosplugin'
(missing_symbol / 'Contents/MacOS').mkdir(parents=True)
missing_source = args.destination / 'QAMissingSymbol.m'
missing_source.write_text('''#import <Foundation/Foundation.h>
extern NSString *const QAAbsentHostSymbol;
@interface QAMissingSymbol : NSObject
@end
@implementation QAMissingSymbol
+ (id)filter { return QAAbsentHostSymbol; }
@end
''')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-bundle', '-framework', 'Foundation', '-mmacosx-version-min=15.0', '-arch', 'arm64', '-arch', 'x86_64',
                    '-undefined', 'dynamic_lookup', str(missing_source), '-o', str(missing_symbol / 'Contents/MacOS/QAMissingSymbol')],
                   check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(missing_symbol / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QAMissingSymbol', 'CFBundleIdentifier': 'org.horosproject.qa.QAMissingSymbol', 'CFBundleName': 'QAMissingSymbol',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QAMissingSymbol', 'pluginType': 'imageFilter',
    'MenuTitles': ['QAMissingSymbol']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(missing_symbol)], check=True, capture_output=True)

# A former database plugin whose command stays in a modal dialog, and that can
# ask the application to quit from inside it: see the module's description.
modal = args.destination / 'QAModalDialog.horosplugin'
(modal / 'Contents/MacOS').mkdir(parents=True)
modal_source = args.destination / 'QAModalDialog.m'
modal_source.write_text(r'''#import <AppKit/AppKit.h>
static void QAModalDialogTrace(NSString *text) {
    NSLog(@"PLUGINFIXTURE QAModalDialog %@", text);
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (!markers) return;
    NSString *path = [@(markers) stringByAppendingPathComponent:@"QAModalDialog.trace"];
    NSString *before = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    [[before stringByAppendingFormat:@"%@\n", text] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static NSMenuItem *QAModalDialogFind(NSMenu *menu, BOOL (^matches)(NSMenuItem *)) {
    for (NSMenuItem *item in menu.itemArray) {
        if (matches(item)) return item;
        NSMenuItem *found = item.submenu ? QAModalDialogFind(item.submenu, matches) : nil;
        if (found) return found;
    }
    return nil;
}
@interface QAModalDialog : NSObject
@end
@implementation QAModalDialog
+ (void)load {
    const char *delay = getenv("HOROS_PLUGIN_MODAL_AUTORUN");
    if (!delay) return;
    NSTimeInterval seconds = atof(delay);
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        [self performSelector:@selector(chooseOwnMenuItem) withObject:nil afterDelay:seconds];
    }];
}
// The item the application made for this plugin in its Plugins menu, sent as a click sends it.
+ (void)chooseOwnMenuItem {
    NSMenuItem *item = QAModalDialogFind(NSApp.mainMenu, ^BOOL(NSMenuItem *candidate) {
        return [candidate.title isEqualToString:@"QAModalDialog"] && candidate.action != NULL;
    });
    QAModalDialogTrace([NSString stringWithFormat:@"own menu item %@, action %@, target %@", item ? @"found" : @"missing",
                        item ? NSStringFromSelector(item.action) : @"-", item.target ? NSStringFromClass([item.target class]) : @"-"]);
    if (item) [NSApp sendAction:item.action to:item.target from:item];
}
+ (id)filter { return [[[self alloc] init] autorelease]; }
- (long)prepareFilter:(id)viewer { return 0; }
// The notes beside the plugins folder this bundle is in, as the application left them.
- (NSString *)notes {
    NSString *support = [[[NSBundle bundleForClass:[self class]].bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSMutableArray *notes = [NSMutableArray array];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:support error:NULL])
        if ([entry hasPrefix:@"Plugin_Loading"])
            [notes addObject:[NSString stringWithFormat:@"%@ = %@", entry,
                              [[NSString stringWithContentsOfFile:[support stringByAppendingPathComponent:entry] encoding:NSUTF8StringEncoding error:NULL]
                               stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]];
    return notes.count ? [notes componentsJoinedByString:@"; "] : @"none";
}
- (void)askToQuit:(NSString *)how {
    QAModalDialogTrace([NSString stringWithFormat:@"asking to quit by %@; modal window %@", how, NSApp.modalWindow ? @"open" : @"absent"]);
    if ([how isEqualToString:@"key"]) {
        NSMenuItem *quit = QAModalDialogFind(NSApp.mainMenu, ^BOOL(NSMenuItem *candidate) {
            return [candidate.keyEquivalent isEqualToString:@"q"] && candidate.keyEquivalentModifierMask == NSEventModifierFlagCommand;
        });
        [quit.menu update];
        QAModalDialogTrace([NSString stringWithFormat:@"Quit item %@, enabled %d, action %@, target %@", quit ? quit.title : @"missing", quit.enabled,
                            quit ? NSStringFromSelector(quit.action) : @"-", quit.target ? NSStringFromClass([quit.target class]) : @"-"]);
        for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)])
            [NSApp postEvent:[NSEvent keyEventWithType:type.unsignedIntegerValue location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:NSApp.keyWindow.windowNumber context:nil
                                            characters:@"q" charactersIgnoringModifiers:@"q" isARepeat:NO keyCode:12] atStart:NO];
    } else if ([how isEqualToString:@"delegate"]) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            QAModalDialogTrace(@"-terminate: to the application's delegate, from a block of the main run loop");
            [(id)NSApp.delegate performSelector:@selector(terminate:) withObject:nil];
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    } else if ([how isEqualToString:@"application"]) {
        [NSApp terminate:nil];
    }
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *timer) {
        QAModalDialogTrace([NSString stringWithFormat:@"still running 3 s after asking to quit by %@; notes: %@", how, [self notes]]);
    }].tolerance = 0;
}
- (long)filterImage:(NSString *)menu {
    QAModalDialogTrace([NSString stringWithFormat:@"command %@ started; notes: %@", menu, [self notes]]);
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Synthetic plugin dialog";
    alert.informativeText = @"QAModalDialog keeps this dialog open until it is answered.";
    [alert addButtonWithTitle:@"OK"];
    const char *quit = getenv("HOROS_PLUGIN_MODAL_QUIT");
    if (quit) {
        NSString *how = @(quit);
        NSTimer *timer = [NSTimer timerWithTimeInterval:2 repeats:NO block:^(NSTimer *fired) { [self askToQuit:how]; }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
    [alert runModal];
    QAModalDialogTrace([NSString stringWithFormat:@"command %@ returned", menu]);
    return 0;
}
@end
''')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-bundle', '-framework', 'AppKit', '-arch', 'arm64', '-arch', 'x86_64',
                    str(modal_source), '-o', str(modal / 'Contents/MacOS/QAModalDialog')],
                   check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(modal / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QAModalDialog', 'CFBundleIdentifier': 'org.horosproject.qa.QAModalDialog', 'CFBundleName': 'QAModalDialog',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QAModalDialog', 'pluginType': 'Database',
    'MenuTitles': ['QAModalDialog']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(modal)], check=True, capture_output=True)

# One plugin twice, as two installers of the same author leave it: the same
# name, class and identifier under the two former extensions, at two versions.
same_name_source = args.destination / 'QA.m'
same_name_source.write_text(r'''#import <AppKit/AppKit.h>
@interface QA : NSObject
@end
@implementation QA
+ (id)filter { return [[[self alloc] init] autorelease]; }
- (long)prepareFilter:(id)viewer { return 0; }
- (long)filterImage:(NSString *)menu {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *which = [NSString stringWithFormat:@"%@ %@", bundle.bundlePath.lastPathComponent, [bundle objectForInfoDictionaryKey:@"CFBundleVersion"]];
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) {
        [which writeToFile:[@(markers) stringByAppendingPathComponent:@"QA.executed"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return 0;
    }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Synthetic plugin executed";
    alert.informativeText = which;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return 0;
}
@end
''')
for extension, version in [('horosplugin', '1.0'), ('osirixplugin', '2.0')]:
    bundle = args.destination / ('QA.' + extension)
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(['xcrun', 'clang', '-bundle', '-framework', 'AppKit', '-arch', 'arm64', '-arch', 'x86_64',
                        str(same_name_source), '-o', str(bundle / 'Contents/MacOS/QA')],
                       check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'QA', 'CFBundleIdentifier': 'org.horosproject.qa.QA', 'CFBundleName': 'QA',
        'CFBundleVersion': version, 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QA', 'pluginType': 'Database',
        'MenuTitles': ['QA']}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)

# Version 1: a stand-in IsiXPluginKit.framework (only its install name
# matters: a plugin links it, the host provides it; a test executable reaches
# it with -rpath DEST/Kit) and bundles that link it.
kit = args.destination / 'Kit/IsiXPluginKit.framework'
kit_binary = kit / 'Versions/A/IsiXPluginKit'
kit_binary.parent.mkdir(parents=True)
kit_source = args.destination / 'IsiXPluginKitStandIn.c'
kit_source.write_text('int IsiXPluginKitStandIn(void) { return 1; }\n')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                    '-install_name', '@rpath/IsiXPluginKit.framework/Versions/A/IsiXPluginKit',
                    str(kit_source), '-o', str(kit_binary)], check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(kit / 'Versions/Current').symlink_to('A')
(kit / 'IsiXPluginKit').symlink_to('Versions/Current/IsiXPluginKit')
subprocess.run(['codesign', '--force', '--sign', '-', str(kit_binary)], check=True, capture_output=True)
for name, architectures in [('QAVersion1', ['arm64', 'x86_64']), ('QAVersion1Intel', ['x86_64']),
                            ('QAVersion1InvalidSignature', ['arm64', 'x86_64'])]:
    bundle = args.destination / (name + '.isixplugin')
    executable = bundle / 'Contents/MacOS' / name
    executable.parent.mkdir(parents=True)
    source = args.destination / (name + '.m')
    # +load leaves a file when the code runs: installing or listing must not.
    source.write_text('''#import <Foundation/Foundation.h>
extern int IsiXPluginKitStandIn(void);
@interface CLASS : NSObject
@end
@implementation CLASS
+ (void)load {
    const char *directory = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (directory) [@"loaded" writeToFile:[@(directory) stringByAppendingPathComponent:@"CLASS.ran"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    IsiXPluginKitStandIn();
}
@end
'''.replace('CLASS', name))
    command = ['xcrun', 'clang', '-bundle', '-framework', 'Foundation', '-mmacosx-version-min=15.0',
               '-F', str(args.destination / 'Kit'), '-framework', 'IsiXPluginKit']
    for architecture in architectures:
        command += ['-arch', architecture]
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(command + [str(source), '-o', str(executable)], check=True,
                       env=dict(os.environ, TMPDIR=scratch + '/'))
    info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.example.isix.qa.' + name,
            'CFBundleName': name, 'CFBundleVersion': '1.0', 'CFBundleShortVersionString': '1.0',
            'CFBundlePackageType': 'BNDL', 'LSMinimumSystemVersion': '15.0',
            'NSPrincipalClass': name, 'IsiXPluginAPIVersion': 1}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    resources = bundle/'Contents/Resources'
    resources.mkdir()
    (resources/'seal.txt').write_text('Original synthetic resource')
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    if name == 'QAVersion1InvalidSignature':
        (resources/'seal.txt').write_text('Modified after signing')
# A former plugin renamed to look like a version 1 bundle: the version 1
# loader refuses it by what it declares, and it is never tried as a former one.
subprocess.run(['ditto', str(args.destination / 'QAUniversal.horosplugin'), str(args.destination / 'QARenamed.isixplugin')], check=True)
print('Created synthetic plugin bundles, former and version 1, and a stand-in IsiXPluginKit; none installed.')
