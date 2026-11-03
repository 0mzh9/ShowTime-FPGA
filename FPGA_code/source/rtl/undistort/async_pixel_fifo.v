`timescale 1ns/1ps
 
 
module async_pixel_fifo                                                     // 双时钟像素 FIFO：本地二进制指针寻址，格雷码指针跨域同步以判断满空。
    #(parameter WIDTH = 18, ADDR_BITS = 12)                                 // 源图每行像素数；FIFO 二进制地址位数。
    (                                                                       // 格雷码指针双时钟 FIFO，隔离写入与读取时钟域。
     input wire                  rst_n, wr_clk, rd_clk,                     // 低有效复位；写入侧时钟；读取侧时钟。
     input wire                  wr_valid,
     output wire                 wr_ready,
     input wire [WIDTH - 1 : 0]  wr_data,
     output wire [ADDR_BITS : 0] wr_used,
     output reg                  rd_valid,
     input wire                  rd_ready,
     output reg [WIDTH - 1 : 0]  rd_data);
    reg [WIDTH - 1 : 0] memory[0 : (1 << ADDR_BITS) - 1];
    reg [ADDR_BITS : 0] wbin, wgray, rbin, rgray, rg1, rg2, wg1, wg2;
    reg [1 : 0]         wr_reset, rd_reset;
    always @(posedge wr_clk or negedge rst_n)
        if (!rst_n)
            wr_reset <= 0;
        else
            wr_reset <= {wr_reset[0], 1'b1};
    always @(posedge rd_clk or negedge rst_n)
        if (!rst_n)
            rd_reset <= 0;
        else
            rd_reset <= {rd_reset[0], 1'b1};
    function [ADDR_BITS : 0] gray_to_bin;                                   // 接收端将已同步的读指针格雷码还原为二进制，只用于本地占用量统计。
        input [ADDR_BITS : 0] value;
        integer               k;
        begin
            gray_to_bin[ADDR_BITS] = value[ADDR_BITS];
            for (k = ADDR_BITS - 1; k >= 0; k = k - 1)
                gray_to_bin[k] = gray_to_bin[k + 1] ^ value[k];
        end
    endfunction
    wire                 full     = wgray == {~rg2[ADDR_BITS : ADDR_BITS - 1], rg2[ADDR_BITS - 2 : 0]};
    assign               wr_ready = wr_reset[1] &&  !full;                  // 写域复位同步释放后且 FIFO 未满才接受像素。
    assign               wr_used  = wbin - gray_to_bin(rg2);
    wire [ADDR_BITS : 0] wnext = wbin + 1'b1, rnext = rbin + 1'b1;
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wbin  <= 0;
            wgray <= 0;
            rg1   <= 0;
            rg2   <= 0;
        end else if (!wr_reset[1]) begin
            wbin  <= 0;
            wgray <= 0;
            rg1   <= 0;
            rg2   <= 0;
        end else begin
            rg1 <= rgray;
            rg2 <= rg1;
            if (wr_valid && wr_ready) begin                                 // 只有有效且就绪时才更新存储与写指针；相机端丢帧由上层另行处理。
                memory[wbin[ADDR_BITS - 1 : 0]] <= wr_data;
                wbin                            <= wnext;
                wgray                           <= (wnext >> 1) ^ wnext;
            end
        end
    end
    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rbin     <= 0;
            rgray    <= 0;
            wg1      <= 0;
            wg2      <= 0;
            rd_valid <= 0;
            rd_data  <= 0;
        end else if (!rd_reset[1]) begin
            rbin     <= 0;
            rgray    <= 0;
            wg1      <= 0;
            wg2      <= 0;
            rd_valid <= 0;
            rd_data  <= 0;
        end else begin
            wg1 <= wgray;
            wg2 <= wg1;
            if (!rd_valid || rd_ready) begin                                // 输出寄存器为空或已被消费时才预取下一项，阻塞期间输出内容保持。
                if (rgray != wg2) begin
                    rd_data  <= memory[rbin[ADDR_BITS - 1 : 0]];
                    rd_valid <= 1;
                    rbin     <= rnext;
                    rgray    <= (rnext >> 1) ^ rnext;
                end else
                    rd_valid <= 0;
            end
        end
    end
endmodule
