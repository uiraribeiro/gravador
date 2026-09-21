//
//  Permissions.swift
//  GravadorAulas
//
//  Verificação e solicitação das permissões TCC (microfone, câmera,
//  reconhecimento de fala, captura de tela, acessibilidade).
//

import Foundation
import AVFoundation
import Speech
import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class PermissionsManager: ObservableObject {

    enum Status: String {
        case unknown, granted, denied, restricted
    }

    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var camera: Status = .unknown
    @Published private(set) var speechRecognition: Status = .unknown
    @Published private(set) var screenCapture: Status = .unknown
    @Published private(set) var accessibility: Status = .unknown

    static let shared = PermissionsManager()

    private init() {
        refresh()
    }

    func refresh() {
        microphone = Self.microphoneStatus()
        camera = Self.cameraStatus()
        speechRecognition = Self.speechRecognitionStatus()
        screenCapture = Self.screenCaptureStatus()
        accessibility = Self.accessibilityStatus()
    }

    // MARK: - Microfone

    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run { self.microphone = granted ? .granted : .denied }
        AppLog.perm.info("microfone solicitado -> \(granted, privacy: .public)")
        return granted
    }

    // MARK: - Câmera

    static func cameraStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    func requestCamera() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run { self.camera = granted ? .granted : .denied }
        AppLog.perm.info("camera solicitada -> \(granted, privacy: .public)")
        return granted
    }

    // MARK: - Reconhecimento de fala

    static func speechRecognitionStatus() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                let ok = (status == .authorized)
                Task { @MainActor in
                    self.speechRecognition = ok ? .granted : .denied
                    AppLog.perm.info("speech solicitado -> \(status.rawValue, privacy: .public)")
                    cont.resume(returning: ok)
                }
            }
        }
    }

    // MARK: - Screen Capture (ScreenCaptureKit)

    /// Versão estática segura — não chama `shared` para evitar recursão
    /// durante o init. Sempre retorna `.unknown` na checagem inicial;
    /// o valor real é determinado por `verifyScreenCaptureAccess()`.
    static func screenCaptureStatus() -> Status {
        .unknown
    }

    /// Verificação REAL de screen capture tentando iniciar um SCStream
    /// mínimo. Se já há permissão, retorna true. Se não há, dispara o
    /// prompt do sistema (uma vez por app) e retorna true se o usuário
    /// aceitar, false se negar.
    @discardableResult
    func verifyScreenCaptureAccess() async -> Bool {
        do {
            let content = try await SCShareableContentProxy.current()
            guard let display = content.displays.first else {
                await MainActor.run { self.screenCapture = .denied }
                return false
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 32
            config.height = 32
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try await stream.startCapture()
                try? await stream.stopCapture()
                await MainActor.run { self.screenCapture = .granted }
                AppLog.perm.info("screen capture: GRANTED")
                return true
            } catch {
                AppLog.perm.error("screen capture verify falhou: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.screenCapture = .denied }
                return false
            }
        } catch {
            AppLog.perm.error("SCShareableContent falhou: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { self.screenCapture = .denied }
            return false
        }
    }

    func requestScreenCapture() async -> Bool {
        // A verificação real (com prompt do sistema) só faz sentido ser
        // chamada quando o usuário tenta gravar. Aqui apenas marcamos
        // status como "checking" e devolvemos o estado atual.
        await verifyScreenCaptureAccess()
    }

    // MARK: - Accessibility (para CGEventTap do keycast)

    static func accessibilityStatus() -> Status {
        // Em Swift 6 + macOS 27 SDK, qualquer forma de passar CFDictionary com
        // kCFBooleanTrue para AXIsProcessTrustedWithOptions resulta em
        // EXC_BAD_ACCESS no CFGetTypeID interno (offset 0x8 inválido).
        // A chamada sem opções funciona — o prompt é disparado depois
        // por requestAccessibility() que abre Preferências do Sistema.
        let trusted = AXIsProcessTrustedWithOptions(nil)
        return trusted ? .granted : .unknown
    }

    func requestAccessibility() {
        // Não há API programática de "request". O usuário precisa abrir
        // Privacidade e Segurança → Acessibilidade e marcar o app.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        AppLog.perm.info("aberto painel de acessibilidade")
    }

    // MARK: - Diagnóstico

    var canRecordAtAll: Bool {
        // Não exigimos screenCapture == .granted aqui porque a verificação
        // real só acontece quando o usuário clica Gravar (e dispara o
        // prompt do sistema). Só bloqueamos se a tela estiver explicitamente
        // negada.
        microphone == .granted && screenCapture != .denied
    }
}

// Wrapper async para SCShareableContent (sem instanciar o objeto no escopo global).
enum SCShareableContentProxy {
    static func current() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { cont in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let content {
                    cont.resume(returning: content)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "GravadorAulas.ShareableContent",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "ScreenCaptureKit retornou sem conteúdo e sem erro."]
                    ))
                }
            }
        }
    }
}