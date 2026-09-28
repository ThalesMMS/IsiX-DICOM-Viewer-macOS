#!/usr/bin/env python3
"""Exercise production ROI font selection/cache with real AppKit fonts.

The labels are pictures of the view's text layer (`HorosAnnotationText`,
#727): the real rasterizer is compiled with the ROI methods.
"""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(__file__).resolve().parents[1]
def source(name):
    path = 'Horos/Sources/' + name
    return (subprocess.check_output(['git', 'show', sys.argv[1] + ':' + path])
            if len(sys.argv) > 1 else (root / path).read_bytes()).decode('latin1')

roi = source('ROI.m')
a = roi.index('-(void)updateLabelFont')
b = roi.index('- (long) maxStringWidth:', a)
view = source('DCMView.m')
a2 = view.index('        labelFont = [[NSFont fontWithName:')
b2 = view.index('[ROI setFontHeight:', a2)
code = r'''
#import <Cocoa/Cocoa.h>
#import "AnnotationPresentation-Swift.h"
@interface TestWindow:NSObject
@property float backingScaleFactor;
@end
@implementation TestWindow
@end
@interface TestView:NSObject
@property(retain) TestWindow *window;
-(void)setNeedsDisplay:(BOOL)value;
@end
@implementation TestView
-(void)setNeedsDisplay:(BOOL)value{}
@end
@interface DCMView:TestView
@end
@implementation DCMView
@end
static inline HorosROICanvas *ROICanvasCurrent(void){return nil;}
@interface ROI:NSObject {NSCache *stringTextureCache;DCMView *curView;NSString *stringTex;NSMutableDictionary *stanStringAttrib;}
@end
@implementation ROI
METHODS
@end
// The picture's size in points for a string in a font: its size and margins.
static NSSize frameFor(NSString *s, NSFont *f) {NSSize z=[s sizeWithAttributes:@{NSFontAttributeName:f}];return NSMakeSize(ceil(z.width+8),ceil(z.height+4));}
static NSFont *viewerFont(void) {NSFont *labelFont=nil;
VIEW_FONT
return [labelFont autorelease];
}
#define check(...) do {if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 [NSApplication sharedApplication];
 NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
 for(NSString *name in @[@"Helvetica", @"Horos-Definitely-Uninstalled-QA-Font"]){
  ROI *r=[ROI new]; NSSize initial=NSZeroSize;
  for(NSNumber *size in @[@12,@13,@12]){
   [d setVolatileDomain:@{@"LabelFONTNAME":name,@"LabelFONTSIZE":size,
                         @"FONTNAME":@"Courier",@"FONTSIZE":@30}
                forName:NSArgumentDomain];
   [r updateLabelFont];
   HorosAnnotationText *t=[r stringTextureForString:@"Length: 5.501 cm"];
   NSFont *expected=viewerFont();
   check(expected.pointSize==size.doubleValue);
   check(NSEqualSizes(t.frameSize, frameFor(@"Length: 5.501 cm", expected)));
   check(t==[r stringTextureForString:@"Length: 5.501 cm"]);
   NSSize measured=t.frameSize;
   if(initial.width==0) initial=measured;
   else if(size.intValue==13) check(measured.width>initial.width);
   else check(NSEqualSizes(initial,measured));
   check([d integerForKey:@"FONTSIZE"]==30);
  }
  // A later series open reads the same defaults; it must not keep the size-13 texture.
  ROI *reopened=[ROI new];
  HorosAnnotationText *reopenedTexture=[reopened stringTextureForString:@"Length: 5.501 cm"];
  check(NSEqualSizes(initial,reopenedTexture.frameSize));
  [reopened release];
  [d setVolatileDomain:@{@"LabelFONTNAME":name,@"LabelFONTSIZE":@13,
                        @"FONTNAME":@"Courier",@"FONTSIZE":@30}
               forName:NSArgumentDomain];
  ROI *kept=[ROI new];
  check([kept stringTextureForString:@"Length: 5.501 cm"].frameSize.width>initial.width);
  [kept release];
  [r release];
 }
 ROI *r=[ROI new];TestView*v=[TestView new];v.window=[TestWindow new];
 [r setValue:v forKey:@"curView"];
 for(NSNumber*scale in @[@1,@2,@1,@2]){
  v.window.backingScaleFactor=scale.floatValue;
  HorosAnnotationText*t=[r stringTextureForString:@"Length: 5.501 cm"];
  // Layout reads the pixel size before any draw call, including on a cached ROI.
  check(t.pixelWidth==(NSInteger)(t.frameSize.width*scale.floatValue) && t.pixelHeight==(NSInteger)(t.frameSize.height*scale.floatValue));
  check(t==[r stringTextureForString:@"Length: 5.501 cm"]);
 }
 NSLog(@"PASS: installed/missing ROI fonts, cache refresh, 12/13/12 sizes, reopen defaults, viewer agreement, annotation independence, pre-draw 1x/2x layout sizes");
}}
'''.replace('METHODS', roi[a:b]).replace('VIEW_FONT', view[a2:b2])
with tempfile.TemporaryDirectory(prefix='horos-roi-font-') as d:
    p = Path(d)
    (p / 'test.m').write_text(code)
    swift = [str(root / 'Horos/Sources' / n) for n in ('AnnotationPresentation.swift', 'AnnotationOverlay.swift', 'ROICanvas.swift')]
    subprocess.run(['xcrun', 'swiftc', *swift, '-emit-library',
                    '-module-name', 'AnnotationPresentation',
                    '-emit-objc-header-path', str(p / 'AnnotationPresentation-Swift.h'),
                    '-o', str(p / 'libAnnotationPresentation.dylib')], check=True)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fsanitize=undefined', '-Wno-incompatible-pointer-types',
                    '-framework', 'Cocoa', '-I', str(p), str(p / 'test.m'), '-L', str(p),
                    '-lAnnotationPresentation', '-Wl,-rpath,' + str(p),
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
