`timescale 1ns/1ps
module camera_correction_bridge                                             // 采集到显示的板级桥接：跨域收帧、整帧管理、处理、DDR 仲裁及 HDMI 读出。
    #(parameter PAN_ENABLE = 0, RUNTIME_CALIBRATION = 0, GAMMA_ENABLE = 0, DYNAMIC_MODE = 0, WIDTH = 1280, HEIGHT = 720,  // 源图每行像素数；源图有效行数；是否编入虚拟转向通路；是否编入 Gamma 查表通路；是否使用运行时标定参数；是否根据运行时模式选择输出尺寸。
                OUT_WIDTH = 1920, OUT_HEIGHT = 1080, A = 28, PERF_ENABLE = 0, PERF_DVP = 0, SPLIT_ENABLE = 0,
                ALTERNATE_ENABLE = 0)
    (input wire [639 : 0] calibration,                                      // 当前帧使用的标定参数。
     input wire pan_request,                                                // 转向请求翻转标识。
     input wire signed [15 : 0] pan_angle,                                  // 转向角，单位 0.1 度。
     input wire [15 : 0] pan_sequence,                                      // 转向事务序号。
     output wire          display_pan_seen,                                 // 已检测到目标矫正帧开始 HDMI 输出。
     output wire [64 : 0] display_pan,                                      // 目标输出帧的转向状态与帧号。
     input wire           mode1080, mode1080_pixel, quiesce,                // 选择 1080P 输出画布。
     input wire           gamma_enable, gamma_epoch,                        // 自适应 Gamma 开关；Gamma 状态代次。
     output wire display_gamma_seen, display_gamma_enable, display_gamma_epoch,
     output wire drained,                                                   // 在途 DDR 事务已排空。
     input wire          clk, rst_n, cam_clk, cam_vsync, cam_de, pix_clk, display_vsync, display_de,  // 本模块工作时钟；低有效复位；相机像素时钟；视频像素时钟。
     input wire          perf_dvp_clk, perf_dvp_vsync, perf_dvp_href, perf_camera_initialized,
     input wire [15 : 0] cam_pixel,                                         // 摄像头 RGB565 像素。
     output wire [15 : 0] display_pixel,                                    // HDMI RGB565 输出像素。
     output wire display_pixel_de, init_done, fault,                        // 与输出像素对齐的有效标志；首个可用图像对已发布；锁存的故障标志。
     output wire [A - 1 : 0] axi_araddr, axi_awaddr,                        // DDR 读字地址；DDR 写字地址。
     output wire [3 : 0] axi_arlen, axi_aruser_id, axi_awlen, axi_awuser_id,
     output wire         axi_arvalid, axi_aruser_ap, axi_awvalid, axi_awuser_ap,
     input wire          axi_arready, axi_awready,                          // DDR 接受读地址；DDR 接受写地址。
     input wire [255 : 0] axi_rdata,                                        // 原生 DDR 返回数据。
     input wire [3 : 0] axi_rid, axi_wusero_id,
     input wire         axi_rvalid, axi_rlast, axi_wready, axi_wusero_last,  // DDR 返回拍有效；当前突发最后一拍；原生 DDR 请求提供写数据；原生写数据末拍指示。
     output wire [255 : 0] axi_wdata,                                       // 原生 DDR 写数据。
     output wire [31 : 0] axi_wstrb                                         // 原生 DDR 字节使能。
    );
    localparam N = WIDTH * HEIGHT;

    localparam          DISPLAY_WIDTH = OUT_WIDTH;
    localparam          STORAGE_WIDTH = SPLIT_ENABLE ? 2 * WIDTH : WIDTH;
    wire                display_corrected;
    localparam [15 : 0] LINE_PIXELS = WIDTH;
    wire                camera_valid, camera_ready, camera_overflow, fifo_ready;
    wire [17 : 0]       camera_data, fifo_raw_data;
    wire                fifo_raw_valid, fifo_raw_ready;
    reg                 fifo_valid;
    reg [17 : 0]        fifo_data;
    reg [1 : 0]         overflow_sync;
    reg [2 : 0]         cam_reset_sync, pix_reset_sync;
    always @(posedge cam_clk or negedge rst_n)
        if (!rst_n)
            cam_reset_sync <= 0;
        else
            cam_reset_sync <= {cam_reset_sync[1 : 0], 1'b1};
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n)
            pix_reset_sync <= 0;
        else
            pix_reset_sync <= {pix_reset_sync[1 : 0], 1'b1};
    camera_frame_stream #(.WIDTH(WIDTH),                                    // 为相机有效像素附加帧首和帧尾标记；无反压能力的输入发生拥塞时报告丢帧。
                          .HEIGHT(HEIGHT))
                     stream(                                                // 先校验完整像素流的帧界及像素计数。
                             .clk(cam_clk),
                             .rst_n(cam_reset_sync[2]),
                             .vsync(cam_vsync),
                             .de(cam_de),
                             .pixel(cam_pixel),
                             .valid(camera_valid),
                             .ready(camera_ready),
                             .data(camera_data),
                             .overflow(camera_overflow));
    async_pixel_fifo camera_fifo(.rst_n(rst_n),                             // 双时钟像素 FIFO：本地二进制指针寻址，格雷码指针跨域同步以判断满空。
                                 .wr_clk(cam_clk),
                                 .rd_clk(clk),                              // 摄像头 PCLK 到处理时钟域的跨时钟缓冲。
                                 .wr_valid(camera_valid),
                                 .wr_ready(camera_ready),
                                 .wr_data(camera_data),
                                 .wr_used(),
                                 .rd_valid(fifo_raw_valid),
                                 .rd_ready(fifo_raw_ready),
                                 .rd_data(fifo_raw_data));

    assign fifo_raw_ready = rst_n && (!fifo_valid || fifo_ready);           // 相机 FIFO 输出加一级弹性寄存，阻塞时保留带帧首尾标记的当前像素。
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_valid <= 0;
            fifo_data  <= 0;
        end else if (fifo_raw_ready) begin
            fifo_valid <= fifo_raw_valid;
            if (fifo_raw_valid)
                fifo_data <= fifo_raw_data;
        end
    end
    wire          core_fault, cap_fault, display_fault, board_fault, display_underflow;
    reg           capture_fault, capturing;
    reg [31 : 0]  capture_index, previous_verified;
    reg [10 : 0]  capture_x;
    wire [31 : 0] cap_verified;
    assign        fault = core_fault || cap_fault || display_fault || board_fault || capture_fault || overflow_sync[1];  // 汇总处理、采集、显示、DDR 及跨域溢出故障，用于停止和健康查询。
    wire          cap_begin_ready, cap_line_ready, cap_end_ready, cap_start_ready, cap_pixel_ready, cap_done_valid;
    wire [1 : 0]  cap_slot;
    wire [31 : 0] cap_base, cap_id, cap_done_id, cap_done_base;
    wire          begin_valid =  !capturing && fifo_valid && fifo_data[17] && cap_start_ready &&  !fault;
    wire          start_valid =  !capturing && fifo_valid && fifo_data[17] && cap_begin_ready &&  !fault;
    wire          start       = begin_valid && cap_begin_ready;
    assign        fifo_ready =
                      !fault &&
                      (capturing ? cap_pixel_ready : (fifo_valid && (!fifo_data[17] ||  !cap_begin_ready ||  !cap_start_ready)));
    wire          capture_pixel  = capturing && fifo_valid &&  !fault;
    wire          pixel_fire     = capture_pixel && cap_pixel_ready;
    wire          cap_line_valid = pixel_fire && capture_x == WIDTH - 1;
    wire          cap_end_valid  = pixel_fire && capture_index == N - 1;
    wire          cap_retire     = capturing && cap_verified != previous_verified;
    wire          cap_done_ready = capturing &&  !fault;
    wire          acq_valid, acq_ready, acq_slot, rel_valid, rel_ready, rel_slot;
    wire [31 : 0] acq_base, acq_raw_base, acq_id, rel_id, published;
    wire          processing_begin, processing_finish;
    wire [3 : 0]  adaptive_level;
    wire [7 : 0]  mean_brightness, dark_ratio, high_ratio;
    wire [61 : 0] acq_meta;
    wire [33 : 0] acq_pan;
    adaptive_gamma_stats stats(.clk(clk),                                   // 对完整原帧统计亮度与暗亮比例，平滑统计后逐档调节 Gamma；不修改输入像素。
                               .rst_n(rst_n),
                               .enable(gamma_enable),                       // 从有效原图统计平均亮度及暗部、高亮比例。
                               .pixel_valid(pixel_fire),
                               .first(capture_index == 0),
                               .last(capture_index == N - 1),
                               .pixel(fifo_data[15 : 0]),
                               .level(adaptive_level),
                               .mean(mean_brightness),
                               .dark(dark_ratio),
                               .high(high_ratio),
                               .stats_valid());
    wire [31 : 0]        processing_begin_id, processing_finish_id;
    wire [A - 1 : 0]     c_araddr, c_awaddr, v_araddr, p_awaddr, d_araddr;
    wire [3 : 0]         c_arlen, c_arid, c_awlen, c_awid, v_arlen, v_arid, p_awlen, p_awid, d_arlen, d_arid;
    wire                 c_arvalid, c_awvalid, c_arap, c_awap, v_arvalid, v_arap, p_awvalid, p_awap, d_arvalid, d_arap;
    wire [2 : 0]         r_ready, r_return;
    wire [1 : 0]         w_ready, w_request;
    wire [255 : 0]       c_wdata, p_wdata;
    wire [31 : 0]        c_wstrb, p_wstrb;
    assign               init_done = published != 0;                        // 至少一个完整原帧发布后才认为采集链路已初始化。
    undistort_core #(.PAN_ENABLE(PAN_ENABLE),                               // 整帧处理核心：锁定原帧、扫描输出坐标、逆映射取样，完成写回后发布结果及关联元数据。
                     .RUNTIME_CALIBRATION(RUNTIME_CALIBRATION),
                     .GAMMA_ENABLE(GAMMA_ENABLE),
                     .DYNAMIC_MODE(DYNAMIC_MODE),
                     .WIDTH(WIDTH),
                     .HEIGHT(HEIGHT),
                     .OUT_WIDTH(OUT_WIDTH),
                     .OUT_HEIGHT(OUT_HEIGHT),
                     .ADDR_WIDTH(A),
                     .SPLIT_ENABLE(0))
        core(                                                               // 几何映射、取样、Gamma 与插值均在此 FPGA 内核完成。
                .pan_request(pan_request),
                .pan_angle(pan_angle),
                .pan_sequence(pan_sequence),
                .acquire_pan(acq_pan),
                .calibration(calibration),
                .gamma_enable(gamma_enable),
                .gamma_epoch(gamma_epoch),
                .gamma_level(adaptive_level),
                .gamma_stats({mean_brightness, dark_ratio, high_ratio}),
                .acquire_meta(acq_meta),
                .mode1080(mode1080),
                .clk(clk),
                .rst_n(rst_n),
                .ddr_init_done(rst_n),
                .capture_begin_valid(begin_valid),
                .capture_begin_ready(cap_begin_ready),
                .capture_begin_slot(cap_slot),
                .capture_begin_base(cap_base),
                .capture_begin_frame_id(cap_id),
                .capture_line_valid(cap_line_valid),
                .capture_line_pixels(LINE_PIXELS),
                .capture_line_ready(cap_line_ready),
                .capture_end_valid(cap_end_valid),
                .capture_end_ready(cap_end_ready),
                .writer_flushed(cap_done_valid && cap_done_ready),
                .write_issue(p_awvalid && w_ready[1]),
                .write_retire(cap_retire),
                .acquire_valid(acq_valid),
                .acquire_reader(1'b0),
                .acquire_ready(acq_ready),
                .acquire_slot(acq_slot),
                .acquire_base(acq_base),
                .acquire_raw_base(acq_raw_base),
                .acquire_frame_id(acq_id),
                .release_valid(rel_valid),
                .release_reader(1'b0),
                .release_slot(rel_slot),
                .release_ready(rel_ready),
                .release_frame_id(rel_id),
                .axi_araddr(c_araddr),
                .axi_arlen(c_arlen),
                .axi_aruser_id(c_arid),
                .axi_aruser_ap(c_arap),
                .axi_arvalid(c_arvalid),
                .axi_arready(r_ready[0]),
                .axi_awaddr(c_awaddr),
                .axi_awlen(c_awlen),
                .axi_awuser_id(c_awid),
                .axi_awuser_ap(c_awap),
                .axi_awvalid(c_awvalid),
                .axi_awready(w_ready[0]),
                .axi_rdata(axi_rdata),
                .axi_rid(axi_rid),
                .axi_rvalid(r_return[0]),
                .axi_rlast(axi_rlast),
                .axi_wready(w_request[0]),
                .axi_wusero_id(axi_wusero_id),
                .axi_wusero_last(axi_wusero_last),
                .axi_wdata(c_wdata),
                .axi_wstrb(c_wstrb),
                .fault(core_fault),
                .fault_code(),
                .frame_completed(),
                .completed_frame_id(),
                .published_frames(published),
                .line_loads(),
                .cache_hits(),
                .blocks_verified(),
                .verify_retries(),
                .processing_begin(processing_begin),
                .processing_finish(processing_finish),
                .processing_begin_id(processing_begin_id),
                .processing_finish_id(processing_finish_id));
    corrected_frame_writer #(.WIDTH(WIDTH),                                 // 结果写帧器：将 RGB565 打包为 DDR 宽字，写后读回验证，通过后才提交整帧。
                             .HEIGHT(HEIGHT),
                             .ADDR_WIDTH(A),
                             .WRITE_ID(10),
                             .VERIFY_ID(10))
        capture_writer(                                                     // 采集原图写入 DDR，并完成读回校验。
                .clk(clk),
                .rst_n(rst_n),
                .ddr_init_done(rst_n),
                .frame_start_valid(start_valid),
                .frame_start_ready(cap_start_ready),
                .frame_base_word(cap_base),
                .frame_id(cap_id),
                .pixel_valid(capture_pixel),
                .pixel_ready(cap_pixel_ready),
                .pixel(fifo_data[15 : 0]),
                .pixel_index(capture_index),
                .pixel_last(fifo_data[16]),
                .frame_done_valid(cap_done_valid),
                .frame_done_ready(cap_done_ready),
                .done_base_word(cap_done_base),
                .done_frame_id(cap_done_id),
                .fault(cap_fault),
                .fault_code(),
                .blocks_transferred(),
                .blocks_verified(cap_verified),
                .verify_retries(),
                .axi_awaddr(p_awaddr),
                .axi_awlen(p_awlen),
                .axi_awuser_id(p_awid),
                .axi_awuser_ap(p_awap),
                .axi_awvalid(p_awvalid),
                .axi_awready(w_ready[1]),
                .axi_wdata(p_wdata),
                .axi_wstrb(p_wstrb),
                .axi_wready(w_request[1]),
                .axi_wusero_id(axi_wusero_id),
                .axi_wusero_last(axi_wusero_last),
                .verify_araddr(v_araddr),
                .verify_arlen(v_arlen),
                .verify_aruser_id(v_arid),
                .verify_aruser_ap(v_arap),
                .verify_arvalid(v_arvalid),
                .verify_arready(r_ready[1]),
                .verify_rdata(axi_rdata),
                .verify_rid(axi_rid),
                .verify_rvalid(r_return[1]),
                .verify_rlast(axi_rlast));
    hdmi_frame_reader #(.PAN_ENABLE(PAN_ENABLE),                            // 锁定原图与矫正结果对，跨域预取像素并逐帧交替输出，嵌入类型和状态信息。
                        .TELEMETRY_ENABLE(GAMMA_ENABLE),
                        .DYNAMIC_MODE(DYNAMIC_MODE),
                        .WIDTH(OUT_WIDTH),
                        .HEIGHT(OUT_HEIGHT),
                        .RAW_WIDTH(WIDTH),
                        .RAW_HEIGHT(HEIGHT),
                        .A(A))
        display_reader(                                                     // 交替读取同一图像对的原图与矫正结果。
                .acquire_pan(acq_pan),
                .display_pan_seen(display_pan_seen),
                .display_pan(display_pan),
                .acquire_meta(acq_meta),
                .display_gamma_seen(display_gamma_seen),
                .display_gamma_enable(display_gamma_enable),
                .display_gamma_epoch(display_gamma_epoch),
                .mode1080(mode1080),
                .mode1080_pixel(mode1080_pixel),
                .clk(clk),
                .rst_n(rst_n),
                .pix_clk(pix_clk),
                .vsync(display_vsync),
                .de(display_de),
                .pixel(display_pixel),
                .pixel_de(display_pixel_de),
                .corrected_view(display_corrected),
                .acquire_valid(acq_valid),
                .acquire_ready(acq_ready),
                .acquire_slot(acq_slot),
                .acquire_base(acq_base),
                .acquire_raw_base(acq_raw_base),
                .acquire_id(acq_id),
                .release_valid(rel_valid),
                .release_ready(rel_ready),
                .release_slot(rel_slot),
                .release_id(rel_id),
                .araddr(d_araddr),
                .arlen(d_arlen),
                .arid(d_arid),
                .arap(d_arap),
                .arvalid(d_arvalid),
                .arready(r_ready[2]),
                .rdata(axi_rdata),
                .rid(axi_rid),
                .rvalid(r_return[2]),
                .rlast(axi_rlast),
                .fault(display_fault),
                .underflow(display_underflow));
    ddr_board_arbiter #(.A(A),                                              // 板级 DDR 仲裁：锁存读写事务归属，将返回数据路由到对应请求方并检查事务标签。
                        .QUIESCE_ENABLE(DYNAMIC_MODE))
        arbiter(                                                            // 共享原生 DDR 端口，保持突发事务的所有权。
                .quiesce(quiesce),
                .drained(drained),
                .clk(clk),
                .rst_n(rst_n),
                .r_addr({d_araddr, v_araddr, c_araddr}),
                .r_len({d_arlen, v_arlen, c_arlen}),
                .r_id({d_arid, v_arid, c_arid}),
                .r_valid({d_arvalid, v_arvalid, c_arvalid}),
                .r_ap({d_arap, v_arap, c_arap}),
                .r_ready(r_ready),
                .r_return_valid(r_return),
                .w_addr({p_awaddr, c_awaddr}),
                .w_len({p_awlen, c_awlen}),
                .w_id({p_awid, c_awid}),
                .w_valid({p_awvalid, c_awvalid}),
                .w_ap({p_awap, c_awap}),
                .w_ready(w_ready),
                .w_request(w_request),
                .w_data({p_wdata, c_wdata}),
                .w_strb({p_wstrb, c_wstrb}),
                .axi_araddr(axi_araddr),
                .axi_arlen(axi_arlen),
                .axi_aruser_id(axi_aruser_id),
                .axi_aruser_ap(axi_aruser_ap),
                .axi_arvalid(axi_arvalid),
                .axi_arready(axi_arready),
                .axi_awaddr(axi_awaddr),
                .axi_awlen(axi_awlen),
                .axi_awuser_id(axi_awuser_id),
                .axi_awuser_ap(axi_awuser_ap),
                .axi_awvalid(axi_awvalid),
                .axi_awready(axi_awready),
                .axi_rvalid(axi_rvalid),
                .axi_rid(axi_rid),
                .axi_rlast(axi_rlast),
                .axi_wready(axi_wready),
                .axi_wusero_id(axi_wusero_id),
                .axi_wusero_last(axi_wusero_last),
                .axi_wdata(axi_wdata),
                .axi_wstrb(axi_wstrb),
                .fault(board_fault));

    reg [$clog2(DISPLAY_WIDTH) - 1 : 0] output_x;
    reg [10 : 0]                        output_y;
    wire                                performance_output_de =
                                            display_pixel_de && (ALTERNATE_ENABLE ? display_corrected : (!SPLIT_ENABLE || output_x >= WIDTH));
    always @(posedge pix_clk or negedge pix_reset_sync[2]) begin
        if (!pix_reset_sync[2]) begin
            output_x <= 0;
            output_y <= 0;
        end else if (display_vsync) begin
            output_x <= 0;
            output_y <= 0;
        end else if (display_pixel_de) begin
            if (output_x == ((DYNAMIC_MODE &&  !mode1080_pixel) ? 1280 : DISPLAY_WIDTH) - 1) begin
                output_x <= 0;
                output_y <= output_y + 1'b1;
            end else
                output_x <= output_x + 1'b1;
        end
    end
    generate
        if (PERF_ENABLE) begin : performance
            wire [1023 : 0]           snapshot;
            wire                      arm_toggle;
            wire                      perf_reset = rst_n && (!PERF_DVP || perf_camera_initialized);
            video_performance_monitor monitor(                              // 被动统计处理耗时，不参与视频握手。
                                              .clk(clk),
                                              .rst_n(perf_reset),
                                              .initialized(init_done),
                                              .arm_toggle(arm_toggle),
                                              .cam_clk(PERF_DVP ? perf_dvp_clk : cam_clk),
                                              .cam_vsync(PERF_DVP ? perf_dvp_vsync : cam_vsync),
                                              .cam_de(PERF_DVP ? perf_dvp_href : cam_de),
                                              .cam_header_written(
                                                  PERF_DVP ? 1'b1 : (camera_valid && camera_ready && camera_data[17])),
                                              .pix_clk(pix_clk),
                                              .pix_vsync(display_vsync),
                                              .pix_output_de(performance_output_de),
                                              .raw_start(start),
                                              .raw_drop(!capturing && fifo_valid && fifo_ready && fifo_data[17]),
                                              .raw_done(cap_done_valid && cap_done_ready),
                                              .raw_id(cap_id),
                                              .process_start(processing_begin),
                                              .process_done(processing_finish),
                                              .process_start_id(processing_begin_id),
                                              .process_done_id(processing_finish_id),
                                              .acquire(acq_valid && acq_ready),
                                              .acquire_id(acq_id),
                                              .fault(fault),
                                              .underflow(display_underflow),
                                              .snapshot(snapshot));
            performance_jtag          debug_port(.clk(clk),                 // 性能诊断 JTAG 探针封装：供调试器读取快照，不参与像素运算。
                                                 .rst_n(perf_reset),
                                                 .snapshot(snapshot),
                                                 .arm_toggle(arm_toggle));
        end
    endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capturing         <= 0;
            capture_index     <= 0;
            capture_x         <= 0;
            previous_verified <= 0;
            capture_fault     <= 0;
            overflow_sync     <= 0;
        end else begin
            overflow_sync <= {overflow_sync[0], camera_overflow};
            if (start) begin                                                // 新采集帧启动时记录帧槽、DDR 基址及帧号，写回完成前不发布。
                capturing         <= 1;
                capture_index     <= 0;
                capture_x         <= 0;
                previous_verified <= 0;
            end else
                previous_verified <= cap_verified;
            if (pixel_fire) begin
                if (fifo_data[17] != (capture_index == 0) || fifo_data[16] != (capture_index == N - 1))
                    capture_fault <= 1;
                capture_index <= capture_index + 1'b1;
                if (capture_x == WIDTH - 1)
                    capture_x <= 0;
                else
                    capture_x <= capture_x + 1'b1;
            end
            if (cap_done_valid && cap_done_ready)
                capturing <= 0;
        end
    end
endmodule
