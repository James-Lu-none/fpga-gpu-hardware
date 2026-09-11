`timescale 1ns / 1ps

import gpu_pkg::*;

interface warp_alloc_if;
    logic valid;
    logic [15:0] block_id;
    logic [15:0] block_idx_x;
    logic [15:0] block_idx_y;
    logic [15:0] thread_id_start;
    logic [31:0] active_mask;
    logic ready;
    logic [4:0] available_slots;
    
    modport master (
        output valid, block_id, block_idx_x, block_idx_y, thread_id_start, active_mask,
        input  ready, available_slots
    );
    modport slave (
        input  valid, block_id, block_idx_x, block_idx_y, thread_id_start, active_mask,
        output ready, available_slots
    );
endinterface

interface issue_if;
    logic valid;
    logic [$clog2(MAX_WARPS)-1:0] warp_id;
    logic [11:0] pc;
    logic [31:0] active_mask;
    logic [15:0] block_idx_x;
    logic [15:0] block_idx_y;
    logic [15:0] thread_id_start;
    
    modport master (output valid, warp_id, pc, active_mask, block_idx_x, block_idx_y, thread_id_start);
    modport slave  (input  valid, warp_id, pc, active_mask, block_idx_x, block_idx_y, thread_id_start);
endinterface

interface decode_if;
    logic valid;
    logic [$clog2(MAX_WARPS)-1:0] warp_id;
    logic [11:0] pc;
    logic [31:0] active_mask;
    logic [15:0] block_idx_x;
    logic [15:0] block_idx_y;
    logic [15:0] thread_id_start;
    
    logic [7:0] opcode;
    logic [4:0] rd;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [31:0] imm;
    logic is_imm;
    
    modport master (
        output valid, warp_id, pc, active_mask, block_idx_x, block_idx_y, thread_id_start,
        output opcode, rd, rs1, rs2, imm, is_imm
    );
    modport slave (
        input  valid, warp_id, pc, active_mask, block_idx_x, block_idx_y, thread_id_start,
        input  opcode, rd, rs1, rs2, imm, is_imm
    );
endinterface

interface operand_if;
    logic valid;
    logic [$clog2(MAX_WARPS)-1:0] warp_id;
    logic [11:0] pc;
    logic [31:0] active_mask;
    logic [15:0] block_idx_x;
    logic [15:0] block_idx_y;
    logic [15:0] thread_id_start;
    
    logic [7:0] opcode;
    logic [4:0] rd;
    logic [31:0] imm;
    logic is_imm;
    
    logic [DATA_W-1:0] rs1_data;
    logic [DATA_W-1:0] rs2_data;
    
    modport master (
        output valid, warp_id, pc, active_mask, block_idx_x, block_idx_y, thread_id_start,
        output opcode, rd, imm, is_imm, rs1_data, rs2_data
    );
    modport slave (
        input  valid, warp_id, pc, active_mask, block_idx_x, block_idx_y, thread_id_start,
        input  opcode, rd, imm, is_imm, rs1_data, rs2_data
    );
endinterface

interface wb_if;
    logic valid;
    logic [$clog2(MAX_WARPS)-1:0] warp_id;
    logic [4:0] rd;
    logic [DATA_W-1:0] data;
    logic [31:0] mask;
    
    modport master (output valid, warp_id, rd, data, mask);
    modport slave  (input  valid, warp_id, rd, data, mask);
endinterface

interface ctx_wb_if;
    logic valid;
    logic [$clog2(MAX_WARPS)-1:0] warp_id;
    logic [11:0] next_pc;
    logic is_done;
    logic is_divergent;
    logic [31:0] taken_mask;
    logic [31:0] not_taken_mask;
    logic is_sync;
    
    modport master (
        output valid, warp_id, next_pc, is_done, is_divergent, 
        output taken_mask, not_taken_mask, is_sync
    );
    modport slave (
        input  valid, warp_id, next_pc, is_done, is_divergent, 
        input  taken_mask, not_taken_mask, is_sync
    );
endinterface
