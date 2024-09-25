import Foundation
import ScreenCaptureKit
import AVFAudio

// 오디오를 캡처하는 ScreenCaptureKit 객체의 설정을 다루는 클래스
class AudioRecorder {
    private let sampleRate: Int
    
    private(set) var availableDisplays = [SCDisplay]()
    private var selectedDisplay: SCDisplay?
    
    let captureEngine = CaptureEngine()
    
    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }
    
    func setting() async throws -> (SCStreamConfiguration, SCContentFilter) {
        await self.checkAvailableContent()
        
        let config = streamConfiguration
        let filter = contentFilter
        
        return (config, filter)
    }
    
    private var streamConfiguration: SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = self.sampleRate
        
        return streamConfig
    }
    
    private var contentFilter: SCContentFilter {
        var filter: SCContentFilter
        
        guard let display = selectedDisplay else { fatalError("No display selected.") }
        let excludedApps = [SCRunningApplication]()
        
        filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        
        return filter;
    }
    
    private func checkAvailableContent() async {
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = availableContent.displays
            selectedDisplay = availableDisplays.first
        } catch {
            print("캡처 대상 탐색 오류")
        }
    }
}

// 시스템 오디오를 캡처하는 클래스
class CaptureEngine {
    // Screen Capture Kit stream
    private(set) var stream: SCStream?
    private var streamOutput: CaptureEngineStreamOutput?
    
    // 캡처되는 샘플 버퍼
    // video는 캡처는 되지만 미사용
    private let videoSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoSampleBufferQueue")
    private let audioSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.AudioSampleBufferQueue")
    
    // 비동기 continuation
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    
    // 캡처 실행 메소드
    // 비동기적으로 stream으로부터 캡처된 버퍼마다 yield하여 STT 처리할 수 있게하는 generator
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            self.continuation = continuation
            
            let output = CaptureEngineStreamOutput(continuation: continuation)
            streamOutput = output
            streamOutput!.pcmBufferHandler = { continuation.yield($0) }
            
            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)
                
                try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
                try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
                
                stream?.startCapture()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
    
    // 캡처 중단 메소드
    // Screen Capture Kit의 캡처와 startCapture의 generator 중단
    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
    }
}

// 캡처되어 전달된 오디오 버퍼를 처리하는 클래스
private class CaptureEngineStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    
    var pcmBufferHandler: ((Data) -> Void)?
    
    init(continuation: AsyncThrowingStream<Data, Error>.Continuation?) {
        self.continuation = continuation
    }
    
    // CaptureEngine의 startCapture 메소드에서 stream?.startCapture 실행시 delegate 되어 실행되는 메소드
    // 오디오가 캡처되어 버퍼를 전달
    // 비디오 정보는 다루지 않고, 오디오에 대해서만 처리
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        switch type {
        case .audio:
            handleAudio(for: sampleBuffer)
        default:
            return
        }
    }
    
    // CaptureEngine의 stopCapture 메소드에서 stream?.stopCapture 실행시 delegate 되어 실행되는 메소드
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation?.finish(throwing: error)
    }
    
    // 캡처된 오디오를 컨버팅 후 리턴하는 메소드
    // 32bit float pcm 오디오를 16bit int pcm 오디오로 컨버팅
    // pcmBufferHandler를 통해 yield
    private func handleAudio(for buffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(buffer) else {
            print("format description error")
            return
        }
        
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: format)
        guard let destinationFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                    sampleRate: sourceFormat.sampleRate,
                                                    channels: sourceFormat.channelCount,
                                                    interleaved: sourceFormat.isInterleaved) else {
            print("destination format error")
            return
        }
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
            print("컨버터를 생성할 수 없습니다.")
            return
        }
        
        guard let pcmBuffer = buffer.asPCMBuffer else {
            print("AVAudioPCMBuffer로 변환할 수 없습니다.")
            return
        }
        
        let frameCapacity = AVAudioFrameCount(pcmBuffer.frameLength)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: frameCapacity) else {
            print("출력 버퍼를 생성할 수 없습니다.")
            return
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        
        if status != .haveData {
            print("변환 실패: \(error?.localizedDescription ?? "알 수 없는 오류")")
            return
        }
        
        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
            
        guard let mData = audioBuffer.mData else {
            print("오디오 버퍼 데이터를 가져올 수 없습니다.")
            return
        }
        
        let dataSize = Int(outputBuffer.frameCapacity * outputBuffer.format.streamDescription.pointee.mBytesPerFrame)
        let data = Data(bytes: mData, count: dataSize)
        
        pcmBufferHandler?(data)
    }
}

extension CMSampleBuffer {
    // CMSampleBuffer 타입의 오디오 버퍼를 AVAudioPCMBuffer 객체로 변환
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
