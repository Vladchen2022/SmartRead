#!/bin/bash
set -euo pipefail

runtime="$HOME/Library/Application Support/SmartRead/Kokoro"
release="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
mkdir -p "$runtime"

if [[ ! -x "$runtime/env/bin/python" ]]; then
    uv venv --python 3.12 "$runtime/env"
fi
uv pip install --python "$runtime/env/bin/python" 'kokoro-onnx==0.6.1'

for asset in kokoro-v1.0.int8.onnx voices-v1.0.bin; do
    if [[ ! -s "$runtime/$asset" ]]; then
        curl --fail --location --retry 2 --output "$runtime/$asset.download" "$release/$asset"
        mv "$runtime/$asset.download" "$runtime/$asset"
    fi
done
