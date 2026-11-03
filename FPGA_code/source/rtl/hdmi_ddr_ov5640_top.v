`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: Will
// 
// Create Date: 2023-03-17  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1
 
 
 
 

module hdmi_ddr_ov5640_top                                                  // 系统顶层：连接相机、DDR、几何处理、视频输出、串口控制和参数掉电保存。
    #(parameter MEM_ROW_ADDR_WIDTH = 15,
      parameter MEM_COL_ADDR_WIDTH = 10,
      parameter MEM_BADDR_WIDTH    = 3,
      parameter MEM_DQ_WIDTH       = 32,
      parameter MEM_DQS_WIDTH      = 32 / 8)
    (input sys_clk,                                                         // 板卡参考时钟。
     inout eeprom_scl, eeprom_sda,                                          // EEPROM 开漏时钟线；EEPROM 开漏数据线。
     input uart_rx,                                                         // 板卡串口接收。
     output uart_tx,                                                        // 板卡串口发送。
     input clk_p,
     input clk_n,
     //OV5640
     output [1 : 0] cmos_init_done,                                         // OV5640寄存器初始化完成
     //coms2
     inout cmos2_scl,                                                       // 摄像头 2 的 I2C 接口。
     inout cmos2_sda,                                                       // 摄像头 2 的 I2C 接口。
     input cmos2_vsync,                                                     // 摄像头 2 的场同步信号。
     input cmos2_href,                                                      // 摄像头 2 的行有效参考信号 HREF。
     input cmos2_pclk,                                                      // 摄像头 2 的像素时钟。
     input [7 : 0] cmos2_data,                                              // 摄像头 2 的数据。
     output cmos2_reset,                                                    // 摄像头 2 的复位。
     output cmos2_pwdn,
     //DDR
     output                              mem_rst_n,
     output                              mem_ck,
     output                              mem_ck_n,
     output                              mem_cke,
     output                              mem_cs_n,
     output                              mem_ras_n,
     output                              mem_cas_n,
     output                              mem_we_n,
     output                              mem_odt,
     output [MEM_ROW_ADDR_WIDTH - 1 : 0] mem_a,
     output [MEM_BADDR_WIDTH - 1 : 0]    mem_ba,
     inout [MEM_DQ_WIDTH / 8 - 1 : 0]    mem_dqs,
     inout [MEM_DQ_WIDTH / 8 - 1 : 0]    mem_dqs_n,
     inout [MEM_DQ_WIDTH - 1 : 0]        mem_dq,
     output [MEM_DQ_WIDTH / 8 - 1 : 0]   mem_dm,
     output reg                          heart_beat_led,                    // 运行心跳指示。
     output ddr_init_done,                                                  // DDR 初始化完成。
     //MS72xx       
     output rstn_out,
     output iic_tx_scl,
     inout  iic_tx_sda,
     output hdmi_int_led,                                                   // HDMI_OUT初始化完成
     //HDMI_OUT
     output pix_clk,                                                        // 像素时钟。
     output              vs_out,
     output              hs_out,
     output              de_out,
     output wire [7 : 0] r_out,
     output wire [7 : 0] g_out,
     output wire [7 : 0] b_out);
    /////////////////////////////////////////////////////////////////////////////////////
    // ENABLE_DDR
    parameter CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;  // 28
    parameter TH_1S           = 27'd33000000;
    /////////////////////////////////////////////////////////////////////////////////////
    reg [15 : 0]  rstn_1ms;
    wire          cmos_scl;                                                 // 摄像头 I2C 时钟。
    wire          cmos_sda;                                                 // 摄像头 I2C 数据。
    wire          cmos_vsync;                                               // 摄像头场同步。
    wire          cmos_href;                                                // 摄像头行有效参考信号 HREF。
    wire          cmos_pclk;                                                // 摄像头像素时钟。
    wire [7 : 0]  cmos_data;                                                // 摄像头数据。
    wire          cmos_reset;                                               // 摄像头复位。
    wire          initial_en;
    wire [15 : 0] cmos2_d_16bit /*synthesis PAP_MARK_DEBUG="1"*/;
    wire          cmos2_href_16bit /*synthesis PAP_MARK_DEBUG="1"*/;
    reg [7 : 0]   cmos2_d_d0 /*synthesis PAP_MARK_DEBUG="1"*/;
    reg           cmos2_href_d0 /*synthesis PAP_MARK_DEBUG="1"*/;
    reg           cmos2_vsync_d0 /*synthesis PAP_MARK_DEBUG="1"*/;
    wire          cmos2_pclk_16bit /*synthesis PAP_MARK_DEBUG="1"*/;
    wire [15 : 0] o_rgb565;
    wire          pclk_in_test;
    wire          vs_in_test;
    wire          de_in_test;
    wire [15 : 0] i_rgb565 /*synthesis PAP_MARK_DEBUG="1"*/;
    wire          de_re;
    //axi bus   
    wire [CTRL_ADDR_WIDTH - 1 : 0]      axi_awaddr;
    wire                                axi_awuser_ap;
    wire [3 : 0]                        axi_awuser_id;
    wire [3 : 0]                        axi_awlen;
    wire                                axi_awready; /*synthesis PAP_MARK_DEBUG="1"*/
    wire                                axi_awvalid; /*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH * 8 - 1 : 0]     axi_wdata;
    wire [MEM_DQ_WIDTH * 8 / 8 - 1 : 0] axi_wstrb;
    wire                                axi_wready; /*synthesis PAP_MARK_DEBUG="1"*/
    wire [3 : 0]                        axi_wusero_id;
    wire                                axi_wusero_last;
    wire [CTRL_ADDR_WIDTH - 1 : 0]      axi_araddr;
    wire                                axi_aruser_ap;
    wire [3 : 0]                        axi_aruser_id;
    wire [3 : 0]                        axi_arlen;
    wire                                axi_arready; /*synthesis PAP_MARK_DEBUG="1"*/
    wire                                axi_arvalid; /*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH * 8 - 1 : 0]     axi_rdata /* synthesis syn_keep = 1 */;
    wire                                axi_rvalid /* synthesis syn_keep = 1 */;
    wire [3 : 0]                        axi_rid;
    wire                                axi_rlast;
    reg [26 : 0]                        cnt;
    reg [15 : 0]                        cnt_1;
    /////////////////////////////////////////////////////////////////////////////////////
    //PLL
    wire          camera_clocks_ready = locked;
    wire          mode1080, pipe_enable, quiesce, video_hold, config_hold;
    wire          video_clk, video_clk_pll, tx_phase_clk, video_locked, clock_ready, clock_epoch;
    wire          pll_reset, pll_apb_ready, pll_sel, pll_en, pll_write, pll_fault;
    wire [4 : 0]  pll_addr;
    wire [15 : 0] pll_wdata, pll_rdata;
    wire          pipeline_reset_n, video_reset_n, config_reset_n, control_reset_n;
    wire          pipeline_drained;
    (* syn_preserve=1, async_reg="true" *) reg [1 : 0] mode_core_sync, mode_video_sync, mode_cfg_sync;
    always @(posedge core_clk or negedge control_reset_n)                   // 将分辨率选择同步到处理时钟域；其余域使用独立同步链。
        if (!control_reset_n)
            mode_core_sync <= 0;
        else
            mode_core_sync <= {mode_core_sync[0], mode1080};
    always @(posedge video_clk or negedge control_reset_n)
        if (!control_reset_n)
            mode_video_sync <= 0;
        else
            mode_video_sync <= {mode_video_sync[0], mode1080};
    always @(posedge cfg_clk or negedge control_reset_n)
        if (!control_reset_n)
            mode_cfg_sync <= 0;
        else
            mode_cfg_sync <= {mode_cfg_sync[0], mode1080};
    reg [1 : 0]                             q_core;
    wire                                    command_valid, reply_valid, reply_ready;
    wire                                    pan_packet_mode, pan_busy, pan_reply_valid, reply_mux_ready, pan_request;
    wire [15 : 0]                           pan_reply, pan_sequence;
    wire signed [15 : 0]                    pan_angle;
    wire                                    display_pan_seen;
    wire [64 : 0]                           display_pan;
    (* async_reg="true" *) reg [2 : 0]  pan_request_core, pan_seen_sys;
    (* async_reg="true" *) reg [15 : 0] pan_angle_meta, pan_angle_core, pan_sequence_meta, pan_sequence_core;
    (* async_reg="true" *) reg [64 : 0] pan_display_meta, pan_display_sys;
    reg [64 : 0]                            pan_display_stable;
    always @(posedge core_clk or negedge control_reset_n) begin             // 转向序号及角度先寄存两拍，再由三级请求翻转同步链触发使用。
        if (!control_reset_n) begin
            pan_request_core  <= 0;
            pan_angle_meta    <= 0;
            pan_angle_core    <= 0;
            pan_sequence_meta <= 0;
            pan_sequence_core <= 0;
        end else begin
            pan_request_core  <= {pan_request_core[1 : 0], pan_request};
            pan_angle_meta    <= pan_angle;
            pan_angle_core    <= pan_angle_meta;
            pan_sequence_meta <= pan_sequence;
            pan_sequence_core <= pan_sequence_meta;
        end
    end
    always @(posedge sys_clk or negedge control_reset_n) begin
        if (!control_reset_n) begin
            pan_seen_sys       <= 0;
            pan_display_meta   <= 0;
            pan_display_sys    <= 0;
            pan_display_stable <= 0;
        end else begin
            pan_seen_sys     <= {pan_seen_sys[1 : 0], display_pan_seen};
            pan_display_meta <= display_pan;
            pan_display_sys  <= pan_display_meta;
            if (pan_display_sys == pan_display_meta)
                pan_display_stable <= pan_display_sys;
        end
    end
    assign          reply_ready = reply_mux_ready &&  !pan_reply_valid;     // 转向事务应答优先取得串口出口，其余控制等待同一发送器空闲。
    pan_control_v15 pan_control(.clk(sys_clk),                              // 虚拟转向串口事务：检查请求序号、角度和 CRC，以目标矫正帧输出作为成功依据。
                                .rst_n(control_reset_n),                    // 角度命令需等目标帧实际输出后才返回成功。
                                .command_valid(command_valid &&  !calibration_packet_mode),
                                .command(command),
                                .received_valid(received_valid),
                                .received_byte(received_byte),
                                .enabled(calibration_ready &&  !calibration_busy && calibration_payload[0] &&
                                         control_state == 4 &&  !mode1080 &&  !status_fault[1]),
                                .display_seen(pan_seen_sys[2]),
                                .display_pan(pan_display_stable),
                                .packet_mode(pan_packet_mode),
                                .busy(pan_busy),
                                .reply_valid(pan_reply_valid),
                                .reply(pan_reply),
                                .reply_ready(reply_mux_ready),
                                .request(pan_request),
                                .target_angle(pan_angle),
                                .target_sequence(pan_sequence));
    wire [95 : 0]   camera_diagnostic;
    wire [3 : 0]    control_state;
    wire            uart_reply_valid, uart_reply_ready;
    wire            calibration_packet_mode, received_valid, video_command_valid, video_reply_valid, video_reply_ready;
    wire [7 : 0]    received_byte;
    wire [15 : 0]   video_command, video_reply;
    wire            calibration_boot, calibration_busy, calibration_done, calibration_update, calibration_ready;
    wire [7 : 0]    calibration_error;
    wire [783 : 0]  calibration_packet;
    wire [639 : 0]  calibration_payload, calibration_core;
    wire [31 : 0]   calibration_sequence;
    wire            calibration_request, calibration_ack;
    wire            ee_valid, ee_write, ee_ready, ee_done, ee_error;
    wire [7 : 0]    ee_address, ee_wdata, ee_rdata;
    wire [15 : 0]   uart_reply;
    wire            gamma_enable, gamma_epoch, display_gamma_seen, display_gamma_enable, display_gamma_epoch;
    (* syn_preserve=1, async_reg="true" *) reg [1 : 0] gamma_en_core;
    (* syn_preserve=1, async_reg="true" *) reg [2 : 0] gamma_epoch_core;
    (* syn_preserve=1, async_reg="true" *) reg [1 : 0] gamma_en_sys;
    (* syn_preserve=1, async_reg="true" *) reg [2 : 0] gamma_seen_sys, gamma_epoch_sys;
    reg                                                      gamma_applied_core, gamma_tag_core;

    always @(posedge core_clk or negedge control_reset_n)
        if (!control_reset_n) begin
            gamma_en_core      <= 0;
            gamma_epoch_core   <= 0;
            gamma_applied_core <= 0;
            gamma_tag_core     <= 0;
        end else begin
            gamma_en_core    <= {gamma_en_core[0], gamma_enable};
            gamma_epoch_core <= {gamma_epoch_core[1 : 0], gamma_epoch};
            if (gamma_epoch_core[2] != gamma_tag_core) begin
                gamma_applied_core <= gamma_en_core[1];
                gamma_tag_core     <= gamma_epoch_core[2];
            end
        end
    always @(posedge sys_clk or negedge control_reset_n)
        if (!control_reset_n) begin
            gamma_seen_sys  <= 0;
            gamma_en_sys    <= 0;
            gamma_epoch_sys <= 0;
        end else begin
            gamma_seen_sys  <= {gamma_seen_sys[1 : 0], display_gamma_seen};
            gamma_en_sys    <= {gamma_en_sys[0], display_gamma_enable};
            gamma_epoch_sys <= {gamma_epoch_sys[1 : 0], display_gamma_epoch};
        end
    wire [15 : 0]                                            command, reply;
    (* syn_preserve=1, async_reg="true" *) reg [1 : 0] status_ddr, status_camera, status_drain, status_frame,
                                                             status_config, status_fault;
    reset_release                                            control_reset(.clk(sys_clk),  // 复位异步拉低、三级寄存器同步释放，供各自时钟域独立使用。
                                                                           .async_n(locked),
                                                                           .reset_n(control_reset_n));
    reset_release                                            pipeline_reset(.clk(core_clk),  // 复位异步拉低、三级寄存器同步释放，供各自时钟域独立使用。
                                                                            .async_n(ddr_init_done && pipe_enable),
                                                                            .reset_n(pipeline_reset_n));
    reset_release timing_reset(.clk(video_clk),                             // 复位异步拉低、三级寄存器同步释放，供各自时钟域独立使用。
                               .async_n(video_locked && clock_ready &&  !video_hold),
                               .reset_n(video_reset_n));
    reset_release hdmi_config_reset(.clk(cfg_clk),                          // 复位异步拉低、三级寄存器同步释放，供各自时钟域独立使用。
                                    .async_n(rstn_out &&  !config_hold),
                                    .reset_n(config_reset_n));
    always @(posedge core_clk or negedge control_reset_n)
        if (!control_reset_n)
            q_core <= 2'b11;
        else
            q_core <= {q_core[0], quiesce};
    always @(posedge sys_clk or negedge control_reset_n) begin
        if (!control_reset_n) begin
            status_ddr    <= 0;
            status_camera <= 0;
            status_drain  <= 0;
            status_frame  <= 0;
            status_config <= 0;
            status_fault  <= 0;
        end else begin
            status_ddr    <= {status_ddr[0], ddr_init_done};
            status_camera <= {status_camera[0], cmos_init_done[1]};
            status_drain  <= {status_drain[0], pipeline_drained};
            status_frame  <= {status_frame[0], init_done};
            status_config <= {status_config[0], init_over_tx};
            status_fault  <= {status_fault[0], correction_fault};
        end
    end
    uart_command_port uart(.clk(sys_clk),                                   // UART 字节收发及双字节命令拼接；数据包接收期间将原始字节交给事务模块。
                           .rst_n(control_reset_n),
                           .rx(uart_rx),
                           .tx(uart_tx),
                           .packet_mode(calibration_packet_mode || pan_packet_mode),
                           .received_valid(received_valid),
                           .received_byte(received_byte),
                           .command_valid(command_valid),
                           .command(command),
                           .reply_valid(uart_reply_valid),
                           .reply(uart_reply),
                           .reply_ready(uart_reply_ready));
    uart_diagnostics  diagnostics(.clk(sys_clk),                            // 诊断快照读取与控制应答复用：控制应答优先，诊断按锁存快照分段返回。
                                  .rst_n(control_reset_n),
                                  .command_valid(command_valid &&  !pan_busy),
                                  .command(command),
                                  .live_status({4'h9, control_state, status_ddr[1], status_camera[1], status_fault[1],
                                                status_frame[1], status_config[1], clock_ready, pipe_enable, quiesce}),
                                  .camera_status(camera_diagnostic),
                                  .control_valid(reply_valid || pan_reply_valid),
                                  .control_reply(pan_reply_valid ? pan_reply : reply),
                                  .control_ready(reply_mux_ready),
                                  .uart_ready(uart_reply_ready),
                                  .uart_valid(uart_reply_valid),
                                  .uart_reply(uart_reply));
    calibration_control coefficient_control(.clk(sys_clk),                  // 标定事务总控：协调视频停止、CAL1 接收、EEPROM 保存、跨域提交和应答。
                                            .rst_n(control_reset_n),
                                            .command_valid(command_valid && command[15 : 8] != 8'h0c &&  !pan_busy),
                                            .command(command),
                                            .received_valid(received_valid),
                                            .received_byte(received_byte),
                                            .packet_mode(calibration_packet_mode),
                                            .video_command_valid(video_command_valid),
                                            .video_command(video_command),
                                            .video_reply_valid(video_reply_valid),
                                            .video_reply(video_reply),
                                            .video_reply_ready(video_reply_ready),
                                            .video_state(control_state),
                                            .reply_valid(reply_valid),
                                            .reply(reply),
                                            .reply_ready(reply_ready),
                                            .store_boot_ready(calibration_boot),
                                            .store_busy(calibration_busy),
                                            .store_done(calibration_done),
                                            .store_error(calibration_error),
                                            .active_sequence(calibration_sequence),
                                            .active_payload(calibration_payload),
                                            .store_update(calibration_update),
                                            .update_packet(calibration_packet),
                                            .commit_request(calibration_request),
                                            .commit_ack(calibration_ack),
                                            .ready(calibration_ready));
    calibration_store   coefficient_store(.clk(sys_clk),                    // 24LC02 双槽参数管理：启动择新加载，更新先写备用槽、读回核对再提交。
                                          .rst_n(control_reset_n),
                                          .update(calibration_update),      // 上电读取或事务更新 EEPROM 中的标定参数。
                                          .update_packet(calibration_packet),
                                          .boot_ready(calibration_boot),
                                          .busy(calibration_busy),
                                          .done(calibration_done),
                                          .error_code(calibration_error),
                                          .active_payload(calibration_payload),
                                          .active_sequence(calibration_sequence),
                                          .active_present(),
                                          .active_slot(),
                                          .bus_valid(ee_valid),
                                          .bus_write(ee_write),
                                          .bus_addr(ee_address),
                                          .bus_wdata(ee_wdata),
                                          .bus_ready(ee_ready),
                                          .bus_done(ee_done),
                                          .bus_error(ee_error),
                                          .bus_rdata(ee_rdata));
    eeprom_byte_port    coefficient_eeprom(.clk(sys_clk),                   // EEPROM 单字节读写封装：锁存地址和数据，将 I2C 完成及超时统一返回上层。
                                           .rst_n(control_reset_n),
                                           .valid(ee_valid),
                                           .write_byte(ee_write),
                                           .address(ee_address),
                                           .wdata(ee_wdata),
                                           .ready(ee_ready),
                                           .done(ee_done),
                                           .error(ee_error),
                                           .rdata(ee_rdata),
                                           .scl(eeprom_scl),
                                           .sda(eeprom_sda));
    calibration_cdc     coefficient_commit(.sys_clk(sys_clk),               // 标定总线跨时钟传递：源端保持载荷，目标端识别请求翻转后整组锁存并返回确认。
                                           .core_clk(core_clk),
                                           .rst_n(control_reset_n),
                                           .request(calibration_request),
                                           .payload(calibration_payload),
                                           .ack(calibration_ack),
                                           .core_payload(calibration_core));
    video_mode_control #(.GAMMA_ENABLE(1))                                  // 视频会话状态机：依次完成停止排空、模式配置、启动及帧级 Gamma 确认。
        control(.gamma_enable(gamma_enable),
                .gamma_epoch(gamma_epoch),                                  // 统一协调停止、模式切换与 Gamma 状态确认。
                .display_gamma_seen(gamma_seen_sys[2]),
                .display_gamma_enable(gamma_en_sys[1]),
                .display_gamma_epoch(gamma_epoch_sys[2]),
                .clk(sys_clk),
                .rst_n(control_reset_n),
                .command_valid(video_command_valid),
                .command(video_command),
                .reply_valid(video_reply_valid),
                .reply(video_reply),
                .reply_ready(video_reply_ready),
                .ddr_ready(status_ddr[1]),
                .camera_ready(status_camera[1]),
                .drained(status_drain[1]),
                .frame_ready(status_frame[1]),
                .clock_ready(clock_ready),
                .clock_epoch(clock_epoch),
                .video_configured(status_config[1]),
                .pipeline_fault(status_fault[1]),
                .mode1080(mode1080),
                .pipe_enable(pipe_enable),
                .quiesce(quiesce),
                .video_hold(video_hold),
                .config_hold(config_hold),
                .running(),
                .state(control_state));

    assign           video_clk_pll = video_clk;                             // 动态 PLL 的像素时钟用于扫描时序及 HDMI 输出，不改变 125 MHz 核心处理时钟。
    pll              u_pll(.clkin1(sys_clk),
                           .clkout1(cfg_clk),
                           .clkout2(clk_25M),
                           .lock(locked));
    video_pll_config clock_control(.clk(sys_clk),                           // 经 APB 顺序写入并核对 PLL 配置，释放复位后等待目标视频时钟锁定。
                                   .rst_n(control_reset_n),
                                   .epoch(clock_epoch),
                                   .mode1080(mode1080),
                                   .locked(video_locked),
                                   .pll_reset(pll_reset),
                                   .ready(clock_ready),
                                   .fault(pll_fault),
                                   .apb_ready(pll_apb_ready),
                                   .apb_rdata(pll_rdata),
                                   .apb_addr(pll_addr),
                                   .apb_wdata(pll_wdata),
                                   .apb_sel(pll_sel),
                                   .apb_en(pll_en),
                                   .apb_write(pll_write));
    video_pll        u_video_pll(.clkin1(sys_clk),                          // 视频 PLL 及动态配置接口封装；输出像素时钟和锁定状态。
                                 .rst(pll_reset),
                                 .apb_rst_n(control_reset_n),
                                 .clkout0(video_clk),
                                 .clkout3(tx_phase_clk),
                                 .locked(video_locked),
                                 .apb_ready(pll_apb_ready),
                                 .apb_rdata(pll_rdata),
                                 .apb_addr(pll_addr),
                                 .apb_wdata(pll_wdata),
                                 .apb_sel(pll_sel),
                                 .apb_en(pll_en),
                                 .apb_write(pll_write));

    //配置7210
    wire       init_over_tx;
    ms72xx_ctl ms72xx_ctl(.clk(cfg_clk),                                    // input       clk,
                          .mode1080(mode_cfg_sync[1]),
                          .rst_n(config_reset_n),                           // input       rstn,
                          .init_over(init_over_tx),                         // output      init_over,
                          .init_over_rx(init_over_rx),                      // output      init_over,
                          //        .iic_tx_scl      (  iic_tx_scl     ), //output      iic_scl,
                          //        .iic_tx_sda      (  iic_tx_sda     ), //inout       iic_sda
                          .iic_scl(iic_tx_scl),                             // output      iic_scl,
                          .iic_sda(iic_tx_sda)                              // 双向       iic_sda
               );
    //   assign    hdmi_int_led    =    init_over_tx; 

    always @(posedge cfg_clk) begin
        if (!locked)
            rstn_1ms <= 16'd0;
        else begin
            if (rstn_1ms == 16'h2710)
                rstn_1ms <= rstn_1ms;
            else
                rstn_1ms <= rstn_1ms + 1'b1;
        end
    end

    assign rstn_out = (rstn_1ms == 16'h2710);

    //配置CMOS///////////////////////////////////////////////////////////////////////////////////
    //OV5640 register configure enable    

    power_on_delay #(.CLOCK_HZ(24750000))                                   // 相机上电时序：先保持复位，再延迟释放并等待器件稳定。
        power_on_delay_inst(.clk_50M(clk_25M),
                            .reset_n(camera_clocks_ready),                  // 输入
                            .camera1_rstn(),                                // 输出
                            .camera2_rstn(cmos2_reset),                     // 输出
                            .camera_pwnd(cmos2_pwdn),                       // 输出
                            .initial_en(initial_en)                         // 输出
        );

    wire   camera_config_error;
    assign cmos_init_done[0] = camera_config_error;
    //CMOS2 Camera 
    reg_config coms2_reg_config(.clk_25M(clk_25M),                          // 输入
                                .camera_rstn(cmos2_reset),                  // 输入
                                .initial_en(initial_en),                    // 输入
                                .i2c_sclk(cmos2_scl),                       // 输出
                                .i2c_sdat(cmos2_sda),                       // 双向端口
                                .reg_conf_done(cmos_init_done[1]),          // 输出 config_finished
                                .config_error(camera_config_error),
                                .reg_index(),
                                .sensor_id(),
                                .error_code(),
                                .debug_status(camera_diagnostic));
    //CMOS 8bit转16bit///////////////////////////////////////////////////////////////////////////////////

    reg [1 : 0] camera_ready_sync;
    wire        camera_ready_async = cmos_init_done[1] && ddr_init_done && cmos2_reset;
    always @(posedge cmos2_pclk or negedge camera_ready_async) begin        // 相机初始化或外部复位失效时，采集域同步撤销运行资格。
        if (!camera_ready_async)
            camera_ready_sync <= 0;
        else
            camera_ready_sync <= {camera_ready_sync[0], 1'b1};
    end
    //CMOS2
    always @(posedge cmos2_pclk) begin                                      // 在相机像素时钟域寄存 DVP 数据及同步信号，再交给字节拼接模块。
        cmos2_d_d0     <= cmos2_data;
        cmos2_href_d0  <= cmos2_href;
        cmos2_vsync_d0 <= cmos2_vsync;
    end

    cmos_8_16bit cmos2_8_16bit(.pclk(cmos2_pclk),                           // 输入
                               .rst_n(camera_ready_sync[1]),                // 输入
                               .pdata_i(cmos2_d_d0),                        // 输入[7:0]
                               .de_i(cmos2_href_d0),                        // 输入
                               .vs_i(cmos2_vsync_d0),                       // 输入

                               .pixel_clk(cmos2_pclk_16bit),                // 输出
                               .pdata_o(cmos2_d_16bit),                     // 输出[15:0]
                               .de_o(cmos2_href_16bit)                      // 输出
                 );
    //输入视频源选择//////////////////////////////////////////////////////////////////////////////////////////
    assign pclk_in_test = cmos2_pclk_16bit;
    assign vs_in_test   = cmos2_vsync_d0;
    assign de_in_test   = cmos2_href_16bit;
    assign i_rgb565     = cmos2_d_16bit;                                    // 保持摄像头 RGB565 原有红绿蓝通道顺序。

    assign hdmi_int_led = init_done &&  !correction_fault;
    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    //修改ddr读写模块v1
    wire correction_fault;
    camera_correction_bridge #(.PAN_ENABLE(1),                              // 采集到显示的板级桥接：跨域收帧、整帧管理、处理、DDR 仲裁及 HDMI 读出。
                               .RUNTIME_CALIBRATION(1),
                               .GAMMA_ENABLE(1),
                               .DYNAMIC_MODE(1),
                               .A(CTRL_ADDR_WIDTH),
                               .PERF_ENABLE(1),
                               .PERF_DVP(1),
                               .SPLIT_ENABLE(1),
                               .ALTERNATE_ENABLE(1))
        frame_pipeline(                                                     // 连接采集、DDR、FPGA 处理与 HDMI 显示链。
                .calibration(calibration_core),
                .pan_request(pan_request_core[2]),
                .pan_angle(pan_angle_core),
                .pan_sequence(pan_sequence_core),
                .display_pan_seen(display_pan_seen),
                .display_pan(display_pan),
                .gamma_enable(gamma_applied_core),
                .gamma_epoch(gamma_tag_core),
                .display_gamma_seen(display_gamma_seen),
                .display_gamma_enable(display_gamma_enable),
                .display_gamma_epoch(display_gamma_epoch),
                .mode1080(mode_core_sync[1]),
                .mode1080_pixel(mode_video_sync[1]),
                .quiesce(q_core[1]),
                .drained(pipeline_drained),
                .clk(core_clk),
                .rst_n(pipeline_reset_n),

                .perf_dvp_clk(cmos2_pclk),
                .perf_dvp_vsync(cmos2_vsync_d0),
                .perf_dvp_href(cmos2_href_d0),
                .perf_camera_initialized(cmos_init_done[1]),
                .cam_clk(pclk_in_test),
                .cam_vsync(vs_in_test),
                .cam_de(de_in_test),
                .cam_pixel(i_rgb565),
                .pix_clk(video_clk),
                .display_vsync(vs_o),
                .display_de(de_re),
                .display_pixel(o_rgb565),
                .display_pixel_de(de_o),
                .init_done(init_done),
                .fault(correction_fault),
                .axi_awaddr(axi_awaddr),
                .axi_awuser_id(axi_awuser_id),
                .axi_awlen(axi_awlen),
                .axi_awuser_ap(axi_awuser_ap),
                .axi_awvalid(axi_awvalid),
                .axi_awready(axi_awready),
                .axi_wdata(axi_wdata),
                .axi_wstrb(axi_wstrb),
                .axi_wready(axi_wready),
                .axi_wusero_id(axi_wusero_id),
                .axi_wusero_last(axi_wusero_last),
                .axi_araddr(axi_araddr),
                .axi_aruser_id(axi_aruser_id),
                .axi_arlen(axi_arlen),
                .axi_aruser_ap(axi_aruser_ap),
                .axi_arvalid(axi_arvalid),
                .axi_arready(axi_arready),
                .axi_rdata(axi_rdata),
                .axi_rid(axi_rid),
                .axi_rvalid(axi_rvalid),
                .axi_rlast(axi_rlast));

    hdmi_tx_output hdmi_output(.video_clk(video_clk_pll),                   // HDMI 并行输出寄存：像素与同步信号一起打一拍，再拆分 RGB565 颜色通道。
                               .tx_phase_clk(tx_phase_clk),
                               .rgb565(o_rgb565),
                               .de(timing_de),
                               .hs(hs_o),
                               .vs(vs_o),
                               .tx_clk(pix_clk),
                               .r(r_out),
                               .g(g_out),
                               .b(b_out),
                               .tx_de(de_out),
                               .tx_hs(hs_out),
                               .tx_vs(vs_out));
    /////////////////////////////////////////////////////////////////////////////////////
    //产生visa时序 
    wire timing_de;
    sync_vg #(.DYNAMIC_MODE(1),                                             // 视频扫描时序：根据总周期、同步宽度和前后沿生成行场同步及有效区坐标。
              .H_TOTAL(2200),
              .H_FP(88),
              .H_BP(148),
              .H_SYNC(44),
              .H_ACT(1920),
              .V_TOTAL(1125),
              .V_FP(4),
              .V_BP(36),
              .V_SYNC(5),
              .V_ACT(1080))
        sync_vg(.mode1080(mode_video_sync[1]),
                .clk(video_clk),                                            // input                   clk,
                .rstn(video_reset_n),                                       // input                   rstn,
                .vs_out(vs_o),                                              // output reg              vs_out,
                .hs_out(hs_o),                                              // output reg              hs_out,
                .de_out(timing_de),                                         // output reg              de_out,
                .de_re(de_re));
    ////////////////////////////////////////////////////////////////////////////////////////////
    //ddr    

    wire clk_125Mhz;

    GTP_INBUFGDS #(.IOSTANDARD("DEFAULT"),
                   .TERM_DIFF("ON"))
              u_gtp(.O(clk_125Mhz),                                         // 输出
                    .I(clk_p),                                              // 输入
                    .IB(clk_n)                                              // 输入
              );
    ddr3_test u_ddr3_test_h(.ref_clk(clk_125Mhz),
                            .resetn(rstn_out),                              // 输入
                            .ddr_init_done(ddr_init_done),                  // 输出

                            .pll_lock(pll_lock),                            // 输出

                            .core_clk(core_clk),                            // 输出

                            .phy_pll_lock(phy_pll_lock),                    // 输出
                            .gpll_lock(gpll_lock),                          // 输出
                            .rst_gpll_lock(rst_gpll_lock),                  // 输出
                            .ddrphy_cpd_lock(ddrphy_cpd_lock),              // 输出
                            //.ddr_init_done             (ddr_init_done),                        // output

                            .axi_awaddr(axi_awaddr),                        // 输入 [27:0]
                            .axi_awuser_ap(1'b0),                           // 输入
                            .axi_awuser_id(axi_awuser_id),                  // 输入 [3:0]
                            .axi_awlen(axi_awlen),                          // 输入 [3:0]
                            .axi_awready(axi_awready),                      // 输出
                            .axi_awvalid(axi_awvalid),                      // 输入
                            .axi_wdata(axi_wdata),
                            .axi_wstrb(axi_wstrb),                          // 输入 [31:0]
                            .axi_wready(axi_wready),                        // 输出
                            .axi_wusero_id(axi_wusero_id),                  // 输出 [3:0]
                            .axi_wusero_last(axi_wusero_last),              // 输出
                            .axi_araddr(axi_araddr),                        // 输入 [27:0]
                            .axi_aruser_ap(1'b0),                           // 输入
                            .axi_aruser_id(axi_aruser_id),                  // 输入 [3:0]
                            .axi_arlen(axi_arlen),                          // 输入 [3:0]
                            .axi_arready(axi_arready),                      // 输出
                            .axi_arvalid(axi_arvalid),                      // 输入
                            .axi_rdata(axi_rdata),                          // 输出 [255:0]
                            .axi_rid(axi_rid),                              // 输出 [3:0]
                            .axi_rlast(axi_rlast),                          // 输出
                            .axi_rvalid(axi_rvalid),                        // 输出

                            .apb_clk(1'b0),                                 // 输入
                            .apb_rst_n(1'b1),                               // 输入
                            .apb_sel(1'b0),                                 // 输入
                            .apb_enable(1'b0),                              // 输入
                            .apb_addr(8'b0),                                // 输入 [7:0]
                            .apb_write(1'b0),                               // 输入
                            .apb_ready(),                                   // 输出
                            .apb_wdata(16'b0),                              // 输入 [15:0]
                            .apb_rdata(),                                   // 输出 [15:0]
                            //             .apb_int                   (                   ),// output

                            .mem_rst_n(mem_rst_n),                          // 输出
                            .mem_ck(mem_ck),                                // 输出
                            .mem_ck_n(mem_ck_n),                            // 输出
                            .mem_cke(mem_cke),                              // 输出
                            .mem_cs_n(mem_cs_n),                            // 输出
                            .mem_ras_n(mem_ras_n),                          // 输出
                            .mem_cas_n(mem_cas_n),                          // 输出
                            .mem_we_n(mem_we_n),                            // 输出
                            .mem_odt(mem_odt),                              // 输出
                            .mem_a(mem_a),                                  // 输出 [14:0]
                            .mem_ba(mem_ba),                                // 输出 [2:0]
                            .mem_dqs(mem_dqs),                              // 双向 [3:0]
                            .mem_dqs_n(mem_dqs_n),                          // 双向 [3:0]
                            .mem_dq(mem_dq),                                // 双向 [31:0]
                            .mem_dm(mem_dm),                                // 输出 [3:0]
                            //debug

                            .dbg_gate_start(1'b0),                          // 输入
                            .dbg_cpd_start(1'b0),                           // 输入
                            .dbg_ddrphy_rst_n(1'b1),                        // 输入
                            .dbg_gpll_scan_rst(1'b0),                       // 输入
                            .samp_position_dyn_adj(1'b0),                   // 输入
                            .init_samp_position_even(32'd0),                // 输入 [31:0]
                            .init_samp_position_odd(32'd0),                 // 输入 [31:0]
                            .wrcal_position_dyn_adj(1'b0),                  // 输入
                            .init_wrcal_position(32'd0),                    // 输入 [31:0]
                            .force_read_clk_ctrl(1'b0),                     // 输入
                            .init_slip_step(16'd0),                         // 输入 [15:0]
                            .init_read_clk_ctrl(12'd0),                     // 输入 [11:0]
                            .debug_calib_ctrl(),                            // 输出 [33:0]
                            .dbg_slice_status(),                            // 输出 [67:0]
                            .dbg_slice_state(),                             // 输出 [87:0]
                            .debug_data(),                                  // 输出 [275:0]
                            .dbg_dll_upd_state(),                           // 输出 [1:0]
                            .debug_gpll_dps_phase(),                        // 输出 [8:0]
                            .dbg_rst_dps_state(),                           // 输出 [2:0]
                            .dbg_tran_err_rst_cnt(),                        // 输出 [5:0]
                            .dbg_ddrphy_init_fail(),                        // 输出
                            .debug_cpd_offset_adj(1'b0),                    // 输入
                            .debug_cpd_offset_dir(1'b0),                    // 输入
                            .debug_cpd_offset(10'd0),                       // 输入 [9:0]
                            .debug_dps_cnt_dir0(),                          // 输出 [9:0]
                            .debug_dps_cnt_dir1(),                          // 输出 [9:0]
                            .ck_dly_en(1'b0),                               // 输入
                            .init_ck_dly_step(8'h0),                        // 输入 [7:0]
                            .ck_dly_set_bin(),                              // 输出 [7:0]
                            .align_error(),                                 // 输出
                            .debug_rst_state(),                             // 输出 [3:0]
                            .debug_cpd_state()                              // 输出 [3:0]
              );
    //心跳信号
    always @(posedge core_clk) begin
        if (!ddr_init_done)
            cnt <= 27'd0;
        else if (cnt >= TH_1S)
            cnt <= 27'd0;
        else
            cnt <= cnt + 27'd1;
    end

    always @(posedge core_clk) begin
        if (!ddr_init_done)
            heart_beat_led <= 1'd1;
        else if (cnt >= TH_1S)
            heart_beat_led <=  ~heart_beat_led;
    end

    /////////////////////////////////////////////////////////////////////////////////////
endmodule
