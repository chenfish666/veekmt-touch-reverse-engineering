// ============================================================================
// i2c_touch_config.v  --  CY8CTMG120 v24  (DECODED: outputs real X / Y)
//
// FORMAT CRACKED (4-corner data at 1kHz, pointer read + handshake):
//   It is the standard cyttsp gen3 layout after all:
//     reg3 = X_hi, reg4 = X_lo   -> X = {rx3,rx4} big-endian  (~49..755)
//     reg5 = Y_hi, reg6 = Y_lo   -> Y = {rx5,rx6} big-endian  (~33..408)
//   on an 800x480 panel. So:
//     x_coord[9:0] = {rx3[1:0], rx4}
//     y_coord[8:0] = {rx5[0],  rx6}
//
// Working recipe (all required): addr 0x08, ~1kHz (4kHz is too marginal),
//   open-drain SCL + clock-stretch handling, POINTER read from reg0, and a
//   HANDSHAKE write (rx0^0x80 -> reg0) after EVERY read so the chip keeps
//   producing fresh samples and does not re-stick.  Power-cycle the board once
//   after programming to give the touch chip a clean start.
//
// Outputs:
//   oREG_X1[9:0] = X      oREG_Y1[8:0] = Y      (raw chip coordinates)
//   oREG_TOUCH_COUNT = rx2 (status/te count, for observation)
//   oREG_GESTURE[4] = touch_valid (LEDG7), [3]=heartbeat, [1]=stretch_seen,
//                     [0]=handshake-write ACK
//   touch_valid = X high byte in range (rx3[7:4]==0); FF when no touch.
//
// camera.v already feeds oREG_X1/oREG_Y1 to ltp_controller and shows the low
// bytes on HEX7HEX6 (X_lo) / HEX1HEX0 (Y_lo) for verification.
// TOUCH_I2C_SCL must be `inout` (from v19).
// ============================================================================

module i2c_touch_config(
    iCLK, iRSTN, iTRIG, iSW, oREADY,
    oREG_X1, oREG_Y1, oREG_X2, oREG_Y2,
    oREG_TOUCH_COUNT, oREG_GESTURE,
    I2C_SCLK, I2C_SDAT
);

input                iCLK;
input                iRSTN;
input                iTRIG;
input        [17:0]  iSW;
output reg           oREADY;
output reg    [9:0]  oREG_X1;
output reg    [8:0]  oREG_Y1;
output reg    [9:0]  oREG_X2;
output reg    [8:0]  oREG_Y2;
output reg    [7:0]  oREG_TOUCH_COUNT;
output reg    [7:0]  oREG_GESTURE;
inout                I2C_SCLK;
inout                I2C_SDAT;

//===========================================================================
parameter    CLK_FREQ    = 50_000_000;
localparam   DEV_ADDR    = 7'h08;
localparam   NUM_REG     = 5'd9;
localparam   STRETCH_MAX = 8'd100;
localparam   POLL_GAP    = 23'd60_000;
localparam   TICK_DIV    = 14'd10000;     // ~1kHz (clean; 4kHz too marginal)

localparam   ST_WAIT  = 4'd0,  ST_START  = 4'd1,  ST_WADDR = 4'd2,  ST_RSTART = 4'd3,
             ST_RADDR = 4'd4,  ST_DATA   = 4'd5,  ST_STOP  = 4'd6,
             ST_HSTART= 4'd7,  ST_HBYTE  = 4'd8,  ST_HSTOP = 4'd9,  ST_LATCH = 4'd10;

//===========================================================================
reg          scl, sda_o;
reg   [3:0]  state;
reg   [2:0]  phase;
reg   [3:0]  bit_cnt, byte_idx;
reg   [7:0]  sh_wr, sh_rd;
reg   [7:0]  rx0,rx1,rx2,rx3,rx4,rx5,rx6,rx7,rx8;
reg  [13:0]  tick_cnt;
reg  [22:0]  poll_cnt;
reg   [7:0]  stretch_cnt;
reg          devw_ack, stretch_seen;
reg  [24:0]  hb_cnt;

wire         tick     = (tick_cnt == TICK_DIV - 14'd1);
wire         sda_in;
wire         scl_in;
wire  [7:0]  devW = {DEV_ADDR,1'b0};
wire  [7:0]  devR = {DEV_ADDR,1'b1};
wire         hb   = hb_cnt[24];
wire         scl_ready = scl_in | (stretch_cnt >= STRETCH_MAX);

// decoded coordinates (combinational from latest read)
wire  [9:0]  x_dec = {rx3[1:0], rx4};
wire  [8:0]  y_dec = {rx5[0],  rx6};
wire         touch_valid = (rx3[7:4] == 4'h0);   // X hi in range; FF -> no touch

reg  [7:0] hs_nxt;
always @(*)
    case (byte_idx + 4'd1)
    4'd1: hs_nxt = 8'h00; default: hs_nxt = rx0 ^ 8'h80;
    endcase

assign    I2C_SCLK = scl   ? 1'bz : 1'b0;
assign    I2C_SDAT = sda_o ? 1'bz : 1'b0;
assign    scl_in   = I2C_SCLK;
assign    sda_in   = I2C_SDAT;

always @(posedge iCLK or negedge iRSTN)
    if (!iRSTN) tick_cnt<=0; else if (tick) tick_cnt<=0; else tick_cnt<=tick_cnt+14'd1;
always @(posedge iCLK or negedge iRSTN)
    if (!iRSTN) hb_cnt<=0; else hb_cnt<=hb_cnt+25'd1;

always @(*)
begin
    oREG_X1 = x_dec;
    oREG_Y1 = y_dec;
    oREG_X2 = 10'd0; oREG_Y2 = 9'd0; oREG_TOUCH_COUNT = rx2;
    oREG_GESTURE      = 8'b0;
    oREG_GESTURE[4]   = touch_valid;   // LEDG7 = finger on screen
    oREG_GESTURE[3]   = hb;            // LEDG3 = heartbeat
    oREG_GESTURE[1]   = stretch_seen;  // LEDG2
    oREG_GESTURE[0]   = devw_ack;      // LEDG1 = handshake ACK
end

//===========================================================================
always @(posedge iCLK or negedge iRSTN)
begin
    if (!iRSTN)
    begin
        scl<=1; sda_o<=1; state<=ST_WAIT; bit_cnt<=0; byte_idx<=0;
        phase<=0; sh_wr<=0; sh_rd<=0; oREADY<=0; poll_cnt<=0;
        devw_ack<=0; stretch_seen<=0; stretch_cnt<=0;
        rx0<=0;rx1<=0;rx2<=0;rx3<=0;rx4<=0;rx5<=0;rx6<=0;rx7<=0;rx8<=0;
    end
    else
    begin
        oREADY<=1'b0;

        if (state==ST_WAIT)
        begin
            scl<=1; sda_o<=1;
            if (poll_cnt >= POLL_GAP) begin poll_cnt<=0; phase<=0; stretch_seen<=0; state<=ST_START; end
            else poll_cnt<=poll_cnt+23'd1;
        end
        else if (tick)
        begin
            case (state)

            ST_START:
            begin
                case (phase)
                0: begin scl<=1; sda_o<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=1; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                1: begin sda_o<=0; phase<=2; end
                2: begin scl<=0;   phase<=3; end
                3: begin sh_wr<=devW; byte_idx<=0; bit_cnt<=0; phase<=0; state<=ST_WADDR; end
                default: phase<=0;
                endcase
            end

            ST_WADDR:
            begin
                case (phase)
                0: begin scl<=0; sda_o<=(bit_cnt==8)?1'b1:sh_wr[7]; phase<=1; end
                1: begin scl<=0; phase<=2; end
                2: begin scl<=1; phase<=3; end
                3: begin scl<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=4; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                4: begin
                        scl<=0; phase<=0;
                        if (bit_cnt==8) begin
                            bit_cnt<=0;
                            if (byte_idx==4'd0) begin byte_idx<=4'd1; sh_wr<=8'h00; end
                            else state<=ST_RSTART;
                        end else begin sh_wr<={sh_wr[6:0],1'b0}; bit_cnt<=bit_cnt+4'd1; end
                   end
                default: phase<=0;
                endcase
            end

            ST_RSTART:
            begin
                case (phase)
                0: begin scl<=0; sda_o<=1; phase<=1; end
                1: begin scl<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=2; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                2: begin sda_o<=0; phase<=3; end
                3: begin scl<=0; sh_wr<=devR; bit_cnt<=0; phase<=0; state<=ST_RADDR; end
                default: phase<=0;
                endcase
            end

            ST_RADDR:
            begin
                case (phase)
                0: begin scl<=0; sda_o<=(bit_cnt==8)?1'b1:sh_wr[7]; phase<=1; end
                1: begin scl<=0; phase<=2; end
                2: begin scl<=1; phase<=3; end
                3: begin scl<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=4; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                4: begin
                        scl<=0; phase<=0;
                        if (bit_cnt==8) begin bit_cnt<=0; byte_idx<=0; state<=ST_DATA; end
                        else begin sh_wr<={sh_wr[6:0],1'b0}; bit_cnt<=bit_cnt+4'd1; end
                   end
                default: phase<=0;
                endcase
            end

            ST_DATA:
            begin
                case (phase)
                0: begin
                        scl<=0;
                        sda_o <= (bit_cnt==8) ? ((byte_idx==NUM_REG-1)?1'b1:1'b0) : 1'b1;
                        phase<=1;
                   end
                1: begin scl<=0; phase<=2; end
                2: begin scl<=1; phase<=3; end
                3: begin scl<=1;
                        if (scl_ready) begin
                            if (bit_cnt<8) sh_rd<={sh_rd[6:0],sda_in};
                            stretch_cnt<=0; phase<=4;
                        end else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                4: begin
                        scl<=0; phase<=0;
                        if (bit_cnt==8) begin
                            bit_cnt<=0;
                            case (byte_idx)
                            4'd0: rx0<=sh_rd;  4'd1: rx1<=sh_rd;
                            4'd2: rx2<=sh_rd;  4'd3: rx3<=sh_rd;
                            4'd4: rx4<=sh_rd;  4'd5: rx5<=sh_rd;
                            4'd6: rx6<=sh_rd;  4'd7: rx7<=sh_rd;
                            4'd8: rx8<=sh_rd;
                            endcase
                            if (byte_idx==NUM_REG-1) state<=ST_STOP;
                            else byte_idx<=byte_idx+4'd1;
                        end else bit_cnt<=bit_cnt+4'd1;
                   end
                default: phase<=0;
                endcase
            end

            ST_STOP:
            begin
                case (phase)
                0: begin scl<=0; sda_o<=0; phase<=1; end
                1: begin scl<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=2; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                2: begin sda_o<=1; phase<=3; end
                3: begin phase<=0; byte_idx<=0; state<=ST_HSTART; end
                default: phase<=0;
                endcase
            end

            ST_HSTART:
            begin
                case (phase)
                0: begin scl<=1; sda_o<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=1; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                1: begin sda_o<=0; phase<=2; end
                2: begin scl<=0;   phase<=3; end
                3: begin sh_wr<=devW; byte_idx<=0; bit_cnt<=0; phase<=0; state<=ST_HBYTE; end
                default: phase<=0;
                endcase
            end

            ST_HBYTE:
            begin
                case (phase)
                0: begin scl<=0; sda_o<=(bit_cnt==8)?1'b1:sh_wr[7]; phase<=1; end
                1: begin scl<=0; phase<=2; end
                2: begin scl<=1; phase<=3; end
                3: begin scl<=1;
                        if (scl_ready) begin
                            if (bit_cnt==8 && byte_idx==4'd0) devw_ack <= (sda_in==1'b0);
                            stretch_cnt<=0; phase<=4;
                        end else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                4: begin
                        scl<=0; phase<=0;
                        if (bit_cnt==8) begin
                            bit_cnt<=0;
                            if (byte_idx==4'd2) state<=ST_HSTOP;
                            else begin byte_idx<=byte_idx+4'd1; sh_wr<=hs_nxt; end
                        end else begin sh_wr<={sh_wr[6:0],1'b0}; bit_cnt<=bit_cnt+4'd1; end
                   end
                default: phase<=0;
                endcase
            end

            ST_HSTOP:
            begin
                case (phase)
                0: begin scl<=0; sda_o<=0; phase<=1; end
                1: begin scl<=1;
                        if (scl_ready) begin stretch_cnt<=0; phase<=2; end
                        else begin stretch_seen<=1; stretch_cnt<=stretch_cnt+8'd1; end end
                2: begin sda_o<=1; phase<=3; end
                3: begin phase<=0; state<=ST_LATCH; end
                default: phase<=0;
                endcase
            end

            ST_LATCH: begin oREADY<=1'b1; poll_cnt<=0; state<=ST_WAIT; end
            default:  state<=ST_WAIT;
            endcase
        end
    end
end

endmodule