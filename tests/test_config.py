#!/usr/bin/env python3
"""Test config parsing and model discovery."""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def test_config_load():
    """Test that models.json loads correctly."""
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        cfg = json.load(f)
    
    assert 'default_model' in cfg, "Missing default_model"
    assert 'models' in cfg, "Missing models"
    assert cfg['default_model'] in cfg['models'], "Default model not in models"
    
    model = cfg['models'][cfg['default_model']]
    assert 'name' in model, "Missing name"
    assert 'ctx_size' in model, "Missing ctx_size"
    assert 'ngl' in model, "Missing ngl"
    
    print("✓ Config loads correctly")
    return True

def test_config_schema():
    """Test config schema validation."""
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        cfg = json.load(f)
    
    required_fields = ['name', 'ctx_size', 'ngl', 'batch_size', 'ubatch_size']
    for model_id, model in cfg['models'].items():
        for field in required_fields:
            assert field in model, f"Model {model_id} missing {field}"
    
    print("✓ Config schema valid")
    return True

if __name__ == '__main__':
    try:
        test_config_load()
        test_config_schema()
        print("\nAll config tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        sys.exit(1)
