`timescale 1ns/1ps
 
 
 
module video_performance_monitor                                            // 按帧号关联采集、处理和输出事件，统计周期与异常并生成可冻结诊断快照。
    #(                                                                      // 仅观测事件与统计时间，不驱动图像数据通路。
      parameter [31 : 0] CORE_HZ = 125000000, WINDOW_TICKS = 1250000000, SETTLE_TICKS = 125000000)
    (input wire             clk, rst_n, initialized, arm_toggle,            // 本模块工作时钟；低有效复位。
     input wire             cam_clk, cam_vsync, cam_de, cam_header_written,  // 相机像素时钟。
     input wire             pix_clk, pix_vsync, pix_output_de,              // 视频像素时钟。
     input wire             raw_start, raw_drop, raw_done, process_start, process_done,
     input wire [31 : 0]    raw_id, process_start_id, process_done_id,
     input wire             acquire,
     input wire [31 : 0]    acquire_id,
     input wire             fault, underflow,                               // 锁存的异常标志。
     output wire [1023 : 0] snapshot);                                      // 供串口或 JTAG 读取的诊断快照。

    reg  cam_vs_d, cam_armed;
    wire cam_event = cam_armed && cam_de;
    always @(posedge cam_clk or negedge rst_n) begin
        if (!rst_n) begin
            cam_vs_d  <= 0;
            cam_armed <= 0;
        end else begin
            cam_vs_d <= cam_vsync;
            if (cam_vsync &&  !cam_vs_d)
                cam_armed <= 1;
            else if (cam_event)
                cam_armed <= 0;
        end
    end
    wire cam_received, cam_written, cam_overflow;
    perf_event_mailbox #(.WIDTH(1))                                         // 事件邮箱跨域：载荷保持到对端确认，请求和确认均用翻转标识传递。
        camera_events(.rst_n(rst_n),
                      .src_clk(cam_clk),
                      .src_event(cam_event),
                      .src_data(cam_header_written),
                      .overflow(cam_overflow),
                      .dst_clk(clk),
                      .dst_event(cam_received),
                      .dst_data(cam_written));

    wire          acquired_pix, acquire_overflow;
    wire [31 : 0] acquired_id;
    perf_event_mailbox #(.WIDTH(32))                                        // 事件邮箱跨域：载荷保持到对端确认，请求和确认均用翻转标识传递。
                 ownership_events(.rst_n(rst_n),
                                  .src_clk(clk),
                                  .src_event(acquire),
                                  .src_data(acquire_id),
                                  .overflow(acquire_overflow),
                                  .dst_clk(pix_clk),
                                  .dst_event(acquired_pix),
                                  .dst_data(acquired_id));
    reg          pix_vs_d, pix_armed, pix_has_id;
    reg [31 : 0] pix_id;
    wire         pix_refresh = pix_vsync &&  !pix_vs_d;
    wire         pix_first   = pix_armed && pix_output_de;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_vs_d   <= 0;
            pix_armed  <= 0;
            pix_id     <= 0;
            pix_has_id <= 0;
        end else begin
            pix_vs_d <= pix_vsync;
            if (pix_refresh) begin
                pix_armed  <= 1;
                pix_has_id <= 0;
            end else if (pix_first)
                pix_armed <= 0;
            if (acquired_pix) begin
                pix_id     <= acquired_id;
                pix_has_id <= 1;
            end
        end
    end
    wire               refresh_received, refresh_overflow, refresh_unused;
    perf_event_mailbox refresh_events(.rst_n(rst_n),                        // 事件邮箱跨域：载荷保持到对端确认，请求和确认均用翻转标识传递。
                                      .src_clk(pix_clk),
                                      .src_event(pix_refresh),
                                      .src_data(1'b0),
                                      .overflow(refresh_overflow),
                                      .dst_clk(clk),
                                      .dst_event(refresh_received),
                                      .dst_data(refresh_unused));
    wire               output_received, output_overflow;
    wire [32 : 0]      output_data;
    perf_event_mailbox #(.WIDTH(33))                                        // 事件邮箱跨域：载荷保持到对端确认，请求和确认均用翻转标识传递。
                                           output_events(.rst_n(rst_n),
                                                         .src_clk(pix_clk),
                                                         .src_event(pix_first),
                                                         .src_data({pix_has_id, pix_id}),
                                                         .overflow(output_overflow),
                                                         .dst_clk(clk),
                                                         .dst_event(output_received),
                                                         .dst_data(output_data));
    (* async_reg="true" *) reg [1 : 0] cam_error_sync, pix_error_sync, underflow_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cam_error_sync <= 0;
            pix_error_sync <= 0;
            underflow_sync <= 0;
        end else begin
            cam_error_sync <= {cam_error_sync[0], cam_overflow};
            pix_error_sync <= {pix_error_sync[0], refresh_overflow || output_overflow};
            underflow_sync <= {underflow_sync[0], underflow};
        end
    end
    wire cdc_error = cam_error_sync[1] || pix_error_sync[1] || acquire_overflow;

    reg [31 : 0] tick, header_time[0 : 15];
    reg [4 : 0]  header_wr, header_rd;
    wire         header_push = cam_received && cam_written;
    wire         header_pop  = raw_start || raw_drop;
    wire         queue_empty = header_wr == header_rd;
    wire         queue_full  = header_wr[4] != header_rd[4] && header_wr[3 : 0] == header_rd[3 : 0];
    reg [31 : 0] tags[0 : 15], t0[0 : 15], t1[0 : 15], t3[0 : 15];
    reg [15 : 0] valid, process_valid;
    reg          metadata_error;
    wire [3 : 0] raw_slot = raw_id[3 : 0], start_slot = process_start_id[3 : 0];
    wire [3 : 0] done_slot = process_done_id[3 : 0], out_slot = output_data[3 : 0];
    wire         out_match  = valid[out_slot] && tags[out_slot] == output_data[31 : 0];
    wire         proc_match = valid[done_slot] && process_valid[done_slot] && tags[done_slot] == process_done_id;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick           <= 0;
            header_wr      <= 0;
            header_rd      <= 0;
            valid          <= 0;
            process_valid  <= 0;
            metadata_error <= 0;
        end else begin
            tick <= tick + 1'b1;
            if (header_push) begin
                if (queue_full)
                    metadata_error <= 1;
                else begin
                    header_time[header_wr[3 : 0]] <= tick;
                    header_wr                     <= header_wr + 1'b1;
                end
            end
            if (header_pop) begin
                if (queue_empty &&  !header_push)
                    metadata_error <= 1;
                else
                    header_rd <= header_rd + 1'b1;
            end
            if (raw_start) begin
                tags[raw_slot]          <= raw_id;
                t1[raw_slot]            <= tick;
                process_valid[raw_slot] <= 0;
                valid[raw_slot]         <=  !queue_empty || header_push;
                t0[raw_slot]            <= queue_empty ? tick : header_time[header_rd[3 : 0]];
            end
            if (process_start) begin                                        // 通过帧号及索引核对处理起点，避免不同帧的计时被错误拼接。
                if (!valid[start_slot] || tags[start_slot] != process_start_id)
                    metadata_error <= 1;
                else begin
                    t3[start_slot]            <= tick;
                    process_valid[start_slot] <= 1;
                end
            end
        end
    end

    reg                                    running, done, auto_started, arm_d;
    reg                                    initialized_q, begin_window;
    (* async_reg="true" *) reg [1 : 0] arm_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            initialized_q <= 0;
            begin_window  <= 0;
            arm_sync      <= 0;
        end else begin
            initialized_q <= initialized;
            arm_sync      <= {arm_sync[0], arm_toggle};
            begin_window  <= (arm_sync[1] != arm_d) || (!auto_started && initialized_q && settle == SETTLE_TICKS - 1);
        end
    end
    reg [31 : 0] elapsed, settle, generation;
    reg [31 : 0] sensor_count, accepted_count, raw_done_count, start_count, done_count;
    reg [31 : 0] refresh_count, new_count, repeat_count, last_id, lat_count, proc_count, missing;
    reg          last_valid;
    reg          seen_fault, seen_underflow, seen_cdc;
    reg [31 : 0] full_min, full_max, internal_min, internal_max, proc_min, proc_max;
    reg [39 : 0] full_sum, internal_sum, proc_sum;

    reg          out_pending, proc_pending, out_was_new, out_was_match;
    reg [31 : 0] full_delta, internal_delta, proc_delta;
    wire         new_output = output_received && output_data[32] && (!last_valid || last_id != output_data[31 : 0]);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running        <= 0;
            done           <= 0;
            auto_started   <= 0;
            arm_d          <= 0;
            elapsed        <= 0;
            settle         <= 0;
            generation     <= 0;
            sensor_count   <= 0;
            accepted_count <= 0;
            raw_done_count <= 0;
            start_count    <= 0;
            done_count     <= 0;
            refresh_count  <= 0;
            new_count      <= 0;
            repeat_count   <= 0;
            last_id        <= 0;
            last_valid     <= 0;
            lat_count      <= 0;
            proc_count     <= 0;
            missing        <= 0;
            full_min       <= 32'hffffffff;
            full_max       <= 0;
            internal_min   <= 32'hffffffff;
            internal_max   <= 0;
            proc_min       <= 32'hffffffff;
            proc_max       <= 0;
            full_sum       <= 0;
            internal_sum   <= 0;
            proc_sum       <= 0;
            seen_fault     <= 0;
            seen_underflow <= 0;
            seen_cdc       <= 0;
            out_pending    <= 0;
            proc_pending   <= 0;
            out_was_new    <= 0;
            out_was_match  <= 0;
            full_delta     <= 0;
            internal_delta <= 0;
            proc_delta     <= 0;
        end else begin
            arm_d <= arm_sync[1];
            if (initialized_q &&  !auto_started && settle < SETTLE_TICKS)
                settle <= settle + 1'b1;

            if (output_received && output_data[32]) begin
                last_id    <= output_data[31 : 0];
                last_valid <= 1;
            end
            out_pending   <= running && new_output;
            out_was_new   <= new_output;
            out_was_match <= out_match;
            if (new_output) begin
                full_delta     <= tick - t0[out_slot];
                internal_delta <= tick - t1[out_slot];
            end
            proc_pending <= running && process_done && proc_match;

            proc_delta <= tick - t3[done_slot];
            if (begin_window) begin
                running        <= 1;
                done           <= 0;
                auto_started   <= 1;
                elapsed        <= 0;
                generation     <= generation + 1'b1;
                sensor_count   <= 0;
                accepted_count <= 0;
                raw_done_count <= 0;
                start_count    <= 0;
                done_count     <= 0;
                refresh_count  <= 0;
                new_count      <= 0;
                repeat_count   <= 0;
                lat_count      <= 0;
                proc_count     <= 0;
                missing        <= 0;
                full_min       <= 32'hffffffff;
                full_max       <= 0;
                internal_min   <= 32'hffffffff;
                internal_max   <= 0;
                proc_min       <= 32'hffffffff;
                proc_max       <= 0;
                full_sum       <= 0;
                internal_sum   <= 0;
                proc_sum       <= 0;
                seen_fault     <= 0;
                seen_underflow <= 0;
                seen_cdc       <= 0;
                out_pending    <= 0;
                proc_pending   <= 0;
            end else begin
                if (running) begin
                    elapsed <= elapsed + 1'b1;
                    if (elapsed == WINDOW_TICKS - 1)
                        running <= 0;
                    seen_fault     <= seen_fault || fault;
                    seen_underflow <= seen_underflow || underflow_sync[1];
                    seen_cdc       <= seen_cdc || cdc_error;
                    if (cam_received)
                        sensor_count <= sensor_count + 1'b1;
                    if (raw_start)
                        accepted_count <= accepted_count + 1'b1;
                    if (raw_done)
                        raw_done_count <= raw_done_count + 1'b1;
                    if (process_start)
                        start_count <= start_count + 1'b1;
                    if (process_done)
                        done_count <= done_count + 1'b1;
                    if (refresh_received)
                        refresh_count <= refresh_count + 1'b1;
                    if (new_output)
                        new_count <= new_count + 1'b1;
                    if (output_received && output_data[32] &&  !new_output)
                        repeat_count <= repeat_count + 1'b1;
                end

                if (!running && auto_started &&  !out_pending &&  !proc_pending)
                    done <= 1;
                if (out_pending) begin
                    if (!out_was_match)
                        missing <= missing + 1'b1;
                    else begin
                        lat_count    <= lat_count + 1'b1;
                        full_sum     <= full_sum + full_delta;
                        internal_sum <= internal_sum + internal_delta;
                        if (full_delta < full_min)
                            full_min <= full_delta;
                        if (full_delta > full_max)
                            full_max <= full_delta;
                        if (internal_delta < internal_min)
                            internal_min <= internal_delta;
                        if (internal_delta > internal_max)
                            internal_max <= internal_delta;
                    end
                end
                if (proc_pending) begin
                    proc_count <= proc_count + 1'b1;
                    proc_sum   <= proc_sum + proc_delta;
                    if (proc_delta < proc_min)
                        proc_min <= proc_delta;
                    if (proc_delta > proc_max)
                        proc_max <= proc_delta;
                end
            end
        end
    end

    reg [1023 : 0]  frozen;
    reg             done_d;
    wire [31 : 0]   status = {26'd0, seen_cdc, metadata_error, seen_underflow, seen_fault, done, running};
    wire [1023 : 0] live   = {32'd0,
                              generation,
                              missing,
                              last_id,
                              {24'd0, proc_sum[39 : 32]},
                              proc_sum[31 : 0],
                              proc_max,
                              proc_min,
                              proc_count,
                              {24'd0, internal_sum[39 : 32]},
                              internal_sum[31 : 0],
                              internal_max,
                              internal_min,
                              {24'd0, full_sum[39 : 32]},
                              full_sum[31 : 0],
                              full_max,
                              full_min,
                              lat_count,
                              repeat_count,
                              new_count,
                              refresh_count,
                              done_count,
                              start_count,
                              raw_done_count,
                              accepted_count,
                              sensor_count,
                              elapsed,
                              WINDOW_TICKS,
                              CORE_HZ,
                              status,
                              32'd1,
                              32'h50455246};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frozen <= 0;
            done_d <= 0;
        end else begin
            done_d <= done;
            if (done &&  !done_d)                                           // 测量窗口结束后冻结快照，软件分段读取期间内容不再改变。
                frozen <= live;
        end
    end

    assign snapshot = done_d ? frozen : live;
endmodule
