//
//  ReferenceCycle.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

import Foundation

/// Forms a reference cycle by holding another node strongly.
final class CycleNode {
  let name: String
  var next: CycleNode?

  /// Stores the node name and prints the creation event.
  init(name: String) {
    self.name = name
    print("init(\(name))")
  }

  deinit {
    print("deinit(\(name))")
  }
}

/// Observes a cycle after every external strong reference is released.
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
