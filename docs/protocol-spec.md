# DDM Protocol Specification

Status: Working specification

## 1. Scope

This document defines the current target protocol model for DDM (Doomsday
Messenger).

It captures the current design direction from `brainstorm.md`, aligns it with
repository-level architectural constraints, and defines the intended wire
format baseline for future implementation work.

This is not yet a frozen standard. Sections marked as open questions identify
areas that still require explicit design decisions before the protocol can be
treated as stable.

Important implementation note: the current repository still contains
transitional `BCS`-based and raw-signature code paths. This document is the
normative target format going forward: shared object serialization is
`deterministic CBOR`, signatures use `COSE_Sign1`, and type definitions in the
documentation use `CDDL`.

## 2. Design Goals

DDM is designed around the following core goals:

1. End-to-end encrypted messaging by default.
2. Strong transport independence.
3. Fully asynchronous delivery.
4. Operation across unstable, delayed, or offline networks.
5. Anonymous or partially anonymous participation, depending on address mode.
6. Spam resistance through proof of work.
7. Ability to function both over interactive networks and over slow
   store-and-forward channels.

The protocol MUST NOT assume low-latency bidirectional connectivity. Delivery
over `libp2p`, direct file transfer, removable media, local synchronization, or
other replication channels is expected.

## 3. Core Model

### 3.1 Message Flow

DDM uses a store-and-forward model.

A sender creates an encrypted message object, attaches a proof of work, assigns
the object to a stream, and publishes it through any available transport.
Recipients obtain objects by synchronizing the stream ranges they currently
choose to consume.

The baseline protocol assumes that:

1. message publication is asynchronous;
2. delivery confirmation may be delayed or absent;
3. clients can operate with partial network visibility;
4. no single transport is required for correctness.

### 3.2 Encryption and Identity

The current design uses two distinct cryptographic roles:

1. `Ed25519` for identity and signatures;
2. `X25519` for key exchange and encrypted payload delivery.

The product direction also states that a user address is based on an
`Ed25519` public key. Therefore, the protocol SHOULD treat identity and payload
encryption as separate but linked concerns.

At this stage, the specification assumes:

1. every account has a stable signing identity;
2. recipient-side `X25519` key material is deterministically derived from the
   account `Ed25519` key material;
3. every encrypted message is addressed to recipient-side decryption material;
4. signatures are encoded as `COSE_Sign1` objects using `EdDSA` with
   `Ed25519`;
5. the exact binary details of the `Ed25519` to `X25519` derivation procedure
   are still to be finalized.

TODO: migrate encrypted payload delivery from `X25519` to `mlkem768x25519`
after that recipient type is finalized in `age`.

### 3.3 Address Model

An address is a versioned binary structure.

The current agreed direction is:

1. the address is serialized with deterministic `CBOR`;
2. in version `176`, the core identity material is the `Ed25519` public key
   encoded in 32 bytes;
3. the address structure also carries an address-level policy byte that
   indicates whether ACK-based retry behavior is expected.

This means the address is not just a naked public key value. It is a protocol
object with a stable binary schema and address-level behavior bits.

For human-facing representation, DDM uses lowercase
`base32` encoding without padding over a compact display-only byte layout.
There is no textual prefix. This display layout is not the protocol CBOR
address serialization.

The current `CDDL` definition is:

```cddl
u8 = 0..255
pubkey32 = bytes .size 32
address-policy = u8

address-v1 = [
  version: 176,
  policy: address-policy,
  ed25519-pubkey: pubkey32
]
```

The current assumption is that `address-policy` is a single byte. Only
one capability is currently defined:

1. `ack-expected`: if set, senders MAY use ACK-based retry logic for this
   address.

All other bits are reserved for future use and MUST be zero in newly generated
version `176` addresses unless and until the specification defines them.

Because `X25519` recipient material is derived from `Ed25519`, the version `176`
address does not need to carry a separate `X25519` public key.

The display-only address byte layout is:

```text
version: 1 byte, value 176
policy: 1 byte
ed25519-pubkey: 32 bytes
checksum: 1 byte
```

The display checksum is computed over the first 34 bytes:

```text
s = len(data)
for each byte b in data:
  s = rol8(s, 1)
  s = (s + b) mod 256
checksum = s
```

## 4. Global Configuration

Global configuration is a versioned signed record:

```cddl
u64 = 0..18446744073709551615
i64 = -9223372036854775808..9223372036854775807

cose-headers = { * int => any }

cose-sign1 = #6.18([
  protected: bstr .cbor cose-headers,
  unprotected: cose-headers,
  payload: bstr,
  signature: bstr
])

config-record = config-record-v1

config-record-v1 = [
  version: 1,
  signed-payload: cose-sign1
]

config-record-v1-payload = [
  seqno: u64,
  active-from-unix: i64,
  pow-base-target: u64,
  pow-scale-divisor: u64,
  pow-modulus: bstr .size 128
]
```

Each record is self-describing by `version`. The `COSE_Sign1.payload` of
`config-record-v1.signed-payload` MUST be the deterministic `CBOR` encoding of
`config-record-v1-payload`.

### 4.1 Record Version 1

Record version `1` payload contains:

1. `seqno: u64` (monotonic freshness value);
2. `active_from_unix: i64` (UTC activation time);
3. `pow_base_target: u64`;
4. `pow_scale_divisor: u64`;
5. `pow_modulus: bstr .size 128`.

The `COSE_Sign1` profile for the current protocol is:

1. the protected header MUST contain `alg = EdDSA` (`1: -8`);
2. the payload MUST be embedded, not detached;
3. the unprotected header SHOULD be empty unless a later profile adds specific
   fields;
4. the verification key is a developer-controlled hardcoded admin public key.

### 4.2 Activation Rules

Config records represent full snapshots, not patches. A source may return more
than one record. At evaluation time `t`, the active record is selected as:

1. records with `active_from_unix <= t`;
2. the record with the largest `seqno` among them.

If no record is active yet, clients use a built-in signed default record.

### 4.3 Decentralized Distribution

Global config is distributed in the same decentralized store-and-forward model
as ordinary messages. There is no central mandatory config endpoint.

Config records are replicated together with message sync payloads across the
same transports (online relays, peer sync, offline file transfer, removable
media, and equivalent channels). This lets clients receive future config
updates even in delay-tolerant or intermittently connected environments.

### 4.4 Unknown Version Handling

If a client encounters an unknown config record version, it MUST NOT apply that
record and MUST present a persistent upgrade prompt to the user.

## 5. Streams and Sharding

### 5.1 Purpose

DDM does not assume that every participant can ingest all network traffic.
Instead, message distribution is partitioned into streams.

### 5.2 Stream Assignment

Each message belongs to exactly one stream.

The stream is derived from a prefix of a hash of the full address structure.
This means stream selection is based on the serialized address object, including
its versioned format, rather than on a standalone raw public key.

The current design direction is:

1. stream ID = first 32 bits of `SHA-256(serialized-address)`;
2. stream derivation includes the full serialized address bytes, including
   version and policy.


### 5.4 Client Sync Strategy

A client chooses which stream range to synchronize based on:

1. available bandwidth;
2. available storage;
3. current transport;
4. local privacy strategy;
5. observed stream density.

A client MAY synchronize:

1. all streams;
2. only the stream(s) that directly correspond to its address set;
3. an expanded subset for privacy or cover traffic;
4. a rotating random subset for verification or anonymity.

## 6. Proof of Work

### 6.1 Purpose

Proof of work is used to raise the cost of unsolicited bulk traffic and reduce
network abuse.

### 6.2 Current Direction

The current protocol uses a Wesolowski RSA-group VDF.

The protocol MUST support algorithm agility:

1. the active algorithm identifier MUST be part of global configuration;
2. difficulty parameters MUST be globally publishable;
3. nodes MUST be able to reject obsolete or unknown proof-of-work regimes.

In version 1, the active algorithm is `VDF RSA` (algorithm id `1`), and the
network-wide RSA modulus is distributed in signed global config as
`pow_modulus` (exactly 128 bytes).

Unless explicitly overridden by a later revision, all hash references in this
draft use `SHA-256`, including:

1. stream selection from serialized addresses;
2. object-hash references where the object model requires a fixed 32-byte hash.

Proof of work is bound to `SHA-256` of canonical serialized
`encrypted-message-v1` bytes.

### 6.3 Effective Difficulty Model

The current protocol defines an effective difficulty model for message
publication:

1. the globally distributed value is a base proof-of-work target;
2. the sender-side effective target MUST additionally account for message TTL
   from `encrypted-message-v1.ttl`;
3. the sender-side effective target MUST additionally account for payload size;
4. each message MUST include a fixed per-object cost so splitting one logical
   payload across many tiny objects is more expensive than sending fewer larger
   objects.

In other words, for two otherwise equal messages, a larger payload or longer
TTL requires harder proof of work than a smaller payload or shorter-lived
message.

The canonical sender-side difficulty function is:

```text
raw_pow_score(base_difficulty, ttl_seconds, encrypted_message_length_bytes) =
    clamp_i64_max(
        base_difficulty *
        max(ttl_seconds, 3600) *
        (encrypted_message_length_bytes + 1024)
    )

target_difficulty(raw_pow_score, scale_divisor) =
    max(1, raw_pow_score / max(scale_divisor, 1))
```

Where:

1. `ttl_seconds` is the message TTL in whole seconds;
2. `encrypted_message_length_bytes` is the serialized `EncryptedMessage` length
   in bytes;
3. `3600` is the minimum billed TTL (1 hour);
4. `1024` is the fixed per-object byte overhead used to discourage
   fragmentation;
5. `clamp_i64_max` saturates the result to `2^63 - 1` for storage
   compatibility;
6. `scale_divisor` is a globally published integer used to map the legacy score
   into a practical VDF difficulty range.

### 6.4 VDF Envelope

The canonical proof-of-work envelope is:

```cddl
u32 = 0..4294967295
proof-component = bstr .size 128
pow-algorithm = 1

pow-envelope-v1 = [
  version: 1,
  algorithm: pow-algorithm,
  y: proof-component,
  pi: proof-component,
  object: bstr .cbor encrypted-message-v1
]
```

Field interpretation:

1. `version` identifies the proof-of-work envelope format version;
2. `algorithm` identifies the proof-of-work algorithm; the current protocol
   uses RSA VDF;
3. `y` is the VDF output value, left-padded with zeros to 128 bytes;
4. `pi` is the VDF proof value, left-padded with zeros to 128 bytes;
5. `object` is the canonical serialized `EncryptedMessage` bytes.

The shared object that propagates through streams is `pow-envelope-v1`. The
inner `encrypted-message-v1` remains the transport-independent object bound by
proof of work and consumed by higher protocol layers after proof verification
succeeds.

### 6.5 VDF Validation

Proof of work is validated as follows:

1. decode `pow-envelope-v1`;
2. require `algorithm = 1` (`VDF RSA`);
3. require `object` to decode as a valid `encrypted-message-v1`;
4. recompute the required difficulty from the configured `base_difficulty`,
   configured `scale_divisor`, decoded `ttl`, and serialized
   `encrypted-message-v1` length;
5. compute `pow_input = sha256(deterministic-cbor(encrypted-message-v1))`;
6. verify the VDF proof using `pow_modulus`, `pow_input`, `difficulty`, `y`,
   and `pi`;
7. accept the envelope only if VDF verification succeeds.

## 7. Shared Objects

All shared protocol objects use deterministic `CBOR` as their canonical binary
encoding.

All type definitions in the DDM documentation use `CDDL`.

The following serialization rules are normative:

1. canonical bytes are the deterministic `CBOR` bytes defined by the relevant
   `CDDL` type;
2. integer values MUST be encoded in deterministic shortest-form `CBOR`;
3. DDM-native protocol objects SHOULD be encoded as `CBOR` arrays; standardized
   structures such as `COSE_Sign1` MUST keep their RFC-defined tagged forms;
4. when one object embeds another serialized object, the field is carried as a
   `bstr` containing the embedded object's deterministic `CBOR` bytes;
5. `COSE_Sign1` objects in DDM MUST use tag `18` and MUST carry an embedded
   payload rather than a detached payload unless a later profile states
   otherwise;
6. the canonical bytes are the bytes hashed for stream assignment and proof of
   work, and the bytes carried when one object embeds another serialized
   object.

The shared type set is:

```cddl
u8 = 0..255
u32 = 0..4294967295
u64 = 0..18446744073709551615
i64 = -9223372036854775808..9223372036854775807

uuid-bytes = bytes .size 16
hash32 = bytes .size 32
pubkey32 = bytes .size 32
secret16 = bytes .size 16

address-policy = u8
pow-algorithm = 1

message-type = 0 / 1 / 2 / 3

cose-headers = { * int => any }

cose-sign1 = #6.18([
  protected: bstr .cbor cose-headers,
  unprotected: cose-headers,
  payload: bstr,
  signature: bstr
])

address-v1 = [
  version: 176,
  policy: address-policy,
  ed25519-pubkey: pubkey32
]

config-record = config-record-v1
config-record-v1 = [
  version: 1,
  signed-payload: cose-sign1
]

config-record-v1-payload = [
  seqno: u64,
  active-from-unix: i64,
  pow-base-target: u64,
  pow-scale-divisor: u64,
  pow-modulus: bstr .size 128
]

pow-envelope-v1 = [
  version: 1,
  algorithm: pow-algorithm,
  y: bstr .size 128,
  pi: bstr .size 128,
  object: bstr .cbor encrypted-message-v1
]

encrypted-message-v1 = [
  version: 1,
  ttl: u32,
  expires-time: u64,
  stream-number: u32,
  payload: bstr
]

unencrypted-message-v1 = [
  magic: u32,
  version: 1,
  signed-body: cose-sign1
]

message-body-v1 = [
  message-id: uuid-bytes,
  sender: address-v1,
  message-type: message-type,
  message: bstr,
  ack-data: bstr
]

ack-message-data = [
  acked-message-id: uuid-bytes
]
```

### 7.1 Encrypted Message Object

Field interpretation for `encrypted-message-v1`:

1. `version` identifies the object format version;
2. `ttl` is the sender-selected TTL in whole seconds used for PoW difficulty;
3. `expires_time` is the absolute end-of-life of the object;
4. `stream_number` is the stream in which the object propagates;
5. `payload` is a binary `age` message for one recipient, addressed to the
   recipient-side `X25519` material derived from the destination address.

### 7.2 Decrypted Message Payload

Field interpretation for `unencrypted-message-v1` and `message-body-v1`:

1. `magic` identifies the internal payload format;
2. `version` identifies the decrypted payload envelope format revision;
3. `signed_body` is a `COSE_Sign1` object whose payload MUST be the
   deterministic `CBOR` encoding of `message-body-v1`;
4. `message_id` is a sender-generated UUID that identifies the message for ACK
   and local deduplication;
5. `sender` carries the full sender address object encoded as `address-v1`;
6. `message_type` identifies the logical payload type and content encoding;
7. `message` carries the payload bytes; for `message_type = 3` (`Ack`) it MUST
   contain the deterministic `CBOR` encoding of `ack-message-data`;
8. `ack_data` carries a precomputed acknowledgment message encoded as a full
   serialized `encrypted-message-v1`; if `message_type = 3` (`Ack`),
   `ack_data` MUST be empty.

The `COSE_Sign1` profile for `signed_body` is:

1. the protected header MUST contain `alg = EdDSA` (`1: -8`);
2. the payload MUST be embedded, not detached;
3. the sender verification key is `message-body-v1.sender.ed25519-pubkey`;
4. unprotected headers SHOULD be empty unless a later profile adds specific
   fields.

Payload size limit:

1. `len(message)` MUST be at most `640 KiB` (`655,360` bytes);
2. senders MUST reject payloads above this limit;
3. receivers MAY reject oversized payloads during validation.

The current implementation-facing interpretation is that `signed_body` covers
the logical inner message object. Outer transport fields such as object
expiration time or stream number remain part of the enclosing
`encrypted-message-v1` rather than the signed inner payload.

`message_id` is a UUID version 4 value encoded as 16 raw bytes in protocol
objects. Textual UUID rendering is for debugging and user interfaces only.

### 7.3 ACK Message Payload

Field interpretation for `ack-message-data`:

1. `acked_message_id` identifies the delivered message.

The sender precomputes a complete encrypted ACK message addressed back to the
sender and embeds the serialized `encrypted-message-v1` bytes in `ack_data`.
The recipient MAY republish that byte sequence as-is after successful
decryption.

The embedded ACK message uses the ordinary `encrypted-message-v1` container.
Its decrypted payload MUST set `message_type = 3` (`Ack`), MUST carry a
serialized `ack-message-data` in `message`, and MUST leave `ack_data` empty.

This makes ACK traffic externally indistinguishable from ordinary encrypted
messages at the shared-object level.

## 8. Message Types

The initial content plan supports multiple logical message types.

The current enum is:

```cddl
message-type = 0 / 1 / 2 / 3
```

Interpretation:

1. `0`: `Plain`, UTF-8 plain-text message without additional structure;
2. `1`: `Markdown`, UTF-8 structured markdown;
3. `2`: `Binary`, extended encoding for richer message formats;
4. `3`: `Ack`, deterministic `CBOR` encoding of `ack-message-data`.

The first structured UTF-8 format is markdown-based and uses a single required
subject header at the start of the document:

```text
Subject text
============

Regular Markdown body starts here.
```

The first line is the message subject. The second line is a Setext level-1
underline made of `=` characters. After the first blank line, the remainder of
the payload is an ordinary UTF-8 Markdown document. No other headers are
required by the protocol.

The protocol SHOULD later support a binary structured encoding for richer
payloads such as attachments and media.

## 9. Delivery and Acknowledgment

### 9.1 ACK Relay

The second delivery signal is an explicit acknowledgment path.

Current intended model:

1. the sender precomputes a complete encrypted ACK message addressed back to
   the sender;
2. the precomputed ACK message is included inside the encrypted message as
   `ack_data`;
3. the recipient MAY republish that ACK message as-is after successful
   delivery;
4. when the sender observes a valid ACK whose `acked_message_id` matches the
   original message, the sender stops retrying the message.

This avoids requiring the recipient to construct an ACK interactively after
decryption.

The protocol defines ACK targeting by `message_id`.

An ACK is valid only if the ACK sender identity matches the original
destination address of the acknowledged message. A sender MUST ignore ACKs that
match `acked_message_id` but come from any other sender identity.

### 9.2 Address-Level ACK Policy

The current design direction defines ACK behavior as an address property.

Examples:

1. fully anonymous addresses may opt out of ACK expectations;
2. retry-capable addresses may advertise that ACK-based retries should be used;
3. a single device MAY derive multiple addresses from the same root key
   material, with different privacy and acknowledgment policies.

In version `176` addresses, `ack-expected` is encoded as bit 0 of the policy
byte. Bits 1 through 7 are reserved and MUST be zero.

### 9.3 Retries

The protocol only defines the conditions under which retries are relevant:

1. the address policy indicates `ack-expected`;
2. no valid ACK for the `message_id` has been observed;
3. the message has not exceeded local retry limits.

The default retry schedule, TTL growth policy, and proof-of-work escalation
policy are client-behavior defaults, not wire-level protocol rules. The current
recommended default profile is defined in `docs/client-behavior.md`.

For wire-level identity, a retry is a republished copy of the same logical
message. A sender retrying a message:

1. MUST reuse the same serialized `unencrypted-message-v1` bytes, including
   `message_id`, signed `message-body-v1`, and `ack_data`;
2. MAY change outer publication properties such as proof-of-work data and
   `expires_time`;
3. MUST create a new `message_id` if the logical payload changes.

### 9.4 Anti-Replay and Deduplication

DDM distinguishes between transport-level replay and logical-message replay.

Transport-level replay means the same serialized `encrypted-message-v1` bytes
are republished through one or more transports. This is allowed. Nodes MAY
dedupe such objects locally by the canonical serialized `encrypted-message-v1`
bytes or by their hash, but identical republishing is not a protocol
violation.

Logical-message replay is handled after decryption:

1. the deduplication key for an ordinary message is
   `(canonical serialized sender address, message_id)`;
2. the first successfully verified payload for that key is the canonical
   logical message instance;
3. if a later decrypted payload presents the same deduplication key but
   different serialized `unencrypted-message-v1` bytes, the later payload MUST
   be treated as a conflicting replay and MUST NOT be surfaced as a new
   message;
4. a recipient MUST NOT emit more than one ACK for the same logical message;
5. `message_id` uniqueness is scoped to the sender identity, not globally
   across the network.

ACKs use a separate deduplication rule:

1. the deduplication key for an ACK is
   `(canonical serialized sender address, acked_message_id)`;
2. the original sender MUST accept at most one valid ACK for that key and only
   when that sender identity matches the original destination address;
3. later matching ACKs MAY be ignored once retry state has been resolved.

## 10. Privacy Measures

### 10.1 Cover Traffic

The protocol allows cover traffic but does not require a fixed network-wide
cover-traffic rate.

Ordinary nodes MAY generate messages to invalid or unknown addresses in order
to create background network noise and reduce traffic analysis accuracy.

Mobile clients MAY participate in cover traffic only under suitable operating
conditions, such as:

1. connected to unmetered Wi-Fi;
2. charging;
3. allowed by device background-execution policy.

Recommended default cover-traffic profiles are client behavior and are defined
in `docs/client-behavior.md`.

### 10.2 Partial Sync for Privacy

A client SHOULD be allowed to synchronize additional streams beyond its
directly relevant stream set in order to reduce the correlation between local
interest and observed network requests.

## 11. Network Statistics and Sampling

Clients need a way to estimate stream load before deciding what to synchronize.

DDM does not define a single protocol-wide wire format for source statistics.
Instead, sync-range selection is based on:

1. local node policy;
2. statistics advertised or readable from one or more message sources;
3. the concrete protocol or storage format used to communicate with that
   source.

A source may be an interactive peer, a local replica, an exported database
file, removable media, or another transport-specific object store.

The shared concept is that a source SHOULD expose enough range-level density
information for a client to choose what to synchronize without ingesting the
entire source first. The conceptual source model is documented in
`docs/source-statistics-concept.md`.

Concrete request and response formats, snapshot handling, and verification
procedures belong in transport-specific or format-specific sub-documents rather
than in the main protocol specification.

## 12. Transport Independence

The protocol MUST remain independent from any single transport.

Expected transport classes include:

1. `libp2p` online exchange;
2. direct file export/import;
3. synchronization between local devices;
4. removable-media transfer;
5. short-range wireless transfer such as Bluetooth.

A transport MAY optimize discovery, batching, or replication, but it MUST NOT
change the logical message, stream, proof-of-work, or acknowledgment semantics.

## 13. Current Non-Goals

The following items are intentionally not fixed in this specification:

1. exact attachment format;
2. future perfect forward secrecy strategy.

## 14. Remaining Open Questions

No additional protocol-level open questions are currently tracked in this
document.

## 15. Next Specification Steps

The recommended next steps are:

1. migrate the Go and Dart implementations from transitional `BCS` encoders to
   deterministic `CBOR`;
2. replace raw signature handling with `COSE_Sign1` verification and emission;
3. define attachment formats;
4. define future perfect forward secrecy strategy.
