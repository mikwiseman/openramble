import SwiftUI
import UniformTypeIdentifiers

/// The one page: everything you have said, newest at the bottom by your thumb,
/// and the button that records the next thing.
struct HomeView: View {
    @Environment(Dictation.self) private var dictation
    @Environment(TakeStore.self) private var store
    @State private var path: [Take.ID] = []
    @State private var showsSettings = false
    @State private var choosesFile = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                // While listening, the page clears for the voice alone.
                TakeList()
                    .opacity(dictation.isRecording ? 0 : 1)
                    .allowsHitTesting(!dictation.isRecording)
                    .accessibilityHidden(dictation.isRecording)

                if dictation.isRecording {
                    VoiceView(levels: dictation.levels)
                        .frame(height: 140)
                        .padding(.horizontal, Theme.margin)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            // The glass floats over the words, which scroll beneath it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 18) {
                    NoticeView()
                    RecordControls()
                }
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .animation(.smooth(duration: 0.35), value: dictation.isRecording)
            .background(Color(.systemBackground))
            .navigationDestination(for: Take.ID.self) { id in
                TakeView(id: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open Audio File", systemImage: "waveform") { choosesFile = true }
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .disabled(dictation.isRecording)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .fileImporter(isPresented: $choosesFile, allowedContentTypes: [.audio]) { result in
                guard case let .success(url) = result else { return }
                Task { await dictation.open(file: url) }
            }
        }
        .sensoryFeedback(trigger: dictation.isRecording) { _, recording in
            recording ? .start : .stop
        }
        .sensoryFeedback(.success, trigger: dictation.wordsArrived)
    }
}

/// Takes grouped by day, in the person's own words.
struct TakeList: View {
    @Environment(TakeStore.self) private var store
    @Environment(Dictation.self) private var dictation

    private var shown: [Take] {
        store.takes.filter { $0.id != dictation.recordingID }
    }

    var body: some View {
        let takes = shown
        if takes.isEmpty {
            EmptyPage()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.takeSpacing * 1.5) {
                    ForEach(Self.days(takes), id: \.day) { group in
                        VStack(alignment: .leading, spacing: Theme.takeSpacing) {
                            Text(Self.title(for: group.day))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, -Theme.takeSpacing / 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.takes) { take in
                                NavigationLink(value: take.id) {
                                    TakeRow(take: take)
                                }
                                .buttonStyle(.plain)
                                .id(take.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            // Opens at the newest take, and stays there as new words arrive.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }

    struct Day {
        let day: Date
        let takes: [Take]
    }

    static func days(_ takes: [Take], calendar: Calendar = .current) -> [Day] {
        var groups: [Day] = []
        for take in takes {
            let day = calendar.startOfDay(for: take.recordedAt)
            if groups.last?.day == day {
                groups[groups.count - 1] = Day(day: day, takes: groups[groups.count - 1].takes + [take])
            } else {
                groups.append(Day(day: day, takes: [take]))
            }
        }
        return groups
    }

    static func title(for day: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: now, toGranularity: .year)
        return day.formatted(sameYear
            ? .dateTime.weekday(.wide).day().month(.wide)
            : .dateTime.day().month(.wide).year())
    }
}

/// Before the first take.
struct EmptyPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Say anything.")
                .font(Theme.display)
            Text("Tap the button and talk. Your words appear here, written on this iPhone, and are copied, ready to paste.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// One take in the list.
struct TakeRow: View {
    @Environment(Dictation.self) private var dictation
    let take: Take

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(take.caption)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            content
                .transition(.blurReplace)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .animation(.smooth(duration: 0.5), value: take.state)
        .contextMenu {
            if take.hasWords {
                Button("Copy", systemImage: "doc.on.doc") { dictation.copy(take) }
                ShareLink(item: take.text)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch take.state {
        case .written:
            Text(take.text)
                .font(Theme.words)
                .lineSpacing(Theme.leading)
                .lineLimit(12)
                .foregroundStyle(.primary)
        case .writing:
            WritingLine()
        case .silent:
            Text("No words heard.")
                .font(Theme.words.italic())
                .foregroundStyle(.tertiary)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Not written.")
                    .font(Theme.words.italic())
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await dictation.write(take.id) } }
                    .font(.callout)
            }
        }
    }
}

/// "Writing", breathing quietly while the engine works.
struct WritingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("Writing…")
            .font(Theme.words.italic())
            .foregroundStyle(.secondary)
            .phaseAnimator([0.35, 0.9]) { view, opacity in
                view.opacity(reduceMotion ? 0.6 : opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
    }
}
