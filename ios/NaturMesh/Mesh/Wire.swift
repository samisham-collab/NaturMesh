import Foundation
import CryptoKit

/// Message kinds that may travel over the mesh. There is deliberately no kind for
/// photo, audio or video: media cannot enter the mesh at all.
enum MessageKind: UInt8, CaseIterable {
    case text = 1
    case position = 2
    case sos = 3
    case checkIn = 4
    case ack = 5
    case gatewayAdvert = 6   // reserved for residence / uplink gateways (a fixed AP, satellite or wired)
    case hello = 7           // who I am: name, key-agreement key, battery, gateway flag
    case direct = 8          // end-to-end encrypted to one node (X25519), relayed opaque by everyone else

    /// Higher wins when links are busy.
    var priority: Int {
        switch self {
        case .sos: return 5
        case .checkIn: return 3
        case .direct: return 2
        case .position, .hello: return 1
        case .gatewayAdvert: return 1
        case .text, .ack: return 0
        }
    }
}

/// Header flag bits. Signed along with the rest of the header.
enum PacketFlags {
    static let urgent: UInt8 = 0x01
}

enum CheckInStatus: UInt8, CaseIterable, Identifiable {
    case ok = 1
    case needHelp = 2
    case evacuated = 3

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .ok: return "I'm OK"
        case .needHelp: return "Need help"
        case .evacuated: return "Safe / evacuated"
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .needHelp: return "exclamationmark.triangle.fill"
        case .evacuated: return "figure.walk.arrival"
        }
    }
}

struct GeoPoint: Equatable {
    var latitude: Double
    var longitude: Double
    var accuracyMeters: UInt16
}

/// Decrypted body of a packet.
enum Payload: Equatable {
    case text(String, urgent: Bool)
    case position(GeoPoint, battery: UInt8, name: String)
    case sos(GeoPoint?, battery: UInt8, name: String, note: String)
    case checkIn(CheckInStatus, GeoPoint?, battery: UInt8, name: String)
    case ack(MessageID)
    case gatewayAdvert(name: String)
    case hello(name: String, agreementKey: Data, battery: UInt8, gateway: Bool)
    /// `to` is the recipient node, `box` is nonce + ciphertext + tag under the pair key. Only the recipient can open it.
    case direct(to: NodeID, box: Data)

    var kind: MessageKind {
        switch self {
        case .text: return .text
        case .position: return .position
        case .sos: return .sos
        case .checkIn: return .checkIn
        case .ack: return .ack
        case .gatewayAdvert: return .gatewayAdvert
        case .hello: return .hello
        case .direct: return .direct
        }
    }

    var isUrgent: Bool {
        switch self {
        case .text(_, let u): return u
        case .sos: return true
        default: return false
        }
    }
}

struct MessageID: Hashable {
    let bytes: [UInt8] // 16 bytes

    init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        self.bytes = bytes
    }

    static func random() -> MessageID {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        return MessageID(bytes: b)
    }

    var short: String { bytes.prefix(4).map { String(format: "%02x", $0) }.joined() }
}

/// Node identity as seen on the wire: the hash of the signing public key.
struct NodeID: Hashable, Comparable {
    let raw: [UInt8] // 8 bytes
    var hex: String { raw.map { String(format: "%02x", $0) }.joined() }

    init(publicKey: Data) {
        let digest = SHA256.hash(data: publicKey)
        raw = Array(digest.prefix(8))
    }

    init(raw: [UInt8]) {
        precondition(raw.count == 8)
        self.raw = raw
    }

    static func < (a: NodeID, b: NodeID) -> Bool { a.hex < b.hex }
    var short: String { String(hex.prefix(6)).uppercased() }
}

enum Wire {
    static let magic: [UInt8] = [0x4E, 0x4D] // "NM"
    static let version: UInt8 = 1
    static let defaultHopLimit: UInt8 = 5
    static let maxHopLimit: UInt8 = 7
    /// Whole packet, worst case, stays under this. Anything larger is refused.
    static let maxPacketBytes = 700
    static let maxBodyBytes = 320
    static let maxNameBytes = 16
    static let signatureBytes = 64
    static let publicKeyBytes = 32
    static let nonceBytes = 12
    static let tagBytes = 16
    /// magic(2) version(1) kind(1) flags(1) hopLimit(1) hopCount(1) channel(4) msgId(16) sender(32) ts(8) nonce(12) bodyLen(2)
    static let headerBytes = 2 + 1 + 1 + 1 + 1 + 1 + 4 + 16 + 32 + 8 + 12 + 2
    static let hopCountOffset = 6
}

/// Header + encrypted body + signature. The body is opaque until the channel key opens it.
struct Packet {
    var kind: MessageKind
    var flags: UInt8
    var hopLimit: UInt8
    var hopCount: UInt8
    var channelTag: UInt32
    var id: MessageID
    var senderPublicKey: Data
    var timestampMillis: UInt64
    var nonce: Data
    var ciphertext: Data   // body + 16 byte tag
    var signature: Data

    var sender: NodeID { NodeID(publicKey: senderPublicKey) }
    var timestamp: Date { Date(timeIntervalSince1970: Double(timestampMillis) / 1000) }

    /// Bytes covered by the signature: every header field with hopCount zeroed, plus the ciphertext.
    var signedBytes: Data {
        var d = headerData(hopCount: 0)
        d.append(ciphertext)
        return d
    }

    /// Header bytes also used as additional authenticated data for the body.
    var aad: Data { headerData(hopCount: 0) }

    func headerData(hopCount hc: UInt8) -> Data {
        var w = ByteWriter()
        w.bytes(Wire.magic)
        w.u8(Wire.version)
        w.u8(kind.rawValue)
        w.u8(flags)
        w.u8(hopLimit)
        w.u8(hc)
        w.u32(channelTag)
        w.bytes(id.bytes)
        w.data(senderPublicKey)
        w.u64(timestampMillis)
        w.data(nonce)
        w.u16(UInt16(ciphertext.count))
        return w.data
    }

    func encode() -> Data {
        var d = headerData(hopCount: hopCount)
        d.append(ciphertext)
        d.append(signature)
        return d
    }

    enum DecodeError: Error { case tooShort, badMagic, badVersion, badKind, badLength, tooLarge, badHopLimit }

    static func decode(_ data: Data) throws -> Packet {
        guard data.count <= Wire.maxPacketBytes else { throw DecodeError.tooLarge }
        guard data.count >= Wire.headerBytes + Wire.tagBytes + Wire.signatureBytes else { throw DecodeError.tooShort }
        var r = ByteReader(data)
        guard r.bytes(2) == Wire.magic else { throw DecodeError.badMagic }
        guard r.u8() == Wire.version else { throw DecodeError.badVersion }
        guard let kind = MessageKind(rawValue: r.u8()) else { throw DecodeError.badKind }
        let flags = r.u8()
        let hopLimit = r.u8()
        let hopCount = r.u8()
        guard hopLimit >= 1, hopLimit <= Wire.maxHopLimit, hopCount <= hopLimit else { throw DecodeError.badHopLimit }
        let channelTag = r.u32()
        let id = MessageID(bytes: r.bytes(16))
        let sender = Data(r.bytes(Wire.publicKeyBytes))
        let ts = r.u64()
        let nonce = Data(r.bytes(Wire.nonceBytes))
        let bodyLen = Int(r.u16())
        guard bodyLen >= Wire.tagBytes, bodyLen <= Wire.maxBodyBytes + Wire.tagBytes else { throw DecodeError.badLength }
        guard r.remaining == bodyLen + Wire.signatureBytes else { throw DecodeError.badLength }
        let ciphertext = Data(r.bytes(bodyLen))
        let signature = Data(r.bytes(Wire.signatureBytes))
        return Packet(kind: kind, flags: flags, hopLimit: hopLimit, hopCount: hopCount, channelTag: channelTag,
                      id: id, senderPublicKey: sender, timestampMillis: ts, nonce: nonce,
                      ciphertext: ciphertext, signature: signature)
    }
}

// MARK: - Payload coding

extension Payload {
    func encode() -> Data {
        var w = ByteWriter()
        switch self {
        case .text(let s, _):
            w.string(s, max: Wire.maxBodyBytes - 2)
        case .position(let p, let battery, let name):
            w.geo(p); w.u8(battery); w.name(name)
        case .sos(let p, let battery, let name, let note):
            w.optGeo(p); w.u8(battery); w.name(name); w.string(note, max: 120)
        case .checkIn(let status, let p, let battery, let name):
            w.u8(status.rawValue); w.optGeo(p); w.u8(battery); w.name(name)
        case .ack(let id):
            w.bytes(id.bytes)
        case .gatewayAdvert(let name):
            w.name(name)
        case .hello(let name, let key, let battery, let gateway):
            w.name(name); w.data(key.prefix(32)); w.u8(battery); w.u8(gateway ? 1 : 0)
        case .direct(let to, let box):
            w.bytes(to.raw); w.data(box)
        }
        return w.data
    }

    enum DecodeError: Error { case malformed }

    static func decode(kind: MessageKind, _ data: Data) throws -> Payload {
        var r = ByteReader(data)
        do {
            switch kind {
            case .text:
                return .text(try r.string(), urgent: false) // urgency rides in the header flags
            case .position:
                let p = try r.geo(); let b = r.u8(); let n = try r.name()
                return .position(p, battery: b, name: n)
            case .sos:
                let p = try r.optGeo(); let b = r.u8(); let n = try r.name(); let note = try r.string()
                return .sos(p, battery: b, name: n, note: note)
            case .checkIn:
                guard let s = CheckInStatus(rawValue: r.u8()) else { throw DecodeError.malformed }
                let p = try r.optGeo(); let b = r.u8(); let n = try r.name()
                return .checkIn(s, p, battery: b, name: n)
            case .ack:
                guard r.remaining >= 16 else { throw DecodeError.malformed }
                return .ack(MessageID(bytes: r.bytes(16)))
            case .gatewayAdvert:
                return .gatewayAdvert(name: try r.name())
            case .hello:
                let n = try r.name()
                guard r.remaining >= 34 else { throw DecodeError.malformed }
                let key = Data(r.bytes(32)); let b = r.u8(); let g = r.u8()
                return .hello(name: n, agreementKey: key, battery: b, gateway: g == 1)
            case .direct:
                guard r.remaining >= 8 + Wire.nonceBytes + Wire.tagBytes else { throw DecodeError.malformed }
                let to = NodeID(raw: r.bytes(8))
                return .direct(to: to, box: Data(r.bytes(r.remaining)))
            }
        } catch {
            throw DecodeError.malformed
        }
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { data.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8((v >> UInt64(s)) & 0xff)) } }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func data(_ d: Data) { data.append(d) }

    mutating func string(_ s: String, max: Int) {
        var bytes = Array(s.utf8)
        if bytes.count > max { bytes = Array(bytes.prefix(max)) }
        u16(UInt16(bytes.count)); self.bytes(bytes)
    }

    mutating func name(_ s: String) {
        var bytes = Array(s.utf8)
        if bytes.count > Wire.maxNameBytes { bytes = Array(bytes.prefix(Wire.maxNameBytes)) }
        u8(UInt8(bytes.count)); self.bytes(bytes)
    }

    mutating func geo(_ p: GeoPoint) {
        u64(p.latitude.bitPattern); u64(p.longitude.bitPattern); u16(p.accuracyMeters)
    }

    mutating func optGeo(_ p: GeoPoint?) {
        if let p { u8(1); geo(p) } else { u8(0) }
    }
}

struct ByteReader {
    private let d: [UInt8]
    private var i = 0

    init(_ data: Data) { d = [UInt8](data) }

    var remaining: Int { d.count - i }

    mutating func u8() -> UInt8 { guard i < d.count else { return 0 }; defer { i += 1 }; return d[i] }
    mutating func u16() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }
    mutating func u32() -> UInt32 { var v: UInt32 = 0; for _ in 0..<4 { v = v << 8 | UInt32(u8()) }; return v }
    mutating func u64() -> UInt64 { var v: UInt64 = 0; for _ in 0..<8 { v = v << 8 | UInt64(u8()) }; return v }
    mutating func bytes(_ n: Int) -> [UInt8] {
        let end = min(i + n, d.count)
        let out = Array(d[i..<end]) + [UInt8](repeating: 0, count: max(0, n - (end - i)))
        i = end
        return out
    }

    mutating func string() throws -> String {
        let n = Int(u16()); guard n <= remaining else { throw Payload.DecodeError.malformed }
        guard let s = String(bytes: bytes(n), encoding: .utf8) else { throw Payload.DecodeError.malformed }
        return s
    }

    mutating func name() throws -> String {
        let n = Int(u8()); guard n <= Wire.maxNameBytes, n <= remaining else { throw Payload.DecodeError.malformed }
        guard let s = String(bytes: bytes(n), encoding: .utf8) else { throw Payload.DecodeError.malformed }
        return s
    }

    mutating func geo() throws -> GeoPoint {
        guard remaining >= 18 else { throw Payload.DecodeError.malformed }
        let lat = Double(bitPattern: u64()), lon = Double(bitPattern: u64()), acc = u16()
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { throw Payload.DecodeError.malformed }
        return GeoPoint(latitude: lat, longitude: lon, accuracyMeters: acc)
    }

    mutating func optGeo() throws -> GeoPoint? {
        switch u8() {
        case 0: return nil
        case 1: return try geo()
        default: throw Payload.DecodeError.malformed
        }
    }
}
