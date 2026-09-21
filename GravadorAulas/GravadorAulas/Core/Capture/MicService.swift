//
//  MicService.swift
//  GravadorAulas
//
//  Captura de microfone via AVCaptureSession + AVCaptureAudioDataOutput.
//

import Foundation
import AVFoundation
import CoreMedia

protocol MicServiceDelegate: AnyObject {
    func micService(_ service: MicService, didOutput sampleBuffer: CMSampleBuffer)
    func micService(_ service: MicService, didFailWithError error: Error)
}

final class MicService: NSObject {

    weak var delegate: MicServiceDelegate?

    let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private var input: AVCaptureDeviceInput?
    private let queue = DispatchQueue(label: "gravadoraulas.mic.samples", qos: .userInteractive)

    private(set) var isRunning = false
    private(set) var currentLevel: Float = 0.0 // RMS linear 0...1

    override init() {
        super.init()
        session.sessionPreset = .high
    }

    func prepare(deviceRef: DeviceRef) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let old = input {
            session.removeInput(old)
            self.input = nil
        }

        guard let device = AVCaptureDevice(uniqueID: deviceRef.uniqueID) else {
            throw NSError(domain: "GravadorAulas", code: 200,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Microfone '\(deviceRef.displayName)' indisponível."])
        }

        let new = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(new) else {
            throw NSError(domain: "GravadorAulas", code: 201,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Não foi possível adicionar o microfone."])
        }
        session.addInput(new)
        self.input = new

        if !session.outputs.contains(output) {
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                throw NSError(domain: "GravadorAulas", code: 202,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Não foi possível registrar o output de áudio."])
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

extension MicService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        delegate?.micService(self, didOutput: sampleBuffer)
        // Medição de nível simples
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        _ = sampleBuffer.formatDescription?.audioStreamBasicDescription
        let count = Int(sampleBuffer.numSamples)
        guard count > 0 else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copyResult = data.withUnsafeMutableBytes { rawBuf -> OSStatus in
            guard let baseAddr = rawBuf.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddr
            )
        }
        guard copyResult == kCMBlockBufferNoErr else { return }
        var peak: Float = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let s16 = buf.bindMemory(to: Int16.self)
            for i in 0..<min(s16.count, count) {
                let v = abs(Float(s16[i]) / 32768.0)
                if v > peak { peak = v }
            }
        }
        self.currentLevel = min(1.0, peak)
    }
}