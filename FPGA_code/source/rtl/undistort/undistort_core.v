`timescale 1ns/1ps
 
 
module undistort_core                                                       // 整帧处理核心：锁定原帧、扫描输出坐标、逆映射取样，完成写回后发布结果及关联元数据。
    #(parameter PAN_ENABLE = 0, RUNTIME_CALIBRATION = 0, GAMMA_ENABLE = 0, DYNAMIC_MODE = 0, WIDTH = 1280, HEIGHT = 720,  // 源图每行像素数；源图有效行数；是否编入虚拟转向通路；是否编入 Gamma 查表通路；是否使用运行时标定参数；是否根据运行时模式选择输出尺寸。
                OUT_WIDTH = 1920, OUT_HEIGHT = 1080, ADDR_WIDTH = 28, SPLIT_ENABLE = 0)
    (input wire clk, rst_n, ddr_init_done, mode1080,                        // 处理时钟；低有效复位；DDR 初始化完成；1080P 模式选择。
     input wire [639 : 0] calibration,                                      // 当前帧使用的标定参数。
     input wire pan_request,                                                // 转向请求翻转标识。
     input wire signed [15 : 0] pan_angle,                                  // 转向角，单位 0.1 度。
     input wire [15 : 0] pan_sequence,                                      // 转向事务序号。
     output wire [33 : 0] acquire_pan,                                      // 与结果绑定的转向状态。
     input wire           gamma_enable, gamma_epoch,                        // 自适应 Gamma 开关；Gamma 状态代次。
     input wire [3 : 0] gamma_level,                                        // Gamma 档位。
     input wire [23 : 0] gamma_stats,                                       // 平均亮度、暗部及高亮比例。
     output wire [61 : 0]             acquire_meta,                         // 与结果绑定的运行状态信息。
     input wire                       capture_begin_valid, capture_line_valid, capture_end_valid,  // 申请新的原帧采集槽；一行有效像素接收完毕；当前相机帧结束。
     input wire [15 : 0]              capture_line_pixels,
     input wire                       writer_flushed, write_issue, write_retire,  // 写入端无残留像素数据；一笔 DDR 写事务已经发出；一笔 DDR 写事务已确认结束。
     output wire                      capture_begin_ready, capture_line_ready, capture_end_ready,  // 采集槽申请可被接受；可接收当前行的完成信息；可接收当前帧的结束信息。
     output wire [1 : 0]              capture_begin_slot,                   // 分配给采集端的原帧槽号。
     output wire [31 : 0]             capture_begin_base, capture_begin_frame_id,  // 新采集帧的 DDR 基址；新采集帧的递增帧号。
     input wire                       acquire_valid, acquire_reader,        // 读取端申请取得完整结果帧。
     output wire                      acquire_ready, acquire_slot,          // 完整结果及其引用可以分配；取得的结果槽号。
     output wire [31 : 0]             acquire_base, acquire_frame_id, acquire_raw_base,  // 取得的结果帧基址；取得结果所对应的帧号；该结果对应的原帧基址。
     input wire                       release_valid, release_reader, release_slot,  // 请求释放已有帧引用。
     output wire                      release_ready,                        // 该帧引用可以释放。
     input wire [31 : 0]              release_frame_id,
     output wire [ADDR_WIDTH - 1 : 0] axi_araddr, axi_awaddr,               // DDR 读字地址；DDR 写字地址。
     output wire [3 : 0] axi_arlen, axi_aruser_id, axi_awlen, axi_awuser_id,
     output wire         axi_aruser_ap, axi_arvalid, axi_awuser_ap, axi_awvalid,
     input wire          axi_arready, axi_awready,                          // DDR 接受读地址；DDR 接受写地址。
     input wire [255 : 0] axi_rdata,                                        // 原生 DDR 返回数据。
     input wire [3 : 0] axi_rid, axi_wusero_id,
     input wire         axi_rvalid, axi_rlast, axi_wready, axi_wusero_last,  // DDR 返回拍有效；当前突发最后一拍；原生 DDR 请求提供写数据；原生写数据末拍指示。
     output wire [255 : 0] axi_wdata,                                       // 原生 DDR 写数据。
     output wire [31 : 0] axi_wstrb,                                        // 原生 DDR 字节使能。
     output wire fault,                                                     // 锁存的故障标志。
     output wire [7 : 0] fault_code,                                        // 故障类型编码。
     output reg frame_completed,                                            // 结果提交脉冲。
     output reg [31 : 0] completed_frame_id,                                // 已完成处理的帧号。
     output wire [31 : 0] published_frames, line_loads, cache_hits, blocks_verified, verify_retries,
     output wire          processing_begin, processing_finish,              // 矫正处理起始事件；矫正结果写入完成事件。
     output wire [31 : 0] processing_begin_id, processing_finish_id         // 开始处理的原图帧号；完成处理的原图帧号。
    );
    wire [31 : 0]        N            = (DYNAMIC_MODE &&  !mode1080)
                                            ? 32'd921600
                                            : OUT_WIDTH * OUT_HEIGHT;       // 按模式选择输出像素总数，不改变输入摄像头尺寸。
    wire [10 : 0]        output_width = (DYNAMIC_MODE &&  !mode1080) ? 11'd1280 : OUT_WIDTH;
    wire                 reclaim_valid, reclaim_slot;
    reg [1 : 0]          pair_raw_slot[0 : 1];
    reg [61 : 0]         pair_meta[0 : 1];
    reg [33 : 0]         pair_pan[0 : 1], frame_pan;
    assign               acquire_pan = pair_pan[acquire_slot];              // 取得结果时同时返回该结果锁定的角度、序号及代际信息。
    wire                 pan_table_ready, pan_next_epoch;
    wire signed [15 : 0] pan_next_angle;
    wire [15 : 0]        pan_next_sequence;
    wire          pan_enabled = PAN_ENABLE &&  !mode1080 && calibration[0];  // 仅有效标定下的 720P 矫正分支启用虚拟转向。
    wire          geometry_ready =  !pan_enabled || pan_table_ready;
    reg           frame_gamma, frame_epoch;
    reg [3 : 0]   frame_level;
    reg [23 : 0]  frame_stats;
    reg [31 : 0]  process_cycles;
    assign        acquire_meta = pair_meta[acquire_slot];
    reg [31 : 0]  pair_raw_base[0 : 1], pair_frame_id[0 : 1];
    assign        acquire_raw_base = pair_raw_base[acquire_slot];           // 显示原图使用与当前结果同一输入帧的基址，避免前后帧错配。
    wire          raw_fault, result_fault, cache_fault, reader_fault, writer_fault, arb_fault;
    wire          split_fault;
    wire [3 : 0]  raw_code, result_code, reader_code, writer_code, arb_code;
    assign        fault      = raw_fault || result_fault || cache_fault || reader_fault || writer_fault || arb_fault ||  // 任一关键模块故障都会阻止继续处理和发布不完整结果。
                               split_fault;                                 // 任一子模块故障都会阻止继续发布结果。
    assign        fault_code = raw_fault ? {4'h1, raw_code}
                               : result_fault ? {4'h2, result_code}
                               : cache_fault ? 8'h30
                               : reader_fault ? {4'h4, reader_code}
                               : writer_fault ? {4'h5, writer_code}
                               : arb_fault ? {4'h6, arb_code}
                               : split_fault ? 8'h70
                                              : 8'd0;
    reg           active, locked_result_slot;
    reg [1 : 0]   locked_raw_slot;
    reg [31 : 0]  locked_raw_base, locked_frame_id, index;
    reg [10 : 0]  u;
    reg [10 : 0]  v;
    wire          raw_begin_ready, raw_line_ready, raw_end_ready, raw_valid, raw_ready, raw_release_ready;
    wire [1 : 0]  raw_slot;
    wire [31 : 0] raw_base, raw_id;
    wire          result_write_ready, result_write_slot, result_commit_ready, writer_start_ready, writer_done_valid,
                  writer_done_ready;
    wire          result_acquire_ready, result_release_ready;
    wire [31 : 0] result_write_base, writer_done_id, writer_done_base;
    wire          can_start =  !active &&  !fault && ddr_init_done && writer_start_ready && result_write_ready &&
                              geometry_ready;                               // 原图、结果槽、DDR 及几何表全部就绪后才开始。
    wire          start     = raw_valid && can_start;
    reg           composing;
    reg [31 : 0]  locked_temp_base, locked_output_base;
    wire          split_start_ready, split_done_valid, split_done_ready;
    wire [31 : 0] split_done_id;
    wire          completed_valid     = SPLIT_ENABLE ? split_done_valid : writer_done_valid;
    wire [31 : 0] completed_id        = SPLIT_ENABLE ? split_done_id : writer_done_id;
    wire          finish              = completed_valid && active &&  !fault && result_commit_ready && raw_release_ready;
    wire          normal_done         = writer_done_valid && writer_done_ready;
    assign        split_done_ready    = active &&  !fault && result_commit_ready && raw_release_ready;  // 可选拼接通路也必须等结果提交和原帧释放均可完成才结束。
    assign        processing_begin    = start;                              // 性能计数从接受完整原帧并启动处理这一拍开始。
    assign        processing_finish   = normal_done;
    assign        processing_begin_id = raw_id;
    assign        processing_finish_id = locked_frame_id;
    assign        raw_ready            = can_start;
    assign        writer_done_ready =
                      active &&  !fault &&
                      (SPLIT_ENABLE ? (!composing && split_start_ready) : (result_commit_ready && raw_release_ready));
    assign        capture_begin_ready = raw_begin_ready &&  !fault;
    assign        capture_line_ready  = raw_line_ready &&  !fault;
    assign        capture_end_ready   = raw_end_ready &&  !fault;
    assign        acquire_ready       = result_acquire_ready &&  !fault;
    assign        release_ready       = result_release_ready &&  !fault;
    raw_frame_manager #(.WIDTH(WIDTH),                                      // 原帧三槽所有权管理：收齐图像并确认待写事务结束后，才把帧交给处理端。
                        .HEIGHT(HEIGHT),
                        .SLOTS(4),
                        .STRIDE_WORD(32'h00200000))
        raw_frames(.clk(clk),
                   .rst_n(rst_n),
                   .capture_begin_valid(capture_begin_valid &&  !fault),
                   .capture_begin_ready(raw_begin_ready),
                   .capture_begin_slot(capture_begin_slot),
                   .capture_begin_base(capture_begin_base),
                   .capture_begin_frame_id(capture_begin_frame_id),
                   .capture_line_valid(capture_line_valid &&  !fault),
                   .capture_line_pixels(capture_line_pixels),
                   .capture_line_ready(raw_line_ready),
                   .capture_end_valid(capture_end_valid &&  !fault),
                   .capture_end_ready(raw_end_ready),
                   .writer_flushed(writer_flushed &&  !fault),
                   .write_issue(write_issue &&  !fault),
                   .write_retire(write_retire &&  !fault),
                   .process_valid(raw_valid),
                   .process_ready(raw_ready),
                   .process_slot(raw_slot),
                   .process_base(raw_base),
                   .process_frame_id(raw_id),
                   .release_valid(reclaim_valid),
                   .release_ready(raw_release_ready),
                   .release_slot(pair_raw_slot[reclaim_slot]),
                   .release_frame_id(pair_frame_id[reclaim_slot]),
                   .fault(raw_fault),
                   .fault_code(raw_code),
                   .published_frames(),
                   .dropped_frames(),
                   .slot_states(),
                   .pending_writes());
    corrected_frame_manager #(.BASE_WORD(SPLIT_ENABLE ? 32'h00d00000 : 32'h00c00000))  // 双结果槽所有权管理：完整结果提交后发布，被显示引用的槽不得重新分配写入。
         results(.clk(clk),
                 .rst_n(rst_n),
                 .write_begin_valid(raw_valid &&  !active &&  !fault && ddr_init_done && writer_start_ready &&
                                    geometry_ready),
                 .write_begin_ready(result_write_ready),
                 .write_begin_frame_id(raw_id),
                 .write_begin_slot(result_write_slot),
                 .write_begin_base(result_write_base),
                 .commit_valid(completed_valid && active &&  !fault && raw_release_ready),
                 .commit_ready(result_commit_ready),
                 .commit_slot(locked_result_slot),
                 .commit_frame_id(completed_id),
                 .acquire_valid(acquire_valid &&  !fault),
                 .acquire_reader(acquire_reader),
                 .acquire_ready(result_acquire_ready),
                 .acquire_slot(acquire_slot),
                 .acquire_base(acquire_base),
                 .acquire_frame_id(acquire_frame_id),
                 .release_valid(release_valid &&  !fault),
                 .release_reader(release_reader),
                 .release_slot(release_slot),
                 .release_ready(result_release_ready),
                 .release_frame_id(release_frame_id),
                 .fault(result_fault),
                 .fault_code(result_code),
                 .reclaim_valid(reclaim_valid),
                 .reclaim_slot(reclaim_slot),
                 .slot_states(),
                 .reader_refs(),
                 .published_frames(published_frames));
    wire map_ready, map_valid, xy_ready;
    wire signed [23 : 0] sx, sy;
    wire [31 : 0]        map_tag;
    wire                 ray_valid, ray_ready;
    wire [10 : 0]        ray_u, ray_v;
    wire [31 : 0]        ray_tag;
    wire signed [31 : 0] ray_x, ray_y;
    wire                 input_valid = active && index < N &&  !fault && ddr_init_done;
    wire                 mapping_ready;
    generate
        if (PAN_ENABLE) begin : virtual_camera                              // 仅启用转向的配置实例化列预计算与射线归一化通路。
            wire [63 : 0]    table_value;
            wire             table_read;
            wire [10 : 0]    table_column;
            pan_column_table columns(.clk(clk),                             // 按列预计算转向射线：后台生成备用表，整张表完成后仅在处理帧边界切换。
                                     .rst_n(rst_n),
                                     .request(pan_request),
                                     .angle_tenths(pan_angle),              // 按角度生成列参数表，并在处理帧起始时提交。
                                     .sequence_id(pan_sequence),
                                     .frame_start(start),
                                     .read_column(table_column),
                                     .read_enable(table_read),
                                     .read_value(table_value),
                                     .ready(pan_table_ready),
                                     .next_angle(pan_next_angle),
                                     .next_sequence(pan_next_sequence),
                                     .next_epoch(pan_next_epoch),
                                     .active_epoch(),
                                     .active_angle(),
                                     .active_sequence(),
                                     .busy());
            pan_normalizer   normalize(.clk(clk),                           // 复用列参数计算转向后的归一化坐标；列查表、行坐标、标签按同一节拍对齐。
                                       .rst_n(rst_n),
                                       .in_valid(input_valid && pan_enabled),  // 输出虚拟相机旋转射线，供真实镜头模型投影。
                                       .in_ready(ray_ready),
                                       .u(u),
                                       .v(v),
                                       .in_tag(index),
                                       .read_enable(table_read),
                                       .read_column(table_column),
                                       .read_value(table_value),
                                       .out_valid(ray_valid),
                                       .out_ready(mapping_ready && pan_enabled),
                                       .norm_x(ray_x),
                                       .norm_y(ray_y),
                                       .out_u(ray_u),
                                       .out_v(ray_v),
                                       .out_tag(ray_tag));
        end else begin : no_virtual_camera
            assign pan_table_ready   = 1;
            assign pan_next_epoch    = 0;
            assign pan_next_angle    = 0;
            assign pan_next_sequence = 0;
            assign ray_valid         = 0;
            assign ray_ready         = 0;
            assign ray_u             = 0;
            assign ray_v             = 0;
            assign ray_tag           = 0;
            assign ray_x             = 0;
            assign ray_y             = 0;
        end
    endgenerate
    assign xy_ready = pan_enabled ? ray_ready : mapping_ready;              // 启用转向时先等射线通路，否则直接等待 Brown 映射器。
    generate
        if (RUNTIME_CALIBRATION) begin : runtime_geometry
            distort_map_runtime #(.EXTERNAL_NORMALIZATION(PAN_ENABLE))      // 运行时 Brown4 逆映射：26 级定点流水，支持外部转向射线和几何直通旁路。
                mapping(.calibration(calibration),
                        .out_overflow(),                                    // 将输出像素反向映射到原图坐标，合并矫正与转向。
                        .use_external(pan_enabled),
                        .normalized_x(ray_x),
                        .normalized_y(ray_y),
                        .mode1080(mode1080),
                        .clk(clk),
                        .rst_n(rst_n),
                        .in_valid(pan_enabled ? ray_valid : input_valid),
                        .in_ready(mapping_ready),
                        .u(pan_enabled ? ray_u : u),
                        .v(pan_enabled ? ray_v : v),
                        .in_tag(pan_enabled ? ray_tag : index),
                        .out_valid(map_valid),
                        .out_ready(map_ready),
                        .source_x_q12(sx),
                        .source_y_q12(sy),
                        .out_tag(map_tag));
        end else begin : fixed_geometry
            distort_map_fixed #(.DYNAMIC_MODE(DYNAMIC_MODE))                // 固定参数 Brown 映射器：保留兼容参数化实现，输出原图采样坐标及像素标签。
                mapping(.mode1080(mode1080),
                        .clk(clk),
                        .rst_n(rst_n),
                        .in_valid(active && index < N &&  !fault && ddr_init_done),
                        .in_ready(mapping_ready),
                        .u(u),
                        .v(v),
                        .in_tag(index),
                        .out_valid(map_valid),
                        .out_ready(map_ready),
                        .source_x_q12(sx),
                        .source_y_q12(sy),
                        .out_tag(map_tag));
        end
    endgenerate
    wire signed [27 : 0] x8 = ($signed({{4{sx[23]}}, sx}) + 28'sd8) >>> 4;
    wire signed [27 : 0] y8 = ($signed({{4{sy[23]}}, sy}) + 28'sd8) >>> 4;
    wire signed [27 : 0] x0 = x8 >>> 8, y0 = y8 >>> 8;

    wire                cache_query_ready;
    reg                 coord_valid;
    reg signed [15 : 0] coord_x, coord_y;
    reg [7 : 0]         coord_fx, coord_fy;
    reg [31 : 0]        coord_tag;
    assign              map_ready = rst_n && ddr_init_done &&  !fault && (!coord_valid || cache_query_ready);  // 映射结果采用一级弹性缓冲，源行缓存未接收时保持整数坐标及小数。
    always @(posedge clk) begin
        if (!rst_n) begin
            coord_valid <= 0;
            coord_x     <= 0;
            coord_y     <= 0;
            coord_fx    <= 0;
            coord_fy    <= 0;
            coord_tag   <= 0;
        end else if (map_ready) begin
            coord_valid <= map_valid;
            if (map_valid) begin
                coord_x   <= x0[15 : 0];
                coord_y   <= y0[15 : 0];
                coord_fx  <= x8[7 : 0];
                coord_fy  <= y8[7 : 0];
                coord_tag <= map_tag;
            end
        end
    end
    wire           sample_valid, sample_ready;
    wire [15 : 0]  p00, p10, p01, p11;
    wire [3 : 0]   mask;
    wire [7 : 0]   frac_x, frac_y;
    wire [31 : 0]  sample_tag;
    wire           line_command, line_ready, line_return_valid, line_return_last;
    wire [31 : 0]  line_address;
    wire [15 : 0]  line_beats;
    wire [255 : 0] line_data;

    source_line_cache #(.WIDTH(WIDTH),                                      // 源图行缓存：核对帧号、基址及行标签，命中直接取四邻点，缺行则从 DDR 装载。
                        .HEIGHT(HEIGHT),
                        .CACHE_LINES(112))
                              cache(                                        // 源图行缓存，返回四邻点和有效掩码。
                                      .clk(clk),
                                      .rst_n(rst_n),
                                      .query_valid(coord_valid &&  !fault),
                                      .query_ready(cache_query_ready),
                                      .query_x(coord_x),
                                      .query_y(coord_y),
                                      .query_frac_x(coord_fx),
                                      .query_frac_y(coord_fy),
                                      .query_frame_id(locked_frame_id),
                                      .query_base_word(locked_raw_base),
                                      .query_tag(coord_tag),
                                      .response_valid(sample_valid),
                                      .response_ready(sample_ready),
                                      .p00(p00),
                                      .p10(p10),
                                      .p01(p01),
                                      .p11(p11),
                                      .tap_valid(mask),
                                      .frac_x(frac_x),
                                      .frac_y(frac_y),
                                      .response_tag(sample_tag),
                                      .command_valid(line_command),
                                      .command_ready(line_ready),
                                      .command_word_addr(line_address),
                                      .command_beats(line_beats),
                                      .return_valid(line_return_valid),
                                      .return_data(line_data),
                                      .return_last(line_return_last),
                                      .fault(cache_fault),
                                      .hit_queries(cache_hits),
                                      .line_loads(line_loads));
    wire [ADDR_WIDTH - 1 : 0] c_araddr, v_araddr, w_awaddr;
    wire [3 : 0]              c_arlen, v_arlen, w_awlen, c_rid, v_rid, w_id;
    wire                      c_arap, v_arap, w_awap, c_arvalid, v_arvalid, w_awvalid, c_arready, v_arready, w_awready;
    wire                      c_rvalid, v_rvalid, c_rlast, v_rlast, w_ready, w_last;
    wire [255 : 0]            c_rdata, v_rdata, w_data;
    wire [31 : 0]             w_strb;
    ddr_line_reader #(.ADDR_WIDTH(ADDR_WIDTH))                              // 源图行读取：把一行请求拆成符合突发长度及边界要求的 DDR 事务，并核对返回标签。
                  source_reader(.clk(clk),
                                .rst_n(rst_n),
                                .ddr_init_done(ddr_init_done),
                                .command_valid(line_command &&  !fault),
                                .command_ready(line_ready),
                                .command_word_addr(line_address),
                                .command_beats(line_beats),
                                .return_valid(line_return_valid),
                                .return_data(line_data),
                                .return_last(line_return_last),
                                .line_done(),
                                .busy(),
                                .fault(reader_fault),
                                .fault_code(reader_code),
                                .axi_araddr(c_araddr),
                                .axi_arlen(c_arlen),
                                .axi_aruser_id(),
                                .axi_aruser_ap(c_arap),
                                .axi_arvalid(c_arvalid),
                                .axi_arready(c_arready),
                                .axi_rdata(c_rdata),
                                .axi_rid(c_rid),
                                .axi_rvalid(c_rvalid),
                                .axi_rlast(c_rlast));
    wire          pixel_valid, pixel_ready;
    wire [15 : 0] pixel;
    wire [31 : 0] pixel_tag;
    wire          gamma_valid, gamma_ready;
    wire [15 : 0] g00, g10, g01, g11;
    wire [3 : 0]  gmask;
    wire [7 : 0]  gfx, gfy;
    wire [31 : 0] gtag;
    generate
        if (GAMMA_ENABLE) begin : enhancement
            gamma_taps gamma(.clk(clk),                                     // 先对四邻点做 Gamma，再进行一次双线性插值；原图分支不经过此查表。
                             .rst_n(rst_n),
                             .enable(frame_gamma),
                             .level(frame_level),                           // 在邻点插值之前施加已锁定的 Gamma 档位。
                             .in_valid(sample_valid &&  !fault),
                             .in_ready(sample_ready),
                             .out_ready(gamma_ready),
                             .out_valid(gamma_valid),
                             .p00(p00),
                             .p10(p10),
                             .p01(p01),
                             .p11(p11),
                             .mask(mask),
                             .fx(frac_x),
                             .fy(frac_y),
                             .tag(sample_tag),
                             .q00(g00),
                             .q10(g10),
                             .q01(g01),
                             .q11(g11),
                             .out_mask(gmask),
                             .out_fx(gfx),
                             .out_fy(gfy),
                             .out_tag(gtag));
        end else begin : no_enhancement
            assign gamma_valid  = sample_valid;
            assign sample_ready = gamma_ready;
            assign g00          = p00;
            assign g10          = p10;
            assign g01          = p01;
            assign g11          = p11;
            assign gmask        = mask;
            assign gfx          = frac_x;
            assign gfy          = frac_y;
            assign gtag         = sample_tag;
        end
    endgenerate
    bilinear_rgb565 interpolation(.clk(clk),                                // 四邻域双线性插值：RGB565 三通道独立加权、舍入，标签与有效位同步保持。
                                  .rst_n(rst_n),
                                  .in_valid(gamma_valid &&  !fault),
                                  .in_ready(gamma_ready),                   // 四点双线性插值，整个几何链只重采样一次。
                                  .frac_x(gfx),
                                  .frac_y(gfy),
                                  .p00(g00),
                                  .p10(g10),
                                  .p01(g01),
                                  .p11(g11),
                                  .tap_valid(gmask),
                                  .in_tag(gtag),
                                  .out_valid(pixel_valid),
                                  .out_ready(pixel_ready),
                                  .out_pixel(pixel),
                                  .out_tag(pixel_tag));
    corrected_frame_writer #(.DYNAMIC_MODE(DYNAMIC_MODE),                   // 结果写帧器：将 RGB565 打包为 DDR 宽字，写后读回验证，通过后才提交整帧。
                             .WIDTH(OUT_WIDTH),
                             .HEIGHT(OUT_HEIGHT),
                             .ADDR_WIDTH(ADDR_WIDTH))
        writer(.mode1080(mode1080),
               .clk(clk),
               .rst_n(rst_n),
               .ddr_init_done(ddr_init_done),
               .frame_start_valid(raw_valid &&  !active &&  !fault && ddr_init_done && result_write_ready &&
                                  geometry_ready),
               .frame_start_ready(writer_start_ready),
               .frame_base_word(SPLIT_ENABLE ? (32'h00c00000 + (result_write_slot ? 32'h00400000 : 32'd0))
                                             : result_write_base),
               .frame_id(raw_id),
               .pixel_valid(pixel_valid && active &&  !fault),
               .pixel_ready(pixel_ready),
               .pixel(pixel),
               .pixel_index(pixel_tag),
               .pixel_last(pixel_tag == N - 1),
               .frame_done_valid(writer_done_valid),
               .frame_done_ready(writer_done_ready),
               .done_base_word(writer_done_base),
               .done_frame_id(writer_done_id),
               .fault(writer_fault),
               .fault_code(writer_code),
               .blocks_transferred(),
               .blocks_verified(blocks_verified),
               .verify_retries(verify_retries),
               .axi_awaddr(w_awaddr),
               .axi_awlen(w_awlen),
               .axi_awuser_id(),
               .axi_awuser_ap(w_awap),
               .axi_awvalid(w_awvalid),
               .axi_awready(w_awready),
               .axi_wdata(w_data),
               .axi_wstrb(w_strb),
               .axi_wready(w_ready),
               .axi_wusero_id(w_id),
               .axi_wusero_last(w_last),
               .verify_araddr(v_araddr),
               .verify_arlen(v_arlen),
               .verify_aruser_id(),
               .verify_aruser_ap(v_arap),
               .verify_arvalid(v_arvalid),
               .verify_arready(v_arready),
               .verify_rdata(v_rdata),
               .verify_rid(v_rid),
               .verify_rvalid(v_rvalid),
               .verify_rlast(v_rlast));
    wire [ADDR_WIDTH - 1 : 0] normal_araddr, normal_awaddr, split_araddr, split_awaddr;
    wire [3 : 0]              normal_arlen, normal_aruser_id, normal_awlen, normal_awuser_id;
    wire [3 : 0]              split_arlen, split_aruser_id, split_awlen, split_awuser_id;
    wire                      normal_aruser_ap, normal_arvalid, normal_awuser_ap, normal_awvalid;
    wire                      split_aruser_ap, split_arvalid, split_awuser_ap, split_awvalid;
    wire                      normal_arready = axi_arready &&  !composing;
    wire                      normal_awready = axi_awready &&  !composing;
    wire [255 : 0]            normal_rdata   = axi_rdata;
    wire [255 : 0]            normal_wdata, split_wdata;
    wire [3 : 0]              normal_rid = axi_rid, normal_wusero_id = axi_wusero_id;
    wire                      normal_rvalid = axi_rvalid &&  !composing, normal_rlast = axi_rlast;
    wire                      normal_wready = axi_wready &&  !composing, normal_wusero_last = axi_wusero_last;
    wire [31 : 0]             normal_wstrb, split_wstrb;

    ddr_correction_arbiter #(.ADDR_WIDTH(ADDR_WIDTH))                       // 处理侧 DDR 仲裁：在源图读取和结果核验之间分配读端口，独立管理结果写事务。
           arbiter(.clk(clk),
                   .rst_n(rst_n),
                   .ddr_init_done(ddr_init_done),
                   .c_araddr(c_araddr),
                   .c_arlen(c_arlen),
                   .c_arap(c_arap),
                   .c_arvalid(c_arvalid),
                   .c_arready(c_arready),
                   .c_rdata(c_rdata),
                   .c_rid(c_rid),
                   .c_rvalid(c_rvalid),
                   .c_rlast(c_rlast),
                   .v_araddr(v_araddr),
                   .v_arlen(v_arlen),
                   .v_arap(v_arap),
                   .v_arvalid(v_arvalid),
                   .v_arready(v_arready),
                   .v_rdata(v_rdata),
                   .v_rid(v_rid),
                   .v_rvalid(v_rvalid),
                   .v_rlast(v_rlast),
                   .w_awaddr(w_awaddr),
                   .w_awlen(w_awlen),
                   .w_awap(w_awap),
                   .w_awvalid(w_awvalid),
                   .w_awready(w_awready),
                   .w_data(w_data),
                   .w_strb(w_strb),
                   .w_ready(w_ready),
                   .w_last(w_last),
                   .w_id(w_id),
                   .axi_araddr(normal_araddr),
                   .axi_arlen(normal_arlen),
                   .axi_aruser_id(normal_aruser_id),
                   .axi_aruser_ap(normal_aruser_ap),
                   .axi_arvalid(normal_arvalid),
                   .axi_arready(normal_arready),
                   .axi_awaddr(normal_awaddr),
                   .axi_awlen(normal_awlen),
                   .axi_awuser_id(normal_awuser_id),
                   .axi_awuser_ap(normal_awuser_ap),
                   .axi_awvalid(normal_awvalid),
                   .axi_awready(normal_awready),
                   .axi_rdata(normal_rdata),
                   .axi_rid(normal_rid),
                   .axi_rvalid(normal_rvalid),
                   .axi_rlast(normal_rlast),
                   .axi_wready(normal_wready),
                   .axi_wusero_id(normal_wusero_id),
                   .axi_wusero_last(normal_wusero_last),
                   .axi_wdata(normal_wdata),
                   .axi_wstrb(normal_wstrb),
                   .fault(arb_fault),
                   .fault_code(arb_code));
    assign axi_araddr    = composing ? split_araddr : normal_araddr;
    assign axi_awaddr    = composing ? split_awaddr : normal_awaddr;
    assign axi_arlen     = composing ? split_arlen : normal_arlen;
    assign axi_aruser_id = composing ? split_aruser_id : normal_aruser_id;
    assign axi_awlen     = composing ? split_awlen : normal_awlen;
    assign axi_awuser_id = composing ? split_awuser_id : normal_awuser_id;
    assign axi_aruser_ap = composing ? split_aruser_ap : normal_aruser_ap;
    assign axi_arvalid   = composing ? split_arvalid : normal_arvalid;
    assign axi_awuser_ap = composing ? split_awuser_ap : normal_awuser_ap;
    assign axi_awvalid   = composing ? split_awvalid : normal_awvalid;
    assign axi_wdata     = composing ? split_wdata : normal_wdata;
    assign axi_wstrb     = composing ? split_wstrb : normal_wstrb;
    generate
        if (SPLIT_ENABLE) begin : comparison
            split_frame_composer #(.WIDTH(WIDTH),                           // 可选左右拼接通路：依次读原图与结果行，合成为两倍宽的 RGB565 输出帧。
                                   .HEIGHT(HEIGHT),
                                   .ADDR_WIDTH(ADDR_WIDTH))
                composer(.clk(clk),
                         .rst_n(rst_n),
                         .ddr_init_done(ddr_init_done),
                         .start_valid(writer_done_valid && active &&  !composing &&  !fault),
                         .start_ready(split_start_ready),
                         .raw_base(locked_raw_base),
                         .corrected_base(locked_temp_base),
                         .output_base(locked_output_base),
                         .frame_id(locked_frame_id),
                         .done_valid(split_done_valid),
                         .done_ready(split_done_ready),
                         .done_id(split_done_id),
                         .fault(split_fault),
                         .axi_araddr(split_araddr),
                         .axi_arlen(split_arlen),
                         .axi_aruser_id(split_aruser_id),
                         .axi_aruser_ap(split_aruser_ap),
                         .axi_arvalid(split_arvalid),
                         .axi_arready(axi_arready && composing),
                         .axi_awaddr(split_awaddr),
                         .axi_awlen(split_awlen),
                         .axi_awuser_id(split_awuser_id),
                         .axi_awuser_ap(split_awuser_ap),
                         .axi_awvalid(split_awvalid),
                         .axi_awready(axi_awready && composing),
                         .axi_rdata(axi_rdata),
                         .axi_rid(axi_rid),
                         .axi_rvalid(axi_rvalid && composing),
                         .axi_rlast(axi_rlast),
                         .axi_wready(axi_wready && composing),
                         .axi_wusero_id(axi_wusero_id),
                         .axi_wusero_last(axi_wusero_last),
                         .axi_wdata(split_wdata),
                         .axi_wstrb(split_wstrb));
        end else begin : no_comparison
            assign split_start_ready = 1'b0;
            assign split_done_valid  = 1'b0;
            assign split_done_id     = 32'd0;
            assign split_fault       = 1'b0;
            assign split_araddr      = 0;
            assign split_awaddr      = 0;
            assign split_arlen       = 0;
            assign split_aruser_id   = 0;
            assign split_awlen       = 0;
            assign split_awuser_id   = 0;
            assign split_aruser_ap   = 0;
            assign split_arvalid     = 0;
            assign split_awuser_ap   = 0;
            assign split_awvalid     = 0;
            assign split_wdata       = 0;
            assign split_wstrb       = 0;
        end
    endgenerate
    always @(posedge clk) begin
        if (!rst_n) begin
            pair_pan[0]        <= 0;
            pair_pan[1]        <= 0;
            frame_pan          <= 0;
            active             <= 0;
            composing          <= 0;
            frame_gamma        <= 0;
            frame_epoch        <= 0;
            frame_level        <= 4;
            frame_stats        <= 0;
            process_cycles     <= 0;
            pair_meta[0]       <= 0;
            pair_meta[1]       <= 0;
            locked_temp_base   <= 0;
            locked_output_base <= 0;
            locked_raw_slot    <= 0;
            locked_result_slot <= 0;
            locked_raw_base    <= 0;
            locked_frame_id    <= 0;
            pair_raw_slot[0]   <= 0;
            pair_raw_slot[1]   <= 0;
            pair_raw_base[0]   <= 0;
            pair_raw_base[1]   <= 0;
            pair_frame_id[0]   <= 0;
            pair_frame_id[1]   <= 0;
            index              <= 0;
            u                  <= 0;
            v                  <= 0;
            frame_completed    <= 0;
            completed_frame_id <= 0;
        end else begin
            frame_completed <= 0;
            if (active)
                process_cycles <= process_cycles + 1'b1;
            if (start) begin                                                // 帧开始时统一锁定基址、标定、Gamma 和转向信息，本帧中途不混用新参数。
                frame_pan      <= {pan_enabled, pan_next_epoch, pan_next_sequence, pan_next_angle};
                frame_gamma    <= GAMMA_ENABLE && gamma_enable;
                frame_epoch    <= GAMMA_ENABLE && gamma_epoch;              // 每帧开始时锁定 Gamma 开关，避免同帧前后不同。
                frame_level    <= GAMMA_ENABLE ? gamma_level : 4;
                frame_stats    <= GAMMA_ENABLE ? gamma_stats : 0;
                process_cycles <= 0;                                        // 本帧使用同一 Gamma 档位及统计快照。
                pair_raw_slot[result_write_slot] <= raw_slot;
                pair_raw_base[result_write_slot] <= raw_base;
                pair_frame_id[result_write_slot] <= raw_id;
                active                           <= 1;
                composing                        <= 0;
                locked_temp_base                 <= 32'h00c00000 + (result_write_slot ? 32'h00400000 : 32'd0);
                locked_output_base               <= result_write_base;
                locked_raw_slot                  <= raw_slot;
                locked_raw_base                  <= raw_base;
                locked_frame_id                  <= raw_id;
                locked_result_slot               <= result_write_slot;
                index                            <= 0;
                u                                <= 0;
                v                                <= 0;
            end
            if (active && index < N &&  !fault && ddr_init_done && xy_ready) begin  // 只有坐标下游允许接收时才推进扫描索引，暂停不会跳过输出像素。
                index <= index + 1'b1;
                if (u == output_width - 1) begin
                    u <= 0;
                    v <= v + 1'b1;
                end else
                    u <= u + 1'b1;
            end
            if (SPLIT_ENABLE && normal_done)
                composing <= 1;
            if (finish) begin
                pair_pan[locked_result_slot] <= frame_pan;
                pair_meta[locked_result_slot] <=
                    {frame_epoch, frame_gamma, frame_level, frame_stats, process_cycles + 32'd1};
                composing          <= 0;
                active             <= 0;
                frame_completed    <= 1;
                completed_frame_id <= locked_frame_id;
            end
        end
    end
endmodule
