package ohos_app_cangjie_entry.core.mtproto

/**
 * Calls tab "Create Call Link" (iOS CallListController.createGroupCall → engine.calls.createConferenceCall).
 *   phone.createConferenceCall#7d0444bb flags:# muted:flags.0?true video_stopped:flags.2?true
 *     join:flags.3?true random_id:int public_key:flags.3?int256 block:flags.3?bytes
 *     params:flags.3?DataJSON = Updates
 *   iOS Api42.swift:12076 appendInt32(2097431739) = 0x7d0444bb; telegram_api.tl:2655.
 * iOS GroupCalls.swift:3348 sends flags = 0 (no join), so only random_id follows the flags word.
 */
public class PhoneCreateConferenceCall <: TLObject {
    public var randomId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x7d0444bb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        serializer.writeInt32(this.randomId)
    }
}
