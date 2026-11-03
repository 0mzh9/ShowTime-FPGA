//////////////////////////////////////////////////////////////////////////////////
//                                                                              //
//                                                                              //
//  Author: meisq                                                               //
//          msq@qq.com                                                          //
//          ALINX(shanghai) Technology Co.,Ltd                                  //
//          heijin                                                              //
//     WEB: http://www.alinx.cn/                                                //
//     BBS: http://www.heijin.org/                                              //
//                                                                              //
//////////////////////////////////////////////////////////////////////////////////
//                                                                              //
// Copyright (c) 2017,ALINX(shanghai) Technology Co.,Ltd                        //
//                    All rights reserved                                       //
//                                                                              //
// This source file may be used and distributed without restriction provided    //
// that this copyright statement is not removed from the file and that any      //
// derivative work contains the original copyright notice and the associated    //
// disclaimer.                                                                  //
//                                                                              //
//////////////////////////////////////////////////////////////////////////////////

//================================================================================
//  Revision History:
//  Date          By            Revision    Change Description
//--------------------------------------------------------------------------------
//  2017/7/19     meisq          1.0         Original
//*******************************************************************************/

 
 
module i2c_config                                                           // 相机寄存器初始化：顺序写配置表，再读回关键寄存器；异常时保留诊断现场。
    #(parameter integer RESET_DELAY_CYCLES = 500000,                        // 复位后等待时间；正式时钟频率以顶层连接为准。
      parameter integer TIMEOUT_CYCLES = 1000000                            // 限定单笔寄存器事务最长等待时间。
    )
    (input rst,
     input clk,                                                             // 处理时钟。
     input [15 : 0]     clk_div_cnt,
     input              i2c_addr_2byte,
     output reg [9 : 0] lut_index,
     input [7 : 0]      lut_dev_addr,
     input [15 : 0]     lut_reg_addr,
     input [7 : 0]      lut_reg_data,
     output reg         error,
     output             done,                                               // 事务完成脉冲。
     inout               i2c_scl,
     inout               i2c_sda,
     output reg [15 : 0] sensor_id,
     output reg [3 : 0]  error_code,                                        // 错误原因编码。
     output [95 : 0] debug_status,
     output [63 : 0] debug_bus);
    wire   scl_pad_i, scl_pad_o, scl_padoen_o;
    wire   sda_pad_i, sda_pad_o, sda_padoen_o;
    assign sda_pad_i = i2c_sda;
    assign i2c_sda   =  ~sda_padoen_o ? sda_pad_o : 1'bz;                   // 开漏总线：不驱动时释放 SDA，由上拉电阻提供高电平。
    assign scl_pad_i = i2c_scl;
    assign i2c_scl   =  ~scl_padoen_o ? scl_pad_o : 1'bz;                   // SCL 也按输出使能控制释放，保留底层时钟延展处理。

    reg           i2c_read_req, i2c_write_req;
    wire          i2c_read_req_ack, i2c_write_req_ack;
    wire [7 : 0]  i2c_read_data;
    wire          err;
    wire [3 : 0]  master_nack_state;
    reg [15 : 0]  transaction_address;                                      // 记录事务地址，便于错误后诊断。
    reg [7 : 0]   transaction_value, last_read_value;
    reg           transaction_read;
    reg [3 : 0]   failed_nack_state;
    reg [15 : 0]  controller_snapshot;
    reg           arbitration_seen;
    wire [59 : 0] master_debug_bus;
    localparam    S_WRITE_START = 0, S_WRITE_WAIT = 1, S_DELAY = 2, S_READ_START = 3, S_READ_WAIT = 4, S_DONE = 5,
                  S_ERROR = 6;
    reg [2 : 0]   state;
    reg [2 : 0]   read_index;
    reg [31 : 0]  delay_count, timeout_count;
    reg [15 : 0]  read_address;
    reg [7 : 0]   expected_data;
    wire          reading            = state == S_READ_START || state == S_READ_WAIT;
    wire [7 : 0]  i2c_slave_dev_addr = reading ? 8'h78 : lut_dev_addr;
    wire [15 : 0] i2c_slave_reg_addr = reading ? read_address : lut_reg_addr;
    wire [7 : 0]  i2c_write_data     = lut_reg_data;
    assign        done               = state == S_DONE;

    assign debug_status[15 : 0]  = sensor_id;
    assign debug_status[31 : 16] = transaction_address;
    assign debug_status[39 : 32] = transaction_value;
    assign debug_status[47 : 40] = last_read_value;
    assign debug_status[57 : 48] = lut_index;
    assign debug_status[61 : 58] = error_code;
    assign debug_status[64 : 62] = state;
    assign debug_status[67 : 65] = read_index;
    assign debug_status[68]      = transaction_read;
    assign debug_status[72 : 69] = failed_nack_state;
    assign debug_status[73]      = done;
    assign debug_status[74]      = error;
    assign debug_status[75]      = scl_pad_i;
    assign debug_status[76]      = sda_pad_i;
    assign debug_status[77]      = scl_padoen_o;
    assign debug_status[78]      = sda_padoen_o;
    assign debug_status[94 : 79] = controller_snapshot;
    assign debug_status[95]      = arbitration_seen;
    assign debug_bus             = {rst, state, master_debug_bus};
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            controller_snapshot <= 0;
            arbitration_seen    <= 0;
        end else if (state != S_ERROR) begin
            controller_snapshot <= {master_debug_bus[37], master_debug_bus[16 : 8], master_debug_bus[5 : 0]};
            if (master_debug_bus[4])
                arbitration_seen <= 1;
        end
    end

    always @ * begin
        case (read_index)
            0 : begin
                read_address  = 16'h300a;
                expected_data = 8'h56;
            end
            1 : begin
                read_address  = 16'h300b;
                expected_data = 8'h40;
            end
            2 : begin
                read_address  = 16'h4300;
                expected_data = 8'h61;
            end
            3 : begin
                read_address  = 16'h501f;
                expected_data = 8'h01;
            end
            4 : begin
                read_address  = 16'h3808;
                expected_data = 8'h05;
            end
            5 : begin
                read_address  = 16'h3809;
                expected_data = 8'h00;
            end
            6 : begin
                read_address  = 16'h380a;
                expected_data = 8'h02;
            end
            7 : begin
                read_address  = 16'h380b;
                expected_data = 8'hd0;
            end
            default : begin
                read_address  = 16'h300a;
                expected_data = 8'h56;
            end
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state               <= S_WRITE_START;
            lut_index           <= 0;
            i2c_read_req        <= 0;
            i2c_write_req       <= 0;
            read_index          <= 0;
            delay_count         <= 0;
            timeout_count       <= 0;
            sensor_id           <= 0;
            error               <= 0;
            error_code          <= 0;
            transaction_address <= 0;
            transaction_value   <= 0;
            last_read_value     <= 0;
            transaction_read    <= 0;
            failed_nack_state   <= 0;
        end else begin
            if (state == S_WRITE_WAIT || state == S_READ_WAIT)
                timeout_count <= timeout_count + 1'b1;
            else
                timeout_count <= 0;
            case (state)
                S_WRITE_START : begin                                       // 锁存当前查表项并提出相机寄存器写请求。
                    if (lut_dev_addr == 8'hff) begin
                        read_index <= 2;
                        state      <= S_READ_START;
                    end else begin
                        transaction_address <= lut_reg_addr;
                        transaction_value   <= lut_reg_data;
                        transaction_read    <= 0;
                        i2c_write_req       <= 1;
                        state               <= S_WRITE_WAIT;
                    end
                end
                S_WRITE_WAIT : begin                                        // 等待字节事务应答，失败或超时进入错误状态。
                    if (i2c_write_req_ack) begin
                        i2c_write_req <= 0;
                        if (err) begin
                            failed_nack_state <= master_nack_state;
                            error             <= 1;
                            error_code        <= 1;
                            state             <= S_ERROR;
                        end else begin
                            lut_index   <= lut_index + 1'b1;
                            delay_count <= 0;

                            state <= (lut_reg_addr == 16'h3008 && lut_reg_data[7])
                                         ?                                  // 根据寄存器地址和值识别摄像头软件复位。
                                         S_DELAY
                                         : S_WRITE_START;
                        end
                    end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
                        i2c_write_req <= 0;
                        error         <= 1;
                        error_code    <= 2;
                        state         <= S_ERROR;
                    end
                end
                S_DELAY : begin                                             // 在需要稳定时间的配置步骤之间等待。
                    if (delay_count >= RESET_DELAY_CYCLES - 1) begin
                        read_index <= 0;
                        state      <= S_READ_START;
                    end else
                        delay_count <= delay_count + 1'b1;
                end
                S_READ_START : begin                                        // 提出关键寄存器读回请求。
                    transaction_address <= read_address;
                    transaction_value   <= expected_data;
                    transaction_read    <= 1;
                    i2c_read_req        <= 1;
                    state               <= S_READ_WAIT;
                end
                S_READ_WAIT : begin                                         // 核对传感器标识及配置回读值。
                    if (i2c_read_req_ack) begin
                        last_read_value <= i2c_read_data;
                        i2c_read_req    <= 0;
                        if (read_index == 0)
                            sensor_id[15 : 8] <= i2c_read_data;
                        if (read_index == 1)
                            sensor_id[7 : 0] <= i2c_read_data;
                        if (err) begin
                            failed_nack_state <= master_nack_state;
                            error             <= 1;
                            error_code        <= 1;
                            state             <= S_ERROR;
                        end else if (i2c_read_data != expected_data) begin
                            error      <= 1;
                            error_code <= (read_index < 2) ? 3 : 4;
                            state      <= S_ERROR;
                        end else if (read_index == 1) begin
                            state <= S_WRITE_START;
                        end else if (read_index == 7) begin
                            state <= S_DONE;
                        end else begin
                            read_index <= read_index + 1'b1;
                            state      <= S_READ_START;
                        end
                    end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
                        i2c_read_req <= 0;
                        error        <= 1;
                        error_code   <= 2;
                        state        <= S_ERROR;
                    end
                end
                S_DONE : begin                                              // 保持初始化完成状态。
                    i2c_read_req  <= 0;
                    i2c_write_req <= 0;
                end
                S_ERROR : begin                                             // 冻结错误原因与最后事务，便于串口诊断。
                    i2c_read_req  <= 0;
                    i2c_write_req <= 0;
                end
                default : begin
                    error      <= 1;
                    error_code <= 2;
                    state      <= S_ERROR;
                end
            endcase
        end
    end

    i2c_master_top i2c_master_top_m0(.rst(rst | (state == S_ERROR)),        // I2C 单笔寄存器事务：组合设备地址、寄存器地址和数据，返回完成或无应答状态。
                                     .clk(clk),
                                     .clk_div_cnt(clk_div_cnt),

                                     // I2C signals
                                     // i2c clock line
                                     .scl_pad_i(scl_pad_i),                 // SCL 时钟线输入。
                                     .scl_pad_o(scl_pad_o),                 // SCL 输出值，始终为 1'b0。
                                     .scl_padoen_o(scl_padoen_o),           // SCL 输出使能，低电平有效。

                                     // i2c data line
                                     .sda_pad_i(sda_pad_i),                 // SDA 数据线输入。
                                     .sda_pad_o(sda_pad_o),                 // SDA 输出值，始终为 1'b0。
                                     .sda_padoen_o(sda_padoen_o),           // SDA 输出使能，低电平有效。

                                     .i2c_read_req(i2c_read_req),
                                     .i2c_addr_2byte(i2c_addr_2byte),
                                     .i2c_read_req_ack(i2c_read_req_ack),
                                     .i2c_write_req(i2c_write_req),
                                     .i2c_write_req_ack(i2c_write_req_ack),
                                     .i2c_slave_dev_addr(i2c_slave_dev_addr),
                                     .i2c_slave_reg_addr(i2c_slave_reg_addr),
                                     .i2c_write_data(i2c_write_data),
                                     .i2c_read_data(i2c_read_data),
                                     .error(err),
                                     .nack_state(master_nack_state),
                                     .debug_bus(master_debug_bus));
endmodule
