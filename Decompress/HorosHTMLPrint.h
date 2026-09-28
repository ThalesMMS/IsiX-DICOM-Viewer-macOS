#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

// Decompress's HTML report converter, and its focused integration probe.
// WebKit discovers printable page bounds asynchronously. A synchronous
// runOperation can finish before that discovery and silently omit pages.
//
// This header declares; HorosHTMLPrint.m implements. It lives beside
// Decompress, the only program that links the implementation, and not in
// Horos/Sources, whose headers the plugin SDK publishes: there it defined the
// class and both functions in every plugin that included <Horos/Horos.h>.
@interface HorosHTMLPrintSession : NSObject <WKNavigationDelegate>
@property BOOL loaded;
@property BOOL failed;
@property BOOL printed;
@property BOOL succeeded;
@end

// Prints the HTML file at path to a new PDF at destination, on the main thread,
// within timeout seconds. NO, and no file at destination, on any failure; an
// existing destination is never overwritten.
FOUNDATION_EXTERN BOOL HorosPrintHTMLToPDF(NSString *path, NSString *destination, NSTimeInterval timeout);

// Regenerates <path>.pdf through a fresh sibling replaced atomically: on
// failure the previous PDF stays, and the HTML original is never moved.
FOUNDATION_EXTERN BOOL HorosUpdateHTMLReportPDF(NSString *path, NSTimeInterval timeout);
