import Accelerate
import Foundation

nonisolated enum RecordingAudioLag {
    /// Positive lag means output must be shifted earlier. Windows stay bounded even for long takes.
    static func measure(input: [Float], output: [Float], maximumLag: Int) -> Int? {
        guard !input.isEmpty, maximumLag >= 0, output.count >= input.count + maximumLag,
              input.allSatisfy(\.isFinite), output.allSatisfy(\.isFinite) else { return nil }
        return input.withUnsafeBufferPointer { source in
            output.withUnsafeBufferPointer { rendered in
                let count = vDSP_Length(input.count)
                var inputEnergy: Float = 0
                vDSP_dotpr(source.baseAddress!, 1, source.baseAddress!, 1, &inputEnergy, count)
                if inputEnergy < 1e-10 { return 0 }
                var bestLag = 0
                var bestScore: Float = 0
                var outputEnergy: Float = 0
                for lag in 0...maximumLag {
                    let samples = rendered.baseAddress! + lag
                    var dot: Float = 0
                    var energy: Float = 0
                    vDSP_dotpr(source.baseAddress!, 1, samples, 1, &dot, count)
                    vDSP_dotpr(samples, 1, samples, 1, &energy, count)
                    outputEnergy = max(outputEnergy, energy)
                    let score = dot / sqrt(max(inputEnergy * energy, 1e-20))
                    if score > bestScore { bestScore = score; bestLag = lag }
                }
                // A suppressed window cannot establish the delay of speech elsewhere in the take.
                if outputEnergy < 1e-10 { return nil }
                return bestScore >= 0.1 ? bestLag : nil
            }
        }
    }
}
