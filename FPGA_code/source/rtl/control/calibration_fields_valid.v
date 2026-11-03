`timescale 1ns/1ps
 
 
module calibration_fields_valid                                             // 检查已量化参数的尺寸、符号扩展与取值范围；不进行棋盘格标定计算。
    (input wire [639 : 0] payload,
     output wire          valid);                                           // 检查类型、有效范围及焦距倒数的一致性。
    wire [31 : 0]        flags = payload[31 : 0];
    wire signed [31 : 0] fx = payload[159 : 128], fy = payload[191 : 160];
    wire signed [31 : 0] cx = payload[223 : 192], cy = payload[255 : 224];
    wire signed [63 : 0] inv_fx = payload[319 : 256],
                         inv_fy = payload[383 : 320];                       // 倒数焦距采用 Q40，需与对应 Q12 焦距匹配。
    wire signed [31 : 0] p1 = payload[479 : 448], p2 = payload[511 : 480];
    wire signed [31 : 0] ox720 = payload[543 : 512], oy720 = payload[575 : 544];
    wire signed [31 : 0] ox1080 = payload[607 : 576], oy1080 = payload[639 : 608];
    function fits24
        (input signed [31 : 0] value);
        fits24 = value >=  -32'sd8388608 && value <= 32'sd8388607;
    endfunction

    wire [63 : 0] reciprocal_x = $unsigned(fx[23 : 0]) * $unsigned(inv_fx[39 : 0]);
    wire [63 : 0] reciprocal_y = $unsigned(fy[23 : 0]) * $unsigned(inv_fy[39 : 0]);
    assign valid = (flags & 32'hfffffffe) == 0 &&                           // 只允许规定的标志位、固定输入输出尺寸及受支持的定点参数表示。
                   payload[127 : 32] == {16'd1080, 16'd1920, 16'd720, 16'd1280, 16'd720, 16'd1280} &&
                   fx >= 32'sd262144 && fx <= 32'sd8384512 && fy >= 32'sd262144 && fy <= 32'sd8384512 && inv_fx > 0 &&
                   inv_fx < 64'sd549755813888 && inv_fy > 0 && inv_fy < 64'sd549755813888 && fits24(cx) && fits24(cy) &&
                   fits24(ox720) && fits24(oy720) && fits24(ox1080) && fits24(oy1080) && p1 >=  -32'sd536870912 &&
                   p1 <= 32'sd536870912 && p2 >=  -32'sd536870912 && p2 <= 32'sd536870912 &&
                   reciprocal_x >= 64'd4503591037435904 && reciprocal_x <= 64'd4503608217305088 &&
                   reciprocal_y >= 64'd4503591037435904 && reciprocal_y <= 64'd4503608217305088;
endmodule
