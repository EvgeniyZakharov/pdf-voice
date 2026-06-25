import CoreGraphics
import PDFKit
import UIKit

enum PageKind { case text, ocr, skip }

/// Дешёвая классификация: только плотность букв из текстового слоя, без рендера.
/// Возвращает .text или .ocr — никогда .skip.
/// Вызывать можно на main thread; page.string не рендерит thumbnail.
func textDensityKind(_ page: PDFPage) -> PageKind {
    let s = page.string ?? ""
    var letters = 0, nonSpace = 0
    for ch in s where !ch.isWhitespace { nonSpace += 1; if ch.isLetter { letters += 1 } }
    if nonSpace >= 40 {
        let ratio = Double(letters) / Double(nonSpace)
        if ratio >= 0.35 { return .text }
    }
    return .ocr
}

/// Полная классификация: плотность + blank-чек (рендер 48×48).
/// Использовать ТОЛЬКО off main thread или лениво перед OCR конкретной страницы.
func classifyPage(_ page: PDFPage) -> PageKind {
    let kind = textDensityKind(page)
    guard kind == .ocr else { return .text }
    return isBlankPage(page) ? .skip : .ocr
}

/// Рендерит страницу в маленький (48×48) thumbnail и проверяет разброс яркости.
/// Если (max_luma − min_luma) < 24 — страница практически однотонная (пустая).
/// При невозможности получить пиксели возвращает false (лучше лишний OCR, чем пропуск).
/// Дорогая операция — вызывать только off main thread.
func isBlankPage(_ page: PDFPage) -> Bool {
    let thumb = page.thumbnail(of: CGSize(width: 48, height: 48), for: .mediaBox)
    guard let cgImage = thumb.cgImage else { return false }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return false }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
        data: &pixelData,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minLuma: Int = 255
    var maxLuma: Int = 0

    let pixelCount = width * height
    var offset = 0
    for _ in 0..<pixelCount {
        let r = Int(pixelData[offset])
        let g = Int(pixelData[offset + 1])
        let b = Int(pixelData[offset + 2])
        // BT.601 integer approximation: (77*R + 150*G + 29*B) >> 8
        let luma = (77 * r + 150 * g + 29 * b) >> 8
        if luma < minLuma { minLuma = luma }
        if luma > maxLuma { maxLuma = luma }
        offset += bytesPerPixel
    }

    return (maxLuma - minLuma) < 24
}
