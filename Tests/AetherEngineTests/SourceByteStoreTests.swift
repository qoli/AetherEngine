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
}
