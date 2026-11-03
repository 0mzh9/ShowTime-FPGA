`timescale 1ns/1ps
 
 
 
module raw_frame_manager                                                    // 原帧三槽所有权管理：收齐图像并确认待写事务结束后，才把帧交给处理端。
    #(                                                                      // 分离原图采集和处理的所有权，防止覆盖正在读取的帧。
      parameter          WIDTH = 1280, HEIGHT = 720, SLOTS = 3,             // 源图每行像素数；源图有效行数；原帧槽数量。
      parameter [31 : 0] BASE_WORD = 0, STRIDE_WORD = 32'h00400000)         // 帧存储起始字地址；相邻帧槽之间的字地址间隔。
    (input wire clk, rst_n,                                                 // 处理时钟；低有效复位。
     input wire           capture_begin_valid,                              // 申请新的原帧采集槽。
     output wire          capture_begin_ready,                              // 采集槽申请可被接受。
     output wire [1 : 0]  capture_begin_slot,                               // 分配给采集端的原帧槽号。
     output wire [31 : 0] capture_begin_base, capture_begin_frame_id,       // 新采集帧的 DDR 基址；新采集帧的递增帧号。
     input wire           capture_line_valid,                               // 一行有效像素接收完毕。
     input wire [15 : 0]  capture_line_pixels,
     output wire          capture_line_ready,                               // 可接收当前行的完成信息。
     input wire           capture_end_valid,                                // 当前相机帧结束。
     output wire          capture_end_ready,                                // 可接收当前帧的结束信息。
     input wire           writer_flushed, write_issue, write_retire,        // 写入端无残留像素数据；一笔 DDR 写事务已经发出；一笔 DDR 写事务已确认结束。
     output wire          process_valid,                                    // 有完整原帧等待处理。
     input wire           process_ready,                                    // 处理端可取得该原帧。
     output wire [1 : 0]  process_slot,                                     // 待处理原帧槽号。
     output wire [31 : 0] process_base, process_frame_id,                   // 待处理原帧 DDR 基址；待处理原帧的帧号。
     input wire           release_valid,                                    // 请求释放已有帧引用。
     output wire          release_ready,                                    // 该帧引用可以释放。
     input wire [1 : 0]   release_slot,
     input wire [31 : 0]  release_frame_id,
     output reg           fault,                                            // 锁存的故障标志。
     output reg [3 : 0] fault_code,                                         // 故障类型编码。
     output reg [31 : 0]             published_frames, dropped_frames,
     output wire [2 * SLOTS - 1 : 0] slot_states,
     output wire [15 : 0]            pending_writes);
    localparam   FREE = 0, CAPTURING = 1, COMPLETE = 2, PROCESSING = 3;     // 槽状态区分空闲、采集中、完整待处理及处理中，所有权随握手转移。
    reg [1 : 0]  ownership[0 : SLOTS - 1];
    reg [31 : 0] frame_id[0 : SLOTS - 1], next_frame_id;
    reg          capture_active, process_active, sealed, flushed, bad_frame;
    reg [1 : 0]  capture_owner, process_owner;
    reg [15 : 0] lines, pending;
    reg [1 : 0]  complete_queue[0 : SLOTS - 1], head, tail;
    reg [2 : 0]  queue_count;
    reg          free_found;
    reg [1 : 0]  free_slot;
    integer      i, k;
    always @ * begin
        free_found = 0;
        free_slot  = 0;
        for (k = SLOTS - 1; k >= 0; k = k - 1) begin
            if (ownership[k] == FREE) begin
                free_found = 1;
                free_slot  = k;
            end
        end
    end
    genvar g;
    generate
        for (g = 0; g < SLOTS; g = g + 1) begin : states
            assign slot_states[2 * g +: 2] = ownership[g];
        end
    endgenerate
    assign pending_writes         = pending;
    assign capture_begin_ready    = rst_n &&  !fault &&  !capture_active && free_found;  // 只有存在空闲槽且未在采集时才允许取得新原帧槽。
    assign capture_begin_slot     = free_slot;
    assign capture_begin_base     = BASE_WORD + free_slot * STRIDE_WORD;
    assign capture_begin_frame_id = next_frame_id;
    assign capture_line_ready     = rst_n &&  !fault && capture_active &&  !sealed;
    assign capture_end_ready      = capture_line_ready;
    assign process_valid          = rst_n &&  !fault && queue_count != 0;   // 只向处理端发布完成队列中的整帧，不把相机帧尾当作写入已完成。
    assign process_slot           = complete_queue[head];
    assign process_base           = BASE_WORD + process_slot * STRIDE_WORD;
    assign process_frame_id       = frame_id[process_slot];
    assign release_ready          = rst_n &&  !fault;
    wire   capture_accept         = capture_begin_valid && capture_begin_ready;
    wire   process_accept         = process_valid && process_ready;
    wire   release_accept         = release_valid && release_ready;
    wire   settled       = capture_active && sealed && flushed && pending == 0 &&  !write_issue &&  !write_retire;
    wire   publish       = settled &&  !bad_frame && lines == HEIGHT;
    wire   discard       = settled && (bad_frame || lines != HEIGHT);
    wire   invalid_write = (write_issue || write_retire) &&  !capture_active || write_issue && flushed ||
                           write_retire && pending == 0 &&  !write_issue ||
                           write_issue &&  !write_retire && pending == 16'hffff;
    always @(posedge clk) begin
        if (!rst_n) begin
            capture_active   <= 0;
            process_active   <= 0;
            sealed           <= 0;
            flushed          <= 0;
            bad_frame        <= 0;
            capture_owner    <= 0;
            process_owner    <= 0;
            lines            <= 0;
            pending          <= 0;
            head             <= 0;
            tail             <= 0;
            queue_count      <= 0;
            next_frame_id    <= 1;
            fault            <= 0;
            fault_code       <= 0;
            published_frames <= 0;
            dropped_frames   <= 0;
            for (i = 0; i < SLOTS; i = i + 1) begin
                ownership[i]      <= FREE;
                frame_id[i]       <= 0;
                complete_queue[i] <= 0;
            end
        end else if (!fault) begin
            if (invalid_write) begin
                fault      <= 1;
                fault_code <= 1;
            end else if (release_accept && (release_slot >= SLOTS || ownership[release_slot] != PROCESSING ||
                                            release_frame_id != frame_id[release_slot])) begin
                fault      <= 1;
                fault_code <= 2;
            end else if ((capture_line_valid || capture_end_valid || writer_flushed) &&  !capture_active) begin
                fault      <= 1;
                fault_code <= 3;
            end else if (capture_line_valid && sealed) begin
                fault      <= 1;
                fault_code <= 4;
            end else if (capture_accept && next_frame_id == 0) begin
                fault      <= 1;
                fault_code <= 5;
            end else begin
                if (capture_accept) begin
                    ownership[free_slot] <= CAPTURING;
                    frame_id[free_slot]  <= next_frame_id;
                    next_frame_id        <= next_frame_id + 1'b1;
                    capture_owner        <= free_slot;
                    capture_active       <= 1;
                    sealed               <= 0;
                    flushed              <= 0;
                    bad_frame            <= 0;
                    lines                <= 0;
                    pending              <= 0;
                end
                if (capture_line_valid && capture_line_ready) begin         // 校验每行像素数及总行数，异常帧不进入完整帧队列。
                    if (capture_line_pixels != WIDTH || lines >= HEIGHT)
                        bad_frame <= 1;
                    if (lines <= HEIGHT)
                        lines <= lines + 1'b1;
                end
                if (capture_end_valid && capture_end_ready)
                    sealed <= 1;
                if (writer_flushed && capture_active)
                    flushed <= 1;
                if (write_issue &&  !write_retire)                          // 只统计尚未确认的写事务；提出和完成同时发生时保持数量不变。
                    pending <= pending + 1'b1;
                if (write_retire &&  !write_issue)
                    pending <= pending - 1'b1;
                if (publish || discard) begin                               // 只有发布或丢弃整帧时才结束当前采集槽的占用。
                    capture_active <= 0;
                    sealed         <= 0;
                    flushed        <= 0;
                    if (publish) begin
                        ownership[capture_owner] <= COMPLETE;
                        complete_queue[tail]     <= capture_owner;
                        tail                     <= tail == SLOTS - 1 ? 0 : tail + 1'b1;
                        published_frames         <= published_frames + 1'b1;
                    end else begin
                        ownership[capture_owner] <= FREE;
                        dropped_frames           <= dropped_frames + 1'b1;
                    end
                end
                if (process_accept) begin
                    ownership[process_slot] <= PROCESSING;
                    process_owner           <= process_slot;
                    process_active          <= 1;
                    head                    <= head == SLOTS - 1 ? 0 : head + 1'b1;
                end
                case ({publish, process_accept})
                    2'b10 :
                        queue_count <= queue_count + 1'b1;
                    2'b01 :
                        queue_count <= queue_count - 1'b1;
                    default : begin
                    end
                endcase
                if (release_accept) begin
                    ownership[release_slot] <= FREE;
                    process_active          <= 0;
                end
            end
        end
    end
endmodule
