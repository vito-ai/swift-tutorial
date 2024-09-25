import Foundation
import AVFAudio
import GRPC
import NIOCore
import NIOPosix

// 캡처된 시스템 오디오를 GRPC로 실시간 STT를 요청하는 클래스
class SystemAudioSTT {
    // 리턴 제로 API 서버 Config
    private let API_BASE = "https://openapi.vito.ai"
    private let GRPC_SERVER_HOST = "grpc-openapi.vito.ai"
    private let GRPC_SERVER_PORT = 443
    
    // 스트리밍 STT - DecoderConfig (https://developers.rtzr.ai/docs/stt-streaming/grpc)
    private let SAMPLE_RATE: Int32 = 16000 // (8000 ~ 48000 Hz, Required)
    private let ENCODING = OnlineDecoder_DecoderConfig.AudioEncoding.linear16 // (Required)
    
    private let MODEL_NAME: String = "sommers_ko" // STT 모델 (default: sommers_ko)
    private let USE_ITN: Bool = true // 영어, 숫자, 단위 변환 사용 여부 (default: true)
    private let USE_DISFLUENCY_FILTER: Bool = false // 간투어 필터기능 (default: false)
    private let USE_PROFANITY_FILTER: Bool = false // 비속어 필터 기능 (default: false)
    private let KEYWORDS: [String] = [] // 키워드 부스팅 (default: [])
    
    // 리턴 제로 API 애플리케이션 environment
    private let client_id: String
    private let client_secret: String
    
    // Access Token
    private var token: Token?
    
    // grpc
    private var client: OnlineDecoder_OnlineDecoderNIOClient?
    private var call: BidirectionalStreamingCall<OnlineDecoder_DecoderRequest, OnlineDecoder_DecoderResponse>?
    private var callOptions: CallOptions?
    
    // 오디오 레코더
    private let audioRecorder: AudioRecorder
    
    // SystemAudioSTT 객체 init
    init(client_id: String, client_secret: String) {
        self.client_id = client_id
        self.client_secret = client_secret
        self.audioRecorder = AudioRecorder(sampleRate: Int(SAMPLE_RATE))
    }
    
    // 오디오 캡처 및 실시간 STT로 자막 요청 실행 메소드
    func start() async throws {
        try await configGRPC()
        try await getToken()
        try await setupCall()
        
        let (configSCK, filterSCK) = try await audioRecorder.setting()
        
        let errorFlag = AtomicBool(false)
        for try await chunk in audioRecorder.captureEngine.startCapture(configuration: configSCK, filter: filterSCK) {
            if errorFlag.boolValue {
                await stop()
                break
            }
            
            try await checkAccessToken()
            let audioContent = OnlineDecoder_DecoderRequest.with {
                $0.audioContent = chunk
            }
            self.call?.sendMessage(audioContent).whenFailure { error in
                print("Failed to send message: \(error)")
                errorFlag.boolValue = true
            }
        }
        call?.sendEnd(promise: nil)
    }
    
    // 오디오 캡처 및 실시간 STT로 자막 요청 종료 메소드
    func stop() async {
        await audioRecorder.captureEngine.stopCapture()
        client?.channel.close().whenComplete { _ in
            print("gRPC channel closed")
        }
    }
    
    // grpc 클라이언트 생성 메소드
    private func configGRPC() async throws {
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        
        var configuration = ClientConnection.Configuration.default(
            target: .hostAndPort(GRPC_SERVER_HOST, GRPC_SERVER_PORT),
            eventLoopGroup: group
        )
        let customTLS = GRPCTLSConfiguration.makeClientConfigurationBackedByNIOSSL(
            trustRoots: .default,
            certificateVerification: .none
        )
        configuration.tlsConfiguration = customTLS
        
        let channel = ClientConnection(configuration: configuration)
        self.client = OnlineDecoder_OnlineDecoderNIOClient(channel: channel)
    }
    
    // gRPC call을 새로 만들고, 리턴제로 STT Config을 서버에 알리는 메소드
    private func setupCall() async throws {
        call?.sendEnd(promise: nil)
        
        self.callOptions = CallOptions(customMetadata: [
            "Authorization": "Bearer \(token!.access_token)"
        ])
        self.call = self.client!.decode(callOptions: callOptions) { response in
            self.handleSTTResponse(response)
        }
        
        let config = OnlineDecoder_DecoderConfig.with {
            $0.sampleRate = SAMPLE_RATE
            $0.encoding = ENCODING
            $0.modelName = MODEL_NAME
            $0.useItn = USE_ITN
            $0.useDisfluencyFilter = USE_DISFLUENCY_FILTER
            $0.keywords = KEYWORDS
        }
        let initialRequest = OnlineDecoder_DecoderRequest.with {
            $0.streamingConfig = config
        }
        
        try await self.call?.sendMessage(initialRequest).get()
    }
    
    // access_token 확인 메소드
    // access_token이 없거나, 유효기한이 지났을 경우 자동 갱신
    func checkAccessToken() async throws {
        if token == nil || token!.expire_at < Int(Date().timeIntervalSince1970) {
            try await getToken()
            try await setupCall()
        }
    }
    
    // access_token을 요청하는 메소드
    // HTTP 요청으로 client_id와 client_secret으로 OAuth2 인증을 통해 토큰 발급
    private func getToken() async throws {
        guard let url = URL(string: API_BASE + "/v1/authenticate") else {
            throw NSError(domain: "InvalidURL", code: 0, userInfo: nil)
        }
        
        let formData: [String: Any] = ["client_id": self.client_id, "client_secret": self.client_secret]
        let formDataString = (formData.compactMap({ (key, value) -> String in
            return "\(key)=\(value)"
        }) as Array).joined(separator: "&")
        let formEncodedData = formDataString.data(using: .utf8)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "InvalidResponse", code: 0, userInfo: nil)
        }
        
        self.token = try JSONDecoder().decode(Token.self, from: data)
    }
    
    // 자막 출력 메소드
    // isFinal이 아닐 경우 다음 문장 출력시 덮어 쓰기
    private func handleSTTResponse(_ response: OnlineDecoder_DecoderResponse) {
        for result in response.results {
            let sentence = result.alternatives.first?.text ?? ""
            clearLine()
            
            if result.isFinal {
                print(sentence)
                fflush(stdout)
            } else {
                print(sentence, terminator: "")
                fflush(stdout)
            }
        }
    }
    
    // isFinal이 아닌 전사 문장을 지워, 덮어 쓰기 가능하게 하는 메소드
    private func clearLine() {
        print("\r", terminator: "")
        print("\u{001B}[2K", terminator: "")
        fflush(stdout)
    }
}

// 프로그램 동작 확인 전역 변수
var isRunning = true

@main
struct Main {
    static var systemAudioSTT: SystemAudioSTT?
    
    // 프로그램 시작 메소드
    static func main() {
        print("Mac System Audio STT Start (Press Ctrl + C to Quit)")
        setupSignalHandler()
        checkIsRunning()
        loadEnvironment()
        
        let env = ProcessInfo.processInfo.environment
        guard let client_id = env["CLIENT_ID"] else {
            print("CLIENT_ID이 env에 없습니다.")
            return
        }
        guard let client_secret = env["CLIENT_SECRET"] else {
            print("CLIENT_SECRET이 env에 없습니다.")
            return
        }
        
        Task {
            do {
                systemAudioSTT = SystemAudioSTT(client_id: client_id, client_secret: client_secret)
                try await systemAudioSTT?.start()
                isRunning = false
            } catch {
                print(error)
                isRunning = false
            }
        }
        
        RunLoop.main.run()
    }
    
    // Ctrl + C로 프로그램 종료
    static func setupSignalHandler() {
        signal(SIGINT) { _ in
            isRunning = false
        }
    }
    
    // isRunning이 true인 동안 blocking하다가 false가 되는 순간 프로그램 종료
    static func checkIsRunning() {
        Task {
            while isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            await systemAudioSTT?.stop()
            try? await Task.sleep(nanoseconds: 100_000_000)
            print("\nMac System Audio STT Stop")
            exit(0)
        }
    }
    
    // env 파일 loader
    static func loadEnvironment() {
        guard let path = Bundle.module.path(forResource: "secret", ofType: "env") else {
            print("env를 찾지 못했습니다.")
            return
        }
        
        do {
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let envVars = contents.components(separatedBy: .newlines)
            
            for envVar in envVars {
                let components = envVar.components(separatedBy: "=")
                if components.count == 2 {
                    setenv(components[0], components[1], 1)
                }
            }
        } catch {
            print("env를 읽는데 실패하였습니다.")
        }
    }
}

// Access Token HTTP 요청 response JSON
struct Token: Codable {
    var access_token: String
    var expire_at: Int
}

// Atomic하게 동시성 문제없이 bool값 관리
class AtomicBool {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool = false) {
        self.value = value
    }

    var boolValue: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}
