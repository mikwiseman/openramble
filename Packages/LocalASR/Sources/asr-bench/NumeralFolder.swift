import Foundation

/// Свёртка числительных к цифрам — русских и английских.
///
/// Нужна, чтобы оценка качества не врала. Эталон записан словами («сто двадцать
/// восемь мегабайт»), а модель может вернуть цифры («128 мегабайт») — или
/// наоборот. Без свёртки такое совпадение считалось бы двумя ошибками, и цифра
/// WER перестала бы что-либо значить.
///
/// Свёртка идёт в **цифры**, а не в слова, специально: русский склоняет
/// числительное и меняет его род («двадцать пятого», «двадцать пятое»,
/// «двадцать пять»), поэтому единственная устойчивая форма — число.
///
/// Чего свёртка не делает: не угадывает незнакомые формы. Всё, что не нашлось в
/// таблице форм, остаётся словом и честно считается ошибкой при сравнении.
enum NumeralFolder {
    /// Что означает отдельное слово внутри числового отрезка.
    private enum Piece {
        /// Обычное слагаемое: «двадцать» → 20.
        case value(Double)
        /// Множитель разряда: «тысяча» → ×1000 для всего, что накопилось слева.
        case scale(Double)
        /// Английское `hundred`: умножает то, что стоит слева, а не складывается.
        case multiplier(Double)
        /// Дробная половина: «с половиной», «and a half».
        case half
        /// Десятичная точка: «два точка ноль один».
        case point
        /// Слово-связка внутри числа: «и», «and», «a».
        case filler
    }

    /// Свернуть все числительные в строке к цифрам.
    ///
    /// Вход уже нормализован: нижний регистр, «ё» приведена к «е»,
    /// пунктуация отделена от слов.
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
                    // Кусок не сложился в число — возвращаем слово как было.
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

    /// Свести «с половиной» и «and a half» к одному слову.
    ///
    /// Иначе предлог «с» пришлось бы считать служебным всегда, и «три с утра»
    /// потеряло бы предлог.
    private static func collapseHalves(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            let rest = words[index...]
            if rest.starts(with: ["с", "половиной"]) || rest.starts(with: ["and", "a", "half"]) {
                result.append(halfMarker)
                index += rest.starts(with: ["с", "половиной"]) ? 2 : 3
                continue
            }
            result.append(words[index])
            index += 1
        }
        return result
    }

    /// Отдельный символ вместо слова: в тексте он встретиться не может.
    private static let halfMarker = "\u{1}половина"

    /// Цифровая запись: «128», «4.5», «4,5», «25-е», «10-я».
    ///
    /// Наращение падежного окончания через дефис — обычная запись порядкового
    /// числительного. Модель пишет «10-я мысль» там, где сказано «десятая
    /// мысль»; без разбора этой формы каждое такое место давало бы лишнее «я».
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
        // «and» склеивает разряды только после сотни или тысячи:
        // «three hundred and twenty one» — число, «two and three» — нет.
        if word == "and", let last = run.last, isScaleLike(last) { return .filler }
        return nil
    }

    private static func isScaleLike(_ piece: Piece) -> Bool {
        switch piece {
        case .scale, .multiplier: return true
        default: return false
        }
    }

    /// Сложить в число самое длинное начало отрезка.
    ///
    /// Возвращает число и сколько слов оно съело. `nil` — если начало вообще не
    /// число: например, «с» без «половиной» после него.
    ///
    /// Прочитанное отдаётся кусками, а не целиком, потому что подряд идущие
    /// числительные не всегда одно число: «четырнадцать тридцать» — это время,
    /// два числа, а не сорок четыре.
    private static func combinePrefix(_ pieces: [Piece]) -> (value: Double, consumed: Int)? {
        var total: Double = 0
        var current: Double = 0
        var sawNumber = false
        var fraction: Double = 0
        var decimalDigits: String?
        var lastAdded: Double = .infinity
        var consumed = 0
        /// Сколько слов входит в законченное число: хвостовые служебные слова
        /// («точка» без цифр, «and» без продолжения) в него не входят.
        var complete = 0

        loop: for piece in pieces {
            switch piece {
            case let .value(value):
                if decimalDigits != nil {
                    // После «точка» числительные читаются как цифры подряд:
                    // «два точка ноль один» → 2.01.
                    guard value == value.rounded(), value >= 0, value < 100 else { break loop }
                    decimalDigits! += String(Int(value))
                } else {
                    // Слагаемые обязаны убывать: «сто двадцать восемь» — одно
                    // число, а «четырнадцать тридцать» — время, то есть два.
                    // Без этого правила 14:30 превращалось бы в 44.
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

    // MARK: - Формы

    /// Слагаемые. Формы перечислены явно, а не выводятся по основе: «сто» и
    /// «стол» отличаются одной буквой, и угадывание превратило бы стол в сотню.
    private static let cardinals: [String: Double] = {
        var table: [String: Double] = [:]
        func put(_ value: Double, _ forms: String) {
            for form in forms.split(separator: " ") { table[String(form)] = value }
        }

        put(0, "ноль нуль нуля нулю нолем нулем нулевой нулевая нулевое нулевого zero")
        put(1, """
            один одна одно одного одному одним одном одной одну \
            первый первая первое первого первому первым первых первой первую \
            one first
            """)
        put(2, """
            два две двух двум двумя втором второй вторая второе второго второму вторых вторую \
            two second
            """)
        put(3, "три трех трем тремя третий третья третье третьего третьему третьих третью three third")
        put(4, """
            четыре четырех четырем четырьмя \
            четвертый четвертая четвертое четвертого четвертому четвертых четвертую \
            four fourth
            """)
        put(5, "пять пяти пятью пятый пятая пятое пятого пятому пятых пятую five fifth")
        put(6, "шесть шести шестью шестой шестая шестое шестого шестому шестых шестую six sixth")
        put(7, "семь семи семью седьмой седьмая седьмое седьмого седьмому седьмых седьмую seven seventh")
        put(8, "восемь восьми восемью восьмью восьмой восьмая восьмое восьмого восьмых восьмую eight eighth")
        put(9, "девять девяти девятью девятый девятая девятое девятого девятых девятую nine ninth")
        put(10, "десять десяти десятью десятый десятая десятое десятого десятых десятую ten tenth")
        put(11, "одиннадцать одиннадцати одиннадцатый одиннадцатая одиннадцатое одиннадцатого eleven eleventh")
        put(12, "двенадцать двенадцати двенадцатый двенадцатая двенадцатое двенадцатого twelve twelfth")
        put(13, "тринадцать тринадцати тринадцатый тринадцатая тринадцатое тринадцатого thirteen thirteenth")
        put(14, """
            четырнадцать четырнадцати четырнадцатый четырнадцатая четырнадцатое четырнадцатого \
            fourteen fourteenth
            """)
        put(15, "пятнадцать пятнадцати пятнадцатый пятнадцатая пятнадцатое пятнадцатого fifteen fifteenth")
        put(16, """
            шестнадцать шестнадцати шестнадцатый шестнадцатая шестнадцатое шестнадцатого \
            sixteen sixteenth
            """)
        put(17, "семнадцать семнадцати семнадцатый семнадцатая семнадцатое семнадцатого seventeen seventeenth")
        put(18, """
            восемнадцать восемнадцати восемнадцатый восемнадцатая восемнадцатое восемнадцатого \
            eighteen eighteenth
            """)
        put(19, """
            девятнадцать девятнадцати девятнадцатый девятнадцатая девятнадцатое девятнадцатого \
            nineteen nineteenth
            """)
        put(20, "двадцать двадцати двадцатый двадцатая двадцатое двадцатого twenty twentieth")
        put(30, "тридцать тридцати тридцатый тридцатая тридцатое тридцатого thirty thirtieth")
        put(40, "сорок сорока сороковой сороковая сороковое сорокового forty fortieth")
        put(50, "пятьдесят пятидесяти пятидесятый пятидесятая пятидесятое пятидесятого fifty fiftieth")
        put(60, "шестьдесят шестидесяти шестидесятый шестидесятая шестидесятое шестидесятого sixty sixtieth")
        put(70, "семьдесят семидесяти семидесятый семидесятая семидесятое семидесятого seventy seventieth")
        put(80, """
            восемьдесят восьмидесяти восьмидесятый восьмидесятая восьмидесятое восьмидесятого \
            eighty eightieth
            """)
        put(90, "девяносто девяноста девяностый девяностая девяностое девяностого ninety ninetieth")
        put(100, "сто ста сотый сотая сотое сотого")
        put(200, "двести двухсот двумстам двухсотый двухсотая")
        put(300, "триста трехсот трехсотый трехсотая")
        put(400, "четыреста четырехсот четырехсотый")
        put(500, "пятьсот пятисот пятисотый")
        put(600, "шестьсот шестисот шестисотый")
        put(700, "семьсот семисот семисотый")
        put(800, "восемьсот восьмисот восьмисотый")
        put(900, "девятьсот девятисот девятисотый")
        put(1.5, "полтора полторы полутора")
        return table
    }()

    /// Разряды: умножают всё, что накопилось слева, и закрывают группу.
    private static let scales: [String: Double] = {
        var table: [String: Double] = [:]
        func put(_ value: Double, _ forms: String) {
            for form in forms.split(separator: " ") { table[String(form)] = value }
        }
        put(1_000, "тысяча тысячи тысяч тысяче тысячу тысячей тысячный тысячная тысячного thousand thousandth")
        put(1_000_000, "миллион миллиона миллионов миллиону миллионный миллионная million millionth")
        put(1_000_000_000, "миллиард миллиарда миллиардов миллиардный billion billionth")
        return table
    }()

    /// Английское `hundred` — множитель, а не слагаемое: `three hundred` = 300.
    private static let multipliers: Set<String> = ["hundred", "hundredth"]

    private static let points: Set<String> = ["точка", "запятая", "point"]
}
