//
//  SourceSelectionView.swift
//  GravadorAulas
//
//  Tela 1: escolha de fontes (tela, câmera, mic) e parâmetros de gravação.
//

import SwiftUI
import ScreenCaptureKit
import AppKit

struct SourceSelectionView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var permissions: PermissionsManager

    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var isPresentingRegionPicker = false

    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Escolha as fontes")
                    .font(.largeTitle.bold())

                Text("Defina o que será capturado. Você poderá revisar tudo antes de gravar.")
                    .foregroundStyle(.secondary)

                permissionsCard

                screenCard
                cameraCard
                microphoneCard
                optionsCard

                HStack {
                    Spacer()
                    Button("Continuar →") {
                        Task { @MainActor in
                            env.beginNewRecording()
                            onContinue()
                        }
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.canRecordAtAll && env.sourceConfig.captureMicrophone)
                }
            }
            .padding(32)
        }
        .task { await loadSources() }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permissões", systemImage: "lock.shield")
                .font(.headline)
            HStack(spacing: 16) {
                permPill("Microfone", status: permissions.microphone) {
                    Task { await permissions.requestMicrophone() }
                }
                permPill("Captura de tela", status: permissions.screenCapture) {
                    Task { await permissions.requestScreenCapture() }
                }
                permPill("Câmera", status: permissions.camera) {
                    Task { await permissions.requestCamera() }
                }
            }

            // Painel de ajuda específico para screen capture no macOS
            if permissions.screenCapture == .denied {
                screenCaptureHelpCard
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor)))
    }

    /// Painel de ajuda para screen capture.
    /// O TCC do macOS exige que o app seja ENCERRADO e REABERTO depois
    /// de conceder a permissão de Captura de Tela em Preferências do Sistema.
    private var screenCaptureHelpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Captura de Tela precisa de ação manual",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.bold())
            Text("""
No macOS, depois de conceder a permissão em **Privacidade → Gravação de Tela**, **você precisa encerrar e reabrir o Gravador de Aulas** para que o sistema libere a captura.

Sem isso, o app continua tentando acessar a tela sem autorização e o sistema recusa.
""")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    openScreenRecordingSettings()
                } label: {
                    Label("Abrir Preferências", systemImage: "gear")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await recheckScreenCapture() }
                } label: {
                    Label("Verificar novamente", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Encerrar app", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private func openScreenRecordingSettings() {
        // Deep link direto para o painel de Gravação de Tela
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func recheckScreenCapture() async {
        let ok = await permissions.verifyScreenCaptureAccess()
        AppLog.perm.info("recheck: \(ok ? "GRANTED" : "DENIED", privacy: .public)")
    }

    private func permPill(_ name: String,
                          status: PermissionsManager.Status,
                          request: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon(for: status))
                    .foregroundStyle(color(for: status))
                Text(name).bold()
            }
            Button(buttonLabel(for: status), action: request)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func icon(for s: PermissionsManager.Status) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied, .restricted: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for s: PermissionsManager.Status) -> Color {
        switch s {
        case .granted: return .green
        case .denied, .restricted: return .red
        case .unknown: return .orange
        }
    }

    private func buttonLabel(for s: PermissionsManager.Status) -> String {
        switch s {
        case .granted: return "Concedido"
        case .denied: return "Negado — abrir Preferências"
        case .restricted: return "Bloqueado"
        case .unknown: return "Solicitar"
        }
    }

    // MARK: - Screen

    private var screenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tela", systemImage: "display")
                .font(.headline)
            Picker("Origem", selection: $env.sourceConfig.screen) {
                ForEach(displays, id: \.displayID) { d in
                    Text("Display #\(d.displayID) (\(Int(d.frame.width))×\(Int(d.frame.height)))")
                        .tag(ScreenSource.display(displayID: d.displayID))
                }
                ForEach(windows, id: \.windowID) { w in
                    Text(w.title ?? "Janela \(w.windowID)").tag(ScreenSource.window(windowID: w.windowID, title: w.title))
                }
                if case .region(let rect, _, _) = env.sourceConfig.screen {
                    Text("Região \(Int(rect.width))×\(Int(rect.height))")
                        .tag(env.sourceConfig.screen)
                }
            }
            .pickerStyle(.menu)
            Button {
                presentRegionPicker(on: env.sourceConfig.screen.displayID)
            } label: {
                Label("Marcar região na tela…", systemImage: "viewfinder")
            }
            .disabled(isPresentingRegionPicker)
            if case .region(let rect, let displayID, _) = env.sourceConfig.screen {
                HStack {
                    Text("Área: \(Int(rect.width)) × \(Int(rect.height))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Marcar novamente na tela") {
                        presentRegionPicker(on: displayID)
                    }
                    .controlSize(.small)
                }
            }
            Toggle("Capturar áudio do computador", isOn: $env.sourceConfig.captureSystemAudio)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor)))
    }

    private func presentRegionPicker(on displayID: CGDirectDisplayID) {
        isPresentingRegionPicker = true
        RegionSelectionController.present(displayID: displayID) { rect in
            env.sourceConfig.screen = .region(
                rect: rect, displayID: displayID,
                label: "\(Int(rect.width))×\(Int(rect.height))")
            isPresentingRegionPicker = false
        } onCancel: {
            env.sourceConfig.screen = .display(displayID: displayID)
            isPresentingRegionPicker = false
        }
    }

    // MARK: - Camera

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Câmera (webcam)", systemImage: "camera")
                .font(.headline)
            DevicePickerView(
                title: "Webcam",
                devices: env.deviceDiscovery.cameras,
                selection: $env.sourceConfig.camera
            )
            Toggle("Mostrar webcam sobre a gravação", isOn: $env.sourceConfig.cameraOverlay.enabled)
            if env.sourceConfig.cameraOverlay.enabled {
                Toggle("Ocultar durante gravação (mantém ligada)", isOn: $env.sourceConfig.cameraOverlay.hidden)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor)))
    }

    // MARK: - Microfone

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Microfone", systemImage: "mic")
                .font(.headline)
            DevicePickerView(
                title: "Microfone",
                devices: env.deviceDiscovery.microphones,
                selection: $env.sourceConfig.microphone
            )
            Toggle("Gravar microfone em trilha separada", isOn: $env.sourceConfig.captureMicrophone)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor)))
    }

    // MARK: - Options

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Qualidade", systemImage: "slider.horizontal.3")
                .font(.headline)
            HStack(spacing: 24) {
                Picker("Resolução", selection: $env.sourceConfig.resolution) {
                    ForEach(CaptureResolution.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                Picker("Quadros/s", selection: $env.sourceConfig.frameRate) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .frame(width: 80)
                Picker("Qualidade", selection: $env.sourceConfig.quality) {
                    ForEach(QualityPreset.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .frame(width: 140)
            }
            Toggle("Mostrar atalhos de teclado no vídeo", isOn: $env.sourceConfig.showKeyCast)
            if env.sourceConfig.showKeyCast {
                Text("Registra apenas atalhos com ⌘ ou ⌃. A digitação comum não é gravada. Requer permissão de Acessibilidade.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Abrir ajustes de Acessibilidade") {
                    permissions.requestAccessibility()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor)))
    }

    // MARK: - Load

    private func loadSources() async {
        await env.deviceDiscovery.refresh()
        await loadDisplays()
    }

    private func loadDisplays() async {
        do {
            let content = try await SCShareableContentProxy.current()
            await MainActor.run {
                self.displays = content.displays
                self.windows = content.windows.filter { w in
                    guard let app = w.owningApplication else { return false }
                    if app.bundleIdentifier.contains("gravadoraulas") { return false }
                    return w.frame.width >= 200 && w.frame.height >= 100 && w.isOnScreen
                }
            }
        } catch {
            AppLog.ui.error("SCShareableContent falhou: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Region picker sobre a tela real

@MainActor
final class RegionSelectionController: NSObject {
    private static var active: RegionSelectionController?
    private var window: NSWindow?
    private let onSelect: (CGRect) -> Void
    private let onCancel: () -> Void

    private init(onSelect: @escaping (CGRect) -> Void,
                 onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    static func present(displayID: CGDirectDisplayID,
                        onSelect: @escaping (CGRect) -> Void,
                        onCancel: @escaping () -> Void) {
        active?.cancel()
        let controller = RegionSelectionController(onSelect: onSelect, onCancel: onCancel)
        active = controller
        controller.show(displayID: displayID)
    }

    private func show(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) ?? NSScreen.main else {
            cancel()
            return
        }
        let panel = NSWindow(
            contentRect: screen.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen)
        panel.level = .screenSaver
        panel.title = "Selecionar região de captura"
        panel.setAccessibilityLabel("Selecionar região de captura")
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RegionPickerView(
            onSelect: { [weak self] rect in self?.finish(rect) },
            onCancel: { [weak self] in self?.cancel() }))
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ rect: CGRect) {
        window?.orderOut(nil)
        window = nil
        Self.active = nil
        onSelect(rect.integral)
    }

    private func cancel() {
        window?.orderOut(nil)
        window = nil
        Self.active = nil
        onCancel()
    }
}

struct RegionPickerView: View {
    let onSelect: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var start: CGPoint? = nil
    @State private var end: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    var mask = Path()
                    mask.addRect(CGRect(origin: .zero, size: size))
                    if let rect = selectedRect { mask.addRect(rect) }
                    context.fill(mask, with: .color(.black.opacity(0.48)), style: .init(eoFill: true))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            start = value.startLocation
                            end = value.location
                        }
                        .onEnded { value in end = value.location }
                )
                if let s = start, let e = end {
                    let rect = CGRect(
                        x: min(s.x, e.x),
                        y: min(s.y, e.y),
                        width: abs(e.x - s.x),
                        height: abs(e.y - s.y))
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.2))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Arraste para marcar a região da tela").bold()
                Text(selectedRect.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Área mínima: 100 × 100")
                    .font(.caption)
                HStack {
                    Button("Cancelar", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Usar esta região") {
                        if let rect = selectedRect { onSelect(rect) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidSelection)
                }
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(10)
            .padding()
        }
    }

    private var selectedRect: CGRect? {
        guard let s = start, let e = end else { return nil }
        return CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                      width: abs(e.x - s.x), height: abs(e.y - s.y))
    }

    private var isValidSelection: Bool {
        guard let rect = selectedRect else { return false }
        return rect.width >= 100 && rect.height >= 100
    }
}
