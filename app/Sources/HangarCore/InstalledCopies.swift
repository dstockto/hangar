import Foundation

/// Which copies of the app an uninstall has to remove.
///
/// Dragging a DMG to Applications while another copy sits in ~/Applications is
/// an ordinary state to be in, and the first uninstall shipped removed only the
/// bundle it was running from. The user then found Hangar still in Applications,
/// still opening at login, and rebuilding ~/.hangar the moment it launched.
public enum InstalledCopies {
    /// Where a copy of an app is an *installed* copy. Anything found outside
    /// these, such as a build sitting in a source tree, is reported rather than
    /// removed: Launch Services lists it, and trashing someone's build output
    /// because they once launched it is not what uninstall means.
    public static func defaultInstallRoots(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "\(home)/Applications"]
    }

    /// The bundles to move to the Trash, running copy first.
    ///
    /// The running copy always counts, wherever it lives: the user uninstalled
    /// from it. Other copies count when they sit under an install root.
    /// `isRemovable` is the physical question on top of that, so a copy on the
    /// read-only volume of a mounted DMG is reported rather than attempted.
    public static func toRemove(running: String, found: [String],
                                installRoots: [String] = defaultInstallRoots(),
                                isRemovable: (String) -> Bool) -> [String] {
        classify(running: running, found: found, installRoots: installRoots,
                 isRemovable: isRemovable).remove
    }

    /// Copies that were found and are being left alone, so the dialog can say so
    /// rather than quietly leaving one behind, which is the whole bug.
    public static func leftInPlace(running: String, found: [String],
                                   installRoots: [String] = defaultInstallRoots(),
                                   isRemovable: (String) -> Bool) -> [String] {
        classify(running: running, found: found, installRoots: installRoots,
                 isRemovable: isRemovable).keep
    }

    static func classify(running: String, found: [String], installRoots: [String],
                         isRemovable: (String) -> Bool)
        -> (remove: [String], keep: [String]) {
        var seen = Set<String>()
        var remove: [String] = []
        var keep: [String] = []
        for (index, path) in ([running] + found).enumerated() {
            let standard = (path as NSString).standardizingPath
            guard !standard.isEmpty else { continue }
            guard seen.insert(standard.lowercased()).inserted else { continue }
            let isRunning = index == 0
            let installed = isRunning || installRoots.contains { root in
                standard.hasPrefix((root as NSString).standardizingPath + "/")
            }
            if installed && isRemovable(standard) {
                remove.append(standard)
            } else {
                keep.append(standard)
            }
        }
        return (remove, keep)
    }

    /// The list as a sentence for the confirmation dialog. Home is abbreviated
    /// because "/Users/someone/Applications" in a dialog is noise.
    public static func describe(_ paths: [String],
                               home: String = NSHomeDirectory()) -> String {
        paths.map { path in
            path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }.joined(separator: "\n")
    }
}
