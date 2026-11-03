`timescale 1ns/1ps
 
 
module pan_control_v15                                                      // 虚拟转向串口事务：检查请求序号、角度和 CRC，以目标矫正帧输出作为成功依据。
    #(parameter WAIT_TICKS = 135000000, RX_TICKS = 54000000)                // 等待控制事务完成的周期上限；接收字节间隔的周期上限。
    (input wire clk, rst_n, command_valid,                                  // 系统控制时钟（顶层为 27 MHz）；低有效复位；双字节命令有效。
     input wire [15 : 0] command,                                           // 双字节命令。
     input wire received_valid,                                             // 串口接收字节有效。
     input wire [7 : 0] received_byte,                                      // 串口接收字节。
     input wire          enabled, display_seen,
     input wire [64 : 0] display_pan,                                       // 目标输出帧的转向状态与帧号。
     output wire         packet_mode, busy,                                 // 数据包事务独占字节流。
     output wire         reply_valid,                                       // 应答有效。
     output wire [15 : 0] reply,                                            // 待发送的应答字。
     input wire reply_ready,                                                // 应答发送端就绪。
     output reg request,                                                    // 请求翻转标识。
     output reg signed [15 : 0] target_angle,                               // 已接受的目标角度。
     output reg [15 : 0] target_sequence                                    // 已接受的目标序号。
    );
    localparam           IDLE = 0, ARM = 1, RX = 2, APPLY = 3, TX = 4;
    reg [2 : 0]          state;
    reg [31 : 0]         timer;
    reg [63 : 0]         packet;
    reg [3 : 0]          count;
    reg [15 : 0]         crc;
    reg [95 : 0]         response;
    reg [2 : 0]          words;
    wire [15 : 0]        packet_sequence = packet[47 : 32];                 // 转向事务序号，用于拒绝过期确认。
    wire signed [15 : 0] packet_angle    = packet[31 : 16];                 // 有符号转向角，单位为 0.1 度。
    assign               packet_mode     = state == ARM || state == RX;     // 接收转向数据包期间禁止普通命令解析。
    assign               busy            = state != IDLE;
    assign               reply_valid     = state == ARM || state == TX;
    assign               reply           = state == ARM ? 16'h0cc0 : response[95 : 80];  // 握手返回 0CC0；后续成功包或错误码由 response 分段发送。
    function [15 : 0] crc_byte                                              // 转向请求和应答均采用 CRC16/CCITT-FALSE，多项式 0x1021。
        (input [15 : 0] old_crc,
         input [7 : 0]  value);
        integer      i;
        reg [15 : 0] c;
        begin
            c = old_crc ^ {value, 8'd0};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            crc_byte = c;
        end                                                                 // CRC16 多项式，初始值由调用方提供。
    endfunction
    function [15 : 0] crc_ack
        (input [79 : 0] value);
        integer      i;
        reg [15 : 0] c;
        begin
            c = 16'hffff;
            for (i = 9; i >= 0; i = i - 1)
                c = crc_byte(c, value[i * 8 +: 8]);
            crc_ack = c;
        end
    endfunction
    task error
        (input [15 : 0] code);
        begin
            response <= {code, 80'd0};
            words    <= 1;
            state    <= TX;
            timer    <= 0;
        end
    endtask
    wire [79 : 0] ack_body = {16'hdc15, target_sequence, target_angle, display_pan[31 : 0]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            timer           <= 0;
            packet          <= 0;
            count           <= 0;
            crc             <= 16'hffff;
            response        <= 0;
            words           <= 0;
            request         <= 0;
            target_angle    <= 0;
            target_sequence <= 0;
        end else begin
            if (state != IDLE && timer < WAIT_TICKS)
                timer <= timer + 1'b1;
            case (state)
                IDLE :                                                      // 等候转向握手或状态查询，非允许状态返回错误。
                    if (command_valid) begin
                        if (command == 16'h0c00) begin
                            response <= {16'h15c0, 80'd0};
                            words    <= 1;
                            state    <= TX;
                        end                                                 // 查询 V15 兼容能力码；V17 不改变串口协议。
                        else if (command == 16'h0c01) begin
                            response <= {display_pan[47 : 32], 80'd0};
                            words    <= 1;
                            state    <= TX;
                        end else if (command == 16'h0c0c) begin             // 收到转向入口命令后才准备接收角度包。
                            if (enabled) begin
                                state  <= ARM;
                                timer  <= 0;
                                packet <= 0;
                                count  <= 0;
                                crc    <= 16'hffff;
                            end else
                                error(16'he101);
                        end
                    end
                ARM :                                                       // 返回转向就绪，再进入固定长度请求接收。
                    if (reply_ready) begin
                        state <= RX;
                        timer <= 0;
                    end
                RX :                                                        // 接收 PA 请求包，按字节更新 CRC16。
                    if (received_valid) begin
                        packet[63 - count * 8 -: 8] <= received_byte;
                        timer                       <= 0;
                        if (count < 6)
                            crc <= crc_byte(crc, received_byte);
                        if (count == 7) begin
                            if (packet[63 : 48] != 16'h5041)                // PA 包头按实际二进制字节 50 41 核对，不解析 ASCII 角度字符串。
                                error(16'he102);                            // 核验大端 PA 数据包头。
                            else if ({packet[15 : 8], received_byte} != crc)
                                error(16'he103);
                            else if (packet_angle <  -300 || packet_angle > 300)  // 有符号编码范围为 -300 至 +300，即 -30.0 至 +30.0 度。
                                error(16'he104);                            // 数值边界为正负 30 度，实际可用范围还受视野限制。
                            else if (!enabled)
                                error(16'he101);
                            else begin
                                target_angle    <= packet_angle;
                                target_sequence <= packet_sequence;
                                request         <=  !request;
                                state           <= APPLY;
                            end                                             // 翻转请求标识，让跨时钟接收端识别新事务。
                        end else
                            count <= count + 1'b1;
                    end else if (timer >= RX_TICKS - 1)
                        error(16'he105);
                APPLY :                                                     // 等待对应帧的 HDMI 输出事件；串口数据接收完成不能直接视为转向成功。
                    if (!enabled)
                        error(16'he101);
                    else if (display_seen && display_pan[64] == request &&
                             display_pan[63 : 48] ==
                                 target_sequence &&                         // 必须等目标角度、序号与代次对应的图像真正开始输出。
                             $signed(display_pan[47 : 32]) == target_angle) begin
                        response <= {ack_body, crc_ack(ack_body)};
                        words    <= 6;
                        state    <= TX;
                        timer    <= 0;                                      // 组装可见帧确认及 CRC，成功前不提前应答。
                    end else if (timer >= WAIT_TICKS - 1)
                        error(16'he106);
                TX :                                                        // 把成功包或错误应答按双字节送入 UART。
                    if (reply_ready) begin
                        response <= response << 16;
                        words    <= words - 1'b1;
                        if (words == 1) begin
                            state <= IDLE;
                            timer <= 0;
                        end
                    end
                default :
                    state <= IDLE;
            endcase

            if (state == IDLE && command_valid && (command == 16'h0a0a || command == 16'h6868))  // 停止或标定更新会清零运行时角度；角度本身不写 EEPROM。
            begin                                                           // 停止或更新标定时，将虚拟观察方向恢复为零。
                target_angle    <= 0;
                target_sequence <= 0;
                request         <=  !request;
            end
        end
    end
endmodule
