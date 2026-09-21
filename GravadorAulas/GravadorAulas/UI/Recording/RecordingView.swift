//
//  RecordingView.swift
//  GravadorAulas
//
//  Tela 2: prévia da tela, medidores, webcam e controles de gravação.
//

import SwiftUI
import AVFoundation

struct RecordingView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var permissions: PermissionsManager

    @StateObject private var session: RecordingSession
    @State private var countdown: Int? = nil
    @State private var countdownTimer: Timer?
    @State private var didPrepare: Bool = false

    let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
        _session = StateObject(wrappedValue: RecordingSession(config: SourceConfig()))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                stateBadge
                Spacer()
                Text(session.elapsed.hmsString)
                    .font(.system(.title, design: .monospaced))
                    .monospacedDigit()
            }
            .padding()

            HSplitView {
                screenPreview
                    .frame(minWidth: 600)
                sidePanel
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            }

            Divider()

            controlsBar
                .padding()
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .task {
            session.sourceConfig = env.sourceConfig
            if !didPrepare {
                do {
                    try await session.prepare()
                    didPrepare = true
                } catch {
                    AppLog.ui.error("prepare falhou: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        .onDisappear {
            countdownTimer?.invalidate()
            // Garante que a menu bar não fica órfã se o usuário sair da tela
            env.menuBar.detach()
            WindowHider.showMainWindow()
        }
    }

    // MARK: - State badge

    private var stateBadge: some View {
        let (label, color) = badgeInfo()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label).bold()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private func badgeInfo() -> (String, Color) {
        switch session.state {
        case .idle:       return ("Pronto", .gray)
        case .preparing:  return ("Preparando…", .orange)
        case .ready:      return ("Pronto", .gray)
        case .recording:  return ("Gravando", .red)
        case .paused:     return ("Pausado", .yellow)
        case .stopping:   return ("Finalizando…", .orange)
        }
    }

    // MARK: - Screen preview

    private var screenPreview: some View {
        ZStack {
            Color.black
            ScreenPreviewView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let n = countdown {
                Text("\(n)")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(radius: 8)
            }
        }
    }

    // MARK: - Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dispositivos").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "mic.fill")
                    Text("Microfone")
                    Spacer()
                    Text(session.sourceConfig.microphone?.displayName ?? "—")
                        .foregroundStyle(.secondary)
                }
                LevelMetersView(level: session.micLevel)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("Áudio do sistema")
                    Spacer()
                    Text(session.sourceConfig.captureSystemAudio ? "ligado" : "desligado")
                        .foregroundStyle(.secondary)
                }
                LevelMetersView(level: session.sysAudioLevel)
            }

            if let cam = session.sourceConfig.camera, !session.sourceConfig.cameraOverlay.hidden {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text(cam.displayName)
                    }
                    CameraPreviewView(previewLayer: CameraPreviewFactory.make())
                        .frame(height: 180)
                        .background(Color.black)
                        .cornerRadius(8)
                    Text("(prévias só disponíveis após gravação)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let e = session.lastError {
                Text(e)
                    .font(.callout).foregroundStyle(.red)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
            }

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Controls

    private var controlsBar: some View {
        HStack(spacing: 16) {
            switch session.state {
            case .ready, .idle:
                Button {
                    startCountdownAndRecord()
                } label: {
                    Label("Gravar", systemImage: "record.circle.fill")
                        .font(.title3)
                }
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command])

            case .recording:
                Button {
                    session.pause()
                } label: {
                    Label("Pausar", systemImage: "pause.fill")
                        .font(.title3)
                }
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: [.command])

                Button {
                    Task { await stopAndGoToReview() }
                } label: {
                    Label("Parar", systemImage: "stop.fill")
                        .font(.title3)
                }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])

            case .paused:
                Button {
                    Task { try? await session.resume() }
                } label: {
                    Label("Retomar", systemImage: "play.fill")
                        .font(.title3)
                }
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: [.command])

                Button {
                    Task { await stopAndGoToReview() }
                } label: {
                    Label("Parar", systemImage: "stop.fill")
                        .font(.title3)
                }
                .controlSize(.large)

            case .preparing, .stopping:
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if case .recording = session.state {
                Text("⏺").font(.title2).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func startCountdownAndRecord() {
        guard countdown == nil else { return }
        var n = 3
        countdown = n
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            n -= 1
            if n <= 0 {
                timer.invalidate()
                countdown = nil
                // Timer closure não é main-isolated. Despacha ao MainActor
                // antes de mexer em session/start e nos helpers de janela.
                Task { @MainActor in
                    do { try await session.start() } catch {
                        AppLog.ui.error("start falhou: \(error.localizedDescription, privacy: .public)")
                    }
                    WindowHider.hideMainWindow()
                    env.menuBar.attach(
                        session: session,
                        onStopRequested: {
                            Task { @MainActor in await stopAndGoToReview() }
                        },
                        onCancelRequested: {
                            Task { @MainActor in
                                _ = await session.stop()
                                env.menuBar.detach()
                                WindowHider.showMainWindow()
                            }
                        }
                    )
                }
            } else {
                Task { @MainActor in countdown = n }
            }
        }
    }

    private func stopAndGoToReview() async {
        env.menuBar.detach()
        let result = await session.stop()
        WindowHider.showMainWindow()
        await MainActor.run {
            env.lastRecordingResult = result
            var p = env.currentProject ?? Project.empty(name: "Nova aula")
            p.timeline = TimelineBuilder.build(from: p, recordingResult: result)
            p.modifiedAt = .now
            env.currentProject = p
            onStop()
        }
    }
}

// MARK: - Camera preview factory (etapa 1: não-real, etapa 2: real)

enum CameraPreviewFactory {
    @MainActor
    static func make() -> AVCaptureVideoPreviewLayer {
        // Para a Etapa 1 a prévia da câmera é cosmética.
        // A Etapa 2 conecta um AVCaptureSession dedicado à UI.
        let session = AVCaptureSession()
        session.sessionPreset = .high
        return AVCaptureVideoPreviewLayer(session: session)
    }
}