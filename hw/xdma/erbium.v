////////////////////////////////////////////////////////////////////////////////////////////////////
//  ERBium - Business Rule Engine Hardware Accelerator
//  Copyright (C) 2020 Fabio Maschi - Systems Group, ETH Zurich

//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU Affero General Public License as published by the Free Software Foundation, either version 3
//  of the License, or (at your option) any later version.

//  This software is provided by the copyright holders and contributors "AS IS" and any express or
//  implied warranties, including, but not limited to, the implied warranties of merchantability and
//  fitness for a particular purpose are disclaimed. In no event shall the copyright holder or
//  contributors be liable for any direct, indirect, incidental, special, exemplary, or
//  consequential damages (including, but not limited to, procurement of substitute goods or
//  services; loss of use, data, or profits; or business interruption) however caused and on any
//  theory of liability, whether in contract, strict liability, or tort (including negligence or
//  otherwise) arising in any way out of the use of this software, even if advised of the 
//  possibility of such damage. See the GNU Affero General Public License for more details.

//  You should have received a copy of the GNU Affero General Public License along with this
//  program. If not, see <http://www.gnu.org/licenses/agpl-3.0.en.html>.
////////////////////////////////////////////////////////////////////////////////////////////////////

// default_nettype of none prevents implicit wire declaration.
`default_nettype none
`timescale 1 ns / 1 ps
// Top level of the kernel. Do not modify module name, parameters or ports.
module erbium #(
  parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 12 ,
  parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32 ,
  parameter integer C_M00_AXI_ADDR_WIDTH       = 64 ,
  parameter integer C_M00_AXI_DATA_WIDTH       = 512
)
(
  // System Signals
  input  wire                                    ap_clk               ,
  input  wire                                    ap_rst_n             ,
  input  wire                                    ap_clk_2             ,
  input  wire                                    ap_rst_n_2           ,
  // AXI4 master interface m00_axi
  output wire                                    m00_axi_awvalid      ,
  input  wire                                    m00_axi_awready      ,
  output wire [C_M00_AXI_ADDR_WIDTH-1:0]         m00_axi_awaddr       ,
  output wire [8-1:0]                            m00_axi_awlen        ,
  output wire                                    m00_axi_wvalid       ,
  input  wire                                    m00_axi_wready       ,
  output wire [C_M00_AXI_DATA_WIDTH-1:0]         m00_axi_wdata        ,
  output wire [C_M00_AXI_DATA_WIDTH/8-1:0]       m00_axi_wstrb        ,
  output wire                                    m00_axi_wlast        ,
  input  wire                                    m00_axi_bvalid       ,
  output wire                                    m00_axi_bready       ,
  output wire                                    m00_axi_arvalid      ,
  input  wire                                    m00_axi_arready      ,
  output wire [C_M00_AXI_ADDR_WIDTH-1:0]         m00_axi_araddr       ,
  output wire [8-1:0]                            m00_axi_arlen        ,
  input  wire                                    m00_axi_rvalid       ,
  output wire                                    m00_axi_rready       ,
  input  wire [C_M00_AXI_DATA_WIDTH-1:0]         m00_axi_rdata        ,
  input  wire                                    m00_axi_rlast        ,
  // AXI4-Lite slave interface
  input  wire                                    s_axi_control_awvalid,
  output wire                                    s_axi_control_awready,
  input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_awaddr ,
  input  wire                                    s_axi_control_wvalid ,
  output wire                                    s_axi_control_wready ,
  input  wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_wdata  ,
  input  wire [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0] s_axi_control_wstrb  ,
  input  wire                                    s_axi_control_arvalid,
  output wire                                    s_axi_control_arready,
  input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_araddr ,
  output wire                                    s_axi_control_rvalid ,
  input  wire                                    s_axi_control_rready ,
  output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_rdata  ,
  output wire [2-1:0]                            s_axi_control_rresp  ,
  output wire                                    s_axi_control_bvalid ,
  input  wire                                    s_axi_control_bready ,
  output wire [2-1:0]                            s_axi_control_bresp  ,
  output wire                                    interrupt            
);

////////////////////////////////////////////////////////////////////////////////////////////////////
// Wires and Variables
////////////////////////////////////////////////////////////////////////////////////////////////////
reg                                 areset                         = 1'b0;
wire                                ap_start                      ;
wire                                ap_idle                       ;
wire                                ap_done                       ;
wire [32-1:0]                       nfadata_cls                   ;
wire [32-1:0]                       queries_cls                   ;
wire [32-1:0]                       results_cls                   ;
wire [32-1:0]                       scalar03                      ;
wire [64-1:0]                       nfa_hash                      ;
wire [64-1:0]                       nfadata_ptr                   ;
wire [64-1:0]                       queries_ptr                   ;
wire [64-1:0]                       results_ptr                   ;
wire [64-1:0]                       axi00_ptr3                    ;
//
reg                                 ap_start_dlay                 ;
reg [32-1:0]                        nfadata_cls_dlay              ;
reg [32-1:0]                        queries_cls_dlay              ;
reg [32-1:0]                        results_cls_dlay              ;
reg [32-1:0]                        scalar03_dlay                 ;
reg [64-1:0]                        nfa_hash_dlay                 ;
reg [64-1:0]                        nfadata_ptr_dlay              ;
reg [64-1:0]                        queries_ptr_dlay              ;
reg [64-1:0]                        results_ptr_dlay              ;
reg [64-1:0]                        axi00_ptr3_dlay               ;

// Register and invert reset signal.
always @(posedge ap_clk) begin
  areset <= ~ap_rst_n;
  ap_start_dlay    <= ap_start;
  nfadata_cls_dlay <= nfadata_cls;
  queries_cls_dlay <= queries_cls;
  results_cls_dlay <= results_cls;
  scalar03_dlay    <= scalar03;
  nfa_hash_dlay    <= nfa_hash;
  nfadata_ptr_dlay <= nfadata_ptr;
  queries_ptr_dlay <= queries_ptr;
  results_ptr_dlay <= results_ptr;
  axi00_ptr3_dlay  <= axi00_ptr3;
end

////////////////////////////////////////////////////////////////////////////////////////////////////
// Begin control interface RTL
////////////////////////////////////////////////////////////////////////////////////////////////////

// AXI4-Lite slave interface
erbium_control_s_axi #(
  .C_ADDR_WIDTH ( C_S_AXI_CONTROL_ADDR_WIDTH ),
  .C_DATA_WIDTH ( C_S_AXI_CONTROL_DATA_WIDTH )
)
inst_control_s_axi (
  .aclk        ( ap_clk                ),
  .areset      ( areset                ),
  .aclk_en     ( 1'b1                  ),
  .awvalid     ( s_axi_control_awvalid ),
  .awready     ( s_axi_control_awready ),
  .awaddr      ( s_axi_control_awaddr  ),
  .wvalid      ( s_axi_control_wvalid  ),
  .wready      ( s_axi_control_wready  ),
  .wdata       ( s_axi_control_wdata   ),
  .wstrb       ( s_axi_control_wstrb   ),
  .arvalid     ( s_axi_control_arvalid ),
  .arready     ( s_axi_control_arready ),
  .araddr      ( s_axi_control_araddr  ),
  .rvalid      ( s_axi_control_rvalid  ),
  .rready      ( s_axi_control_rready  ),
  .rdata       ( s_axi_control_rdata   ),
  .rresp       ( s_axi_control_rresp   ),
  .bvalid      ( s_axi_control_bvalid  ),
  .bready      ( s_axi_control_bready  ),
  .bresp       ( s_axi_control_bresp   ),
  .interrupt   ( interrupt             ),
  .ap_start    ( ap_start              ),
  .ap_done     ( ap_done               ),
  .ap_idle     ( ap_idle               ),
  .nfadata_cls ( nfadata_cls           ),
  .queries_cls ( queries_cls           ),
  .results_cls ( results_cls           ),
  .scalar03    ( scalar03              ),
  .nfa_hash    ( nfa_hash              ),
  .nfadata_ptr ( nfadata_ptr           ),
  .queries_ptr ( queries_ptr           ),
  .results_ptr ( results_ptr           ),
  .axi00_ptr3  ( axi00_ptr3            )
);

////////////////////////////////////////////////////////////////////////////////////////////////////
// ERBIUM KERNEL
////////////////////////////////////////////////////////////////////////////////////////////////////

erbium_kernel #(
  .C_M00_AXI_ADDR_WIDTH ( C_M00_AXI_ADDR_WIDTH ),
  .C_M00_AXI_DATA_WIDTH ( C_M00_AXI_DATA_WIDTH )
)
inst_erbium (
  .data_clk        ( ap_clk          ),
  .data_rst_n      ( ap_rst_n        ),
  .kernel_clk      ( ap_clk_2        ),
  .kernel_rst_n    ( ap_rst_n_2      ),
  .m00_axi_awvalid ( m00_axi_awvalid ),
  .m00_axi_awready ( m00_axi_awready ),
  .m00_axi_awaddr  ( m00_axi_awaddr  ),
  .m00_axi_awlen   ( m00_axi_awlen   ),
  .m00_axi_wvalid  ( m00_axi_wvalid  ),
  .m00_axi_wready  ( m00_axi_wready  ),
  .m00_axi_wdata   ( m00_axi_wdata   ),
  .m00_axi_wstrb   ( m00_axi_wstrb   ),
  .m00_axi_wlast   ( m00_axi_wlast   ),
  .m00_axi_bvalid  ( m00_axi_bvalid  ),
  .m00_axi_bready  ( m00_axi_bready  ),
  .m00_axi_arvalid ( m00_axi_arvalid ),
  .m00_axi_arready ( m00_axi_arready ),
  .m00_axi_araddr  ( m00_axi_araddr  ),
  .m00_axi_arlen   ( m00_axi_arlen   ),
  .m00_axi_rvalid  ( m00_axi_rvalid  ),
  .m00_axi_rready  ( m00_axi_rready  ),
  .m00_axi_rdata   ( m00_axi_rdata   ),
  .m00_axi_rlast   ( m00_axi_rlast   ),
  .ap_start        ( ap_start_dlay   ),
  .ap_done         ( ap_done         ),
  .ap_idle         ( ap_idle         ),
  .nfadata_cls     ( nfadata_cls_dlay ),
  .queries_cls     ( queries_cls_dlay ),
  .results_cls     ( results_cls_dlay ),
  .scalar03        ( scalar03_dlay   ),
  .nfa_hash        ( nfa_hash_dlay   ),
  .nfadata_ptr     ( nfadata_ptr_dlay ),
  .queries_ptr     ( queries_ptr_dlay ),
  .results_ptr     ( results_ptr_dlay ),
  .axi00_ptr3      ( axi00_ptr3_dlay )
);

endmodule
`default_nettype wire