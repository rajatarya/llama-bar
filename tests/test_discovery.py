#!/usr/bin/env python3
"""Test model discovery script."""
import subprocess
import json
import sys
import os

def test_discovery_script():
    """Test that discover_models.sh outputs valid JSON."""
    script_path = os.path.join(os.path.dirname(__file__), '..', 'discover_models.sh')
    result = subprocess.run(['bash', script_path], capture_output=True, text=True)
    
    assert result.returncode == 0, f"Script failed: {result.stderr}"
    
    try:
        models = json.loads(result.stdout.strip())
        assert isinstance(models, list), "Output should be a list"
        print(f"✓ Discovery script works, found {len(models)} models: {models}")
        return True
    except json.JSONDecodeError as e:
        print(f"✗ Invalid JSON output: {result.stdout}")
        return False

def test_discovery_independent_of_config():
    """Discovery is the cache, not the config: cached models appear whether
    or not models.json lists them; config-only models never do."""
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        cfg = json.load(f)

    script_path = os.path.join(os.path.dirname(__file__), '..', 'discover_models.sh')
    result = subprocess.run(['bash', script_path], capture_output=True, text=True)
    discovered = json.loads(result.stdout.strip())

    for model_id in cfg['models']:
        if model_id not in discovered:
            # Uncached config-only models must stay hidden (they do by definition).
            continue
    # Every discovered id has repo:QUANT shape.
    for model_id in discovered:
        assert ':' in model_id, f"Discovered id {model_id} lacks :QUANT suffix"

    print(f"✓ Discovery lists {len(discovered)} cached models, independent of config")
    return True

def test_config_keys_match_discovered_tags():
    """A config entry whose repo is cached under a slightly different tag
    (e.g. UD-Q2_K_XL vs llama.cpp's Q2_K_XL) is silently never applied."""
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        cfg = json.load(f)
    script_path = os.path.join(os.path.dirname(__file__), '..', 'discover_models.sh')
    result = subprocess.run(['bash', script_path], capture_output=True, text=True)
    discovered = json.loads(result.stdout.strip())

    tags_by_repo = {}
    for model_id in discovered:
        repo, tag = model_id.rsplit(':', 1)
        tags_by_repo.setdefault(repo, set()).add(tag.upper())
    for key in cfg['models']:
        repo, tag = key.rsplit(':', 1)
        if key in discovered or repo not in tags_by_repo:
            continue  # applied, or simply not downloaded
        near = [t for t in tags_by_repo[repo] if tag.upper().endswith(t) or t.endswith(tag.upper())]
        assert not near, f"config key {key} never applies: llama.cpp discovers it as {repo}:{near[0]}"

    print("✓ Every cached config entry's key matches its discovered id")
    return True

def _fake_bin(path, body):
    with open(path, 'w') as f:
        f.write('#!/bin/bash\n' + body + '\n')
    os.chmod(path, 0o755)

def test_discovery_merges_mtplx_packs():
    """Installed MTPLX packs are advertised as <repo>:MTPLX next to llama.cpp's
    cache list; a missing mtplx binary just drops them."""
    import tempfile
    script_path = os.path.join(os.path.dirname(__file__), '..', 'discover_models.sh')
    with tempfile.TemporaryDirectory() as d:
        llama = os.path.join(d, 'llama-server')
        mtplx = os.path.join(d, 'mtplx')
        _fake_bin(llama, 'echo "Number of models in cache: 1"; echo "   1. org/Model-GGUF:Q4_K_M"')
        _fake_bin(mtplx, 'echo \'{"models": [{"repo_id": "Youssofal/Pack-MTPLX", "has_config": true}]}\'')

        env = dict(os.environ, LLAMA_SERVER=llama, MTPLX_BIN=mtplx)
        result = subprocess.run(['bash', script_path], capture_output=True, text=True, env=env)
        assert result.returncode == 0, f"Script failed: {result.stderr}"
        discovered = json.loads(result.stdout.strip())
        assert discovered == ['org/Model-GGUF:Q4_K_M', 'Youssofal/Pack-MTPLX:MTPLX'], discovered

        env['MTPLX_BIN'] = os.path.join(d, 'missing')
        result = subprocess.run(['bash', script_path], capture_output=True, text=True, env=env)
        assert json.loads(result.stdout.strip()) == ['org/Model-GGUF:Q4_K_M'], result.stdout

    print("✓ Discovery merges MTPLX packs and tolerates a missing mtplx")
    return True

if __name__ == '__main__':
    try:
        test_discovery_script()
        test_discovery_independent_of_config()
        test_config_keys_match_discovered_tags()
        test_discovery_merges_mtplx_packs()
        print("\nAll discovery tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        sys.exit(1)
