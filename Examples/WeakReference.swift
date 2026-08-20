//
//  WeakReference.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

/// weak storage가 가리킬 객체의 생명주기를 출력한다.
final class WeakTarget {
  let id: Int

  /// 추적할 식별자를 저장하고 생성 이벤트를 출력한다.
  init(id: Int) {
    self.id = id
    print("target init(\(id))")
  }

  deinit {
    print("target deinit(\(id))")
  }
}

/// WeakTarget을 소유하지 않고 관찰만 한다.
final class WeakObserver {
  weak var target: WeakTarget?

  /// 전달된 객체를 weak storage에 저장한다.
  init(target: WeakTarget?) {
    self.target = target
  }
}

/// strong reference가 사라질 때 weak load가 nil을 반환하는지 확인한다.
@inline(never)
func runWeakReferenceExperiment() {
  var target: WeakTarget? = WeakTarget(id: 2)
  let observer = WeakObserver(target: target)

  print("before nil: \(observer.target?.id as Any)")
  target = nil
  print("after nil: \(observer.target?.id as Any)")
}

runWeakReferenceExperiment()
