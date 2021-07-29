///////////////////////////////////////////
//
// Written: Katherine Parry, Bret Mathis
// Modified: 6/23/2021
//
// Purpose: FPU
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, 
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software 
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES 
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT 
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

`include "wally-config.vh"

module fpu (
  input logic 		          clk,
  input logic 		          reset,
  input logic  [2:0] 	      FRM_REGW, // Rounding mode from CSR
  input logic  [31:0]       InstrD,   // instruction from IFU
  input logic  [`XLEN-1:0]  ReadDataW,// Read data from memory
  input logic  [`XLEN-1:0]  SrcAE,    // Integer input being processed (from IEU)
  input logic  [`XLEN-1:0]  SrcAM,    // Integer input being written into fpreg (from IEU)
  input logic 		          StallE, StallM, StallW, // stall signals from HZU
  input logic 		          FlushE, FlushM, FlushW, // flush signals from HZU
  input logic  [4:0] 	      RdE, RdM, RdW,  // which FP register to write to (from IEU)
  output logic 		          FRegWriteM,     // FP register write enable
  output logic 		          FStallD,        // Stall the decode stage
  output logic 		          FWriteIntE, FWriteIntM, FWriteIntW, // integer register write enable
  output logic [`XLEN-1:0]  FWriteDataE,  // Data to be written to memory
  output logic [`XLEN-1:0]  FIntResM,     // data to be written to integer register
  output logic 		          FDivBusyE,    // Is the divide/sqrt unit busy (stall execute stage)
  output logic 		          IllegalFPUInstrD, // Is the instruction an illegal fpu instruction
  output logic [4:0] 	      SetFflagsM        // FMA flags (to privileged unit)
  );

  //*** make everything FLEN at some point
  //*** add the 128 bit support to the if statement when needed
  //*** make new tests for fp using testfloat that include flag checking and all rounding modes
  //*** what is the format for 16-bit - finding conflicting info online can't find anything specified in spec
  //*** only fma/mul and fp <-> int convert flags have been tested. test the others.

  // FPU specifics:
  //    - uses NaN-blocking format
  //        - if there are any unsused bits the most significant bits are filled with 1s
  //                single stored in a double: | 32 1s | single precision value |
  //    - sets the underflow after rounding
  
  generate if (`F_SUPPORTED | `D_SUPPORTED) begin : fpu

  // control signals
	logic 		  FRegWriteD, FRegWriteE, FRegWriteW; // FP register write enable
	logic [2:0] FrmD, FrmE, FrmM;                   // FP rounding mode
	logic 		  FmtD, FmtE, FmtM, FmtW;             // FP precision 0-single 1-double
	logic 		  FDivStartD, FDivStartE;             // Start division or squareroot
	logic 		  FWriteIntD;                         // Write to integer register
	logic [1:0] FForwardXE, FForwardYE, FForwardZE; // forwarding mux control signals
	logic [2:0] FResultSelD, FResultSelE, FResultSelM, FResultSelW; // Select the result written to FP register
	logic [2:0] FOpCtrlD, FOpCtrlE, FOpCtrlM;           // Select which opperation to do in each component
	logic [1:0] FResSelD, FResSelE, FResSelM;           // Select one of the results that finish in the memory stage
	logic [1:0] FIntResSelD, FIntResSelE, FIntResSelM;  // Select the result written to the integer resister
	logic [4:0] Adr1E, Adr2E, Adr3E;                    // adresses of each input
	
	// regfile signals
	logic [63:0] 	    FRD1D, FRD2D, FRD3D;  // Read Data from FP register - decode stage
	logic [63:0] 	    FRD1E, FRD2E, FRD3E;  // Read Data from FP register - execute stage
	logic [63:0] 	    FSrcXE, FSrcXM;       // Input 1 to the various units (after forwarding)
	logic [63:0] 	    FSrcYE;               // Input 2 to the various units (after forwarding)
	logic [63:0] 	    FPreSrcZE, FSrcZE;     // Input 3 to the various units (after forwarding)
	
	// unpacking signals
	logic 		   XSgnE, YSgnE, ZSgnE;     // input's sign - execute stage
	logic 		   XSgnM, YSgnM, ZSgnM;     // input's sign - memory stage
	logic [10:0] XExpE, YExpE, ZExpE;     // input's exponent - execute stage
	logic [10:0] XExpM, YExpM, ZExpM;     // input's exponent - memory stage
	logic [52:0] XManE, YManE, ZManE;  // input's fraction - execute stage
	logic [52:0] XManM, YManM, ZManM;  // input's fraction - memory stage
	logic [10:0] BiasE;                   // bias based on precision (single=7f double=3ff - max expoent/2)
	logic 		   XNaNE, YNaNE, ZNaNE;           // is the input a NaN - execute stage
	logic 		   XNaNM, YNaNM, ZNaNM;           // is the input a NaN - memory stage
	logic 		   XSNaNE, YSNaNE, ZSNaNE;        // is the input a signaling NaN - execute stage
	logic 		   XSNaNM, YSNaNM, ZSNaNM;        // is the input a signaling NaN - memory stage
	logic 		   XDenormE, YDenormE, ZDenormE;  // is the input denormalized
	logic 		   XZeroE, YZeroE, ZZeroE;        // is the input zero - execute stage
	logic 		   XZeroM, YZeroM, ZZeroM;        // is the input zero - memory stage
	logic 		   XInfE, YInfE, ZInfE;           // is the input infinity - execute stage
	logic 		   XInfM, YInfM, ZInfM;           // is the input infinity - memory stage
	logic 		   XExpMaxE;                      // is the exponent all ones (max value)
	logic 		   XNormE,YNormE;                 // is normal
	logic 		   XNormM,YNormM;                 // is normal
	
	
	// result and flag signals
	logic [63:0]  FDivResM, FDivResW; // divide/squareroot result
	logic [4:0] 	FDivFlgM, FDivFlgW; // divide/squareroot flags
  
	logic [63:0]  FMAResM, FMAResW;   // FMA/multiply result
	logic [4:0] 	FMAFlgM, FMAFlgW;   // FMA/multiply result
	
	logic [63:0] 	ReadResW;           // read result (load instruction)

	logic [63:0] 	FAddResM, FAddResW; // add/FP -> FP convert result
	logic [4:0] 	FAddFlgM, FAddFlgW; // add/FP -> FP convert flags

	logic [63:0] 	CvtResE, CvtResM;   // FP <-> int convert result
	logic [4:0] 	CvtFlgE, CvtFlgM;   // FP <-> int convert flags //*** trim this
	
	logic [63:0] 	ClassResE, ClassResM; // classify result

	logic [63:0] 	CmpResE, CmpResM; // compare result
	logic 		    CmpNVE, CmpNVM;   // compare invalid flag (Not Valid)
	
	logic [63:0] 	SgnResE, SgnResM; // sign injection result
	logic 		    SgnNVE, SgnNVM;   // sign injection invalid flag (Not Valid)

	logic [63:0] 	FResM, FResW;     // selected result that is ready in the memory stage
	logic [4:0] 	FFlgM;            // selected flag that is ready in the memory stage

	logic [63:0] 	   FPUResultW;    // final FP result being written to the FP register
		
	// other signals
	logic 		    FDivSqrtDoneE;          // is divide done
	logic [63:0] 	DivInput1E, DivInput2E; // inputs to divide/squareroot unit
	logic 		    FDivClk;                // clock for divide/squareroot unit
	logic [63:0] 	AlignedSrcAM;           // align SrcA to the floating point format





  ////////////////////////////////////////////////////////////////////////////////////////
	//DECODE STAGE
	////////////////////////////////////////////////////////////////////////////////////////



	// calculate FP control signals
	fctrl fctrl (.Funct7D(InstrD[31:25]), .OpD(InstrD[6:0]), .Rs2D(InstrD[24:20]), .Funct3D(InstrD[14:12]), .FRM_REGW,
              // outputs:
              .IllegalFPUInstrD, .FRegWriteD, .FDivStartD, .FResultSelD, .FOpCtrlD, .FResSelD, 
              .FIntResSelD, .FmtD, .FrmD, .FWriteIntD);
	
	// FP register file
  //    - can read 3 registers and write 1 register every cycle
	fregfile fregfile (.clk, .reset, .we4(FRegWriteW),
			   .a1(InstrD[19:15]), .a2(InstrD[24:20]), .a3(InstrD[31:27]), .a4(RdW), 
         .wd4(FPUResultW),
         // outputs:
			   .rd1(FRD1D), .rd2(FRD2D), .rd3(FRD3D));	
	




	////////////////////////////////////////////////////////////////////////////////////////
	// D/E pipeline registers
	////////////////////////////////////////////////////////////////////////////////////////

	flopenrc #(64) DEReg1(clk, reset, FlushE, ~StallE, FRD1D, FRD1E);
	flopenrc #(64) DEReg2(clk, reset, FlushE, ~StallE, FRD2D, FRD2E);
	flopenrc #(64) DEReg3(clk, reset, FlushE, ~StallE, FRD3D, FRD3E);
	flopenrc #(15) DEAdrReg(clk, reset, FlushE, ~StallE, {InstrD[19:15], InstrD[24:20], InstrD[31:27]}, 
                                                       {Adr1E,         Adr2E,         Adr3E});
	flopenrc #(17) DECtrlReg3(clk, reset, FlushE, ~StallE, 
				  {FRegWriteD, FResultSelD, FResSelD, FIntResSelD, FrmD, FmtD, FOpCtrlD, FWriteIntD, FDivStartD},
				  {FRegWriteE, FResultSelE, FResSelE, FIntResSelE, FrmE, FmtE, FOpCtrlE, FWriteIntE, FDivStartE});
	





  
	////////////////////////////////////////////////////////////////////////////////////////
	//EXECUTION STAGE
	////////////////////////////////////////////////////////////////////////////////////////


	// Hazard unit for FPU  
  //    - determines if any forwarding or stalls are needed
	fhazard fhazard(.Adr1E, .Adr2E, .Adr3E, .FRegWriteM, .FRegWriteW, .RdM, .RdW, .FResultSelM, 
                  // outputs:
                  .FStallD, .FForwardXE, .FForwardYE, .FForwardZE);
	

	// forwarding muxs
	mux3  #(64)  fxemux(FRD1E, FPUResultW, FResM, FForwardXE, FSrcXE);
	mux3  #(64)  fyemux(FRD2E, FPUResultW, FResM, FForwardYE, FSrcYE);
	mux3  #(64)  fzemux(FRD3E, FPUResultW, FResM, FForwardZE, FPreSrcZE);
	mux2  #(64)  fzmulmux(FPreSrcZE, 64'b0, FOpCtrlE[2], FSrcZE); // Force Z to be 0 for multiply instructions
 	
   
  // unpacking unit
  //    - splits FP inputs into their various parts
  //    - does some classifications (SNaN, NaN, Denorm, Norm, Zero, Infifnity)
	unpacking unpacking(.X(FSrcXE), .Y(FSrcYE), .Z(FSrcZE), .FOpCtrlE, .FResultSelE, .FmtE, 
                      // outputs:
                      .XSgnE, .YSgnE, .ZSgnE, .XExpE, .YExpE, .ZExpE, .XManE, .YManE, .ZManE, 
                      .XNaNE, .YNaNE, .ZNaNE, .XSNaNE, .YSNaNE, .ZSNaNE, .XDenormE, .YDenormE, .ZDenormE, 
                      .XZeroE, .YZeroE, .ZZeroE, .BiasE, .XInfE, .YInfE, .ZInfE, .XExpMaxE, .XNormE, .YNormE);

  // FMA
  //    - two stage FMA
  //        - execute stage - multiplication and addend shifting
  //        - memory stage  - addition and rounding
  //    - handles FMA and multiply instructions
  //    - contains some E/M pipleine registers
  // *** currently handles FLEN and 32 bits(dont know if 32 works with 128 - easy to fix) - change to handle only the supported formats
	fma fma (.clk, .reset, .FlushM, .StallM, 
		 .XSgnE, .YSgnE, .ZSgnE, .XExpE, .YExpE, .ZExpE, .XManE, .YManE, .ZManE, 
     .XDenormE, .YDenormE, .ZDenormE, .XZeroE, .YZeroE, .ZZeroE, .BiasE, 
		 .XSgnM, .YSgnM, .ZSgnM, .XExpM, .YExpM, .ZExpM, .XManM, .YManM, .ZManM, 
     .XNaNM, .YNaNM, .ZNaNM, .XZeroM, .YZeroM, .ZZeroM, 
     .XInfM, .YInfM, .ZInfM, .XSNaNM, .YSNaNM, .ZSNaNM,
		 .FOpCtrlE, .FOpCtrlM, 
		 .FmtE, .FmtM, .FrmM, 
     // outputs:
     .FMAFlgM, .FMAResM);
	
	// clock gater
  //    - creates a clock that only runs durring divide/sqrt instructions
  //    - using the seperate clock gives the divide/sqrt unit some to get set up
  // *** the module says not to use in synthisis
	clockgater fpdivclkg(.E(FDivStartE),
			     .SE(1'b0),
			     .CLK(clk),
			     .ECLK(FDivClk));
	
	// capture the inputs for divide/sqrt
  //    - if not captured any forwarded inputs will change durring computation
  //        - this problem is caused by stalling the execute stage
  //    - the other units don't have this problem, only div/sqrt stalls the execute stage
	flopenrc #(64) reg_input1 (.d({XSgnE, XExpE, XManE[51:0]}), .q(DivInput1E),
				   .en(1'b1), .clear(FDivSqrtDoneE),
				   .reset(reset),  .clk(FDivBusyE));
	flopenrc #(64) reg_input2 (.d({YSgnE, YExpE, YManE[51:0]}), .q(DivInput2E),
				   .en(1'b1), .clear(FDivSqrtDoneE),
				   .reset(reset),  .clk(FDivBusyE));
	
	// output for store instructions
  //*** change to use the unpacking unit if possible
	fpdiv fdivsqrt (.op1(DivInput1E), .op2(DivInput2E), .rm(FrmE[1:0]), .op_type(FOpCtrlE[0]), 
			             .reset, .clk(FDivClk), .start(FDivStartE), .P(~FmtE), .OvEn(1'b1), .UnEn(1'b1),
                   // outputs:
			             .FDivBusyE, .done(FDivSqrtDoneE), .AS_Result(FDivResM), .Flags(FDivFlgM));
	
	
	// add/FP <-> FP convert
  //    - computation is done in two stages
  //    - contains some E/M pipleine registers
  //*** remove uneeded logic
  //*** change to use the unpacking unit if possible
	faddcvt faddcvt (.clk, .reset, .FlushM, .StallM, .FrmM, .FOpCtrlM, .FmtE, .FmtM, .FSrcXE, .FSrcYE, .FOpCtrlE, 
   .XSgnM, .YSgnM, .XManM, .YManM, .XExpM, .YExpM,
   .XSgnE, .YSgnE, .XManE, .YManE, .XExpE, .YExpE, .XDenormE, .YDenormE, .XNormE, .YNormE, .XNormM, .YNormM,  .XZeroE, .YZeroE, .XInfE, .YInfE, .XNaNE, .YNaNE, .XSNaNE, .YSNaNE,
                  // outputs:
                  .FAddResM, .FAddFlgM);
	
	// compare unit
  //    - computation is done in one stage
  //    - writes to FP file durring min/max instructions
  //    - other comparisons write a 1 or 0 to the integer register
	fcmp fcmp (.op1({XSgnE,XExpE,XManE[`NF-1:0]}), .op2({YSgnE,YExpE,YManE[`NF-1:0]}), 
            .FSrcXE, .FSrcYE, .FOpCtrlE, 
            .FmtE, .XNaNE, .YNaNE, .XZeroE, .YZeroE, 
            // outputs:
		        .Invalid(CmpNVE), .CmpResE);
	
	// sign injection unit
  //    - computation is done in one stage
	fsgn fsgn (.SgnOpCodeE(FOpCtrlE[1:0]), .XSgnE, .YSgnE, .FSrcXE, .FmtE, .XExpMaxE,
            // outputs:
            .SgnNVE, .SgnResE);
	
	// classify
  //    - computation is done in one stage
  //    - most of the work is done in the unpacking unit
  //    - result is written to the integer register
	fclassify fclassify (.XSgnE, .XDenormE, .XZeroE, .XNaNE, .XInfE, .XNormE, 
                      // outputs:
                      .XSNaNE, .ClassResE);
	
	fcvt fcvt (.XSgnE, .XExpE, .XManE, .XZeroE, .XNaNE, .XInfE, .XDenormE, .BiasE, .SrcAE, .FOpCtrlE, .FmtE, .FrmE,
            // outputs: 
            .CvtResE, .CvtFlgE);
	
	// data to be stored in memory - to IEU
  //    - FP uses NaN-blocking format
  //        - if there are any unsused bits the most significant bits are filled with 1s
	assign FWriteDataE = FSrcYE[`XLEN-1:0];
	




  //***will synth remove registers of values that are always zero?
	////////////////////////////////////////////////////////////////////////////////////////
	// E/M pipe registers
	////////////////////////////////////////////////////////////////////////////////////////

	flopenrc #(64) EMFpReg1(clk, reset, FlushM, ~StallM, FSrcXE, FSrcXM);
	flopenrc #(65) EMFpReg2(clk, reset, FlushM, ~StallM, {XSgnE,XExpE,XManE}, {XSgnM,XExpM,XManM});
	flopenrc #(65) EMFpReg3(clk, reset, FlushM, ~StallM, {YSgnE,YExpE,YManE}, {YSgnM,YExpM,YManM});
	flopenrc #(65) EMFpReg4(clk, reset, FlushM, ~StallM, {ZSgnE,ZExpE,ZManE}, {ZSgnM,ZExpM,ZManM});
	flopenrc #(12) EMFpReg5(clk, reset, FlushM, ~StallM, 
				{XZeroE, YZeroE, ZZeroE, XInfE, YInfE, ZInfE, XNaNE, YNaNE, ZNaNE, XSNaNE, YSNaNE, ZSNaNE},
				{XZeroM, YZeroM, ZZeroM, XInfM, YInfM, ZInfM, XNaNM, YNaNM, ZNaNM, XSNaNM, YSNaNM, ZSNaNM});
	
	flopenrc #(64) EMRegCmpRes(clk, reset, FlushM, ~StallM, CmpResE, CmpResM); 
	flopenrc #(1)  EMRegCmpFlg(clk, reset, FlushM, ~StallM, CmpNVE, CmpNVM); 
	
	flopenrc #(64) EMRegSgnRes(clk, reset, FlushM, ~StallM, SgnResE, SgnResM);
	flopenrc #(1) EMRegSgnFlg(clk, reset, FlushM, ~StallM, SgnNVE, SgnNVM);
	
	flopenrc #(64) EMRegCvtRes(clk, reset, FlushM, ~StallM, CvtResE, CvtResM);
	flopenrc #(5) EMRegCvtFlg(clk, reset, FlushM, ~StallM, CvtFlgE, CvtFlgM);
  
	flopenrc #(64) EMRegClass(clk, reset, FlushM, ~StallM, ClassResE, ClassResM);
	
	flopenrc #(18) EMCtrlReg(clk, reset, FlushM, ~StallM,
				 {FRegWriteE, FResultSelE, FResSelE, FIntResSelE, FrmE, FmtE, FOpCtrlE, FWriteIntE, XNormE, YNormE},
				 {FRegWriteM, FResultSelM, FResSelM, FIntResSelM, FrmM, FmtM, FOpCtrlM, FWriteIntM, XNormM, YNormM});
	
	




	////////////////////////////////////////////////////////////////////////////////////////
	//BEGIN MEMORY STAGE
	////////////////////////////////////////////////////////////////////////////////////////

	// Align SrcA to MSB when single precicion
	mux2  #(64)  SrcAMux({{32{1'b1}}, SrcAM[31:0]}, {{64-`XLEN{1'b1}}, SrcAM}, FmtM, AlignedSrcAM);

  // select a result that may be written to the FP register
	mux4  #(64) FResMux(AlignedSrcAM, SgnResM, CmpResM, CvtResM, FResSelM, FResM);
	mux4  #(5)  FFlgMux(5'b0, {4'b0, SgnNVM}, {4'b0, CmpNVM}, CvtFlgM, FResSelM, FFlgM);
	
  // select the result that may be written to the integer register - to IEU
	mux4  #(`XLEN)  IntResMux(CmpResM[`XLEN-1:0], FSrcXM[`XLEN-1:0], ClassResM[`XLEN-1:0], CvtResM[`XLEN-1:0], FIntResSelM, FIntResM);
	
  // FPU flag selection - to privileged
	mux5  #(5)  FPUFlgMux(5'b0, FMAFlgM, FAddFlgM, FDivFlgM, FFlgM, FResultSelW, SetFflagsM);
	



  
	////////////////////////////////////////////////////////////////////////////////////////
	// M/W pipe registers
	////////////////////////////////////////////////////////////////////////////////////////
	flopenrc #(64) MWRegFma(clk, reset, FlushW, ~StallW, FMAResM, FMAResW); 
	flopenrc #(64) MWRegDiv(clk, reset, FlushW, ~StallW, FDivResM, FDivResW); 
	flopenrc #(64) MWRegAdd(clk, reset, FlushW, ~StallW, FAddResM, FAddResW); 
	flopenrc #(64) MWRegClass(clk, reset, FlushW, ~StallW, FResM, FResW);
	flopenrc #(6)  MWCtrlReg(clk, reset, FlushW, ~StallW,
				{FRegWriteM, FResultSelM, FmtM, FWriteIntM},
				{FRegWriteW, FResultSelW, FmtW, FWriteIntW});
	



	////////////////////////////////////////////////////////////////////////////////////////
	// BEGIN WRITEBACK STAGE
	////////////////////////////////////////////////////////////////////////////////////////

  // put ReadData into NaN-blocking format
  //    - if there are any unsused bits the most significant bits are filled with 1s
  //    - for load instruction
	mux2  #(64)  ReadResMux({{32{1'b1}}, ReadDataW[31:0]}, {{64-`XLEN{1'b1}}, ReadDataW}, FmtW, ReadResW);

  // select the result to be written to the FP register
	mux5  #(64)  FPUResultMux(ReadResW, FMAResW, FAddResW, FDivResW, FResW, FResultSelW, FPUResultW);
	
	
  end else begin // no F_SUPPORTED or D_SUPPORTED; tie outputs low
	assign FStallD = 0;
	assign FWriteIntE = 0; 
	assign FWriteIntM = 0;
	assign FWriteIntW = 0;
	assign FWriteDataE = 0;
	assign FIntResM = 0;
	assign FDivBusyE = 0;
	assign IllegalFPUInstrD = 1;
	assign SetFflagsM = 0;
  end
  endgenerate 
   
endmodule // fpu
