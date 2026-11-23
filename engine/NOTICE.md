# Notices

The engine is original code, written for the Parakeet models. It computes what
two MIT-licensed projects compute, and follows their code closely in the places
listed here so that it gives the same answers.

- **transcribe.cpp**, Copyright (c) 2026 The transcribe.cpp authors, MIT.
  The mel front end (`src/ore_mel.c`), the order of operations of the
  FastConformer encoder (`src/ore_encoder.c`), the greedy TDT decoding loop,
  the SentencePiece encoding of a term and the phrase-boost automaton
  (`src/ore_decoder.c`) follow its `transcribe-mel.cpp`, `conformer.cpp`,
  `arch/parakeet/*.cpp`, `transcribe-tokenizer.cpp` and
  `transcribe-phrase-boost.cpp`.
- **ggml**, Copyright (c) 2023-2026 The ggml authors, MIT. The Q4_K and Q8_0
  weight formats, the quantization of activations (`quantize_row_q8_K`,
  `quantize_row_q8_0`) and the order in which a Q4_K dot product is summed
  (`ggml_vec_dot_q4_K_q8_K`) are ggml's, reproduced in `src/ore_kernels_*.c`
  so that a product gives the same bits. The single-precision `exp`
  (`ore_expf` and the vector forms) is ggml's `ggml_v_expf`, which follows
  Arm's Optimized Routines (MIT).

Both licences read:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The Parakeet model weights are not part of this library. They are NVIDIA's and
Moondream's, under CC BY 4.0.
