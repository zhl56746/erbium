----------------------------------------------------------------------------------------------------
--                                                                                                --
--                                                                                                --
--                                                                                                --
--                                                                                                --
--                                                                                                --
--                                                                                                --
----------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

library tools;
use tools.std_pkg.all;

library bre;
use bre.engine_pkg.all;
use bre.core_pkg.all;

entity mct_wrapper is
    port (
        clk_i        :  in std_logic;
        rst_i        :  in std_logic;

        -- input bus
        rd_data_i    :  in std_logic_vector(511 downto 0);
        rd_valid_i   :  in std_logic;
        rd_last_i    :  in std_logic; -- not in use
        rd_stype_i   :  in std_logic;
        rd_ready_o   : out std_logic;

        -- output bus
        wr_data_o    : out std_logic_vector(511 downto 0);
        wr_valid_o   : out std_logic;
        wr_ready_i   :  in std_logic
    );
end mct_wrapper;

architecture rtl of mct_wrapper is

    constant CFG_DATA_BUS_WIDTH : integer   := 512;
    constant CFG_RD_TYPE_NFA    : std_logic := '0'; -- related to rd_stype_i
    constant CFG_RD_TYPE_QUERY  : std_logic := '1'; -- related to rd_stype_i
    constant C_QUERY_PARTITIONS : integer := CFG_DATA_BUS_WIDTH rem (2*CFG_ENGINE_CRITERIUM_WIDTH);
    --
    signal sig_query_ready    : std_logic;
    signal sig_result_ready   : std_logic;
    signal sig_result_valid   : std_logic;
    signal sig_result_value   : std_logic_vector(CFG_MEM_ADDR_WIDTH - 1 downto 0);


    type flow_ctrl_type is (FLW_CTRL_WAIT, FLW_CTRL_READ, FLW_CTRL_WRITE);
    type query_reg_type is record
        flow_ctrl       : flow_ctrl_type;
        query_array     : query_in_array_type;
        counter         : integer range 1 to CFG_ENGINE_NCRITERIA;
        ready           : std_logic;
        wr_en           : std_logic;
    end record;

    type nfa_reg_type is record
        flow_ctrl       : flow_ctrl_type;
        ready           : std_logic;
        cnt_criterium   : integer range 0 to CFG_ENGINE_NCRITERIA;
        cnt_edge        : std_logic_vector(RNG_BRAM_EDGE_STORE_POINTER - 1 downto 0);
        cnt_slice       : integer range 0 to C_QUERY_PARTITIONS-1;
        mem_addr        : std_logic_vector(CFG_MEM_ADDR_WIDTH - 1 downto 0);
        mem_data        : edge_store_type;
        mem_wren        : std_logic_vector(CFG_ENGINE_NCRITERIA - 1 downto 0);
        engine_rst      : std_logic;
    end record;

    signal query_r, query_rin : query_reg_type;

begin

rd_ready_o <= query_r.ready or nfa_r.ready;

----------------------------------------------------------------------------------------------------
-- QUERY DESERIALISER                                                                             --
----------------------------------------------------------------------------------------------------
-- extract input query criteria from the rd_data_i bus. each query has CFG_ENGINE_NCRITERIA criteria
-- and each criterium has two operands of CFG_ENGINE_CRITERIUM_WIDTH width

query_comb : process(query_r, rd_stype_i, rd_valid_i, rd_data_i, sig_query_ready)
    variable v : query_reg_type;
    --
    variable useful    : integer range 1 to C_QUERY_PARTITIONS;
    variable remaining : integer range 0 to CFG_ENGINE_NCRITERIA;
begin
    v := query_r;

    case query_r.flow_ctrl is

      when FLW_CTRL_WAIT =>

            v.ready := '0';
            v.wr_en := '0';

            if rd_stype_i = CFG_RD_TYPE_QUERY and rd_valid_i = '1' then
                v.flow_ctrl := FLW_CTRL_READ;
                v.counter   := 0;
                v.ready     := '1';
                -- TODO increment query_id
            end if;

      when FLW_CTRL_READ =>

            v.ready := '1';
            v.wr_en := '0';

            remaining := CFG_ENGINE_NCRITERIA - query_r.counter;
            if (remaining > C_QUERY_PARTITIONS) then
                useful := C_QUERY_PARTITIONS;
            else
                useful := remaining;
            end if;
            
            v.counter := query_r.counter + useful;
            if (v.counter = CFG_ENGINE_NCRITERIA) then
                v.flow_ctrl := FLW_CTRL_WRITE;
                v.ready := '0';
            end if;

            for idx in 0 to useful loop
                v.query_array(idx).operand_a := rd_data_i(
                                            CFG_DATA_BUS_WIDTH-(idx*2*CFG_ENGINE_CRITERIUM_WIDTH)-1
                                            downto
                                            CFG_DATA_BUS_WIDTH-(idx*2*CFG_ENGINE_CRITERIUM_WIDTH)-CFG_ENGINE_CRITERIUM_WIDTH);
                v.query_array(idx).operand_b := rd_data_i(
                                            CFG_DATA_BUS_WIDTH-(idx*2*CFG_ENGINE_CRITERIUM_WIDTH)-CFG_ENGINE_CRITERIUM_WIDTH-1
                                            downto
                                            CFG_DATA_BUS_WIDTH-((idx+1)*2*CFG_ENGINE_CRITERIUM_WIDTH));
                --v.query_array(idx).query_id  := ; -- TODO query_id
            end loop;

      when FLW_CTRL_WRITE => 

            v.ready := '0';
            v.wr_en := '0';

            if sig_query_ready = '1' then
                v.wr_en := '1';
                v.flow_ctrl := FLW_CTRL_WAIT;
            end if;

    end case;

    query_rin <= v;
end process;

query_seq: process(clk_i)
begin
    if rising_edge(clk_i) then
        if rst_i = '1' then
            query_r.flow_ctrl   <= FLW_CTRL_WAIT;
            query_r.counter     <= 0;
            query_r.ready       <= '0';
            query_r.wr_en       <= '0';
        else
            query_r <= query_rin;
        end if;
    end if;
end process;

----------------------------------------------------------------------------------------------------
-- NFA-EDGES DESERIALISER                                                                         --
----------------------------------------------------------------------------------------------------
-- extract nfa edges from the rd_data_i bus and assign them to the nfa_mem_data bus, setting both
-- nfa_mem_wren and nfa_mem_addr accordingly. each criterium level has its own memory bank storing
-- the respective edges. each esge is 64-bit wide. edges of a single criteria level are aligned at
-- cache line boundaries.

nfa_comb : process(nfa_r, rd_stype_i, rd_valid_i, rd_data_i)
begin
    v := nfa_r;

    case nfa_r.flow_ctrl is

      when FLW_CTRL_WAIT =>

            v.ready      := '0';
            v.mem_wren   := (others => '0');
            v.engine_rst := '0';
            if rd_stype_i = CFG_RD_TYPE_NFA and rd_valid_i = '1' then
                v.flow_ctrl     := FLW_CTRL_READ;
                v.ready         := '0';
                v.cnt_criterium := 0;
                v.engine_rst    := '1';
            end if;

      when FLW_CTRL_READ =>

            -- Once per criterium
            v.ready     := '0';
            v.flow_ctrl := FLW_CTRL_WRITE;
            v.mem_wren  := (others => '0');
            v.mem_addr  := (others => '0');
            v.mem_data  := deserialise_edge_store(rd_data_i(
                                            CFG_DATA_BUS_WIDTH-CFG_EDGE_BRAM_WIDTH-1
                                            downto
                                            CFG_DATA_BUS_WIDTH-2*CFG_EDGE_BRAM_WIDTH));
            v.cnt_edge  := rd_data_i(CFG_DATA_BUS_WIDTH-1 downto CFG_DATA_BUS_WIDTH-CFG_EDGE_BRAM_WIDTH);
            v.cnt_slice := 2;

            if nfa_r.cnt_criterium = CFG_ENGINE_NCRITERIA then
                v.flow_ctrl  := FLW_CTRL_WAIT;
                v.mem_wren   := (others => '0');
                v.engine_rst := '0';
            else
                v.mem_wren(nfa_r.cnt_criterium) := '1';
            end if;

      when FLW_CTRL_WRITE =>

            -- Once per edge
            v.ready     := '0';
            v.mem_addr  := increment(nfa_r.mem_addr);
            v.mem_data  := deserialise_edge_store(rd_data_i(
                                        CFG_DATA_BUS_WIDTH-nfa_r.cnt_slice*CFG_EDGE_BRAM_WIDTH-1
                                        downto
                                        CFG_DATA_BUS_WIDTH-(nfa_r.cnt_slice+1)*CFG_EDGE_BRAM_WIDTH));
            v.cnt_slice := nfa_r.cnt_slice + 1;

            if v.cnt_slice = C_QUERY_PARTITIONS-1 then
                v.cnt_slice := 0;
                v.ready     := '1';
            end if;

            if v.mem_addr = nfa_r.cnt_edge then
                v.flow_ctrl     := FLW_CTRL_READ;
                v.cnt_criterium := nfa_r.cnt_criterium + 1;
                v.mem_wren      := (others => '0');
                v.ready         := '0';
            end if;

    end case;

    nfa_rin <= v;
end process;

nfa_seq : process(clk_i)
begin
    if rising_edge(clk_i) then
        if rst_i = '1' then
            flow_ctrl       <= FLW_CTRL_WAIT;
            ready           <= '0';
            cnt_criterium   <= 0;
            cnt_slice       <= 0;
            cnt_edge        <= (others => '0');
            mem_addr        <= (others => '0');
            mem_wren        <= (others => '0');
            engine_rst      <= '1';
        else
            nfa_r <= nfa_rin;
        end if;
    end if;
end process;

----------------------------------------------------------------------------------------------------
-- OUTPUT RESULT                                                                                  --
----------------------------------------------------------------------------------------------------
-- consume the outputed sig_result_value and fill in a cache line to write back on the wr_data_o bus
-- A query result consists of the index of the content it points to. This result value occupies
-- CFG_MEM_ADDR_WIDTH bits

wr_data_o <= sig_result_value & (others => '0');

----------------------------------------------------------------------------------------------------
-- NFA-BRE ENGINE TOP                                                                             --
----------------------------------------------------------------------------------------------------
mct_engine_top: top port map 
(
    clk_i           => clk_i,
    rst_i           => nfa_r.engine_rst,
    --
    query_i         => query_r.query_array,
    query_wr_en_i   => query_r.wr_en,
    query_ready_o   => sig_query_ready,
    --
    mem_i           => nfa_r.mem_data,
    mem_wren_i      => nfa_r.mem_wren,
    mem_addr_i      => nfa_r.mem_addr,
    --
    result_ready_i  => wr_ready_i,
    result_valid_o  => wr_valid_o,
    result_value_o  => sig_result_value
);

end architecture rtl;