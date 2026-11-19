#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Encode the transparent theme artwork into standard multi-resolution Windows icons.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: make-windows-icons.swift <asset-directory>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 20, 24, 32, 48, 64, 128, 256]

func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

for theme in ["Light", "Dark", "App"] {
    let sourceURL = directory.appendingPathComponent(theme == "App" ? "AppIcon.png" : "Brand.\(theme).png")
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Could not decode \(sourceURL.path)")
    }
    var frames: [Data] = []
    for size in sizes {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not allocate icon frame")
        }
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let encoded = NSMutableData()
        guard let frame = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Could not encode icon frame")
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Could not finish icon frame") }
        frames.append(encoded as Data)
    }
    var icon = Data()
    appendInteger(UInt16(0), to: &icon)
    appendInteger(UInt16(1), to: &icon)
    appendInteger(UInt16(frames.count), to: &icon)
    var offset = 6 + frames.count * 16
    for (size, frame) in zip(sizes, frames) {
        icon.append(UInt8(size == 256 ? 0 : size))
        icon.append(UInt8(size == 256 ? 0 : size))
        icon.append(contentsOf: [0, 0])
        appendInteger(UInt16(1), to: &icon)
        appendInteger(UInt16(32), to: &icon)
        appendInteger(UInt32(frame.count), to: &icon)
        appendInteger(UInt32(offset), to: &icon)
        offset += frame.count
    }
    for frame in frames { icon.append(frame) }
    try icon.write(to: directory.appendingPathComponent(theme == "App" ? "Cliphoard.ico" : "Cliphoard.\(theme).ico"), options: .atomic)
}
