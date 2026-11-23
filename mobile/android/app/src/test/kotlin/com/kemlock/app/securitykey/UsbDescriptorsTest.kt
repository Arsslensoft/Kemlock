package com.kemlock.app.securitykey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Descriptors written by hand from the USB, HID, CCID and CTAP specifications; no key's own bytes. */
class UsbDescriptorsTest {
    private fun hex(vararg parts: String): ByteArray =
        parts.joinToString(" ").trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()

    /** The report descriptor CTAP gives for a FIDO HID interface: 64-byte reports in and out. */
    private val fidoReport = hex(
        "06 D0 F1", // Usage Page (FIDO Alliance)
        "09 01", // Usage (CTAPHID)
        "A1 01", // Collection (Application)
        "09 20 15 00 26 FF 00 75 08 95 40 81 02", // 64 bytes in
        "09 21 15 00 26 FF 00 75 08 95 40 91 02", // 64 bytes out
        "C0",
    )

    /** A gamepad: ten buttons and two axes, on the Generic Desktop and Button pages. */
    private val gamepadReport = hex(
        "05 01 09 05 A1 01",
        "15 00 25 01 75 01 95 0A 05 09 19 01 29 0A 81 02",
        "95 06 81 03",
        "05 01 09 30 09 31 15 00 26 FF 00 75 08 95 02 81 02",
        "C0",
    )

    /** A CCID class descriptor with [features] and [longest] as dwFeatures and dwMaxCCIDMessageLength, little endian. */
    private fun ccidClassDescriptor(features: String, longest: String): ByteArray = hex(
        "36 21 10 01 00 07", // bLength 54, bDescriptorType, bcdCCID 1.10, one slot, voltages
        "02 00 00 00", // dwProtocols: T=1
        "A0 0F 00 00 A0 0F 00 00 00", // clocks
        "00 2A 00 00 00 2A 00 00 00", // data rates
        "FE 00 00 00", // dwMaxIFSD
        "00 00 00 00 00 00 00 00", // dwSynchProtocols, dwMechanical
        features, // offset 40
        longest, // offset 44
        "FF FF 00 00 00 01",
    ).also { assertEquals(54, it.size) }

    private val extendedApdu = ccidClassDescriptor("40 08 04 00", "00 0C 00 00")
    private val shortApdu = ccidClassDescriptor("40 08 02 00", "0F 01 00 00")
    private val tpdu = ccidClassDescriptor("30 02 01 00", "0F 01 00 00")

    private val deviceDescriptor = hex("12 01 00 02 00 00 00 40 00 00 00 00 00 01 01 02 00 01")

    /** A device and one configuration holding only a smartcard interface, number 0, with [classDescriptor]. */
    private fun ccidDevice(classDescriptor: ByteArray): ByteArray = deviceDescriptor + hex("09 02 5D 00 01 01 00 80 32") +
        hex("09 04 00 00 03 0B 00 00 00") + classDescriptor +
        hex("07 05 02 02 40 00 00", "07 05 82 02 40 00 00", "07 05 83 03 08 00 20")

    private val keyboard = UsbInterfaceInfo(number = 0, klass = 0x03, subclass = 1, protocol = 1)
    private val fido = UsbInterfaceInfo(number = 1, klass = 0x03, subclass = 0, protocol = 0)
    private val ccid = UsbInterfaceInfo(number = 2, klass = 0x0B, subclass = 0, protocol = 0)

    /** A key with a keyboard for one-time passwords, a FIDO HID interface and a smartcard interface. */
    private val composite: ByteArray = deviceDescriptor + hex("09 02 96 00 03 01 00 80 32") +
        // 0: boot keyboard, its HID descriptor (a 71-byte report descriptor), one endpoint
        hex("09 04 00 00 01 03 01 01 00", "09 21 11 01 00 01 22 47 00", "07 05 81 03 08 00 0A") +
        // 1: FIDO HID, its HID descriptor (a 34-byte report descriptor), two endpoints
        hex("09 04 01 00 02 03 00 00 00", "09 21 11 01 00 01 22 22 00", "07 05 04 03 40 00 02", "07 05 84 03 40 00 02") +
        // 2: smartcard, its class descriptor, three endpoints
        hex("09 04 02 00 03 0B 00 00 00") + extendedApdu +
        hex("07 05 02 02 40 00 00", "07 05 82 02 40 00 00", "07 05 83 03 08 00 20")

    private fun neverRead(info: UsbInterfaceInfo): ByteArray? {
        fail("Interface ${info.number} must not be read")
        return null
    }

    @Test
    fun keepsAFidoHidInterface() {
        val interfaces = listOf(UsbInterfaceInfo(number = 0, klass = 0x03, subclass = 0, protocol = 0))

        assertEquals(34, fidoReport.size)
        assertTrue(UsbDescriptors.isCandidate(interfaces))
        assertEquals(HidReport(fido = true, inputBytes = 64), UsbDescriptors.hidReport(fidoReport))
        assertEquals(
            listOf(UsbLinkInfo("usbHid", interfaceNumber = 0, extendedLength = false, frameSize = 64)),
            UsbDescriptors.links(interfaces, ByteArray(0), hidReport = { fidoReport }, inPacketSize = { 8 }),
        )
    }

    @Test
    fun takesTheEndpointsPacketSizeWhenTheReportHasNoInput() {
        val interfaces = listOf(UsbInterfaceInfo(number = 0, klass = 0x03, subclass = 0, protocol = 0))
        val bare = hex("06 D0 F1 09 01 A1 01 C0")

        assertEquals(HidReport(fido = true, inputBytes = 0), UsbDescriptors.hidReport(bare))
        assertEquals(
            listOf(UsbLinkInfo("usbHid", interfaceNumber = 0, extendedLength = false, frameSize = 32)),
            UsbDescriptors.links(interfaces, ByteArray(0), hidReport = { bare }, inPacketSize = { 32 }),
        )
    }

    @Test
    fun refusesABootKeyboardAMouseAndAMemoryStick() {
        val mouse = UsbInterfaceInfo(number = 0, klass = 0x03, subclass = 1, protocol = 2)
        val massStorage = UsbInterfaceInfo(number = 0, klass = 0x08, subclass = 0x06, protocol = 0x50)

        assertFalse(UsbDescriptors.isCandidate(listOf(keyboard)))
        assertFalse(UsbDescriptors.isCandidate(listOf(mouse)))
        assertFalse(UsbDescriptors.isCandidate(listOf(massStorage)))
        assertFalse(UsbDescriptors.isCandidate(listOf(keyboard, mouse, massStorage)))
        assertFalse(UsbDescriptors.isCandidate(emptyList()))
        assertEquals(
            emptyList<UsbLinkInfo>(),
            UsbDescriptors.links(listOf(keyboard, mouse, massStorage), ByteArray(0), hidReport = ::neverRead, inPacketSize = { 8 }),
        )
    }

    @Test
    fun asksAboutAGamepadAndFindsNoLink() {
        val gamepad = listOf(UsbInterfaceInfo(number = 0, klass = 0x03, subclass = 0, protocol = 0))

        assertTrue(UsbDescriptors.isCandidate(gamepad))
        assertFalse(UsbDescriptors.hidReport(gamepadReport).fido)
        assertEquals(emptyList<UsbLinkInfo>(), UsbDescriptors.links(gamepad, ByteArray(0), hidReport = { gamepadReport }, inPacketSize = { 8 }))
        // A device that won't hand over its report descriptor
        assertEquals(emptyList<UsbLinkInfo>(), UsbDescriptors.links(gamepad, ByteArray(0), hidReport = { null }, inPacketSize = { 8 }))
    }

    @Test
    fun readsTheReportDescriptorItemByItem() {
        // A long item in front is skipped
        assertEquals(HidReport(fido = true, inputBytes = 64), UsbDescriptors.hidReport(hex("FE 03 F0 AA BB CC") + fidoReport))
        // The page's bytes as the data of another item (a four-byte Logical Maximum) declare nothing
        assertFalse(UsbDescriptors.hidReport(hex("05 01 09 05 A1 01 27 06 D0 F1 00 75 08 95 40 81 02 C0")).fido)
        // The page given in four bytes
        assertTrue(UsbDescriptors.hidReport(hex("07 D0 F1 00 00 09 01 A1 01 C0")).fido)
        // Input items on another page are not FIDO's report
        assertEquals(
            HidReport(fido = true, inputBytes = 64),
            UsbDescriptors.hidReport(hex("05 01 09 06 A1 01 75 08 95 08 81 02 C0") + fidoReport),
        )
        // Cut short, or empty
        assertEquals(HidReport(fido = false, inputBytes = 0), UsbDescriptors.hidReport(hex("06 D0")))
        assertEquals(HidReport(fido = false, inputBytes = 0), UsbDescriptors.hidReport(ByteArray(0)))
        assertEquals(HidReport(fido = false, inputBytes = 0), UsbDescriptors.hidReport(hex("FE 03")))
    }

    @Test
    fun keepsASmartcardInterfaceWithWhatItsClassDescriptorSays() {
        val interfaces = listOf(UsbInterfaceInfo(number = 0, klass = 0x0B, subclass = 0, protocol = 0))

        assertTrue(UsbDescriptors.isCandidate(interfaces))
        assertEquals(CcidClass(features = 0x00040840, maxMessageLength = 3072), UsbDescriptors.ccidClass(ccidDevice(extendedApdu), 0))
        assertEquals(
            listOf(UsbLinkInfo("usbCcid", interfaceNumber = 0, extendedLength = true, frameSize = 3072)),
            UsbDescriptors.links(interfaces, ccidDevice(extendedApdu), hidReport = ::neverRead, inPacketSize = { 64 }),
        )
        assertEquals(
            listOf(UsbLinkInfo("usbCcid", interfaceNumber = 0, extendedLength = false, frameSize = 271)),
            UsbDescriptors.links(interfaces, ccidDevice(shortApdu), hidReport = ::neverRead, inPacketSize = { 64 }),
        )
    }

    @Test
    fun doesNotOfferASmartcardInterfaceOfTheTpduLevel() {
        val interfaces = listOf(UsbInterfaceInfo(number = 0, klass = 0x0B, subclass = 0, protocol = 0))

        assertTrue(UsbDescriptors.isCandidate(interfaces))
        assertFalse(UsbDescriptors.ccidClass(ccidDevice(tpdu), 0)!!.apduLevel)
        assertEquals(emptyList<UsbLinkInfo>(), UsbDescriptors.links(interfaces, ccidDevice(tpdu), hidReport = ::neverRead, inPacketSize = { 64 }))
    }

    @Test
    fun doesNotOfferASmartcardInterfaceWithoutAClassDescriptor() {
        val interfaces = listOf(UsbInterfaceInfo(number = 0, klass = 0x0B, subclass = 0, protocol = 0))
        val whole = ccidDevice(extendedApdu)

        assertNull(UsbDescriptors.ccidClass(ByteArray(0), 0))
        assertNull(UsbDescriptors.ccidClass(whole, 1))
        // Cut in the middle of the class descriptor
        assertNull(UsbDescriptors.ccidClass(whole.copyOf(18 + 9 + 9 + 30), 0))
        // A descriptor that says it has no length
        assertNull(UsbDescriptors.ccidClass(hex("00 00 00 00"), 0))
        assertEquals(emptyList<UsbLinkInfo>(), UsbDescriptors.links(interfaces, ByteArray(0), hidReport = ::neverRead, inPacketSize = { 64 }))
    }

    @Test
    fun givesBothLinksOfAKeyWithAKeyboardAndNeverReadsTheKeyboard() {
        val interfaces = listOf(keyboard, fido, ccid)
        val read = ArrayList<Int>()

        assertTrue(UsbDescriptors.isCandidate(interfaces))
        assertEquals(
            listOf(
                UsbLinkInfo("usbHid", interfaceNumber = 1, extendedLength = false, frameSize = 64),
                UsbLinkInfo("usbCcid", interfaceNumber = 2, extendedLength = true, frameSize = 3072),
            ),
            UsbDescriptors.links(
                interfaces,
                composite,
                hidReport = { info ->
                    read += info.number
                    fidoReport
                },
                inPacketSize = { 64 },
            ),
        )
        assertEquals(listOf(1), read)
    }

    @Test
    fun findsEachInterfacesOwnClassDescriptor() {
        assertEquals(150, composite.size - 18)
        assertEquals(0x47, UsbDescriptors.hidReportLength(composite, 0))
        assertEquals(34, UsbDescriptors.hidReportLength(composite, 1))
        // The smartcard interface has no HID descriptor, and the HID interfaces no smartcard one
        assertNull(UsbDescriptors.hidReportLength(composite, 2))
        assertNull(UsbDescriptors.ccidClass(composite, 0))
        assertNull(UsbDescriptors.ccidClass(composite, 1))
        assertEquals(CcidClass(features = 0x00040840, maxMessageLength = 3072), UsbDescriptors.ccidClass(composite, 2))
    }
}
