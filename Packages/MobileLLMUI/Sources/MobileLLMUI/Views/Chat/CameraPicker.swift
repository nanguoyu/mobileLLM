// SPDX-License-Identifier: MIT

#if os(iOS)
import SwiftUI
import UIKit

/// The camera capture sheet for composer attachments — `UIImagePickerController` in `.camera` mode
/// (PhotosPicker has no capture path). iOS-only: macOS has no equivalent flow, and Continuity Camera
/// arrives for free through the system clipboard + the Paste action.
struct CameraPicker: UIViewControllerRepresentable {
    /// Receives the captured photo as encoded JPEG bytes (nil on cancel). The caller downscales via the
    /// same `chat.attach(imageData:)` path every other attachment source uses.
    var onCapture: (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // 0.9 keeps detail for the downstream 1568px re-encode; the attach path owns the real budget.
            let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9)
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
