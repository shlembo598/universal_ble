package com.navideck.universal_ble

import java.util.IdentityHashMap

/** One unresolved write per GATT. Object identity, not address/UUID, owns callbacks. */
internal class GattWriteLedger {
    internal class Write(
        val deviceId: String,
        val gatt: Any,
        val characteristic: Any,
        val result: (Result<Unit>) -> Unit,
    )

    private val writes = IdentityHashMap<Any, Write>()

    @Synchronized
    fun admit(deviceId: String, gatt: Any, characteristic: Any, result: (Result<Unit>) -> Unit): Write? {
        if (writes.containsKey(gatt)) return null
        val write = Write(deviceId, gatt, characteristic, result)
        writes[gatt] = write
        return write
    }

    fun complete(gatt: Any?, characteristic: Any, result: Result<Unit>) {
        val write = synchronized(this) {
            val pending = writes[gatt] ?: return
            if (pending.characteristic !== characteristic) return
            writes.remove(gatt)
        }
        write?.result?.invoke(result)
    }

    fun reject(write: Write, error: Throwable) {
        val removed = synchronized(this) {
            if (writes[write.gatt] !== write) false else {
                writes.remove(write.gatt)
                true
            }
        }
        if (removed) write.result(Result.failure(error))
    }

    fun disconnect(deviceId: String, gatt: Any?, error: Throwable) {
        val removed = synchronized(this) {
            val selected = writes.values.filter {
                it.deviceId == deviceId && (gatt == null || it.gatt === gatt)
            }
            selected.forEach { writes.remove(it.gatt) }
            selected
        }
        // Release ownership before calling client code, outside the ledger lock.
        removed.forEach { it.result(Result.failure(error)) }
    }
}
