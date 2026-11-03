///////////////////////////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2022 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//the probe_in module, it samples the user logic output signal and transmits it to the software via jtag
//
//
// 
//
//----------------------------------------------------------------------

module ips_dvio_probe_in_v1_0
#(
  parameter  PROBE_IN_WIDTH               = 1,     //1~256
  parameter  EN_ACTIVITY_DETECTOR         = 1,     // 取值 0～1：0 表示禁用，1 表示使能。
  parameter  DATA_MSB                     = 2      // 参考位宽表达式：EN_ACTIVITY_DETECTOR 为 0 时取 PROBE_IN_WIDTH−1，否则取 PROBE_IN_WIDTH×3−1。
)
(
  input         [1:0]                   clk_conf_trig ,  
  input                                 capt_i,
  input                                 h_rstn      ,
  input                                 conf_rst      ,
  input         [PROBE_IN_WIDTH-1:0]    probe_in      ,
  input                                 rdata_en      ,
  output  reg   [DATA_MSB:0]            probe_rdata   
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
tSfg6zwgsKZeL0KM+T4sUkA6SHRZ8cRurwtPZ4rVY8fPsvodGuZE1evO7+hiYzpfaJjemlhq2noU
7W5C5H3OqfnQqr+S1fdfKoP//GjZVyu9uqfkd8QQrf0TI59c2Te1CV2zIooRdy6q2qmEbDGSjefH
g46mopYmV/llXkKknPhHtnp/B3z7ksHYOcfEpMiKFR54cx8oYVmUupVi8ox2AzHyT8VcC5M34Vb2
g9aZQn2Zg12U+RhBnMnSkvXfEtqVS7k2Z94H8mU4ZEv6FqYTfgQvet818eTR8f0cWy41de8uxIvO
G5Ds/Nw5mSbVAczMDtP26Yk1ojzHS/vQ+u1k9A==

`pragma protect encoding=(enctype="base64", line_length=76, bytes=256)
`pragma protect key_keyowner="Pango Microsystems", key_keyname="PANGO_21", key_method="rsa"
`pragma protect key_block
mDvj2UERrE4BCcifxOnzQAM0cXtznSGWg6Nc2fTO/zgHK7ImV8mNgtP90YgSAtBkROT3GtS946Nv
6Md3GeYpZT7zjPhdi9usdAPJw/v8c2Ld23MppOVCa6tkKc5gpNYP08rzXcB8ySKqjo0yXwSoLVLJ
OWhqQXlOCQ+JQTbGk9Caz23CJUYn9lgUzrrSr03t1xfwDpQEu8QOBwyPvA5OuidXFcwNj3CjdGb0
+P7gcWKbo8pzzq1WY933qKov2Uh9e3iEKK7cr0Mx8otKIa8hBR9Jh4g0LLSXNW+Nca3JatUe94Wr
EyNaqYJ+osb37IwlXTXABRoca1Od2YjvAOTu/Q==

`pragma protect data_method="aes128-cbc"
`pragma protect encoding=(enctype="base64", line_length=76, bytes=5296)
`pragma protect data_block
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

`pragma protect end_protected
endmodule


