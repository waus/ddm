# Global Message Tree

## One Logical Tree, Many Partial Replicas

All live transferable messages (sync blobs) form one logical Merkle tree. Each
node maintains its own partial, possibly stale view and continuously reconciles
it with other nodes. There is no authoritative global root, message ordering,
or consensus round. Equal roots mean equal indexed sets within the same scope
and tree version; delivery does not require network-wide equality.

The tree indexes encrypted publications by blob ID. Retries with different blob
IDs are separate leaves. Expired blobs leave the live tree. Historical
snapshots are retained for a bounded period.

## Structure and Storage

The index is a compressed 16-way nibble tree. Its key is the
hexadecimal sync-blob ID: a big-endian 32-bit stream number followed by the
SHA-256 hash of the transferable blob bytes. Stream prefixes therefore select
contiguous subtrees; prefixes beyond eight nibbles subdivide a single stream.

| Node | Contents |
| --- | --- |
| Leaf | Blob ID and absolute expiry (`TTL`). |
| Branch | Shared prefix, 16 child references, descendant leaf count, minimum and maximum expiry. |

Counts describe all descendant leaves. A leaf counts as one. The `TTL`,
`MinTTL`, and `MaxTTL` fields hold absolute expiry as `uint32` Unix seconds.
Tree shape MUST be deterministic for the same set, independent of arrival
order; empty trees and compressed branches need canonical representations.

A leaf hashes its blob ID; a branch hashes the concatenation of non-empty child
IDs in slot order, using SHA-256. Prefixes, empty slot positions, counts, and
expiry summaries are not directly hashed. A matching node hash MUST NOT be
treated as validation of these metadata.

Metadata MUST be checked against descendants: counts sum child leaf counts,
expiry bounds equal child minima and maxima, and descendant keys match the
branch prefix and child slots. At leaves, expiry MUST match the validated blob,
whose bytes are committed by its ID. Checking one level establishes only local
consistency; unchecked descendant summaries remain untrusted, and sampling
provides only probabilistic evidence about the full subtree.

The tree is independent of the storage engine and can be represented in a KV
store:

```text
node hash -> immutable index node
blob ID   -> transferable blob bytes
roots     -> current root and retained historical roots
```

When returning a root, the node MUST have access to all index nodes and blobs
in that snapshot. Garbage collection may remove them later.

## Snapshots and Garbage Collection

Reading a root selects a snapshot. All subsequent requests follow hashes from
that root. Insertions and removals change hashes along the affected path to the
root; unaffected subtrees keep their hashes.

```text
old root R0 -> old branch A0 -> existing leaves
           \-> branch B
new root R1 -> new branch A1 -> existing leaves + new leaf
           \-> branch B                 (shared)
```

A serving node retains recent roots and their reachable index nodes and blobs
for a bounded period so peers can continue traversing earlier snapshots.

The default retention period is ten minutes. Retention is best-effort. If a
requested snapshot node has been collected, return `not found`; the receiver
reads the latest root and restarts. Snapshot loss is handled as an availability
event.

The protocol assumes accurate clocks, with no clock-skew allowance. An expired
blob MUST NOT be imported, even when it belongs to a retained snapshot.

## Synchronization and Sharding

![Two peers compare trees and exchange missing blobs](assets/tree-sync.svg)

1. Exchange offered prefixes, requested prefixes, and roots for the advertised
   coverage. Distinguish a covered empty range from a range the peer does not
   serve. Coverage claims describe local availability.
2. Select intersections: pull where local requests overlap remote offers; push
   where remote requests overlap local offers. No overlap means no message sync.
3. Capture roots and compare matching ranges. Skip equal hashes; recursively
   compare differing branches by prefix, accounting for compressed paths.
4. Fetch remote-only leaves and their blobs; validate before insertion. Offer
   local-only blobs within the peer's requested ranges. Each peer retains its
   valid local blobs when the other peer lacks them.
5. Finish the bounded snapshot walk, then repeat with fresh roots. Concurrent
   publications are handled in later rounds.

Under high load, a node can narrow synchronization to one prefix, or several
prefixes required by its addresses and privacy policy. Descendant counts let it
estimate load before downloading the blobs. Counts alone do not measure byte
size or arrival rate; local storage and bandwidth budgets also constrain scope.
Peers with different coverage compare overlapping subtrees.

Hash-derived stream assignment is expected to spread recipients approximately
uniformly; traffic can still concentrate on a particular recipient. Nodes
participating in a shard synchronize that shard with one another. Progress
requires an available peer holding the missing blobs.

## Checking Untrusted Peers

A node SHOULD sample an advertised tree before using its claimed size to narrow
its scope, especially when that size greatly exceeds local observations. An
inflated count could otherwise force the client to reveal a narrow address
prefix. Sampling must use the captured root and receiver-chosen randomness.

Use the [source-check procedure](client-behavior.md#4-sync-source-check):
choose random leaf ranks weighted by descendant counts; at each visited branch
fetch all direct children, verify hashes and prefix placement, and check that
their counts sum to the parent count. At the selected leaf, fetch the actual
blob and verify its ID, canonical encoding, message hash, expiry, and PoW. The
hash-linked path back to the captured root is the Merkle inclusion proof. The
default is 20 independent samples.

Sampling gives probabilistic evidence about the advertised tree. A
self-consistent root alone proves neither valid PoW nor blob availability.
Invalid proofs, timeouts, expired blobs, and collected snapshots are distinct
outcomes of verification.

## Transport Contract

Transport specifications define offered/requested prefix descriptors, their
snapshot binding, and explicit empty, unserved, and unavailable responses.

See [source operations and types](source-statistics-concept.md). This document
defines shared tree semantics; transport documents define encoding and
batching.
