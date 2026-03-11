`timescale 1ns / 1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
// Company: Digilent
// Engineer: Arthur Brown
// 
// Create Date: 03/23/2018 01:23:15 PM
// Module Name: axis_volume_controller
// Description: AXI-Stream volume controller intended for use with AXI Stream Pmod I2S2 controller.
//              Whenever a 2-word packet is received on the slave interface, it is multiplied by 
//              the value of the switches, taken to represent the range 0.0:1.0, then sent over the
//              master interface. Reception of data on the slave interface is halted while processing and
//              transfer is taking place.
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// The slave controls the "ready" line, the master controls all other three interfaces. Data always flows from master to slave.
// so...
// There is both a master and slave interface on both the axis_volume_controller module, and on the axis_i2s2 module.
//
// FYI - the 44100 Hz sample rate, times 2 channels, times 24 bits per channel per sample equals 2,116,800 bits/s
//
module axis_volume_controller #(
    parameter SWITCH_WIDTH = 4, // WARNING: this module has not been tested with other values of SWITCH_WIDTH, it will likely need some changes
    parameter DATA_WIDTH = 24
) (
    input wire clk,
    input wire [SWITCH_WIDTH-1:0] sw,
    
    //AXIS SLAVE INTERFACE to take data in from the ADC on the I2S2 module. It uses "ready" to throttle data coming in from the
    //master, so it doesn't get overloaded.
    input  wire [DATA_WIDTH-1:0] s_axis_data,
    input  wire s_axis_valid,
    output reg  s_axis_ready = 1'b1,
    input  wire s_axis_last,
    
    // AXIS MASTER INTERFACE to transmit data out, to the DAC on the I2S2 module. Note that it just throws data out there,
    //but has to wait until the destination (slave) device shows ready, so we know that data was actually pushed.
    output reg [DATA_WIDTH-1:0] m_axis_data = 1'b0,
    output reg m_axis_valid = 1'b0,
    input  wire m_axis_ready,
    output reg m_axis_last = 1'b0
);
    localparam MULTIPLIER_WIDTH = 24;
    reg [MULTIPLIER_WIDTH+DATA_WIDTH-1:0] data [1:0];
        
    reg [SWITCH_WIDTH-1:0] sw_sync_r [2:0];
    wire [SWITCH_WIDTH-1:0] sw_sync = sw_sync_r[2];
//    wire [SWITCH_WIDTH:0] m = {1'b0, sw_sync} + 1;
    reg [MULTIPLIER_WIDTH:0] multiplier = 'b0; // range of 0x00:0x10 for width=4
    
    // The next few lines basically set up asynchronous relationships for both slave and master interfaces:
    // -select will be permanently connected to axis_last
    // -new_word will be high IF both axis_valid AND axis_ready are high (else 0). M_new_word indicates "ready for new word, since the current
    // word will be successfully clocked across the AXIS bus on the next clock tick. (slave will be ready when master indicates valid data) Load a new
    // word on the next clock edge!"
    // -new_packet will be high IF both new_word AND axis_last are high (else 0). You can read "new packet" as being high when all three lines
    // (axis_valid, axis_ready, and axis_last) are high. This means the next word will be successfully clocked across AXIS, and that word
    // will be the last word in the packet (so it means "upon the next clock tick, put send over the start of the next packet")
    //
    // On the slave side, the s_new_word signal means "you are being provided with a valid word. Make sure to load the data lines into a register on 
    // the next rising clock edge."
    // The s_new_packet signal means "
    wire m_select = m_axis_last;
    wire m_new_word = (m_axis_valid == 1'b1 && m_axis_ready == 1'b1) ? 1'b1 : 1'b0;
    wire m_new_packet = (m_new_word == 1'b1 && m_axis_last == 1'b1) ? 1'b1 : 1'b0;
    
    wire s_select = s_axis_last;
    wire s_new_word = (s_axis_valid == 1'b1 && s_axis_ready == 1'b1) ? 1'b1 : 1'b0;
    wire s_new_packet = (s_new_word == 1'b1 && s_axis_last == 1'b1) ? 1'b1 : 1'b0;
    
    // Establish a register for new_packet on the slave (receive) interface with a default value of low
// JMK commented out    reg s_new_packet_r = 1'b0;
    reg s_new_packet_r1 = 1'b0; //JMK added
    reg s_new_packet_r2 = 1'b0; //JMK added
//    reg [15:0] write_address = 16'h0000;
//    reg [15:0] read_address = 16'h0000;   
//    reg [3:0] write_address = 4'h0;
//    reg [3:0] read_address = 4'h0;   
    reg [12:0] write_address = 13'h0000;
    reg [12:0] read_address = 13'h0000;  
//    reg [47:0] write_data = 48'hFFFFFFFFFFFFFF;
    wire [47:0] read_data;
        
    ///I added the below instantiation
    dist_mem_gen_0 myDistMem (
        .a(write_address),      // address for synchronous writes to RAM [12 : 0]
        .d({data[1][23:0],data[0][23:0]}),  // data lines for synchronous writes to RAM [47 : 0]
        .clk(clk),  // clock for synchronous writes to RAM
        .we(s_new_packet_r1),    // enables synchronous writes to RAM
        
        .dpra(read_address),  // address for asynchronous reads from RAM [12 : 0]
        .dpo(read_data)    // data for asynchronous reads from RAM [47 : 0]
    );
  
    
  
    // The next lines "debounce" the switch settings, making them propagate across three clock ticks before being latched into 
    // sw_sync_r[2] on the third clock edge. Note that the width of the register in this case is 4 bits (there are four switches)
    // Note that the only use of that switch setting is in this section below, where the multiplier is basically just the fraction
    // of sw_sync/4'b1111.  sw_sync is the "synchronized" output of these registers. The purpose of the code section below is to 
    // synchronize the switch inputs, and determine the multiplier.
    // The second purpose is to load s_new_packet_r. Remember that s_new_packet is an asynchronous signal, which basically says "on the next clock tick, 
    // you're going to load the last word in a packet. s_new_packet will trail that by one clock tick and basically says "you just loaded the end of a packet
    // so do the multiplication on the next clock tick (this happens in another always block)." This always block will typically keep s_new_packet_r high for
    // only one clock tick (I think)
    always@(posedge clk) begin
        sw_sync_r[2] <= sw_sync_r[1];
        sw_sync_r[1] <= sw_sync_r[0];
        sw_sync_r[0] <= sw;
        
//        if (&sw_sync == 1'b1)
//            multiplier <= {1'b1, {MULTIPLIER_WIDTH{1'b0}}};
//        else
            // multiplier <= {1'b0, sw, {MULTIPLIER_WIDTH-SWITCH_WIDTH{1'b0}}} + 1;
            
            //For the "stock" case, the multiplier width is 24 bits wide, meaning the range of muliplier is
            // is 24'hFFFFFF all the way down to 0
            multiplier <= {sw_sync,{MULTIPLIER_WIDTH{1'b0}}} / {SWITCH_WIDTH{1'b1}};
        
        s_new_packet_r1 <= s_new_packet;
        s_new_packet_r2 <= s_new_packet_r1;
    end
    
    // This is only for receiving data from the ADC. If "new word" is flagged, it means that valid data will appear on the data lines. On the next clock
    // edge, pull that data off of the data lines and put it into the either of the two data registers, depending on s_select.
    // It also says that after all words have been latched into data (both left and right words, that is), see if s_new_packet_r is high (it usually will be
    // after having loaded those words. If so, it means a complete new packet has just been loaded, so on the next clock tick, perform the multiply operation.   
    always@(posedge clk)
        if (s_new_word == 1'b1) // sign extend and register AXIS slave data. This will add 24 binary zeros to the 
            // left of most positive entries. It will add 24 binary ones to the left of any negative entries.
            data[s_select] <= {{MULTIPLIER_WIDTH{s_axis_data[DATA_WIDTH-1]}}, s_axis_data};
        else if (s_new_packet_r2 == 1'b1) begin //data gets written automatically when s_new_packet_r1 was high, so this is a read cycle
            // 
            //data[0] <= $signed(read_data[23:0]) * multiplier; // core volume control algorithm, infers a DSP48 slice
            //data[1] <= $signed(read_data[47:24]) * multiplier;
            //To emulate a multiplication by "1" (That's going to left shift everything by 24 bits
            
            //The case statement below will combine the time delayed term from memory (the first term in most
            //expressions below) with the current input. The time delayed term has adjustable volume, depending
            //on the positions of the two most significant switches out of the four inputs. The case statement
            //adjusts the "volume" of the time delayed signal by shifting it a greater or lesser amount to the
            //left. Note that what's stored in memory is just the 24 bit samples... a left and a right sample
            //lead to a lower and higher one in memory, for a 48 bit word.
            //Because I wanted to keep most modifications to the factory code in this always block, I've stored
            //samples as they come, and am stuffing the sums into the 48-bit data word, basically using the upper
            //24-bits of that 48 bit word to capture each sample. Note that when these are played back onto the 
            //master interface in a separate always block, only the upper 24-bits is placed on the wire. This is
            //to allow for a multiplication operation between two 24-bit numbers.
            //
            //Delay is changed by grabbing samples from further back in memory, depending on the switch positions
            //It turns out that 8192 words in memory is about as bit as we can store in my Basys3's FPGA.
            //That's OK. I've determined that going back in time 3000 samples (about 70 milliseconds of delay)
            //and the positions of the two lowest order switches of the four will control the amount of time
            //delay
            case (sw[3:2]) 
                2'b00: begin
                            //For the final design, just comment out this line so we have the values in data stay the same
                            //data[0] <= {read_data[23],read_data[23],read_data[23],read_data[23:0],21'h000000};
                            //data[1] <= {read_data[47],read_data[47],read_data[47],read_data[47:24],21'h000000};
                            data[0] <= {data[0][23:0],24'h000000};
                            data[1] <= {data[1][23:0],24'h000000};
                       end
                2'b01: begin
                            data[0] <= {read_data[23],read_data[23],read_data[23:0],22'h000000} + {data[0][23:0],24'h000000};
                            data[1] <= {read_data[47],read_data[47],read_data[47:24],22'h000000} + {data[1][23:0],24'h000000};
                       end              
                2'b10: begin
                            data[0] <= {read_data[23],read_data[23:0],23'h000000} + {data[0][23:0],24'h000000};
                            data[1] <= {read_data[47],read_data[47:24],23'h000000}+ {data[1][23:0],24'h000000};
                       end
                default: begin
                            data[0] <= {read_data[23:0],24'h000000} + {data[0][23:0],24'h000000};
                            data[1] <= {read_data[47:24],24'h000000} + {data[1][23:0],24'h000000};
                       end                                              
            endcase
            write_address <= write_address + 1'b1;
            
            case (sw[1:0])
                2'b00: read_address <= write_address - 1500;
                2'b01: read_address <= write_address - 2000;
                2'b10: read_address <= write_address - 2500;
                default: read_address <= write_address - 3000;
            endcase
        end
        
    // The next block sets m_axis_valid. The decision to put data on the data lines is driven to match the valid signal in another block.
    // The first part of the logic says "if we clocked a packet on the slave interface on the previous edge (which sets s_new_packer_r), use the current
    // clock edge to set valid (so data will be clocked out on the master interface on the next edge."
    // The second part of the logic says "If we are currently clocking out the lts word of a packet on the master interface, clear the valid line
    // (since we don't have any more data left to clock out)
    always@(posedge clk)
        if (s_new_packet_r2 == 1'b1)
            m_axis_valid <= 1'b1;
        else if (m_new_packet == 1'b1)
            m_axis_valid <= 1'b0;
           
    // This next always block "unwinds" the logic that creates the asynchronous signals m_new_word and m_new_packet. 
    // Remember that m_new_packet is determined by ANDing m_new_word with m_axis_last. As a result, the always block below effectively toggles
    // m_axis_last, and ensures that both it and m_new_packet last only for one clock period.
    // The second part of the always block basically says that m_axis_last gets set for the second half of the two word packet.
    always@(posedge clk)
        if (m_new_packet == 1'b1)
            m_axis_last <= 1'b0;
        else if (m_new_word == 1'b1)
            m_axis_last <= 1'b1;
            
    // The block below is NOT SYNCHRONOUS with clk! It's all combinatorial logic as opposed to sequential
    // This block basically makes sure that valid data is placed on the lines, to track with m_axis_valid. THAT signal is changed synchronously wih clk.
    // The m_select register will say which of the two data registers (left or right) is placed on the lines.
    always@(m_axis_valid, data[0], data[1], m_select)
        if (m_axis_valid == 1'b1)
            m_axis_data = data[m_select][MULTIPLIER_WIDTH+DATA_WIDTH-1:MULTIPLIER_WIDTH]; //This is really only going to put the upper 24 bits on the data lines
        else
            m_axis_data = 'b0;
            
    // As the comments from the top of the file state, "Reception of data on the slave interface is halted while processing and transfer is taking place.
    // The way data is throttled is via the s_axis_ready line. The next always block is how that throttling takes place.
    // First part of logic says "if you're currently clocking IN the last word of a packet, on the slave interface, tell the master not to send more data"
    // The second part says "if we're currently clocking OUT the last word of a packet, on the master interface, we're good to receive more data on the
    // slave interface.
    always@(posedge clk)
        if (s_new_packet == 1'b1)
            s_axis_ready <= 1'b0;
        else if (m_new_packet == 1'b1)
            s_axis_ready <= 1'b1;
endmodule