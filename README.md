# BaM int32 vector addition

`vector_add_bam.cu` creates three SSD-backed BaM `array_t<int32_t>` arrays,
randomly initializes **all three**, launches `C[i] = A[i] + B[i]`, writes back
dirty pages, verifies every A/B/C element using a fresh cache, then releases
the arrays, cache, controller queues and CUDA context.

Default size: **10,737,418,240 elements per array = 40 GiB**, 120 GiB total.
Uses GPU 0, `/dev/libnvm0` and `/dev/libnvm1`, namespace 1, 16 KiB pages,
32 queues per SSD, queue depth 128, and a shared **1 GiB GPU data cache**.
Range/page metadata uses additional GPU memory (about 240 MiB for page states).
All indexing and storage offsets are 64-bit.

## Raw storage layout

Running the program **overwrites the first 60 GiB of each SSD** at the default
size. Run only with your two dedicated SSDs already bound to BaM. Do not run
another BaM application against these controllers concurrently.

| Array | Region on each SSD | Logical size across both SSDs |
|---|---|---|
| A | [0, 20 GiB) | 40 GiB |
| B | [20, 40 GiB) | 40 GiB |
| C | [40, 60 GiB) | 40 GiB |

Pages alternate between the two controllers (`STRIPE`). Regions are recomputed
for smaller test sizes, rounding up to whole pages per SSD. No filesystem,
partitioning, RAID, or full-size CPU buffers are involved. Deallocation releases
application resources; SSD contents remain until overwritten. BaM's cache
writeback is not a guarantee of power-loss durability / an NVMe FLUSH command.

Random values are reproducible from a seed and lie in [-1,000,000, 1,000,000],
so addition fits in int32. C is randomly initialized as requested, then overwritten
by the sum. Initialization uses BaM writes, which may read pages on cache misses.
Printed durations include cache writeback; this is an application example,
not a raw bandwidth benchmark.

## Build on sws-2a100-03

Copy `vector_add_bam.cu`, `build.sh`, and `prepare_header.py` into a directory on
the node, then run there:

```bash
bash build.sh
```

Defaults match the working installation:
`BAM_ROOT=/root/bam-setup/bam`, `BAM_BUILD=$BAM_ROOT/build-a100-gcc12`,
`CUDA_ROOT=/opt/bam/cuda-12.8`, `BAM_CXX=/usr/bin/g++-12`.
These environment variables can override the paths. The existing CUDA 12.8
header compatibility fix is still required on that node.

The build helper creates `.bam-include/page_cache.h` from your BaM header. It
corrects upstream `new[]`/`delete` mismatches and makes cache flush skip unused
slots (needed for small tests). It also enables aligned C++11 allocations.
The installed BaM source and kernel module are unchanged. Keep the helper files
with the `.cu` file and use this build command.

## Run on the node as root

```bash
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export LD_LIBRARY_PATH="/opt/bam/cuda-12.8/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Small correctness test: 1,048,576 int32 elements (4 MiB) per array.
./vector_add_bam 1048576 12345

# Full requested size: 40 GiB per array, using the default seed.
./vector_add_bam
```

The small test also writes the beginning of both SSDs. Proceed to the full run
after it prints `PASS`. The full run performs substantial SSD reads and writes
and may take minutes. `./vector_add_bam --help` prints usage without opening SSDs.
After a node reboot, load the BaM module and bind the SSDs again first.

## Validation

API inspected against BaM commit `315fadfc5c5c018a64596157bfac94ecbb7d87a2`
and its pinned freestanding/libcxx dependencies. CUDA object compilation passed
locally with CUDA 13.0 / GCC 11 targeting `sm_80`; the node build command uses
your CUDA 12.8 / GCC 12 installation. Linking and hardware execution must be
performed on the configured node; local validation does not establish SSD
write correctness on that machine.

Source reference: https://github.com/ZaidQureshi/bam/blob/315fadfc5c5c018a64596157bfac94ecbb7d87a2/include/page_cache.h
