`timescale 1ns/1ps
 
 
module perf_event_mailbox                                                   // 事件邮箱跨域：载荷保持到对端确认，请求和确认均用翻转标识传递。
    #(parameter WIDTH = 1)                                                  // 源图每行像素数。
    (                                                                       // 跨时钟事件邮箱，载荷保持到接收应答返回。
     input wire                 rst_n, src_clk, src_event,                  // 低有效复位；源时钟域。
     input wire [WIDTH - 1 : 0] src_data,
     output reg                 overflow,
     input wire                 dst_clk,                                    // 目标时钟域。
     output reg                 dst_event,
     output reg [WIDTH - 1 : 0] dst_data);
    reg                                    request, acknowledge;
    reg [WIDTH - 1 : 0]                    held;
    (* async_reg="true" *) reg [1 : 0] ack_sync, req_sync;
    always @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            request  <= 0;
            held     <= 0;
            ack_sync <= 0;
            overflow <= 0;
        end else begin
            ack_sync <= {ack_sync[0], acknowledge};
            if (src_event) begin
                if (request == ack_sync[1]) begin                           // 上一个事件已经确认后才发送新事件，源端载荷保持到应答返回。
                    held    <= src_data;
                    request <=  !request;
                end else
                    overflow <= 1;
            end
        end
    end
    always @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_sync    <= 0;
            acknowledge <= 0;
            dst_event   <= 0;
            dst_data    <= 0;
        end else begin
            req_sync  <= {req_sync[0], request};
            dst_event <= 0;
            if (req_sync[1] != acknowledge) begin                           // 目标域检测翻转请求，整组取走稳定载荷后更新确认标识。
                dst_data    <= held;
                dst_event   <= 1;
                acknowledge <= req_sync[1];
            end
        end
    end
endmodule
