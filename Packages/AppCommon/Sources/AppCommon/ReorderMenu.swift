import SwiftUI

/// Moving rows of an ordered list on the Mac: a drag there can't start on a row
/// that's a button or a switch, so each row gets a handle beside it to drag by, and Move
/// Up/Down/to Top/to Bottom in its context menu. iOS keeps drag in Edit mode. `move` is the
/// list's `onMove` handler.
public enum ReorderMenu {
    public static var hint: String {
        #if os(macOS)
        "Drag a row by its handle, or right-click it to move it."
        #else
        "Tap Edit, then drag to reorder."
        #endif
    }
}

extension View {
    public func reorderMenu(index: Int, count: Int, move: @escaping (IndexSet, Int) -> Void) -> some View {
        #if os(macOS)
        HStack(spacing: 10) {
            // Plain content outside the row's control, so the list's drag can start here.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 24)
                .contentShape(.rect)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            self
        }
        .contextMenu {
            Button("Move to Top", systemImage: "arrow.up.to.line") { move([index], 0) }
                .disabled(index == 0)
            Button("Move Up", systemImage: "arrow.up") { move([index], index - 1) }
                .disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") { move([index], index + 2) }
                .disabled(index >= count - 1)
            Button("Move to Bottom", systemImage: "arrow.down.to.line") { move([index], count) }
                .disabled(index >= count - 1)
        }
        #else
        self
        #endif
    }
}
