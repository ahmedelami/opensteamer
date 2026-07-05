import AudioToolbox
import Foundation

public protocol PCMFrameProvider: AnyObject, Sendable {
    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>)
}
