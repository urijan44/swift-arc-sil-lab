# Swift ARC Doesn’t Scan the Heap — I Removed `strong_release` from SIL to Prove It

> A source-to-runtime experiment with Swift 6.3.1: inspect ownership in SIL, delete one `strong_release`, measure the resulting leak, compare weak-reference lowering, and follow the call stack into the Swift runtime.

Swift ARC is sometimes explained as if it were a background service that periodically scans memory and frees objects that are no longer used. The word *Automatic* makes that story sound plausible, but it describes a tracing garbage collector more closely than Swift’s reference-counting model.

Swift ARC works differently:

1. The compiler analyzes ownership and value lifetimes.
2. It represents those rules with operations such as `copy_value`, `destroy_value`, `strong_retain`, and `strong_release` in SIL.
3. Those operations are lowered to runtime behavior such as `swift_retain` and `swift_release`.
4. When a release brings an object’s strong reference count to zero, destruction begins on that execution path.

There is no periodic heap traversal asking which objects are still reachable from a root set. Reference-count updates are driven by ownership events.

This repository checks that claim at four different layers:

- Source → SILGen → SIL → LLVM IR
- A causal intervention: delete exactly one object release
- Runtime observations: `deinit`, maximum RSS, and an LLDB backtrace
- Swift’s open-source reference-counting implementation

It also examines how `weak` storage is lowered and uses a strong reference cycle to contrast reference counting with tracing GC.

## The result in one picture

```text
Swift source ownership
        │
        ▼
SIL destroy/release operations
        │
        ▼
swift_release / refcount decrement
        │
        ├── count > 0 ──► object stays alive
        │
        └── count == 0 ─► deinit / destruction
```

Removing the `strong_release` for the test object broke that chain. Its `deinit` disappeared, and a repeated-allocation workload grew from roughly 2.5 MB to 145 MB maximum RSS.

## Experiment environment

The checked-in patches were verified with:

```text
Apple Swift version 6.3.1
Target: arm64-apple-macosx26.0
Xcode 26.4.1
```

SIL is an implementation-level representation. Instruction selection, temporary value numbers, and release placement may change between compiler versions or optimization settings. If a patch no longer applies on another toolchain, regenerate the SIL and locate the corresponding release again.

## A short SIL primer

SIL, the Swift Intermediate Language, sits between Swift source and LLVM IR. It preserves Swift concepts—including types, calling conventions, generics, and ownership—at a level where the compiler can reason about them before lowering to LLVM.

This article observes the following pipeline:

| Stage | Command | What to inspect |
| --- | --- | --- |
| Swift source | `.swift` | Language-level scopes, `let`, and `weak` |
| Raw SIL | `swiftc -emit-silgen` | `@owned`, `@guaranteed`, `begin_borrow`, `destroy_value` |
| Canonical SIL | `swiftc -emit-sil -Onone -Xfrontend -disable-arc-opts` | `strong_release`, `load_weak`, `store_weak` |
| LLVM IR | `swiftc -emit-ir` | `swift_release`, `swift_weakLoadStrong`, and other runtime entry points |
| Machine code/runtime | Execute under LLDB | The decrement-to-`deinit` call path |

`-disable-arc-opts` is an internal compiler option used here to make ARC operations easier to inspect. It is not a recommended production build setting. With ARC optimization enabled, the compiler may remove balanced retain/release pairs, move releases, transfer ownership through calling conventions, or inline runtime operations.

## Experiment 1: Follow a local strong reference through the compiler

The relevant source from [`Examples/StrongReference.swift`](Examples/StrongReference.swift) is intentionally small:

```swift
do {
    let object = TrackedObject(id: 1)
    consume(object)
    print("before scope end")
}

print("after scope")
```

`TrackedObject` prints from `init` and `deinit`, while `consume` is marked `@inline(never)` so that the object has an observable use.

### Raw SIL: ownership and lifetime

The essential part of the `-emit-silgen` output is:

```sil
%37 = apply %36(...) : ... -> @owned TrackedObject
%38 = move_value [lexical] [var_decl] %37

%40 = begin_borrow %38
%42 = apply %41(%40) : ... (@guaranteed TrackedObject) -> ()
end_borrow %40

destroy_value %38
```

What each operation means:

- `@owned`: the value carries independent ownership and must be consumed exactly once along every control-flow path.
- `move_value [lexical]`: establishes the lexical lifetime corresponding to the local `object` variable.
- `begin_borrow` / `end_borrow`: lends the object to `consume` without transferring or duplicating ownership.
- `destroy_value`: ends the owned value’s lifetime. At this abstraction level, the compiler expresses value destruction rather than requiring a literal `swift_release` call.

The [SIL ownership specification](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/SIL.md#ownership) defines the same invariant: an owned value must be consumed exactly once, either by `destroy_value` or another consuming instruction.

### Canonical SIL: the concrete object release

After ownership lowering, the same lifetime ending becomes more concrete:

```sil
%32 = apply %31(...) : ... -> @owned TrackedObject
debug_value %32, let, name "object"

%35 = apply %34(%32) : ... (@guaranteed TrackedObject) -> ()

// Code for print("before scope end")

strong_release %32

// Code for print("after scope")
```

The source never calls `release(object)`. The compiler materialized `strong_release %32` from the source-level lifetime rules.

The official [SIL instruction reference](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/Instructions.md#strong_release) defines `strong_release` as decrementing the referenced heap object’s strong count. If the count reaches zero, the object is destroyed; object memory is deallocated once the relevant strong and unowned counts permit it.

At the LLVM IR layer, this becomes:

```llvm
call void @swift_release(ptr %object)
```

That gives us a traceable chain from source lifetime to a runtime reference-count operation.

## Experiment 2: Delete one `strong_release`

[`SIL/remove-object-release.patch`](SIL/remove-object-release.patch) removes exactly one line:

```diff
-  strong_release %32
```

The allocation, object use, print statements, destructor, and all other SIL remain unchanged. The original and modified SIL are then compiled back into separate executables.

Original SIL:

```text
before scope
init(1)
consume(1)
before scope end
deinit(1)
after scope
```

With the object’s `strong_release` removed:

```text
before scope
init(1)
consume(1)
before scope end
after scope
```

`deinit(1)` is gone. The scope ends and later statements execute, but the runtime does not rediscover and collect the object afterward. The ownership event that would have decremented its strong count is missing.

When recompiling textual SIL, use the same module name that generated it:

```bash
xcrun swiftc \
    -module-name ARCLab \
    Build/SIL/StrongReference.leaky.sil \
    -o Build/Binaries/strong-leaky
```

The module name matters because the SIL contains mangled symbols and metadata tied to that module context.

## Experiment 3: Turn the missing release into measurable heap growth

The missing `deinit` demonstrates that the object lifetime did not end, but a memory-usage comparison makes the consequence more visible.

[`Examples/MemoryGrowth.swift`](Examples/MemoryGrowth.swift) creates 512 `Payload` objects. Each object owns a distinct 256 KiB array buffer. In the normal SIL, each loop iteration ends with a `strong_release` of the local payload. [`SIL/remove-payload-release.patch`](SIL/remove-payload-release.patch) removes only that release.

The last verified run on 2026-08-20 produced:

| Executable | Maximum RSS |
| --- | ---: |
| Original SIL | 2,523,136 bytes |
| `strong_release` removed | 145,096,704 bytes |

The absolute values depend on the operating system, allocator, and machine state. The important property is experimental control: both executables perform the same allocations and workload, while one object release is the only intentional difference.

```text
Same allocation size
Same object use
Same iteration count
        │
        └── Only strong_release changes
                     │
                     ├── Present: buffers are reclaimed across iterations
                     └── Removed: buffers accumulate
```

This is a causal intervention, not merely a timing correlation.

## Experiment 4: What changes for a weak reference?

[`Examples/WeakReference.swift`](Examples/WeakReference.swift) stores its target like this:

```swift
final class WeakObserver {
    weak var target: WeakTarget?
}
```

### Getter: `load_weak`

The synthesized getter contains:

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

- `ref_element_addr` obtains the address of the `target` property inside the observer.
- `begin_access [read]` begins a read access scope for that storage.
- `load_weak` safely reads the weak slot.
- The getter returns `@owned Optional<WeakTarget>`. That does **not** mean the field persistently owns the target. If the target is alive at load time, the operation produces a temporary strong result that the caller can use safely.

In LLVM IR, `load_weak` lowers to:

```llvm
%target = call ptr @swift_weakLoadStrong(ptr %weakStorage)
```

The name is descriptive: load from weak storage and, if the target is still alive, return a strong reference. This prevents a concurrent deallocation from turning the read into an invalid pointer.

### Setter: `store_weak`

The synthesized setter contains:

```sil
%5 = ref_element_addr %1, #WeakObserver.target
%6 = begin_access [modify] [dynamic] %5
store_weak %0 to %6
end_access %6
```

The property’s persistent storage operation is `store_weak`, not a strong-property assignment that keeps the target retained.

You may still see balanced `retain_value %0` and `release_value %0` operations around the setter parameter. They protect temporary values during the call; they do not make `WeakObserver.target` a persistent strong owner.

### Destroying weak storage

With this toolchain, the synthesized `WeakObserver.deinit` contains:

```sil
%2 = ref_element_addr %0, #WeakObserver.target
%3 = begin_access [deinit] [static] %2
destroy_addr %3
end_access %3
```

There is no literal `destroy_weak` instruction in this canonical SIL output. The type-aware `destroy_addr` is lowered further, and LLVM IR contains:

```llvm
call void @swift_weakDestroy(ptr %weakStorage)
```

Instruction spelling can vary by compiler stage and version. For Swift 6.3.1, the observed mapping is:

| Meaning | Canonical SIL | LLVM IR/runtime |
| --- | --- | --- |
| Initialize weak storage | `store_weak ... [init]` | `swift_weakInit` |
| Assign weak storage | `store_weak` | `swift_weakAssign` |
| Read weak storage | `load_weak` | `swift_weakLoadStrong` |
| Destroy weak storage | `destroy_addr` | `swift_weakDestroy` |

The runtime result matches the ownership model:

```text
target init(2)
before nil: Optional(2)
target deinit(2)
after nil: nil
```

For native Swift objects, forming a weak reference may create a side table. Weak variables use that side table to observe whether the target is still alive. The lifecycle comments in [`RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h#L54-L169) describe the strong, unowned, and weak counts, along with the side-table states.

One important nuance: `deinit` and the final release of every related allocation are not necessarily the same instant. A strong count of zero begins deinitialization. Outstanding unowned references may extend the object allocation’s lifetime, and outstanding weak references may keep the side table alive even longer. That state machine is still event-driven reference counting, not tracing GC.

## How can we show there is no periodic traversal?

A finite experiment cannot mathematically prove the universal negative “no hidden loop exists anywhere.” Waiting ten seconds and observing an object still alive leaves an easy objection: perhaps the hypothetical period is eleven seconds.

A stronger computing argument combines evidence from independent layers.

### 1. Observe the compiler artifact

The source lifetime becomes `destroy_value`, then `strong_release`, then `swift_release`. This positively identifies the mechanism that initiates destruction.

### 2. Remove only that cause

Deleting one `strong_release` removes `deinit` and changes maximum RSS from approximately 2.5 MB to 145 MB under the same workload. The result tracks the ownership event directly.

### 3. Inspect the runtime call stack

Breaking on `TrackedObject.deinit` produces this stack:

```text
TrackedObject.deinit
TrackedObject.__deallocating_deinit
_swift_release_dealloc
RefCounts<...>::doDecrementSlow<...>
runStrongReferenceExperiment
main
```

The destructor is not entered from a collector thread or timer callback. It is reached on the main thread through the decrement path initiated by `runStrongReferenceExperiment`. The `swift_release` wrapper may be inlined and therefore absent as a separate frame, but `doDecrementSlow` and `_swift_release_dealloc` remain visible.

### 4. Read the runtime control flow

In Swift’s [`HeapObject.cpp`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp#L593-L619), `swift_release` reaches:

```cpp
object->refCounts.decrementAndMaybeDeinit(1, count);
```

The zero-count slow path in [`RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h#L1019-L1075) transitions the object into deinitialization and calls:

```cpp
_swift_release_dealloc(getHeapObject());
```

Finally, [`_swift_release_dealloc`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp#L894-L896) invokes the metadata destroy function:

```cpp
asFullMetadata(object->metadata)->destroy(object);
```

The implementation’s control flow is explicit:

```text
release event → decrement → zero check → destroy
```

### 5. Use a reference cycle as a distinguishing case

[`Examples/ReferenceCycle.swift`](Examples/ReferenceCycle.swift) creates two nodes that own each other, then removes every external strong reference:

```swift
first?.next = second
second?.next = first

first = nil
second = nil
```

The objects are unreachable from the program, but each still has one strong reference from the other node:

```text
first  --strong--> second
  ^                  |
  |------strong------|
```

A tracing collector reasons about reachability from roots. ARC reasons about strong reference counts. Neither count reaches zero in this cycle, so neither `deinit` runs:

```text
init(first)
init(second)
external references released
wait finished; no deinit was called
```

The `sleep` is not proof by itself. The stronger point is that the result can be derived by accounting for each retain and release: both final counts remain nonzero, and the runtime observation matches that calculation.

## Prior art—and what this experiment adds

This article should not claim that modifying SIL to study object deallocation is a new idea. After conducting this experiment independently, I found one particularly close precedent.

In the 2023 Swift Forums thread [“SIL strong_release behavior”](https://forums.swift.org/t/sil-strong-release-behavior/66387), the author generated SIL, removed the `dealloc_ref` inside `__deallocating_deinit`, and observed a leak with Apple’s `leaks` tool. Joe Groff explained that reaching a strong count of zero invokes `__deallocating_deinit`; that function is then responsible for invoking `deinit`, destroying stored properties, and deallocating the object’s memory.

That experiment and this repository modify different links in the same lifecycle:

| 2023 Swift Forums experiment | This experiment |
| --- | --- |
| Removes `dealloc_ref` inside the deallocating destructor | Removes the earlier `strong_release` ownership event |
| Observes the result with `leaks` | Compares `deinit` output and maximum RSS: ~2.5 MB → 145 MB |
| Focuses on strong-reference deallocation | Compares strong and weak lowering in SIL and LLVM IR |
| Explains the SIL destructor relationship | Captures `doDecrementSlow → _swift_release_dealloc → deinit` in LLDB |
| Investigates one surprising result | Packages the hypothesis as a reproducible source-to-runtime repository |

There is also a direct historical confirmation of the “no explicit periodic GC phase” model. In the 2016 Swift compiler discussion [“Questions about ARC”](https://forums.swift.org/t/questions-about-arc/4621/6), a participant asked whether Swift used immediate reference counting without an explicit garbage-collection phase. [Swift developer Roman Levenstein confirmed that understanding](https://forums.swift.org/t/questions-about-arc/4621/7). The same thread notes that ARC updates can still be coalesced or optimized; that does not turn the runtime into a tracing collector.

The contribution here is therefore not the first observation that SIL controls object destruction. It is the combination of:

- directly removing the `strong_release` that ends the object lifetime,
- measuring the same workload with and without that release,
- explaining weak storage across SIL and LLVM IR,
- capturing the runtime decrement-to-destructor stack, and
- publishing the complete process as a reproducible experiment.

## Important limitations and common traps

### The exact source line for `deinit` is not fixed

Event-driven reference counting does not imply that a release must remain at the closing brace shown in source. The optimizer may shorten a lifetime after its last use, subject to lexical-lifetime and deinit-barrier rules. Use `withExtendedLifetime(_:)` when a lifetime must be explicitly extended.

### Retains and releases do not always survive as function calls

The compiler may eliminate balanced operations, transfer ownership through calling conventions, or inline runtime functions. Do not expect every source reference to produce a visible one-to-one `swift_retain` / `swift_release` pair in final assembly.

### `autoreleasepool` is not tracing GC

Objective-C interoperability can delay releases for autoreleased objects until a pool drains. That batches registered ownership operations; it does not scan the heap for unreachable objects.

### Weak references are not free

A weak field does not persistently increment its target’s strong count, but weak storage still requires runtime bookkeeping, side-table state, and safe concurrent loads. “Does not own” is not the same as “has no runtime cost.”

## Reproduce the experiments

Requirements:

- macOS
- Xcode command-line tools
- a Swift toolchain close enough to the verified version for the textual SIL patches to apply

Run everything:

```bash
./Scripts/run-experiments.sh
```

The script:

1. Generates raw SIL, canonical SIL, and LLVM IR under `Build/SIL`.
2. Applies the patches that remove the selected `strong_release` operations.
3. Compiles the original and modified SIL into separate executables.
4. Runs the strong, weak, and cycle experiments.
5. Reports maximum RSS for the repeated-allocation workload.

Capture the release-to-`deinit` call stack:

```bash
./Scripts/capture-release-stack.sh
```

Search the generated artifacts directly:

```bash
rg -n 'destroy_value|strong_release' Build/SIL/StrongReference.*.sil
rg -n 'load_weak|store_weak' Build/SIL/WeakReference.*.sil
rg -n 'swift_release|swift_weak' Build/SIL/*.ll
```

## Conclusion

The *Automatic* in Swift ARC does not mean that the runtime periodically walks the heap. It means developers do not manually write every retain and release: the compiler derives ownership operations from the program’s lifetime rules, and the runtime applies the resulting reference-count state transitions.

In these experiments:

- Source ownership became SIL destruction and release operations.
- Removing one `strong_release` removed `deinit` and caused measurable heap growth.
- LLDB connected the decrement slow path directly to the deallocating destructor.
- Weak properties lowered through dedicated weak-storage operations and side-table runtime calls.
- A strong cycle remained allocated because its reference counts never reached zero, even after the objects became unreachable.

That is the right mental model for Swift ARC: not periodic cleanup, but compiler-generated ownership operations driving runtime reference-count transitions.

## References

- [The Swift Programming Language — Automatic Reference Counting](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/)
- [Swift SIL specification](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/SIL.md)
- [Swift SIL instruction reference — `strong_release`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/docs/SIL/Instructions.md#strong_release)
- [Swift runtime — `HeapObject.cpp`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/runtime/HeapObject.cpp)
- [Swift runtime — `RefCount.h`](https://github.com/swiftlang/swift/blob/3db5a1ed8f80ec566c9e9191dc7371909e9880b0/stdlib/public/SwiftShims/swift/shims/RefCount.h)
- [Swift Forums — SIL strong_release behavior (2023)](https://forums.swift.org/t/sil-strong-release-behavior/66387)
- [Swift Forums — Questions about ARC (2016)](https://forums.swift.org/t/questions-about-arc/4621/7)
