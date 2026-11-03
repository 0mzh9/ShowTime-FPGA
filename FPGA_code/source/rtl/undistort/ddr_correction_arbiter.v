`timescale 1ns/1ps
 
 
 
module ddr_correction_arbiter                                               // 处理侧 DDR 仲裁：在源图读取和结果核验之间分配读端口，独立管理结果写事务。
    #(parameter ADDR_WIDTH = 28)                                            // DDR 地址位宽。
    (                                                                       // 在矫正域仲裁源图读取及结果写入校验。
     input wire clk, rst_n, ddr_init_done,                                  // 处理时钟；低有效复位；DDR 初始化完成。
     input wire [ADDR_WIDTH - 1 : 0]  c_araddr, v_araddr,
     input wire [3 : 0]               c_arlen, v_arlen,
     input wire                       c_arap, v_arap, c_arvalid, v_arvalid,
     output wire                      c_arready, v_arready,
     output wire [255 : 0]            c_rdata, v_rdata,
     output wire [3 : 0]              c_rid, v_rid,
     output wire                      c_rvalid, v_rvalid, c_rlast, v_rlast,
     input wire [ADDR_WIDTH - 1 : 0]  w_awaddr,
     input wire [3 : 0]               w_awlen,
     input wire                       w_awap, w_awvalid,
     output wire                      w_awready,
     input wire [255 : 0]             w_data,
     input wire [31 : 0]              w_strb,
     output wire                      w_ready, w_last,
     output wire [3 : 0]              w_id,
     output wire [ADDR_WIDTH - 1 : 0] axi_araddr, axi_awaddr,               // DDR 读字地址；DDR 写字地址。
     output wire [3 : 0] axi_arlen, axi_aruser_id, axi_awlen, axi_awuser_id,
     output wire         axi_aruser_ap, axi_arvalid, axi_awuser_ap, axi_awvalid,
     input wire          axi_arready, axi_awready,                          // DDR 接受读地址；DDR 接受写地址。
     input wire [255 : 0] axi_rdata,                                        // 原生 DDR 返回数据。
     input wire [3 : 0] axi_rid, axi_wusero_id,
     input wire         axi_rvalid, axi_rlast, axi_wready, axi_wusero_last,  // DDR 返回拍有效；当前突发最后一拍；原生 DDR 请求提供写数据；原生写数据末拍指示。
     output wire [255 : 0] axi_wdata,                                       // 原生 DDR 写数据。
     output wire [31 : 0] axi_wstrb,                                        // 原生 DDR 字节使能。
     output reg fault,                                                      // 锁存的故障标志。
     output reg [3 : 0] fault_code                                          // 故障类型编码。
    );
    reg          read_active, read_owner, locked, lock_owner, prefer_verify, write_active;
    reg [4 : 0]  read_beats, read_count, write_beats, write_count;
    wire         selected             = locked ? lock_owner : (v_arvalid && (!c_arvalid || prefer_verify));
    wire         selected_valid       = selected ? v_arvalid : c_arvalid;
    assign       axi_arvalid          = rst_n && ddr_init_done &&  !fault &&  !read_active && selected_valid;
    assign       axi_araddr           = selected ? v_araddr : c_araddr;
    assign       axi_arlen            = selected ? v_arlen : c_arlen;
    assign       axi_aruser_ap        = selected ? v_arap : c_arap;
    assign       axi_aruser_id        = selected ? 4'h9 : 4'h8;
    wire         ar_fire              = axi_arvalid && axi_arready;
    assign       c_arready            = axi_arvalid &&  !selected && axi_arready;
    assign       v_arready            = axi_arvalid && selected && axi_arready;
    wire         response_context     = read_active || ar_fire;
    wire         response_owner       = read_active ? read_owner : selected;
    wire [4 : 0] expected_read_beats  = read_active ? read_beats : ({1'b0, axi_arlen} + 5'd1);
    wire [4 : 0] response_count       = read_active ? read_count : 5'd0;
    wire         good_read            = response_context && axi_rid == (response_owner ? 4'h9 : 4'h8) &&
                                        axi_rlast == (response_count == expected_read_beats - 1'b1);
    assign       c_rvalid             = rst_n &&  !fault && axi_rvalid && good_read &&  !response_owner;
    assign       v_rvalid             = rst_n &&  !fault && axi_rvalid && good_read && response_owner;
    assign       c_rdata              = axi_rdata;
    assign       v_rdata              = axi_rdata;
    assign       c_rid                = axi_rid;
    assign       v_rid                = axi_rid;
    assign       c_rlast              = axi_rlast;
    assign       v_rlast              = axi_rlast;
    assign       axi_awvalid          = rst_n && ddr_init_done &&  !fault &&  !write_active && w_awvalid;
    assign       axi_awaddr           = w_awaddr;
    assign       axi_awlen            = w_awlen;
    assign       axi_awuser_ap        = w_awap;
    assign       axi_awuser_id        = 9;
    assign       w_awready            = axi_awvalid && axi_awready;
    wire         aw_fire              = axi_awvalid && axi_awready;
    wire         write_context        = write_active || aw_fire;
    wire [4 : 0] expected_write_beats = write_active ? write_beats : ({1'b0, axi_awlen} + 5'd1);
    wire [4 : 0] request_count        = write_active ? write_count : 5'd0;
    wire         good_write =
                     write_context && axi_wusero_id == 9 && axi_wusero_last == (request_count == expected_write_beats - 1'b1);
    assign       w_ready   = rst_n &&  !fault && axi_wready && good_write;
    assign       w_last    = axi_wusero_last;
    assign       w_id      = axi_wusero_id;
    assign       axi_wdata = w_data;
    assign       axi_wstrb = w_strb;
    always @(posedge clk) begin
        if (!rst_n) begin
            read_active   <= 0;
            read_owner    <= 0;
            locked        <= 0;
            lock_owner    <= 0;
            prefer_verify <= 0;
            write_active  <= 0;
            read_beats    <= 0;
            read_count    <= 0;
            write_beats   <= 0;
            write_count   <= 0;
            fault         <= 0;
            fault_code    <= 0;
        end else if (!fault) begin
            if (!ddr_init_done && (read_active || write_active || locked)) begin
                fault      <= 1;
                fault_code <= 5;
            end else if (axi_rvalid &&  !good_read) begin
                fault      <= 1;
                fault_code <= response_context ? 3 : 2;
            end else if (axi_wready &&  !good_write) begin
                fault      <= 1;
                fault_code <= 4;
            end else begin
                if (axi_arvalid &&  !axi_arready) begin                     // 地址尚未被接受时锁住当前选择，满足 valid 保持期间载荷稳定。
                    locked     <= 1;
                    lock_owner <= selected;
                end
                if (ar_fire) begin
                    locked      <= 0;
                    read_active <= 1;
                    read_owner  <= selected;
                    read_beats  <= {1'b0, axi_arlen} + 5'd1;
                    read_count  <= 0;
                end
                if (axi_rvalid && good_read) begin                          // 只在合法读返回上推进拍数，末拍到达后解除占用。
                    if (axi_rlast) begin
                        read_active   <= 0;
                        read_count    <= 0;
                        prefer_verify <=  !response_owner;
                    end else
                        read_count <= response_count + 1'b1;
                end
                if (aw_fire) begin
                    write_active <= 1;
                    write_beats  <= {1'b0, axi_awlen} + 5'd1;
                    write_count  <= 0;
                end
                if (axi_wready && good_write) begin
                    if (axi_wusero_last) begin
                        write_active <= 0;
                        write_count  <= 0;
                    end else
                        write_count <= request_count + 1'b1;
                end
            end
        end
    end
endmodule
