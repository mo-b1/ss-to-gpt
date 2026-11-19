# Screenshot to ChatGPT for macOS

A native macOS menu-bar helper for the ChatGPT desktop app. Press a global shortcut, select part of the screen, and it pastes the screenshot into either a new conversation or the conversation already open.

## Build

Requires macOS 13+, Xcode Command Line Tools, and the ChatGPT macOS app.

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open "dist/Screenshot to ChatGPT.app"
```

On first use, allow the helper in **System Settings → Privacy & Security → Accessibility**. macOS may also request **Screen Recording** permission.

## Use

1. Click the viewfinder in the menu bar and open **Settings**.
2. Choose **A new chat** or **The chat currently open**.
3. Press **Command + Shift + 8** (or select another shortcut).
4. Drag to select an area. Press Escape to cancel.

## Context menu

After launching the app once, right-click selected text, an image, or a file and choose **Services → Send to ChatGPT**. The selection uses the same new-chat/current-chat and auto-send settings as screenshots.

If the item is hidden, enable **Send to ChatGPT** in **System Settings → Keyboard → Keyboard Shortcuts → Services**. Some apps show enabled services directly in the context menu instead of inside a Services submenu.

For the existing-chat option, open the desired conversation in ChatGPT first. The native ChatGPT app does not expose a public API for selecting a conversation by ID.

Screenshots are not uploaded by this helper. It passes the image through the macOS clipboard to ChatGPT.
