import SwiftUI

struct ConsoleLog: Identifiable, Equatable {
    let id = UUID()
    let level: String // "log", "warn", "error"
    let message: String
    let timestamp: Date
    
    var color: Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        default: return .primary
        }
    }
    
    var iconName: String {
        switch level {
        case "error": return "exclamationmark.octagon.fill"
        case "warn": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }
}

struct ConsoleLogRow: View {
    let log: ConsoleLog
    let dateFormatter: DateFormatter
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: log.iconName)
                .font(.caption2)
                .foregroundStyle(log.color)
                .padding(.top, 3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(log.message)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(log.color)
                    .textSelection(.enabled)
                
                Text(dateFormatter.string(from: log.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
    }
}

struct NetworkRequest: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var method: String
    var status: Int
    var statusText: String
    var type: String
    var size: Int
    var time: Int // duration in ms
    var timestamp: Date
    var headers: [String: String]
    var responsePreview: String
    
    var resourceName: String {
        guard let urlObj = URL(string: url) else {
            return url
        }
        let last = urlObj.lastPathComponent
        return last.isEmpty ? (urlObj.host ?? url) : last
    }
    
    var statusColor: Color {
        if status >= 200 && status < 300 {
            return .green
        } else if status >= 300 && status < 400 {
            return .blue
        } else if status >= 400 {
            return .red
        } else {
            return .secondary
        }
    }
}

struct PerformanceMetrics: Equatable {
    var loadTime: Double = 0.0 // ms
    var domReady: Double = 0.0 // ms
    var redirectCount: Int = 0
    var jsHeapSize: Double = 0.0 // bytes
    var jsHeapLimit: Double = 0.0 // bytes
}

struct ElementInfo: Identifiable, Equatable {
    let id = UUID()
    let tag: String
    let idAttribute: String
    let classes: [String]
    let dimensions: String
    let styles: [String: String]
    let selector: String
    let xpath: String
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case log = "Logs"
    case warn = "Warnings"
    case error = "Errors"
    var id: String { rawValue }
}

struct ConsoleSheet: View {
    @Binding var logs: [ConsoleLog]
    let onExecuteJS: (String) -> Void
    let onClear: () -> Void
    /// Hand the captured warnings/errors to the agent to fix.
    var onAskAgent: ((String) -> Void)? = nil
    @Environment(\.dismiss) var dismiss

    @State private var command: String = ""
    @State private var selectedFilter: LogFilter = .all
    @State private var animateRows = false

    /// Warnings + errors — the actionable subset to send the agent.
    private var issues: [ConsoleLog] {
        logs.filter { $0.level == "warn" || $0.level == "error" }
    }

    private func askAgentToFix() {
        let lines = issues.map { "\($0.level.uppercased()): \($0.message)" }.joined(separator: "\n")
        onAskAgent?("My site's preview console reported these issues. Find the cause in the code and fix it:\n\n\(lines)")
    }
    
    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    var filteredLogs: [ConsoleLog] {
        switch selectedFilter {
        case .all: return logs
        case .log: return logs.filter { $0.level == "log" }
        case .warn: return logs.filter { $0.level == "warn" }
        case .error: return logs.filter { $0.level == "error" }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Stylish filter picker
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(LogFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .appSecondaryBackground()
                
                Divider()
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if filteredLogs.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "terminal")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                    Text("No logs captured matching filter.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                ForEach(filteredLogs) { log in
                                    ConsoleLogRow(log: log, dateFormatter: Self.logDateFormatter)
                                        .id(log.id)
                                        .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                    .onChange(of: filteredLogs.count) { _, _ in
                        if let last = filteredLogs.last {
                            withAnimation(Theme.spring) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .appBackground(.primary)
                
                Divider()
                
                HStack(spacing: 12) {
                    TextField("Execute JS...", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    Button {
                        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        Haptics.tap()
                        onExecuteJS(command)
                        command = ""
                    } label: {
                        Text("Run")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Theme.actionGradient, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.pressable)
                }
                .padding()
                .appSecondaryBackground()
            }
            .navigationTitle("Live Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        Haptics.tap()
                        onClear()
                    }
                }
                if onAskAgent != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.tap()
                            askAgentToFix()
                        } label: {
                            Label("Fix with AI", systemImage: "wand.and.stars")
                        }
                        .disabled(issues.isEmpty)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                withAnimation(Theme.snappy) {
                    animateRows = true
                }
            }
        }
    }
}

struct NetworkSheet: View {
    @Binding var requests: [NetworkRequest]
    @Environment(\.dismiss) var dismiss
    @State private var selectedRequest: NetworkRequest?
    
    var body: some View {
        NavigationStack {
            List(requests) { req in
                Button {
                    Haptics.tap()
                    selectedRequest = req
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(req.resourceName)
                                .font(.system(.subheadline, design: .monospaced))
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            
                            Text(req.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("\(req.status)")
                                    .font(.caption.monospacedDigit())
                                    .fontWeight(.bold)
                                    .foregroundStyle(req.statusColor)
                                
                                Text(req.method)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            }
                            
                            HStack(spacing: 6) {
                                Text(formatBytes(req.size))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                
                                Text("\(req.time)ms")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .foregroundStyle(.primary)
                .appListRowBackground()
            }
            .listStyle(.plain)
            .appBackground(.primary)
            .navigationTitle("Network Traffic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        Haptics.tap()
                        requests.removeAll()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedRequest) { req in
                NetworkDetailView(request: req)
            }
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB"]
        var size = Double(bytes)
        var unitIndex = 0
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", size, units[unitIndex])
    }
}

struct NetworkDetailView: View {
    let request: NetworkRequest
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Summary") {
                    LabeledContent("URL", value: request.url)
                    LabeledContent("Method", value: request.method)
                    LabeledContent("Status", value: "\(request.status) (\(request.statusText))")
                    LabeledContent("Content Type", value: request.type)
                    LabeledContent("Duration", value: "\(request.time) ms")
                    LabeledContent("Size", value: "\(request.size) bytes")
                }
                .appListRowBackground()
                
                Section("Response Headers") {
                    if request.headers.isEmpty {
                        Text("No response headers captured").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(request.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, val in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.brand)
                                Text(val)
                                    .font(.system(.footnote, design: .monospaced))
                            }
                        }
                    }
                }
                .appListRowBackground()
                
                Section("Response Preview") {
                    if request.responsePreview.isEmpty {
                        Text("Empty response body").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(request.responsePreview)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .appSecondaryBackground()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(maxHeight: 250)
                    }
                }
                .appListRowBackground()
            }
            .appBackground(.grouped)
            .navigationTitle("Request Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PerformanceSheet: View {
    let metrics: PerformanceMetrics
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            MetricCard(title: "Load Time", value: String(format: "%.0f ms", metrics.loadTime), icon: "timer", color: .purple)
                            MetricCard(title: "DOM Content", value: String(format: "%.0f ms", metrics.domReady), icon: "doc.plaintext", color: .blue)
                        }
                        
                        HStack(spacing: 16) {
                            MetricCard(title: "Redirects", value: "\(metrics.redirectCount)", icon: "arrow.triangle.2.circlepath", color: .orange)
                            MetricCard(title: "JS Memory", value: formatHeap(metrics.jsHeapSize), icon: "memorychip", color: .green)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Core Diagnostics")
                }
                
                Section("Memory Details") {
                    LabeledContent("Used JS Heap", value: formatHeap(metrics.jsHeapSize))
                    LabeledContent("JS Heap Limit", value: formatHeap(metrics.jsHeapLimit))
                }
                .appListRowBackground()
                
                Section("Diagnostics Guide") {
                    Text("• **Load Time** measures the delay from the initial request to the triggering of window.onload.\n\n• **DOM Content** measures the parsing time of the main HTML body.\n\n• **JS Memory** estimates the active JavaScript heap usage. High heap sizes can indicate memory leaks in single page applications.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .appListRowBackground()
            }
            .appBackground(.grouped)
            .navigationTitle("Performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatHeap(_ bytes: Double) -> String {
        guard bytes > 0 else { return "Unavailable" }
        let mb = bytes / 1024 / 1024
        return String(format: "%.2f MB", mb)
    }
}

struct AuditSheet: View {
    let issues: [SiteAuditIssue]
    var onAskAgent: ((String) -> Void)? = nil
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: issue.severity))
                                .foregroundStyle(color(for: issue.severity))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } header: {
                    Text("Audit Results")
                }
                .appListRowBackground()

                if onAskAgent != nil {
                    Section {
                        Button {
                            Haptics.tap()
                            onAskAgent?(agentPrompt)
                            dismiss()
                        } label: {
                            Label("Fix with AI", systemImage: "wand.and.stars")
                        }
                    }
                    .appListRowBackground()
                }
            }
            .appBackground(.grouped)
            .navigationTitle("Site Audit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var agentPrompt: String {
        let lines = issues.map { "- \($0.severity.rawValue): \($0.title) — \($0.detail)" }.joined(separator: "\n")
        return "The preview audit found these issues. Inspect the relevant files and stage the smallest safe fixes:\n\n\(lines)"
    }

    private func icon(for severity: SiteAuditIssue.Severity) -> String {
        switch severity {
        case .info: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: SiteAuditIssue.Severity) -> Color {
        switch severity {
        case .info: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.headline)
                Spacer()
            }
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .cardSurface(cornerRadius: Theme.cornerSmall)
        .overlay(   // per-metric accent on top of the shared card surface
            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                .strokeBorder(color.opacity(0.18), lineWidth: 1.5)
        )
        .scaleEffect(hovered ? 1.04 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.62), value: hovered)
        .onAppear {
            // Decorative pop — skip entirely under Reduce Motion.
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                hovered = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation {
                        hovered = false
                    }
                }
            }
        }
    }
}

struct ElementInspectorSheet: View {
    let element: ElementInfo
    let onHighlightPermanently: () -> Void
    /// Prefill a chat instruction targeting this element (user completes & sends).
    var onAskAgent: ((String) -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    
    @State private var copiedText: String?
    @State private var styleQuery: String = ""
    @State private var animateHeader = false
    
    var filteredStyles: [(key: String, value: String)] {
        let sorted = element.styles.sorted(by: { $0.key < $1.key })
        if styleQuery.isEmpty { return sorted }
        return sorted.filter { $0.key.localizedCaseInsensitiveContains(styleQuery) || $0.value.localizedCaseInsensitiveContains(styleQuery) }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header Tag Pill
                    HStack(spacing: 8) {
                        Text(element.tag)
                            .font(.system(.headline, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Theme.actionGradient)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .scaleEffect(animateHeader ? 1.0 : 0.8)
                            .opacity(animateHeader ? 1.0 : 0.0)
                        
                        if !element.idAttribute.isEmpty {
                            Text("#\(element.idAttribute)")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(element.dimensions)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    
                    // Classes list
                    if !element.classes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Classes")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(element.classes, id: \.self) { cls in
                                        Text(".\(cls)")
                                            .font(.system(.caption, design: .monospaced))
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    // Copy targets list
                    VStack(alignment: .leading, spacing: 12) {
                        CopyRow(title: "Selector", value: element.selector, onCopy: { copyToClipboard(element.selector, "Selector") })
                        CopyRow(title: "XPath", value: element.xpath, onCopy: { copyToClipboard(element.xpath, "XPath") })
                    }
                    .padding(.horizontal)
                    
                    // Hand this element to the agent to edit.
                    if let onAskAgent {
                        Button {
                            Haptics.tap()
                            let selector = element.selector.isEmpty ? element.tag.lowercased() : element.selector
                            onAskAgent("On my site, update the \(element.tag.lowercased()) element matching CSS selector `\(selector)` — ")
                        } label: {
                            Label("Edit with AI", systemImage: "wand.and.stars")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.actionGradient, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.horizontal)
                        .buttonStyle(.pressable)
                    }

                    // Permanent highlight button
                    Button {
                        Haptics.success()
                        onHighlightPermanently()
                    } label: {
                        Label("Highlight Permanently", systemImage: "paintbrush.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    .buttonStyle(.pressable)
                    
                    // Computed styles section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Computed Styles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        
                        // Search bar inside element computed styles
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search properties (e.g. margin, display)...", text: $styleQuery)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(8)
                        .appSecondaryBackground()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                        
                        VStack(spacing: 0) {
                            if filteredStyles.isEmpty {
                                Text("No matching CSS properties found.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                ForEach(filteredStyles, id: \.key) { key, val in
                                    HStack {
                                        Text(key)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(val)
                                            .font(.system(.footnote, design: .monospaced))
                                            .fontWeight(.medium)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal)
                                    
                                    Divider()
                                }
                            }
                        }
                        .appSecondaryBackground()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .appBackground(.primary)
            .navigationTitle("Inspect Element")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay(
                Group {
                    if let text = copiedText {
                        Text("Copied \(text)!")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassSurface(.capsule, cornerRadius: 999)
                            .foregroundStyle(.primary)
                            .transition(.opacity.combined(with: .scale))
                            .padding(.bottom, 40)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            )
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.65)) {
                    animateHeader = true
                }
            }
        }
    }
    
    private func copyToClipboard(_ value: String, _ name: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        withAnimation {
            copiedText = name
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                copiedText = nil
            }
        }
    }
}

struct CopyRow: View {
    let title: String
    let value: String
    let onCopy: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            
            HStack {
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(Theme.brand)
                }
            }
            .padding(10)
            .appSecondaryBackground()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
