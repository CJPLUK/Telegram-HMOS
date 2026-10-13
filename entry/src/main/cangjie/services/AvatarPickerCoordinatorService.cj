package ohos_app_cangjie_entry.services

private var avatarPickerPresentationPending: Bool = false

public func requestAvatarPickerPresentation(): Unit {
    avatarPickerPresentationPending = true
}

public func consumeAvatarPickerPresentation(): Bool {
    let pending = avatarPickerPresentationPending
    avatarPickerPresentationPending = false
    return pending
}
