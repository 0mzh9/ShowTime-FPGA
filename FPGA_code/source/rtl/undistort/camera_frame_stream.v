`timescale 1ns/1ps
module camera_frame_stream                                                  // 为相机有效像素附加帧首和帧尾标记；无反压能力的输入发生拥塞时报告丢帧。
    #(parameter WIDTH = 1280, HEIGHT = 720)                                 // 源图每行像素数；源图有效行数。
    (                                                                       // 为摄像头像素附加帧首、帧尾标记并检测溢出。
     input wire          clk, rst_n, vsync, de,                             // 本模块工作时钟；低有效复位。
     input wire [15 : 0] pixel,                                             // RGB565 像素。
     output wire          valid,
     input wire           ready,
     output wire [17 : 0] data,
     output reg           overflow);
    localparam   N = WIDTH * HEIGHT;
    reg          vs_d, armed;
    reg [31 : 0] count;
    assign       valid = armed && de && count < N && rst_n;                 // 每帧只输出规定数量的有效像素，未等待到新帧边界时不接收半帧。
    assign       data  = {count == 0, count == N - 1, pixel};               // 高两位分别标记本帧首像素和尾像素，低 16 位保持 RGB565 内容。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d     <= 0;
            armed    <= 0;
            count    <= 0;
            overflow <= 0;
        end else begin
            vs_d <= vsync;
            if (vsync &&  !vs_d) begin
                count <= 0;
                armed <= 1;
            end else if (valid) begin
                if (!ready) begin                                           // 相机 DVP 不能暂停；拥塞时撤销本帧资格并锁存溢出，等待下一完整帧。
                    overflow <= 1;
                    armed    <= 0;
                end else begin
                    count <= count + 1'b1;
                    if (count == N - 1)
                        armed <= 0;
                end
            end
        end
    end
endmodule
