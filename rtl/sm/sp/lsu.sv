`timescale 1ns / 1ps
// LSU (Load/Store Unit)
//
// LSU handles all memory access instructions (LDR, STR). It is 
// "Decoupled" from the main ALU pipeline. This means when a warp executes 
// a memory instruction, it is offloaded to the LSU, and the main scheduler 
// can immediately issue instructions from OTHER warps, hiding memory latency.
//

import gpu_pkg::*;

module lsu (
    input wire clk,
    input wire rst_n,

    // Operand Interface (From Dispatcher / VRF)
    operand_if.slave op,
    output wire lsu_ready, // LSU can accept new instruction

    // L1 Cache Interface
    output reg l1_req_valid,
    output reg [31:0] l1_req_addr,
    output reg [63:0] l1_req_wdata,
    output reg l1_req_we,
    input wire l1_req_ready,

    input wire l1_rsp_valid,
    input wire [63:0] l1_rsp_rdata,

    // Write-Back Interface (To VRF and Context Scheduler)
    wb_if.master wb,
    ctx_wb_if.master ctx_wb
);

    localparam OP_LDR = 8'hA0;
    localparam OP_STR = 8'hA1;

    // We keep it simple: 1 active request at a time for this simple LSU
    // In a real GPU, M LSUs can track M outstanding requests using a scoreboard/MSHR.
    localparam STATE_IDLE = 1'b0;
    localparam STATE_WAIT = 1'b1;

    reg state;
    reg [$clog2(MAX_WARPS)-1:0] active_warp_id;
    reg [11:0] active_pc;
    reg [4:0] active_rd;
    reg is_load;

    assign lsu_ready = (state == STATE_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            is_load <= 1'b0;
            l1_req_valid <= 1'b0;
            l1_req_we <= 1'b0;
            
            wb.valid <= 1'b0;
            ctx_wb.valid <= 1'b0;
        end else begin
            // Default de-asserts
            wb.valid <= 1'b0;
            ctx_wb.valid <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    if (op.valid && lsu_ready) begin
                        if (op.opcode == OP_LDR || op.opcode == OP_STR) begin
                            l1_req_valid <= 1'b1;
                            l1_req_addr <= op.rs1_data[31:0]; // Use Lane 0 RS1 as Address
                            l1_req_wdata <= op.rs2_data; // Write data
                            l1_req_we <= (op.opcode == OP_STR);
                            
                            active_warp_id <= op.warp_id;
                            active_pc <= op.pc;
                            active_rd <= op.rd;
                            is_load <= (op.opcode == OP_LDR);
                            
                            state <= STATE_WAIT;
                        end
                    end
                end

                STATE_WAIT: begin
                    if (l1_req_valid && l1_req_ready) begin
                        l1_req_valid <= 1'b0; // Handshake complete
                    end
                    
                    if (l1_rsp_valid) begin
                        // L1 operation completed
                        if (is_load && (active_rd != 5'd0)) begin
                            wb.valid <= 1'b1;
                            wb.warp_id <= active_warp_id;
                            wb.rd <= active_rd;
                            wb.data <= l1_rsp_rdata;
                            
                            ctx_wb.valid <= 1'b1;
                            ctx_wb.warp_id <= active_warp_id;
                            ctx_wb.next_pc <= active_pc + 12'd1;
                        end else begin
                            // Store or dummy load
                            ctx_wb.valid <= 1'b1; // Still need to wake up the warp
                            ctx_wb.warp_id <= active_warp_id;
                            ctx_wb.next_pc <= active_pc + 12'd1;
                        end
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
