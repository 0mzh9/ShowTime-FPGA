`timescale 1ns/1ps
 
 
module pan_normalizer                                                       // 复用列参数计算转向后的归一化坐标；列查表、行坐标、标签按同一节拍对齐。
    #(parameter TAG_WIDTH = 32)                                             // 逐像素关联标签位宽。
    (input wire clk, rst_n, in_valid,                                       // 处理时钟；低有效复位；输入有效。
     output wire in_ready,                                                  // 允许接收输入。
     input wire [10 : 0] u, v,                                              // 输出横坐标；输出纵坐标。
     input wire [TAG_WIDTH - 1 : 0] in_tag,                                 // 输入像素标签。
     output wire read_enable,                                               // 列参数读取使能。
     output wire [10 : 0] read_column,                                      // 待查询的输出列。
     input wire [63 : 0] read_value,                                        // 该列的旋转坐标与倒数。
     output wire out_valid,                                                 // 输出有效。
     input wire out_ready,                                                  // 下游就绪。
     output reg signed [31 : 0] norm_x, norm_y,                             // 旋转后横向射线，Q24；旋转后纵向射线，Q24。
     output reg [10 : 0] out_u, out_v,                                      // 流水对齐后的横坐标；流水对齐后的纵坐标。
     output reg [TAG_WIDTH - 1 : 0] out_tag                                 // 与输出像素对齐的标签。
    );
    reg [5 : 0]             valid;
    wire                    advance     = rst_n && (!valid[5] || out_ready);  // 末级反压时冻结六级像素与标签流水。
    assign                  in_ready    = advance;
    assign                  out_valid   = valid[5];
    assign                  read_column = u;
    assign                  read_enable = advance && in_valid;              // 仅当输入能进入流水时发起同步列查表，避免表数据与像素标签错位。
    reg signed [11 : 0]     centered_y;                                     // 纵向坐标先以二倍中心差表示，使 359.5 的半像素中心可以精确用整数计算。
    reg signed [43 : 0]     y_product;
    reg signed [31 : 0]     x2, q2, x3, q3, x4, x5;
    reg signed [23 : 0]     y3;
    reg signed [40 : 0]     ylo4;
    reg signed [39 : 0]     yhi4;
    reg signed [63 : 0]     y_rotated;
    reg [10 : 0]            us[0 : 4], vs[0 : 4];
    reg [TAG_WIDTH - 1 : 0] tags[0 : 4];
    wire signed [31 : 0]    y_q24 = (y_product + 44'sd32) >>> 6;
    integer                 i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid      <= 0;
            norm_x     <= 0;
            norm_y     <= 0;
            out_tag    <= 0;
            out_u      <= 0;
            out_v      <= 0;                                                // 复位时清空输出纵坐标；正常运行时保留与射线对应的输出像素位置。
            centered_y <= 0;
            y_product  <= 0;
            x2         <= 0;
            q2         <= 0;
            x3         <= 0;
            q3         <= 0;
            x4         <= 0;
            x5         <= 0;
            y3         <= 0;
            ylo4       <= 0;
            yhi4       <= 0;
            y_rotated  <= 0;                                                // 复位时清空纵向旋转乘积寄存器。
            for (i = 0; i < 5; i = i + 1) begin
                us[i]   <= 0;
                vs[i]   <= 0;
                tags[i] <= 0;
            end
        end else if (advance) begin                                         // 流水暂停时，列值、纵向射线、原坐标与标签全部保持。
            valid   <= {valid[4 : 0], in_valid};
            us[0]   <= u;
            vs[0]   <= v;
            tags[0] <= in_tag;
            for (i = 1; i < 5; i = i + 1) begin
                us[i]   <= us[i - 1];
                vs[i]   <= vs[i - 1];
                tags[i] <= tags[i - 1];
            end
            centered_y <= $signed({1'b0, v}) * 12'sd2 - 12'sd719;           // v*2-719 等价于 2*(v-359.5)，保持虚拟相机像素中心约定。
            y_product  <= centered_y * 32'sd587377;
            x2         <= read_value[63 : 32];                              // 列参数高 32 位为 X/Z，后续按流水延迟对齐。
            q2         <= read_value[31 : 0];                               // 列参数低 32 位为 1/Z，供纵向射线计算复用。

            y3        <= y_q24;
            x3        <= x2;
            q3        <= q2;
            ylo4      <= y3 * $signed({1'b0, q3[15 : 0]});                  // 把 Q24 倒数分为无符号低段与带符号高段，分级计算纵向投影。
            yhi4      <= y3 * $signed(q3[31 : 16]);
            x4        <= x3;                                                // 将横向射线延迟到纵向部分乘积对应的周期。
            y_rotated <= $signed(ylo4) + ($signed({{24{yhi4[39]}}, yhi4}) <<< 16);  // 高段按位权左移十六位后与低段乘积合并。
            x5        <= x4;                                                // 继续对齐横向射线，使横纵坐标及像素标签同步输出。
            norm_x    <= x5;
            norm_y    <= (y_rotated + 64'sd8388608) >>> 24;
            out_u     <= us[4];
            out_v     <= vs[4];
            out_tag   <= tags[4];
        end
    end
endmodule
