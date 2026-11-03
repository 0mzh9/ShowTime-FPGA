`timescale 1ns/1ps
 
 
 
module hdmi_tx_output                                                       // HDMI 并行输出寄存：像素与同步信号一起打一拍，再拆分 RGB565 颜色通道。
    (input wire          video_clk, tx_phase_clk,
     input wire [15 : 0] rgb565,
     input wire          de, hs, vs,
     output wire         tx_clk,
     output wire [7 : 0] r, g, b,
     output wire         tx_de, tx_hs, tx_vs);

    wire        data_io_clk, forward_io_clk;
    GTP_CLKBUFR data_clock(.CLKIN(video_clk),
                           .CLKOUT(data_io_clk));
    GTP_CLKBUFR forwarded_clock(.CLKIN(tx_phase_clk),
                                .CLKOUT(forward_io_clk));
    GTP_ODDR_E1 #(.GRS_EN("FALSE"),
                  .ODDR_MODE("SAME_EDGE"),
                  .RS_TYPE("ASYNC_RESET"))
                  forward_clock(.CLK(forward_io_clk),
                                .D0(1'b1),
                                .D1(1'b0),
                                .CE(1'b1),
                                .RS(1'b0),
                                .Q(tx_clk));
    wire [18 : 0] parallel_data = {rgb565, de, hs, vs};

    (* PAP_IO_REGISTER=1 *) reg [18 : 0] registered_data;
    always @(posedge data_io_clk)                                           // 打包的颜色与 DE/HS/VS 共用一个输出寄存器，保持视频时序对应关系。
        registered_data <= parallel_data;
    assign r                     = {registered_data[18 : 14], 3'b0};        // RGB565 红通道扩展到 HDMI 八位接口，低三位补零。
    assign g                     = {registered_data[13 : 8], 2'b0};         // 绿色六位扩展，低两位补零，不增加真实色彩精度。
    assign b                     = {registered_data[7 : 3], 3'b0};          // 蓝色五位扩展，低三位补零。
    assign {tx_de, tx_hs, tx_vs} = registered_data[2 : 0];
endmodule
