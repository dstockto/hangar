import AppKit
import HangarCore

/// The panel itself. Borderless panels need canBecomeKey spelled out, and this
/// is also the last line of defence for the close-versus-quit distinction below.
final class HangarPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if HangarPanel.isDismissKey(event) {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// Command-Q and Command-W mean "close this overlay", never "quit Hangar".
    /// Hangar lives in the menubar, so quitting is an explicit menu choice.
    static func isDismissKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        return key == "q" || key == "w"
    }
}

/// A row in the results list: either a sticky product header or a host.
enum PanelRow {
    case productHeader(product: String, count: Int)
    case host(entry: SearchEntry, matches: [Range<String.Index>],
              hostMatches: [Range<String.Index>], newEnvironment: Bool)

    var isHeader: Bool {
        if case .productHeader = self { return true }
        return false
    }
}

/// The floating picker. AppKit rather than SwiftUI: an NSTextField with
/// doCommandBy interception gives real text editing plus completely predictable
/// arrow and return handling, which is the whole interaction here.
@MainActor
final class PanelController: NSObject, NSTextFieldDelegate, NSTableViewDelegate,
                             NSTableViewDataSource, NSWindowDelegate {
    private let store: FleetStore
    private var panel: HangarPanel!
    private var backdrop: NSView!
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var footer: FooterView!
    private var headerLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var separator: NSBox!

    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var collapseWork: DispatchWorkItem?
    private var editor: HostEditor?

    private var pool: [SearchEntry] = []
    private var matched: [SearchEntry] = []
    private var rows: [PanelRow] = []
    private var activeFilter: [String: String] = [:]
    private var lastQuery = ""

    init(store: FleetStore) {
        self.store = store
        super.init()
        buildPanel()
    }

    // MARK: - Construction

    private func buildPanel() {
        let metric = Brand.Metric.self
        let panel = HangarPanel(
            contentRect: NSRect(x: 0, y: 0, width: metric.panelWidth,
                                height: metric.panelInitialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                      // system shadow, none authored
        panel.minSize = metric.panelMinSize
        panel.maxSize = metric.panelMaxSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onDismiss = { [weak self] in self?.hide() }
        // Clicking away dismisses it, the way Spotlight does. Without this the
        // panel stayed on screen behind whatever was clicked, holding a query
        // nobody was still typing.
        panel.delegate = self
        panel.setAccessibilityLabel("Hangar host search")

        // System material, with the brand panel colour beneath it so the surface
        // stays correct when Reduce Transparency turns vibrancy off.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = metric.panelCornerRadius
        container.layer?.masksToBounds = true

        backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = Brand.Color.panel
            .withAlphaComponent(metric.panelFallbackOpacity).cgColor

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        headerLabel = label(font: Brand.Font.groupHeader, color: Brand.Color.textSecondary)
        headerLabel.stringValue = "HANGAR"

        let searchGlyph = NSImageView()
        // The supplied glyph set has no magnifier; the brand kit asks for a 16 pt
        // search icon, so this uses the system search affordance rather than
        // inventing brand artwork. Flagged as a deviation.
        let magnifier = NSImage(systemSymbolName: "magnifyingglass",
                                accessibilityDescription: "Search")
        magnifier?.isTemplate = true
        searchGlyph.image = magnifier
        searchGlyph.contentTintColor = Brand.Color.textSecondary
        searchGlyph.imageScaling = .scaleProportionallyUpOrDown

        searchField = NSTextField()
        searchField.placeholderString = "Filter hosts"
        searchField.font = Brand.Font.search
        searchField.textColor = Brand.Color.textPrimary
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setAccessibilityLabel("Filter hosts")

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none   // the row draws the brand capsule
        tableView.floatsGroupRows = true
        tableView.usesAutomaticRowHeights = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.doubleAction = #selector(activateSelection)
        let column = NSTableColumn(identifier: .init("host"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        emptyLabel = label(font: Brand.Font.metadata, color: Brand.Color.textSecondary)
        emptyLabel.isHidden = true

        footer = FooterView()

        separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Brand.Color.textPrimary
            .withAlphaComponent(metric.separatorOpacity)

        for view in [backdrop!, effect, headerLabel!, searchGlyph, searchField!,
                     separator!, scrollView!, emptyLabel!, footer!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        panel.contentView = container

        let inset = metric.space12
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: metric.space8),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: metric.space16),

            searchGlyph.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: metric.space16),
            searchGlyph.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchGlyph.widthAnchor.constraint(equalToConstant: metric.glyphSize),
            searchGlyph.heightAnchor.constraint(equalToConstant: metric.glyphSize),

            searchField.leadingAnchor.constraint(equalTo: searchGlyph.trailingAnchor,
                                                 constant: metric.space8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -inset),
            searchField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor,
                                             constant: metric.space4),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor,
                                           constant: metric.space8),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: metric.footerHeight),
        ])
        self.panel = panel
    }

    private func label(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        return field
    }

    // MARK: - Presentation

    var isVisible: Bool { panel.isVisible }

    func toggle(filter: [String: String], title: String) {
        if panel.isVisible && activeFilter == filter { hide() }
        else { show(filter: filter, title: title) }
    }

    func show(filter: [String: String], title: String) {
        activeFilter = filter
        pool = store.entries(matching: filter)
        // The title comes from a hotkey the user named in their own config, so
        // it keeps the capitalisation they gave it.
        headerLabel.stringValue = title
        searchField.stringValue = ""
        lastQuery = ""
        applyThemeColors()
        recompute(reason: .reset)
        resizeTo(height: Brand.Metric.panelInitialHeight)
        centerOnActiveScreen()
        if !panel.isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        installKeyMonitor()

        if store.isStale {
            Task { @MainActor in
                await store.refresh()
                pool = store.entries(matching: activeFilter)
                recompute(reason: .reset)
            }
        }
    }

    func hide(restoringFocus: Bool = true) {
        collapseWork?.cancel()
        removeKeyMonitor()
        panel.orderOut(nil)
        // Cleared on the way out as well as on the way in, so a query never
        // flashes back up in the frame before the next show() resets it.
        searchField.stringValue = ""
        lastQuery = ""
        if restoringFocus, let previousApp,
           previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// Losing key means the click landed somewhere else, so the panel goes away.
    /// Focus is not handed back to the previous app here: whatever was clicked is
    /// already frontmost, and activating anything else would take it away again.
    ///
    /// One of our own windows taking key, the ssh settings editor from
    /// command-click, is not clicking away.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        Task { @MainActor in
            guard panel.isVisible, !panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, key !== panel { return }
            if editor != nil { return }
            hide(restoringFocus: false)
        }
    }

    /// Named colours resolve against the drawing appearance, so anything cached
    /// in a CALayer has to be refreshed when the panel is shown.
    private func applyThemeColors() {
        panel.appearance = nil
        backdrop.layer?.backgroundColor = Brand.Color.panel
            .withAlphaComponent(Brand.Metric.panelFallbackOpacity).cgColor
        separator.fillColor = Brand.Color.textPrimary
            .withAlphaComponent(Brand.Metric.separatorOpacity)
        searchField.textColor = Brand.Color.textPrimary
        headerLabel.textColor = Brand.Color.textSecondary
        emptyLabel.textColor = Brand.Color.textSecondary
    }

    private func resizeTo(height: CGFloat) {
        var frame = panel.frame
        let clamped = min(max(height, Brand.Metric.panelMinSize.height),
                          Brand.Metric.panelMaxSize.height)
        frame.origin.y += frame.height - clamped
        frame.size.height = clamped
        panel.setFrame(frame, display: true)
    }

    /// Opens on whichever screen has the mouse, top edge 18% below the screen top.
    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let top = visible.maxY - visible.height * Brand.Metric.panelTopFraction
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: top - size.height))
    }

    // MARK: - Filtering

    private enum RecomputeReason { case reset, narrowed, widened }

    private func recompute(reason: RecomputeReason) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            matched = pool
        } else {
            // Subsequence matching is monotone: if a query does not match, no
            // extension of it can either. So an added character only ever filters
            // the previous result set, never the whole fleet.
            let source = (reason == .narrowed && !lastQuery.isEmpty
                          && query.hasPrefix(lastQuery)) ? matched : pool
            // Ranked in the core, so the panel and the hangar command cannot
            // disagree about which host best matches a query.
            matched = FleetIndex.ranked(source, matching: Fuzzy.Query(query))
        }
        lastQuery = query

        let previousSelection = selectedEntry()?.instance.id
        rows = PanelController.group(matched, query: query)

        // Sticky headers stop helping once everything is on screen.
        tableView.floatsGroupRows = matched.count >= 12

        // The first result is always selected, so Return connects without touching
        // the arrow keys. A selection that survived the narrowing is kept instead.
        var target = rows.firstIndex { if case .host = $0 { return true } else { return false } }
        if let previousSelection,
           let kept = rows.firstIndex(where: {
               if case .host(let entry, _, _, _) = $0 {
                   return entry.instance.id == previousSelection
               }
               return false
           }) {
            target = kept
        }

        tableView.reloadData()
        if let target {
            tableView.selectRowIndexes([target], byExtendingSelection: false)
            reveal(row: target, isFirstResult: target <= 1)
        }

        emptyLabel.isHidden = !matched.isEmpty
        if matched.isEmpty {
            emptyLabel.stringValue = query.isEmpty
                ? "No hosts found."
                : "No hosts match \u{201C}\(query)\u{201D}."
        }
        footer.update(store: store, resultCount: matched.count, totalCount: pool.count)
        scheduleCollapse()
    }

    /// Product headers with counts, plus a divider marker when the environment
    /// changes inside a product. Environment never gets a header of its own.
    static func group(_ entries: [SearchEntry], query: String) -> [PanelRow] {
        // Parsed once for the whole list rather than per row.
        let parsed = Fuzzy.Query(query)
        var rows: [PanelRow] = []
        rows.reserveCapacity(entries.count + 8)
        var index = 0
        while index < entries.count {
            let product = entries[index].instance.product
            var end = index
            while end < entries.count, entries[end].instance.product == product { end += 1 }
            let slice = entries[index..<end]
            rows.append(.productHeader(product: product.isEmpty ? "untagged" : product,
                                       count: slice.count))
            var previousEnvironment: String?
            for entry in slice {
                let environment = entry.instance.env
                let changed = previousEnvironment != nil && previousEnvironment != environment
                previousEnvironment = environment
                let matches = parsed.isEmpty ? [] : Fuzzy.ranges(query: parsed, in: entry.alias)
                let hostMatches = parsed.isEmpty
                    ? [] : Fuzzy.ranges(query: parsed, in: entry.hostname)
                rows.append(.host(entry: entry, matches: matches,
                                  hostMatches: hostMatches, newEnvironment: changed))
            }
            index = end
        }
        return rows
    }

    /// scrollRowToVisible does nothing when a row is already *partially* visible, so
    /// a leftover scroll position from the previous query can leave the selected row
    /// half hidden under the sticky product header. For the first result, go to the
    /// top outright; otherwise scroll it clear of the floating header.
    private func reveal(row: Int, isFirstResult: Bool) {
        if isFirstResult {
            tableView.scroll(.zero)
            return
        }
        tableView.scrollRowToVisible(row)
        guard tableView.floatsGroupRows else { return }
        let rowRect = tableView.rect(ofRow: row)
        let visible = tableView.visibleRect
        let hidden = (visible.minY + Brand.Metric.groupHeaderHeight) - rowRect.minY
        if hidden > 0 {
            tableView.scroll(NSPoint(x: visible.minX, y: max(0, visible.minY - hidden)))
        }
    }

    /// The panel holds its height while typing, then settles to content height.
    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            let content = self.rows.reduce(CGFloat.zero) { total, row in
                total + (row.isHeader ? Brand.Metric.groupHeaderHeight
                                      : Brand.Metric.hostRowHeight)
            }
            let chrome = Brand.Metric.searchRegionHeight + Brand.Metric.footerHeight + 12
            let target = min(Brand.Metric.panelInitialHeight, content + chrome)
            guard abs(target - self.panel.frame.height) > 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Brand.Metric.collapseAnimation
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                var frame = self.panel.frame
                frame.origin.y += frame.height - target
                frame.size.height = target
                self.panel.animator().setFrame(frame, display: true)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Brand.Metric.collapseDelay,
                                      execute: work)
    }

    // MARK: - Actions

    /// A plain click just selects. Command-click opens the ssh settings editor,
    /// which is where a wrong login gets fixed.
    @objc private func handleClick() {
        guard NSEvent.modifierFlags.contains(.command) else { return }
        editSelection()
    }

    private func editSelection() {
        guard let entry = selectedEntry() else { return }
        hide()
        let editor = HostEditor(store: store, instance: entry.instance,
                                alias: entry.alias) { [weak self] message in
            Notifier.show(title: "SSH settings", body: message, seconds: 3)
            self?.editor = nil
        }
        self.editor = editor
        editor.show()
    }

    @objc private func activateSelection() {
        guard let entry = selectedEntry() else { return }
        let (command, _) = store.sshTarget(for: entry.instance)
        hide()
        Launcher.open(command: command, in: store.terminal) { problem in
            Notifier.show(title: "Could not open a terminal", body: problem, seconds: 4)
        }
    }

    private func copySelection() {
        guard let entry = selectedEntry() else { return }
        let (command, _) = store.sshTarget(for: entry.instance)
        Launcher.copyToClipboard(command)
        footer.flashCopied()
        Notifier.show(title: "Copied", body: command)
    }

    private func selectedEntry() -> SearchEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .host(let entry, _, _, _) = rows[row] else {
            return nil
        }
        return entry
    }

    /// Moves selection over host rows only, stepping past product headers.
    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = tableView.selectedRow
        var index = current < 0 ? -1 : current
        let step = delta > 0 ? 1 : -1
        var remaining = abs(delta)
        while remaining > 0 {
            var next = index + step
            while next >= 0, next < rows.count, rows[next].isHeader { next += step }
            if next < 0 || next >= rows.count { break }
            index = next
            remaining -= 1
        }
        guard index >= 0, index < rows.count, !rows[index].isHeader else { return }
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    // MARK: - Key handling

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if HangarPanel.isDismissKey(event) {
                self.hide()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "r" {
                self.refreshNow()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
                self.editSelection()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func refreshNow() {
        footer.update(store: store, resultCount: matched.count, totalCount: pool.count)
        Task { @MainActor in
            await self.store.refresh()
            self.pool = self.store.entries(matching: self.activeFilter)
            self.recompute(reason: .reset)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        recompute(reason: query.count > lastQuery.count ? .narrowed : .widened)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)):   move(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.command) { copySelection() }
            else { activateSelection() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            move(by: -rows.count); return true
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            move(by: rows.count); return true
        case #selector(NSResponder.scrollPageUp(_:)):   move(by: -8); return true
        case #selector(NSResponder.scrollPageDown(_:)): move(by: 8); return true
        default: return false
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].isHeader ? Brand.Metric.groupHeaderHeight : Brand.Metric.hostRowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        switch rows[row] {
        case .productHeader(let product, let count):
            let id = NSUserInterfaceItemIdentifier("ProductHeader")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? ProductHeaderView
                ?? ProductHeaderView(identifier: id)
            view.configure(product: product, count: count)
            return view
        case .host(let entry, let matches, let hostMatches, let newEnvironment):
            let id = NSUserInterfaceItemIdentifier("HostRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? HostRowView
                ?? HostRowView(identifier: id)
            view.configure(entry: entry, matches: matches, hostMatches: hostMatches,
                           showsDivider: newEnvironment,
                           selected: tableView.selectedRow == row)
            return view
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection is drawn by the rows, so both the old and new row must redraw.
        // Only the rows on screen exist, so only those need telling.
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostRowView)?
                .updateSelection(tableView.selectedRow == row)
        }
    }
}
