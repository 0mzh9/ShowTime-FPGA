`timescale 1ns/1ps
 
 
module ddr_line_reader                                                      // 源图行读取：把一行请求拆成符合突发长度及边界要求的 DDR 事务，并核对返回标签。
    #(                                                                      // 盘古原生 DDR 字地址读取器，返回通道不可反压。
      parameter         ADDR_WIDTH = 28, COL_ADDR_WIDTH = 10, MAX_LINE_BEATS = 80,  // DDR 地址位宽。
      parameter [3 : 0] READ_ID         = 4'h8,
      parameter         WATCHDOG_CYCLES = 4096)                             // 无进展看门狗周期上限。
    (input wire clk, rst_n, ddr_init_done,                                  // 处理时钟；低有效复位；DDR 初始化完成。
     input wire command_valid,                                              // 双字节命令有效。
     output wire           command_ready,                                   // 命令接收端就绪。
     input wire [31 : 0]   command_word_addr,                               // 待读取行的 DDR 字地址。
     input wire [15 : 0]   command_beats,                                   // 当前行需要的 DDR 宽字数。
     output wire           return_valid,                                    // DDR 返回宽字有效。
     output wire [255 : 0] return_data,                                     // DDR 返回的 256 位数据。
     output wire           return_last,                                     // 当前行请求的最后一个返回宽字。
     output reg            line_done,
     output wire           busy,                                            // 事务进行中。
     output reg fault,                                                      // 锁存的故障标志。
     output reg [3 : 0] fault_code,                                         // 故障类型编码。
     output reg [ADDR_WIDTH - 1 : 0] axi_araddr,                            // DDR 读字地址。
     output wire [3 : 0] axi_aruser_id,
     output wire         axi_aruser_ap,
     output wire [3 : 0] axi_arlen,
     output wire         axi_arvalid,                                       // 读地址请求有效。
     input wire axi_arready,                                                // DDR 接受读地址。
     input wire [255 : 0] axi_rdata,                                        // 原生 DDR 返回数据。
     input wire [3 : 0] axi_rid,
     input wire         axi_rlast, axi_rvalid                               // 当前突发最后一拍；DDR 返回拍有效。
    );
    localparam   IDLE = 0, SEND = 1, RECEIVE = 2, FAILED = 3;
    reg [1 : 0]  state;
    reg [15 : 0] total, received;
    reg [4 : 0]  burst_beats, burst_received;
    reg [31 : 0] watchdog;
    assign       busy          = (state != IDLE);
    assign       command_ready = rst_n && ddr_init_done &&  !fault && state == IDLE;
    assign       axi_arvalid   = rst_n && ddr_init_done &&  !fault && state == SEND;
    assign       axi_arlen     = burst_beats - 1'b1;                        // AXI 风格长度字段编码为实际拍数减一。
    assign       axi_aruser_id = READ_ID;
    assign       axi_aruser_ap = 1'b0;

    reg [255 : 0] response_data;
    reg [3 : 0]   response_id;
    reg           response_last, response_valid;
    always @(posedge clk) begin
        response_data <= axi_rdata;
        response_id   <= axi_rid;
        response_last <= axi_rlast;
        if (!rst_n)
            response_valid <= 1'b0;
        else
            response_valid <= axi_rvalid;
    end
    wire          active_return = (state == RECEIVE);
    wire          good_return =
                      active_return && response_id == READ_ID && response_last == (burst_received == burst_beats - 1'b1);
    assign        return_valid = rst_n &&  !fault && ddr_init_done && response_valid && good_return;
    assign        return_data  = response_data;
    assign        return_last  = return_valid && received == total - 1'b1;  // 只在整行最后一个宽字到达时标记 return_last，而非每次突发的末拍。
    wire [32 : 0] last_word    = {1'b0, command_word_addr} + ({17'd0, command_beats} << 3) - 1'b1;
    wire          bad_command = command_beats == 0 || command_beats > MAX_LINE_BEATS || command_word_addr[2 : 0] != 0 ||
                                (last_word >> ADDR_WIDTH) != 0;

    function [4 : 0] choose_burst;                                          // 选择本次允许的突发拍数，同时顾及剩余长度及 DDR 行列边界。
        input [31 : 0] address;
        input [15 : 0] remaining;
        integer        available, amount;
        begin
            available = ((1 << COL_ADDR_WIDTH) - (address & ((1 << COL_ADDR_WIDTH) - 1))) >> 3;
            amount    = remaining > 16 ? 16 : remaining;
            if (available < amount)
                amount = available;
            choose_burst = amount;
        end
    endfunction
    wire [ADDR_WIDTH - 1 : 0] next_address = axi_araddr + ({{(ADDR_WIDTH - 5){1'b0}}, burst_beats} << 3);
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= IDLE;
            fault          <= 0;
            fault_code     <= 0;
            line_done      <= 0;
            axi_araddr     <= 0;
            total          <= 0;
            received       <= 0;
            burst_beats    <= 0;
            burst_received <= 0;
            watchdog       <= 0;
        end else begin
            line_done <= 0;
            if (!fault) begin
                if (state != IDLE &&  !ddr_init_done) begin
                    fault      <= 1;
                    fault_code <= 5;
                    state      <= FAILED;
                end else if (response_valid &&  !good_return) begin         // 返回 ID、末拍或计数异常时锁存故障，阻止错误数据进入缓存。
                    fault <= 1;
                    state <= FAILED;
                    if (!active_return)
                        fault_code <= 2;
                    else if (response_id != READ_ID)
                        fault_code <= 3;
                    else
                        fault_code <= 4;
                end else if (state != IDLE && WATCHDOG_CYCLES != 0 && watchdog >= WATCHDOG_CYCLES - 1 &&
                             !(axi_arvalid && axi_arready) &&  !return_valid) begin
                    fault      <= 1;
                    fault_code <= 6;
                    state      <= FAILED;
                end else begin
                    if (state == IDLE || (axi_arvalid && axi_arready) || return_valid)
                        watchdog <= 0;
                    else
                        watchdog <= watchdog + 1'b1;
                    case (state)
                        IDLE :                                              // 接收行基址和宽字数量。
                            if (command_valid && command_ready) begin
                                if (bad_command) begin
                                    fault      <= 1;
                                    fault_code <= 1;
                                    state      <= FAILED;
                                end else begin
                                    axi_araddr     <= command_word_addr[ADDR_WIDTH - 1 : 0];
                                    total          <= command_beats;
                                    received       <= 0;
                                    burst_received <= 0;
                                    burst_beats    <= choose_burst(command_word_addr, command_beats);
                                    state          <= SEND;
                                end
                            end
                        SEND :                                              // 提出本次分段突发读地址。
                            if (axi_arvalid && axi_arready)
                                state <= RECEIVE;
                        RECEIVE : begin                                     // 接收并计数当前突发，必要时继续下一段。
                        end
                        default : begin
                            fault      <= 1;
                            fault_code <= 7;
                            state      <= FAILED;
                        end
                    endcase
                    if (return_valid) begin
                        received <= received + 1'b1;
                        if (response_last) begin
                            burst_received <= 0;
                            if (received == total - 1'b1) begin
                                state     <= IDLE;
                                line_done <= 1;
                            end else begin
                                axi_araddr  <= next_address;
                                burst_beats <= choose_burst(next_address, total - received - 1'b1);
                                state       <= SEND;
                            end
                        end else
                            burst_received <= burst_received + 1'b1;
                    end
                end
            end
        end
    end
endmodule
