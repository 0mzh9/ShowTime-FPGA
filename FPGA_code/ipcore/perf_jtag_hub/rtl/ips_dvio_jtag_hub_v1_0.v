//////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2022 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//the jtag_hub module, it controls to select which DVIO and sub module
//note that one FPGA only support one jtag_hub
//
module ips_dvio_jtag_hub_v1_0
 #(
   parameter  CTRL_PORT_NUM = 1,     //@IPC int 1,15 ;the number of usr_app connect with jtag_hub
   parameter  UJTAG_SEL     = 0      // 1 表示使用 jtagif，0 表示使用扫描链。
 )
 (
  //for user jtagif
   input            urck_in,
   input            utdi_in,
   // for JTAG_interface                        
   input            tdi_in,                    // 用户数据寄存器的 TDI。
   output           tdo_out,                   // 用户数据寄存器的 TDO。
   input            reset_dr,	                 // TAP 处于 e_TEST_LOGIC_RESET 状态时产生高有效复位。
   input            shift_in,	                 // TAP 处于 e_SHIFT_DR 状态。
   input            update_in,                 // TAP 处于 e_UPDATE_DR 状态。
   input            capture_in,                // TAP 处于 e_CAPTURE_DR 状态。
   input            sel_in,                    // 用户数据寄存器已选中。
   input            drck_in,                   // 用户数据寄存器的 TCK。
   input            h_rstn ,                   // 来自用户逻辑器件的硬件复位，低电平有效。
  // for user_app interface(dvio,etc)
   output           drck_o,                    // 向各用户应用转发 TCK。
   output           conf_tdi,                  // 向各用户应用转发 TDI。
   output reg [15:0]conf_sel,                  // 根据标识号选择配置模块。
   output reg [8:0] id_o,                      // 标识号指示。
   output           capt_o,                    // 采集
   output           shift_d,                    // 将 shift_in 延迟一个时钟周期。
   input     [15:0] hub_tdo                    // 来自各用户应用的读回信号。

 );  
`pragma protect begin_protected
`pragma protect version=1
`pragma protect author="default"
`pragma protect author_info="default"
`pragma protect encrypt_agent="Synplify encryptP1735.pl"
`pragma protect encrypt_agent_info="Synplify encryptP1735.pl Version 1.1"

`pragma protect encoding=(enctype="base64", line_length=76, bytes=256)
`pragma protect key_keyowner="Synplicity", key_keyname="SYNP15_1", key_method="rsa"
`pragma protect key_block
09kU0i4SGRaVljY6BWp0mCMfmEmeF1ikqJOWGTRsHsSXjyOZCgBHZFTSxLkxCMXfiapL5qOm0Yeh
WrLmked77Xz0zTZDtpwa6wXiPFBoMXkCPqC5LnoO2XZVy/9wNDzMVuohQkVkEzvXbv86cJH5LqPh
W/QUz77mlN5qq877nBCPYeexUmMdgBEAusGBpgeTk5MakO7YRXXD4b9yLgEep+jkD3OJb6E/50Fa
EenwMZ2osOpjcgiDt+XSLZIPnTELoi9Em8vXvOCjTdoIULZqdNE1/bvWk6N3fAj+m6G/FHhlNhA2
26f/fiKyMh3fTqj0gf8ZB/nqpqbm9n7Pn7WGGw==

`pragma protect encoding=(enctype="base64", line_length=76, bytes=256)
`pragma protect key_keyowner="Pango Microsystems", key_keyname="PANGO_21", key_method="rsa"
`pragma protect key_block
Fg9evSymPQ+8PvKT5ZO0ZF/Vkaq3udmPIAtvmGcNhQ/QYrHSTLSy43tn+yGGJM6GOwCBQ00VnHj/
FTCLgOpypFCew3z2OgMKs+YOv51TZzIfXI1SqTP83+qB1dKK0jqMNajs9+T0Jt9spaEkCy3HoP31
lMP4ZZynU5yPf1ltC6HFdH3+KX3+1ffYrDTz+rlzRL871O+J9QWiUwfTNCNPuHVs0C8/PCRWv6T0
b/7eMm5JC8Z8Opk5VHXiIAOn7BxhVf09oYGgotfrZ6T12eumsteFRqc7ozENvpW+6mklA/4Z8wlb
G3aGsXh+I1tFBdn26XpbjEoLRoBLVmSkJfW/mw==

`pragma protect data_method="aes128-cbc"
`pragma protect encoding=(enctype="base64", line_length=76, bytes=9808)
`pragma protect data_block
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
suP5mA==

`pragma protect end_protected
endmodule
