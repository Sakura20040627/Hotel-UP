import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

@main struct HotelFlowApp: App {
    @State private var container: ModelContainer?
    @State private var failed = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    Dashboard().modelContainer(container)
                } else if failed {
                    ContentUnavailableView("无法打开本地数据库", systemImage: "externaldrive.badge.exclamationmark")
                } else {
                    ProgressView().task {
                        do { container = try ModelContainer(for: LedgerRecord.self) }
                        catch { failed = true }
                    }
                }
            }
        }
    }
}

struct Draft: Identifiable {
    var id: String
    var date: Date
    var dateConfirmed: Bool
    var rooms: [Room]
    var unresolved: Int
    var url: URL
    var pending: URL?
}

struct PDFPreview: Identifiable {
    var id = UUID()
    var url: URL
    var source: Source?
}

private struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct Dashboard: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @State private var ledger = Ledger()
    @State private var loaded = false
    @State private var blocked = false
    @State private var showingFiles = false
    @State private var importingBackup = false
    @State private var export = false
    @State private var backup: BackupFile?
    @State private var restoreCandidate: Backup?
    @State private var settings = false
    @State private var draft: Draft?
    @State private var preview: PDFPreview?
    @State private var message: String?
    @State private var busy = false
    @State private var historyDate = Date()
    @State private var filterHistory = false
    @State private var finishedCount = 0
    @State private var remaining = false
    @State private var rejected = Set<URL>()
    @State private var selectedTab = 0

    private var today: Date { Calendar.current.startOfDay(for: .now) }
    private var todayRooms: [Room] { ledger.days.first { $0.date == today }?.rooms ?? [] }
    private var personal: [Room] {
        Priority.sorted(todayRooms.filter { ledger.settings.owns($0) && !$0.removed && !$0.superseded })
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { todayView }
                .tabItem { Label("今日", systemImage: "checklist") }.tag(0)
            NavigationStack { suppliesView }
                .tabItem { Label("备品", systemImage: "shippingbox") }.tag(1)
            NavigationStack { historyView }
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }.tag(2)
        }
        .task { load(); checkInbox() }
        .onChange(of: phase) { _, value in if value == .active { checkInbox() } }
        .onChange(of: draft == nil) { _, closed in if closed { checkInbox() } }
        .alert("HotelFlow", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [importingBackup ? .json : .pdf]) { result in
            do {
                let url = try result.get()
                if importingBackup {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    restoreCandidate = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
                } else {
                    importFile(url, pending: false)
                }
            } catch { message = importingBackup ? "无法读取备份。" : "无法读取所选 PDF。" }
        }
        .fileExporter(isPresented: $export, document: backup, contentType: .json, defaultFilename: "HotelFlow-Backup") { result in
            if case .failure = result { message = "无法导出备份。" }
        }
        .confirmationDialog("从备份恢复将替换目前的本地工作记录", isPresented: Binding(
            get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("恢复备份", role: .destructive) { if let restoreCandidate { restoreBackup(restoreCandidate) }; restoreCandidate = nil }
        }
        .sheet(isPresented: $settings) { settingsView }
        .sheet(item: $draft, onDismiss: { checkInbox() }) { value in reviewSheet(value) }
        .sheet(item: $preview) { value in
            NavigationStack {
                PDFPositionView(url: value.url, source: value.source)
                    .navigationTitle("原始 PDF")
                    .toolbar { Button("关闭") { preview = nil } }
            }
        }
        .sensoryFeedback(.success, trigger: finishedCount)
    }

    private var todayView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ledger.settings.hotel.isEmpty ? "HotelFlow" : ledger.settings.hotel).font(.title2.bold())
                    Text(today, format: .dateTime.month().day().weekday())
                    Text(ledger.settings.employee.isEmpty ? "请在设置中填写担当者" : ledger.settings.employee)
                    let done = personal.filter { $0.work.stage == .done }.count
                    let rate = personal.isEmpty ? 0.0 : Double(done) / Double(personal.count)
                    ProgressView(value: rate)
                    Text("任务 \(personal.count) · OUT→IN \(personal.filter { $0.kind == .turnover }.count) · 完成 \(done) · \(Int(rate * 100))%")
                        .font(.subheadline)
                }
                .padding(12)
                .modifier(SummarySurface())
                Button("导入今日清扫 PDF", systemImage: "square.and.arrow.down") {
                    importingBackup = false
                    showingFiles = true
                }
                    .disabled(blocked || busy || draft != nil)
                if busy { ProgressView("正在本地识别 PDF") }
            }
            Section("我的房间") {
                ForEach(personal) { room in
                    NavigationLink { roomDetail(room.id) } label: { card(room) }
                        .swipeActions(edge: .leading) {
                            if room.kind.cleanable && room.work.stage == .waiting {
                                Button("开始", systemImage: "play.fill") { edit(room.id) { $0.work.start(at: .now) } }
                            }
                        }
                }
                .onMove { from, to in
                    var moved = personal
                    moved.move(fromOffsets: from, toOffset: to)
                    updateDay(today) { day in
                        for index in day.rooms.indices {
                            day.rooms[index].order = moved.firstIndex { $0.id == day.rooms[index].id }
                        }
                    }
                }
                if personal.isEmpty { Text("暂无个人任务").foregroundStyle(.secondary) }
            }
            Section("未分配") {
                ForEach(todayRooms.filter { Settings.normalized($0.employee).isEmpty && !$0.removed && !$0.superseded }) { room in
                    NavigationLink { roomDetail(room.id) } label: { card(room) }
                }
            }
            Section("其他担当者") {
                ForEach(todayRooms.filter { !Settings.normalized($0.employee).isEmpty && !ledger.settings.owns($0) && !$0.removed && !$0.superseded }) { room in
                    NavigationLink { roomDetail(room.id) } label: { card(room) }
                }
            }
            Section("已移除") {
                ForEach(todayRooms.filter { $0.removed && !$0.superseded }) { room in
                    Button("恢复 \(room.number)") { edit(room.id, audit: "恢复个人任务") { $0.removed = false } }
                }
            }
        }
        .navigationTitle("今日")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("设置", systemImage: "gearshape") { settings = true } }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
    }

    private func card(_ room: Room) -> some View {
        let result = SupplyEngine.requirement(for: room, settings: ledger.settings)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(room.number).font(.title2.bold())
                Spacer()
                Text(room.kind.cleanable ? "P\(room.kind.priority) · \(room.kind.rawValue)" : room.kind.rawValue)
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(room.type.rawValue) · \(result.guests.map(String.init) ?? "未知") 人（\(result.guestSource)）")
            Text("双人床 \(result.doubles) · 单人床 \(result.singles) · 备品 \(result.counts.values.reduce(0, +)) 件")
            if !room.notes.isEmpty { Text(room.notes) }
            if !room.marks.isEmpty { Text(room.marks.joined(separator: " · ")) }
            if let warning = result.warning { Text(warning).foregroundStyle(.orange) }
            if room.needsReview { Text("需核对 PDF").foregroundStyle(.orange) }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text("\(room.work.stage.rawValue) · \(duration(room.work.elapsed(at: timeline.date)))")
                    .monospacedDigit()
            }
        }
        .font(.subheadline)
        .foregroundStyle(room.work.stage == .done ? .secondary : .primary)
        .padding(.vertical, 8)
    }

    private func roomDetail(_ id: UUID) -> some View {
        Group {
            if let room = todayRooms.first(where: { $0.id == id }) {
                List {
                    Section { card(room) }
                    Section("清扫") {
                        if (room.kind.cleanable && room.work.stage == .waiting) ||
                            (room.work.stage == .active && room.work.runningSince == nil) {
                            Button(room.work.started == nil ? "开始清扫" : "继续清扫") { edit(id) { $0.work.start(at: .now) } }
                        }
                        if room.work.runningSince != nil {
                            Button("暂停") { edit(id) { $0.work.pause(at: .now) } }
                            Button("进入检查") { edit(id) { $0.work.inspect(at: .now) } }
                        }
                        if room.work.stage == .inspection {
                            Button("完成清扫") {
                                edit(id) { $0.work.finish(at: .now) }
                                finishedCount += 1
                            }.disabled(room.work.checked.count != Self.steps.count)
                        }
                        if room.work.stage == .done {
                            Button("撤销完成") { edit(id, audit: "撤销完成") { $0.work.reopen() } }
                        }
                    }
                    Section("清扫步骤 \(room.work.checked.count)/\(Self.steps.count)") {
                        if let current = room.work.order.first(where: { !room.work.checked.contains($0) }) {
                            LabeledContent("当前步骤", value: Self.steps[current])
                        }
                        ForEach(room.work.order, id: \.self) { index in
                            Toggle(Self.steps[index], isOn: Binding(get: { room.work.checked.contains(index) }, set: { checked in
                                edit(id) { if checked { $0.work.checked.insert(index) } else { $0.work.checked.remove(index) } }
                            })).disabled(room.work.stage == .done || (!room.kind.cleanable && room.work.started == nil))
                        }.onMove { from, to in edit(id, audit: "调整清扫步骤顺序") { $0.work.order.move(fromOffsets: from, toOffset: to) } }
                    }
                    Section("房间信息") {
                        fields(roomBinding(id))
                        Picker("房型", selection: roomBinding(id).typeOverride) {
                            Text("自动").tag(Optional<RoomType>.none)
                            ForEach(RoomType.allCases.filter { $0 != .special }) { Text($0.rawValue).tag(Optional($0)) }
                        }.disabled(room.number == "1103")
                        if !ledger.settings.employee.isEmpty && !ledger.settings.owns(room) {
                            Button("认领") { edit(id, audit: "手动认领") { $0.employee = ledger.settings.employee } }
                        }
                        Button("移除任务", role: .destructive) { edit(id, audit: "手动移除") { $0.removed = true } }
                        if let source = room.source, let revision = room.revision, let url = try? pdfURL(revision) {
                            Button("查看原始位置") { preview = PDFPreview(url: url, source: source) }
                        }
                    }
                    Section("每房备品") { roomSupplies(room) }
                    if !room.audit.isEmpty {
                        Section("修改记录") {
                            ForEach(Array(room.audit.enumerated()), id: \.offset) { _, entry in
                                LabeledContent(entry.description, value: entry.date.formatted())
                            }
                        }
                    }
                }
                .navigationTitle(room.number)
                .toolbar { EditButton() }
            } else { ContentUnavailableView("找不到房间", systemImage: "door.left.hand.closed") }
        }
    }

    private func roomSupplies(_ room: Room) -> some View {
        let requirement = SupplyEngine.requirement(for: room, settings: ledger.settings)
        return ForEach(Supply.allCases) { item in
            let count = requirement.counts[item]
            let prepared = min(room.prepared[item] ?? 0, count ?? 0)
            VStack(alignment: .leading) {
                Stepper("\(item.rawValue) · \(count.map(String.init) ?? "—")", onIncrement: {
                    edit(room.id, audit: "调整\(item.rawValue)") { $0.quantities[item] = min(999, (count ?? 0) + 1) }
                }, onDecrement: {
                    edit(room.id, audit: "调整\(item.rawValue)") { $0.quantities[item] = max(0, (count ?? 0) - 1) }
                })
                if let count, count > 0 {
                    Toggle("已准备 \(prepared)/\(count)", isOn: Binding(get: { prepared == count }, set: { ready in
                        edit(room.id) { $0.prepared[item] = ready ? count : 0 }
                    }))
                }
            }
        }
    }

    private var suppliesView: some View {
        let rooms = remaining ? personal.filter { $0.work.stage != .done } : personal
        let requirements = rooms.map { SupplyEngine.requirement(for: $0, settings: ledger.settings) }
        let required = requirements.reduce(0) { $0 + $1.counts.values.reduce(0, +) }
        let ready = zip(rooms, requirements).reduce(0) { total, pair in
            total + pair.1.counts.reduce(0) { $0 + min($1.value, pair.0.prepared[$1.key, default: 0]) }
        }
        return List {
            Section {
                Toggle("仅显示未完成任务", isOn: $remaining)
                ProgressView(value: Double(ready), total: Double(max(required, 1))) {
                    Text("已准备 \(ready)/\(required) 件已确定物资")
                }
                ForEach(rooms.filter { SupplyEngine.requirement(for: $0, settings: ledger.settings).warning != nil }) { room in
                    NavigationLink { roomDetail(room.id) } label: { Text("\(room.number) · \(SupplyEngine.requirement(for: room, settings: ledger.settings).warning ?? "")") }
                }
            }
            ForEach([true, false], id: \.self) { linen in
                Section(linen ? "床上用品" : "客房备品") {
                    ForEach(Supply.allCases.filter { $0.linen == linen }) { item in
                        LabeledContent(item.rawValue, value: String(requirements.reduce(0) { $0 + $1.counts[item, default: 0] }))
                    }
                }
            }
            Section("按房间") {
                ForEach(rooms) { room in NavigationLink(room.number) { roomDetail(room.id) } }
            }
        }.navigationTitle("备品")
    }

    private var historyView: some View {
        List {
            Toggle("按日期筛选", isOn: $filterHistory)
            if filterHistory { DatePicker("日期", selection: $historyDate, displayedComponents: .date) }
            ForEach(ledger.days.sorted { $0.date > $1.date }.filter {
                !filterHistory || Calendar.current.isDate($0.date, inSameDayAs: historyDate)
            }) { day in
                let owned = day.rooms.filter { ledger.settings.owns($0) || $0.work.started != nil }
                let done = owned.filter { $0.work.stage == .done }
                let total = owned.reduce(0.0) { $0 + $1.work.elapsed(at: .now) }
                let completeTotal = done.reduce(0.0) { $0 + $1.work.elapsed(at: .now) }
                Section(day.date.formatted(date: .abbreviated, time: .omitted)) {
                    Text("任务 \(owned.count) · 已完成 \(done.count) · 总计 \(duration(total))")
                    if !done.isEmpty { Text("完成房平均 \(duration(completeTotal / Double(done.count)))") }
                    ForEach(owned) { room in
                        LabeledContent("\(room.number) · \(room.work.stage.rawValue)", value: duration(room.work.elapsed(at: .now)))
                    }
                    ForEach(Array(day.revisions.enumerated()), id: \.element.id) { index, entry in
                        Button("原始 PDF · 版本 \(index + 1)") {
                            if let url = try? pdfURL(entry.id, create: false) { preview = PDFPreview(url: url) }
                        }
                    }
                }
            }
        }.navigationTitle("历史")
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                TextField("酒店", text: settingsBinding(\.hotel))
                TextField("担当者", text: settingsBinding(\.employee))
                TextField("姓名别名，用英文逗号分隔", text: settingsBinding(\.aliases))
                TextField("1103 容量（未配置可留空）", text: Binding(
                    get: { ledger.settings.specialCapacity.map(String.init) ?? "" },
                    set: { input in
                        if input.isEmpty { settingsBinding(\.specialCapacity).wrappedValue = nil }
                        else if let value = Int(input), (1...99).contains(value) { settingsBinding(\.specialCapacity).wrappedValue = value }
                    })).keyboardType(.numberPad)
                Button("备份全部本地记录和 PDF") { settings = false; createBackup() }
                Button("从备份恢复") {
                    settings = false
                    importingBackup = true
                    showingFiles = true
                }
            }.navigationTitle("设置").toolbar { Button("完成") { settings = false } }
        }
    }

    private static let steps = ["收垃圾与撤旧布草", "浴室预处理并使用清洁剂", "更换床单、被套，整理床铺", "清洁浴室",
                                "清洁灶台、台面和接触表面", "整理毛巾并补充牙刷等备品", "地面清洁", "物品复位与最终检查"]

    private func duration(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            if let record = try context.fetch(FetchDescriptor<LedgerRecord>()).first {
                ledger = try JSONDecoder().decode(Ledger.self, from: record.data)
            }
        } catch { blocked = true; message = "本地记录无法读取。现有记录已保留。" }
    }

    @discardableResult private func save(_ updated: Ledger, restoring: Bool = false) -> Bool {
        guard !blocked || restoring else { return false }
        do {
            let data = try JSONEncoder().encode(updated)
            let existing = try context.fetch(FetchDescriptor<LedgerRecord>()).first
            if let existing { existing.data = data }
            else { context.insert(LedgerRecord(data: data)) }
            try context.save()
            ledger = updated
            blocked = false
            return true
        } catch {
            context.rollback()
            message = "无法保存本地记录，请重试。"
            return false
        }
    }

    private func settingsBinding<T>(_ key: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { ledger.settings[keyPath: key] }, set: { value in
            var updated = ledger
            updated.settings[keyPath: key] = value
            save(updated)
        })
    }

    private func updateDay(_ date: Date, update: (inout Day) -> Void) {
        var next = ledger
        guard let index = next.days.firstIndex(where: { $0.date == date }) else { return }
        update(&next.days[index])
        save(next)
    }

    private func edit(_ id: UUID, audit: String? = nil, update: (inout Room) -> Void) {
        updateDay(today) { day in
            guard let index = day.rooms.firstIndex(where: { $0.id == id }) else { return }
            update(&day.rooms[index])
            if let audit { day.rooms[index].audit.append(Audit(description: audit)) }
        }
    }

    private func roomBinding(_ id: UUID) -> Binding<Room> {
        Binding(get: { todayRooms.first { $0.id == id } ?? Room(number: "") }, set: { room in
            edit(id, audit: "手动修改房间信息") { $0 = room }
        })
    }

    private func fields(_ room: Binding<Room>) -> some View {
        Group {
            Picker("任务类型", selection: room.kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("担当者", text: room.employee)
            TextField("入住人数", text: Binding(
                get: { room.wrappedValue.guests.map(String.init) ?? "" },
                set: { value in
                    if value.isEmpty { room.wrappedValue.guests = nil }
                    else if let count = Int(value), (1...99).contains(count) { room.wrappedValue.guests = count }
                })).keyboardType(.numberPad)
            TextField("备注", text: room.notes, axis: .vertical)
        }
    }

    private func pdfURL(_ hash: String, create: Bool = true) throws -> URL {
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: create)
        let folder = base.appendingPathComponent("PDF", isDirectory: true)
        if create { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return folder.appendingPathComponent(hash + ".pdf")
    }

    private func checkInbox() {
        guard loaded, !blocked, !busy, draft == nil, !settings,
              let folder = try? Inbox.folder(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let pending = files.filter { $0.pathExtension == "pdf" && !rejected.contains($0) }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }
        if let next = pending.first { importFile(next, pending: true) }
    }

    private func importFile(_ source: URL, pending: Bool) {
        guard !busy, !blocked else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let scope = source.startAccessingSecurityScopedResource()
                    defer { if scope { source.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: source)
                }.value
                let id = Inbox.digest(data)
                if ledger.days.contains(where: { $0.revisions.contains { $0.id == id } }) {
                    if pending { try FileManager.default.removeItem(at: source) }
                    else { message = "此 PDF 已导入。" }
                    busy = false
                    checkInbox()
                    return
                }
                let parsed = try await Task.detached(priority: .userInitiated) { try PDFParsing.parse(data) }.value
                let url = try pdfURL(id)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                draft = Draft(id: id, date: parsed.date ?? today, dateConfirmed: parsed.date != nil,
                              rooms: parsed.rooms, unresolved: parsed.unresolved, url: url, pending: pending ? source : nil)
            } catch {
                if pending { rejected.insert(source) }
                message = "无法读取或识别 PDF。请确认文件完整且未加密。"
                busy = false
                if pending { checkInbox() }
            }
        }
    }

    private func reviewSheet(_ value: Draft) -> some View {
        Review(draft: value, settings: ledger.settings, days: ledger.days) { confirmed in
            var next = ledger
            let date = Calendar.current.startOfDay(for: confirmed.date)
            let rooms = confirmed.rooms.map { room in
                var updated = room
                updated.needsReview = false
                updated.revision = confirmed.id
                return updated
            }
            let revision = Revision(id: confirmed.id, date: date, rooms: rooms, unresolved: confirmed.unresolved)
            if let index = next.days.firstIndex(where: { $0.date == date }) {
                next.days[index].rooms = ImportDiff.merge(next.days[index].rooms, rooms)
                next.days[index].revisions.append(revision)
            } else {
                next.days.append(Day(date: date, rooms: rooms, revisions: [revision]))
            }
            if save(next) {
                if let pending = confirmed.pending { try? FileManager.default.removeItem(at: pending) }
                draft = nil
                selectedTab = date == today ? 0 : 2
            }
        } cancel: {
            if let pending = value.pending { rejected.insert(pending) }
            try? FileManager.default.removeItem(at: value.url)
            draft = nil
        }
    }

    private func createBackup() {
        do {
            var docs: [String: Data] = [:]
            for revision in ledger.days.flatMap(\.revisions) {
                docs[revision.id] = try Data(contentsOf: pdfURL(revision.id, create: false))
            }
            backup = BackupFile(bytes: try JSONEncoder().encode(Backup(ledger: ledger, documents: docs)))
            export = true
        } catch { message = "备份失败，部分本地文件无法读取。" }
    }

    private func restoreBackup(_ backup: Backup) {
        do {
            for date in backup.ledger.days {
                for room in date.rooms {
                    guard room.work.order.sorted() == Array(0..<8),
                          room.quantities.values.allSatisfy({ (0...999).contains($0) }),
                          room.prepared.values.allSatisfy({ (0...999).contains($0) }),
                          room.guests.map({ (1...99).contains($0) }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
                }
            }
            for revision in backup.ledger.days.flatMap(\.revisions) {
                guard let data = backup.documents[revision.id], Inbox.digest(data) == revision.id else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try data.write(to: pdfURL(revision.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if save(backup.ledger, restoring: true) { checkInbox() }
        } catch { message = "恢复失败，备份文件可能不完整。" }
    }
}

private struct SummarySurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}
