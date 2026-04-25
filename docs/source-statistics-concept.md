# DDM Sync Source Concept

This document defines the baseline transport-independent sync source concept.

The baseline model has one source and one receiver. It is intentionally a
concept note, not a wire-format specification.

## Core Idea

A source is any object that can provide:

1. the current and future config timeline;
2. messages by ID, where "message" means the encrypted transferable object
   currently called a sync blob;
3. enough index metadata for a client to decide what to synchronize next.

A source may be an interactive node, a local replica, an exported database
file, removable media, or another transport-specific object store.

## Required Source Operations

The baseline source contract matches the Go `proto.Source` interface and has
four operations:

```go
type Source interface {
    GetConfigs(ctx context.Context) ([]ConfigRecord, error)
    GetSyncBlobs(ctx context.Context, ids []SyncBlobID) ([]SyncBlobLookupResult, error)
    GetMessageIndexRoot(ctx context.Context) (*MessageIndexNode, error)
    GetMessageIndexNode(ctx context.Context, id MessageIndexNodeID) (*MessageIndexNode, error)
}
```

Semantics:

1. `GetConfigs` returns the full config timeline that is active now or
   may become active in the future, ordered by ascending `seqno`.
2. `GetSyncBlobs` returns blobs for a batch of blob IDs, preserving request
   order, duplicate requests, and explicit misses.
3. `GetMessageIndexRoot` returns the current message-index tree root.
4. `GetMessageIndexNode` returns one message-index node by explicit structural
   node ID.

Returned config remains untrusted until signature and metadata validation
succeeds.

## Core Types

`ConfigRecord`
: A versioned opaque config record. The source returns raw records and the
  receiver validates signatures, activation metadata, and version-specific
  payload rules.

`SyncBlobID`
: A typed sync-blob identifier in canonical binary form. The current Go
  implementation uses 36 bytes.

`SyncBlob`
: An encrypted transferable synchronization object with two fields:
  `ID SyncBlobID` and `Payload []byte`.

`SyncBlobLookupResult`
: A result item that preserves request-to-result alignment for
  `LoadSyncBlobs`. It contains the requested `ID` and either a populated
  `Blob` or `Blob == nil` for an explicit miss.

`NibblePath`
: A canonical lowercase hexadecimal nibble string in `[0-9a-f]`. It is used
  as the logical key space for the message index.

`MessageIndexNodeID`
: A structural message-index node reference hash. The current Go
  implementation uses a canonical SHA-256-based 32-byte identifier.

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

DDM does not define one universal sync-source wire format.

Transport-specific documents may choose their own:

1. request and response encoding;
2. snapshot identity format;
3. proof, hash, or diff scheme;
4. follow-up query flow.

The shared requirement is only the conceptual source model and the baseline
operations above.
