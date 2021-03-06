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
use ieee.numeric_std.all;

library tools;

PACKAGE std_pkg IS

----------------------------------------------------------------------------------------------------
-- FUNCTIONS IN std_pkg.vhd                                                                       --
----------------------------------------------------------------------------------------------------

    function v_or(d : std_logic_vector) return std_logic;
    function v_and(d : std_logic_vector) return std_logic;
    function is_zero(d : std_logic_vector) return std_logic;
    function is_not_zero(d : std_logic_vector) return std_logic;
    function my_conv_integer(a: std_logic_vector) return integer;
    function notx(d : std_logic_vector) return boolean;
    function compare(a, b : std_logic_vector) return std_logic;
    function multiply(a, b : std_logic_vector) return std_logic_vector;
    function sign_extend(value: std_logic_vector; fill: std_logic; size: positive) return std_logic_vector;
    function add(a, b : std_logic_vector; ci: std_logic) return std_logic_vector;
    function increment(a : std_logic_vector) return std_logic_vector;
    function decrement(a : std_logic_vector) return std_logic_vector;
    function shift(value : std_logic_vector(31 downto 0); shamt: std_logic_vector(4 downto 0); s: std_logic; t: std_logic) return std_logic_vector;
    function shift_left(value : std_logic_vector(31 downto 0); shamt : std_logic_vector(4 downto 0)) return std_logic_vector;
    function shift_right(value : std_logic_vector(31 downto 0); shamt : std_logic_vector(4 downto 0); padding: std_logic) return std_logic_vector;
    function FLOOR (X : real ) return integer;
        -- returns largest integer value (as real) not greater than X
    function clogb2 (depth: in natural) return integer;
    function power_of_two(value: integer; depth: integer) return std_logic_vector;

----------------------------------------------------------------------------------------------------
-- COMPONENTS IN std_pkg.vhd                                                                      --
----------------------------------------------------------------------------------------------------

    component uram_wrapper is
    generic (
        G_RAM_WIDTH  : integer := 64;                  -- Specify RAM witdh (number of bits per row)
        G_RAM_DEPTH  : integer := 1024;                -- Specify RAM depth (number of entries)
        G_RD_LATENCY : integer := 2                    -- Specify RAM read latency
    );
    port (
        clk_i         :  in std_logic;
        core_a_en_i   :  in std_logic;
        core_a_addr_i :  in std_logic_vector((clogb2(G_RAM_DEPTH)-1) downto 0);
        core_a_data_o : out std_logic_vector(G_RAM_WIDTH-1 downto 0);
        core_b_en_i   :  in std_logic;
        core_b_addr_i :  in std_logic_vector((clogb2(G_RAM_DEPTH)-1) downto 0);
        core_b_data_o : out std_logic_vector(G_RAM_WIDTH-1 downto 0);
        wr_en_i       :  in std_logic;
        wr_addr_i     :  in std_logic_vector((clogb2(G_RAM_DEPTH)-1) downto 0);
        wr_data_i     :  in std_logic_vector(G_RAM_WIDTH-1 downto 0)
    );
    end component;


    component simple_counter is
    generic (
        G_WIDTH   : integer := 8
    );
    port (
        clk_i     :  in std_logic;
        rst_i     :  in std_logic;
        enable_i  :  in std_logic;
        counter_o : out std_logic_vector(G_WIDTH - 1 downto 0)
    );
    end component;

    component rxtx_fifo_single is
    generic (
        G_DATA_WIDTH    : integer := 32
    );
    port (
        clk_i           :  in std_logic;
        rst_i           :  in std_logic; -- rst low active
        -- input (slave)
        slav_ready_o    : out std_logic;
        slav_valid_i    :  in std_logic;
        slav_last_i     :  in std_logic;
        slav_value_i    :  in std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        -- output (master)
        mast_ready_i    :  in std_logic;
        mast_valid_o    : out std_logic;
        mast_last_o     : out std_logic;
        mast_value_o    : out std_logic_vector(G_DATA_WIDTH - 1 downto 0)
    );
    end component;

    component rxtx_fifo_multi is
    generic (
        G_DATA_WIDTH    : integer := 32;
        G_DEPTH         : integer := 5
    );
    port (
        clk_i           :  in std_logic;
        rst_i           :  in std_logic; -- rst low active
        -- input (slave)
        slav_ready_o    : out std_logic;
        slav_valid_i    :  in std_logic;
        slav_last_i     :  in std_logic;
        slav_value_i    :  in std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        -- output (master)
        mast_ready_i    :  in std_logic;
        mast_valid_o    : out std_logic;
        mast_last_o     : out std_logic;
        mast_value_o    : out std_logic_vector(G_DATA_WIDTH - 1 downto 0)
    );
    end component;

end std_pkg;

PACKAGE BODY std_pkg IS

-- Unary OR reduction
    function v_or(d : std_logic_vector) return std_logic is
        variable z : std_logic;
    begin
        z := '0';
        if notx (d) then
            for i in d'range loop
                z := z or d(i);
            end loop;
        end if;
        return z;
    end;
-- Unary AND reduction
    function v_and(d : std_logic_vector) return std_logic is
        variable z : std_logic;
    begin
        z := '1';
        if notx (d) then
            for i in d'range loop
                z := z and d(i);
            end loop;
        end if;
        return z;
    end;

-- Check for ones in the vector
    function is_not_zero(d : std_logic_vector) return std_logic is
        variable z : std_logic_vector(d'range);
    begin
        z := (others => '0');
        if notx(d) then

            if d = z then
                return '0';
            else
                return '1';
            end if;

        else
            return '0';
        end if;
    end;

-- Check for ones in the vector
    function is_zero(d : std_logic_vector) return std_logic is
    begin
        return not is_not_zero(d);
    end;

    -- rewrite conv_integer to avoid modelsim warnings
    function my_conv_integer(a : std_logic_vector) return integer is
        variable res : integer range 0 to 2**a'length-1;
    begin
        res := 0;
        if (notx(a)) then
            res := to_integer(unsigned(a));
        end if;
        return res;
    end;

    function compare(a, b : std_logic_vector) return std_logic is
        variable z : std_logic;
    begin
        if notx(a & b) and a = b then
            return '1';
        else
            return '0';
        end if;
    end;

-- Unary NOT X test
    function notx(d : std_logic_vector) return boolean is
        variable res : boolean;
    begin
        res := true;
-- pragma translate_off
        res := not is_x(d);
-- pragma translate_on
        return (res);
    end;

-- -- 32 bit shifter
-- -- SYNOPSIS:
-- --    value: value to be shifted
-- --    shamt: shift amount
-- --    s 0 / 1: shift right / left
-- --    t 0 / 1: shift logical / arithmetic
-- -- PSEUDOCODE (from microblaze reference guide)
-- --     if S = 1 then
-- --          (rD) = (rA) << (rB)[27:31]
-- --     else
-- --      if T = 1 then
-- --         if ((rB)[27:31]) != 0 then
-- --              (rD)[0:(rB)[27:31]-1] = (rA)[0]
-- --              (rD)[(rB)[27:31]:31] = (rA) >> (rB)[27:31]
-- --         else
-- --              (rD) = (rA)
-- --      else
-- --         (rD) = (rA) >> (rB)[27:31]

    function shift(value: std_logic_vector(31 downto 0); shamt: std_logic_vector(4 downto 0); s: std_logic; t: std_logic) return std_logic_vector is
    begin
        if s = '1' then
            -- left arithmetic or logical shift
            return shift_left(value, shamt);
        else
            if t = '1' then
                -- right arithmetic shift
                return shift_right(value, shamt, value(31));
            else
                -- right logical shift
                return shift_right(value, shamt, '0');
            end if;
        end if;
    end;

    function shift_left(value: std_logic_vector(31 downto 0); shamt: std_logic_vector(4 downto 0)) return std_logic_vector is
        variable result: std_logic_vector(31 downto 0);
        variable paddings: std_logic_vector(15 downto 0);
    begin
        paddings := (others => '0');
        result := value;
        if (shamt(4) = '1') then result := result(15 downto 0) & paddings(15 downto 0); end if;
        if (shamt(3) = '1') then result := result(23 downto 0) & paddings( 7 downto 0); end if;
        if (shamt(2) = '1') then result := result(27 downto 0) & paddings( 3 downto 0); end if;
        if (shamt(1) = '1') then result := result(29 downto 0) & paddings( 1 downto 0); end if;
        if (shamt(0) = '1') then result := result(30 downto 0) & paddings( 0 );         end if;
        return result;
    end;

    function shift_right(value: std_logic_vector(31 downto 0); shamt: std_logic_vector(4 downto 0); padding: std_logic) return std_logic_vector is
        variable result: std_logic_vector(31 downto 0);
        variable paddings: std_logic_vector(15 downto 0);
    begin
        paddings := (others => padding);
        result := value;
        if (shamt(4) = '1') then result := paddings(15 downto 0) & result(31 downto 16); end if;
        if (shamt(3) = '1') then result := paddings( 7 downto 0) & result(31 downto  8); end if;
        if (shamt(2) = '1') then result := paddings( 3 downto 0) & result(31 downto  4); end if;
        if (shamt(1) = '1') then result := paddings( 1 downto 0) & result(31 downto  2); end if;
        if (shamt(0) = '1') then result := paddings( 0 )         & result(31 downto  1); end if;
        return result;
    end;

    function multiply(a, b: std_logic_vector) return std_logic_vector is
        variable x: std_logic_vector (a'length + b'length - 1 downto 0);
    begin
        x := std_logic_vector(signed(a) * signed(b));
        return x(31 downto 0);
    end;

    function sign_extend(value: std_logic_vector; fill: std_logic; size: positive) return std_logic_vector is
        variable a: std_logic_vector (size - 1 downto 0);
    begin
        a(size - 1 downto value'length) := (others => fill);
        a(value'length - 1 downto 0) := value;
        return a;
    end;

    function add(a, b : std_logic_vector; ci: std_logic) return std_logic_vector is
        variable x : std_logic_vector(a'length + 1 downto 0);
    begin
        x := (others => '0');
        if notx (a & b & ci) then
            x := std_logic_vector(signed('0' & a & '1') + signed('0' & b & ci));
        end if;
        return x(a'length + 1 downto 1);
    end;

    function increment(a : std_logic_vector) return std_logic_vector is
        variable x : std_logic_vector(a'length-1 downto 0);
    begin
        x := (others => '0');
        if notx (a) then
            x := std_logic_vector(signed(a) + 1);
        end if;
        return x;
    end;

    function decrement(a : std_logic_vector) return std_logic_vector is
        variable x : std_logic_vector(a'length-1 downto 0);
    begin
        x := (others => '0');
        if notx (a) then
            x := std_logic_vector(signed(a) - 1);
        end if;
        return x;
    end;

    function floor(X : real) return integer is
        -- returns largest integer value (as real) not greater than X
        -- No conversion to an integer type is expected, so truncate
        -- cannot overflow for large arguments.
        --
        variable large: real  := 1073741824.0;
        type long is range -1073741824 to 1073741824;
        -- 2**30 is longer than any single-precision mantissa
        variable rd: real;
    begin
        if abs( X ) >= large then
            return integer(X);
        else
            rd := real ( long( X));
            if X > 0.0 then
                if rd <= X then
                    return integer(rd);
                else
                    return integer(rd - 1.0);
                end if;
            elsif  X = 0.0  then
                return 0;
            else
                if rd >= X then
                    return integer(rd);
                else
                    return integer(rd + 1.0);
                end if;
            end if;
        end if;
    end floor;

    function clogb2( depth : natural) return integer is
        variable temp    : integer := depth;
        variable ret_val : integer := 0;
    begin
        while temp > 1 loop
            ret_val := ret_val + 1;
            temp    := temp / 2;
        end loop;

        if (depth mod 2) = 1 then
            ret_val := ret_val + 1;
        end if;

        return ret_val;
    end function;

    function power_of_two(value: integer; depth: integer) return std_logic_vector is
        variable res : std_logic_vector(depth - 1 downto 0);
    begin
        res := (others => '0');
        res(value) := '1';

        return res;
    end function;
    
end std_pkg;