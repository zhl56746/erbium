----------------------------------------------------------------------------------------------------
--  ERBium - Business Rule Engine Hardware Accelerator
--  Copyright (C) 2020 Fabio Maschi - Systems Group, ETH Zurich

--  This program is free software: you can redistribute it and/or modify it under the terms of the
--  GNU Affero General Public License as published by the Free Software Foundation, either version 3
--  of the License, or (at your option) any later version.

--  This software is provided by the copyright holders and contributors "AS IS" and any express or
--  implied warranties, including, but not limited to, the implied warranties of merchantability and
--  fitness for a particular purpose are disclaimed. In no event shall the copyright holder or
--  contributors be liable for any direct, indirect, incidental, special, exemplary, or
--  consequential damages (including, but not limited to, procurement of substitute goods or
--  services; loss of use, data, or profits; or business interruption) however caused and on any
--  theory of liability, whether in contract, strict liability, or tort (including negligence or
--  otherwise) arising in any way out of the use of this software, even if advised of the 
--  possibility of such damage. See the GNU Affero General Public License for more details.

--  You should have received a copy of the GNU Affero General Public License along with this
--  program. If not, see <http://www.gnu.org/licenses/agpl-3.0.en.html>.
----------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

library std;
use std.textio.all;

library tools;
use tools.std_pkg.all;

library erbium;
use erbium.engine_pkg.all;

package core_pkg is

----------------------------------------------------------------------------------------------------
-- TYPES                                                                                          --
----------------------------------------------------------------------------------------------------

    -- TODO define range of integer QUERY_ID as a subtype ;)
    constant C_INIT_QUERY_ID : integer := 2**CFG_QUERY_ID_WIDTH - 1;

    constant C_QUERYARRAY_WIDTH : integer := CFG_CRITERION_VALUE_WIDTH * CFG_ENGINE_NCRITERIA + CFG_QUERY_ID_WIDTH;

    type match_structure_type is (STRCT_SIMPLE, STRCT_PAIR);
    type match_pair_function is (FNCTR_PAIR_NOP, FNCTR_PAIR_AND, FNCTR_PAIR_OR, FNCTR_PAIR_XOR, FNCTR_PAIR_NAND, FNCTR_PAIR_NOR);
    type match_simp_function is (FNCTR_SIMP_NOP, FNCTR_SIMP_EQU, FNCTR_SIMP_NEQ, FNCTR_SIMP_GRT, FNCTR_SIMP_GEQ, FNCTR_SIMP_LES, FNCTR_SIMP_LEQ);
    type match_mode_type is (MODE_STRICT_MATCH, MODE_FULL_ITERATION);

    type core_flow_control is (FLW_CTRL_BUFFER, FLW_CTRL_MEM);

    type edge_store_type is record
        operand_a       : std_logic_vector(CFG_CRITERION_VALUE_WIDTH - 1 downto 0);
        operand_b       : std_logic_vector(CFG_CRITERION_VALUE_WIDTH - 1 downto 0);
        pointer         : std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
        last            : std_logic;
    end record;

    type edge_buffer_type is record
        pointer         : std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
        query_id        : integer range 0 to 2**CFG_QUERY_ID_WIDTH - 1;
        weight          : std_logic_vector(CFG_WEIGHT_WIDTH - 1 downto 0);
        clock_cycles    : std_logic_vector(CFG_DBG_N_OF_CLK_CYCS_WIDTH - 1 downto 0);
        has_match       : std_logic;
    end record;

    type query_buffer_type is record
        operand         : std_logic_vector(CFG_CRITERION_VALUE_WIDTH - 1 downto 0);
        query_id        : integer range 0 to 2**CFG_QUERY_ID_WIDTH - 1;
    end record;
    type query_in_array_type is array(0 to CFG_ENGINE_NCRITERIA - 1) of query_buffer_type;

    type query_flow_type is record
        read_en         : std_logic;
        query           : query_buffer_type;
        first           : std_logic;
    end record;

    type fetch_out_type is record
        buffer_rd_en    : std_logic;
        mem_rd_en       : std_logic;
        mem_addr        : std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
        flow_ctrl       : core_flow_control;
        query_id        : integer range 0 to 2**CFG_QUERY_ID_WIDTH - 1;
        weight          : std_logic_vector(CFG_WEIGHT_WIDTH - 1 downto 0);
        clock_cycles    : std_logic_vector(CFG_DBG_N_OF_CLK_CYCS_WIDTH - 1 downto 0);
        idle            : std_logic;
    end record;

    type execute_out_type is record
        inference_res   : std_logic;
        writing_edge    : edge_buffer_type;
        has_match       : std_logic;
        empty           : std_logic;
    end record;

    type mem_out_type is record
        rd_addr         : std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
        rd_en           : std_logic;
        wr_addr         : std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
        wr_en           : std_logic;
        wr_data         : edge_store_type;
    end record;

    type core_parameters_type is record
        G_RAM_DEPTH           : integer;
        G_RAM_LATENCY         : integer;
        G_MATCH_STRCT         : match_structure_type;
        G_MATCH_FUNCTION_A    : match_simp_function;
        G_MATCH_FUNCTION_B    : match_simp_function;
        G_MATCH_FUNCTION_PAIR : match_pair_function;
        G_MATCH_MODE          : match_mode_type;
        G_WEIGHT              : std_logic_vector(CFG_WEIGHT_WIDTH - 1 downto 0);
        G_WILDCARD_ENABLED    : std_logic;
    end record;

----------------------------------------------------------------------------------------------------
-- COMPONENTS                                                                                     --
----------------------------------------------------------------------------------------------------

    component functor is
        generic (
            G_FUNCTION          : match_simp_function  := FNCTR_SIMP_NOP;
            G_WILDCARD          : std_logic            := '0'
        );
        port (
            rule_i              :  in std_logic_vector(CFG_CRITERION_VALUE_WIDTH-1 downto 0);
            query_i             :  in std_logic_vector(CFG_CRITERION_VALUE_WIDTH-1 downto 0);
            funct_o             : out std_logic;
            stopscan_o          : out std_logic;
            wildcard_o          : out std_logic
        );
    end component;

    component matcher is
        generic (
            G_STRUCTURE         : match_structure_type := STRCT_SIMPLE;
            G_FUNCTION_A        : match_simp_function  := FNCTR_SIMP_NOP;
            G_FUNCTION_B        : match_simp_function  := FNCTR_SIMP_NOP;
            G_FUNCTION_PAIR     : match_pair_function  := FNCTR_PAIR_NOP;
            G_WILDCARD          : std_logic            := '0'
        );
        port (
            op_query_i          :  in std_logic_vector(CFG_CRITERION_VALUE_WIDTH-1 downto 0);
            opA_rule_i          :  in std_logic_vector(CFG_CRITERION_VALUE_WIDTH-1 downto 0);
            opB_rule_i          :  in std_logic_vector(CFG_CRITERION_VALUE_WIDTH-1 downto 0);
            match_result_o      : out std_logic;
            stopscan_o          : out std_logic;
            wildcard_o          : out std_logic
        );
    end component;

    component core is
        generic (
            G_MATCH_STRCT         : match_structure_type := STRCT_SIMPLE;
            G_MATCH_FUNCTION_A    : match_simp_function  := FNCTR_SIMP_NOP;
            G_MATCH_FUNCTION_B    : match_simp_function  := FNCTR_SIMP_NOP;
            G_MATCH_FUNCTION_PAIR : match_pair_function  := FNCTR_PAIR_NOP;
            G_MATCH_MODE          : match_mode_type      := MODE_FULL_ITERATION;
            G_MEM_RD_LATENCY      : integer              := 2;
            G_WEIGHT              : std_logic_vector(CFG_WEIGHT_WIDTH - 1 downto 0) := (others=>'0');
            G_WILDCARD_ENABLED    : std_logic            := '1'
        );
        port (
            clk_i           :  in std_logic;
            rst_i           :  in std_logic; -- low active
            idle_o          : out std_logic;
            prev_idle_i     :  in std_logic;
            -- FIFO edge buffer from previous level
            prev_empty_i    :  in std_logic;
            prev_data_i     :  in edge_buffer_type;
            prev_read_o     : out std_logic;
            -- FIFO query buffer
            query_i         :  in query_buffer_type;
            query_empty_i   :  in std_logic;
            query_read_o    : out std_logic;
            -- MEMORY
            mem_edge_i      :  in edge_store_type;
            mem_addr_o      : out std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
            mem_en_o        : out std_logic;
            -- FIFO edge buffer to next level
            next_full_i     :  in std_logic;
            next_data_o     : out edge_buffer_type;
            next_write_o    : out std_logic
        );
    end component;

    component result_reducer is
    port (
        clk_i           :  in std_logic;
        rst_i           :  in std_logic; -- low active
        engine_idle_i   :  in std_logic;
        -- interim result from NFA-PE
        interim_empty_i :  in std_logic;
        interim_data_i  :  in edge_buffer_type;
        interim_read_o  : out std_logic;
        -- final result to TOP
        result_ready_i  :  in std_logic;
        result_data_o   : out edge_buffer_type;
        result_last_o   : out std_logic;
        result_valid_o  : out std_logic
    );
    end component;

    component buffer_edge is
        generic (
            G_DEPTH   : integer := 32;
            G_ALMST   : integer := 1
        );
        port (
            rst_i         :  in std_logic;
            clk_i         :  in std_logic;
            -- FIFO Write Interface
            wr_en_i       :  in std_logic;
            wr_data_i     :  in edge_buffer_type;
            full_o        : out std_logic;
            almost_full_o : out std_logic;
            -- FIFO Read Interface
            rd_en_i       :  in std_logic;
            rd_data_o     : out edge_buffer_type;
            empty_o       : out std_logic
        );
    end component;

    component buffer_query is
        generic (
            G_DEPTH   : integer := 32;
            G_ALMST   : integer := 1
        );
        port (
            rst_i         :  in std_logic;
            clk_i         :  in std_logic;
            -- FIFO Write Interface
            wr_en_i       :  in std_logic;
            wr_data_i     :  in query_buffer_type;
            full_o        : out std_logic;
            almost_full_o : out std_logic;
            -- FIFO Read Interface
            rd_en_i       :  in std_logic;
            rd_data_o     : out query_buffer_type;
            empty_o       : out std_logic
        );
    end component;

    component engine is
    generic (
        G_INOUT_LATENCY  : integer := 4 -- TODO: not dynamic for the moment!
    );
    port (
        clk_i             :  in std_logic;
        rst_i             :  in std_logic; -- rst low active
        --
        query_i           :  in query_in_array_type;
        query_last_i      :  in std_logic;
        query_wr_en_i     :  in std_logic;
        query_ready_o     : out std_logic;
        --
        mem_i             :  in std_logic_vector(CFG_EDGE_BRAM_WIDTH - 1 downto 0);
        mem_wren_i        :  in std_logic_vector(CFG_ENGINE_NCRITERIA - 1 downto 0);
        mem_addr_i        :  in std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
        --
        result_ready_i    :  in std_logic;
        result_valid_o    : out std_logic;
        result_last_o     : out std_logic;
        result_value_o    : out std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0)
    );
    end component;
    
----------------------------------------------------------------------------------------------------
-- FUNCTIONS                                                                                      --
----------------------------------------------------------------------------------------------------

    function deserialise_edge_store(vec : std_logic_vector) return edge_store_type;

    function serialise_query_array(vec : query_in_array_type) return std_logic_vector;
    function deserialise_query_array(vec : std_logic_vector) return query_in_array_type;

    function insert_into_vector(vec : std_logic_vector; val : std_logic_vector; p : integer) return std_logic_vector;

end core_pkg;

package body core_pkg is

function deserialise_edge_store(vec : std_logic_vector) return edge_store_type is
    variable res : edge_store_type;
    variable vec_buff : std_logic_vector(CFG_EDGE_BRAM_WIDTH - 1 downto 0);
  begin
    vec_buff      := vec;
    res.operand_a := vec_buff(RNG_BRAM_EDGE_STORE_OPERAND_A);
    res.operand_b := vec_buff(RNG_BRAM_EDGE_STORE_OPERAND_B);
    res.pointer   := vec_buff(RNG_BRAM_EDGE_STORE_POINTER);
    res.last      := vec_buff(RNG_BRAM_EDGE_STORE_LAST'left);
    return res;
end deserialise_edge_store;

function deserialise_query_array(vec : std_logic_vector) return query_in_array_type is
    variable res : query_in_array_type;
    variable vec_buff : std_logic_vector(C_QUERYARRAY_WIDTH - 1 downto 0);
  begin
    vec_buff := vec;
    if notx(vec) then
        for_des : for idx in 0 to CFG_ENGINE_NCRITERIA - 1 loop
            res(idx).operand := vec_buff(CFG_CRITERION_VALUE_WIDTH * (idx+1) - 1
                                        downto
                                        CFG_CRITERION_VALUE_WIDTH * idx);
            res(idx).query_id := to_integer(unsigned(vec_buff(C_QUERYARRAY_WIDTH - 1
                                        downto
                                        CFG_CRITERION_VALUE_WIDTH * CFG_ENGINE_NCRITERIA)));
        end loop for_des;
    end if;
    
    return res;
end deserialise_query_array;

function insert_into_vector(vec : std_logic_vector;
                            val : std_logic_vector;
                            p : integer) return std_logic_vector is
    variable res : std_logic_vector(vec'range);
  begin
    res := vec;
    res(p + val'length - 1 downto p) := val;

    return res;
end insert_into_vector;

function serialise_query_array(vec : query_in_array_type) return std_logic_vector is
    variable res : std_logic_vector(C_QUERYARRAY_WIDTH - 1 downto 0);
    variable v_id : std_logic_vector(CFG_QUERY_ID_WIDTH - 1 downto 0);
  begin
    v_id := std_logic_vector(to_unsigned(vec(0).query_id, v_id'length));

    for_ser : for idx in 0 to CFG_ENGINE_NCRITERIA - 1 loop
        res := insert_into_vector(res, vec(idx).operand, idx * CFG_CRITERION_VALUE_WIDTH);
    end loop for_ser;
    res := insert_into_vector(res, v_id, CFG_ENGINE_NCRITERIA * CFG_CRITERION_VALUE_WIDTH);
    
    return res;
end serialise_query_array;

end core_pkg;