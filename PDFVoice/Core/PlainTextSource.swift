import Foundation

/// Источник для `.txt`: весь файл — одна глава. Детектит кодировку
/// (UTF-8 → Windows-1251 → лосси-UTF-8), т.к. в рунете .txt часто в CP1251.
struct PlainTextSource: ReflowSource {
    let url: URL

    func parse() throws -> BookContent {
        let data = try Data(contentsOf: url)
        let text = Self.normalize(Self.decode(data))
        return BookContent(chapters: [BookChapter(title: nil, text: text)])
    }

    /// Приводит «сырой» TXT к абзацам, разделённым одинарным «\n» (зазор даёт
    /// paragraphSpacing рендерера). Абзацы в TXT разделены пустой строкой; внутри
    /// абзаца переносы строк «мягкие» (хард-врап) — разворачиваем их в пробел.
    /// Без этого пустые строки давали огромные отступы, а хард-врап — рваный текст.
    static func normalize(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = unified.components(separatedBy: "\n\n")
            .map { para in
                para.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n")
    }

    /// Порядок проб важен: UTF-8 строгий (отвергает невалидные последовательности),
    /// дальше CP1251 (кириллица), в конце — лосси-UTF-8 как гарантированный фолбэк.
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
