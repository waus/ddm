# Go v1 Foundation Fixtures

These fixtures are generated from the current Go implementation and are the compatibility baseline for the Dart rewrite.

## Generate

From the repository `go/` directory:

```bash
/Users/user/sdk/go1.25.1/bin/go run ./cmd/gen-golden-fixtures
```

## Scope

This fixture set includes:

- address
- config record
- plaintext message
- encrypted message
- PoW envelope
- sync blob
- message-index leaf and branch
- HTTP sync JSON responses
- P2P RPC frame payloads

## Notes

- See `ddm_proto_dart/docs/foundation-interop.md` for compatibility decisions and quirks.
- `manifest.json` contains SHA-256 checksums for every generated file.
