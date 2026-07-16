import Foundation
import Testing
@testable import AetherEngine

@Suite("Source byte store", .serialized)
struct SourceByteStoreTests {
    @Test("Overlapping writes merge into one immutable complete generation")
    func overlappingWritesBecomeComplete() throws {
        let store = try SourceByteStore(
            blockSize: 8,
            capacityBytes: 32
        )
        let directory = store.sessionDirectory
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 12,
            validator: .strongETag("\"generation-a\"")
        )
        try store.admit(generation)

        try store.store(Data([0, 1, 2, 3, 4, 5]), at: 0)
        try store.store(Data([4, 5, 6, 7, 8, 9]), at: 4)
        try store.store(Data([10, 11]), at: 10)

        #expect(try store.read(at: 0, maximumLength: 12) == Data(0...7))
        #expect(try store.read(at: 8, maximumLength: 12) == Data(8...11))
        #expect(store.snapshot == SourceByteStoreSnapshot(
            generation: generation,
            residentBytes: 12,
            isComplete: true
        ))
        #expect(store.validationCandidate
            == SourceByteStoreValidationCandidate(
                generation: generation,
                isComplete: true
            ))

        store.close()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: SourceByteStoreError.closed) {
            _ = try store.read(at: 0, maximumLength: 1)
        }
    }

    @Test("Capacity evicts the least recently used block without inventing coverage")
    func boundedLRUEviction() throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 8
        )
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 12,
            validator: .lastModified("Wed, 16 Jul 2026 12:00:00 GMT")
        )
        try store.admit(generation)

        try store.store(Data([0, 1, 2, 3]), at: 0)
        try store.store(Data([4, 5, 6, 7]), at: 4)
        #expect(try store.read(at: 0, maximumLength: 1) == Data([0]))
        try store.store(Data([8, 9, 10, 11]), at: 8)

        #expect(try store.read(at: 0, maximumLength: 4) == Data([0, 1, 2, 3]))
        #expect(try store.read(at: 4, maximumLength: 4) == nil)
        #expect(try store.read(at: 8, maximumLength: 4) == Data([8, 9, 10, 11]))
        #expect(store.snapshot == SourceByteStoreSnapshot(
            generation: generation,
            residentBytes: 8,
            isComplete: false
        ))
        #expect(store.validationCandidate
            == SourceByteStoreValidationCandidate(
                generation: generation,
                isComplete: false
            ))
    }

    @Test("Generation mismatch fails before bytes from revisions can mix")
    func generationMismatchFails() throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 8
        )
        defer { store.close() }
        let first = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-a\"")
        )
        let replacement = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-b\"")
        )
        try store.admit(first)
        try store.store(Data([0, 1, 2, 3]), at: 0)

        #expect(throws: SourceByteStoreError.generationMismatch) {
            try store.admit(replacement)
        }
        #expect(try store.read(at: 0, maximumLength: 4) == Data([0, 1, 2, 3]))

        try store.replaceGeneration(with: replacement)
        #expect(try store.read(at: 0, maximumLength: 4) == nil)
        #expect(store.snapshot == SourceByteStoreSnapshot(
            generation: replacement,
            residentBytes: 0,
            isComplete: false
        ))
    }

    @Test("Cache-only validation requires a strong in-memory source validator")
    func validationRequiresValidator() throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 8
        )
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 4,
            validator: nil
        )
        try store.admit(generation)
        try store.store(Data([0, 1, 2, 3]), at: 0)

        #expect(store.snapshot?.isComplete == true)
        #expect(store.validationCandidate == nil)
    }

    @Test("Concurrent exact-range misses use one origin producer")
    func exactRangeSingleFlight() async throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 16
        )
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-a\"")
        )
        let data = Data(0...7)
        let leaderStarted = DispatchSemaphore(value: 0)
        let releaseLeader = DispatchSemaphore(value: 0)
        let followerWaiting = DispatchSemaphore(value: 0)
        let producer = LockedRangeProducer()

        let leader = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: { false },
                originFetch: {
                    producer.begin()
                    leaderStarted.signal()
                    releaseLeader.wait()
                    producer.end()
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(leaderStarted)
        )

        let follower = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: {
                    followerWaiting.signal()
                    return false
                },
                originFetch: {
                    producer.begin()
                    defer { producer.end() }
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(followerWaiting)
        )
        releaseLeader.signal()

        #expect(try await leader.value == data)
        #expect(try await follower.value == data)
        let resident = try store.fetchExactRange(
            at: 0,
            length: 8,
            shouldAbort: { false },
            originFetch: {
                Issue.record(
                    "resident exact range must not refetch"
                )
                return SourceByteStoreFetchedRange(
                    generation: generation,
                    data: data
                )
            }
        )
        #expect(resident == data)
        #expect(producer.snapshot.count == 1)
        #expect(producer.snapshot.maximumConcurrent == 1)
    }

    @Test("Cancelling one follower does not cancel the shared leader")
    func followerCancellationIsIsolated() async throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 16
        )
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-a\"")
        )
        let data = Data(0...7)
        let leaderStarted = DispatchSemaphore(value: 0)
        let releaseLeader = DispatchSemaphore(value: 0)
        let producer = LockedRangeProducer()

        let leader = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: { false },
                originFetch: {
                    producer.begin()
                    leaderStarted.signal()
                    releaseLeader.wait()
                    producer.end()
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(leaderStarted)
        )

        let cancelledFollower = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: { true },
                originFetch: {
                    producer.begin()
                    defer { producer.end() }
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        do {
            _ = try await cancelledFollower.value
            Issue.record("expected follower cancellation")
        } catch let error as SourceByteStoreError {
            #expect(error == .cancelled)
        }

        releaseLeader.signal()
        #expect(try await leader.value == data)
        #expect(producer.snapshot.count == 1)
    }

    @Test("A surviving follower replaces a cancelled leader without overlapping origin work")
    func cancelledLeaderPromotesFollower() async throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 16
        )
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-a\"")
        )
        let data = Data(0...7)
        let leaderStarted = DispatchSemaphore(value: 0)
        let releaseLeader = DispatchSemaphore(value: 0)
        let followerWaiting = DispatchSemaphore(value: 0)
        let producer = LockedRangeProducer()

        let leader = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: { false },
                originFetch: {
                    producer.begin()
                    leaderStarted.signal()
                    releaseLeader.wait()
                    producer.end()
                    throw SourceByteStoreError.cancelled
                }
            )
        }
        #expect(
            await waitForSemaphore(leaderStarted)
        )

        let follower = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: {
                    followerWaiting.signal()
                    return false
                },
                originFetch: {
                    producer.begin()
                    defer { producer.end() }
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(followerWaiting)
        )
        releaseLeader.signal()

        do {
            _ = try await leader.value
            Issue.record("expected leader cancellation")
        } catch let error as SourceByteStoreError {
            #expect(error == .cancelled)
        }
        #expect(try await follower.value == data)
        #expect(producer.snapshot.count == 2)
        #expect(producer.snapshot.maximumConcurrent == 1)
    }

    @Test("Generation reset terminates every exact-range waiter")
    func resetTerminatesRangeFlight() async throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 16
        )
        defer { store.close() }
        let generation = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-a\"")
        )
        let data = Data(0...7)
        let leaderStarted = DispatchSemaphore(value: 0)
        let releaseLeader = DispatchSemaphore(value: 0)
        let followerWaiting = DispatchSemaphore(value: 0)

        let leader = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: { false },
                originFetch: {
                    leaderStarted.signal()
                    releaseLeader.wait()
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(leaderStarted)
        )

        let follower = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: {
                    followerWaiting.signal()
                    return false
                },
                originFetch: {
                    Issue.record(
                        "invalidated follower must not fetch"
                    )
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(followerWaiting)
        )
        try store.reset()
        releaseLeader.signal()

        for task in [leader, follower] {
            do {
                _ = try await task.value
                Issue.record(
                    "expected generation mismatch"
                )
            } catch let error as SourceByteStoreError {
                #expect(error == .generationMismatch)
            }
        }
        #expect(store.snapshot == nil)
    }

    @Test("Close terminates every exact-range waiter and removes session bytes")
    func closeTerminatesRangeFlight() async throws {
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 16
        )
        let directory = store.sessionDirectory
        let generation = try SourceByteStoreGeneration(
            contentLength: 8,
            validator: .strongETag("\"generation-a\"")
        )
        let data = Data(0...7)
        let leaderStarted = DispatchSemaphore(value: 0)
        let releaseLeader = DispatchSemaphore(value: 0)
        let followerWaiting = DispatchSemaphore(value: 0)

        let leader = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: { false },
                originFetch: {
                    leaderStarted.signal()
                    releaseLeader.wait()
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(leaderStarted)
        )

        let follower = Task.detached {
            try store.fetchExactRange(
                at: 0,
                length: 8,
                shouldAbort: {
                    followerWaiting.signal()
                    return false
                },
                originFetch: {
                    Issue.record(
                        "closed follower must not fetch"
                    )
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: data
                    )
                }
            )
        }
        #expect(
            await waitForSemaphore(followerWaiting)
        )
        store.close()
        releaseLeader.signal()

        for task in [leader, follower] {
            do {
                _ = try await task.value
                Issue.record("expected closed")
            } catch let error as SourceByteStoreError {
                #expect(error == .closed)
            }
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.path
            )
        )
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning:
                    semaphore.wait(
                        timeout: .now() + 2
                    ) == .success
            )
        }
    }
}

private final class LockedRangeProducer:
    @unchecked Sendable
{
    struct Snapshot {
        let count: Int
        let maximumConcurrent: Int
    }

    private let lock = NSLock()
    private var count = 0
    private var concurrent = 0
    private var maximumConcurrent = 0

    func begin() {
        lock.lock()
        count += 1
        concurrent += 1
        maximumConcurrent = max(
            maximumConcurrent,
            concurrent
        )
        lock.unlock()
    }

    func end() {
        lock.lock()
        concurrent -= 1
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            count: count,
            maximumConcurrent: maximumConcurrent
        )
    }
}
