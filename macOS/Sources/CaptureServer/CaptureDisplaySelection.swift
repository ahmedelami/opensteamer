/// Keeps an owned virtual framebuffer out of system-audio capture selection.
struct CaptureDisplaySelection: Equatable, Sendable {
    let screenDisplayID: UInt32?
    let systemAudioDisplayID: UInt32?

    init(explicitDisplayID: UInt32?, virtualDisplayID: UInt32?) {
        screenDisplayID = virtualDisplayID ?? explicitDisplayID
        systemAudioDisplayID = explicitDisplayID
    }
}
