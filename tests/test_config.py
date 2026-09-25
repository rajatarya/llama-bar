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
    
    print("✓ Config loads correctly")
    return True

def test_config_schema():
    """Config entries are tuning overrides; only name is required."""
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        cfg = json.load(f)

    for model_id, model in cfg['models'].items():
        assert 'name' in model, f"Model {model_id} missing name"
        # Tuning fields must be presentable values when provided.
        for field in ('ctx_size', 'ngl', 'batch_size', 'ubatch_size'):
            if field in model:
                assert isinstance(model[field], int) and model[field] > 0, \
                    f"Model {model_id} has invalid {field}"
        # backend picks the server start.sh launches; MTPLX packs use the :MTPLX tag.
        backend = model.get('backend', 'llamacpp')
        assert backend in ('llamacpp', 'mtplx'), f"Model {model_id} has unknown backend {backend}"
        assert (backend == 'mtplx') == model_id.endswith(':MTPLX'), \
            f"Model {model_id}: backend {backend} must match the :MTPLX id tag"

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
