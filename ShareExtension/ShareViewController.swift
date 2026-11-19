import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()
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
        let stack = UIStackView(arrangedSubviews: [status, done])
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
            guard (try? Inbox.folder()) != nil else {
                status.text = "分享扩展无法访问共享容器。请先在 LINE 中将 PDF 存到「文件」，再从 HotelFlow 导入。"
                done.isEnabled = true
                return
            }
            var received = 0
            for provider in providers {
                if (try? await Self.receive(provider)) != nil { received += 1 }
            }
            if received == 0 {
                status.text = "未收到本地 PDF。请在 LINE 中打开并下载 PDF，再使用系统分享，或先存储到「文件」。"
            } else if received < providers.count {
                status.text = "已接收 \(received) 份 PDF，部分文件失败。打开 HotelFlow 查看。"
            } else {
                status.text = "已接收 \(received) 份 PDF，打开 HotelFlow 查看。"
            }
            done.isEnabled = true
        }
    }

    private static func receive(_ provider: NSItemProvider) async throws {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let data = try? await readFile(provider, type: .pdf) {
                try Inbox.enqueue(data)
                return
            }
            if let data = try? await readData(provider, type: .pdf) {
                try Inbox.enqueue(data)
                return
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let data = try? await readData(provider, type: .fileURL) {
            try Inbox.enqueue(data)
            return
        }
        if provider.registeredTypeIdentifiers.contains(UTType.data.identifier) {
            let data: Data
            if let file = try? await readFile(provider, type: .data) { data = file }
            else { data = try await readData(provider, type: .data) }
            try Inbox.enqueue(data)
            return
        }
        throw PDFInput.Failure.invalid
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
        extensionContext?.completeRequest(returningItems: nil)
    }
}
