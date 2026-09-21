import SwiftUI

struct ChaptersPanelView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var title = ""
    @State private var start: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Capítulos").font(.headline)
                Spacer()
                Button {
                    suggestChapters()
                } label: {
                    Label("Sugerir pela transcrição", systemImage: "wand.and.stars")
                }
                .disabled((env.currentProject?.transcriptionSegments ?? []).isEmpty)
            }
            HStack {
                TextField("Nome do assunto", text: $title)
                TextField("Segundo", value: $start, format: .number)
                    .frame(width: 74)
                Button("Adicionar") { addChapter() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let chapters = env.currentProject?.chapters {
                List {
                    ForEach(chapters.sorted(by: { $0.start < $1.start })) { chapter in
                        HStack {
                            Text(chapter.start.hmsString)
                                .monospacedDigit()
                                .frame(width: 70, alignment: .leading)
                            TextField("Assunto", text: chapterTitleBinding(for: chapter.id))
                            Spacer()
                            Button(role: .destructive) { removeChapter(chapter.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 100)
            }
        }
        .padding()
    }

    private func addChapter() {
        guard var project = env.currentProject else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, start >= 0, start <= project.timeline.duration else { return }
        project.chapters.append(Chapter(title: cleanTitle, start: start))
        project.modifiedAt = .now
        env.currentProject = project
        title = ""
    }

    private func removeChapter(_ id: UUID) {
        guard var project = env.currentProject else { return }
        project.chapters.removeAll { $0.id == id }
        project.modifiedAt = .now
        env.currentProject = project
    }

    private func chapterTitleBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { env.currentProject?.chapters.first(where: { $0.id == id })?.title ?? "" },
            set: { newTitle in
                guard var project = env.currentProject,
                      let index = project.chapters.firstIndex(where: { $0.id == id }) else { return }
                project.chapters[index].title = newTitle
                project.modifiedAt = .now
                env.currentProject = project
            })
    }

    private func suggestChapters() {
        guard var project = env.currentProject else { return }
        let segments = (project.transcriptionSegments ?? [])
            .filter { $0.kind != "silence" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard let first = segments.first else { return }

        var starts: [TranscriptionSegment] = [first]
        var lastChapterStart = first.start
        for index in 1..<segments.count {
            let segment = segments[index]
            let gap = segment.start - segments[index - 1].end
            let elapsed = segment.start - lastChapterStart
            if (gap >= 2.5 && elapsed >= 30) || elapsed >= 300 {
                starts.append(segment)
                lastChapterStart = segment.start
            }
        }

        let generated = starts.enumerated().map { index, segment in
            Chapter(title: chapterTitle(from: segment.text, isFirst: index == 0),
                    start: index == 0 ? 0 : segment.start)
        }
        // Mantém capítulos manuais distantes das sugestões e evita duplicatas.
        let manual = project.chapters.filter { chapter in
            !generated.contains(where: { abs($0.start - chapter.start) < 1 })
        }
        project.chapters = (manual + generated).sorted { $0.start < $1.start }
        project.modifiedAt = .now
        env.currentProject = project
    }

    private func chapterTitle(from text: String, isFirst: Bool) -> String {
        let cleaned = text
            .replacingOccurrences(of: "[\\n\\r]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).prefix(7)
        var result = words.joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        if result.isEmpty { result = isFirst ? "Introdução" : "Novo assunto" }
        if result.count > 56 { result = String(result.prefix(53)) + "…" }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}
