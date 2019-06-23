import Foundation
import AsyncDisplayKit
import Display
import Postbox
import TelegramCore

struct ChatMessageItemWidthFill {
    let compactInset: CGFloat
    let compactWidthBoundary: CGFloat
    let freeMaximumFillFactor: CGFloat
    
    func widthFor(_ width: CGFloat) -> CGFloat {
        if width <= self.compactWidthBoundary {
            return max(1.0, width - self.compactInset)
        } else {
            return max(1.0, floor(width * self.freeMaximumFillFactor))
        }
    }
}

struct ChatMessageItemBubbleLayoutConstants {
    let edgeInset: CGFloat
    let defaultSpacing: CGFloat
    let mergedSpacing: CGFloat
    let maximumWidthFill: ChatMessageItemWidthFill
    let minimumSize: CGSize
    let contentInsets: UIEdgeInsets
    let borderInset: CGFloat
}

struct ChatMessageItemTextLayoutConstants {
    let bubbleInsets: UIEdgeInsets
}

struct ChatMessageItemImageLayoutConstants {
    let bubbleInsets: UIEdgeInsets
    let statusInsets: UIEdgeInsets
    let defaultCornerRadius: CGFloat
    let mergedCornerRadius: CGFloat
    let contentMergedCornerRadius: CGFloat
    let maxDimensions: CGSize
    let minDimensions: CGSize
}

struct ChatMessageItemVideoLayoutConstants {
    let maxHorizontalHeight: CGFloat
    let maxVerticalHeight: CGFloat
}

struct ChatMessageItemInstantVideoConstants {
    let insets: UIEdgeInsets
    let dimensions: CGSize
}

struct ChatMessageItemFileLayoutConstants {
    let bubbleInsets: UIEdgeInsets
}

struct ChatMessageItemWallpaperLayoutConstants {
    let maxTextWidth: CGFloat
}

struct ChatMessageItemLayoutConstants {
    let avatarDiameter: CGFloat
    let timestampHeaderHeight: CGFloat
    
    let bubble: ChatMessageItemBubbleLayoutConstants
    let image: ChatMessageItemImageLayoutConstants
    let video: ChatMessageItemVideoLayoutConstants
    let text: ChatMessageItemTextLayoutConstants
    let file: ChatMessageItemFileLayoutConstants
    let instantVideo: ChatMessageItemInstantVideoConstants
    let wallpapers: ChatMessageItemWallpaperLayoutConstants
    
    init() {
        self.avatarDiameter = 37.0
        self.timestampHeaderHeight = 34.0
        
        self.bubble = ChatMessageItemBubbleLayoutConstants(edgeInset: 4.0, defaultSpacing: 2.0 + UIScreenPixel, mergedSpacing: 1.0, maximumWidthFill: ChatMessageItemWidthFill(compactInset: 36.0, compactWidthBoundary: 500.0, freeMaximumFillFactor: 0.85), minimumSize: CGSize(width: 40.0, height: 35.0), contentInsets: UIEdgeInsets(top: 0.0, left: 6.0, bottom: 0.0, right: 0.0), borderInset: UIScreenPixel)
        self.text = ChatMessageItemTextLayoutConstants(bubbleInsets: UIEdgeInsets(top: 6.0 + UIScreenPixel, left: 12.0, bottom: 6.0 - UIScreenPixel, right: 12.0))
        self.image = ChatMessageItemImageLayoutConstants(bubbleInsets: UIEdgeInsets(top: 1.0 + UIScreenPixel, left: 1.0 + UIScreenPixel, bottom: 1.0 + UIScreenPixel, right: 1.0 + UIScreenPixel), statusInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 6.0, right: 6.0), defaultCornerRadius: 17.0, mergedCornerRadius: 5.0, contentMergedCornerRadius: 5.0, maxDimensions: CGSize(width: 300.0, height: 300.0), minDimensions: CGSize(width: 170.0, height: 74.0))
        self.video = ChatMessageItemVideoLayoutConstants(maxHorizontalHeight: 250.0, maxVerticalHeight: 360.0)
        self.file = ChatMessageItemFileLayoutConstants(bubbleInsets: UIEdgeInsets(top: 15.0, left: 9.0, bottom: 15.0, right: 12.0))
        self.instantVideo = ChatMessageItemInstantVideoConstants(insets: UIEdgeInsets(top: 4.0, left: 0.0, bottom: 4.0, right: 0.0), dimensions: CGSize(width: 212.0, height: 212.0))
        self.wallpapers = ChatMessageItemWallpaperLayoutConstants(maxTextWidth: 180.0)
    }
}

enum ChatMessageItemBottomNeighbor {
    case none
    case merged(semi: Bool)
}

let defaultChatMessageItemLayoutConstants = ChatMessageItemLayoutConstants()

enum ChatMessagePeekPreviewContent {
    case media(Media)
    case url(ASDisplayNode, CGRect, String)
}

private let voiceMessageDurationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .spellOut
    formatter.allowedUnits = [.second]
    formatter.zeroFormattingBehavior = .pad
    return formatter
}()

private let musicDurationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .spellOut
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter
}()

private let fileSizeFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowsNonnumericFormatting = true
    return formatter
}()

enum ChatMessageAccessibilityCustomActionType {
    case reply
    case options
}

final class ChatMessageAccessibilityCustomAction: UIAccessibilityCustomAction {
    let action: ChatMessageAccessibilityCustomActionType
    
    init(name: String, target: Any?, selector: Selector, action: ChatMessageAccessibilityCustomActionType) {
        self.action = action
        
        super.init(name: name, target: target, selector: selector)
    }
}

final class ChatMessageAccessibilityData {
    let label: String?
    let value: String?
    let hint: String?
    let traits: UIAccessibilityTraits
    let customActions: [ChatMessageAccessibilityCustomAction]?
    let singleUrl: String?
    
    init(item: ChatMessageItem, isSelected: Bool?) {
        var label: String = ""
        let value: String
        var hint: String?
        var traits: UIAccessibilityTraits = 0
        var singleUrl: String?
        
        var customActions: [ChatMessageAccessibilityCustomAction] = []
        
        let isIncoming = item.message.effectivelyIncoming(item.context.account.peerId)
        var announceIncomingAuthors = false
        if let peer = item.message.peers[item.message.id.peerId] {
            if peer is TelegramGroup {
                announceIncomingAuthors = true
            } else if let channel = peer as? TelegramChannel, case .group = channel.info {
                announceIncomingAuthors = true
            }
        }
        
        let authorName = item.message.author?.displayTitle
        
        if let chatPeer = item.message.peers[item.message.id.peerId] {
            let (_, _, messageText) = chatListItemStrings(strings: item.presentationData.strings, nameDisplayOrder: item.presentationData.nameDisplayOrder, message: item.message, chatPeer: RenderedPeer(peer: chatPeer), accountPeerId: item.context.account.peerId, isPeerGroup: false)
            
            var text = messageText
            
            loop: for media in item.message.media {
                if let _ = media as? TelegramMediaImage {
                    if isIncoming {
                        if announceIncomingAuthors, let authorName = authorName {
                            label = "Photo, from: \(authorName)"
                        } else {
                            label = "Photo"
                        }
                    } else {
                        label = "Your photo"
                    }
                    text = ""
                    if !item.message.text.isEmpty {
                        text.append("\nCaption: \(item.message.text)")
                    }
                } else if let file = media as? TelegramMediaFile {
                    var isSpecialFile = false
                    for attribute in file.attributes {
                        switch attribute {
                            case let .Audio(audio):
                                isSpecialFile = true
                                if isSelected == nil {
                                    hint = "Double tap to play"
                                }
                                traits |= UIAccessibilityTraitStartsMediaSession
                                if audio.isVoice {
                                    let durationString = voiceMessageDurationFormatter.string(from: Double(audio.duration)) ?? ""
                                    if isIncoming {
                                        if announceIncomingAuthors, let authorName = authorName {
                                            label = "Voice message, from: \(authorName)"
                                        } else {
                                            label = "Voice message"
                                        }
                                    } else {
                                        label = "Your voice message"
                                    }
                                    text = "Duration: \(durationString)"
                                } else {
                                    let durationString = musicDurationFormatter.string(from: Double(audio.duration)) ?? ""
                                    if isIncoming {
                                        if announceIncomingAuthors, let authorName = authorName {
                                            label = "Music file, from: \(authorName)"
                                        } else {
                                            label = "Music file"
                                        }
                                    } else {
                                        label = "Your music file"
                                    }
                                    let performer = audio.performer ?? "Unknown"
                                    let title = audio.title ?? "Unknown"
                                    text = "\(title), by \(performer). Duration: \(durationString)"
                                }
                            case let .Video(video):
                                isSpecialFile = true
                                if isSelected == nil {
                                    hint = "Double tap to play"
                                }
                                traits |= UIAccessibilityTraitStartsMediaSession
                                let durationString = voiceMessageDurationFormatter.string(from: Double(video.duration)) ?? ""
                                if video.flags.contains(.instantRoundVideo) {
                                    if isIncoming {
                                        if announceIncomingAuthors, let authorName = authorName {
                                            label = "Video message, from: \(authorName)"
                                        } else {
                                            label = "Video message"
                                        }
                                    } else {
                                        label = "Your video message"
                                    }
                                } else {
                                    if isIncoming {
                                        if announceIncomingAuthors, let authorName = authorName {
                                            label = "Video, from: \(authorName)"
                                        } else {
                                            label = "Video"
                                        }
                                    } else {
                                        label = "Your video"
                                    }
                                }
                                text = "Duration: \(durationString)"
                            default:
                                break
                        }
                    }
                    if !isSpecialFile {
                        if isSelected == nil {
                            hint = "Double tap to open"
                        }
                        let sizeString = fileSizeFormatter.string(fromByteCount: Int64(file.size ?? 0))
                        if isIncoming {
                            if announceIncomingAuthors, let authorName = authorName {
                                label = "File, from: \(authorName)"
                            } else {
                                label = "File"
                            }
                        } else {
                            label = "Your file"
                        }
                        text = "\(file.fileName ?? ""). Size: \(sizeString)"
                    }
                    if !item.message.text.isEmpty {
                        text.append("\nCaption: \(item.message.text)")
                    }
                    break loop
                } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
                    var contentText = "Page preview. "
                    if let title = content.title, !title.isEmpty {
                        contentText.append("Title: \(title). ")
                    }
                    if let text = content.text, !text.isEmpty {
                        contentText.append(text)
                    }
                    text = "\(item.message.text)\n\(contentText)"
                } else if let contact = media as? TelegramMediaContact {
                    if isIncoming {
                        if announceIncomingAuthors, let authorName = authorName {
                            label = "Shared contact, from: \(authorName)"
                        } else {
                            label = "Shared contact"
                        }
                    } else {
                        label = "Your shared contact"
                    }
                    var displayName = ""
                    if !contact.firstName.isEmpty {
                        displayName.append(contact.firstName)
                    }
                    if !contact.lastName.isEmpty {
                        if !displayName.isEmpty {
                            displayName.append(" ")
                        }
                        displayName.append(contact.lastName)
                    }
                    var phoneNumbersString = ""
                    var phoneNumberCount = 0
                    var emailAddressesString = ""
                    var emailAddressCount = 0
                    var organizationString = ""
                    if let vCard = contact.vCardData, let vCardData = vCard.data(using: .utf8), let contactData = DeviceContactExtendedData(vcard: vCardData) {
                        if displayName.isEmpty && !contactData.organization.isEmpty {
                            displayName = contactData.organization
                        }
                        if !contactData.basicData.phoneNumbers.isEmpty {
                            for phone in contactData.basicData.phoneNumbers {
                                if !phoneNumbersString.isEmpty {
                                    phoneNumbersString.append(", ")
                                }
                                for c in phone.value {
                                    phoneNumbersString.append(c)
                                    phoneNumbersString.append(" ")
                                }
                                phoneNumberCount += 1
                            }
                        } else {
                            for c in contact.phoneNumber {
                                phoneNumbersString.append(c)
                                phoneNumbersString.append(" ")
                            }
                            phoneNumberCount += 1
                        }
                        
                        for email in contactData.emailAddresses {
                            if !emailAddressesString.isEmpty {
                                emailAddressesString.append(", ")
                            }
                            emailAddressesString.append("\(email.value)")
                            emailAddressCount += 1
                        }
                        if !contactData.organization.isEmpty && displayName != contactData.organization {
                            organizationString = contactData.organization
                        }
                    } else {
                        phoneNumbersString.append("\(contact.phoneNumber)")
                    }
                    text = "\(displayName)."
                    if !phoneNumbersString.isEmpty {
                        if phoneNumberCount > 1 {
                            text.append("\(phoneNumberCount) phone numbers: ")
                        } else {
                            text.append("Phone number: ")
                        }
                        text.append("\(phoneNumbersString). ")
                    }
                    if !emailAddressesString.isEmpty {
                        if emailAddressCount > 1 {
                            text.append("\(emailAddressCount) email addresses: ")
                        } else {
                            text.append("Email: ")
                        }
                        text.append("\(emailAddressesString). ")
                    }
                    if !organizationString.isEmpty {
                        text.append("Organization: \(organizationString).")
                    }
                } else if let poll = media as? TelegramMediaPoll {
                    if isIncoming {
                        if announceIncomingAuthors, let authorName = authorName {
                            label = "Anonymous poll, from: \(authorName)"
                        } else {
                            label = "Anonymous poll"
                        }
                    } else {
                        label = "Your anonymous poll"
                    }
                    
                    var optionVoterCount: [Int: Int32] = [:]
                    var maxOptionVoterCount: Int32 = 0
                    var totalVoterCount: Int32 = 0
                    let voters: [TelegramMediaPollOptionVoters]?
                    if poll.isClosed {
                        voters = poll.results.voters ?? []
                    } else {
                        voters = poll.results.voters
                    }
                    var selectedOptionId: Data?
                    if let voters = voters, let totalVoters = poll.results.totalVoters {
                        var didVote = false
                        for voter in voters {
                            if voter.selected {
                                didVote = true
                                selectedOptionId = voter.opaqueIdentifier
                            }
                        }
                        totalVoterCount = totalVoters
                        if didVote || poll.isClosed {
                            for i in 0 ..< poll.options.count {
                                inner: for optionVoters in voters {
                                    if optionVoters.opaqueIdentifier == poll.options[i].opaqueIdentifier {
                                        optionVoterCount[i] = optionVoters.count
                                        maxOptionVoterCount = max(maxOptionVoterCount, optionVoters.count)
                                        break inner
                                    }
                                }
                            }
                        }
                    }
                    
                    var optionVoterCounts: [Int]
                    if totalVoterCount != 0 {
                        optionVoterCounts = countNicePercent(votes: (0 ..< poll.options.count).map({ Int(optionVoterCount[$0] ?? 0) }), total: Int(totalVoterCount))
                    } else {
                        optionVoterCounts = Array(repeating: 0, count: poll.options.count)
                    }
                    
                    text = "Title: \(poll.text). "
                    
                    text.append("\(poll.options.count) options: ")
                    var optionsText = ""
                    for i in 0 ..< poll.options.count {
                        let option = poll.options[i]
                        
                        if !optionsText.isEmpty {
                            optionsText.append(", ")
                        }
                        optionsText.append(option.text)
                        if let selectedOptionId = selectedOptionId, selectedOptionId == option.opaqueIdentifier {
                            optionsText.append(", selected")
                        }
                        
                        if let _ = optionVoterCount[i] {
                            if maxOptionVoterCount != 0 && totalVoterCount != 0 {
                                optionsText.append(", \(optionVoterCounts[i])%")
                            }
                        }
                    }
                    text.append("\(optionsText). ")
                    if totalVoterCount != 0 {
                        if totalVoterCount == 1 {
                            text.append("1 vote. ")
                        } else {
                            text.append("\(totalVoterCount) votes. ")
                        }
                    } else {
                        text.append("No votes. ")
                    }
                    if poll.isClosed {
                        text.append("Final results. ")
                    }
                }
            }
            
            var result = ""
            
            if let isSelected = isSelected {
                if isSelected {
                    result += "Selected.\n"
                }
                traits |= UIAccessibilityTraitStartsMediaSession
            }
            
            result += "\(text)"
            
            let dateString = DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(item.message.timestamp)), dateStyle: .medium, timeStyle: .short)
            
            result += "\n\(dateString)"
            if !isIncoming && item.read {
                if announceIncomingAuthors {
                    result += "Seen by recipients"
                } else {
                    result += "Seen by recipient"
                }
            }
            value = result
        } else {
            value = ""
        }
        
        if label.isEmpty {
            if let author = item.message.author {
                if isIncoming {
                    label = author.displayTitle
                } else {
                    label = "Your message"
                }
            } else {
                label = "Message"
            }
        }
        
        for attribute in item.message.attributes {
            if let attribute = attribute as? TextEntitiesMessageAttribute {
                var hasUrls = false
                loop: for entity in attribute.entities {
                    switch entity.type {
                        case .Url:
                            if hasUrls {
                                singleUrl = nil
                                break loop
                            } else {
                                if let range = Range<String.Index>(NSRange(location: entity.range.lowerBound, length: entity.range.count), in: item.message.text) {
                                    singleUrl = String(item.message.text[range])
                                    hasUrls = true
                                }
                            }
                        case let .TextUrl(url):
                            if hasUrls {
                                singleUrl = nil
                                break loop
                            } else {
                                singleUrl = url
                                hasUrls = true
                            }
                        default:
                            break
                    }
                }
            } else if let attribute = attribute as? ReplyMessageAttribute, let replyMessage = item.message.associatedMessages[attribute.messageId] {
                let replyLabel: String
                if replyMessage.flags.contains(.Incoming) {
                    if let author = replyMessage.author {
                        replyLabel = "Reply to message from \(author.displayTitle)"
                    } else {
                        replyLabel = "Reply to message"
                    }
                } else {
                    replyLabel = "Reply to your message"
                }
                label = "\(replyLabel) . \(label)"
            }
        }
        
        if hint == nil && singleUrl != nil {
            hint = "Double tap to open link"
        }
        
        if let forwardInfo = item.message.forwardInfo {
            let forwardLabel: String
            if let author = forwardInfo.author, author.id == item.context.account.peerId {
                forwardLabel = "Forwarded from you"
            } else {
                let peerString: String
                if let peer = forwardInfo.author {
                    if let authorName = forwardInfo.authorSignature {
                        peerString = "\(peer.displayTitle(strings: item.presentationData.strings, displayOrder: item.presentationData.nameDisplayOrder)) (\(authorName))"
                    } else {
                        peerString = peer.displayTitle(strings: item.presentationData.strings, displayOrder: item.presentationData.nameDisplayOrder)
                    }
                } else if let authorName = forwardInfo.authorSignature {
                    peerString = authorName
                } else {
                    peerString = ""
                }
                forwardLabel = "Forwarded from \(peerString)"
            }
            label = "\(forwardLabel). \(label)"
        }
        
        if isSelected == nil {
            var canReply = item.controllerInteraction.canSetupReply(item.message)
            for media in item.content.firstMessage.media {
                if let _ = media as? TelegramMediaExpiredContent {
                    canReply = false
                }
                else if let media = media as? TelegramMediaAction {
                    if case .phoneCall(_, _, _) = media.action {
                    } else {
                        canReply = false
                    }
                }
            }
            
            if canReply {
                customActions.append(ChatMessageAccessibilityCustomAction(name: "Reply", target: nil, selector: #selector(self.noop), action: .reply))
            }
            customActions.append(ChatMessageAccessibilityCustomAction(name: "Open message menu", target: nil, selector: #selector(self.noop), action: .options))
        }
        
        self.label = label
        self.value = value
        self.hint = hint
        self.traits = traits
        self.customActions = customActions.isEmpty ? nil : customActions
        self.singleUrl = singleUrl
    }
    
    @objc private func noop() {
    }
}

public class ChatMessageItemView: ListViewItemNode {
    let layoutConstants = defaultChatMessageItemLayoutConstants
    
    var item: ChatMessageItem?
    var accessibilityData: ChatMessageAccessibilityData?
    
    public required convenience init() {
        self.init(layerBacked: false)
    }
    
    public init(layerBacked: Bool) {
        super.init(layerBacked: layerBacked, dynamicBounce: true, rotated: true)
        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func reuse() {
        super.reuse()
        
        self.item = nil
        self.frame = CGRect()
    }
    
    func setupItem(_ item: ChatMessageItem) {
        self.item = item
    }
    
    func updateAccessibilityData(_ accessibilityData: ChatMessageAccessibilityData) {
        self.accessibilityData = accessibilityData
    }
    
    override public func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, previousItem: ListViewItem?, nextItem: ListViewItem?) {
        if let item = item as? ChatMessageItem {
            let doLayout = self.asyncLayout()
            let merged = item.mergedWithItems(top: previousItem, bottom: nextItem)
            let (layout, apply) = doLayout(item, params, merged.top, merged.bottom, merged.dateAtBottom)
            self.contentSize = layout.contentSize
            self.insets = layout.insets
            apply(.None, false)
        }
    }
    
    override public func layoutAccessoryItemNode(_ accessoryItemNode: ListViewAccessoryItemNode, leftInset: CGFloat, rightInset: CGFloat) {
        if let avatarNode = accessoryItemNode as? ChatMessageAvatarAccessoryItemNode {
            avatarNode.frame = CGRect(origin: CGPoint(x: leftInset + 3.0, y: self.apparentFrame.height - 38.0 - self.insets.top - 2.0 - UIScreenPixel), size: CGSize(width: 38.0, height: 38.0))
        }
    }
    
    override public func animateInsertion(_ currentTimestamp: Double, duration: Double, short: Bool) {
        if short {
            //self.layer.animateBoundsOriginYAdditive(from: -self.bounds.size.height, to: 0.0, duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring)
        } else {
            self.transitionOffset = -self.bounds.size.height * 1.6
            self.addTransitionOffsetAnimation(0.0, duration: duration, beginAt: currentTimestamp)
        }
    }
    
    func asyncLayout() -> (_ item: ChatMessageItem, _ params: ListViewItemLayoutParams, _ mergedTop: ChatMessageMerge, _ mergedBottom: ChatMessageMerge, _ dateHeaderAtBottom: Bool) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation, Bool) -> Void) {
        return { _, _, _, _, _ in
            return (ListViewItemNodeLayout(contentSize: CGSize(width: 32.0, height: 32.0), insets: UIEdgeInsets()), { _, _ in
                
            })
        }
    }
    
    func transitionNode(id: MessageId, media: Media) -> (ASDisplayNode, () -> (UIView?, UIView?))? {
        return nil
    }
    
    func peekPreviewContent(at point: CGPoint) -> (Message, ChatMessagePeekPreviewContent)? {
        return nil
    }
    
    func updateHiddenMedia() {
    }
    
    func updateSelectionState(animated: Bool) {
    }
    
    func updateSearchTextHighlightState() {
    }
    
    func updateHighlightedState(animated: Bool) {
        var isHighlightedInOverlay = false
        if let item = self.item, let contextHighlightedState = item.controllerInteraction.contextHighlightedState {
            switch item.content {
                case let .message(message, _, _, _):
                    if contextHighlightedState.messageStableId == message.stableId {
                        isHighlightedInOverlay = true
                    }
                case let .group(messages):
                    for (message, _, _, _) in messages {
                        if contextHighlightedState.messageStableId == message.stableId {
                            isHighlightedInOverlay = true
                            break
                        }
                    }
            }
        }
        self.isHighlightedInOverlay = isHighlightedInOverlay
    }
    
    func updateAutomaticMediaDownloadSettings() {
    }
    
    func playMediaWithSound() -> ((Double?) -> Void, Bool, Bool, Bool, ASDisplayNode?)? {
        return nil
    }
    
    override public func header() -> ListViewItemHeader? {
        if let item = self.item {
            return item.header
        } else {
            return nil
        }
    }
    
    func performMessageButtonAction(button: ReplyMarkupButton) {
        if let item = self.item {
            switch button.action {
                case .text:
                    item.controllerInteraction.sendMessage(button.title)
                case let .url(url):
                    item.controllerInteraction.openUrl(url, true, nil)
                case .requestMap:
                    item.controllerInteraction.shareCurrentLocation()
                case .requestPhone:
                    item.controllerInteraction.shareAccountContact()
                case .openWebApp:
                    item.controllerInteraction.requestMessageActionCallback(item.message.id, nil, true)
                case let .callback(data):
                    item.controllerInteraction.requestMessageActionCallback(item.message.id, data, false)
                case let .switchInline(samePeer, query):
                    var botPeer: Peer?
                    
                    var found = false
                    for attribute in item.message.attributes {
                        if let attribute = attribute as? InlineBotMessageAttribute {
                            if let peerId = attribute.peerId {
                                botPeer = item.message.peers[peerId]
                                found = true
                            }
                        }
                    }
                    if !found {
                        botPeer = item.message.author
                    }
                    
                    var peerId: PeerId?
                    if samePeer {
                        peerId = item.message.id.peerId
                    }
                    if let botPeer = botPeer, let addressName = botPeer.addressName {
                        item.controllerInteraction.activateSwitchInline(peerId, "@\(addressName) \(query)")
                    }
                case .payment:
                    item.controllerInteraction.openCheckoutOrReceipt(item.message.id)
                case let .urlAuth(url, buttonId):
                    item.controllerInteraction.requestMessageActionUrlAuth(url, item.message.id, buttonId)
            }
        }
    }
    
    func presentMessageButtonContextMenu(button: ReplyMarkupButton) {
        if let item = self.item {
            switch button.action {
                case let .url(url):
                    item.controllerInteraction.longTap(.url(url), item.message)
                default:
                    break
            }
        }
    }
}
