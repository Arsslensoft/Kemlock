package com.kemlock.app.securitykey

/**
 * One interface a USB device declares: its [number], and the class, subclass and protocol it
 * says it speaks. This is all a key is recognised by; who made the device is never looked at.
 */
data class UsbInterfaceInfo(val number: Int, val klass: Int, val subclass: Int, val protocol: Int) {
    /** A smartcard reader (CCID). */
    val isCcid: Boolean get() = klass == UsbDescriptors.CLASS_CCID

    /** A keyboard or mouse of the boot kind, which a key uses to type one-time passwords. */
    val isBootHid: Boolean get() = klass == UsbDescriptors.CLASS_HID && subclass == 1 && (protocol == 1 || protocol == 2)

    /** An HID interface that may be FIDO's: its report descriptor says, once permission is given. */
    val isOpenHid: Boolean get() = klass == UsbDescriptors.CLASS_HID && !isBootHid
}

/**
 * One way to talk to a key over USB, as lib/platform/security_keys.dart reads it: [kind] is
 * `usbHid` or `usbCcid`, [frameSize] the size of a report or the longest CCID message.
 */
data class UsbLinkInfo(val kind: String, val interfaceNumber: Int, val extendedLength: Boolean, val frameSize: Int)

/** What an HID report descriptor says: whether it is FIDO's, and the size of its input report. */
data class HidReport(val fido: Boolean, val inputBytes: Int)

/** What a CCID class descriptor says of the reader: `dwFeatures` and `dwMaxCCIDMessageLength`. */
data class CcidClass(val features: Long, val maxMessageLength: Int) {
    /** The reader takes whole APDUs, short or extended, and does the TPDU work itself. */
    val apduLevel: Boolean get() = features and (UsbDescriptors.CCID_SHORT_APDU or UsbDescriptors.CCID_EXTENDED_APDU) != 0L

    /** The reader takes extended-length APDUs. */
    val extendedLength: Boolean get() = features and UsbDescriptors.CCID_EXTENDED_APDU != 0L
}

/**
 * Tells a security key from any other USB device by the interfaces it declares (openspec:
 * add-security-key-management, design decision 5). Pure parsing, with JVM tests; nothing here
 * touches Android.
 */
object UsbDescriptors {
    const val CLASS_HID = 0x03
    const val CLASS_CCID = 0x0B

    const val KIND_HID = "usbHid"
    const val KIND_CCID = "usbCcid"

    /** FIDO's usage page, which the report descriptor of a key's FIDO interface declares. */
    const val FIDO_USAGE_PAGE = 0xF1D0L

    /** The exchange levels in a CCID reader's `dwFeatures`. */
    const val CCID_SHORT_APDU = 0x00020000L
    const val CCID_EXTENDED_APDU = 0x00040000L

    private const val DESCRIPTOR_INTERFACE = 0x04

    /** The type of the class descriptor that follows an HID or a CCID interface descriptor. */
    private const val DESCRIPTOR_CLASS = 0x21
    private const val DESCRIPTOR_REPORT = 0x22
    private const val HID_CLASS_LENGTH = 9
    private const val CCID_CLASS_LENGTH = 54

    /** No report or CCID message is longer than this; a descriptor that says so is not believed. */
    private const val LONGEST_FRAME = 1 shl 20

    /**
     * Whether a device with these [interfaces] may be a security key, so that the person may be
     * asked to let Kemlock use it: it has a smartcard interface, or an HID interface that is not
     * a boot keyboard or mouse. A memory stick or a plain keyboard is not, and is never asked about.
     */
    fun isCandidate(interfaces: List<UsbInterfaceInfo>): Boolean = interfaces.any { it.isCcid || it.isOpenHid }

    /**
     * The links a device with these [interfaces] has as a security key, in the order of its
     * interfaces. [rawDescriptors] are the device's descriptors as the system gives them (the
     * device descriptor, then each configuration with its interfaces); [hidReport] reads the
     * report descriptor of an HID interface, or gives null when the device won't hand it over;
     * [inPacketSize] is the packet size of that interface's IN endpoint.
     *
     * An HID interface is kept only when its report descriptor declares FIDO's usage page. A
     * smartcard interface is kept only when the reader takes whole APDUs: Kemlock's Dart side
     * sends APDUs and does not speak the TPDU or character level, so a reader of those levels
     * is not offered. Boot keyboards and mice are never read, so they are never claimed.
     */
    fun links(
        interfaces: List<UsbInterfaceInfo>,
        rawDescriptors: ByteArray,
        hidReport: (UsbInterfaceInfo) -> ByteArray?,
        inPacketSize: (UsbInterfaceInfo) -> Int,
    ): List<UsbLinkInfo> = interfaces.mapNotNull { info ->
        when {
            info.isCcid -> ccidClass(rawDescriptors, info.number)?.takeIf { it.apduLevel }?.let {
                UsbLinkInfo(KIND_CCID, info.number, it.extendedLength, it.maxMessageLength)
            }
            info.isOpenHid -> hidReport(info)?.let(::hidReport)?.takeIf { it.fido }?.let {
                UsbLinkInfo(KIND_HID, info.number, extendedLength = false, frameSize = if (it.inputBytes > 0) it.inputBytes else inPacketSize(info))
            }
            else -> null
        }
    }

    /**
     * Reads an HID report [descriptor] item by item: short items with the size their first byte
     * gives, long items skipped. It is FIDO's when a Usage Page item names [FIDO_USAGE_PAGE];
     * the input report's size is Report Size times Report Count of the Input items on that page.
     */
    fun hidReport(descriptor: ByteArray): HidReport {
        var fido = false
        var usagePage = 0L
        var reportSize = 0L
        var reportCount = 0L
        var inputBits = 0L
        // What Push saved: usage page, report size, report count.
        val saved = ArrayDeque<Triple<Long, Long, Long>>()
        var at = 0
        while (at < descriptor.size) {
            val prefix = descriptor[at].toInt() and 0xFF
            if (prefix == 0xFE) {
                // A long item: its data size, its tag, then the data.
                if (at + 2 >= descriptor.size) break
                at += 3 + (descriptor[at + 1].toInt() and 0xFF)
                continue
            }
            val size = if (prefix and 0x03 == 3) 4 else prefix and 0x03
            if (at + 1 + size > descriptor.size) break
            val value = unsigned(descriptor, at + 1, size)
            val tag = prefix shr 4
            when ((prefix shr 2) and 0x03) {
                // Main items: Input is tag 8.
                0 -> if (tag == 0x8 && usagePage == FIDO_USAGE_PAGE) inputBits = (inputBits + reportSize * reportCount).coerceAtMost(8L * LONGEST_FRAME + 8)
                // Global items.
                1 -> when (tag) {
                    0x0 -> {
                        usagePage = value
                        if (value == FIDO_USAGE_PAGE) fido = true
                    }
                    0x7 -> reportSize = value
                    0x9 -> reportCount = value
                    0xA -> saved.addLast(Triple(usagePage, reportSize, reportCount))
                    0xB -> saved.removeLastOrNull()?.let {
                        usagePage = it.first
                        reportSize = it.second
                        reportCount = it.third
                    }
                }
            }
            at += 1 + size
        }
        val bytes = (inputBits + 7) / 8
        return HidReport(fido, if (bytes in 1..LONGEST_FRAME) bytes.toInt() else 0)
    }

    /**
     * How long the report descriptor of HID interface [number] is, from the HID class descriptor
     * that follows the interface in [rawDescriptors]; null when it isn't there.
     */
    fun hidReportLength(rawDescriptors: ByteArray, number: Int): Int? {
        val at = classDescriptor(rawDescriptors, number, CLASS_HID, HID_CLASS_LENGTH) ?: return null
        if (rawDescriptors[at + 6].toInt() and 0xFF != DESCRIPTOR_REPORT) return null
        return unsigned(rawDescriptors, at + 7, 2).toInt().takeIf { it > 0 }
    }

    /**
     * The class descriptor of smartcard interface [number] in [rawDescriptors] (type 0x21, 54
     * bytes): `dwFeatures` at offset 40 and `dwMaxCCIDMessageLength` at offset 44, both little
     * endian. Null when the interface has none.
     */
    fun ccidClass(rawDescriptors: ByteArray, number: Int): CcidClass? {
        val at = classDescriptor(rawDescriptors, number, CLASS_CCID, CCID_CLASS_LENGTH) ?: return null
        val longest = unsigned(rawDescriptors, at + 44, 4)
        return CcidClass(features = unsigned(rawDescriptors, at + 40, 4), maxMessageLength = if (longest in 1..LONGEST_FRAME) longest.toInt() else 0)
    }

    /**
     * Where the class descriptor of interface [number] starts in [raw]: the first descriptor of
     * type 0x21 and at least [length] bytes between that interface's descriptor (its first
     * setting, of class [klass]) and the next interface's. Every descriptor starts with its
     * length and its type, which is all that is needed to walk them.
     */
    private fun classDescriptor(raw: ByteArray, number: Int, klass: Int, length: Int): Int? {
        var at = 0
        var inside = false
        while (at + 2 <= raw.size) {
            val size = raw[at].toInt() and 0xFF
            val type = raw[at + 1].toInt() and 0xFF
            if (size < 2 || at + size > raw.size) return null
            if (type == DESCRIPTOR_INTERFACE && size >= 9) {
                inside = (raw[at + 2].toInt() and 0xFF) == number && raw[at + 3].toInt() == 0 && (raw[at + 5].toInt() and 0xFF) == klass
            } else if (inside && type == DESCRIPTOR_CLASS && size >= length) {
                return at
            }
            at += size
        }
        return null
    }

    /** The little-endian number in the [size] bytes of [bytes] from [at]. */
    private fun unsigned(bytes: ByteArray, at: Int, size: Int): Long {
        var value = 0L
        for (i in 0 until size) value = value or ((bytes[at + i].toLong() and 0xFF) shl (8 * i))
        return value
    }
}
