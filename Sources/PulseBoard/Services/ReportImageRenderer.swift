import AppKit
import SwiftUI

/// Renders the GFM Markdown morning report (the exact text shown in the web console / copied to
/// Feishu) into a PNG card that can be pasted straight into a group chat.
///
/// Only the Markdown subset produced by `MarkdownReportGenerator` / the web console is supported:
/// `#`/`##`/`###` headings, `>` quote blocks, pipe tables, `- ` bullet lists and paragraphs, with
/// inline `**bold**` and `` `code` ``.
enum ReportImageRenderer {
    enum RenderError: LocalizedError {
        case renderFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: "晨报图片渲染失败"
            case .encodeFailed: "晨报图片 PNG 编码失败"
            }
        }
    }

    static let canvasWidth: CGFloat = 1180

    @MainActor
    static func renderPNG(markdown: String, scale: CGFloat = 2) throws -> Data {
        let blocks = ReportMarkdownParser.parse(markdown)
        let content = ReportImageView(blocks: blocks, generatedAt: Date())
            .frame(width: canvasWidth)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: canvasWidth, height: nil)
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { throw RenderError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.encodeFailed }
        return png
    }

    @MainActor
    static func copyToPasteboard(png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
    }
}

// MARK: - Markdown block parsing

enum ReportMarkdownBlock {
    enum Align { case leading, center, trailing }

    case h1(String)
    case h2(String)
    case h3(String)
    case quote([String])
    case table(header: [String], aligns: [Align], rows: [[String]])
    case bullets([String])
    case paragraph(String)
}

enum ReportMarkdownParser {
    static func parse(_ markdown: String) -> [ReportMarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [ReportMarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if line.hasPrefix("### ") { blocks.append(.h3(String(line.dropFirst(4)))); i += 1; continue }
            if line.hasPrefix("## ") { blocks.append(.h2(String(line.dropFirst(3)))); i += 1; continue }
            if line.hasPrefix("# ") { blocks.append(.h1(String(line.dropFirst(2)))); i += 1; continue }

            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    var l = String(lines[i].dropFirst())
                    if l.hasPrefix(" ") { l.removeFirst() }
                    if l.hasPrefix("- ") { l.removeFirst(2) }
                    if !l.trimmingCharacters(in: .whitespaces).isEmpty { quoteLines.append(l) }
                    i += 1
                }
                if !quoteLines.isEmpty { blocks.append(.quote(quoteLines)) }
                continue
            }

            if line.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].contains("---") {
                let header = splitCells(line)
                let aligns: [ReportMarkdownBlock.Align] = splitCells(lines[i + 1]).map { a in
                    if a.hasPrefix(":") && a.hasSuffix(":") { return .center }
                    if a.hasSuffix(":") { return .trailing }
                    return .leading
                }
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].hasPrefix("|") {
                    var cells = splitCells(lines[i])
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, aligns: aligns, rows: rows))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count, lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ") {
                    items.append(String(lines[i].dropFirst(2)))
                    i += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            blocks.append(.paragraph(line))
            i += 1
        }
        return blocks
    }

    /// Splits a GFM table row on unescaped `|`, turning `\|` back into a literal pipe.
    static func splitCells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var current = ""
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                if let next = iterator.next() {
                    if next == "|" { current.append("|") } else { current.append(ch); current.append(next) }
                } else {
                    current.append(ch)
                }
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func inline(_ text: String) -> AttributedString {
        // Pipes were already unescaped by splitCells; protect any remaining literal backslashes.
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Layout grouping

/// Groups the flat Markdown blocks into the morning-report layout:
/// header (title + meta) → headline KPI strip → section cards.
struct ReportLayout {
    struct KPI {
        let label: String
        let value: String
        let caption: String
    }

    struct Section {
        let title: String?
        var blocks: [ReportMarkdownBlock]
    }

    var title: String = "Clipto 性能晨报"
    var meta: [String] = []
    var kpis: [KPI] = []
    var sections: [Section] = []

    init(blocks: [ReportMarkdownBlock]) {
        var i = 0
        var seenSection = false
        while i < blocks.count {
            let block = blocks[i]
            switch block {
            case .h1(let t) where !seenSection:
                title = t
            case .quote(let lines) where !seenSection:
                meta += lines
            case .h2(let t) where t.contains("头条"):
                seenSection = true
                if i + 1 < blocks.count, case .table(let header, _, let rows) = blocks[i + 1], let values = rows.first {
                    let captions = rows.count > 1 ? rows[1] : []
                    kpis = header.indices.map { idx in
                        KPI(label: header[idx],
                            value: idx < values.count ? values[idx] : "—",
                            caption: idx < captions.count ? captions[idx] : "")
                    }
                    i += 1
                }
            case .h2(let t):
                seenSection = true
                sections.append(Section(title: t, blocks: []))
            default:
                if sections.isEmpty { sections.append(Section(title: nil, blocks: [])) }
                sections[sections.count - 1].blocks.append(block)
            }
            i += 1
        }
    }
}

// MARK: - SwiftUI card

private enum Palette {
    static let ink = Color(red: 0.09, green: 0.11, blue: 0.19)
    static let muted = Color(red: 0.42, green: 0.46, blue: 0.55)
    static let line = Color(red: 0.89, green: 0.91, blue: 0.95)
    static let canvas = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let accent = Color(red: 0.23, green: 0.36, blue: 0.95)
    static let bandTop = Color(red: 0.07, green: 0.09, blue: 0.24)
    static let bandMid = Color(red: 0.16, green: 0.15, blue: 0.47)
    static let bandEnd = Color(red: 0.11, green: 0.33, blue: 0.80)
    static let kpiColors: [Color] = [
        Color(red: 0.02, green: 0.59, blue: 0.41),  // speed – emerald
        Color(red: 0.49, green: 0.23, blue: 0.93),  // memory – violet
        Color(red: 0.92, green: 0.35, blue: 0.05),  // CPU – orange
        Color(red: 0.15, green: 0.39, blue: 0.92)   // GPU – blue
    ]
}

private struct ReportImageView: View {
    let blocks: [ReportMarkdownBlock]
    let generatedAt: Date

    private var layout: ReportLayout { ReportLayout(blocks: blocks) }

    var body: some View {
        let layout = self.layout
        VStack(alignment: .leading, spacing: 0) {
            header(layout)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(layout.sections.enumerated()), id: \.offset) { _, section in
                    sectionCard(section)
                }
                footer
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
    }

    // MARK: Header band

    private func header(_ layout: ReportLayout) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                pill("macOS 版")
                pill("每日晨报")
                Spacer()
                Text("CliptoPulse")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(ReportMarkdownParser.inline(layout.title))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !layout.meta.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(layout.meta.enumerated()), id: \.offset) { _, line in
                        Text(ReportMarkdownParser.inline(line))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !layout.kpis.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(layout.kpis.enumerated()), id: \.offset) { idx, kpi in
                        kpiCard(kpi, color: Palette.kpiColors[idx % Palette.kpiColors.count])
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [Palette.bandTop, Palette.bandMid, Palette.bandEnd],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Light decorative glows – cheap "art" that always renders the same.
                Circle().fill(Color.white.opacity(0.07)).frame(width: 420, height: 420).offset(x: 430, y: -170)
                Circle().fill(Color.cyan.opacity(0.10)).frame(width: 260, height: 260).offset(x: 520, y: 120)
                Circle().fill(Color.purple.opacity(0.12)).frame(width: 300, height: 300).offset(x: -520, y: 160)
            }
            .clipped()
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    private func kpiCard(_ kpi: ReportLayout.KPI, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(ReportMarkdownParser.inline(kpi.label))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            Text(ReportMarkdownParser.inline(kpi.value.replacingOccurrences(of: "**", with: "")))
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(ReportMarkdownParser.inline(kpi.caption))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.white)
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                .fill(color)
                .frame(height: 4)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    // MARK: Section cards

    private func sectionCard(_ section: ReportLayout.Section) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = section.title {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 5, height: 20)
                    Text(ReportMarkdownParser.inline(title))
                        .font(.system(size: 20, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .shadow(color: Color(red: 0.2, green: 0.25, blue: 0.45).opacity(0.08), radius: 12, y: 4)
    }

    @ViewBuilder
    private func blockView(_ block: ReportMarkdownBlock) -> some View {
        switch block {
        case .h1(let t), .h2(let t):
            Text(ReportMarkdownParser.inline(t))
                .font(.system(size: 18, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        case .h3(let t):
            Text(ReportMarkdownParser.inline(t))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        case .quote(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(ReportMarkdownParser.inline(item))
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color(red: 1.0, green: 0.97, blue: 0.90))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.orange.opacity(0.8)).frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .table(let header, let aligns, let rows):
            tableView(header: header, aligns: aligns, rows: rows)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.accent)
                        Text(ReportMarkdownParser.inline(item))
                            .font(.system(size: 14.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .paragraph(let t):
            Text(ReportMarkdownParser.inline(t))
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tableView(header: [String], aligns: [ReportMarkdownBlock.Align], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { idx, h in
                    cell(h, align: align(aligns, idx), isHeader: true)
                }
            }
            .background(Color(red: 0.95, green: 0.96, blue: 0.99))
            ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                Rectangle().fill(Palette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { idx, c in
                        cell(c, align: align(aligns, idx), isHeader: false)
                    }
                }
                .background(rIdx % 2 == 1 ? Color(red: 0.985, green: 0.988, blue: 0.997) : Color.white)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func align(_ aligns: [ReportMarkdownBlock.Align], _ idx: Int) -> ReportMarkdownBlock.Align {
        idx < aligns.count ? aligns[idx] : .leading
    }

    private func cell(_ text: String, align: ReportMarkdownBlock.Align, isHeader: Bool) -> some View {
        let frameAlign: Alignment = switch align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let textAlign: TextAlignment = switch align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(ReportMarkdownParser.inline(text))
            .font(.system(size: 13.5, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? Palette.muted : Palette.ink)
            .multilineTextAlignment(textAlign)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlign)
    }

    private var footer: some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return HStack {
            Text("CliptoPulse 自动生成 · \(f.string(from: generatedAt))")
            Spacer()
            Text("数据源：Clipto DAGSC schedule.db + CliptoPulse 硬件采样")
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 4)
    }
}
