#!/bin/bash
set -euo pipefail

readonly repository="FluidInference/sensevoice-small-coreml"
readonly revision="cdea3526163035c19915d4a10268992d018ebd46"
readonly required_bytes=600000000

if [[ "${OPENRAMBLE_SENSEVOICE_WEIGHT_DOWNLOAD_GO:-}" != "YES_EXACT_INT8_ONCE" ]]; then
  echo "refusing model download: set OPENRAMBLE_SENSEVOICE_WEIGHT_DOWNLOAD_GO=YES_EXACT_INT8_ONCE" >&2
  exit 64
fi
if [[ $# -ne 1 || "$1" != $TMP/openramble-sensevoice-model-* ]]; then
  echo "usage: $0 $TMP/openramble-sensevoice-model-<unique-id>" >&2
  exit 64
fi

readonly destination="$1"
if [[ -e "$destination" || -L "$destination" ]]; then
  echo "refusing existing destination: $destination" >&2
  exit 64
fi

readonly parent="${destination%/*}"
mkdir -p "$parent"
available_kib=$(df -Pk "$parent" | awk 'NR == 2 { print $4 }')
if [[ ! "$available_kib" =~ ^[0-9]+$ ]] || (( available_kib * 1024 < required_bytes )); then
  echo "insufficient or unreadable free-space measurement; need at least $required_bytes bytes" >&2
  exit 70
fi

stage=$(mktemp -d "$parent/.openramble-sensevoice-stage.XXXXXX")
cleanup() {
  if [[ -n "${stage:-}" && "$stage" == "$parent"/.openramble-sensevoice-stage.* && -d "$stage" ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT INT TERM

artifacts=(
  "SenseVoicePreprocessor.mlmodelc/analytics/coremldata.bin|243|5bdb0b132e48c7e852ec18eeba7e217b6cb7153e6a939ce76b5ed17242e956dd"
  "SenseVoicePreprocessor.mlmodelc/coremldata.bin|330|e64cc73b2a9b01bad799a23874bc20dba3cf3342c23e3f60012c3e884f682944"
  "SenseVoicePreprocessor.mlmodelc/model.mil|15008|1b9b18be0a35b11165269b1ca071a30af736deb314d8bd82d9540c769137a70e"
  "SenseVoicePreprocessor.mlmodelc/weights/weight.bin|3037504|69c630a115da5e4db36ec41662f0b776c0ef33ec6776d86f8cdaaba022518396"
  "SenseVoiceSmall_int8.mlmodelc/analytics/coremldata.bin|243|ab5e9ee0d49e1f88838f1c2178cbe58a20dac12b50c4da803a75a54c6229845a"
  "SenseVoiceSmall_int8.mlmodelc/coremldata.bin|436|55ef1c194e641418817d7d07f6bfbd8032571e800b81264caba37eb63a95335b"
  "SenseVoiceSmall_int8.mlmodelc/model.mil|1134696|015fe7242a15eeb2fc0ca7f908ca3a09a5826b36e7d7f704803c8bbe60c1a148"
  "SenseVoiceSmall_int8.mlmodelc/weights/weight.bin|235373118|dab122c65d5043cba5b47561d5c1d3a049dd123c662e802d9dbce8fdd0505a38"
  "vocab.json|352064|a2594fc1474e78973149cba8cd1f603ebed8c39c7decb470631f66e70ce58e97"
)

observed_total=0
for record in "${artifacts[@]}"; do
  IFS='|' read -r relative_path expected_size expected_sha <<< "$record"
  output="$stage/$relative_path"
  mkdir -p "${output%/*}"
  url="https://huggingface.co/$repository/resolve/$revision/$relative_path"
  /usr/bin/curl --disable --fail --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-all-errors --connect-timeout 20 --output "$output" "$url"
  observed_size=$(stat -f '%z' "$output")
  observed_sha=$(shasum -a 256 "$output" | awk '{ print $1 }')
  if [[ "$observed_size" != "$expected_size" || "$observed_sha" != "$expected_sha" ]]; then
    echo "artifact identity mismatch: $relative_path" >&2
    exit 74
  fi
  observed_total=$((observed_total + observed_size))
done

if (( observed_total != 239913642 )); then
  echo "artifact total mismatch: $observed_total" >&2
  exit 74
fi

chmod -R go-w "$stage"
mv -- "$stage" "$destination"
stage=""
echo "verified exact int8 artifacts installed at $destination ($observed_total bytes)" >&2
