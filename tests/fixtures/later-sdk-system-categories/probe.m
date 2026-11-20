// A stand-in for a plugin: built without any header of the application, it
// sends each selector by name, as declared by the selector list, and checks
// what comes back. Usage: probe <list.json> <implemented.json>, the first every
// selector of these classes with its type encoding, the second those the
// library answers.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <compression.h>
#import <zlib.h>
#import "LaterSDKDecls.h"

static int failures = 0, checks = 0;
static NSMutableSet<NSString *> *exercised;
#define CHECK(condition) do { checks++; if (!(condition)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); } } while (0)
#define USE(entry) [exercised addObject:@entry]
#define EQ(a, b) [(a) isEqual:(b)]

static NSString *withoutDigits(const char *types) {
    NSMutableString *text = [NSMutableString string];
    for (const char *c = types; c && *c; c++) if (*c < '0' || *c > '9') [text appendFormat:@"%c", *c];
    return text;
}

static void spin(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
}

@interface Probe : NSObject
@property NSInteger count;
@property BOOL onMain;
@property (strong) id last;
@end
@implementation Probe
- (void)hit:(id)object { self.count++; self.onMain = [NSThread isMainThread]; self.last = object; }
- (void)notified:(NSNotification *)note { self.count++; }
@end

@interface RedView : NSView
@end
@implementation RedView
- (void)drawRect:(NSRect)rect { [[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] setFill]; NSRectFill(self.bounds); }
@end

static BOOL near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.03; }
static BOOL isColor(NSColor *color, CGFloat r, CGFloat g, CGFloat b) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    BOOL same = c && near(c.redComponent, r) && near(c.greenComponent, g) && near(c.blueComponent, b);
    if (!same) fprintf(stderr, "  colour %.3f %.3f %.3f alpha %.3f, expected %.3f %.3f %.3f\n", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent, r, g, b);
    return same;
}

// The samples of a pixel as the bitmap holds them, from 0 to 1, in the colour space of the bitmap:
// -colorAtX:y: hands them over labelled as generic RGB whatever that space is.
static BOOL isPixel(NSBitmapImageRep *rep, NSInteger x, NSInteger y, CGFloat r, CGFloat g, CGFloat b) {
    NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
    BOOL same = c && near(c.redComponent, r) && near(c.greenComponent, g) && near(c.blueComponent, b);
    if (!same) fprintf(stderr, "  pixel %.3f %.3f %.3f alpha %.3f, expected %.3f %.3f %.3f\n", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent, r, g, b);
    return same;
}

// 40 x 20 pixels, one pixel a point: the left half red, the right half blue.
static NSImage *twoHalves(void) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:40 pixelsHigh:20 bitsPerSample:8 samplesPerPixel:4
                                                                      hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    unsigned char *data = rep.bitmapData;
    for (int y = 0; y < 20; y++) for (int x = 0; x < 40; x++) {
        unsigned char *p = data + y * rep.bytesPerRow + x * 4;
        p[0] = x < 20 ? 255 : 0; p[1] = 0; p[2] = x < 20 ? 0 : 255; p[3] = 255;
    }
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(40, 20)];
    [image addRepresentation:[rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace]];
    return image;
}

static NSBitmapImageRep *bitmapOf(NSImage *image) {
    for (NSImageRep *rep in image.representations) if ([rep isKindOfClass:NSBitmapImageRep.class]) return (NSBitmapImageRep *)rep;
    return nil;
}

static void checkTypes(NSString *listPath, NSString *implementedPath) {
    NSArray *list = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:listPath] options:0 error:NULL];
    NSArray *implemented = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:implementedPath] options:0 error:NULL];
    CHECK(list.count >= implemented.count);
    CHECK(implemented.count > 0);
    NSMutableDictionary *byEntry = [NSMutableDictionary dictionary];
    for (NSDictionary *item in list) byEntry[item[@"entry"]] = item;
    NSMutableDictionary *protocols = [NSMutableDictionary dictionary];
    for (Protocol *protocol in LaterSDKProbeProtocols()) protocols[NSStringFromProtocol(protocol)] = protocol;
    int compared = 0, withList = 0;
    for (NSString *entry in implemented) {
        NSDictionary *item = byEntry[entry];
        if (!item) { failures++; fprintf(stderr, "FAIL %s is not in the list\n", entry.UTF8String); continue; }
        NSArray *parts = [entry componentsSeparatedByString:@" "];
        Class owner = NSClassFromString(parts[0]);
        BOOL isClassMethod = [parts[1] hasPrefix:@"+"];
        SEL selector = NSSelectorFromString([parts[1] substringFromIndex:1]);
        Method method = isClassMethod ? class_getClassMethod(owner, selector) : class_getInstanceMethod(owner, selector);
        if (!method) { failures++; fprintf(stderr, "FAIL %s is not answered\n", entry.UTF8String); continue; }
        Dl_info info;
        if (!dladdr((void *)method_getImplementation(method), &info) || !strstr(info.dli_fname, "LaterSDKCategories")) {
            failures++; fprintf(stderr, "FAIL %s is answered by %s, not by the two files\n", entry.UTF8String, info.dli_fname ?: "?");
        }
        NSString *types = withoutDigits(method_getTypeEncoding(method));
        Protocol *protocol = protocols[[@"LaterSDKProbe_" stringByAppendingString:parts[0]]];
        struct objc_method_description declared = protocol_getMethodDescription(protocol, selector, YES, !isClassMethod);
        if (!declared.types) { failures++; fprintf(stderr, "FAIL %s has no declaration in the probe\n", entry.UTF8String); continue; }
        compared++;
        if (![types isEqual:withoutDigits(declared.types)]) {
            failures++; fprintf(stderr, "FAIL %s: types %s, the declaration compiles to %s\n", entry.UTF8String, types.UTF8String, withoutDigits(declared.types).UTF8String);
        }
#if defined(__arm64__)
        if (item[@"encoding"] != NSNull.null) {
            withList++;
            if (![types isEqual:item[@"encoding"]]) {
                failures++; fprintf(stderr, "FAIL %s: types %s, the list says %s\n", entry.UTF8String, types.UTF8String, [item[@"encoding"] UTF8String]);
            }
        } else {
            printf("no encoding in the list for %s: %s (equal to the compiled declaration)\n", entry.UTF8String, types.UTF8String);
        }
#endif
    }
    // What was left out must stay unanswered by the two files.
    int leftOut = 0;
    for (NSDictionary *item in list) {
        if ([implemented containsObject:item[@"entry"]]) continue;
        leftOut++;
        NSArray *parts = [item[@"entry"] componentsSeparatedByString:@" "];
        Class owner = NSClassFromString(parts[0]);
        SEL selector = NSSelectorFromString([parts[1] substringFromIndex:1]);
        Method method = [parts[1] hasPrefix:@"+"] ? class_getClassMethod(owner, selector) : class_getInstanceMethod(owner, selector);
        Dl_info info;
        if (method && dladdr((void *)method_getImplementation(method), &info) && strstr(info.dli_fname, "LaterSDKCategories")) {
            failures++; fprintf(stderr, "FAIL %s was to be left out\n", [item[@"entry"] UTF8String]);
        }
    }
    printf("types: %d selectors compared with the compiled declaration, %d with the list; %d left out\n", compared, withList, leftOut);
    checks += compared + withList;
}

static void testStrings(void) {
    USE("NSString -stringAfterString:");
    CHECK(EQ([@"a=b=c" stringAfterString:@"="], @"b=c"));
    CHECK([@"abc" stringAfterString:@"x"] == nil);
    CHECK([@"abc" stringAfterString:nil] == nil);
    CHECK(EQ([@"abc" stringAfterString:@"c"], @""));
    USE("NSString -stringBetweenString:andString:");
    CHECK(EQ([@"x[one]y[two]" stringBetweenString:@"[" andString:@"]"], @"one"));
    CHECK([@"x[one" stringBetweenString:@"[" andString:@"]"] == nil);
    CHECK([@"x[one]" stringBetweenString:nil andString:nil] == nil);
    USE("NSString -stringsBetweenString:andString:");
    CHECK(EQ([@"x[one]y[two]z[" stringsBetweenString:@"[" andString:@"]"], (@[@"one", @"two"])));
    CHECK(EQ([@"x" stringsBetweenString:nil andString:@"]"], @[]));
    CHECK(EQ([@"<<a>><<b>>" stringsBetweenString:@"<<" andString:@">>"], (@[@"a", @"b"])));
    USE("NSString -stringByDeletingPrefix:");
    CHECK(EQ([@"prefix" stringByDeletingPrefix:@"pre"], @"fix"));
    CHECK(EQ([@"prefix" stringByDeletingPrefix:@"x"], @"prefix"));
    CHECK(EQ([@"prefix" stringByDeletingPrefix:nil], @"prefix"));
    USE("NSString -stringByDeletingSuffix:");
    CHECK(EQ([@"file.dcm" stringByDeletingSuffix:@".dcm"], @"file"));
    CHECK(EQ([@"file.dcm" stringByDeletingSuffix:@".x"], @"file.dcm"));
    CHECK(EQ([@"file.dcm" stringByDeletingSuffix:nil], @"file.dcm"));
    USE("NSString -stringByRemovingCombiningMarks");
    CHECK(EQ([@"é à ñ Ü" stringByRemovingCombiningMarks], @"e a n U"));
    CHECK(EQ([@"" stringByRemovingCombiningMarks], @""));
    USE("NSString -withoutWhitespaceSequences");
    CHECK(EQ([@"a  \t\n b   c" withoutWhitespaceSequences], @"a b c"));
    CHECK(EQ([@"" withoutWhitespaceSequences], @""));
    USE("NSString -sanitizeFileName");
    CHECK(EQ([@"a/b:c?.txt" sanitizeFileName], @"a_b_c_.txt"));
    CHECK(EQ([@"" sanitizeFileName], @"_"));
    CHECK(EQ([@".." sanitizeFileName], @"_"));
    CHECK(EQ([@"plain name.txt" sanitizeFileName], @"plain name.txt"));
    USE("NSString -sha1");
    CHECK(EQ([@"abc" sha1], @"a9993e364706816aba3e25717850c26c9cd0d89d"));
    CHECK(EQ([@"" sha1], @"da39a3ee5e6b4b0d3255bfef95601890afd80709"));
    USE("NSString -urlDecodedString");
    CHECK(EQ([@"a%20b%C3%A9" urlDecodedString], @"a bé"));
    CHECK(EQ([@"100%ZZ" urlDecodedString], @"100%ZZ"));
    USE("NSString -validURL");
    CHECK([@"https://example.com/x?y=1" validURL]);
    CHECK([@"file:///tmp/x" validURL]);
    CHECK(![@"not a url" validURL]);
    CHECK(![@"" validURL]);
    CHECK(![@"example.com" validURL]);
    USE("NSString -quotedPrintableString");
    CHECK(EQ([@"é=a b" quotedPrintableString], @"=C3=A9=3Da b"));
    CHECK(EQ([@"a \nb" quotedPrintableString], @"a=20\r\nb"));
    NSString *longLine = [[@"" stringByPaddingToLength:200 withString:@"é" startingAtIndex:0] quotedPrintableString];
    for (NSString *line in [longLine componentsSeparatedByString:@"\r\n"]) CHECK(line.length <= 76);
    CHECK([[longLine stringByReplacingOccurrencesOfString:@"=\r\n" withString:@""] length] == 200 * 6);
    CHECK(EQ([@"" quotedPrintableString], @""));
    USE("NSString -numberToSuperscript");
    CHECK(EQ([@"-12" numberToSuperscript], @"⁻¹²"));
    CHECK(EQ([@"x" numberToSuperscript], @"x"));
    USE("NSString +randomStringWithLength:");
    CHECK([NSString randomStringWithLength:10].length == 10);
    CHECK(![[NSString randomStringWithLength:32] isEqual:[NSString randomStringWithLength:32]]);
    CHECK(EQ([NSString randomStringWithLength:0], @""));
    CHECK(EQ([NSString randomStringWithLength:-3], @""));
    USE("NSString +stringWithData:");
    CHECK(EQ([NSString stringWithData:[@"olá" dataUsingEncoding:NSUTF8StringEncoding]], @"olá"));
    CHECK(EQ([NSString stringWithData:[NSData dataWithBytes:"ol\xE1" length:3]], @"olá"));
    CHECK([NSString stringWithData:nil] == nil);
    CHECK(EQ([NSString stringWithData:[NSData data]], @""));
    USE("NSString +timeString:maxUnits:abbreviated:");
    NSString *abbreviated = [NSString timeString:3725 maxUnits:2 abbreviated:YES], *full = [NSString timeString:3725 maxUnits:0 abbreviated:NO];
    printf("timeString: «%s» / «%s»\n", abbreviated.UTF8String, full.UTF8String);
    CHECK([abbreviated containsString:@"1"] && [abbreviated containsString:@"2"] && ![abbreviated containsString:@"5"]);
    CHECK([full containsString:@"1"] && [full containsString:@"2"] && [full containsString:@"5"] && full.length > abbreviated.length);
    CHECK([NSString timeString:NAN maxUnits:2 abbreviated:YES] == nil);
    CHECK([NSString timeString:0 maxUnits:-1 abbreviated:NO] != nil);

    USE("NSString -sizeOfStringWithFont:");
    NSSize small = [@"Hello" sizeOfStringWithFont:[NSFont systemFontOfSize:10]], large = [@"Hello" sizeOfStringWithFont:[NSFont systemFontOfSize:40]];
    CHECK(small.width > 0 && large.width > small.width * 2 && large.height > small.height);
    CHECK([@"Hello" sizeOfStringWithFont:nil].width > 0);
    CHECK([@"" sizeOfStringWithFont:nil].width == 0);

    USE("NSString -drawStringInRect:withAttributes:alignment:");
    [@"no context" drawStringInRect:NSMakeRect(0, 0, 10, 10) withAttributes:nil alignment:0];
    for (TextAlignment alignment = 0; alignment <= 3; alignment++) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:200 pixelsHigh:30 bitsPerSample:8 samplesPerPixel:4
                                                                          hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [@"II" drawStringInRect:NSMakeRect(0, 0, 200, 30) withAttributes:alignment == 3 ? nil : @{NSFontAttributeName: [NSFont systemFontOfSize:20], NSForegroundColorAttributeName: NSColor.blackColor}
                      alignment:alignment == 3 ? 99 : alignment];
        [@"II" drawStringInRect:NSZeroRect withAttributes:nil alignment:0];
        [NSGraphicsContext restoreGraphicsState];
        long left = 0, middle = 0, right = 0;
        for (int y = 0; y < 30; y++) for (int x = 0; x < 200; x++) {
            if (rep.bitmapData[y * rep.bytesPerRow + x * 4 + 3] == 0) continue;
            if (x < 50) left++; else if (x >= 150) right++; else if (x >= 75 && x < 125) middle++;
        }
        if (alignment == 0 || alignment == 3) CHECK(left > 0 && middle == 0 && right == 0);
        if (alignment == 1) CHECK(left == 0 && middle > 0 && right == 0);
        if (alignment == 2) CHECK(left == 0 && middle == 0 && right > 0);
    }
}

static void testCollections(void) {
    NSArray *numbers = @[@1, @2, @1, @3, @2];
    USE("NSArray -arrayByRemovingDuplicates");
    CHECK(EQ([numbers arrayByRemovingDuplicates], (@[@1, @2, @3])));
    CHECK(EQ([@[] arrayByRemovingDuplicates], @[]));
    USE("NSArray -arrayByRemovingFirstObject");
    CHECK(EQ([numbers arrayByRemovingFirstObject], (@[@2, @1, @3, @2])));
    CHECK(EQ([@[] arrayByRemovingFirstObject], @[]));
    USE("NSArray -arrayByRemovingLastObject");
    CHECK(EQ([numbers arrayByRemovingLastObject], (@[@1, @2, @1, @3])));
    CHECK(EQ([@[] arrayByRemovingLastObject], @[]));
    USE("NSArray -arrayByRemovingObject:");
    CHECK(EQ([numbers arrayByRemovingObject:@1], (@[@2, @3, @2])));
    CHECK(EQ([numbers arrayByRemovingObject:nil], numbers));
    CHECK(EQ([numbers arrayByRemovingObject:@"x"], numbers));
    USE("NSArray -arrayByRemovingObjectAtIndex:");
    CHECK(EQ([numbers arrayByRemovingObjectAtIndex:1], (@[@1, @1, @3, @2])));
    CHECK(EQ([numbers arrayByRemovingObjectAtIndex:99], numbers));
    CHECK(EQ([@[] arrayByRemovingObjectAtIndex:0], @[]));
    CHECK(EQ([numbers arrayByRemovingObjectAtIndex:NSNotFound], numbers));
    USE("NSArray -arrayByRemovingObjectFirstOccurenceOf:");
    CHECK(EQ([numbers arrayByRemovingObjectFirstOccurenceOf:@1], (@[@2, @1, @3, @2])));
    CHECK(EQ([numbers arrayByRemovingObjectFirstOccurenceOf:nil], numbers));
    CHECK(EQ([numbers arrayByRemovingObjectFirstOccurenceOf:@9], numbers));
    USE("NSArray -arrayByRemovingObjectsFromArray:");
    CHECK(EQ([numbers arrayByRemovingObjectsFromArray:(@[@1, @2])], @[@3]));
    CHECK(EQ([numbers arrayByRemovingObjectsFromArray:nil], numbers));
    USE("NSArray -indexOfSmallestValue");
    CHECK([(@[@3, @1.5, @2, @1.5]) indexOfSmallestValue] == 1);
    CHECK([(@[@"x", @7]) indexOfSmallestValue] == 1);
    CHECK([@[] indexOfSmallestValue] == NSNotFound);
    USE("NSArray -intersectArray:");
    CHECK([numbers intersectArray:(@[@9, @3])]);
    CHECK(![numbers intersectArray:(@[@9])]);
    CHECK(![numbers intersectArray:nil]);
    USE("NSArray -intersectionArray:");
    CHECK(EQ([numbers intersectionArray:(@[@3, @1])], (@[@1, @1, @3])));
    CHECK(EQ([numbers intersectionArray:nil], @[]));
    USE("NSArray -medianNumberFromNumbersArray");
    CHECK(EQ([(@[@3, @1, @2]) medianNumberFromNumbersArray], @2));
    CHECK(EQ([(@[@4, @1, @2, @3]) medianNumberFromNumbersArray], @2.5));
    CHECK([@[] medianNumberFromNumbersArray] == nil);
    CHECK([@[@"x"] medianNumberFromNumbersArray] == nil);
    USE("NSArray -randomObject");
    CHECK([numbers containsObject:[numbers randomObject]]);
    CHECK([@[] randomObject] == nil);
    USE("NSArray -randomizedArray");
    NSMutableArray *hundred = [NSMutableArray array];
    for (int i = 0; i < 100; i++) [hundred addObject:@(i)];
    NSArray *shuffled = [hundred randomizedArray];
    CHECK(shuffled.count == 100 && EQ([NSSet setWithArray:shuffled], [NSSet setWithArray:hundred]) && !EQ(shuffled, hundred));
    CHECK(EQ([@[] randomizedArray], @[]));

    NSArray *list = @[@"a", @1, @{@"k": @[@YES, @2.5]}, [NSData dataWithBytes:"xy" length:2]];
    USE("NSArray -arrayAsString");
    USE("NSArray +arrayFromString:");
    NSString *text = [list arrayAsString];
    CHECK(text.length > 0 && EQ([NSArray arrayFromString:text], list));
    CHECK([(@[NSNull.null]) arrayAsString] == nil);
    CHECK(EQ([NSArray arrayFromString:[@[] arrayAsString]], @[]));
    CHECK([NSArray arrayFromString:nil] == nil);
    CHECK([NSArray arrayFromString:@"<<<"] == nil);
    CHECK([NSArray arrayFromString:[@{@"a": @1} dictionaryAsString]] == nil);
    CHECK(EQ([NSArray arrayFromString:@"(a, b)"], (@[@"a", @"b"])));
    USE("NSArray -arrayAsJSONwithOptions:");
    USE("NSArray +arrayFromJSON:withOptions:");
    CHECK(EQ([(@[@1, @"a"]) arrayAsJSONwithOptions:0], @"[1,\"a\"]"));
    CHECK([[(@[@1]) arrayAsJSONwithOptions:NSJSONWritingPrettyPrinted] containsString:@"\n"]);
    CHECK([(@[[NSDate date]]) arrayAsJSONwithOptions:0] == nil);
    CHECK(EQ([NSArray arrayFromJSON:@"[1, [2]]" withOptions:0], (@[@1, @[@2]])));
    CHECK([[NSArray arrayFromJSON:@"[1, [2]]" withOptions:NSJSONReadingMutableContainers] isKindOfClass:NSMutableArray.class]);
    CHECK([NSArray arrayFromJSON:nil withOptions:0] == nil);
    CHECK([NSArray arrayFromJSON:@"{}" withOptions:0] == nil);
    CHECK([NSArray arrayFromJSON:@"not json" withOptions:0] == nil);

    USE("NSMutableArray -addObjectIfNotNil:");
    NSMutableArray *mutable = [NSMutableArray array];
    [mutable addObjectIfNotNil:nil];
    CHECK(mutable.count == 0);
    [mutable addObjectIfNotNil:@1];
    CHECK(EQ(mutable, @[@1]));
    USE("NSMutableArray -addString:");
    [mutable addString:nil];
    [mutable addString:@"s"];
    CHECK(EQ(mutable, (@[@1, @"s"])));
    USE("NSMutableArray -replaceLasObjectWith:");
    [mutable replaceLasObjectWith:@"t"];
    CHECK(EQ(mutable, (@[@1, @"t"])));
    [mutable replaceLasObjectWith:nil];
    CHECK(EQ(mutable, (@[@1, @"t"])));
    NSMutableArray *empty = [NSMutableArray array];
    [empty replaceLasObjectWith:@"only"];
    CHECK(EQ(empty, @[@"only"]));

    NSDictionary *dictionary = @{@"Key": @1, @"x-a": @2, @"x-b": @3, @7: @"seven"};
    USE("NSDictionary -dictionaryByAddingDictionary:");
    CHECK(EQ([dictionary dictionaryByAddingDictionary:(@{@"Key": @9, @"new": @4})], (@{@"Key": @9, @"x-a": @2, @"x-b": @3, @7: @"seven", @"new": @4})));
    CHECK(EQ([dictionary dictionaryByAddingDictionary:nil], dictionary));
    USE("NSDictionary -dictionaryByAddingObject:forKey:");
    CHECK(EQ([@{} dictionaryByAddingObject:@1 forKey:@"a"], @{@"a": @1}));
    CHECK(EQ([dictionary dictionaryByAddingObject:nil forKey:@"a"], dictionary));
    CHECK(EQ([dictionary dictionaryByAddingObject:@1 forKey:nil], dictionary));
    USE("NSDictionary -dictionaryByRemovingKey:");
    CHECK(EQ([dictionary dictionaryByRemovingKey:@7], (@{@"Key": @1, @"x-a": @2, @"x-b": @3})));
    CHECK(EQ([dictionary dictionaryByRemovingKey:nil], dictionary));
    CHECK(EQ([dictionary dictionaryByRemovingKey:@"absent"], dictionary));
    USE("NSDictionary -dictionaryByRemovingKeysWithPrefix:");
    CHECK(EQ([dictionary dictionaryByRemovingKeysWithPrefix:@"x-"], (@{@"Key": @1, @7: @"seven"})));
    CHECK(EQ([dictionary dictionaryByRemovingKeysWithPrefix:nil], dictionary));
    CHECK(EQ([dictionary dictionaryByRemovingKeysWithPrefix:@""], dictionary));
    USE("NSDictionary -objectForCaseInsensitiveKey:");
    CHECK(EQ([dictionary objectForCaseInsensitiveKey:@"KEY"], @1));
    CHECK(EQ([dictionary objectForCaseInsensitiveKey:@"Key"], @1));
    CHECK([dictionary objectForCaseInsensitiveKey:@"absent"] == nil);
    CHECK([dictionary objectForCaseInsensitiveKey:nil] == nil);
    USE("NSDictionary -dictionaryAsString");
    USE("NSDictionary +dictionaryFromString:");
    NSDictionary *plist = @{@"a": @[@1, @"two"], @"b": @{@"c": @YES}};
    CHECK(EQ([NSDictionary dictionaryFromString:[plist dictionaryAsString]], plist));
    CHECK([dictionary dictionaryAsString] == nil);
    CHECK([NSDictionary dictionaryFromString:nil] == nil);
    CHECK([NSDictionary dictionaryFromString:@"garbage <"] == nil);
    CHECK([NSDictionary dictionaryFromString:[@[@1] arrayAsString]] == nil);
    USE("NSDictionary -dictionaryAsJSONwithOptions:");
    USE("NSDictionary +dictionaryFromJSON:withOptions:");
    CHECK(EQ([@{@"a": @[@1]} dictionaryAsJSONwithOptions:0], @"{\"a\":[1]}"));
    CHECK([dictionary dictionaryAsJSONwithOptions:0] == nil);
    CHECK(EQ([NSDictionary dictionaryFromJSON:@"{\"a\": {\"b\": null}}" withOptions:0], @{@"a": @{@"b": NSNull.null}}));
    CHECK([NSDictionary dictionaryFromJSON:nil withOptions:0] == nil);
    CHECK([NSDictionary dictionaryFromJSON:@"[1]" withOptions:0] == nil);

    USE("NSMutableDictionary -changeKeyFrom:to:");
    NSMutableDictionary *changing = [@{@"old": @1, @"other": @2} mutableCopy];
    [changing changeKeyFrom:@"old" to:@"new"];
    CHECK(EQ(changing, (@{@"new": @1, @"other": @2})));
    [changing changeKeyFrom:@"absent" to:@"other"];
    [changing changeKeyFrom:nil to:@"other"];
    [changing changeKeyFrom:@"new" to:nil];
    [changing changeKeyFrom:@"new" to:@"new"];
    CHECK(EQ(changing, (@{@"new": @1, @"other": @2})));
    USE("NSMutableDictionary -setObjectIfNonNil:forKey:");
    [changing setObjectIfNonNil:nil forKey:@"k"];
    [changing setObjectIfNonNil:@3 forKey:nil];
    [changing setObjectIfNonNil:@3 forKey:@"k"];
    CHECK(EQ(changing, (@{@"new": @1, @"other": @2, @"k": @3})));

    USE("NSSet -array");
    CHECK(EQ(([NSSet setWithArray:[([NSSet setWithObjects:@1, @2, nil]) array]]), ([NSSet setWithObjects:@1, @2, nil])));
    CHECK(EQ([[NSSet set] array], @[]));
    USE("NSOrderedSet -anyObject");
    CHECK(EQ([[NSOrderedSet orderedSetWithArray:(@[@5, @6])] anyObject], @5));
    CHECK([[NSOrderedSet orderedSet] anyObject] == nil);
}

static void testData(NSString *folder) {
    NSData *hello = [@"hello" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *bytes100 = [NSMutableData data];
    for (int i = 0; i < 100; i++) { unsigned char b = (unsigned char)(i * 7); [bytes100 appendBytes:&b length:1]; }
    USE("NSData -base64Encoded");
    CHECK(EQ([hello base64Encoded], @"aGVsbG8="));
    CHECK(EQ([[NSData data] base64Encoded], @""));
    CHECK(![[bytes100 base64Encoded] containsString:@"\n"]);
    USE("NSData -base64Decoded");
    CHECK(EQ([[@"aGVsbG8=" dataUsingEncoding:NSASCIIStringEncoding] base64Decoded], hello));
    CHECK([[@"***" dataUsingEncoding:NSASCIIStringEncoding] base64Decoded].length == 0);
    CHECK([[@"aGVsbG8" dataUsingEncoding:NSASCIIStringEncoding] base64Decoded] == nil);
    CHECK(EQ([[NSData data] base64Decoded], [NSData data]));
    USE("NSData -encodeBase64");
    USE("NSData -encodeBase64WithNewlines:");
    NSString *lines = [bytes100 encodeBase64];
    CHECK(EQ(lines, [bytes100 encodeBase64WithNewlines:YES]));
    NSArray *split = [lines componentsSeparatedByString:@"\n"];
    CHECK(split.count == 3 && [split[0] length] == 64 && [split[1] length] == 64);
    CHECK(EQ([bytes100 encodeBase64WithNewlines:NO], [bytes100 base64EncodedStringWithOptions:0]));
    CHECK(EQ([[NSData data] encodeBase64], @""));
    USE("NSData -decodeBase64");
    USE("NSData -decodeBase64WithNewLines:");
    NSData *linesData = [lines dataUsingEncoding:NSASCIIStringEncoding];
    CHECK(EQ([linesData decodeBase64], bytes100));
    CHECK(EQ([linesData decodeBase64WithNewLines:YES], bytes100));
    CHECK([linesData decodeBase64WithNewLines:NO] == nil);
    CHECK(EQ([[[bytes100 encodeBase64WithNewlines:NO] dataUsingEncoding:NSASCIIStringEncoding] decodeBase64WithNewLines:NO], bytes100));
    CHECK(EQ([[[bytes100 encodeBase64WithNewlines:NO] dataUsingEncoding:NSASCIIStringEncoding] decodeBase64], bytes100));
    USE("NSData -hexStringValue");
    USE("NSData -hexval");
    CHECK(EQ([[NSData dataWithBytes:"\x00\xff\x1a" length:3] hexStringValue], @"00ff1a"));
    CHECK(EQ([[NSData dataWithBytes:"\x00\xff\x1a" length:3] hexval], @"00ff1a"));
    CHECK(EQ([[NSData data] hexStringValue], @"") && EQ([[NSData data] hexval], @""));
    USE("NSData -hexdump");
    NSString *dump = [[@"hello, hexdump of 23b\n" dataUsingEncoding:NSASCIIStringEncoding] hexdump];
    printf("%s", dump.UTF8String);
    NSArray *dumpLines = [dump componentsSeparatedByString:@"\n"];
    CHECK(dumpLines.count == 3 && EQ(dumpLines[0], @"00000000  68 65 6c 6c 6f 2c 20 68  65 78 64 75 6d 70 20 6f  |hello, hexdump o|"));
    CHECK([dumpLines[1] hasPrefix:@"00000010  66 20 32 33 62 0a"] && [dumpLines[1] hasSuffix:@"|f 23b.|"] && [dumpLines[1] length] == [dumpLines[0] length] - 10);
    CHECK(EQ([[NSData data] hexdump], @""));
    USE("NSData -md5Digest");
    CHECK(EQ([[[@"abc" dataUsingEncoding:NSASCIIStringEncoding] md5Digest] hexStringValue], @"900150983cd24fb0d6963f7d28e17f72"));
    CHECK([[NSData data] md5Digest].length == 16);
    USE("NSData -sha1Digest");
    CHECK(EQ([[[@"abc" dataUsingEncoding:NSASCIIStringEncoding] sha1Digest] hexStringValue], @"a9993e364706816aba3e25717850c26c9cd0d89d"));
    CHECK([[NSData data] sha1Digest].length == 20);
    USE("NSData -dataAsStringWithEncoding:");
    CHECK(EQ([hello dataAsStringWithEncoding:NSUTF8StringEncoding], @"hello"));
    CHECK(EQ([[NSData dataWithBytes:"\xE9" length:1] dataAsStringWithEncoding:NSISOLatin1StringEncoding], @"é"));
    CHECK([[NSData dataWithBytes:"\xE9" length:1] dataAsStringWithEncoding:NSUTF8StringEncoding] == nil);
    CHECK([hello dataAsStringWithEncoding:0] == nil);

    USE("NSData -compressDataWithAlgorithm:");
    USE("NSData -decompressDataWithDestinationSize:algorithm:");
    NSMutableData *repeated = [NSMutableData data];
    for (int i = 0; i < 2000; i++) [repeated appendData:hello];
    compression_algorithm algorithms[] = {COMPRESSION_ZLIB, COMPRESSION_LZFSE, COMPRESSION_LZ4, COMPRESSION_LZMA};
    for (int i = 0; i < 4; i++) {
        NSData *compressed = [repeated compressDataWithAlgorithm:algorithms[i]];
        CHECK(compressed.length > 0 && compressed.length < repeated.length / 4);
        void *buffer = [compressed decompressDataWithDestinationSize:repeated.length algorithm:algorithms[i]];
        CHECK(buffer && memcmp(buffer, repeated.bytes, repeated.length) == 0);
        free(buffer);
        NSData *tiny = [hello compressDataWithAlgorithm:algorithms[i]];
        CHECK(tiny.length > 0);
        void *tinyBuffer = [tiny decompressDataWithDestinationSize:16 algorithm:algorithms[i]];
        CHECK(tinyBuffer && memcmp(tinyBuffer, "hello\0\0\0\0\0\0\0\0\0\0\0", 16) == 0);
        free(tinyBuffer);
    }
    unsigned char noise[4096];
    arc4random_buf(noise, sizeof noise);
    NSData *noiseData = [NSData dataWithBytes:noise length:sizeof noise], *packedNoise = [noiseData compressDataWithAlgorithm:COMPRESSION_LZ4];
    void *noiseBack = [packedNoise decompressDataWithDestinationSize:sizeof noise algorithm:COMPRESSION_LZ4];
    CHECK(packedNoise.length > 0 && noiseBack && memcmp(noiseBack, noise, sizeof noise) == 0);
    free(noiseBack);
    CHECK([repeated compressDataWithAlgorithm:(compression_algorithm)0] == nil);
    CHECK([[NSData data] compressDataWithAlgorithm:COMPRESSION_ZLIB] == nil);
    CHECK([[repeated compressDataWithAlgorithm:COMPRESSION_ZLIB] decompressDataWithDestinationSize:0 algorithm:COMPRESSION_ZLIB] == NULL);
    CHECK([[NSData data] decompressDataWithDestinationSize:100 algorithm:COMPRESSION_ZLIB] == NULL);
    CHECK([repeated decompressDataWithDestinationSize:100 algorithm:(compression_algorithm)0] == NULL);

    USE("NSData +dataWithFirstBytes:ofFile:");
    NSString *digits = [folder stringByAppendingPathComponent:@"digits.bin"];
    [[@"0123456789" dataUsingEncoding:NSASCIIStringEncoding] writeToFile:digits atomically:YES];
    CHECK(EQ([NSData dataWithFirstBytes:4 ofFile:digits], [@"0123" dataUsingEncoding:NSASCIIStringEncoding]));
    CHECK([NSData dataWithFirstBytes:100 ofFile:digits].length == 10);
    CHECK(EQ([NSData dataWithFirstBytes:0 ofFile:digits], [NSData data]));
    CHECK([NSData dataWithFirstBytes:4 ofFile:nil] == nil);
    CHECK([NSData dataWithFirstBytes:4 ofFile:[folder stringByAppendingPathComponent:@"absent"]] == nil);
    USE("NSData +dataWithLong:");
    unsigned long longValue = 0x0102030405060708UL;
    CHECK(EQ([NSData dataWithLong:longValue], [NSData dataWithBytes:&longValue length:sizeof longValue]) && [NSData dataWithLong:0].length == 8);
    USE("NSData +dataWithShort:");
    unsigned short shortValue = 0x0102;
    CHECK(EQ([NSData dataWithShort:shortValue], [NSData dataWithBytes:&shortValue length:2]) && [NSData dataWithShort:0].length == 2);
    USE("NSData +headerValuesFromString:");
    NSDictionary *headers = [NSData headerValuesFromString:@"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nX-A: 1\r\n continued\r\nSet: a\r\nSet: b\r\nHost:example.com:80\r\n\r\nbody: x"];
    CHECK(EQ(headers, (@{@"Content-Type": @"text/html; charset=utf-8", @"X-A": @"1 continued", @"Set": @"a, b", @"Host": @"example.com:80"})));
    CHECK(EQ([NSData headerValuesFromString:@"A: 1\nB:\n"], (@{@"A": @"1", @"B": @""})));
    CHECK(EQ([NSData headerValuesFromString:nil], @{}));
    CHECK(EQ([NSData headerValuesFromString:@""], @{}));
}

static void testDatesNumbersURLs(void) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1609459199];  // 2020-12-31T23:59:59Z
    USE("NSDate -javaScriptDateTime");
    CHECK(EQ([date javaScriptDateTime], @"2020-12-31T23:59:59.000Z"));
    CHECK(EQ([[NSDate dateWithTimeIntervalSince1970:1609459199.25] javaScriptDateTime], @"2020-12-31T23:59:59.250Z"));
    USE("NSDate +dateWithJavaScriptDateTime:");
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:@"2020-12-31T23:59:59.000Z"], date));
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:@"2020-12-31T23:59:59Z"], date));
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:@"2021-01-01T01:59:59+02:00"], date));
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:[date javaScriptDateTime]], date));
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:@"2020-12-31T23:59:59.250000Z"], [NSDate dateWithTimeIntervalSince1970:1609459199.25]));
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:@"2020-12-31T23:59Z"], [NSDate dateWithTimeIntervalSince1970:1609459140]));
    NSDate *local = [NSDate dateWithJavaScriptDateTime:@"2020-02-29T12:00:00"], *localMillis = [NSDate dateWithJavaScriptDateTime:@"2020-02-29T12:00:00.500"];
    CHECK(local && EQ([local dateAsStringWithCalendarFormat:@"%Y-%m-%d %H:%M:%S"], @"2020-02-29 12:00:00") && [localMillis timeIntervalSinceDate:local] == 0.5);
    CHECK(EQ([NSDate dateWithJavaScriptDateTime:@"2020-02-29T12:00"], local));
    CHECK([NSDate dateWithJavaScriptDateTime:nil] == nil);
    CHECK([NSDate dateWithJavaScriptDateTime:@"yesterday"] == nil);
    CHECK([NSDate dateWithJavaScriptDateTime:@""] == nil);
    USE("NSDate -javaScriptDate");
    USE("NSDate +dateWithJavaScriptDate:");
    NSDate *noon = [[NSCalendar currentCalendar] dateFromComponents:({ NSDateComponents *c = [NSDateComponents new]; c.year = 2020; c.month = 2; c.day = 29; c.hour = 12; c; })];
    CHECK(EQ([noon javaScriptDate], @"2020-02-29"));
    NSDate *day = [NSDate dateWithJavaScriptDate:@"2020-02-29"];
    CHECK(day && EQ([day javaScriptDate], @"2020-02-29") && [noon timeIntervalSinceDate:day] == 12 * 3600);
    CHECK(EQ([NSDate dateWithJavaScriptDate:@"2020-12-31T23:59:59Z"], date));
    CHECK([NSDate dateWithJavaScriptDate:nil] == nil);
    CHECK([NSDate dateWithJavaScriptDate:@"31/12/2020"] == nil);
    USE("NSDate -rfc1123String");
    CHECK(EQ([date rfc1123String], @"Thu, 31 Dec 2020 23:59:59 GMT"));
    USE("NSDate -differenceWithDate:");
    NSDateComponents *difference = [date differenceWithDate:[date dateByAddingTimeInterval:-(86400 * 2 + 3661)]];
    CHECK(difference.year == 0 && difference.month == 0 && difference.day == 2 && difference.hour == 1 && difference.minute == 1 && difference.second == 1);
    CHECK([[date dateByAddingTimeInterval:-90] differenceWithDate:date].minute == -1 && [[date dateByAddingTimeInterval:-90] differenceWithDate:date].second == -30);
    CHECK([date differenceWithDate:nil] == nil);
    USE("NSDate -dateAsStringWithCalendarFormat:");
    CHECK(EQ([noon dateAsStringWithCalendarFormat:@"%Y-%m-%d %H:%M:%S"], @"2020-02-29 12:00:00"));
    CHECK(EQ([noon dateAsStringWithCalendarFormat:@"day %e of %B '%y, %A at %I %p (100%%)"], @"day 29 of February '20, Saturday at 12 PM (100%)"));
    CHECK(EQ([noon dateAsStringWithCalendarFormat:@"dd/MM/yyyy"], @"29/02/2020"));
    CHECK([[noon dateAsStringWithCalendarFormat:nil] hasPrefix:@"2020-02-29 12:00:00 "]);
    CHECK([[noon dateAsStringWithCalendarFormat:@""] hasPrefix:@"2020-02-29 12:00:00 "]);
    USE("NSDate +dateWithString:calendarFormat:");
    CHECK(EQ([NSDate dateWithString:@"2020-02-29 12:00:00" calendarFormat:@"%Y-%m-%d %H:%M:%S"], noon));
    CHECK(EQ([NSDate dateWithString:@"29/02/2020 12" calendarFormat:@"dd/MM/yyyy HH"], noon));
    CHECK(EQ([NSDate dateWithString:[noon dateAsStringWithCalendarFormat:nil] calendarFormat:nil], noon));
    CHECK([NSDate dateWithString:@"nonsense" calendarFormat:@"%Y-%m-%d"] == nil);
    CHECK([NSDate dateWithString:nil calendarFormat:nil] == nil);
    USE("NSDate +dateWithString:calendarFormat:error:");
    BOOL failed = YES;
    CHECK(EQ([NSDate dateWithString:@"2020-02-29 12:00:00" calendarFormat:@"%Y-%m-%d %H:%M:%S" error:&failed], noon) && failed == NO);
    CHECK([NSDate dateWithString:@"nonsense" calendarFormat:@"%Y-%m-%d" error:&failed] == nil && failed == YES);
    failed = NO;
    CHECK([NSDate dateWithString:nil calendarFormat:nil error:&failed] == nil && failed == YES);
    CHECK([NSDate dateWithString:@"2020-02-29" calendarFormat:@"%Y-%m-%d" error:NULL] != nil);

    USE("NSNumber +parseString:intoNSInteger:");
    NSInteger integer = 7;
    CHECK([NSNumber parseString:@" -42 " intoNSInteger:&integer] && integer == -42);
    CHECK(![NSNumber parseString:@"abc" intoNSInteger:&integer] && integer == -42);
    CHECK(![NSNumber parseString:@"12abc" intoNSInteger:&integer] && ![NSNumber parseString:@"" intoNSInteger:&integer] && ![NSNumber parseString:nil intoNSInteger:&integer]);
    CHECK(![NSNumber parseString:@"99999999999999999999" intoNSInteger:&integer] && integer == -42);
    CHECK([NSNumber parseString:@"5" intoNSInteger:NULL]);
    USE("NSNumber +parseString:intoNSUInteger:");
    NSUInteger unsignedInteger = 7;
    CHECK([NSNumber parseString:@"18446744073709551615" intoNSUInteger:&unsignedInteger] && unsignedInteger == NSUIntegerMax);
    CHECK(![NSNumber parseString:@"-1" intoNSUInteger:&unsignedInteger] && unsignedInteger == NSUIntegerMax);
    CHECK(![NSNumber parseString:nil intoNSUInteger:NULL]);
    USE("NSNumber +parseString:intoSInt64:");
    SInt64 signed64 = 0;
    CHECK([NSNumber parseString:@"-9223372036854775808" intoSInt64:&signed64] && signed64 == INT64_MIN);
    CHECK(![NSNumber parseString:@"1.5" intoSInt64:&signed64] && ![NSNumber parseString:nil intoSInt64:NULL]);
    USE("NSNumber +parseString:intoUInt64:");
    UInt64 unsigned64 = 0;
    CHECK([NSNumber parseString:@"+123" intoUInt64:&unsigned64] && unsigned64 == 123);
    CHECK(![NSNumber parseString:@"x" intoUInt64:&unsigned64] && unsigned64 == 123 && ![NSNumber parseString:nil intoUInt64:NULL]);

    NSURL *url = [NSURL URLWithString:@"https://host/path?a=1&b=two%20words&flag"];
    USE("NSURL -queryItems");
    CHECK(EQ([url queryItems], (@{@"a": @"1", @"b": @"two words", @"flag": @""})));
    CHECK(EQ([[NSURL URLWithString:@"https://host/path"] queryItems], @{}));
    CHECK(EQ([[NSURL fileURLWithPath:@"/tmp/x"] queryItems], @{}));
    USE("NSURL -URLByAppendingQueryParameters:");
    NSURL *appended = [url URLByAppendingQueryParameters:(@{@"z": @"a&b", @"c": @3})];
    CHECK(EQ(appended.absoluteString, @"https://host/path?a=1&b=two%20words&flag&c=3&z=a%26b"));
    CHECK(EQ([appended queryItems], (@{@"a": @"1", @"b": @"two words", @"flag": @"", @"c": @"3", @"z": @"a&b"})));
    CHECK(EQ([[NSURL URLWithString:@"https://host/path"] URLByAppendingQueryParameters:@{@"q": @"x y"}].absoluteString, @"https://host/path?q=x%20y"));
    CHECK(EQ([url URLByAppendingQueryParameters:nil], url) && EQ([url URLByAppendingQueryParameters:@{}], url));
    USE("NSURL -URLByRemovingQueryParameters:");
    CHECK(EQ([url URLByRemovingQueryParameters:(@[@"a", @"flag", @"absent"])].absoluteString, @"https://host/path?b=two%20words"));
    CHECK(EQ([url URLByRemovingQueryParameters:(@[@"a", @"flag", @"b"])].absoluteString, @"https://host/path"));
    CHECK(EQ([url URLByRemovingQueryParameters:nil], url) && EQ([url URLByRemovingQueryParameters:@[]].absoluteString, url.absoluteString));
    CHECK(EQ([[NSURL URLWithString:@"https://host/path"] URLByRemovingQueryParameters:@[@"a"]].absoluteString, @"https://host/path"));
}

static void testThreadsAndObjects(void) {
    USE("NSNotificationCenter -addUniqueObserver:selector:name:object:");
    NSNotificationCenter *center = [[NSNotificationCenter alloc] init];
    Probe *observer = [Probe new];
    NSObject *sender = [NSObject new];
    [center addUniqueObserver:observer selector:@selector(notified:) name:@"LaterSDKProbeNote" object:nil];
    [center addUniqueObserver:observer selector:@selector(notified:) name:@"LaterSDKProbeNote" object:nil];
    [center addUniqueObserver:observer selector:@selector(notified:) name:@"LaterSDKProbeNote" object:nil];
    [center postNotificationName:@"LaterSDKProbeNote" object:sender];
    CHECK(observer.count == 1);
    [center addUniqueObserver:nil selector:@selector(notified:) name:@"LaterSDKProbeNote" object:nil];
    [center addUniqueObserver:observer selector:NULL name:@"LaterSDKProbeNote" object:nil];
    [center postNotificationName:@"LaterSDKProbeNote" object:sender];
    CHECK(observer.count == 2);
    Probe *any = [Probe new];
    [center addUniqueObserver:any selector:@selector(notified:) name:nil object:sender];
    [center addUniqueObserver:any selector:@selector(notified:) name:nil object:sender];
    [center postNotificationName:@"LaterSDKProbeOther" object:sender];
    CHECK(any.count == 1);
    [center removeObserver:observer];
    [center removeObserver:any];

    USE("NSThread -getThreadNum");
    CHECK([[NSThread mainThread] getThreadNum] == 1);
    CHECK([[NSThread currentThread] getThreadNum] == 1);
    __block NSInteger other = -1, otherAsSeenFromMain = -2;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{ other = [[NSThread currentThread] getThreadNum]; }];
    otherAsSeenFromMain = [thread getThreadNum];
    [thread start];
    for (int i = 0; i < 100 && other == -1; i++) spin(0.02);
    printf("thread numbers: main %ld, another %ld (%ld before it started)\n", (long)[[NSThread mainThread] getThreadNum], (long)other, (long)otherAsSeenFromMain);
    CHECK(other > 1 && other == otherAsSeenFromMain);

    USE("NSObject -OsiriXPerformSelectorOnMainThread:withObject:waitUntilDone:");
    Probe *probe = [Probe new];
    [probe OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"now" waitUntilDone:YES];
    CHECK(probe.count == 1 && probe.onMain && EQ(probe.last, @"now"));
    [probe OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:nil waitUntilDone:NO];
    CHECK(probe.count == 1);
    spin(0.1);
    CHECK(probe.count == 2 && probe.last == nil);
    [probe OsiriXPerformSelectorOnMainThread:NULL withObject:@"x" waitUntilDone:YES];
    CHECK(probe.count == 2);
    __block BOOL returned = NO, doneWhenReturned = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [probe OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"from another thread" waitUntilDone:YES];
        doneWhenReturned = probe.count == 3;
        returned = YES;
    });
    for (int i = 0; i < 100 && !returned; i++) spin(0.02);
    CHECK(returned && doneWhenReturned && probe.onMain && EQ(probe.last, @"from another thread"));

    USE("NSObject -OsiriXPerformSelectorOnMainThread:withObject:rootCallStack:");
    Probe *root = [Probe new];
    [root OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"root" rootCallStack:YES];
    [root OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"root" rootCallStack:NO];
    [root OsiriXPerformSelectorOnMainThread:NULL withObject:@"root" rootCallStack:NO];
    CHECK(root.count == 0);
    spin(0.1);
    CHECK(root.count == 2 && root.onMain && EQ(root.last, @"root"));
    returned = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [root OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"root from another thread" rootCallStack:YES];
        returned = YES;
    });
    for (int i = 0; i < 100 && root.count < 3; i++) spin(0.02);
    CHECK(returned && root.count == 3 && root.onMain && EQ(root.last, @"root from another thread"));

    USE("NSObject -OsiriXPerformSelectorOnMainThread:withObject:afterDelay:");
    USE("NSObject -OsiriXPerformSelectorOnMainThread:withObject:rootCallStack:afterDelay:");
    Probe *delayed = [Probe new];
    NSDate *start = [NSDate date];
    [delayed OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"later" afterDelay:0.3f];
    [delayed OsiriXPerformSelectorOnMainThread:NULL withObject:@"later" afterDelay:0.3f];
    spin(0.15);
    CHECK(delayed.count == 0);
    for (int i = 0; i < 100 && delayed.count < 1; i++) spin(0.02);
    NSTimeInterval waited = -[start timeIntervalSinceNow];
    printf("afterDelay 0.3: performed after %.3f s\n", waited);
    CHECK(delayed.count == 1 && delayed.onMain && EQ(delayed.last, @"later") && waited >= 0.29 && waited < 1);
    [delayed OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"zero" afterDelay:0];
    [delayed OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"zero" afterDelay:-1];
    [delayed OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"zero" afterDelay:NAN];
    CHECK(delayed.count == 1);
    spin(0.1);
    CHECK(delayed.count == 4);
    start = [NSDate date];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [delayed OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"later from another thread" rootCallStack:YES afterDelay:0.3f];
        [delayed OsiriXPerformSelectorOnMainThread:NULL withObject:nil rootCallStack:NO afterDelay:0.3f];
    });
    spin(0.15);
    CHECK(delayed.count == 4);
    for (int i = 0; i < 100 && delayed.count < 5; i++) spin(0.02);
    waited = -[start timeIntervalSinceNow];
    printf("rootCallStack afterDelay 0.3 from another thread: performed after %.3f s\n", waited);
    CHECK(delayed.count == 5 && delayed.onMain && EQ(delayed.last, @"later from another thread") && waited >= 0.29 && waited < 1);
    // The timer keeps its receiver until it fires.
    __weak Probe *weak;
    @autoreleasepool {
        Probe *kept = [Probe new];
        weak = kept;
        [kept OsiriXPerformSelectorOnMainThread:@selector(hit:) withObject:@"kept" rootCallStack:NO afterDelay:0.1f];
    }
    CHECK(weak != nil);
    spin(0.3);
    CHECK(weak == nil);
}

static void testFiles(NSString *folder) {
    NSFileManager *files = [[NSFileManager alloc] init];
    NSString *a = [folder stringByAppendingPathComponent:@"tree"], *deep = [a stringByAppendingPathComponent:@"one/two"];
    USE("NSFileManager -confirmDirectoryAtPath:createIntermediateDirectories:");
    CHECK([files confirmDirectoryAtPath:deep createIntermediateDirectories:NO] == nil);
    CHECK(EQ([files confirmDirectoryAtPath:deep createIntermediateDirectories:YES], deep));
    BOOL isDirectory = NO;
    CHECK([files fileExistsAtPath:deep isDirectory:&isDirectory] && isDirectory);
    CHECK(EQ([files confirmDirectoryAtPath:deep createIntermediateDirectories:NO], deep));
    CHECK(EQ([files confirmDirectoryAtPath:[a stringByAppendingPathComponent:@"flat"] createIntermediateDirectories:NO], [a stringByAppendingPathComponent:@"flat"]));
    NSString *file10 = [a stringByAppendingPathComponent:@"ten.txt"], *file5 = [deep stringByAppendingPathComponent:@"five.TXT"], *fileDat = [a stringByAppendingPathComponent:@"x.dat"];
    [[@"0123456789" dataUsingEncoding:NSASCIIStringEncoding] writeToFile:file10 atomically:YES];
    [[@"01234" dataUsingEncoding:NSASCIIStringEncoding] writeToFile:file5 atomically:YES];
    [[@"abc" dataUsingEncoding:NSASCIIStringEncoding] writeToFile:fileDat atomically:YES];
    CHECK([files confirmDirectoryAtPath:file10 createIntermediateDirectories:YES] == nil);
    CHECK([files confirmDirectoryAtPath:nil createIntermediateDirectories:YES] == nil && [files confirmDirectoryAtPath:@"" createIntermediateDirectories:YES] == nil);
    USE("NSFileManager -fileSize:");
    CHECK([files fileSize:file10] == 10 && [files fileSize:[a stringByAppendingPathComponent:@"absent"]] == 0 && [files fileSize:nil] == 0);
    USE("NSFileManager -folderSize:");
    CHECK([files folderSize:a] == 18 && [files folderSize:deep] == 5 && [files folderSize:file10] == 0 && [files folderSize:nil] == 0);
    USE("NSFileManager -countFolderItemsForPath:");
    CHECK([files countFolderItemsForPath:a] == 4 && [files countFolderItemsForPath:deep] == 1 && [files countFolderItemsForPath:file10] == 0 && [files countFolderItemsForPath:nil] == 0);
    USE("NSFileManager -crc32ForPath:");
    CHECK([files crc32ForPath:file10] == crc32(crc32(0, NULL, 0), (const Bytef *)"0123456789", 10) && [files crc32ForPath:file10] == 0xA684C7C6UL);
    NSMutableData *big = [NSMutableData dataWithLength:3 * 1024 * 1024 + 17];
    arc4random_buf(big.mutableBytes, big.length);
    NSString *bigPath = [folder stringByAppendingPathComponent:@"big.bin"];
    [big writeToFile:bigPath atomically:YES];
    CHECK([files crc32ForPath:bigPath] == crc32(crc32(0, NULL, 0), big.bytes, (uInt)big.length));
    CHECK([files crc32ForPath:nil] == 0 && [files crc32ForPath:[a stringByAppendingPathComponent:@"absent"]] == 0);
    USE("NSFileManager -filesWithExtension:inDirectory:");
    [files createDirectoryAtPath:[a stringByAppendingPathComponent:@"folder.txt"] withIntermediateDirectories:NO attributes:nil error:NULL];
    CHECK(EQ([files filesWithExtension:@"txt" inDirectory:a], @[file10]));
    CHECK(EQ([files filesWithExtension:@".TXT" inDirectory:a], @[file10]));
    CHECK(EQ([files filesWithExtension:@"txt" inDirectory:deep], @[file5]));
    CHECK(EQ([files filesWithExtension:nil inDirectory:a], @[]) && EQ([files filesWithExtension:@"txt" inDirectory:nil], @[]));
    CHECK(EQ([files filesWithExtension:@"txt" inDirectory:[a stringByAppendingPathComponent:@"absent"]], @[]));
    USE("NSFileManager -filesWithExtensions:inDirectory:");
    CHECK(EQ([files filesWithExtensions:(@[@"dat", @"txt", @7]) inDirectory:a], (@[file10, fileDat])));
    CHECK(EQ([files filesWithExtensions:nil inDirectory:a], @[]) && EQ([files filesWithExtensions:@[] inDirectory:a], @[]));

    USE("NSFileManager -removeItemsWithPrefix:error:");
    NSString *pre = [folder stringByAppendingPathComponent:@"prefixed"];
    [files createDirectoryAtPath:pre withIntermediateDirectories:NO attributes:nil error:NULL];
    for (NSString *name in @[@"tmp-1", @"tmp-2.bin", @"keep", @"atmp-3"]) [[NSData data] writeToFile:[pre stringByAppendingPathComponent:name] atomically:YES];
    [files createDirectoryAtPath:[pre stringByAppendingPathComponent:@"tmp-dir/inner"] withIntermediateDirectories:YES attributes:nil error:NULL];
    NSError *error = nil;
    CHECK(![files removeItemsWithPrefix:[pre stringByAppendingString:@"/"] error:&error] && error != nil);
    CHECK([files countFolderItemsForPath:pre] == 5);
    error = nil;
    CHECK(![files removeItemsWithPrefix:nil error:&error] && error != nil);
    CHECK(![files removeItemsWithPrefix:@"" error:NULL] && ![files removeItemsWithPrefix:@"no-folder" error:NULL]);
    error = nil;
    CHECK([files removeItemsWithPrefix:[pre stringByAppendingPathComponent:@"tmp-"] error:&error] && error == nil);
    CHECK(EQ([[files contentsOfDirectoryAtPath:pre error:NULL] sortedArrayUsingSelector:@selector(compare:)], (@[@"atmp-3", @"keep"])));
    CHECK(![files removeItemsWithPrefix:[folder stringByAppendingPathComponent:@"absent/x"] error:&error] && error != nil);
    USE("NSFileManager -removeContentOfDirectoryAtPath:");
    CHECK([files removeContentOfDirectoryAtPath:pre] && [files fileExistsAtPath:pre] && [files countFolderItemsForPath:pre] == 0);
    CHECK([files removeContentOfDirectoryAtPath:pre]);
    CHECK(![files removeContentOfDirectoryAtPath:nil] && ![files removeContentOfDirectoryAtPath:file10] && [files fileExistsAtPath:file10]);
    CHECK(![files removeContentOfDirectoryAtPath:[folder stringByAppendingPathComponent:@"absent"]]);

    USE("NSFileManager -testWritingPermission:error:");
    USE("NSFileManager -correctWritingPermissionForDirectory:error:");
    USE("NSFileManager -correctWritingPermissionForFile:");
    error = nil;
    CHECK([files testWritingPermission:pre error:&error] && error == nil && [files countFolderItemsForPath:pre] == 0);
    CHECK([files testWritingPermission:file10 error:&error] && error == nil && [files fileSize:file10] == 10);
    CHECK(![files testWritingPermission:nil error:&error] && error != nil);
    error = nil;
    CHECK(![files testWritingPermission:[folder stringByAppendingPathComponent:@"absent"] error:&error] && error != nil);
    CHECK(![files testWritingPermission:nil error:NULL]);
    if (geteuid() != 0) {
        chmod(pre.fileSystemRepresentation, 0500);
        error = nil;
        CHECK(![files testWritingPermission:pre error:&error] && error != nil);
        error = nil;
        [files correctWritingPermissionForDirectory:pre error:&error];
        CHECK(error == nil && [files testWritingPermission:pre error:NULL]);
        struct stat status;
        CHECK(stat(pre.fileSystemRepresentation, &status) == 0 && (status.st_mode & 0777) == 0700);
        chmod(file10.fileSystemRepresentation, 0444);
        CHECK(![files testWritingPermission:file10 error:&error] && error != nil);
        CHECK([files correctWritingPermissionForFile:file10] && [files testWritingPermission:file10 error:NULL]);
        CHECK(stat(file10.fileSystemRepresentation, &status) == 0 && (status.st_mode & 0777) == 0644);
    }
    error = nil;
    [files correctWritingPermissionForDirectory:nil error:&error];
    CHECK(error != nil);
    error = nil;
    [files correctWritingPermissionForDirectory:file10 error:&error];
    CHECK(error != nil);
    [files correctWritingPermissionForDirectory:pre error:NULL];
    [files correctWritingPermissionForDirectory:nil error:NULL];
    CHECK(![files correctWritingPermissionForFile:nil] && ![files correctWritingPermissionForFile:[folder stringByAppendingPathComponent:@"absent"]]);
    CHECK([files correctWritingPermissionForFile:file10]);

    USE("NSFileManager -getTotalSize:andFreeSize:forPath:");
    unsigned long long total = 0, free = 0;
    CHECK([files getTotalSize:&total andFreeSize:&free forPath:folder] && total > 0 && free > 0 && free <= total);
    printf("volume: %llu bytes, %llu free\n", total, free);
    CHECK([files getTotalSize:NULL andFreeSize:NULL forPath:folder]);
    total = 1;
    CHECK(![files getTotalSize:&total andFreeSize:&free forPath:nil] && total == 1);
    CHECK(![files getTotalSize:&total andFreeSize:&free forPath:@"/no/such/volume/at/all"]);

    USE("NSFileManager -tmpFilePathInDir:withExtension:");
    NSString *first = [files tmpFilePathInDir:folder withExtension:@"png"], *second = [files tmpFilePathInDir:folder withExtension:@".png"];
    CHECK(EQ(first.stringByDeletingLastPathComponent, folder) && EQ(first.pathExtension, @"png") && EQ(second.pathExtension, @"png") && !EQ(first, second) && ![files fileExistsAtPath:first]);
    CHECK(EQ([files tmpFilePathInDir:folder withExtension:nil].pathExtension, @"") && EQ([files tmpFilePathInDir:folder withExtension:@""].pathExtension, @""));
    CHECK(EQ([files tmpFilePathInDir:nil withExtension:@"x"].stringByDeletingLastPathComponent, NSTemporaryDirectory().stringByStandardizingPath)
          || EQ([[files tmpFilePathInDir:nil withExtension:@"x"].stringByDeletingLastPathComponent stringByAppendingString:@"/"], NSTemporaryDirectory()));
    USE("NSFileManager -tmpFilePathInTmpWithExtension:");
    NSString *inTmp = [files tmpFilePathInTmpWithExtension:@"dcm"];
    CHECK([inTmp hasPrefix:NSTemporaryDirectory()] && EQ(inTmp.pathExtension, @"dcm") && !EQ(inTmp, [files tmpFilePathInTmpWithExtension:@"dcm"]));
    CHECK([[files tmpFilePathInTmpWithExtension:nil] hasPrefix:NSTemporaryDirectory()]);
    USE("NSFileManager -tmpFilePathInTmpWithName:");
    CHECK(EQ([files tmpFilePathInTmpWithName:@"name.bin"], [NSTemporaryDirectory() stringByAppendingPathComponent:@"name.bin"]));
    CHECK([files tmpFilePathInTmpWithName:nil] == nil && [files tmpFilePathInTmpWithName:@""] == nil);
    USE("NSFileManager -userApplicationSupportFolderForApp:");
    NSString *appName = [@"LaterSDKProbe-" stringByAppendingString:NSUUID.UUID.UUIDString], *support = [files userApplicationSupportFolderForApp:appName];
    printf("application support: %s\n", support.UTF8String);
    CHECK(EQ(support.lastPathComponent, appName) && EQ(support.stringByDeletingLastPathComponent.lastPathComponent, @"Application Support")
          && [files fileExistsAtPath:support isDirectory:&isDirectory] && isDirectory);
    CHECK(EQ([files userApplicationSupportFolderForApp:appName], support));
    if ([support.lastPathComponent hasPrefix:@"LaterSDKProbe-"]) [files removeItemAtPath:support error:NULL];
    CHECK(EQ([files userApplicationSupportFolderForApp:nil].lastPathComponent, @"Application Support"));
    CHECK(EQ([files userApplicationSupportFolderForApp:@""], [files userApplicationSupportFolderForApp:nil]));
}

static void testImages(NSString *folder) {
    NSImage *image = twoHalves(), *empty = [[NSImage alloc] initWithSize:NSZeroSize];
    USE("NSImage -bitmapImageRepresentation");
    NSBitmapImageRep *rep = [image bitmapImageRepresentation];
    CHECK(rep.pixelsWide == 40 && rep.pixelsHigh == 20 && NSEqualSizes(rep.size, NSMakeSize(40, 20)) && rep.bitsPerPixel == 32);
    CHECK(isPixel(rep, 5, 10, 1, 0, 0) && isPixel(rep, 35, 10, 0, 0, 1));
    CHECK([empty bitmapImageRepresentation] == nil);
    USE("NSImage -bitmapImageRepresentationWithBitsPerSample:andBitsPerPixel:");
    NSBitmapImageRep *rgb = [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:24];
    CHECK(EQ(rep.colorSpace, NSColorSpace.sRGBColorSpace) && EQ(rgb.colorSpace, NSColorSpace.sRGBColorSpace));
    CHECK(rgb.pixelsWide == 40 && rgb.pixelsHigh == 20 && rgb.samplesPerPixel == 3 && !rgb.hasAlpha && rgb.bitsPerPixel == 24 && rgb.bitsPerSample == 8);
    CHECK(rgb.bitmapData[0] == 255 && rgb.bitmapData[1] == 0 && rgb.bitmapData[2] == 0 && rgb.bitmapData[39 * 3 + 2] == 255 && rgb.bitmapData[39 * 3] == 0);
    CHECK(isPixel(rgb, 5, 10, 1, 0, 0) && isPixel(rgb, 35, 10, 0, 0, 1));
    NSBitmapImageRep *gray = [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:8];
    CHECK(gray.colorSpace.colorSpaceModel == NSColorSpaceModelGray && EQ(gray.colorSpace, NSColorSpace.genericGamma22GrayColorSpace));
    CHECK(gray.samplesPerPixel == 1 && gray.bitsPerPixel == 8 && gray.bitmapData[0] == 76 && gray.bitmapData[39] == 28);
    NSBitmapImageRep *grayAlpha = [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:16];
    CHECK(grayAlpha.samplesPerPixel == 2 && grayAlpha.hasAlpha && grayAlpha.bitmapData[0] == 76 && grayAlpha.bitmapData[1] == 255);
    NSBitmapImageRep *deep = [image bitmapImageRepresentationWithBitsPerSample:16 andBitsPerPixel:64];
    CHECK(deep.samplesPerPixel == 4 && deep.bitsPerSample == 16 && deep.hasAlpha && ((uint16_t *)deep.bitmapData)[0] == 65535 && ((uint16_t *)deep.bitmapData)[1] == 0 && ((uint16_t *)deep.bitmapData)[3] == 65535);
    CHECK(isPixel(deep, 5, 10, 1, 0, 0) && isPixel(deep, 35, 10, 0, 0, 1));
    NSBitmapImageRep *deepGray = [image bitmapImageRepresentationWithBitsPerSample:16 andBitsPerPixel:16];
    CHECK(deepGray.samplesPerPixel == 1 && deepGray.bitsPerSample == 16 && ((uint16_t *)deepGray.bitmapData)[0] == 76 * 257);
    CHECK([image bitmapImageRepresentationWithBitsPerSample:7 andBitsPerPixel:13] == nil && [image bitmapImageRepresentationWithBitsPerSample:0 andBitsPerPixel:0] == nil);
    CHECK([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:40] == nil && [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:-8] == nil);
    CHECK([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:12] == nil && [image bitmapImageRepresentationWithBitsPerSample:32 andBitsPerPixel:32] == nil);
    CHECK([empty bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32] == nil);
    USE("NSImage -bitmapImageRepresentationWithBitsPerSample:andBitsPerPixel:scalingFactor:");
    NSBitmapImageRep *doubled = [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:2];
    CHECK(doubled.pixelsWide == 80 && doubled.pixelsHigh == 40 && doubled.samplesPerPixel == 4 && isPixel(doubled, 10, 20, 1, 0, 0) && isPixel(doubled, 70, 20, 0, 0, 1));
    CHECK([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:0.5f].pixelsWide == 20);
    CHECK([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:0].pixelsWide == 40);
    CHECK([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:NAN].pixelsWide == 40);
    CHECK([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:1e9f] == nil);
    USE("NSImage -bitmapImageRepresentationWithBitsPerSample:andBitsPerPixel:scalingFactor:alphaFirst:");
    NSBitmapImageRep *argb = [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:1 alphaFirst:YES];
    CHECK((argb.bitmapFormat & NSBitmapFormatAlphaFirst) && argb.bitmapData[0] == 255 && argb.bitmapData[1] == 255 && argb.bitmapData[2] == 0 && argb.bitmapData[3] == 0);
    CHECK(argb.bitmapData[39 * 4] == 255 && argb.bitmapData[39 * 4 + 1] == 0 && argb.bitmapData[39 * 4 + 3] == 255 && isPixel(argb, 35, 10, 0, 0, 1));
    NSBitmapImageRep *rgba = [image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:32 scalingFactor:1 alphaFirst:NO];
    CHECK(!(rgba.bitmapFormat & NSBitmapFormatAlphaFirst) && rgba.bitmapData[0] == 255 && rgba.bitmapData[1] == 0 && rgba.bitmapData[3] == 255);
    CHECK(!([image bitmapImageRepresentationWithBitsPerSample:8 andBitsPerPixel:24 scalingFactor:1 alphaFirst:YES].bitmapFormat & NSBitmapFormatAlphaFirst));

    USE("NSImage -resizedImageRepresentationToPixelDimensions:");
    NSBitmapImageRep *resized = [image resizedImageRepresentationToPixelDimensions:NSMakeSize(10, 8)];
    CHECK(resized.pixelsWide == 10 && resized.pixelsHigh == 8 && NSEqualSizes(resized.size, NSMakeSize(10, 8)) && isPixel(resized, 1, 4, 1, 0, 0) && isPixel(resized, 8, 4, 0, 0, 1));
    CHECK([image resizedImageRepresentationToPixelDimensions:NSZeroSize] == nil && [image resizedImageRepresentationToPixelDimensions:NSMakeSize(-4, 4)] == nil);
    CHECK([image resizedImageRepresentationToPixelDimensions:NSMakeSize(NAN, INFINITY)] == nil && [empty resizedImageRepresentationToPixelDimensions:NSMakeSize(4, 4)] == nil);
    USE("NSImage -getDataOfType:compressionFactor:");
    NSData *png = [image getDataOfType:NSBitmapImageFileTypePNG compressionFactor:1];
    CHECK(png.length > 8 && memcmp(png.bytes, "\x89PNG\r\n\x1a\n", 8) == 0);
    NSBitmapImageRep *pngBack = [NSBitmapImageRep imageRepWithData:png];
    CHECK(pngBack.pixelsWide == 40 && pngBack.pixelsHigh == 20 && isPixel(pngBack, 5, 10, 1, 0, 0));
    NSData *tiff = [image getDataOfType:NSBitmapImageFileTypeTIFF compressionFactor:0.5f];
    CHECK(tiff.length > 4 && (memcmp(tiff.bytes, "II*\0", 4) == 0 || memcmp(tiff.bytes, "MM\0*", 4) == 0));
    NSData *jpegLow = [image getDataOfType:NSBitmapImageFileTypeJPEG compressionFactor:0], *jpegHigh = [image getDataOfType:NSBitmapImageFileTypeJPEG compressionFactor:1];
    CHECK(jpegLow.length > 2 && memcmp(jpegLow.bytes, "\xFF\xD8", 2) == 0 && jpegHigh.length > jpegLow.length);
    CHECK([image getDataOfType:NSBitmapImageFileTypeJPEG compressionFactor:NAN].length > 0 && [image getDataOfType:NSBitmapImageFileTypeJPEG compressionFactor:-5].length > 0);
    CHECK([image getDataOfType:999 compressionFactor:1] == nil && [empty getDataOfType:NSBitmapImageFileTypePNG compressionFactor:1] == nil);
    USE("NSImage -JPEGRepresentation");
    NSData *jpeg = [image JPEGRepresentation];
    NSBitmapImageRep *jpegBack = [NSBitmapImageRep imageRepWithData:jpeg];
    CHECK(jpeg.length > 2 && memcmp(jpeg.bytes, "\xFF\xD8", 2) == 0 && jpegBack.pixelsWide == 40 && jpegBack.pixelsHigh == 20);
    CHECK([empty JPEGRepresentation] == nil);
    NSImage *clear = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    [clear addRepresentation:[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:8 pixelsHigh:8 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0]];
    CHECK(isPixel([NSBitmapImageRep imageRepWithData:[clear JPEGRepresentation]], 4, 4, 1, 1, 1));
    USE("NSImage -PDFRepresentation");
    NSData *pdf = [image PDFRepresentation];
    CHECK(pdf.length > 5 && memcmp(pdf.bytes, "%PDF-", 5) == 0);
    NSPDFImageRep *pdfBack = [NSPDFImageRep imageRepWithData:pdf];
    CHECK(pdfBack.pageCount == 1 && NSEqualSizes(pdfBack.bounds.size, NSMakeSize(40, 20)));
    CHECK([empty PDFRepresentation] == nil);

    USE("NSImage -crop:");
    NSImage *cropped = [image crop:NSMakeRect(20, 5, 15, 10)];
    CHECK(NSEqualSizes(cropped.size, NSMakeSize(15, 10)) && bitmapOf(cropped).pixelsWide == 15 && bitmapOf(cropped).pixelsHigh == 10);
    CHECK(isPixel(bitmapOf(cropped), 1, 5, 0, 0, 1) && isPixel(bitmapOf(cropped), 13, 5, 0, 0, 1));
    NSImage *straddling = [image crop:NSMakeRect(15, 0, 10, 20)];
    CHECK(isPixel(bitmapOf(straddling), 2, 10, 1, 0, 0) && isPixel(bitmapOf(straddling), 7, 10, 0, 0, 1));
    CHECK([image crop:NSZeroRect] == nil && [image crop:NSMakeRect(NAN, 0, 10, 10)] == nil && [empty crop:NSMakeRect(0, 0, 4, 4)] == nil);
    USE("NSImage -flipImageX:Y:");
    NSImage *mirrored = [image flipImageX:YES Y:NO];
    CHECK(NSEqualSizes(mirrored.size, image.size) && isPixel(bitmapOf(mirrored), 5, 10, 0, 0, 1) && isPixel(bitmapOf(mirrored), 35, 10, 1, 0, 0));
    CHECK(isPixel(bitmapOf([image flipImageX:NO Y:YES]), 5, 10, 1, 0, 0) && isPixel(bitmapOf([image flipImageX:NO Y:NO]), 35, 10, 0, 0, 1));
    NSImage *quarters = [image crop:NSMakeRect(10, 0, 20, 20)];  // red left, blue right; turned below
    NSImage *upsideDown = [[quarters rotateBy:90] flipImageX:NO Y:YES];
    CHECK(isPixel(bitmapOf(upsideDown), 10, 2, 1, 0, 0) && isPixel(bitmapOf(upsideDown), 10, 17, 0, 0, 1));
    CHECK([empty flipImageX:YES Y:YES] == nil);
    USE("NSImage -rotateBy:");
    NSImage *turned = [image rotateBy:90];
    CHECK(NSEqualSizes(turned.size, NSMakeSize(20, 40)) && bitmapOf(turned).pixelsWide == 20 && bitmapOf(turned).pixelsHigh == 40);
    // Counterclockwise: the left of the picture goes to the bottom, which is the last row of the bitmap.
    CHECK(isPixel(bitmapOf(turned), 10, 35, 1, 0, 0) && isPixel(bitmapOf(turned), 10, 5, 0, 0, 1));
    NSImage *half = [image rotateBy:180];
    CHECK(NSEqualSizes(half.size, NSMakeSize(40, 20)) && isPixel(bitmapOf(half), 5, 10, 0, 0, 1) && isPixel(bitmapOf(half), 35, 10, 1, 0, 0));
    NSImage *diagonal = [image rotateBy:45];
    CHECK(near(diagonal.size.width, 60 / sqrt(2)) && near(diagonal.size.height, 60 / sqrt(2)) && [bitmapOf(diagonal) colorAtX:0 y:0].alphaComponent == 0);
    CHECK(NSEqualSizes([image rotateBy:0].size, image.size) && NSEqualSizes([image rotateBy:NAN].size, image.size) && [empty rotateBy:30] == nil);

    USE("NSImage -imageByScalingToSize:retinaSupport:proportionally:");
    NSImage *stretched = [image imageByScalingToSize:NSMakeSize(10, 10) retinaSupport:NO proportionally:NO];
    CHECK(NSEqualSizes(stretched.size, NSMakeSize(10, 10)) && bitmapOf(stretched).pixelsWide == 10 && bitmapOf(stretched).pixelsHigh == 10);
    CHECK(isPixel(bitmapOf(stretched), 1, 5, 1, 0, 0) && isPixel(bitmapOf(stretched), 8, 5, 0, 0, 1));
    NSImage *fitted = [image imageByScalingToSize:NSMakeSize(10, 10) retinaSupport:NO proportionally:YES];
    CHECK(NSEqualSizes(fitted.size, NSMakeSize(10, 5)) && bitmapOf(fitted).pixelsWide == 10 && bitmapOf(fitted).pixelsHigh == 5);
    float scale = [NSImage backingScaleNSImage];
    NSImage *retina = [image imageByScalingToSize:NSMakeSize(10, 10) retinaSupport:YES proportionally:NO];
    CHECK(NSEqualSizes(retina.size, NSMakeSize(10, 10)) && bitmapOf(retina).pixelsWide == lround(10 * scale));
    CHECK([image imageByScalingToSize:NSZeroSize retinaSupport:YES proportionally:YES] == nil && [image imageByScalingToSize:NSMakeSize(NAN, 5) retinaSupport:NO proportionally:NO] == nil);
    CHECK([empty imageByScalingToSize:NSMakeSize(10, 10) retinaSupport:NO proportionally:YES] == nil && [empty imageByScalingToSize:NSMakeSize(10, 10) retinaSupport:NO proportionally:NO] == nil);
    USE("NSImage -imageByScalingProportionallyToSize:retinaSupport:");
    NSImage *enlarged = [image imageByScalingProportionallyToSize:NSMakeSize(80, 80) retinaSupport:NO];
    CHECK(NSEqualSizes(enlarged.size, NSMakeSize(80, 40)) && bitmapOf(enlarged).pixelsWide == 80 && isPixel(bitmapOf(enlarged), 70, 20, 0, 0, 1));
    CHECK(bitmapOf([image imageByScalingProportionallyToSize:NSMakeSize(80, 80) retinaSupport:YES]).pixelsWide == lround(80 * scale));
    CHECK([image imageByScalingProportionallyToSize:NSZeroSize retinaSupport:NO] == nil);
    USE("NSImage -imageByScalingProportionallyToMaxSizeUsingNSImage:");
    NSImage *reduced = [image imageByScalingProportionallyToMaxSizeUsingNSImage:NSMakeSize(20, 20)];
    CHECK(NSEqualSizes(reduced.size, NSMakeSize(20, 10)) && bitmapOf(reduced).pixelsWide == 20 && isPixel(bitmapOf(reduced), 2, 5, 1, 0, 0));
    CHECK(NSEqualSizes([image imageByScalingProportionallyToMaxSizeUsingNSImage:NSMakeSize(400, 400)].size, NSMakeSize(40, 20)));
    CHECK(NSEqualSizes([image imageByScalingProportionallyToMaxSizeUsingNSImage:NSMakeSize(400, 10)].size, NSMakeSize(20, 10)));
    CHECK([image imageByScalingProportionallyToMaxSizeUsingNSImage:NSZeroSize] == nil && [empty imageByScalingProportionallyToMaxSizeUsingNSImage:NSMakeSize(5, 5)] == nil);
    USE("NSImage -imageWithOpaqueBackgroundColor:");
    NSBitmapImageRep *green = bitmapOf([clear imageWithOpaqueBackgroundColor:[NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:1]]);
    CHECK(green.pixelsWide == 8 && isPixel(green, 4, 4, 0, 1, 0) && [green colorAtX:4 y:4].alphaComponent == 1);
    CHECK(isPixel(bitmapOf([clear imageWithOpaqueBackgroundColor:nil]), 4, 4, 1, 1, 1));
    CHECK(isPixel(bitmapOf([image imageWithOpaqueBackgroundColor:NSColor.greenColor]), 5, 10, 1, 0, 0) && [empty imageWithOpaqueBackgroundColor:NSColor.greenColor] == nil);
    USE("NSImage -imageWithShadowOffset:blur:color:");
    NSImage *shadowed = [image imageWithShadowOffset:NSMakeSize(2, -2) blur:3 color:NSColor.blackColor];
    CHECK(NSEqualSizes(shadowed.size, NSMakeSize(50, 30)));
    // The image sits in the middle; the shadow falls below it and to its right, where the image was clear.
    CHECK(isPixel(bitmapOf(shadowed), 10, 15, 1, 0, 0) && [bitmapOf(shadowed) colorAtX:44 y:26].alphaComponent > 0.3 && [bitmapOf(shadowed) colorAtX:1 y:1].alphaComponent < 0.05);
    CHECK(NSEqualSizes([image imageWithShadowOffset:NSZeroSize blur:0 color:nil].size, image.size) && NSEqualSizes([image imageWithShadowOffset:NSMakeSize(1, 1) blur:NAN color:nil].size, NSMakeSize(42, 22)));
    CHECK([image imageWithShadowOffset:NSMakeSize(NAN, 0) blur:1 color:nil] == nil && [empty imageWithShadowOffset:NSMakeSize(1, 1) blur:1 color:nil] == nil);

    USE("NSImage +backingScaleNSImage");
    printf("backing scale: %g\n", scale);
    CHECK(scale >= 1 && scale <= 4);
    USE("NSImage +imageWithPreviewOfFileAtPath:ofSize:");
    NSString *pngPath = [folder stringByAppendingPathComponent:@"picture.png"], *textPath = [folder stringByAppendingPathComponent:@"notes.txt"];
    [png writeToFile:pngPath atomically:YES];
    [[@"text" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:textPath atomically:YES];
    NSImage *preview = [NSImage imageWithPreviewOfFileAtPath:pngPath ofSize:NSMakeSize(16, 16)];
    CHECK(NSEqualSizes(preview.size, NSMakeSize(16, 8)) && isPixel(bitmapOf(preview), 1, (int)(bitmapOf(preview).pixelsHigh / 2), 1, 0, 0));
    NSImage *icon = [NSImage imageWithPreviewOfFileAtPath:textPath ofSize:NSMakeSize(32, 32)];
    CHECK(icon && icon.size.width <= 32 && icon.size.height <= 32 && icon.size.width > 0);
    CHECK([NSImage imageWithPreviewOfFileAtPath:nil ofSize:NSMakeSize(16, 16)] == nil && [NSImage imageWithPreviewOfFileAtPath:[folder stringByAppendingPathComponent:@"absent.png"] ofSize:NSMakeSize(16, 16)] == nil);
    CHECK([NSImage imageWithPreviewOfFileAtPath:pngPath ofSize:NSZeroSize] == nil);
}

static void testColorsViewsWindows(void) {
    NSColor *orange = [NSColor colorWithSRGBRed:1 green:0.5 blue:0 alpha:0.5], *pattern = [NSColor colorWithPatternImage:twoHalves()];
    USE("NSColor -hexadecimalValue");
    CHECK(EQ([orange hexadecimalValue], @"#FF8000") && EQ([[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1] hexadecimalValue], @"#000000"));
    CHECK(EQ([[NSColor colorWithSRGBRed:0.02 green:1 blue:1 alpha:1] hexadecimalValue], @"#05FFFF") && [pattern hexadecimalValue] == nil);
    USE("NSColor -rgbaCSSValue");
    CHECK(EQ([orange rgbaCSSValue], @"rgba(255, 128, 0, 0.5)") && EQ([[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1] rgbaCSSValue], @"rgba(0, 0, 255, 1)"));
    CHECK(EQ([[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0] rgbaCSSValue], @"rgba(0, 0, 0, 0)") && EQ([[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.125] rgbaCSSValue], @"rgba(0, 0, 0, 0.125)"));
    CHECK(EQ([[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.05] rgbaCSSValue], @"rgba(0, 0, 0, 0.05)") && [pattern rgbaCSSValue] == nil);
    USE("NSColor -inverted");
    NSColor *inverted = [orange inverted];
    CHECK(isColor(inverted, 0, 0.5, 1) && near(inverted.alphaComponent, 0.5) && isColor([NSColor.blackColor inverted], 1, 1, 1) && [pattern inverted] == nil);
    USE("NSColor -oppsite");
    CHECK(isColor([[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] oppsite], 0, 1, 1) && isColor([[NSColor colorWithSRGBRed:0 green:1 blue:1 alpha:1] oppsite], 1, 0, 0));
    CHECK(isColor([[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1] oppsite], 1, 1, 0) && near([[orange oppsite] alphaComponent], 0.5));
    CHECK(isColor([NSColor.blackColor oppsite], 1, 1, 1) && isColor([NSColor.whiteColor oppsite], 0, 0, 0) && [pattern oppsite] == nil);
    USE("NSColor +colorFromHexString:");
    CHECK(isColor([NSColor colorFromHexString:@"#FF8000"], 1, 0.5, 0) && [NSColor colorFromHexString:@"#FF8000"].alphaComponent == 1);
    CHECK(isColor([NSColor colorFromHexString:@"f80"], 1, 0.533, 0) && near([NSColor colorFromHexString:@"0xFF800080"].alphaComponent, 0.5) && near([NSColor colorFromHexString:@" #f808 "].alphaComponent, 0.533));
    CHECK(EQ([[NSColor colorFromHexString:[orange hexadecimalValue]] hexadecimalValue], @"#FF8000"));
    CHECK([NSColor colorFromHexString:nil] == nil && [NSColor colorFromHexString:@""] == nil && [NSColor colorFromHexString:@"#GG0000"] == nil && [NSColor colorFromHexString:@"#12345"] == nil && [NSColor colorFromHexString:@"１２３"] == nil);

    USE("NSView -screenCapture");
    RedView *view = [[RedView alloc] initWithFrame:NSMakeRect(0, 0, 30, 20)];
    NSImage *capture = [view screenCapture];
    { NSColor *c = [[bitmapOf(capture) colorAtX:(int)(bitmapOf(capture).pixelsWide / 2) y:(int)(bitmapOf(capture).pixelsHigh / 2)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      printf("view capture: %g x %g points, %ld x %ld pixels, centre %.3f %.3f %.3f\n", capture.size.width, capture.size.height, (long)bitmapOf(capture).pixelsWide, (long)bitmapOf(capture).pixelsHigh, c.redComponent, c.greenComponent, c.blueComponent); }
    CHECK(NSEqualSizes(capture.size, NSMakeSize(30, 20)) && isPixel(bitmapOf(capture), (int)(bitmapOf(capture).pixelsWide / 2), (int)(bitmapOf(capture).pixelsHigh / 2), 1, 0, 0));
    CHECK([[[NSView alloc] initWithFrame:NSZeroRect] screenCapture] == nil);
    __block NSImage *fromAnotherThread = nil;
    __block BOOL returned = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        fromAnotherThread = [view screenCapture];
        returned = YES;
    });
    for (int i = 0; i < 200 && !returned; i++) spin(0.02);
    CHECK(returned && NSEqualSizes(fromAnotherThread.size, NSMakeSize(30, 20)));

    USE("NSWindow -isDarkMode");
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    CHECK([window isDarkMode]);
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    CHECK(![window isDarkMode]);
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    CHECK([window isDarkMode]);
    __block BOOL dark = NO;
    returned = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        dark = [window isDarkMode];
        returned = YES;
    });
    for (int i = 0; i < 200 && !returned; i++) spin(0.02);
    CHECK(returned && dark);
    [window close];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: probe <list.json> <implemented.json>\n"); return 2; }
        exercised = [NSMutableSet set];
        [NSApplication sharedApplication];
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"later-sdk-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        checkTypes(@(argv[1]), @(argv[2]));
        testStrings();
        testCollections();
        testData(folder);
        testDatesNumbersURLs();
        testThreadsAndObjects();
        testFiles(folder);
        testImages(folder);
        testColorsViewsWindows();
        // The same from a thread that is not the main one, for what does not need it.
        __block BOOL done = NO;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            @autoreleasepool {
                NSString *other = [folder stringByAppendingPathComponent:@"other-thread"];
                [NSFileManager.defaultManager createDirectoryAtPath:other withIntermediateDirectories:YES attributes:nil error:NULL];
                testStrings();
                testCollections();
                testData(other);
                testDatesNumbersURLs();
                testFiles(other);
                testImages(other);
            }
            done = YES;
        }];
        thread.stackSize = 8 << 20;
        [thread start];
        for (int i = 0; i < 3000 && !done; i++) spin(0.02);
        CHECK(done);
        [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
        NSArray *implemented = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[2])] options:0 error:NULL];
        for (NSString *entry in implemented) {
            if (![exercised containsObject:entry]) { failures++; fprintf(stderr, "FAIL %s was not exercised\n", entry.UTF8String); }
        }
        for (NSString *entry in exercised) {
            if (![implemented containsObject:entry]) { failures++; fprintf(stderr, "FAIL %s is exercised and not in the implemented list\n", entry.UTF8String); }
        }
        printf("%d checks, %lu of %lu selectors exercised, %d failures\n", checks, (unsigned long)exercised.count, (unsigned long)implemented.count, failures);
        return failures ? 1 : 0;
    }
}
