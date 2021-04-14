//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if compiler(>=5.5)
import _Concurrency
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import Backtrace
import CoreMetrics
import Dispatch
import Logging

// MARK: - LifecycleTask

/// Represents an item that can be started and shut down
public protocol LifecycleTask {
    var label: String { get }
    var shutdownIfNotStarted: Bool { get }
    func start() async throws
    func shutdown() async throws
}

extension LifecycleTask {
    public var shutdownIfNotStarted: Bool {
        return false
    }
}

// MARK: - LifecycleHandler

/// Supported startup and shutdown method styles
public struct LifecycleHandler {
    //private let underlying: ((@escaping (Error?) -> Void) -> Void)?
    private let underlying: (() async throws -> Void)?

    /// Initialize a `LifecycleHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying completion handler
    @available(*, deprecated)
    public init(_ handler: (@escaping (Error?) -> Void) -> Void) {
        // FIXME
        fatalError("not implemented")
    }

    public init(_ handler: (() async throws -> Void)?) {
        self.underlying = handler
    }

    /// Asynchronous `LifecycleHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying async handler
    @available(*, deprecated)
    public static func `async`(_ handler: @escaping (@escaping (Error?) -> Void) -> Void) -> LifecycleHandler {
        return LifecycleHandler(handler)
    }

    public static func `async`(_ handler: @escaping () async throws -> Void) -> LifecycleHandler {
        return LifecycleHandler(handler)
    }

    /// Asynchronous `LifecycleHandler` based on a blocking, throwing function.
    ///
    /// - parameters:
    ///    - body: the underlying function
    public static func sync(_ body: @escaping () throws -> Void) -> LifecycleHandler {
        func asyncBody () async throws {
            try body()
        }
        return LifecycleHandler(asyncBody)
    }

    /// Noop `LifecycleHandler`.
    public static var none: LifecycleHandler {
        return LifecycleHandler(nil)
    }

    internal func run() async throws {
        if let underlying = self.underlying {
            try await underlying()
        }
    }

    internal var noop: Bool {
        return self.underlying == nil
    }
}

// MARK: - Stateful Lifecycle Handlers

/// LifecycleHandler for starting stateful tasks. The state can then be fed into a LifecycleShutdownHandler
public struct LifecycleStartHandler<State> {
    //private let underlying: (@escaping (Result<State, Error>) -> Void) -> Void
    private let underlying: () async throws -> State

    /// Initialize a `LifecycleHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - callback: the underlying completion handler
    @available(*, deprecated)
    public init(_ handler: @escaping (@escaping (Result<State, Error>) -> Void) -> Void) {
        // FIXME
        fatalError("not implemented")
    }

    public init(_ handler: @escaping () async throws -> State) {
        self.underlying = handler
    }

    /// Asynchronous `LifecycleStartHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying async handler
    @available(*, deprecated)
    public static func `async`(_ handler: @escaping (@escaping (Result<State, Error>) -> Void) -> Void) -> LifecycleStartHandler {
        return LifecycleStartHandler(handler)
    }

    public static func `async`(_ handler: @escaping () async throws -> State) -> LifecycleStartHandler {
        return LifecycleStartHandler(handler)
    }

    /// Synchronous `LifecycleStartHandler` based on a blocking, throwing function.
    ///
    /// - parameters:
    ///    - body: the underlying function
    public static func sync(_ body: @escaping () throws -> State) -> LifecycleStartHandler {
        func asyncBody () async throws -> State {
            try body()
        }
        return LifecycleStartHandler(asyncBody)
    }

    internal func run() async throws -> State {
        try await self.underlying()
    }
}

/// LifecycleHandler for shutting down stateful tasks. The state comes from a LifecycleStartHandler
public struct LifecycleShutdownHandler<State> {
    //private let underlying: (State, @escaping (Error?) -> Void) -> Void
    private let underlying: (State) async throws -> Void

    /// Initialize a `LifecycleShutdownHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying completion handler
    @available(*, deprecated)
    public init(_ handler: @escaping (State, @escaping (Error?) -> Void) -> Void) {
        // FIXME
        fatalError("not implemented")
    }

    public init(_ handler: @escaping (State) async throws -> Void) {
        self.underlying = handler
    }

    /// Asynchronous `LifecycleShutdownHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying async handler
    @available(*, deprecated)
    public static func `async`(_ handler: @escaping (State, @escaping (Error?) -> Void) -> Void) -> LifecycleShutdownHandler {
       return LifecycleShutdownHandler(handler)
    }

    public static func `async`(_ handler: @escaping (State) async throws -> Void) -> LifecycleShutdownHandler {
        return LifecycleShutdownHandler(handler)
    }

    /// Asynchronous `LifecycleShutdownHandler` based on a blocking, throwing function.
    ///
    /// - parameters:
    ///    - body: the underlying function
    public static func sync(_ body: @escaping (State) throws -> Void) -> LifecycleShutdownHandler {
        func asyncBody (state: State) async throws -> Void {
            try body(state)
        }
        return LifecycleShutdownHandler(asyncBody)
    }

    internal func run(state: State) async throws -> Void {
        try await self.underlying(state)
    }
}

// MARK: - ServiceLifecycle

/// `ServiceLifecycle` provides a basic mechanism to cleanly startup and shutdown the application, freeing resources in order before exiting.
///  By default, also install shutdown hooks based on `Signal` and backtraces.
public struct ServiceLifecycle {
    private static let backtracesInstalled = AtomicBoolean(false)

    private let configuration: Configuration

    /// The underlying `ComponentLifecycle` instance
    private let underlying: ComponentLifecycle

    /// Creates a `ServiceLifecycle` instance.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.underlying = ComponentLifecycle(label: self.configuration.label, logger: self.configuration.logger)
        // setup backtraces as soon as possible, so if we crash during setup we get a backtrace
        self.installBacktrace()
    }

    /// Starts the provided `LifecycleTask` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    @available(*, deprecated)
    public func start(_ callback: @escaping (Error?) -> Void) {
        // FIXE
    }

    public func start() async throws {
        guard self.underlying.idle else {
            preconditionFailure("already started")
        }
        self.setupShutdownHook()
        try await self.underlying.start()
    }

    /// Starts the provided `LifecycleTask` array and waits (blocking) until a shutdown `Signal` is captured or `shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    @available(*, deprecated)
    public func _startAndWait() throws {
        // FIXE
    }

    public func startAndWait() async throws {
        guard self.underlying.idle else {
            preconditionFailure("already started")
        }
        self.setupShutdownHook()
        try await self.underlying.startAndWait()
    }

    /// Shuts down the `LifecycleTask` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    @available(*, deprecated)
    public func shutdown(_ callback: @escaping (Error?) -> Void = { _ in }) {
        self.underlying.shutdown(callback)
    }

    public func shutdown() async throws {
        try await self.underlying.shutdown()
    }

    /// Waits (blocking) until shutdown `Signal` is captured or `shutdown` is invoked on another thread.
    @available(*, deprecated)
    public func _wait() {
        self.underlying._wait()
    }

    public func wait() async throws {
        try await self.underlying.wait()
    }

    private func installBacktrace() {
        if self.configuration.installBacktrace, ServiceLifecycle.backtracesInstalled.compareAndSwap(expected: false, desired: true) {
            self.log("installing backtrace")
            Backtrace.install()
        }
    }

    private func setupShutdownHook() {
        self.configuration.shutdownSignal?.forEach { signal in
            // FIXME
            self.log("setting up shutdown hook on \(signal)")
            fatalError("not implemented")
            //let signalSource = ServiceLifecycle.trap(signal: signal, handler: { signal in
            //    self.log("intercepted signal: \(signal)")
            //    self.shutdown()
            //}, cancelAfterTrap: true)
            //self.underlying.shutdownGroup.notify(queue: .global()) {
            //    signalSource.cancel()
            //}
        }
    }

    private func log(_ message: String) {
        self.underlying.log(message)
    }
}

extension ServiceLifecycle {
    /// Setup a signal trap.
    ///
    /// - parameters:
    ///    - signal: The signal to trap.
    ///    - handler: closure to invoke when the signal is captured.
    ///    - on: DispatchQueue to run the signal handler on (default global dispatch queue)
    ///    - cancelAfterTrap: Defaults to false, which means the signal handler can be run multiple times. If true, the DispatchSignalSource will be cancelled after being trapped once.
    /// - returns: a `DispatchSourceSignal` for the given trap. The source must be cancelled by the caller.
    public static func trap(signal sig: Signal, handler: @escaping (Signal) -> Void, on queue: DispatchQueue = .global(), cancelAfterTrap: Bool = false) -> DispatchSourceSignal {
        let signalSource = DispatchSource.makeSignalSource(signal: sig.rawValue, queue: queue)
        signal(sig.rawValue, SIG_IGN)
        signalSource.setEventHandler(handler: {
            if cancelAfterTrap {
                signalSource.cancel()
            }
            handler(sig)
        })
        signalSource.resume()
        return signalSource
    }

    /// A system signal
    public struct Signal: Equatable, CustomStringConvertible {
        internal var rawValue: CInt

        public static let TERM = Signal(rawValue: SIGTERM)
        public static let INT = Signal(rawValue: SIGINT)
        public static let USR1 = Signal(rawValue: SIGUSR1)
        public static let USR2 = Signal(rawValue: SIGUSR2)
        public static let HUP = Signal(rawValue: SIGHUP)

        // for testing
        internal static let ALRM = Signal(rawValue: SIGALRM)

        public var description: String {
            var result = "Signal("
            switch self {
            case Signal.TERM: result += "TERM, "
            case Signal.INT: result += "INT, "
            case Signal.ALRM: result += "ALRM, "
            case Signal.USR1: result += "USR1, "
            case Signal.USR2: result += "USR2, "
            case Signal.HUP: result += "HUP, "
            default: () // ok to ignore
            }
            result += "rawValue: \(self.rawValue))"
            return result
        }
    }
}

extension ServiceLifecycle: LifecycleTasksContainer {
    public func register(_ tasks: [LifecycleTask]) {
        self.underlying.register(tasks)
    }
}

extension ServiceLifecycle {
    /// `ServiceLifecycle` configuration options.
    public struct Configuration {
        /// Defines the `label` for the lifeycle and its Logger
        public var label: String
        /// Defines the `Logger` to log with.
        public var logger: Logger
        /// Defines the `DispatchQueue` on which startup and shutdown callback handlers are run.
        public var callbackQueue: DispatchQueue
        /// Defines what, if any, signals to trap for invoking shutdown.
        public var shutdownSignal: [Signal]?
        /// Defines if to install a crash signal trap that prints backtraces.
        public var installBacktrace: Bool

        public init(label: String = "Lifecycle",
                    logger: Logger? = nil,
                    callbackQueue: DispatchQueue = .global(),
                    shutdownSignal: [Signal]? = [.TERM, .INT],
                    installBacktrace: Bool = true) {
            self.label = label
            self.logger = logger ?? Logger(label: label)
            self.callbackQueue = callbackQueue
            self.shutdownSignal = shutdownSignal
            self.installBacktrace = installBacktrace
        }
    }
}

struct ShutdownError: Error {
    public let errors: [String: Error]
}

// MARK: - ComponentLifecycle

/// `ComponentLifecycle` provides a basic mechanism to cleanly startup and shutdown a subsystem in a larger application, freeing resources in order before exiting.
public class ComponentLifecycle: LifecycleTask {
    public let label: String
    private let logger: Logger

    private var waitlist = [UnsafeContinuation<Void, Error>]()
    private let waitlistLock = Lock()

    private var state = State.idle([])
    private let stateLock = Lock()

    /// Creates a `ComponentLifecycle` instance.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - logger: `Logger` to log with.
    public init(label: String, logger: Logger? = nil) {
        self.label = label
        self.logger = logger ?? Logger(label: label)
        //self.shutdownGroup.enter()
    }

    /// Starts the provided `LifecycleTask` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    @available(*, deprecated)
    public func start(_ callback: @escaping (Error?) -> Void) {
        // FIXME
        fatalError("not implemented")
    }

    /// Starts the provided `LifecycleTask` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handlers callback  on
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    @available(*, deprecated)
    public func start(on queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        // FIXME
        fatalError("not implemented")
    }

    public func start() async throws {
        /*var shutdownContinuation: UnsafeContinuation<Void, Error>
        try await withUnsafeThrowingContinuation{ cc in
            shutdownContinuation = cc
        }*/

        let tasks = self.stateLock.withLock { () -> [LifecycleTask] in
            guard case .idle(let tasks) = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            self.state = .starting(tasks, 0)
            return tasks
        }

        self.log("starting")
        Counter(label: "\(self.label).lifecycle.start").increment()

        if tasks.count == 0 {
            self.log(level: .notice, "no tasks provided")
        }

        do {
            try await self.startTask(tasks: tasks, index: 0)
        } catch {
            try await self.shutdown()
        }

        self.stateLock.lock()
        switch self.state {
        case .shuttingDown:
            self.stateLock.unlock()
            // shutdown was called while starting, or start failed, shutdown what we can
            //let stoppable: [LifecycleTask]
            //if started < tasks.count {
            //    stoppable = tasks.enumerated().filter { $0.offset <= started || $0.element.shutdownIfNotStarted }.map { $0.element }
            //} else {
            //    stoppable = tasks
            //}
            //await self._shutdown(tasks: stoppable)
            // TODO: verify this works, used to be that the group was left after callback go the error
            //self.shutdownGroup.leave()
            //if let error = error {
            //    throw error
            //}
        case .shutdown:
            self.stateLock.unlock()
        case .starting:
            self.state = .started(tasks)
            self.stateLock.unlock()
        default:
            preconditionFailure("invalid state, \(self.state)")
        }
    }

    /// Starts the provided `LifecycleTask` array and waits (blocking) until `shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handlers callback on
    @available(*, deprecated)
    public func startAndWait(on queue: DispatchQueue = .global()) throws {
        // FIXME
        fatalError("not implemented")
    }

    public func startAndWait() async throws {
        try await self.start()
        try await self.wait()
    }

    /// Shuts down the `LifecycleTask` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    @available(*, deprecated)
    public func shutdown(_ callback: @escaping (Error?) -> Void = { _ in }) {
        // FIXME
        fatalError("not implemented")
    }

    public func shutdown() async throws {
        self.stateLock.lock()
        switch self.state {
        case .idle:
            self.state = .shutdown(nil)
            self.stateLock.unlock()
        case .starting(let tasks, let started):
            let stoppable: [LifecycleTask]
            if started < tasks.count {
                stoppable = tasks.enumerated().filter { $0.offset <= started || $0.element.shutdownIfNotStarted }.map { $0.element }
            } else {
                stoppable = tasks
            }
            let handle: Task.Handle<Void, Error> = Task.runDetached {
                try await self._shutdown(tasks: stoppable)
            }
            self.state = .shuttingDown(handle)
            self.stateLock.unlock()
            try await handle.get()
        case .started(let tasks):
            let handle: Task.Handle<Void, Error> = Task.runDetached {
                try await self._shutdown(tasks: tasks)
            }
            self.state = .shuttingDown(handle)
            self.stateLock.unlock()
            try await handle.get()
        case .shuttingDown(let handle):
            self.stateLock.unlock()
            try await handle.get()
        case .shutdown:
            self.stateLock.unlock()
            self.log(level: .warning, "already shutdown")
        }

        guard case .shutdown(let errors) = self.state else {
            preconditionFailure("invalid state, \(self.state)")
        }
        let result: Result<Void, Error> = errors.flatMap{ .failure(Lifecycle.ShutdownError(errors: $0)) } ?? .success(())
        let waitlist = self.waitlistLock.withLock{ self.waitlist }
        waitlist.forEach { $0.resume(with: result) }
    }

    /// Waits (blocking) until `shutdown` is invoked on another thread.
    @available(*, deprecated)
    public func _wait() {
        // FIXME
        fatalError("not implemented")
    }

    public func wait() async throws {
        try await withUnsafeThrowingContinuation{ continuation in
            self.waitlistLock.withLock{
                self.waitlist.append(continuation)
            }
        }
    }

    // MARK: - internal

    internal var idle: Bool {
        if case .idle = self.state {
            return true
        } else {
            return false
        }
    }

    // MARK: - private

    private func startTask(tasks: [LifecycleTask], index: Int) async throws {
        // FIXME
        // async barrier
        //let start = { (callback) -> Void in queue.async { tasks[index].start(callback) } }
        //let callback = { (index, error) -> Void in queue.async { callback(index, error) } }

        if index >= tasks.count {
            return
        }

        self.log("starting tasks [\(tasks[index].label)]")
        let startTime = DispatchTime.now()

        do  {
            try await tasks[index].start()
            Timer(label: "\(self.label).\(tasks[index].label).lifecycle.start").recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
            // shutdown called while starting
            guard case .starting = (self.stateLock.withLock{ self.state }) else {
                return
            }
            self.stateLock.withLock {
                self.state = .starting(tasks, index)
            }
            return try await self.startTask(tasks: tasks, index: index + 1)
        } catch {
            self.log(level: .error, "failed to start [\(tasks[index].label)]: \(error)")
            throw error
        }
    }

    private func _shutdown(tasks: [LifecycleTask]) async throws {
        self.log("shutting down")
        Counter(label: "\(self.label).lifecycle.shutdown").increment()

        let errors = await self.shutdownTask(tasks: tasks.reversed(), index: 0, errors: nil)
        try self.stateLock.withLock {
            guard case .shuttingDown = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            self.state = .shutdown(errors)
            try errors.flatMap{ throw Lifecycle.ShutdownError(errors: $0) }

        }
        self.log("bye")
    }

    private func shutdownTask(tasks: [LifecycleTask], index: Int, errors: [String: Error]?) async -> [String: Error]? {
        // FIXME
        // async barrier
        //let shutdown = { (callback) -> Void in queue.async { tasks[index].shutdown(callback) } }
        //let callback = { (errors) -> Void in queue.async { callback(errors) } }

        if index >= tasks.count {
            return errors
        }

        self.log("stopping tasks [\(tasks[index].label)]")
        let startTime = DispatchTime.now()

        do {
            try await tasks[index].shutdown()
            Timer(label: "\(self.label).\(tasks[index].label).lifecycle.shutdown").recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
        } catch {
            self.log(level: .error, "failed to stop [\(tasks[index].label)]: \(error)")
            var errors = errors
            if errors == nil {
                errors = [:]
            }
            errors![tasks[index].label] = error
        }
        // continue to next shutdown task regardless of previous shutdown result
        return await self.shutdownTask(tasks: tasks, index: index + 1, errors: errors)
    }

    internal func log(level: Logger.Level = .info, _ message: String) {
        self.logger.log(level: level, "[\(self.label)] \(message)")
    }

    private enum State {
        case idle([LifecycleTask])
        case starting([LifecycleTask], Int)
        case started([LifecycleTask])
        case shuttingDown(Task.Handle<Void, Error>)
        case shutdown([String: Error]?)
    }
}

extension ComponentLifecycle: LifecycleTasksContainer {
    public func register(_ tasks: [LifecycleTask]) {
        self.stateLock.withLock {
            guard case .idle(let existing) = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            self.state = .idle(existing + tasks)
        }
    }
}

/// A container of `LifecycleTask`, used to register additional `LifecycleTask`
public protocol LifecycleTasksContainer {
    /// Adds a `LifecycleTask` to a `LifecycleTasks` collection.
    ///
    /// - parameters:
    ///    - tasks: array of `LifecycleTask`.
    func register(_ tasks: [LifecycleTask])
}

extension LifecycleTasksContainer {
    /// Adds a `LifecycleTask` to a `LifecycleTasks` collection.
    ///
    /// - parameters:
    ///    - tasks: one or more `LifecycleTask`.
    public func register(_ tasks: LifecycleTask ...) {
        self.register(tasks)
    }

    /// Adds a `LifecycleTask` to a `LifecycleTasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: `Handler` to perform the startup.
    ///    - shutdown: `Handler` to perform the shutdown.
    public func register(label: String, start: LifecycleHandler, shutdown: LifecycleHandler, shutdownIfNotStarted: Bool? = nil) {
        self.register(_LifecycleTask(label: label, shutdownIfNotStarted: shutdownIfNotStarted, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleTask` to a `LifecycleTasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - handler: `Handler` to perform the shutdown.
    public func registerShutdown(label: String, _ handler: LifecycleHandler) {
        self.register(label: label, start: .none, shutdown: handler)
    }

    /// Add a stateful `LifecycleTask` to a `LifecycleTasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: `LifecycleStartHandler` to perform the startup and return the state.
    ///    - shutdown: `LifecycleShutdownHandler` to perform the shutdown given the state.
    public func registerStateful<State>(label: String, start: LifecycleStartHandler<State>, shutdown: LifecycleShutdownHandler<State>) {
        self.register(StatefulLifecycleTask(label: label, start: start, shutdown: shutdown))
    }
}

// internal for testing
internal struct _LifecycleTask: LifecycleTask {
    let label: String
    let shutdownIfNotStarted: Bool
    let startHandler: LifecycleHandler
    let shutdownHandler: LifecycleHandler

    init(label: String, shutdownIfNotStarted: Bool? = nil, start: LifecycleHandler, shutdown: LifecycleHandler) {
        self.label = label
        self.shutdownIfNotStarted = shutdownIfNotStarted ?? start.noop
        self.startHandler = start
        self.shutdownHandler = shutdown
    }

    func start() async throws {
        try await self.startHandler.run()
    }

    func shutdown() async throws  {
        try await self.shutdownHandler.run()
    }
}

// internal for testing
internal class StatefulLifecycleTask<State>: LifecycleTask {
    let label: String
    let shutdownIfNotStarted: Bool = false
    let startHandler: LifecycleStartHandler<State>
    let shutdownHandler: LifecycleShutdownHandler<State>

    let stateLock = Lock()
    var state: State?

    init(label: String, start: LifecycleStartHandler<State>, shutdown: LifecycleShutdownHandler<State>) {
        self.label = label
        self.startHandler = start
        self.shutdownHandler = shutdown
    }

    func start() async throws {
        let state = try await self.startHandler.run()
        self.stateLock.withLock {
            self.state = state
        }
    }

    func shutdown() async throws {
        guard let state = (self.stateLock.withLock { self.state }) else {
            throw UnknownState()
        }
        try await self.shutdownHandler.run(state: state)
    }

    struct UnknownState: Error {}
}
#endif
