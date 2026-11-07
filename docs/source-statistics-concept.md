# DDM Sync Source Concept

This document defines a transport-independent sync source model with one source
and one receiver.

See [Global Message Tree](message-tree.md) for snapshot lifetime, bidirectional
reconciliation, shard coverage, and verification requirements.

## Core Idea

A source is any object that can provide:

1. the retained config timeline;
2. messages by ID, where "message" means the encrypted transferable object
   called a sync blob;
3. enough index metadata for a client to decide what to synchronize next.

A source may be an interactive node, a local replica, an exported database
file, removable media, or another transport-specific object store.

## Required Source Operations

The source contract exposes these operations:

```
GetConfigs() []ConfigRecord
GetSyncBlobs(ids []SyncBlobID) []SyncBlob
GetMessageIndexRoot() MessageIndexNode
GetMessageIndexNode(id MessageIndexNodeID) MessageIndexNode
Push(blob SyncBlob)
GetSyncState() { root MessageIndexNode?, coverage []StreamPrefix }

```

Semantics:

1. `GetConfigs` returns retained historical, active, and future config records,
   ordered by ascending `seqno`. Historical records validate live publications
   generated under earlier configurations.
2. `GetSyncBlobs` returns blobs for a batch of blob IDs, preserving request
   order, duplicate requests, and explicit misses.
3. `GetMessageIndexRoot` returns the current message-index tree root.
4. `GetMessageIndexNode` returns one message-index node by explicit structural
   node ID.
5. `Push` transfers a blob. The sender validates blobs before export; receiving
   nodes validate blobs before insertion. Fixed-store adapters persist validated
   exports.
6. `GetSyncState` returns a root snapshot and maintained ranges. An empty
   coverage list serves no range; the prefix `""` covers every stream. A covered
   range without leaves is empty. Missing snapshot nodes are unavailable.

Returned config remains untrusted until signature and metadata validation
succeeds.

## Core Types

`ConfigRecord`
: A versioned opaque config record. The source returns raw records and the
  receiver validates signatures, activation metadata, and version-specific
  payload rules.

`SyncBlobID`
: A 36-byte typed sync-blob identifier in canonical binary form.

`SyncBlob`
: An encrypted transferable synchronization object with two fields:
  `ID SyncBlobID` and `Payload []byte`.

`GetSyncBlobs` result
: A slice aligned with the requested IDs. Each entry is either a populated
  `*SyncBlob` or `nil` for an explicit miss. A returned blob carries its own
  `ID`; callers validate that it matches the requested ID at the same index.

`NibblePath`
: A canonical lowercase hexadecimal nibble string in `[0-9a-f]`. It is used
  as the logical key space for the message index.

`MessageIndexNodeID`
: A 32-byte SHA-256 structural message-index node reference hash.

## Message Index

The message index is a copy-on-write augmented nibble tree with explicit node
addressing.

- keys are canonical lowercase hexadecimal nibble strings;
- node IDs use one canonical serialized form;
- node payloads use a tagged union with one of two variants:
  `MessageIndexBranch` or `MessageIndexLeaf`.

The conceptual wire shape is:

```cddl
MessageIndexNode = #6.40000(MessageIndexBranch) / #6.40001(MessageIndexLeaf)
```

`MessageIndexLeaf`
: A terminal node payload with `SyncBlobID` and `TTL`.

`MessageIndexBranch`
: A branch node payload with:
  `Prefix`, `ChildrenCount`, `MinTTL`, `MaxTTL`, and
  `ChildrenIDs [16]*MessageIndexNodeID`.

Branch semantics:

1. `Prefix` is the shared nibble prefix covered by the branch.
2. `ChildrenCount` is the total number of leaf descendants reachable through
   the branch.
3. `MinTTL` and `MaxTTL` summarize the TTL range across all descendants.
4. `ChildrenIDs` is a fixed 16-slot table indexed by the next hexadecimal
   nibble.

The purpose of the index is simple: let a client estimate density and choose a
prefix or range to synchronize without reading every message first.

## Boundary

Transport-specific documents define:

1. request and response encoding;
2. snapshot identity format;
3. proof packaging and diff request flow consistent with shared tree semantics;
4. follow-up query flow.

The shared requirement is only the source model and the
operations above.

## Coverage and Routing Wire Format

HTTP `GET /state` returns `{"root": <node or null>, "coverage": [<prefix>, ...]}`.
P2P RPC method `7` returns the same state in the `Node` and `Coverage` fields.
The CBOR response tuple is `[Status, Error, Peers, Configs, Blobs, Node, Coverage]`;
unused fields are null. Coverage contains at most 256 lowercase hexadecimal
prefixes of up to eight nibbles. Normalize duplicate and nested ranges before
computing intersections.

P2P providers advertise every maintained prefix using namespace
`hex(SHA256(UTF8("ddm/shard/" + prefix)))`. Its provider key is a CIDv1 raw block
with SHA-256 of the UTF-8 namespace. Lookup queries every ancestor prefix of
the destination stream, including `""` and the full eight-nibble stream. A
fresh state response determines whether a discovered peer still serves that
stream; provider records can outlive coverage changes.
