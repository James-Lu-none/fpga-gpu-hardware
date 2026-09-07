# -------------------------------------------------------------------------
# Primary Clocks
# -------------------------------------------------------------------------
# we need to tell vivado that sys_clk_p is a clock
# otherwise we will get critical warning like:
# [Timing 38-472] The REFCLK pin of IDELAYCTRL u_mig_ddr3/u_mig_7series_0_mig/u_iodelay_ctrl/u_idelayctrl_200 is not reached by any clock but IDELAYE2 u_mig_ddr3/u_mig_7series_0_mig/u_memc_ui_top_axi/mem_intfc0/ddr_phy_top0/u_ddr_mc_phy_wrapper/u_ddr_mc_phy/ddr_phy_4lanes_0.u_ddr_phy_4lanes/ddr_byte_lane_A.ddr_byte_lane_A/ddr_byte_group_io/input_[0].iserdes_dq_.idelay_dq.idelaye2 has REFCLK_FREQUENCY of 200.000 Mhz (period 5.000 ns). The IDELAYCTRL REFCLK pin frequency must match the IDELAYE2 REFCLK_FREQUENCY property value.

# set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
# set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
# set_property PACKAGE_PIN T4 [get_ports sys_clk_n]
# create_clock -period 5.000 -name ddr3_sys_clk [get_ports sys_clk_p]

# -------------------------------------------------------------------------
# Asynchronous Clock Domain Crossing (CDC) Timing Constraints
# -------------------------------------------------------------------------
# Note: AXI CDC IPs handle their own synchronization internally.


# Ignore recovery/removal timing on the HDMI asynchronous reset synchronizer
set_false_path -to [get_pins -quiet u_hdmi/clk_pix_rst_sync_reg[*]/CLR]

# Configuration Voltage
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# [Labtools 27-3347] Flash Programming Unsuccessful: Byte 8805306 does not match (56 != 00) Verify that the selected flash part matches the actual flash device connected to the board. Resolution: Verify the correct flash type is selected in the hardware manager. A mismatch between the selected flash part and the detected flash device will cause initialization to fail.
# resolved with following configuration
# set flash bus width to 4 bits
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
# set flash to use 4 data pins
set_property CONFIG_MODE SPIx4 [current_design]
# set flash read clock frequency to 50 MHz for faster boot (important for PCIe)
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
# enable SPI_FALL_EDGE for better high-speed stability
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
# since flash fails at about 8MB everytime, so we enable compression to make bitstream smaller
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# UART
set_property PACKAGE_PIN L14 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]
set_property PACKAGE_PIN L15 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

# KEYs
set_property PACKAGE_PIN F15 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]
set_property PACKAGE_PIN L19 [get_ports key1]
set_property IOSTANDARD LVCMOS33 [get_ports key1]
set_property PACKAGE_PIN L20 [get_ports key2]
set_property IOSTANDARD LVCMOS33 [get_ports key2]
set_property PACKAGE_PIN K17 [get_ports key3]
set_property IOSTANDARD LVCMOS33 [get_ports key3]
set_property PACKAGE_PIN J17 [get_ports key4]
set_property IOSTANDARD LVCMOS33 [get_ports key4]

# LEDs
set_property PACKAGE_PIN L13 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led1]
set_property PACKAGE_PIN M13 [get_ports led2]
set_property IOSTANDARD LVCMOS33 [get_ports led2]
set_property PACKAGE_PIN K14 [get_ports led3]
set_property IOSTANDARD LVCMOS33 [get_ports led3]
set_property PACKAGE_PIN K13 [get_ports led4]
set_property IOSTANDARD LVCMOS33 [get_ports led4]
