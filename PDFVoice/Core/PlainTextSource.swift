import Foundation

/// Источник для `.txt`: весь файл — одна глава. Детектит кодировку
/// (UTF-8 → Windows-1251 → лосси-UTF-8), т.к. в рунете .txt часто в CP1251.
struct PlainTextSource: ReflowSource {
    let url: URL

    func parse() throws -> BookContent {
        let data = try Data(contentsOf: url)
        let text = Self.decode(data)
        return BookContent(chapters: [BookChapter(title: nil, text: text)])
    }

    /// Порядок проб важен: UTF-8 строгий (отвергает невалидные последовательности),
    /// дальше CP1251 (кириллица), в конце — лосси-UTF-8 как гарантированный фолбэк.
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
