import Foundation
import SwiftData

struct Revision: Codable, Identifiable {
    var id: String
    var imported = Date()
    var date: Date
    var rooms: [Room]
    var unresolved: Int
}

struct Day: Codable, Identifiable {
    var id: Date { date }
    var date: Date
    var rooms: [Room]
    var revisions: [Revision]
}

struct Ledger: Codable {
    var settings = Settings()
    var days: [Day] = []
}

enum ImportDiff {
    static func changes(from old: [Room], to new: [Room]) -> [String] {
        let incoming = Set(new.map(\.number))
        let prior = Set(old.filter { !$0.superseded }.map(\.number))
        var results = incoming.subtracting(prior).sorted().map { "新增 \($0)" }
        results += prior.subtracting(incoming).sorted().map { "表中移除 \($0)" }
        for room in new {
            guard let previous = old.first(where: { $0.number == room.number && !$0.superseded }) else { continue }
            var fields: [String] = []
            if previous.kind != room.kind { fields.append("类型") }
            if previous.guests != room.guests { fields.append("人数") }
            if previous.employee != room.employee { fields.append("担当者") }
            if previous.notes != room.notes || previous.marks != room.marks { fields.append("备注") }
            if !fields.isEmpty { results.append("\(room.number) · \(fields.joined(separator: "、"))") }
        }
        return results
    }

    static func merge(_ old: [Room], _ incoming: [Room]) -> [Room] {
        let newNumbers = Set(incoming.map(\.number))
        let updated = incoming.map { room in
            guard let prior = old.first(where: { $0.number == room.number }) else { return room }
            var result = room
            result.id = prior.id
            result.work = prior.work
            result.prepared = prior.prepared
            result.removed = prior.removed
            result.typeOverride = prior.typeOverride
            result.quantities.merge(prior.quantities) { _, previous in previous }
            result.order = prior.order
            result.audit = prior.audit + room.audit
            let fields = changes(from: [prior], to: [room])
            if let summary = fields.first {
                result.audit.append(Audit(description: "修订确认 · \(summary) · 原担当者 \(prior.employee) · 原人数 \(prior.guests.map(String.init) ?? "未填写") · 原类型 \(prior.kind.rawValue) · 原备注 \(prior.notes)"))
            }
            return result
        }
        let archived = old.filter { !newNumbers.contains($0.number) }.map { room in
            var result = room
            if !result.superseded { result.audit.append(Audit(description: "修订表已移除此房间")) }
            result.superseded = true
            return result
        }
        return updated + archived
    }
}

@Model final class LedgerRecord {
    @Attribute(.unique) var key: String
    var data: Data

    init(data: Data) {
        key = "HotelFlow"
        self.data = data
    }
}

struct Backup: Codable {
    var ledger: Ledger
    var documents: [String: Data]
}
