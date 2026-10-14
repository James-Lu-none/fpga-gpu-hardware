// Synchronous simulation adapter for the OpenCL calls used by our host tests.
// Kernels always run in RTL; this adapter never computes GPU results on the CPU.
#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>

#define MEMORY_BYTES 65536
#define MAX_ARGS 16
struct _cl_platform_id { int unused; };
struct _cl_device_id { int unused; };
struct _cl_context { unsigned char memory[MEMORY_BYTES]; size_t next; };
struct _cl_command_queue { cl_context context; };
struct _cl_mem { cl_context context; size_t address, size; };
struct _cl_program { cl_context context; char *source; int built; };
struct _cl_kernel { cl_program program; uint32_t args[MAX_ARGS]; unsigned set[MAX_ARGS], count; };
static struct _cl_platform_id platform;
static struct _cl_device_id device;
static void status(cl_int *out, cl_int value) { if (out) *out = value; }

cl_int clGetPlatformIDs(cl_uint count, cl_platform_id *out, cl_uint *total) {
    if (total) *total = 1;
    if (out && count) *out = &platform;
    return CL_SUCCESS;
}
cl_int clGetDeviceIDs(cl_platform_id p, cl_device_type type, cl_uint count, cl_device_id *out, cl_uint *total) {
    (void)type;
    if (p != &platform) return CL_INVALID_PLATFORM;
    if (total) *total = 1;
    if (out && count) *out = &device;
    return CL_SUCCESS;
}
static cl_int info_string(const char *text, size_t size, void *value, size_t *required) {
    size_t length = strlen(text) + 1;
    if (required) *required = length;
    if (value) {
        if (size < length) return CL_INVALID_VALUE;
        memcpy(value, text, length);
    }
    return CL_SUCCESS;
}
cl_int clGetPlatformInfo(cl_platform_id p, cl_platform_info param, size_t size, void *value, size_t *required) {
    if (p != &platform) return CL_INVALID_PLATFORM;
    if (param != CL_PLATFORM_NAME) return CL_INVALID_VALUE;
    return info_string("FPGA GPU RTL simulation", size, value, required);
}
cl_int clGetDeviceInfo(cl_device_id d, cl_device_info param, size_t size, void *value, size_t *required) {
    if (d != &device) return CL_INVALID_DEVICE;
    if (param != CL_DEVICE_NAME) return CL_INVALID_VALUE;
    return info_string("GPC Verilator", size, value, required);
}
cl_context clCreateContext(const cl_context_properties *props, cl_uint count, const cl_device_id *devices,
        void (CL_CALLBACK *notify)(const char *, const void *, size_t, void *), void *data, cl_int *err) {
    (void)props; (void)notify; (void)data;
    if (count != 1 || !devices || devices[0] != &device) { status(err, CL_INVALID_DEVICE); return NULL; }
    cl_context c = calloc(1, sizeof(*c));
    if (c) c->next = 4096; // Kernel arguments occupy address zero.
    status(err, c ? CL_SUCCESS : CL_OUT_OF_HOST_MEMORY);
    return c;
}
cl_command_queue clCreateCommandQueue(cl_context c, cl_device_id d, cl_command_queue_properties props, cl_int *err) {
    (void)props;
    if (!c || d != &device) { status(err, CL_INVALID_CONTEXT); return NULL; }
    cl_command_queue q = malloc(sizeof(*q));
    if (q) q->context = c;
    status(err, q ? CL_SUCCESS : CL_OUT_OF_HOST_MEMORY);
    return q;
}
cl_mem clCreateBuffer(cl_context c, cl_mem_flags flags, size_t size, void *host, cl_int *err) {
    (void)flags;
    if (!c || !size || size > MEMORY_BYTES - c->next) { status(err, CL_INVALID_BUFFER_SIZE); return NULL; }
    cl_mem m = malloc(sizeof(*m));
    if (m) {
        m->context = c; m->address = c->next; m->size = size;
        c->next += (size + 7) & ~(size_t)7;
        if (host) memcpy(c->memory + m->address, host, size);
    }
    status(err, m ? CL_SUCCESS : CL_OUT_OF_HOST_MEMORY);
    return m;
}
static cl_int transfer(cl_command_queue q, cl_mem m, size_t offset, size_t size, void *data, int write) {
    if (!q || !m || q->context != m->context || !data || offset > m->size || size > m->size - offset)
        return CL_INVALID_VALUE;
    if (write) memcpy(m->context->memory + m->address + offset, data, size);
    else memcpy(data, m->context->memory + m->address + offset, size);
    return CL_SUCCESS;
}
cl_int clEnqueueWriteBuffer(cl_command_queue q, cl_mem m, cl_bool blocking, size_t offset, size_t size,
        const void *data, cl_uint n, const cl_event *wait, cl_event *event) {
    (void)blocking;
    if (n || wait || event) return CL_INVALID_EVENT_WAIT_LIST;
    return transfer(q, m, offset, size, (void *)data, 1);
}
cl_int clEnqueueReadBuffer(cl_command_queue q, cl_mem m, cl_bool blocking, size_t offset, size_t size,
        void *data, cl_uint n, const cl_event *wait, cl_event *event) {
    (void)blocking;
    if (n || wait || event) return CL_INVALID_EVENT_WAIT_LIST;
    return transfer(q, m, offset, size, data, 0);
}
cl_program clCreateProgramWithSource(cl_context c, cl_uint count, const char **strings, const size_t *lengths, cl_int *err) {
    if (!c || count != 1 || !strings || !strings[0]) { status(err, CL_INVALID_VALUE); return NULL; }
    cl_program p = calloc(1, sizeof(*p));
    size_t size = lengths && lengths[0] ? lengths[0] : strlen(strings[0]);
    if (p) p->source = malloc(size + 1);
    if (!p || !p->source) { free(p); status(err, CL_OUT_OF_HOST_MEMORY); return NULL; }
    memcpy(p->source, strings[0], size); p->source[size] = 0; p->context = c;
    status(err, CL_SUCCESS);
    return p;
}
cl_int clBuildProgram(cl_program p, cl_uint count, const cl_device_id *devices, const char *options,
        void (CL_CALLBACK *notify)(cl_program, void *), void *data) {
    (void)count; (void)devices; (void)data;
    if (!p) return CL_INVALID_PROGRAM;
    if ((options && *options) || notify) return CL_INVALID_BUILD_OPTIONS;
    // Compilation is deferred until enqueue, when NDRange configuration is known.
    p->built = 1;
    return CL_SUCCESS;
}
cl_kernel clCreateKernel(cl_program p, const char *name, cl_int *err) {
    if (!p || !p->built || !name || !*name) { status(err, CL_INVALID_KERNEL_NAME); return NULL; }
    cl_kernel k = calloc(1, sizeof(*k));
    if (k) k->program = p;
    status(err, k ? CL_SUCCESS : CL_OUT_OF_HOST_MEMORY);
    return k;
}
cl_int clSetKernelArg(cl_kernel k, cl_uint index, size_t size, const void *value) {
    if (!k || index >= MAX_ARGS || !value) return CL_INVALID_ARG_VALUE;
    uint32_t data;
    if (size == sizeof(cl_mem)) {
        cl_mem m; memcpy(&m, value, sizeof(m));
        if (!m || m->context != k->program->context) return CL_INVALID_MEM_OBJECT;
        data = (uint32_t)m->address;
    } else if (size == sizeof(uint32_t)) memcpy(&data, value, sizeof(data));
    else return CL_INVALID_ARG_SIZE;
    k->args[index] = data; k->set[index] = 1;
    if (index + 1 > k->count) k->count = index + 1;
    return CL_SUCCESS;
}
static int execute_simulator(void) {
    const char *runner = getenv("FPGAGPU_SIM_RUNNER");
    if (!runner) return -1;
    pid_t child = fork();
    if (child == 0) { execl("/bin/bash", "bash", runner, (char *)NULL); _exit(127); }
    if (child < 0) return -1;
    int code;
    while (waitpid(child, &code, 0) < 0) { if (errno != EINTR) return -1; }
    return WIFEXITED(code) ? WEXITSTATUS(code) : -1;
}
cl_int clEnqueueNDRangeKernel(cl_command_queue q, cl_kernel k, cl_uint dims, const size_t *offset,
        const size_t *global, const size_t *local, cl_uint n, const cl_event *wait, cl_event *event) {
    if (!q || !k || q->context != k->program->context) return CL_INVALID_CONTEXT;
    if ((dims != 1 && dims != 2) || !global || !local) return CL_INVALID_WORK_DIMENSION;
    size_t global_y = dims == 2 ? global[1] : 1;
    size_t local_y = dims == 2 ? local[1] : 1;
    if (offset && (offset[0] || (dims == 2 && offset[1]))) return CL_INVALID_GLOBAL_OFFSET;
    if (n || wait || event) return CL_INVALID_EVENT_WAIT_LIST;
    if (local[0] != 2 || local_y != 1) return CL_INVALID_WORK_GROUP_SIZE;
    if (!global[0] || !global_y || global[0] % 2 || global[0] > 131070 || global_y > 65535)
        return CL_INVALID_GLOBAL_WORK_SIZE;
    for (unsigned i = 0; i < k->count; i++) {
        if (!k->set[i]) return CL_INVALID_KERNEL_ARGS;
        for (unsigned lane = 0; lane < 2; lane++)
            for (unsigned b = 0; b < 4; b++) q->context->memory[i*8+lane*4+b] = (unsigned char)(k->args[i] >> (b*8));
    }
    FILE *f = fopen("kernel.c", "w");
    if (!f) return CL_OUT_OF_RESOURCES;
    int failed = fprintf(f, "#include \"device_intrinsics.h\"\n%s", k->program->source) < 0;
    failed |= fclose(f) != 0;
    if (failed) return CL_OUT_OF_RESOURCES;
    f = fopen("memory.hex", "w");
    if (!f) return CL_OUT_OF_RESOURCES;
    for (size_t addr = 0; addr < MEMORY_BYTES; addr += 8) {
        uint64_t word = 0;
        for (unsigned b = 0; b < 8; b++) word |= (uint64_t)q->context->memory[addr+b] << (b*8);
        if (fprintf(f, "%016llx\n", (unsigned long long)word) < 0) failed = 1;
    }
    failed |= fclose(f) != 0;
    f = fopen("gpc_config.txt", "w");
    if (!f) return CL_OUT_OF_RESOURCES;
    // AXI-Lite host configuration: grid X/Y, block X/Y, src/dst registers.
    if (fprintf(f, "%zu %zu %zu %zu 0 0\n", global[0]/local[0], global_y/local_y, local[0], local_y) < 0) failed = 1;
    failed |= fclose(f) != 0;
    if (failed || execute_simulator()) return CL_OUT_OF_RESOURCES;
    f = fopen("memory.bin", "rb");
    if (!f) return CL_OUT_OF_RESOURCES;
    failed = fread(q->context->memory, 1, MEMORY_BYTES, f) != MEMORY_BYTES;
    failed |= fgetc(f) != EOF;
    failed |= fclose(f) != 0;
    return failed ? CL_OUT_OF_RESOURCES : CL_SUCCESS;
}
cl_int clFinish(cl_command_queue q) { return q ? CL_SUCCESS : CL_INVALID_COMMAND_QUEUE; }
cl_int clReleaseKernel(cl_kernel k) { free(k); return CL_SUCCESS; }
cl_int clReleaseProgram(cl_program p) { if (p) { free(p->source); free(p); } return CL_SUCCESS; }
cl_int clReleaseMemObject(cl_mem m) { free(m); return CL_SUCCESS; }
cl_int clReleaseCommandQueue(cl_command_queue q) { free(q); return CL_SUCCESS; }
cl_int clReleaseContext(cl_context c) { free(c); return CL_SUCCESS; }
