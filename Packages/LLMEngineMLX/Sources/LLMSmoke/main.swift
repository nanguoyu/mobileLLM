// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
