//
//  StrongReference.swift
//  SwiftARCSILLab
//
//  Created by henry.lee on 08/20/26
//

/// 객체의 생성과 소멸 시점을 콘솔에 기록한다.
final class TrackedObject {
  let id: Int

  /// 추적할 식별자를 저장하고 생성 이벤트를 출력한다.
  init(id: Int) {
    self.id = id
    print("init(\(id))")
  }

  deinit {
    print("deinit(\(id))")
  }
}

/// 전달받은 객체를 실제로 사용해 optimizer가 객체 사용을 제거하지 못하게 한다.
@inline(never)
func consume(_ object: TrackedObject) {
  print("consume(\(object.id))")
}

/// 지역 strong reference의 마지막 사용 뒤 객체가 해제되는 과정을 관찰한다.
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
