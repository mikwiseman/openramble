import DictationCore
import Foundation
import XCTest

/// Сквозные тесты диктовки: настоящий звук, настоящая модель, настоящий словарь.
///
/// Каждый слой проверен по отдельности, но стыки между ними — нет. Здесь
/// проверяется ровно то, что нельзя увидеть в тесте одного слоя: доходит ли
/// сказанное от файла до вставки целиком, в правильном виде и без чужих хвостов.
@MainActor
final class DictationEndToEndTests: EndToEndScenario {
    // MARK: - Главный сценарий продукта

    /// Русская фраза с английскими терминами приходит на вставку латиницей.
    ///
    /// Ради этого существует словарь замен: внутри русской фразы модель честно
    /// пишет термин кириллицей — «пул реквест», «продакшн», — а человек ждёт
    /// «pull request» и «production». Проверить это можно только целиком:
    /// отдельно модель права, отдельно словарь работает, а совпасть они обязаны
    /// на одном и том же тексте.
    func testMixedRussianEnglishPhraseArrivesWithLatinTerms() async throws {
        try await speak(Phrase.mixed)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        XCTAssertEqual(texts.count, 1, "Одна диктовка — одна вставка")
        let text = try XCTUnwrap(texts.first)

        for term in Phrase.mixedTerms {
            XCTAssertTrue(
                text.contains(term),
                "Термин «\(term)» обязан прийти латиницей. Пришло: \(text)"
            )
        }

        // Сверяем не только появление латиницы, но и исчезновение кириллицы:
        // замена, добавившая термин рядом со старым написанием, тоже сломана.
        for spoken in ["реквест", "гитхаб", "линтер", "деплой", "продакшн"] {
            XCTAssertFalse(
                text.containsInsensitive(spoken),
                "Кириллическое написание «\(spoken)» осталось в тексте: \(text)"
            )
        }

        // Порядок слов — отдельная проверка: замены идут регулярным выражением
        // по всей строке и переставить куски могли бы незаметно.
        let positions = Phrase.mixedTerms.compactMap { text.position(of: $0) }
        XCTAssertEqual(positions.count, Phrase.mixedTerms.count)
        XCTAssertEqual(positions, positions.sorted(), "Порядок терминов во фразе обязан сохраниться")

        // Длина сравнивается по существу: модель может ошибиться в слове, но не
        // имеет права потерять или удвоить фразу.
        XCTAssertEqual(
            Double(text.wordCount),
            Double(Phrase.mixed.wordCount),
            accuracy: 3,
            "Длина разошлась со сказанным: \(text)"
        )

        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0, "Команды в этой фразе не было")

        // Текст обязан уйти туда, где диктовали, а не туда, где сейчас фокус.
        let target = await inserter.insertions.first?.target
        XCTAssertEqual(target?.bundleIdentifier, "com.apple.TextEdit")

        let starts = await sounds.startPlays
        let stops = await sounds.stopPlays
        XCTAssertEqual([starts, stops], [1, 1], "Звуки начала и конца — по одному разу")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// Термины в косвенных падежах доходят до вставки латиницей.
    ///
    /// «На питоне», «без даунтайма» — именно так человек и говорит, и именно на
    /// этом замена по точному совпадению не срабатывала никогда. Проверяется
    /// сквозным путём, потому что склонение придумывает не тест, а модель.
    func testDeclinedTermsStillReachInsertionInLatin() async throws {
        try await speak(Phrase.declined)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        for term in Phrase.declinedTerms {
            XCTAssertTrue(
                text.contains(term),
                "Термин «\(term)» в косвенном падеже не заменился. Пришло: \(text)"
            )
        }
        for spoken in ["свифт", "билд", "даунтайм"] {
            XCTAssertFalse(
                text.containsInsensitive(spoken),
                "Кириллическое написание «\(spoken)» осталось: \(text)"
            )
        }

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// Обычное русское слово, похожее на термин, словарь не трогает.
    ///
    /// «В центре города» не должно стать «в Sentry города». Замены идут
    /// регулярными выражениями с падежными хвостами, и цена ошибки здесь —
    /// испорченная обычная речь, а не просто незамененный термин.
    func testOrdinaryWordThatLooksLikeATermIsLeftAlone() async throws {
        try await speak(Phrase.falseFriend)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        XCTAssertFalse(text.contains("Sentry"), "Обычное слово подменилось термином: \(text)")
        XCTAssertTrue(text.containsInsensitive("центре"), "Слово из фразы пропало: \(text)")
        XCTAssertTrue(text.containsInsensitive("города"), "Слово из фразы пропало: \(text)")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// Английская речь целиком: словарь её не портит, команда работает.
    func testEnglishDictationWithEnglishTrailingCommand() async throws {
        try await speak(Phrase.englishSend, voice: .english)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        XCTAssertTrue(text.contains("pull request"), "Английская фраза пришла не целиком: \(text)")
        XCTAssertFalse(text.containsInsensitive("send it"), "Команда осталась в тексте: \(text)")

        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 1, "«Send it» — такая же команда, как «отправь»")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// Трёхминутная диктовка доходит целиком, вместе с хвостом.
    ///
    /// Единственное место, где видно молчаливую потерю речи на стыке
    /// пятнадцатисекундных окон движка: конец предложения исчезает без ошибки и
    /// без предупреждения. Ни тест одного слоя, ни короткая запись этого не
    /// поймают — нужна настоящая длинная запись, прошедшая весь путь.
    func testThreeMinuteDictationArrivesWholeWithoutLosingTheTail() async throws {
        try await speak(Phrase.veryLong)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)

        // Абзац произнесён пять раз — все пять обязаны дойти.
        let repeats = text.occurrences(of: "Вечером мы собираем сборку")
        XCTAssertEqual(repeats, 5, "Из пяти повторов дошло \(repeats): текст потерян на стыке окон")

        let expected = Double(Phrase.long.wordCount * 5)
        XCTAssertGreaterThan(
            Double(text.wordCount),
            expected * 0.9,
            "Из \(Int(expected)) слов дошло \(text.wordCount)"
        )

        // Хвост — самое уязвимое место: именно он пропадает молча.
        let tail = String(text.suffix(60))
        XCTAssertTrue(tail.containsInsensitive("заранее"), "Конец записи не дошёл: …\(tail)")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Команда в конце фразы

    /// «Отправь» в конце становится нажатием Return и не остаётся в тексте.
    func testTrailingSendCommandPressesReturnWithoutEatingWords() async throws {
        try await speak(Phrase.send)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 1, "«Отправь» — это действие, а не слово")

        XCTAssertFalse(
            text.containsInsensitive("отправ"),
            "Команда осталась в тексте: \(text)"
        )
        // Главная опасность здесь — срезать вместе с командой соседние слова.
        for word in ["Проверь", "pull request", "пожалуйста"] {
            XCTAssertTrue(text.containsInsensitive(word), "Слово «\(word)» пропало: \(text)")
        }
        XCTAssertFalse(text.hasSuffix(","), "Хвостовая запятая от команды должна уйти: \(text)")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// «Новая строка» уходит в сам текст, а не в нажатие клавиши.
    ///
    /// Нажатием её сделать нельзя: Return в чужом окне отправляет сообщение,
    /// а не переносит строку.
    func testTrailingNewLineCommandGoesIntoTheTextItself() async throws {
        try await speak(Phrase.newLine)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        XCTAssertTrue(text.hasSuffix("\n"), "Перенос обязан быть в самом тексте: \(text.debugDescription)")
        XCTAssertTrue(text.containsInsensitive("мысль"), "Слова из фразы пропали: \(text)")
        XCTAssertFalse(text.containsInsensitive("новая строка"), "Команда осталась в тексте: \(text)")

        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0, "Return отправил бы сообщение вместо переноса строки")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Отмена

    /// Отмена посреди распознавания длинной записи не вставляет ничего.
    ///
    /// Отмена приходит гарантированно после начала распознавания: тридцать
    /// секунд речи движок разбирает за доли секунды, и без этой синхронизации
    /// тест проверял бы отмену ДО распознавания — совсем другой путь.
    func testCancelDuringRealRecognitionInsertsNothing() async throws {
        try await speak(Phrase.long)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitUntil("запись пошла") { controller.state == .listening }
        controller.stop()
        await waitUntil("распознавание началось") { await self.probe.calls == 1 }

        controller.cancel()
        await waitUntil("сессия закрылась") { controller.state == .idle }

        let texts = await inserter.texts
        XCTAssertEqual(texts, [], "Отменённая диктовка не вставляет ничего")
        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0)

        // Микрофон — единственное, что видно пользователю снаружи приложения.
        let aborts = await capture.abortCount
        let recording = await capture.isRecording
        XCTAssertGreaterThanOrEqual(aborts, 1, "Захват обязан быть погашен явно")
        XCTAssertFalse(recording, "Микрофон остался включённым после отмены")

        // Запись убирается позже, чем сессия объявляет себя закрытой: удаление
        // стоит в `defer` завершающей задачи, а «свободно» выставляет задача
        // отмены. Печатаем зазор — он и есть найденный дефект стыка.
        let delay = await assertNoRecordingsLeft()
        let interrupted = await probe.failures
        print(
            """
            Отмена посреди распознавания:
              движок \(interrupted.first.map { "прерван — \($0)" } ?? "успел договорить сам")
              запись убрана через \(Self.milliseconds(delay)) мс после состояния «свободно»
            """
        )

        await assertNoFailureNotices()
    }

    /// Отменённая диктовка не портит следующую, начатую сразу после неё.
    ///
    /// Самый неприятный стык: хвост отменённой сессии просыпается уже во время
    /// новой. Проверяется на настоящей модели, потому что именно она и создаёт
    /// ту задержку, в которую хвост успевает проснуться.
    func testCancelledDictationDoesNotPoisonTheNextOne() async throws {
        try await speak(Phrase.long)
        try await speak(Phrase.other)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitUntil("запись пошла") { controller.state == .listening }
        controller.stop()
        await waitUntil("распознавание началось") { await self.probe.calls == 1 }
        controller.cancel()
        await waitUntil("отменённая сессия закрылась") { controller.state == .idle }

        await dictate(with: controller)

        let texts = await inserter.texts
        XCTAssertEqual(texts.count, 1, "Вставиться должна только вторая диктовка")
        let text = try XCTUnwrap(texts.first)
        XCTAssertTrue(text.containsInsensitive(Phrase.otherMarker), "Вставилось не то: \(text)")
        XCTAssertFalse(
            text.containsInsensitive(Phrase.longMarker),
            "В новую диктовку протёк текст отменённой: \(text)"
        )

        let recording = await capture.isRecording
        XCTAssertFalse(recording, "Микрофон остался включённым")
        await assertNoRecordingsLeft()
    }

    // MARK: - Две диктовки подряд

    /// Две диктовки подряд доходят целиком и не смешиваются.
    ///
    /// Движок переиспользуется между сессиями, и состояние декодера — общее
    /// место, где хвост первой фразы способен протечь во вторую. Увидеть это
    /// можно только на двух разных настоящих записях подряд.
    func testTwoDictationsInARowDoNotMix() async throws {
        try await speak(Phrase.mixed)
        try await speak(Phrase.other)
        let controller = makeController()

        await dictate(with: controller)
        await dictate(with: controller)

        let texts = await inserter.texts
        XCTAssertEqual(texts.count, 2, "Обе диктовки обязаны дойти")

        XCTAssertTrue(texts[0].contains("pull request"), "Первая пришла не полностью: \(texts[0])")
        XCTAssertFalse(
            texts[0].containsInsensitive(Phrase.otherMarker),
            "В первую попал текст второй: \(texts[0])"
        )

        XCTAssertTrue(
            texts[1].containsInsensitive(Phrase.otherMarker),
            "Вторая пришла не полностью: \(texts[1])"
        )
        for term in ["pull request", "GitHub", "production"] {
            XCTAssertFalse(
                texts[1].containsInsensitive(term),
                "Во вторую протёк хвост первой («\(term)»): \(texts[1])"
            )
        }

        let starts = await capture.startCount
        XCTAssertEqual(starts, 2)
        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Края

    /// Нажал и сразу отпустил: до распознавания дело не доходит, файла не остаётся.
    func testTooShortRecordingNeverReachesRecognition() async throws {
        try await speakBriefly(Phrase.short, seconds: 0.2)
        let controller = makeController()

        await dictate(with: controller)

        let calls = await probe.calls
        XCTAssertEqual(calls, 0, "Обрывок не должен доходить до модели")
        let texts = await inserter.texts
        XCTAssertEqual(texts, [], "Вставлять нечего")

        await assertNoRecordingsLeft()
        // Человек просто передумал — пугать его ошибкой не за что.
        await assertNoFailureNotices()
    }

    /// Человек промолчал: модель ничего не выдумала, вставки не было.
    func testSilentRecordingProducesNoInsertion() async throws {
        try await stayQuiet(seconds: 3)
        let controller = makeController()

        await dictate(with: controller)

        // Тишину отсеивает не длительность: запись полноценная, и до модели она
        // доходит. Пустым обязан оказаться именно ответ модели.
        let calls = await probe.calls
        XCTAssertEqual(calls, 1, "Трёхсекундная запись обязана дойти до распознавания")
        let raw = await probe.rawTexts.first
        XCTAssertEqual(
            raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "Модель выдумала фразу из тишины: \(raw ?? "—")"
        )

        let texts = await inserter.texts
        XCTAssertEqual(texts, [], "Пустой результат не вставляется")
        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0)

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }
}
