`timescale 1ns/1ps
 
 
 
 
 
 
module distort_map_fixed                                                    // 固定参数 Brown 映射器：保留兼容参数化实现，输出原图采样坐标及像素标签。
    #(                                                                      // 固定参数的反向畸变映射参考路径。
      parameter                 TAG_WIDTH    = 32,                          // 逐像素关联标签位宽。
      parameter signed [23 : 0] FX_Q12       = 24'sd3139016,
      parameter signed [23 : 0] FY_Q12       = 24'sd3141675,
      parameter signed [23 : 0] CX_Q12       = 24'sd2701818,
      parameter signed [23 : 0] CY_Q12       = 24'sd1381566,
      parameter signed [39 : 0] INV_FX_Q40   = 40'sd1434717100,
      parameter signed [39 : 0] INV_FY_Q40   = 40'sd1433502494,
      parameter signed [31 : 0] K1_Q30       =  -32'sd317085963,
      parameter signed [31 : 0] K2_Q30       = 32'sd72783623,
      parameter signed [31 : 0] P1_Q30       =  -32'sd1849811,
      parameter signed [31 : 0] P2_Q30       = 32'sd1846515,
      parameter                 DYNAMIC_MODE = 0,                           // 是否根据运行时模式选择输出尺寸。
      parameter signed [23 : 0] OUT_CX_Q12 = 24'sd4104864, OUT_CY_Q12 = 24'sd2048223)
    (input wire clk, rst_n, mode1080,                                       // 处理时钟；低有效复位；1080P 模式选择。
     input wire in_valid,                                                   // 输入有效。
     output wire in_ready,                                                  // 允许接收输入。
     input wire [10 : 0] u,                                                 // 输出横坐标。
     input wire [10 : 0] v,                                                 // 输出纵坐标。
     input wire [TAG_WIDTH - 1 : 0] in_tag,                                 // 输入像素标签。
     output wire out_valid,                                                 // 输出有效。
     input wire out_ready,                                                  // 下游就绪。
     output reg signed [23 : 0] source_x_q12, source_y_q12,                 // 原图横坐标，Q12；原图纵坐标，Q12。
     output reg [TAG_WIDTH - 1 : 0] out_tag                                 // 与输出像素对齐的标签。
    );
    function
        signed [63 : 0]       rounded_shift;
        input signed [63 : 0] value;
        input integer         n;
        begin
            rounded_shift = (value + (64'sd1 <<< (n - 1))) >>> n;
        end
    endfunction
    localparam              STAGES = 15;
    reg [STAGES - 1 : 0]    valid_pipe;
    wire                    advance   = rst_n && (!valid_pipe[STAGES - 1] || out_ready);
    assign                  in_ready  = advance;
    assign                  out_valid = valid_pipe[STAGES - 1];
    reg [TAG_WIDTH - 1 : 0] tags[0 : STAGES - 2];
    reg signed [23 : 0]     dx1, dy1;
    reg signed [63 : 0]     nx2, ny2;

    reg signed [26 : 0] xs[0 : 7], ys[0 : 7];
    reg signed [53 : 0] xxp4, yyp4, xyp4;
    reg signed [27 : 0] xx5, yy5, xy5, xx6, yy6, xy6, xx7, yy7, xy7;
    reg signed [27 : 0] r26, r27, r28, r48;
    reg signed [55 : 0] r4p7;
    reg signed [29 : 0] two_xy8, r2_two_xx8, r2_two_yy8;
    reg signed [59 : 0] k1p9, k2p9;
    reg signed [61 : 0] tx1p9, tx2p9, ty1p9, ty2p9;
    reg signed [31 : 0] radial10;
    reg signed [27 : 0] tx10, ty10, tx11, ty11, xd12, yd12;
    reg signed [58 : 0] rxp11, ryp11;
    reg signed [51 : 0] pxp13, pyp13;
    reg signed [23 : 0] px14, py14;
    integer             i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe <= 0;
            for (i = 0; i < STAGES - 1; i = i + 1)
                tags[i] <= 0;
            for (i = 0; i < 8; i = i + 1) begin
                xs[i] <= 0;
                ys[i] <= 0;
            end
            out_tag      <= 0;
            dx1          <= 0;
            dy1          <= 0;
            nx2          <= 0;
            ny2          <= 0;
            xxp4         <= 0;
            yyp4         <= 0;
            xyp4         <= 0;
            xx5          <= 0;
            yy5          <= 0;
            xy5          <= 0;
            xx6          <= 0;
            yy6          <= 0;
            xy6          <= 0;
            xx7          <= 0;
            yy7          <= 0;
            xy7          <= 0;
            r26          <= 0;
            r27          <= 0;
            r28          <= 0;
            r48          <= 0;
            r4p7         <= 0;
            two_xy8      <= 0;
            r2_two_xx8   <= 0;
            r2_two_yy8   <= 0;
            k1p9         <= 0;
            k2p9         <= 0;
            tx1p9        <= 0;
            tx2p9        <= 0;
            ty1p9        <= 0;
            ty2p9        <= 0;
            radial10     <= 0;
            tx10         <= 0;
            ty10         <= 0;
            tx11         <= 0;
            ty11         <= 0;
            rxp11        <= 0;
            ryp11        <= 0;
            xd12         <= 0;
            yd12         <= 0;
            pxp13        <= 0;
            pyp13        <= 0;
            px14         <= 0;
            py14         <= 0;
            source_x_q12 <= 0;
            source_y_q12 <= 0;
        end else if (advance) begin
            valid_pipe <= {valid_pipe[STAGES - 2 : 0], in_valid};
            tags[0]    <= in_tag;
            for (i = 1; i < STAGES - 1; i = i + 1)
                tags[i] <= tags[i - 1];
            for (i = 1; i < 8; i = i + 1) begin
                xs[i] <= xs[i - 1];
                ys[i] <= ys[i - 1];
            end
            if (in_valid) begin
                dx1 <= ($signed({1'b0, u}) <<< 12) - ((DYNAMIC_MODE &&  !mode1080) ? CX_Q12 : OUT_CX_Q12);
                dy1 <= ($signed({1'b0, v}) <<< 12) - ((DYNAMIC_MODE &&  !mode1080) ? CY_Q12 : OUT_CY_Q12);
            end
            if (valid_pipe[0]) begin
                nx2 <= dx1 * INV_FX_Q40;
                ny2 <= dy1 * INV_FY_Q40;
            end
            if (valid_pipe[1]) begin
                xs[0] <= rounded_shift(nx2, 28);
                ys[0] <= rounded_shift(ny2, 28);
            end
            if (valid_pipe[2]) begin
                xxp4 <= xs[0] * xs[0];
                yyp4 <= ys[0] * ys[0];
                xyp4 <= xs[0] * ys[0];
            end
            if (valid_pipe[3]) begin
                xx5 <= rounded_shift(xxp4, 24);
                yy5 <= rounded_shift(yyp4, 24);
                xy5 <= rounded_shift(xyp4, 24);
            end
            if (valid_pipe[4]) begin
                r26 <= xx5 + yy5;
                xx6 <= xx5;
                yy6 <= yy5;
                xy6 <= xy5;
            end
            if (valid_pipe[5]) begin
                r4p7 <= r26 * r26;
                r27  <= r26;
                xx7  <= xx6;
                yy7  <= yy6;
                xy7  <= xy6;
            end
            if (valid_pipe[6]) begin
                r48        <= rounded_shift(r4p7, 24);
                r28        <= r27;
                two_xy8    <= {{2{xy7[27]}}, xy7} <<< 1;
                r2_two_xx8 <= {{2{r27[27]}}, r27} + ({{2{xx7[27]}}, xx7} <<< 1);
                r2_two_yy8 <= {{2{r27[27]}}, r27} + ({{2{yy7[27]}}, yy7} <<< 1);
            end
            if (valid_pipe[7]) begin
                k1p9  <= r28 * K1_Q30;
                k2p9  <= r48 * K2_Q30;
                tx1p9 <= two_xy8 * P1_Q30;
                tx2p9 <= r2_two_xx8 * P2_Q30;
                ty1p9 <= r2_two_yy8 * P1_Q30;
                ty2p9 <= two_xy8 * P2_Q30;
            end
            if (valid_pipe[8]) begin
                radial10 <= 64'sd1073741824 + rounded_shift(k1p9, 24) + rounded_shift(k2p9, 24);
                tx10     <= rounded_shift(tx1p9, 30) + rounded_shift(tx2p9, 30);
                ty10     <= rounded_shift(ty1p9, 30) + rounded_shift(ty2p9, 30);
            end
            if (valid_pipe[9]) begin
                rxp11 <= xs[7] * radial10;
                ryp11 <= ys[7] * radial10;
                tx11  <= tx10;
                ty11  <= ty10;
            end
            if (valid_pipe[10]) begin
                xd12 <= rounded_shift(rxp11, 30) + tx11;
                yd12 <= rounded_shift(ryp11, 30) + ty11;
            end
            if (valid_pipe[11]) begin
                pxp13 <= xd12 * FX_Q12;
                pyp13 <= yd12 * FY_Q12;
            end
            if (valid_pipe[12]) begin
                px14 <= rounded_shift(pxp13, 24);
                py14 <= rounded_shift(pyp13, 24);
            end
            if (valid_pipe[13]) begin
                source_x_q12 <= px14 + CX_Q12;
                source_y_q12 <= py14 + CY_Q12;
                out_tag      <= tags[STAGES - 2];
            end
        end
    end
endmodule
