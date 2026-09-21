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
    @Published var currentProject: Project?
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