`timescale 1ns/1ps
 
 
 
 
module split_frame_composer                                                 // 可选左右拼接通路：依次读原图与结果行，合成为两倍宽的 RGB565 输出帧。
    #(parameter WIDTH = 1280, HEIGHT = 720, ADDR_WIDTH = 28)                // 源图每行像素数；源图有效行数；DDR 地址位宽。
    (                                                                       // 保留的同帧并排合成路径，不替代当前交替输出。
     input wire clk, rst_n, ddr_init_done,                                  // 处理时钟；低有效复位；DDR 初始化完成。
     input wire           start_valid,
     output wire          start_ready,
     input wire [31 : 0]  raw_base, corrected_base, output_base, frame_id,  // 本次事务关联的图像帧号。
     output wire          done_valid,
     input wire           done_ready,
     output wire [31 : 0] done_id,
     output wire          fault,                                            // 锁存的故障标志。
     output wire [ADDR_WIDTH - 1 : 0] axi_araddr, axi_awaddr,               // DDR 读字地址；DDR 写字地址。
     output wire [3 : 0] axi_arlen, axi_aruser_id, axi_awlen, axi_awuser_id,
     output wire         axi_aruser_ap, axi_arvalid, axi_awuser_ap, axi_awvalid,
     input wire          axi_arready, axi_awready,                          // DDR 接受读地址；DDR 接受写地址。
     input wire [255 : 0] axi_rdata,                                        // 原生 DDR 返回数据。
     input wire [3 : 0] axi_rid, axi_wusero_id,
     input wire         axi_rvalid, axi_rlast, axi_wready, axi_wusero_last,  // DDR 返回拍有效；当前突发最后一拍；原生 DDR 请求提供写数据；原生写数据末拍指示。
     output wire [255 : 0] axi_wdata,
     output wire [31 : 0]  axi_wstrb                                        // 原生 DDR 写数据；原生 DDR 字节使能。
    );
    localparam          OUTPUT_WIDTH = 2 * WIDTH, N = OUTPUT_WIDTH * HEIGHT, BEATS = WIDTH / 16;
    localparam [15 : 0] LINE_BEATS = BEATS;
    localparam   IDLE = 0, RAW_CMD = 2, RAW_WAIT = 3, CORR_CMD = 4, CORR_WAIT = 5, PRIME = 6, IMAGE = 7, DRAIN = 8;
    localparam   RAM_A = $clog2(2 * BEATS);
    reg [3 : 0]  state;
    reg [31 : 0] raw_locked, corr_locked, index, row_offset;
    reg [$clog2(OUTPUT_WIDTH) - 1 : 0] x;
    reg [9 : 0]                        y;
    reg [RAM_A - 1 : 0]                load_index, read_index;
    reg [255 : 0]                      rows[0 : 2 * BEATS - 1];
    reg [255 : 0]                      word_data;
    wire                               cmd_ready, return_valid, return_last, reader_fault, writer_fault, arb_fault;
    wire [255 : 0]                     return_data;
    wire                               writer_ready, pixel_ready, writer_done;
    wire                               pixel_valid  = state == IMAGE &&  !fault;
    wire                               fire         = pixel_valid && pixel_ready;
    wire [15 : 0]                      pixel        = word_data[{x[3 : 0], 4'b0000} +: 16];
    wire [31 : 0]                      command_addr = (state == RAW_CMD ? raw_locked : corr_locked) + row_offset;
    assign                             fault        = reader_fault || writer_fault || arb_fault;
    assign                             start_ready  = state == IDLE && writer_ready &&  !fault;
    assign                             done_valid   = state == DRAIN && writer_done &&  !fault;
    wire [ADDR_WIDTH - 1 : 0]          c_araddr, v_araddr, w_awaddr;
    wire [3 : 0]                       c_arlen, v_arlen, w_awlen, c_rid, v_rid, w_id;
    wire           c_arap, v_arap, w_awap, c_arvalid, v_arvalid, w_awvalid, c_arready, v_arready, w_awready;
    wire           c_rvalid, v_rvalid, c_rlast, v_rlast, w_ready, w_last;
    wire [255 : 0] c_rdata, v_rdata, w_data;
    wire [31 : 0]  w_strb;
    ddr_line_reader #(.ADDR_WIDTH(ADDR_WIDTH),                              // 源图行读取：把一行请求拆成符合突发长度及边界要求的 DDR 事务，并核对返回标签。
                      .MAX_LINE_BEATS(BEATS))
        reader(.clk(clk),
               .rst_n(rst_n),
               .ddr_init_done(ddr_init_done),
               .command_valid((state == RAW_CMD || state == CORR_CMD) &&  !fault),
               .command_ready(cmd_ready),
               .command_word_addr(command_addr),
               .command_beats(LINE_BEATS),
               .return_valid(return_valid),
               .return_data(return_data),
               .return_last(return_last),
               .line_done(),
               .busy(),
               .fault(reader_fault),
               .fault_code(),
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
    corrected_frame_writer #(.WIDTH(OUTPUT_WIDTH),                          // 结果写帧器：将 RGB565 打包为 DDR 宽字，写后读回验证，通过后才提交整帧。
                             .HEIGHT(HEIGHT),
                             .ADDR_WIDTH(ADDR_WIDTH))
        writer(.clk(clk),
               .rst_n(rst_n),
               .ddr_init_done(ddr_init_done),
               .frame_start_valid(start_valid && state == IDLE &&  !fault),
               .frame_start_ready(writer_ready),
               .frame_base_word(output_base),
               .frame_id(frame_id),
               .pixel_valid(pixel_valid),
               .pixel_ready(pixel_ready),
               .pixel(pixel),
               .pixel_index(index),
               .pixel_last(index == N - 1),
               .frame_done_valid(writer_done),
               .frame_done_ready(done_ready && state == DRAIN &&  !fault),
               .done_base_word(),
               .done_frame_id(done_id),
               .fault(writer_fault),
               .fault_code(),
               .blocks_transferred(),
               .blocks_verified(),
               .verify_retries(),
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
                .axi_rdata(axi_rdata),
                .axi_rid(axi_rid),
                .axi_rvalid(axi_rvalid),
                .axi_rlast(axi_rlast),
                .axi_wready(axi_wready),
                .axi_wusero_id(axi_wusero_id),
                .axi_wusero_last(axi_wusero_last),
                .axi_wdata(axi_wdata),
                .axi_wstrb(axi_wstrb),
                .fault(arb_fault),
                .fault_code());

    always @(posedge clk) begin
        if (return_valid)
            rows[load_index] <= return_data;
        word_data <= rows[read_index];
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= IDLE;
            raw_locked  <= 0;
            corr_locked <= 0;
            index       <= 0;
            row_offset  <= 0;
            x           <= 0;
            y           <= 0;
            load_index  <= 0;
            read_index  <= 0;
        end else if (!fault) begin
            if (start_valid && start_ready) begin
                raw_locked  <= raw_base;
                corr_locked <= corrected_base;
                index       <= 0;
                x           <= 0;
                y           <= 0;
                row_offset  <= 0;
                state       <= RAW_CMD;
            end
            if ((state == RAW_CMD || state == CORR_CMD) && cmd_ready) begin
                load_index <= state == RAW_CMD ? 0 : BEATS;
                state      <= state == RAW_CMD ? RAW_WAIT : CORR_WAIT;
            end
            if (return_valid) begin
                load_index <= load_index + 1'b1;
                if (return_last) begin
                    if (state == RAW_WAIT)
                        state <= CORR_CMD;
                    else begin
                        read_index <= 0;
                        state      <= PRIME;
                    end
                end
            end
            if (state == PRIME)
                state <= IMAGE;
            if (fire) begin
                index <= index + 1'b1;
                if (x == OUTPUT_WIDTH - 1) begin
                    x <= 0;
                    y <= y + 1'b1;
                    if (index == N - 1)
                        state <= DRAIN;
                    else begin
                        row_offset <= row_offset + WIDTH / 2;
                        state      <= RAW_CMD;
                    end
                end else begin
                    x <= x + 1'b1;
                    if (x[3 : 0] == 15) begin
                        read_index <= read_index + 1'b1;
                        state      <= PRIME;
                    end
                end
            end
            if (done_valid && done_ready)
                state <= IDLE;
        end
    end
endmodule
