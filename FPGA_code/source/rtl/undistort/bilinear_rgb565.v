 
 
`timescale 1ns/1ps
module bilinear_rgb565                                                      // 四邻域双线性插值：RGB565 三通道独立加权、舍入，标签与有效位同步保持。
    #(                                                                      // 四个邻点按 Q8 小数权重插值，输出仍为 RGB565。
      parameter TAG_WIDTH = 32)                                             // 逐像素关联标签位宽。
    (input wire clk,                                                        // 处理时钟。
     input wire rst_n,                                                      // 低有效复位。
     input wire in_valid,                                                   // 输入有效。
     output wire in_ready,                                                  // 允许接收输入。
     input wire [7 : 0]             frac_x,                                 // 横向插值小数权重。
     input wire [7 : 0]             frac_y,                                 // 纵向插值小数权重。
     input wire [15 : 0]            p00, p10, p01, p11,
     input wire [3 : 0]             tap_valid,                              // 四邻点分别是否位于有效图像内。
     input wire [TAG_WIDTH - 1 : 0] in_tag,                                 // 输入像素标签。
     output wire out_valid,                                                 // 输出有效。
     input wire out_ready,                                                  // 下游就绪。
     output reg [15 : 0]            out_pixel,
     output reg [TAG_WIDTH - 1 : 0] out_tag                                 // 与输出像素对齐的标签。
    );
    reg                     v1, v2, v3;
    wire                    advance   = rst_n && (!v3 || out_ready);
    assign                  in_ready  = advance;
    assign                  out_valid = v3;
    wire [8 : 0]            ax        = {1'b0, frac_x};
    wire [8 : 0]            ay        = {1'b0, frac_y};
    wire [8 : 0]            bx        = 9'd256 - ax;                        // 用 256 表示权重一，避免用八位数表示 1.0 时发生溢出。
    wire [8 : 0]            by        = 9'd256 - ay;
    reg [16 : 0]            w00, w10, w01, w11;                             // 四项权重是两个 Q8 分量相乘的整数结果，总和恒为 65536。
    reg [15 : 0]            c00, c10, c01, c11;
    reg [TAG_WIDTH - 1 : 0] tag1, tag2;

    wire [20 : 0] r00 = w00 * c00[15 : 11], r10 = w10 * c10[15 : 11];       // 先取红色独立通道再乘权重，不能把整个打包 RGB565 当整数插值。
    wire [20 : 0] r01 = w01 * c01[15 : 11], r11 = w11 * c11[15 : 11];
    wire [21 : 0] g00 = w00 * c00[10 : 5], g10 = w10 * c10[10 : 5];         // 绿色有六位，因此其乘积与累加位宽比红蓝多一位。
    wire [21 : 0] g01 = w01 * c01[10 : 5], g11 = w11 * c11[10 : 5];
    wire [20 : 0] b00 = w00 * c00[4 : 0], b10 = w10 * c10[4 : 0];
    wire [20 : 0] b01 = w01 * c01[4 : 0], b11 = w11 * c11[4 : 0];
    reg [20 : 0]  sum_r, sum_b;
    reg [21 : 0]  sum_g;
    wire [20 : 0] round_r = sum_r + 21'd32768;                              // 右移十六位之前加半个单位，实现与参考一致的四舍五入。
    wire [21 : 0] round_g = sum_g + 22'd32768;
    wire [20 : 0] round_b = sum_b + 21'd32768;
    always @(posedge clk) begin
        if (!rst_n) begin
            v1        <= 0;
            v2        <= 0;
            v3        <= 0;
            w00       <= 0;
            w10       <= 0;
            w01       <= 0;
            w11       <= 0;
            c00       <= 0;
            c10       <= 0;
            c01       <= 0;
            c11       <= 0;
            tag1      <= 0;
            tag2      <= 0;
            out_tag   <= 0;
            sum_r     <= 0;
            sum_g     <= 0;
            sum_b     <= 0;
            out_pixel <= 0;
        end else if (advance) begin                                         // 下游停顿时，乘积、累加结果、有效位与标签一起冻结。
            v1 <= in_valid;
            v2 <= v1;
            v3 <= v2;
            if (in_valid) begin
                w00  <= bx * by;                                            // 第一级生成四个二维权重。
                w10  <= ax * by;
                w01  <= bx * ay;
                w11  <= ax * ay;
                c00  <= tap_valid[0] ? p00 : 16'd0;                         // 各越界邻点独立置零，其他有效邻点仍参与加权。
                c10  <= tap_valid[1] ? p10 : 16'd0;
                c01  <= tap_valid[2] ? p01 : 16'd0;
                c11  <= tap_valid[3] ? p11 : 16'd0;
                tag1 <= in_tag;
            end
            if (v1) begin                                                   // 第二级分别累加红、绿、蓝四个邻点乘积。
                sum_r <= r00 + r10 + r01 + r11;
                sum_g <= g00 + g10 + g01 + g11;
                sum_b <= b00 + b10 + b01 + b11;
                tag2  <= tag1;
            end
            if (v2) begin
                out_pixel <= {round_r[20 : 16], round_g[21 : 16], round_b[20 : 16]};  // 第三级取舍入后的通道高位，再按 RGB565 原位序重新打包。
                out_tag   <= tag2;
            end
        end
    end
endmodule
