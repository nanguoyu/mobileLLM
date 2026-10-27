// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers
import AgentContracts
import AppUI

/// Bytes have already been verified against the artifact store's original receipt by the app.
public struct WorkflowSavedFile: Sendable, Identifiable {
    public let reference: ArtifactReference
    public let data: Data
    public var id: ArtifactID { reference.id }
    public init(reference: ArtifactReference, data: Data) { self.reference = reference; self.data = data }
}

struct WorkflowSavedFilesView: View {
    let files: [WorkflowSavedFile]
    @State private var selection: WorkflowSavedFile?
    @State private var exporting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Saved files").font(.headline)
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if file.reference.mimeType == "image/jpeg" {
                        if file.reference.semanticType == "sandbox.browser-failure" {
                            Label("Failed browser check", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Theme.danger)
                        }
                        #if os(iOS)
                        if let image = UIImage(data: file.data) {
                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Screenshot from the application check")
                        }
                        #else
                        if let image = NSImage(data: file.data) {
                            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Screenshot from the application check")
                        }
                        #endif
                    }
                    Button {
                        selection = file; exporting = true
                    } label: {
                        Label(file.reference.mimeType == "application/zip" ? "Save project source" : "Save screenshot",
                              systemImage: "square.and.arrow.up")
                            .font(.callout.weight(.medium)).frame(minHeight: 44)
                    }.accessibilityIdentifier("workflow.task.file." + file.id.description)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.danger) }
        }.studioCard()
            .fileExporter(isPresented: $exporting, document: WorkflowFileDocument(data: selection?.data ?? Data()),
                contentType: selection?.reference.mimeType == "application/zip" ? .zip : .jpeg,
                defaultFilename: selection?.reference.mimeType == "application/zip" ? "project-source" : "application-check") { result in
                    if case .failure(let failure) = result { error = failure.localizedDescription }
                    selection = nil
                }
    }
}

private struct WorkflowFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .jpeg] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
