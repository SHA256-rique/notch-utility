import Foundation
import AVFoundation
import Combine

/// One new word a day, in whichever languages the user is learning.
///
/// ## Why the selection is derived, not stored
/// The obvious design is "pick a random word each midnight and write it to
/// disk". That needs a timer that fires at midnight, survives sleep, survives
/// the clock changing, and survives the app not running that day -- four ways to
/// show the wrong word.
///
/// Instead the word for a given day is a pure function of the day and the
/// language: `index = (dayNumber + languageOffset) % packCount`. There is no
/// scheduled work at all, the answer is the same whether you open the app at
/// 00:01 or at 23:59, and a day the app never ran simply passes by. The only
/// state on disk is what the user *did* -- which words they marked as learned.
///
/// The per-language offset means two enabled languages do not march in lockstep
/// through position 1, position 2, position 3 of their packs, which looks
/// mechanical the moment you notice it.
@MainActor
final class DailyWordService: ObservableObject {

    private struct Model: Codable {
        /// `WordEntry.id` values the user has ticked off.
        var learned: [String] = []
        /// `yyyy-MM-dd` days on which at least one word was marked learned.
        var learnedDays: [String] = []
    }

    @Published private(set) var learned: Set<String> = []
    @Published private(set) var learnedDays: Set<String> = []
    /// Forces a re-read of today's words when the day rolls over while the
    /// panel happens to be open.
    @Published private(set) var dayStamp: String = DailyWordService.today()

    static let shared = DailyWordService()

    private let store = JSONStore<Model>(filename: "words.json", debounce: 0.6)
    private var token: UUID?

    private init() {
        let model = store.load() ?? Model()
        learned = Set(model.learned)
        learnedDays = Set(model.learnedDays)
    }

    // MARK: - Lifecycle

    /// The only reason this polls at all is the midnight rollover while the
    /// panel is pinned open. Ten minutes is plenty -- being up to ten minutes
    /// late to swap the card at 00:00 is not a defect anyone can perceive.
    func activate() {
        guard token == nil else { return }
        token = WidgetPollingHub.shared.register(label: "daily-word", interval: 600) { [weak self] in
            Task { @MainActor in
                let now = Self.today()
                if now != self?.dayStamp { self?.dayStamp = now }
            }
        }
    }

    func deactivate() {
        WidgetPollingHub.shared.unregister(token)
        token = nil
    }

    // MARK: - Selection

    /// Today's word in each enabled language, in the user's chosen order.
    var todaysWords: [WordEntry] {
        enabledLanguages.compactMap { word(for: $0) }
    }

    var enabledLanguages: [WordLanguage] {
        Settings.shared.data.dailyWord.languages.compactMap(WordLanguage.init(rawValue:))
    }

    func word(for language: WordLanguage, on date: Date = Date()) -> WordEntry? {
        let pack = WordPacks.pack(for: language)
        guard !pack.isEmpty else { return nil }
        let index = (Self.dayNumber(date) + Self.offset(for: language)) % pack.count
        return pack[index]
    }

    /// Days since the reference epoch, in the user's own calendar. Using the
    /// local calendar rather than `timeIntervalSince1970 / 86400` means the word
    /// changes at the user's midnight, not at UTC midnight -- which for anyone
    /// west of Greenwich would otherwise flip the card mid-afternoon.
    nonisolated static func dayNumber(_ date: Date = Date()) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let today = calendar.startOfDay(for: date)
        return max(0, calendar.dateComponents([.day], from: start, to: today).day ?? 0)
    }

    /// A stable, boring hash. Not `hashValue`: Swift's string hashing is seeded
    /// per process, so the offset would change on every launch and the word of
    /// the day would not survive a restart.
    nonisolated static func offset(for language: WordLanguage) -> Int {
        var accumulator = 7
        for byte in language.rawValue.utf8 {
            accumulator = (accumulator &* 31 &+ Int(byte)) % 100_003
        }
        return accumulator
    }

    nonisolated static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Progress

    func isLearned(_ entry: WordEntry) -> Bool { learned.contains(entry.id) }

    func toggleLearned(_ entry: WordEntry) {
        if learned.contains(entry.id) {
            learned.remove(entry.id)
        } else {
            learned.insert(entry.id)
            learnedDays.insert(Self.today())
            NotchArbiter.shared.flash("Learned", symbol: "checkmark.seal.fill",
                                      module: .notes, detail: entry.term)
        }
        persist()
    }

    /// Consecutive days on which at least one word was marked learned, ending
    /// today or yesterday. Same leniency as the Claude usage streak: at 9am you
    /// have not done today's yet, and zeroing the streak for that would be
    /// wrong and discouraging in equal measure.
    var streak: Int {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        func key(_ offset: Int) -> String {
            formatter.string(from: calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date())
        }
        var cursor = learnedDays.contains(key(0)) ? 0 : 1
        guard learnedDays.contains(key(cursor)) else { return 0 }
        var count = 0
        while learnedDays.contains(key(cursor)) {
            count += 1
            cursor += 1
            if cursor > 3_650 { break }
        }
        return count
    }

    var learnedCount: Int { learned.count }

    func totalWords(for language: WordLanguage) -> Int { WordPacks.pack(for: language).count }

    private func persist() {
        store.save(Model(learned: Array(learned).sorted(), learnedDays: Array(learnedDays).sorted()))
    }

    func flush() {
        store.saveNow(Model(learned: Array(learned).sorted(), learnedDays: Array(learnedDays).sorted()))
    }

    // MARK: - Speech

    /// Held for the lifetime of the app rather than created per utterance:
    /// `AVSpeechSynthesizer` deallocated mid-speech simply stops, and a local
    /// variable in a button action is deallocated immediately.
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ entry: WordEntry) {
        let utterance = AVSpeechUtterance(string: entry.term)
        utterance.voice = AVSpeechSynthesisVoice(language: entry.language.speechLocale)
        // Slightly under normal pace: this is a word being taught, not read out.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}
