`timescale 1ns/1ps
 
 
 
module eeprom_byte_port                                                     // EEPROM 单字节读写封装：锁存地址和数据，将 I2C 完成及超时统一返回上层。
    #(parameter CLOCK_HZ = 27000000, I2C_DIV = 53,                          // 24LC02 单字节事务接口，底层为开漏 I2C。
                TIMEOUT_CYCLES = CLOCK_HZ / 50)
    (input wire         clk, rst_n, valid, write_byte,                      // 本模块工作时钟；低有效复位。
     input wire [7 : 0] address, wdata,
     output wire        ready,
     output reg         done, error,
     output reg [7 : 0] rdata,
     inout wire         scl, sda);
    reg [2 : 0]    state;
    reg            read_req, write_req;
    reg [7 : 0]    saved_addr, saved_data;
    reg [31 : 0]   timer;
    wire           read_ack, write_ack, master_error;
    wire [7 : 0]   read_data;
    wire           scl_out, scl_oe, sda_out, sda_oe;
    wire           master_reset =  !rst_n || state == 4;                    // 超时恢复阶段复位底层 I2C 主机，释放未结束的总线事务。
    assign         scl          = scl_oe ? 1'bz : scl_out;                  // 输出使能关闭时为高阻，由总线上拉形成高电平。
    assign         sda          = sda_oe ? 1'bz : sda_out;
    assign         ready        = rst_n && state == 0;                      // 只有空闲状态可以锁存新的单字节读写请求。
    i2c_master_top master(.rst(master_reset),                               // I2C 单笔寄存器事务：组合设备地址、寄存器地址和数据，返回完成或无应答状态。
                          .clk(clk),
                          .clk_div_cnt(I2C_DIV[15 : 0]),
                          .scl_pad_i(scl),
                          .scl_pad_o(scl_out),
                          .scl_padoen_o(scl_oe),
                          .sda_pad_i(sda),
                          .sda_pad_o(sda_out),
                          .sda_padoen_o(sda_oe),
                          .i2c_addr_2byte(1'b0),
                          .i2c_read_req(read_req),
                          .i2c_read_req_ack(read_ack),
                          .i2c_write_req(write_req),
                          .i2c_write_req_ack(write_ack),
                          .i2c_slave_dev_addr(8'ha0),
                          .i2c_slave_reg_addr({8'd0, saved_addr}),
                          .i2c_write_data(saved_data),
                          .i2c_read_data(read_data),
                          .error(master_error),
                          .nack_state(),
                          .debug_bus());
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= 0;
            read_req   <= 0;
            write_req  <= 0;
            saved_addr <= 0;
            saved_data <= 0;
            timer      <= 0;
            done       <= 0;
            error      <= 0;
            rdata      <= 0;
        end else begin
            done <= 0;
            case (state)
                0 :
                    if (valid) begin                                        // 在请求接受时保存地址与数据，上层后续改变输入不会影响在途事务。
                        saved_addr <= address;
                        saved_data <= wdata;
                        read_req   <=  !write_byte;
                        write_req  <= write_byte;
                        timer      <= 0;
                        error      <= 0;
                        state      <= 1;
                    end
                1 : begin
                    if (read_ack || write_ack) begin
                        read_req  <= 0;
                        write_req <= 0;
                        rdata     <= read_data;
                        error     <= master_error;
                        done      <= 1;
                        state     <= 2;
                    end else if (timer == TIMEOUT_CYCLES - 1) begin         // 到达最长等待时间后发出错误完成，并进入底层主机复位恢复。
                        read_req  <= 0;
                        write_req <= 0;
                        error     <= 1;
                        done      <= 1;
                        state     <= 4;
                    end else
                        timer <= timer + 1'b1;
                end
                2 :
                    state <= 3;
                3 :
                    state <= 0;
                4 :
                    state <= 3;
                default :
                    state <= 4;
            endcase
        end
    end
endmodule
