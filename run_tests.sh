#!/usr/bin/env bash
# Run the full llama-bar test suite: config, discovery, start.sh, proxy, model logic.
# Exits nonzero on the first failing test.
set -euo pipefail
cd "$(dirname "$0")"

echo "── tests/test_config.py ──"
python3 tests/test_config.py

echo "── tests/test_discovery.py ──"
python3 tests/test_discovery.py

echo "── tests/test_start.py ──"
python3 tests/test_start.py

echo "── tests/test_proxy.py ──"
python3 -B tests/test_proxy.py

echo "── tests/test_model_logic.swift ──"
swiftc -o /tmp/llamabar-test-model-logic tests/test_model_logic.swift LlamaBar/ModelLogic.swift LlamaBar/Shell.swift
/tmp/llamabar-test-model-logic

# The app itself has no unit tests; type-checking it catches a broken main.swift
# before build.sh does (that is how the menu bar app last went missing).
echo "── LlamaBar app type-check ──"
swiftc -typecheck LlamaBar/main.swift LlamaBar/ModelLogic.swift LlamaBar/Shell.swift
echo "  ✓ main.swift + ModelLogic.swift + Shell.swift type-check"

echo "✅ All tests passed"
