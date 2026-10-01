#!/usr/bin/env python3
"""Execute the production DICOM date adapter, query filters and fixed formats."""
import private_tmpdir  # noqa: F401
import harness_defaults
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
albums = (root / "Horos/Sources/DicomDatabase+Albums.swift").read_text()
a = albums.index("        func previousDay(_ days: Int) -> NSDate {")
b = albums.index("\n        }", a) + len("\n        }")
previous_day = albums[a:b]
dicom_file = (root / "Horos/Sources/DicomFile.mm").read_bytes().decode("latin1")
at = dicom_file.index("static NSDate *HorosFVTiffAcquisitionDate(")
end = dicom_file.index("\n}\n", at) + 3
acquisition_parser = dicom_file[at:end]
assert "date = [HorosFVTiffAcquisitionDate(datetime_string) retain];" in dicom_file
assert "if (date == nil)\n                date = [[[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] valueForKey:NSFileCreationDate] retain];" in dicom_file
program = r'''
import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func parsed(_ value: String) -> DCMCalendarDate {
    guard let date = DCMCalendarDate.dicomDateTime(value) as? DCMCalendarDate else { fatalError(value) }
    return date
}
NSTimeZone.default = TimeZone(identifier: "America/New_York")!
for input in [" 2024/02/29 12:34:56", " 02/29/2024 12:34:56", " 29 Feb 2024 12:34:56", " 29 February 2024 12:34:56"] {
    check(HorosFVTiffTestDate(input) == (parsed("20240229123456-0500") as Date), "FV TIFF local absolute Date/Time")
}
check(HorosFVTiffTestDate(" 2024-02-29 12:34:56") == (parsed("20240229123456+0000") as Date), "FV TIFF ISO absolute Date/Time uses UTC")
for input in ["", "invalid", "2024/02/30 12:34:56", "2024/02/29 25:34:56"] {
    check(HorosFVTiffTestDate(input) == nil, "FV TIFF invalid metadata preserves fallback")
}
let leap = parsed("20240229123456.123456-0500")
check(leap.dateString() == "20240229", "DA must retain the stated zone")
check(leap.dateTimeString(true) == "20240229123456.123456-0500", "DT fraction/offset roundtrip")
check(HorosDateString(leap, "%Y%m%d-%Y%m%d") == "20240229-20240229", "inclusive range format")
let plus = parsed("20240229123456.123456+0530")
check(plus.dateTimeString(true) == "20240229123456.123456+0530", "positive DT offset")
let before = parsed("19991231235959.250000+0000")
check(before.dateTimeString(true) == "19991231235959.250000+0000", "fractions before the reference epoch")
let date = DCMCalendarDate.dicomDate("20240229") as! DCMCalendarDate
let exact = QueryFilter(object: date, ofSearchType: 9, forKey: "StudyDate")
check(exact.filteredValue() == "20240229-20240229", "exact query date")
check(QueryFilter(object: date, ofSearchType: 6, forKey: "StudyDate").filteredValue() == "-20240229", "before includes the chosen day")
UserDefaults.standard.set(true, forKey: "DICOMQueryAllowFutureQuery")
check(QueryFilter(object: date, ofSearchType: 7, forKey: "StudyDate").filteredValue() == "20240229-", "open ended after date")
UserDefaults.standard.set(false, forKey: "DICOMQueryAllowFutureQuery")
let today = HorosDateString(Date(), "%Y%m%d")!
check(QueryFilter(object: date, ofSearchType: 7, forKey: "StudyDate").filteredValue() as String? == "20240229-" + today, "after through today")
let yesterday = DCMCalendarDate().date(byAddingYears: 0, months: 0, days: -1, hours: 0, minutes: 0, seconds: 0)!
let lastTwo = QueryFilter(object: 11, ofSearchType: 8, forKey: "StudyDate").filteredValue() as String?
check(lastTwo == HorosDateString(yesterday, "%Y%m%d")! + "-" + today, "last two days actual \(String(describing: lastTwo)) wanted \(HorosDateString(yesterday, "%Y%m%d")! + "-" + today)")
let spring = parsed("20240309120000")
let next = spring.date(byAddingYears: 0, months: 0, days: 1, hours: 0, minutes: 0, seconds: 0)!
check(HorosDateString(next, "%Y%m%d%H%M%S") == "20240310120000", "calendar day across spring DST")
check((next as! NSDate).timeIntervalSince(spring as Date) == 23 * 3600, "spring day has 23 hours")
let fall = parsed("20241102120000")
let fallNext = fall.date(byAddingYears: 0, months: 0, days: 1, hours: 0, minutes: 0, seconds: 0)!
check((fallNext as! NSDate).timeIntervalSince(fall as Date) == 25 * 3600, "fall day has 25 hours")
let yearEnd = parsed("20241231120000")
check(HorosDateString(yearEnd.date(byAddingYears: 0, months: 0, days: 1, hours: 0, minutes: 0, seconds: 0), "%Y%m%d") == "20250101", "year boundary")
let monthEnd = parsed("20240331120000")
check(HorosDateString(monthEnd.date(byAddingYears: 0, months: -1, days: 0, hours: 0, minutes: 0, seconds: 0), "%Y%m%d") == "20240229", "month boundary clamps to leap day")
let query = DCMCalendarDate.queryDate("20240101-20240229") as! DCMCalendarDate
check(query.dateString() == "20240101-20240229", "DICOM query range preserved")
check(HorosDateString(leap, "%Y:%m:%d %H:%M:%S") == "2024:02:29 12:34:56", "image metadata wire format")
let noTime = NSDate.date(withYYYYMMDD: "2024.02.29", hhmmss: nil) as! Date
check(HorosDateString(noTime, "%Y%m%d%H%M%S") == "20240229000000", "N2 date-only midnight")
check(NSDate.date(withYYYYMMDD: "20240230", hhmmss: nil) == nil, "N2 invalid date rejected")
let highFraction = parsed("19991231235959.999999-0030")
check(highFraction.dateTimeString(true) == "19991231235959.999999-0030", "fraction must never round to next second")
check(highFraction.timeStringWithMilliseconds() == "235959.999", "milliseconds truncate")
check((DCMCalendarDate.dicomTime("000000") as? DCMCalendarDate)?.timeString() == "000000.000000", "midnight TM accepted")
check(abs(DCMCalendarDate().timeIntervalSinceNow) < 2, "default initialization uses now")
let archive = try! NSKeyedArchiver.archivedData(withRootObject: plus, requiringSecureCoding: true)
let restored = try! NSKeyedUnarchiver.unarchivedObject(ofClass: DCMCalendarDate.self, from: archive)!
check(restored.dateTimeString(true) == plus.dateTimeString(true), "archive preserves DT timezone and fraction")
let queryCopy = query.copy() as! DCMCalendarDate
check(queryCopy.isQuery() && queryCopy.dateString() == query.dateString(), "copy preserves query metadata")
let queryArchive = try! NSKeyedArchiver.archivedData(withRootObject: query, requiringSecureCoding: true)
let restoredQuery = try! NSKeyedUnarchiver.unarchivedObject(ofClass: DCMCalendarDate.self, from: queryArchive)!
check(restoredQuery.isQuery() && restoredQuery.dateString() == query.dateString(), "archive preserves query metadata")
for instant in ["20240311000000", "20241104000000"] {
    let start = parsed(instant) as NSDate
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = NSTimeZone.default
    PREVIOUS_DAY
    let previous = previousDay(1)
    check(HorosDateString(previous, "%H%M%S") == "000000", "smart album previous day keeps midnight")
    let expectedHours: Double = instant == "20240311000000" ? 23 : 25
    check(start.timeIntervalSince(previous as Date) == expectedHours * 3600, "smart album DST day length")
}
var years = 0, months = 0, days = 0
HorosDicomStudyYearsMonthsDays(parsed("20250301120000") as Date, parsed("20240229120000") as Date, &years, &months, &days)
check(years == 1 && months == 0 && days == 1, "age calculation at leap year boundary")
print("PASS: production date adapter, DICOM formats, query bounds, leap/month/year boundaries, DST and N2 parsing")
'''.replace('PREVIOUS_DAY', previous_day)
with tempfile.TemporaryDirectory(prefix="horos-calendar-date-") as folder:
    work = Path(folder)
    (work / "DCM").symlink_to(root / "DCM Framework", target_is_directory=True)
    (work / "Bridge.h").write_text('#import "DCMCalendarDate.h"\nNSDate *HorosFVTiffTestDate(NSString *value);\n#import "Horos.h"\n#define HOROS_BRIDGING_HEADER 1\n#import "DicomStudy.h"\n')
    (work / "main.swift").write_text(harness_defaults.SWIFT + program)
    flags = ["-I", str(work), "-I", str(root / "DCM Framework"), "-I", str(root / "Horos/Sources"), "-DHOROS_BRIDGING_HEADER=1"]
    (work / "FVTiffDate.m").write_text('#import "DCMCalendarDate.h"\n' + acquisition_parser + '\nNSDate *HorosFVTiffTestDate(NSString *value) { return HorosFVTiffAcquisitionDate(value); }\n')
    subprocess.run(["xcrun", "clang", "-c", "-Werror", *flags, str(work / "FVTiffDate.m"), "-o", str(work / "FVTiffDate.o")], check=True)
    objects = [str(work / "FVTiffDate.o")]
    for path in ("DCM Framework/DCMCalendarDate.m", "Horos/Sources/Horos.m", "Horos/Sources/DicomStudy+CAPI.m"):
        obj = work / (Path(path).stem + ".o")
        subprocess.run(["xcrun", "clang", "-c", "-Werror=deprecated-declarations", *flags, str(root / path), "-o", str(obj)], check=True)
        objects.append(str(obj))
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", *flags[:-1], "-Xcc", flags[-1], "-import-objc-header", str(work / "Bridge.h"),
                    str(root / "Horos/Sources/QueryFilter.swift"), str(root / "Nitrogen/Sources/NSDate+N2.swift"),
                    str(work / "main.swift"), *objects, "-o", str(work / "test")], check=True)
    subprocess.run([str(work / "test"), "-AppleLocale", "th_TH", "-AppleLanguages", "(th)"], check=True)
