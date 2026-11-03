`timescale 1ns/1ps
 
 
module adaptive_gamma_stats                                                 // 对完整原帧统计亮度与暗亮比例，平滑统计后逐档调节 Gamma；不修改输入像素。
    #(parameter PIXELS = 921600)                                            // 一帧应有的有效像素总数。
    (input wire          clk, rst_n, enable, pixel_valid, first, last,      // 本模块工作时钟；低有效复位；输入 RGB565 像素有效。
     input wire [15 : 0] pixel,                                             // RGB565 像素。
     output reg [3 : 0] level,                                              // 当前 Gamma 档位。
     output reg [7 : 0] mean, dark, high,                                   // 平均亮度；暗部比例，量化到 255；高亮比例，量化到 255。
     output reg stats_valid                                                 // 完整帧统计更新脉冲。
    );
    wire [7 : 0]  r = {pixel[15 : 11], pixel[15 : 13]};                     // RGB565 红色通道扩展为八位，仅用于亮度统计。
    wire [7 : 0]  g = {pixel[10 : 5], pixel[10 : 9]};
    wire [7 : 0]  b = {pixel[4 : 0], pixel[4 : 2]};
    reg           valid_d, first_d, last_d;
    reg [15 : 0]  luma_sum;
    wire [7 : 0]  y = luma_sum[15 : 8];                                     // 取加权亮度累加结果的高八位。
    reg [31 : 0]  sum, count, nd, nh;
    wire [31 : 0] next_sum   = (first_d ? 32'd0 : sum) + y;
    wire [31 : 0] next_count = (first_d ? 32'd0 : count) + 1;
    wire [31 : 0] next_dark  = (first_d ? 32'd0 : nd) + (y < 32);           // 暗部定义为亮度低于 32。
    wire [31 : 0] next_high  = (first_d ? 32'd0 : nh) + (y > 224);          // 高亮定义为亮度高于 224。
    reg [31 : 0]  numerator[0 : 2];
    reg [31 : 0]  dividend, remainder, quotient;
    reg [5 : 0]   bit_count;                                                // 串行除法共处理三组分子：亮度和、暗部计数乘 255、高亮计数乘 255。
    reg [1 : 0]   which, state;
    reg [7 : 0]   values[0 : 2];
    wire [32 : 0] shifted       = {remainder, dividend[31]};
    wire          subtract      = shifted >= PIXELS;
    wire [31 : 0] quotient_next = {quotient[30 : 0], subtract};
    reg           initialized;
    reg [1 : 0]   settle_frames;
    wire [10 : 0] smooth_mean = {3'd0, mean} * 7 + values[0];               // 按前值七份、当前值一份进行帧间平滑。
    wire [10 : 0] smooth_dark = {3'd0, dark} * 7 + values[1];
    wire [10 : 0] smooth_high = {3'd0, high} * 7 + values[2];
    reg [3 : 0]   target;

    always @ * begin
        target = 4;                                                         // 中性档位，不额外提亮或压暗；档位 4 对应 gamma=1.0；较小档位提亮，较大档位压暗。
        if (dark > 96 && high > 24)                                         // 暗部和高亮共存时优先温和提亮，避免直接选最强亮度调整。
            target = 3;
        else if (mean < 48 && dark > 128)
            target = 0;
        else if (mean < 72 && dark > 80)
            target = 1;
        else if (mean < 96 && dark > 40)
            target = 2;
        else if (mean < 112 && dark > 24)
            target = 3;
        else if (mean > 208 && high > 96)
            target = 8;
        else if (mean > 184 && high > 64)
            target = 7;
        else if (mean > 160 && high > 32)
            target = 6;
        else if (mean > 144 && high > 16)
            target = 5;

        if (mean >= 116 && mean <= 140 && dark < 80 && high < 48)
            target = 4;                                                     // 正常曝光死区，抑制档位来回跳变。
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_d       <= 0;
            first_d       <= 0;
            last_d        <= 0;
            luma_sum      <= 0;
            sum           <= 0;
            count         <= 0;
            nd            <= 0;
            nh            <= 0;
            level         <= 4;
            mean          <= 128;
            dark          <= 0;
            high          <= 0;
            stats_valid   <= 0;
            initialized   <= 0;
            settle_frames <= 0;
            state         <= 0;
            which         <= 0;
            dividend      <= 0;
            remainder     <= 0;
            quotient      <= 0;
            bit_count     <= 0;
            numerator[0]  <= 0;
            numerator[1]  <= 0;
            numerator[2]  <= 0;
            values[0]     <= 0;
            values[1]     <= 0;
            values[2]     <= 0;
        end else begin
            stats_valid <= 0;
            valid_d     <= pixel_valid;
            first_d     <= first;
            last_d      <= last;
            if (pixel_valid)
                luma_sum <= r * 16'd77 + g * 16'd150 + b * 16'd29;          // 近似亮度为 (77R + 150G + 29B) / 256。
            if (valid_d) begin
                sum   <= next_sum;
                count <= next_count;
                nd    <= next_dark;
                nh    <= next_high;
                if (last_d && next_count == PIXELS && state == 0) begin     // 只对像素数正确的完整帧启动统计除法。
                    numerator[0] <= next_sum;
                    numerator[1] <= next_dark * 255;                        // 暗部比例量化到 0 至 255。
                    numerator[2] <= next_high * 255;
                    state        <= 1;
                    which        <= 0;
                end
            end
            case (state)
                1 : begin
                    dividend  <= numerator[which];
                    quotient  <= 0;
                    remainder <= 0;
                    bit_count <= 0;                                         // 依次初始化三组统计量的除法，不在逐像素路径内做通用除法。
                    state     <= 2;
                end
                2 : begin
                    remainder <= subtract ? shifted - PIXELS : shifted;
                    dividend  <= {dividend[30 : 0], 1'b0};
                    quotient  <= quotient_next;
                    if (bit_count == 31) begin
                        values[which] <= quotient_next[7 : 0];
                        if (which == 2)
                            state <= 3;
                        else begin
                            which <= which + 1'b1;
                            state <= 1;
                        end
                    end else
                        bit_count <= bit_count + 1'b1;
                end
                3 : begin
                    mean        <= initialized ? smooth_mean[10 : 3] : values[0];  // 首个完整统计直接初始化；之后使用 7/8 历史值与 1/8 当前值平滑。
                    dark        <= initialized ? smooth_dark[10 : 3] : values[1];
                    high        <= initialized ? smooth_high[10 : 3] : values[2];
                    initialized <= 1;
                    state       <= 0;
                    stats_valid <= 1;

                    if (enable && initialized) begin
                        if (settle_frames == 2) begin                       // 每三帧至多移动一档，避免亮度突变。
                            settle_frames <= 0;
                            if (level < target)
                                level <= level + 1'b1;
                            else if (level > target)
                                level <= level - 1'b1;
                        end else
                            settle_frames <= settle_frames + 1'b1;
                    end
                end
                default : begin
                end
            endcase
            if (!enable) begin
                level         <= 4;
                settle_frames <= 0;
            end                                                             // 关闭时回到中性档位并清除切换等待。
        end
    end
endmodule
