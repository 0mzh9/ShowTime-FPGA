`timescale 1ns/1ps
 
 
 
module video_pll_config                                                     // 经 APB 顺序写入并核对 PLL 配置，释放复位后等待目标视频时钟锁定。
    #(parameter RESET_TICKS = 270, LOCK_TICKS = 64)
    (                                                                       // 通过 APB 写入并读回视频 PLL 的分频、占空比和相位。
     input wire          clk, rst_n, epoch, mode1080, locked,               // 本模块工作时钟；低有效复位；选择 1080P 输出画布。
     input wire          apb_ready,
     input wire [15 : 0] apb_rdata,
     output reg          pll_reset, ready,
     output reg [4 : 0]  apb_addr,
     output reg [15 : 0] apb_wdata,
     output reg          apb_sel, apb_en, apb_write,
     output reg          fault                                              // 锁存的故障标志。
    );
    localparam   WAIT = 0, WSET = 1, WACCESS = 2, RSET = 3, RACCESS = 4, RELEASE = 5, LOCK = 6, DONE = 7, ERROR = 8;
    reg [3 : 0]  state;
    reg          seen, target;
    reg [1 : 0]  word_index;
    reg [15 : 0] count;
    (* syn_preserve=1, async_reg="true" *) reg [1 : 0] lock_sync;
    function [4 : 0] addr                                                   // 把配置项序号转换成 PLL APB 寄存器地址。
        (input [1 : 0] i);
        case (i)
            0 :
                addr = 0;
            1 :
                addr = 1;
            2 :
                addr = 7;
            default :
                addr = 8;
        endcase
    endfunction
    function [15 : 0] value                                                 // 根据目标视频模式选择寄存器配置常量。
        (input [1 : 0] i,
         input         m);
        case (i)
            0, 2 :
                value = m ? 16'h0707 : 16'h0e0e;
            1 :
                value = 16'h0000;
            3 :
                value = m ? 16'h0505 : 16'h060a;
        endcase
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= WAIT;
            seen       <= 1;
            target     <= 0;
            word_index <= 0;
            count      <= 0;
            lock_sync  <= 0;
            pll_reset  <= 1;
            ready      <= 0;
            fault      <= 0;
            apb_addr   <= 0;
            apb_wdata  <= 0;
            apb_sel    <= 0;
            apb_en     <= 0;
            apb_write  <= 0;
        end else begin
            lock_sync <= {lock_sync[0], locked};
            if (epoch != seen) begin
                seen       <= epoch;
                target     <= mode1080;
                word_index <= 0;
                count      <= 0;
                state      <= WAIT;
                pll_reset  <= 1;
                ready      <= 0;
                fault      <= 0;
                apb_sel    <= 0;
                apb_en     <= 0;
                apb_write  <= 0;
            end else
                case (state)
                    WAIT :                                                  // 保持配置复位并等待重新配置条件。
                        if (count == RESET_TICKS - 1) begin
                            count <= 0;
                            state <= WSET;
                        end else
                            count <= count + 1'b1;
                    WSET : begin                                            // 建立 APB 写地址与数据。
                        apb_addr  <= addr(word_index);
                        apb_wdata <= value(word_index, target);
                        apb_sel   <= 1;
                        apb_en    <= 0;
                        apb_write <= 1;
                        state     <= WACCESS;
                        count     <= 0;
                    end
                    WACCESS : begin                                         // 保持写事务直到 APB 就绪。
                        apb_en <= 1;
                        if (apb_en && apb_ready) begin
                            apb_sel   <= 0;
                            apb_en    <= 0;
                            apb_write <= 0;
                            state     <= RSET;
                        end else if (count == 1023) begin
                            state <= ERROR;
                            fault <= 1;
                        end else
                            count <= count + 1'b1;
                    end
                    RSET : begin                                            // 建立同一寄存器的读回地址。
                        apb_sel   <= 1;
                        apb_en    <= 0;
                        apb_write <= 0;
                        state     <= RACCESS;
                        count     <= 0;
                    end
                    RACCESS : begin                                         // 核对读回值，再处理下一配置项。
                        apb_en <= 1;
                        if (apb_en && apb_ready) begin                      // 读回正确后才释放该配置项，防止接口完成但寄存器内容不符。
                            apb_sel <= 0;
                            apb_en  <= 0;
                            if (apb_rdata != value(word_index, target)) begin
                                state <= ERROR;
                                fault <= 1;
                            end else if (word_index == 3) begin
                                count <= 0;
                                state <= RELEASE;
                            end else begin
                                word_index <= word_index + 1'b1;
                                state      <= WSET;
                            end
                        end else if (count == 1023) begin
                            state <= ERROR;
                            fault <= 1;
                        end else
                            count <= count + 1'b1;
                    end
                    RELEASE :                                               // 释放 PLL 复位并进入锁定等待。
                        if (count == RESET_TICKS - 1) begin
                            pll_reset <= 0;
                            state     <= LOCK;
                            count     <= 0;
                        end else
                            count <= count + 1'b1;
                    LOCK :                                                  // 连续检查锁定条件，超时则报告错误。
                        if (!lock_sync[1])
                            count <= 0;
                        else if (count == LOCK_TICKS - 1) begin
                            ready <= 1;
                            state <= DONE;
                        end else
                            count <= count + 1'b1;
                    DONE :                                                  // 保持本次视频时钟配置成功状态。
                        if (!lock_sync[1]) begin
                            ready <= 0;
                            count <= 0;
                            state <= LOCK;
                        end
                    ERROR : begin                                           // 锁存配置异常，等待下一次重配请求。
                        ready     <= 0;
                        pll_reset <= 1;
                        apb_sel   <= 0;
                        apb_en    <= 0;
                        apb_write <= 0;
                    end
                endcase
        end
    end
endmodule
