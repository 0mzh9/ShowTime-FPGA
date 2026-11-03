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
//将两个8bit数据拼成一个16bit RGB565数据；
`timescale 1ns/1ns

 
 
module cmos_8_16bit                                                         // DVP 字节拼接：在相机像素时钟域将两个连续字节组成一个 RGB565 像素。
    (input               pclk, rst_n, de_i,                                 // 相机 DVP 像素时钟、低有效复位及输入字节有效信号。
     input [7 : 0]       pdata_i,                                           // 摄像头当前输出的八位数据。
     input               vs_i,                                              // 相机帧同步，用于重新建立字节边界。
     output              pixel_clk,
     output reg          de_o,
     output reg [15 : 0] pdata_o);                                          // 两个字节合成的 RGB565 像素；只在 de_o 有效时消费。
    reg [7 : 0] high_byte;
    reg         second_byte, armed;                                         // 记录高字节/低字节阶段及是否已等待到有效帧同步。
    assign      pixel_clk = pclk;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            high_byte   <= 0;
            second_byte <= 0;
            armed       <= 0;
            de_o        <= 0;
            pdata_o     <= 0;
        end else begin
            de_o <= 0;                                                      // 每拍先撤销像素有效，仅在第二个字节到达时输出一个有效像素。
            if (vs_i) begin                                                 // 在帧界重新建立字节对齐。
                second_byte <= 0;
                armed       <= 1;
            end else if (!de_i)
                second_byte <= 0;                                           // 行无效时丢弃未配对字节，防止后续像素错位。
            else if (armed) begin
                second_byte <=  !second_byte;
                if (!second_byte)
                    high_byte <= pdata_i;
                else begin
                    pdata_o <= {high_byte, pdata_i};                        // 高字节与低字节拼成一个 RGB565 像素。
                    de_o    <= 1;
                end
            end
        end
    end
endmodule
