import Foundation

/// The target languages the word-of-the-day feature can teach.
///
/// Adding one means adding a case and a pack below. Nothing else in the app
/// knows the list, and the user's selection is stored as raw strings, so a case
/// can be removed later without corrupting anyone's settings.
enum WordLanguage: String, Codable, CaseIterable, Identifiable {
    case spanish, french, german, italian, portuguese, japanese, english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spanish:    return "Spanish"
        case .french:     return "French"
        case .german:     return "German"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese"
        case .japanese:   return "Japanese"
        case .english:    return "English"
        }
    }

    /// Used for the flag-ish badge on the card. A two-letter code rather than an
    /// emoji flag, because a flag is a country and a language is not.
    var code: String {
        switch self {
        case .spanish:    return "ES"
        case .french:     return "FR"
        case .german:     return "DE"
        case .italian:    return "IT"
        case .portuguese: return "PT"
        case .japanese:   return "JA"
        case .english:    return "EN"
        }
    }

    /// Locale identifier for speech synthesis, so "hear it" is pronounced by a
    /// voice that speaks the language rather than an English voice guessing.
    var speechLocale: String {
        switch self {
        case .spanish:    return "es-ES"
        case .french:     return "fr-FR"
        case .german:     return "de-DE"
        case .italian:    return "it-IT"
        case .portuguese: return "pt-BR"
        case .japanese:   return "ja-JP"
        case .english:    return "en-US"
        }
    }
}

struct WordEntry: Codable, Equatable, Identifiable {
    var id: String { "\(language.rawValue).\(term)" }
    let language: WordLanguage
    /// The word as written in the target language.
    let term: String
    /// Romanisation / phonetic hint. Empty where the script is already Latin
    /// and the spelling is a reliable guide.
    let pronunciation: String
    /// Part of speech, kept short: "noun", "verb", "adj".
    let partOfSpeech: String
    let meaning: String
    /// One sentence in the target language...
    let example: String
    /// ...and its translation, because an example you cannot read teaches
    /// nothing.
    let exampleTranslation: String
}

/// Curated word packs, bundled in the binary.
///
/// ## Why these are embedded rather than fetched
/// A word a day is the definition of a feature that must work on a plane. An
/// API-backed version would need a key, a network round trip, a cache, an
/// offline fallback and a privacy story -- to deliver about twelve kilobytes of
/// text per language that never changes. Embedding the text costs the binary
/// less than one app icon.
///
/// The packs are ordered by rough usefulness rather than alphabetically, so a
/// user who only sticks with it for two weeks still learns words they will
/// actually use.
enum WordPacks {

    static func pack(for language: WordLanguage) -> [WordEntry] {
        switch language {
        case .spanish:    return spanish
        case .french:     return french
        case .german:     return german
        case .italian:    return italian
        case .portuguese: return portuguese
        case .japanese:   return japanese
        case .english:    return english
        }
    }

    private static func e(_ language: WordLanguage, _ term: String, _ pronunciation: String,
                          _ partOfSpeech: String, _ meaning: String,
                          _ example: String, _ translation: String) -> WordEntry {
        WordEntry(language: language, term: term, pronunciation: pronunciation,
                  partOfSpeech: partOfSpeech, meaning: meaning,
                  example: example, exampleTranslation: translation)
    }

    // MARK: - Spanish

    static let spanish: [WordEntry] = [
        e(.spanish, "madrugar", "ma-dru-GAR", "verb", "to get up very early",
          "Prefiero madrugar y trabajar en silencio.", "I prefer to get up early and work in silence."),
        e(.spanish, "sobremesa", "so-bre-ME-sa", "noun", "the conversation that lingers after a meal",
          "La sobremesa duró más que la comida.", "The after-dinner talk lasted longer than the meal."),
        e(.spanish, "aprovechar", "a-pro-ve-CHAR", "verb", "to make good use of something",
          "Hay que aprovechar la mañana.", "We should make the most of the morning."),
        e(.spanish, "cotidiano", "co-ti-DIA-no", "adj", "everyday, daily",
          "Es parte de mi rutina cotidiana.", "It is part of my daily routine."),
        e(.spanish, "desarrollar", "de-sa-rro-LLAR", "verb", "to develop, to build out",
          "Estamos desarrollando una aplicación nueva.", "We are developing a new application."),
        e(.spanish, "entrega", "en-TRE-ga", "noun", "delivery; also dedication",
          "La entrega del proyecto es el viernes.", "The project delivery is on Friday."),
        e(.spanish, "ligero", "li-GE-ro", "adj", "light, not heavy",
          "Este programa es muy ligero.", "This program is very lightweight."),
        e(.spanish, "atajo", "a-TA-jo", "noun", "a shortcut",
          "Aprendí un atajo de teclado nuevo.", "I learned a new keyboard shortcut."),
        e(.spanish, "plazo", "PLA-zo", "noun", "deadline, time period",
          "El plazo termina a medianoche.", "The deadline ends at midnight."),
        e(.spanish, "ensayar", "en-sa-YAR", "verb", "to rehearse, to try out",
          "Voy a ensayar la presentación una vez más.", "I am going to rehearse the presentation once more."),
        e(.spanish, "acogedor", "a-co-ge-DOR", "adj", "cosy, welcoming",
          "Su oficina es pequeña pero acogedora.", "Their office is small but cosy."),
        e(.spanish, "rendimiento", "ren-di-MIEN-to", "noun", "performance, output",
          "El rendimiento mejoró mucho.", "The performance improved a lot."),
        e(.spanish, "apagar", "a-pa-GAR", "verb", "to switch off",
          "Apaga la pantalla antes de dormir.", "Turn off the screen before sleeping."),
        e(.spanish, "borrador", "bo-rra-DOR", "noun", "a draft",
          "Solo es un borrador, no lo publiques.", "It is only a draft, do not publish it."),
        e(.spanish, "guardar", "guar-DAR", "verb", "to save, to keep",
          "Recuerda guardar los cambios.", "Remember to save the changes."),
        e(.spanish, "por si acaso", "por si a-CA-so", "phrase", "just in case",
          "Hice una copia por si acaso.", "I made a copy just in case."),
        e(.spanish, "tardar", "tar-DAR", "verb", "to take time, to be late",
          "La compilación tarda dos minutos.", "The build takes two minutes."),
        e(.spanish, "sencillo", "sen-CI-llo", "adj", "simple, straightforward",
          "Busco una solución sencilla.", "I am looking for a simple solution."),
        e(.spanish, "averiguar", "a-ve-ri-GUAR", "verb", "to find out",
          "Tengo que averiguar por qué falla.", "I have to find out why it fails."),
        e(.spanish, "ahorrar", "a-ho-RRAR", "verb", "to save (money, time, energy)",
          "Esto ahorra mucha batería.", "This saves a lot of battery."),
        e(.spanish, "estrenar", "es-tre-NAR", "verb", "to use or wear for the first time",
          "Hoy estreno teclado.", "Today I am using a new keyboard for the first time."),
        e(.spanish, "pendiente", "pen-DIEN-te", "noun/adj", "pending; also a slope",
          "Tengo tres tareas pendientes.", "I have three pending tasks."),
        e(.spanish, "seguimiento", "se-gui-MIEN-to", "noun", "follow-up, tracking",
          "Hago seguimiento de mis hábitos.", "I keep track of my habits."),
        e(.spanish, "desplegar", "des-ple-GAR", "verb", "to deploy, to unfold",
          "Vamos a desplegar la versión nueva.", "We are going to deploy the new version."),
        e(.spanish, "hito", "I-to", "noun", "milestone",
          "Alcanzamos el primer hito.", "We reached the first milestone."),
        e(.spanish, "afinar", "a-fi-NAR", "verb", "to fine-tune",
          "Falta afinar los detalles.", "The details still need fine-tuning."),
        e(.spanish, "respaldo", "res-PAL-do", "noun", "backup, support",
          "Haz un respaldo antes de actualizar.", "Make a backup before updating."),
        e(.spanish, "enfoque", "en-FO-que", "noun", "approach, focus",
          "Me gusta tu enfoque al problema.", "I like your approach to the problem."),
        e(.spanish, "a propósito", "a pro-PÓ-si-to", "phrase", "on purpose; also by the way",
          "Lo dejé así a propósito.", "I left it that way on purpose."),
        e(.spanish, "madrugada", "ma-dru-GA-da", "noun", "the small hours before dawn",
          "Terminé el código de madrugada.", "I finished the code in the small hours.")
    ]

    // MARK: - French

    static let french: [WordEntry] = [
        e(.french, "flâner", "fla-NAY", "verb", "to wander with no destination",
          "J'aime flâner après le travail.", "I like to wander after work."),
        e(.french, "quotidien", "ko-ti-DYAN", "adj/noun", "daily; everyday life",
          "C'est devenu un rituel quotidien.", "It has become a daily ritual."),
        e(.french, "aboutir", "a-boo-TEER", "verb", "to succeed, to come to fruition",
          "Le projet a enfin abouti.", "The project finally came to fruition."),
        e(.french, "brouillon", "broo-YON", "noun", "a rough draft",
          "Ce n'est qu'un brouillon.", "It is only a rough draft."),
        e(.french, "léger", "lay-ZHAY", "adj", "light, lightweight",
          "Ce logiciel est très léger.", "This software is very lightweight."),
        e(.french, "échéance", "ay-shay-AHNS", "noun", "deadline, due date",
          "L'échéance est vendredi soir.", "The deadline is Friday evening."),
        e(.french, "raccourci", "ra-koor-SEE", "noun", "a shortcut",
          "Ce raccourci clavier me fait gagner du temps.", "This keyboard shortcut saves me time."),
        e(.french, "peaufiner", "po-fee-NAY", "verb", "to polish, to fine-tune",
          "Je peaufine les derniers détails.", "I am polishing the last details."),
        e(.french, "enregistrer", "on-re-zhis-TRAY", "verb", "to save, to record",
          "N'oublie pas d'enregistrer.", "Do not forget to save."),
        e(.french, "au cas où", "o ka OO", "phrase", "just in case",
          "J'ai fait une sauvegarde au cas où.", "I made a backup just in case."),
        e(.french, "démarche", "day-MARSH", "noun", "approach, process, step taken",
          "J'apprécie ta démarche.", "I appreciate your approach."),
        e(.french, "veille", "VAY", "noun", "the day before; also standby mode",
          "L'ordinateur est en veille.", "The computer is on standby."),
        e(.french, "soigné", "swa-NYAY", "adj", "neat, carefully done",
          "Une interface soignée fait la différence.", "A carefully-made interface makes the difference."),
        e(.french, "déployer", "day-plwa-YAY", "verb", "to deploy, to roll out",
          "On déploie la nouvelle version demain.", "We are deploying the new version tomorrow."),
        e(.french, "repère", "re-PAIR", "noun", "landmark, reference point",
          "C'est un bon repère pour la suite.", "That is a good reference point going forward."),
        e(.french, "autonomie", "o-to-no-MEE", "noun", "battery life; independence",
          "L'autonomie a doublé.", "The battery life has doubled."),
        e(.french, "aperçu", "a-per-SUU", "noun", "a preview, an overview",
          "Voici un aperçu du résultat.", "Here is a preview of the result."),
        e(.french, "contourner", "kon-toor-NAY", "verb", "to work around, to bypass",
          "On peut contourner le problème.", "We can work around the problem."),
        e(.french, "coup de main", "koo de MAN", "phrase", "a helping hand",
          "Tu me donnes un coup de main ?", "Will you give me a hand?"),
        e(.french, "étape", "ay-TAP", "noun", "step, stage, milestone",
          "Première étape : comprendre le bug.", "First step: understand the bug."),
        e(.french, "allumer", "a-lu-MAY", "verb", "to switch on",
          "Allume l'écran, s'il te plaît.", "Turn on the screen, please."),
        e(.french, "ranger", "ron-ZHAY", "verb", "to tidy, to put away",
          "Je range mon bureau le vendredi.", "I tidy my desk on Fridays."),
        e(.french, "astuce", "as-TUUS", "noun", "a tip, a clever trick",
          "Merci pour l'astuce !", "Thanks for the tip!"),
        e(.french, "relancer", "re-lon-SAY", "verb", "to restart; to follow up",
          "Je vais relancer le serveur.", "I am going to restart the server."),
        e(.french, "en cours", "on KOOR", "phrase", "in progress",
          "Le téléchargement est en cours.", "The download is in progress."),
        e(.french, "faille", "FAI", "noun", "a flaw, a security hole",
          "Ils ont corrigé la faille.", "They fixed the security hole."),
        e(.french, "convivial", "kon-vee-VYAL", "adj", "user-friendly, welcoming",
          "Une interface conviviale.", "A user-friendly interface."),
        e(.french, "sauvegarde", "sov-GARD", "noun", "a backup",
          "La sauvegarde est terminée.", "The backup has finished."),
        e(.french, "mise à jour", "meez a ZHOOR", "noun", "an update",
          "Une mise à jour est disponible.", "An update is available."),
        e(.french, "épuré", "ay-pu-RAY", "adj", "pared back, minimal",
          "Un design épuré et lisible.", "A pared-back, readable design.")
    ]

    // MARK: - German

    static let german: [WordEntry] = [
        e(.german, "Feierabend", "FYE-er-ah-bent", "noun", "the end of the working day, as a state of mind",
          "Ich mache jetzt Feierabend.", "I am finishing work for the day now."),
        e(.german, "Vorhaben", "FOR-hah-ben", "noun", "a plan, an undertaking",
          "Das Vorhaben dauert zwei Wochen.", "The undertaking will take two weeks."),
        e(.german, "übersichtlich", "UU-ber-zicht-lich", "adj", "clear, well laid out",
          "Die Oberfläche ist sehr übersichtlich.", "The interface is very clearly laid out."),
        e(.german, "Entwurf", "ent-VOORF", "noun", "a draft, a design",
          "Das ist nur ein Entwurf.", "That is only a draft."),
        e(.german, "speichern", "SHPY-khern", "verb", "to save",
          "Vergiss nicht zu speichern.", "Do not forget to save."),
        e(.german, "Abkürzung", "AP-kuer-tsung", "noun", "shortcut, abbreviation",
          "Kennst du eine Abkürzung?", "Do you know a shortcut?"),
        e(.german, "Frist", "FRIST", "noun", "deadline",
          "Die Frist läuft heute ab.", "The deadline expires today."),
        e(.german, "sorgfältig", "ZORK-fel-tich", "adj", "careful, thorough",
          "Er arbeitet sehr sorgfältig.", "They work very carefully."),
        e(.german, "Leistung", "LY-stung", "noun", "performance, output",
          "Die Leistung hat sich verdoppelt.", "The performance has doubled."),
        e(.german, "auffallen", "OWF-fal-len", "verb", "to stand out, to be noticeable",
          "Mir ist ein Fehler aufgefallen.", "I noticed a mistake."),
        e(.german, "Sicherung", "ZIH-cher-ung", "noun", "a backup; a fuse",
          "Die Sicherung ist fertig.", "The backup is finished."),
        e(.german, "erledigen", "er-LAY-di-gen", "verb", "to get something done",
          "Ich erledige das noch heute.", "I will get that done today."),
        e(.german, "Vorschau", "FOR-show", "noun", "a preview",
          "Die Vorschau sieht gut aus.", "The preview looks good."),
        e(.german, "schlank", "SHLANK", "adj", "slim, lean",
          "Ein schlankes Programm ohne Ballast.", "A lean program with no bloat."),
        e(.german, "Umgebung", "um-GAY-bung", "noun", "environment, surroundings",
          "Die Entwicklungsumgebung ist eingerichtet.", "The development environment is set up."),
        e(.german, "vermeiden", "fer-MY-den", "verb", "to avoid",
          "Wir wollen Abhängigkeiten vermeiden.", "We want to avoid dependencies."),
        e(.german, "Meilenstein", "MY-len-shtyne", "noun", "milestone",
          "Der erste Meilenstein ist erreicht.", "The first milestone has been reached."),
        e(.german, "ausschalten", "OWS-shal-ten", "verb", "to switch off",
          "Schalte den Bildschirm aus.", "Switch off the screen."),
        e(.german, "Gewohnheit", "ge-VOHN-hyte", "noun", "a habit",
          "Es ist zur Gewohnheit geworden.", "It has become a habit."),
        e(.german, "zuverlässig", "TSOO-fer-les-sich", "adj", "reliable",
          "Ein zuverlässiges Werkzeug.", "A reliable tool."),
        e(.german, "Aufwand", "OWF-vant", "noun", "effort, expenditure",
          "Der Aufwand lohnt sich.", "The effort is worth it."),
        e(.german, "einrichten", "INE-rich-ten", "verb", "to set up, to configure",
          "Ich richte den Server ein.", "I am setting up the server."),
        e(.german, "Kleinigkeit", "KLY-nich-kyte", "noun", "a small thing, a trifle",
          "Das ist nur eine Kleinigkeit.", "That is only a small thing."),
        e(.german, "nachhaltig", "NAKH-hal-tich", "adj", "sustainable, lasting",
          "Eine nachhaltige Lösung.", "A sustainable solution."),
        e(.german, "Bildschirm", "BILT-shirm", "noun", "screen, display",
          "Mein Bildschirm ist zu hell.", "My screen is too bright."),
        e(.german, "verschieben", "fer-SHEE-ben", "verb", "to postpone; to move",
          "Wir verschieben das Treffen.", "We are postponing the meeting."),
        e(.german, "Rückmeldung", "RUEK-mel-dung", "noun", "feedback, a reply",
          "Danke für die schnelle Rückmeldung.", "Thanks for the quick feedback."),
        e(.german, "gründlich", "GRUEND-lich", "adj", "thorough",
          "Wir haben gründlich getestet.", "We tested thoroughly."),
        e(.german, "Ablauf", "AP-lowf", "noun", "sequence, procedure; expiry",
          "Der Ablauf ist automatisiert.", "The procedure is automated."),
        e(.german, "Zwischenstand", "TSVI-shen-shtant", "noun", "interim status, current score",
          "Wie ist der Zwischenstand?", "What is the current status?")
    ]

    // MARK: - Italian

    static let italian: [WordEntry] = [
        e(.italian, "magari", "ma-GA-ri", "adv", "maybe; if only",
          "Magari domani finisco.", "Maybe I will finish tomorrow."),
        e(.italian, "quotidiano", "kwo-ti-DIA-no", "adj", "daily",
          "È il mio rituale quotidiano.", "It is my daily ritual."),
        e(.italian, "bozza", "BOT-tsa", "noun", "a draft",
          "È solo una bozza.", "It is only a draft."),
        e(.italian, "salvare", "sal-VA-re", "verb", "to save",
          "Ricordati di salvare.", "Remember to save."),
        e(.italian, "scorciatoia", "skor-cha-TO-ya", "noun", "a shortcut",
          "Ho imparato una scorciatoia utile.", "I learned a useful shortcut."),
        e(.italian, "scadenza", "ska-DEN-tsa", "noun", "deadline, expiry",
          "La scadenza è venerdì.", "The deadline is Friday."),
        e(.italian, "leggero", "led-JE-ro", "adj", "light, lightweight",
          "Un'app leggera e veloce.", "A light, fast app."),
        e(.italian, "rendimento", "ren-di-MEN-to", "noun", "performance",
          "Il rendimento è migliorato.", "The performance has improved."),
        e(.italian, "accorgersi", "ak-KOR-jer-si", "verb", "to notice, to realise",
          "Mi sono accorto dell'errore.", "I noticed the mistake."),
        e(.italian, "sfruttare", "sfrut-TA-re", "verb", "to make the most of",
          "Sfruttiamo bene la mattina.", "Let us make good use of the morning."),
        e(.italian, "anteprima", "an-te-PRI-ma", "noun", "preview",
          "Guarda l'anteprima prima di pubblicare.", "Look at the preview before publishing."),
        e(.italian, "impostare", "im-po-STA-re", "verb", "to set up, to configure",
          "Devo impostare il server.", "I need to set up the server."),
        e(.italian, "traguardo", "tra-GWAR-do", "noun", "milestone, finish line",
          "Abbiamo raggiunto il primo traguardo.", "We reached the first milestone."),
        e(.italian, "spegnere", "SPE-nye-re", "verb", "to switch off",
          "Spegni lo schermo.", "Turn off the screen."),
        e(.italian, "abitudine", "a-bi-TU-di-ne", "noun", "a habit",
          "È diventata un'abitudine.", "It has become a habit."),
        e(.italian, "affidabile", "af-fi-DA-bi-le", "adj", "reliable",
          "Uno strumento affidabile.", "A reliable tool."),
        e(.italian, "rimandare", "ri-man-DA-re", "verb", "to postpone",
          "Rimandiamo la riunione.", "Let us postpone the meeting."),
        e(.italian, "curato", "ku-RA-to", "adj", "well-crafted, polished",
          "Un design molto curato.", "A very polished design."),
        e(.italian, "riscontro", "ri-SKON-tro", "noun", "feedback, response",
          "Grazie per il riscontro rapido.", "Thanks for the quick feedback."),
        e(.italian, "risparmiare", "ris-par-MYA-re", "verb", "to save (money, time)",
          "Così risparmiamo batteria.", "This way we save battery."),
        e(.italian, "aggiornamento", "ad-jor-na-MEN-to", "noun", "an update",
          "C'è un aggiornamento disponibile.", "There is an update available."),
        e(.italian, "backup", "BE-kap", "noun", "a backup",
          "Il backup è completato.", "The backup is complete."),
        e(.italian, "ingombrante", "in-gom-BRAN-te", "adj", "bulky, cumbersome",
          "Un'interfaccia ingombrante.", "A cumbersome interface."),
        e(.italian, "approfondire", "ap-pro-fon-DI-re", "verb", "to look into more deeply",
          "Voglio approfondire l'argomento.", "I want to look into the subject more deeply."),
        e(.italian, "in corso", "in KOR-so", "phrase", "in progress",
          "Il download è in corso.", "The download is in progress."),
        e(.italian, "svolta", "SVOL-ta", "noun", "a turning point",
          "È stata una svolta per il progetto.", "It was a turning point for the project."),
        e(.italian, "sfondo", "SFON-do", "noun", "background",
          "Gira in sfondo senza disturbare.", "It runs in the background without bothering you."),
        e(.italian, "compito", "KOM-pi-to", "noun", "a task",
          "Ho tre compiti da finire.", "I have three tasks to finish."),
        e(.italian, "collaudo", "kol-LAU-do", "noun", "testing, trial run",
          "Il collaudo è andato bene.", "The trial run went well."),
        e(.italian, "sottile", "sot-TI-le", "adj", "subtle, thin",
          "Una differenza sottile ma importante.", "A subtle but important difference.")
    ]

    // MARK: - Portuguese

    static let portuguese: [WordEntry] = [
        e(.portuguese, "saudade", "sau-DA-de", "noun", "a fond longing for something absent",
          "Sinto saudade daquele projeto.", "I feel a longing for that project."),
        e(.portuguese, "cotidiano", "co-ti-di-A-no", "adj/noun", "daily; everyday life",
          "Faz parte do meu cotidiano.", "It is part of my everyday life."),
        e(.portuguese, "rascunho", "has-KU-nyo", "noun", "a draft",
          "É apenas um rascunho.", "It is only a draft."),
        e(.portuguese, "salvar", "sal-VAR", "verb", "to save",
          "Lembre-se de salvar o arquivo.", "Remember to save the file."),
        e(.portuguese, "atalho", "a-TA-lyo", "noun", "a shortcut",
          "Aprendi um atalho novo.", "I learned a new shortcut."),
        e(.portuguese, "prazo", "PRA-zo", "noun", "deadline",
          "O prazo termina sexta.", "The deadline ends on Friday."),
        e(.portuguese, "leve", "LE-ve", "adj", "light, lightweight",
          "Um aplicativo leve e rápido.", "A light, fast application."),
        e(.portuguese, "desempenho", "de-zem-PE-nyo", "noun", "performance",
          "O desempenho melhorou muito.", "The performance improved a lot."),
        e(.portuguese, "perceber", "per-se-BER", "verb", "to notice, to realise",
          "Percebi o erro tarde demais.", "I noticed the mistake too late."),
        e(.portuguese, "aproveitar", "a-pro-vay-TAR", "verb", "to make the most of",
          "Vamos aproveitar a manhã.", "Let us make the most of the morning."),
        e(.portuguese, "prévia", "PRE-vya", "noun", "a preview",
          "Veja a prévia antes de publicar.", "Look at the preview before publishing."),
        e(.portuguese, "configurar", "con-fi-gu-RAR", "verb", "to set up",
          "Preciso configurar o servidor.", "I need to set up the server."),
        e(.portuguese, "marco", "MAR-co", "noun", "milestone",
          "Atingimos o primeiro marco.", "We reached the first milestone."),
        e(.portuguese, "desligar", "dez-li-GAR", "verb", "to switch off",
          "Desligue a tela antes de dormir.", "Turn off the screen before sleeping."),
        e(.portuguese, "hábito", "A-bi-to", "noun", "a habit",
          "Virou um hábito diário.", "It became a daily habit."),
        e(.portuguese, "confiável", "con-fi-A-vel", "adj", "reliable",
          "Uma ferramenta confiável.", "A reliable tool."),
        e(.portuguese, "adiar", "a-di-AR", "verb", "to postpone",
          "Vamos adiar a reunião.", "Let us postpone the meeting."),
        e(.portuguese, "caprichado", "ca-pri-SHA-do", "adj", "carefully done, polished",
          "Um design bem caprichado.", "A nicely polished design."),
        e(.portuguese, "retorno", "he-TOR-no", "noun", "feedback, a return",
          "Obrigado pelo retorno rápido.", "Thanks for the quick feedback."),
        e(.portuguese, "economizar", "e-co-no-mi-ZAR", "verb", "to save, to economise",
          "Isso economiza bateria.", "That saves battery."),
        e(.portuguese, "atualização", "a-tu-a-li-za-SAUN", "noun", "an update",
          "Há uma atualização disponível.", "There is an update available."),
        e(.portuguese, "cópia de segurança", "CO-pya de se-gu-RAN-sa", "noun", "a backup",
          "Faça uma cópia de segurança.", "Make a backup."),
        e(.portuguese, "enxuto", "en-SHU-to", "adj", "lean, trimmed down",
          "Um código enxuto e legível.", "Lean, readable code."),
        e(.portuguese, "aprofundar", "a-pro-fun-DAR", "verb", "to go deeper into",
          "Quero aprofundar esse tema.", "I want to go deeper into this topic."),
        e(.portuguese, "em andamento", "en an-da-MEN-to", "phrase", "in progress",
          "O download está em andamento.", "The download is in progress."),
        e(.portuguese, "virada", "vi-RA-da", "noun", "a turning point",
          "Foi a virada do projeto.", "It was the project's turning point."),
        e(.portuguese, "plano de fundo", "PLA-no de FUN-do", "noun", "background",
          "Roda em plano de fundo.", "It runs in the background."),
        e(.portuguese, "tarefa", "ta-RE-fa", "noun", "a task",
          "Tenho três tarefas pendentes.", "I have three pending tasks."),
        e(.portuguese, "teste", "TES-te", "noun", "a test",
          "O teste passou sem erros.", "The test passed with no errors."),
        e(.portuguese, "sutil", "su-TIL", "adj", "subtle",
          "Uma diferença sutil mas importante.", "A subtle but important difference.")
    ]

    // MARK: - Japanese

    static let japanese: [WordEntry] = [
        e(.japanese, "木漏れ日", "komorebi", "noun", "sunlight filtering through leaves",
          "木漏れ日がきれいですね。", "The sunlight through the leaves is beautiful."),
        e(.japanese, "毎日", "mainichi", "noun/adv", "every day",
          "毎日少しずつ練習します。", "I practise a little every day."),
        e(.japanese, "下書き", "shitagaki", "noun", "a draft",
          "これはまだ下書きです。", "This is still a draft."),
        e(.japanese, "保存", "hozon", "noun/verb", "saving, preservation",
          "作業を保存してください。", "Please save your work."),
        e(.japanese, "近道", "chikamichi", "noun", "a shortcut",
          "いい近道を見つけました。", "I found a good shortcut."),
        e(.japanese, "締め切り", "shimekiri", "noun", "deadline",
          "締め切りは金曜日です。", "The deadline is Friday."),
        e(.japanese, "軽い", "karui", "adj", "light, lightweight",
          "このアプリは軽いです。", "This app is lightweight."),
        e(.japanese, "性能", "seinou", "noun", "performance, capability",
          "性能が上がりました。", "The performance has improved."),
        e(.japanese, "気づく", "kizuku", "verb", "to notice",
          "間違いに気づきました。", "I noticed the mistake."),
        e(.japanese, "習慣", "shuukan", "noun", "a habit, a custom",
          "それは私の習慣になりました。", "That has become my habit."),
        e(.japanese, "設定", "settei", "noun/verb", "settings, configuration",
          "設定を変えました。", "I changed the settings."),
        e(.japanese, "節目", "fushime", "noun", "a milestone, a turning point",
          "大きな節目を迎えました。", "We have reached a major milestone."),
        e(.japanese, "消す", "kesu", "verb", "to turn off, to erase",
          "画面を消してください。", "Please turn off the screen."),
        e(.japanese, "信頼", "shinrai", "noun", "trust, reliability",
          "信頼できる道具です。", "It is a tool you can trust."),
        e(.japanese, "延期", "enki", "noun/verb", "postponement",
          "会議を延期しました。", "We postponed the meeting."),
        e(.japanese, "丁寧", "teinei", "adj", "careful, polite, thorough",
          "丁寧に作られた画面です。", "It is a carefully made screen."),
        e(.japanese, "感想", "kansou", "noun", "impressions, feedback",
          "感想を聞かせてください。", "Please tell me your impressions."),
        e(.japanese, "節約", "setsuyaku", "noun/verb", "saving, economising",
          "電池を節約できます。", "It can save battery."),
        e(.japanese, "更新", "koushin", "noun/verb", "update, renewal",
          "更新が届いています。", "An update has arrived."),
        e(.japanese, "背景", "haikei", "noun", "background",
          "背景で静かに動きます。", "It runs quietly in the background."),
        e(.japanese, "作業", "sagyou", "noun", "work, a task",
          "作業に集中しています。", "I am concentrating on the task."),
        e(.japanese, "試す", "tamesu", "verb", "to try, to test",
          "新しい方法を試します。", "I will try a new method."),
        e(.japanese, "微妙", "bimyou", "adj", "subtle; also iffy",
          "微妙な違いがあります。", "There is a subtle difference."),
        e(.japanese, "片付ける", "katazukeru", "verb", "to tidy up, to clear away",
          "机を片付けました。", "I tidied my desk."),
        e(.japanese, "続ける", "tsuzukeru", "verb", "to continue, to keep doing",
          "毎日続けることが大事です。", "Continuing every day is what matters."),
        e(.japanese, "余裕", "yoyuu", "noun", "room to spare, composure",
          "時間に余裕があります。", "There is time to spare."),
        e(.japanese, "本番", "honban", "noun", "production, the real thing",
          "本番に反映しました。", "I pushed it to production."),
        e(.japanese, "確認", "kakunin", "noun/verb", "confirmation, checking",
          "もう一度確認します。", "I will check once more."),
        e(.japanese, "静か", "shizuka", "adj", "quiet",
          "静かな作業環境が好きです。", "I like a quiet working environment."),
        e(.japanese, "一段落", "ichidanraku", "noun", "a natural stopping point",
          "作業が一段落しました。", "The work has reached a stopping point.")
    ]

    // MARK: - English

    static let english: [WordEntry] = [
        e(.english, "yak shaving", "", "phrase", "a chain of small tasks needed before the real one",
          "Adding the icon turned into three hours of yak shaving.",
          "The real task keeps receding behind its prerequisites."),
        e(.english, "sonder", "SON-der", "noun", "the realisation that every passer-by has a life as vivid as yours",
          "The café at rush hour is a good place for sonder.",
          "A coined word, but a useful one."),
        e(.english, "bikeshedding", "", "verb", "arguing over the trivial part of a decision",
          "We spent the review bikeshedding the button colour.",
          "From Parkinson's observation about a nuclear plant and a bike shed."),
        e(.english, "laconic", "luh-KON-ik", "adj", "using very few words",
          "Her code reviews are laconic but never unclear.",
          "From Laconia, whose people were famously terse."),
        e(.english, "ossify", "OSS-i-fy", "verb", "to harden into a rigid form",
          "The workaround ossified into the architecture.",
          "Literally, to turn into bone."),
        e(.english, "desultory", "DES-ul-tor-ee", "adj", "jumping from one thing to another without purpose",
          "A desultory afternoon of half-finished branches.",
          "Not the same as 'lazy' — it is about lack of thread."),
        e(.english, "perfunctory", "per-FUNK-tor-ee", "adj", "done as a formality, without care",
          "A perfunctory test that asserts nothing.",
          "The opposite of thorough."),
        e(.english, "elide", "ee-LYDE", "verb", "to omit, to slur over",
          "The summary elides the part where it failed.",
          "Common in both speech and writing."),
        e(.english, "apposite", "AP-uh-zit", "adj", "strikingly appropriate",
          "An apposite example, not just a relevant one.",
          "Not to be confused with 'opposite'."),
        e(.english, "quotidian", "kwo-TID-ee-an", "adj", "daily; ordinary to the point of dullness",
          "The quotidian work is what actually ships.",
          "Shares a root with Spanish 'cotidiano'."),
        e(.english, "obviate", "OB-vee-ate", "verb", "to remove the need for",
          "Caching obviates the second request.",
          "Stronger than 'reduces' — it removes entirely."),
        e(.english, "tractable", "TRAK-tuh-bul", "adj", "easy to manage or solve",
          "Splitting it made the problem tractable.",
          "The opposite is 'intractable'."),
        e(.english, "salient", "SAY-lee-ent", "adj", "most noticeable, most important",
          "The salient point is the memory floor.",
          "Originally 'leaping out'."),
        e(.english, "inveigle", "in-VAY-gul", "verb", "to persuade by flattery or trickery",
          "The dialog inveigles you into enabling it.",
          "Dark-pattern vocabulary."),
        e(.english, "sedulous", "SED-yuh-lus", "adj", "diligent, persistent",
          "Sedulous note-taking saved the migration.",
          "Rarer and warmer than 'diligent'."),
        e(.english, "gravamen", "gruh-VAY-men", "noun", "the essential grievance of a complaint",
          "The gravamen of the report is the idle CPU cost.",
          "Legal in origin, useful in reviews."),
        e(.english, "limn", "LIM", "verb", "to describe or depict in outline",
          "The ADR limns the trade-off without settling it.",
          "The 'b' is silent, as is the 'n' in the noun form."),
        e(.english, "recrudesce", "ree-kroo-DESS", "verb", "to break out again after a lull",
          "The race condition recrudesced under load.",
          "Originally medical."),
        e(.english, "sinecure", "SY-neh-kyoor", "noun", "a position with pay and no real duties",
          "The maintainer role became a sinecure.",
          "Literally 'without care'."),
        e(.english, "propinquity", "pro-PIN-kwi-tee", "noun", "nearness in place or time",
          "The propinquity of the two calls hid the bug.",
          "Also used of kinship."),
        e(.english, "welter", "WEL-ter", "noun", "a confused mass",
          "A welter of config files with no owner.",
          "Also a verb: to roll about."),
        e(.english, "anodyne", "AN-uh-dyne", "adj", "inoffensive to the point of being bland",
          "An anodyne release note that says nothing.",
          "Originally a painkiller."),
        e(.english, "abstruse", "ab-STROOS", "adj", "hard to understand",
          "An abstruse error message helps nobody.",
          "Not a compliment."),
        e(.english, "germane", "jer-MAYN", "adj", "relevant to the matter at hand",
          "That benchmark is not germane to idle cost.",
          "Shakespeare's coinage in this sense."),
        e(.english, "lodestar", "LODE-star", "noun", "a guiding principle",
          "Idle cost is the lodestar for every decision here.",
          "Literally the star you navigate by."),
        e(.english, "palimpsest", "PAL-imp-sest", "noun", "something reused, with traces of its earlier form",
          "The codebase is a palimpsest of three rewrites.",
          "From scraped-and-rewritten manuscripts."),
        e(.english, "vitiate", "VISH-ee-ate", "verb", "to spoil or weaken the effect of",
          "One unguarded write vitiates the whole benchmark.",
          "Stronger than 'undermine'."),
        e(.english, "ambit", "AM-bit", "noun", "the scope or extent of something",
          "That is outside the ambit of this release.",
          "Useful where 'scope' has been worn out."),
        e(.english, "cavil", "KAV-il", "verb", "to raise trivial objections",
          "I will not cavil over the naming.",
          "Rhymes with 'travel'."),
        e(.english, "susurrus", "soo-SUR-us", "noun", "a whispering or rustling sound",
          "The susurrus of a fan that should not be spinning.",
          "Onomatopoeic in Latin too.")
    ]
}
