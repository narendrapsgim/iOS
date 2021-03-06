import Foundation
import PromiseKit
import UserNotifications
import ObjectMapper

internal enum WebhookManagerError: Error {
    case noApi
    case unregisteredIdentifier
    case unexpectedType(given: String, desire: String)
    case unmappableValue
}

// swiftlint:disable file_length
// swiftlint:disable type_body_length

public class WebhookManager: NSObject {
    public static func isManager(forSessionIdentifier identifier: String) -> Bool {
        return identifier.starts(with: baseURLSessionIdentifier)
    }
    private static let baseURLSessionIdentifier = "webhook-"
    private static var currentURLSessionIdentifier: String {
        baseURLSessionIdentifier + Bundle.main.bundleIdentifier!
    }
    private static var currentRegularURLSessionIdentifier: String {
        "non-background"
    }

    internal let ephemeralUrlSession: URLSession
    internal var sessionInfos = Set<WebhookSessionInfo>()
    internal var currentBackgroundSessionInfo: WebhookSessionInfo {
        sessionInfo(forIdentifier: Self.currentURLSessionIdentifier)
    }
    internal var currentRegularSessionInfo: WebhookSessionInfo {
        sessionInfo(forIdentifier: Self.currentRegularURLSessionIdentifier)
    }

    // must be accessed on appropriate queue
    private let dataQueue: DispatchQueue
    private let sessionInfoQueue = DispatchQueue(label: "webhook-session-info")
    private let dataQueueSpecificKey: DispatchSpecificKey<Bool>
    // underlying queue is the dataQueue
    private let dataOperationQueue: OperationQueue

    private var pendingDataForTask: [TaskKey: Data] = [:] {
        willSet {
            assert(DispatchQueue.getSpecific(key: dataQueueSpecificKey) == true)
        }
    }
    private var resolverForTask: [TaskKey: Resolver<Void>] = [:] {
        willSet {
            assert(DispatchQueue.getSpecific(key: dataQueueSpecificKey) == true)
        }
    }

    private var responseHandlers = [WebhookResponseIdentifier: WebhookResponseHandler.Type]()

    // MARK: - Lifecycle

    override internal init() {
        let specificKey = DispatchSpecificKey<Bool>()
        let underlyingQueue = DispatchQueue(label: "webhookmanager-data")
        underlyingQueue.setSpecific(key: specificKey, value: true)

        self.dataQueue = underlyingQueue
        self.dataQueueSpecificKey = specificKey
        self.dataOperationQueue = with(OperationQueue()) {
            $0.underlyingQueue = underlyingQueue
            $0.maxConcurrentOperationCount = 1
        }

        self.ephemeralUrlSession = URLSession(configuration: .ephemeral)

        super.init()

        // cause the current background session to be created
        _ = currentBackgroundSessionInfo

        register(responseHandler: WebhookResponseUnhandled.self, for: .unhandled)
    }

    internal func register(
        responseHandler: WebhookResponseHandler.Type,
        for identifier: WebhookResponseIdentifier
    ) {
        precondition(responseHandlers[identifier] == nil)
        responseHandlers[identifier] = responseHandler
    }

    private func sessionInfo(for session: URLSession) -> WebhookSessionInfo {
        let sessionInfos = sessionInfoQueue.sync { self.sessionInfos }

        guard let identifier = session.configuration.identifier else {
            if let sameSession = sessionInfos.first(where: { $0.session == session }) {
                return sameSession
            }

            Current.Log.error("asked for session \(session) but couldn't identify info for it")
            return currentBackgroundSessionInfo
        }

        return sessionInfo(forIdentifier: identifier)
    }

    private func sessionInfo(forIdentifier identifier: String) -> WebhookSessionInfo {
        sessionInfoQueue.sync {
            if let sessionInfo = sessionInfos.first(where: { $0.identifier == identifier }) {
                return sessionInfo
            }

            let sessionInfo = WebhookSessionInfo(
                identifier: identifier,
                delegate: self,
                delegateQueue: dataOperationQueue,
                background: identifier != Self.currentRegularURLSessionIdentifier
            )
            sessionInfos.insert(sessionInfo)
            return sessionInfo
        }
    }

    public func handleBackground(for identifier: String, completionHandler: @escaping () -> Void) {
        precondition(Self.isManager(forSessionIdentifier: identifier))
        Current.Log.notify("handleBackground started for \(identifier)")

        let sessionInfo = self.sessionInfo(forIdentifier: identifier)
        Current.Log.info("created or retrieved: \(sessionInfo)")

        // enter before setting finish, in case we had another leave/enter pair set up, we want to prevent notifying
        sessionInfo.eventGroup.enter()
        sessionInfo.setDidFinish {
            // this is wrapped via a block -- rather than being invoked directly -- because iOS 14 (at least b1/b2)
            // sends `urlSessionDidFinishEvents` when it didn't send `handleEventsForBackgroundURLSession`
            sessionInfo.eventGroup.leave()
        }

        sessionInfo.eventGroup.notify(queue: DispatchQueue.main) {
            Current.Log.notify("final completion for \(identifier)")
            completionHandler()
        }

        if currentBackgroundSessionInfo != sessionInfo {
            sessionInfo.eventGroup.notify(queue: .main) { [weak self] in
                Current.Log.info("removing session info \(sessionInfo)")
                self?.sessionInfos.remove(sessionInfo)
            }
        }
    }

    // MARK: - Sending Ephemeral

    public func sendEphemeral(request: WebhookRequest) -> Promise<Void> {
        let promise: Promise<Any> = sendEphemeral(request: request)
        return promise.asVoid()
    }

    public func sendEphemeral<MappableResult: BaseMappable>(request: WebhookRequest) -> Promise<MappableResult> {
        let promise: Promise<Any> = sendEphemeral(request: request)
        return promise.map {
            if let result = Mapper<MappableResult>().map(JSONObject: $0) {
                return result
            } else {
                throw WebhookManagerError.unmappableValue
            }
        }
    }

    public func sendEphemeral<MappableResult: BaseMappable>(request: WebhookRequest) -> Promise<[MappableResult]> {
        let promise: Promise<Any> = sendEphemeral(request: request)
        return promise.map {
            if let result = Mapper<MappableResult>(shouldIncludeNilValues: false).mapArray(JSONObject: $0) {
                return result
            } else {
                throw WebhookManagerError.unmappableValue
            }
        }
    }

    public func sendEphemeral<ResponseType>(request: WebhookRequest) -> Promise<ResponseType> {
        ProcessInfo.processInfo.backgroundTask(withName: "webhook-send-ephemeral") { [ephemeralUrlSession] _ in
            attemptNetworking {
                firstly {
                    Self.urlRequest(for: request)
                }.then { urlRequest, data in
                    ephemeralUrlSession.uploadTask(.promise, with: urlRequest, from: data)
                }
            }
        }.then { data, response in
            Promise.value(data).webhookJson(
                on: DispatchQueue.global(qos: .utility),
                statusCode: (response as? HTTPURLResponse)?.statusCode
            )
        }.map { possible in
            if let value = possible as? ResponseType {
                return value
            } else {
                throw WebhookManagerError.unexpectedType(
                    given: String(describing: type(of: possible)),
                    desire: String(describing: ResponseType.self)
                )
            }
        }.tap { result in
            switch result {
            case .fulfilled(let response):
                Current.Log.info {
                    var log = "got successful response for \(request.type)"
                    if Current.isDebug {
                        log += ": \(response)"
                    }
                    return log
                }
            case .rejected(let error):
                Current.Log.error("got failure for \(request.type): \(error)")
            }
        }
    }

    // MARK: - Sending Persistent

    public func send(
        identifier: WebhookResponseIdentifier = .unhandled,
        request: WebhookRequest
    ) -> Promise<Void> {
        let sendRegular: () -> Promise<Void> = { [self, currentRegularSessionInfo] in
            self.send(on: currentRegularSessionInfo, identifier: identifier, request: request)
        }

        let sendBackground: () -> Promise<Void> = { [self, currentBackgroundSessionInfo] in
            self.send(on: currentBackgroundSessionInfo, identifier: identifier, request: request)
        }

        if Current.isBackgroundRequestsImmediate() {
            return sendBackground()
        } else {
            Current.Log.info("in background, choosing to not use background session")
            return sendRegular().recover { error -> Promise<Void> in
                Current.Log.error("in-background non-background failed: \(error)")
                return sendBackground()
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func send(
        on sessionInfo: WebhookSessionInfo,
        identifier: WebhookResponseIdentifier,
        request: WebhookRequest
    ) -> Promise<Void> {
        guard let handlerType = responseHandlers[identifier] else {
            Current.Log.error("no existing handler for \(identifier), not sending request")
            return .init(error: WebhookManagerError.unregisteredIdentifier)
        }

        let (promise, seal) = Promise<Void>.pending()

        // wrap this in a background task, but don't let the expiration cause the resolve chain to be aborted
        // this is important because we may be woken up later and asked to continue the same request, even if timed out
        // since, you know, background execution and whatnot
        ProcessInfo.processInfo.backgroundTask(withName: "webhook-send") { _ in promise }.cauterize()

        firstly {
            Self.urlRequest(for: request)
        }.done(on: dataQueue) { urlRequest, data in
            let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let temporaryFile = temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("json")
            try data.write(to: temporaryFile, options: [])
            let task = sessionInfo.session.uploadTask(with: urlRequest, fromFile: temporaryFile)

            let persisted = WebhookPersisted(request: request, identifier: identifier)
            task.webhookPersisted = persisted

            let taskKey = TaskKey(sessionInfo: sessionInfo, task: task)

            self.evaluateCancellable(
                by: task,
                type: handlerType,
                persisted: persisted,
                with: promise
            )
            self.resolverForTask[taskKey] = seal
            task.resume()

            Current.Log.info {
                var values = [
                    "\(taskKey)",
                    "type(\(handlerType))"
                ]

                if Current.isDebug {
                    values += [
                        "request(\(persisted.request))"
                    ]
                }

                return "starting request: " + values.joined(separator: ", ")
            }

            try FileManager.default.removeItem(at: temporaryFile)
        }.catch { error in
            self.invoke(
                sessionInfo: sessionInfo,
                handler: handlerType,
                request: request,
                result: .init(error: error),
                resolver: seal
            )
        }

        return promise
    }

    // MARK: - Private

    private func evaluateCancellable(
        by newTask: URLSessionTask,
        type newType: WebhookResponseHandler.Type,
        persisted newPersisted: WebhookPersisted,
        with newPromise: Promise<Void>
    ) {
        currentBackgroundSessionInfo.session.getAllTasks { tasks in
            tasks.filter { thisTask in
                guard let (thisType, thisPersisted) = self.responseInfo(from: thisTask) else {
                    Current.Log.error("cancelling request without persistence info: \(thisTask)")
                    thisTask.cancel()
                    return false
                }

                if thisType == newType, thisTask != newTask {
                    return newType.shouldReplace(request: newPersisted.request, with: thisPersisted.request)
                } else {
                    return false
                }
            }.forEach { existingTask in
                let taskKey = TaskKey(sessionInfo: self.currentBackgroundSessionInfo, task: existingTask)
                if let existingResolver = self.resolverForTask[taskKey] {
                    // connect the task we're about to cancel's promise to the replacement
                    newPromise.pipe { existingResolver.resolve($0) }
                }
                existingTask.cancel()
            }
        }
    }

    private static func urlRequest(for request: WebhookRequest) -> Promise<(URLRequest, Data)> {
        return Promise { seal in
            guard let api = Current.api() else {
                seal.reject(WebhookManagerError.noApi)
                return
            }

            var urlRequest = try URLRequest(
                url: api.connectionInfo.webhookURL,
                method: .post
            )
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let jsonObject = Mapper<WebhookRequest>(context: WebhookRequestContext.server).toJSON(request)
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])

            // httpBody is ignored by URLSession but is made available in tests
            urlRequest.httpBody = data

            seal.fulfill((urlRequest, data))
        }
    }

    private func handle(result: WebhookResponseHandlerResult) {
        if let notification = result.notification {
            UNUserNotificationCenter.current().add(notification) { error in
                if let error = error {
                    Current.Log.error("failed to add notification for result \(result): \(error)")
                }
            }
        }
    }

    private func responseInfo(from task: URLSessionTask) -> (WebhookResponseHandler.Type, WebhookPersisted)? {
        guard let persisted = task.webhookPersisted else {
            Current.Log.error("no persisted info for \(task) \(task.taskDescription ?? "(nil)")")
            return nil
        }

        guard let handlerType = responseHandlers[persisted.identifier] else {
            Current.Log.error("unknown response identifier \(persisted.identifier) for \(task)")
            return nil
        }

        return (handlerType, persisted)
    }
}

extension WebhookManager: URLSessionDelegate {
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Current.Log.notify("event delivery ended")
        sessionInfo(for: session).fireDidFinish()
    }
}

extension WebhookManager: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskKey = TaskKey(sessionInfo: sessionInfo(for: session), task: dataTask)

        dataQueue.async {
            self.pendingDataForTask[taskKey, default: Data()].append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sessionInfo = self.sessionInfo(for: session)
        let taskKey = TaskKey(sessionInfo: sessionInfo, task: task)

        guard error?.isCancelled != true else {
            Current.Log.info("ignoring cancelled task \(taskKey)")
            dataQueue.async {
                self.pendingDataForTask.removeValue(forKey: taskKey)
            }
            return
        }

        let result = Promise<Data?> { seal in
            dataQueue.async {
                let data = self.pendingDataForTask[taskKey]
                self.pendingDataForTask.removeValue(forKey: taskKey)
                seal.resolve(error, data)
            }
        }.webhookJson(
            on: DispatchQueue.global(qos: .utility),
            statusCode: (task.response as? HTTPURLResponse)?.statusCode
        )

        // dispatch
        if let (handlerType, persisted) = responseInfo(from: task) {
            // logging
            result.done(on: dataQueue) { body in
                Current.Log.info {
                    var values = [
                        "\(taskKey)",
                        "type(\(handlerType))"
                    ]

                    if Current.isDebug {
                        values += [
                            "request(\(persisted.request))",
                            "body(\(body))"
                        ]
                    }

                    return "got response: " + values.joined(separator: ", ")
                }
            }.catch { error in
                Current.Log.error("failed request for \(handlerType): \(error)")
            }

            invoke(
                sessionInfo: sessionInfo,
                handler: handlerType,
                request: persisted.request,
                result: result,
                resolver: resolverForTask[taskKey]
            )

            resolverForTask.removeValue(forKey: taskKey)
        } else {
            Current.Log.notify("no handler for background task")
            Current.Log.error("couldn't find appropriate handler for \(task)")
        }
    }

    private func invoke(
        sessionInfo: WebhookSessionInfo,
        handler handlerType: WebhookResponseHandler.Type,
        request: WebhookRequest,
        result: Promise<Any>,
        resolver: Resolver<Void>?
    ) {
        guard let api = Current.api() else {
            Current.Log.error("no api")
            return
        }

        Current.Log.notify("starting \(request.type) (\(handlerType))")
        sessionInfo.eventGroup.enter()

        let handler = handlerType.init(api: api)
        let handlerPromise = firstly {
            handler.handle(request: .value(request), result: result)
        }.done { [weak self] result in
            // keep the handler around until it finishes
            withExtendedLifetime(handler) {
                self?.handle(result: result)
            }
        }

        firstly {
            when(fulfilled: [handlerPromise.asVoid(), result.asVoid()])
        }.tap {
            resolver?.resolve($0)
        }.ensure {
            Current.Log.notify("finished \(request.type) \(handlerType)")
            sessionInfo.eventGroup.leave()
        }.cauterize()
    }
}

internal class WebhookSessionInfo: CustomStringConvertible, Hashable {
    let identifier: String
    let eventGroup: DispatchGroup
    let session: URLSession
    private var pendingDidFinishHandler: (() -> Void)?

    var description: String {
        "sessionInfo(identifier: \(identifier))"
    }

    func setDidFinish(_ block: @escaping () -> Void) {
        pendingDidFinishHandler?()
        pendingDidFinishHandler = block
    }

    func fireDidFinish() {
        pendingDidFinishHandler?()
        pendingDidFinishHandler = nil
    }

    init(
        identifier: String,
        delegate: URLSessionDelegate,
        delegateQueue: OperationQueue,
        background: Bool
    ) {
        let configuration: URLSessionConfiguration = {
            if NSClassFromString("XCTest") != nil {
                // ^ cannot reference Current here because we're being created inside Current as it is made
                // we cannot mock http requests in a background session, so this code path has to differ
                return .ephemeral
            } else {
                let configuration: URLSessionConfiguration

                if background {
                    configuration = URLSessionConfiguration.background(withIdentifier: identifier)
                } else {
                    configuration = URLSessionConfiguration.default
                }

                return with(configuration) {
                    $0.sharedContainerIdentifier = Constants.AppGroupID
                    $0.httpCookieStorage = nil
                    $0.httpCookieAcceptPolicy = .never
                    $0.httpShouldSetCookies = false
                    $0.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                }
            }
        }()

        self.identifier = identifier
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        self.eventGroup = DispatchGroup()
    }

    static func == (lhs: WebhookSessionInfo, rhs: WebhookSessionInfo) -> Bool {
        lhs.identifier == rhs.identifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

private struct TaskKey: Hashable, CustomStringConvertible {
    private let sessionIdentifier: String
    private let taskIdentifier: Int

    init(sessionInfo: WebhookSessionInfo, task: URLSessionTask) {
        self.sessionIdentifier = sessionInfo.identifier
        self.taskIdentifier = task.taskIdentifier
    }

    var description: String {
        "taskKey(session: \(sessionIdentifier), task: \(taskIdentifier))"
    }
}
