// What `AsyncMutexPerformanceTests`' actor cases do, with XCTest and the
// package taken away: detached tasks take turns on one actor, yielding after
// each turn, while the main thread waits for them on a semaphore.
//
// On Linux arm64 a libdispatch worker dies about once in a hundred of these:
//
//     *** Program crashed: Bad pointer dereference at 0xffffffff89abcdff ***
//       0  _dispatch_worker_thread + 540 in libdispatch.so
//
// which is DISPATCH_OBJECT_LISTLESS + 0x10: the root queue's head is an item
// marked as being on no list.

import Dispatch

actor Box {
    private let cycle = (0 ..< 1024).map { ($0 &* 5 &+ 1) % 1024 }
    private var writes = 0

    func step(from index: Int) -> Int {
        writes &+= 1
        return cycle[index]
    }

    var count: Int {
        writes
    }
}

func sample(tasks: Int, iterations: Int) {
    let box = Box()
    let finished = DispatchSemaphore(value: 0)

    for task in 0 ..< tasks {
        Task.detached(priority: .userInitiated) {
            var index = task
            for _ in 0 ..< iterations {
                index = await box.step(from: index)
                await Task.yield()
            }
            finished.signal()
        }
    }
    for _ in 0 ..< tasks {
        finished.wait()
    }

    let checked = DispatchSemaphore(value: 0)
    Task.detached {
        let writes = await box.count
        precondition(writes == tasks * iterations, "the workload did not run")
        checked.signal()
    }
    checked.wait()
}

// The four cases, ten samples of each, as the measurements take them.
for (tasks, iterations) in [(64, 2_000), (8, 10_000), (1, 100_000), (512, 250)] {
    for _ in 0 ..< 10 {
        sample(tasks: tasks, iterations: iterations)
    }
}
