#!/usr/bin/env bash
# Run the full llama-bar test suite: config, discovery, start.sh, model logic.
# Exits nonzero on the first failing test.
set -euo pipefail
cd "$(dirname "$0")"

echo "── tests/test_config.py ──"
python3 tests/test_config.py

echo "── tests/test_discovery.py ──"
python3 tests/test_discovery.py

echo "── tests/test_start.py ──"
python3 tests/test_start.py

echo "── tests/test_model_logic.swift ──"
swiftc -o /tmp/llamabar-test-model-logic tests/test_model_logic.swift LlamaBar/ModelLogic.swift
/tmp/llamabar-test-model-logic

echo "✅ All tests passed"
