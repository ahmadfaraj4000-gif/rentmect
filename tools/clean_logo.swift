import AppKit
import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: clean_logo.swift input output\n", stderr)
  exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
  let image = NSImage(contentsOf: inputURL),
  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fputs("Could not read input image.\n", stderr)
  exit(1)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
  data: &pixels,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: bytesPerRow,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("Could not create bitmap context.\n", stderr)
  exit(1)
}

context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width
var minY = height
var maxX = 0
var maxY = 0

func offset(_ x: Int, _ y: Int) -> Int {
  (y * bytesPerRow) + (x * bytesPerPixel)
}

func isLogoPixel(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
  return !(r > 238 && g > 238 && b > 238)
}

for y in 0..<height {
  for x in 0..<width {
    let i = offset(x, y)
    let r = pixels[i]
    let g = pixels[i + 1]
    let b = pixels[i + 2]
    if isLogoPixel(r, g, b) {
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
    }
  }
}

guard minX <= maxX && minY <= maxY else {
  fputs("No logo pixels found.\n", stderr)
  exit(1)
}

let padding = 24
minX = max(0, minX - padding)
minY = max(0, minY - padding)
maxX = min(width - 1, maxX + padding)
maxY = min(height - 1, maxY + padding)

let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1
let outBytesPerRow = cropWidth * bytesPerPixel
var outPixels = [UInt8](repeating: 0, count: cropHeight * outBytesPerRow)

for y in 0..<cropHeight {
  for x in 0..<cropWidth {
    let source = offset(minX + x, minY + y)
    let dest = (y * outBytesPerRow) + (x * bytesPerPixel)
    let r = pixels[source]
    let g = pixels[source + 1]
    let b = pixels[source + 2]

    outPixels[dest] = r
    outPixels[dest + 1] = g
    outPixels[dest + 2] = b

    if r > 238 && g > 238 && b > 238 {
      outPixels[dest + 3] = 0
    } else {
      outPixels[dest + 3] = 255
    }
  }
}

guard
  let outContext = CGContext(
    data: &outPixels,
    width: cropWidth,
    height: cropHeight,
    bitsPerComponent: 8,
    bytesPerRow: outBytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ),
  let outImage = outContext.makeImage(),
  let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
else {
  fputs("Could not create output image.\n", stderr)
  exit(1)
}

CGImageDestinationAddImage(destination, outImage, nil)
if !CGImageDestinationFinalize(destination) {
  fputs("Could not write output image.\n", stderr)
  exit(1)
}
