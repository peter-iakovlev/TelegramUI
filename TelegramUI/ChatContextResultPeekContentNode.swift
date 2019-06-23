import Foundation
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import AVFoundation

final class ChatContextResultPeekContent: PeekControllerContent {
    let account: Account
    let contextResult: ChatContextResult
    let menu: [PeekControllerMenuItem]
    
    init(account: Account, contextResult: ChatContextResult, menu: [PeekControllerMenuItem]) {
        self.account = account
        self.contextResult = contextResult
        self.menu = menu
    }
    
    func presentation() -> PeekControllerContentPresentation {
        return .contained(userInterfaceEnabled: false)
    }
    
    func menuActivation() -> PeerkControllerMenuActivation {
        return .drag
    }
    
    func menuItems() -> [PeekControllerMenuItem] {
        return self.menu
    }
    
    func node() -> PeekControllerContentNode & ASDisplayNode {
        return ChatContextResultPeekNode(account: self.account, contextResult: self.contextResult)
    }
    
    func topAccessoryNode() -> ASDisplayNode? {
        let arrowNode = ASImageNode()
        if let image = UIImage(bundleImageName: "Peek/Arrow") {
            arrowNode.image = image
            arrowNode.frame = CGRect(origin: CGPoint(), size: image.size)
        }
        return arrowNode
    }
    
    func isEqual(to: PeekControllerContent) -> Bool {
        if let to = to as? ChatContextResultPeekContent {
            return self.contextResult == to.contextResult
        } else {
            return false
        }
    }
}

private final class ChatContextResultPeekNode: ASDisplayNode, PeekControllerContentNode {
    private let account: Account
    private let contextResult: ChatContextResult
    
    private let imageNodeBackground: ASDisplayNode
    private let imageNode: TransformImageNode
    private var videoLayer: (SoftwareVideoThumbnailLayer, SoftwareVideoLayerFrameManager, SampleBufferLayer)?
    
    private var currentImageResource: TelegramMediaResource?
    private var currentVideoFile: TelegramMediaFile?
    
    private let timebase: CMTimebase
    
    private var displayLink: CADisplayLink?
    private var ticking: Bool = false {
        didSet {
            if self.ticking != oldValue {
                if self.ticking {
                    class DisplayLinkProxy: NSObject {
                        weak var target: ChatContextResultPeekNode?
                        init(target: ChatContextResultPeekNode) {
                            self.target = target
                        }
                        
                        @objc func displayLinkEvent() {
                            self.target?.displayLinkEvent()
                        }
                    }
                    
                    let displayLink = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.displayLinkEvent))
                    self.displayLink = displayLink
                    displayLink.add(to: RunLoop.main, forMode: RunLoopMode.commonModes)
                    if #available(iOS 10.0, *) {
                        displayLink.preferredFramesPerSecond = 25
                    } else {
                        displayLink.frameInterval = 2
                    }
                    displayLink.isPaused = false
                    CMTimebaseSetRate(self.timebase, 1.0)
                } else if let displayLink = self.displayLink {
                    self.displayLink = nil
                    displayLink.isPaused = true
                    displayLink.invalidate()
                    CMTimebaseSetRate(self.timebase, 0.0)
                }
            }
        }
    }
    
    private func displayLinkEvent() {
        let timestamp = CMTimebaseGetTime(self.timebase).seconds
        self.videoLayer?.1.tick(timestamp: timestamp)
    }
    
    init(account: Account, contextResult: ChatContextResult) {
        self.account = account
        self.contextResult = contextResult
        
        self.imageNodeBackground = ASDisplayNode()
        self.imageNodeBackground.isLayerBacked = true
        self.imageNodeBackground.backgroundColor = UIColor(white: 0.9, alpha: 1.0)
        
        self.imageNode = TransformImageNode()
        self.imageNode.contentAnimations = [.subsequentUpdates]
        self.imageNode.isLayerBacked = !smartInvertColorsEnabled()
        self.imageNode.displaysAsynchronously = false
        
        var timebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(nil, CMClockGetHostTimeClock(), &timebase)
        CMTimebaseSetRate(timebase!, 0.0)
        self.timebase = timebase!
        
        super.init()
        
        self.addSubnode(self.imageNodeBackground)
        
        self.imageNode.contentAnimations = [.firstUpdate, .subsequentUpdates]
        self.addSubnode(self.imageNode)
    }
    
    deinit {
        if let displayLink = self.displayLink {
            displayLink.isPaused = true
            displayLink.invalidate()
        }
    }
    
    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let imageLayout = self.imageNode.asyncLayout()
        let currentImageResource = self.currentImageResource
        let currentVideoFile = self.currentVideoFile
        
        var updateImageSignal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>?
        
        var imageResource: TelegramMediaResource?
        var videoFileReference: FileMediaReference?
        var imageDimensions: CGSize?
        switch self.contextResult {
            case let .externalReference(_, _, type, title, _, url, content, thumbnail, _):
                if let content = content {
                    imageResource = content.resource
                } else if let thumbnail = thumbnail {
                    imageResource = thumbnail.resource
                }
                imageDimensions = content?.dimensions
                if let content = content, type == "gif", let thumbnailResource = imageResource
                    , let dimensions = content.dimensions {
                    videoFileReference = .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: 0), partialReference: nil, resource: content.resource, previewRepresentations: [TelegramMediaImageRepresentation(dimensions: dimensions, resource: thumbnailResource)], immediateThumbnailData: nil, mimeType: "video/mp4", size: nil, attributes: [.Animated, .Video(duration: 0, size: dimensions, flags: [])]))
                    imageResource = nil
                }
            case let .internalReference(_, _, _, title, _, image, file, _):
                if let image = image {
                    if let largestRepresentation = largestImageRepresentation(image.representations) {
                        imageDimensions = largestRepresentation.dimensions
                    }
                    imageResource = imageRepresentationLargerThan(image.representations, size: CGSize(width: 200.0, height: 100.0))?.resource
                } else if let file = file {
                    if let dimensions = file.dimensions {
                        imageDimensions = dimensions
                    } else if let largestRepresentation = largestImageRepresentation(file.previewRepresentations) {
                        imageDimensions = largestRepresentation.dimensions
                    }
                    imageResource = smallestImageRepresentation(file.previewRepresentations)?.resource
                }
                
                if let file = file {
                    if file.isVideo && file.isAnimated {
                        videoFileReference = .standalone(media: file)
                        imageResource = nil
                    }
                }
        }
        
        let fittedImageDimensions: CGSize
        let croppedImageDimensions: CGSize
        if let imageDimensions = imageDimensions {
            fittedImageDimensions = imageDimensions.fitted(CGSize(width: size.width, height: size.height))
        } else {
            fittedImageDimensions = CGSize(width: min(size.width, size.height), height: min(size.width, size.height))
        }
        croppedImageDimensions = fittedImageDimensions
        
        var imageApply: (() -> Void)?
        if let _ = imageResource {
            let imageCorners = ImageCorners()
            let arguments = TransformImageArguments(corners: imageCorners, imageSize: fittedImageDimensions, boundingSize: croppedImageDimensions, intrinsicInsets: UIEdgeInsets())
            imageApply = imageLayout(arguments)
        }
        
        var updatedImageResource = false
        if let currentImageResource = currentImageResource, let imageResource = imageResource {
            if !currentImageResource.isEqual(to: imageResource) {
                updatedImageResource = true
            }
        } else if (currentImageResource != nil) != (imageResource != nil) {
            updatedImageResource = true
        }
        
        var updatedVideoFile = false
        if let currentVideoFile = currentVideoFile, let videoFileReference = videoFileReference {
            if !currentVideoFile.isEqual(to: videoFileReference.media) {
                updatedVideoFile = true
            }
        } else if (currentVideoFile != nil) != (videoFileReference != nil) {
            updatedVideoFile = true
        }
        
        if updatedImageResource {
            if let imageResource = imageResource {
                let tmpRepresentation = TelegramMediaImageRepresentation(dimensions: CGSize(width: fittedImageDimensions.width * 2.0, height: fittedImageDimensions.height * 2.0), resource: imageResource)
                let tmpImage = TelegramMediaImage(imageId: MediaId(namespace: 0, id: 0), representations: [tmpRepresentation], immediateThumbnailData: nil, reference: nil, partialReference: nil)
                updateImageSignal = chatMessagePhoto(postbox: self.account.postbox, photoReference: .standalone(media: tmpImage))
            } else {
                updateImageSignal = .complete()
            }
        }
        
        self.currentImageResource = imageResource
        self.currentVideoFile = videoFileReference?.media
        
        if let imageApply = imageApply {
            if let updateImageSignal = updateImageSignal {
                self.imageNode.setSignal(updateImageSignal)
            }
            
            self.imageNode.frame = CGRect(origin: CGPoint(), size: croppedImageDimensions)
            self.imageNodeBackground.frame = CGRect(origin: CGPoint(), size: croppedImageDimensions)
            imageApply()
        }
        
        if updatedVideoFile {
            if let (thumbnailLayer, _, layer) = self.videoLayer {
                self.videoLayer = nil
                thumbnailLayer.removeFromSuperlayer()
                layer.layer.removeFromSuperlayer()
            }
            
            if let videoFileReference = videoFileReference {
                let thumbnailLayer = SoftwareVideoThumbnailLayer(account: self.account, fileReference: videoFileReference)
                self.layer.addSublayer(thumbnailLayer)
                let layerHolder = takeSampleBufferLayer()
                layerHolder.layer.videoGravity = AVLayerVideoGravity.resizeAspectFill
                self.layer.addSublayer(layerHolder.layer)
                let manager = SoftwareVideoLayerFrameManager(account: self.account, fileReference: videoFileReference, resource: videoFileReference.media.resource, layerHolder: layerHolder)
                self.videoLayer = (thumbnailLayer, manager, layerHolder)
                thumbnailLayer.ready = { [weak self, weak thumbnailLayer, weak manager] in
                    if let strongSelf = self, let thumbnailLayer = thumbnailLayer, let manager = manager {
                        if strongSelf.videoLayer?.0 === thumbnailLayer && strongSelf.videoLayer?.1 === manager {
                            manager.start()
                        }
                    }
                }
            }
        }
        
        if let (thumbnailLayer, _, layer) = self.videoLayer {
            thumbnailLayer.frame = CGRect(origin: CGPoint(), size: croppedImageDimensions)
            layer.layer.frame = CGRect(origin: CGPoint(), size: CGSize(width: croppedImageDimensions.width, height: croppedImageDimensions.height))
        }
        
        if !self.ticking {
            self.ticking = true
        }
    
        return croppedImageDimensions
    }
}
