`default_nettype none

// TOP MODULE

module wokwi (
    input wire CLK,
    input wire  RST,
    input wire  BTN0,
    input wire  BTN1,
    input wire  BTN2,
    input wire BTN3,
    output wire LED0,
    output wire LED1,
    output wire LED2,
    output wire LED3,
    output wire SND,
    output wire [6:0] SEG,
    output wire [5:0] AN
);

  // 50 MHz clock → 50000 ticks/ms
  localparam TICKS_PER_MILLI = 50000;

  wire [7:0] score;
  wire [3:0] led_internal;
  wire [3:0] btn_clean;

  // debounce buttons
  debounce db0 (.clk(CLK), .btn_in(BTN0), .btn_out(btn_clean[0]));
  debounce db1 (.clk(CLK), .btn_in(BTN1), .btn_out(btn_clean[1]));
  debounce db2 (.clk(CLK), .btn_in(BTN2), .btn_out(btn_clean[2]));
  debounce db3 (.clk(CLK), .btn_in(BTN3), .btn_out(btn_clean[3]));

  simon simon1 (
      .clk   (CLK),
      .rst   (RST),
      .ticks_per_milli (TICKS_PER_MILLI),
      .btn   ({btn_clean[3], btn_clean[2], btn_clean[1], btn_clean[0]}),
      .led   (led_internal),
      .sound (SND),
      .score (score)
  );

  // invert if LEDs are active-low
  assign {LED3, LED2, LED1, LED0} = ~led_internal;

  seven_seg display (
      .clk   (CLK),
      .score (score),
      .seg   (SEG),
      .an    (AN)
  );

endmodule

// DEBOUNCE

module debounce(
    input wire clk,
    input wire btn_in,
    output reg btn_out
);
  reg [19:0] counter = 0;
  reg btn_sync = 0;

  always @(posedge clk) begin
    btn_sync <= btn_in;
    if (btn_sync == btn_out)
      counter <= 0;
    else begin
      counter <= counter + 1;
      if (counter == 20'hFFFFF)
        btn_out <= btn_sync;
    end
  end
endmodule


// SOUND GENERATOR

module play (
    input wire clk,
    input wire rst,
    input wire [15:0] ticks_per_milli,
    input wire [9:0] freq,
    output reg sound
);
  reg [31:0] tick_counter;
  wire [31:0] ticks_per_second = ticks_per_milli * 1000;

  always @(posedge clk) begin
    if (rst) begin
      tick_counter <= 0;
      sound <= 0;
    end else if (freq == 0) begin
      sound <= 0;
    end else begin
      tick_counter <= tick_counter + freq;
      if (tick_counter >= (ticks_per_second >> 1)) begin
        sound <= !sound;
        tick_counter <= tick_counter + freq - (ticks_per_second >> 1);
      end
    end
  end
endmodule


// SIMON GAME (FULL SEQUENCE REPLAY)

module simon (
    input wire clk,
    input wire rst,
    input wire [15:0] ticks_per_milli,
    input wire [3:0] btn,
    output reg [3:0] led,
    output wire sound,
    output wire [7:0] score
);

  localparam MAX_GAME_LEN = 32;
  localparam TIMEOUT_LIMIT = 25000; // 25s human-friendly

  wire [9:0] GAME_TONES[3:0];
  assign GAME_TONES[0] = 196;
  assign GAME_TONES[1] = 262;
  assign GAME_TONES[2] = 330;
  assign GAME_TONES[3] = 784;

  localparam StatePowerOn   = 0;
  localparam StateInit      = 1;
  localparam StatePlay      = 2;
  localparam StatePlayWait  = 3;
  localparam StateUserWait  = 4;
  localparam StateUserInput = 5;
  localparam StateGameOver  = 6;

  reg [4:0] seq_counter;
  reg [4:0] seq_length;
  reg [1:0] seq[MAX_GAME_LEN-1:0];
  reg [2:0] state;

  reg [15:0] tick_counter;
  reg [15:0] millis_counter;
  reg [9:0] sound_freq;
  reg [1:0] user_input;

  reg [7:0] score_reg;
  assign score = score_reg;

  reg [15:0] lfsr = 16'hACE1;
  wire lfsr_feedback = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];

  play play1 (
      .clk(clk),
      .rst(rst),
      .ticks_per_milli(ticks_per_milli),
      .freq(sound_freq),
      .sound(sound)
  );
  
  //FSM
  
  always @(posedge clk) begin
    if (rst) begin
      seq_length <= 0;
      seq_counter <= 0;
      tick_counter <= 0;
      millis_counter <= 0;
      sound_freq <= 0;
      state <= StatePowerOn;
      led <= 0;
      score_reg <= 0;
      lfsr <= 16'hACE1;
    end else begin
      tick_counter <= tick_counter + 1;
      if (lfsr == 0)
        lfsr <= 16'hACE1;
      else
        lfsr <= {lfsr[14:0], lfsr_feedback};

      if (tick_counter == ticks_per_milli) begin
        tick_counter <= 0;
        millis_counter <= millis_counter + 1;
      end

      case(state)
      
        //POWER ON
        StatePowerOn: begin
          led <= 4'b0001 << millis_counter[10:9];
          if(btn != 0) begin
            state <= StateInit;
            millis_counter <= 0;
          end
        end

        //INIT
        
        StateInit: begin
          seq[0] <= lfsr[1:0];
          seq_length <= 1;
          seq_counter <= 0;
          score_reg <= 0;
          if(millis_counter == 1000)
            state <= StatePlay;
        end

        //PLAY SEQUENCE
        
        StatePlay: begin
          led <= 4'b0001 << seq[seq_counter];
          sound_freq <= GAME_TONES[seq[seq_counter]];
          millis_counter <= 0;
          state <= StatePlayWait;
        end

        StatePlayWait: begin
          if(millis_counter == 700) begin
            led <= 0;
            sound_freq <= 0;
          end
          if(millis_counter == 1000) begin
            if(seq_counter + 1 == seq_length) begin
              // full sequence played, now add new step
              seq[seq_length] <= lfsr[1:0];
              seq_length <= seq_length + 1;
              seq_counter <= 0;
              millis_counter <= 0;
              state <= StateUserWait;
            end else begin
              // move to next step in sequence
              seq_counter <= seq_counter + 1;
              state <= StatePlay;
            end
          end
        end

        //USER INPUT
        StateUserWait: begin
          if(millis_counter >= TIMEOUT_LIMIT)
            state <= StateGameOver;
          else if(btn != 0) begin
            case(btn)
              4'b0001: user_input <= 0;
              4'b0010: user_input <= 1;
              4'b0100: user_input <= 2;
              4'b1000: user_input <= 3;
            endcase
            state <= StateUserInput;
            millis_counter <= 0;
          end
        end

        StateUserInput: begin
          led <= 4'b0001 << user_input;
          sound_freq <= GAME_TONES[user_input];

          if(millis_counter == 700) begin
            sound_freq <= 0;
            if(user_input == seq[seq_counter]) begin
              if(seq_counter + 1 == seq_length - 1) begin
                // user completed full sequence correctly
                score_reg <= score_reg + 1;
                seq_counter <= 0;
                millis_counter <= 0;
                state <= StatePlay; // replay full sequence next round
              end else begin
                seq_counter <= seq_counter + 1;
                state <= StateUserWait;
              end
            end else begin
              state <= StateGameOver;
            end
          end
        end

        //GAME OVER
        StateGameOver: begin
          led <= millis_counter[8] ? 4'b1111 : 4'b0000;
          if(btn != 0) begin
            state <= StateInit;
            score_reg <= 0;
            seq_counter <= 0;
            seq_length <= 1;
            millis_counter <= 0;
          end
        end
      endcase
    end
  end
endmodule


// 7-SEG DISPLAY

module seven_seg(
    input  wire clk,
    input  wire [7:0] score,
    output reg  [6:0] seg,
    output reg  [5:0] an
);
reg [16:0] refresh_counter = 0;
  wire [2:0] digit_sel = refresh_counter[16:14];

  always @(posedge clk)
    refresh_counter <= refresh_counter + 1;

  wire [3:0] ones = score % 10;
  wire [3:0] tens = (score / 10) % 10;

  reg [3:0] digit;

  always @(*) begin
    case(digit_sel)
      3'b000: begin an = 6'b111110; digit = ones; end
      3'b001: begin an = 6'b111101; digit = tens; end
      default: begin an = 6'b111111; digit = 0; end
    endcase
  end

  always @(*) begin
    case(digit)
      4'd0: seg = 7'b1000000;
      4'd1: seg = 7'b1111001;
      4'd2: seg = 7'b0100100;
      4'd3: seg = 7'b0110000;
      4'd4: seg = 7'b0011001;
      4'd5: seg = 7'b0010010;
      4'd6: seg = 7'b0000010;
      4'd7: seg = 7'b1111000;
      4'd8: seg = 7'b0000000;
      4'd9: seg = 7'b0010000;
      default: seg = 7'b1111111;
    endcase
  end
endmodule
