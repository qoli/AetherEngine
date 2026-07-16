import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier composite HLS provider", .serialized)
struct BlackCarrierCompositeProviderTests {
    @Test("Track metadata produces one default and unique deterministic names")
    func renditionMetadata() {
        let tracks = [
            makeTrack(id: 2, name: "English", language: "eng", isDefault: false),
            makeTrack(id: 3, name: "English", language: "eng", isDefault: true),
            makeTrack(id: 4, name: "", language: nil, isDefault: true),
        ]

        let metadata = BlackCarrierCompositeProvider.renditionMetadata(
            for: tracks
        )

        #expect(metadata.map(\.ordinal) == [0, 1, 2])
        #expect(metadata.map(\.sourceTrackID) == [2, 3, 4])
        #expect(metadata.map(\.name) == ["English", "English 2", "Audio 3"])
        #expect(metadata.map(\.isDefault) == [false, true, false])
        #expect(metadata.allSatisfy { $0.isAutoselect })
    }

    @Test("Composite provider serves black video and every disk-backed audio rendition")
    func compositeProvider() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)

        let trackInfos = [
            makeTrack(
                id: 0,
                name: "English",
                language: "eng",
                isDefault: true
            ),
            makeTrack(
                id: 1,
                name: "日本語",
                language: "jpn",
                isDefault: false
            ),
        ]
        let metadata = BlackCarrierCompositeProvider.renditionMetadata(
            for: trackInfos
        )

        let englishDemuxer = try makeWAVDemuxer(seconds: 5.25, frequency: 440)
        defer { englishDemuxer.close() }
        let japaneseDemuxer = try makeWAVDemuxer(seconds: 5.25, frequency: 660)
        defer { japaneseDemuxer.close() }

        let english = try BlackCarrierAudioRenditionStore(
            metadata: metadata[0],
            demuxer: englishDemuxer,
            audioStreamIndex: englishDemuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline
        )
        let japanese = try BlackCarrierAudioRenditionStore(
            metadata: metadata[1],
            demuxer: japaneseDemuxer,
            audioStreamIndex: japaneseDemuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline
        )

        let videoDirectory = videoProvider.sessionDirectory
        let audioDirectories = [
            english.sessionDirectory,
            japanese.sessionDirectory,
        ]
        let expectedBandwidth =
            try #require(videoProvider.masterBandwidth)
            + max(english.peakBandwidth, japanese.peakBandwidth)
        let expectedAverageBandwidth =
            try #require(videoProvider.masterAverageBandwidth)
            + max(english.averageBandwidth, japanese.averageBandwidth)

        let provider = try BlackCarrierCompositeProvider(
            videoProvider: videoProvider,
            audioStores: [english, japanese]
        )

        #expect(provider.segmentCount == 2)
        #expect(provider.masterCodecs == "avc1.42C01E,ec-3")
        #expect(provider.masterBandwidth == expectedBandwidth)
        #expect(provider.masterAverageBandwidth == expectedAverageBandwidth)
        #expect(provider.alternateAudioRenditions.map(\.name) == [
            "English",
            "日本語",
        ])
        #expect(provider.sourceTrackID(forAudioOrdinal: 0) == 0)
        #expect(provider.sourceTrackID(forAudioOrdinal: 1) == 1)
        #expect(provider.sourceTrackID(forAudioOrdinal: 9) == nil)

        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(master.contains("CODECS=\"avc1.42C01E,ec-3\""))
        #expect(master.contains("AUDIO=\"audio\""))
        #expect(master.contains("BANDWIDTH=\(expectedBandwidth)"))
        #expect(master.contains("AVERAGE-BANDWIDTH=\(expectedAverageBandwidth)"))

        guard case .master(let parsedMaster) = try HLSPlaylistParser.parse(master) else {
            Issue.record("Expected a carrier master playlist")
            return
        }
        #expect(parsedMaster.audioRenditions.count == 2)

        for ordinal in 0...1 {
            #expect(provider.alternateAudioInitSegment(ordinal: ordinal) != nil)
            #expect(provider.alternateAudioMediaSegment(
                ordinal: ordinal,
                index: 0
            ) != nil)
            let segmentURL = try #require(
                provider.alternateAudioMediaSegmentURL(
                    ordinal: ordinal,
                    index: 1
                )
            )
            #expect(FileManager.default.fileExists(atPath: segmentURL.path))
            let playlist = try #require(
                HLSLocalServer.buildAlternateAudioMediaPlaylistText(
                    ordinal: ordinal,
                    provider: provider
                )
            )
            guard case .media(let parsed) = try HLSPlaylistParser.parse(playlist) else {
                Issue.record("Expected an audio media playlist")
                return
            }
            #expect(parsed.segments.map(\.duration) == [4, 1.25])
        }

        #expect(provider.alternateAudioInitSegment(ordinal: 9) == nil)
        #expect(provider.alternateAudioMediaSegment(
            ordinal: 0,
            index: 9
        ) == nil)

        provider.close()
        #expect(!FileManager.default.fileExists(atPath: videoDirectory.path))
        for directory in audioDirectories {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("Invalid audio group fails atomically and closes every session directory")
    func invalidGroupClosesStorage() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)
        let first = try makeStore(
            metadata: BlackCarrierAudioRenditionMetadata(
                ordinal: 0,
                sourceTrackID: 7,
                language: "eng",
                name: "English",
                isDefault: true,
                isAutoselect: true
            ),
            timeline: timeline,
            frequency: 440
        )
        let duplicate = try makeStore(
            metadata: BlackCarrierAudioRenditionMetadata(
                ordinal: 1,
                sourceTrackID: 7,
                language: "jpn",
                name: "日本語",
                isDefault: false,
                isAutoselect: true
            ),
            timeline: timeline,
            frequency: 660
        )
        let directories = [
            videoProvider.sessionDirectory,
            first.sessionDirectory,
            duplicate.sessionDirectory,
        ]

        #expect(throws: BlackCarrierCompositeProviderError.duplicateSourceTrackID(
            id: 7
        )) {
            _ = try BlackCarrierCompositeProvider(
                videoProvider: videoProvider,
                audioStores: [first, duplicate]
            )
        }
        for directory in directories {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    private func makeTrack(
        id: Int,
        name: String,
        language: String?,
        isDefault: Bool
    ) -> TrackInfo {
        TrackInfo(
            id: id,
            name: name,
            codec: "pcm_s16le",
            language: language,
            channels: 2,
            isDefault: isDefault
        )
    }

    private func makeWAVDemuxer(
        seconds: Double,
        frequency: Double
    ) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: seconds,
            frequency: frequency
        )))
        return demuxer
    }

    private func makeStore(
        metadata: BlackCarrierAudioRenditionMetadata,
        timeline: BlackCarrierTimeline,
        frequency: Double
    ) throws -> BlackCarrierAudioRenditionStore {
        let demuxer = try makeWAVDemuxer(
            seconds: CMTimeGetSeconds(timeline.duration),
            frequency: frequency
        )
        defer { demuxer.close() }
        return try BlackCarrierAudioRenditionStore(
            metadata: metadata,
            demuxer: demuxer,
            audioStreamIndex: demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline
        )
    }

    private func makeWAV(
        sampleRate: Int,
        channels: Int,
        seconds: Double,
        frequency: Double
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * frequency * Double(frame) / Double(sampleRate)
                )
            )
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }

        var data = Data()
        func appendString(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }

        appendString("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * 2))
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
