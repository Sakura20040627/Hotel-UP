import XCTest
import UIKit
import SwiftData
@testable import HotelFlow

final class RulesTests: XCTestCase {
    func testSyntheticAcceptanceTotals() {
        var settings = Settings()
        settings.employee = "示例担当"
        let rooms = [
            Room(number: "1001", kind: .turnover, employee: settings.employee, guests: 3),
            Room(number: "903", kind: .checkout, employee: settings.employee),
            Room(number: "1102", kind: .checkout, employee: settings.employee),
            Room(number: "901", kind: .checkout, employee: "其他担当")
        ].filter(settings.owns)
        XCTAssertEqual(rooms.count, 3)
        XCTAssertEqual(rooms.filter { $0.kind == .turnover }.count, 1)
        let counts = rooms.reduce(into: [Supply: Int]()) {
            $0.merge(SupplyEngine.requirement(for: $1, settings: settings).counts, uniquingKeysWith: +)
        }
        XCTAssertEqual(counts, [.doubleCover: 3, .doubleSheet: 3, .singleCover: 5, .singleSheet: 5,
                                .pillow: 11, .towel: 11, .handTowel: 11, .toothbrush: 11, .mat: 3])
    }

    func testSpecialRoomAndRevision() {
        var settings = Settings()
        settings.specialCapacity = 3
        var room = Room(number: "1103", kind: .turnover)
        let unknown = SupplyEngine.requirement(for: room, settings: settings)
        XCTAssertEqual(unknown.doubles, 1)
        XCTAssertEqual(unknown.counts[.pillow], 2)
        XCTAssertNil(unknown.counts[.towel])
        XCTAssertNotNil(unknown.warning)
        room.guests = 3
        room.work.start(at: Date(timeIntervalSince1970: 100))
        room.work.finish(at: Date(timeIntervalSince1970: 200))
        let three = SupplyEngine.requirement(for: room, settings: settings)
        XCTAssertEqual(three.doubles, 1)
        XCTAssertEqual(three.counts[.toothbrush], 3)
        let changed = Room(number: room.number, kind: room.kind, guests: 4)
        XCTAssertEqual(ImportDiff.changes(from: [room], to: [changed]), ["1103 · 人数"])
        let merged = ImportDiff.merge([room], [changed])[0]
        XCTAssertEqual(merged.work, room.work)
        XCTAssertEqual(merged.id, room.id)
        let four = SupplyEngine.requirement(for: merged, settings: settings)
        XCTAssertEqual(four.doubles, 2)
        XCTAssertEqual(four.counts[.pillow], 4)
        for item in [Supply.towel, .handTowel, .toothbrush] { XCTAssertEqual(four.counts[item], 4) }
        XCTAssertNotNil(four.warning)
    }

    func testAssignmentAndPriority() {
        var settings = Settings()
        settings.employee = "担当A"
        settings.aliases = "A"
        XCTAssertTrue(settings.owns(Room(number: "201", employee: " A ")))
        XCTAssertFalse(settings.owns(Room(number: "202", employee: "担当AB")))
        XCTAssertFalse(settings.owns(Room(number: "203")))
        let rooms = [Room(number: "202", kind: .checkout, marks: ["12時OUT"]),
                     Room(number: "201", kind: .checkout),
                     Room(number: "301", kind: .turnover, marks: ["12時IN"]),
                     Room(number: "205", kind: .turnover)]
        let local = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 10))!
        XCTAssertEqual(Priority.sorted(rooms, at: local).map(\.number), ["301", "205", "201", "202"])
        XCTAssertEqual(Priority.sorted([
            Room(number: "201", kind: .turnover, marks: ["12時OUT"]),
            Room(number: "202", kind: .checkout)
        ], at: local).map(\.number), ["202", "201"])
        XCTAssertTrue(SupplyEngine.requirement(for: Room(number: "201", kind: .stay, guests: 3),
                                               settings: settings).counts.isEmpty)
    }

    func testTimerSurvivesRoundTripAndExcludesPause() throws {
        let start = Date(timeIntervalSince1970: 100)
        var work = Work()
        work.start(at: start)
        work.pause(at: start.addingTimeInterval(15))
        work.start(at: start.addingTimeInterval(50))
        let encoded = try JSONEncoder().encode(work)
        var restored = try JSONDecoder().decode(Work.self, from: encoded)
        XCTAssertEqual(restored.elapsed(at: start.addingTimeInterval(60)), 25)
        restored.inspect(at: start.addingTimeInterval(70))
        restored.finish(at: start.addingTimeInterval(85))
        XCTAssertEqual(restored.elapsed(at: start.addingTimeInterval(100)), 35)
    }

    @MainActor func testSwiftDataRestoresRunningSession() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("test.store")
        let start = Date(timeIntervalSince1970: 1_000)
        do {
            let container = try ModelContainer(for: LedgerRecord.self, configurations: ModelConfiguration(url: url))
            var room = Room(number: "201", kind: .checkout)
            room.work.start(at: start)
            let value = Ledger(days: [Day(date: start, rooms: [room], revisions: [])])
            container.mainContext.insert(LedgerRecord(data: try JSONEncoder().encode(value)))
            try container.mainContext.save()
        }
        let container = try ModelContainer(for: LedgerRecord.self, configurations: ModelConfiguration(url: url))
        let record = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LedgerRecord>()).first)
        let restored = try JSONDecoder().decode(Ledger.self, from: record.data)
        let room = try XCTUnwrap(restored.days.first?.rooms.first)
        XCTAssertEqual(room.work.stage, .active)
        XCTAssertEqual(room.work.elapsed(at: start.addingTimeInterval(90)), 90)
    }

    func testCoordinateLayoutKeepsGuestsOnTheirRow() {
        func token(_ text: String, _ x: CGFloat, _ y: CGFloat) -> Token {
            Token(text: text, box: CGRect(x: x - 0.01, y: y - 0.005, width: 0.02, height: 0.01), confidence: 1)
        }
        let rooms = PDFParsing.rows([
            token("Room №", 0.10, 0.9), token("OUT", 0.2, 0.9), token("OUT→IN", 0.3, 0.9),
            token("清掃担当者名", 0.5, 0.9), token("入住人数", 0.70, 0.9), token("備考", 0.85, 0.9),
            token("301", 0.10, 0.8), token("○", 0.2, 0.8), token("○", 0.3, 0.8),
            token("担当A", 0.5, 0.8), token("3人", 0.7, 0.8), token("備品確認", 0.85, 0.78),
            token("302", 0.10, 0.74), token("○", 0.2, 0.74), token("担当B", 0.5, 0.74)
        ])
        XCTAssertEqual(rooms.map(\.kind), [.turnover, .checkout])
        XCTAssertEqual(rooms.map(\.employee), ["担当A", "担当B"])
        XCTAssertEqual(rooms.map(\.guests), [3, nil])
        XCTAssertEqual(rooms.first?.notes, "備品確認")
    }

    @MainActor func testPDFKitCoordinateImport() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 700)).pdfData { context in
            context.beginPage()
            let font = UIFont.systemFont(ofSize: 11)
            func draw(_ text: String, _ x: CGFloat, _ y: CGFloat) {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font])
            }
            draw("2026-11-17", 30, 20)
            draw("Room", 30, 80)
            draw("OUT", 150, 80)
            draw("PAX", 230, 80)
            draw("担当者", 340, 80)
            draw("201", 30, 120)
            draw("X", 152, 120)
            draw("3", 232, 120)
            draw("A", 344, 120)
        }
        let parsed = try PDFParsing.parse(data)
        XCTAssertNotNil(parsed.date)
        XCTAssertEqual(parsed.rooms.first?.number, "201")
        XCTAssertEqual(parsed.rooms.first?.employee, "A")
        XCTAssertEqual(parsed.rooms.first?.guests, 3)
        XCTAssertEqual(parsed.rooms.first?.kind, .checkout)
        XCTAssertEqual(parsed.rooms.first?.source?.page, 0)
    }
}
