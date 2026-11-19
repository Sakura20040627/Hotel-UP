import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController, UIDocumentPickerDelegate {
    private let status = UILabel()
    private let saveToFiles = UIButton(type: .system)
    private var exportFolder: URL?
    private var exportFiles: [URL] = []
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = "正在接收 PDF…"
        status.numberOfLines = 0
        status.textAlignment = .center
        done.setTitle("完成", for: .normal)
        done.isEnabled = false
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        saveToFiles.setTitle("存到「文件」", for: .normal)
        saveToFiles.isHidden = true
        saveToFiles.addTarget(self, action: #selector(exportPDFs), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, saveToFiles, done])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter {
                $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ||
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
                $0.registeredTypeIdentifiers.contains(UTType.data.identifier)
            }
        Task {
            var received = 0
            for provider in providers {
                guard let data = try? await Self.receive(provider) else { continue }
                do {
                    try Inbox.enqueue(data)
                    received += 1
                } catch {
                    try? prepareExport(data)
                }
            }
            if !exportFiles.isEmpty {
                status.text = "有 \(exportFiles.count) 份 PDF 需要存到「文件」，然后在 HotelFlow 里导入。"
                saveToFiles.isHidden = false
            } else if received == 0 {
                status.text = "无法读取或保存 PDF。请在 LINE 中打开并下载文件，再使用系统分享。"
            } else if received < providers.count {
                status.text = "已接收 \(received) 份 PDF，部分文件失败。打开 HotelFlow 查看。"
            } else {
                status.text = "已接收 \(received) 份 PDF，打开 HotelFlow 查看。"
            }
            done.isEnabled = true
        }
    }

    private static func receive(_ provider: NSItemProvider) async throws -> Data {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let data = try? await readFile(provider, type: .pdf) { return data }
            if let data = try? await readData(provider, type: .pdf) { return data }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let data = try? await readData(provider, type: .fileURL) { return data }
        if provider.registeredTypeIdentifiers.contains(UTType.data.identifier) {
            if let data = try? await readFile(provider, type: .data) { return data }
            return try await readData(provider, type: .data)
        }
        throw PDFInput.Failure.invalid
    }

    private func prepareExport(_ data: Data) throws {
        let folder: URL
        if let exportFolder {
            folder = exportFolder
        } else {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            exportFolder = folder
        }
        let file = folder.appendingPathComponent("HotelFlow-\(UUID().uuidString.prefix(8)).pdf")
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        exportFiles.append(file)
    }

    @objc private func exportPDFs() {
        let picker = UIDocumentPickerViewController(forExporting: exportFiles, asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        status.text = "已存到「文件」。请打开 HotelFlow，点「导入今日清扫 PDF」。"
        saveToFiles.isHidden = true
    }

    private static func readFile(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                continuation.resume(with: Result {
                    guard let url else { throw error ?? PDFInput.Failure.invalid }
                    return try PDFInput.read(url)
                })
            }
        }
    }

    private static func readData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        if type == .fileURL {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                    continuation.resume(with: Result {
                        if let url = item as? URL { return try PDFInput.read(url) }
                        if let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) { return try PDFInput.read(url) }
                        throw error ?? PDFInput.Failure.invalid
                    })
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                continuation.resume(with: Result {
                    guard let data else { throw error ?? PDFInput.Failure.invalid }
                    try PDFInput.validate(data)
                    return data
                })
            }
        }
    }

    @objc private func close() {
        if let exportFolder { try? FileManager.default.removeItem(at: exportFolder) }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
