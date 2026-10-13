import SwiftUI
import AppKit
import Carbon
import ServiceManagement

struct Setting: Equatable {
    var warmth, brightness, contrast: Double   // contrast: -1 = softest, 0 = normal, +1 = sharpest

    func matches(_ o: Setting) -> Bool {
        abs(warmth - o.warmth) < 0.01 && abs(brightness - o.brightness) < 0.01 && abs(contrast - o.contrast) < 0.01
    }
}

let slotNames = ["Favorite", "#2", "#3", "#4"]
let slotIcons = ["star.fill", "2.circle", "3.circle", "4.circle"]

final class Filter: ObservableObject {
    static let shared = Filter()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { changed() } }
    @Published var warmth: Double { didSet { changed() } }
    @Published var brightness: Double { didSet { changed() } }
    @Published var contrast: Double { didSet { changed() } }
    @Published var builtInOnly: Bool { didSet { changed() } }
    @Published var slots: [Setting]
    @Published var selected: Int { didSet { d.set(selected, forKey: "selected") } }
    @Published var atLogin = SMAppService.mainApp.status == .enabled {
        didSet { try? atLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    init() {
        // First launch starts on the Favorite setting.
        d.register(defaults: ["enabled": false, "warmth": 0.036, "brightness": 0.848,
                              "contrast": -0.311, "builtInOnly": false])
        enabled = d.bool(forKey: "enabled")
        warmth = d.double(forKey: "warmth")
        brightness = d.double(forKey: "brightness")
        contrast = d.double(forKey: "contrast")
        builtInOnly = d.bool(forKey: "builtInOnly")
        // Each slot starts as the Favorite (saved from the old single-favorite version if present,
        // else the default Favorite: soft contrast, barely warm, slightly dimmed).
        let fav = d.array(forKey: "favorite") as? [Double] ?? [0.036, 0.848, -0.311]
        let saved = d.array(forKey: "slots") as? [[Double]] ?? Array(repeating: fav, count: 4)
        slots = saved.map { Setting(warmth: $0[0], brightness: $0[1], contrast: $0[2]) }
        selected = d.integer(forKey: "selected")
    }

    var current: Setting { Setting(warmth: warmth, brightness: brightness, contrast: contrast) }

    var unsaved: Bool { !current.matches(slots[selected]) }

    func select(_ i: Int) {
        selected = i
        let p = slots[i]
        warmth = p.warmth; brightness = p.brightness; contrast = p.contrast
        if !enabled { enabled = true }
    }

    func save() {
        slots[selected] = current
        d.set(slots.map { [$0.warmth, $0.brightness, $0.contrast] }, forKey: "slots")
    }

    private func changed() {
        d.set(enabled, forKey: "enabled"); d.set(warmth, forKey: "warmth")
        d.set(brightness, forKey: "brightness"); d.set(contrast, forKey: "contrast")
        d.set(builtInOnly, forKey: "builtInOnly")
        CGDisplayRestoreColorSyncSettings()
        apply()
    }

    private func displays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }

    /// Re-applies the color curve. Called on change, on screen changes, and on a timer
    /// because macOS resets gamma when displays sleep/wake or reconnect.
    func apply() {
        guard enabled else { return }
        // Warm tint: blue drops the most, green a little (roughly 6500K -> 3000K at full warmth).
        let tint = (r: 1.0, g: 1.0 - 0.25 * warmth, b: 1.0 - 0.62 * warmth)
        let curve = contrastCurve()
        let r = curve.map { CGGammaValue($0 * brightness * tint.r) }
        let g = curve.map { CGGammaValue($0 * brightness * tint.g) }
        let b = curve.map { CGGammaValue($0 * brightness * tint.b) }
        for id in displays() where !builtInOnly || CGDisplayIsBuiltin(id) != 0 {
            CGSetDisplayTransferByTable(id, 256, r, g, b)
        }
    }

    /// Maps input level (0...1) to output level for the current contrast setting.
    /// Softer: lifts blacks and pulls down whites, like ink on paper.
    /// Sharper: S-curve that darkens grey text and brightens light backgrounds,
    /// without hard clipping so detail near black/white isn't lost.
    private func contrastCurve() -> [Double] {
        (0..<256).map { i in
            let x = Double(i) / 255
            if contrast < 0 {
                let c = -contrast
                let lo = 0.16 * c, hi = 1 - 0.10 * c
                return lo + x * (hi - lo)
            } else {
                let s = x * x * (3 - 2 * x)          // smoothstep S-curve
                return x + (s - x) * contrast
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var timer: Timer?
    var isDuplicate = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // Only one copy may run; a second copy would keep re-applying its own settings.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) {
            isDuplicate = true
            NSApp.terminate(nil)
            return
        }
        Filter.shared.apply()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in Filter.shared.apply() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in Filter.shared.apply() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                          object: nil, queue: .main) { _ in Filter.shared.apply() }
        registerHotKey()
    }

    func applicationWillTerminate(_ n: Notification) {
        if !isDuplicate { CGDisplayRestoreColorSyncSettings() }
    }

    // Control + Option + R toggles reader mode from anywhere.
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Filter.shared.enabled.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x5244_4D44), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

struct MenuView: View {
    @EnvironmentObject var f: Filter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reader Mode").font(.headline)
                Spacer()
                Toggle("", isOn: $f.enabled).toggleStyle(.switch).labelsHidden()
            }

            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    Button { f.select(i) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: slotIcons[i]).font(.system(size: 16))
                            Text(slotNames[i]).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(f.enabled && f.selected == i ? Color.orange.opacity(0.35) : Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }

            slider("Contrast", "circle.lefthalf.filled", $f.contrast, -1...1, ends: ("Softer", "Sharper"))
            slider("Warmth", "sun.max", $f.warmth, 0...1, ends: ("None", "Warm"))
            slider("Brightness", "light.max", $f.brightness, 0.3...1, ends: ("Dim", "Full"))

            HStack {
                Spacer()
                Button(f.unsaved ? "Save to \(slotNames[f.selected])" : "Saved") { f.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!f.enabled || !f.unsaved)
            }

            Divider()
            Toggle("Only laptop screen", isOn: $f.builtInOnly)
            Toggle("Open at login", isOn: $f.atLogin)
            HStack {
                Text("⌃⌥R toggles it anywhere").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    func slider(_ name: String, _ icon: String, _ v: Binding<Double>, _ r: ClosedRange<Double>,
                ends: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(name, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Slider(value: v, in: r).disabled(!f.enabled)
            HStack {
                Text(ends.0); Spacer(); Text(ends.1)
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

@main
struct ReaderModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var f = Filter.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(f)
        } label: {
            Image(systemName: f.enabled ? "book.fill" : "book")
        }
        .menuBarExtraStyle(.window)
    }
}
