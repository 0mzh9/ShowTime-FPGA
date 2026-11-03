`timescale 1ns/1ps
 
 
 
module uart_diagnostics                                                     // 诊断快照读取与控制应答复用：控制应答优先，诊断按锁存快照分段返回。
    (                                                                       // 只读诊断入口，不改变视频控制状态。
     input wire clk, rst_n, command_valid,                                  // 系统控制时钟（顶层为 27 MHz）；低有效复位；双字节命令有效。
     input wire [15 : 0]  command, live_status, control_reply,
     input wire [95 : 0]  camera_status,
     input wire           control_valid, uart_ready,
     output wire          control_ready, uart_valid,
     output wire [15 : 0] uart_reply);
    (* async_reg="true" *) reg [95 : 0] camera_meta, camera_sync;
    reg [111 : 0]                           snapshot;
    reg                                     pending;
    reg [15 : 0]                            response;
    assign                                  control_ready = uart_ready;
    assign                                  uart_valid    = control_valid || pending;  // 控制应答始终优先；诊断请求保留到发送器可以接收。
    assign                                  uart_reply    = control_valid ? control_reply : response;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            camera_meta <= 0;
            camera_sync <= 0;
            snapshot    <= 0;
            pending     <= 0;
            response    <= 0;
        end else begin

            camera_meta <= camera_status;
            camera_sync <= camera_meta;
            if (pending && uart_ready &&  !control_valid)
                pending <= 0;
            if (command_valid && command[15 : 8] == 8'h5a && command[7 : 0] <= 7 &&  !pending) begin  // 5A00 锁存同一时刻快照；后续 5A01 至 5A07 分段读取该快照。
                pending <= 1;
                if (command[7 : 0] == 0) begin
                    snapshot <= {camera_sync, live_status};
                    response <= 16'h9d09;
                end else
                    response <= snapshot[(command[2 : 0] - 1'b1) * 16 +: 16];
            end
        end
    end
endmodule
