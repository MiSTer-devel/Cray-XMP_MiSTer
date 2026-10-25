//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

`include "build_id.v" 
localparam CONF_STR = {
	"Cray-XMP;;",
	"-;",
	"F1,IOS,Load boot file,34000000;",
	"S0,IMG,Expander disk;",
	"S1,IMG,Disk drives;",
	"S2,TXT,Printer file;",
	"S3,TAP,Tape;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[6:5],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[9:7],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[4:3],Text color,White,Green,Amber,Cyan;",
	"O[14],Font,8x8 (15kHz),8x16 (31kHz);",
	"O[15],Device times,Fast,Real;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,1;", // [optional] config version 0-99. 
	        // If CONF_STR options are changed in incompatible way, then change version number too,
			  // so all options will get default values on first start.
	"V,v",`BUILD_DATE 
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(4), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_ios),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	
	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(clk_50m_global),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset;

wire [1:0] col = status[4:3];

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
reg ce_pix;
wire hvcnt_atzero;
wire video;

// Leave H/V sync always on. This stabilizes the video output while the core
// is in reset. This example releases the reset when H/V counters are at zero.
reg reset_core = 1;
always @(posedge clk_sys) begin
	if(reset) reset_core <= 1;
	else if(hvcnt_atzero) reset_core <= 0;
end

wire [21:0] gamma_bus;
wire ioctl_download;

wire [31:0] sd_lba[4];
wire [5:0] sd_blk_cnt[4];
wire [3:0] sd_rd, sd_wr, sd_ack;
wire [13:0] sd_buff_addr;
wire [7:0] sd_buff_dout;
wire [7:0] sd_buff_din[4];
wire sd_buff_wr;
wire [3:0] img_mounted;
wire [63:0] img_size;
wire img_readonly;

localparam CLK_HZ = 58800000;
localparam IOS_HZ = 80000000;

wire clk_cpu, clk_ios;

wire clk_50m_global;
cyclonev_clkena #(
	.clock_type("Global Clock"),
	.ena_register_mode("always enabled")
) ref_video
(
	.inclk(CLK_50M),
	.ena(1'b1),
	.enaout(),
	.outclk(clk_50m_global)
);

pll_cpu pll_cpu
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_cpu),
	.locked()
);
pll_ios pll_ios
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_ios),
	.locked()
);

wire uart_break, uart_break_cpu;
cdc_bit sync_break
(
	.clk(clk_cpu),
	.d(uart_break),
	.q(uart_break_cpu)
);

reg host_reset_ios;
wire host_reset;
always @(posedge clk_ios) host_reset_ios <= RESET | status[0] | buttons[1] | ioctl_download;
cdc_bit sync_host_reset
(
	.clk(clk_cpu),
	.d(host_reset_ios),
	.q(host_reset)
);

reg reset_cpu, uart_reset_cpu;
reg [15:0] reset_cnt;

always @(posedge clk_cpu) begin
	uart_reset_cpu <= host_reset;
	if(host_reset | uart_break_cpu) begin
		reset_cpu <= 1;
		reset_cnt <= '1;
	end else if(reset_cnt != 0) reset_cnt <= reset_cnt - 1'd1;
	else reset_cpu <= 0;
end

wire reset_ios;
cdc_bit sync_reset_ios
(
	.clk(clk_ios),
	.d(reset_cpu),
	.q(reset_ios)
);

wire uart_reset;
cdc_bit sync_reset
(
	.clk(clk_sys),
	.d(reset_cpu),
	.q(reset)
);
cdc_bit sync_uart_reset
(
	.clk(clk_sys),
	.d(uart_reset_cpu),
	.q(uart_reset)
);

localparam [2:0] CENTRAL = 3'b000;
localparam [2:0] BUFFER  = 3'b001;

wire mem_req, mem_we, mem_take, mem_ack;
wire [6:0] mem_len;
wire [21:0] mem_addr;
wire [63:0] mem_wdata;

wire cm_req, cm_we, cm_ack;
wire [21:0] cm_addr;
wire [63:0] cm_wdata;

wire bm_req, bm_we, bm_ack;
wire [23:0] bm_addr;
wire [63:0] bm_wdata;

wire tape_req, tape_ack;
wire [20:0] tape_addr;
wire [24:0] tape_base;
wire [23:0] tape_bytes;

wire boot_req, boot_we, boot_ack;
wire [24:0] boot_addr;
wire [63:0] boot_wdata;
wire boot_done, boot_missing;

wire [63:0] mem_rdata;
wire [3:0] other_take;
wire cpu_held;

ddr3_ports #(
	.N(5),
	.STREAM(5'b00001)
) ddr3
(
	.clk(clk_cpu),
	.reset(reset_cpu),

	.req({boot_req, tape_req, bm_req, cm_req, mem_req}),
	.we({boot_we, 1'b0, bm_we, cm_we, mem_we}),
	.len({7'd1, 7'd1, 7'd1, 7'd1, mem_len}),
	.addr({boot_addr, tape_base + {4'd0, tape_addr}, BUFFER, bm_addr[21:0], CENTRAL, cm_addr, CENTRAL, mem_addr}),
	.wdata({boot_wdata, 64'd0, bm_wdata, cm_wdata, mem_wdata}),
	.user_rst({4'b0000, cpu_held}),
	.take({other_take, mem_take}),
	.ack({boot_ack, tape_ack, bm_ack, cm_ack, mem_ack}),
	.rdata(mem_rdata),

	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

parameter [24:0] CLEAR = 25'h0800000;

xmp_boot #(
	.FILE(25'h0800000),
	.BUFFER({BUFFER, 22'd0}),
	.CLEAR(CLEAR)
) boot
(
	.clk(clk_cpu),
	.reset(reset_cpu),

	.o_req(boot_req),
	.o_we(boot_we),
	.o_addr(boot_addr),
	.o_wdata(boot_wdata),
	.i_ack(boot_ack),
	.i_rdata(mem_rdata),

	.o_done(boot_done),
	.o_missing(boot_missing),
	.o_tape_bytes(tape_bytes),
	.o_tape(tape_base)
);

wire [5:0] key_valid, key_ready, char_valid, char_ready;
wire [41:0] key, char;

wire [31:0] drive_lba;
wire [8:0] drive_rd, drive_wr;

wire [7:0] print_char;
wire print_valid;

xmp_machine #(.CLOCKS_PER_MS(IOS_HZ / 1000)) machine
(
	.clk(clk_cpu),
	.clk_ios(clk_ios),
	.rst(reset_cpu | ~boot_done),
	.i_real(status[15]),

	.o_mem_req(mem_req),
	.o_mem_we(mem_we),
	.o_mem_len(mem_len),
	.o_mem_addr(mem_addr),
	.o_mem_wdata(mem_wdata),
	.i_mem_take(mem_take),
	.i_mem_ack(mem_ack),
	.i_mem_rdata(mem_rdata),

	.o_cm_req(cm_req),
	.o_cm_we(cm_we),
	.o_cm_addr(cm_addr),
	.o_cm_wdata(cm_wdata),
	.i_cm_ack(cm_ack),
	.i_cm_rdata(mem_rdata),

	.o_bm_req(bm_req),
	.o_bm_we(bm_we),
	.o_bm_addr(bm_addr),
	.o_bm_wdata(bm_wdata),
	.i_bm_ack(bm_ack),
	.i_bm_rdata(mem_rdata),

	.i_key_valid(key_valid),
	.i_key(key),
	.o_key_ready(key_ready),
	.o_char_valid(char_valid),
	.o_char(char),
	.i_char_ready(char_ready),

	.o_tape_req(tape_req),
	.o_tape_addr(tape_addr),
	.i_tape_ack(tape_ack),
	.i_tape_data(mem_rdata),
	.i_tape_bytes(tape_bytes),

	.i_reel_mounted(img_mounted[3]),
	.i_reel_blocks(img_size[63:9]),
	.i_reel_readonly(img_readonly),
	.o_reel_lba(sd_lba[3]),
	.o_reel_rd(sd_rd[3]),
	.o_reel_wr(sd_wr[3]),
	.i_reel_ack(sd_ack[3]),
	.i_reel_buff_addr(sd_buff_addr[8:0]),
	.i_reel_buff_dout(sd_buff_dout),
	.o_reel_buff_din(sd_buff_din[3]),
	.i_reel_buff_wr(sd_buff_wr),

	.o_sd_lba(sd_lba[0]),
	.o_sd_rd(sd_rd[0]),
	.o_sd_wr(sd_wr[0]),
	.i_sd_ack(sd_ack[0]),
	.i_sd_buff_addr(sd_buff_addr[8:0]),
	.i_sd_buff_dout(sd_buff_dout),
	.o_sd_buff_din(sd_buff_din[0]),
	.i_sd_buff_wr(sd_buff_wr),

	.o_print_valid(print_valid),
	.o_print(print_char),
	.i_print_ready(spool_ready && shown_ready),

	.o_drive_lba(drive_lba),
	.o_drive_rd(drive_rd),
	.o_drive_wr(drive_wr),
	.i_drive_ack({9{sd_ack[1]}}),
	.i_drive_buff_addr(sd_buff_addr[11:0]),
	.i_drive_buff_dout(sd_buff_dout),
	.o_drive_buff_din(sd_buff_din[1]),
	.i_drive_buff_wr(sd_buff_wr),

	.o_cpu_held(cpu_held),
	.o_step(),
	.o_p()
);

localparam [31:0] DRIVE_BLOCKS = 32'd1185120;

reg [31:0] drive_base;
always @(*) begin
	drive_base = 32'd0;
	for(int n = 1; n < 9; n = n + 1) if (drive_rd[n] | drive_wr[n]) drive_base = n * DRIVE_BLOCKS;
end

wire spool_ready, shown_ready;

print_spool spool
(
	.clk(clk_ios),

	.i_char(print_char),
	.i_valid(print_valid && shown_ready),
	.o_ready(spool_ready),

	.i_mounted(img_mounted[2]),
	.i_blocks(img_size[40:9]),
	.o_lba(sd_lba[2]),
	.o_rd(sd_rd[2]),
	.o_wr(sd_wr[2]),
	.i_ack(sd_ack[2]),
	.i_buff_addr(sd_buff_addr[8:0]),
	.i_buff_dout(sd_buff_dout),
	.o_buff_din(sd_buff_din[2]),
	.i_buff_wr(sd_buff_wr && sd_ack[2])
);

assign sd_rd[1]       = |drive_rd;
assign sd_wr[1]       = |drive_wr;
assign sd_lba[1]      = drive_base + drive_lba;
assign sd_blk_cnt[0]  = 6'd0;
assign sd_blk_cnt[1]  = 6'd7;
assign sd_blk_cnt[2]  = 6'd0;
assign sd_blk_cnt[3]  = 6'd0;

localparam OPERATOR = 3;
localparam STATION  = 0;

assign char_ready[1] = 1'b1;
assign char_ready[2] = 1'b1;
assign char_ready[4] = 1'b1;
assign char_ready[5] = 1'b1;
assign key_valid[1]  = 1'b0;
assign key_valid[2]  = 1'b0;
assign key_valid[4]  = 1'b0;
assign key_valid[5]  = 1'b0;
assign key[13:7]     = 7'd0;
assign key[20:14]    = 7'd0;
assign key[41:28]    = 14'd0;

wire [13:0] con_tx_data, con_rx_data, term_data;
wire [1:0] con_tx_valid, con_tx_ready, con_rx_valid, con_rx_ready, term_valid, term_ready;

cdc_stream #(.W(7)) operator_tx
(
	.src_clk(clk_ios),
	.src_reset(reset_ios),
	.src_data(char[7*OPERATOR+:7]),
	.src_valid(char_valid[OPERATOR]),
	.src_ready(char_ready[OPERATOR]),
	.dst_clk(clk_sys),
	.dst_reset(reset),
	.dst_data(con_tx_data[6:0]),
	.dst_valid(con_tx_valid[0]),
	.dst_ready(con_tx_ready[0])
);

cdc_stream #(.W(7)) station_tx
(
	.src_clk(clk_ios),
	.src_reset(reset_ios),
	.src_data(char[7*STATION+:7]),
	.src_valid(char_valid[STATION]),
	.src_ready(char_ready[STATION]),
	.dst_clk(clk_sys),
	.dst_reset(reset),
	.dst_data(con_tx_data[13:7]),
	.dst_valid(con_tx_valid[1]),
	.dst_ready(con_tx_ready[1])
);

cdc_stream #(.W(7)) operator_rx
(
	.src_clk(clk_sys),
	.src_reset(reset),
	.src_data(con_rx_data[6:0]),
	.src_valid(con_rx_valid[0]),
	.src_ready(con_rx_ready[0]),
	.dst_clk(clk_ios),
	.dst_reset(reset_ios),
	.dst_data(key[7*OPERATOR+:7]),
	.dst_valid(key_valid[OPERATOR]),
	.dst_ready(key_ready[OPERATOR])
);

cdc_stream #(.W(7)) station_rx
(
	.src_clk(clk_sys),
	.src_reset(reset),
	.src_data(con_rx_data[13:7]),
	.src_valid(con_rx_valid[1]),
	.src_ready(con_rx_ready[1]),
	.dst_clk(clk_ios),
	.dst_reset(reset_ios),
	.dst_data(key[7*STATION+:7]),
	.dst_valid(key_valid[STATION]),
	.dst_ready(key_ready[STATION])
);

reg [2:0] key_tgl;
reg [10:0] ps2_key_s = 0;
always @(posedge clk_sys) begin
	key_tgl <= {key_tgl[1:0], ps2_key[10]};
	if(key_tgl[2] != key_tgl[1]) ps2_key_s <= {~ps2_key_s[10], ps2_key[9:0]};
end

reg [1:0] visible;
reg key_stb;
always @(posedge clk_sys) begin
	key_stb <= ps2_key_s[10];
	if(reset) visible <= 2'd0;
	else if(key_stb != ps2_key_s[10] && ps2_key_s[9:8] == 2'b10) begin
		if(ps2_key_s[7:0] == 8'h05) visible <= 2'd0;
		if(ps2_key_s[7:0] == 8'h06) visible <= 2'd1;
		if(ps2_key_s[7:0] == 8'h04) visible <= 2'd2;
	end
end

wire [6:0] shown_char, prt_data;
wire shown_valid, shown_taken, prt_valid, prt_ready;

print_screen print_screen
(
	.clk(clk_ios),
	.reset(reset_ios),

	.i_char(print_char),
	.i_valid(print_valid && spool_ready),
	.o_ready(shown_ready),

	.o_char(shown_char),
	.o_valid(shown_valid),
	.i_ready(shown_taken)
);

cdc_stream #(.W(7)) printer_tx
(
	.src_clk(clk_ios),
	.src_reset(reset_ios),
	.src_data(shown_char),
	.src_valid(shown_valid),
	.src_ready(shown_taken),
	.dst_clk(clk_sys),
	.dst_reset(reset),
	.dst_data(prt_data),
	.dst_valid(prt_valid),
	.dst_ready(prt_ready)
);

wire no_file, started;
cdc_bit sync_no_file
(
	.clk(clk_sys),
	.d(boot_missing),
	.q(no_file)
);
cdc_bit sync_started
(
	.clk(clk_sys),
	.d(boot_done),
	.q(started)
);

wire [7:0] kbd_data;
wire kbd_valid, kbd_ready;

wire [13:0] sent_data;
wire [1:0] sent_valid, sent_ready;

term_keyboard #(.CAPS(1)) keyboard
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key_s),
	.dout(kbd_data),
	.dout_valid(kbd_valid),
	.dout_ready(kbd_ready)
);

xmp_console #(
	.CLK_HZ(CLK_HZ),
	.BAUD(115200)
) console
(
	.clk(clk_sys),
	.reset(reset),
	.uart_reset(uart_reset),

	.no_file(no_file),
	.started(started),

	.tx_data(con_tx_data),
	.tx_valid(con_tx_valid),
	.tx_ready(con_tx_ready),
	.rx_data(con_rx_data),
	.rx_valid(con_rx_valid),
	.rx_ready(con_rx_ready),

	.term_data(term_data),
	.term_valid(term_valid),
	.term_ready(term_ready),

	.key_data(sent_data),
	.key_valid(sent_valid),
	.key_ready(sent_ready),

	.uart_rxd(UART_RXD),
	.uart_txd(UART_TXD),
	.uart_break(uart_break)
);

reg  [19:0] act_cnt;
always @(posedge clk_cpu) begin
	if(mem_req && !cpu_held) act_cnt <= '1;
	else if(act_cnt != 0) act_cnt <= act_cnt - 1'd1;
end

assign LED_USER = (act_cnt != 0);

reg [19:0] disk_cnt;
always @(posedge clk_ios) begin
	if(|sd_ack) disk_cnt <= '1;
	else if(disk_cnt != 0) disk_cnt <= disk_cnt - 1'd1;
end

assign LED_DISK = {1'b1, disk_cnt != 0};

wire half, bell;

wire font_8x8 = ~status[14];

xmp_terminal terminal
(
	.clk(clk_sys),
	.reset(reset_core),

	.ce_pix(ce_pix),
	.hvcnt_atzero(hvcnt_atzero),

	.hblank(HBlank),
	.hsync(HSync),
	.vblank(VBlank),
	.vsync(VSync),

	.video(video),

	.font_8x8(font_8x8),
	.visible(visible),

	.rx_data({prt_data, term_data}),
	.rx_valid({prt_valid, term_valid}),
	.rx_ready({prt_ready, term_ready}),

	.key_data(kbd_data),
	.key_valid(kbd_valid),
	.key_ready(kbd_ready),

	.tx_data(sent_data),
	.tx_valid(sent_valid),
	.tx_ready(sent_ready),

	.half(half),
	.bell(bell)
);

always @(posedge clk_sys) begin
	reg [1:0] div;
	div    <= div + 2'd1;
	ce_pix <= font_8x8 ? (div == 2'd0) : ~div[0];
end

localparam [14:0] BELL_HALF = 15'(CLK_HZ / 2000 - 1);
reg bell_tone;
reg [14:0] bell_div;
always @(posedge clk_sys)
	if(!bell) begin
		bell_tone <= 1'b0;
		bell_div  <= 15'd0;
	end else if(bell_div == BELL_HALF) begin
		bell_tone <= ~bell_tone;
		bell_div  <= 15'd0;
	end else bell_div <= bell_div + 15'd1;

assign AUDIO_L = {3'd0, bell_tone, 12'd0};
assign AUDIO_R = AUDIO_L;

reg [23:0] rgb;
always @(*) begin
	case(col)
		2'd0: rgb = 24'hFFFFFF;
		2'd1: rgb = 24'h33FF33;
		2'd2: rgb = 24'hFFB000;
		2'd3: rgb = 24'h40FFFF;
	endcase
end

wire [23:0] lit = !video ? 24'd0 : half ? {1'b0, rgb[23:17], 1'b0, rgb[15:9], 1'b0, rgb[7:1]} : rgb;

wire [2:0] fx = status[9:7];

reg doubled;
always @(posedge clk_sys) doubled <= font_8x8 && (forced_scandoubler || (fx != 3'd0));

wire mixer_de;

assign CLK_VIDEO = clk_sys;
assign VGA_SL = (fx > 3'd1) ? fx[1:0] - 2'd1 : 2'd0;

video_mixer #(
	.LINE_LENGTH(640),
	.GAMMA(1)
) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),
	.scandoubler(doubled),
	.hq2x(fx == 3'd1),
	.gamma_bus(gamma_bus),
	.R(lit[23:16]),
	.G(lit[15:8]),
	.B(lit[7:0]),
	.HSync(~HSync),
	.VSync(~VSync),
	.HBlank(HBlank),
	.VBlank(VBlank),
	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(mixer_de)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(mixer_de),
	.ARX((ar == 2'd0) ? 12'd4 : {10'd0, ar - 2'd1}),
	.ARY((ar == 2'd0) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[6:5]})
);

endmodule
