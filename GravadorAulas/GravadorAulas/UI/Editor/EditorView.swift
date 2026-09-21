//
//  EditorView.swift
//  GravadorAulas
//
//  Tela 3: revisão e edição da aula gravada.
//
//  Etapa 1: timeline visual, clipes clicáveis, inspector com ações
//            básicas (deletar, fade in/out, volume), controles de playhead.
//
//  Etapa 2 amplia: trim preciso, split no playhead, anotações, undo/redo,
//                  destaque do cursor.
//

import SwiftUI
import AVKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var previewVM = PreviewViewModel()

    @State private var player: AVPlayer?
    @State private var showExportSheet = false
    @State private var showTranscriptionPanel = false
    @State private var showChaptersPanel = false
    @State private var showPrivacyPanel = false
    @State private var privacyDraftRect = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.15)

    // Edição
    @State private var selectedClipKey: String? = nil    // "trackKind:clipId"
    @State private var inspectorClip: Clip? = nil         // clipe selecionado para o sheet
    @State private var playhead: Double = 0               // segundos
    @State private var undoStack: [Project] = []
    @State private var redoStack: [Project] = []

    var body: some View {
        HSplitView {
            timelineColumn
                .frame(minWidth: 480)
            sideColumn
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await preparePreview() }
                } label: {
                    Label("Visualizar", systemImage: "play.rectangle")
                }
                .disabled(previewVM.isWorking || env.lastRecordingResult == nil)

                Button { showExportSheet = true } label: {
                    Label("Exportar MP4", systemImage: "square.and.arrow.up")
                }
                .disabled(env.currentProject == nil)

                Button {
                    Task { await importVideo() }
                } label: {
                    Label("Importar vídeo", systemImage: "film")
                }
                .disabled(env.currentProject == nil || env.lastRecordingResult == nil)

                Button {
                    importImage()
                } label: {
                    Label("Importar imagem", systemImage: "photo.badge.plus")
                }
                .disabled(env.currentProject == nil || env.lastRecordingResult == nil)

                Button {
                    revealRecordingInFinder()
                } label: {
                    Label("Mostrar gravações no Finder", systemImage: "folder")
                }
                .disabled(env.lastRecordingResult?.outputDirectory == nil)

                Divider()

                Button { undoEdit() } label: {
                    Label("Desfazer", systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command])

                Button { redoEdit() } label: {
                    Label("Refazer", systemImage: "arrow.uturn.forward")
                }
                .disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Button {
                    selectedClipKey = nil
                    inspectorClip = nil
                } label: {
                    Label("Limpar seleção", systemImage: "rectangle.dashed")
                }
                .disabled(selectedClipKey == nil)
            }
        }
        .sheet(isPresented: Binding(
            get: { inspectorClip != nil },
            set: { if !$0 { inspectorClip = nil; selectedClipKey = nil } }
        )) {
            if let clip = inspectorClip {
                ClipInspectorSheet(
                    clip: clip,
                    onApply: { applyEdit($0, to: clip) },
                    onDelete: { deleteClip(clip) }
                )
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(isPresented: $showExportSheet)
        }
    }

    // MARK: - Timeline column

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player {
                    ZStack {
                        NativePlayerView(player: player)
                        if showPrivacyPanel {
                            PrivacySelectionOverlay(rect: $privacyDraftRect,
                                regions: env.currentProject?.privacyRegions ?? [])
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                } else {
                    placeholderPreview
                }

                if previewVM.isWorking {
                    statusOverlay
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.black)

            Divider()

            timelineBar
                .frame(height: 180)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    @ViewBuilder
    private var placeholderPreview: some View {
        VStack(spacing: 12) {
            if env.lastRecordingResult == nil {
                Text("Nenhuma gravação")
                    .foregroundStyle(.secondary)
            } else {
                if let err = previewVM.errorMessage {
                    Label("Falha ao visualizar", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Text("Dica: apague os segmentos antigos em $TMPDIR/GravadorAulas/ e grave novamente.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("Pronto para visualizar")
                        .foregroundStyle(.secondary)
                }
                Button(previewVM.errorMessage == nil ? "Visualizar gravação" : "Tentar novamente") {
                    Task { await preparePreview() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewVM.isWorking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(previewVM.phaseLabel)
                .foregroundStyle(.white)
            if let err = previewVM.errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(24)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Timeline bar (cliques nos clipes abrem inspector)

    private var timelineBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Linha do tempo")
                    .font(.headline)
                Spacer()
                Text(timecode(playhead))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("/")
                    .foregroundStyle(.secondary)
                Text(timecode(env.currentProject?.timeline.duration ?? 0))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(env.currentProject?.timeline.tracks ?? []) { track in
                            HStack(spacing: 6) {
                                Image(systemName: icon(for: track.kind))
                                    .frame(width: 18)
                                Text(label(for: track.kind))
                                    .frame(width: 90, alignment: .leading)
                                    .font(.caption)

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .frame(height: 22)
                                    ForEach(track.clips) { clip in
                                        clipView(clip, in: track)
                                    }
                                }
                                .frame(height: 22)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Playhead
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 7 * 28)
                        .offset(x: CGFloat(playhead) * pixelsPerSecond + 110)
                        .allowsHitTesting(false)
                }
                .frame(minWidth: CGFloat((env.currentProject?.timeline.duration ?? 60)) * pixelsPerSecond + 120)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let localX = max(0, value.location.x - 110)
                        playhead = Double(localX / pixelsPerSecond)
                    }
            )

            // Controles do playhead
            HStack(spacing: 16) {
                Button {
                    playhead = 0
                } label: { Image(systemName: "backward.end.fill") }

                Button {
                    if let player {
                        player.pause()
                        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600))
                        player.play()
                    }
                } label: { Image(systemName: "play.fill") }
                    .disabled(player == nil)

                Button {
                    playhead = env.currentProject?.timeline.duration ?? 0
                } label: { Image(systemName: "forward.end.fill") }

                Spacer()

                Text("Clique em um clipe para editar")
                    .font(.caption).foregroundStyle(.secondary)

                Spacer()

                Text("\(env.currentProject?.timeline.tracks.flatMap(\.clips).count ?? 0) clipes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Text("Dica: arraste na régua para mover o playhead. Selecione um clipe para ajustar o início, o fim ou dividir no playhead.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func clipView(_ clip: Clip, in track: Track) -> some View {
        let startX = CGFloat(clip.timelineStart) * pixelsPerSecond
        let width = CGFloat(clip.timelineDuration) * pixelsPerSecond
        let key = "\(track.kind.rawValue):\(clip.id.uuidString)"
        let selected = selectedClipKey == key
        return RoundedRectangle(cornerRadius: 4)
            .fill(color(for: track.kind).opacity(selected ? 1.0 : 0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.white : Color.clear, lineWidth: 2)
            )
            .frame(width: max(4, width), height: 22)
            .offset(x: startX)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedClipKey = key
                inspectorClip = clip
            }
            .help("\(label(for: track.kind)) • \(timecode(clip.timelineStart)) → \(timecode(clip.timelineStart + clip.timelineDuration))")
    }

    private var pixelsPerSecond: CGFloat { 30 }
    private func timecode(_ s: Double) -> String { s.hmsString }

    private func icon(for kind: TrackKind) -> String {
        switch kind {
        case .screen: return "display"
        case .camera: return "camera"
        case .microphone: return "mic"
        case .systemAudio: return "speaker.wave.2"
        case .image: return "photo"
        case .text: return "text.alignleft"
        case .effect: return "wand.and.stars"
        }
    }

    private func label(for kind: TrackKind) -> String {
        switch kind {
        case .screen: return "Tela"
        case .camera: return "Webcam"
        case .microphone: return "Microfone"
        case .systemAudio: return "Sistema"
        case .image: return "Imagens"
        case .text: return "Textos"
        case .effect: return "Efeitos"
        }
    }

    private func color(for kind: TrackKind) -> Color {
        switch kind {
        case .screen: return .blue
        case .camera: return .purple
        case .microphone: return .pink
        case .systemAudio: return .teal
        case .image: return .yellow
        case .text: return .orange
        case .effect: return .indigo
        }
    }

    // MARK: - Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Projeto") {
                    Text(env.currentProject?.name ?? "—")
                    Text(env.currentProject?.modifiedAt.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Revisão") {
                    Toggle("Transcrição", isOn: $showTranscriptionPanel)
                    Toggle("Capítulos", isOn: $showChaptersPanel)
                    Toggle("Regiões de privacidade", isOn: $showPrivacyPanel)
                }

                Section("Visualização de teclas") {
                    if env.keycast.isRunning {
                        Label("Capturando", systemImage: "keyboard.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Desligado", systemImage: "keyboard")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Dicas de edição") {
                    Label("Clique em um clipe na timeline para abrir o inspector.",
                          systemImage: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("Arraste na régua cinza para mover o playhead.",
                          systemImage: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)

            Divider()

            if showTranscriptionPanel {
                TranscriptionPanelView().frame(minHeight: 200)
            }
            if showChaptersPanel {
                ChaptersPanelView().frame(minHeight: 200)
            }
            if showPrivacyPanel {
                PrivacyRegionsView(draftRect: $privacyDraftRect).frame(minHeight: 200)
            }

            Spacer()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Edit actions

    enum EditAction {
        case deleteClip
        case setVolume(Float)
        case setMuted(Bool)
        case addFadeIn(Double)
        case addFadeOut(Double)
        case splitAtPlayhead
        case trimStart(Double)
        case trimEnd(Double)
    }

    private func applyEdit(_ action: EditAction, to clip: Clip) {
        guard var project = env.currentProject else { return }

        switch action {
        case .deleteClip:
            project.timeline.tracks = project.timeline.tracks.map { track in
                var t = track
                t.clips.removeAll { $0.id == clip.id }
                return t
            }

        case .setVolume(let v):
            project.timeline.tracks = project.timeline.tracks.map { track in
                var t = track
                if t.clips.contains(where: { $0.id == clip.id }) {
                    t.volume = v
                }
                return t
            }

        case .setMuted(let m):
            project.timeline.tracks = project.timeline.tracks.map { track in
                var t = track
                if t.clips.contains(where: { $0.id == clip.id }) {
                    t.muted = m
                }
                return t
            }

        case .addFadeIn(let d):
            applyEffect(.fadeIn, to: clip, in: &project, duration: d)

        case .addFadeOut(let d):
            applyEffect(.fadeOut, to: clip, in: &project, duration: d)

        case .splitAtPlayhead:
            splitClip(clip, at: playhead, in: &project)

        case .trimStart(let amount):
            for i in project.timeline.tracks.indices {
                if let j = project.timeline.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) {
                    let current = project.timeline.tracks[i].clips[j]
                    let n = max(0, min(amount, current.sourceDuration - 0.05))
                    project.timeline.tracks[i].clips[j].sourceStart += n
                    project.timeline.tracks[i].clips[j].sourceDuration -= n
                    project.timeline.tracks[i].clips[j].timelineStart += n
                    break
                }
            }

        case .trimEnd(let amount):
            for i in project.timeline.tracks.indices {
                if let j = project.timeline.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) {
                    let current = project.timeline.tracks[i].clips[j]
                    let n = max(0, min(amount, current.sourceDuration - 0.05))
                    project.timeline.tracks[i].clips[j].sourceDuration -= n
                    break
                }
            }
        }

        project.modifiedAt = .now
        undoStack.append(env.currentProject!)
        redoStack.removeAll()
        env.currentProject = project
        AppLog.editor.info("edit aplicado: \(String(describing: action), privacy: .public)")
    }

    private func applyEffect(_ kind: EffectDescriptor.Kind,
                             to clip: Clip,
                             in project: inout Project,
                             duration: Double) {
        for i in project.timeline.tracks.indices {
            if let ci = project.timeline.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) {
                project.timeline.tracks[i].clips[ci].effects.append(
                    EffectDescriptor(kind: kind,
                        start: kind == .fadeOut
                            ? max(clip.timelineStart, clip.timelineStart + clip.timelineDuration - duration)
                            : clip.timelineStart,
                        duration: duration)
                )
                return
            }
        }
    }

    private func splitClip(_ clip: Clip, at time: Double, in project: inout Project) {
        guard time > clip.timelineStart,
              time < clip.timelineStart + clip.timelineDuration else { return }
        let offset = time - clip.timelineStart
        let first = Clip(
            id: UUID(),
            assetURL: clip.assetURL,
            sourceStart: clip.sourceStart,
            sourceDuration: offset,
            timelineStart: clip.timelineStart,
            effects: clip.effects,
            annotations: clip.annotations
        )
        let second = Clip(
            id: UUID(),
            assetURL: clip.assetURL,
            sourceStart: clip.sourceStart + offset,
            sourceDuration: clip.sourceDuration - offset,
            timelineStart: time,
            effects: [],
            annotations: []
        )
        for i in project.timeline.tracks.indices {
            if let ci = project.timeline.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) {
                project.timeline.tracks[i].clips.remove(at: ci)
                project.timeline.tracks[i].clips.insert(contentsOf: [first, second], at: ci)
                return
            }
        }
    }

    private func deleteClip(_ clip: Clip) {
        applyEdit(.deleteClip, to: clip)
        inspectorClip = nil
        selectedClipKey = nil
    }

    private func undoEdit() {
        guard let previous = undoStack.popLast(), let current = env.currentProject else { return }
        redoStack.append(current)
        env.currentProject = previous
        player = nil
    }

    private func redoEdit() {
        guard let next = redoStack.popLast(), let current = env.currentProject else { return }
        undoStack.append(current)
        env.currentProject = next
        player = nil
    }

    // MARK: - Preview

    private func importVideo() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard duration.isFinite, duration > 0, var project = env.currentProject,
                  let index = project.timeline.tracks.firstIndex(where: { $0.kind == .screen }) else { return }
            let start = project.timeline.duration
            project.timeline.tracks[index].clips.append(Clip(
                id: UUID(), assetURL: url, sourceStart: 0,
                sourceDuration: duration, timelineStart: start))
            project.timeline.duration += duration
            project.modifiedAt = .now
            env.currentProject = project
            player = nil
        } catch {
            previewVM.reportError("Não foi possível importar o vídeo: \(error.localizedDescription)")
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              var project = env.currentProject,
              let trackIndex = project.timeline.tracks.firstIndex(where: { $0.kind == .screen }),
              let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: {
                  playhead >= $0.timelineStart && playhead < $0.timelineStart + $0.timelineDuration
              }) else { return }
        let remaining = project.timeline.duration - playhead
        project.timeline.tracks[trackIndex].clips[clipIndex].annotations.append(Annotation(
            kind: .image, start: playhead, duration: min(5, remaining),
            rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            text: url.absoluteString))
        project.modifiedAt = .now
        env.currentProject = project
        player = nil
    }

    private func revealRecordingInFinder() {
        guard let dir = env.lastRecordingResult?.outputDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func preparePreview() async {
        guard let result = env.lastRecordingResult else {
            previewVM.errorMessage = "Sem gravação disponível."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString.prefix(6)).mp4")
        let preset = ExportPreset.defaultPresets.first!
        player = nil
        previewVM.start()
        defer { previewVM.stop() }

        await env.exporter.export(
            result: result,
            preset: preset,
            outputURL: url,
            cameraOverlay: env.sourceConfig.cameraOverlay,
            includeCamera: env.sourceConfig.camera != nil && !env.sourceConfig.cameraOverlay.hidden,
            micVolume: env.currentProject?.timeline.track(.microphone)?.volume ?? 1.0,
            systemVolume: env.currentProject?.timeline.track(.systemAudio)?.volume ?? 0.7,
            project: env.currentProject
        )

        switch env.exporter.status {
        case .finished(let u):
            AppLog.editor.info("preview pronto: \(u.path, privacy: .public)")
            await installPlayer(url: u)
        case .failed(let m):
            previewVM.errorMessage = m
            AppLog.editor.error("preview falhou: \(m, privacy: .public)")
        case .cancelled:
            previewVM.errorMessage = "Cancelado"
        default:
            previewVM.errorMessage = "Estado inválido"
        }
    }

    private func installPlayer(url: URL) async {
        let p = AVPlayer(url: url)
        self.player = p
        p.play()
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct PrivacySelectionOverlay: View {
    @Binding var rect: CGRect
    let regions: [PrivacyRegion]
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(regions) { region in
                    Rectangle()
                        .stroke(.orange, lineWidth: 2)
                        .background(.orange.opacity(0.15))
                        .frame(width: region.rect.width * geometry.size.width,
                               height: region.rect.height * geometry.size.height)
                        .offset(x: region.rect.minX * geometry.size.width,
                                y: region.rect.minY * geometry.size.height)
                }
                Rectangle()
                    .stroke(.cyan, lineWidth: 3)
                    .background(.cyan.opacity(0.18))
                    .frame(width: rect.width * geometry.size.width,
                           height: rect.height * geometry.size.height)
                    .offset(x: rect.minX * geometry.size.width,
                            y: rect.minY * geometry.size.height)
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            let start = dragStart ?? value.startLocation
                            dragStart = start
                            let x1 = min(max(0, start.x / geometry.size.width), 1)
                            let y1 = min(max(0, start.y / geometry.size.height), 1)
                            let x2 = min(max(0, value.location.x / geometry.size.width), 1)
                            let y2 = min(max(0, value.location.y / geometry.size.height), 1)
                            rect = CGRect(x: min(x1, x2), y: min(y1, y2),
                                          width: abs(x2 - x1), height: abs(y2 - y1))
                        }
                        .onEnded { _ in dragStart = nil })
            }
        }
    }
}

// MARK: - Preview VM

@MainActor
final class PreviewViewModel: ObservableObject {
    @Published var isWorking = false
    @Published var phaseLabel = ""
    @Published var errorMessage: String?

    func start() {
        isWorking = true
        phaseLabel = "Compondo…"
        errorMessage = nil
    }

    func updatePhase(_ s: String) { phaseLabel = s }
    func reportError(_ m: String) { errorMessage = m; phaseLabel = "Falhou" }

    func stop() {
        isWorking = false
        phaseLabel = ""
    }
}

// MARK: - Clip Inspector Sheet

struct ClipInspectorSheet: View {
    let clip: Clip
    let onApply: (EditorView.EditAction) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fadeInDuration: Double = 0.5
    @State private var fadeOutDuration: Double = 0.5
    @State private var volume: Float = 1.0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Editar clipe")
                    .font(.title2.bold())
                Spacer()
                Button("Fechar") { dismiss() }
            }

            GroupBox("Informações") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Início").foregroundStyle(.secondary)
                        Spacer()
                        Text(clip.timelineStart.hmsString).monospacedDigit()
                    }
                    HStack {
                        Text("Duração").foregroundStyle(.secondary)
                        Spacer()
                        Text(clip.timelineDuration.hmsString).monospacedDigit()
                    }
                    HStack {
                        Text("Arquivo").foregroundStyle(.secondary)
                        Spacer()
                        Text(clip.assetURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.callout)
            }

            GroupBox("Volume (trilha de áudio)") {
                VStack {
                    Slider(value: $volume, in: 0...1)
                    HStack {
                        Text("0%").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Text("\(Int(volume*100))%").monospacedDigit()
                        Spacer()
                        Text("100%").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .onChange(of: volume) { _, newValue in
                    onApply(.setVolume(newValue))
                }
            }

            GroupBox("Fade") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fade in:").frame(width: 90, alignment: .leading)
                        Slider(value: $fadeInDuration, in: 0...3, step: 0.1)
                        Text("\(fadeInDuration, specifier: "%.1f")s")
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                        Button("Aplicar") {
                            onApply(.addFadeIn(fadeInDuration))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    HStack {
                        Text("Fade out:").frame(width: 90, alignment: .leading)
                        Slider(value: $fadeOutDuration, in: 0...3, step: 0.1)
                        Text("\(fadeOutDuration, specifier: "%.1f")s")
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                        Button("Aplicar") {
                            onApply(.addFadeOut(fadeOutDuration))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            GroupBox("Aparar clipe") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Remover do início")
                        Slider(value: $trimStart, in: 0...max(0.01, clip.sourceDuration - 0.05))
                        Text("\(trimStart, specifier: "%.1f")s")
                        Button("Aplicar") { onApply(.trimStart(trimStart)); dismiss() }
                    }
                    HStack {
                        Text("Remover do fim")
                        Slider(value: $trimEnd, in: 0...max(0.01, clip.sourceDuration - 0.05))
                        Text("\(trimEnd, specifier: "%.1f")s")
                        Button("Aplicar") { onApply(.trimEnd(trimEnd)); dismiss() }
                    }
                }
            }

            GroupBox("Dividir / Excluir") {
                HStack(spacing: 12) {
                    Button {
                        onApply(.splitAtPlayhead)
                    } label: {
                        Label("Dividir no playhead", systemImage: "scissors")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Excluir clipe", systemImage: "trash")
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 540)
    }
}

// MARK: - Observer token

private final class ObserverToken: @unchecked Sendable {
    var observer: NSObjectProtocol?
    var resumed = false
    var onFinish: (() -> Void)?
}
