import SwiftUI

struct TodayHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let date: Date
    let hotel: String
    let employee: String
    let total: Int
    let priority: Int
    let completed: Int
    let processing: Bool
    let importStatus: String?
    let importDisabled: Bool
    let importPDF: () -> Void
    let openSettings: () -> Void

    private var progress: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(date, format: .dateTime.month().day().weekday())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("今日清扫")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if !hotel.isEmpty {
                    Text(hotel).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                if employee.isEmpty {
                    Button("设置担当者", systemImage: "person.crop.circle.badge.plus", action: openSettings)
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .padding(.top, 3)
                } else {
                    Label(employee, systemImage: "person.crop.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: importPDF) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.headline)
                    Text("导入 PDF").font(.headline)
                    Spacer()
                    Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 15)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .background(.primary, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .opacity(importDisabled ? 0.55 : 1)
            .disabled(importDisabled)
            .accessibilityIdentifier("today.importPDF")

            if let importStatus {
                Group {
                    if processing { ProgressView(importStatus) }
                    else { Text(importStatus).textSelection(.enabled) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("today.importStatus")
            }

            VStack(alignment: .leading, spacing: 13) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { metrics }
                    VStack(alignment: .leading, spacing: 10) { metrics }
                }
                ProgressView(value: progress)
                    .tint(.primary)
                    .accessibilityLabel("清扫完成进度")
            }
            .padding(16)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var metrics: some View {
        metric("我的房间", value: "\(total)")
        metric("优先", value: "\(priority)")
        metric("已完成", value: "\(completed)/\(total)")
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
