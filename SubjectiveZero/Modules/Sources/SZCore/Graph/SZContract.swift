// SPDX-License-Identifier: AGPL-3.0-only
// The node contract — single source of truth for a node's UI and the runtime's I/O enforcement
// (docs/GRAPH_AND_NODES.md, docs/BUILD_SPEC.md). Pure value types, `Codable`, no Metal/macOS imports;
// `NodeContract ⇄ node-contract.json`.
import Foundation

/// The built-in port type set (mirrored by the runtime value set + the editor controls).
public enum SZPortType: String, Codable, Sendable, CaseIterable {
    case float, float2, float3, float4
    case float3x3, float4x4
    case colorRGB, colorRGBA
    case texture                       // MTLTexture handle (by id at runtime)
    case floatArray                    // variable-length [Float], connection-only; flows over the value channel (no by-value default)
    case bool
    case enumeration = "enum"
    case string, event
}

/// A typed value carried by a port default (and, at runtime, across data edges). Encodes as a tagged
/// object — `{ "type": "float", "value": 1.0 }` — so JSON stays self-describing and round-trips stably.
/// Vector/matrix/color payloads are flat `[Double]` (counts: float2→2 … float4x4→16, colorRGBA→4).
public enum SZPortValue: Codable, Equatable, Sendable {
    case float(Double)
    case float2([Double])
    case float3([Double])
    case float4([Double])
    case float3x3([Double])
    case float4x4([Double])
    case colorRGB([Double])
    case colorRGBA([Double])
    case bool(Bool)
    case enumeration(String)
    case string(String)
    case event

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(SZPortType.self, forKey: .type)
        switch type {
        case .float:     self = .float(try c.decode(Double.self, forKey: .value))
        case .float2:    self = .float2(try c.decode([Double].self, forKey: .value))
        case .float3:    self = .float3(try c.decode([Double].self, forKey: .value))
        case .float4:    self = .float4(try c.decode([Double].self, forKey: .value))
        case .float3x3:  self = .float3x3(try c.decode([Double].self, forKey: .value))
        case .float4x4:  self = .float4x4(try c.decode([Double].self, forKey: .value))
        case .colorRGB:  self = .colorRGB(try c.decode([Double].self, forKey: .value))
        case .colorRGBA: self = .colorRGBA(try c.decode([Double].self, forKey: .value))
        case .bool:      self = .bool(try c.decode(Bool.self, forKey: .value))
        case .enumeration: self = .enumeration(try c.decode(String.self, forKey: .value))
        case .string:    self = .string(try c.decode(String.self, forKey: .value))
        case .event:     self = .event
        case .texture, .floatArray:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "\(type.rawValue) has no by-value default")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .float(let v):     try c.encode(v, forKey: .value)
        case .float2(let v),
             .float3(let v),
             .float4(let v),
             .float3x3(let v),
             .float4x4(let v),
             .colorRGB(let v),
             .colorRGBA(let v): try c.encode(v, forKey: .value)
        case .bool(let v):      try c.encode(v, forKey: .value)
        case .enumeration(let v): try c.encode(v, forKey: .value)
        case .string(let v):    try c.encode(v, forKey: .value)
        case .event:            break
        }
    }

    /// The port type this value carries.
    public var type: SZPortType {
        switch self {
        case .float: .float
        case .float2: .float2
        case .float3: .float3
        case .float4: .float4
        case .float3x3: .float3x3
        case .float4x4: .float4x4
        case .colorRGB: .colorRGB
        case .colorRGBA: .colorRGBA
        case .bool: .bool
        case .enumeration: .enumeration
        case .string: .string
        case .event: .event
        }
    }

    /// The value as a flat `[Float]` for the runtime's scalar-input ABI channel (`float`/vectors/colors/
    /// matrices, and `bool` as 0/1). `nil` for the non-numeric kinds — enum/string ride the
    /// string-input channel instead, and `event` carries no value.
    public var floats: [Float]? {
        switch self {
        case .float(let v): [Float(v)]
        case .float2(let a), .float3(let a), .float4(let a),
             .colorRGB(let a), .colorRGBA(let a), .float3x3(let a), .float4x4(let a): a.map(Float.init)
        case .bool(let b): [b ? 1 : 0]
        case .enumeration, .string, .event: nil
        }
    }

    /// The value as a `String` for the runtime's v4 string-input channel — the chosen option of an `enum`
    /// or the text of a `string`. `nil` for the other kinds (they cross as floats or not at all).
    public var string: String? {
        switch self {
        case .enumeration(let s), .string(let s): s
        default: nil
        }
    }
}

/// One choice of an `enum` port: a human `label` (shown in the dropdown / read by an agent) and the
/// canonical `value` carried over the v4 string channel and switched on by the node. Encoded
/// **positionally** as `["label", "value"]` — a flat pair with no named fields to invite nesting.
public struct SZEnumOption: Codable, Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// `label == value` — the common static case (e.g. blend modes).
    public init(value: String) {
        self.label = value
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.label = try c.decode(String.self)
        self.value = try c.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(label)
        try c.encode(value)
    }
}

/// The editor control hint shown for an unconnected input (docs/GRAPH_AND_NODES.md). `filePicker` is how
/// a `string` port marks itself as a path — there is no separate `file` type.
public enum SZPortUIKind: String, Codable, Sendable {
    case slider, field, colorWell, toggle, dropdown, filePicker
}

public struct SZPortUI: Codable, Equatable, Sendable {
    public var kind: SZPortUIKind
    public var min: Double?
    public var max: Double?
    public var step: Double?

    public init(kind: SZPortUIKind, min: Double? = nil, max: Double? = nil, step: Double? = nil) {
        self.kind = kind
        self.min = min
        self.max = max
        self.step = step
    }
}

/// A typed input or output port. `def` is the unconnected-input default (`"default"` in JSON); `display`
/// marks a texture output as a render-endpoint candidate.
public struct SZPort: Codable, Equatable, Sendable {
    public var name: String
    public var type: SZPortType
    public var ui: SZPortUI?
    public var def: SZPortValue?
    public var display: Bool?
    /// The static choices for an `enum` port. A *dynamic* enum (e.g. `camera`) leaves this nil/empty and
    /// the node supplies its options at runtime; the host's effective options are the
    /// node-returned list if any, else this.
    public var options: [SZEnumOption]?

    public init(
        name: String,
        type: SZPortType,
        ui: SZPortUI? = nil,
        def: SZPortValue? = nil,
        display: Bool? = nil,
        options: [SZEnumOption]? = nil
    ) {
        self.name = name
        self.type = type
        self.ui = ui
        self.def = def
        self.display = display
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, ui
        case def = "default"
        case display, options
    }
}

/// A host-granted entitlement a node needs to run (docs/RUNTIME.md). Pre-granted on project load by the
/// runtime's permission broker. Minimal by design — extended one case at a time as a node needs it.
public enum SZEntitlement: String, Codable, Sendable {
    case camera
    case microphone
}

/// `NodeContract ⇄ node-contract.json` — the node's typed I/O + identity. `permissions` travels with the
/// contract so a copied library node carries its entitlement, and the runtime can pre-grant before load.
public struct SZNodeContract: Codable, Equatable, Sendable {
    public var title: String
    public var sfSymbol: String
    public var summary: String
    public var inputs: [SZPort]
    public var outputs: [SZPort]
    public var permissions: [SZEntitlement]?   // nil/omitted == none

    public init(
        title: String,
        sfSymbol: String,
        summary: String,
        inputs: [SZPort] = [],
        outputs: [SZPort] = [],
        permissions: [SZEntitlement]? = nil
    ) {
        self.title = title
        self.sfSymbol = sfSymbol
        self.summary = summary
        self.inputs = inputs
        self.outputs = outputs
        self.permissions = permissions
    }

    /// One port as generated code sees it: which side it's on, what it's called, what type it carries. Direction
    /// is part of the identity — a `float` named `x` read as an input and one written as an output are different
    /// obligations on the code, so a set that ignored direction would let a port move side without registering.
    public struct PortSignature: Hashable, Sendable {
        public enum Direction: Hashable, Sendable { case input, output }
        public var direction: Direction
        public var name: String
        public var type: SZPortType
    }

    /// The part of the contract that generated code must satisfy, and therefore the only part whose change
    /// invalidates a build (see `SZNode.needsRebuild`).
    ///
    /// Excluded on purpose: `display`, `def`, `ui` and `options` (presentation and values — the runtime seeds
    /// them, code never names them), `title`/`sfSymbol`/`summary` (identity), and `permissions` (pre-granted by
    /// the runtime broker, never read from the contract by node code). Port *order* is excluded too: runtime and
    /// audit both address ports by name, never by index.
    public var portSurface: Set<PortSignature> {
        var surface = Set<PortSignature>()
        for p in inputs { surface.insert(PortSignature(direction: .input, name: p.name, type: p.type)) }
        for p in outputs { surface.insert(PortSignature(direction: .output, name: p.name, type: p.type)) }
        return surface
    }

    /// Declared entitlements, normalized to a list.
    public var requiredPermissions: [SZEntitlement] { permissions ?? [] }
}
