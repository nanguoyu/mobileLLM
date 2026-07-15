// SPDX-License-Identifier: MIT

import Foundation
import LLMEngineMLX

// Fork acceptance gate. If bits=1 quantizedMatmul runs and matches the reference, the PrismML
// 1-bit fork is correctly wired into this build — the whole point of the fork.
print(ForkLink.factoryReady())

let r = BitsOneCheck.run()
print("bits=1 kernel: \(r.detail)")
if r.passed {
    print("✅ PASS — PrismML fork's quantizedMatmul(bits:1) runs and matches dequantize·matmul.")
} else {
    print("❌ FAIL — bits=1 kernel produced wrong/degenerate output.")
    exit(1)
}
