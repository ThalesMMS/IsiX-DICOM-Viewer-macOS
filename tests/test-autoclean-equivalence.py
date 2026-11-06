#!/usr/bin/env python3
"""Keep what the automatic cleanup deletes the same as before it had a policy.

The rules that decide which studies leave the database moved from
DicomDatabase+Clean.swift to AutoCleanupPolicy, over rows of values, and the
deletions to DatabaseCleanupService. This compiles the previous revision of
the file, as it was, and the current code against the same stand-ins
(tests/autoclean_harness.py) and the real N2ManagedObjectContext, and runs both
over copies of the same SQLite stores, with the same preferences and the same
injected filesystem capacity. For each case it compares what each one did:

- the preview, in order: the rows of each rule and the text of the summary;
- the studies deleted: in the order of the deletions for the space rule, which
  commits one study at a time, and as a set for the date rule, which commits them
  together, and whose order the preview gives;
- the studies and the files left, and the refresh notifications.

The stores are real Core Data stores, with albums as a relationship. They mix
locked studies, albums, comments, missing dates, missing patient UIDs, patients
whose UIDs differ only in case, accents or width, recently added studies, linked
files and files in the data folder, and more eligible studies than
MAXSTUDYDELETE (50). The cases go through the date rule, the space rule, and both
in one pass, with each preference that decides.

dontDeleteStudiesIfInAlbum never decided anything: the previous revision read it
in the date rule, but a later filter of that rule and the space rule kept every
study in an album anyway. The policy no longer reads it and always keeps them.
The cases still store it both ways, so that the previous revision runs with each
value and the same studies must stay.

Three differences are on purpose. The previous revision sent the comparison of
patient UIDs to nil, which answered "the same", so a study with no UID, sorted
first, took every study after it for one patient; the policy gives it a group of
its own. And it sorted with compare: but grouped without case, accents or width,
looking only at the next study, so a UID sorted between two spellings split their
patient; the policy sorts with the comparison of the groups, and a patient joined
that way stays while one of its studies lacks a date the rule reads, because that
study would otherwise take the date of the others and go. And it skipped a missing
date unless the first study of the group lacked it, so the order in which the
studies were read decided whether a study with no date went; the policy keeps
every patient with a study that lacks the date, with one spelling too.

The test does not relax any comparison for these. A store is compared with the
previous revision as it was unless it holds what a difference is about: then with
that revision with OWN_GROUP, PATIENT_ORDER or WHOLE_GROUP applied to exactly those
lines, and nothing else, so anything more that changed in it still fails. Each
difference must show in those stores, or its exception would be about nothing. The
last two must also only spare studies: every date pass below the limit of 50
deletes a subset of what the revision before it deleted. At the limit it need not,
because the order decides which 50 go first; the rest wait for the next pass.

A comparison that cannot fail proves nothing, so each run also builds the policy
with a rule changed and requires the comparison to find it. `--negative-control`
does that for every mutation in MUTATIONS instead of those that undo a difference
on purpose.

`--reference REVISION` compares with another revision than PREVIOUS. The test is
skipped (code 2) when git does not have the revision.
"""
import argparse
import json
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import autoclean_harness  # noqa: E402
import harness_defaults  # noqa: E402  the harness's preferences stay in its own process
import isix_modules  # noqa: E402

SKIPPED = 2
POLICY = ROOT / 'Modules/IsiXDatabase/Sources/AutoCleanupPolicy.swift'
# The last revision where the rules were in DicomDatabase+Clean.swift.
PREVIOUS = isix_modules.revision_before(ROOT, str(POLICY.relative_to(ROOT)))

# The difference on purpose, in the previous revision: (text, replacement).
OWN_GROUP = (('guard let string = string else { return .orderedSame }', 'guard let string = string else { return .orderedAscending }'),)

PATIENT_ORDER = (
    ('.sortedArray(using: [NSSortDescriptor(key: "patientUID", ascending: true)]) as NSArray',
     '''.sortedArray(options: .stable) { a, b in
                switch ((a as AnyObject).value(forKey: "patientUID") as? NSString, (b as AnyObject).value(forKey: "patientUID") as? NSString) {
                case let (uid?, other?): return uid.compare(other as String, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
                case (nil, nil): return .orderedSame
                case (nil, _?): return .orderedAscending
                case (_?, nil): return .orderedDescending
                }
            } as NSArray'''),
    ('let to = i\n', '''let to = i
            func heldBack(lacking keys: [String]) -> Bool {
                let group = (from...to).map { study($0) }
                return group.contains { row in keys.allSatisfy { row.value(forKey: $0) == nil } }
                    && Set(group.map { $0.value(forKey: "patientUID") as? String }).count > 1
            }
'''),
    ('dateProduced = compare(producedDate, studyDate) == .orderedDescending',
     'dateProduced = compare(producedDate, studyDate) == .orderedDescending && !heldBack(lacking: ["date"])'),
    ('dateOpened = compare(openedDate, openedStudyDate) == .orderedDescending',
     'dateOpened = compare(openedDate, openedStudyDate) == .orderedDescending && !heldBack(lacking: ["dateOpened", "dateAdded"])'),
)

# On top of PATIENT_ORDER: a study with no date holds its patient back with one spelling too.
WHOLE_GROUP = (('\n                    && Set(group.map { $0.value(forKey: "patientUID") as? String }).count > 1', ''),)

# A rule changed in the policy: (name, text, replacement). Each must be found.
# The first ON_PURPOSE undo a difference on purpose, and every run checks those.
ON_PURPOSE = 4
MUTATIONS = (
    ('a study with no UID takes the studies after it', 'guard let patientUID, let other else { return false }',
     'guard let patientUID else { return true }\n        guard let other else { return false }'),
    ('the order is not the comparison of the groups', 'let order = patientOrder(uidA, uidB)', 'let order = (uidA as NSString).compare(uidB)'),
    ('a study with no date goes on the date of the others', 'dates.count == group.count ? dates.max() : nil', 'dates.max()'),
    ('the first study read decides whether a missing date counts', 'dates.count == group.count ? dates.max() : nil',
     'dates.count == group.count || (date(group.first!) != nil && Set(group.map { $0.patientUID }).count == 1) ? dates.max() : nil'),
    ('the date rule forgets locked studies','if study.isLocked { return false }', 'if false { return false }'),
    ('the space rule forgets locked studies', 'if study.isLocked { continue }', 'if false { continue }'),
    ('MAXSTUDYDELETE is one less', 'maximumStudiesPerRule = 50', 'maximumStudiesPerRule = 49'),
    ('the space rule takes studies added an hour ago', 'spaceRuleGrace: TimeInterval = 7200', 'spaceRuleGrace: TimeInterval = 1800'),
    ('the date rule takes studies added this week', 'dateRuleGrace: TimeInterval = 60 * 60 * 7 * 24', 'dateRuleGrace: TimeInterval = 60 * 60 * 3 * 24'),
    ('the space order is newest first', 'dateA == dateB ? a.position < b.position : dateA < dateB', 'dateA == dateB ? a.position < b.position : dateA > dateB'),
    ('a patient is judged study by study', 'while i < studies.count - 1 && isSamePatient(', 'while false && isSamePatient('),
    ('patients are told apart by accents', '[.caseInsensitive, .diacriticInsensitive, .widthInsensitive]', '[.caseInsensitive, .widthInsensitive]'),
    ('the space rule forgets albums', 'if study.isInAlbum { continue }', 'if false { continue }'),
    ('the date rule forgets albums', '!study.isInAlbum && (study.dateAdded', '(study.dateAdded'),
    ('the comment filter is inverted', 'found ? preferences.commentFilterMode != 1 : preferences.commentFilterMode != 0',
     'found ? preferences.commentFilterMode != 0 : preferences.commentFilterMode != 1'),
)

DRIVER = r'''
static NSAttributeDescription *attr(NSString *name, NSAttributeType type) {
    NSAttributeDescription *a=[NSAttributeDescription new];a.name=name;a.attributeType=type;a.optional=YES;return a;
}
static NSRelationshipDescription *rel(NSString *name, NSEntityDescription *dest, NSUInteger max, NSDeleteRule rule) {
    NSRelationshipDescription *r=[NSRelationshipDescription new];r.name=name;r.destinationEntity=dest;r.minCount=0;r.maxCount=max;r.optional=YES;r.deleteRule=rule;return r;
}
static NSManagedObjectModel *fixtureModel(void) {
    NSManagedObjectModel *model=[NSManagedObjectModel new];
    NSEntityDescription *study=[NSEntityDescription new], *series=[NSEntityDescription new], *image=[NSEntityDescription new], *album=[NSEntityDescription new];
    study.name=@"Study";study.managedObjectClassName=@"DicomStudy";
    series.name=@"Series";series.managedObjectClassName=@"DicomSeries";
    image.name=@"Image";image.managedObjectClassName=@"DicomImage";
    album.name=@"Album";
    NSMutableArray *props=[NSMutableArray array];
    for (NSString *key in @[@"comment",@"comment2",@"comment3",@"comment4",@"name",@"studyName",@"patientID",@"patientUID"]) [props addObject:attr(key,NSStringAttributeType)];
    for (NSString *key in @[@"date",@"dateAdded",@"dateOpened"]) [props addObject:attr(key,NSDateAttributeType)];
    [props addObject:attr(@"lockedStudy",NSBooleanAttributeType)];
    NSRelationshipDescription *inAlbum=rel(@"albums",album,0,NSNullifyDeleteRule), *studies=rel(@"studies",study,0,NSNullifyDeleteRule);
    inAlbum.inverseRelationship=studies;studies.inverseRelationship=inAlbum;
    [props addObject:inAlbum];[props addObject:rel(@"series",series,0,NSCascadeDeleteRule)];study.properties=props;
    album.properties=@[attr(@"name",NSStringAttributeType),studies];
    series.properties=@[rel(@"images",image,0,NSCascadeDeleteRule)];
    image.properties=@[attr(@"completePath",NSStringAttributeType),attr(@"inDatabaseFolder",NSBooleanAttributeType)];
    model.entities=@[study,series,image,album];
    return model;
}
static id orNull(id value) { return value ?: NSNull.null; }
static id nilIfNull(id value) { return value==NSNull.null ? nil : value; }
// generate DIRECTORY: the store of the studies described in DIRECTORY/studies.json, one commit per study.
static void generate(NSString *directory) {
    NSArray *studies=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"studies.json"]] options:0 error:NULL];
    NSPersistentStoreCoordinator *psc=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:fixtureModel()];
    check([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"index.sqlite"]] options:@{NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"}} error:NULL]!=nil,@"create SQLite");
    NSManagedObjectContext *ctx=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];ctx.persistentStoreCoordinator=psc;
    [ctx performBlockAndWait:^{
        NSManagedObject *album=[NSEntityDescription insertNewObjectForEntityForName:@"Album" inManagedObjectContext:ctx];
        [album setValue:@"fixture" forKey:@"name"];
        NSDate *now=[NSDate date];
        for (NSDictionary *d in studies) {
            NSManagedObject *s=[NSEntityDescription insertNewObjectForEntityForName:@"Study" inManagedObjectContext:ctx];
            for (NSString *key in @[@"comment",@"comment2",@"comment3",@"comment4",@"name",@"studyName",@"patientID",@"patientUID"])
                [s setPrimitiveValue:nilIfNull(d[key]) forKey:key];
            for (NSString *key in @[@"date",@"dateAdded",@"dateOpened"]) {
                NSNumber *hours=nilIfNull(d[key]);
                [s setPrimitiveValue:hours ? [now dateByAddingTimeInterval:-hours.doubleValue*3600] : nil forKey:key];
            }
            [s setPrimitiveValue:nilIfNull(d[@"lockedStudy"]) forKey:@"lockedStudy"];
            if ([d[@"album"] boolValue]) [[s mutableSetValueForKey:@"albums"] addObject:album];
            NSManagedObject *se=[NSEntityDescription insertNewObjectForEntityForName:@"Series" inManagedObjectContext:ctx];
            NSManagedObject *im=[NSEntityDescription insertNewObjectForEntityForName:@"Image" inManagedObjectContext:ctx];
            [im setPrimitiveValue:d[@"path"] forKey:@"completePath"];[im setPrimitiveValue:d[@"inDatabaseFolder"] forKey:@"inDatabaseFolder"];
            [[se mutableSetValueForKey:@"images"] addObject:im];[[s mutableSetValueForKey:@"series"] addObject:se];
            NSError *error=nil;
            check([ctx save:&error],[NSString stringWithFormat:@"commit a study: %@",error]);
        }
    }];
}
static NSArray *leftStudies(NSManagedObjectContext *reader) {
    NSFetchRequest *request=[NSFetchRequest fetchRequestWithEntityName:@"Study"];
    NSMutableArray *left=[NSMutableArray array];
    for (NSManagedObject *study in [reader executeFetchRequest:request error:NULL]) [left addObject:[study valueForKey:@"studyName"]];
    return [left sortedArrayUsingSelector:@selector(compare:)];
}
// run DIRECTORY CASE: one case of DIRECTORY/cases.json on the store of DIRECTORY; what happened goes to stdout.
static void runCase(NSString *directory, int number) {
    NSDictionary *c=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"cases.json"]] options:0 error:NULL][number];
    fixtureDirectory=directory;
    NSString *dataFolder=[directory stringByAppendingPathComponent:@"db"];
    NSPersistentStoreCoordinator *psc=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:fixtureModel()];
    check([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"index.sqlite"]] options:@{NSSQLitePragmasOption:@{@"journal_mode":@"DELETE"}} error:NULL]!=nil,@"open SQLite");
    N2ManagedObjectContext *ctx=[[N2ManagedObjectContext alloc] initWithDatabase:nil concurrencyType:NSConfinementConcurrencyType];ctx.persistentStoreCoordinator=psc;
    DicomDatabase *db=[DicomDatabase new];db.managedObjectContext=ctx;db.dataBaseDirPath=dataFolder;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSDictionary *preferences=c[@"preferences"];
    for (NSString *key in preferences) [defaults setObject:preferences[key] forKey:key];
    // The free space: below the request until `enough_after` studies are gone.
    unsigned long long requested=[c[@"requested"] unsignedLongLongValue];
    int enoughAfter=[c[@"enough_after"] intValue];
    deletedStudies=[NSMutableArray array];
    NSMutableArray *deleted=deletedStudies;
    capacityOverride=^NSDictionary *{
        BOOL enough=enoughAfter>=0 && (int)deleted.count>=enoughAfter;
        return @{NSFileSystemSize:@(1000ULL*1024*1024), NSFileSystemFreeSize:@((enough ? requested+500 : requested-1)*1024*1024)};
    };
    __block int notifications=0;
    id token=[NSNotificationCenter.defaultCenter addObserverForName:_O2AddToDBAnywayNotification object:db queue:nil usingBlock:^(NSNotification *n){notifications++;}];
    NSDictionary *preview=[db automaticCleanupPreview];
    NSMutableArray *rows=[NSMutableArray array];
    for (NSDictionary *row in preview[@"rows"]) {
        NSDate *date=row[@"date"];
        [rows addObject:@{@"rule":orNull(row[@"rule"]), @"patient":orNull(row[@"patient"]), @"study":orNull(row[@"study"]), @"uid":orNull(row[@"uid"]),
                          @"date":[date isKindOfClass:NSDate.class] ? @(date.timeIntervalSinceReferenceDate) : NSNull.null}];
    }
    if ([c[@"run"] isEqual:@"space"]) [db cleanForFreeSpaceMB:(NSInteger)requested];
    else [db cleanOldStuff];
    NSManagedObjectContext *reader=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];reader.persistentStoreCoordinator=psc;
    NSMutableArray *files=[NSMutableArray array];
    for (NSString *file in [NSFileManager.defaultManager subpathsAtPath:directory])
        if ([file.pathExtension isEqual:@"dcm"]) [files addObject:file];
    NSDictionary *result=@{@"summary":orNull(preview[@"summary"]), @"rows":rows, @"failed":@(preview[@"error"]!=nil), @"deleted":deleted,
                           @"left":leftStudies(reader), @"files":[files sortedArrayUsingSelector:@selector(compare:)], @"notifications":@(notifications)};
    [NSNotificationCenter.defaultCenter removeObserver:token];
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
    printf("RESULT %s\n",[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
    fflush(stdout);
}
void harness_main(int argc, char **argv) { @autoreleasepool {
    NSString *directory=[NSString stringWithUTF8String:argv[2]];
    method_exchangeImplementations(class_getInstanceMethod(NSFileManager.class,@selector(attributesOfFileSystemForPath:error:)),class_getInstanceMethod(NSFileManager.class,@selector(fixtureAttributes:error:)));
    if (strcmp(argv[1],"generate")==0) generate(directory);
    else runCase(directory,atoi(argv[3]));
} }
'''


def studies(seed, count, patients):
    """`count` study descriptions of one store. Hours are ages, at half a day
    from any whole day and far from the two hours of the space rule, so that the
    minutes between making the store and running a case decide nothing."""
    rng = random.Random(seed)
    uids = ['PATIENT', 'patient', 'PÁTIENT', 'ＰＡＴＩＥＮＴ', 'OTHER', 'Other', 'ZED', '', 'a', 'B']
    described = []
    for i in range(count):
        def chance(p):
            return rng.random() < p

        def age(low, high):
            return 24 * rng.randint(low, high) + 12
        added = rng.choice([None] * 1 + [1, 3] * 2 + [age(2, 6)] * 2 + [age(8, 3000)] * 13)
        if patients == 'distinct':
            uid = 'P%04d' % rng.randrange(100000)
        else:
            uid = None if patients == 'with-none' and chance(0.08) else (rng.choice(uids) if chance(0.5) else 'P%03d' % rng.randrange(count))
        linked = chance(0.3)
        described.append({
            'patientUID': uid, 'patientID': 'ID%d' % i, 'name': None if chance(0.1) else 'SYNTHETIC^%d' % i, 'studyName': 'STUDY%04d' % i,
            'date': None if chance(0.08) else age(0, 3000), 'dateOpened': None if chance(0.5) else age(0, 400), 'dateAdded': added,
            'lockedStudy': rng.choice([None, 0, 0, 0, 1]), 'album': chance(0.1),
            'comment': rng.choice([None] * 5 + ['', 'keep this', 'KEEP', 'other text']),
            'comment2': 'second' if chance(0.05) else None, 'comment3': '' if chance(0.05) else None, 'comment4': 'fourth' if chance(0.05) else None,
            'path': ('linked/image%04d.dcm' if linked else 'db/image%04d.dcm') % i, 'inDatabaseFolder': 0 if linked else 1,
        })
    return described


# dontDeleteStudiesIfInAlbum is only read by the previous revision.
BASE = {'LOGCLEANINGDAYS': 30, 'AUTOCLEANINGDATEPRODUCEDDAYS': '30', 'AUTOCLEANINGDATEOPENEDDAYS': '30', 'AUTOCLEANINGDATE': False,
        'AUTOCLEANINGDATEPRODUCED': False, 'AUTOCLEANINGDATEOPENED': False, 'AUTOCLEANINGCOMMENTS': False, 'AUTOCLEANINGDONTCONTAIN': 0,
        'dontDeleteStudiesWithComments': False, 'dontDeleteStudiesIfInAlbum': False, 'AUTOCLEANINGDELETEORIGINAL': False,
        'AUTOCLEANINGSPACE': False, 'AUTOCLEANINGSPACESIZE': '100'}


def case(run, requested=100, enough_after=-1, **preferences):
    return {'run': run, 'requested': requested, 'enough_after': enough_after, 'preferences': {**BASE, **preferences}}


def cases():
    """The preferences that decide what goes, and what stops the rules."""
    date = dict(AUTOCLEANINGDATE=True, AUTOCLEANINGDATEPRODUCED=True)
    both = dict(date, AUTOCLEANINGDATEOPENED=True)
    opened = dict(AUTOCLEANINGDATE=True, AUTOCLEANINGDATEOPENED=True)
    space = dict(AUTOCLEANINGSPACE=True)
    found = []
    for condition in (date, opened, both):
        for days in ('2', '30', '365', '1095'):
            found.append(case('pass', **condition, AUTOCLEANINGDATEPRODUCEDDAYS=days, AUTOCLEANINGDATEOPENEDDAYS=days))
    found += [
        case('pass', **date, dontDeleteStudiesWithComments=True),
        case('pass', **date, dontDeleteStudiesIfInAlbum=True),
        case('pass', **both, dontDeleteStudiesWithComments=True, dontDeleteStudiesIfInAlbum=True, AUTOCLEANINGDELETEORIGINAL=True),
        case('pass', **date, AUTOCLEANINGDELETEORIGINAL=True),
        case('pass', **date, AUTOCLEANINGCOMMENTS=True, AUTOCLEANINGCOMMENTSTEXT='keep', AUTOCLEANINGDONTCONTAIN=0),
        case('pass', **date, AUTOCLEANINGCOMMENTS=True, AUTOCLEANINGCOMMENTSTEXT='keep', AUTOCLEANINGDONTCONTAIN=1),
        case('pass', **date, AUTOCLEANINGCOMMENTS=True, AUTOCLEANINGCOMMENTSTEXT='KEEP THIS', AUTOCLEANINGDONTCONTAIN=2),
        case('pass', **date, AUTOCLEANINGCOMMENTS=True, AUTOCLEANINGCOMMENTSTEXT='', AUTOCLEANINGDONTCONTAIN=0),
        case('pass', **date, AUTOCLEANINGCOMMENTS=True),  # no text at all: the rule stops, the pass goes on
        case('pass', **date, LOGCLEANINGDAYS=1),  # retention periods that pause everything
        case('pass', **date, AUTOCLEANINGDATEPRODUCEDDAYS='1'),
        case('pass', AUTOCLEANINGDATE=True),  # no condition selected
        case('pass', **date, AUTOCLEANINGDATEPRODUCEDDAYS='40000'),  # the 32-bit arithmetic
    ]
    for mode in (0, 1, 2, 7, '1', '2'):
        found.append(case('space', **space, AutocleanSpaceMode=mode))
    found += [
        case('space', **space),
        case('space', **space, AutocleanSpaceMode=['not', 'a', 'mode']),
        case('space', **space, dontDeleteStudiesWithComments=True),
        case('space', **space, dontDeleteStudiesIfInAlbum=True),
        case('space', **space, AUTOCLEANINGDELETEORIGINAL=True),
    ]
    for enough_after in (0, 1, 3, 10, 49, 50):
        found.append(case('space', enough_after=enough_after, **space, AutocleanSpaceMode=2))
    found += [
        case('pass', **date, **space, AutocleanSpaceMode=0),  # the date rule, then the space rule
        case('pass', **both, **space, AutocleanSpaceMode=1, enough_after=5),
        case('pass', **date, **space, AutocleanSpaceMode=['not', 'a', 'mode']),
        case('pass', **space, AutocleanSpaceMode=2, AUTOCLEANINGSPACESIZE='-10'),  # a percentage of the volume
        case('pass', **space, AUTOCLEANINGSPACESIZE='1e309'),
    ]
    return found


def stores(folder, binary):
    """The stores, each made once by `binary`, and the folder of each."""
    made = []
    for name, seed, count, patients in (('mixed', 1607, 90, 'pool'), ('no-uid', 1608, 60, 'with-none'), ('many', 1609, 240, 'distinct')):
        store = folder / 'stores' / name
        (store / 'db').mkdir(parents=True)
        (store / 'linked').mkdir()
        described = studies(seed, count, patients)
        (store / 'studies.json').write_text(json.dumps(described))
        (store / 'cases.json').write_text(json.dumps(cases()))
        for study in described:
            (store / study['path']).write_text('original pixels')
        subprocess.run([str(binary), 'generate', str(store)], check=True, capture_output=True, timeout=120)
        made.append(store)
    return made


def run_case(binary, store, number, work):
    """What `binary` did with case `number`, on a copy of `store`."""
    copy = work / 'run'
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(store, copy)
    result = subprocess.run([str(binary), 'run', str(copy), str(number)], capture_output=True, text=True, timeout=120)
    lines = [line for line in result.stdout.splitlines() if line.startswith('RESULT ')]
    if result.returncode != 0 or not lines:
        return {'crashed': result.returncode, 'stderr': result.stderr[-500:]}
    return json.loads(lines[-1][len('RESULT '):])


def comparable(result, case_of):
    """The result as compared: the date rule commits several studies at once,
    in no order of its own, and only the space rule alone gives an order."""
    if 'crashed' in result or case_of['run'] == 'space':
        return result
    return {**result, 'deleted': sorted(result['deleted'])}


def baseline_results(binary, made, work):
    every_case = cases()
    return {(store.name, number): comparable(run_case(binary, store, number, work), every_case[number])
            for store in made for number in range(len(every_case))}


def differences(binary, made, expected, work):
    every_case = cases()
    found = []
    for store in made:
        for number in range(len(every_case)):
            got = comparable(run_case(binary, store, number, work), every_case[number])
            if got != expected[(store.name, number)]:
                found.append((store.name, number, got))
    return found


def describe(store, number, got, expected):
    keys = [key for key in sorted(set(got) | set(expected)) if got.get(key) != expected.get(key)]
    return f'{store} case {number} {json.dumps(cases()[number]["preferences"])[:160]}: differs in {keys}'


def mutant(folder, mutation, library, archives):
    """The current code with `mutation` in the policy, in `folder`."""
    name, text, replacement = mutation
    source = POLICY.read_text(encoding='utf-8')
    if text not in source:
        raise SystemExit(f'FAIL: the negative control no longer applies: {text!r} is not in the policy')
    changed = folder / 'sources' / POLICY.name
    changed.parent.mkdir(parents=True)
    changed.write_text(source.replace(text, replacement), encoding='utf-8')
    modules = folder / 'modules'
    real = isix_modules.module_sources
    isix_modules.module_sources = lambda module: [changed if path.name == POLICY.name else path for path in real(module)]
    try:
        isix_modules.build_module('IsiXDatabase', modules, ['-target', 'arm64-apple-macos15.0'])
    finally:
        isix_modules.module_sources = real
    linked = [str(modules / Path(archive).name) if Path(archive).name == 'libIsiXDatabase.a' else archive for archive in archives]
    autoclean_harness.compile_objc(folder, DRIVER + harness_defaults.OBJC, library)
    return autoclean_harness.compile_swift(folder, autoclean_harness.CURRENT_SOURCES, library, linked, modules=modules)


def on_purpose(source, *differences_applied):
    """`source` of the previous revision with the differences on purpose, each of whose lines must be there once."""
    for text, replacement in (line for difference in differences_applied for line in difference):
        if source.count(text) != 1:
            raise SystemExit(f'FAIL: the difference on purpose no longer applies: {text!r} is not in the reference once')
        source = source.replace(text, replacement)
    return source


def compile_reference(folder, source, library, archives):
    """The previous revision, with `source` as its rules, in `folder`."""
    autoclean_harness.compile_objc(folder, DRIVER + harness_defaults.OBJC, library)
    (folder / 'source').mkdir()
    path = folder / 'source' / 'DicomDatabase+Clean.swift'
    path.write_text(source, encoding='utf-8')
    return autoclean_harness.compile_swift(folder, [path], library, archives)


def has_spellings(store):
    """Whether two studies of `store` hold one UID spelled differently."""
    def folded(uid):
        return ''.join(c for c in unicodedata.normalize('NFKD', uid) if not unicodedata.combining(c)).casefold()
    uids = {study['patientUID'] for study in json.loads((store / 'studies.json').read_text())} - {None}
    return len({folded(uid) for uid in uids}) < len(uids)


def has_patient_lacking_a_date(store):
    """Whether a patient of several studies in `store` has one with no date a condition reads."""
    def folded(uid):
        return ''.join(c for c in unicodedata.normalize('NFKD', uid) if not unicodedata.combining(c)).casefold()
    patients = {}
    for study in json.loads((store / 'studies.json').read_text()):
        if study['patientUID'] is not None:
            patients.setdefault(folded(study['patientUID']), []).append(study)
    return any(len(group) > 1 and any(s['date'] is None or (s['dateOpened'] is None and s['dateAdded'] is None) for s in group)
               for group in patients.values())


def only_spares(results, before, name):
    """The cases `results` changes from `before`, the date passes below the limit
    among them and the studies those keep, which must be some, and none deleted more."""
    changed = [key for key, result in results.items() if result != before[key]]
    if not changed:
        raise SystemExit(f'FAIL: no case shows {name}')

    def date_rule_alone(key):
        return cases()[key[1]]['run'] == 'pass' and not cases()[key[1]]['preferences']['AUTOCLEANINGSPACE']
    below_limit = [key for key in changed if date_rule_alone(key)
                   and len(results[key]['deleted']) < 50 and len(before[key]['deleted']) < 50]
    more = [key for key in below_limit if set(results[key]['deleted']) - set(before[key]['deleted'])]
    if more:
        raise SystemExit(f'FAIL: {name} deleted a study more in {more[:5]}')
    kept = sum(len(set(before[key]['deleted']) - set(results[key]['deleted'])) for key in below_limit)
    if not kept:
        raise SystemExit(f'FAIL: no date pass below the limit keeps a study by {name}')
    return changed, below_limit, kept


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--reference', default=PREVIOUS)
    parser.add_argument('--negative-control', action='store_true', help='check every mutation, not only those of the differences on purpose')
    arguments = parser.parse_args()
    shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{arguments.reference}:Horos/Sources/DicomDatabase+Clean.swift'],
                           capture_output=True, text=True)
    if shown.returncode != 0 or 'dateCleanupCandidates' not in shown.stdout:
        print(f'skipped: git does not have the rules at {arguments.reference}', file=sys.stderr)
        sys.exit(SKIPPED)

    with tempfile.TemporaryDirectory(prefix='horos-autoclean-equivalence-') as temporary:
        folder = Path(temporary)
        library, archives = autoclean_harness.library(folder)

        old = compile_reference(folder / 'previous', shown.stdout, library, archives)
        own_group = compile_reference(folder / 'own-group', on_purpose(shown.stdout, OWN_GROUP), library, archives)
        joined = compile_reference(folder / 'patient-order', on_purpose(shown.stdout, OWN_GROUP, PATIENT_ORDER), library, archives)
        whole = compile_reference(folder / 'whole-group', on_purpose(shown.stdout, OWN_GROUP, PATIENT_ORDER, WHOLE_GROUP), library, archives)

        current = folder / 'current'
        autoclean_harness.compile_objc(current, DRIVER + harness_defaults.OBJC, library)
        new = autoclean_harness.compile_swift(current, autoclean_harness.CURRENT_SOURCES, library, archives)

        made = stores(folder, new)
        work = folder / 'work'
        work.mkdir()
        as_it_was = baseline_results(old, made, work)
        with_no_uid = [store for store in made
                       if any(study['patientUID'] is None for study in json.loads((store / 'studies.json').read_text()))]
        alone = baseline_results(own_group, with_no_uid, work)
        with_spellings = [store for store in made if has_spellings(store)]
        before_joining = {**as_it_was, **alone}
        ordered = baseline_results(joined, with_spellings, work)
        before_whole = {**before_joining, **ordered}
        with_undated = [store for store in made if has_patient_lacking_a_date(store)]
        held = baseline_results(whole, with_undated, work)
        crashed = [(key, result) for results in (as_it_was, alone, ordered, held) for key, result in results.items() if 'crashed' in result]
        if crashed:
            raise SystemExit(f'FAIL: the previous revision did not run {[key for key, _ in crashed[:5]]}: {crashed[0][1]}')

        changed = [key for key, result in alone.items() if result != as_it_was[key]]
        if not changed:
            raise SystemExit('FAIL: no case shows the study with no UID alone')
        taken = sum(len(set(alone[key]['deleted']) - set(as_it_was[key]['deleted'])) for key in changed)
        spared = sum(len(set(as_it_was[key]['deleted']) - set(alone[key]['deleted'])) for key in changed)

        rejoined, below_limit, kept = only_spares(ordered, before_joining, 'a patient joined by the order')
        unjudged, undated_below_limit, undated_kept = only_spares(held, before_whole, 'a patient held back by a missing date')
        expected = {**before_whole, **held}

        # The fixture has to reach what the comparison is about.
        reached = {
            'a limit of 50 studies by date': any(len(r['deleted']) == 50 and cases()[k[1]]['run'] == 'pass' for k, r in expected.items()),
            'a limit of 50 studies by space': any(len(r['deleted']) == 50 and cases()[k[1]]['run'] == 'space' for k, r in expected.items()),
            'a space rule stopped by the free space': any(0 < len(r['deleted']) < 50 and cases()[k[1]]['run'] == 'space' for k, r in expected.items()),
            'a preview that lists both rules': any(len({row['rule'] for row in r['rows']}) == 2 for r in expected.values()),
            'a rule that could not be evaluated': any(r['failed'] for r in expected.values()),
        }
        missing = [name for name, seen in reached.items() if not seen]
        if missing:
            raise SystemExit(f'FAIL: the fixture does not reach {missing}')

        found = differences(new, made, expected, work)
        for store, number, got in found[:10]:
            print(describe(store, number, got, expected[(store, number)]))
            for key in sorted(set(got) | set(expected[(store, number)])):
                if got.get(key) != expected[(store, number)].get(key):
                    print(f'  {key}: was {str(expected[(store, number)].get(key))[:300]}')
                    print(f'  {key}: now {str(got.get(key))[:300]}')
        if found:
            raise SystemExit(f'FAIL: {len(found)} of {len(expected)} cases delete differently from {arguments.reference}')
        deleted = sum(len(result['deleted']) for result in expected.values())
        print(f'PASS: {len(expected)} cases over {len(made)} stores delete the same {deleted} studies as {arguments.reference}, in the same order,')
        print(f'with a study with no UID as a group of its own in {len(with_no_uid)} store(s): that alone changes {len(changed)} cases, '
              f'which delete {taken} studies more and {spared} fewer;')
        print(f'and with the order of the groups in {len(with_spellings)} store(s): that changes {len(rejoined)} more cases, '
              f'and the {len(below_limit)} date passes below the limit among them keep {kept} studies and delete none more;')
        print(f'and with a patient held back by a missing date in {len(with_undated)} store(s): that changes {len(unjudged)} more cases, '
              f'and the {len(undated_below_limit)} date passes below the limit among them keep {undated_kept} studies and delete none more')

        controls = MUTATIONS if arguments.negative_control else MUTATIONS[:ON_PURPOSE]
        survived = []
        for index, mutation in enumerate(controls):
            binary = mutant(folder / f'mutant{index}', mutation, library, archives)
            caught = differences(binary, made, expected, work)
            print(f'negative control: {mutation[0]}: {len(caught)} of {len(expected)} cases differ')
            if not caught:
                survived.append(mutation[0])
        if survived:
            raise SystemExit(f'FAIL: the comparison does not notice: {survived}')


if __name__ == '__main__':
    main()
