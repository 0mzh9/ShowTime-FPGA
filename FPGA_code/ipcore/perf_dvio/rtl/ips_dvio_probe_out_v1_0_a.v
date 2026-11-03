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
//the probe_out module, it generates a combined signal of 1 and 0 to drive the fpga on-chip design
//
//
//----------------------------------------------------------------------

module ips_dvio_probe_out_v1_0_a
#(
  parameter                         PROBE_OUT_WIDTH    = 1,     //1~256
  parameter  [PROBE_OUT_WIDTH-1:0]  INIT_PROBE_OUT     = 0     // 上电时输出探针的初始配置。
)
(
  input   [1:0]                             clk_conf_trig ,
  input                                     h_rstn        ,
  input                                     conf_rst      ,
  input                                     conf_rden     ,
  input                                     conf_sel_rd   ,
  input                                     conf_sel      ,
  input                                     conf_tdi      ,
  input   [8:0]                             conf_id       ,
  input                                     shift_i       ,
  
  output    reg                             conf_rdata    ,
//output    reg                             conf_rdlast   ,
  output    reg     [PROBE_OUT_WIDTH-1:0]   probe_out  
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
H9EJYJLKIBEuJR+NRUB2BHoVyEpUvMy4Z3jDz2GHzUD3q6JHHHXG9t3L+XNeHdGSgIn+JP0wSGo7
+bNqMBmK4SDAZp2j90pFIjSwhoyftT8R1RDDNsaRXLCbaPZXdan8t0zDUAevCohOLl5HBdnoZF5z
Faf5tCli/elDJJhzrjBxDsRCZECsRvWn6+vHEaE1DI790rSGz3qLrZ4kzPZeFAeLGya8m2460Ftf
G7E0bJtl1zYxicuAvEzR72YYTAhXJd4dfs/qUB2VnOs4IRSzNV0a/i4Mm+ys8C92ViDOWwcosOFV
9CYl5sy3Lb5Z2FIbCLhE56J5/PLBv7Al02LfGQ==

`pragma protect encoding=(enctype="base64", line_length=76, bytes=256)
`pragma protect key_keyowner="Pango Microsystems", key_keyname="PANGO_21", key_method="rsa"
`pragma protect key_block
mwE0IR5DZh630JkrQa3+nCXPRAGrHH36/b1Myj5jFQZRcXpc/DpOOwrjRcUu9gPkyv3skObdbcLC
2eGQMm7+0aZTbLaVKpui3vKTFe7Qbrsdog5CT7xs10X8jaTvtmkVpjAIldu3kS7F17KUe/WZAiX3
yHR4h4TjAr14XLByaCdXqcMnwdp+HXPirbbmLCgsXIFWGtjilwEHoxFCM4m4xcr1V9C5Rh8qFTDP
4Cs8lRaWZs2iiG/4zYEQV1Ghtzx3DfHEqnUwqDW3xxYL1xRPTpQOw6OALs0BEtf6F2ZY5XHdhaVB
2kUjlS6Lh0zUkXWZSm/Y8YZ0T3Kg43QGQIGXCw==

`pragma protect data_method="aes128-cbc"
`pragma protect encoding=(enctype="base64", line_length=76, bytes=4400)
`pragma protect data_block
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
4Ovxh73lEMElhrc=

`pragma protect end_protected
endmodule









