globals("directive_tester","directive_matcher","comment_stripper",
        "identifier_mangler","identifier_matcher","blank_line_tester",
        "value_extractor","varsize_matcher","good_label_matcher",
        "routine_name_validator","parent_routine_extractor")
local lpeg = require "lpeg"
local C,Ct,Cc,S,P,R = lpeg.C,lpeg.Ct,lpeg.Cc,lpeg.S,lpeg.P,lpeg.R
-- general-purpose bits
local whitespace = S" \t"
local EW = whitespace^0 -- EW -> eat whitespace
identifier_matcher = ((P"_"+P"\\@"+R("az","AZ")))*(P"_"+P"\\@"+R("az","AZ","09"))^0
blank_line_tester = whitespace^0 * -1;
local scoped_id = (identifier_matcher*"::")^0*identifier_matcher
local quoted_char = P"\\" * 1 + 1
local dblquote_string = P'"' * (quoted_char - P'"')^0 * P'"'
local quote_string = P"'" * (quoted_char - P"'")^0 * P"'"
-- directive_tester
directive_tester = EW * "#"
-- directive_matcher
local parsed_quoted_char = (P"\\" * C(1))
local parsed_dblquote_string = Ct(P'"' * ((parsed_quoted_char + C(1)) - P'"')^0 * P'"') / table.concat
local directive_param = EW * (parsed_dblquote_string + C((1-S", \t")^1))
   * (EW * "," + #whitespace * EW + -1)
directive_matcher = EW * "#" * EW * C(identifier_matcher)
   * Ct(directive_param^0) * -1
-- comment_stripper
local noncomment_char = dblquote_string + quote_string + (1 - P";");
comment_stripper = C(noncomment_char^0)
-- identifier_mangler
local mangled_scoped_id = C(scoped_id)/identifier_mangling_function
local mangled_new_id = C(identifier_matcher)/identifier_creating_function
identifier_mangler = Ct(
   -- label definitions get mangled differently
   ((mangled_scoped_id*(C":"+#whitespace+-1))+true)
      *(mangled_scoped_id+C(whitespace^1+quote_string+dblquote_string+1))^0
      * -1
)/table.concat
-- value_extractor
local hex_value = lpeg.P"$" * C(lpeg.R("09","AF","af")*lpeg.R("09","AF","af")^-3) * Cc(16) / tonumber
local dec_value = C(lpeg.R"09"*lpeg.R"09"^-4) * Cc(10) / tonumber
value_extractor = hex_value + dec_value
-- varsize_matcher
local function rep(x) return x, x end
local sbs_matcher = dec_value * "*" * dec_value * "/" * dec_value
local ss_matcher = dec_value * Cc(1) * "/" * dec_value
local s_matcher = dec_value / rep * Cc(0)
varsize_matcher = (("BYTE" * Cc(1) * Cc(1) * Cc(0))
      + (("WORD"+P"PTR") * Cc(2) * Cc(2) * Cc(0))
      + sbs_matcher + ss_matcher + s_matcher) * -1
-- good_label_matcher
good_label_matcher = P"+"^1+P"-"^1+identifier_matcher
-- routine_name_validator
local routine_name = identifier_matcher - "_"
routine_name_validator = ((routine_name * P"::") - (routine_name*-1))^0 * routine_name * -1
-- parent_routine_extractor
parent_routine_extractor = C(((routine_name * P"::") - (routine_name*P"::"*routine_name*-1))^0 * routine_name) * P"::" * C(routine_name) * -1
