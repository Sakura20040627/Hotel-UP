import Foundation

enum PDFInput {
    enum Failure: LocalizedError {
        case invalid, locked

        var errorDescription: String? {
            switch self {
            case .invalid: "此文件不是可读取的 PDF。请打开原文件，重新保存后再导入。"
            case .locked: "此 PDF 有密码。请先将它另存为未加密的 PDF，再导入。"
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw Failure.invalid }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        guard Data(data.prefix(1024)).range(of: Data("%PDF-".utf8)) != nil else {
            throw Failure.invalid
        }
    }
}
