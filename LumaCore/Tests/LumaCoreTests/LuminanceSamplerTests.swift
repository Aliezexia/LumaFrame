import Foundation
import Testing
@testable import LumaCore

struct LuminanceSamplerTests {
    @Test
    func uniformGrayUsesSRGBLinearizationAcrossUnevenCells() throws {
        for byte: UInt8 in [0, 1, 10, 64, 128, 255] {
            let image = grayImage(width: 11, height: 7) { _, _ in byte }
            let grid = try #require(sample(image, width: 11, height: 7, columns: 3, rows: 2))
            let encoded = Double(byte) / 255
            let expected = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            #expect(grid.count == 6)
            #expect(grid.allSatisfy { abs($0 - expected) < 1e-12 })
        }
    }

    @Test
    func onePixelShiftOfFineStripesPreservesMeteredExposure() throws {
        var readings: [Double] = []
        for shift in [0, 1] {
            // The former center-pixel sampler selected either all dark or all white
            // pixels here, even though the actual scene average does not change.
            let image = grayImage(width: 720, height: 128) { x, _ in
                (x - shift + 15) % 15 == 7 ? 26 : 255
            }
            let grid = try #require(sample(image, width: 720, height: 128, columns: 48, rows: 64))
            let value = try #require(SpatialMetering.correction(luminances: grid, columns: 48, rows: 64,
                                                               mode: .matrix, aspectRatio: 720.0 / 128))
            readings.append(value)
        }
        let dark = pow((26.0 / 255 + 0.055) / 1.055, 2.4)
        let expected = log2(((14 + dark) / 15) / 0.18)
        #expect(abs(readings[0] - expected) < 1e-12)
        #expect(abs(readings[1] - readings[0]) < 1e-12)
    }

    @Test
    func averagesLinearLightRatherThanEncodedChannelValues() throws {
        let image = grayImage(width: 2, height: 1) { x, _ in x == 0 ? 0 : 255 }
        let grid = try #require(sample(image, width: 2, height: 1, columns: 1, rows: 1))
        #expect(abs(grid[0] - 0.5) < 1e-12)
    }

    @Test
    func bgraChannelOrderIgnoresAlphaAndRowPadding() throws {
        // Two BGRA pixels per row; four padding bytes after the first row.
        // The allocation deliberately omits trailing padding after the final row.
        let bytes: [UInt8] = [0, 0, 255, 0, 0, 255, 0, 255, 255, 255, 255, 255,
                              255, 0, 0, 255, 255, 255, 255, 0]
        let grid = try #require(sample(bytes, width: 2, height: 2, bytesPerRow: 12, columns: 2, rows: 2))
        for (actual, expected) in zip(grid, [0.2126, 0.7152, 0.0722, 1]) {
            #expect(abs(actual - expected) < 1e-12)
        }
    }

    @Test
    func cropUsesTopLeftOriginWithoutIncludingSurroundingPixels() throws {
        var bytes = grayImage(width: 4, height: 3) { _, _ in 255 }
        let colors: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255],
                                [255, 0, 0, 255], [0, 0, 0, 255]]
        for (index, position) in [(1, 1), (2, 1), (1, 2), (2, 2)].enumerated() {
            let offset = (position.1 * 4 + position.0) * 4
            bytes.replaceSubrange(offset..<(offset + 4), with: colors[index])
        }
        let grid = try #require(sample(bytes, width: 4, height: 3,
                                      crop: PixelCrop(x: 1, y: 1, width: 2, height: 2), columns: 2, rows: 2))
        for (actual, expected) in zip(grid, [0.2126, 0.7152, 0.0722, 0]) {
            #expect(abs(actual - expected) < 1e-12)
        }
    }

    @Test
    func fractionalCellBoundariesPreserveWholeCropMean() throws {
        let bytes = grayImage(width: 5, height: 7) { x, y in x == 0 && y == 0 ? 255 : 0 }
        let grid = try #require(sample(bytes, width: 5, height: 7, columns: 3, rows: 2))
        let mean = grid.reduce(0.0, +) / Double(grid.count)
        #expect(abs(mean - 1.0 / 35) < 1e-12)
        #expect(abs(grid[0] - 6.0 / 35) < 1e-12)
        #expect(grid.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test
    func invalidDimensionsBufferStrideAndCropAreRejected() {
        let bytes = grayImage(width: 4, height: 3) { _, _ in 128 }
        #expect(sample(bytes, width: 0, height: 3) == nil)
        #expect(sample(bytes, width: 4, height: -1) == nil)
        #expect(sample(bytes, width: 4, height: 3, bytesPerRow: 15) == nil)
        #expect(sample(bytes, width: 4, height: 3, bytesPerRow: -1) == nil)
        #expect(sample(Array(bytes.dropLast()), width: 4, height: 3) == nil)
        #expect(sample([], width: 4, height: 3) == nil)
        #expect(sample(bytes, width: 4, height: 3, columns: 0) == nil)
        #expect(sample(bytes, width: 4, height: 3, rows: -1) == nil)
        #expect(sample(bytes, width: 4, height: 3, columns: 5) == nil)
        #expect(sample(bytes, width: 4, height: 3, rows: 4) == nil)
        for crop in [PixelCrop(x: -1, y: 0, width: 1, height: 1),
                     PixelCrop(x: 0, y: -1, width: 1, height: 1),
                     PixelCrop(x: 0, y: 0, width: 0, height: 1),
                     PixelCrop(x: 0, y: 0, width: 1, height: -1),
                     PixelCrop(x: 3, y: 0, width: 2, height: 1),
                     PixelCrop(x: 0, y: 3, width: 1, height: 1),
                     PixelCrop(x: Int.max, y: 0, width: Int.max, height: 1)] {
            #expect(sample(bytes, width: 4, height: 3, crop: crop) == nil)
        }
    }

    @Test
    func impossibleSizeArithmeticReturnsNilWithoutTrapping() {
        let bytes: [UInt8] = [0, 0, 0, 255]
        #expect(sample(bytes, width: Int.max, height: 1, bytesPerRow: Int.max) == nil)
        #expect(sample(bytes, width: 1, height: Int.max, bytesPerRow: 8) == nil)
        #expect(sample(bytes, width: 1, height: 3, bytesPerRow: Int.max / 2) == nil)
        #expect(sample(bytes, width: Int.max / 4, height: 8, bytesPerRow: Int.max,
                       columns: Int.max / 4, rows: 8) == nil)
    }

    private func grayImage(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                bytes.append(contentsOf: [value, value, value, 255])
            }
        }
        return bytes
    }

    private func sample(_ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int? = nil,
                        crop: PixelCrop? = nil, columns: Int = 1, rows: Int = 1) -> [Double]? {
        bytes.withUnsafeBufferPointer {
            LuminanceSampler.grid(bgra: $0, width: width, height: height,
                                  bytesPerRow: bytesPerRow ?? width * 4,
                                  crop: crop ?? PixelCrop(x: 0, y: 0, width: width, height: height),
                                  columns: columns, rows: rows)
        }
    }
}
