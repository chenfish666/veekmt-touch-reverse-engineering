// ============================================================================
// TOUCH_DETECT.v  --  finger-present detector from the INT line (retriggerable)
//
// Drives oTOUCH_detect from TOUCH_INT_n (active low). The panel is weak and the
// INT line bounces / briefly drops during a press, so a strict symmetric
// debounce could never assert. Instead this is a RETRIGGERABLE one-shot:
//   - assert immediately when a finger is seen (INT low),
//   - HOLD for ~150 ms after the finger was last seen,
// so brief INT dropouts during a press do not clear it. This matches the
// original module's "hold for a while" behaviour but is driven by the clean
// INT line instead of coordinate changes (the chip latches coords, so the old
// coordinate-change method failed).
//
// Coordinate calibration does NOT belong here -- coordinates flow straight from
// i2c_touch_config to ltp_controller; touch regions are tuned in raw coordinate
// space inside ltp_controller.
// ============================================================================
module TOUCH_DETECT(
    iCLK,
    iRST_n,
    iTOUCH_INT_n,    // touch INT pin, active-low (finger down = 0)
    oTOUCH_detect    // 1 = finger present (asserts instantly, holds ~150 ms)
);

input            iCLK;            // 50 MHz
input            iRST_n;
input            iTOUCH_INT_n;
output reg       oTOUCH_detect;

parameter HOLD_CYCLES = 24'd7_500_000;   // ~150 ms @ 50 MHz

// 2-FF synchronizer for the asynchronous INT line
reg int_n_meta, int_n_sync;
always @(posedge iCLK or negedge iRST_n)
    if (!iRST_n) begin int_n_meta <= 1'b1; int_n_sync <= 1'b1; end
    else         begin int_n_meta <= iTOUCH_INT_n; int_n_sync <= int_n_meta; end

wire finger = ~int_n_sync;        // finger down = INT low

// retriggerable one-shot: reload the hold timer whenever a finger is seen
reg [23:0] hold;
always @(posedge iCLK or negedge iRST_n)
    if (!iRST_n)
    begin
        oTOUCH_detect <= 1'b0;
        hold          <= 24'd0;
    end
    else if (finger)
    begin
        oTOUCH_detect <= 1'b1;            // assert instantly on touch
        hold          <= HOLD_CYCLES;     // (re)load hold timer
    end
    else if (hold != 24'd0)
    begin
        oTOUCH_detect <= 1'b1;            // keep high through brief INT dropouts
        hold          <= hold - 24'd1;
    end
    else
        oTOUCH_detect <= 1'b0;            // released long enough -> clear

endmodule