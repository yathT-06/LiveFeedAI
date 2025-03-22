import Foundation
import UIKit
import CoreMedia
import CoreVideo
import CoreImage
import AVFoundation
import Speech

class AIManager {
    static let shared = AIManager()
    #if targetEnvironment(simulator)
    private let serverURL = "http://localhost:8000"
    #else
    private let serverURL = "http://172.17.47.244:8000" // Replace with your Mac's actual IP
    #endif
    private var lastDescription: String = "Initializing..."
    private var lastSpeechResponse: String = ""
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    // Create a single reusable CIContext for better performance
    private let ciContext = CIContext()
    
    // Add a processing queue to prevent blocking the main thread
    private let processingQueue = DispatchQueue(label: "com.app.imageProcessing", qos: .userInitiated)
    
    // Track if we're already processing an image to avoid redundant requests
    private var isProcessingImage = false
    
    // Image description history for smoothing
    private var descriptionHistory: [String] = []
    
    // Cache for recently processed images
    private var imageHashCache = NSCache<NSString, NSString>()

    private init() {}

    func analyzeFrame(_ sampleBuffer: CMSampleBuffer?) async -> String {
        // Skip if we're already processing an image
        guard !isProcessingImage else {
            return lastDescription
        }
        
        isProcessingImage = true
        defer { isProcessingImage = false }
        
        guard let sampleBuffer = sampleBuffer else {
            return "Sample buffer is nil."
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return "Failed to get pixel buffer."
        }
        
        // Use our more efficient conversion method
        guard let imageData = await convertPixelBufferToJPEGAsync(pixelBuffer) else {
            return "Failed to convert frame."
        }
        
        let description = await processImage(imageData: imageData)
        
        // Only update if significantly different from recent descriptions
        if descriptionHistory.isEmpty || !isSimilarToRecentDescriptions(description) {
            descriptionHistory.append(description)
            if descriptionHistory.count > 5 {
                descriptionHistory.removeFirst()
            }
            lastDescription = description
        }
        
        return lastDescription
    }
    
    private func isSimilarToRecentDescriptions(_ newDescription: String) -> Bool {
        // Simple similarity check - can be enhanced with more sophisticated NLP
        for desc in descriptionHistory {
            let words1 = Set(desc.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let words2 = Set(newDescription.lowercased().components(separatedBy: .whitespacesAndNewlines))
            
            // Skip very short descriptions
            if words1.count < 3 || words2.count < 3 {
                continue
            }
            
            let intersection = words1.intersection(words2)
            let similarity = Double(intersection.count) / Double(max(words1.count, words2.count))
            
            if similarity > 0.7 {
                return true
            }
        }
        return false
    }

    func processSpeechCommand(_ command: String) async -> String {
        let url = URL(string: "\(serverURL)/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0 // Add a reasonable timeout
        
        let body: [String: String] = ["query": command]
        
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            return "Error encoding speech command: \(error.localizedDescription)"
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return "Server error: Invalid response type"
            }
            
            guard httpResponse.statusCode == 200 else {
                return "Server error: \(httpResponse.statusCode)"
            }
            
            do {
                let result = try JSONDecoder().decode(SpeechResponse.self, from: data)
                lastSpeechResponse = result.response
                
                // Move speech synthesis to a background thread to avoid UI blocking
                Task.detached {
                    let utterance = AVSpeechUtterance(string: self.lastSpeechResponse)
                    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                    utterance.rate = 0.5
                    
                    await MainActor.run {
                        self.speechSynthesizer.speak(utterance)
                    }
                }
                
                return lastSpeechResponse
            } catch {
                return "Error decoding response: \(error.localizedDescription)"
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    func getLatestDescription() -> String {
        return lastDescription
    }

    private func convertPixelBufferToJPEGAsync(_ pixelBuffer: CVPixelBuffer) async -> Data? {
        return await withCheckedContinuation { continuation in
            processingQueue.async {
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                
                // Resize to smaller dimensions for faster network transfer
                let maxDimension: CGFloat = 480.0
                let scale = maxDimension / max(ciImage.extent.width, ciImage.extent.height)
                let smallerImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                
                // Lock the pixel buffer to prevent modification during access
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                
                guard let cgImage = self.ciContext.createCGImage(smallerImage, from: smallerImage.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let uiImage = UIImage(cgImage: cgImage)
                
                // Use lower compression for better performance/size tradeoff
                let imageData = uiImage.jpegData(compressionQuality: 0.5)
                continuation.resume(returning: imageData)
            }
        }
    }

    private func processImage(imageData: Data) async -> String {
        // Generate simple hash of image data for caching
        let imageHash = NSString(string: String(imageData.hashValue))
        
        // Check if we already processed a similar image
        if let cachedDescription = imageHashCache.object(forKey: imageHash) {
            return cachedDescription as String
        }
        
        let url = URL(string: "\(serverURL)/process-image")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30.0

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return "Server error: Invalid response type"
            }
            
            guard httpResponse.statusCode == 200 else {
                return "Server error: \(httpResponse.statusCode)"
            }
            
            do {
                let result = try JSONDecoder().decode(ImageResponse.self, from: data)
                
                // Cache the result
                imageHashCache.setObject(NSString(string: result.recognized_text), forKey: imageHash)
                
                return result.recognized_text
            } catch {
                return "Error decoding image response: \(error.localizedDescription)"
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    struct ImageResponse: Codable {
        let recognized_text: String
    }

    struct SpeechResponse: Codable {
        let response: String
    }
}
