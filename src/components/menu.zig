//! Pop-up menus: a button (or arbitrary trigger) that toggles a popover of item
//! views. Built from a `.popover` over an app-owned `State(bool)` — no dedicated
//! overlay style or hit action.

const view = @import("../view/view.zig");
const state = @import("../state/state.zig");

const View = view.View;

fn toggleBoolState(s: *state.State(bool)) void {
    s.set(!s.get());
}

/// A button that toggles a popover menu of `items` (a tuple or `[]const View`).
/// `open` is app-owned `State(bool)` tracking whether the menu is shown; tapping
/// the button toggles it, tapping the scrim dismisses it.
pub fn Menu(label: []const u8, open: *state.State(bool), items: anytype) View {
    const content = view.VStack(items).padding(6);
    return view.Button(label, view.actionCtx(state.State(bool), open, toggleBoolState))
        .popover(open.binding(), content);
}

/// Attach a popover menu of `items` to an arbitrary `trigger` view: tapping the
/// trigger toggles the menu. The right-click/long-press analogue of `Menu`.
pub fn ContextMenu(trigger: View, open: *state.State(bool), items: anytype) View {
    const content = view.VStack(items).padding(6);
    return trigger
        .onTap(view.actionCtx(state.State(bool), open, toggleBoolState))
        .popover(open.binding(), content);
}
