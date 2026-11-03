`timescale 1ns/1ps

// 有符号全精度乘法：部分乘积、分组求和、结果合并各占一拍。
// 所有寄存器共用 advance；下游停顿时，乘积与主流水线一起保持。
module signed_mul_pipe #(                                                   // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
    parameter A_WIDTH = 27,
    parameter B_WIDTH = 27
) (
    input wire clk, rst_n, advance, input_valid,                            // 本模块工作时钟；低有效复位；本拍允许整条关联流水同时推进；本拍乘法输入有效。
    input wire signed [A_WIDTH - 1 : 0] a,
    input wire signed [B_WIDTH - 1 : 0] b,
    output reg signed [A_WIDTH + B_WIDTH - 1 : 0] product
);
    localparam AL = A_WIDTH / 2, AH = A_WIDTH - AL;                         // A 的低段不带符号，高段保留补码符号；两段位数之和仍等于 A_WIDTH。
    localparam BL = B_WIDTH / 2, BH = B_WIDTH - BL;                         // B 采用相同分段方法，允许奇数位宽。
    localparam LL = AL + BL + 2, LH = AL + BH + 1;                          // 低段先补零，交叉乘积为符号及进位预留完整位宽。
    localparam HL = AH + BL + 1, HH = AH + BH;
    localparam ROW = A_WIDTH + B_WIDTH;                                     // 最终乘积宽度始终为两个操作数位宽之和，不截去低位或改变舍入点。

    // 低半部补零后作为正数；高半部保留原符号。
    wire signed [AL : 0] a_low = $signed({1'b0, a[AL - 1 : 0]});
    wire signed [AH - 1 : 0] a_high = $signed(a[A_WIDTH - 1 : AL]);
    wire signed [BL : 0] b_low = $signed({1'b0, b[BL - 1 : 0]});
    wire signed [BH - 1 : 0] b_high = $signed(b[B_WIDTH - 1 : BL]);
    reg signed [LL - 1 : 0] p_ll;
    reg signed [LH - 1 : 0] p_lh;
    reg signed [HL - 1 : 0] p_hl;
    reg signed [HH - 1 : 0] p_hh;
    reg signed [ROW - 1 : 0] row_low, row_high;
    wire signed [ROW - 1 : 0] ll_ext = {{(ROW - LL){p_ll[LL - 1]}}, p_ll};  // 第一级低低乘积扩展到完整结果位宽后才参与移位累加。
    wire signed [ROW - 1 : 0] lh_ext = {{(ROW - LH){p_lh[LH - 1]}}, p_lh};
    wire signed [ROW - 1 : 0] hl_ext = {{(ROW - HL){p_hl[HL - 1]}}, p_hl};
    wire signed [ROW - 1 : 0] hh_ext = {{(ROW - HH){p_hh[HH - 1]}}, p_hh};

    always @(posedge clk) begin
        if (!rst_n) begin
            p_ll <= 0; p_lh <= 0; p_hl <= 0; p_hh <= 0;
            row_low <= 0; row_high <= 0; product <= 0;
        end else if (advance) begin
            if (input_valid) begin                                          // 只在有效输入时刷新部分乘积；流水推进时后两级仍处理已有数据。
                p_ll <= a_low * b_low;                                      // 第一级：低段与低段相乘。
                p_lh <= a_low * b_high;                                     // 第一级：A 低段与 B 有符号高段相乘。
                p_hl <= a_high * b_low;                                     // 第一级：A 有符号高段与 B 低段相乘。
                p_hh <= a_high * b_high;                                    // 第一级：两个有符号高段相乘。
            end
            // 先扩位再移位，保留负数符号及完整乘积，不改变原有舍入规则。
            row_low <= ll_ext + (lh_ext <<< BL);                            // 第二级：按 B 低段位数对齐，同 A 低段有关的两个乘积先求和。
            row_high <= hl_ext + (hh_ext <<< BL);                           // 第二级：同 A 高段有关的两个乘积先求和。
            product <= row_low + (row_high <<< AL);                         // 第三级：按 A 低段位数对齐并合并，得到与直接有符号乘法相同的完整结果。
        end
    end
endmodule
