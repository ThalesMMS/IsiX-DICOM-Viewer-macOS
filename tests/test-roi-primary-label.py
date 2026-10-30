#!/usr/bin/env python3
"""Test Swift compact formatting and production ROI presentation selection:
the primary measurement only, and the statistics the Viewers pane hides.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py); without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

static NSUserDefaults *d;

/// The preferences, read again by the ROIs.
static void prefer( NSDictionary *preferences)
{
    [d setVolatileDomain: preferences forName: NSArgumentDomain];
    [ROI loadDefaultSettings];
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    d = [NSUserDefaults standardUserDefaults];
    ROI *r = newROI( tCPolygon);
    r.textualBoxLine1 = @"QA Area"; r.textualBoxLine2 = @"Area: 25.000 mm²";
    r.textualBoxLine3 = @"Mean: 22.500"; r.textualBoxLine5 = @"Length: 2.000 cm";
    prefer( @{@"ROIPRIMARYMEASUREMENTONLY": @NO});
    NSArray *full = [r displayedTextualLines]; check( full.count == 6 && [full[ 2] isEqual: @"Mean: 22.500"]);
    prefer( @{@"ROIPRIMARYMEASUREMENTONLY": @YES});
    for( NSNumber *t in @[@(tCPolygon), @(tOval), @(tROI), @(tPencil), @(tPlain)])
    {
        r.type = (ToolMode) t.intValue; check( [[r displayedTextualLines] isEqual: @[@"25.000 mm²"]]);
    }
    r.type = tOPolygon; check( [[r displayedTextualLines] isEqual: @[@"2.000 cm"]]);
    r.type = tMesure; r.textualBoxLine2 = @"Comprimento: 5,501 cm";
    check( [[r displayedTextualLines] isEqual: @[@"5,501 cm"]]);
    r.type = tAngle; r.textualBoxLine2 = @"Angle: 60.000° / 300.000°";
    check( [[r displayedTextualLines] isEqual: @[@"60.000°"]]);
    r.type = tMesure; r.textualBoxLine2 = @"Length: X=3 cm, Y=2 cm/sec";
    check( [r displayedTextualLines].count == 6);
    r.type = tText; check( [r displayedTextualLines].count == 6);
    r.type = tCPolygon; r.textualBoxLine2 = @"Area: 25.000 mm²";
    prefer( @{@"ROIPRIMARYMEASUREMENTONLY": @YES, @"ROITEXTNAMEONLY": @YES});
    check( [[r displayedTextualLines] isEqual: full]);
    prefer( @{@"ROIPRIMARYMEASUREMENTONLY": @YES});
    r.textNameOnly = YES; check( [[r displayedTextualLines] isEqual: full]); r.textNameOnly = NO;
    prefer( @{@"ROIPRIMARYMEASUREMENTONLY": @NO});
    check( [[r displayedTextualLines] isEqual: full]);
    check( [r.textualBoxLine3 isEqual: @"Mean: 22.500"]);
    check( ![HorosROILabelPresentation compactMeasurement: @"Area:" primaryAngle: NO]);
    check( ![HorosROILabelPresentation compactMeasurement: nil primaryAngle: NO]);
    check( [[HorosROILabelPresentation compactMeasurement: @"Length: 40.0 µm" primaryAngle: NO] isEqual: @"40.0 µm"]);
    // Statistics hidden in the Viewers pane leave the label, not its source lines.
    ROI *st = newROI( tROI);
    st.textualBoxLine1 = nil;
    [st setTextualBoxLine: 2 area: @"Area: 25.000 mm²" width: @"5.000 mm" height: @"5.000 mm"];
    [st setStatisticsLines: 3 mean: 22.5 sdev: 1 sum: 100 median: 22 min: 1 max: 40 skewness: 0 kurtosis: 0 unit: @" HU " fused: NO];
    [st setStatisticsLines: 5 mean: 2 sdev: 1 sum: 8 median: NAN min: 0 max: 4 skewness: 0 kurtosis: 0 unit: @" SUV " fused: YES];
    check( [st.textualBoxLine2 isEqual: @"Area: 25.000 mm² (W: 5.000 mm H: 5.000 mm)"]);
    check( [st.textualBoxLine3 isEqual: @"Mean: 22.500 HU SDev: 1.000 HU Sum: 100 HU Median: 22.000 HU"]);
    check( [st.textualBoxLine4 isEqual: @"Min: 1.000 HU Max: 40.000 HU"]);
    check( [st.textualBoxLine5 isEqual: @"Fused Image Mean: 2.000 SUV SDev: 1.000 SUV Sum: 8 SUV Median: N/A SUV"]);
    NSArray *all = @[@"", st.textualBoxLine2, st.textualBoxLine3, st.textualBoxLine4, st.textualBoxLine5, st.textualBoxLine6 ?: @""];
    check( [[st displayedTextualLines] isEqual: all]);
    NSMutableDictionary *meanOnly = [NSMutableDictionary dictionaryWithDictionary: @{@"ROIPRIMARYMEASUREMENTONLY": @NO}];
    for( NSString *k in @[@"Area", @"WH", @"SDev", @"Sum", @"Median", @"Min", @"Max"]) meanOnly[[HorosROILabelPresentation defaultsKeyForStatistic: k]] = @NO;
    prefer( meanOnly);
    check( [[st displayedTextualLines] isEqual: (@[@"", @"", @"Mean: 22.500 HU", @"", @"Fused Image Mean: 2.000 SUV", @""])]);
    check( [st.textualBoxLine3 hasSuffix: @"Median: 22.000 HU"]);
    prefer( @{[HorosROILabelPresentation defaultsKeyForStatistic: @"Area"]: @NO});
    check( [[st displayedTextualLines][ 1] isEqual: @"W: 5.000 mm H: 5.000 mm"]);
    st.textualBoxLine2 = @"Calcium Score: 1.0";
    check( [[st displayedTextualLines][ 1] isEqual: @"Calcium Score: 1.0"]);
    [st setStatisticsLines: 3 mean: 1 sdev: 1 sum: 1 median: 1 min: 1 max: 1 skewness: 0.5 kurtosis: 2 unit: @" HU " fused: NO];
    prefer( @{[HorosROILabelPresentation defaultsKeyForStatistic: @"Min"]: @NO, [HorosROILabelPresentation defaultsKeyForStatistic: @"Max"]: @NO});
    check( [[st displayedTextualLines][ 3] isEqual: @"Skewness: 0.500 Kurtosis: 2.000"]);
    check( [[HorosROILabelPresentation titleForStatistic: @"Mean"] isEqual: @"Mean"] && [[HorosROILabelPresentation titleForStatistic: @"Area"] isEqual: @"Area"]);
    [window release];
    printf( "PASS: opt-in/default/restore, area/length/angle, units/locale, full-source preservation, name-only precedence, compound and unknown fallbacks, hidden statistics\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
