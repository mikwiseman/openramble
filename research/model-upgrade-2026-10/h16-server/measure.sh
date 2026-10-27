#!/bin/bash
# Inside the container. `measure.sh build` compiles the server at both commits;
# `measure.sh run` measures them, file mode then `serve`, alternating which goes
# first. Sources in /src/<label>, model in /models, audio in /audio, results in /out.
set -euo pipefail
labels=(before after)
files=(en-3540s ru-3540s)

if [[ "${1:-}" == build ]]; then
  # wai-stt's own CPU (Ampere Altra, Neoverse-N1), not this host's: native
  # detection on an Apple M4 under Docker asks GCC 12 for fp16fml without fp16.
  export TRANSCRIBE_CMAKE_ARGS="-DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod"
  for label in "${labels[@]}"; do
    (cd "/src/$label" && CARGO_TARGET_DIR="/target/$label" cargo build --release --locked -p openramble-cli)
    install -D "/target/$label/release/openramble" "/out/bin/$label/openramble"
  done
  exit 0
fi

now() { date +%s.%N; }

file_mode() {  # label file
  local bin="/out/bin/$1/openramble" start
  start=$(now)
  "$bin" --workers 4 --model-dir /models --format json "/audio/$2.wav" > "/out/$1-$2.json" 2> "/out/$1-$2.log" &
  local pid=$!
  python3 /sample.py "$pid" "/out/$1-$2.memory.json"
  wait "$pid"
  echo "{\"wall_seconds\": $(printf %.3f "$(echo "$(now) - $start" | bc)")}" > "/out/$1-$2.time.json"
}

serve() {  # label
  local bin="/out/bin/$1/openramble" key start
  key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf 'bench %s\n' "$(printf %s "$key" | sha256sum | cut -d' ' -f1)" > /tmp/keys
  start=$(now)
  "$bin" serve --keys /tmp/keys --listen 127.0.0.1:8080 --engines 4 --model-dir /models 2> "/out/$1-serve.log" &
  local pid=$!
  until curl -fsS http://127.0.0.1:8080/health > /dev/null 2>&1; do sleep 0.2; done
  echo "{\"ready_seconds\": $(printf %.3f "$(echo "$(now) - $start" | bc)")}" > "/out/$1-serve.ready.json"
  python3 /sample.py "$pid" "/out/$1-serve.idle.json" --for 10
  python3 /sample.py "$pid" "/out/$1-serve.job.json" &
  local sampler=$!
  start=$(now)
  curl -fsS -H "xi-api-key: $key" -F file=@/audio/en-3540s.wav -F output_format=openramble \
    http://127.0.0.1:8080/v1/speech-to-text > "/out/$1-serve-en-3540s.json"
  echo "{\"wall_seconds\": $(printf %.3f "$(echo "$(now) - $start" | bc)")}" > "/out/$1-serve.time.json"
  kill -TERM "$pid"
  wait "$pid" || true
  wait "$sampler" || true
}

for index in "${!files[@]}"; do
  order=("${labels[@]}")
  (( index % 2 )) && order=(after before)
  for label in "${order[@]}"; do file_mode "$label" "${files[$index]}"; done
done
for label in after before; do serve "$label"; done
nproc > /out/nproc.txt
