/////////////////////////////////////////////////////////////////////
////                                                             ////
////  WISHBONE rev.B2 compliant I2C Master byte-controller       ////
////                                                             ////
////                                                             ////
////  Author: Richard Herveille                                  ////
////          richard@asics.ws                                   ////
////          www.asics.ws                                       ////
////                                                             ////
////  Downloaded from: http://www.opencores.org/projects/i2c/    ////
////                                                             ////
/////////////////////////////////////////////////////////////////////
////                                                             ////
//// Copyright (C) 2001 Richard Herveille                        ////
////                    richard@asics.ws                         ////
////                                                             ////
//// This source file may be used and distributed without        ////
//// restriction provided that this copyright statement is not   ////
//// removed from the file and that any derivative work contains ////
//// the original copyright notice and the associated disclaimer.////
////                                                             ////
////     THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY     ////
//// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   ////
//// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS   ////
//// FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE AUTHOR      ////
//// OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,         ////
//// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES    ////
//// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE   ////
//// GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR        ////
//// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF  ////
//// LIABILITY, WHETHER IN  CONTRACT, STRICT LIABILITY, OR TORT  ////
//// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT  ////
//// OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE         ////
//// POSSIBILITY OF SUCH DAMAGE.                                 ////
////                                                             ////
/////////////////////////////////////////////////////////////////////

//  CVS Log
//
//  $Id: i2c_master_byte_ctrl.v,v 1.8 2009-01-19 20:29:26 rherveille Exp $
//
//  $Date: 2009-01-19 20:29:26 $
//  $Revision: 1.8 $
//  $Author: rherveille $
//  $Locker:  $
//  $State: Exp $
//
// Change History:
//               $Log: not supported by cvs2svn $
//               Revision 1.7  2004/02/18 11:40:46  rherveille
//               Fixed a potential bug in the statemachine. During a 'stop' 2 cmd_ack signals were generated. Possibly canceling a new start command.
//
//               Revision 1.6  2003/08/09 07:01:33  rherveille
//               Fixed a bug in the Arbitration Lost generation caused by delay on the (external) sda line.
//               Fixed a potential bug in the byte controller's host-acknowledge generation.
//
//               Revision 1.5  2002/12/26 15:02:32  rherveille
//               Core is now a Multimaster I2C controller
//
//               Revision 1.4  2002/11/30 22:24:40  rherveille
//               Cleaned up code
//
//               Revision 1.3  2001/11/05 11:59:25  rherveille
//               Fixed wb_ack_o generation bug.
//               Fixed bug in the byte_controller statemachine.
//               Added headers.
//

// synopsys translate_off
`timescale 1ns / 1ps
// synopsys translate_on

/////////////////////////////////////////////////////////////////////
////                                                             ////
////  WISHBONE rev.B2 compliant I2C Master controller defines    ////
////                                                             ////
////                                                             ////
////  Author: Richard Herveille                                  ////
////          richard@asics.ws                                   ////
////          www.asics.ws                                       ////
////                                                             ////
////  Downloaded from: http://www.opencores.org/projects/i2c/    ////
////                                                             ////
/////////////////////////////////////////////////////////////////////
////                                                             ////
//// Copyright (C) 2001 Richard Herveille                        ////
////                    richard@asics.ws                         ////
////                                                             ////
//// This source file may be used and distributed without        ////
//// restriction provided that this copyright statement is not   ////
//// removed from the file and that any derivative work contains ////
//// the original copyright notice and the associated disclaimer.////
////                                                             ////
////     THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY     ////
//// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   ////
//// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS   ////
//// FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE AUTHOR      ////
//// OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,         ////
//// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES    ////
//// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE   ////
//// GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR        ////
//// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF  ////
//// LIABILITY, WHETHER IN  CONTRACT, STRICT LIABILITY, OR TORT  ////
//// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT  ////
//// OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE         ////
//// POSSIBILITY OF SUCH DAMAGE.                                 ////
////                                                             ////
/////////////////////////////////////////////////////////////////////

//  CVS Log
//
//  $Id: i2c_master_defines.v,v 1.3 2001-11-05 11:59:25 rherveille Exp $
//
//  $Date: 2001-11-05 11:59:25 $
//  $Revision: 1.3 $
//  $Author: rherveille $
//  $Locker:  $
//  $State: Exp $
//
// Change History:
//               $Log: not supported by cvs2svn $


// I2C registers wishbone addresses

// bitcontroller states
`define I2C_CMD_NOP   4'b0000
`define I2C_CMD_START 4'b0001
`define I2C_CMD_STOP  4'b0010
`define I2C_CMD_WRITE 4'b0100
`define I2C_CMD_READ  4'b1000


module i2c_master_byte_ctrl                                                 // I2C 字节控制器：组织八位移位和第九位应答，底层位操作完成后再推进。
    (clk, rst, nReset, ena, clk_cnt, start, stop, read, write, ack_in, din, cmd_ack, ack_out, dout, i2c_busy, i2c_al,
     scl_i, scl_o, scl_oen, sda_i, sda_o, sda_oen, debug_state);

    //
    // inputs & outputs
    //
    input clk;                                                              // 主时钟。
    input rst;                                                              // 同步全局复位，高电平有效。
    input nReset;                                                           // 异步复位，低电平有效。
    input ena;                                                              // 内核使能信号。

    input [15 : 0] clk_cnt;                                                 // SCL 频率的 4 倍。

    // control inputs
    input         start;                                                    // 启动请求。
    input         stop;                                                     // 需要在本次字节之后产生停止条件。
    input         read;                                                     // 从总线读取一个字节。
    input         write;                                                    // 向总线发送一个字节。
    input         ack_in;                                                   // 读字节后发送的应答位：零为 ACK，一为 NACK。
    input [7 : 0] din;                                                      // 准备发送的八位数据。

    // status outputs
    output reg cmd_ack;                                                     // 完整字节操作及所需应答处理结束后返回完成。
    //reg cmd_ack;
    output reg ack_out;                                                     // 写字节后采集的从机应答位。
    //reg ack_out;
    output         i2c_busy;
    output         i2c_al;
    output [7 : 0] dout;

    // I2C signals
    input           scl_i;
    output          scl_o;
    output          scl_oen;
    input           sda_i;
    output          sda_o;
    output          sda_oen;
    output [31 : 0] debug_state;
    wire [21 : 0]   bit_debug;
    assign          debug_state = {core_cmd, cnt_done, bit_debug, c_state};

    // Variable declarations

    // statemachine
    parameter [4 : 0] ST_IDLE  = 5'b0_0000;
    parameter [4 : 0] ST_START = 5'b0_0001;
    parameter [4 : 0] ST_READ  = 5'b0_0010;
    parameter [4 : 0] ST_WRITE = 5'b0_0100;
    parameter [4 : 0] ST_ACK   = 5'b0_1000;
    parameter [4 : 0] ST_STOP  = 5'b1_0000;

    // signals for bit_controller
    reg [3 : 0] core_cmd;
    reg         core_txd;
    wire        core_ack, core_rxd;

    // signals for shift register
    reg [7 : 0] sr;                                                         // 8 位移位寄存器。
    reg         shift, ld;

    // signals for state machine
    wire        go;
    reg [2 : 0] dcnt;
    wire        cnt_done;

    // Module body

    // hookup bit_controller
    i2c_master_bit_ctrl bit_controller(.clk(clk),                           // I2C 位控制器：产生起始、停止、读写位时序，并处理总线同步与仲裁。
                                       .rst(rst),
                                       .nReset(nReset),
                                       .ena(ena),
                                       .clk_cnt(clk_cnt),
                                       .cmd(core_cmd),
                                       .cmd_ack(core_ack),
                                       .busy(i2c_busy),
                                       .al(i2c_al),
                                       .din(core_txd),
                                       .dout(core_rxd),
                                       .scl_i(scl_i),
                                       .scl_o(scl_o),
                                       .scl_oen(scl_oen),
                                       .sda_i(sda_i),
                                       .sda_o(sda_o),
                                       .sda_oen(sda_oen),
                                       .debug_state(bit_debug));

    // generate go-signal
    assign go = (read | write | stop) &  ~cmd_ack;                          // 原参考注记：cmd_ack 为低电平有效；实际极性以逻辑实现为准。

    // generate shift register
    always @(posedge clk or negedge nReset) begin
        if (!nReset)
            sr <= #1 8'h0;                                                  // 井号延迟仅用于 ModelSim 仿真，分析与综合时不使用。
        else if (rst == 1)
            sr <= #1 8'h0;
        else if (ld)                                                        // 装载数据。
            sr <= #1 din;                                                   // din 为输入数据。
        else if (shift)
            sr <= #1 {sr[6 : 0], core_rxd};
    end

    // assign dout output to shift-register
    assign dout = sr;                                                       // 读出的字节就是八次位采样后形成的移位寄存器内容。

    // generate counter
    always @(posedge clk or negedge nReset) begin
        if (!nReset)
            dcnt <= #1 3'h0;
        else if (rst)
            dcnt <= #1 3'h0;
        else if (ld)                                                        // 装入七后再执行逐位递减，共覆盖一个字节的八个位。
            dcnt <= #1 3'h7;
        else if (shift)
            dcnt <= #1 dcnt - 3'h1;
    end

    assign cnt_done =  ~( |dcnt);                                           // 单目运算符 | 为归约或，对操作数全部位求或并输出一位结果。

    // state machine
    reg [4 : 0] c_state; // synopsys enum_state

    always @(posedge clk or negedge nReset)
        if (!nReset) begin
            core_cmd <= #1 `I2C_CMD_NOP;
            core_txd <= #1 1'b0;
            shift    <= #1 1'b0;
            ld       <= #1 1'b0;
            cmd_ack  <= #1 1'b0;
            c_state  <= #1 ST_IDLE;
            ack_out  <= #1 1'b0;
        end else if (rst | i2c_al) begin                                    // 复位或仲裁丢失时取消当前字节操作，回到空闲等待。
            core_cmd <= #1 `I2C_CMD_NOP;
            core_txd <= #1 1'b0;
            shift    <= #1 1'b0;
            ld       <= #1 1'b0;
            cmd_ack  <= #1 1'b0;
            c_state  <= #1 ST_IDLE;
            ack_out  <= #1 1'b0;
        end else begin
            // initially reset all signals
            core_txd <= #1 sr[7];
            shift    <= #1 1'b0;
            ld       <= #1 1'b0;
            cmd_ack  <= #1 1'b0;

            case (c_state) // synopsys full_case parallel_case
                ST_IDLE :
                    if (go) begin
                        if (start) begin
                            c_state  <= #1 ST_START;
                            core_cmd <= #1 `I2C_CMD_START;
                        end else if (read) begin
                            c_state  <= #1 ST_READ;
                            core_cmd <= #1 `I2C_CMD_READ;
                        end else if (write) begin
                            c_state  <= #1 ST_WRITE;
                            core_cmd <= #1 `I2C_CMD_WRITE;
                        end else                                            // 停止条件。
                        begin
                            c_state  <= #1 ST_STOP;
                            core_cmd <= #1 `I2C_CMD_STOP;
                        end
                        ld <= #1 1'b1;
                    end

                ST_START :
                    if (core_ack) begin
                        if (read) begin
                            c_state  <= #1 ST_READ;
                            core_cmd <= #1 `I2C_CMD_READ;
                        end else begin
                            c_state  <= #1 ST_WRITE;
                            core_cmd <= #1 `I2C_CMD_WRITE;
                        end

                        ld <= #1 1'b1;
                    end

                ST_WRITE :
                    if (core_ack)
                        if (cnt_done) begin
                            c_state  <= #1 ST_ACK;
                            core_cmd <= #1 `I2C_CMD_READ;
                        end else begin
                            c_state  <= #1 ST_WRITE;                        // 保持当前状态。
                            core_cmd <= #1 `I2C_CMD_WRITE;                  // 写入下一位。
                            shift    <= #1 1'b1;
                        end

                ST_READ :
                    if (core_ack) begin
                        if (cnt_done) begin
                            c_state  <= #1 ST_ACK;
                            core_cmd <= #1 `I2C_CMD_WRITE;
                        end else begin
                            c_state  <= #1 ST_READ;                         // 保持当前状态。
                            core_cmd <= #1 `I2C_CMD_READ;                   // 读取下一位。
                        end

                        shift    <= #1 1'b1;
                        core_txd <= #1 ack_in;
                    end

                ST_ACK :
                    if (core_ack) begin
                        if (stop) begin
                            c_state  <= #1 ST_STOP;
                            core_cmd <= #1 `I2C_CMD_STOP;
                        end else begin
                            c_state  <= #1 ST_IDLE;
                            core_cmd <= #1 `I2C_CMD_NOP;

                            //generate command acknowledge signal
                            cmd_ack <= #1 1'b1;
                        end

                        //assign ack_out output to bit_controller(contains last received bit)
                        ack_out <= #1 core_rxd;

                        core_txd <= #1 1'b1;
                    end else
                        core_txd <= #1 ack_in;

                ST_STOP :
                    if (core_ack) begin
                        c_state  <= #1 ST_IDLE;
                        core_cmd <= #1 `I2C_CMD_NOP;

                        // generate command acknowledge signal
                        cmd_ack <= #1 1'b1;
                    end
            endcase
        end
endmodule
