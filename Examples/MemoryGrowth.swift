//
//  MemoryGrowth.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

/// Owns a distinct heap buffer on every iteration to expose the RSS difference.
final class Payload {
  let bytes: [UInt8]

  /// Creates a unique 256 KiB buffer.
  init(seed: Int) {
    self.bytes = [UInt8](
      repeating: UInt8(truncatingIfNeeded: seed),
      count: 256 * 1024
    )
  }
}

/// Reads the payload buffer so the allocation cannot be eliminated as dead code.
@inline(never)
func consume(_ payload: Payload) -> Int {
  Int(payload.bytes[payload.bytes.count - 1])
}

/// Repeatedly creates local objects to compare RSS with and without release.
@inline(never)
func allocatePayloads(iterations: Int) -> Int {
  var checksum = 0

  for index in 0 ..< iterations {
    let payload = Payload(seed: index)
    checksum &+= consume(payload)
  }

  return checksum
}

print("checksum: \(allocatePayloads(iterations: 512))")
