import Foundation
import Postbox
import SwiftSignalKit

final class ApplicationSpecificBoolNotice: NoticeEntry {
    init() {
    }
    
    init(decoder: PostboxDecoder) {
    }
    
    func encode(_ encoder: PostboxEncoder) {
    }
    
    func isEqual(to: NoticeEntry) -> Bool {
        if let _ = to as? ApplicationSpecificBoolNotice {
            return true
        } else {
            return false
        }
    }
}

final class ApplicationSpecificVariantNotice: NoticeEntry {
    let value: Bool
    
    init(value: Bool) {
        self.value = value
    }
    
    init(decoder: PostboxDecoder) {
        self.value = decoder.decodeInt32ForKey("v", orElse: 0) != 0
    }
    
    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.value ? 1 : 0, forKey: "v")
    }
    
    func isEqual(to: NoticeEntry) -> Bool {
        if let to = to as? ApplicationSpecificVariantNotice {
            if self.value != to.value {
                return false
            }
            return true
        } else {
            return false
        }
    }
}

final class ApplicationSpecificCounterNotice: NoticeEntry {
    let value: Int32
    
    init(value: Int32) {
        self.value = value
    }
    
    init(decoder: PostboxDecoder) {
        self.value = decoder.decodeInt32ForKey("v", orElse: 0)
    }
    
    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.value, forKey: "v")
    }
    
    func isEqual(to: NoticeEntry) -> Bool {
        if let to = to as? ApplicationSpecificCounterNotice {
            if self.value != to.value {
                return false
            }
            return true
        } else {
            return false
        }
    }
}

final class ApplicationSpecificTimestampNotice: NoticeEntry {
    let value: Int32
    
    init(value: Int32) {
        self.value = value
    }
    
    init(decoder: PostboxDecoder) {
        self.value = decoder.decodeInt32ForKey("v", orElse: 0)
    }
    
    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.value, forKey: "v")
    }
    
    func isEqual(to: NoticeEntry) -> Bool {
        if let to = to as? ApplicationSpecificTimestampNotice {
            if self.value != to.value {
                return false
            }
            return true
        } else {
            return false
        }
    }
}

private func noticeNamespace(namespace: Int32) -> ValueBoxKey {
    let key = ValueBoxKey(length: 4)
    key.setInt32(0, value: namespace)
    return key
}

private func noticeKey(peerId: PeerId, key: Int32) -> ValueBoxKey {
    let v = ValueBoxKey(length: 8 + 4)
    v.setInt64(0, value: peerId.toInt64())
    v.setInt32(8, value: key)
    return v
}

private enum ApplicationSpecificGlobalNotice: Int32 {
    case secretChatInlineBotUsage = 0
    case secretChatLinkPreviews = 1
    case proxyAdsAcknowledgment = 2
    case chatMediaMediaRecordingTips = 3
    case profileCallTips = 4
    case setPublicChannelLink = 5
    case passcodeLockTips = 6
    case contactsPermissionWarning = 7
    case notificationsPermissionWarning = 8
    case volumeButtonToUnmuteTip = 9
    case archiveChatTips = 10
    case archiveIntroDismissed = 11
    case callsTabTip = 12
    case notificationsPermissionTabBarWarningMute = 13
    
    var key: ValueBoxKey {
        let v = ValueBoxKey(length: 4)
        v.setInt32(0, value: self.rawValue)
        return v
    }
}

private struct ApplicationSpecificNoticeKeys {
    private static let botPaymentLiabilityNamespace: Int32 = 1
    private static let globalNamespace: Int32 = 2
    private static let permissionsNamespace: Int32 = 3
    
    static func botPaymentLiabilityNotice(peerId: PeerId) -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: botPaymentLiabilityNamespace), key: noticeKey(peerId: peerId, key: 0))
    }
    
    static func secretChatInlineBotUsage() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.secretChatInlineBotUsage.key)
    }
    
    static func secretChatLinkPreviews() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.secretChatLinkPreviews.key)
    }
    
    static func archiveIntroDismissed() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.archiveIntroDismissed.key)
    }
    
    static func chatMediaMediaRecordingTips() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.chatMediaMediaRecordingTips.key)
    }
    
    static func archiveChatTips() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.archiveChatTips.key)
    }
    
    static func profileCallTips() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.profileCallTips.key)
    }
    
    static func proxyAdsAcknowledgment() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.proxyAdsAcknowledgment.key)
    }
    
    static func setPublicChannelLink() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.setPublicChannelLink.key)
    }
    
    static func passcodeLockTips() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.passcodeLockTips.key)
    }
    
    static func contactsPermissionWarning() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: permissionsNamespace), key: ApplicationSpecificGlobalNotice.contactsPermissionWarning.key)
    }
    
    static func notificationsPermissionWarning() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: permissionsNamespace), key: ApplicationSpecificGlobalNotice.notificationsPermissionWarning.key)
    }

    static func notificationsPermissionTabBarWarningMute() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: permissionsNamespace), key: ApplicationSpecificGlobalNotice.notificationsPermissionTabBarWarningMute.key)
    }
    
    static func volumeButtonToUnmuteTip() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.volumeButtonToUnmuteTip.key)
    }
    
    static func callsTabTip() -> NoticeEntryKey {
        return NoticeEntryKey(namespace: noticeNamespace(namespace: globalNamespace), key: ApplicationSpecificGlobalNotice.callsTabTip.key)
    }
}

public struct ApplicationSpecificNotice {
    static func getBotPaymentLiability(accountManager: AccountManager, peerId: PeerId) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            if let _ = transaction.getNotice(ApplicationSpecificNoticeKeys.botPaymentLiabilityNotice(peerId: peerId)) as? ApplicationSpecificBoolNotice {
                return true
            } else {
                return false
            }
        }
    }
    
    static func setBotPaymentLiability(accountManager: AccountManager, peerId: PeerId) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.botPaymentLiabilityNotice(peerId: peerId), ApplicationSpecificBoolNotice())
        }
    }
    
    static func getSecretChatInlineBotUsage(accountManager: AccountManager) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            if let _ = transaction.getNotice(ApplicationSpecificNoticeKeys.secretChatInlineBotUsage()) as? ApplicationSpecificBoolNotice {
                return true
            } else {
                return false
            }
        }
    }
    
    static func setSecretChatInlineBotUsage(accountManager: AccountManager) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.secretChatInlineBotUsage(), ApplicationSpecificBoolNotice())
        }
    }
    
    public static func setSecretChatInlineBotUsage(transaction: AccountManagerModifier) {
        transaction.setNotice(ApplicationSpecificNoticeKeys.secretChatInlineBotUsage(), ApplicationSpecificBoolNotice())
    }
    
    static func getSecretChatLinkPreviews(accountManager: AccountManager) -> Signal<Bool?, NoError> {
        return accountManager.transaction { transaction -> Bool? in
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.secretChatLinkPreviews()) as? ApplicationSpecificVariantNotice {
                return value.value
            } else {
                return nil
            }
        }
    }
    
    static func getSecretChatLinkPreviews(_ entry: NoticeEntry) -> Bool? {
        if let value = entry as? ApplicationSpecificVariantNotice {
            return value.value
        } else {
            return nil
        }
    }
    
    static func setSecretChatLinkPreviews(accountManager: AccountManager, value: Bool) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.secretChatLinkPreviews(), ApplicationSpecificVariantNotice(value: value))
        }
    }
    
    public static func setSecretChatLinkPreviews(transaction: AccountManagerModifier, value: Bool) {
        transaction.setNotice(ApplicationSpecificNoticeKeys.secretChatLinkPreviews(), ApplicationSpecificVariantNotice(value: value))
    }
    
    static func secretChatLinkPreviewsKey() -> NoticeEntryKey {
        return ApplicationSpecificNoticeKeys.secretChatLinkPreviews()
    }
    
    static func getChatMediaMediaRecordingTips(accountManager: AccountManager) -> Signal<Int32, NoError> {
        return accountManager.transaction { transaction -> Int32 in
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.chatMediaMediaRecordingTips()) as? ApplicationSpecificCounterNotice {
                return value.value
            } else {
                return 0
            }
        }
    }
    
    static func incrementChatMediaMediaRecordingTips(accountManager: AccountManager, count: Int32 = 1) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            var currentValue: Int32 = 0
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.chatMediaMediaRecordingTips()) as? ApplicationSpecificCounterNotice {
                currentValue = value.value
            }
            currentValue += count
            
            transaction.setNotice(ApplicationSpecificNoticeKeys.chatMediaMediaRecordingTips(), ApplicationSpecificCounterNotice(value: currentValue))
        }
    }
    
    static func getArchiveChatTips(accountManager: AccountManager) -> Signal<Int32, NoError> {
        return accountManager.transaction { transaction -> Int32 in
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.archiveChatTips()) as? ApplicationSpecificCounterNotice {
                return value.value
            } else {
                return 0
            }
        }
    }
    
    static func incrementArchiveChatTips(accountManager: AccountManager, count: Int = 1) -> Signal<Int, NoError> {
        return accountManager.transaction { transaction -> Int in
            var currentValue: Int32 = 0
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.archiveChatTips()) as? ApplicationSpecificCounterNotice {
                currentValue = value.value
            }
            let previousValue = currentValue
            currentValue += Int32(count)
            
            transaction.setNotice(ApplicationSpecificNoticeKeys.archiveChatTips(), ApplicationSpecificCounterNotice(value: currentValue))
            
            return Int(previousValue)
        }
    }
    
    public static func setArchiveIntroDismissed(transaction: AccountManagerModifier, value: Bool) {
        transaction.setNotice(ApplicationSpecificNoticeKeys.archiveIntroDismissed(), ApplicationSpecificVariantNotice(value: value))
    }
    
    static func archiveIntroDismissedKey() -> NoticeEntryKey {
        return ApplicationSpecificNoticeKeys.archiveIntroDismissed()
    }
    
    static func getProfileCallTips(accountManager: AccountManager) -> Signal<Int32, NoError> {
        return accountManager.transaction { transaction -> Int32 in
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.profileCallTips()) as? ApplicationSpecificCounterNotice {
                return value.value
            } else {
                return 0
            }
        }
    }
    
    static func incrementProfileCallTips(accountManager: AccountManager, count: Int32 = 1) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            var currentValue: Int32 = 0
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.profileCallTips()) as? ApplicationSpecificCounterNotice {
                currentValue = value.value
            }
            currentValue += count
            
            transaction.setNotice(ApplicationSpecificNoticeKeys.profileCallTips(), ApplicationSpecificCounterNotice(value: currentValue))
        }
    }
    
    static func getSetPublicChannelLink(accountManager: AccountManager) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.profileCallTips()) as? ApplicationSpecificCounterNotice {
                return value.value < 1
            } else {
                return true
            }
        }
    }
    
    static func markAsSeenSetPublicChannelLink(accountManager: AccountManager) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.profileCallTips(), ApplicationSpecificCounterNotice(value: 1))
        }
    }
    
    static func getProxyAdsAcknowledgment(accountManager: AccountManager) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            if let _ = transaction.getNotice(ApplicationSpecificNoticeKeys.proxyAdsAcknowledgment()) as? ApplicationSpecificBoolNotice {
                return true
            } else {
                return false
            }
        }
    }
    
    static func setProxyAdsAcknowledgment(accountManager: AccountManager) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.proxyAdsAcknowledgment(), ApplicationSpecificBoolNotice())
        }
    }
    
    static func getPasscodeLockTips(accountManager: AccountManager) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            if let _ = transaction.getNotice(ApplicationSpecificNoticeKeys.passcodeLockTips()) as? ApplicationSpecificBoolNotice {
                return true
            } else {
                return false
            }
        }
    }
    
    static func setPasscodeLockTips(accountManager: AccountManager) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.passcodeLockTips(), ApplicationSpecificBoolNotice())
        }
    }
    
    public static func contactsPermissionWarningKey() -> NoticeEntryKey {
        return ApplicationSpecificNoticeKeys.contactsPermissionWarning()
    }
    
    public static func setContactsPermissionWarning(accountManager: AccountManager, value: Int32) {
        let _ =  accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.contactsPermissionWarning(), ApplicationSpecificTimestampNotice(value: value))
        }.start()
    }
    
    public static func notificationsPermissionWarningKey() -> NoticeEntryKey {
        return ApplicationSpecificNoticeKeys.notificationsPermissionWarning()
    }

    public static func notificationsPermissionTabBarWarningMuteKey() -> NoticeEntryKey {
        return ApplicationSpecificNoticeKeys.notificationsPermissionTabBarWarningMute()
    }
    
    public static func getTimestampValue(_ entry: NoticeEntry) -> Int32? {
        if let value = entry as? ApplicationSpecificTimestampNotice {
            return value.value
        } else {
            return nil
        }
    }
    
    public static func setNotificationsPermissionWarning(accountManager: AccountManager, value: Int32) {
        let _ = accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.notificationsPermissionWarning(), ApplicationSpecificTimestampNotice(value: value))
        }.start()
    }

    public static func setNotificationsPermissionTabBarWarningMute(accountManager: AccountManager, value: Bool) {
        let _ = accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.notificationsPermissionTabBarWarningMute(), ApplicationSpecificVariantNotice(value: value))
            }.start()
    }
    
    static func getVolumeButtonToUnmute(accountManager: AccountManager) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            if let _ = transaction.getNotice(ApplicationSpecificNoticeKeys.volumeButtonToUnmuteTip()) as? ApplicationSpecificBoolNotice {
                return true
            } else {
                return false
            }
        }
    }
    
    public static func setVolumeButtonToUnmute(accountManager: AccountManager) {
        let _ = accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.volumeButtonToUnmuteTip(), ApplicationSpecificBoolNotice())
        }.start()
    }
    
    static func getCallsTabTip(accountManager: AccountManager) -> Signal<Int32, NoError> {
        return accountManager.transaction { transaction -> Int32 in
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.callsTabTip()) as? ApplicationSpecificCounterNotice {
                return value.value
            } else {
                return 0
            }
        }
    }
    
    static func incrementCallsTabTips(accountManager: AccountManager, count: Int = 1) -> Signal<Int, NoError> {
        return accountManager.transaction { transaction -> Int in
            var currentValue: Int32 = 0
            if let value = transaction.getNotice(ApplicationSpecificNoticeKeys.callsTabTip()) as? ApplicationSpecificCounterNotice {
                currentValue = value.value
            }
            let previousValue = currentValue
            currentValue += min(3, Int32(count))
            
            transaction.setNotice(ApplicationSpecificNoticeKeys.callsTabTip(), ApplicationSpecificCounterNotice(value: currentValue))
            
            return Int(previousValue)
        }
    }
    
    static func setCallsTabTip(accountManager: AccountManager) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
            transaction.setNotice(ApplicationSpecificNoticeKeys.callsTabTip(), ApplicationSpecificBoolNotice())
        }
    }

    static func reset(accountManager: AccountManager) -> Signal<Void, NoError> {
        return accountManager.transaction { transaction -> Void in
        }
    }
}
