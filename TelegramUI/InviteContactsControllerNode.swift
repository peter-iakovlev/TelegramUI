import Display
import AsyncDisplayKit
import UIKit
import Postbox
import TelegramCore
import SwiftSignalKit

private enum InviteContactsEntryId: Hashable {
    case option(index: Int)
    case contactId(String)
    
    var hashValue: Int {
        switch self {
            case let .option(index):
                return (index + 2).hashValue
            case let .contactId(contactId):
                return contactId.hashValue
        }
    }
    
    static func <(lhs: InviteContactsEntryId, rhs: InviteContactsEntryId) -> Bool {
        return lhs.hashValue < rhs.hashValue
    }
    
    static func ==(lhs: InviteContactsEntryId, rhs: InviteContactsEntryId) -> Bool {
        switch lhs {
            case let .option(index):
                if case .option(index) = rhs {
                    return true
                } else {
                    return false
                }
            case let .contactId(lhsId):
                switch rhs {
                    case let .contactId(rhsId):
                        return lhsId == rhsId
                    default:
                        return false
                }
        }
    }
}

private final class InviteContactsInteraction {
    let toggleContact: (String) -> Void
    let shareTelegram: () -> Void
    
    init(toggleContact: @escaping (String) -> Void, shareTelegram: @escaping () -> Void) {
        self.toggleContact = toggleContact
        self.shareTelegram = shareTelegram
    }
}

private enum InviteContactsEntry: Comparable, Identifiable {
    case option(Int, ContactListAdditionalOption, PresentationTheme, PresentationStrings)
    case peer(Int, DeviceContactStableId, DeviceContactBasicData, Int32, ContactsPeerItemSelection, PresentationTheme, PresentationStrings, PresentationPersonNameOrder, PresentationPersonNameOrder)
    
    var stableId: InviteContactsEntryId {
        switch self {
            case let .option(index, _, _, _):
                return .option(index: index)
            case let .peer(_, id, _, _, _, _, _, _, _):
                return .contactId(id)
        }
    }
    
    func item(account: Account, interaction: InviteContactsInteraction) -> ListViewItem {
        switch self {
            case let .option(_, option, theme, _):
                return ContactListActionItem(theme: theme, title: option.title, icon: option.icon, header: nil, action: option.action)
            case let .peer(_, id, contact, count, selection, theme, strings, nameSortOrder, nameDisplayOrder):
                let status: ContactsPeerItemStatus
                if count != 0 {
                    status = .custom(strings.Contacts_ImportersCount(count))
                } else {
                    status = .none
                }
                let peer = TelegramUser(id: PeerId(namespace: -1, id: 0), accessHash: nil, firstName: contact.firstName, lastName: contact.lastName, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [])
                return ContactsPeerItem(theme: theme, strings: strings, sortOrder: nameSortOrder, displayOrder: nameDisplayOrder, account: account, peerMode: .peer, peer: .peer(peer: peer, chatPeer: peer), status: status, enabled: true, selection: selection, editing: ContactsPeerItemEditing(editable: false, editing: false, revealed: false), index: nil, header: ChatListSearchItemHeader(type: .contacts, theme: theme, strings: strings, actionTitle: nil, action: nil), action: { _ in
                    interaction.toggleContact(id)
                })
        }
    }
    
    static func ==(lhs: InviteContactsEntry, rhs: InviteContactsEntry) -> Bool {
        switch lhs {
            case let .option(lhsIndex, lhsOption, lhsTheme, lhsStrings):
                if case let .option(rhsIndex, rhsOption, rhsTheme, rhsStrings) = rhs, lhsIndex == rhsIndex, lhsOption == rhsOption, lhsTheme === rhsTheme, lhsStrings === rhsStrings {
                    return true
                } else {
                    return false
                }
            case let .peer(lhsIndex, lhsId, lhsContact, lhsCount, lhsSelection, lhsTheme, lhsStrings, lhsSortOrder, lhsDisplayOrder):
                switch rhs {
                    case let .peer(rhsIndex, rhsId, rhsContact, rhsCount, rhsSelection, rhsTheme, rhsStrings, rhsSortOrder, rhsDisplayOrder):
                        if lhsIndex != rhsIndex {
                            return false
                        }
                        if lhsId != rhsId {
                            return false
                        }
                        if lhsContact != rhsContact {
                            return false
                        }
                        if lhsCount != rhsCount {
                            return false
                        }
                        if lhsSelection != rhsSelection {
                            return false
                        }
                        if lhsTheme !== rhsTheme {
                            return false
                        }
                        if lhsStrings !== rhsStrings {
                            return false
                        }
                        if lhsSortOrder != rhsSortOrder {
                            return false
                        }
                        if lhsDisplayOrder != rhsDisplayOrder {
                            return false
                        }
                        return true
                    default:
                        return false
            }
        }
    }
    
    static func <(lhs: InviteContactsEntry, rhs: InviteContactsEntry) -> Bool {
        switch lhs {
            case let .option(lhsIndex, _, _, _):
                switch rhs {
                    case let .option(rhsIndex, _, _, _):
                        return lhsIndex < rhsIndex
                    case .peer:
                        return true
                }
            case let .peer(lhsIndex, _, _, _, _, _, _, _, _):
                switch rhs {
                    case .option:
                        return false
                    case let .peer(rhsIndex, _, _, _, _, _, _, _, _):
                        return lhsIndex < rhsIndex
                }
        }
    }
}

struct InviteContactsGroupSelectionState: Equatable {
    let selectedContactIndices: [String: Int]
    let nextSelectionIndex: Int
    
    private init(selectedContactIndices: [String: Int], nextSelectionIndex: Int) {
        self.selectedContactIndices = selectedContactIndices
        self.nextSelectionIndex = nextSelectionIndex
    }
    
    init() {
        self.selectedContactIndices = [:]
        self.nextSelectionIndex = 0
    }
    
    func withReplacedSelectedContactIds(_ contactIds: [String]) -> InviteContactsGroupSelectionState {
        var selectedContactIndices: [String: Int] = [:]
        var nextSelectionIndex: Int = self.nextSelectionIndex
        for contactId in contactIds {
            selectedContactIndices[contactId] = nextSelectionIndex
            nextSelectionIndex += 1
        }
        return InviteContactsGroupSelectionState(selectedContactIndices: selectedContactIndices, nextSelectionIndex: nextSelectionIndex)
    }
    
    func withToggledContactId(_ contactId: String) -> InviteContactsGroupSelectionState {
        var updatedIndices = self.selectedContactIndices
        if let _ = updatedIndices[contactId] {
            updatedIndices.removeValue(forKey: contactId)
            return InviteContactsGroupSelectionState(selectedContactIndices: updatedIndices, nextSelectionIndex: self.nextSelectionIndex)
        } else {
            updatedIndices[contactId] = self.nextSelectionIndex
            return InviteContactsGroupSelectionState(selectedContactIndices: updatedIndices, nextSelectionIndex: self.nextSelectionIndex + 1)
        }
    }
    
    func withSelectedContactId(_ contactId: String) -> InviteContactsGroupSelectionState {
        var updatedIndices = self.selectedContactIndices
        if let _ = updatedIndices[contactId] {
            return self
        } else {
            updatedIndices[contactId] = self.nextSelectionIndex
            return InviteContactsGroupSelectionState(selectedContactIndices: updatedIndices, nextSelectionIndex: self.nextSelectionIndex + 1)
        }
    }
    
    func withClearedSelection() -> InviteContactsGroupSelectionState {
        return InviteContactsGroupSelectionState(selectedContactIndices: [:], nextSelectionIndex: self.nextSelectionIndex)
    }
    
    static func ==(lhs: InviteContactsGroupSelectionState, rhs: InviteContactsGroupSelectionState) -> Bool {
        return lhs.selectedContactIndices == rhs.selectedContactIndices && lhs.nextSelectionIndex == rhs.nextSelectionIndex
    }
}

private func inviteContactsEntries(accountPeer: Peer?, sortedContacts: [(DeviceContactStableId, DeviceContactBasicData, Int32)], selectionState: InviteContactsGroupSelectionState, theme: PresentationTheme, strings: PresentationStrings, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, interaction: InviteContactsInteraction) -> [InviteContactsEntry] {
    var entries: [InviteContactsEntry] = []
        
    entries.append(.option(0, ContactListAdditionalOption(title: strings.Contacts_ShareTelegram, icon: .generic(UIImage(bundleImageName: "Contact List/InviteActionIcon")!), action: {
        interaction.shareTelegram()
    }), theme, strings))
    
    var index = 0
    for (id, contact, count) in sortedContacts {
        entries.append(.peer(index, id, contact, count, .selectable(selected: selectionState.selectedContactIndices[id] != nil), theme, strings, nameSortOrder, nameDisplayOrder))
        index += 1
    }
    
    return entries
}

private func preparedInviteContactsTransition(account: Account, from fromEntries: [InviteContactsEntry], to toEntries: [InviteContactsEntry], sortedContats: [(DeviceContactStableId, DeviceContactBasicData, Int32)], interaction: InviteContactsInteraction, firstTime: Bool, animated: Bool) -> InviteContactsTransition {
    let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
    
    let deletions = deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
    let insertions = indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, interaction: interaction), directionHint: nil) }
    let updates = updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, interaction: interaction), directionHint: nil) }
    
    return InviteContactsTransition(deletions: deletions, insertions: insertions, updates: updates, sortedContats: sortedContats, firstTime: firstTime, animated: animated, isLoading: false)
}

private struct InviteContactsTransition {
    let deletions: [ListViewDeleteItem]
    let insertions: [ListViewInsertItem]
    let updates: [ListViewUpdateItem]
    let sortedContats: [(DeviceContactStableId, DeviceContactBasicData, Int32)]
    let firstTime: Bool
    let animated: Bool
    let isLoading: Bool
}

final class InviteContactsControllerNode: ASDisplayNode {
    let listNode: ListView
    
    private let context: AccountContext
    private var searchDisplayController: SearchDisplayController?
    
    private var validLayout: (ContainerViewLayout, CGFloat, CGFloat)?
    
    var navigationBar: NavigationBar?
    
    private let countPanelNode: InviteContactsCountPanelNode
    
    var requestActivateSearch: (() -> Void)?
    var requestDeactivateSearch: (() -> Void)?
    var requestShareTelegram: (() -> Void)?
    var requestShare: (([(DeviceContactBasicData, Int32)]) -> Void)?
    
    let currentSortedContacts = Atomic<[(DeviceContactStableId, DeviceContactBasicData, Int32)]>(value: [])
    
    var selectionState = InviteContactsGroupSelectionState() {
        didSet {
            if self.selectionState != oldValue {
                self.selectionStatePromise.set(.single(self.selectionState))
                self.countPanelNode.badge = "\(self.selectionState.selectedContactIndices.count)"
                if oldValue.selectedContactIndices.isEmpty != self.selectionState.selectedContactIndices.isEmpty {
                    if let (layout, navigationHeight, actualNavigationHeight) = self.validLayout {
                        self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, actualNavigationBarHeight: actualNavigationHeight, transition: .animated(duration: 0.3, curve: .spring))
                    }
                }
            }
        }
    }
    private let selectionStatePromise = Promise<InviteContactsGroupSelectionState>(InviteContactsGroupSelectionState())
    
    private var queuedTransitions: [InviteContactsTransition] = []
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private let themeAndStringsPromise: Promise<(PresentationTheme, PresentationStrings, PresentationPersonNameOrder, PresentationPersonNameOrder)>

    private var chatListEmptyIndicator: ActivityIndicator?
    
    private let _ready = Promise<Bool>()
    private var readyValue = false {
        didSet {
            if self.readyValue, self.readyValue != oldValue {
                self._ready.set(.single(self.readyValue))
            }
        }
    }
    var ready: Signal<Bool, NoError> {
        return self._ready.get()
    }
    
    private var disposable: Disposable?
    
    private let currentContactIds = Atomic<[String]>(value: [])
    
    init(context: AccountContext) {
        self.context = context
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        self.themeAndStringsPromise = Promise((self.presentationData.theme, self.presentationData.strings, self.presentationData.nameSortOrder, self.presentationData.nameDisplayOrder))
        
        self.listNode = ListView()
        
        var shareImpl: (() -> Void)?
        self.countPanelNode = InviteContactsCountPanelNode(theme: self.presentationData.theme, strings: self.presentationData.strings, action: {
            shareImpl?()
        })
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.backgroundColor = self.presentationData.theme.chatList.backgroundColor
        
        self.addSubnode(self.listNode)
        self.addSubnode(self.countPanelNode)
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                strongSelf.themeAndStringsPromise.set(.single((presentationData.theme, presentationData.strings, presentationData.nameSortOrder, presentationData.nameDisplayOrder)))
                
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        })
        
        let account = self.context.account
        var firstTime: Int32 = 1
        let selectionStateSignal = self.selectionStatePromise.get()
        let transition: Signal<InviteContactsTransition, NoError>
        let themeAndStringsPromise = self.themeAndStringsPromise
        let previousEntries = Atomic<[InviteContactsEntry]?>(value: nil)
        
        let interaction = InviteContactsInteraction(toggleContact: { [weak self] id in
            if let strongSelf = self {
                strongSelf.selectionState = strongSelf.selectionState.withToggledContactId(id)
            }
        }, shareTelegram: { [weak self] in
            self?.requestShareTelegram?()
        })
        
        let existingNumbers: Signal<Set<String>, NoError> = account.postbox.contactPeersView(accountPeerId: nil, includePresences: false)
        |> map { view -> Set<String> in
            var existingNumbers = Set<String>()
            for peer in view.peers {
                if let peer = peer as? TelegramUser, let phone = peer.phone {
                    existingNumbers.insert(formatPhoneNumber(phone))
                }
            }
            return existingNumbers
        }
        
        let currentSortedContacts = self.currentSortedContacts
        let sortedContacts: Signal<[(DeviceContactStableId, DeviceContactBasicData, Int32)], NoError> = combineLatest(existingNumbers, (context.sharedContext.contactDataManager?.basicData() ?? .single([:])) |> take(1))
        |> mapToSignal { existingNumbers, contacts -> Signal<[(DeviceContactStableId, DeviceContactBasicData, Int32)], NoError> in
            var mappedContacts: [(String, [DeviceContactNormalizedPhoneNumber])] = []
            for (id, basicData) in contacts {
                mappedContacts.append((id: id, basicData.phoneNumbers.map({ phoneNumber in
                    return DeviceContactNormalizedPhoneNumber(rawValue: formatPhoneNumber(phoneNumber.value))
                })))
            }
            return deviceContactsImportedByCount(postbox: context.account.postbox, contacts: mappedContacts)
            |> map { counts -> [(DeviceContactStableId, DeviceContactBasicData, Int32)] in
                var result: [(DeviceContactStableId, DeviceContactBasicData, Int32)] = []
                var contactValues: [DeviceContactStableId: DeviceContactBasicData] = [:]
                for (id, basicData) in contacts {
                    var found = false
                    for number in basicData.phoneNumbers {
                        if existingNumbers.contains(formatPhoneNumber(number.value)) {
                            found = true
                        }
                    }
                    if !found {
                        contactValues[id] = basicData
                    }
                }
                var countValues: [(String, Int32)] = []
                for (id, count) in counts {
                    countValues.append((id, count))
                }
                countValues.sort(by: { $0.1 > $1.1 })
                var existing = Set<String>()
                for (id, value) in countValues {
                    existing.insert(id)
                    if let contact = contactValues[id] {
                        result.append((id, contact, value))
                    }
                }
                for (id, contact) in contacts {
                    if !existing.contains(id) {
                        result.append((id, contact, 0))
                    }
                }
                
                return result
            }
        }
        |> beforeNext { sortedContacts in
            let _ = currentSortedContacts.swap(sortedContacts)
        }
        let processingQueue = Queue()
        transition = (combineLatest(sortedContacts, selectionStateSignal, themeAndStringsPromise.get())
        |> mapToQueue { sortedContacts, selectionState, themeAndStrings -> Signal<InviteContactsTransition, NoError> in
            let signal = deferred { () -> Signal<InviteContactsTransition, NoError> in
                let entries = inviteContactsEntries(accountPeer: nil, sortedContacts: sortedContacts, selectionState: selectionState, theme: themeAndStrings.0, strings: themeAndStrings.1, nameSortOrder: themeAndStrings.2, nameDisplayOrder: themeAndStrings.3, interaction: interaction)
                let previous = previousEntries.swap(entries)
                let animated: Bool
                if let previous = previous {
                    animated = (entries.count - previous.count) < 20
                } else {
                    animated = false
                }
                return .single(preparedInviteContactsTransition(account: context.account, from: previous ?? [], to: entries, sortedContats: sortedContacts, interaction: interaction, firstTime: previous == nil, animated: animated))
            }
            
            if OSAtomicCompareAndSwap32(1, 0, &firstTime) {
                return signal
                |> runOn(Queue.mainQueue())
            } else {
                return signal
                |> runOn(processingQueue)
            }
        })
        |> deliverOnMainQueue

        self.enqueueTransition(InviteContactsTransition(deletions: [], insertions: [], updates: [], sortedContats: [], firstTime: true, animated: false, isLoading: true))
        self.disposable = transition.start(next: { [weak self] transition in
            self?.enqueueTransition(transition)
        })
        
        shareImpl = { [weak self] in
            if let strongSelf = self {
                var result: [(DeviceContactBasicData, Int32)] = []
                for contact in (strongSelf.currentSortedContacts.with { $0 }) {
                    if strongSelf.selectionState.selectedContactIndices[contact.0] != nil {
                        result.append((contact.1, contact.2))
                    }
                }
                if !result.isEmpty {
                    self?.requestShare?(result)
                }
            }
        }
    }
    
    deinit {
        self.disposable?.dispose()
        self.presentationDataDisposable?.dispose()
    }
    
    private func updateThemeAndStrings() {
        self.backgroundColor = self.presentationData.theme.chatList.backgroundColor
        self.searchDisplayController?.updatePresentationData(self.presentationData)
    }
    
    func scrollToTop() {
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, actualNavigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let hadValidLayout = self.validLayout != nil
        self.validLayout = (layout, navigationBarHeight, actualNavigationBarHeight)
        
        var insets = layout.insets(options: [.input])
        insets.top += navigationBarHeight
        
        if let searchDisplayController = self.searchDisplayController {
            searchDisplayController.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        }
        
        insets.left += layout.safeInsets.left
        insets.right += layout.safeInsets.right
        
        var headerInsets = layout.insets(options: [.input])
        headerInsets.top += actualNavigationBarHeight
        
        let countPanelHeight = self.countPanelNode.updateLayout(width: layout.size.width, bottomInset: layout.intrinsicInsets.bottom, transition: transition)
        if self.selectionState.selectedContactIndices.isEmpty {
            transition.updateFrame(node: self.countPanelNode, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height), size: CGSize(width: layout.size.width, height: countPanelHeight)))
        } else {
            insets.bottom += countPanelHeight
            transition.updateFrame(node: self.countPanelNode, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - countPanelHeight), size: CGSize(width: layout.size.width, height: countPanelHeight)))
        }
        
        self.listNode.bounds = CGRect(x: 0.0, y: 0.0, width: layout.size.width, height: layout.size.height)
        self.listNode.position = CGPoint(x: layout.size.width / 2.0, y: layout.size.height / 2.0)
        
        var duration: Double = 0.0
        var curve: UInt = 0
        switch transition {
            case .immediate:
                break
            case let .animated(animationDuration, animationCurve):
                duration = animationDuration
                switch animationCurve {
                    case .easeInOut, .custom:
                        break
                    case .spring:
                        curve = 7
                }
        }
        
        let listViewCurve: ListViewAnimationCurve
        if curve == 7 {
            listViewCurve = .Spring(duration: duration)
        } else {
            listViewCurve = .Default(duration: nil)
        }
        
        let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, headerInsets: headerInsets, duration: duration, curve: listViewCurve)
        
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: updateSizeAndInsets, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })

        if let chatListEmptyIndicator = self.chatListEmptyIndicator {
            let indicatorSize = chatListEmptyIndicator.measure(CGSize(width: 100.0, height: 100.0))
            transition.updateFrame(node: chatListEmptyIndicator, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - indicatorSize.width) / 2.0), y: updateSizeAndInsets.insets.top + floor((layout.size.height -  updateSizeAndInsets.insets.top - updateSizeAndInsets.insets.bottom - indicatorSize.height) / 2.0)), size: indicatorSize))
        }
        
        if !hadValidLayout {
            self.dequeueTransitions()
        }
    }
    
    func activateSearch(placeholderNode: SearchBarPlaceholderNode) {
        guard let (containerLayout, navigationBarHeight, _) = self.validLayout, let navigationBar = self.navigationBar, self.searchDisplayController == nil else {
            return
        }
        
        self.searchDisplayController = SearchDisplayController(presentationData: self.presentationData, contentNode: ContactsSearchContainerNode(context: self.context, onlyWriteable: false, categories: [.deviceContacts], openPeer: { [weak self] peer in
            if let strongSelf = self, case let .deviceContact(id, _) = peer {
                strongSelf.selectionState = strongSelf.selectionState.withSelectedContactId(id)
                strongSelf.requestDeactivateSearch?()
            }
        }), cancel: { [weak self] in
            if let requestDeactivateSearch = self?.requestDeactivateSearch {
                requestDeactivateSearch()
            }
        })
        
        self.searchDisplayController?.containerLayoutUpdated(containerLayout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        self.searchDisplayController?.activate(insertSubnode: { [weak self, weak placeholderNode] subnode, isSearchBar in
            if let strongSelf = self, let strongPlaceholderNode = placeholderNode {
                if isSearchBar {
                    strongPlaceholderNode.supernode?.insertSubnode(subnode, aboveSubnode: strongPlaceholderNode)
                } else {
                    strongSelf.insertSubnode(subnode, belowSubnode: navigationBar)
                }
            }
        }, placeholder: placeholderNode)
    }
    
    func deactivateSearch(placeholderNode: SearchBarPlaceholderNode) {
        if let searchDisplayController = self.searchDisplayController {
            self.searchDisplayController = nil
            searchDisplayController.deactivate(placeholder: placeholderNode)
        }
    }
    
    private func enqueueTransition(_ transition: InviteContactsTransition) {
        self.queuedTransitions.append(transition)
        
        if self.validLayout != nil {
            self.dequeueTransitions()
        }
    }
    
    private func dequeueTransitions() {
        if self.validLayout != nil {
            while !self.queuedTransitions.isEmpty {
                let transition = self.queuedTransitions.removeFirst()
                
                var options = ListViewDeleteAndInsertOptions()
                if transition.firstTime {
                    options.insert(.Synchronous)
                    options.insert(.LowLatency)
                } else if transition.animated {
                    options.insert(.AnimateInsertion)
                }

                if self.chatListEmptyIndicator == nil, transition.isLoading {
                    let chatListEmptyIndicator = ActivityIndicator(type: .custom(self.presentationData.theme.list.itemAccentColor, 22.0, 1.0, false))
                    self.chatListEmptyIndicator = chatListEmptyIndicator
                    self.insertSubnode(chatListEmptyIndicator, aboveSubnode: self.listNode)
                } else if !transition.isLoading, let chatListEmptyIndicator = self.chatListEmptyIndicator {
                    self.chatListEmptyIndicator = nil
                    chatListEmptyIndicator.removeFromSupernode()
                }

                self.listNode.transaction(deleteIndices: transition.deletions, insertIndicesAndItems: transition.insertions, updateIndicesAndItems: transition.updates, options: options, updateOpaqueState: nil, completion: { [weak self] _ in
                    if let strongSelf = self {
                        strongSelf.readyValue = true
                    }
                })
            }
        }
    }
    
    func selectAll() {
        let ids = self.currentSortedContacts.with { $0 }.map { $0.0 }
        var allSelected = true
        for id in ids {
            if self.selectionState.selectedContactIndices[id] == nil {
                allSelected = false
                break
            }
        }
        self.selectionState = self.selectionState.withReplacedSelectedContactIds(allSelected ? [] : ids)
    }
}

