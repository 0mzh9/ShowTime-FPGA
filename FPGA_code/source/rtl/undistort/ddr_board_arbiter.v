`timescale 1ns/1ps
 
 
module ddr_board_arbiter                                                    // 板级 DDR 仲裁：锁存读写事务归属，将返回数据路由到对应请求方并检查事务标签。
    #(parameter A = 28, QUIESCE_ENABLE = 0)
    (                                                                       // 仲裁采集、处理与显示请求，每个方向保持一笔已登记命令。
     input wire clk, rst_n, quiesce,                                        // 处理时钟；低有效复位；停止发起新的 DDR 事务。
     output wire drained,                                                   // 在途 DDR 事务已排空。
     input wire [3 * A - 1 : 0] r_addr,
     input wire [11 : 0]        r_len, r_id,
     input wire [2 : 0]         r_valid, r_ap,
     output wire [2 : 0]        r_ready, r_return_valid,
     input wire [2 * A - 1 : 0] w_addr,
     input wire [7 : 0]         w_len, w_id,
     input wire [1 : 0]         w_valid, w_ap,
     output wire [1 : 0]        w_ready, w_request,
     input wire [511 : 0]       w_data,
     input wire [63 : 0]        w_strb,
     output wire [A - 1 : 0]    axi_araddr, axi_awaddr,                     // DDR 读字地址；DDR 写字地址。
     output wire [3 : 0] axi_arlen, axi_aruser_id, axi_awlen, axi_awuser_id,
     output wire         axi_arvalid, axi_aruser_ap, axi_awvalid, axi_awuser_ap,
     input wire          axi_arready, axi_awready,                          // DDR 接受读地址；DDR 接受写地址。
     input wire axi_rvalid, axi_rlast, axi_wready, axi_wusero_last,         // DDR 返回拍有效；当前突发最后一拍；原生 DDR 请求提供写数据；原生写数据末拍指示。
     input wire [3 : 0]    axi_rid, axi_wusero_id,
     output wire [255 : 0] axi_wdata,                                       // 原生 DDR 写数据。
     output wire [31 : 0] axi_wstrb,                                        // 原生 DDR 字节使能。
     output reg fault                                                       // 锁存的故障标志。
    );
    assign          drained  =  !r_active &&  !r_locked &&  !w_active &&  !w_locked &&  !fault;  // 停止流程用此信号确认读写均无锁定或在途事务，且没有故障。
    wire            halt_new = QUIESCE_ENABLE && quiesce;
    reg             r_active, r_locked, w_active, w_locked, w_rr, w_owner, w_lock_owner;
    reg [1 : 0]     r_owner, r_lock_owner, r_rr;
    reg [3 : 0]     expected_rid, expected_wid;
    reg [4 : 0]     r_beats, r_count, w_beats, w_count;
    reg [1 : 0]     r_select;
    reg [A - 1 : 0] read_address, write_address;
    reg [3 : 0]     read_length, read_id, write_length, write_id;
    reg             read_ap, write_ap;
    integer         k, candidate;
    always @ * begin
        r_select = r_rr;
        for (k = 2; k >= 0; k = k - 1) begin
            candidate = r_rr + k;
            if (candidate >= 3)
                candidate = candidate - 3;
            if (r_valid[candidate])
                r_select = candidate;
        end
        if (r_locked)
            r_select = r_lock_owner;
    end
    wire w_select = w_locked ? w_lock_owner : (w_valid[w_rr] ? w_rr :  !w_rr);

    assign       axi_araddr    = read_address;
    assign       axi_arlen     = read_length;
    assign       axi_aruser_id = read_id;
    assign       axi_aruser_ap = read_ap;
    assign       axi_arvalid   = rst_n &&  !fault &&  !r_active && r_locked;
    assign       axi_awaddr    = write_address;
    assign       axi_awlen     = write_length;
    assign       axi_awuser_id = write_id;
    assign       axi_awuser_ap = write_ap;
    assign       axi_awvalid   = rst_n &&  !fault &&  !w_active && w_locked;
    wire         ar = axi_arvalid && axi_arready, aw = axi_awvalid && axi_awready;
    assign       r_ready        = ar ? (3'b001 << r_select) : 3'b000;       // 只向本次真正被 DDR 接收的读申请方返回 ready。
    assign       w_ready        = aw ? (2'b01 << w_select) : 2'b00;
    wire [1 : 0] response_owner = r_active ? r_owner : r_select;
    wire         request_owner  = w_active ? w_owner : w_select;
    wire [3 : 0] rid_expected   = r_active ? expected_rid : axi_aruser_id;
    wire [3 : 0] wid_expected   = w_active ? expected_wid : axi_awuser_id;
    wire [4 : 0] rn = r_active ? r_count : 0, wn = w_active ? w_count : 0;
    wire [4 : 0] rl     = r_active ? r_beats : ({1'b0, axi_arlen} + 5'd1);
    wire [4 : 0] wl     = w_active ? w_beats : ({1'b0, axi_awlen} + 5'd1);
    wire         good_r = (r_active || ar) && axi_rid == rid_expected && axi_rlast == (rn == rl - 1'b1);
    wire         good_w = (w_active || aw) && axi_wusero_id == wid_expected && axi_wusero_last == (wn == wl - 1'b1);
    assign       r_return_valid = rst_n &&  !fault && axi_rvalid && good_r ? (3'b001 << response_owner) : 0;  // 返回数据按锁存的事务所有者分发，不使用可能已变化的当前请求选择。
    assign       w_request      = rst_n &&  !fault && axi_wready && good_w ? (2'b01 << request_owner) : 0;
    assign       axi_wdata      = w_data[request_owner * 256 +: 256];
    assign       axi_wstrb      = w_strb[request_owner * 32 +: 32];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault         <= 0;
            r_active      <= 0;
            r_locked      <= 0;
            w_active      <= 0;
            w_locked      <= 0;
            r_rr          <= 0;
            w_rr          <= 1;
            r_owner       <= 0;
            r_lock_owner  <= 0;
            w_owner       <= 0;
            w_lock_owner  <= 0;
            expected_rid  <= 0;
            expected_wid  <= 0;
            r_beats       <= 0;
            w_beats       <= 0;
            r_count       <= 0;
            w_count       <= 0;
            read_address  <= 0;
            write_address <= 0;
            read_length   <= 0;
            write_length  <= 0;
            read_id       <= 0;
            write_id      <= 0;
            read_ap       <= 0;
            write_ap      <= 0;
        end else if (!fault) begin
            if ((axi_rvalid &&  !good_r) || (axi_wready &&  !good_w))       // 返回标签或末拍与登记上下文不符时锁存异常。
                fault <= 1;
            else begin
                if (!halt_new &&  !r_active &&  !r_locked && r_valid[r_select]) begin  // 暂停新事务时仍允许原有事务排空，不再改变读端所有者。
                    r_locked     <= 1;
                    r_lock_owner <= r_select;
                    read_address <= r_addr[r_select * A +: A];
                    read_length  <= r_len[r_select * 4 +: 4];
                    read_id      <= r_id[r_select * 4 +: 4];
                    read_ap      <= r_ap[r_select];
                end
                if (!halt_new &&  !w_active &&  !w_locked && w_valid[w_select]) begin
                    w_locked      <= 1;
                    w_lock_owner  <= w_select;
                    write_address <= w_addr[w_select * A +: A];
                    write_length  <= w_len[w_select * 4 +: 4];
                    write_id      <= w_id[w_select * 4 +: 4];
                    write_ap      <= w_ap[w_select];
                end
                if (ar) begin
                    r_locked     <= 0;
                    r_active     <= 1;
                    r_owner      <= r_select;
                    expected_rid <= axi_aruser_id;
                    r_beats      <= {1'b0, axi_arlen} + 5'd1;
                    r_count      <= 0;
                end
                if (aw) begin
                    w_locked     <= 0;
                    w_active     <= 1;
                    w_owner      <= w_select;
                    expected_wid <= axi_awuser_id;
                    w_beats      <= {1'b0, axi_awlen} + 5'd1;
                    w_count      <= 0;
                end
                if (axi_rvalid && good_r) begin
                    if (axi_rlast) begin
                        r_active <= 0;
                        r_rr     <= response_owner == 2 ? 0 : response_owner + 1'b1;
                    end else
                        r_count <= rn + 1'b1;
                end
                if (axi_wready && good_w) begin
                    if (axi_wusero_last) begin
                        w_active <= 0;
                        w_rr     <=  !request_owner;
                    end else
                        w_count <= wn + 1'b1;
                end
            end
        end
    end
endmodule
