//
//  ProjectStore.swift
//  GravadorAulas
//
//  Persistência do projeto como JSON. Não modifica arquivos originais
//  (segmentos gravados, mídias importadas).
//

import Foundation

final class ProjectStore {

    static let shared = ProjectStore()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Sugere uma pasta de projetos: ~/Movies/GravadorAulas/Projetos
    func defaultProjectsDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .moviesDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let dir = base.appendingPathComponent("GravadorAulas/Projetos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func save(_ project: Project) throws -> URL {
        let dir = defaultProjectsDirectory()
        let url = dir.appendingPathComponent("\(safe(name: project.name))-\(project.id.uuidString).gaulasproj.json")
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
        AppLog.editor.info("projeto salvo: \(url.path, privacy: .public)")
        return url
    }

    func load(url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Project.self, from: data)
    }

    private func safe(name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " _-"))
        return name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }
}
