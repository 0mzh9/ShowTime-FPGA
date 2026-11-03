`timescale 1ns/1ps
 
 
 
module pan_column_table                                                     // 按列预计算转向射线：后台生成备用表，整张表完成后仅在处理帧边界切换。
    (input wire clk, rst_n, request,                                        // 处理时钟；低有效复位；请求翻转标识。
     input wire signed [15 : 0] angle_tenths,                               // 转向角，单位 0.1 度。
     input wire [15 : 0] sequence_id,                                       // 本次请求序号。
     input wire frame_start,                                                // 处理帧起始。
     input wire [10 : 0] read_column,                                       // 待查询的输出列。
     input wire read_enable,                                                // 列参数读取使能。
     output reg [63 : 0] read_value,                                        // 该列的旋转坐标与倒数。
     output wire                 ready,
     output wire signed [15 : 0] next_angle,                                // 下一处理帧将使用的角度。
     output wire [15 : 0]        next_sequence,                             // 下一处理帧将使用的请求序号。
     output wire                 next_epoch,                                // 下一处理帧将使用的转向表代际。
     output reg                  active_epoch,                              // 当前已生效的转向表代际。
     output reg signed [15 : 0]  active_angle,                              // 当前已生效的转向角。
     output reg [15 : 0]         active_sequence,                           // 当前表所对应的转向请求序号，用于后续目标帧确认。
     output wire busy                                                       // 事务进行中。
    );
    localparam           IDLE = 0, TRIG_WAIT = 1, PRODUCTS = 2, NORMALIZE = 3, DIV_INIT = 4, DIVIDE = 5, X_MULTIPLY = 6,
                         WRITE = 7, TRIG_CAPTURE = 8, PRODUCT_WAIT1 = 9, PRODUCT_WAIT2 = 10,
                         X_WAIT1 = 11, X_WAIT2 = 12;
    reg [3 : 0]          state;
    reg [63 : 0]         bank0[0 : 1279], bank1[0 : 1279];                  // 双列参数表，一份输出使用，一份后台重建。
    reg                  active_bank, build_bank, valid_bank, pending, seen, build_epoch;
    reg signed [15 : 0]  build_angle;
    reg [15 : 0]         build_sequence;
    reg [10 : 0]         column;
    reg signed [31 : 0]  x_acc;                                             // Q30 横向射线累加值，按列递增，避免逐列重复计算除法。
    wire signed [31 : 0] x_q24 = (x_acc + 32'sd32) >>> 6;                   // 把累加值舍入到 Q24，作为当前输出列的初始横向射线。
    wire [8 : 0]  angle_abs = build_angle < 0 ?  - build_angle : build_angle;  // 三角查找表按绝对角度索引，符号另行处理。
    wire [47 : 0] trig;
    pan_trig_rom  rom(.clk(clk),                                            // 转向三角查找表：绝对角度以 0.1 度索引，同步输出 Q22 正弦和余弦。
                      .angle_abs(angle_abs),
                      .value(trig));                                        // 正余弦查表值采用有符号 Q22。
    wire signed [23 : 0] sine   = build_angle < 0 ?  - $signed(trig[47 : 24]) : $signed(trig[47 : 24]);
    wire signed [23 : 0] cosine = $signed(trig[23 : 0]);
    reg signed [23 : 0] sine_latched, cosine_latched;
    wire signed [55 : 0] xp, zp;
    reg signed [31 : 0]  xn;
    reg [31 : 0]         denominator;
    reg [48 : 0]         dividend, quotient;
    reg [31 : 0]         remainder;
    reg [5 : 0]          count;
    reg signed [31 : 0]  reciprocal;
    wire signed [63 : 0] x_product;
    wire [32 : 0]        trial         = {remainder, dividend[48]};         // 恢复除法的当前试减余数；高位移入下一位被除数。
    wire                 subtract      = trial >= {1'b0, denominator};
    wire [48 : 0]        quotient_next = {quotient[47 : 0], subtract};
    wire signed [63 : 0] xn_wide       = ((xp + 56'sd2097152) >>> 22) + ($signed(sine_latched) * 64'sd4);  // Q24 射线乘 Q22 余弦后回到 Q24，再加正弦的 Q24 表示。
    wire signed [63 : 0] zn_wide       = ($signed(cosine_latched) * 64'sd4) - ((zp + 56'sd2097152) >>> 22);  // Z=cos(theta)-x*sin(theta)，与 X/Z 共同形成透视投影。
    wire signed [31 : 0] x_result      = (x_product + 64'sd8388608) >>> 24;  // Q24×Q24 乘积舍入回 Q24，保留与参考模型一致的精度。
    assign               ready         = valid_bank || pending;             // 活动表有效或已有完整待提交表时，允许下一处理帧准备启动。
    assign               busy          = state != IDLE || pending;
    assign               next_angle    = pending ? build_angle : active_angle;
    assign               next_sequence = pending ? build_sequence : active_sequence;
    assign               next_epoch    = pending ? build_epoch : active_epoch;
    // 将列参数的宽乘法拆成三拍，完整保留乘积，不更改列参数的定点格式。
    signed_mul_pipe #(.A_WIDTH(32), .B_WIDTH(24)) rotate_x (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(1'b1), .input_valid(state == PRODUCTS),
        .a(x_q24), .b(cosine_latched), .product(xp));
    signed_mul_pipe #(.A_WIDTH(32), .B_WIDTH(24)) rotate_z (                // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(1'b1), .input_valid(state == PRODUCTS),
        .a(x_q24), .b(sine_latched), .product(zp));
    signed_mul_pipe #(.A_WIDTH(32), .B_WIDTH(32)) project_x (               // 三级有符号全精度乘法：部分乘积、分组累加、结果合并，统一由 advance 控制。
        .clk(clk), .rst_n(rst_n), .advance(1'b1), .input_valid(state == X_MULTIPLY),
        .a(xn), .b(reciprocal), .product(x_product));
    always @(posedge clk) begin
        if (read_enable) begin
            if (active_bank)
                read_value <= bank1[read_column];
            else
                read_value <= bank0[read_column];
        end
        if (!rst_n) begin
            state           <= IDLE;
            active_bank     <= 0;
            build_bank      <= 1;
            valid_bank      <= 0;
            pending         <= 0;
            seen            <=  !request;
            build_epoch     <= 0;
            build_angle     <= 0;
            build_sequence  <= 0;
            column          <= 0;
            x_acc           <=  -32'sd751254743;
            active_epoch    <= 0;
            active_angle    <= 0;
            active_sequence <= 0;
            sine_latched    <= 0;
            cosine_latched  <= 0;
            xn              <= 0;
            denominator     <= 1;
            dividend        <= 0;
            quotient        <= 0;
            remainder       <= 0;
            count           <= 0;
            reciprocal      <= 0;
        end else begin
            if (frame_start && pending) begin                               // 仅在处理帧边界切换整张列参数表。
                active_bank     <= build_bank;
                valid_bank      <= 1;
                pending         <= 0;
                active_epoch    <= build_epoch;
                active_angle    <= build_angle;
                active_sequence <= build_sequence;
            end
            case (state)
                IDLE :                                                      // 没有待提交表时接受新的角度翻转请求。
                    if (!pending && request != seen) begin                  // 翻转标识变化时接受新的角度请求。
                        seen           <= request;
                        build_epoch    <= request;
                        build_angle    <= angle_tenths;
                        build_sequence <= sequence_id;
                        build_bank     <=  !active_bank;
                        column         <= 0;
                        x_acc          <=  -32'sd751254743;
                        state          <= TRIG_WAIT;
                    end
                TRIG_WAIT :                                                 // 等待同步正余弦 ROM 的数据稳定。
                    state <= TRIG_CAPTURE;
                TRIG_CAPTURE : begin                                        // 锁存查表值和角度符号，隔开 ROM 与宽乘法路径。
                    // 先锁存 ROM 输出及符号选择，截断 ROM 到乘法器的组合路径。
                    sine_latched <= sine;
                    cosine_latched <= cosine;
                    state <= PRODUCTS;
                end
                PRODUCTS : state <= PRODUCT_WAIT1;                          // 启动当前列的旋转乘法。
                PRODUCT_WAIT1 : state <= PRODUCT_WAIT2;                     // 等待三级宽乘法的中间级。
                PRODUCT_WAIT2 : state <= NORMALIZE;                         // 等待完整旋转乘积输出。
                NORMALIZE : begin                                           // 形成旋转射线的 X、Z 分量。
                    xn          <= xn_wide;
                    denominator <= zn_wide;
                    state       <= DIV_INIT;
                end
                DIV_INIT : begin                                            // 初始化 2^48 除以 Z 的迭代除法。
                    dividend  <= 49'h1000000000000;                         // 被除数为 2^48；除以 Q24 的 Z 后得到 Q24 格式的 1/Z。
                    quotient  <= 0;
                    remainder <= 0;
                    count     <= 48;
                    state     <= DIVIDE;
                end                                                         // 为当前列计算 Z 分量的整数倒数。
                DIVIDE : begin                                              // 逐位求倒数，只对每列计算一次。
                    dividend  <= dividend << 1;
                    remainder <= subtract ? trial - {1'b0, denominator} : trial;
                    quotient  <= quotient_next;
                    if (count == 0) begin
                        reciprocal <= quotient_next[31 : 0];
                        state      <= X_MULTIPLY;
                    end                                                     // 49 步除法完成后，倒数复用于本列全部像素。
                    else
                        count <= count - 1'b1;
                end
                X_MULTIPLY : state <= X_WAIT1;                              // 使用倒数计算 X/Z。
                X_WAIT1 : state <= X_WAIT2;                                 // 等待横向投影乘法的中间级。
                X_WAIT2 : state <= WRITE;                                   // 等待完整横向投影乘积。
                WRITE : begin                                               // 写入备用列参数表，最后一列完成才允许帧边界切换。
                    if (build_bank)
                        bank1[column] <= {x_result, reciprocal};            // 每列保存旋转归一化横坐标及倒数。
                    else
                        bank0[column] <= {x_result, reciprocal};
                    if (column == 1279) begin
                        pending <= 1;
                        state   <= IDLE;
                    end                                                     // 整张表写完才置待提交标志。
                    else begin
                        column <= column + 1'b1;
                        x_acc  <= x_acc + 32'sd1174753;                     // 按固定的每列射线步进递增，覆盖 1280 个输出列。
                        state  <= PRODUCTS;
                    end
                end
                default :
                    state <= IDLE;
            endcase
        end
    end
endmodule
