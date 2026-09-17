`timescale 1ns / 1ps
// Company: 
// Engineer: 
// Create Date: 2026/08/26
// Design Name: Standard AMBA AXI4 SystemVerilog Interface Package
// Module Name: axi_if
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel fpgagpu-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
// Standard SystemVerilog AXI4 Bus Interface Bundle to simplify inter-module
// AXI bus connections (XDMA, Crossbar, MIG DDR3, GPGPU SM Compute Engine).

interface axi4_if #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 256,
    parameter integer ID_W = 1
);
    // Write Address Channel
    logic [ID_W-1:0] awid; // Write address ID
    logic [ADDR_W-1:0] awaddr; // Write address
    logic [7:0] awlen; // Burst length
    logic [2:0] awsize; // Burst size
    logic [1:0] awburst; // Burst type
    logic awlock; // Lock type
    logic [3:0] awcache; // Memory type
    logic [2:0] awprot; // Protection type
    logic [3:0] awqos; // Quality of Service
    logic [3:0] awregion; // Region identifier
    logic awvalid; // Write address valid
    logic awready; // Write address ready

    // Write Data Channel
    logic [DATA_W-1:0] wdata; // Write data
    logic [(DATA_W/8)-1:0] wstrb; // Write strobes
    logic wlast; // Write last
    logic wvalid; // Write valid
    logic wready; // Write ready

    // Write Response Channel
    logic [ID_W-1:0] bid; // Response ID
    logic [1:0] bresp; // Write response
    logic bvalid; // Write response valid
    logic bready; // Response ready

    // Read Address Channel
    logic [ID_W-1:0] arid; // Read address ID
    logic [ADDR_W-1:0] araddr; // Read address
    logic [7:0] arlen; // Burst length
    logic [2:0] arsize; // Burst size
    logic [1:0] arburst; // Burst type
    logic arlock; // Lock type
    logic [3:0] arcache; // Memory type
    logic [2:0] arprot; // Protection type
    logic [3:0] arqos; // Quality of Service
    logic [3:0] arregion; // Region identifier
    logic arvalid; // Read address valid
    logic arready; // Read address ready

    // Read Data Channel
    logic [ID_W-1:0] rid; // Read ID tag
    logic [DATA_W-1:0] rdata; // Read data
    logic [1:0] rresp; // Read response
    logic rlast; // Read last
    logic rvalid; // Read valid
    logic rready; // Read ready

    // Master Modport (For Drivers / Masters like XDMA & GPGPU Core)
    modport master (
        output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awvalid,
        input awready,
        output wdata, wstrb, wlast, wvalid,
        input wready,
        input bid, bresp, bvalid,
        output bready,
        output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, arvalid,
        input arready,
        input rid, rdata, rresp, rlast, rvalid,
        output rready
    );

    // Slave Modport (For Receivers / Slaves like Crossbar & MIG DDR3)
    modport slave (
        input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awvalid,
        output awready,
        input wdata, wstrb, wlast, wvalid,
        output wready,
        output bid, bresp, bvalid,
        input bready,
        input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, arvalid,
        output arready,
        output rid, rdata, rresp, rlast, rvalid,
        input rready
    );

endinterface

interface axi_lite_if #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 32
);
    // Write Address Channel
    logic [ADDR_W-1:0] awaddr; // Write address
    logic [2:0] awprot; // Protection type
    logic awvalid; // Write address valid
    logic awready; // Write address ready

    // Write Data Channel
    logic [DATA_W-1:0] wdata; // Write data
    logic [(DATA_W/8)-1:0] wstrb; // Write strobes
    logic wvalid; // Write valid
    logic wready; // Write ready

    // Write Response Channel
    logic [1:0] bresp; // Write response
    logic bvalid; // Write response valid
    logic bready; // Response ready

    // Read Address Channel
    logic [ADDR_W-1:0] araddr; // Read address
    logic [2:0] arprot; // Protection type
    logic arvalid; // Read address valid
    logic arready; // Read address ready

    // Read Data Channel
    logic [DATA_W-1:0] rdata; // Read data
    logic [1:0] rresp; // Read response
    logic rvalid; // Read valid
    logic rready; // Read ready

    // Master Modport
    modport master (
        output awaddr, awprot, awvalid,
        input awready,
        output wdata, wstrb, wvalid,
        input wready,
        input bresp, bvalid,
        output bready,
        output araddr, arprot, arvalid,
        input arready,
        input rdata, rresp, rvalid,
        output rready
    );

    // Slave Modport
    modport slave (
        input awaddr, awprot, awvalid,
        output awready,
        input wdata, wstrb, wvalid,
        output wready,
        output bresp, bvalid,
        input bready,
        input araddr, arprot, arvalid,
        output arready,
        output rdata, rresp, rvalid,
        input rready
    );

endinterface
