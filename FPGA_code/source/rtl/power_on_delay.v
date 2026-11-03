`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: Will
// 
// Create Date: 2023-03-17  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
 
 
module power_on_delay                                                       // 相机上电时序：先保持复位，再延迟释放并等待器件稳定。
    #(                                                                      // 摄像头复位和上电等待均由计数器产生。
      parameter integer CLOCK_HZ      = 27000000,                           // 延时按实际输入时钟频率换算，端口历史名称不决定时钟频率。
      parameter integer RESET_CYCLES  = CLOCK_HZ / 50,
      parameter integer SETTLE_CYCLES = CLOCK_HZ / 50)
    (input      clk_50M,
     input      reset_n,
     output reg camera1_rstn,
     output     camera2_rstn,
     output     camera_pwnd,
     output reg initial_en);
    reg [31 : 0] count;
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            count        <= 0;
            camera1_rstn <= 1'b0;
            initial_en   <= 1'b0;
        end else begin
            if (count < RESET_CYCLES + SETTLE_CYCLES)
                count <= count + 1'b1;

            camera1_rstn <= count >= RESET_CYCLES - 1;
            initial_en   <= count >= RESET_CYCLES + SETTLE_CYCLES - 1;
        end
    end
    assign camera2_rstn = camera1_rstn;

    assign camera_pwnd = 1'b0;                                              // PWDN 固定为低电平；相机上电等待通过复位时序完成。
endmodule
