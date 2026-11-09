`timescale 1ns / 1ps
// One synchronous instruction read and one loader write, with no reset.
module instruction_ram #(
    parameter integer DEPTH = gpu_pkg::IRAM_DEPTH,
    parameter integer ADDR_W = 12
)(
    input wire clk,
    input wire write_enable,
    input wire [ADDR_W-1:0] write_address,
    input wire [31:0] write_data,
    input wire [ADDR_W-1:0] read_address,
    output reg [31:0] read_data
);
    (* ram_style = "block" *) reg [31:0] words [0:DEPTH-1];
    always @(posedge clk) begin
        if (write_enable) words[write_address] <= write_data;
        read_data <= words[read_address];
    end
endmodule
