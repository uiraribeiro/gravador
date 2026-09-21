# Gravador de Aulas — Orientações do projeto

App **SwiftUI nativo para macOS 13.0+ (Apple Silicon)** que grava e edita videoaulas. Usa `ScreenCaptureKit` (tela + áudio do sistema), `AVFoundation` (webcam, microfone, composição, exportação) e `SFSpeechRecognizer` (transcrição pt-BR on-device, Etapa 3).

> Antes de editar qualquer arquivo Swift, **sempre rode `pwd`** para confirmar que está em `/Volumes/Lacie/Documentos/empresa/Gravador/GravadorAulas/...` e não em outro clone/projeto.

## Como abrir e rodar

```bash
cd /Volumes/Lacie/Documentos/empresa/Gravador/GravadorAulas
open GravadorAulas.xcodeproj
# Xcode 15+ → ⌘R
```

O scheme compartilhado já está configurado em `GravadorAulas.xcodeproj/xcshareddata/xcschemes/GravadorAulas.xcscheme`.

**Deployment target:** macOS 13.0 (Ventura). Recursos exclusivos do Sonoma ficam atrás de `#available(macOS 14, *)` (ex.: `AVCaptureDevice.DeviceType.externalUnknown`).

## Layout

```
GravadorAulas/
├── GravadorAulas.xcodeproj/         ← projeto Xcode (gerado à mão)
│   └── project.pbxproj
├── GravadorAulas/
│   ├── App/                         ← @main, AppEnvironment
│   ├── Core/
│   │   ├── Models/                  ← Project, Timeline, Clip, Track,
│   │   │                              SourceConfig, ExportPreset, Chapter
│   │   ├── Capture/                 ← ScreenCaptureService (SCStream),
│   │   │                              CameraService, MicService,
│   │   │                              RecordingSession (orquestrador),
│   │   │                              DeviceDiscovery, KeyCastService
│   │   ├── Project/                 ← ProjectStore (JSON em ~/Movies)
│   │   ├── Timeline/                ← TimelineBuilder
│   │   ├── Effects/                 ← EffectApplier, CIFilter pré-fabricados
│   │   ├── Transcription/           ← Transcriber, FillerDetector
│   │   └── Export/                  ← Compositor (AVMutableComposition),
│   │                                  Exporter (AVAssetExportSession)
│   ├── UI/
│   │   ├── SourceSelection/         ← Etapa 1
│   │   ├── Recording/               ← Etapa 1
│   │   ├── Editor/                  ← timeline visual + export sheet
│   │   ├── Transcription/ Chapters/ Effects/ Export/  ← stubs Etapas 2-4
│   ├── Utilities/                   ← Logger, Permissions, CMTimeFormatting,
│   │                                  PreviewViews (NSView wrappers)
│   └── Resources/
│       ├── Info.plist               ← permissões TCC + localização pt-BR
│       ├── GravadorAulas.entitlements
│       └── Assets.xcassets/
├── docs/                            ← reservado para ADRs e notas
├── README.md                        ← manual de uso
└── CLAUDE.md                        ← este arquivo
```

## Princípios de design

1. **Cada fonte grava em MP4 segmentado.** Tela (+ system audio), câmera e mic têm `SegmentWriter`s independentes. Pausa = `finishWriting` no segmento atual; retomada = novo segmento com PTS reiniciado. Cada segmento é um MP4 válido isolado — útil para crash recovery.
2. **Composição final é feita na exportação**, nunca em tempo real. `Compositor.compose` junta os segmentos via `AVMutableComposition` com offsets calculados pela `RecordingSession` (`timelinePosition`).
3. **UI nunca bloqueia.** Captura roda em serial queues dedicadas; transcrição e exportação são `Task`s. O `@MainActor` é exclusivo da UI.
4. **Local-first.** `SFSpeechRecognizer.requiresOnDeviceRecognition = true` quando suportado. Nenhum upload silencioso.

## Convenções

- **Idioma do código**: identificadores em inglês; comentários, mensagens de UI, strings de log em **português brasileiro**.
- **Logging**: use os canais em `Utilities/Logger.swift` (`AppLog.recorder`, `.capture`, `.camera`, `.mic`, `.screen`, `.export`, `.editor`, `.transc`, `.chapter`, `.keycast`, `.perm`, `.ui`). Nunca use `print`.
- **Threads**:
  - `RecordingSession` é `@MainActor` — publica estado para a UI.
  - Delegates de captura são `nonisolated` e despacham para `MainActor` via `Task { @MainActor in … }`.
  - `SegmentWriter` tem fila serial própria; `append` é thread-safe.
- **Caminhos do `project.pbxproj`**: o root group tem `path = GravadorAulas;` (sem isso o Xcode não acha os fontes porque eles vivem em `GravadorAulas/GravadorAulas/…`).
- **Build settings relativos** ficam em `GravadorAulas/Resources/...` (já relativo a `SRCROOT`).

## Permissões e privacidade

| Chave | Onde | Por quê |
|---|---|---|
| `NSMicrophoneUsageDescription` | Info.plist | mic do professor |
| `NSCameraUsageDescription` | Info.plist | webcam (overlay) |
| `NSScreenCaptureUsageDescription` | Info.plist | SCStream |
| `NSSpeechRecognitionUsageDescription` | Info.plist | transcrição pt-BR |
| Accessibility (TCC) | runtime | `CGEventTap` do KeyCastService |

**Sandbox desligado** (`Resources/GravadorAulas.entitlements`) — `CGEventTap` e `SCStream` com áudio não funcionam bem sob sandbox. Para Mac App Store será preciso revisar; para Developer ID esta é a config correta.

**Política do KeyCast:** só registra teclas com modificador (`⌘`/`⌃`/`⌥`/`⇧`). Texto digitado nunca é exibido nem armazenado.

## Status das etapas

| Etapa | Estado | Onde mexer |
|---|---|---|
| 1. MVP funcional | **entregue** | `Core/Capture/*`, `Core/Export/*`, `UI/SourceSelection/*`, `UI/Recording/*` |
| 2. Editor (trim/split/fade/anotações/cursor/undo) | não iniciado | `Core/Timeline/TimelineBuilder.swift`, `Core/Effects/Effects.swift`, `UI/Editor/EditorView.swift` |
| 3. Transcrição + fillers + silêncios + SRT | stub compilável | `Core/Transcription/Transcriber.swift`, `UI/Transcription/TranscriptionPanelView.swift` |
| 4. Capítulos + teclas + blur + intro/outro | stub compilável + keycast service real | `Core/Capture/KeyCastService.swift` (real), outros stubs |
| 5. Testes de robustez | pendente | checklist no README.md |

## Onde a saída vai

- **Gravações brutas (segmentos)**: `/tmp/GravadorAulas/rec-XXXXXXXX/` (limpo automaticamente pelo macOS eventualmente; segmentos finalizados são MP4 válidos)
- **Projetos editáveis**: `~/Movies/GravadorAulas/Projetos/*.gaulasproj.json`
- **Exports MP4**: o usuário escolhe via `NSSavePanel`
- **Lista de capítulos `.txt`**: ao lado do MP4 exportado + copiada para clipboard

## Gotchas conhecidos

1. **`AVMutableCompositionTrack.preferredTransform` é read-only.** A rotação/orientação vai via `AVMutableVideoCompositionLayerInstruction.setTransform(_:at:)`. Não tente setar a propriedade.
2. **`AVCaptureDevice.DeviceType.externalUnknown`** só existe a partir de macOS 14. Para 13, use `.external` (deprecated mas funcional).
3. **`onChange(of:)`** com `(oldValue, newValue)` requer macOS 14. Para 13, use a forma legada `{ newValue in … }`.
4. **Sandbox + ScreenCaptureKit com áudio**: incompatível. Já está desligado.
5. **`SCStreamConfiguration.sourceRect`** sobrescreve `width/height` quando setado — certifique-se de que os valores batem com a região escolhida.
6. **`AVAudioSession`** é iOS-only. Não usar no `GravadorAulasApp.init`. No macOS o roteamento de áudio é automático via entitlements.

## Comandos úteis durante desenvolvimento

```bash
# Limpar DerivedData quando o Xcode “esquece” paths
rm -rf ~/Library/Developer/Xcode/DerivedData/GravadorAulas-*

# Ver logs do app em tempo real
log stream --predicate 'subsystem == "com.gravadoraulas.app"'

# Inspecionar segmentos gravados (sem composição)
open -a "QuickTime Player" /tmp/GravadorAulas/rec-*/screen-001.mp4
```

## Quem manter isso

Este CLAUDE.md é lido por Mavis e por Claude Code automaticamente ao iniciar uma sessão neste diretório. Se você adicionar arquivos novos, atualize:
- a seção **Layout** acima;
- o `project.pbxproj` (PBXBuildFile + PBXFileReference + grupo correspondente);
- o `README.md` (se a mudança afetar uso ou troubleshooting).

## prompt inicial

Aqui está o prompt atualizado, com os seis recursos incorporados:
Desenvolva um aplicativo NATIVO para macOS em Apple Silicon (arm64) para gravar e editar videoaulas. Use Swift e SwiftUI. Prefira ScreenCaptureKit para tela e áudio do computador, AVFoundation para câmera, microfone e mídia, e recursos nativos de transcrição quando disponíveis.

Antes de programar, apresente a arquitetura, a versão mínima de macOS, as permissões necessárias e um plano de implementação por etapas. Entregue código compilável e funcionalidades reais, não apenas telas demonstrativas.

OBJETIVO
O professor deve conseguir escolher as fontes, gravar uma aula, fazer edições rápidas e exportar um MP4 sem precisar dominar um editor profissional.

GRAVAÇÃO
- Selecionar monitor, janela ou região retangular da tela, com prévia da área escolhida.
- Selecionar webcam e microfone entre os dispositivos disponíveis, incluindo dispositivos externos.
- Gravar áudio do computador e microfone simultaneamente em trilhas separadas.
- Mostrar prévia da webcam e medidores de áudio.
- Oferecer gravar, contagem regressiva, pausar, retomar e parar. A pausa não deve gerar um trecho vazio.
- Permitir posicionar, redimensionar e ocultar a imagem da webcam.
- Oferecer opções de resolução, 30 ou 60 fps e qualidade.
- Salvar progressivamente e recuperar uma gravação após falha.
- Tratar permissões negadas e dispositivos desconectados com mensagens claras.

EDITOR
- Importar vídeos, imagens e arquivos de áudio.
- Exibir linha do tempo com trilhas separadas para tela, webcam, microfone, áudio do computador, imagens, textos e efeitos.
- Oferecer prévia, forma de onda, zoom da linha do tempo, desfazer/refazer e atalhos de teclado.
- Fazer trim, dividir clipes, remover trechos sem deixar lacunas e aplicar fade-in/fade-out.
- Ajustar separadamente os volumes do microfone e do áudio do computador.
- Oferecer redução de ruído e melhoria da clareza da voz, com comparação antes/depois.
- Inserir setas, círculos, retângulos, textos e imagens rápidas, definindo posição e duração.
- Destacar o cursor com halo e realçar cliques. Permitir ajustar a intensidade do destaque.
- Salvar um projeto editável sem alterar os arquivos originais.

EDIÇÃO ASSISTIDA
- Transcrever a fala em português brasileiro com marcação temporal.
- Permitir editar por meio da transcrição e localizar palavras no vídeo.
- Identificar expressões de preenchimento, como “é...”, “eh...”, “ah...” e “hum...”, e sugerir cortes para revisão.
- Detectar silêncios e sugerir sua remoção automática. Oferecer controles de duração mínima do silêncio, quantidade de pausa a preservar e intensidade da remoção.
- Mostrar uma prévia dos cortes sugeridos. Permitir aceitar ou rejeitar cada sugestão ou aplicar um lote, sempre com desfazer.
- Evitar cortes que eliminem palavras, respirações naturais ou pausas importantes para compreender a aula.
- Gerar legendas editáveis e permitir exportá-las em SRT.

CAPÍTULOS
- Sugerir capítulos por assunto a partir da transcrição, com título e horário de início.
- Permitir criar, renomear, mover, excluir e reorganizar capítulos manualmente.
- Exibir os capítulos na linha do tempo e permitir exportar uma lista de títulos e horários em texto para colar na descrição de uma plataforma de ensino.

TECLAS NA TELA
- Oferecer uma opção para mostrar no vídeo as teclas e atalhos pressionados durante a gravação.
- Permitir escolher posição, tamanho, duração e aparência das indicações.
- Não exibir texto digitado continuamente, senhas ou conteúdo de campos sensíveis. Priorizar atalhos como Command+C e Command+Z.
- Permitir desligar esse recurso a qualquer momento e remover as indicações durante a edição.

PRIVACIDADE VISUAL
- Permitir aplicar desfoque, pixelização ou uma tarja sólida a regiões escolhidas do vídeo.
- Permitir definir quando o efeito começa e termina, além de mover e redimensionar a região protegida.
- Oferecer acompanhamento da região ao longo do vídeo, se for tecnicamente viável; caso contrário, permitir ajustar sua posição com pontos de controle na linha do tempo.
- Mostrar claramente na prévia como ficará o vídeo exportado.

ABERTURA E ENCERRAMENTO
- Permitir criar modelos reutilizáveis de abertura e encerramento com imagem ou vídeo, título, nome do professor, logotipo e música opcional.
- Salvar vários modelos e escolher um deles por projeto.
- Permitir ajustar a duração e aplicar transições simples.
- Garantir que músicas importadas sejam usadas apenas quando o usuário as fornecer.

EXPORTAÇÃO
- Exportar MP4 com vídeo H.264 e áudio AAC.
- Criar presets de exportação para plataformas de ensino, com opções como apresentação em 1080p, vídeo leve para upload e versão em alta qualidade. Mostrar as configurações reais de cada preset e permitir personalizá-las.
- Permitir exportar legendas incorporadas ao vídeo ou em arquivo SRT separado.
- Exportar a lista de capítulos em texto.
- Mostrar progresso, permitir cancelar e relatar erros de forma útil.
- Manter sincronizados tela, webcam, microfone e áudio do computador.

EXPERIÊNCIA E QUALIDADE
- Interface em português brasileiro, com modo claro e escuro e acessibilidade básica.
- Fluxo principal: escolher fontes → conferir prévia e níveis → gravar → revisar → editar → exportar.
- Guardar preferências de dispositivos e exportação.
- Não bloquear a interface durante gravação, transcrição ou exportação.
- Preferir processamento local. Qualquer processamento em nuvem deve exigir escolha explícita do usuário.
- Organizar o código em módulos de captura, sincronização, projeto, linha do tempo, efeitos, transcrição e exportação.
- Confirmar a disponibilidade das APIs na versão mínima de macOS escolhida.

ORDEM DE ENTREGA
1. MVP funcional: seleção de fontes, gravação, pausa, retomada, parada e exportação MP4.
2. Editor: importação, linha do tempo, cortes, áudio, anotações e destaque do cursor.
3. Transcrição, legendas, sugestões de remoção de silêncios e expressões de preenchimento.
4. Capítulos, visualização de atalhos, desfoque, modelos de abertura/encerramento e presets.
5. Testes de gravações longas, recuperação de falhas, sincronização, dispositivos desconectados e exportação.

Ao final de cada etapa, informe o que funciona, como compilar e testar no Xcode e quais limitações ainda existem. Continue até completar o fluxo principal.