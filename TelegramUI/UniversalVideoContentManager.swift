import Foundation
import AsyncDisplayKit
import SwiftSignalKit
import Postbox

private final class UniversalVideoContentSubscriber {
    let id: Int32
    let priority: UniversalVideoPriority
    let update: (((UniversalVideoContentNode & ASDisplayNode), Bool)?) -> Void
    var active: Bool = false
    
    init(id: Int32, priority: UniversalVideoPriority, update: @escaping (((UniversalVideoContentNode & ASDisplayNode), Bool)?) -> Void) {
        self.id = id
        self.priority = priority
        self.update = update
    }
}

private final class UniversalVideoContentHolder {
    private var nextId: Int32 = 0
    private var subscribers: [UniversalVideoContentSubscriber] = []
    let content: UniversalVideoContent
    let contentNode: UniversalVideoContentNode & ASDisplayNode
    
    var statusDisposable: Disposable?
    var statusValue: MediaPlayerStatus?
    
    var bufferingStatusDisposable: Disposable?
    var bufferingStatusValue: (IndexSet, Int)?
    
    var playbackCompletedIndex: Int?
    
    init(content: UniversalVideoContent, contentNode: UniversalVideoContentNode & ASDisplayNode, statusUpdated: @escaping (MediaPlayerStatus?) -> Void, bufferingStatusUpdated: @escaping ((IndexSet, Int)?) -> Void, playbackCompleted: @escaping () -> Void) {
        self.content = content
        self.contentNode = contentNode
        
        self.statusDisposable = (contentNode.status |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self {
                strongSelf.statusValue = value
                statusUpdated(value)
            }
        })
        
        self.bufferingStatusDisposable = (contentNode.bufferingStatus |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self {
                strongSelf.bufferingStatusValue = value
                bufferingStatusUpdated(value)
            }
        })
        
        self.playbackCompletedIndex = contentNode.addPlaybackCompleted {
            playbackCompleted()
        }
    }
    
    deinit {
        self.statusDisposable?.dispose()
        self.bufferingStatusDisposable?.dispose()
        if let playbackCompletedIndex = self.playbackCompletedIndex {
            self.contentNode.removePlaybackCompleted(playbackCompletedIndex)
        }
    }
    
    var isEmpty: Bool {
        return self.subscribers.isEmpty
    }
    
    func addSubscriber(priority: UniversalVideoPriority, update: @escaping (((UniversalVideoContentNode & ASDisplayNode), Bool)?) -> Void) -> Int32 {
        let id = self.nextId
        self.nextId += 1
        
        self.subscribers.append(UniversalVideoContentSubscriber(id: id, priority: priority, update: update))
        self.subscribers.sort(by: { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.id < rhs.id
        })
        
        return id
    }
    
    func removeSubscriberAndUpdate(id: Int32) {
        for i in 0 ..< self.subscribers.count {
            if self.subscribers[i].id == id {
                let subscriber = self.subscribers[i]
                self.subscribers.remove(at: i)
                if subscriber.active {
                    self.update(removeSubscribers: [subscriber])
                }
                break
            }
        }
    }
    
    func update(forceUpdateId: Int32? = nil, initiatedCreation: Int32? = nil, removeSubscribers: [UniversalVideoContentSubscriber] = []) {
        var removeSubscribers = removeSubscribers
        for i in (0 ..< self.subscribers.count) {
            if i == self.subscribers.count - 1 {
                if !self.subscribers[i].active {
                    self.subscribers[i].active = true
                    self.subscribers[i].update((self.contentNode, initiatedCreation: initiatedCreation == self.subscribers[i].id))
                }
            } else {
                if self.subscribers[i].active {
                    self.subscribers[i].active = false
                    removeSubscribers.append(self.subscribers[i])
                }
            }
        }
        
        for subscriber in removeSubscribers {
            subscriber.update(nil)
        }
        
        if let forceUpdateId = forceUpdateId {
            for subscriber in self.subscribers {
                if subscriber.id == forceUpdateId {
                    if !subscriber.active {
                        subscriber.update(nil)
                    }
                    break
                }
            }
        }
    }
}

private final class UniversalVideoContentHolderCallbacks {
    let playbackCompleted = Bag<() -> Void>()
    let status = Bag<(MediaPlayerStatus?) -> Void>()
    let bufferingStatus = Bag<((IndexSet, Int)?) -> Void>()
    
    var isEmpty: Bool {
        return self.playbackCompleted.isEmpty && self.status.isEmpty && self.bufferingStatus.isEmpty
    }
}

private struct NativeVideoContentHolderKey: Hashable {
    let id: UInt32
    let mediaId: MediaId
}

private func getHolderKey(forContentId id: AnyHashable) -> AnyHashable {
    if let id = id as? NativeVideoContentId, case let .message(_, stableId, mediaId) = id {
        return NativeVideoContentHolderKey(id: stableId, mediaId: mediaId)
    } else {
        return id
    }
}

final class UniversalVideoContentManager {
    private var holders: [AnyHashable: UniversalVideoContentHolder] = [:]
    private var holderCallbacks: [AnyHashable: UniversalVideoContentHolderCallbacks] = [:]
    
    func attachUniversalVideoContent(content: UniversalVideoContent, priority: UniversalVideoPriority, create: () -> UniversalVideoContentNode & ASDisplayNode, update: @escaping (((UniversalVideoContentNode & ASDisplayNode), Bool)?) -> Void) -> (AnyHashable, Int32) {
        assert(Queue.mainQueue().isCurrent())
        
        var initiatedCreation = false
        let holderKey = getHolderKey(forContentId: content.id)
        let holder: UniversalVideoContentHolder

        if let current = self.holders[holderKey] {
            holder = current
        } else {
            initiatedCreation = true
            holder = UniversalVideoContentHolder(
                content: content,
                contentNode: create(),
                statusUpdated: { [weak self] value in
                    guard let self = self, let current = self.holderCallbacks[holderKey] else { return }
                    for subscriber in current.status.copyItems() {
                        subscriber(value)
                    }
                },
                bufferingStatusUpdated: { [weak self] value in
                    guard let self = self, let current = self.holderCallbacks[holderKey] else { return }
                    for subscriber in current.bufferingStatus.copyItems() {
                        subscriber(value)
                    }
                },
                playbackCompleted: { [weak self] in
                    guard let self = self, let current = self.holderCallbacks[holderKey] else { return }
                    for subscriber in current.playbackCompleted.copyItems() {
                        subscriber()
                    }
                }
            )

            self.holders[holderKey] = holder
        }
        
        let id = holder.addSubscriber(priority: priority, update: update)
        holder.update(forceUpdateId: id, initiatedCreation: initiatedCreation ? id : nil)
        return (holder.content.id, id)
    }
    
    func detachUniversalVideoContent(id: AnyHashable, index: Int32) {
        assert(Queue.mainQueue().isCurrent())

        let holderKey = getHolderKey(forContentId: id)
        if let holder = self.holders[holderKey] {
            holder.removeSubscriberAndUpdate(id: index)
            if holder.isEmpty {
                self.holders.removeValue(forKey: holderKey)
                
                if let current = self.holderCallbacks[holderKey] {
                    for subscriber in current.status.copyItems() {
                        subscriber(nil)
                    }
                }
            }
        }
    }
    
    func withUniversalVideoContent(id: AnyHashable, _ f: ((UniversalVideoContentNode & ASDisplayNode)?) -> Void) {
        let holderKey = getHolderKey(forContentId: id)
        if let holder = self.holders[holderKey] {
            f(holder.contentNode)
        } else {
            f(nil)
        }
    }
    
    func addPlaybackCompleted(id: AnyHashable, _ f: @escaping () -> Void) -> Int {
        assert(Queue.mainQueue().isCurrent())
        let holderKey = getHolderKey(forContentId: id)
        var callbacks: UniversalVideoContentHolderCallbacks
        if let current = self.holderCallbacks[holderKey] {
            callbacks = current
        } else {
            callbacks = UniversalVideoContentHolderCallbacks()
            self.holderCallbacks[holderKey] = callbacks
        }
        return callbacks.playbackCompleted.add(f)
    }
    
    func removePlaybackCompleted(id: AnyHashable, index: Int) {
        let holderKey = getHolderKey(forContentId: id)
        if let current = self.holderCallbacks[holderKey] {
            current.playbackCompleted.remove(index)
            if current.playbackCompleted.isEmpty {
                self.holderCallbacks.removeValue(forKey: holderKey)
            }
        }
    }
    
    func statusSignal(content: UniversalVideoContent) -> Signal<MediaPlayerStatus?, NoError> {
        return Signal { subscriber in
            let holderKey = getHolderKey(forContentId: content.id)

            var callbacks: UniversalVideoContentHolderCallbacks
            if let current = self.holderCallbacks[holderKey] {
                callbacks = current
            } else {
                callbacks = UniversalVideoContentHolderCallbacks()
                self.holderCallbacks[holderKey] = callbacks
            }
            
            let index = callbacks.status.add({ value in
                subscriber.putNext(value)
            })
            if let current = self.holders[holderKey] {
                subscriber.putNext(current.statusValue)
            } else {
                subscriber.putNext(nil)
            }
            
            return ActionDisposable {
                Queue.mainQueue().async {
                    if let current = self.holderCallbacks[holderKey] {
                        current.status.remove(index)
                        if current.playbackCompleted.isEmpty {
                            self.holderCallbacks.removeValue(forKey: holderKey)
                        }
                    }
                }
            }
        } |> runOn(Queue.mainQueue())
    }
    
    func bufferingStatusSignal(content: UniversalVideoContent) -> Signal<(IndexSet, Int)?, NoError> {
        return Signal { subscriber in
            let holderKey = getHolderKey(forContentId: content.id)

            var callbacks: UniversalVideoContentHolderCallbacks
            if let current = self.holderCallbacks[holderKey] {
                callbacks = current
            } else {
                callbacks = UniversalVideoContentHolderCallbacks()
                self.holderCallbacks[holderKey] = callbacks
            }
            
            let index = callbacks.bufferingStatus.add({ value in
                subscriber.putNext(value)
            })
            
            if let current = self.holders[holderKey] {
                subscriber.putNext(current.bufferingStatusValue)
            } else {
                subscriber.putNext(nil)
            }
            
            return ActionDisposable {
                Queue.mainQueue().async {
                    if let current = self.holderCallbacks[holderKey] {
                        current.status.remove(index)
                        if current.playbackCompleted.isEmpty {
                            self.holderCallbacks.removeValue(forKey: holderKey)
                        }
                    }
                }
            }
        } |> runOn(Queue.mainQueue())
    }
}
