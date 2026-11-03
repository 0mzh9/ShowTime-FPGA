`timescale 1ns/1ps
 
 
module corrected_frame_manager                                              // 双结果槽所有权管理：完整结果提交后发布，被显示引用的槽不得重新分配写入。
    #(                                                                      // 管理结果槽位和读者引用，所有读取方释放后才回收。
      parameter [31 : 0] BASE_WORD = 32'h00c00000, STRIDE_WORD = 32'h00400000)  // 帧存储起始字地址；相邻帧槽之间的字地址间隔。
    (input wire clk, rst_n,                                                 // 处理时钟；低有效复位。
     input wire           write_begin_valid,                                // 申请结果帧写槽。
     output wire          write_begin_ready,                                // 可分配新的结果帧写槽。
     input wire [31 : 0]  write_begin_frame_id,
     output wire          write_begin_slot,                                 // 分配的结果槽号。
     output wire [31 : 0] write_begin_base,                                 // 结果槽的 DDR 基址。
     input wire           commit_valid,                                     // 写入端提交核验完成的结果帧。
     output wire          commit_ready,                                     // 结果管理器可以接收本次提交。
     input wire           commit_slot,
     input wire [31 : 0]  commit_frame_id,
     input wire           acquire_valid, acquire_reader,                    // 读取端申请取得完整结果帧。
     output wire          acquire_ready, acquire_slot,                      // 完整结果及其引用可以分配；取得的结果槽号。
     output wire [31 : 0] acquire_base, acquire_frame_id,                   // 取得的结果帧基址；取得结果所对应的帧号。
     input wire           release_valid, release_reader, release_slot,      // 请求释放已有帧引用。
     output wire          release_ready,                                    // 该帧引用可以释放。
     input wire [31 : 0]  release_frame_id,
     output wire          reclaim_valid, reclaim_slot,
     output reg           fault,                                            // 锁存的故障标志。
     output reg [3 : 0] fault_code,                                         // 故障类型编码。
     output wire [3 : 0] slot_states,
     output wire [1 : 0] reader_refs,
     output reg [31 : 0] published_frames);
    localparam   FREE = 0, WRITING = 1, READY = 2;
    reg [1 : 0]  ownership[0 : 1];
    reg [31 : 0] frame_id[0 : 1], last_frame_id;
    reg          writing, write_owner, latest_valid, latest;
    reg [1 : 0]  reader_active;
    reg          reader_owner[0 : 1];
    wire         refs0             = (reader_active[0] &&  !reader_owner[0]) || (reader_active[1] &&  !reader_owner[1]);
    wire         refs1             = (reader_active[0] && reader_owner[0]) || (reader_active[1] && reader_owner[1]);
    wire         free_found        = ownership[0] == FREE || ownership[1] == FREE;
    wire         free_slot         = ownership[0] != FREE;
    assign       slot_states       = {ownership[1], ownership[0]};
    assign       reader_refs       = reader_active;
    assign       write_begin_ready = rst_n &&  !fault &&  !writing && free_found;  // 写入端只能取得空闲且无显示引用的结果槽。
    assign       write_begin_slot  = free_slot;
    assign       write_begin_base  = BASE_WORD + (free_slot ? STRIDE_WORD : 0);
    assign       commit_ready      = rst_n &&  !fault && writing;
    assign       acquire_ready     = rst_n &&  !fault && latest_valid &&  !reader_active[acquire_reader];  // 读取端取得最新完整结果，并为该读者建立独立引用。
    assign       acquire_slot      = latest;
    assign       acquire_base      = BASE_WORD + (latest ? STRIDE_WORD : 0);
    assign       acquire_frame_id  = frame_id[latest];
    assign       release_ready     = rst_n &&  !fault && reader_active[release_reader];
    assign       reclaim_valid     = rst_n &&  !fault &&
                                     ((ownership[0] == READY && latest_valid && latest != 0 &&  !refs0) ||
                                      (ownership[1] == READY && latest_valid && latest != 1 &&  !refs1));
    assign       reclaim_slot      = latest == 0;
    integer      i;
    always @(posedge clk) begin
        if (!rst_n) begin
            ownership[0]     <= FREE;
            ownership[1]     <= FREE;
            frame_id[0]      <= 0;
            frame_id[1]      <= 0;
            last_frame_id    <= 0;
            writing          <= 0;
            write_owner      <= 0;
            latest_valid     <= 0;
            latest           <= 0;
            reader_active    <= 0;
            reader_owner[0]  <= 0;
            reader_owner[1]  <= 0;
            fault            <= 0;
            fault_code       <= 0;
            published_frames <= 0;
        end else if (!fault) begin
            if (write_begin_valid && write_begin_ready &&
                (write_begin_frame_id == 0 || write_begin_frame_id <= last_frame_id)) begin
                fault      <= 1;
                fault_code <= 1;
            end else if (commit_valid && commit_ready &&
                         (commit_slot != write_owner || commit_frame_id != frame_id[write_owner])) begin
                fault      <= 1;
                fault_code <= 2;
            end else if (release_valid && release_ready &&
                         (release_slot != reader_owner[release_reader] || release_frame_id != frame_id[release_slot]))
            begin
                fault      <= 1;
                fault_code <= 3;
            end else begin
                if (ownership[0] == READY && latest_valid && latest != 0 &&  !refs0)  // 旧结果既不是最新帧、也没有读取引用时才能回收。
                    ownership[0] <= FREE;
                if (ownership[1] == READY && latest_valid && latest != 1 &&  !refs1)
                    ownership[1] <= FREE;
                if (write_begin_valid && write_begin_ready) begin
                    ownership[free_slot] <= WRITING;
                    frame_id[free_slot]  <= write_begin_frame_id;
                    last_frame_id        <= write_begin_frame_id;
                    writing              <= 1;
                    write_owner          <= free_slot;
                end
                if (commit_valid && commit_ready) begin                     // 提交把写入槽转为完整可读状态，更新最新结果及其帧号。
                    ownership[write_owner] <= READY;
                    writing                <= 0;
                    latest                 <= write_owner;
                    latest_valid           <= 1;
                    published_frames       <= published_frames + 1'b1;
                end
                if (acquire_valid && acquire_ready) begin                   // 接收读取申请后保存读者引用，直至收到对应释放握手。
                    reader_active[acquire_reader] <= 1;
                    reader_owner[acquire_reader]  <= latest;
                end
                if (release_valid && release_ready)
                    reader_active[release_reader] <= 0;
            end
        end
    end
endmodule
