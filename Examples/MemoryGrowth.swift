//
//  MemoryGrowth.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

/// 매 반복마다 별도의 heap buffer를 소유해 release 유무에 따른 RSS 차이를 만든다.
final class Payload {
  let bytes: [UInt8]

  /// 256 KiB 크기의 고유한 buffer를 만든다.
  init(seed: Int) {
    self.bytes = [UInt8](
      repeating: UInt8(truncatingIfNeeded: seed),
      count: 256 * 1024
    )
  }
}

/// Payload의 buffer를 읽어 전체 할당이 dead-code elimination 되지 않게 한다.
@inline(never)
func consume(_ payload: Payload) -> Int {
  Int(payload.bytes[payload.bytes.count - 1])
}

/// 지역 객체를 반복 생성해 정상 release와 release 제거 실행 파일의 RSS를 비교한다.
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
