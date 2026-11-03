`timescale 1ns/1ps
 
 
 
module calibration_cdc                                                      // 标定总线跨时钟传递：源端保持载荷，目标端识别请求翻转后整组锁存并返回确认。
    (input wire           sys_clk, core_clk, rst_n, request,                // 系统控制时钟；图像处理核心时钟；低有效复位。
     input wire [639 : 0] payload,
     output wire          ack,
     output reg [639 : 0] core_payload);
    (* async_reg="true" *) reg [2 : 0] request_sync, ack_sync;              // 请求及应答各用三级同步寄存器；宽载荷本身由握手期间稳定来保证采样。
    reg                                    core_ack;
    assign                                 ack = ack_sync[2];               // 接收端完成整组参数锁存后返回应答。
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            request_sync <= 0;
            core_ack     <= 0;
            core_payload <= 0;
        end                                                                 // 一次性更新参数总线，避免跨时钟读取到混合系数。
        else begin
            request_sync <= {request_sync[1 : 0], request};
            if (request_sync[2] != core_ack) begin                          // 请求翻转未确认时一次性锁存整组参数；随后回送同一翻转标识。
                core_payload <= payload;
                core_ack     <= request_sync[2];
            end
        end
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)
            ack_sync <= 0;
        else
            ack_sync <= {ack_sync[1 : 0], core_ack};
    end
endmodule
