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

def test_discovery_matches_config():
    """Test that discovered models are in config."""
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        cfg = json.load(f)
    
    script_path = os.path.join(os.path.dirname(__file__), '..', 'discover_models.sh')
    result = subprocess.run(['bash', script_path], capture_output=True, text=True)
    discovered = json.loads(result.stdout.strip())
    
    for model_id in discovered:
        assert model_id in cfg['models'], f"Discovered model {model_id} not in config"
    
    print("✓ All discovered models are in config")
    return True

if __name__ == '__main__':
    try:
        test_discovery_script()
        test_discovery_matches_config()
        print("\nAll discovery tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        sys.exit(1)
