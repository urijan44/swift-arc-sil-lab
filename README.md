# Swift ARC는 루프를 돌며 객체를 찾지 않는다

> Swift 6.3.1에서 SIL의 `strong_release`를 직접 제거하고, 객체 수명과 메모리 사용량이 어떻게 달라지는지 확인한 기록이다.

Swift의 ARC(Automatic Reference Counting)를 “런타임이 일정한 주기로 메모리를 훑어서 사용하지 않는 객체를 해제하는 기능”이라고 설명하는 경우가 있다. `Automatic`이라는 이름만 보면 그럴듯하지만, 그것은 tracing garbage collector의 동작에 더 가깝다.

Swift ARC의 기본 모델은 다르다.

1. 컴파일러가 값의 소유권과 lifetime을 분석한다.
2. 그 결과를 SIL의 `copy_value`, `destroy_value`, `strong_retain`, `strong_release` 같은 연산으로 표현한다.
3. 실행 파일에서는 이 연산이 `swift_retain`, `swift_release` 등의 런타임 동작으로 내려간다.
4. `release`가 strong reference count를 0으로 만들면 그 실행 흐름 안에서 `deinit`과 deallocation이 시작된다.

즉 “어떤 객체가 더 이상 도달 가능한가?”를 확인하려고 힙 전체를 주기적으로 순회하는 것이 아니다. 소유권이 바뀌는 사건에 따라 카운터를 갱신한다.

이 글에서는 이 주장을 다음 네 방법으로 교차 확인한다.

- Source → SILGen → SIL → LLVM IR 변환을 관찰한다.
- SIL에서 객체 하나의 `strong_release`만 제거한 뒤 다시 실행한다.
- 반복 할당 코드에서 같은 release를 제거하고 최대 RSS를 비교한다.
- LLDB call stack과 Swift 오픈소스 런타임 구현을 연결한다.

## 실험 환경

이 저장소에서 기록한 결과의 환경은 다음과 같다.

```text
Apple Swift version 6.3.1
Target: arm64-apple-macosx26.0
Xcode 26.4.1
```

SIL은 compiler 버전과 optimization option에 따라 명령 이름, 임시 값 번호, release 위치가 달라질 수 있다. 이 저장소의 patch는 위 버전에서 검증했다. 다른 버전에서 patch context가 맞지 않는다면 생성된 SIL에서 해당 객체의 release를 다시 찾아야 한다.

## 먼저 SIL이 무엇인지

SIL(Swift Intermediate Language)은 Swift source와 LLVM IR 사이의 중간 표현이다. Swift의 타입, 호출 규약, generic, 소유권 정보를 LLVM IR보다 높은 수준에서 표현한다.

이 글에서 관찰하는 파이프라인은 다음과 같다.

| 단계 | 생성 명령 | 이 글에서 볼 것 |
| --- | --- | --- |
| Swift source | `.swift` | `let`, `weak`, scope 같은 언어 표현 |
| Raw SIL | `swiftc -emit-silgen` | `@owned`, `@guaranteed`, `begin_borrow`, `destroy_value` |
| Canonical SIL | `swiftc -emit-sil -Onone -Xfrontend -disable-arc-opts` | `strong_release`, `load_weak`, `store_weak` |
| LLVM IR | `swiftc -emit-ir` | `swift_release`, `swift_weakLoadStrong` 등 runtime entry point |
| Machine code/runtime | 실행 및 LLDB | refcount 감소에서 `deinit`으로 연결되는 call stack |

`-disable-arc-opts`는 관찰을 위해 ARC optimization을 억제하는 compiler 내부 option이다. 실제 production build option으로 권장하는 설정이 아니다. 최적화를 허용하면 compiler가 불필요한 retain/release pair를 제거하거나 release 위치를 옮길 수 있다.

## 실험 1: 지역 strong reference

핵심 source는 단순하다. 전체 코드는 [`Examples/StrongReference.swift`](Examples/StrongReference.swift)에 있다.

```swift
do {
    let object = TrackedObject(id: 1)
    consume(object)
    print("before scope end")
}

print("after scope")
```

### Raw SIL: 값의 소유권과 lifetime

`-emit-silgen` 결과에서 중요한 부분만 줄이면 다음과 같다.

```sil
%37 = apply %36(...) : ... -> @owned TrackedObject
%38 = move_value [lexical] [var_decl] %37

%40 = begin_borrow %38
%42 = apply %41(%40) : ... (@guaranteed TrackedObject) -> ()
end_borrow %40

destroy_value %38
```

- `@owned`: 이 값이 독립적인 소유권을 가진다는 뜻이다. 모든 control-flow path에서 정확히 한 번 소비되어야 한다.
- `move_value [lexical]`: source의 지역 변수 `object`에 대응하는 lexical lifetime을 만든다.
- `begin_borrow` / `end_borrow`: `consume`에 객체를 넘기는 동안 소유권을 복사하지 않고 빌린다.
- `destroy_value`: `%38`의 owned lifetime을 끝낸다. 이 단계에서는 “값을 파괴한다”는 의미가 중심이고, 아직 반드시 `swift_release`라는 구체적인 runtime call 모양일 필요는 없다.

Swift SIL 문서도 owned value가 `destroy_value` 또는 consuming instruction으로 정확히 한 번 소비되어야 한다고 정의한다. 또한 optimizer가 사용 범위를 침범하지 않는 선에서 destroy 위치를 당길 수 있다고 설명한다. 자세한 규칙은 [Swift SIL: Ownership and Lifetimes](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/SIL.md#ownership)에서 확인할 수 있다.

### Canonical SIL: `strong_release`

ownership lowering 뒤에는 같은 객체의 lifetime 종료가 더 구체적으로 보인다.

```sil
%32 = apply %31(...) : ... -> @owned TrackedObject
debug_value %32, let, name "object"

%35 = apply %34(%32) : ... (@guaranteed TrackedObject) -> ()

// print("before scope end")에 해당하는 코드

strong_release %32

// print("after scope")에 해당하는 코드
```

`strong_release %32`는 `%32`가 참조하는 객체의 strong reference count를 감소시키는 연산이다. source에는 `release(object)`라는 코드가 없지만, compiler가 source의 lifetime 규칙을 이 연산으로 구체화했다.

LLVM IR에서는 이 지점이 다음처럼 내려간다.

```llvm
call void @swift_release(ptr %object)
```

## 실험 2: `strong_release` 한 줄만 제거하기

[`SIL/remove-object-release.patch`](SIL/remove-object-release.patch)는 다음 한 줄만 삭제한다.

```diff
-  strong_release %32
```

나머지 SIL은 동일하다. 원본 SIL과 수정한 SIL을 각각 다시 실행 파일로 만들면 결과가 갈린다.

원본:

```text
before scope
init(1)
consume(1)
before scope end
deinit(1)
after scope
```

`strong_release` 제거:

```text
before scope
init(1)
consume(1)
before scope end
after scope
```

두 번째 실행에서는 `deinit(1)`이 호출되지 않는다. scope가 끝나고 프로그램의 다음 문장이 실행되어도 런타임이 나중에 객체를 찾아 수집하지 않는다. 제거된 release를 대신할 소유권 사건이 없기 때문이다.

SIL을 다시 compile할 때는 생성 시 사용한 module name을 그대로 전달해야 한다.

```bash
xcrun swiftc \
    -module-name ARCLab \
    Build/SIL/StrongReference.leaky.sil \
    -o Build/Binaries/strong-leaky
```

module name이 달라지면 SIL 안의 mangled symbol 및 metadata와 compile context가 어긋날 수 있다.

## 실험 3: 정말 메모리가 증가하는가

`deinit` log가 사라진 것만으로도 객체 lifetime이 끝나지 않았다는 사실은 알 수 있다. 다만 메모리 사용량 차이도 관찰하기 위해 [`Examples/MemoryGrowth.swift`](Examples/MemoryGrowth.swift)를 추가했다.

이 코드는 256 KiB buffer를 가진 `Payload`를 512회 생성한다. 정상 SIL에서는 반복문마다 지역 객체에 해당하는 `strong_release`가 실행된다. [`SIL/remove-payload-release.patch`](SIL/remove-payload-release.patch)는 그 release만 제거한다.

2026-08-20에 같은 machine에서 측정한 결과다.

| 실행 파일 | Maximum RSS |
| --- | ---: |
| 원본 SIL | 2,523,136 bytes |
| `strong_release` 제거 | 145,096,704 bytes |

약 2.5MB와 145MB로 차이가 났다. 절대값은 OS, allocator 및 실행 시점에 따라 달라질 수 있다. 중요한 것은 두 실행 파일의 source-level 작업이 같고, 반복문의 객체 release 한 줄만 다르다는 점이다.

이 실험은 단순한 상관관계보다 강한 개입 실험이다.

```text
같은 객체 생성
같은 객체 사용
같은 반복 횟수
        │
        └─ strong_release 유무만 변경
                     │
                     ├─ 있음: buffer가 반복마다 회수됨
                     └─ 없음: buffer가 누적됨
```

## 실험 4: weak reference는 SIL에서 어떻게 다른가

[`Examples/WeakReference.swift`](Examples/WeakReference.swift)의 observer는 target을 다음처럼 저장한다.

```swift
final class WeakObserver {
    weak var target: WeakTarget?
}
```

### Getter: `load_weak`

```sil
sil ... WeakObserver.target.getter
    : $@convention(method) (@guaranteed WeakObserver)
      -> @owned Optional<WeakTarget> {
bb0(%0 : $WeakObserver):
  %2 = ref_element_addr %0, #WeakObserver.target
  %3 = begin_access [read] [dynamic] %2
  %4 = load_weak %3
  end_access %3
  return %4
}
```

- `ref_element_addr`: 객체 안에서 `target` property의 storage 주소를 구한다.
- `begin_access [read]`: 해당 storage에 대한 read access scope를 시작한다.
- `load_weak`: weak storage를 안전하게 읽는다.
- 반환형은 `@owned Optional<WeakTarget>`이다. weak field가 strong ownership을 보관한다는 뜻이 아니다. 읽는 순간 target이 살아 있다면 caller가 안전하게 사용할 수 있는 일시적인 strong result를 만드는 것이다.

LLVM IR에서 `load_weak`는 `swift_weakLoadStrong` 호출로 내려간다.

```llvm
%target = call ptr @swift_weakLoadStrong(ptr %weakStorage)
```

이름 그대로 “weak storage를 읽되, 살아 있다면 strong reference로 load”한다. concurrent deallocation 중인 객체를 무효한 pointer로 반환하지 않기 위한 동작이다.

### Setter: `store_weak`

```sil
%5 = ref_element_addr %1, #WeakObserver.target
%6 = begin_access [modify] [dynamic] %5
store_weak %0 to %6
end_access %6
```

strong property였다면 객체를 지속적으로 소유하도록 retain/release가 property assignment에 반영된다. 여기서는 field에 값을 넣는 핵심 연산이 `store_weak`이다.

Setter 주변에 `retain_value %0`, `release_value %0`가 보일 수 있다. 이것은 parameter와 temporary value의 lifetime을 안전하게 유지하기 위한 균형 잡힌 임시 소유권이다. `WeakObserver.target` property가 target의 strong count를 계속 올려 보관한다는 뜻이 아니다.

### weak storage 파괴

이 toolchain의 canonical SIL에서 synthesized `WeakObserver.deinit`은 다음처럼 보인다.

```sil
%2 = ref_element_addr %0, #WeakObserver.target
%3 = begin_access [deinit] [static] %2
destroy_addr %3
end_access %3
```

여기서는 `destroy_weak`이라는 instruction이 text로 직접 나오지 않는다. `destroy_addr`가 property의 weak 타입 정보를 바탕으로 lowering되고, LLVM IR에서는 다음 runtime call을 확인할 수 있다.

```llvm
call void @swift_weakDestroy(ptr %weakStorage)
```

따라서 특정 Swift 버전의 SIL에서 반드시 `destroy_weak` 문자열을 찾아야 한다고 가정하면 안 된다. 현재 실험에서는 다음 대응이 실제 결과다.

| 의미 | Canonical SIL | LLVM IR/runtime |
| --- | --- | --- |
| weak storage 초기화 | `store_weak ... [init]` | `swift_weakInit` |
| weak storage 대입 | `store_weak` | `swift_weakAssign` |
| weak storage 읽기 | `load_weak` | `swift_weakLoadStrong` |
| weak storage 파괴 | `destroy_addr` | `swift_weakDestroy` |

실행 결과도 field가 target을 소유하지 않는다는 사실과 일치한다.

```text
target init(2)
before nil: Optional(2)
target deinit(2)
after nil: nil
```

Swift native object에 weak reference가 처음 만들어지면 runtime은 side table을 만들 수 있다. weak variable은 이 side table을 통해 target의 생명 상태를 확인한다. [Swift runtime의 `RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h#L54-L169)는 strong, unowned, weak count와 side table을 포함한 object lifecycle을 코드 주석으로 설명한다.

여기서 `deinit` 실행과 모든 관련 allocation의 `free`를 같은 순간으로 단순화해서는 안 된다. strong count가 0이면 객체가 deinitialize되지만, outstanding unowned reference가 있으면 객체 allocation의 반환이 늦어질 수 있고 weak reference가 남아 있으면 side table은 더 오래 유지될 수 있다. 이 차이는 주기적 tracing과 무관하며, runtime의 strong/unowned/weak lifecycle state machine에 따른다.

## “순회가 없다”를 어떻게 더 강하게 검증할까

유한한 횟수의 실행만으로 “어떤 숨은 loop도 절대 존재하지 않는다”라는 보편적인 부정을 수학적으로 증명할 수는 없다. 단순히 `sleep(10)` 뒤에도 객체가 남았다는 관찰만 제시하면 “주기가 11초일 수도 있지 않은가?”라는 반론을 배제하지 못한다.

그래서 서로 다른 층의 증거를 결합해야 한다.

### 1. Compile 결과에서 원인을 찾는다

Source lifetime이 SIL의 `destroy_value`와 `strong_release`, LLVM IR의 `swift_release`로 변환되는 것을 확인했다. 이것은 해제가 특정 ownership event에 의해 시작된다는 compile-time 증거다.

### 2. 원인 하나만 제거하는 개입 실험을 한다

`strong_release` 한 줄만 제거했을 때 `deinit`이 사라지고 RSS가 증가했다. 숨은 collector가 있었다면 프로그램 종료 전 다른 시점에 객체를 회수할 가능성이 있지만, 관찰된 lifetime은 release 존재 여부와 직접 연결됐다.

### 3. Runtime call stack을 확인한다

`TrackedObject.deinit`에 breakpoint를 걸면 다음 call stack을 얻는다.

```text
TrackedObject.deinit
TrackedObject.__deallocating_deinit
_swift_release_dealloc
RefCounts<...>::doDecrementSlow<...>
runStrongReferenceExperiment
main
```

별도의 collector thread나 timer callback에서 호출된 것이 아니다. `runStrongReferenceExperiment`를 실행한 main thread의 release/decrement 경로에서 곧바로 `deinit`으로 들어왔다. 최적화로 `swift_release` wrapper가 inline되어 frame에 보이지 않을 수 있지만, `doDecrementSlow`와 `_swift_release_dealloc`은 남아 있다.

### 4. Runtime source에서 control flow를 읽는다

Swift runtime의 [`HeapObject.cpp`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp#L593-L619)에서 `swift_release` 경로는 다음 동작으로 연결된다.

```cpp
object->refCounts.decrementAndMaybeDeinit(1, count);
```

[`RefCount.h`의 slow path](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h#L1019-L1075)는 decrement 결과가 0이면 `deinitNow = true`로 전환하고 다음 호출을 수행한다.

```cpp
_swift_release_dealloc(getHeapObject());
```

그리고 [`_swift_release_dealloc`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp#L894-L896)은 metadata의 destroy function을 호출한다.

```cpp
asFullMetadata(object->metadata)->destroy(object);
```

구현의 control flow 자체가 “release event → decrement → zero 여부 → destroy”다.

### 5. Reference cycle을 반례로 사용한다

[`Examples/ReferenceCycle.swift`](Examples/ReferenceCycle.swift)는 두 객체가 서로를 strong reference로 가리키게 한 뒤 외부 reference를 모두 제거한다.

```swift
first?.next = second
second?.next = first

first = nil
second = nil
```

외부에서는 더 이상 두 객체에 도달할 수 없지만 각 객체의 strong count에는 상대 객체의 reference가 남아 있다.

```text
first  --strong--> second
  ^                  |
  |------strong------|
```

tracing GC의 핵심 판단 기준은 root에서의 reachability다. 반면 ARC의 기준은 strong count다. 이 cycle에서는 두 count가 0이 되지 않으므로 `deinit`이 호출되지 않는다.

```text
init(first)
init(second)
external references released
wait finished; no deinit was called
```

`sleep` 자체가 “순회 없음”의 증명은 아니다. 이 예제의 의미는 ARC 모델로 결과를 연역할 수 있다는 데 있다. 각 assignment와 release 후 count를 종이에 계산하면 두 객체의 count가 왜 0이 되지 않는지 설명할 수 있고, 런타임 결과도 그 계산과 일치한다.

## 중요한 한계와 오해하기 쉬운 지점

### 정확한 `deinit` source line은 고정되어 있지 않다

ARC가 event-driven reference counting이라는 사실과 compiler가 정확히 어느 source line에 release를 배치하는지는 별개의 문제다. optimizer는 객체의 마지막 사용 이후로 lifetime을 줄일 수 있고, lexical lifetime 및 deinit barrier 규칙도 적용한다. 수명을 명시적으로 연장해야 한다면 `withExtendedLifetime(_:)`를 사용한다.

### retain/release가 항상 함수 호출로 남지는 않는다

Compiler는 서로 상쇄되는 retain/release를 제거하고, 호출 규약을 통해 ownership을 전달하며, runtime function을 inline할 수 있다. 최종 assembly에서 모든 source reference마다 `swift_retain`과 `swift_release`가 1:1로 보일 것이라고 기대하면 안 된다.

### `autoreleasepool`은 tracing GC가 아니다

Objective-C interoperability에서는 autoreleased object의 release가 pool drain 시점까지 지연될 수 있다. 이것은 등록된 autorelease ownership을 묶어서 처리하는 mechanism이지, 힙을 순회해 unreachable object를 찾는 tracing collector가 아니다.

### weak도 공짜는 아니다

weak reference는 target의 strong count를 지속적으로 증가시키지 않지만, side table과 안전한 concurrent load를 위한 runtime 관리가 필요하다. “소유하지 않는다”와 “아무 runtime 비용도 없다”는 같은 말이 아니다.

## 직접 재현하기

macOS와 Xcode command line tool이 필요하다.

```bash
./Scripts/run-experiments.sh
```

이 script는 다음 작업을 수행한다.

1. Raw SIL, canonical SIL, LLVM IR을 `Build/SIL`에 생성한다.
2. patch를 적용해 `strong_release`가 제거된 SIL을 만든다.
3. 원본과 수정 SIL을 각각 compile한다.
4. strong, weak, cycle 실험을 실행한다.
5. 반복 할당 실험의 maximum RSS를 출력한다.

release에서 `deinit`까지 이어지는 call stack은 다음 명령으로 확인할 수 있다.

```bash
./Scripts/capture-release-stack.sh
```

생성된 파일에서 핵심 instruction만 빠르게 찾으려면 다음 검색도 유용하다.

```bash
rg -n 'destroy_value|strong_release' Build/SIL/StrongReference.*.sil
rg -n 'load_weak|store_weak' Build/SIL/WeakReference.*.sil
rg -n 'swift_release|swift_weak' Build/SIL/*.ll
```

## 결론

Swift ARC의 `Automatic`은 “런타임이 주기적으로 힙을 순회한다”는 뜻이 아니다. 개발자가 모든 retain/release를 source에 직접 작성하지 않아도 되도록 compiler가 소유권 규칙을 분석하고 구체적인 lifetime operation을 만든다는 뜻에 가깝다.

이 실험에서 확인한 인과관계는 다음과 같다.

```text
Source ownership
    → SIL destroy/release
    → runtime refcount decrement
    → strong count == 0
    → deinit / deallocation
```

release를 제거하면 이 사슬이 끊겼고, runtime은 나중에 객체를 다시 찾아와 수집하지 않았다. weak reference는 별도의 weak storage와 side table 경로를 사용했으며 target을 지속적으로 strong-own하지 않았다. strong reference cycle은 reachability가 아니라 reference count를 기준으로 동작한다는 차이를 그대로 드러냈다.

이것이 Swift ARC를 GC식 “주기적 청소”가 아니라 compiler가 삽입한 ownership operation과 runtime refcount state transition의 협업으로 이해해야 하는 이유다.

## 참고 자료

- [The Swift Programming Language — Automatic Reference Counting](https://docs.swift.org/swift-book/documentation/the-swift-programming-language-guide/automaticreferencecounting/)
- [Swift SIL specification](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/SIL.md)
- [Swift runtime `HeapObject.cpp`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp)
- [Swift runtime `RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h)
