//
//  Transcriber.swift
//  GravadorAulas
//
//  Transcrição pt-BR on-device via SFSpeechRecognizer.
//  Detecta fillers ("é...", "ah...", "hum...") e silêncios.
//  Gera sugestões de corte que o usuário pode aceitar ou rejeitar.
//

import Foundation
import Speech
import AVFoundation
import Accelerate

@MainActor
final class Transcriber: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case finished
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var segments: [TranscriptionSegment] = []
    @Published private(set) var suggestions: [CutSuggestion] = []

    private let recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    override init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
        super.init()
    }

    var onDeviceSupported: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    /// Executa a transcrição completa sobre o arquivo de áudio.
    func transcribe(audioURL: URL) async {
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Reconhecedor indisponível")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true
        request.taskHint = .dictation

        state = .running
        segments = []
        suggestions = []

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let mapped = result.bestTranscription.segments.map { seg in
                        TranscriptionSegment(
                            text: seg.substring,
                            start: seg.timestamp,
                            end: seg.timestamp + seg.duration
                        )
                    }
                    Task { @MainActor in
                        self.segments = mapped
                        if result.isFinal {
                            self.state = .finished
                            cont.resume()
                        }
                    }
                } else if let error {
                    Task { @MainActor in
                        self.state = .failed(error.localizedDescription)
                        cont.resume()
                    }
                }
            }
        }
    }

    /// Cancela a transcrição em curso.
    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Classifica segmentos com "filler" e gera sugestões de silêncio.
    /// Deve ser chamado depois de `transcribe()` terminar.
    func analyzeForEditing(minSilenceSeconds: Double = 0.6) {
        // 1) Fillers
        let withFillers = FillerDetector.detect(in: segments)
        self.segments = withFillers

        // 2) Silêncios entre segmentos consecutivos
        var sugs: [CutSuggestion] = []
        for i in 0..<withFillers.count - 1 {
            let end = withFillers[i].end
            let nextStart = withFillers[i + 1].start
            let gap = nextStart - end
            if gap >= minSilenceSeconds {
                sugs.append(CutSuggestion(
                    kind: .silence,
                    start: end,
                    end: nextStart,
                    description: "Silêncio de \(String(format: "%.1f", gap))s"
                ))
            }
        }
        // 3) Fillers viram sugestões
        for seg in withFillers where seg.kind == "filler" {
            sugs.append(CutSuggestion(
                kind: .filler,
                start: seg.start,
                end: seg.end,
                description: "Expressão de preenchimento: “\(seg.text)”"
            ))
        }
        self.suggestions = sugs
    }

    /// Exporta os segmentos como SRT.
    func writeSRT(to url: URL) throws {
        let body = segments.enumerated().map { idx, seg in
            let i = idx + 1
            return "\(i)\n\(seg.start.srtTimestamp) --> \(seg.end.srtTimestamp)\n\(seg.text)\n"
        }.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Modelo de sugestões

struct CutSuggestion: Identifiable, Equatable {
    enum Kind: String, Equatable { case silence, filler }
    let id = UUID()
    let kind: Kind
    let start: Double
    let end: Double
    let description: String
    var duration: Double { end - start }
}

// MARK: - Detector de fillers

enum FillerDetector {
    static let patterns = [
        "é...", "eh...", "ée", "éé",
        "ah...", "ah", "áh",
        "hum...", "uhm...", "hm...",
        "tipo...", "tipo",
        "né...", "né", "naquele...",
        "tipo assim", "sei lá",
        "então...", "então",
    ]

    static func classify(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return patterns.contains { lower.contains($0) }
    }

    static func detect(in segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.map { seg in
            var s = seg
            if classify(seg.text) { s.kind = "filler" }
            return s
        }
    }
}