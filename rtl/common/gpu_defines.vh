`ifndef GPU_DEFINES_VH
`define GPU_DEFINES_VH

`include "gpu_debug.vh"

// =============================================================================
// GPU Global Architecture Definitions & Parameters
// =============================================================================

// Architecture Version
`define HW_VERSION_MAJOR            8'd3
`define HW_VERSION_MINOR            8'd0

// Architecture Hierarchy Parameters (N, M, K)
`define NUM_SMS                     1
`define NUM_SUB_PARTITIONS          4
`define NUM_SPS                     4
`define NUM_LANES                   16

// Bit Widths & Microarchitectural Dimensions
`define LANE_DATA_W                 32
`define WARP_DATA_W                 (32 * `NUM_LANES)
`define DATA_W_L1                   256
`define STRB_W_L1                   (`DATA_W_L1 / 8)
`define DATA_W                      `WARP_DATA_W
`define MAX_WARPS                   8
`define NUM_REGS                    32
`define IRAM_DEPTH                  1024
`define WARP_SIZE                   `NUM_LANES

// Performance Counter Indices (32-bit GPC-wide, AXI-Lite 0x30 + index*4)
`define PERF_COUNT                  14
`define PERF_CYCLE                  0
`define PERF_INST_RETIRED           1
`define PERF_WARP_ISSUE             2
`define PERF_L1_REQ                 3
`define PERF_L1_HIT                 4
`define PERF_L1_MISS                5
`define PERF_L2_REQ                 6
`define PERF_L2_HIT                 7
`define PERF_L2_MISS                8
`define PERF_LSU_WAIT_CYCLES        9
`define PERF_LSU_FIFO_FULL_CYCLES   10
`define PERF_AXI_READ_STALL_CYCLES  11
`define PERF_AXI_WRITE_STALL_CYCLES 12
`define PERF_WARP_DONE              13

`endif // GPU_DEFINES_VH

