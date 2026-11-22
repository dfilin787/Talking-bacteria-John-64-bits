import UIKit

struct AnimationClip {
    let name: String
    let frames: [UIImage]
    let size: CGSize

    var frameCount: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    static func load(_ name: String) -> AnimationClip? {
        guard let dir = BundleLocator.directory("Animations/\(name)") else {
            assertionFailure("Нет папки клипа: Animations/\(name)")
            return nil
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let urls = contents
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var images: [UIImage] = []
        images.reserveCapacity(urls.count)
        for url in urls {

            if let image = UIImage(contentsOfFile: url.path)?.predecoded() {
                images.append(image)
            }
        }
        guard let first = images.first else { return nil }
        return AnimationClip(name: name, frames: images, size: first.size)
    }

    func frame(at index: Int) -> UIImage {
        frames[min(max(index, 0), frames.count - 1)]
    }
}

extension UIImage {

    func predecoded() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let decoded = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return decoded.withRenderingMode(.alwaysOriginal)
    }
}

enum ClipName {

    static let idleBase = "sway"
    static let blink = "blink"
    static let sway = "sway"
    static let lookLeftRight = "lookLeftRight"
    static let bumpLeftRight = "bumpLeftRight"
    static let bumpUpDown = "bumpUpDown"
    static let talk = "talk"
    static let listen = "listen"
    static let needle = "needle"
    static let multiply = "multiply"
    static let explode = "explode"

    static let laugh = ["laugh", "laughGiggle", "laughGuffaw"]
    static let crazy = ["crazy1", "crazy2"]
    static let eat = ["eatBrownDonut", "eatOrangeDonut", "eatPinkDonut"]

    static let all: [String] = [
        idleBase, blink, sway, lookLeftRight, bumpLeftRight, bumpUpDown,
        talk, listen, needle, multiply, explode
    ] + laugh + crazy + eat
}

final class ClipLibrary {
    static let shared = ClipLibrary()

    private var clips: [String: AnimationClip] = [:]

    private init() {
        for name in ClipName.all {
            if let clip = AnimationClip.load(name) {
                clips[name] = clip
            }
        }
    }

    func clip(_ name: String) -> AnimationClip? { clips[name] }

    func random(from names: [String]) -> AnimationClip? {
        let available = names.compactMap { clips[$0] }
        return available.randomElement()
    }

    var loadedCount: Int { clips.count }
    var totalFrames: Int { clips.values.reduce(0) { $0 + $1.frameCount } }
}
