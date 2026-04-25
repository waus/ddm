# Client TODO

This checklist focuses on the baseline client features required to deliver a
usable DDM Flutter application on top of the Dart core.

## 1. App Foundation

- [x] Create the Flutter app entry point and base app shell.
- [x] Set up app routing, screen structure, and navigation state.
- [ ] Add configuration for environments, logging, and crash-safe startup.
- [x] Add a minimal design system: theme, spacing, typography, buttons, forms,
      lists, and status indicators.

## 2. Local Identity and Profile

- [ ] Implement first-run onboarding.
- [x] Create a local account/profile.
- [ ] ? Generate, import, export, and persist identity keys safely.
- [x] Show the local user address in shareable form.
- [ ] ? Add backup and recovery UX for keys and local profile data.

## 3. Local Storage

- [x] Define the local database schema for accounts, contacts, messages,
      deliveries, config snapshots, and app settings.
- [ ] Add migrations and version handling for local storage.
- [x] Add repositories/services for client-side reads and writes.

## 4. Contacts and Address Book

- [ ] Add contact creation, editing, deletion, and local notes.
- [ ] Expose address policy flags such as `ack-expected`.
- [x] Add QR/share flows for exchanging addresses.

## 5. Messaging UX

- [x] Build the chat list / conversation list screen.
- [x] Build the conversation screen.
- [x] Build the compose flow for a new message.
- [x] Support text messages as the first message type.
- [ ] Show message states: created, in-delivering, acknowledged, expired, delivered, received.

## 6. Message Submission and Outbox

- [x] Connect message composition to the Dart core submission pipeline.
- [ ] Persist draft messages locally.
- [ ] Implement an outbox queue visible to the user.

## 7. Receive Path and Inbox

- [x] Sync encrypted objects from the selected transport/source.
- [x] Decrypt, validate, and store inbound messages.
- [x] Build an inbox update flow that safely reacts to newly received data.
- [x] Publish ACK objects when required by address policy.

## 8. Retry, TTL, and Delivery Policy

- [ ] Implement the default ACK-based retry profile from
      `docs/client-behavior.md`.
- [x] Apply TTL jitter to default and explicit TTL values.
- [ ] Stop retries immediately after a valid ACK is observed.
- [ ] Expose delivery policy details in settings and debug views.

## 9. Sync and Transport

- [x] Define the client sync coordinator on top of `ddm_proto_dart`.
- [x] Support online synchronization when network transport is available.
- [ ] Support offline import/export flows for sync packages or files.
- [ ] Track per-stream sync state and last successful progress.
- [ ] Add source registration controls and background sync policy hooks.

## 10. Global Configuration

- [ ] Fetch, validate, persist, and activate signed global config snapshots.
- [ ] Show the currently active config version and activation time.
- [ ] Handle unknown config record versions with a persistent upgrade prompt.
- [ ] Apply config-driven PoW and protocol parameters consistently.

## 11. Privacy and Security UX

- [x] Allow creating silent accounts without ACK reply.

## 12. Settings and Diagnostics

- [ ] Create settings screens for network and developer options.
- [x] Add a sync status screen with recent activity and current errors.
- [ ] Add developer/debug screens for config, streams, queue state, and local
      database inspection.

## 13. Testing and Release Readiness

- [ ] Add unit tests for client-side state and delivery policy logic.
- [ ] Add widget tests for onboarding and message flow.
