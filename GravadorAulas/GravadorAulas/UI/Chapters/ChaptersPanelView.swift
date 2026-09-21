import SwiftUI

struct ChaptersPanelView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var title = ""
    @State private var start: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capítulos").font(.headline)
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
                            Text(chapter.title)
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
}
