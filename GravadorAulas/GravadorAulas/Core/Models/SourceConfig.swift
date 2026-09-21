//
//  SourceConfig.swift
//  GravadorAulas
//

import Foundation
import CoreMedia
import CoreGraphics

// MARK: - Resolução

enum CaptureResolution: String, Codable, CaseIterable, Identifiable {
    case r720p, r1080p, r1440p, r2160p, matchDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .r720p:  return "720p (1280×720)"
        case .r1080p: return "1080p (1920×1080)"
        case .r1440p: return "1440p (2560×1440)"
        case .r2160p: return "4K (3840×2160)"
        case .matchDisplay: return "Resolução nativa da tela"
        }
    }

    var pixelSize: CGSize? {
        switch self {
        case .r720p:  return CGSize(width: 1280, height: 720)
        case .r1080p: return CGSize(width: 1920, height: 1080)
        case .r1440p: return CGSize(width: 2560, height: 1440)
        case .r2160p: return CGSize(width: 3840, height: 2160)
        case .matchDisplay: return nil
        }
    }
}

enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case low, medium, high, max

    var id: String { rawValue }
    var label: String {
        switch self {
        case .low:    return "Leve"
        case .medium: return "Equilibrada"
        case .high:   return "Alta"
        case .max:    return "Máxima"
        }
    }
    /// Bits por segundo do vídeo H.264.
    var bitsPerSecond: Int {
        switch self {
        case .low:    return 2_000_000
        case .medium: return 6_000_000
        case .high:   return 12_000_000
        case .max:    return 25_000_000
        }
    }
    /// KBps de áudio AAC.
    var audioBitrate: Int {
        switch self {
        case .low:    return 64_000
        case .medium: return 96_000
        case .high:   return 128_000
        case .max:    return 192_000
        }
    }
}

// MARK: - Tela (fonte)

/// Identifica uma fonte de tela: display inteiro, janela ou região retangular.
enum ScreenSource: Codable, Equatable, Hashable {
    case display(displayID: CGDirectDisplayID)
    case window(windowID: CGWindowID, title: String?)
    case region(rect: CGRect, displayID: CGDirectDisplayID, label: String)

    var displayID: CGDirectDisplayID {
        switch self {
        case .display(let id): return id
        case .window(_, _): return CGMainDisplayID()
        case .region(_, let id, _): return id
        }
    }

    var humanLabel: String {
        switch self {
        case .display(let id):
            return "Display #\(id)"
        case .window(_, let title):
            return title ?? "Janela"
        case .region(_, _, let label):
            return "Região — \(label)"
        }
    }
}

// MARK: - Dispositivo (câmera ou microfone)

/// Identifica um dispositivo de captura (câmera ou microfone) por
/// uniqueID do AVCaptureDevice.
struct DeviceRef: Codable, Equatable, Hashable, Identifiable {
    let uniqueID: String
    var displayName: String

    var id: String { uniqueID }
}

// MARK: - Webcam overlay (posição / tamanho)

struct CameraOverlayConfig: Codable, Equatable {
    var enabled: Bool = true
    var normalizedRect: CGRect = CGRect(x: 0.72, y: 0.72, width: 0.25, height: 0.25) // canto inferior direito
    var cornerRadius: CGFloat = 16
    var hidden: Bool = false
}

// MARK: - Configuração de fontes para uma gravação

struct SourceConfig: Codable, Equatable {
    var screen: ScreenSource = .display(displayID: CGMainDisplayID())
    var captureSystemAudio: Bool = true
    var captureMicrophone: Bool = true

    var camera: DeviceRef? = nil
    var microphone: DeviceRef? = nil

    var cameraOverlay: CameraOverlayConfig = .init()

    var resolution: CaptureResolution = .r1080p
    var frameRate: Int = 30
    var quality: QualityPreset = .high

    var showKeyCast: Bool = false
}