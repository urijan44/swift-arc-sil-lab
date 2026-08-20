# Swift ARC는 어떻게 객체를 해제할까? SIL에서 `strong_release`를 지워 확인해봤다

**언어:** [한국어](README.ko.md) · [English](README.md)

> Swift 6.3.1에서 소유권이 SIL로 변환되는 과정을 살펴보고, `strong_release` 한 줄을 직접 제거해 누수를 만든 뒤, weak reference lowering과 Swift runtime의 호출 경로까지 추적한 기록이다.

Swift ARC를 “런타임이 일정한 주기로 메모리를 훑다가 사용하지 않는 객체를 발견하면 해제하는 기능”이라고 이해하는 경우가 있다. `Automatic`이라는 이름만 보면 그럴듯하지만, 이 설명은 Swift의 reference counting보다 tracing garbage collector에 더 가깝다.

Swift ARC의 기본 동작은 다르다.

1. 컴파일러가 값의 소유권과 lifetime을 분석한다.
2. 분석 결과를 SIL의 `copy_value`, `destroy_value`, `strong_retain`, `strong_release` 같은 연산으로 표현한다.
3. 이 연산은 다시 `swift_retain`, `swift_release` 같은 runtime 동작으로 lowering된다.
4. release가 객체의 strong reference count를 0으로 만들면 그 실행 흐름에서 객체 파괴가 시작된다.

즉, root에서 도달 가능한 객체를 찾기 위해 런타임이 주기적으로 힙 전체를 순회하는 구조가 아니다. 소유권이 변하는 사건에 따라 reference count가 갱신되는 구조다.

이 저장소에서는 이 설명을 네 층에서 교차 검증한다.

- Source → SILGen → SIL → LLVM IR 변환
- 객체 release 한 줄만 제거하는 개입 실험
- `deinit`, maximum RSS, LLDB backtrace를 이용한 runtime 관찰
- Swift 오픈소스 reference-counting 구현 확인

추가로 weak storage가 어떻게 lowering되는지 살펴보고, strong reference cycle을 통해 ARC와 tracing GC의 판단 기준이 어떻게 다른지도 비교한다.

## 결과를 한 장으로 요약하면

```text
Swift source의 소유권
        │
        ▼
SIL destroy/release 연산
        │
        ▼
swift_release / refcount 감소
        │
        ├── count > 0 ──► 객체 유지
        │
        └── count == 0 ─► deinit / 객체 파괴
```

실험 객체의 `strong_release`를 제거하자 이 사슬이 끊겼다. `deinit`이 호출되지 않았고, 동일한 반복 할당 workload의 maximum RSS는 약 2.5MB에서 145MB로 증가했다.

## 실험 환경

저장소의 patch는 다음 환경에서 검증했다.

```text
Apple Swift version 6.3.1
Target: arm64-apple-macosx26.0
Xcode 26.4.1
```

SIL은 compiler의 구현 세부사항에 속한다. Swift 버전이나 optimization option이 바뀌면 instruction 선택, 임시 값 번호, release 위치도 달라질 수 있다. 다른 toolchain에서 patch가 적용되지 않는다면 SIL을 다시 생성하고 대상 객체의 release를 찾아 patch 문맥을 갱신해야 한다.

## SIL을 처음 보는 독자를 위한 짧은 설명

SIL(Swift Intermediate Language)은 Swift source와 LLVM IR 사이의 중간 표현이다. Swift의 타입, 호출 규약, generic, 소유권 정보를 LLVM IR보다 높은 수준에서 보존하므로, 컴파일러가 Swift 고유의 의미를 분석하고 최적화하기 좋다.

이 글에서 관찰하는 compile pipeline은 다음과 같다.

| 단계 | 생성 명령 | 이 글에서 확인할 것 |
| --- | --- | --- |
| Swift source | `.swift` | scope, `let`, `weak` 같은 언어 표현 |
| Raw SIL | `swiftc -emit-silgen` | `@owned`, `@guaranteed`, `begin_borrow`, `destroy_value` |
| Canonical SIL | `swiftc -emit-sil -Onone -Xfrontend -disable-arc-opts` | `strong_release`, `load_weak`, `store_weak` |
| LLVM IR | `swiftc -emit-ir` | `swift_release`, `swift_weakLoadStrong` 등 runtime entry point |
| Machine code/runtime | 실행 및 LLDB | refcount 감소에서 `deinit`으로 이어지는 호출 경로 |

`-disable-arc-opts`는 ARC 연산을 쉽게 관찰하기 위해 optimization을 억제하는 compiler 내부 option이다. production build에 권장하는 설정이 아니다. ARC optimization을 허용하면 컴파일러가 균형 잡힌 retain/release pair를 제거하거나, release 위치를 이동하거나, 호출 규약으로 소유권을 전달하거나, runtime call을 inline할 수 있다.

## 실험 1: 지역 strong reference가 컴파일되는 과정

[`Examples/StrongReference.swift`](Examples/StrongReference.swift)의 핵심 source는 의도적으로 단순하게 만들었다.

```swift
do {
    let object = TrackedObject(id: 1)
    consume(object)
    print("before scope end")
}

print("after scope")
```

`TrackedObject`는 `init`과 `deinit`에서 log를 출력한다. `consume`에는 `@inline(never)`를 붙여 객체 사용이 관찰 가능한 형태로 남게 했다.

### Raw SIL: 소유권과 lifetime

`-emit-silgen` 결과에서 중요한 부분만 추리면 다음과 같다.

```sil
%37 = apply %36(...) : ... -> @owned TrackedObject
%38 = move_value [lexical] [var_decl] %37

%40 = begin_borrow %38
%42 = apply %41(%40) : ... (@guaranteed TrackedObject) -> ()
end_borrow %40

destroy_value %38
```

각 연산의 의미는 다음과 같다.

- `@owned`: 값이 독립적인 소유권을 가진다. 모든 control-flow path에서 정확히 한 번 소비되어야 한다.
- `move_value [lexical]`: source의 지역 변수 `object`에 대응하는 lexical lifetime을 만든다.
- `begin_borrow` / `end_borrow`: 소유권을 복사하거나 넘기지 않고 `consume`이 객체를 빌려 쓰게 한다.
- `destroy_value`: owned value의 lifetime을 끝낸다. 이 추상화 단계에서는 반드시 `swift_release`라는 구체적인 runtime call 형태일 필요는 없다.

[SIL ownership specification](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/SIL.md#ownership)도 같은 invariant를 정의한다. owned value는 `destroy_value` 또는 다른 consuming instruction에 의해 모든 경로에서 정확히 한 번 소비되어야 한다.

### Canonical SIL: 구체적인 객체 release

ownership lowering 뒤에는 같은 lifetime 종료가 더 구체적으로 드러난다.

```sil
%32 = apply %31(...) : ... -> @owned TrackedObject
debug_value %32, let, name "object"

%35 = apply %34(%32) : ... (@guaranteed TrackedObject) -> ()

// print("before scope end")에 해당하는 코드

strong_release %32

// print("after scope")에 해당하는 코드
```

Source에는 `release(object)`라는 호출이 없다. 컴파일러가 source-level lifetime 규칙으로부터 `strong_release %32`를 만들어냈다.

공식 [SIL instruction reference](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/Instructions.md#strong_release)는 `strong_release`가 참조하는 heap object의 strong count를 감소시킨다고 정의한다. count가 0이 되면 객체가 파괴되고, strong 및 unowned count 상태가 허용하는 시점에 객체 메모리가 해제된다.

LLVM IR에서는 다음과 같은 runtime call로 내려간다.

```llvm
call void @swift_release(ptr %object)
```

이제 source lifetime부터 runtime reference-count 연산까지 하나의 경로로 연결할 수 있다.

## 실험 2: `strong_release` 한 줄만 제거하기

[`SIL/remove-object-release.patch`](SIL/remove-object-release.patch)는 다음 한 줄만 제거한다.

```diff
-  strong_release %32
```

객체 생성, 객체 사용, 출력문, destructor와 나머지 SIL은 그대로다. 원본 SIL과 수정한 SIL을 각각 실행 파일로 다시 만들었다.

원본 SIL의 실행 결과:

```text
before scope
init(1)
consume(1)
before scope end
deinit(1)
after scope
```

객체의 `strong_release`를 제거한 결과:

```text
before scope
init(1)
consume(1)
before scope end
after scope
```

`deinit(1)`이 사라졌다. scope가 끝나고 다음 문장까지 실행됐지만, 런타임이 나중에 객체를 다시 발견해서 수집하지 않는다. strong count를 감소시켜야 할 ownership event 자체가 사라졌기 때문이다.

Textual SIL을 다시 compile할 때는 SIL 생성 시 사용한 module name을 동일하게 전달해야 한다.

```bash
xcrun swiftc \
    -module-name ARCLab \
    Build/SIL/StrongReference.leaky.sil \
    -o Build/Binaries/strong-leaky
```

SIL에는 module context에 결합된 mangled symbol과 metadata가 들어 있으므로 module name이 중요하다.

## 실험 3: 누락된 release를 실제 메모리 증가로 관찰하기

`deinit` log가 사라진 것으로 객체 lifetime이 끝나지 않았음을 알 수 있다. 하지만 메모리 사용량 차이까지 관찰하면 결과가 더 명확해진다.

[`Examples/MemoryGrowth.swift`](Examples/MemoryGrowth.swift)는 `Payload` 객체를 512회 만든다. 각 객체는 별도의 256KiB array buffer를 소유한다. 정상 SIL에서는 매 loop iteration 끝에서 지역 payload의 `strong_release`가 실행된다. [`SIL/remove-payload-release.patch`](SIL/remove-payload-release.patch)는 이 release만 제거한다.

2026-08-20 마지막 검증 결과는 다음과 같았다.

| 실행 파일 | Maximum RSS |
| --- | ---: |
| 원본 SIL | 2,523,136 bytes |
| `strong_release` 제거 | 145,096,704 bytes |

절대값은 OS, allocator, machine 상태에 따라 달라질 수 있다. 중요한 것은 실험 통제다. 두 실행 파일은 같은 크기의 객체를 같은 횟수만큼 만들고 같은 방식으로 사용한다. 의도적으로 바꾼 것은 객체 release 한 줄뿐이다.

```text
같은 allocation size
같은 객체 사용
같은 iteration count
        │
        └── strong_release 유무만 변경
                     │
                     ├── 있음: iteration마다 buffer 회수
                     └── 없음: buffer 누적
```

단순한 시간적 상관관계가 아니라 원인 하나를 제거한 개입 실험이다.

## 실험 4: weak reference는 무엇이 다를까

[`Examples/WeakReference.swift`](Examples/WeakReference.swift)의 observer는 target을 다음과 같이 저장한다.

```swift
final class WeakObserver {
    weak var target: WeakTarget?
}
```

### Getter: `load_weak`

Synthesized getter에는 다음 SIL이 들어간다.

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

- `ref_element_addr`: observer 내부의 `target` property storage 주소를 구한다.
- `begin_access [read]`: storage의 read access scope를 시작한다.
- `load_weak`: weak slot을 안전하게 읽는다.
- getter의 반환형은 `@owned Optional<WeakTarget>`이다. field가 target을 지속적으로 strong-own한다는 뜻이 아니다. load 시점에 target이 살아 있다면 caller가 안전하게 쓸 수 있는 일시적인 strong result를 만든다는 뜻이다.

LLVM IR에서 `load_weak`는 다음과 같이 lowering된다.

```llvm
%target = call ptr @swift_weakLoadStrong(ptr %weakStorage)
```

이름 그대로 weak storage에서 값을 읽되, target이 살아 있다면 strong reference로 반환한다. concurrent deallocation 중인 객체를 무효한 pointer로 반환하지 않기 위한 동작이다.

### Setter: `store_weak`

Synthesized setter에는 다음 SIL이 들어간다.

```sil
%5 = ref_element_addr %1, #WeakObserver.target
%6 = begin_access [modify] [dynamic] %5
store_weak %0 to %6
end_access %6
```

Property에 값을 보관하는 핵심 연산은 `store_weak`이다. target을 지속적으로 retain하는 strong-property assignment가 아니다.

Setter parameter 주변에는 균형 잡힌 `retain_value %0`, `release_value %0`가 보일 수 있다. 이는 호출 도중 temporary value를 안전하게 유지하기 위한 연산이다. `WeakObserver.target`이 target의 strong owner가 된다는 의미가 아니다.

### Weak storage 파괴

이 toolchain에서 synthesized `WeakObserver.deinit`은 다음과 같이 보인다.

```sil
%2 = ref_element_addr %0, #WeakObserver.target
%3 = begin_access [deinit] [static] %2
destroy_addr %3
end_access %3
```

Canonical SIL text에는 `destroy_weak`이라는 instruction이 직접 나타나지 않는다. Type-aware `destroy_addr`가 더 낮은 단계로 lowering되고, LLVM IR에서는 다음 runtime call을 확인할 수 있다.

```llvm
call void @swift_weakDestroy(ptr %weakStorage)
```

Instruction 이름은 compiler stage와 버전에 따라 달라질 수 있다. Swift 6.3.1에서 실제로 관찰한 mapping은 다음과 같다.

| 의미 | Canonical SIL | LLVM IR/runtime |
| --- | --- | --- |
| weak storage 초기화 | `store_weak ... [init]` | `swift_weakInit` |
| weak storage 대입 | `store_weak` | `swift_weakAssign` |
| weak storage 읽기 | `load_weak` | `swift_weakLoadStrong` |
| weak storage 파괴 | `destroy_addr` | `swift_weakDestroy` |

Runtime 결과도 이 소유권 모델과 일치한다.

```text
target init(2)
before nil: Optional(2)
target deinit(2)
after nil: nil
```

Native Swift object에 weak reference를 만들면 runtime은 side table을 생성할 수 있다. Weak variable은 이 side table을 통해 target의 생명 상태를 관찰한다. [`RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h#L54-L169)의 lifecycle 주석은 strong, unowned, weak count와 side-table state를 자세히 설명한다.

여기서 `deinit` 실행과 모든 관련 allocation의 최종 `free`를 같은 순간으로 단순화하면 안 된다. strong count가 0이면 deinitialization이 시작되지만, outstanding unowned reference가 있으면 객체 allocation의 수명이 연장될 수 있고 weak reference가 남아 있으면 side table은 더 오래 유지될 수 있다. 이것 역시 tracing GC가 아니라 event-driven reference-count state machine이다.

## “주기적 순회가 없다”는 것을 어떻게 보여줄 수 있을까

유한한 실험만으로 “어디에도 숨은 loop가 존재하지 않는다”라는 보편적인 부정을 수학적으로 증명할 수는 없다. 10초를 기다렸는데 객체가 남아 있다는 관찰만 제시하면 “가상의 주기가 11초일 수도 있지 않은가?”라는 반론을 배제하지 못한다.

더 강한 컴퓨팅 사고는 서로 독립적인 층의 증거를 결합하는 것이다.

### 1. Compile 결과에서 원인을 찾는다

Source lifetime이 `destroy_value`, `strong_release`, `swift_release`로 변환되는 것을 확인했다. 객체 파괴를 시작하는 mechanism을 compile artifact에서 구체적으로 식별한 셈이다.

### 2. 그 원인만 제거한다

`strong_release` 한 줄을 지우자 `deinit`이 사라지고 동일 workload의 maximum RSS가 약 2.5MB에서 145MB로 증가했다. 결과가 ownership event 존재 여부와 직접 연결된다.

### 3. Runtime call stack을 확인한다

`TrackedObject.deinit`에 breakpoint를 걸면 다음 stack을 얻는다.

```text
TrackedObject.deinit
TrackedObject.__deallocating_deinit
_swift_release_dealloc
RefCounts<...>::doDecrementSlow<...>
runStrongReferenceExperiment
main
```

Destructor가 collector thread나 timer callback에서 진입한 것이 아니다. `runStrongReferenceExperiment`를 실행한 main thread의 decrement path에서 직접 `deinit`으로 이어졌다. `swift_release` wrapper는 inline되어 별도 frame으로 보이지 않을 수 있지만 `doDecrementSlow`와 `_swift_release_dealloc`은 남아 있다.

### 4. Runtime source의 control flow를 읽는다

Swift [`HeapObject.cpp`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp#L593-L619)에서 `swift_release` 경로는 다음 코드로 이어진다.

```cpp
object->refCounts.decrementAndMaybeDeinit(1, count);
```

[`RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h#L1019-L1075)의 zero-count slow path는 객체를 deinitialization 상태로 바꾸고 다음 함수를 호출한다.

```cpp
_swift_release_dealloc(getHeapObject());
```

마지막으로 [`_swift_release_dealloc`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp#L894-L896)이 metadata의 destroy function을 호출한다.

```cpp
asFullMetadata(object->metadata)->destroy(object);
```

구현의 control flow 자체가 명시적이다.

```text
release event → decrement → zero 확인 → destroy
```

### 5. Reference cycle을 구분 사례로 사용한다

[`Examples/ReferenceCycle.swift`](Examples/ReferenceCycle.swift)는 두 node가 서로를 strong-own하게 만든 다음 모든 외부 strong reference를 제거한다.

```swift
first?.next = second
second?.next = first

first = nil
second = nil
```

프로그램 외부에서는 두 객체에 도달할 수 없지만, 각 객체에는 상대 객체가 가진 strong reference 하나가 남아 있다.

```text
first  --strong--> second
  ^                  |
  |------strong------|
```

Tracing collector의 핵심 판단 기준은 root로부터의 reachability다. 반면 ARC의 판단 기준은 strong reference count다. 이 cycle에서는 두 count가 모두 0이 되지 않으므로 어느 `deinit`도 호출되지 않는다.

```text
init(first)
init(second)
external references released
wait finished; no deinit was called
```

`sleep` 자체가 증명은 아니다. 더 중요한 점은 retain과 release를 하나씩 계산하면 결과를 연역할 수 있다는 것이다. 두 객체의 마지막 count가 0보다 크고, runtime 관찰도 그 계산과 일치한다.

## 비슷한 선행 사례와 이번 실험의 차이

SIL을 수정해 객체 deallocation을 조사하는 아이디어 자체가 처음이라고 주장해서는 안 된다. 이번 실험을 독립적으로 진행한 뒤 검색해보니 매우 가까운 선행 사례 하나를 찾을 수 있었다.

2023년 Swift Forums의 [“SIL strong_release behavior”](https://forums.swift.org/t/sil-strong-release-behavior/66387)에서 질문자는 생성된 SIL의 `__deallocating_deinit` 내부 `dealloc_ref`를 제거하고 Apple `leaks` 도구로 누수를 관찰했다. Joe Groff는 strong count가 0이 되면 `__deallocating_deinit`이 호출되고, 이 함수가 `deinit` 호출, stored property 파괴, 객체 메모리 deallocation을 최종적으로 담당한다고 설명했다.

선행 사례와 이 저장소는 같은 lifecycle에서 서로 다른 연결 고리를 제거한다.

| 2023년 Swift Forums 실험 | 이번 실험 |
| --- | --- |
| deallocating destructor 내부의 `dealloc_ref` 제거 | 그보다 앞선 ownership event인 `strong_release` 제거 |
| `leaks`로 결과 관찰 | `deinit`과 maximum RSS 약 2.5MB → 145MB 비교 |
| strong-reference deallocation 중심 | strong과 weak의 SIL/LLVM IR lowering 비교 |
| SIL destructor 관계 설명 | LLDB로 `doDecrementSlow → _swift_release_dealloc → deinit` 확인 |
| 하나의 의문을 조사 | 가설 전체를 source-to-runtime 재현 저장소로 구성 |

“명시적인 주기적 GC phase가 없는가?”라는 질문에 대한 직접적인 역사적 확인도 있다. 2016년 Swift compiler 토론 [“Questions about ARC”](https://forums.swift.org/t/questions-about-arc/4621/6)에서 한 참여자가 Swift가 명시적인 garbage-collection phase 없이 immediate reference counting을 사용하는지 물었고, [Swift 개발자 Roman Levenstein은 그 이해가 맞다고 확인했다](https://forums.swift.org/t/questions-about-arc/4621/7). 같은 토론에서 ARC update가 합쳐지거나 최적화될 수 있다는 설명도 나오지만, 이것이 runtime을 tracing collector로 바꾸는 것은 아니다.

따라서 이 글의 가치는 SIL이 객체 파괴를 제어한다는 사실을 최초로 발견했다는 데 있지 않다. 다음 항목을 하나의 재현 가능한 실험으로 결합했다는 데 있다.

- 객체 lifetime을 끝내는 `strong_release`를 직접 제거
- 동일 workload에서 release 유무에 따른 RSS 비교
- weak storage를 SIL과 LLVM IR 양쪽에서 설명
- runtime decrement부터 destructor까지 LLDB stack으로 확인
- 전체 과정을 다시 실행할 수 있는 source와 script로 공개

## 중요한 한계와 흔한 오해

### 정확한 `deinit` source line은 고정되어 있지 않다

Event-driven reference counting이라는 사실이 release가 source의 닫는 중괄호 위치에 반드시 남는다는 뜻은 아니다. Optimizer는 lexical lifetime과 deinit barrier 규칙을 지키는 범위에서 마지막 사용 이후로 lifetime을 줄일 수 있다. Lifetime을 명시적으로 연장해야 한다면 `withExtendedLifetime(_:)`을 사용해야 한다.

### Retain과 release가 항상 함수 호출로 남지는 않는다

컴파일러는 균형 잡힌 연산을 제거하고, 호출 규약으로 소유권을 전달하고, runtime function을 inline할 수 있다. 최종 assembly에서 source reference마다 `swift_retain`과 `swift_release`가 1:1로 보일 것이라고 기대하면 안 된다.

### `autoreleasepool`은 tracing GC가 아니다

Objective-C interoperability에서는 autoreleased object의 release가 pool drain 시점까지 지연될 수 있다. 등록된 ownership operation을 묶어서 처리하는 mechanism이지, 힙을 순회해 unreachable object를 찾는 collector가 아니다.

### Weak reference도 공짜는 아니다

Weak field는 target의 strong count를 지속적으로 올리지 않지만, weak storage를 위한 runtime bookkeeping, side-table state, 안전한 concurrent load가 필요하다. “소유하지 않는다”와 “runtime cost가 없다”는 같은 말이 아니다.

## 직접 재현하기

필요한 환경:

- macOS
- Xcode command-line tools
- Textual SIL patch가 적용될 만큼 검증 버전과 가까운 Swift toolchain

전체 실험 실행:

```bash
./Scripts/run-experiments.sh
```

Script는 다음 작업을 수행한다.

1. Raw SIL, canonical SIL, LLVM IR을 `Build/SIL` 아래에 생성한다.
2. 선택한 `strong_release`를 제거하는 patch를 적용한다.
3. 원본 SIL과 수정 SIL을 각각 별도 실행 파일로 compile한다.
4. strong, weak, cycle 실험을 실행한다.
5. 반복 할당 workload의 maximum RSS를 출력한다.

Release에서 `deinit`으로 이어지는 call stack 확인:

```bash
./Scripts/capture-release-stack.sh
```

생성된 artifact에서 핵심 instruction 검색:

```bash
rg -n 'destroy_value|strong_release' Build/SIL/StrongReference.*.sil
rg -n 'load_weak|store_weak' Build/SIL/WeakReference.*.sil
rg -n 'swift_release|swift_weak' Build/SIL/*.ll
```

## 결론

Swift ARC의 `Automatic`은 런타임이 주기적으로 힙을 순회한다는 뜻이 아니다. 개발자가 모든 retain과 release를 직접 source에 작성하지 않아도 되도록 컴파일러가 프로그램의 lifetime 규칙에서 ownership operation을 만들고, runtime이 그 결과에 따라 reference-count state를 전환한다는 뜻에 가깝다.

이번 실험에서 확인한 내용은 다음과 같다.

- Source ownership이 SIL의 destroy/release 연산으로 변환됐다.
- `strong_release` 한 줄을 제거하자 `deinit`이 사라지고 heap 사용량이 실제로 증가했다.
- LLDB에서 decrement slow path가 deallocating destructor로 직접 이어졌다.
- Weak property는 전용 weak-storage operation과 side-table runtime call로 lowering됐다.
- Strong cycle은 unreachable 상태가 된 뒤에도 reference count가 0이 아니어서 메모리에 남았다.

따라서 Swift ARC는 “주기적인 청소”가 아니라 compiler-generated ownership operation이 runtime reference-count transition을 구동하는 구조로 이해해야 한다.

## 참고 자료

- [The Swift Programming Language — Automatic Reference Counting](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/)
- [Swift SIL specification](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/SIL.md)
- [Swift SIL instruction reference — `strong_release`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/Instructions.md#strong_release)
- [Swift runtime — `HeapObject.cpp`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp)
- [Swift runtime — `RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h)
- [Swift Forums — SIL strong_release behavior (2023)](https://forums.swift.org/t/sil-strong-release-behavior/66387)
- [Swift Forums — Questions about ARC (2016)](https://forums.swift.org/t/questions-about-arc/4621/7)
