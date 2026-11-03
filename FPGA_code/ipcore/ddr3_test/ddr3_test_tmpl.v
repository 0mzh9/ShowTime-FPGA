// Created by IP Generator (Version 2022.2-SP6.4 build 146967)
// Instantiation Template
//
// Insert the following codes into your Verilog file.
//   * Change the_instance_name to your own instance name.
//   * Change the signal names in the port associations


ddr3_test the_instance_name (
  .resetn(resetn),                                      // 输入
  .core_clk(core_clk),                                  // 输出
  .pll_lock(pll_lock),                                  // 输出
  .phy_pll_lock(phy_pll_lock),                          // 输出
  .gpll_lock(gpll_lock),                                // 输出
  .rst_gpll_lock(rst_gpll_lock),                        // 输出
  .ddrphy_cpd_lock(ddrphy_cpd_lock),                    // 输出
  .ddr_init_done(ddr_init_done),                        // 输出
  .axi_awaddr(axi_awaddr),                              // 输入 [27:0]
  .axi_awuser_ap(axi_awuser_ap),                        // 输入
  .axi_awuser_id(axi_awuser_id),                        // 输入 [3:0]
  .axi_awlen(axi_awlen),                                // 输入 [3:0]
  .axi_awready(axi_awready),                            // 输出
  .axi_awvalid(axi_awvalid),                            // 输入
  .axi_wdata(axi_wdata),                                // 输入 [255:0]
  .axi_wstrb(axi_wstrb),                                // 输入 [31:0]
  .axi_wready(axi_wready),                              // 输出
  .axi_wusero_id(axi_wusero_id),                        // 输出 [3:0]
  .axi_wusero_last(axi_wusero_last),                    // 输出
  .axi_araddr(axi_araddr),                              // 输入 [27:0]
  .axi_aruser_ap(axi_aruser_ap),                        // 输入
  .axi_aruser_id(axi_aruser_id),                        // 输入 [3:0]
  .axi_arlen(axi_arlen),                                // 输入 [3:0]
  .axi_arready(axi_arready),                            // 输出
  .axi_arvalid(axi_arvalid),                            // 输入
  .axi_rdata(axi_rdata),                                // 输出 [255:0]
  .axi_rid(axi_rid),                                    // 输出 [3:0]
  .axi_rlast(axi_rlast),                                // 输出
  .axi_rvalid(axi_rvalid),                              // 输出
  .apb_clk(apb_clk),                                    // 输入
  .apb_rst_n(apb_rst_n),                                // 输入
  .apb_sel(apb_sel),                                    // 输入
  .apb_enable(apb_enable),                              // 输入
  .apb_addr(apb_addr),                                  // 输入 [7:0]
  .apb_write(apb_write),                                // 输入
  .apb_ready(apb_ready),                                // 输出
  .apb_wdata(apb_wdata),                                // 输入 [15:0]
  .apb_rdata(apb_rdata),                                // 输出 [15:0]
  .mem_cs_n(mem_cs_n),                                  // 输出
  .mem_rst_n(mem_rst_n),                                // 输出
  .mem_ck(mem_ck),                                      // 输出
  .mem_ck_n(mem_ck_n),                                  // 输出
  .mem_cke(mem_cke),                                    // 输出
  .mem_ras_n(mem_ras_n),                                // 输出
  .mem_cas_n(mem_cas_n),                                // 输出
  .mem_we_n(mem_we_n),                                  // 输出
  .mem_odt(mem_odt),                                    // 输出
  .mem_a(mem_a),                                        // 输出 [14:0]
  .mem_ba(mem_ba),                                      // 输出 [2:0]
  .mem_dqs(mem_dqs),                                    // 双向 [3:0]
  .mem_dqs_n(mem_dqs_n),                                // 双向 [3:0]
  .mem_dq(mem_dq),                                      // 双向 [31:0]
  .mem_dm(mem_dm),                                      // 输出 [3:0]
  .dbg_gate_start(dbg_gate_start),                      // 输入
  .dbg_cpd_start(dbg_cpd_start),                        // 输入
  .dbg_ddrphy_rst_n(dbg_ddrphy_rst_n),                  // 输入
  .dbg_gpll_scan_rst(dbg_gpll_scan_rst),                // 输入
  .samp_position_dyn_adj(samp_position_dyn_adj),        // 输入
  .init_samp_position_even(init_samp_position_even),    // 输入 [31:0]
  .init_samp_position_odd(init_samp_position_odd),      // 输入 [31:0]
  .wrcal_position_dyn_adj(wrcal_position_dyn_adj),      // 输入
  .init_wrcal_position(init_wrcal_position),            // 输入 [31:0]
  .force_read_clk_ctrl(force_read_clk_ctrl),            // 输入
  .init_slip_step(init_slip_step),                      // 输入 [15:0]
  .init_read_clk_ctrl(init_read_clk_ctrl),              // 输入 [11:0]
  .debug_calib_ctrl(debug_calib_ctrl),                  // 输出 [33:0]
  .dbg_slice_status(dbg_slice_status),                  // 输出 [67:0]
  .dbg_slice_state(dbg_slice_state),                    // 输出 [87:0]
  .debug_data(debug_data),                              // 输出 [275:0]
  .dbg_dll_upd_state(dbg_dll_upd_state),                // 输出 [1:0]
  .debug_gpll_dps_phase(debug_gpll_dps_phase),          // 输出 [8:0]
  .dbg_rst_dps_state(dbg_rst_dps_state),                // 输出 [2:0]
  .dbg_tran_err_rst_cnt(dbg_tran_err_rst_cnt),          // 输出 [5:0]
  .dbg_ddrphy_init_fail(dbg_ddrphy_init_fail),          // 输出
  .debug_cpd_offset_adj(debug_cpd_offset_adj),          // 输入
  .debug_cpd_offset_dir(debug_cpd_offset_dir),          // 输入
  .debug_cpd_offset(debug_cpd_offset),                  // 输入 [9:0]
  .debug_dps_cnt_dir0(debug_dps_cnt_dir0),              // 输出 [9:0]
  .debug_dps_cnt_dir1(debug_dps_cnt_dir1),              // 输出 [9:0]
  .ck_dly_en(ck_dly_en),                                // 输入
  .init_ck_dly_step(init_ck_dly_step),                  // 输入 [7:0]
  .ck_dly_set_bin(ck_dly_set_bin),                      // 输出 [7:0]
  .align_error(align_error),                            // 输出
  .debug_rst_state(debug_rst_state),                    // 输出 [3:0]
  .debug_cpd_state(debug_cpd_state)                     // 输出 [3:0]
);
