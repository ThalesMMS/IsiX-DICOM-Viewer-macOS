#!/usr/bin/env python3
"""Test Swift compact formatting and production ROI presentation selection:
the primary measurement only, and the statistics the Viewers pane hides."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/ROI.m').read_bytes().decode('latin1')
a=s.index('static NSArray *ROILabelSegment(');b=s.index('- (void) prepareTextualData:',a)
code=r'''
#import <Cocoa/Cocoa.h>
#import "Presentation-Swift.h"
static BOOL ROITEXTNAMEONLY;
enum{tOPolygon,tMesure,tAngle,tOval,tROI,tCPolygon,tPencil,tPlain,tText};
@interface ROI:NSObject {
@public NSString *textualBoxLine1,*textualBoxLine2,*textualBoxLine3,*textualBoxLine4,*textualBoxLine5,*textualBoxLine6;int type;
 NSDictionary *textualBoxSegments;
@public BOOL textNameOnly;
}
@property(retain) NSString *textualBoxLine2,*textualBoxLine3,*textualBoxLine4,*textualBoxLine5,*textualBoxLine6;
@end
@implementation ROI
@synthesize textualBoxLine2,textualBoxLine3,textualBoxLine4,textualBoxLine5,textualBoxLine6;
METHOD
@end
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 ROI*r=[ROI new];r->type=tCPolygon;
 r->textualBoxLine1=@"QA Area";r->textualBoxLine2=@"Area: 25.000 mm²";
 r->textualBoxLine3=@"Mean: 22.500";r->textualBoxLine5=@"Length: 2.000 cm";
 NSUserDefaults*d=[NSUserDefaults standardUserDefaults];
 [d setVolatileDomain:@{@"ROIPRIMARYMEASUREMENTONLY":@NO} forName:NSArgumentDomain];
 NSArray*full=[r displayedTextualLines];check(full.count==6 && [full[2] isEqual:@"Mean: 22.500"]);
 [d setVolatileDomain:@{@"ROIPRIMARYMEASUREMENTONLY":@YES} forName:NSArgumentDomain];
 for(NSNumber*t in @[@(tCPolygon),@(tOval),@(tROI),@(tPencil),@(tPlain)]){
  r->type=t.intValue;check([[r displayedTextualLines] isEqual:@[@"25.000 mm²"]]);
 }
 r->type=tOPolygon;check([[r displayedTextualLines] isEqual:@[@"2.000 cm"]]);
 r->type=tMesure;r->textualBoxLine2=@"Comprimento: 5,501 cm";
 check([[r displayedTextualLines] isEqual:@[@"5,501 cm"]]);
 r->type=tAngle;r->textualBoxLine2=@"Angle: 60.000° / 300.000°";
 check([[r displayedTextualLines] isEqual:@[@"60.000°"]]);
 r->type=tMesure;r->textualBoxLine2=@"Length: X=3 cm, Y=2 cm/sec";
 check([r displayedTextualLines].count==6);
 r->type=tText;check([r displayedTextualLines].count==6);
 r->type=tCPolygon;r->textualBoxLine2=@"Area: 25.000 mm²";
 ROITEXTNAMEONLY=YES;check([[r displayedTextualLines] isEqual:full]);ROITEXTNAMEONLY=NO;
 r->textNameOnly=YES;check([[r displayedTextualLines] isEqual:full]);r->textNameOnly=NO;
 [d setVolatileDomain:@{@"ROIPRIMARYMEASUREMENTONLY":@NO} forName:NSArgumentDomain];
 check([[r displayedTextualLines] isEqual:full]);
 check([r->textualBoxLine3 isEqual:@"Mean: 22.500"]);
 check(![HorosROILabelPresentation compactMeasurement:@"Area:" primaryAngle:NO]);
 check(![HorosROILabelPresentation compactMeasurement:nil primaryAngle:NO]);
 check([[HorosROILabelPresentation compactMeasurement:@"Length: 40.0 µm" primaryAngle:NO] isEqual:@"40.0 µm"]);
 // Statistics hidden in the Viewers pane leave the label, not its source lines.
 ROI*st=[ROI new];st->type=tROI;
 [st setTextualBoxLine:2 area:@"Area: 25.000 mm²" width:@"5.000 mm" height:@"5.000 mm"];
 [st setStatisticsLines:3 mean:22.5 sdev:1 sum:100 median:22 min:1 max:40 skewness:0 kurtosis:0 unit:@" HU " fused:NO];
 [st setStatisticsLines:5 mean:2 sdev:1 sum:8 median:NAN min:0 max:4 skewness:0 kurtosis:0 unit:@" SUV " fused:YES];
 check([st.textualBoxLine2 isEqual:@"Area: 25.000 mm² (W: 5.000 mm H: 5.000 mm)"]);
 check([st.textualBoxLine3 isEqual:@"Mean: 22.500 HU SDev: 1.000 HU Sum: 100 HU Median: 22.000 HU"]);
 check([st.textualBoxLine4 isEqual:@"Min: 1.000 HU Max: 40.000 HU"]);
 check([st.textualBoxLine5 isEqual:@"Fused Image Mean: 2.000 SUV SDev: 1.000 SUV Sum: 8 SUV Median: N/A SUV"]);
 NSArray*all=@[@"",st.textualBoxLine2,st.textualBoxLine3,st.textualBoxLine4,st.textualBoxLine5,st.textualBoxLine6];
 check([[st displayedTextualLines] isEqual:all]);
 NSMutableDictionary*meanOnly=[NSMutableDictionary dictionaryWithDictionary:@{@"ROIPRIMARYMEASUREMENTONLY":@NO}];
 for(NSString*k in @[@"Area",@"WH",@"SDev",@"Sum",@"Median",@"Min",@"Max"])meanOnly[[HorosROILabelPresentation defaultsKeyForStatistic:k]]=@NO;
 [d setVolatileDomain:meanOnly forName:NSArgumentDomain];
 check([[st displayedTextualLines] isEqual:(@[@"",@"",@"Mean: 22.500 HU",@"",@"Fused Image Mean: 2.000 SUV",@""])]);
 check([st.textualBoxLine3 hasSuffix:@"Median: 22.000 HU"]);
 [d setVolatileDomain:@{[HorosROILabelPresentation defaultsKeyForStatistic:@"Area"]:@NO} forName:NSArgumentDomain];
 check([[st displayedTextualLines][1] isEqual:@"W: 5.000 mm H: 5.000 mm"]);
 st.textualBoxLine2=@"Calcium Score: 1.0";
 check([[st displayedTextualLines][1] isEqual:@"Calcium Score: 1.0"]);
 [st setStatisticsLines:3 mean:1 sdev:1 sum:1 median:1 min:1 max:1 skewness:0.5 kurtosis:2 unit:@" HU " fused:NO];
 [d setVolatileDomain:@{[HorosROILabelPresentation defaultsKeyForStatistic:@"Min"]:@NO,[HorosROILabelPresentation defaultsKeyForStatistic:@"Max"]:@NO} forName:NSArgumentDomain];
 check([[st displayedTextualLines][3] isEqual:@"Skewness: 0.500 Kurtosis: 2.000"]);
 check([[HorosROILabelPresentation titleForStatistic:@"Mean"] isEqual:@"Mean"] && [[HorosROILabelPresentation titleForStatistic:@"Area"] isEqual:@"Area"]);
 NSLog(@"PASS: opt-in/default/restore, area/length/angle, units/locale, full-source preservation, name-only precedence, compound and unknown fallbacks, hidden statistics");
}}
'''.replace('METHOD',s[a:b])
with tempfile.TemporaryDirectory(prefix='horos-primary-label-') as d:
    p=Path(d);(p/'test.m').write_text(code)
    subprocess.run(['xcrun','swiftc',str(root/'Horos/Sources/ROILabelPresentation.swift'),'-emit-library','-module-name','Presentation','-emit-objc-header-path',str(p/'Presentation-Swift.h'),'-o',str(p/'libPresentation.dylib')],check=True)
    subprocess.run(['xcrun','clang','-fno-objc-arc','-fsanitize=undefined','-framework','Cocoa','-I',d,str(p/'test.m'),'-L',d,'-lPresentation','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
