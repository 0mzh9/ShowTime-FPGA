`timescale 1ns/1ps
 
 
 
module video_mode_control                                                   // 视频会话状态机：依次完成停止排空、模式配置、启动及帧级 Gamma 确认。
    #(parameter GAMMA_ENABLE = 0, SETTLE_TICKS = 540000, CLEAR_TICKS = 2700)  // 是否编入 Gamma 查表通路。
    (                                                                       // 统筹停止、排空、复位、模式切换及首帧确认。
     input wire clk, rst_n, command_valid,                                  // 系统控制时钟（顶层为 27 MHz）；低有效复位；双字节命令有效。
     input wire display_gamma_seen, display_gamma_enable, display_gamma_epoch,
     output reg gamma_enable, gamma_epoch,                                  // 自适应 Gamma 开关；Gamma 状态代次。
     input wire [15 : 0] command,                                           // 双字节命令。
     output reg reply_valid,                                                // 应答有效。
     output reg [15 : 0] reply,                                             // 待发送的应答字。
     input wire reply_ready,                                                // 应答发送端就绪。
     input wire         ddr_ready, camera_ready, drained, frame_ready, video_configured, pipeline_fault, clock_ready,
     output reg         mode1080, pipe_enable, quiesce, video_hold, config_hold, clock_epoch,  // 选择 1080P 输出画布。
     output wire        running,
     output reg [3 : 0] state);
    localparam BOOT = 0, CONFIG_WAIT = 1, STOPPED = 2, STARTING = 3, RUNNING = 4, DRAIN = 5, CLEAR = 6, MODE_SETTLE = 7;
    reg [31 : 0] timer;
    reg          mode_reply, gamma_pending;
    assign       running = state == RUNNING;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gamma_enable  <= 0;
            gamma_epoch   <= 0;
            gamma_pending <= 0;
            state         <= BOOT;
            timer         <= 0;
            mode1080      <= 0;
            pipe_enable   <= 0;
            quiesce       <= 1;
            video_hold    <= 1;
            config_hold   <= 1;
            reply_valid   <= 0;
            reply         <= 0;
            mode_reply    <= 0;
            clock_epoch   <= 0;
        end else begin
            if (reply_valid && reply_ready)
                reply_valid <= 0;
            case (state)
                BOOT, MODE_SETTLE : begin
                    if (!clock_ready)
                        timer <= 0;
                    else if (timer == SETTLE_TICKS - 1) begin
                        timer       <= 0;
                        video_hold  <= 0;
                        config_hold <= 0;
                        state       <= CONFIG_WAIT;
                    end else
                        timer <= timer + 1'b1;
                end
                CONFIG_WAIT :                                               // 等待目标分辨率的 PLL 和外部视频芯片配置完成。
                    if (video_configured) begin
                        state <= STOPPED;
                        if (mode_reply) begin
                            reply       <= mode1080 ? 16'h2345 : 16'h1234;
                            reply_valid <= 1;
                            mode_reply  <= 0;
                        end
                    end
                DRAIN : begin                                               // 禁止新帧进入并等待在途图像和 DDR 事务排空。

                    if (timer < 16)
                        timer <= timer + 1'b1;
                    else if (drained &&  !pipeline_fault) begin
                        pipe_enable <= 0;
                        timer       <= 0;
                        state       <= CLEAR;
                    end
                end
                CLEAR : begin                                               // 清除旧会话流水状态，避免再次输出旧帧。
                    if (timer == CLEAR_TICKS - 1) begin
                        state       <= STOPPED;
                        reply       <= 16'h6868;
                        reply_valid <= 1;
                    end else
                        timer <= timer + 1'b1;
                end
                STARTING :                                                  // 等待新会话第一组原图和矫正结果准备就绪。
                    if (frame_ready &&  !pipeline_fault) begin              // 新帧对确实就绪且无流水故障后，才确认采集已经启动。
                        state       <= RUNNING;
                        reply       <= 16'h6688;
                        reply_valid <= 1;
                    end
                default : begin
                end
            endcase
            if (GAMMA_ENABLE && gamma_pending && state == RUNNING &&  !reply_valid &&  !pipeline_fault &&  // 运行中的 Gamma 应答必须匹配已输出帧的开关和请求代际。
                !(command_valid && command == 16'h6868) && display_gamma_seen && display_gamma_enable == gamma_enable &&
                display_gamma_epoch == gamma_epoch) begin
                reply         <= gamma_enable ? 16'hAABB : 16'hABCD;
                reply_valid   <= 1;
                gamma_pending <= 0;                                         // 请求开启 FPGA 自适应 Gamma。
            end
            if (command_valid &&  !reply_valid) begin
                if (command == 16'h6868 && (state != DRAIN && state != CLEAR)) begin
                    quiesce       <= 1;
                    state         <= DRAIN;
                    timer         <= 0;
                    mode_reply    <= 0;
                    gamma_pending <= 0;
                end else if (GAMMA_ENABLE &&  !gamma_pending && (state == STOPPED || state == RUNNING) &&  // Gamma 更新使用独立待确认标志，避免尚未生效时接受第二次切换。
                             (command == 16'hAABB || command == 16'hABCD)) begin  // 请求关闭 FPGA 自适应 Gamma。
                    gamma_enable <= command == 16'hAABB;
                    gamma_epoch  <=  !gamma_epoch;
                    if (state == STOPPED) begin
                        reply       <= command;
                        reply_valid <= 1;
                    end else
                        gamma_pending <= 1;
                end else if (state == STOPPED && (command == 16'h1234 || command == 16'h2345)) begin  // 分辨率只在停止状态切换，先完成时钟和视频器件重配置。
                    mode1080    <= command == 16'h2345;
                    video_hold  <= 1;
                    config_hold <= 1;
                    clock_epoch <=  !clock_epoch;
                    timer       <= 0;
                    state       <= MODE_SETTLE;
                    mode_reply  <= 1;
                end else if (command == 16'h6688 && state == STOPPED && ddr_ready && camera_ready && video_configured)
                begin
                    pipe_enable <= 1;
                    quiesce     <= 0;
                    state       <= STARTING;
                end else if (command == 16'h6688 && state == RUNNING) begin
                    reply       <= 16'h6688;
                    reply_valid <= 1;
                end
            end
        end
    end
endmodule
