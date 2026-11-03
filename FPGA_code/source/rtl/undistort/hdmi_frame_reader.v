`timescale 1ns/1ps
 
 
 
module hdmi_frame_reader                                                    // 锁定原图与矫正结果对，跨域预取像素并逐帧交替输出，嵌入类型和状态信息。
    #(parameter PAN_ENABLE = 0, TELEMETRY_ENABLE = 0, DYNAMIC_MODE = 0, WIDTH = 1920, HEIGHT = 1080, RAW_WIDTH = 1280,  // 源图每行像素数；源图有效行数；是否编入虚拟转向通路；是否根据运行时模式选择输出尺寸。
                RAW_HEIGHT = 720, A = 28)
    (input wire          clk, rst_n, pix_clk, vsync, de, mode1080, mode1080_pixel,  // 本模块工作时钟；低有效复位；视频像素时钟；选择 1080P 输出画布。
     output reg [15 : 0] pixel,                                             // RGB565 像素。
     output wire             pixel_de, corrected_view,
     output wire             acquire_valid,                                 // 读取端申请取得完整结果帧。
     input wire              acquire_ready, acquire_slot,                   // 完整结果及其引用可以分配；取得的结果槽号。
     input wire [61 : 0]     acquire_meta,                                  // 与结果绑定的运行状态信息。
     input wire [33 : 0]     acquire_pan,                                   // 与结果绑定的转向状态。
     output reg              display_pan_seen,                              // 已检测到目标矫正帧开始 HDMI 输出。
     output reg [64 : 0]     display_pan,                                   // 目标输出帧的转向状态与帧号。
     output reg              display_gamma_seen, display_gamma_enable, display_gamma_epoch,
     input wire [31 : 0]     acquire_base, acquire_raw_base, acquire_id,    // 取得的结果帧基址；该结果对应的原帧基址。
     output wire             release_valid,                                 // 请求释放已有帧引用。
     input wire              release_ready,                                 // 该帧引用可以释放。
     output reg              release_slot,
     output reg [31 : 0]     release_id,
     output wire [A - 1 : 0] araddr,
     output wire [3 : 0]     arlen, arid,
     output wire             arap, arvalid,
     input wire              arready,
     input wire [255 : 0]    rdata,
     input wire [3 : 0]      rid,
     input wire              rvalid, rlast,
     output wire             fault,                                         // 锁存的故障标志。
     output reg underflow);
    localparam    RELEASE = 0, ACQUIRE = 1, COMMAND = 2, WAIT_DATA = 3, PUSH = 4, HOLD = 5, PRIME = 6, REWIND = 7;
    wire [10 : 0] active_width  = (DYNAMIC_MODE &&  !mode1080) ? 11'd1280 : WIDTH;
    wire [10 : 0] active_height = (DYNAMIC_MODE &&  !mode1080) ? 11'd720 : HEIGHT;
    wire [10 : 0] X_PAD         = (DYNAMIC_MODE &&  !mode1080_pixel)
                                      ? 0
                                      : (WIDTH - RAW_WIDTH) / 2;            // 1080P 原图画布左右各留 320 像素，720P 不填边。
    wire [10 : 0] Y_PAD         = (DYNAMIC_MODE &&  !mode1080_pixel)
                                      ? 0
                                      : (HEIGHT - RAW_HEIGHT) / 2;          // 1080P 原图画布上下各留 180 行。
    reg [2 : 0]   state, vs_pipe;
    reg [2 : 0]   pix_reset_sync;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n)
            pix_reset_sync <= 0;
        else
            pix_reset_sync <= {pix_reset_sync[1 : 0], 1'b1};
    reg          owned, restart, view_corrected, retain_pair;
    reg [31 : 0] base, raw_base;

    reg [119 : 0]                          descriptor;
    reg [65 : 0]                           pan_descriptor, pixel_pan;
    reg                                    descriptor_toggle;
    (* async_reg="true" *) reg [2 : 0] descriptor_sync;
    reg [119 : 0]                          pixel_descriptor;
    // CRC-8/0x07、初值为零，与原逐位循环完全等价。
    // 预先展开线性变换，用平衡异或归约替代 112 次串行反馈组合链。
    function [7 : 0] crc8 (input [111 : 0] value);
        begin
            crc8[0] = ^(value & 112'hcfd275f12c3d9177298cd0ad51c1);
            crc8[1] = ^(value & 112'h50769e137446b3997a9571f7f243);
            crc8[2] = ^(value & 112'h6f3f49d7c4b0f645dca63342b547);
            crc8[3] = ^(value & 112'hde7e93af8961ec8bb94c66856a8e);
            crc8[4] = ^(value & 112'hbcfd275f12c3d9177298cd0ad51c);
            crc8[5] = ^(value & 112'h79fa4ebe2587b22ee5319a15aa38);
            crc8[6] = ^(value & 112'hf3f49d7c4b0f645dca63342b5470);
            crc8[7] = ^(value & 112'he7e93af8961ec8bb94c66856a8e0);
        end
    endfunction
    wire [111 : 0] descriptor_body = {
                       16'hD95A, acquire_meta[59 : 56], acquire_meta[61], mode1080, 1'b0, acquire_meta[60],
                       acquire_id, acquire_meta[31 : 0], acquire_meta[55 : 32]};
    reg [10 : 0]   row, position;
    reg [7 : 0]    returned;
    reg [255 : 0]  staging[0 : WIDTH / 16 - 1];
    reg [255 : 0]  staging_word;
    wire [10 : 0]  stored_width  = view_corrected ? active_width : RAW_WIDTH;
    wire [10 : 0]  stored_height = view_corrected ? active_height : RAW_HEIGHT;
    wire [15 : 0]  line_beats    = stored_width >> 4;
    wire           line_ready, line_data_valid, line_last, line_done, busy;
    wire [255 : 0] line_data;
    wire [11 : 0]  fifo_used;
    wire           fifo_ready, fifo_valid;

    reg          pair_valid;
    reg [31 : 0] pair_data;
    wire         pair_ready =  !pair_valid || fifo_ready;
    wire         pair_push  = state == PUSH &&  !restart &&  !vs_pipe[1] &&  !fault;
    always @(posedge clk or negedge rst_n) begin                            // 核心域维护像素对暂存；场同步、重启或故障时清除旧帧预取。
        if (!rst_n) begin
            pair_valid <= 0;
            pair_data  <= 0;
        end else if (restart || vs_pipe[1] || fault)
            pair_valid <= 0;
        else if (pair_ready) begin
            pair_valid <= pair_push;
            if (pair_push)
                pair_data <= staging_word[position[3 : 0] * 16 +: 32];
        end
    end
    wire [31 : 0] fifo_data;
    reg           de1, de2, frame_bad;
    reg [15 : 0]  pixel1;
    reg           draw_enable, draw_payload, draw_marker, draw_marker_bit;
    reg [1 : 0]   owned_sync, corrected_sync;
    reg [10 : 0]  output_x, output_y;
    wire          payload =
                      corrected_sync[1] ||                                  // 矫正图使用完整输出画布，原图仅中央区域读取 DDR。
                      (output_x >= X_PAD && output_x < X_PAD + RAW_WIDTH && output_y >= Y_PAD && output_y < Y_PAD + RAW_HEIGHT);
    wire [15 : 0] source_pixel = output_x[0] ? fifo_data[31 : 16] : fifo_data[15 : 0];
    wire [15 : 0] marker_code  = corrected_sync[1] ? 16'hA5C3 : 16'hA53C;   // A53C 表示原图，A5C3 表示矫正图。

    wire metadata_region = TELEMETRY_ENABLE && output_x >= 128 && output_x < 1088 && output_y < 4 &&
                           owned_sync[1];                                   // 顶部四行承载帧号、Gamma 状态与处理周期数。

    wire [7 : 0] metadata_cell  = output_x[10 : 3] - 8'd16;
    wire         metadata_bit   = metadata_region ? pixel_descriptor[7'd119 - metadata_cell[6 : 0]] : 1'b0;
    wire         marker_region  = (TELEMETRY_ENABLE ? output_x < 128 :      // 类型标记与遥测区域保持协议规定的位置。
                                       output_x[10 : 7] == ((DYNAMIC_MODE &&  !mode1080_pixel) ? 4'd0 : 4'd7)) &&
                                  output_y < (TELEMETRY_ENABLE ? 4 : 16) && owned_sync[1];
    assign       corrected_view = corrected_sync[1];                        // 输出类型已同步到像素时钟域，供状态信息及原图/矫正图选择使用。
    assign       pixel_de       = de2;
    assign       acquire_valid  = state == ACQUIRE &&  !owned && vs_pipe[1] &&  !fault;  // 仅在视频帧边界取得完整帧对，避免活动图像中途切换来源。
    assign       release_valid  = state == RELEASE && owned &&  !busy &&  !fault;  // 释放前要求行读取结束，防止 DDR 返回仍引用已回收的槽。
    wire         command_valid =
                     state == COMMAND &&  !restart &&  !vs_pipe[1] && fifo_used <= 2048 - (stored_width >> 1) &&  !fault;
    ddr_line_reader #(.ADDR_WIDTH(A),                                       // 源图行读取：把一行请求拆成符合突发长度及边界要求的 DDR 事务，并核对返回标签。
                      .MAX_LINE_BEATS(WIDTH / 16),
                      .READ_ID(11))
        reader(.clk(clk),
               .rst_n(rst_n),
               .ddr_init_done(rst_n),
               .command_valid(command_valid),
               .command_ready(line_ready),
               .command_word_addr(view_corrected ? base + ((DYNAMIC_MODE &&  !mode1080) ? row * 640 : row * (WIDTH / 2))
                                                 : raw_base + row * (RAW_WIDTH / 2)),
               .command_beats(line_beats),
               .return_valid(line_data_valid),
               .return_data(line_data),
               .return_last(line_last),
               .line_done(line_done),
               .busy(busy),
               .fault(fault),
               .fault_code(),
               .axi_araddr(araddr),
               .axi_arlen(arlen),
               .axi_aruser_id(arid),
               .axi_aruser_ap(arap),
               .axi_arvalid(arvalid),
               .axi_arready(arready),
               .axi_rdata(rdata),
               .axi_rid(rid),
               .axi_rvalid(rvalid),
               .axi_rlast(rlast));
    async_pixel_fifo #(.WIDTH(32),                                          // 双时钟像素 FIFO：本地二进制指针寻址，格雷码指针跨域同步以判断满空。
                       .ADDR_BITS(11))
                  pixels(.rst_n(rst_n &&  !vsync),
                         .wr_clk(clk),
                         .rd_clk(pix_clk),
                         .wr_valid(pair_valid &&  !restart &&  !vs_pipe[1] &&  !fault),
                         .wr_ready(fifo_ready),
                         .wr_data(pair_data),
                         .wr_used(fifo_used),
                         .rd_valid(fifo_valid),
                         .rd_ready(de && payload && output_x[0] &&  !frame_bad),
                         .rd_data(fifo_data));
    wire [10 : 0] staging_next      = (position + 2) >> 4;
    wire [10 : 0] staging_read_addr = state == PRIME || staging_next >= line_beats ? 0 : staging_next;
    always @(posedge clk)                                                   // 同步行缓存读出打一拍，与后续 PUSH 状态的像素选择对齐。
        if (rst_n &&  !fault && (state == PRIME || (state == PUSH && pair_ready &&  !restart &&  !vs_pipe[1])))
            staging_word <= staging[staging_read_addr];
    always @(posedge pix_clk or negedge pix_reset_sync[2]) begin
        if (!pix_reset_sync[2]) begin
            de1                  <= 0;
            de2                  <= 0;
            pixel1               <= 0;
            pixel                <= 0;
            owned_sync           <= 0;
            corrected_sync       <= 0;
            draw_enable          <= 0;
            draw_payload         <= 0;
            draw_marker          <= 0;
            draw_marker_bit      <= 0;
            output_x             <= 0;
            output_y             <= 0;
            frame_bad            <= 0;
            underflow            <= 0;
            descriptor_sync      <= 0;
            pixel_descriptor     <= 0;
            pixel_pan            <= 0;
            display_pan_seen     <= 0;
            display_pan          <= 0;
            display_gamma_seen   <= 0;
            display_gamma_enable <= 0;
            display_gamma_epoch  <= 0;
        end else begin
            owned_sync      <= {owned_sync[0], owned};
            de1             <= de;
            de2             <= de1;
            descriptor_sync <= {descriptor_sync[1 : 0], descriptor_toggle};
            if (descriptor_sync[2] != descriptor_sync[1]) begin
                pixel_descriptor <= descriptor;
                pixel_pan        <= pan_descriptor;
            end
            if (TELEMETRY_ENABLE && de && output_x == 0 && output_y == 1 && owned_sync[1] && corrected_sync[1] &&
                !frame_bad) begin
                display_gamma_seen   <= 1;
                display_gamma_enable <= pixel_descriptor[96];
                display_gamma_epoch  <= pixel_descriptor[99];

                if (PAN_ENABLE && pixel_pan[65] && (!display_pan_seen || pixel_pan[64 : 32] != display_pan[64 : 32]))
                begin
                    display_pan_seen <= 1;
                    display_pan      <= pixel_pan[64 : 0];
                end
            end
            corrected_sync <= {corrected_sync[0], view_corrected};

            pixel1          <= source_pixel;
            draw_enable     <= de && owned_sync[1] &&  !frame_bad;
            draw_payload    <= payload && fifo_valid;
            draw_marker     <= marker_region || metadata_region;
            draw_marker_bit <= metadata_region ? metadata_bit : marker_code[4'd15 - output_x[6 : 3]];
            pixel           <= draw_enable
                                   ? (draw_marker ? (draw_marker_bit ? 16'hffff : 16'd0) :  // 最后一级选择标记、真实像素或黑边。
                                          (draw_payload ? pixel1 : 16'd0))
                                   : 16'd0;
            if (vsync) begin
                output_x <= 0;
                output_y <= 0;
            end else if (de) begin
                if (output_x == ((DYNAMIC_MODE &&  !mode1080_pixel) ? 1280 : WIDTH) - 1) begin
                    output_x <= 0;
                    output_y <= output_y + 1'b1;
                end else
                    output_x <= output_x + 1'b1;
            end
            if (vsync)
                frame_bad <= 0;
            else if (de && payload && owned_sync[1] &&  !fifo_valid) begin  // 有效图像区若像素 FIFO 为空，记录本帧欠载，不伪装成正常完整帧。
                frame_bad <= 1;
                underflow <= 1;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= HOLD;
            owned             <= 0;
            restart           <= 0;
            vs_pipe           <= 0;
            base              <= 0;
            raw_base          <= 0;
            row               <= 0;
            returned          <= 0;
            position          <= 0;
            release_slot      <= 0;
            release_id        <= 0;
            view_corrected    <= 0;
            retain_pair       <= 0;
            descriptor        <= 0;
            descriptor_toggle <= 0;
            pan_descriptor    <= 0;
        end else begin
            vs_pipe <= {vs_pipe[1 : 0], vsync};
            if (line_data_valid) begin
                staging[returned] <= line_data;
                returned          <= returned + 1'b1;
            end
            case (state)
                RELEASE :                                                   // 在无在途行读取时释放当前帧对引用。
                    if (!owned || (release_valid && release_ready)) begin
                        owned   <= 0;
                        state   <= ACQUIRE;
                        restart <= 0;
                    end
                ACQUIRE :                                                   // 在视频帧边界取得最新完整结果及其关联原图。
                    if (acquire_valid && acquire_ready) begin
                        if (PAN_ENABLE)
                            pan_descriptor <= {acquire_pan, acquire_id};
                        if (TELEMETRY_ENABLE) begin
                            descriptor        <= {descriptor_body, crc8(descriptor_body)};
                            descriptor_toggle <=  !descriptor_toggle;
                        end
                        owned          <= 1;
                        release_slot   <= acquire_slot;
                        release_id     <= acquire_id;
                        base           <= acquire_base;
                        raw_base       <= acquire_raw_base;
                        row            <= 0;
                        view_corrected <= 0;
                        retain_pair    <= 0;
                        state          <= COMMAND;
                    end
                COMMAND :                                                   // 预取本显示行需要的 DDR 数据。
                    if (command_valid && line_ready) begin
                        returned <= 0;
                        state    <= WAIT_DATA;
                    end
                WAIT_DATA :                                                 // 等候行读取完成，再开始送入跨域像素 FIFO。
                    if (line_done) begin
                        if (restart)
                            state <= retain_pair ? REWIND : RELEASE;
                        else begin
                            position <= 0;
                            state    <= PRIME;
                        end
                    end
                PRIME :                                                     // 给同步行缓存读口预留读延迟。
                    state <= restart ? (retain_pair ? REWIND : RELEASE) : PUSH;
                PUSH :                                                      // 按 FIFO 接收能力逐个推送像素对。
                    if (!vs_pipe[1] && pair_ready &&  !restart) begin
                        if (position == stored_width - 2) begin
                            row   <= row + 1'b1;
                            state <= row == stored_height - 1 ? HOLD : COMMAND;
                        end else
                            position <= position + 2;
                    end
                HOLD : begin                                                // 已发送本帧全部像素，等待下一个场边界。
                end
                REWIND : begin                                              // 同一帧对由原图切换到矫正图，重新从首行预取。
                    row      <= 0;
                    returned <= 0;
                    position <= 0;
                    restart  <= 0;
                    state    <= COMMAND;
                end
                default :
                    state <= RELEASE;
            endcase
            if (vs_pipe[1] &&  !vs_pipe[2] && state != ACQUIRE) begin       // 场边界先把同一帧对从原图切到矫正图；矫正图结束后才释放并取下一对。
                restart <= 1;
                if (owned &&  !view_corrected) begin
                    view_corrected <= 1;
                    retain_pair    <= 1;
                    state          <= busy ? WAIT_DATA : REWIND;
                end else begin
                    retain_pair <= 0;
                    state       <= busy ? WAIT_DATA : RELEASE;
                end
            end
        end
    end
endmodule
