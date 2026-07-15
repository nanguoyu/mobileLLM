// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import MLX
import MLXRandom

/// The fork acceptance gate at the kernel level: exercises the PrismML `bits=1` affine Metal kernel.
/// Quantizes a matrix to 1-bit, runs `quantizedMatmul` (the decode-time op), and compares it against
/// dequantize-then-matmul. Upstream MLX only supports bits ∈ {2,3,4,5,6,8}, so this op existing and
/// being correct *is* the proof the fork is wired in. (Bonsai weights are 1-bit affine, group 128.)
public enum BitsOneCheck {
    public struct Result: Sendable {
        public let passed: Bool
        public let detail: String
    }

    public static func run(outDim: Int = 256, inDim: Int = 512, groupSize: Int = 128) -> Result {
        MLXRandom.seed(0)
        let w = MLXRandom.normal([outDim, inDim])   // fp32 "weights"
        let x = MLXRandom.normal([1, inDim])        // one token's activation (batch 1 — decode)

        // bits: 1 → the fork kernel. On stock MLX this call would assert.
        let (wq, scales, biases) = quantized(w, groupSize: groupSize, bits: 1, mode: .affine)
        let y = quantizedMatmul(x, wq, scales: scales, biases: biases,
                                transpose: true, groupSize: groupSize, bits: 1, mode: .affine)
        let wDeq = dequantized(wq, scales: scales, biases: biases,
                               groupSize: groupSize, bits: 1, mode: .affine, dtype: .float32)
        let yRef = matmul(x, wDeq.T)
        MLX.eval(y, yRef)   // MLX lazy-array materialization (not code eval)

        let a = y.asArray(Float.self)
        let b = yRef.asArray(Float.self)
        let finite = a.allSatisfy(\.isFinite)
        let maxDiff = zip(a, b).map { Swift.abs($0 - $1) }.max() ?? .infinity
        let distinct = Set(a.map { ($0 * 100).rounded() }).count   // guard against a degenerate all-equal result
        let passed = finite && a.count == outDim && maxDiff < 1e-2 && distinct > 4
        let detail = "shape=\(y.shape) finite=\(finite) "
            + "maxDiff(qmm vs dequant·matmul)=\(String(format: "%.2e", maxDiff)) distinct=\(distinct)/\(outDim)"
        return Result(passed: passed, detail: detail)
    }
}
