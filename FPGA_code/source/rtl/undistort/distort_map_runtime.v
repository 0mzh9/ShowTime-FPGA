`timescale 1ns/1ps
 
 
 
 
 
 
 
module distort_map_runtime                                                  // 运行时 Brown4 逆映射：26 级定点流水，支持外部转向射线和几何直通旁路。
    #(parameter TAG_WIDTH = 32, EXTERNAL_NORMALIZATION = 0)                 // 逐像素关联标签位宽。
    (input wire clk, rst_n, mode1080,                                       // 处理时钟；低有效复位；1080P 模式选择。
     input wire [639 : 0] calibration,                                      // 当前帧使用的标定参数。
     input wire                 use_external,                               // 选择外部归一化射线。
     input wire signed [31 : 0] normalized_x, normalized_y,                 // 转向后的归一化横坐标；转向后的归一化纵坐标。
     output reg                 out_overflow,                               // 坐标运算超出允许定点范围。
     input wire                 in_valid,                                   // 输入有效。
     output wire in_ready,                                                  // 允许接收输入。
     input wire [10 : 0] u,                                                 // 输出横坐标。
     input wire [10 : 0] v,                                                 // 输出纵坐标。
     input wire [TAG_WIDTH - 1 : 0] in_tag,                                 // 输入像素标签。
     output wire out_valid,                                                 // 输出有效。
     input wire out_ready,                                                  // 下游就绪。
     output reg signed [23 : 0] source_x_q12, source_y_q12,                 // 原图横坐标，Q12；原图纵坐标，Q12。
     output reg [TAG_WIDTH - 1 : 0] out_tag                                 // 与输出像素对齐的标签。
    );

    wire                 enable = calibration[0];                           // bit0 控制几何矫正使能；关闭时走坐标旁路，并非参数包校验状态。
    wire signed [23 : 0] FX_Q12 = calibration[151 : 128],
                         FY_Q12 = calibration[183 : 160];                   // 输入焦距采用 Q12，两个方向分别计算。
    wire signed [23 : 0] CX_Q12 = calibration[215 : 192], CY_Q12 = calibration[247 : 224];  // 输入原图主点坐标采用 Q12。
    wire signed [39 : 0] INV_FX_Q40 = calibration[295 : 256],
                         INV_FY_Q40 = calibration[359 : 320];               // 倒数焦距采用 Q40，用乘法代替逐像素除法。
    wire signed [31 : 0] K1_Q30     = calibration[415 : 384],
                         K2_Q30     = calibration[447 : 416];               // Brown 模型的两个径向系数，采用 Q30。
    wire signed [31 : 0] P1_Q30     = calibration[479 : 448],
                         P2_Q30     = calibration[511 : 480];               // Brown 模型的两个切向系数，采用 Q30。
    wire signed [23 : 0] OUT_CX_Q12 = mode1080 ? calibration[599 : 576]
                                               : calibration[535 : 512];    // 按输出模式选择独立的输出主点。
    wire signed [23 : 0] OUT_CY_Q12 = mode1080 ? calibration[631 : 608] : calibration[567 : 544];  // 纵向输出主点随 720P 和 1080P 画布分别选择。
    function fits
        (input signed [63 : 0] value,
         input integer         bits);
        fits = (value >=  - (64'sd1 <<< (bits - 1))) && (value < (64'sd1 <<< (bits - 1)));  // 以有符号补码区间检查可表示性，超界产生溢出标志，不静默放行。
    endfunction
    function
        signed [63 : 0]       rounded_shift;
        input signed [63 : 0] value;
        input integer         n;
        begin
            rounded_shift = (value + (64'sd1 <<< (n - 1))) >>> n;           // 先加半个量化单位再算术右移，负数仍保持补码符号扩展。
        end
    endfunction
    localparam           STAGES = 26;                                       // 五组宽乘法各增加两拍，数据、标签与错误标志统一停顿。
    // 流水阶段：0 差值，3 归一化乘积，4 归一化坐标，7 二次乘积，8 二次项，
    // 9 半径平方，12 四次乘积，13 几何项，14/15 系数乘积，16 径向比例，
    // 19 径向乘积，20 畸变坐标，23 像素乘积，24 舍入，25 输出。
    reg [STAGES - 1 : 0] valid_pipe;
    wire   advance   = rst_n && (!valid_pipe[STAGES - 1] || out_ready);     // 末级可消费或为空时，才推进整条流水线。
    assign in_ready  = advance;                                             // 上游只有看到 ready 才能推进坐标，背压时所有伴随信息一起保持。
    assign out_valid = valid_pipe[STAGES - 1];
    reg [TAG_WIDTH - 1 : 0] tags[0 : STAGES - 2];                           // 标签延迟到最后一级，与对应的源坐标同拍输出。
    reg signed [23 : 0]     dx1, dy1;
    wire signed [63 : 0]    nx2, ny2;
    reg signed [31 : 0]     external_x1, external_y1, external_x2, external_y2,
                            external_x3, external_y3, external_x4, external_y4;
    reg                     external1, external2, external3, external4;

    reg signed [26 : 0] xs[0 : 12], ys[0 : 12];
    wire signed [53 : 0] xxp4, yyp4, xyp4;
    reg signed [27 : 0] xx5, yy5, xy5, xx6, yy6, xy6;
    reg signed [27 : 0] r26, r28, r48;
    wire signed [55 : 0] r4p7;
    reg signed [29 : 0] two_xy8, r2_two_xx8, r2_two_yy8;
    reg signed [59 : 0] k1p9, k2p9;
    reg signed [61 : 0] tx1p9, tx2p9, ty1p9, ty2p9;

    reg signed [46 : 0]  k1lo9, k1hi9;
    reg signed [46 : 0]  k2lo9, k2hi9;
    reg signed [46 : 0]  tx1lo9, tx1hi9;
    reg signed [46 : 0]  tx2lo9, tx2hi9;
    reg signed [46 : 0]  ty1lo9, ty1hi9;
    reg signed [46 : 0]  ty2lo9, ty2hi9;
    reg signed [31 : 0]  radial10;
    reg signed [27 : 0]  tx10, ty10, xd12, yd12;
    wire signed [58 : 0] rxp11, ryp11;
    wire signed [51 : 0] pxp13, pyp13;
    reg signed [23 : 0]  px14, py14;
    reg [STAGES - 1 : 0] bad;
    reg [10 : 0]         identity_u[0 : STAGES - 2], identity_v[0 : STAGES - 2];
    wire signed [24 : 0] dx_wide     = ($signed({1'b0, u}) <<< 12) - OUT_CX_Q12;  // 输出横坐标减去当前画布中心，先扩位后计算，避免减法被窄位截断。
    wire signed [24 : 0] dy_wide     = ($signed({1'b0, v}) <<< 12) - OUT_CY_Q12;
    wire signed [28 : 0] r2_wide     = $signed({xx5[27], xx5}) + $signed({yy5[27], yy5});
    wire signed [63 : 0] radial_wide = 64'sd1073741824 + rounded_shift(k1p9, 24) +
                                       rounded_shift(k2p9, 24);             // 径向比例为 1 + k1*r2 + k2*r4。
    wire signed [63 : 0] tx_wide     = rounded_shift(tx1p9, 30) + rounded_shift(tx2p9, 30);  // 切向横向分量由两组乘积分别舍入后相加，保持原算法量化顺序。
    wire signed [63 : 0] ty_wide     = rounded_shift(ty1p9, 30) + rounded_shift(ty2p9, 30);
    wire signed [63 : 0] xd_wide     = rounded_shift(rxp11, 30) + tx11;
    wire signed [63 : 0] yd_wide     = rounded_shift(ryp11, 30) + ty11;
    wire signed [24 : 0] sx_wide     = $signed({px14[23], px14}) + $signed({CX_Q12[23], CX_Q12});
    wire signed [24 : 0] sy_wide     = $signed({py14[23], py14}) + $signed({CY_Q12[23], CY_Q12});

    // 乘法旁路也延迟三拍，保证半径/切向量与对应乘积属于同一像素。
    reg signed [27 : 0] r2_align[0 : 2], xx_align[0 : 2], yy_align[0 : 2], xy_align[0 : 2];
    reg signed [27 : 0] tx_align[0 : 2], ty_align[0 : 2];
    wire signed [27 : 0] r27 = r2_align[2], xx7 = xx_align[2], yy7 = yy_align[2], xy7 = xy_align[2];
    wire signed [27 : 0] tx11 = tx_align[2], ty11 = ty_align[2];
    integer delay_index;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (delay_index = 0; delay_index < 3; delay_index = delay_index + 1) begin
                r2_align[delay_index] <= 0; xx_align[delay_index] <= 0;
                yy_align[delay_index] <= 0; xy_align[delay_index] <= 0;
                tx_align[delay_index] <= 0; ty_align[delay_index] <= 0;
            end
        end else if (advance) begin
            r2_align[0] <= r26; xx_align[0] <= xx6; yy_align[0] <= yy6; xy_align[0] <= xy6;
            tx_align[0] <= tx10; ty_align[0] <= ty10;
            for (delay_index = 1; delay_index < 3; delay_index = delay_index + 1) begin
                r2_align[delay_index] <= r2_align[delay_index - 1];
                xx_align[delay_index] <= xx_align[delay_index - 1];
                yy_align[delay_index] <= yy_align[delay_index - 1];
                xy_align[delay_index] <= xy_align[delay_index - 1];
                tx_align[delay_index] <= tx_align[delay_index - 1];
                ty_align[delay_index] <= ty_align[delay_index - 1];
            end
        end
    end
    signed_mul_pipe #(.A_WIDTH(24), .B_WIDTH(40)) normalize_x (             // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[0]),
        .a(dx1), .b(INV_FX_Q40), .product(nx2));
    signed_mul_pipe #(.A_WIDTH(24), .B_WIDTH(40)) normalize_y (             // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[0]),
        .a(dy1), .b(INV_FY_Q40), .product(ny2));
    signed_mul_pipe #(.A_WIDTH(27), .B_WIDTH(27)) square_x (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[4]),
        .a(xs[0]), .b(xs[0]), .product(xxp4));
    signed_mul_pipe #(.A_WIDTH(27), .B_WIDTH(27)) square_y (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[4]),
        .a(ys[0]), .b(ys[0]), .product(yyp4));
    signed_mul_pipe #(.A_WIDTH(27), .B_WIDTH(27)) cross_xy (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[4]),
        .a(xs[0]), .b(ys[0]), .product(xyp4));
    signed_mul_pipe #(.A_WIDTH(28), .B_WIDTH(28)) radius_fourth (           // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[9]),
        .a(r26), .b(r26), .product(r4p7));
    signed_mul_pipe #(.A_WIDTH(27), .B_WIDTH(32)) radial_x (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[16]),
        .a(xs[12]), .b(radial10), .product(rxp11));
    signed_mul_pipe #(.A_WIDTH(27), .B_WIDTH(32)) radial_y (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[16]),
        .a(ys[12]), .b(radial10), .product(ryp11));
    signed_mul_pipe #(.A_WIDTH(28), .B_WIDTH(24)) pixel_x (                 // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[20]),
        .a(xd12), .b(FX_Q12), .product(pxp13));
    signed_mul_pipe #(.A_WIDTH(28), .B_WIDTH(24)) pixel_y (                 // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(advance), .input_valid(valid_pipe[20]),
        .a(yd12), .b(FY_Q12), .product(pyp13));

    integer              i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe   <= 0;
            bad          <= 0;
            out_overflow <= 0;
            for (i = 0; i < STAGES - 1; i = i + 1) begin
                identity_u[i] <= 0;
                identity_v[i] <= 0;
            end
            for (i = 0; i < STAGES - 1; i = i + 1)
                tags[i] <= 0;
            for (i = 0; i < 13; i = i + 1) begin
                xs[i] <= 0;
                ys[i] <= 0;
            end
            out_tag      <= 0;
            dx1          <= 0;
            dy1          <= 0;

            external_x1  <= 0;
            external_y1  <= 0;
            external_x2  <= 0;
            external_y2  <= 0;
            external1    <= 0;
            external2    <= 0;
            external3 <= 0; external4 <= 0;
            external_x3 <= 0; external_y3 <= 0;
            external_x4 <= 0; external_y4 <= 0;

            xx5          <= 0;
            yy5          <= 0;
            xy5          <= 0;
            xx6          <= 0;
            yy6          <= 0;
            xy6          <= 0;

            r26          <= 0;

            r28          <= 0;
            r48          <= 0;

            two_xy8      <= 0;
            r2_two_xx8   <= 0;
            r2_two_yy8   <= 0;
            k1lo9        <= 0;
            k1hi9        <= 0;
            k2lo9        <= 0;
            k2hi9        <= 0;
            tx1lo9       <= 0;
            tx1hi9       <= 0;
            tx2lo9       <= 0;
            tx2hi9       <= 0;
            ty1lo9       <= 0;
            ty1hi9       <= 0;
            ty2lo9       <= 0;
            ty2hi9       <= 0;
            k1p9         <= 0;
            k2p9         <= 0;
            tx1p9        <= 0;
            tx2p9        <= 0;
            ty1p9        <= 0;
            ty2p9        <= 0;
            radial10     <= 0;
            tx10         <= 0;
            ty10         <= 0;

            xd12         <= 0;
            yd12         <= 0;

            px14         <= 0;
            py14         <= 0;
            source_x_q12 <= 0;
            source_y_q12 <= 0;                                              // 源坐标保留十二位小数，后续用于邻点取样。
        end else if (advance) begin
            valid_pipe    <= {valid_pipe[STAGES - 2 : 0], in_valid};
            tags[0]       <= in_tag;
            identity_u[0] <= u;
            identity_v[0] <= v;
            for (i = 1; i < STAGES - 1; i = i + 1) begin
                identity_u[i] <= identity_u[i - 1];
                identity_v[i] <= identity_v[i - 1];
            end
            bad     <= {bad[STAGES - 2 : 0], 1'b0};
            bad[0]  <= (EXTERNAL_NORMALIZATION && use_external) ? (!fits(normalized_x, 27) ||  !fits(normalized_y, 27))
                                                                : (!fits(dx_wide, 24) ||  !fits(dy_wide, 24));
            bad[4]  <= bad[3] || (!(EXTERNAL_NORMALIZATION && external4) &&
                                  (!fits(rounded_shift(nx2, 28), 27) ||  !fits(rounded_shift(ny2, 28), 27)));
            bad[8]  <= bad[7] ||  !fits(rounded_shift(xxp4, 24), 28) ||  !fits(rounded_shift(yyp4, 24), 28) ||
                       !fits(rounded_shift(xyp4, 24), 28);
            bad[9]  <= bad[8] ||  !fits(r2_wide, 28);
            bad[13]  <= bad[12] ||  !fits(rounded_shift(r4p7, 24), 28);
            bad[16] <= bad[15] ||  !fits(radial_wide, 32) ||  !fits(tx_wide, 28) ||  !fits(ty_wide, 28);
            bad[20] <= bad[19] ||  !fits(xd_wide, 28) ||  !fits(yd_wide, 28);
            bad[24] <= bad[23] ||  !fits(rounded_shift(pxp13, 24), 24) ||  !fits(rounded_shift(pyp13, 24), 24);
            for (i = 1; i < STAGES - 1; i = i + 1)
                tags[i] <= tags[i - 1];
            for (i = 1; i < 13; i = i + 1) begin
                xs[i] <= xs[i - 1];
                ys[i] <= ys[i - 1];
            end
            if (in_valid && enable) begin                                   // 输入只在几何矫正使能时进入计算；旁路坐标仍随同标签继续延迟。
                dx1 <= dx_wide[23 : 0];
                dy1 <= dy_wide[23 : 0];
            end
            external1   <= use_external;
            external2   <= external1;
            external3 <= external2; external4 <= external3;
            external_x3 <= external_x2; external_y3 <= external_y2;
            external_x4 <= external_x3; external_y4 <= external_y3;
            external_x1 <= normalized_x;
            external_y1 <= normalized_y;
            external_x2 <= external_x1;
            external_y2 <= external_y1;
            if (valid_pipe[3]) begin                                        // 阶段 4 取得归一化坐标：转向使能时选择外部射线，否则使用内参归一化。
                xs[0] <= (EXTERNAL_NORMALIZATION && external4) ? external_x4 : rounded_shift(nx2, 28);
                ys[0] <= (EXTERNAL_NORMALIZATION && external4) ? external_y4 : rounded_shift(ny2, 28);
            end
            if (valid_pipe[7]) begin                                        // 阶段 8 形成 x²、y²、xy，归一化坐标与中间溢出标志同步传递。
                xx5 <= rounded_shift(xxp4, 24);
                yy5 <= rounded_shift(yyp4, 24);
                xy5 <= rounded_shift(xyp4, 24);
            end
            if (valid_pipe[8]) begin                                        // 阶段 9 形成 r²=x²+y²，并准备半径四次项。
                r26 <= xx5 + yy5;
                xx6 <= xx5;
                yy6 <= yy5;
                xy6 <= xy5;
            end
            if (valid_pipe[12]) begin                                       // 阶段 13 整理 r⁴、2xy、r²+2x² 与 r²+2y²。
                r48        <= rounded_shift(r4p7, 24);
                r28        <= r27;
                two_xy8    <= {{2{xy7[27]}}, xy7} <<< 1;
                r2_two_xx8 <= {{2{r27[27]}}, r27} + ({{2{xx7[27]}}, xx7} <<< 1);
                r2_two_yy8 <= {{2{r27[27]}}, r27} + ({{2{yy7[27]}}, yy7} <<< 1);
            end
            if (valid_pipe[13]) begin                                       // 阶段 14 开始径向及切向系数乘积，使用拆分的部分乘积保持精度。
                k1lo9  <= r28 * $signed({1'b0, K1_Q30[15 : 0]});
                k1hi9  <= r28 * $signed(K1_Q30[31 : 16]);
                k2lo9  <= r48 * $signed({1'b0, K2_Q30[15 : 0]});
                k2hi9  <= r48 * $signed(K2_Q30[31 : 16]);
                tx1lo9 <= two_xy8 * $signed({1'b0, P1_Q30[15 : 0]});
                tx1hi9 <= two_xy8 * $signed(P1_Q30[31 : 16]);
                tx2lo9 <= r2_two_xx8 * $signed({1'b0, P2_Q30[15 : 0]});
                tx2hi9 <= r2_two_xx8 * $signed(P2_Q30[31 : 16]);
                ty1lo9 <= r2_two_yy8 * $signed({1'b0, P1_Q30[15 : 0]});
                ty1hi9 <= r2_two_yy8 * $signed(P1_Q30[31 : 16]);
                ty2lo9 <= two_xy8 * $signed({1'b0, P2_Q30[15 : 0]});
                ty2hi9 <= two_xy8 * $signed(P2_Q30[31 : 16]);
            end
            if (valid_pipe[14]) begin                                       // 阶段 15 将两部分系数乘积合成为完整有符号结果。
                k1p9  <= $signed(k1lo9) + ($signed({{17{k1hi9[46]}}, k1hi9}) <<< 16);
                k2p9  <= $signed(k2lo9) + ($signed({{17{k2hi9[46]}}, k2hi9}) <<< 16);
                tx1p9 <= $signed(tx1lo9) + ($signed({{17{tx1hi9[46]}}, tx1hi9}) <<< 16);
                tx2p9 <= $signed(tx2lo9) + ($signed({{17{tx2hi9[46]}}, tx2hi9}) <<< 16);
                ty1p9 <= $signed(ty1lo9) + ($signed({{17{ty1hi9[46]}}, ty1hi9}) <<< 16);
                ty2p9 <= $signed(ty2lo9) + ($signed({{17{ty2hi9[46]}}, ty2hi9}) <<< 16);
            end
            if (valid_pipe[15]) begin                                       // 阶段 16 得到径向比例 1+k1*r²+k2*r⁴ 及切向补偿。
                radial10 <= 64'sd1073741824 + rounded_shift(k1p9, 24) + rounded_shift(k2p9, 24);
                tx10     <= rounded_shift(tx1p9, 30) + rounded_shift(tx2p9, 30);
                ty10     <= rounded_shift(ty1p9, 30) + rounded_shift(ty2p9, 30);
            end
            if (valid_pipe[19]) begin                                       // 阶段 20 合并径向投影和切向分量，得到畸变归一化坐标。
                xd12 <= rounded_shift(rxp11, 30) + tx11;
                yd12 <= rounded_shift(ryp11, 30) + ty11;
            end
            if (valid_pipe[23]) begin                                       // 阶段 24 把归一化投影乘积舍入为 Q12 像素坐标。
                px14 <= rounded_shift(pxp13, 24);
                py14 <= rounded_shift(pyp13, 24);
            end
            if (valid_pipe[24]) begin                                       // 输出阶段 25（第 26 拍）加输入主点，并合并最终溢出判断。
                out_tag      <= tags[STAGES - 2];
                out_overflow <= enable && (bad[24] ||  !fits(sx_wide, 24) ||  !fits(sy_wide, 24));
                if (!enable) begin
                    source_x_q12 <= ($signed({1'b0, identity_u[STAGES - 2]}) - (mode1080 ? 24'sd320 : 24'sd0)) <<< 12;
                    source_y_q12 <= ($signed({1'b0, identity_v[STAGES - 2]}) - (mode1080 ? 24'sd180 : 24'sd0)) <<< 12;
                end else if (bad[24] ||  !fits(sx_wide, 24) ||  !fits(sy_wide, 24)) begin

                    source_x_q12 <=  -24'sd8388608;
                    source_y_q12 <=  -24'sd8388608;
                end else begin
                    source_x_q12 <= sx_wide[23 : 0];
                    source_y_q12 <= sy_wide[23 : 0];
                end
            end
        end
    end
endmodule
