// RefGallery — a native SwiftUI gallery mirroring examples/showcase's Controls
// page, used to capture macOS 26 Liquid Glass reference screenshots for theme
// parity work. Not part of the library build.
//
//   xcrun swiftc -O RefGallery.swift -o refgallery
//   ./refgallery --out /tmp/ref-light.png [--dark] [--sheet|--alert|--popover]
//
// The app opens a 900x640 window, waits for the first frame, captures its own
// window (CGWindowListCreateImage on one's own windows needs no screen-recording
// permission), writes a PNG, and exits.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ── The gallery ──────────────────────────────────────────────────────────────

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
    }
}

struct ControlsPage: View {
    @State private var wifi = true
    @State private var notifications = false
    @State private var slider = 0.5
    @State private var quantity = 2
    @State private var size = 1
    @State private var range = 0
    @State private var radio = 0
    @State private var name = ""

    var body: some View {
        Form {
            Section("Buttons") {
                HStack(spacing: 10) {
                    Button("Primary") {}.buttonStyle(.glassProminent)
                    Button("Glass") {}.buttonStyle(.glass)
                    Button("Delete") {}.buttonStyle(.glassProminent).tint(.red)
                    Button("Plain") {}.buttonStyle(.borderless)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button("Disabled") {}.buttonStyle(.glass).disabled(true)
                    Button {} label: { Image(systemName: "heart") }.buttonStyle(.glass)
                    Button {} label: { Image(systemName: "trash") }.buttonStyle(.glass)
                    Spacer()
                }
            }
            Section("Toggles") {
                LabeledRow(label: "Wi‑Fi") { Toggle("", isOn: $wifi).toggleStyle(.switch).labelsHidden() }
                LabeledRow(label: "Notifications") { Toggle("", isOn: $notifications).toggleStyle(.switch).labelsHidden() }
            }
            Section("Slider & Progress") {
                Slider(value: $slider)
                ProgressView(value: 0.45)
            }
            Section("Stepper & Pickers") {
                LabeledRow(label: "Quantity") { Stepper("", value: $quantity).labelsHidden() }
                LabeledRow(label: "Size") {
                    Picker("", selection: $size) {
                        Text("Small").tag(0); Text("Medium").tag(1); Text("Large").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                LabeledRow(label: "Range") {
                    Picker("", selection: $range) {
                        Text("Day").tag(0); Text("Week").tag(1); Text("Month").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            Section("Radio group") {
                Picker("", selection: $radio) {
                    Text("Automatic").tag(0); Text("On").tag(1); Text("Off").tag(2)
                }.pickerStyle(.radioGroup).labelsHidden()
            }
            Section("Text field") {
                TextField("Your name", text: $name)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Controls")
    }
}

struct SidebarLabel: Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String
}

let sidebarItems: [SidebarLabel] = [
    .init(id: 0, name: "Controls", icon: "gearshape"),
    .init(id: 1, name: "Text & Icons", icon: "textformat"),
    .init(id: 2, name: "Shapes & Media", icon: "square.on.circle"),
    .init(id: 3, name: "Layout", icon: "rectangle.3.group"),
    .init(id: 4, name: "Table", icon: "tablecells"),
    .init(id: 5, name: "Editor", icon: "pencil"),
    .init(id: 6, name: "Overlays", icon: "square.stack"),
    .init(id: 7, name: "Effects", icon: "sparkles"),
    .init(id: 8, name: "Navigation", icon: "paperplane"),
]

struct RootView: View {
    let showSheet: Bool
    let showAlert: Bool
    let showPopover: Bool
    @State private var selection: Int? = 0
    @State private var sheetUp = false
    @State private var alertUp = false
    @State private var popoverUp = false

    var body: some View {
        NavigationSplitView {
            List(sidebarItems, selection: $selection) { item in
                Label(item.name, systemImage: item.icon)
            }
            .navigationSplitViewColumnWidth(220)
        } detail: {
            ControlsPage()
        }
        .frame(width: 900, height: 640)
        .sheet(isPresented: $sheetUp) {
            VStack(spacing: 12) {
                Text("Sheet").font(.title2.weight(.semibold))
                Text("A bottom sheet drawn over a dimming scrim.\nTap outside or Done to dismiss.")
                    .multilineTextAlignment(.center)
                Button("Done") { sheetUp = false }.buttonStyle(.glassProminent)
            }
            .padding(28)
            .frame(width: 420)
        }
        .alert("Heads up", isPresented: $alertUp) {
            Button("OK") {}
        } message: {
            Text("A centered alert. Long unbreakable tokens wrap too.")
        }
        .overlay(alignment: .topLeading) {
            if showPopover {
                Button("Toggle popover") { popoverUp = true }
                    .buttonStyle(.glass)
                    .padding(.leading, 260)
                    .padding(.top, 300)
                    .popover(isPresented: $popoverUp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Popover").font(.headline)
                            Text("Anchored near its trigger; tap outside to dismiss.")
                        }
                        .padding(14)
                        .frame(width: 220)
                    }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if showSheet { sheetUp = true }
                if showAlert { alertUp = true }
                if showPopover { popoverUp = true }
            }
        }
    }
}

// ── Window + self-capture ────────────────────────────────────────────────────

func writePNG(_ img: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var outPath = "/tmp/ref.png"

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outPath = args[i + 1] }
        let dark = args.contains("--dark")
        let root = RootView(
            showSheet: args.contains("--sheet"),
            showAlert: args.contains("--alert"),
            showPopover: args.contains("--popover")
        )

        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = true
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Give SwiftUI a beat to settle (and overlays to present), then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.capture() }
    }

    func capture() {
        if CommandLine.arguments.contains("--hold") {
            // External capture mode: a driver script runs
            //   screencapture -o -x -l <windowNumber> out.png
            // (window-server pixels, including backdrop effects), then kills us.
            print("WINDOWID \(window.windowNumber)")
            fflush(stdout)
            return
        }
        // In-process render. CABackdropLayer-based effects (the glass frost)
        // may not composite here — the driver compares this against an external
        // screencapture to decide which to trust.
        let v = window.contentView!
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: outPath))
                print("captured (cacheDisplay) -> \(outPath)")
                exit(0)
            }
        }
        print("capture FAILED")
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, "delegateHolder", delegate, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
