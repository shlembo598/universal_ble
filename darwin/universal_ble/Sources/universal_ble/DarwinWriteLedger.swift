import Foundation

/// CoreBluetooth and Flutter channel callbacks use the central's main queue.
/// One pending write per peripheral; no-response completion is local admission.
final class DarwinWriteLedger {
  enum Mode { case withResponse, withoutResponse }

  final class Write {
    let deviceId: String
    let peripheral: AnyObject
    let characteristic: AnyObject
    let mode: Mode
    let data: Data
    let send: (Data) -> Void
    let result: (Result<Void, Error>) -> Void
    var dispatched = false

    init(deviceId: String, peripheral: AnyObject, characteristic: AnyObject,
         mode: Mode, data: Data, send: @escaping (Data) -> Void,
         result: @escaping (Result<Void, Error>) -> Void) {
      self.deviceId = deviceId
      self.peripheral = peripheral
      self.characteristic = characteristic
      self.mode = mode
      self.data = data
      self.send = send
      self.result = result
    }
  }

  private var writes: [ObjectIdentifier: Write] = [:]

  func admit(deviceId: String, peripheral: AnyObject, characteristic: AnyObject,
             mode: Mode, data: Data, send: @escaping (Data) -> Void,
             result: @escaping (Result<Void, Error>) -> Void) -> Bool {
    let key = ObjectIdentifier(peripheral)
    guard writes[key] == nil else { return false }
    writes[key] = Write(deviceId: deviceId, peripheral: peripheral, characteristic: characteristic,
                        mode: mode, data: data, send: send, result: result)
    return true
  }

  func pump(peripheral: AnyObject, canSendWithoutResponse: Bool) {
    guard let write = writes[ObjectIdentifier(peripheral)], !write.dispatched else { return }
    guard write.mode == .withResponse || canSendWithoutResponse else { return }
    // Register dispatch before invoking CoreBluetooth; a reentrant callback is safe.
    write.dispatched = true
    write.send(write.data)
    if write.mode == .withoutResponse { finish(write, .success(())) }
  }

  func acknowledge(peripheral: AnyObject, characteristic: AnyObject, result: Result<Void, Error>) {
    guard let write = writes[ObjectIdentifier(peripheral)], write.dispatched,
          write.mode == .withResponse, write.characteristic === characteristic else { return }
    finish(write, result)
  }

  func disconnect(deviceId: String, peripheral: AnyObject?, error: Error) {
    fail(writes.values.filter {
      $0.deviceId == deviceId && (peripheral == nil || $0.peripheral === peripheral)
    }, error: error)
  }

  func unavailable(error: Error) {
    fail(Array(writes.values), error: error)
  }

  private func finish(_ write: Write, _ result: Result<Void, Error>) {
    let key = ObjectIdentifier(write.peripheral)
    guard writes[key] === write else { return }
    writes.removeValue(forKey: key)
    write.result(result)
  }

  private func fail(_ selected: [Write], error: Error) {
    // Remove the entire captured set before callbacks can admit a new request.
    for write in selected { writes.removeValue(forKey: ObjectIdentifier(write.peripheral)) }
    for write in selected { write.result(.failure(error)) }
  }
}
