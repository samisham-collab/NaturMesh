# naturMesh for iOS

**The network that survives the weather.**

The iPhone app behind the naturMesh site: nearby phones become an encrypted,
self-healing mesh for emergency services. No tower, no server, no account.
Every phone is a relay.

- SwiftUI · iOS 17+ · Xcode 16 · no third-party dependencies
- Text, position, SOS, check-ins and direct messages only. Photos, audio and video cannot enter the mesh.
- Branding follows `../index.html`: the palette (`moss`, `canopy`, `bark`, `birch`, `lichen`, `signal`, `ember`),
  Fraunces for display and Archivo for text (bundled, SIL OFL), the leaf-venation mark and the natur**Mesh** wordmark.

## How it works

| Layer | Choice |
|---|---|
| Link | Apple MultipeerConnectivity (Bluetooth + peer-to-peer Wi-Fi + LAN), encrypted per link, up to 7 direct neighbours |
| Routing | Controlled flooding with a hop limit (default 5, max 7), duplicate cache, 50–250 ms relay jitter |
| Identity | Ed25519 signing key and X25519 agreement key per device, in the Keychain. Every packet is signed. Node ID = hash of the signing key. No accounts, phone numbers or email |
| Confidentiality | ChaCha20-Poly1305 with a key derived (HKDF) from a channel passphrase. Same passphrase = can read; everyone else still relays |
| Wire format | Compact binary header + encrypted body + signature, under 700 bytes worst case |

### Flood protection

Every inbound packet is checked in this order, cheapest first:

1. Per-neighbour token bucket (20 msg/s, burst 40). A spamming neighbour is throttled whatever keys it rotates.
2. Size, version, kind and hop-limit check. Only six message kinds exist. Multipeer streams and file transfers are refused.
3. Duplicate suppression, then an age window (6 h back, 15 min forward) against replay. Each phone passes a message on once, then forgets it.
4. Signature verification.
5. Per-sender token bucket (1 msg / 3 s, burst 4). SOS has its own limit of one per 10 s.
6. SOS beats check-in beats position beats text when links are busy.

### What the site promises, and where it lives in the code

| Site | App |
|---|---|
| Bluetooth to find phones, Wi-Fi Direct to move messages, no pairing | `Mesh/Transport.swift`: MultipeerConnectivity does both, encrypted per link |
| 7 hops before a message retires; each phone passes it on once, then forgets it | `Mesh/MeshNode.swift` controlled flooding + `Mesh/Guard.swift` duplicate cache |
| "Or it rides in a pocket": store and forward, minutes to hours | `Mesh/MeshNode.swift` carry store: accepted packets are kept up to 6 h (400 max, priority first) and offered to every new neighbour, paced under its rate limit |
| The first phone with a tower, satellite or live Wi-Fi becomes everyone's gateway | `Services/UplinkMonitor.swift` (NWPathMonitor + a tiny captive-portal probe) sets the gateway flag in this phone's hello; Nearby shows who the exits are. Forwarding traffic *through* the exit is the next piece of work |
| A surviving access point bridges two clusters | Multipeer also runs over infrastructure Wi-Fi, so phones on the same AP mesh together with no extra code |
| 0 accounts, phone numbers or email | Keys are generated on device and never leave it |
| X25519 end-to-end on every direct message | `Mesh/Identity.swift` pair key (X25519 + HKDF) and `Mesh/Crypto.swift` `DirectBox`; tap a peer in Nearby |
| Group channels for a shelter roster or a road-clearing crew | Channel passphrases, saved and switchable in Settings |
| An urgent flag that cuts through a hundred messages | `!` in the composer; the flag is signed in the header and drawn in ember |
| Free. Actually free. | There is nothing to buy |

Also: hold-to-send **SOS** (2 s, GPS attached, always max hops), one-tap **check-ins** with battery level,
a **Nearby** list with distance and bearing, optional **position sharing** every 5 minutes, and **traffic stats**
so you can watch the limits work.

Honest limits: iOS does not let an app relay from the background indefinitely, so "sits at zero battery cost until
the day it matters, then wakes up on its own" is not something a third-party app can fully deliver today. The app
relays while it is open, and the carry store means a phone that was open earlier still delivers what it heard.

## Layout

```
NaturMesh/
  App/        AppModel — UI state, owns the mesh node
  Mesh/       Wire format, identity, channel + direct crypto, inbound guard, transport, routing, carry store, peers
  Services/   Location, battery, uplink monitor
  Theme/      Brand tokens, LeafMark, Wordmark (colours live in Assets.xcassets)
  Fonts/      Fraunces and Archivo (SIL Open Font License)
  UI/         SwiftUI views
```

## Build

Open `NaturMesh.xcodeproj` in Xcode 16, set your team under Signing, run on two or more iPhones.
Multipeer does not work in the simulator across devices; use real phones.
