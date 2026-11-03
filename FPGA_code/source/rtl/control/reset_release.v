`timescale 1ns/1ps
module reset_release                                                        // 复位异步拉低、三级寄存器同步释放，供各自时钟域独立使用。
    (input wire  clk, async_n,                                              // 本模块工作时钟。
     output wire reset_n);                                                  // 复位异步置位，在目标时钟域同步释放。
    (* async_reg="true" *) reg [2 : 0] sync;
    always @(posedge clk or negedge async_n)
        if (!async_n)
            sync <= 0;
        else
            sync <= {sync[1 : 0], 1'b1};
    assign reset_n = sync[2];
endmodule
