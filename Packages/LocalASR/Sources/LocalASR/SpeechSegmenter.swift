import Foundation

/// Нарезка записи на куски по паузам в речи.
///
/// Существует из-за поведения движка: он обрабатывает звук окнами по 15 секунд
/// и при склейке окон **молча теряет речь**. На проверке пропало целое
/// предложение — без ошибки, без предупреждения, просто исчезло. Хуже дефекта
/// для диктовки не придумать: человек уверен, что сказанное записано.
///
/// Тот же кусок, поданный отдельно, распознаётся полностью. Поэтому длинные
/// записи режутся заранее — по тишине, чтобы разрез не попал в середину слова.
public struct SpeechSegmenter: Sendable {
    /// Максимальная длина куска.
    ///
    /// Заметно меньше пятнадцатисекундного окна движка: нужен запас, иначе
    /// после ресемплинга кусок окажется на границе и потеря вернётся.
    public let maximumDuration: TimeInterval

    /// Ниже какой длины резать бессмысленно.
    public let minimumDuration: TimeInterval

    /// Насколько тихо должно быть, чтобы считать это паузой.
    ///
    /// Порог относительный: берётся доля от средней громкости записи, поэтому
    /// одинаково работает и для тихой речи, и для громкой.
    public let silenceRatio: Float

    private let sampleRate: Double

    public init(
        maximumDuration: TimeInterval = 12,
        minimumDuration: TimeInterval = 0.35,
        silenceRatio: Float = 0.15,
        sampleRate: Double = 16_000
    ) {
        self.maximumDuration = maximumDuration
        self.minimumDuration = minimumDuration
        self.silenceRatio = silenceRatio
        self.sampleRate = sampleRate
    }

    /// Диапазон отсчётов одного куска.
    public struct Segment: Sendable, Equatable {
        public let range: Range<Int>
        public var duration: TimeInterval
    }

    /// Нужно ли вообще резать эту запись.
    public func needsSegmentation(sampleCount: Int) -> Bool {
        Double(sampleCount) / sampleRate > maximumDuration
    }

    /// Разбить запись на куски.
    ///
    /// Короткие записи возвращаются одним куском — резать их незачем.
    public func segments(for samples: [Float]) -> [Segment] {
        let total = samples.count
        guard total > 0 else { return [] }

        let whole = Segment(range: 0..<total, duration: Double(total) / sampleRate)
        guard needsSegmentation(sampleCount: total) else { return [whole] }

        let maximumSamples = Int(maximumDuration * sampleRate)
        // Искать паузу начинаем не с самого начала куска, а ближе к его концу:
        // иначе разрезы получатся частыми и короткими.
        let searchWindow = Int(3.0 * sampleRate)
        let energies = windowEnergies(samples)
        let threshold = silenceThreshold(from: energies)

        var result: [Segment] = []
        var start = 0

        while start < total {
            let hardEnd = min(start + maximumSamples, total)
            if hardEnd == total {
                result.append(Segment(range: start..<total, duration: Double(total - start) / sampleRate))
                break
            }

            // Ищем самую тихую точку в конце куска — там и режем.
            let searchStart = max(start + Int(minimumDuration * sampleRate), hardEnd - searchWindow)
            let cut = quietestPoint(
                in: searchStart..<hardEnd,
                energies: energies,
                threshold: threshold
            ) ?? hardEnd

            result.append(Segment(range: start..<cut, duration: Double(cut - start) / sampleRate))
            start = cut
        }

        return result.filter { $0.duration >= 0.05 }
    }

    // MARK: - Энергия сигнала

    /// Размер окна для оценки громкости — 20 мс.
    private var windowSize: Int { Int(0.02 * sampleRate) }

    private func windowEnergies(_ samples: [Float]) -> [Float] {
        let size = windowSize
        guard size > 0 else { return [] }

        var energies: [Float] = []
        energies.reserveCapacity(samples.count / size + 1)

        var index = 0
        while index < samples.count {
            let end = min(index + size, samples.count)
            var sum: Float = 0
            for position in index..<end { sum += abs(samples[position]) }
            energies.append(sum / Float(end - index))
            index += size
        }
        return energies
    }

    private func silenceThreshold(from energies: [Float]) -> Float {
        guard !energies.isEmpty else { return 0 }
        let average = energies.reduce(0, +) / Float(energies.count)
        return average * silenceRatio
    }

    /// Найти самое тихое место в диапазоне.
    private func quietestPoint(
        in range: Range<Int>,
        energies: [Float],
        threshold: Float
    ) -> Int? {
        let size = windowSize
        guard size > 0, !energies.isEmpty else { return nil }

        let firstWindow = range.lowerBound / size
        let lastWindow = min(range.upperBound / size, energies.count - 1)
        guard firstWindow < lastWindow else { return nil }

        var quietestIndex = firstWindow
        var quietestValue = Float.greatestFiniteMagnitude

        for window in firstWindow...lastWindow where energies[window] < quietestValue {
            quietestValue = energies[window]
            quietestIndex = window
        }

        // Если тишины не нашлось вовсе — режем по границе куска: молчаливая
        // потеря речи хуже, чем разрез посреди слова.
        guard quietestValue <= threshold else { return nil }
        return min(quietestIndex * size + size / 2, range.upperBound)
    }
}
