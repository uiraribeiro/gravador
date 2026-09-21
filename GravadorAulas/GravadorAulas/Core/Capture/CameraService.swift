//
//  CameraService.swift
//  GravadorAulas
//
//  Captura de webcam via AVCaptureSession + AVCaptureVideoDataOutput.
//  Entrega CMSampleBuffers para o RecordingSession e expõe
//  AVCaptureVideoPreviewLayer para a UI.
//

import Foundation
import AVFoundation
import CoreMedia
import AppKit

protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutput sampleBuffer: CMSampleBuffer)
    func cameraService(_ service: CameraService, didFailWithError error: Error)
}

final class CameraService: NSObject {

    weak var delegate: CameraServiceDelegate?

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private let queue = DispatchQueue(label: "gravadoraulas.camera.samples", qos: .userInteractive)

    private(set) var isRunning: Bool = false

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
        session.sessionPreset = .high
    }

    /// Inicializa o dispositivo, adiciona inputs/outputs.
    /// Falha com erro caso o dispositivo não exista ou esteja ocupado.
    func prepare(deviceRef: DeviceRef) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Remove o input anterior, se houver.
        if let old = input {
            session.removeInput(old)
            self.input = nil
        }

        guard let device = AVCaptureDevice(uniqueID: deviceRef.uniqueID) else {
            throw NSError(domain: "GravadorAulas", code: 100,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Webcam '\(deviceRef.displayName)' indisponível."])
        }

        do {
            let new = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(new) else {
                throw NSError(domain: "GravadorAulas", code: 101,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Não foi possível adicionar a webcam."])
            }
            session.addInput(new)
            self.input = new
        } catch {
            throw error
        }

        if session.outputs.contains(output) == false {
            output.alwaysDiscardsLateVideoFrames = false
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                throw NSError(domain: "GravadorAulas", code: 102,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Não foi possível registrar o output da webcam."])
            }
            session.addOutput(output)
        }
    }

    func start() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async { self?.isRunning = true }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.isRunning = false }
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        delegate?.cameraService(self, didOutput: sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Frames lentos; apenas loga
        AppLog.camera.warning("frame descartado pela webcam")
    }
}