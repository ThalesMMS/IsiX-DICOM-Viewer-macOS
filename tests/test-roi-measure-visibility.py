#!/usr/bin/env python3
"""Test the production ROI visibility rule for multiple unselected measures.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py); without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

/// The labels shown for a selected ROI only, or for every ROI.
static void textIfSelected( BOOL selectedOnly)
{
    [[NSUserDefaults standardUserDefaults] setVolatileDomain: @{@"ROITEXTIFSELECTED": @(selectedOnly)} forName: NSArgumentDomain];
    [ROI loadDefaultSettings];
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{@"ROITEXTIFSELECTED": @NO});
    ROI *a = newROI( tMesure), *b = newROI( tMesure);
    a.displayTextualData = b.displayTextualData = YES;
    [a setROIMode: ROI_sleep]; [b setROIMode: ROI_sleep];
    check( a.isTextualDataDisplayed && b.isTextualDataDisplayed);
    [a setROIMode: ROI_selected];
    check( a.isTextualDataDisplayed && b.isTextualDataDisplayed);
    // Selection-only is opt-in and applies independently to each measure.
    textIfSelected( YES);
    check( a.isTextualDataDisplayed && !b.isTextualDataDisplayed);
    [a setROIMode: ROI_sleep];
    check( !a.isTextualDataDisplayed && !b.isTextualDataDisplayed);
    b.mouseOverROI = YES;
    check( !a.isTextualDataDisplayed && b.isTextualDataDisplayed);
    b.mouseOverROI = NO; textIfSelected( NO);
    check( a.isTextualDataDisplayed && b.isTextualDataDisplayed);
    // Explicit suppression still takes precedence, independent of the peer ROI.
    for( int state = 0; state < 4; state++)
    {
        [a setROIMode: state]; a.hidden = YES;
        check( !a.isTextualDataDisplayed && b.isTextualDataDisplayed); a.hidden = NO;
        a.displayCalciumScoring = YES; check( !a.isTextualDataDisplayed); a.displayCalciumScoring = NO;
        a.displayTextualData = NO; check( !a.isTextualDataDisplayed); a.displayTextualData = YES;
    }
    [window release];
    printf( "PASS: two unselected measures, independent selection, opt-in selection-only, hover, restore and explicit suppression\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
