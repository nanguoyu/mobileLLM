# mobileLLM

On-device LLM chat for **macOS + iOS**. Pure MLX + Swift. Runs Prism ML's **Bonsai** (1-bit)
models fully on device — no account, no cloud, nothing leaves the device.

Sibling to [MobileDiffuser](../MobileDiffuser) (the image app); reuses its download subsystem,
design system, and memory/thermal governors, but lives in its own project so it can use the
**PrismML `mlx-swift` fork** (1-bit Metal kernels) without touching MobileDiffuser's validated
upstream diffusion stack.

- **iPhone hero:** Bonsai-8B 1-bit (1.28 GB, fits 8 GB devices comfortably).
- **Mac / 12 GB iPhone flagship:** Bonsai-27B 1-bit (5.13 GB, Qwen3.5 Gated-DeltaNet, thinking mode).

📄 **[docs/DESIGN.md](docs/DESIGN.md)** — architecture, model catalog, product/UX, roadmap, risks.

Status: design phase. Build starts with the fork pin + a `bits=1` smoke-decode gate, then an
8B-1bit MVP (chat · streaming · thinking disclosure · model manager). Device testing last.
