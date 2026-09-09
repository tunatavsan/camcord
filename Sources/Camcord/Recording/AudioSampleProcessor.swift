import AudioToolbox
import CoreMedia
import Foundation

/// Levels measured from the processed PCM that is handed to the writer.
struct AudioLevels: Equatable, Sendable {
    let rmsDBFS: Double
    let peakDBFS: Double
    let limited: Bool
}

/// Stateful per-source gain, metering, and peak protection for uncompressed audio.
/// Callers confine each instance to one serial sample queue; limiter release state is
/// intentionally independent for system audio, microphone, and the final mixed stream.
final class AudioSampleProcessor {
    struct Output {
        let sampleBuffer: CMSampleBuffer
        let levels: AudioLevels
    }

    enum ProcessingError: Error, Equatable {
        case missingFormatDescription
        case unsupportedFormat(formatID: AudioFormatID, flags: AudioFormatFlags, bitsPerChannel: UInt32)
        case malformedBuffer(String)
        case coreMedia(OSStatus)
    }

    static let silenceFloorDBFS = -90.0
    static let ceilingDBFS = -1.0

    private static let ceilingLinear = pow(10.0, ceilingDBFS / 20.0)
    private static let minimumGainDB = -60.0
    private static let maximumGainDB = 24.0
    private static let releaseSeconds = 0.250

    private var limiterGain = 1.0

    func process(_ sampleBuffer: CMSampleBuffer, gainDB: Double) throws -> Output {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { throw ProcessingError.missingFormatDescription }

        let format = try PCMFormat(asbd: asbd)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount >= 0 else { throw ProcessingError.malformedBuffer("negative sample count") }
        if frameCount == 0 {
            return Output(
                sampleBuffer: sampleBuffer,
                levels: AudioLevels(rmsDBFS: Self.silenceFloorDBFS, peakDBFS: Self.silenceFloorDBFS, limited: false)
            )
        }

        let buffers = try Self.copyAudioBuffers(from: sampleBuffer)
        try format.validate(buffers: buffers, frameCount: frameCount)
        let decoded = try format.decode(buffers: buffers, frameCount: frameCount)

        let requestedDB = gainDB.isFinite
            ? min(max(gainDB, Self.minimumGainDB), Self.maximumGainDB)
            : 0
        let requestedGain = pow(10.0, requestedDB / 20.0)
        var sourcePeak = 0.0
        var hadNonFiniteSample = false
        for value in decoded {
            guard value.isFinite else {
                hadNonFiniteSample = true
                continue
            }
            sourcePeak = max(sourcePeak, abs(value))
        }

        let gainedPeak = sourcePeak * requestedGain
        let targetLimiterGain = gainedPeak > Self.ceilingLinear
            ? Self.ceilingLinear / gainedPeak
            : 1.0
        if targetLimiterGain < limiterGain {
            // Attack applies to the whole buffer, so even its first peak is protected.
            limiterGain = targetLimiterGain
        } else if limiterGain < 1 {
            let duration = Double(frameCount) / max(asbd.mSampleRate, 1)
            let release = 1 - (1 - limiterGain) * exp(-duration / Self.releaseSeconds)
            limiterGain = min(targetLimiterGain, release)
        }
        limiterGain = min(max(limiterGain, 0), 1)

        let totalGain = requestedGain * limiterGain
        let limited = limiterGain < 1 - 1e-12
        var processed = decoded
        var sumSquares = 0.0
        var outputPeak = 0.0
        for index in processed.indices {
            let input = processed[index].isFinite ? processed[index] : 0
            let output = min(max(input * totalGain, -Self.ceilingLinear), Self.ceilingLinear)
            processed[index] = output
            sumSquares += output * output
            outputPeak = max(outputPeak, abs(output))
        }
        let rms = sqrt(sumSquares / Double(processed.count))
        let levels = AudioLevels(
            rmsDBFS: Self.decibels(rms),
            peakDBFS: Self.decibels(outputPeak),
            limited: limited
        )

        // At exact unity with no limiter or invalid sample repair, retain the immutable
        // source rather than allocating/copying an equivalent PCM buffer.
        if totalGain == 1, !hadNonFiniteSample {
            return Output(sampleBuffer: sampleBuffer, levels: levels)
        }

        let encoded = try format.encode(processed, matching: buffers, frameCount: frameCount)
        let outputBuffer = try Self.makeSampleBuffer(
            from: sampleBuffer,
            formatDescription: formatDescription,
            audioBuffers: encoded
        )
        return Output(sampleBuffer: outputBuffer, levels: levels)
    }

    private static func decibels(_ linear: Double) -> Double {
        guard linear.isFinite, linear > 0 else { return silenceFloorDBFS }
        return max(silenceFloorDBFS, 20 * log10(linear))
    }

    private struct CopiedAudioBuffer {
        let channels: Int
        var data: Data
    }

    private enum SampleEncoding {
        case float32
        case int16
        case int32

        var byteCount: Int {
            switch self {
            case .int16: MemoryLayout<Int16>.size
            case .float32: MemoryLayout<Float>.size
            case .int32: MemoryLayout<Int32>.size
            }
        }
    }

    private struct PCMFormat {
        let asbd: AudioStreamBasicDescription
        let encoding: SampleEncoding
        let nonInterleaved: Bool

        init(asbd: AudioStreamBasicDescription) throws {
            self.asbd = asbd
            let flags = asbd.mFormatFlags
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  flags & kAudioFormatFlagIsBigEndian == 0,
                  flags & kAudioFormatFlagIsPacked != 0
            else {
                throw ProcessingError.unsupportedFormat(
                    formatID: asbd.mFormatID, flags: flags, bitsPerChannel: asbd.mBitsPerChannel
                )
            }

            if flags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
                encoding = .float32
            } else if flags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 16 {
                encoding = .int16
            } else if flags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 32 {
                encoding = .int32
            } else {
                throw ProcessingError.unsupportedFormat(
                    formatID: asbd.mFormatID, flags: flags, bitsPerChannel: asbd.mBitsPerChannel
                )
            }
            nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        }

        func validate(buffers: [CopiedAudioBuffer], frameCount: Int) throws {
            let channelCount = Int(asbd.mChannelsPerFrame)
            guard channelCount > 0, buffers.reduce(0, { $0 + $1.channels }) == channelCount else {
                throw ProcessingError.malformedBuffer("channel layout does not match the format description")
            }
            if nonInterleaved {
                guard buffers.count > 1 || channelCount == 1 else {
                    throw ProcessingError.malformedBuffer("non-interleaved PCM has no channel planes")
                }
            } else {
                guard buffers.count == 1 else {
                    throw ProcessingError.malformedBuffer("interleaved PCM has multiple buffers")
                }
            }
            for buffer in buffers {
                let required = frameCount * buffer.channels * encoding.byteCount
                guard buffer.data.count >= required else {
                    throw ProcessingError.malformedBuffer("PCM buffer is shorter than its sample count")
                }
            }
        }

        func decode(buffers: [CopiedAudioBuffer], frameCount: Int) throws -> [Double] {
            var result: [Double] = []
            result.reserveCapacity(frameCount * Int(asbd.mChannelsPerFrame))
            for buffer in buffers {
                let scalarCount = frameCount * buffer.channels
                buffer.data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    for index in 0..<scalarCount {
                        let address = base.advanced(by: index * encoding.byteCount)
                        switch encoding {
                        case .float32:
                            var value: Float = 0
                            memcpy(&value, address, MemoryLayout<Float>.size)
                            result.append(Double(value))
                        case .int16:
                            var value: Int16 = 0
                            memcpy(&value, address, MemoryLayout<Int16>.size)
                            result.append(Double(value) / 32_768.0)
                        case .int32:
                            var value: Int32 = 0
                            memcpy(&value, address, MemoryLayout<Int32>.size)
                            result.append(Double(value) / 2_147_483_648.0)
                        }
                    }
                }
            }
            return result
        }

        func encode(
            _ values: [Double], matching buffers: [CopiedAudioBuffer], frameCount: Int
        ) throws -> [CopiedAudioBuffer] {
            var result = buffers
            var valueIndex = 0
            for bufferIndex in result.indices {
                let scalarCount = frameCount * result[bufferIndex].channels
                result[bufferIndex].data.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    for scalarIndex in 0..<scalarCount {
                        let value = values[valueIndex + scalarIndex]
                        let address = base.advanced(by: scalarIndex * encoding.byteCount)
                        switch encoding {
                        case .float32:
                            var encoded = Float(value)
                            memcpy(address, &encoded, MemoryLayout<Float>.size)
                        case .int16:
                            var encoded = Int16((value * Double(Int16.max)).rounded())
                            memcpy(address, &encoded, MemoryLayout<Int16>.size)
                        case .int32:
                            var encoded = Int32((value * Double(Int32.max)).rounded())
                            memcpy(address, &encoded, MemoryLayout<Int32>.size)
                        }
                    }
                }
                valueIndex += scalarCount
            }
            guard valueIndex == values.count else {
                throw ProcessingError.malformedBuffer("processed PCM channel count changed")
            }
            return result
        }
    }

    private static func copyAudioBuffers(from sampleBuffer: CMSampleBuffer) throws -> [CopiedAudioBuffer] {
        var listSize = 0
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizingStatus == noErr, listSize >= MemoryLayout<AudioBufferList>.size else {
            throw ProcessingError.coreMedia(sizingStatus)
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { throw ProcessingError.coreMedia(status) }

        let pointer = UnsafeMutableAudioBufferListPointer(list)
        return try pointer.map { buffer in
            guard buffer.mDataByteSize == 0 || buffer.mData != nil else {
                throw ProcessingError.malformedBuffer("audio buffer has no data")
            }
            return CopiedAudioBuffer(
                channels: Int(buffer.mNumberChannels),
                data: Data(bytes: buffer.mData ?? storage, count: Int(buffer.mDataByteSize))
            )
        }
    }

    private static func makeSampleBuffer(
        from source: CMSampleBuffer,
        formatDescription: CMFormatDescription,
        audioBuffers: [CopiedAudioBuffer]
    ) throws -> CMSampleBuffer {
        let timings = try timingInfo(from: source)
        let sizes = try sampleSizes(from: source)
        var output: CMSampleBuffer?
        let createStatus = timings.withUnsafeBufferPointer { timingPointer in
            sizes.withUnsafeBufferPointer { sizePointer in
                CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: nil,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: formatDescription,
                    sampleCount: CMSampleBufferGetNumSamples(source),
                    sampleTimingEntryCount: timings.count,
                    sampleTimingArray: timingPointer.baseAddress,
                    sampleSizeEntryCount: sizes.count,
                    sampleSizeArray: sizePointer.baseAddress,
                    sampleBufferOut: &output
                )
            }
        }
        guard createStatus == noErr, let output else { throw ProcessingError.coreMedia(createStatus) }

        let listSize = MemoryLayout<AudioBufferList>.size
            + max(0, audioBuffers.count - 1) * MemoryLayout<AudioBuffer>.size
        let listStorage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = listStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(audioBuffers.count)
        let listPointer = UnsafeMutableAudioBufferListPointer(list)
        var allocations: [UnsafeMutableRawPointer] = []
        allocations.reserveCapacity(audioBuffers.count)
        defer {
            for allocation in allocations { allocation.deallocate() }
            listStorage.deallocate()
        }

        for (index, buffer) in audioBuffers.enumerated() {
            let allocation = UnsafeMutableRawPointer.allocate(
                byteCount: max(buffer.data.count, 1), alignment: 16
            )
            allocations.append(allocation)
            buffer.data.copyBytes(to: allocation.assumingMemoryBound(to: UInt8.self), count: buffer.data.count)
            listPointer[index] = AudioBuffer(
                mNumberChannels: UInt32(buffer.channels),
                mDataByteSize: UInt32(buffer.data.count),
                mData: allocation
            )
        }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            output,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: list
        )
        guard setStatus == noErr else { throw ProcessingError.coreMedia(setStatus) }
        return output
    }

    private static func timingInfo(from sampleBuffer: CMSampleBuffer) throws -> [CMSampleTimingInfo] {
        var count = 0
        let sizingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        )
        guard sizingStatus == noErr, count > 0 else { throw ProcessingError.coreMedia(sizingStatus) }
        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: count
        )
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil
        )
        guard status == noErr else { throw ProcessingError.coreMedia(status) }
        return timings
    }

    private static func sampleSizes(from sampleBuffer: CMSampleBuffer) throws -> [Int] {
        var count = 0
        let sizingStatus = CMSampleBufferGetSampleSizeArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        )
        if sizingStatus == kCMSampleBufferError_BufferHasNoSampleSizes || count == 0 { return [] }
        guard sizingStatus == noErr else { throw ProcessingError.coreMedia(sizingStatus) }
        var sizes = [Int](repeating: 0, count: count)
        let status = CMSampleBufferGetSampleSizeArray(
            sampleBuffer, entryCount: count, arrayToFill: &sizes, entriesNeededOut: nil
        )
        guard status == noErr else { throw ProcessingError.coreMedia(status) }
        return sizes
    }
}
