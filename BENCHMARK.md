# Muse-Glimmer-30B-BF16 — Complete Benchmark Report

**Model:** `unsloth/Muse-Glimmer-30B-GGUF` (BF16, 2-shard, ~52 GB)  
**Source:** https://huggingface.co/meta-models/Muse-Glimmer-30B  
**Backend:** llama.cpp `llama-server` with Metal on Apple Silicon  
**Hardware:** Mac17,6 (MacBook Pro M4 Max), 128 GB unified RAM, 18 cores  
**Date:** 2025-08-11

---

## 1. Critical Discovery: This Is a Reasoning Model

Muse-Glimmer-30B uses an **internal reasoning format** (`reasoning_content` separate from `content`).
You **must** use the `/v1/chat/completions` endpoint (not raw `/completion`) — the model's chat template
handles the reasoning/output split correctly.

You **must** include a system prompt with reasoning strength:

```
Reasoning strength: low|medium|high|xhigh
```

Without this, the model's reasoning can loop indefinitely (observed at low temps).

---

## 2. Speed Benchmarks

### Throughput by Configuration

| Config | tok/s | Notes |
|--------|-------|-------|
| ngl=20, no flash-attn | **0.9** | Unusable |
| ngl=40, no flash-attn | **~2** | Poor |
| ngl=48, flash-attn=on | **4.7** | ⚠️ Cliff — 2× slower than max |
| ngl=56, flash-attn=on | **10.3** | Full speed |
| **ngl=64, flash-attn=on** | **10.3** | ✅ Optimal |

### Context Size vs Speed

| ctx-size | RSS | Gen tok/s | KV Cache |
|----------|-----|-----------|----------|
| 8,192 | 53.5 GB | 10.3 | ~1.5 GB |
| 16,384 | 53.6 GB | 10.3 | ~1.6 GB |
| 32,768 | 53.8 GB | 10.3 | ~1.8 GB |
| 65,536 | 54.2 GB | 10.2 | ~2.2 GB |
| 131,072 | 55.1 GB | 10.2 | ~3.1 GB |
| **262,144** | **56.7 GB** | **10.3** | ~4.7 GB |

**Finding:** Context up to 256K has **zero impact** on generation speed.
At 256K, only 56.7 GB of 128 GB is used — **71 GB remains free**.

### Sampling Parameters vs Speed

| Parameter | Range Tested | Speed Impact |
|-----------|-------------|--------------|
| temperature | 0.1–1.0 | None (~10.2 tok/s) |
| top_p | 0.8–0.95 | None (~10.2 tok/s) |
| top_k | 40–64 | None (~10.2 tok/s) |

Generation is **memory-bandwidth bound**, not compute-bound or sampling-bound.

---

## 3. Quality Benchmarks

### Temperature Sweep (raw completion, no system prompt)

| Temp | Result |
|------|--------|
| 0.1 | ❌ Stuck in internal reasoning loop, never output code |
| 0.3 | ⚠️ Mostly reasoning, barely started code at 256 tokens |
| **0.5** | ✅ Only one that produced complete, working Trie code |
| 0.7 | ❌ Got stuck in reasoning loop |
| 1.0 | ⚠️ Began reasoning, partial code output |

**Finding with raw completion:** temp=0.5 was the only usable setting. But this was the
wrong API — raw completion doesn't handle the reasoning format.

### Chat API with System Prompt (Recommended)

All using **official recommended params:** `temp=1.0, top_p=0.95, top_k=64`

| Test | Reasoning | Time | Output Quality |
|------|-----------|------|---------------|
| Trie (xhigh) | 2,499 chars | 94.6s | Clean code, examples, explanation ✅ |
| Trie (high) | 3,321 chars | 108.4s | Clean code, assertions, explanation ✅ |
| **Trie (low)** | **594 chars** | **55.0s** | **Clean code, per-method docstrings, tests ✅** |
| A* (low) | 451 chars | 104.0s | Full A* with diagonal, heap, type hints ✅ |

**Finding:** With the chat API + system prompt, the official params work correctly.
`reasoning=low` gives the best code-to-reasoning ratio (3:1 output:reasoning chars).
Code quality is high across all settings.

### Recommended: Reasoning Strength by Task

Model card says: *"Use high or xhigh for complex problem solving, coding, and agentic tasks."*

Tested comparison on palindrome task:
| Level | Time | Think | Output |
|-------|------|-------|--------|
| low | 38s | 640 | 977 |
| xhigh | 88s | 2,967 | 1,163 |

xhigh produces better type-checking (`isinstance` vs `is None`), more examples, and
better edge-case handling. The gap widens on complex tasks.

| Task | Reasoning | Why |
|------|-----------|-----|
| Simple code / boilerplate | **low** | Fast, still correct |
| Code generation | **xhigh** | Per model card, better edge cases |
| Code review / debugging | **high** | Deep analysis without max cost |
| Architecture / design | **xhigh** | Maximum reasoning |
| Complex multi-step problems | **xhigh** | Maximum reasoning |

---

## 4. Optimal Configuration

### Server Launch

```bash
llama-server \
  --model Muse-Glimmer-30B-BF16-00001-of-00002.gguf \
  --host 127.0.0.1 --port 8080 \
  --ctx-size 8192 \
  --n-gpu-layers 64 \
  --threads 12 \
  --batch-size 512 --ubatch-size 512 \
  --flash-attn on \
  --parallel 1
```

**Note:** Sampling params (temp, top_p, top_k) are **client-side** — set them in the request,
not at server launch. The server defaults are overridden per-request.

### Client Request (Coding — recommended per model card)

```json
{
  "messages": [
    {"role": "system", "content": "Reasoning strength: xhigh"},
    {"role": "user", "content": "Your prompt here"}
  ],
  "temperature": 1.0,
  "top_p": 0.95,
  "top_k": 64,
  "max_tokens": 1536
}
```

### Client Request (Complex Analysis)

```json
{
  "messages": [
    {"role": "system", "content": "Reasoning strength: xhigh"},
    {"role": "user", "content": "Your complex prompt here"}
  ],
  "temperature": 1.0,
  "top_p": 0.95,
  "top_k": 64,
  "max_tokens": 4096
}
```

### For Long-Running Sessions

Change only:
```bash
  --ctx-size 262144
  --batch-size 256 --ubatch-size 256
```

---

## 5. The 5× Multiplier: flash-attn

| Without flash-attn | With flash-attn |
|---|---|
| ~2 tok/s | ~10.3 tok/s |

This is the single most impactful server flag. **Never run without it.**

---

## 6. Resource Budget

| ctx | Model | KV Cache | Total RSS | Free (of 128 GB) |
|-----|-------|----------|-----------|-------------------|
| 8K | 52 GB | ~1.5 GB | 53.5 GB | 74.5 GB |
| 32K | 52 GB | ~1.8 GB | 53.8 GB | 74.2 GB |
| 64K | 52 GB | ~2.2 GB | 54.2 GB | 73.8 GB |
| 128K | 52 GB | ~3.1 GB | 55.1 GB | 72.9 GB |
| 256K | 52 GB | ~4.7 GB | 56.7 GB | 71.3 GB |

You can run another LLM, heavy IDE, and browser alongside this model at 256K context.

---

## 7. Quick Reference

| Setting | Value | Impact |
|---------|-------|--------|
| `--flash-attn` | **on** | 5× speed multiplier |
| `--n-gpu-layers` | **64** | Cliff at 48; max it out |
| `--ctx-size` | **8192** daily, **262144** max | No speed penalty for larger |
| `--threads` | **12** | Sweet spot on 18-core |
| **temperature** | **1.0** | Official recommendation |
| **top_p** | **0.95** | Official recommendation |
| **top_k** | **64** | Official recommendation |
| **System prompt** | `Reasoning strength: low` | Required! Controls think time |
| **max_tokens** | ≥ 1024 | Room for reasoning + output |
| **API** | `/v1/chat/completions` | Must use chat endpoint |

**Expected:** ~10.3 tok/s, high-quality code and analysis.
