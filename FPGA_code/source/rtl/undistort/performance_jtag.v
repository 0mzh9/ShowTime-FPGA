`timescale 1ns/1ps
module performance_jtag                                                     // 性能诊断 JTAG 探针封装：供调试器读取快照，不参与像素运算。
    (input wire            clk, rst_n,                                      // 本模块工作时钟；低有效复位。
     input wire [1023 : 0] snapshot,                                        // 供串口或 JTAG 读取的诊断快照。
     output wire           arm_toggle);                                     // 通过只读 JTAG 探针导出性能统计快照。
    wire          drck, tdi, capt, shift, tdo;
    wire [14 : 0] select;
    wire [8 : 0]  id;
    perf_jtag_hub hub(.resetn_i(rst_n),
                      .drck_o(drck),
                      .hub_tdi(tdi),
                      .capt_o(capt),
                      .shift_o(shift),
                      .conf_sel(select),
                      .id_o(id),
                      .hub_tdo({14'd0, tdo}));
    perf_dvio     dvio(.drck_in(drck),
                       .hub_tdi(tdi),
                       .id_i(id),
                       .capt_i(capt),
                       .shift_i(shift),
                       .conf_sel(select[0]),
                       .hub_tdo(tdo),
                       .clk(clk),
                       .resetn_i(rst_n),
                       .probe_in0(snapshot[255 : 0]),
                       .probe_in1(snapshot[511 : 256]),
                       .probe_in2(snapshot[767 : 512]),
                       .probe_in3(snapshot[1023 : 768]),
                       .probe_out0(arm_toggle));
endmodule
