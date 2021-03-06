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
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

library erbium;
use erbium.engine_pkg.all;
use erbium.core_pkg.all;
USE erbium.cfg_criteria.all;

library tools;
use tools.std_pkg.all;

entity engine is
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
end engine;

architecture behavioural of engine is

    -- CORE INTERFACE ARRAYS
    type edge_buffer_array  is array (CFG_ENGINE_NCRITERIA - 1 downto 0) of edge_buffer_type;
    type edge_buffer_arrayp1 is array (CFG_ENGINE_NCRITERIA downto 0) of edge_buffer_type;
    type edge_store_array   is array (CFG_ENGINE_NCRITERIA - 1 downto 0) of edge_store_type;
    type mem_addr_array     is array (CFG_ENGINE_NCRITERIA - 1 downto 0) of std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
    type mem_data_array     is array (CFG_ENGINE_NCRITERIA - 1 downto 0) of std_logic_vector(CFG_EDGE_BRAM_WIDTH - 1 downto 0);
    type query_buffer_array is array (CFG_ENGINE_NCRITERIA - 1 downto 0) of query_buffer_type;
    --
    -- CORE INTERFACE DOPIO
    type edge_buffer_dopio  is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of edge_buffer_array;
    type edge_buffer_dopiop1 is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of edge_buffer_arrayp1;
    type edge_store_dopio   is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of edge_store_array;
    type mem_addr_dopio     is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of mem_addr_array;
    type mem_data_dopio     is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of mem_data_array;
    type query_buffer_dopio is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of query_buffer_array;
    type ncrieria_dopio     is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of std_logic_vector(0 to CFG_ENGINE_NCRITERIA - 1);
    type ncrieria_dopio_p1  is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of std_logic_vector(0 to CFG_ENGINE_NCRITERIA);
    type edge_buffer_ardopio is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of edge_buffer_type;
    type mem_data_ardopio   is array (CFG_ENGINE_DOPIO_CORES - 1 downto 0) of mem_data_array;    --
    signal pe_idle         : ncrieria_dopio;
    signal prev_idle       : ncrieria_dopio;
    signal prev_empty      : ncrieria_dopio_p1;
    signal prev_read       : ncrieria_dopio_p1;
    signal prev_data       : edge_buffer_dopiop1;
    signal query           : query_buffer_dopio;
    signal query_full      : ncrieria_dopio;
    signal query_empty     : ncrieria_dopio;
    signal query_read      : ncrieria_dopio;
    signal mem_edge        : edge_store_dopio;
    signal mem_addr        : mem_addr_dopio;
    signal mem_en          : ncrieria_dopio;
    signal next_full       : ncrieria_dopio;
    signal next_data       : edge_buffer_dopio;
    signal next_write      : ncrieria_dopio;
    --
    signal query_wr_en     : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
    --
    -- result reducer
    signal resred_value    : edge_buffer_ardopio;
    signal resred_valid    : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
    signal resred_last     : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
    signal resred_ready    : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
    --
    signal sig_cores_idle  : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
    --
    -- BRAM INTERFACE ARRAYS
    signal uram_rd_data    : mem_data_ardopio;
    --
    -- CORNER CASE SIGNALS
    signal sig_origin_node : edge_buffer_ardopio;
    --
    -- DOPIO
    -- type flow_ctrl_type is (FLW_CTRL_A, FLW_CTRL_B);
    type dopio_reg_type is record
        -- rd_flow_ctrl    : flow_ctrl_type;
        -- wr_flow_ctrl    : flow_ctrl_type;
        query_ready     : std_logic;
        core_running    : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
        --
        query_flow_ctrl : integer range 0 to CFG_ENGINE_DOPIO_CORES;
        reslt_flow_ctrl : integer range 0 to CFG_ENGINE_DOPIO_CORES;
    end record;
    signal dopio_r, dopio_rin   : dopio_reg_type;
    signal sig_dopio_res : std_logic_vector(CFG_ENGINE_DOPIO_CORES - 1 downto 0);
    --
    -- IN/O UT REGISTER WRAPPER (REDUCE ROUTING TIMES)
    type inout_wrapper_type is record
        -- nfa to mem
        mem_data   : std_logic_vector(CFG_EDGE_BRAM_WIDTH - 1 downto 0);
        mem_wren   : std_logic_vector(CFG_ENGINE_NCRITERIA - 1 downto 0);
        mem_addr   : std_logic_vector(CFG_TRANSITION_POINTER_WIDTH - 1 downto 0);
    end record;
    type inout_wrapper_array is array (G_INOUT_LATENCY - 1 downto 0) of inout_wrapper_type;
    signal inout_r, inout_rin : inout_wrapper_array;
    signal io_r   : inout_wrapper_type;
begin

----------------------------------------------------------------------------------------------------
-- ERBIUM CORE TOP                                                                                --
----------------------------------------------------------------------------------------------------

gen_dopio: for D in 0 to CFG_ENGINE_DOPIO_CORES - 1 generate

  gen_stages: for I in 0 to CFG_ENGINE_NCRITERIA - 1 generate
    
    mem_edge(D)(I) <= deserialise_edge_store(uram_rd_data(D)(I));

    buff_query_g : buffer_query generic map
    (
        G_DEPTH         => CFG_EDGE_BUFFERS_DEPTH
    )
    port map
    (
        rst_i           => rst_i,
        clk_i           => clk_i,
        --
        wr_en_i         => query_wr_en(D),
        wr_data_i       => query_i(I),
        full_o          => open,
        almost_full_o   => query_full(D)(I),
        --
        rd_en_i         => query_read(D)(I),
        rd_data_o       => query(D)(I),
        empty_o         => query_empty(D)(I)
    );

    pe_g : core generic map
    (
        G_MATCH_STRCT         => CFG_CORE_PARAM_ARRAY(I).G_MATCH_STRCT,
        G_MATCH_FUNCTION_A    => CFG_CORE_PARAM_ARRAY(I).G_MATCH_FUNCTION_A,
        G_MATCH_FUNCTION_B    => CFG_CORE_PARAM_ARRAY(I).G_MATCH_FUNCTION_B,
        G_MATCH_FUNCTION_PAIR => CFG_CORE_PARAM_ARRAY(I).G_MATCH_FUNCTION_PAIR,
        G_MATCH_MODE          => CFG_CORE_PARAM_ARRAY(I).G_MATCH_MODE,
        G_MEM_RD_LATENCY      => CFG_CORE_PARAM_ARRAY(I).G_RAM_LATENCY,
        G_WEIGHT              => CFG_CORE_PARAM_ARRAY(I).G_WEIGHT,
        G_WILDCARD_ENABLED    => CFG_CORE_PARAM_ARRAY(I).G_WILDCARD_ENABLED
    )
    port map
    (
        rst_i           => rst_i,
        clk_i           => clk_i,
        idle_o          => pe_idle(D)(I),
        prev_idle_i     => prev_idle(D)(I),
        -- FIFO buffer from previous level
        prev_empty_i    => prev_empty(D)(I),
        prev_data_i     => prev_data(D)(I),
        prev_read_o     => prev_read(D)(I),
        -- FIFO query buffer
        query_i         => query(D)(I),
        query_empty_i   => query_empty(D)(I),
        query_read_o    => query_read(D)(I),
        -- MEMORY
        mem_edge_i      => mem_edge(D)(I),
        mem_addr_o      => mem_addr(D)(I),
        mem_en_o        => mem_en(D)(I),
        -- FIFO buffer to next level
        next_full_i     => next_full(D)(I),
        next_data_o     => next_data(D)(I),
        next_write_o    => next_write(D)(I)
    );

    buff_edge_g : buffer_edge generic map
    (
        G_DEPTH         => CFG_EDGE_BUFFERS_DEPTH,
        G_ALMST         => CFG_CORE_PARAM_ARRAY(I).G_RAM_LATENCY + 2
    )
    port map
    (
        rst_i           => rst_i,
        clk_i           => clk_i,
        --
        wr_en_i         => next_write(D)(I),
        wr_data_i       => next_data(D)(I),
        almost_full_o   => next_full(D)(I),
        full_o          => open,
        --
        rd_en_i         => prev_read(D)(I+1),
        rd_data_o       => prev_data(D)(I+1),
        empty_o         => prev_empty(D)(I+1)
    );

  end generate gen_stages;

    ------------------------------------------------------------------------------------------------
    -- RESULT REDUCER                                                                             --
    ------------------------------------------------------------------------------------------------

    reducer : result_reducer port map
    (
        clk_i           => clk_i,
        rst_i           => rst_i,
        engine_idle_i   => sig_cores_idle(D),
        --
        interim_empty_i => prev_empty(D)(CFG_ENGINE_NCRITERIA),
        interim_data_i  => prev_data(D)(CFG_ENGINE_NCRITERIA),
        interim_read_o  => prev_read(D)(CFG_ENGINE_NCRITERIA),
        -- final result to TOP
        result_ready_i  => resred_ready(D),
        result_data_o   => resred_value(D),
        result_last_o   => resred_last(D),
        result_valid_o  => resred_valid(D)
    );

    prev_idle(D) <= query_last_i & (pe_idle(D)(0 to CFG_ENGINE_NCRITERIA - 2)
                                    and not next_write(D)(0 to CFG_ENGINE_NCRITERIA - 2));

    sig_cores_idle(D) <= v_and(pe_idle(D)) and not v_or(next_write(D)) and query_last_i;

    -- ORIGIN
    sig_origin_node(D).query_id     <= query(D)(0).query_id;
    sig_origin_node(D).weight       <= (others => '0');
    sig_origin_node(D).clock_cycles <= (others => '0');
    sig_origin_node(D).has_match    <= '1';
    prev_empty(D)(0) <= query_empty(D)(0);
    prev_data(D)(0)  <= sig_origin_node(D);

    -- ORIGIN LOOK-UP
    gen_lookup : if CFG_FIRST_CRITERION_LOOKUP generate
        sig_origin_node(D).pointer <= (CFG_TRANSITION_POINTER_WIDTH - 1 downto CFG_CRITERION_VALUE_WIDTH => '0') & query(D)(0).operand;
    end generate gen_lookup;

    gen_lookup_n : if not CFG_FIRST_CRITERION_LOOKUP generate
        sig_origin_node(D).pointer  <= (others => '0');
    end generate gen_lookup_n;

    -- DOPIO
    query_wr_en(D) <= query_wr_en_i when dopio_r.query_flow_ctrl = D else '0';
    resred_ready(D) <= result_ready_i when dopio_r.reslt_flow_ctrl = D else '0';

end generate gen_dopio;

gen_stages_mem: for I in 0 to CFG_ENGINE_NCRITERIA - 1 generate

  gen_dp_core: if CFG_ENGINE_DOPIO_CORES = 1 generate

    uram_g : uram_wrapper generic map
    (
        G_RAM_WIDTH     => CFG_EDGE_BRAM_WIDTH,
        G_RAM_DEPTH     => CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH,
        G_RD_LATENCY    => CFG_CORE_PARAM_ARRAY(I).G_RAM_LATENCY
    )
    port map
    (
        clk_i         => clk_i,
        core_a_en_i   => mem_en(0)(I),
        core_a_addr_i => mem_addr(0)(I)(clogb2(CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH)-1 downto 0),
        core_a_data_o => uram_rd_data(0)(I),
        core_b_en_i   => '0',
        core_b_addr_i => (others => '0'),
        core_b_data_o => open,
        wr_en_i       => io_r.mem_wren(I),
        wr_addr_i     => io_r.mem_addr(clogb2(CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH)-1 downto 0),
        wr_data_i     => io_r.mem_data
    );

  end generate gen_dp_core;

  gen_dp_cores: if CFG_ENGINE_DOPIO_CORES = 2 generate

    uram_g : uram_wrapper generic map
    (
        G_RAM_WIDTH     => CFG_EDGE_BRAM_WIDTH,
        G_RAM_DEPTH     => CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH,
        G_RD_LATENCY    => CFG_CORE_PARAM_ARRAY(I).G_RAM_LATENCY
    )
    port map
    (
        clk_i         => clk_i,
        core_a_en_i   => mem_en(0)(I),
        core_a_addr_i => mem_addr(0)(I)(clogb2(CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH)-1 downto 0),
        core_a_data_o => uram_rd_data(0)(I),
        core_b_en_i   => mem_en(1)(I),
        core_b_addr_i => mem_addr(1)(I)(clogb2(CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH)-1 downto 0),
        core_b_data_o => uram_rd_data(1)(I),
        wr_en_i       => io_r.mem_wren(I),
        wr_addr_i     => io_r.mem_addr(clogb2(CFG_CORE_PARAM_ARRAY(I).G_RAM_DEPTH)-1 downto 0),
        wr_data_i     => io_r.mem_data
    );

  end generate gen_dp_cores;

end generate gen_stages_mem;


----------------------------------------------------------------------------------------------------
-- DOPIO ENGINE                                                                                   --
----------------------------------------------------------------------------------------------------

query_ready_o  <= dopio_rin.query_ready;

result_last_o  <= not v_or((sig_dopio_res and resred_last) xor dopio_r.core_running);
result_valid_o <= v_or(resred_valid and sig_dopio_res);
result_value_o <= resred_value(dopio_r.reslt_flow_ctrl).pointer;

sig_dopio_res <= std_logic_vector(to_unsigned(dopio_r.reslt_flow_ctrl + 1, CFG_ENGINE_DOPIO_CORES));

dopio_comb: process(dopio_r, query_wr_en_i, query_full, resred_valid, result_ready_i, resred_last)
    variable v : dopio_reg_type;
begin
    v := dopio_r;

    -- reslt_flow_ctrl
    if (resred_valid(dopio_r.reslt_flow_ctrl) and result_ready_i) = '1' then
        v.core_running(dopio_r.reslt_flow_ctrl) := not resred_last(dopio_r.reslt_flow_ctrl);
        v.reslt_flow_ctrl := dopio_r.reslt_flow_ctrl + 1;
        if v.reslt_flow_ctrl = CFG_ENGINE_DOPIO_CORES then
            v.reslt_flow_ctrl := 0;
        end if;
    end if;

    -- query_flow_ctrl
    if query_wr_en_i = '1' then
        v.core_running(dopio_r.query_flow_ctrl) := '1';
        v.query_flow_ctrl := dopio_r.query_flow_ctrl + 1;
        if v.query_flow_ctrl = CFG_ENGINE_DOPIO_CORES then
            v.query_flow_ctrl := 0;
        end if;
        v.query_ready := not query_full(v.query_flow_ctrl)(CFG_ENGINE_NCRITERIA - 1);
    else
        v.query_ready := not query_full(dopio_r.query_flow_ctrl)(CFG_ENGINE_NCRITERIA - 1);
    end if;
    
    dopio_rin <= v;
end process;

dopio_seq: process(clk_i)
begin
    if rising_edge(clk_i) then
        if rst_i = '0' then
            dopio_r.query_ready <= '0';
            dopio_r.core_running <= (others => '0');
            dopio_r.query_flow_ctrl <= 0;
            dopio_r.reslt_flow_ctrl <= 0;
        else
            dopio_r <= dopio_rin;
        end if;
    end if;
end process;


----------------------------------------------------------------------------------------------------
-- IN/OUT REGISTER WRAPPER (REDUCE ROUTING TIMES)                                                 --
----------------------------------------------------------------------------------------------------

ior_comb : process(inout_r, mem_i, mem_wren_i, mem_addr_i)
    variable v : inout_wrapper_array;
begin
    
    v := inout_r;
    
    v(0) := inout_r(1);
    v(1) := inout_r(2);
    v(2) := inout_r(3);

    v(3).mem_data := mem_i;
    v(3).mem_wren := mem_wren_i;
    v(3).mem_addr := mem_addr_i;

    inout_rin <= v;

end process;

ior_seq : process(clk_i)
begin
    if rising_edge(clk_i) then
        if rst_i = '0' then
            -- default rst
            inout_r(0).mem_wren <= (others => '0');
            inout_r(1).mem_wren <= (others => '0');
            inout_r(2).mem_wren <= (others => '0');
        else
            inout_r <= inout_rin;
        end if;
    end if;
end process;

-- assign
io_r <= inout_r(0);

end architecture behavioural;