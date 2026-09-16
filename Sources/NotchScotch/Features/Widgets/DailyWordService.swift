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

    /// A word the user has been shown, kept forever.
    ///
    /// The glossary is the point of the feature, not a side effect of it: one
    /// word a day is only worth doing if you can go back and find the one from
    /// last Tuesday. It stores a copy of the term and meaning rather than a
    /// reference into `WordPacks`, so editing or reordering a pack later cannot
    /// orphan someone's history.
    struct SeenWord: Codable, Identifiable, Equatable {
        var id: String { entryID }
        var entryID: String
        var language: String
        var term: String
        var meaning: String
        var firstSeen: Date
        var isLearned: Bool = false

        var languageValue: WordLanguage? { WordLanguage(rawValue: language) }
    }

    private struct Model: Codable {
        /// `WordEntry.id` values the user has ticked off.
        var learned: [String] = []
        /// `yyyy-MM-dd` days on which at least one word was marked learned.
        var learnedDays: [String] = []
        /// Every word ever shown, keyed by entry id.
        var seen: [String: SeenWord] = [:]
    }

    @Published private(set) var learned: Set<String> = []
    @Published private(set) var learnedDays: Set<String> = []
    @Published private(set) var seen: [String: SeenWord] = [:]

    /// Manual step away from today's word, for "show me another".
    ///
    /// Reset at midnight along with `dayStamp`: skipping ahead three words on a
    /// Tuesday should not still be three ahead on Wednesday, or the daily word
    /// stops being daily.
    @Published private(set) var manualOffset: Int = 0
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
        seen = model.seen
    }

    // MARK: - Lifecycle

    /// The only reason this polls at all is the midnight rollover while the
    /// panel is pinned open. Ten minutes is plenty -- being up to ten minutes
    /// late to swap the card at 00:00 is not a defect anyone can perceive.
    func activate() {
        recordToday()
        guard token == nil else { return }
        token = WidgetPollingHub.shared.register(label: "daily-word", interval: 600) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let now = Self.today()
                guard now != self.dayStamp else { return }
                // A new day: new words, and any manual skipping is forgotten.
                self.dayStamp = now
                self.manualOffset = 0
                self.recordToday()
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
        // `%` in Swift keeps the sign of the dividend, so stepping backwards
        // past position zero would index negatively. The extra `+ count` makes
        // the modulo behave the way the maths does.
        let raw = Self.dayNumber(date) + Self.offset(for: language) + manualOffset
        let index = ((raw % pack.count) + pack.count) % pack.count
        return pack[index]
    }

    // MARK: - Stepping

    func nextWord() {
        manualOffset += 1
        recordToday()
    }

    func previousWord() {
        manualOffset -= 1
        recordToday()
    }

    /// Back to the word the day actually calls for.
    func backToToday() {
        guard manualOffset != 0 else { return }
        manualOffset = 0
        recordToday()
    }

    var isShowingToday: Bool { manualOffset == 0 }

    // MARK: - Glossary

    /// Files whatever is currently on screen into the glossary.
    ///
    /// Called on display rather than on some explicit "save" action: the user
    /// asked to be taught a word, they were shown one, and a glossary that only
    /// contains the ones they remembered to press a button on is a worse record
    /// of what they have seen than no glossary at all.
    func recordToday() {
        for entry in todaysWords { record(entry) }
    }

    func record(_ entry: WordEntry) {
        guard seen[entry.id] == nil else { return }
        seen[entry.id] = SeenWord(entryID: entry.id,
                                  language: entry.language.rawValue,
                                  term: entry.term,
                                  meaning: entry.meaning,
                                  firstSeen: Date(),
                                  isLearned: learned.contains(entry.id))
        persist()
    }

    /// The glossary, most recently seen first.
    func glossary(matching query: String = "", language: WordLanguage? = nil) -> [SeenWord] {
        seen.values
            .filter { language == nil || $0.language == language?.rawValue }
            .filter {
                query.isEmpty
                    || $0.term.localizedCaseInsensitiveContains(query)
                    || $0.meaning.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.firstSeen > $1.firstSeen }
    }

    var glossaryCount: Int { seen.count }

    /// Looks a glossary entry back up in its pack, so the detail card can show
    /// the example sentence the summary does not store.
    func entry(for word: SeenWord) -> WordEntry? {
        guard let language = word.languageValue else { return nil }
        return WordPacks.pack(for: language).first { $0.term == word.term }
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
            seen[entry.id]?.isLearned = false
        } else {
            learned.insert(entry.id)
            learnedDays.insert(Self.today())
            record(entry)
            NotchArbiter.shared.flash("Learned", symbol: "checkmark.seal.fill",
                                      module: .notes, detail: entry.term)
            seen[entry.id]?.isLearned = true
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

    private var model: Model {
        Model(learned: Array(learned).sorted(),
              learnedDays: Array(learnedDays).sorted(),
              seen: seen)
    }

    private func persist() { store.save(model) }

    func flush() { store.saveNow(model) }

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
