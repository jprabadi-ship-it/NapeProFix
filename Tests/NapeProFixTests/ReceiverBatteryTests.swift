import Testing
@testable import NapeProFix

/// Replies captured from a Link-KM receiver with the Nape Pro (FW v1.3.0) on
/// it, and from a K17 Pro keyboard on USB.
@Test func readsLevelFromReceiverReply() {
    let reply: [UInt8] = [0xA7, 0x31, 0x61, 0x00] + [UInt8](repeating: 0, count: 28)
    #expect(ReceiverBattery.level(fromReport: reply) == 97)
}

@Test func ignoresRepliesThatAreNotTheBatteryAnswer() {
    // A keyboard rejecting the sub-command.
    #expect(ReceiverBattery.level(fromReport: [0xFF, 0x31, 0x00, 0x00]) == nil)
    // The firmware version reply ("v1.3.0…").
    #expect(ReceiverBattery.level(fromReport: [0xA1, 0x76, 0x31, 0x2E]) == nil)
    #expect(ReceiverBattery.level(fromReport: [0xA7, 0x31]) == nil)
}

@Test func clampsLevelToOneHundred() {
    #expect(ReceiverBattery.level(fromReport: [0xA7, 0x31, 0xFF]) == 100)
}
