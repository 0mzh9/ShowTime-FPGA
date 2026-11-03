// Created by IP Generator (Version 2022.2-SP6.4 build 146967)
// Instantiation Template
//
// Insert the following codes into your Verilog file.
//   * Change the_instance_name to your own instance name.
//   * Change the signal names in the port associations


wr_fram_buf the_instance_name (
  .wr_data(wr_data),    // 输入 [31:0]
  .wr_addr(wr_addr),    // 输入 [11:0]
  .wr_en(wr_en),        // 输入
  .wr_clk(wr_clk),      // 输入
  .wr_rst(wr_rst),      // 输入
  .rd_addr(rd_addr),    // 输入 [8:0]
  .rd_data(rd_data),    // 输出 [255:0]
  .rd_clk(rd_clk),      // 输入
  .rd_rst(rd_rst)       // 输入
);
