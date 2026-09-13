#!/usr/bin/env swift
// Local-only macOS Vision companion for StackChan.
//
// It accepts bounded SBFR JPEG packets from the USB serial stream and sends
// only the existing target protocol back to the robot. It performs no network
// access, identity recognition, persistence, or servo control.

import Foundation
import ImageIO
import Vision

private let magic = [UInt8]([0x53, 0x42, 0x46, 0x52]) // "SBFR"
private let version: UInt8 = 1
private let headerLength = 13
private let maximumJPEGBytes = 300_000
private let minimumConfidence: Float = 0.65

private struct Frame {
    let sequence: UInt32
    let jpeg: Data
}

private final class FrameDecoder {
    private var buffer = Data()

    func append(_ bytes: Data) -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []

        while buffer.count >= headerLength {
            guard Array(buffer.prefix(4)) == magic else {
                buffer.removeFirst()
                continue
            }
            guard buffer[4] == version else {
                buffer.removeFirst(4)
                continue
            }

            let sequence = littleEndianUInt32(at: 5)
            let length = Int(littleEndianUInt32(at: 9))
            guard length > 0 && length <= maximumJPEGBytes else {
                buffer.removeFirst(4)
                continue
            }
            guard buffer.count >= headerLength + length else { break }

            frames.append(Frame(sequence: sequence,
                                jpeg: Data(buffer[headerLength..<(headerLength + length)])))
            buffer.removeFirst(headerLength + length)
        }
        return frames
    }

    private func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}

private func target(for jpeg: Data) -> (x: Float, y: Float, confidence: Float)? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }

    let request = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
    do {
        try handler.perform([request])
    } catch {
        fputs("Vision request failed: \(error)\n", stderr)
        return nil
    }

    guard let face = (request.results ?? [])
        .filter({ $0.confidence >= minimumConfidence })
        .max(by: { ($0.boundingBox.width * $0.boundingBox.height * CGFloat($0.confidence))
                 < ($1.boundingBox.width * $1.boundingBox.height * CGFloat($1.confidence)) }) else {
        return nil
    }

    let box = face.boundingBox // Vision has a bottom-left origin.
    let x = Float((box.midX * 2) - 1)
    let y = Float(1 - (box.midY * 2)) // StackChan protocol has top = -1.
    return (clamp(x), clamp(y), clamp(face.confidence))
}

private func clamp(_ value: Float) -> Float { min(1, max(-1, value)) }

private func command(sequence: UInt32, target: (x: Float, y: Float, confidence: Float)) -> Data {
    Data(String(format: "T,%u,%.4f,%.4f,%.4f\\n",
                sequence, target.x, target.y, target.confidence).utf8)
}

private func usage() -> Never {
    fputs("Usage: stanbot-vision --serial /dev/cu.usbmodem… | --jpeg frame.jpg [--sequence N]\n", stderr)
    exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let jpegIndex = arguments.firstIndex(of: "--jpeg"), arguments.indices.contains(jpegIndex + 1) {
    let path = arguments[jpegIndex + 1]
    let sequence = arguments.firstIndex(of: "--sequence")
        .flatMap { arguments.indices.contains($0 + 1) ? UInt32(arguments[$0 + 1]) : nil } ?? 1
    guard let jpeg = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        fputs("Cannot read JPEG: \(path)\n", stderr)
        exit(66)
    }
    if let result = target(for: jpeg) {
        FileHandle.standardOutput.write(command(sequence: sequence, target: result))
    }
    exit(0)
}

guard let serialIndex = arguments.firstIndex(of: "--serial"),
      arguments.indices.contains(serialIndex + 1) else { usage() }
let serialPath = arguments[serialIndex + 1]
guard let input = FileHandle(forReadingAtPath: serialPath),
      let output = FileHandle(forWritingAtPath: serialPath) else {
    fputs("Cannot open serial device: \(serialPath)\n", stderr)
    exit(69)
}

private let decoder = FrameDecoder()
while true {
    let bytes = input.availableData
    if bytes.isEmpty { break }
    for frame in decoder.append(bytes) {
        if let result = target(for: frame.jpeg) {
            output.write(command(sequence: frame.sequence, target: result))
        }
    }
}
