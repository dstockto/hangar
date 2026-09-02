import AppKit
import HangarCore

/// Per-host ssh settings editor, opened with Command-click or Command-E.
///
/// Edits are saved as overrides in ~/.hangar/config.json, never written straight
/// into ~/.ssh/config.d/hangar: that file is regenerated wholesale on every
/// refresh, so a direct edit would survive exactly until the next sync.
@MainActor
final class HostEditor: NSObject, NSWindowDelegate {
    private let store: FleetStore
    private let instance: Instance
    private let alias: String
    private let onSaved: (String) -> Void

    private var window: NSWindow!
    private var userField: NSTextField!
    private var keyField: NSTextField!
    private var scopePopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var detectButton: NSButton!
    private var testButton: NSButton!
    private var saveButton: NSButton!
    private var removeButton: NSButton!

    private var scopes: [FleetStore.OverrideScope] = []
    private var effective: (user: String?, identityFile: String?) = (nil, nil)
    private var busy = false

    init(store: FleetStore, instance: Instance, alias: String,
         onSaved: @escaping (String) -> Void) {
        self.store = store
        self.instance = instance
        self.alias = alias
        self.onSaved = onSaved
        super.init()
        build()
    }

    // MARK: - Construction

    private func build() {
        scopes = FleetStore.OverrideScope.all(for: instance)
        effective = store.effectiveSSHSettings(for: instance)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 268),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SSH settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating

        let host = NSTextField(labelWithString: alias)
        host.font = Brand.Font.hostPrimary
        host.textColor = Brand.Color.textPrimary

        let hostname = NSTextField(labelWithString: instance.host ?? instance.id)
        hostname.font = Brand.Font.shortcut
        hostname.textColor = Brand.Color.textSecondary
        hostname.lineBreakMode = .byTruncatingMiddle

        userField = NSTextField()
        userField.font = Brand.Font.hostPrimary
        userField.placeholderString = effective.user ?? NSUserName()
        userField.setAccessibilityLabel("SSH user")

        keyField = NSTextField()
        keyField.font = Brand.Font.hostPrimary
        keyField.placeholderString = effective.identityFile ?? "ssh agent and default keys"
        keyField.setAccessibilityLabel("Identity file")

        let choose = NSButton(title: "Choose\u{2026}", target: self,
                              action: #selector(chooseKey))
        choose.bezelStyle = .rounded

        scopePopup = NSPopUpButton()
        scopePopup.addItems(withTitles: scopes.map(\.label))
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.setAccessibilityLabel("Applies to")

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = Brand.Font.metadata
        statusLabel.textColor = Brand.Color.textSecondary
        statusLabel.lineBreakMode = .byTruncatingTail

        detectButton = NSButton(title: "Detect Login", target: self,
                                action: #selector(detect))
        testButton = NSButton(title: "Test", target: self, action: #selector(test))
        removeButton = NSButton(title: "Remove Override", target: self,
                                action: #selector(removeOverride))
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        for button in [detectButton!, testButton!, removeButton!, saveButton!, cancel] {
            button.bezelStyle = .rounded
        }

        let keyRow = NSStackView(views: [keyField, choose])
        keyRow.orientation = .horizontal
        keyRow.spacing = Brand.Metric.space8

        let form = NSGridView(views: [
            [labelCell("Host"), host],
            [NSGridCell.emptyContentView, hostname],
            [labelCell("SSH user"), userField],
            [labelCell("Identity file"), keyRow],
            [labelCell("Applies to"), scopePopup],
        ])
        form.rowSpacing = Brand.Metric.space8
        form.columnSpacing = Brand.Metric.space12
        form.column(at: 0).xPlacement = .trailing

        let leftButtons = NSStackView(views: [detectButton, testButton, removeButton])
        leftButtons.orientation = .horizontal
        leftButtons.spacing = Brand.Metric.space8

        let rightButtons = NSStackView(views: [cancel, saveButton])
        rightButtons.orientation = .horizontal
        rightButtons.spacing = Brand.Metric.space8

        let buttonRow = NSStackView(views: [leftButtons, NSView(), rightButtons])
        buttonRow.orientation = .horizontal

        let root = NSStackView(views: [form, statusLabel, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Brand.Metric.space12
        root.edgeInsets = NSEdgeInsets(top: Brand.Metric.space16,
                                       left: Brand.Metric.space16,
                                       bottom: Brand.Metric.space16,
                                       right: Brand.Metric.space16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor,
                                             constant: -Brand.Metric.space32),
            form.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: -Brand.Metric.space32),
        ])
        window.contentView = content
        self.window = window
        loadExistingOverride()
    }

    private func labelCell(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Brand.Font.metadata
        field.textColor = Brand.Color.textSecondary
        return field
    }

    func show() {
        AppMainMenu.install()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(userField)
    }

    @objc private func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        AppMainMenu.release()
    }

    // MARK: - State

    private var selectedScope: FleetStore.OverrideScope {
        scopes[max(0, min(scopePopup.indexOfSelectedItem, scopes.count - 1))]
    }

    /// Shows what is already saved at the chosen scope, so reopening the editor
    /// reflects reality rather than starting blank.
    private func loadExistingOverride() {
        let existing = store.existingOverride(scope: selectedScope)
        userField.stringValue = existing?.user ?? ""
        keyField.stringValue = existing?.identityFile ?? ""
        removeButton.isEnabled = existing != nil
        statusLabel.stringValue = existing == nil
            ? "ssh currently uses \(effective.user ?? NSUserName())"
            : "Override saved for \(selectedScope.label.lowercased())"
    }

    @objc private func scopeChanged() { loadExistingOverride() }

    private func setBusy(_ value: Bool, message: String? = nil) {
        busy = value
        for button in [detectButton, testButton, saveButton, removeButton] {
            button?.isEnabled = !value
        }
        if value { removeButton.isEnabled = false }
        else { removeButton.isEnabled = store.existingOverride(scope: selectedScope) != nil }
        if let message { statusLabel.stringValue = message }
    }

    private var targetHost: String { instance.host ?? instance.privateIP ?? instance.id }

    // MARK: - Actions

    @objc private func chooseKey() {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = true
        dialog.canChooseDirectories = false
        dialog.allowsMultipleSelection = false
        dialog.showsHiddenFiles = true
        dialog.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        dialog.prompt = "Use Key"
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        let path = url.path
        let home = NSHomeDirectory()
        keyField.stringValue = path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count) : path
    }

    @objc private func test() {
        let user = userField.stringValue.isEmpty ? effective.user : userField.stringValue
        let key = keyField.stringValue.isEmpty ? nil : keyField.stringValue
        let host = targetHost
        setBusy(true, message: "Testing \(user ?? NSUserName())@\(host)\u{2026}")
        Task {
            let result = await Task.detached {
                FleetStore.testConnection(host: host, user: user, identityFile: key)
            }.value
            await MainActor.run {
                self.setBusy(false)
                self.statusLabel.stringValue = result.detail
                self.statusLabel.textColor = result.ok
                    ? Brand.Color.stateRunning : Brand.Color.stateTerminated
            }
        }
    }

    /// Tries the usual cloud-image logins in parallel and keeps the first that
    /// authenticates, which is faster and less annoying than guessing by hand.
    @objc private func detect() {
        let key = keyField.stringValue.isEmpty ? nil : keyField.stringValue
        let host = targetHost
        let candidates = SSHLogin.candidates(effective: effective.user)
        setBusy(true, message: "Trying \(candidates.count) logins\u{2026}")
        Task {
            let found = await FleetStore.detectLogin(host: host, identityFile: key,
                                                    candidates: candidates)
            await MainActor.run {
                self.setBusy(false)
                if let found {
                    self.userField.stringValue = found
                    self.statusLabel.stringValue =
                        "\(found) authenticated. Save to keep it."
                    self.statusLabel.textColor = Brand.Color.stateRunning
                } else {
                    self.statusLabel.stringValue =
                        "No login authenticated. Check the identity file or the host."
                    self.statusLabel.textColor = Brand.Color.stateTerminated
                }
            }
        }
    }

    @objc private func save() {
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        let message = store.saveOverride(scope: selectedScope,
                                         user: user.isEmpty ? nil : user,
                                         identityFile: key.isEmpty ? nil : key)
        onSaved(message)
        close()
    }

    @objc private func removeOverride() {
        let message = store.saveOverride(scope: selectedScope, user: nil, identityFile: nil)
        onSaved(message)
        close()
    }
}
