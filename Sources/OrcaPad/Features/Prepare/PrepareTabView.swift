import SwiftUI

/// Prepare tab (desktop parity): machine / filament / process selection and
/// the full generated settings editor with simple/advanced/expert filtering,
/// plus the slice action. Scaffolded in Gate C1; the desktop-parity editors
/// land in Gate C2.
struct PrepareTabView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                selectionSection
                configSection
                sliceSection
            }
            .navigationTitle("Prepare")
        }
    }

    private var selectionSection: some View {
        Section("Presets") {
            NavigationLink {
                PresetPickerView(presets: environment.presets)
            } label: {
                Label(
                    environment.presets.selection.machine.isEmpty
                        ? "Select machine" : environment.presets.selection.machine,
                    systemImage: "printer"
                )
            }
            LabeledContent("Filament") {
                Text(environment.presets.selection.filament)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Process") {
                Text(environment.presets.selection.process)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var configSection: some View {
        Section {
            NavigationLink {
                ResolvedConfigView(presets: environment.presets)
            } label: {
                Label("Resolved configuration", systemImage: "doc.text.magnifyingglass")
            }
        } footer: {
            Text("Every value the slicer will use, merged from the selected presets.")
        }
    }

    private var sliceSection: some View {
        Section {
            Button {
                Task {
                    await environment.slicing.run(
                        document: environment.document,
                        presets: environment.presets
                    )
                }
            } label: {
                Label(
                    environment.slicing.progress != nil
                        ? "Slicing… \(environment.slicing.progress?.percent ?? 0)%"
                        : "Slice Plate",
                    systemImage: "scissors"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .disabled(
                environment.document.scene?.objects.isEmpty != false ||
                    environment.document.isBusy ||
                    environment.presets.isSelecting
            )
        } footer: {
            if let failure = environment.slicing.lastFailure {
                Text("Last slice failed: \(failure.localizedDescription)")
                    .foregroundStyle(.red)
            } else if let outcome = environment.slicing.lastOutcome {
                Text(
                    "G-code ready — \(outcome.outputURL.lastPathComponent) " +
                        "(~\(Int(outcome.result.timeEstimateSeconds / 60)) min)"
                )
            }
        }
    }
}
