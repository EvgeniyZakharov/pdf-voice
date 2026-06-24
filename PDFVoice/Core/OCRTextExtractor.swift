import Foundation
import NaturalLanguage
import PDFKit
import UIKit
import Vision

/// Распознавание текста на сканах (PDF без текстового слоя) через Vision.
/// Возвращает предложения с боксами строк в координатах страницы — для подсветки.
enum OCRTextExtractor {

    /// Распознаёт документ. `progress(done, total)` вызывается на главном потоке.
    static func sentences(from document: PDFDocument,
                          pageRange: Range<Int>? = nil,
                          progress: @escaping (Int, Int) -> Void) async -> [Sentence] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let range = pageRange ?? (0..<pageCount)
        guard !range.isEmpty else { return [] }

        var result: [Sentence] = []
        let tokenizer = NLTokenizer(unit: .sentence)

        for pi in range {
            let done = pi - range.lowerBound + 1
            let total = range.count
            defer { Task { @MainActor in progress(done, total) } }
            guard let page = document.page(at: pi) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            guard let observations = await recognize(page: page, pageRect: pageRect),
                  !observations.isEmpty else { continue }

            // Склеиваем текст страницы и запоминаем диапазон + бокс каждой строки.
            var pageText = ""
            var lineRanges: [(NSRange, CGRect)] = []
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let str = candidate.string
                let start = (pageText as NSString).length
                pageText += str + " "
                let range = NSRange(location: start, length: (str as NSString).length)
                let bb = obs.boundingBox   // нормализованный, origin внизу-слева
                let box = CGRect(x: bb.minX * pageRect.width,
                                 y: bb.minY * pageRect.height,
                                 width: bb.width * pageRect.width,
                                 height: bb.height * pageRect.height)
                lineRanges.append((range, box))
            }
            guard !pageText.isEmpty else { continue }

            tokenizer.string = pageText
            tokenizer.enumerateTokens(in: pageText.startIndex..<pageText.endIndex) { range, _ in
                let ns = NSRange(range, in: pageText)
                let raw = (pageText as NSString).substring(with: ns)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let spoken = TextNormalizer.expandForSpeech(raw)
                guard !spoken.isEmpty else { return true }

                let boxes = lineRanges
                    .filter { NSIntersectionRange($0.0, ns).length > 0 }
                    .map { $0.1 }
                result.append(Sentence(text: spoken, pageIndex: pi, boxes: boxes))
                return true
            }
        }
        return result
    }

    /// Распознавание одной страницы. Vision выполняется на фоновой очереди.
    private static func recognize(page: PDFPage, pageRect: CGRect) async -> [VNRecognizedTextObservation]? {
        let scale: CGFloat = 2
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        guard let cgImage = page.thumbnail(of: size, for: .mediaBox).cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["ru-RU", "en-US"]
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results as? [VNRecognizedTextObservation])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
