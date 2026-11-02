import UIKit

/// Bundled procedural illustration: explicitly labelled demo, never treated as a camera measurement.
enum DemoScene {
    static let image: UIImage = {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let c = renderer.cgContext
            let colors = [UIColor(red: 0.56, green: 0.69, blue: 0.68, alpha: 1).cgColor,
                          UIColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 900), options: [])
            UIColor(red: 0.98, green: 0.87, blue: 0.58, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 600, y: 230, width: 140, height: 140))
            func mountain(_ points: [CGPoint], color: UIColor) {
                c.beginPath(); c.move(to: points[0])
                for p in points.dropFirst() { c.addLine(to: p) }
                c.closePath(); c.setFillColor(color.cgColor); c.fillPath()
            }
            mountain([CGPoint(x: 0,y: 730),CGPoint(x: 0,y: 590),CGPoint(x: 220,y: 370),CGPoint(x: 440,y: 620),CGPoint(x: 650,y: 450),CGPoint(x: 900,y: 630),CGPoint(x: 900,y: 730)],
                     color: UIColor(red: 0.40, green: 0.54, blue: 0.52, alpha: 1))
            mountain([CGPoint(x: 0,y: 840),CGPoint(x: 0,y: 780),CGPoint(x: 340,y: 540),CGPoint(x: 620,y: 800),CGPoint(x: 900,y: 590),CGPoint(x: 900,y: 840)],
                     color: UIColor(red: 0.22, green: 0.39, blue: 0.38, alpha: 1))
            c.setFillColor(UIColor(red: 0.46, green: 0.63, blue: 0.61, alpha: 1).cgColor)
            c.fill(CGRect(x: 0,y: 835,width: 900,height: 365))
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.24).cgColor)
            c.setLineWidth(2)
            for row in 0..<18 {
                let y = CGFloat(855 + row * 18)
                c.move(to: CGPoint(x: 40 + (row % 3) * 42, y: Int(y)))
                c.addLine(to: CGPoint(x: 850 - (row % 4) * 37, y: Int(y)))
            }
            c.strokePath()
            mountain([CGPoint(x: 0,y: 1200),CGPoint(x: 0,y: 1010),CGPoint(x: 220,y: 960),CGPoint(x: 470,y: 1130),CGPoint(x: 900,y: 1080),CGPoint(x: 900,y: 1200)],
                     color: UIColor(red: 0.13, green: 0.25, blue: 0.25, alpha: 1))
            for i in 0..<5 {
                let x = CGFloat(40 + i * 49), y = CGFloat(930 + (i % 3) * 25), h = CGFloat(210 - i * 17)
                mountain([CGPoint(x:x,y:y-h),CGPoint(x:x-48,y:y),CGPoint(x:x+48,y:y)],
                         color: UIColor(red: 0.13, green: 0.27, blue: 0.26, alpha: 1))
            }
        }
    }()
    static func preview(zoom: Double, aspect: CGFloat) -> UIImage {
        let cropped = crop(image, aspect: aspect)
        let factor = max(1, zoom)
        let size = cropped.size
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            cropped.draw(in: CGRect(x: size.width * (1 - factor) / 2, y: size.height * (1 - factor) / 2,
                                    width: size.width * factor, height: size.height * factor))
        }
    }

    /// Synthetic EV differences come from the same selected visible demo pixels.
    /// The matrix baseline is the user-selected demo EV, never a real measurement.
    static func meteringOffset(image: UIImage, mode: MeteringMode, point: MeteringPoint) -> Double {
        let columns = 48, rows = 64
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: columns, height: rows,
                bitsPerComponent: 8, bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cgImage = image.cgImage else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard rendered else { return 0 }
        func linear(_ byte: UInt8) -> Double {
            let v = Double(byte) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let values = stride(from: 0, to: pixels.count, by: 4).map { i in
            0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
        }
        let aspect = Double(image.size.width / image.size.height)
        guard let selected = SpatialMetering.correction(luminances: values, columns: columns, rows: rows,
                  mode: mode, point: point, aspectRatio: aspect),
              let matrix = SpatialMetering.correction(luminances: values, columns: columns, rows: rows,
                  mode: .matrix, aspectRatio: aspect) else { return 0 }
        return selected - matrix
    }

    static func crop(_ image: UIImage, aspect: CGFloat) -> UIImage {
        let original = image.size
        let width = min(original.width, original.height * aspect)
        let height = min(original.height, original.width / aspect)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(at: CGPoint(x: -(original.width-width)/2, y: -(original.height-height)/2))
        }
    }
}

