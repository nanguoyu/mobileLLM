// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import LLMEngineMLX

// Fork-compile gate: if this builds, runs, and prints, the 1-bit fork resolved and linked.
// The bits=1 decode-with-weights smoke test extends this next.
print(ForkLink.factoryReady())
