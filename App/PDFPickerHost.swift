import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PDFPickerHost: UIViewControllerRepresentable {
    var requested: Bool
    let onSelection: (URL?) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onSelection = onSelection
        controller.requested = requested
        controller.presentPickerIfReady()
    }

    final class Controller: UIViewController, UIDocumentPickerDelegate {
        var requested = false
        var onSelection: ((URL?) -> Void)?
        private var scheduled = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentPickerIfReady()
        }

        func presentPickerIfReady() {
            guard requested, !scheduled, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            scheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                scheduled = false
                guard requested, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .data], asCopy: true)
                picker.delegate = self
                present(picker, animated: true)
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            requested = false
            onSelection?(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            requested = false
            onSelection?(nil)
        }
    }
}
