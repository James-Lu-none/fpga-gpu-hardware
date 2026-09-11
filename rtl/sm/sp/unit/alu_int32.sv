`timescale 1ns / 1ps
// ALU (Arithmetic Logic Unit)
// 
// ALU is instantiated in processing_block.sv
// currently it only supports integer arithmetic (ADD, SUB, MUL) 
// and logical operations for all active threads in a warp. 
// It processes multiple lanes in parallel
//

import gpu_pkg::*;

module alu_int32 (
    input wire clk,
    input wire rst_n,

    // Operand Interface
    operand_if.slave op,

    // Write-Back Interface (To vector_regfile)
    wb_if.master wb,

    // To PC module
    output wire alu_updates_nzp,
    output wire [2:0] next_nzp0,
    output wire [2:0] next_nzp1,
    output wire is_exit,
    output wire is_branch,
    output wire is_sync
);

    // Opcodes Definition
    localparam OP_ADD = 8'h01;
    localparam OP_SUB = 8'h02;
    localparam OP_MUL = 8'h03;
    localparam OP_CMP = 8'h04;
    localparam OP_ADDI = 8'h81;
    localparam OP_S2R = 8'hB0;
    localparam OP_BR = 8'hC0;
    localparam OP_SYNC = 8'hE0;
    localparam OP_EXIT = 8'hFF;

    // ALU Combinational Logic
    wire [31:0] lane0_rs1 = op.rs1_data[31:0];
    wire [31:0] lane1_rs1 = op.rs1_data[63:32];
    
    wire [31:0] lane0_rs2 = op.is_imm ? op.imm : op.rs2_data[31:0];
    wire [31:0] lane1_rs2 = op.is_imm ? op.imm : op.rs2_data[63:32];

    // originally, we did too much work in the same clock cycle:
    // decode opcode 
    // -> perform arithmetic execution, send result to comparator to check if result is zero or negative and generate NZP code 
    // -> send to PC module 
    // -> write to warp_nzp_reg
    // so we separate arithmetic execution from other pipeline stages. 
    // This is because arithmetic execution (especially multiplication) 
    // is very time consuming and will make the critical path too long.
    // So we seperate Arithmetic Execution and NZP computation into two pipeline stages. 
    
    // Execution Stage 1: Arithmetic Execution (Pipelined to break DSP critical path)
    reg [31:0] ex1_add0, ex1_add1;
    reg [31:0] ex1_sub0, ex1_sub1;
    reg [31:0] ex1_mul0, ex1_mul1;
    
    reg ex1_valid;
    reg [7:0] ex1_opcode;
    reg [31:0] ex1_imm;
    reg [15:0] ex1_tid, ex1_bid_x, ex1_bid_y;
    reg [4:0] ex1_rd;
    reg [3:0] ex1_warp_id;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex1_valid <= 1'b0;
        end else begin
            ex1_valid <= op.valid;
            ex1_opcode <= op.opcode;
            ex1_imm <= op.imm;
            ex1_tid <= op.thread_id_start;
            ex1_bid_x <= op.block_idx_x;
            ex1_bid_y <= op.block_idx_y;
            ex1_rd <= op.rd;
            ex1_warp_id <= op.warp_id;
            
            // Vivado will push these registers directly into the DSP/Adder blocks
            // which cuts the 10-level logic path in half
            ex1_add0 <= lane0_rs1 + lane0_rs2;
            ex1_add1 <= lane1_rs1 + lane1_rs2;
            
            ex1_sub0 <= lane0_rs1 - lane0_rs2;
            ex1_sub1 <= lane1_rs1 - lane1_rs2;
            
            ex1_mul0 <= lane0_rs1 * lane0_rs2;
            ex1_mul1 <= lane1_rs1 * lane1_rs2;
        end
    end

    // Execution Stage 2: MUXing, Condition Codes (NZP), and Write-Back
    reg [31:0] alu0_out;
    reg [31:0] alu1_out;
    reg alu_writes_reg;
    reg _alu_updates_nzp;
    reg _is_exit;
    reg _is_branch;
    reg _is_sync;
    
    always @(*) begin
        alu0_out = 32'd0;
        alu1_out = 32'd0;
        alu_writes_reg = 1'b0;
        _alu_updates_nzp = 1'b0;
        _is_exit = 1'b0;
        _is_branch = 1'b0;
        _is_sync = 1'b0;

        case (ex1_opcode)
            OP_ADD, OP_ADDI: begin
                alu0_out = ex1_add0;
                alu1_out = ex1_add1;
                alu_writes_reg = 1'b1;
                _alu_updates_nzp = 1'b1;
            end
            OP_SUB, OP_CMP: begin
                alu0_out = ex1_sub0;
                alu1_out = ex1_sub1;
                alu_writes_reg = (ex1_opcode == OP_SUB);
                _alu_updates_nzp = 1'b1;
            end
            OP_MUL: begin
                alu0_out = ex1_mul0;
                alu1_out = ex1_mul1;
                alu_writes_reg = 1'b1;
                _alu_updates_nzp = 1'b0; // Disable NZP for MUL
            end
            OP_S2R: begin
                alu_writes_reg = 1'b1;
                case (ex1_imm)
                    32'd0: begin alu0_out = ex1_tid; alu1_out = ex1_tid + 32'd1; end
                    32'd1: begin alu0_out = 32'd0; alu1_out = 32'd0; end
                    32'd2: begin alu0_out = ex1_bid_x; alu1_out = ex1_bid_x; end
                    32'd3: begin alu0_out = ex1_bid_y; alu1_out = ex1_bid_y; end
                    default: begin alu0_out = 32'd0; alu1_out = 32'd0; end
                endcase
            end
            OP_BR:   _is_branch = 1'b1;
            OP_SYNC: _is_sync = 1'b1;
            OP_EXIT: _is_exit = 1'b1;
            default: ;
        endcase
    end

    // Drive PC module signals based on EX2 valid
    assign alu_updates_nzp = _alu_updates_nzp && ex1_valid;
    assign is_exit = _is_exit && ex1_valid;
    assign is_branch = _is_branch && ex1_valid;
    assign is_sync = _is_sync && ex1_valid;

    // Timing Optimization: Only ADD/SUB/CMP evaluate NZP
    wire [31:0] nzp_eval0 = (_alu_updates_nzp) ? alu0_out : 32'hFFFFFFFF;
    wire next_n0 = nzp_eval0[31];
    wire next_z0 = (nzp_eval0 == 32'd0);
    wire next_p0 = (!next_n0 && !next_z0);
    assign next_nzp0 = {next_n0, next_z0, next_p0};

    wire [31:0] nzp_eval1 = (_alu_updates_nzp) ? alu1_out : 32'hFFFFFFFF;
    wire next_n1 = nzp_eval1[31];
    wire next_z1 = (nzp_eval1 == 32'd0);
    wire next_p1 = (!next_n1 && !next_z1);
    assign next_nzp1 = {next_n1, next_z1, next_p1};

    // Execution Stage 3: Write-Back Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb.valid <= 1'b0;
        end else begin
            wb.valid <= 1'b0;
            if (ex1_valid) begin
                if (alu_writes_reg && (ex1_rd != 5'd0)) begin
                    wb.valid <= 1'b1;
                    wb.warp_id <= ex1_warp_id;
                    wb.rd <= ex1_rd;
                    wb.data <= {alu1_out, alu0_out};
                    wb.mask <= 32'hFFFFFFFF;
                end
            end
        end
    end

endmodule
