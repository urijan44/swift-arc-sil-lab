//
//  WeakReference.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

/// Logs the lifetime of an object referenced through weak storage.
final class WeakTarget {
  let id: Int

  /// Stores an identifier and prints the creation event.
  init(id: Int) {
    self.id = id
    print("target init(\(id))")
  }

  deinit {
    print("target deinit(\(id))")
  }
}

/// Observes a WeakTarget without owning it.
final class WeakObserver {
  weak var target: WeakTarget?

  /// Stores the supplied object in weak storage.
  init(target: WeakTarget?) {
    self.target = target
  }
}

/// Verifies that a weak load returns nil after the strong reference is released.
@inline(never)
func runWeakReferenceExperiment() {
  var target: WeakTarget? = WeakTarget(id: 2)
  let observer = WeakObserver(target: target)

  print("before nil: \(observer.target?.id as Any)")
  target = nil
  print("after nil: \(observer.target?.id as Any)")
}

runWeakReferenceExperiment()
