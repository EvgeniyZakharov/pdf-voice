import AVFoundation

/// Единый список голосов для выбора: системные (всегда) + Silero (если сервер
/// доступен). Идентификатор хранится строкой: "sys:<id>" или "silero:<speaker>".
enum VoiceKind { case system, silero }

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let kind: VoiceKind
    let systemIdentifier: String?
    let sileroSpeaker: String?
}

enum VoiceCatalog {

    /// Кэш сырого списка голосов ОС. `AVSpeechSynthesisVoice.speechVoices()`
    /// синхронно опрашивает систему — дорого дёргать на каждый рендер SwiftUI
    /// body (Menu с этим списком пересобирается на каждую смену предложения и
    /// каждый кадр скролла reflow, см. аудит П3). Кэшируем НА ПРОЦЕСС, без
    /// инвалидации по нотификации: `AVSpeechSynthesizer.availableVoicesDidChangeNotification`
    /// доступна только с iOS 17, а min iOS проекта — 16, `#available`-гардом
    /// пришлось бы городить два пути ради события, которое практически никогда
    /// не происходит на лету (голоса ставятся в Настройках iOS, а не пока
    /// открыто приложение) — если это всё же случится, подхватится при
    /// следующем запуске процесса.
    private static var cachedRawVoices: [AVSpeechSynthesisVoice]?

    private static func rawVoices() -> [AVSpeechSynthesisVoice] {
        if let cachedRawVoices { return cachedRawVoices }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        cachedRawVoices = voices
        return voices
    }

    /// Голоса Silero (показываются только при доступном сервере): женский и
    /// мужской. Из пяти спикеров сервера в выборе оставлены два — `xenia`
    /// (бывшая «Ксения 2», теперь просто «Ксения») и `eugene`. Сам сервер
    /// остальных не потерял, они лишь убраны из UI.
    static let sileroSpeakers: [(id: String, title: String)] = [
        ("xenia",  "Ксения"),
        ("eugene", "Евгений"),
    ]

    /// Системный голос ровно один — Милена. Остальные русские голоса iOS из
    /// выбора убраны; Милена же остаётся и офлайн-фолбэком, когда Silero-сервер
    /// недоступен (см. `SpeechEngine.fallBackToSystemVoice`).
    static func systemVoices() -> [AVSpeechSynthesisVoice] {
        let russian = rawVoices()
            .filter { $0.language == "ru-RU" && isRealVoice($0) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        // Милена бывает в нескольких качествах (compact/enhanced/premium) —
        // сортировка выше ставит лучшее первым. Если её на устройстве нет вовсе,
        // берём лучший русский: без системного голоса ломается офлайн-фолбэк.
        let milena = russian.filter(isMilena)
        return Array((milena.isEmpty ? russian : milena).prefix(1))
    }

    private static func isMilena(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.localizedCaseInsensitiveContains("milena")
            || v.name.localizedCaseInsensitiveContains("milena")
            || v.name.localizedCaseInsensitiveContains("милена")
    }

    /// Отсеивает служебные и шуточные голоса iOS. Проверено на устройстве: в
    /// `speechVoices()` для en-US приходят Albert, Bad News, Bells, Zarvox и ещё
    /// полтора десятка эффектов — все с тем же качеством `.default`, что и
    /// нормальная Samantha, так что сортировкой по качеству их не отделить.
    /// Отличает их ЛЕГАСИ-префикс идентификатора; настоящие голоса живут в
    /// `com.apple.voice.*` (compact/enhanced/premium) и `com.apple.ttsbundle.*`.
    private static func isRealVoice(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.hasPrefix("com.apple.voice.")
            || v.identifier.hasPrefix("com.apple.ttsbundle.")
    }

    /// Английские системные голоса — лучшие по качеству, не больше трёх.
    /// Нейроголоса тут не участвуют: Silero-сервер держит русскую модель
    /// (`v3_1_ru`), английский текст ему отдавать нечего.
    static func englishSystemVoices(limit: Int = 3) -> [AVSpeechSynthesisVoice] {
        let english = rawVoices()
            .filter { $0.language.hasPrefix("en-") && isRealVoice($0) }
            .sorted { lhs, rhs in
                // en-US вперёд (основной вариант), дальше по качеству.
                if (lhs.language == "en-US") != (rhs.language == "en-US") {
                    return lhs.language == "en-US"
                }
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
        // Один и тот же голос бывает в нескольких качествах — оставляем по
        // одному на имя (сортировка уже поставила лучшее качество первым).
        var seen = Set<String>()
        let unique = english.filter { seen.insert($0.name).inserted }
        return Array(unique.prefix(limit))
    }

    /// Голос по умолчанию для языка: Милена для русского, лучший системный
    /// английский — для английского.
    static func defaultSelection(for language: String = "ru") -> String {
        let voices = isEnglish(language) ? englishSystemVoices() : systemVoices()
        if let v = voices.first { return "sys:" + v.identifier }
        return "sys:"
    }

    static func isEnglish(_ language: String) -> Bool {
        language.lowercased().hasPrefix("en")
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Стандартный"
        }
    }

    static func systemOptions() -> [VoiceOption] {
        systemVoices().map { v in
            // `v.name` приходит от iOS на языке системы («Milena» на английской),
            // а весь остальной список русский — подписываем явно.
            VoiceOption(id: "sys:" + v.identifier,
                        title: isMilena(v) ? "Милена" : v.name,
                        subtitle: qualityLabel(v),
                        kind: .system,
                        systemIdentifier: v.identifier,
                        sileroSpeaker: nil)
        }
    }

    static func sileroOptions() -> [VoiceOption] {
        sileroSpeakers.map { s in
            VoiceOption(id: "silero:" + s.id,
                        title: s.title,
                        subtitle: "Silero · нейросеть",
                        kind: .silero,
                        systemIdentifier: nil,
                        sileroSpeaker: s.id)
        }
    }

    /// Английские варианты выбора (только системные голоса).
    static func englishOptions() -> [VoiceOption] {
        englishSystemVoices().map { v in
            VoiceOption(id: "sys:" + v.identifier,
                        title: v.name,
                        subtitle: qualityLabel(v),
                        kind: .system,
                        systemIdentifier: v.identifier,
                        sileroSpeaker: nil)
        }
    }

    /// Список для выбора под язык книги. Русский — Милена + нейроголоса (когда
    /// сервер доступен), английский — системные английские голоса.
    static func options(sileroReachable: Bool, language: String = "ru") -> [VoiceOption] {
        if isEnglish(language) { return englishOptions() }
        return systemOptions() + (sileroReachable ? sileroOptions() : [])
    }

    /// Приводит СОХРАНЁННЫЙ выбор к актуальному каталогу ЯЗЫКА. Голос, убранный
    /// из списка (старые `kseniya`/`aidar`/`baya`, другой системный голос, а для
    /// английского — вообще любой русский), заменяем на голос по умолчанию:
    /// иначе Picker показывал бы пустую строку, а озвучка шла голосом, которого
    /// в выборе нет.
    ///
    /// Для русского проверяем по ПОЛНОМУ набору, без гейта доступности сервера:
    /// выбранный нейроголос остаётся валидным и когда сервер временно не отвечает.
    static func sanitized(_ selection: String, for language: String = "ru") -> String {
        isValid(selection, for: language) ? selection : defaultSelection(for: language)
    }

    /// Голос из полного каталога языка (независимо от доступности Silero-сервера
    /// в моменте — см. комментарий у `sanitized`). Используется для проверки
    /// ПО-КНИЖНОГО выбора (`LibraryItem.voiceID`): русский Silero-спикер невалиден
    /// для английской книги (Silero знает только русский), голос, убранный из
    /// каталога — невалиден для любой книги.
    static func isValid(_ selection: String, for language: String = "ru") -> Bool {
        let valid = isEnglish(language) ? englishOptions() : systemOptions() + sileroOptions()
        return valid.contains { $0.id == selection }
    }
}
