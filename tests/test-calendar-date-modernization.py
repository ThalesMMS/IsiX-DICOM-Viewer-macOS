#!/usr/bin/env python3
"""Execute the production DICOM date adapter, query filters and fixed formats."""
import private_tmpdir  # noqa: F401
import harness_defaults
from pathlib import Path
import subprocess
import tempfile
from isix_modules import build_module, link_flags

root = Path(__file__).resolve().parents[1]
albums = (root / "Horos/Sources/DicomDatabase+Albums.swift").read_text()
a = albums.index("        func previousDay(_ days: Int) -> NSDate {")
b = albums.index("\n        }", a) + len("\n        }")
previous_day = albums[a:b]
# The FluoView acquisition date: Objective-C in DicomFile.mm before, Swift in
# DicomFile+NonDICOMReaders.swift since (its two static functions, run here as
# top-level ones).
legacy_reader = root / "Horos/Sources/DicomFile.mm"
if legacy_reader.exists():
    dicom_file = legacy_reader.read_bytes().decode("latin1")
    at = dicom_file.index("static NSDate *HorosFVTiffAcquisitionDate(")
    end = dicom_file.index("\n}\n", at) + 3
    acquisition_parser = dicom_file[at:end]
    swift_acquisition_parser = ""
    assert "date = [HorosFVTiffAcquisitionDate(datetime_string) retain];" in dicom_file
    assert "if (date == nil)\n                date = [[[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] valueForKey:NSFileCreationDate] retain];" in dicom_file
else:
    readers = (root / "Horos/Sources/DicomFile+NonDICOMReaders.swift").read_text()
    pieces = []
    for signature in ("    static func fluoViewAcquisitionDate(_ value: String) -> NSDate? {",
                      "    static func calendarDate(_ text: String, _ format: String) -> NSDate? {"):
        at = readers.index(signature)
        end = readers.index("\n    }\n", at) + len("\n    }\n")
        pieces.append("\n".join(line[4:] for line in readers[at:end].replace("static func", "func").split("\n")))
    swift_acquisition_parser = "\n".join(pieces) + \
        "func HorosFVTiffTestDate(_ value: String) -> Date? { fluoViewAcquisitionDate(value) as Date? }\n"
    acquisition_parser = ""
    assert "let date = Self.fluoViewAcquisitionDate(dateTime) ?? creationDate(of: path)" in readers
    assert ".object(forKey: FileAttributeKey.creationDate) as? NSDate" in readers
series_source = (root / "Horos/Sources/DicomSeries.swift").read_text()
at = series_source.index("    @objc public var displayDate: Date? {")
end = series_source.index("\n    }", at) + len("\n    }")
series_display_date = series_source[at:end]
# DicomDatabase is Swift: the normalisation of the importer (+Import.swift)
# and the marker date it compares with (+CAPI.m, by the IsiXDICOMFile date).
database = (root / "Horos/Sources/DicomDatabase+Import.swift").read_text()
at = database.index('        var importedDate = curDict?.object(forKey: "studyDate") as? Date')
end = database.index("\n", database.index("importedDate = nil }", at))
import_date_normalization = database[at:end]
capi = (root / "Horos/Sources/DicomDatabase+CAPI.m").read_text()
at = capi.index('NSDate* DicomDatabaseUndefinedStudyDate(void) {')
undefined_study_date = capi[at:capi.index('\n}\n', at) + 3]
program = r'''
import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func parsed(_ value: String) -> DICOMCalendarDate {
    guard let date = DICOMCalendarDate.dicomDateTime(value) else { fatalError(value) }
    return date
}
// The fixed-format date strings of the app, by the module's date type.
func HorosDateString(_ date: Any?, _ format: String) -> String? {
    DICOMCalendarDate.string(from: date, calendarFormat: format)
}
NSTimeZone.default = TimeZone(identifier: "America/New_York")!
final class DateStudy { var date: Date? }
final class DateSeries {
    var date: Date?
    var study: DateStudy?
SERIES_DISPLAY_DATE
}
let dateStudy = DateStudy()
let dateSeries = DateSeries()
dateSeries.study = dateStudy
let knownDate = parsed("20261002141500") as Date
let seriesDate = parsed("20261002150000") as Date
let noDate = DICOMCalendarDate.date(withYear: 1901, month: 1, day: 1, hour: 0, minute: 0, second: 0, timeZone: nil)! as Date
dateStudy.date = knownDate
dateSeries.date = noDate
check(dateSeries.displayDate == knownDate, "legacy series marker displays the study date")
check(dateSeries.date == noDate, "display does not mutate the legacy row")
dateSeries.date = nil
check(dateSeries.displayDate == knownDate, "missing series date uses the study date")
dateSeries.date = seriesDate
check(dateSeries.displayDate == seriesDate, "a valid series date takes precedence")
dateSeries.date = noDate
dateStudy.date = noDate
check(dateSeries.displayDate == nil, "a missing date at both levels displays no date")
dateSeries.study = nil
check(dateSeries.displayDate == nil, "an unrelated study supplies no date")
check(HorosImportedDate(["studyDate": noDate]) == nil, "the importer discards the parser marker")
check(HorosImportedDate([:]) == nil, "the importer preserves an absent date")
check(HorosImportedDate(["studyDate": knownDate]) == knownDate, "the importer preserves a clinical date")
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
let date = DICOMCalendarDate.dicomDate("20240229")!
let exact = QueryFilter(object: date, ofSearchType: 9, forKey: "StudyDate")
check(exact.filteredValue() == "20240229-20240229", "exact query date")
check(QueryFilter(object: date, ofSearchType: 6, forKey: "StudyDate").filteredValue() == "-20240229", "before includes the chosen day")
UserDefaults.standard.set(true, forKey: "DICOMQueryAllowFutureQuery")
check(QueryFilter(object: date, ofSearchType: 7, forKey: "StudyDate").filteredValue() == "20240229-", "open ended after date")
UserDefaults.standard.set(false, forKey: "DICOMQueryAllowFutureQuery")
let today = HorosDateString(Date(), "%Y%m%d")!
check(QueryFilter(object: date, ofSearchType: 7, forKey: "StudyDate").filteredValue() as String? == "20240229-" + today, "after through today")
let yesterday = DICOMCalendarDate().date(byAddingYears: 0, months: 0, days: -1, hours: 0, minutes: 0, seconds: 0)!
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
let query = DICOMCalendarDate.queryDate("20240101-20240229")
check(query.dateString() == "20240101-20240229", "DICOM query range preserved")
check(HorosDateString(leap, "%Y:%m:%d %H:%M:%S") == "2024:02:29 12:34:56", "image metadata wire format")
let noTime = NSDate.date(withYYYYMMDD: "2024.02.29", hhmmss: nil) as! Date
check(HorosDateString(noTime, "%Y%m%d%H%M%S") == "20240229000000", "N2 date-only midnight")
check(NSDate.date(withYYYYMMDD: "20240230", hhmmss: nil) == nil, "N2 invalid date rejected")
let highFraction = parsed("19991231235959.999999-0030")
check(highFraction.dateTimeString(true) == "19991231235959.999999-0030", "fraction must never round to next second")
check(highFraction.timeStringWithMilliseconds() == "235959.999", "milliseconds truncate")
check(DICOMCalendarDate.dicomTime("000000")?.timeString() == "000000.000000", "midnight TM accepted")
check(abs(DICOMCalendarDate().timeIntervalSinceNow) < 2, "default initialization uses now")
let archive = try! NSKeyedArchiver.archivedData(withRootObject: plus, requiringSecureCoding: true)
let restored = try! NSKeyedUnarchiver.unarchivedObject(ofClass: DICOMCalendarDate.self, from: archive)!
check(restored.dateTimeString(true) == plus.dateTimeString(true), "archive preserves DT timezone and fraction")
let queryCopy = query.copy() as! DICOMCalendarDate
check(queryCopy.isQuery() && queryCopy.dateString() == query.dateString(), "copy preserves query metadata")
let queryArchive = try! NSKeyedArchiver.archivedData(withRootObject: query, requiringSecureCoding: true)
let restoredQuery = try! NSKeyedUnarchiver.unarchivedObject(ofClass: DICOMCalendarDate.self, from: queryArchive)!
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
// The date the importer files a study under: DA and TM read together.
func studyInstant(_ date: String, _ time: String?) -> Date? {
    return DICOMCalendarDate.dicomDate(date, time: time) as Date?
}
let wholeSeconds = parsed("20261004103015") as Date
check(studyInstant("20261004", "103015") == wholeSeconds, "a time in whole seconds is read as before")
for (time, fraction) in [("103015.123456", 0.123456), ("103015.5", 0.5), ("103015.000001", 0.000001), ("10:30:15.25", 0.25)] {
    guard let instant = studyInstant("20261004", time) else { fatalError("fractional time \(time) was not read") }
    check(abs(instant.timeIntervalSince(wholeSeconds) - fraction) < 1e-6, "fractional time \(time)")
}
check(studyInstant("20261004", "1030") == parsed("20261004103000") as Date, "HHMM time")
check(studyInstant("20261004", "10") == parsed("20261004100000") as Date, "HH time")
check(studyInstant("2026.10.04", "103015") == wholeSeconds, "ACR-NEMA date")
check(studyInstant("20261004", nil) == parsed("20261004120000") as Date, "a date without a time is filed at noon")
for (date, time) in [("20261004", "103075"), ("20261004", "10301"), ("20261004", "103015.12a"), ("2022XX03", "103015"), ("20261004", "1030151")] {
    check(studyInstant(date, time) == nil, "unreadable \(date) \(time)")
}
// Trailing characters are left, as NSCalendarDate left them; missing fields are not.
check(DICOMCalendarDate(string: "20261004103015.123456", calendarFormat: "%Y%m%d%H%M%S") as Date? == wholeSeconds, "trailing fraction tolerated")
check(DICOMCalendarDate(string: "2026100410301", calendarFormat: "%Y%m%d%H%M%S") == nil, "a short value is still rejected")
check(DICOMCalendarDate(string: "20261004256015", calendarFormat: "%Y%m%d%H%M%S") == nil, "an invalid hour is still rejected")
let dicomdirTime = NSDate.date(withYYYYMMDD: "20261004", hhmmss: "103015.123456") as? Date
check(dicomdirTime != nil && abs(dicomdirTime!.timeIntervalSince(wholeSeconds) - 0.123456) < 1e-6, "DICOMDIR fractional time")
check(NSDate.date(withYYYYMMDD: "20261004", hhmmss: "103015") as? Date == wholeSeconds, "DICOMDIR whole seconds")
var years = 0, months = 0, days = 0
HorosDicomStudyYearsMonthsDays(parsed("20250301120000") as Date, parsed("20240229120000") as Date, &years, &months, &days)
check(years == 1 && months == 0 && days == 1, "age calculation at leap year boundary")
print("PASS: production date adapter, DICOM formats, fractional study times, query bounds, leap/month/year boundaries, DST and N2 parsing")
'''.replace('PREVIOUS_DAY', previous_day).replace('SERIES_DISPLAY_DATE', series_display_date) + swift_acquisition_parser
program += ("\nfunc HorosImportedDate(_ values: [String: Any]) -> Date? {\n"
            "    let curDict: NSMutableDictionary? = NSMutableDictionary(dictionary: values)\n"
            "    let defaultDate = DicomDatabaseUndefinedStudyDate()\n"
            + import_date_normalization + "\n    return importedDate\n}\n")
with tempfile.TemporaryDirectory(prefix="horos-calendar-date-") as folder:
    work = Path(folder)
    (work / "Bridge.h").write_text('#import "IsiXDICOMFile-Swift.h"\n' + ('NSDate *HorosFVTiffTestDate(NSString *value);\n' if acquisition_parser else '') + 'NSDate *DicomDatabaseUndefinedStudyDate(void);\n#define HOROS_BRIDGING_HEADER 1\n#import "DicomStudy.h"\n')
    (work / "main.swift").write_text(harness_defaults.SWIFT + program)
    build_module("IsiXStorage", work / "modules")
    # The DICOM date type, in the module that depends on IsiXImaging.
    build_module("IsiXImaging", work / "modules")
    build_module("IsiXDICOMFile", work / "modules", ["-I", str(work / "modules")])
    flags = ["-I", str(work), "-I", str(work / "modules"), "-I", str(root / "Horos/Sources"), "-DHOROS_BRIDGING_HEADER=1"]
    (work / "FVTiffDate.m").write_text('#import "IsiXDICOMFile-Swift.h"\n' + acquisition_parser + ('\nNSDate *HorosFVTiffTestDate(NSString *value) { return HorosFVTiffAcquisitionDate(value); }' if acquisition_parser else '') + '\n' + undefined_study_date)
    subprocess.run(["xcrun", "clang", "-c", "-Werror", *flags, str(work / "FVTiffDate.m"), "-o", str(work / "FVTiffDate.o")], check=True)
    objects = [str(work / "FVTiffDate.o")]
    for path in ("Horos/Sources/DicomStudy+CAPI.m",):
        obj = work / (Path(path).stem + ".o")
        subprocess.run(["xcrun", "clang", "-c", "-Werror=deprecated-declarations", *flags, str(root / path), "-o", str(obj)], check=True)
        objects.append(str(obj))
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", *flags[:-1], "-Xcc", flags[-1], "-import-objc-header", str(work / "Bridge.h"),
                    str(root / "Horos/Sources/QueryFilter.swift"), str(root / "Nitrogen/Sources/NSDate+N2.swift"),
                    str(work / "main.swift"), *objects, *link_flags("IsiXStorage", work / "modules"),
                    *link_flags("IsiXDICOMFile", work / "modules"), *link_flags("IsiXImaging", work / "modules"),
                    "-o", str(work / "test")], check=True)
    subprocess.run([str(work / "test"), "-AppleLocale", "th_TH", "-AppleLanguages", "(th)"], check=True)
