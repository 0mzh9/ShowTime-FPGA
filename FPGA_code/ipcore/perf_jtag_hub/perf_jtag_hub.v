

module perf_jtag_hub
 #(

parameter CTRL_PORT_NUM = 1, //@IPC int 1,15 //the number of usr_app connect with jtag_hub

parameter UJTAG_SEL = 0 // 1 表示使用 jtagif，0 表示使用扫描链。

 )
 (
   
   input              resetn_i ,                 // 来自用户逻辑器件的硬件复位，低电平有效。
  // for user_app interface(dvio,etc)
   output             drck_o,                    // 向各用户应用转发 TCK。
   output             hub_tdi,                   // 向各用户应用转发 TDI。
   output             capt_o,                    // 采集
   output             shift_o,                   // 移位
   output     [14:0]  conf_sel,                  // 根据标识号选择配置模块。
   output     [8:0]   id_o,                      // 标识号指示。
   input      [14:0]  hub_tdo                    // 来自各用户应用的读回信号。
 );  
 

localparam PGT_DEVICE_30G = 0; //@IPC bool

localparam PGT_DEVICE = 0; //@IPC bool

localparam PGL_DEVICE = 0; //@IPC bool


wire capture,drck1,reset,sel1,shift,update,tdi1,tdo1; 

    
GTP_SCANCHAIN_E1 u_GTP_SCANCHAIN(
     
     .TCK(),
     .TDI(),
     .TMS(),
     .TDO(),
     .CAPDR(capture),
        
     .JCLK(), 
     .TCK_USER(drck1),                   // 器件为 pgl22g 时，由 TCK_USER 输出时钟；原记录日期 2017-11-14。
     .TMS_USER(),
     .JRTI(),
     
     .RST(reset),
     .FLG_USER(sel1),
     .SHFTDR(shift),
     .TDI_USER(tdi1),             
     .UPDR(update),  
     .TDO_USER(tdo1)                                                            
)/* synthesis syn_noprune = 1 */;

wire [15:0] conf_sel_s;
wire [15:0] hub_tdo_s;
wire shift_d;

ips_dvio_jtag_hub_v1_0
 #(
 .CTRL_PORT_NUM  (CTRL_PORT_NUM),          // 连接到 jtag_hub 的用户应用数量。
 .UJTAG_SEL      (UJTAG_SEL)              // 1 表示使用 jtagif，0 表示使用扫描链。
 )                               
 u_ips_dvio_jtag_hub(
   // for user jtagif 
   
  // for JTAG_interface
   
   .drck_in      (drck1),                // 用户数据寄存器的 TCK。
   .tdi_in       (tdi1),                 // 用户数据寄存器的 TDI。
   
   .tdo_out      (tdo1),                 // 用户数据寄存器的 TDO。
   .reset_dr     (reset),	               // TAP 处于 e_TEST_LOGIC_RESET 状态时产生高有效复位。
    
   .shift_in     (shift),	               // TAP 处于 e_SHIFT_DR 状态；器件不是 pgt30g 时执行移位。
        
   .update_in    (update),               // TAP 处于 e_UPDATE_DR 状态。
   .capture_in   (capture),              // TAP 处于 e_CAPTURE_DR 状态。
   .sel_in       (sel1),                 // 用户数据寄存器已选中。
   .h_rstn       (resetn_i),
  
  // for user_app interface(debug_core,etc)
   .drck_o       (drck_o),               // 向各用户应用转发 TCK。
   .conf_tdi     (hub_tdi),              // 向各用户应用转发 TDI。
   .conf_sel     (conf_sel_s),           // 根据标识号选择配置模块。
   .id_o         (id_o),                 // 标识号指示。
   .capt_o       (capt_o),               // 采集
   .shift_d      (shift_d),              // 将 shift_in 延迟一个时钟周期。
   .hub_tdo      (hub_tdo_s)             // 来自各用户应用的读回信号。
 ); 
assign conf_sel  = conf_sel_s[14:0];
assign shift_o   = shift_d;
assign hub_tdo_s[14:0] = hub_tdo[14:0];
assign hub_tdo_s[15] = 1'b0;
            
endmodule
