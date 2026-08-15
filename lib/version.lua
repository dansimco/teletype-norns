-- version.lua -- the version of the lib/ tree.
--
-- teletype.lua carries the same constant and compares the two at load. That
-- catches the failure mode where the top-level script is copied to the norns
-- but lib/ is not: the script starts, prints a current version, and then
-- behaves like an older build with no error to explain why.
return 'ui-6'
