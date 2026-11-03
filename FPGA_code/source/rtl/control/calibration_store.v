`timescale 1ns/1ps
 
 
 
 
module calibration_store                                                    // 24LC02 双槽参数管理：启动择新加载，更新先写备用槽、读回核对再提交。
    #(parameter POWERUP_TICKS = 270000, WRITE_TICKS = 162000)
    (input wire clk, rst_n, update,                                         // 系统控制时钟（顶层为 27 MHz）；低有效复位；请求更新系数。
     input wire [783 : 0] update_packet,                                    // 待持久化的 CAL1 数据包。
     output reg boot_ready, busy, done,                                     // 上电系数读取已完成；事务进行中；事务完成脉冲。
     output reg [7 : 0] error_code,                                         // 错误原因编码。
     output reg [639 : 0] active_payload,                                   // 当前有效的 80 字节系数。
     output reg [31 : 0] active_sequence,                                   // 当前系数序号。
     output reg active_present, active_slot,                                // 存在有效持久化系数；当前有效槽位。
     output reg bus_valid, bus_write,                                       // 字节总线请求有效；字节事务写方向。
     output reg [7 : 0] bus_addr, bus_wdata,                                // EEPROM 字节地址；EEPROM 写入字节。
     input wire bus_ready, bus_done, bus_error,                             // 总线可接收请求；字节事务完成；字节事务出错。
     input wire [7 : 0] bus_rdata                                           // EEPROM 读回字节。
    );

    localparam [639 : 0]
                   FACTORY =
                       640'h002054be003d39fa001514be002939fa00000000000000000000000000000000000000005571831e0000000055840bac001514be002939fa002ff02b002fe5c80438078002d0050002d0050000000000;  // 无有效 EEPROM 记录时使用出厂旁路参数。
    localparam     POWER = 0, BOOT_M0 = 1, BOOT_M1 = 2, BOOT_BODY = 3, BOOT_START = 4, BOOT_FEED = 5, BOOT_VALIDATE = 6,
                   BOOT_NEXT = 7, IDLE = 8, UPDATE_CHECK = 9, INVALID0 = 10, INVALID1 = 11, WRITE_BODY = 12, READ_BODY = 13,
                   COMMIT0 = 14, COMMIT1 = 15, SUCCESS = 16, FAIL = 17, BUS_REQ = 20, BUS_WAIT = 21, WRITE_WAIT = 22,
                   WRITE_CHECK = 23, WRITE_RESULT = 24;
    reg [5 : 0]    state, after_bus, after_write;
    reg [31 : 0]   timer;
    reg            slot, target_slot;
    reg [6 : 0]    index;
    reg [783 : 0]  staged;
    reg [7 : 0]    last_data;
    reg            last_error;
    reg            verify_start, verify_byte;
    reg [7 : 0]    verify_data;
    wire           verify_busy, verify_done;
    wire [7 : 0]   verify_error;
    wire [783 : 0] verified_packet;
    wire           boot_fields, update_fields;
    wire [31 : 0]  sequence_delta = staged[95 : 64] - active_sequence;      // 用序号差值识别更新记录，并兼容序号回绕。
    calibration_packet_rx    verifier(.clk(clk),                            // 逐字节接收固定长度 CAL1 包，检查包头、版本、长度、CRC32 和结束标记。
                                      .rst_n(rst_n),
                                      .start(verify_start),
                                      .cancel(1'b0),                        // 复用完整数据包校验器核验 EEPROM 读回内容。
                                      .byte_valid(verify_byte),
                                      .byte_data(verify_data),
                                      .busy(verify_busy),
                                      .done(verify_done),
                                      .error_code(verify_error),
                                      .packet(verified_packet));
    calibration_fields_valid boot_check(.payload(verified_packet[735 : 96]),  // 检查已量化参数的尺寸、符号扩展与取值范围；不进行棋盘格标定计算。
                                        .valid(boot_fields));
    calibration_fields_valid update_check(.payload(staged[735 : 96]),       // 检查已量化参数的尺寸、符号扩展与取值范围；不进行棋盘格标定计算。
                                          .valid(update_fields));
    task read_at
        (input [7 : 0] address,
         input [5 : 0] next_state);
        begin
            bus_addr  <= address;
            bus_write <= 0;
            after_bus <= next_state;
            state     <= BUS_REQ;
        end
    endtask
    task write_at
        (input [7 : 0] address,
         input [7 : 0] value,
         input [5 : 0] next_state);
        begin
            bus_addr    <= address;
            bus_wdata   <= value;
            bus_write   <= 1;
            after_bus   <= WRITE_WAIT;
            after_write <= next_state;
            state       <= BUS_REQ;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= POWER;
            timer           <= 0;
            slot            <= 0;
            target_slot     <= 0;
            index           <= 0;
            staged          <= 0;
            boot_ready      <= 0;
            busy            <= 1;
            done            <= 0;
            error_code      <= 0;
            active_payload  <= FACTORY;
            active_sequence <= 0;
            active_present  <= 0;
            active_slot     <= 0;
            bus_valid       <= 0;
            bus_write       <= 0;
            bus_addr        <= 0;
            bus_wdata       <= 0;
            after_bus       <= 0;
            after_write     <= 0;
            last_error      <= 0;
            last_data       <= 0;
            verify_start    <= 0;
            verify_byte     <= 0;
            verify_data     <= 0;
        end else begin
            done         <= 0;
            verify_start <= 0;
            verify_byte  <= 0;
            case (state)
                POWER :                                                     // 等待器件上电稳定，再依次检查两个参数槽。
                    if (timer == POWERUP_TICKS - 1) begin
                        timer <= 0;
                        read_at(0, BOOT_M0);
                    end else
                        timer <= timer + 1'b1;
                BOOT_M0 :                                                   // 核对槽首提交标志的第一字节。
                    if (last_error || last_data != 8'hc3)
                        state <= BOOT_NEXT;                                 // 先检查当前槽位的首个提交标记。
                    else
                        read_at({slot, 7'd1}, BOOT_M1);
                BOOT_M1 :                                                   // 核对第二字节标志，拒绝未提交的槽。
                    if (last_error || last_data != 8'h3c)
                        state <= BOOT_NEXT;                                 // 第二个提交标记也有效后才读取正文。
                    else begin
                        index <= 0;
                        read_at({slot, 7'd2}, BOOT_BODY);
                    end
                BOOT_BODY :                                                 // 读取候选槽中的完整 CAL1 记录。
                    if (last_error)
                        state <= BOOT_NEXT;
                    else begin
                        staged[index * 8 +: 8] <= last_data;
                        if (index == 97)
                            state <= BOOT_START;
                        else begin
                            index <= index + 1'b1;
                            read_at({slot, 7'd3} + index, BOOT_BODY);
                        end
                    end
                BOOT_START : begin                                          // 启动与串口相同的数据包验证器。
                    verify_start <= 1;
                    index        <= 0;
                    state        <= BOOT_FEED;
                end
                BOOT_FEED :                                                 // 把 EEPROM 读回的字节逐一送入验证器。
                    if (verify_busy) begin
                        verify_byte <= 1;
                        verify_data <= staged[index * 8 +: 8];
                        if (index == 97)
                            state <= BOOT_VALIDATE;
                        else
                            index <= index + 1'b1;
                    end
                BOOT_VALIDATE :                                             // 只在包校验、字段检查和序号比较通过后选用此槽。
                    if (verify_done) begin                                  // 只启用通过完整校验且序号较新的记录。
                        if (verify_error == 0 && boot_fields &&
                            (!active_present || $signed(verified_packet[95 : 64] - active_sequence) > 0)) begin
                            active_payload  <= verified_packet[735 : 96];
                            active_sequence <= verified_packet[95 : 64];
                            active_present  <= 1;
                            active_slot     <= slot;
                        end
                        state <= BOOT_NEXT;
                    end
                BOOT_NEXT :                                                 // 检查下一个槽；没有有效记录时保留出厂直通载荷。
                    if (!slot) begin
                        slot <= 1;
                        read_at(8'h80, BOOT_M0);
                    end else begin
                        boot_ready <= 1;
                        busy       <= 0;
                        state      <= IDLE;
                    end
                IDLE :                                                      // 等待新的参数保存请求，已有活动槽继续有效。
                    if (update) begin
                        staged      <= update_packet;
                        target_slot <= active_present ?  !active_slot : 1'b0;  // 写入非当前槽位，保留旧参数作为掉电回退。
                        busy        <= 1;
                        error_code  <= 0;
                        state       <= UPDATE_CHECK;
                    end
                UPDATE_CHECK :                                              // 检查字段及新序号，通过后开始清除备用槽提交标记。
                    if (!update_fields || $signed(sequence_delta) <= 0) begin
                        error_code <= 3;
                        state      <= FAIL;
                    end else
                        write_at({target_slot, 7'd0}, 0, INVALID0);
                INVALID0 :                                                  // 首字节标记已清除，继续清除第二字节。
                    write_at({target_slot, 7'd1}, 0, INVALID1);             // 写正文之前先使目标槽位失效。
                INVALID1 : begin                                            // 两个标记均已失效，开始写入候选记录。
                    index <= 0;
                    write_at({target_slot, 7'd2}, staged[7 : 0], WRITE_BODY);
                end
                WRITE_BODY :                                                // 按字节写入候选 CAL1 记录。
                    if (index == 97) begin
                        index <= 0;
                        read_at({target_slot, 7'd2}, READ_BODY);
                    end else begin
                        index <= index + 1'b1;
                        write_at({target_slot, 7'd3} + index, staged[(index + 1) * 8 +: 8], WRITE_BODY);
                    end
                READ_BODY :                                                 // 逐字节读回并与候选记录比较。
                    if (last_error || last_data != staged[index * 8 +: 8]) begin
                        error_code <= 5;
                        state      <= FAIL;
                    end                                                     // 逐字节读回比对，全部通过后才允许提交。
                    else if (index == 97)
                        write_at({target_slot, 7'd0}, 8'hc3, COMMIT0);
                    else begin
                        index <= index + 1'b1;
                        read_at({target_slot, 7'd3} + index, READ_BODY);
                    end
                COMMIT0 :                                                   // 第一字节提交标志已写完，继续写第二字节。
                    write_at({target_slot, 7'd1}, 8'h3c, COMMIT1);          // 正文核验完成后最后写入提交标记。
                COMMIT1 :                                                   // 两字节提交均已写完，转入活动参数切换。
                    state <= SUCCESS;
                SUCCESS : begin                                             // 确认持久化成功后切换正在使用的参数。
                    active_payload  <= staged[735 : 96];
                    active_sequence <= staged[95 : 64];
                    active_present  <= 1;
                    active_slot     <= target_slot;
                    busy            <= 0;
                    done            <= 1;
                    state           <= IDLE;
                end
                FAIL : begin                                                // 返回错误，保持原先活动参数。
                    busy  <= 0;
                    done  <= 1;
                    state <= IDLE;
                end
                BUS_REQ : begin                                             // 等待底层单字节接口接收事务。
                    bus_valid <= 1;
                    if (bus_valid && bus_ready) begin
                        bus_valid <= 0;
                        state     <= BUS_WAIT;
                    end
                end
                BUS_WAIT :                                                  // 等待单字节读写完成并保存返回状态。
                    if (bus_done) begin
                        last_error <= bus_error;
                        last_data  <= bus_rdata;
                        state      <= after_bus;
                        timer      <= 0;
                    end

                WRITE_WAIT :                                                // 写后等待 EEPROM 内部写周期结束。
                    if (last_error) begin
                        error_code <= 4;
                        state      <= FAIL;
                    end                                                     // 等待 EEPROM 内部写周期结束后再检查结果。
                    else if (timer == WRITE_TICKS - 1)
                        state <= WRITE_CHECK;
                    else
                        timer <= timer + 1'b1;
                WRITE_CHECK :                                               // 读回刚写入的地址以核验单字节写入。
                    read_at(bus_addr, WRITE_RESULT);
                WRITE_RESULT :                                              // 检查单字节核验结果，成功后返回上层状态。
                    if (last_error) begin
                        error_code <= 4;
                        state      <= FAIL;
                    end else if (last_data != bus_wdata) begin
                        error_code <= 5;
                        state      <= FAIL;
                    end else
                        state <= after_write;
                default : begin
                    error_code <= 7;
                    state      <= FAIL;
                end
            endcase
        end
    end
endmodule
