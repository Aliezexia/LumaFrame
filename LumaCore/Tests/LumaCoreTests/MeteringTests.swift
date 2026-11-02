import Foundation
import Testing
@testable import LumaCore

struct MeteringTests {
    @Test
    func uniformGrayIsNeutralInEveryModeAndGridSize() throws {
        for (columns, rows) in [(1, 1), (16, 12), (31, 47)] {
            for mode in MeteringMode.allCases {
                let ev = try #require(SpatialMetering.correction(
                    luminances: Array(repeating: 0.18, count: columns * rows),
                    columns: columns, rows: rows, mode: mode,
                    point: MeteringPoint(x: 0, y: 1), aspectRatio: Double(columns) / Double(rows)))
                #expect(abs(ev) < 1e-12)
            }
        }
    }

    @Test
    func uniformFieldsPreservePhotographicStopDifferences() throws {
        for (luminance, expectedEV) in [(0.045, -2.0), (0.09, -1.0), (0.36, 1.0), (0.72, 2.0)] {
            for mode in MeteringMode.allCases {
                let ev = try #require(SpatialMetering.correction(
                    luminances: Array(repeating: luminance, count: 24 * 18),
                    columns: 24, rows: 18, mode: mode, aspectRatio: 4.0 / 3))
                #expect(abs(ev - expectedEV) < 1e-12)
            }
        }
    }

    @Test
    func selectingBrightAndDarkRegionsChangesTheActualReading() throws {
        let grid = field(columns: 120, rows: 80) { x, _ in x < 0.5 ? 0.045 : 0.72 }
        let dark = try #require(SpatialMetering.correction(
            luminances: grid, columns: 120, rows: 80, mode: .spot,
            point: MeteringPoint(x: 0.25, y: 0.5), aspectRatio: 1.5))
        let bright = try #require(SpatialMetering.correction(
            luminances: grid, columns: 120, rows: 80, mode: .spot,
            point: MeteringPoint(x: 0.75, y: 0.5), aspectRatio: 1.5))
        #expect(abs(dark + 2) < 1e-12)
        #expect(abs(bright - 2) < 1e-12)
        #expect(abs(bright - dark - 4) < 1e-12)
    }

    @Test
    func centerWeightedRespondsMoreToCentralSubjectThanMatrix() throws {
        let grid = field(columns: 80, rows: 80) { x, y in
            hypot(x - 0.5, y - 0.5) < 0.20 ? 0.72 : 0.045
        }
        let matrix = try #require(SpatialMetering.correction(
            luminances: grid, columns: 80, rows: 80, mode: .matrix, aspectRatio: 1))
        let center = try #require(SpatialMetering.correction(
            luminances: grid, columns: 80, rows: 80, mode: .centerWeighted, aspectRatio: 1))
        #expect(center > matrix + 0.4)
        #expect(center < 2, "中央重点仍然应受外围场景影响")
    }

    @Test
    func matrixIsAnEqualAreaAverageAndIgnoresThePoint() throws {
        for point in [MeteringPoint.center, MeteringPoint(x: 0, y: 0), MeteringPoint(x: 1, y: 1)] {
            let ev = try #require(SpatialMetering.correction(
                luminances: [0.1, 0.2, 0.3, 0.4], columns: 2, rows: 2,
                mode: .matrix, point: point, aspectRatio: 2))
            #expect(abs(ev - log2(0.25 / 0.18)) < 1e-12)
        }
    }

    @Test
    func spotDoesNotIncludeLightOutsideItsCircle() throws {
        let grid = field(columns: 160, rows: 160) { x, y in
            hypot(x - 0.5, y - 0.5) <= 0.09 ? 0.18 : 0.9
        }
        let spot = try #require(SpatialMetering.correction(
            luminances: grid, columns: 160, rows: 160, mode: .spot, aspectRatio: 1))
        let matrix = try #require(SpatialMetering.correction(
            luminances: grid, columns: 160, rows: 160, mode: .matrix, aspectRatio: 1))
        #expect(abs(spot) < 1e-12)
        #expect(matrix > 2)
    }

    @Test
    func spotCircleUsesTheShorterPhysicalSide() throws {
        let grid = field(columns: 200, rows: 100) { x, _ in abs(x - 0.5) < 0.06 ? 0.72 : 0.18 }
        let wide = try #require(SpatialMetering.correction(
            luminances: grid, columns: 200, rows: 100, mode: .spot, aspectRatio: 2))
        let square = try #require(SpatialMetering.correction(
            luminances: grid, columns: 200, rows: 100, mode: .spot, aspectRatio: 1))
        #expect(abs(wide - 2) < 1e-12, "宽画幅的点测区横向归一半径应为0.04")
        #expect(square < wide - 0.05)
        #expect(square > 0)
    }

    @Test
    func edgeClampKeepsFullCircleInsideLandscapeAndPortraitFrames() {
        let corner = MeteringPoint(x: 0, y: 1)
        let landscape = SpatialMetering.clampedPoint(corner, aspectRatio: 16.0 / 9)
        let portrait = SpatialMetering.clampedPoint(corner, aspectRatio: 9.0 / 16)
        #expect(abs(landscape.x - 0.045) < 1e-12)
        #expect(abs(landscape.y - 0.92) < 1e-12)
        #expect(abs(portrait.x - 0.08) < 1e-12)
        #expect(abs(portrait.y - 0.955) < 1e-12)
        #expect(SpatialMetering.clampedPoint(.center, aspectRatio: 0.75) == .center)
        #expect(SpatialMetering.clampedPoint(corner, aspectRatio: .nan) == .center)
    }

    @Test
    func coarseGridStillHasARealSpotAverageAcrossCellBoundary() throws {
        let ev = try #require(SpatialMetering.correction(
            luminances: [0.09, 0.36], columns: 2, rows: 1, mode: .spot, aspectRatio: 1))
        #expect(abs(ev - log2(0.225 / 0.18)) < 1e-12)
    }

    @Test
    func blackAndWhiteStayFiniteAndBounded() throws {
        for mode in MeteringMode.allCases {
            let black = try #require(SpatialMetering.correction(
                luminances: [0], columns: 1, rows: 1, mode: mode, aspectRatio: 1))
            let white = try #require(SpatialMetering.correction(
                luminances: [1], columns: 1, rows: 1, mode: mode, aspectRatio: 1))
            #expect(black.isFinite && black >= -18)
            #expect(abs(black - log2(0.000001 / 0.18)) < 1e-12)
            #expect(abs(white - log2(1 / 0.18)) < 1e-12)
        }
    }

    @Test
    func invalidGridAndLuminanceAreRejected() {
        for mode in MeteringMode.allCases {
            #expect(SpatialMetering.correction(luminances: [], columns: 0, rows: 1, mode: mode, aspectRatio: 1) == nil)
            #expect(SpatialMetering.correction(luminances: [0.18], columns: -1, rows: -1, mode: mode, aspectRatio: 1) == nil)
            #expect(SpatialMetering.correction(luminances: [0.18], columns: 2, rows: 1, mode: mode, aspectRatio: 1) == nil)
            #expect(SpatialMetering.correction(luminances: [0.18], columns: Int.max, rows: 2, mode: mode, aspectRatio: 1) == nil)
            for luminance in [-0.1, 1.01, .nan, .infinity] {
                #expect(SpatialMetering.correction(luminances: [luminance], columns: 1, rows: 1, mode: mode, aspectRatio: 1) == nil)
            }
            for aspect in [0.0, -1, .nan, .infinity, Double.leastNonzeroMagnitude] {
                #expect(SpatialMetering.correction(luminances: [0.18], columns: 1, rows: 1, mode: mode, aspectRatio: aspect) == nil)
            }
        }
    }

    @Test
    func pointNormalizationAlsoAppliesToDecodedCoordinates() throws {
        #expect(MeteringPoint(x: -2, y: .infinity) == MeteringPoint(x: 0, y: 0.5))
        #expect(MeteringPoint(x: .nan, y: 3) == MeteringPoint(x: 0.5, y: 1))
        let decoded = try JSONDecoder().decode(MeteringPoint.self, from: Data("{\"x\":2,\"y\":-1}".utf8))
        #expect(decoded == MeteringPoint(x: 1, y: 0))
        let point = MeteringPoint(x: 0.23, y: 0.81)
        #expect(try JSONDecoder().decode(MeteringPoint.self, from: JSONEncoder().encode(point)) == point)
        for mode in MeteringMode.allCases {
            #expect(try JSONDecoder().decode(MeteringMode.self, from: JSONEncoder().encode(mode)) == mode)
        }
    }

    private func field(columns: Int, rows: Int, value: (Double, Double) -> Double) -> [Double] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                value((Double(column) + 0.5) / Double(columns), (Double(row) + 0.5) / Double(rows))
            }
        }
    }
}
