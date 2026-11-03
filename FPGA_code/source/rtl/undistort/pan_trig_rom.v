`timescale 1ns/1ps
 
module pan_trig_rom                                                         // 转向三角查找表：绝对角度以 0.1 度索引，同步输出 Q22 正弦和余弦。
    (input wire          clk,                                               // 本模块工作时钟。
     input wire [8 : 0]  angle_abs,                                         // 索引为角度绝对值的十倍；负角度的正弦符号在列计算模块恢复。
     output reg [47 : 0] value);                                            // 0 至 30 度、步进 0.1 度的正余弦常量表；高 24 位保存 Q22 正弦，低 24 位保存 Q22 余弦。
    always @(posedge clk) begin                                             // 同步 ROM 有一拍读取延迟，调用端必须等待后再锁存三角值。
        case (angle_abs)
            9'd0 :
                value <= 48'h000000400000;                                  // 零度时 sin=0、cos=1，Q22 的单位值编码为 0x400000。
            9'd1 :
                value <= 48'h001c983ffffa;
            9'd2 :
                value <= 48'h0039313fffe6;
            9'd3 :
                value <= 48'h0055c93fffc7;
            9'd4 :
                value <= 48'h0072623fff9a;
            9'd5 :
                value <= 48'h008efa3fff60;
            9'd6 :
                value <= 48'h00ab923fff1a;
            9'd7 :
                value <= 48'h00c82a3ffec7;
            9'd8 :
                value <= 48'h00e4c23ffe67;
            9'd9 :
                value <= 48'h0101593ffdfb;
            9'd10 :
                value <= 48'h011df13ffd81;
            9'd11 :
                value <= 48'h013a883ffcfb;
            9'd12 :
                value <= 48'h01571f3ffc68;
            9'd13 :
                value <= 48'h0173b63ffbc8;
            9'd14 :
                value <= 48'h01904c3ffb1c;
            9'd15 :
                value <= 48'h01ace23ffa63;
            9'd16 :
                value <= 48'h01c9783ff99d;
            9'd17 :
                value <= 48'h01e60d3ff8ca;
            9'd18 :
                value <= 48'h0202a23ff7ea;
            9'd19 :
                value <= 48'h021f373ff6fe;
            9'd20 :
                value <= 48'h023bcb3ff605;
            9'd21 :
                value <= 48'h02585f3ff4ff;
            9'd22 :
                value <= 48'h0274f23ff3ec;
            9'd23 :
                value <= 48'h0291853ff2cd;
            9'd24 :
                value <= 48'h02ae173ff1a1;
            9'd25 :
                value <= 48'h02caa93ff068;
            9'd26 :
                value <= 48'h02e73a3fef22;
            9'd27 :
                value <= 48'h0303cb3fedd0;
            9'd28 :
                value <= 48'h03205b3fec71;
            9'd29 :
                value <= 48'h033cea3feb05;
            9'd30 :
                value <= 48'h0359793fe98c;
            9'd31 :
                value <= 48'h0376073fe806;
            9'd32 :
                value <= 48'h0392943fe674;
            9'd33 :
                value <= 48'h03af213fe4d5;
            9'd34 :
                value <= 48'h03cbad3fe329;
            9'd35 :
                value <= 48'h03e8383fe171;
            9'd36 :
                value <= 48'h0404c33fdfab;
            9'd37 :
                value <= 48'h04214c3fddd9;
            9'd38 :
                value <= 48'h043dd53fdbfb;
            9'd39 :
                value <= 48'h045a5d3fda0f;
            9'd40 :
                value <= 48'h0476e43fd817;
            9'd41 :
                value <= 48'h04936a3fd612;
            9'd42 :
                value <= 48'h04afef3fd400;
            9'd43 :
                value <= 48'h04cc743fd1e2;
            9'd44 :
                value <= 48'h04e8f73fcfb6;
            9'd45 :
                value <= 48'h0505793fcd7e;
            9'd46 :
                value <= 48'h0521fb3fcb3a;
            9'd47 :
                value <= 48'h053e7b3fc8e8;
            9'd48 :
                value <= 48'h055afa3fc68a;
            9'd49 :
                value <= 48'h0577793fc41f;
            9'd50 :
                value <= 48'h0593f63fc1a7;
            9'd51 :
                value <= 48'h05b0723fbf23;
            9'd52 :
                value <= 48'h05cced3fbc92;
            9'd53 :
                value <= 48'h05e9663fb9f4;
            9'd54 :
                value <= 48'h0605df3fb74a;
            9'd55 :
                value <= 48'h0622563fb492;
            9'd56 :
                value <= 48'h063ecc3fb1ce;
            9'd57 :
                value <= 48'h065b413faefe;
            9'd58 :
                value <= 48'h0677b53fac20;
            9'd59 :
                value <= 48'h0694273fa936;
            9'd60 :
                value <= 48'h06b0983fa63f;
            9'd61 :
                value <= 48'h06cd083fa33c;
            9'd62 :
                value <= 48'h06e9763fa02b;
            9'd63 :
                value <= 48'h0705e33f9d0e;
            9'd64 :
                value <= 48'h07224f3f99e5;
            9'd65 :
                value <= 48'h073eb93f96ae;
            9'd66 :
                value <= 48'h075b213f936b;
            9'd67 :
                value <= 48'h0777893f901c;
            9'd68 :
                value <= 48'h0793ee3f8cbf;
            9'd69 :
                value <= 48'h07b0523f8956;
            9'd70 :
                value <= 48'h07ccb53f85e0;
            9'd71 :
                value <= 48'h07e9163f825e;
            9'd72 :
                value <= 48'h0805763f7ecf;
            9'd73 :
                value <= 48'h0821d43f7b33;
            9'd74 :
                value <= 48'h083e303f778a;
            9'd75 :
                value <= 48'h085a8b3f73d5;
            9'd76 :
                value <= 48'h0876e43f7013;
            9'd77 :
                value <= 48'h08933b3f6c45;
            9'd78 :
                value <= 48'h08af903f686a;
            9'd79 :
                value <= 48'h08cbe43f6482;
            9'd80 :
                value <= 48'h08e8363f608d;
            9'd81 :
                value <= 48'h0904873f5c8c;
            9'd82 :
                value <= 48'h0920d53f587e;
            9'd83 :
                value <= 48'h093d223f5464;
            9'd84 :
                value <= 48'h09596d3f503d;
            9'd85 :
                value <= 48'h0975b63f4c09;
            9'd86 :
                value <= 48'h0991fd3f47c9;
            9'd87 :
                value <= 48'h09ae423f437c;
            9'd88 :
                value <= 48'h09ca853f3f22;
            9'd89 :
                value <= 48'h09e6c63f3abc;
            9'd90 :
                value <= 48'h0a03063f3649;
            9'd91 :
                value <= 48'h0a1f433f31ca;
            9'd92 :
                value <= 48'h0a3b7e3f2d3e;
            9'd93 :
                value <= 48'h0a57b83f28a5;
            9'd94 :
                value <= 48'h0a73ef3f2400;
            9'd95 :
                value <= 48'h0a90243f1f4e;
            9'd96 :
                value <= 48'h0aac573f1a8f;
            9'd97 :
                value <= 48'h0ac8883f15c4;
            9'd98 :
                value <= 48'h0ae4b63f10ec;
            9'd99 :
                value <= 48'h0b00e33f0c08;
            9'd100 :
                value <= 48'h0b1d0d3f0717;
            9'd101 :
                value <= 48'h0b39353f021a;
            9'd102 :
                value <= 48'h0b555b3efd10;
            9'd103 :
                value <= 48'h0b717f3ef7f9;
            9'd104 :
                value <= 48'h0b8da03ef2d6;
            9'd105 :
                value <= 48'h0ba9bf3eeda6;
            9'd106 :
                value <= 48'h0bc5dc3ee86a;
            9'd107 :
                value <= 48'h0be1f63ee321;
            9'd108 :
                value <= 48'h0bfe0e3eddcb;
            9'd109 :
                value <= 48'h0c1a243ed869;
            9'd110 :
                value <= 48'h0c36373ed2fb;
            9'd111 :
                value <= 48'h0c52483ecd80;
            9'd112 :
                value <= 48'h0c6e563ec7f8;
            9'd113 :
                value <= 48'h0c8a623ec264;
            9'd114 :
                value <= 48'h0ca66b3ebcc3;
            9'd115 :
                value <= 48'h0cc2723eb716;
            9'd116 :
                value <= 48'h0cde763eb15c;
            9'd117 :
                value <= 48'h0cfa783eab96;
            9'd118 :
                value <= 48'h0d16773ea5c3;
            9'd119 :
                value <= 48'h0d32733e9fe4;
            9'd120 :
                value <= 48'h0d4e6d3e99f8;
            9'd121 :
                value <= 48'h0d6a643e9400;
            9'd122 :
                value <= 48'h0d86583e8dfb;
            9'd123 :
                value <= 48'h0da24a3e87ea;
            9'd124 :
                value <= 48'h0dbe393e81cc;
            9'd125 :
                value <= 48'h0dda263e7ba2;
            9'd126 :
                value <= 48'h0df60f3e756c;
            9'd127 :
                value <= 48'h0e11f63e6f28;
            9'd128 :
                value <= 48'h0e2dda3e68d9;
            9'd129 :
                value <= 48'h0e49bb3e627d;
            9'd130 :
                value <= 48'h0e65993e5c14;
            9'd131 :
                value <= 48'h0e81743e559f;
            9'd132 :
                value <= 48'h0e9d4d3e4f1e;
            9'd133 :
                value <= 48'h0eb9233e4890;
            9'd134 :
                value <= 48'h0ed4f53e41f6;
            9'd135 :
                value <= 48'h0ef0c53e3b4f;
            9'd136 :
                value <= 48'h0f0c923e349c;
            9'd137 :
                value <= 48'h0f285b3e2ddc;
            9'd138 :
                value <= 48'h0f44223e2710;
            9'd139 :
                value <= 48'h0f5fe53e2038;
            9'd140 :
                value <= 48'h0f7ba63e1953;
            9'd141 :
                value <= 48'h0f97633e1262;
            9'd142 :
                value <= 48'h0fb31e3e0b65;
            9'd143 :
                value <= 48'h0fced53e045b;
            9'd144 :
                value <= 48'h0fea893dfd44;
            9'd145 :
                value <= 48'h10063a3df622;
            9'd146 :
                value <= 48'h1021e83deef2;
            9'd147 :
                value <= 48'h103d923de7b7;
            9'd148 :
                value <= 48'h1059393de06f;
            9'd149 :
                value <= 48'h1074dd3dd91b;
            9'd150 :
                value <= 48'h10907e3dd1bb;
            9'd151 :
                value <= 48'h10ac1b3dca4e;
            9'd152 :
                value <= 48'h10c7b53dc2d5;
            9'd153 :
                value <= 48'h10e34c3dbb4f;
            9'd154 :
                value <= 48'h10fedf3db3bd;
            9'd155 :
                value <= 48'h111a6f3dac1f;
            9'd156 :
                value <= 48'h1135fb3da475;
            9'd157 :
                value <= 48'h1151853d9cbe;
            9'd158 :
                value <= 48'h116d0a3d94fb;
            9'd159 :
                value <= 48'h11888c3d8d2b;
            9'd160 :
                value <= 48'h11a40b3d8550;
            9'd161 :
                value <= 48'h11bf863d7d68;
            9'd162 :
                value <= 48'h11dafe3d7574;
            9'd163 :
                value <= 48'h11f6713d6d73;
            9'd164 :
                value <= 48'h1211e23d6566;
            9'd165 :
                value <= 48'h122d4f3d5d4d;
            9'd166 :
                value <= 48'h1248b83d5528;
            9'd167 :
                value <= 48'h12641d3d4cf7;
            9'd168 :
                value <= 48'h127f7f3d44b9;
            9'd169 :
                value <= 48'h129add3d3c6f;
            9'd170 :
                value <= 48'h12b6383d3419;
            9'd171 :
                value <= 48'h12d18f3d2bb6;
            9'd172 :
                value <= 48'h12ece13d2348;
            9'd173 :
                value <= 48'h1308313d1acd;
            9'd174 :
                value <= 48'h13237c3d1246;
            9'd175 :
                value <= 48'h133ec43d09b3;
            9'd176 :
                value <= 48'h135a073d0113;
            9'd177 :
                value <= 48'h1375473cf868;
            9'd178 :
                value <= 48'h1390833cefb0;
            9'd179 :
                value <= 48'h13abbb3ce6ec;
            9'd180 :
                value <= 48'h13c6ef3cde1c;
            9'd181 :
                value <= 48'h13e21f3cd540;
            9'd182 :
                value <= 48'h13fd4c3ccc58;
            9'd183 :
                value <= 48'h1418743cc363;
            9'd184 :
                value <= 48'h1433983cba62;
            9'd185 :
                value <= 48'h144eb83cb156;
            9'd186 :
                value <= 48'h1469d43ca83d;
            9'd187 :
                value <= 48'h1484ec3c9f18;
            9'd188 :
                value <= 48'h14a0003c95e7;
            9'd189 :
                value <= 48'h14bb103c8caa;
            9'd190 :
                value <= 48'h14d61c3c8360;
            9'd191 :
                value <= 48'h14f1233c7a0b;
            9'd192 :
                value <= 48'h150c273c70aa;
            9'd193 :
                value <= 48'h1527263c673c;
            9'd194 :
                value <= 48'h1542213c5dc3;
            9'd195 :
                value <= 48'h155d173c543d;
            9'd196 :
                value <= 48'h15780a3c4aab;
            9'd197 :
                value <= 48'h1592f83c410e;
            9'd198 :
                value <= 48'h15ade23c3764;
            9'd199 :
                value <= 48'h15c8c73c2dae;
            9'd200 :
                value <= 48'h15e3a83c23ed;
            9'd201 :
                value <= 48'h15fe853c1a1f;
            9'd202 :
                value <= 48'h16195e3c1045;
            9'd203 :
                value <= 48'h1634323c065f;
            9'd204 :
                value <= 48'h164f013bfc6e;
            9'd205 :
                value <= 48'h1669cc3bf270;
            9'd206 :
                value <= 48'h1684933be866;
            9'd207 :
                value <= 48'h169f553bde51;
            9'd208 :
                value <= 48'h16ba133bd42f;
            9'd209 :
                value <= 48'h16d4cc3bca02;
            9'd210 :
                value <= 48'h16ef803bbfc8;
            9'd211 :
                value <= 48'h170a303bb583;
            9'd212 :
                value <= 48'h1724db3bab31;
            9'd213 :
                value <= 48'h173f823ba0d4;
            9'd214 :
                value <= 48'h175a243b966b;
            9'd215 :
                value <= 48'h1774c23b8bf6;
            9'd216 :
                value <= 48'h178f5a3b8175;
            9'd217 :
                value <= 48'h17a9ee3b76e8;
            9'd218 :
                value <= 48'h17c47e3b6c50;
            9'd219 :
                value <= 48'h17df083b61ab;
            9'd220 :
                value <= 48'h17f98e3b56fb;
            9'd221 :
                value <= 48'h18140f3b4c3f;
            9'd222 :
                value <= 48'h182e8b3b4177;
            9'd223 :
                value <= 48'h1849023b36a3;
            9'd224 :
                value <= 48'h1863753b2bc3;
            9'd225 :
                value <= 48'h187de33b20d8;
            9'd226 :
                value <= 48'h18984b3b15e0;
            9'd227 :
                value <= 48'h18b2af3b0add;
            9'd228 :
                value <= 48'h18cd0e3affce;
            9'd229 :
                value <= 48'h18e7683af4b4;
            9'd230 :
                value <= 48'h1901bd3ae98d;
            9'd231 :
                value <= 48'h191c0d3ade5b;
            9'd232 :
                value <= 48'h1936583ad31d;
            9'd233 :
                value <= 48'h19509e3ac7d3;
            9'd234 :
                value <= 48'h196adf3abc7e;
            9'd235 :
                value <= 48'h19851b3ab11d;
            9'd236 :
                value <= 48'h199f523aa5b0;
            9'd237 :
                value <= 48'h19b9833a9a37;
            9'd238 :
                value <= 48'h19d3b03a8eb3;
            9'd239 :
                value <= 48'h19edd73a8323;
            9'd240 :
                value <= 48'h1a07f93a7787;
            9'd241 :
                value <= 48'h1a22163a6be0;
            9'd242 :
                value <= 48'h1a3c2e3a602d;
            9'd243 :
                value <= 48'h1a56403a546e;
            9'd244 :
                value <= 48'h1a704e3a48a4;
            9'd245 :
                value <= 48'h1a8a563a3cce;
            9'd246 :
                value <= 48'h1aa4583a30ed;
            9'd247 :
                value <= 48'h1abe563a24ff;
            9'd248 :
                value <= 48'h1ad84e3a1907;
            9'd249 :
                value <= 48'h1af2403a0d02;
            9'd250 :
                value <= 48'h1b0c2d3a00f2;
            9'd251 :
                value <= 48'h1b261539f4d7;
            9'd252 :
                value <= 48'h1b3ff839e8b0;
            9'd253 :
                value <= 48'h1b59d539dc7d;
            9'd254 :
                value <= 48'h1b73ac39d03f;
            9'd255 :
                value <= 48'h1b8d7e39c3f5;
            9'd256 :
                value <= 48'h1ba74b39b7a0;
            9'd257 :
                value <= 48'h1bc11239ab3f;
            9'd258 :
                value <= 48'h1bdad4399ed3;
            9'd259 :
                value <= 48'h1bf48f39925b;
            9'd260 :
                value <= 48'h1c0e463985d7;
            9'd261 :
                value <= 48'h1c27f7397949;
            9'd262 :
                value <= 48'h1c41a2396cae;
            9'd263 :
                value <= 48'h1c5b47396009;
            9'd264 :
                value <= 48'h1c74e7395357;
            9'd265 :
                value <= 48'h1c8e8139469b;
            9'd266 :
                value <= 48'h1ca8163939d3;
            9'd267 :
                value <= 48'h1cc1a4392cff;
            9'd268 :
                value <= 48'h1cdb2d392020;
            9'd269 :
                value <= 48'h1cf4b1391336;
            9'd270 :
                value <= 48'h1d0e2e390640;
            9'd271 :
                value <= 48'h1d27a638f93f;
            9'd272 :
                value <= 48'h1d411838ec33;
            9'd273 :
                value <= 48'h1d5a8438df1b;
            9'd274 :
                value <= 48'h1d73ea38d1f8;
            9'd275 :
                value <= 48'h1d8d4a38c4c9;
            9'd276 :
                value <= 48'h1da6a438b78f;
            9'd277 :
                value <= 48'h1dbff938aa4a;
            9'd278 :
                value <= 48'h1dd947389cfa;
            9'd279 :
                value <= 48'h1df290388f9e;
            9'd280 :
                value <= 48'h1e0bd2388237;
            9'd281 :
                value <= 48'h1e250f3874c4;
            9'd282 :
                value <= 48'h1e3e46386747;
            9'd283 :
                value <= 48'h1e57763859be;
            9'd284 :
                value <= 48'h1e70a1384c2a;
            9'd285 :
                value <= 48'h1e89c5383e8a;
            9'd286 :
                value <= 48'h1ea2e33830e0;
            9'd287 :
                value <= 48'h1ebbfb38232a;
            9'd288 :
                value <= 48'h1ed50d381569;
            9'd289 :
                value <= 48'h1eee1938079c;
            9'd290 :
                value <= 48'h1f071f37f9c5;
            9'd291 :
                value <= 48'h1f201e37ebe2;
            9'd292 :
                value <= 48'h1f391837ddf5;
            9'd293 :
                value <= 48'h1f520b37cffc;
            9'd294 :
                value <= 48'h1f6af837c1f8;
            9'd295 :
                value <= 48'h1f83de37b3e8;
            9'd296 :
                value <= 48'h1f9cbe37a5ce;
            9'd297 :
                value <= 48'h1fb5983797a9;
            9'd298 :
                value <= 48'h1fce6c378978;
            9'd299 :
                value <= 48'h1fe739377b3d;
            9'd300 :
                value <= 48'h200000376cf6;
            default :
                value <= 48'h000000400000;
        endcase
    end
endmodule
