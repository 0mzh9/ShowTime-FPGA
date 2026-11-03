`timescale 1ns/1ps
 
 
module paged_pixel_bank                                                     // 分页面像素 RAM：把较深存储拆成 2048 项页面，读地址页号与同步 RAM 输出对齐。
    #(parameter DEPTH = 35840, AB = $clog2(DEPTH))                          // 像素存储总深度。
    (                                                                       // 显式分页的像素 RAM，避免整块容量按二次幂过度填充。
     input wire              clk, write_enable, read_enable,                // 本模块工作时钟；列参数读使能。
     input wire [AB - 1 : 0] write_address, read_address,
     input wire [15 : 0]     write_data,
     output reg [15 : 0]     read_data);
    localparam       PAGES = (DEPTH + 2047) / 2048;                         // 以 2048 项为一页向上取整，避免单个深 RAM 产生较大的读选择路径。
    wire [15 : 0]    page_data[0 : PAGES - 1];
    reg [AB - 1 : 0] selected_address;
    wire [10 : 0]    write_offset = write_address, read_offset = read_address;
    always @(posedge clk)                                                   // 同步保存读页号，保证页选择和各页 RAM 的读延迟一致。
        if (read_enable)
            selected_address <= read_address;
    genvar p;
    generate
        for (p = 0; p < PAGES; p = p + 1) begin : pages
            (* ram_style="block" *) reg [15 : 0] memory[0 : 2047];
            reg [15 : 0]                             value;
            assign                                   page_data[p] = value;
            always @(posedge clk) begin
                if (write_enable && (write_address >> 11) == p)
                    memory[write_offset] <= write_data;
                if (read_enable && (read_address >> 11) == p)
                    value <= memory[read_offset];
            end
        end
    endgenerate
    integer i;
    always @ * begin
        read_data = 0;
        for (i = 0; i < PAGES; i = i + 1)
            if ((selected_address >> 11) == i)
                read_data = page_data[i];
    end
endmodule
