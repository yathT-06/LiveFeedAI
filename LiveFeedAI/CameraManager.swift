import AVFoundation
import UIKit
import CoreImage

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    private let captureSession = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delegate: ((CMSampleBuffer?) -> Void)?
    private var isSetupComplete: Bool = false
    @Published var isSessionRunning: Bool = false
    @Published var errorMessage: String?
    
    // Scene change detection - optimized
    private var previousFrame: CIImage?
    private let changeThreshold: CGFloat = 0.035  // Adjusted sensitivity
    private let context = CIContext(options: [.cacheIntermediates: false])
    
    // Adaptive debounce for efficiency
    private var lastProcessedTime: Date = .distantPast
    private var adaptiveDebounceInterval: TimeInterval = 0.3
    private var processingTimeHistory: [TimeInterval] = []

    override init() {
        super.init()
        setupCamera()
        self.previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        self.previewLayer?.videoGravity = .resizeAspectFill
    }

    func setupCamera() {
        captureSession.sessionPreset = .vga640x480
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            errorMessage = "No back camera available."
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                errorMessage = "Failed to add camera input."
                return
            }
        } catch {
            errorMessage = "Error setting up camera: \(error.localizedDescription)"
            return
        }

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.alwaysDiscardsLateVideoFrames = true
        videoOutput?.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput?.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue", qos: .userInteractive))
        
        if let videoOutput = videoOutput, captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            if let connection = videoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
        } else {
            errorMessage = "Failed to add video output."
            return
        }

        isSetupComplete = true
    }

    func startCapture(delegate: @escaping (CMSampleBuffer?) -> Void) {
        self.delegate = delegate
        if isSetupComplete && !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = self.captureSession.isRunning
                    if !self.isSessionRunning {
                        self.errorMessage = "Failed to start capture session."
                    }
                }
            }
        }
    }

    func stopCapture() {
        if captureSession.isRunning {
            captureSession.stopRunning()
            self.isSessionRunning = false
            self.previousFrame = nil
        }
    }

    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return previewLayer
    }

    func setPreviewLayerFrame(_ frame: CGRect) {
        previewLayer?.frame = frame
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let currentTime = Date()
        guard currentTime.timeIntervalSince(lastProcessedTime) >= adaptiveDebounceInterval else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let currentFrame = CIImage(cvPixelBuffer: pixelBuffer)

        if let previousFrame = self.previousFrame {
            let startTime = Date()
            let difference = computeImageDifference(previous: previousFrame, current: currentFrame)
            
            if difference > changeThreshold {
                self.delegate?(sampleBuffer)
                lastProcessedTime = currentTime
                
                // Update adaptive debounce based on processing time
                let processingTime = Date().timeIntervalSince(startTime)
                updateAdaptiveDebounce(processingTime: processingTime)
            }
        } else {
            self.delegate?(sampleBuffer)  // Process first frame immediately
            lastProcessedTime = currentTime
        }
        self.previousFrame = currentFrame
    }

    private func updateAdaptiveDebounce(processingTime: TimeInterval) {
        processingTimeHistory.append(processingTime)
        if processingTimeHistory.count > 10 {
            processingTimeHistory.removeFirst()
        }
        
        let avgProcessingTime = processingTimeHistory.reduce(0, +) / Double(processingTimeHistory.count)
        // Set debounce to slightly longer than average processing time for efficiency
        adaptiveDebounceInterval = min(1.0, max(0.2, avgProcessingTime * 1.2))
    }

    private func computeImageDifference(previous: CIImage, current: CIImage) -> CGFloat {
        // Sample pixels at key points instead of processing the whole image
        let samplePoints = [(0.2, 0.2), (0.5, 0.5), (0.8, 0.8), (0.2, 0.8), (0.8, 0.2)]
        var totalDifference: CGFloat = 0
        
        for (x, y) in samplePoints {
            let prevX = previous.extent.width * CGFloat(x)
            let prevY = previous.extent.height * CGFloat(y)
            let currX = current.extent.width * CGFloat(x)
            let currY = current.extent.height * CGFloat(y)
            
            let prevColor = sampleAverageColor(in: previous, at: CGPoint(x: prevX, y: prevY))
            let currColor = sampleAverageColor(in: current, at: CGPoint(x: currX, y: currY))
            
            let diff = colorDifference(prevColor, currColor)
            totalDifference += diff
        }
        
        return totalDifference / CGFloat(samplePoints.count)
    }
    
    private func sampleAverageColor(in image: CIImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        // Sample a small area around the point for more stable results
        let rect = CGRect(x: point.x - 2, y: point.y - 2, width: 5, height: 5)
                .intersection(image.extent)
        
        if rect.isEmpty {
            return (0, 0, 0)
        }
        
        let filter = CIFilter(name: "CIAreaAverage")!
        filter.setValue(image.cropped(to: rect), forKey: kCIInputImageKey)
        guard let outputImage = filter.outputImage else { return (0, 0, 0) }
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        
        return (CGFloat(bitmap[0]) / 255.0, CGFloat(bitmap[1]) / 255.0, CGFloat(bitmap[2]) / 255.0)
    }
    
    private func colorDifference(_ c1: (r: CGFloat, g: CGFloat, b: CGFloat), _ c2: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        let rDiff = abs(c1.r - c2.r)
        let gDiff = abs(c1.g - c2.g)
        let bDiff = abs(c1.b - c2.b)
        return (rDiff + gDiff + bDiff) / 3.0
    }
}

extension CIImage {
    func resized(to size: CGSize) -> CIImage {
        let scaleX = size.width / extent.width
        let scaleY = size.height / extent.height
        return transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}
