`timescale 1ns / 1ps

package address_pkg;
    // 1. RISC-V Local BRAM (Instruction/Data/Mailbox) 
    // Base Address Region: 0x0000_0000 ~ 0x0001_FFFF (128KB)
    localparam logic [31:0] ADDR_BASE_BRAM = 32'h0000_0000;
    
    localparam logic [31:0] BRAM_PROGADDR_RESET = 32'h0000_0000;
    localparam logic [31:0] BRAM_PROGADDR_IRQ   = 32'h0000_0010;
    localparam logic [31:0] BRAM_STACKADDR      = 32'h0001_0000;
    
    localparam logic [31:0] BRAM_RING_BUFFER_BASE = 32'h0001_8000;

    // 1b. Control Registers (AXI-Lite Peripheral)
    // Base Address Region: 0x0002_0000
    localparam logic [31:0] CTRL_REG_BASE       = 32'h0002_0000;
    localparam logic [31:0] CTRL_REG_IRQ        = CTRL_REG_BASE + 32'h00;
    localparam logic [31:0] CTRL_REG_CPU_RESET  = CTRL_REG_BASE + 32'h04;

    // 2. Graphics Processing Cluster (GPC / SM)
    // Base Address Region: 0x1000_XXXX
    localparam logic [31:0] ADDR_BASE_GPC = 32'h1000_0000;
    
    localparam logic [31:0] GPC_IRAM_OFFSET  = 32'h0000_1000;
    localparam logic [31:0] GPC_IRAM_BASE    = ADDR_BASE_GPC + GPC_IRAM_OFFSET;

    // 3. Simple AXI-Lite UART
    // Base Address Region: 0x2000_XXXX
    localparam logic [31:0] ADDR_BASE_UART = 32'h2000_0000;

    // 4. DDR4 / Main System Memory
    // Base Address Region: 0x8000_XXXX
    localparam logic [31:0] ADDR_BASE_DDR4 = 32'h8000_0000;
endpackage
