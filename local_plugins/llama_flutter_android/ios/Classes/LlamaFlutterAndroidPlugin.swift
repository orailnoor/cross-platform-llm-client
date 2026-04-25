import Flutter
import Foundation

public class LlamaFlutterAndroidPlugin: NSObject, FlutterPlugin, LlamaHostApi {

    private var flutterApi: LlamaFlutterApi?
    private let wrapper = LlamaIosWrapper()
    private var isModelLoaded_ = false
    private let stoppingLock = NSLock()
    private var _isStopping = false
    private var isStopping: Bool {
        get { stoppingLock.lock(); defer { stoppingLock.unlock() }; return _isStopping }
        set { stoppingLock.lock(); defer { stoppingLock.unlock() }; _isStopping = newValue }
    }
    private var currentModelPath: String?
    private let queue = DispatchQueue(
        label: "com.write4me.llama_flutter_android.inference",
        qos: .userInitiated
    )

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LlamaFlutterAndroidPlugin()
        instance.flutterApi = LlamaFlutterApi(binaryMessenger: registrar.messenger())
        LlamaHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    }

    // MARK: - LlamaHostApiProtocol

    func loadModel(config: ModelConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try ObjcExceptionBridge.catch {
                    self.wrapper.loadModel(
                        atPath: config.modelPath,
                        nThreads: Int32(config.nThreads),
                        contextSize: Int32(config.contextSize),
                        nGpuLayers: Int32(config.nGpuLayers ?? 99),
                        progressCallback: { [weak self] progress in
                            DispatchQueue.main.async {
                                self?.flutterApi?.onLoadProgress(progress: progress) { _ in }
                            }
                        }
                    )
                }
                self.isModelLoaded_ = true
                self.currentModelPath = config.modelPath
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async {
                    self.flutterApi?.onError(error: error.localizedDescription) { _ in }
                    completion(.failure(error))
                }
            }
        }
    }

    func generate(request: GenerateRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isModelLoaded_ else {
            completion(.failure(NSError(
                domain: "LlamaPlugin", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]
            )))
            return
        }
        isStopping = false
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try ObjcExceptionBridge.catch {
                    self.wrapper.generate(
                        withPrompt: request.prompt,
                        maxTokens: Int32(request.maxTokens),
                        temperature: request.temperature,
                        topP: request.topP,
                        topK: Int32(request.topK),
                        minP: request.minP,
                        typicalP: request.typicalP,
                        repeatPenalty: request.repeatPenalty,
                        frequencyPenalty: request.frequencyPenalty,
                        presencePenalty: request.presencePenalty,
                        repeatLastN: Int32(request.repeatLastN),
                        mirostat: Int32(request.mirostat),
                        mirostatTau: request.mirostatTau,
                        mirostatEta: request.mirostatEta,
                        seed: request.seed ?? -1,
                        penalizeNewline: request.penalizeNewline
                    ) { [weak self] token in
                        guard let self = self, !self.isStopping else { return }
                        DispatchQueue.main.async {
                            self.flutterApi?.onToken(token: token) { _ in }
                        }
                    }
                }
                if !self.isStopping {
                    DispatchQueue.main.async {
                        self.flutterApi?.onDone() { _ in }
                        completion(.success(()))
                    }
                }
            } catch {
                if !self.isStopping {
                    DispatchQueue.main.async {
                        self.flutterApi?.onError(error: error.localizedDescription) { _ in }
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func generateChat(request: ChatRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isModelLoaded_ else {
            completion(.failure(NSError(
                domain: "LlamaPlugin", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]
            )))
            return
        }
        isStopping = false

        let messages = request.messages.map { TemplateChatMessage(role: $0.role, content: $0.content) }
        let formattedPrompt = ChatTemplateManager.shared.formatMessages(
            messages: messages,
            templateName: request.template,
            modelPath: currentModelPath
        )

        let generateRequest = GenerateRequest(
            prompt: formattedPrompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            minP: request.minP,
            typicalP: request.typicalP,
            repeatPenalty: request.repeatPenalty,
            frequencyPenalty: request.frequencyPenalty,
            presencePenalty: request.presencePenalty,
            repeatLastN: request.repeatLastN,
            mirostat: request.mirostat,
            mirostatTau: request.mirostatTau,
            mirostatEta: request.mirostatEta,
            seed: request.seed,
            penalizeNewline: request.penalizeNewline
        )
        generate(request: generateRequest, completion: completion)
    }

    func getSupportedTemplates() -> [String] {
        return ChatTemplateManager.shared.getSupportedTemplates()
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        isStopping = true
        wrapper.stop()
        completion(.success(()))
    }

    func dispose(completion: @escaping (Result<Void, Error>) -> Void) {
        isStopping = true
        wrapper.stop()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.wrapper.freeModel()
            self.isModelLoaded_ = false
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func isModelLoaded() -> Bool {
        return isModelLoaded_
    }

    func getContextInfo() -> ContextInfo {
        let used = Int64(wrapper.tokensUsed())
        let size = Int64(wrapper.contextSize())
        let pct  = size > 0 ? (Double(used) / Double(size) * 100.0) : 0.0
        return ContextInfo(tokensUsed: used, contextSize: size, usagePercentage: pct)
    }

    func clearContext(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            self?.wrapper.clearContext()
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func setSystemPromptLength(length: Int64) {
        wrapper.setSystemPromptLength(Int32(length))
    }

    func registerCustomTemplate(name: String, content: String) {
        ChatTemplateManager.shared.registerCustomTemplate(name: name, content: content)
    }

    func unregisterCustomTemplate(name: String) {
        ChatTemplateManager.shared.unregisterCustomTemplate(name: name)
    }

    func detectGpu(completion: @escaping (Result<GpuInfo, Error>) -> Void) {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        // Estimate free memory as 50% of total for now, or just return total as a proxy if unavailable
        let freeMemory = totalMemory / 2 
        
        let info = GpuInfo(
            vulkanSupported: false,
            gpuName: "Apple Metal",
            vulkanApiVersion: -1,
            deviceLocalMemoryBytes: Int64(totalMemory),
            freeRamBytes: Int64(freeMemory),
            recommendedGpuLayers: 99
        )
        completion(.success(info))
    }
}
