# LLM Speed Experiments

Date: 2026-05-22

| Experiment | Result | Decision |
|---|---:|---|
| Bonsai default MLX eval | ~8-10 tok/s | Too slow |
| `--cache-size 4096 --memory-size 4096` | 34-36 tok/s best runs | Kept |
| KV cache quantization (`--kv-bits 4/8`) | No improvement | Rejected |
| Reset `llm-tool chat` before each command | Spanish test ~2.03s; prevents history growth | Kept |
| Compact system prompt | TTFT avg 0.89s -> 0.48s in persistent chat | Kept |
| Debug-only prompt logging | Removes hot-path terminal output | Kept |
| Prompt labels `Task`/`Information` vs `Do`/`Text` | TTFT 0.492s -> 0.467s; TPS 27.06 -> 28.38 | Kept `Do`/`Text` |
| Extra memory/cache sweep | No reliable improvement over 4096/4096 | Rejected |
| Reset before request vs reset after response vs no reset | Visible wall ~0.73s in all cases | Rejected; no meaningful win |
| MLX Python one-shot CLI | Spanish 33.9 tok/s; long 28.9 tok/s | Rejected; not >20% vs Swift |
| MLX Python persistent raw worker | TTFT 0.41s but wrong Spanish output | Rejected; quality broken |
| MLX Python persistent chat-template worker | Spanish TTFT 3.85s, 5.83 tok/s; long 6.51 tok/s | Rejected; much slower |
| MLX Python KV/cache/activation options | KV slower; max-kv slower; activation quantization unsupported | Rejected |
| MLX Python prompt cache | Failed with current CLI cache-file handling | Rejected |

Latest full-suite speed check: 29.14 tok/s. Latest exact Spanish command: 1.63s.

Current guardrail: `tests/local_llm_speed_case.py` requires at least 20 tok/s.

Conclusion: under Bonsai-only and current MLX Swift/Python runtimes, no tested architecture produced a reliable >20% improvement over the current warmed Swift `llm-tool chat` path. Big next steps require either a different inference runtime, native in-process MLX Swift integration, speculative decoding with a compatible draft model, or a smaller/faster model.
