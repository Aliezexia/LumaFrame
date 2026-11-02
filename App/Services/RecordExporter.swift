import Photos
import SwiftUI
import UIKit

enum PhotoSaveFailure: LocalizedError, Equatable {
    case denied, failed

    var errorDescription: String? {
        switch self {
        case .denied: return "尚未允许添加照片。可在系统设置中开启照片添加权限，或使用分享保存记录。"
        case .failed: return "照片没有保存成功。记录仍保留在此页面，可重试或分享。"
        }
    }
}

enum RecordExporter {
    @MainActor private static var hasInjectedSaveFailure = false
    /// Uses the unfiltered reference image. Exposure-trend processing belongs to the
    /// preview and must not be confused with a physically accurate film rendering.
    static func compose(image: UIImage, lines: [String], title: String, parameters: [RecordParameter] = []) -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }
        let width: CGFloat = min(1600, max(720, image.size.width))
        let inset = width * 0.035
        let textWidth = width - inset * 2
        let imageHeight = textWidth * image.size.height / image.size.width
        let titleFont = UIFont.systemFont(ofSize: width * 0.035, weight: .semibold)
        let bodyFont = UIFont.monospacedSystemFont(ofSize: width * 0.024, weight: .medium)
        let noteFont = UIFont.systemFont(ofSize: width * 0.020, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = width * 0.007
        paragraph.lineBreakMode = .byWordWrapping
        let ink = UIColor(red: 0.12, green: 0.13, blue: 0.13, alpha: 1)
        let muted = UIColor(red: 0.32, green: 0.33, blue: 0.32, alpha: 1)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont, .foregroundColor: ink, .paragraphStyle: paragraph
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: ink, .paragraphStyle: paragraph
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: noteFont, .foregroundColor: muted, .paragraphStyle: paragraph
        ]
        let note = "取景参考图 · 参数用于拍摄记录，不代表胶片成片"
        func height(_ value: String, attributes: [NSAttributedString.Key: Any], width: CGFloat? = nil) -> CGFloat {
            ceil((value as NSString).boundingRect(with: CGSize(width: width ?? textWidth, height: .greatestFiniteMagnitude),
                 options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height)
        }
        let titleHeight = height(title, attributes: titleAttributes)
        // Structured rows are shared with the record sheet. Legacy callers retain
        // their verbatim text; never infer data by splitting localized display strings.
        let body = parameters.isEmpty ? lines.joined(separator: "\n") : (lines.last ?? "")
        let labelWidth = textWidth * 0.28
        let columnGap = width * 0.025
        let valueWidth = textWidth - labelWidth - columnGap
        let rowGap = width * 0.010
        let rowHeights = parameters.map { parameter in
            max(height(parameter.label, attributes: noteAttributes, width: labelWidth),
                height(parameter.value, attributes: bodyAttributes, width: valueWidth))
        }
        let tableHeight = rowHeights.reduce(0, +) + rowGap * CGFloat(parameters.count)
        let bodyHeight = height(body, attributes: parameters.isEmpty ? bodyAttributes : noteAttributes)
        let noteHeight = height(note, attributes: noteAttributes)
        let gap = width * 0.022
        let outputSize = CGSize(width: width, height: inset + imageHeight + gap + titleHeight + gap + tableHeight + bodyHeight + gap + noteHeight + inset)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            image.draw(in: CGRect(x: inset, y: inset, width: textWidth, height: imageHeight))
            var y = inset + imageHeight + gap
            (title as NSString).draw(in: CGRect(x: inset, y: y, width: textWidth, height: titleHeight), withAttributes: titleAttributes)
            y += titleHeight + gap
            for (index, parameter) in parameters.enumerated() {
                let rowHeight = rowHeights[index]
                (parameter.label as NSString).draw(in: CGRect(x: inset, y: y, width: labelWidth, height: rowHeight), withAttributes: noteAttributes)
                (parameter.value as NSString).draw(in: CGRect(x: inset + labelWidth + columnGap, y: y, width: valueWidth, height: rowHeight), withAttributes: bodyAttributes)
                y += rowHeight + rowGap
            }
            (body as NSString).draw(in: CGRect(x: inset, y: y, width: textWidth, height: bodyHeight), withAttributes: parameters.isEmpty ? bodyAttributes : noteAttributes)
            y += bodyHeight + gap
            (note as NSString).draw(in: CGRect(x: inset, y: y, width: textWidth, height: noteHeight), withAttributes: noteAttributes)
        }
    }

    /// Writes only to Photos' recent items; no album enumeration or read access.
    @MainActor static func save(_ image: UIImage) async throws {
        // These launch arguments only affect the isolated UI-testing process.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") {
            if arguments.contains("-ui-testing-save-denied") { throw PhotoSaveFailure.denied }
            if arguments.contains("-ui-testing-save-failure"), !hasInjectedSaveFailure {
                hasInjectedSaveFailure = true
                throw PhotoSaveFailure.failed
            }
        }
        var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoSaveFailure.denied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                if success { continuation.resume() }
                else { continuation.resume(throwing: PhotoSaveFailure.failed) }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
