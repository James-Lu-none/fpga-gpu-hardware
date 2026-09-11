`timescale 1ns / 1ps

package gpu_pkg;
    // Architecture Hierarchy Parameters (N, M, K)
    parameter NUM_SMS = 2;
    parameter NUM_SUB_PARTITIONS = 1;
    parameter NUM_LANES = 2;

    // Derived & Microarchitectural Parameters
    parameter DATA_W = 32 * NUM_LANES; // Vector datapath width (bits)
    parameter MAX_WARPS = 8;
    parameter NUM_REGS = 32;
    parameter IRAM_DEPTH = 1024;
    parameter WARP_SIZE = 32;
endpackage
