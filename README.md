# Audio Echo Effects processor for I2S2 PMOD board and the Basys3

## This modifies the Digilent Volume Controller example code used for the I2S2 audio ADC/DAC PMOD board. It replaces the volume controller with a block of code, controlled essentially by four switches. Two switches control the echo delay, and two switches control the volume of the echoed signal

In addition, there is reset input from one of the four pushbuttons. This is not intended to be actively used, and really is intended just to minimize the modifications to the original Volume Controller file.

The delay effect implements a distributed memory generator, and uses the maximum amount possible on the Basys3's Artix-7 FPGA. There is testbench code provided for this memory.

There is also testbench code provided for the echo effect module. This essentially just acts to stimulate the AXIS master and slave ports so we can be sure that there is dataflow. It does not do any automated validation of data coming in or out. The testbenches are written in older-style Verilog, but my intent is to replace these testbenches in the future with SystemVerilog.

