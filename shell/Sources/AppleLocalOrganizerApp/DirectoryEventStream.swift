import CoreServices
import Foundation

final class DirectoryEventStream {
    private final class CallbackBox {
        let handler: @Sendable ([String]) -> Void

        init(handler: @escaping @Sendable ([String]) -> Void) {
            self.handler = handler
        }
    }

    private let path: String
    private let latency: CFTimeInterval
    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?

    init(path: String, latency: CFTimeInterval = 0.8, handler: @escaping @Sendable ([String]) -> Void) {
        self.path = path
        self.latency = latency
        self.callbackBox = CallbackBox(handler: handler)
    }

    func start() throws {
        guard stream == nil else {
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(callbackBox).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPathsPointer, _, _ in
                guard let info else {
                    return
                }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                let eventPaths = unsafeBitCast(eventPathsPointer, to: CFArray.self) as Array
                let paths = eventPaths.compactMap { $0 as? String }
                box.handler(Array(paths.prefix(Int(numEvents))))
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw NSError(
                domain: "DropSort",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "FSEventStream を作成できませんでした: \(path)"]
            )
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw NSError(
                domain: "DropSort",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "FSEventStream を開始できませんでした: \(path)"]
            )
        }

        self.stream = stream
    }

    func stop() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
