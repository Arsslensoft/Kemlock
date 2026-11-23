package com.kemlock.app.securitykey

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * A USB device that may be a security key, under the name [id] the Dart side knows it by:
 * `usb:` and the kernel's number for this plug-in, which changes each time it is plugged in.
 * Its serial number is never read.
 */
internal class UsbKey(val id: String, val device: UsbDevice) {
    /** Its links as a security key, once permission let them be read. Written on the I/O thread. */
    @Volatile
    var links: List<UsbLink>? = null

    /** It was unplugged. */
    @Volatile
    var removed = false

    /** The open device, shared by its links, and how many hold it. I/O thread only. */
    var connection: UsbDeviceConnection? = null
    var holders = 0
}

/** A read the Dart side is waiting on. */
internal class PendingRead(val result: MethodChannel.Result)

/**
 * One interface of a [UsbKey] that carries messages: FIDO's HID interface, or the smartcard
 * (CCID) one. [input] is the endpoint the key answers on; [output] the one it is written to,
 * which an HID interface may lack.
 */
internal class UsbLink(
    val id: String,
    val info: UsbLinkInfo,
    val key: UsbKey,
    val usbInterface: UsbInterface,
    val input: UsbEndpoint,
    val output: UsbEndpoint?,
) {
    /** The interface is claimed and its reader runs. Written on the I/O thread. */
    @Volatile
    var open = false

    /** The thread that waits on [input]. It goes on for as long as it is the one named here. */
    @Volatile
    var reader: Thread? = null

    /** The frames the key sent that the Dart side has not taken yet, and its waiting read. Main thread only. */
    val frames = ArrayDeque<ByteArray>()
    var pending: PendingRead? = null

    val isHid: Boolean get() = info.kind == UsbDescriptors.KIND_HID

    fun map(): Map<String, Any?> = mapOf("id" to id, "kind" to info.kind, "extendedLength" to info.extendedLength, "frameSize" to info.frameSize)
}

/**
 * Security keys over USB: finds them, asks the system's question, and carries raw frames.
 *
 * A device is a candidate by the interfaces it declares ([UsbDescriptors]), never by who made
 * it: there is no list of makers or models, and no filter in the manifest, so the system asks
 * its question each time a key is plugged in and only when a screen wants the key.
 *
 * Threads: the maps and every answer live on the main thread. Opening, claiming, writing and
 * closing run on one I/O thread. Each open link has a reader thread that waits on its IN
 * endpoint and posts every frame to the main thread, so a read never holds the I/O thread and
 * a write (CTAPHID's cancel, say) goes out while a read waits.
 */
internal class UsbLinks(
    private val context: Context,
    private val main: Handler,
    private val tell: (Map<String, Any?>) -> Unit,
) {
    private val manager: UsbManager? = runCatching { context.getSystemService(Context.USB_SERVICE) as? UsbManager }.getOrNull()
    private val io = Executors.newSingleThreadExecutor()
    private val permissionAction = context.packageName + ".securitykey.USB_PERMISSION"

    private val keys = HashMap<String, UsbKey>()

    /** The devices the Dart side was told of, which it is told of again when they leave. */
    private val told = HashSet<String>()

    /** Who waits for the system's question about a device to be answered. */
    private val asking = HashMap<String, MutableList<MethodChannel.Result>>()
    private var watching = false
    private var awaitingAnswer = false

    /** A device was plugged in or unplugged, while the Dart side listens. */
    private val plugs = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = device(intent) ?: return
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> attached(device)
                UsbManager.ACTION_USB_DEVICE_DETACHED -> gone(id(device))
            }
        }
    }

    /** The person answered the system's question. */
    private val answers = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != permissionAction) return
            // The device the answer is about; without it, every question is looked at again.
            val ids = device(intent)?.let { listOf(id(it)) } ?: asking.keys.toList()
            for (id in ids) answered(id)
            if (asking.isEmpty()) stopAwaitingAnswer()
        }
    }

    // ---- Finding keys ----

    /** Starts or stops telling of keys plugged in and unplugged. */
    fun watch(on: Boolean) {
        if (watching == on) return
        watching = on
        runCatching {
            if (on) {
                val filter = IntentFilter().apply {
                    addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                    addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
                }
                // Not exported: the system's own broadcasts still arrive.
                ContextCompat.registerReceiver(context, plugs, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
            } else {
                context.unregisterReceiver(plugs)
            }
        }
    }

    /** The activity is going away for good. */
    fun shutDown() {
        watch(false)
        stopAwaitingAnswer()
        for (id in keys.keys.toList()) gone(id)
        io.shutdown()
    }

    /** The candidates plugged in now, each as the Dart side reads a device. */
    fun present(result: MethodChannel.Result) {
        val plugged = devices().filter(::isCandidate)
        val ids = plugged.map(::id).toSet()
        // Unplugged while nobody listened.
        for (id in keys.keys.filter { it !in ids }) gone(id)
        val now = plugged.map(::key)
        io.execute {
            val maps = now.mapNotNull(::describe)
            main.post {
                for (map in maps) told += map["device"] as String
                result.success(maps)
            }
        }
    }

    private fun attached(device: UsbDevice) {
        if (!isCandidate(device)) return
        val key = key(device)
        io.execute {
            val map = describe(key) ?: return@execute
            main.post {
                if (watching && !key.removed) {
                    told += key.id
                    tell(map + ("event" to "arrived"))
                }
            }
        }
    }

    /**
     * On the I/O thread: [key] as the Dart side reads a device. Before permission its links are
     * not known. With permission, a device that has none is not a security key and is left out.
     */
    private fun describe(key: UsbKey): Map<String, Any?>? {
        val links = if (permitted(key.device)) runCatching { linksOf(key) }.getOrNull() ?: return null else null
        if (links != null && links.isEmpty()) return null
        return mapOf(
            "device" to key.id,
            "product" to runCatching { key.device.productName }.getOrNull(),
            "needsPermission" to (links == null),
            "links" to links.orEmpty().map(UsbLink::map),
        )
    }

    /**
     * The device named [id] is no longer plugged in: its reads fail with `removed`, its links
     * are closed, and the Dart side is told when it knew of it. Main thread.
     */
    private fun gone(id: String) {
        asking.remove(id)?.forEach { it.fail(SecurityKeyError.Removed()) }
        val key = keys.remove(id)
        if (key != null) {
            key.removed = true
            val links = key.links.orEmpty()
            for (link in links) {
                link.frames.clear()
                link.pending?.result?.fail(SecurityKeyError.Removed())
                link.pending = null
            }
            if (!io.isShutdown) {
                io.execute {
                    for (link in links) shut(link)
                    runCatching { key.connection?.close() }
                    key.connection = null
                    key.holders = 0
                }
            }
        }
        if (told.remove(id)) tell(mapOf("event" to "left", "device" to id))
    }

    // ---- The system's question ----

    /**
     * Answers with the links of the device named [deviceId], after the system's question when
     * Kemlock may not use the device yet.
     */
    fun requestPermission(deviceId: String, result: MethodChannel.Result) {
        val manager = manager ?: return result.fail(SecurityKeyError.Unavailable())
        val device = devices().firstOrNull { id(it) == deviceId } ?: return result.fail(SecurityKeyError.Removed())
        // Never ask about a device that cannot be a key.
        if (!isCandidate(device)) return result.success(emptyList<Any>())
        val key = key(device)
        if (permitted(device)) return answerLinks(key, result)
        val waiting = asking.getOrPut(deviceId) { ArrayList() }
        waiting += result
        // The question is already up.
        if (waiting.size > 1) return
        try {
            awaitAnswer()
            // Mutable from Android 12, so the system can add its answer; the package makes the intent ours alone.
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val intent = Intent(permissionAction).setPackage(context.packageName)
            manager.requestPermission(device, PendingIntent.getBroadcast(context, 0, intent, flags))
        } catch (e: Exception) {
            asking.remove(deviceId)
            if (asking.isEmpty()) stopAwaitingAnswer()
            result.fail(SecurityKeyError.Failed(e.message ?: e.javaClass.simpleName))
        }
    }

    /** The question about the device named [id] was answered: whether it may be used is asked of the system. */
    private fun answered(id: String) {
        val waiting = asking.remove(id) ?: return
        val device = devices().firstOrNull { id(it) == id }
        when {
            device == null -> {
                waiting.forEach { it.fail(SecurityKeyError.Removed()) }
                gone(id)
            }
            permitted(device) -> waiting.forEach { answerLinks(key(device), it) }
            else -> waiting.forEach { it.fail(SecurityKeyError.Denied()) }
        }
    }

    private fun answerLinks(key: UsbKey, result: MethodChannel.Result) {
        io.execute {
            try {
                val maps = linksOf(key).map(UsbLink::map)
                main.post {
                    told += key.id
                    result.success(maps)
                }
            } catch (e: Exception) {
                val error = e as? SecurityKeyError ?: SecurityKeyError.Failed(e.message ?: e.javaClass.simpleName)
                main.post { result.fail(error) }
            }
        }
    }

    private fun awaitAnswer() {
        if (awaitingAnswer) return
        ContextCompat.registerReceiver(context, answers, IntentFilter(permissionAction), ContextCompat.RECEIVER_NOT_EXPORTED)
        awaitingAnswer = true
    }

    private fun stopAwaitingAnswer() {
        if (!awaitingAnswer) return
        awaitingAnswer = false
        runCatching { context.unregisterReceiver(answers) }
    }

    // ---- Reading what a device is ----

    /**
     * On the I/O thread, with permission: the links [key] has as a security key, read once and
     * kept for as long as it stays plugged in. Reading an HID interface's report descriptor
     * needs the interface claimed for a moment; boot keyboards and mice are never touched.
     */
    private fun linksOf(key: UsbKey): List<UsbLink> {
        key.links?.let { return it }
        val connection = acquire(key)
        try {
            val raw = connection.rawDescriptors ?: ByteArray(0)
            val usable = LinkedHashMap<UsbInterfaceInfo, Triple<UsbInterface, UsbEndpoint, UsbEndpoint?>>()
            for (usbInterface in interfaces(key.device)) {
                val info = info(usbInterface)
                if (info.isCcid) {
                    val input = endpoint(usbInterface, UsbConstants.USB_ENDPOINT_XFER_BULK, UsbConstants.USB_DIR_IN) ?: continue
                    val output = endpoint(usbInterface, UsbConstants.USB_ENDPOINT_XFER_BULK, UsbConstants.USB_DIR_OUT) ?: continue
                    usable[info] = Triple(usbInterface, input, output)
                } else if (info.isOpenHid) {
                    val input = endpoint(usbInterface, UsbConstants.USB_ENDPOINT_XFER_INT, UsbConstants.USB_DIR_IN) ?: continue
                    usable[info] = Triple(usbInterface, input, endpoint(usbInterface, UsbConstants.USB_ENDPOINT_XFER_INT, UsbConstants.USB_DIR_OUT))
                }
            }
            val found = UsbDescriptors.links(
                usable.keys.toList(),
                raw,
                hidReport = { info -> reportDescriptor(connection, usable.getValue(info).first, raw) },
                inPacketSize = { info -> usable.getValue(info).second.maxPacketSize },
            )
            val links = found.mapNotNull { link ->
                val (info, pipes) = usable.entries.firstOrNull { it.key.number == link.interfaceNumber } ?: return@mapNotNull null
                val kind = if (link.kind == UsbDescriptors.KIND_HID) "hid" else "ccid"
                UsbLink("${key.id}:$kind:${info.number}", link, key, pipes.first, pipes.second, pipes.third)
            }
            key.links = links
            return links
        } finally {
            release(key)
        }
    }

    /**
     * The report descriptor of HID interface [usbInterface]: GET_DESCRIPTOR (Report) sent to
     * the interface. The interface is claimed for the request, taking it from the system's own
     * HID driver, and given back at once.
     */
    private fun reportDescriptor(connection: UsbDeviceConnection, usbInterface: UsbInterface, raw: ByteArray): ByteArray? {
        if (!connection.claimInterface(usbInterface, true)) return null
        try {
            val length = (UsbDescriptors.hidReportLength(raw, usbInterface.id) ?: REPORT_DESCRIPTOR_GUESS).coerceIn(1, REPORT_DESCRIPTOR_LONGEST)
            val buffer = ByteArray(length)
            val read = connection.controlTransfer(0x81, 0x06, 0x2200, usbInterface.id, buffer, buffer.size, CONTROL_TIMEOUT_MS)
            return if (read > 0) buffer.copyOf(read) else null
        } finally {
            runCatching { connection.releaseInterface(usbInterface) }
        }
    }

    // ---- Links ----

    private fun find(id: String): UsbLink? {
        for (key in keys.values) key.links?.firstOrNull { it.id == id }?.let { return it }
        return null
    }

    /** Opens the device if no other link has, claims the interface and starts its reader. */
    fun open(id: String, result: MethodChannel.Result) {
        val link = find(id) ?: return result.fail(SecurityKeyError.Removed())
        background(link, result) {
            if (link.key.removed) throw SecurityKeyError.Removed()
            if (!link.open) {
                val connection = acquire(link.key)
                // Force: the system's HID driver holds a FIDO interface until it is taken from it.
                if (!connection.claimInterface(link.usbInterface, true)) {
                    release(link.key)
                    throw SecurityKeyError.Failed("The key's interface could not be claimed")
                }
                start(link, connection)
            }
            null
        }
    }

    /** Ends the link. A link that is gone is not an error. */
    fun close(id: String, result: MethodChannel.Result) {
        val link = find(id) ?: return result.success(null)
        link.frames.clear()
        link.pending?.result?.success(emptyList<ByteArray>())
        link.pending = null
        io.execute {
            runCatching { shut(link) }
            main.post {
                // What the reader posted while the link was closing.
                link.frames.clear()
                result.success(null)
            }
        }
    }

    /**
     * Sends [frames] in order. HID: each is one output report, with no report id in front since
     * FIDO uses none, written to the interrupt OUT endpoint, or with SET_REPORT when the
     * interface has no such endpoint. CCID: each is one whole message on the bulk OUT endpoint.
     */
    fun write(id: String, frames: List<ByteArray>, result: MethodChannel.Result) {
        val link = find(id) ?: return result.fail(SecurityKeyError.Removed())
        background(link, result) {
            val connection = link.key.connection?.takeIf { link.open } ?: throw SecurityKeyError.Failed("The link is not open")
            for (frame in frames) {
                if (frame.isEmpty()) continue
                if (!send(connection, link, frame)) throw SecurityKeyError.Failed("The key did not take the message")
            }
            null
        }
    }

    private fun send(connection: UsbDeviceConnection, link: UsbLink, frame: ByteArray): Boolean {
        val output = link.output
            // SET_REPORT (Output, report id 0) to the interface.
            ?: return connection.controlTransfer(0x21, 0x09, 0x0200, link.usbInterface.id, frame, frame.size, WRITE_TIMEOUT_MS) == frame.size
        if (frame.size <= TRANSFER_LONGEST) return connection.bulkTransfer(output, frame, frame.size, WRITE_TIMEOUT_MS) == frame.size
        // Before Android 9 a transfer carries 16 384 bytes at most. That is a whole number of
        // packets, so the key sees the pieces as one message.
        var at = 0
        while (at < frame.size) {
            val piece = frame.copyOfRange(at, minOf(at + TRANSFER_LONGEST, frame.size))
            if (connection.bulkTransfer(output, piece, piece.size, WRITE_TIMEOUT_MS) != piece.size) return false
            at += piece.size
        }
        return true
    }

    /**
     * Every frame the key has sent since the last read; when there is none, the first to come
     * within [timeoutMs]. No frame in time is an empty list, not an error.
     */
    fun read(id: String, timeoutMs: Int, result: MethodChannel.Result) {
        val link = find(id) ?: return result.fail(SecurityKeyError.Removed())
        if (!link.open) return result.fail(SecurityKeyError.Failed("The link is not open"))
        if (link.frames.isNotEmpty()) {
            val waiting = ArrayList(link.frames)
            link.frames.clear()
            return result.success(waiting)
        }
        if (timeoutMs <= 0) return result.success(emptyList<ByteArray>())
        // One read waits at a time.
        link.pending?.result?.success(emptyList<ByteArray>())
        val pending = PendingRead(result)
        link.pending = pending
        main.postDelayed({
            if (link.pending === pending) {
                link.pending = null
                // Silence may be a key that was unplugged while nobody watched the plugs.
                if (plugged(link.key.device)) {
                    result.success(emptyList<ByteArray>())
                } else {
                    result.fail(SecurityKeyError.Removed())
                    gone(link.key.id)
                }
            }
        }, timeoutMs.toLong())
    }

    /** A frame came from the key. Main thread. */
    private fun arrived(link: UsbLink, frame: ByteArray) {
        if (!link.open || link.key.removed) return
        val pending = link.pending
        if (pending != null) {
            link.pending = null
            pending.result.success(listOf(frame))
        } else {
            if (link.frames.size >= FRAMES_KEPT) link.frames.removeFirst()
            link.frames.addLast(frame)
        }
    }

    /**
     * On the I/O thread: starts the thread that waits on [link]'s IN endpoint. HID: each frame
     * is one input report. CCID: each frame is what one bulk transfer returned; the Dart side
     * puts messages together from their length field. The wait is cut into short ones so the
     * thread sees the link close; `bulkTransfer` serves interrupt endpoints as well as bulk ones.
     */
    private fun start(link: UsbLink, connection: UsbDeviceConnection) {
        val packet = link.input.maxPacketSize.coerceAtLeast(1)
        // A whole number of packets, so a key never sends more than the buffer holds.
        val size = if (link.isHid) ((maxOf(link.info.frameSize, packet) + packet - 1) / packet) * packet else TRANSFER_LONGEST
        link.open = true
        val reader = Thread({
            val buffer = ByteArray(size)
            while (link.reader === Thread.currentThread()) {
                val started = SystemClock.elapsedRealtime()
                val read = try {
                    connection.bulkTransfer(link.input, buffer, buffer.size, READ_SLICE_MS)
                } catch (e: Exception) {
                    -1
                }
                if (read > 0) {
                    val frame = buffer.copyOf(read)
                    main.post { arrived(link, frame) }
                } else if (read < 0 && link.reader === Thread.currentThread() && SystemClock.elapsedRealtime() - started < READ_SLICE_MS / 2) {
                    // An error, not a wait that ran out: the key is going away. Don't spin until the system says so.
                    try {
                        Thread.sleep(READ_SLICE_MS / 2L)
                    } catch (e: InterruptedException) {
                        return@Thread
                    }
                }
            }
        }, "kemlock-security-key")
        reader.isDaemon = true
        link.reader = reader
        reader.start()
    }

    /** On the I/O thread: stops [link]'s reader, gives the interface back and lets go of the device. */
    private fun shut(link: UsbLink) {
        if (!link.open) return
        link.open = false
        val reader = link.reader
        link.reader = null
        // The reader must be out of its transfer before the device is closed under it.
        runCatching { reader?.join(READER_STOP_MS) }
        val connection = link.key.connection
        if (connection != null) runCatching { connection.releaseInterface(link.usbInterface) }
        release(link.key)
    }

    /** On the I/O thread: the open device of [key], opened when no link holds it yet. */
    private fun acquire(key: UsbKey): UsbDeviceConnection {
        key.connection?.let {
            key.holders += 1
            return it
        }
        val opened = try {
            manager?.openDevice(key.device)
        } catch (e: SecurityException) {
            throw SecurityKeyError.Denied()
        } catch (e: Exception) {
            null
        }
        if (opened == null) {
            throw if (key.removed || !plugged(key.device)) SecurityKeyError.Removed() else SecurityKeyError.Failed("The key could not be opened")
        }
        key.connection = opened
        key.holders = 1
        return opened
    }

    /** On the I/O thread: closes the device when its last holder lets go. */
    private fun release(key: UsbKey) {
        if (key.holders > 0) key.holders -= 1
        if (key.holders == 0) {
            runCatching { key.connection?.close() }
            key.connection = null
        }
    }

    /**
     * Runs [work] on the I/O thread and answers [result] on the main thread. Work that fails
     * on a key that is no longer plugged in fails with `removed`, whatever it threw.
     */
    private fun background(link: UsbLink, result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                val removed = e is SecurityKeyError.Removed || link.key.removed || !plugged(link.key.device)
                val error = when {
                    removed -> SecurityKeyError.Removed()
                    e is SecurityKeyError -> e
                    else -> SecurityKeyError.Failed(e.message ?: e.javaClass.simpleName)
                }
                main.post {
                    result.fail(error)
                    if (removed) gone(link.key.id)
                }
            }
        }
    }

    // ---- The system's view of the devices ----

    private fun devices(): List<UsbDevice> = runCatching { manager?.deviceList?.values?.toList() }.getOrNull().orEmpty()

    private fun plugged(device: UsbDevice): Boolean = devices().any { it.deviceId == device.deviceId }

    private fun permitted(device: UsbDevice): Boolean = runCatching { manager?.hasPermission(device) == true }.getOrDefault(false)

    private fun key(device: UsbDevice): UsbKey = keys.getOrPut(id(device)) { UsbKey(id(device), device) }

    private fun id(device: UsbDevice): String = "usb:${device.deviceId}"

    /** The device's interfaces, each in its first setting. */
    private fun interfaces(device: UsbDevice): List<UsbInterface> =
        (0 until device.interfaceCount).map(device::getInterface).filter { it.alternateSetting == 0 }

    private fun info(usbInterface: UsbInterface) =
        UsbInterfaceInfo(usbInterface.id, usbInterface.interfaceClass, usbInterface.interfaceSubclass, usbInterface.interfaceProtocol)

    private fun isCandidate(device: UsbDevice): Boolean = UsbDescriptors.isCandidate(interfaces(device).map(::info))

    private fun endpoint(usbInterface: UsbInterface, type: Int, direction: Int): UsbEndpoint? =
        (0 until usbInterface.endpointCount).map(usbInterface::getEndpoint).firstOrNull { it.type == type && it.direction == direction }

    private fun device(intent: Intent): UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
    } else {
        @Suppress("DEPRECATION")
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
    }

    private companion object {
        const val CONTROL_TIMEOUT_MS = 1000
        const val WRITE_TIMEOUT_MS = 2000

        /** How long the reader waits on the endpoint before it looks whether the link was closed. */
        const val READ_SLICE_MS = 250
        const val READER_STOP_MS = 1000L

        /** What one transfer carries on every Android version: 16 384 bytes, a whole number of packets at any speed. */
        const val TRANSFER_LONGEST = 16384

        /** The report descriptor's length when the HID descriptor does not give it, and the longest one read. */
        const val REPORT_DESCRIPTOR_GUESS = 512
        const val REPORT_DESCRIPTOR_LONGEST = 4096

        /** Frames kept for a Dart side that stopped reading, after which the oldest go. */
        const val FRAMES_KEPT = 4096
    }
}
