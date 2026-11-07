package com.navideck.universal_ble

import java.util.concurrent.CyclicBarrier
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

object GattWriteLedgerHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var cases = 0
        fun scenario(name: String, run: () -> Unit) { run(); cases++; println("PASS $name") }
        val failure = IllegalStateException("synthetic")
        scenario("one unresolved write blocks another characteristic on the same GATT") {
            val ledger = GattWriteLedger(); val gatt = Any(); val char = Any()
            check(ledger.admit("same", gatt, char) {} != null)
            check(ledger.admit("same", gatt, Any()) {} == null)
            check(ledger.admit("other", Any(), char) {} != null)
        }
        scenario("same address cannot correlate callbacks from different GATT owners") {
            val ledger = GattWriteLedger(); val old = Any(); val fresh = Any(); val char = Any()
            var oldCount = 0; var freshCount = 0
            ledger.admit("same", old, char) { oldCount++ }
            ledger.admit("same", fresh, char) { freshCount++ }
            ledger.complete(old, char, Result.success(Unit))
            check(oldCount == 1 && freshCount == 0)
            ledger.complete(fresh, char, Result.success(Unit)); check(freshCount == 1)
        }
        scenario("wrong characteristic and unsolicited callback do not release lane") {
            val ledger = GattWriteLedger(); val gatt = Any(); val char = Any(); var count = 0
            ledger.admit("a", gatt, char) { count++ }
            ledger.complete(gatt, Any(), Result.success(Unit)); ledger.complete(null, char, Result.success(Unit))
            check(count == 0 && ledger.admit("a", gatt, char) {} == null)
            ledger.complete(gatt, char, Result.success(Unit)); ledger.complete(gatt, char, Result.success(Unit))
            check(count == 1)
        }
        scenario("captured disconnect cannot reject newer GATT on same address") {
            val ledger = GattWriteLedger(); val old = Any(); val fresh = Any(); val char = Any()
            var oldFailed = false; var freshCompleted = false
            ledger.admit("a", old, char) { oldFailed = it.isFailure }
            ledger.admit("a", fresh, char) { freshCompleted = it.isSuccess }
            ledger.disconnect("a", old, failure); check(oldFailed && !freshCompleted)
            ledger.complete(old, char, Result.success(Unit)); check(!freshCompleted)
            ledger.complete(fresh, char, Result.success(Unit)); check(freshCompleted)
        }
        scenario("immediate rejection and late callback complete once") {
            val ledger = GattWriteLedger(); val gatt = Any(); val char = Any(); var count = 0
            val write = ledger.admit("a", gatt, char) { check(it.isFailure); count++ }!!
            ledger.reject(write, failure); ledger.complete(gatt, char, Result.success(Unit)); ledger.reject(write, failure)
            check(count == 1)
        }
        scenario("old rejected request cannot remove new request on same GATT") {
            val ledger = GattWriteLedger(); val gatt = Any(); val char = Any(); var completed = false
            val old = ledger.admit("a", gatt, char) {}!!
            ledger.reject(old, failure)
            ledger.admit("a", gatt, char) { completed = it.isSuccess }
            ledger.reject(old, failure); check(!completed)
            ledger.complete(gatt, char, Result.success(Unit)); check(completed)
        }
        scenario("ownership releases before callback and callback runs outside lock") {
            val ledger = GattWriteLedger(); val gatt = Any(); val char = Any(); var fresh = false
            ledger.admit("a", gatt, char) {
                val next = thread { check(ledger.admit("a", gatt, char) { fresh = it.isSuccess } != null) }
                next.join(2000); check(!next.isAlive)
            }
            ledger.complete(gatt, char, Result.success(Unit)); ledger.complete(gatt, char, Result.success(Unit))
            check(fresh)
        }
        scenario("disconnect without GATT revokes only matching device") {
            val ledger = GattWriteLedger(); val a = Any(); val b = Any(); val char = Any()
            var aFailed = false; var bCompleted = false
            ledger.admit("a", a, char) { aFailed = it.isFailure }
            ledger.admit("b", b, char) { bCompleted = it.isSuccess }
            ledger.disconnect("a", null, failure); check(aFailed && !bCompleted)
            ledger.complete(b, char, Result.success(Unit)); check(bCompleted)
        }
        scenario("callback/disconnect race resolves exactly once") {
            repeat(100) {
                val ledger = GattWriteLedger(); val gatt = Any(); val char = Any()
                val barrier = CyclicBarrier(2); val count = AtomicInteger()
                ledger.admit("a", gatt, char) { count.incrementAndGet() }
                val callback = thread { barrier.await(); ledger.complete(gatt, char, Result.success(Unit)) }
                val disconnect = thread { barrier.await(); ledger.disconnect("a", gatt, failure) }
                callback.join(); disconnect.join(); check(count.get() == 1)
            }
        }
        println("$cases generic BLE GATT ledger cases passed")
    }
}
