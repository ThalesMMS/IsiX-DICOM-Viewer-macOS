#!/usr/bin/env python3
"""Build local synthetic plugins, of the former API and of the version 1 API.

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
for name, architectures, principal, throws in [
    ('QADisabled', ['arm64', 'x86_64'], 'QADisabled', False),
    ('QAUniversal', ['arm64', 'x86_64'], 'QAUniversal', False),
    ('QAIntel', ['x86_64'], 'QAIntel', False),
    ('QAMissingClass', ['arm64', 'x86_64'], 'QAAbsent', False),
    ('QAInvalidSignature', ['arm64', 'x86_64'], 'QAInvalidSignature', False),
    ('QAInitializationFailure', ['arm64', 'x86_64'], 'QAInitializationFailure', True),
]:
    bundle = args.destination / (name + '.horosplugin')
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
            'NSPrincipalClass': principal, 'pluginType': 'imageFilter', 'MenuTitles': [name]}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    resources = bundle/'Contents/Resources'
    resources.mkdir()
    (resources/'seal.txt').write_text('Original synthetic resource')
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    if name == 'QAInvalidSignature':
        (resources/'seal.txt').write_text('Modified after signing')

# The former plugins above are refused at every entry since the plugin API
# version 1. These are what the application takes or refuses instead: a stand-in
# IsiXPluginKit.framework (only its install name matters: a plugin links it, the
# host provides it; a test executable reaches it with -rpath DEST/Kit), version 1
# bundles that link it, and former plugins under other names.
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
# A former plugin with the other former extension, and one renamed to look like
# a version 1 bundle: both are refused, the second by what it declares.
for copy in ('QAOsiriX.osirixplugin', 'QARenamed.isixplugin'):
    subprocess.run(['ditto', str(args.destination / 'QAUniversal.horosplugin'), str(args.destination / copy)], check=True)
print('Created synthetic plugin bundles, former and version 1, and a stand-in IsiXPluginKit; none installed.')
