import AudioToolbox
import CoreMedia
import Foundation
import Testing

@testable import Camcord

enum AudioTestPCM {
    enum Encoding {
        case float32
        case int16
        case int32

        var byteCount: Int {
            switch self {
            case .int16: 2
            case .float32, .int32: 4
            }
        }

        var flags: AudioFormatFlags {
            switch self {
            case .float32: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            case .int16, .int32: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            }
        }

        var bits: UInt32 { UInt32(byteCount * 8) }
    }

    struct Decoded {
        let channels: [[Double]]
        let asbd: AudioStreamBasicDescription
    }

    static func make(
        channels: [[Double]],
        encoding: Encoding = .float32,
        interleaved: Bool = true,
        sampleRate: Double = 48_000,
        presentationTimeStamp: CMTime = CMTime(value: 12_345, timescale: 48_000),
        formatFlags: AudioFormatFlags? = nil
    ) throws -> CMSampleBuffer {
        guard let frameCount = channels.first?.count, frameCount > 0,
              channels.allSatisfy({ $0.count == frameCount })
        else { throw TestError.invalidChannels }

        let channelCount = channels.count
        let bytesPerFrame = encoding.byteCount * (interleaved ? channelCount : 1)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags ?? (encoding.flags | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved)),
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: encoding.bits,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { throw TestError.coreMedia(formatStatus) }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let createStatus: OSStatus
        if interleaved {
            createStatus = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
        } else {
            createStatus = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
        }
        guard createStatus == noErr, let sampleBuffer else { throw TestError.coreMedia(createStatus) }

        let encodedBuffers: [[UInt8]]
        let bufferChannels: [Int]
        if interleaved {
            var values: [Double] = []
            values.reserveCapacity(frameCount * channelCount)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount { values.append(channels[channel][frame]) }
            }
            encodedBuffers = [encode(values, as: encoding)]
            bufferChannels = [channelCount]
        } else {
            encodedBuffers = channels.map { encode($0, as: encoding) }
            bufferChannels = Array(repeating: 1, count: channelCount)
        }
        try attach(encodedBuffers, channelCounts: bufferChannels, to: sampleBuffer)
        return sampleBuffer
    }

    static func decode(_ sampleBuffer: CMSampleBuffer) throws -> Decoded {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { throw TestError.invalidFormat }
        let encoding: Encoding
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
            encoding = .float32
        } else if asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 16 {
            encoding = .int16
        } else if asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 32 {
            encoding = .int32
        } else { throw TestError.invalidFormat }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let audioBuffers = try copyBuffers(sampleBuffer)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        if interleaved {
            let channelCount = Int(asbd.mChannelsPerFrame)
            let flat = decode(audioBuffers[0].bytes, as: encoding, count: frameCount * channelCount)
            var channels = Array(repeating: [Double](), count: channelCount)
            for channel in channels.indices { channels[channel].reserveCapacity(frameCount) }
            for frame in 0..<frameCount {
                for channel in 0..<channelCount { channels[channel].append(flat[frame * channelCount + channel]) }
            }
            return Decoded(channels: channels, asbd: asbd)
        }
        return Decoded(
            channels: audioBuffers.map { decode($0.bytes, as: encoding, count: frameCount * $0.channels) },
            asbd: asbd
        )
    }

    private struct RawAudioBuffer {
        let channels: Int
        let bytes: Data
    }

    private static func copyBuffers(_ sampleBuffer: CMSampleBuffer) throws -> [RawAudioBuffer] {
        var size = 0
        let sizing = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: nil
        )
        guard sizing == noErr else { throw TestError.coreMedia(sizing) }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retained
        )
        guard status == noErr else { throw TestError.coreMedia(status) }
        return try UnsafeMutableAudioBufferListPointer(list).map { buffer in
            guard let data = buffer.mData else { throw TestError.invalidData }
            return RawAudioBuffer(
                channels: Int(buffer.mNumberChannels),
                bytes: Data(bytes: data, count: Int(buffer.mDataByteSize))
            )
        }
    }

    private static func attach(
        _ buffers: [[UInt8]], channelCounts: [Int], to sampleBuffer: CMSampleBuffer
    ) throws {
        let listSize = MemoryLayout<AudioBufferList>.size
            + max(0, buffers.count - 1) * MemoryLayout<AudioBuffer>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(buffers.count)
        let pointer = UnsafeMutableAudioBufferListPointer(list)
        var allocations: [UnsafeMutableRawPointer] = []
        defer {
            allocations.forEach { $0.deallocate() }
            storage.deallocate()
        }
        for index in buffers.indices {
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: max(1, buffers[index].count), alignment: 16)
            allocations.append(allocation)
            buffers[index].withUnsafeBytes { raw in
                if let base = raw.baseAddress { memcpy(allocation, base, raw.count) }
            }
            pointer[index] = AudioBuffer(
                mNumberChannels: UInt32(channelCounts[index]),
                mDataByteSize: UInt32(buffers[index].count),
                mData: allocation
            )
        }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: list
        )
        guard status == noErr else { throw TestError.coreMedia(status) }
    }

    private static func encode(_ values: [Double], as encoding: Encoding) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: values.count * encoding.byteCount)
        result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in values.indices {
                let address = base.advanced(by: index * encoding.byteCount)
                switch encoding {
                case .float32:
                    var value = Float(values[index])
                    memcpy(address, &value, 4)
                case .int16:
                    var value = Int16((min(max(values[index], -1), 1) * Double(Int16.max)).rounded())
                    memcpy(address, &value, 2)
                case .int32:
                    var value = Int32((min(max(values[index], -1), 1) * Double(Int32.max)).rounded())
                    memcpy(address, &value, 4)
                }
            }
        }
        return result
    }

    private static func decode(_ data: Data, as encoding: Encoding, count: Int) -> [Double] {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            return (0..<count).map { index in
                let address = base.advanced(by: index * encoding.byteCount)
                switch encoding {
                case .float32:
                    var value: Float = 0
                    memcpy(&value, address, 4)
                    return Double(value)
                case .int16:
                    var value: Int16 = 0
                    memcpy(&value, address, 2)
                    return Double(value) / 32_768
                case .int32:
                    var value: Int32 = 0
                    memcpy(&value, address, 4)
                    return Double(value) / 2_147_483_648
                }
            }
        }
    }

    enum TestError: Error {
        case invalidChannels
        case invalidFormat
        case invalidData
        case coreMedia(OSStatus)
    }
}

@Suite("AudioSampleProcessor")
struct AudioSampleProcessorTests {

    @Test("meter responds on every display frame with consistent 60/120 Hz ballistics")
    func displayRateMeterResponse() {
        var fast = AudioMeterMotion()
        fast.advance(rms: 0.8, peak: 0.95, elapsed: 1.0 / 120)
        #expect(fast.rms > 0.2 && fast.rms < 0.8)
        #expect(fast.peak == 0.95)
        var sixty = AudioMeterMotion()
        var oneTwenty = AudioMeterMotion()
        for _ in 0..<12 { sixty.advance(rms: 0.8, peak: 0.95, elapsed: 1.0 / 60) }
        for _ in 0..<24 { oneTwenty.advance(rms: 0.8, peak: 0.95, elapsed: 1.0 / 120) }
        #expect(abs(sixty.rms - oneTwenty.rms) < 0.00001)
        let beforeRelease = oneTwenty.rms
        oneTwenty.advance(rms: 0, peak: 0, elapsed: 1.0 / 120)
        #expect(oneTwenty.rms < beforeRelease && oneTwenty.rms > 0.7)
        #expect(oneTwenty.peak == 0.95)
        for _ in 0..<240 { oneTwenty.advance(rms: 0, peak: 0, elapsed: 1.0 / 120) }
        #expect(oneTwenty.rms < 0.001 && oneTwenty.peak < 0.3)
    }
    @Test("unity preserves identity, channel phase, timing, format, and source bytes")
    func unityNoCopyAndImmutable() throws {
        let left = [0.10, 0.20, -0.30, -0.40]
        let right = [-0.40, 0.30, -0.20, 0.10]
        let source = try AudioTestPCM.make(channels: [left, right])
        let sourceBefore = try AudioTestPCM.decode(source)
        let pts = CMSampleBufferGetPresentationTimeStamp(source)
        let duration = CMSampleBufferGetDuration(source)

        let output = try AudioSampleProcessor().process(source, gainDB: 0)
        let decoded = try AudioTestPCM.decode(output.sampleBuffer)

        #expect(output.sampleBuffer === source)
        #expect(decoded.channels == sourceBefore.channels)
        #expect(try AudioTestPCM.decode(source).channels == sourceBefore.channels)
        #expect(CMSampleBufferGetNumSamples(output.sampleBuffer) == CMSampleBufferGetNumSamples(source))
        #expect(CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer) == pts)
        #expect(CMSampleBufferGetDuration(output.sampleBuffer) == duration)
        #expect(decoded.asbd.mFormatFlags == sourceBefore.asbd.mFormatFlags)
        #expect(decoded.asbd.mChannelsPerFrame == sourceBefore.asbd.mChannelsPerFrame)
        #expect(abs(output.levels.peakDBFS - 20 * log10(0.4)) < 0.001)
        #expect(!output.levels.limited)
    }

    @Test("plus six decibels produces the expected amplitude in a new buffer")
    func gainProducesRealPCM() throws {
        let source = try AudioTestPCM.make(channels: [[0.10, -0.10], [0.05, -0.05]])
        let before = try AudioTestPCM.decode(source).channels
        let output = try AudioSampleProcessor().process(source, gainDB: 6)
        let decoded = try AudioTestPCM.decode(output.sampleBuffer).channels
        let expected = 0.1 * pow(10, 6.0 / 20.0)

        #expect(output.sampleBuffer !== source)
        #expect(abs(decoded[0][0] - expected) < 0.000_01)
        #expect(abs(decoded[0][1] + expected) < 0.000_01)
        #expect(try AudioTestPCM.decode(source).channels == before)
        #expect(!output.levels.limited)
    }

    @Test("planar Float32 preserves channel planes and relative phase")
    func planarFloat() throws {
        let left = [0.1, 0.2, 0.3, 0.4]
        let right = [-0.4, -0.3, -0.2, -0.1]
        let source = try AudioTestPCM.make(channels: [left, right], interleaved: false)
        let output = try AudioSampleProcessor().process(source, gainDB: -6)
        let decoded = try AudioTestPCM.decode(output.sampleBuffer)
        let scale = pow(10, -6.0 / 20.0)

        #expect(decoded.asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        for index in left.indices {
            #expect(abs(decoded.channels[0][index] - left[index] * scale) < 0.000_01)
            #expect(abs(decoded.channels[1][index] - right[index] * scale) < 0.000_01)
        }
    }

    @Test("signed PCM16 interleaved and PCM32 planar are supported")
    func signedIntegerPCM() throws {
        let int16 = try AudioTestPCM.make(
            channels: [[0.2, -0.2], [-0.1, 0.1]], encoding: .int16, interleaved: true
        )
        let int32 = try AudioTestPCM.make(
            channels: [[0.2, -0.2], [-0.1, 0.1]], encoding: .int32, interleaved: false
        )
        let int16Output = try AudioSampleProcessor().process(int16, gainDB: -3)
        let int32Output = try AudioSampleProcessor().process(int32, gainDB: -3)
        let expected = 0.2 * pow(10, -3.0 / 20.0)

        #expect(abs(try AudioTestPCM.decode(int16Output.sampleBuffer).channels[0][0] - expected) < 0.000_1)
        #expect(abs(try AudioTestPCM.decode(int32Output.sampleBuffer).channels[0][0] - expected) < 0.000_001)
    }

    @Test("overfull and non-finite Float32 samples become finite below the ceiling")
    func limiterProtectsOutput() throws {
        let source = try AudioTestPCM.make(
            channels: [[2.0, .nan, -.infinity], [-2.0, .infinity, 0.5]]
        )
        let output = try AudioSampleProcessor().process(source, gainDB: 24)
        let channels = try AudioTestPCM.decode(output.sampleBuffer).channels
        let samples = channels.flatMap { $0 }
        let ceiling = pow(10, -1.0 / 20.0)

        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples.map { abs($0) }.max()! <= ceiling + 0.000_01)
        #expect(output.levels.peakDBFS <= -1 + 0.000_01)
        #expect(output.levels.limited)
        #expect(try AudioTestPCM.decode(source).channels[0][0] == 2.0)
    }

    @Test("limiter attack is immediate and release persists across buffers")
    func limiterReleaseIsStateful() throws {
        let processor = AudioSampleProcessor()
        let hot = try AudioTestPCM.make(channels: [[1.0, 1.0], [1.0, 1.0]])
        let quiet = try AudioTestPCM.make(channels: [[0.1, 0.1], [0.1, 0.1]])
        let hotOutput = try processor.process(hot, gainDB: 6)
        let quietOutput = try processor.process(quiet, gainDB: 0)
        let quietPeak = try AudioTestPCM.decode(quietOutput.sampleBuffer).channels.flatMap { $0 }.map { abs($0) }.max()!

        #expect(hotOutput.levels.peakDBFS <= -1 + 0.000_01)
        #expect(hotOutput.levels.limited)
        #expect(quietOutput.levels.limited)
        #expect(quietPeak < 0.1)
        #expect(quietPeak > 0)
    }

    @Test("silence reports the documented floor")
    func silenceFloor() throws {
        let source = try AudioTestPCM.make(channels: [[0, 0, 0], [0, 0, 0]])
        let levels = try AudioSampleProcessor().process(source, gainDB: 0).levels
        #expect(levels == AudioLevels(rmsDBFS: -90, peakDBFS: -90, limited: false))
    }

    @Test("unsupported unsigned PCM is rejected explicitly")
    func unsupportedPCM() throws {
        let source = try AudioTestPCM.make(
            channels: [[0.1, -0.1]],
            encoding: .int16,
            formatFlags: kAudioFormatFlagIsPacked
        )
        do {
            _ = try AudioSampleProcessor().process(source, gainDB: 0)
            Issue.record("expected unsigned PCM to be rejected")
        } catch AudioSampleProcessor.ProcessingError.unsupportedFormat {
            // The error identifies the actual format ID, flags, and bit depth.
        }
    }
}
