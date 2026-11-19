import SwiftUI
import PDFKit

struct Review: View {
    @State var draft: Draft
    let settings: Settings
    let days: [Day]
    let confirm: (Draft) -> Void
    let cancel: () -> Void
    @State private var checked = false
    @State private var preview: PDFPreview?
    let original: [Room]

    init(draft: Draft, settings: Settings, days: [Day], confirm: @escaping (Draft) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        original = draft.rooms
        self.settings = settings
        self.days = days
        self.confirm = confirm
        self.cancel = cancel
    }

    private var old: [Room] {
        days.first { Calendar.current.isDate($0.date, inSameDayAs: draft.date) }?.rooms ?? []
    }
    private var valid: Bool {
        draft.dateConfirmed && checked && !draft.rooms.isEmpty &&
        Set(draft.rooms.map(\.number)).count == draft.rooms.count &&
        draft.rooms.allSatisfy { $0.number.range(of: #"^[0-9]{3,4}$"#, options: .regularExpression) != nil }
    }

    private func reviewedDraft() -> Draft {
        var checked = draft
        for index in checked.rooms.indices {
            let room = checked.rooms[index]
            guard let previous = original.first(where: { $0.id == room.id }) else {
                checked.rooms[index].audit.append(Audit(description: "校对时手动添加"))
                continue
            }
            if room != previous {
                let prior = "房号 \(previous.number) · \(previous.kind.rawValue) · \(previous.employee) · \(previous.guests.map(String.init) ?? "未填写") 人 · \(previous.notes)"
                checked.rooms[index].audit.append(Audit(description: "校对时修改 · 原值 \(prior)"))
            }
        }
        return checked
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("清扫日期", selection: $draft.date, displayedComponents: .date)
                    Toggle("已核对清扫日期", isOn: $draft.dateConfirmed)
                    if draft.rooms.isEmpty {
                        Text("PDF 已打开，但未识别到清扫表。请查看原文并添加房间后确认。")
                            .foregroundStyle(.orange)
                        Button("手动添加房间", systemImage: "plus") { draft.rooms.append(Room(number: "")) }
                    }
                    if draft.unresolved > 0 { Text("\(draft.unresolved) 页未识别，请查看原始 PDF 并补齐。").foregroundStyle(.orange) }
                    if !settings.employee.isEmpty {
                        Text("匹配 \(settings.employee) · \(draft.rooms.filter(settings.owns).count) 间")
                    }
                    Button("查看整份 PDF") { preview = PDFPreview(url: draft.url) }
                }
                if !old.isEmpty {
                    Section("同日修订 · 确认后保留原有清扫状态与耗时") {
                        let changes = ImportDiff.changes(from: old, to: draft.rooms)
                        if changes.isEmpty { Text("无房间字段变化") }
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, summary in Text(summary) }
                    }
                }
                ForEach($draft.rooms) { $room in
                    Section(room.number.isEmpty ? "手动添加房间" : room.number) {
                        if room.needsReview { Text("识别结果需核对").foregroundStyle(.orange) }
                        TextField("房号", text: $room.number).keyboardType(.numberPad)
                        Picker("类型", selection: $room.kind) {
                            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        TextField("担当者（空白为未分配）", text: $room.employee)
                        TextField("入住人数", text: Binding(
                            get: { room.guests.map(String.init) ?? "" },
                            set: { text in
                                if text.isEmpty { room.guests = nil }
                                else if let count = Int(text), (1...99).contains(count) { room.guests = count }
                            })).keyboardType(.numberPad)
                        TextField("备注", text: $room.notes, axis: .vertical)
                        if !room.marks.isEmpty { Text(room.marks.joined(separator: " · ")) }
                        if let source = room.source {
                            Button("第 \(source.page + 1) 页 · 查看原始位置") {
                                preview = PDFPreview(url: draft.url, source: source)
                            }
                        }
                        if let sources = room.fieldSources, !sources.isEmpty {
                            Menu("查看识别字段位置") {
                                ForEach(sources.keys.sorted(), id: \.self) { field in
                                    if let source = sources[field] {
                                        Button("\(field) · \(Int(source.confidence * 100))%") {
                                            preview = PDFPreview(url: draft.url, source: source)
                                        }
                                    }
                                }
                            }
                        }
                        Button("从本版移除此行", role: .destructive) {
                            let id = room.id
                            draft.rooms.removeAll { $0.id == id }
                        }
                    }
                }
                if !draft.rooms.isEmpty {
                    Button("添加遗漏房间", systemImage: "plus") { draft.rooms.append(Room(number: "")) }
                }
                Toggle("已核对房号、任务、担当者和修订差异", isOn: $checked)
                Button("确认导入") { confirm(reviewedDraft()) }.disabled(!valid)
            }
            .navigationTitle("校对清扫表")
            .toolbar { Button("取消", action: cancel) }
        }
        .interactiveDismissDisabled()
        .sheet(item: $preview) { item in
            NavigationStack {
                PDFPositionView(url: item.url, source: item.source)
                    .navigationTitle("原始 PDF")
                    .toolbar { Button("关闭") { preview = nil } }
            }
        }
        .onChange(of: draft.rooms) { _, _ in checked = false }
        .onChange(of: draft.date) { _, _ in checked = false }
    }
}

struct PDFPositionView: UIViewRepresentable {
    let url: URL
    let source: Source?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        if let source, let page = view.document?.page(at: source.page) {
            let bounds = page.bounds(for: .mediaBox)
            let rect = CGRect(x: bounds.minX + source.x * bounds.width,
                              y: bounds.minY + source.y * bounds.height,
                              width: source.width * bounds.width, height: source.height * bounds.height)
            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            annotation.color = .systemOrange.withAlphaComponent(0.8)
            page.addAnnotation(annotation)
            view.go(to: rect, on: page)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
