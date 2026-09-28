#!/usr/bin/env python3
"""Exercise the production file validator and directory-collision method with real files."""
from pathlib import Path
import hashlib
import sqlite3
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
import object_probe  # noqa: E402

# NSFileManager (N2) is Swift since #710, and -confirmDirectoryAtPath:subDirectory:
# is a private Swift method. The program drives it through the public selector
# that calls it, -confirmDirectoryAtPath:, in a library compiled from the Swift
# with the Swift classes it calls (N2DirectoryEnumerator, HorosStorageFailure -
# the real one, no stub) and the Objective-C objects it links.
helpers = [object_probe.first_app_object(name) for name in ('NSFileManager+N2+CAPI', 'NSString+SymlinksAndAliases')]
if any(h is None for h in helpers):
    print('needs a built NSFileManager+N2+CAPI.o and NSString+SymlinksAndAliases.o: script/build_and_run.sh',
          file=sys.stderr)
    raise SystemExit(2)
code = r'''
#import <CoreData/CoreData.h>
#import "HorosDatabaseFileValidation.h"
@interface NSFileManager(TestDirectory)
-(NSString*)confirmDirectoryAtPath:(NSString*)path;
@end
int main(int argc, const char **argv) { @autoreleasepool {
 NSString *mode = @(argv[1]), *path = @(argv[2]);
 if ([mode isEqual:@"validate"]) return HorosIsDatabaseFile(path) ? 0 : 1;
 if ([mode isEqual:@"directory"]) {
  @try { [NSFileManager.defaultManager confirmDirectoryAtPath:path]; return 0; }
  @catch (NSException *e) { return 1; }
 }
 NSManagedObjectModel *model = [NSManagedObjectModel new];
 NSMutableArray *entities = [NSMutableArray new];
 for (NSString *name in @[@"Study", @"Series", @"Image", @"Album"]) {
  NSEntityDescription *entity = [NSEntityDescription new];
  entity.name = name; entity.managedObjectClassName = @"NSManagedObject";
  NSAttributeDescription *attribute = [NSAttributeDescription new];
  attribute.name = @"fixtureValue"; attribute.attributeType = NSStringAttributeType;
  entity.properties = @[attribute]; [entities addObject:entity];
 }
 model.entities = entities;
 if (argc > 3) model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@(argv[3])]];
 if (!model) return 3;
 NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
 NSError *error = nil;
 NSPersistentStore *store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
  URL:[NSURL fileURLWithPath:path] options:@{NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"}} error:&error];
 if (!store) { NSLog(@"%@",error); return 2; }
 return [coordinator removePersistentStore:store error:&error] ? 0 : 2;
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-file-safety-') as folder:
    work = Path(folder)
    (work / 'test.m').write_text(code)
    binary = work / 'test'
    bridging = work / 'bridging.h'
    bridging.write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                        '#import "N2DirectoryEnumerator.h"\n#import "NSFileManager+N2.h"\n'
                        '#import "NSString+SymlinksAndAliases.h"\n')
    library = object_probe.swift_dylib([root / 'Nitrogen/Sources/NSFileManager+N2.swift',
                                        root / 'Nitrogen/Sources/N2DirectoryEnumerator.swift',
                                        root / 'Horos/Sources/StorageFailure.swift'],
                                       helpers, work / 'libNSFileManagerN2.dylib', bridging_header=bridging,
                                       include_dirs=(root / 'Nitrogen/Sources', root / 'Horos/Sources',
                                                     root / 'LetsMoveAndDock'),
                                       frameworks=('Cocoa',))
    subprocess.run(['xcrun', 'clang', '-I', str(root / 'Horos/Sources'), str(work / 'test.m'),
                    str(library), '-Wl,-rpath,' + str(work),
                    '-framework', 'Foundation', '-framework', 'CoreData', '-lsqlite3', '-o', str(binary)], check=True)
    def run(mode, path, expected):
        result = subprocess.run([str(binary), mode, str(path)], capture_output=True)
        assert result.returncode == expected, result.stderr.decode()
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()
    text = work / 'external.sql'
    text.write_text('CREATE TABLE valuable (id INTEGER);\n')
    external = work / 'external' / 'Horos Data' / 'Database.sql'
    external.parent.mkdir(parents=True)
    with sqlite3.connect(external) as connection:
        connection.execute('create table valuable (id integer)')
        connection.execute('insert into valuable values (42)')
    malformed = work / 'malformed' / 'Horos Data' / 'Database.sql'
    malformed.parent.mkdir(parents=True)
    malformed.write_bytes(b'SQLite format 3\0' + b'not a database' * 40)
    for path in (text, external, malformed):
        before = digest(path)
        run('validate', path, 1)
        run('directory', path, 1)
        run('directory', path / 'Horos Data' / 'nested', 1)
        assert path.is_file() and digest(path) == before, str(path)
    valid = work / 'valid' / 'Horos Data' / 'Database.sql'
    valid.parent.mkdir(parents=True)
    run('create', valid, 0)
    before = digest(valid)
    run('validate', valid, 0)
    assert digest(valid) == before
    renamed = valid.with_name('other.sql')
    renamed.write_bytes(valid.read_bytes())
    run('validate', renamed, 1)
    run('validate', work / 'missing.sql', 1)
    run('directory', work / 'new' / 'nested', 0)
    assert (work / 'new' / 'nested').is_dir()
    if len(sys.argv) > 1:
        models = sorted(Path(sys.argv[1]).glob('OsiriXDB*.mom'))
        assert models, 'No compiled Horos models found'
        for model in models:
            historical = work / model.stem / 'Horos Data' / 'Database.sql'
            historical.parent.mkdir(parents=True)
            subprocess.run([str(binary), 'create', str(historical), str(model)], check=True)
            before = digest(historical)
            run('validate', historical, 0)
            assert digest(historical) == before
            print('PASS model:', model.name)
    print('PASS: textual SQL, external SQLite, malformed SQLite, missing/renamed files, Core Data metadata, and direct/parent directory collisions')
