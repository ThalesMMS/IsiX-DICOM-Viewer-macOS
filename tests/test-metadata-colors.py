#!/usr/bin/env python3
"""Compile the production cell delegate and check contrast/styling across AppKit appearances.
Optional git revision reproduces pre-fix contrast failures. No DICOM files are needed.
"""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parent.parent
# XMLController is Swift since #828: the Swift method is compiled into a Swift
# fixture with the same checks. A revision before it compiles the Objective-C one.
sys.path.insert(0,str(root/'tests'))
from sources import source_text
def former(revision):
 try: return subprocess.check_output(['git','show',revision+':Horos/Sources/XMLController.m'],stderr=subprocess.DEVNULL).decode('latin1')
 except subprocess.CalledProcessError: return None
s=former(sys.argv[1]) if len(sys.argv)>1 else None
if s is None:
 swift=(subprocess.check_output(['git','show',sys.argv[1]+':Horos/Sources/XMLController.swift']).decode('utf-8') if len(sys.argv)>1 else source_text('XMLController'))
 a=swift.index('    @objc(outlineView:willDisplayCell:forTableColumn:item:)');swift_method=swift[a:swift.index('\n    }\n',a)+7]
else:
 a=s.index('- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:');method=s[a:s.index('- (void) traverse:',a)]
source=r'''
#import <AppKit/AppKit.h>
#include <math.h>
#define check(v) NSCAssert((v), @"failed: %s", #v)
@interface OutlineFixture:NSObject
@property BOOL selected;
-(NSInteger)rowForItem:(id)item;
-(NSIndexSet*)selectedRowIndexes;
@end
@implementation OutlineFixture
-(NSInteger)rowForItem:(id)item{return 0;}
-(NSIndexSet*)selectedRowIndexes{return self.selected ? [NSIndexSet indexSetWithIndex:0] : [NSIndexSet indexSet];}
@end
@interface MetadataFixture:NSObject { @public NSTextField *search; NSMutableSet *modifiedFields; }
-(BOOL)item:(id)item containsString:(NSString*)text;
-(NSString*)getPath:(id)item;
-(void)outlineView:(NSOutlineView*)view willDisplayCell:(id)cell forTableColumn:(NSTableColumn*)column item:(id)item;
@end
@implementation MetadataFixture
-(BOOL)item:(id)item containsString:(NSString*)text{return [item containsString:text];}
-(NSString*)getPath:(id)item{return item;}
METHOD
@end
static double luminance(NSColor *color) {
 NSColor *rgb=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
 double values[]={rgb.redComponent,rgb.greenComponent,rgb.blueComponent};
 for(int i=0;i<3;i++) values[i]=values[i]<=0.04045 ? values[i]/12.92 : pow((values[i]+0.055)/1.055,2.4);
 return .2126*values[0]+.7152*values[1]+.0722*values[2];
}
static void checkReadable(NSColor *foreground) {
 for(NSColor *background in NSColor.alternatingContentBackgroundColors) {
  NSColor *fg=[foreground colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  NSColor *bg=[background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  NSColor *base=[NSColor.textBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  CGFloat ba=bg.alphaComponent;
  bg=[NSColor colorWithSRGBRed:bg.redComponent*ba+base.redComponent*(1-ba) green:bg.greenComponent*ba+base.greenComponent*(1-ba) blue:bg.blueComponent*ba+base.blueComponent*(1-ba) alpha:1];
  CGFloat a=fg.alphaComponent;
  NSColor *composite=[NSColor colorWithSRGBRed:fg.redComponent*a+bg.redComponent*(1-a) green:fg.greenComponent*a+bg.greenComponent*(1-a) blue:fg.blueComponent*a+bg.blueComponent*(1-a) alpha:1];
  double x=luminance(composite),y=luminance(bg),ratio=(MAX(x,y)+.05)/(MIN(x,y)+.05);
  NSLog(@"row contrast %.2f",ratio);check(ratio>=4.5);
 }
}
int main(void) { @autoreleasepool {
 MetadataFixture *fixture=[MetadataFixture new];fixture->search=[NSTextField new];fixture->modifiedFields=[NSMutableSet set];
 OutlineFixture *outline=[OutlineFixture new];NSTextFieldCell *cell=[NSTextFieldCell new];
 for(NSString *theme in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua,NSAppearanceNameAccessibilityHighContrastAqua,NSAppearanceNameAccessibilityHighContrastDarkAqua]) {
  [[NSAppearance appearanceNamed:theme] performAsCurrentDrawingAppearance:^{
   fixture->search.stringValue=@"";outline.selected=NO;[fixture->modifiedFields removeAllObjects];
   [fixture outlineView:(id)outline willDisplayCell:cell forTableColumn:nil item:@"PatientName"];
   double text=luminance(cell.textColor), bg=luminance(NSColor.textBackgroundColor);
   check((MAX(text,bg)+.05)/(MIN(text,bg)+.05)>=4.5);
   fixture->search.stringValue=@"Patient";
   [fixture outlineView:(id)outline willDisplayCell:cell forTableColumn:nil item:@"PatientName"];
   check(([NSFontManager.sharedFontManager traitsOfFont:cell.font]&NSBoldFontMask)!=0);
   [fixture outlineView:(id)outline willDisplayCell:cell forTableColumn:nil item:@"Modality"];
   checkReadable(cell.textColor);
   [fixture->modifiedFields addObject:@"Modality"];
   [fixture outlineView:(id)outline willDisplayCell:cell forTableColumn:nil item:@"Modality"];
   checkReadable(cell.textColor);
   outline.selected=YES;
   [fixture outlineView:(id)outline willDisplayCell:cell forTableColumn:nil item:@"Modality"];
   check([cell.textColor isEqual:NSColor.selectedControlTextColor]);
   check(([NSFontManager.sharedFontManager traitsOfFont:cell.font]&NSBoldFontMask)!=0);
  }];
 }
 NSLog(@"PASS: actual metadata cell delegate uses readable primary colors in light/dark/high-contrast appearances, preserves search emphasis and modified/selected state");
} }
'''
swift_source=r'''
import AppKit
func check(_ v: Bool, _ what: String = #function, line: Int = #line) { if !v { NSLog("failed: line %d", line); exit(1) } }
final class OutlineFixture: NSOutlineView {
 var selected = false
 override func row(forItem item: Any?) -> Int { return 0 }
 override var selectedRowIndexes: IndexSet { return selected ? IndexSet(integer: 0) : IndexSet() }
}
final class MetadataFixture: NSObject {
 var search: NSSearchField? = NSSearchField()
 var modifiedFields: NSMutableArray? = NSMutableArray()
 func item(_ item: Any?, containsString text: String?) -> Bool { return (item as! NSString).contains(text!) }
 func getPath(_ item: Any?) -> String { return item as! String }
METHOD
}
func luminance(_ color: NSColor) -> Double {
 let rgb = color.usingColorSpace(.sRGB)!
 var values = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
 for i in 0..<3 { values[i] = values[i] <= 0.04045 ? values[i]/12.92 : pow((values[i]+0.055)/1.055, 2.4) }
 return 0.2126*values[0]+0.7152*values[1]+0.0722*values[2]
}
func checkReadable(_ foreground: NSColor) {
 for background in NSColor.alternatingContentBackgroundColors {
  let fg = foreground.usingColorSpace(.sRGB)!
  var bg = background.usingColorSpace(.sRGB)!
  let base = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
  let ba = bg.alphaComponent
  bg = NSColor(srgbRed: bg.redComponent*ba+base.redComponent*(1-ba), green: bg.greenComponent*ba+base.greenComponent*(1-ba), blue: bg.blueComponent*ba+base.blueComponent*(1-ba), alpha: 1)
  let a = fg.alphaComponent
  let composite = NSColor(srgbRed: fg.redComponent*a+bg.redComponent*(1-a), green: fg.greenComponent*a+bg.greenComponent*(1-a), blue: fg.blueComponent*a+bg.blueComponent*(1-a), alpha: 1)
  let x = luminance(composite), y = luminance(bg), ratio = (max(x,y)+0.05)/(min(x,y)+0.05)
  NSLog("row contrast %.2f", ratio); check(ratio >= 4.5)
 }
}
func bold(_ font: NSFont?) -> Bool { return (NSFontManager.shared.traits(of: font!).rawValue & NSFontTraitMask.boldFontMask.rawValue) != 0 }
let fixture = MetadataFixture()
let outline = OutlineFixture()
let cell = NSTextFieldCell()
for theme in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
 NSAppearance(named: theme)!.performAsCurrentDrawingAppearance {
  fixture.search!.stringValue = ""; outline.selected = false; fixture.modifiedFields!.removeAllObjects()
  fixture.outlineView(outline, willDisplayCell: cell, for: nil, item: "PatientName")
  let text = luminance(cell.textColor!), bg = luminance(NSColor.textBackgroundColor)
  check((max(text,bg)+0.05)/(min(text,bg)+0.05) >= 4.5)
  fixture.search!.stringValue = "Patient"
  fixture.outlineView(outline, willDisplayCell: cell, for: nil, item: "PatientName")
  check(bold(cell.font))
  fixture.outlineView(outline, willDisplayCell: cell, for: nil, item: "Modality")
  checkReadable(cell.textColor!)
  fixture.modifiedFields!.add("Modality")
  fixture.outlineView(outline, willDisplayCell: cell, for: nil, item: "Modality")
  checkReadable(cell.textColor!)
  outline.selected = true
  fixture.outlineView(outline, willDisplayCell: cell, for: nil, item: "Modality")
  check(cell.textColor!.isEqual(NSColor.selectedControlTextColor))
  check(bold(cell.font))
 }
}
NSLog("PASS: actual metadata cell delegate uses readable primary colors in light/dark/high-contrast appearances, preserves search emphasis and modified/selected state")
'''
with tempfile.TemporaryDirectory(prefix='horos-metadata-colors-') as directory:
 p=Path(directory)
 if s is None:
  (p/'main.swift').write_text(swift_source.replace('METHOD',swift_method))
  subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 else:
  (p/'test.m').write_text(source.replace('METHOD',method))
  subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','AppKit',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
