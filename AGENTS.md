# GEOEYE universal_ble fork

Last updated: 2026-11-07.

- This branch preserves upstream2.1.0; UPSTREAM.json records the exact Git base and original239 file hashes. Preserve LICENSE, attribution and generated Pigeon contracts.
- Keep legacy public APIs, queue defaults and write/disconnect timeout behavior. Owned APIs reuse the existing queue, validate canDispatch immediately before native invocation and retain the original platform Future. No fabricated receiver ACK, native cancellation or byte counts.
- Explicit physical disconnect alone bypasses the stalled data queue. Never globally clear/disable queues or timeouts.
- Android writes bind GATT plus characteristic identity and clean up exactly once. Darwin ownership remains on the central main queue; readiness is flow control, not delivery ACK. Owned no-response writes reject not-ready without retaining payload for later replay.
- Run flutter test and flutter analyze. Keep native ledger/channel host tests; Apple SDK/Xcode/device acceptance remains separate from Linux Dart/Android checks.
- Follow review-implementation after each accepted change. Update GEOEYE_PATCHES.md and CHANGELOG.md when changing fork behavior. No cache edits or weakening upstream tests.
