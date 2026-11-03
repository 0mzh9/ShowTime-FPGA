`timescale 1ns/1ps
 
 
 
module calibration_packet_rx                                                // 逐字节接收固定长度 CAL1 包，检查包头、版本、长度、CRC32 和结束标记。
    #(parameter TIMEOUT_CYCLES = 54000000)                                  // 事务最长等待周期数。
    (input wire         clk, rst_n, start, cancel, byte_valid,              // 本模块工作时钟；低有效复位。
     input wire [7 : 0] byte_data,                                          // 输入字节。
     output reg busy, done,                                                 // 事务进行中；事务完成脉冲。
     output reg [7 : 0] error_code,                                         // 错误原因编码。
     output reg [783 : 0] packet                                            // 完整 CAL1 数据包。
    );
    localparam       TW = $clog2(TIMEOUT_CYCLES + 1);                       // 按接收超时上限计算计数器位宽。
    reg [TW - 1 : 0] timer;
    reg [6 : 0]      index;
    reg [31 : 0]     crc;
    function [31 : 0] crc_byte                                              // 反射 CRC32：每字节最低位先进入 0xEDB88320 反馈，包尾再比较最终异或值。
        (input [31 : 0] previous,
         input [7 : 0]  value);
        integer      bit_index;
        reg [31 : 0] c;
        begin
            c = previous ^ value;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                c = c[0] ? (c >> 1) ^ 32'hedb88320 : c >> 1;                // 反射形式 CRC32 多项式。
            crc_byte = c;
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy       <= 0;
            done       <= 0;
            error_code <= 0;
            packet     <= 0;
            timer      <= 0;
            index      <= 0;
            crc        <= 32'hffffffff;
        end else begin
            done <= 0;
            if (cancel) begin
                busy  <= 0;
                timer <= 0;
                index <= 0;
            end else if (start &&  !busy) begin                             // 新包开始时清零字节索引、恢复 CRC 初值，并启动接收超时监测。
                busy       <= 1;
                error_code <= 0;
                packet     <= 0;
                timer      <= 0;
                index      <= 0;
                crc        <= 32'hffffffff;
            end else if (busy) begin
                if (byte_valid) begin                                       // 每个收到的字节按协议偏移写入，只有版本到载荷末尾参与 CRC32。
                    packet[index * 8 +: 8] <= byte_data;
                    timer                  <= 0;                            // 按字节装载 CAL1 数据包，字段保持原小端顺序。
                    if (index >= 4 && index <= 91)
                        crc <= crc_byte(crc, byte_data);                    // CRC 覆盖协议指定的正文范围。
                    if (index == 97) begin
                        busy <= 0;
                        done <= 1;
                        if (packet[31 : 0] != 32'h314c4143 ||               // 固定包头、载荷长度和包尾不正确时拒绝整包。
                            packet[63 : 48] != 16'd80 ||                    // 核验 CAL1 包头、载荷长度及帧尾。
                            packet[775 : 768] != 8'h0d || byte_data != 8'h0a)
                            error_code <= 1;
                        else if (packet[39 : 32] != 1 || packet[47 : 40] != 1)
                            error_code <= 6;
                        else if (packet[767 : 736] != (crc ^ 32'hffffffff))  // CRC 覆盖偏移 4 至 91 的字节，不包括包头、CRC 字段及结束标记。
                            error_code <= 2;                                // 将累计 CRC 取反后与包内校验值比较。
                    end else
                        index <= index + 1'b1;
                end else if (timer == TIMEOUT_CYCLES - 1) begin
                    busy       <= 0;
                    done       <= 1;
                    error_code <= 8;
                end else
                    timer <= timer + 1'b1;
            end
        end
    end
endmodule
