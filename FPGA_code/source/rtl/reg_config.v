`timescale 1ns/1ps
 
 
 
module reg_config                                                           // 相机初始化封装：连接寄存器查找表和 I2C 控制器，对外给出完成与错误状态。
    #(parameter integer CLOCK_HZ           = 24750000,                      // 该控制时钟每秒的周期数。
      parameter integer SCCB_DIV           = 49,                            // 相机寄存器控制总线分频参数。
      parameter integer RESET_DELAY_CYCLES = CLOCK_HZ / 100,
      parameter integer TIMEOUT_CYCLES     = CLOCK_HZ / 50)                 // 事务最长等待周期数。
    (input           clk_25M,
     input           camera_rstn,
     input           initial_en,
     output          reg_conf_done,
     output          config_error,
     inout           i2c_sclk,
     inout           i2c_sdat,
     output [9 : 0]  reg_index,
     output [15 : 0] sensor_id,
     output [3 : 0]  error_code,                                            // 错误原因编码。
     output [95 : 0] debug_status);
    wire [31 : 0] lut_data;
    wire          reset_config =  !camera_rstn ||  !initial_en;
    lut_ov5640_rgb565_1280_720 #(.SENSOR_XCLK_MHZ(25))                      // OV5640 寄存器配置表：输出地址与写值，建立 1280×720 RGB565 采集模式。
        lut(.lut_index(reg_index),
            .lut_data(lut_data));

    i2c_config #(.RESET_DELAY_CYCLES(RESET_DELAY_CYCLES),                   // 相机寄存器初始化：顺序写配置表，再读回关键寄存器；异常时保留诊断现场。
                 .TIMEOUT_CYCLES(TIMEOUT_CYCLES))
        u_config(.rst(reset_config),
                 .clk(clk_25M),
                 .clk_div_cnt(SCCB_DIV[15 : 0]),
                 .i2c_addr_2byte(1'b1),
                 .lut_index(reg_index),
                 .lut_dev_addr(lut_data[31 : 24]),
                 .lut_reg_addr(lut_data[23 : 8]),
                 .lut_reg_data(lut_data[7 : 0]),
                 .error(config_error),
                 .done(reg_conf_done),
                 .i2c_scl(i2c_sclk),
                 .i2c_sda(i2c_sdat),
                 .sensor_id(sensor_id),
                 .error_code(error_code),
                 .debug_status(debug_status),
                 .debug_bus());
endmodule
