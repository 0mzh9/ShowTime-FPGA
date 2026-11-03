`timescale 1ns/1ps
 
 
module uart_command_port                                                    // UART 字节收发及双字节命令拼接；数据包接收期间将原始字节交给事务模块。
    #(parameter CLOCK_HZ = 27000000, BAUD = 115200)                         // 该控制时钟每秒的周期数；串口目标波特率。
    (                                                                       // 115200、8N1 的双字节命令与应答接口。
     input wire clk, rst_n, rx,                                             // 本模块工作时钟；低有效复位。
     output reg tx,
     output reg command_valid,                                              // 双字节命令有效。
     output reg [15 : 0] command,                                           // 双字节命令。
     input wire  packet_mode,                                               // 数据包事务独占字节流。
     output wire received_valid,                                            // 串口接收字节有效。
     output wire [7 : 0] received_byte,                                     // 串口接收字节。
     input wire reply_valid,                                                // 应答有效。
     input wire [15 : 0] reply,                                             // 待发送的应答字。
     output wire reply_ready                                                // 应答发送端就绪。
    );
    localparam                             BIT_TICKS = (CLOCK_HZ + BAUD / 2) / BAUD;  // 按系统时钟与波特率四舍五入计算每一位的时钟周期数。
    localparam                             GAP_TICKS = CLOCK_HZ / 10;       // 双字节命令间隔过长时丢弃残留前缀，避免与后续字节误拼接。
    (* async_reg="true" *) reg [1 : 0] rx_sync;
    reg [1 : 0]                            rs;
    reg [15 : 0]                           rc;
    reg [2 : 0]                            rb;
    reg [7 : 0]                            rd, byte_data;
    reg                                    byte_valid;
    assign                                 received_valid = byte_valid;
    assign                                 received_byte  = byte_data;
    reg                                    have_first;
    reg [7 : 0]                            first;
    reg [31 : 0]                           gap;
    reg                                    busy;
    reg [19 : 0]                           tx_shift;
    reg [4 : 0]                            tx_index;
    reg [15 : 0]                           tc;
    assign                                 reply_ready =  !busy;            // 发送器空闲才接受新的双字节应答。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync    <= 3;
            rs         <= 0;
            rc         <= 0;
            rb         <= 0;
            rd         <= 0;
            byte_data  <= 0;
            byte_valid <= 0;
        end else begin
            rx_sync    <= {rx_sync[0], rx};
            byte_valid <= 0;
            case (rs)
                0 :
                    if (!rx_sync[1]) begin
                        rs <= 1;
                        rc <= BIT_TICKS / 2 - 1;
                    end
                1 :
                    if (rc != 0)
                        rc <= rc - 1'b1;
                    else if (!rx_sync[1]) begin
                        rs <= 2;
                        rc <= BIT_TICKS - 1;
                        rb <= 0;
                    end else
                        rs <= 0;
                2 :
                    if (rc != 0)
                        rc <= rc - 1'b1;
                    else begin
                        rd[rb] <= rx_sync[1];
                        rc     <= BIT_TICKS - 1;
                        if (rb == 7)
                            rs <= 3;
                        else
                            rb <= rb + 1'b1;
                    end
                3 :
                    if (rc != 0)
                        rc <= rc - 1'b1;
                    else begin
                        if (rx_sync[1]) begin
                            byte_data  <= rd;
                            byte_valid <= 1;
                        end
                        rs <= 0;
                    end
            endcase
        end
    end
    function prefix                                                         // 只把合法命令首字节保留为前缀，其余字节不建立普通命令。
        (input [7 : 0] b);
        begin
            prefix = b == 8'h12 || b == 8'h23 || b == 8'h66 || b == 8'h68 || b == 8'hAA || b == 8'hAB || b == 8'h5A ||
                     b == 8'h0a || b == 8'h0b || b == 8'h0c;
        end
    endfunction
    wire match = have_first && ((first == 8'h12 && byte_data == 8'h34) || (first == 8'h23 && byte_data == 8'h45) ||
                                (first == 8'h66 && byte_data == 8'h88) || (first == 8'h68 && byte_data == 8'h68) ||
                                (first == 8'hAA && byte_data == 8'hBB) || (first == 8'hAB && byte_data == 8'hCD) ||
                                (first == 8'h5A && byte_data <= 7) || (first == 8'h0a && byte_data == 8'h0a) ||
                                (first == 8'h0b && (byte_data <= 3 || (byte_data >= 8'h10 && byte_data <= 8'h37))) ||
                                (first == 8'h0c && (byte_data <= 1 || byte_data == 8'h0c)));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            have_first    <= 0;
            first         <= 0;
            gap           <= 0;
            command_valid <= 0;
            command       <= 0;
        end else begin
            command_valid <= 0;
            if (have_first) begin
                if (gap == GAP_TICKS - 1) begin
                    have_first <= 0;
                    gap        <= 0;
                end else
                    gap <= gap + 1'b1;
            end
            if (packet_mode) begin                                          // 参数包或转向包独占时，普通命令拼接器清空，不解释包内字节。
                have_first <= 0;
                gap        <= 0;
            end else if (byte_valid) begin
                gap <= 0;
                if (match && gap < GAP_TICKS - 1) begin
                    command       <= {first, byte_data};
                    command_valid <= 1;
                    have_first    <= 0;
                end else begin
                    have_first <= prefix(byte_data);
                    first      <= byte_data;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 0;
            tx       <= 1;
            tx_shift <= 20'hfffff;
            tx_index <= 0;
            tc       <= 0;
        end else if (!busy) begin
            tx <= 1;
            if (reply_valid) begin                                          // 锁存完整应答，按高字节再低字节组织两个 UART 字节。
                tx_shift <= {1'b1, reply[7 : 0], 1'b0, 1'b1, reply[15 : 8], 1'b0};
                tx       <= 0;
                busy     <= 1;
                tx_index <= 0;
                tc       <= BIT_TICKS - 1;
            end
        end else if (tc != 0)
            tc <= tc - 1'b1;
        else if (tx_index == 19) begin
            busy <= 0;
            tx   <= 1;
        end else begin
            tx_shift <= {1'b1, tx_shift[19 : 1]};
            tx       <= tx_shift[1];
            tx_index <= tx_index + 1'b1;
            tc       <= BIT_TICKS - 1;
        end
    end
endmodule
