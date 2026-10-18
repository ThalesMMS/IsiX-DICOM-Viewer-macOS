/*
 * Copyright 2008-2019, Torsten Curdt
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
// Modified in this fork: host runtime and platform API adaptations; upstream credits retained.


#import "FRFeedbackController.h"
#import "FRFeedbackReporter.h"
#import "FRUploader.h"
#import "FRCommand.h"
#import "FRApplication.h"
#import "FRCrashLogFinder.h"
#import "FRSystemProfile.h"
#import "FRConstants.h"
#import "FRConsoleLog.h"
#import "FRLocalizedString.h"

#import "NSMutableDictionary+Additions.h"

// Of the host's finder, beside the original interface.
@interface FRCrashLogFinder (HorosReportText)
+ (nullable NSString *)textOfReportAtURL:(NSURL *)url;
@end

// The window's layout, in points.
static const CGFloat FRWindowMargin = 20.0;
static const CGFloat FRMinimumContentWidth = 480.0;
static const CGFloat FRMessageHeight = 77.0;
static const CGFloat FRDetailsHeight = 300.0;
static const CGFloat FRButtonMinimumWidth = 96.0;

// Private interface.
@interface FRFeedbackController()
@property (readwrite, strong, nonatomic) IBOutlet NSArrayController *systemDiscovery;

@property (readwrite, weak, nonatomic) IBOutlet NSTextField *headingField;
@property (readwrite, weak, nonatomic) IBOutlet NSTextField *subheadingField;

@property (readwrite, weak, nonatomic) IBOutlet NSTextField *messageLabel;
#if (MAC_OS_X_VERSION_MIN_REQUIRED < 101200)
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *messageView;
#else
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *messageView;
#endif

@property (readwrite, weak, nonatomic) IBOutlet NSTextField *emailLabel;
@property (readwrite, weak, nonatomic) IBOutlet NSComboBox *emailBox;

@property (readwrite, weak, nonatomic) IBOutlet NSButton *detailsButton;
@property (readwrite, weak, nonatomic) IBOutlet NSTextField *detailsLabel;

@property (readwrite, weak, nonatomic) IBOutlet NSButton *sendDetailsCheckbox;

@property (readwrite, weak, nonatomic) IBOutlet NSTabView *tabView;

// Which of the two places the buttons follows: the details row when the tab
// view is hidden, the tab view when it is shown.
@property (readwrite, strong, nonatomic, nullable) NSLayoutConstraint *buttonsBelowDetailsRow;
@property (readwrite, strong, nonatomic, nullable) NSLayoutConstraint *buttonsBelowTabView;
@property (readwrite, strong, nonatomic, nullable) NSLayoutConstraint *detailsBelowEmail;
@property (readwrite, strong, nonatomic, nullable) NSLayoutConstraint *detailsBelowMessage;

// Even though they are not top-level objects, keep strong references to the tabViews because they are added/removed from their owning TabView, so something needs to hold on to them.
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabSystem;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabConsole;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabCrash;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabScript;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabPreferences;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabException;

@property (readwrite, weak, nonatomic) IBOutlet NSTableView *systemView;
#if (MAC_OS_X_VERSION_MIN_REQUIRED < 101200)
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *consoleView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *crashesView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *scriptView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *preferencesView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *exceptionView;
#else
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *consoleView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *crashesView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *scriptView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *preferencesView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *exceptionView;
#endif

@property (readwrite, weak, nonatomic) IBOutlet NSProgressIndicator *indicator;

@property (readwrite, weak, nonatomic) IBOutlet NSButton *cancelButton;
@property (readwrite, weak, nonatomic) IBOutlet NSButton *sendButton;

@property (readwrite, nonatomic) BOOL detailsShown;
@property (readwrite, strong, nonatomic, nullable) FRUploader *uploader;
@property (readwrite, strong, nonatomic) NSString *type;
@end

@implementation FRFeedbackController

#pragma mark Construction

- (instancetype) init
{
    self = [super initWithWindowNibName:@"FeedbackReporter"];
    if (self != nil) {
        _detailsShown = YES;
    }
    return self;
}

#pragma mark Accessors

- (void) setHeading:(NSString*)message
{
    assert(message);
    [[self headingField] setStringValue:message];
}

- (void) setSubheading:(NSString *)informativeText
{
    assert(informativeText);
    [[self subheadingField] setStringValue:informativeText];
}

- (void) setMessage:(NSString*)message
{
    [[self messageView] setString:message];
}

- (void) setException:(NSString*)exception
{
    [[self exceptionView] setString:exception];
}

#pragma mark information gathering

- (NSString*) consoleLog
{
    NSNumber *hours = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_LOGHOURS];

    int h = 24;

    if (hours != nil) {
        h = [hours intValue];
    }

    NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-h * 60.0 * 60.0];

    NSNumber *maximumSize = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_MAXCONSOLELOGSIZE];

    return [FRConsoleLog logSince:since maxSize:maximumSize];
}


- (NSArray*) systemProfile
{
    static NSArray *systemProfile = nil;

    static dispatch_once_t predicate = 0;
    dispatch_once(&predicate, ^{
        systemProfile = [FRSystemProfile discover];
    });

    return systemProfile;
}

- (NSString*) systemProfileAsString
{
    NSMutableString *string = [NSMutableString string];
    NSArray *dicts = [self systemProfile];
    for (NSDictionary *dict in dicts) {
        [string appendFormat:@"%@ = %@\n", [dict objectForKey:@"key"], [dict objectForKey:@"value"]];
    }
    return string;
}

- (NSString*) crashLog
{
    NSDate *lastSubmissionDate = [[NSUserDefaults standardUserDefaults] objectForKey:DEFAULTS_KEY_LASTSUBMISSIONDATE];
    if (lastSubmissionDate && ![lastSubmissionDate isKindOfClass:[NSDate class]]) {
        lastSubmissionDate = nil;
    }
    
    NSString *expectedPrefix = [FRApplication applicationName];
    NSArray *crashFiles = [FRCrashLogFinder findCrashLogsSince:lastSubmissionDate
                                                  withBaseName:expectedPrefix];
    
    NSLog(@"Found %lu crash files earlier than latest submission on: %@",
          (unsigned long)[crashFiles count],
          lastSubmissionDate);
    
    NSURL *latestCrashFileURL = [crashFiles lastObject];
    if (latestCrashFileURL == nil) {
        return @"";
    }
    
    NSLog(@"Chose newest crash file at: %@", latestCrashFileURL);
    
    // The finder reads the report: the system's .ips reports are JSON, and it puts
    // their readable lines first.
    NSString *fileContents = [FRCrashLogFinder textOfReportAtURL:latestCrashFileURL];
    if (fileContents == nil) {
        NSLog(@"Failed to read crash file at: %@", latestCrashFileURL);
        return @"";
    }
    
    return fileContents;
}

- (NSString*) scriptLog
{
    NSMutableString *scriptLog = [NSMutableString string];

    NSURL *scriptFileURL = [[NSBundle mainBundle] URLForResource:@"FRFeedbackReporter" withExtension:@"sh"];

    if (scriptFileURL) {
        FRCommand *cmd = [[FRCommand alloc] initWithFileURL:scriptFileURL args:@[]];
        [cmd setOutput:scriptLog];
        [cmd setError:scriptLog];
        int ret = [cmd execute];

        NSLog(@"Script exit code = %d", ret);
    }

    return scriptLog;
}

- (NSString*) preferences
{
    NSMutableDictionary *preferences = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:[FRApplication applicationIdentifier]] mutableCopy];

    if (preferences == nil) {
        return @"";
    }

    [preferences removeObjectForKey:DEFAULTS_KEY_SENDEREMAIL];

    id<FRFeedbackReporterDelegate> strongDelegate = [self delegate];
    if ([strongDelegate respondsToSelector:@selector(anonymizePreferencesForFeedbackReport:)]) {
        NSDictionary *newPreferences = [strongDelegate anonymizePreferencesForFeedbackReport:preferences];
        assert(newPreferences);
        return [NSString stringWithFormat:@"%@", newPreferences];
    }
    else {
        return [NSString stringWithFormat:@"%@", preferences];
    }
}


#pragma mark UI Actions

// The tab view is hidden rather than shrunk: a tab view resized to no height
// by its springs loses the frames of its pages and draws them over the rows
// above and below it. The buttons then follow the details row instead, and the
// window takes the height its content asks for, keeping its top edge.
- (void) setDetailsVisible:(BOOL)show
{
    NSLayoutConstraint *place = show ? [self buttonsBelowTabView] : [self buttonsBelowDetailsRow];
    NSLayoutConstraint *other = show ? [self buttonsBelowDetailsRow] : [self buttonsBelowTabView];
    [[self tabView] setHidden:!show];
    // One place at a time: both at once cannot be satisfied, and the layout
    // engine would drop another constraint for good to recover.
    [other setActive:NO];
    [place setActive:YES];
    [self setDetailsShown:show];
    [self fitWindowToContent];
}

- (IBAction) showDetails:(id)sender
{
    assert([sender isKindOfClass:[NSControl class]]);
    BOOL show = [[sender objectValue] boolValue];
    [self setDetailsVisible:show];
}

#pragma mark Layout

// A label whose text wraps within the given width and asks for the height of
// the wrapped text.
- (void) wrapLabel:(NSTextField *)label width:(CGFloat)width
{
    [[label cell] setWraps:YES];
    [[label cell] setScrollable:NO];
    [label setUsesSingleLineMode:NO];
    [label setLineBreakMode:NSLineBreakByWordWrapping];
    [label setPreferredMaxLayoutWidth:width];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationVertical];
}

// Each page of the tab view holds one scroll view, placed by springs the nib
// gives differently per page. Pin it to the page instead.
- (void) pinPageContentOfTabViewItem:(NSTabViewItem *)item
{
    NSView *page = [item view];
    for (NSView *view in [page subviews]) {
        [view setTranslatesAutoresizingMaskIntoConstraints:NO];
        [NSLayoutConstraint activateConstraints:@[
            [[view leadingAnchor] constraintEqualToAnchor:[page leadingAnchor] constant:12.0],
            [[view trailingAnchor] constraintEqualToAnchor:[page trailingAnchor] constant:-12.0],
            [[view topAnchor] constraintEqualToAnchor:[page topAnchor] constant:12.0],
            [[view bottomAnchor] constraintEqualToAnchor:[page bottomAnchor] constant:-12.0],
        ]];
    }
}

// The nib places the controls with fixed frames and springs from an older
// system, sized for its English texts. Translated texts are cut, and hiding the
// details collapses the tab view over the other rows. Replace the frames with
// constraints derived from the content: the labels wrap within the window
// width, the window is wide enough for every tab of the details, and its height
// follows the rows that are shown.
- (void) installContentLayout
{
    NSWindow *window = [self window];
    NSView *content = [window contentView];
    NSTabView *tabView = [self tabView];

    // The nib's application icon has no outlet.
    NSImageView *icon = nil;
    for (NSView *view in [content subviews]) {
        [view setTranslatesAutoresizingMaskIntoConstraints:NO];
        if ([view isKindOfClass:[NSImageView class]]) {
            icon = (NSImageView *)view;
        }
    }
    NSScrollView *messageScrollView = [[self messageView] enclosingScrollView];
    assert(icon && messageScrollView);

    NSArray<NSTabViewItem *> *pages = @[[self tabSystem], [self tabConsole], [self tabCrash],
                                         [self tabScript], [self tabPreferences], [self tabException]];
    for (NSTabViewItem *item in pages) {
        [self pinPageContentOfTabViewItem:item];
    }

    // All six pages are in the tab view while the nib is fresh, with their
    // translated labels: its minimum size then fits every tab.
    NSSize tabMinimum = [tabView minimumSize];
    CGFloat width = MAX(FRMinimumContentWidth, ceil(tabMinimum.width) + 2.0 * FRWindowMargin);
    CGFloat textWidth = width - 2.0 * FRWindowMargin;
    CGFloat headingLeading = FRWindowMargin + NSWidth([icon frame]) + FRWindowMargin;

    [self wrapLabel:[self headingField] width:width - headingLeading - FRWindowMargin];
    [self wrapLabel:[self subheadingField] width:width - headingLeading - FRWindowMargin];
    [self wrapLabel:[self messageLabel] width:textWidth];
    [self wrapLabel:[self emailLabel] width:textWidth];

    NSButton *disclosure = [self detailsButton];
    NSButton *checkbox = [self sendDetailsCheckbox];
    NSTextField *detailsLabel = [self detailsLabel];
    NSButton *send = [self sendButton];
    NSButton *cancel = [self cancelButton];
    NSProgressIndicator *indicator = [self indicator];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    [constraints addObject:[[content widthAnchor] constraintEqualToConstant:width]];

    // Icon, heading and subheading.
    [constraints addObjectsFromArray:@[
        [[icon leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:FRWindowMargin],
        [[icon topAnchor] constraintEqualToAnchor:[content topAnchor] constant:FRWindowMargin],
        [[icon widthAnchor] constraintEqualToConstant:NSWidth([icon frame])],
        [[icon heightAnchor] constraintEqualToConstant:NSHeight([icon frame])],
        [[[self headingField] leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:headingLeading],
        [[[self headingField] trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-FRWindowMargin],
        [[[self headingField] topAnchor] constraintEqualToAnchor:[icon topAnchor]],
        [[[self subheadingField] leadingAnchor] constraintEqualToAnchor:[[self headingField] leadingAnchor]],
        [[[self subheadingField] trailingAnchor] constraintEqualToAnchor:[[self headingField] trailingAnchor]],
        [[[self subheadingField] topAnchor] constraintEqualToAnchor:[[self headingField] bottomAnchor] constant:8.0],
    ]];

    // The message starts below the lower of the icon and the subheading.
    NSLayoutConstraint *messageUp = [[[self messageLabel] topAnchor] constraintEqualToAnchor:[content topAnchor]];
    [messageUp setPriority:NSLayoutPriorityFittingSizeCompression];
    [constraints addObjectsFromArray:@[
        [[[self messageLabel] topAnchor] constraintGreaterThanOrEqualToAnchor:[icon bottomAnchor] constant:16.0],
        [[[self messageLabel] topAnchor] constraintGreaterThanOrEqualToAnchor:[[self subheadingField] bottomAnchor] constant:16.0],
        messageUp,
    ]];

    // Message, email and details rows, all as wide as the window allows.
    for (NSView *view in @[[self messageLabel], messageScrollView, [self emailLabel], [self emailBox], tabView]) {
        [constraints addObject:[[view leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:FRWindowMargin]];
        [constraints addObject:[[view trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-FRWindowMargin]];
    }
    [constraints addObjectsFromArray:@[
        [[messageScrollView topAnchor] constraintEqualToAnchor:[[self messageLabel] bottomAnchor] constant:6.0],
        [[messageScrollView heightAnchor] constraintEqualToConstant:FRMessageHeight],
        [[[self emailLabel] topAnchor] constraintEqualToAnchor:[messageScrollView bottomAnchor] constant:12.0],
        [[[self emailBox] topAnchor] constraintEqualToAnchor:[[self emailLabel] bottomAnchor] constant:6.0],

        // The details row: the disclosure triangle, then either its label or the
        // "send details" checkbox, whichever the application's settings show.
        [[disclosure leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:FRWindowMargin],
        [[disclosure centerYAnchor] constraintEqualToAnchor:[checkbox centerYAnchor]],
        [[checkbox leadingAnchor] constraintEqualToAnchor:[disclosure trailingAnchor] constant:6.0],
        [[checkbox trailingAnchor] constraintLessThanOrEqualToAnchor:[content trailingAnchor] constant:-FRWindowMargin],
        [[detailsLabel leadingAnchor] constraintEqualToAnchor:[disclosure trailingAnchor] constant:4.0],
        [[detailsLabel trailingAnchor] constraintLessThanOrEqualToAnchor:[content trailingAnchor] constant:-FRWindowMargin],
        [[detailsLabel centerYAnchor] constraintEqualToAnchor:[checkbox centerYAnchor]],

        [[tabView topAnchor] constraintEqualToAnchor:[checkbox bottomAnchor] constant:8.0],
        [[tabView heightAnchor] constraintEqualToConstant:MAX(FRDetailsHeight, ceil(tabMinimum.height))],

        // Cancel and Send at the bottom right, the progress indicator at the left.
        [[send trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-FRWindowMargin],
        [[send bottomAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:-FRWindowMargin],
        [[send widthAnchor] constraintGreaterThanOrEqualToConstant:FRButtonMinimumWidth],
        [[cancel trailingAnchor] constraintEqualToAnchor:[send leadingAnchor] constant:-12.0],
        [[cancel firstBaselineAnchor] constraintEqualToAnchor:[send firstBaselineAnchor]],
        [[cancel widthAnchor] constraintGreaterThanOrEqualToConstant:FRButtonMinimumWidth],
        [[indicator leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:FRWindowMargin],
        [[indicator centerYAnchor] constraintEqualToAnchor:[send centerYAnchor]],
        [[cancel leadingAnchor] constraintGreaterThanOrEqualToAnchor:[indicator trailingAnchor] constant:12.0],
    ]];
    // The details row follows the e-mail row, or the message when the e-mail
    // row is hidden.
    [self setDetailsBelowEmail:[[checkbox topAnchor] constraintEqualToAnchor:[[self emailBox] bottomAnchor] constant:12.0]];
    [self setDetailsBelowMessage:[[checkbox topAnchor] constraintEqualToAnchor:[messageScrollView bottomAnchor] constant:12.0]];
    [constraints addObject:[self detailsBelowEmail]];
    [NSLayoutConstraint activateConstraints:constraints];

    [self setButtonsBelowTabView:[[send topAnchor] constraintEqualToAnchor:[tabView bottomAnchor] constant:12.0]];
    [self setButtonsBelowDetailsRow:[[send topAnchor] constraintEqualToAnchor:[checkbox bottomAnchor] constant:FRWindowMargin]];

    [self setDetailsVisible:[self detailsShown]];
}

// Size the window to its content, keeping its top edge where it is.
- (void) fitWindowToContent
{
    NSWindow *window = [self window];
    NSView *content = [window contentView];
    NSSize size = [content fittingSize];
    NSRect frame = [window frameRectForContentRect:NSMakeRect(0.0, 0.0, size.width, size.height)];
    NSRect current = [window frame];
    frame.origin.x = NSMinX(current);
    frame.origin.y = NSMaxY(current) - NSHeight(frame);
    // The nib's minimum size is the old expanded height; it would hold the
    // window open below the buttons once the details are hidden.
    [window setMinSize:frame.size];
    [window setMaxSize:frame.size];
    [window setFrame:frame display:YES];
}

- (IBAction) cancel:(id)sender
{
    (void)sender;

    [[self uploader] cancel];
    [self setUploader:nil];

    [self close];
}

- (IBAction) send:(id)sender
{
    (void)sender;

    if ([self uploader] != nil) {
        NSLog(@"Still uploading");
        return;
    }

    // Without a server, Send used to log a missing Info.plist key and leave
    // the window open: the report went nowhere.
    NSURL *url = [self uploadURL];
    if (url == nil) {
        [self saveReport];
        return;
    }

    // Reachability is only a snapshot and cannot predict whether this upload
    // succeeds. Let NSURLSession attempt it and report its actual error through
    // the existing uploaderFailed:withError: flow, which keeps retry available.
    FRUploader* uploader = [[FRUploader alloc] initWithTargetURL:url delegate:self];
    [self setUploader:uploader];

    NSDictionary *dict = [self reportFields];

    NSLog(@"Sending feedback to %@", url);

    [uploader postAndNotify:dict];
}

// The delegate's server, else the Info.plist's; nil when there is neither.
- (nullable NSURL *) uploadURL
{
    id<FRFeedbackReporterDelegate> strongDelegate = [self delegate];
    if ([strongDelegate respondsToSelector:@selector(targetURLForFeedbackReport)]) {
        return [strongDelegate targetURLForFeedbackReport];
    }
    NSString *target = [FRApplication feedbackURL];
    if (target == nil) {
        return nil;
    }
    NSURL *url = [NSURLComponents componentsWithString:target].URL;
    if (url == nil) {
        NSLog(@"Invalid feedback URL: %@", target);
    }
    return url;
}

// The fields of the report, as posted to a server.
- (NSDictionary *) reportFields
{
    id<FRFeedbackReporterDelegate> strongDelegate = [self delegate];
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    if (![[self emailBox] isHidden]) {
        [dict setValidString:[[self emailBox] stringValue]
                      forKey:POST_KEY_EMAIL];
    }

    [dict setValidString:[[self messageView] string]
                  forKey:POST_KEY_MESSAGE];

    [dict setValidString:[self type]
                  forKey:POST_KEY_TYPE];

    [dict setValidString:[FRApplication applicationShortVersion]
                  forKey:POST_KEY_VERSION_SHORT];

    [dict setValidString:[FRApplication applicationBundleVersion]
                  forKey:POST_KEY_VERSION_BUNDLE];

    [dict setValidString:[FRApplication applicationVersion]
                  forKey:POST_KEY_VERSION];

    if ([[self sendDetailsCheckbox] state] == NSControlStateValueOn) {
        if ([strongDelegate respondsToSelector:@selector(customParametersForFeedbackReport)]) {
            NSDictionary *customParams = [strongDelegate customParametersForFeedbackReport];
            if (customParams) {
                [dict addEntriesFromDictionary:customParams];
            }
        }

        [dict setValidString:[self systemProfileAsString]
                      forKey:POST_KEY_SYSTEM];

        [dict setValidString:[[self consoleView] string]
                      forKey:POST_KEY_CONSOLE];

        [dict setValidString:[[self crashesView] string]
                      forKey:POST_KEY_CRASHES];

        [dict setValidString:[[self scriptView] string]
                      forKey:POST_KEY_SHELL];

        [dict setValidString:[[self preferencesView] string]
                      forKey:POST_KEY_PREFERENCES];

        [dict setValidString:[[self exceptionView] string]
                      forKey:POST_KEY_EXCEPTION];
    }

    return dict;
}

#pragma mark Saving without a server

// The fields as plain text: one section per field, in the order of the window,
// then any field the delegate added.
- (NSString *) reportText
{
    NSDictionary *fields = [self reportFields];
    NSArray *order = @[POST_KEY_TYPE, POST_KEY_VERSION, POST_KEY_EMAIL, POST_KEY_MESSAGE,
                       POST_KEY_SYSTEM, POST_KEY_CONSOLE, POST_KEY_CRASHES, POST_KEY_SHELL,
                       POST_KEY_PREFERENCES, POST_KEY_EXCEPTION];
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *key in order) {
        if ([fields objectForKey:key] != nil) {
            [keys addObject:key];
        }
    }
    NSMutableArray *others = [[fields allKeys] mutableCopy];
    [others removeObjectsInArray:order];
    [others removeObjectsInArray:@[POST_KEY_VERSION_SHORT, POST_KEY_VERSION_BUNDLE]];
    [keys addObjectsFromArray:[others sortedArrayUsingSelector:@selector(compare:)]];

    NSMutableString *text = [NSMutableString stringWithFormat:@"%@\n%@\n",
                             [FRApplication applicationName] ?: @"",
                             [[NSProcessInfo processInfo] operatingSystemVersionString]];
    for (NSString *key in keys) {
        NSString *value = [NSString stringWithFormat:@"%@", [fields objectForKey:key]];
        [text appendFormat:@"\n== %@ ==\n%@\n", key, value];
    }
    return text;
}

// Without a server to post to, the report goes to a file the user chooses and
// is shown in the Finder. Nothing is sent, and the panel warns that the file
// can hold patient data.
- (void) saveReport
{
    NSString *report = [self reportText];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    [formatter setDateFormat:@"yyyy-MM-dd HH.mm.ss"];
    NSString *fileName = [NSString stringWithFormat:@"%@ %@ %@.txt",
                          [FRApplication applicationName] ?: @"Report",
                          [self type] ?: FR_FEEDBACK,
                          [formatter stringFromDate:[NSDate date]]];

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:fileName];
    [panel setCanCreateDirectories:YES];
    [panel setMessage:NSLocalizedString(@"Please notice this report might contain patient data.", @"Crash report save panel")];

    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        NSURL *reportURL = [panel URL];
        if (result != NSModalResponseOK || reportURL == nil) {
            return;
        }

        NSError *error = nil;
        if (![report writeToURL:reportURL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            NSLog(@"Failed to save the report to %@: %@", reportURL, error);
            NSAlert *alert = [[NSAlert alloc] init];
            [alert addButtonWithTitle:FRLocalizedString(@"OK", nil)];
            [alert setMessageText:NSLocalizedString(@"The report could not be saved.", @"Crash report save failure")];
            [alert setInformativeText:[NSString stringWithFormat:FRLocalizedString(@"Error: %@", nil), [error localizedDescription]]];
            [alert setAlertStyle:NSAlertStyleWarning];
            [alert beginSheetModalForWindow:[self window] completionHandler:nil];
            return;
        }

        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[reportURL]];

        // As after an upload: the next report lists the crashes after this one.
        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                                  forKey:DEFAULTS_KEY_LASTSUBMISSIONDATE];
        [self close];
    }];
}

- (void) uploaderStarted:(FRUploader*)pUploader
{
    assert(pUploader); (void)pUploader;

    // NSLog(@"Upload started");

    [[self indicator] setHidden:NO];
    [[self indicator] startAnimation:self];

    [[self messageView] setEditable:NO];
    [[self sendButton] setEnabled:NO];
}

- (void) uploaderFailed:(FRUploader*)pUploader withError:(NSError*)error
{
    assert(pUploader); (void)pUploader;

    NSLog(@"Upload failed: %@", error);

    [[self indicator] stopAnimation:self];
    [[self indicator] setHidden:YES];

    [self setUploader:nil];

    [[self messageView] setEditable:YES];
    [[self sendButton] setEnabled:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:FRLocalizedString(@"OK", nil)];
    [alert setMessageText:FRLocalizedString(@"Sorry, failed to submit your feedback to the server.", nil)];
    [alert setInformativeText:[NSString stringWithFormat:FRLocalizedString(@"Error: %@", nil), [error localizedDescription]]];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];

    [self close];
}

- (void) uploaderFinished:(FRUploader*)pUploader
{
    assert(pUploader); (void)pUploader;

    // NSLog(@"Upload finished");

    [[self indicator] stopAnimation:self];
    [[self indicator] setHidden:YES];

    NSString *response = [[self uploader] response];

    [self setUploader:nil];

    [[self messageView] setEditable:YES];
    [[self sendButton] setEnabled:YES];

    NSArray *lines = [response componentsSeparatedByString:@"\n"];
    for (NSString *line in [lines reverseObjectEnumerator]) {
        if ([line length] == 0) {
            continue;
        }

        if (![line hasPrefix:@"OK "]) {

            NSLog (@"Failed to submit to server: %@", response);

            NSAlert *alert = [[NSAlert alloc] init];
            [alert addButtonWithTitle:FRLocalizedString(@"OK", nil)];
            [alert setMessageText:FRLocalizedString(@"Sorry, failed to submit your feedback to the server.", nil)];
            [alert setInformativeText:[NSString stringWithFormat:FRLocalizedString(@"Error: %@", nil), line]];
            [alert setAlertStyle:NSAlertStyleWarning];
            [alert runModal];

            return;
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                              forKey:DEFAULTS_KEY_LASTSUBMISSIONDATE];
    
    [[NSUserDefaults standardUserDefaults] setObject:[[self emailBox] stringValue]
                                              forKey:DEFAULTS_KEY_SENDEREMAIL];

    [self close];
}

- (void) windowWillClose: (NSNotification *) n
{
    assert(n); (void)n;

    [[self uploader] cancel];

    if ([[self type] isEqualToString:FR_EXCEPTION]) {
        NSString *exitAfterException = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_EXITAFTEREXCEPTION];
        if (exitAfterException && [exitAfterException isEqualToString:@"YES"]) {
            // We want a pure exit() here I think.
            // As an exception has already been raised there is no
            // guarantee that the code path to [NSAapp terminate] is functional.
            // Calling abort() will crash the app here but is that more desirable?
            exit(EXIT_FAILURE);
        }
    }
}

- (void) windowDidLoad
{
    [[self window] setDelegate:self];

    [[self window] setTitle:FRLocalizedString(@"Feedback", nil)];

    [[self emailLabel] setStringValue:FRLocalizedString(@"Email address:", nil)];
    [[self detailsLabel] setStringValue:FRLocalizedString(@"Details", nil)];

    [[self tabSystem] setLabel:FRLocalizedString(@"System", nil)];
    [[self tabConsole] setLabel:FRLocalizedString(@"Console", nil)];
    [[self tabCrash] setLabel:FRLocalizedString(@"CrashLog", nil)];
    [[self tabScript] setLabel:FRLocalizedString(@"Script", nil)];
    [[self tabPreferences] setLabel:FRLocalizedString(@"Preferences", nil)];
    [[self tabException] setLabel:FRLocalizedString(@"Exception", nil)];

    [[self sendButton] setTitle:FRLocalizedString(@"Send", nil)];
    [[self cancelButton] setTitle:FRLocalizedString(@"Cancel", nil)];

    // Use a fixed pitch font for the text views that show code-like things.
    // Oddly, setting the font in the xib doesn't seem to work.
    NSFont *font = [NSFont userFixedPitchFontOfSize:[NSFont labelFontSize]];

    NSString *emptyString = @"";

    [[[self consoleView] textContainer] setWidthTracksTextView:NO];
    [[self consoleView] setString:emptyString];
    [[self consoleView] setFont:font];

    [[[self crashesView] textContainer] setWidthTracksTextView:NO];
    [[self crashesView] setString:emptyString];
    [[self crashesView] setFont:font];

    [[[self scriptView] textContainer] setWidthTracksTextView:NO];
    [[self scriptView] setString:emptyString];
    [[self scriptView] setFont:font];

    [[[self preferencesView] textContainer] setWidthTracksTextView:NO];
    [[self preferencesView] setString:emptyString];
    [[self preferencesView] setFont:font];

    [[[self exceptionView] textContainer] setWidthTracksTextView:NO];
    [[self exceptionView] setString:emptyString];
    [[self exceptionView] setFont:font];

    [self installContentLayout];
}

- (void) stopSpinner
{
    [[self indicator] stopAnimation:self];
    [[self indicator] setHidden:YES];
    [[self sendButton] setEnabled:YES];
}

- (void) insertTabViewItemInCorrectOrder:(NSTabViewItem *)inTabViewItem
{
    assert(inTabViewItem);

    // If it's already present, do nothing.
    if ([[self tabView] indexOfTabViewItem:inTabViewItem] != NSNotFound) {
        return;
    }

    NSString *identifier = [inTabViewItem identifier];
    assert(identifier);
    
    // This is the order we want them in.
    NSArray *orderedIdentifiers = @[@"System",
                                    @"Console",
                                    @"Crashes",
                                    @"Shell",
                                    @"Preferences",
                                    @"Exception"];
    NSUInteger fullIndex = [orderedIdentifiers indexOfObject:identifier];
    assert(fullIndex != NSNotFound);

    // Determine the index to insert at. If there are no items yet, we'll insert at the beginning.
    NSInteger runningIndex = 0;
    NSArray *existingTabItems = [[self tabView] tabViewItems];
    for (NSTabViewItem *item in existingTabItems)
    {
        NSString *testIdentifier = [item identifier];
        NSUInteger testFullIndex = [orderedIdentifiers indexOfObject:testIdentifier];
        assert(testFullIndex != NSNotFound);
        assert(testFullIndex != fullIndex);
        if (fullIndex < testFullIndex)
        {
            // We found the index to insert.
            break;
        }
        runningIndex++;
    }

    // Insert the given TabViewItem at the calculated index.
    [[self tabView] insertTabViewItem:inTabViewItem atIndex:runningIndex];
}

- (void) populateSystemTab:(NSArray *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabSystem]];
    [[self systemDiscovery] setContent:inInfo];
}

- (void) populateConsoleTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabConsole]];
    [[self consoleView] setString:inInfo];
}

- (void) populateCrashTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabCrash]];
    [[self crashesView] setString:inInfo];
}

- (void) populateScriptTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabScript]];
    [[self scriptView] setString:inInfo];
}

- (void) populatePreferencesTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabPreferences]];
    [[self preferencesView] setString:inInfo];
}

- (void) populateExceptionTab
{
    [self insertTabViewItemInCorrectOrder:[self tabException]];
    // exceptionView's string was set elsewhere
}

- (void) populateAllTabViews
{
    NSString *reportType = [self type];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t workQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    __weak FRFeedbackController *weakSelf = self;

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSArray *systemProfile = [FRSystemProfile discover];
        if ([systemProfile count] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populateSystemTab:systemProfile];
            });
        }
    });

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSString *consoleLog = [weakSelf consoleLog];
        if ([consoleLog length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populateConsoleTab:consoleLog];
            });
        }
    });

    if ([reportType isEqualToString:FR_CRASH]) {
        dispatch_group_async(group, workQueue, ^{
            //sleep(5 + arc4random_uniform(10));
            NSString *crashLog = [weakSelf crashLog];
            if ([crashLog length] > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf populateCrashTab:crashLog];
                });
            }
        });
    }

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSString *scriptLog = [weakSelf scriptLog];
        if ([scriptLog length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populateScriptTab:scriptLog];
            });
        }
    });

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSString *preferences = [weakSelf preferences];
        if ([preferences length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populatePreferencesTab:preferences];
            });
        }
    });

    if ([reportType isEqualToString:FR_EXCEPTION]) {
       [self populateExceptionTab];
    }

    // When they've all finished, stop the spinner animating.
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [weakSelf stopSpinner];
    });
}

- (void) reset
{
    // Remove them all because we don't know which we'll need to show. But keep the "System" tab because it can always show something. Also select it, because the other tab views have weird resizing issues if they are selected before they are populated.
    [[self tabView] removeTabViewItem:[self tabConsole]];
    [[self tabView] removeTabViewItem:[self tabCrash]];
    [[self tabView] removeTabViewItem:[self tabScript]];
    [[self tabView] removeTabViewItem:[self tabPreferences]];
    [[self tabView] removeTabViewItem:[self tabException]];
    [[self tabView] selectTabViewItemWithIdentifier:@"System"];

    // The addresses offered are "anonymous" and the one last used. The user's
    // contact card is not read: on the main thread, that waits for an answer
    // to the system's Contacts permission prompt.
    [[self emailBox] removeAllItems];

    [[self emailBox] addItemWithObjectValue:FRLocalizedString(@"anonymous", nil)];

    NSInteger found = NSNotFound;
    NSString *email = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_KEY_SENDEREMAIL];
    if ([email length] > 0) {
        found = [[self emailBox] indexOfItemWithObjectValue:email];
        if (found == NSNotFound) {
            [[self emailBox] addItemWithObjectValue:email];
            found = [[self emailBox] indexOfItemWithObjectValue:email];
        }
    }
    if (found != NSNotFound) {
        [[self emailBox] selectItemAtIndex:found];
    } else if ([[self emailBox] numberOfItems] >= 2) {
        NSString *defaultSender = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_DEFAULTSENDER];
        NSUInteger idx = (defaultSender && [defaultSender isEqualToString:@"firstEmail"]) ? 1 : 0;
        [[self emailBox] selectItemAtIndex:idx];
    }

    [[self headingField] setStringValue:@""];
    [[self messageView] setString:@""];
    [[self exceptionView] setString:@""];

    [[self detailsButton] setIntValue:NO];

    [[self indicator] setHidden:NO];
    [[self indicator] startAnimation:self];
    [[self sendButton] setEnabled:NO];

    //  setup 'send details' checkbox...
    [[self sendDetailsCheckbox] setTitle:FRLocalizedString(@"Send details", nil)];
    [[self sendDetailsCheckbox] setState:NSControlStateValueOn];
    NSString *sendDetailsIsOptional = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_SENDDETAILSISOPTIONAL];
    if (sendDetailsIsOptional && [sendDetailsIsOptional isEqualToString:@"YES"]) {
        [[self detailsLabel] setHidden:YES];
        [[self sendDetailsCheckbox] setHidden:NO];
    } else {
        [[self detailsLabel] setHidden:NO];
        [[self sendDetailsCheckbox] setHidden:YES];
    }

    [self setDetailsVisible:NO];
}

- (void) showWindow:(id)sender
{
    NSString *reportType = [self type];
    if ([reportType isEqualToString:FR_FEEDBACK]) {
        [[self messageLabel] setStringValue:FRLocalizedString(@"Feedback comment label", nil)];
    } else {
        [[self messageLabel] setStringValue:FRLocalizedString(@"Comments:", nil)];
    }

    [self populateAllTabViews];

    // Without a server the button saves the report, and the window says so
    // instead of promising to send it.
    // Nothing is sent without a server, so nobody can answer: the e-mail row
    // is hidden and the details row moves up to the message.
    BOOL uploads = [self uploadURL] != nil;
    [[self emailLabel] setHidden:!uploads];
    [[self emailBox] setHidden:!uploads];
    NSLayoutConstraint *place = uploads ? [self detailsBelowEmail] : [self detailsBelowMessage];
    NSLayoutConstraint *other = uploads ? [self detailsBelowMessage] : [self detailsBelowEmail];
    [other setActive:NO];
    [place setActive:YES];

    if (uploads) {
        [[self sendButton] setTitle:FRLocalizedString(@"Send", nil)];
    } else {
        [[self sendButton] setTitle:NSLocalizedString(@"Save Report...", @"Crash report button")];
        [self setSubheading:[reportType isEqualToString:FR_FEEDBACK]
            ? NSLocalizedString(@"Save this report to keep a record of your feedback. Click Details to see what it contains.", @"Feedback window without a server")
            : NSLocalizedString(@"Save this report to keep a record of the problem. Click Details to see what it contains.", @"Crash report window without a server")];
    }

    // The heading and labels were just set; the window takes their height.
    [self fitWindowToContent];

    [super showWindow:sender];
}

- (BOOL) isShown
{
    NSWindow *window = [self window];
    return [window isVisible];
}

@end
