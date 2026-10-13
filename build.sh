#!/usr/bin/env bash
set -euo pipefail
bam_example_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bam_root=${BAM_ROOT:-/root/bam-setup/bam}
bam_build=${BAM_BUILD:-$bam_root/build-a100-gcc12}
bam_cuda=${CUDA_ROOT:-/opt/bam/cuda-12.8}
bam_cxx=${BAM_CXX:-/usr/bin/g++-12}

test -f "$bam_root/include/page_cache.h"
test -f "$bam_root/include/freestanding/include/simt/atomic"
test -x "$bam_cuda/bin/nvcc"
test -x "$bam_cxx"
python3 "$bam_example_dir/prepare_header.py" \
  "$bam_root/include/page_cache.h" "$bam_example_dir/.bam-include/page_cache.h"

bam_flags=(-ccbin "$bam_cxx" -std=c++11 -O3 -lineinfo -arch=sm_80
  -D__CUDA__ -Xcompiler=-faligned-new
  -I"$bam_example_dir/.bam-include" -I"$bam_build/include"
  -I"$bam_root/include" -I"$bam_root/include/freestanding/include")
if [[ ${1:-} == --compile-only ]]; then
  "$bam_cuda/bin/nvcc" "${bam_flags[@]}" -c "$bam_example_dir/vector_add_bam.cu" \
    -o "$bam_example_dir/vector_add_bam.o"
else
  test -f "$bam_build/lib/libnvm.so"
  "$bam_cuda/bin/nvcc" "${bam_flags[@]}" "$bam_example_dir/vector_add_bam.cu" \
    -L"$bam_build/lib" -lnvm -lcuda -Xcompiler=-pthread \
    -Xlinker -rpath -Xlinker "$bam_build/lib" \
    -o "$bam_example_dir/vector_add_bam"
fi
