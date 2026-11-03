`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Myminieye
// Engineer: Nill
// 
// Create Date: 2019-09-16 19:46
// Design Name: 
// Module Name: ms7210_ctl
// Project Name: hdmi_tx
// Target Devices: Pg2l100H  
// Tool Versions: 
// Description:  
// 
// Dependencies: 
// Revision: v1.0
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`define UD #1
module ms72xx_ctl                                                           // 复用底层 I2C 驱动完成 HDMI 芯片初始化，按配置阶段选择事务来源。
    (input clk,                                                             // 处理时钟。
     input mode1080,                                                        // 1080P 模式选择。
     input rst_n,                                                           // 低有效复位。

     output init_over_rx,
     output init_over,
     output iic_scl,
     inout  iic_sda);
    reg rstn_temp1, rstn_temp2;
    reg rstn;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rstn_temp1 <= 1'b0;
        else
            rstn_temp1 <= rst_n;
    end

    always @(posedge clk) begin
        rstn_temp2 <= rstn_temp1;
        rstn       <= rstn_temp2;
    end

    wire          init_over_rx;
    assign        init_over_rx = 1'b1;                                      // 该配置把接收侧初始化标志固定完成；实际初始化选择仍由以下复用逻辑决定。
    wire [7 : 0]  device_id_rx;
    wire          iic_trig_rx;
    wire          w_r_rx;
    wire [15 : 0] addr_rx;
    wire [7 : 0]  data_in_rx;
    wire          busy_rx;
    wire [7 : 0]  data_out_rx;
    wire          byte_over_rx;

    wire [7 : 0]  device_id_tx;
    wire          iic_trig_tx;
    wire          w_r_tx;
    wire [15 : 0] addr_tx;
    wire [7 : 0]  data_in_tx;
    wire          busy_tx;
    wire [7 : 0]  data_out_tx;
    wire          byte_over_tx;

    wire [7 : 0]  device_id;
    wire          iic_trig;
    wire          w_r;
    wire [15 : 0] addr /*synthesis PAP_MARK_DEBUG="true"*/;
    wire [7 : 0]  data_in;
    wire          busy;
    wire [7 : 0]  data_out /*synthesis PAP_MARK_DEBUG="true"*/;
    wire          byte_over /*synthesis PAP_MARK_DEBUG="true"*/;

    ms7200_ctl U1_ms7200_ctl(.clk(),                                        // 输入
                             .rstn(rstn),                                   // 输入

                             .init_over(),                                  // 输出 寄存器
                             .device_id(),                                  // 输出        [7:0]
                             .iic_trig(iic_trig_rx),                        // 输出 寄存器
                             .w_r(w_r_rx),                                  // 输出 寄存器
                             .addr(addr_rx),                                // 输出 寄存器   [15:0]
                             .data_in(data_in_rx),                          // 输出 寄存器   [ 7:0]
                             .busy(busy_rx),                                // 输入
                             .data_out(data_out_rx),                        // 输入        [ 7:0]
                             .byte_over(byte_over_rx)                       // 输入
               );

    wire       nack_error;
    ms7210_ctl U2_ms7210_ctl(.nack_error(nack_error),                       // HDMI 发送芯片配置：按目标视频模式设置寄存器，并反馈连接与初始化状态。
                             .mode1080(mode1080),
                             .clk(clk),                                     // 输入
                             .rstn(rstn),                                   // 输入

                             .init_over(init_over),                         // 输出 寄存器
                             .device_id(),                                  // 输出        [7:0]
                             .iic_trig(iic_trig_tx),                        // 输出 寄存器
                             .w_r(w_r_tx),                                  // 输出 寄存器
                             .addr(addr_tx),                                // 输出 寄存器   [15:0]
                             .data_in(data_in_tx),                          // 输出 寄存器   [ 7:0]
                             .busy(busy_tx),                                // 输入
                             .data_out(data_out_tx),                        // 输入        [ 7:0]
                             .byte_over(byte_over_tx)                       // 输入
               );

    assign device_id    = (init_over_rx == 1'b1 && init_over == 1'b0) ? 8'hB2 : 8'h56;  // device_id_tx : device_id_rx;；按初始化阶段在 HDMI 发送和接收控制器之间选择设备地址。
    assign iic_trig     = (init_over_rx == 1'b1 && init_over == 1'b0) ? iic_trig_tx : iic_trig_rx;  // 触发、读写方向、寄存器地址和数据必须来自同一被选控制器。
    assign w_r          = (init_over_rx == 1'b1 && init_over == 1'b0) ? w_r_tx : w_r_rx;
    assign addr         = (init_over_rx == 1'b1 && init_over == 1'b0) ? addr_tx : addr_rx;
    assign data_in      = (init_over_rx == 1'b1 && init_over == 1'b0) ? data_in_tx : data_in_rx;
    assign busy_tx      = (init_over_rx == 1'b1 && init_over == 1'b0) ? busy : 0;
    assign data_out_tx  = (init_over_rx == 1'b1 && init_over == 1'b0) ? data_out : 0;
    assign byte_over_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? byte_over : 0;

    assign busy_rx      = (init_over_rx == 1'b0 || init_over == 1'b1) ? busy : 0;
    assign data_out_rx  = (init_over_rx == 1'b0 || init_over == 1'b1) ? data_out : 0;
    assign byte_over_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? byte_over : 0;

    wire sda_in /*synthesis PAP_MARK_DEBUG="true"*/;
    wire sda_out /*synthesis PAP_MARK_DEBUG="true"*/;
    wire sda_out_en /*synthesis PAP_MARK_DEBUG="true"*/;
    iic_dri #(.CLK_FRE(27'd10_000_000),                                     // parameter            CLK_FRE   = 27'd50_000_000,//system clock frequency
              .IIC_FREQ(20'd400_000),                                       // parameter            IIC_FREQ  = 20'd400_000,   //I2c clock frequency
              .T_WR(10'd1),                                                 // parameter            T_WR      = 10'd5,         //I2c transmit delay ms
              .ADDR_BYTE(2'd2),                                             // parameter            ADDR_BYTE = 2'd1,          //I2C addr byte number
              .LEN_WIDTH(8'd3),                                             // parameter            LEN_WIDTH = 8'd3,          //I2C transmit byte width
              .DATA_BYTE(2'd1)                                              // parameter            DATA_BYTE = 2'd1           //I2C data byte number
              )
        iic_dri(.nack_error(nack_error),
                .clk(clk),                                                  // input                clk,
                .rstn(rstn),                                                // input                rstn,
                .device_id(device_id),                                      // input                device_id,
                .pluse(iic_trig),                                           // 输入                pluse,                     ；I2C 传输触发。
                .w_r(w_r),                                                  // 输入                w_r,                       ；I2C 传输方向：1 为发送，0 为接收。
                .byte_len(4'd1),                                            // 输入  [LEN_WIDTH:0] byte_len,                  ；单次触发的 I2C 传输字节数。

                .addr(addr),                                                // 输入  [7:0]         addr,                      ；I2C 传输地址。
                .data_in(data_in),                                          // 输入  [7:0]         data_in,                   ；I2C 发送数据。

                .busy(busy),                                                // 输出 寄存器           busy=0,                    ；I2C 总线状态。

                .byte_over(byte_over),                                      // 输出 寄存器           byte_over=0,               ；I2C 单字节传输完成标志。
                .data_out(data_out),                                        // 输出 寄存器[7:0]      data_out,                  ；I2C 接收数据。

                .scl(iic_scl),                                              // output               scl,
                .sda_in(sda_in),                                            // input                sda_in,
                .sda_out(sda_out),                                          // output   reg         sda_out=1'b1,
                .sda_out_en(sda_out_en)                                     // 输出               sda_out_en
        );

    assign iic_sda = sda_out_en ? sda_out : 1'bz;                           // 驱动关闭时释放 SDA，输入采样始终读取实际总线电平。
    assign sda_in  = iic_sda;
endmodule
