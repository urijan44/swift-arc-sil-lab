//
//  StrongReference.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

/// Logs when an object is created and destroyed.
final class TrackedObject {
  let id: Int

  /// Stores an identifier and prints the creation event.
  init(id: Int) {
    self.id = id
    print("init(\(id))")
  }

  deinit {
    print("deinit(\(id))")
  }
}

/// Uses the object so the optimizer cannot eliminate the experiment.
@inline(never)
func consume(_ object: TrackedObject) {
  print("consume(\(object.id))")
}

/// Observes destruction after the lifetime of a local strong reference ends.
@inline(never)
func runStrongReferenceExperiment() {
  print("before scope")

  do {
    let object = TrackedObject(id: 1)
    consume(object)
    print("before scope end")
  }

  print("after scope")
}

runStrongReferenceExperiment()
