import Foundation

enum Kind: String, Codable, CaseIterable, Identifiable {
    case turnover = "OUT→IN", checkout = "OUT", special = "特殊清扫"
    case checkin = "IN", stay = "S", skip = "清掃不要", unknown = "待确认"
    var id: Self { self }
    var full: Bool { self == .turnover || self == .checkout }
    var cleanable: Bool { full || self == .special }
    var priority: Int {
        switch self { case .turnover: 1; case .checkout: 2; case .special: 3; default: 4 }
    }
}

enum RoomType: String, Codable, CaseIterable, Identifiable {
    case triple = "三人房", quad = "四人房", special = "1103 特殊房"
    var id: Self { self }

    static func inferred(_ room: String) -> Self {
        if room == "1103" { return .special }
        return ["01", "05"].contains(String(room.suffix(2))) ? .triple : .quad
    }
}

enum Supply: String, CaseIterable, Codable, Identifiable {
    case doubleCover = "双人被套", doubleSheet = "双人床单"
    case singleCover = "单人被套", singleSheet = "单人床单", pillow = "枕套"
    case towel = "浴巾", handTowel = "小毛巾", toothbrush = "牙刷", mat = "脚垫"
    var id: Self { self }
    var linen: Bool {
        switch self {
        case .doubleCover, .doubleSheet, .singleCover, .singleSheet, .pillow: true
        default: false
        }
    }
}

enum Stage: String, Codable {
    case waiting = "待清扫", active = "清扫中", inspection = "待检查", done = "已完成"
}

struct Source: Codable, Equatable {
    var page: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var confidence: Double
}

struct Work: Codable, Equatable {
    var stage: Stage = .waiting
    var started: Date?
    var runningSince: Date?
    var finished: Date?
    var pauses: [Date] = []
    var accumulated: TimeInterval = 0
    var checked: Set<Int> = []
    var order = Array(0..<8)

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
    mutating func start(at date: Date) {
        guard stage == .waiting || stage == .active, runningSince == nil else { return }
        if started == nil { started = date }
        stage = .active
        runningSince = date
    }
    mutating func pause(at date: Date) {
        guard runningSince != nil else { return }
        stop(at: date)
        pauses.append(date)
    }
    mutating func inspect(at date: Date) {
        stop(at: date)
        stage = .inspection
    }
    mutating func finish(at date: Date) {
        stop(at: date)
        stage = .done
        finished = date
    }
    mutating func reopen() {
        stage = .inspection
        finished = nil
    }
    private mutating func stop(at date: Date) {
        accumulated = elapsed(at: date)
        runningSince = nil
    }
}

struct Room: Codable, Identifiable, Equatable {
    var id = UUID()
    var number: String
    var kind: Kind = .unknown
    var employee = ""
    var guests: Int?
    var notes = ""
    var marks: [String] = []
    var source: Source?
    var fieldSources: [String: Source]?
    var revision: String?
    var needsReview = false
    var removed = false
    var superseded = false
    var typeOverride: RoomType?
    var quantities: [Supply: Int] = [:]
    var prepared: [Supply: Int] = [:]
    var work = Work()
    var order: Int?
    var audit: [Audit] = []
    var type: RoomType { number == "1103" ? .special : typeOverride ?? RoomType.inferred(number) }
}

struct Audit: Codable, Equatable {
    var date = Date()
    var description: String
}

struct Settings: Codable, Equatable {
    var employee = Bundle.main.object(forInfoDictionaryKey: "HotelFlowEmployee") as? String ?? ""
    var aliases = ""
    var specialCapacity: Int?
    var hotel = Bundle.main.object(forInfoDictionaryKey: "HotelFlowHotel") as? String ?? ""

    func owns(_ room: Room) -> Bool {
        let name = Self.normalized(room.employee)
        let allowed = ([employee] + aliases.components(separatedBy: ",")).map(Self.normalized)
        return !name.isEmpty && allowed.contains(name)
    }
    static func normalized(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Requirement {
    var counts: [Supply: Int]
    var doubles: Int
    var singles: Int
    var guests: Int?
    var guestSource: String
    var warning: String?
}

struct SupplySummary {
    var counts: [Supply: Int] = [:]
    var ready = 0
    var warnings: [UUID: String] = [:]
    var required: Int { counts.values.reduce(0, +) }
}

enum SupplyEngine {
    static func summary(for rooms: [Room], settings: Settings) -> SupplySummary {
        rooms.reduce(into: SupplySummary()) { summary, room in
            let need = requirement(for: room, settings: settings)
            summary.counts.merge(need.counts, uniquingKeysWith: +)
            summary.ready += need.counts.reduce(0) { total, entry in
                total + min(entry.value, room.prepared[entry.key, default: 0])
            }
            summary.warnings[room.id] = need.warning
        }
    }

    static func requirement(for room: Room, settings: Settings) -> Requirement {
        let capacity: Int? = switch room.type {
        case .triple: 3
        case .quad: 4
        case .special: settings.specialCapacity
        }
        let guests = room.guests ?? (room.type == .special ? nil : capacity)
        let doubles = room.type == .special && (guests ?? 0) > 3 ? 2 : 1
        let singles = room.type == .special ? 0 : (room.type == .triple ? 1 : 2)
        let pillows = room.type == .special ? doubles * 2 : (capacity ?? 0)
        let warning: String? = if guests == nil && room.kind.full { "入住人数待确认" }
        else if let guests, let capacity, guests > capacity { "超过已配置容量" }
        else if room.kind == .special && room.quantities.isEmpty { "按备注确认备品" }
        else { nil }

        let notes = room.notes.precomposedStringWithCompatibilityMapping.lowercased()
        let skipLinen = ["不换床品", "无需换床品", "リネン交換なし", "リネン交換不要", "シーツ交換なし"]
            .contains { notes.contains($0) }
        let skipGuestSupplies = ["不补备品", "備品補充なし", "備品補充不要"]
            .contains { notes.contains($0) }

        var counts: [Supply: Int] = [:]
        if room.kind.full {
            counts[.mat] = 1
            if !skipLinen {
                counts.merge([.doubleCover: doubles, .doubleSheet: doubles, .singleCover: singles,
                              .singleSheet: singles, .pillow: pillows]) { _, updated in updated }
            }
            if let guests, !skipGuestSupplies {
                counts[.towel] = guests
                counts[.handTowel] = guests
                counts[.toothbrush] = guests
            }
        }
        for (item, quantity) in room.quantities { counts[item] = max(0, quantity) }
        return Requirement(counts: counts, doubles: doubles, singles: singles, guests: guests,
                           guestSource: room.guests != nil ? "明确人数" : (guests == nil ? "待确认" : "房型默认"),
                           warning: warning)
    }
}

enum Priority {
    static func sorted(_ rooms: [Room], at time: Date = .now, calendar: Calendar = .current) -> [Room] {
        let now = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
        return rooms.sorted { lhs, rhs in
            if (lhs.work.stage == .done) != (rhs.work.stage == .done) { return rhs.work.stage == .done }
            if lhs.order != rhs.order { return (lhs.order ?? Int.max) < (rhs.order ?? Int.max) }
            let releaseA = minutes(in: lhs, suffix: "OUT") ?? 0
            let releaseB = minutes(in: rhs, suffix: "OUT") ?? 0
            if (releaseA > now) != (releaseB > now) { return releaseA <= now }
            if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority < rhs.kind.priority }
            let deadlineA = minutes(in: lhs, suffix: "IN") ?? Int.max
            let deadlineB = minutes(in: rhs, suffix: "IN") ?? Int.max
            if deadlineA != deadlineB { return deadlineA < deadlineB }
            if releaseA > now, releaseB > now, releaseA != releaseB { return releaseA < releaseB }
            return (Int(lhs.number) ?? Int.max) < (Int(rhs.number) ?? Int.max)
        }
    }

    private static func minutes(in room: Room, suffix: String) -> Int? {
        let text = (room.marks + [room.notes]).joined(separator: " ").precomposedStringWithCompatibilityMapping
        let pattern = #"\d{1,2}(?::\d{2}|時(?:\d{1,2}分)?)\s*"# + suffix
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let parts = text[match].split { !$0.isNumber }.compactMap { Int($0) }
        let minute = parts.dropFirst().first ?? 0
        guard let hour = parts.first, hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }
}
