import Foundation

/// Classic token bucket. `rate` tokens per second refill, `burst` is the ceiling.
struct TokenBucket {
    let rate: Double
    let burst: Double
    private var tokens: Double
    private var last: Date

    init(rate: Double, burst: Double, now: Date = Date()) {
        self.rate = rate; self.burst = burst; tokens = burst; last = now
    }

    mutating func take(now: Date = Date()) -> Bool {
        tokens = min(burst, tokens + now.timeIntervalSince(last) * rate)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

enum DropReason: String, CaseIterable, Identifiable {
    case neighbourRate = "Neighbour rate limit"
    case malformed = "Malformed"
    case duplicate = "Duplicate"
    case clock = "Clock window"
    case badSignature = "Bad signature"
    case senderRate = "Sender rate limit"
    case sosRate = "SOS rate limit"
    case hopLimit = "Hop limit reached"

    var id: String { rawValue }
}

struct TrafficStats: Equatable {
    var sent = 0
    var received = 0
    var relayed = 0
    var dropped: [DropReason: Int] = [:]
    var totalDropped: Int { dropped.values.reduce(0, +) }
}

/// Every inbound packet passes these checks, cheapest first, so a flood is shed before it costs anything.
///
/// 1. Per-neighbour token bucket (whoever is on the other end of the link, regardless of the keys they claim).
/// 2. Size, version, kind and hop-limit check while decoding.
/// 3. Duplicate suppression, then an age window (6 h back, 15 min forward) against replay.
/// 4. Signature verification.
/// 5. Per-sender token bucket, with a separate, tighter limit for SOS.
final class InboundGuard {
    struct Limits {
        var neighbourRate = 20.0, neighbourBurst = 40.0
        var senderRate = 1.0 / 3.0, senderBurst = 4.0
        var sosRate = 1.0 / 10.0, sosBurst = 2.0
        /// How far in the future a timestamp may be. Guards against clock games, not carried messages.
        var maxFutureSkew: TimeInterval = 15 * 60
        /// How old a message may be and still be accepted. Matches the carry store, so a message can
        /// ride in a pocket for hours and still deliver itself.
        var maxAge: TimeInterval = 6 * 60 * 60
        var dedupeCapacity = 8192
    }

    var limits = Limits()
    private var neighbours: [String: TokenBucket] = [:]
    private var senders: [NodeID: TokenBucket] = [:]
    private var sosSenders: [NodeID: TokenBucket] = [:]
    private var seen: Set<MessageID> = []
    private var seenOrder: [MessageID] = []

    enum Verdict {
        case accept(Packet)
        case drop(DropReason)
    }

    func inspect(_ data: Data, fromNeighbour link: String, now: Date = Date()) -> Verdict {
        // 1. neighbour bucket
        var nb = neighbours[link] ?? TokenBucket(rate: limits.neighbourRate, burst: limits.neighbourBurst, now: now)
        let ok = nb.take(now: now)
        neighbours[link] = nb
        guard ok else { return .drop(.neighbourRate) }

        // 2. structure
        guard let packet = try? Packet.decode(data) else { return .drop(.malformed) }

        // 3. duplicate, then clock
        if seen.contains(packet.id) { return .drop(.duplicate) }
        let age = now.timeIntervalSince(packet.timestamp)
        guard age <= limits.maxAge, -age <= limits.maxFutureSkew else { return .drop(.clock) }

        // 4. signature
        guard Identity.verify(signature: packet.signature, of: packet.signedBytes, publicKey: packet.senderPublicKey) else {
            return .drop(.badSignature)
        }

        // 5. sender buckets
        let sender = packet.sender
        var sb = senders[sender] ?? TokenBucket(rate: limits.senderRate, burst: limits.senderBurst, now: now)
        let senderOK = sb.take(now: now)
        senders[sender] = sb
        guard senderOK else { return .drop(.senderRate) }
        if packet.kind == .sos {
            var xb = sosSenders[sender] ?? TokenBucket(rate: limits.sosRate, burst: limits.sosBurst, now: now)
            let sosOK = xb.take(now: now)
            sosSenders[sender] = xb
            guard sosOK else { return .drop(.sosRate) }
        }

        remember(packet.id)
        return .accept(packet)
    }

    /// Our own messages go into the cache too, so an echo from a neighbour is dropped.
    func remember(_ id: MessageID) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > limits.dedupeCapacity {
            let old = seenOrder.removeFirst()
            seen.remove(old)
        }
    }

    func forget(neighbour link: String) { neighbours[link] = nil }
}
