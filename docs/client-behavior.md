# DDM Client Behavior Defaults

This document defines recommended client defaults. These rules guide sender and
receiver behavior but do not change the wire protocol.

## 1. Retry Profile

The default retry profile applies only when the destination address sets
`ack-expected`.

Recommended sender behavior:

1. publish the initial message with a TTL of 2 days;
2. if no valid ACK arrives, retry once with a TTL of 4 days;
3. if no valid ACK arrives again, retry once with a TTL of 8 days;
4. stop after 3 total publications;
5. stop immediately after observing a valid ACK for the `MessageID`.
6. for each publication, use two independent random additions for the selected
   baseline `X`:
7. write `ttl = X + rand(0..X/10)` into the encrypted message and use this
   exact value for PoW difficulty calculation;
8. write `expires_time = now + X + rand(0..X/20)`.

Clients MAY increase proof-of-work cost on later retries, but the default
profile does not require escalation.

TTL/expiry jitter helps reduce deanonymization risk from deterministic timing
patterns. The same rules SHOULD be applied to explicitly configured and default
TTL values.

## 2. Cover Traffic

Cover traffic is optional. Clients SHOULD treat it as a policy choice driven by
device class, power state, and network conditions.

Recommended defaults:

1. server and desktop clients MAY send low-rate cover traffic;
2. mobile clients SHOULD send cover traffic only while charging and on
   unmetered Wi-Fi;
3. constrained clients MAY disable cover traffic entirely.

Clients SHOULD never block ordinary message delivery because cover traffic is
disabled.

## 3. Global Config Version Handling

Global configuration is distributed as an array of signed records:

```text
struct Record {
  version: u8,
  payload: Vec<u8>,
}
config: Vec<Record>
```

Client behavior requirement:

1. if a config record version is unknown, the client MUST stop applying that
   record;
2. the client MUST show a persistent and explicit upgrade prompt;
3. the prompt SHOULD state that protocol safety may be degraded until the
   client is updated.

## 4. Sync Source Check

The source check is an optional preflight for large remote message-index trees.
It protects a client from a source that advertises a large root only to force the
client into revealing a narrow address prefix during partial synchronization.

The default check uses 20 independent samples. Empty roots are accepted as a
no-op, but clients normally SHOULD skip the check for an empty root.

The client first reads the source root. For each sample, the client:

1. chooses a random integer `rank` in `[0, root.children_count)`;
2. walks the augmented nibble tree by treating `children_count` as subtree
   weights;
3. at each branch, requests all referenced direct children, validates every
   child, verifies every child hash against the referenced child id, verifies
   that each child belongs to its parent slot, and verifies that the sum of
   direct child subtree sizes equals the parent `children_count`;
4. chooses the child whose cumulative subtree range contains `rank`;
5. at a leaf, requests the referenced sync blob and validates its canonical
   encoding, proof of work, id, and expiry;
6. verifies that the leaf TTL equals the blob `expires_time`.

This is an order-statistics walk. Every leaf has equal probability of being
sampled regardless of tree depth. Clients SHOULD fail the check on the first
invalid response. Source availability and request failures MUST remain distinct
from invalid source responses so callers can apply different retry and rating
policies.
