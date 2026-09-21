//
//  RecordingSession.swift
//  GravadorAulas
//
//  Orquestrador da gravação.
//
//  Coordena ScreenCaptureService (tela + áudio do sistema), CameraService
//  (webcam) e MicService (microfone). Cada fonte grava em arquivos MP4
//  segmentados (um MP4 por bloco pause/resume). A composição final é
//  feita pelo Compositor a partir dos URLs dos segmentos.
//
//  Estado:
//      idle → preparing → ready → recording ⇄ paused → stopping → idle
//
//  Toda a publicação é feita no main actor para a UI.
//

import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import AppKit
import Combine

// MARK: - Segment metadata

/// Metadados de um segmento gravado (1 arquivo MP4).
struct SegmentRef: Identifiable, Equatable {
    let id: UUID
    let kind: TrackKind
    let url: URL
    /// Duração efetiva gravada (segundos). Definida após finish().
    var duration: Double
    /// Posição na timeline do projeto onde o segmento começa.
    let timelineStart: Double
}

struct RecordingResult: Equatable {
    var screen: [SegmentRef]
    var camera: [SegmentRef]
    var mic:   [SegmentRef]
    var sysAudioIncludedInScreen: Bool
    var timelineDuration: Double
    var outputDirectory: URL
}

// MARK: - Erros

enum RecordingError: LocalizedError {
    case notReady
    case deviceUnavailable(String)
    case startFailed(String)
    case noScreenContent

    var errorDescription: String? {
        switch self {
        case .notReady: return "A sessão ainda não foi preparada."
        case .deviceUnavailable(let d): return "Dispositivo indisponível: \(d)"
        case .startFailed(let m): return "Falha ao iniciar a captura: \(m)"
        case .noScreenContent: return "Não foi possível obter o conteúdo de tela."
        }
    }
}

// MARK: - Session

@MainActor
final class RecordingSession: NSObject, ObservableObject {

    enum State: Equatable { case idle, preparing, ready, recording, paused, stopping }

    // MARK: Estado publicado

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var sysAudioLevel: Float = 0
    @Published var lastError: String?
    @Published var sourceConfig: SourceConfig

    // MARK: Componentes internos

    private let screen = ScreenCaptureService()
    private let camera = CameraService()
    private let mic   = MicService()

    private var segmentsScreen: [SegmentRef] = []
    private var segmentsCamera: [SegmentRef] = []
    private var segmentsMic:   [SegmentRef] = []

    // Writers ativos (1 por fonte). Substituídos a cada novo segmento.
    private var writerScreen: SegmentWriter?
    private var writerCamera: SegmentWriter?
    private var writerMic:    SegmentWriter?

    private var timelinePosition: Double = 0
    private var lastResumeAt: Date?
    private var segmentIndex: Int = 0

    private let sessionDir: URL
    private weak var previewView: ScreenBufferView?
    private var timer: Timer?

    // MARK: Init

    init(config: SourceConfig) {
        self.sourceConfig = config
        let movies = (try? FileManager.default.url(for: .moviesDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let dir = movies.appendingPathComponent(
            "GravadorAulas/Gravacoes/rec-\(UUID().uuidString.prefix(8))")
        self.sessionDir = dir
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        screen.delegate = self
        camera.delegate = self
        mic.delegate = self
    }

    var outputDirectory: URL { sessionDir }
    var cameraPreviewLayer: AVCaptureVideoPreviewLayer { camera.previewLayer }
    var currentTimelineTime: Double {
        timelinePosition + (lastResumeAt.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0)
    }

    func attachPreview(view: ScreenBufferView) {
        self.previewView = view
    }

    // MARK: Preparação

    /// Prepara todos os serviços. Não inicia a captura.
    func prepare() async throws {
        guard state == .idle else { return }
        state = .preparing
        defer {
            if state == .preparing { state = .ready }
        }

        // Tela
        try screen.configure(
            source: sourceConfig.screen,
            frameRate: sourceConfig.frameRate,
            resolution: sourceConfig.resolution,
            captureAudio: sourceConfig.captureSystemAudio
        )

        // Mic (opcional)
        if sourceConfig.captureMicrophone, let m = sourceConfig.microphone {
            do {
                try mic.prepare(deviceRef: m)
            } catch {
                throw RecordingError.deviceUnavailable("microfone — \(error.localizedDescription)")
            }
        }

        // Câmera (opcional)
        if let cam = sourceConfig.camera {
            do {
                try camera.prepare(deviceRef: cam)
                camera.start()
            } catch {
                throw RecordingError.deviceUnavailable("webcam — \(error.localizedDescription)")
            }
        }

        state = .ready
        AppLog.recorder.info("sessão pronta")
    }

    func stopPreviewIfIdle() {
        if state == .ready || state == .idle { camera.stop() }
    }

    // MARK: Início

    func start() async throws {
        guard state == .ready else {
            throw RecordingError.notReady
        }

        // Verifica permissão de captura de tela com stream mínimo ANTES
        // de gastar recursos abrindo arquivos. Isso dispara o prompt do
        // sistema na primeira vez e retorna false se o usuário negar.
        let screenOK = await PermissionsManager.shared.verifyScreenCaptureAccess()
        if !screenOK {
            await MainActor.run {
                self.lastError = "Permissão de Captura de Tela negada. Libere em Ajustes → Privacidade → Gravação de Tela."
            }
            throw RecordingError.startFailed("Sem permissão de captura de tela.")
        }

        state = .recording
        timelinePosition = 0
        elapsed = 0
        segmentIndex = 0
        lastError = nil
        segmentsScreen.removeAll()
        segmentsCamera.removeAll()
        segmentsMic.removeAll()

        // Abre o primeiro segmento para cada fonte
        openScreenSegment()
        openCameraSegment()
        openMicSegment()

        // Inicia serviços
        do {
            let content = try await SCShareableContentProxy.current()
            try await screen.start(content: content)
            if sourceConfig.captureMicrophone, let _ = sourceConfig.microphone {
                mic.start()
            }
            if let _ = sourceConfig.camera {
                camera.start()
            }
        } catch {
            state = .ready
            throw RecordingError.startFailed(error.localizedDescription)
        }

        lastResumeAt = .now
        startTimer()
        AppLog.recorder.info("gravação iniciada")
    }

    // MARK: Pausa / Retomada

    func pause() {
        guard state == .recording else { return }
        if let lastResumeAt {
            timelinePosition += max(0, Date.now.timeIntervalSince(lastResumeAt))
        }
        lastResumeAt = nil
        elapsed = timelinePosition
        state = .paused
        stopTimer()
        Task {
            await screen.stop()
            mic.stop()
            camera.stop()
            await closeAllSegments()
            AppLog.recorder.info("gravação pausada em \(self.timelinePosition)s")
        }
    }

    func resume() async throws {
        guard state == .paused else { return }
        state = .recording
        openScreenSegment()
        openCameraSegment()
        openMicSegment()
        do {
            let content = try await SCShareableContentProxy.current()
            try await screen.start(content: content)
            if sourceConfig.captureMicrophone { mic.start() }
            if sourceConfig.camera != nil { camera.start() }
            lastResumeAt = .now
            startTimer()
            AppLog.recorder.info("gravação retomada em \(self.timelinePosition)s")
        } catch {
            state = .paused
            throw RecordingError.startFailed(error.localizedDescription)
        }
    }

    // MARK: Parada

    @discardableResult
    func stop() async -> RecordingResult {
        guard state == .recording || state == .paused else {
            return RecordingResult(screen: segmentsScreen, camera: segmentsCamera,
                                   mic: segmentsMic, sysAudioIncludedInScreen: sourceConfig.captureSystemAudio,
                                   timelineDuration: timelinePosition,
                                   outputDirectory: sessionDir)
        }
        if state == .recording, let lastResumeAt {
            timelinePosition += max(0, Date.now.timeIntervalSince(lastResumeAt))
        }
        lastResumeAt = nil
        elapsed = timelinePosition
        state = .stopping
        stopTimer()
        await screen.stop()
        mic.stop()
        camera.stop()
        await closeAllSegments()

        let result = RecordingResult(
            screen: segmentsScreen,
            camera: segmentsCamera,
            mic:   segmentsMic,
            sysAudioIncludedInScreen: sourceConfig.captureSystemAudio,
            timelineDuration: max(timelinePosition,
                segmentsScreen.map { $0.timelineStart + $0.duration }.max() ?? 0),
            outputDirectory: sessionDir
        )
        state = .idle
        AppLog.recorder.info("gravação parada; duração=\(self.timelinePosition)s, segmentos(screen=\(self.segmentsScreen.count),cam=\(self.segmentsCamera.count),mic=\(self.segmentsMic.count))")
        return result
    }

    // MARK: Timer de elapsed

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let start = lastResumeAt else { return }
        elapsed = timelinePosition + Date.now.timeIntervalSince(start)
    }

    // MARK: Segmentos

    private func nextURL(_ name: String, ext: String = "mp4") -> URL {
        let url = sessionDir.appendingPathComponent("\(name)-\(String(format: "%03d", segmentIndex)).\(ext)")
        return url
    }

    private func openScreenSegment() {
        segmentIndex += 1 // usado por todos para manter a contagem coerente
        let url = nextURL("screen")
        do {
            let w = try SegmentWriter(
                url: url,
                kind: .screen,
                timelineStart: timelinePosition,
                videoSize: currentScreenSize(),
                frameRate: sourceConfig.frameRate,
                videoBitrate: sourceConfig.quality.bitsPerSecond,
                audioBitrate: sourceConfig.quality.audioBitrate,
                recordAudio: sourceConfig.captureSystemAudio
            )
            writerScreen = w
            AppLog.recorder.info("segmento de tela aberto: \(url.lastPathComponent, privacy: .public)")
        } catch {
            AppLog.recorder.error("erro criando segmento de tela: \(error.localizedDescription, privacy: .public)")
            lastError = "Falha criando arquivo de tela: \(error.localizedDescription)"
        }
    }

    private func openCameraSegment() {
        guard sourceConfig.camera != nil, sourceConfig.cameraOverlay.enabled, !sourceConfig.cameraOverlay.hidden else {
            writerCamera = nil; return
        }
        let url = nextURL("camera")
        let cameraSize = cameraCaptureSize()
        do {
            let w = try SegmentWriter(
                url: url,
                kind: .camera,
                timelineStart: timelinePosition,
                videoSize: cameraSize,
                frameRate: 30,
                videoBitrate: max(2_000_000, sourceConfig.quality.bitsPerSecond / 3),
                audioBitrate: 0,
                recordAudio: false
            )
            writerCamera = w
            AppLog.recorder.info("segmento de câmera aberto: \(url.lastPathComponent, privacy: .public)")
        } catch {
            AppLog.recorder.error("erro criando segmento de câmera: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cameraCaptureSize() -> CGSize {
        if let dims = camera.previewLayer.connection?.inputPorts.first?
            .formatDescription?.dimensions {
            return CGSize(width: Int(dims.width), height: Int(dims.height))
        }
        return CGSize(width: 1280, height: 720)
    }

    private func openMicSegment() {
        guard sourceConfig.captureMicrophone, sourceConfig.microphone != nil else {
            writerMic = nil; return
        }
        let url = nextURL("mic")
        do {
            let w = try SegmentWriter(
                url: url,
                kind: .microphone,
                timelineStart: timelinePosition,
                videoSize: .zero,
                frameRate: 0,
                videoBitrate: 0,
                audioBitrate: sourceConfig.quality.audioBitrate,
                recordAudio: true
            )
            writerMic = w
            AppLog.recorder.info("segmento de mic aberto: \(url.lastPathComponent, privacy: .public)")
        } catch {
            AppLog.recorder.error("erro criando segmento de mic: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeAllSegments() async {
        if let s = writerScreen { await s.finish(); segmentsScreen.append(s.ref) }
        if let c = writerCamera { await c.finish(); segmentsCamera.append(c.ref) }
        if let m = writerMic    { await m.finish(); segmentsMic.append(m.ref) }
        writerScreen = nil; writerCamera = nil; writerMic = nil
    }

    private func currentScreenSize() -> CGSize {
        if let size = sourceConfig.resolution.pixelSize { return size }
        // matchDisplay
        let d = NSScreen.main ?? NSScreen.screens.first
        return d?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    // MARK: Processamento de buffers

    fileprivate nonisolated func ingest(screenBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        Task { @MainActor in
            switch type {
            case .screen:
                self.writerScreen?.append(sample: screenBuffer, isVideo: true)
                if let pb = CMSampleBufferGetImageBuffer(screenBuffer) {
                    self.previewView?.latestPixelBuffer = pb
                }
            case .audio:
                self.writerScreen?.append(sample: screenBuffer, isVideo: false)
                self.updateAudioLevel(buffer: screenBuffer, target: \.sysAudioLevel)
            case .microphone:
                // Reservado para Etapa 4 (microfone via SCStream).
                break
            @unknown default:
                break
            }
        }
    }

    fileprivate nonisolated func ingest(cameraBuffer: CMSampleBuffer) {
        Task { @MainActor in
            self.writerCamera?.append(sample: cameraBuffer, isVideo: true)
        }
    }

    fileprivate nonisolated func ingest(micBuffer: CMSampleBuffer) {
        Task { @MainActor in
            self.writerMic?.append(sample: micBuffer, isVideo: false)
            self.updateAudioLevel(buffer: micBuffer, target: \.micLevel)
        }
    }

    fileprivate nonisolated func handle(screenError: Error?) {
        Task { @MainActor in
            if let e = screenError {
                self.lastError = "Captura de tela parou: \(e.localizedDescription)"
                AppLog.screen.error("delegate parou com erro: \(e.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateAudioLevel(buffer: CMSampleBuffer, target: ReferenceWritableKeyPath<RecordingSession, Float>) {
        guard let blockBuffer = buffer.dataBuffer else { return }
        let count = Int(buffer.numSamples)
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
        data.withUnsafeBytes { buf in
            let s16 = buf.bindMemory(to: Int16.self)
            for i in 0..<min(s16.count, count) {
                let v = abs(Float(s16[i]) / 32768.0)
                if v > peak { peak = v }
            }
        }
        self[keyPath: target] = min(1.0, peak)
    }
}

// MARK: - Delegates

extension RecordingSession: ScreenCaptureServiceDelegate {
    nonisolated func screenCapture(_ service: ScreenCaptureService,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   type: SCStreamOutputType) {
        ingest(screenBuffer: sampleBuffer, type: type)
    }
    nonisolated func screenCapture(_ service: ScreenCaptureService, didStopWithError error: Error?) {
        handle(screenError: error)
    }
}

extension RecordingSession: CameraServiceDelegate {
    nonisolated func cameraService(_ service: CameraService, didOutput sampleBuffer: CMSampleBuffer) {
        ingest(cameraBuffer: sampleBuffer)
    }
    nonisolated func cameraService(_ service: CameraService, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = "Webcam: \(error.localizedDescription)"
        }
    }
}

extension RecordingSession: MicServiceDelegate {
    nonisolated func micService(_ service: MicService, didOutput sampleBuffer: CMSampleBuffer) {
        ingest(micBuffer: sampleBuffer)
    }
    nonisolated func micService(_ service: MicService, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = "Microfone: \(error.localizedDescription)"
        }
    }
}

// MARK: - SegmentWriter

/// Encapsula um AVAssetWriter para um segmento. Pode ter trilha de vídeo
/// e/ou de áudio. Suporta alimentação fora de ordem de mídia (áudio chega
/// antes do vídeo e vice-versa) via fila serial.
final class SegmentWriter: @unchecked Sendable {

    enum Track { case video, audio }

    private(set) var ref: SegmentRef
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput?
    let audioInput: AVAssetWriterInput?
    private(set) var started = false
    private(set) var finishedFlag = false
    private let queue = DispatchQueue(label: "gravadoraulas.writer.\(UUID().uuidString.prefix(6))")
    private let recordVideo: Bool
    private let recordAudio: Bool

    init(url: URL,
         kind: TrackKind,
         timelineStart: Double,
         videoSize: CGSize,
         frameRate: Int,
         videoBitrate: Int,
         audioBitrate: Int,
         recordAudio: Bool) throws {
        self.ref = SegmentRef(id: UUID(), kind: kind, url: url,
                              duration: 0, timelineStart: timelineStart)
        self.recordVideo = videoSize != .zero && videoBitrate > 0
        self.recordAudio = recordAudio && audioBitrate > 0

        self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        if self.recordVideo {
            let codecProps: [String: Any] = [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: max(1, frameRate * 2),
            ]
            let vSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width.rounded()),
                AVVideoHeightKey: Int(videoSize.height.rounded()),
                AVVideoCompressionPropertiesKey: codecProps,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
            vi.expectsMediaDataInRealTime = true
            if writer.canAdd(vi) { writer.add(vi); self.videoInput = vi }
            else { self.videoInput = nil }
        } else {
            self.videoInput = nil
        }

        if self.recordAudio {
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: audioBitrate,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) { writer.add(ai); self.audioInput = ai }
            else { self.audioInput = nil }
        } else {
            self.audioInput = nil
        }
    }

    // PTS do primeiro sample de cada trilha. Usado para definir o tempo
    // inicial da sessão de escrita do AVAssetWriter, evitando que o MP4
    // final fique com duração de horas (porque os PTS do SCStream/AVCapture
    // são em mach_absolute_time).
    private var firstVideoPTS: CMTime?
    private var firstAudioPTS: CMTime?
    private var videoSampleCount: Int = 0
    private var audioSampleCount: Int = 0

    func append(sample: CMSampleBuffer, isVideo: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.finishedFlag else { return }

            let input = isVideo ? self.videoInput : self.audioInput
            guard let input else { return }

            // Rastreia o PTS do primeiro sample de cada trilha.
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
            if isVideo {
                if self.firstVideoPTS == nil {
                    self.firstVideoPTS = samplePTS
                    AppLog.recorder.info("primeiro PTS de vídeo: \(samplePTS.seconds, privacy: .public)s")
                }
                self.videoSampleCount += 1
                if self.videoSampleCount == 1 || self.videoSampleCount % 30 == 0 {
                    AppLog.recorder.info("vídeo: \(self.videoSampleCount) frames (PTS \(samplePTS.seconds, privacy: .public)s)")
                }
            } else {
                if self.firstAudioPTS == nil {
                    self.firstAudioPTS = samplePTS
                    AppLog.recorder.info("primeiro PTS de áudio: \(samplePTS.seconds, privacy: .public)s")
                }
                self.audioSampleCount += 1
            }
            // Inicia a sessão no PTS mais cedo entre as trilhas que já vimos.
            // O AVAssetWriter interpreta isso como o início do arquivo:
            // samples com PTS >= startTime são gravados normalmente; samples
            // anteriores seriam cortados. Como estamos alimentando o PTS
            // original, isso resulta em um arquivo com duração correta.
            if !self.started {
                let earliest = self.earliestPTS() ?? samplePTS
                self.writer.startWriting()
                self.writer.startSession(atSourceTime: earliest)
                self.started = true
            }

            guard input.isReadyForMoreMediaData else { return }
            input.append(sample)
        }
    }

    private func earliestPTS() -> CMTime? {
        switch (firstVideoPTS, firstAudioPTS) {
        case (.some(let v), .some(let a)): return CMTimeMinimum(v, a)
        case (.some(let v), .none):        return v
        case (.none, .some(let a)):        return a
        case (.none, .none):               return nil
        }
    }

    func finish() async {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                if !self.started {
                    // Nenhum sample chegou: só abrimos o arquivo para
                    // gerar um MP4 válido (vazio).
                    self.writer.startWriting()
                    self.writer.startSession(atSourceTime: .zero)
                    self.started = true
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.writer.finishWriting {
                    self.finishedFlag = true
                    if self.writer.status == .completed {
                        let url = self.ref.url
                        Task {
                            let dur = await AVURLAsset.duration(url: url)
                            await MainActor.run {
                                self.ref.duration = dur
                                cont.resume()
                            }
                        }
                    } else {
                        AppLog.export.error("finishWriting não completou: status=\(self.writer.status.rawValue, privacy: .public) err=\(self.writer.error?.localizedDescription ?? "-", privacy: .public)")
                        cont.resume()
                    }
                }
            }
        }
    }
}

extension AVURLAsset {
    static func duration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            return CMTimeGetSeconds(d)
        } catch {
            return 0
        }
    }
}
