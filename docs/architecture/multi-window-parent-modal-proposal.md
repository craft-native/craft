# Parent and modal windows: approved contract

**Status: implemented on macOS, Linux, and Windows; platform smokes in CI.**
`WindowCreateOptions` exposes `parent` and `modal`, and each native creation
path now applies them. The installed-app tests and the remaining acceptance
checks below still determine whether issue #67 can be closed. Native parenting
is distinct from the existing creator-page ownership contract.

## Contract

1. `parent` names a live window controlled by the requesting page. `main`
   means that page's own native window, not the process's first window. A
   named parent must be a handle owned by the requesting page. Unknown,
   destroyed, unrelated, or self-referential parents fail before a child is
   created. Reject cycles rather than allowing a window to become its own
   ancestor. A window opened without `parent` remains independent of its
   creator, as the existing orphan-adoption tests require.
2. A parented non-modal window remains above and follows its parent. Closing
   the parent closes its attached descendants. On macOS, ordinary close may
   retain those pages for same-name reopen; permanent destroy releases the
   whole attached subtree. Linux and Windows close destroys their native
   windows and attached descendants. Do not transfer a parented descendant's
   handle to another page after its parent is destroyed.
3. `modal: true` requires `parent`. It blocks interaction with that parent
   while visible, but not with unrelated application windows. Dismissing or
   destroying the modal window restores the parent's interaction; closing the
   parent closes the modal window first. The modal relationship does not turn
   creator-page events into a process-wide broadcast.
4. Parent and modal relationships are fixed at first creation. Reopening an
   existing name with incompatible relationship options rejects rather than
   silently reparenting a live window. `alwaysOnTop` on a modal child is
   rejected so it cannot override parent-scoped modality.

The native APIs do not make this one portable call. AppKit has
[attached child windows](https://developer.apple.com/documentation/appkit/nswindow/addchildwindow%28_%3Aordered%3A%29)
and [parent-scoped sheets](https://developer.apple.com/documentation/appkit/nswindow/sheetparent).
GTK has [transient windows](https://docs.gtk.org/gtk3/method.Window.set_transient_for.html)
and optional [destroy-with-parent](https://docs.gtk.org/gtk3/method.Window.set_destroy_with_parent.html),
but [`gtk_window_set_modal()`](https://docs.gtk.org/gtk3/method.Window.set_modal.html)
blocks *every* window in the application. Win32
[owned windows](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)
stay above and are destroyed with their owner, while a
[modal dialog](https://learn.microsoft.com/en-us/windows/win32/dlgbox/about-dialog-boxes)
disables its owner. Craft must enforce the same visible contract above rather
than equating these APIs by name.

## Implementation and acceptance plan

- Keep native parent identity separate from the existing creator-webview
  event owner. Authenticate a requested parent against the sender before
  creating or showing anything, and retain a parent/child graph that can
  reject cycles and release descendants exactly once.
- Connect the platform-native parent relationship and parent-scoped modal
  blocking. On every close, destroy, reopen, and failed creation path, unwind
  modal blocking and native attachments without a stale handle or disabled
  parent.
- Extend macOS, Linux and Windows GUI smokes and installed PKG/DEB/MSI smokes.
  Each must prove focus/z-order, parent-only blocking, sibling interactivity,
  close propagation, destroy cleanup, same-name reopening, unrelated-parent
  rejection, and the existing unparented orphan-adoption behavior.
  The Windows GUI smoke also enumerates its native process windows and reads
  Win32 enabled state during modal show, hide, reopen and close to distinguish
  parent-only blocking from mere visibility checks. It also checks native owner
  handles for the modal and its non-modal sibling, and verifies that sibling
  remains enabled while their common parent is blocked.
  The Linux GUI and installed-DEB smokes run under Openbox rather than a bare
  Xvfb server, and require an unrelated window, a non-modal sibling, and the
  modal itself to take focus in turn while the modal remains visible. The GUI
  smoke also reads each child window's `WM_TRANSIENT_FOR` owner and Openbox's
  bottom-to-top `_NET_CLIENT_LIST_STACKING` to verify both children remain
  above their parent.

The parent-scoped modality choice was approved on October 1, 2026. The native
paths implement it; cross-platform installed-app CI and the acceptance checks
above remain the release gate.
