`timescale 1ns / 1ps

`include "gpu_debug.vh"

package gpu_pkg;
    // Architecture Version Parameters
    localparam bit [7:0] HW_VERSION_MAJOR = 8'd3;
    localparam bit [7:0] HW_VERSION_MINOR = 8'd0;

    // Architecture Hierarchy Parameters (N, M, K)
    parameter NUM_SMS = 2;
    parameter NUM_SUB_PARTITIONS = 4;
    parameter NUM_LANES = 16;

    // Derived & Microarchitectural Parameters
    parameter DATA_W = 32 * NUM_LANES; // Vector datapath width (bits)
    parameter MAX_WARPS = 8;
    parameter NUM_REGS = 32;
    parameter IRAM_DEPTH = 1024;
    parameter WARP_SIZE = NUM_LANES;
    
    // 32-bit GPC-wide performance counters, AXI-Lite 0x30 + index*4.
    localparam PERF_COUNT = 14;
    localparam PERF_CYCLE = 0;
    localparam PERF_INST_RETIRED = 1;
    localparam PERF_WARP_ISSUE = 2;
    localparam PERF_L1_REQ = 3;
    localparam PERF_L1_HIT = 4;
    localparam PERF_L1_MISS = 5;
    localparam PERF_L2_REQ = 6;
    localparam PERF_L2_HIT = 7;
    localparam PERF_L2_MISS = 8;

    localparam PERF_LSU_WAIT_CYCLES = 9;
    localparam PERF_LSU_FIFO_FULL_CYCLES = 10;
    localparam PERF_AXI_READ_STALL_CYCLES = 11;
    localparam PERF_AXI_WRITE_STALL_CYCLES = 12;
    localparam PERF_WARP_DONE = 13;
endpackage
