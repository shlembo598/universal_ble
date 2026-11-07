import Foundation
import CoreFoundation

// These shims exercise actual extracted plugin methods, not Apple API availability.
enum BleOutputProperty { case withResponse, withoutResponse }
enum CBCharacteristicWriteType { case withResponse, withoutResponse }
enum CBPeripheralState { case connected, disconnected }
enum Property { case write, writeWithoutResponse }
enum UniversalBleErrorCode: Error {
  case deviceNotFound, characteristicNotFound, characteristicDoesNotSupportWrite
  case characteristicDoesNotSupportWriteWithoutResponse, deviceDisconnected
  case invalidAttributeLength, operationInProgress
}
func createFlutterError(code: UniversalBleErrorCode, message: String) -> Error { code }
extension Error { func toFlutterError() -> Error { self } }
final class UniversalBleLogger {
  static let shared = UniversalBleLogger()
  func logDebug(_ message: String) {}
}
final class FlutterStandardTypedData {
  let data: Data
  init(_ data: Data) { self.data = data }
}
public final class CBCharacteristic: NSObject {
  let properties: Set<Property> = [.write, .writeWithoutResponse]
}
struct DeviceUUID { let uuidString = "a" }
public final class CBPeripheral: NSObject {
  let uuid = DeviceUUID()
  var state = CBPeripheralState.connected
  var canSendWriteWithoutResponse = true
  var withMaximum = 20, withoutMaximum = 20
  let characteristic = CBCharacteristic()
  var sent: [(Data, CBCharacteristicWriteType)] = []
  var onWrite: (() -> Void)?
  func getCharacteristic(_ characteristic: String, of service: String) -> CBCharacteristic? { self.characteristic }
  func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
    type == .withResponse ? withMaximum : withoutMaximum
  }
  func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
    sent.append((data, type)); onWrite?()
  }
}
public final class Manager {
  var peripherals: [String: CBPeripheral] = [:]
  func cancelPeripheralConnection(_ peripheral: CBPeripheral) { peripheral.state = .disconnected }
}
public typealias CBCentralManager = Manager
extension String { func findPeripheral(manager: Manager) -> CBPeripheral? { manager.peripherals[self] } }
final class CallbackChannel {
  func onConnectionChanged(deviceId: String, connected: Bool, error: String?, completion: (Result<Void, Error>) -> Void) { completion(.success(())) }
}
final class Pending<Value> {
  let deviceId: String
  let result: (Result<Value, Error>) -> Void
  init(_ deviceId: String, _ result: @escaping (Result<Value, Error>) -> Void) { self.deviceId = deviceId; self.result = result }
}
final class Discovery { func cleanup() {} }

final class BleCentralDarwin: NSObject {
  let manager = Manager()
  let callbackChannel = CallbackChannel()
  private let writeLedger = DarwinWriteLedger()
  private var autoConnectDevices = Set<String>()
  private var characteristicReadFutures = [Pending<FlutterStandardTypedData>]()
  private var characteristicNotifyFutures = [Pending<Void>]()
  private var discoverServicesFutures = [Pending<[String]>]()
  private var rssiReadFutures = [Pending<Int64>]()
  private var activeServiceDiscoveries: [String: Discovery] = [:]
  // ACTUAL_PLUGIN_METHODS
}

var cases = 0
func scenario(_ name: String, _ run: () -> Void) { run(); cases += 1; print("PASS \(name)") }
func submit(_ plugin: BleCentralDarwin, mode: BleOutputProperty, count: Int = 1,
            result: @escaping (Result<Void, Error>) -> Void) {
  plugin.writeValue(deviceId: "a", service: "service", characteristic: "characteristic",
                    value: FlutterStandardTypedData(Data(repeating: 1, count: count)),
                    bleOutputProperty: mode, completion: result)
}

scenario("actual first short withoutResponse completes without ready callback") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  var completed = 0
  submit(plugin, mode: .withoutResponse) { precondition((try? $0.get()) != nil); completed += 1 }
  precondition(peripheral.sent.count == 1 && completed == 1)
  plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(peripheral.sent.count == 1 && completed == 1)
}
scenario("actual saturation defers bytes until ready and rejects another pending write") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  peripheral.canSendWriteWithoutResponse = false
  var completed = 0, busy = 0
  submit(plugin, mode: .withoutResponse) { precondition((try? $0.get()) != nil); completed += 1 }
  submit(plugin, mode: .withResponse) { if case .failure(let e) = $0 { precondition(e as? UniversalBleErrorCode == .operationInProgress); busy += 1 } }
  plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(peripheral.sent.isEmpty && completed == 0 && busy == 1)
  peripheral.canSendWriteWithoutResponse = true
  plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(peripheral.sent.count == 1 && completed == 1)
}
scenario("actual withResponse registers before synchronous callback") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  peripheral.canSendWriteWithoutResponse = false
  var completed = 0
  peripheral.onWrite = { plugin.peripheral(peripheral, didWriteValueFor: peripheral.characteristic, error: nil) }
  submit(plugin, mode: .withResponse) { precondition((try? $0.get()) != nil); completed += 1 }
  precondition(peripheral.sent.count == 1 && completed == 1)
}
for mode in [BleOutputProperty.withResponse, .withoutResponse] {
  scenario("actual \(mode) validates its own maximum before sending") {
    let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
    peripheral.withMaximum = 3; peripheral.withoutMaximum = 5
    var rejected = 0
    submit(plugin, mode: mode, count: mode == .withResponse ? 4 : 6) {
      if case .failure(let error) = $0 { precondition(error as? UniversalBleErrorCode == .invalidAttributeLength); rejected += 1 }
    }
    precondition(rejected == 1 && peripheral.sent.isEmpty)
    submit(plugin, mode: .withoutResponse, count: 4) { precondition((try? $0.get()) != nil) }
    precondition(peripheral.sent.count == 1)
  }
  scenario("actual disconnect clears \(mode), late readiness never sends old data") {
    let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
    peripheral.canSendWriteWithoutResponse = false
    var failed = 0
    submit(plugin, mode: mode) { if case .failure = $0 { failed += 1 } else { preconditionFailure() } }
    try! plugin.disconnect(deviceId: "a")
    peripheral.state = .connected; peripheral.canSendWriteWithoutResponse = true
    plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
    plugin.peripheral(peripheral, didWriteValueFor: peripheral.characteristic, error: nil)
    precondition(failed == 1 && peripheral.sent.count == (mode == .withResponse ? 1 : 0))
  }
}
scenario("actual ready callback on disconnected peripheral clears deferred data") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  peripheral.canSendWriteWithoutResponse = false
  var failed = 0
  submit(plugin, mode: .withoutResponse) { if case .failure = $0 { failed += 1 } }
  peripheral.state = .disconnected
  plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(failed == 1 && peripheral.sent.isEmpty)
}
scenario("actual write error and duplicate callback complete one request once") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  var failed = 0
  submit(plugin, mode: .withResponse) { if case .failure = $0 { failed += 1 } else { preconditionFailure() } }
  plugin.peripheral(peripheral, didWriteValueFor: peripheral.characteristic, error: NSError(domain: "test", code: 1))
  plugin.peripheral(peripheral, didWriteValueFor: peripheral.characteristic, error: nil)
  precondition(failed == 1)
}
scenario("actual auto-reconnect clears old pending data before readiness returns") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  peripheral.canSendWriteWithoutResponse = false
  var failures = 0
  submit(plugin, mode: .withoutResponse) { if case .failure = $0 { failures += 1 } }
  peripheral.state = .disconnected
  plugin.centralManager(plugin.manager, didDisconnectPeripheral: peripheral, timestamp: 0, isReconnecting: true, error: nil)
  peripheral.state = .connected; peripheral.canSendWriteWithoutResponse = true
  plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(failures == 1 && peripheral.sent.isEmpty)
}
scenario("actual disconnect with missing cached peripheral clears orphaned pending data") {
  let plugin = BleCentralDarwin(), peripheral = CBPeripheral(); plugin.manager.peripherals["a"] = peripheral
  peripheral.canSendWriteWithoutResponse = false
  var failures = 0
  submit(plugin, mode: .withoutResponse) { if case .failure = $0 { failures += 1 } }
  plugin.manager.peripherals.removeValue(forKey: "a")
  try! plugin.disconnect(deviceId: "a")
  peripheral.canSendWriteWithoutResponse = true
  plugin.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(failures == 1 && peripheral.sent.isEmpty)
}
print("\(cases) extracted Darwin plugin write-channel cases passed")

// Owned path must not dispatch a previously rejected payload on a later ready event.
do {
  let central = BleCentralDarwin()
  let peripheral = CBPeripheral()
  central.manager.peripherals["owned"] = peripheral
  peripheral.canSendWriteWithoutResponse = false
  var failed = false
  central.writeOwnedValue(deviceId: "owned", service: "s", characteristic: "c",
    value: FlutterStandardTypedData(Data([1])), bleOutputProperty: .withoutResponse) { result in
    if case .failure = result { failed = true }
  }
  precondition(failed && peripheral.sent.isEmpty)
  peripheral.canSendWriteWithoutResponse = true
  central.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
  precondition(peripheral.sent.isEmpty)
}
print("Owned no-response readiness rejection passed")
