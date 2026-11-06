//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
import IsiXDICOMNetwork

/// What a DICOM print job's output says failed: the step line of print.sh's
/// EXIT trap and the failure line of HorosStoredPrint, as they write them.
@Suite struct DICOMPrintJobFailureTests {

    private func classify(_ lines: [String], status: Int32 = 1) -> DICOMPrintJobFailure {
        DICOMPrintJobFailure.classify(output: lines.joined(separator: "\n") + "\n", status: status)
    }

    @Test func theSetupAndLayoutStepsAreReadFromTheScriptLine() {
        #expect(classify(["IsiXPrintJob: step=setup status=1"]) == .setup)
        #expect(classify(["dcmpsprt: error: synthetic layout failure", "IsiXPrintJob: step=layout status=23"], status: 23) == .layout)
    }

    @Test func aSendStepIsReadFromTheHelpersStage() {
        #expect(classify(["HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=load; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .layout)
        #expect(classify(["HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=connect; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .unreachable)
    }

    @Test func aJobStageGivesThePrintersRefusalWhenItSentAStatus() {
        #expect(classify(["HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=job dimse=0xC600; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .refused(0xC600))
        // The DIMSE status may end the fields, before the semicolon.
        #expect(classify(["HorosStoredPrint: page=2 operation=1 stage=job dimse=0xA700;",
                          "IsiXPrintJob: step=send status=1"]) == .refused(0xA700))
    }

    @Test func aJobStageWithoutAStatusFromThePrinterIsAnInterruption() {
        #expect(classify(["HorosStoredPrint: page=2 operation=1 cleanup=0 release=0 accepted=0 stage=job; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .interrupted)
        // A DIMSE field that is not a hexadecimal status is no refusal.
        #expect(classify(["HorosStoredPrint: page=1 operation=1 stage=job dimse=C600; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .interrupted)
        #expect(classify(["HorosStoredPrint: page=1 operation=1 stage=job dimse=0xZZ; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .interrupted)
    }

    @Test func printerSettingsTheHelperCannotUseAreTheirOwnFailure() {
        #expect(classify(["HorosStoredPrint: cannot initialize printer", "IsiXPrintJob: step=send status=1"]) == .printerSettings)
    }

    @Test func warningsAreNotFailures() {
        let warning = "HorosStoredPrint: warning: page=1 operation=0 cleanup=0 release=1 accepted=1; the page was printed, only the cleanup after it failed"
        #expect(classify([warning, "IsiXPrintJob: step=send status=1"]) == .status(1))
        // A failure line after a warning still counts.
        #expect(classify([warning, "HorosStoredPrint: page=2 operation=1 stage=connect; batch stopped, no retry",
                          "IsiXPrintJob: step=send status=1"]) == .unreachable)
    }

    @Test func aSendStepWithoutAFailureLineOrAStageGivesTheStatus() {
        #expect(classify(["IsiXPrintJob: step=send status=7"], status: 7) == .status(7))
        #expect(classify(["HorosStoredPrint: page=1 operation=1; batch stopped, no retry", "IsiXPrintJob: step=send status=1"]) == .status(1))
        #expect(classify(["HorosStoredPrint: page=1 stage=other;", "IsiXPrintJob: step=send status=1"]) == .status(1))
    }

    @Test func noStepGivesTheExitStatus() {
        #expect(DICOMPrintJobFailure.classify(output: "", status: 127) == .status(127))
        #expect(classify(["HorosStoredPrint: page=1 operation=1 stage=connect; batch stopped, no retry"], status: 1) == .status(1))
        #expect(classify(["IsiXPrintJob: status=2"], status: 2) == .status(2))
        #expect(classify(["IsiXPrintJob: step=unknown status=3"], status: 3) == .status(3))
    }

    @Test func theLastStepLineWins() {
        #expect(classify(["IsiXPrintJob: step=layout status=23", "IsiXPrintJob: step=setup status=1"]) == .setup)
    }
}
