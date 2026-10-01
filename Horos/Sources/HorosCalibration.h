#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
#include <float.h>

// Parse the entire entry, honoring the decimal separator of the user's locale.
// Also accept period-decimal values emitted by legacy setFloatValue: controls.
FOUNDATION_EXPORT BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value);
