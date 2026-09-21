//
//  DeviceDiscovery.swift
//  GravadorAulas
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Descoberta de câmeras, microfones, displays e janelas para SCStream.
@MainActor
final class DeviceDiscovery: ObservableObject {

    @Published private(set) var cameras: [DeviceRef] = []
    @Published private(set) var microphones: [DeviceRef] = []
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []

    func refresh() async {
        // AVFoundation — nomes de DeviceType atualizados em macOS 14:
        // .builtInWideAngleCamera, .builtInMicrophone, .external
        let videoTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoTypes,
            mediaType: .video,
            position: .unspecified
        )
        cameras = session.devices.map { DeviceRef(uniqueID: $0.uniqueID, displayName: $0.localizedName) }

        let audioTypes: [AVCaptureDevice.DeviceType] = [
            .microphone,
            .external,
        ]
        let micSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: audioTypes,
            mediaType: .audio,
            position: .unspecified
        )
        microphones = micSession.devices.map { DeviceRef(uniqueID: $0.uniqueID, displayName: $0.localizedName) }

        // ScreenCaptureKit
        do {
            let content = try await SCShareableContentProxy.current()
            self.displays = content.displays
            self.windows = content.windows.filter { w in
                // Filtra janelas invisíveis / muito pequenas / da própria app
                guard let app = w.owningApplication else { return false }
                if app.bundleIdentifier.contains("gravadoraulas") { return false }
                return w.frame.width >= 200 && w.frame.height >= 100 && w.isOnScreen
            }
        } catch {
            AppLog.capture.error("falha listando SCShareableContent: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func avDevice(for ref: DeviceRef, type: AVMediaType) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: ref.uniqueID)
    }
}