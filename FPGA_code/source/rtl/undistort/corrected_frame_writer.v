`timescale 1ns/1ps
 
 
 
module corrected_frame_writer                                               // 结果写帧器：将 RGB565 打包为 DDR 宽字，写后读回验证，通过后才提交整帧。
    #(                                                                      // 整块写入 DDR，再读回核验，通过后才发布。
      parameter         DYNAMIC_MODE = 0, WIDTH = 1280, HEIGHT = 720, ADDR_WIDTH = 28,  // 源图每行像素数；源图有效行数；是否根据运行时模式选择输出尺寸；DDR 地址位宽。
      parameter [3 : 0] WRITE_ID = 4'h9, VERIFY_ID = 4'h9,
      parameter         MAX_VERIFY_TRIES = 4, WATCHDOG_CYCLES = 4096)       // 无进展看门狗周期上限；结果读回核验的重试上限。
    (input wire clk, rst_n, ddr_init_done, mode1080,                        // 处理时钟；低有效复位；DDR 初始化完成；1080P 模式选择。
     input wire          frame_start_valid,                                 // 开始一帧结果写入。
     output wire         frame_start_ready,                                 // 写帧器可以接受新的帧上下文。
     input wire [31 : 0] frame_base_word, frame_id,                         // 本次事务关联的图像帧号。
     input wire          pixel_valid,                                       // 像素有效。
     output wire pixel_ready,                                               // 接收端可接受像素。
     input wire [15 : 0] pixel,                                             // RGB565 像素。
     input wire [31 : 0] pixel_index,
     input wire          pixel_last,
     output wire         frame_done_valid,                                  // 整帧写回核验完成。
     input wire          frame_done_ready,                                  // 上层可以接收完整帧提交。
     output reg [31 : 0] done_base_word, done_frame_id,
     output reg          fault,                                             // 锁存的故障标志。
     output reg [3 : 0] fault_code,                                         // 故障类型编码。
     output reg [31 : 0]              blocks_transferred, blocks_verified, verify_retries,
     output wire [ADDR_WIDTH - 1 : 0] axi_awaddr,                           // DDR 写字地址。
     output wire [3 : 0] axi_awuser_id, axi_awlen,
     output wire         axi_awuser_ap, axi_awvalid,
     input wire          axi_awready,                                       // DDR 接受写地址。
     output wire [255 : 0] axi_wdata,                                       // 原生 DDR 写数据。
     output wire [31 : 0] axi_wstrb,                                        // 原生 DDR 字节使能。
     input wire axi_wready, axi_wusero_last,                                // 原生 DDR 请求提供写数据；原生写数据末拍指示。
     input wire [3 : 0]               axi_wusero_id,
     output wire [ADDR_WIDTH - 1 : 0] verify_araddr,
     output wire [3 : 0]              verify_aruser_id, verify_arlen,
     output wire                      verify_aruser_ap, verify_arvalid,
     input wire                       verify_arready,
     input wire [255 : 0]             verify_rdata,
     input wire [3 : 0]               verify_rid,
     input wire                       verify_rlast, verify_rvalid);
    localparam    MAX_PIXELS = WIDTH * HEIGHT;
    wire [31 : 0] PIXELS     = (DYNAMIC_MODE &&  !mode1080) ? 32'd921600 : MAX_PIXELS;

    localparam    WATCHDOG_WIDTH    = WATCHDOG_CYCLES > 1 ? $clog2(WATCHDOG_CYCLES) : 1;
    localparam    PIXEL_COUNT_WIDTH = MAX_PIXELS > 0 ? $clog2(MAX_PIXELS + 1) : 1;
    localparam    IDLE = 0, COLLECT = 1, ADDRESS = 2, WRITE = 3, VERIFY_START = 4, VERIFY = 5, DONE = 6, FAILED = 7;
    reg [2 : 0]   state;
    reg [255 : 0] block_data[0 : 15], pack_word;
    reg [3 : 0]   lane, pack_beat, write_beat, verify_beat;
    reg [PIXEL_COUNT_WIDTH - 1 : 0] accepted_pixels;
    reg [31 : 0]                    block_address, attempt;
    reg [WATCHDOG_WIDTH - 1 : 0]    watchdog;
    reg                             mismatch;
    reg [7 : 0]                     compare_mismatch;
    reg                             compare_valid;
    wire [255 : 0]                  expected_verify_data = block_data[verify_beat];
    wire                            pending_mismatch     = compare_valid &&  | compare_mismatch;
    integer                         compare_lane;
    wire                            verify_cmd_ready, verify_data_valid, verify_data_last, verify_done, verify_busy,
                                    reader_fault;                           // 最终读回完成后，仍需计入流水中的部分比较结果。
    wire [3 : 0]                    reader_fault_code;
    wire [255 : 0]                  verify_data;
    wire [32 : 0]                   frame_last_word = {1'b0, frame_base_word} + PIXELS / 2 - 1;
    wire   bad_base = (PIXELS % 256) != 0 || frame_base_word[6 : 0] != 0 || (frame_last_word >> ADDR_WIDTH) != 0;
    assign frame_start_ready = rst_n &&  !fault && ddr_init_done && state == IDLE;
    assign pixel_ready       = rst_n &&  !fault && ddr_init_done && state == COLLECT;
    assign frame_done_valid  = state == DONE &&  !fault;
    assign axi_awaddr        = block_address[ADDR_WIDTH - 1 : 0];
    assign axi_awlen         = 4'd15;                                       // 一次写突发固定为 16 个 256 位宽字，共 256 个 RGB565 像素。
    assign axi_awuser_id     = WRITE_ID;
    assign axi_awuser_ap     = 0;
    assign axi_awvalid       = rst_n && ddr_init_done &&  !fault && state == ADDRESS;
    assign axi_wdata         = block_data[write_beat];
    assign axi_wstrb         = 32'hffffffff;                                // 所有 32 个字节均有效；该路径没有局部字节更新。
    wire   write_context     = state == WRITE || (axi_awvalid && axi_awready);
    ddr_line_reader #(.ADDR_WIDTH(ADDR_WIDTH),                              // 源图行读取：把一行请求拆成符合突发长度及边界要求的 DDR 事务，并核对返回标签。
                      .MAX_LINE_BEATS(16),
                      .READ_ID(VERIFY_ID),
                      .WATCHDOG_CYCLES(WATCHDOG_CYCLES))
        verifier(.clk(clk),
                 .rst_n(rst_n),
                 .ddr_init_done(ddr_init_done),
                 .command_valid(state == VERIFY_START &&  !fault),
                 .command_ready(verify_cmd_ready),
                 .command_word_addr(block_address),
                 .command_beats(16'd16),
                 .return_valid(verify_data_valid),
                 .return_data(verify_data),
                 .return_last(verify_data_last),
                 .line_done(verify_done),
                 .busy(verify_busy),
                 .fault(reader_fault),
                 .fault_code(reader_fault_code),
                 .axi_araddr(verify_araddr),
                 .axi_aruser_id(verify_aruser_id),
                 .axi_aruser_ap(verify_aruser_ap),
                 .axi_arlen(verify_arlen),
                 .axi_arvalid(verify_arvalid),
                 .axi_arready(verify_arready),
                 .axi_rdata(verify_rdata),
                 .axi_rid(verify_rid),
                 .axi_rlast(verify_rlast),
                 .axi_rvalid(verify_rvalid));

    always @(posedge clk) begin
        if (!rst_n)
            pack_word <= 0;
        else if (state == IDLE)
            pack_word <= 0;
        else if (pixel_valid && pixel_ready) begin
            if (lane == 15)
                pack_word <= 0;
            else
                pack_word[lane * 16 +: 16] <= pixel;
        end
    end

    always @(posedge clk)
        if (pixel_valid && pixel_ready && lane == 15)                       // 每收齐 16 个像素，形成一个可供 DDR 写出的完整宽字。
            block_data[pack_beat] <= {pixel, pack_word[239 : 0]};

    always @(posedge clk) begin
        if (!rst_n) begin
            accepted_pixels <= 0;
            lane            <= 0;
            pack_beat       <= 0;
        end else if (state == IDLE) begin
            accepted_pixels <= 0;
            lane            <= 0;
            pack_beat       <= 0;
        end else if (pixel_valid && pixel_ready) begin
            accepted_pixels <= accepted_pixels + 1'b1;
            if (lane == 15) begin
                lane      <= 0;
                pack_beat <= pack_beat + 1'b1;
            end else
                lane <= lane + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            write_beat  <= 0;
            verify_beat <= 0;
        end else if (!fault) begin
            if (state == IDLE || state == COLLECT)
                write_beat <= 0;
            else if (axi_wready && write_context && write_beat != 15)
                write_beat <= write_beat + 1'b1;
            if (state != VERIFY)
                verify_beat <= 0;
            else if (verify_data_valid)
                verify_beat <= verify_beat + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            compare_valid    <= 0;
            compare_mismatch <= 0;
        end else begin
            compare_valid <= state == VERIFY && verify_data_valid;
            if (state == VERIFY && verify_data_valid)
                for (compare_lane = 0; compare_lane < 8; compare_lane = compare_lane + 1)
                    compare_mismatch[compare_lane] <=
                        verify_data[compare_lane * 32 +: 32] !== expected_verify_data[compare_lane * 32 +: 32];
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state              <= IDLE;
            fault              <= 0;
            fault_code         <= 0;
            done_base_word     <= 0;
            done_frame_id      <= 0;
            block_address      <= 0;
            watchdog           <= 0;
            attempt            <= 0;
            mismatch           <= 0;
            blocks_transferred <= 0;
            blocks_verified    <= 0;
            verify_retries     <= 0;
        end else if (!fault) begin
            if (state != IDLE &&  !ddr_init_done) begin
                fault      <= 1;
                fault_code <= 7;
                state      <= FAILED;
            end else if (reader_fault) begin
                fault      <= 1;
                fault_code <= 6;
                state      <= FAILED;
            end else if (axi_wready && (!write_context || axi_wusero_id != WRITE_ID)) begin  // 返回的写数据请求必须属于本写帧器，否则停止并报告归属错误。
                fault      <= 1;
                fault_code <= 3;
                state      <= FAILED;
            end else if (axi_wready && axi_wusero_last != (write_beat == 15)) begin  // DDR 的末拍标识必须与当前突发计数一致。
                fault      <= 1;
                fault_code <= 4;
                state      <= FAILED;
            end else if ((state == ADDRESS || state == WRITE) && WATCHDOG_CYCLES != 0 &&  // 地址或数据握手长期不前进时触发看门狗，避免永久等待。
                         watchdog >= WATCHDOG_CYCLES - 1 &&  !(axi_awvalid && axi_awready) &&  !axi_wready) begin
                fault      <= 1;
                fault_code <= 8;
                state      <= FAILED;
            end else begin
                if ((state != ADDRESS && state != WRITE) || (axi_awvalid && axi_awready) || axi_wready)
                    watchdog <= 0;
                else
                    watchdog <= watchdog + 1'b1;
                case (state)
                    IDLE :                                                  // 接受帧基址和帧号，开始一帧写回。
                        if (frame_start_valid && frame_start_ready) begin
                            if (bad_base || frame_id == 0) begin
                                fault      <= 1;
                                fault_code <= 2;
                                state      <= FAILED;
                            end else begin
                                done_base_word     <= frame_base_word;
                                done_frame_id      <= frame_id;
                                block_address      <= frame_base_word;
                                blocks_transferred <= 0;
                                blocks_verified    <= 0;
                                verify_retries     <= 0;
                                attempt            <= 0;
                                state              <= COLLECT;
                            end
                        end
                    COLLECT :                                               // 按像素握手收集 16×16 像素的突发块。
                        if (pixel_valid && pixel_ready) begin
                            if (pixel_index != accepted_pixels || pixel_last != (accepted_pixels == PIXELS - 1)) begin
                                fault      <= 1;
                                fault_code <= 1;
                                state      <= FAILED;
                            end else begin
                                if (lane == 15) begin
                                    if (pack_beat == 15) begin
                                        attempt <= 0;
                                        state   <= ADDRESS;
                                    end
                                end
                            end
                        end
                    ADDRESS :                                               // 保持写地址有效直到 DDR 接受。
                        if (axi_awvalid && axi_awready)
                            state <= WRITE;
                    WRITE : begin                                           // 依据 DDR 的写数据请求提供各个宽字。
                    end
                    VERIFY_START :                                          // 为刚写完的块发起读回。
                        if (verify_cmd_ready) begin
                            mismatch <= 0;
                            state    <= VERIFY;
                        end
                    VERIFY : begin                                          // 逐宽字比较读回数据；不一致时按上限重试。
                        if (pending_mismatch)
                            mismatch <= 1;
                        if (verify_done) begin
                            if (mismatch || pending_mismatch) begin         // 读回不一致时重读核验，超过限定次数则拒绝发布该帧。
                                if (attempt + 1 >= MAX_VERIFY_TRIES) begin
                                    fault      <= 1;
                                    fault_code <= 5;
                                    state      <= FAILED;
                                end else begin
                                    attempt        <= attempt + 1'b1;
                                    verify_retries <= verify_retries + 1'b1;
                                    state          <= VERIFY_START;
                                end
                            end else begin
                                blocks_verified <= blocks_verified + 1'b1;
                                if (accepted_pixels == PIXELS)
                                    state <= DONE;
                                else begin
                                    block_address <= block_address + 128;
                                    state         <= COLLECT;
                                end
                            end
                        end
                    end
                    DONE :                                                  // 完成有效保持到帧管理器接收，不只产生一个可能丢失的瞬时脉冲。
                        if (frame_done_ready)
                            state <= IDLE;
                    default : begin
                        fault      <= 1;
                        fault_code <= 9;
                        state      <= FAILED;
                    end
                endcase
                if (axi_wready) begin
                    if (write_beat == 15) begin
                        blocks_transferred <= blocks_transferred + 1'b1;
                        state              <= VERIFY_START;
                    end
                end
            end
        end
    end
endmodule
