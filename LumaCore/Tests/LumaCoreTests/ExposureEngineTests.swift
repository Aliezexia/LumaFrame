import Foundation
import Testing
@testable import LumaCore

struct ExposureEngineTests {
    @Test
    func testSunny16ReferenceAndCalibrationDirection() throws {
        // f/16 at 1/125 s, ISO 100 is approximately EV15.
        let reading = try #require(ExposureEngine.ev100(aperture: 16, shutterSeconds: 1.0 / 125, iso: 100))
        #expect(abs((reading) - (log2(32000))) <= 1e-10)
        #expect(abs((reading) - (15)) <= 0.04)
        let calibrated = try #require(ExposureEngine.ev100(
            aperture: 16, shutterSeconds: 1.0 / 125, iso: 100, calibrationEV: 0.7
        ))
        #expect(abs((calibrated - reading) - (0.7)) <= 1e-10)
    }

    @Test
    func testISOAndExposureDirections() throws {
        let baseline = ExposureSetting(iso: 100, aperture: 8, shutterSeconds: 1.0 / 125)
        let measured = try #require(ExposureEngine.ev100(
            aperture: baseline.aperture, shutterSeconds: baseline.shutterSeconds, iso: baseline.iso
        ))
        #expect(abs((ExposureEngine.deltaEV(ev100: measured, setting: baseline)) - (0)) <= 1e-10)

        var doubledISO = baseline
        doubledISO.iso = 200
        #expect(abs((ExposureEngine.deltaEV(ev100: measured, setting: doubledISO)) - (1)) <= 1e-10)
        let newCameraReading = try #require(ExposureEngine.ev100(
            aperture: 8, shutterSeconds: 1.0 / 125, iso: 200
        ))
        #expect(abs((newCameraReading) - (measured - 1)) <= 1e-10)

        var slower = baseline
        slower.shutterSeconds *= 2
        #expect(abs((ExposureEngine.deltaEV(ev100: measured, setting: slower)) - (1)) <= 1e-10)

        var smallerAperture = baseline
        smallerAperture.aperture *= sqrt(2)
        #expect(abs((ExposureEngine.deltaEV(ev100: measured, setting: smallerAperture)) - (-1)) <= 1e-10)
    }

    @Test
    func testPositiveCompensationLowersTargetAndLengthensExposure() {
        #expect(abs((ExposureEngine.targetEV(ev100: 12, iso: 400)) - (14)) <= 1e-10)
        #expect(abs((ExposureEngine.targetEV(ev100: 12, iso: 400, compensationEV: 1)) - (13)) <= 1e-10)
        let setting = ExposureSetting(iso: 100, aperture: 8, shutterSeconds: 1.0 / 125)
        let neutral = ExposureEngine.solve(mode: .aperturePriority, setting: setting, ev100: 13)
        let brighter = ExposureEngine.solve(mode: .aperturePriority, setting: setting, ev100: 13, compensationEV: 1)
        #expect(brighter.setting.shutterSeconds > neutral.setting.shutterSeconds)
        #expect(abs((brighter.setting.shutterSeconds / neutral.setting.shutterSeconds) - (2)) <= 0.1)
        #expect(abs((brighter.residualEV) - (ExposureEngine.deltaEV(ev100: 13, setting: brighter.setting) - 1)) <= 1e-10)
    }

    @Test
    func testManualModeNeverOverwritesUserParameters() {
        let unusual = ExposureSetting(iso: 373, aperture: 3.7, shutterSeconds: 0.017)
        let result = ExposureEngine.solve(mode: .manual, setting: unusual, ev100: 16, compensationEV: 2)
        #expect(result.setting == unusual)
        #expect(!(result.isLimited))
        #expect(abs((result.residualEV) - (ExposureEngine.deltaEV(ev100: 16, setting: unusual) - 2)) <= 1e-10)
    }

    @Test
    func testAperturePriorityChangesOnlyShutter() {
        let original = ExposureSetting(iso: 400, aperture: 5.6, shutterSeconds: 1)
        let result = ExposureEngine.solve(mode: .aperturePriority, setting: original, ev100: 12)
        #expect(result.setting.iso == original.iso)
        #expect(result.setting.aperture == original.aperture)
        #expect(result.setting.shutterSeconds != original.shutterSeconds)
        #expect(ExposureEngine.shutterStops.contains(result.setting.shutterSeconds))
        #expect(!(result.isLimited))
        #expect(abs(result.residualEV) < 0.2)
    }

    @Test
    func testShutterPriorityChangesOnlyAperture() {
        let original = ExposureSetting(iso: 400, aperture: 1.4, shutterSeconds: 1.0 / 125)
        let result = ExposureEngine.solve(mode: .shutterPriority, setting: original, ev100: 12)
        #expect(result.setting.iso == original.iso)
        #expect(result.setting.shutterSeconds == original.shutterSeconds)
        #expect(result.setting.aperture != original.aperture)
        #expect(ExposureEngine.apertureStops.contains(result.setting.aperture))
        #expect(!(result.isLimited))
        #expect(abs(result.residualEV) < 0.2)
    }

    @Test
    func testAutomaticQuantizationAcrossInteriorRange() {
        // Sweep measured scene EVs; bounded error is the nearest nominal stop's half interval.
        for sceneEV in stride(from: 5.0, through: 18.0, by: 0.07) {
            for mode in [ExposureMode.aperturePriority, .shutterPriority] {
                let result = ExposureEngine.solve(
                    mode: mode,
                    setting: ExposureSetting(iso: 100, aperture: 5.6, shutterSeconds: 1.0 / 125),
                    ev100: sceneEV,
                    compensationEV: 0.3
                )
                if !result.isLimited {
                    #expect(abs(result.residualEV) <= 0.24, "mode=\(mode) EV=\(sceneEV)")
                }
            }
        }
    }

    @Test
    func testAperturePriorityLimitsBothEndsAndReportsResidual() {
        let input = ExposureSetting(iso: 100, aperture: 8, shutterSeconds: 1.0 / 125)
        let tooDark = ExposureEngine.solve(mode: .aperturePriority, setting: input, ev100: -10)
        #expect(tooDark.setting.shutterSeconds == 4)
        #expect(tooDark.isLimited)
        #expect(tooDark.residualEV < 0)

        let tooBright = ExposureEngine.solve(mode: .aperturePriority, setting: input, ev100: 30)
        #expect(tooBright.setting.shutterSeconds == 1.0 / 8000)
        #expect(tooBright.isLimited)
        #expect(tooBright.residualEV > 0)
    }

    @Test
    func testShutterPriorityLimitsBothEnds() {
        let input = ExposureSetting(iso: 100, aperture: 8, shutterSeconds: 1.0 / 125)
        let tooDark = ExposureEngine.solve(mode: .shutterPriority, setting: input, ev100: -10)
        #expect(tooDark.setting.aperture == 1)
        #expect(tooDark.isLimited)
        #expect(tooDark.residualEV < 0)

        let tooBright = ExposureEngine.solve(mode: .shutterPriority, setting: input, ev100: 30)
        #expect(tooBright.setting.aperture == 22)
        #expect(tooBright.isLimited)
        #expect(tooBright.residualEV > 0)
    }

    @Test
    func testExactLimitsAreNotReportedAsClipped() throws {
        for time in [ExposureEngine.shutterStops.first!, ExposureEngine.shutterStops.last!] {
            let input = ExposureSetting(iso: 100, aperture: 8, shutterSeconds: time)
            let reading = try #require(ExposureEngine.ev100(aperture: 8, shutterSeconds: time, iso: 100))
            let solution = ExposureEngine.solve(mode: .aperturePriority, setting: input, ev100: reading)
            #expect(!(solution.isLimited))
            #expect(solution.setting.shutterSeconds == time)
            #expect(abs((solution.residualEV) - (0)) <= 1e-10)
        }
        for aperture in [ExposureEngine.apertureStops.first!, ExposureEngine.apertureStops.last!] {
            let input = ExposureSetting(iso: 100, aperture: aperture, shutterSeconds: 1.0 / 125)
            let reading = try #require(ExposureEngine.ev100(
                aperture: aperture, shutterSeconds: input.shutterSeconds, iso: 100
            ))
            let solution = ExposureEngine.solve(mode: .shutterPriority, setting: input, ev100: reading)
            #expect(!(solution.isLimited))
            #expect(solution.setting.aperture == aperture)
        }
    }

    @Test
    func testInvalidInputsAreRejectedWithoutInventingAReading() {
        for invalid in [0, -1, Double.nan, .infinity, -.infinity] {
            #expect(ExposureEngine.ev100(aperture: invalid, shutterSeconds: 0.01, iso: 100) == nil)
            #expect(ExposureEngine.ev100(aperture: 8, shutterSeconds: invalid, iso: 100) == nil)
            #expect(ExposureEngine.ev100(aperture: 8, shutterSeconds: 0.01, iso: invalid) == nil)
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(ExposureEngine.ev100(aperture: 8, shutterSeconds: 0.01, iso: 100, calibrationEV: invalid) == nil)
            #expect(ExposureEngine.targetEV(ev100: invalid, iso: 100).isNaN)
            #expect(ExposureEngine.deltaEV(ev100: invalid, setting: ExposureSetting()).isNaN)
            let solution = ExposureEngine.solve(mode: .aperturePriority, setting: ExposureSetting(), ev100: invalid)
            #expect(solution.setting == ExposureSetting())
            #expect(solution.residualEV.isNaN)
            #expect(solution.isLimited)
        }
        #expect(ExposureEngine.targetEV(ev100: 12, iso: 0).isNaN)
        #expect(ExposureEngine.targetEV(ev100: 12, iso: 100, compensationEV: .nan).isNaN)
        let invalidSetting = ExposureSetting(iso: 400, aperture: 0, shutterSeconds: 0.01)
        let invalidSolution = ExposureEngine.solve(mode: .manual, setting: invalidSetting, ev100: 12)
        #expect(invalidSolution.setting == invalidSetting)
        #expect(invalidSolution.residualEV.isNaN)
    }

    @Test
    func testFilmRiskThresholdsAreInclusiveAndHaveNoExposureBias() {
        for film in [FilmKind.negative, .blackAndWhite] {
            #expect(ExposureEngine.risk(deltaEV: -2, film: film) == .shadows)
            #expect(ExposureEngine.risk(deltaEV: -1.999, film: film) == .darker)
            #expect(ExposureEngine.risk(deltaEV: 2.999, film: film) == .brighter)
            #expect(ExposureEngine.risk(deltaEV: 3, film: film) == .highlights)
        }
        #expect(ExposureEngine.risk(deltaEV: -1, film: .slide) == .shadows)
        #expect(ExposureEngine.risk(deltaEV: -0.999, film: .slide) == .darker)
        #expect(ExposureEngine.risk(deltaEV: 0.999, film: .slide) == .brighter)
        #expect(ExposureEngine.risk(deltaEV: 1, film: .slide) == .highlights)

        for film in FilmKind.allCases {
            #expect(ExposureEngine.risk(deltaEV: 0, film: film) == .balanced)
            #expect(ExposureEngine.risk(deltaEV: 0.339, film: film) == .balanced)
            #expect(ExposureEngine.risk(deltaEV: -0.339, film: film) == .balanced)
            #expect(ExposureEngine.risk(deltaEV: 0.34, film: film) == .brighter)
            #expect(ExposureEngine.risk(deltaEV: -0.34, film: film) == .darker)
        }
        #expect(ExposureRisk.highlights.isSevere)
        #expect(ExposureRisk.shadows.isSevere)
        #expect(!(ExposureRisk.brighter.isSevere))
        #expect(!(ExposureRisk.darker.isSevere))
        #expect(!(ExposureRisk.balanced.isSevere))
    }

    @Test
    func testStopTablesAndLabels() {
        #expect(ExposureEngine.isoStops.first == 25)
        #expect(ExposureEngine.isoStops.last == 3200)
        #expect(ExposureEngine.apertureStops.first == 1)
        #expect(ExposureEngine.apertureStops.last == 22)
        #expect(ExposureEngine.shutterStops.first == 1.0 / 8000)
        #expect(ExposureEngine.shutterStops.last == 4)
        for table in [ExposureEngine.isoStops, ExposureEngine.apertureStops, ExposureEngine.shutterStops] {
            #expect(zip(table, table.dropFirst()).allSatisfy { $0 < $1 })
        }
        #expect(ExposureEngine.shutterLabel(1.0 / 125) == "1/125")
        #expect(ExposureEngine.shutterLabel(1.3) == "1.3 s")
        #expect(ExposureEngine.shutterLabel(4) == "4 s")
        #expect(ExposureEngine.shutterLabel(.nan) == "—")
    }

    @Test
    func testSettingsRoundTripPreservesManualValues() throws {
        let input = ExposureSetting(iso: 400, aperture: 5.6, shutterSeconds: 1.0 / 125)
        let data = try JSONEncoder().encode(input)
        #expect(try JSONDecoder().decode(ExposureSetting.self, from: data) == input)
        #expect(ExposureMode.allCases.map(\.rawValue) == ["M", "A", "S"])
    }
}
