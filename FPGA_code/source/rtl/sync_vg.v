`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Myminieye
// Engineer: Ori
// 
// Create Date:    2021-08-06 15:16 
// Design Name:  
// Module Name:    sync_vg
// QQ Group   :    
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
//    VS     ______                                       ______
//HS  __    |      |_______________……____________________|      |
//   |       h_sync  h_bp       h_act                h_fp
//   |__                    _______________________
//DE    |   _______________|                       |_____________
//      |
//      .
//      |
//    __|
//   |  
//   |__ 
//      |
// Revision: v1.0
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1

module sync_vg                                                              // 视频扫描时序：根据总周期、同步宽度和前后沿生成行场同步及有效区坐标。
    #(parameter DYNAMIC_MODE = 0,                                           // 是否根据运行时模式选择输出尺寸。
      parameter X_BITS       = 12,
      parameter Y_BITS       = 12,

      //MODE_720p ；
      parameter V_TOTAL   = 12'd750,
      parameter V_FP      = 12'd5,
      parameter V_BP      = 12'd20,
      parameter V_SYNC    = 12'd5,
      parameter V_ACT     = 12'd720,
      parameter H_TOTAL   = 12'd1650,
      parameter H_FP      = 12'd110,
      parameter H_BP      = 12'd220,
      parameter H_SYNC    = 12'd40,
      parameter H_ACT     = 12'd1280,
      parameter HV_OFFSET = 12'd0

    )
    (input clk,                                                             // 处理时钟。
     input mode1080,                                                        // 1080P 模式选择。
     input rstn,                                                            // 低有效复位。
     output reg                  vs_out,
     output reg                  hs_out,
     output reg                  de_out,
     output reg                  de_re,
     output reg [X_BITS - 1 : 0] x_act,
     output reg [Y_BITS - 1 : 0] y_act);

    wire [11 : 0]        ht = (DYNAMIC_MODE &&  !mode1080) ? 1650 : H_TOTAL;
    wire [11 : 0]        hf = (DYNAMIC_MODE &&  !mode1080) ? 110 : H_FP;
    wire [11 : 0]        hb = (DYNAMIC_MODE &&  !mode1080) ? 220 : H_BP;
    wire [11 : 0]        hs = (DYNAMIC_MODE &&  !mode1080) ? 40 : H_SYNC;
    wire [11 : 0]        vt = (DYNAMIC_MODE &&  !mode1080) ? 750 : V_TOTAL;
    wire [11 : 0]        vf = (DYNAMIC_MODE &&  !mode1080) ? 5 : V_FP;
    wire [11 : 0]        vb = (DYNAMIC_MODE &&  !mode1080) ? 20 : V_BP;
    wire [11 : 0]        vs = (DYNAMIC_MODE &&  !mode1080) ? 5 : V_SYNC;
    reg [X_BITS - 1 : 0] h_count;                                           // 行扫描计数包含同步、消隐及有效图像，不只是有效像素。
    reg [Y_BITS - 1 : 0] v_count;                                           // 每到一行结束才推进场扫描计数。

    /* horizontal counter */
    always @(posedge clk) begin
        if (!rstn)
            h_count <= `UD 0;
        else begin
            if (h_count < ht - 1)                                           // 达到行总周期后回零，为下一扫描行重新开始计时。
                h_count <= `UD h_count + 1;
            else
                h_count <= `UD 0;
        end
    end

    /* vertical counter */
    always @(posedge clk) begin
        if (!rstn)
            v_count <= `UD 0;
        else if (h_count == ht - 1) begin                                   // 场坐标在行末更新，避免同一行中途改变扫描行号。
            if (v_count == vt - 1)
                v_count <= `UD 0;
            else
                v_count <= `UD v_count + 1;
        end
    end

    always @(posedge clk) begin
        if (!rstn)
            hs_out <= `UD 4'b0;
        else
            hs_out <= `UD((h_count < hs));
    end

    always @(posedge clk) begin
        if (!rstn)
            vs_out <= `UD 4'b0;
        else begin
            if ((v_count == 0) && (h_count == HV_OFFSET))
                vs_out <= `UD 1'b1;
            else if ((v_count == vs) && (h_count == HV_OFFSET))
                vs_out <= `UD 1'b0;
            else
                vs_out <= `UD vs_out;
        end
    end

    always @(posedge clk) begin                                             // 有效区排除行场同步以及前后消隐；只有 de_out 为真时输出有效画面。
        if (!rstn)
            de_out <= `UD 4'b0;
        else
            de_out <= (((v_count >= vs + vb) && (v_count <= vt - vf - 1)) &&
                       ((h_count >= hs + hb) && (h_count <= ht - hf - 1)));
    end

    always @(posedge clk) begin                                             // 读使能相对显示有效区提前两个像素，补偿后端读数据流水延迟。
        if (!rstn)
            de_re <= `UD 4'b0;
        else
            de_re <= (((v_count >= vs + vb) && (v_count <= vt - vf - 1)) &&
                      ((h_count >= hs + hb - 2'd2) && (h_count <= ht - hf - 3)));
    end
    // active pixels counter output
    always @(posedge clk) begin                                             // 有效区横坐标从零开始，按像素时钟逐点递增。
        if (!rstn)
            x_act <= `UD'd0;
        else begin
            /* X coords – for a backend pattern generator */
            if (h_count > (hs + hb - 1'b1))
                x_act <= `UD(h_count - (hs + hb));
            else
                x_act <= `UD'd0;
        end
    end

    always @(posedge clk) begin                                             // 有效区纵坐标去掉同步及后消隐行数。
        if (!rstn)
            y_act <= `UD'd0;
        else begin
            /* Y coords – for a backend pattern generator */
            if (v_count > (vs + vb - 1'b1))
                y_act <= `UD(v_count - (vs + vb));
            else
                y_act <= `UD'd0;
        end
    end
endmodule
