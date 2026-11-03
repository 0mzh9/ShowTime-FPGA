`timescale 1ns/1ps
 
 
module calibration_control                                                  // 标定事务总控：协调视频停止、CAL1 接收、EEPROM 保存、跨域提交和应答。
    #(parameter WAIT_TICKS = 270000000, RX_TICKS = 54000000)                // 等待控制事务完成的周期上限；接收字节间隔的周期上限。
    (input wire clk, rst_n, command_valid,                                  // 系统控制时钟（顶层为 27 MHz）；低有效复位；双字节命令有效。
     input wire [15 : 0] command,                                           // 双字节命令。
     input wire received_valid,                                             // 串口接收字节有效。
     input wire [7 : 0] received_byte,                                      // 串口接收字节。
     output wire         packet_mode,                                       // 数据包事务独占字节流。
     output reg          video_command_valid,
     output reg [15 : 0] video_command,
     input wire          video_reply_valid,
     input wire [15 : 0] video_reply,
     output wire         video_reply_ready,
     input wire [3 : 0]  video_state,
     output wire         reply_valid,                                       // 应答有效。
     output wire [15 : 0] reply,                                            // 待发送的应答字。
     input wire reply_ready,                                                // 应答发送端就绪。
     input wire          store_boot_ready, store_busy, store_done,          // EEPROM 启动加载结束；EEPROM 存储事务进行中；EEPROM 存储事务结束。
     input wire [7 : 0]  store_error,                                       // EEPROM 事务错误码。
     input wire [31 : 0] active_sequence,                                   // 当前系数序号。
     input wire [639 : 0] active_payload,                                   // 当前有效的 80 字节系数。
     output reg            store_update,
     output wire [783 : 0] update_packet,                                   // 待持久化的 CAL1 数据包。
     output reg commit_request,                                             // 参数提交请求翻转标识。
     input wire commit_ack,                                                 // 处理域参数提交确认。
     output reg ready);
    localparam   BOOT = 0, BOOT_COMMIT = 1, IDLE = 2, STOP = 3, ARM = 4, RECEIVE = 5, STORE = 6, COMMIT = 7, RESUME = 8,
                 RECOVER_STOP = 9;
    reg [3 : 0]  state;
    reg [31 : 0] timer;
    reg          own_valid, saved_running, rx_start;
    reg [15 : 0] own_reply;
    reg [31 : 0] crc_sequence;
    reg [6 : 0]  crc_index;
    reg [15 : 0] payload_crc;
    function [15 : 0] crc_byte                                              // 活动载荷查询校验使用 CRC16/CCITT：逐字节送入高位并按 0x1021 反馈。
        (input [15 : 0] previous,
         input [7 : 0]  value);
        integer      i;
        reg [15 : 0] c;
        begin
            c = previous ^ {value, 8'd0};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            crc_byte = c;
        end
    endfunction
    wire         rx_busy, rx_done;
    wire [7 : 0] rx_error;
    wire         internal_reply    = state == STOP || state == RESUME || state == RECOVER_STOP;
    assign       packet_mode       = state == ARM || state == RECEIVE || rx_busy;  // 接收参数包期间禁止把数据体中的双字节误当作普通控制指令。
    assign       reply_valid       = own_valid || (!internal_reply && video_reply_valid);
    assign       reply             = own_valid ? own_reply : video_reply;   // 标定事务自己的应答优先；内部视频握手由状态机消费，不直接转发给 PC。
    assign       video_reply_ready = internal_reply || (!own_valid && reply_ready);
    calibration_packet_rx #(.TIMEOUT_CYCLES(RX_TICKS))                      // 逐字节接收固定长度 CAL1 包，检查包头、版本、长度、CRC32 和结束标记。
        receiver(.clk(clk),
                 .rst_n(rst_n),
                 .start(rx_start),
                 .cancel(1'b0),
                 .byte_valid(received_valid),
                 .byte_data(received_byte),
                 .busy(rx_busy),
                 .done(rx_done),
                 .error_code(rx_error),
                 .packet(update_packet));
    task respond
        (input [15 : 0] value);
        begin
            own_valid <= 1;
            own_reply <= value;
        end
    endtask
    task video_send
        (input [15 : 0] value);
        begin
            video_command_valid <= 1;
            video_command       <= value;
            timer               <= 0;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= BOOT;
            timer               <= 0;
            own_valid           <= 0;
            own_reply           <= 0;
            saved_running       <= 0;
            rx_start            <= 0;
            store_update        <= 0;
            commit_request      <= 0;
            ready               <= 0;
            video_command_valid <= 0;
            video_command       <= 0;
            crc_sequence        <= 32'hffffffff;
            crc_index           <= 0;
            payload_crc         <= 16'hffff;
        end else begin
            rx_start            <= 0;
            store_update        <= 0;
            video_command_valid <= 0;
            if (!store_boot_ready || crc_sequence != active_sequence) begin  // 参数序号改变后重新计算 80 字节活动载荷 CRC，供上位机读回核对。
                crc_sequence <= active_sequence;
                crc_index    <= 0;
                payload_crc  <= 16'hffff;
            end else if (crc_index < 80) begin
                payload_crc <= crc_byte(payload_crc, active_payload[crc_index * 8 +: 8]);
                crc_index   <= crc_index + 1'b1;
            end
            if (own_valid && reply_ready)
                own_valid <= 0;
            if (state != IDLE && state != BOOT && timer < WAIT_TICKS)
                timer <= timer + 1'b1;
            case (state)
                BOOT :                                                      // 等待 EEPROM 完成启动加载。
                    if (store_boot_ready) begin
                        commit_request <=  !commit_request;
                        timer          <= 0;
                        state          <= BOOT_COMMIT;
                    end
                BOOT_COMMIT :                                               // 把启动参数提交到处理时钟域后才允许控制操作。
                    if (commit_ack == commit_request) begin
                        ready <= 1;
                        state <= IDLE;
                    end
                STOP :                                                      // 等待视频排空确认，再允许接收新参数。
                    if (video_reply_valid && video_reply == 16'h6868) begin  // 收到停止完成后才返回 0AA0，发送端不得提前发送参数正文。
                        respond(16'h0aa0);
                        state <= ARM;
                        timer <= 0;
                    end else if (timer == WAIT_TICKS - 1) begin
                        respond(16'he007);
                        state <= IDLE;
                    end
                ARM :                                                       // 先发就绪应答，发送端收到后才能传 CAL1。
                    if (own_valid && reply_ready) begin
                        rx_start <= 1;
                        state    <= RECEIVE;
                        timer    <= 0;
                    end
                RECEIVE :                                                   // 接收并检查完整 CAL1 数据包。
                    if (rx_done) begin
                        if (rx_error != 0) begin
                            respond({8'he0, rx_error});
                            state <= IDLE;
                        end else begin
                            store_update <= 1;
                            state        <= STORE;
                            timer        <= 0;
                        end
                    end
                STORE :                                                     // 等待 EEPROM 写入、读回与提交完成。
                    if (store_done) begin
                        if (store_error != 0) begin
                            respond({8'he0, store_error});
                            state <= IDLE;
                        end else begin
                            commit_request <=  !commit_request;
                            state          <= COMMIT;
                            timer          <= 0;
                        end
                    end
                COMMIT :                                                    // 等待新活动参数跨域生效，再给出保存成功应答。
                    if (commit_ack == commit_request) begin                 // 只有处理域确认新参数已锁存后，才继续完成持久化成功事务。
                        if (saved_running) begin
                            video_send(16'h6688);
                            state <= RESUME;
                        end else begin
                            respond(16'hdcdc);
                            state <= IDLE;
                        end                                                 // EEPROM 写入及读回验证成功后确认。
                    end else if (timer == WAIT_TICKS - 1) begin
                        respond(16'he007);
                        ready <= 0;
                        state <= BOOT;
                    end
                RESUME :                                                    // 等待恢复采集的内部控制应答。
                    if (video_reply_valid && video_reply == 16'h6688) begin
                        respond(16'hdcdc);
                        state <= IDLE;
                    end else if (timer == WAIT_TICKS - 1) begin
                        video_send(16'h6868);
                        state <= RECOVER_STOP;
                    end
                RECOVER_STOP :                                              // 异常后再次请求停止，防止未确认状态继续运行。
                    if ((video_reply_valid && video_reply == 16'h6868) || timer == WAIT_TICKS - 1) begin
                        respond(16'he007);
                        state <= IDLE;
                    end
                default : begin
                end
            endcase
            if (command_valid &&  !own_valid &&  !video_reply_valid &&  !packet_mode) begin  // 事务空闲且没有待发应答时才接收新的普通命令，避免串口回复混流。
                if (command == 16'h0b02)
                    respond(ready && state == IDLE ? 16'h0b02 : 16'he007);
                else if (command == 16'h0b00)
                    respond(active_sequence[15 : 0]);
                else if (command == 16'h0b01)
                    respond(active_sequence[31 : 16]);
                else if (command == 16'h0b03)
                    respond(state == IDLE && crc_index == 80 ? payload_crc : 16'he007);
                else if (command[15 : 8] == 8'h0b && command[7 : 0] >= 8'h10 && command[7 : 0] <= 8'h37)
                    respond(state == IDLE ? active_payload[(command[7 : 0] - 8'h10) * 16 +: 16] : 16'he007);
                else if (command == 16'h0a0a) begin                         // 系数更新入口，先停止并排空视频处理。
                    if (ready && state == IDLE &&  !store_busy && (video_state == 2 || video_state == 4)) begin
                        saved_running <= video_state == 4;
                        video_send(16'h6868);
                        state <= STOP;
                    end else
                        respond(16'he007);
                end else if (command[15 : 8] != 8'h5a) begin
                    if (ready && state == IDLE)
                        video_send(command);
                    else
                        respond(16'he007);
                end
            end
        end
    end
endmodule
