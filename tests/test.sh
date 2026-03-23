#!/bin/bash
# Build engine if needed
if [ ! -f "../bin/evolution-engine" ]; then
    echo "Rebuilding engine..."
    cd .. && dub build -b release && cd tests
fi

# Download rules
echo "Downloading latest rules..."
RULES_URL="https://github.com/AMDphreak/evolution-rules-code/archive/refs/tags/latest.zip"
ZIP_PATH="latest.zip"
EXTRACT_PATH="rules_code"

rm -rf "$EXTRACT_PATH"
curl -L -s -o "$ZIP_PATH" "$RULES_URL"
unzip -q "$ZIP_PATH" -d "$EXTRACT_PATH"
rm "$ZIP_PATH"

RULES_DIR=$(find "$EXTRACT_PATH" -maxdepth 1 -type d -name "evolution-rules-code*")/rules/qt

# Run test
echo "Running evolution-engine test..."
../bin/evolution-engine --path . --rules-dir "$RULES_DIR" --from 5.15 --to 6.0
