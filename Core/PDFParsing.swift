import Foundation
import PDFKit
import UIKit
import Vision

struct Token {
    let text: String
    let box: CGRect
    let confidence: Double
}

struct Parsed {
    var date: Date?
    var rooms: [Room]
    var unresolved: Int
}

enum PDFParsing {
    private enum Column: String, CaseIterable {
        case room = "ROOM№", turnover = "OUT→IN", out = "OUT", skip = "清掃不要"
        case checkin = "IN", stay = "S", extra = "エクストラ", early = "12時IN", late = "12時OUT"
        case pickup = "案内回収", notes = "特別事項・注意事項", employee = "清掃担当者名"
        case complete = "清掃完了", guests = "入住人数", inspection = "检查备注"

        static func identify(_ text: String) -> Self? {
            let value = text.precomposedStringWithCompatibilityMapping.uppercased()
                .filter { !$0.isWhitespace }.replacingOccurrences(of: "NO.", with: "NO")
            if ["ROOMNO", "ROOM#", "ROOM", "部屋番号", "房号"].contains(value) { return .room }
            if ["人数", "宿泊人数", "宿泊者数", "PAX"].contains(value) { return .guests }
            if ["担当者", "清掃担当", "清掃担当者"].contains(value) { return .employee }
            if ["備考", "特別事項", "注意事項"].contains(value) { return .notes }
            return allCases.first { $0.rawValue == value }
        }
    }

    static func parse(_ data: Data) throws -> Parsed {
        try PDFInput.validate(data)
        guard let document = PDFDocument(data: data) else { throw PDFInput.Failure.invalid }
        guard !document.isLocked else { throw PDFInput.Failure.locked }
        guard document.pageCount > 0 else { throw PDFInput.Failure.invalid }
        var result = Parsed(rooms: [], unresolved: 0)
        var inherited: [Column: CGFloat] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let embedded = textTokens(page)
            var choice = table(embedded, page: index, inherited: inherited)
            if embedded.count < 10 || choice.columns[.employee] == nil || choice.rooms.isEmpty ||
                choice.rooms.allSatisfy({ $0.kind == .unknown || $0.employee.isEmpty }) {
                if let observed = try? ocr(page) {
                    let fallback = table(observed, page: index, inherited: inherited)
                    if score(fallback.rooms) > score(choice.rooms) ||
                        (choice.columns.isEmpty && !fallback.columns.isEmpty) {
                        choice = fallback
                    }
                    result.date = result.date ?? findDate(observed)
                }
            }
            inherited = choice.columns
            result.date = result.date ?? findDate(embedded)
            if choice.rooms.isEmpty { result.unresolved += 1 }
            result.rooms += choice.rooms
        }
        let duplicates = Dictionary(grouping: result.rooms, by: \.number).filter { $0.value.count > 1 }
        for index in result.rooms.indices where duplicates[result.rooms[index].number] != nil {
            result.rooms[index].needsReview = true
        }
        return result
    }

    private static func score(_ rooms: [Room]) -> Int {
        rooms.count + rooms.filter { $0.kind != .unknown && !$0.employee.isEmpty }.count * 3
    }

    private static func textTokens(_ page: PDFPage) -> [Token] {
        guard let text = page.string as NSString? else { return [] }
        let regex = try? NSRegularExpression(pattern: #"[^\s]+"#)
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        return (regex?.matches(in: text as String, range: NSRange(location: 0, length: text.length)) ?? [])
            .compactMap { match in
                let rect = page.selection(for: match.range)?.bounds(for: page) ?? .zero
                guard !rect.isEmpty else { return nil }
                return Token(text: text.substring(with: match.range), box: CGRect(
                    x: (rect.minX - bounds.minX) / bounds.width, y: (rect.minY - bounds.minY) / bounds.height,
                    width: rect.width / bounds.width, height: rect.height / bounds.height
                ), confidence: 1)
            }
    }

    private static func ocr(_ page: PDFPage) throws -> [Token] {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = min(2200 / bounds.width, 2700 / bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            let context = renderer.cgContext
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
        }
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).flatMap { observation -> [Token] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let text = candidate.string
            return text.split(whereSeparator: \.isWhitespace).map { word in
                let rect = (try? candidate.boundingBox(for: word.startIndex..<word.endIndex))?.boundingBox
                    ?? observation.boundingBox
                return Token(text: String(word), box: rect, confidence: Double(candidate.confidence))
            }
        }
    }

    private static func lines(_ tokens: [Token]) -> [[Token]] {
        var groups: [[Token]] = []
        for token in tokens.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = groups.last?.first,
               abs(anchor.box.midY - token.box.midY) < min(0.009, max(0.002, anchor.box.height * 0.4)) {
                groups[groups.count - 1].append(token)
            } else {
                groups.append([token])
            }
        }
        return groups.map { $0.sorted { $0.box.midX < $1.box.midX } }
    }

    static func rows(_ tokens: [Token]) -> [Room] {
        table(tokens, page: 0, inherited: [:]).rooms
    }

    private static func table(_ tokens: [Token], page: Int, inherited: [Column: CGFloat])
        -> (rooms: [Room], columns: [Column: CGFloat]) {
        let groups = lines(tokens)
        var columns = inherited
        var hotelLayout = false
        var header: CGFloat = 1
        var best = 0
        for group in groups {
            var found: [Column: CGFloat] = [:]
            for (index, token) in group.enumerated() {
                if let column = Column.identify(token.text) { found[column] = token.box.midX }
                if index + 1 < group.count {
                    let next = group[index + 1]
                    if next.box.minX - token.box.maxX < 0.015,
                       let column = Column.identify(token.text + next.text) {
                        found[column] = token.box.union(next.box).midX
                    }
                }
            }
            if found[.room] != nil, found.count >= 2, found.count > best {
                columns = found
                header = group.first?.box.midY ?? 1
                best = found.count
            }
        }
        if best > 0, let room = columns[.room], let out = columns[.out], let turnover = columns[.turnover],
           abs(room - 0.062) < 0.02, abs(out - 0.121) < 0.02, abs(turnover - 0.186) < 0.02 {
            let heading = tokens.filter { abs($0.box.midY - header) < 0.028 }
            let employee = heading.contains { (0.67...0.76).contains($0.box.midX) && $0.text.contains("担当者名") }
            let notes = heading.contains { (0.48...0.66).contains($0.box.midX) && $0.text.contains("特別事項") }
            if employee && notes {
                hotelLayout = true
                columns = [.room: 0.062, .out: 0.121, .turnover: 0.186, .checkin: 0.250,
                           .stay: 0.306, .extra: 0.350, .early: 0.381, .late: 0.414,
                           .pickup: 0.449, .notes: 0.576, .employee: 0.721, .inspection: 0.802]
            }
        }
        guard let roomX = columns[.room] else { return ([], columns) }
        let centers = columns.sorted { $0.value < $1.value }
        func column(_ x: CGFloat) -> Column? {
            if hotelLayout {
                // Normalized grid boundaries, applied only after matching the printed headers.
                let boundaries: [(CGFloat, Column)] = [
                    (0.0926, .room), (0.1478, .out), (0.2230, .turnover), (0.2783, .checkin),
                    (0.3335, .stay), (0.3648, .extra), (0.3977, .early), (0.4320, .late),
                    (0.4663, .pickup), (0.6861, .notes), (0.7542, .employee), (0.8582, .inspection),
                    (0.889, .complete)
                ]
                guard x >= 0.028 else { return nil }
                return boundaries.first { x < $0.0 }?.1
            }
            return centers.min { abs($0.value - x) < abs($1.value - x) }?.key
        }
        let body = tokens.filter { $0.box.midY < header - 0.002 }
        let candidates = body.filter {
            column($0.box.midX) == .room && abs($0.box.midX - roomX) < 0.09 &&
            $0.text.range(of: #"^[0-9]{3,4}$"#, options: .regularExpression) != nil
        }.sorted { $0.box.midY > $1.box.midY }
        let rooms = candidates.enumerated().map { index, anchor -> Room in
            let bottom = index + 1 < candidates.count ? (anchor.box.midY + candidates[index + 1].box.midY) / 2 : max(0, anchor.box.midY - 0.035)
            let top = index > 0 ? (anchor.box.midY + candidates[index - 1].box.midY) / 2 : min(header, anchor.box.midY + 0.035)
            var cells: [Column: [Token]] = [:]
            for token in body where token.box.midY > bottom && token.box.midY <= top {
                guard let key = column(token.box.midX), key != .room else { continue }
                if key == .notes || abs(token.box.midY - anchor.box.midY) <= max(0.004, anchor.box.height * 0.65) {
                    cells[key, default: []].append(token)
                }
            }
            func contents(_ key: Column) -> String {
                lines(cells[key] ?? []).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
            }
            func marked(_ key: Column) -> Bool {
                let value = contents(key).trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && !["-", "－", "—", "×", "0"].contains(value)
            }
            let kind: Kind = if marked(.turnover) { .turnover }
            else if marked(.out) { .checkout }
            else if marked(.skip) || (hotelLayout && contents(.checkin).filter { !$0.isWhitespace }.contains("清掃不要")) { .skip }
            else if marked(.extra) || marked(.pickup) { .special }
            else if marked(.stay) { .stay }
            else if marked(.checkin) { .checkin }
            else { .unknown }
            let roomNumber = anchor.text
            let noteText = contents(.notes).precomposedStringWithCompatibilityMapping
            let guestText = contents(.guests).precomposedStringWithCompatibilityMapping
            let guestPattern = #"[1-9][0-9]?\s*(?:人|名)"#
            let explicit = guestText.range(of: #"^\s*[1-9][0-9]?\s*(?:人|名)?\s*$"#, options: .regularExpression)
                .flatMap { _ in Int(guestText.filter(\.isNumber)) }
            let noteCount = hotelLayout && guestText.isEmpty
                ? noteText.range(of: #"^\s*"# + guestPattern + #"(?![0-9])"#, options: .regularExpression)
                : nil
            let guests = explicit ?? noteCount.flatMap { Int(noteText[$0].filter(\.isNumber)) }
            let notes = [noteText, contents(.inspection)].filter { !$0.isEmpty }.joined(separator: "\n")
            let marks: [Column] = [.early, .late, .extra, .pickup, .complete]
            let values = marks.filter(marked).map { "\($0.rawValue) \(contents($0))" }
            let employee = contents(.employee)
                .replacingOccurrences(of: #"(?<=[\p{Han}])\s+(?=[\p{Han}])"#, with: "", options: .regularExpression)
            let quality = ([anchor] + cells.values.flatMap { $0 }).map(\.confidence).min() ?? 0
            let fieldSources = Dictionary(uniqueKeysWithValues: cells.compactMap { key, values -> (String, Source)? in
                guard let first = values.first else { return nil }
                let rect = values.dropFirst().reduce(first.box) { $0.union($1.box) }
                return (key.rawValue, Source(page: page, x: rect.minX, y: rect.minY, width: rect.width,
                                             height: rect.height, confidence: values.map(\.confidence).min() ?? 0))
            })
            return Room(number: roomNumber, kind: kind, employee: employee, guests: guests, notes: notes,
                        marks: values, source: Source(page: page, x: 0, y: bottom, width: 1, height: top - bottom, confidence: quality),
                        fieldSources: fieldSources,
                        needsReview: kind == .unknown || best == 0 || quality < 0.85 ||
                            (!guestText.isEmpty && guests == nil) || columns[.employee] == nil ||
                            (roomNumber == "1103" && kind.full && guests == nil))
        }
        return (rooms, columns)
    }

    private static func findDate(_ tokens: [Token]) -> Date? {
        let text = lines(tokens).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
            .precomposedStringWithCompatibilityMapping
        guard let span = text.range(of: #"20\d\d\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}"#, options: .regularExpression) else { return nil }
        let parts = text[span].split { !$0.isNumber }.compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
