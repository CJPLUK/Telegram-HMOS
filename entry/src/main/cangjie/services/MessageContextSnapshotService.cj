package ohos_app_cangjie_entry.services

import ohos_app_cangjie_entry.interop.{callArkAsync, COMPONENT_SNAPSHOT_CAPTURE}
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*

/** Result of capturing one already-rendered message node. Dimensions are pixels. */
public class MessageContextSnapshot {
    public var path: String = ""
    public var width: Int64 = 0
    public var height: Int64 = 0

    public init(path!: String = "", width!: Int64 = 0, height!: Int64 = 0) {
        this.path = path
        this.width = width
        this.height = height
    }
}

/**
 * ArkTS owns componentSnapshot and PNG encoding. Cangjie receives only a sandbox
 * path, which keeps PixelMap lifetime and cross-language ownership unambiguous.
 */
public class MessageContextSnapshotService {
    private var generation: Int64 = 0
    private var activeToken: String = ""
    private var snapshot: Option<MessageContextSnapshot> = None<MessageContextSnapshot>
    private var waiter: Option<(Option<MessageContextSnapshot>) -> Unit> = None<(Option<MessageContextSnapshot>) -> Unit>

    /** Start capture in Touch.Down while Ark interop still has a UI scope. */
    public func preload(componentId: String, token: String): Unit {
        this.generation += 1
        let requestGeneration = this.generation
        match (this.snapshot) {
            case Some(old) => this.release(old.path)
            case None => ()
        }
        this.activeToken = token
        this.snapshot = None<MessageContextSnapshot>
        this.waiter = None<(Option<MessageContextSnapshot>) -> Unit>
        let args = JsonObject()
        args.setString("componentId", componentId)
        args.setString("token", token)
        callArkAsync(COMPONENT_SNAPSHOT_CAPTURE, args.toJsonString(), { response: String =>
            var result: Option<MessageContextSnapshot> = None<MessageContextSnapshot>
            let json = JsonParser.parseObject(response)
            if (json.getBool("ok")) {
                let captured = MessageContextSnapshot(
                    path: json.getString("path"),
                    width: json.getInt("width"),
                    height: json.getInt("height")
                )
                if (captured.path.size > 0) {
                    result = Some(captured)
                }
            }
            if (requestGeneration != this.generation || token != this.activeToken) {
                match (result) {
                    case Some(stale) => this.release(stale.path)
                    case None => ()
                }
                return
            }
            match (result) {
                case Some(_) => ()
                case None => Hilog.info(0, "CjTelegram", "[MessageContextSnapshot] capture failed component=${componentId}")
            }
            match (this.waiter) {
                case Some(completion) =>
                    this.waiter = None<(Option<MessageContextSnapshot>) -> Unit>
                    this.activeToken = ""
                    completion(result)
                case None => this.snapshot = result
            }
        })
    }

    /** Consume the preload immediately, or wait for its in-flight result. */
    public func consume(token: String, completion: (Option<MessageContextSnapshot>) -> Unit): Unit {
        if (token != this.activeToken) {
            completion(None<MessageContextSnapshot>)
            return
        }
        match (this.snapshot) {
            case Some(captured) =>
                this.snapshot = None<MessageContextSnapshot>
                this.activeToken = ""
                completion(Some(captured))
            case None => this.waiter = Some(completion)
        }
    }

    /** Cancel a short tap or a gesture that moved before recognition. */
    public func cancel(token: String): Unit {
        if (token != this.activeToken) { return }
        this.generation += 1
        this.activeToken = ""
        this.waiter = None<(Option<MessageContextSnapshot>) -> Unit>
        match (this.snapshot) {
            case Some(old) => this.release(old.path)
            case None => ()
        }
        this.snapshot = None<MessageContextSnapshot>
    }

    public func release(path: String): Unit {
        if (path.size == 0) { return }
        // Dismissal runs after an animation timer and has no Ark interop scope.
        // The PNG is in this app's cache sandbox, so native unlink is sufficient.
        try { FileIo.unlink(path) } catch (_e: Exception) {}
    }
}

private var _messageContextSnapshotService: Option<MessageContextSnapshotService> = None<MessageContextSnapshotService>

public func getMessageContextSnapshotService(): MessageContextSnapshotService {
    match (_messageContextSnapshotService) {
        case Some(service) => service
        case None =>
            let service = MessageContextSnapshotService()
            _messageContextSnapshotService = Some(service)
            service
    }
}
