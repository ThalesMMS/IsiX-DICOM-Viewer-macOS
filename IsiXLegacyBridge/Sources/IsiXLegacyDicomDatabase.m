//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.
//
// The database a legacy plugin sees, and the database window. There is no
// store in the plugin: the kit's context has a model of the legacy entities
// (Study, Series, Image, Album) for NSEntityDescription and NSFetchRequest,
// and evaluates each fetch over the objects the plugin API returns, with the
// request's predicate, sort descriptors, offset and limit. A fetch of series
// or images goes through every study, and is as slow as the database is big;
// a plugin that knows its study reads its series instead.

#import "IsiXLegacyBridgeInternal.h"

static IsiXLegacyDatabaseBridge *Bridge(void) { return [IsiXLegacyDatabaseBridge shared]; }

#pragma mark - The kit's context

ISIX_LEGACY_CLASS(ManagedObjectContext)
@interface IsiXLegacyManagedObjectContext : NSManagedObjectContext
@end

@implementation IsiXLegacyManagedObjectContext

- (NSArray*) executeFetchRequest: (NSFetchRequest*) request error: (NSError**) error
{
    return [[IsiXLegacyDicomDatabase defaultDatabase] isixObjectsForFetchRequest: request];
}

- (NSUInteger) countForFetchRequest: (NSFetchRequest*) request error: (NSError**) error
{
    NSFetchRequest *all = [request copy];
    all.resultType = NSManagedObjectResultType;
    return [[IsiXLegacyDicomDatabase defaultDatabase] isixObjectsForFetchRequest: all].count;
}

- (NSManagedObject*) objectWithID: (NSManagedObjectID*) objectID
{
    return [(id) objectID isKindOfClass: [IsiXLegacyDatabaseObject class]] ? (id) objectID : nil;
}

- (NSManagedObject*) existingObjectWithID: (NSManagedObjectID*) objectID error: (NSError**) error
{
    return [self objectWithID: objectID];
}

- (BOOL) save: (NSError**) error { return YES; }
- (BOOL) hasChanges { return NO; }

@end

#pragma mark - DicomDatabase

@implementation IsiXLegacyDicomDatabase
{
    NSManagedObjectModel *model;
    NSManagedObjectContext *context;
    NSRecursiveLock *lock;
}

@synthesize name;

+ (IsiXLegacyDicomDatabase*) defaultDatabase
{
    static IsiXLegacyDicomDatabase *database;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ database = [[IsiXLegacyDicomDatabase alloc] init]; });
    return database;
}

+ (IsiXLegacyDicomDatabase*) activeLocalDatabase { return [self defaultDatabase]; }
+ (IsiXLegacyDicomDatabase*) databaseForContext: (NSManagedObjectContext*) c { return [self defaultDatabase]; }
+ (NSArray*) allDatabases { return @[[self defaultDatabase]]; }

/// The legacy entities, with the attributes the kit's objects answer.
+ (NSManagedObjectModel*) isixModel
{
    NSEntityDescription *study = [[NSEntityDescription alloc] init], *series = [[NSEntityDescription alloc] init];
    NSEntityDescription *image = [[NSEntityDescription alloc] init], *album = [[NSEntityDescription alloc] init];
    NSAttributeDescription* (^attribute)(NSString*, NSAttributeType) = ^(NSString *n, NSAttributeType type) {
        NSAttributeDescription *made = [[NSAttributeDescription alloc] init];
        made.name = n;
        made.attributeType = type;
        made.optional = YES;
        return made;
    };
    NSRelationshipDescription* (^relationship)(NSString*, NSEntityDescription*, BOOL) = ^(NSString *n, NSEntityDescription *to, BOOL many) {
        NSRelationshipDescription *made = [[NSRelationshipDescription alloc] init];
        made.name = n;
        made.destinationEntity = to;
        made.minCount = 0;
        made.maxCount = many ? 0 : 1;
        made.optional = YES;
        return made;
    };
    NSArray* (^attributes)(NSDictionary<NSString*, NSNumber*>*) = ^(NSDictionary<NSString*, NSNumber*> *types) {
        NSMutableArray *made = [NSMutableArray array];
        for (NSString *key in types) [made addObject: attribute(key, types[key].unsignedIntegerValue)];
        return made;
    };
    NSNumber *text = @(NSStringAttributeType), *date = @(NSDateAttributeType), *integer = @(NSInteger32AttributeType);
    NSNumber *flag = @(NSBooleanAttributeType), *real = @(NSFloatAttributeType);
    NSDictionary *comments = @{@"comment": text, @"comment2": text, @"comment3": text, @"comment4": text};

    study.name = @"Study";
    study.managedObjectClassName = NSStringFromClass([IsiXLegacyDicomStudy class]);
    NSMutableDictionary *studyTypes = [comments mutableCopy];
    [studyTypes addEntriesFromDictionary: @{@"accessionNumber": text, @"date": date, @"dateAdded": date, @"dateOfBirth": date,
                                            @"hasDICOM": flag, @"id": text, @"institutionName": text, @"lockedStudy": flag,
                                            @"modality": text, @"name": text, @"numberOfImages": integer, @"patientID": text,
                                            @"patientSex": text, @"patientUID": text, @"performingPhysician": text,
                                            @"referringPhysician": text, @"reportURL": text, @"stateText": integer,
                                            @"studyInstanceUID": text, @"studyName": text}];
    series.name = @"Series";
    series.managedObjectClassName = NSStringFromClass([IsiXLegacyDicomSeries class]);
    NSMutableDictionary *seriesTypes = [comments mutableCopy];
    [seriesTypes addEntriesFromDictionary: @{@"date": date, @"id": integer, @"modality": text, @"name": text,
                                             @"numberOfImages": integer, @"seriesDescription": text, @"seriesDICOMUID": text,
                                             @"seriesInstanceUID": text, @"seriesSOPClassUID": text, @"stateText": integer}];
    image.name = @"Image";
    image.managedObjectClassName = NSStringFromClass([IsiXLegacyDicomImage class]);
    NSMutableDictionary *imageTypes = [comments mutableCopy];
    [imageTypes addEntriesFromDictionary: @{@"date": date, @"frameID": integer, @"instanceNumber": integer, @"sliceLocation": real,
                                            @"storedIsKeyImage": flag, @"modality": text, @"numberOfFrames": integer}];
    album.name = @"Album";
    album.managedObjectClassName = NSStringFromClass([IsiXLegacyDicomAlbum class]);

    NSRelationshipDescription *studySeries = relationship(@"series", series, YES), *seriesStudy = relationship(@"study", study, NO);
    NSRelationshipDescription *seriesImages = relationship(@"images", image, YES), *imageSeries = relationship(@"series", series, NO);
    NSRelationshipDescription *studyAlbums = relationship(@"albums", album, YES), *albumStudies = relationship(@"studies", study, YES);
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries;
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages;
    studyAlbums.inverseRelationship = albumStudies; albumStudies.inverseRelationship = studyAlbums;
    study.properties = [attributes(studyTypes) arrayByAddingObjectsFromArray: @[studySeries, studyAlbums]];
    series.properties = [attributes(seriesTypes) arrayByAddingObjectsFromArray: @[seriesStudy, seriesImages]];
    image.properties = [attributes(imageTypes) arrayByAddingObject: imageSeries];
    album.properties = [attributes(@{@"name": text, @"smartAlbum": flag}) arrayByAddingObject: albumStudies];

    NSManagedObjectModel *made = [[NSManagedObjectModel alloc] init];
    made.entities = @[study, series, image, album];
    return made;
}

- (instancetype) init
{
    if (!(self = [super init])) return nil;
    model = [IsiXLegacyDicomDatabase isixModel];
    context = [[IsiXLegacyManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType];
    context.persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model];
    lock = [[NSRecursiveLock alloc] init];
    name = @"Local Database";
    return self;
}

- (NSManagedObjectContext*) managedObjectContext { return context; }
- (NSManagedObjectModel*) managedObjectModel { return model; }
- (BOOL) isLocal { return YES; }
- (BOOL) isReadOnly { return ![Bridge() isAvailable]; }

#pragma mark Folders

/// A folder of the kit, made when first asked for.
- (NSString*) isixFolder: (NSString*) folder
{
    NSString *path = folder ? [[IsiXLegacyDatabaseBridge temporaryFolderPath] stringByAppendingPathComponent: folder]
                            : [IsiXLegacyDatabaseBridge temporaryFolderPath];
    [[NSFileManager defaultManager] createDirectoryAtPath: path withIntermediateDirectories: YES attributes: nil error: NULL];
    return path;
}

- (NSString*) baseDirPath { return [self isixFolder: nil]; }
- (NSString*) dataBaseDirPath { return [self isixFolder: nil]; }
- (NSString*) dataDirPath { return [self isixFolder: @"DATABASE.noindex"]; }
- (NSString*) incomingDirPath { return [self isixFolder: @"INCOMING.noindex"]; }
- (NSString*) tempDirPath { return [self isixFolder: @"TEMP.noindex"]; }

#pragma mark Entities and fetches

- (NSEntityDescription*) entityForName: (NSString*) entityName { return model.entitiesByName[entityName]; }
- (NSEntityDescription*) studyEntity { return [self entityForName: @"Study"]; }
- (NSEntityDescription*) seriesEntity { return [self entityForName: @"Series"]; }
- (NSEntityDescription*) imageEntity { return [self entityForName: @"Image"]; }
- (NSEntityDescription*) albumEntity { return [self entityForName: @"Album"]; }

/// Every object of an entity, from the plugin API.
- (NSArray*) isixAllObjectsOfEntity: (NSString*) entityName
{
    if ([entityName isEqualToString: @"Album"]) return [self albums];
    NSArray *studies = [IsiXLegacyDatabaseObject isixObjectsWithRecords: [Bridge() allStudies] entity: IsiXLegacyEntityStudy];
    if ([entityName isEqualToString: @"Study"]) return studies;
    NSMutableArray *series = [NSMutableArray array];
    for (IsiXLegacyDicomStudy *study in studies) [series addObjectsFromArray: study.series.allObjects];
    if ([entityName isEqualToString: @"Series"]) return series;
    if ([entityName isEqualToString: @"Image"])
    {
        NSMutableArray *images = [NSMutableArray array];
        for (IsiXLegacyDicomSeries *one in series) [images addObjectsFromArray: one.sortedImages];
        return images;
    }
    [Bridge() fail: [NSString stringWithFormat: @"The database has no entity %@.", entityName]];
    return @[];
}

- (NSArray*) isixObjectsForFetchRequest: (NSFetchRequest*) request
{
    NSString *entityName = request.entityName ?: request.entity.name;
    NSArray *objects = [self isixAllObjectsOfEntity: entityName];
    if (request.predicate) objects = [objects filteredArrayUsingPredicate: request.predicate];
    if (request.sortDescriptors.count) objects = [objects sortedArrayUsingDescriptors: request.sortDescriptors];
    if (request.fetchOffset > 0)
        objects = request.fetchOffset < objects.count ? [objects subarrayWithRange: NSMakeRange(request.fetchOffset, objects.count - request.fetchOffset)] : @[];
    if (request.fetchLimit > 0 && objects.count > request.fetchLimit) objects = [objects subarrayWithRange: NSMakeRange(0, request.fetchLimit)];
    switch (request.resultType)
    {
        case NSCountResultType:
            return @[@(objects.count)];
        case NSDictionaryResultType:
        {
            NSMutableArray *rows = [NSMutableArray array];
            NSArray *keys = [request.propertiesToFetch valueForKey: @"name"] ?: [self isixAttributeNamesOfEntity: entityName];
            for (id object in objects) [rows addObject: [object dictionaryWithValuesForKeys: keys]];
            return rows;
        }
        default:
            return objects;
    }
}

/// The attribute names of an entity, for a dictionary fetch without properties.
- (NSArray*) isixAttributeNamesOfEntity: (NSString*) entityName
{
    return model.entitiesByName[entityName].attributesByName.allKeys;
}


- (NSString*) isixEntityName: (id) e
{
    return [e isKindOfClass: [NSEntityDescription class]] ? [(NSEntityDescription*) e name] : e;
}

- (NSArray*) objectsForEntity: (id) e predicate: (NSPredicate*) p error: (NSError**) err
{
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName: [self isixEntityName: e]];
    request.predicate = p;
    return [self isixObjectsForFetchRequest: request];
}

- (NSArray*) objectsForEntity: (id) e predicate: (NSPredicate*) p { return [self objectsForEntity: e predicate: p error: NULL]; }
- (NSArray*) objectsForEntity: (id) e { return [self objectsForEntity: e predicate: nil error: NULL]; }
- (NSUInteger) countObjectsForEntity: (id) e predicate: (NSPredicate*) p { return [self objectsForEntity: e predicate: p].count; }
- (NSUInteger) countObjectsForEntity: (id) e { return [self countObjectsForEntity: e predicate: nil]; }

- (id) objectWithID: (id) oid { return [oid isKindOfClass: [IsiXLegacyDatabaseObject class]] ? oid : nil; }

- (NSArray*) objectsWithIDs: (NSArray*) objectIDs
{
    NSMutableArray *objects = [NSMutableArray array];
    for (id oid in objectIDs) if ([self objectWithID: oid]) [objects addObject: oid];
    return objects;
}

- (BOOL) save { return YES; }
- (BOOL) save: (NSError**) err { return YES; }
- (void) lock { [lock lock]; }
- (void) unlock { [lock unlock]; }
- (BOOL) tryLock { return [lock tryLock]; }

#pragma mark Albums

- (NSArray*) albums
{
    return [IsiXLegacyDatabaseObject isixObjectsWithRecords: [Bridge() albums] entity: IsiXLegacyEntityAlbum];
}

- (void) addStudies: (NSArray*) dicomStudies toAlbum: (IsiXLegacyDicomAlbum*) dicomAlbum
{
    [dicomAlbum addStudies: [NSSet setWithArray: dicomStudies ?: @[]]];
}

- (IsiXLegacyDicomAlbum*) newAlbumWithName: (NSString*) albumName
{
    return [IsiXLegacyDatabaseObject isixObjectWithRecord: [Bridge() createAlbumNamed: albumName] entity: IsiXLegacyEntityAlbum];
}

#pragma mark Files

/// The files, and the files in the folders, that are not hidden.
+ (NSArray*) isixFilesIn: (NSArray*) paths
{
    NSMutableArray *files = [NSMutableArray array];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (id item in paths)
    {
        NSString *path = [item isKindOfClass: [NSURL class]] ? [item path] : item;
        BOOL folder = NO;
        if (![path isKindOfClass: [NSString class]] || ![manager fileExistsAtPath: path isDirectory: &folder]) continue;
        if (!folder) { [files addObject: path]; continue; }
        NSDirectoryEnumerator *walk = [manager enumeratorAtPath: path];
        for (NSString *relative in walk)
        {
            NSString *file = [path stringByAppendingPathComponent: relative];
            BOOL inner = NO;
            if (![relative.lastPathComponent hasPrefix: @"."] && [manager fileExistsAtPath: file isDirectory: &inner] && !inner)
                [files addObject: file];
        }
    }
    return files;
}

- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications dicomOnly: (BOOL) dicomOnly rereadExistingItems: (BOOL) rereadExistingItems generatedByOsiriX: (BOOL) generatedByOsiriX returnArray: (BOOL) returnArray
{
    NSArray *files = [IsiXLegacyDicomDatabase isixFilesIn: paths];
    if (!files.count) return @[];
    return [IsiXLegacyDatabaseObject isixObjectsWithRecords: [Bridge() importFiles: files] entity: IsiXLegacyEntityImage];
}

- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications dicomOnly: (BOOL) dicomOnly rereadExistingItems: (BOOL) rereadExistingItems generatedByOsiriX: (BOOL) generatedByOsiriX
{
    return [self addFilesAtPaths: paths postNotifications: postNotifications dicomOnly: dicomOnly rereadExistingItems: rereadExistingItems generatedByOsiriX: generatedByOsiriX returnArray: YES];
}

- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications dicomOnly: (BOOL) dicomOnly rereadExistingItems: (BOOL) rereadExistingItems
{
    return [self addFilesAtPaths: paths postNotifications: postNotifications dicomOnly: dicomOnly rereadExistingItems: rereadExistingItems generatedByOsiriX: NO returnArray: YES];
}

- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications
{
    return [self addFilesAtPaths: paths postNotifications: postNotifications dicomOnly: YES rereadExistingItems: NO generatedByOsiriX: NO returnArray: YES];
}

- (NSArray*) addFilesAtPaths: (NSArray*) paths { return [self addFilesAtPaths: paths postNotifications: YES]; }

- (NSString*) uniquePathForNewDataFileWithExtension: (NSString*) ext
{
    return [Bridge() temporaryFilePathWithExtension: ext ?: @"dcm"];
}

@end

#pragma mark - BrowserController

@implementation IsiXLegacyBrowserController
{
    /// The image -findAndSelectFile:... chose, for -newViewerDICOM:.
    IsiXLegacyDicomImage *selectedImage;
}

+ (IsiXLegacyBrowserController*) currentBrowser
{
    static IsiXLegacyBrowserController *browser;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ browser = [[IsiXLegacyBrowserController alloc] init]; });
    return browser;
}

+ (NSArray*) statesArray { return @[@"empty", @"unread", @"reviewed", @"dictated", @"validated"]; }

- (IsiXLegacyDicomDatabase*) database { return [IsiXLegacyDicomDatabase defaultDatabase]; }
- (NSString*) documentsDirectory { return self.database.baseDirPath; }
- (NSString*) fixedDocumentsDirectory { return self.database.baseDirPath; }
- (NSString*) currentDatabasePath { return [self.database.baseDirPath stringByAppendingPathComponent: @"Database.sql"]; }
- (NSManagedObjectContext*) managedObjectContext { return self.database.managedObjectContext; }
- (NSManagedObjectContext*) localManagedObjectContext { return self.database.managedObjectContext; }
- (NSManagedObjectModel*) managedObjectModel { return self.database.managedObjectModel; }
- (long) saveDatabase { return 0; }
- (long) saveDatabase: (NSString*) path { return 0; }

#pragma mark Selection

- (NSArray*) databaseSelection
{
    NSMutableArray *selection = [NSMutableArray array];
    for (NSDictionary *record in [Bridge() selection])
        [selection addObject: [IsiXLegacyDatabaseObject isixObjectWithRecord: record entity: [record[@"type"] isEqualToString: @"Study"]
                                                                                             ? IsiXLegacyEntityStudy : IsiXLegacyEntitySeries]];
    return selection;
}

- (NSMutableArray*) filesForDatabaseOutlineSelection: (NSMutableArray*) correspondingManagedObjects onlyImages: (BOOL) onlyImages
{
    NSMutableArray *files = [NSMutableArray array];
    for (id item in self.databaseSelection)
    {
        NSArray *series = [item isKindOfClass: [IsiXLegacyDicomStudy class]]
            ? (onlyImages ? [item imageSeries] : [[item series] allObjects]) : @[item];
        for (IsiXLegacyDicomSeries *one in series)
            for (IsiXLegacyDicomImage *image in one.sortedImages)
            {
                if (!image.completePath) continue;
                [files addObject: image.completePath];
                [correspondingManagedObjects addObject: image];
            }
    }
    return files;
}

- (NSMutableArray*) filesForDatabaseOutlineSelection: (NSMutableArray*) correspondingManagedObjects
{
    return [self filesForDatabaseOutlineSelection: correspondingManagedObjects onlyImages: YES];
}

- (NSMutableArray*) filesForDatabaseMatrixSelection: (NSMutableArray*) correspondingManagedObjects onlyImages: (BOOL) onlyImages
{
    return [self filesForDatabaseOutlineSelection: correspondingManagedObjects onlyImages: onlyImages];
}

- (NSArray*) albums { return self.database.albums; }

#pragma mark Adding files

+ (NSArray*) addFiles: (NSArray*) newFilesArray toContext: (NSManagedObjectContext*) context toDatabase: (IsiXLegacyBrowserController*) browserController onlyDICOM: (BOOL) onlyDICOM notifyAddedFiles: (BOOL) notifyAddedFiles parseExistingObject: (BOOL) parseExistingObject dbFolder: (NSString*) dbFolder generatedByOsiriX: (BOOL) generatedByOsiriX
{
    return [[IsiXLegacyDicomDatabase defaultDatabase] addFilesAtPaths: newFilesArray postNotifications: notifyAddedFiles dicomOnly: onlyDICOM rereadExistingItems: parseExistingObject generatedByOsiriX: generatedByOsiriX];
}

+ (NSArray*) addFiles: (NSArray*) newFilesArray toContext: (NSManagedObjectContext*) context toDatabase: (IsiXLegacyBrowserController*) browserController onlyDICOM: (BOOL) onlyDICOM notifyAddedFiles: (BOOL) notifyAddedFiles parseExistingObject: (BOOL) parseExistingObject dbFolder: (NSString*) dbFolder
{
    return [self addFiles: newFilesArray toContext: context toDatabase: browserController onlyDICOM: onlyDICOM notifyAddedFiles: notifyAddedFiles parseExistingObject: parseExistingObject dbFolder: dbFolder generatedByOsiriX: NO];
}

+ (NSArray*) addFiles: (NSArray*) newFilesArray toContext: (NSManagedObjectContext*) context onlyDICOM: (BOOL) onlyDICOM notifyAddedFiles: (BOOL) notifyAddedFiles parseExistingObject: (BOOL) parseExistingObject dbFolder: (NSString*) dbFolder
{
    return [self addFiles: newFilesArray toContext: context toDatabase: [self currentBrowser] onlyDICOM: onlyDICOM notifyAddedFiles: notifyAddedFiles parseExistingObject: parseExistingObject dbFolder: dbFolder generatedByOsiriX: NO];
}

- (NSArray*) addFilesToDatabase: (NSArray*) newFilesArray onlyDICOM: (BOOL) onlyDICOM produceAddedFiles: (BOOL) produceAddedFiles parseExistingObject: (BOOL) parseExistingObject
{
    return [self.database addFilesAtPaths: newFilesArray postNotifications: produceAddedFiles dicomOnly: onlyDICOM rereadExistingItems: parseExistingObject];
}

- (NSArray*) addFilesToDatabase: (NSArray*) newFilesArray onlyDICOM: (BOOL) onlyDICOM produceAddedFiles: (BOOL) produceAddedFiles
{
    return [self addFilesToDatabase: newFilesArray onlyDICOM: onlyDICOM produceAddedFiles: produceAddedFiles parseExistingObject: NO];
}

- (NSArray*) addFilesToDatabase: (NSArray*) newFilesArray { return [self addFilesToDatabase: newFilesArray onlyDICOM: NO produceAddedFiles: YES]; }
- (NSArray*) addFilesAndFolderToDatabase: (NSArray*) filenames { return [self.database addFilesAtPaths: filenames]; }
- (NSString*) getNewFileDatabasePath: (NSString*) extension { return [self.database uniquePathForNewDataFileWithExtension: extension]; }
- (NSString*) getNewFileDatabasePath: (NSString*) extension dbFolder: (NSString*) dbFolder { return [self getNewFileDatabasePath: extension]; }
- (void) checkIncoming: (id) sender {}

#pragma mark Opening series

- (BOOL) findAndSelectFile: (NSString*) path image: (IsiXLegacyDicomImage*) curImage shouldExpand: (BOOL) expand extendingSelection: (BOOL) extendingSelection
{
    if (![curImage isKindOfClass: [IsiXLegacyDicomImage class]]) return NO;
    selectedImage = curImage;
    return YES;
}

- (BOOL) findAndSelectFile: (NSString*) path image: (IsiXLegacyDicomImage*) curImage shouldExpand: (BOOL) expand
{
    return [self findAndSelectFile: path image: curImage shouldExpand: expand extendingSelection: NO];
}

/// The series to open: of the image chosen last, else the first of the selection.
- (NSString*) isixSeriesToOpen
{
    if (selectedImage) return selectedImage.isixRecord[@"isixSeriesInstanceUID"];
    id first = self.databaseSelection.firstObject;
    if ([first isKindOfClass: [IsiXLegacyDicomStudy class]]) first = [first imageSeries].firstObject;
    return [first isKindOfClass: [IsiXLegacyDicomSeries class]] ? [first seriesDICOMUID] : nil;
}

- (void) newViewerDICOM: (id) sender
{
    NSString *series = [self isixSeriesToOpen];
    selectedImage = nil;
    if (series) (void) [Bridge() openViewerForSeries: series];
    else [Bridge() fail: @"Nothing is selected in the database to open."];
}

- (void) viewerDICOM: (id) sender { [self newViewerDICOM: sender]; }

- (IsiXLegacyViewerController*) loadSeries: (NSManagedObject*) curFile :(IsiXLegacyViewerController*) viewer :(BOOL) firstViewer keyImagesOnly: (BOOL) keyImages
{
    id object = curFile;
    if ([object isKindOfClass: [IsiXLegacyDicomImage class]]) object = [object series];
    if (![object isKindOfClass: [IsiXLegacyDicomSeries class]] || ![Bridge() openViewerForSeries: [object seriesDICOMUID]]) return nil;
    return [IsiXLegacyViewerController frontMostDisplayed2DViewer];
}

- (void) refreshDatabase: (id) sender {}
- (void) outlineViewRefresh {}
- (void) refreshAlbums {}

@end
