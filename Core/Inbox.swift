import Foundation
import CryptoKit

enum Inbox {
    static var group: String? {
        Bundle.main.object(forInfoDictionaryKey: "HotelFlowAppGroup") as? String
    }

    static func folder() throws -> URL {
        guard let group, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let result = root.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult static func enqueue(_ data: Data) throws -> URL {
        let destination = try folder().appendingPathComponent(digest(data) + ".pdf")
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw error }
        return destination
    }
}
