# Zoom Into Cursor

Enlarge text or anything else on your screen by pointing your mouse cursor anywhere on screen. Multiple size options. Let the lens follow your cursor, or lock it in place so it stays put while you work underneath it.

Zoom Into Cursor lives in your menu bar — there's no dock icon, no window to manage, and no account to sign in to. It's a free, open-source macOS utility.

## Features

- A floating magnifier window that follows your mouse cursor anywhere on screen, including over other apps and full-screen windows
- Five lens sizes, from a compact 800x400 window up to a huge 4800x1000 "Full 5K Width" strip
- Lock/unlock the lens in place so it stops following the cursor and stays where you put it
- Global keyboard shortcuts that work system-wide, even when another app is focused
- Menu bar only — no dock icon, no clutter

## Installation

1. Download the project (click **Code → Download ZIP** on GitHub, or `git clone` the repo).
2. Unzip it if needed, then open the folder.
3. Drag `LensApp.app` to your **Applications** folder (optional, but recommended).
4. Because this app is free and open-source, it isn't signed with a paid Apple Developer certificate. The first time you open it, macOS Gatekeeper will block it with a message like *"Apple could not verify ... is free of malware"*. To open it anyway:
   - **Right-click (or Control-click) `LensApp.app` → Open → Open**, or
   - Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the LensApp warning, or
   - Run this once in Terminal: `xattr -cr /Applications/LensApp.app` and then double-click it normally.

   You only need to do this once. After the first approved launch, it opens normally going forward.

5. The first time it runs, macOS will ask for **Screen Recording** permission (this is required for the magnifier to capture what's under your cursor). Approve it in the prompt, or enable it manually in **System Settings → Privacy & Security → Screen Recording**, then relaunch the app.

### Building from source instead

If you'd rather build it yourself:

```
swift build -c release
```

The resulting binary at `.build/release/LensApp` can be dropped into `LensApp.app/Contents/MacOS/LensApp` in place of the prebuilt one. You can also open the folder in Xcode (it's a Swift Package) and run it directly from there.

## Using Zoom Into Cursor

Once running, you'll see a 🔍 icon in your menu bar — that's your control center.

- **Move your mouse** anywhere on screen and the lens follows it, showing a magnified view of whatever is underneath.
- Click the menu bar icon to open the menu:
  - **Lens Dimensions** — choose from five sizes: Standard, Large, Huge, Ultra-Wide, or Full 5K Width.
  - **Cycle Size** — step through the five sizes in order.
  - **Lock/Unlock Position** — freeze the lens in its current spot (it stops following the cursor and becomes semi-transparent so you can still see what's behind it), or unlock it to resume following your cursor.
  - **Quit Zoom Into Cursor** — closes the app.

### Keyboard shortcuts

These work system-wide, even while another app is in focus:

| Shortcut | Action |
|---|---|
| `Option + L` | Cycle through lens sizes |
| `Option + S` | Lock / unlock the lens position |

## Troubleshooting

- **"Apple could not verify this app is free of malware"** — expected for an unsigned open-source app. See step 4 under Installation.
- **The lens shows a black or empty rectangle** — Screen Recording permission hasn't been granted yet. Open **System Settings → Privacy & Security → Screen Recording**, enable it for LensApp, then quit and reopen the app.
- **Nothing happens when I press the shortcuts** — another app may already be using `Option+L` or `Option+S`. Quit that app, or try the menu bar items instead.
- **I don't see the menu bar icon** — your menu bar may be too full. Try removing other menu bar icons, or widen your display's visible menu bar area.

## Requirements

- macOS 13 (Ventura) or later
- Works on both Apple Silicon and Intel Macs

## License

MIT — see [LICENSE](LICENSE). Free to use, modify, and share.
