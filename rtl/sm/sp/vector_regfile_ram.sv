`timescale 1ns / 1ps
// One synchronous read and one write port for one 32-bit VRF lane.
// Keep each inferred memory in its own module, with full-word writes and
// independent clocked read/write processes. RAM and read data have no reset.
module vector_regfile_ram #(
    parameter integer DEPTH = 256,
    parameter integer ADDR_W = $clog2(DEPTH)
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
    end
    always @(posedge clk) begin
        read_data <= words[read_address];
    end
endmodule
