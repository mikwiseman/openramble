import Foundation

/// Convolution of numerals to numbers - Russian and English.
///
/// It is necessary that the quality assessment does not lie. The standard is written in words (“one hundred twenty
/// eight megabytes"), and the model can return numbers ("128 megabytes") - or
/// vice versa. Without convolution, such a match would be considered two errors, and the figure
/// WER would cease to mean anything.
///
/// The convolution is in **numbers**, and not in words, specially: Russian declines
/// numeral and changes its gender (“twenty-fifth”, “twenty-fifth”,
/// “twenty-five”), so the only stable form is number.
///
/// What convolution doesn't do: it doesn't guess unfamiliar shapes. Everything that was not found in
/// table of forms, remains a word and is honestly considered an error when compared.
enum NumeralFolder {
    /// What does a single word inside a number line mean.
    private enum Piece {
        /// Common term: “twenty” → 20.
        case value(Double)
        /// Place multiplier: “thousand” → ×1000 for everything that has accumulated on the left.
        case scale(Double)
        /// English `hundred`: multiplies what is on the left, rather than adding it.
        case multiplier(Double)
        /// Fractional half: “and a half”, “and a half”.
        case half
        /// Decimal point: “two dot zero one.”
        case point
        /// Linking word inside a number: “and”, “and”, “a”.
        case filler
    }

    /// Collapse all numerals in a line to digits.
    ///
    /// The input is already normalized: lower case and Russian yo is folded to ye,
    /// Punctuation is separated from words.
    static func fold(_ words: [String]) -> [String] {
        let prepared = collapseHalves(words)
        var result: [String] = []
        var run: [Piece] = []
        var runWords: [String] = []

        func flush() {
            defer {
                run.removeAll()
                runWords.removeAll()
            }
            var offset = 0
            while offset < run.count {
                let rest = Array(run[offset...])
                guard let (value, consumed) = combinePrefix(rest), consumed > 0 else {
                    // The piece did not form a number - return the word as it was.
                    result.append(runWords[offset])
                    offset += 1
                    continue
                }
                result.append(format(value))
                offset += consumed
            }
        }

        for word in prepared {
            if let piece = piece(for: word, run: run) {
                run.append(piece)
                runWords.append(word)
                continue
            }

            flush()
            result.append(word)
        }
        flush()
        return result
    }

    /// Reduce “and a half” and “and a half” to one word.
    ///
    /// Otherwise, the preposition “s” would always have to be considered a service preposition, and “three in the morning”
    /// would lose the pretext.
    private static func collapseHalves(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            let rest = words[index...]
            if rest.starts(with: ["\u{0441}", "\u{043F}\u{043E}\u{043B}\u{043E}\u{0432}\u{0438}\u{043D}\u{043E}\u{0439}"]) || rest.starts(with: ["and", "a", "half"]) {
                result.append(halfMarker)
                index += rest.starts(with: ["\u{0441}", "\u{043F}\u{043E}\u{043B}\u{043E}\u{0432}\u{0438}\u{043D}\u{043E}\u{0439}"]) ? 2 : 3
                continue
            }
            result.append(words[index])
            index += 1
        }
        return result
    }

    /// A separate character instead of a word: it cannot appear in the text.
    private static let halfMarker = "\u{1}\u{043F}\u{043E}\u{043B}\u{043E}\u{0432}\u{0438}\u{043D}\u{0430}"

    /// Digital recording: “128”, “4.5”, “4.5”, “25th”, “10th”.
    ///
    /// Increasing the case ending through a hyphen is the usual notation of ordinal
    /// numeral. The model writes “10th thought” where it says “tenth
    /// thought"; without parsing this form, each such place would give an extra “I”.
    private static func digitValue(_ word: String) -> Double? {
        guard let first = word.first, first.isNumber else { return nil }
        var body = word.replacingOccurrences(of: ",", with: ".")
        if let dash = body.firstIndex(of: "-") {
            let suffix = body[body.index(after: dash)...]
            guard !suffix.isEmpty, suffix.count <= 3, suffix.allSatisfy(\.isLetter) else { return nil }
            body = String(body[..<dash])
        }
        guard body.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Double(body)
    }

    private static func piece(for word: String, run: [Piece]) -> Piece? {
        if let value = digitValue(word) { return .value(value) }
        if let value = cardinals[word] { return .value(value) }
        if let scale = scales[word] { return .scale(scale) }
        if multipliers.contains(word) { return .multiplier(100) }

        let insideRun = !run.isEmpty
        if word == halfMarker { return insideRun ? .half : nil }
        if points.contains(word) { return insideRun ? .point : nil }
        // “and” merges digits only after hundreds or thousands:
        // “three hundred and twenty one” is a number, “two and three” is not.
        if word == "and", let last = run.last, isScaleLike(last) { return .filler }
        return nil
    }

    private static func isScaleLike(_ piece: Piece) -> Bool {
        switch piece {
        case .scale, .multiplier: return true
        default: return false
        }
    }

    /// Add the longest beginning of the segment into a number.
    ///
    /// Returns the number and how many words it ate. `nil` — if there is no beginning at all
    /// number: for example, "with" without "half" after it.
    ///
    /// What is read is given in pieces, and not as a whole, because there are consecutive
    /// numerals are not always one number: “fourteen thirty” is the time
    /// two numbers, not forty-four.
    private static func combinePrefix(_ pieces: [Piece]) -> (value: Double, consumed: Int)? {
        var total: Double = 0
        var current: Double = 0
        var sawNumber = false
        var fraction: Double = 0
        var decimalDigits: String?
        var lastAdded: Double = .infinity
        var consumed = 0
        /// How many words are included in the completed number: tail function words
        /// (“dot” without numbers, “and” without continuation) are not included in it.
        var complete = 0

        loop: for piece in pieces {
            switch piece {
            case let .value(value):
                if decimalDigits != nil {
                    // After the “dot” the numerals are read as numbers in a row:
                    // “two point zero one” → 2.01.
                    guard value == value.rounded(), value >= 0, value < 100 else { break loop }
                    decimalDigits! += String(Int(value))
                } else {
                    // The terms must decrease: “one hundred twenty-eight” is one
                    // number, and “fourteen thirty” is the time, that is, two.
                    // Without this rule, 14:30 would turn into 44.
                    guard current == 0 || value < lastAdded else { break loop }
                    current += value
                    lastAdded = value
                }
                sawNumber = true
                consumed += 1
                complete = consumed
            case let .scale(scale):
                guard decimalDigits == nil else { break loop }
                total += max(current, 1) * scale
                current = 0
                lastAdded = .infinity
                sawNumber = true
                consumed += 1
                complete = consumed
            case let .multiplier(factor):
                guard decimalDigits == nil else { break loop }
                current = max(current, 1) * factor
                lastAdded = .infinity
                sawNumber = true
                consumed += 1
                complete = consumed
            case .half:
                guard sawNumber, fraction == 0 else { break loop }
                fraction = 0.5
                consumed += 1
                complete = consumed
            case .point:
                guard sawNumber, decimalDigits == nil else { break loop }
                decimalDigits = ""
                consumed += 1
            case .filler:
                consumed += 1
            }
        }

        guard sawNumber, complete > 0 else { return nil }

        var value = total + current + fraction
        if let decimalDigits, !decimalDigits.isEmpty {
            guard let tail = Double("0." + decimalDigits) else { return nil }
            value += tail
        }
        return (value, complete)
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%g", value)
    }

    // MARK: - Forms

    /// Addends. The forms are listed explicitly, rather than being derived from the stem: "hundred" and
    /// "table" differ by one letter, and guessing would turn the table into a hundred.
    private static let cardinals: [String: Double] = {
        var table: [String: Double] = [:]
        func put(_ value: Double, _ forms: String) {
            for form in forms.split(separator: " ") { table[String(form)] = value }
        }

        put(0, "\u{043D}\u{043E}\u{043B}\u{044C} \u{043D}\u{0443}\u{043B}\u{044C} \u{043D}\u{0443}\u{043B}\u{044F} \u{043D}\u{0443}\u{043B}\u{044E} \u{043D}\u{043E}\u{043B}\u{0435}\u{043C} \u{043D}\u{0443}\u{043B}\u{0435}\u{043C} \u{043D}\u{0443}\u{043B}\u{0435}\u{0432}\u{043E}\u{0439} \u{043D}\u{0443}\u{043B}\u{0435}\u{0432}\u{0430}\u{044F} \u{043D}\u{0443}\u{043B}\u{0435}\u{0432}\u{043E}\u{0435} \u{043D}\u{0443}\u{043B}\u{0435}\u{0432}\u{043E}\u{0433}\u{043E} zero")
        put(1, """
            \u{043E}\u{0434}\u{0438}\u{043D} \u{043E}\u{0434}\u{043D}\u{0430} \u{043E}\u{0434}\u{043D}\u{043E} \u{043E}\u{0434}\u{043D}\u{043E}\u{0433}\u{043E} \u{043E}\u{0434}\u{043D}\u{043E}\u{043C}\u{0443} \u{043E}\u{0434}\u{043D}\u{0438}\u{043C} \u{043E}\u{0434}\u{043D}\u{043E}\u{043C} \u{043E}\u{0434}\u{043D}\u{043E}\u{0439} \u{043E}\u{0434}\u{043D}\u{0443} \
            \u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{0439} \u{043F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0435} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0433}\u{043E} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{043C}\u{0443} \u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{043C} \u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{0445} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0439} \u{043F}\u{0435}\u{0440}\u{0432}\u{0443}\u{044E} \
            one first
            """)
        put(2, """
            \u{0434}\u{0432}\u{0430} \u{0434}\u{0432}\u{0435} \u{0434}\u{0432}\u{0443}\u{0445} \u{0434}\u{0432}\u{0443}\u{043C} \u{0434}\u{0432}\u{0443}\u{043C}\u{044F} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{043C} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0439} \u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0435} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0433}\u{043E} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{043C}\u{0443} \u{0432}\u{0442}\u{043E}\u{0440}\u{044B}\u{0445} \u{0432}\u{0442}\u{043E}\u{0440}\u{0443}\u{044E} \
            two second
            """)
        put(3, "\u{0442}\u{0440}\u{0438} \u{0442}\u{0440}\u{0435}\u{0445} \u{0442}\u{0440}\u{0435}\u{043C} \u{0442}\u{0440}\u{0435}\u{043C}\u{044F} \u{0442}\u{0440}\u{0435}\u{0442}\u{0438}\u{0439} \u{0442}\u{0440}\u{0435}\u{0442}\u{044C}\u{044F} \u{0442}\u{0440}\u{0435}\u{0442}\u{044C}\u{0435} \u{0442}\u{0440}\u{0435}\u{0442}\u{044C}\u{0435}\u{0433}\u{043E} \u{0442}\u{0440}\u{0435}\u{0442}\u{044C}\u{0435}\u{043C}\u{0443} \u{0442}\u{0440}\u{0435}\u{0442}\u{044C}\u{0438}\u{0445} \u{0442}\u{0440}\u{0435}\u{0442}\u{044C}\u{044E} three third")
        put(4, """
            \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}\u{0445} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}\u{043C} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{044C}\u{043C}\u{044F} \
            \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{044B}\u{0439} \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{0430}\u{044F} \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{043E}\u{0435} \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{043E}\u{0433}\u{043E} \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{043E}\u{043C}\u{0443} \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{044B}\u{0445} \u{0447}\u{0435}\u{0442}\u{0432}\u{0435}\u{0440}\u{0442}\u{0443}\u{044E} \
            four fourth
            """)
        put(5, "\u{043F}\u{044F}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{0438} \u{043F}\u{044F}\u{0442}\u{044C}\u{044E} \u{043F}\u{044F}\u{0442}\u{044B}\u{0439} \u{043F}\u{044F}\u{0442}\u{0430}\u{044F} \u{043F}\u{044F}\u{0442}\u{043E}\u{0435} \u{043F}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} \u{043F}\u{044F}\u{0442}\u{043E}\u{043C}\u{0443} \u{043F}\u{044F}\u{0442}\u{044B}\u{0445} \u{043F}\u{044F}\u{0442}\u{0443}\u{044E} five fifth")
        put(6, "\u{0448}\u{0435}\u{0441}\u{0442}\u{044C} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438} \u{0448}\u{0435}\u{0441}\u{0442}\u{044C}\u{044E} \u{0448}\u{0435}\u{0441}\u{0442}\u{043E}\u{0439} \u{0448}\u{0435}\u{0441}\u{0442}\u{0430}\u{044F} \u{0448}\u{0435}\u{0441}\u{0442}\u{043E}\u{0435} \u{0448}\u{0435}\u{0441}\u{0442}\u{043E}\u{0433}\u{043E} \u{0448}\u{0435}\u{0441}\u{0442}\u{043E}\u{043C}\u{0443} \u{0448}\u{0435}\u{0441}\u{0442}\u{044B}\u{0445} \u{0448}\u{0435}\u{0441}\u{0442}\u{0443}\u{044E} six sixth")
        put(7, "\u{0441}\u{0435}\u{043C}\u{044C} \u{0441}\u{0435}\u{043C}\u{0438} \u{0441}\u{0435}\u{043C}\u{044C}\u{044E} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{043E}\u{0439} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{0430}\u{044F} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{043E}\u{0435} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{043E}\u{0433}\u{043E} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{043E}\u{043C}\u{0443} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{044B}\u{0445} \u{0441}\u{0435}\u{0434}\u{044C}\u{043C}\u{0443}\u{044E} seven seventh")
        put(8, "\u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C}\u{044E} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{044C}\u{044E} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{043E}\u{0439} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0430}\u{044F} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{043E}\u{0435} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{043E}\u{0433}\u{043E} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{044B}\u{0445} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0443}\u{044E} eight eighth")
        put(9, "\u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044C} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{0438} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044C}\u{044E} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044B}\u{0439} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{0430}\u{044F} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043E}\u{0435} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044B}\u{0445} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{0443}\u{044E} nine ninth")
        put(10, "\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044C} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0438} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044C}\u{044E} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044B}\u{0439} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0430}\u{044F} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0435} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044B}\u{0445} \u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0443}\u{044E} ten tenth")
        put(11, "\u{043E}\u{0434}\u{0438}\u{043D}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043E}\u{0434}\u{0438}\u{043D}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{043E}\u{0434}\u{0438}\u{043D}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{043E}\u{0434}\u{0438}\u{043D}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{043E}\u{0434}\u{0438}\u{043D}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{043E}\u{0434}\u{0438}\u{043D}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} eleven eleventh")
        put(12, "\u{0434}\u{0432}\u{0435}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0434}\u{0432}\u{0435}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0434}\u{0432}\u{0435}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0434}\u{0432}\u{0435}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0434}\u{0432}\u{0435}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0434}\u{0432}\u{0435}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} twelve twelfth")
        put(13, "\u{0442}\u{0440}\u{0438}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0442}\u{0440}\u{0438}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0442}\u{0440}\u{0438}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0442}\u{0440}\u{0438}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0442}\u{0440}\u{0438}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0442}\u{0440}\u{0438}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} thirteen thirteenth")
        put(14, """
            \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} \
            fourteen fourteenth
            """)
        put(15, "\u{043F}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{043F}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{043F}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{043F}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{043F}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} fifteen fifteenth")
        put(16, """
            \u{0448}\u{0435}\u{0441}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0448}\u{0435}\u{0441}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0448}\u{0435}\u{0441}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0448}\u{0435}\u{0441}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0448}\u{0435}\u{0441}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0448}\u{0435}\u{0441}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} \
            sixteen sixteenth
            """)
        put(17, "\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} seventeen seventeenth")
        put(18, """
            \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} \
            eighteen eighteenth
            """)
        put(19, """
            \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} \
            nineteen nineteenth
            """)
        put(20, "\u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} twenty twentieth")
        put(30, "\u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{044B}\u{0439} \u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{0430}\u{044F} \u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0435} \u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{043E}\u{0433}\u{043E} thirty thirtieth")
        put(40, "\u{0441}\u{043E}\u{0440}\u{043E}\u{043A} \u{0441}\u{043E}\u{0440}\u{043E}\u{043A}\u{0430} \u{0441}\u{043E}\u{0440}\u{043E}\u{043A}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{043E}\u{0440}\u{043E}\u{043A}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{043E}\u{0440}\u{043E}\u{043A}\u{043E}\u{0432}\u{043E}\u{0435} \u{0441}\u{043E}\u{0440}\u{043E}\u{043A}\u{043E}\u{0432}\u{043E}\u{0433}\u{043E} forty fortieth")
        put(50, "\u{043F}\u{044F}\u{0442}\u{044C}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442} \u{043F}\u{044F}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0438} \u{043F}\u{044F}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044B}\u{0439} \u{043F}\u{044F}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0430}\u{044F} \u{043F}\u{044F}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0435} \u{043F}\u{044F}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} fifty fiftieth")
        put(60, "\u{0448}\u{0435}\u{0441}\u{0442}\u{044C}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0438} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044B}\u{0439} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0430}\u{044F} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0435} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} sixty sixtieth")
        put(70, "\u{0441}\u{0435}\u{043C}\u{044C}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442} \u{0441}\u{0435}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0438} \u{0441}\u{0435}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044B}\u{0439} \u{0441}\u{0435}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0430}\u{044F} \u{0441}\u{0435}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0435} \u{0441}\u{0435}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} seventy seventieth")
        put(80, """
            \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0438} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{044B}\u{0439} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0430}\u{044F} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0435} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E} \
            eighty eightieth
            """)
        put(90, "\u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{043E} \u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{0430} \u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{044B}\u{0439} \u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{0430}\u{044F} \u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{043E}\u{0435} \u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{043E}\u{0433}\u{043E} ninety ninetieth")
        put(100, "\u{0441}\u{0442}\u{043E} \u{0441}\u{0442}\u{0430} \u{0441}\u{043E}\u{0442}\u{044B}\u{0439} \u{0441}\u{043E}\u{0442}\u{0430}\u{044F} \u{0441}\u{043E}\u{0442}\u{043E}\u{0435} \u{0441}\u{043E}\u{0442}\u{043E}\u{0433}\u{043E}")
        put(200, "\u{0434}\u{0432}\u{0435}\u{0441}\u{0442}\u{0438} \u{0434}\u{0432}\u{0443}\u{0445}\u{0441}\u{043E}\u{0442} \u{0434}\u{0432}\u{0443}\u{043C}\u{0441}\u{0442}\u{0430}\u{043C} \u{0434}\u{0432}\u{0443}\u{0445}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439} \u{0434}\u{0432}\u{0443}\u{0445}\u{0441}\u{043E}\u{0442}\u{0430}\u{044F}")
        put(300, "\u{0442}\u{0440}\u{0438}\u{0441}\u{0442}\u{0430} \u{0442}\u{0440}\u{0435}\u{0445}\u{0441}\u{043E}\u{0442} \u{0442}\u{0440}\u{0435}\u{0445}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439} \u{0442}\u{0440}\u{0435}\u{0445}\u{0441}\u{043E}\u{0442}\u{0430}\u{044F}")
        put(400, "\u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}\u{0441}\u{0442}\u{0430} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}\u{0445}\u{0441}\u{043E}\u{0442} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}\u{0445}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439}")
        put(500, "\u{043F}\u{044F}\u{0442}\u{044C}\u{0441}\u{043E}\u{0442} \u{043F}\u{044F}\u{0442}\u{0438}\u{0441}\u{043E}\u{0442} \u{043F}\u{044F}\u{0442}\u{0438}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439}")
        put(600, "\u{0448}\u{0435}\u{0441}\u{0442}\u{044C}\u{0441}\u{043E}\u{0442} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0441}\u{043E}\u{0442} \u{0448}\u{0435}\u{0441}\u{0442}\u{0438}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439}")
        put(700, "\u{0441}\u{0435}\u{043C}\u{044C}\u{0441}\u{043E}\u{0442} \u{0441}\u{0435}\u{043C}\u{0438}\u{0441}\u{043E}\u{0442} \u{0441}\u{0435}\u{043C}\u{0438}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439}")
        put(800, "\u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C}\u{0441}\u{043E}\u{0442} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0441}\u{043E}\u{0442} \u{0432}\u{043E}\u{0441}\u{044C}\u{043C}\u{0438}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439}")
        put(900, "\u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044C}\u{0441}\u{043E}\u{0442} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{0438}\u{0441}\u{043E}\u{0442} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{0438}\u{0441}\u{043E}\u{0442}\u{044B}\u{0439}")
        put(1.5, "\u{043F}\u{043E}\u{043B}\u{0442}\u{043E}\u{0440}\u{0430} \u{043F}\u{043E}\u{043B}\u{0442}\u{043E}\u{0440}\u{044B} \u{043F}\u{043E}\u{043B}\u{0443}\u{0442}\u{043E}\u{0440}\u{0430}")
        return table
    }()

    /// Discharges: multiply everything that has accumulated on the left and close the group.
    private static let scales: [String: Double] = {
        var table: [String: Double] = [:]
        func put(_ value: Double, _ forms: String) {
            for form in forms.split(separator: " ") { table[String(form)] = value }
        }
        put(1_000, "\u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{0430} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{0438} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{0435} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{0443} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{0435}\u{0439} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{043D}\u{044B}\u{0439} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{043D}\u{0430}\u{044F} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{043D}\u{043E}\u{0433}\u{043E} thousand thousandth")
        put(1_000_000, "\u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043E}\u{043D} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043E}\u{043D}\u{0430} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043E}\u{043D}\u{043E}\u{0432} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043E}\u{043D}\u{0443} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043E}\u{043D}\u{043D}\u{044B}\u{0439} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043E}\u{043D}\u{043D}\u{0430}\u{044F} million millionth")
        put(1_000_000_000, "\u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{0430}\u{0440}\u{0434} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{0430}\u{0440}\u{0434}\u{0430} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{0430}\u{0440}\u{0434}\u{043E}\u{0432} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{0430}\u{0440}\u{0434}\u{043D}\u{044B}\u{0439} billion billionth")
        return table
    }()

    /// English `hundred` is a multiplier, not a summand: `three hundred` = 300.
    private static let multipliers: Set<String> = ["hundred", "hundredth"]

    private static let points: Set<String> = ["\u{0442}\u{043E}\u{0447}\u{043A}\u{0430}", "\u{0437}\u{0430}\u{043F}\u{044F}\u{0442}\u{0430}\u{044F}", "point"]
}
