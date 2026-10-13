# BaM cluster setup and handoff

This document records the setup and results reported during the October 12–13,
2026 session. It is a handoff for another chat, not a fresh probe of the node.
After a reboot or a new reservation, recheck runtime state before running I/O.

## Context for the next assistant

The user reserved `sws-2a100-03` to build CUDA applications that initiate NVMe
access from GPU threads using [BaM](https://github.com/ZaidQureshi/bam).
The user has root access and confirmed that **both NVMe SSDs are dedicated to
this experiment**. Use both SSDs and GPU 0. Setup and full-size vector-add
correctness testing have already succeeded; do not restart installation.

BaM source, CUDA, and the kernel module are on the cluster node. The local
workstation is a different machine. SSH is normally initiated with
`ssh sws-2a100-03`, logging in as `bfakhri`; installation and runs were performed
from a root shell. Do not assume direct root SSH is configured.

The example repository is private:
https://github.com/BasselFakhry/bam-vector-add

## Hardware and operating system

| Item | Observed configuration |
|---|---|
| Host | `sws-2a100-03` |
| OS | Debian 13 (trixie) |
| Running Linux kernel | `6.18.48.1.amd64-smp` |
| NVIDIA driver | `595.71.05`, open kernel module |
| GPU 0 | NVIDIA A100 80 GB PCIe, `0000:17:00.0`, NUMA node 0 |
| GPU 1 | NVIDIA A100 80 GB PCIe, `0000:ca:00.0`, NUMA node 1 |
| GPU PCIe links | Reported PCIe 4.0 ×16 |
| GPU BAR1 | Reported 128 GiB per GPU; large BAR resources allocated |
| MIG | Disabled |
| SSD 0 | Samsung/Dell PM1735a MU, 1.6 TB nominal, about 1.5 TiB |
| SSD 0 PCI address | `0000:67:00.0`, NUMA node 0 |
| SSD 1 | SK hynix/Dell PE8010 U.2, 960 GB nominal, about 894.3 GiB |
| SSD 1 PCI address | `0000:68:00.0`, NUMA node 0 |
| SSD PCIe links | Reported PCIe 4.0 ×4 each |
| CPU model / system RAM total | Not recorded here; inspect the node if needed |

GPU 0 and the SSDs are under different PCI root buses; do not claim they share
a PCIe switch. Tested GPU-to-SSD I/O works on this topology.

Relevant paths:

```text
GPU 0: /sys/devices/pci0000:16/0000:16:02.0/0000:17:00.0
SSD 0: /sys/devices/pci0000:64/0000:64:04.0/0000:67:00.0
SSD 1: /sys/devices/pci0000:64/0000:64:05.0/0000:68:00.0
```

Initially the SSD namespaces were `/dev/nvme0n1` and `/dev/nvme1n1`, with no
mounted filesystems or storage holders found before binding. They now contain
the experiment's data. The OS uses separate SATA storage: sda/sdb for the root
RAID and sdc/sdd for `/local`. Never substitute these OS disks for the NVMe SSDs.

## What was installed and built

There is **no separate BaM OS kernel**. The existing Linux kernel loads BaM's
`libnvm.ko` module. NVIDIA's installed driver was retained.

| Component | Path / version |
|---|---|
| CUDA toolkit | `/opt/bam/cuda-12.8`, nvcc `12.8.93` |
| CUDA installer | `cuda_12.8.1_570.124.06_linux.run`, toolkit-only installation |
| User-space compiler | `/usr/bin/gcc-12`, `/usr/bin/g++-12`, Debian `12.4.0-5` |
| Kernel-module compiler | `/usr/bin/gcc`, GCC 14.2 |
| CMake | 3.31.6 |
| BaM checkout | `/root/bam-setup/bam` |
| BaM commit | `315fadfc5c5c018a64596157bfac94ecbb7d87a2` |
| Successful build | `/root/bam-setup/bam/build-a100-gcc12` |
| BaM library | `build-a100-gcc12/lib/libnvm.so` |
| BaM kernel module | `build-a100-gcc12/module/libnvm.ko` |
| Raw benchmark | `build-a100-gcc12/bin/nvm-block-bench` |
| Example checkout on node | `/root/bam-vector-add` |
| Benchmark logs | `/root/bam-setup/results/` |
| Exact kernel headers | `/lib/modules/6.18.48.1.amd64-smp/build` |
| NVIDIA source used for symbols | `/root/bam-setup/nvidia-open-595.71.05` |
| NVIDIA symbols file | `.../nvidia-open-595.71.05/kernel-open/Module.symvers` |

BaM dependencies were cloned recursively. Pinned revisions:

- `include/freestanding`: `6360203797a3601fa61f3580dc97b2535b2c232d`
- Its `libcxx`: `36156f0962149ef19ce778110642150b456a182b`

The `CUDA Version: 13.2` shown by `nvidia-smi` is the installed driver's reported
CUDA compatibility level. The toolkit used for this project is CUDA 12.8.

Set these variables in each shell as needed:

```bash
export PATH="/opt/bam/cuda-12.8/bin:$PATH"
export LD_LIBRARY_PATH="/opt/bam/cuda-12.8/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
```

## Boot configuration: IOMMU and ACS

The node uses **confupdate-managed GRUB**. Ordinary `update-grub` printed
`Disabled by confupdate`. Do not bypass `/etc/default/grub.d/disable.cfg` or
assume `/etc/default/grub` controls the generated entries.

The supported configuration is `/etc/confupdate/kernel-append.d/BAM_P2P`.
Its literal contents have **two backslashes before each semicolon**:

```text
intel_iommu=off
pci=disable_acs_redir=0000:16:02.0\\;0000:64:04.0\\;0000:64:05.0
```

Confupdate's `xargs` processing removes one escape level, leaving escaped
semicolons in GRUB. The running kernel receives ordinary semicolons.
These are configuration-file contents, **not commands to type into Bash**.

The configuration was applied with:

```bash
confupdate command bootloader append
grub-script-check /boot/grub/grub.cfg
```

That command also ran `grub-install` for both existing EFI boot installations.
The node was then rebooted. Backups were saved under
`/root/bam-setup/boot-backups/`.

Verified after reboot:

- `/proc/cmdline` includes `intel_iommu=off` and the complete three-port ACS list.
- GPU 0 and both NVMe controllers had no `iommu_group` symlinks.
- All three listed ports showed `ReqRedir-` and `CmpltRedir-` in `ACSCtl`.
- Both A100 GPUs remained available with NVIDIA driver 595.71.05.

Read PCI extended capabilities as root; unprivileged `lspci` previously printed
no ACS lines. GPU 1's root port was not included in these changes.

## Compatibility fixes used

1. **Toolkit-only CUDA install.** The Debian CUDA package installation plan
   would have removed some installed NVIDIA packages, so the runfile's
   `--toolkit --toolkitpath=/opt/bam/cuda-12.8` option was used instead.
2. **CUDA 12.8 versus newer glibc headers.** Added `noexcept(true)` to the four
   conflicting declarations for `sinpi`, `sinpif`, `cospi`, and `cospif` in
   `/opt/bam/cuda-12.8/targets/x86_64-linux/include/crt/math_functions.h`.
   Backup: `math_functions.h.bam-original`. This was a local compatibility
   workaround, not a replacement NVIDIA driver.
3. **Old bundled C++ headers versus GCC 14.** CUDA/BaM user-space compilation
   succeeded with GCC/G++ 12. Use the `build-a100-gcc12` directory, not the older
   failed `build-a100` directory.
4. **Linux 6.18 module API changes.** In BaM `module/pci.c`, changed
   `class_create(THIS_MODULE, DRIVER_NAME)` to `class_create(DRIVER_NAME)`.
   In `module/map.c`, removed the final `NULL` argument from the old five-argument
   `get_user_pages` call. These are node-specific compatibility edits.
5. **Matching NVIDIA exported-symbol information.** Cloned tag `595.71.05` from
   `NVIDIA/open-gpu-kernel-modules` and built `modules` from the repository root
   to generate `kernel-open/Module.symvers`. Building only the incomplete
   installed source copy failed with missing `nv-kernel.o_binary`.
   The rebuilt NVIDIA modules were **not installed or loaded**.
6. **BaM module Kbuild.** Symlinked the BaM `module/*.c` and `module/*.h` sources
   into the module build directory and supplied the Kbuild below.

The successful user-space configuration was equivalent to:

```bash
cd /root/bam-setup/bam
cmake -S . -B build-a100-gcc12 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_DEFAULT_CMP0146=OLD \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-12 \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++-12 \
  -DCMAKE_CUDA_COMPILER=/opt/bam/cuda-12.8/bin/nvcc \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-12 \
  -DCUDA_HOST_COMPILER=/usr/bin/g++-12 \
  -DCUDA_TOOLKIT_ROOT_DIR=/opt/bam/cuda-12.8 \
  -DCMAKE_CUDA_ARCHITECTURES=80 -Dnvidia_archs=80 \
  -DNVIDIA=/root/bam-setup/nvidia-open-595.71.05/kernel-open/nvidia \
  -Ddriver_include:PATH=/root/bam-setup/nvidia-open-595.71.05/kernel-open/nvidia \
  -DKERNEL=/lib/modules/"$(uname -r)"/build
cmake --build build-a100-gcc12 --target libnvm block-benchmark-module --parallel 8
```

`/root/bam-setup/bam/build-a100-gcc12/module/Kbuild` contains:

```makefile
obj-m := libnvm.o
libnvm-y := pci.o list.o ctrl.o map.o
ccflags-y += -D_CUDA
ccflags-y += -I/root/bam-setup/nvidia-open-595.71.05/kernel-open/nvidia
ccflags-y += -I/root/bam-setup/bam/src
ccflags-y += -I/root/bam-setup/bam/src/linux
KBUILD_EXTRA_SYMBOLS := /root/bam-setup/nvidia-open-595.71.05/kernel-open/Module.symvers
```

It was built with:

```bash
make -C /root/bam-setup/bam/build-a100-gcc12/module -j8 CC=/usr/bin/gcc
```

The resulting `libnvm.ko` reports version 0.3, depends on `nvidia`, and has
vermagic matching `6.18.48.1.amd64-smp`. Missing `vmlinux` caused BTF generation
to be skipped; module compilation and loading still succeeded.

## Runtime module and SSD ownership

The module was loaded with `max_num_ctrls=2`. After confirming no mounts, swap,
or storage holders on either selected namespace, both PCI devices were unbound
from the Linux `nvme` driver and bound to the PCI driver named **`libnvm helper`**.

Observed mapping after binding in SSD 0, then SSD 1 order:

| PCI device | BaM device | Driver |
|---|---|---|
| `0000:67:00.0` | `/dev/libnvm0` | `libnvm helper` |
| `0000:68:00.0` | `/dev/libnvm1` | `libnvm helper` |

Device nodes were root-only (`0600`). Ordinary Linux NVMe block nodes disappear
while their controllers are owned by BaM. Do not mount or concurrently access
these controllers through another application during a BaM run.

**Module loading and controller binding were manual, not configured to happen
automatically after reboot.** If the node rebooted, inspect it first. The restart
sequence is: confirm dedicated controllers are unused, load the matching
`libnvm.ko` if needed, then unbind/bind only the two selected PCI devices. Do not
blindly reload an already active module or assume enumeration is unchanged.

Read-only checks, run as root on the node:

```bash
uname -r
cat /proc/cmdline
nvidia-smi
lsmod | grep '^libnvm'
ls -l /dev/libnvm*
for bam_bdf in 0000:67:00.0 0000:68:00.0; do
  readlink -f "/sys/bus/pci/devices/$bam_bdf/driver"
done
for bam_port in 0000:16:02.0 0000:64:04.0 0000:64:05.0; do
  lspci -D -s "$bam_port" -vv | grep 'ACSCtl:'
done
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL
swapon --show
```

A kernel or NVIDIA driver upgrade may require rebuilding the module against
the new headers/symbols. No such upgrade was performed in this session.

## Verified performance and correctness

### BaM raw read benchmark

GPU 0, both SSDs, sequential reads. The benchmark labels bandwidth `GB/S`,
but the reported values use GiB/s; approximately 12.19 GiB/s is 13.09 GB/s.

| Request size | Queues per SSD | Reported effective bandwidth |
|---|---:|---:|
| 4 KiB | 8 | 4.6106 GiB/s |
| 4 KiB | 32 | 5.34147 GiB/s |
| 16 KiB | 32 | 12.0803 GiB/s |
| 64 KiB | 32 | 12.1484 GiB/s |

A longer 16 KiB sweep averaged 12.18705 GiB/s with 32 queues/depth 128,
12.18820 with 64/depth 128, and 12.19055 with 64/depth 256. More queues/depth
provided negligible improvement. Keep 32 queues/depth 128 as the tested baseline.
This is a measured plateau, not proof of the exact physical bottleneck.

### Vector addition: completed successfully on the node

The small test (1,048,576 elements per array) and full test both printed PASS.
Full size: **10,737,418,240 int32 elements per array, 40 GiB each, 120 GiB total**.

| Phase | Full-size time |
|---|---:|
| Random initialization of A/B/C plus cache writeback | 91.0164 s |
| `C = A + B` plus cache writeback | 220.279 s |
| Full verification through a newly created cache | 169.522 s |

Every A/B/C element was checked against deterministic expected values.
After cache writeback, the original cache was destroyed and a fresh cache was
used for verification. This validates SSD-backed read/write correctness for
this workload. It does not test power-loss durability or arbitrary applications.

The program released its arrays, cache, queues, controllers and CUDA context.
Raw SSD contents remain. Full initialization overwrote the first **60 GiB on
each SSD**: A at [0,20), B at [20,40), C at [40,60) GiB per SSD.

## Example build and run

The node successfully cloned this private repository after GitHub CLI browser
authentication. GitHub account passwords do not authenticate HTTPS Git clones;
use the node's authenticated Git/CLI setup or an authorized SSH key. Never put
tokens or credentials in this document.

From the existing root checkout:

```bash
cd /root/bam-vector-add
git pull --ff-only
bash build.sh
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export LD_LIBRARY_PATH="/opt/bam/cuda-12.8/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
./vector_add_bam 1048576
```

After the small test prints PASS, the full run is `./vector_add_bam`.
Both runs write raw SSD regions; they are not read-only diagnostics.

The build helper generates a private `.bam-include/page_cache.h` overlay with
correct `delete[]` calls and a flush guard for unused cache slots. It enables
aligned allocations for C++11. These changes leave the original BaM checkout
untouched. BaM header warnings appeared during the node build, but linking and
both runtime tests succeeded.

## Application programming model and tunable settings

- CPU setup constructs controllers, the shared cache, ranges and array descriptors.
- CUDA kernels use `array_d_t<int32_t>::seq_read` and `seq_write`.
- BaM handles cache lookup, misses, GPU-initiated I/O and eviction during access.
- The example assigns disjoint raw SSD regions; upstream BaM does not allocate
  named filesystem files for these arrays. A reusable wrapper can hide this setup.
- `kCacheBytes` is currently `1ULL << 30` (1 GiB shared across all arrays).
  `40ULL << 30` requests 40 GiB, subject to metadata and other GPU memory needs.
- `kPageBytes` is currently 16384 (16 KiB); 4096 (4 KiB) was also used in the
  raw benchmarks. Page sizes must satisfy BaM/controller constraints.
- Changing striped page size changes the on-SSD interpretation: reinitialize
  the example's arrays rather than reading old data with the new layout.
- Neither a 40 GiB cache nor the vector-add example with 4 KiB pages was tested
  in the recorded session. These were discussed as configuration options.
- The kernel uses 256 blocks × 128 threads and 64-bit grid-stride indexing.
- Inputs are reproducible pseudorandom int32 values in [-1,000,000, 1,000,000],
  so their sums fit in int32. All three arrays, including C, are initialized.
- Explicit cache writeback plus synchronization is performed before teardown.
  This is not an NVMe FLUSH/power-loss durability guarantee.

## Suggested prompt for another chat

> Read CLUSTER_SETUP.md and README.md from my bam-vector-add repository. BaM is
> already installed and validated on sws-2a100-03 with GPU 0 and two dedicated
> NVMe SSDs. The full 3 × 40 GiB int32 vector-add test passed. Preserve the existing
> driver/toolkit and confupdate-managed boot configuration. Check current runtime
> state if the node rebooted. Help me build further GPU-initiated storage
> applications using the existing installation; distinguish recorded results
> from configuration options that have not yet been tested.
