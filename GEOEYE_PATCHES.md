# GEOEYE BLE fork

Date:2026-11-07. Branch:codex/geoeye-owned-writes-v2. Based on upstream universal_ble2.1.0 at23d4b9566c26665970a1f4a0e8cb1048ba9e554b; all239 release-file hashes matched before patching. UPSTREAM.json preserves those hashes and LICENSE/attribution remain. Package version stays2.1.0; consumers distinguish this fork by Git URL and immutable commit. Main3.x is a separate upgrade.

- UniversalBle.writeOwned uses the existing command queue; canDispatch is checked inside the queue immediately before native invocation. The owned Future has no queue timeout and retains original platform IO. Caller owns immutable payloads. Legacy writes/timeouts are unchanged.
- disconnect(...,bypassWriteQueue:true) reaches physical cleanup while data IO is stalled; default disconnect still queues. No global clearQueue/QueueType.none/timeout disabling.
- Android GattWriteLedger allows one pending write per GATT identity, validates characteristic identity and resolves once on actual callback/failure/cleanup. Superseded GATT callbacks cannot clear another GATT write; state handling is posted to main after connectGatt registration.
- Darwin uses a main-queue-owned ledger per peripheral. With-response matches actual peripheral/characteristic completion. Legacy without-response waits for readiness; local acceptance is not a receiver ACK. Owned iOS no-response uses additive geoeye/universal_ble_owned MethodChannel, rejects not-ready immediately, and never retains old payload across readiness events. Disconnect/radio loss/reconnect revoke captured pending ownership. Mode-specific maximum length is validated; PigeonError becomes FlutterError at the channel boundary. Generated Pigeon remains unchanged.

GEOEYE injects optional owned-write/close delegates from app composition; portable core does not reference fork-only APIs directly. Android delegate is active; iOS generic delegate is beta-gated. Model protocols, source-age policy and decoder recovery belong to the application, not this plugin.

Validation: run flutter test and flutter analyze. Native ledger tests live in android/src/test and test/native. The application tools/ble runners compile the Android ledger and, when swiftc is available, Foundation/shim Darwin tests. Dart/host checks do not prove CoreBluetooth API compatibility, actual callback ordering, physical receiver processing or decoder reset. Xcode/Apple device acceptance remains open.

Updating upstream: preserve this branch, inspect upstream changes against UPSTREAM.json/base, port the small owned-write changes to a new branch and rerun Dart/native/application checks before repinning. Never replace the tested pin with a moving branch or edit Pub cache. Rollback plugin pin and app delegates together.
