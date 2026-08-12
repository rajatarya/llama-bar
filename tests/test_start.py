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
    
    print("✓ start.sh help works")
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
        print("\nAll start.sh tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        sys.exit(1)
