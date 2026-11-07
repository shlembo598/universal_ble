import Foundation

var cases = 0
let failure = NSError(domain: "synthetic", code: 1)
func scenario(_ name: String, _ body: () -> Void) {
  body(); cases += 1; print("PASS \(name)")
}

scenario("first short without-response write completes locally without a ready event") {
  let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
  var sent = [Data](), results = 0
  precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                           mode: .withoutResponse, data: Data([1]), send: { sent.append($0) }, result: {
    precondition((try? $0.get()) != nil); results += 1
  }))
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  precondition(sent == [Data([1])] && results == 1)
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  precondition(sent.count == 1 && results == 1)
}

scenario("saturation waits before dispatch and false-ready does not advance") {
  let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
  var sends = 0, results = 0
  precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                           mode: .withoutResponse, data: Data([2]), send: { _ in sends += 1 }, result: { _ in results += 1 }))
  ledger.pump(peripheral: device, canSendWithoutResponse: false)
  ledger.pump(peripheral: device, canSendWithoutResponse: false)
  precondition(sends == 0 && results == 0)
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  precondition(sends == 1 && results == 1)
}

scenario("with-response ignores no-response readiness but waits for matching ACK") {
  let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
  var sends = 0, results = 0
  precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                           mode: .withResponse, data: Data([3]), send: { _ in sends += 1 }, result: { _ in results += 1 }))
  ledger.pump(peripheral: device, canSendWithoutResponse: false)
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  precondition(sends == 1 && results == 0)
  ledger.acknowledge(peripheral: device, characteristic: NSObject(), result: .success(()))
  precondition(results == 0)
  ledger.acknowledge(peripheral: device, characteristic: characteristic, result: .success(()))
  ledger.acknowledge(peripheral: device, characteristic: characteristic, result: .success(()))
  precondition(results == 1)
}

for mode in [DarwinWriteLedger.Mode.withResponse, .withoutResponse] {
  scenario("busy peripheral rejects another pending write in \(mode)") {
    let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
    precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                             mode: mode, data: Data([1]), send: { _ in }, result: { _ in }))
    precondition(!ledger.admit(deviceId: "a", peripheral: device, characteristic: NSObject(),
                              mode: mode, data: Data([2]), send: { _ in }, result: { _ in preconditionFailure() }))
    ledger.disconnect(deviceId: "a", peripheral: device, error: failure)
  }
  scenario("disconnect clears pending \(mode), no late ready/ACK dispatch") {
    let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
    var sends = 0, failures = 0
    precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                             mode: mode, data: Data([1]), send: { _ in sends += 1 }, result: {
      if case .failure = $0 { failures += 1 } else { preconditionFailure() }
    }))
    if mode == .withResponse { ledger.pump(peripheral: device, canSendWithoutResponse: false) }
    ledger.disconnect(deviceId: "a", peripheral: device, error: failure)
    ledger.pump(peripheral: device, canSendWithoutResponse: true)
    ledger.acknowledge(peripheral: device, characteristic: characteristic, result: .success(()))
    precondition(failures == 1 && sends == (mode == .withResponse ? 1 : 0))
  }
}

scenario("old peripheral callbacks cannot complete a new object on same device ID") {
  let ledger = DarwinWriteLedger(), old = NSObject(), fresh = NSObject(), characteristic = NSObject()
  var oldFailed = 0, freshDone = 0
  precondition(ledger.admit(deviceId: "same", peripheral: old, characteristic: characteristic,
                           mode: .withResponse, data: Data([1]), send: { _ in }, result: { _ in oldFailed += 1 }))
  ledger.pump(peripheral: old, canSendWithoutResponse: true)
  precondition(ledger.admit(deviceId: "same", peripheral: fresh, characteristic: characteristic,
                           mode: .withResponse, data: Data([2]), send: { _ in }, result: { _ in freshDone += 1 }))
  ledger.pump(peripheral: fresh, canSendWithoutResponse: true)
  ledger.disconnect(deviceId: "same", peripheral: old, error: failure)
  ledger.acknowledge(peripheral: old, characteristic: characteristic, result: .success(()))
  precondition(oldFailed == 1 && freshDone == 0)
  ledger.acknowledge(peripheral: fresh, characteristic: characteristic, result: .success(()))
  precondition(freshDone == 1)
}

scenario("registered owner handles synchronous ACK from dispatch") {
  let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
  var results = 0
  precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                           mode: .withResponse, data: Data([1]), send: { _ in
    ledger.acknowledge(peripheral: device, characteristic: characteristic, result: .success(()))
  }, result: { _ in results += 1 }))
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  precondition(results == 1)
}

scenario("disconnect during local dispatch never reports a later local success") {
  let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
  var failures = 0
  precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                           mode: .withoutResponse, data: Data([1]), send: { _ in
    ledger.disconnect(deviceId: "a", peripheral: device, error: failure)
  }, result: { if case .failure = $0 { failures += 1 } else { preconditionFailure() } }))
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  precondition(failures == 1)
}

scenario("radio loss removes both modes before reentrant callback admits a new request") {
  let ledger = DarwinWriteLedger(), first = NSObject(), second = NSObject(), characteristic = NSObject()
  var failures = 0, freshDone = 0
  for (index, device) in [first, second].enumerated() {
    precondition(ledger.admit(deviceId: "\(index)", peripheral: device, characteristic: characteristic,
                             mode: index == 0 ? .withResponse : .withoutResponse,
                             data: Data([1]), send: { _ in }, result: { result in
      if case .failure = result { failures += 1 } else { preconditionFailure() }
      if index == 0 {
        precondition(ledger.admit(deviceId: "fresh", peripheral: first, characteristic: characteristic,
                                 mode: .withoutResponse, data: Data([9]), send: { _ in }, result: { _ in freshDone += 1 }))
      }
    }))
  }
  ledger.unavailable(error: failure)
  precondition(failures == 2 && freshDone == 0)
  ledger.pump(peripheral: first, canSendWithoutResponse: true)
  precondition(freshDone == 1)
}

scenario("ACK without dispatch cannot finish an admitted request") {
  let ledger = DarwinWriteLedger(), device = NSObject(), characteristic = NSObject()
  var results = 0
  precondition(ledger.admit(deviceId: "a", peripheral: device, characteristic: characteristic,
                           mode: .withResponse, data: Data([1]), send: { _ in }, result: { _ in results += 1 }))
  ledger.acknowledge(peripheral: device, characteristic: characteristic, result: .success(()))
  precondition(results == 0)
  ledger.pump(peripheral: device, canSendWithoutResponse: true)
  ledger.acknowledge(peripheral: device, characteristic: characteristic, result: .failure(failure))
  precondition(results == 1)
}
print("\(cases) Darwin BLE write ledger cases passed")
