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

module i2c_master_top                                                       // I2C 单笔寄存器事务：组合设备地址、寄存器地址和数据，返回完成或无应答状态。
    (input rst,
     input clk,                                                             // 处理时钟。
     input [15 : 0] clk_div_cnt,

     // I2C signals
     // i2c clock line
     input scl_pad_i,                                                       // SCL 时钟线输入。
     output scl_pad_o,                                                      // SCL 输出值，始终为 1'b0。
     output scl_padoen_o,                                                   // SCL 输出使能，低电平有效。
     // i2c data line                            
     input sda_pad_i,                                                       // SDA 数据线输入。
     output sda_pad_o,                                                      // SDA 输出值，始终为 1'b0。
     output sda_padoen_o,                                                   // SDA 输出使能，低电平有效。
     input i2c_addr_2byte,                                                  // 寄存器地址是否为 16 位。
     input i2c_read_req,                                                    // 读取寄存器请求。
     output i2c_read_req_ack,                                               // 读取寄存器请求应答。
     input i2c_write_req,                                                   // 写入寄存器请求。
     output i2c_write_req_ack,                                              // 写入寄存器请求应答。
     input [7 : 0] i2c_slave_dev_addr,                                      // I2C 设备地址。
     input [15 : 0] i2c_slave_reg_addr,                                     // I2C 寄存器地址。
     input [7 : 0] i2c_write_data,                                          // I2C 寄存器写入数据。
     output reg [7 : 0] i2c_read_data,                                      // I2C 寄存器读出数据。
     output reg error,                                                      // 错误指示，通常表示设备未应答。
     output reg [3 : 0] nack_state,
     output [59 : 0]    debug_bus);
    //State machine definition
    localparam   S_IDLE         = 0;                                        // 空闲状态，等待读写请求。
    localparam   S_WR_DEV_ADDR  = 1;                                        // 写入设备地址。
    localparam   S_WR_REG_ADDR  = 2;                                        // 写入寄存器地址。
    localparam   S_WR_DATA      = 3;                                        // 写入寄存器数据。
    localparam   S_WR_ACK       = 4;                                        // 写入请求应答。
    localparam   S_WR_ERR_NACK  = 5;                                        // 写入错误：I2C 设备未响应。
    localparam   S_RD_DEV_ADDR0 = 6;                                        // I2C 读取流程先发送设备地址和寄存器地址。
    localparam   S_RD_REG_ADDR  = 7;                                        // I2C 读取流程发送 8 位寄存器地址。
    localparam   S_RD_DEV_ADDR1 = 8;                                        // 再次发送设备地址。
    localparam   S_RD_DATA      = 9;                                        // 读取数据。
    localparam   S_RD_STOP      = 10;                                       // 读取结束后发送停止条件。
    localparam   S_WR_STOP      = 11;                                       // 写入结束后发送停止条件。
    localparam   S_WAIT         = 12;
    localparam   S_WR_REG_ADDR1 = 13;                                       // 使用双字节寄存器地址时，追加另一个地址字节。
    localparam   S_RD_REG_ADDR1 = 14;                                       // 读取双字节地址寄存器时，先完成剩余地址字节。
    localparam   S_RD_ACK       = 15;                                       // 停止条件完成后，向上层发布寄存器读取结束。
    reg          start;
    reg          stop;
    reg          read;
    reg          write;
    reg          ack_in;
    reg [7 : 0]  txr;
    wire [7 : 0] rxr;
    wire         i2c_busy;
    wire         i2c_al;
    wire         done;
    wire         irxack;
    reg [3 : 0]  state, next_state;

    reg transfer_read;

    wire [31 : 0] byte_debug;
    assign        debug_bus = {
                      byte_debug[31 : 28], rxr, txr, byte_debug[27 : 0], state, done, error, i2c_busy, i2c_al,
                      sda_padoen_o, scl_padoen_o, sda_pad_i, scl_pad_i};
    always @(posedge clk or posedge rst)
        if (rst)
            nack_state <= 0;
        else if (next_state == S_WR_ERR_NACK && state != S_WR_ERR_NACK)
            nack_state <= state;
    always @(posedge clk or posedge rst)
        if (rst)
            transfer_read <= 1'b0;
        else if (state == S_IDLE)
            transfer_read <=  !i2c_write_req && i2c_read_req;
    assign i2c_read_req_ack  = (state == S_RD_ACK);                         // 读应答对应完整寄存器读事务结束，不是单个位操作完成。
    assign i2c_write_req_ack = (state == S_WR_ACK);                         // 写应答对应完整寄存器写事务结束。
    always @(posedge clk or posedge rst) begin
        if (rst)
            state <= S_IDLE;
        else
            state <= next_state;
    end
    always @(*) begin
        case (state)
            S_IDLE :
                //Waiting for read and write requests
                if (i2c_write_req)
                    next_state <= S_WR_DEV_ADDR;
                else if (i2c_read_req)
                    next_state <= S_RD_DEV_ADDR0;
                else
                    next_state <= S_IDLE;
            //Write I2C device address
            S_WR_DEV_ADDR :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= S_WR_REG_ADDR;
                else
                    next_state <= S_WR_DEV_ADDR;
            //Write the address of the I2C register
            S_WR_REG_ADDR :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    //If it is the 8bit register address, it enters the write data state
                    next_state <= i2c_addr_2byte ? S_WR_REG_ADDR1 : S_WR_DATA;
                else
                    next_state <= S_WR_REG_ADDR;
            S_WR_REG_ADDR1 :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= S_WR_DATA;
                else
                    next_state <= S_WR_REG_ADDR1;
            //Write data		
            S_WR_DATA :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= S_WR_STOP;
                else
                    next_state <= S_WR_DATA;
            S_WR_ERR_NACK :
                next_state <= transfer_read ? S_RD_STOP : S_WR_STOP;
            S_RD_ACK, S_WR_ACK :
                next_state <= S_WAIT;
            S_WAIT :
                next_state <= S_IDLE;
            S_RD_DEV_ADDR0 :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= S_RD_REG_ADDR;
                else
                    next_state <= S_RD_DEV_ADDR0;
            S_RD_REG_ADDR :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= i2c_addr_2byte ? S_RD_REG_ADDR1 : S_RD_DEV_ADDR1;
                else
                    next_state <= S_RD_REG_ADDR;
            S_RD_REG_ADDR1 :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= S_RD_DEV_ADDR1;
                else
                    next_state <= S_RD_REG_ADDR1;
            S_RD_DEV_ADDR1 :
                if (done && irxack)
                    next_state <= S_WR_ERR_NACK;
                else if (done)
                    next_state <= S_RD_DATA;
                else
                    next_state <= S_RD_DEV_ADDR1;
            S_RD_DATA :
                if (done)
                    next_state <= S_RD_STOP;
                else
                    next_state <= S_RD_DATA;
            S_RD_STOP :
                if (done)
                    next_state <= S_RD_ACK;
                else
                    next_state <= S_RD_STOP;
            S_WR_STOP :
                if (done)
                    next_state <= S_WR_ACK;
                else
                    next_state <= S_WR_STOP;
            default :
                next_state <= S_IDLE;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            error <= 1'b0;
        else if (state == S_IDLE)
            error <= 1'b0;
        else if (state == S_WR_ERR_NACK)
            error <= 1'b1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            start <= 1'b0;
        else if (done)
            start <= 1'b0;
        else if (state == S_WR_DEV_ADDR || state == S_RD_DEV_ADDR0 || state == S_RD_DEV_ADDR1)
            start <= 1'b1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst)
            stop <= 1'b0;
        else if (done)
            stop <= 1'b0;
        else if (state == S_WR_STOP || state == S_RD_STOP)
            stop <= 1'b1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst)
            ack_in <= 1'b0;
        else
            ack_in <= 1'b1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst)
            write <= 1'b0;
        else if (done)
            write <= 1'b0;
        else if (state == S_WR_DEV_ADDR || state == S_WR_REG_ADDR || state == S_WR_REG_ADDR1 || state == S_WR_DATA ||
                 state == S_RD_DEV_ADDR0 || state == S_RD_DEV_ADDR1 || state == S_RD_REG_ADDR ||
                 state == S_RD_REG_ADDR1)
            write <= 1'b1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst)
            read <= 1'b0;
        else if (done)
            read <= 1'b0;
        else if (state == S_RD_DATA)
            read <= 1'b1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            i2c_read_data <= 8'h00;
        else if (state == S_RD_DATA && done)
            i2c_read_data <= rxr;
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            txr <= 8'd0;
        else
            case (state)
                S_WR_DEV_ADDR, S_RD_DEV_ADDR0 :
                    txr <= {i2c_slave_dev_addr[7 : 1], 1'b0};
                S_RD_DEV_ADDR1 :
                    txr <= {i2c_slave_dev_addr[7 : 1], 1'b1};
                S_WR_REG_ADDR, S_RD_REG_ADDR :
                    txr <= (i2c_addr_2byte == 1'b1) ? i2c_slave_reg_addr[15 : 8] : i2c_slave_reg_addr[7 : 0];
                S_WR_REG_ADDR1, S_RD_REG_ADDR1 :
                    txr <= i2c_slave_reg_addr[7 : 0];
                S_WR_DATA :
                    txr <= i2c_write_data;
                default :
                    txr <= 8'hff;
            endcase
    end
    i2c_master_byte_ctrl byte_controller(.clk(clk),                         // I2C 字节控制器：组织八位移位和第九位应答，底层位操作完成后再推进。
                                         .rst(1'b0),
                                         .nReset(~rst),
                                         .ena(1'b1),
                                         .clk_cnt(clk_div_cnt),
                                         .start(start),
                                         .stop(stop),
                                         .read(read),
                                         .write(write),
                                         .ack_in(ack_in),
                                         .din(txr),
                                         .cmd_ack(done),
                                         .ack_out(irxack),
                                         .dout(rxr),
                                         .i2c_busy(i2c_busy),
                                         .i2c_al(i2c_al),
                                         .scl_i(scl_pad_i),
                                         .scl_o(scl_pad_o),
                                         .scl_oen(scl_padoen_o),
                                         .sda_i(sda_pad_i),
                                         .sda_o(sda_pad_o),
                                         .sda_oen(sda_padoen_o),
                                         .debug_state(byte_debug));
endmodule
