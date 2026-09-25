#!/usr/bin/env python3
"""Test the proxy's loaded-model matching for both backends."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import proxy  # noqa: E402  (import-safe: the server only starts under __main__)


def test_matches_loaded_mtplx():
    """mtplx serve reports its pack directory on /health."""
    fn = "Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed:MTPLX"
    q27 = "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Quality:MTPLX"
    path = "/Users/x/.mtplx/models/Youssofal--Qwen3.8-Flash-Next-MTPLX-Optimized-Speed"
    assert proxy._matches_loaded(fn, path)
    assert proxy._matches_loaded(fn, path + "/"), "trailing slash"
    assert not proxy._matches_loaded(q27, path), "other MTPLX pack must not match"
    assert not proxy._matches_loaded(fn, ""), "no server → no match"
    print("✓ MTPLX pack directories match their :MTPLX id only")


def test_matches_loaded_gguf_unchanged():
    """GGUF snapshot matching still keys on owner, repo and quant."""
    path = ("/Users/x/.cache/huggingface/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/"
            "snapshots/abc/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf")
    assert proxy._matches_loaded("unsloth/Qwen3.8-Flash-Next-GGUF:IQ4_XS", path)
    assert not proxy._matches_loaded("unsloth/Qwen3.8-Flash-Next-GGUF:Q4_K_XL", path)
    assert not proxy._matches_loaded("Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed:MTPLX", path)
    print("✓ GGUF matching unchanged; GGUF paths never match MTPLX ids")


if __name__ == '__main__':
    try:
        test_matches_loaded_mtplx()
        test_matches_loaded_gguf_unchanged()
        print("\nAll proxy tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        sys.exit(1)
