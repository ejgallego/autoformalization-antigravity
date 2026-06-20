#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

struct mapping {
    unsigned char *base;
    size_t len;
};

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage:\n"
            "  %s prepare <dir> <files> <bytes-per-file>\n"
            "  %s probe <dir> <files> <bytes-per-file> <maps-per-file> <passes> <sequential|permuted>\n"
            "  %s walk <dir> <files> <bytes-per-file> <maps-per-file> <rounds> <records-per-file> <heap-bytes> <sequential|permuted|reverse>\n",
            argv0, argv0, argv0);
}

static uint64_t parse_u64(const char *s, const char *name) {
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0') {
        fprintf(stderr, "invalid %s: %s\n", name, s);
        exit(2);
    }
    return (uint64_t)v;
}

static void file_path(char *buf, size_t buflen, const char *dir, uint64_t idx) {
    int n = snprintf(buf, buflen, "%s/file-%06" PRIu64 ".bin", dir, idx);
    if (n < 0 || (size_t)n >= buflen) {
        fprintf(stderr, "path too long for index %" PRIu64 "\n", idx);
        exit(2);
    }
}

static double now_seconds(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static uint64_t gcd_u64(uint64_t a, uint64_t b) {
    while (b != 0) {
        uint64_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

static uint64_t coprime_stride(uint64_t n) {
    uint64_t stride = n / 2 + 1;
    if ((stride & 1) == 0) {
        stride++;
    }
    while (stride > 1 && gcd_u64(stride, n) != 1) {
        stride += 2;
        if (stride >= n) {
            stride = 1;
            break;
        }
    }
    return stride == 0 ? 1 : stride;
}

static uint64_t mix64(uint64_t x) {
    x ^= x >> 30;
    x *= UINT64_C(0xbf58476d1ce4e5b9);
    x ^= x >> 27;
    x *= UINT64_C(0x94d049bb133111eb);
    x ^= x >> 31;
    return x;
}

static int prepare_files(const char *dir, uint64_t files, size_t bytes_per_file) {
    if (mkdir(dir, 0777) != 0 && errno != EEXIST) {
        perror("mkdir");
        return 1;
    }

    const size_t chunk_size = 1024 * 1024;
    unsigned char *buf = malloc(chunk_size);
    if (buf == NULL) {
        perror("malloc");
        return 1;
    }
    for (size_t i = 0; i < chunk_size; i++) {
        buf[i] = (unsigned char)(i * 131u + 17u);
    }

    char path[4096];
    double start = now_seconds();
    for (uint64_t i = 0; i < files; i++) {
        file_path(path, sizeof(path), dir, i);
        int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0666);
        if (fd < 0) {
            perror(path);
            free(buf);
            return 1;
        }

        size_t remaining = bytes_per_file;
        while (remaining > 0) {
            size_t n = remaining < chunk_size ? remaining : chunk_size;
            ssize_t wrote = write(fd, buf, n);
            if (wrote < 0) {
                perror("write");
                close(fd);
                free(buf);
                return 1;
            }
            remaining -= (size_t)wrote;
        }
        if (close(fd) != 0) {
            perror("close");
            free(buf);
            return 1;
        }
    }
    double end = now_seconds();
    printf("mode=prepare files=%" PRIu64 " bytes_per_file=%zu total_bytes=%" PRIu64 " elapsed_seconds=%.6f\n",
           files, bytes_per_file, files * (uint64_t)bytes_per_file, end - start);
    free(buf);
    return 0;
}

static int map_files(const char *dir,
                     uint64_t files,
                     size_t bytes_per_file,
                     uint64_t maps_per_file,
                     struct mapping **maps_out) {
    uint64_t total_maps = files * maps_per_file;
    struct mapping *maps = calloc((size_t)total_maps, sizeof(struct mapping));
    if (maps == NULL) {
        perror("calloc");
        return 1;
    }

    char path[4096];
    for (uint64_t i = 0; i < files; i++) {
        file_path(path, sizeof(path), dir, i);
        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            perror(path);
            free(maps);
            return 1;
        }
        for (uint64_t j = 0; j < maps_per_file; j++) {
            uint64_t idx = i * maps_per_file + j;
            void *base = mmap(NULL, bytes_per_file, PROT_READ, MAP_PRIVATE, fd, 0);
            if (base == MAP_FAILED) {
                perror("mmap");
                close(fd);
                free(maps);
                return 1;
            }
            maps[idx].base = (unsigned char *)base;
            maps[idx].len = bytes_per_file;
        }
        close(fd);
    }

    *maps_out = maps;
    return 0;
}

static int unmap_files(struct mapping *maps, uint64_t total_maps) {
    int status = 0;
    for (uint64_t m = 0; m < total_maps; m++) {
        if (munmap(maps[m].base, maps[m].len) != 0) {
            perror("munmap");
            status = 1;
        }
    }
    free(maps);
    return status;
}

static int probe_files(const char *dir,
                       uint64_t files,
                       size_t bytes_per_file,
                       uint64_t maps_per_file,
                       uint64_t passes,
                       const char *pattern) {
    long page_size_long = sysconf(_SC_PAGESIZE);
    if (page_size_long <= 0) {
        perror("sysconf(_SC_PAGESIZE)");
        return 1;
    }
    size_t page_size = (size_t)page_size_long;
    if (bytes_per_file == 0 || bytes_per_file % page_size != 0) {
        fprintf(stderr, "bytes-per-file must be a positive multiple of page size %zu\n", page_size);
        return 2;
    }
    if (maps_per_file == 0 || passes == 0) {
        fprintf(stderr, "maps-per-file and passes must be positive\n");
        return 2;
    }

    uint64_t pages_per_map = bytes_per_file / page_size;
    uint64_t total_maps = files * maps_per_file;
    uint64_t total_slots = total_maps * pages_per_map;
    struct mapping *maps = NULL;

    double map_start = now_seconds();
    if (map_files(dir, files, bytes_per_file, maps_per_file, &maps) != 0) {
        return 1;
    }
    double map_end = now_seconds();

    volatile uint64_t checksum = 0;
    double touch_start = now_seconds();
    if (strcmp(pattern, "sequential") == 0) {
        for (uint64_t pass = 0; pass < passes; pass++) {
            for (uint64_t m = 0; m < total_maps; m++) {
                unsigned char *base = maps[m].base;
                for (uint64_t p = 0; p < pages_per_map; p++) {
                    checksum += base[p * page_size];
                }
            }
        }
    } else if (strcmp(pattern, "permuted") == 0) {
        uint64_t stride = coprime_stride(total_slots);
        for (uint64_t pass = 0; pass < passes; pass++) {
            for (uint64_t i = 0; i < total_slots; i++) {
                uint64_t slot = (i * stride) % total_slots;
                uint64_t m = slot / pages_per_map;
                uint64_t p = slot % pages_per_map;
                checksum += maps[m].base[p * page_size];
            }
        }
    } else {
        fprintf(stderr, "unknown pattern: %s\n", pattern);
        free(maps);
        return 2;
    }
    double touch_end = now_seconds();

    if (unmap_files(maps, total_maps) != 0) {
        return 1;
    }
    double end = now_seconds();

    printf("mode=probe files=%" PRIu64 " bytes_per_file=%zu maps_per_file=%" PRIu64
           " total_maps=%" PRIu64 " page_size=%zu pages_per_map=%" PRIu64
           " unique_bytes=%" PRIu64 " mapped_bytes=%" PRIu64 " touched_page_slots=%" PRIu64
           " passes=%" PRIu64 " pattern=%s map_seconds=%.6f touch_seconds=%.6f"
           " total_seconds=%.6f checksum=%" PRIu64 "\n",
           files, bytes_per_file, maps_per_file, total_maps, page_size, pages_per_map,
           files * (uint64_t)bytes_per_file,
           total_maps * (uint64_t)bytes_per_file,
           total_slots * passes,
           passes, pattern,
           map_end - map_start, touch_end - touch_start, end - map_start, checksum);

    return 0;
}

static int walk_files(const char *dir,
                      uint64_t files,
                      size_t bytes_per_file,
                      uint64_t maps_per_file,
                      uint64_t rounds,
                      uint64_t records_per_file,
                      uint64_t heap_bytes,
                      const char *pattern) {
    long page_size_long = sysconf(_SC_PAGESIZE);
    if (page_size_long <= 0) {
        perror("sysconf(_SC_PAGESIZE)");
        return 1;
    }
    size_t page_size = (size_t)page_size_long;
    if (bytes_per_file == 0 || bytes_per_file % page_size != 0 || bytes_per_file < 64) {
        fprintf(stderr, "bytes-per-file must be at least 64 bytes and a multiple of page size %zu\n", page_size);
        return 2;
    }
    if (maps_per_file == 0 || rounds == 0 || records_per_file == 0 || files == 0) {
        fprintf(stderr, "files, maps-per-file, rounds, and records-per-file must be positive\n");
        return 2;
    }
    if (strcmp(pattern, "sequential") != 0 &&
        strcmp(pattern, "permuted") != 0 &&
        strcmp(pattern, "reverse") != 0) {
        fprintf(stderr, "unknown pattern: %s\n", pattern);
        return 2;
    }

    uint64_t pages_per_map = bytes_per_file / page_size;
    uint64_t total_maps = files * maps_per_file;
    uint64_t header_touches = files * rounds * 4;
    uint64_t record_touches = files * rounds * records_per_file * 4;
    uint64_t heap_slots = heap_bytes / (uint64_t)page_size;
    struct mapping *maps = NULL;

    double map_start = now_seconds();
    if (map_files(dir, files, bytes_per_file, maps_per_file, &maps) != 0) {
        return 1;
    }
    double map_end = now_seconds();

    unsigned char *heap = NULL;
    double heap_start = now_seconds();
    if (heap_bytes > 0) {
        heap = malloc((size_t)heap_bytes);
        if (heap == NULL) {
            perror("malloc heap");
            unmap_files(maps, total_maps);
            return 1;
        }
        for (uint64_t off = 0; off < heap_bytes; off += (uint64_t)page_size) {
            heap[off] = (unsigned char)(off >> 12);
        }
    }
    double heap_end = now_seconds();

    uint64_t module_stride = coprime_stride(files);
    volatile uint64_t checksum = 0;
    double walk_start = now_seconds();
    for (uint64_t round = 0; round < rounds; round++) {
        for (uint64_t i = 0; i < files; i++) {
            uint64_t module;
            if (strcmp(pattern, "sequential") == 0) {
                module = i;
            } else if (strcmp(pattern, "reverse") == 0) {
                module = files - 1 - i;
            } else {
                module = (i * module_stride + round * (module_stride + 1)) % files;
            }

            struct mapping *primary = &maps[module * maps_per_file + (round % maps_per_file)];
            struct mapping *header = &maps[module * maps_per_file];
            unsigned char *base = primary->base;
            unsigned char *header_base = header->base;

            checksum += header_base[0];
            checksum += header_base[bytes_per_file / 3];
            checksum += header_base[bytes_per_file / 2];
            checksum += header_base[bytes_per_file - 1];

            for (uint64_t record = 0; record < records_per_file; record++) {
                uint64_t seed = mix64(module ^ (round << 32) ^ (record * UINT64_C(0x9e3779b97f4a7c15)) ^ checksum);
                size_t off = (size_t)(seed % (uint64_t)(bytes_per_file - 64));
                checksum += base[off];
                checksum += base[off + 8];
                checksum += base[off + 24];
                checksum += base[off + 56];
            }

            if (heap != NULL && heap_slots > 0) {
                uint64_t slot = mix64(module + round * UINT64_C(0xd6e8feb86659fd93) + checksum) % heap_slots;
                heap[slot * (uint64_t)page_size] ^= (unsigned char)checksum;
            }
        }
    }
    double walk_end = now_seconds();

    free(heap);
    if (unmap_files(maps, total_maps) != 0) {
        return 1;
    }
    double end = now_seconds();

    printf("mode=walk files=%" PRIu64 " bytes_per_file=%zu maps_per_file=%" PRIu64
           " total_maps=%" PRIu64 " page_size=%zu pages_per_map=%" PRIu64
           " unique_bytes=%" PRIu64 " mapped_bytes=%" PRIu64
           " rounds=%" PRIu64 " records_per_file=%" PRIu64
           " heap_bytes=%" PRIu64 " heap_slots=%" PRIu64
           " header_touches=%" PRIu64 " record_touches=%" PRIu64
           " pattern=%s map_seconds=%.6f heap_seconds=%.6f walk_seconds=%.6f"
           " total_seconds=%.6f checksum=%" PRIu64 "\n",
           files, bytes_per_file, maps_per_file, total_maps, page_size, pages_per_map,
           files * (uint64_t)bytes_per_file,
           total_maps * (uint64_t)bytes_per_file,
           rounds, records_per_file, heap_bytes, heap_slots,
           header_touches, record_touches,
           pattern,
           map_end - map_start, heap_end - heap_start, walk_end - walk_start,
           end - map_start, checksum);

    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "prepare") == 0) {
        if (argc != 5) {
            usage(argv[0]);
            return 2;
        }
        const char *dir = argv[2];
        uint64_t files = parse_u64(argv[3], "files");
        size_t bytes_per_file = (size_t)parse_u64(argv[4], "bytes-per-file");
        return prepare_files(dir, files, bytes_per_file);
    }

    if (strcmp(argv[1], "probe") == 0) {
        if (argc != 8) {
            usage(argv[0]);
            return 2;
        }
        const char *dir = argv[2];
        uint64_t files = parse_u64(argv[3], "files");
        size_t bytes_per_file = (size_t)parse_u64(argv[4], "bytes-per-file");
        uint64_t maps_per_file = parse_u64(argv[5], "maps-per-file");
        uint64_t passes = parse_u64(argv[6], "passes");
        const char *pattern = argv[7];
        return probe_files(dir, files, bytes_per_file, maps_per_file, passes, pattern);
    }

    if (strcmp(argv[1], "walk") == 0) {
        if (argc != 10) {
            usage(argv[0]);
            return 2;
        }
        const char *dir = argv[2];
        uint64_t files = parse_u64(argv[3], "files");
        size_t bytes_per_file = (size_t)parse_u64(argv[4], "bytes-per-file");
        uint64_t maps_per_file = parse_u64(argv[5], "maps-per-file");
        uint64_t rounds = parse_u64(argv[6], "rounds");
        uint64_t records_per_file = parse_u64(argv[7], "records-per-file");
        uint64_t heap_bytes = parse_u64(argv[8], "heap-bytes");
        const char *pattern = argv[9];
        return walk_files(dir, files, bytes_per_file, maps_per_file, rounds, records_per_file, heap_bytes, pattern);
    }

    usage(argv[0]);
    return 2;
}
