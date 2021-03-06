// swiftlint:disable all
import Foundation

public class RequestHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPRequest

    public typealias OutboundIn = HTTPResponse
    public typealias OutboundOut = HTTPServerResponsePart

    var state: RequestState = .ready

    public init() { }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            switch state {
            case .ready: break
            default: assertionFailure("Unexpected state: \(state)")
            }
            state = .awaitingBody(head)
        case .body(var chunk):
            switch state {
            case .ready: assertionFailure("Unexpected state: \(state)")
            case .awaitingBody(let head):
                state = .collectingBody(head, nil)
                channelRead(context: context, data: data)
            case .collectingBody(let head, let existingBody):
                let body: ByteBuffer
                if var existing = existingBody {
                    existing.writeBuffer(&chunk)
                    body = existing
                } else {
                    body = chunk
                }
                state = .collectingBody(head, body)
            case .waitingResponse: assertionFailure("Unexpected state: \(state)")
            }
        case .end(let tailHeaders):
            assert(tailHeaders == nil, "Tail headers are not supported")
            switch state {
            case .ready: assertionFailure("Unexpected state: \(state)")
            case .awaitingBody(let head):
                state = .waitingResponse(head)
                respond(to: head, body: .empty, context: context)
            case .collectingBody(let head, let body):
                state = .waitingResponse(head)
                let body: HTTPBody = body.flatMap(HTTPBody.init(buffer:)) ?? .empty
                respond(to: head, body: body, context: context)
            case .waitingResponse: assertionFailure("Unexpected state: \(state)")
            }
        }
    }

    private func respond(to head: HTTPRequestHead, body: HTTPBody, context: ChannelHandlerContext) {
        let req = HTTPRequest(head: head, body: body, channel: context.channel)
        context.fireChannelRead(wrapInboundOut(req))
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard case let .waitingResponse(request) = state else { preconditionFailure("Unexpected state: \(state)") }
        let response = unwrapOutboundIn(data)
        serialize(response, for: request, context: context, promise: promise)
        state = .ready
    }

    private func serialize(_ res: HTTPResponse, for reqhead: HTTPRequestHead, context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        // add a RFC1123 timestamp to the Date header to make this
        // a valid request
        var reshead = res.head
        reshead.headers.add(name: "date", value: RFC1123DateCache.shared.currentTimestamp())

        // add 'Connection' header if needed
        let connectionHeaders = reshead.headers[canonicalForm: "connection"].map { $0.lowercased() }

        if !connectionHeaders.contains("keep-alive") && !connectionHeaders.contains("close") {
            // the user hasn't pre-set either 'keep-alive' or 'close', so we might need to add headers
            reshead.headers.add(name: "Connection", value: reqhead.isKeepAlive ? "keep-alive" : "close")
        }

        // begin serializing
        context.write(wrapOutboundOut(.head(reshead)), promise: nil)
        if reqhead.method == .HEAD || res.status == .noContent {
            // skip sending the body for HEAD requests
            // also don't send bodies for 204 (no content) requests
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: promise)
        } else {
            switch res.body.storage {
            case .none: context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            case .buffer(let buffer): writeAndflush(buffer: buffer, context: context, shouldClose: !reqhead.isKeepAlive, promise: promise)
            case .string(let string):
                var buffer = context.channel.allocator.buffer(capacity: string.count)
                buffer.writeString(string)
                writeAndflush(buffer: buffer, context: context, shouldClose: !reqhead.isKeepAlive, promise: promise)
            case .staticString(let string):
                var buffer = context.channel.allocator.buffer(capacity: string.utf8CodeUnitCount)
                buffer.writeStaticString(string)
                writeAndflush(buffer: buffer, context: context, shouldClose: !reqhead.isKeepAlive, promise: promise)
            case .data(let data):
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                writeAndflush(buffer: buffer, context: context, shouldClose: !reqhead.isKeepAlive, promise: promise)
            case .dispatchData(let data):
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                writeAndflush(buffer: buffer, context: context, shouldClose: !reqhead.isKeepAlive, promise: promise)
            }
        }
    }

    /// Writes a `ByteBuffer` to the context.
    private func writeAndflush(buffer: ByteBuffer, context: ChannelHandlerContext, shouldClose: Bool, promise: EventLoopPromise<Void>?) {
        if buffer.readableBytes > 0 {
            _ = context.write(wrapOutboundOut(.body(.byteBuffer(buffer))))
        }
        _ = context.writeAndFlush(wrapOutboundOut(.end(nil))).map {
            if shouldClose {
                // close connection now
                context.close(promise: promise)
            } else {
                promise?.succeed(())
            }
        }
    }
}

enum RequestState {
    case ready
    case awaitingBody(HTTPRequestHead)
    case collectingBody(HTTPRequestHead, ByteBuffer?)
    case waitingResponse(HTTPRequestHead)
}
