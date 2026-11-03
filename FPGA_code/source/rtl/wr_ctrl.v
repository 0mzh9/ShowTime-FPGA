`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Meyesemi
// Engineer: Nill
// 
// Create Date: 07/01/23 17:29:04
// Design Name: 
// Module Name: wr_ctrl
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1

module wr_ctrl                                                              // DDR 写控制：对齐地址与写数据请求，维护突发计数及写完成反馈。
    #(parameter CTRL_ADDR_WIDTH = 28,
      parameter MEM_DQ_WIDTH    = 16)
    (input clk,                                                             // 处理时钟。
     input rst_n,                                                           // 低有效复位。

     input                            wr_en,
     input [CTRL_ADDR_WIDTH - 1 : 0]  wr_addr,
     input [3 : 0]                    wr_id,
     input [3 : 0]                    wr_len,
     output                           wr_cmd_done,
     output                           wr_ready,
     input                            wr_data_en,
     input [MEM_DQ_WIDTH * 8 - 1 : 0] wr_data,
     output                           wr_bac,

     output reg [CTRL_ADDR_WIDTH - 1 : 0] axi_awaddr = 0,                   // DDR 写字地址。
     output reg [3 : 0] axi_awid  = 0,
     output reg [3 : 0] axi_awlen = 0,
     output [2 : 0]     axi_awsize,
     output [1 : 0]     axi_awburst,                                        // 仅支持 2'b01，即地址递增突发 INCR。
     input axi_awready,                                                     // DDR 接受写地址。
     output reg axi_awvalid = 0,                                            // 写地址请求有效。

     output [MEM_DQ_WIDTH * 8 - 1 : 0] axi_wdata,                           // 原生 DDR 写数据。
     output [MEM_DQ_WIDTH - 1 : 0] axi_wstrb,                               // 原生 DDR 字节使能。
     input  axi_wlast,
     output axi_wvalid,
     input  axi_wready,                                                     // 原生 DDR 请求提供写数据。
     input [3 : 0] axi_bid,                                                 // 主接口写响应。
     input [1 : 0] axi_bresp,                                               // 写响应，表示本次写事务的状态。
     input axi_bvalid,                                                      // 写响应有效，表示该通道当前提供有效写响应。
     output reg axi_bready = 1,                                             // 响应就绪，表示主机可以接受写响应。
     output reg [2 : 0] test_wr_state = 0);

    localparam DQ_NUM = MEM_DQ_WIDTH / 8;

    localparam E_IDLE = 3'd0;
    localparam E_WR   = 3'd1;
    localparam E_END  = 3'd2;

    assign axi_awburst = 2'b01;
    assign axi_awsize  = 3'b110;

    assign axi_wstrb = {MEM_DQ_WIDTH{1'b1}};

    //===========================================================================
    //   write ADDR channels
    //===========================================================================
    reg [3 : 0] cmd_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awaddr  <= 'b0;
            axi_awid    <= 4'b0;
            axi_awlen   <= 4'b0;
            axi_awvalid <= 1'b0;
        end else if (wr_en) begin
            axi_awid    <= wr_id;
            axi_awaddr  <= wr_addr;
            axi_awlen   <= wr_len;
            axi_awvalid <= 1'b1;
        end else if (axi_awvalid & axi_awready) begin                       // 地址只有在 valid 与 ready 同时成立时被 DDR 接受。
            axi_awvalid <= 1'b0;
            axi_awid    <= axi_awid;
            axi_awaddr  <= axi_awaddr;
            axi_awlen   <= axi_awlen;
        end else begin
            axi_awvalid <= axi_awvalid;
            axi_awid    <= axi_awid;
            axi_awaddr  <= axi_awaddr;
            axi_awlen   <= axi_awlen;
        end
    end

    //----------------------------
    //Write Response (B) Channel
    //----------------------------
    always @(posedge clk) begin
        if (rst_n == 0)
            axi_bready <= 1'b0;
        else
            axi_bready <= 1'b1;
    end

    wire [3 : 0] trans_len /* synthesis PAP_MARK_DEBUG="true" */;
    wire         burst_finish;

    assign trans_len = wr_len;

    always @(posedge clk) begin
        if (!rst_n)
            cmd_cnt <= 4'd0;
        else begin
            if (axi_awvalid & axi_awready)
                cmd_cnt <= cmd_cnt + 4'd1;
            else if (axi_wlast && axi_wvalid && axi_wready)
                cmd_cnt <= cmd_cnt - 4'd1;
            else
                cmd_cnt <= cmd_cnt;
        end
    end

    reg         write_en;
    reg [3 : 0] axi_data_cnt;
    always @(posedge clk) begin
        if (!rst_n)
            write_en <= 1'b0;
        else if (axi_awvalid & axi_awready & cmd_cnt == 4'd0)
            write_en <= 1'b1;

        else if (axi_wvalid && axi_data_cnt == trans_len && axi_wready)
            write_en <= 1'b0;
    end

    assign wr_ready = axi_wready;

    always @(posedge clk) begin
        if (!rst_n)
            axi_data_cnt <= 4'd0;
        else if (cmd_cnt > 4'd1 &&  ~write_en)
            axi_data_cnt <= 4'd0;
        else begin
            if (axi_wready & axi_wvalid) begin                              // 每个真正消费的写宽字推进一次数据计数。
                if (axi_data_cnt == trans_len)
                    axi_data_cnt <= 4'd0;
                else
                    axi_data_cnt <= axi_data_cnt + 1'b1;
            end else
                axi_data_cnt <= axi_data_cnt;
        end
    end

    reg    axi_wready_1d;
    assign burst_finish =  ~axi_wready_1d && axi_wready;

    always @(posedge clk) begin
        axi_wready_1d <= axi_wready;
    end

    assign wr_cmd_done = axi_wlast;
    assign axi_wdata   = wr_data;
    assign axi_wvalid  = axi_wready;
    assign wr_bac      = axi_wvalid && (~axi_wready && axi_wready_1d);
endmodule
