import AppKit
import BurrowKit

/// The app's own windows and menu bar, read through the accessibility tree from
/// inside the app, so no Accessibility permission is needed and every button a
/// person can press is there.
///
/// SwiftUI only builds its elements when asked through the attribute API that
/// assistive apps use (`accessibilityAttributeValue`), and many of them do not
/// adopt the newer NSAccessibility protocol, so everything goes through that API.
@MainActor
public final class AccessibilitySurface: ControlSurface {
    public init() {}

    private let maxDepth = 40

    public func snapshot() -> [ControlNode] {
        for flag in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: flag))
        }
        // The approval dialog is left out, so an agent cannot approve itself.
        var roots = NSApp.windows
            .filter { $0.isVisible && $0.identifier != approvalWindow }
            .map { node(for: $0, depth: 0) }
        if let menu = NSApp.mainMenu { roots.append(menuNode(menu, title: "Menubalk")) }
        return roots
    }

    public func press(_ node: ControlNode) throws {
        if let item = node.handle as? NSMenuItem, let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            return
        }
        // One route only: some buttons report failure after pressing, and a
        // fallback would press them twice.
        if let element = node.handle as? NSAccessibilityProtocol {
            _ = element.accessibilityPerformPress()
        } else if let element = node.handle as? NSObject, element.responds(to: Selector(("accessibilityPerformPress"))) {
            // Returns a BOOL, which perform() cannot read; the result is ignored.
            _ = element.perform(Selector(("accessibilityPerformPress")))
        } else if let element = node.handle as? NSObject, element.accessibilityActionNames().contains(.press) {
            element.accessibilityPerformAction(.press)
        } else {
            throw ControlError("this element cannot be pressed")
        }
    }

    public func type(_ node: ControlNode, _ text: String) throws {
        guard let element = node.handle as? NSObject else { throw ControlError("not a text field") }
        // Typing through the field editor runs the normal editing path, so the
        // SwiftUI binding sees the change; setting the value would bypass it.
        if let modern = element as? NSAccessibilityProtocol {
            modern.setAccessibilityFocused(true)
        } else {
            element.accessibilitySetValue(true, forAttribute: .focused)
        }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else if element.accessibilityIsAttributeSettable(.value) {
            element.accessibilitySetValue(text, forAttribute: .value)
        } else {
            throw ControlError("this element does not take text")
        }
    }

    public func select(_ node: ControlNode) throws {
        // SwiftUI lists ignore an accessibility selection; selecting the row in
        // the table reaches the list's selection binding.
        if let row = node.handle as? TableRow {
            let table = row.table
            let allowed = if let outline = table as? NSOutlineView, let item = outline.item(atRow: row.index) {
                outline.delegate?.outlineView?(outline, shouldSelectItem: item) ?? true
            } else {
                table.delegate?.tableView?(table, shouldSelectRow: row.index) ?? true
            }
            guard allowed else { throw ControlError("this row cannot be selected, it is probably a heading") }
            table.selectRowIndexes(IndexSet(integer: row.index), byExtendingSelection: false)
            table.scrollRowToVisible(row.index)
            return
        }
        if let element = node.handle as? NSAccessibilityProtocol {
            element.setAccessibilitySelected(true)
            return
        }
        guard let element = node.handle as? NSObject, element.accessibilityIsAttributeSettable(.selected) else {
            throw ControlError("cannot select this element")
        }
        element.accessibilitySetValue(true, forAttribute: .selected)
    }

    private func node(for object: Any, depth: Int) -> ControlNode {
        guard let element = object as? NSObject else { return ControlNode(role: "AXUnknown") }
        let modern = element as? NSAccessibilityProtocol
        func string(_ attribute: NSAccessibility.Attribute) -> String? {
            let selector: String? = switch attribute {
            case .role: "accessibilityRole"
            case .subrole: "accessibilitySubrole"
            case .identifier: "accessibilityIdentifier"
            case .description: "accessibilityLabel"
            case .title: "accessibilityTitle"
            case .help: "accessibilityHelp"
            case .value: "accessibilityValue"
            default: nil
            }
            for candidate in [selector.flatMap(Self.object(element)), element.accessibilityAttributeValue(attribute)] {
                switch candidate {
                case let string as String where !string.isEmpty: return string
                case let attributed as NSAttributedString where !attributed.string.isEmpty: return attributed.string
                case let number as NSNumber: return number.stringValue
                default: continue
                }
            }
            return nil
        }
        let role = string(.role) ?? "AXUnknown"
        var children: [ControlNode] = []
        // Mail bodies render in a web view whose tree is huge; `state` has the text.
        if depth < maxDepth, role != "AXWebArea" {
            let kids = (Self.object(element)("accessibilityChildren") as? [Any]).flatMap { $0.isEmpty ? nil : $0 }
                ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
            children = kids.map { node(for: $0, depth: depth + 1) }
            if let table = element as? NSTableView {
                var index = 0
                for i in children.indices where children[i].role == "AXRow" {
                    children[i].handle = TableRow(table: table, index: index)
                    index += 1
                }
            }
        }
        return ControlNode(
            role: role,
            subrole: string(.subrole),
            identifier: string(.identifier),
            label: string(.description) ?? string(.title) ?? string(.help),
            value: string(.value),
            enabled: modern?.isAccessibilityEnabled() ?? (element.accessibilityAttributeValue(.enabled) as? Bool) ?? true,
            children: children,
            handle: element
        )
    }

    /// Calls an object-returning accessibility getter by name. SwiftUI's own
    /// nodes implement them without declaring the protocol in Swift.
    private static func object(_ element: NSObject) -> (String) -> Any? {
        { name in
            let selector = Selector(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
    }

    private func menuNode(_ menu: NSMenu, title: String) -> ControlNode {
        ControlNode(role: "AXMenu", label: title, children: menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
            ControlNode(
                role: "AXMenuItem",
                label: item.title,
                enabled: item.isEnabled,
                children: item.submenu.map { [menuNode($0, title: item.title)] } ?? [],
                handle: item
            )
        })
    }
}

/// A row of a SwiftUI list, which only its table can select.
private final class TableRow {
    let table: NSTableView
    let index: Int
    init(table: NSTableView, index: Int) {
        self.table = table
        self.index = index
    }
}

private let approvalWindow = NSUserInterfaceItemIdentifier("burrow.approval")

/// Asks the person before an agent sends, deletes, logs out or records; the
/// safe answer is the default.
@MainActor
public func approveControlAction(_ action: String) async -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.window.identifier = approvalWindow
    alert.messageText = "Een agent wil op ‘\(action)’ drukken"
    alert.informativeText = [NSApp.keyWindow?.title, "Versturen, verwijderen, uitloggen en opnemen doet een agent alleen met jouw goedkeuring."]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Weiger")
    alert.addButton(withTitle: "Sta toe")
    return alert.runModal() == .alertSecondButtonReturn
}
