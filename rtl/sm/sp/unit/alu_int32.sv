`timescale 1ns / 1ps
// Combinational 32-bit scalar lane.
// fn: 0 ADD, 1 SUB, 2 MUL (low 32), 4 AND, 5 OR, 6 XOR, 7 SETCC.
// ISA decode, immediates, S2R, warp metadata and pipeline registers belong to SP.
module alu_int32 (
    input wire [2:0] fn,
    input wire [31:0] a, b,
    output reg [31:0] result,
    output wire [2:0] nzp
);
    wire signed [31:0] s_a = a;
    wire signed [31:0] s_b = b;

    always @(*) begin
        case (fn)
            3'd0: result = a + b;
            3'd1: result = a - b;
            3'd2: result = a * b;
            3'd4: result = a & b;
            3'd5: result = a | b;
            3'd6: result = a ^ b;
            3'd7: result = (s_a < s_b) ? 32'd1 : 32'd0;
            default: result = 32'd0;
        endcase
    end
    assign nzp = {result[31], result == 0, !result[31] && result != 0};
endmodule
