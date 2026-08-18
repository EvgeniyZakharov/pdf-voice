import Foundation

/// Общий строитель HTTP-запросов к Silero-серверу + валидация ответа.
///
/// Используется в двух местах: `SileroBackend.fetchAudio` (боевой путь озвучки —
/// ретраи/бэкофф/тайминги и LRU-кэш остаются ТАМ, этот тип только строит запрос и
/// классифицирует статус ответа) и `VoicePreviewer` (демо-фраза голоса в Настройках).
/// `enum` без состояния — потоконезависим, безопасен вызывать из `nonisolated static`
/// сетевого пути `SileroBackend.fetchAudio` (выполняется вне MainActor).
enum SileroClient {
    private struct SynthesizeRequest: Encodable {
        let text: String
        let speaker: String
    }

    /// Сервер отверг КОНКРЕТНЫЙ контент (4xx, кроме 429 — rate limit) — не
    /// транзиентная сетевая ошибка. Вызывающая сторона (`SileroBackend.runQueue`)
    /// не ретраит и не откатывается на системный голос из-за неё.
    enum ContentError: Error {
        case rejected(Int)
    }

    static func makeRequest(baseURL: URL, apiKey: String, speaker: String,
                            text: String, timeout: TimeInterval) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("synthesize"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        req.httpBody = try JSONEncoder().encode(SynthesizeRequest(text: text, speaker: speaker))
        return req
    }

    /// Не бросает на HTTP 200. На прочих статусах бросает `ContentError.rejected`
    /// для 4xx (кроме 429) или `URLError(.badServerResponse)` для остального
    /// (5xx/429/не-HTTP-ответ) — классификация статуса, решение о ретрае остаётся
    /// за вызывающей стороной (см. `SileroBackend.fetchAudio`).
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        if (400...499).contains(http.statusCode), http.statusCode != 429 {
            throw ContentError.rejected(http.statusCode)
        }
        throw URLError(.badServerResponse)
    }
}
