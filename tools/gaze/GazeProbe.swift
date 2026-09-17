// Run the gaze pipeline on still images and print one JSON line per face.
//
//   swiftc -O tools/gaze/GazeProbe.swift -o /tmp/gazeprobe
//   /tmp/gazeprobe Gaze-resnet50.mlpackage frame1.jpg frame2.jpg ...
//
// For each face: Vision's face rectangle and head yaw/pitch (revision 3), the
// face width in pixels, the coarse facing class the app logs (same thresholds
// as Facing.swift), and the Core ML gaze model's yaw/pitch in degrees on a
// square crop of the face. It is a probe for trying models on clips from the
// robot's camera, not part of the app. See docs/gaze.md.
import CoreML
import Foundation
import ImageIO
import Vision

func degrees(_ value: NSNumber?) -> Double? { value.map { $0.doubleValue * 180 / .pi } }

/// A JSON number with a fixed number of decimals, rather than 0.42799999.
func fixed(_ value: Double?, _ places: Int = 1) -> Any {
    guard let value, value.isFinite else { return NSNull() }
    return NSDecimalNumber(string: String(format: "%.\(places)f", value))
}

func facing(width: Double, yaw: Double?, pitch: Double?) -> String {
    guard let yaw, width >= 48 else { return "unknown" }
    if abs(yaw) > 35 { return "away" }
    if let pitch, abs(pitch) > 30 { return "away" }
    return "toward"
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("usage: gazeprobe MODEL.mlpackage|.mlmodelc IMAGE...\n".data(using: .utf8)!)
    exit(2)
}
let modelURL = URL(fileURLWithPath: arguments[1])
let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
let configuration = MLModelConfiguration()
configuration.computeUnits = .all
let visionModel = try VNCoreMLModel(for: try MLModel(contentsOf: compiled, configuration: configuration))

for path in arguments.dropFirst(2) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("{\"image\":\"\(path)\",\"error\":\"unreadable\"}")
        continue
    }
    let faces = VNDetectFaceRectanglesRequest()
    faces.revision = VNDetectFaceRectanglesRequestRevision3
    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([faces])
    let width = Double(image.width), height = Double(image.height)
    for face in faces.results ?? [] where face.confidence >= 0.7 {
        let box = face.boundingBox
        // A square crop around the face, in top-left pixel coordinates.
        let side = max(box.width * width, box.height * height) * 1.1
        let centreX = box.midX * width, centreY = (1 - box.midY) * height
        let crop = CGRect(x: centreX - side / 2, y: centreY - side / 2, width: side, height: side)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let faceImage = image.cropping(to: crop) else { continue }
        let gaze = VNCoreMLRequest(model: visionModel)
        gaze.imageCropAndScaleOption = .scaleFill
        let started = Date()
        try VNImageRequestHandler(cgImage: faceImage, orientation: .up).perform([gaze])
        let milliseconds = Date().timeIntervalSince(started) * 1000
        let outputs = (gaze.results as? [VNCoreMLFeatureValueObservation]) ?? []
        func output(_ name: String) -> Double? {
            outputs.first { $0.featureName == name }?.featureValue.multiArrayValue.map { $0[0].doubleValue }
        }
        let pixels = box.width * width
        let headYaw = degrees(face.yaw), headPitch = degrees(face.pitch)
        let fields: [String: Any] = [
            "image": (path as NSString).lastPathComponent,
            "face_x": fixed(box.midX, 3), "face_px": fixed(pixels, 0),
            "head_yaw": fixed(headYaw), "head_pitch": fixed(headPitch),
            "facing": facing(width: pixels, yaw: headYaw, pitch: headPitch),
            "gaze_yaw": fixed(output("yaw_degrees")), "gaze_pitch": fixed(output("pitch_degrees")),
            "gaze_ms": fixed(milliseconds),
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
