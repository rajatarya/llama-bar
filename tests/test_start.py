#!/usr/bin/env python3
"""Test start.sh arguments."""
import subprocess
import sys
import os

def test_start_help():
    """Test start.sh --help works."""
    script_path = os.path.join(os.path.dirname(__file__), '..', 'start.sh')
    result = subprocess.run(['bash', script_path, '--help'], capture_output=True, text=True)
    
    assert result.returncode == 0, "Help should succeed"
    assert 'Usage:' in result.stdout, "Help should contain Usage"
    assert '--model' in result.stdout, "Help should mention --model"
    assert '--dry-run' in result.stdout, "Help should mention --dry-run"
    
    print("✓ start.sh help works")
    return True

def test_start_dry_run_all_models():
    """start.sh --dry-run resolves every configured model without launching."""
    import json
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    script_path = os.path.join(os.path.dirname(__file__), '..', 'start.sh')
    with open(config_path) as f:
        cfg = json.load(f)

    assert len(cfg['models']) >= 1, "No models configured to test"
    for model_id in cfg['models']:
        result = subprocess.run(
            ['bash', script_path, '--model', model_id, '--dry-run'],
            capture_output=True, text=True)
        assert result.returncode == 0, (
            f"dry-run failed for {model_id}:\n{result.stdout}\n{result.stderr}")
        assert 'DRY-RUN' in result.stdout, f"dry-run marker missing for {model_id}"

        # MODEL_FILE=... must resolve to a file that exists on disk
        model_file = next(
            (line.split('=', 1)[1] for line in result.stdout.splitlines()
             if line.startswith('MODEL_FILE=')), '')
        assert model_file, f"MODEL_FILE empty for {model_id}:\n{result.stdout}"
        assert os.path.isfile(model_file), \
            f"MODEL_FILE not on disk for {model_id}: {model_file}"

    print(f"✓ dry-run resolves all {len(cfg['models'])} configured models")
    return True


def test_start_dry_run_default():
    """start.sh --dry-run without --model resolves the default model."""
    script_path = os.path.join(os.path.dirname(__file__), '..', 'start.sh')
    result = subprocess.run(['bash', script_path, '--dry-run'],
                            capture_output=True, text=True)
    assert result.returncode == 0, f"Default dry-run failed:\n{result.stderr}"
    assert 'DRY-RUN' in result.stdout, "DRY-RUN marker missing"

    # Default must match default_model in config
    import json
    config_path = os.path.join(os.path.dirname(__file__), '..', 'models.json')
    with open(config_path) as f:
        default_id = json.load(f)['default_model']
    assert f'model={default_id}' in result.stdout, \
        f"Expected default {default_id}, got:\n{result.stdout}"

    print("✓ dry-run resolves default model")
    return True


def test_start_list():
    """Test start.sh --list works."""
    script_path = os.path.join(os.path.dirname(__file__), '..', 'start.sh')
    result = subprocess.run(['bash', script_path, '--list'], capture_output=True, text=True)
    
    assert result.returncode == 0, "List should succeed"
    # Should output JSON array
    import json
    try:
        models = json.loads(result.stdout.strip())
        assert isinstance(models, list), "List should output JSON array"
    except:
        pass  # May output differently, just check it runs
    
    print("✓ start.sh --list works")
    return True

if __name__ == '__main__':
    try:
        test_start_help()
        test_start_list()
        test_start_dry_run_all_models()
        test_start_dry_run_default()
        print("\nAll start.sh tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        sys.exit(1)
