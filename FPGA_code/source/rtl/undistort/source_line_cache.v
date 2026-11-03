`timescale 1ns/1ps
 
 
 
 
module source_line_cache                                                    // 源图行缓存：核对帧号、基址及行标签，命中直接取四邻点，缺行则从 DDR 装载。
    #(                                                                      // 按行缓存源图，为每个输出像素提供四个相邻采样点。
      parameter WIDTH = 1280, HEIGHT = 720, CACHE_LINES = 32,               // 顶层实际实例覆盖为 112 行；此处默认值仅用于参数化复用。
                TAG_WIDTH = 32                                              // 行缓存容量，由参数控制；当前正式实例为 112 行。
    )
    (input wire clk, rst_n,                                                 // 处理时钟；低有效复位。
     input wire                 query_valid,                                // 源坐标查询有效。
     output wire                query_ready,                                // 允许接收下一源坐标查询。
     input wire signed [15 : 0] query_x, query_y,
     input wire [7 : 0]         query_frac_x, query_frac_y,                 // 横向小数权重随源坐标一同进入缓存。
     input wire [31 : 0]            query_frame_id, query_base_word,        // 本次查询所属原帧号；本次查询所属原帧基址。
     input wire [TAG_WIDTH - 1 : 0] query_tag,                              // 查询所携带的输出像素标签。
     output wire                    response_valid,                         // 缓存响应有效。
     input wire                     response_ready,                         // 响应下游就绪。
     output reg [15 : 0]            p00, p10, p01, p11,
     output reg [3 : 0]             tap_valid,                              // 四邻点分别是否位于有效图像内。
     output reg [7 : 0]             frac_x, frac_y,                         // 横向插值小数权重；纵向插值小数权重。
     output reg [TAG_WIDTH - 1 : 0] response_tag,                           // 与四邻域响应对齐的像素标签。
     output wire                    command_valid,                          // 源图行读取请求有效，与 UART 双字节命令无关。
     input wire           command_ready,                                    // 命令接收端就绪。
     output reg [31 : 0]  command_word_addr,                                // 待读取行的 DDR 字地址。
     output wire [15 : 0] command_beats,                                    // 当前行需要的 DDR 宽字数。
     input wire           return_valid,                                     // DDR 返回宽字有效。
     input wire [255 : 0] return_data,                                      // DDR 返回的 256 位数据。
     input wire           return_last,                                      // 当前行请求的最后一个返回宽字。
     output reg           fault,                                            // 锁存的故障标志。
     output reg [31 : 0] hit_queries, line_loads);
    localparam  BEATS = WIDTH / 16, HALF_WIDTH = WIDTH / 2;                 // 一个 256 位 DDR 宽字容纳 16 个 RGB565 像素。
    localparam  BANK_DEPTH = (CACHE_LINES / 2) * HALF_WIDTH;                // 按横纵奇偶拆为四个分银行，每个银行只保存相应半行和半列。
    localparam  ROW_BITS   = HEIGHT > 1 ? $clog2(HEIGHT) : 1;
    localparam  SLOT_BITS  = CACHE_LINES > 1 ? $clog2(CACHE_LINES) : 1;
    localparam  BEAT_BITS  = BEATS > 1 ? $clog2(BEATS) : 1;
    localparam  PIXEL_BITS = WIDTH > 1 ? $clog2(WIDTH) : 1;
    localparam  IDLE = 0, CHECK = 1, COMMAND = 2, CAPTURE = 3, FILL = 4, DRAIN = 5, REPLAY = 6, FILL_PRIME = 7,
                FAILED = 8, FILL_DRAIN = 9, CHECK_PREP = 10;
    reg [3 : 0] state;
    reg         read_valid, output_valid;
    reg         address_valid, address_sample;
    reg [$clog2(BANK_DEPTH) - 1 : 0] address0, address1, address2, address3;
    reg [1 : 0]                      address_parity;
    reg [3 : 0]                      address_mask;
    reg [7 : 0]                      address_frac_x, address_frac_y;
    reg [TAG_WIDTH - 1 : 0]          address_tag;
    wire                             advance        = rst_n &&  !fault && (!output_valid || response_ready);
    wire                             inner_ready    = (state == IDLE) && advance;
    assign                           response_valid = output_valid &&  !fault;
    assign                           command_valid  = (state == COMMAND) &&  !fault;
    assign                           command_beats  = BEATS;

    reg [255 : 0]             staging[0 : BEATS - 1];                       // 先暂存完整行的 DDR 宽字，再按像素分发到缓存 RAM。
    reg [255 : 0]             staging_word;
    reg [CACHE_LINES - 1 : 0] row_valid;
    reg [ROW_BITS - 1 : 0]    row_number[0 : CACHE_LINES - 1];

    reg [31 : 0]        cached_frame, cached_base;
    reg signed [15 : 0] x, y;

    wire signed [31 : 0]     y_wide = {{16{y[15]}}, y};
    reg [31 : 0]             frame_id, base_word;
    reg                      q_valid;
    reg signed [15 : 0]      q_x, q_y;
    reg [7 : 0]              q_frac_x, q_frac_y;
    reg [31 : 0]             q_frame_id, q_base_word;
    reg [TAG_WIDTH - 1 : 0]  q_tag;
    reg [SLOT_BITS - 1 : 0]  q_top_slot, q_bottom_slot, miss_top_slot, miss_bottom_slot;
    reg                      saved_top_hit, saved_bottom_hit;
    reg [3 : 0]              mask;
    reg [ROW_BITS - 1 : 0]   load_y;
    reg [SLOT_BITS - 1 : 0]  load_slot;
    reg [BEAT_BITS - 1 : 0]  receive_count;
    reg [PIXEL_BITS - 1 : 0] fill_x;
    wire [15 : 0]            read0, read1, read2, read3;
    reg [1 : 0]              read_parity;
    reg [3 : 0]              read_mask;
    reg [7 : 0]              read_frac_x, read_frac_y;
    reg [TAG_WIDTH - 1 : 0]  read_tag;
    reg [7 : 0]              saved_frac_x, saved_frac_y;
    reg [TAG_WIDTH - 1 : 0]  saved_tag;
    integer                  i;
    function in_bounds;
        input integer px, py;
        begin
            in_bounds = (px >= 0 && px < WIDTH && py >= 0 && py < HEIGHT);
        end
    endfunction

    function [SLOT_BITS - 1 : 0] row_slot;                                  // 计算源行所属循环槽；112 不是二次幂，使用分级减法实现取模。
        input [ROW_BITS - 1 : 0] py;
        reg [ROW_BITS - 1 : 0]   a, b;
        begin
            if (CACHE_LINES == 112) begin
                a        = py >= 448 ? py - 448 : py;
                b        = a >= 224 ? a - 224 : a;
                row_slot = b >= 112 ? b - 112 : b;
            end else
                row_slot = py & (CACHE_LINES - 1);
        end
    endfunction
    function row_hit;                                                       // 命中需同时满足有效位、行号、帧号和基址，防止换帧后复用旧数据。
        input integer  py;
        input [31 : 0] frame, base;
        integer        slot;
        begin
            slot = row_slot(py);
            if (py < 0 || py >= HEIGHT)
                row_hit = 1;
            else
                row_hit = row_valid[slot] && row_number[slot] == py && cached_frame == frame && cached_base == base;
        end
    endfunction

    assign query_ready = rst_n &&  !fault && (!q_valid || inner_ready);     // 查询前端只暂存一项；缺行期间保留此查询，不丢失坐标与标签。

    integer row_reset;
    always @(posedge clk) begin
        if (!rst_n) begin
            row_valid <= 0;
            for (row_reset = 0; row_reset < CACHE_LINES; row_reset = row_reset + 1)
                row_number[row_reset] <= 0;
        end else if (!fault) begin
            if (state == CHECK) begin
                if (cached_frame != frame_id || cached_base != base_word)
                    row_valid <= 0;
                else if ((mask[0] || mask[1]) &&  !saved_top_hit)
                    row_valid[miss_top_slot] <= 0;
                else if ((mask[2] || mask[3]) &&  !saved_bottom_hit)
                    row_valid[miss_bottom_slot] <= 0;
            end else if (state == FILL_DRAIN) begin                         // 最后一个 RAM 写周期结束后，才把整行标记为可命中。
                row_valid[load_slot]  <= 1;
                row_number[load_slot] <= load_y;
            end
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            q_valid       <= 0;
            q_x           <= 0;
            q_y           <= 0;
            q_frac_x      <= 0;
            q_frac_y      <= 0;
            q_frame_id    <= 0;
            q_base_word   <= 0;
            q_tag         <= 0;
            q_top_slot    <= 0;
            q_bottom_slot <= 0;
        end else begin
            if (inner_ready && q_valid)
                q_valid <= 0;
            if (query_valid && query_ready) begin
                q_valid     <= 1;
                q_x         <= query_x;
                q_y         <= query_y;
                q_frac_x    <= query_frac_x;
                q_frac_y    <= query_frac_y;
                q_frame_id  <= query_frame_id;
                q_base_word <= query_base_word;
                q_tag       <= query_tag;
                q_top_slot  <= ($signed(query_y) >= 0 && $signed(query_y) < HEIGHT) ? row_slot(query_y) : 0;
                q_bottom_slot <=
                    ($signed(query_y) + 1 >= 0 && $signed(query_y) + 1 < HEIGHT) ? row_slot(query_y + 1) : 0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            saved_top_hit    <= 0;
            saved_bottom_hit <= 0;
        end else if (state == CHECK_PREP) begin
            saved_top_hit    <= row_valid[miss_top_slot] && row_number[miss_top_slot] == y_wide &&
                                cached_frame == frame_id && cached_base == base_word;
            saved_bottom_hit <= row_valid[miss_bottom_slot] && row_number[miss_bottom_slot] == y_wide + 32'sd1 &&
                                cached_frame == frame_id && cached_base == base_word;
        end
    end
    wire [3 : 0] query_mask = {in_bounds($signed(q_x) + 1, $signed(q_y) + 1), in_bounds($signed(q_x), $signed(q_y) + 1),
                               in_bounds($signed(q_x) + 1, $signed(q_y)), in_bounds($signed(q_x), $signed(q_y))};

    wire signed [31 : 0] query_y_wide = {{16{q_y[15]}}, q_y};
    wire                 frame_hit    = cached_frame == q_frame_id && cached_base == q_base_word;
    wire                 top_hit      = row_valid[q_top_slot] && row_number[q_top_slot] == query_y_wide;
    wire                 bottom_hit   = row_valid[q_bottom_slot] && row_number[q_bottom_slot] == query_y_wide + 1;
    wire                 query_hit    = frame_hit && (!(query_mask[0] || query_mask[1]) || top_hit) &&
                                        (!(query_mask[2] || query_mask[3]) || bottom_hit);
    wire                 replay       = (state == REPLAY);
    wire                 issue_read   = advance && (replay || (q_valid && inner_ready && query_hit));

    wire                     sample_read      = advance && (replay || (q_valid && inner_ready));
    wire signed [15 : 0]     read_x           = replay ? x : q_x;
    wire signed [15 : 0]     read_y           = replay ? y : q_y;
    wire [SLOT_BITS - 1 : 0] read_top_slot    = replay ? miss_top_slot : q_top_slot;
    wire [SLOT_BITS - 1 : 0] read_bottom_slot = replay ? miss_bottom_slot : q_bottom_slot;
    wire [SLOT_BITS - 1 : 0] even_slot        = read_y[0] ? read_bottom_slot : read_top_slot;
    wire [SLOT_BITS - 1 : 0] odd_slot         = read_y[0] ? read_top_slot : read_bottom_slot;

    integer even_x, odd_x, even_y, odd_y, a0, a1, a2, a3;
    always @ * begin
        even_x = read_x[0] ? $signed(read_x) + 1 : $signed(read_x);
        odd_x  = read_x[0] ? $signed(read_x) : $signed(read_x) + 1;
        even_y = read_y[0] ? $signed(read_y) + 1 : $signed(read_y);
        odd_y  = read_y[0] ? $signed(read_y) : $signed(read_y) + 1;
        a0     = 0;
        a1     = 0;
        a2     = 0;
        a3     = 0;
        if (in_bounds(even_x, even_y))
            a0 = (even_slot / 2) * HALF_WIDTH + even_x / 2;
        if (in_bounds(odd_x, even_y))
            a1 = (even_slot / 2) * HALF_WIDTH + odd_x / 2;
        if (in_bounds(even_x, odd_y))
            a2 = (odd_slot / 2) * HALF_WIDTH + even_x / 2;
        if (in_bounds(odd_x, odd_y))
            a3 = (odd_slot / 2) * HALF_WIDTH + odd_x / 2;
    end
    function [15 : 0] select_read;                                          // 根据源坐标横纵奇偶，把四个分银行输出重排为 p00、p10、p01、p11。
        input [1 : 0] bank;
        begin
            case (bank)
                0 :
                    select_read = read0;
                1 :
                    select_read = read1;
                2 :
                    select_read = read2;
                3 :
                    select_read = read3;
            endcase
        end
    endfunction

    wire [31 : 0] fill_pixel        = staging_word[((fill_x & 15)) * 16 +: 32];
    wire [31 : 0] staging_next      = (fill_x + 2) >> 4;
    wire [31 : 0] staging_read_addr = state == FILL_PRIME || staging_next >= BEATS ? 0 : staging_next;
    always @(posedge clk)
        if (rst_n &&  !fault && (state == FILL_PRIME || state == FILL))
            staging_word <= staging[staging_read_addr];
    integer fill_addr;
    always @ *
        fill_addr = (load_slot / 2) * HALF_WIDTH + fill_x / 2;

    reg                              fill_write;
    reg [31 : 0]                     fill_pixel_q;
    reg [$clog2(BANK_DEPTH) - 1 : 0] fill_addr_q;
    reg [1 : 0]                      fill_bank_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            fill_write   <= 0;
            fill_pixel_q <= 0;
            fill_addr_q  <= 0;
            fill_bank_q  <= 0;
        end else begin
            fill_write <=  !fault && state == FILL;
            if (!fault && state == FILL) begin
                fill_pixel_q <= fill_pixel;
                fill_addr_q  <= fill_addr;
                fill_bank_q  <= {load_y[0], fill_x[0]};
            end
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= IDLE;
            fault             <= 0;
            cached_frame      <= 0;
            cached_base       <= 0;
            p00               <= 0;
            p10               <= 0;
            p01               <= 0;
            p11               <= 0;
            tap_valid         <= 0;
            frac_x            <= 0;
            frac_y            <= 0;
            response_tag      <= 0;
            command_word_addr <= 0;
            x                 <= 0;
            y                 <= 0;
            frame_id          <= 0;
            base_word         <= 0;
            mask              <= 0;
            miss_top_slot     <= 0;
            miss_bottom_slot  <= 0;
            read_valid        <= 0;
            output_valid      <= 0;
            read_parity       <= 0;
            read_mask         <= 0;
            address_valid     <= 0;
            address_sample    <= 0;
            address0          <= 0;
            address1          <= 0;
            address2          <= 0;
            address3          <= 0;
            address_parity    <= 0;
            address_mask      <= 0;
            address_frac_x    <= 0;
            address_frac_y    <= 0;
            address_tag       <= 0;
            read_frac_x       <= 0;
            read_frac_y       <= 0;
            read_tag          <= 0;
            saved_frac_x      <= 0;
            saved_frac_y      <= 0;
            saved_tag         <= 0;
            load_y            <= 0;
            load_slot         <= 0;
            receive_count     <= 0;
            fill_x            <= 0;
            hit_queries       <= 0;
            line_loads        <= 0;

        end else if (!fault) begin

            if (return_valid && state != CAPTURE &&  !(state == COMMAND && command_ready)) begin  // 没有行接收上下文却收到返回数据时锁存故障，避免误写缓存。
                fault <= 1;
                state <= FAILED;
            end else begin
                if (advance) begin                                          // 统一推进地址、RAM 输出和响应寄存器；下游暂停时保持配对。

                    address_valid  <= issue_read;
                    address_sample <= sample_read;
                    read_valid     <= address_valid;
                    output_valid   <= read_valid;
                    if (sample_read) begin
                        address0       <= a0;
                        address1       <= a1;
                        address2       <= a2;
                        address3       <= a3;
                        address_parity <= {read_y[0], read_x[0]};
                        address_mask   <= replay ? mask : query_mask;
                        address_frac_x <= replay ? saved_frac_x : q_frac_x;
                        address_frac_y <= replay ? saved_frac_y : q_frac_y;
                        address_tag    <= replay ? saved_tag : q_tag;
                    end
                    if (address_sample) begin

                        read_parity <= address_parity;
                        read_mask   <= address_mask;
                        read_frac_x <= address_frac_x;
                        read_frac_y <= address_frac_y;
                        read_tag    <= address_tag;
                    end
                    if (read_valid) begin
                        p00          <= read_mask[0] ? select_read(read_parity) : 16'd0;
                        p10          <= read_mask[1] ? select_read(read_parity ^ 2'b01) : 16'd0;
                        p01          <= read_mask[2] ? select_read(read_parity ^ 2'b10) : 16'd0;
                        p11          <= read_mask[3] ? select_read(read_parity ^ 2'b11) : 16'd0;
                        tap_valid    <= read_mask;
                        frac_x       <= read_frac_x;
                        frac_y       <= read_frac_y;
                        response_tag <= read_tag;
                    end
                end
                case (state)
                    IDLE :                                                  // 接受暂存查询；命中时沿读流水推进。
                        if (q_valid && inner_ready) begin

                            x                <= q_x;
                            y                <= q_y;
                            frame_id         <= q_frame_id;
                            base_word        <= q_base_word;
                            miss_top_slot    <= q_top_slot;
                            miss_bottom_slot <= q_bottom_slot;
                            saved_frac_x     <= q_frac_x;
                            saved_frac_y     <= q_frac_y;
                            saved_tag        <= q_tag;
                            mask             <= query_mask;
                            if (query_hit)
                                hit_queries <= hit_queries + 1;
                            else
                                state <= DRAIN;
                        end
                    DRAIN :                                                 // 清空正在读取的旧响应后处理缺行。
                        if (!address_valid &&  !read_valid &&  !output_valid)
                            state <= CHECK_PREP;
                    CHECK_PREP :                                            // 预计算需要的行槽号及命中条件。
                        state <= CHECK;
                    CHECK : begin                                           // 核对帧、基址和上下邻行标签，确定应装载的行。
                        if (cached_frame != frame_id || cached_base != base_word) begin  // 原帧标识或基址变化时清空缓存有效位，重新装载所需行。
                            cached_frame <= frame_id;
                            cached_base  <= base_word;
                            state        <= CHECK_PREP;
                        end else if ((mask[0] || mask[1]) &&  !saved_top_hit) begin
                            load_y            <= $signed(y);
                            load_slot         <= miss_top_slot;
                            command_word_addr <= base_word + y_wide * (WIDTH / 2);
                            receive_count     <= 0;
                            state             <= COMMAND;
                        end else if ((mask[2] || mask[3]) &&  !saved_bottom_hit) begin
                            load_y            <= $signed(y) + 1;
                            load_slot         <= miss_bottom_slot;
                            command_word_addr <= base_word + (y_wide + 32'sd1) * (WIDTH / 2);
                            receive_count     <= 0;
                            state             <= COMMAND;
                        end else begin
                            state <= REPLAY;
                        end
                    end
                    COMMAND :                                               // 提交缺失源图行的 DDR 读请求。
                        if (command_ready) begin
                            line_loads <= line_loads + 1;
                            state      <= CAPTURE;
                        end
                    CAPTURE : begin                                         // 接收一整行宽字到暂存区，检查返回数量和末拍。
                    end
                    FILL_PRIME :                                            // 为暂存区同步读取预留一个周期。
                        state <= FILL;
                    FILL : begin                                            // 按横坐标奇偶把一行像素分发到四个 RAM 分银行。
                        if (fill_x == WIDTH - 2)
                            state <= FILL_DRAIN;
                        else
                            fill_x <= fill_x + 2;
                    end
                    FILL_DRAIN : begin                                      // 等待 RAM 最后一次写入完成，再公布该行有效。
                        state <= CHECK_PREP;
                    end
                    REPLAY :                                                // 行装载完成，重新检查并处理保留的查询。
                        if (issue_read)
                            state <= IDLE;
                    default : begin
                        fault <= 1;
                        state <= FAILED;
                    end
                endcase
                if (return_valid && (state == CAPTURE || (state == COMMAND && command_ready))) begin  // 返回宽字只在合法读事务内计数，并检查末拍与预期行长度是否一致。
                    if (return_last != (receive_count == BEATS - 1)) begin
                        fault <= 1;
                        state <= FAILED;
                    end else begin
                        staging[receive_count] <= return_data;
                        if (receive_count == BEATS - 1) begin
                            fill_x <= 0;
                            state  <= FILL_PRIME;
                        end else
                            receive_count <= receive_count + 1;
                    end
                end
            end
        end
    end
    paged_pixel_bank #(.DEPTH(BANK_DEPTH))                                  // 分页面像素 RAM：把较深存储拆成 2048 项页面，读地址页号与同步 RAM 输出对齐。
        bank0(.clk(clk),
              .write_enable(rst_n &&  !fault && fill_write && fill_bank_q == 2'd0),
              .write_address(fill_addr_q),
              .write_data(fill_pixel_q[15 : 0]),
              .read_enable(rst_n &&  !fault && advance && address_sample),
              .read_address(address0),
              .read_data(read0));
    paged_pixel_bank #(.DEPTH(BANK_DEPTH))                                  // 分页面像素 RAM：把较深存储拆成 2048 项页面，读地址页号与同步 RAM 输出对齐。
        bank1(.clk(clk),
              .write_enable(rst_n &&  !fault && fill_write && fill_bank_q == 2'd0),
              .write_address(fill_addr_q),
              .write_data(fill_pixel_q[31 : 16]),
              .read_enable(rst_n &&  !fault && advance && address_sample),
              .read_address(address1),
              .read_data(read1));
    paged_pixel_bank #(.DEPTH(BANK_DEPTH))                                  // 分页面像素 RAM：把较深存储拆成 2048 项页面，读地址页号与同步 RAM 输出对齐。
        bank2(.clk(clk),
              .write_enable(rst_n &&  !fault && fill_write && fill_bank_q == 2'd2),
              .write_address(fill_addr_q),
              .write_data(fill_pixel_q[15 : 0]),
              .read_enable(rst_n &&  !fault && advance && address_sample),
              .read_address(address2),
              .read_data(read2));
    paged_pixel_bank #(.DEPTH(BANK_DEPTH))                                  // 分页面像素 RAM：把较深存储拆成 2048 项页面，读地址页号与同步 RAM 输出对齐。
        bank3(.clk(clk),
              .write_enable(rst_n &&  !fault && fill_write && fill_bank_q == 2'd2),
              .write_address(fill_addr_q),
              .write_data(fill_pixel_q[31 : 16]),
              .read_enable(rst_n &&  !fault && advance && address_sample),
              .read_address(address3),
              .read_data(read3));
endmodule
