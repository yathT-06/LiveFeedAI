import Speech

class SpeechRecognizer: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    static let shared = SpeechRecognizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var delegate: ((String) -> Void)?

    private override init() {
        super.init()
        speechRecognizer?.delegate = self
        requestSpeechAuthorization()
    }

    private func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("Speech recognition authorization status: \(status.rawValue)")
        }
    }

    func startListening(delegate: @escaping (String) -> Void) {
        self.delegate = delegate

        guard !audioEngine.isRunning else { return }
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            startRecognitionTask()
        } catch {
            print("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func startRecognitionTask() {
        recognitionTask?.cancel()
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { result, error in
            if let result = result {
                let transcription = result.bestTranscription.formattedString
                self.delegate?(transcription)
            }
            if let error = error {
                print("Speech recognition error: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if self.audioEngine.isRunning {
                        self.startRecognitionTask()
                    }
                }
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        print("Speech recognizer availability: \(available)")
    }
}
