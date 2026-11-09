`timescale 1ns / 1ps

module cache_line_ram #(
    parameter integer DATA_W = 256,
    parameter integer TAG_W = 21,
    parameter integer NUM_LINES = 64,
    parameter integer ADDR_W = $clog2(NUM_LINES)
)(
    input wire clk,
    input wire read_enable,
    input wire [ADDR_W-1:0] read_address,
    output reg [DATA_W-1:0] read_data,
    output reg [TAG_W-1:0] read_tag,
    input wire write_enable,
    input wire [ADDR_W-1:0] write_address,
    input wire [DATA_W-1:0] write_data,
    input wire [TAG_W-1:0] write_tag
);
    (* ram_style = "block" *) reg [DATA_W-1:0] data_words [0:NUM_LINES-1];
    (* ram_style = "block" *) reg [TAG_W-1:0] tag_words [0:NUM_LINES-1];
    always @(posedge clk) begin
        if (read_enable) begin
            read_data <= data_words[read_address];
            read_tag <= tag_words[read_address];
        end
        if (write_enable) begin
            data_words[write_address] <= write_data;
            tag_words[write_address] <= write_tag;
        end
    end
endmodule
