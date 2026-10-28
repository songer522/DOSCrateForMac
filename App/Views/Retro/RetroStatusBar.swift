import LauncherKit
import SwiftUI

struct RetroStatusBar: View {
    let model: AppModel

    private var controllerStatus: ControllerStatus? {
        ControllerStatus.make(model.gamepads.devices, enabled: model.prefs.useControllers)
    }

    var body: some View {
        if let progress = model.imports.progress {
            bar(cancellable: true) {
                progressBar(current: progress.current, total: progress.total)
                Text(progress.label)
            }
        } else if model.isScanningLibrary {
            bar(cancellable: true) {
                Text("Looking for games…")
            }
        } else if model.imports.isCheckingDuplicates {
            bar(cancellable: true) {
                Text("Checking for duplicates…")
            }
        } else if let removal = model.removalProgress {
            bar(cancellable: false) {
                progressBar(current: removal.done, total: removal.total)
                Text("Removing \(removal.done) of \(removal.total)…")
            }
        } else if let metadataText = model.metadata.statusText {
            bar(cancellable: false) {
                if case .downloading(let fraction) = model.metadata.phase {
                    progressBar(current: Int((min(1.0, max(0.0, fraction)) * 100).rounded()), total: 100)
                } else if let findProgress = model.metadata.findMissingProgress {
                    progressBar(current: findProgress.current, total: findProgress.total)
                }
                Text(metadataText)
                if Self.showsMetadataRetry(for: model) {
                    Button("Retry") { model.metadata.retry() }
                        .buttonStyle(RetroButtonStyle(kind: .text))
                } else if Self.showsFindMissingCancel(for: model) {
                    Button("Cancel") { model.metadata.cancelFindMissing() }
                        .buttonStyle(RetroButtonStyle(kind: .text))
                } else if Self.showsUnmatchedReview(for: model) {
                    Button("Review") { model.showingUnmatchedMetadata = true }
                        .buttonStyle(RetroButtonStyle(kind: .text))
                }
            }
        } else if controllerStatus != nil {
            bar(cancellable: false) {}
        }
    }

    static func leadingText(for model: AppModel) -> String? {
        LibraryView.statusBarLeadingText(for: model)
    }

    static func showsMetadataRetry(for model: AppModel) -> Bool {
        LibraryView.showsMetadataRetry(for: model)
    }

    static func showsUnmatchedReview(for model: AppModel) -> Bool {
        LibraryView.showsUnmatchedReview(for: model)
    }

    static func showsFindMissingCancel(for model: AppModel) -> Bool {
        LibraryView.showsFindMissingCancel(for: model)
    }

    private func bar(cancellable: Bool, @ViewBuilder _ items: () -> some View) -> some View {
        HStack(spacing: 10) {
            items()
                .font(RetroFont.font())
                .foregroundStyle(RetroPalette.shadow)
            Spacer()
            if let status = controllerStatus {
                HStack(spacing: 6) {
                    PixelSymbol("gamecontroller",
                                color: status.enabled ? RetroPalette.desktop : RetroPalette.bevelDark,
                                pointSize: 16,
                                scale: 1)
                    Text(status.label)
                        .font(RetroFont.font())
                        .foregroundStyle(status.enabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                }
            }
            if cancellable {
                Button("Cancel") { model.cancelImport() }
                    .buttonStyle(RetroButtonStyle(kind: .text))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RetroPalette.panel)
        .retroBevel(.sunken)
    }

    private func progressBar(current: Int, total: Int) -> some View {
        let fraction = min(1.0, max(0.0, Double(current) / Double(max(total, 1))))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RetroPalette.bevelLight
                RetroPalette.highlight
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(width: 160, height: 14)
        .retroBevel(.sunken)
    }
}
