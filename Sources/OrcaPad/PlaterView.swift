import OrcaBridge
import SwiftUI
import UniformTypeIdentifiers

/// Presentation-only plater shell. Engine/file/job orchestration lives in the
/// process-lifetime AppEnvironment stores and services.
struct PlaterView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var importPresented = false
    @State private var objectsPresented = false
    @State private var settingsPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 3) {
                Text("OrcaPad")
                    .font(.caption.weight(.semibold))
                ForEach(environment.status.visibleEntries) { entry in
                    Text(entry.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(entry.subsystem == .slice ? 3 : 2)
                }
            }
            .padding(10)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let selection = environment.document.selection,
                   let object = environment.document.scene?.object(
                       id: selection.objectID
                   ),
                   !object.instances.isEmpty {
                    selectionHUD(for: selection, object: object)
                }
                platerToolbar
            }
            .padding(.bottom, 14)
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: ImportTypes.stl,
            onCompletion: handleImport
        )
        .sheet(isPresented: $objectsPresented) { objectsList }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(presets: environment.presets)
        }
    }

    @ViewBuilder
    private var canvas: some View {
        let document = environment.document
        if let scene = document.scene {
            MetalCanvas(
                onStatus: {
                    environment.status.report(.renderer, $0)
                },
                scene: SceneSync(
                    snapshot: scene,
                    selectedObjectID: document.selection?.objectID,
                    selectedInstanceID: document.selection?.instanceID,
                    previewTransform: document.previewTransform,
                    presentationRevision: document.presentationRevision,
                    frameRequest: document.frameRequest
                ),
                onSelect: { objectID, instanceID in
                    document.select(
                        objectID: objectID,
                        instanceID: instanceID
                    )
                },
                onMoveSelected: { delta in
                    document.moveSelected(by: delta)
                },
                onMoveEnded: {
                    Task { await document.commitSelectedTransform() }
                }
            )
        } else {
            Color(red: 0.075, green: 0.078, blue: 0.093)
        }
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            Task {
                if !environment.document.isReady {
                    await environment.bootstrap()
                }
                guard environment.document.isReady else { return }
                await environment.document.importModel(from: url)
            }
        case .failure(let error):
            environment.status.report(
                .document,
                failure: AppFailure.wrap(
                    error,
                    operation: "choose import file"
                )
            )
        }
    }

    @ViewBuilder
    private func selectionHUD(
        for selection: InstanceSelection,
        object: SceneObject
    ) -> some View {
        let ordinal = (object.instances.firstIndex {
            $0.id == selection.instanceID
        } ?? 0) + 1
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("instance \(ordinal)/\(object.instances.count) · drag to move")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
            Divider().frame(height: 30)
            HUDButton(symbol: "rotate.left", label: "−45°") {
                rotateSelected(by: -45)
            }
            HUDButton(symbol: "rotate.left", label: "−15°") {
                rotateSelected(by: -15)
            }
            HUDButton(symbol: "rotate.right", label: "+15°") {
                rotateSelected(by: 15)
            }
            HUDButton(symbol: "rotate.right", label: "+45°") {
                rotateSelected(by: 45)
            }
            Divider().frame(height: 30)
            HUDButton(symbol: "plus.rectangle.on.rectangle", label: "Copy") {
                Task {
                    await environment.document.addInstance(
                        to: selection.objectID
                    )
                }
            }
            HUDButton(symbol: "trash", label: "Del inst") {
                Task {
                    if object.instances.count > 1 {
                        await environment.document.deleteInstance(
                            selection.instanceID,
                            of: selection.objectID
                        )
                    } else {
                        await environment.document.deleteObject(
                            selection.objectID
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func rotateSelected(by degrees: Double) {
        Task {
            await environment.document.rotateSelected(by: degrees)
        }
    }

    private var objectsList: some View {
        let objects = environment.document.scene?.objects ?? []
        return NavigationStack {
            Group {
                if objects.isEmpty {
                    Text("No objects — import an STL")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(objects) { object in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(object.name).lineLimit(1)
                                    Text("\(object.instances.count) instance(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task {
                                        await environment.document.addInstance(
                                            to: object.id
                                        )
                                    }
                                } label: {
                                    Image(
                                        systemName: "plus.rectangle.on.rectangle"
                                    )
                                }
                                .buttonStyle(.borderless)
                                Button {
                                    Task {
                                        await environment.document.deleteObject(
                                            object.id
                                        )
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                environment.document.select(
                                    objectID: object.id,
                                    instanceID: object.instances.first?.id
                                )
                                objectsPresented = false
                            }
                        }
                        .onDelete { indexSet in
                            let objectIDs = indexSet.map { objects[$0].id }
                            Task {
                                await environment.document.deleteObjects(
                                    objectIDs
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Objects")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { objectsPresented = false }
                }
            }
        }
    }

    private var platerToolbar: some View {
        let document = environment.document
        return HStack(spacing: 22) {
            ToolbarButton(
                symbol: "plus",
                label: "Import",
                disabled: document.isBusy
            ) { importPresented = true }
            ToolbarButton(
                symbol: "list.bullet",
                label: "Objects",
                disabled: document.scene?.objects.isEmpty != false ||
                    document.isMutating
            ) { objectsPresented = true }
            ToolbarButton(
                symbol: "arrow.2.circlepath",
                label: "Arrange",
                disabled: true
            ) {
                // Phase 2: engine arrange (Arrange.cpp + libnest2d).
            }
            ToolbarButton(
                symbol: "scissors",
                label: document.isSlicing ? "Slicing" : "Slice",
                disabled: document.scene?.objects.isEmpty != false ||
                    document.isBusy || environment.presets.isSelecting
            ) {
                Task {
                    await environment.slicing.run(
                        document: document,
                        presets: environment.presets
                    )
                }
            }
            ToolbarButton(
                symbol: "gearshape",
                label: "Settings",
                disabled: !environment.presets.isReady || document.isSlicing
            ) {
                settingsPresented = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private enum ImportTypes {
    static let stl: [UTType] = {
        guard let type = UTType(filenameExtension: "stl") else {
            preconditionFailure("iOS did not provide an STL content type")
        }
        return [type]
    }()
}

private struct ToolbarButton: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .secondary : .primary)
        .environment(\.isEnabled, !disabled)
    }
}

private struct HUDButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(minWidth: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
