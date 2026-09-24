#if DEBUG
import AppKit

/// DEBUG-only: `GLIMPSE_DEBUG_SCENARIO=1 GLIMPSE_DEBUG_IMAGE=… GLIMPSE_SNAPSHOT_DIR=…` opens every UI surface
/// with a sample image, renders each window to PNG (no Screen Recording permission needed) and quits.
@MainActor
enum DebugScenario {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["GLIMPSE_DEBUG_SCENARIO"] != nil, let dir = env["GLIMPSE_SNAPSHOT_DIR"],
              let path = env["GLIMPSE_DEBUG_IMAGE"], let (image, scale) = ImageUtil.load(url: URL(fileURLWithPath: path)) else { return }
        let out = URL(fileURLWithPath: dir)
        Task { @MainActor in
            let capture = Capture(image: image, scale: scale)
            if let screen = NSScreen.main {
                // Selection overlay: fake a frozen screen by stretching the sample image.
                let frozen = ImageUtil.resized(image, toPixelWidth: Int(screen.frame.width * screen.backingScaleFactor),
                                               height: Int(screen.frame.height * screen.backingScaleFactor))
                let w1 = SelectionController.debugWindow(screen: screen, frozen: frozen, mode: .area)
                w1.selectionView.debugSet(mouse: CGPoint(x: 300, y: 250), selection: nil)
                snapshot(w1, to: out.appendingPathComponent("select-idle.png"))
                w1.selectionView.debugSet(mouse: CGPoint(x: screen.frame.width - 60, y: screen.frame.height - 60),
                                          selection: CGRect(x: 200, y: 150, width: screen.frame.width - 260, height: screen.frame.height - 210))
                snapshot(w1, to: out.appendingPathComponent("select-drag.png"))
            }
            QuickAccessManager.shared.show(capture)
            QuickAccessManager.shared.show(Capture(image: image, scale: scale))
            try? await Task.sleep(nanoseconds: 800_000_000)
            for (i, w) in NSApp.windows.enumerated() where w is QuickAccessPanel {
                snapshot(w, to: out.appendingPathComponent("overlay-\(i).png"))
                if let v = w.contentView { v.mouseEntered(with: NSEvent()) }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            for (i, w) in NSApp.windows.enumerated() where w is QuickAccessPanel {
                snapshot(w, to: out.appendingPathComponent("overlay-hover-\(i).png"))
            }

            EditorWindowController.open(capture: capture)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let editor = EditorWindowController.openEditors.first {
                let m = editor.model
                let s = m.imageSize
                m.add(Annotation(kind: .arrow, start: CGPoint(x: s.width * 0.6, y: s.height * 0.7),
                                 end: CGPoint(x: s.width * 0.35, y: s.height * 0.35), color: .defaultRed, lineWidth: 6))
                var t = Annotation(kind: .text, start: CGPoint(x: s.width * 0.5, y: s.height * 0.75), end: .zero,
                                   color: .defaultRed, lineWidth: 4)
                t.text = "Look here"
                t.fontSize = 32
                m.add(t)
                let rect = Annotation(kind: .rectangle, start: CGPoint(x: s.width * 0.1, y: s.height * 0.1),
                                      end: CGPoint(x: s.width * 0.3, y: s.height * 0.3), color: RGBA.presets[4], lineWidth: 4)
                m.add(rect)
                m.add(Annotation(kind: .counter, start: CGPoint(x: s.width * 0.1, y: s.height * 0.1), end: .zero,
                                 color: RGBA.presets[4], lineWidth: 4))
                m.tool = .select
                m.selectedID = rect.id
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let w = editor.window { snapshot(w, to: out.appendingPathComponent("editor.png")) }
                m.tool = .text
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let w = editor.window { snapshot(w, to: out.appendingPathComponent("editor-text.png")) }
                m.tool = .crop
                m.cropDraft = CGRect(x: s.width * 0.05, y: s.height * 0.05, width: s.width * 0.6, height: s.height * 0.6)
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let w = editor.window { snapshot(w, to: out.appendingPathComponent("editor-crop.png")) }
                m.applyCrop()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let w = editor.window { snapshot(w, to: out.appendingPathComponent("editor-cropped.png")) }
                editor.window?.performClose(nil)
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            for (i, w) in NSApp.windows.enumerated() where w is QuickAccessPanel && w.isVisible {
                snapshot(w, to: out.appendingPathComponent("overlay-after-edit-\(i).png"))
            }

            PinWindowController.pin(capture: capture)
            try? await Task.sleep(nanoseconds: 500_000_000)
            for (i, w) in NSApp.windows.enumerated() where w is PinPanel && w.isVisible {
                snapshot(w, to: out.appendingPathComponent("pin-\(i).png"))
            }

            PermissionsWindowController.show()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let w = PermissionsWindowController.shared?.window { snapshot(w, to: out.appendingPathComponent("permissions.png")) }
            PermissionsWindowController.shared?.window?.close()

            SettingsWindowController.show()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let w = SettingsWindowController.shared?.window { snapshot(w, to: out.appendingPathComponent("settings.png")) }
            NSLog("Glimpse debug scenario finished")
            NSApp.terminate(nil)
        }
    }

    static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: ImageUtil.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if let layer = view.layer, window.isVisible {
            layer.render(in: ctx)
        } else if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let cg = rep.cgImage { ctx.draw(cg, in: view.bounds) }
        }
        if let img = ctx.makeImage() {
            try? ImageExporter.write(img, scale: scale, to: url)
        }
    }
}
#endif
