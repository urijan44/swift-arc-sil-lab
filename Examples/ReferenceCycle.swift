//
//  ReferenceCycle.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

import Foundation

/// 서로를 strong reference로 가리켜 순환 참조를 구성한다.
final class CycleNode {
  let name: String
  var next: CycleNode?

  /// 노드 이름을 저장하고 생성 이벤트를 출력한다.
  init(name: String) {
    self.name = name
    print("init(\(name))")
  }

  deinit {
    print("deinit(\(name))")
  }
}

/// 외부 strong reference가 사라진 뒤에도 순환 참조가 남는지 관찰한다.
@inline(never)
func runReferenceCycleExperiment() {
  var first: CycleNode? = CycleNode(name: "first")
  var second: CycleNode? = CycleNode(name: "second")

  first?.next = second
  second?.next = first

  first = nil
  second = nil

  print("external references released")
  Thread.sleep(forTimeInterval: 2)
  print("wait finished; no deinit was called")
}

runReferenceCycleExperiment()
