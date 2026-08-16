// Controller card — the shared face of every binding-source node (MIDI Input, OSC Input): learn
// mints outputs. Press Learn → move a physical control → when it SETTLES (steady for a beat) the
// binding auto-commits as a new output socket on this node (settle = commit, no Bind button); the
// user wires the socket by an ordinary canvas drag. Each learned control is a strip: label · wire
// key · live value · bar. Renders host-pushed state ONLY — strips from snapshot truth (outputs ∩
// the mappings table), the activity monitor, bars and the armed candidate from telemetry.
// Source-agnostic: the key is whatever the node reports (MIDI "ch1/cc21", OSC "/1/fader1").
// Tweak freely: the palette + settle constants sit at the top; the layout is three plain sections.
import SwiftUI

struct ControllerCard: View {
    @ObservedObject var state: SZCardState

    // Palette — the node-card family's tiers: proportional semibold = identity, monospaced = data.
    static let accent = Color(red: 0.4, green: 0.78, blue: 1.0)      // the card-family accent (corner-pin's)
    static let hot = Color(red: 0.98, green: 0.78, blue: 0.13)       // armed / listening
    static let text = Color.white.opacity(0.9)
    static let dim = Color.white.opacity(0.5)
    static let faint = Color.white.opacity(0.08)
    static let mono = Font.system(size: 9.5, design: .monospaced)

    // Settle detection: the candidate must hold (same key, quiet value) this long before commit.
    static let settleSeconds: TimeInterval = 0.7
    static let movedThreshold = 0.004
    // Activity monitor: the dot stays lit this long after the last event.
    static let activityGlow: TimeInterval = 0.25

    @State private var last: (key: String, value01: Double, at: Date)?
    @State private var committing = false
    @State private var lastSeq: Double = 0
    @State private var lastEventAt: Date = .distantPast
    @State private var now: Date = Date()
    @State private var hovered: String?

    struct Strip: Identifiable {
        let id: String        // the minted output port name
        let label: String
        let key: String
        let min: Double
        let max: Double
    }

    // MARK: - model over the pushed state

    private var table: [[String: Any]] {
        (try? JSONSerialization.jsonObject(
            with: Data((state.input("mappings")?.defaultString ?? "[]").utf8))) as? [[String: Any]] ?? []
    }

    /// One strip per minted output: float outputs named by the mappings table (the lastEvent /
    /// lastKey learn signal is plumbing, not a control). A row without a label is titled by its key.
    var strips: [Strip] {
        var byPort: [String: [String: Any]] = [:]
        for row in table { if let port = row["port"] as? String { byPort[port] = row } }
        return state.outputs.compactMap { port in
            guard port.type == "float", let row = byPort[port.name] else { return nil }
            let key = row["key"] as? String ?? ""
            let label = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Strip(id: port.name, label: label ?? key, key: key,
                         min: (row["min"] as? NSNumber)?.doubleValue ?? 0,
                         max: (row["max"] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    var armed: Bool { state.learn?.armed == true }
    var active: Bool { now.timeIntervalSince(lastEventAt) < Self.activityGlow }

    // MARK: - body

    var body: some View {
        let strips = strips
        VStack(alignment: .leading, spacing: 0) {
            // Header: Learn + the activity monitor. Learn lives up here so the footprint's row
            // slack (the region snaps to 24 pt rows) falls under the strip list, never after a button.
            header
                .padding(.bottom, strips.isEmpty ? 4 : 6)
            if strips.isEmpty {
                emptyState
            } else {
                ForEach(strips) { strip in stripRow(strip) }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10))
        // Every host push (~30 Hz telemetry) ticks the activity + settle machines.
        .onReceive(state.objectWillChange) { _ in tick() }
    }

    /// Header: the Learn button (idle → button; armed → pulsing "Listening…" pill, tap to cancel)
    /// and the activity monitor — a dot that lights on every event + the newest key and value, the
    /// "is my controller talking to this node at all?" answer before anything is bound. While
    /// armed the monitor slot shows the learn hint instead. Settle = commit; the host disarms after
    /// the commit and the new strip arrives with the next snapshot.
    private var header: some View {
        let event = state.values("lastEvent")
        let key = state.string("lastKey")
        return HStack(spacing: 8) {
            Button {
                state.call(armed ? "learn_cancel" : "learn_arm")
            } label: {
                HStack(spacing: 5) {
                    if armed {
                        Circle().fill(Self.hot).frame(width: 6, height: 6).modifier(Pulse())
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9, weight: .semibold))
                    }
                    Text(armed ? "Listening…" : "Learn").font(.system(size: 10.5, weight: .semibold))
                }
                .fixedSize()   // the pill never wraps or truncates — the status text yields instead
                .foregroundStyle(armed ? Color.black.opacity(0.85) : Self.text)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(armed ? Self.hot : Color.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().stroke(armed ? Self.hot : Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help(armed ? "Cancel learn" : "Arm learn, then move a control on your device — it becomes an output socket")
            if armed {
                Text(hint).font(.system(size: 10)).foregroundStyle(Self.hot).lineLimit(1)
            } else {
                Circle()
                    .fill(active ? Self.accent : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
                    .shadow(color: active ? Self.accent.opacity(0.8) : .clear, radius: 3)
                if let key, event.count >= 2, event[0] > 0 {
                    Text(key).font(Self.mono).foregroundStyle(active ? Self.text : Self.dim).lineLimit(1)
                    Text(Self.percent(event[1])).font(Self.mono).foregroundStyle(Self.dim).fixedSize()
                } else {
                    // Idle: an OSC node shows where the phone should point; MIDI just waits.
                    Text(idleStatus).font(Self.mono).foregroundStyle(Self.dim).lineLimit(1).truncationMode(.middle)
                        .help(idleHelp)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// OSC: the port it listens on (short — never truncates), full address in the tooltip and in the
    /// empty state. MIDI: just waiting.
    private var oscPort: Int? { state.input("port").flatMap { $0.defaultDouble }.map { Int($0) } }
    private var oscAddress: String? { oscPort.map { "\(Self.lanAddress ?? Self.hostLabel):\($0)" } }
    private var idleStatus: String { oscPort.map { "udp :\($0)" } ?? "waiting for a controller…" }
    private var idleHelp: String {
        guard let port = oscPort else { return "" }
        return "Send OSC to \(Self.lanAddress ?? "this Mac"):\(port) or \(Self.hostLabel):\(port) (UDP) — advertised as _osc._udp"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No controls yet")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.text)
            Text("Press Learn, then move a control on your device — it becomes an output socket you can wire.")
                .font(.system(size: 10)).foregroundStyle(Self.dim)
                .fixedSize(horizontal: false, vertical: true)
            if let address = oscAddress {
                Text("Point your OSC app at").font(.system(size: 10)).foregroundStyle(Self.dim)
                    .padding(.top, 4)
                Text(address).font(Self.mono).foregroundStyle(Self.text).lineLimit(1)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
                    .help(idleHelp)
            }
        }
        .padding(.vertical, 6)
    }

    private func stripRow(_ strip: Strip) -> some View {
        let value = state.values(strip.id).first
        let normalized = value.map { strip.max == strip.min ? 0 : ($0 - strip.min) / (strip.max - strip.min) } ?? 0
        let isHovered = hovered == strip.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(strip.label)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.text)
                    .lineLimit(1)
                if strip.label != strip.key {
                    Text(strip.key).font(Self.mono).foregroundStyle(Self.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(value.map { Self.format($0, in: strip) } ?? "—")
                    .font(Self.mono).foregroundStyle(value == nil ? Self.dim : Self.text)
                Button {
                    state.call("remove_binding", argsJSON: #"{"port":"\#(strip.id)"}"#)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isHovered ? Self.text : Self.dim.opacity(0.6))
                        .frame(width: 14, height: 14)
                        .background(isHovered ? Self.faint : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove this binding (drops its output socket)")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Self.faint)
                    Capsule().fill(Self.accent.opacity(value == nil ? 0.35 : 1))
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, normalized)))))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? strip.id : (hovered == strip.id ? nil : hovered) }
    }

    private var hint: String {
        guard let learn = state.learn, learn.armed else { return "" }
        guard learn.seen, let key = learn.key, let value01 = learn.value01 else { return "move the control you want…" }
        return "\(key) \(Self.percent(value01)) — hold still to bind"
    }

    // MARK: - machines (driven per host push)

    private func tick() {
        now = Date()
        // Activity: any advance of the event sequence lights the dot.
        let event = state.values("lastEvent")
        if event.count >= 1, event[0] != lastSeq {
            lastSeq = event[0]
            lastEventAt = now
        }
        // Settle: track the candidate; when it holds steady past the window, commit ONCE.
        guard let learn = state.learn, learn.armed else {
            committing = false
            last = nil
            return
        }
        guard learn.seen, let key = learn.key, let value01 = learn.value01 else { last = nil; return }
        if last == nil || key != last!.key || abs(value01 - last!.value01) > Self.movedThreshold {
            last = (key, value01, now)
        }
        if !committing, let held = last, now.timeIntervalSince(held.at) >= Self.settleSeconds {
            committing = true   // one commit per gesture
            state.call("learn_commit")
        }
    }

    // MARK: - formatting

    private static func percent(_ value01: Double) -> String { "\(Int((value01 * 100).rounded()))%" }

    /// A 0…1 range reads as a percentage; anything else as the scaled value with sensible precision.
    private static func format(_ value: Double, in strip: Strip) -> String {
        if strip.min == 0, strip.max == 1 { return percent(value) }
        let span = abs(strip.max - strip.min)
        return String(format: span >= 100 ? "%.0f" : (span >= 10 ? "%.1f" : "%.2f"), value)
    }

    /// The Mac's Bonjour name (`.local`) — what an OSC app lists under discovery.
    private static let hostLabel: String = {
        let name = Host.current().localizedName ?? "this Mac"
        return name.hasSuffix(".local") ? name : name + ".local"
    }()

    /// The first non-loopback IPv4 address (Wi-Fi/Ethernet first) — what an OSC app asks you to type.
    private static let lanAddress: String? = {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var best: (rank: Int, address: String)?
        for ptr in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let rank = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)   // en0 = Wi-Fi/primary on most Macs
            if best == nil || rank < best!.rank { best = (rank, String(cString: buffer)) }
        }
        return best?.address
    }()
}

/// A slow breathing opacity — the "listening" pulse.
private struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true } }
    }
}

enum SZCardMain {
    static func make(_ state: SZCardState) -> AnyView { AnyView(ControllerCard(state: state)) }
}
