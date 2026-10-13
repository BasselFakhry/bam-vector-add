// GPU-initiated SSD vector addition using BaM commit 315fadfc.
// Build with build.sh. Running overwrites raw regions on BOTH /dev/libnvm{0,1}.
// Defaults: 10,737,418,240 int32_t elements per array (40 GiB each).
#include <cuda_runtime.h>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <chrono>
#include <page_cache.h>

constexpr uint64_t kElements = 10737418240ULL;
constexpr uint64_t kPageBytes = 16384;
constexpr uint64_t kCacheBytes = 1ULL << 30; // Shared 1 GiB data cache, plus metadata.
constexpr int kGpu = 0;
constexpr unsigned kThreads = 128, kBlocks = 256;
static_assert(sizeof(int32_t) == 4, "Requires 32-bit integers");

void check(cudaError_t status) {
    if (status != cudaSuccess) throw std::runtime_error(cudaGetErrorString(status));
}
void finish() {
    check(cudaGetLastError());
    check(cudaDeviceSynchronize());
}

// Stateless, reproducible pseudorandom numbers. Independent stream per array.
// Restricted range ensures that signed int32 addition cannot overflow.
__host__ __device__ int32_t random_value(uint64_t i, uint64_t seed, uint64_t stream) {
    uint64_t x = i + seed + 0x9e3779b97f4a7c15ULL * (stream + 1);
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return static_cast<int32_t>(x % 2000001ULL) - 1000000;
}

__global__ void initialize_arrays(array_d_t<int32_t>* A, array_d_t<int32_t>* B,
                                  array_d_t<int32_t>* C, uint64_t n, uint64_t seed) {
    const uint64_t stride = uint64_t(blockDim.x) * gridDim.x;
    for (uint64_t i = uint64_t(blockIdx.x) * blockDim.x + threadIdx.x;
         i < n; i += stride) {
        A->seq_write(i, random_value(i, seed, 0));
        B->seq_write(i, random_value(i, seed, 1));
        C->seq_write(i, random_value(i, seed, 2));
    }
}

__global__ void vector_add(array_d_t<int32_t>* A, array_d_t<int32_t>* B,
                           array_d_t<int32_t>* C, uint64_t n) {
    const uint64_t stride = uint64_t(blockDim.x) * gridDim.x;
    for (uint64_t i = uint64_t(blockIdx.x) * blockDim.x + threadIdx.x;
         i < n; i += stride) {
        const int32_t a = A->seq_read(i);
        const int32_t b = B->seq_read(i);
        C->seq_write(i, a + b);
    }
}

// Executed with a newly constructed (cold) cache after flushing C to the SSDs.
__global__ void verify_arrays(array_d_t<int32_t>* A, array_d_t<int32_t>* B,
                              array_d_t<int32_t>* C, uint64_t n, uint64_t seed,
                              unsigned long long* errors) {
    const uint64_t stride = uint64_t(blockDim.x) * gridDim.x;
    unsigned long long local_errors = 0;
    for (uint64_t i = uint64_t(blockIdx.x) * blockDim.x + threadIdx.x;
         i < n; i += stride) {
        const int32_t a = A->seq_read(i);
        const int32_t b = B->seq_read(i);
        const int32_t c = C->seq_read(i);
        const int32_t expected_a = random_value(i, seed, 0);
        const int32_t expected_b = random_value(i, seed, 1);
        if (a != expected_a || b != expected_b || c != expected_a + expected_b)
            ++local_errors;
    }
    if (local_errors) atomicAdd(errors, local_errors);
}

// Members are destroyed in reverse order: arrays, ranges, then cache.
// The caller keeps both controllers alive until all DMA buffers are released.
struct Arrays {
    page_cache_t cache;
    std::unique_ptr<range_t<int32_t>> ranges[3];
    std::unique_ptr<array_t<int32_t>> arrays[3];

    Arrays(uint64_t n, const std::vector<Controller*>& controllers)
        : cache(kPageBytes, kCacheBytes / kPageBytes, kGpu,
                *controllers[0], 4, controllers) {
        const uint64_t pages = (n * sizeof(int32_t) + kPageBytes - 1) / kPageBytes;
        const uint64_t pages_per_ssd = (pages + 1) / 2;
        // Explicitly start a new cache allocation sequence.
        check(cudaMemset(cache.pdt.page_ticket, 0, sizeof(padded_struct_pc)));
        check(cudaMemset(cache.pdt.ctrl_counter, 0,
                         sizeof(simt::atomic<uint64_t, simt::thread_scope_device>)));
        for (unsigned j = 0; j < 3; ++j) {
            // STRIPE: SSD = logical_page % 2;
            // physical_page = start_page + logical_page / 2.
            const uint64_t start_page = j * pages_per_ssd;
            ranges[j].reset(new range_t<int32_t>(0, n, start_page, pages, 0,
                                                kPageBytes, &cache, kGpu, STRIPE));
            std::vector<range_t<int32_t>*> r{ranges[j].get()};
            arrays[j].reset(new array_t<int32_t>(n, start_page * kPageBytes, r, kGpu));
        }
    }
    array_d_t<int32_t>* operator[](unsigned j) { return arrays[j]->d_array_ptr; }
    void flush() { cache.flush_cache(); finish(); }
};

uint64_t parse_uint(const char* s) {
    std::string text(s);
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos)
        throw std::runtime_error("Arguments must be unsigned decimal integers");
    return std::stoull(text);
}

template<class F> void timed(const char* label, F action) {
    std::cout << std::dec << label << "..." << std::endl;
    const auto start = std::chrono::steady_clock::now();
    action();
    std::cout << std::dec << label << ": "
              << std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count()
              << " seconds" << std::endl;
}

int main(int argc, char** argv) {
    try {
        if (argc > 3 || (argc > 1 && std::string(argv[1]) == "--help")) {
            std::cout << "Usage: " << argv[0] << " [elements [seed]]\n"
                      << "Defaults: 10737418240 elements, seed 12345.\n"
                      << "OVERWRITES raw A/B/C regions on /dev/libnvm0 and /dev/libnvm1.\n";
            return argc > 3 ? 1 : 0;
        }
        const uint64_t n = argc > 1 ? parse_uint(argv[1]) : kElements;
        const uint64_t seed = argc > 2 ? parse_uint(argv[2]) : 12345;
        if (n == 0 || n > kElements)
            throw std::runtime_error("elements must be between 1 and 10737418240");
        const uint64_t pages = (n * sizeof(int32_t) + kPageBytes - 1) / kPageBytes;
        const uint64_t bytes_per_ssd = 3 * ((pages + 1) / 2) * kPageBytes;
        // Must precede the first CUDA runtime call.
        if (setenv("CUDA_DEVICE_ORDER", "PCI_BUS_ID", 1) != 0)
            throw std::runtime_error("Cannot set CUDA_DEVICE_ORDER");
        check(cudaSetDevice(kGpu));
        char bdf[32];
        check(cudaDeviceGetPCIBusId(bdf, sizeof(bdf), kGpu));
        std::cout << "GPU " << bdf << "; " << n << " int32 elements per array\n"
                  << "Overwriting bytes [0, " << bytes_per_ssd
                  << ") on EACH SSD; shared GPU cache = 1 GiB.\n" << std::flush;

        {
            std::unique_ptr<Controller> ssd0(new Controller("/dev/libnvm0", 1, kGpu, 128, 32));
            std::unique_ptr<Controller> ssd1(new Controller("/dev/libnvm1", 1, kGpu, 128, 32));
            std::vector<Controller*> controllers{ssd0.get(), ssd1.get()};
            for (Controller* c : controllers) {
                if (c->blk_size == 0 || kPageBytes % c->blk_size != 0 ||
                    c->blk_size != ssd0->blk_size || c->page_size != ssd0->page_size ||
                    c->ns.metadata_size != 0 ||
                    c->ns.size < bytes_per_ssd / c->blk_size ||
                    c->ns.capacity < bytes_per_ssd / c->blk_size)
                    throw std::runtime_error("Incompatible namespace geometry or insufficient capacity");
            }
            {
                Arrays data(n, controllers);
                timed("Random initialization of A, B, C and cache writeback", [&] {
                    initialize_arrays<<<kBlocks, kThreads>>>(data[0], data[1], data[2], n, seed);
                    finish();
                    data.flush();
                });
                timed("C = A + B and cache writeback", [&] {
                    vector_add<<<kBlocks, kThreads>>>(data[0], data[1], data[2], n);
                    finish();
                    data.flush();
                });
            }
            {
                Arrays data(n, controllers); // Drop prior cache: verify SSD-backed results.
                BufferPtr errors = createBuffer(sizeof(unsigned long long), kGpu);
                check(cudaMemset(errors.get(), 0, sizeof(unsigned long long)));
                timed("Full verification with a fresh cache", [&] {
                    verify_arrays<<<kBlocks, kThreads>>>(data[0], data[1], data[2], n, seed,
                        static_cast<unsigned long long*>(errors.get()));
                    finish();
                });
                unsigned long long count = 0;
                check(cudaMemcpy(&count, errors.get(), sizeof(count), cudaMemcpyDeviceToHost));
                if (count) throw std::runtime_error("Verification failed at " +
                                                    std::to_string(count) + " indices");
                std::cout << "PASS: every A, B, C element verified.\n";
            }
        }
        // All BaM objects have released their resources before resetting CUDA.
        check(cudaDeviceReset());
        std::cout << "Released arrays, cache, queues, controllers and CUDA context.\n"
                  << "Raw SSD contents remain; deallocation does not erase them.\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "ERROR: " << e.what() << '\n';
        cudaDeviceReset();
        return 1;
    }
}
