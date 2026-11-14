`timescale 1ns / 1ps
// One synchronous instruction read and one loader write, with no reset.

`include "gpu_defines.vh"

module instruction_ram (
    input wire clk,
    input wire write_enable,
    input wire [11:0] write_address,
    input wire [31:0] write_data,
    input wire [11:0] read_address,
    output reg [31:0] read_data
);
    localparam integer DEPTH = `IRAM_DEPTH;
    (* ram_style = "block" *) reg [31:0] words [0:DEPTH-1];
    localparam integer RAM_ADDR_W = $clog2(DEPTH);
    always @(posedge clk) begin
        if (write_enable) words[write_address[RAM_ADDR_W-1:0]] <= write_data;
        read_data <= words[read_address[RAM_ADDR_W-1:0]];
    end
endmodule
