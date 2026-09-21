//
//  AppEnvironment.swift
//  GravadorAulas
//
//  Container de serviços de longa duração usados pela UI.
//

import SwiftUI
import Combine
import AVFoundation
import ScreenCaptureKit

@MainActor
final class AppEnvironment: ObservableObject {

    @Published var sourceConfig: SourceConfig = .init()
    @Published var currentProject: Project? {
        didSet {
            if let currentProject {
                do { _ = try ProjectStore.shared.save(currentProject) }
                catch { AppLog.editor.error("falha salvando projeto: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
    @Published var lastRecordingResult: RecordingResult?

    let deviceDiscovery = DeviceDiscovery()
    let exporter = Exporter()
    let keycast = KeyCastService()
    let menuBar = MenuBarController()

    private var session: RecordingSession?

    init() {}

    // MARK: Recording flow

    func beginNewRecording() {
        currentProject = Project.empty(name: "Nova aula")
        lastRecordingResult = nil
    }

    func openProject(at url: URL) throws {
        var project = try ProjectStore.shared.load(url: url)
        let screen = project.timeline.track(.screen)?.clips ?? []
        guard !screen.isEmpty, screen.allSatisfy({ FileManager.default.fileExists(atPath: $0.assetURL.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        project.timeline.duration = max(project.timeline.duration,
            screen.map { $0.timelineStart + $0.sourceDuration }.max() ?? 0)
        func refs(_ kind: TrackKind) -> [SegmentRef] {
            (project.timeline.track(kind)?.clips ?? []).map {
                SegmentRef(id: $0.id, kind: kind, url: $0.assetURL,
                           duration: $0.sourceDuration, timelineStart: $0.timelineStart)
            }
        }
        lastRecordingResult = RecordingResult(
            screen: refs(.screen), camera: refs(.camera), mic: refs(.microphone),
            sysAudioIncludedInScreen: project.sources.captureSystemAudio,
            timelineDuration: project.timeline.duration,
            outputDirectory: screen[0].assetURL.deletingLastPathComponent())
        sourceConfig = project.sources
        currentProject = project
    }

    func requestToggleRecording() {
        guard let session else { return }
        switch session.state {
        case .ready:    Task { try? await session.start() }
        case .recording: session.pause()
        case .paused:   Task { try? await session.resume() }
        case .idle, .preparing, .stopping: break
        }
    }

    func requestTogglePause() {
        guard let session else { return }
        switch session.state {
        case .recording: session.pause()
        case .paused:    Task { try? await session.resume() }
        default: break
        }
    }

    func makeSession() -> RecordingSession {
        session = RecordingSession(config: sourceConfig)
        return session!
    }

    func clearSession() {
        session = nil
    }
}
