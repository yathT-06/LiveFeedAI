import SwiftUI
import AVFoundation

struct LiveFeedCameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var description: String = "Initializing..."
    @State private var isListening: Bool = false
    @State private var cameraAccessGranted: Bool = false
    @State private var isFetchingDescription: Bool = false
    @State private var errorMessage: String? = nil // Added error state

    var body: some View {
        ZStack {
            if let error = errorMessage ?? cameraManager.errorMessage {
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        Text(error)
                            .foregroundColor(.white)
                            .font(.headline)
                            .padding()
                    )
            } else if cameraManager.isSessionRunning, let _ = cameraManager.getPreviewLayer() {
                CameraPreview(cameraManager: cameraManager)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        Text("Starting camera...")
                            .foregroundColor(.white)
                            .font(.headline)
                    )
            }
            
            VStack {
                if isFetchingDescription {
                    ProgressView("Fetching new description...")
                        .progressViewStyle(CircularProgressViewStyle())
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                        .padding(.top, 50)
                } else {
                    Text(description)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.top, 50)
                }

                Spacer()

                Button(action: {
                    if isListening {
                        stopListening()
                    } else {
                        startListening()
                    }
                }) {
                    Text(isListening ? "Stop Listening" : "Start Listening")
                        .padding()
                        .background(isListening ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            checkCameraPermission()
            if cameraAccessGranted {
                startCameraCapture()
            } else {
                print("Camera access not granted.")
            }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                print("Microphone access granted: \(granted)")
            }
        }
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAccessGranted = true
            print("Camera access already granted.")
            startCameraCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraAccessGranted = granted
                    print("Camera access granted: \(granted)")
                    if granted {
                        self.startCameraCapture()
                    }
                }
            }
        case .denied, .restricted:
            cameraAccessGranted = false
            print("Camera access denied or restricted.")
            self.description = "Camera access denied. Please enable in Settings."
        @unknown default:
            cameraAccessGranted = false
            print("Unknown camera authorization status.")
        }
    }

    private func startCameraCapture() {
        cameraManager.startCapture { sampleBuffer in
            Task {
                if let sampleBuffer = sampleBuffer {
                    DispatchQueue.main.async {
                        self.isFetchingDescription = true
                    }
                    let newDescription = await AIManager.shared.analyzeFrame(sampleBuffer)
                    DispatchQueue.main.async {
                        if newDescription.lowercased().contains("error") {
                            self.errorMessage = "Failed to fetch description: \(newDescription)"
                        } else {
                            self.description = newDescription
                            self.errorMessage = nil
                        }
                        self.isFetchingDescription = false
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "No frame data received."
                        self.isFetchingDescription = false
                    }
                }
            }
        }
    }

    private func startListening() {
        isListening = true
        SpeechRecognizer.shared.startListening { command in
            Task {
                let response = await AIManager.shared.processSpeechCommand(command)
                print("Speech command: \(command), Response: \(response)")
            }
        }
    }

    private func stopListening() {
        isListening = false
        SpeechRecognizer.shared.stopListening()
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var cameraManager: CameraManager

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        updatePreviewLayer(for: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        updatePreviewLayer(for: uiView)
    }

    private func updatePreviewLayer(for view: UIView) {
        guard let previewLayer = cameraManager.getPreviewLayer() else {
            print("Preview layer is nil during update.")
            return
        }
        previewLayer.frame = view.bounds
        if previewLayer.superlayer == nil {
            view.layer.addSublayer(previewLayer)
            print("Preview layer added to view with frame: \(view.bounds)")
        } else {
            print("Preview layer already added, updating frame to: \(view.bounds)")
        }
    }
}

struct LiveFeedCameraView_Previews: PreviewProvider {
    static var previews: some View {
        LiveFeedCameraView()
    }
}
