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
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        Task {
            var received = 0
            for provider in providers {
                if (try? await Self.receive(provider)) != nil { received += 1 }
            }
            if received == 0 {
                status.text = "无法接收 PDF。请确认文件已下载并检查 HotelFlow 的 App Group 签名。"
            } else if received < providers.count {
                status.text = "已接收 \(received) 份 PDF，部分文件失败。打开 HotelFlow 查看。"
            } else {
                status.text = "已接收 \(received) 份 PDF，打开 HotelFlow 查看。"
            }
            done.isEnabled = true
        }
    }

    private static func receive(_ provider: NSItemProvider) async throws {
        let _: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                continuation.resume(with: Result {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try Inbox.enqueue(Data(contentsOf: url))
                })
            }
        }
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
