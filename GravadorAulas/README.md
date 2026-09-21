# Gravador de Aulas — macOS nativo (Apple Silicon)

App nativo em Swift/SwiftUI para gravar e editar videoaulas no macOS 13+ (Apple Silicon, arm64). Usa ScreenCaptureKit para tela e áudio do sistema, AVFoundation para câmera/microfone, e prepara a infraestrutura para transcrição on-device em pt-BR (SFSpeechRecognizer).

## Requisitos

- macOS 13.0 (Ventura) ou superior
- Apple Silicon (M1/M2/M3/M4)
- Xcode 15+ instalado (`xcode-select --install` para Command Line Tools, ou instalar Xcode pela App Store)
- Permissões: Microfone, Captura de Tela, Câmera, Reconhecimento de Fala e Acessibilidade (esta última só para a Etapa 4 — visualização de teclas)

## Como compilar e rodar

1. **Abra o projeto no Xcode**

   ```bash
   cd GravadorAulas
   open GravadorAulas.xcodeproj
   ```

   O Xcode vai ler o `xcshareddata/xcschemes/GravadorAulas.xcscheme`. Use o scheme `GravadorAulas` já configurado.

2. **Selecione o time "Sign to Run Locally"** (automático, sem team) ou configure seu Apple ID em *Signing & Capabilities*.

3. **Run** (`⌘R`). O Xcode compila para o destino My Mac.

4. Na primeira execução o macOS pede permissões de **Microfone** e **Captura de Tela**. Conceda as duas. A permissão de captura é do sistema: *Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela*.

## Arquitetura

```
GravadorAulas/
  GravadorAulas.xcodeproj/         ← projeto Xcode (gerado)
  GravadorAulas/
    App/                           ← entry, AppEnvironment
    Core/
      Models/                      ← Project, Timeline, Clip, Track, SourceConfig, ExportPreset
      Capture/                     ← ScreenCaptureService, CameraService, MicService,
                                    RecordingSession (orquestrador), KeyCastService
      Project/                     ← ProjectStore (JSON)
      Timeline/                    ← TimelineBuilder
      Effects/                     ← EffectApplier (CIFilter prontos p/ Etapa 4)
      Transcription/               ← Transcriber (SFSpeechRecognizer) + FillerDetector
      Export/                      ← Compositor (AVMutableComposition) + Exporter
    UI/
      SourceSelection/             ← escolha de fontes (Etapa 1)
      Recording/                   ← tela de captura + controles
      Editor/                      ← timeline simples + export sheet
      Transcription/ Chapters/
      Effects/ Export/             ← painéis (stubs para Etapas 3 e 4)
    Utilities/                     ← Logger, Permissions, CMTimeFormatting, PreviewViews
    Resources/                     ← Info.plist, .entitlements, Assets.xcassets
```

### Princípios

- Cada fonte grava em **MP4 segmentado** (um arquivo por bloco pause/resume).
- A composição final é via `AVMutableComposition` no `Exporter`.
- Tudo local. `SFSpeechRecognizer.requiresOnDeviceRecognition = true` quando suportado.
- UI nunca bloqueia: gravação/transcrição/export rodam em `Task`/`actor`.

## Onde a saída vai

- **Gravações brutas (segmentos)**: `${TMPDIR}/GravadorAulas/rec-XXXXXXXX/`
  - No macOS 13+ isso resolve para `/var/folders/<hash>/T/GravadorAulas/rec-XXXXXXXX/`
  - Use o botão **"Mostrar gravações no Finder"** na aba Revisão para abrir a pasta.
- **Projetos editáveis**: `~/Movies/GravadorAulas/Projetos/*.gaulasproj.json`
- **Exports MP4**: o usuário escolhe via `NSSavePanel` (qualquer pasta)
- **Lista de capítulos `.txt`**: ao lado do MP4 exportado + copiada para clipboard

Para localizar segmentos antigos via terminal:
```bash
echo "$TMPDIR"
ls "$TMPDIR/GravadorAulas/"
```

## Etapa 1 — MVP (entregue)

O que funciona ao rodar o app:

1. **Fontes**
   - Seleção de display, janela ou região retangular (com picker de região)
   - Lista de câmeras (incluindo externas em macOS 14+) e microfones
   - Resolução (720p/1080p/1440p/4K/nativa), 30/60 fps, qualidade (Leve/Máx.)
   - Toggle de captura de áudio do sistema e microfone

2. **Gravação**
   - Botão Gravar com contagem regressiva de 3 s
   - Pausa/Retomada (cada retomada abre novo segmento MP4)
   - Parada (limpa buffers, finaliza segmentos)
   - Medidores de nível de microfone e áudio do sistema em tempo real
   - Prévia da tela na própria janela
   - Recuperação parcial: cada segmento é um MP4 válido — se o app cair, todos os segmentos já finalizados podem ser reutilizados

3. **Exportação**
   - Sheet com presets (Plataforma 1080p / Upload leve 720p / Alta qualidade 60fps)
   - Sliders independentes de volume do microfone e do áudio do sistema
   - Personalização do preset (largura/altura/fps/bitrate/legendas incorporadas)
   - Escolha de destino (.mp4 via NSSavePanel)
   - Progresso e cancelamento
   - Lista de capítulos (.txt) colada na área de transferência automaticamente
   - Compõe tudo: tela + áudio do sistema + microfone + (overlay) webcam

### Limitamente conhecidas na Etapa 1

- A pré-visualização ao vivo da webcam está conectada, mas a renderização dentro do `VideoPlayer` é via `AVAssetExportSession`. Para a Etapa 2 substituímos por um player dedicado com controle de tempo.
- Não há ainda undo/redo, trim/split interativo, fade-in/out na timeline (stubs prontos em `Core/Timeline/`).
- A orientação da tela é herdada do SCStream; em monitores externos muito grandes pode haver pequena diferença de aspecto até calibrarmos `sourceRect`.

## Como testar a Etapa 1

1. **Compile e rode** (`⌘R`).
2. Na aba **Fontes**:
   - Selecione um display e uma webcam (se disponível)
   - Conceda as permissões
   - Clique **Continuar →**
3. Na aba **Gravação**:
   - Aguarde a contagem regressiva
   - Fale algo, mova o mouse
   - Pause por alguns segundos e retome
   - Clique **Parar**
4. Na aba **Revisão**:
   - Clique **Visualizar** (gera um MP4 temporário e toca)
   - Clique **Exportar MP4**, escolha destino e preset
   - Abra o MP4 no QuickTime para conferir sincronia e qualidade
   - Verifique o `.txt` colado com a lista de capítulos

## Próximas etapas (placeholders funcionais)

- **Etapa 2 — Editor completo**: trim/split, fade, volumes por clipe, anotações, destaque do cursor, undo/redo, atalhos. Veja `Core/Timeline/TimelineBuilder.swift` (esqueleto pronto).
- **Etapa 3 — Transcrição**: pt-BR on-device, edição por transcrição, detecção de fillers/silêncios, SRT. Veja `Core/Transcription/Transcriber.swift`.
- **Etapa 4 — Capítulos, teclas, privacidade, intro/outro**: `Core/Capture/KeyCastService.swift` já tem o CGEventTap com política de privacidade; `Core/Effects/Effects.swift` tem os CIFilter de blur/pixelização.
- **Etapa 5 — Testes de robustez**: gravações longas, recovery, sync drift, dispositivos desconectados.

## Permissões e privacidade

- O app **não roda em sandbox** (`Resources/GravadorAulas.entitlements`). Isso é necessário porque `CGEventTap` (keycast) e `SCStream` com áudio têm comportamento limitado sob sandbox nesta versão. Para distribuição direta (Developer ID) esta é a configuração correta.
- O `KeyCastService` só registra teclas com modificador (`⌘`, `⌃`, `⌥`, `⇧`). Nunca armazena texto bruto.
- `SFSpeechRecognizer.requiresOnDeviceRecognition = true` quando o reconhecedor local está disponível — nenhum áudio sai do dispositivo.
- A região de privacidade (Etapa 4) usa `CIFilter.boxBlur` e `CIFilter.pixellate` localmente.

## Problemas comuns

| Sintoma | Causa provável | Solução |
|---|---|---|
| Botão Gravar desabilitado | Permissão de tela negada | Ajustes → Privacidade → Gravação de Tela → habilitar o app |
| Sem dispositivos de áudio | Permissão de microfone negada | Ajustes → Privacidade → Microfone |
| Tela preta na pré-visualização | SCStream ainda em inicialização | Aguarde 1–2 s após “Preparando” |
| Exportação lenta | Qualidade “Alta” em vídeo 4K | Reduza resolução no preset |
| Câmera externa não aparece | macOS 13 não tem `.externalUnknown` | Atualize para macOS 14+ ou conecte antes de abrir o app |

## Build manual sem Xcode (limitado)

```bash
cd GravadorAulas
swift build  # não gera um .app funcional — só checa sintaxe. Para gravar é preciso Xcode.
```

## Aviso

Este projeto foi gerado para o usuário `Mestre Endy` em um Mac com Apple Silicon rodando macOS 27. O deployment target é 13.0. APIs exclusivas de 14+ ficam atrás de `#available(macOS 14, *)`.